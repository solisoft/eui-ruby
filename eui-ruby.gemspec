# frozen_string_literal: true

require_relative 'lib/eui/version'

Gem::Specification.new do |spec|
  spec.name = 'eui-ruby'
  spec.version = EUI::VERSION
  spec.authors = ['Olivier Bonnaure']
  spec.email = ['olivier@solisoft.net']

  spec.summary = 'EUI applications in Ruby: the wire format, the views, and the server that speaks them.'
  spec.description = <<~TEXT
    EUI delivers an application interface over HTTPS without HTML, CSS or
    JavaScript: the server sends a tree that is already resolved, in a
    compact binary encoding, and a native client lays it out and draws it on
    the GPU. This gem is the server half in Ruby — the encoder, the session,
    the content-addressed asset store, the signed manifest, and a component
    model where a view is a hash and a handler changes state.
  TEXT
  spec.homepage = 'https://github.com/solisoft/eui-ruby'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2'

  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['documentation_uri'] = 'https://github.com/solisoft/eui/tree/main/spec'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*.rb', 'examples/*.rb', 'README.md', 'LICENSE', 'CHANGELOG.md']
  spec.require_paths = ['lib']

  # None. Everything here is the standard library: sockets, OpenSSL for the
  # publisher key, and a BLAKE3 of its own because an asset is named by the
  # hash of its content and nothing in Ruby ships one.
end
