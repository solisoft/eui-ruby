# frozen_string_literal: true

require_relative '../proto/op'

module EUI
  module View
    # What it costs to go from the tree the client holds to the one the view
    # just returned.
    #
    # The point of the whole exercise: a click that changes one number is
    # one `SetText`, not a page. Keyed children reconcile by `MoveChild`, so
    # reordering a thousand-row table is *n* moves rather than a rebuild.
    class Diff
      def initialize(encoder)
        @encoder = encoder
        @ops = []
      end

      def ops(old_tree, new_tree)
        @ops = []
        if replaceable?(old_tree, new_tree)
          node(old_tree, new_tree)
        else
          # The root changed kind: there is no parent to patch it in, so the
          # whole document is replaced. Tables are not cleared with it.
          @encoder.assign_ids(new_tree)
          @ops << Proto::Op.mount(@encoder.subtree_of(new_tree))
        end
        @ops
      end

      private

      def replaceable?(old, new)
        old.kind == new.kind && old.key == new.key
      end

      # One node against its counterpart, then its children.
      def node(old, new)
        new.id = old.id
        @ops << Proto::Op.set_style(new.id, new.style) if old.style != new.style
        @ops << Proto::Op.set_text(new.id, new.text) if old.text != new.text
        props(old, new)
        handlers(old, new)
        children(old, new)
        # Instructions rather than state: a node is scrolled, or focused,
        # once — so what triggers the op is the view asking again, not the
        # client's own offset, which this server never learns.
        @ops << Proto::Op.scroll_to(new.id, new.scroll_to[0], new.scroll_to[1]) if new.scroll_to && new.scroll_to != old.scroll_to
        @ops << Proto::Op.focus(new.id) if new.focus_to && !old.focus_to
      end

      def props(old, new)
        before = old.props.to_h
        after = new.props.to_h
        after.each do |atom, value|
          @ops << Proto::Op.set_prop(new.id, atom, value) if before[atom] != value
        end
        # There is no op that removes a property, and a client that kept one
        # the view stopped sending would answer for a state nothing holds.
        # Null is how a prop goes away.
        (before.keys - after.keys).each do |atom|
          @ops << Proto::Op.set_prop(new.id, atom, Proto::Value.null)
        end
      end

      def handlers(old, new)
        before = old.handlers.to_h
        after = new.handlers.to_h
        after.each do |event, handler|
          @ops << Proto::Op.set_handler(new.id, event, handler) if before[event] != handler
        end
        (before.keys - after.keys).each do |event|
          @ops << Proto::Op.clear_handler(new.id, event)
        end
      end

      def children(old, new)
        return if old.children.empty? && new.children.empty?

        if keyed?(old.children) && keyed?(new.children)
          keyed_children(old, new)
        else
          positional_children(old, new)
        end
      end

      def keyed?(children)
        !children.empty? && children.all?(&:key)
      end

      # Position is identity: child *i* on one side is child *i* on the
      # other. Right for a view whose shape is fixed, wrong for a list —
      # which is what keys are for.
      def positional_children(old, new)
        shared = [old.children.length, new.children.length].min
        shared.times do |i|
          before = old.children[i]
          after = new.children[i]
          if replaceable?(before, after)
            node(before, after)
          else
            @encoder.assign_ids(after)
            @ops << Proto::Op.replace(before.id, @encoder.subtree_of(after))
          end
        end

        if old.children.length > shared
          @ops << Proto::Op.remove_child(new.id, shared, old.children.length - shared)
        elsif new.children.length > shared
          new.children[shared..].each_with_index do |child, offset|
            @encoder.assign_ids(child)
            @ops << Proto::Op.insert_child(new.id, shared + offset, @encoder.subtree_of(child))
          end
        end
      end

      # Identity is the key, so a row that moved is a row that moved rather
      # than every row below it having changed.
      #
      # The obvious way to write this is quadratic — scan the old children
      # for each new one — and a ten-thousand-row sort then costs fifty
      # million comparisons before a single byte is sent. What makes it
      # `n log n` instead is the observation that a `MoveChild` only ever
      # pulls a row *forward*: everything before `index` is already final,
      # and the rest keep their relative order. So a row's current position
      # is `index` plus however many rows ahead of it are still waiting,
      # and a Fenwick tree answers that in fourteen steps rather than ten
      # thousand.
      def keyed_children(old, new)
        parent = new.id
        wanted = new.children.map(&:key)
        wanted_set = {}
        wanted.each { |k| wanted_set[k] = true }

        cur = old.children.dup
        i = 0
        while i < cur.length
          if wanted_set[cur[i].key]
            i += 1
            next
          end
          run = 1
          run += 1 while i + run < cur.length && !wanted_set[cur[i + run].key]
          @ops << Proto::Op.remove_child(parent, i, run)
          cur.slice!(i, run)
        end

        at = {}
        cur.each_with_index { |child, slot| at[child.key] = slot }
        waiting = Fenwick.new(cur.length)

        new.children.each_with_index do |after, index|
          slot = at[after.key]
          if slot.nil?
            @encoder.assign_ids(after)
            @ops << Proto::Op.insert_child(parent, index, @encoder.subtree_of(after))
            next
          end

          from = index + waiting.count_before(slot)
          @ops << Proto::Op.move_child(parent, from, index) if from != index
          waiting.place(slot)
          reconcile_kept(cur[slot], after)
        end
      end

      # How many of the rows still waiting sit ahead of this one. A plain
      # array of counts would answer it in a scan; this answers it, and
      # takes a row out of the running, in log n.
      class Fenwick
        def initialize(size)
          @size = size
          @tree = Array.new(size + 1, 0)
          (1..size).each do |i|
            @tree[i] += 1
            parent = i + (i & -i)
            @tree[parent] += @tree[i] if parent <= size
          end
        end

        # Rows still waiting at slots `0...slot`.
        def count_before(slot)
          total = 0
          i = slot
          while i.positive?
            total += @tree[i]
            i -= i & -i
          end
          total
        end

        def place(slot)
          i = slot + 1
          while i <= @size
            @tree[i] -= 1
            i += i & -i
          end
        end
      end

      def reconcile_kept(before, after)
        if before.kind == after.kind
          node(before, after)
        else
          @encoder.assign_ids(after)
          @ops << Proto::Op.replace(before.id, @encoder.subtree_of(after))
        end
      end
    end
  end
end
