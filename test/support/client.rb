# frozen_string_literal: true

require 'socket'
require 'digest/sha1'
require 'base64'
require 'securerandom'

# The client half of a session, in as little code as it takes: enough to
# drive a server in a test, and a readable answer to "what does a client
# actually do?".
class TestClient
  def self.free_port
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    port
  end

  def initialize(port, path)
    key = Base64.strict_encode64(SecureRandom.bytes(16))
    @socket = TCPSocket.new('127.0.0.1', port)
    @socket.write("GET #{path} HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\n" \
                  "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
    status = @socket.gets("\r\n")
    raise "handshake: #{status.inspect}" unless status&.include?('101')

    accept = nil
    while (line = @socket.gets("\r\n")) != "\r\n"
      accept = line.split(':', 2).last.strip if line.downcase.start_with?('sec-websocket-accept')
    end
    expected = Base64.strict_encode64(Digest::SHA1.digest(key + EUI::WebSocket::GUID))
    raise 'the accept key does not match' unless accept == expected
  end

  def hello(width: 1000, height: 700, granted: 0)
    viewport = EUI::Proto::Viewport.new(width, height, 100, 0, 1, 100)
    send_frame(EUI::Proto::Frame.hello(EUI::Proto::Hello.new(EUI::Proto::PROTOCOL_VERSION, viewport, granted, nil)))
  end

  def send_frame(frame)
    payload = frame.encode
    header = +''.b
    header << 0x82.chr
    len = payload.bytesize
    if len < 126
      header << (0x80 | len).chr
    elsif len < 65_536
      header << (0x80 | 126).chr << [len].pack('n')
    else
      header << (0x80 | 127).chr << [len].pack('Q>')
    end
    mask = SecureRandom.bytes(4).bytes
    masked = payload.bytes.each_with_index.map { |b, i| b ^ mask[i & 3] }.pack('C*')
    @socket.write(header + mask.pack('C*') + masked)
    self
  end

  # The next frame, or nil if the server said nothing in time.
  def recv(timeout: 3)
    return nil unless IO.select([@socket], nil, nil, timeout)

    b0 = read(1)&.unpack1('C')
    return nil if b0.nil?

    len = read(1).unpack1('C') & 0x7F
    len = read(2).unpack1('n') if len == 126
    len = read(8).unpack1('Q>') if len == 127
    EUI::Proto::Frame.decode(len.zero? ? '' : read(len))
  end

  # Every frame until one of `kind` arrives.
  def recv_until(kind, timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      frame = recv(timeout: timeout)
      return frame if frame.nil? || frame.kind == kind
    end
    nil
  end

  def click(node) = send_frame(EUI::Proto::Frame.event(EUI::Proto::EventFrame.new(node, EUI::Proto::EventKind.code('click'), 0, EUI::Proto::Value.null)))

  def close
    @socket.close
  rescue IOError
    nil
  end

  private

  def read(count)
    data = +''.b
    data << @socket.read(count - data.bytesize) while data.bytesize < count
    data
  end
end

# A running application, on a port of its own, stopped when the block ends.
def with_app(app)
  port = TestClient.free_port
  server = EUI::Server.new(app, host: '127.0.0.1', port: port, logger: ->(_line) {})
  thread = Thread.new { server.start }
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
  loop do
    begin
      TCPSocket.new('127.0.0.1', port).close
      break
    rescue Errno::ECONNREFUSED
      raise 'the server never came up' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end
  yield port
ensure
  server&.stop
  thread&.kill
end
