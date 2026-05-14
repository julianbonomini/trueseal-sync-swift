# TruesealSyncBindings — generated, do not edit

This directory contains the UniFFI-generated Swift bindings for the Rust `trueseal-sync` crate.

**Do not hand-edit** — the file is regenerated every time `scripts/build-xcframework.sh` runs.

## Contents after build

| File | Source |
|------|--------|
| `hush_sync.swift` | `uniffi-bindgen generate --language swift` |

## Exposed symbols (internal to the package)

These types are **not part of the public API**.  App developers never interact with them.
They are consumed exclusively by `Sources/TruesealSync/` via `@_implementationOnly import TruesealSyncBindings`.

| Symbol | Kind |
|--------|------|
| `HushFfiSession` | UniFFI object |
| `SessionError` | UniFFI error enum |
| `Member` | UniFFI record |
| `MessageCallback` | UniFFI callback interface protocol |
| `RemovedFromGroupCallback` | UniFFI callback interface protocol |
| `GroupDestroyedCallback` | UniFFI callback interface protocol |
| `MemberRequestCallback` | UniFFI callback interface protocol |
| `MemberJoinedCallback` | UniFFI callback interface protocol |
| `MemberLeftCallback` | UniFFI callback interface protocol |
| `ConnectionChangedCallback` | UniFFI callback interface protocol |
