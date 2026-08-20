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

declare -F run_live_probe >/dev/null \
  || fail "the wizard has no LaunchServices seam for the signed probe"

completion_report="$test_root/completion.json"
if completion_report_is_successful "$completion_report"; then
  fail "a missing record completion report unexpectedly passed"
fi
printf '%s\n' '{"schema":"wrong","exit_code":0}' >"$completion_report"
if completion_report_is_successful "$completion_report"; then
  fail "a record completion report with the wrong schema unexpectedly passed"
fi
printf '%s\n' '{"schema":"grab-rabbit-live-cadence-completion-v1","exit_code":42}' >"$completion_report"
if completion_report_is_successful "$completion_report"; then
  fail "a nonzero record completion report unexpectedly passed"
fi
printf '%s\n' '{"schema":"grab-rabbit-live-cadence-completion-v1","exit_code":0}' >"$completion_report"
completion_report_is_successful "$completion_report" \
  || fail "a successful record completion report was rejected"
rg -Fq 'wizard-owned process cleanup could not prove completion' "$wizard" \
  || fail "the EXIT trap does not surface an unresolved process cleanup"

launch_log="$test_root/live-probe-open-args.txt"
WIZARD_TEST_PREFLIGHT_FAIL=false
WIZARD_TEST_SYNC_INTERRUPT=false
WIZARD_TEST_SYNC_ENUMERATION_FAIL=false
WIZARD_TEST_SYNC_MARKER="$test_root/sync-opened"
open() {
  local stdout_path="" stderr_path="" json_path="" argument
  local is_record=false is_preflight=false
  : >"$launch_log"
  while (( $# )); do
    argument=$1
    printf '%s\n' "$argument" >>"$launch_log"
    shift
    case "$argument" in
      -o) stdout_path=$1 ;;
      --stderr) stderr_path=$1 ;;
      --json) json_path=$1 ;;
      record) is_record=true ;;
      preflight) is_preflight=true ;;
    esac
  done
  if [[ "$is_record" == true ]]; then
    : >"$stdout_path"
    : >"$stderr_path"
    command sleep 2
    return 0
  fi
  if [[ "$is_preflight" == true ]]; then
    if [[ "$WIZARD_TEST_PREFLIGHT_FAIL" == true ]]; then
      printf '%s\n' '{"schema":"grab-rabbit-live-cadence-failure-v1","exitCode":23,"outputCreated":false}' \
        >"$json_path"
    else
      printf '%s\n' '{"schema":"grab-rabbit-live-cadence-preflight-v1","passed":true,"exact_camera_id_matched_in_process":true,"exact_window_id_matched_in_process":true,"output_created":false,"privacy_sentinel_pixels":0}' \
        >"$json_path"
    fi
    : >"$stdout_path"
    : >"$stderr_path"
    return 0
  fi
  printf '%s\n' '{"authorization":{"camera":"authorized","microphone":"authorized","screenCapturePreflightGranted":true}}' \
    >"$json_path"
  : >"$stderr_path"
  if [[ "$WIZARD_TEST_SYNC_INTERRUPT" == true ]]; then
    : >"$WIZARD_TEST_SYNC_MARKER"
    return 130
  fi
}
STABLE_APP="$test_root/Grab Rabbit Live Cadence Probe.app"
mkdir -p "$STABLE_APP"
run_live_probe list-sources --skip-window-query \
  || fail "the LaunchServices probe seam did not propagate success"
jq -e '.authorization.camera == "authorized"' <<<"$LIVE_PROBE_JSON" >/dev/null \
  || fail "the LaunchServices probe seam did not return the app's stdout"
expected_launch_arguments=$(printf '%s\n' \
  -n -W -g -o /dev/null --stderr /dev/null \
  "$STABLE_APP" --args list-sources --skip-window-query \
  --json /private/tmp/grab-rabbit-48-live-probe-launch.TOKEN/result.json \
  --launch-token /private/tmp/grab-rabbit-48-live-probe-launch.TOKEN)
