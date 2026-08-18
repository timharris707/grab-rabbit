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
    docs/agents/openrouter-image-generation.md
    docs/release/signing.md
    scripts/resolve-main-handoff.sh
    scripts/verify-handoff-integrity.sh
    scripts/test-handoff-integrity.sh
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
    docs/agents/openrouter-image-generation.md
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
    '**Image-generation or branding work:**'
    '**Transient state:**'
)

for required_trigger in "${required_triggers[@]}"; do
    if ! grep -Fq "$required_trigger" AGENTS.md; then
        fail "AGENTS.md is missing the mandatory $required_trigger trigger"
    fi
done

required_agent_contracts=(
    'Read these sources in order:'
    'run `scripts/resolve-main-handoff.sh` from any checkout'
    'The returned path is the only handoff.'
    'before asking for credentials or'
    'choosing a provider route.'
    'Refresh `.claude/handoff.md` before compaction or session succession.'
    '`scripts/verify-handoff-integrity.sh` before handing the session off.'
    'Refresh repository bindings by re-running the ClickAI setup skill;'
    'For ClickAI session-scope conduct,'
    'Before writing any pull-request description or GitHub comment on behalf of'
    'read `references/pr-writing.md` from the installed ClickAI `orchestrate`'
)

for required_contract in "${required_agent_contracts[@]}"; do
    if ! grep -Fq "$required_contract" AGENTS.md; then
        fail "AGENTS.md is missing the mandatory $required_contract contract"
    fi
done

required_openrouter_contracts=(
    '`OPENROUTER_API_KEY` is supplied by the environment.'
    'if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then'
    'Run this check before asking Tim to create, paste, or reconfigure a key.'
    'The setup, preparation, and runtime blocks are the complete route.'
    'add no alternate command or invocation prose elsewhere in this'
    'Preparation is complete only when that import exits `0`.'
    'It intentionally omits'
    '`--offline` so a cold cache can download the pinned package.'
    'its allowlist excludes provider credentials, headers, organization or'
    'project selection, proxy settings, and all other inherited variables.'
    'keep the runtime stage offline.'
    '`gpt-image-2` generation is proven on this route.'
    'The OpenRouter image-edit endpoint returned `404 Not Found`'
    'Treat editing as unsupported on this route:'
    'without retrying or silently switching model or provider.'
)

for required_contract in "${required_openrouter_contracts[@]}"; do
    if ! grep -Fq -- "$required_contract" docs/agents/openrouter-image-generation.md; then
        fail "OpenRouter image-generation reference is missing the $required_contract contract"
    fi
done

required_openrouter_setup_block='image_gen_cli="${CODEX_HOME:-$HOME/.codex}/skills/.system/imagegen/scripts/image_gen.py"'

openrouter_reference=$(<docs/agents/openrouter-image-generation.md)

if [[ "$openrouter_reference" != *"$required_openrouter_setup_block"* ]]; then
    fail "OpenRouter image-generation reference is missing the exact setup block"
fi

required_openrouter_preparation_block=$(printf '%s\n' \
    'env -i \' \
    '    HOME="$HOME" \' \
    '    PATH="$PATH" \' \
    '    TMPDIR="${TMPDIR:-/tmp}" \' \
    "    uv run --with 'openai==3.1.0' --no-env-file --no-project python -c \\" \
    "    'import openai; assert openai.__version__ == \"3.1.0\"'")

if [[ "$openrouter_reference" != *"$required_openrouter_preparation_block"* ]]; then
    fail "OpenRouter image-generation reference is missing the exact minimal preparation block"
fi

required_openrouter_runtime_block=$(printf '%s\n' \
    '(' \
    '    set +a' \
    '    unset openrouter_key' \
    '    openrouter_key=${OPENROUTER_API_KEY:?OPENROUTER_API_KEY is missing}' \
    '' \
    '    env -i \' \
    '        HOME="$HOME" \' \
    '        PATH="$PATH" \' \
    '        TMPDIR="${TMPDIR:-/tmp}" \' \
    '        OPENAI_API_KEY="$openrouter_key" \' \
    '        OPENAI_BASE_URL=https://openrouter.ai/api/v1 \' \
    "        uv run --offline --with 'openai==3.1.0' --no-env-file --no-project \\" \
    '        python "$image_gen_cli" generate \' \
    '        --model gpt-image-2 \' \
    '        --prompt-file "$prompt_file" \' \
    '        --quality low \' \
    '        --size 1024x1024 \' \
    '        --no-augment \' \
    '        --out "$output_file"' \
    ')')

if [[ "$openrouter_reference" != *"$required_openrouter_runtime_block"* ]]; then
    fail "OpenRouter image-generation reference is missing the exact isolated runtime block"
fi

if ! GRAB_RABBIT_SETUP_BLOCK="$required_openrouter_setup_block" \
    GRAB_RABBIT_PREPARATION_BLOCK="$required_openrouter_preparation_block" \
    GRAB_RABBIT_RUNTIME_BLOCK="$required_openrouter_runtime_block" \
    ruby -e '
