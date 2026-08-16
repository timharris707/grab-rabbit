# Studio platform API and hardware floor

_Research for [#44 — STUDIO RESEARCH: Pin the Tahoe API and hardware floor](https://github.com/timharris707/grab-rabbit/issues/44). Evidence checked 2026-08-16 against Apple primary sources and the installed Xcode 26.6 / macOS 26.5 SDK. This document records findings; it does not change project deployment or architecture settings._

## Verdict

**Product-floor recommendation:** set Studio's eventual deployment contract to **macOS Tahoe
26.0 on Apple silicon (`arm64`)**. Every public primitive required by the issue is available
before Tahoe: the newest floor-defining symbols are ScreenCaptureKit microphone capture and
AVFoundation Background Replacement state, both introduced in macOS 15.0. Apple records the
initial `macOS Tahoe 26` release separately from 26.0.1 and 26.1, so 26.0—not the installed
26.5 SDK—is the earliest Tahoe point release.[^tahoe-release] No required 26.1–26.5 symbol was
found.

**Hardware classification:** `arm64` is Tim's approved **product choice**, not a blanket API
requirement. Apple shipped Tahoe 26 for several Intel Macs,[^tahoe-hardware] and the required
symbols have no architecture unavailability annotations. Individual features still have
hardware contracts: Presenter Overlay requires Apple silicon; ScreenCaptureKit HDR capture is
Apple-silicon-only; and Continuity Camera effects depend on the attached iPhone model. Those
facts support Tim's ruling without rewriting it as an API requirement.

**Unresolved product tradeoff for Tim:** the name-bounded public-SDK audit below found no direct
pre-stream Presenter Overlay enabled/active property or off method among declarations matching
`presenter.?overlay`, `outputVideoEffect`, or `video.?effect`. AVFoundation can open the system
video-effects UI for user action, but that asynchronous method does not itself read or change
Presenter Overlay state.[^system-effects-ui] Once an `SCStream` starts, delegate callbacks
(macOS 14.0) and per-frame metadata (macOS 14.2) can positively report the
effect.[^presenter-start][^presenter-rect] **Inference:** a no-writer `SCStream` can therefore
provide a pre-recording observation phase that fails closed on a positive signal.[^scstream]
Apple does not document callback/metadata timing or a bounded observation interval whose silence
conclusively establishes that the effect is off. Raising the floor within Tahoe does not close
that gap.

> **Exact adjudication question:** Which Q16 enforcement contract should Studio use: user
> confirmation; bounded automatic no-writer observation that fails closed on a positive signal
> while treating no signal as non-conclusive; or a stronger guarantee requiring additional
> evidence or a different enforcement route? The public 26.5 surface supports positive
> pre-recording detection after `SCStream` starts, but documents neither a conclusive bounded
> negative nor direct off control.

## How to read the findings

- **Source fact** means an Apple document or exact public SDK declaration states it.
- **Inference** means the conclusion follows from the cited public surface but Apple does not
  state the product conclusion verbatim.
- **Product-floor recommendation** is the proposed Grab Rabbit contract, not an Apple mandate.
- **Unresolved** identifies a product tradeoff for Tim; it is not filled with an API guess.

The installed SDK is
`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk`
(`xcrun --sdk macosx --show-sdk-version` = `26.5`). Header excerpts below are exact apart from
whitespace and omitted non-macOS platform clauses. **Symbol presence in that SDK is never used
as proof of an earlier release.** Earlier floors come from the declarations'
`API_AVAILABLE`/`API_UNAVAILABLE` annotations, corroborating live Apple Documentation metadata,
and Apple's release record.

All selected symbols are documented public framework API in `System/Library/Frameworks/.../Headers`
and Apple Documentation. No private framework, private header, SPI, accessibility automation,
or Control Center UI scripting is part of the recommendation.

## Point-release proof

### Source facts

1. Apple's initial security-content record is titled `macOS Tahoe 26`, dated 2025-09-15;
   Apple's release table separately lists `macOS Tahoe 26.0.1` on 2025-09-29 and `26.1` on
   2025-11-03.[^tahoe-release] The installed SDK's deployment-target list spells the initial
   semantic target `26.0`, but that local list is corroboration, not the release evidence.
2. The newest required API floors are macOS 15.0:
   `SCStreamOutputTypeMicrophone`, `SCStreamConfiguration.captureMicrophone`, and
   `AVCaptureDevice.backgroundReplacementEnabled/Active`. The Apple Documentation records the
   same introductions.[^sck-microphone][^background-enabled]
3. The latest required sub-point symbol is
   `SCStreamFrameInfoPresenterOverlayContentRect`, introduced in macOS 14.2.[^presenter-rect]
4. A scan of the installed public headers found no 26.1–26.5 availability annotation in Vision,
   ScreenCaptureKit, Core Image, Core Video, or Core Media. Later capture/composition additions
   found elsewhere—AVFoundation Edge Light (26.2), AVFoundation audio zoom (26.4), and Metal
   tensor/sparse-resource additions (26.4)—are not part of
   [#44](https://github.com/timharris707/grab-rabbit/issues/44)'s required contract.

### Inference

Because every required symbol's declared floor is at most macOS 15.0, the first Tahoe release
contains the complete compile-time API set. A later Tahoe point release could contain bug fixes,
but no cited public contract makes 26.1–26.5 necessary. Runtime quality and performance remain
prototype questions for [#47](https://github.com/timharris707/grab-rabbit/issues/47),
[#48](https://github.com/timharris707/grab-rabbit/issues/48), and
[#49](https://github.com/timharris707/grab-rabbit/issues/49); they are not invented here as a
deployment-floor reason.

### Conceptual compile audit

The exact checked-in symbol probe
[`probes/studio-platform-api-floor.swift`](probes/studio-platform-api-floor.swift), importing
AVFoundation, Vision, ScreenCaptureKit, Core Image, and Metal, typechecked against the installed
SDK for:

- `arm64-apple-macosx15.0`;
- `arm64-apple-macosx26.0`; and
- `x86_64-apple-macosx26.0`.

The probe referenced explicit Continuity Camera discovery, all three mask requests, object and
optical-flow request types, ScreenCaptureKit microphone output, all required video-effect state,
Presenter Overlay frame metadata, real-time asset-writer input, and a Metal-backed `CIContext`.
This is only a consistency check against the annotated declarations. It is not runtime proof on
15.0, 26.0, Intel, an iPhone, or a particular camera.

## Required API contract

### 1. Continuity Camera discovery, selection, and frames

| Material symbol | Exact installed declaration / change | State, limitation, permission, and production status |
|---|---|---|
| `AVCaptureDevice.DiscoverySession` | `API_AVAILABLE(macos(10.15)) @interface AVCaptureDeviceDiscoverySession`; `devices` is KVO-observable. | **Source fact:** public production discovery API. The returned list is live state, not a permanent inventory.[^discovery] |
| `AVCaptureDeviceTypeContinuityCamera` | `API_AVAILABLE(macos(14.0))`; the header says apps opt in with `NSCameraUseContinuityCameraDeviceType`; without it, Continuity cameras report `.builtInWideAngleCamera`. | **Source fact:** public explicit discovery type. The current project does not declare the opt-in key. Adding it belongs to a later implementation ticket, not this research change.[^continuity-type] |
| `AVCaptureDevice.isContinuityCamera` | `@property(... getter=isContinuityCamera) BOOL continuityCamera API_AVAILABLE(macos(13.0));` | **Source fact:** identifies an external iPhone webcam even though device type classification has a separate opt-in contract.[^continuity-property] |
| `.external` / `.externalUnknown` | `.external API_AVAILABLE(macos(14.0))`; `.externalUnknown API_DEPRECATED_WITH_REPLACEMENT("AVCaptureDeviceTypeExternal", macos(10.15, 14.0))`. | **Source fact:** replace the current broad deprecated `.externalUnknown` when Studio implementation is specified; do not relabel the existing muxed mobile-device path as Continuity Camera. |
| `AVCaptureVideoDataOutput` and its sample-buffer delegate | `API_AVAILABLE(macos(10.7))`; `setSampleBufferDelegate(_:queue:)` delivers callbacks on the supplied queue, which Apple requires to be serial to guarantee frame order. | **Source fact:** public uncompressed/compressed frame path. Studio must supply a serial callback queue before depending on ordered frames. The header also warns that blocked delegates drop frames and retaining pooled buffers too long can stop new delivery; the compositor must copy/consume promptly.[^video-output] |
| `AVCaptureDeviceWasDisconnectedNotification`, `isConnected`, and the discovery list | Disconnect notification is public from macOS 10.7; `isConnected` and the discovery list are observable. | **Source fact:** public disconnection state. **Inference:** retain the exact manually selected device/input and fail closed on its disconnect. Do not follow `systemPreferredCamera`, whose declaration says it may change spontaneously, because Q15 prohibits silent substitution.[^preferred-camera] |
| Camera authorization | `authorizationStatusForMediaType:` and `requestAccessForMediaType:` are `API_AVAILABLE(macos(10.14))`. | **Source fact:** camera/microphone TCC is stateful; before authorization, capture devices may vend black video or silent audio.[^capture-permission] The host already has camera/audio-input entitlements and generated usage descriptions; this lane changes none. |

Apple's Continuity Camera requirements are iOS 16 or later, iPhone XR or later, macOS Ventura
13 or later on a compatible Mac, the same two-factor-authenticated Apple Account, nearby devices
with Bluetooth and Wi-Fi enabled, and a trusted USB connection when wired.[^continuity-support]
Those are camera-path requirements, not an Apple-silicon requirement. The feature uses one
iPhone and one Mac at a time.

**Product-floor recommendation:** discover `.continuityCamera`, `.external`, and appropriate
built-in camera types; show `isContinuityCamera` as first-class source metadata; bind Studio to
the exact selected device; and treat disappearance of that device as the Q15 stop/pause event.
Do not use the existing `.muxed` “mobile device” movie-output path as a webcam substitute.

### 2. Person masks, foreground instances, tracking, and optical flow

| Material symbol | Exact installed declaration / state | Supported meaning and limit |
|---|---|---|
| `VNGeneratePersonSegmentationRequest` | `API_AVAILABLE(macos(12.0)) @interface ... : VNStatefulRequest`; the header says it may retain prior masks for temporal stability. | **Source fact:** produces a person matte. `VNStatefulRequest` requires timestamped `CMSampleBuffer` input and uses `frameAnalysisSpacing`; `fast`, `balanced`, and `accurate` trade speed for quality.[^person-segmentation] The header describes `fast` as suitable for streaming on devices with a Neural Engine, but does not declare the request arm64-only. |
| `VNGenerateForegroundInstanceMaskRequest` | `API_AVAILABLE(macos(14.0)) @interface ... : VNImageBasedRequest`. | **Source fact:** produces instance masks for “salient objects that can be separated from the background,” not semantic chair/microphone labels.[^foreground-mask] **Inference:** because it is image-based rather than stateful, instance identity must not be assumed stable across frames. |
| `VNGeneratePersonInstanceMaskRequest` | `API_AVAILABLE(macos(14.0)) @interface ... : VNImageBasedRequest`. | **Source fact:** separates individual people; it is not an arbitrary-object or temporal-tracking guarantee.[^person-instance] |
| `VNInstanceMaskObservation` | `API_AVAILABLE(macos(14.0))`; exposes `instanceMask`, `allInstances`, and generated masks/images for a selected index set. | **Source fact:** each pixel belongs to one instance or background. The observation exposes indices, not semantic class names or cross-frame identity.[^instance-observation] |
| `VNTrackObjectRequest` + `VNSequenceRequestHandler` | `API_AVAILABLE(macos(10.13)) @interface VNTrackObjectRequest : VNTrackingRequest`. | **Source fact:** a general bounding-box tracker seeded with `VNDetectedObjectObservation`; it does not generate a matte or identify the object's class.[^object-tracking] |
| `VNGenerateOpticalFlowRequest` | `API_AVAILABLE(macos(11.0))`; revision 2 is macOS 13.0. | **Source fact:** generates dense directional change between equal-sized images; Apple's header calls it “very resource intensive.” It is a two-image request, not temporal object identity.[^generated-flow] |
| `VNTrackOpticalFlowRequest` | `API_AVAILABLE(macos(14.0)) @interface ... : VNStatefulRequest`; at least two images are required. | **Source fact:** stateful dense flow with tunable accuracy, also documented as resource-intensive.[^tracked-flow] It can be a prototype candidate, not a quality guarantee. |
| Vision compute-device inspection | `API_AVAILABLE(macos(14.0)) -supportedComputeStageDevicesAndReturnError:` and `-setComputeDevice:forComputeStage:`. | **Source fact:** supported CPU/GPU/Neural Engine devices are request-configuration and runtime facts.[^vision-compute] No listed request has an architecture-only annotation. |

**Inference:** native APIs supply a supportable person-only baseline and candidates for Q11, but
documentation alone cannot promise a stable chair back or Shure microphone. Foreground-instance
selection, object tracking, or optical flow must earn that behavior in [#47](https://github.com/timharris707/grab-rabbit/issues/47),
after the broader feasibility work in [#45](https://github.com/timharris707/grab-rabbit/issues/45).
No [#44](https://github.com/timharris707/grab-rabbit/issues/44) finding changes the approved
“quality wins” rule.

Vision, Core Image, and Metal declare no capture permission of their own. **Inference:** they
process buffers already obtained under camera/screen authorization; they do not broaden what
the app may capture.

### 3. Camera, depth, and calibration metadata

The macOS API surface is narrower than the iPhone's in-process capture surface.

| Question | Exact installed declaration | Finding |
|---|---|---|
| Can the Mac app read sensor ISO and exposure duration? | `AVCaptureDevice.ISO`, `.exposureDuration`, and `.lensPosition` each end in `API_UNAVAILABLE(macos, visionos)`. | **Source fact:** no public macOS property for these numeric sensor values on the Continuity Camera capture device.[^camera-iso] |
| Can it read device white-balance gains? | `deviceWhiteBalanceGains ... API_UNAVAILABLE(macos, visionos)`. | **Source fact:** no public macOS gains value.[^camera-white-balance] |
| Can it request live depth from the Mac camera input? | `activeDepthDataFormat` and `AVCaptureDevice.Format.supportedDepthDataFormats` are `API_UNAVAILABLE(macos, visionos)`. `AVCaptureDepthDataOutput` is also unavailable on macOS. | **Source fact:** the iOS live-depth negotiation path is not a macOS capture contract.[^depth-format] |
| Can it request camera calibration delivery? | `AVCaptureConnection.cameraIntrinsicMatrixDeliverySupported/Enabled`, `AVCapturePhotoOutput.cameraCalibrationDataDeliverySupported`, and `AVCapturePhotoSettings.cameraCalibrationDataDeliveryEnabled` each carry an exact `API_UNAVAILABLE(macos...)` clause in the installed public headers; the reproduction audit below prints every declaration without normalizing its annotation. | **Source fact:** public AVFoundation does not expose the video-connection or photo-settings enablement path on macOS.[^camera-calibration-delivery] |
| Does Core Media define an intrinsic-matrix attachment? | `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix API_AVAILABLE(macos(10.13))`. | **Source fact:** the generic key exists.[^camera-intrinsic-matrix] **Inference:** its existence does not guarantee that Continuity Camera frames carry it, because AVFoundation's delivery controls are unavailable on macOS. Code may inspect optional attachments but must not require one. |
| What metadata is usable? | `uniqueID`, `localizedName`, `modelID`, `manufacturer`, `transportType`, `activeFormat`, format descriptions, frame timing, dimensions, and color attachments are public. | **Source fact:** identity, format, timing, and color metadata can drive source selection and pixel interpretation. They do not describe room-light direction, brightness, color temperature, or depth. |

**Inference:** Studio lighting analysis must be pixel-derived on the Mac. The public capture path
does not provide a dependable ISO, exposure-duration, white-balance-gain, raw-depth, or camera-
calibration feed from Continuity Camera. This finding narrows architecture; it does not prove
which pixel-analysis method meets the realism bar in [#49](https://github.com/timharris707/grab-rabbit/issues/49).

### 4. Core Image and Metal composition

| Material symbol | Exact installed declaration | State, hardware, permission, and role |
|---|---|---|
| `CIImage(cvPixelBuffer:)` | `initWithCVPixelBuffer: ... NS_AVAILABLE(10_11, 5_0)`. | **Source fact:** public pixel-buffer-backed image ingress from capture and mask buffers.[^ci-image] The declaration does not promise copy behavior; allocation and performance remain [#48](https://github.com/timharris707/grab-rabbit/issues/48) measurements. |
| `CIContext(mtlDevice:)` | `contextWithMTLDevice: ... NS_AVAILABLE(10_11, 9_0)`. | **Source fact:** a context binds rendering to a chosen Metal device.[^ci-context] Contexts are reusable state/caches; they do not own Studio's media clock. |
| `CIBlendWithMask` / `blendWithMaskFilter` | Typed built-ins are under `NS_CLASS_AVAILABLE(10_15, 13_0)`; the filter interpolates foreground and background by mask. | **Source fact:** public local composition primitive. It makes no mask-quality promise. |
| `CIContext.render(...toCVPixelBuffer:)` / `...toMTLTexture:` | Both render paths are `NS_AVAILABLE(10_11, ...)`. | **Source fact:** public output to an asset-writer pixel buffer or Metal texture. |
| `MTLCreateSystemDefaultDevice` | `API_AVAILABLE(macos(10.11))`. | **Source fact:** public Metal device acquisition with no arm64-only declaration.[^metal-device] |
| `CVMetalTextureCacheCreate` / `...CreateTextureFromImage` | `API_AVAILABLE(macosx(10.11), ...)`. | **Source fact:** public Core Video/Metal texture bridge. |

**Product-floor recommendation:** a Metal-backed Core Image graph is sufficient as the minimum
public composition contract: camera image + mask + generated background + optional sanitized
screen image into an asset-writer pixel buffer. A custom Metal kernel may later improve quality
or performance, but no later Tahoe API is required to make that choice. Clock ownership,
backpressure, buffer lifetime, and measured performance remain [#48](https://github.com/timharris707/grab-rabbit/issues/48) work.

### 5. ScreenCaptureKit frames and audio

| Material symbol | Exact installed declaration | State, hardware, permission, and role |
|---|---|---|
| `SCShareableContent`, `SCContentFilter`, `SCStreamConfiguration`, `SCStream`, `SCStreamOutput` | Core stream classes/protocol are `API_AVAILABLE(macos(12.3))`. | **Source fact:** public production screen/window source and callback pipeline.[^scstream] |
| `SCStreamOutputTypeScreen` | Enum base is macOS 12.3. | **Source fact:** `CMSampleBuffer` backed by an IOSurface, configured by stream width, height, and pixel format.[^stream-output] |
| `SCStreamOutputTypeAudio` / `capturesAudio` | `API_AVAILABLE(macos(13.0))`. | **Source fact:** system/application audio buffers use the configured sample rate and channel count. |
| `SCStreamOutputTypeMicrophone`, `captureMicrophone`, `microphoneCaptureDeviceID` | Each is `API_AVAILABLE(macos(15.0))`; the device ID is an `AVCaptureDevice.uniqueID`. | **Source fact:** public selected-microphone path if Studio chooses one ScreenCaptureKit stream for all sources.[^sck-microphone] The existing separate microphone path is also viable; [#48](https://github.com/timharris707/grab-rabbit/issues/48) owns the clock/ownership choice. |
| `SCStreamFrameInfoStatus`, `.contentRect`, `.scaleFactor`, `.displayTime` | Base keys are macOS 12.3. `SCFrameStatusIdle` means no new frame because display content did not change. | **Source fact:** screen callbacks may report unchanged content rather than provide the moving camera's cadence. This supports—but does not decide—the independent render-clock prototype. |
| `SCStream.synchronizationClock` | `API_AVAILABLE(macos(13.0))`. | **Source fact:** a public media-capture clock is available. It does not choose fixed, camera-driven, or hybrid scheduling. |
| `SCStreamConfiguration.captureDynamicRange` | `API_AVAILABLE(macos(15.0))`; the header says HDR capture is supported only on Apple silicon and has no effect on Intel. | **Source fact:** an explicit Apple-silicon constraint, but HDR is not in [#44](https://github.com/timharris707/grab-rabbit/issues/44)'s required Studio contract. SDR capture has no such declaration. |

Screen and system-audio recording is governed by macOS Privacy & Security authorization; Apple
documents the user's Screen & System Audio Recording control and instructs ScreenCaptureKit apps
to add `NSScreenCaptureUsageDescription` with an explanation of why screen-recording access is
required.[^screen-permission][^screen-capture-permission] The current project does not generate
that key; [#18](https://github.com/timharris707/grab-rabbit/issues/18) owns the shipped
permission-purpose settings and must add reviewed user-facing copy. Microphone capture separately
uses microphone TCC, `NSMicrophoneUsageDescription`, and—under the current Grab Rabbit release
allowlist—the host audio-input entitlement. This evidence-only lane changes neither settings nor
entitlements.

### 6. Real-time writing and timing

| Material symbol | Exact installed declaration / state | Required behavior |
|---|---|---|
| `AVAssetWriter` | `API_AVAILABLE(macos(10.7))`; the header says one writer instance is used once for one file. | **Source fact:** public one-shot state machine (`unknown` → `writing` → terminal state), suitable for H.264/HEVC movie output.[^asset-writer] |
| `startWriting()` then `startSession(atSourceTime:)` | Available from the writer's original macOS floor. The session start maps source sample time to movie time; samples must be appended inside a session. | **Source fact:** common source-time mapping preserves track synchronization; it does not synthesize a render cadence. |
| `AVAssetWriterInput.expectsMediaDataInRealTime` and `readyForMoreMediaData` | Public from macOS 10.7. The header says real-time producers should enable the former; if readiness is false, clients may need to drop samples or reduce data rate. | **Source fact:** backpressure is explicit state and cannot be ignored.[^writer-input] |
| `AVAssetWriterInputPixelBufferAdaptor.append(_:withPresentationTime:)` | Public from macOS 10.7; presentation time is relative to the writer session start. | **Source fact:** public path for compositor-owned video timestamps and pooled pixel buffers.[^pixel-adaptor] |
| `finishWriting` completion | Async completion is `API_AVAILABLE(macos(10.9))`; the header requires append calls to return before finishing. | **Source fact:** finalization is part of the state machine; current Grab Rabbit output-reservation/finalization safeguards remain in force. |

**Inference:** no later Tahoe writer convenience is necessary. Studio can preserve the existing
real-time writer and output-safety foundation while giving the compositor an explicit PTS
contract. [#48](https://github.com/timharris707/grab-rabbit/issues/48) must decide the render
clock and prove monotonic video timestamps, screen/camera staleness behavior, A/V sync, and
backpressure under load.

### 7. Apple video-effect detection and control

| Effect | Public state/control surface and exact floor | What Studio can and cannot promise |
|---|---|---|
| Background Replacement | `AVCaptureDevice.backgroundReplacementEnabled` and per-device `.backgroundReplacementActive` are readonly, public, and `API_AVAILABLE(macos(15.0))`; format support/rate range is also 15.0.[^background-enabled] | **Source fact:** detect user enablement, active application to a configured device, and format support. **Inference:** no public setter or background-image payload exists in AVFoundation, so Studio cannot turn it off or supply its generated image to the system feature. It can block start until the user disables it and observe active state. |
| Presenter Overlay | `SCStreamDelegate.outputVideoEffectDidStart/Stop` are macOS 14.0; `SCStreamFrameInfoPresenterOverlayContentRect` is 14.2; `presenterOverlayPrivacyAlertSetting` is 14.0.[^presenter-start][^presenter-rect][^presenter-alert] `AVCaptureDevice.showSystemUserInterface(.videoEffects)` is macOS 12.0.[^system-effects-ui] | **Source fact:** after the stream starts, callbacks report the overlay effect and frame metadata identifies Presenter Overlay content. The privacy-alert policy is configurable, and Studio may open system UI where the user can change video effects, but the app does not directly own that interaction. **Inference:** Studio can start an `SCStream` without starting `AVAssetWriter` or adding `SCRecordingOutput`, observe before recording, and fail closed on a positive signal.[^scstream] The name-bounded audit below found no direct pre-stream getter or off method, and Apple does not document bounded silence as a conclusive negative. This is the Tim adjudication above. |
| Center Stage | `centerStageControlMode`, class `.centerStageEnabled`, and per-device `.centerStageActive` are `API_AVAILABLE(macos(12.3))`; enabled is settable only in app/cooperative mode and observable in user/cooperative mode.[^center-stage-api] | **Source fact:** Studio can inspect support/active state and can control enablement only after explicitly choosing an app/cooperative control contract. **Product recommendation:** honor the Q16 user choice, snapshot it before lighting calibration, and treat a later state change as invalidating calibration rather than silently accepting changed framing. |
| Studio Light | class `.studioLightEnabled`, device `.studioLightActive`, and format `.studioLightSupported` are readonly and `API_AVAILABLE(macos(13.0))`.[^studio-light-api] | **Source fact:** detect user enablement, activity, and format support; no public setter. **Product recommendation:** permit it only when selected before calibration, then invalidate calibration visibly if state changes. |
| Portrait Effect | class `.portraitEffectEnabled`, device `.portraitEffectActive`, and format support are readonly and macOS 12.0. | **Source fact:** Portrait blur is a separate system effect, not Background Replacement and not Grab Rabbit's generated-background compositor. Studio preflight should not conflate the two. |

The direct-state/control audit is deliberately **name-bounded**, not exhaustive. The reproducible
command below searches every public header and Swift interface in AVFoundation,
ScreenCaptureKit, and CoreMediaIO case-insensitively for exactly
`presenter.?overlay|outputVideoEffect|video.?effect`. Its Presenter-specific matches are the
privacy-alert enum/property, delegate start/stop callbacks, and frame content-rect key; broader
video-effect matches also include AVFoundation's nonblocking system-UI method and unrelated
effect declarations. None of those matching declarations is a direct Presenter Overlay state
getter or off method. A differently named public symbol is not excluded, so the finding is
“not identified by this named audit,” not a universal absence proof. It does not make bounded
no-signal observation conclusive or claim anything about private frameworks or future Apple
releases.

### 8. Hardware and camera-path matrix

| Capability | Apple's technical requirement | Classification for Grab Rabbit |
|---|---|---|
| macOS Tahoe 26 | Apple's initial Tahoe list included Intel MacBook Pro, iMac, and Mac Pro models as well as Apple-silicon Macs.[^tahoe-hardware] | **Source fact:** Tahoe itself was not arm64-only. **Decision:** Tim nevertheless selected Apple silicon for Studio. |
| Base Continuity Camera webcam | iPhone XR or later on iOS 16+, Mac on Ventura 13+, same Apple Account with 2FA, Bluetooth/Wi-Fi proximity or trusted USB.[^continuity-support] | **Source fact:** not Apple-silicon-only. Runtime availability depends on both devices and setup; an iPhone is not bundled hardware. |
| Center Stage with Continuity Camera | iPhone 11 or later, excluding iPhone SE, with a compatible app.[^center-stage-hardware] | **Source fact:** camera-model feature constraint, not a compile-time API constraint. |
| Studio Light | Apple-silicon Mac laptop with built-in camera on Sonoma 14+, or Continuity Camera with iPhone 12+ on Ventura 13+.[^video-effects] | **Source fact:** Mac mini Studio use requires the compatible Continuity Camera path; `studioLightSupported/Active` remains the runtime truth. |
| Background Replacement | Sequoia 15+ on Apple silicon, or Sequoia 15+ with Continuity Camera/iOS 18 on iPhone 12+.[^video-effects] | **Source fact:** matches Tim's arm64 product floor on Mac, but remains user-controlled and must be off in Studio. |
| Presenter Overlay | Sonoma 14+ on Apple silicon.[^video-effects] | **Source fact:** explicit hardware requirement for the system feature. Studio must still detect/prevent double processing under Q16. |
| Vision mask/track requests | No material request declaration is architecture-restricted; per-request compute devices are queryable at runtime. Person segmentation's fast quality documentation points to Neural Engine streaming use. | **Inference:** Apple silicon is a performance/product floor, not a static API floor. [#47](https://github.com/timharris707/grab-rabbit/issues/47) must benchmark actual camera/scene quality and latency. |
| ScreenCaptureKit HDR | `captureDynamicRange` states HDR capture is Apple-silicon-only. | **Source fact:** explicit hardware requirement for optional HDR, which is outside the present required SDR contract. |
| Core Image / Metal composition and AVAssetWriter | Required declarations are available for both macOS architectures; the 26.0 symbol probe typechecked for arm64 and x86_64. | **Inference:** no compile-time arm64 requirement. Tim's ruling still makes production Studio arm64-only. |

No specific M1/M2/M3/M4/M5 generation is required by a selected public symbol. A later quality
envelope may require a performance tier, but that would need measured prototype evidence and a
separate Tim decision—not a reinterpretation of
[#44](https://github.com/timharris707/grab-rabbit/issues/44).

## Permission and entitlement summary

| Boundary | Public contract | Current repository fact / recommendation |
|---|---|---|
| Camera | AVFoundation camera authorization; `NSCameraUsageDescription`; App Sandbox camera entitlement when sandboxed.[^capture-permission][^camera-entitlement] | The project already generates a camera usage description and the host entitlement allowlist includes `com.apple.security.device.camera = true`. Preserve it. |
| Microphone | AVFoundation audio authorization; `NSMicrophoneUsageDescription`; audio-input entitlement when sandboxed.[^microphone-entitlement] | The project already generates a microphone usage description and has `com.apple.security.device.audio-input = true`. Preserve it. |
| Screen/system audio | macOS Screen & System Audio Recording privacy authorization; Apple's ScreenCaptureKit overview instructs apps to declare `NSScreenCaptureUsageDescription` with user-facing purpose copy.[^screen-permission][^screen-capture-permission] | The current project does not generate the key. [#18](https://github.com/timharris707/grab-rabbit/issues/18) must add the reviewed copy with its shipped identity/TCC work. No new entitlement is proposed, and this research PR does not change target settings. |
| Vision/Core Image/Metal | No capture authorization in the cited request/render declarations. | **Inference:** process only already-authorized buffers; no extra data access is granted. |
| Output file | AVAssetWriter writes to a URL the app can access. | Preserve existing output reservation, visible failure, and finalization behavior. |
| Continuity Camera | Apple Account/device proximity/trust requirements plus normal camera authorization.[^continuity-support] | No custom iPhone app or private entitlement is needed for the native route. |

TCC grants remain bound to the signed application identity, per
[`docs/release/signing.md`](../release/signing.md#tcc-and-runtime-lessons). This research does not
alter the entitlement allowlist, signing identity, usage strings, or any project setting.

## Selected minimum API set for later Studio briefs

This is a floor contract, not an implementation design:

1. **Camera:** `AVCaptureDevice.DiscoverySession`, `.continuityCamera`,
   `isContinuityCamera`, exact-device `AVCaptureDeviceInput`,
   `AVCaptureVideoDataOutput`, and disconnection observation.
2. **Foreground:** `VNGeneratePersonSegmentationRequest` for the hard person-only baseline;
   `VNGenerateForegroundInstanceMaskRequest`, `VNGeneratePersonInstanceMaskRequest`,
   `VNTrackObjectRequest`, and optical flow remain prototype candidates rather than guarantees.
3. **Composition:** `CIImage` over pixel buffers, a Metal-backed `CIContext`, mask blending,
   and render to a writer-owned `CVPixelBuffer`; custom Metal is optional.
4. **Screen/audio:** `SCContentFilter`, `SCStreamConfiguration`, `SCStream`, screen and system-
   audio outputs; ScreenCaptureKit microphone output is available if
   [#48](https://github.com/timharris707/grab-rabbit/issues/48) selects it.
5. **Timing/writing:** `SCStream.synchronizationClock`, explicit compositor PTS,
   `AVAssetWriter`, real-time `AVAssetWriterInput`s, readiness/backpressure checks, and a pixel-
   buffer adaptor.
6. **Effects:** Background Replacement enabled/active/support; Center Stage enabled/active/
   support and chosen control mode; Studio Light enabled/active/support; Presenter Overlay
   stream callbacks plus frame metadata. The last item supports positive fail-closed detection
   during a no-writer pre-recording observation stream, but Apple does not document bounded
   silence as conclusive; Tim must choose user confirmation, bounded non-conclusive observation,
   or a stronger enforcement guarantee.

## Acceptance-criteria matrix

| [#44](https://github.com/timharris707/grab-rabbit/issues/44) acceptance criterion | Evidence/result | Status |
|---|---|---|
| Findings file with Apple primary documentation and installed SDK interfaces | This file cites Apple Documentation/Support inline and quotes exact installed declarations with SDK provenance. | Met |
| Inventory Continuity Camera, masks, tracking/flow, metadata/depth, composition, ScreenCaptureKit, writer timing, and effects | Sections 1–8 cover all eight requested categories and name the minimum API set. | Met |
| For every material symbol: availability/change, architecture/device constraints, statefulness, entitlement/permission, public status | Per-category tables plus hardware and permission matrices; all selected symbols are public SDK/API. | Met |
| Determine detection/control for Background Replacement, Presenter Overlay, Center Stage, and Studio Light | Effects matrix distinguishes readonly state, writable Center Stage mode, positive Presenter detection after `SCStream` starts but before writing, missing direct controls, and the non-conclusive bounded-negative limit. | Met, with explicit Tim tradeoff |
| Evidence-backed Tahoe point recommendation and named quality/product tradeoff | Tahoe 26.0 + arm64 recommendation; Presenter Overlay question stated verbatim; quality/performance deferred to prototypes. | Met |
| Separate Tim's Apple-silicon ruling from technical requirements | Hardware matrix separates OS/API, effect, camera-model, optional HDR, and product constraints. | Met |
| Link findings from ticket; one-line verdict in map; no deployment change | Map carries the one-line verdict and retains the [#44](https://github.com/timharris707/grab-rabbit/issues/44) pointer. The [ticket summary](https://github.com/timharris707/grab-rabbit/issues/44#issuecomment-5309709048) links these findings and records the feature-level verdict. Repository settings are untouched. | Met |

## Remaining uncertainties (not hidden as facts)

1. **Tim adjudication:** the exact Presenter Overlay preflight question at the top of this file.
2. **Runtime and quality:** Apple documentation does not prove mask stability, throughput,
   thermal behavior, A/V drift, or edge quality on Tim's cameras. Those belong to the claimed
   prototype tickets.
3. **Optional frame attachments:** a Continuity Camera may vend additional attachments in a
   particular configuration, but no public macOS contract guarantees raw depth, calibration,
   ISO, exposure duration, or white-balance gains. Implementation may log optional metadata;
   it must not depend on it.
4. **Point-release bugs:** no required symbol forces a point release after 26.0. If a prototype
   uncovers an Apple bug fixed only later, that concrete evidence can reopen the runtime floor.
   The installed 26.5 environment alone cannot pre-decide that.

## Reproduction and audit commands

These read-only commands produced the declaration evidence and checks:

```bash
xcodebuild -version
sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx --show-sdk-version

rg -n 'ContinuityCamera|ForegroundInstance|PersonInstance|PersonSegmentation|OpticalFlow|TrackObject|CenterStage|StudioLight|BackgroundReplacement|PresenterOverlay|outputVideoEffect|startCapture|addRecordingOutput|captureMicrophone|CameraIntrinsicMatrix|cameraCalibrationDataDelivery|supportedDepthDataFormats|activeDepthDataFormat' \
  "$sdk/System/Library/Frameworks" --glob '*.{h,swiftinterface}'

av_headers="$sdk/System/Library/Frameworks/AVFoundation.framework/Versions/A/Headers"
rg -n '@property.*\b(lensPosition|exposureDuration|ISO|deviceWhiteBalanceGains|activeDepthDataFormat|supportedDepthDataFormats|cameraIntrinsicMatrixDeliverySupported|cameraIntrinsicMatrixDeliveryEnabled|cameraCalibrationDataDeliverySupported|cameraCalibrationDataDeliveryEnabled)\b.*API_(AVAILABLE|UNAVAILABLE)' \
  "$av_headers/AVCaptureDevice.h" \
  "$av_headers/AVCaptureSession.h" \
  "$av_headers/AVCapturePhotoOutput.h"

core_media_header="$sdk/System/Library/Frameworks/CoreMedia.framework/Versions/A/Headers/CMSampleBuffer.h"
rg -n -A1 '^CM_EXPORT const CFStringRef kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix' \
  "$core_media_header"

rg -n 'API_AVAILABLE\(macosx?\(26\.[1-9]|@available\(macOS 26\.[1-9]' \
  "$sdk/System/Library/Frameworks/AVFoundation.framework" \
  "$sdk/System/Library/Frameworks/Vision.framework" \
  "$sdk/System/Library/Frameworks/ScreenCaptureKit.framework" \
  "$sdk/System/Library/Frameworks/CoreImage.framework" \
  "$sdk/System/Library/Frameworks/Metal.framework" \
  "$sdk/System/Library/Frameworks/CoreVideo.framework" \
  "$sdk/System/Library/Frameworks/CoreMedia.framework" \
  --glob '*.{h,swiftinterface}'

rg -n -i 'presenter.?overlay|outputVideoEffect|video.?effect' \
  "$sdk/System/Library/Frameworks/AVFoundation.framework" \
  "$sdk/System/Library/Frameworks/ScreenCaptureKit.framework" \
  "$sdk/System/Library/Frameworks/CoreMediaIO.framework" \
  --glob '*.{h,swiftinterface}'

curl -LfsS 'https://developer.apple.com/tutorials/data/documentation/screencapturekit.json' \
  | jq -r '.primaryContentSections[].content[]?
    | select(any(.inlineContent[]?; .code? == "NSScreenCaptureUsageDescription"))
    | [.inlineContent[] | (.text // .code)] | join("")'

probe=docs/research/probes/studio-platform-api-floor.swift
xcrun swiftc -typecheck -target arm64-apple-macosx15.0 -sdk "$sdk" "$probe"
xcrun swiftc -typecheck -target arm64-apple-macosx26.0 -sdk "$sdk" "$probe"
xcrun swiftc -typecheck -target x86_64-apple-macosx26.0 -sdk "$sdk" "$probe"
```

## Apple primary sources

[^tahoe-release]: Apple, [About the security content of macOS Tahoe 26](https://support.apple.com/en-us/125110), and [Apple security releases](https://support.apple.com/en-us/100100). The latter separately records 26, 26.0.1, and 26.1.
[^tahoe-hardware]: Apple, [macOS Tahoe 26 is compatible with these computers](https://support.apple.com/en-us/122867), including listed Intel models.
[^continuity-support]: Apple, [Continuity Camera: Use iPhone as a webcam for Mac](https://support.apple.com/en-us/102546).
[^video-effects]: Apple, [Use video effects and mic modes during video calls on Mac](https://support.apple.com/en-us/105117).
[^center-stage-hardware]: Apple, [Use Center Stage to keep you centered in the camera frame](https://support.apple.com/en-us/111102).
[^discovery]: Apple, [`AVCaptureDevice.DiscoverySession`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/discoverysession).
[^continuity-type]: Apple, [`AVCaptureDeviceTypeContinuityCamera`](https://developer.apple.com/documentation/avfoundation/avcapturedevicetypecontinuitycamera).
[^continuity-property]: Apple, [`AVCaptureDevice.isContinuityCamera`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iscontinuitycamera).
[^video-output]: Apple, [`AVCaptureVideoDataOutput`](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput).
[^preferred-camera]: Apple, [`AVCaptureDevice.systemPreferredCamera`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/systempreferredcamera).
[^capture-permission]: Apple, [`AVCaptureDevice.authorizationStatus(for:)`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus(for:)) and [`requestAccess(for:)`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/requestaccess(for:completionhandler:)).
[^person-segmentation]: Apple, [`VNGeneratePersonSegmentationRequest`](https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest) and [`VNStatefulRequest`](https://developer.apple.com/documentation/vision/vnstatefulrequest).
[^foreground-mask]: Apple, [`VNGenerateForegroundInstanceMaskRequest`](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest).
[^person-instance]: Apple, [`VNGeneratePersonInstanceMaskRequest`](https://developer.apple.com/documentation/vision/vngeneratepersoninstancemaskrequest).
[^instance-observation]: Apple, [`VNInstanceMaskObservation`](https://developer.apple.com/documentation/vision/vninstancemaskobservation).
[^object-tracking]: Apple, [`VNTrackObjectRequest`](https://developer.apple.com/documentation/vision/vntrackobjectrequest).
[^generated-flow]: Apple, [`VNGenerateOpticalFlowRequest`](https://developer.apple.com/documentation/vision/vngenerateopticalflowrequest).
[^tracked-flow]: Apple, [`VNTrackOpticalFlowRequest`](https://developer.apple.com/documentation/vision/vntrackopticalflowrequest).
[^vision-compute]: Apple, [`VNRequest.supportedComputeStageDevices`](https://developer.apple.com/documentation/vision/vnrequest/supportedcomputestagedevices).
[^camera-iso]: Apple, [`AVCaptureDevice.ISO`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iso), [`exposureDuration`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposureduration), and [`lensPosition`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/lensposition).
[^camera-white-balance]: Apple, [`AVCaptureDevice.deviceWhiteBalanceGains`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicewhitebalancegains).
[^depth-format]: Apple, [`AVCaptureDevice.Format.supportedDepthDataFormats`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/supporteddepthdataformats) and [`activeDepthDataFormat`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activedepthdataformat).
[^camera-calibration-delivery]: Apple, [`AVCaptureConnection.isCameraIntrinsicMatrixDeliverySupported`](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/iscameraintrinsicmatrixdeliverysupported), [`isCameraIntrinsicMatrixDeliveryEnabled`](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/iscameraintrinsicmatrixdeliveryenabled), [`AVCapturePhotoOutput.isCameraCalibrationDataDeliverySupported`](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/iscameracalibrationdatadeliverysupported), and [`AVCapturePhotoSettings.isCameraCalibrationDataDeliveryEnabled`](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/iscameracalibrationdatadeliveryenabled).
[^camera-intrinsic-matrix]: Apple, [`kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`](https://developer.apple.com/documentation/coremedia/kcmsamplebufferattachmentkey_cameraintrinsicmatrix).
[^ci-image]: Apple, [`CIImage.imageWithCVPixelBuffer:`](https://developer.apple.com/documentation/coreimage/ciimage/imagewithcvpixelbuffer:).
[^ci-context]: Apple, [`CIContext.init(mtlDevice:)`](https://developer.apple.com/documentation/coreimage/cicontext/init(mtldevice:)-swey).
[^metal-device]: Apple, [`MTLCreateSystemDefaultDevice()`](https://developer.apple.com/documentation/metal/mtlcreatesystemdefaultdevice()).
[^scstream]: Apple, [`SCStream`](https://developer.apple.com/documentation/screencapturekit/scstream) and [Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos).
[^stream-output]: Apple, [`SCStreamOutputType`](https://developer.apple.com/documentation/screencapturekit/scstreamoutputtype).
[^sck-microphone]: Apple, [`SCStreamConfiguration.captureMicrophone`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone) and [`microphoneCaptureDeviceID`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/microphonecapturedeviceid).
[^screen-permission]: Apple, [Control access to screen and system audio recording on Mac](https://support.apple.com/guide/mac-help/control-access-to-screen-and-system-audio-recording-mchld6aa7d23/mac).
[^screen-capture-permission]: Apple, [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit), which instructs apps to add the exact `NSScreenCaptureUsageDescription` key with purpose copy before capturing.
[^asset-writer]: Apple, [`AVAssetWriter`](https://developer.apple.com/documentation/avfoundation/avassetwriter) and [`startSession(atSourceTime:)`](https://developer.apple.com/documentation/avfoundation/avassetwriter/startsession(atsourcetime:)).
[^writer-input]: Apple, [`AVAssetWriterInput.expectsMediaDataInRealTime`](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/expectsmediadatainrealtime).
[^pixel-adaptor]: Apple, [`AVAssetWriterInputPixelBufferAdaptor.append(_:withPresentationTime:)`](https://developer.apple.com/documentation/avfoundation/avassetwriterinputpixelbufferadaptor/append(_:withpresentationtime:)).
[^background-enabled]: Apple, [`AVCaptureDevice.isBackgroundReplacementEnabled`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isbackgroundreplacementenabled) and [`isBackgroundReplacementActive`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isbackgroundreplacementactive).
[^presenter-start]: Apple, [`SCStreamDelegate.outputVideoEffectDidStart(for:)`](https://developer.apple.com/documentation/screencapturekit/scstreamdelegate/outputvideoeffectdidstart(for:)) and [`outputVideoEffectDidStop(for:)`](https://developer.apple.com/documentation/screencapturekit/scstreamdelegate/outputvideoeffectdidstop(for:)).
[^presenter-rect]: Apple, [`SCStreamFrameInfo.presenterOverlayContentRect`](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/presenteroverlaycontentrect).
[^presenter-alert]: Apple, [`SCStreamConfiguration.presenterOverlayPrivacyAlertSetting`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/presenteroverlayprivacyalertsetting).
[^system-effects-ui]: Apple, [`AVCaptureDevice.showSystemUserInterface(_:)`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/showsystemuserinterface(_:)), a nonblocking method that opens the system UI for the user to change video effects or microphone modes.
[^center-stage-api]: Apple, [`AVCaptureDevice.centerStageControlMode`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/centerstagecontrolmode), [`isCenterStageEnabled`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iscenterstageenabled), and [`isCenterStageActive`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iscenterstageactive).
[^studio-light-api]: Apple, [`AVCaptureDevice.isStudioLightEnabled`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isstudiolightenabled) and [`isStudioLightActive`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isstudiolightactive).
[^camera-entitlement]: Apple, [`com.apple.security.device.camera`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.camera) and [`NSCameraUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nscamerausagedescription).
[^microphone-entitlement]: Apple, [`com.apple.security.device.audio-input`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input) and [`NSMicrophoneUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription).
