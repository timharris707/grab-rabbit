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
if ! command -v ffprobe >/dev/null; then
    echo "ffprobe is required for playable-output verification" >&2
    exit 6
fi

mkdir -p "$output_dir/runs"
swift build --package-path "$prototype_root" -c release
binary="$prototype_root/.build/release/cadence-probe"
process_ledger="$output_dir/processes.tsv"
echo -e 'pid\tcommand\tstarted_utc\tstopped_utc\texit_code' >"$process_ledger"

run_case() {
    candidate=$1
    browser_case=$2
    canvas=$3
    composition=$4
    stem="$candidate--$browser_case--$canvas--$composition"
    metrics="$output_dir/runs/$stem.logic.json"
    events="$output_dir/runs/$stem.events.jsonl"
    movie="$output_dir/runs/$stem.mov"
    native="$output_dir/runs/$stem.native.json"
    probe="$output_dir/runs/$stem.ffprobe.json"

    "$binary" "$candidate" "$browser_case" "$canvas" "$metrics" "$events"
    started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    "$binary" render "$candidate" "$browser_case" "$canvas" "$composition" "$movie" "$native" &
    probe_pid=$!
    set +e
    wait "$probe_pid"
    code=$?
    set -e
    stopped=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo -e "$probe_pid\tcadence-probe render $stem\t$started\t$stopped\t$code" >>"$process_ledger"
    if [[ $code -ne 0 ]]; then return "$code"; fi
    ffprobe -v error \
        -show_entries format=duration,size:stream=index,codec_name,codec_type,width,height,avg_frame_rate,duration,start_time \
        -of json "$movie" >"$probe"
}

for candidate in screen-driven camera-driven fixed-clock hybrid; do
    run_case "$candidate" static 16x9 camera-browser
    run_case "$candidate" low-change 9x16 camera-browser
    run_case "$candidate" active square camera-browser
done
for canvas in 16x9 9x16 square; do
    run_case fixed-clock active "$canvas" camera-only
done

jq -s '{runs: length, passed: all(.privacySentinelPixelsInRenderedOutput == 0 and .privacySentinelPixelsBeforeCache == 0 and .appendFailures == 0), failures: map(select(.privacySentinelPixelsInRenderedOutput != 0 or .privacySentinelPixelsBeforeCache != 0 or .appendFailures != 0))}' \
    "$output_dir"/runs/*.native.json >"$output_dir/privacy-probe.json"

jq -s '[.[] | {candidate, browserCase, canvas, composition, encodedVideoFrames, writerReadinessWaits, appendFailures, wallSeconds, userCPUSeconds, systemCPUSeconds, maximumResidentBytes, thermalStateBefore, thermalStateAfter, outputDurationSeconds}]' \
    "$output_dir"/runs/*.native.json >"$output_dir/native-summary.json"

jq -s '[.[] | {candidate, browserCase, canvas, appendedFrames, effectiveFPS, maxOutputGapMilliseconds, droppedWriterNotReady, duplicateCameraFrames, duplicateBrowserFrames, maxBrowserAgeMilliseconds, p95CameraLatencyMilliseconds, maxAbsoluteAVDriftMilliseconds, monotonicTimestamps, pauseResumeContinuous, disconnectedFailClosed, privacySentinelPixelsInCache}]' \
    "$output_dir"/runs/*.logic.json >"$output_dir/logic-summary.json"

manifest_tmp="$output_dir/manifest.tmp.json"
jq -n \
    --arg schema 'grab-rabbit-render-cadence-native-prototype-v1' \
    --arg branch "$branch" \
    --arg commit "$commit" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg host "$(scutil --get ComputerName)" \
    --arg os "$(sw_vers -productVersion) ($(sw_vers -buildVersion))" \
    --arg hardware "$(system_profiler SPHardwareDataType -json | jq -c '.SPHardwareDataType[0] | {machine_name, machine_model, chip_type, number_processors, physical_memory}')" \
    --arg swift "$(swift --version 2>&1 | head -1)" \
    --arg ffmpeg "$(ffprobe -version | head -1)" \
    --arg config 'H.264/AAC MOV; 30 fps candidate schedule; 12 s source timeline; pause [4,5) removed from output PTS; fail closed at injected camera disconnect 10 s; writer blocks [2.20,2.32),[7.40,7.58); typed copy/sanitize/cache boundary; synthetic camera/browser/audio' \
    '{schema: $schema, branch: $branch, commit: $commit, generated_at: $generated_at, host: $host, os: $os, hardware: ($hardware | fromjson), toolchain: {swift: $swift, ffprobe: $ffmpeg}, config: $config, coverage: {camera_browser_runs: 12, camera_only_runs: 3, shapes: ["1920x1080", "1080x1920", "1080x1080"], source_cases: ["static", "low-change", "active"]}, limitations: ["synthetic camera/browser/audio, not ScreenCaptureKit or physical AVCaptureDevice", "CPU time/RSS/thermal measured in process; GPU and ANE pressure require interactive sudo powermetrics", "offline asset-writer throughput, not wall-clock capture callback jitter", "injected writer-unready windows are deterministic; actual adaptor readiness waits are separately counted"]}' \
    >"$manifest_tmp"

find "$output_dir" -type f ! -name 'manifest.tmp.json' ! -name 'manifest.json' ! -name 'SHA256SUMS' -print0 \
    | sort -z | xargs -0 shasum -a 256 >"$output_dir/SHA256SUMS"
jq --rawfile hashes "$output_dir/SHA256SUMS" '. + {sha256sums: ($hashes | split("\n") | map(select(length > 0)))}' \
    "$manifest_tmp" >"$output_dir/manifest.json"
rm "$manifest_tmp"

jq -e '.passed == true and .runs == 15 and (.failures | length) == 0' "$output_dir/privacy-probe.json" >/dev/null
if [[ $(awk 'NR > 1 && $5 != 0 {bad++} END {print bad+0}' "$process_ledger") -ne 0 ]]; then
    echo "a prototype-owned process failed" >&2
    exit 7
fi
echo "evidence=$output_dir"
echo "commit=$commit"
