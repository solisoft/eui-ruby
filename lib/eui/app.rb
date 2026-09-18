# frozen_string_literal: true

require_relative 'assets'
require_relative 'manifest'
require_relative 'server'

module EUI
  # An application: the components it serves, the assets they name, and the
  # manifest that says who published it.
  #
  #     app = EUI::App.new(name: "Counter", app_id: "counter.example")
  #     app.mount("counter", Counter)
  #     app.run(port: 5012)
  #
  # The first component mounted is the one a bare origin opens, because the
  # protocol has one entry and a server here has many: `wss://host` has to
  # mean something, and the first one in the file is what a person reading
  # it top to bottom would say.
  class App
    attr_reader :components, :assets, :name, :app_id

    def initialize(name:, app_id: nil, version: '0.1.0', root: Dir.pwd,
                   key_path: nil, capabilities: [], logger: nil)
      @name = name
      @app_id = app_id || name.downcase.gsub(/[^a-z0-9]+/, '-')
      @version = version
      @root = root
      @assets = Assets.new(root: root)
      @components = {}
      @capabilities = capabilities
      @key_path = key_path
      @logger = logger
    end

    def mount(path, component_class)
      name = path.to_s.delete_prefix('/')
      @components[name] = component_class
      @default ||= name
      self
    end

    def component_for(name)
      return @components[@default] if name.nil?

      @components[name]
    end

    # The face an application draws in, bound to a font role and sent as
    # content-addressed assets — so the window talks to no font service and
    # opens no connection the session did not.
    #
    # Declaring one at boot is what takes the manifest's floor to EUI 4;
    # calling it later falls back to `sans` for the sessions already open
    # rather than ending them.
    def font(family, paths)
      hashes = Array(paths).map { |path| @assets.add_file(path) }
      @fonts ||= {}
      @fonts[family] = hashes
      family
    end

    def fonts = @fonts || {}

    # The signed record at `/.well-known/eui`. Without a key path there is
    # no manifest, which a debug client on loopback accepts and a release
    # client does not.
    def manifest
      return nil unless @key_path

      @manifest ||= Manifest.new(
        app_id: @app_id, name: @name, version: @version,
        key: Manifest.publisher_key(@key_path),
        entry: "/_eui/session/#{@default}",
        capabilities: @capabilities,
        protocol_min: 1, protocol_max: Proto::PROTOCOL_VERSION
      )
    end

    def run(host: '127.0.0.1', port: 5012, tls: nil)
      Server.new(self, host: host, port: port, tls: tls, logger: @logger).start
    end
  end
end
