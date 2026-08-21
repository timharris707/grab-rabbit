# Account-controls proof wizard (issue #49 human gate)

Before Tim can authorize the eight text-only image-generation calls (`$0.38772` image-output
subtotal before text charges), the exact OpenAI and Google account controls have to be proven and
written down: data retention, processing region, age and content settings, billing state, and
commercial-use terms. This directory is the tooling that produces that proof.

It generates **no images and makes no provider calls**. It stores no credentials and uploads
nothing. The only outbound action anywhere here is handing a dashboard URL to the default browser.
The eight-call gate stays locked; this wizard only produces the evidence Tim reads before deciding.

It composes with the zero-call packet one directory up. Phase 1 verifies that packet's checksums
against the `aceda5c` checkpoint and refuses to go green if the packet has drifted.

## Two phases, per the [#59](https://github.com/timharris707/grab-rabbit/issues/59) standard

**Phase 1 — agent preflight.** `run-preflight.sh` runs every mechanical step end to end: tool
checks, the packet checksum verification, the no-provider-client check, staging the evidence
directory, and opening the dashboard panes. It writes `preflight-result.json` with a green or red
status. Phase 2 refuses to start unless that file says green, so nobody ever meets a preflight
failure in the middle of the walkthrough.

```bash
./run-preflight.sh --evidence-dir /tmp/grab-rabbit-49-account-proof
./run-preflight.sh --evidence-dir DIR --no-browser   # stage only, open no panes
./run-preflight.sh --evidence-dir DIR --force        # restage from scratch, discarding records
```

Re-running phase 1 over a directory that already holds recorded work adopts that work only after
checking it: the state must be valid JSON with a run token, its step ids must match the current
manifest, and every step it calls done must have a readable record. Anything else is red, with
`--force` named as the way out. `--force` deletes a directory, so it refuses any directory that is
neither empty nor holding a phase 1 result — it will not delete somebody else's `/tmp` path.

A re-run after a red result adopts its own leftover, so a retry never needs `--force` — but only
when the directory holds *exactly* the one result file, which is all a red run leaves behind. A
directory holding a result file plus anything else may hold recorded human-gate work, so it is
refused with `--force` named, never deleted silently.

**Phase 2 — the proof walkthrough.** A driving agent with desktop or remote-computer control runs
`run-proof-walkthrough.sh` one command at a time. Tim is pulled in only where a password or
two-factor code must be typed. Sixteen steps, about 27 minutes end to end, of which Tim's own part
is the two sign-ins.

```bash
./run-proof-walkthrough.sh status  --evidence-dir DIR   # progress and what is next
./run-proof-walkthrough.sh next    --evidence-dir DIR   # the next step, as JSON for the driver
./run-proof-walkthrough.sh brief   STEP_ID --evidence-dir DIR   # the same step in plain sentences
./run-proof-walkthrough.sh open    STEP_ID --evidence-dir DIR   # hand that step's URL to the browser
./run-proof-walkthrough.sh record  STEP_ID --value "..." [--screenshot FILE] \
                                   [--actual-label "..."] [--note "..."] --evidence-dir DIR
./run-proof-walkthrough.sh redo    STEP_ID --evidence-dir DIR   # reopen exactly that one step
./run-proof-walkthrough.sh compile --evidence-dir DIR   # write account-controls-proof.json
```

Each step is recorded before the next is offered, so an interruption or a wrong entry resumes at
that step. Nothing restarts the run from the top — that was the defect in the old #48 wizard.
`redo` reopens exactly one step and leaves every other recorded step alone.

The `next` payload is everything the driver needs for that step: the absolute evidence directory,
the absolute file to save a capture to (`screenshot_save_to`), and a ready-to-run `record_command`.
A driver working from `next` alone never has to guess a path.

`compile` names every record file from the manifest rather than globbing a directory. A record that
is missing or unreadable is fatal, so a proof can never come out complete-looking with a hole in it,
and it lists controls in walkthrough order.

The `record_command` in that payload ships `<VALUE-REQUIRED>` where the value goes, and `record`
rejects that placeholder, so a driver that runs the line verbatim is told to go read the screen
rather than recording a placeholder as the proven value.

