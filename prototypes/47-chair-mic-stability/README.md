# Q11 foreground-stability prototype

This throwaway branch answers [issue #47](https://github.com/timharris707/grab-rabbit/issues/47).
It never merges into production. It compares only the prerequisite-research candidates:

- **P0:** native `GeneratePersonSegmentationRequest`, accurate, stateful, every source frame;
- **P1:** native `GenerateForegroundInstanceMaskRequest`, all instances unioned, with the raw
  per-frame instance indexes rendered in distinct colors.

SAM 2.1 Tiny is intentionally absent. It remains conditional on an observed P1 failure and
Tim's explicit approval of the approximately 149 MiB model download. The prototype performs
no cloud calls, paid model calls, credential changes, or model downloads.

## Evidence contract

Each source clip is processed once through P0 and P1. The tool writes:

- a full-duration synchronized comparison movie (no selected highlights);
- frame-by-frame JSONL measurements;
- a raw measurement summary;
- a phase/candidate/object visual-review worksheet; and
- a hash-bound run manifest with explicit coverage gaps.

The comparison is a 3-by-2 grid:

| | Left | Center | Right |
|---|---|---|---|
| Top | Source | P0 person matte | P0 checkerboard composite |
| Bottom | P1 per-instance colors | P1 union matte | P1 checkerboard composite |

Green marker lines denote P0 panels; blue lines denote P1 panels. P1 colors deliberately follow
each frame's raw instance indexes so temporal identity changes remain visible.

Normalized regions in `experiment.json` use a top-left origin. They record raw person/chair/
microphone coverage and known-background false inclusion. They are reproducible sampling boxes,
not pixel-accurate ground truth. Temporal XOR/IoU includes intentional motion. Neither the tool
nor this branch invents a quality threshold or support verdict.

## Current physical inventory (2026-08-16)

- Mac Mini (`Cliff's OpenClaw's Mac Mini`): macOS 26.5.2, Apple silicon, Shure MV7+ connected,
  **no camera currently enumerated**.
- MacBook Pro camera host: built-in MacBook camera, Studio Display camera paths, and Tim's iPhone
  Continuity Camera currently enumerate.

The honest route is therefore human-started capture on the MacBook, followed by offline replay
on the Mini. The Mini's CuaDriver PID 12083 and Screen Sharing PID 9243 are unrelated and must
remain untouched.

## Build and inventory

```bash
cd prototypes/47-chair-mic-stability
swift build
swift run foreground-probe inventory --output /absolute/evidence/path/macbook-inventory.json
```

Build the camera-TCC-stable app bundle. The script refuses any signer except the exact approved
identity in `docs/release/signing.md`:

```bash
scripts/build-capture-app.sh
```

## Required human capture (not yet performed)

Before each 32-second run, put one person, the actual desk-chair back, and the actual Shure
microphone in frame; wear glasses when available. Keep one plausible lighting condition fixed
for that clip. Run two lighting conditions for Tim's iPhone camera and repeat them on at least
one non-iPhone camera. The executable beeps and prints six phases: stillness, speaking motion,
microphone occlusion, chair occlusion, chair movement, and final stillness.

```bash
probe='.build/capture-app/Grab Rabbit Foreground Probe.app/Contents/MacOS/foreground-probe'

"$probe" inventory --output /absolute/evidence/path/camera-inventory.json
"$probe" capture \
  --device-id 'EXACT_ID_FROM_INVENTORY' \
  --clip-id iphone-normal \
  --lighting 'normal room light' \
  --output /absolute/evidence/path/captures
```

Repeat with unique clip IDs. Capture is explicit and refuses to overwrite evidence. Verify the
scene and fill time-bounded person/chair/microphone/background rectangles in a copy of
`experiment.example.json`; use additional region entries when an object moves out of its earlier
box.

## Process on the Mac Mini

Copy this prototype directory, `experiment.json`, raw clips, and capture sidecars to a dedicated
temporary Mini directory. Then run from an interactive SSH session so macOS can request the one
administrator password required by `powermetrics`:

```bash
scripts/run-with-pressure.sh \
  /absolute/path/to/experiment.json \
  /absolute/path/to/evidence-output
```

This records CPU, GPU, ANE, thermal, and per-process pressure alongside the native analysis.
Preserve the output before removing only the temporary Mini directory and processes started by
this run. Do not remove or replace any pre-existing Mini process.

## Verdict boundary

After all required clips and worksheets exist, Tim reviews every synchronized movie and records
one outcome on the issue: person-only; automatic quality-gated inclusion by object/camera; or a
justified user-assisted path. Exact thresholds must be written explicitly at that time. This
checkpoint does not request or pre-empt that verdict.
