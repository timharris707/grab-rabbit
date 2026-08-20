#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
wizard="$script_dir/run-human-gate-wizard.sh"
test_root=$(mktemp -d /tmp/grab-rabbit-48-wizard-tests.XXXXXX)
trap 'rm -rf "$test_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

harness="$test_root/wizard-functions.sh"
awk '/^banner "Grab Rabbit render-cadence human gate"/ { exit } { print }' "$wizard" >"$harness"
# shellcheck source=/dev/null
source "$harness"
trap 'rm -rf "$test_root"' EXIT

gate_output=""
if gate_output=$(required_confirm "Continue the required test action?" <<<"n" 2>&1); then
  fail "a No response unexpectedly passed the required continuation gate"
fi
grep -Fq 'Choosing No ends this wizard run.' <<<"$gate_output" \
  || fail "the required gate did not explain the No behavior before input"
case "$gate_output" in
  *'Choosing No ends this wizard run.'*'? Continue the required test action?'*) ;;
  *) fail "the required gate warning was not printed before the input prompt" ;;
esac

if awk '/^# STAGES — author below\./ { in_stages=1 } in_stages' "$wizard" \
    | rg -n 'if ! confirm ' >"$test_root/direct-confirmations.txt"; then
  fail "a required stage gate bypasses the explicit required_confirm wording"
fi

inventory_state="$test_root/inventory-state"
printf '0\n' >"$inventory_state"
probe="$test_root/live-probe-stub"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'state_file=${WIZARD_TEST_INVENTORY_STATE:?}' \
  'state=$(<"$state_file")' \
  'if [[ "$state" == 0 ]]; then' \
  '  printf '\''1\n'\'' >"$state_file"' \
  '  printf '\''%s\n'\'' '\''{"cameras":[]}'\''' \
  'else' \
  '  printf '\''%s\n'\'' '\''{"cameras":[{"name":"Connected Camera","deviceType":"external","uniqueID":"stable-camera-id"}]}'\''' \
  'fi' >"$probe"
chmod +x "$probe"
UNSIGNED_PROBE="$probe"
WIZARD_TEST_INVENTORY_STATE="$inventory_state"
export WIZARD_TEST_INVENTORY_STATE
SOURCE_JSON='{"cameras":[]}'

if camera_count_is_positive; then
  fail "the first zero-camera inventory unexpectedly passed"
fi
camera_count_is_positive \
  || fail "the retry did not refresh AVFoundation inventory after the camera connected"
jq -e '.cameras == [{"name":"Connected Camera","deviceType":"external","uniqueID":"stable-camera-id"}]' \
  <<<"$SOURCE_JSON" >/dev/null \
  || fail "the refreshed inventory was not retained for exact camera selection"

inventory_output=$(print_camera_inventory)
grep -Fq 'Camera: Connected Camera [external]' <<<"$inventory_output" \
  || fail "the refreshed camera name and type were not shown"
grep -Fq 'Stable ID: stable-camera-id' <<<"$inventory_output" \
  || fail "the refreshed stable ID was not shown"

