#!/bin/bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
resolver="$repo_root/scripts/resolve-main-handoff.sh"
verifier="$repo_root/scripts/verify-handoff-integrity.sh"
temporary_root=${TMPDIR:-/tmp}
fixture_root=$(mktemp -d "${temporary_root%/}/grab-rabbit-handoff-tests.XXXXXX")
fixture_root=$(cd "$fixture_root" && pwd -P)
trap 'rm -rf "$fixture_root"' EXIT

main_checkout="$fixture_root/project"
linked_checkout="$fixture_root/linked"
mkdir -p "$main_checkout"
git -C "$main_checkout" init -q -b main
git -C "$main_checkout" config user.name 'Grab Rabbit Tests'
git -C "$main_checkout" config user.email 'tests@invalid.example'
printf '.claude/handoff.md\n.build/\n' >"$main_checkout/.gitignore"
printf 'fixture\n' >"$main_checkout/tracked.txt"
git -C "$main_checkout" add .gitignore tracked.txt
git -C "$main_checkout" commit -q -m 'Create handoff fixture'
git -C "$main_checkout" worktree add -q -b codex/fixture "$linked_checkout"

main_handoff="$main_checkout/.claude/handoff.md"
manifest="$linked_checkout/.build/smoke/manifest.json"
artifact="$linked_checkout/.build/smoke/Grab Rabbit.app"
mkdir -p "$(dirname "$main_handoff")" "$(dirname "$manifest")" "$artifact"

write_handoff() {
    local body=$1
    printf '# Handoff — fixture\n\n%s\n' "$body" >"$main_handoff"
}

write_manifest() {
    local commit=$1
    local display_name=${2:-'Grab Rabbit'}
    local strict_validity=${3:-true}

    jq -n \
        --arg artifactPath "$artifact" \
        --arg displayName "$display_name" \
        --arg gitCommit "$commit" \
        --argjson strictOnDiskValidity "$strict_validity" \
        '{
            schemaVersion: 1,
            artifactPath: $artifactPath,
            buildTime: "2026-08-14T00:00:00Z",
            displayName: $displayName,
            bundleIdentifier: "com.timharris.grabrabbit.smoke",
            gitCommit: $gitCommit,
            signing: {
                commonName: "Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)",
                certificateChain: [
                    "Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)",
                    "Developer ID Certification Authority",
                    "Apple Root CA"
                ],
                teamIdentifier: "F66FM4V88Q",
                sha1Fingerprint: "189EC9780DE0A94CF5B24CC5983CAB3FDAE15638",
                hardenedRuntime: true,
                strictOnDiskValidity: $strictOnDiskValidity,
                nestedCode: [
                    "Autoupdate",
                    "Updater.app",
                    "Downloader.xpc",
                    "Installer.xpc",
                    "Sparkle.framework"
                ]
            },
            quarantinedArtifacts: []
        }' >"$manifest"
}

expect_failure() {
    local name=$1
    local expected=$2
    shift 2

    local output
    if output=$("$@" 2>&1); then
        echo "$name unexpectedly passed" >&2
        exit 1
    fi
    if ! grep -Fq "$expected" <<<"$output"; then
        echo "$name failed without the expected diagnostic: $expected" >&2
        printf '%s\n' "$output" >&2
        exit 1
    fi
    echo "$name: rejected as expected"
}

write_handoff 'No active manual-smoke artifact.'
expected_handoff="$main_checkout/.claude/handoff.md"
main_result=$(cd "$main_checkout" && "$resolver")
[[ "$main_result" == "$expected_handoff" ]]
echo 'Main-checkout resolution: passed'

linked_result=$(cd "$linked_checkout" && "$resolver")
[[ "$linked_result" == "$expected_handoff" ]]
echo 'Linked-worktree resolution: passed'

lane_head=$(git -C "$linked_checkout" rev-parse HEAD)
write_manifest "$lane_head"
write_handoff "Manual-smoke manifest: $manifest"
(cd "$linked_checkout" && "$verifier")
echo 'Valid manifest pointer: passed'

write_handoff 'Manual-smoke artifact: QuickRecorder.app'
expect_failure 'Obsolete QuickRecorder pointer' 'bare .app artifact pointer' \
    bash -c "cd \"$linked_checkout\" && \"$verifier\""

write_handoff "Manual-smoke manifest: $fixture_root/missing/manifest.json"
expect_failure 'Missing manifest' 'manifest does not exist' \
    bash -c "cd \"$linked_checkout\" && \"$verifier\""

write_manifest '0000000000000000000000000000000000000000'
write_handoff "Manual-smoke manifest: $manifest"
expect_failure 'Manifest and HEAD mismatch' 'does not match lane HEAD' \
    bash -c "cd \"$linked_checkout\" && \"$verifier\""

write_manifest "$lane_head" 'QuickRecorder' false
expect_failure 'Invalid strict identity' 'Grab Rabbit smoke identity' \
    bash -c "cd \"$linked_checkout\" && \"$verifier\""

write_manifest "$lane_head"
rmdir "$artifact"
expect_failure 'Missing artifact' 'artifact does not exist' \
    bash -c "cd \"$linked_checkout\" && \"$verifier\""
mkdir "$artifact"

printf '# Handoff — fixture\n\nManual-smoke manifest: %s' "$manifest" >"$main_handoff"
unterminated_output=$(cd "$linked_checkout" && "$verifier")
if ! grep -Fq '(1 manifest pointer(s))' <<<"$unterminated_output"; then
    echo 'Unterminated final manifest pointer was not validated' >&2
    printf '%s\n' "$unterminated_output" >&2
    exit 1
fi
echo 'Unterminated final manifest pointer: passed'

write_handoff 'No active manual-smoke artifact.'
mkdir -p "$linked_checkout/.claude"
printf '# stale linked-worktree handoff\n' >"$linked_checkout/.claude/handoff.md"
expect_failure 'Divergent linked-worktree handoff' 'linked-worktree handoff exists' \
    bash -c "cd \"$linked_checkout\" && \"$resolver\""

echo 'Handoff integrity tests passed: 10/10'
