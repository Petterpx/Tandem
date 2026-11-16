#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
if [ "$#" -ne 1 ]; then
  printf 'Usage: %s IPHONE_UDID\n' "$0" >&2
  exit 2
fi
RUNTIME="$ROOT/build/ios-usb-native"
mkdir -p "$RUNTIME"
xcrun devicectl device info ddiServices --device "$1" --auto-mount-ddis \
  --timeout 30 --json-output "$RUNTIME/ddi-services.json"
"$RUNTIME/tandem-ios-usb" --probe --udid "$1"
