import Foundation
@_implementationOnly @preconcurrency import TruesealSyncBindings

/// Every error the TrueSeal SDK can raise (sync ADR-0028, as amended by
/// ADR-0032 and SYNC-15). Exactly 14 cases, one-to-one with the core —
/// there is no catch-all. The canonical names live in trueseal-sync
/// docs/shared-facts.json; the G12 parity check compares them.
public enum TrueSealError: Error, Equatable, Sendable {

    /// The Relay Address string is malformed (ADR-0028). Nothing was dialed.
    case invalidRelayAddress(String)

    /// The namespace is empty or outside `[a-zA-Z0-9_-]+`.
    case invalidNamespace(String)

    /// A durable write failed — the operation did not commit and no
    /// in-memory state changed. The caller may retry.
    case storage(String)

    /// The object was closed (`close()`). Every call after `close()` fails
    /// with this; Session State is kept on disk.
    case closed

    /// The operation needs group membership the device does not currently
    /// hold — sending while `notJoined`, `pendingJoin`, `leaving` or
    /// `destroying`, for example. Carries the status the call saw.
    case notMember(GroupStatus)

    /// `join(token:)` while the device is already in a group (any status
    /// other than `notJoined`).
    case alreadyInGroup

    /// The Pairing Token is malformed, or its Pairing Secret was already
    /// spent (ADR-0023).
    case invalidPairingToken

    /// The pairing window is not open (already closed, cancelled or expired).
    case pairingClosed

    /// The group is at the Maximum Group Size (ADR-0027).
    case groupFull(max: UInt32)

    /// `remove(memberId:)` named an id that is not a current member.
    case memberNotFound

    /// The body exceeds the effective Protocol Size Limit (ADR-0025).
    /// Nothing was queued; retrying the same body always fails.
    case payloadTooLarge(max: UInt32)

    /// A second `onMessage` registration. Registration is one-shot per
    /// object (ADR-0028).
    case messageHandlerAlreadySet

    /// Session State on disk was written by a newer release (ADR-0032).
    /// Nothing was touched; upgrade the SDK to open it.
    case storeTooNew(found: UInt32, supported: UInt32)

    /// The current manifest's version cannot be incremented (SYNC-10) —
    /// the group is frozen for good and its devices must pair again.
    case manifestVersionExhausted
}

extension TrueSealError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRelayAddress(let msg):
            return "Invalid relay address: \(msg)"
        case .invalidNamespace(let msg):
            return "Invalid namespace: \(msg)"
        case .storage(let msg):
            return "Storage error (nothing was committed; retry is safe): \(msg)"
        case .closed:
            return "This TrueSeal object is closed."
        case .notMember(let status):
            return "Operation requires group membership (current status: \(status))."
        case .alreadyInGroup:
            return "This device is already in a group."
        case .invalidPairingToken:
            return "The pairing token is invalid or already used."
        case .pairingClosed:
            return "The pairing window is closed."
        case .groupFull(let max):
            return "The group is full (maximum \(max) members)."
        case .memberNotFound:
            return "No current member with that id."
        case .payloadTooLarge(let max):
            return "Payload exceeds the protocol size limit (maximum \(max) bytes)."
        case .messageHandlerAlreadySet:
            return "A message handler is already registered (registration is one-shot)."
        case .storeTooNew(let found, let supported):
            return "Session State was written by a newer release (store v\(found), this SDK supports up to v\(supported)). Upgrade the SDK."
        case .manifestVersionExhausted:
            return "The group's manifest version space is exhausted; the group must pair again."
        }
    }
}

extension TrueSealError {
    /// Maps the core's FFI error to the public case. Total by construction:
    /// the generated enum has exactly these 14 variants (a 15th fails the
    /// core's own surface test), so the switch is exhaustive with no default.
    static func map(_ ffi: TruesealSyncBindings.TrueSealError) -> TrueSealError {
        switch ffi {
        case .InvalidRelayAddress(let msg): return .invalidRelayAddress(msg)
        case .InvalidNamespace(let msg): return .invalidNamespace(msg)
        case .Storage(let msg): return .storage(msg)
        case .Closed: return .closed
        case .NotMember(let status): return .notMember(GroupStatus(status))
        case .AlreadyInGroup: return .alreadyInGroup
        case .InvalidPairingToken: return .invalidPairingToken
        case .PairingClosed: return .pairingClosed
        case .GroupFull(let max): return .groupFull(max: max)
        case .MemberNotFound: return .memberNotFound
        case .PayloadTooLarge(let max): return .payloadTooLarge(max: max)
        case .MessageHandlerAlreadySet: return .messageHandlerAlreadySet
        case .StoreTooNew(let found, let supported): return .storeTooNew(found: found, supported: supported)
        case .ManifestVersionExhausted: return .manifestVersionExhausted
        }
    }
}
