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

This table is the complete approved signer set. Certificate rotation requires a
tracked decision that adds the incoming common name, Team ID, and fingerprint here,
records the outgoing certificate's overlap and revocation dates, and verifies
notarization continuity before cutover. An artifact signed by an unlisted identity
fails the release gate.

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

The checks above prove structural validity and platform policy, not signer identity.
Verify the leaf certificate for the host, every nested object, and the DMG against the
approved set. The current Sparkle paths are shown explicitly so none are hidden by a
deep check:

```bash
set -euo pipefail

expected_common_name='Developer ID Application: TIMOTHY G HARRIS (F66FM4V88Q)'
expected_team_id='F66FM4V88Q'
expected_sha1='189EC9780DE0A94CF5B24CC5983CAB3FDAE15638'
identity_output='.build/release-identity'
mkdir -p "$identity_output"

verify_signer() {
    signed_path=$1
    certificate_prefix=$2
    signing_details=$(codesign -dvvv "$signed_path" 2>&1)
    grep -Fq "Authority=$expected_common_name" <<<"$signing_details"
    grep -Fq "TeamIdentifier=$expected_team_id" <<<"$signing_details"
    codesign -d --extract-certificates="$identity_output/$certificate_prefix-" "$signed_path"
    actual_sha1=$(openssl x509 -inform DER \
        -in "$identity_output/$certificate_prefix-0" -noout -fingerprint -sha1 \
        | cut -d= -f2 | tr -d ':')
    test "$actual_sha1" = "$expected_sha1"
}

sparkle_root="$artifact_path/Contents/Frameworks/Sparkle.framework/Versions/Current"
verify_signer "$artifact_path" host
verify_signer "$sparkle_root/Autoupdate" autoupdate
verify_signer "$sparkle_root/Updater.app" updater
verify_signer "$sparkle_root/XPCServices/Downloader.xpc" downloader
verify_signer "$sparkle_root/XPCServices/Installer.xpc" installer
verify_signer "$artifact_path/Contents/Frameworks/Sparkle.framework" sparkle
verify_signer "$release_dmg" dmg
```

## Entitlement allowlists

Entitlements are per-object capabilities, not a bundle-wide template. Never copy the
host entitlements onto Sparkle or another nested component. For the current baseline,
the exact approved key/value sets are:

| Signed object | Allowed entitlements |
|---|---|
| Grab Rabbit host | `com.apple.security.device.audio-input = true`; `com.apple.security.device.camera = true` |
| `Autoupdate` | `com.apple.application-identifier = org.sparkle-project.Sparkle.Autoupdate` |
| `Updater.app` | Empty |
| `Downloader.xpc` | Empty |
| `Installer.xpc` | Empty |
| `Sparkle.framework` | Empty |

An empty allowlist means no entitlement keys, whether `codesign` renders an empty
dictionary or no entitlement blob. Any added, removed, or changed value requires a
tracked security review that updates this table before signing. In particular, future
App Sandbox or XPC work must define its minimal per-object changes here rather than
silently broadening the host or helper.

Dump every final object and compare its complete dictionary with the table; release
automation fails on any extra or missing key/value:

```bash
codesign --display --entitlements - "$artifact_path"
codesign --display --entitlements - "$sparkle_root/Autoupdate"
codesign --display --entitlements - "$sparkle_root/Updater.app"
codesign --display --entitlements - "$sparkle_root/XPCServices/Downloader.xpc"
codesign --display --entitlements - "$sparkle_root/XPCServices/Installer.xpc"
codesign --display --entitlements - "$artifact_path/Contents/Frameworks/Sparkle.framework"
```

## Nested Sparkle order

Manual signing proceeds from leaf code outward. Use the same Developer ID identity,
runtime/timestamp policy, and approved entitlements throughout; use `--deep` for
verification, not as a substitute for deliberate signing.

For the current Sparkle 2.9.5 layout, sign all leaf objects first: the standalone
`Autoupdate` executable, `Updater.app`, `Downloader.xpc`, and `Installer.xpc`. Their
order relative to one another is not significant. Then sign `Sparkle.framework`
after every leaf, and sign the Grab Rabbit host application last.

After signing, run the exact signer and entitlement checks above before the
deep/strict check.

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
