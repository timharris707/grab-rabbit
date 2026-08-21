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
#                             record one step's proven value and mark it done.
#                             The two sign-in steps take only the literal words
#                             signed-in or not-signed-in, so no credential has a
#                             field to be typed into. A screenshot must be a
#                             plain filename already saved in DIR/screenshots.
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
    if [[ -z "$next_id" ]]; then
        jq -n --arg dir "$evidence_dir" --arg script "$ap_dir/run-proof-walkthrough.sh" \
            '{done: true,
              message: "every step is recorded",
              compile_command: ($script + " compile --evidence-dir " + $dir)}'
        exit 0
    fi
    # The payload carries the absolute paths the driver needs, so a driver
    # working from `next` alone never has to guess where to save a capture.
    step_json "$next_id" | jq \
        --argjson index "$((done_steps + 1))" \
        --argjson total "$total_steps" \
        --arg dir "$evidence_dir" \
        --arg script "$ap_dir/run-proof-walkthrough.sh" \
        '. + {step_number: $index,
              step_total: $total,
              evidence_dir: $dir,
              screenshots_dir: ($dir + "/screenshots"),
              screenshot_save_to: (if .evidence.screenshot == null then null
                                   else $dir + "/screenshots/" + .evidence.screenshot end),
              record_command: ($script + " record " + .id + " --value \"<VALUE-REQUIRED>\" "
                               + (if .evidence.screenshot == null then ""
                                  else "--screenshot " + .evidence.screenshot + " " end)
                               + "--evidence-dir " + $dir),
              compile_command: (if .id == "walkthrough-complete"
                                then $script + " compile --evidence-dir " + $dir else null end)}'
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
    ap_assert_evidence_layout "$evidence_dir"
    step="$(step_json "$step_id")" || ap_die "no step with id $step_id" 64
    [[ -n "$value" ]] || ap_die 'record needs --value; a blank proof is not a proof' 64
    # The placeholder the next payload ships must never survive into a record.
    [[ "$value" != "<VALUE-REQUIRED>" ]] \
        || ap_die 'replace <VALUE-REQUIRED> with the value you actually read on screen' 64
    expected_next="$(next_step_id)"
    if [[ -n "$expected_next" && "$expected_next" != "$step_id" && "$(step_status "$step_id")" != "done" ]]; then
        ap_die "steps run in order: $expected_next is next. Use redo to reopen a recorded step." 65
    fi
    # A credential must not be able to reach a record. The two sign-in steps
    # take one of a fixed pair of words and nothing else, so there is no field
    # on those steps a password or a one-time code could be typed into.
    if [[ "$(printf '%s' "$step" | jq -r '.evidence.allowed_values // empty')" != "" ]]; then
        printf '%s' "$step" | jq -e --arg v "$value" '.evidence.allowed_values | index($v)' >/dev/null \
            || ap_die "step $step_id accepts only: $(printf '%s' "$step" | jq -r '.evidence.allowed_values | join(", ")'). Never pass a password, a code, or free text here." 64
    fi
    # --value on a sign-in step is already fixed to two words, so the digit guard
    # belongs on the free-text fields instead: a note or a corrected label is
    # where a careless driver would otherwise paste a password and a code, and
    # both land in the compiled proof. Sign-in page labels are button text like
    # "Sign in", so nothing legitimate there needs a run of digits.
    if [[ "$(printf '%s' "$step" | jq -r '.requires_human')" == true ]]; then
        for field in note actual_label; do
            case "$field" in
                note) field_name="note" ;;
                *) field_name="corrected label" ;;
            esac
            [[ ! "${!field}" =~ [0-9]{4,} ]] \
                || ap_die "step $step_id refuses a $field_name containing a run of four or more digits; that shape is a one-time code. Nothing on a sign-in step needs one." 64
            # The auditor's exploit string also carried a digit-free password.
            [[ ! "$(printf '%s' "${!field}" | tr '[:upper:]' '[:lower:]')" =~ (password|passcode|passphrase|one-time|otp|2fa|verification\ code) ]] \
                || ap_die "step $step_id refuses a $field_name naming a credential; record what was on screen, never what was typed" 64
        done
    fi
    if [[ -n "$screenshot" ]]; then
        # The filename is a bare name under the staged screenshots directory,
        # never a path that could climb out of it.
        [[ "$screenshot" != */* && "$screenshot" != .* ]] \
            || ap_die "the screenshot must be a plain filename saved in $evidence_dir/screenshots" 66
        [[ -f "$evidence_dir/screenshots/$screenshot" && ! -L "$evidence_dir/screenshots/$screenshot" ]] \
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
    # State first, record second. The reverse order leaves a window where an
    # interruption yields a step marked done with no record behind it — exactly
    # the shape a proof must never be built from.
    write_state '.steps |= map(if .id == $id then .status = "pending" | .recorded_at = null else . end)' \
        --arg id "$step_id"
    rm -f "$evidence_dir/records/$step_id.json"
    ap_ok "reopened $step_id; every other recorded step is untouched"
    ;;

compile)
    proof="$evidence_dir/account-controls-proof.json"
    # Any refusal below must not leave an older proof sitting there looking
    # current, so a previous one is voided up front and only restored to its
    # real name by a compile that succeeds.
    if [[ -f "$proof" ]]; then
        mv "$proof" "$evidence_dir/account-controls-proof.void.json"
        ap_warn "an earlier proof was set aside as account-controls-proof.void.json until this compile succeeds"
    fi
    ap_assert_evidence_layout "$evidence_dir"
    missing="$(jq -r '[.steps[] | select(.status != "done") | .id] | join(", ")' "$state_file")"
    [[ -z "$missing" ]] || ap_die "these steps are not recorded yet: $missing" 65
    # The state file says a step is done; only a readable record file proves
    # somebody actually looked. A proof assembled from a glob would quietly drop
    # a missing record and then read as fully confirmed, so every record is
    # named explicitly from the manifest and a gap is fatal.
    ap_records_are_coherent "$evidence_dir" \
        || ap_die 'the recorded steps and their record files do not agree, so no proof was written' 65
    record_files=()
    while read -r step_id; do
        record_file="$evidence_dir/records/$step_id.json"
        [[ -f "$record_file" && ! -L "$record_file" ]] \
            || ap_die "the record for $step_id is missing, so no proof was written" 65
        record_files+=("$record_file")
    done < <(jq -r '.steps[].id' "$AP_STEPS_FILE")
    [[ "${#record_files[@]}" -eq "$total_steps" ]] \
        || ap_die "found ${#record_files[@]} records for $total_steps steps, so no proof was written" 65

    preflight_json="$(ap_read_preflight "$evidence_dir")"
    records_json="$(jq -s '.' "${record_files[@]}")"
    # Records are read in manifest order, so the proof reads in the order the
    # controls were proven rather than in whatever order the shell globbed.
    jq -n \
        --slurpfile manifest "$AP_STEPS_FILE" \
        --slurpfile state "$state_file" \
        --argjson preflight "$preflight_json" \
        --arg compiled_at "$(ap_now)" \
        --arg evidence_dir "$evidence_dir" \
        --argjson records "$records_json" \
        '{schema_version: 1,
          gate: $manifest[0].gate,
          run_token: $state[0].run_token,
          head_sha: $preflight.head_sha,
          steps_sha256: $preflight.steps_sha256,
          walkthrough_started_at: $state[0].started_at,
          compiled_at: $compiled_at,
          evidence_dir: $evidence_dir,
          provider_calls_made: 0,
          image_calls_made: 0,
          image_calls_still_unauthorized: $manifest[0].gate_constants.image_calls_still_unauthorized,
          image_output_subtotal_usd_before_text: $manifest[0].gate_constants.image_output_subtotal_usd_before_text,
          controls_recorded: ($records | length),
          steps_in_manifest: ($manifest[0].steps | length),
          labels_still_unverified: [$records[] | select(.label_was_unverified and .label_seen_on_screen == null) | .step_id],
          controls: [$records[] | {step_id, record_key, proven_value, screenshot, label_seen_on_screen, note, recorded_at}]}' \
        > "$proof"
    [[ "$(jq -r '.controls | length' "$proof")" == "$total_steps" ]] \
        || ap_die "the written proof does not hold one control per step; treat $proof as void" 65
    rm -f "$evidence_dir/account-controls-proof.void.json"
    ap_ok "wrote $proof"
    unconfirmed="$(jq -r '.labels_still_unverified | join(", ")' "$proof")"
    [[ -z "$unconfirmed" ]] || ap_warn "these steps recorded no on-screen label, so their labels stay unconfirmed: $unconfirmed"
    ap_note 'the eight-call gate stays locked; this file is proof for Tim to read, not an authorization'
    ;;

*)
    ap_die "unknown command $command_name" 64
    ;;
esac
