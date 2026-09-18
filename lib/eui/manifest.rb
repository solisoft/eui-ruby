# frozen_string_literal: true

require 'openssl'
require 'fileutils'
require_relative 'proto'
require_relative 'assets'

module EUI
  # The application manifest served at `/.well-known/eui`
  # (`spec/01-transport.md` §2.1): an `EUIM` record, signed by the
  # publisher, that a client reads before it opens a session.
  #
  # The signature is what makes trust-on-first-use mean anything: the
  # client pins `publisher_key` against `app_id` on first run and refuses a
  # different one later. So the key belongs to the *application*, not to a
  # deployment — keep the file, and keep it out of the repository.
  class Manifest
    MAGIC = 'EUIM'
    RECORD_VERSION = 1
    MAX_STR = 256

    KEY = {
      app_id: 0, name: 1, version: 2, protocol_min: 3, protocol_max: 4,
      publisher_key: 5, capabilities: 6, theme: 7, entry: 8, rotation: 9,
      signature: 10
    }.freeze

    attr_accessor :app_id, :name, :version, :protocol_min, :protocol_max,
                  :capabilities, :theme, :entry

    def initialize(app_id:, name:, key:, version: '0.1.0', entry: '/_eui/session',
                   capabilities: 0, theme: nil, protocol_min: 1, protocol_max: Proto::PROTOCOL_VERSION)
      @app_id = app_id
      @name = name
      @version = version
      @key = key
      @entry = entry
      @capabilities = capabilities.is_a?(Integer) ? capabilities : Proto::Caps.mask(capabilities)
      @theme = theme
      @protocol_min = protocol_min
      @protocol_max = protocol_max
    end

    # An Ed25519 key kept on disk, generated on first use. Never committed:
    # whoever holds it can publish as this application.
    def self.publisher_key(path)
      if File.exist?(path)
        OpenSSL::PKey.read(File.read(path))
      else
        key = OpenSSL::PKey.generate_key('ED25519')
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, key.private_to_pem)
        File.chmod(0o600, path)
        key
      end
    end

    def public_key_hex = @key.raw_public_key.unpack1('H*')

    # The bytes the publisher signs: every field but the signature. A
    # decoder rebuilds them exactly, because the order is fixed.
    def signed_bytes = write(nil)

    def encode
      write(@key.sign(nil, signed_bytes))
    end

    # The capability names this application asks for. Being granted them is
    # a separate act, and one this server never hears the answer to unless
    # the client reports it in its Hello.
    def capability_names = Proto::Caps.names(@capabilities)

    private

    def write(signature)
      fields = [
        [KEY[:app_id], Proto::Value.str(check(@app_id, 'app_id'))],
        [KEY[:name], Proto::Value.str(check(@name, 'name'))],
        [KEY[:version], Proto::Value.str(check(@version, 'version'))],
        [KEY[:protocol_min], Proto::Value.int(@protocol_min)],
        [KEY[:protocol_max], Proto::Value.int(@protocol_max)],
        [KEY[:publisher_key], Proto::Value.str(public_key_hex)],
        [KEY[:capabilities], Proto::Value.int(@capabilities)],
        [KEY[:theme], @theme ? Proto::Value.str(Assets.hex(@theme)) : Proto::Value.null],
        [KEY[:entry], Proto::Value.str(check(@entry, 'entry'))],
        # No rotation: this key has never been anything else. When one is
        # needed it is the previous key and its signature over the new one,
        # and the client's pin moves rather than the session failing.
        [KEY[:rotation], Proto::Value.null]
      ]
      fields << [KEY[:signature], Proto::Value.str(signature.unpack1('H*'))] if signature

      w = Proto::Writer.new
      w.raw(MAGIC).u8(RECORD_VERSION).varint(fields.length)
      fields.each do |(k, v)|
        w.varint(k)
        v.encode(w)
      end
      w.to_s
    end

    def check(value, what)
      string = value.to_s
      raise Error, "manifest #{what} is at most #{MAX_STR} bytes" if string.bytesize > MAX_STR

      string
    end
  end
end
