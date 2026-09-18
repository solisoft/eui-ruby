# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/client'
require 'net/http'

# The whole thing, over a real socket: handshake, Hello, Welcome, Mount,
# an event, and the patch it costs.
class SessionTest < Minitest::Test
  include TestHelpers
  include EUI::DSL

  class Counter < EUI::Component
    def mount(params)
      super
      @count = 0
    end

    on('increment') { @count += 1 }

    def render
      column(gap: 4) do
        [text(@count.to_s, size: '2xl'), button('+', 'increment')]
      end
    end
  end

  def app
    app = EUI::App.new(name: 'Counter', app_id: 'counter.test')
    app.mount('counter', Counter)
    app
  end

  def first_click_node(mount)
    tree = mount[:subtree]
    tree.nodes.find { |n| tree.handlers_of(n).any? { |(e, _)| e == EUI::Proto::EventKind.code('click') } }&.id
  end

  def test_a_session_welcomes_mounts_and_patches
    with_app(app) do |port|
      client = TestClient.new(port, '/_eui/session/counter')
      client.hello

      welcome = client.recv
      assert_equal EUI::Proto::Frame::WELCOME, welcome.kind
      assert_equal EUI::Proto::PROTOCOL_VERSION, welcome.body.version
      assert_equal 16, welcome.body.session.bytesize
      refute welcome.body.resumed, 'a first Hello is answered with a session that starts empty'

      batch = client.recv
      assert_equal EUI::Proto::Frame::BATCH, batch.kind
      assert_equal 1, batch.body.seq
      mount = batch.body.ops.last
      assert_equal EUI::Proto::Op::MOUNT, mount.opcode

      node = first_click_node(mount)
      refute_nil node, 'the button carries a click handler'

      client.click(node)
      patch = client.recv
      assert_equal EUI::Proto::Frame::BATCH, patch.kind
      assert_equal 2, patch.body.seq
      assert_equal [EUI::Proto::Op::SET_TEXT], patch.body.ops.map(&:opcode),
                   'one changed number is one op'
      assert_equal '1', patch.body.ops.first[:text].inline
      client.close
    end
  end

  def test_an_event_on_a_node_with_no_handler_is_dropped
    with_app(app) do |port|
      client = TestClient.new(port, '/_eui/session/counter')
      client.hello
      client.recv # welcome
      client.recv # mount

      client.click(9999)
      assert_nil client.recv(timeout: 0.4), 'nothing is looked up and nothing is answered'
      client.close
    end
  end

  def test_a_ping_is_answered
    with_app(app) do |port|
      client = TestClient.new(port, '/_eui/session/counter')
      client.hello
      client.recv
      client.recv
      client.send_frame(EUI::Proto::Frame.ping('12345678'))
      pong = client.recv
      assert_equal EUI::Proto::Frame::PONG, pong.kind
      assert_equal '12345678', pong.body
      client.close
    end
  end

  def test_a_resync_is_answered_with_a_fresh_mount
    with_app(app) do |port|
      client = TestClient.new(port, '/_eui/session/counter')
      client.hello
      client.recv
      client.recv
      client.send_frame(EUI::Proto::Frame.resync)
      batch = client.recv
      assert_equal EUI::Proto::Op::MOUNT, batch.body.ops.last.opcode
      client.close
    end
  end

  def test_the_asset_endpoint_serves_by_content
    application = app
    hash = application.assets.add_bytes('some bytes', content_type: 'image/png')
    with_app(application) do |port|
      body = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/_eui/asset/#{EUI::Assets.hex(hash)}"))
      assert_equal '200', body.code
      assert_equal 'some bytes', body.body
      assert_equal 'public, max-age=31536000, immutable', body['cache-control']

      missing = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/_eui/asset/#{'0' * 64}"))
      assert_equal '404', missing.code, 'a hash this server does not hold is a 404, never a redirect'
    end
  end

  def test_a_session_that_does_not_exist_is_a_404
    with_app(app) do |port|
      response = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/_eui/session/nobody"))
      assert_equal '404', response.code
    end
  end
end
