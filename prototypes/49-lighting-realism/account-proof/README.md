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
restates that zero calls were made and that eight image calls remain unauthorized.

## Self test

```bash
./selftest.sh
```

A dry run in a temporary directory with no browser and no account. It proves the phase-1 gate, step
ordering, resume after an interruption, single-step redo, refusal of a red or foreign phase-1
result, and that the run produces no image file.

## What was adopted from the #48 lane

- **`open -W` does not propagate an app's exit code.** So no green or red decision anywhere here
  rests on an exit code from a launch. Phase 1 writes its verdict as a machine-readable result file
  that phase 2 reads back, and a browser open is recorded as an *attempt* — the proof that a pane
  loaded is the evidence the driving agent captures, never `open`'s status.
- **A delayed start can pin an older identical process.** The same hazard here is a stale evidence
  directory at a familiar path. Adapted as a per-run identity token: phase 1 mints a run token and
  records the evidence directory's device and inode, and phase 2 refuses unless both still match.
  A green result from an earlier run cannot be spent by this one.
