import XCTest
import CryptoKit
@testable import TruesealSync
import TruesealSyncBindings

// Both modules export the same type names (the public mirrors and the FFI
// originals); pin the unqualified names here to the PUBLIC ones — this suite
// checks the SDK's canonical surface, not the generated bindings directly.
// (TrueSeal/TrueSealError/ConnectionState typealiases already exist in
// TruesealSyncTests.swift — same target, shared scope.)
typealias DeliveryIssue = TruesealSync.DeliveryIssue
typealias UnreadableReason = TruesealSync.UnreadableReason

// SDK-2 (#3): check the sync JSON test vectors THROUGH the Swift bindings —
// release gate G5. The vendored file proves the shipped XCFramework and the
// generated trueseal_sync.swift produce/recognise the same wire reality as
// the Rust reference, instead of inferring compatibility from versions
// (ADR-0022). Consumption contract: trueseal-sync/docs/test-vectors/README.md.
//
// The pin (G8) — mirror of the relay's internal/vectors pin:
private let syncV1Source = "trueseal-sync@265f99f docs/test-vectors/sync-v1.json"
private let syncV1FormatVersion = 1
private let syncV1SHA256 = "0506d5a80a9485f612d4d38a2530b70296a1e022e0539f3a001b6298a3dc3b37"

private typealias J = [String: Any]

private enum VectorError: Error, CustomStringConvertible {
    case drift(found: String)
    case malformed(String)
    case mismatch(String)

    var description: String {
        switch self {
        case .drift(let found):
            return "vendored sync-v1.json SHA-256 \(found) != pinned \(syncV1SHA256) — the file drifted from \(syncV1Source). Do NOT re-pin to silence this: an unexpected drift is a wire-format bug."
        case .malformed(let what): return "sync-v1.json malformed: \(what)"
        case .mismatch(let what): return what
        }
    }
}

/// One line of the machine-readable report the Release Conductor attaches
/// as Release Evidence (G5). `status` is `checked-through-bindings` or
/// `documented-core-internal` (with the owning checker named in `detail`).
private struct ReportEntry {
    let section: String
    let status: String
    let detail: String
}