WIZARD_TEST_CUA_PID=12083
WIZARD_TEST_SCREEN_PID=63772
WIZARD_TEST_UID=501
WIZARD_TEST_CUA_LABEL=application.com.trycua.driver.71387198.71387204.C55B77DC-126E-4D42-B416-B4CBA387CA87
WIZARD_TEST_CUA_STATUS=0
WIZARD_TEST_CUA_START='Sat Aug 15 15:15:09 2026'
WIZARD_TEST_SCREEN_START='Thu Aug 20 07:58:47 2026'
WIZARD_TEST_CUA_PPID=1
WIZARD_TEST_SCREEN_PPID=1
WIZARD_TEST_SCREEN_PATH="$SCREENSHARINGD_PATH"
WIZARD_TEST_CUA_EXTRA_ARGUMENT=""
WIZARD_TEST_SCREEN_LSTART_SEQUENCE_FILE=""
WIZARD_TEST_DUPLICATE_CUA=false
WIZARD_TEST_LAUNCHCTL_LIST_FAIL=false
WIZARD_TEST_SCREEN_ARGS_FAIL=false
launchctl() {
  if [[ "$*" == list ]]; then
    printf '%s\t%s\t%s\n' "$WIZARD_TEST_CUA_PID" "$WIZARD_TEST_CUA_STATUS" "$WIZARD_TEST_CUA_LABEL"
    if [[ "$WIZARD_TEST_DUPLICATE_CUA" == true ]]; then
      printf '%s\t0\t%s\n' 12084 application.com.trycua.driver.duplicate
    fi
    if [[ "$WIZARD_TEST_LAUNCHCTL_LIST_FAIL" == true ]]; then
      return 1
    fi
    return 0
  fi
  if [[ "$*" == "print gui/$WIZARD_TEST_UID/$WIZARD_TEST_CUA_LABEL" ]]; then
    printf '%s\n' \
      "gui/$WIZARD_TEST_UID/$WIZARD_TEST_CUA_LABEL = {" \
      $'\tstate = running' \
      $'\tbundle id = com.trycua.driver' \
      $'\tprogram = /Applications/CuaDriver.app/Contents/MacOS/cua-driver' \
      $'\tpid = 12083' \
      '}'
    return 0
  fi
  if [[ "$*" == "print gui/$WIZARD_TEST_UID/application.com.trycua.driver.duplicate" ]]; then
    printf '%s\n' \
      "gui/$WIZARD_TEST_UID/application.com.trycua.driver.duplicate = {" \
      $'\tstate = running' \
      $'\tbundle id = com.trycua.driver' \
      $'\tprogram = /Applications/CuaDriver.app/Contents/MacOS/cua-driver' \
      $'\tpid = 12084' \
      '}'
    return 0
  fi
  if [[ "$*" == 'print system/com.apple.screensharing' ]]; then
    printf '%s\n' \
      'system/com.apple.screensharing = {' \
      $'\tstate = running' \
      $'\tprogram = /System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/MacOS/screensharingd' \
      $'\tpid = 63772' \
      '}'
    return 0
  fi
  return 1
}
ps() {
  if [[ "$*" == "-ww -p $WIZARD_TEST_CUA_PID -o ppid=" ]]; then
    printf '%s\n' "$WIZARD_TEST_CUA_PPID"
    return 0
  fi
  if [[ "$*" == "-ww -p $WIZARD_TEST_CUA_PID -o comm=" ]]; then
    printf '%s\n' "$CUA_DRIVER_PATH"
    return 0
  fi
  if [[ "$*" == "-ww -p $WIZARD_TEST_CUA_PID -o args=" ]]; then
    printf '%s serve%s\n' "$CUA_DRIVER_PATH" "$WIZARD_TEST_CUA_EXTRA_ARGUMENT"
    return 0
  fi
  if [[ "$*" == "-ww -p $WIZARD_TEST_CUA_PID -o lstart=" ]]; then
    printf '%s\n' "$WIZARD_TEST_CUA_START"
    return 0
  fi
  if [[ "$*" == "-ww -p $WIZARD_TEST_SCREEN_PID -o ppid=" ]]; then
    printf '%s\n' "$WIZARD_TEST_SCREEN_PPID"
    return 0
  fi
  if [[ "$*" == "-ww -p $WIZARD_TEST_SCREEN_PID -o comm=" ]]; then
    printf '%s\n' "$WIZARD_TEST_SCREEN_PATH"
    return 0
  fi
  if [[ "$*" == "-ww -p $WIZARD_TEST_SCREEN_PID -o args=" ]]; then
    [[ "$WIZARD_TEST_SCREEN_ARGS_FAIL" == false ]] || return 1
    printf '%s\n' "$SCREENSHARINGD_PATH"
    return 0
  fi
  if [[ "$*" == "-ww -p $WIZARD_TEST_SCREEN_PID -o lstart=" ]]; then
    if [[ -n "$WIZARD_TEST_SCREEN_LSTART_SEQUENCE_FILE" ]]; then
      sequence_state=$(<"$WIZARD_TEST_SCREEN_LSTART_SEQUENCE_FILE")
      if [[ "$sequence_state" == 0 ]]; then
        printf '1\n' >"$WIZARD_TEST_SCREEN_LSTART_SEQUENCE_FILE"
        printf '%s\n' "$WIZARD_TEST_SCREEN_START"
      else
        printf '%s\n' 'Thu Aug 20 08:58:47 2026'
      fi
      return 0
    fi
    printf '%s\n' "$WIZARD_TEST_SCREEN_START"
    return 0
  fi
  return 1
}

