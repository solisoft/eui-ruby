# frozen_string_literal: true

require 'digest/sha1'
require 'base64'
require 'securerandom'
require_relative 'errors'
require_relative 'proto'

module EUI
  # The server half of RFC 6455, with only what an EUI session needs.
  #
  # A session carries **binary** frames and nothing else: a text frame is
  # not a protocol extension point, it is a sign that something other than
  # an EUI client is talking, and the session ends
  # (`spec/01-transport.md` §2.3).
  class WebSocket
    GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
    MAX_MESSAGE = Proto::Limits::MAX_FRAME_BYTES + 16

    CONTINUATION = 0x0
    TEXT = 0x1
    BINARY = 0x2
    CLOSE = 0x8
    PING = 0x9
    PONG = 0xA

    class ClosedError < Error; end
    class ProtocolError < Error; end

    attr_reader :path, :headers

    def initialize(socket, path:, headers:)
      @socket = socket
      @path = path
      @headers = headers
      @write_lock = Mutex.new
      @closed = false
    end

    # Answer the upgrade. The key is not a secret and proves nothing: it is
    # there so that a cache between the two ends cannot mistake this for a
    # reply it may serve to somebody else.
    def self.accept(socket, path:, headers:)
      key = headers['sec-websocket-key']
      raise ProtocolError, 'no Sec-WebSocket-Key' unless key

      accept = Base64.strict_encode64(Digest::SHA1.digest(key + GUID))
      socket.write(
        "HTTP/1.1 101 Switching Protocols\r\n" \
        "Upgrade: websocket\r\n" \
        "Connection: Upgrade\r\n" \
        "Sec-WebSocket-Accept: #{accept}\r\n\r\n"
      )
      new(socket, path: path, headers: headers)
    end

    def closed? = @closed

    # The next application message, or nil once the peer has gone.
    # Control frames are answered here and never surface.
    def recv
      message = +''
      message.force_encoding(Encoding::BINARY)
      kind = nil

      loop do
        frame = read_frame
        return nil if frame.nil?

        opcode, payload, fin = frame
        case opcode
        when CLOSE
          send_close(1000)
          return nil
        when PING
          send_frame(PONG, payload)
          next
        when PONG
          next
        when TEXT, BINARY
          raise ProtocolError, 'a frame arrived inside a fragmented message' unless message.empty?

          kind = opcode
          message << payload
        when CONTINUATION
          raise ProtocolError, 'a continuation with nothing to continue' if kind.nil?

          message << payload
        else
          raise ProtocolError, "unknown opcode #{opcode}"
        end

        raise ProtocolError, 'message too large' if message.bytesize > MAX_MESSAGE
        next unless fin

        return [kind == TEXT ? :text : :binary, message]
      end
    end

    def send_binary(data) = send_frame(BINARY, data)

    def send_close(code = 1000, reason = '')
      return if @closed

      payload = [code].pack('n') + reason.to_s.byteslice(0, 123).to_s
      send_frame(CLOSE, payload)
      @closed = true
    rescue Error, SystemCallError, IOError
      @closed = true
    end

    def close
      send_close
      @socket.close
    rescue SystemCallError, IOError
      nil
    end

    private

    def send_frame(opcode, payload)
      payload = payload.to_s.b
      header = +''
      header.force_encoding(Encoding::BINARY)
      header << (0x80 | opcode).chr
      len = payload.bytesize
      if len < 126
        header << len.chr
      elsif len < 65_536
        header << 126.chr << [len].pack('n')
      else
        header << 127.chr << [len].pack('Q>')
      end
      @write_lock.synchronize do
        raise ClosedError, 'the socket is closed' if @socket.closed?

        @socket.write(header, payload)
      end
    rescue SystemCallError, IOError => e
      @closed = true
      raise ClosedError, e.message
    end

    def read_frame
      head = read_exactly(2)
      return nil if head.nil?

      b0, b1 = head.bytes
      fin = (b0 & 0x80) != 0
      raise ProtocolError, 'reserved bits set' if (b0 & 0x70) != 0

      opcode = b0 & 0x0F
      masked = (b1 & 0x80) != 0
      # Every frame from a client is masked; one that is not is either a
      # proxy rewriting traffic or something that is not a browser stack.
      raise ProtocolError, 'a client frame must be masked' unless masked

      len = b1 & 0x7F
      len = read_exactly(2).unpack1('n') if len == 126
      len = read_exactly(8).unpack1('Q>') if len == 127
      raise ProtocolError, 'frame too large' if len > MAX_MESSAGE

      mask = read_exactly(4)
      payload = len.zero? ? +'' : read_exactly(len)
      return nil if payload.nil?

      [opcode, unmask(payload, mask), fin]
    end

    def unmask(payload, mask)
      return payload if payload.empty?

      key = mask.bytes
      out = payload.dup
      out.force_encoding(Encoding::BINARY)
      bytes = out.bytes
      bytes.each_with_index { |b, i| bytes[i] = b ^ key[i & 3] }
      bytes.pack('C*')
    end

    def read_exactly(count)
      data = +''
      data.force_encoding(Encoding::BINARY)
      while data.bytesize < count
        chunk = @socket.read(count - data.bytesize)
        return nil if chunk.nil? || chunk.empty?

        data << chunk
      end
      data
    rescue SystemCallError, IOError
      nil
    end
  end
end
