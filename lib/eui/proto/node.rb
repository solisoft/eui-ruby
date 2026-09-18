# frozen_string_literal: true

require_relative 'limits'
require_relative 'style'

module EUI
  module Proto
    # The closed set of primitive node kinds (`spec/02-wire-format.md` §4.1).
    #
    # Everything a person would call a widget — button, dialog, table, date
    # picker — is composed from these on the server, which is why the
    # catalogue grows without shipping a new client.
    module NodeKind
      BY_NAME = {
        'box' => 0x01, 'text' => 0x02, 'image' => 0x03, 'icon' => 0x04,
        'input' => 0x05, 'textarea' => 0x06, 'scroll' => 0x07, 'list' => 0x08,
        'canvas' => 0x09, 'spacer' => 0x0A, 'divider' => 0x0B, 'overlay' => 0x0C,
        'slot' => 0x0D, 'sizer' => 0x0E, 'audio' => 0x0F, 'video' => 0x10,
        'scene' => 0x11
      }.freeze
      BY_CODE = BY_NAME.invert.freeze

      LEAF  = %w[text icon spacer divider audio video scene].map { |n| BY_NAME[n] }.freeze
      INERT = %w[spacer divider].map { |n| BY_NAME[n] }.freeze

      def self.code(name)
        BY_NAME.fetch(name.to_s) { raise ViewError, "unknown node kind '#{name}'" }
      end

      def self.name(code)
        BY_CODE.fetch(code) { raise DecodeError, "unknown node kind #{code}" }
      end

      def self.leaf?(code)  = LEAF.include?(code)
      def self.inert?(code) = INERT.include?(code)
    end

    # Input and lifecycle events (`spec/06-events.md`).
    module EventKind
      BY_NAME = {
        'click' => 0x01, 'double_click' => 0x02, 'pointer_down' => 0x03, 'pointer_up' => 0x04,
        'pointer_move' => 0x05, 'pointer_enter' => 0x06, 'pointer_leave' => 0x07,
        'key_down' => 0x08, 'key_up' => 0x09, 'text_input' => 0x0A, 'focus' => 0x0B,
        'blur' => 0x0C, 'change' => 0x0D, 'submit' => 0x0E, 'scroll' => 0x0F,
        'resize' => 0x10, 'context_menu' => 0x11, 'drag_start' => 0x12, 'drag_over' => 0x13,
        'drop' => 0x14, 'long_press' => 0x15, 'window' => 0x16, 'ended' => 0x17,
        'time_update' => 0x18, 'wake' => 0x19, 'file_pick' => 0x1A, 'file_save' => 0x1B,
        'location' => 0x1C, 'nfc_tag' => 0x1D, 'file_drag' => 0x1E, 'back' => 0x1F,
        'level' => 0x20
      }.freeze
      BY_CODE = BY_NAME.invert.freeze

      # The protocol version an event arrived in: an event a client cannot
      # decode is left out at encode time rather than sent, so the view still
      # renders and the widget simply never hears from it.
      SINCE = { 0x20 => 3 }.freeze

      def self.code(name)
        BY_NAME.fetch(name.to_s) { raise ViewError, "unknown event '#{name}'" }
      end

      def self.name(code)
        BY_CODE.fetch(code) { raise DecodeError, "unknown event kind #{code}" }
      end

      def self.since(code) = SINCE.fetch(code, 1)
    end

    # A string: interned in the session's atom table, or carried inline.
    TextRef = Struct.new(:atom, :inline) do
      def self.atom_ref(id) = new(Integer(id), nil)
      def self.inline_ref(s) = new(nil, s.to_s)

      def self.decode(reader)
        case (tag = reader.u8)
        when 0x00 then atom_ref(reader.varint32)
        when 0x01 then inline_ref(reader.str(Limits::MAX_INLINE_STR, 'inline string'))
        else raise DecodeError, "unknown TextRef tag #{tag}"
        end
      end

      def encode(writer)
        if atom
          writer.u8(0x00).varint(atom)
        else
          writer.u8(0x01).str(inline)
        end
      end
    end

    # A property value (`spec/02-wire-format.md` §4.4).
    #
    # Tagged rather than inferred from the Ruby object: a string may be an
    # atom or an inline run, and 32 bytes may be an asset hash or a label.
    class Value
      NULL   = 0x00
      BOOL   = 0x01
      INT    = 0x02
      FLOAT  = 0x03
      ATOM   = 0x04
      STR    = 0x05
      ASSET  = 0x06
      COLOR  = 0x07
      LIST   = 0x08

      attr_reader :tag, :value

      def initialize(tag, value = nil)
        @tag = tag
        @value = value
      end

      class << self
        def null          = new(NULL)
        def bool(b)       = new(BOOL, b ? true : false)
        def int(n)        = new(INT, Integer(n))
        def float(f)
          f = Float(f)
          raise ViewError, 'a float on the wire must be finite' unless f.finite?

          new(FLOAT, f)
        end
        def atom(id)      = new(ATOM, Integer(id))
        def str(s)        = new(STR, s.to_s)
        def asset(hash)
          raise ViewError, 'an asset is 32 bytes' unless hash.bytesize == Limits::HASH_BYTES

          new(ASSET, hash.b)
        end
        def color(ref)    = new(COLOR, ref)
        def list(items)   = new(LIST, items)

        # A plain Ruby value as the wire would carry it. Strings go inline:
        # interning is the encoder's decision, not this one's.
        def from(ruby)
          case ruby
          when nil then null
          when true, false then bool(ruby)
          when Integer then int(ruby)
          when Float then float(ruby)
          when String, Symbol then str(ruby.to_s)
          when ColorRef then color(ruby)
          when Array then list(ruby.map { |i| from(i) })
          when Value then ruby
          else raise ViewError, "a prop cannot carry #{ruby.class}"
          end
        end
      end

      def self.decode(reader, depth = 1)
        raise DecodeError, 'value nesting' if depth > Limits::MAX_VALUE_DEPTH

        case (tag = reader.u8)
        when NULL then null
        when BOOL
          case reader.u8
          when 0 then bool(false)
          when 1 then bool(true)
          else raise DecodeError, 'bool must be 0 or 1'
          end
        when INT then int(reader.svarint)
        when FLOAT then float(reader.f64)
        when ATOM then atom(reader.varint32)
        when STR then str(reader.str(Limits::MAX_INLINE_STR, 'inline string'))
        when ASSET then asset(reader.take(Limits::HASH_BYTES))
        when COLOR then color(ColorRef.new(reader.u16))
        when LIST
          count = reader.varint32_max(Limits::MAX_VALUE_LIST, 'value list length')
          list(Array.new(count) { decode(reader, depth + 1) })
        else raise DecodeError, "unknown Value tag #{tag}"
        end
      end

      def encode(writer)
        case @tag
        when NULL  then writer.u8(NULL)
        when BOOL  then writer.u8(BOOL).u8(@value ? 1 : 0)
        when INT   then writer.u8(INT).svarint(@value)
        when FLOAT then writer.u8(FLOAT).f64(@value)
        when ATOM  then writer.u8(ATOM).varint(@value)
        when STR   then writer.u8(STR).str(@value)
        when ASSET then writer.u8(ASSET).raw(@value)
        when COLOR then writer.u8(COLOR).u16(@value.bits)
        when LIST
          writer.u8(LIST).varint(@value.length)
          @value.each { |item| item.encode(writer) }
        end
        writer
      end

      # What a handler sees: plain Ruby, with atoms left as their ids for
      # the session to resolve against its own table.
      def to_ruby
        case @tag
        when NULL then nil
        when LIST then @value.map(&:to_ruby)
        when COLOR then @value
        else @value
        end
      end

      def ==(other)
        other.is_a?(Value) && other.tag == @tag && other.value == @value
      end
      alias eql? ==

      def hash = [@tag, @value].hash
    end

    # What an event does when it happens.
    Handler = Struct.new(:kind, :chunk, :name) do
      SERVER = 0x00
      LOCAL  = 0x01
      BOTH   = 0x02

      # Round trip: the client emits an `Event` frame naming this atom.
      def self.server(atom) = new(SERVER, nil, Integer(atom))
      # Runs entirely on the client, in the metered VM. No network traffic.
      def self.local(chunk) = new(LOCAL, Integer(chunk), nil)
      # Runs locally for the immediate feedback, then tells the server.
      def self.local_then_server(chunk, atom) = new(BOTH, Integer(chunk), Integer(atom))

      def self.decode(reader)
        case (tag = reader.u8)
        when SERVER then server(reader.varint32)
        when LOCAL then local(reader.varint32)
        when BOTH then local_then_server(reader.varint32, reader.varint32)
        else raise DecodeError, "unknown Handler tag #{tag}"
        end
      end

      def encode(writer)
        case kind
        when SERVER then writer.u8(SERVER).varint(name)
        when LOCAL then writer.u8(LOCAL).varint(chunk)
        when BOTH then writer.u8(BOTH).varint(chunk).varint(name)
        end
      end
    end

    # One node of a subtree, with its props and handlers held as ranges into
    # the owning [Subtree]'s side arrays.
    FlatNode = Struct.new(:kind, :id, :style, :key, :text, :props, :handlers, :child_count, keyword_init: true)

    # A subtree, stored pre-order.
    #
    # Reconstructing the shape needs nothing but `child_count`: a node's
    # first child is the next entry, and its next sibling is found by
    # skipping that child's own descendants. Decoding is iterative, so a
    # hostile 10 000-deep tree costs a bounds check rather than the stack.
    class Subtree
      attr_reader :nodes, :props, :handlers

      def initialize
        @nodes = []
        @props = []
        @handlers = []
      end

      def root = @nodes.first

      def props_of(node)
        start, len = node.props
        @props[start, len] || []
      end

      def handlers_of(node)
        start, len = node.handlers
        @handlers[start, len] || []
      end

      def push(kind:, id:, style:, key: 0, text: nil, props: [], handlers: [], child_count: 0)
        prop_start = @props.length
        @props.concat(props)
        handler_start = @handlers.length
        @handlers.concat(handlers)
        @nodes << FlatNode.new(
          kind: kind, id: id, style: style, key: key, text: text,
          props: [prop_start, props.length], handlers: [handler_start, handlers.length],
          child_count: child_count
        )
        self
      end

      def self.decode(reader)
        out = new
        pending = []
        loop do
          raise DecodeError, 'node count' if out.nodes.length >= Limits::MAX_NODES

          child_count = out.send(:decode_one, reader)
          if child_count.positive?
            raise DecodeError, 'tree depth' if pending.length >= Limits::MAX_TREE_DEPTH

            pending << child_count
          else
            while (top = pending.last)
              pending[-1] = top - 1
              break unless pending[-1].zero?

              pending.pop
            end
          end
          return out if pending.empty?
        end
      end

      def encode(writer)
        @nodes.each do |node|
          props = props_of(node)
          handlers = handlers_of(node)

          flags = 0
          flags |= 0x01 unless node.key.zero?
          flags |= 0x02 if node.text
          flags |= 0x04 unless props.empty?
          flags |= 0x08 unless handlers.empty?

          writer.u8(node.kind).u8(flags).varint(node.id).varint(node.style)
          writer.varint(node.key) unless node.key.zero?
          node.text&.encode(writer)
          unless props.empty?
            writer.varint(props.length)
            props.each do |(atom, value)|
              writer.varint(atom)
              value.encode(writer)
            end
          end
          unless handlers.empty?
            writer.varint(handlers.length)
            handlers.each do |(event, handler)|
              writer.u8(event)
              handler.encode(writer)
            end
          end
          writer.varint(node.child_count)
        end
        writer
      end

      private

      def decode_one(reader)
        kind = reader.u8
        NodeKind.name(kind)
        flags = reader.u8
        raise DecodeError, 'reserved node flags set' if (flags & 0xF0) != 0

        id = reader.varint32
        raise DecodeError, 'node id must be non-zero' if id.zero?

        style = reader.varint32
        key = (flags & 0x01).zero? ? 0 : reader.varint32
        text = (flags & 0x02).zero? ? nil : TextRef.decode(reader)

        props = []
        unless (flags & 0x04).zero?
          count = reader.varint32_max(Limits::MAX_PROPS, 'props per node')
          count.times { props << [reader.varint32, Value.decode(reader)] }
        end

        handlers = []
        unless (flags & 0x08).zero?
          count = reader.varint32_max(Limits::MAX_HANDLERS, 'handlers per node')
          count.times do
            event = reader.u8
            EventKind.name(event) # refuse one this revision does not define
            handlers << [event, Handler.decode(reader)]
          end
        end

        if NodeKind.inert?(kind) && (text || !props.empty? || !handlers.empty?)
          raise DecodeError, 'inert node kind carries content'
        end

        child_count = reader.varint32_max(Limits::MAX_CHILDREN, 'children per node')
        raise DecodeError, 'a leaf kind carries children' if NodeKind.leaf?(kind) && child_count.positive?

        push(kind: kind, id: id, style: style, key: key, text: text, props: props,
             handlers: handlers, child_count: child_count)
        child_count
      end
    end
  end
end
