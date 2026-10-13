// swift-tools-version: 5.9
import PackageDescription

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
        // Source state uses path: — the XCFramework is produced locally by
        // scripts/build-xcframework.sh, or extracted by CI from the pinned
        // trueseal-sync core release (see .github/workflows/ci.yml).
        // The release workflow stamps url:+checksum: on the tag for SPM
        // consumers. Do not commit a url: form here.
        .binaryTarget(
            name: "TruesealSyncFFI",
            path: "TruesealSyncFFI.xcframework"
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
