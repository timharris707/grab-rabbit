#!/usr/bin/env bash
#
# Dry run of the whole wizard with no browser and no account: proves the phase-1
# gate, the step order, resume after an interruption, single-step redo, refusal
# to compile a proof with a hole in it, and the credential and path guards.
# Runs entirely in a temporary directory and makes zero calls.
#
# Usage: ./selftest.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d /tmp/grab-rabbit-49-account-proof-selftest.XXXXXX)"
evidence="$work/evidence"
trap 'rm -rf "$work"' EXIT

failures=0
assertions=0
check() {
    local description="$1"; shift
    assertions=$((assertions + 1))
    if "$@" >/dev/null 2>&1; then
        printf '  [ok] %s\n' "$description"
    else
        printf '  [FAIL] %s\n' "$description"
        failures=$((failures + 1))
    fi
}
refute() {
    local description="$1"; shift
    assertions=$((assertions + 1))
    if "$@" >/dev/null 2>&1; then
        printf '  [FAIL] %s\n' "$description"
        failures=$((failures + 1))
    else
        printf '  [ok] %s\n' "$description"
    fi
}

walk() { "$here/run-proof-walkthrough.sh" "$@" --evidence-dir "$evidence"; }
walk_out() { "$here/run-proof-walkthrough.sh" "$@" --evidence-dir "$evidence" 2>/dev/null; }
last_step_id="$(jq -r '.steps[-1].id' "$here/steps.json")"

printf '\n  Account-proof wizard self test\n\n'

# ── Phase 1 gates phase 2 ───────────────────────────────────────────────────
refute 'phase 2 refuses before phase 1 has run' walk status

check 'phase 1 runs green with no browser' \
    "$here/run-preflight.sh" --evidence-dir "$evidence" --no-browser
check 'the phase 1 result records status green' \
    bash -c "[[ \$(jq -r .status '$evidence/preflight-result.json') == green ]]"
check 'the phase 1 result records zero calls' \
    bash -c "[[ \$(jq -r '.provider_calls_made,.image_calls_made' '$evidence/preflight-result.json' | sort -u) == 0 ]]"
check 'the phase 1 result opened no browser pane in this mode' \
    bash -c "[[ \$(jq '.browser_panes | length' '$evidence/preflight-result.json') == 0 ]]"
check 'the phase 1 result pins the step manifest checksum' \
    bash -c "[[ \$(jq -r '.steps_sha256 | length' '$evidence/preflight-result.json') == 64 ]]"
check 'the phase 1 result carries the commit it ran against' \
    bash -c "jq -e '.head_sha | length > 0' '$evidence/preflight-result.json'"

check 'phase 2 starts once phase 1 is green' walk status
check 'the first offered step is the OpenAI sign-in' \
    bash -c "[[ \$(cd '$here' && ./run-proof-walkthrough.sh next --evidence-dir '$evidence' | jq -r .id) == openai-signin ]]"
check 'the first step is flagged as one Tim must type into' \
    bash -c "[[ \$(cd '$here' && ./run-proof-walkthrough.sh next --evidence-dir '$evidence' | jq -r .requires_human) == true ]]"

# ── The next payload is enough to drive on ──────────────────────────────────
check 'the next payload names the evidence directory' \
    bash -c "[[ \$(cd '$here' && ./run-proof-walkthrough.sh next --evidence-dir '$evidence' | jq -r .evidence_dir) == '$evidence' ]]"
check 'the next payload names the screenshots directory' \
    bash -c "[[ \$(cd '$here' && ./run-proof-walkthrough.sh next --evidence-dir '$evidence' | jq -r .screenshots_dir) == '$evidence/screenshots' ]]"
check 'the next payload carries a ready-to-run record command' \
    bash -c "cd '$here' && ./run-proof-walkthrough.sh next --evidence-dir '$evidence' | jq -e '.record_command | test(\"record openai-signin\")'"

# ── Credential and value guards ─────────────────────────────────────────────
refute 'a later step cannot be recorded out of order' \
    walk record openai-billing-state --value 'attached'
refute 'a step cannot be recorded with an empty value' \
    walk record openai-signin --value ''
refute 'a sign-in step refuses free text' \
    walk record openai-signin --value 'a-password-typed-by-mistake'
refute 'a sign-in step refuses a one-time-code shape' \
    walk record openai-signin --value '481920'
refute 'a step cannot claim a screenshot that is not there' \
    walk record openai-signin --value signed-in --screenshot missing.png
refute 'a screenshot name cannot climb out of the screenshots directory' \
    walk record openai-signin --value signed-in --screenshot ../../escape.png

