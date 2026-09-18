# frozen_string_literal: true

require 'securerandom'
require_relative 'proto'
require_relative 'view/tree'
require_relative 'view/diff'
require_relative 'websocket'

module EUI
  # One socket, one component instance, one tree.
  #
  # The shape is the whole protocol in twenty lines: the client says Hello,
  # the server answers Welcome and mounts a tree, and from then on every
  # event is a handler, a render, and the *difference* between what the
  # client holds and what the view now says.
  class Session
    # A client that connects and says nothing is not a client.
    HELLO_TIMEOUT = 10
    # Whichever side has been silent for this long sends a Ping. Nothing
    # else wakes: the zero-wakeup idle budget is a property of that rule.
    IDLE_PING = 30
    # Two unanswered pings and the socket is gone, whatever it still says.
    MAX_UNANSWERED_PINGS = 2
    # The code on the `Error` that ends a session the application itself
    # closed. Codes 1–8 are the decoder's and 100–104 the client's; this is
    # a server's, and it says the session ended on purpose.
    CLOSED_BY_APPLICATION = 200

    attr_reader :id, :component, :viewport, :granted, :protocol

    def initialize(socket, component_class:, app:, logger: nil)
      @ws = socket
      @component_class = component_class
      @app = app
      @logger = logger
      @id = SecureRandom.bytes(16)
      @encoder = View::Encoder.new(assets: app&.assets)
      @inbox = Thread::Queue.new
      @seq = 0
      @acked = 0
      @protocol = Proto::PROTOCOL_VERSION
      @granted = 0
      @viewport = Proto::Viewport.default
      @open = true
    end

    def run
      hello = handshake or return

      @protocol = [hello.version, Proto::PROTOCOL_VERSION].min
      @granted = hello.granted
      @viewport = hello.viewport
      @encoder.protocol = @protocol
      # A session that starts empty, which is every first Hello's answer.
      # Resuming one whose socket broke is the server's to offer, and this
      # one does not yet: a client that reconnects gets a fresh Mount.
      send_frame(Proto::Frame.welcome(Proto::Welcome.new(@protocol, @id, false)))

      # The faces this application draws in, bound to their roles before
      # any view names one.
      @app&.fonts&.each { |family, hashes| @encoder.font(family, hashes) }

      @component = @component_class.new(session: self)
      @component.mount({ 'viewport' => @viewport.to_h })
      render!

      reader = Thread.new { read_loop }
      pump
      reader.kill
      @component.unmount
    rescue WebSocket::ClosedError, WebSocket::ProtocolError => e
      log("session ended: #{e.message}")
    ensure
      @open = false
      @ws.close
    end

    # Render again although nothing arrived: a timer in the application, a
    # message from another session, anything this process knows and the
    # client does not.
    def refresh!
      @inbox << [:render] if @open
    end

    # Say one line to the person through the machine they are using. Shown
    # only if they granted `notifications`, and nothing comes back either
    # way — not that it was shown, not that it was not.
    def notify(title, body: '', tag: '')
      @inbox << [:notify, [title.to_s, body.to_s, tag.to_s]] if @open
    end

    def close(reason = 'the application closed the session')
      @inbox << [:close, reason] if @open
    end

    def granted?(capability) = (@granted & Proto::Caps.bit(capability)) != 0

    private

    def handshake
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HELLO_TIMEOUT
      kind, bytes = @ws.recv
      return nil if kind.nil?
      if kind == :text
        # A text frame is not an extension point; it is something that is
        # not an EUI client.
        @ws.send_close(1003, 'binary frames only')
        return nil
      end
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      frame = Proto::Frame.decode(bytes)
      unless frame.kind == Proto::Frame::HELLO && frame.body.version >= 1
        fail_session(400, 'the first frame is a Hello')
        return nil
      end
      frame.body
    rescue DecodeError => e
      fail_session(400, e.message)
      nil
    end

    def read_loop
      while (message = @ws.recv)
        kind, bytes = message
        if kind == :text
          @inbox << [:close, 'binary frames only']
          break
        end
        @inbox << [:frame, bytes]
      end
      @inbox << [:eof]
    rescue WebSocket::ProtocolError => e
      @inbox << [:close, e.message]
    rescue StandardError => e
      log("read: #{e.class}: #{e.message}")
      @inbox << [:eof]
    end

    # The one thread that writes. Everything that changes the tree comes
    # through here, in the order it arrived, so two events never render on
    # top of each other.
    def pump
      unanswered = 0
      loop do
        item = @inbox.pop(timeout: IDLE_PING)
        if item.nil?
          unanswered += 1
          return if unanswered > MAX_UNANSWERED_PINGS

          send_frame(Proto::Frame.ping(SecureRandom.bytes(8)))
          next
        end

        what, payload = item
        case what
        when :eof then return
        when :close
          fail_session(CLOSED_BY_APPLICATION, payload.to_s)
          return
        when :render then render!
        when :notify
          send_batch([Proto::Op.notify(*payload)])
        when :frame
          unanswered = 0
          return unless handle(payload)
        end
      end
    end

    def handle(bytes)
      frame = Proto::Frame.decode(bytes)
      trace { "frame kind 0x#{frame.kind.to_s(16)}" }
      case frame.kind
      when Proto::Frame::EVENT then dispatch(frame.body)
      when Proto::Frame::ACK then @acked = frame.body
      when Proto::Frame::PING then send_frame(Proto::Frame.pong(frame.body))
      when Proto::Frame::PONG then nil
      when Proto::Frame::VIEWPORT
        @viewport = frame.body
        post('viewport', { 'viewport' => @viewport.to_h })
      when Proto::Frame::RESYNC
        # Not an error, and never answered with one: the client's tree is
        # unrecoverable and it wants the document again. The tables it
        # already holds are not repeated — they were never cleared.
        @encoder.forget_tree!
        render!
      when Proto::Frame::ERROR
        log("client error #{frame.body[0]}: #{frame.body[1]}")
        return false
      when Proto::Frame::UPLOAD, Proto::Frame::BLOB
        log('file transfers are not implemented yet; the chunk was dropped')
      else
        fail_session(400, 'that frame is the server\'s to send')
        return false
      end
      true
    rescue DecodeError => e
      fail_session(400, e.message)
      false
    end

    # An event on a node that carries no handler for it *now* is dropped.
    # Usually that is a race rather than an attack — a handler a render
    # removed is still in the client's tree for the one round trip it takes
    # the new one to arrive — and nothing is looked up for it either way.
    def dispatch(event)
      target = @encoder.event_target(event.node, event.event)
      unless target
        trace { "event on node #{event.node} (#{Proto::EventKind.name(event.event)}) names no handler in the tree we last sent" }
        return
      end

      name, props = target
      trace { "event #{Proto::EventKind.name(event.event)} on node #{event.node} -> #{name}" }
      post(name, {
             'node' => event.node,
             'kind' => Proto::EventKind.name(event.event),
             'payload' => resolve(event.payload),
             'props' => props
           })
    end

    def post(name, params)
      @component.handle(name, params)
      render!
    rescue ViewError
      raise
    rescue StandardError => e
      # A handler that raised leaves the state unchanged and the screen
      # right; the next click still works. It is a log line, not the end of
      # somebody's session.
      log("#{name}: #{e.class}: #{e.message}")
      log(e.backtrace.first(3).join("\n")) if e.backtrace
    end

    def render!
      view = @component.render
      ops = @encoder.render(view)
      send_batch(ops) unless ops.empty?
    rescue ViewError => e
      # A view that cannot be encoded fails the same way on every later
      # render, and a server that only logged it would leave a window that
      # looks alive and answers nothing.
      log("view: #{e.message}")
      fail_session(400, e.message)
      @open = false
    end

    def send_batch(ops)
      trace { "batch of #{ops.length}: #{ops.map { |o| format('0x%02X', o.opcode) }.join(' ')}" }
      @seq += 1
      send_frame(Proto::Frame.batch(Proto::Batch.new(@seq, ops)))
    end

    def send_frame(frame)
      @ws.send_binary(frame.encode)
    end

    def fail_session(code, message)
      send_frame(Proto::Frame.error(code, message))
      @ws.send_close(1000, 'session ended')
    rescue WebSocket::ClosedError
      nil
    end

    # Atoms the client sent back are ids in *this* session's table, so they
    # are resolved here rather than handed to a view as numbers.
    def resolve(value)
      case value.tag
      when Proto::Value::ATOM then @encoder.atom_value(value.value)
      when Proto::Value::LIST then value.value.map { |v| resolve(v) }
      else value.to_ruby
      end
    end

    def log(message)
      @logger&.call("[EUI] #{message}")
    end

    # `EUI_TRACE=1` prints every frame and every event this session sees.
    # The one thing worth watching when a click does nothing.
    def trace
      return unless ENV['EUI_TRACE']

      log("trace: #{yield}")
    end
  end
end
