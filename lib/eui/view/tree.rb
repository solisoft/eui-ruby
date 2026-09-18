# frozen_string_literal: true

require_relative 'style'
require_relative '../proto/op'
require_relative '../proto/node'

module EUI
  module View
    # A node on its way to the wire: the view's hash with every string
    # interned, every style resolved to a table id, and an id of its own
    # once the diff has settled one.
    TNode = Struct.new(
      :id, :kind, :style, :key, :key_atom, :text, :props, :handlers,
      :children, :scroll_to, :focus_to, keyword_init: true
    ) do
      def leaf? = Proto::NodeKind.leaf?(kind)

      # Everything in the subtree, this node included.
      def size = 1 + children.sum(&:size)
    end

    # The session's tables and the tree it last sent.
    #
    # Tables are append-only and session-scoped, exactly as the wire format
    # requires: an atom interned for the first page is still there on the
    # tenth, which is why a second page costs no second `DefAtom`.
    class Encoder
      attr_reader :previous, :protocol

      def initialize(protocol: Proto::PROTOCOL_VERSION, assets: nil)
        @protocol = protocol
        @assets = assets
        @atoms = {}
        @atoms_by_id = ['']
        @styles = {}
        @colors = {}
        @chunks = {}
        @fonts = {}
        @style_cache = {}
        @pending = []
        @previous = nil
        @next_id = 1
        @nodes_by_id = {}
        @compiler = Compiler.new(colors: method(:color_literal), fonts: method(:font_role!))
      end

      def protocol=(version)
        @protocol = version
      end

      # ---------------------------------------------------------------- tables

      def atom(string)
        string = string.to_s
        found = @atoms[string]
        return found if found

        id = @atoms.length + 1
        raise ViewError, "more than #{Proto::Limits::MAX_ATOMS} atoms in one session" if id > Proto::Limits::MAX_ATOMS

        @atoms[string] = id
        @atoms_by_id << string
        @pending << Proto::Op.def_atom(id, string)
        id
      end

      def atom_value(id) = @atoms_by_id[id]

      # Style id 0 is the default record, which every session already has.
      def style(record)
        bytes = record.to_bytes
        return 0 if bytes == Proto::StyleRecord.new.to_bytes

        found = @styles[bytes]
        return found if found

        id = @styles.length + 1
        raise ViewError, "more than #{Proto::Limits::MAX_STYLES} styles in one session" if id > Proto::Limits::MAX_STYLES

        @styles[bytes] = id
        @pending << Proto::Op.def_style(id, record)
        id
      end

      def color_literal(rgba)
        found = @colors[rgba]
        return found if found

        id = @colors.length + 1
        raise ViewError, "more than #{Proto::Limits::MAX_COLORS} literal colours" if id > Proto::Limits::MAX_COLORS

        @colors[rgba] = id
        @pending << Proto::Op.def_color(id, rgba)
        id
      end

      # Bind a font role to its faces. Roles 0 and 1 are the client's own
      # sans and mono; binding one replaces it for this session only.
      def font(family, hashes)
        found = @fonts[family]
        return found if found

        role = @fonts.length + 2
        raise ViewError, "a session binds at most #{Proto::Limits::MAX_FONT_ROLE - 1} font families" if role > Proto::Limits::MAX_FONT_ROLE

        @fonts[family] = role
        @pending << Proto::Op.def_font(role, hashes)
        role
      end

      def font_role(family) = @fonts[family]

      # The role a view means when it names a family. A family nobody bound
      # is an error here rather than a silent fall back to `sans`: the view
      # asked for a typeface, and drawing another one quietly is how a page
      # is wrong for a week.
      def font_role!(family)
        @fonts.fetch(family) do
          raise ViewError, "no font bound for '#{family}'; call app.font(#{family.inspect}, [paths]) at boot"
        end
      end

      def next_id
        id = @next_id
        @next_id += 1
        id
      end

      # ------------------------------------------------------------- rendering

      # The ops this view costs: the definitions it needed, then the patch
      # that takes the client's tree to it. Definitions come first because
      # the wire format requires it — a decoder rejects a forward reference.
      def render(view, full: false)
        tree = build(view)
        ops =
          if full || @previous.nil?
            assign_ids(tree)
            [Proto::Op.mount(subtree_of(tree))]
          else
            Diff.new(self).ops(@previous, tree)
          end
        @previous = tree
        index(tree)
        flush + ops
      end

      # What the session owes the client before it can read anything else.
      def flush
        pending = @pending
        @pending = []
        pending
      end

      # The node the client named, and what the server last rendered on it:
      # the handler's own event name, and the node's props.
      #
      # An event on a node that carries no handler for it *now* is dropped.
      # Usually that is a race rather than an attack — a handler a render
      # removed is still in the client's tree for the one round trip it
      # takes the new one to arrive.
      def event_target(node_id, event)
        node = @nodes_by_id[node_id]
        return nil unless node

        handler = node.handlers.find { |(kind, _)| kind == event }
        return nil unless handler

        name = handler[1].name
        return nil unless name

        [@atoms_by_id[name], props_of(node)]
      end

      def node(node_id) = @nodes_by_id[node_id]

      # Everything a session forgets when its client asks for a resync.
      def forget_tree!
        @previous = nil
        @nodes_by_id = {}
      end

      # ---------------------------------------------------------------- build

      def build(view, depth = 1)
        raise ViewError, 'a view is a hash' unless view.is_a?(Hash)
        raise ViewError, "the tree is nested more than #{Proto::Limits::MAX_TREE_DEPTH} deep" if depth > Proto::Limits::MAX_TREE_DEPTH

        kind_name = fetch(view, 'k') || 'box'
        kind = Proto::NodeKind.code(kind_name)
        style_id = style_for(fetch(view, 's'))

        key = fetch(view, 'key')
        key = key.to_s if key
        text = build_text(view, kind)
        props, scroll_to, focus_to = build_props(fetch(view, 'p'), kind)
        handlers = build_handlers(fetch(view, 'on'))

        if Proto::NodeKind.inert?(kind) && (text || !props.empty? || !handlers.empty?)
          raise ViewError, "a #{kind_name} carries nothing: no text, no props, no handlers"
        end

        children = Array(fetch(view, 'c')).compact.map { |child| build(child, depth + 1) }
        if Proto::NodeKind.leaf?(kind) && !children.empty?
          raise ViewError, "a #{kind_name} is a leaf and cannot have children"
        end
        raise ViewError, "more than #{Proto::Limits::MAX_CHILDREN} children on one node" if children.length > Proto::Limits::MAX_CHILDREN

        TNode.new(
          id: 0, kind: kind, style: style_id, key: key,
          key_atom: key ? atom(key) : 0, text: text, props: props,
          handlers: handlers, children: children, scroll_to: scroll_to, focus_to: focus_to
        )
      end

      # A subtree as the wire carries it, pre-order.
      def subtree_of(node)
        out = Proto::Subtree.new
        stack = [node]
        walk = lambda do |n|
          out.push(kind: n.kind, id: n.id, style: n.style, key: n.key_atom, text: n.text,
                   props: n.props, handlers: n.handlers, child_count: n.children.length)
          n.children.each { |c| walk.call(c) }
        end
        walk.call(stack.first)
        out
      end

      def assign_ids(node)
        node.id = next_id if node.id.zero?
        node.children.each { |child| assign_ids(child) }
        node
      end

      # What a handler is handed: the node's props, by name, as plain Ruby.
      def props_of(node)
        node.props.each_with_object({}) do |(atom_id, value), out|
          out[@atoms_by_id[atom_id]] = value.to_ruby
        end
      end

      private

      # Two style hashes with the same contents are the same style, and a
      # table of ten thousand rows has three of them. Ruby hashes a small
      # hash by its contents, so this is one lookup instead of compiling and
      # encoding a 64-byte record per node — which is most of what a render
      # of fifty thousand nodes used to cost.
      def style_for(style)
        return 0 if style.nil? || style.empty?

        cached = @style_cache[style]
        return cached if cached

        @style_cache[style.dup.freeze] = style(@compiler.record(style))
      end

      def fetch(hash, key)
        return hash[key] if hash.key?(key)

        hash[key.to_sym]
      end

      def build_text(view, kind)
        raw = fetch(view, 't')
        return nil if raw.nil?

        string = raw.to_s
        if string.bytesize > Proto::Limits::MAX_INLINE_STR
          raise ViewError, "a text of #{string.bytesize} bytes; the client takes at most #{Proto::Limits::MAX_INLINE_STR} — split it into nodes"
        end
        raise ViewError, "a #{Proto::NodeKind.name(kind)} carries no text" if Proto::NodeKind.inert?(kind)

        # Interning is for what repeats. A unique cell value would be a
        # permanent entry in a table that is never cleared, so only what
        # the view asked for goes in it.
        if fetch(view, 'intern') && string.bytesize <= 24
          Proto::TextRef.atom_ref(atom(string))
        else
          Proto::TextRef.inline_ref(string)
        end
      end

      # `scroll_to` and `focus_to` never reach the client as props: they are
      # instructions, done to a node once, and the diff turns a change of
      # one into its own op.
      def build_props(props, kind)
        return [[], nil, false] if props.nil?
        raise ViewError, 'a node\'s props are a hash' unless props.is_a?(Hash)

        scroll_to = nil
        focus_to = false
        out = []
        props.each do |name, value|
          name = name.to_s
          case name
          when 'scroll_to'
            unless %w[scroll list].include?(Proto::NodeKind.name(kind))
              raise ViewError, "scroll_to is for a scroll or a list, not a #{Proto::NodeKind.name(kind)}"
            end
            unless value.is_a?(Array) && value.length == 2
              raise ViewError, 'a scroll_to is [x, y] in pixels'
            end

            scroll_to = value.map { |n| Integer(n.round) }
          when 'focus_to'
            focus_to = value == true
          else
            out << [atom(name), prop_value(name, value, kind)]
          end
        end
        raise ViewError, "more than #{Proto::Limits::MAX_PROPS} props on one node" if out.length > Proto::Limits::MAX_PROPS

        [out, scroll_to, focus_to]
      end

      # An image's `src` is a file in the application: it goes on the wire
      # as the hash of its bytes, served from `/_eui/asset`.
      def prop_value(name, value, kind)
        kind_name = Proto::NodeKind.name(kind)
        asset = (%w[image audio video].include?(kind_name) && name == 'src') ||
                (kind_name == 'scene' && %w[shader mesh].include?(name))
        return Proto::Value.asset(asset_hash(name, value)) if asset

        Proto::Value.from(value)
      end

      def asset_hash(name, value)
        case value
        when String
          raise ViewError, "no asset store to resolve #{name} '#{value}'" unless @assets

          @assets.add_file(value)
        when Hash
          hex = value['asset'] || value[:asset]
          raise ViewError, "a #{name} is a path or {\"asset\" => \"<hash>\"}" unless hex
          raise ViewError, "an asset is 64 hex characters, got '#{hex}'" unless /\A[0-9a-f]{64}\z/.match?(hex)

          [hex].pack('H*')
        else raise ViewError, "a #{name} is a path or {\"asset\" => \"<hash>\"}"
        end
      end

      def build_handlers(on)
        return [] if on.nil?
        raise ViewError, 'a node\'s handlers are a hash' unless on.is_a?(Hash)

        out = []
        on.each do |event, target|
          code = Proto::EventKind.code(event)
          # An event the other end cannot decode is left out rather than
          # sent: the view still renders, the widget just never hears from
          # it. `level` arrived in version 3.
          next if Proto::EventKind.since(code) > @protocol

          unless target.is_a?(String) || target.is_a?(Symbol)
            raise ViewError, 'a handler is a server event name; local handlers are not compiled yet'
          end

          out << [code, Proto::Handler.server(atom(target.to_s))]
        end
        raise ViewError, "more than #{Proto::Limits::MAX_HANDLERS} handlers on one node" if out.length > Proto::Limits::MAX_HANDLERS

        out
      end

      def index(tree)
        @nodes_by_id = {}
        stack = [tree]
        until stack.empty?
          node = stack.pop
          @nodes_by_id[node.id] = node
          stack.concat(node.children)
        end
      end
    end
  end
end
