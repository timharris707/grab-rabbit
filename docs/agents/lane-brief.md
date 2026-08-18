# Lane brief template

How a tracked work item becomes a working brief for the Codex or human lane
implementing it. The item is the spec: the brief adds only standing constraints and
lane mechanics, never a second copy of the requirements.

The brief is runner-agnostic. Beside the verbatim body, cite the item and the
explicitly scoped command that fetches it so any bound runner can recover the
authoritative text from any checkout:

```bash
gh issue view <N> --repo timharris707/grab-rabbit --comments
```

Keep the brief free of one harness's tool names, session mechanics, or file
conventions. The installed orchestrate skill's runner-parity reference owns the full
launcher standard.

## Before generating the brief

1. Pick the item from the binding doc's frontier, which reads both dependency edges
   and the `blocked` label.
2. Claim it with the read-before-write recipe. A live `Lane-start` refuses a second
   claim.
3. Create a fresh item-named branch and linked worktree from the current default
   branch. Record any environment facts or resources the lane must pin at launch.
4. Select the exact verification tier from the binding doc before work begins.

## Brief

```markdown
# Lane brief — item #<N>: <title>

## Spec
The spec is item #<N>, fetchable with:
`gh issue view <N> --repo timharris707/grab-rabbit --comments`

<paste the item body verbatim; do not reinterpret it>

Record deviations in the summary. A deviation from a recorded decision returns to
the decider instead of entering the work silently.

## Required reading
- `docs/agents/project-baseline.md`
- `docs/agents/team-workflow.md`
- The domain/context documents named by that binding
- For bug-shaped work: the installed ClickAI `diagnose` skill
- For build-shaped work: the installed ClickAI `implement` skill
- For signing, TCC, updater, or release work: `docs/release/signing.md`

## Standing constraints
- Verification: <the exact commands selected from the binding for this item>.
- Check every command's own exit code. Piped or filtered output is not evidence.
- Commit checkpoints on the lane branch with short imperative subjects.
- The reviewer/integrator—not the lane—owns merge.
- Follow the binding doc's precedence and exemption rules.
- If this lane itself files a cross-repository pull request, follow the installed
  orchestrate skill's `references/pr-writing.md`.

## Output contract
Write a compact tracker summary containing:
1. What landed by file, with the diff stat.
2. Every verification command and its exit code, ending with `Skipped checks: none`
   or naming every skipped check and why.
3. Deviations from the spec and open questions.

Quote only load-bearing hunks or sentences, never the full diff or transcript. The
orchestrator audits the diff in the lane workspace. Post the summary back to item
#<N>; that tracker comment is the durable record.
```
