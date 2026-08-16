#!/bin/bash

set -euo pipefail

if [[ $# -ne 3 || "$1" != /* || "$2" != /* || "$3" != /* ]]; then
    echo "usage: $0 /absolute/live-metrics.json /absolute/powermetrics.txt /absolute/binding.json" >&2
    exit 2
fi

metrics=$1
power=$2
binding=$3
[[ -f "$metrics" ]] || { echo "missing live metrics: $metrics" >&2; exit 3; }
[[ -f "$power" ]] || { echo "missing powermetrics output: $power" >&2; exit 4; }
[[ ! -e "$binding" ]] || { echo "refusing to overwrite: $binding" >&2; exit 5; }
configured=$(jq -r '.powermetricsHookPath // empty' "$metrics")
[[ "$configured" == "$power" ]] || {
    echo "powermetrics path does not match the path recorded before the run" >&2
    exit 6
}

jq -n \
    --arg schema 'grab-rabbit-live-powermetrics-binding-v1' \
    --arg metrics_path "$metrics" \
    --arg metrics_sha256 "$(shasum -a 256 "$metrics" | awk '{print $1}')" \
    --arg powermetrics_path "$power" \
    --arg powermetrics_sha256 "$(shasum -a 256 "$power" | awk '{print $1}')" \
    --arg bound_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema:$schema,metrics_path:$metrics_path,metrics_sha256:$metrics_sha256,powermetrics_path:$powermetrics_path,powermetrics_sha256:$powermetrics_sha256,bound_at:$bound_at}' \
    >"$binding"
echo "binding=$binding"
