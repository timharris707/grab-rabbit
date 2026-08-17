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

printf 'human-gate wizard tests passed (2/2)\n'
