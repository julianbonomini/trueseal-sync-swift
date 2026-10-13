# Contributing

Local development and release mechanics for trueseal-sync-swift. If you just want to
use the SDK, the [README](README.md) is the quickstart.

## Local development

Requires the sibling repos checked out side-by-side:

```
trueseal/
  trueseal-noise/
  trueseal-sync/
  trueseal-sync-swift/   ← this repo
```

```bash
# One-time: install Rust targets
rustup target add \
    aarch64-apple-darwin x86_64-apple-darwin \
    aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

# Build XCFramework + generate Swift bindings
bash scripts/build-xcframework.sh
```

The committed `Package.swift` on main always builds from the local path (the
`artifactURL`/`artifactChecksum` constants at the top of the file are empty on main).
Release commits have all three constants stamped by `scripts/stamp-package.sh`, so the
tagged tree records the exact `url:`+`checksum:` SPM consumers resolve (gates G8/G9).

> **Note:** `scripts/build-xcframework.sh` is for local development only. CI does not
> run it — it downloads the prebuilt artifact from
> [trueseal-sync releases](https://github.com/julianbonomini/trueseal-sync/releases)
> instead.

## Releasing

To stage a release: `gh workflow run release.yml -f version=0.x.x` (add
`-f dry_run=true` to build, test and stamp without publishing anything). The
[release workflow](.github/workflows/release.yml) downloads the prebuilt XCFramework
from the `trueseal-sync` core pinned by `TRUESEAL_SYNC_TAG`, verifies its checksum,
builds and tests, stamps the constants, commits the release pin to `release/v0.x.x`
(pushed without force), and creates a **draft** candidate release. Promotion (SDK-4)
creates the immutable tag `v0.x.x` on that exact commit and publishes the draft — same
bytes, no rebuild, and tags are never moved
([sync ADR-0030](https://github.com/julianbonomini/trueseal-sync/blob/main/docs/adr/0030-distribution-channels-and-lockstep-versions.md),
[e2e ADR-0002](https://github.com/julianbonomini/trueseal-e2e/blob/main/docs/adr/0002-release-conductor-orchestration.md)).
Pushing a tag directly triggers nothing.
