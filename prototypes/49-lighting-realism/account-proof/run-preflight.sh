#!/usr/bin/env bash
#
# Phase 1 of the issue #49 account-controls proof wizard: the agent preflight.
#
# Runs every mechanical step end to end — environment checks, packet SHA
# verification, evidence staging, opening the provider dashboards — and writes a
# machine-readable green or red result. Phase 2 refuses to start unless this
# result is green, so nobody ever meets a preflight failure inside the
# walkthrough.
#
# Makes zero provider calls. Stores no credentials. Uploads nothing.
#
# Usage:
#   ./run-preflight.sh [--evidence-dir DIR] [--no-browser] [--force]
#
#   --no-browser  stage everything but do not hand any URL to a browser. This is
#                 the mode the self test uses and the mode to use when the
#                 driving agent opens panes itself.
#   --force       restage over an existing evidence directory. Without it an
#                 existing directory is left alone so an interrupted run keeps
#                 its recorded steps.

# shellcheck source=lib-account-proof.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-account-proof.sh"

evidence_dir="$(ap_resolve_evidence_dir "$@")"
open_browser=true
force=false
for argument in "$@"; do
    case "$argument" in
        --no-browser) open_browser=false ;;
        --force) force=true ;;
        --evidence-dir) ;;
        *) ;;
    esac
done

checks_json='[]'
overall=green

# record_check NAME RESULT DETAIL — append one machine-readable check outcome.
record_check() {
    local name="$1" result="$2" detail="$3"
    checks_json="$(printf '%s' "$checks_json" | jq \
        --arg name "$name" --arg result "$result" --arg detail "$detail" \
        '. + [{name: $name, result: $result, detail: $detail}]')"
    if [[ "$result" == pass ]]; then
        ap_ok "$name"
    else
        ap_bad "$name — $detail"
        overall=red
    fi
}

printf '\n  %sPhase 1 — agent preflight for the issue 49 account-controls proof%s\n\n' \
    "$AP_BOLD" "$AP_RESET"

ap_require_jq
record_check 'jq is installed' pass 'jq resolved on PATH'

if [[ -f "$AP_STEPS_FILE" && ! -L "$AP_STEPS_FILE" ]] && jq -e . "$AP_STEPS_FILE" >/dev/null 2>&1; then
    record_check 'the step manifest parses' pass "$AP_STEPS_FILE"
else
    record_check 'the step manifest parses' fail "$AP_STEPS_FILE is missing or not valid JSON"
fi

if [[ "$(jq -r '.image_calls_authorized' "$AP_STEPS_FILE" 2>/dev/null)" == "0" \
    && "$(jq -r '.provider_calls_authorized' "$AP_STEPS_FILE" 2>/dev/null)" == "0" ]]; then
    record_check 'the manifest authorizes zero provider calls' pass 'image_calls_authorized and provider_calls_authorized are both 0'
else
    record_check 'the manifest authorizes zero provider calls' fail 'the manifest does not declare zero authorized calls'
fi

if ap_no_network_self_check; then
    record_check 'no provider client lives in this wizard' pass 'no transfer tool or provider host appears in any script here'
else
    record_check 'no provider client lives in this wizard' fail 'a transfer tool or provider host appears in a script here'
fi

# The wizard composes with the existing zero-call packet, so the packet must be
# the packet the gate was written against.
packet_dir="$(cd "$ap_dir/.." && pwd)"
packet_mismatch=""
packet_verified=0
if [[ -f "$AP_PACKET_SHA_FILE" ]]; then
    while read -r expected name; do
        [[ -n "$name" ]] || continue
        actual="$(ap_sha256 "$packet_dir/$name" 2>/dev/null || true)"
        if [[ "$actual" == "$expected" ]]; then
            packet_verified=$((packet_verified + 1))
        else
            packet_mismatch="$packet_mismatch $name"
        fi
    done < "$AP_PACKET_SHA_FILE"
else
    packet_mismatch=" the checksum file itself is missing"
