#!/bin/bash

set -euo pipefail

prototype_root=$(cd "$(dirname "$0")/.." && pwd)
output_root=${1:-"$prototype_root/.build/capture-app"}
approved_common_name='Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)'
approved_fingerprint='189EC9780DE0A94CF5B24CC5983CAB3FDAE15638'
app_path="$output_root/Grab Rabbit Foreground Probe.app"

identity_output=$(security find-identity -v -p codesigning)
if ! grep -Fq "$approved_fingerprint \"$approved_common_name\"" <<<"$identity_output"; then
    echo "The exact approved Developer ID identity is unavailable; refusing to sign." >&2
    exit 1
fi

certificate_output=$(security find-certificate -a -c "$approved_common_name" -Z)
if ! grep -Fq "SHA-1 hash: $approved_fingerprint" <<<"$certificate_output"; then
    echo "The installed certificate fingerprint does not match the approved release binding." >&2
    exit 1
fi

swift build --package-path "$prototype_root" -c release --product foreground-probe
binary_dir=$(swift build --package-path "$prototype_root" -c release --show-bin-path)

mkdir -p "$app_path/Contents/MacOS"
cp "$prototype_root/CaptureApp-Info.plist" "$app_path/Contents/Info.plist"
cp "$binary_dir/foreground-probe" "$app_path/Contents/MacOS/foreground-probe"

codesign --force --options runtime --timestamp \
    --sign "$approved_fingerprint" "$app_path"
codesign --verify --strict --verbose=2 "$app_path"

echo "$app_path"
