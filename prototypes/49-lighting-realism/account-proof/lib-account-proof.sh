#!/usr/bin/env bash
#
# Shared helpers for the issue #49 account-controls proof wizard.
#
# This library and both scripts that source it make zero provider calls, store
# no credentials, and upload nothing. The only outbound action anywhere in this
# directory is handing a dashboard URL to the default browser.

set -euo pipefail

readonly AP_DEFAULT_EVIDENCE_DIR="/tmp/grab-rabbit-49-account-proof"
readonly AP_PREFLIGHT_FILE="preflight-result.json"
readonly AP_STATE_FILE="state.json"

ap_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ap_dir
readonly AP_STEPS_FILE="$ap_dir/steps.json"
readonly AP_PACKET_SHA_FILE="$ap_dir/packet-sha256.txt"

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    AP_BOLD=$(tput bold); AP_DIM=$(tput dim); AP_RESET=$(tput sgr0)
    AP_GREEN=$(tput setaf 2); AP_YELLOW=$(tput setaf 3); AP_RED=$(tput setaf 1)
else
    AP_BOLD=""; AP_DIM=""; AP_RESET=""; AP_GREEN=""; AP_YELLOW=""; AP_RED=""
fi

ap_say()  { printf '  %s\n' "$1"; }
ap_note() { printf '  %s%s%s\n' "$AP_DIM" "$1" "$AP_RESET"; }
ap_ok()   { printf '  %s[ok]%s %s\n' "$AP_GREEN" "$AP_RESET" "$1"; }
ap_warn() { printf '  %s[warn]%s %s\n' "$AP_YELLOW" "$AP_RESET" "$1"; }
ap_bad()  { printf '  %s[fail]%s %s\n' "$AP_RED" "$AP_RESET" "$1"; }
ap_die()  { ap_bad "$1"; exit "${2:-1}"; }

ap_require_jq() {
    command -v jq >/dev/null 2>&1 || ap_die 'jq is required; install it before running this wizard' 69
}

# ap_dir_identity DIR — the device and inode of DIR. Adapted from the #48 lane's
# per-launch identity token: a path alone can be swapped underneath a delayed
# start, so every cross-phase binding is checked against this identity too.
ap_dir_identity() {
    stat -f '%d:%i' "$1" 2>/dev/null || stat -c '%d:%i' "$1" 2>/dev/null
}

ap_new_run_token() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        printf '%s-%s' "$(date -u '+%Y%m%dT%H%M%SZ')" "$$"
    fi
}

ap_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

ap_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

# ap_resolve_evidence_dir "$@" — read --evidence-dir from an argument list,
# falling back to the shared default. Echoes the chosen path.
#
# Values belonging to the other options are skipped, so a recorded value that
# happens to read `--evidence-dir` cannot redirect the run.
ap_resolve_evidence_dir() {
    local result="$AP_DEFAULT_EVIDENCE_DIR"
    while (( $# )); do
        case "$1" in
            --evidence-dir) result="${2:-$result}"; shift 2 || break ;;
            --value|--screenshot|--actual-label|--note) shift 2 || break ;;
            *) shift ;;
        esac
    done
    printf '%s' "$result"
}

# ap_steps_sha — the checksum of the step manifest, pinned by phase 1 into its
# result and re-checked by phase 2. A manifest edited between the phases would
# otherwise leave a recorded run describing steps that no longer exist.
ap_steps_sha() { ap_sha256 "$AP_STEPS_FILE"; }

# ap_holds_only_the_result_file DIR — true when DIR contains exactly one entry
# and that entry is the phase 1 result file. That is the shape a red run leaves
# behind, and the only shape a re-run may delete without --force. A directory
# holding anything else may hold recorded human-gate work.
ap_holds_only_the_result_file() {
    local dir="$1" entry count=0
    for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        count=$((count + 1))
        [[ "${entry##*/}" == "$AP_PREFLIGHT_FILE" && -f "$entry" && ! -L "$entry" ]] || return 1
    done
    [[ "$count" -eq 1 ]]
}

# ap_subdir_is_contained DIR NAME — true when DIR/NAME is a real directory that
# actually lives inside DIR: not a symlink, and resolving to the path it claims.
# A records/ or screenshots/ swapped for a symlink to a sibling would otherwise
# let fabricated records compile into a clean-looking proof.
ap_subdir_is_contained() {
    local dir="$1" name="$2"
    local path="$dir/$name" parent_physical physical expected
    [[ -d "$path" && ! -L "$path" ]] || return 1
    parent_physical=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
    physical=$(cd "$path" 2>/dev/null && pwd -P) || return 1
    expected="$parent_physical/$name"
    [[ "$physical" == "$expected" ]] || return 1
    [[ "$(ap_dir_identity "$path")" == "$(ap_dir_identity "$expected")" ]] || return 1
}

