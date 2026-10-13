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

Two dispatch-only workflows, per
[e2e ADR-0002](https://github.com/julianbonomini/trueseal-e2e/blob/main/docs/adr/0002-release-conductor-orchestration.md):

1. **Candidate** — `gh workflow run release.yml -f version=0.x.x` (add
   `-f dry_run=true` to build, test and stamp without staging anything).
   [release.yml](.github/workflows/release.yml) downloads the pinned core artifact,
   verifies its checksum, builds and tests, stamps the constants, commits the release
   pin to `release/v0.x.x` (pushed without force), and creates a **draft** candidate
   release carrying `TruesealSyncFFI.xcframework.zip`. The Release Conductor (or a
   maintainer) can target a core *candidate* instead of the committed pin with
   `-f core_tag=<tag> -f core_zip_sha256=<sha>` — an override changes which pinned
   bytes, never whether the bytes are pinned.
2. **Promote** — `gh workflow run promote.yml -f version=0.x.x`.
   [promote.yml](.github/workflows/promote.yml) verifies the staged zip against the
   release commit's stamped checksum (recomputed with the candidate's own tool),
   refuses to touch an existing tag, then publishes the draft — creating the
   immutable tag `v0.x.x` on the release commit. Same bytes, no rebuild; idempotent
   on re-run (already-published is a no-op). Release notes link the lockstep
   changelog's `trueseal-sync-swift` section.

Tags are never moved
([sync ADR-0030](https://github.com/julianbonomini/trueseal-sync/blob/main/docs/adr/0030-distribution-channels-and-lockstep-versions.md));
a bad release is a new patch version. Pushing a tag directly triggers nothing.

### The core pin (G8)

`TRUESEAL_SYNC_TAG` + `TRUESEAL_SYNC_ZIP_SHA256` at the top of
[ci.yml](.github/workflows/ci.yml) and [release.yml](.github/workflows/release.yml)
are an exact version + checksum pin, committed so no one can change it without
review. The checksum is the **core release's published** value.

While the cross-repo `TRUESEAL_READ_TOKEN` PAT is expired (maintainer item A6), the
bytes travel through this repo's byte-exact `core-<tag>` mirror release;
`scripts/mirror-core-artifact.sh <tag>` performs the mirror with verification in
both directions. Once the token is refreshed (or the core repo is public), flip the
two `gh release download` steps to `--repo julianbonomini/trueseal-sync` and retire
the mirror — the checksum constant does not change. A CI guard rejects floating
cross-repo inputs (`releases/latest`, `:latest`, sibling paths) outright.

### Parity (G12)

`python3 scripts/check-parity.py` compares every public case name in the SDK against
the core's canonical Shared Facts (vendored at `Parity/shared-facts.json`, pinned by
commit + sha256 — refresh procedure in [Parity/README.md](Parity/README.md)). CI runs
the check plus its negative self-test and uploads the report as Release Evidence for
the Conductor. Any drift — a renamed, missing or extra case — fails the build.

### Re-enabling the dead-relay disconnect test

`test_onEvent_connectionTransitions_againstLiveRelay` has its disconnect half parked
(the core did not detect a killed relay — trueseal-sync B23c, PR #146). Once that fix
merges AND the pinned core artifact is rebuilt past the merge (re-stage the core
candidate, re-run `scripts/mirror-core-artifact.sh`, commit the new checksum
constant), re-enable the assertion: kill the fixture relay after the `connected`
event and expect `connectionChanged(.disconnected)` within ~120 s (the watchdog
surfaces it in ~75–100 s at production timeouts).
