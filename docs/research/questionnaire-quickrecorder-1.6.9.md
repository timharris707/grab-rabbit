# QuickRecorder security-posture decision questionnaire

- Recipient: Tim Harris, repository decider
- Purpose: resolve product and operational facts that source code cannot establish, so security implementation items can be prioritized without inventing policy.

The review of QuickRecorder 1.6.9 found release, updater, capture-consent, parser, and lifecycle risks. The findings stand independently; these answers determine the intended guarantees and the order/shape of remediation. Partial answers and “I don't know” are useful.

## 1. Distribution and release trust

1. Is grab-rabbit intended to redistribute QuickRecorder binaries to end users, or is it an internal/research fork only?

   Answer (2026-08-14; [Q1 correction on issue #6](https://github.com/timharris707/grab-rabbit/issues/6#issuecomment-5299102644)): **YES.** Grab Rabbit is intended to distribute binaries to end users. This supersedes the earlier personal-only answer.

2. If binaries will be distributed, should Developer ID signing, notarization, stapling, Gatekeeper acceptance, and an exact production-entitlement allowlist be non-negotiable release gates?

   Answer (2026-08-14; [final Q2 decision on issue #6](https://github.com/timharris707/grab-rabbit/issues/6#issuecomment-5299100693)): **YES.** Before any binary distribution, Developer ID signing, trusted timestamping, notarization, stapling, Gatekeeper acceptance, signed-DMG verification, and an exact production-entitlement allowlist are mandatory release gates.

3. Who should control the production Sparkle Ed25519 key, and what backup, access, revocation, and rotation policy should implementation assume?

   Answer (2026-08-14; [final Q3 decision on issue #6](https://github.com/timharris707/grab-rabbit/issues/6#issuecomment-5299100693)): Tim is the accountable Sparkle Ed25519 key custodian initially. The key stays separate from GitHub credentials and general build hosts, with least-privilege access, encrypted offline backup, documented rotation, and an emergency revocation/release procedure.

## 2. Capture consent guarantees

4. Must quick screen/window shortcuts always honor the stored system-audio choice, with no fast-start override?

   Answer (2026-08-14; [final Q4 decision on issue #7](https://github.com/timharris707/grab-rabbit/issues/7#issuecomment-5299100953)): **YES.** Every quick screen/window path honors the stored system-audio choice; fast-start never changes media consent. When microphone and system audio are enabled, every start path captures both.

5. Is the app blocklist intended as a hard privacy boundary or only a best-effort start-time convenience filter?

   Answer (2026-08-14; [final Q5 decision on issue #7](https://github.com/timharris707/grab-rabbit/issues/7#issuecomment-5299100953)): The blocklist is strict and fail-closed. Exclusions must update dynamically; capture stops rather than silently including a blocklisted app when the guarantee cannot be maintained.

6. If an explicitly selected display disappears or changes during countdown, must recording fail closed rather than substitute the display under the pointer?

   Answer (2026-08-14; [final Q6 decision on issue #7](https://github.com/timharris707/grab-rabbit/issues/7#issuecomment-5299100953)): **YES.** If an explicitly selected display or window disappears mid-countdown, recording fails closed with a visible error and never substitutes another target.

## 3. Automation trust

7. Who is intended to use the AppleScript commands: only the interactive user, trusted local automation, or any macOS-authorized Apple Events sender?

   Answer (2026-08-14; [final Q7 decision on issue #7](https://github.com/timharris707/grab-rabbit/issues/7#issuecomment-5299100953)): AppleScript is for trusted local automation under the interactive user account only.

8. Should scripting be disabled until explicitly enabled?

   Answer (2026-08-14; [final Q8 decision on issue #7](https://github.com/timharris707/grab-rabbit/issues/7#issuecomment-5299100953)): **YES.** Scripting is disabled until explicitly enabled.

9. Should scripted capture require a visible in-app confirmation?

   Answer (2026-08-14; [final Q9 decision on issue #7](https://github.com/timharris707/grab-rabbit/issues/7#issuecomment-5299100953)): **NO.** No modal confirmation is required for every script command after explicit opt-in.

10. Should scripted capture require a visible countdown before capture begins?

   Answer (2026-08-14; [final Q10 decision on issue #7](https://github.com/timharris707/grab-rabbit/issues/7#issuecomment-5299100953)): **YES.** Every scripted capture has a visible countdown and a persistent active-recording indicator.

## 4. Containment and supported files

11. Is App Sandbox a desired requirement?

   Answer (2026-08-14; [final Q11 decision on issue #8](https://github.com/timharris707/grab-rabbit/issues/8#issuecomment-5299101181)): **YES.** App Sandbox is desired and required when feasible.

12. If full sandboxing conflicts with capture behavior, may untrusted QMA/media parsing move into a narrowly sandboxed XPC service?

   Answer (2026-08-14; [final Q12 decision on issue #8](https://github.com/timharris707/grab-rabbit/issues/8#issuecomment-5299101181)): **YES.** If whole-app sandboxing is infeasible, untrusted QMA/media parsing and conversion must move into a narrowly sandboxed XPC service; the host remains least-privileged.

13. What maximum QMA duration should be supported?

   Answer (2026-08-14; [final Q13 decision on issue #8](https://github.com/timharris707/grab-rabbit/issues/8#issuecomment-5299101181)): The maximum supported QMA duration is 24 hours.

14. What maximum QMA file or package size should be supported?

   Answer (2026-08-14; [final Q14 decision on issue #8](https://github.com/timharris707/grab-rabbit/issues/8#issuecomment-5299101181)): The maximum supported QMA package size is 64 GiB.

15. Must QMA open/export work on shared destinations?

   Answer (2026-08-14; [final Q15 decision on issue #8](https://github.com/timharris707/grab-rabbit/issues/8#issuecomment-5299101181)): **YES, with containment.** Shared destinations are supported only through validated copy-in to private local staging.

16. Must QMA open/export work on network destinations?

   Answer (2026-08-14; [final Q16 decision on issue #8](https://github.com/timharris707/grab-rabbit/issues/8#issuecomment-5299101181)): **YES, with containment.** Network destinations are supported only through validated copy-in to private local staging; mutable remote content is never parsed in place.

17. Must QMA open/export work on removable destinations?

   Answer (2026-08-14; [final Q17 decision on issue #8](https://github.com/timharris707/grab-rabbit/issues/8#issuecomment-5299101181)): **YES, with containment.** Removable destinations use the same validated copy-in to private local staging rule.

## 5. Catch-all

18. Is there anything we did not ask about the intended security, privacy, release, or automation posture that should shape implementation?

   Answer (2026-08-14; [final Q18 decision on issue #8](https://github.com/timharris707/grab-rabbit/issues/8#issuecomment-5299101181)): No telemetry by default. Do not distribute a release until all five High findings are closed and the production artifact gates pass.