normalized_launch_arguments=$(sed -E \
  's#/private/tmp/grab-rabbit-48-live-probe-launch\.[^/[:space:]]+#/private/tmp/grab-rabbit-48-live-probe-launch.TOKEN#' \
  "$launch_log")
[[ "$normalized_launch_arguments" == "$expected_launch_arguments" ]] \
  || fail "the signed probe was not launched through its exact app bundle with isolated output"

LIVE_PROBE="$STABLE_APP/Contents/MacOS/live-cadence-probe"
EVIDENCE_DIR="$test_root/preflight-evidence"
mkdir -p "$EVIDENCE_DIR"
CAMERA_ID=stable-camera-id
WINDOW_ID=123
WIZARD_TEST_PREFLIGHT_FAIL=true
if exact_preflight_passes_without_output; then
  fail "a failing LaunchServices preflight was accepted from the open waiter's zero exit"
fi
[[ ! -e "$EVIDENCE_DIR/preflight-must-not-exist.mov" \
    && ! -e "$EVIDENCE_DIR/preflight.json" ]] \
  || fail "a failed preflight left output that prevented a safe retry"
WIZARD_TEST_PREFLIGHT_FAIL=false
exact_preflight_passes_without_output \
  || fail "a successful machine-readable LaunchServices preflight was rejected"

record_stdout="$test_root/record.stdout"
record_stderr="$test_root/record.stderr"
record_movie="$test_root/record.mov"
record_metrics="$test_root/record.metrics.json"
record_events="$test_root/record.events.jsonl"
record_completion="$test_root/record.completion.json"
WIZARD_TEST_RECORD_PID=42424
WIZARD_TEST_PRIOR_RECORD_PID=42423
WIZARD_TEST_RECORD_PARENT_PID=1
WIZARD_TEST_RECORD_STARTED_AT='Thu Aug 20 14:00:00 2026'
WIZARD_TEST_RECORD_BASE_ARGUMENTS="$LIVE_PROBE record --candidate fixed-clock --output $record_movie --metrics $record_metrics --events $record_events --completion-json $record_completion"
WIZARD_TEST_RECORD_ARGUMENT_SUFFIX=""
WIZARD_TEST_RECORD_PS_FAIL=false
WIZARD_TEST_RECORD_VISIBLE=true
WIZARD_TEST_RECORD_DUPLICATE=false
wizard_test_record_arguments() {
  local token
  token=$(awk 'previous == "--launch-token" { print; exit } { previous = $0 }' "$launch_log")
  [[ -n "$token" ]] || return 1
  printf '%s --launch-token %s%s' \
    "$WIZARD_TEST_RECORD_BASE_ARGUMENTS" "$token" "$WIZARD_TEST_RECORD_ARGUMENT_SUFFIX"
}
ps() {
  local record_arguments
  case "$*" in
    '-ww -axo pid=,args=')
      if [[ "$WIZARD_TEST_SYNC_ENUMERATION_FAIL" == true && -e "$WIZARD_TEST_SYNC_MARKER" ]]; then
        return 17
      fi
      printf ' %s %s\n' "$WIZARD_TEST_PRIOR_RECORD_PID" "$WIZARD_TEST_RECORD_BASE_ARGUMENTS"
      if record_arguments=$(wizard_test_record_arguments); then
        printf ' %s %s\n' "$WIZARD_TEST_RECORD_PID" "$record_arguments"
        if [[ "$WIZARD_TEST_RECORD_DUPLICATE" == true ]]; then
          printf ' %s %s\n' 42425 "$record_arguments"
        fi
      fi
      [[ "$WIZARD_TEST_RECORD_PS_FAIL" == false ]]
      ;;
    "-ww -p $WIZARD_TEST_RECORD_PID -o ppid=")
      [[ "$WIZARD_TEST_RECORD_VISIBLE" == true ]] || return 1
      printf '%s\n' "$WIZARD_TEST_RECORD_PARENT_PID"
      ;;
    "-ww -p $WIZARD_TEST_RECORD_PID -o comm=")
      [[ "$WIZARD_TEST_RECORD_VISIBLE" == true ]] || return 1
      printf '%s\n' "$LIVE_PROBE"
      ;;
    "-ww -p $WIZARD_TEST_RECORD_PID -o lstart=")
      [[ "$WIZARD_TEST_RECORD_VISIBLE" == true ]] || return 1
      printf '%s\n' "$WIZARD_TEST_RECORD_STARTED_AT"
      ;;
    "-ww -p $WIZARD_TEST_RECORD_PID -o args=")
      [[ "$WIZARD_TEST_RECORD_VISIBLE" == true ]] || return 1
      wizard_test_record_arguments
      ;;
    "-ww -p 42425 -o ppid=") printf '%s\n' "$WIZARD_TEST_RECORD_PARENT_PID" ;;
    "-ww -p 42425 -o comm=") printf '%s\n' "$LIVE_PROBE" ;;
    "-ww -p 42425 -o lstart=") printf '%s\n' "$WIZARD_TEST_RECORD_STARTED_AT" ;;
    "-ww -p 42425 -o args=") wizard_test_record_arguments ;;
    *) command ps "$@" ;;
  esac
}
kill() {
  if [[ "$1" == -0 && "$2" == "$WIZARD_TEST_RECORD_PID" ]]; then
    [[ "$WIZARD_TEST_RECORD_VISIBLE" == true ]]
    return
  fi
  command kill "$@"
}
redirect_target="$test_root/redirect-target"
ln -s "$redirect_target" "$record_stdout"
if launch_live_probe_record "$record_stdout" "$record_stderr" \
    record --candidate fixed-clock \
    --output "$record_movie" --metrics "$record_metrics" --events "$record_events" \
    --completion-json "$record_completion"; then
  fail "a dangling LaunchServices stdout symlink unexpectedly passed"
