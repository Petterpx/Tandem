#!/bin/bash
set -euo pipefail
integration_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${1:?output directory}"
mkdir -p "$output_dir/ScrollFixture.app"
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator -parse-as-library "$integration_dir/ScrollFixture.swift" -o "$output_dir/ScrollFixture.app/ScrollFixture"
cat > "$output_dir/ScrollFixture.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>ScrollFixture</string><key>CFBundleIdentifier</key><string>local.tandem.scroll-fixture</string><key>CFBundleName</key><string>ScrollFixture</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>LSRequiresIPhoneOS</key><true/><key>UIApplicationSceneManifest</key><dict/><key>UILaunchScreen</key><dict/><key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array></dict></plist>
PLIST
codesign --force --sign - "$output_dir/ScrollFixture.app"
