#!/bin/bash
# Optional experimental iOS support; Android/Simulator builds do not require Rust.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
destination_dir="${1:?Usage: build-ios-usb-helper.sh /path/to/Tandem.app/Contents/MacOS}"
helper_path="$destination_dir/tandem-ios-usb"
license_dir="$destination_dir/IOSUSBLicenses"
if [[ "$destination_dir" == */Contents/MacOS ]]; then
    license_dir="${destination_dir%/MacOS}/Resources/IOSUSBLicenses"
fi
mode="${TANDEM_BUILD_IOS_USB_HELPER:-auto}"
skip_helper() {
    # Do not leave a previously bundled helper active after an explicit opt-out.
    rm -f "$helper_path"
    rm -rf "$license_dir"
    echo "warning: $1 Experimental iOS USB support is disabled; Android and Simulator remain available." >&2
    exit 0
}
case "$mode" in
    0) skip_helper 'TANDEM_BUILD_IOS_USB_HELPER=0.' ;;
    auto|1) ;;
    *) echo 'error: TANDEM_BUILD_IOS_USB_HELPER must be auto, 0, or 1.' >&2; exit 1 ;;
esac
if [[ "$mode" == auto && -n "${CI:-}" && "${CI:-}" != false && "${CI:-}" != 0 ]]; then
    skip_helper 'CI auto mode does not add a Rust build dependency; set TANDEM_BUILD_IOS_USB_HELPER=1 to opt in.'
fi
cargo_path="${CARGO:-}"
if [[ -z "$cargo_path" ]]; then cargo_path="$(command -v cargo || true)"; fi
if [[ -z "$cargo_path" && -x /opt/homebrew/bin/cargo ]]; then cargo_path=/opt/homebrew/bin/cargo; fi
if [[ -z "$cargo_path" && -x "$HOME/.cargo/bin/cargo" ]]; then cargo_path="$HOME/.cargo/bin/cargo"; fi
if [[ ! -x "$cargo_path" ]]; then
    if [[ "$mode" == auto ]]; then skip_helper 'Cargo was not found; install Rust to build the optional helper.'; fi
    echo 'error: Cargo is required with TANDEM_BUILD_IOS_USB_HELPER=1.' >&2
    exit 1
fi
if ! CARGO="$cargo_path" "$repo_dir/Prototypes/IOSUSB/scripts/build-backend.sh" >&2; then
    if [[ "$mode" == auto ]]; then skip_helper 'The optional Rust helper build failed; use TANDEM_BUILD_IOS_USB_HELPER=1 to require it.'; fi
    echo 'error: Required experimental iOS USB helper build failed.' >&2
    exit 1
fi
# License completeness is part of a successful helper build.
if ! python3 "$repo_dir/scripts/collect-ios-usb-licenses.py" \
    --cargo "$cargo_path" \
    --manifest-path "$repo_dir/Prototypes/IOSUSB/Backend/Cargo.toml" \
    --output "$license_dir" >&2 || \
    ! cp "$repo_dir/Prototypes/IOSUSB/Backend/THIRD_PARTY.md" "$license_dir/THIRD_PARTY.md" || \
    ! cp "$repo_dir/build/ios-usb-native/vendor/idevice/LICENSE.txt" "$license_dir/idevice-LICENSE.txt"; then
    rm -f "$helper_path"
    rm -rf "$license_dir"
    if [[ "$mode" == auto ]]; then skip_helper 'The optional helper license collection failed.'; fi
    echo 'error: Required experimental iOS USB helper license collection failed.' >&2
    exit 1
fi
mkdir -p "$destination_dir"
staged_path="$(mktemp "$destination_dir/.tandem-ios-usb.XXXXXX")"
trap 'rm -f "$staged_path"' EXIT
cp "$repo_dir/build/ios-usb-native/tandem-ios-usb" "$staged_path"
chmod 755 "$staged_path"
# New inode avoids macOS's executable code-signature cache after rebuilding.
/usr/bin/codesign --force --sign - "$staged_path" >&2
mv -f "$staged_path" "$helper_path"
echo "$helper_path"
