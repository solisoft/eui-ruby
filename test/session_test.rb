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

  # ------------------------------------------------------- what goes wrong

  class Fragile < EUI::Component
    def mount(params)
      super
      @state = 'ok'
    end

    on('boom') { raise 'the handler fell over' }
    on('break_the_view') { @state = 'broken' }
    on('count') { @state = 'counted' }

    def render
      raise EUI::ViewError, 'a role nobody defined' if @state == 'broken'

      # Two handlers on the root, so a test can aim at one without the
      # button underneath answering first.
      column([text(@state), button('go', 'count')],
             on: { 'click' => 'boom', 'double_click' => 'break_the_view' })
    end
  end

  def fragile_app
    app = EUI::App.new(name: 'Fragile', app_id: 'fragile.test')
    app.mount('fragile', Fragile)
    app
  end

  def connected(port, path = '/_eui/session/fragile')
    client = TestClient.new(port, path)
    client.hello
    client.recv # welcome
    [client, client.recv] # and the mount
  end

  def test_a_handler_that_raises_does_not_end_the_session
    with_app(fragile_app) do |port|
      client, mount = connected(port)
      root = mount.body.ops.last[:subtree].nodes.first.id

      client.send_frame(EUI::Proto::Frame.event(
                          EUI::Proto::EventFrame.new(root, EUI::Proto::EventKind.code('click'), 0, EUI::Proto::Value.null)
                        ))
      # The state did not change, so the view did not change, so there is
      # nothing to send. The session is still up, which is the point.
      assert_nil client.recv(timeout: 0.4)

      client.send_frame(EUI::Proto::Frame.viewport(EUI::Proto::Viewport.new(500, 400, 100, 1, 1, 100)))
      assert_nil client.recv(timeout: 0.4), 'a viewport this view ignores costs nothing either'

      client.send_frame(EUI::Proto::Frame.ping('abcdefgh'))
      assert_equal EUI::Proto::Frame::PONG, client.recv.kind, 'the next frame still works'
      client.close
    end
  end

  def test_a_view_that_cannot_be_encoded_ends_the_session_with_a_reason
    with_app(fragile_app) do |port|
      client, mount = connected(port)
      root = mount.body.ops.last[:subtree].nodes.first.id

      # A view that fails fails the same way on every later render, so a
      # server that only logged it would leave a window that looks alive
      # and answers nothing.
      client.send_frame(EUI::Proto::Frame.event(
                          EUI::Proto::EventFrame.new(root, EUI::Proto::EventKind.code('double_click'), 0, EUI::Proto::Value.null)
                        ))
      error = client.recv
      assert_equal EUI::Proto::Frame::ERROR, error.kind
      assert_equal 400, error.body[0]
      assert_match(/a role nobody defined/, error.body[1])
      client.close
    end
  end

  class Ticker < EUI::Component
    def mount(params)
      super
      @ticks = 0
    end

    def tick!
      @ticks += 1
      refresh!
    end

    def render = column([text("ticks #{@ticks}")])
  end

  def test_a_render_can_be_asked_for_from_outside_the_socket
    seen = Queue.new
    component_class = Class.new(Ticker) do
      define_method(:mount) do |params|
        super(params)
        seen << self
      end
    end
    app = EUI::App.new(name: 'Ticker', app_id: 'ticker.test')
    app.mount('ticker', component_class)

    with_app(app) do |port|
      client = TestClient.new(port, '/_eui/session/ticker')
      client.hello
      client.recv
      client.recv

      component = seen.pop
      component.tick!
      batch = client.recv
      assert_equal [EUI::Proto::Op::SET_TEXT], batch.body.ops.map(&:opcode)
      assert_equal 'ticks 1', batch.body.ops.first[:text].inline
      client.close
    end
  end

  def test_a_notification_is_an_op_like_any_other
    seen = Queue.new
    component_class = Class.new(Ticker) do
      define_method(:mount) do |params|
        super(params)
        seen << self
      end
    end
    app = EUI::App.new(name: 'Ticker', app_id: 'notify.test')
    app.mount('ticker', component_class)

    with_app(app) do |port|
      client = TestClient.new(port, '/_eui/session/ticker')
      client.hello
      client.recv
      client.recv
      seen.pop.notify('Two replies', body: 'in this thread', tag: 'thread-7')
      batch = client.recv
      op = batch.body.ops.first
      assert_equal EUI::Proto::Op::NOTIFY, op.opcode
      assert_equal 'Two replies', op[:title]
      assert_equal 'thread-7', op[:tag]
      client.close
    end
  end

  def test_the_viewport_reaches_the_component
    app = EUI::App.new(name: 'Sizer', app_id: 'sizer.test')
    app.mount('sizer', Class.new(EUI::Component) do
      def render = column([text("#{width} x #{height}")])
    end)

    with_app(app) do |port|
      client = TestClient.new(port, '/_eui/session/sizer')
      client.hello(width: 1280, height: 900)
      client.recv
      mount = client.recv
      text = mount.body.ops.last[:subtree].nodes.find { |n| n.text }
      assert_equal '1280 x 900', text.text.inline, 'the Hello carried it'

      client.send_frame(EUI::Proto::Frame.viewport(EUI::Proto::Viewport.new(640, 480, 100, 0, 1, 100)))
      batch = client.recv
      assert_equal '640 x 480', batch.body.ops.first[:text].inline, 'and a resize follows on its own'
      client.close
    end
  end
end
