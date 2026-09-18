# Ruby against Soli

The same EUI application, written twice — `bench_app.rb` and
`soli/app/controllers/bench_controller.sl` — node for node, key for key,
string for string. A table of invoices, a **tick** that changes one number
in the header, and a **sort** that reverses every row.

What is compared is the two servers. The client is the same, the protocol is
the same, and — as the identical byte counts below show — the tree is the
same.

## How to run it

```
# Soli, in one terminal
soli serve bench/soli --port 5102

# this gem, in another
PORT=5101 ROWS=10000 ruby bench/bench_app.rb

# and the driver against each
ruby bench/bench.rb --port 5102 --name soli
ruby bench/bench.rb --port 5101 --name ruby
```

The row count is `ROWS` in the environment for Ruby and a constant at the
top of the Soli controller.

Every phase is measured **until the server goes quiet**, because the two
deliver a large tree differently: this gem sends one `Mount` of fifty
thousand nodes; Soli sends a `Mount` of the root and grafts the rows on with
`InsertChild` across twenty-one batches. Both are conforming, and counting
only the first frame would flatter one of them. Memory is every process
listening on the port, from `/proc`; CPU is that process's own user+system
time across the run, so the driver's cost is not charged to it.

## 10 000 rows — 50 011 nodes

| | Soli (release) | Ruby 3.4 | Ruby 3.4 + YJIT |
|---|---:|---:|---:|
| mount, bytes | 885 KB | 846 KB | 846 KB |
| mount, time | 1 227 ms | 1 691 ms | 1 544 ms |
| tick — one number | 279 ms | 612 ms | 409 ms |
| tick, bytes | **9 B** | **9 B** | **9 B** |
| sort — 10 000 rows reversed | 250 ms | 789 ms | 457 ms |
| sort, bytes / ops | 58.5 KB / 10 000 | 58.5 KB / 10 000 | 58.5 KB / 10 000 |
| RSS idle | 96.5 MB | **23.5 MB** | 24.2 MB |
| RSS after the run | 216.2 MB | **125.9 MB** | 173.5 MB |
| CPU for 25 events | 7.1 s | 16.8 s | 10.9 s |

## 500 rows — 2 511 nodes, which is what an application actually looks like

| | Soli (release) | Ruby 3.4 |
|---|---:|---:|
| mount | 39.6 KB, 45 ms | 39.6 KB, 79 ms |
| tick | 9 B, 12.2 ms (p95 18.5) | 9 B, 22.7 ms (p95 32.7) |
| sort — 500 rows reversed | 2.8 KB, 15 ms | 2.8 KB, 29 ms |
| RSS idle → after | 88.5 → 86.8 MB | **23.5 → 32.7 MB** |
| CPU for 40 events | 0.51 s | 1.04 s |

## What it says

**The bytes are identical.** 9 bytes for a changed number, 2.8 KB to reorder
five hundred rows, byte for byte across two implementations that share
nothing but a specification. That is the protocol's claim, and it holds
whoever writes the server.

**Ruby costs about twice the CPU, and about a third of the memory.** Twice
is a language difference: the same work, done by an interpreter instead of
compiled Rust, with YJIT closing about half the gap. The memory is not a
language difference — Soli's 88 MB is a whole application server (eight
worker threads, an HTTP stack, a database driver, a LiveView registry, a
bytecode compiler for local handlers) and this gem is a library that does
one thing. Compare what they do before comparing what they hold.

**At the scale an application really is, both are far inside a frame.** 500
rows, one number changed: 12 ms against 23 ms, on a 60 Hz budget of 16 ms
per frame — and the render is not what the viewer waits for anyway, because
the client already drew the last one.

**The first run of this benchmark said Ruby was 45× slower on the sort.**
That was not Ruby: it was a quadratic keyed reconciliation in this gem —
`Array#include?` inside a loop over ten thousand rows. A Fenwick tree
([`lib/eui/view/diff.rb`](../lib/eui/view/diff.rb)) took the sort from
17 690 ms to 789 ms, and a content-keyed style cache took the render of
fifty thousand nodes from 2 870 ms to 612 ms. A benchmark between two
languages measures the two implementations first, and it is worth suspecting
your own before drawing a conclusion about anybody's runtime.

## Caveats worth keeping in view

- One session at a time, over loopback, without TLS, on one machine.
  Nothing here says anything about a hundred sessions at once — where
  Soli's worker pool and Rust's threads are a different argument from
  Ruby's one thread per connection under a GVL.
- Soli renders its view through its own interpreter, so its numbers are not
  "Rust speed" either; both sides are interpreting a view and encoding it.
- The RSS of a fresh Soli is measured before any session; its growth during
  a run includes the session it kept for the resume window.
