import Foundation
import Observation
@_implementationOnly @preconcurrency import TruesealSyncBindings

/// The canonical TrueSeal entry type (sync ADR-0028).
///
/// One object represents this device. It outlives group membership: after
/// removal, `leave()` or `destroyGroup()` the library wipes the namespace,
/// rotates to a fresh identity and the same object reaches `notJoined`,
/// ready to pair again. `close()` stops the connection and handlers but
/// keeps Session State on disk; every call after `close()` fails with
/// ``TrueSealError/closed``.
///
/// State (`status`, `me`, `members`, `connection`) is `@Observable` and
/// main-actor isolated for SwiftUI. Pairing and membership operations
/// run on the main actor and refresh state immediately (synchronous
/// transitions raise no event, ADR-0028); `send` and the `on…`
/// registrations are `nonisolated` — the core handle is thread-safe, so
/// the hot path never blocks the main actor.
@MainActor @Observable
public final class TrueSeal {

    // MARK: - Observable state

    /// Group membership state. `statusChanged` events fire only for the
    /// asynchronous transitions; synchronous ones are knowable from the
    /// initiating call's success (ADR-0028 statusChanged mapping).
    public private(set) var status: GroupStatus

    /// This device's current identity. Changes when the identity rotates
    /// (removal, leave, Destroy Group).
    public private(set) var me: Member

    /// Every other current member (empty unless `status == .member`).
    public private(set) var members: [Member]

    /// Relay connectivity.
    public private(set) var connection: ConnectionState

    // MARK: - Internals

    @ObservationIgnored private nonisolated let core: TruesealSyncBindings.TrueSeal
    @ObservationIgnored private var stateSubscription: TruesealSyncBindings.Subscription?

    private init(core: TruesealSyncBindings.TrueSeal) throws {
        self.core = core
        self.status = GroupStatus(try core.status())
        self.me = Member(try core.me())
        self.members = ((try? core.members()) ?? []).map(Member.init)
        self.connection = ConnectionState(try core.connection())

        // Keep the observable state in lockstep with the core. The core
        // buffers events raised before a listener registers, so no
        // transition is lost between open() and this subscription.
        let bridge = EventListenerBridge { [weak self] event in
            Task { @MainActor [weak self] in
                self?.applyStateChange(event)
            }
        }
        self.stateSubscription = try core.onEvent(listener: bridge)
    }

    /// Re-reads state from the core. Called after synchronous transitions
    /// (join → pendingJoin, leave → leaving, destroyGroup → destroying,
    /// cancelJoin → notJoined) raise NO event by design (ADR-0028
    /// statusChanged mapping) — without this the observable state would
    /// lag the call the app just made.
    private func refreshState() {
        if let s = try? core.status() { status = GroupStatus(s) }
        if let m = try? core.me() { me = Member(m) }
        members = ((try? core.members()) ?? []).map(Member.init)
        if let c = try? core.connection() { connection = ConnectionState(c) }
    }

    private func applyStateChange(_ event: TrueSealEvent) {
        switch event {
        case .statusChanged(let newStatus, _):
            status = newStatus
            // Identity may have rotated across this transition.
            if let refreshed = try? core.me() { me = Member(refreshed) }
            if newStatus != .member { members = [] }
        case .membersChanged(let newMembers):
            members = newMembers
        case .connectionChanged(let newConnection):
            connection = newConnection
        case .joinRequest, .admissionDropped:
            break
        }
    }

    // MARK: - Open

    /// Opens (or creates) Session State under `storage` and connects to the
    /// relay in the background. Returns before the connection is up;
    /// `send(_:)` works immediately via the outbox (ADR-0026).
    ///
    /// - Parameters:
    ///   - relay: the Relay Address string,
    ///     `trueseal://<relay public key hex>@host[:receivePort][?push=pushPort]`.
    ///     The relay CLI prints it (`trueseal-relay address --host <host>`).
    ///   - storage: directory for Session State. It is excluded from
    ///     backups (ADR-0032); data at rest is protected by the OS sandbox.
    ///   - namespace: isolates independent groups on one device.
    ///   - maxPayloadBytes: optional operator-lowered limit; clamped at the
    ///     protocol ceiling (61,440).
    public nonisolated static func open(
        relay: String,
        storage: URL,
        namespace: String = "default",
        maxPayloadBytes: UInt32? = nil
    ) async throws -> TrueSeal {
        let core: TruesealSyncBindings.TrueSeal
        do {
            core = try TruesealSyncBindings.TrueSeal.open(
                relay: relay,
                baseDir: storage.path,
                namespace: namespace,
                maxPayloadBytes: maxPayloadBytes
            )
        } catch let error as TruesealSyncBindings.TrueSealError {
            throw TrueSealError.map(error)
        }
        return try await MainActor.run { try TrueSeal(core: core) }
    }

