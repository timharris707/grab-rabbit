#!/bin/bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

failed=0

fail() {
    echo "agent-memory check failed: $1" >&2
    failed=1
}

required_files=(
    AGENTS.md
    docs/agents/project-baseline.md
    docs/agents/team-workflow.md
    docs/release/signing.md
    scripts/verify-agent-memory.sh
)

for required_file in "${required_files[@]}"; do
    if [[ ! -f "$required_file" ]]; then
        fail "$required_file is missing from the working tree"
    fi
    if ! git ls-files --error-unmatch "$required_file" >/dev/null 2>&1; then
        fail "$required_file is missing or untracked"
    fi
done

previous_line=0
required_pointers=(
    docs/agents/project-baseline.md
    docs/agents/team-workflow.md
    docs/release/signing.md
    .claude/handoff.md
)

for required_pointer in "${required_pointers[@]}"; do
    pointer_line=$(grep -nF "$required_pointer" AGENTS.md | head -n 1 | cut -d: -f1 || true)
    if [[ -z "$pointer_line" ]]; then
        fail "AGENTS.md is missing the $required_pointer pointer"
    elif (( pointer_line <= previous_line )); then
        fail "AGENTS.md read-order pointers are out of order at $required_pointer"
    else
        previous_line=$pointer_line
    fi
done

required_triggers=(
    '**Every repository task:**'
    '**Tracked work:**'
    '**Build, signing, TCC, updater, or release work:**'
    '**Transient state:**'
)

for required_trigger in "${required_triggers[@]}"; do
    if ! grep -Fq "$required_trigger" AGENTS.md; then
        fail "AGENTS.md is missing the mandatory $required_trigger trigger"
    fi
done

required_agent_contracts=(
    'Read these sources in order:'
    'Refresh `.claude/handoff.md` before compaction or session succession.'
    'Refresh repository bindings by re-running the ClickAI setup skill;'
)

for required_contract in "${required_agent_contracts[@]}"; do
    if ! grep -Fq "$required_contract" AGENTS.md; then
        fail "AGENTS.md is missing the mandatory $required_contract contract"
    fi
done

if ! git check-ignore -q --no-index -- .claude/handoff.md; then
    fail ".gitignore no longer excludes .claude/handoff.md"
fi

if git ls-files --error-unmatch -- .claude/handoff.md >/dev/null 2>&1; then
    fail ".claude/handoff.md must remain untracked"
fi

if ! grep -Fq 'live frontier query' AGENTS.md; then
    fail "AGENTS.md no longer requires the handoff to use the live frontier"
fi

if ! grep -Fq 'AGPL' docs/agents/project-baseline.md || ! grep -Fq '../../LICENSE' docs/agents/project-baseline.md; then
    fail "project baseline no longer points to the authoritative AGPL license"
fi

required_product_contracts=(
    'Rounded window exteriors are transparent.'
    'deterministic non-desktop matte'
    'Audio and video remain real-time and synchronized.'
    "Grab Rabbit's own native review/player"
    'TapRecord is a workflow benchmark only'
    '`~/Movies/GrabRabbit`'
    'failure stays visible instead of silently'
)

for required_contract in "${required_product_contracts[@]}"; do
    if ! grep -Fq "$required_contract" docs/agents/project-baseline.md; then
        fail "project baseline is missing the $required_contract product contract"
    fi
done

required_attribution_contracts=(
    'required upstream copyright'
    'changelog provenance'
    'attribution are authoritative'
)

for required_contract in "${required_attribution_contracts[@]}"; do
    if ! grep -Fq "$required_contract" docs/agents/project-baseline.md; then
        fail "project baseline is missing the $required_contract ownership field"
    fi
done

secret_placeholder_pattern='(BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY|((password|token|secret|api[_ -]?key|private[_ -]?key)[[:space:]]*[:=][[:space:]]*(TODO|TBD|CHANGEME|REPLACE_ME|YOUR_|<[^>]+>)))'
if grep -Eiq "$secret_placeholder_pattern" docs/release/signing.md; then
    fail "release signing reference contains a secret or obvious secret placeholder"
fi

if (( failed != 0 )); then
    exit 1
fi

echo "Agent memory check passed"
