# trueseal-sync-swift

Swift SDK for [trueseal-sync](https://github.com/julianbonomini/trueseal-sync) — E2EE, local-first sync between devices. No accounts. No server that can read your data.

Wraps the Rust core via UniFFI. The public surface is pure Swift — no FFI types, no Noise Protocol, no raw pointers.

**Platforms:** macOS 13+ · iOS 16+ · Swift 5.9+ / Xcode 15+

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

let client = try TruesealSyncClient(
    relayURL: URL(string: "tcp://relay.example.com")!,
    relayPublicKey: hexToData("your64charhexstring")  // 32-byte X25519 key
)
```

The relay's public key is a build-time constant. Get it from your relay operator, or run `trueseal-relay --print-pubkey` if self-hosting. To decode a hex string:

```swift
func hexToData(_ hex: String) -> Data {
    var data = Data()
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        data.append(UInt8(hex[i..<j], radix: 16)!)
        i = j
    }
    return data
}
```

The client connects to the relay in the background. It's usable immediately — the outbox queues blobs and replays them once the relay is reachable.

> **Required entitlement.** Without this, the relay connection silently fails:
> ```xml
> <!-- YourApp.entitlements -->
> <key>com.apple.security.network.client</key>
> <true/>
> ```
> Add it on both macOS and iOS targets.

---

### Pair two devices

Devices sync within a *Sync Group* — a set of mutually-trusted devices. You bootstrap the group by pairing. One device generates a token; the other scans it; the first accepts.

**Device A** — open a 60-second pairing window and get a token (show it as a QR code, send via AirDrop, etc.):

```swift
let token = clientA.generatePairingToken()
```

**Device B** — submit the token:

```swift
try clientB.joinGroup(token: token)
```

**Device A** — a pairing request arrives; accept it to finalise membership:

```swift
for await request in clientA.pairingRequests {
    print("Request from: \(request.deviceName)")
    clientA.acceptPairingRequest(request)
    break  // token is single-use
}
```

After `acceptPairingRequest`, both devices are full members and can send and receive.

---

### Send & receive

```swift
// Send — throws .notInGroup until pairing is complete
try await client.publish(text: "hello")
try await client.publish(someData)

// Receive
Task {
    for await blob in client.blobs {
        print(blob.text ?? "<binary>")         // convenience UTF-8 decode
        print(blob.senderPublicKey.count)      // 32 — stable identity per device
    }
}
```

---

### Membership events

```swift
Task {
    for await event in client.memberEvents {
        switch event {
        case .joined(let m):   // new device admitted
        case .left(let m):     // device removed by another member
        case .removedSelf:     // this device was removed
        case .groupDestroyed:  // session is terminal — all streams complete here
        }
    }
}
```

To remove a member (soft removal, no key rotation):

```swift
try client.removeMember(client.members[0])
```

To cryptographically exclude a compromised device, use `destroyGroup()` instead. Every member receives `.groupDestroyed`, all streams complete, and devices rotate keypairs on the next init.

---

## Errors

All errors are `TruesealSyncError`, conforming to `LocalizedError`.

| Case | When |
|------|------|
| `.notInGroup` | Published before pairing completed |
| `.invalidPairingToken` | Token malformed or window expired |
| `.groupDestroyed` | Session terminal — reconstruct the client |
| `.pushFailed(msg)` | Informational; blob is already queued in the outbox |
| `.memberNotFound` | ID not in the current Group Manifest |
| `.invalidRelayPublicKey` | Key not exactly 32 bytes |
| `.invalidRelayURL` | URL missing a host component |

---

## Architecture

```
Your App
   │  import TruesealSync
   ▼
TruesealSyncClient          ← idiomatic Swift (this SDK)
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

Then point `Package.swift` at the local framework:

```swift
.binaryTarget(name: "TruesealSyncFFI", path: "TruesealSyncFFI.xcframework")
```

Don't commit that — the published `Package.swift` uses `url:+checksum:` so SPM resolves correctly for remote consumers.

To cut a release: `git tag v0.x.x && git push origin v0.x.x`. The [release workflow](.github/workflows/release.yml) builds the XCFramework, attaches it to the GitHub Release, and stamps `Package.swift` with the correct `url`/`checksum` before retagging.

---

## Further reading

- [trueseal-sync concepts](https://github.com/julianbonomini/trueseal-sync) — Group Manifest, pairing ceremony, outbox replay, delivery guarantees
- [trueseal-relay](https://github.com/julianbonomini/trueseal-relay) — deploying and self-hosting the relay
- [Swift SDK reference](https://github.com/julianbonomini/trueseal-sync-swift) — full API docs (DocC)
- [trueseal ecosystem](https://github.com/julianbonomini) — trueseal-noise, trueseal-protocol, trueseal-clip

---

## License

Apache 2.0 — see [LICENSE](LICENSE).
