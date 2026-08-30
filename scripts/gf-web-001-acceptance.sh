#!/usr/bin/env bash
set -u -o pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exporter="$repo_root/scripts/gf-web-export.sh"
verifier="$repo_root/scripts/gf-web-verify.sh"
tool="$repo_root/scripts/lib/gf-web.py"
fixture="$repo_root/fixtures/web-export-project"
iterations=1
artifact_root=${GF_WEB001_ARTIFACT_ROOT:-$repo_root/artifacts/gf-web-001/gf-web-001-acceptance-$(date -u +%Y%m%dT%H%M%SZ)-$$}

while (($#)); do
  case "$1" in
    --iterations) (($# >= 2)) || { printf '%s\n' '--iterations requires a value' >&2; exit 2; }; iterations=$2; shift 2 ;;
    --artifact-root) (($# >= 2)) || { printf '%s\n' '--artifact-root requires a value' >&2; exit 2; }; artifact_root=$2; shift 2 ;;
    *) printf 'usage: %s [--iterations N] [--artifact-root PATH]\n' "$0" >&2; exit 2 ;;
  esac
done
[[ $iterations =~ ^[1-9][0-9]*$ ]] || { printf 'iterations must be positive\n' >&2; exit 2; }

temp_root=$(mktemp -d "${TMPDIR:-/tmp}/game-foundry-gf-web001.XXXXXX")
started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
start_ns=$(date +%s%N)
checks='[]'
failures=0
real_godot_export_count=0
successful_real_exports=0
mkdir -p "$artifact_root/negative" "$artifact_root/iterations"
cleanup() { rm -rf -- "$temp_root"; }
trap cleanup EXIT

record() {
  local iteration=$1 name=$2 status=$3 detail=${4:-}
  checks=$(jq --argjson iteration "$iteration" --arg name "$name" --arg status "$status" --arg detail "$detail" \
    '. + [{iteration:$iteration,name:$name,status:$status,detail:(if $detail=="" then null else $detail end)}]' <<<"$checks")
  printf 'iteration %02d %-34s %s\n' "$iteration" "$name" "${status^^}"
  [[ $status == pass ]] || failures=$((failures + 1))
}

copy_fixture() {
  local destination=$1
  cp -a "$fixture" "$destination"
  rm -rf -- "$destination/.godot"
}

# Workstation readiness is real and independent of the export result.
"$repo_root/scripts/doctor.sh" --json >"$artifact_root/doctor.json" 2>"$artifact_root/doctor.stderr"
doctor_code=$?
if [[ $doctor_code -eq 0 ]] && jq -e '.status=="ready" and .tools.godot.web_export.status=="pass" and any(.checks[]; .id=="web_export_templates" and .status=="pass")' "$artifact_root/doctor.json" >/dev/null; then
  record 0 A_doctor_web_capability pass
else
  record 0 A_doctor_web_capability fail "exit=$doctor_code"
fi

"$tool" validate-project "$fixture" --preset 'Game Foundry Web' >"$artifact_root/fixture-validation.json"
fixture_code=$?
if [[ $fixture_code -eq 0 ]] && jq -e '.status=="pass" and .renderer=="gl_compatibility" and .threaded==false and .extensions_support==false' "$artifact_root/fixture-validation.json" >/dev/null; then
  record 0 B_fixture_configuration pass
else
  record 0 B_fixture_configuration fail "exit=$fixture_code"
fi

# Two genuine clean exports prove structural repeatability. A third genuine
# invocation below is the controlled source-mutation failure case.
for export_number in 1 2; do
  export_dir="$artifact_root/export-$export_number"
  real_godot_export_count=$((real_godot_export_count + 1))
  "$exporter" --fixture-id web-export-fixture --artifact-dir "$export_dir" "$fixture" "$export_dir/web" >"$export_dir.console.json" 2>"$export_dir.console.stderr"
  code=$?
  if [[ $code -eq 0 ]] && jq -e '.status=="pass" and .verification.status=="pass" and .source_unchanged==true and .browser_runtime_acceptance=="not_tested"' "$export_dir/export-result.json" >/dev/null; then
    successful_real_exports=$((successful_real_exports + 1))
    record 0 "C_real_export_$export_number" pass
  else
    record 0 "C_real_export_$export_number" fail "exit=$code"
  fi
done

"$tool" compare "$artifact_root/export-1/web-release.json" "$artifact_root/export-2/web-release.json" >"$artifact_root/repeatability.json"
repeat_code=$?
if [[ $repeat_code -eq 0 ]] && jq -e '.status=="pass" and .structurally_equivalent==true' "$artifact_root/repeatability.json" >/dev/null; then
  record 0 D_structural_repeatability pass
else
  record 0 D_structural_repeatability fail "exit=$repeat_code"
fi

# Controlled preflight failures do not damage workstation templates.
copy_fixture "$temp_root/missing-templates-project"
missing_artifact="$artifact_root/negative/missing-templates"
mkdir -p "$missing_artifact"
GODOT_EXPORT_TEMPLATES_DIR="$temp_root/no-templates" "$exporter" --artifact-dir "$missing_artifact" \
  "$temp_root/missing-templates-project" "$missing_artifact/web" >"$missing_artifact/console.json" 2>"$missing_artifact/console.stderr"
missing_code=$?
GODOT_EXPORT_TEMPLATES_DIR="$temp_root/no-templates" "$repo_root/scripts/doctor.sh" --json >"$missing_artifact/doctor.json" 2>"$missing_artifact/doctor.stderr"
missing_doctor_code=$?
if [[ $missing_code -ne 0 && $missing_doctor_code -ne 0 ]] && jq -e '.status=="fail" and (.reason|contains("template is missing"))' "$missing_artifact/export-result.json" >/dev/null && jq -e 'any(.checks[]; .id=="web_export_templates" and .status=="fail")' "$missing_artifact/doctor.json" >/dev/null; then record 0 H_missing_templates pass; else record 0 H_missing_templates fail "export_exit=$missing_code doctor_exit=$missing_doctor_code"; fi

copy_fixture "$temp_root/incompatible-renderer-project"
sed -i 's/gl_compatibility/gl_compatibility_invalid/g' "$temp_root/incompatible-renderer-project/project.godot"
renderer_artifact="$artifact_root/negative/incompatible-renderer"
mkdir -p "$renderer_artifact"
"$exporter" --artifact-dir "$renderer_artifact" "$temp_root/incompatible-renderer-project" "$renderer_artifact/web" >"$renderer_artifact/console.json" 2>"$renderer_artifact/console.stderr"
renderer_code=$?
if [[ $renderer_code -ne 0 ]] && jq -e '.status=="fail" and (.reason|contains("project validation"))' "$renderer_artifact/export-result.json" >/dev/null && jq -e '.failures|any(contains("gl_compatibility"))' "$renderer_artifact/project-validation.json" >/dev/null; then record 0 I_incompatible_renderer pass; else record 0 I_incompatible_renderer fail "exit=$renderer_code"; fi

copy_fixture "$temp_root/threaded-project"
sed -i 's/variant\/thread_support=false/variant\/thread_support=true/' "$temp_root/threaded-project/export_presets.cfg"
thread_artifact="$artifact_root/negative/threaded-profile"
mkdir -p "$thread_artifact"
"$exporter" --artifact-dir "$thread_artifact" "$temp_root/threaded-project" "$thread_artifact/web" >"$thread_artifact/console.json" 2>"$thread_artifact/console.stderr"
thread_code=$?
if [[ $thread_code -ne 0 ]] && jq -e '.failures|any(contains("thread_support=false"))' "$thread_artifact/project-validation.json" >/dev/null; then record 0 J_threaded_profile pass; else record 0 J_threaded_profile fail "exit=$thread_code"; fi

copy_fixture "$temp_root/native-extension-project"
printf '[configuration]\nentry_symbol = "example"\n' >"$temp_root/native-extension-project/unsupported.gdextension"
native_artifact="$artifact_root/negative/native-extension"
mkdir -p "$native_artifact"
"$exporter" --artifact-dir "$native_artifact" "$temp_root/native-extension-project" "$native_artifact/web" >"$native_artifact/console.json" 2>"$native_artifact/console.stderr"
native_code=$?
if [[ $native_code -ne 0 ]] && jq -e '.failures|any(contains("native extension"))' "$native_artifact/project-validation.json" >/dev/null; then record 0 P_native_extension pass; else record 0 P_native_extension fail "exit=$native_code"; fi

copy_fixture "$temp_root/source-mutation-project"
mutation_artifact="$artifact_root/negative/source-mutation"
mkdir -p "$mutation_artifact"
real_godot_export_count=$((real_godot_export_count + 1))
GF_GF_WEB001_ENABLE_TEST_HOOKS=1 GF_GF_WEB001_SOURCE_MUTATION=1 "$exporter" --artifact-dir "$mutation_artifact" \
  "$temp_root/source-mutation-project" "$mutation_artifact/web" >"$mutation_artifact/console.json" 2>"$mutation_artifact/console.stderr"
mutation_code=$?
if [[ $mutation_code -ne 0 ]] && jq -e '.status=="fail" and (.reason|contains("source mutation"))' "$mutation_artifact/export-result.json" >/dev/null && jq -e '.source_unchanged==false' "$mutation_artifact/export-metadata.json" >/dev/null; then record 0 O_source_mutation pass; else record 0 O_source_mutation fail "exit=$mutation_code"; fi

# Repeat the deterministic integrity matrix without repeating the expensive
# engine export. Every iteration begins from genuine exported bytes.
for ((iteration=1; iteration<=iterations; iteration++)); do
  iteration_dir="$artifact_root/iterations/$(printf '%02d' "$iteration")"
  mkdir -p "$iteration_dir"

  "$verifier" "$artifact_root/export-1/web-release.json" "$artifact_root/export-1/web" >"$iteration_dir/valid.json"
  code=$?
  if [[ $code -eq 0 ]] && jq -e '.status=="pass"' "$iteration_dir/valid.json" >/dev/null; then record "$iteration" E_manifest_verification pass; else record "$iteration" E_manifest_verification fail "exit=$code"; fi

  cp -al "$artifact_root/export-1/web" "$iteration_dir/missing-entry-web"
  rm "$iteration_dir/missing-entry-web/index.html"
  "$verifier" "$artifact_root/export-1/web-release.json" "$iteration_dir/missing-entry-web" >"$iteration_dir/missing-entry.json"
  code=$?
  if [[ $code -ne 0 ]] && jq -e '.errors|any(contains("index.html"))' "$iteration_dir/missing-entry.json" >/dev/null; then record "$iteration" K_missing_entrypoint pass; else record "$iteration" K_missing_entrypoint fail "exit=$code"; fi

  cp -al "$artifact_root/export-1/web" "$iteration_dir/missing-wasm-web"
  wasm_path=$(jq -r '.files[]|select(.content_role=="wasm")|.path' "$artifact_root/export-1/web-release.json" | head -1)
  rm "$iteration_dir/missing-wasm-web/$wasm_path"
  "$verifier" "$artifact_root/export-1/web-release.json" "$iteration_dir/missing-wasm-web" >"$iteration_dir/missing-wasm.json"
  code=$?
  if [[ $code -ne 0 ]] && jq -e '.errors|any(contains("wasm"))' "$iteration_dir/missing-wasm.json" >/dev/null; then record "$iteration" L_missing_wasm pass; else record "$iteration" L_missing_wasm fail "exit=$code"; fi

  cp -al "$artifact_root/export-1/web" "$iteration_dir/tamper-web"
  cp --reflink=auto "$artifact_root/export-1/web/index.js" "$iteration_dir/tamper-index.js"
  mv "$iteration_dir/tamper-index.js" "$iteration_dir/tamper-web/index.js"
  printf '\nCONTROLLED_TAMPER\n' >>"$iteration_dir/tamper-web/index.js"
  "$verifier" "$artifact_root/export-1/web-release.json" "$iteration_dir/tamper-web" >"$iteration_dir/tamper.json"
  code=$?
  if [[ $code -ne 0 ]] && jq -e '.errors|any(contains("SHA-256 mismatch"))' "$iteration_dir/tamper.json" >/dev/null; then record "$iteration" M_hash_tamper pass; else record "$iteration" M_hash_tamper fail "exit=$code"; fi

  jq '(.files[0].path)="../escape.js"' "$artifact_root/export-1/web-release.json" >"$iteration_dir/unsafe-manifest.json"
  "$verifier" "$iteration_dir/unsafe-manifest.json" "$artifact_root/export-1/web" >"$iteration_dir/unsafe-path.json"
  code=$?
  if [[ $code -ne 0 ]] && jq -e '.errors|any(contains("unsafe path"))' "$iteration_dir/unsafe-path.json" >/dev/null; then record "$iteration" N_unsafe_manifest_path pass; else record "$iteration" N_unsafe_manifest_path fail "exit=$code"; fi
done

finished_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
duration=$(awk -v start="$start_ns" -v end="$(date +%s%N)" 'BEGIN {printf "%.6f",(end-start)/1000000000}')
status=pass
((failures > 0)) && status=fail
jq -n --arg slice GF-WEB-001 --arg status "$status" --arg started_at "$started_at" --arg finished_at "$finished_at" \
  --arg artifact_root "$artifact_root" --argjson duration_seconds "$duration" --argjson iterations "$iterations" --argjson failures "$failures" \
  --argjson real_godot_export_count "$real_godot_export_count" --argjson successful_real_exports "$successful_real_exports" \
  --slurpfile doctor "$artifact_root/doctor.json" --slurpfile repeatability "$artifact_root/repeatability.json" --argjson checks "$checks" \
  '{slice:$slice,status:$status,started_at:$started_at,finished_at:$finished_at,duration_seconds:$duration_seconds,artifact_root:$artifact_root,iterations:$iterations,failures:$failures,real_godot_export_count:$real_godot_export_count,successful_real_exports:$successful_real_exports,doctor:$doctor[0],repeatability:$repeatability[0],checks:$checks,boundaries:{browser_runtime_acceptance:"not_tested",astro_site_integration:"not_implemented",cloudflare_deployment:"not_implemented"}}' \
  >"$artifact_root/evidence-summary.json"

printf 'GF-WEB-001 DETERMINISTIC ACCEPTANCE: %s\nITERATIONS: %s\nFAILURES: %s\nREAL GODOT EXPORTS: %s\nEVIDENCE: %s\nBROWSER RUNTIME ACCEPTANCE = NOT TESTED\n' \
  "${status^^}" "$iterations" "$failures" "$real_godot_export_count" "$artifact_root"
((failures == 0))