final class SyncVectorTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var report: [ReportEntry] = []

    override func tearDownWithError() throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
        report = []
    }

    // MARK: - Loading (drift-refusing, G8)

    /// Loads and pins the vendored vectors. A byte of drift — accidental or
    /// copied-in — fails here before any check runs.
    private func loadVectors() throws -> J {
        // SPM copies the declared file flat into the resource bundle; accept
        // both the flat layout and a Vectors/ subdirectory so the lookup
        // survives a future switch to .copy("Vectors") or .process.
        let url = Bundle.module.url(forResource: "sync-v1", withExtension: "json", subdirectory: "Vectors")
            ?? Bundle.module.url(forResource: "sync-v1", withExtension: "json")
            ?? Bundle(for: SyncVectorTests.self).url(forResource: "sync-v1", withExtension: "json")
        guard let url else {
            throw VectorError.malformed("sync-v1.json missing from the test bundle — the vector file MUST be present (issue #3: fail the build on missing vector files)")
        }
        let bytes = try Data(contentsOf: url)
        let found = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard found == syncV1SHA256 else { throw VectorError.drift(found: found) }
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? J else {
            throw VectorError.malformed("root is not an object")
        }
        guard root["format"] as? String == "trueseal-sync-vectors",
              root["formatVersion"] as? Int == syncV1FormatVersion else {
            throw VectorError.malformed("unexpected format/formatVersion")
        }
        return root
    }

    // MARK: - protocol: versions and limits through the bindings

    /// The comparison, factored so the negative control can feed it a
    /// mutated copy. Throws on the FIRST mismatch, listing all of them.
    private func assertProtocolMatches(_ v: J) throws {
        guard let p = v["protocol"] as? J else { throw VectorError.malformed("missing protocol section") }
        var failures: [String] = []
        func expect(_ key: String, _ actual: UInt32, _ file: String) {
            guard let want = p[key] as? Int else {
                failures.append("protocol.\(key) missing from the vector file")
                return
            }
            if UInt32(want) != actual {
                failures.append("protocol.\(key): bindings report \(actual), vectors pin \(want) (\(file))")
            }
        }
        // Every value on the left is the LINKED CORE's FFI static reached
        // through the public SDK surface (SDK-3 pass-throughs) — this is a
        // through-the-bindings check, not a re-implementation.
        expect("transportVersion", TrueSeal.info.transportVersion, "TrueSeal.info.transportVersion")
        expect("endToEndVersion", TrueSeal.info.endToEndVersion, "TrueSeal.info.endToEndVersion")
        expect("protocolSizeLimit", TrueSeal.maxPayloadBytes, "TrueSeal.maxPayloadBytes")
        expect("maxGroupSize", TrueSeal.maxGroupSize, "TrueSeal.maxGroupSize")
        if !failures.isEmpty { throw VectorError.mismatch(failures.joined(separator: "; ")) }
    }

    func test_protocol_versionsAndLimits_matchThroughBindings() throws {
        let v = try loadVectors()
        try assertProtocolMatches(v)
        note("protocol", "checked-through-bindings",
             "transportVersion/endToEndVersion/protocolSizeLimit/maxGroupSize via TrueSeal.info + maxPayloadBytes + maxGroupSize (the linked core's FFI statics)")
    }

    /// Negative control (issue #3): a mutated vector MUST fail the check.
    /// Proves the comparisons above are real, not tautological.
    func test_mutatedVector_failsTheCheck() throws {
        var v = try loadVectors()
        guard var p = v["protocol"] as? J else { throw VectorError.malformed("missing protocol section") }
        let original = p["maxGroupSize"] as? Int
        p["maxGroupSize"] = (original ?? 32) + 1
        v["protocol"] = p
        XCTAssertThrowsError(try assertProtocolMatches(v)) { error in
            guard case VectorError.mismatch(let detail) = error,
                  detail.contains("maxGroupSize") else {
                return XCTFail("mutation did not produce a maxGroupSize mismatch: \(error)")
            }
        }
    }

    // MARK: - rejections: canonical taxonomy through the bindings

    /// Every rejection's expected typed error / Delivery Issue / Connection
    /// State must exist in the SDK's canonical surface (ADR-0028/0032 + the
    /// SYNC-15 amendment — 14 errors, shared-facts names). Each name below is
    /// referenced at COMPILE TIME against the real Swift case: if the SDK
    /// drops or renames a case this file stops compiling; if the vectors add
    /// a rejection the surface doesn't cover, the runtime check fails.
    func test_rejections_everyExpectedNameExistsThroughBindings() throws {
        let v = try loadVectors()
        guard let rejections = v["rejections"] as? [J], !rejections.isEmpty else {
            throw VectorError.malformed("missing/empty rejections")
        }

        // kind "typedError": the name must be a real TrueSealError case.
        let typedErrors: [String: TrueSealError] = [
            "payloadTooLarge": .payloadTooLarge(max: 0),
        ]
        // kind "deliveryIssue" names + UnreadableReason reasons.
        let issueNames: [String: DeliveryIssue] = [
            "heldForUpgrade": .heldForUpgrade(version: 0),
            "unreadable": .unreadable(reason: .malformed),
        ]
        let unreadableReasons: [String: UnreadableReason] = [
            "malformed": .malformed,
            "senderOutdated": .senderOutdated,
            "expired": .expired,
            "droppedWhileHeld": .droppedWhileHeld,
        ]
        // kind "connectionState" names.
        let connectionStates: [String: ConnectionState] = [
            "relayVersionUnsupported": .relayVersionUnsupported(min: 0, max: 0),
        ]
        // kind "connectionFailure" is the typed ConnectionState.disconnected
        // path (a refused version exchange resolves as connectionFailed);
        // it has no payload name to pin — asserted structurally below.

        var failures: [String] = []
        for r in rejections {
            guard let layer = r["layer"] as? String,
                  let kase = r["case"] as? String,
                  let expect = r["expect"] as? J,
                  let kind = expect["kind"] as? String else {
                failures.append("malformed rejection entry")
                continue
            }
            let label = "\(layer)/\(kase)"
            switch kind {
            case "typedError":
                guard let name = expect["name"] as? String, typedErrors[name] != nil else {
                    failures.append("\(label): typed error '\(expect["name"] ?? "?")' has no TrueSealError case")
                    continue
                }
            case "deliveryIssue":
                guard let name = expect["name"] as? String else {
                    failures.append("\(label): deliveryIssue without a name")
                    continue
                }
                if name == "unreadable" {
                    guard let reason = expect["reason"] as? String, unreadableReasons[reason] != nil else {
                        failures.append("\(label): unreadable reason '\(expect["reason"] ?? "?")' has no UnreadableReason case")
                        continue
                    }
                } else if issueNames[name] == nil {
                    failures.append("\(label): delivery issue '\(name)' has no DeliveryIssue case")
                }
            case "connectionState":
                guard let name = expect["name"] as? String, connectionStates[name] != nil else {
                    failures.append("\(label): connection state '\(expect["name"] ?? "?")' has no ConnectionState case")
                    continue
                }
            case "connectionFailure":
                break // structural — covered by the preVersionRelaySilent note below
            default:
                failures.append("\(label): unknown expect.kind '\(kind)' — a new rejection kind the SDK's surface must name")
            }
        }
        if !failures.isEmpty { throw VectorError.mismatch(failures.joined(separator: "; ")) }
        note("rejections", "checked-through-bindings",
             "\(rejections.count) rejection entries: every expected typed error / DeliveryIssue(+reason) / ConnectionState exists in the SDK's canonical surface (compile-time referenced)")
    }

    // MARK: - size rejection, behaviorally through the bindings

    /// The size-layer rejection IS reachable offline through the bindings:
    /// the core consults the size gate FIRST (ADR-0025: refused
    /// synchronously in send(), before any other side effect), so even a
    /// non-member's send(limit+1) throws payloadTooLarge(max:) with the
    /// vector's exact limit. The at-limit body passes the size gate and
    /// fails on the NEXT gate (notMember — nothing to fan out to), which
    /// pins the ordering both ways.
    @MainActor
    func test_sizeRejection_sendRefusesOverLimit_withTheVectorsExactLimit() async throws {
        let v = try loadVectors()
        guard let p = v["protocol"] as? J,
              let limit = p["protocolSizeLimit"] as? Int else {
            throw VectorError.malformed("missing protocol.protocolSizeLimit")
        }
        // Internal consistency of the vector's own rejection entry.
        guard let rejections = v["rejections"] as? [J],
              let sizeEntry = rejections.first(where: { ($0["case"] as? String) == "bodyOverProtocolLimit" }),
              let expect = sizeEntry["expect"] as? J,
              expect["name"] as? String == "payloadTooLarge",
              expect["max"] as? Int == limit,
              let input = sizeEntry["input"] as? J,
              input["bodyLen"] as? Int == limit + 1 else {
            throw VectorError.malformed("size rejection entry inconsistent with protocol section")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trueseal-vectors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let t = try await TrueSeal.open(
            relay: "trueseal://0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef@127.0.0.1:9?push=9",
            storage: dir, namespace: "vectors")

        // Over the limit: typed refusal carrying the vector's exact max —
        // through the public SDK send(), against the shipped XCFramework.
        do {
            _ = try t.send(Data(count: limit + 1))
            XCTFail("send(limit+1) must throw payloadTooLarge (ADR-0025; vector size/bodyOverProtocolLimit)")
        } catch TrueSealError.payloadTooLarge(let max) {
            XCTAssertEqual(Int(max), limit, "payloadTooLarge.max must be the vector's protocolSizeLimit")
        }
        // At the limit: the size gate passes; the next gate (membership)
        // fires instead — pinning size-before-membership from the other side.
        XCTAssertThrowsError(try t.send(Data(count: limit))) { error in
            guard case TrueSealError.notMember = error else {
                return XCTFail("at-limit body must pass the size gate (then fail notMember offline); got \(error)")
            }
        }
        note("rejections/size", "checked-through-bindings (behavioral)",
             "send(limit+1) throws payloadTooLarge(max: 61440) — the vector's exact limit; send(limit) passes the size gate (fails notMember offline). Size gate precedes membership, pinned both directions")
    }

    // MARK: - core-internal sections: present, and their checker named

    /// These sections pin bytes the public FFI deliberately does not expose
    /// entry points for (signing inputs, seal/open, message codec, frame
    /// assembly). Faking access would violate G5's purpose, so they are
    /// checked by the owner named per section — this test asserts the
    /// sections are present and non-empty so they cannot silently vanish
    /// from the file every consumer pins.
    func test_coreInternalSections_arePresentAndNamed() throws {
        let v = try loadVectors()
        // section → where it is checked
        let owners: [(String, String)] = [
            ("domains", "core: vectors::generated_vectors_verify_against_the_code"),
            ("transportVersionPrefix", "relay: internal/vectors vectors_test.go (RELAY-5) + core vectors test"),
            ("signing", "core: vectors test (signing_message / signing_message_for are the signer's own functions)"),
            ("addressedEncryption", "core: vectors test (seal/open round-trip with fixed ephemeral)"),
            ("messageId", "core: vectors test (tsm1_ derivation)"),
            ("messages", "core: vectors test (real message codec, incl. the 65-byte pre-SYNC-3 Pair refusal)"),
            ("sealedEnvelope", "core: vectors test (build_sealed_with_ephemeral; prefix is the decrypted payload)"),
            ("frames", "relay: vectors_test.go byte-for-byte (RELAY-5) + core vectors test"),
        ]
        for (section, owner) in owners {
            guard let value = v[section] else {
                throw VectorError.mismatch("core-internal section '\(section)' is MISSING from the pinned vectors — was it removed upstream?")
            }
            if let dict = value as? J {
                XCTAssertFalse(dict.isEmpty, "section '\(section)' is empty")
            }
            note(section, "documented-core-internal", "no FFI entry point by design; checked by \(owner)")
        }
        // The remaining protocol fields the FFI does not expose — presence
        // asserted, checker named, so the coverage map is complete.
        guard let p = v["protocol"] as? J else { throw VectorError.malformed("missing protocol section") }
        for key in ["storeVersion", "maxEnvelopeBytes", "noiseFramePlaintextMax",
                    "maxManifestVersionJump", "maxHeldBlobs", "replayWindowMs"] {
            XCTAssertNotNil(p[key], "protocol.\(key) missing")
        }
        note("protocol (remaining fields)", "documented-core-internal",
             "storeVersion/maxEnvelopeBytes/noiseFramePlaintextMax/maxManifestVersionJump/maxHeldBlobs/replayWindowMs have no FFI static; checked by the core vectors test (and the relay for its layers)")
    }

    // MARK: - machine-readable report (Release Evidence)

    private func note(_ section: String, _ status: String, _ detail: String) {
        report.append(ReportEntry(section: section, status: status, detail: detail))
    }

    /// Emits the G5 report: one entry per section with its status and
    /// checker. Written to $TRUSEAL_VECTOR_REPORT when set (CI attaches it as
    /// an artifact); always printed for the test log.
    func test_emitMachineReadableReport() throws {
        // Run after the checks: re-derive entries deterministically rather
        // than depending on XCTest execution order.
        var entries: [ReportEntry] = [
            ReportEntry(section: "pin", status: "checked-through-bindings",
                        detail: "\(syncV1Source); sha256 \(syncV1SHA256); drift-refusing load"),
            ReportEntry(section: "protocol", status: "checked-through-bindings",
                        detail: "transportVersion/endToEndVersion/protocolSizeLimit/maxGroupSize via TrueSeal.info/maxPayloadBytes/maxGroupSize"),
            ReportEntry(section: "rejections (taxonomy)", status: "checked-through-bindings",
                        detail: "every expected typed error / DeliveryIssue(+reason) / ConnectionState exists in the SDK surface"),
            ReportEntry(section: "rejections/size (behavioral)", status: "checked-through-bindings",
                        detail: "send(limit+1) throws payloadTooLarge(max: 61440) with the vector's exact limit; send(limit) passes the size gate (notMember offline); size-before-membership pinned both ways"),
            ReportEntry(section: "negative control", status: "checked-through-bindings",
                        detail: "a mutated protocol expectation fails the check"),
        ]
        for (section, owner) in [
            ("domains", "core vectors test"),
            ("transportVersionPrefix", "relay vectors_test.go + core"),
            ("signing", "core vectors test"),
            ("addressedEncryption", "core vectors test"),
            ("messageId", "core vectors test"),
            ("messages", "core vectors test"),
            ("sealedEnvelope", "core vectors test"),
            ("frames", "relay vectors_test.go + core"),
            ("protocol (remaining fields)", "core vectors test"),
            ("rejections (inbound behaviors: held/older/expired/malformed envelopes)", "e2e Adversary Client (G3) — needs a hostile peer"),
        ] {
            entries.append(ReportEntry(section: section, status: "documented-core-internal", detail: "checked by \(owner)"))
        }

        var jsonEntries: [J] = []
        for e in entries {
            jsonEntries.append(["section": e.section, "status": e.status, "detail": e.detail])
        }
        let doc: J = [
            "gate": "G5",
            "sdk": "trueseal-sync-swift",
            "pin": ["source": syncV1Source, "sha256": syncV1SHA256, "formatVersion": syncV1FormatVersion],
            "checks": jsonEntries,
        ]
        let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        let text = String(decoding: data, as: UTF8.self)
        print("TRUSEAL-G5-REPORT: \(text)")
        if let path = ProcessInfo.processInfo.environment["TRUSEAL_VECTOR_REPORT"] {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