check 'the first step records with its allowed value' walk record openai-signin --value signed-in
check 'the second step is offered next' \
    bash -c "[[ \$(cd '$here' && ./run-proof-walkthrough.sh next --evidence-dir '$evidence' | jq -r .id) == openai-org-identity ]]"

# ── Resume ──────────────────────────────────────────────────────────────────
check 'a fresh process resumes at the same step, not the top' \
    bash -c "[[ \$(cd '$here' && ./run-proof-walkthrough.sh next --evidence-dir '$evidence' | jq -r .id) == openai-org-identity ]]"
check 're-running phase 1 preserves recorded steps' \
    "$here/run-preflight.sh" --evidence-dir "$evidence" --no-browser
check 'the recorded first step survived the phase 1 re-run' \
    bash -c "[[ \$(jq -r '.steps[0].status' '$evidence/state.json') == done ]]"

# ── A screenshot step takes its path straight from the next payload ─────────
save_to="$(walk_out next | jq -r '.screenshot_save_to')"
check 'a screenshot step tells the driver the absolute file to save' \
    bash -c "[[ '$save_to' == '$evidence/screenshots/openai-org-identity.png' ]]"
: > "$save_to"
check 'a step records with the screenshot saved where the payload said' \
    walk record openai-org-identity --value 'Example Org (org-EXAMPLE)' \
        --actual-label 'Organization ID' --screenshot "$(basename "$save_to")"

# ── Record the rest ─────────────────────────────────────────────────────────
for step_id in $(jq -r '.steps[].id' "$here/steps.json"); do
    [[ "$(jq -r --arg id "$step_id" '.steps[] | select(.id == $id) | .status' "$evidence/state.json")" == pending ]] || continue
    if [[ "$(jq -r --arg id "$step_id" '.steps[] | select(.id == $id) | .requires_human' "$here/steps.json")" == true ]]; then
        walk record "$step_id" --value signed-in >/dev/null
    else
        walk record "$step_id" --value 'selftest placeholder value' >/dev/null
    fi
done
check 'every step is recorded' \
    bash -c "[[ \$(jq '[.steps[] | select(.status == \"done\")] | length' '$evidence/state.json') == \$(jq '.steps | length' '$here/steps.json') ]]"
check 'the last step was recordable without compile having run first' \
    bash -c "[[ -f '$evidence/records/$last_step_id.json' && ! -f '$evidence/account-controls-proof.json' ]]"

# ── Redo touches one step, and leaves no done-without-record window ─────────
check 'redo reopens one step' walk redo openai-region
check 'redo left the other recorded steps alone' \
    bash -c "[[ \$(jq '[.steps[] | select(.status == \"pending\")] | length' '$evidence/state.json') == 1 ]]"
check 'redo never leaves a step marked done with no record behind it' \
    bash -c "for s in \$(jq -r '.steps[] | select(.status == \"done\") | .id' '$evidence/state.json'); do
                 [[ -f '$evidence/records/'\$s.json ]] || exit 1; done"
refute 'compile refuses while a step is reopened' walk compile
check 'the reopened step records again' walk record openai-region --value 'selftest placeholder value'

# ── A hole in the records must never compile into a proof ───────────────────
mv "$evidence/records/openai-region.json" "$work/held.json"
refute 'compile refuses when a record file has vanished' walk compile
refute 'no proof was written from the incomplete records' \
    bash -c "[[ -f '$evidence/account-controls-proof.json' ]]"
mv "$work/held.json" "$evidence/records/openai-region.json"
check 'compile recovers once the record is back' walk compile

# ── The compiled proof ──────────────────────────────────────────────────────
check 'the proof holds one control per manifest step' \
    bash -c "[[ \$(jq '.controls | length' '$evidence/account-controls-proof.json') == \$(jq '.steps | length' '$here/steps.json') ]]"
check 'the proof keeps the eight-call gate locked' \
    bash -c "[[ \$(jq -r .image_calls_still_unauthorized '$evidence/account-controls-proof.json') == 8 ]]"
check 'the proof carries the subtotal from the manifest, not a hardcoded copy' \
    bash -c "[[ \$(jq -r .image_output_subtotal_usd_before_text '$evidence/account-controls-proof.json') == \$(jq -r .gate_constants.image_output_subtotal_usd_before_text '$here/steps.json') ]]"
check 'the proof records zero calls made' \
    bash -c "[[ \$(jq -r .image_calls_made '$evidence/account-controls-proof.json') == 0 ]]"
check 'the proof carries the commit it was proven against' \
    bash -c "[[ \$(jq -r .head_sha '$evidence/account-controls-proof.json') == \$(jq -r .head_sha '$evidence/preflight-result.json') ]]"
