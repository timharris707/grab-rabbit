# Grab Rabbit project baseline

_Read this first for every repository task. Last confirmed: 2026-08-14._

## Product and baseline

Grab Rabbit is Tim Harris's macOS screen-recorder fork of QuickRecorder. It records
screens, windows, applications, and mobile devices with microphone and system audio.
The intended destination is an end-user binary distribution, subject to the approved
security and release gates ([decision Q1](../research/questionnaire-quickrecorder-1.6.9.md#1-distribution-and-release-trust)).

The audited upstream baseline is the lightweight tag
[QuickRecorder 1.6.9 at `0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e`](https://github.com/lihaoyun6/QuickRecorder/tree/0ed9b2bddd1c8a9d55bad22784d7cd976a96de2e).
The [security review](../research/quickrecorder-1.6.9-security-review.md#baseline-and-scope)
is the canonical evidence for that pin and its risks. Grab Rabbit changes are commits
on top of that baseline; do not reinterpret or move the pin.

## Primary acceptance scenario

The daily-use gate is repeated window-level Zoom-call capture:

- true source-window dimensions through window-level ScreenCaptureKit capture, with
  no desktop pixels;
- microphone plus remote/application audio in one standard `.mp4` or `.mov` by
  default, with the existing separate-track option preserved;
- H.264 or HEVC output with fast-start metadata that `ffmpeg` can read; and
- multiple back-to-back clips without one recording overwriting or deleting another.

A lost live-call recording is unrecoverable and blocks daily use. This baseline owns
the acceptance scenario; tracker items own its implementation and regression tests.

## Durable recording workflow decisions

- Rounded window exteriors are transparent. An opaque compatibility path uses a
  deterministic non-desktop matte; it never substitutes desktop pixels.
- Audio and video remain real-time and synchronized.
- A successful Stop opens Grab Rabbit's own native review/player.
  TapRecord is a workflow benchmark only, never a branding or layout source.
- The exact first-run output default is `~/Movies/GrabRabbit`. The user can select a
  different destination; creation or access failure stays visible instead of silently
  falling back elsewhere.

## Product identity status

The full Grab Rabbit rebrand is approved, but application rebrand work had not begun
when this baseline was last confirmed. The current project, product, and bundle
identifier still use QuickRecorder and `com.lihaoyun6.QuickRecorder`. The ordered
identity sources are the [rebrand decision](https://github.com/timharris707/grab-rabbit/issues/15#issuecomment-5299286699)
and issues [#17](https://github.com/timharris707/grab-rabbit/issues/17),
[#18](https://github.com/timharris707/grab-rabbit/issues/18),
[#19](https://github.com/timharris707/grab-rabbit/issues/19), and
[#20](https://github.com/timharris707/grab-rabbit/issues/20). Treat their live state
as authoritative; this paragraph records status, not permission to skip a gate.

## Durable decisions and priority rules

- Tim Harris is the decider; `docs/agents/team-workflow.md` owns that binding.
- The [security review](../research/quickrecorder-1.6.9-security-review.md) owns findings
  and safeguards. The [decision questionnaire](../research/questionnaire-quickrecorder-1.6.9.md)
  owns Tim's final security, privacy, automation, containment, and distribution policy.
- Protect the primary acceptance scenario first. Recording loss, capture of an
  unchosen target or media source, and a false success result are release-blocking.
- Within that gate, retire output loss first, audio-consent divergence second, and
  missing-target substitution third. Live dependency edges own the current status.
- No binary distribution occurs until all five High findings are closed and the
  production artifact gates pass, as decided in
  [Q18](../research/questionnaire-quickrecorder-1.6.9.md#5-catch-all).
- Work stays within its accepted issue. New scope becomes a separate tracked item;
  live dependency edges and claims decide order.

## Source ownership

| Source | Sole responsibility |
|---|---|
| This baseline | Durable product purpose, origin, acceptance scenario, and identity status |
| [`docs/release/signing.md`](../release/signing.md) | Release identity, signing, notarization, and TCC/runtime signing lessons |
| [`docs/agents/team-workflow.md`](team-workflow.md) | Tracker, frontier, claim, verification, review, and merge bindings |
| `.claude/handoff.md` | Hot pointer: transient active state, current-session results, exact next action, and expensive session-specific gotchas; durable facts remain pointers to tracked sources |

Do not copy transient issue or pull-request lists into tracked memory. To find the
next work, run the live frontier query in
[`docs/agents/team-workflow.md`](team-workflow.md#tracker-binding), then inspect issue
comments for `Lane-start` markers, dependency state, and open pull requests.

## License and attribution

The repository's [GNU AGPLv3 license](../../LICENSE) and required upstream copyright,
license, changelog provenance, and attribution are authoritative. Rebranding must
preserve them; product-facing identity changes do not erase upstream authorship.