RUN_USER_ID="$WIZARD_TEST_UID"
CUA_DRIVER_PID=""
SCREENSHARINGD_PID=""
CUA_DRIVER_LAUNCHD_TARGET=""
CUA_DRIVER_STARTED_AT=""
SCREENSHARINGD_STARTED_AT=""
CUA_DRIVER_PARENT_PID=""
SCREENSHARINGD_PARENT_PID=""
CUA_DRIVER_ARGUMENTS=""
SCREENSHARINGD_ARGUMENTS=""
pin_protected_processes \
  || fail "the live exact-path processes were not discovered"
[[ "$CUA_DRIVER_PID" == 12083 && "$SCREENSHARINGD_PID" == 63772 ]] \
  || fail "the discovered process IDs were not retained"
[[ "$CUA_DRIVER_LAUNCHD_TARGET" == "gui/$WIZARD_TEST_UID/$WIZARD_TEST_CUA_LABEL" \
    && "$CUA_DRIVER_STARTED_AT" == "$WIZARD_TEST_CUA_START" \
    && "$SCREENSHARINGD_STARTED_AT" == "$WIZARD_TEST_SCREEN_START" ]] \
  || fail "the launchd job and immutable start times were not retained"
[[ "$CUA_DRIVER_PARENT_PID" == 1 && "$SCREENSHARINGD_PARENT_PID" == 1 ]] \
  || fail "the observed launchd parent PIDs were not retained"
[[ "$CUA_DRIVER_ARGUMENTS" == "$CUA_DRIVER_PATH serve" \
    && "$SCREENSHARINGD_ARGUMENTS" == "$SCREENSHARINGD_PATH" ]] \
  || fail "the observed role arguments were not retained"
protected_processes_are_live \
  || fail "the pinned live process identities did not pass"
WIZARD_TEST_CUA_STATUS=-9
pin_protected_processes \
  || fail "a live launchd job with a nonzero previous exit status was rejected"
WIZARD_TEST_CUA_STATUS=0
WIZARD_TEST_LAUNCHCTL_LIST_FAIL=true
if discover_cua_driver_launchd_record >/dev/null; then
  fail "a partial failed launchd enumeration was accepted as complete"
fi
WIZARD_TEST_LAUNCHCTL_LIST_FAIL=false
protected_snapshot="$test_root/protected-processes.json"
write_protected_process_snapshot "$protected_snapshot" \
  || fail "the complete two-process snapshot was not written"
jq -e \
  --arg cua_job "gui/$WIZARD_TEST_UID/$WIZARD_TEST_CUA_LABEL" \
  --arg cua_path "$CUA_DRIVER_PATH" \
  --arg screen_job "$SCREENSHARINGD_LAUNCHD_TARGET" \
  --arg screen_path "$SCREENSHARINGD_PATH" '
    .schema == "grab-rabbit-protected-process-snapshot-v1"
    and (.processes | length) == 2
    and .processes[0] == {role:"cua-driver",launchd_job:$cua_job,pid:12083,parent_pid:1,started_at:"Sat Aug 15 15:15:09 2026",executable_path:$cua_path,arguments:($cua_path + " serve")}
    and .processes[1] == {role:"screensharingd",launchd_job:$screen_job,pid:63772,parent_pid:1,started_at:"Thu Aug 20 07:58:47 2026",executable_path:$screen_path,arguments:$screen_path}
  ' "$protected_snapshot" >/dev/null \
  || fail "the protected-process snapshot did not retain the complete pinned identities"

