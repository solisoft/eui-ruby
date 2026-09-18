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
| Mount, fresh session | 72 ms | 100 ms | 76 ms | 91 ms | 89 ms | **45 ms** | 62 ms |
| Tick — one number | 17.0 ms | 36.9 ms | 35.7 ms | 32.2 ms | 9.9 ms | 6.9 ms | **2.5 ms** |
| Tick, p95 | 27.1 ms | 76.4 ms | 76.3 ms | 47.0 ms | 17.0 ms | 9.8 ms | **3.9 ms** |
| Sort — 500 rows reversed | 24 ms | 32 ms | 31 ms | 38 ms | 10 ms | 14 ms | **8 ms** |
| Resident memory, idle | 43.2 MB | 23.6 MB | 22.1 MB | 27.6 MB | 58.7 MB | 8.0 MB | **2.5 MB** |
| Resident memory, after | 52.5 MB | 33.5 MB | 26.1 MB | 46.1 MB | 121.5 MB | 16.2 MB | **5.1 MB** |
| CPU for 25 events | 0.48 s | 0.97 s | 0.95 s | 0.89 s | 0.50 s | 0.24 s | **0.07 s** |
| On the wire | 39.6 KB mount · **9 B** tick · **2.8 KB** sort — identical | | | | | | |

## 10 000 rows — 50 011 nodes

| | Soli | Ruby | Python | PHP | Node | Go | Rust |
|---|---:|---:|---:|---:|---:|---:|---:|
| Mount, fresh session | 1 553 ms | 2 162 ms | 1 931 ms | 2 117 ms | 1 164 ms | 1 209 ms | **869 ms** |
| Tick — one number | 356 ms | 661 ms | 649 ms | 671 ms | 132 ms | 97 ms | **55 ms** |
| Sort — 10 000 reversed | 421 ms | 812 ms | 751 ms | 927 ms | 197 ms | 180 ms | **164 ms** |
| Resident memory, idle | 102.5 MB | 23.6 MB | 22.1 MB | 28.2 MB | 61.1 MB | 7.9 MB | **2.5 MB** |
| Resident memory, after | 223.0 MB | 125.7 MB | 94.2 MB | 151.8 MB | 250.7 MB | 90.2 MB | **54.3 MB** |
| CPU for 25 events | 9.80 s | 18.48 s | 17.85 s | 19.09 s | 5.65 s | 4.13 s | **1.55 s** |
| On the wire | 885 / 846 KB mount · **9 B** tick · **58.5 KB** sort, 10 000 ops | | | | | | |

## The same JavaScript on two runtimes

`eui-node` runs unchanged on Bun, and the same 98 tests pass under both
runners. What changes is the bill:

| 10 000 rows | mount | tick | sort | memory, idle → after | CPU, 25 events |
|---|---:|---:|---:|---:|---:|
| Node 26 | 1 164 ms | 132 ms | 197 ms | 61 → 251 MB | 5.65 s |
| Bun 1.4 | 1 177 ms | 192 ms | 297 ms | **33 → 183 MB** | 7.90 s |

| 500 rows | mount | tick | sort | memory, idle → after | CPU, 25 events |
|---|---:|---:|---:|---:|---:|
| Node 26 | 89 ms | 9.9 ms | 10 ms | 59 → 122 MB | 0.50 s |
| Bun 1.4 | 66 ms | 10.1 ms | 14 ms | **33 → 58 MB** | 0.65 s |

V8 is quicker on this work by a third to a half; JavaScriptCore under Bun
holds about half the memory. Neither changes a byte on the wire.

## What it says

**The bytes are identical.** Nine bytes for a changed number, 2.8 KB to
reorder five hundred rows, 58.5 KB and ten thousand `MoveChild` to reverse
the big table — byte for byte, out of seven implementations that share nothing
but a specification. That is the protocol's claim, and it holds whoever
writes the server. The one difference, 885 KB against 846 KB at the mount, is
Soli interning a row's cell strings the other six carry inline: the same
tree, spelled two ways.

**The spread is about 12× at the tick, and it is a runtime ranking.** Rust and
Go compile to machine code and land where you would expect; V8 is within a
factor of two of Go; Soli's own interpreter is next; CRuby, CPython and PHP
land within a fifth of one another, about 7× behind Rust. Nothing here is a
verdict on the *protocol* — every one of these servers is doing the same
work, which is why the wire is identical.

**Memory is not a language ranking, it is a "what else is in the process"
ranking.** Soli's idle is a whole application server: worker pool, HTTP
stack, database driver, LiveView registry, a bytecode compiler for local
handlers. Node's is V8. Python, Ruby and PHP idle in the twenties because
each of those libraries is one thing. Rust's 2.5 MB and Go's 8 MB are what a
process is when nothing else is in it. What grows during a run is the tree
itself, and there the shapes differ: Rust holds fifty thousand nodes in
54 MB, Node in 251 MB.

**At the scale an application really is, all seven are inside a frame.** 500
rows, one number changed: 2.5 to 37 ms, against a 60 Hz budget of 16 ms — and
the render is not what the viewer waits for anyway, because the client
already drew the last one.

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
