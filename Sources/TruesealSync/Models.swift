import Foundation
@_implementationOnly @preconcurrency import TruesealSyncBindings

// Public model types for the canonical TrueSeal API (sync ADR-0028).
// These mirror the core's FFI types one-to-one; zero FFI types leak into
// the public surface (the bindings are @_implementationOnly). The canonical
// names live in trueseal-sync docs/shared-facts.json — keep them aligned.

/// A group member (or this device, via ``TrueSeal/me``).
public struct Member: Equatable, Sendable {
    /// Stable identifier for this device's current identity. The same value
    /// appears in `members`, `TrueSealMessage.from.id` and `remove(memberId:)`.
    public let id: String
    /// Human-readable, auto-generated display name. Not an authenticator.
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A pending request to join the group, delivered as a `joinRequest` event
/// while a pairing window is open (ADR-0023).
public struct JoinRequest: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The typed form of a Relay Address (ADR-0028). The string form is
/// `trueseal://<relay public key hex>@host[:receivePort][?push=pushPort]`.
public struct RelayAddress: Equatable, Sendable {
    public let host: String
    public let publicKey: Data
    public let receivePort: UInt16
    public let pushPort: UInt16

    public init(host: String, publicKey: Data, receivePort: UInt16 = 7700, pushPort: UInt16 = 7701) {
        self.host = host
        self.publicKey = publicKey
        self.receivePort = receivePort
        self.pushPort = pushPort
    }
}

/// A delivered message (ADR-0026).
public struct TrueSealMessage: Equatable, Sendable {
    /// Stable, unique per sender (`tsm1_…`). The library deduplicates on it;
    /// a handler never sees the same message twice.
    public let id: String
    public let from: Member
    public let body: Data

    public init(id: String, from: Member, body: Data) {
        self.id = id
        self.from = from
        self.body = body
    }
}

/// Version reporting (ADR-0022/0030).
public struct TruesealInfo: Equatable, Sendable {
    public let sdkVersion: String
    public let transportVersion: UInt32
    public let endToEndVersion: UInt32

    public init(sdkVersion: String, transportVersion: UInt32, endToEndVersion: UInt32) {
        self.sdkVersion = sdkVersion
        self.transportVersion = transportVersion
        self.endToEndVersion = endToEndVersion
    }
}

/// Group membership state (ADR-0027/0029).
public enum GroupStatus: Equatable, Sendable {
    case notJoined
    case pendingJoin
    case member
    case leaving
    case destroying
}

/// Why ``GroupStatus`` changed. `statusChanged` fires only for the
/// asynchronous transitions (ADR-0028 statusChanged mapping, SYNC-15).
public enum StatusReason: Equatable, Sendable {
    case created
    case joined
    case left
    case removed
    case destroyed
    case storeReset
}

/// Relay connectivity (ADR-0028).
public enum ConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case disconnected
    /// The relay refused our Transport Version. The library keeps retrying
    /// in case the relay is upgraded (ADR-0022).
    case relayVersionUnsupported(min: UInt32, max: UInt32)
}

/// Why an admission could not be delivered to a joiner (ADR-0027).
public enum AdmissionDropReason: Equatable, Sendable {
    case groupFull
}

/// Why an inbound blob could not be read (ADR-0034).
public enum UnreadableReason: Equatable, Sendable {
    case malformed
    case senderOutdated
    case expired
    case droppedWhileHeld
}

/// Why a queued send failed permanently (ADR-0025/0026).
public enum SendFailedReason: Equatable, Sendable {
    case tooLarge
    case malformed
    case expired
}

/// The event sum type delivered to `onEvent` listeners (ADR-0028).
public enum TrueSealEvent: Equatable, Sendable {
    case statusChanged(status: GroupStatus, reason: StatusReason)
    /// The whole current member list, not deltas (ADR-0027).
    case membersChanged(members: [Member])
    case joinRequest(request: JoinRequest)
    case connectionChanged(connection: ConnectionState)
    case admissionDropped(name: String, reason: AdmissionDropReason)
}

/// The delivery-issue sum type (ADR-0026 as amended by ADR-0034).
/// Optional to observe; delivery itself does not depend on it.
public enum DeliveryIssue: Equatable, Sendable {
    case unreadable(reason: UnreadableReason)
    case unauthorized
    case heldForUpgrade(version: UInt32)
    case handlerGaveUp(messageId: String, error: String)
    case sendFailed(messageId: String, reason: SendFailedReason)
}