WIZARD_TEST_SCREEN_PATH=/unexpected/screensharingd
if protected_processes_are_live; then
  fail "a pinned PID whose executable path changed unexpectedly passed"
fi
WIZARD_TEST_SCREEN_PATH="$SCREENSHARINGD_PATH"
WIZARD_TEST_SCREEN_START='Thu Aug 20 08:58:47 2026'
if protected_processes_are_live; then
  fail "a restarted process at the pinned PID unexpectedly passed"
fi
if protected_pid_is_still_protected "$WIZARD_TEST_SCREEN_PID"; then
  fail "a recycled pinned PID was still exempt from owned-process cleanup"
fi
WIZARD_TEST_SCREEN_START='Thu Aug 20 07:58:47 2026'
WIZARD_TEST_SCREEN_PPID=2
if protected_processes_are_live; then
  fail "a process whose parent changed unexpectedly passed"
fi
WIZARD_TEST_SCREEN_PPID=1
WIZARD_TEST_CUA_EXTRA_ARGUMENT=' --unexpected'
if protected_processes_are_live; then
  fail "a process whose arguments changed unexpectedly passed"
fi
WIZARD_TEST_CUA_EXTRA_ARGUMENT=""
screen_lstart_sequence="$test_root/screen-lstart-sequence"
printf '0\n' >"$screen_lstart_sequence"
WIZARD_TEST_SCREEN_LSTART_SEQUENCE_FILE="$screen_lstart_sequence"
if protected_processes_are_live; then
  fail "a PID recycled across the launchd check unexpectedly passed"
fi
WIZARD_TEST_SCREEN_LSTART_SEQUENCE_FILE=""
WIZARD_TEST_DUPLICATE_CUA=true
if protected_processes_are_live; then
  fail "later CuaDriver ambiguity unexpectedly passed"
fi
WIZARD_TEST_DUPLICATE_CUA=false
snapshot_target="$test_root/snapshot-symlink-target.json"
snapshot_symlink="$test_root/snapshot-symlink.json"
ln -s "$snapshot_target" "$snapshot_symlink"
if write_protected_process_snapshot "$snapshot_symlink"; then
  fail "a protected-process snapshot followed a dangling symlink"
fi
[[ ! -e "$snapshot_target" ]] \
  || fail "the dangling snapshot symlink target was modified"
REAL_JQ=$(command -v jq)
WIZARD_TEST_SWAP_SNAPSHOT_PARENT=false
WIZARD_TEST_SNAPSHOT_PARENT=""
WIZARD_TEST_SNAPSHOT_PARENT_MOVED=""
WIZARD_TEST_SNAPSHOT_PARENT_TARGET=""
jq() {
  if [[ "$WIZARD_TEST_SWAP_SNAPSHOT_PARENT" == true && "$1" == -n ]]; then
    mv "$WIZARD_TEST_SNAPSHOT_PARENT" "$WIZARD_TEST_SNAPSHOT_PARENT_MOVED"
    ln -s "$WIZARD_TEST_SNAPSHOT_PARENT_TARGET" "$WIZARD_TEST_SNAPSHOT_PARENT"
  fi
  "$REAL_JQ" "$@"
}
WIZARD_TEST_SNAPSHOT_PARENT="$test_root/snapshot-parent"
WIZARD_TEST_SNAPSHOT_PARENT_MOVED="$test_root/snapshot-parent-moved"
WIZARD_TEST_SNAPSHOT_PARENT_TARGET="$test_root/snapshot-parent-target"
mkdir "$WIZARD_TEST_SNAPSHOT_PARENT" "$WIZARD_TEST_SNAPSHOT_PARENT_TARGET"
WIZARD_TEST_SWAP_SNAPSHOT_PARENT=true
if write_protected_process_snapshot "$WIZARD_TEST_SNAPSHOT_PARENT/protected.json"; then
  fail "a protected-process snapshot followed a swapped parent directory"
