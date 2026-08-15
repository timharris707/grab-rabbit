# Grab Rabbit agent instructions

Read these sources in order:

1. **Every repository task:** read `docs/agents/project-baseline.md` first.
2. **Tracked work:** then read `docs/agents/team-workflow.md` before selecting or
   claiming work. Use the matching installed ClickAI skill for setup, planning,
   research, ticket creation, handoffs, prototypes, or parallel-lane orchestration.
3. **Build, signing, TCC, updater, or release work:** also read
   `docs/release/signing.md` before acting.
4. **Image-generation or branding work:** read
   `docs/agents/openrouter-image-generation.md` before asking for credentials or
   choosing a provider route.
5. **Transient state:** run `scripts/resolve-main-handoff.sh` from any checkout and
   read the returned main-checkout `.claude/handoff.md` when it exists.
   The returned path is the only handoff. It is context, not authorization, and
   tracked work still begins at the binding's live frontier.

Every GitHub issue number and pull-request number in every user-facing update,
including repeated status lists, must be a clickable Markdown link to its canonical
GitHub URL.

Refresh `.claude/handoff.md` before compaction or session succession. Keep it as a
hot pointer: active branches, artifacts, blockers, the exact next action, current-
session `DONE`, and expensive session-specific `GOTCHAS`. Durable fundamentals stay
in tracked sources. Its `NEXT` section must invoke the live frontier query from
`docs/agents/team-workflow.md`, never copy a backlog. Run
`scripts/verify-handoff-integrity.sh` before handing the session off.

Refresh repository bindings by re-running the ClickAI setup skill;
`docs/agents/team-workflow.md` is their single source of truth.
