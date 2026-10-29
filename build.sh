#!/bin/sh
# Build, sign and package proxy-copy for Apple silicon Macs.
#
#   ./build.sh                 build into build/proxy-copy (unsigned)
#   SIGN_ID="Developer ID Application: Name (TEAMID)" ./build.sh
#                              also sign with hardened runtime
#   NOTARY_PROFILE=profile ./build.sh
#                              also notarize (needs SIGN_ID and a profile made
#                              with `xcrun notarytool store-credentials`)
set -eu
cd "$(dirname "$0")"
mkdir -p build

swiftc -O -swift-version 5 -target arm64-apple-macos13 \
  -framework ImageCaptureCore -lsqlite3 \
  Sources/proxy-copy.swift -o build/proxy-copy

if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --options runtime --timestamp \
    --entitlements proxy-copy.entitlements \
    --identifier com.morrisseymedia.proxy-copy \
    -s "$SIGN_ID" build/proxy-copy
fi

(cd build && rm -f proxy-copy-macos-arm64.zip && zip -q proxy-copy-macos-arm64.zip proxy-copy)

if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit build/proxy-copy-macos-arm64.zip \
    --keychain-profile "$NOTARY_PROFILE" --wait
fi

echo "build/proxy-copy-macos-arm64.zip"