check 'the proof carries when the walkthrough started' \
    bash -c "[[ \$(jq -r .walkthrough_started_at '$evidence/account-controls-proof.json') == \$(jq -r .started_at '$evidence/state.json') ]]"
check 'every control carries when it was observed' \
    bash -c "jq -e '[.controls[] | select(.recorded_at == null)] | length == 0' '$evidence/account-controls-proof.json'"
check 'the proof lists controls in walkthrough order' \
    bash -c "[[ \$(jq -r '[.controls[].step_id] | join(\",\")' '$evidence/account-controls-proof.json') == \$(jq -r '[.steps[].id] | join(\",\")' '$here/steps.json') ]]"
check 'the proof names the step whose label was confirmed on screen' \
    bash -c "jq -e '.labels_still_unverified | index(\"openai-org-identity\") == null' '$evidence/account-controls-proof.json'"
check 'the proof flags the steps whose labels were never confirmed' \
    bash -c "[[ \$(jq '.labels_still_unverified | length' '$evidence/account-controls-proof.json') -gt 0 ]]"

# ── Phase 1 result tampering ────────────────────────────────────────────────
tamper() {
    jq "$1" "$evidence/preflight-result.json" > "$evidence/preflight-result.json.tmp"
    mv "$evidence/preflight-result.json.tmp" "$evidence/preflight-result.json"
}
cp "$evidence/preflight-result.json" "$work/preflight-good.json"
tamper '.status = "red"'
refute 'phase 2 refuses when the phase 1 result is red' walk status
cp "$work/preflight-good.json" "$evidence/preflight-result.json"
tamper '.run_token = "a-different-run"'
refute 'phase 2 refuses a phase 1 result from a different run' walk status
cp "$work/preflight-good.json" "$evidence/preflight-result.json"
tamper '.steps_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"'
refute 'phase 2 refuses when the manifest changed after phase 1 pinned it' walk status
cp "$work/preflight-good.json" "$evidence/preflight-result.json"
check 'phase 2 works again once the phase 1 result is intact' walk status

# ── Phase 1 adoption is validated, not assumed ──────────────────────────────
adopted="$work/adopted"
mkdir -p "$adopted/records" "$adopted/screenshots"
cp "$evidence/state.json" "$adopted/state.json"
refute 'phase 1 refuses to adopt a state whose record files are absent' \
    "$here/run-preflight.sh" --evidence-dir "$adopted" --no-browser
cp "$evidence"/records/*.json "$adopted/records/"
jq '.steps[0].id = "a-step-that-does-not-exist"' "$evidence/state.json" > "$adopted/state.json"
refute 'phase 1 refuses to adopt a state describing different steps' \
    "$here/run-preflight.sh" --evidence-dir "$adopted" --no-browser
printf 'not json' > "$adopted/state.json"
refute 'phase 1 refuses to adopt a state that is not valid JSON' \
    "$here/run-preflight.sh" --evidence-dir "$adopted" --no-browser

# ── A retry after red just works ────────────────────────────────────────────
after_red="$work/after-red"
mkdir -p "$after_red"
printf '{"status":"red"}' > "$after_red/preflight-result.json"
check 'phase 1 re-runs cleanly over its own red leftover without --force' \
    "$here/run-preflight.sh" --evidence-dir "$after_red" --no-browser

# ── --force will not delete a directory this wizard does not own ────────────
stranger="$work/stranger"
mkdir -p "$stranger"
printf 'important' > "$stranger/somebody-elses-file"
refute '--force refuses a directory holding no phase 1 result' \
    "$here/run-preflight.sh" --evidence-dir "$stranger" --no-browser --force
check 'the unrelated file was left alone' bash -c "[[ -f '$stranger/somebody-elses-file' ]]"

# ── An option value cannot redirect the run ─────────────────────────────────
check 'a recorded value reading like an option does not redirect the run' \
    bash -c "cd '$here' && ./run-proof-walkthrough.sh redo openai-region --evidence-dir '$evidence' \
             && ./run-proof-walkthrough.sh record openai-region --value --evidence-dir --evidence-dir '$evidence' \
             && [[ -f '$evidence/records/openai-region.json' ]]"

# ── Nothing anywhere produced an image or a call ────────────────────────────
refute 'the run generated no image of its own' \
    bash -c "find '$evidence' -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \\) -print -quit | grep -q ."

printf '\n  %s assertions\n' "$assertions"
if (( failures )); then
    printf '  %s check(s) failed\n\n' "$failures"
    exit 1
fi
printf '  all checks passed\n\n'
