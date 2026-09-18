# frozen_string_literal: true

module EUI
  module Proto
    # An append-only byte buffer with the protocol's primitives on it
    # (`spec/02-wire-format.md` §1). Every method returns `self`, so an
    # encoder reads as one sentence.
    class Writer
      attr_reader :buffer

      def initialize
        @buffer = +''
        @buffer.force_encoding(Encoding::BINARY)
      end

      def u8(value)
        @buffer << (value & 0xFF).chr
        self
      end

      def u16(value)
        @buffer << [value & 0xFFFF].pack('v')
        self
      end

      def u32(value)
        @buffer << [value & 0xFFFF_FFFF].pack('V')
        self
      end

      def u64(value)
        @buffer << [value & 0xFFFF_FFFF_FFFF_FFFF].pack('Q<')
        self
      end

      def f64(value)
        @buffer << [value].pack('E')
        self
      end

      # LEB128, minimally encoded. A decoder rejects any other spelling of
      # the same number, so there is only ever one.
      def varint(value)
        raise Error, "varint cannot carry #{value}" if value.negative?

        loop do
          byte = value & 0x7F
          value >>= 7
          if value.zero?
            @buffer << byte.chr
            break
          end
          @buffer << (byte | 0x80).chr
        end
        self
      end

      # LEB128 over zigzag: the sign rides in the low bit, so a small
      # negative number costs one byte like a small positive one.
      def svarint(value)
        varint((value << 1) ^ (value >> 63))
      end

      def bytes(str)
        str = str.b
        varint(str.bytesize)
        @buffer << str
        self
      end

      def str(value)
        bytes(value.to_s.encode(Encoding::UTF_8).b)
      end

      def raw(str)
        @buffer << str.b
        self
      end

      def size
        @buffer.bytesize
      end

      def to_s
        @buffer
      end
    end
  end
end
