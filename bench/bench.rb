# frozen_string_literal: true

# Drive one EUI session and measure what it cost the server.
#
#   ruby bench/bench.rb --port 5101 --name ruby
#
# Nothing here assumes how a server chooses to deliver a tree. Soli sends a
# `Mount` of the root and grafts ten thousand rows on with `InsertChild`
# across a dozen batches; this gem sends one `Mount`. Both are conforming,
# and neither is measured fairly by counting the first frame — so every
# phase is measured until the server **goes quiet**, and what is reported is
# everything it sent.
#
#   mount   a fresh session: bytes, ops, nodes, first frame and settle
#   tick    one number changes — the floor: handler, render, diff, frame
#   sort    ten thousand keyed rows reversed — the ceiling for the diff
#   rss     the server's resident memory, from /proc
#   cpu     the server's own user+system time, so the client's cost is not
#           counted against it

require 'json'
require_relative '../lib/eui'
require_relative '../test/support/client'

options = { port: 5101, name: 'server', path: '/_eui/session/bench', ticks: 20, sorts: 5, quiet: 1.0 }
ARGV.each_slice(2) do |(flag, value)|
  case flag
  when '--port' then options[:port] = Integer(value)
  when '--name' then options[:name] = value
  when '--path' then options[:path] = value
  when '--ticks' then options[:ticks] = Integer(value)
  when '--sorts' then options[:sorts] = Integer(value)
  when '--quiet' then options[:quiet] = Float(value)
  end
end

def pids_on(port)
  out = `ss -ltnp 2>/dev/null`.lines.grep(/:#{port} /).join
  roots = out.scan(/pid=(\d+)/).flatten.map(&:to_i).uniq
  roots.flat_map { |pid| [pid] + children_of(pid) }.uniq
end

def children_of(pid)
  `pgrep -P #{pid} 2>/dev/null`.split.map(&:to_i).flat_map { |k| [k] + children_of(k) }
end

def rss_kb(pids)
  pids.sum do |pid|
    File.read("/proc/#{pid}/status")[/VmRSS:\s+(\d+)/, 1].to_i
  rescue Errno::ENOENT
    0
  end
end

def cpu_seconds(pids)
  pids.sum do |pid|
    fields = File.read("/proc/#{pid}/stat").split
    (fields[13].to_f + fields[14].to_f) / 100.0
  rescue Errno::ENOENT
    0.0
  end
end

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def percentile(values, fraction)
  return 0.0 if values.empty?

  values.sort[[(values.length * fraction).ceil - 1, 0].max]
end

# Everything the server sends until it has been quiet for `quiet` seconds.
def collect(client, quiet:, first_timeout: 120)
  started = now
  first = nil
  bytes = 0
  batches = 0
  ops = 0
  nodes = 0
  subtrees = []
  atoms = {}

  loop do
    frame = client.recv(timeout: first.nil? ? first_timeout : quiet)
    break if frame.nil?

    first ||= now
    case frame.kind
    when EUI::Proto::Frame::BATCH
      bytes += frame.encode.bytesize
      batches += 1
      ops += frame.body.ops.length
      frame.body.ops.each do |op|
        atoms[op[:id]] = op[:value] if op.opcode == EUI::Proto::Op::DEF_ATOM
        subtree = op[:subtree]
        next unless subtree

        subtrees << subtree
        nodes += subtree.nodes.length
      end
    when EUI::Proto::Frame::ERROR
      warn "server error #{frame.body.inspect}"
      break
    end
  end

  { bytes: bytes, batches: batches, ops: ops, nodes: nodes, subtrees: subtrees, atoms: atoms,
    first_ms: first ? (first - started) * 1000 : nil, settle_ms: (now - started) * 1000 - (quiet * 1000) }
end

pids = pids_on(options[:port])
abort "nothing is listening on #{options[:port]}" if pids.empty?

rss_idle = rss_kb(pids)
cpu_start = cpu_seconds(pids)

client = TestClient.new(options[:port], options[:path])
started = now
client.hello(width: 1400, height: 900)
welcome = client.recv(timeout: 30)
abort 'no Welcome' unless welcome&.kind == EUI::Proto::Frame::WELCOME

mount = collect(client, quiet: options[:quiet])
mount_ms = (now - started) * 1000 - (options[:quiet] * 1000)
rss_mounted = rss_kb((pids + pids_on(options[:port])).uniq)

# The click targets: whichever nodes carry the handlers the tree named
# `tick` and `sort`. Both servers name them the same, because both views do.
targets = {}
mount[:subtrees].each do |subtree|
  subtree.nodes.each do |node|
    subtree.handlers_of(node).each do |(event, handler)|
      next unless event == EUI::Proto::EventKind.code('click')

      name = mount[:atoms][handler.name]
      targets[name] = node.id if name
    end
  end
end
abort "no tick/sort handlers in the tree (found #{targets.keys})" unless targets['tick'] && targets['sort']

def measure(client, node, count, quiet)
  firsts = []
  settles = []
  bytes = []
  ops = []
  count.times do
    client.click(node)
    run = collect(client, quiet: quiet)
    raise 'no answer' if run[:first_ms].nil?

    # The first frame back is the round trip proper; the settle is when the
    # server stopped talking, which for a ten-thousand-row sort is the
    # number that matters.
    firsts << run[:first_ms]
    settles << run[:settle_ms]
    bytes << run[:bytes]
    ops << run[:ops]
  end
  { first_p50: percentile(firsts, 0.5), first_p95: percentile(firsts, 0.95),
    settle_p50: percentile(settles, 0.5),
    bytes: bytes.sum / bytes.length, ops: ops.sum / ops.length }
end

tick = measure(client, targets['tick'], options[:ticks], 0.25)
sort = measure(client, targets['sort'], options[:sorts], options[:quiet])

# A server that forks per connection has its work in a child that did not
# exist when this started, so the set is taken again rather than trusted.
pids = (pids + pids_on(options[:port])).uniq
cpu_used = cpu_seconds(pids) - cpu_start
rss_after = rss_kb(pids)
client.close

report = {
  name: options[:name],
  processes: pids.length,
  nodes: mount[:nodes],
  mount_batches: mount[:batches],
  mount_ops: mount[:ops],
  mount_kb: (mount[:bytes] / 1024.0).round(1),
  mount_ms: mount_ms.round(0),
  tick_ms_p50: tick[:first_p50].round(2),
  tick_ms_p95: tick[:first_p95].round(2),
  tick_bytes: tick[:bytes],
  tick_ops: tick[:ops],
  sort_ms_p50: sort[:first_p50].round(0),
  sort_settle_ms: sort[:settle_p50].round(0),
  sort_kb: (sort[:bytes] / 1024.0).round(1),
  sort_ops: sort[:ops],
  rss_idle_mb: (rss_idle / 1024.0).round(1),
  rss_mounted_mb: (rss_mounted / 1024.0).round(1),
  rss_after_mb: (rss_after / 1024.0).round(1),
  cpu_s: cpu_used.round(2)
}
puts report.map { |k, v| "#{k}=#{v}" }.join(' ')
File.write("/tmp/eui-bench-#{options[:name]}.json", JSON.generate(report)) if defined?(JSON)
