# frozen_string_literal: true

require 'socket'
require_relative 'errors'
require_relative 'websocket'
require_relative 'session'

module EUI
  # The three endpoints an EUI application answers on
  # (`spec/01-transport.md` §2), and nothing else.
  #
  #   GET /.well-known/eui          the signed manifest
  #   GET /_eui/asset/<blake3-hex>  a content-addressed asset
  #   WSS /_eui/session[/<name>]    the session
  #
  # TLS 1.3 is the protocol's floor, and a release client refuses `ws://`
  # outright. Pass `tls:` in production; over loopback a debug client can
  # be told to come in the front door with `EUI_ALLOW_INSECURE_LOOPBACK=1`.
  class Server
    HEADER_LIMIT = 16 * 1024

    def initialize(app, host: '127.0.0.1', port: 5012, tls: nil, logger: nil)
      @app = app
      @host = host
      @port = port
      @tls = tls
      @logger = logger || ->(line) { warn line }
      @connections = []
    end

    def start
      server = TCPServer.new(@host, @port)
      server = wrap_tls(server) if @tls
      @server = server
      log("listening on #{scheme}://#{@host}:#{@port}")
      log("  manifest  #{scheme}://#{@host}:#{@port}/.well-known/eui")
      @app.components.each_key do |name|
        log("  session   #{scheme == 'https' ? 'wss' : 'ws'}://#{@host}:#{@port}/_eui/session/#{name}")
      end

      loop do
        socket = begin
          server.accept
        rescue OpenSSL::SSL::SSLError => e
          log("TLS handshake: #{e.message}")
          next
        rescue IOError, Errno::EBADF
          break
        end
        Thread.new(socket) { |s| serve(s) }
      end
    end

    def stop
      @server&.close
    rescue IOError
      nil
    end

    private

    def scheme = @tls ? 'https' : 'http'

    def wrap_tls(server)
      require 'openssl'
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.cert = OpenSSL::X509::Certificate.new(File.read(@tls.fetch(:cert)))
      ctx.key = OpenSSL::PKey.read(File.read(@tls.fetch(:key)))
      # The protocol's floor, not a preference: a server answering `wss://`
      # with TLS 1.2 is refused by a conforming client rather than
      # accommodated, so there is nothing to gain by offering it.
      ctx.min_version = OpenSSL::SSL::TLS1_3_VERSION
      OpenSSL::SSL::SSLServer.new(server, ctx)
    end

    def serve(socket)
      request = read_request(socket)
      return socket.close if request.nil?

      method, path, headers = request
      if websocket?(headers) && method == 'GET'
        session(socket, path, headers)
      else
        http(socket, method, path)
        socket.close
      end
    rescue WebSocket::ProtocolError => e
      log("websocket: #{e.message}")
      socket.close
    rescue StandardError => e
      log("#{e.class}: #{e.message}")
      log(e.backtrace.first(5).join("\n")) if e.backtrace
      socket.close
    end

    def websocket?(headers)
      headers['upgrade']&.downcase == 'websocket'
    end

    def session(socket, path, headers)
      name = path.sub(%r{\A/_eui/session/?}, '')
      component = @app.component_for(name.empty? ? nil : name)
      unless path.start_with?('/_eui/session') && component
        respond(socket, 404, 'text/plain', "no session at #{path}\n")
        return socket.close
      end

      ws = WebSocket.accept(socket, path: path, headers: headers)
      Session.new(ws, component_class: component, app: @app, logger: @logger).run
    end

    def http(socket, method, path)
      return respond(socket, 405, 'text/plain', "GET only\n") unless method == 'GET'

      case path
      when '/.well-known/eui'
        manifest = @app.manifest
        return respond(socket, 404, 'text/plain', "this application has no manifest\n") unless manifest

        respond(socket, 200, 'application/vnd.eui.manifest', manifest.encode)
      when %r{\A/_eui/asset/([0-9a-f]{64})\z}
        entry = @app.assets.fetch(Regexp.last_match(1))
        # A hash this server does not hold is a 404 and never a redirect:
        # the name is the content, so there is nowhere else it could be.
        return respond(socket, 404, 'text/plain', "no such asset\n") unless entry

        respond(socket, 200, entry.content_type, entry.bytes,
                'Cache-Control' => 'public, max-age=31536000, immutable')
      when '/health'
        respond(socket, 200, 'text/plain', "ok\n")
      else
        respond(socket, 404, 'text/plain', "not found\n")
      end
    end

    def respond(socket, status, type, body, extra = {})
      body = body.to_s.b
      reason = { 200 => 'OK', 404 => 'Not Found', 405 => 'Method Not Allowed', 400 => 'Bad Request' }.fetch(status, 'OK')
      head = +"HTTP/1.1 #{status} #{reason}\r\n"
      head << "Content-Type: #{type}\r\n"
      head << "Content-Length: #{body.bytesize}\r\n"
      extra.each { |k, v| head << "#{k}: #{v}\r\n" }
      head << "Connection: close\r\n\r\n"
      socket.write(head, body)
    rescue SystemCallError, IOError
      nil
    end

    def read_request(socket)
      line = socket.gets("\r\n")
      return nil if line.nil?

      method, path, = line.split
      return nil if method.nil? || path.nil?

      headers = {}
      read = line.bytesize
      while (header = socket.gets("\r\n"))
        read += header.bytesize
        raise ProtocolError, 'headers too long' if read > HEADER_LIMIT
        break if header == "\r\n"

        name, value = header.split(':', 2)
        next unless value

        headers[name.strip.downcase] = value.strip
      end
      [method, path, headers]
    rescue SystemCallError, IOError
      nil
    end

    def log(line) = @logger.call("[EUI] #{line}")
  end
end
