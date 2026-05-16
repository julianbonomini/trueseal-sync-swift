// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TruesealSync",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        // The only public-facing product.  App devs import TruesealSync — never TruesealSyncBindings.
        .library(name: "TruesealSync", targets: ["TruesealSync"]),
    ],
    targets: [
        // ── 1. Compiled Rust binary (XCFramework) ────────────────────────────
        // path: is used for local development.  On every release the CI workflow
        // stamps this to url:+checksum:, commits, and retagsso the published tag
        // always has the correct remote reference for SPM consumers.
        //
        // For local dev: run scripts/build-xcframework.sh, then change this to
        //   url: "https://github.com/julianbonomini/trueseal-sync-swift/releases/download/v0.1.0/TruesealSyncFFI.xcframework.zip", checksum: "728e2b4ddd888ad372b051ae204dddb135907235016934c7dd91b5e53f6548bb"
        // Do not commit that local change.
        .binaryTarget(
            name: "TruesealSyncFFI",
            url: "https://github.com/julianbonomini/trueseal-sync-swift/releases/download/v0.1.0/TruesealSyncFFI.xcframework.zip", checksum: "728e2b4ddd888ad372b051ae204dddb135907235016934c7dd91b5e53f6548bb"
        ),

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
            path: "Tests/TruesealSyncTests"
        ),
    ]
)
