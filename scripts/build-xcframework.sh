#!/usr/bin/env bash
# scripts/build-xcframework.sh
#
# LOCAL DEVELOPMENT ONLY — not used by CI.
# CI downloads a prebuilt XCFramework + bindings from the trueseal-sync GitHub
# release (see .github/workflows/ci.yml and .github/workflows/release.yml).
#
# Build the trueseal-sync Rust library for macOS + iOS targets, generate UniFFI
# Swift bindings, and package everything into TruesealSyncFFI.xcframework.
#
# Prerequisites:
#   rustup target add aarch64-apple-darwin x86_64-apple-darwin \
#                      aarch64-apple-ios  x86_64-apple-ios \
#                      aarch64-apple-ios-sim
#   cargo install uniffi-bindgen  (or use the in-tree binary: cargo run --bin uniffi-bindgen)
#
# Usage:
#   bash scripts/build-xcframework.sh            # release build (default)
#   PROFILE=debug bash scripts/build-xcframework.sh

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUST_DIR="$(cd "$REPO_ROOT/../trueseal-sync" && pwd)"   # path to the Rust crate

PROFILE="${PROFILE:-release}"
CARGO_FLAGS=()
[[ "$PROFILE" == "release" ]] && CARGO_FLAGS+=("--release")

CRATE_NAME="trueseal_sync"           # underscored crate name
LIB_NAME="lib${CRATE_NAME}.a"

# Use a writable target dir outside the Rust crate to avoid com.apple.provenance
# lock files that macOS stamps on files inside the source tree.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/trueseal-sync-build}"

BUILD_DIR="$CARGO_TARGET_DIR"
OUT_DIR="$REPO_ROOT/build"
XCFRAMEWORK_DIR="$REPO_ROOT/TruesealSyncFFI.xcframework"
BINDINGS_DIR="$REPO_ROOT/Sources/TruesealSyncBindings"

# ── Helpers ───────────────────────────────────────────────────────────────────

step() { echo -e "\n\033[1;34m▶  $*\033[0m"; }
ok()   { echo -e "\033[1;32m✓  $*\033[0m"; }
fail() { echo -e "\033[1;31m✗  $*\033[0m" >&2; exit 1; }

require() {
    command -v "$1" &>/dev/null || fail "Required tool not found: $1"
}

# ── Preflight ─────────────────────────────────────────────────────────────────

require lipo
require xcodebuild

# Prefer the rustup-managed cargo over any Homebrew-installed one so that
# cross-compilation targets installed via `rustup target add` are visible.
if [[ -x "$HOME/.cargo/bin/cargo" ]]; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi
require cargo

step "Building trueseal-sync for all targets (profile=$PROFILE)"

TARGETS=(
    "aarch64-apple-darwin"
    "x86_64-apple-darwin"
    "aarch64-apple-ios"
    "aarch64-apple-ios-sim"
    "x86_64-apple-ios"         # Intel iOS Simulator (needed for universal sim slice)
)

for TARGET in "${TARGETS[@]}"; do
    step "  cargo build → $TARGET"
    (
        cd "$RUST_DIR"
        cargo build "${CARGO_FLAGS[@]}" --target "$TARGET" 2>&1 | tail -3
    )
    # Verify the static archive was produced before continuing.
    EXPECTED="$BUILD_DIR/$TARGET/$PROFILE/$LIB_NAME"
    [[ -f "$EXPECTED" ]] || fail "Missing $EXPECTED after build — is staticlib in crate-type?"
    ok "$TARGET"
done

# ── Lipo: macOS universal ─────────────────────────────────────────────────────

step "Lipo macOS arm64 + x86_64"
mkdir -p "$OUT_DIR/macos" "$OUT_DIR/ios" "$OUT_DIR/ios-sim"

lipo -create \
    "$BUILD_DIR/aarch64-apple-darwin/$PROFILE/$LIB_NAME" \
    "$BUILD_DIR/x86_64-apple-darwin/$PROFILE/$LIB_NAME" \
    -output "$OUT_DIR/macos/$LIB_NAME"
