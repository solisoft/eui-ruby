# frozen_string_literal: true

module EUI
  # BLAKE3, in Ruby, because an asset is named by the hash of its content
  # and the client recomputes it (`spec/01-transport.md` §2.2).
  #
  # Only the plain hash: no keyed mode, no key derivation, no extendable
  # output past 32 bytes. That is every use the protocol has for it — an
  # asset's name — and each of the others is a footgun this library would
  # rather not carry.
  module Blake3
    OUT_LEN = 32
    BLOCK_LEN = 64
    CHUNK_LEN = 1024

    CHUNK_START = 1 << 0
    CHUNK_END   = 1 << 1
    PARENT      = 1 << 2
    ROOT        = 1 << 3

    IV = [
      0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
      0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
    ].freeze

    MSG_PERMUTATION = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8].freeze

    MASK = 0xFFFF_FFFF

    class << self
      def hexdigest(data) = digest(data).unpack1('H*')

      def digest(data)
        hasher = Hasher.new
        hasher.update(data)
        hasher.digest
      end

      def file(path)
        hasher = Hasher.new
        File.open(path, 'rb') do |io|
          while (block = io.read(65_536))
            hasher.update(block)
          end
        end
        hasher.digest
      end

      def rotr(x, n) = ((x >> n) | (x << (32 - n))) & MASK

      def g(state, a, b, c, d, mx, my)
        state[a] = (state[a] + state[b] + mx) & MASK
        state[d] = rotr(state[d] ^ state[a], 16)
        state[c] = (state[c] + state[d]) & MASK
        state[b] = rotr(state[b] ^ state[c], 12)
        state[a] = (state[a] + state[b] + my) & MASK
        state[d] = rotr(state[d] ^ state[a], 8)
        state[c] = (state[c] + state[d]) & MASK
        state[b] = rotr(state[b] ^ state[c], 7)
      end

      def round(state, m)
        g(state, 0, 4, 8, 12, m[0], m[1])
        g(state, 1, 5, 9, 13, m[2], m[3])
        g(state, 2, 6, 10, 14, m[4], m[5])
        g(state, 3, 7, 11, 15, m[6], m[7])
        g(state, 0, 5, 10, 15, m[8], m[9])
        g(state, 1, 6, 11, 12, m[10], m[11])
        g(state, 2, 7, 8, 13, m[12], m[13])
        g(state, 3, 4, 9, 14, m[14], m[15])
      end

      # The one primitive: a chaining value and a block in, sixteen words
      # out. The first eight are the next chaining value; all sixteen are
      # the root's output.
      def compress(cv, block, counter, block_len, flags)
        state = [
          cv[0], cv[1], cv[2], cv[3], cv[4], cv[5], cv[6], cv[7],
          IV[0], IV[1], IV[2], IV[3],
          counter & MASK, (counter >> 32) & MASK, block_len, flags
        ]
        m = block
        7.times do |r|
          round(state, m)
          m = MSG_PERMUTATION.map { |i| m[i] } if r < 6
        end
        8.times do |i|
          state[i] ^= state[i + 8]
          state[i + 8] ^= cv[i]
        end
        state
      end

      def words_of(block)
        block = block.ljust(BLOCK_LEN, "\x00") if block.bytesize < BLOCK_LEN
        block.unpack('V16')
      end

      def parent_output(left, right, flags)
        Output.new(IV.dup, left + right, 0, BLOCK_LEN, PARENT | flags)
      end

      def parent_cv(left, right, flags) = parent_output(left, right, flags).chaining_value
    end

    # A node's output, before anybody has decided whether it is the root.
    # Which it is changes the flags, and so changes the bytes: that is what
    # keeps a chunk's hash from being a tree's hash.
    Output = Struct.new(:input_cv, :block_words, :counter, :block_len, :flags) do
      def chaining_value
        Blake3.compress(input_cv, block_words, counter, block_len, flags)[0, 8]
      end

      def root_bytes(length = OUT_LEN)
        out = +''
        counter = 0
        while out.bytesize < length
          words = Blake3.compress(input_cv, block_words, counter, block_len, flags | ROOT)
          out << words.pack('V16')
          counter += 1
        end
        out.byteslice(0, length)
      end
    end

    # One chunk of at most 1024 bytes, compressed a block at a time.
    class ChunkState
      attr_reader :chunk_counter

      def initialize(key, chunk_counter, flags)
        @cv = key.dup
        @chunk_counter = chunk_counter
        @block = +''
        @block.force_encoding(Encoding::BINARY)
        @blocks_compressed = 0
        @flags = flags
      end

      def length = (BLOCK_LEN * @blocks_compressed) + @block.bytesize

      def start_flag = @blocks_compressed.zero? ? CHUNK_START : 0

      def update(input)
        offset = 0
        while offset < input.bytesize
          if @block.bytesize == BLOCK_LEN
            @cv = Blake3.compress(@cv, Blake3.words_of(@block), @chunk_counter, BLOCK_LEN, @flags | start_flag)[0, 8]
            @blocks_compressed += 1
            @block = +''
            @block.force_encoding(Encoding::BINARY)
          end
          want = BLOCK_LEN - @block.bytesize
          take = [want, input.bytesize - offset].min
          @block << input.byteslice(offset, take)
          offset += take
        end
        self
      end

      def output
        Output.new(@cv, Blake3.words_of(@block), @chunk_counter, @block.bytesize, @flags | start_flag | CHUNK_END)
      end
    end

    # The streaming hasher. Chunks are merged into a binary tree as they
    # complete, so hashing a 200 MB file costs a stack of at most 54
    # chaining values.
    class Hasher
      def initialize(key: IV.dup, flags: 0)
        @key = key
        @flags = flags
        @chunk = ChunkState.new(key, 0, flags)
        @stack = []
      end

      def update(input)
        input = input.b
        offset = 0
        while offset < input.bytesize
          if @chunk.length == CHUNK_LEN
            add_chunk(@chunk.output.chaining_value, @chunk.chunk_counter + 1)
            @chunk = ChunkState.new(@key, @chunk.chunk_counter + 1, @flags)
          end
          want = CHUNK_LEN - @chunk.length
          take = [want, input.bytesize - offset].min
          @chunk.update(input.byteslice(offset, take))
          offset += take
        end
        self
      end

      def digest(length = OUT_LEN)
        output = @chunk.output
        @stack.reverse_each do |left|
          output = Blake3.parent_output(left, output.chaining_value, @flags)
        end
        output.root_bytes(length)
      end

      def hexdigest(length = OUT_LEN) = digest(length).unpack1('H*')

      private

      # A chunk's chaining value joins the tree, merging with everything to
      # its left that is now complete — which is what the low bits of the
      # chunk count say.
      def add_chunk(cv, total_chunks)
        while (total_chunks & 1).zero?
          cv = Blake3.parent_cv(@stack.pop, cv, @flags)
          total_chunks >>= 1
        end
        @stack.push(cv)
      end
    end
  end
end
