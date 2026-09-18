# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'minitest/autorun'
require 'eui'

module TestHelpers
  # Bytes as a hex string, so a failing assertion prints something a person
  # can compare against the spec.
  def hex(bytes) = bytes.b.unpack1('H*')

  def encode(op)
    w = EUI::Proto::Writer.new
    op.encode(w)
    w.to_s
  end

  def reader(bytes) = EUI::Proto::Reader.new(bytes)
end
