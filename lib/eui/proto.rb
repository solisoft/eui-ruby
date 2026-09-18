# frozen_string_literal: true

require_relative 'errors'
require_relative 'proto/limits'
require_relative 'proto/reader'
require_relative 'proto/writer'
require_relative 'proto/style'
require_relative 'proto/node'
require_relative 'proto/op'
require_relative 'proto/frame'

module EUI
  module Proto
    # The version this library speaks. Four: `DefFont` and the font roles it
    # binds took the protocol there (`spec/02-wire-format.md` §4.1).
    #
    # A session speaks `min(client, server)`, negotiated in the Welcome —
    # the number a client names in its Hello is not a field id and not a
    # capability set, it is this.
    PROTOCOL_VERSION = 4
  end
end
