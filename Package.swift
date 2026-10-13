// swift-tools-version: 5.9
import PackageDescription

// ── Release pin (SWIFT-2) ───────────────────────────────────────────────────
// These three constants are the SINGLE place a release commit records which
// XCFramework the binaryTarget resolves to (gates G8/G9).
//
// On main, artifactURL and artifactChecksum are EMPTY: the package builds
// from the local TruesealSyncFFI.xcframework (produced by
// scripts/build-xcframework.sh, or extracted by CI from the pinned core
// release — see .github/workflows/ci.yml).
//
// The candidate build (.github/workflows/release.yml, via
// scripts/stamp-package.sh) stamps all three constants and commits the
// result as the release commit BEFORE the tag exists (e2e ADR-0002 step 2).
// Promotion (SDK-4) creates the immutable tag on that exact commit — tags
// are never moved (sync ADR-0030). Do not hand-edit the stamped values.
let version = "0.6.0"
let artifactURL = ""
let artifactChecksum = ""

let truesealSyncFFI: Target = artifactURL.isEmpty
    ? .binaryTarget(
        name: "TruesealSyncFFI",
        path: "TruesealSyncFFI.xcframework"
    )
    : .binaryTarget(
        name: "TruesealSyncFFI",
        url: artifactURL,
        checksum: artifactChecksum
    )

let package = Package(
    name: "TruesealSync",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        // The only public-facing product.  App devs import TruesealSync — never TruesealSyncBindings.
        .library(name: "TruesealSync", targets: ["TruesealSync"]),
    ],
    targets: [
        // ── 1. Compiled Rust binary (XCFramework) ────────────────────────────
        // path: on main (artifactURL empty); url:+checksum: on a release
        // commit (stamped by scripts/stamp-package.sh). See the release pin
        // constants at the top of this file.
        truesealSyncFFI,

        // ── 2. Generated UniFFI Swift bindings ────────────────────────────────
        // trueseal_sync.swift is produced by `uniffi-bindgen generate`.
        // NOT listed in products — internal to the package only.
        // TruesealSync imports it with @_implementationOnly so none of these
        // types bleed into the public API.
        .target(
            name: "TruesealSyncBindings",
            dependencies: ["TruesealSyncFFI"],
            path: "Sources/TruesealSyncBindings"
        ),

        // ── 3. Idiomatic Swift SDK (public) ───────────────────────────────────
        // Zero UniFFI / FFI types in the public surface.
        // All async via Swift Concurrency; all errors via TruesealSyncError.
        .target(
            name: "TruesealSync",
            dependencies: ["TruesealSyncBindings"],
            path: "Sources/TruesealSync"
        ),

        // ── 4. Tests ─────────────────────────────────────────────────────────
        .testTarget(
            name: "TruesealSyncTests",
            dependencies: ["TruesealSync"],
            path: "Tests/TruesealSyncTests",
            exclude: ["Vectors/README.md"],
            resources: [.copy("Vectors/sync-v1.json")]
        ),
    ]
)
