# frozen_string_literal: true

require_relative 'errors'
require_relative 'proto'
require_relative 'websocket'
require_relative 'session'

module EUI
  # A session over a pipe (`spec/01-transport.md` §7): the application
  # starts the client itself and speaks to it over the client's standard
  # input and output. No port, no TLS, no manifest — the window is a child
  # of this process and goes when it does.
  #
  #     app = EUI::App.new(name: "Counter")
  #     app.mount("counter", Counter)
  #     app.run_pipe            # opens the window, returns when it closes
  #
  # The frames are a socket's, one after another with nothing between them:
  # a frame's own length is what ends it. Assets travel in the session as
  # `Fetch` and `Asset`, because there is no origin for the client to `GET`
  # them from.
  module Pipe
    # The two ends of a pipe dressed as the socket a `Session` reads and
    # writes: `recv` gives one whole frame or nil at a clean end,
    # `send_binary` writes one, and `send_close` is the end of the pipe.
    class Socket
      def initialize(input, output)
        @in = input
        @out = output
        @write = Mutex.new
        @closed = false
      end

      def recv
        kind = @in.read(1)
        return nil if kind.nil?

        head = kind.b
        loop do
          byte = @in.read(1) or raise WebSocket::ProtocolError, 'the pipe ended in the middle of a frame'
          head << byte
          break if byte.ord.nobits?(0x80)
          raise WebSocket::ProtocolError, "a frame's length is not a varint" if head.bytesize >= 11
        end
        length = Proto::Reader.new(head.byteslice(1..)).varint
        # Before a byte of room is asked for: on a pipe nothing else bounds
        # what a length asks for (01 §7.2).
        raise WebSocket::ProtocolError, "a frame of #{length} bytes is past the limit" if length > Proto::Limits::MAX_FRAME_BYTES

        payload = length.zero? ? ''.b : @in.read(length)
        raise WebSocket::ProtocolError, 'the pipe ended in the middle of a frame' if payload.nil? || payload.bytesize != length

        [:binary, head + payload]
      end

      def send_binary(bytes)
        @write.synchronize do
          raise WebSocket::ClosedError, 'the pipe is closed' if @closed

          @out.write(bytes)
          @out.flush
        end
      rescue Errno::EPIPE, IOError => e
        raise WebSocket::ClosedError, e.message
      end

      # A pipe has no close frame. The `Error` before it said why; closing
      # our end is how the window learns the application has stopped.
      def send_close(_code = nil, _reason = nil)
        @write.synchronize do
          @out.close unless @closed
          @closed = true
        end
      rescue IOError
        nil
      end

      def close
        send_close
        @in.close unless @in.closed?
      rescue IOError
        nil
      end
    end

    # Start `eui --pipe` and run one session of `component` over its standard
    # input and output, until the window closes or the session ends.
    # Answers the client's exit status.
    #
    # `allow` is the grant (01 §7.6): the command line this process writes is
    # the whole of what the session may do, because a process the person
    # started can already do everything a capability names.
    def self.run(app, component: nil, eui: ENV.fetch('EUI', 'eui'), title: app.name, allow: [], logger: nil)
      klass = app.component_for(component) or raise Error, "no component #{component.inspect}"
      to_child, ours_out = IO.pipe
      ours_in, from_child = IO.pipe
      [to_child, ours_out, ours_in, from_child].each(&:binmode)
      args = [eui, '--pipe', '--title', title.to_s]
      grant = Array(allow).map(&:to_s)
      args += ['--allow', grant.join(',')] unless grant.empty?
      pid = Process.spawn(*args, in: to_child, out: from_child)
      to_child.close
      from_child.close

      Session.new(Socket.new(ours_in, ours_out), component_class: klass, app: app, logger: logger, pipe: true).run
      _, status = Process.wait2(pid)
      status
    ensure
      [ours_out, ours_in].each { |io| io&.close unless io&.closed? }
    end
  end
end
