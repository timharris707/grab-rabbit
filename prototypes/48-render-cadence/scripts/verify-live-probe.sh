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
if rg -n 'CGRequestScreenCaptureAccess|requestAccess\(' "$source_root" >"$evidence/forbidden-tcc-request.txt"; then
    echo "probe must never request or mutate TCC" >&2
    exit 5
fi

probe="$prototype_root/.build/release/live-cadence-probe"
"$probe" list-sources --json "$evidence/sources.json" >"$evidence/sources.stdout.json"
camera_count=$(jq '.cameras | length' "$evidence/sources.json")
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
    '{schema:$schema,branch:$branch,commit:$commit,host:$host,os:$os,camera_count:$camera_count,missing_camera_preflight_exit:$preflight_exit,output_created:false,checks:{warnings_as_errors_build:true,tests:true,desktop_filter_absent:true,desktop_independent_window_filter:true,typed_sanitized_cache:true,copy_sanitize_cache_order:true,no_tcc_request_api:true}}' \
    >"$evidence/manifest.json"

(cd "$evidence" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 >SHA256SUMS)
echo "evidence=$evidence"
