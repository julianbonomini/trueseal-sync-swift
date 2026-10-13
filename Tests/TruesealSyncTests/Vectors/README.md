# Vendored sync test vectors (G5 / G8)

`sync-v1.json` is a byte-exact copy of `trueseal-sync`'s
`docs/test-vectors/sync-v1.json` — the preview wire format, pinned so this
SDK's tests can prove the shipped XCFramework + generated bindings agree
with the Rust core (release gate G5, sync ADR-0022). The consumption
contract is upstream: `trueseal-sync/docs/test-vectors/README.md`.

## The pin (G8)

Every cross-repo input is pinned to an exact version and checksum — no
floating references. The pin lives at the top of `SyncVectorTests.swift`:

- `syncV1Source` — the upstream repo + commit + path this copy came from.
- `syncV1SHA256` — the SHA-256 of the vendored file. `loadVectors()` refuses
  to parse bytes that don't match, so an accidental edit (or a silent
  upstream drift copied in) fails every vector-consuming test.

The same file+checksum is vendored by the relay (`internal/vectors`), so all
consumers pin the same bytes.

## What is checked through the bindings, and where the rest lives

Checked **through the Swift bindings** (see `SyncVectorTests.swift`):

- `protocol` versions + limits against `TrueSeal.info` / `maxPayloadBytes` /
  `maxGroupSize` (which are the linked core's FFI statics);
- the `rejections` taxonomy: every named typed error / Delivery Issue /
  Connection State exists in the SDK's canonical surface;
- the size-layer rejection behaviorally: the core consults the size gate
  FIRST, so even offline `send(limit+1)` throws `payloadTooLarge(max:)` with
  the vector's exact limit, and `send(limit)` passes the size gate (failing
  notMember offline) — the ordering is pinned from both directions.

**Core-internal** (no FFI entry point; checked by the core's own vector test
`vectors::generated_vectors_verify_against_the_code`, and by the relay for
its layers): `signing`, `addressedEncryption`, `messageId`, `messages`,
`sealedEnvelope`, `frames`, `transportVersionPrefix`, `domains`, and the
inbound rejection behaviors (held/older/expired/malformed envelopes need a
hostile peer — that is the e2e Adversary Client's job, G3). The test asserts
these sections are present and non-empty so they can't silently vanish, and
the machine-readable report names their checker.

## Updating (deliberate protocol changes only)

The vectors change only when the wire format deliberately changes (a version
bump per ADR-0022). To update:

1. Land the upstream change in trueseal-sync (its CI regenerates and
   drift-checks `sync-v1.json`).
2. Copy the new file here:
   `cp ../trueseal-sync/docs/test-vectors/sync-v1.json Tests/TruesealSyncTests/Vectors/`
3. Update `syncV1Source` and `syncV1SHA256` in `SyncVectorTests.swift`
   (`shasum -a 256 Tests/TruesealSyncTests/Vectors/sync-v1.json`).

An unexpected mismatch means the wire format changed accidentally — treat it
as a bug, not a prompt to re-pin.