fi
[[ ! -e "$redirect_target" ]] \
  || fail "LaunchServices followed a dangling stdout symlink"
rm "$record_stdout"
remove_live_probe_launch_dir "$LAST_LIVE_PROBE_LAUNCH_DIR" \
  || fail "the refused redirect launch marker was not removed"
launch_live_probe_record "$record_stdout" "$record_stderr" \
  record --candidate fixed-clock \
  --output "$record_movie" --metrics "$record_metrics" --events "$record_events" \
  --completion-json "$record_completion" \
  || fail "the background signed probe was not launched and pinned"
record_pid="$LAST_LIVE_PROBE_PID"
record_waiter_pid="$LAST_LIVE_PROBE_WAITER_PID"
[[ "$record_pid" == "$WIZARD_TEST_RECORD_PID" && "$record_pid" != "$record_waiter_pid" ]] \
  || fail "the LaunchServices waiter was mistaken for the actual signed probe"
[[ "$record_pid" != "$WIZARD_TEST_PRIOR_RECORD_PID" ]] \
  || fail "a pre-existing identical recording was mistaken for the newly launched probe"
live_probe_process_is_running "$record_pid" \
  || fail "the pinned signed-probe identity did not remain live"
WIZARD_TEST_RECORD_PS_FAIL=true
if discover_live_probe_process "${LIVE_PROBE_OWNED_ARGUMENTS[0]}"; then
  fail "partial failed process enumeration unexpectedly established uniqueness"
fi
WIZARD_TEST_RECORD_PS_FAIL=false
expected_record_launch_arguments=$(printf '%s\n' \
  -n -W -g -o /dev/null --stderr /dev/null \
  "$STABLE_APP" --args record --candidate fixed-clock \
  --output "$record_movie" --metrics "$record_metrics" --events "$record_events" \
  --completion-json "$record_completion" \
  --launch-token /private/tmp/grab-rabbit-48-record-launch.TOKEN)
normalized_record_launch_arguments=$(sed -E \
  's#/private/tmp/grab-rabbit-48-record-launch\.[^/[:space:]]+#/private/tmp/grab-rabbit-48-record-launch.TOKEN#' \
  "$launch_log")
