#!/bin/bash

set -euo pipefail

usage() {
    echo "usage: $0 EXACT_40_CHARACTER_GIT_SHA" >&2
    exit 2
}

[[ $# -eq 1 && "$1" =~ ^[0-9a-f]{40}$ ]] || usage

expected_sha=$1
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROTOTYPE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REPOSITORY_ROOT=$(cd "$PROTOTYPE_ROOT/../.." && pwd)
EXPECTED_BRANCH="prototype/48-render-cadence"
REMOTE_HOST="macmini"
REMOTE_WORKTREE="/Users/openclaw/grab-rabbit/.worktrees/48-render-cadence"
REMOTE_STABLE_DIR="$REMOTE_WORKTREE/prototypes/48-render-cadence/.build/human-gate-stable"
APP_NAME="Grab Rabbit Live Cadence Probe.app"
MANIFEST_NAME="staging-manifest.json"
APPROVED_NAME="Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)"
APPROVED_TEAM="F66FM4V88Q"
APPROVED_SHA1="189EC9780DE0A94CF5B24CC5983CAB3FDAE15638"
BUNDLE_ID="dev.clickai.grabrabbit.prototype.render-cadence"

local_branch=$(git -C "$REPOSITORY_ROOT" branch --show-current)
local_status=$(git -C "$REPOSITORY_ROOT" status --porcelain)
local_head=$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)
local_upstream=$(git -C "$REPOSITORY_ROOT" rev-parse '@{upstream}')
remote_head=$(git -C "$REPOSITORY_ROOT" ls-remote origin "refs/heads/$EXPECTED_BRANCH" | awk '{print $1}')
[[ "$local_branch" == "$EXPECTED_BRANCH" ]] || { echo "refusing wrong local branch" >&2; exit 3; }
[[ -z "$local_status" ]] || { echo "refusing dirty local checkout" >&2; exit 3; }
[[ "$local_head" == "$expected_sha" && "$local_upstream" == "$expected_sha" && "$remote_head" == "$expected_sha" ]] \
    || { echo "refusing SHA mismatch between expected, local, tracking, and remote" >&2; exit 3; }

ssh "$REMOTE_HOST" /bin/bash -s -- "$REMOTE_WORKTREE" "$REMOTE_STABLE_DIR" "$EXPECTED_BRANCH" "$expected_sha" <<'REMOTE_GUARD'
set -euo pipefail
REMOTE_WORKTREE=$1
REMOTE_STABLE_DIR=$2
EXPECTED_BRANCH=$3
expected_sha=$4
[[ "$(cd "$REMOTE_WORKTREE" && pwd -P)" == "$REMOTE_WORKTREE" ]]
[[ ! -L "$REMOTE_WORKTREE" ]]
[[ "$(git -C "$REMOTE_WORKTREE" branch --show-current)" == "$EXPECTED_BRANCH" ]]
[[ "$(git -C "$REMOTE_WORKTREE" rev-parse HEAD)" == "$expected_sha" ]]
[[ -z "$(git -C "$REMOTE_WORKTREE" status --porcelain)" ]]
[[ ! -e "$REMOTE_STABLE_DIR" && ! -L "$REMOTE_STABLE_DIR" ]]
stable_parent=${REMOTE_STABLE_DIR%/*}
[[ -d "$stable_parent" && ! -L "$stable_parent" ]]
[[ "$(cd "$stable_parent" && pwd -P)" == "$stable_parent" ]]
REMOTE_GUARD

STAGING_DIR=$(mktemp -d /tmp/grab-rabbit-48-stage.XXXXXX)
cleanup_local_stage() {
    [[ "$STAGING_DIR" == /tmp/grab-rabbit-48-stage.* && -d "$STAGING_DIR" ]] || return 0
    rm -rf "$STAGING_DIR"
}
trap cleanup_local_stage EXIT

staged_app="$STAGING_DIR/$APP_NAME"
manifest="$STAGING_DIR/$MANIFEST_NAME"
"$SCRIPT_DIR/build-live-app.sh" --sign-approved --output "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"

details=$(codesign -dvvv "$staged_app" 2>&1)
actual_name=$(sed -n 's/^Authority=//p' <<<"$details" | head -1)
actual_team=$(sed -n 's/^TeamIdentifier=//p' <<<"$details" | head -1)
grep -Eq '^CodeDirectory .* flags=.*\(runtime\)' <<<"$details"
actual_bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$staged_app/Contents/Info.plist")

identity_dir=$(mktemp -d "$STAGING_DIR/identity.XXXXXX")
codesign -d --extract-certificates="$identity_dir/cert-" "$staged_app"
actual_sha1=$(openssl x509 -inform DER -in "$identity_dir/cert-0" -noout -fingerprint -sha1 \
    | cut -d= -f2 | tr -d ':')
[[ "$actual_name" == "$APPROVED_NAME" ]]
[[ "$actual_team" == "$APPROVED_TEAM" ]]
[[ "$actual_sha1" == "$APPROVED_SHA1" ]]
[[ "$actual_bundle" == "$BUNDLE_ID" ]]

[[ "$(find "$staged_app" -type l | wc -l | tr -d ' ')" -eq 0 ]]
info_sha256=$(shasum -a 256 "$staged_app/Contents/Info.plist" | awk '{print $1}')
executable_sha256=$(shasum -a 256 "$staged_app/Contents/MacOS/live-cadence-probe" | awk '{print $1}')
generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n \
    --arg schema "grab-rabbit-render-cadence-staged-app-v1" \
    --arg branch "$EXPECTED_BRANCH" \
    --arg git_sha "$expected_sha" \
    --arg remote_directory "$REMOTE_STABLE_DIR" \
    --arg app_relative_path "$APP_NAME" \
    --arg info_sha256 "$info_sha256" \
    --arg executable_sha256 "$executable_sha256" \
    --arg bundle_id "$actual_bundle" \
    --arg common_name "$actual_name" \
    --arg team_id "$actual_team" \
    --arg certificate_sha1 "$actual_sha1" \
    --arg generated_at "$generated_at" \
    '{schema:$schema,branch:$branch,git_sha:$git_sha,remote_directory:$remote_directory,
      app_relative_path:$app_relative_path,hashes:{info_plist_sha256:$info_sha256,executable_sha256:$executable_sha256},
      signing:{bundle_id:$bundle_id,common_name:$common_name,team_id:$team_id,certificate_sha1:$certificate_sha1,hardened_runtime:true},
      generated_at:$generated_at,cleanup_owner:"human-gate-wizard"}' >"$manifest"

ssh "$REMOTE_HOST" /bin/mkdir "$REMOTE_STABLE_DIR"
(cd "$STAGING_DIR" && tar -cf - "$APP_NAME" "$MANIFEST_NAME") \
    | ssh "$REMOTE_HOST" /usr/bin/tar -xf - -C "$REMOTE_STABLE_DIR"

ssh "$REMOTE_HOST" /bin/bash -s -- \
    "$REMOTE_WORKTREE" "$REMOTE_STABLE_DIR" "$EXPECTED_BRANCH" "$expected_sha" <<'REMOTE_VERIFY'
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
REMOTE_WORKTREE=$1
REMOTE_STABLE_DIR=$2
EXPECTED_BRANCH=$3
expected_sha=$4
APP_NAME="Grab Rabbit Live Cadence Probe.app"
MANIFEST_NAME="staging-manifest.json"
APPROVED_NAME="Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)"
APPROVED_TEAM="F66FM4V88Q"
APPROVED_SHA1="189EC9780DE0A94CF5B24CC5983CAB3FDAE15638"
BUNDLE_ID="dev.clickai.grabrabbit.prototype.render-cadence"
app="$REMOTE_STABLE_DIR/$APP_NAME"
manifest="$REMOTE_STABLE_DIR/$MANIFEST_NAME"
[[ "$(git -C "$REMOTE_WORKTREE" branch --show-current)" == "$EXPECTED_BRANCH" ]]
[[ "$(git -C "$REMOTE_WORKTREE" rev-parse HEAD)" == "$expected_sha" ]]
[[ -z "$(git -C "$REMOTE_WORKTREE" status --porcelain)" ]]
[[ -d "$app" && ! -L "$app" && -f "$manifest" && ! -L "$manifest" ]]
[[ "$(find "$REMOTE_STABLE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 2 ]]
[[ "$(find "$app" -type l | wc -l | tr -d ' ')" -eq 0 ]]
info_sha256=$(shasum -a 256 "$app/Contents/Info.plist" | awk '{print $1}')
executable_sha256=$(shasum -a 256 "$app/Contents/MacOS/live-cadence-probe" | awk '{print $1}')
jq -e --arg branch "$EXPECTED_BRANCH" --arg sha "$expected_sha" --arg directory "$REMOTE_STABLE_DIR" \
    --arg app "$APP_NAME" --arg info "$info_sha256" --arg executable "$executable_sha256" \
    --arg bundle "$BUNDLE_ID" --arg name "$APPROVED_NAME" --arg team "$APPROVED_TEAM" --arg fingerprint "$APPROVED_SHA1" '
    .schema == "grab-rabbit-render-cadence-staged-app-v1" and .branch == $branch and .git_sha == $sha
    and .remote_directory == $directory and .app_relative_path == $app
    and .hashes.info_plist_sha256 == $info and .hashes.executable_sha256 == $executable
    and .signing.bundle_id == $bundle and .signing.common_name == $name
    and .signing.team_id == $team and .signing.certificate_sha1 == $fingerprint
    and .signing.hardened_runtime == true and .cleanup_owner == "human-gate-wizard"' "$manifest" >/dev/null
codesign --verify --deep --strict --verbose=2 "$app"
details=$(codesign -dvvv "$app" 2>&1)
[[ "$(sed -n 's/^Authority=//p' <<<"$details" | head -1)" == "$APPROVED_NAME" ]]
[[ "$(sed -n 's/^TeamIdentifier=//p' <<<"$details" | head -1)" == "$APPROVED_TEAM" ]]
grep -Eq '^CodeDirectory .* flags=.*\(runtime\)' <<<"$details"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$BUNDLE_ID" ]]
certificate_dir=$(mktemp -d /tmp/grab-rabbit-48-remote-cert.XXXXXX)
trap 'rm -rf "$certificate_dir"' EXIT
codesign -d --extract-certificates="$certificate_dir/cert-" "$app"
actual_sha1=$(openssl x509 -inform DER -in "$certificate_dir/cert-0" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
[[ "$actual_sha1" == "$APPROVED_SHA1" ]]
REMOTE_VERIFY

printf 'staged_sha=%s\nremote_app=%s/%s\nremote_manifest=%s/%s\n' \
    "$expected_sha" "$REMOTE_STABLE_DIR" "$APP_NAME" "$REMOTE_STABLE_DIR" "$MANIFEST_NAME"