reference = File.binread(ARGV.fetch(0))
blocks = {
  "setup" => ENV.fetch("GRAB_RABBIT_SETUP_BLOCK"),
  "preparation" => ENV.fetch("GRAB_RABBIT_PREPARATION_BLOCK"),
  "runtime" => ENV.fetch("GRAB_RABBIT_RUNTIME_BLOCK")
}

blocks.each do |name, block|
  count = reference.scan(block).length
  unless count == 1
    warn "#{name} block count: #{count}"
    exit 1
  end
  reference.sub!(block, "")
end

reserved_route_token = /(^|[^[:alnum:]_])(uv|image_gen_cli|image_gen[.]py|OPENAI_API_KEY|OPENAI_BASE_URL)([^[:alnum:]_]|$)/
if reference.match(reserved_route_token)
  warn "reserved route token outside canonical blocks"
  exit 1
end
' docs/agents/openrouter-image-generation.md
then
    fail "OpenRouter image-generation reference must contain each canonical route block exactly once and no route tokens elsewhere"
fi

forbidden_openrouter_contracts=(
    'OPENAI_API_KEY="$OPENROUTER_API_KEY"'
    'env -u OPENROUTER_API_KEY'
    'export -n openrouter_key'
    'uv run --with openai python'
)

for forbidden_contract in "${forbidden_openrouter_contracts[@]}"; do
    if grep -Fq -- "$forbidden_contract" docs/agents/openrouter-image-generation.md; then
        fail "OpenRouter image-generation reference retains unsafe route $forbidden_contract"
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

required_handoff_contracts=(
    $'the primary checkout\'s `.claude/handoff.md`, untracked.'
    '`scripts/resolve-main-handoff.sh` resolves that one path from Git worktree metadata'
    'primary-checkout path is the sole copy.'
    '`scripts/verify-handoff-integrity.sh`'
    'Manual-smoke manifest: /absolute/path/to/manifest.json'
    "binds that manifest to the lane's current commit"
)

for required_contract in "${required_handoff_contracts[@]}"; do
    if ! grep -Fq "$required_contract" docs/agents/team-workflow.md; then
        fail "team-workflow binding is missing the $required_contract handoff contract"
    fi
done

required_team_workflow_contracts=(
    '_Pack version: team-workflow v1.5.2'
    '**Implicit-repo check**: mismatch'
    'xcodebuild -project QuickRecorder.xcodeproj -scheme QuickRecorder -configuration Debug'
    '**Announce model/effort**: on.'
    '**Runner inventory**: a Claude Code orchestrator session'
    '**Runner policy**: orchestration and integration run on Claude Code'
    '**Review-tier policy** (decider-set 2026-08-16):'
    '## Session-scope conduct'
    '## Accepted drift'
)

for required_contract in "${required_team_workflow_contracts[@]}"; do
    if ! grep -Fq "$required_contract" docs/agents/team-workflow.md; then
        fail "team-workflow binding is missing the $required_contract setup contract"
    fi
done

required_lane_brief_contracts=(
    'gh issue view <N> --repo timharris707/grab-rabbit --comments'
    'installed ClickAI `diagnose` skill'
    'Skipped checks: none'
    'never the full diff or transcript'
)

for required_contract in "${required_lane_brief_contracts[@]}"; do
    if ! grep -Fq "$required_contract" docs/agents/lane-brief.md; then
        fail "lane brief is missing the $required_contract setup contract"
    fi
done

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

required_identity_contracts=(
    'The product name is **Grab Rabbit**.'
    'Lens Leap app icon'
    'Viewfinder Ears status-item companion'
    '`dev.clickai.grabrabbit`'
    'durable identity decisions'
)

for required_contract in "${required_identity_contracts[@]}"; do
    if ! grep -Fq "$required_contract" docs/agents/project-baseline.md; then
        fail "project baseline is missing the $required_contract identity decision"
    fi
done

forbidden_baseline_status=(
    'application rebrand work had not begun'
    'final Grab Rabbit bundle identifier has not been selected'
)

for forbidden_status in "${forbidden_baseline_status[@]}"; do
    if grep -Fq "$forbidden_status" docs/agents/project-baseline.md; then
        fail "project baseline retains stale status: $forbidden_status"
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
secret_audit_files=(
    docs/release/signing.md
    docs/agents/openrouter-image-generation.md
)

if grep -Eiq "$secret_placeholder_pattern" "${secret_audit_files[@]}"; then
    fail "an agent reference contains a secret or obvious secret placeholder"
fi

openrouter_secret_pattern='sk-or-v1-[[:alnum:]_-]{20,}'
if grep -Eiq "$openrouter_secret_pattern" "${secret_audit_files[@]}"; then
    fail "an agent reference contains material matching an OpenRouter credential"
fi

if (( failed != 0 )); then
    exit 1
fi

echo "Agent memory check passed"
