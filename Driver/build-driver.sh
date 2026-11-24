#!/bin/zsh
# Builds Driver/build/WhopperMic.driver (universal-free arm64 + x86_64) and signs it with the local identity.
set -euo pipefail
cd "$(dirname "$0")"
OUT="build/WhopperMic.driver"
rm -rf "$OUT"; mkdir -p "$OUT/Contents/MacOS"
clang -bundle -O2 -Wall -Wextra -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
  -framework CoreAudio -framework CoreFoundation \
  -o "$OUT/Contents/MacOS/WhopperMic" WhopperMic/WhopperMic.c
cp WhopperMic/Info.plist "$OUT/Contents/Info.plist"
IDENTITY="Whopper Local Signing"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then codesign --force --sign "$IDENTITY" "$OUT"; else codesign --force --sign - "$OUT"; fi
echo "Built $OUT"
