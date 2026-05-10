# HushSync Swift SDK

Idiomatic Swift wrapper for the [hush-sync](../hush-sync) Rust library.

E2EE, local-first sync between devices.  No FFI, no Noise Protocol, no raw keys.

---

## Requirements

- Xcode 15 / Swift 5.9+
- macOS 13+ · iOS 16+
- Rust toolchain + `rustup` (to build the XCFramework)

---

## Build the XCFramework

Run once before opening in Xcode or running `swift build`:

```bash
# Install Rust targets (one-time)
rustup target add \
    aarch64-apple-darwin x86_64-apple-darwin \
    aarch64-apple-ios \
    aarch64-apple-ios-sim x86_64-apple-ios

# Build
bash scripts/build-xcframework.sh
```

This produces `HushSyncFFI.xcframework` and installs generated Swift bindings
into `Sources/HushSyncBindings/`.

---

## Add to your project

### Swift Package Manager

```swift
// Package.swift
dependencies: [
    .package(path: "../hush-sync-swift"),   // local
    // or a tagged release:
    // .package(url: "https://github.com/your-org/hush-sync-swift", from: "0.1.0"),
],
targets: [
    .target(name: "YourApp", dependencies: ["HushSync"]),
]
```

---

## Usage

### 1. Initialise

```swift
import HushSync

let client = try HushSyncClient(
    relayURL: URL(string: "tcp://relay.example.com:4433")!,
    relayPublicKey: Data(base64Encoded: "<32-byte relay pub key, base64>")!
)
// storageDirectory and namespace have sensible defaults.
// The client is immediately usable — relay connects in the background.
```

### 2. Pair two devices

**Device A** — generates a pairing token (show as QR code, AirDrop, etc.):

```swift
let token = clientA.generatePairingToken()
// display `token` to the user
```

**Device B** — scans the token and requests to join:

```swift
try clientB.joinGroup(token: token)
```

**Device A** — accepts the request:

```swift
for await request in clientA.pairingRequests {
    print("Pairing request from: \(request.deviceName)")
    clientA.acceptPairingRequest(request)
    break   // single-use window
}
```

### 3. Publish a clipboard entry

```swift
try await client.publish(text: "Hello from Mac")

// or raw data:
try await client.publish(someData)
```

### 4. Receive blobs

```swift
Task {
    for await blob in client.blobs {
        if let text = blob.text {
            print("Received: \(text)")
        }
    }
}
```

### 5. List & remove members

```swift
let members = client.members
print(members.map(\.name))  // ["AmberFalcon", "CrimsonOwl"]

try client.removeMember(members[0])   // Soft Removal — no key rotation
```

### 6. Handle membership events

```swift
Task {
    for await event in client.memberEvents {
        switch event {
        case .joined(let m):   print("\(m.name) joined")
        case .left(let m):     print("\(m.name) left")
        case .removedSelf:     print("This device was removed from the group")
        case .groupDestroyed:  print("Group destroyed — reinitialise to start fresh")
        }
    }
}
```

### 7. Destroy group (security incident)

```swift
client.destroyGroup()
// Every member receives .groupDestroyed.
// All devices rotate keypairs automatically on next init.
```

---

## Error handling

All errors are ``HushSyncError`` — a Swift enum conforming to `Error` and `LocalizedError`.

```swift
do {
    try await client.publish(text: "hello")
} catch HushSyncError.notInGroup {
    // Pairing not yet complete
} catch HushSyncError.groupDestroyed {
    // Reinitialise the client
} catch {
    print(error.localizedDescription)
}
```

---

## Architecture

```
Your App
   │  import HushSync
   ▼
HushSyncClient          ← idiomatic Swift (this SDK)
   │  @_implementationOnly import HushSyncBindings
   ▼
HushSyncBindings        ← UniFFI-generated Swift (internal, never public)
   │
   ▼
HushSyncFFI.xcframework ← compiled Rust (hush-sync + hush-noise)
```

No UniFFI types, raw bytes, or Noise Protocol concepts cross the public boundary.

---

## License

Apache 2.0 — see [LICENSE](LICENSE).
