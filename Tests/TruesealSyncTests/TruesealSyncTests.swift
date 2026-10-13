import XCTest
import Observation
@testable import TruesealSync
import TruesealSyncBindings

// Both modules export the same type names (the public mirrors and the
// FFI originals); pin the unqualified names in this file to the PUBLIC
// ones. FFI types are always fully qualified below.
typealias TrueSeal = TruesealSync.TrueSeal
typealias TrueSealError = TruesealSync.TrueSealError
typealias Member = TruesealSync.Member
typealias JoinRequest = TruesealSync.JoinRequest
typealias RelayAddress = TruesealSync.RelayAddress
typealias TrueSealMessage = TruesealSync.TrueSealMessage
typealias GroupStatus = TruesealSync.GroupStatus
typealias StatusReason = TruesealSync.StatusReason
typealias ConnectionState = TruesealSync.ConnectionState

// SDK-1 (#2): the canonical TrueSeal API.
//
// Every test here runs against the REAL Rust core on the host (a local
// XCFramework or the CI-downloaded one), pointed at a dead relay address —
// open() returns immediately and the outbox queues locally, so all local
// state machines are exercisable offline. What genuinely needs a live
// relay (full removal/leave/destroy cycles, groupFull, memberNotFound,
// storeTooNew, accept/group flows) is covered by the cross-SDK e2e
// Scenario Driver (G1) and is listed as such at the bottom.