fi
WIZARD_TEST_SWAP_SNAPSHOT_PARENT=false
[[ ! -e "$WIZARD_TEST_SNAPSHOT_PARENT_TARGET/protected.json" ]] \
  || fail "the swapped snapshot parent redirected the write"
if write_protected_process_snapshot "$protected_snapshot"; then
  fail "an existing protected-process snapshot was unexpectedly overwritten"
fi
WIZARD_TEST_SCREEN_ARGS_FAIL=true
if write_protected_process_snapshot "$test_root/incomplete-protected-processes.json"; then
  fail "an incomplete protected-process snapshot unexpectedly passed"
fi
WIZARD_TEST_SCREEN_ARGS_FAIL=false
WIZARD_TEST_DUPLICATE_CUA=true
if pin_protected_processes; then
  fail "duplicate launchd-managed CuaDriver services unexpectedly passed"
fi
WIZARD_TEST_DUPLICATE_CUA=false

REAL_MKDIR=$(command -v mkdir)
WIZARD_TEST_SWAP_EVIDENCE_ROOT=false
WIZARD_TEST_EVIDENCE_ROOT=""
WIZARD_TEST_EVIDENCE_ROOT_MOVED=""
WIZARD_TEST_EVIDENCE_ROOT_TARGET=""
mkdir() {
  local requested=${*: -1}
  if [[ "$WIZARD_TEST_SWAP_EVIDENCE_ROOT" == true \
      && ( "$requested" == "$EVIDENCE_DIR" || "$requested" == "${EVIDENCE_DIR##*/}" ) ]]; then
    mv "$WIZARD_TEST_EVIDENCE_ROOT" "$WIZARD_TEST_EVIDENCE_ROOT_MOVED"
    ln -s "$WIZARD_TEST_EVIDENCE_ROOT_TARGET" "$WIZARD_TEST_EVIDENCE_ROOT"
  fi
  "$REAL_MKDIR" "$@"
}
WIZARD_TEST_EVIDENCE_ROOT="$test_root/swapped-evidence"
WIZARD_TEST_EVIDENCE_ROOT_MOVED="$test_root/swapped-evidence-moved"
WIZARD_TEST_EVIDENCE_ROOT_TARGET="$test_root/swapped-evidence-target"
"$REAL_MKDIR" "$WIZARD_TEST_EVIDENCE_ROOT" "$WIZARD_TEST_EVIDENCE_ROOT_TARGET"
EVIDENCE_DIR="$WIZARD_TEST_EVIDENCE_ROOT/human-gate-fixed-stamp"
RUNS_DIR="$EVIDENCE_DIR/runs"
WIZARD_TEST_SWAP_EVIDENCE_ROOT=true
if create_evidence_directory; then
  fail "a swapped evidence root unexpectedly retained ownership"
fi
WIZARD_TEST_SWAP_EVIDENCE_ROOT=false
[[ ! -e "$WIZARD_TEST_EVIDENCE_ROOT_TARGET/human-gate-fixed-stamp" ]] \
  || fail "the swapped evidence root redirected the run directory"

EVIDENCE_DIR="$test_root/evidence/human-gate-fixed-stamp"
RUNS_DIR="$EVIDENCE_DIR/runs"
create_evidence_directory \
  || fail "the exclusive evidence directory was not created"
if create_evidence_directory; then
  fail "a second same-stamp evidence directory claim unexpectedly passed"
fi

printf 'human-gate wizard tests passed (3/3)\n'
