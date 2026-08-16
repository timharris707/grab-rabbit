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
