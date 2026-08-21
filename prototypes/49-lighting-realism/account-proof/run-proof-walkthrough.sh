#!/usr/bin/env bash
#
# Phase 2 of the issue #49 account-controls proof wizard: the proof walkthrough.
#
# A driving agent with desktop control runs this one command at a time. Tim is
# pulled in only on the steps flagged requires_human, which are the two sign-ins
# and nothing else. Every step is recorded before the next one is offered, so an
# interruption or a wrong entry resumes at that step and never restarts the run.
#
# Makes zero provider calls. Stores no credentials. Uploads nothing. The only
# outbound action is handing a dashboard URL to the default browser.
#
# Commands (all take --evidence-dir DIR, default /tmp/grab-rabbit-49-account-proof):
#   status                    progress, and which step is next
#   next                      the next unrecorded step, as JSON for the driver
#   show STEP_ID              one step, as JSON
#   brief STEP_ID             one step in plain sentences, for reading to Tim
#   open STEP_ID              hand that step's URL to the default browser
#   record STEP_ID --value V [--screenshot FILE] [--actual-label L] [--note N]
#                             record one step's proven value and mark it done
#   redo STEP_ID              reopen exactly that step, leaving every other step
#   compile                   write account-controls-proof.json once all steps are done

# shellcheck source=lib-account-proof.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-account-proof.sh"

command_name="${1:-status}"
shift || true

evidence_dir="$(ap_resolve_evidence_dir "$@")"
ap_require_jq
ap_assert_green "$evidence_dir"

state_file="$evidence_dir/$AP_STATE_FILE"

step_json() {
    jq -e --arg id "$1" '.steps[] | select(.id == $id)' "$AP_STEPS_FILE"
}

next_step_id() {
    jq -r --slurpfile state "$state_file" \
        '[.steps[].id] - [$state[0].steps[] | select(.status == "done") | .id] | .[0] // ""' \
        "$AP_STEPS_FILE"
}

step_status() {
    jq -r --arg id "$1" '.steps[] | select(.id == $id) | .status' "$state_file"
}

# write_state FILTER ARGS... — rewrite the state file through jq atomically.
write_state() {
    local filter="$1"; shift
    jq "$@" "$filter" "$state_file" > "$state_file.tmp"
    mv "$state_file.tmp" "$state_file"
}

total_steps="$(jq '.steps | length' "$AP_STEPS_FILE")"
done_steps="$(jq '[.steps[] | select(.status == "done")] | length' "$state_file")"

case "$command_name" in
status)
    remaining_seconds="$(jq -r --slurpfile state "$state_file" \
        '[.steps[] | select(.id as $i | ($state[0].steps[] | select(.id == $i) | .status) != "done") | .estimated_seconds] | add // 0' \
        "$AP_STEPS_FILE")"
    printf '\n  %sPhase 2 — account-controls proof walkthrough%s\n\n' "$AP_BOLD" "$AP_RESET"
    ap_say "$done_steps of $total_steps steps recorded, about $(( (remaining_seconds + 59) / 60 )) minutes of work left"
    jq -r --slurpfile manifest "$AP_STEPS_FILE" \
        '.steps[] | . as $s | ($manifest[0].steps[] | select(.id == $s.id)) as $m
         | "  " + (if $s.status == "done" then "[done]   " else "[pending]" end) + " " + $s.id
           + (if $m.requires_human then "  (Tim types a credential here)" else "" end)' \
        "$state_file"
    next_id="$(next_step_id)"
    printf '\n'
    if [[ -n "$next_id" ]]; then
        ap_note "next: ./run-proof-walkthrough.sh next --evidence-dir $evidence_dir"
    else
        ap_note "every step is recorded: ./run-proof-walkthrough.sh compile --evidence-dir $evidence_dir"
    fi
    ;;

next)
    next_id="$(next_step_id)"
    [[ -n "$next_id" ]] || { jq -n '{done: true, message: "every step is recorded; run compile"}'; exit 0; }
    step_json "$next_id" | jq --argjson index "$((done_steps + 1))" --argjson total "$total_steps" \
        '. + {step_number: $index, step_total: $total}'
    ;;

show)
    step_json "${1:?show needs a step id}" || ap_die "no step with id $1" 64
    ;;

brief)
    step="$(step_json "${1:?brief needs a step id}")" || ap_die "no step with id $1" 64
    printf '\n  %s%s%s\n\n' "$AP_BOLD" "$(printf '%s' "$step" | jq -r '.title')" "$AP_RESET"
    ap_say "$(printf '%s' "$step" | jq -r '.one_action')"
    printf '\n'
    if [[ "$(printf '%s' "$step" | jq -r '.requires_human')" == true ]]; then
        ap_warn 'Tim does this part. Hand him the keyboard now.'
        ap_say "What he will see: $(printf '%s' "$step" | jq -r '.human_handoff.what_tim_sees')"
        ap_say "What he types: $(printf '%s' "$step" | jq -r '.human_handoff.what_tim_types')"
    else
        ap_say "For the driving agent: $(printf '%s' "$step" | jq -r '.agent_instructions')"
    fi
    if [[ "$(printf '%s' "$step" | jq -r '.label_unverified')" == true ]]; then
        printf '\n'
        ap_warn "The on-screen label \"$(printf '%s' "$step" | jq -r '.control_label')\" has not been confirmed against a live account. Check it on screen, and pass the real one with --actual-label."
    fi
    ;;

