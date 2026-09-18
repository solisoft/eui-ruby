# frozen_string_literal: true

require_relative 'test_helper'

# The wire format, against the numbers `spec/02-wire-format.md` pins.
#
# A second implementation written from that document alone has to check
# itself against the same bytes, which is the whole reason they are
# written down there rather than only in the reference crate.
class ProtoTest < Minitest::Test
  include TestHelpers
  include EUI::Proto

  def test_varint_is_minimally_encoded
    w = Writer.new
    w.varint(0).varint(1).varint(127).varint(128).varint(300)
    assert_equal '00017f8001ac02', hex(w.to_s)

    r = reader(w.to_s)
    assert_equal [0, 1, 127, 128, 300], 5.times.map { r.varint }
    assert r.eof?
  end

  def test_a_non_minimal_varint_is_refused
    # 0x80 0x00 is a two-byte spelling of zero. Normalising it is how one
    # implementation's signature check becomes another's bypass.
    assert_raises(EUI::DecodeError) { reader([0x80, 0x00].pack('C*')).varint32 }
  end

  def test_svarint_zigzags
    w = Writer.new
    [0, -1, 1, -2, 2, 2**40, -(2**40)].each { |n| w.svarint(n) }
    r = reader(w.to_s)
    assert_equal [0, -1, 1, -2, 2, 2**40, -(2**40)], 7.times.map { r.svarint }
  end

  def test_default_style_record_bytes
    bytes = StyleRecord.new.to_bytes
    assert_equal 64, bytes.bytesize
    expected = [
      0x00, 0x00, 0x00, 0x03, 0x05, 0x00, 0x01, 0x00,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, # padding
      0, 0, 0, 0, # margin
      0, 0, 0, 0, 0, 0, # bg, fg, border_color
      0, 0, 0, 0, # border_width
      0x00, 0x00, 0xFF, # radius, shadow, opacity
      0x00, 0x02, 0x00, 0x00, # font_family, font_size base, weight, align
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, # clamp, decoration, overflow, position, z, cursor
      0x00, 0x00, 0x00, 0x00 # transition, animation, blur, motion
    ]
    assert_equal expected, bytes.bytes
  end

  # `spec/02-wire-format.md` §8, byte for byte: a column with "Hi" in it.
  def test_the_worked_example_is_150_bytes
    tree = Subtree.new
    tree.push(kind: NodeKind.code('box'), id: 1, style: 1, child_count: 1)
    tree.push(kind: NodeKind.code('text'), id: 2, style: 2, text: TextRef.atom_ref(1))

    column = StyleRecord.new
    column.display = Enum::DISPLAY['column']
    column.padding = [4, 4, 4, 4]
    column.bg = ColorRef.role(1)

    label = StyleRecord.new
    label.font_size = 3
    label.fg = ColorRef.role(8)

    ops = [Op.def_atom(1, 'Hi'), Op.def_style(1, column), Op.def_style(2, label), Op.mount(tree)]
    body = ops.map { |op| encode(op) }.join

    assert_equal 150, body.bytesize, 'spec §8 body size'
    assert_equal '1001024869', hex(body[0, 5]), 'DefAtom'
    assert_equal '1101', hex(body[5, 2]), 'DefStyle 1 header'
    assert_equal '1102', hex(body[71, 2]), 'DefStyle 2 header'
    assert_equal '20010001010102020202000100', hex(body[137, 13]), 'Mount'
  end

  def test_a_subtree_round_trips
    tree = Subtree.new
    tree.push(kind: NodeKind.code('box'), id: 1, style: 3, key: 7,
              props: [[2, Value.int(42)], [3, Value.list([Value.bool(true), Value.str('x')])]],
              handlers: [[EventKind.code('click'), Handler.server(9)]], child_count: 1)
    tree.push(kind: NodeKind.code('text'), id: 2, style: 0, text: TextRef.inline_ref('Hi'))

    w = Writer.new
    tree.encode(w)
    back = Subtree.decode(reader(w.to_s))

    assert_equal 2, back.nodes.length
    assert_equal 7, back.nodes[0].key
    assert_equal [[2, Value.int(42)], [3, Value.list([Value.bool(true), Value.str('x')])]], back.props_of(back.nodes[0])
    assert_equal [[EventKind.code('click'), Handler.server(9)]], back.handlers_of(back.nodes[0])
    assert_equal TextRef.inline_ref('Hi'), back.nodes[1].text
  end

  def test_a_leaf_with_children_is_refused
    tree = Subtree.new
    tree.push(kind: NodeKind.code('text'), id: 1, style: 0, child_count: 1)
    tree.push(kind: NodeKind.code('text'), id: 2, style: 0)
    w = Writer.new
    tree.encode(w)
    assert_raises(EUI::DecodeError) { Subtree.decode(reader(w.to_s)) }
  end

  def test_frames_round_trip
    frames = [
      Frame.hello(Hello.new(4, Viewport.new(1280, 900, 200, 1, 0, 125), Caps.mask(%w[fs.pick net.open]), nil)),
      Frame.welcome(Welcome.new(4, 'x' * 16, true)),
      Frame.ack(9),
      Frame.ping('12345678'),
      Frame.pong('12345678'),
      Frame.error(400, 'no'),
      Frame.resync,
      Frame.viewport(Viewport.default),
      Frame.event(EventFrame.new(3, EventKind.code('change'), 5, Value.str('typed')))
    ]
    frames.each do |frame|
      bytes = frame.encode
      back = Frame.decode(bytes)
      assert_equal frame.kind, back.kind
      assert_equal hex(bytes), hex(back.encode), "frame kind #{frame.kind}"
    end
  end

  def test_trailing_bytes_are_an_error
    bytes = Frame.ack(1).encode + 'x'
    assert_raises(EUI::DecodeError) { Frame.decode(bytes) }
  end

  def test_an_unknown_capability_bit_is_refused
    hello = Frame.hello(Hello.new(4, Viewport.default, 1 << 20, nil))
    assert_raises(EUI::DecodeError) { Frame.decode(hello.encode) }
  end

  def test_a_batch_carries_at_most_four_notifications
    ops = Array.new(5) { Op.notify('hi') }
    bytes = Frame.batch(Batch.new(1, ops)).encode
    assert_raises(EUI::DecodeError) { Frame.decode(bytes) }
  end

  def test_a_style_record_rejects_a_motion_with_nothing_to_direct
    record = StyleRecord.new
    record.motion = Enum::MOTION['top']
    assert_raises(EUI::DecodeError) { record.validate! }
  end
end
