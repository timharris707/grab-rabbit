#!/bin/bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 /absolute/path/to/experiment.json /absolute/path/to/output-directory" >&2
    exit 2
fi

manifest=$1
output_dir=$2
prototype_root=$(cd "$(dirname "$0")/.." && pwd)
repository_root=$(cd "$prototype_root/../.." && pwd)
power_pid=''

mkdir -p "$output_dir"

stop_powermetrics() {
    if [[ -n "$power_pid" ]] && kill -0 "$power_pid" 2>/dev/null; then
        sudo -n kill -INT "$power_pid" 2>/dev/null || true
        wait "$power_pid" 2>/dev/null || true
    fi
}
trap stop_powermetrics EXIT INT TERM

echo "macOS requires an administrator password once to measure CPU/GPU/ANE pressure."
sudo -v

export GRAB_RABBIT_PROTOTYPE_BRANCH
export GRAB_RABBIT_PROTOTYPE_COMMIT
GRAB_RABBIT_PROTOTYPE_BRANCH=$(git -C "$repository_root" branch --show-current)
GRAB_RABBIT_PROTOTYPE_COMMIT=$(git -C "$repository_root" rev-parse HEAD)

sudo powermetrics \
    --sample-rate 500 \
    --sample-count -1 \
    --samplers tasks,cpu_power,gpu_power,ane_power,thermal \
    --show-process-energy \
    --show-process-gpu \
    --show-usage-summary \
    >"$output_dir/powermetrics.txt" 2>&1 &
power_pid=$!

swift run --package-path "$prototype_root" -c release foreground-probe \
    process --manifest "$manifest" --output "$output_dir"

stop_powermetrics
power_pid=''
/usr/bin/shasum -a 256 "$output_dir/powermetrics.txt" >"$output_dir/powermetrics.sha256"
