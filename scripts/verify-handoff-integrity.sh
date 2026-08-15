#!/bin/bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
handoff_path=$("$script_dir/resolve-main-handoff.sh")
main_checkout=$(cd "$(dirname "$handoff_path")/.." && pwd -P)

fail() {
    echo "Handoff integrity check failed: $1" >&2
    exit 1
}

if [[ ! -f "$handoff_path" || -L "$handoff_path" ]]; then
    fail "main-checkout handoff is missing or is not a regular file at $handoff_path"
fi
if ! git -C "$main_checkout" check-ignore -q --no-index -- .claude/handoff.md; then
    fail '.claude/handoff.md is not ignored'
fi
if git -C "$main_checkout" ls-files --error-unmatch -- .claude/handoff.md >/dev/null 2>&1; then
    fail '.claude/handoff.md is tracked'
fi

if grep -Eq '^(Manual-smoke artifact|Smoke artifact):' "$handoff_path" \
    || grep -Eq '/[^`[:cntrl:]]*[.]app([/`[:space:])}]|$)' "$handoff_path"; then
    fail 'handoff contains a bare .app artifact pointer; reference its manifest instead'
fi

if grep -F 'Manual-smoke manifest:' "$handoff_path" \
    | grep -Ev '^Manual-smoke manifest: /[^[:cntrl:]]+/manifest[.]json$' >/dev/null; then
    fail 'manual-smoke manifest lines must use: Manual-smoke manifest: /absolute/path/to/manifest.json'
fi

main_common_dir=$(git -C "$main_checkout" rev-parse --path-format=absolute --git-common-dir)
manifest_count=0
seen_manifests=$'\n'
while IFS= read -r line; do
    [[ "$line" == 'Manual-smoke manifest: '* ]] || continue
    manifest_path=${line#Manual-smoke manifest: }
    manifest_count=$((manifest_count + 1))

    if [[ "$seen_manifests" == *$'\n'"$manifest_path"$'\n'* ]]; then
        fail "duplicate manual-smoke manifest pointer: $manifest_path"
    fi
    seen_manifests+="$manifest_path"$'\n'

    if [[ ! -f "$manifest_path" || -L "$manifest_path" ]]; then
        fail "manifest does not exist as a regular file: $manifest_path"
    fi
    if ! jq -e . "$manifest_path" >/dev/null 2>&1; then
        fail "manifest is not valid JSON: $manifest_path"
    fi

    manifest_dir=$(cd "$(dirname "$manifest_path")" && pwd -P)
    canonical_manifest="$manifest_dir/$(basename "$manifest_path")"
    if [[ "$manifest_path" != "$canonical_manifest" ]]; then
        fail "manifest path is not canonical: $manifest_path"
    fi
    if ! lane_root=$(git -C "$manifest_dir" rev-parse --show-toplevel 2>/dev/null); then
        fail "manifest is not inside a Git worktree: $manifest_path"
    fi
    lane_root=$(cd "$lane_root" && pwd -P)
    if [[ "$manifest_path" != "$lane_root/.build/smoke/manifest.json" ]]; then
        fail "manifest is outside the lane's canonical smoke location: $manifest_path"
    fi

    lane_common_dir=$(git -C "$lane_root" rev-parse --path-format=absolute --git-common-dir)
    if [[ "$lane_common_dir" != "$main_common_dir" ]]; then
        fail "manifest references a lane from another repository: $manifest_path"
    fi

    if ! jq -e '
        (keys == [
            "artifactPath", "buildTime", "bundleIdentifier", "displayName",
            "gitCommit", "quarantinedArtifacts", "schemaVersion", "signing"
        ]) and
        (.schemaVersion == 1) and
        (.buildTime | type == "string" and length > 0) and
        (.displayName == "Grab Rabbit") and
        (.bundleIdentifier == "com.timharris.grabrabbit.smoke") and
        (.gitCommit | type == "string") and
        (.quarantinedArtifacts | type == "array") and
        (.signing | keys == [
            "certificateChain", "commonName", "hardenedRuntime", "nestedCode",
            "sha1Fingerprint", "strictOnDiskValidity", "teamIdentifier"
        ]) and
        (.signing.commonName == "Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)") and
        (.signing.certificateChain == [
            "Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)",
            "Developer ID Certification Authority",
            "Apple Root CA"
        ]) and
        (.signing.teamIdentifier == "F66FM4V88Q") and
        (.signing.sha1Fingerprint == "189EC9780DE0A94CF5B24CC5983CAB3FDAE15638") and
        (.signing.hardenedRuntime == true) and
        (.signing.strictOnDiskValidity == true) and
        (.signing.nestedCode == [
            "Autoupdate", "Updater.app", "Downloader.xpc", "Installer.xpc",
            "Sparkle.framework"
        ])
    ' "$manifest_path" >/dev/null; then
        fail "manifest does not carry the exact Grab Rabbit smoke identity: $manifest_path"
    fi

    lane_head=$(git -C "$lane_root" rev-parse HEAD)
    manifest_commit=$(jq -er '.gitCommit' "$manifest_path")
    if [[ "$manifest_commit" != "$lane_head" ]]; then
        fail "manifest commit $manifest_commit does not match lane HEAD $lane_head"
    fi

    artifact_path=$(jq -er '.artifactPath' "$manifest_path")
    expected_artifact="$lane_root/.build/smoke/Grab Rabbit.app"
    if [[ "$artifact_path" != "$expected_artifact" ]]; then
        fail "manifest artifact path does not match its lane: $artifact_path"
    fi
    if [[ ! -d "$artifact_path" || -L "$artifact_path" ]]; then
        fail "manifest artifact does not exist as a regular application directory: $artifact_path"
    fi
done <"$handoff_path"

echo "Handoff integrity check passed: $handoff_path ($manifest_count manifest pointer(s))"
