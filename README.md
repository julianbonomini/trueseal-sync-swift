# trueseal-sync-swift

> **Developer Preview.** Every package is `0.x` and openly allowed to break — the API,
> the wire format and stored data may change without notice. Each breaking release
> carries upgrade steps. See the
> [preview lifecycle](https://trueseal.dev/agents/developer-preview).

The Swift SDK for [TrueSeal](https://trueseal.dev) — end-to-end encrypted, local-first
sync between a group of devices. No accounts. The relay can't read or forge messages;
[here is exactly what it does see](https://trueseal.dev/agents/threat-model).

Pure-Swift surface over the Rust core ([trueseal-sync](https://github.com/julianbonomini/trueseal-sync))
— no FFI types, no Noise Protocol, no raw pointers.

**Platforms:** macOS 14+ · iOS 17+ · Swift 5.9+ / Xcode 15+

---

## Install

```swift
// Package.swift
.package(url: "https://github.com/julianbonomini/trueseal-sync-swift", from: "0.6.0")
```

No Rust toolchain needed. A pre-built XCFramework ships with every
[release](https://github.com/julianbonomini/trueseal-sync-swift/releases) and SPM
downloads it automatically.

---

## Open

You need a relay — a server that routes encrypted blobs between devices. One Relay
Address string carries its key, host and both ports; the relay CLI prints it
(`trueseal-relay address --host relay.example.com`). To run one, see
[self-hosting](https://trueseal.dev/agents/running-a-relay).

```swift
import TruesealSync

let ts = try await TrueSeal.open(
    relay: "trueseal://<relay public key hex>@relay.example.com",
    storage: try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true)
)
```

Session State lives under `storage` (excluded from backups; data at rest is protected
by the OS sandbox). `open` returns before the connection is up — the outbox queues and
replays once the relay is reachable. State is `@Observable` for SwiftUI: `ts.status`,
`ts.me`, `ts.members`, `ts.connection`.

> **Required entitlement.** Without this, the relay connection silently fails:
> ```xml
> <!-- YourApp.entitlements -->
> <key>com.apple.security.network.client</key>
> <true/>
> ```
> Add it on both macOS and iOS targets.

---

## Pair two devices

Devices sync within a group. You bootstrap the group by pairing: one device opens a
window and hands over a token; the other joins with it; the first accepts. The token
carries a single-use secret — it does not expire on a timer; the window closes when
the device cancels it or accepts a join.

**Device A** — open the pairing window and get a token (show it as a QR code, send via
AirDrop, etc.):

```swift
let token = try tsA.startPairing()
```

**Device B** — join with the token (status becomes `pendingJoin` until the first
manifest arrives):

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

## Send & receive

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

Delivery is at least once, in per-sender order. The message is acked only after your
handler completes — a throw retries (5 attempts, then a `handlerGaveUp` delivery
issue). The library deduplicates on `message.id`; a handler never sees the same
message twice. The handler runs off the main actor — hop to `MainActor` explicitly for
UI work; don't block it, a hung handler stalls delivery. The same rule applies to
`onEvent` / `onDeliveryIssue` listeners, which share one FFI listener bus: return
promptly — a listener parked longer than the core's liveness window (~75 s) wedges
event delivery for the whole object and tears the session down around it.

Call `ts.close()` when you're done — it stops the connection and handlers, keeping
Session State; every later call fails with `TrueSealError.closed`.

---

## Reference

This README is a quickstart. The full reference lives in the docs:

- **[Human Docs](https://trueseal.dev/docs/integrate/integrating-trueseal-sync)** —
  integrating TrueSeal, pairing, membership, sending and receiving, errors and events
- **[Agent Docs: SDK API reference](https://trueseal.dev/agents/api)** — every public
  type, method, error case and limit, canonical across all three SDKs (paste-friendly
  for coding agents; the [Agent Docs tree](https://trueseal.dev/agents/) has the rest)
- **[Threat Model](https://trueseal.dev/agents/threat-model)** — every security claim,
  the tests that prove it, and the limitations
- **[Developer Preview lifecycle](https://trueseal.dev/agents/developer-preview)** —
  version rules and upgrade notes

Security reports: see [SECURITY.md](SECURITY.md). Hacking on the SDK itself:
[CONTRIBUTING.md](CONTRIBUTING.md).

---

## License

Apache 2.0 — see [LICENSE](LICENSE).
