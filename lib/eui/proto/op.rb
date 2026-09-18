# frozen_string_literal: true

require_relative 'node'
require_relative 'style'

module EUI
  module Proto
    # One operation in a batch (`spec/02-wire-format.md` §5).
    #
    # Structural only. Whether an op is *coherent* — that the node it names
    # exists, that the atom it references was defined — is session state and
    # belongs to the session, not here.
    class Op
      DEF_ATOM       = 0x10
      DEF_STYLE      = 0x11
      DEF_COLOR      = 0x12
      DEF_CHUNK      = 0x13
      DEF_CHUNK_BYTES = 0x14
      DEF_FONT       = 0x15
      MOUNT          = 0x20
      REPLACE        = 0x21
      SET_STYLE      = 0x22
      SET_TEXT       = 0x23
      SET_PROP       = 0x24
      INSERT_CHILD   = 0x25
      REMOVE_CHILD   = 0x26
      MOVE_CHILD     = 0x27
      SET_HANDLER    = 0x28
      CLEAR_HANDLER  = 0x29
      FOCUS          = 0x2A
      SCROLL_TO      = 0x2B
      NOTIFY         = 0x2C

      attr_reader :opcode, :fields

      def initialize(opcode, fields = {})
        @opcode = opcode
        @fields = fields
      end

      def [](name) = @fields[name]

      class << self
        def def_atom(id, value)        = new(DEF_ATOM, id: id, value: value)
        def def_style(id, record)      = new(DEF_STYLE, id: id, record: record)
        def def_color(id, rgba)        = new(DEF_COLOR, id: id, rgba: rgba)
        def def_chunk(id, hash)        = new(DEF_CHUNK, id: id, hash: hash)
        def def_chunk_bytes(id, bytes) = new(DEF_CHUNK_BYTES, id: id, bytes: bytes)
        def def_font(role, faces)      = new(DEF_FONT, role: role, faces: faces)
        def mount(subtree)             = new(MOUNT, subtree: subtree)
        def replace(node, subtree)     = new(REPLACE, node: node, subtree: subtree)
        def set_style(node, style)     = new(SET_STYLE, node: node, style: style)
        def set_text(node, text)       = new(SET_TEXT, node: node, text: text)
        def set_prop(node, prop, value) = new(SET_PROP, node: node, prop: prop, value: value)
        def insert_child(parent, index, subtree) = new(INSERT_CHILD, parent: parent, index: index, subtree: subtree)
        def remove_child(parent, index, count)   = new(REMOVE_CHILD, parent: parent, index: index, count: count)
        def move_child(parent, from, to)         = new(MOVE_CHILD, parent: parent, from: from, to: to)
        def set_handler(node, event, handler)    = new(SET_HANDLER, node: node, event: event, handler: handler)
        def clear_handler(node, event)           = new(CLEAR_HANDLER, node: node, event: event)
        def focus(node)                          = new(FOCUS, node: node)
        def scroll_to(node, x, y)                = new(SCROLL_TO, node: node, x: x, y: y)
        def notify(title, body = '', tag = '')   = new(NOTIFY, title: title, body: body, tag: tag)
      end

      def self.decode(reader)
        case (opcode = reader.u8)
        when DEF_ATOM
          def_atom(nonzero(reader.varint32, 'atom id'), reader.str(Limits::MAX_ATOM_BYTES, 'atom value'))
        when DEF_STYLE
          def_style(nonzero(reader.varint32, 'style id'), StyleRecord.decode(reader))
        when DEF_COLOR
          def_color(nonzero(reader.varint32, 'color id'), reader.u32)
        when DEF_CHUNK
          def_chunk(nonzero(reader.varint32, 'chunk id'), reader.take(Limits::HASH_BYTES))
        when DEF_CHUNK_BYTES
          def_chunk_bytes(nonzero(reader.varint32, 'chunk id'), reader.bytes(Limits::MAX_CHUNK_BYTES, 'chunk bytes'))
        when DEF_FONT
          role = reader.u8
          raise DecodeError, 'font role' if role > Limits::MAX_FONT_ROLE

          count = reader.varint32
          raise DecodeError, 'a font role with no face' if count.zero?
          raise DecodeError, 'font faces' if count > Limits::MAX_FACES_PER_ROLE

          def_font(role, Array.new(count) { reader.take(Limits::HASH_BYTES) })
        when MOUNT then mount(Subtree.decode(reader))
        when REPLACE then replace(nonzero(reader.varint32, 'node id'), Subtree.decode(reader))
        when SET_STYLE then set_style(nonzero(reader.varint32, 'node id'), reader.varint32)
        when SET_TEXT then set_text(nonzero(reader.varint32, 'node id'), TextRef.decode(reader))
        when SET_PROP
          set_prop(nonzero(reader.varint32, 'node id'), reader.varint32, Value.decode(reader))
        when INSERT_CHILD
          insert_child(nonzero(reader.varint32, 'node id'), reader.varint32, Subtree.decode(reader))
        when REMOVE_CHILD
          remove_child(nonzero(reader.varint32, 'node id'), reader.varint32, reader.varint32)
        when MOVE_CHILD
          move_child(nonzero(reader.varint32, 'node id'), reader.varint32, reader.varint32)
        when SET_HANDLER
          node = nonzero(reader.varint32, 'node id')
          event = reader.u8
          EventKind.name(event)
          set_handler(node, event, Handler.decode(reader))
        when CLEAR_HANDLER
          node = nonzero(reader.varint32, 'node id')
          event = reader.u8
          EventKind.name(event)
          clear_handler(node, event)
        when FOCUS then focus(nonzero(reader.varint32, 'node id'))
        when SCROLL_TO then scroll_to(nonzero(reader.varint32, 'node id'), reader.svarint, reader.svarint)
        when NOTIFY
          notify(reader.str(Limits::MAX_NOTIFY_TITLE, 'notification title'),
                 reader.str(Limits::MAX_NOTIFY_BODY, 'notification body'),
                 reader.str(Limits::MAX_NOTIFY_TAG, 'notification tag'))
        else raise DecodeError, "unknown opcode #{opcode}"
        end
      end

      def self.nonzero(value, what)
        raise DecodeError, "#{what} must be non-zero" if value.zero?

        value
      end

      def encode(writer)
        f = @fields
        writer.u8(@opcode)
        case @opcode
        when DEF_ATOM then writer.varint(f[:id]).str(f[:value])
        when DEF_STYLE
          writer.varint(f[:id])
          f[:record].encode(writer)
        when DEF_COLOR then writer.varint(f[:id]).u32(f[:rgba])
        when DEF_CHUNK then writer.varint(f[:id]).raw(f[:hash])
        when DEF_CHUNK_BYTES then writer.varint(f[:id]).bytes(f[:bytes])
        when DEF_FONT
          writer.u8(f[:role]).varint(f[:faces].length)
          f[:faces].each { |face| writer.raw(face) }
        when MOUNT then f[:subtree].encode(writer)
        when REPLACE
          writer.varint(f[:node])
          f[:subtree].encode(writer)
        when SET_STYLE then writer.varint(f[:node]).varint(f[:style])
        when SET_TEXT
          writer.varint(f[:node])
          f[:text].encode(writer)
        when SET_PROP
          writer.varint(f[:node]).varint(f[:prop])
          f[:value].encode(writer)
        when INSERT_CHILD
          writer.varint(f[:parent]).varint(f[:index])
          f[:subtree].encode(writer)
        when REMOVE_CHILD then writer.varint(f[:parent]).varint(f[:index]).varint(f[:count])
        when MOVE_CHILD then writer.varint(f[:parent]).varint(f[:from]).varint(f[:to])
        when SET_HANDLER
          writer.varint(f[:node]).u8(f[:event])
          f[:handler].encode(writer)
        when CLEAR_HANDLER then writer.varint(f[:node]).u8(f[:event])
        when FOCUS then writer.varint(f[:node])
        when SCROLL_TO then writer.varint(f[:node]).svarint(f[:x]).svarint(f[:y])
        when NOTIFY then writer.str(f[:title]).str(f[:body]).str(f[:tag])
        else raise Error, "cannot encode opcode #{@opcode}"
        end
        writer
      end

      def ==(other)
        other.is_a?(Op) && other.opcode == @opcode && other.fields == @fields
      end
    end

    # An ordered run of ops carrying a sequence number. The client acks the
    # last one it applied, and applies a batch all or nothing.
    Batch = Struct.new(:seq, :ops) do
      def self.decode(reader)
        seq = reader.varint
        count = reader.varint32_max(Limits::MAX_OPS_PER_BATCH, 'ops per batch')
        notifications = 0
        ops = Array.new(count) do
          op = Op.decode(reader)
          if op.opcode == Op::NOTIFY
            notifications += 1
            raise DecodeError, 'notifications per batch' if notifications > Limits::MAX_NOTIFY_PER_BATCH
          end
          op
        end
        new(seq, ops)
      end

      def encode(writer)
        writer.varint(seq).varint(ops.length)
        ops.each { |op| op.encode(writer) }
        writer
      end
    end
  end
end
