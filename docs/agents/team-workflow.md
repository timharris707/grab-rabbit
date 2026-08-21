# Team workflow — repo bindings

<!-- Seeded by the ClickAI team-workflow pack's setup skill. Re-run setup to refresh
     these bindings idempotently when the repository changes. -->

_Pack version: team-workflow v1.5.2 · Last confirmed: 2026-08-17_

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
- **Implicit-repo check**: mismatch — `gh repo view` in this fork resolves to
  `lihaoyun6/QuickRecorder`, not the bound tracker. Every tracker command therefore
  retains explicit `--repo timharris707/grab-rabbit` scoping, and every API path
  names `repos/timharris707/grab-rabbit` literally.

## Verify commands

Verification is tiered by the changed surface. Every lane runs the full-branch
whitespace check and the English-only source gate:

```bash
git diff --check origin/main...HEAD
LC_ALL=C scripts/verify-english-only.sh
```

Application, project, dependency, or build-setting changes also run:

```bash
xcodebuild -project QuickRecorder.xcodeproj -scheme QuickRecorder -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/test CODE_SIGNING_ALLOWED=NO test
xcodebuild -quiet -project QuickRecorder.xcodeproj -scheme QuickRecorder -configuration Release -destination 'platform=macOS' -derivedDataPath .build/verify CODE_SIGNING_ALLOWED=NO build
lipo .build/verify/Build/Products/Release/QuickRecorder.app/Contents/MacOS/QuickRecorder -verify_arch x86_64 arm64
scripts/verify-sparkle-version.sh 2.9.5 .build/verify/Build/Products/Release/QuickRecorder.app
LC_ALL=C scripts/verify-english-only.sh .build/verify/Build/Products/Release/QuickRecorder.app
```

Agent-context or workflow changes run `scripts/verify-agent-memory.sh`. Changes to
the handoff resolver, verifier, or contract also run
`scripts/test-handoff-integrity.sh`; changes to the English-only scanner or verifier
also run `LC_ALL=C scripts/test-verify-english-only.sh`. Documentation and research
lanes add the source, link, arithmetic, or secret checks named by their tracker item.
There is no separate lint target.

The Debug suite passed 176/176 and the unsigned Release build produced an
`x86_64` + `arm64` executable on 2026-08-20 (main `1cb670a`). `CODE_SIGNING_ALLOWED=NO` proves compile
and packaging health only. Signed, TCC, updater, manual-smoke, notarization, and
distribution work must use the additional gates in `docs/release/signing.md` and
the driving tracker item.

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
- Model routing follows the resident approval rule, updated by Tim's in-session
  directives of 2026-08-18/19 (recorded on issue #39 and in the orchestrator
  handoffs): all agent lanes run on Anthropic subagents, never codex, until Tim
  revokes. Claude Fable orchestrates (2026-08-17 approval); Sonnet is limited to
  genuinely mechanical build lanes (splices, ports, verbatim transforms); Opus 5
  (or Fable) runs complex build lanes and all adversarial audits. The trigger for
  the codex revocation was silent high-effort stream wedges (2026-08-18).

## Templates

- Issue/work-item spec: the equivalent seeded form at
  `.github/ISSUE_TEMPLATE/work-item.md` is retained unchanged.
- Lane brief: refreshed from the v1.5.2 pack template at
  `docs/agents/lane-brief.md` on 2026-08-16.

## Handoff

- **Handoff location**: the primary checkout's `.claude/handoff.md`, untracked.
  `scripts/resolve-main-handoff.sh` resolves that one path from Git worktree metadata
  when run from either the primary checkout or a linked worktree. The returned
  primary-checkout path is the sole copy.
- **Ignore entry**: seeded in `.gitignore`.
- **Session-start auto-load hook**: seeded as the Codex-equivalent instruction in
  root `AGENTS.md`; the Claude Code harness on this machine auto-loads the handoff
  at session start, so no tracked runtime settings file is present or required.
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

- **Lane launch**: after the frontier and collision gates pass, the primary
  orchestrator posts the claim, provisions and preflights the workspace, then
  launches the lane with an issue-as-spec brief. Development work uses an
  Anthropic in-process subagent (Agent tool) driven from the orchestrator; work
  Tim wants to watch uses a picker-visible Claude Code session; physical hardware
  and other human-only gates use a human lane. The `Lane-start` marker and
  launch report stamp workspace, branch, runner, model, and effort, using
  `Lane-start: workspace=<name> branch=<branch> (runner=<runner> model=<model> effort=<effort>)`.
  Values are read from the launch surface; a click-launched value that the launcher
  cannot read is recorded as
  `session defaults at click time — not launcher-readable`, never guessed. The
  launcher titles a picker-visible lane `#<issue> — <short title>`;
  in-process subagents have no picker entry, so the launch report carries that
  identity. Native auto-archive on pull-request close: **no**.