    /// `open(relay:…)` with the typed Relay Address form.
    public nonisolated static func open(
        relay: RelayAddress,
        storage: URL,
        namespace: String = "default",
        maxPayloadBytes: UInt32? = nil
    ) async throws -> TrueSeal {
        let core: TruesealSyncBindings.TrueSeal
        do {
            core = try TruesealSyncBindings.TrueSeal.openWithAddress(
                relay: relay.ffi,
                baseDir: storage.path,
                namespace: namespace,
                maxPayloadBytes: maxPayloadBytes
            )
        } catch let error as TruesealSyncBindings.TrueSealError {
            throw TrueSealError.map(error)
        }
        return try await MainActor.run { try TrueSeal(core: core) }
    }

    // MARK: - Lifecycle

    /// Stops the connection and the handlers, keeping Session State on
    /// disk. Every call after `close()` fails with ``TrueSealError/closed``.
    public nonisolated func close() {
        core.close()
    }

    // MARK: - Sending

    /// Queues `body` for fan-out to every member and returns the Message ID
    /// once it is durably in the outbox (ADR-0026). Delivery is at least
    /// once, in per-sender order. Fails immediately with
    /// ``TrueSealError/payloadTooLarge(max:)`` or ``TrueSealError/notMember(_:)``.
    public nonisolated func send(_ body: Data) throws -> String {
        do {
            return try core.send(body: body)
        } catch let error as TruesealSyncBindings.TrueSealError {
            throw TrueSealError.map(error)
        }
    }

    // MARK: - Receiving

    /// Registers the single message handler; registering it starts
    /// receiving (ADR-0026). The handler is awaited: the message is acked
    /// only after it completes, and a throw is a handler attempt (5 tries,
    /// then `handlerGaveUp`). Registration is one-shot per object — a
    /// second call fails with ``TrueSealError/messageHandlerAlreadySet``
    /// and cancelling the returned subscription does not re-enable it.
    public nonisolated func onMessage(
        _ handler: @escaping @Sendable (TrueSealMessage) async throws -> Void
    ) throws -> Subscription {
        do {
            return Subscription(try core.onMessage(handler: MessageHandlerBridge(handler)))
        } catch let error as TruesealSyncBindings.TrueSealError {
            throw TrueSealError.map(error)
        }
    }

    /// Registers an event listener. Any number of listeners; events raised
    /// before the first registration are buffered (ADR-0028).
    public nonisolated func onEvent(
        _ listener: @escaping @Sendable (TrueSealEvent) -> Void
    ) throws -> Subscription {
        do {
            return Subscription(try core.onEvent(listener: EventListenerBridge(listener)))
        } catch let error as TruesealSyncBindings.TrueSealError {
            throw TrueSealError.map(error)
        }
    }

    /// Registers a delivery-issue listener (optional; ADR-0026).
    public nonisolated func onDeliveryIssue(
        _ listener: @escaping @Sendable (DeliveryIssue) -> Void
    ) throws -> Subscription {
        do {
            return Subscription(try core.onDeliveryIssue(listener: IssueListenerBridge(listener)))
        } catch let error as TruesealSyncBindings.TrueSealError {
            throw TrueSealError.map(error)
        }
    }

    // MARK: - Pairing (admitting side)

    /// Opens the pairing window and returns the Pairing Token for the
    /// joiner (ADR-0023). Join requests arrive as `joinRequest` events.
    public func startPairing() throws -> String {
        do {
            let token = try core.startPairing()
            refreshState()
            return token
        } catch let error as TruesealSyncBindings.TrueSealError {
            throw TrueSealError.map(error)
        }
    }

