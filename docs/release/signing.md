# Grab Rabbit release signing

_Canonical release-identity reference. Last confirmed: 2026-08-14._

This file contains public identity metadata and operational checks only. Signing
credentials and private-key material stay outside the repository.

## Expected identity

| Field | Expected value |
|---|---|
| Certificate common name | `Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)` |
| Team ID | `F66FM4V88Q` |
| SHA-1 fingerprint | `189EC9780DE0A94CF5B24CC5983CAB3FDAE15638` |

These values identify the intended certificate; they do not assert that it is
installed, valid, or available to the current process. Verify availability live:

```bash
security find-identity -v -p codesigning
security find-certificate -a -c 'Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)' -Z
```

The public identity was present and valid when last confirmed. Certificate expiry,
keychain access, and signing authorization are live environment state.

## Identity boundaries

The current source project still requests `Apple Development`, upstream Team ID
`L4T783637F`, and bundle identifier `com.lihaoyun6.QuickRecorder`. The inspected
upstream 1.6.9 artifact was signed as `Apple Development: lihaoyun11@gmail.com`.
Those upstream identities are provenance, not acceptable Grab Rabbit production
identities ([QR-169-02](../research/quickrecorder-1.6.9-security-review.md#qr-169-02--high-the-published-artifact-fails-the-production-distribution-trust-gate)).

The final Grab Rabbit bundle identifier has not been selected. Issue
[#17](https://github.com/timharris707/grab-rabbit/issues/17) is its authority: the
selected identifier must be Grab Rabbit-controlled and must not retain the upstream
identifier. Issue [#18](https://github.com/timharris707/grab-rabbit/issues/18) owns
the shipped identity transition and preference migration.

## Production trust gates

Before any binary distribution, require all gates approved in
[questionnaire Q2](../research/questionnaire-quickrecorder-1.6.9.md#1-distribution-and-release-trust):

- Developer ID Application signing with a trusted timestamp;
- an exact production-entitlement allowlist for the host and every nested code object;
- Apple notarization and a valid stapled ticket;
- Gatekeeper acceptance of the application;
- a signed DMG that passes its own signature and Gatekeeper checks; and
- closure of all five High findings, per
  [Q18](../research/questionnaire-quickrecorder-1.6.9.md#5-catch-all).

Inspect the final artifacts, not only project settings:

```bash
artifact_path='/absolute/path/to/Grab Rabbit.app'
release_dmg='/absolute/path/to/Grab Rabbit.dmg'

codesign -dv --verbose=4 "$artifact_path"
codesign --verify --deep --strict --verbose=2 "$artifact_path"
spctl --assess --type execute --verbose=4 "$artifact_path"
xcrun stapler validate "$artifact_path"
codesign --verify --deep --strict --verbose=2 "$release_dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$release_dmg"
```

## Nested Sparkle order

Manual signing proceeds from leaf code outward. Use the same Developer ID identity,
runtime/timestamp policy, and approved entitlements throughout; use `--deep` for
verification, not as a substitute for deliberate signing.

For the current Sparkle 2.9.5 layout, sign all leaf objects first: the standalone
`Autoupdate` executable, `Updater.app`, `Downloader.xpc`, and `Installer.xpc`. Their
order relative to one another is not significant. Then sign `Sparkle.framework`
after every leaf, and sign the Grab Rabbit host application last.

After signing, enumerate nested code and confirm every authority and Team ID matches
the host before running the deep/strict check.

## TCC and runtime lessons

- `CODE_SIGNING_ALLOWED=NO` produces an unsigned verification build with an incomplete
  linker signature. It is suitable for compile verification, not Screen Recording or
  other TCC smoke tests.
- Static `codesign --verify --deep --strict` is necessary but not sufficient. An
  ad-hoc Hardened Runtime host combined with differently signed Sparkle code passed a
  static check and was rejected by `dyld`; launch and updater-loading smoke tests are
  required.
- TCC grants bind to the signed application identity. The Grab Rabbit bundle/signing
  transition requires visible Screen Recording, Microphone, Camera, Automation, and
  Notification re-consent; authorization cannot be copied from QuickRecorder
  ([issue #18](https://github.com/timharris707/grab-rabbit/issues/18)).
- Run permission smoke tests from a consistently signed artifact at a stable path.
  Sign every nested component with one identity before interpreting a TCC failure
  as an application defect.

The [security review](../research/quickrecorder-1.6.9-security-review.md) remains the
source for baseline artifact findings. This file owns current Grab Rabbit signing
identity and operational signing rules.
