# frozen_string_literal: true

module EUI
  # Anything this library raises on its own.
  class Error < StandardError; end

  # Bytes that are not a legal encoding of what they claim to be.
  #
  # The decoder refuses rather than repairs: a non-minimal varint, a value
  # outside an enumeration, a length that does not account for every byte.
  # "Ignore what you don't understand" is how one implementation's frame
  # becomes another's smuggling channel.
  class DecodeError < Error; end

  # A view the protocol has no way to carry: an unknown style key, a colour
  # role nobody defined, a tree deeper than the client accepts. Raised while
  # encoding, which is the only moment at which the author can still fix it.
  class ViewError < Error; end
end