[[ "$normalized_record_launch_arguments" == "$expected_record_launch_arguments" ]] \
  || fail "the background recording bypassed the signed app's LaunchServices identity"
WIZARD_TEST_KILL_SIGNALS=""
kill() {
  WIZARD_TEST_KILL_SIGNALS="$WIZARD_TEST_KILL_SIGNALS $1"
}
sleep() { :; }
if cleanup_live_probe_processes >/dev/null; then
  fail "cleanup accepted a signed probe that remained live after every owned signal"
fi
[[ "${#LIVE_PROBE_OWNED_PIDS[@]}" -eq 1 \
    && "$WIZARD_TEST_KILL_SIGNALS" == *'-INT'* \
    && "$WIZARD_TEST_KILL_SIGNALS" == *'-TERM'* \
    && "$WIZARD_TEST_KILL_SIGNALS" == *'-KILL'* ]] \
  || fail "cleanup forgot a still-live signed probe or skipped its escalation"
unset -f kill sleep
kill() {
  if [[ "$1" == -0 && "$2" == "$WIZARD_TEST_RECORD_PID" ]]; then
    [[ "$WIZARD_TEST_RECORD_VISIBLE" == true ]]
    return
  fi
  command kill "$@"
}
WIZARD_TEST_RECORD_ARGUMENT_SUFFIX=' --recycled'
if live_probe_process_is_running "$record_pid"; then
  fail "a changed signed-probe argument identity unexpectedly remained owned"
fi
if live_probe_process_is_stopped "$record_pid"; then
  fail "an unobservable live signed probe was mistaken for a stopped process"
fi
WIZARD_TEST_RECORD_ARGUMENT_SUFFIX=""
WIZARD_TEST_RECORD_STARTED_AT='Thu Aug 20 14:00:01 2026'
if live_probe_process_is_running "$record_pid"; then
  fail "a recycled signed-probe PID unexpectedly remained owned"
fi
wait "$record_waiter_pid" >/dev/null 2>&1 || true
untrack_owned_pid "$record_waiter_pid"
untrack_live_probe_process "$record_pid"
remove_live_probe_launch_dir "$LAST_LIVE_PROBE_LAUNCH_DIR" \
  || fail "the exact empty background launch marker was not removed"
WIZARD_TEST_RECORD_STARTED_AT='Thu Aug 20 14:00:00 2026'
WIZARD_TEST_RECORD_VISIBLE=true
pending_arguments=$(wizard_test_record_arguments)
track_pending_live_probe_launch "$pending_arguments" 52525
WIZARD_TEST_PENDING_KILL_SIGNALS=""
kill() {
  if [[ "$1" == -0 && "$2" == "$WIZARD_TEST_RECORD_PID" ]]; then
    [[ "$WIZARD_TEST_RECORD_VISIBLE" == true ]]
    return
  fi
  WIZARD_TEST_PENDING_KILL_SIGNALS="$WIZARD_TEST_PENDING_KILL_SIGNALS $1"
  WIZARD_TEST_RECORD_VISIBLE=false
}
sleep() { :; }
cleanup_live_probe_processes \
  || fail "cleanup did not recover and stop a delayed LaunchServices child"
unset -f kill sleep
[[ "${#LIVE_PROBE_PENDING_WAITER_PIDS[@]}" -eq 0 \
    && "${#LIVE_PROBE_OWNED_PIDS[@]}" -eq 0 \
    && "$WIZARD_TEST_PENDING_KILL_SIGNALS" == *'-INT'* ]] \
  || fail "a delayed LaunchServices child escaped pending-launch cleanup"

WIZARD_TEST_RECORD_VISIBLE=true
WIZARD_TEST_RECORD_DUPLICATE=true
track_pending_live_probe_launch "$(wizard_test_record_arguments)" 62626
sleep() { :; }
if cleanup_live_probe_processes >/dev/null; then
  fail "ambiguous signed-probe discovery unexpectedly passed cleanup"