    /// Admits a join request. Fails with ``TrueSealError/pairingClosed``,
    /// ``TrueSealError/groupFull(max:)`` or
    /// ``TrueSealError/manifestVersionExhausted``. There is no reject —
    /// the protocol sends no decline (ADR-0023).
    public func accept(requestId: String) throws {
        do {
            try core.accept(requestId: requestId)
            refreshState()
        } catch let error as TruesealSyncBindings.TrueSealError {
            throw TrueSealError.map(error)
        }
    }

    /// Closes the pairing window. Unaccepted requests disappear with it.
    public func cancelPairing() throws {
        do {
            try core.cancelPairing()
            refreshState()
        } catch let error as TruesealSyncBindings.TrueSealError {
            throw TrueSealError.map(error)
        }
    }

    // MARK: - Pairing (joining side)

    /// Joins the group named by the Pairing Token, moving this device to
    /// `pendingJoin` until the first manifest arrives (ADR-0023).
    public func join(token: String) throws {
        do {
            try core.join(token: token)
            refreshState()
        } catch let error as TruesealSyncBindings.TrueSealError {
            throw TrueSealError.map(error)
        }
    }

    /// Abandons a pending join, back to `notJoined`.
    public func cancelJoin() throws {
        do {
            try core.cancelJoin()
            refreshState()
        } catch let error as TruesealSyncBindings.TrueSealError {
            throw TrueSealError.map(error)
        }
    }

    // MARK: - Membership

    /// Removes a member by id (any member may remove; ADR-0027). The
    /// removed device wipes and rotates automatically.
    public func remove(memberId: String) throws {
        do {
            try core.remove(memberId: memberId)
            refreshState()
        } catch let error as TruesealSyncBindings.TrueSealError {
            throw TrueSealError.map(error)
        }
    }

    /// Leaves the group: `leaving` now, `notJoined` with reason `left`
    /// once the relay has accepted the Leave (ADR-0027).
    public func leave() throws {
        do {
            try core.leave()
            refreshState()
        } catch let error as TruesealSyncBindings.TrueSealError {
            throw TrueSealError.map(error)
        }
    }

    /// Destroys the group for every current member (ADR-0029). Durable and
    /// forwarded; honoured from any past or present member.
    public func destroyGroup() throws {
        do {
            try core.destroyGroup()
            refreshState()
        } catch let error as TruesealSyncBindings.TrueSealError {
            throw TrueSealError.map(error)
        }
    }

    // MARK: - Info, limits, parsing (module functions)

    /// Version reporting (ADR-0022/0030).
    public nonisolated static var info: TruesealInfo {
        TruesealInfo(TruesealSyncBindings.truesealInfo())
    }

    /// The Protocol Size Limit on a `send` body, in bytes (ADR-0025).
    public nonisolated static var maxPayloadBytes: UInt32 {
        TruesealSyncBindings.truesealMaxPayloadBytes()
    }

    /// The Maximum Group Size (ADR-0027).
    public nonisolated static var maxGroupSize: UInt32 {
        TruesealSyncBindings.truesealMaxGroupSize()
    }

    /// Parses a Relay Address string into its typed form (strict grammar;
    /// uppercase hex in the key accepted). Throws
    /// ``TrueSealError/invalidRelayAddress(_:)``.
    public nonisolated static func parseRelayAddress(_ input: String) throws -> RelayAddress {
        do {
            return RelayAddress(try TruesealSyncBindings.truesealParseRelayAddress(input: input))
        } catch let error as TruesealSyncBindings.TrueSealError {
            throw TrueSealError.map(error)
        }
    }
}

extension TrueSeal {

    /// Cancel handle returned by every `on…` registration (ADR-0028).
    ///
    /// `@unchecked Sendable`: the core's Subscription handle is a Rust
    /// object behind the core's own synchronization; `cancel()` is safe
    /// from any thread.
    public struct Subscription: @unchecked Sendable {
        private let core: TruesealSyncBindings.Subscription

        init(_ core: TruesealSyncBindings.Subscription) {
            self.core = core
        }

        public func cancel() {
            core.cancel()
        }
    }
}
