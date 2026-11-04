#!/bin/bash
set -euo pipefail
integration_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${1:?output directory}"
mkdir -p "$output_dir/TextFixture.app"
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator -parse-as-library "$integration_dir/TextFixture.swift" -o "$output_dir/TextFixture.app/TextFixture"
cat > "$output_dir/TextFixture.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>TextFixture</string><key>CFBundleIdentifier</key><string>local.tandem.text-fixture</string><key>CFBundleName</key><string>TextFixture</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>LSRequiresIPhoneOS</key><true/><key>UIApplicationSceneManifest</key><dict/><key>CFBundleURLTypes</key><array><dict><key>CFBundleURLSchemes</key><array><string>textfixture</string></array></dict></array></dict></plist>
PLIST
codesign --force --sign - "$output_dir/TextFixture.app"
