# Changelog

## 0.1.0

The first cut: enough to write an EUI application in Ruby and have the
reference client draw it.

- `EUI::Proto` — the wire format of `spec/02`: varints, the 64-byte style
  record, nodes, values, handlers, ops, batches and every session frame,
  checked against the byte vectors the spec pins.
- `EUI::View` — a view hash compiled into interned atoms, styles and
  colours, and diffed against the tree the client holds: keyed children
  reconcile by `MoveChild`, and one changed word is one `SetText`.
- `EUI::Session` / `EUI::Server` — the HTTP and WebSocket halves of
  `spec/01`: manifest, content-addressed assets, and a session that
  welcomes, mounts, patches, answers a ping and rebuilds on a resync.
- `EUI::Component` — state, handlers, and a view that is a function of the
  state.
- `EUI::Blake3` — BLAKE3 in Ruby, because an asset is named by the hash of
  its content.
- `EUI::Manifest` — the signed `EUIM` record, with an Ed25519 publisher key
  kept on disk.

Not yet: local handlers (`spec/07` bytecode), file transfers (`spec/01`
§6), session resume, and the windowed `list`'s `window` event.
