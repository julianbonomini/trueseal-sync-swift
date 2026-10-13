#!/usr/bin/env bash
# mirror-core-artifact.sh [core-tag]   (default: v0.6.0)
#
# Byte-exact republish of the core's Swift artifact into THIS repo's
# `core-<tag>` release — the transport half of the G8 core pin while the
# cross-repo TRUESEAL_READ_TOKEN PAT is expired (maintainer item A6).
#
# Why this exists: ci.yml / release.yml run with the workflow GITHUB_TOKEN,
# which cannot read another repo's releases. The PIN is still exact — the
# committed TRUESEAL_SYNC_ZIP_SHA256 constant is the CORE release's
# published checksum, and every download verifies against it — the mirror
# only changes WHERE the bytes are fetched from. Once the token is
# refreshed (or the core repo is public), the download steps flip to
# `--repo julianbonomini/trueseal-sync` and this script is retired; the
# checksum constant does not change.
#
# What it does, in order:
#   1. downloads trueseal-sync-swift-<tag>.zip + .sha256 from the core repo
#      (needs `gh` auth that can read julianbonomini/trueseal-sync — the
#      maintainer's login today, the Conductor's GitHub App later);
#   2. verifies the zip against the core's published .sha256 (refuses to
#      mirror bytes the core release does not name);
#   3. creates this repo's `core-<tag>` prerelease if missing and uploads
#      the zip (idempotent: an existing asset is left untouched);
#   4. downloads the mirrored asset BACK and re-verifies the checksum;
#   5. prints the value TRUESEAL_SYNC_ZIP_SHA256 must carry (it must equal
#      the core's published checksum — if the workflows disagree, fix the
#      commit, not the mirror).
set -euo pipefail

CORE_REPO="julianbonomini/trueseal-sync"
THIS_REPO="julianbonomini/trueseal-sync-swift"
TAG="${1:-v0.6.0}"
ZIP="trueseal-sync-swift-${TAG}.zip"
MIRROR_TAG="core-${TAG}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "▶ 1/5 download $ZIP (+ .sha256) from $CORE_REPO@$TAG"
gh release download "$TAG" --repo "$CORE_REPO" \
  --pattern "$ZIP" --pattern "$ZIP.sha256" \
  --dir "$WORK" --clobber

echo "▶ 2/5 verify against the core's published checksum"
CORE_PUBLISHED_SHA="$(awk '{print $1}' "$WORK/$ZIP.sha256")"
echo "$CORE_PUBLISHED_SHA" | grep -qE '^[0-9a-f]{64}$' \
  || { echo "FAIL: $CORE_REPO $ZIP.sha256 is not a single sha256"; exit 1; }
( cd "$WORK" && echo "$CORE_PUBLISHED_SHA  $ZIP" | shasum -a 256 -c - )

echo "▶ 3/5 ensure the mirror release $THIS_REPO@$MIRROR_TAG"
if ! gh release view "$MIRROR_TAG" --repo "$THIS_REPO" >/dev/null 2>&1; then
  gh release create "$MIRROR_TAG" --repo "$THIS_REPO" \
    --title "Core artifact mirror: trueseal-sync $TAG" \
    --notes "Byte-exact republish of $CORE_REPO@$TAG $ZIP for this repo's CI (G8 pin transport; see scripts/mirror-core-artifact.sh). sha256: $CORE_PUBLISHED_SHA" \
    --prerelease
fi
if ! gh release view "$MIRROR_TAG" --repo "$THIS_REPO" --json assets --jq '.assets[].name' | grep -qx "$ZIP"; then
  gh release upload "$MIRROR_TAG" --repo "$THIS_REPO" "$WORK/$ZIP"
else
  echo "   asset already mirrored — left untouched (mirror content is immutable)"
fi

echo "▶ 4/5 download the mirrored asset back and re-verify"
mkdir -p "$WORK/roundtrip"
gh release download "$MIRROR_TAG" --repo "$THIS_REPO" \
  --pattern "$ZIP" --dir "$WORK/roundtrip" --clobber
( cd "$WORK/roundtrip" && echo "$CORE_PUBLISHED_SHA  $ZIP" | shasum -a 256 -c - )

echo "▶ 5/5 pin check"
WORKFLOW_SHA="$(grep -E '^[[:space:]]*TRUESEAL_SYNC_ZIP_SHA256:' .github/workflows/ci.yml | awk '{print $2}')"
if [ "$WORKFLOW_SHA" = "$CORE_PUBLISHED_SHA" ]; then
  echo "OK: TRUESEAL_SYNC_ZIP_SHA256 already matches the core's published checksum"
else
  echo "NOTE: the workflows pin $WORKFLOW_SHA"
  echo "      the core's published checksum is $CORE_PUBLISHED_SHA"
  echo "      → commit the new constant in ci.yml AND release.yml together (one commit, one pin)"
fi
echo "done: $MIRROR_TAG serves bytes identical to $CORE_REPO@$TAG"