# ap_assert_evidence_layout DIR — both evidence subdirectories are really inside
# DIR. Checked at adoption, at record time, and at compile: a swap between any
# two of those moments is exactly the window an exploit would use.
ap_assert_evidence_layout() {
    local dir="$1" name
    for name in records screenshots; do
        ap_subdir_is_contained "$dir" "$name" \
            || ap_die "$dir/$name is not a real directory inside $dir; refusing to trust anything in it" 74
    done
}

# ap_read_preflight DIR — echo the preflight result JSON, failing when the file
# is missing, unreadable, or a symlink. Phase 2 never proceeds without it.
ap_read_preflight() {
    local file="$1/$AP_PREFLIGHT_FILE"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    cat "$file"
}

# ap_assert_green DIR — the phase-1 gate for phase 2. The status must be green,
# the run token in the preflight result must match the one recorded in the state
# file, and the evidence directory must still be the same directory that the
# preflight staged. Any mismatch is a refusal, not a warning.
ap_assert_green() {
    local dir="$1" preflight state status token state_token recorded_identity live_identity
    local pinned_steps_sha live_steps_sha
    preflight="$(ap_read_preflight "$dir")" \
        || ap_die "phase 1 has not run in $dir — run ./run-preflight.sh first" 78
    status="$(printf '%s' "$preflight" | jq -r '.status')"
    if [[ "$status" != "green" ]]; then
        ap_bad "phase 1 result is $status, so phase 2 refuses to start"
        printf '%s' "$preflight" | jq -r '.checks[] | select(.result != "pass") | "  failed check: " + .name + " — " + .detail'
        exit 78
    fi
    token="$(printf '%s' "$preflight" | jq -r '.run_token')"
    state="$dir/$AP_STATE_FILE"
    [[ -f "$state" && ! -L "$state" ]] || ap_die "the walkthrough state file is missing from $dir" 78
    state_token="$(jq -r '.run_token' "$state")"
    [[ "$token" == "$state_token" ]] \
        || ap_die 'the phase 1 result and the walkthrough state come from different runs; re-run phase 1' 78
    recorded_identity="$(printf '%s' "$preflight" | jq -r '.evidence_dir_identity')"
    live_identity="$(ap_dir_identity "$dir")"
    [[ -n "$live_identity" && "$recorded_identity" == "$live_identity" ]] \
        || ap_die 'the evidence directory is not the directory phase 1 staged; re-run phase 1' 78
    pinned_steps_sha="$(printf '%s' "$preflight" | jq -r '.steps_sha256 // ""')"
    live_steps_sha="$(ap_steps_sha)"
    [[ -n "$pinned_steps_sha" && "$pinned_steps_sha" == "$live_steps_sha" ]] \
        || ap_die 'steps.json has changed since phase 1 pinned it; re-run phase 1 to restage against the current manifest' 78
}

# ap_records_are_coherent DIR — every step the state calls done has a readable
# record, and no record exists for a step the state does not know. Both phases
# check this: phase 1 before adopting an existing directory, phase 2 before
# compiling. A record file that quietly disappeared must never read as a
# control somebody proved.
ap_records_are_coherent() {
    local dir="$1" step_id status record missing="" orphan="" file
    while IFS=$'\t' read -r step_id status; do
        [[ -n "$step_id" ]] || continue
        record="$dir/records/$step_id.json"
        if [[ "$status" == "done" ]]; then
            if [[ ! -f "$record" || -L "$record" ]] || ! jq -e . "$record" >/dev/null 2>&1; then
                missing="$missing $step_id"
            fi
        elif [[ -e "$record" ]]; then
            orphan="$orphan $step_id"
        fi
    done < <(jq -r '.steps[] | [.id, .status] | @tsv' "$dir/$AP_STATE_FILE")
    for file in "$dir"/records/*.json; do
        [[ -e "$file" ]] || continue
        step_id="$(basename "$file" .json)"
        jq -e --arg id "$step_id" '[.steps[].id] | index($id)' "$dir/$AP_STATE_FILE" >/dev/null 2>&1 \
            || orphan="$orphan $step_id"
    done
    if [[ -n "$missing" || -n "$orphan" ]]; then
        [[ -z "$missing" ]] || printf 'steps recorded as done with no readable record:%s\n' "$missing" >&2
        [[ -z "$orphan" ]] || printf 'record files with no matching recorded step:%s\n' "$orphan" >&2
        return 1
    fi
}

# ap_no_network_self_check — proves this directory holds no client for any
# provider. The wizard may open a URL in a browser and nothing else.
ap_no_network_self_check() {
    local hit file pattern
    # Built from parts so this check cannot match its own source line.
    pattern="\\b(cu""rl|wg""et|n""c|nca""t|ss""h|sc""p|rsy""nc|ft""p|telne""t|api\\.openai\\.com|generativelanguage\\.googleapis\\.com)\\b|/dev/tc""p|urlli""b|reques""ts\\.(get|post)|http\\.clien""t"
    for file in "$ap_dir"/*.sh; do
        [[ "${file##*/}" == "lib-account-proof.sh" ]] && continue
        hit="$(grep -nE "$pattern" "$file" || true)"
        [[ -z "$hit" ]] || { printf '%s\n' "$hit" >&2; return 1; }
    done
}
