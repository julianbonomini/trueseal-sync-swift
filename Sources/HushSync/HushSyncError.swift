import Foundation

/// All errors surfaced by ``HushSyncClient``.
///
/// Maps one-to-one with the Rust `SessionError` variants; zero FFI types leak through.
public enum HushSyncError: Error, LocalizedError, Sendable {

    /// Relay URL missing a host or port component.
    case invalidRelayURL

    /// The relay public key was not exactly 32 bytes.
    case invalidRelayPublicKey

    /// The namespace string contains illegal characters or is empty.
    /// Valid pattern: `[a-zA-Z0-9_-]+`
    case invalidNamespace(String)

    /// Push (blob fan-out) failed.  The blob was durably queued in the outbox
    /// and will be retried on reconnect — this error is informational.
    case pushFailed(String)

    /// The pairing token was malformed or expired.
    case invalidPairingToken

    /// An operation that requires group membership was attempted before pairing.
    case notInGroup

    /// The target member ID was not found in the current Group Manifest.
    case memberNotFound

    /// The group has been destroyed.  Reconstruct ``HushSyncClient`` with the
    /// same namespace to start fresh with a new identity.
    case groupDestroyed

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .invalidRelayURL:
            return "Invalid relay URL — must include a host and port."
        case .invalidRelayPublicKey:
            return "Relay public key must be exactly 32 bytes."
        case .invalidNamespace(let msg):
            return "Invalid namespace: \(msg)"
        case .pushFailed(let msg):
            return "Push failed: \(msg)"
        case .invalidPairingToken:
            return "The pairing token is invalid or has expired."
        case .notInGroup:
            return "Not in any Sync Group — complete pairing first."
        case .memberNotFound:
            return "Member not found in the current Sync Group."
        case .groupDestroyed:
            return "The Sync Group has been destroyed."
        }
    }
}

// MARK: - Internal conversion from UniFFI SessionError

// Kept internal — HushSyncBindings is imported @_implementationOnly,
// so SessionError is never visible to callers.
extension HushSyncError {
    init(from ffi: SessionError) {
        switch ffi {
        case .InvalidKeyLength:
            self = .invalidRelayPublicKey
        case .InvalidRelayPublicKey:
            self = .invalidRelayPublicKey
        case .InvalidNamespace(let msg):
            self = .invalidNamespace(msg)
        case .PushFailed(let msg):
            self = .pushFailed(msg)
        case .InvalidToken:
            self = .invalidPairingToken
        case .NotInGroup:
            self = .notInGroup
        case .MemberNotFound:
            self = .memberNotFound
        case .GroupDestroyed:
            self = .groupDestroyed
        }
    }
}
