# frozen_string_literal: true

require_relative 'test_helper'

# The view layer: the style vocabulary, the tables, and what a view that
# cannot be encoded does about it.
class ViewTest < Minitest::Test
  include TestHelpers
  include EUI::DSL

  def setup
    @encoder = EUI::View::Encoder.new
  end

  def compile(style) = EUI::View::Compiler.new.record(style)

  def test_the_style_vocabulary
    r = compile({
                  'display' => 'column', 'justify' => 'between', 'align' => 'center',
                  'gap' => 4, 'pad' => [2, 3], 'bg' => 'surface.raised', 'fg' => 'text.muted',
                  'size' => 'lg', 'weight' => 'bold', 'radius' => 'md', 'shadow' => 'sm',
                  'width' => '50%', 'height' => 240, 'max_width' => '1fr', 'basis' => 'sp:4',
                  'underline' => true, 'cursor' => 'pointer', 'transition' => 'fast'
                })

    assert_equal EUI::Proto::Enum::DISPLAY['column'], r.display
    assert_equal EUI::Proto::Enum::JUSTIFY['between'], r.justify
    assert_equal [2, 3, 2, 3], r.padding
    assert_equal EUI::Theme.role('surface.raised'), r.bg.index
    assert_equal 3, r.font_size, 'lg is index 3 on the text scale'
    assert_equal EUI::Proto::Dim.percent(5000), r.width
    assert_equal EUI::Proto::Dim.px(240), r.height
    assert_equal EUI::Proto::Dim.fr(100), r.max_width
    assert_equal EUI::Proto::Dim.space(4), r.basis
    assert_equal 1, r.text_decoration
    assert_equal 1, r.transition, 'fast is motion index 0, carried as index + 1'
  end

  def test_an_unknown_style_key_is_an_error
    # Not a key that does nothing: a style silently dropped is a page that
    # is wrong for a day.
    error = assert_raises(EUI::ViewError) { compile({ 'padding' => 4 }) }
    assert_match(/unknown style key 'padding'/, error.message)
  end

  def test_an_unknown_colour_role_is_an_error
    assert_raises(EUI::ViewError) { compile({ 'bg' => 'surface.fancy' }) }
  end

  def test_a_literal_colour_needs_a_table
    assert_raises(EUI::ViewError) { compile({ 'bg' => '#ff8800' }) }
    id = nil
    compiler = EUI::View::Compiler.new(colors: ->(rgba) { id = rgba; 1 })
    ref = compiler.record({ 'bg' => '#ff8800' }).bg
    assert_equal 0xFF8800FF, id
    assert ref.literal?
  end

  def test_tables_are_append_only_and_deduplicate
    assert_equal 1, @encoder.atom('click')
    assert_equal 1, @encoder.atom('click'), 'the same string is the same atom'
    assert_equal 2, @encoder.atom('value')

    record = compile({ 'gap' => 2 })
    first = @encoder.style(record)
    assert_equal first, @encoder.style(compile({ 'gap' => 2 })), 'equal records share an id'
    assert_equal 0, @encoder.style(compile({})), 'the default record is id 0'
  end

  def test_the_definitions_come_before_what_uses_them
    ops = @encoder.render(text('Hi', size: 'lg'))
    assert_equal EUI::Proto::Op::MOUNT, ops.last.opcode
    assert(ops[0..-2].all? { |op| op.opcode < 0x20 }, 'every definition precedes the Mount')
  end

  def test_props_and_handlers_reach_the_wire
    ops = @encoder.render(box(props: { 'id' => 7 }, on: { 'click' => 'pick' }))
    mount = ops.last
    tree = mount[:subtree]
    node = tree.nodes.first
    assert_equal [[@encoder.atom('id'), EUI::Proto::Value.int(7)]], tree.props_of(node)
    assert_equal [[EUI::Proto::EventKind.code('click'), EUI::Proto::Handler.server(@encoder.atom('pick'))]],
                 tree.handlers_of(node)
  end

  def test_an_event_arrives_by_the_name_the_view_gave_it
    @encoder.render(box(props: { 'id' => 7 }, on: { 'wake' => 'tick' }))
    node = @encoder.previous.id
    name, props = @encoder.event_target(node, EUI::Proto::EventKind.code('wake'))
    assert_equal 'tick', name, 'the handler is named by the view, not by the event kind'
    assert_equal({ 'id' => 7 }, props)
    assert_nil @encoder.event_target(node, EUI::Proto::EventKind.code('click'))
  end

  def test_a_leaf_cannot_have_children
    assert_raises(EUI::ViewError) { @encoder.render({ 'k' => 'text', 't' => 'x', 'c' => [box] }) }
  end

  def test_an_inert_node_carries_nothing
    assert_raises(EUI::ViewError) { @encoder.render({ 'k' => 'divider', 'on' => { 'click' => 'x' } }) }
  end

  def test_a_tree_deeper_than_the_client_accepts_is_refused
    deep = box
    300.times { deep = box([deep]) }
    assert_raises(EUI::ViewError) { @encoder.render(deep) }
  end

  def test_a_font_nobody_bound_is_an_error
    error = assert_raises(EUI::ViewError) { @encoder.render(text('x', font: 'Space Grotesk')) }
    assert_match(/no font bound/, error.message)
  end

  def test_a_bound_font_becomes_a_role
    @encoder.font('Space Grotesk', [EUI::Blake3.digest('face')])
    ops = @encoder.render(text('x', font: 'Space Grotesk'))
    assert_equal EUI::Proto::Op::DEF_FONT, ops.first.opcode
    assert_equal 2, ops.first[:role], 'roles 0 and 1 are the client\'s own sans and mono'
  end
end
