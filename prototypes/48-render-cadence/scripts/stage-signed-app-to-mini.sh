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
STAGING_DIR=""
LOCAL_LOCK_DIR="/tmp/grab-rabbit-48-render-cadence-stage.lock"
LOCAL_LOCK_OWNER="$LOCAL_LOCK_DIR/owner-pid"
LOCAL_LOCK_HELD=false
REMOTE_TEMP_DIR="${REMOTE_STABLE_DIR%/*}/.human-gate-staging-$expected_sha"
REMOTE_BUILD_CREATED=false
REMOTE_ROLLBACK_ARMED=false

assert_local_checkpoint() {
    local local_branch local_status local_head local_upstream live_remote_head
    local_branch=$(git -C "$REPOSITORY_ROOT" branch --show-current)
    local_status=$(git -C "$REPOSITORY_ROOT" status --porcelain)
    local_head=$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)
    local_upstream=$(git -C "$REPOSITORY_ROOT" rev-parse '@{upstream}')
    live_remote_head=$(git -C "$REPOSITORY_ROOT" ls-remote origin "refs/heads/$EXPECTED_BRANCH" | awk '{print $1}')
    [[ "$local_branch" == "$EXPECTED_BRANCH" ]] || { echo "refusing wrong local branch" >&2; return 3; }
    [[ -z "$local_status" ]] || { echo "refusing dirty local checkout" >&2; return 3; }
    [[ "$local_head" == "$expected_sha" && "$local_upstream" == "$expected_sha" \
        && "$live_remote_head" == "$expected_sha" ]] \
        || { echo "refusing SHA mismatch between expected, local, tracking, and live remote" >&2; return 3; }
    printf '%s\n' "$local_head"
}

local_lock_path_is_exact() {
    [[ "$LOCAL_LOCK_DIR" == "/tmp/grab-rabbit-48-render-cadence-stage.lock" \
        && "$LOCAL_LOCK_OWNER" == "/tmp/grab-rabbit-48-render-cadence-stage.lock/owner-pid" ]]
}

local_lock_has_exact_owner_entry() {
    local entry name count=0
    local_lock_path_is_exact || return 1
    [[ -d "$LOCAL_LOCK_DIR" && ! -L "$LOCAL_LOCK_DIR" ]] || return 1
    for entry in "$LOCAL_LOCK_DIR"/* "$LOCAL_LOCK_DIR"/.[!.]* "$LOCAL_LOCK_DIR"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        name=${entry##*/}
        [[ "$name" == "owner-pid" ]] || return 1
        count=$((count + 1))
    done
    [[ "$count" -eq 1 && -f "$LOCAL_LOCK_OWNER" && ! -L "$LOCAL_LOCK_OWNER" ]]
}

process_is_running_without_signal() {
    local pid=$1 observed="" ps_status=0
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    observed=$(ps -p "$pid" -o pid= 2>/dev/null) || ps_status=$?
    observed=$(tr -d '[:space:]' <<<"$observed")
    if [[ "$ps_status" -eq 0 && "$observed" == "$pid" ]]; then
        return 0
    fi
    [[ "$ps_status" -eq 1 && -z "$observed" ]] && return 1
    return 2
}

create_local_lock() {
    local_lock_path_is_exact || return 1
    mkdir -m 700 "$LOCAL_LOCK_DIR" 2>/dev/null || return 1
    LOCAL_LOCK_HELD=true
    if ! printf '%s\n' "$$" >"$LOCAL_LOCK_OWNER"; then
        rmdir "$LOCAL_LOCK_DIR" 2>/dev/null || true
        LOCAL_LOCK_HELD=false
        return 1
    fi
}

acquire_local_lock() {
    local owner_pid liveness_status=0
    local_lock_path_is_exact || { echo "refusing unexpected local lock path" >&2; return 10; }
    if create_local_lock; then
        return 0
    fi
    if ! local_lock_has_exact_owner_entry; then
        echo "refusing unknown, symlinked, or extra-entry local staging lock" >&2
        return 10
    fi
    owner_pid=$(<"$LOCAL_LOCK_OWNER")
    [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] \
        || { echo "refusing local staging lock with an invalid owner PID" >&2; return 10; }
    process_is_running_without_signal "$owner_pid" || liveness_status=$?
    if [[ "$liveness_status" -eq 0 ]]; then
        echo "refusing concurrent local staging helper owned by PID $owner_pid" >&2
        return 10
    elif [[ "$liveness_status" -ne 1 ]]; then
        echo "refusing local staging lock whose owner liveness could not be determined" >&2
        return 10
    fi
    rm "$LOCAL_LOCK_OWNER" \
        || { echo "refusing local staging lock that changed during stale-lock cleanup" >&2; return 10; }
    rmdir "$LOCAL_LOCK_DIR" \
        || { echo "refusing local staging lock that gained an unexpected entry" >&2; return 10; }
    create_local_lock \
        || { echo "refusing local staging lock acquired concurrently during stale-lock cleanup" >&2; return 10; }
}

