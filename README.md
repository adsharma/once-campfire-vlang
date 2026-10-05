# once-campfire-vlang

Campfire in V, ported from `../once-campfire-go` (which ports the Rust Campfire).
Preserves the SQLite schema, storage layout, cookies, frontend, and behavior of
the Go app. See `REPORT.md` for the current porting status.

## Layout

Each `internal/<pkg>` of the Go port becomes a top-level V module here
(`rails`, `jobs`, `useragent`, `httpcompat`, `qrcode`, `zstd`, `database`,
`html`, `richtext`, `storage`, `integrations`). Tests live beside code as
`*_test.v`. Reference oracle vectors are vendored under
`integrations/testdata/` (pinned to the same reference commit as the Go port).

## Intentional differences from the Go port

- **No TLS certificate/hostname verification on outbound fetches.** V's
  `net.openssl` binding never sets `VERIFY_PEER` and performs no hostname
  check, so link unfurls, webhook deliveries, and push sends skip verification
  (the Go port verifies against system roots). Scheme allow-listing, the SSRF
  IP guard, size caps, and redirect limits all still apply.
- **Outbound DNS is resolved twice per unfurl hop in production** (once for
  guard validation/pinning, once for dialing). Answers are pinned per hostname
  for the duration of one unfurl; the OS resolver cache makes the extra query
  cheap.
- **OpenGraph unfurl JSON emits keys in canonical order**
  (`title, url, image, description`) rather than document insertion order. The
  values are identical and JSON-object comparison is order-insensitive.
- **Oracle lookup/request accounting.** The reference `*_expected.json`
  oracles were recorded from the Rails app, whose resolution ordering differs
  from the Go port in dimensions Go's own suite never asserts (FTP probes
  resolve-then-reject in Rails vs scheme-reject in Go; redirect-chain lookup
  counts). Tests assert every recorded lookup host is guard-checked
  (set inclusion) and every recorded request occurs in order (subsequence), but
  not exact counts. Outcomes (status/body) match exactly on all 90 OpenGraph
  and 19 webhook cases.
- **`math.big` comparison pitfall.** V's `Integer.==` also compares internal
  digit-array lengths, so all P-256 field/point comparisons go through a
  value-based `big_eq` helper (`integrations/p256.v`).
