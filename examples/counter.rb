# frozen_string_literal: true

# The counter, as an EUI application in Ruby.
#
#   ruby -Ilib examples/counter.rb
#   EUI_ALLOW_INSECURE_LOOPBACK=1 eui ws://127.0.0.1:5099/_eui/session/counter
#
# What to look at: `render` is a pure function of `@count`, and pressing a
# button sends one `SetText` — not a page, not a diffed DOM, not a frame of
# JSON. The style records were sent once, at mount, and every later render
# references them by id.

require_relative '../lib/eui'

class Counter < EUI::Component
  def mount(params)
    super
    @count = 0
  end

  on('increment') { @count += 1 }
  on('decrement') { @count -= 1 }
  on('reset')     { @count = 0 }

  def render
    column(
      display: 'column', justify: 'center', align: 'center', gap: 7,
      bg: 'surface.base', width: '100%', height: '100%', pad: 8
    ) do
      [
        text('COUNTER', size: 'sm', weight: 'semibold', fg: 'text.muted', font: 'mono'),
        text(@count.to_s, size: '4xl', weight: 'bold', fg: tone),
        row(gap: 4) do
          [
            button('−', 'decrement', tone: 'quiet', size: 'lg'),
            button('Reset', 'reset', tone: 'quiet'),
            button('+', 'increment', size: 'lg')
          ]
        end,
        divider(width: 320),
        text(footnote, size: 'xs', fg: 'text.muted', font: 'mono')
      ]
    end
  end

  private

  # Colour by what the number *is*, so it reads as a legend rather than
  # decoration — and reads right in either theme, because the client
  # resolves the role and this server never learns which one they are in.
  def tone
    return 'danger.base' if @count.negative?
    return 'text.muted' if @count.zero?

    'success.base'
  end

  def footnote
    "#{width} × #{height} · #{@viewport['mode'] || 'light'}"
  end
end

app = EUI::App.new(name: 'Counter', app_id: 'counter.eui-ruby')
app.mount('counter', Counter)
app.run(port: Integer(ENV.fetch('PORT', '5099')))
