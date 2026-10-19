#!/bin/bash
# 下载并校验第三方二进制（adb、scrcpy-server）到 App/Resources/Vendor/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/App/Resources/Vendor"
SCRCPY_VERSION="5.0.1"
PT_URL="https://dl.google.com/android/repository/platform-tools_r37.0.0-darwin.zip"
PT_SHA="094a1395683c509fd4d48667da0d8b5ef4d42b2abfcd29f2e8149e2f989357c7"
SERVER_URL="https://github.com/Genymobile/scrcpy/releases/download/v${SCRCPY_VERSION}/scrcpy-server-v${SCRCPY_VERSION}"
SERVER_SHA="764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536"
LICENSE_URL="https://raw.githubusercontent.com/Genymobile/scrcpy/v${SCRCPY_VERSION}/LICENSE"

mkdir -p "$VENDOR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

verify() { # file sha
  echo "$2  $1" | /usr/bin/shasum -a 256 -c >/dev/null 2>&1
}

# scrcpy-server
if [ -f "$VENDOR/scrcpy-server-v${SCRCPY_VERSION}" ] && verify "$VENDOR/scrcpy-server-v${SCRCPY_VERSION}" "$SERVER_SHA"; then
  echo "scrcpy-server 已存在且校验通过，跳过"
else
  curl -fsSL --retry 3 -o "$TMP/scrcpy-server" "$SERVER_URL"
  verify "$TMP/scrcpy-server" "$SERVER_SHA" || { echo "scrcpy-server sha256 校验失败" >&2; exit 1; }
  mv "$TMP/scrcpy-server" "$VENDOR/scrcpy-server-v${SCRCPY_VERSION}"
fi

# platform-tools (adb)
if [ -x "$VENDOR/adb" ] && [ -f "$VENDOR/NOTICE.txt" ] && "$VENDOR/adb" version >/dev/null 2>&1; then
  echo "adb 已存在且可运行，跳过"
else
  curl -fsSL --retry 3 -o "$TMP/platform-tools.zip" "$PT_URL"
  verify "$TMP/platform-tools.zip" "$PT_SHA" || { echo "platform-tools sha256 校验失败" >&2; exit 1; }
  unzip -q -o "$TMP/platform-tools.zip" platform-tools/adb platform-tools/NOTICE.txt -d "$TMP/x"
  cp "$TMP/x/platform-tools/adb" "$VENDOR/adb"
  cp "$TMP/x/platform-tools/NOTICE.txt" "$VENDOR/NOTICE.txt"
  chmod +x "$VENDOR/adb"
fi

# scrcpy LICENSE
if [ ! -s "$VENDOR/LICENSE" ]; then
  curl -fsSL --retry 3 -o "$VENDOR/LICENSE" "$LICENSE_URL"
fi
echo "vendor 就绪: $VENDOR"
