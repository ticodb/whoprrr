#!/bin/zsh
# Builds dist/Whoprrr-<version>-<label>.dmg and .zip plus SHA256SUMS from the current tree.
# Public beta builds are ad-hoc signed (SIGN_IDENTITY="-"). With a paid Apple Developer account:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/release.sh
# then notarize (docs/releasing.md).
set -euo pipefail
cd "$(dirname "$0")/.."
export SIGN_IDENTITY="${SIGN_IDENTITY--}"
VERSION="$(cat VERSION)"
LABEL="${RELEASE_LABEL-beta 9}"
TAG="${VERSION}${LABEL:+-${LABEL// /}}"
./scripts/build-app.sh

rm -rf dist; mkdir -p dist
ditto -c -k --keepParent build/Whoprrr.app "dist/Whoprrr-${TAG}.zip"

STAGE="$(mktemp -d)"
cp -R build/Whoprrr.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp docs/install.md "$STAGE/READ ME FIRST.md"
hdiutil create -quiet -volname "Whoprrr ${TAG}" -srcfolder "$STAGE" -ov -format UDZO "dist/Whoprrr-${TAG}.dmg"
rm -rf "$STAGE"

( cd dist && shasum -a 256 *.zip *.dmg > SHA256SUMS )
echo; ls -lh dist; echo; cat dist/SHA256SUMS
