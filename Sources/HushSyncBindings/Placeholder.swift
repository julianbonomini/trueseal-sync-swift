// This file is a compile-time placeholder so SwiftPM can resolve the
// HushSyncBindings target before the XCFramework is built.
//
// `scripts/build-xcframework.sh` overwrites this directory with the real
// UniFFI-generated `hush_sync.swift` and removes this file.
//
// If you see this file at build time, run the build script first:
//
//   bash scripts/build-xcframework.sh
