#!/bin/bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
artifact_dir="$repo_root/.build/smoke"
artifact_path="$artifact_dir/Grab Rabbit.app"
manifest_path="$artifact_dir/manifest.json"
quarantine_root="$repo_root/.build/smoke-quarantine"
legacy_smoke_dir="$repo_root/.build/manual-smoke/Build/Products/Release"
signer_common_name='Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)'
signer_intermediate='Developer ID Certification Authority'
signer_root='Apple Root CA'
signer_team_id='F66FM4V88Q'
signer_sha1='189EC9780DE0A94CF5B24CC5983CAB3FDAE15638'
bundle_identifier='com.timharris.grabrabbit.smoke'
display_name='Grab Rabbit'

mkdir -p "$repo_root/.build" "$artifact_dir" "$quarantine_root"
build_root=$(mktemp -d "$repo_root/.build/smoke-build.XXXXXX")
trap 'rm -rf "$build_root"' EXIT

quarantine_stamp=$(date -u '+%Y%m%dT%H%M%SZ')
for prior_app in "$artifact_dir"/*.app "$legacy_smoke_dir"/*.app; do
    [[ -d "$prior_app" ]] || continue
    mkdir -p "$quarantine_root/$quarantine_stamp"
    prior_name=$(basename "$prior_app")
    disabled_path="$quarantine_root/$quarantine_stamp/$prior_name.disabled"
    collision=1
    while [[ -e "$disabled_path" ]]; do
        disabled_path="$quarantine_root/$quarantine_stamp/$prior_name.$collision.disabled"
        collision=$((collision + 1))
    done
    mv "$prior_app" "$disabled_path"
done

if ! security find-identity -v -p codesigning | grep -Fq "$signer_sha1 \"$signer_common_name\""; then
    echo "Smoke build failed: approved Developer ID identity is unavailable" >&2
    exit 1
fi

installed_sha1=$(security find-certificate -a -c "$signer_common_name" -Z \
    | sed -n 's/^SHA-1 hash: //p' | head -1)
if [[ "$installed_sha1" != "$signer_sha1" ]]; then
    echo "Smoke build failed: approved certificate fingerprint is unavailable" >&2
    exit 1
fi

xcodebuild \
    -quiet \
    -project "$repo_root/QuickRecorder.xcodeproj" \
    -scheme QuickRecorder \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$build_root/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    build

built_products="$build_root/DerivedData/Build/Products/Release"
built_app="$built_products/QuickRecorder.app"
if [[ ! -d "$built_app" ]]; then
    echo "Smoke build failed: expected product not found at $built_app" >&2
    exit 1
fi

top_level_apps=$(find "$built_products" -maxdepth 1 -type d -name '*.app' -print)
top_level_count=$(grep -c . <<<"$top_level_apps")
if [[ "$top_level_count" -ne 1 || "$top_level_apps" != "$built_app" ]]; then
    echo "Smoke build failed: temporary build products contain an unexpected app" >&2
    printf '%s\n' "$top_level_apps" >&2
    exit 1
fi

ditto "$built_app" "$artifact_path"
info_plist="$artifact_path/Contents/Info.plist"
if /usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$info_plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $display_name" "$info_plist"
else
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $display_name" "$info_plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleName $display_name" "$info_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$info_plist"
actual_display_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$info_plist")
actual_bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
if [[ "$actual_display_name" != "$display_name" || "$actual_bundle_identifier" != "$bundle_identifier" ]]; then
    echo "Smoke build failed: built identity does not match Grab Rabbit smoke identity" >&2
    exit 1
fi

sparkle_root="$artifact_path/Contents/Frameworks/Sparkle.framework/Versions/Current"
autoupdate="$sparkle_root/Autoupdate"
updater="$sparkle_root/Updater.app"
downloader="$sparkle_root/XPCServices/Downloader.xpc"
installer="$sparkle_root/XPCServices/Installer.xpc"
sparkle_framework="$artifact_path/Contents/Frameworks/Sparkle.framework"
for nested_path in "$autoupdate" "$updater" "$downloader" "$installer" "$sparkle_framework"; do
    if [[ ! -e "$nested_path" ]]; then
        echo "Smoke build failed: nested code is missing at $nested_path" >&2
        exit 1
    fi
done

autoupdate_entitlements="$build_root/Autoupdate.entitlements"
plutil -create xml1 "$autoupdate_entitlements"
plutil -insert 'com\.apple\.application-identifier' -string 'org.sparkle-project.Sparkle.Autoupdate' "$autoupdate_entitlements"

codesign --force --options runtime --timestamp --sign "$signer_common_name" \
    --entitlements "$autoupdate_entitlements" "$autoupdate"
codesign --force --options runtime --timestamp --sign "$signer_common_name" "$updater"
codesign --force --options runtime --timestamp --sign "$signer_common_name" "$downloader"
codesign --force --options runtime --timestamp --sign "$signer_common_name" "$installer"
codesign --force --options runtime --timestamp --sign "$signer_common_name" "$sparkle_framework"
codesign --force --options runtime --timestamp --sign "$signer_common_name" \
    --entitlements "$repo_root/QuickRecorder/QuickRecorder.entitlements" "$artifact_path"

certificate_dir="$build_root/certificates"
entitlement_dir="$build_root/entitlements"
mkdir -p "$certificate_dir" "$entitlement_dir"

verify_signer_and_runtime() {
    signed_path=$1
    certificate_prefix=$2
    signing_details=$(codesign -dvvv "$signed_path" 2>&1)
    actual_common_name=$(sed -n 's/^Authority=//p' <<<"$signing_details" | head -1)
    actual_authority_chain=$(sed -n 's/^Authority=//p' <<<"$signing_details")
    expected_authority_chain=$(printf '%s\n%s\n%s' "$signer_common_name" "$signer_intermediate" "$signer_root")
    actual_team_id=$(sed -n 's/^TeamIdentifier=//p' <<<"$signing_details" | head -1)
    if ! grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"$signing_details"; then
        echo "Smoke build failed: Hardened Runtime is missing from $signed_path" >&2
        exit 1
    fi
    codesign -d --extract-certificates="$certificate_dir/$certificate_prefix-" "$signed_path"
    actual_sha1=$(openssl x509 -inform DER \
        -in "$certificate_dir/$certificate_prefix-0" -noout -fingerprint -sha1 \
        | cut -d= -f2 | tr -d ':')
    if [[ "$actual_common_name" != "$signer_common_name" \
        || "$actual_authority_chain" != "$expected_authority_chain" \
        || "$actual_team_id" != "$signer_team_id" \
        || "$actual_sha1" != "$signer_sha1" ]]; then
        echo "Smoke build failed: unapproved signer on $signed_path" >&2
        exit 1
    fi
    codesign --verify --strict --verbose=2 "$signed_path"
}

dump_entitlements() {
    signed_path=$1
    output_path=$2
    codesign -d --entitlements :- "$signed_path" >"$output_path" 2>/dev/null
    if [[ ! -s "$output_path" ]]; then
        plutil -create xml1 "$output_path"
    fi
    plutil -lint "$output_path" >/dev/null
}

verify_empty_entitlements() {
    signed_path=$1
    output_path=$2
    dump_entitlements "$signed_path" "$output_path"
    if [[ $(plutil -convert json -o - "$output_path" | jq 'keys | length') -ne 0 ]]; then
        echo "Smoke build failed: unexpected entitlements on $signed_path" >&2
        exit 1
    fi
}

verify_signer_and_runtime "$autoupdate" autoupdate
verify_signer_and_runtime "$updater" updater
verify_signer_and_runtime "$downloader" downloader
verify_signer_and_runtime "$installer" installer
verify_signer_and_runtime "$sparkle_framework" sparkle
verify_signer_and_runtime "$artifact_path" host

dump_entitlements "$autoupdate" "$entitlement_dir/autoupdate.plist"
if [[ $(plutil -convert json -o - "$entitlement_dir/autoupdate.plist" | jq 'keys | length') -ne 1 \
    || $(plutil -extract 'com\.apple\.application-identifier' raw "$entitlement_dir/autoupdate.plist") != 'org.sparkle-project.Sparkle.Autoupdate' ]]; then
    echo "Smoke build failed: Autoupdate entitlements differ from the approved allowlist" >&2
    exit 1
fi

verify_empty_entitlements "$updater" "$entitlement_dir/updater.plist"
verify_empty_entitlements "$downloader" "$entitlement_dir/downloader.plist"
verify_empty_entitlements "$installer" "$entitlement_dir/installer.plist"
verify_empty_entitlements "$sparkle_framework" "$entitlement_dir/sparkle.plist"

dump_entitlements "$artifact_path" "$entitlement_dir/host.plist"
if [[ $(plutil -convert json -o - "$entitlement_dir/host.plist" | jq 'keys | length') -ne 2 \
    || $(plutil -extract 'com\.apple\.security\.device\.audio-input' raw "$entitlement_dir/host.plist") != true \
    || $(plutil -extract 'com\.apple\.security\.device\.camera' raw "$entitlement_dir/host.plist") != true ]]; then
    echo "Smoke build failed: host entitlements differ from the approved allowlist" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$artifact_path"

artifact_apps=$(find "$artifact_dir" -maxdepth 1 -type d -name '*.app' -print)
artifact_count=$(grep -c . <<<"$artifact_apps")
if [[ "$artifact_count" -ne 1 || "$artifact_apps" != "$artifact_path" ]]; then
    echo "Smoke build failed: artifact directory must contain exactly one Grab Rabbit.app" >&2
    exit 1
fi

quarantined_json=$(find "$quarantine_root" -type d -name '*.app.disabled' -print 2>/dev/null \
    | sort | jq -Rsc 'split("\n") | map(select(length > 0))')
git_commit=$(git -C "$repo_root" rev-parse HEAD)
build_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
manifest_tmp="$build_root/manifest.json"
jq -n \
    --arg artifactPath "$artifact_path" \
    --arg buildTime "$build_time" \
    --arg bundleIdentifier "$bundle_identifier" \
    --arg displayName "$display_name" \
    --arg gitCommit "$git_commit" \
    --arg signerCommonName "$signer_common_name" \
    --arg signerIntermediate "$signer_intermediate" \
    --arg signerRoot "$signer_root" \
    --arg signerFingerprint "$signer_sha1" \
    --arg teamIdentifier "$signer_team_id" \
    --argjson quarantinedArtifacts "$quarantined_json" \
    '{
        schemaVersion: 1,
        artifactPath: $artifactPath,
        buildTime: $buildTime,
        displayName: $displayName,
        bundleIdentifier: $bundleIdentifier,
        gitCommit: $gitCommit,
        signing: {
            commonName: $signerCommonName,
            certificateChain: [$signerCommonName, $signerIntermediate, $signerRoot],
            teamIdentifier: $teamIdentifier,
            sha1Fingerprint: $signerFingerprint,
            hardenedRuntime: true,
            strictOnDiskValidity: true,
            nestedCode: ["Autoupdate", "Updater.app", "Downloader.xpc", "Installer.xpc", "Sparkle.framework"]
        },
        quarantinedArtifacts: $quarantinedArtifacts
    }' >"$manifest_tmp"
mv "$manifest_tmp" "$manifest_path"

echo "Grab Rabbit smoke artifact: $artifact_path"
echo "Grab Rabbit smoke manifest: $manifest_path"
