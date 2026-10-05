# once-campfire-vlang

Campfire in V, ported from `../once-campfire-go` (which ports the Rust Campfire,
pinned as a submodule there). Preserve the SQLite schema, storage layout, cookies,
frontend, and behavior of the Go app. Record intentional differences in README.md.

Use the V standard library first: `net.http`, `db.sqlite`, `net.websocket`, `crypto`,
`encoding.json`, `regex`, `sync`, and `embed`. No web framework, ORM, dependency
injection framework, or JavaScript build framework. Small protocol/algorithm libraries
are appropriate where stdlib has no implementation (libzstd for the bounded streaming
encoder, libvips/ffmpeg for media processing).

Do not edit `../once-campfire-go/` or its `reference/`. Port-owned frontend overrides
go in `assets/overrides/`. Tests live beside code as `*_test.v`. Reuse the reference
vectors and the reference parity seed where the Go port does. Never benchmark an
incomplete response as if it were the full application. Use identical data, response
validation, CPU affinity, encoding, warmup, repetitions, and sequential interleaved
runs. Record raw measurements and limitations in `bench/results/`.

Run `v fmt -w .`, `v vet .`, and `v test .` before committing.
SQLite FTS5 needs no build tags in V; the schema enables it via SQL.