fi
unset -f sleep
[[ "${#LIVE_PROBE_PENDING_WAITER_PIDS[@]}" -eq 1 ]] \
  || fail "ambiguous signed-probe cleanup forgot its exact pending identity"
LIVE_PROBE_PENDING_ARGUMENTS=()
LIVE_PROBE_PENDING_WAITER_PIDS=()
WIZARD_TEST_RECORD_DUPLICATE=false

residue_dir=$(mktemp -d /tmp/grab-rabbit-48-live-probe-launch.XXXXXX)
residue_dir=$(cd "$residue_dir" && pwd -P)
track_live_probe_launch_dir "$residue_dir" \
  || fail "the temporary residue directory was not identity-pinned"
printf '%s\n' '{"cameras":[{"uniqueID":"must-not-remain"}]}' >"$residue_dir/result.json"
remove_live_probe_launch_dir "$residue_dir" \
  || fail "owned transient source identifiers were not securely removed"
[[ ! -e "$residue_dir" ]] \
  || fail "the transient source-identifier directory remained after cleanup"

unproven_dir=$(mktemp -d /tmp/grab-rabbit-48-live-probe-launch.XXXXXX)
unproven_dir=$(cd "$unproven_dir" && pwd -P)
track_live_probe_launch_dir "$unproven_dir" \
  || fail "the unproven cleanup directory was not identity-pinned"
printf '%s\n' unexpected >"$unproven_dir/unexpected"
if cleanup_live_probe_processes >/dev/null; then
  fail "an unproven launch-directory cleanup unexpectedly passed"
fi
[[ "${#LIVE_PROBE_LAUNCH_DIRS[@]}" -eq 1 \
    && "${LIVE_PROBE_LAUNCH_DIRS[0]}" == "$unproven_dir" ]] \
  || fail "an unproven launch-directory cleanup forgot its exact ownership metadata"
rm "$unproven_dir/unexpected"
remove_live_probe_launch_dir "$unproven_dir" \
  || fail "the repaired unproven cleanup directory was not removed"

WIZARD_TEST_SYNC_INTERRUPT=true
WIZARD_TEST_SYNC_ENUMERATION_FAIL=true
if run_live_probe list-sources --skip-window-query; then
  fail "an interrupted synchronous LaunchServices probe unexpectedly passed"
fi
[[ "${#LIVE_PROBE_PENDING_WAITER_PIDS[@]}" -eq 1 ]] \
  || fail "an interrupted synchronous launch forgot its pending process identity"
WIZARD_TEST_SYNC_INTERRUPT=false
WIZARD_TEST_SYNC_ENUMERATION_FAIL=false
LIVE_PROBE_PENDING_ARGUMENTS=()
LIVE_PROBE_PENDING_WAITER_PIDS=()
sync_launch_index=$((${#LIVE_PROBE_LAUNCH_DIRS[@]} - 1))
sync_launch_dir="${LIVE_PROBE_LAUNCH_DIRS[$sync_launch_index]}"
remove_live_probe_launch_dir "$sync_launch_dir" \
  || fail "the interrupted synchronous launch residue was not removed"

: >"$WIZARD_TEST_SYNC_MARKER"
WIZARD_TEST_SYNC_INTERRUPT=true
if run_live_probe list-sources --skip-window-query; then
  fail "an interrupted synchronous launch with empty enumeration unexpectedly passed"
fi
[[ "${#LIVE_PROBE_PENDING_WAITER_PIDS[@]}" -eq 1 ]] \
  || fail "an interrupted synchronous launch forgot its identity after an empty process snapshot"
WIZARD_TEST_SYNC_INTERRUPT=false
LIVE_PROBE_PENDING_ARGUMENTS=()
LIVE_PROBE_PENDING_WAITER_PIDS=()
sync_launch_index=$((${#LIVE_PROBE_LAUNCH_DIRS[@]} - 1))
sync_launch_dir="${LIVE_PROBE_LAUNCH_DIRS[$sync_launch_index]}"
remove_live_probe_launch_dir "$sync_launch_dir" \
  || fail "the interrupted empty-snapshot launch residue was not removed"

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
