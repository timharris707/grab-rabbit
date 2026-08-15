# Team workflow — repo bindings

<!-- Seeded by the ClickAI team-workflow pack's setup skill. Re-run setup to refresh
     these bindings idempotently when the repository changes. -->

_Pack version: clickai-skills 1.0.0 · Last confirmed: 2026-08-14_

## Tracker binding

- **Tracker**: GitHub Issues on `timharris707/grab-rabbit`.
- **Claim recipe**: the pack's tracker-discipline recipe as written: read comments,
  refuse a live `Lane-start`, then assign the actor and post the machine-readable
  marker.
- **Frontier query**:

  ```bash
  gh api 'repos/timharris707/grab-rabbit/issues?state=open&per_page=100' --paginate --jq '.[]
    | select(has("pull_request") | not)
    | {number, title,
       labels: [.labels[].name],
       assignees: [.assignees[].login],
       blockedBy: (.issue_dependencies_summary.blocked_by // 0)}'
  ```

  Grabbable means: labeled `ready-for-agent`, unassigned, `blockedBy == 0`, and
  without the `blocked` label.
- **Blocking**: native dependency edges for issue-backed blockers; the `blocked`
  label only for non-ticket blockers. The frontier reads both.
- **Label vocabulary**: pack defaults created on 2026-08-14:
  `needs-triage`, `ready-for-agent`, `ready-for-human`, `blocked`,
  `slice`, `bug`, `gate-decision`, and `process`.

## Verify commands

The repository currently has no separate lint or automated-test target. The proven
verification command is the unsigned universal Release build:

```bash
xcodebuild -project QuickRecorder.xcodeproj -scheme QuickRecorder -configuration Release -destination 'platform=macOS' -derivedDataPath .build/verify CODE_SIGNING_ALLOWED=NO build
```

This command passed on 2026-08-14. Re-run setup after the project and scheme are
renamed or when lint/tests are added so briefs never use a stale command.

## The decider

- **Decider**: Tim Harris.

Every pack skill resolves “the decider” to this line. Sessions bring Tim
recommendations and evidence; Tim adjudicates product and risk decisions.

## Docs home

- **Binding doc home**: `docs/agents/team-workflow.md`.
- **Decision maps**: `docs/<scope>-decision-map.md`.
- **Research findings**: `docs/research/`.
- **Domain/context docs agents should load**: `README.md`, plus security and release
  documents as they are added.

## Precedence & exemptions

System, user, and repository-specific instructions govern first. This pack supplies
the tracker, lane, decision, research, handoff, and orchestration discipline around
them.

- **Prototype test-exemption**: code on `prototype/<name>` branches is exempt from
  test-first and coverage rules. Prototype branches are throwaway and never merge;
  the exemption ends when real implementation starts.
- Security fixes include a regression check that would catch recurrence.
- Product and UI changes stay within the accepted issue spec; discoveries outside it
  become new tracker items.

## Templates

- Issue/work-item spec: seeded at `.github/ISSUE_TEMPLATE/work-item.md`.
- Lane brief: seeded at `docs/agents/lane-brief.md`.

## Handoff

- **Handoff location**: the primary checkout's `.claude/handoff.md`, untracked.
  `scripts/resolve-main-handoff.sh` resolves that one path from Git worktree metadata
  when run from either the primary checkout or a linked worktree. The returned
  primary-checkout path is the sole copy.
- **Ignore entry**: seeded in `.gitignore`.
- **Session-start auto-load hook**: seeded as the Codex-equivalent instruction in
  root `AGENTS.md`; no runtime settings file was present or required.
- **Integrity gate**: before session succession, run
  `scripts/verify-handoff-integrity.sh`. Reference an active manual-smoke artifact
  with exactly `Manual-smoke manifest: /absolute/path/to/manifest.json`; the verifier
  binds that manifest to the lane's current commit, canonical artifact, and approved
  Grab Rabbit smoke identity.

## Orchestration

- **CodeRabbit configuration**: `grab-rabbit` and `modeldeck-private` both use
  organization settings, with English (US), early access disabled, and no
  repository-specific inheritance override. Organization settings are
  authoritative; do not add `.coderabbit.yaml` or `.coderabbit.yml`.

- **Lane launch**: the primary orchestrator selects from the frontier, applies the
  claim recipe, launches one agent session per issue, and stamps the issue number
  into the lane name.
- **Workspace provisioning**: one linked worktree per lane under
  `.worktrees/<issue>-<slug>`, on an issue-named branch from the current default
  branch.
- **Monitoring**: the orchestrator polls agent state plus issue and pull-request
  activity. Tracker `Lane-start` markers remain the source of truth for claims.
- **Verification executor**: each lane runs its specified checks; the primary
  integrator re-runs the binding's required verification before merge.
- **Merge flow**: each implementation uses a non-draft pull request carrying
  `Closes #<issue>`. Checks and tests must be green. When a CodeRabbit review
  appears, it must be triaged before the primary integrator merges sequentially.
  CodeRabbit auto-reviews new pull requests; if it is silent, comment
  `@coderabbitai review`, escalating once to `@coderabbitai full review`. Fix real
  findings; skip nits only with a stated reason on the pull request. If both
  triggers remain silent, record both trigger comments and the resulting silent
  outcome on the pull request; only then may the integrator merge without a
  CodeRabbit review.
