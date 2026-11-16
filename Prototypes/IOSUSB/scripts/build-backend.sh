#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h:h:h:h}"
TASK_BUILD="$TASK_ROOT/build/ios-usb-native"
TASK_VENDOR="$TASK_BUILD/vendor/idevice"
TASK_REV="89702099f4d7552f704f93b4526756abda319ceb"
mkdir -p "$TASK_BUILD/vendor"
if [[ ! -d "$TASK_VENDOR/.git" ]]; then
  git clone https://github.com/jkcoxson/idevice.git "$TASK_VENDOR"
fi
if [[ "$(git -C "$TASK_VENDOR" rev-parse HEAD)" != "$TASK_REV" ]]; then
  git -C "$TASK_VENDOR" fetch origin "$TASK_REV"
  git -C "$TASK_VENDOR" checkout --detach "$TASK_REV"
fi
TASK_CARGO="${CARGO:-/opt/homebrew/bin/cargo}"
if [[ ! -x "$TASK_CARGO" ]]; then TASK_CARGO="$(command -v cargo)"; fi
export CARGO_TARGET_DIR="$TASK_BUILD/cargo-target"
"$TASK_CARGO" build --locked --release --manifest-path "$TASK_ROOT/Prototypes/IOSUSB/Backend/Cargo.toml"
# New inode + atomic replacement avoids macOS retaining the old executable's
# code-signature cache while a viewer still has that executable open.
TASK_STAGED="$TASK_BUILD/tandem-ios-usb.new.$$"
trap 'rm -f "$TASK_STAGED"' EXIT
cp "$CARGO_TARGET_DIR/release/tandem-ios-usb" "$TASK_STAGED"
mv -f "$TASK_STAGED" "$TASK_BUILD/tandem-ios-usb"
echo "$TASK_BUILD/tandem-ios-usb"
