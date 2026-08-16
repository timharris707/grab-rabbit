# Render-cadence prototype findings

These findings are evidence for [issue #48](https://github.com/timharris707/grab-rabbit/issues/48),
not a production implementation or final verdict. The final runtime tradeoff still needs the
physical-camera and interactive resource gates below.

## Checkpoint result

The deterministic tracer rejects ScreenCaptureKit-driven ownership. With a static browser it
offers one video frame across the source timeline; with a low-change browser it offers 1 fps.
The camera-driven, fixed-clock, and coalesced-hybrid candidates each offer 261 frames over nine
active output seconds (29 fps after nine deliberately injected writer-not-ready drops), keep
timestamps strictly monotonic, remove the one-second pause from output PTS, and stop appending
at the injected camera disconnect. Their synthetic camera latency is 0 ms p95 and their last
video/audio-master separation is one frame (33.333 ms).

The first hybrid tracer generated both camera and screen wakeups at the same PTS. It produced
58 fps during active browser input and non-monotonic duplicate timestamps. The current hybrid
coalesces equal wakeups before writer submission. With a continuously moving 30 fps camera it
then converges exactly to camera-driven behavior, so this evidence shows no hybrid benefit that
justifies its larger state surface.

The native Mac Mini run encoded 15 playable H.264/AAC MOVs: 12 camera/browser comparisons
(four candidates across static 1920x1080, low-change 1080x1920, and active 1080x1080) and three
fixed-clock camera-only shapes. All 15 have matching audio/video stream durations where the
candidate supplies a continuous clock; all 15 have zero append failures and zero sentinel
pixels at sanitized cache ingress or in rendered frames. Screen-driven low-change ends with
966.667 ms A/V stream-duration divergence, while static output collapses to one video frame.

Across the three continuously clocked candidates, the Mini encoded 261-frame camera/browser
runs in 1.400–2.379 seconds, using 85.6–122.3 MB peak resident memory. Process CPU ranges were
0.505–0.984 seconds (user + system), depending primarily on shape. Thermal state stayed
nominal. Actual asset-writer readiness caused 596–1,027 one-millisecond waits; the prototype
recorded those separately from the nine deterministic drop-policy events.

## Privacy boundary

`RawBrowserFrame` cannot enter `FrameCache`. Only `WindowPrivacyBoundary.sanitize` can construct
`SanitizedBrowserFrame`, and only that type is accepted by the cache. The probe seeds exterior
pixels with `0xffff4f00`, copies and mattes them before cache ingress, and scans both the ingress
frame and every rendered writer buffer. The current evidence is 36/36 logical runs and 15/15
native runs with zero surviving sentinel pixels.

This is the prototype equivalent of the production order in
`CaptureOutputSession.prepareWindowSample`: copy the ScreenCaptureKit sample, apply
`WindowCapturePrivacy`, and only then make the frame retainable by a cache/compositor.

## Current recommendation and unresolved tradeoff

Reject ScreenCaptureKit-driven output ownership. Do not carry the general hybrid state machine
forward unless a physical run demonstrates a measurable efficiency advantage; when the camera
moves continuously, a correct hybrid is just camera-driven with extra transitions.

Camera-driven and fixed-clock remain honestly unresolved. Camera-driven is the smallest shape
that preserves motion over a static browser, while fixed-clock is the only candidate here whose
cadence does not depend on continued camera delivery. Choosing between them requires observing
real `AVCaptureVideoDataOutput` jitter/stalls, real ScreenCaptureKit callbacks, GPU/ANE/power,
and camera-to-output latency under actual composition. The later production tripwire must hold
a browser frame static while camera content changes and assert continuous monotonic output at
the selected fps, no raw exterior sentinel at cache ingress, bounded camera latency and A/V
drift, and visible fail-closed behavior on exact-device disconnect.

## Evidence and remaining physical gate

The final evidence directory is generated after each pushed SHA and is intentionally ignored
by Git because playable camera artifacts must not be published. Its `manifest.json` binds every
artifact hash to the exact branch SHA, Mini host, macOS, hardware, toolchain, and configuration.

The Mac Mini currently enumerates no camera. `powermetrics` also requires an interactive
administrator password; noninteractive sudo is unavailable. No TCC, preference, audio, output,
or diagnostics state was changed. To close the gate, Tim must make an iPhone Continuity Camera
or another camera visible to the Mini and approve an interactive Mini run that:

1. verifies the exact selected device and opens a signed, stable-path probe using only the
   approved certificate from `docs/release/signing.md`;
2. selects a real browser window with a static page, a low-change page, and active scrolling;
3. performs camera-only and camera/browser runs for all three shapes, including pause/resume and
   physically disconnecting the exact selected camera; and
4. enters the administrator password once for `powermetrics` so CPU/GPU/ANE/power and thermal
   samples can be bound to the same manifest.

The Mini's CuaDriver PID 12083 and Screen Sharing PID 9243 were present before and after the
native run. The 15 prototype-owned render PIDs are recorded in `processes.tsv`; all exited 0,
and none remains live.

## Live-run executable readiness

The branch now also contains an actual-hardware `live-cadence-probe`; its results are not mixed
with the synthetic evidence above. It selects a real `AVCaptureVideoDataOutput` camera by exact
stable device ID and an optional real ScreenCaptureKit window by exact `SCWindow.windowID`.
Screen frames have no raw-cache API: the callback copies the pixel buffer, runs the production
`WindowCapturePrivacy` matte algorithm, verifies opaque/sentinel-free exterior pixels, and only
then constructs the type accepted by `LiveFrameCache`. Camera-driven and fixed-clock triggers
compose the live buffers through Metal-backed Core Image into a real-time H.264 writer; system
audio and microphone inputs are separate real-time AAC tracks when explicitly requested and
already authorized.

The live metrics schema includes exact camera/window IDs, callback cadence and p95 jitter,
camera latency, browser age, A/V endpoint drift, writer readiness/drops, pause/resume,
disconnect reason, monotonicity, privacy scans, CPU/RSS/thermal, runtime certificate chain/TCC
state, and a predeclared external-powermetrics path. The tool does not invoke `sudo`, request
TCC, silently omit requested audio, substitute a display, or switch cameras.

This preparation does not close the physical gate. Until a camera is present and Tim performs
the signed run, all live metric fields remain unmeasured.

The unsigned-safe Mini gate at source checkpoint `75d3a354fb924700f00ca2f562c0deab0203ce5c`
passed its warnings-as-errors Release build, 3/3 selection/fail-closed tests, static
desktop-filter/TCC/privacy checks, and unsigned app-bundle build. Live inventory reported zero
cameras. The missing-camera preflight exited 20, its machine report recorded zero privacy
sentinel pixels and `outputCreated: false`, and the requested movie path did not exist. Screen
preflight authorization was false, so window enumeration was skipped without requesting access;
no Screen Sharing source was substituted.

The same Mini check found one identity with the approved common name but zero certificates with
the approved `189EC9780DE0A94CF5B24CC5983CAB3FDAE15638` fingerprint and one identity beginning
with the prohibited `45F21D` prefix. No signing was attempted. CuaDriver PID 12083 and Screen
Sharing PID 9243 were present before and after; the two owned verification/build process PIDs
exited 0 and are recorded with timestamps.
