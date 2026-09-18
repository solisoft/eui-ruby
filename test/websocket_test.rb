# frozen_string_literal: true

require_relative 'test_helper'
require 'socket'
require 'digest/sha1'
require 'base64'

# RFC 6455, with only what a session needs.
class WebSocketTest < Minitest::Test
  include TestHelpers

  def pair
    server, client = UNIXSocket.pair
    [EUI::WebSocket.new(server, path: '/x', headers: {}), client]
  end

  def masked(payload, opcode: 0x2, fin: true)
    mask = "\x01\x02\x03\x04".b
    body = payload.b.bytes.each_with_index.map { |b, i| b ^ mask.bytes[i & 3] }.pack('C*')
    head = +''.b
    head << ((fin ? 0x80 : 0x00) | opcode).chr
    head << (0x80 | payload.bytesize).chr
    head + mask + body
  end

  def test_the_accept_key_is_the_rfc_example
    # The one number in this file worth pinning: an accept key that is
    # wrong by a character is a handshake every client refuses, and the
    # error it prints points at the server's key rather than at the GUID.
    accept = Base64.strict_encode64(Digest::SHA1.digest("dGhlIHNhbXBsZSBub25jZQ==#{EUI::WebSocket::GUID}"))
    assert_equal 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=', accept
  end

  def test_a_masked_binary_message_arrives_whole
    ws, client = pair
    client.write(masked('hello'))
    assert_equal [:binary, 'hello'], ws.recv
  end

  def test_a_fragmented_message_is_reassembled
    ws, client = pair
    client.write(masked('he', fin: false))
    client.write(masked('llo', opcode: 0x0))
    assert_equal [:binary, 'hello'], ws.recv
  end

  def test_a_ping_is_answered_without_surfacing
    ws, client = pair
    client.write(masked('ab', opcode: 0x9))
    client.write(masked('done'))
    assert_equal [:binary, 'done'], ws.recv
    reply = client.readpartial(16)
    assert_equal 0x8A, reply.bytes.first, 'pong'
  end

  def test_an_unmasked_client_frame_is_refused
    ws, client = pair
    client.write([0x82, 0x01].pack('C2') + 'x')
    assert_raises(EUI::WebSocket::ProtocolError) { ws.recv }
  end

  def test_a_close_ends_the_stream
    ws, client = pair
    client.write(masked('', opcode: 0x8))
    assert_nil ws.recv
  end

  def test_what_the_server_writes_is_not_masked
    ws, client = pair
    ws.send_binary('hi')
    frame = client.readpartial(16)
    assert_equal 0x82, frame.bytes[0]
    assert_equal 2, frame.bytes[1], 'no mask bit, length 2'
    assert_equal 'hi', frame.byteslice(2, 2)
  end
end