release_local_lock() {
    local owner_pid
    [[ "$LOCAL_LOCK_HELD" == true ]] || return 0
    local_lock_path_is_exact \
        || { echo "refusing to clean an unexpected local lock path" >&2; return 1; }
    local_lock_has_exact_owner_entry \
        || { echo "refusing to clean an altered local staging lock" >&2; return 1; }
    owner_pid=$(<"$LOCAL_LOCK_OWNER")
    [[ "$owner_pid" == "$$" ]] \
        || { echo "refusing to clean another process's local staging lock" >&2; return 1; }
    rm "$LOCAL_LOCK_OWNER"
    rmdir "$LOCAL_LOCK_DIR"
    LOCAL_LOCK_HELD=false
}

rollback_remote_transaction() {
    [[ "$REMOTE_ROLLBACK_ARMED" == true && -n "$REMOTE_TEMP_DIR" ]] || return 0
    ssh "$REMOTE_HOST" /bin/bash -s -- \
        "$REMOTE_WORKTREE" "$REMOTE_STABLE_DIR" "$REMOTE_TEMP_DIR" \
        "$EXPECTED_BRANCH" "$expected_sha" "$REMOTE_BUILD_CREATED" <<'REMOTE_ROLLBACK'
# GRAB_RABBIT_REMOTE_ROLLBACK
set -euo pipefail
REMOTE_WORKTREE=$1
REMOTE_STABLE_DIR=$2
REMOTE_TEMP_DIR=$3
EXPECTED_BRANCH=$4
expected_sha=$5
build_created=$6
build_dir="$REMOTE_WORKTREE/prototypes/48-render-cadence/.build"

[[ "$EXPECTED_BRANCH" == "prototype/48-render-cadence" ]]
[[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]]
[[ "$(cd "$REMOTE_WORKTREE" && pwd -P)" == "$REMOTE_WORKTREE" && ! -L "$REMOTE_WORKTREE" ]]
[[ "$REMOTE_STABLE_DIR" == "$build_dir/human-gate-stable" ]]
[[ "${REMOTE_TEMP_DIR%/*}" == "$build_dir" ]]
temp_name=${REMOTE_TEMP_DIR##*/}
[[ "$temp_name" == ".human-gate-staging-$expected_sha" ]]

remove_owned_transaction_directory() {
    local directory=$1 entry name owner
    [[ -d "$directory" && ! -L "$directory" ]]
    owner="$directory/.grab-rabbit-stage-owner"
    [[ -f "$owner" && ! -L "$owner" && "$(cat "$owner")" == "$expected_sha" ]]
    for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        name=${entry##*/}
        case "$name" in
            '.grab-rabbit-stage-owner') ;;
            'Grab Rabbit Live Cadence Probe.app') ;;
            'staging-manifest.json') ;;
            '.certificate-verification') ;;
            *) echo "refusing unexpected transaction entry: $entry" >&2; return 1 ;;
        esac
    done
    rm -rf "$directory"
}

if [[ -e "$REMOTE_TEMP_DIR" || -L "$REMOTE_TEMP_DIR" ]]; then
    remove_owned_transaction_directory "$REMOTE_TEMP_DIR"
elif [[ -e "$REMOTE_STABLE_DIR/.grab-rabbit-stage-owner" ]]; then
    remove_owned_transaction_directory "$REMOTE_STABLE_DIR"
fi
if [[ "$build_created" == true && -d "$build_dir" && ! -L "$build_dir" ]]; then
    rmdir "$build_dir" 2>/dev/null || true
fi
REMOTE_ROLLBACK
}

cleanup() {
    local code=$? lock_cleanup_code=0
    trap - EXIT INT TERM
    if [[ "$code" -ne 0 ]]; then
        rollback_remote_transaction >/dev/null 2>&1 || true
    fi
    release_local_lock || lock_cleanup_code=$?
    if [[ -n "$STAGING_DIR" && "$STAGING_DIR" == /tmp/grab-rabbit-48-stage.* \
        && -d "$STAGING_DIR" ]]; then
        rm -rf "$STAGING_DIR"
    fi
    if [[ "$code" -eq 0 && "$lock_cleanup_code" -ne 0 ]]; then
        code=$lock_cleanup_code
    fi
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

initial_sha=$(assert_local_checkpoint)
[[ "$initial_sha" == "$expected_sha" ]]

STAGING_DIR=$(mktemp -d /tmp/grab-rabbit-48-stage.XXXXXX)
staged_app="$STAGING_DIR/$APP_NAME"
manifest="$STAGING_DIR/$MANIFEST_NAME"
"$SCRIPT_DIR/build-live-app.sh" --sign-approved --output "$staged_app"

post_build_sha=$(assert_local_checkpoint)
[[ "$post_build_sha" == "$initial_sha" ]]
codesign --verify --deep --strict --verbose=2 "$staged_app"

details=$(codesign -dvvv "$staged_app" 2>&1)
actual_name=$(sed -n '/^Authority=/{s///;p;q;}' <<<"$details")
actual_team=$(sed -n '/^TeamIdentifier=/{s///;p;q;}' <<<"$details")
actual_cdhash=$(sed -n 's/^CDHash=//p' <<<"$details" | tr '[:upper:]' '[:lower:]')
grep -Eq '^CodeDirectory .* flags=.*\(runtime\)' <<<"$details"
[[ "$actual_cdhash" =~ ^[0-9a-f]{40}$ ]]
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
manifest_sha=$(assert_local_checkpoint)
[[ "$manifest_sha" == "$post_build_sha" ]]
generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n \
    --arg schema "grab-rabbit-render-cadence-staged-app-v1" \
    --arg branch "$EXPECTED_BRANCH" \
    --arg git_sha "$manifest_sha" \
    --arg remote_directory "$REMOTE_STABLE_DIR" \
    --arg app_relative_path "$APP_NAME" \
    --arg info_sha256 "$info_sha256" \
    --arg executable_sha256 "$executable_sha256" \
    --arg bundle_id "$actual_bundle" \
    --arg common_name "$actual_name" \
    --arg team_id "$actual_team" \
    --arg certificate_sha1 "$actual_sha1" \
    --arg code_directory_cdhash "$actual_cdhash" \
    --arg generated_at "$generated_at" \
    '{schema:$schema,branch:$branch,git_sha:$git_sha,remote_directory:$remote_directory,
      app_relative_path:$app_relative_path,hashes:{info_plist_sha256:$info_sha256,executable_sha256:$executable_sha256},
      signing:{bundle_id:$bundle_id,common_name:$common_name,team_id:$team_id,certificate_sha1:$certificate_sha1,
        code_directory_cdhash:$code_directory_cdhash,hardened_runtime:true},
      generated_at:$generated_at,cleanup_owner:"human-gate-wizard"}' >"$manifest"

acquire_local_lock
REMOTE_ROLLBACK_ARMED=true
prepare_output="$STAGING_DIR/remote-prepare.txt"
ssh "$REMOTE_HOST" /bin/bash -s -- \
    "$REMOTE_WORKTREE" "$REMOTE_STABLE_DIR" "$REMOTE_TEMP_DIR" \
    "$EXPECTED_BRANCH" "$manifest_sha" "$info_sha256" "$actual_cdhash" >"$prepare_output" <<'REMOTE_PREPARE'
# GRAB_RABBIT_REMOTE_PREPARE
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
REMOTE_WORKTREE=$1
REMOTE_STABLE_DIR=$2
REMOTE_TEMP_DIR=$3
EXPECTED_BRANCH=$4
expected_sha=$5
fresh_info_sha256=$6
fresh_cdhash=$7
prototype_dir="$REMOTE_WORKTREE/prototypes/48-render-cadence"
build_dir="$prototype_dir/.build"
created_build=false
transaction_created=false
published_cert_dir=""

