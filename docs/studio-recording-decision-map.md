# Studio recording decision map

- **Parent:** [#43 — STUDIO DECISION MAP: Lighting-aware camera and browser recording](https://github.com/timharris707/grab-rabbit/issues/43)
- **Decider:** Tim Harris
- **Weight:** Deep fog. The remaining questions change the platform floor, foreground contract,
  render clock, cloud boundary, and measurable quality envelope, so they must resolve as
  dependency-wired gate tickets before Studio production work is specified.

## Destination

Grab Rabbit has a fully recorded, evidence-backed decision set for a production-quality solo
Studio mode: camera-only and camera-plus-screen/window/browser recording, first-class
Continuity Camera, lighting-aware generated backgrounds, local live compositing, privacy and
failure boundaries, output layouts, and a measurable quality contract. At that point every
remaining implementation unit can be specified as ordinary dependency-wired GitHub work
without silently deciding a product, privacy, platform, or architecture question inside a
build slice.

## Decision-record provenance

This map reconstructs the complete 2026-08-16 Studio discussion from the read-only T3
projection thread `cea24fa4-8cde-45e7-9b34-1eebc69dc9e3`: 54 completed messages from
17:16:07Z through 18:27:54Z. The record distinguishes three kinds of statement:

- Tim's feature request, corrections, and explicit approvals are **decisions**.
- Assistant recommendations became decisions only where Tim explicitly approved them.
- The assistant's research synthesis remains a set of **claims to verify** unless the current
  repository or a cited primary source independently proves it.

The original request was for self-recorded video comparable to the solo-camera experience in
Zoom or FaceTime, smart AI-designed backgrounds that use the user's current lighting to look
real, capture of the user's live camera while navigating a web page, and the iPhone as a
first-class webcam option. Tim asked for research into the desired features, existing products,
reusable technology, and integration shape before grilling and decision mapping.

## Current-code pins

These pins describe commit `67a2ff8719d855436a0219571f02ad55b2151b16`, the map's survey
baseline. They are evidence of what exists, not approval to reuse an interface unchanged.

| Current fact | Evidence and consequence |
|---|---|
| Camera devices already feed `AVCaptureSession` paths and floating previews. | `QuickRecorder/AVContext.swift:13-49` configures the camera-overlay video-data output; its delegate callback runs, but the frame-processing body is reserved/commented out. The separate mobile-device preview at `QuickRecorder/AVContext.swift:52-68` has an active no-op sample callback. Studio needs a real frame-consumer path rather than capturing either preview window. |
| Camera selection already discovers built-in and external video devices. | `QuickRecorder/SCContext.swift:785-788` uses `AVCaptureDevice.DiscoverySession`; `QuickRecorder/ViewModel/CameraOverlayer.swift:138-199` exposes the devices. The Tahoe research must prove the exact Continuity Camera discovery contract rather than assuming every external device is an iPhone. |
| The existing “mobile device” path is different from a webcam path. | `QuickRecorder/SCContext.swift:800-803` discovers muxed external devices, while `QuickRecorder/AVContext.swift:64-149` records them through `AVCaptureMovieFileOutput`. It must not be relabeled as Continuity Camera. |
| The floating camera overlay cannot satisfy camera-plus-single-window capture. | `QuickRecorder/ViewModel/CameraOverlayer.swift:119-126` tells users it is unavailable for a single window. `QuickRecorder/RecordEngine.swift:166-176` includes the overlay only in a multi-window filter and uses a desktop-independent filter for one window. |
| The current video writer is driven by ScreenCaptureKit video callbacks. | `QuickRecorder/WindowCapturePrivacy.swift:902-1010` sanitizes and appends each complete screen sample. `QuickRecorder/RecordEngine.swift:347-355` already records the important cadence warning: ScreenCaptureKit may emit frames only when content changes. A moving camera can therefore freeze over a static page unless Studio owns a render clock. |
| Recording sessions already bind screen video, system audio, microphone audio, a writer, and callback lifetime. | `QuickRecorder/RecordEngine.swift:438-501` constructs `CaptureOutputSession`; `QuickRecorder/WindowCapturePrivacy.swift:788-845` owns the corresponding resources. Studio must preserve the existing fail-closed lifetime and A/V ownership guarantees. |
| The writer already supports H.264/HEVC, real-time inputs, network optimization, and safe output reservation. | `QuickRecorder/RecordEngine.swift:695-799` creates the output and inputs. `QuickRecorder/RecordingOutputJob.swift:81-143` already models single, remux, conversion, and package layouts, but no Studio editable-package schema has been decided. |
| Camera and microphone entitlements already exist. | `QuickRecorder/QuickRecorder.entitlements:5-8` enables audio input and camera access. This does not prove that Vision, depth, Apple video effects, or arbitrary foreground-object masks are available to the app. |
| The app and tests still target macOS 12.3 and do not declare an arm64-only product. | `QuickRecorder.xcodeproj/project.pbxproj:434-454` and `:595-650` contain the current deployment settings. The installed survey environment is arm64 macOS 26.5.2 with Xcode 26.6 / SDK 26.5, but one installed SDK cannot establish the earliest supported point release. |
| No current production or test source imports Vision, Core Image, or Metal. | Repository-wide source search at the survey commit found no imports or foreground-matting implementation. The feature is new even though capture and writer foundations exist. |

## Settled-decision index

The question text below preserves the wording that Tim saw. Where the recommendation is
summarized, it is the recommendation Tim explicitly approved. A later ruling is called out
instead of silently rewriting the earlier record.

### Q1 — Product boundary

**Question:** Should the first destination be a solo recording studio—camera-only and
camera-plus-screen/window/browser—not a multi-person calling system like FaceTime or Zoom?

**Approved recommendation:** Yes. Calling, conferencing, and participant infrastructure would
multiply the scope without being necessary for excellent self-recorded video.

### Q2 — “Live streaming” meaning

**Question:** Do you mean continuously recording your live camera while you navigate a webpage,
or broadcasting live to services such as YouTube, Twitch, or another destination?

**Approved recommendation:** Recorded camera-plus-browser composition comes first. Actual
broadcasting should be a separate later decision because it adds accounts, network failure
handling, latency, and stream moderation.

### Q3 — Realism contract

**Question:** Should “Make It Look Real” preserve the person’s genuine camera image while
matching the generated background to measured lighting—direction, brightness, color
temperature, contrast, depth-of-field, edge treatment, and plausible shadows?

**Approved recommendation:** Yes. Avoid generatively reconstructing the person. That gives Grab
Rabbit a concrete quality target while preserving identity and natural motion.

### Q4 — AI privacy boundary

**Question:** May Grab Rabbit send one explicitly approved, reduced-resolution reference frame
to a cloud AI service to design the background, provided live video remains on-device and the
reference is not retained?

**Approved recommendation at the time:** Use the reference frame as an opt-in default, with a
clear preview of what is sent. Continuous camera streaming to the AI provider is prohibited.
Q13 later narrowed the normal path further: text only leaves the Mac unless a still is
separately approved and proven better.

### Q5 — Background direction

**Question:** Should users describe the setting they want, while Grab Rabbit automatically
handles lighting realism, or should the application invent the entire setting with no direction?

**Approved recommendation:** Hybrid. The user chooses or describes the scene; Grab Rabbit
analyzes the camera image and applies the realism constraints automatically.

### Q6 — iPhone support

**Question:** Is native Apple Continuity Camera sufficient for the first milestone, with a
custom Grab Rabbit iPhone companion application explicitly deferred?

**Approved recommendation:** Yes. The iPhone should appear as a first-class camera option
through Apple’s native path; building and maintaining a separate iOS capture stack should
require a demonstrated gap.

### Unnumbered platform-floor ruling between Q6 and Q8

No Q7-labelled prompt appears in the stored thread, so this map does not invent one. Tim
explicitly approved raising Grab Rabbit's planning floor to **macOS Tahoe 26** to prioritize the
latest Apple technology over backward compatibility. The exact point-release floor—26.0 or a
later Tahoe release required by a chosen API—remains open.

### Q8 — Hardware floor

**Question:** Should Grab Rabbit also become Apple-silicon-only?

**Approved recommendation:** Yes. It aligns with the cutting-edge goal and gives Grab Rabbit
predictable Neural Engine, Metal, Presenter Overlay, and video-effect performance. Tim chose
Apple silicon to simplify the product and make first-class use of Apple’s newest technology.
The research gate must still distinguish a product choice from APIs that technically require
Apple silicon.

### Q9 — Output package

**Question:** Should every recording produce a ready-to-share composite, with an optional
editable package containing the clean screen, raw camera, generated background, and separate
audio sources?

**Approved recommendation:** Yes, with editable sources off by default to avoid clutter.

### Q10 — Initial layouts

**Question:** Which layouts must ship first?

**Approved recommendation:** Selectable 16:9, vertical 9:16, and square camera canvases, plus a
movable/resizable picture-in-picture camera over browser capture. Defer side-by-side and live
scene switching.

### Q11 — Foreground scope

**Question:** What must survive background removal besides the primary person?

**Original recommendation:** One person plus hair, glasses, clothing, and worn or held objects.
Don’t initially guarantee furniture, pets, or additional people.

**Tim's refinement:** Chair back and a Shure microphone are quality-gated soft goals, not hard
requirements. Retain either only when it stays visually stable. Quality wins: a clean
person-only matte is preferable to a chair or microphone that flickers, is partly cut off, or
disappears and returns. The effect may depend on camera source; primary-source research and a
focused real-camera prototype must establish what is actually supportable.

### Q12 — Lighting changes

**Question:** Should Grab Rabbit generate the background once, then continuously adjust its
exposure, color, and contrast locally as room lighting changes?

**Approved recommendation:** Yes. No cloud calls or background regeneration during recording.

### Q13 — Privacy refinement

**Question:** Should the normal path analyze the approved frame locally and send only a textual
lighting description to the image generator, with actual still upload available only when
explicitly approved and demonstrably better?

**Approved recommendation:** Yes. This strengthens the earlier privacy decision while
preserving the higher-quality option. The normal path sends no camera pixels; any still upload
is separately approved and must first show a quality advantage.

### Q14 — Browser operation

**Question:** Is first-release webpage navigation manual, with AI-controlled browser tours
deferred?

**Approved recommendation:** Yes. Browser automation is a distinct product involving scripting,
safety, and editing decisions.

### Q15 — Failure behavior

**Question:** If the selected iPhone disconnects or Studio processing fails, should recording
visibly pause or stop rather than switching cameras or dropping effects?

**Approved recommendation:** Yes. “Record without background” can be an explicit choice before
starting, never a silent mid-record fallback.

### Q16 — Apple effects

**Question:** In Studio mode, should Apple Background Replacement and Presenter Overlay be
required off, while Center Stage and Studio Light may remain on only when selected before
lighting calibration?

**Approved recommendation:** Yes. This prevents double processing and keeps the lighting
reference stable.

## Recovered research synthesis: claims, not decisions

The locked session reported the following synthesis. It is retained so research lanes do not
start from zero, but it is not promoted into fact without the evidence named below.

| Session claim or recommendation | Current treatment |
|---|---|
| [Zoom](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0060387), [Google Meet](https://support.google.com/meet/answer/13954947), and [Teams](https://support.microsoft.com/en-us/teams/meetings/change-your-background-in-microsoft-teams-meetings) document generated/decorated backgrounds, but the session found no documented coupling from observed lighting through generation to live harmonization. | Differentiation hypothesis only. Product documentation is not proof that no competing implementation exists, and market novelty is not required to build. |
| [Google Studio Lighting](https://support.google.com/meet/answer/13948742) and [Camo Spotlight](https://camo.com/support/camo/adjusting-video-settings) document subject-lighting adjustments, while generated backgrounds remain a separate feature. | Market-context claim only; it helps frame the desired integration but does not select an implementation. |
| Loom, Riverside, and Descript were reported to offer camera-only, camera-plus-screen, and/or editable source-track workflows without the complete lighting-aware generation loop. | Market-context claim only. Primary product research would be needed if parity details later affect a product decision. |
| [Apple video effects](https://support.apple.com/en-us/105117) provide Presenter Overlay, Studio Light, and system background replacement, but the session reported that an app cannot programmatically supply its generated image to Apple's system background feature. | The user-facing feature list is primary context; app controllability and integration remain platform-research questions. |
| [Google Total Relighting](https://research.google/pubs/total-relighting-learning-to-relight-portraits-for-background-replacement/) demonstrates that portrait/background relighting is a recognized technical problem, but the session found no drop-in production implementation for Grab Rabbit. | Research context, not a reusable-code decision. |
| Native Continuity Camera, Vision person segmentation, Core Image/Metal, and common media clocks provide the foundation; no custom iPhone app is needed. | Plausible and consistent with the approved direction, but exact APIs, availability, behavior, and point-release floor belong to the platform research ticket. |
| Foreground-instance masking may support arbitrary objects; person segmentation may be temporally stable; optical flow or object tracking may help chair/microphone stability. | Unverified Q11 hypotheses. They belong to the foreground primary-source research ticket and cannot become a support guarantee without the real-camera prototype. |
| macOS does not expose iPhone depth, portrait mattes, sensor ISO, exposure, or white-balance readings through this capture path, so lighting must be inferred from pixels. | Material architecture claim requiring Apple primary-source verification. |
| The largest integration risk is render cadence because a ScreenCaptureKit-driven compositor can freeze a moving camera over an unchanged webpage. | The current source confirms the callback-driven shape and its cadence warning; the correct fixed/camera/hybrid clock remains a prototype question. |
| Preserve the current no-camera recorder; add a native Studio compositor using camera + matte + generated background + optional sanitized browser frame; generate before recording; keep segmentation, edge treatment, lighting adaptation, and composition local; never silently substitute a source/effect. | Assistant architecture recommendation. Q12 and Q15 independently settle the pre-generation/local-live/fail-closed boundaries, but the isolated compositor and frame ownership remain technical decisions the cadence/privacy prototype must earn. |
| The repo's proven OpenRouter `gpt-image-2` CLI route can generate images. | Proven only for agent-run development artifacts by `docs/agents/openrouter-image-generation.md`; it does not establish a distributable product credential, provider, retention, billing, or model contract. |

## Deep-fog clusters

### A. Exact Tahoe and Apple-silicon API floor

**Question.** Which exact Tahoe point release and required API set support Continuity Camera
discovery, foreground extraction/tracking, local composition, video-effect preflight, and
real-time writing? Which requirements are API availability, and which are only performance or
product-floor choices?

**Why foggy.** The project targets 12.3, contains no matting implementation, and is being
surveyed with only the 26.5 SDK. Raising the target blindly to the installed SDK would confuse
local availability with the earliest supportable release.

| Option | Cost / risk |
|---|---|
| Set 26.0 + arm64 if every required primitive is available there. | Widest Tahoe reach, but may force workarounds or omit a later API that materially improves quality. |
| Set the earliest later 26.x release required by the chosen primitives. | Smaller audience, but an honest compile/runtime contract with less compatibility code. |
| Keep 26.0 by substituting an older primitive for a later convenience API. | Preserves reach at the cost of more code or lower quality; acceptable only if evidence shows the trade is worthwhile. |

**Gates.** Deployment settings, availability checks, camera discovery, foreground prototype,
render prototype, effect preflight, and every later Studio build brief.

**Ticket.** [#44 — STUDIO RESEARCH: Pin the Tahoe API and hardware floor](https://github.com/timharris707/grab-rabbit/issues/44)

### B. Q11 native and reusable foreground feasibility

**Question.** What can Tahoe APIs actually segment and track beyond one person, what camera or
depth data is exposed, and what reusable non-Apple model could legally and operationally fill a
gap for chair backs and microphones?

**Why foggy.** The transcript contains plausible API names but no durable primary-source
findings. “Foreground object,” “person matte,” “depth,” and “stable real-time tracking” are not
interchangeable capabilities.

| Option | Cost / risk |
|---|---|
| Native person matte only. | Lowest runtime and integration risk; cannot satisfy the soft chair/microphone goal when they fall outside the person mask. |
| Native foreground-instance/object mask plus temporal tracking. | Potentially retains arbitrary objects, but selection, instance identity, performance, and temporal behavior are unknown. |
| Person matte plus a reusable custom model/tracker. | May improve object semantics but adds model size, licensing, update, Neural Engine/Metal, and failure-surface costs. |

**Gates.** Which candidates enter the real-camera prototype and whether camera-source/depth
differences are meaningful test dimensions.

**Ticket.** [#45 — STUDIO RESEARCH: Establish chair and microphone foreground feasibility](https://github.com/timharris707/grab-rabbit/issues/45)

**Verdict.** Require a native person-only baseline and class-agnostic foreground-instance
comparison on shared camera clips; Apple does not promise chair/microphone semantics,
cross-frame identity, live depth, portrait/semantic matte delivery, or calibration, so SAM 2.1
Tiny remains a conditional prompted challenger after native failure and explicit download
approval. [Cited findings](research/studio-foreground-feasibility.md)

### C. Q11 chair-back and Shure-microphone support envelope

**Question.** On real camera feeds, can any researched path retain Tim's chair back and Shure
microphone without flicker, partial disappearance, objectionable edges, or unacceptable latency?

**Why foggy.** Q11 explicitly makes visual quality—not theoretical segmentation capability—the
decider. This question must be seen across motion, occlusion, lighting, and available camera
sources. A single still is insufficient.

| Option | Cost / risk |
|---|---|
| Guarantee neither; ship a person-only matte. | Predictable baseline but preserves the floating-person and invisible-microphone defects Tim wants investigated. |
| Include each object only after preflight passes a stable quality threshold. | Matches the approved soft-goal contract, but requires measurable thresholds and a truthful pre-recording preview. |
| Expose an explicit user-assisted object selection when automatic inclusion is stable enough. | More control and complexity; still cannot excuse flicker or a silent mid-record fallback. |

**Gates.** Supported-foreground matrix, calibration/preflight UX, mask quality thresholds, and
the production segmentation/tracking choice.

**Ticket.** [#47 — STUDIO PROTOTYPE: Test chair and Shure microphone foreground stability](https://github.com/timharris707/grab-rabbit/issues/47)

### D. Studio render clock, privacy boundary, and A/V quality

**Question.** Should the compositor be fixed-clock, camera-driven, or hybrid, and can that path
keep a moving camera fluid over a static browser while preserving sanitized-window pixels,
monotonic timestamps, microphone/system-audio sync, and writer backpressure behavior?

**Why foggy.** The existing writer appends screen callbacks. Studio adds an independently moving
camera and substantial local processing; the wrong clock reshapes writer ownership, buffering,
pause/resume, and failure interfaces.

| Option | Cost / risk |
|---|---|
| ScreenCaptureKit-driven. | Smallest change, but risks frozen camera motion over static pages and cannot satisfy the destination unless tests disprove that risk. |
| Camera-driven using the latest sanitized browser frame. | Naturally preserves camera motion, but must define screen-frame staleness, output cadence, and audio-master alignment. |
| Fixed render clock with latest camera and sanitized browser frames. | Most explicit cadence contract and layout control, but adds scheduling, duplication, backpressure, and resource cost. |
| Hybrid clock with explicit staleness/wakeup policy. | May balance efficiency and fluidity, but has the largest state-machine surface and needs strong regression tripwires. |

**Gates.** Studio compositor interfaces, frame ownership, pause/stop semantics, performance
budget, output resolution/fps envelope, and regression strategy for static browser pages.

**Ticket.** [#48 — STUDIO PROTOTYPE: Prove render cadence, privacy, and A/V sync](https://github.com/timharris707/grab-rabbit/issues/48)

### E. Production image-generation and privacy route

**Question.** Which production-capable provider/model and credential/service boundary can turn
the user scene direction plus textual lighting profile into a background while honoring Q4 and
Q13, and what primary-source retention, training, regional, billing, and availability terms
apply?

**Why foggy.** A local development CLI with Tim's key is not a shippable product contract. The
decision changes network architecture, disclosures, secrets, failure handling, and recurring
cost.

| Option | Cost / risk |
|---|---|
| Direct provider call with a user-supplied key. | Avoids a Grab Rabbit backend and centralized spend, but creates difficult onboarding and provider coupling. |
| Managed Grab Rabbit service. | Smoothest user experience and centralized policy enforcement, but adds backend operations, abuse controls, billing, and custody risk. |
| On-device generation. | Strongest privacy and offline story, but model size, latency, quality, and distribution feasibility are unproven. |

**Gates.** Product privacy disclosure, credential ownership, generator interface, offline/error
behavior, and which routes may enter the visual prototype. No provider choice is implied here.

**Ticket.** [#46 — STUDIO RESEARCH: Define the production image-generation and privacy route](https://github.com/timharris707/grab-rabbit/issues/46)

### F. Lighting-profile realism and optional-still advantage

**Question.** Can a textual lighting profile plus local harmonization meet the “Make It Look
Real” contract, and does an explicitly approved reduced-resolution still produce a large enough
quality improvement to justify offering that optional path?

**Why foggy.** Q3 defines a visual outcome and Q13 requires a demonstrated advantage before
camera pixels may be offered as input. Neither can be decided from API documentation or a
single generated image.

| Option | Cost / risk |
|---|---|
| Text profile only, then local exposure/color/contrast adaptation. | Best default privacy; may provide insufficient spatial lighting cues unless prompt and local processing are strong. |
| Text default plus separately approved low-resolution still when proven better. | Preserves the approved privacy hierarchy but adds consent, preview, retention verification, and two quality paths. |
| On-device image-conditioned generation or transformation. | Could keep pixels local, but feasibility and quality depend on the production route research. |

**Gates.** Lighting-profile schema, calibration samples, prompt/generator contract, local
adaptation scope, optional-still product decision, and the measurable realism acceptance set.

**Ticket.** [#49 — STUDIO PROTOTYPE: Validate lighting-profile realism and optional still input](https://github.com/timharris707/grab-rabbit/issues/49)

## Dependency graph and resolution order

The graph is deliberately evidence-first. Research lanes may run in parallel. A prototype does
not start until the facts that shape its candidates are recorded; native dependency edges, not
`blocked` labels, carry these relationships.

| Work | Native `blocked by` edges | Directly blocks |
|---|---|---|
| [#44 — Tahoe/API research](https://github.com/timharris707/grab-rabbit/issues/44) | None | [#47](https://github.com/timharris707/grab-rabbit/issues/47), [#48](https://github.com/timharris707/grab-rabbit/issues/48), [#49](https://github.com/timharris707/grab-rabbit/issues/49) |
| [#45 — Foreground research](https://github.com/timharris707/grab-rabbit/issues/45) | None | [#47](https://github.com/timharris707/grab-rabbit/issues/47) |
| [#46 — Generation-route research](https://github.com/timharris707/grab-rabbit/issues/46) | None | [#49](https://github.com/timharris707/grab-rabbit/issues/49) |
| [#47 — Q11 foreground prototype](https://github.com/timharris707/grab-rabbit/issues/47) | [#44](https://github.com/timharris707/grab-rabbit/issues/44), [#45](https://github.com/timharris707/grab-rabbit/issues/45) | [#43](https://github.com/timharris707/grab-rabbit/issues/43) |
| [#48 — Cadence/A/V/privacy prototype](https://github.com/timharris707/grab-rabbit/issues/48) | [#44](https://github.com/timharris707/grab-rabbit/issues/44) | [#43](https://github.com/timharris707/grab-rabbit/issues/43) |
| [#49 — Lighting realism prototype](https://github.com/timharris707/grab-rabbit/issues/49) | [#44](https://github.com/timharris707/grab-rabbit/issues/44), [#46](https://github.com/timharris707/grab-rabbit/issues/46) | [#43](https://github.com/timharris707/grab-rabbit/issues/43) |
| [#43 — Parent map](https://github.com/timharris707/grab-rabbit/issues/43) | [#47](https://github.com/timharris707/grab-rabbit/issues/47), [#48](https://github.com/timharris707/grab-rabbit/issues/48), [#49](https://github.com/timharris707/grab-rabbit/issues/49) | None |

Suggested most-gating-first order:

1. Run [#44](https://github.com/timharris707/grab-rabbit/issues/44), [#45](https://github.com/timharris707/grab-rabbit/issues/45), and [#46](https://github.com/timharris707/grab-rabbit/issues/46) in parallel.
2. Run [#48](https://github.com/timharris707/grab-rabbit/issues/48) after the platform findings.
3. Run [#47](https://github.com/timharris707/grab-rabbit/issues/47) after both platform and foreground findings, using the Mac
   Mini as the host whenever the required camera/scene can be made available there.
4. Run [#49](https://github.com/timharris707/grab-rabbit/issues/49) after platform and generation-route findings, with explicit
   approval before any real camera still leaves the Mac.
5. Write each outcome back into this map, graduate the ledger below into the smallest final
   adjudication tickets, and close [#43](https://github.com/timharris707/grab-rabbit/issues/43) only after both the live frontier and ledger are empty.

## Not yet specified

These are in-scope questions whose final ticket shape depends on the research/prototype
outcomes above. They must graduate into gate tickets or be resolved by an existing child before
the map closes.

- **Measurable Studio quality envelope:** supported resolution/fps combinations, sustained
  compositor latency, A/V drift, dropped/stalled frame limits, mask-stability/flicker threshold,
  edge-quality review set, and resource ceiling. Depends on the three prototypes.
- **Foreground support matrix and preflight:** which camera/scene combinations may offer chair
  or microphone inclusion, how a failed preflight communicates person-only fallback before
  recording, and whether manual object selection is justified. Depends on the Q11 prototype.
- **Production generator contract:** provider/model, credential owner, billing boundary,
  retention/training/region disclosure, model-version pinning, and whether the optional still
  path ships at all. Depends on generation research and the lighting prototype.
- **Lighting calibration flow:** what frame is “approved,” how the user previews the textual
  profile and generated scene, what is locked before recording, and how Center Stage or Studio
  Light changes force recalibration. Depends on platform and lighting findings.
- **Editable package contract:** package extension/schema, names and codecs for clean screen,
  raw camera, generated background, and audio sources, plus atomic publication and partial
  failure behavior. Depends on the selected compositor and quality envelope; Q9 already fixes
  that the composite is always produced and editable sources default off.
- **Visible failure taxonomy:** which failures may visibly pause and recover, which must stop,
  and what happens to an already reserved output. Q15 settles fail-closed behavior but the
  tested compositor state machine must supply the recoverability facts.

## Out of scope

### Tim-decided product boundaries

These rulings are beyond this destination; they do not graduate into tickets without a new
decision from Tim.

- Multi-person calling, conferencing, or participant infrastructure — Q1.
- Broadcasting to YouTube, Twitch, or other streaming destinations — Q2.
- Generatively reconstructing or replacing the person — Q3.
- Continuous camera/video upload to an AI provider — Q4 and Q13.
- A custom Grab Rabbit iPhone companion/capture stack without a demonstrated native gap — Q6.
- Side-by-side scenes and live scene switching in the first release — Q10.
- Guaranteed pets, second people, or furniture beyond the quality-gated chair-back goal — Q11.
- Cloud calls or background regeneration during recording — Q12.
- AI-controlled browser tours in the first release — Q14.
- Silent camera substitution, silent effect removal, or silent background fallback — Q15.
- Apple Background Replacement or Presenter Overlay inside Studio mode — Q16.

### Repository and parent-scope constraints

These constraints apply existing repository policy and the accepted parent scope; they are not
additional Studio product decisions attributed to Tim.

- Reworking the existing no-camera recorder as part of this decision map. Studio integration
  must preserve its accepted privacy and reliability behavior unless a later tracked decision
  explicitly changes it.
- Production implementation, release signing, notarization, distribution, or any outward-facing
  release. Those become ordinary tracked work only after the map closes and remain subject to
  the repository's existing release gates and Tim's explicit release approval.

## Map-close gate

The map is not done merely because this document exists. Each child ticket must carry its
evidence/verdict, and each resolved cluster in this document must retain its ticket pointer
alongside a one-line outcome. Every entry under **Not yet specified** must graduate or be
resolved, native dependencies must show an empty frontier, and only then may [#43](https://github.com/timharris707/grab-rabbit/issues/43) close and PR-sized production slices be filed.
