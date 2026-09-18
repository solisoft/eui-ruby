# Seven servers, one protocol

The same EUI application, written seven times — in Soli, Ruby, Python, PHP,
JavaScript, Go and Rust — node for node, key for key, string for string. A
table of invoices, a **tick** that changes one number in the header, and a
**sort** that reverses every row.

What is compared is the seven servers. The client is the same, the protocol is
the same, and — as the byte counts below show — the tree is the same.

| | the application | the server |
|---|---|---|
| Soli | [`soli/app/controllers/bench_controller.sl`](soli/app/controllers/bench_controller.sl) | `soli serve bench/soli --port 5102` |
| Ruby | [`bench_app.rb`](bench_app.rb) | `PORT=5101 ROWS=10000 ruby bench/bench_app.rb` |
| Python | `../../eui-python/bench/bench_app.py` | `PORT=5103 ROWS=10000 python3 bench/bench_app.py` |
| PHP | `../../eui-php/bench/bench_app.php` | `PORT=5104 ROWS=10000 php bench/bench_app.php` |
| Node | `../../eui-node/bench/bench-app.js` | `PORT=5105 ROWS=10000 node bench/bench-app.js` |
| Bun | the same file | `PORT=5106 ROWS=10000 bun bench/bench-app.js` |
| Go | `../../eui-go/bench/benchapp/main.go` | `PORT=5107 ROWS=10000 go run ./bench/benchapp` |
| Rust | `../../eui-rust/examples/bench.rs` | `PORT=5108 ROWS=10000 cargo run --release --example bench` |

One driver measures all seven, because a driver that spoke each server's
language would be measuring itself:

```
ruby bench/bench.rb --port 5102 --name soli
```

Every phase is measured **until the server goes quiet** — a one-second silent
window — because the seven deliver a large tree differently: six send one
`Mount` of fifty thousand nodes; Soli sends a `Mount` of the root and grafts
the rows on with `InsertChild` across twenty-one batches. Both are conforming,
and counting only the first frame would flatter one of them. The latency
figures are the first frame back, median over the driver's defaults of **20
ticks and 5 sorts**; the CPU column covers those 25 events. Memory is `VmRSS`
for every process listening on the port **and its children**, because PHP
forks one per connection; CPU is those processes' own user+system time across
the run, so the driver's cost is not charged to them.

## 500 rows — 2 511 nodes, which is what an application looks like

| | Soli | Ruby | Python | PHP | Node | Go | Rust |
|---|---:|---:|---:|---:|---:|---:|---:|
| Mount, fresh session | 44 ms | 72 ms | 79 ms | 92 ms | 81 ms | **42 ms** | 68 ms |
| Tick — one number | 13.8 ms | 22.9 ms | 22.5 ms | 26.4 ms | 8.3 ms | 4.4 ms | **2.4 ms** |
| Tick, p95 | 17.3 ms | 32.0 ms | 34.5 ms | 34.1 ms | 12.0 ms | 7.2 ms | **3.6 ms** |
| Sort — 500 rows reversed | 17 ms | 36 ms | 27 ms | 30 ms | 9 ms | 9 ms | **5 ms** |
| Resident memory, idle | 109.2 MB | 23.5 MB | 22.1 MB | 29.6 MB | 73.4 MB | 8.4 MB | **2.5 MB** |
| Resident memory, after | 100.6 MB | 33.4 MB | 26.1 MB | 49.3 MB | 124.4 MB | 15.8 MB | **5.2 MB** |
| CPU for 25 events | 0.35 s | 0.67 s | 0.65 s | 0.72 s | 0.45 s | 0.18 s | **0.06 s** |
| On the wire | 39.6 KB mount · **9 B** tick · **2.8 KB** sort — identical | | | | | | |

## 10 000 rows — 50 011 nodes

| | Soli | Ruby | Python | PHP | Node | Go | Rust |
|---|---:|---:|---:|---:|---:|---:|---:|
| Mount, fresh session | 1 202 ms | 1 421 ms | 1 293 ms | 1 572 ms | 896 ms | 851 ms | **828 ms** |
| Tick — one number | 223 ms | 536 ms | 550 ms | 552 ms | 116 ms | 88 ms | **57 ms** |
| Sort — 10 000 reversed | 243 ms | 587 ms | 666 ms | 723 ms | 179 ms | 168 ms | **114 ms** |
| Resident memory, idle | 96.2 MB | 23.5 MB | 22.1 MB | 29.5 MB | 83.6 MB | 9.0 MB | **2.5 MB** |
| Resident memory, after | 228.6 MB | 125.9 MB | 94.2 MB | 153.7 MB | 267.8 MB | 93.6 MB | **56.5 MB** |
| CPU for 25 events | 6.29 s | 14.38 s | 14.65 s | 15.36 s | 5.09 s | 3.72 s | **1.46 s** |
| On the wire | 885 / 846 KB mount · **9 B** tick · **58.5 KB** sort, 10 000 ops | | | | | | |

