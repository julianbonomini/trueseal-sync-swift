# trueseal-sync-swift

Swift SDK for [trueseal-sync](https://github.com/julianbonomini/trueseal-sync) — E2EE, local-first sync between devices. No accounts. No server that can read your data.

Wraps the Rust core via UniFFI. The public surface is pure Swift — no FFI types, no Noise Protocol, no raw pointers.

**Platforms:** macOS 14+ · iOS 17+ · Swift 5.9+ / Xcode 15+

---

## Install

```swift
// Package.swift
.package(url: "https://github.com/julianbonomini/trueseal-sync-swift", from: "0.1.0")
```

No Rust toolchain needed. A pre-built XCFramework ships with every [release](https://github.com/julianbonomini/trueseal-sync-swift/releases) and SPM downloads it automatically.

---

## Usage

### Init

You need a relay — a server that routes encrypted blobs between devices. The relay never sees plaintext; it only forwards ciphertext it can't decrypt.

```swift
import TruesealSync

let ts = try await TrueSeal.open(
    relay: "trueseal://<relay public key hex>@relay.example.com",
    storage: try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true)
)
```

One Relay Address string carries the key, host and both ports — the relay CLI prints it (`trueseal-relay address --host relay.example.com`). Session State lives under `storage` (excluded from backups; protected by the OS sandbox). `open` returns before the connection is up — the outbox queues and replays once the relay is reachable.

State is `@Observable` for SwiftUI: `ts.status`, `ts.me`, `ts.members`, `ts.connection`.

> **Required entitlement.** Without this, the relay connection silently fails:
> ```xml
> <!-- YourApp.entitlements -->
> <key>com.apple.security.network.client</key>
> <true/>
> ```
> Add it on both macOS and iOS targets.

---

### Pair two devices

Devices sync within a group — a set of mutually-trusted devices. You bootstrap the group by pairing. One device opens a window and hands over a token; the other joins with it; the first accepts.

**Device A** — open the pairing window and get a token (show it as a QR code, send via AirDrop, etc.):

```swift
let token = try tsA.startPairing()
```

**Device B** — join with the token (status becomes `pendingJoin` until the first manifest arrives):

```swift
try tsB.join(token: token)
```

**Device A** — the request arrives as an event; accept it:

```swift
let sub = tsA.onEvent { event in
    if case .joinRequest(let request) = event {
        print("Request from: \(request.name)")
        try? tsA.accept(requestId: request.id)
    }
}
```

After `accept`, both devices are members and can send and receive.

---

### Send & receive

```swift
// Send — returns the Message ID once durably queued (fails typed while
// not a member, or over the 61,440-byte limit)
let messageId = try ts.send(Data("hello".utf8))

// Receive — one awaited handler per object; registering it starts receiving
let sub = ts.onMessage { message in
    print(String(data: message.body, encoding: .utf8) ?? "<binary>")
    print(message.from.name)   // sender, same id as in ts.members
    print(message.id)          // stable tsm1_… id; the library deduplicates
}
```

Delivery is at least once, in per-sender order. The message is acked only after your handler completes — a throw retries (5 attempts, then a `handlerGaveUp` delivery issue). The library deduplicates on `message.id`; a handler never sees the same message twice. The handler runs off the main actor — don't block the main actor inside it (hop to `MainActor` explicitly for UI work); a blocked main actor stalls delivery, and the relay can see handler latency.

---

### Membership events

```swift
let sub = ts.onEvent { event in
    switch event {
    case .statusChanged(let status, let reason):
        break // member/created, notJoined/left|removed|destroyed|storeReset …
    case .membersChanged(let members):
        break // the whole current list, not deltas
    case .joinRequest, .connectionChanged, .admissionDropped:
        break
    }
}
```

To remove a member (they wipe and rotate automatically):

```swift
try ts.remove(memberId: ts.members[0].id)
```

`ts.leave()` leaves; `ts.destroyGroup()` destroys the group for everyone (durable, forwarded, honoured from any past or present member). In every case the same object reaches `notJoined` and can pair again — no rebuilding.

`ts.close()` stops the connection and handlers, keeping Session State; every later call fails with `TrueSealError.closed`.

---

## Errors

Exactly 14 cases, one `TrueSealError` enum, no catch-all — the same list in every SDK (sync ADR-0028 as amended):

`invalidRelayAddress` · `invalidNamespace` · `storage` · `closed` · `notMember(status)` · `alreadyInGroup` · `invalidPairingToken` · `pairingClosed` · `groupFull(max)` · `memberNotFound` · `payloadTooLarge(max)` · `messageHandlerAlreadySet` · `storeTooNew(found, supported)` · `manifestVersionExhausted`

Delivery problems that don't throw arrive on the optional `onDeliveryIssue` stream: `unreadable(reason)`, `unauthorized`, `heldForUpgrade(version)`, `handlerGaveUp(messageId, error)`, `sendFailed(messageId, reason)`.

---

## Architecture

```
Your App
   │  import TruesealSync
   ▼
TrueSeal                    ← idiomatic Swift (this SDK)
   │  @_implementationOnly import TruesealSyncBindings
   ▼
TruesealSyncBindings        ← UniFFI-generated Swift (internal)
   │
   ▼
TruesealSyncFFI.xcframework ← compiled Rust (trueseal-sync + trueseal-noise)
```

No UniFFI types or FFI concepts appear in the public surface. `TruesealSyncBindings` is an implementation detail — never import it directly.

---

## Local development

Requires the sibling repos checked out side-by-side:

```
trueseal/
  trueseal-noise/
  trueseal-sync/
  trueseal-sync-swift/   ← this repo
```

```bash
# One-time: install Rust targets
rustup target add \
    aarch64-apple-darwin x86_64-apple-darwin \
    aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

# Build XCFramework + generate Swift bindings
bash scripts/build-xcframework.sh
```

The committed `Package.swift` already points at the local path; the release workflow stamps `url:`+`checksum:` on each tag for SPM consumers.

Don't commit that — the published `Package.swift` uses `url:+checksum:` so SPM resolves correctly for remote consumers.

To cut a release: `git tag v0.x.x && git push origin v0.x.x`. The [release workflow](.github/workflows/release.yml) downloads the prebuilt XCFramework from the `trueseal-sync` release pinned by `TRUESEAL_SYNC_TAG`, attaches it to the GitHub Release, and stamps `Package.swift` with the correct `url`/`checksum` before retagging.

> **Note:** `scripts/build-xcframework.sh` is for local development only. CI does not run it — it downloads the prebuilt artifact from [trueseal-sync releases](https://github.com/julianbonomini/trueseal-sync/releases) instead.

---

## Further reading

- [trueseal-sync overview](https://trueseal.dev/docs/components/trueseal-sync/overview) — concepts, Group Manifest, pairing ceremony, outbox replay, delivery guarantees
- [trueseal-sync (Rust core)](https://github.com/julianbonomini/trueseal-sync) — source for the underlying crate
- [trueseal-relay](https://github.com/julianbonomini/trueseal-relay) — deploying and self-hosting the relay
- [Swift SDK reference](https://github.com/julianbonomini/trueseal-sync-swift) — full API docs (DocC)
- [trueseal ecosystem](https://github.com/julianbonomini) — trueseal-noise, trueseal-protocol, trueseal-clip

---

## License

Apache 2.0 — see [LICENSE](LICENSE).
