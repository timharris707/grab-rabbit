# QuickRecorder security-posture decision questionnaire

- Recipient: Tim Harris, repository decider
- Purpose: resolve product and operational facts that source code cannot establish, so security implementation items can be prioritized without inventing policy.

The review of QuickRecorder 1.6.9 found release, updater, capture-consent, parser, and lifecycle risks. The findings stand independently; these answers determine the intended guarantees and the order/shape of remediation. Partial answers and “I don't know” are useful.

## 1. Distribution and release trust

1. Is grab-rabbit intended to redistribute QuickRecorder binaries to end users, or is it an internal/research fork only?

   Answer:

2. If binaries will be distributed, should Developer ID signing, notarization, stapling, Gatekeeper acceptance, and an exact production-entitlement allowlist be non-negotiable release gates?

   Answer:

3. Who should control the production Sparkle Ed25519 key, and what backup, access, revocation, and rotation policy should implementation assume?

   Answer:

## 2. Capture consent guarantees

4. Must quick screen/window shortcuts always honor the stored system-audio choice, with no fast-start override?

   Answer:

5. Is the app blocklist intended as a hard privacy boundary or only a best-effort start-time convenience filter?

   Answer:

6. If an explicitly selected display disappears or changes during countdown, must recording fail closed rather than substitute the display under the pointer?

   Answer:

## 3. Automation trust

7. Who is intended to use the AppleScript commands: only the interactive user, trusted local automation, or any macOS-authorized Apple Events sender?

   Answer:

8. Should scripting be disabled until explicitly enabled?

   Answer:

9. Should scripted capture require a visible in-app confirmation?

   Answer:

10. Should scripted capture require a visible countdown before capture begins?

   Answer:

## 4. Containment and supported files

11. Is App Sandbox a desired requirement?

   Answer:

12. If full sandboxing conflicts with capture behavior, may untrusted QMA/media parsing move into a narrowly sandboxed XPC service?

   Answer:

13. What maximum QMA duration should be supported?

   Answer:

14. What maximum QMA file or package size should be supported?

   Answer:

15. Must QMA open/export work on shared destinations?

   Answer:

16. Must QMA open/export work on network destinations?

   Answer:

17. Must QMA open/export work on removable destinations?

   Answer:

## 5. Catch-all

18. Is there anything we did not ask about the intended security, privacy, release, or automation posture that should shape implementation?

   Answer:
