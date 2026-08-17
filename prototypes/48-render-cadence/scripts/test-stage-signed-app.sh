#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROTOTYPE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
STAGER="$SCRIPT_DIR/stage-signed-app-to-mini.sh"
WIZARD="$SCRIPT_DIR/run-human-gate-wizard.sh"
EXPECTED_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
REMOTE_PREFIX="/Users/openclaw/grab-rabbit/.worktrees/48-render-cadence"
TEST_ROOT=$(mktemp -d /tmp/grab-rabbit-48-stage-tests.XXXXXX)

cleanup() {
    [[ "$TEST_ROOT" == /tmp/grab-rabbit-48-stage-tests.* && -d "$TEST_ROOT" ]] || return 0
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

write_fake_tools() {
    local case_root=$1 fake_bin="$1/fake-bin"
    mkdir -p "$fake_bin"

    cp "$STAGER" "$case_root/prototypes/48-render-cadence/scripts/stage-signed-app-to-mini.sh"
    chmod +x "$case_root/prototypes/48-render-cadence/scripts/stage-signed-app-to-mini.sh"
    cp "$PROTOTYPE_ROOT/LiveProbe-Info.plist" "$case_root/prototypes/48-render-cadence/LiveProbe-Info.plist"

    printf '%s\n' '#!/bin/bash' \
        'set -euo pipefail' \
        'case "$*" in' \
        '  *"branch --show-current"*) echo prototype/48-render-cadence ;;' \
        '  *"status --porcelain"*) [[ ! -f "$FAKE_STATE/dirty" ]] || echo dirty ;;' \
        '  *"rev-parse HEAD"*) cat "$FAKE_STATE/head" ;;' \
        '  *"rev-parse @{upstream}"*) cat "$FAKE_STATE/upstream" ;;' \
        '  *"ls-remote origin refs/heads/prototype/48-render-cadence"*) printf "%s\\trefs/heads/prototype/48-render-cadence\\n" "$(cat "$FAKE_STATE/remote")" ;;' \
        '  *) echo "unexpected fake git call: $*" >&2; exit 90 ;;' \
        'esac' >"$fake_bin/git"

    printf '%s\n' '#!/bin/bash' \
        'set -euo pipefail' \
        'if [[ "${FAKE_REMOTE_CONTEXT:-0}" == 1 && -f "$FAKE_STATE/fail-verify-once" && "$*" == *"--verify"* ]]; then rm "$FAKE_STATE/fail-verify-once"; exit 82; fi' \
        'if [[ "$*" == *"-dvvv"* ]]; then' \
        '  printf "%s\\n" "CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+1 location=embedded" "Authority=Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)" "TeamIdentifier=F66FM4V88Q" >&2' \
        'elif [[ "$*" == *"--extract-certificates="* ]]; then' \
        '  for argument in "$@"; do' \
        '    case "$argument" in --extract-certificates=*) prefix=${argument#*=}; mkdir -p "${prefix%/*}"; printf cert >"${prefix}0" ;; esac' \
        '  done' \
        'fi' >"$fake_bin/codesign"

    printf '%s\n' '#!/bin/bash' \
        'printf "%s\\n" "sha1 Fingerprint=18:9E:C9:78:0D:E0:A9:4C:F5:B2:4C:C5:98:3C:AB:3F:DA:E1:56:38"' \
        >"$fake_bin/openssl"

    printf '%s\n' '#!/bin/bash' \
        'set -euo pipefail' \
        '[[ "$1" == "--sign-approved" && "$2" == "--output" ]]' \
        'app=$3' \
        'mkdir -p "$app/Contents/MacOS"' \
        'cp "$FAKE_INFO_PLIST" "$app/Contents/Info.plist"' \
        'printf probe >"$app/Contents/MacOS/live-cadence-probe"' \
        'chmod +x "$app/Contents/MacOS/live-cadence-probe"' \
        'if [[ "${FAKE_DRIFT_AFTER_BUILD:-0}" == 1 ]]; then printf dirty >"$FAKE_STATE/dirty"; fi' \
        >"$case_root/prototypes/48-render-cadence/scripts/build-live-app.sh"
    chmod +x "$case_root/prototypes/48-render-cadence/scripts/build-live-app.sh"

    printf '%s\n' '#!/bin/bash' \
        'set -euo pipefail' \
        'host=$1; shift' \
        '[[ "$host" == macmini ]]' \
        'map_path() {' \
        '  case "$1" in' \
        '    "$FAKE_REMOTE_PREFIX"*) printf "%s%s\\n" "$FAKE_REMOTE_WORKTREE" "${1#$FAKE_REMOTE_PREFIX}" ;;' \
        '    *) printf "%s\\n" "$1" ;;' \
        '  esac' \
        '}' \
        'if [[ "$1" == /usr/bin/tar ]]; then' \
        '  destination=$(map_path "${@: -1}")' \
        '  printf "tar\\n" >>"$FAKE_EVENTS"' \
        '  if [[ -f "$FAKE_STATE/fail-tar-once" ]]; then rm "$FAKE_STATE/fail-tar-once"; exit 81; fi' \
        '  /usr/bin/tar -xf - -C "$destination"' \
        '  exit 0' \
        'fi' \
        'if [[ "$1" == /bin/bash && "$2" == -s ]]; then' \
        '  shift 3' \
        '  script=$(mktemp "$FAKE_STATE/remote-script.XXXXXX")' \
        '  while IFS= read -r line || [[ -n "$line" ]]; do printf "%s\\n" "$line"; done >"$script"' \
        '  worktree=$(map_path "$1")' \
        '  original_stable=$2' \
        '  stable=$(map_path "$2")' \
        '  shift 2' \
        '  if rg -q GRAB_RABBIT_REMOTE_PREPARE "$script"; then' \
        '    printf "prepare\\n" >>"$FAKE_EVENTS"' \
        '    output=$(PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" /bin/bash "$script" "$worktree" "$stable" "$@")' \
        '    printf "%s\\n" "${output//$FAKE_REMOTE_WORKTREE/$FAKE_REMOTE_PREFIX}"' \
        '  elif rg -q GRAB_RABBIT_REMOTE_ROLLBACK "$script"; then' \
        '    printf "rollback\\n" >>"$FAKE_EVENTS"' \
        '    remote_temp=$(map_path "$1")' \
        '    shift' \
        '    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" /bin/bash "$script" "$worktree" "$stable" "$remote_temp" "$@"' \
        '  elif rg -q GRAB_RABBIT_REMOTE_VERIFY_AND_PROMOTE "$script"; then' \
        '    printf "verify\\n" >>"$FAKE_EVENTS"' \
        '    remote_temp=$(map_path "$1")' \
        '    shift' \
        '    manifest="$remote_temp/staging-manifest.json"' \
        '    rewritten_manifest="$manifest.rewritten"' \
        '    jq --arg directory "$stable" '\''.remote_directory = $directory'\'' "$manifest" >"$rewritten_manifest"' \
        '    mv "$rewritten_manifest" "$manifest"' \
        '    rewritten="$script.rewritten"' \
        '    awk -v replacement="export PATH=\\\"$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin\\\"" '\''/^export PATH=/ { print replacement; next } { print }'\'' "$script" >"$rewritten"' \
        '    set +e' \
        '    FAKE_REMOTE_CONTEXT=1 /bin/bash "$rewritten" "$worktree" "$stable" "$remote_temp" "$@"' \
        '    verify_code=$?' \
        '    set -e' \
        '    [[ "$verify_code" -eq 0 ]] || exit "$verify_code"' \
        '    manifest="$stable/staging-manifest.json"' \
        '    rewritten_manifest="$manifest.rewritten"' \
        '    jq --arg directory "$original_stable" '\''.remote_directory = $directory'\'' "$manifest" >"$rewritten_manifest"' \
        '    mv "$rewritten_manifest" "$manifest"' \
        '    printf "promote\\n" >>"$FAKE_EVENTS"' \
        '  else' \
        '    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" /bin/bash "$script" "$worktree" "$stable" "$@"' \
        '  fi' \
        '  rm -f "$script"' \
        '  exit 0' \
        'fi' \
        'echo "unexpected fake ssh call: $*" >&2' \
        'exit 91' >"$fake_bin/ssh"

    chmod +x "$fake_bin/git" "$fake_bin/codesign" "$fake_bin/openssl" "$fake_bin/ssh"
}

new_case() {
    local name=$1 case_root="$TEST_ROOT/$1"
    mkdir -p "$case_root/prototypes/48-render-cadence/scripts" \
        "$case_root/remote/prototypes/48-render-cadence" "$case_root/state"
    printf '%s\n' "$EXPECTED_SHA" >"$case_root/state/head"
    printf '%s\n' "$EXPECTED_SHA" >"$case_root/state/upstream"
    printf '%s\n' "$EXPECTED_SHA" >"$case_root/state/remote"
    : >"$case_root/events"
    write_fake_tools "$case_root"
    printf '%s\n' "$case_root"
}

run_stager() {
    local case_root=$1 remote_physical
    remote_physical=$(cd "$case_root/remote" && pwd -P)
    FAKE_STATE="$case_root/state" \
    FAKE_EVENTS="$case_root/events" \
    FAKE_BIN="$case_root/fake-bin" \
    FAKE_INFO_PLIST="$case_root/prototypes/48-render-cadence/LiveProbe-Info.plist" \
    FAKE_REMOTE_PREFIX="$REMOTE_PREFIX" \
    FAKE_REMOTE_WORKTREE="$remote_physical" \
    PATH="$case_root/fake-bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        "$case_root/prototypes/48-render-cadence/scripts/stage-signed-app-to-mini.sh" "$EXPECTED_SHA"
}

assert_remote_clean_after_failure() {
    local case_root=$1 build_root="$1/remote/prototypes/48-render-cadence/.build"
    [[ ! -e "$build_root/human-gate-stable" ]] || fail "failed staging left the fixed target"
    if [[ -d "$build_root" ]]; then
        [[ -z "$(find "$build_root" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
            || fail "failed staging left a transaction artifact"
    fi
}

assert_published_manifest() {
    local case_root=$1 manifest
    manifest="$case_root/remote/prototypes/48-render-cadence/.build/human-gate-stable/staging-manifest.json"
    [[ -f "$manifest" ]] || fail "staging did not publish the manifest"
    jq -e --arg sha "$EXPECTED_SHA" --arg directory "$REMOTE_PREFIX/prototypes/48-render-cadence/.build/human-gate-stable" '
        .git_sha == $sha and .remote_directory == $directory
        and .cleanup_owner == "human-gate-wizard"' "$manifest" >/dev/null \
        || fail "published manifest is not bound to the revalidated SHA and stable path"
}

test_absent_parent_startup() {
    local case_root
    case_root=$(new_case absent-parent)
    [[ ! -e "$case_root/remote/prototypes/48-render-cadence/.build" ]]
    run_stager "$case_root" >/dev/null
    assert_published_manifest "$case_root"
}

test_post_build_drift_refusal() {
    local case_root code
    case_root=$(new_case post-build-drift)
    set +e
    FAKE_DRIFT_AFTER_BUILD=1 run_stager "$case_root" >/dev/null 2>&1
    code=$?
    set -e
    [[ "$code" -ne 0 ]] || fail "post-build checkout drift was accepted"
    [[ ! -s "$case_root/events" ]] || fail "post-build drift reached remote preparation"
    assert_remote_clean_after_failure "$case_root"
}

test_transfer_rollback_and_retry() {
    local case_root code
    case_root=$(new_case transfer-rollback)
    : >"$case_root/state/fail-tar-once"
    set +e
    run_stager "$case_root" >/dev/null 2>&1
    code=$?
    set -e
    [[ "$code" -ne 0 ]] || fail "interrupted transfer reported success"
    assert_remote_clean_after_failure "$case_root"
    run_stager "$case_root" >/dev/null
    assert_published_manifest "$case_root"
}

test_verification_rollback_and_retry() {
    local case_root code
    case_root=$(new_case verification-rollback)
    : >"$case_root/state/fail-verify-once"
    set +e
    run_stager "$case_root" >/dev/null 2>&1
    code=$?
    set -e
    [[ "$code" -ne 0 ]] || fail "failed remote verification reported success"
    assert_remote_clean_after_failure "$case_root"
    run_stager "$case_root" >/dev/null
    assert_published_manifest "$case_root"
}

test_exact_stage_order() {
    local expected actual
    expected=$(printf '%s\n' \
        'Connect and verify the exact camera|10' \
        'Verify and visibly authorize the staged stable probe|15' \
        'Select one real browser window and prepare three cases|10' \
        'Run the shape, pause, and physical-disconnect matrix|35' \
        'Sample CPU, GPU, ANE, power, and thermal pressure|15' \
        "Verify evidence, restore state, and record Tim's verdict|15")
    actual=$(sed -n 's/^stage "\(.*\)" \([0-9][0-9]*\)$/\1|\2/p' "$WIZARD")
    [[ "$actual" == "$expected" ]] || fail "approved stage order or minutes changed"
    [[ "$(awk -F'|' '{ total += $2 } END { print total }' <<<"$actual")" -eq 100 ]] \
        || fail "approved stage minutes no longer total 100"
}

test_absent_parent_startup
test_post_build_drift_refusal
test_transfer_rollback_and_retry
test_verification_rollback_and_retry
test_exact_stage_order
echo "stage-signed-app tests passed (5/5)"
