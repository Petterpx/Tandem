#!/bin/bash
# 生成测试 APK 夹具（包名 dev.tandem.testapp，无代码，minSdk 21）。
# 密钥只放在临时目录，脚本结束即删除。可重复执行。
set -euo pipefail

SDK="${ANDROID_SDK:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/34.0.0"
JAR="$SDK/platforms/android-34/android.jar"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Packages/TandemCore/Tests/AndroidDriverTests/Fixtures/tandem-test.apk"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/AndroidManifest.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="dev.tandem.testapp">
    <uses-sdk android:minSdkVersion="21" android:targetSdkVersion="34" />
    <application android:label="TandemTest" android:hasCode="false" />
</manifest>
XML

"$BT/aapt2" link -o "$WORK/unsigned.apk" -I "$JAR" --manifest "$WORK/AndroidManifest.xml" \
    --min-sdk-version 21 --target-sdk-version 34 --version-code 1 --version-name 1.0
"$BT/zipalign" -f 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
/usr/bin/keytool -genkeypair -keystore "$WORK/test.jks" -storepass tandem -keypass tandem \
    -alias test -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Tandem Test" >/dev/null 2>&1
mkdir -p "$(dirname "$OUT")"
"$BT/apksigner" sign --ks "$WORK/test.jks" --ks-pass pass:tandem --key-pass pass:tandem \
    --out "$OUT" "$WORK/aligned.apk"
rm -f "$OUT.idsig"
"$BT/aapt2" dump packagename "$OUT"
