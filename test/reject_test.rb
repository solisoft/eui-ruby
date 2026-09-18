# frozen_string_literal: true

require_relative 'test_helper'

# What the decoder refuses.
#
# Every case here is bytes a hostile peer can send for free, and every one
# of them has a tempting repair: clamp the enum, ignore the trailing bytes,
# normalise the varint, truncate the string. The repair is the bug — it is
# how two implementations come to disagree about what a frame said, which
# is the whole of the attack surface on a protocol like this.
class RejectTest < Minitest::Test
  include TestHelpers
  include EUI::Proto

  def refuse(bytes, what)
    assert_raises(EUI::DecodeError, what) { Frame.decode(bytes) }
  end

  # A batch of one op, wrapped as the frame it would really arrive in.
  def batch_frame(op_bytes)
    body = Writer.new
    body.varint(1).varint(1).raw(op_bytes)
    payload = body.to_s
    out = Writer.new
    out.u8(Frame::BATCH).varint(payload.bytesize).raw(payload)
    out.to_s
  end

  def style_bytes(&block)
    record = StyleRecord.new
    w = Writer.new
    record.encode(w)
    bytes = w.to_s.dup
    block&.call(bytes)
    bytes
  end

  def test_a_truncated_frame
    whole = Frame.ack(7).encode
    refuse(whole.byteslice(0, whole.bytesize - 1), 'a frame shorter than it declared')
  end

  def test_trailing_bytes_after_the_payload
    refuse(Frame.ack(7).encode + "\x00", 'trailing bytes are an error, not padding')
  end

  def test_a_frame_kind_this_revision_does_not_define
    refuse([0x7F, 0x00].pack('C*'), 'unknown kinds are not reserved for forward compatibility')
  end

  def test_a_frame_longer_than_the_ceiling
    w = Writer.new
    w.u8(Frame::BATCH).varint(Limits::MAX_FRAME_BYTES + 1)
    refuse(w.to_s, 'a declared length past MAX_FRAME_BYTES')
  end

  def test_a_non_minimal_varint_inside_a_frame
    w = Writer.new
    w.u8(Frame::ACK).varint(2).raw([0x80, 0x00].pack('C*'))
    refuse(w.to_s, 'two bytes spelling zero')
  end

  def test_a_string_that_is_not_utf8
    w = Writer.new
    body = Writer.new
    body.varint(400).varint(2).raw("\xC3\x28")
    payload = body.to_s
    w.u8(Frame::ERROR).varint(payload.bytesize).raw(payload)
    refuse(w.to_s, 'a lone continuation byte')
  end

  def test_an_inline_string_past_its_ceiling
    op = Writer.new
    op.u8(Op::SET_TEXT).varint(1).u8(0x01).varint(Limits::MAX_INLINE_STR + 1).raw('x' * (Limits::MAX_INLINE_STR + 1))
    refuse(batch_frame(op.to_s), 'an inline string of more than 4 KiB')
  end

  def test_a_node_id_of_zero
    op = Writer.new
    op.u8(Op::SET_STYLE).varint(0).varint(1)
    refuse(batch_frame(op.to_s), 'id 0 is always "none"')
  end

  def test_reserved_node_flags
    op = Writer.new
    op.u8(Op::MOUNT).u8(NodeKind.code('box')).u8(0x10).varint(1).varint(0).varint(0)
    refuse(batch_frame(op.to_s), 'a flag bit this revision does not define')
  end

  def test_a_node_kind_and_an_event_kind_nobody_defines
    op = Writer.new
    op.u8(Op::MOUNT).u8(0x7E).u8(0x00).varint(1).varint(0).varint(0)
    refuse(batch_frame(op.to_s), 'kind 0x7E')

    op = Writer.new
    op.u8(Op::CLEAR_HANDLER).varint(1).u8(0x7E)
    refuse(batch_frame(op.to_s), 'event 0x7E')
  end

  def test_a_leaf_kind_given_children
    op = Writer.new
    op.u8(Op::MOUNT)
    op.u8(NodeKind.code('text')).u8(0x00).varint(1).varint(0).varint(1)
    op.u8(NodeKind.code('text')).u8(0x00).varint(2).varint(0).varint(0)
    refuse(batch_frame(op.to_s), 'a text node with a child')
  end

  def test_an_inert_kind_carrying_content
    op = Writer.new
    op.u8(Op::MOUNT)
    op.u8(NodeKind.code('divider')).u8(0x02).varint(1).varint(0)
    op.u8(0x01).str('no')
    op.varint(0)
    refuse(batch_frame(op.to_s), 'a divider with text')
  end

  def test_more_props_than_a_node_may_carry
    op = Writer.new
    op.u8(Op::MOUNT).u8(NodeKind.code('box')).u8(0x04).varint(1).varint(0)
    op.varint(Limits::MAX_PROPS + 1)
    refuse(batch_frame(op.to_s), "more than #{Limits::MAX_PROPS} props")
  end

  def test_more_handlers_than_a_node_may_carry
    op = Writer.new
    op.u8(Op::MOUNT).u8(NodeKind.code('box')).u8(0x08).varint(1).varint(0)
    op.varint(Limits::MAX_HANDLERS + 1)
    refuse(batch_frame(op.to_s), "more than #{Limits::MAX_HANDLERS} handlers")
  end

  def test_a_value_nested_past_its_depth
    op = Writer.new
    op.u8(Op::SET_PROP).varint(1).varint(1)
    5.times { op.u8(Value::LIST).varint(1) }
    op.u8(Value::NULL)
    refuse(batch_frame(op.to_s), 'a list five deep')
  end

  def test_a_bool_that_is_neither
    op = Writer.new
    op.u8(Op::SET_PROP).varint(1).varint(1).u8(Value::BOOL).u8(2)
    refuse(batch_frame(op.to_s), 'a bool of 2')
  end

  def test_a_float_that_is_not_finite
    [Float::NAN, Float::INFINITY].each do |value|
      op = Writer.new
      op.u8(Op::SET_PROP).varint(1).varint(1).u8(Value::FLOAT).f64(value)
      refuse(batch_frame(op.to_s), "a float of #{value}")
    end
  end

  def test_a_style_record_with_an_enum_outside_its_range
    bytes = style_bytes { |b| b.setbyte(0, 9) } # display
    op = Writer.new
    op.u8(Op::DEF_STYLE).varint(1).raw(bytes)
    refuse(batch_frame(op.to_s), 'display 9 is clamped by nobody')
  end

  def test_a_style_record_whose_auto_carries_a_value
    bytes = style_bytes { |b| b.setbyte(9, 5) } # basis: tag auto, value 5
    op = Writer.new
    op.u8(Op::DEF_STYLE).varint(1).raw(bytes)
    refuse(batch_frame(op.to_s), 'Dim::Auto with a value')
  end

  def test_a_style_record_with_bits_this_revision_does_not_define
    [[60, 9], [61, 0x40], [55, 0x04]].each do |(offset, value)| # transition, animation, decoration
      bytes = style_bytes { |b| b.setbyte(offset, value) }
      op = Writer.new
      op.u8(Op::DEF_STYLE).varint(1).raw(bytes)
      refuse(batch_frame(op.to_s), "style byte #{offset} = #{value}")
    end
  end

  def test_a_font_role_with_no_face_and_a_role_past_the_table
    op = Writer.new
    op.u8(Op::DEF_FONT).u8(2).varint(0)
    refuse(batch_frame(op.to_s), 'a role bound to nothing')

    op = Writer.new
    op.u8(Op::DEF_FONT).u8(Limits::MAX_FONT_ROLE + 1).varint(1).raw('x' * 32)
    refuse(batch_frame(op.to_s), 'role 10')
  end

  def test_an_opcode_nobody_defines
    refuse(batch_frame([0x7F].pack('C')), 'opcode 0x7F')
  end

  def test_a_resume_offer_that_is_neither_yes_nor_no
    body = Writer.new
    body.varint(4)
    Viewport.default.encode(body)
    body.varint(0).u8(2)
    payload = body.to_s
    w = Writer.new
    w.u8(Frame::HELLO).varint(payload.bytesize).raw(payload)
    refuse(w.to_s, 'resume tag 2')
  end

  def test_a_transfer_chunk_past_its_ceiling
    body = Writer.new
    body.varint(1).varint(0).u8(0).varint(Limits::MAX_TRANSFER_CHUNK_BYTES + 1)
    payload = body.to_s
    w = Writer.new
    w.u8(Frame::UPLOAD).varint(payload.bytesize).raw(payload)
    refuse(w.to_s, 'a chunk of more than 256 KiB')
  end

  def test_a_view_the_protocol_cannot_carry_fails_at_encode
    encoder = EUI::View::Encoder.new
    # Not a decode error: these never reach the wire at all, which is the
    # point — the author finds out while writing the view.
    assert_raises(EUI::ViewError) { encoder.render({ 'k' => 'box', 's' => { 'size' => 300 } }) }
    assert_raises(EUI::ViewError) { encoder.render({ 'k' => 'nope' }) }
    assert_raises(EUI::ViewError) { encoder.render({ 'k' => 'box', 'on' => { 'clicked' => 'x' } }) }
    assert_raises(EUI::ViewError) { encoder.render({ 'k' => 'box', 'p' => { 'a' => Object.new } }) }
    assert_raises(EUI::ViewError) { encoder.render({ 'k' => 'text', 't' => 'x' * 5000 }) }
    assert_raises(EUI::ViewError) { encoder.render({ 'k' => 'box', 'p' => { 'scroll_to' => [0, 1] } }) }
  end
end