cleanup_prepare() {
    local code=$?
    trap - EXIT
    if [[ -n "$published_cert_dir" && "$published_cert_dir" == /tmp/grab-rabbit-48-published-cert.* \
        && -d "$published_cert_dir" ]]; then
        rm -rf "$published_cert_dir"
    fi
    if [[ "$code" -ne 0 ]]; then
        if [[ "$transaction_created" == true && "${REMOTE_TEMP_DIR%/*}" == "$build_dir" \
            && -f "$REMOTE_TEMP_DIR/.grab-rabbit-stage-owner" \
            && "$(cat "$REMOTE_TEMP_DIR/.grab-rabbit-stage-owner")" == "$expected_sha" ]]; then
            rm -rf "$REMOTE_TEMP_DIR"
        fi
        if [[ "$created_build" == true && -d "$build_dir" && ! -L "$build_dir" ]]; then
            rmdir "$build_dir" 2>/dev/null || true
        fi
    fi
    exit "$code"
}
trap cleanup_prepare EXIT

remove_owned_transaction_directory() {
    local directory=$1 entry name owner
    [[ -d "$directory" && ! -L "$directory" ]]
    owner="$directory/.grab-rabbit-stage-owner"
    [[ -f "$owner" && ! -L "$owner" && "$(cat "$owner")" == "$expected_sha" ]]
    for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        name=${entry##*/}
        case "$name" in
            '.grab-rabbit-stage-owner') ;;
            'Grab Rabbit Live Cadence Probe.app') ;;
            'staging-manifest.json') ;;
            '.certificate-verification') ;;
            *) echo "refusing unexpected transaction entry: $entry" >&2; return 1 ;;
        esac
    done
    rm -rf "$directory"
}

validate_published_target() {
    local app manifest info_sha256 executable_sha256 details actual_cdhash certificate_dir actual_sha1
    app="$REMOTE_STABLE_DIR/Grab Rabbit Live Cadence Probe.app"
    manifest="$REMOTE_STABLE_DIR/staging-manifest.json"
    [[ -d "$REMOTE_STABLE_DIR" && ! -L "$REMOTE_STABLE_DIR" ]] || return 1
    [[ -d "$app" && ! -L "$app" && -f "$manifest" && ! -L "$manifest" ]] || return 1
    [[ "$(find "$REMOTE_STABLE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 2 ]] || return 1
    [[ "$(find "$app" -type l | wc -l | tr -d ' ')" -eq 0 ]] || return 1
    info_sha256=$(shasum -a 256 "$app/Contents/Info.plist" | awk '{print $1}') || return 1
    executable_sha256=$(shasum -a 256 "$app/Contents/MacOS/live-cadence-probe" | awk '{print $1}') || return 1
    codesign --verify --deep --strict --verbose=2 "$app" || return 1
    details=$(codesign -dvvv "$app" 2>&1) || return 1
    actual_cdhash=$(sed -n 's/^CDHash=//p' <<<"$details" | tr '[:upper:]' '[:lower:]')
    [[ "$actual_cdhash" =~ ^[0-9a-f]{40}$ ]] || return 1
    jq -e --arg branch "$EXPECTED_BRANCH" --arg sha "$expected_sha" --arg directory "$REMOTE_STABLE_DIR" \
        --arg info "$info_sha256" --arg fresh_info "$fresh_info_sha256" \
        --arg executable "$executable_sha256" --arg cdhash "$actual_cdhash" --arg fresh_cdhash "$fresh_cdhash" '
        .schema == "grab-rabbit-render-cadence-staged-app-v1" and .branch == $branch and .git_sha == $sha
        and .remote_directory == $directory and .app_relative_path == "Grab Rabbit Live Cadence Probe.app"
        and .hashes.info_plist_sha256 == $info and $info == $fresh_info
        and .hashes.executable_sha256 == $executable
        and .signing.bundle_id == "dev.clickai.grabrabbit.prototype.render-cadence"
        and .signing.common_name == "Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)"
        and .signing.team_id == "F66FM4V88Q"
        and .signing.certificate_sha1 == "189EC9780DE0A94CF5B24CC5983CAB3FDAE15638"
        and .signing.code_directory_cdhash == $cdhash and $cdhash == $fresh_cdhash
        and .signing.hardened_runtime == true and .cleanup_owner == "human-gate-wizard"' "$manifest" >/dev/null \
        || return 1
    [[ "$(sed -n '/^Authority=/{s///;p;q;}' <<<"$details")" == "Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)" ]] \
        || return 1
    [[ "$(sed -n '/^TeamIdentifier=/{s///;p;q;}' <<<"$details")" == "F66FM4V88Q" ]] || return 1
    grep -Eq '^CodeDirectory .* flags=.*\(runtime\)' <<<"$details" || return 1
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" \
        == "dev.clickai.grabrabbit.prototype.render-cadence" ]] || return 1
    published_cert_dir=$(mktemp -d /tmp/grab-rabbit-48-published-cert.XXXXXX) || return 1
    certificate_dir=$published_cert_dir
    codesign -d --extract-certificates="$certificate_dir/cert-" "$app" || return 1
    actual_sha1=$(openssl x509 -inform DER -in "$certificate_dir/cert-0" -noout -fingerprint -sha1 \
        | cut -d= -f2 | tr -d ':') || return 1
    [[ "$actual_sha1" == "189EC9780DE0A94CF5B24CC5983CAB3FDAE15638" ]] || return 1
    rm -rf "$published_cert_dir" || return 1
    published_cert_dir=""
}

