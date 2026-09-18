# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

# The manifest: what a client reads before it opens a session, and the
# signature that makes trust-on-first-use mean anything.
class ManifestTest < Minitest::Test
  include TestHelpers

  def key = @key ||= OpenSSL::PKey.generate_key('ED25519')

  def manifest(**overrides)
    EUI::Manifest.new(**{ app_id: 'counter.test', name: 'Counter', key: key,
                          entry: '/_eui/session/counter' }.merge(overrides))
  end

  def test_the_record_is_signed_over_everything_but_the_signature
    m = manifest
    bytes = m.encode
    assert_equal 'EUIM', bytes[0, 4]
    assert_equal 1, bytes[4].unpack1('C'), 'record version'

    signature = [bytes.byteslice(bytes.bytesize - 128, 128)].pack('H*')
    public_key = OpenSSL::PKey.new_raw_public_key('ED25519', key.raw_public_key)
    assert public_key.verify(nil, signature, m.signed_bytes)
    refute public_key.verify(nil, signature, m.signed_bytes + 'x')
  end

  def test_the_fields_are_in_key_order
    r = EUI::Proto::Reader.new(manifest.encode)
    r.take(4)
    r.u8
    count = r.varint
    assert_equal 11, count, 'a manifest has exactly eleven fields'
    count.times do |expected|
      assert_equal expected, r.varint, 'fields are in key order'
      EUI::Proto::Value.decode(r)
    end
    r.finish!
  end

  def test_capabilities_are_a_bitset_of_names
    m = manifest(capabilities: %w[net.open notifications])
    assert_equal EUI::Proto::Caps::NET_OPEN | EUI::Proto::Caps::NOTIFICATIONS, m.capabilities
    assert_equal %w[notifications net.open], m.capability_names
  end

  def test_a_publisher_key_is_made_once_and_kept
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config', 'eui_publisher.pem')
      first = EUI::Manifest.publisher_key(path)
      assert File.exist?(path)
      assert_equal 0o600, File.stat(path).mode & 0o777, 'whoever holds it can publish as this application'
      assert_equal first.raw_public_key, EUI::Manifest.publisher_key(path).raw_public_key
    end
  end

  def test_a_string_field_is_bounded
    assert_raises(EUI::Error) { manifest(name: 'x' * 300).encode }
  end
end