fi
if [[ -z "$packet_mismatch" ]]; then
    record_check 'the zero-call packet matches its recorded checksums' pass "$packet_verified files verified against $AP_PACKET_SHA_FILE"
else
    record_check 'the zero-call packet matches its recorded checksums' fail "changed since aceda5c:$packet_mismatch"
fi

if head_sha="$(git -C "$ap_dir" rev-parse HEAD 2>/dev/null)"; then
    record_check 'the worktree commit is readable' pass "$head_sha"
else
    head_sha=""
    record_check 'the worktree commit is readable' fail 'this directory is not inside a git worktree'
fi

if [[ "$open_browser" == true ]] && ! command -v open >/dev/null 2>&1; then
    record_check 'a browser opener is available' fail 'no open command; re-run with --no-browser and open the panes by hand'
else
    record_check 'a browser opener is available' pass \
        "$([[ "$open_browser" == true ]] && echo 'open resolved on PATH' || echo 'browser opening was not requested')"
fi

# Stage the evidence directory. Work already recorded there is preserved, but
# only after it is checked: a stale or hand-written state at the default path
# must never be blessed and re-dated as though this run had produced it.
staged=fresh
adopt_detail=""
if [[ -e "$evidence_dir" && "$force" == false ]]; then
    if [[ -f "$evidence_dir/$AP_STATE_FILE" && ! -L "$evidence_dir/$AP_STATE_FILE" ]]; then
        adopt_detail="$(
            set -o pipefail
            jq -e . "$evidence_dir/$AP_STATE_FILE" >/dev/null 2>&1 \
                || { echo 'the existing state file is not valid JSON'; exit 0; }
            if [[ -z "$(jq -r '.run_token // ""' "$evidence_dir/$AP_STATE_FILE")" ]]; then
                echo 'the existing state file carries no run token'; exit 0
            fi
            manifest_ids="$(jq -c '[.steps[].id]' "$AP_STEPS_FILE")"
            state_ids="$(jq -c '[.steps[].id]' "$evidence_dir/$AP_STATE_FILE")"
            if [[ "$manifest_ids" != "$state_ids" ]]; then
                echo 'the existing state describes different steps than the current manifest'; exit 0
            fi
            ap_records_are_coherent "$evidence_dir" 2>/dev/null \
                || { echo 'the existing state and its record files do not agree'; exit 0; }
        )"
        if [[ -z "$adopt_detail" ]]; then
            staged=preserved
        else
            record_check 'the evidence directory can be adopted' fail \
                "$adopt_detail — pass --force to restage $evidence_dir from scratch"
        fi
    elif [[ -d "$evidence_dir" && -z "$(find "$evidence_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        # An empty directory the caller made themselves is nothing to preserve.
        staged=fresh
    elif [[ -f "$evidence_dir/$AP_PREFLIGHT_FILE" ]]; then
        # A red run leaves its result file and nothing else. Adopting that
        # leftover is what lets a retry simply work instead of demanding --force.
        staged=restaged-after-red
    else
        record_check 'the evidence directory can be adopted' fail \
            "$evidence_dir already exists and holds neither a walkthrough state nor a phase 1 result; pass --force to restage it"
    fi
fi

# --force deletes a directory, so it only ever deletes one this wizard could
# plausibly own: an empty one, or one holding a phase 1 result.
if [[ "$force" == true && -e "$evidence_dir" ]]; then
    if [[ -f "$evidence_dir/$AP_PREFLIGHT_FILE" ]] \
        || [[ -d "$evidence_dir" && -z "$(find "$evidence_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        :
    else
        record_check 'the evidence directory is safe to restage' fail \
            "$evidence_dir holds no phase 1 result, so --force refuses to delete it; choose another --evidence-dir"
    fi
fi

run_token=""
if [[ "$overall" == green ]]; then
    if [[ "$staged" == preserved ]]; then
        run_token="$(jq -r '.run_token' "$evidence_dir/$AP_STATE_FILE")"
        ap_note "keeping the $(jq '[.steps[] | select(.status == "done")] | length' "$evidence_dir/$AP_STATE_FILE") recorded step(s) already in $evidence_dir"
    else
        rm -rf "$evidence_dir"
        mkdir -p "$evidence_dir/records" "$evidence_dir/screenshots"
        run_token="$(ap_new_run_token)"
        jq -n \
            --arg run_token "$run_token" \
            --arg started_at "$(ap_now)" \
            --slurpfile manifest "$AP_STEPS_FILE" \
            '{schema_version: 1,
              run_token: $run_token,
              started_at: $started_at,
              gate: $manifest[0].gate,
              provider_calls_made: 0,
              image_calls_made: 0,
              steps: [$manifest[0].steps[] | {id: .id, status: "pending", recorded_at: null}]}' \
            > "$evidence_dir/$AP_STATE_FILE"
    fi
    record_check 'the evidence directory is staged' pass "$evidence_dir ($staged)"
fi

# Adapted from the #48 lane: an exit code from a delayed launch proves nothing,
# so the green or red decision is written here as data and read back by phase 2,
# and it is bound to this run's token plus the directory's device and inode so a
# stale result at the same path can never be mistaken for this one.
identity="$(ap_dir_identity "$evidence_dir" 2>/dev/null || true)"
if [[ -z "$identity" && "$overall" == green ]]; then
    record_check 'the evidence directory identity is readable' fail "cannot stat $evidence_dir"
fi

opened_json='[]'
if [[ "$overall" == green && "$open_browser" == true ]]; then
    while read -r url; do
        [[ -n "$url" && "$url" != null ]] || continue
        # `open` returning 0 does not prove a pane loaded, so the attempt is
        # recorded as an attempt; the proof of a loaded pane is the evidence the
        # driving agent captures in phase 2.
        if open "$url" >/dev/null 2>&1; then attempt=requested; else attempt=refused; fi
        opened_json="$(printf '%s' "$opened_json" | jq --arg url "$url" --arg attempt "$attempt" \
            '. + [{url: $url, open_attempt: $attempt}]')"
    done < <(jq -r '[.steps[].url | select(. != null)] | unique | .[]' "$AP_STEPS_FILE")
    ap_ok "handed $(printf '%s' "$opened_json" | jq 'length') dashboard URLs to the default browser"
fi

# A red result still has to be readable, so the directory exists either way.
mkdir -p "$evidence_dir" 2>/dev/null || true

jq -n \
    --arg status "$overall" \
    --arg run_token "$run_token" \
    --arg evidence_dir "$evidence_dir" \
    --arg identity "$identity" \
    --arg head_sha "$head_sha" \
    --arg steps_sha256 "$(ap_steps_sha)" \
    --arg finished_at "$(ap_now)" \
    --arg staged "$staged" \
    --argjson checks "$checks_json" \
    --argjson opened "$opened_json" \
    '{schema_version: 1,
      phase: 1,
      status: $status,
      run_token: $run_token,
      evidence_dir: $evidence_dir,
      evidence_dir_identity: $identity,
      head_sha: $head_sha,
      steps_sha256: $steps_sha256,
      staging: $staged,
      finished_at: $finished_at,
      provider_calls_made: 0,
      image_calls_made: 0,
      checks: $checks,
      browser_panes: $opened}' \
    > "${evidence_dir}/${AP_PREFLIGHT_FILE}.tmp" 2>/dev/null \
    || { ap_bad "could not write the preflight result into $evidence_dir"; exit 1; }
mv "${evidence_dir}/${AP_PREFLIGHT_FILE}.tmp" "$evidence_dir/$AP_PREFLIGHT_FILE"

printf '\n'
if [[ "$overall" == green ]]; then
    ap_ok "phase 1 is green — result written to $evidence_dir/$AP_PREFLIGHT_FILE"
    ap_note "next: ./run-proof-walkthrough.sh next --evidence-dir $evidence_dir"
    exit 0
fi
ap_bad "phase 1 is red — phase 2 will refuse to start until every check above passes"
exit 1