[[ "$EXPECTED_BRANCH" == "prototype/48-render-cadence" ]]
[[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]]
[[ "$fresh_info_sha256" =~ ^[0-9a-f]{64}$ ]]
[[ "$fresh_cdhash" =~ ^[0-9a-f]{40}$ ]]
[[ "$(cd "$REMOTE_WORKTREE" && pwd -P)" == "$REMOTE_WORKTREE" && ! -L "$REMOTE_WORKTREE" ]]
[[ "$(cd "$prototype_dir" && pwd -P)" == "$prototype_dir" && ! -L "$prototype_dir" ]]
[[ "$(git -C "$REMOTE_WORKTREE" branch --show-current)" == "$EXPECTED_BRANCH" ]]
[[ "$(git -C "$REMOTE_WORKTREE" rev-parse HEAD)" == "$expected_sha" ]]
[[ "$(git -C "$REMOTE_WORKTREE" rev-parse '@{upstream}')" == "$expected_sha" ]]
live_remote=$(git -C "$REMOTE_WORKTREE" ls-remote origin "refs/heads/$EXPECTED_BRANCH" | awk '{print $1}')
[[ "$live_remote" == "$expected_sha" && -z "$(git -C "$REMOTE_WORKTREE" status --porcelain)" ]]
[[ "$REMOTE_STABLE_DIR" == "$build_dir/human-gate-stable" ]]
[[ "${REMOTE_TEMP_DIR%/*}" == "$build_dir" ]]
[[ "${REMOTE_TEMP_DIR##*/}" == ".human-gate-staging-$expected_sha" ]]
if [[ -e "$REMOTE_STABLE_DIR" || -L "$REMOTE_STABLE_DIR" ]]; then
    validate_published_target || exit 9
    trap - EXIT
    printf 'already|false\n'
    exit 0
fi
if [[ ! -e "$build_dir" && ! -L "$build_dir" ]]; then
    mkdir "$build_dir"
    created_build=true
else
    [[ -d "$build_dir" && ! -L "$build_dir" && "$(cd "$build_dir" && pwd -P)" == "$build_dir" ]]
fi
if [[ -e "$REMOTE_TEMP_DIR" || -L "$REMOTE_TEMP_DIR" ]]; then
    remove_owned_transaction_directory "$REMOTE_TEMP_DIR"
fi
mkdir "$REMOTE_TEMP_DIR"
transaction_created=true
printf '%s\n' "$expected_sha" >"$REMOTE_TEMP_DIR/.grab-rabbit-stage-owner"
trap - EXIT
printf 'ready|%s\n' "$created_build"
REMOTE_PREPARE
prepare_result=$(<"$prepare_output")

