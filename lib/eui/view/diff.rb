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
      def keyed_children(old, new)
        parent = new.id
        cur = old.children.dup
        wanted = new.children.map(&:key)

        # What is not in the new list goes first, in contiguous runs, so a
        # section that closed costs one op rather than twenty.
        i = 0
        while i < cur.length
          if wanted.include?(cur[i].key)
            i += 1
            next
          end
          run = 1
          run += 1 while i + run < cur.length && !wanted.include?(cur[i + run].key)
          @ops << Proto::Op.remove_child(parent, i, run)
          cur.slice!(i, run)
        end

        new.children.each_with_index do |after, index|
          at = cur[index]
          if at && at.key == after.key
            reconcile_kept(at, after, parent, index)
            next
          end

          from = cur.index { |c| c.key == after.key }
          if from
            @ops << Proto::Op.move_child(parent, from, index)
            moved = cur.delete_at(from)
            cur.insert(index, moved)
            reconcile_kept(moved, after, parent, index)
          else
            @encoder.assign_ids(after)
            @ops << Proto::Op.insert_child(parent, index, @encoder.subtree_of(after))
            cur.insert(index, after)
          end
        end

        return unless cur.length > new.children.length

        @ops << Proto::Op.remove_child(parent, new.children.length, cur.length - new.children.length)
      end

      def reconcile_kept(before, after, parent, index)
        if before.kind == after.kind
          node(before, after)
        else
          @encoder.assign_ids(after)
          @ops << Proto::Op.replace(before.id, @encoder.subtree_of(after))
        end
        [parent, index]
      end
    end
  end
end
