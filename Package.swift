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
        // Stamped by CI on every tagged release via .github/workflows/release.yml.
        // For local development: run scripts/build-xcframework.sh, then
        // temporarily swap url/checksum for: path: "HushSyncFFI.xcframework"
        .binaryTarget(
            name: "HushSyncFFI",
            url: "https://github.com/julianbonomini/hush-sync-swift/releases/download/v0.0.5/HushSyncFFI.xcframework.zip",
            checksum: "8584a6bb6d388b4cb2c1376fef70a58408c3d150dc28b89b73676565b4f15b96"
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
