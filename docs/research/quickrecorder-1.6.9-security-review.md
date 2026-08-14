# QuickRecorder 1.6.9 codebase and security review

- Status: research complete; implementation has not started
- Date: 2026-08-14
- Driving item: [grab-rabbit #2](https://github.com/timharris707/grab-rabbit/issues/2)

## Executive verdict

QuickRecorder 1.6.9 should not be redistributed or treated as a safe implementation baseline without remediation. The pinned source builds successfully and contains useful controls, but the review confirmed five high-priority issues:

1. The app embeds Sparkle 2.6.0, which is affected by a reviewed high-severity update-signature bypass and later updater vulnerabilities.
2. The official 1.6.9 artifact is an Apple Development build with debug/test entitlements; Gatekeeper rejects both the app and unsigned DMG, and no notarization ticket is stapled.
3. Asynchronous audio remux cleanup can delete a subsequent recording.
4. quick screen/window shortcuts force system-audio capture even when the user turned that capture off.
5. a stale explicit display choice can silently fall back to and record a different display.

The full result is **0 confirmed critical issues, 5 high, 11 medium, and 5 low hardening observations**. Two additional runtime-dependent paths—QMA offline-render nonprogress and overlapping selector-thumbnail refreshes—are explicitly recorded as unproven hypotheses. No first-party remote-code-execution path, credential, private signing key, telemetry SDK, or arbitrary shell-command construction was found.

The highest-value sequence is:

1. stop shipping the existing updater and release pipeline unchanged;
2. establish a production signing/notarization gate and upgrade Sparkle directly to 2.9.5 or later;
3. introduce one immutable, serialized recording-session state machine;
4. make capture choices fail closed and honor audio/target consent;
5. harden QMA/media parsing and contain it with App Sandbox or a narrowly sandboxed service;
6. add the regression gates in this report before fixing the individual defects.

## Baseline and scope

The reviewed pin is the upstream lightweight tag [1.6.9](https://github.com/lihaoyun6/QuickRecorder/tree/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e):

| Property | Verified value |
|---|---|
| Commit | 0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e |
| Git tree | 618bcb07fdc94eeef31230a4ee6147a7e41949c1 |
| Commit subject | Fixed: Crash on Intel-based Macs |
| Commit signature | unsigned |
| Tag object | lightweight tag pointing directly to the commit |
| Tracked files | 155 |
| Aggregate tracked bytes | 3,722,987 |
| First-party Swift | 27 files, 7,882 lines |

The tag's appcast still advertises 1.6.8 at its head ([tagged appcast](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/appcast.xml#L5-L26)); the 1.6.9 entry was added in the next, appcast-only commit [e820517](https://github.com/lihaoyun6/QuickRecorder/commit/e82051787f013ec2e811fcceab2d7de80e9d4dbe).

### Complete file accounting

| Category | Files | Review performed |
|---|---:|---|
| First-party Swift | 27 | Every line read; security-sensitive APIs and state transitions traced |
| Main asset catalog | 99 | 37 JSON catalogs parsed; 60 PNGs decoded/CRC-checked; SVG inspected; stray .DS_Store triaged |
| Preview asset catalog | 1 | JSON parsed |
| Localizations and credits | 10 | Parsed; links, embedded objects, and permission strings inspected |
| Xcode project/workspace/scheme/package lock | 5 | Build phases, settings, package requirements, pins, and test configuration inspected |
| Info.plist and entitlements | 2 | Document/automation/update surfaces and permissions inspected |
| Scripting definition | 1 | Every command and argument mapped to its handler |
| Root text/release metadata | 5 | README files, license, ignore rules, and full appcast inspected |
| Root images | 5 | Decoded and metadata-checked |
| **Total** | **155** | Reconciled to git ls-tree |

The 27 Swift files were:

    QuickRecorder/AVContext.swift
    QuickRecorder/QuickRecorderApp.swift
    QuickRecorder/RecordEngine.swift
    QuickRecorder/SCContext.swift
    QuickRecorder/Supports/AppleScript.swift
    QuickRecorder/Supports/GroupForm.swift
    QuickRecorder/Supports/SleepPreventer.swift
    QuickRecorder/Supports/Sparkle.swift
    QuickRecorder/Supports/WindowAccessor.swift
    QuickRecorder/Supports/WindowHighlighter.swift
    QuickRecorder/ViewModel/AppBlockSelector.swift
    QuickRecorder/ViewModel/AppSelector.swift
    QuickRecorder/ViewModel/AreaSelector.swift
    QuickRecorder/ViewModel/CameraOverlayer.swift
    QuickRecorder/ViewModel/ContentView.swift
    QuickRecorder/ViewModel/ContentViewNew.swift
    QuickRecorder/ViewModel/MousePointer.swift
    QuickRecorder/ViewModel/PreviewView.swift
    QuickRecorder/ViewModel/QmaPlayer.swift
    QuickRecorder/ViewModel/ScreenMagnifier.swift
    QuickRecorder/ViewModel/ScreenSelector.swift
    QuickRecorder/ViewModel/SettingsView.swift
    QuickRecorder/ViewModel/StatusBar.swift
    QuickRecorder/ViewModel/SurpriseView.swift
    QuickRecorder/ViewModel/VideoEditor.swift
    QuickRecorder/ViewModel/WinSelector.swift
    QuickRecorder/ViewModel/iDeviceSelector.swift

The five direct SwiftPM pins were AECAudioStream 0eab971, KeyboardShortcuts 2.2.4, MatrixColorSelector 0853e68, Sparkle 2.6.0, and SwiftLAME e8256a8 ([Package.resolved](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved#L3-L47)).

## Verification performed

The following read-only or build-output-only probes were run against an archive of the exact tag:

| Probe | Result |
|---|---|
| Unsigned universal Release build from the repository binding | passed |
| Standard Release compiler warnings | 0 |
| Xcode Analyze action | passed; 8 application Sendable warnings plus 1 AppIntents metadata warning |
| Debug build with complete strict concurrency checking | passed in Swift 5 mode; 431 warning lines, 367 unique lines |
| Application test targets | 0; the scheme has an empty TestAction ([scheme](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder.xcodeproj/xcshareddata/xcschemes/QuickRecorder.xcscheme#L25-L31)) |
| Asset JSON | 38/38 parsed |
| PNG decode | 65/65 passed |
| XML/plist validation | passed |
| Secret/credential scan | no private key or credential found; SUPublicEDKey is an expected public update key |
| First-party network surface | Sparkle update feed only; fixed external links; no analytics/telemetry |
| Privacy declarations | No `PrivacyInfo.xcprivacy` or privacy-policy document exists in the [155-file tagged tree](https://github.com/lihaoyun6/QuickRecorder/tree/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e), and none was bundled in the [inspected 1.6.9 app](https://github.com/lihaoyun6/QuickRecorder/releases/tag/1.6.9). Camera and microphone purpose strings are supplied through the [Debug and Release project settings](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder.xcodeproj/project.pbxproj#L498-L541) with [Simplified Chinese](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/zh-Hans.lproj/InfoPlist.strings#L8-L9) and [Traditional Chinese](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/zh-Hant.lproj/InfoPlist.strings#L8-L9) localized overrides. |

The official [1.6.9 release](https://github.com/lihaoyun6/QuickRecorder/releases/tag/1.6.9) was also inspected without executing it:

| Artifact probe | Result |
|---|---|
| DMG size | 4,651,431 bytes, matching appcast and GitHub |
| DMG SHA-256 | 5a5901ff071a8a081c13224ffa8fa749c73e107b05b856b37e4368ac03d70ed0, matching GitHub |
| Sparkle Ed25519 signature | verified against the embedded SUPublicEDKey |
| App architecture/version | universal x86_64 + arm64; 1.6.9 build 169 |
| codesign deep/strict integrity | passed |
| App signer | Apple Development: lihaoyun11@gmail.com; certificate expired 2025-06-15 |
| Hardened runtime | present |
| Gatekeeper app assessment | rejected |
| Stapled notarization ticket | absent |
| DMG signature/Gatekeeper | DMG unsigned; rejected |
| GitHub build attestation | absent |
| GitHub release immutability | false |

These results establish integrity of the bytes that were inspected. They do not make the development-signed artifact a production-trustworthy release.

## Existing controls worth preserving

- The updater feed and enclosures use HTTPS, the app embeds an Ed25519 public key, and the 1.6.9 full and delta artifacts verify against it ([Info.plist](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/Info.plist#L43-L50)).
- Hardened runtime is enabled in both build configurations ([project settings](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder.xcodeproj/project.pbxproj#L519-L552)).
- Microphone access goes through the operating-system permission API and the preference is disabled after denial ([SCContext.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/SCContext.swift#L227-L240)).
- Output-directory type and creation errors are checked before capture ([RecordEngine.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/RecordEngine.swift#L27-L43)).
- Normal stop attempts to stop capture/taps, restore sleep, close overlays, and finish writers ([SCContext.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/SCContext.swift#L329-L399)).
- Gifski launch uses a fixed executable and an argument array, not a shell command ([PreviewView.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/PreviewView.swift#L155-L164)).
- Sharing, clipboard export, and external App Store navigation require explicit user actions.
- No custom URL scheme, project shell build phase, package plugin, macro, executable resource, private key, or telemetry SDK was found.

## Findings

Severity here combines likely impact and required preconditions for this product. It is not a substitute for CVSS; privacy and data-loss defects can be High even when they are not remote exploits.

### QR-169-01 — High: Sparkle 2.6.0 is affected by known updater vulnerabilities

Sparkle is locked to 2.6.0 in both the project and lockfile ([project requirement](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder.xcodeproj/project.pbxproj#L579-L587), [resolved pin](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved#L31-L38)). The updater starts during app initialization ([QuickRecorderApp.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/QuickRecorderApp.swift#L38-L49)), and the UI supports automatic checks/downloads ([Sparkle.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/Supports/Sparkle.swift#L41-L63)).

Applicable primary advisories are:

- [CVE-2025-0509 / GHSA-wc9m-r3v6-9p5h](https://github.com/advisories/GHSA-wc9m-r3v6-9p5h), GitHub-reviewed High: GitHub's affected-version record lists `<= 2.6.3` and 2.6.4 as the first patched version for replacement of an existing signed update while bypassing (Ed)DSA signing checks. The advisory's CVSS vector requires adjacent access, high complexity, high privileges, and user interaction; HTTPS GitHub hosting lowers likelihood but does not remove the affected code.
- [CVE-2026-47121 / GHSA-hg88-v3cw-3qrh](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-hg88-v3cw-3qrh), Medium: a malicious, validly signed delta can traverse an intermediate symlink. The stated precondition is compromise of the EdDSA signing key.
- [GHSA-gmj2-gq3j-vqmj](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-gmj2-gq3j-vqmj), Medium: the first symlink fix remained incomplete through 2.9.4.
- [CVE-2026-47122 / GHSA-g3hp-f6mg-559v](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-g3hp-f6mg-559v), Medium: a tight local race can spoof installer release metadata; installed-code integrity is not affected.

There is a primary-source version-range conflict: Sparkle's contemporaneous [2.6.1 release notes](https://github.com/sparkle-project/Sparkle/releases/tag/2.6.1) say 2.6.1 fixed this replacement/signature-bypass issue and that all older releases were affected, whereas GitHub's later reviewed advisory lists releases through 2.6.3 as affected. Both sources classify the pinned 2.6.0 as affected, so the baseline conclusion is unchanged. As of the review date, [Sparkle 2.9.5](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.5) is the current release and contains the more complete destination-symlink hardening; the direct-to-2.9.5 recommendation therefore also remains unchanged.

Recommended safeguard: upgrade directly to 2.9.5 or later; do not publish new delta updates before upgrading; isolate the Ed25519 key from GitHub credentials and general build hosts; document key access, backup, revocation, and rotation; block releases on applicable advisories.

Regression tripwire: install a prior fixture version and prove that a valid full/delta update succeeds while wrong-key, altered-byte, mismatched-length/version, downgrade, duplicate-item, and symlink/path-escape fixtures fail closed. CI must inspect the built framework version, not only Package.resolved.

### QR-169-02 — High: the published artifact fails the production distribution trust gate

The Release configuration explicitly selects Apple Development ([project.pbxproj](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder.xcodeproj/project.pbxproj#L519-L552)). The source entitlement file contains only camera and audio-input keys ([QuickRecorder.entitlements](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/QuickRecorder.entitlements#L4-L9)), but the official app's signature additionally contains:

- com.apple.security.get-task-allow = true;
- a read-only absolute-path exception for /;
- test-manager and core-symbolication Mach lookup exceptions.

The official bytes pass deep signature integrity and carry hardened runtime, but the app and unsigned DMG are rejected by Gatekeeper and have no stapled notarization ticket. Apple's [TN2415](https://developer.apple.com/library/archive/technotes/tn2415/_index.html) says get-task-allow controls whether Xcode's debugger can attach. Apple's [Developer ID](https://developer.apple.com/developer-id/) and [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) guidance describe the trust path for software distributed outside the Mac App Store.

Impact: users are pushed toward Gatekeeper-bypass instructions; the debug entitlement weakens the process boundary of an unsandboxed app that already holds screen, microphone, and camera trust. This is not a remote exploit by itself.

Recommended safeguard: produce an Archive/export product with Developer ID Application, trusted timestamp, notarization, and stapling; sign the DMG; enforce an exact final-artifact entitlement allowlist; reject get-task-allow, temporary exceptions, disabled library validation, JIT, and unsigned executable memory unless separately approved.

Regression tripwire:

    codesign --verify --deep --strict QuickRecorder.app
    spctl --assess --type execute QuickRecorder.app
    xcrun stapler validate QuickRecorder.app

CI must inspect every nested code object and fail unless signer, team, runtime flags, and entitlements match policy. The DMG must pass its own signature/Gatekeeper check.

### QR-169-03 — High: asynchronous remux cleanup can delete a subsequent recording

Video with microphone and system audio writes intermediates and starts asynchronous mixing during stop ([RecordEngine.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/RecordEngine.swift#L373-L435), [SCContext.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/SCContext.swift#L357-L386)). Recording state becomes available before the nested exports finish ([SCContext.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/SCContext.swift#L449-L475)). Although mixAudioTracks receives an immutable videoURL, its success callback deletes the mutable global filePath ([SCContext.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/SCContext.swift#L714-L821)).

Preconditions: remux, microphone, and system audio are enabled; recording A stops; recording B starts before A's export completes. A's callback can delete B's active output. Failed exports can also leave sensitive intermediates.

Recommended safeguard: create an immutable per-recording job containing all URLs and option snapshots; clean only captured job URLs; keep the session in postprocessing until completion; use a private staging directory and atomic final replacement.

Regression tripwire: inject delayed two-stage exporters, start B while A is pending, complete A, and assert that only A's exact intermediates are removed and B remains present, writable, and playable. Separately force first-stage failure, first-stage cancellation, second-stage failure, and second-stage cancellation. In every case, job-owned intermediates must be securely removed or moved to an explicit user-visible quarantine/recovery location, completion must not be claimed, and no undisclosed plaintext residue may remain in output, temporary, or shared directories.

### QR-169-04 — High privacy: quick screen/window shortcuts override the audio opt-out

The current-screen and topmost-window shortcuts use fastStart ([QuickRecorderApp.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/QuickRecorderApp.swift#L320-L341)). Capture enables system audio when recordWinSound OR fastStart OR audioOnly is true ([RecordEngine.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/RecordEngine.swift#L216-L224)). The settings UI presents Record System Audio, Record Current Screen, and Record Topmost Window as distinct shortcuts ([SettingsView.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/SettingsView.swift#L250-L268)).

Impact: calls, alerts, music, or other system audio are recorded despite the stored audio choice.

Recommended safeguard: fast start may skip UI/countdown, but it must not alter media consent. Capture audio only from an explicit immutable per-session choice.

Regression tripwire: matrix-test screen/window starts with fastStart true/false and recordWinSound true/false. An audio track must exist only when explicitly enabled.

### QR-169-05 — High privacy: stale explicit display selection silently falls back to another display

Refreshing the screen selector does not clear its selected display, and Start is disabled only when selected is nil ([ScreenSelector.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/ScreenSelector.swift#L94-L159)). Preparation attempts to resolve that object in refreshed content, but if it is absent it silently substitutes the display under the mouse ([RecordEngine.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/RecordEngine.swift#L44-L59)).

Preconditions: monitor disconnect/topology change during selection or countdown, or refresh retaining a stale object.

Recommended safeguard: clear selection on refresh; resolve the chosen stable display ID immediately before capture; abort visibly if unavailable. Never substitute a target after explicit selection.

Regression tripwire: remove the selected mocked display during countdown and assert that no SCStream is created and no other display is captured.

### QR-169-06 — Medium: the QMA trust boundary has multiple validation and resource failures

QMA is registered as an owned package document type ([Info.plist](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/Info.plist#L22-L40)) and opens through DocumentGroup ([QuickRecorderApp.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/QuickRecorderApp.swift#L45-L60)). Four confirmed weaknesses share this boundary:

1. Both readers call regularFileContents without first checking isRegularFile ([QmaPlayer.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/QmaPlayer.swift#L299-L345), [alternate loader](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/QmaPlayer.swift#L369-L388)). A safe host reproduction made sys.m4a a symlink; Foundation reported a symbolic wrapper, then regularFileContents raised an uncaught NSInternalInconsistencyException.
2. info.json and both entire audio members are retained as Data, and the immediate loader materializes them before playback reopens the files from disk. File size is attacker-controlled and unbounded, allowing memory exhaustion.
3. sysVol and micVol are not checked for finite/range-safe values before UI conversion and AVAudioPlayerNode use. JSON values such as 1e20 make the percentage conversion to Int trap ([QmaPlayer.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/QmaPlayer.swift#L306-L345), [UI use](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/QmaPlayer.swift#L131-L155)).
4. MP3 export writes a predictable hidden intermediate and removes it only after conversion succeeds ([QmaPlayer.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/QmaPlayer.swift#L561-L625)). A safe reproduction placed a symlink at that staging name; AVAudioFile followed it and expanded an 8-byte victim to 557 bytes. The created audio mode was 0644.

The symlink overwrite requires export into a directory another actor can write and a user-writable target; it is user-level corruption, not privilege escalation. Conversion failure or ignored cleanup can leave a plaintext hidden recording.

Recommended safeguard: define a strict, versioned QMA schema; require a directory root and regular, non-link expected members; reject aliases/devices/unexpected members; whitelist formats; bound manifest/member sizes; require finite/ranged numbers; stream from validated stable handles or a private copy. Stage exports in a randomized private 0700 directory with exclusive 0600 files, then atomically replace only the approved destination.

Regression tripwire: a corpus must cover every member as regular/symlink/directory/alias/missing, malformed JSON, unexpected files, huge/sparse members, mismatched track formats/lengths, numeric extremes, replacement races, pre-existing stage files/symlinks, disk-full, cancellation, and converter failure. Every case must fail with a typed error, bounded RSS/time, no target modification, and no residue.

### QR-169-07 — Medium: VideoEditor double-decodes paths, permitting output escape and a crash

The trimmer obtains URL.path, calls removingPercentEncoding, force-unwraps it, and converts the result back to a file URL ([VideoEditor.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/VideoEditor.swift#L58-L71)). Opened URLs are forwarded into that trimmer ([QuickRecorderApp.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/QuickRecorderApp.swift#L193-L198)).

A safe Foundation probe confirmed:

    literal filename: %2E%2E%2Fescaped.mov
    decoded path:     /tmp/qreview/../escaped
    standardized out: /tmp/escaped (Cropped).mov

    literal filename: %ZZ.mov
    removingPercentEncoding result: nil

Thus a valid media file with a crafted literal filename can place a new cropped file outside its source directory after the user accepts trimming; malformed percent text crashes at the force unwrap. The generated timestamp suffix prevents an exact chosen-file overwrite in this path.

Recommended safeguard: never percent-decode URL.path. Derive output using URL component APIs or NSSavePanel, and verify that the standardized output parent equals an authorized directory.

Regression tripwire: use literal names containing %2E%2E%2F, %2F, %25, %ZZ, and composed/decomposed Unicode; assert containment and no trap.

### QR-169-08 — Medium: lack of sandboxing amplifies every parser and lifecycle defect

The built setting is ENABLE_APP_SANDBOX=NO, no app-sandbox entitlement exists, and the README treats sandboxing as unnecessary because the app is not intended for the App Store ([README.md](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/README.md#L35-L40)). Apple describes [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox) as restricting system-resource and user-data access to contain damage if an app is compromised; the benefit is not limited to App Store distribution.

The same unsandboxed process opens QMA/MOV/MP4, accepts Apple Events, updates itself, and carries screen/camera/microphone trust. A parser or dependency compromise therefore inherits broad user access.

Recommended safeguard: perform an explicit sandbox-feasibility decision. Prefer App Sandbox with user-selected files/security-scoped access. If whole-app sandboxing is infeasible, move untrusted document/media parsing into a narrowly sandboxed XPC service and minimize the main process's document/automation surface.

Regression tripwire: a boundary test must prove that parsing cannot read/write outside selected input, private staging, and approved output roots.

### QR-169-09 — Medium privacy: the blocklist is only a start-time snapshot

Bundle IDs are stored by the selector ([AppBlockSelector.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/AppBlockSelector.swift#L38-L56)), but recording resolves them only against applications in the initial cached shareable-content snapshot and builds one filter ([RecordEngine.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/RecordEngine.swift#L80-L118)). The UI discloses that apps launched later cannot be excluded ([SettingsView.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/SettingsView.swift#L279-L285)), so this is a documented limitation, not a hidden promise.

Impact: a password manager, messaging app, or other blocked app launched later can enter the recording.

Recommended safeguard: either update SCContentFilter as apps/windows change and offer fail-closed enforcement, or rename/present the feature unmistakably as a best-effort start-time filter.

Regression tripwire: launch a blocklisted fixture after capture starts and assert that its distinctive pixels never appear when strict mode is selected.

### QR-169-10 — Medium: AppleScript and countdown flows race global capture state

QuickRecorder enables Cocoa scripting ([Info.plist](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/Info.plist#L43-L46)) and exposes screen, area, application, window, system-audio, and preference commands ([Scriptable.sdef](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/Supports/Scriptable.sdef#L3-L66)).

Confirmed issues:

- record system audio temporarily changes persistent recordMic, calls synchronous preparation plus an unstructured Task, then immediately restores the preference ([AppleScript.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/Supports/AppleScript.swift#L180-L195), [RecordEngine.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/RecordEngine.swift#L133-L138)). Setup, start, and cleanup can observe different mic choices.
- Capture handlers check only stream before asynchronous content discovery, so concurrent Apple Events can both pass idle and race shared writers/state ([AppleScript.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/Supports/AppleScript.swift#L12-L39)).
- A replaced countdown retains its timer; an older, no-longer-visible countdown can later invoke its recording action ([ContentView.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/ContentView.swift#L297-L337), [panel replacement](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/ContentView.swift#L372-L386)).
- configure accepts an unbounded fps value although other arguments are validated ([AppleScript.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/Supports/AppleScript.swift#L201-L229)).

Apple Events/TCC authorization is a required precondition for a non-user sender; this review did not bypass or reset local TCC to test every sender type.

Recommended safeguard: make automation opt-in; decide whether capture commands require a visible confirmation; serialize every entry point through an idle → preparing/countdown → recording → stopping → postprocessing state machine; pass immutable per-session arguments; return deterministic script errors; cancel countdowns by session generation; accept only supported FPS values.

Regression tripwire: force suspension between preparation/start for both mic-option combinations; send parallel Apple Events and assert exactly one accepted session; replace countdown A with B and assert only B can fire; fuzz every scripting argument and caller policy.

### QR-169-11 — Medium: capture callbacks and stop/finalization are not serialized

Screen and audio callbacks use global concurrent queues ([RecordEngine.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/RecordEngine.swift#L285-L303)) and mutate shared timestamps, queues, and writer inputs ([RecordEngine.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/RecordEngine.swift#L489-L614)). Stop requests stopCapture without awaiting completion, then immediately marks inputs finished and finishes writing ([SCContext.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/SCContext.swift#L329-L386)).

A queued callback can append after markAsFinished, causing truncation, writer failure, or a state race. Complete strict-concurrency checking emitted 431 warning lines, including all mutable SCContext globals and multiple non-Sendable captures; this is supporting evidence, not 431 distinct vulnerabilities.

Recommended safeguard: one actor/serial executor owns session state and writer interaction; await stream shutdown and drain callbacks before finishing inputs; make stop/error/termination idempotent.

Regression tripwire: hold sample callbacks, initiate stop/error/quit, release callbacks, and assert no post-finish append. Run stress cases under Thread Sanitizer and make strict-concurrency warnings ratchet downward.

### QR-169-12 — Medium privacy: capture-derived data and sessions outlive their visible UI

Two independent paths were confirmed:

- Preview writes the first captured frame to fixed qr-preview.jpg, reads it back, and never deletes it ([SCContext.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/SCContext.swift#L479-L491), [write helper](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/QuickRecorderApp.swift#L580-L589)).
- iDevice preview starts AVCaptureSession, while its close button only closes windows and does not stop that session ([AVContext.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/AVContext.swift#L62-L117), [CameraOverlayer.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/CameraOverlayer.swift#L96-L100)).

Recommended safeguard: render preview in memory; if disk is unavoidable, use unique private files and delete on close/error/termination. Make every overlay own an idempotent session-stop token and show an authoritative indicator for every active capture source.

Regression tripwire: close preview/app and assert no temp artifact; close iDevice overlay and assert session.isRunning is false and no later sample arrives.

### QR-169-13 — Medium availability/privacy: magnifier captures too much and leaks per event

When enabled, every monitored mouse event takes a screenshot ([QuickRecorderApp.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/QuickRecorderApp.swift#L164-L180)). The helper composites every on-screen non-QuickRecorder window over infinite bounds and allocates a pointer array without deallocation ([QuickRecorderApp.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/QuickRecorderApp.swift#L549-L577)).

Impact: sustained mouse motion grows memory and repeatedly materializes more sensitive desktop imagery than the small magnified region requires.

Recommended safeguard: capture only a bounded cursor region, throttle to display refresh, reuse buffers, and deterministically deallocate.

Regression tripwire: inject 10,000 events; assert bounded live allocations/RSS and that requested capture bounds never exceed the magnifier crop.

### QR-169-14 — Medium: output naming and I/O failure handling permit collisions, traps, and residue

Output names have only second-level uniqueness ([SCContext.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/SCContext.swift#L180-L184)). Repeated frame saves can overwrite the same PNG; audio writer creation uses try!, and video writer creation suppresses an error into an implicitly unwrapped global before use ([RecordEngine.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/RecordEngine.swift#L317-L341), [video writer](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/RecordEngine.swift#L373-L435)). The first-party source contains 4 try!, 5 forced casts, 2 fatalError calls, and 8 assertionFailure calls; not all are attacker reachable, but several sit on file/capture boundaries.

Recommended safeguard: exclusive-create UUID/counter names, use private staging plus atomic replace, propagate every writer/file error through one idempotent rollback path, and remove force operations at external-state boundaries.

Regression tripwire: freeze the clock and create concurrent outputs; inject EEXIST, permission denial, full disk, disconnect, invalid defaults, and encoder failure; assert unique paths, truthful errors, no crash, and no residue.

### QR-169-15 — Medium: iDevice failure and termination paths can claim success or skip finalization

The stop path does nothing when the capture session has already stopped, even if movie output still needs teardown, and the delegate ignores its error while always notifying Recording Completed ([AVContext.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/AVContext.swift#L120-L151)). Application termination only stops SCContext.stream, while iDevice recording uses AVCaptureSession ([QuickRecorderApp.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/QuickRecorderApp.swift#L189-L191)).

Preconditions: USB disconnect, capture interruption, disk/encoder error, or quit during iDevice recording.

Recommended safeguard: include iDevice in the central session state machine; finalize regardless of session.isRunning; handle delegate error; wait for finalization during graceful termination; validate the final asset before success.

Regression tripwire: simulate disconnect/error/quit-mid-record and require a truthful failure; never emit completed unless the output is finalized and playable.

### QR-169-16 — Medium: release provenance and dependency policy are not reproducible

The source commit and lightweight tag are unsigned. GitHub reports the release as mutable, and no workflow, release script, export configuration, SBOM, or attestation exists in the tag. The binary's injected entitlements differ from source, proving that the packaging step is not reconstructible from the reviewed tree.

The checked-in lockfile is a useful control, but AECAudioStream and MatrixColorSelector declare mutable main-branch requirements ([project.pbxproj](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder.xcodeproj/project.pbxproj#L588-L603)). A lock regeneration can import new code without a semantic version change. SwiftLAME is revision-pinned but suppresses warnings and Clang static analysis for its bundled LAME C target.

Recommended safeguard: build once in CI from a signed annotated tag; make releases immutable; produce an SBOM and SLSA/Sigstore provenance; record source/Xcode/SDK/signer/notarization/hash data; publish appcast and release channels atomically; replace branch requirements with reviewed versions/revisions; disable automatic package resolution during release; review/fuzz the bundled LAME encoder without suppressing analyzer output.

Regression tripwire: compare tag, MARKETING_VERSION, build, Info.plist, appcast, asset sizes/digests/signatures, and package lock; fail on an unsigned tag, mutable release, missing attestation/SBOM, branch drift, advisory match, or final-artifact entitlement mismatch.

## Low hardening observations

1. Screen-permission denial schedules another content request every second indefinitely ([SCContext.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/SCContext.swift#L55-L90)). Stop after denial and retry only on explicit user action. Regression tripwire: return `userDeclined`, advance the controlled scheduler beyond one second, and assert that no automatic second content request occurs; one explicit Retry action may issue exactly one new request.
2. Preview Delete permanently removes the recording without confirmation or Trash recovery, and completion notifications include full paths that may appear on a lock screen ([PreviewView.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/PreviewView.swift#L88-L110), [notifications](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/SCContext.swift#L702-L710)).
3. Malformed or migrated savedArea defaults can crash through forced casts and required dictionary members ([AreaSelector.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/AreaSelector.swift#L282-L297)).
4. Video-trimmer observation tokens, an iDevice animation timer, and sleep assertions have incomplete ownership/cleanup and can retain media, file handles, timers, or sleep prevention across repeated use ([VideoEditor.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/VideoEditor.swift#L19-L38), [iDeviceSelector.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/iDeviceSelector.swift#L115-L135), [SleepPreventer.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/Supports/SleepPreventer.swift#L11-L25)).
5. The mutable appcast can load remote HTML image content; Ed25519 protects enclosure bytes, not feed text or remote subresources ([appcast.xml](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/appcast.xml#L11-L25)). Prefer inert/local release notes and document GitHub update-check network metadata.

## Explicit hypothesis and unknowns

- **Hypothesis, Medium if reachable:** QMA offline export loops until manualRenderingSampleTime reaches duration, but non-success statuses break only the switch, not the loop ([QmaPlayer.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/QmaPlayer.swift#L585-L601)). A persistent non-advancing status would busy-loop. A simple host probe advanced normally, so crafted-file reachability was not proven. Add an injected-renderer test with a persistent non-success status, deadline, cancellation, and no-progress limit.
- **Hypothesis, Medium availability/privacy if reachable:** screen and window thumbnail refreshes clear shared stream/target arrays without first stopping or awaiting earlier captures, while callbacks map a stream to the current arrays by index and capture setup appends each stream only after `startCapture` returns ([ScreenSelector.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/ScreenSelector.swift#L176-L213), [WinSelector.swift](https://github.com/lihaoyun6/QuickRecorder/blob/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e/QuickRecorder/ViewModel/WinSelector.swift#L270-L326)). Depending on ScreenCaptureKit callback/start ordering, overlapping refreshes could leave obsolete thumbnail captures running, associate a stale frame with a refreshed target, or race an index lookup. Runtime reachability and persistence after array removal were not proven. Regression tripwire: use delayed controllable streams, overlap refresh A with refresh B, and assert every A stream is stopped exactly once before removal, active-stream count remains bounded, stale A callbacks cannot mutate B thumbnails or indexes, and view-model teardown leaves no capture running.
- Actual Apple Events/TCC behavior remains to be tested for signed/unsigned apps, Terminal, Shortcuts, and remote events on supported macOS versions. No TCC state was altered for this review.
- Physical camera/iDevice disconnect and multi-display hot-plug behavior was source-reviewed but not hardware-tested.
- AVFoundation behavior for every malformed media container and macOS 12-current runtime was not exhaustively fuzzed.
- The direct dependency graph and manifests were reviewed; the full source of Sparkle, KeyboardShortcuts, and every bundled LAME C function was not line-audited. Advisory absence for the other packages is not proof of safety.
- Product intent for fast-start audio, blocklist guarantees, automation trust, distribution audience, and key custody is human-held. It is captured in [the decision questionnaire](questionnaire-quickrecorder-1.6.9.md).

## Regression program

The project currently has no application test target, so the first implementation slice should create the harness and make each previously reported defect a named tripwire.

### P0 release blockers

| Gate | Covers |
|---|---|
| Final artifact signer, notarization, Gatekeeper, nested-code, and entitlement allowlist | QR-169-02 |
| Sparkle adversarial full/delta fixtures and built-framework version/advisory gate | QR-169-01 |
| Recording-session state and delayed remux cross-record isolation | QR-169-03, QR-169-11 |
| Capture consent matrix and stale-target fail-closed tests | QR-169-04, QR-169-05 |
| QMA filesystem corpus, size/numeric fuzzing, symlink overwrite, and cleanup | QR-169-06 |
| Video filename containment/crash corpus | QR-169-07 |

### P1 security and privacy

| Gate | Covers |
|---|---|
| App Sandbox/XPC filesystem-boundary integration tests | QR-169-08 |
| Dynamic blocklist fixture and declared best-effort/strict behavior | QR-169-09 |
| Parallel Apple Events, immutable option snapshot, caller policy, and countdown cancellation | QR-169-10 |
| Thread Sanitizer stop/error/quit stress and strict-concurrency warning ratchet | QR-169-11 |
| Temp-artifact absence and visible-session lifecycle tests | QR-169-12 |
| Magnifier capture-bounds and allocation/RSS budget | QR-169-13 |
| iDevice disconnect/error/finalization truthfulness | QR-169-15 |

### P2 hardening and release coherence

- Collision, disk-full, permissions, corrupt-defaults, observer/timer/sleep cleanup, screen-permission retry, overlapping selector-refresh lifecycle, Trash/notification privacy, and offline-render no-progress tests.
- Signed-tag, immutable-release, SBOM/attestation, package-lock, branch-drift, endpoint allowlist, appcast/release/Homebrew coherence, asset/resource, and secret scans.
- Run the repository's unsigned universal Release build on every change. Add Debug/Release test jobs for oldest-supported and current macOS, then make Xcode Analyze and strict concurrency non-regressing gates.

## Recommended implementation boundaries

No implementation was performed. The smallest safe implementation plan should preserve these boundaries:

1. **Release lane:** Sparkle update plus production signing/notarization/provenance, independently verifiable from application behavior.
2. **Session lane:** immutable RecordingSession plus serialized lifecycle; this owns cross-record cleanup, callback stop ordering, AppleScript concurrency, countdown cancellation, and iDevice finalization.
3. **Consent lane:** explicit target/audio choices, fail-closed target loss, and the blocklist contract.
4. **Input lane:** QMA schema/parser/export hardening and VideoEditor path containment, ideally inside a sandbox boundary.
5. **Privacy/resource lane:** in-memory preview, capture-session ownership, magnifier bounds, and deterministic cleanup.
6. **Test-infrastructure lane:** add the test target and release artifact gates before claiming any security fix complete.

These should become separate, decision-backed implementation items after the questionnaire is adjudicated. This research item intentionally stops here.