ok "macOS universal: $OUT_DIR/macos/$LIB_NAME"

# ── iOS device (arm64 only) ───────────────────────────────────────────────────

cp "$BUILD_DIR/aarch64-apple-ios/$PROFILE/$LIB_NAME" "$OUT_DIR/ios/$LIB_NAME"
ok "iOS device: $OUT_DIR/ios/$LIB_NAME"

# ── Lipo: iOS Simulator universal ────────────────────────────────────────────

step "Lipo iOS Simulator arm64 + x86_64"
lipo -create \
    "$BUILD_DIR/aarch64-apple-ios-sim/$PROFILE/$LIB_NAME" \
    "$BUILD_DIR/x86_64-apple-ios/$PROFILE/$LIB_NAME" \
    -output "$OUT_DIR/ios-sim/$LIB_NAME"
ok "iOS Simulator universal: $OUT_DIR/ios-sim/$LIB_NAME"

# ── UniFFI: generate Swift bindings ──────────────────────────────────────────

step "Generating UniFFI Swift bindings"

# Use the in-tree binary (cargo run --bin uniffi-bindgen).
# The generated files land in OUT_DIR/bindings/:
#   trueseal_sync.swift
#   trueseal_syncFFI.h
#   trueseal_syncFFI.modulemap
BINDGEN_OUT="$OUT_DIR/bindings"
mkdir -p "$BINDGEN_OUT"

DYLIB_PATH="$BUILD_DIR/aarch64-apple-darwin/$PROFILE/lib${CRATE_NAME}.dylib"
# Fall back to .a if no dylib (static-only build)
if [[ ! -f "$DYLIB_PATH" ]]; then
    DYLIB_PATH="$BUILD_DIR/aarch64-apple-darwin/$PROFILE/$LIB_NAME"
fi

(
    cd "$RUST_DIR"
    cargo run --bin uniffi-bindgen -- generate \
        --library "$DYLIB_PATH" \
        --language swift \
        --out-dir "$BINDGEN_OUT" \
        2>&1 | tail -5
)
ok "Bindings written to $BINDGEN_OUT"

# ── Copy module map + header to each slice ────────────────────────────────────

for SLICE_DIR in "$OUT_DIR/macos" "$OUT_DIR/ios" "$OUT_DIR/ios-sim"; do
    cp "$BINDGEN_OUT/${CRATE_NAME}FFI.h"         "$SLICE_DIR/"
    cp "$BINDGEN_OUT/${CRATE_NAME}FFI.modulemap" "$SLICE_DIR/module.modulemap"
done

# ── Assemble XCFramework ──────────────────────────────────────────────────────

step "Assembling TruesealSyncFFI.xcframework"
rm -rf "$XCFRAMEWORK_DIR"

xcodebuild -create-xcframework \
    -library "$OUT_DIR/macos/$LIB_NAME"    -headers "$OUT_DIR/macos"    \
    -library "$OUT_DIR/ios/$LIB_NAME"      -headers "$OUT_DIR/ios"      \
    -library "$OUT_DIR/ios-sim/$LIB_NAME"  -headers "$OUT_DIR/ios-sim"  \
    -output "$XCFRAMEWORK_DIR"

ok "XCFramework: $XCFRAMEWORK_DIR"

# ── Copy generated Swift file into TruesealSyncBindings ──────────────────────────

step "Installing Swift bindings into Sources/TruesealSyncBindings/"
rm -f "$BINDINGS_DIR/Placeholder.swift"  # remove compile-time stub
cp "$BINDGEN_OUT/${CRATE_NAME}.swift" "$BINDINGS_DIR/${CRATE_NAME}.swift"
ok "Bindings installed: $BINDINGS_DIR/${CRATE_NAME}.swift"

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  TruesealSyncFFI.xcframework ready.                             ║"
echo "║  Run 'swift build' or open in Xcode to verify.             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