// MARK: - Bindings → public conversions (internal)

extension Member {
    init(_ ffi: TruesealSyncBindings.Member) {
        self.init(id: ffi.id, name: ffi.name)
    }
}

extension JoinRequest {
    init(_ ffi: TruesealSyncBindings.MemberRequest) {
        self.init(id: ffi.id, name: ffi.name)
    }
}

extension RelayAddress {
    init(_ ffi: TruesealSyncBindings.RelayAddress) {
        self.init(host: ffi.host, publicKey: ffi.publicKey, receivePort: ffi.receivePort, pushPort: ffi.pushPort)
    }

    var ffi: TruesealSyncBindings.RelayAddress {
        TruesealSyncBindings.RelayAddress(host: host, publicKey: publicKey, receivePort: receivePort, pushPort: pushPort)
    }
}

extension TrueSealMessage {
    init(_ ffi: TruesealSyncBindings.TrueSealMessage) {
        self.init(id: ffi.id, from: Member(ffi.from), body: ffi.body)
    }
}

extension TruesealInfo {
    init(_ ffi: TruesealSyncBindings.TruesealInfo) {
        self.init(sdkVersion: ffi.sdkVersion, transportVersion: ffi.transportVersion, endToEndVersion: ffi.endToEndVersion)
    }
}

extension GroupStatus {
    init(_ ffi: TruesealSyncBindings.GroupStatus) {
        switch ffi {
        case .notJoined: self = .notJoined
        case .pendingJoin: self = .pendingJoin
        case .member: self = .member
        case .leaving: self = .leaving
        case .destroying: self = .destroying
        }
    }
}

extension StatusReason {
    init(_ ffi: TruesealSyncBindings.StatusReason) {
        switch ffi {
        case .created: self = .created
        case .joined: self = .joined
        case .left: self = .left
        case .removed: self = .removed
        case .destroyed: self = .destroyed
        case .storeReset: self = .storeReset
        }
    }
}

extension ConnectionState {
    init(_ ffi: TruesealSyncBindings.ConnectionState) {
        switch ffi {
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .disconnected: self = .disconnected
        case .relayVersionUnsupported(let min, let max): self = .relayVersionUnsupported(min: min, max: max)
        }
    }
}

extension AdmissionDropReason {
    init(_ ffi: TruesealSyncBindings.AdmissionDropReason) {
        switch ffi {
        case .groupFull: self = .groupFull
        }
    }
}

extension UnreadableReason {
    init(_ ffi: TruesealSyncBindings.UnreadableReason) {
        switch ffi {
        case .malformed: self = .malformed
        case .senderOutdated: self = .senderOutdated
        case .expired: self = .expired
        case .droppedWhileHeld: self = .droppedWhileHeld
        }
    }
}

extension SendFailedReason {
    init(_ ffi: TruesealSyncBindings.SendFailedReason) {
        switch ffi {
        case .tooLarge: self = .tooLarge
        case .malformed: self = .malformed
        case .expired: self = .expired
        }
    }
}

extension TrueSealEvent {
    init(_ ffi: TruesealSyncBindings.TrueSealEvent) {
        switch ffi {
        case .statusChanged(let status, let reason):
            self = .statusChanged(status: GroupStatus(status), reason: StatusReason(reason))
        case .membersChanged(let members):
            self = .membersChanged(members: members.map(Member.init))
        case .joinRequest(let request):
            self = .joinRequest(request: JoinRequest(request))
        case .connectionChanged(let connection):
            self = .connectionChanged(connection: ConnectionState(connection))
        case .admissionDropped(let name, let reason):
            self = .admissionDropped(name: name, reason: AdmissionDropReason(reason))
        }
    }
}

extension DeliveryIssue {
    init(_ ffi: TruesealSyncBindings.DeliveryIssue) {
        switch ffi {
        case .unreadable(let reason):
            self = .unreadable(reason: UnreadableReason(reason))
        case .unauthorized:
            self = .unauthorized
        case .heldForUpgrade(let version):
            self = .heldForUpgrade(version: version)
        case .handlerGaveUp(let messageId, let error):
            self = .handlerGaveUp(messageId: messageId, error: error)
        case .sendFailed(let messageId, let reason):
            self = .sendFailed(messageId: messageId, reason: SendFailedReason(reason))
        }
    }
}
