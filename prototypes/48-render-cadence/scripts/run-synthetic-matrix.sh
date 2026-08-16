#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 || "$1" != /* ]]; then
    echo "usage: $0 /absolute/path/to/evidence-directory" >&2
    exit 2
fi

output_dir=$1
prototype_root=$(cd "$(dirname "$0")/.." && pwd)
repository_root=$(cd "$prototype_root/../.." && pwd)
branch=$(git -C "$repository_root" branch --show-current)
commit=$(git -C "$repository_root" rev-parse HEAD)

if [[ "$branch" != "prototype/48-render-cadence" ]]; then
    echo "refusing non-prototype branch: $branch" >&2
    exit 3
fi
if [[ -n "$(git -C "$repository_root" status --porcelain)" ]]; then
    echo "commit the prototype checkpoint before generating bound evidence" >&2
    exit 4
fi
if [[ -e "$output_dir" ]]; then
    echo "refusing to overwrite evidence directory: $output_dir" >&2
    exit 5
fi

mkdir -p "$output_dir/runs"
swift build --package-path "$prototype_root" -c release
binary="$prototype_root/.build/release/cadence-probe"

summary="$output_dir/summary.csv"
echo 'candidate,browser_case,canvas,appended_frames,effective_fps,max_output_gap_ms,writer_not_ready_drops,duplicate_camera_frames,duplicate_browser_frames,max_browser_age_ms,p95_camera_latency_ms,max_abs_av_drift_ms,monotonic,pause_resume,disconnect_fail_closed,privacy_sentinel_pixels' >"$summary"

for candidate in screen-driven camera-driven fixed-clock hybrid; do
    for browser_case in static low-change active; do
        for canvas in 16x9 9x16 square; do
            stem="$candidate--$browser_case--$canvas"
            "$binary" "$candidate" "$browser_case" "$canvas" \
                "$output_dir/runs/$stem.metrics.json" \
                "$output_dir/runs/$stem.events.jsonl" >>"$summary"
        done
    done
done

jq -s '{runs: length, failing_runs: map(select(.privacySentinelPixelsInCache != 0)), passed: all(.privacySentinelPixelsInCache == 0)}' \
    "$output_dir"/runs/*.metrics.json >"$output_dir/privacy-probe.json"

manifest_tmp="$output_dir/manifest.tmp.json"
jq -n \
    --arg schema 'grab-rabbit-render-cadence-prototype-v1' \
    --arg branch "$branch" \
    --arg commit "$commit" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg host "$(scutil --get ComputerName)" \
    --arg os "$(sw_vers -productVersion) ($(sw_vers -buildVersion))" \
    --arg hardware "$(system_profiler SPHardwareDataType -json | jq -c '.SPHardwareDataType[0] | {machine_name, machine_model, chip_type, number_processors, physical_memory}')" \
    --arg swift "$(swift --version 2>&1 | head -1)" \
    --arg config 'deterministic synthetic; 30 fps; 12 s; pause [4,5); disconnect 10 s; writer blocks [2.20,2.32),[7.40,7.58); opaque privacy matte' \
    '{schema: $schema, branch: $branch, commit: $commit, generated_at: $generated_at, host: $host, os: $os, hardware: ($hardware | fromjson), toolchain: $swift, config: $config, limitations: ["synthetic timing, not wall-clock runtime", "no playable media", "no physical camera or ScreenCaptureKit/TCC", "resource metrics deferred to Mac Mini runtime"]}' \
    >"$manifest_tmp"

(cd "$output_dir" && find . -type f ! -name 'manifest.tmp.json' ! -name 'manifest.json' ! -name 'SHA256SUMS' -print0 \
    | sort -z | xargs -0 shasum -a 256 >SHA256SUMS)
jq --rawfile hashes "$output_dir/SHA256SUMS" '. + {sha256sums: ($hashes | split("\n") | map(select(length > 0)))}' \
    "$manifest_tmp" >"$output_dir/manifest.json"
rm "$manifest_tmp"

jq -e '.passed == true and .runs == 36 and (.failing_runs | length) == 0' "$output_dir/privacy-probe.json" >/dev/null
echo "evidence=$output_dir"
echo "commit=$commit"
