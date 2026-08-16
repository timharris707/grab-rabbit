#!/usr/bin/env bash
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly plan_file="$script_dir/stage1-plan.json"
readonly destination="${1:-}"

if [[ -z "$destination" ]]; then
    printf 'usage: %s EMPTY_DESTINATION\n' "$0" >&2
    exit 64
fi
if [[ -e "$destination" ]] && [[ -n "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    printf 'refusing non-empty destination: %s\n' "$destination" >&2
    exit 73
fi
command -v jq >/dev/null || { printf '%s\n' 'jq is required' >&2; exit 69; }

[[ "$(jq -r '.status' "$plan_file")" == "NOT_AUTHORIZED_ZERO_CALL_PREPARATION_ONLY" ]]
[[ "$(jq -r '.totals.image_calls' "$plan_file")" == "8" ]]
[[ "$(jq -r '.totals.image_output_subtotal_usd_before_text' "$plan_file")" == "0.38772" ]]
[[ "$(jq -r '.controls.automatic_retries' "$plan_file")" == "0" ]]
[[ "$(jq -r '.output.width, .output.height' "$plan_file" | paste -sd x -)" == "1376x768" ]]

mkdir -p "$destination/cells"
cp "$plan_file" "$destination/stage1-plan.json"
cp "$script_dir/comparison-rubric.json" "$destination/comparison-rubric.json"
cp "$script_dir/local-adaptation-scenarios.json" "$destination/local-adaptation-scenarios.json"

jq -r '.models[] | [.provider, .route, .model] | @tsv' "$plan_file" |
while IFS=$'\t' read -r provider route model; do
    model_slug="$(printf '%s' "$model" | tr -cs '[:alnum:].-' '-')"
    jq -r '.scenes[] | [.id, .text] | @tsv' "$plan_file" |
    while IFS=$'\t' read -r scene_id scene_text; do
        jq -r '.lighting_profiles[] | [.id, .text] | @tsv' "$plan_file" |
        while IFS=$'\t' read -r light_id light_text; do
            cell_id="${model_slug}_${scene_id}_${light_id}"
            cell_dir="$destination/cells/$cell_id"
            mkdir "$cell_dir"
            prompt="$(jq -r --arg scene "$scene_text" --arg light "$light_text" '.prompt_template | gsub("\\{\\{scene\\}\\}"; $scene) | gsub("\\{\\{lighting\\}\\}"; $light)' "$plan_file")"
            printf '%s\n' "$prompt" > "$cell_dir/prompt.txt"
            jq -n \
                --arg cell_id "$cell_id" --arg provider "$provider" --arg route "$route" \
                --arg model "$model" --arg prompt_sha256 "$(shasum -a 256 "$cell_dir/prompt.txt" | awk '{print $1}')" \
                '{schema_version:1,status:"NOT_RUN",cell_id:$cell_id,provider:$provider,route:$route,model:$model,request:{width:1376,height:768,quality:"medium-equivalent",output_count:1,automatic_retries:0,prompt_sha256:$prompt_sha256},evidence:{account_retention_setting:null,processing_region:null,started_at:null,wall_time_ms:null,request_id:null,result:null,safety_or_failure:null,actual_width:null,actual_height:null,output_file:null,output_sha256:null,text_input_tokens:null,image_output_tokens:null,billed_cost_usd:null}}' \
                > "$cell_dir/evidence.json"
        done
    done
done

cell_count="$(find "$destination/cells" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[[ "$cell_count" == "8" ]]
if find "$destination" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) -print -quit | grep -q .; then
    printf '%s\n' 'unexpected image output' >&2
    exit 70
fi

jq -n --argjson cells "$cell_count" '{status:"PREPARED_ZERO_CALL",cells:$cells,provider_calls:0,still_uploads:0,model_downloads:0,authorized_stage1_calls:0,later_stage1_call_ceiling:8,later_image_output_subtotal_usd_before_text:"0.38772"}' > "$destination/preparation-summary.json"
printf 'prepared %s zero-call cells at %s\n' "$cell_count" "$destination"
