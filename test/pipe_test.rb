# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'rbconfig'

# `spec/01-transport.md` §7: a session over a pipe. The client's end is
# played here by a second `EUI::Pipe::Socket` over the other halves of two
# `IO.pipe`s — exactly the bytes `eui --pipe` reads and writes.
class PipeTest < Minitest::Test
  include TestHelpers
  include EUI::DSL

  class Counter < EUI::Component
    def mount(params)
      super
      @count = 0
    end

    on('increment') { @count += 1 }

    def render
      column(gap: 4) { [text(@count.to_s), button('+', 'increment')] }
    end
  end

  def app
    app = EUI::App.new(name: 'Counter', app_id: 'counter.pipe.test')
    app.mount('counter', Counter)
    app
  end

  def hello
    viewport = EUI::Proto::Viewport.new(800, 600, 100, 0, 1, 100)
    # The client offers 8, the version a pipe session starts from.
    EUI::Proto::Frame.hello(EUI::Proto::Hello.new(8, viewport, 0, nil))
  end

  # A session on one end of the pipes, the client's socket on the other.
  def with_pipe(app)
    to_server, client_out = IO.pipe
    client_in, from_server = IO.pipe
    [to_server, client_out, client_in, from_server].each(&:binmode)
    server = EUI::Pipe::Socket.new(to_server, from_server)
    session = Thread.new { EUI::Session.new(server, component_class: app.component_for(nil), app: app, pipe: true).run }
    client = EUI::Pipe::Socket.new(client_in, client_out)
    yield client
    client.close
    assert session.join(5), 'the session ends when the client closes its end'
  end

  def recv(client)
    _, bytes = client.recv
    EUI::Proto::Frame.decode(bytes, pipe: true)
  end

  def test_fetch_and_asset_are_refused_on_a_socket
    fetch = EUI::Proto::Frame.fetch("\xAB".b * 32, 300).encode
    assert_equal '0d22' + ('ab' * 32) + 'ac02', hex(fetch), 'the bytes 01 §7.3 gives a Fetch'
    asset = EUI::Proto::Frame.asset("\x01".b * 32, 2, EUI::Proto::MORE, "\x09\x08\x07".b).encode
    assert_equal '0e26' + ('01' * 32) + '020003090807', hex(asset)
    [fetch, asset].each do |bytes|
      EUI::Proto::Frame.decode(bytes, pipe: true)
      assert_raises(EUI::DecodeError) { EUI::Proto::Frame.decode(bytes) }
    end
  end

  def test_a_pipe_session_welcomes_mounts_and_answers_a_click
    with_pipe(app) do |client|
      client.send_binary(hello.encode)
      welcome = recv(client)
      assert_equal EUI::Proto::Frame::WELCOME, welcome.kind
      assert_equal EUI::Proto::PROTOCOL_VERSION, welcome.body.version, 'the lower of the two'
      batch = recv(client)
      assert_equal EUI::Proto::Frame::BATCH, batch.kind
      mount = batch.body.ops.last
      tree = mount[:subtree]
      node = tree.nodes.find { |n| tree.handlers_of(n).any? }.id
      event = EUI::Proto::EventFrame.new(node, EUI::Proto::EventKind.code('click'), 0, EUI::Proto::Value.null)
      client.send_binary(EUI::Proto::Frame.event(event).encode)
      patch = recv(client)
      assert_equal EUI::Proto::Frame::BATCH, patch.kind
      assert_equal 2, patch.body.seq, 'a click is one more batch'
    end
  end

  def test_an_asset_is_served_in_the_session_in_chunks
    a = app
    picture = Random.new(7).bytes(600 * 1024)
    name = a.assets.add_bytes(picture, content_type: 'image/png')
    with_pipe(a) do |client|
      client.send_binary(hello.encode)
      2.times { recv(client) }

      client.send_binary(EUI::Proto::Frame.fetch(name, 1 << 20).encode)
      got = +''.b
      flags = []
      loop do
        frame = recv(client)
        assert_equal EUI::Proto::Frame::ASSET, frame.kind
        hash, seq, flag, bytes = frame.body
        assert_equal name, hash
        assert_equal flags.length, seq, 'contiguous from 0'
        flags << flag
        got << bytes
        break if flag == EUI::Proto::LAST
      end
      assert_equal [EUI::Proto::MORE, EUI::Proto::MORE, EUI::Proto::LAST], flags, '256 KiB at a time'
      assert_equal name, EUI::Blake3.digest(got), 'and it hashes to its name'

      client.send_binary(EUI::Proto::Frame.fetch("\x11".b * 32, 1 << 20).encode)
      _, _, flag, why = recv(client).body
      assert_equal EUI::Proto::ABORT, flag
      assert_equal 'no such asset', why

      client.send_binary(EUI::Proto::Frame.fetch(name, 10).encode)
      _, _, flag, why = recv(client).body
      assert_equal EUI::Proto::ABORT, flag, 'larger than the cap is refused, not sent'
      assert_match(/past the 10 allowed/, why)
    end
  end

  def test_a_pipe_frame_past_the_limit_is_refused_before_it_is_read
    r, w = IO.pipe
    w.write([0x03].pack('C') + EUI::Proto::Writer.new.varint(EUI::Proto::Limits::MAX_FRAME_BYTES + 1).to_s)
    w.close
    error = assert_raises(EUI::WebSocket::ProtocolError) { EUI::Pipe::Socket.new(r, $stderr).recv }
    assert_match(/past the limit/, error.message)
  end

  # `Pipe.run` against a stand-in for `eui --pipe`: a script that says Hello
  # on its standard output, reads the Welcome and the first batch from its
  # standard input, writes down what it was started with, and exits.
  def test_run_starts_the_client_and_speaks_over_its_stdio
    Dir.mktmpdir do |dir|
      argv_file = File.join(dir, 'argv')
      fake = File.join(dir, 'eui')
      lib = File.expand_path('../lib', __dir__)
      File.write(fake, <<~RUBY)
        #!#{RbConfig.ruby}
        $LOAD_PATH.unshift #{lib.inspect}
        require 'eui'
        File.write(#{argv_file.inspect}, ARGV.join(' '))
        $stdin.binmode
        $stdout.binmode
        pipe = EUI::Pipe::Socket.new($stdin, $stdout)
        viewport = EUI::Proto::Viewport.new(800, 600, 100, 0, 1, 100)
        pipe.send_binary(EUI::Proto::Frame.hello(EUI::Proto::Hello.new(8, viewport, 0, nil)).encode)
        kinds = 2.times.map { EUI::Proto::Frame.decode(pipe.recv[1], pipe: true).kind }
        exit(kinds == [EUI::Proto::Frame::WELCOME, EUI::Proto::Frame::BATCH] ? 0 : 3)
      RUBY
      File.chmod(0o755, fake)

      status = app.run_pipe(eui: fake, title: 'Probe', allow: ['clipboard.write'])
      assert status.success?, "the stand-in saw a Welcome and a batch (exit #{status.exitstatus})"
      assert_equal '--pipe --title Probe --allow clipboard.write', File.read(argv_file)
    end
  end
end