**What may be passed to `--value`.** Anything the step's `value_description` asks for, except on the
two sign-in steps: those accept only the literal words `signed-in` or `not-signed-in`. The account
address is recorded on the identity steps instead. A `--screenshot` must be a plain filename already
saved in `DIR/screenshots`.

**What may be passed to `--note` and `--actual-label` on a sign-in step.** Both reach the compiled
proof, so on the two credential steps both reject a run of four or more digits and any text naming a
credential (`password`, `passcode`, `passphrase`, `one-time`, `otp`, `2fa`, `verification code`).
Sign-in page labels are button text like `Sign in`, and a useful note reads `dashboard loaded,
two-factor prompt appeared on phone` — nothing legitimate on those steps needs a digit run or a
credential word. Between the fixed `--value` words and these two guards, there is no field on a
credential step that can carry a password or a code into the proof.

`compile` sets any earlier proof aside as `account-controls-proof.void.json` before it checks
anything, and only a compile that succeeds restores a file under the real name. A refused compile
therefore never leaves a stale proof sitting there looking current.

`records/` and `screenshots/` are checked at adoption, at record time, and at compile: each must be
a real directory inside the evidence directory, not a symlink pointing somewhere else. Otherwise a
swapped `records/` could compile fabricated records into a clean-looking proof.

## The step manifest

`steps.json` is the machine-readable manifest the driver reads. Every step carries an id, the URL,
the exact on-screen label of the control to find, one action, the evidence to capture (which value
to record and which screenshot filename to save), and a `requires_human` flag.

Two steps are `requires_human: true` — `openai-signin` and `google-signin`. Both are credential
entry and nothing else. Each carries a `human_handoff` block saying in plain words what Tim will
see on screen and what he types. The driving agent stops there and hands him the keyboard, and
never reads, logs, or screenshots a password or a code.

**Unverified labels.** Every provider control label in the manifest is marked
`label_unverified: true`. They were written from documented provider interfaces, but no label here
could be confirmed without a live login, and an unconfirmed label must never be presented to Tim as
verbatim. The driving agent confirms each on screen and passes the real one with `--actual-label`;
`compile` then lists any step whose label was never confirmed under `labels_still_unverified`.

## Evidence output

```
DIR/preflight-result.json          phase 1 green or red, its checks, the run token
DIR/state.json                     per-step status, so the run is resumable
DIR/records/<step_id>.json         one proven value per step
DIR/screenshots/                   the driving agent saves capture files here
DIR/account-controls-proof.json    the compiled proof, written by `compile`
```

The compiled proof is one file the orchestrator can post on #49 and Tim can read in one look. It
restates that zero calls were made and that eight image calls remain unauthorized, and it carries
its own provenance: the commit it was proven against, the pinned manifest checksum, when the
walkthrough started, when it was compiled, and when each individual control was observed. The
eight-call count and the `$0.38772` subtotal are read from the manifest, not written into the
compiler.

The manifest is pinned across the phase boundary: phase 1 records `steps.json`'s checksum and phase
2 refuses to run if it no longer matches, so a manifest edited between the phases cannot leave a
half-recorded run describing steps that no longer exist.

## Self test

```bash
./selftest.sh
```

A dry run in a temporary directory with no browser and no account: 73 assertions. It proves the
phase-1 gate, step ordering, resume after an interruption, single-step redo, refusal to compile a
proof with a missing record, refusal of a red, foreign, or manifest-stale phase-1 result, refusal to
adopt an incoherent evidence directory or a symlinked `records/`, refusal to delete a directory
holding recorded work, the credential and path guards, that a refused compile voids an earlier
proof, that `--force` will not delete an unrelated directory, and that the run generates no image of
its own outside `screenshots/`.

## What was adopted from the #48 lane

- **`open -W` does not propagate an app's exit code.** So no green or red decision anywhere here
  rests on an exit code from a launch. Phase 1 writes its verdict as a machine-readable result file
  that phase 2 reads back, and a browser open is recorded as an *attempt* — the proof that a pane
  loaded is the evidence the driving agent captures, never `open`'s status.
- **A delayed start can pin an older identical process.** The same hazard here is a stale evidence
  directory at a familiar path. Adapted as a per-run identity token: phase 1 mints a run token and
  records the evidence directory's device and inode, and phase 2 refuses unless both still match.
  A green result from an earlier run cannot be spent by this one.
