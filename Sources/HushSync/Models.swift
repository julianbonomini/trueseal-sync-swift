import Foundation

// MARK: - ReceivedBlob

/// A blob delivered to this device from another member of the Sync Group.
///
/// The raw bytes are whatever the sender passed to ``HushSyncClient/publish(_:)``.
/// Use ``text`` for clipboard payloads encoded as UTF-8.
public struct ReceivedBlob: Sendable {
    /// Raw application payload.
    public let data: Data

    /// The sender's 32-byte X25519 noise public key.
    /// Stable per device — use as a sender identity token.
    public let senderPublicKey: Data

    /// Convenience: interprets ``data`` as UTF-8 text.
    public var text: String? {
        String(data: data, encoding: .utf8)
    }
}

// MARK: - SyncMember

/// A remote device that is a current member of the Sync Group.
public struct SyncMember: Sendable, Identifiable, Hashable {
    /// Opaque stable identifier derived from the member's signing public key.
    /// Suitable for use as a SwiftUI `id`.
    public let id: String

    /// Auto-generated human-readable name (e.g. "AmberFalcon").
    /// Derived deterministically from the signing key — no user-settable display names.
    public let name: String
}

// MARK: - PairingRequest

/// An incoming request from another device that wants to join the Sync Group.
///
/// Obtained from ``HushSyncClient/pairingRequests``.  Pass the whole value to
/// ``HushSyncClient/acceptPairingRequest(_:)`` to admit the device.
public struct PairingRequest: Sendable {
    /// Opaque token — pass back to ``HushSyncClient/acceptPairingRequest(_:)``.
    /// Never interpret the contents.
    public let token: String

    /// Auto-generated name for the requesting device.
    public let deviceName: String
}

// MARK: - MemberEvent

/// Lifecycle events for Sync Group membership.
///
/// Delivered via ``HushSyncClient/memberEvents``.
public enum MemberEvent: Sendable {
    /// A new device was admitted to the Sync Group (by any member).
    case joined(SyncMember)

    /// A device was removed via Soft Removal (by any member).
    /// Does **not** fire when the local device is removed — see ``removedSelf``.
    case left(SyncMember)

    /// The local device was excluded from the Sync Group by another member.
    case removedSelf

    /// Any member triggered a Destroy Group.  The session is now terminal;
    /// reconstruct ``HushSyncClient`` with the same namespace to start fresh.
    case groupDestroyed
}

// MARK: - ConnectionState

/// Informational relay connection state.
///
/// Delivered via ``HushSyncClient/connectionState``.
/// The library queues outbox messages and reconnects automatically —
/// callers may show a "syncing" indicator but should never gate on this.
public enum ConnectionState: Sendable {
    case connected
    case disconnected
}