- **Announce model/effort**: on. Launches and every review hand-off carry the
  runner/model/session identity and reasoning effort when readable, with the
  per-round repeats and close-out cost/announcement lines required by the
  orchestrate skill.
- **Runner inventory**: a Claude Code orchestrator session (model Claude Fable)
  owning routing, audit, and integration; development lanes on Anthropic
  in-process subagents (Agent tool) launched from the orchestrator, or
  picker-visible Claude Code sessions when Tim wants to watch; human lanes for
  steps only Tim or a physical machine can perform. There is no launcher script. This
  orchestration section is the in-repo launch recipe and applies the pack's
  runner-parity chain: eligibility, proved claim, workspace, environment, portable
  brief, and preflight, each gating the next.
- **Runner policy**: orchestration and integration run on Claude Code (model
  Claude Fable, Tim's 2026-08-17 approval). All agent lanes run on Anthropic
  subagents, never codex, until Tim revokes (Tim, 2026-08-18/19, superseding the
  codex default; recorded on issue #39; trigger: silent codex high-effort
  stream wedges, 2026-08-18). Sonnet
  only for genuinely mechanical build lanes (splices, ports, verbatim
  transforms); Opus 5 (or Fable) for complex build lanes, all adversarial
  audits, and research lanes. Use a human lane only for a genuinely human-held
  gate. Diagnose and retry a failed launch on the policy runner before any
  fallback; a fallback is recorded on both the launch report and tracker item as
  `runner fallback: X→Y, reason`.
- **Workspace provisioning**: one linked worktree per lane under
  `.worktrees/<issue>-<slug>`. Implementation branches use
  `codex/<issue>-<slug>`; throwaway prototypes use `prototype/<issue>-<slug>` and
  never merge. Item-specific resources are named in the brief and pruned with the
  worktree; none exist by default.
- **Monitoring**: while lanes are live, the orchestrator re-arms a roughly
  four-minute metronome and performs one small filtered check of lane state plus
  issue and pull-request activity per eventless wake. The first successful poll
  proves the watch is armed. Completion notifications trigger immediate review;
  tracker `Lane-start` markers remain the claim authority. With no live lanes and
  no pending external event, no metronome is needed.
- **Verification executor**: each lane runs its named checks. At close-out, an
  independent verifier re-runs non-trivial contracts in the lane workspace and
  reports each command's exit code plus `Skipped checks: none` or every omission;
  the primary integrator may run a small mechanical set inline and always
  spot-checks the load-bearing diff and evidence before merge.
- **Review-tier policy** (decider-set 2026-08-16): while the codex revocation
  above stands, the delegated-model choices below are superseded; delegated
  review runs on Anthropic per the runner policy (Opus 5 or Fable for
  adversarial tiers). The effort floors still apply.
  - Mechanical verification re-runs: `gpt-5.6-luna`, low effort when a delegated
    model is needed; exact shell commands may run inline without another model.
    Floor: never use this tier for adversarial judgment, a security/risk waiver, or
    the review of release-arming behavior.
  - Adversarial review — finders, skeptics, and re-probes: `gpt-5.6-sol`, high
    effort. Floor: no low-effort or Luna skeptic on real code or release-arming
    changes.
  - Max tier: `gpt-5.6-sol`, max effort, only for a case Tim explicitly names;
    never the default.
- **Merge flow**: each implementation uses a non-draft pull request carrying
  `Closes #<issue>`. Checks and tests must be green. When a CodeRabbit review
  appears, it must be triaged before the primary integrator merges sequentially.
  CodeRabbit auto-reviews new pull requests; if it is silent, comment
  `@coderabbitai review`, escalating once to `@coderabbitai full review`. Fix real
  findings; skip nits only with a stated reason on the pull request. If both
  triggers remain silent, record both trigger comments and the resulting silent
  outcome on the pull request; only then may the integrator merge without a
  CodeRabbit review. Pull-request prose and agent-written tracker comments follow
  the installed orchestrate skill's `references/pr-writing.md`; the primary
  integrator merges sequentially, posts the close-out, checks for uncommitted work,
  prunes the lane, and only then names the session Tim may archive.

## Session-scope conduct

- **PR-writing pointer**: accepted on 2026-08-16. Root `AGENTS.md` points every
  session at this binding and the installed orchestrate skill's
  `references/pr-writing.md` before it writes a pull-request description or GitHub
  comment on Tim's behalf.

## Optional bindings

- Adversarial review, codebase review, domain memory, glossary/non-negotiables, and
  a friction log remain unbound as of 2026-08-16; revisit them on a setup re-run.

## Accepted drift

_None yet._
