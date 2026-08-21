#!/usr/bin/env bash
#
# Dry run of the whole wizard with no browser and no account: proves the phase-1
# gate, the step order, resume after an interruption, single-step redo, and the
# compiled proof. Runs entirely in a temporary directory and makes zero calls.
#
# Usage: ./selftest.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d /tmp/grab-rabbit-49-account-proof-selftest.XXXXXX)"
evidence="$work/evidence"
trap 'rm -rf "$work"' EXIT

failures=0
check() {
    local description="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  [ok] %s\n' "$description"
    else
        printf '  [FAIL] %s\n' "$description"
        failures=$((failures + 1))
    fi
}
refute() {
    local description="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  [FAIL] %s\n' "$description"
        failures=$((failures + 1))
    else
        printf '  [ok] %s\n' "$description"
    fi
}

walk() { "$here/run-proof-walkthrough.sh" "$@" --evidence-dir "$evidence"; }

printf '\n  Account-proof wizard self test\n\n'

# Phase 2 must refuse before phase 1 has ever run.
refute 'phase 2 refuses before phase 1 has run' walk status

check 'phase 1 runs green with no browser' \
    "$here/run-preflight.sh" --evidence-dir "$evidence" --no-browser
check 'the phase 1 result records status green' \
    bash -c "[[ \$(jq -r .status '$evidence/preflight-result.json') == green ]]"
check 'the phase 1 result records zero calls' \
    bash -c "[[ \$(jq -r '.provider_calls_made,.image_calls_made' '$evidence/preflight-result.json' | sort -u) == 0 ]]"
check 'the phase 1 result opened no browser pane in this mode' \
    bash -c "[[ \$(jq '.browser_panes | length' '$evidence/preflight-result.json') == 0 ]]"

check 'phase 2 starts once phase 1 is green' walk status
check 'the first offered step is the OpenAI sign-in' \
    bash -c "[[ \$(cd '$here' && ./run-proof-walkthrough.sh next --evidence-dir '$evidence' | jq -r .id) == openai-signin ]]"
check 'the first step is flagged as one Tim must type into' \
    bash -c "[[ \$(cd '$here' && ./run-proof-walkthrough.sh next --evidence-dir '$evidence' | jq -r .requires_human) == true ]]"

# Order is enforced: a later step cannot be recorded first.
refute 'a later step cannot be recorded out of order' \
    walk record openai-billing-state --value 'attached'
# A blank proof is refused.
refute 'a step cannot be recorded with an empty value' \
    walk record openai-signin --value ''
# A screenshot that was never saved is refused.
refute 'a step cannot claim a screenshot that is not there' \
    walk record openai-signin --value yes --screenshot missing.png

check 'the first step records' walk record openai-signin --value yes
check 'the second step is offered next' \
    bash -c "[[ \$(cd '$here' && ./run-proof-walkthrough.sh next --evidence-dir '$evidence' | jq -r .id) == openai-org-identity ]]"

# Interruption: a brand new process picks up exactly where the last one stopped.
check 'a fresh process resumes at the same step, not the top' \
    bash -c "[[ \$(cd '$here' && ./run-proof-walkthrough.sh next --evidence-dir '$evidence' | jq -r .id) == openai-org-identity ]]"

# A re-run of phase 1 without --force keeps recorded work.
check 're-running phase 1 preserves recorded steps' \
    "$here/run-preflight.sh" --evidence-dir "$evidence" --no-browser
check 'the recorded first step survived the phase 1 re-run' \
    bash -c "[[ \$(jq -r '.steps[0].status' '$evidence/state.json') == done ]]"

# Record the rest, exercising the actual-label path on one step.
for step_id in $(jq -r '.steps[].id' "$here/steps.json" | tail -n +2); do
    if [[ "$step_id" == openai-org-identity ]]; then
        walk record "$step_id" --value 'Example Org (org-EXAMPLE)' --actual-label 'Organization ID' >/dev/null
    else
        walk record "$step_id" --value 'selftest placeholder value' >/dev/null
    fi
done
check 'every step is recorded' \
    bash -c "[[ \$(jq '[.steps[] | select(.status == \"done\")] | length' '$evidence/state.json') == \$(jq '.steps | length' '$here/steps.json') ]]"

# Redo reopens exactly one step and nothing else.
check 'redo reopens one step' walk redo openai-region
check 'redo left the other recorded steps alone' \
    bash -c "[[ \$(jq '[.steps[] | select(.status == \"pending\")] | length' '$evidence/state.json') == 1 ]]"
refute 'compile refuses while a step is reopened' walk compile
check 'the reopened step records again' walk record openai-region --value 'selftest placeholder value'

check 'compile writes the proof' walk compile
check 'the proof keeps the eight-call gate locked' \
    bash -c "[[ \$(jq -r .image_calls_still_unauthorized '$evidence/account-controls-proof.json') == 8 ]]"
check 'the proof records zero calls made' \
    bash -c "[[ \$(jq -r .image_calls_made '$evidence/account-controls-proof.json') == 0 ]]"
check 'the proof names the step whose label was confirmed on screen' \
    bash -c "jq -e '.labels_still_unverified | index(\"openai-org-identity\") == null' '$evidence/account-controls-proof.json'"
check 'the proof flags the steps whose labels were never confirmed' \
    bash -c "[[ \$(jq '.labels_still_unverified | length' '$evidence/account-controls-proof.json') -gt 0 ]]"

# A tampered or red phase 1 result stops phase 2 dead.
jq '.status = "red"' "$evidence/preflight-result.json" > "$evidence/preflight-result.json.tmp"
mv "$evidence/preflight-result.json.tmp" "$evidence/preflight-result.json"
refute 'phase 2 refuses when the phase 1 result is red' walk status
jq '.status = "green" | .run_token = "a-different-run"' "$evidence/preflight-result.json" > "$evidence/preflight-result.json.tmp"
mv "$evidence/preflight-result.json.tmp" "$evidence/preflight-result.json"
refute 'phase 2 refuses a phase 1 result from a different run' walk status

# Nothing anywhere in the run produced an image or a call.
refute 'the run produced no image file' \
    bash -c "find '$evidence' -type f \\( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \\) -print -quit | grep -q ."

printf '\n'
if (( failures )); then
    printf '  %s check(s) failed\n\n' "$failures"
    exit 1
fi
printf '  all checks passed\n\n'
