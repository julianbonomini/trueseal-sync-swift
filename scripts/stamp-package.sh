#!/bin/sh
# stamp-package.sh <version> <checksum>
#
# Writes the SWIFT-2 release pin constants at the top of Package.swift for a
# release commit (e2e ADR-0002 step 2): the version, the download URL this
# repo's GitHub Release will serve the XCFramework from, and its
# `swift package compute-checksum` value.
#
# The candidate build (release.yml) runs this BEFORE the tag exists; the
# promotion step (SDK-4) creates the immutable tag on the stamped commit.
# The URL is deterministic from the version, so a release commit can be
# written before the release (and its tag) exist.
#
# Env: REPO — owner/name used in the URL (default: the canonical repo).
set -eu

VERSION="${1:?usage: stamp-package.sh <version> <checksum>}"
CHECKSUM="${2:?usage: stamp-package.sh <version> <checksum>}"
REPO="${REPO:-julianbonomini/trueseal-sync-swift}"

URL="https://github.com/${REPO}/releases/download/v${VERSION}/TruesealSyncFFI.xcframework.zip"

# The constants are anchored at line start so a stamp can never hit an
# unrelated string (the failure mode of the old path:→url: sed rewrite).
sed -i '' \
  -e "s|^let version = \".*\"|let version = \"${VERSION}\"|" \
  -e "s|^let artifactURL = \".*\"|let artifactURL = \"${URL}\"|" \
  -e "s|^let artifactChecksum = \".*\"|let artifactChecksum = \"${CHECKSUM}\"|" \
  Package.swift

# Fail loudly if any constant did not get stamped.
grep -q "^let version = \"${VERSION}\"$"           Package.swift
grep -q "^let artifactURL = \"${URL}\"$"           Package.swift
grep -q "^let artifactChecksum = \"${CHECKSUM}\"$" Package.swift

echo "Stamped Package.swift: version=${VERSION}"
echo "  url      = ${URL}"
echo "  checksum = ${CHECKSUM}"
