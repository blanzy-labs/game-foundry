#!/usr/bin/env bash
set -u -o pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exporter="$repo_root/scripts/gf-web-export.sh"
browser_test="$repo_root/scripts/gf-web-browser-test.sh"
fixture="$repo_root/fixtures/web-export-project"
healthy_runs=1
fault_iterations=1
artifact_root=${GF_WEB002_ARTIFACT_ROOT:-$repo_root/artifacts/gf-web-002/gf-web-002-acceptance-$(date -u +%Y%m%dT%H%M%SZ)-$$}

while (($#)); do
  case "$1" in
    --healthy-runs) healthy_runs=$2; shift 2 ;;
    --fault-iterations) fault_iterations=$2; shift 2 ;;
    --artifact-root) artifact_root=$2; shift 2 ;;
    *) printf 'usage: %s [--healthy-runs N] [--fault-iterations N] [--artifact-root PATH]\n' "$0" >&2; exit 2 ;;
  esac
done
[[ $healthy_runs =~ ^[1-9][0-9]*$ && $fault_iterations =~ ^[1-9][0-9]*$ ]] || { printf 'run counts must be positive\n' >&2; exit 2; }

temp_root=$(mktemp -d "${TMPDIR:-/tmp}/game-foundry-gf-web002.XXXXXX")
started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
start_ns=$(date +%s%N)
checks='[]'; failures=0; healthy_pass=0; fault_pass=0; deterministic_pass=0
mkdir -p "$artifact_root/healthy" "$artifact_root/negative" "$artifact_root/deterministic"
cleanup() { rm -rf -- "$temp_root"; }
trap cleanup EXIT

record() {
  local group=$1 name=$2 status=$3 detail=${4:-}
  checks=$(jq --arg group "$group" --arg name "$name" --arg status "$status" --arg detail "$detail" '.+[{group:$group,name:$name,status:$status,detail:(if $detail=="" then null else $detail end)}]' <<<"$checks")
  printf '%-15s %-34s %s\n' "$group" "$name" "${status^^}"
  [[ $status == pass ]] || failures=$((failures+1))
}

"$repo_root/scripts/doctor.sh" --json >"$artifact_root/doctor.json" 2>"$artifact_root/doctor.stderr"
doctor_code=$?
if [[ $doctor_code -eq 0 ]] && jq -e '.status=="ready" and .tools.browser_runtime.status=="pass" and .tools.godot.web_export.status=="pass"' "$artifact_root/doctor.json" >/dev/null; then record preflight doctor pass; else record preflight doctor fail "exit=$doctor_code"; fi

export_dir="$artifact_root/gf-web-001-release"
"$exporter" --fixture-id web-export-fixture --artifact-dir "$export_dir" "$fixture" "$export_dir/web" >"$artifact_root/export.console.json" 2>"$artifact_root/export.console.stderr"
export_code=$?
if [[ $export_code -eq 0 ]] && jq -e '.status=="pass" and .verification.status=="pass"' "$export_dir/export-result.json" >/dev/null; then record preflight gf_web_001_release pass; else record preflight gf_web_001_release fail "exit=$export_code"; fi
manifest="$export_dir/web-release.json"; bundle="$export_dir/web"

for ((run=1; run<=healthy_runs; run++)); do
  run_dir="$artifact_root/healthy/run-$(printf '%02d' "$run")"
  "$browser_test" "$manifest" "$bundle" "$run_dir" >"$run_dir.console.json" 2>"$run_dir.console.stderr"
  code=$?
  if [[ $code -eq 0 ]] && jq -e '.status=="pass" and .runtime_ready==true and .wasm_requested==true and .wasm_status.status==200 and (.wasm_status.content_type|startswith("application/wasm")) and .canvas_found==true and .rendering.nonempty==true and .rendering.changed_after_input==true and .keyboard_test.passed==true and .mouse_test.passed==true and .console_error_count==0 and .page_error_count==0 and .failed_required_request_count==0 and .resize_test.passed==true and .small_viewport_test.passed==true and .cleanup.browser_closed==true and .cleanup.server_closed==true' "$run_dir/browser-result.json" >/dev/null && [[ -s $run_dir/browser-runtime-ready.png ]]; then
    healthy_pass=$((healthy_pass+1)); record healthy "real_chromium_$(printf '%02d' "$run")" pass
  else record healthy "real_chromium_$(printf '%02d' "$run")" fail "exit=$code"; fi
done

run_fault() {
  local name=$1 fault=$2 expected=$3 case_manifest=$manifest case_bundle=$bundle timeout=1800 code js case_dir
  case_dir="$artifact_root/negative/$name"
  mkdir -p "$case_dir"
  if [[ $name == missing_wasm ]]; then
    cp -a --reflink=auto "$bundle" "$temp_root/missing-wasm"
    rm "$temp_root/missing-wasm/$(jq -r '.files[]|select(.content_role=="wasm")|.path' "$manifest" | head -1)"
    case_bundle="$temp_root/missing-wasm"
  elif [[ $name == broken_javascript ]]; then
    cp -a --reflink=auto "$bundle" "$temp_root/broken-js"
    js=$(jq -r '.files[]|select(.content_role=="javascript" and (.path|endswith(".js")))|.path' "$manifest" | tail -1)
    cp --reflink=auto "$bundle/$js" "$temp_root/detached.js"; mv "$temp_root/detached.js" "$temp_root/broken-js/$js"
    printf 'this is controlled invalid javascript {{{\n' >"$temp_root/broken-js/$js"
    case_bundle="$temp_root/broken-js"
  fi
  GF_GF_WEB002_ENABLE_TEST_HOOKS=1 "$browser_test" --fault "$fault" --skip-integrity --startup-timeout-ms "$timeout" --input-timeout-ms 900 "$case_manifest" "$case_bundle" "$case_dir" >"$case_dir.console.json" 2>"$case_dir.console.stderr"
  code=$?
  if [[ $name == http_server_close_failure && $code -ne 0 ]] &&
     jq -e '.status=="fail" and .cleanup.browser_closed==true and .cleanup.server_closed==false and (.cleanup.server_close_error|contains("GF_WEB_CONTROLLED_SERVER_CLOSE_FAILURE"))' "$case_dir/browser-result.json" >/dev/null; then
    fault_pass=$((fault_pass+1)); record negative "$name" pass
  elif [[ $code -ne 0 ]] && jq -e --arg expected "$expected" '.status=="fail" and .cleanup.browser_closed==true and .cleanup.server_closed==true and (.failure_reason|test($expected;"i"))' "$case_dir/browser-result.json" >/dev/null; then
    fault_pass=$((fault_pass+1)); record negative "$name" pass
  else record negative "$name" fail "exit=$code expected=$expected"; fi
}

