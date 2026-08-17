# Studio render-cadence prototype

This throwaway branch answers [issue #48](https://github.com/timharris707/grab-rabbit/issues/48).
It never merges into production. The first tracer is a deterministic state-machine harness that
compares ScreenCaptureKit-driven, camera-driven, fixed-clock, and hybrid ownership before live
capture widens the experiment.

The tracer intentionally models the risky cases: static, low-change, and active browser input;
camera motion; writer backpressure; pause/resume; and a camera disconnect. Browser samples have
two distinct types. Only `SanitizedBrowserFrame` can enter `FrameCache`, and construction is
private to `WindowPrivacyBoundary`, mirroring the copy-then-sanitize order in
`CaptureOutputSession.prepareWindowSample`.

Run a manifest-bound matrix from a clean committed checkpoint:

```bash
prototypes/48-render-cadence/scripts/run-synthetic-matrix.sh \
  /absolute/path/to/evidence-directory
```

The output contains one JSONL event trace and one JSON metrics record per candidate/case/shape,
plus `summary.csv`, `privacy-probe.json`, SHA-256 hashes, and `manifest.json`. This tracer does
not claim runtime CPU/GPU/ANE/thermal performance or playable-media acceptance.

The native stage writes H.264/AAC movies, probes their streams, records per-process CPU time,
resident memory, writer-readiness waits, and thermal state, and covers camera-only plus
camera/browser compositions:

```bash
prototypes/48-render-cadence/scripts/run-native-matrix.sh \
  /absolute/path/to/native-evidence-directory
```

Run that stage on the Mac Mini whenever feasible. GPU/ANE/power sampling remains a separately
named human gate because `powermetrics` requires interactive administrator authorization.

## Live probe preparation

`live-cadence-probe` is the actual-hardware path. It discovers cameras through
`AVCaptureDevice.DiscoverySession`, selects only an exact stable `uniqueID`, and discovers only
real on-screen `SCWindow` values from `SCShareableContent.excludingDesktopWindows`. Window
capture constructs only `SCContentFilter(desktopIndependentWindow:)`; there is no display or
desktop fallback. Inventory, preflight, and recording only inspect existing TCC state. The
separate `authorize` command can invoke macOS-owned Camera, Microphone, and Screen Recording
requests, but only after its runtime identity contains the exact approved team and Developer ID
fingerprint.

Unsigned-safe inventory and preflight do not capture or create a movie:

```bash
swift run --package-path prototypes/48-render-cadence -c release \
  live-cadence-probe list-sources

swift run --package-path prototypes/48-render-cadence -c release \
  live-cadence-probe preflight \
  --camera-id 'EXACT_UNIQUE_ID' \
  --window-id 'EXACT_WINDOW_ID' \
  --output /absolute/must-not-exist.mov \
  --json /absolute/preflight.json
```

Exact camera/window IDs printed by inventory stay transient; the preflight report and live-run
metrics retain exact-match booleans but not the identifiers. The live `record` command refuses
to run unless camera/screen/microphone authorization is already in the required state and its
own runtime certificate is the exact approved Developer ID fingerprint
`189EC9780DE0A94CF5B24CC5983CAB3FDAE15638`. Recording never requests permission or selects
another camera after disconnect. Camera-driven and fixed-clock runs share the same typed
sanitized-window cache and real-time H.264/AAC writer:

```bash
live-cadence-probe record \
  --camera-id 'EXACT_UNIQUE_ID' \
  --window-id 'EXACT_WINDOW_ID' \
  --candidate fixed-clock \
  --canvas 16x9 \
  --duration 12 \
  --fps 30 \
  --pause-at 4 \
  --pause-duration 1 \
  --system-audio \
  --microphone \
  --output /absolute/run.mov \
  --metrics /absolute/run.metrics.json \
  --events /absolute/run.events.jsonl \
  --powermetrics-path /absolute/run.powermetrics.txt
```

The `--powermetrics-path` is a predeclared external hook; the probe does not run `sudo` or
`powermetrics`. After the separately authorized sampler exits,
`scripts/bind-powermetrics.sh` hash-binds it to the live metrics. `scripts/build-live-app.sh`
builds an unsigned inspection bundle or a stable signed bundle; signed mode refuses every
identity except the approved name/team/fingerprint and explicitly rejects the `45F21D…`
certificate. `scripts/verify-live-probe.sh` is the reproducible compile/test/static/preflight
gate used before physical capture.

## Human gate wizard

Tim confirmed the six-stage order: exact camera; approved signing and visible TCC authorization;
exact browser window and three cases; shape/pause/disconnect matrix; external `sudo powermetrics`;
then verification, state restoration, and visual verdict. The repeatable path is
[`scripts/run-human-gate-wizard.sh`](scripts/run-human-gate-wizard.sh):

```bash
prototypes/48-render-cadence/scripts/run-human-gate-wizard.sh
```

Start from a clean, pushed `prototype/48-render-cadence` checkout on the Mac Mini. Have the exact
camera, a browser, the approved certificate/private key already visible in Keychain Access, the
administrator password, and time to inspect the movies in QuickTime. The stable probe app path
must be empty, the prohibited `45F21D…` identity must not be live, and protected PIDs 12083 and
9243 must still be running. The wizard estimates 100 minutes, asks before every stateful or
interactive phase, lets `sudo` own its foreground password prompt, and never writes a password or
exact camera/window ID. Do not run it as an automated or unattended gate.
