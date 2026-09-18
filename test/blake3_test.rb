# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

# BLAKE3, against the official vectors.
#
# An asset's name *is* its content, so this is the one piece of arithmetic
# in the library a client will disagree with loudly: a hash that is wrong
# by a bit means every image in the application 404s.
class Blake3Test < Minitest::Test
  include TestHelpers

  # The input of length n is the bytes 0, 1, 2 … 250 repeating, which is
  # what the BLAKE3 test vectors use.
  VECTORS = {
      0 => 'af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262',
      63 => 'e9bc37a594daad83be9470df7f7b3798297c3d834ce80ba85d6e207627b7db7b',
      64 => '4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98',
      65 => 'de1e5fa0be70df6d2be8fffd0e99ceaa8eb6e8c93a63f2d8d1c30ecb6b263dee',
      1023 => '10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11',
      1024 => '42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7',
      1025 => 'd00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444',
      2048 => 'e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a',
      2049 => '5f4d72f40d7a5f82b15ca2b2e44b1de3c2ef86c426c95c1af0b6879522563030',
      3000 => '5fade288bf27444bee55ba2babb98c3c922c1e84c2e445e7d1f6da24756f5060',
      4096 => '015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969',
      10000 => '5f81f9e4ab67627b6b036d5d4e3bc40d9d3daa6fcc2b6dd07ab2bbf0a877da54',
      65536 => '68d647e619a930e7b1082f74f334b0c65a315725569bdc123f0ee11881717bfe',
  }.freeze

  def pattern(length) = (0...length).map { |i| i % 251 }.pack('C*')

  def test_the_vectors
    VECTORS.each do |length, want|
      assert_equal want, EUI::Blake3.hexdigest(pattern(length)), "length #{length}"
    end
  end

  def test_abc
    assert_equal '6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85',
                 EUI::Blake3.hexdigest('abc')
  end

  # A chunk is 1024 bytes and a block is 64: fed in sevens, every boundary
  # falls somewhere awkward, which is where a streaming hash breaks.
  def test_streaming_matches_one_shot
    data = pattern(3000)
    hasher = EUI::Blake3::Hasher.new
    data.each_char.each_slice(7) { |slice| hasher.update(slice.join) }
    assert_equal EUI::Blake3.hexdigest(data), hasher.hexdigest
  end

  def test_a_file_hashes_as_its_bytes
    path = File.join(Dir.tmpdir, "eui-blake3-#{Process.pid}.bin")
    File.binwrite(path, pattern(5000))
    assert_equal EUI::Blake3.hexdigest(pattern(5000)), EUI::Blake3.file(path).unpack1('H*')
  ensure
    File.unlink(path) if path && File.exist?(path)
  end
end