open)
    step="$(step_json "${1:?open needs a step id}")" || ap_die "no step with id $1" 64
    url="$(printf '%s' "$step" | jq -r '.url // empty')"
    [[ -n "$url" ]] || ap_die "step $1 has no URL to open" 64
    command -v open >/dev/null 2>&1 || ap_die 'no open command on this host; open the URL by hand' 69
    # `open` exiting 0 does not prove the pane loaded — the #48 lane's finding.
    # The proof is the evidence recorded for this step, not this exit code.
    open "$url" >/dev/null 2>&1 || ap_warn "the browser did not accept the URL; open it by hand: $url"
    ap_ok "requested $url"
    ;;

record)
    step_id="${1:?record needs a step id}"; shift || true
    value=""; screenshot=""; actual_label=""; note=""
    while (( $# )); do
        case "$1" in
            --value) value="${2:-}"; shift 2 ;;
            --screenshot) screenshot="${2:-}"; shift 2 ;;
            --actual-label) actual_label="${2:-}"; shift 2 ;;
            --note) note="${2:-}"; shift 2 ;;
            --evidence-dir) shift 2 ;;
            *) ap_die "unknown option $1" 64 ;;
        esac
    done
    step="$(step_json "$step_id")" || ap_die "no step with id $step_id" 64
    [[ -n "$value" ]] || ap_die 'record needs --value; a blank proof is not a proof' 64
    expected_next="$(next_step_id)"
    if [[ -n "$expected_next" && "$expected_next" != "$step_id" && "$(step_status "$step_id")" != "done" ]]; then
        ap_die "steps run in order: $expected_next is next. Use redo to reopen a recorded step." 65
    fi
    if [[ -n "$screenshot" ]]; then
        [[ -f "$evidence_dir/screenshots/$screenshot" ]] \
            || ap_die "the screenshot $screenshot is not in $evidence_dir/screenshots — save it there first" 66
    fi
    record_key="$(printf '%s' "$step" | jq -r '.evidence.record_key')"
    jq -n \
        --arg step_id "$step_id" \
        --arg record_key "$record_key" \
        --arg value "$value" \
        --arg screenshot "$screenshot" \
        --arg manifest_label "$(printf '%s' "$step" | jq -r '.control_label // ""')" \
        --arg actual_label "$actual_label" \
        --arg note "$note" \
        --arg recorded_at "$(ap_now)" \
        --argjson label_unverified "$(printf '%s' "$step" | jq '.label_unverified')" \
        '{schema_version: 1,
          step_id: $step_id,
          record_key: $record_key,
          proven_value: $value,
          screenshot: (if $screenshot == "" then null else $screenshot end),
          label_in_manifest: (if $manifest_label == "" then null else $manifest_label end),
          label_seen_on_screen: (if $actual_label == "" then null else $actual_label end),
          label_was_unverified: $label_unverified,
          note: (if $note == "" then null else $note end),
          recorded_at: $recorded_at}' \
        > "$evidence_dir/records/$step_id.json"
    write_state '.steps |= map(if .id == $id then .status = "done" | .recorded_at = $at else . end)' \
        --arg id "$step_id" --arg at "$(ap_now)"
    ap_ok "recorded $step_id"
    remaining="$(next_step_id)"
    if [[ -n "$remaining" ]]; then
        ap_note "next: ./run-proof-walkthrough.sh next --evidence-dir $evidence_dir"
    else
        ap_note "next: ./run-proof-walkthrough.sh compile --evidence-dir $evidence_dir"
    fi
    ;;

redo)
    step_id="${1:?redo needs a step id}"
    step_json "$step_id" >/dev/null || ap_die "no step with id $step_id" 64
    rm -f "$evidence_dir/records/$step_id.json"
    write_state '.steps |= map(if .id == $id then .status = "pending" | .recorded_at = null else . end)' \
        --arg id "$step_id"
    ap_ok "reopened $step_id; every other recorded step is untouched"
    ;;

compile)
    missing="$(jq -r '[.steps[] | select(.status != "done") | .id] | join(", ")' "$state_file")"
    [[ -z "$missing" ]] || ap_die "these steps are not recorded yet: $missing" 65
    proof="$evidence_dir/account-controls-proof.json"
    jq -n \
        --slurpfile manifest "$AP_STEPS_FILE" \
        --slurpfile state "$state_file" \
        --arg compiled_at "$(ap_now)" \
        --arg evidence_dir "$evidence_dir" \
        --slurpfile records <(cat "$evidence_dir"/records/*.json) \
        '{schema_version: 1,
          gate: $manifest[0].gate,
          run_token: $state[0].run_token,
          evidence_dir: $evidence_dir,
          compiled_at: $compiled_at,
          provider_calls_made: 0,
          image_calls_made: 0,
          image_calls_still_unauthorized: 8,
          image_output_subtotal_usd_before_text: "0.38772",
          labels_still_unverified: [$records[] | select(.label_was_unverified and .label_seen_on_screen == null) | .step_id],
          controls: [$records[] | {step_id, record_key, proven_value, screenshot, label_seen_on_screen, note}]}' \
        > "$proof"
    ap_ok "wrote $proof"
    unconfirmed="$(jq -r '.labels_still_unverified | join(", ")' "$proof")"
    [[ -z "$unconfirmed" ]] || ap_warn "these steps recorded no on-screen label, so their labels stay unconfirmed: $unconfirmed"
    ap_note 'the eight-call gate stays locked; this file is proof for Tim to read, not an authorization'
    ;;

*)
    ap_die "unknown command $command_name" 64
    ;;
esac
