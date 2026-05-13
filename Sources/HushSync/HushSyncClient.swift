import Foundation

@_implementationOnly import HushSyncBindings

/// The entry point for the HushSync SDK.
///
/// Wraps a Rust `HushFfiSession` with an idiomatic Swift concurrency API.
/// No FFI types, raw bytes, or Noise Protocol concepts appear in the public surface.
///
/// ## Lifecycle
///
/// ```swift
/// let client = try HushSyncClient(
///     relayURL: URL(string: "tcp://relay.example.com:4433")!,
///     relayPublicKey: Data(base64Encoded: "...")!
/// )
/// ```
///
/// Construction is **infallible with respect to relay connectivity** — the client
/// connects in the background and queues any outbox messages until the relay is reached.
/// The only throwing conditions are invalid arguments (URL, key length, namespace).
///
/// ## Pairing
///
/// One device calls ``generatePairingToken()`` and hands the token to the other device
/// out-of-band (QR code, AirDrop, etc.).  The other device calls ``joinGroup(token:)``.
/// The initiating device accepts via ``pairingRequests`` + ``acceptPairingRequest(_:)``.
///
/// ## Publishing & Receiving
///
/// ```swift
/// try await client.publish(text: "Hello from Mac")
///
/// for await blob in client.blobs {
///     print(blob.text ?? "<binary>")
/// }
/// ```
public final class HushSyncClient: @unchecked Sendable {

    // MARK: - Private state

    private let session: HushFfiSession

    // MARK: - Public async streams

    /// Incoming blobs pushed to this device by other Sync Group members.
    ///
    /// Iterate with `for await blob in client.blobs { … }`.
    /// The stream never finishes under normal operation; it completes only after
    /// ``destroyGroup()`` is called (or received from a remote member).
    public let blobs: AsyncStream<ReceivedBlob>

    /// Sync Group membership lifecycle events.
    ///
    /// Delivers ``MemberEvent`` values as they arrive.
    /// Finishes when the group is destroyed.
    public let memberEvents: AsyncStream<MemberEvent>

    /// Incoming pairing requests from devices that have scanned this device's token.
    ///
    /// Iterate and call ``acceptPairingRequest(_:)`` to admit each device.
    /// Call ``cancelPairing()`` to close the window without admitting anyone.
    public let pairingRequests: AsyncStream<PairingRequest>

    /// Informational relay connection state changes.
    ///
    /// The library reconnects automatically — use this for UI indicators only.
    /// Never gate on this stream before calling ``publish(_:)``.
    public let connectionState: AsyncStream<ConnectionState>

    // MARK: - Init

    /// Create a HushSync client.
    ///
    /// - Parameters:
    ///   - relayURL: TCP address of the relay, e.g. `tcp://relay.example.com:4433`.
    ///               Must include a host and port.
    ///   - relayPublicKey: 32-byte X25519 public key of the relay (obtained from your
    ///                     relay operator).  Wrong length throws ``HushSyncError/invalidRelayPublicKey``.
    ///   - storageDirectory: Directory for the session state database.
    ///                       Defaults to `Application Support/HushSync/`.
    ///   - namespace: Scopes the local database.  One client per namespace.
    ///                Valid pattern: `[a-zA-Z0-9_-]+`. Defaults to `"default"`.
    ///
    /// - Throws: ``HushSyncError`` for invalid arguments.
    ///           Never throws for relay connectivity — the client starts offline and
    ///           reconnects in the background.
    public init(
        relayURL: URL,
        relayPublicKey: Data,
        storageDirectory: URL = .defaultHushSyncStorage,
        namespace: String = "default"
    ) throws {
        guard let host = relayURL.host else {
            throw HushSyncError.invalidRelayURL
        }
        let baseDir = storageDirectory.path

        // Create continuations before the session so callbacks can fire immediately.
        let (blobStream, blobCont)       = AsyncStream.makeStream(of: ReceivedBlob.self)
        let (memberStream, memberCont)   = AsyncStream.makeStream(of: MemberEvent.self)
        let (pairingStream, pairingCont) = AsyncStream.makeStream(of: PairingRequest.self)
        let (connStream, connCont)       = AsyncStream.makeStream(of: ConnectionState.self)

        self.blobs           = blobStream
        self.memberEvents    = memberStream
        self.pairingRequests = pairingStream
        self.connectionState = connStream

        do {
            self.session = try HushFfiSession.create(
                baseDir: baseDir,
                namespace: namespace,
                relayHost: host,
                relayPub: relayPublicKey,
                onMessage:           BlobCallbackHandler(continuation: blobCont),
                onRemovedFromGroup:  MemberRemovedCallbackHandler(continuation: memberCont),
                onGroupDestroyed:    GroupDestroyedCallbackHandler(continuation: memberCont),
                onConnectionChanged: ConnectionChangedCallbackHandler(continuation: connCont)
            )
        } catch let e as SessionError {
            throw HushSyncError(from: e)
        }

        // Wire post-init callbacks (member request, joined, left).
        session.setOnMemberRequest(callback: PairingRequestCallbackHandler(continuation: pairingCont))
        session.setOnMemberJoined(callback: MemberJoinedCallbackHandler(continuation: memberCont))
        session.setOnMemberLeft(callback: MemberLeftCallbackHandler(continuation: memberCont))
    }

