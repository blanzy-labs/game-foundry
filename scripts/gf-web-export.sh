#!/usr/bin/env bash
set -u -o pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/scripts/lib/gf-web-common.sh"
tool="$repo_root/scripts/lib/gf-web.py"
verify="$repo_root/scripts/gf-web-verify.sh"
preset='Game Foundry Web'
fixture_id='web-export-fixture'
artifact_dir=''
timeout_seconds=${GF_WEB_EXPORT_TIMEOUT_SECONDS:-180}

while (($#)); do
  case "$1" in
    --preset) (($# >= 2)) || { printf '%s\n' '--preset requires a value' >&2; exit 2; }; preset=$2; shift 2 ;;
    --fixture-id) (($# >= 2)) || { printf '%s\n' '--fixture-id requires a value' >&2; exit 2; }; fixture_id=$2; shift 2 ;;
    --artifact-dir) (($# >= 2)) || { printf '%s\n' '--artifact-dir requires a value' >&2; exit 2; }; artifact_dir=$2; shift 2 ;;
    --) shift; break ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) break ;;
  esac
done
(($# == 2)) || { printf 'usage: %s [--preset NAME] [--fixture-id ID] [--artifact-dir DIR] PROJECT OUTPUT_DIR\n' "$0" >&2; exit 2; }
[[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] || { printf 'GF_WEB_EXPORT_TIMEOUT_SECONDS must be positive\n' >&2; exit 2; }

project=$(realpath "$1" 2>/dev/null) || { printf 'project path does not exist\n' >&2; exit 2; }
output=$(realpath -m "$2")
artifact_dir=${artifact_dir:-$(dirname "$output")}
artifact_dir=$(realpath -m "$artifact_dir")
manifest="$artifact_dir/web-release.json"
result_file="$artifact_dir/export-result.json"
mkdir -p "$artifact_dir/logs"

fail() {
  local reason=$1 code=${2:-1}
  jq -n --arg status fail --arg reason "$reason" --arg project "$project" --arg output "$output" \
    --arg manifest "$manifest" '{status:$status,reason:$reason,project:$project,output_directory:$output,manifest:$manifest,browser_runtime_acceptance:"not_tested"}' >"$result_file"
  printf 'GF WEB EXPORT FAIL: %s\nEVIDENCE: %s\n' "$reason" "$artifact_dir" >&2
  exit "$code"
}

[[ -f $project/project.godot ]] || fail 'project.godot is missing'
[[ $output != "$project" && $output != "$project/"* ]] || fail 'output directory must be outside the source project'
if [[ -e $output ]]; then
  [[ -d $output && ! -L $output ]] || fail 'output path is not a safe directory'
  [[ -z $(find "$output" -mindepth 1 -print -quit) ]] || fail 'output directory must be empty'
else
  mkdir -p "$output" || fail 'could not create output directory'
fi

"$tool" validate-project "$project" --preset "$preset" >"$artifact_dir/project-validation.json"
validation_code=$?
[[ $validation_code -eq 0 ]] || fail 'Web target project validation failed'

godot_bin=$(gf_web_godot_bin)
godot_version=$(gf_web_godot_version) || fail 'Godot executable is unavailable'
[[ $godot_version == 4.* && $godot_version != *mono* ]] || fail 'Godot 4.x Standard is required'
templates_dir=$(gf_web_templates_dir "$godot_version")
gf_web_templates_ready "$templates_dir" || fail "single-threaded Web export template is missing from $templates_dir"

"$tool" fingerprint "$project" >"$artifact_dir/source-before.json" || fail 'source fingerprint failed before export'
source_before=$(jq -r .source_fingerprint "$artifact_dir/source-before.json")
source_commit=$(git -C "$project" rev-parse HEAD 2>/dev/null || true)
command=("$godot_bin" --headless --path "$project" --export-release "$preset" "$output/index.html")
printf '%q ' "${command[@]}" >"$artifact_dir/logs/command.txt"; printf '\n' >>"$artifact_dir/logs/command.txt"
printf '%s\n' "$godot_version" >"$artifact_dir/logs/godot-version.txt"
printf '%s\n' "$templates_dir/web_nothreads_release.zip" >"$artifact_dir/logs/template.txt"
start_ns=$(date +%s%N)
timeout "$timeout_seconds" "${command[@]}" >"$artifact_dir/logs/stdout.log" 2>"$artifact_dir/logs/stderr.log"
export_code=$?
end_ns=$(date +%s%N)
duration=$(gf_web_elapsed_seconds "$start_ns" "$end_ns")
printf '%s\n' "$export_code" >"$artifact_dir/logs/exit-code.txt"

if [[ ${GF_GF_WEB001_ENABLE_TEST_HOOKS:-0} == 1 && ${GF_GF_WEB001_SOURCE_MUTATION:-0} == 1 ]]; then
  printf 'CONTROLLED_GF_WEB_001_SOURCE_MUTATION\n' >"$project/gf-web-unauthorized-mutation.txt"
fi

"$tool" fingerprint "$project" >"$artifact_dir/source-after.json" || fail 'source fingerprint failed after export'
source_after=$(jq -r .source_fingerprint "$artifact_dir/source-after.json")
jq -n --arg godot_version "$godot_version" --arg templates_dir "$templates_dir" --arg preset "$preset" \
  --argjson exit_code "$export_code" --argjson duration_seconds "$duration" --arg source_before "$source_before" --arg source_after "$source_after" \
  '{godot_version:$godot_version,templates_dir:$templates_dir,preset:$preset,threaded:false,template:"web_nothreads_release.zip",exit_code:$exit_code,duration_seconds:$duration_seconds,source_before:$source_before,source_after:$source_after,source_unchanged:($source_before==$source_after)}' \
  >"$artifact_dir/export-metadata.json"
[[ $export_code -eq 0 ]] || fail "Godot Web export exited $export_code"
[[ $source_before == "$source_after" ]] || fail 'Web export caused an unexpected source mutation'

"$tool" create-manifest "$manifest" "$output" --fixture-id "$fixture_id" --godot-version "$godot_version" \
  --source-fingerprint "$source_before" --source-commit "$source_commit" --preset "$preset" >"$artifact_dir/manifest-generation.json" || fail 'manifest generation failed'
"$verify" "$manifest" "$output" >"$artifact_dir/verification.json"
verify_code=$?
[[ $verify_code -eq 0 ]] || fail 'bundle verification failed'

jq -n --arg status pass --arg project "$project" --arg output "$output" --arg manifest "$manifest" --arg preset "$preset" \
  --arg godot_version "$godot_version" --argjson duration_seconds "$duration" --arg source_fingerprint "$source_before" \
  --slurpfile verification "$artifact_dir/verification.json" \
  '{status:$status,target:"web",project:$project,output_directory:$output,manifest:$manifest,preset:$preset,godot_version:$godot_version,renderer:"gl_compatibility",threaded:false,duration_seconds:$duration_seconds,exit_code:0,source_fingerprint:$source_fingerprint,source_unchanged:true,verification:$verification[0],browser_runtime_acceptance:"not_tested"}' >"$result_file"
cat "$result_file"
