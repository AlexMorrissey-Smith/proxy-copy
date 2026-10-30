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
if [ -n "${NOTARY_PROFILE:-}" ] && [ -z "${SIGN_ID:-}" ]; then
  echo "NOTARY_PROFILE requires SIGN_ID (Developer ID Application certificate)." >&2
  exit 1
fi

swiftc -O -swift-version 5 -target arm64-apple-macos13 \
  -framework ImageCaptureCore \
  Sources/CR3.swift Sources/main.swift -o build/proxy-copy

if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --options runtime --timestamp \
    --entitlements proxy-copy.entitlements \
    --identifier com.morrisseymedia.proxy-copy \
    -s "$SIGN_ID" build/proxy-copy
  codesign --verify --strict --verbose=2 build/proxy-copy
fi

(cd build && rm -f proxy-copy-macos-arm64.zip && zip -q proxy-copy-macos-arm64.zip proxy-copy)

if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit build/proxy-copy-macos-arm64.zip \
    --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > build/notarization.json
  status=$(/usr/bin/plutil -extract status raw -o - build/notarization.json)
  if [ "$status" != "Accepted" ]; then
    cat build/notarization.json >&2
    exit 1
  fi
fi

(cd build && shasum -a 256 proxy-copy-macos-arm64.zip > SHA256SUMS)

echo "build/proxy-copy-macos-arm64.zip"