## The same JavaScript on two runtimes

`eui-node` runs unchanged on Bun, and the same 98 tests pass under both
runners. What changes is the bill:

| 10 000 rows | mount | tick | sort | memory, idle → after | CPU, 25 events |
|---|---:|---:|---:|---:|---:|
| Node 26 | 896 ms | 116 ms | 179 ms | 84 → 268 MB | 5.09 s |
| Bun 1.4 | 977 ms | 173 ms | 218 ms | **33 → 138 MB** | 7.08 s |

| 500 rows | mount | tick | sort | memory, idle → after | CPU, 25 events |
|---|---:|---:|---:|---:|---:|
| Node 26 | 81 ms | 8.3 ms | 9 ms | 73 → 124 MB | 0.45 s |
| Bun 1.4 | 59 ms | 9.3 ms | 12 ms | **33 → 61 MB** | 0.58 s |

V8 is quicker on this work by a tenth to a half; JavaScriptCore under Bun
holds about half the memory. Neither changes a byte on the wire.

## What it says

**The bytes are identical.** Nine bytes for a changed number, 2.8 KB to
reorder five hundred rows, 58.5 KB and ten thousand `MoveChild` to reverse
the big table — byte for byte, out of seven implementations that share nothing
but a specification. That is the protocol's claim, and it holds whoever
writes the server. The one difference, 885 KB against 846 KB at the mount, is
Soli interning a row's cell strings the other six carry inline: the same
tree, spelled two ways.

**The spread is about 11× at the tick, and it is a runtime ranking.** Rust and
Go compile to machine code and land where you would expect; V8 is within a
factor of two of Go; Soli's own interpreter is next; CRuby, CPython and PHP
land within a sixth of one another, about 10× behind Rust. Nothing here is a
verdict on the *protocol* — every one of these servers is doing the same
work, which is why the wire is identical.

**Memory is not a language ranking, it is a "what else is in the process"
ranking.** Soli's idle is a whole application server: worker pool, HTTP
stack, database driver, LiveView registry, a bytecode compiler for local
handlers — and it moves by sixty megabytes between runs as that pool warms,
which is why its idle at 500 rows reads *higher* than its figure after the
run. Node's is V8. Python, Ruby and PHP idle in the twenties because
each of those libraries is one thing. Rust's 2.5 MB and Go's 8 MB are what a
process is when nothing else is in it. What grows during a run is the tree
itself, and there the shapes differ: Rust holds fifty thousand nodes in
54 MB, Node in 251 MB.

**At the scale an application really is, all seven are inside a frame or
near it.** 500 rows, one number changed: 2.4 to 26 ms, against a 60 Hz budget
of 16 ms — and the render is not what the viewer waits for anyway, because the
client already drew the last one.

**Run-to-run spread is real, and it is not even across the seven.** These are
single runs of a few dozen events on a machine that is not otherwise idle. An
earlier pass of this same benchmark, taken while a compile was finishing, put
Ruby's 500-row tick at 36.9 ms against the 22.9 here and Soli's at 17.0
against 13.8 — while Rust moved by six hundredths of a millisecond. The
compiled servers barely notice a busy machine; the allocating ones notice it a
great deal. Read the ranking, not the third digit.

## What this is not evidence of

- **Concurrency.** One session at a time, over loopback, without TLS. A
  hundred at once is a different argument: Soli's worker pool, Go's and
  Rust's threads, Node's event loop, PHP's process per connection, and Ruby's
  and Python's threads under a global lock would not rank like this.
- **A fair memory comparison.** See above: the processes do not contain the
  same things.
- **Steady state.** Node's JIT warms up and its heap grows before a
  collection; the numbers here are one run of a few dozen events.
- **TLS.** Six of the seven terminate it themselves; the Rust crate takes no
  dependencies and Rust's standard library has no TLS, so it answers `ws://`
  and belongs behind a terminator. That is a deployment difference, not a
  measured one — nothing here goes through TLS.

The first version of this benchmark reported the Ruby sort at 17 690 ms. That
was not Ruby: it was a quadratic keyed reconciliation, and a style record
compiled once per node instead of once per distinct style. A Fenwick tree and
a cache took it to 789 ms, and the other five implementations were written
with both from the start. A benchmark between languages measures the
implementations first.

Instrumenting Soli the same way found the same shape of thing again.
`EUI_TRACE=1` splits its tick into the view, which its interpreter runs, and
the convert-diff-encode, which is Rust: 7.6 ms and 3.4 ms at 500 rows. Half of
the first was rebuilding two and a half thousand style hashes that were all
identical — hoisting them takes the tick to 6.2 ms with the output unchanged
to the byte — and the Rust half was paying a BLAKE3 per node to look up a
style cache that a pointer could have answered. The bench app is deliberately
*not* hoisted: the seven have to stay node for node identical or the
comparison stops meaning anything.
