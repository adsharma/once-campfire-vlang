# Port status report — `integrations` module

Date: 2026-10-05. V 0.5.2. Reference pinned to
`basecamp/once-campfire-rust@64f8635` (same as the Go port).

## What was ported this session

The full `internal/integrations` package of the Go port (~outbound HTTP,
push, unfurl), as pure-V modules with no new dependencies:

| File | Contents | Verification |
|---|---|---|
| `integrations/netaddr.v` | IPv4/IPv6 parse, Ruby-compatible numeric-host parsing, Surfguard-derived block tables, `resolve_public` guard | Go `TestAddressPolicy` allow+block lists verbatim; numeric/mixed-host rejections |
| `integrations/tls_sock.v`, `httpc.v` | DNS via `net.resolve_ipaddrs`, dial-IP+SNI TLS via `net.openssl`, HTTP/1.1 client (redirects unfollowed, chunked/length framing, gzip/deflate inflation, per-read timeouts, scriptable transport hook) | Localhost servers: chunked/gzip/content-length/EOF bodies, refused conn, 300 ms read-timeout → timeout reply |
| `integrations/p256.v` | Pure-V NIST P-256 (field arithmetic on `math.big`, point add/double/mult, compressed+uncompressed parsing, ECDH, ECDSA sign) | RFC 8291 appendix vector byte-identical; `n*G == ∞`; Go `ecdsa.Verify` accepts our signatures |
| `integrations/webpush.v` | HKDF-SHA256, aes128gcm framing, `encrypt_push`, VAPID ES256 JWT | Reference `web_push_expected.json` decrypts; JWT header/claims segments byte-identical to oracle |
| `integrations/push_delivery.v` | Endpoint allow-list, sender (TTL/Urgency/Auth headers, 404/410 invalidation), `truncate_push` | Go test vectors verbatim (endpoints, 5 truncation cases incl. emoji/controls) |
| `integrations/webhook.v` | Unguarded delivery, 100 MB cap, text vs attachment dispatch, MIME table + wildcard/invalid handling, timeout→reply mapping | Full 19-case `webhook_cases.json` oracle incl. exact wire-header assertions |
| `integrations/opengraph.v` | Guarded unfurl: twitter→fxtwitter rewrite, media-URL skip, 10-hop redirect loop, HEAD image probe (jpeg/png/gif/webp), canonical/image validation, latin-1/loose decoding, Unicode blank checks, per-unfurl DNS pinning cache | Full 90-case `opengraph_cases.json` oracle: status + body exact (order-insensitive JSON), requests subsequence, lookups set-inclusion |

## Full-repo test results (`v test .`, `v vet .` clean)

12/13 suites pass. The single failure is `richtext/oracle_test.v` with
**10 pre-existing diffs** (fuzz-0/14/20 autolink edge cases, xss-math
foreign-content cases) that predate this session and belong to the
`richtext` sanitizer work, not `integrations`.

## Bugs found in the V port by differential testing

1. Transposed byte in hand-copied P-256 `Gy` (`0c` vs `7c`) — caught by the
   G-on-curve check against Go's `elliptic.P256` params.
2. `Integer.==` representation sensitivity — fixed with `big_eq`.
3. Inflated bodies truncated to wire `Content-Length` — reordered to
   de-chunk → length-cap → inflate like Go's transport.
4. `Content-Type` absent vs empty conflated — Go checks header-map presence.
5. Case-sensitive media-URL matching; any-dot (not last-dot) extension scan
   with `\b` boundary; Host header must keep explicit ports.
6. Double DNS resolution consuming rebinding-oracle answers — fixed with a
   per-unfurl resolution cache (also a real TOCTOU improvement).
7. Latin-1 fallback decoding, Unicode `TrimSpace` blank checks, `og:image`
   `null`-vs-`""` (Go uses `*string`), property/name precedence — all from
   oracle diffs.

## Known limitations (see README for differences)

- No outbound TLS cert verification (V stdlib limitation).
- DNS lookup counts/order vs the Rails-recorded oracle asserted loosely
  (set/subsequence); outcomes exact. Per user direction, not pursued further.
- `richtext` oracle: 10 known diffs outstanding (prior work).
- Remaining unported surface: `web`/`front`/`cable` handlers, assets/templates,
  `cmd` main, benches.
