# frozen_string_literal: true

require_relative 'test_helper'

# What a change costs.
#
# The protocol's whole claim is in these numbers: a click that changes one
# number is one op, and a thousand-row table reordered is *n* moves rather
# than a rebuild.
class DiffTest < Minitest::Test
  include TestHelpers
  include EUI::DSL

  def setup
    @encoder = EUI::View::Encoder.new
  end

  def render(view) = @encoder.render(view)

  def opcodes(ops) = ops.map(&:opcode)

  def test_the_first_render_is_a_mount
    ops = render(column([text('0')]))
    assert_equal EUI::Proto::Op::MOUNT, ops.last.opcode
  end

  def test_one_changed_word_is_one_op
    render(column([text('0'), text('steady')]))
    ops = render(column([text('1'), text('steady')]))
    assert_equal [EUI::Proto::Op::SET_TEXT], opcodes(ops)
    assert_equal '1', ops.first[:text].inline
  end

  def test_an_unchanged_view_costs_nothing
    view = column([text('0')])
    render(view)
    assert_empty render(column([text('0')]))
  end

  def test_a_changed_style_is_one_set_style
    render(text('x', fg: 'text.default'))
    ops = render(text('x', fg: 'danger.base'))
    # The record is new to the session, so it is defined before it is named.
    assert_equal [EUI::Proto::Op::DEF_STYLE, EUI::Proto::Op::SET_STYLE], opcodes(ops)
  end

  def test_a_changed_kind_is_a_replace
    render(column([text('x')]))
    ops = render(column([box]))
    assert_equal [EUI::Proto::Op::REPLACE], opcodes(ops)
  end

  def test_props_that_go_away_are_set_to_null
    render(box(props: { 'a' => 1, 'b' => 2 }))
    ops = render(box(props: { 'a' => 3 }))
    assert_equal [EUI::Proto::Op::SET_PROP, EUI::Proto::Op::SET_PROP], opcodes(ops)
    assert_equal EUI::Proto::Value.int(3), ops[0][:value]
    assert_equal EUI::Proto::Value.null, ops[1][:value]
  end

  def test_a_handler_removed_is_cleared
    render(box(on: { 'click' => 'a' }))
    ops = render(box)
    assert_equal [EUI::Proto::Op::CLEAR_HANDLER], opcodes(ops)
  end

  def test_children_appended_and_removed_positionally
    render(column([text('a')]))
    ops = render(column([text('a'), text('b')]))
    assert_equal [EUI::Proto::Op::INSERT_CHILD], opcodes(ops)

    ops = render(column([text('a')]))
    assert_equal [EUI::Proto::Op::REMOVE_CHILD], opcodes(ops)
    assert_equal 1, ops.first[:index]
    assert_equal 1, ops.first[:count]
  end

  def rows(keys) = column(keys.map { |k| keyed(k, text(k.to_s)) })

  def test_a_reordered_keyed_list_is_moves
    render(rows(%w[a b c]))
    ops = render(rows(%w[c a b]))
    assert_equal [EUI::Proto::Op::MOVE_CHILD], opcodes(ops)
    assert_equal 2, ops.first[:from]
    assert_equal 0, ops.first[:to]
  end

  def test_a_keyed_row_keeps_its_node_id_when_it_moves
    render(rows(%w[a b c]))
    before = @encoder.previous.children.map(&:id)
    render(rows(%w[c b a]))
    after = @encoder.previous.children.map(&:id)
    assert_equal before.reverse, after, 'identity is the key, not the position'
  end

  def test_a_run_of_removed_rows_is_one_op
    render(rows(%w[a b c d e]))
    ops = render(rows(%w[a e]))
    assert_equal [EUI::Proto::Op::REMOVE_CHILD], opcodes(ops)
    assert_equal 1, ops.first[:index]
    assert_equal 3, ops.first[:count]
  end

  def test_a_new_keyed_row_is_inserted_where_it_belongs
    render(rows(%w[a c]))
    ops = render(rows(%w[a b c]))
    # The new key is a string this session had not interned yet, so its
    # definition rides ahead of the insertion that names it.
    assert_equal [EUI::Proto::Op::DEF_ATOM, EUI::Proto::Op::INSERT_CHILD], opcodes(ops)
    assert_equal 1, ops.last[:index]
  end

  def test_a_resync_sends_the_tree_again_but_not_the_tables
    render(rows(%w[a b]))
    keys = %w[a b].map { |k| @encoder.atom(k) }
    @encoder.forget_tree!
    ops = render(rows(%w[a b]))
    assert_equal [EUI::Proto::Op::MOUNT], opcodes(ops), 'tables are never cleared'
    assert_equal keys, %w[a b].map { |k| @encoder.atom(k) }, 'the atoms the session holds are still its own'
  end

  def test_scroll_and_focus_are_instructions_not_props
    render({ 'k' => 'scroll', 'p' => { 'scroll_to' => [0, 0] } })
    ops = render({ 'k' => 'scroll', 'p' => { 'scroll_to' => [0, 640] } })
    assert_equal [EUI::Proto::Op::SCROLL_TO], opcodes(ops)
    assert_equal 640, ops.first[:y]

    render(box(props: { 'focus_to' => false }))
    ops = render(box(props: { 'focus_to' => true }))
    assert_equal [EUI::Proto::Op::FOCUS], opcodes(ops)
  end
end
