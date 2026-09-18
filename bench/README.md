# Five servers, one protocol

The same EUI application, written five times — in Soli, Ruby, Python, PHP and
JavaScript — node for node, key for key, string for string. A table of
invoices, a **tick** that changes one number in the header, and a **sort**
that reverses every row.

What is compared is the five servers. The client is the same, the protocol is
the same, and — as the byte counts below show — the tree is the same.

| | the application | the server |
|---|---|---|
| Soli | [`soli/app/controllers/bench_controller.sl`](soli/app/controllers/bench_controller.sl) | `soli serve bench/soli --port 5102` |
| Ruby | [`bench_app.rb`](bench_app.rb) | `PORT=5101 ROWS=10000 ruby bench/bench_app.rb` |
| Python | `../../eui-python/bench/bench_app.py` | `PORT=5103 ROWS=10000 python3 bench/bench_app.py` |
| PHP | `../../eui-php/bench/bench_app.php` | `PORT=5104 ROWS=10000 php bench/bench_app.php` |
| Node | `../../eui-node/bench/bench-app.js` | `PORT=5105 ROWS=10000 node bench/bench-app.js` |

One driver measures all five, because a driver that spoke each server's
language would be measuring itself:

```
ruby bench/bench.rb --port 5102 --name soli
```

Every phase is measured **until the server goes quiet**, because the five
deliver a large tree differently: four send one `Mount` of fifty thousand
nodes; Soli sends a `Mount` of the root and grafts the rows on with
`InsertChild` across twenty-one batches. Both are conforming, and counting
only the first frame would flatter one of them. Memory is `VmRSS` for every
process listening on the port **and its children**, because PHP forks one per
connection; CPU is those processes' own user+system time across the run, so
the driver's cost is not charged to them.

## 500 rows — 2 511 nodes, which is what an application looks like

| | Soli | Ruby | Python | PHP | Node |
|---|---:|---:|---:|---:|---:|
| Mount, fresh session | 62 ms | 107 ms | 72 ms | 117 ms | **63 ms** |
| Tick — one number | **12.0 ms** | 23.7 ms | 25.3 ms | 28.0 ms | **9.4 ms** |
| Tick, p95 | 20.7 ms | 49.2 ms | 34.6 ms | 33.6 ms | **12.6 ms** |
| Sort — 500 rows reversed | 18 ms | 29 ms | 27 ms | 32 ms | **10 ms** |
| Resident memory, idle | 59.0 MB | 23.5 MB | **22.2 MB** | 29.8 MB | 61.3 MB |
| Resident memory, after | 70.9 MB | 32.8 MB | **26.3 MB** | 48.6 MB | 127.0 MB |
| CPU for 40 events | **0.57 s** | 1.10 s | 1.06 s | 1.27 s | 0.63 s |
| On the wire | 39.6 KB mount · **9 B** tick · **2.8 KB** sort — identical | | | | |

## 10 000 rows — 50 011 nodes

| | Soli | Ruby | Python | PHP | Node |
|---|---:|---:|---:|---:|---:|
| Mount, fresh session | 1 471 ms | 1 742 ms | 1 420 ms | 2 055 ms | **1 075 ms** |
| Tick — one number | 327 ms | 577 ms | 650 ms | 601 ms | **125 ms** |
| Sort — 10 000 reversed | 385 ms | 688 ms | 709 ms | 717 ms | **191 ms** |
| Resident memory, idle | 43.8 MB | 23.6 MB | **22.1 MB** | 28.1 MB | 59.2 MB |
| Resident memory, after | 177.3 MB | 124.7 MB | **91.3 MB** | 151.4 MB | 247.5 MB |
| CPU for 20 events | 7.16 s | 12.94 s | 13.95 s | 13.79 s | **4.41 s** |
| On the wire | 885 / 846 KB mount · **9 B** tick · **58.5 KB** sort, 10 000 ops | | | | |

## What it says

**The bytes are identical.** Nine bytes for a changed number, 2.8 KB to
reorder five hundred rows, 58.5 KB and ten thousand `MoveChild` to reverse
the big table — byte for byte, out of five implementations that share nothing
but a specification. That is the protocol's claim, and it holds whoever
writes the server. The one difference, 885 KB against 846 KB at the mount, is
Soli interning a row's cell strings the other four carry inline: the same
tree, spelled two ways.

**The spread between languages is about 3×, and the ranking is a JIT
ranking.** Node is quickest everywhere and V8 is why; Soli's own interpreter
is next; CRuby, CPython and PHP land within a fifth of one another. None of
this is Rust-against-the-rest — Soli renders its view through an interpreter
too, and every one of these servers is interpreting a view and encoding it.

**Memory is not a language ranking, it is a "what else is in the process"
ranking.** Soli's idle is a whole application server: worker pool, HTTP
stack, database driver, LiveView registry, a bytecode compiler for local
handlers. Node's is V8. Python, Ruby and PHP idle in the twenties because
each of those libraries is one thing. What grows during a run is the tree
itself, and there the shapes differ: Python holds fifty thousand nodes in
91 MB, Node in 247 MB.

**At the scale an application really is, all five are inside a frame.** 500
rows, one number changed: 9 to 28 ms, against a 60 Hz budget of 16 ms — and
the render is not what the viewer waits for anyway, because the client
already drew the last one.

## What this is not evidence of

- **Concurrency.** One session at a time, over loopback, without TLS. A
  hundred at once is a different argument: Soli's worker pool, Node's event
  loop, PHP's process per connection, and Ruby's and Python's threads under a
  global lock would not rank like this.
- **A fair memory comparison.** See above: the processes do not contain the
  same things.
- **Steady state.** Node's JIT warms up and its heap grows before a
  collection; the numbers here are one run of a few dozen events.

The first version of this benchmark reported the Ruby sort at 17 690 ms. That
was not Ruby: it was a quadratic keyed reconciliation, and a style record
compiled once per node instead of once per distinct style. A Fenwick tree and
a cache took it to 789 ms, and the other three implementations were written
with both from the start. A benchmark between languages measures the
implementations first.
