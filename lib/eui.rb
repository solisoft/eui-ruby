# frozen_string_literal: true

require_relative 'eui/version'
require_relative 'eui/errors'
require_relative 'eui/blake3'
require_relative 'eui/theme'
require_relative 'eui/proto'
require_relative 'eui/view/style'
require_relative 'eui/view/tree'
require_relative 'eui/view/diff'
require_relative 'eui/dsl'
require_relative 'eui/assets'
require_relative 'eui/manifest'
require_relative 'eui/component'
require_relative 'eui/websocket'
require_relative 'eui/session'
require_relative 'eui/server'
require_relative 'eui/app'

# EUI in Ruby: an application interface delivered over HTTPS without HTML,
# CSS or JavaScript.
#
# The server sends an interface tree that is **already resolved**, in a
# compact binary encoding; a native client applies it, lays it out and draws
# it on the GPU. There is no tolerant parse, no cascade to resolve and no
# script to run at the other end — which is why a view here is a hash and a
# style is a flat, closed vocabulary rather than a language.
#
# The protocol is specified in `spec/` of the EUI repository; every file in
# this gem names the section it implements.
module EUI
end
