# frozen_string_literal: true

module EUI
  # The view, written as Ruby.
  #
  # Every helper answers a plain hash — `{"k" =>, "s" =>, "c" =>}` — so a
  # view is data all the way down: printable, comparable, testable without
  # a socket. Style keys are the spec's own vocabulary, passed as keyword
  # arguments; `on:`, `props:` and `key:` are the three that are not style.
  #
  #     column(gap: 4, pad: 6, bg: "surface.base") do
  #       [text("Hello", size: "2xl", weight: "bold"),
  #        button("Increment", "increment")]
  #     end
  module DSL
    module_function

    RESERVED = %i[on props key intern].freeze

    def node(kind, children = nil, text: nil, **options)
      style = options.reject { |k, _| RESERVED.include?(k) }
      out = { 'k' => kind.to_s }
      out['s'] = style unless style.empty?
      out['t'] = text unless text.nil?
      out['key'] = options[:key].to_s if options[:key]
      out['intern'] = true if options[:intern]
      out['p'] = stringify(options[:props]) if options[:props]
      out['on'] = stringify(options[:on]) if options[:on]
      kids = Array(children).compact
      out['c'] = kids unless kids.empty?
      out
    end

    def stringify(hash)
      hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
    end

    # ------------------------------------------------------------ primitives

    def box(children = nil, **options, &block)
      node('box', children || block&.call, **options)
    end

    def row(children = nil, **options, &block)
      box(children || block&.call, **options.merge(display: 'row'))
    end

    def column(children = nil, **options, &block)
      box(children || block&.call, **options.merge(display: 'column'))
    end

    # Children overlap, ordered by `z`: menus, tooltips, a badge on a
    # corner.
    def stack(children = nil, **options, &block)
      box(children || block&.call, **options.merge(display: 'stack'))
    end

    def text(content, **options)
      node('text', nil, text: content.to_s, **options)
    end

    def image(src, **options)
      node('image', nil, **options.merge(props: (options[:props] || {}).merge('src' => src)))
    end

    def icon(name, **options)
      node('icon', nil, **options.merge(props: (options[:props] || {}).merge('name' => name)))
    end

    def input(value, on_change: nil, **options)
      props = (options[:props] || {}).merge('value' => value.to_s)
      on = options[:on] || {}
      on = on.merge('change' => on_change) if on_change
      node('input', nil, **options.merge(props: props, on: on))
    end

    def textarea(value, on_change: nil, **options)
      props = (options[:props] || {}).merge('value' => value.to_s)
      on = options[:on] || {}
      on = on.merge('change' => on_change) if on_change
      node('textarea', nil, **options.merge(props: props, on: on))
    end

    def scroll(children = nil, **options, &block)
      node('scroll', children || block&.call, **options)
    end

    # A virtualised list: only the window in view is laid out, and the
    # client asks for another range with a `window` event.
    def list(children = nil, **options, &block)
      node('list', children || block&.call, **options)
    end

    def canvas(paths, **options)
      node('canvas', nil, **options.merge(props: (options[:props] || {}).merge('paths' => paths)))
    end

    def overlay(children = nil, **options, &block)
      node('overlay', children || block&.call, **options)
    end

    def sizer(children = nil, **options, &block)
      node('sizer', children || block&.call, **options)
    end

    # Flexible empty space. Inert: no text, no props, no handlers.
    def spacer(**options)
      node('spacer', nil, **options.merge(grow: options.fetch(:grow, 1)))
    end

    def divider(**options)
      node('divider', nil, **{ height: 1, bg: 'border.subtle', width: '100%' }.merge(options))
    end

    # Identity for reconciliation: a row that moved is a row that moved,
    # rather than every row below it having changed.
    def keyed(key, node)
      node.merge('key' => key.to_s)
    end

    # -------------------------------------------------------------- widgets
    #
    # Composed from the primitives above and nothing else, which is the
    # whole reason the catalogue can grow without shipping a new client.

    TONES = {
      'accent' => %w[accent.base accent.on],
      'danger' => %w[danger.base danger.on],
      'success' => %w[success.base success.on],
      'warning' => %w[warning.base warning.on],
      'info' => %w[info.base info.on],
      'quiet' => %w[surface.raised text.default]
    }.freeze

    def button(label, event, tone: 'accent', size: 'md', **options)
      bg, fg = TONES.fetch(tone.to_s) { raise ViewError, "unknown button tone '#{tone}'" }
      pad = { 'sm' => [1, 3], 'md' => [2, 4], 'lg' => [3, 5] }.fetch(size.to_s, [2, 4])
      style = {
        display: 'row', justify: 'center', align: 'center',
        bg: bg, radius: 'md', pad: pad, cursor: 'pointer', transition: 'fast'
      }.merge(options.reject { |k, _| RESERVED.include?(k) })
      on = (options[:on] || {}).merge('click' => event)
      box([text(label, fg: fg, weight: 'medium')], **style, on: on, key: options[:key])
    end

    # A surface a thing sits on: raised, padded, with a hairline.
    def card(children = nil, **options, &block)
      style = {
        display: 'column', bg: 'surface.raised', radius: 'md', pad: 5, gap: 4,
        border: 1, border_color: 'border.subtle'
      }.merge(options.reject { |k, _| RESERVED.include?(k) })
      box(children || block&.call, **style, on: options[:on], key: options[:key])
    end

    # A label above a field, the pair kept together.
    def field(label, value, on_change:, **options)
      column(gap: 2, **options.reject { |k, _| RESERVED.include?(k) }) do
        [
          text(label, size: 'sm', fg: 'text.muted'),
          input(value, on_change: on_change, bg: 'surface.sunken', radius: 'sm',
                       pad: [2, 3], border: 1, border_color: 'border.default')
        ]
      end
    end
  end
end
