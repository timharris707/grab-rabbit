#!/bin/bash

set -euo pipefail

usage() {
    echo "usage: $0 --unsigned|--sign-approved --output /absolute/path/to/Probe.app" >&2
    exit 2
}

[[ $# -eq 3 ]] || usage
mode=$1
[[ "$2" == '--output' ]] || usage
app=$3
[[ "$mode" == '--unsigned' || "$mode" == '--sign-approved' ]] || usage
[[ "$app" == /* && "$app" == *.app ]] || usage
[[ ! -e "$app" ]] || { echo "refusing to overwrite: $app" >&2; exit 3; }

prototype_root=$(cd "$(dirname "$0")/.." && pwd)
repository_root=$(cd "$prototype_root/../.." && pwd)
[[ "$(git -C "$repository_root" branch --show-current)" == 'prototype/48-render-cadence' ]] || {
    echo "refusing non-prototype branch" >&2
    exit 4
}

swift build --package-path "$prototype_root" -c release -Xswiftc -warnings-as-errors
binary="$prototype_root/.build/release/live-cadence-probe"
contents="$app/Contents"
mkdir -p "$contents/MacOS"
cp "$prototype_root/LiveProbe-Info.plist" "$contents/Info.plist"
cp "$binary" "$contents/MacOS/live-cadence-probe"
chmod 755 "$contents/MacOS/live-cadence-probe"

if [[ "$mode" == '--unsigned' ]]; then
    echo "unsigned_app=$app"
    exit 0
fi

approved_name='Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)'
approved_team='F66FM4V88Q'
approved_sha1='189EC9780DE0A94CF5B24CC5983CAB3FDAE15638'
disallowed_prefix='45F21D'
certificate_listing=$(security find-certificate -a -c "$approved_name" -Z 2>/dev/null || true)
grep -Fq "SHA-1 hash: $approved_sha1" <<<"$certificate_listing" || {
    echo "approved certificate fingerprint is not live; refusing to sign" >&2
    exit 5
}
identity_listing=$(security find-identity -v -p codesigning 2>/dev/null || true)
if grep -Fq "$disallowed_prefix" <<<"$identity_listing"; then
    echo "disallowed signing identity is live; refusing to sign" >&2
    exit 6
fi
grep -F "$approved_sha1" <<<"$identity_listing" | grep -F "$approved_name" >/dev/null || {
    echo "approved signing identity/private key is unavailable" >&2
    exit 7
}

codesign --force --options runtime --timestamp \
    --entitlements "$prototype_root/LiveProbe.entitlements" \
    --sign "$approved_sha1" "$app"
codesign --verify --strict --verbose=2 "$app"

identity_dir=$(mktemp -d /tmp/grab-rabbit-live-identity.XXXXXX)
trap 'rm -rf "$identity_dir"' EXIT
details=$(codesign -dvvv "$app" 2>&1)
actual_team=$(sed -n 's/^TeamIdentifier=//p' <<<"$details" | head -1)
actual_name=$(sed -n 's/^Authority=//p' <<<"$details" | head -1)
codesign -d --extract-certificates="$identity_dir/cert-" "$app"
actual_sha1=$(openssl x509 -inform DER -in "$identity_dir/cert-0" -noout -fingerprint -sha1 \
    | cut -d= -f2 | tr -d ':')
[[ "$actual_name" == "$approved_name" ]]
[[ "$actual_team" == "$approved_team" ]]
[[ "$actual_sha1" == "$approved_sha1" ]]
[[ "$actual_sha1" != "$disallowed_prefix"* ]]

entitlements=$(codesign --display --entitlements - "$app" 2>/dev/null)
grep -Fq 'com.apple.security.device.audio-input' <<<"$entitlements"
grep -Fq 'com.apple.security.device.camera' <<<"$entitlements"
echo "signed_app=$app"
echo "signer=$actual_name|$actual_team|$actual_sha1"