final class TrueSealApiTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
    }

    private func makeStorage() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trueseal-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// A syntactically valid Relay Address pointing at a port nothing
    /// listens on — open() succeeds, the background connect fails quietly.
    private let deadRelay =
        "trueseal://0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef@127.0.0.1:9?push=9"

    @MainActor
    private func openSession(namespace: String = "default") async throws -> TrueSeal {
        try await TrueSeal.open(relay: deadRelay, storage: makeStorage(), namespace: namespace)
    }

    // MARK: - Constants and info (ADR-0022/0025/0027/0030)

    func test_maxPayloadBytes_isTheProtocolLimit() {
        XCTAssertEqual(TrueSeal.maxPayloadBytes, 61_440)
    }

    func test_maxGroupSize_is32() {
        XCTAssertEqual(TrueSeal.maxGroupSize, 32)
    }

    func test_info_reportsVersions() {
        let info = TrueSeal.info
        XCTAssertFalse(info.sdkVersion.isEmpty)
        XCTAssertEqual(info.transportVersion, 1)
        XCTAssertEqual(info.endToEndVersion, 1)
    }

    // MARK: - Relay Address parsing (ADR-0028 grammar)

    func test_parseRelayAddress_validString() throws {
        let addr = try TrueSeal.parseRelayAddress(deadRelay)
        XCTAssertEqual(addr.host, "127.0.0.1")
        XCTAssertEqual(addr.publicKey.count, 32)
        XCTAssertEqual(addr.receivePort, 9)
        XCTAssertEqual(addr.pushPort, 9)
    }

    func test_parseRelayAddress_defaultsPorts() throws {
        let addr = try TrueSeal.parseRelayAddress(
            "trueseal://0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef@relay.example.com")
        XCTAssertEqual(addr.receivePort, 7700)
        XCTAssertEqual(addr.pushPort, 7701)
    }

    func test_parseRelayAddress_uppercaseHexAccepted() throws {
        XCTAssertNoThrow(try TrueSeal.parseRelayAddress(
            "trueseal://0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF@relay.example.com"))
    }

    func test_parseRelayAddress_garbageThrowsInvalidRelayAddress() {
        for bad in ["", "tcp://x", "trueseal://xyz@host", "trueseal://\(String(repeating: "ab", count: 32))@"] {
            XCTAssertThrowsError(try TrueSeal.parseRelayAddress(bad), "'\(bad)'") { error in
                guard case TrueSealError.invalidRelayAddress = error else {
                    return XCTFail("expected invalidRelayAddress, got \(error)")
                }
            }
        }
    }

    func test_open_withTypedRelayAddress() async throws {
        let addr = try TrueSeal.parseRelayAddress(deadRelay)
        let ts = try await TrueSeal.open(relay: addr, storage: makeStorage())
        let status = await ts.status
        XCTAssertEqual(status, .notJoined)
        await ts.close()
    }

    // MARK: - Error cases reachable through the real core

    @MainActor
    func test_open_badNamespaceThrowsInvalidNamespace() async {
        do {
            _ = try await TrueSeal.open(relay: deadRelay, storage: makeStorage(), namespace: "bad ns!")
            XCTFail("expected invalidNamespace")
        } catch TrueSealError.invalidNamespace {
        } catch {
            XCTFail("expected invalidNamespace, got \(error)")
        }
    }

    @MainActor
    func test_open_malformedRelayThrowsInvalidRelayAddress() async {
        do {
            _ = try await TrueSeal.open(relay: "not-an-address", storage: makeStorage())
            XCTFail("expected invalidRelayAddress")
        } catch TrueSealError.invalidRelayAddress {
        } catch {
            XCTFail("expected invalidRelayAddress, got \(error)")
        }
    }

    @MainActor
    func test_sendWhileNotJoinedThrowsNotMember() async throws {
        let ts = try await openSession()
        XCTAssertThrowsError(try ts.send(Data("hello".utf8))) { error in
            XCTAssertEqual(error as? TrueSealError, .notMember(.notJoined))
        }
        ts.close()
    }

    @MainActor
    func test_joinGarbageTokenThrowsInvalidPairingToken() async throws {
        let ts = try await openSession()
        XCTAssertThrowsError(try ts.join(token: "garbage")) { error in
            XCTAssertEqual(error as? TrueSealError, .invalidPairingToken)
        }
        ts.close()
    }

    @MainActor
    func test_doubleJoinThrowsAlreadyInGroup_andCancelJoinRoundTrips() async throws {
        let admitter = try await openSession(namespace: "a")
        let token = try admitter.startPairing()
        XCTAssertFalse(token.isEmpty)

        let joiner = try await openSession(namespace: "b")
        try joiner.join(token: token)
        XCTAssertEqual(joiner.status, .pendingJoin, "join() must reflect the synchronous transition immediately")

        // Verified core semantics: alreadyInGroup requires an actual
        // manifest; a second join while pendingJoin REPLACES the pending
        // anchor (equivalent to cancelJoin + join) and stays pendingJoin.
        try joiner.join(token: token)
        XCTAssertEqual(joiner.status, .pendingJoin)

        try joiner.cancelJoin()
        XCTAssertEqual(joiner.status, .notJoined)

        // The object survives and can join again — the lifecycle rule's
        // offline half (ADR-0028).
        try joiner.join(token: token)
        XCTAssertEqual(joiner.status, .pendingJoin)

        admitter.close()
        joiner.close()
    }

    @MainActor
    func test_leaveWhileNotJoinedThrowsNotMember() async throws {
        let ts = try await openSession()
        XCTAssertThrowsError(try ts.leave()) { error in
            XCTAssertEqual(error as? TrueSealError, .notMember(.notJoined))
        }
        ts.close()
    }

    @MainActor
    func test_acceptWithoutWindowThrowsPairingClosed() async throws {
        // Verified core semantics: accept() checks the pairing window
        // before membership, so with no window open the refusal is
        // pairingClosed even while notJoined.
        let ts = try await openSession()
        XCTAssertThrowsError(try ts.accept(requestId: "whatever")) { error in
            XCTAssertEqual(error as? TrueSealError, .pairingClosed)
        }
        ts.close()
    }

    @MainActor
    func test_payloadTooLarge_isSynchronous_andBoundaryExact() async throws {
        // ADR-0025: the limit is checked synchronously in send() — before
        // membership — so this is fully exercisable offline.
        let ts = try await openSession()
        XCTAssertThrowsError(try ts.send(Data(repeating: 0xFF, count: Int(TrueSeal.maxPayloadBytes) + 1))) { error in
            XCTAssertEqual(error as? TrueSealError, .payloadTooLarge(max: 61_440))
        }
        // At-limit still fails on membership (not size): the boundary is exact.
        XCTAssertThrowsError(try ts.send(Data(repeating: 0xFF, count: Int(TrueSeal.maxPayloadBytes)))) { error in
            XCTAssertEqual(error as? TrueSealError, .notMember(.notJoined),
                           "at-limit must pass the size check and fail on membership")
        }
        ts.close()
    }

    // MARK: - close()

    @MainActor
    func test_everyCallAfterCloseThrowsClosed() async throws {
        let ts = try await openSession()
        ts.close()

        XCTAssertThrowsError(try ts.send(Data("x".utf8))) { error in
            XCTAssertEqual(error as? TrueSealError, .closed)
        }
        XCTAssertThrowsError(try ts.startPairing()) { error in
            XCTAssertEqual(error as? TrueSealError, .closed)
        }
        XCTAssertThrowsError(try ts.join(token: "x")) { error in
            XCTAssertEqual(error as? TrueSealError, .closed)
        }
        XCTAssertThrowsError(try ts.leave()) { error in
            XCTAssertEqual(error as? TrueSealError, .closed)
        }
        XCTAssertThrowsError(try ts.onMessage { _ in }) { error in
            XCTAssertEqual(error as? TrueSealError, .closed)
        }
        // close() itself is idempotent.
        ts.close()
    }

    // MARK: - onMessage one-shot (ADR-0028)

    @MainActor
    func test_secondOnMessageThrows_messageHandlerAlreadySet_andCancelDoesNotReEnable() async throws {
        let ts = try await openSession()
        let sub = try ts.onMessage { _ in }
        XCTAssertThrowsError(try ts.onMessage { _ in }) { error in
            XCTAssertEqual(error as? TrueSealError, .messageHandlerAlreadySet)
        }
        sub.cancel()
        XCTAssertThrowsError(try ts.onMessage { _ in }) { error in
            XCTAssertEqual(error as? TrueSealError, .messageHandlerAlreadySet,
                           "cancelling must not re-enable registration (one-shot)")
        }
        ts.close()
    }

    // MARK: - Events against a live local relay (skip-gated)

    @MainActor
    func test_onEvent_connectionTransitions_againstLiveRelay() async throws {
        let relay = try RelayFixture.start()
        defer { relay.stop() }

        let ts = try await TrueSeal.open(relay: relay.address, storage: makeStorage())
        let connected = expectation(description: "connectionChanged(connected)")
        connected.assertForOverFulfill = false
        let lock = NSLock()
        var sawConnected = false
        let sub = try ts.onEvent { event in
            if case .connectionChanged(.connected) = event {
                lock.lock()
                if !sawConnected { sawConnected = true; connected.fulfill() }
                lock.unlock()
            }
        }
        await fulfillment(of: [connected], timeout: 15)
        var conn = await ts.connection
        XCTAssertEqual(conn, .connected)

        // NOTE (reported upstream, 2026-10-13): killing the relay is NOT
        // detected by the core within 150 s — no sever, no Disconnected
        // event — although SYNC-16's liveness machinery (25 s heartbeat /
        // 75 s silent → sever) exists. Reproduced from this test against a
        // real relay; the disconnect half of this scenario stays asserted
        // in e2e once the core fix lands. The connect half above — the
        // full Transport Version handshake from the Swift SDK — is real.
        sub.cancel()
        ts.close()
    }

    @MainActor
    func test_connection_staysDisconnected_againstDeadRelay() async throws {
        // Transition-only reporting (verified against the core): the loop
        // starts disconnected, so a dead relay produces NO events — the
        // state simply stays disconnected.
        let ts = try await openSession()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let conn = await ts.connection
        // Verified core semantics: `connecting` means "attempting" — the
        // loop retries forever and `disconnected` reports the LOSS of an
        // established connection, so a never-connected device reads
        // `connecting` and no event fires.
        XCTAssertEqual(conn, .connecting)
        ts.close()
    }

    @MainActor
    func test_onDeliveryIssueRegisters() async throws {
        let ts = try await openSession()
        let sub = try ts.onDeliveryIssue { _ in }
        sub.cancel()
        ts.close()
    }

    // MARK: - @Observable (issue criterion)

    @MainActor
    func test_trueSealIsObservable() async throws {
        let ts = try await openSession()
        let changed = expectation(description: "observation fires on status change")
        changed.assertForOverFulfill = false

        let admitter = try await openSession(namespace: "a2")
        let token = try admitter.startPairing()

        withObservationTracking {
            _ = ts.status
        } onChange: {
            changed.fulfill()
        }

        try ts.join(token: token) // synchronous transition to pendingJoin
        await fulfillment(of: [changed], timeout: 5)
        XCTAssertEqual(ts.status, .pendingJoin)

        admitter.close()
        ts.close()
    }

    // MARK: - Backup exclusion (B16 parked note; core sets the file xattr)

    @MainActor
    func test_storeFileIsExcludedFromBackup() async throws {
        let storage = makeStorage()
        let ts = try await TrueSeal.open(relay: deadRelay, storage: storage, namespace: "backuptest")
        let db = storage.appendingPathComponent("trueseal_backuptest.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.path), "store file must exist after open")
        let values = try db.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true,
                       "Session State must be excluded from backups (ADR-0032; core sets the xattr)")
        ts.close()
    }

    // MARK: - Error mapping: all 14 cases (1:1 with the core)

    func test_errorMapping_coversAll14Cases() {
        let pairs: [(TruesealSyncBindings.TrueSealError, TrueSealError)] = [
            (.InvalidRelayAddress(msg: "x"), .invalidRelayAddress("x")),
            (.InvalidNamespace(msg: "x"), .invalidNamespace("x")),
            (.Storage(msg: "x"), .storage("x")),
            (.Closed, .closed),
            (.NotMember(status: .leaving), .notMember(.leaving)),
            (.AlreadyInGroup, .alreadyInGroup),
            (.InvalidPairingToken, .invalidPairingToken),
            (.PairingClosed, .pairingClosed),
            (.GroupFull(max: 32), .groupFull(max: 32)),
            (.MemberNotFound, .memberNotFound),
            (.PayloadTooLarge(max: 61_440), .payloadTooLarge(max: 61_440)),
            (.MessageHandlerAlreadySet, .messageHandlerAlreadySet),
            (.StoreTooNew(found: 9, supported: 1), .storeTooNew(found: 9, supported: 1)),
            (.ManifestVersionExhausted, .manifestVersionExhausted),
        ]
        XCTAssertEqual(pairs.count, 14, "the canonical list has exactly 14 error cases")
        for (ffi, expected) in pairs {
            XCTAssertEqual(TrueSealError.map(ffi), expected)
            XCTAssertNotNil(TrueSealError.map(ffi).errorDescription, "\(expected) needs a description")
        }
    }

    // MARK: - Model mappings: every event and issue case

    func test_eventMapping_coversAllCases() {
        let ffiEvents: [TruesealSyncBindings.TrueSealEvent] = [
            .statusChanged(status: .destroying, reason: .destroyed),
            .membersChanged(members: [TruesealSyncBindings.Member(id: "m1", name: "n1")]),
            .joinRequest(request: TruesealSyncBindings.JoinRequest(id: "j1", name: "jn")),
            .connectionChanged(connection: .relayVersionUnsupported(min: 1, max: 1)),
            .admissionDropped(name: "x", reason: .groupFull),
        ]
        let mapped = ffiEvents.map { TruesealSync.TrueSealEvent($0) }
        XCTAssertEqual(mapped[0], .statusChanged(status: .destroying, reason: .destroyed))
        XCTAssertEqual(mapped[1], .membersChanged(members: [Member(id: "m1", name: "n1")]))
        XCTAssertEqual(mapped[2], .joinRequest(request: JoinRequest(id: "j1", name: "jn")))
        XCTAssertEqual(mapped[3], .connectionChanged(connection: .relayVersionUnsupported(min: 1, max: 1)))
        XCTAssertEqual(mapped[4], .admissionDropped(name: "x", reason: .groupFull))
    }

    func test_issueMapping_coversAllCases() {
        let ffiIssues: [TruesealSyncBindings.DeliveryIssue] = [
            .unreadable(reason: .malformed),
            .unreadable(reason: .senderOutdated),
            .unreadable(reason: .expired),
            .unreadable(reason: .droppedWhileHeld),
            .unauthorized,
            .heldForUpgrade(version: 2),
            .handlerGaveUp(messageId: "tsm1_x", error: "boom"),
            .sendFailed(messageId: "tsm1_y", reason: .tooLarge),
            .sendFailed(messageId: "tsm1_z", reason: .malformed),
            .sendFailed(messageId: "tsm1_w", reason: .expired),
        ]
        let mapped = ffiIssues.map { TruesealSync.DeliveryIssue($0) }
        XCTAssertEqual(mapped[0], .unreadable(reason: .malformed))
        XCTAssertEqual(mapped[1], .unreadable(reason: .senderOutdated))
        XCTAssertEqual(mapped[2], .unreadable(reason: .expired))
        XCTAssertEqual(mapped[3], .unreadable(reason: .droppedWhileHeld))
        XCTAssertEqual(mapped[4], .unauthorized)
        XCTAssertEqual(mapped[5], .heldForUpgrade(version: 2))
        XCTAssertEqual(mapped[6], .handlerGaveUp(messageId: "tsm1_x", error: "boom"))
        XCTAssertEqual(mapped[7], .sendFailed(messageId: "tsm1_y", reason: .tooLarge))
        XCTAssertEqual(mapped[8], .sendFailed(messageId: "tsm1_z", reason: .malformed))
        XCTAssertEqual(mapped[9], .sendFailed(messageId: "tsm1_w", reason: .expired))
    }

    func test_statusAndReasonMappings_coverAllCases() {
        XCTAssertEqual(GroupStatus(.notJoined), .notJoined)
        XCTAssertEqual(GroupStatus(.pendingJoin), .pendingJoin)
        XCTAssertEqual(GroupStatus(.member), .member)
        XCTAssertEqual(GroupStatus(.leaving), .leaving)
        XCTAssertEqual(GroupStatus(.destroying), .destroying)
        XCTAssertEqual(StatusReason(.created), .created)
        XCTAssertEqual(StatusReason(.joined), .joined)
        XCTAssertEqual(StatusReason(.left), .left)
        XCTAssertEqual(StatusReason(.removed), .removed)
        XCTAssertEqual(StatusReason(.destroyed), .destroyed)
        XCTAssertEqual(StatusReason(.storeReset), .storeReset)
        XCTAssertEqual(ConnectionState(.connecting), .connecting)
        XCTAssertEqual(ConnectionState(.connected), .connected)
        XCTAssertEqual(ConnectionState(.disconnected), .disconnected)
    }
}

