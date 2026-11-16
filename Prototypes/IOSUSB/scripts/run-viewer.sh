#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
if [ "$#" -ne 1 ]; then
  printf 'Usage: %s IPHONE_UDID\n' "$0" >&2
  exit 2
fi
RUNTIME="$ROOT/build/ios-usb-native"
exec "$RUNTIME/TandemUSBProbe.app/Contents/MacOS/TandemUSBProbe" \
  --backend "$RUNTIME/tandem-ios-usb" --udid "$1" \
  --metrics "$RUNTIME/viewer-backend-metrics.ndjson"
