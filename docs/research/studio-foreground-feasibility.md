# Studio foreground feasibility

_Research date: 2026-08-16 · Driving ticket:
[#45 — STUDIO RESEARCH: Establish chair and microphone foreground feasibility](https://github.com/timharris707/grab-rabbit/issues/45)_

## Verdict

**One-line verdict:** Tahoe has a stateful person matte and per-image, class-agnostic
foreground-instance masks, but Apple documents neither chair/microphone semantics nor stable
instance identity across frames, and the public macOS capture path exposes no live depth,
portrait matte, or camera-calibration stream; the real-camera prototype must keep a native
person-only baseline, test native foreground instances, and use SAM 2.1 Tiny only as a
conditional prompted-video challenger.

This is a feasibility verdict, not a support promise. Tim's ruling remains controlling: the
chair back and Shure microphone are quality-gated soft goals. A clean person-only matte wins
over either object flickering, being partly cut off, or disappearing and returning. This
research does not choose a visual threshold.

## Evidence boundaries

The labels below are used deliberately:

- **Sourced fact** is stated by an Apple public document, an exact installed public SDK
  declaration, or the pinned upstream repository/model card/license.
- **Inference** follows from sourced facts but is not itself an API or model guarantee.
- **Prototype hypothesis** is a path worth measuring on real camera material.
- **Unresolved product judgment** belongs to Tim, the repository's recorded decider.

The Apple declaration audit used Xcode 26.6 (build `17F113`) and
`MacOSX26.5.sdk`. Public documentation sometimes describes the Swift-native Vision API first;
the exact SDK ledger at the end records both that API and the older `VN*` declarations where
the header contains behavior not repeated on the web page. Inline code labels such as `SDK V1`
resolve to rows in that ledger.

## What each primitive actually represents

| Primitive | Exact input and output | Video and temporal contract | Q11 consequence |
|---|---|---|---|
| Person segmentation | **Sourced fact:** `GeneratePersonSegmentationRequest` takes an image/frame and returns one `PixelBufferObservation` matte. The SDK permits one-component 8-bit, half-float, or 32-bit-float output. It does not return semantic labels or per-object IDs. Apple documents `accurate`, `balanced`, and `fast`; the exact header says accurate adds matting refinement, balanced is high accuracy, fast is low accuracy for streaming on Neural Engine devices, and the request may retain earlier masks for temporal stability. [Apple person segmentation][apple-person] `SDK V1` | **Sourced fact:** it is a `StatefulRequest`; the current initializer accepts `frameAnalysisSpacing`. Apple gives no fixed supported input resolution, output dimensions, FPS, latency, or dropped-frame guarantee. [Apple person segmentation][apple-person] `SDK V1` | Required person-only baseline. Hair, glasses, clothing, held objects, chair backs, and microphones are not separately promised by the declaration; their actual inclusion and edges remain visual evidence. |
| Person-instance mask | **Sourced fact:** `GeneratePersonInstanceMaskRequest` returns an `InstanceMaskObservation` whose nonzero pixel values index individual people. It identifies people, not furniture or microphones. [Apple person instances][apple-person-instance] `SDK V2` | **Sourced fact:** it is an `ImageProcessingRequest`, not a `StatefulRequest`. It can be invoked on successive frames, but Apple documents no cross-frame identity or stability. `SDK V2` | It adds no documented chair/microphone capability in the one-person scenario, so it is not a separate minimal prototype candidate. |
| Foreground-instance mask | **Sourced fact:** `GenerateForegroundInstanceMaskRequest` returns an `InstanceMaskObservation` for noticeable/salient foreground objects. Pixel value 0 is background; other values are per-image instance indexes. Callers can request a low-resolution selected-instance mask or a scaled high-resolution mask/image. Apple supplies no class name for an instance. [Apple foreground instances][apple-foreground] [Apple instance observation][apple-instance-observation] `SDK V3` | **Sourced fact:** it is an `ImageProcessingRequest`, not a `StatefulRequest`; the SDK does not promise that index `n` denotes the same object in the next frame. No numeric analysis resolution, cadence, or latency is documented. `SDK V2` `SDK V3` | This is the only native mask that could include a chair or microphone as its own foreground instance, but documentation cannot prove either object will be noticeable, selected, complete, or temporally stable. |
| Attention saliency | **Sourced fact:** `GenerateAttentionBasedSaliencyImageRequest` produces a grayscale heat map of image regions likely to attract human attention, plus bounding rectangles for heat-map modes. [Apple attention saliency][apple-attention-saliency] `SDK V4` | **Sourced fact:** per-image request; no mask identity or temporal state is documented. | Not an alpha matte, semantic detector, or tracker. It might seed a region proposal, but that is only a prototype hypothesis and does not identify a microphone or chair. |
| Objectness saliency | **Sourced fact:** `GenerateObjectnessBasedSaliencyImageRequest` produces a heat map of regions likely to represent objects, plus bounding rectangles. [Apple objectness saliency][apple-objectness-saliency] `SDK V4` | **Sourced fact:** per-image request; no temporal state is documented. | Not a per-pixel object-instance matte and not a semantic label. It is not a standalone Q11 candidate. |
| Object tracking | **Sourced fact:** `TrackObjectRequest` takes an already identified object's bounding observation and updates that bounding box through multiple images/video frames. It is a stateful general-purpose tracker. [Apple object tracking][apple-object-tracking] `SDK V5` | **Sourced fact:** temporal bounding-box tracking; no per-pixel mask is produced. | It could help follow a user-selected chair or microphone region, but cannot repair or propagate a matte by itself. |
| Optical flow | **Sourced fact:** `TrackOpticalFlowRequest` returns per-pixel directional change from the previous image to the current image. Images must have equal dimensions. Apple calls optical flow very resource intensive and says to perform one request at a time and release its memory promptly. [Apple optical flow][apple-optical-flow] `SDK V6` | **Sourced fact:** the current request is stateful and supports frame spacing plus low/medium/high/very-high computation accuracy. It carries motion vectors, not object identity or semantics. `SDK V2` `SDK V6` | Warping a prior chair/microphone mask with flow is a prototype hypothesis, not a documented stability feature. It should be added only if the raw native mask shows a specific temporal failure worth isolating. |
| Scene depth/disparity | **Sourced fact:** `AVCaptureDepthDataOutput` would deliver streaming `AVDepthData`, but the class, `activeDepthDataFormat`, and `supportedDepthDataFormats` are all explicitly `API_UNAVAILABLE(macos)` in the 26.5 SDK. [Apple depth output][apple-depth] `SDK A2` | No public live macOS depth stream exists through this capture API for built-in, USB, or Continuity Camera. | Depth is not an input dimension for the minimum macOS prototype. This does not assert that Apple's private ISP/effects never use depth; it says the app is not given the documented live depth product. |
| Portrait-effects and photo semantic mattes | **Sourced fact:** macOS can read/write `AVPortraitEffectsMatte` and `AVSemanticSegmentationMatte` auxiliary images from files, but `AVCapturePhotoOutput` delivery for depth, portrait mattes, and semantic mattes is explicitly unavailable on macOS. Even where capture exists, these are photo APIs; the named semantic mattes are skin, hair, teeth, and glasses, not chairs or microphones. [Apple portrait matte capture][apple-portrait] [Apple semantic matte capture][apple-semantic-matte] `SDK A3` | No documented live-video delivery on macOS. | They cannot supply the Studio live foreground contract. The system Portrait effect exposes an altered camera image/effect state, not its internal matte. [Apple Continuity sample][apple-continuity] |
| Semantic object detection | **Sourced fact:** a symbol/name audit of the 26.5 public Vision request inventory found no built-in chair or microphone detector. AVFoundation's public capture metadata types name humans, faces, cats, dogs, salient objects, and codes; a salient object has bounds/ID but no chair/microphone class. A custom detector would enter through a custom Core ML/Vision model. [Apple Vision Core ML][apple-coreml] `SDK V7` `SDK A7` | Model-specific. `AVMetadataObject.objectID` persists while a detected object remains in the scene, but an object that exits and re-enters receives a new ID; the output is bounds/metadata, not a matte. [Apple metadata object ID][apple-metadata-id] `SDK A7` | Native APIs cannot automatically name which class-agnostic foreground instance is Tim's chair or microphone. Automatic semantic selection would require a separately licensed model; user/preflight selection is an unresolved product judgment. |

### What “works on video” does and does not mean

**Sourced fact:** all current Swift `ImageProcessingRequest` values can be performed on a
`CMSampleBuffer`/`CVPixelBuffer`, so an app may submit successive camera frames. Only the
requests declared `StatefulRequest` have a documented temporal contract; submitting every
frame to a stateless request does not create stable identities. `SDK V2`

**Inference:** foreground-instance labels must therefore be matched, unioned, or reselected by
client logic on every frame. Bounding-box tracking or optical flow may help that client logic,
but neither turns a class-agnostic per-frame result into a documented chair/microphone mask.

## Compute, resolution, cadence, and production availability

| Area | Recorded fact | What remains unknown |
|---|---|---|
| Compute devices | **Sourced fact:** every current Vision request conforms to `VisionRequest`, whose `supportedComputeStageDevices` maps each stage to the available Core ML CPU, GPU, or Neural Engine devices. A caller can select only a reported device. Apple does not statically assign these foreground requests to a particular processor. [Apple Vision compute devices][apple-vision-compute] `SDK V2` | The mapping for each request/revision/configuration on the prototype Mac, actual scheduler choice, utilization, and contention with encode/composition. Log the runtime mapping; do not assume “Vision” means Neural Engine. |
| Person special case | **Sourced fact:** Apple's exact legacy header specifically describes `.fast` as suitable for streaming on devices with a Neural Engine, while `.balanced` and `.accurate` trade more work for quality/refinement. `SDK V1` | Whether any level sustains the eventual Studio resolution/FPS envelope with compositing and encoding. No level is selected by this research. |
| Native mask dimensions | **Sourced fact:** the SDK describes foreground selected-instance output as a low-resolution analysis mask and offers a scaled image-resolution mask, but publishes no numeric analysis dimensions. Person segmentation exposes supported pixel formats, not a fixed width/height. `SDK V1` `SDK V3` | Dimensions returned for each camera format and quality level, scaling cost, and edge quality after scaling. |
| Native cadence | **Sourced fact:** stateful requests expose `frameAnalysisSpacing`; optical flow is explicitly resource intensive. No Apple page or declaration establishes a supported FPS/latency ceiling for any candidate. [Apple optical flow][apple-optical-flow] `SDK V6` | Per-frame latency, warm-up, memory, thermals, frame skipping, and long-run stability on the chosen Apple-silicon host. |
| API maturity | **Sourced fact:** the legacy person request is available from macOS 12, legacy foreground-instance masks from macOS 14, and the Swift-native equivalents from macOS 15. They are public, non-beta APIs in the inspected SDK. Cinematic capture is macOS 26.0. [Apple person segmentation][apple-person] [Apple foreground instances][apple-foreground] [Apple Cinematic capture][apple-cinematic] | The complete Studio floor still belongs to [#44](https://github.com/timharris707/grab-rabbit/issues/44). Nothing in these mask primitives by itself requires a Tahoe point release later than 26.0. |

## Camera-source and sensor-data contract

Apple exposes three relevant device identities on the Tahoe planning floor:
`.builtInWideAngleCamera`, `.external` for external/USB devices, and `.continuityCamera`.
Continuity Camera needs `NSCameraUseContinuityCameraDeviceType`; otherwise it can report as a
built-in wide-angle device. Apple's sample describes the iPhone camera and its image signal
processing as an `AVCaptureDevice` and documents Center Stage, Portrait, and Studio Light as
system effects. [Apple Continuity sample][apple-continuity] `SDK A1`

| Data visible to this macOS app path | Built-in camera | USB/external camera | Continuity Camera | Public-contract finding |
|---|---|---|---|---|
| Video pixels and timestamps | Yes, when the selected device/session supports the requested configuration. | Same contract. | Same contract; the pixels may already reflect iPhone ISP or selected system effects. | **Sourced fact:** all enter as `AVCaptureDevice` input and `AVCaptureVideoDataOutput` sample buffers. Supported formats and frame-rate ranges are device/runtime properties, not a common fixed promise. [Apple Continuity sample][apple-continuity] `SDK A1` |
| Device/source identity | Built-in type, IDs, name, manufacturer, active format. | External type plus transport/identity metadata where supplied by the device. | Continuity type only after opt-in; otherwise may appear as built-in wide angle. | **Sourced fact:** source identity is distinguishable, but identity does not add mask semantics. `SDK A1` |
| Live depth/disparity | No documented public macOS output. | No documented public macOS output. | No documented public macOS output. | **Sourced fact:** all live depth delivery declarations are unavailable on macOS. [Apple depth output][apple-depth] `SDK A2` |
| Camera calibration/intrinsics | No documented capture-delivery switch. | Same. | Same. | **Sourced fact:** photo calibration delivery and video connection intrinsic-matrix delivery are explicitly unavailable on macOS. The Core Media attachment key exists, but the AVFoundation switch that promises it on capture buffers does not. `SDK A4` |
| Portrait or semantic matte | No capture delivery. | No capture delivery. | No capture delivery, even though the system may apply Portrait mode to pixels. | **Sourced fact:** capture delivery properties are unavailable on macOS. System-effect output is not an exposed matte. [Apple portrait matte capture][apple-portrait] [Apple semantic matte capture][apple-semantic-matte] `SDK A3` |
| Exposure state | Mode/support and “currently adjusting” state are public. Direct numeric `exposureDuration` is unavailable. | Same API; actual mode support is device-specific. | Same API; actual mode support is device-specific. | **Sourced fact:** the mode/boolean declarations are available in the macOS category, while `exposureDuration` is explicitly unavailable. Tahoe adds movie-level shutter-angle/time metadata keys through the same configuration-dependent recommendation API described below; they are not a documented per-frame sensor stream. [Apple exposure duration][apple-exposure] `SDK A5` `SDK A6` |
| ISO | No direct live `AVCaptureDevice.ISO` property on macOS. | Same. | Same. | **Sourced fact:** `ISO` is explicitly unavailable on macOS. Tahoe adds a movie-level ISO metadata key and an API that recommends file metadata after session configuration; Apple does not promise that every source/codec returns that item or that it is a per-frame sensor stream. [Apple ISO][apple-iso] `SDK A5` `SDK A6` |
| White balance | Mode/support and “currently adjusting” state are public. Numeric device gains/temperature/tint are unavailable. | Same API; actual mode support is device-specific. | Same API; actual mode support is device-specific. | **Sourced fact:** numeric gains are unavailable on macOS. Tahoe adds movie-level white-balance metadata keys, with returned items dependent on session/input/codec; this is not a documented continuously sampled lighting feed. [Apple white-balance gains][apple-white-balance] `SDK A5` `SDK A6` |
| Tahoe Cinematic metadata/effect | Runtime-dependent by device/format. | Runtime-dependent. | Runtime-dependent. | **Sourced fact:** `cinematicVideoCaptureSupported` is queried from the configured input. Enabling it applies a simulated depth-of-field effect to video/data/metadata/preview outputs; salient objects can carry tracked bounds/IDs. Apple does not expose a foreground alpha matte through this API. [Apple Cinematic capture][apple-cinematic] [Apple metadata object ID][apple-metadata-id] `SDK A7` |

**Inference:** all three camera classes present RGB frames to the candidate segmentation logic,
but their lenses, resolution, noise, ISP, framing, and selected system effects can change mask
quality. Camera source is therefore a meaningful visual test dimension, not a depth-data or
API-capability shortcut.

**Prototype hypothesis:** the Continuity Camera image may give a better native mask because of
source image quality. It must be tested; Apple does not document superior foreground-mask
results for that source.

## Reusable non-Apple candidate

This lane evaluated one non-Apple path deeply: **Meta SAM 2.1 Hiera Tiny** at upstream commit
[`2b90b9f5ceec907a1c18123530e92e794ad901a4`][sam2-tree] and official model-card revision
[`de431c4043854a71d8101e17995dfe596bf101a5`][sam2-card]. It is the smallest official SAM 2.1
checkpoint and directly matches prompted arbitrary-object video masks. This selection is not a
claim that no other model exists.

| Criterion | Primary-source finding | Product consequence |
|---|---|---|
| Object semantics | **Sourced fact:** SAM 2 is promptable, class-agnostic segmentation for images and video. Points, boxes, or masks initialize object IDs; the video predictor propagates masks for multiple objects using inference state/streaming memory. It does not automatically label an object “chair” or “microphone.” [SAM 2 README][sam2-readme] [SAM 2 model card][sam2-card] [SAM 2 predictor][sam2-predictor] | It can retain a chair and microphone after a click/box/mask prompt. Automatic semantic discovery still needs another model or a product-approved selection step. |
| Temporal behavior | **Sourced fact:** SAM 2's model design uses streaming memory. The official predictor keeps per-object conditioning/non-conditioning state and propagates masklets through a video. [SAM 2 README][sam2-readme] [SAM 2 predictor][sam2-predictor] | This is a true mask-propagation challenger rather than a bounding-box tracker, but recovery after occlusion/re-entry remains a prototype question. |
| Model size | **Sourced fact:** Hiera Tiny is 38.9 million parameters. The official `.pt` endpoint reports `156,008,466` bytes (about 148.8 MiB) without downloading the checkpoint. [SAM 2 README][sam2-readme] [SAM 2 checkpoint][sam2-checkpoint] | The weight alone is material for a small recorder; framework/runtime size is additional and unquantified here. |
| Input/resolution | **Sourced fact:** the pinned Tiny configuration uses a 1024-pixel square internal image size; the official loader resizes every source frame to 1024×1024, and the predictor resizes output mask scores to the original video height and width. [SAM 2 Tiny config][sam2-config] [SAM 2 loader][sam2-loader] [SAM 2 predictor][sam2-predictor] | Non-square input distortion, edge quality after output interpolation, and camera-buffer integration need prototype measurement. |
| Cadence evidence | **Sourced fact:** Meta reports 91.2 FPS for Tiny on an NVIDIA A100 with PyTorch 2.5.1/CUDA 12.4 and full compilation. That number is not Apple-silicon evidence. [SAM 2 README][sam2-readme] | Mac throughput, latency, memory, thermals, and live cadence are unknown. The published FPS cannot be used as Grab Rabbit acceptance evidence. |
| Runtime/backend | **Sourced fact:** the official installation requires Python 3.10+, PyTorch 2.5.1+, torchvision 0.20.1+, documents Linux/CUDA as its supported setup, and builds an optional CUDA extension. The official notebook can select Apple MPS but calls MPS support preliminary, warns of numerical differences/degraded performance, and enables CPU fallback for unsupported operations. [SAM 2 install][sam2-install] [SAM 2 MPS notebook][sam2-mps] | No official Core ML/Neural Engine or native Swift integration is supplied. A Python/MPS quality run is plausible; a shippable macOS runtime is not established. |
| Live-camera readiness | **Sourced fact:** the pinned official predictor initializes from an MP4 or numbered JPEG sequence and holds an inference state; it does not expose an `AVCaptureVideoDataOutput` adapter. [SAM 2 predictor][sam2-predictor] [SAM 2 loader][sam2-loader] | Adapting it to unbounded live input and writer backpressure is engineering, not reuse of a finished macOS component. For [#47][issue-47], a recorded real-camera clip is the lowest-risk comparison. |
| License and redistribution | **Sourced fact:** Meta says the checkpoints, demo code, and training code are Apache License 2.0. The license permits reproduction, modification, sublicensing, and distribution subject to providing the license, marking modified files, retaining relevant notices, and carrying any NOTICE attribution; it grants no trademark rights and includes patent-termination terms. [SAM 2 README][sam2-readme] [SAM 2 license][sam2-license] [SAM 2 model card][sam2-card] | The license grant permits reuse and redistribution of the SAM artifacts under those conditions. A production bundle still needs a separate license/notice audit of PyTorch and every transitive dependency; this lane does not clear that dependency stack. |
| Maintenance/security | **Sourced fact:** the official package declares Python, PyTorch, torchvision, NumPy, tqdm, Hydra, iopath, Pillow, and optional CUDA-extension requirements. [SAM 2 install][sam2-install] [SAM 2 setup][sam2-setup] | A production adoption adds a large third-party update and vulnerability surface, checkpoint/code/config compatibility and provenance management, and runtime hardening. That cost is disproportionate unless native evidence fails and SAM materially improves the soft goals. |
| Production status | **Inference from the sourced runtime facts:** SAM 2.1 Tiny is a valid research challenger but not presently a production-ready Grab Rabbit dependency. | Do not select or ship it from documentation. Any production consideration needs a native-runtime/conversion gate, dependency audit, performance proof, and Tim's cost/UX judgment. |

No model was downloaded in this lane.

## Smallest real-camera prototype matrix

The matrix minimizes capture work by recording one controlled source clip per camera class and
replaying that same clip through each enabled candidate. It deliberately sets no visual pass
threshold.

### Candidate set

| ID | Candidate | Entry rule | Why it is in the matrix |
|---|---|---|---|
| P0 | Native `GeneratePersonSegmentationRequest` | **Mandatory**, starting with documented default `.accurate`; record rather than assume its cadence. | Person-only control. It establishes whether any broader path is actually better than the clean baseline. |
| P1 | Native `GenerateForegroundInstanceMaskRequest` | **Mandatory**. Save both the all-foreground union and per-instance outputs; do not assume instance numbers persist. | Lowest-cost native chance of retaining chair and microphone. It exposes whether selection and temporal identity are the real gaps. |
| P2 | SAM 2.1 Hiera Tiny prompted separately for chair back and microphone | **Conditional:** only on source/object clips where P1 fails or is unstable, and only after the [#47 prototype lane][issue-47] records authorization for the approximately 149 MiB model download. Start with recorded clips and official MPS/CPU fallback; no production integration. | Smallest official arbitrary-object video-mask challenger with permissive artifact licensing. It tests whether a prompted temporal model changes the attainable quality enough to justify further cost. |

Person-instance masks, saliency, object tracking, and optical flow are not independent candidates:
they do not create a broader foreground matte. Add a tracker/flow subtest only after a captured P1
failure identifies a concrete identity or motion problem.

### Source cross-product

| Camera source | P0 | P1 | P2 | Required source notes |
|---|---:|---:|---:|---|
| Built-in Mac camera | Required | Required | Conditional on the failing object/clip | Record exact device ID/type, format/FPS, system-effect state, Vision compute-stage devices, and any Tahoe recommended movie metadata returned. |
| Representative USB camera | Required when hardware is available | Required when hardware is available | Conditional on the failing object/clip | Same notes; record USB model/transport. Absence of owned hardware is a visible coverage gap, not permission to generalize from built-in capture. |
| Continuity Camera iPhone | Required | Required | Conditional on the failing object/clip | Use explicit `.continuityCamera` discovery, record iPhone/device/format and Center Stage/Studio Light/Portrait state, and do not infer depth from image quality. |

Each source clip should include the same observable events: seated stillness; normal head/torso/hand
motion; chair-back partial occlusion and reappearance; microphone partial occlusion, hand crossing,
and reappearance; and a normal room-light change. Save source frames, raw masks, composite previews,
instance IDs/counts, input/output dimensions, per-frame processing time, and any skipped/dropped
frames. These observations let Tim choose a later quality threshold; they are not thresholds.

**Prototype hypothesis:** P1 may work by unioning all noticeable foreground instances, but that
may retain unrelated foreground objects. Selecting only desired instances may reduce clutter but
creates an identity/reselection problem. Test the smallest raw outputs before inventing a tracker.

**Unresolved product judgment:** if P2 is materially better, Tim must decide whether explicit
chair/microphone clicks or boxes are acceptable before any product path is specified. Research
does not silently turn prompted segmentation into automatic detection.

## Decisions this evidence supports

- **Sourced conclusion:** public macOS depth, portrait-matte, semantic-matte, and calibration
  capture APIs cannot be a hidden Continuity Camera fast path for Studio foreground extraction.
- **Sourced conclusion:** native foreground instances are class-agnostic per-image masks; native
  tracking is bounding-box-only and native optical flow is motion-only.
- **Inference:** the smallest honest native experiment is P0 versus P1 on shared clips, not a
  stack that starts with segmentation, saliency, tracking, flow, and a custom model at once.
- **Inference:** camera source remains worth crossing because source pixels differ, even though
  the app receives no documented source-specific depth/matte contract.
- **Recommendation:** keep P2 conditional. Its Apache-2.0 artifacts make a research comparison
  legally plausible, but the official runtime and Apple-silicon evidence do not support a
  production selection.
- **Non-decision:** neither the chair back nor Shure microphone is guaranteed. [#47][issue-47] must return
  visible evidence; Tim owns any threshold and final support envelope.

## Unresolved facts and judgments

| Item | Class | Terminal move |
|---|---|---|
| Which exact built-in Mac, USB camera, iPhone, chair, and Shure microphone are available for the physical test? | Human-held test inventory | [#47][issue-47] should list the actual hardware before capture. Missing USB hardware remains an explicit matrix gap. |
| Which Vision compute devices each configured request reports on the chosen host | Runtime fact | Log `supportedComputeStageDevices` in [#47][issue-47]. |
| Whether Tahoe's `recommendedMovieMetadata` returns ISO, white balance, or shutter items for each source/codec | Runtime fact | Log the returned keys/values after session start in [#47][issue-47]; treat absent items as absent for that configuration only. |
| Whether P0/P1/P2 retain hair, glasses, clothing, chair, and microphone through motion/occlusion without objectionable edges | Visual fact | Produce synchronized source/mask/composite artifacts in [#47][issue-47]. |
| What flicker, latency, partial-cutoff, and edge level is acceptable | **Unresolved product judgment** | Tim chooses after reviewing the prototype evidence; this research sets no threshold. |
| Whether prompted chair/microphone selection is acceptable | **Unresolved product judgment** | Ask Tim only if the prompted path materially outperforms the automatic native path. |
| Whether a roughly 149 MiB checkpoint plus a non-native runtime/conversion burden is acceptable | Product/architecture judgment | Ask Tim only after measured quality and Mac performance justify the cost. |

## Acceptance-criteria coverage

| Issue criterion | Coverage |
|---|---|
| Cited Apple docs/SDK declarations and non-Apple repository/model card/license | Source ledger below; all SAM claims pin the repository/model-card revisions. |
| Separate person segmentation, foreground instances, saliency, tracking, optical flow, depth, portrait mattes, semantic detection, and video behavior | “What each primitive actually represents.” |
| Built-in/USB/Continuity differences for depth, calibration, portrait, exposure, ISO, and white balance | “Camera-source and sensor-data contract,” including Tahoe movie-metadata caveat. |
| Compute device, temporal state, resolution/cadence, and production availability | Dedicated compute/cadence table plus per-candidate findings. Undocumented performance is explicitly unknown. |
| Non-Apple license, redistribution, size, backend, semantics, and maintenance/security | SAM 2.1 Tiny audit. |
| Smallest real-camera matrix with person-only baseline | P0/P1 required across three source classes; P2 conditional. |
| No documentation-only chair/microphone guarantee or visual threshold | Verdict, candidate entry rules, and unresolved-judgment ledger. |

## Primary-source ledger

All web sources were retrieved successfully on 2026-08-16.

### Apple public documentation

- [GeneratePersonSegmentationRequest][apple-person]
- [GeneratePersonInstanceMaskRequest][apple-person-instance]
- [GenerateForegroundInstanceMaskRequest][apple-foreground] and
  [InstanceMaskObservation][apple-instance-observation]
- [Attention-based saliency][apple-attention-saliency] and
  [objectness-based saliency][apple-objectness-saliency]
- [TrackObjectRequest][apple-object-tracking] and
  [TrackOpticalFlowRequest][apple-optical-flow]
- [Vision request compute devices][apple-vision-compute] and
  [VNCoreMLRequest][apple-coreml]
- [Supporting Continuity Camera in your macOS app][apple-continuity]
- [AVCaptureDepthDataOutput][apple-depth],
  [depth capture support][apple-photo-depth],
  [portrait matte capture support][apple-portrait], and
  [semantic matte capture types][apple-semantic-matte]
- [`AVCaptureDevice.exposureDuration`][apple-exposure],
  [`AVCaptureDevice.ISO`][apple-iso], and
  [`AVCaptureDevice.deviceWhiteBalanceGains`][apple-white-balance]
- [`AVCaptureVideoDataOutput`][apple-video-output],
  [Cinematic capture support][apple-cinematic], and
  [`AVMetadataObject.objectID`][apple-metadata-id]

### Exact Apple SDK declaration ledger

Paths below are relative to
`MacOSX26.5.sdk/System/Library/Frameworks/` in Xcode 26.6.

| ID | Exact declaration evidence |
|---|---|
| `SDK V1` | `Vision.framework/Headers/VNGeneratePersonSegmentationRequest.h:15-64` — quality meanings, possible prior-mask use, stateful superclass, output formats, macOS availability. |
| `SDK V2` | `Vision.framework/Versions/A/Modules/Vision.swiftmodule/arm64e-apple-macos.swiftinterface:577-593,1462-1468,1615-1667,1747-1808,1874-1927` — image-request sample/pixel-buffer inputs; `VisionRequest` compute mapping; stateful person segmentation; stateless person/foreground instances; stateful optical flow. |
| `SDK V3` | `Vision.framework/Headers/VNObservation.h:739-784` — instance-label semantics, low-resolution selected mask, scaled mask/image. |
| `SDK V4` | `Vision.framework/Headers/VNObservation.h:538-551` and `VNGenerateAttentionBasedSaliencyImageRequest.h`, `VNGenerateObjectnessBasedSaliencyImageRequest.h` — heat map and bounding regions. |
| `SDK V5` | `Vision.framework/Headers/VNTrackObjectRequest.h:17-50` and `VNTrackingRequest.h:36-64` — sequence handler, bounding observation, tracker limits/lifetime. |
| `SDK V6` | `Vision.framework/Headers/VNGenerateOpticalFlowRequest.h:28-86` — equal-size images, per-pixel vectors, resource warning, formats/revisions. |
| `SDK V7` | `Vision.framework/Versions/A/Modules/Vision.swiftmodule/arm64e-apple-macos.swiftinterface` and `Vision.framework/Headers/` — public request-symbol inventory; exact-name searches for `chair` and `microphone` returned no request or observation type. |
| `SDK A1` | `AVFoundation.framework/Headers/AVCaptureDevice.h:473-496,577-587,140-187,285-373,3189-3206` — device types/Continuity opt-in, identity/transport, formats and frame-rate ranges. |
| `SDK A2` | `AVFoundation.framework/Headers/AVCaptureDepthDataOutput.h:21-32`; `AVCaptureDevice.h:2197-2212,3463-3470` — live depth class/formats explicitly unavailable on macOS. |
| `SDK A3` | `AVFoundation.framework/Headers/AVCapturePhotoOutput.h:910-970,2038-2090`; `AVPortraitEffectsMatte.h`; `AVSemanticSegmentationMatte.h` — capture delivery unavailable, file auxiliary-map types available. |
| `SDK A4` | `AVFoundation.framework/Headers/AVCaptureSession.h:1277-1294`; `AVCapturePhotoOutput.h:479-486` — video intrinsics and photo calibration delivery explicitly unavailable on macOS. |
| `SDK A5` | `AVFoundation.framework/Headers/AVCaptureDevice.h:1360-1499,1700-1757` — public mode/adjusting state; numeric exposure, ISO, and gains unavailable on macOS. |
| `SDK A6` | `AVFoundation.framework/Headers/AVCaptureVideoDataOutput.h:186-199`; `AVMetadataFormat.h:181-199` — Tahoe movie-level metadata API and ISO/white-balance/shutter keys. |
| `SDK A7` | `AVFoundation.framework/Headers/AVCaptureInput.h:425-458`; `AVMetadataObject.h:35-111,143-328,397-587` — Cinematic effect, runtime support, tracked bounds/IDs, and public human/face/cat/dog/salient/code object types. |

### Meta SAM 2 primary sources

- Pinned [repository tree][sam2-tree] and [README/model table][sam2-readme]
- [Installation/runtime requirements][sam2-install], [package dependencies][sam2-setup],
  and [official MPS warning notebook][sam2-mps]
- [Tiny configuration][sam2-config], [video predictor][sam2-predictor], and
  [frame loader][sam2-loader]
- Official [Apache-2.0 license][sam2-license], [model card][sam2-card], and
  [Tiny checkpoint endpoint][sam2-checkpoint]

### Audit limits

- The negative Apple findings are bounded to public declarations in the installed 26.5 SDK;
  they do not speculate about private frameworks or Apple's internal ISP.
- No camera was opened, no real-camera test was run, no model was downloaded, and no production
  code or application setting changed.
- Apple's missing numeric performance contracts are recorded as unknown rather than inferred
  from marketing, one machine, or a different platform.
- SAM's A100/CUDA number is retained only to prevent it from being mistaken for Mac evidence.

[apple-person]: https://developer.apple.com/documentation/vision/generatepersonsegmentationrequest
[apple-person-instance]: https://developer.apple.com/documentation/vision/generatepersoninstancemaskrequest
[apple-foreground]: https://developer.apple.com/documentation/vision/generateforegroundinstancemaskrequest
[apple-instance-observation]: https://developer.apple.com/documentation/vision/instancemaskobservation
[apple-attention-saliency]: https://developer.apple.com/documentation/vision/generateattentionbasedsaliencyimagerequest
[apple-objectness-saliency]: https://developer.apple.com/documentation/vision/generateobjectnessbasedsaliencyimagerequest
[apple-object-tracking]: https://developer.apple.com/documentation/vision/trackobjectrequest
[apple-optical-flow]: https://developer.apple.com/documentation/vision/trackopticalflowrequest
[apple-vision-compute]: https://developer.apple.com/documentation/vision/visionrequest/supportedcomputestagedevices
[apple-coreml]: https://developer.apple.com/documentation/vision/vncoremlrequest
[apple-continuity]: https://developer.apple.com/documentation/avfoundation/supporting-continuity-camera-in-your-macos-app
[apple-depth]: https://developer.apple.com/documentation/avfoundation/avcapturedepthdataoutput
[apple-photo-depth]: https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isdepthdatadeliverysupported
[apple-portrait]: https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isportraiteffectsmattedeliverysupported
[apple-semantic-matte]: https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/availablesemanticsegmentationmattetypes
[apple-exposure]: https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposureduration
[apple-iso]: https://developer.apple.com/documentation/avfoundation/avcapturedevice/iso
[apple-white-balance]: https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicewhitebalancegains
[apple-video-output]: https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput
[apple-cinematic]: https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/iscinematicvideocapturesupported
[apple-metadata-id]: https://developer.apple.com/documentation/avfoundation/avmetadataobject/objectid
[issue-47]: https://github.com/timharris707/grab-rabbit/issues/47
[sam2-tree]: https://github.com/facebookresearch/sam2/tree/2b90b9f5ceec907a1c18123530e92e794ad901a4
[sam2-readme]: https://github.com/facebookresearch/sam2/blob/2b90b9f5ceec907a1c18123530e92e794ad901a4/README.md
[sam2-install]: https://github.com/facebookresearch/sam2/blob/2b90b9f5ceec907a1c18123530e92e794ad901a4/INSTALL.md
[sam2-setup]: https://github.com/facebookresearch/sam2/blob/2b90b9f5ceec907a1c18123530e92e794ad901a4/setup.py
[sam2-mps]: https://github.com/facebookresearch/sam2/blob/2b90b9f5ceec907a1c18123530e92e794ad901a4/notebooks/video_predictor_example.ipynb
[sam2-config]: https://github.com/facebookresearch/sam2/blob/2b90b9f5ceec907a1c18123530e92e794ad901a4/sam2/configs/sam2.1/sam2.1_hiera_t.yaml
[sam2-predictor]: https://github.com/facebookresearch/sam2/blob/2b90b9f5ceec907a1c18123530e92e794ad901a4/sam2/sam2_video_predictor.py
[sam2-loader]: https://github.com/facebookresearch/sam2/blob/2b90b9f5ceec907a1c18123530e92e794ad901a4/sam2/utils/misc.py
[sam2-license]: https://github.com/facebookresearch/sam2/blob/2b90b9f5ceec907a1c18123530e92e794ad901a4/LICENSE
[sam2-card]: https://huggingface.co/facebook/sam2.1-hiera-tiny/blob/de431c4043854a71d8101e17995dfe596bf101a5/README.md
[sam2-checkpoint]: https://dl.fbaipublicfiles.com/segment_anything_2/092824/sam2.1_hiera_tiny.pt