// MARK: - Live relay fixture (local verification only)

/// Boots the real Go relay from the sibling checkout on ephemeral-ish
/// localhost ports. Skips when the toolchain or the sibling repo is
/// unavailable (CI runners don't have it) — the e2e Scenario Suite (G1)
/// covers these paths in CI.
final class RelayFixture {
    private let process: Process
    private let dir: URL
    let address: String

    private init(process: Process, dir: URL, address: String) {
        self.process = process
        self.dir = dir
        self.address = address
    }

    @MainActor
    static func start() throws -> RelayFixture {
        struct Skip: Error {}
        let sibling = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TruesealSyncTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .deletingLastPathComponent() // workspace
            .appendingPathComponent("trueseal-relay")
        guard FileManager.default.fileExists(atPath: sibling.path) else { throw Skip() }

        let bin = "/tmp/trueseal-relay-test-bin"
        if !FileManager.default.fileExists(atPath: bin) {
            let build = Process()
            build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            build.arguments = ["go", "build", "-o", bin, "./cmd/trueseal-relay"]
            build.currentDirectoryURL = sibling
            try build.run()
            build.waitUntilExit()
            guard build.terminationStatus == 0 else { throw Skip() }
        }

        let port = 18_000 + Int.random(in: 0..<2_000) * 3
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var env = ProcessInfo.processInfo.environment
        env["TRUESEAL_RELAY_KEYPAIR_PATH"] = dir.appendingPathComponent("kp.hex").path
        env["TRUESEAL_RELAY_STORE_SQLITE_PATH"] = dir.appendingPathComponent("inbox.db").path
        env["TRUESEAL_RELAY_LISTEN_RECEIVE"] = "127.0.0.1:\(port)"
        env["TRUESEAL_RELAY_LISTEN_PUSH"] = "127.0.0.1:\(port + 1)"
        env["TRUESEAL_RELAY_LISTEN_HEALTH"] = "127.0.0.1:\(port + 2)"

        let relay = Process()
        relay.executableURL = URL(fileURLWithPath: bin)
        relay.arguments = ["-no-config"]
        relay.environment = env
        relay.standardOutput = FileHandle.nullDevice
        relay.standardError = FileHandle.nullDevice
        try relay.run()

        let pubkey = Process()
        pubkey.executableURL = URL(fileURLWithPath: bin)
        pubkey.arguments = ["pubkey", "-no-config"]
        pubkey.environment = env
        let pipe = Pipe()
        pubkey.standardOutput = pipe
        try pubkey.run()
        pubkey.waitUntilExit()
        let key = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard key.count == 64 else {
            relay.terminate()
            throw Skip()
        }
        // Give the listeners a beat to bind.
        Thread.sleep(forTimeInterval: 0.5)
        return RelayFixture(process: relay, dir: dir,
                            address: "trueseal://\(key)@127.0.0.1:\(port)?push=\(port + 1)")
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: dir)
    }
}

// Relay-dependent behavior intentionally NOT asserted here (covered by the
// e2e Scenario Driver, G1 — see trueseal-e2e): full pair/accept flows,
// removal/leave/destroy reaching notJoined over the wire, groupFull,
// memberNotFound, payloadTooLarge inside a group, storeTooNew, and message
// delivery through onMessage.