run_fault missing_wasm missing_wasm 'Timeout|ready|WASM|resource'
run_fault broken_javascript broken_javascript 'ready|page|javascript'
run_fault runtime_never_ready never_ready 'Timeout'
run_fault page_exception page_exception 'page exception'
run_fault console_error console_error 'console error'
run_fault input_nonresponsive input_nonresponsive 'Timeout|keyboard input'
run_fault zero_size_canvas zero_canvas 'canvas|outside|visible'
run_fault blank_canvas blank_canvas 'blank|render'
run_fault bad_mime bad_mime 'MIME|ready|WASM'
run_fault http_server_failure server_bind_failure 'EADDRINUSE|HTTP_SERVER_BIND'
run_fault http_server_close_failure server_close_failure 'SERVER_CLOSE_FAILURE|cleanup failed'

exception_url=$(jq -r '.url // empty' "$artifact_root/negative/page_exception/browser-result.json")
cleanup_ok=false
if jq -e '.cleanup.browser_closed==true and .cleanup.server_closed==true and .cleanup.browser_close_error==null and (.cleanup.browser_processes_remaining|length)==0' "$artifact_root/negative/page_exception/browser-result.json" >/dev/null; then
  if [[ -z $exception_url ]] || ! curl -fsS --max-time 1 "$exception_url" >/dev/null 2>&1; then cleanup_ok=true; fi
fi
if $cleanup_ok; then fault_pass=$((fault_pass+1)); record negative orphan_cleanup pass; else record negative orphan_cleanup fail; fi

for ((iteration=1; iteration<=fault_iterations; iteration++)); do
  case_dir="$artifact_root/deterministic/$(printf '%02d' "$iteration")"
  mkdir -p "$case_dir"
  GF_GF_WEB002_ENABLE_TEST_HOOKS=1 "$browser_test" --fault server_bind_failure --skip-integrity "$manifest" "$bundle" "$case_dir" >"$case_dir.console.json" 2>"$case_dir.console.stderr"
  code=$?
  if [[ $code -ne 0 ]] && jq -e '.status=="fail" and .cleanup.server_closed==true and .cleanup.browser_closed==true' "$case_dir/browser-result.json" >/dev/null; then
    deterministic_pass=$((deterministic_pass+1)); record deterministic "server_cleanup_$(printf '%02d' "$iteration")" pass
  else record deterministic "server_cleanup_$(printf '%02d' "$iteration")" fail "exit=$code"; fi
done

finished_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
duration=$(awk -v start="$start_ns" -v end="$(date +%s%N)" 'BEGIN{printf "%.6f",(end-start)/1000000000}')
status=pass; ((failures>0)) && status=fail
jq -n --arg slice GF-WEB-002 --arg status "$status" --arg started_at "$started_at" --arg finished_at "$finished_at" --arg artifact_root "$artifact_root" \
  --argjson healthy_runs "$healthy_runs" --argjson healthy_pass "$healthy_pass" --argjson fault_iterations "$fault_iterations" --argjson deterministic_pass "$deterministic_pass" --argjson fault_cases_pass "$fault_pass" --argjson failures "$failures" --argjson duration_seconds "$duration" --argjson checks "$checks" \
  --slurpfile doctor "$artifact_root/doctor.json" --slurpfile canonical "$artifact_root/healthy/run-01/browser-result.json" \
  '{slice:$slice,status:$status,started_at:$started_at,finished_at:$finished_at,artifact_root:$artifact_root,duration_seconds:$duration_seconds,healthy:{runs:$healthy_runs,pass:$healthy_pass,fail:($healthy_runs-$healthy_pass)},deterministic_fault:{iterations:$fault_iterations,mode:"pre_launch_server_bind_and_cleanup",pass:$deterministic_pass,fail:($fault_iterations-$deterministic_pass),full_negative_cases_pass:$fault_cases_pass,full_negative_cases_run_once:true},failures:$failures,doctor:$doctor[0],canonical_browser_result:$canonical[0],checks:$checks,boundaries:{chromium_runtime_acceptance:(if $status=="pass" then "pass" else "fail" end),multi_browser_compatibility:"not_tested",mobile_touch_ux:"not_tested",astro_site_integration:"not_implemented",cloudflare_deployment:"not_implemented"}}' >"$artifact_root/evidence-summary.json"
printf 'GF-WEB-002 ACCEPTANCE: %s\nHEALTHY CHROMIUM: %s/%s\nFAULT ITERATIONS: %s\nFAILURES: %s\nEVIDENCE: %s\n' "${status^^}" "$healthy_pass" "$healthy_runs" "$fault_iterations" "$failures" "$artifact_root"
((failures==0))
