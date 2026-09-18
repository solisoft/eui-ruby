# frozen_string_literal: true

require_relative 'limits'
require_relative '../errors'

module EUI
  module Proto
    # A cursor over bytes that refuses anything it was not promised.
    #
    # Two rules do most of the work: a varint must be minimally encoded, and
    # a frame must account for every byte it declared. Both are the classic
    # route to a parser disagreeing with itself.
    class Reader
      def initialize(bytes)
        @bytes = bytes.b
        @pos = 0
      end

      def remaining
        @bytes.bytesize - @pos
      end

      def eof?
        remaining.zero?
      end

      def take(count)
        raise DecodeError, "short read: wanted #{count}, #{remaining} left" if count > remaining

        slice = @bytes.byteslice(@pos, count)
        @pos += count
        slice
      end

      def u8
        take(1).unpack1('C')
      end

      def u16
        take(2).unpack1('v')
      end

      def u32
        take(4).unpack1('V')
      end

      def u64
        take(8).unpack1('Q<')
      end

      def f64
        value = take(8).unpack1('E')
        raise DecodeError, 'float must be finite' unless value.finite?

        value
      end

      def array(count)
        take(count)
      end

      # LEB128, and only the minimal spelling of it: a multi-byte encoding
      # whose last byte is `0x00` is an error rather than a normalisation.
      def varint(max_bytes = 10)
        value = 0
        shift = 0
        count = 0
        loop do
          byte = u8
          count += 1
          raise DecodeError, 'varint too long' if count > max_bytes

          value |= (byte & 0x7F) << shift
          break if (byte & 0x80).zero?
          raise DecodeError, 'non-minimal varint' if count == max_bytes

          shift += 7
        end
        raise DecodeError, 'non-minimal varint' if count > 1 && value < (1 << (7 * (count - 1)))

        value
      end

      def varint32
        value = varint(5)
        raise DecodeError, 'varint overflows u32' if value > 0xFFFF_FFFF

        value
      end

      def varint32_max(max, what)
        value = varint32
        raise DecodeError, "#{what} above #{max}" if value > max

        value
      end

      def svarint
        raw = varint(10)
        (raw >> 1) ^ -(raw & 1)
      end

      def bytes(max, what)
        len = varint32
        raise DecodeError, "#{what} of #{len} bytes, at most #{max}" if len > max

        take(len)
      end

      def str(max, what)
        value = bytes(max, what).force_encoding(Encoding::UTF_8)
        raise DecodeError, "#{what} is not valid UTF-8" unless value.valid_encoding?

        value
      end

      # Trailing bytes are an error, not padding.
      def finish!
        raise DecodeError, "#{remaining} trailing bytes" unless eof?

        self
      end
    end
  end
end