prepare_state=${prepare_result%%|*}
REMOTE_BUILD_CREATED=${prepare_result#*|}
[[ "$prepare_state" == ready || "$prepare_state" == already ]]
[[ "$REMOTE_BUILD_CREATED" == true || "$REMOTE_BUILD_CREATED" == false ]]
[[ "${REMOTE_TEMP_DIR%/*}" == "${REMOTE_STABLE_DIR%/*}" ]]
remote_temp_name=${REMOTE_TEMP_DIR##*/}
[[ "$remote_temp_name" == ".human-gate-staging-$manifest_sha" ]]
if [[ "$prepare_state" == already ]]; then
    idempotent_sha=$(assert_local_checkpoint)
    [[ "$idempotent_sha" == "$manifest_sha" ]]
    REMOTE_ROLLBACK_ARMED=false
    REMOTE_TEMP_DIR=""
    printf 'already_staged_sha=%s\nremote_app=%s/%s\nremote_manifest=%s/%s\n' \
        "$idempotent_sha" "$REMOTE_STABLE_DIR" "$APP_NAME" "$REMOTE_STABLE_DIR" "$MANIFEST_NAME"
    exit 0
fi

transfer_sha=$(assert_local_checkpoint)
[[ "$transfer_sha" == "$manifest_sha" ]]
(cd "$STAGING_DIR" && tar -cf - "$MANIFEST_NAME" "$APP_NAME") \
    | ssh "$REMOTE_HOST" /usr/bin/tar -xf - -C "$REMOTE_TEMP_DIR"

ssh "$REMOTE_HOST" /bin/bash -s -- \
    "$REMOTE_WORKTREE" "$REMOTE_STABLE_DIR" "$REMOTE_TEMP_DIR" \
    "$EXPECTED_BRANCH" "$transfer_sha" "$REMOTE_BUILD_CREATED" <<'REMOTE_VERIFY_AND_PROMOTE'
# GRAB_RABBIT_REMOTE_VERIFY_AND_PROMOTE
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
REMOTE_WORKTREE=$1
REMOTE_STABLE_DIR=$2
REMOTE_TEMP_DIR=$3
EXPECTED_BRANCH=$4
expected_sha=$5
build_created=$6
APP_NAME="Grab Rabbit Live Cadence Probe.app"
MANIFEST_NAME="staging-manifest.json"
APPROVED_NAME="Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)"
APPROVED_TEAM="F66FM4V88Q"
APPROVED_SHA1="189EC9780DE0A94CF5B24CC5983CAB3FDAE15638"
BUNDLE_ID="dev.clickai.grabrabbit.prototype.render-cadence"
build_dir="$REMOTE_WORKTREE/prototypes/48-render-cadence/.build"
app="$REMOTE_TEMP_DIR/$APP_NAME"
manifest="$REMOTE_TEMP_DIR/$MANIFEST_NAME"
owner="$REMOTE_TEMP_DIR/.grab-rabbit-stage-owner"
promoted=false

remove_owned_transaction_directory() {
    local directory=$1 entry name directory_owner
    [[ -d "$directory" && ! -L "$directory" ]]
    directory_owner="$directory/.grab-rabbit-stage-owner"
    [[ -f "$directory_owner" && ! -L "$directory_owner" \
        && "$(cat "$directory_owner")" == "$expected_sha" ]]
    for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        name=${entry##*/}
        case "$name" in
            '.grab-rabbit-stage-owner'|'Grab Rabbit Live Cadence Probe.app'|'staging-manifest.json'|'.certificate-verification') ;;
            *) echo "refusing unexpected transaction entry: $entry" >&2; return 1 ;;
        esac
    done
    rm -rf "$directory"
}

rollback_verify() {
    local code=$?
    trap - EXIT
    if [[ "$code" -ne 0 ]]; then
        if [[ "$promoted" == true && -e "$REMOTE_STABLE_DIR/.grab-rabbit-stage-owner" ]]; then
            remove_owned_transaction_directory "$REMOTE_STABLE_DIR" || true
        elif [[ -e "$REMOTE_TEMP_DIR/.grab-rabbit-stage-owner" ]]; then
            remove_owned_transaction_directory "$REMOTE_TEMP_DIR" || true
        fi
        if [[ "$build_created" == true && -d "$build_dir" && ! -L "$build_dir" ]]; then
            rmdir "$build_dir" 2>/dev/null || true
        fi
    fi
    exit "$code"
}
trap rollback_verify EXIT

[[ "$EXPECTED_BRANCH" == "prototype/48-render-cadence" ]]
[[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]]
[[ "$(cd "$REMOTE_WORKTREE" && pwd -P)" == "$REMOTE_WORKTREE" && ! -L "$REMOTE_WORKTREE" ]]
[[ "$REMOTE_STABLE_DIR" == "$build_dir/human-gate-stable" ]]
[[ "${REMOTE_TEMP_DIR%/*}" == "$build_dir" ]]
temp_name=${REMOTE_TEMP_DIR##*/}
[[ "$temp_name" == ".human-gate-staging-$expected_sha" ]]
[[ -f "$owner" && ! -L "$owner" && "$(cat "$owner")" == "$expected_sha" ]]
[[ "$(git -C "$REMOTE_WORKTREE" branch --show-current)" == "$EXPECTED_BRANCH" ]]
[[ "$(git -C "$REMOTE_WORKTREE" rev-parse HEAD)" == "$expected_sha" ]]
[[ "$(git -C "$REMOTE_WORKTREE" rev-parse '@{upstream}')" == "$expected_sha" ]]
live_remote=$(git -C "$REMOTE_WORKTREE" ls-remote origin "refs/heads/$EXPECTED_BRANCH" | awk '{print $1}')
[[ "$live_remote" == "$expected_sha" && -z "$(git -C "$REMOTE_WORKTREE" status --porcelain)" ]]
[[ ! -e "$REMOTE_STABLE_DIR" && ! -L "$REMOTE_STABLE_DIR" ]]
[[ -d "$app" && ! -L "$app" && -f "$manifest" && ! -L "$manifest" ]]
[[ "$(find "$REMOTE_TEMP_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 3 ]]
[[ "$(find "$app" -type l | wc -l | tr -d ' ')" -eq 0 ]]
info_sha256=$(shasum -a 256 "$app/Contents/Info.plist" | awk '{print $1}')
executable_sha256=$(shasum -a 256 "$app/Contents/MacOS/live-cadence-probe" | awk '{print $1}')
codesign --verify --deep --strict --verbose=2 "$app"
details=$(codesign -dvvv "$app" 2>&1)
actual_cdhash=$(sed -n 's/^CDHash=//p' <<<"$details" | tr '[:upper:]' '[:lower:]')
[[ "$actual_cdhash" =~ ^[0-9a-f]{40}$ ]]
jq -e --arg branch "$EXPECTED_BRANCH" --arg sha "$expected_sha" --arg directory "$REMOTE_STABLE_DIR" \
    --arg app "$APP_NAME" --arg info "$info_sha256" --arg executable "$executable_sha256" \
    --arg bundle "$BUNDLE_ID" --arg name "$APPROVED_NAME" --arg team "$APPROVED_TEAM" \
    --arg fingerprint "$APPROVED_SHA1" --arg cdhash "$actual_cdhash" '
    .schema == "grab-rabbit-render-cadence-staged-app-v1" and .branch == $branch and .git_sha == $sha
    and .remote_directory == $directory and .app_relative_path == $app
    and .hashes.info_plist_sha256 == $info and .hashes.executable_sha256 == $executable
    and .signing.bundle_id == $bundle and .signing.common_name == $name
    and .signing.team_id == $team and .signing.certificate_sha1 == $fingerprint
    and .signing.code_directory_cdhash == $cdhash
    and .signing.hardened_runtime == true and .cleanup_owner == "human-gate-wizard"' "$manifest" >/dev/null
[[ "$(sed -n '/^Authority=/{s///;p;q;}' <<<"$details")" == "$APPROVED_NAME" ]]
[[ "$(sed -n '/^TeamIdentifier=/{s///;p;q;}' <<<"$details")" == "$APPROVED_TEAM" ]]
grep -Eq '^CodeDirectory .* flags=.*\(runtime\)' <<<"$details"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$BUNDLE_ID" ]]
certificate_dir="$REMOTE_TEMP_DIR/.certificate-verification"
[[ ! -e "$certificate_dir" && ! -L "$certificate_dir" ]]
mkdir "$certificate_dir"
codesign -d --extract-certificates="$certificate_dir/cert-" "$app"
actual_sha1=$(openssl x509 -inform DER -in "$certificate_dir/cert-0" -noout -fingerprint -sha1 \
    | cut -d= -f2 | tr -d ':')
[[ "$actual_sha1" == "$APPROVED_SHA1" ]]
find "$certificate_dir" -mindepth 1 -maxdepth 1 -type f -name 'cert-*' -delete
rmdir "$certificate_dir"
mv "$REMOTE_TEMP_DIR" "$REMOTE_STABLE_DIR"
promoted=true
rm "$REMOTE_STABLE_DIR/.grab-rabbit-stage-owner"
trap - EXIT
REMOTE_VERIFY_AND_PROMOTE

REMOTE_ROLLBACK_ARMED=false
REMOTE_TEMP_DIR=""
printf 'staged_sha=%s\nremote_app=%s/%s\nremote_manifest=%s/%s\n' \
    "$transfer_sha" "$REMOTE_STABLE_DIR" "$APP_NAME" "$REMOTE_STABLE_DIR" "$MANIFEST_NAME"
