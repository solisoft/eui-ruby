# frozen_string_literal: true

require_relative 'op'

module EUI
  module Proto
    # Which palette the viewer is using. A *client* fact: it reaches the
    # server only so a server can pick a matching image, never so it can
    # resolve a colour.
    module ThemeMode
      BY_CODE = { 0 => 'light', 1 => 'dark', 2 => 'high_contrast' }.freeze
      def self.name(code)
        BY_CODE.fetch(code) { raise DecodeError, "unknown theme mode #{code}" }
      end
    end

    # How tightly controls are packed.
    module Density
      BY_CODE = { 0 => 'compact', 1 => 'cozy', 2 => 'comfortable' }.freeze
      def self.name(code)
        BY_CODE.fetch(code) { raise DecodeError, "unknown density #{code}" }
      end
    end

    # Capability bits, as granted by the person and reported to the server
    # (`spec/01-transport.md` §2.1). Nothing is granted by being asked for.
    module Caps
      CAMERA          = 1 << 0
      MICROPHONE      = 1 << 1
      CLIPBOARD_READ  = 1 << 2
      CLIPBOARD_WRITE = 1 << 3
      NOTIFICATIONS   = 1 << 4
      LOCATION        = 1 << 5
      FS_PICK         = 1 << 6
      FS_SAVE         = 1 << 7
      NFC             = 1 << 8
      SCENE           = 1 << 9
      NET_OPEN        = 1 << 10

      NAMES = {
        'camera' => CAMERA, 'microphone' => MICROPHONE,
        'clipboard.read' => CLIPBOARD_READ, 'clipboard.write' => CLIPBOARD_WRITE,
        'notifications' => NOTIFICATIONS, 'location' => LOCATION,
        'fs.pick' => FS_PICK, 'fs.save' => FS_SAVE, 'nfc' => NFC,
        'scene' => SCENE, 'net.open' => NET_OPEN
      }.freeze

      # Every bit this revision defines. A bit outside it is a decode error:
      # a client that does not know what a bit means must not agree to it,
      # and neither must a server.
      ALL = 0x7FF

      def self.bit(name)
        NAMES.fetch(name.to_s) { raise Error, "unknown capability '#{name}'" }
      end

      def self.mask(names) = Array(names).reduce(0) { |acc, n| acc | bit(n) }

      def self.names(mask) = NAMES.select { |_, bit| (mask & bit) != 0 }.keys
    end

    # The viewer's presentation state.
    Viewport = Struct.new(:width, :height, :scale, :mode, :density, :font_scale) do
      def self.default = new(0, 0, 100, 0, 1, 100)

      def self.decode(reader)
        new(reader.varint32, reader.varint32, reader.u16,
            ThemeMode::BY_CODE.key?(m = reader.u8) ? m : (raise DecodeError, "unknown theme mode #{m}"),
            Density::BY_CODE.key?(d = reader.u8) ? d : (raise DecodeError, "unknown density #{d}"),
            reader.u16)
      end

      def encode(writer)
        writer.varint(width).varint(height).u16(scale).u8(mode).u8(density).u16(font_scale)
      end

      # What a view sees: pixels, a ratio, and names rather than codes.
      def to_h
        {
          'width' => width, 'height' => height, 'scale' => scale / 100.0,
          'mode' => ThemeMode.name(mode), 'density' => Density.name(density),
          'font_scale' => font_scale / 100.0
        }
      end
    end

    # A session the client still holds a tree for, offered back after the
    # socket broke (`spec/01-transport.md` §4.1). An offer, not a claim.
    Resume = Struct.new(:session, :acked)

    Hello = Struct.new(:version, :viewport, :granted, :resume)
    Welcome = Struct.new(:version, :session, :resumed)
    EventFrame = Struct.new(:node, :event, :name, :payload)
    Transfer = Struct.new(:id, :seq, :flag, :bytes) do
      MORE = 0
      LAST = 1
      ABORT = 2

      def self.decode(reader)
        id = reader.varint32
        seq = reader.varint32
        flag = reader.u8
        raise DecodeError, "unknown chunk flag #{flag}" if flag > ABORT

        max = flag == ABORT ? Limits::MAX_ABORT_REASON : Limits::MAX_TRANSFER_CHUNK_BYTES
        new(id, seq, flag, reader.bytes(max, 'transfer chunk'))
      end

      def encode(writer)
        writer.varint(id).varint(seq).u8(flag).bytes(bytes)
      end
    end

    # A whole session message (`spec/01-transport.md` §3). One frame per
    # WebSocket binary message, and a text frame ends the session.
    class Frame
      HELLO    = 0x01
      WELCOME  = 0x02
      BATCH    = 0x03
      EVENT    = 0x04
      ACK      = 0x05
      PING     = 0x06
      PONG     = 0x07
      ERROR    = 0x08
      RESYNC   = 0x09
      VIEWPORT = 0x0A
      UPLOAD   = 0x0B
      BLOB     = 0x0C

      attr_reader :kind, :body

      def initialize(kind, body = nil)
        @kind = kind
        @body = body
      end

      class << self
        def hello(h)     = new(HELLO, h)
        def welcome(w)   = new(WELCOME, w)
        def batch(b)     = new(BATCH, b)
        def event(e)     = new(EVENT, e)
        def ack(seq)     = new(ACK, seq)
        def ping(nonce)  = new(PING, nonce)
        def pong(nonce)  = new(PONG, nonce)
        def error(code, message) = new(ERROR, [code, message])
        def resync       = new(RESYNC)
        def viewport(v)  = new(VIEWPORT, v)
        def upload(t)    = new(UPLOAD, t)
        def blob(t)      = new(BLOB, t)
      end

      # Decode a complete WebSocket message. Trailing bytes are an error:
      # a length that does not account for every byte of the message is how
      # one implementation's frame becomes another's smuggling channel.
      def self.decode(message)
        r = Reader.new(message)
        kind = r.u8
        len = r.varint
        raise DecodeError, 'frame length' if len > Limits::MAX_FRAME_BYTES

        payload = r.take(len)
        r.finish!
        p = Reader.new(payload)

        frame =
          case kind
          when HELLO
            version = p.varint32
            viewport = Viewport.decode(p)
            granted = p.varint32
            raise DecodeError, 'unknown capability bit' if (granted & ~Caps::ALL) != 0

            resume =
              case (tag = p.u8)
              when 0 then nil
              when 1 then Resume.new(p.take(16), p.varint)
              else raise DecodeError, "unknown resume tag #{tag}"
              end
            hello(Hello.new(version, viewport, granted, resume))
          when WELCOME
            version = p.varint32
            session = p.take(16)
            resumed = case p.u8
                      when 0 then false
                      when 1 then true
                      else raise DecodeError, 'resumed must be 0 or 1'
                      end
            welcome(Welcome.new(version, session, resumed))
          when BATCH then batch(Batch.decode(p))
          when EVENT
            node = p.varint32
            event = p.u8
            EventKind.name(event)
            event(EventFrame.new(node, event, p.varint32, Value.decode(p)))
          when ACK then ack(p.varint)
          when PING then ping(p.take(8))
          when PONG then pong(p.take(8))
          when ERROR then error(p.varint32, p.str(Limits::MAX_INLINE_STR, 'error message'))
          when RESYNC then resync
          when VIEWPORT then viewport(Viewport.decode(p))
          when UPLOAD then upload(Transfer.decode(p))
          when BLOB then blob(Transfer.decode(p))
          else raise DecodeError, "unknown frame kind #{kind}"
          end
        p.finish!
        frame
      end

      def encode
        body = Writer.new
        case @kind
        when HELLO
          body.varint(@body.version)
          @body.viewport.encode(body)
          body.varint(@body.granted)
          if @body.resume
            body.u8(1).raw(@body.resume.session).varint(@body.resume.acked)
          else
            body.u8(0)
          end
        when WELCOME
          body.varint(@body.version).raw(@body.session).u8(@body.resumed ? 1 : 0)
        when BATCH then @body.encode(body)
        when EVENT
          body.varint(@body.node).u8(@body.event).varint(@body.name)
          @body.payload.encode(body)
        when ACK then body.varint(@body)
        when PING, PONG then body.raw(@body)
        when ERROR then body.varint(@body[0]).str(@body[1])
        when RESYNC then nil
        when VIEWPORT then @body.encode(body)
        when UPLOAD, BLOB then @body.encode(body)
        else raise Error, "cannot encode frame kind #{@kind}"
        end

        payload = body.to_s
        out = Writer.new
        out.u8(@kind).varint(payload.bytesize).raw(payload)
        out.to_s
      end
    end
  end
end
