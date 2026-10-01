# frozen_string_literal: true

# The counter again, with no server: this script starts the EUI client
# itself and speaks to it over the client's standard input and output
# (`spec/01-transport.md` §7). No port is opened, no TLS is negotiated and no
# manifest is fetched; the window is this process's child and the script
# ends when the window closes.
#
#   ruby -Ilib examples/pipe.rb          # needs `eui` 0.8 or later on PATH
#   EUI=/path/to/eui ruby -Ilib examples/pipe.rb
#
# The picture is served the way a pipe serves one: the client asks for it by
# its hash with a `Fetch`, and it comes back down the same pipe in `Asset`
# chunks.

require_relative '../lib/eui'

class Counter < EUI::Component
  def mount(params)
    super
    @count = 0
  end

  on('increment') { @count += 1 }
  on('decrement') { @count -= 1 }

  def render
    column(display: 'column', justify: 'center', align: 'center', gap: 6,
           bg: 'surface.base', width: '100%', height: '100%', pad: 8) do
      [
        text('OVER A PIPE', size: 'sm', weight: 'semibold', fg: 'text.muted', font: 'mono'),
        text(@count.to_s, size: '4xl', weight: 'bold'),
        row(gap: 4) do
          [button('−', 'decrement', tone: 'quiet', size: 'lg'), button('+', 'increment', size: 'lg')]
        end,
        text('no port, no server, no manifest', size: 'xs', fg: 'text.muted', font: 'mono')
      ]
    end
  end
end

app = EUI::App.new(name: 'Counter', app_id: 'counter.pipe.eui-ruby', logger: ->(line) { warn(line) })
app.mount('counter', Counter)
status = app.run_pipe
exit(status&.exitstatus || 1)
