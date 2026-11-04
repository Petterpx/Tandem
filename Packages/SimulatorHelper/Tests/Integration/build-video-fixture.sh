#!/bin/bash
# Build only. Installation and launch always require an explicit test-device UDID.
set -euo pipefail
fixture_source="$(cd "$(dirname "$0")" && pwd)"
fixture_output="${1:-$(mktemp -d "${TMPDIR:-/tmp}/tandem-video-fixture.XXXXXX")}"
fixture_app="$fixture_output/VideoProbe.app"
fixture_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
mkdir -p "$fixture_app"
xcrun --sdk iphonesimulator swiftc \
    -target arm64-apple-ios17.0-simulator \
    -sdk "$fixture_sdk" \
    -parse-as-library "$fixture_source/VideoProbe.swift" \
    -o "$fixture_app/VideoProbe"
cp "$fixture_source/VideoProbe-Info.plist" "$fixture_app/Info.plist"
codesign --force --sign - "$fixture_app" >&2
printf '%s\n' "$fixture_app"