    // MARK: - Pairing

    /// Open a 60-second pairing window and return an opaque pairing token.
    ///
    /// Pass the token to the joining device out-of-band (QR code, AirDrop, etc.).
    /// The joining device calls ``joinGroup(token:)`` with it.
    /// This device then receives a ``PairingRequest`` via ``pairingRequests`` and
    /// must call ``acceptPairingRequest(_:)`` to complete the ceremony.
    ///
    /// - Returns: Base64url-encoded pairing token.  Single-use; expires after 60 s.
    public func generatePairingToken() -> String {
        session.pairingToken()
    }

    /// Join a Sync Group as the responding device.
    ///
    /// Decode the initiator's pairing token and push a `Pair` message via the relay.
    /// The initiating device will receive a ``PairingRequest`` and must call
    /// ``acceptPairingRequest(_:)`` to finalise membership.
    ///
    /// - Parameter token: Token obtained from the initiating device (QR scan, etc.).
    /// - Throws: ``HushSyncError/invalidPairingToken`` if the token is malformed or expired.
    public func joinGroup(token: String) throws {
        do {
            try session.joinGroup(token: token)
        } catch let e as SessionError {
            throw HushSyncError(from: e)
        }
    }

    /// Admit a device that sent a pairing request.
    ///
    /// Call this after receiving a ``PairingRequest`` from ``pairingRequests``.
    /// Silently ignored if the token is unknown or the pairing window has closed.
    ///
    /// - Parameter request: The request received from ``pairingRequests``.
    public func acceptPairingRequest(_ request: PairingRequest) {
        _ = session.acceptMember(token: request.token)
    }

    /// Close the pairing window without admitting any device.
    public func cancelPairing() {
        session.cancelPairing()
    }

    // MARK: - Publishing (Push)

    /// Encrypt `data` and fan it out to every current Sync Group member.
    ///
    /// If the relay is unreachable, the blob is durably queued in the local outbox
    /// and delivered automatically on reconnect.  Callers should **not** retry on error —
    /// ``HushSyncError/pushFailed(_:)`` is informational; the blob is already queued.
    ///
    /// - Parameter data: Application payload.  The relay never sees the plaintext.
    /// - Throws: ``HushSyncError/notInGroup`` if pairing has not completed.
    ///           ``HushSyncError/groupDestroyed`` if the group has been destroyed.
    public func publish(_ data: Data) async throws {
        try await Task.detached(priority: .userInitiated) { [session = self.session] in
            do {
                try session.send(blob: data)
            } catch let e as SessionError {
                throw HushSyncError(from: e)
            }
        }.value
    }

    /// Convenience: publish a UTF-8 string.  No-ops on encoding failure.
    ///
    /// - Parameter text: The string to publish.
    /// - Throws: Same as ``publish(_:)``.
    public func publish(text: String) async throws {
        guard let data = text.data(using: .utf8) else { return }
        try await publish(data)
    }

    // MARK: - Members

    /// Stable opaque identifier for the local device.
    ///
    /// Identical to the `id` this device has in a remote peer's ``members`` list.
    public var localNodeId: String {
        session.localNodeId()
    }

    /// Auto-generated display name for the local device.
    ///
    /// Identical to the `name` this device has in a remote peer's ``members`` list.
    public var localDeviceName: String {
        session.localDeviceName()
    }

    /// Current remote Sync Group members (excludes the local device).
    ///
    /// Empty until the first pairing completes.
    public var members: [SyncMember] {
        session.members().map { SyncMember(id: $0.id, name: $0.name) }
    }

    /// Remove a device from the Sync Group (Soft Removal).
    ///
    /// Issues a new Group Manifest excluding the target and propagates it to all
    /// remaining members.  The removed device fires ``MemberEvent/removedSelf``.
    ///
    /// This is cooperative, not cryptographically enforced.  Use ``destroyGroup()``
    /// if a device is compromised and cryptographic exclusion is required.
    ///
    /// - Parameter member: A value obtained from ``members``.
    /// - Throws: ``HushSyncError/notInGroup``, ``HushSyncError/memberNotFound``.
    public func removeMember(_ member: SyncMember) throws {
        do {
            try session.removeMember(memberId: member.id)
        } catch let e as SessionError {
            throw HushSyncError(from: e)
        }
    }

    // MARK: - Destroy Group

    /// Destroy the Sync Group.
    ///
    /// Pushes a `Revoke` message to every member, rotates this device's keypair,
    /// and wipes local session state.  Every device fires ``MemberEvent/groupDestroyed``.
    /// All streams complete after this call.
    ///
    /// Use this for security incidents (stolen/compromised device).  For routine
    /// member removal, prefer ``removeMember(_:)``.
    ///
    /// After calling this, create a new ``HushSyncClient`` with the same namespace
    /// to start fresh with a new identity.
    public func destroyGroup() {
        session.destroyGroup()
    }
}

// MARK: - Default storage directory

public extension URL {
    static var defaultHushSyncStorage: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("HushSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
