# frozen_string_literal: true

require_relative 'test_helper'

# The test the diff is actually worth: a client, in forty lines, that applies
# what the server sends — and then the two trees are compared node by node.
#
# Everything else about a patch stream can look right and still be wrong.
# A `MoveChild` with an index off by one, a `RemoveChild` that counts from
# the list before the removal rather than after, an id quietly reused: each
# produces ops that encode, decode and apply without complaint, and leaves
# the window showing a tree nobody wrote. The only check that catches those
# is to *be* the client.
class ApplyTest < Minitest::Test
  include TestHelpers
  include EUI::DSL

  # What a client holds: the same fields the wire carries, and nothing else.
  Node = Struct.new(:id, :kind, :style, :key, :text, :props, :handlers, :children) do
    def to_shape
      { id: id, kind: kind, style: style, key: key, text: text,
        props: props.sort, handlers: handlers.sort, children: children.map(&:to_shape) }
    end
  end

  class Client
    attr_reader :root

    def initialize = @root = nil

    def apply(ops)
      ops.each { |op| apply_one(op) }
      self
    end

    def find(id)
      stack = [@root].compact
      until stack.empty?
        node = stack.pop
        return node if node.id == id

        stack.concat(node.children)
      end
      nil
    end

    private

    def apply_one(op)
      f = op.fields
      case op.opcode
      when EUI::Proto::Op::MOUNT then @root = build(f[:subtree])
      when EUI::Proto::Op::REPLACE then replace(f[:node], build(f[:subtree]))
      when EUI::Proto::Op::SET_STYLE then node!(f[:node]).style = f[:style]
      when EUI::Proto::Op::SET_TEXT then node!(f[:node]).text = f[:text]
      when EUI::Proto::Op::SET_PROP
        props = node!(f[:node]).props
        if f[:value] == EUI::Proto::Value.null then props.delete(f[:prop])
        else props[f[:prop]] = f[:value]
        end
      when EUI::Proto::Op::SET_HANDLER then node!(f[:node]).handlers[f[:event]] = f[:handler]
      when EUI::Proto::Op::CLEAR_HANDLER then node!(f[:node]).handlers.delete(f[:event])
      when EUI::Proto::Op::INSERT_CHILD then node!(f[:parent]).children.insert(f[:index], build(f[:subtree]))
      when EUI::Proto::Op::REMOVE_CHILD then node!(f[:parent]).children.slice!(f[:index], f[:count])
      when EUI::Proto::Op::MOVE_CHILD
        kids = node!(f[:parent]).children
        kids.insert(f[:to], kids.delete_at(f[:from]))
      when EUI::Proto::Op::DEF_ATOM, EUI::Proto::Op::DEF_STYLE, EUI::Proto::Op::DEF_COLOR,
           EUI::Proto::Op::DEF_FONT, EUI::Proto::Op::FOCUS, EUI::Proto::Op::SCROLL_TO,
           EUI::Proto::Op::NOTIFY
        nil
      else raise "the client has no op #{op.opcode}"
      end
    end

    def node!(id) = find(id) || raise("op names node #{id}, which this client does not have")

    def replace(id, fresh)
      return @root = fresh if @root.id == id

      stack = [@root]
      until stack.empty?
        node = stack.pop
        index = node.children.index { |c| c.id == id }
        return node.children[index] = fresh if index

        stack.concat(node.children)
      end
      raise "replace names node #{id}, which this client does not have"
    end

    # A subtree arrives pre-order, its shape carried by `child_count` alone.
    def build(subtree)
      index = 0
      take = lambda do
        flat = subtree.nodes[index]
        index += 1
        node = Node.new(flat.id, flat.kind, flat.style, flat.key, flat.text,
                        subtree.props_of(flat).to_h, subtree.handlers_of(flat).to_h, [])
        flat.child_count.times { node.children << take.call }
        node
      end
      take.call
    end
  end

  # The server's own tree, in the same shape, so the two can be compared.
  def shape_of(tnode)
    { id: tnode.id, kind: tnode.kind, style: tnode.style, key: tnode.key_atom,
      text: tnode.text, props: tnode.props.to_h.sort, handlers: tnode.handlers.to_h.sort,
      children: tnode.children.map { |c| shape_of(c) } }
  end

  def assert_client_matches(encoder, client, what)
    assert_equal shape_of(encoder.previous), client.root.to_shape, what
  end

  # ------------------------------------------------------------------ cases

  def test_a_sequence_of_edits_leaves_the_client_holding_the_same_tree
    encoder = EUI::View::Encoder.new
    client = Client.new

    views = [
      column([text('a'), text('b')]),
      column([text('a'), text('B'), text('c')]),
      column([text('a')]),
      column([text('a'), box(props: { 'id' => 1 }, on: { 'click' => 'go' })]),
      column([text('a'), box(props: { 'id' => 2 })]),
      column([box, text('a')]),
      row([text('a'), text('b'), text('c')])
    ]
    views.each_with_index do |view, i|
      client.apply(encoder.render(view))
      assert_client_matches(encoder, client, "after view #{i}")
    end
  end

  def keyed_rows(keys, marked = [])
    column(keys.map do |k|
      keyed(k, text(k.to_s, fg: marked.include?(k) ? 'danger.base' : 'text.default'))
    end)
  end

  def test_every_permutation_of_five_keyed_rows_applies
    keys = %w[a b c d e]
    keys.permutation.each do |wanted|
      encoder = EUI::View::Encoder.new
      client = Client.new
      client.apply(encoder.render(keyed_rows(keys)))
      client.apply(encoder.render(keyed_rows(wanted)))
      assert_client_matches(encoder, client, "reordered to #{wanted.join}")
    end
  end

  def test_rows_added_removed_and_reordered_at_once
    encoder = EUI::View::Encoder.new
    client = Client.new
    client.apply(encoder.render(keyed_rows(%w[a b c d e])))
    client.apply(encoder.render(keyed_rows(%w[e x b z a], %w[b])))
    assert_client_matches(encoder, client, 'three at once')
  end

  # The one that finds what hand-written cases do not: a thousand random
  # edits, each one applied and checked.
  def test_random_edits_applied_over_and_over
    rng = Random.new(20_260_918)
    keys = ('a'..'l').to_a

    40.times do |round|
      encoder = EUI::View::Encoder.new
      client = Client.new
      present = keys.sample(rng.rand(1..6), random: rng)
      client.apply(encoder.render(keyed_rows(present)))
      assert_client_matches(encoder, client, "round #{round} mount")

      12.times do |step|
        case rng.rand(5)
        when 0 then present = present.shuffle(random: rng)
        when 1 then present = (present + [keys.sample(random: rng)]).uniq
        when 2 then present = present.length > 1 ? present - [present.sample(random: rng)] : present
        when 3
          index = rng.rand(present.length)
          present = present.dup.insert(index, keys.sample(random: rng)).uniq
        else nil # only the marking below changes
        end
        marked = present.select { rng.rand(3).zero? }
        client.apply(encoder.render(keyed_rows(present, marked)))
        assert_client_matches(encoder, client, "round #{round} step #{step}: #{present.join(',')}")
      end
    end
  end

  def test_a_nested_keyed_list_inside_a_changing_shell
    encoder = EUI::View::Encoder.new
    client = Client.new
    shell = lambda do |title, rows|
      column([text(title), keyed_rows(rows)])
    end
    client.apply(encoder.render(shell.call('one', %w[a b c])))
    client.apply(encoder.render(shell.call('two', %w[c a])))
    assert_client_matches(encoder, client, 'nested')
    client.apply(encoder.render(shell.call('two', %w[c a b])))
    assert_client_matches(encoder, client, 'nested, grown')
  end

  def test_node_ids_are_never_reused_while_a_node_is_alive
    encoder = EUI::View::Encoder.new
    client = Client.new
    seen = {}
    10.times do |i|
      rows = %w[a b c d].rotate(i).take(3)
      client.apply(encoder.render(keyed_rows(rows)))
      live = {}
      walk = lambda do |node|
        refute live.key?(node.id), "node #{node.id} appears twice in one tree"
        live[node.id] = true
        node.children.each { |c| walk.call(c) }
      end
      walk.call(client.root)
      seen.merge!(live)
    end
  end
end
