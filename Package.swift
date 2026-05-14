// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HushSync",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        // The only public-facing product.  App devs import HushSync — never HushSyncBindings.
        .library(name: "HushSync", targets: ["HushSync"]),
    ],
    targets: [
        // ── 1. Compiled Rust binary (XCFramework) ────────────────────────────
        // path: is used for local development.  On every release the CI workflow
        // stamps this to url:+checksum:, commits, and retagsso the published tag
        // always has the correct remote reference for SPM consumers.
        //
        // For local dev: run scripts/build-xcframework.sh, then change this to
        //   path: "HushSyncFFI.xcframework"
        // Do not commit that local change.
        .binaryTarget(
            name: "HushSyncFFI",
            path: "HushSyncFFI.xcframework"
        ),

        // ── 2. Generated UniFFI Swift bindings ────────────────────────────────
        // hush_sync.swift is produced by `uniffi-bindgen generate`.
        // NOT listed in products — internal to the package only.
        // HushSync imports it with @_implementationOnly so none of these
        // types bleed into the public API.
        .target(
            name: "HushSyncBindings",
            dependencies: ["HushSyncFFI"],
            path: "Sources/HushSyncBindings"
        ),

        // ── 3. Idiomatic Swift SDK (public) ───────────────────────────────────
        // Zero UniFFI / FFI types in the public surface.
        // All async via Swift Concurrency; all errors via HushSyncError.
        .target(
            name: "HushSync",
            dependencies: ["HushSyncBindings"],
            path: "Sources/HushSync"
        ),

        // ── 4. Tests ─────────────────────────────────────────────────────────
        .testTarget(
            name: "HushSyncTests",
            dependencies: ["HushSync"],
            path: "Tests/HushSyncTests"
        ),
    ]
)
