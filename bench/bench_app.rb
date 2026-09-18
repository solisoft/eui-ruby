# frozen_string_literal: true

# The Ruby half of the comparison: the same application as bench/soli,
# node for node.
#
#   ROWS=10000 PORT=5101 ruby bench/bench_app.rb
#
# Raw hashes rather than the DSL, so that the two files can be read side by
# side and the trees compared line by line. What is being measured is what
# it costs each server to turn this into bytes — not two different views.

require_relative '../lib/eui'

ROWS = Integer(ENV.fetch('ROWS', '10000'))

class Bench < EUI::Component
  WIDTHS = [90, 160, 90, 90].freeze

  def mount(params)
    super
    @order = 'asc'
    @ticks = 0
  end

  on('sort') { @order = @order == 'asc' ? 'desc' : 'asc' }
  on('tick') { @ticks += 1 }

  def cells(i)
    ["FA-#{i}", "Client #{i % 37} SARL", (i % 3).zero? ? 'Paid' : 'Open', "#{100 + (i * 37)} EUR"]
  end

  def row_node(i)
    values = cells(i)
    {
      'k' => 'box',
      'key' => "r#{i}",
      's' => {
        'display' => 'row', 'gap' => 4, 'pad' => [1, 3, 1, 3],
        'border' => [0, 0, 1, 0], 'border_color' => 'border.subtle'
      },
      'c' => Array.new(4) do |c|
        { 'k' => 'text', 't' => values[c], 's' => { 'width' => WIDTHS[c], 'size' => 1, 'fg' => 'text.default' } }
      end
    }
  end

  def render
    ids = (0...ROWS).to_a
    ids = ids.reverse if @order == 'desc'
    rows = ids.map { |i| row_node(i) }
    {
      'k' => 'box',
      's' => { 'display' => 'column', 'pad' => 6, 'gap' => 3, 'bg' => 'surface.base',
               'width' => '100%', 'height' => '100%' },
      'c' => [
        {
          'k' => 'box',
          's' => { 'display' => 'row', 'gap' => 3, 'align' => 'center' },
          'c' => [
            { 'k' => 'text', 't' => 'Invoices', 's' => { 'size' => 5, 'weight' => 'bold' } },
            { 'k' => 'text', 't' => @ticks.to_s, 's' => { 'size' => 2, 'fg' => 'text.muted', 'font' => 'mono' } },
            { 'k' => 'spacer', 's' => { 'grow' => 1 } },
            {
              'k' => 'box',
              's' => { 'bg' => 'surface.raised', 'radius' => 2, 'pad' => [2, 4], 'cursor' => 'pointer' },
              'on' => { 'click' => 'sort' },
              'c' => [{ 'k' => 'text', 't' => @order == 'asc' ? 'Sort down' : 'Sort up', 's' => { 'weight' => 'medium' } }]
            },
            {
              'k' => 'box',
              's' => { 'bg' => 'accent.base', 'radius' => 2, 'pad' => [2, 4], 'cursor' => 'pointer' },
              'on' => { 'click' => 'tick' },
              'c' => [{ 'k' => 'text', 't' => 'Tick', 's' => { 'fg' => 'accent.on', 'weight' => 'medium' } }]
            }
          ]
        },
        { 'k' => 'scroll', 's' => { 'grow' => 1, 'width' => '100%' },
          'c' => [{ 'k' => 'box', 's' => { 'display' => 'column' }, 'c' => rows }] }
      ]
    }
  end
end

app = EUI::App.new(name: 'Bench', app_id: 'bench.eui-ruby')
app.mount('bench', Bench)
app.run(port: Integer(ENV.fetch('PORT', '5101')))
