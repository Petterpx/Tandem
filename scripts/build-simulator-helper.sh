#!/bin/bash
# Build an isolated macOS 15/arm64 helper; the containing app can retain macOS 14.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
package_dir="$repo_dir/Packages/SimulatorHelper"
destination_dir="${1:-$repo_dir/App/Resources/Vendor/Simulator}"
if [[ "$(uname -m)" != "arm64" ]]; then
    echo 'Skipping iOS simulator helper: Apple Silicon is required; Android remains available.' >&2
    exit 0
fi
swift build --package-path "$package_dir" --configuration release --product tandem-simulator >&2
binary_dir="$(swift build --package-path "$package_dir" --configuration release --show-bin-path)"
mkdir -p "$destination_dir"
cp "$binary_dir/tandem-simulator" "$destination_dir/tandem-simulator"
# The guest binary is data to macOS (Mach-O platform iOS Simulator). It belongs
# beside the host helper in development, or in Resources in a signed app bundle.
guest_dir="$destination_dir"
if [[ "$destination_dir" == */Contents/MacOS ]]; then
    guest_dir="${destination_dir%/MacOS}/Resources/Simulator"
fi
mkdir -p "$guest_dir"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -Os -fobjc-arc \
    "$package_dir/Guest/TextInput.m" -framework Foundation -framework UIKit \
    -o "$guest_dir/tandem-simulator-text"
/usr/bin/codesign --force --sign - "$guest_dir/tandem-simulator-text" >&2
for framework_name in CoreSimulatorStub AccessibilityPlatformTranslationStub; do
    framework="$binary_dir/$framework_name.framework"
    if [[ ! -d "$framework" ]]; then
        framework="$package_dir/.build/artifacts/homebrew-fb/$framework_name/$framework_name.xcframework/macos-arm64/$framework_name.framework"
    fi
    if [[ -d "$framework" ]]; then
        # ditto preserves framework version symlinks.
        /usr/bin/ditto "$framework" "$destination_dir/$framework_name.framework"
        /usr/bin/codesign --force --sign - "$destination_dir/$framework_name.framework" >&2
    elif /usr/bin/otool -L "$binary_dir/tandem-simulator" | /usr/bin/grep -q "$framework_name.framework"; then
        echo "Missing linked framework: $framework_name" >&2
        exit 1
    fi
done
# SwiftPM doesn't give command-line products an executable-relative framework runpath.
/usr/bin/install_name_tool -add_rpath '@executable_path' "$destination_dir/tandem-simulator"
/usr/bin/codesign --force --sign - "$destination_dir/tandem-simulator" >&2
# Text resources cannot live under Contents/MacOS: codesign treats them as code.
license_dir="$destination_dir/Licenses"
if [[ "$destination_dir" == */Contents/MacOS ]]; then
    license_dir="${destination_dir%/MacOS}/Resources/SimulatorLicenses"
fi
/usr/bin/ditto "$package_dir/Licenses" "$license_dir"
echo "$destination_dir/tandem-simulator"
