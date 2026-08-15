# Grab Rabbit agent instructions

Read these sources in order:

1. **Every repository task:** read `docs/agents/project-baseline.md` first.
2. **Tracked work:** then read `docs/agents/team-workflow.md` before selecting or
   claiming work. Use the matching installed ClickAI skill for setup, planning,
   research, ticket creation, handoffs, prototypes, or parallel-lane orchestration.
3. **Build, signing, TCC, updater, or release work:** also read
   `docs/release/signing.md` before acting.
4. **Transient state:** read `.claude/handoff.md` when it exists. It is context, not
   authorization; tracked work still begins at the binding's live frontier.

Refresh `.claude/handoff.md` before compaction or session succession. Keep it as a
hot pointer: active branches, artifacts, blockers, the exact next action, current-
session `DONE`, and expensive session-specific `GOTCHAS`. Durable fundamentals stay
in tracked sources. Its `NEXT` section must invoke the live frontier query from
`docs/agents/team-workflow.md`, never copy a backlog.

Refresh repository bindings by re-running the ClickAI setup skill;
`docs/agents/team-workflow.md` is their single source of truth.
