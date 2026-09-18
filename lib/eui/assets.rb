# frozen_string_literal: true

require_relative 'blake3'
require_relative 'errors'

module EUI
  # The content-addressed store behind `/_eui/asset/<blake3-hex>`.
  #
  # An asset is named by the hash of its bytes, so the name *is* the
  # content: the client recomputes it and discards a mismatch, a proxy may
  # serve it to anyone, and `immutable` is always the right cache header. A
  # file somebody uploaded is not an asset — that travels in the session
  # (`spec/01-transport.md` §6), because it is one person's and not the
  # same for everyone.
  class Assets
    TYPES = {
      '.png' => 'image/png', '.jpg' => 'image/jpeg', '.jpeg' => 'image/jpeg',
      '.gif' => 'image/gif', '.webp' => 'image/webp', '.svg' => 'image/svg+xml',
      '.ttf' => 'font/ttf', '.otf' => 'font/otf', '.woff2' => 'font/woff2',
      '.wav' => 'audio/wav', '.mp3' => 'audio/mpeg', '.ogg' => 'audio/ogg',
      '.mp4' => 'video/mp4', '.wgsl' => 'text/wgsl'
    }.freeze

    Entry = Struct.new(:bytes, :content_type)

    def initialize(root: Dir.pwd)
      @root = File.expand_path(root)
      @by_hash = {}
      @by_path = {}
      @lock = Mutex.new
    end

    # Take a file into the store and answer its hash. Cheap to call on
    # every render: a path whose mtime and size have not moved is not read
    # again.
    def add_file(path)
      full = File.expand_path(path, @root)
      unless full.start_with?(@root + File::SEPARATOR) || full == @root
        raise ViewError, "an asset must live under #{@root}, got #{path}"
      end
      raise ViewError, "no such asset: #{path}" unless File.file?(full)

      stat = File.stat(full)
      stamp = [stat.mtime.to_f, stat.size]
      @lock.synchronize do
        cached = @by_path[full]
        return cached[1] if cached && cached[0] == stamp

        bytes = File.binread(full)
        hash = Blake3.digest(bytes)
        @by_hash[hash] = Entry.new(bytes, TYPES.fetch(File.extname(full).downcase, 'application/octet-stream'))
        @by_path[full] = [stamp, hash]
        hash
      end
    end

    # Bytes that have no file — a picture out of a database, a chart this
    # process drew — reach a window the same way.
    def add_bytes(bytes, content_type: 'application/octet-stream')
      bytes = bytes.b
      hash = Blake3.digest(bytes)
      @lock.synchronize { @by_hash[hash] = Entry.new(bytes, content_type) }
      hash
    end

    def fetch(hex)
      return nil unless /\A[0-9a-f]{64}\z/.match?(hex)

      @lock.synchronize { @by_hash[[hex].pack('H*')] }
    end

    def size = @lock.synchronize { @by_hash.size }

    def self.hex(hash) = hash.unpack1('H*')
  end
end
