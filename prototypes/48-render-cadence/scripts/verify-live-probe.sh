#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 || "$1" != /* ]]; then
    echo "usage: $0 /absolute/path/to/evidence-directory" >&2
    exit 2
fi

evidence=$1
prototype_root=$(cd "$(dirname "$0")/.." && pwd)
repository_root=$(cd "$prototype_root/../.." && pwd)
[[ ! -e "$evidence" ]] || { echo "refusing to overwrite: $evidence" >&2; exit 3; }
mkdir -p "$evidence"

swift build --package-path "$prototype_root" -c release -Xswiftc -warnings-as-errors \
    >"$evidence/build.log" 2>&1
swift test --package-path "$prototype_root" -c release -Xswiftc -warnings-as-errors \
    >"$evidence/tests.log" 2>&1

source_root="$prototype_root/Sources/LiveCadenceProbe"
main_source="$source_root/LiveCadenceProbeMain.swift"
models_source="$source_root/LiveModels.swift"
rg -n 'SCContentFilter\(desktopIndependentWindow:' "$source_root/LiveSources.swift" \
    >"$evidence/window-filter-proof.txt"
if rg -n 'SCContentFilter\([^\n]*display:|SCContentFilter\([^\n]*excludingWindows:' "$source_root" \
    >"$evidence/forbidden-display-filter.txt"; then
    echo "display capture fallback found" >&2
    exit 4
fi
rg -n 'func storeWindow\(_ frame: SanitizedWindowFrame\)' "$source_root/WindowPrivacy.swift" \
    >"$evidence/typed-cache-proof.txt"
rg -n 'let copiedBuffer = try copier.copy\(rawBuffer\)|WindowCapturePrivacy.sanitize\(copiedBuffer\)|storeWindow\(frame\)' \
    "$source_root" >"$evidence/privacy-order-proof.txt"
request_pattern='CGRequestScreenCaptureAccess|AVCaptureDevice\.requestAccess'
request_locations=$(rg -n "$request_pattern" "$source_root" || true)
request_count=$(printf '%s\n' "$request_locations" | sed '/^$/d' | wc -l | tr -d ' ')
authorize_start=$(rg -n 'private static func authorize' "$main_source" | cut -d: -f1 || true)
record_start=$(rg -n 'private static func record' "$main_source" | cut -d: -f1 || true)
authorize_guard=$(awk -v start="$authorize_start" -v end="$record_start" \
    'NR >= start && NR < end && /guard signing\.approvedDeveloperIDPresent/ { print NR; exit }' "$main_source")
first_request=$(rg -n "$request_pattern" "$main_source" | head -1 | cut -d: -f1 || true)
if [[ "$request_count" -ne 3 \
    || ! "$authorize_start" =~ ^[0-9]+$ \
    || ! "$record_start" =~ ^[0-9]+$ \
    || ! "$first_request" =~ ^[0-9]+$ \
    || -z "$authorize_guard" \
    || "$authorize_guard" -ge "$first_request" ]]; then
    echo "TCC requests are not exactly scoped behind the approved-signer guard" >&2
    exit 5
fi
while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" -gt "$authorize_start" && "$line" -lt "$record_start" ]] || {
        echo "TCC request API escaped the explicit authorize command" >&2
        exit 5
    }
done < <(rg -n "$request_pattern" "$main_source" | cut -d: -f1)
{
    printf 'authorize_start=%s\napproved_signer_guard=%s\nrecord_start=%s\n' \
        "$authorize_start" "$authorize_guard" "$record_start"
    printf '%s\n' "$request_locations"
} >"$evidence/tcc-authorize-scope-proof.txt"
{
    rg -n 'let approvedFingerprint = "189EC9780DE0A94CF5B24CC5983CAB3FDAE15638"' "$models_source"
    rg -n 'approvedDeveloperIDPresent: teamIdentifier == "F66FM4V88Q" && fingerprints\.contains\(approvedFingerprint\)' \
        "$models_source"
} >"$evidence/approved-runtime-signer-proof.txt"

if rg -n 'detail:.*(uniqueID|cameraID|windowID)|selectedCamera: StableCameraSource|selectedWindow: CapturableWindowSource' \
    "$source_root" >"$evidence/forbidden-identifier-evidence.txt"; then
    echo "exact camera/window identifier can escape into live evidence" >&2
    exit 6
fi
rg -n 'exactUniqueIDMatchedInProcess|exactWindowIDMatchedInProcess|detail: "exact-selected-device"' \
    "$source_root" >"$evidence/identifier-redaction-proof.txt"

probe="$prototype_root/.build/release/live-cadence-probe"
source_inventory=$("$probe" list-sources --skip-window-query)
camera_count=$(jq '.cameras | length' <<<"$source_inventory")
jq '{generatedAt, cameraCount: (.cameras | length), authorization, signing, windowQuery}' \
    <<<"$source_inventory" >"$evidence/source-summary.json"
unset source_inventory
missing_output="$evidence/must-not-exist.mov"
set +e
"$probe" preflight \
    --camera-id '__grab_rabbit_missing_camera__' \
    --output "$missing_output" \
    --json "$evidence/missing-camera.json" \
    >"$evidence/preflight.stdout" 2>"$evidence/preflight.stderr"
preflight_code=$?
set -e
if [[ "$camera_count" -eq 0 ]]; then expected_code=20; else expected_code=21; fi
[[ "$preflight_code" -eq "$expected_code" ]]
[[ ! -e "$missing_output" ]]
jq -e --argjson code "$expected_code" \
    '.exitCode == $code and .outputCreated == false' "$evidence/missing-camera.json" >/dev/null

jq -n \
    --arg schema 'grab-rabbit-live-probe-verification-v1' \
    --arg branch "$(git -C "$repository_root" branch --show-current)" \
    --arg commit "$(git -C "$repository_root" rev-parse HEAD)" \
    --arg host "$(scutil --get ComputerName)" \
    --arg os "$(sw_vers -productVersion) ($(sw_vers -buildVersion))" \
    --argjson camera_count "$camera_count" \
    --argjson preflight_exit "$preflight_code" \
    '{schema:$schema,branch:$branch,commit:$commit,host:$host,os:$os,camera_count:$camera_count,missing_camera_preflight_exit:$preflight_exit,output_created:false,exact_source_ids_persisted:false,checks:{warnings_as_errors_build:true,tests:true,desktop_filter_absent:true,desktop_independent_window_filter:true,typed_sanitized_cache:true,copy_sanitize_cache_order:true,tcc_requests_scoped_behind_approved_signer:true,live_evidence_identifiers_redacted:true}}' \
    >"$evidence/manifest.json"

(cd "$evidence" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 >SHA256SUMS)
echo "evidence=$evidence"
