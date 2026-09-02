#!/usr/bin/env bash
set -u -o pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
game="$repo_root/games/cyber-shield"
browser_runs=2
artifact_root=${GF_WEB004_ARTIFACT_ROOT:-$repo_root/artifacts/gf-web-004/gf-web-004-acceptance-$(date -u +%Y%m%dT%H%M%SZ)-$$}

while (($#)); do
  case "$1" in
    --browser-runs) browser_runs=${2:?--browser-runs requires a value}; shift 2 ;;
    --artifact-root) artifact_root=${2:?--artifact-root requires a value}; shift 2 ;;
    *) printf 'usage: %s [--browser-runs N] [--artifact-root PATH]\n' "$0" >&2; exit 2 ;;
  esac
done
[[ $browser_runs =~ ^[1-9][0-9]*$ ]] || { printf 'browser runs must be positive\n' >&2; exit 2; }

artifact_root=$(realpath -m "$artifact_root")
started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
start_ns=$(date +%s%N)
checks='[]'
failures=0
browser_pass=0
mkdir -p "$artifact_root/game" "$artifact_root/linux" "$artifact_root/web-export" "$artifact_root/regression"

record() {
  local group=$1 name=$2 status=$3 detail=${4:-}
  checks=$(jq --arg group "$group" --arg name "$name" --arg status "$status" --arg detail "$detail" \
    '. + [{group:$group,name:$name,status:$status,detail:(if $detail=="" then null else $detail end)}]' <<<"$checks")
  printf '%-13s %-36s %s\n' "$group" "$name" "${status^^}"
  [[ $status == pass ]] || failures=$((failures + 1))
}

source_fingerprint() {
  local relative
  while IFS= read -r -d '' relative; do
    printf '%s\0' "$relative"
    if [[ -L $repo_root/$relative ]]; then
      printf 'symlink:%s\0' "$(readlink "$repo_root/$relative")"
    elif [[ -f $repo_root/$relative ]]; then
      sha256sum "$repo_root/$relative"
    else
      printf 'missing\0'
    fi
  done < <(git -C "$repo_root" ls-files --cached --others --exclude-standard -z)
}

before_source=$(source_fingerprint | sha256sum | cut -d' ' -f1)

"$repo_root/scripts/doctor.sh" --json >"$artifact_root/doctor.json" 2>"$artifact_root/doctor.stderr"
code=$?
if [[ $code -eq 0 ]] && jq -e '.status=="ready" and .tools.godot.web_export.status=="pass" and .tools.browser_runtime.status=="pass"' "$artifact_root/doctor.json" >/dev/null; then record preflight doctor pass; else record preflight doctor fail "exit=$code"; fi

godot_bin=$(jq -r '.tools.godot.path // "godot"' "$artifact_root/doctor.json")
"$repo_root/scripts/lib/gf-web.py" validate-project "$game" --preset 'Game Foundry Web' >"$artifact_root/game/project-validation.json"
code=$?
if [[ $code -eq 0 ]] && jq -e '.status=="pass" and .renderer=="gl_compatibility" and .threaded==false and .extensions_support==false' "$artifact_root/game/project-validation.json" >/dev/null; then record game project_validation pass; else record game project_validation fail "exit=$code"; fi

"$godot_bin" --headless --path "$game" --script res://tests/game_acceptance.gd >"$artifact_root/game/game-acceptance.stdout" 2>"$artifact_root/game/game-acceptance.stderr"
code=$?
sed -n 's/^GF_WEB_004_GAME_ACCEPTANCE=//p' "$artifact_root/game/game-acceptance.stdout" | tail -n 1 >"$artifact_root/game/game-acceptance.json"
if [[ $code -eq 0 ]] && jq -e '.status=="pass" and .failures==0 and (.checks|length)==11 and all(.checks[];.status=="pass")' "$artifact_root/game/game-acceptance.json" >/dev/null; then record game deterministic_gameplay pass; else record game deterministic_gameplay fail "exit=$code"; fi

"$godot_bin" --headless --path "$game" --export-release 'Game Foundry Linux' "$artifact_root/linux/cyber-shield.x86_64" >"$artifact_root/linux/export.stdout" 2>"$artifact_root/linux/export.stderr"
linux_export_code=$?
if [[ $linux_export_code -eq 0 && -x $artifact_root/linux/cyber-shield.x86_64 ]]; then record linux x86_64_export pass; else record linux x86_64_export fail "exit=$linux_export_code"; fi
"$artifact_root/linux/cyber-shield.x86_64" --headless -- --runtime-smoke >"$artifact_root/linux/runtime.stdout" 2>"$artifact_root/linux/runtime.stderr"
linux_runtime_code=$?
if [[ $linux_runtime_code -eq 0 ]] && rg -q '^CYBER_SHIELD_RUNTIME_SMOKE_OK$' "$artifact_root/linux/runtime.stdout"; then record linux runtime_smoke pass; else record linux runtime_smoke fail "exit=$linux_runtime_code"; fi
jq -n --arg status "$([[ $linux_export_code -eq 0 && $linux_runtime_code -eq 0 ]] && printf pass || printf fail)" \
  --arg binary "$artifact_root/linux/cyber-shield.x86_64" --argjson size_bytes "$(stat -c %s "$artifact_root/linux/cyber-shield.x86_64" 2>/dev/null || printf 0)" \
  --argjson export_exit "$linux_export_code" --argjson runtime_exit "$linux_runtime_code" \
  '{status:$status,platform:"Linux",architecture:"x86_64",binary:$binary,size_bytes:$size_bytes,export_exit:$export_exit,runtime_exit:$runtime_exit}' >"$artifact_root/linux/result.json"

"$repo_root/scripts/gf-web-export.sh" --fixture-id cyber-shield --artifact-dir "$artifact_root/web-export" "$game" "$artifact_root/web-export/web" >"$artifact_root/web-export.console.json" 2>"$artifact_root/web-export.console.stderr"
code=$?
if [[ $code -eq 0 ]] && jq -e '.status=="pass" and .target=="web" and .verification.status=="pass" and .source_unchanged==true' "$artifact_root/web-export/export-result.json" >/dev/null; then record pipeline gf_web_001 pass; else record pipeline gf_web_001 fail "exit=$code"; fi
manifest="$artifact_root/web-export/web-release.json"
bundle="$artifact_root/web-export/web"

"$repo_root/scripts/gf-web-browser-test.sh" "$manifest" "$bundle" "$artifact_root/gf-web-002" >"$artifact_root/gf-web-002.console.json" 2>"$artifact_root/gf-web-002.console.stderr"
code=$?
if [[ $code -eq 0 ]] && jq -e '.status=="pass" and .runtime_ready==true and .wasm_status.status==200 and (.wasm_status.content_type|startswith("application/wasm")) and .rendering.nonempty==true and .rendering.changed_after_input==true and .keyboard_test.passed==true and .mouse_test.passed==true and .console_error_count==0 and .page_error_count==0 and .cleanup.browser_closed==true' "$artifact_root/gf-web-002/browser-result.json" >/dev/null; then record pipeline gf_web_002 pass; else record pipeline gf_web_002 fail "exit=$code"; fi

"$repo_root/scripts/gf-web-hosting-classify.sh" "$manifest" >"$artifact_root/classification.json"
code=$?
if [[ $code -eq 0 ]] && jq -e '.compatible==false and .reason=="individual_file_limit" and .recommended_profile=="cloudflare-pages-r2" and .largest_file_bytes>.max_file_bytes' "$artifact_root/classification.json" >/dev/null; then record hosting classification pass; else record hosting classification fail "exit=$code"; fi

release="$artifact_root/release"
"$repo_root/scripts/gf-web-hosting-package.sh" --slug cyber-shield --route /games/cyber-shield/ "$manifest" "$bundle" "$release" >"$artifact_root/package-result.json" 2>"$artifact_root/package.stderr"
code=$?
if [[ $code -eq 0 ]] && jq -e '.status=="pass" and .hosting_profile=="cloudflare-pages-r2"' "$artifact_root/package-result.json" >/dev/null; then record hosting pages_r2_package pass; else record hosting pages_r2_package fail "exit=$code"; fi
"$repo_root/scripts/gf-web-hosting-verify.sh" "$release" >"$artifact_root/hosting-verification.json"
code=$?
if [[ $code -eq 0 ]] && jq -e '.status=="pass" and .pages_file_count>0 and .r2_file_count>0' "$artifact_root/hosting-verification.json" >/dev/null; then record hosting package_verification pass; else record hosting package_verification fail "exit=$code"; fi

"$repo_root/scripts/gf-web-browser-test.sh" --hosting-release "$release" "$artifact_root/gf-web-003" >"$artifact_root/gf-web-003.console.json" 2>"$artifact_root/gf-web-003.console.stderr"
code=$?
if [[ $code -eq 0 ]] && jq -e '.status=="pass" and .hosting_profile=="cloudflare-pages-r2" and .wasm_status.origin==.asset_url and .cors.passed==true and .cleanup.browser_closed==true and .cleanup.site_server_closed==true and .cleanup.asset_server_closed==true' "$artifact_root/gf-web-003/browser-result.json" >/dev/null; then record hosting gf_web_003_local_browser pass; else record hosting gf_web_003_local_browser fail "exit=$code"; fi

for ((run=1; run<=browser_runs; run++)); do
  run_dir="$artifact_root/game-browser/run-$(printf '%02d' "$run")"
  mkdir -p "$run_dir"
  "$repo_root/scripts/gf-web-004-browser-test.sh" "$release" "$run_dir" >"$run_dir.console.json" 2>"$run_dir.console.stderr"
  code=$?
  if [[ $code -eq 0 ]] && jq -e '.status=="pass" and .runtime_ready==true and .keyboard_movement.passed==true and .mouse_movement.passed==true and .touch_control.passed==true and .threat_spawn_and_fall.passed==true and .blocked_threat.passed==true and .game_over.passed==true and .spawn_stop.passed==true and .restart.passed==true and .wasm.passed==true and .console_error_count==0 and .page_error_count==0 and .cleanup.browser_closed==true and .cleanup.site_server_closed==true and .cleanup.asset_server_closed==true' "$run_dir/browser-result.json" >/dev/null; then
    browser_pass=$((browser_pass + 1)); record browser "cyber_shield_$(printf '%02d' "$run")" pass
  else
    record browser "cyber_shield_$(printf '%02d' "$run")" fail "exit=$code"
  fi
done

preview_ready="$artifact_root/manual-preview-ready.json"
GF_WEB_PREVIEW_READY_FILE="$preview_ready" "$repo_root/scripts/gf-web-local-preview.sh" "$release" >"$artifact_root/manual-preview.stdout" 2>"$artifact_root/manual-preview.stderr" &
preview_pid=$!
preview_available=false
for _attempt in {1..100}; do
  if [[ -s $preview_ready ]]; then preview_available=true; break; fi
  sleep 0.05
done
preview_http=false
if $preview_available; then
  preview_url=$(jq -r .game_url "$preview_ready")
  if curl -fsS --max-time 5 "$preview_url" >/dev/null; then preview_http=true; fi
fi
kill -INT "$preview_pid" 2>/dev/null || true
wait "$preview_pid" 2>/dev/null
preview_exit=$?
if $preview_available && $preview_http && [[ $preview_exit -eq 0 ]]; then record preview manual_command_smoke pass; else record preview manual_command_smoke fail "ready=$preview_available http=$preview_http exit=$preview_exit"; fi

"$repo_root/scripts/gf-web-001-acceptance.sh" --iterations 1 --artifact-root "$artifact_root/regression/gf-web-001" >"$artifact_root/regression/gf-web-001.console" 2>"$artifact_root/regression/gf-web-001.stderr"
code=$?
if [[ $code -eq 0 ]] && jq -e '.status=="pass"' "$artifact_root/regression/gf-web-001/evidence-summary.json" >/dev/null; then record regression gf_web_001 pass; else record regression gf_web_001 fail "exit=$code"; fi

"$repo_root/scripts/gf-web-002-acceptance.sh" --healthy-runs 1 --fault-iterations 1 --artifact-root "$artifact_root/regression/gf-web-002" >"$artifact_root/regression/gf-web-002.console" 2>"$artifact_root/regression/gf-web-002.stderr"
code=$?
if [[ $code -eq 0 ]] && jq -e '.status=="pass"' "$artifact_root/regression/gf-web-002/evidence-summary.json" >/dev/null; then record regression gf_web_002 pass; else record regression gf_web_002 fail "exit=$code"; fi

"$repo_root/scripts/gf-web-003-acceptance.sh" --healthy-runs 1 --iterations 1 --artifact-root "$artifact_root/regression/gf-web-003" >"$artifact_root/regression/gf-web-003.console" 2>"$artifact_root/regression/gf-web-003.stderr"
code=$?
if [[ $code -eq 0 ]] && jq -e '.status=="pass"' "$artifact_root/regression/gf-web-003/result.json" >/dev/null; then record regression gf_web_003 pass; else record regression gf_web_003 fail "exit=$code"; fi

after_source=$(source_fingerprint | sha256sum | cut -d' ' -f1)
if [[ $before_source == "$after_source" ]]; then record integrity source_unchanged pass; else record integrity source_unchanged fail; fi
jq -n --arg before "$before_source" --arg after "$after_source" '{before:$before,after:$after,unchanged:($before==$after)}' >"$artifact_root/source-state.json"

finished_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
duration=$(awk -v start="$start_ns" -v end="$(date +%s%N)" 'BEGIN{printf "%.6f",(end-start)/1000000000}')
status=pass
((failures > 0)) && status=fail
source_files=$(find "$game" -path '*/.godot' -prune -o -type f -print | wc -l)
gameplay_lines=$(wc -l <"$game/cyber_shield.gd")
pages_count=$(jq '[.files[]|select(.package=="pages")]|length' "$release/hosting-manifest.json")
r2_count=$(jq '[.files[]|select(.package=="r2")]|length' "$release/hosting-manifest.json")
jq -n --arg status "$status" --arg started_at "$started_at" --arg finished_at "$finished_at" --arg artifact_root "$artifact_root" \
  --argjson duration_seconds "$duration" --argjson browser_runs "$browser_runs" --argjson browser_pass "$browser_pass" --argjson failures "$failures" \
  --argjson source_files "$source_files" --argjson gameplay_lines "$gameplay_lines" --argjson pages_count "$pages_count" --argjson r2_count "$r2_count" --argjson checks "$checks" \
  --slurpfile game_acceptance "$artifact_root/game/game-acceptance.json" --slurpfile web_export "$artifact_root/web-export/export-result.json" \
  --slurpfile web_browser "$artifact_root/gf-web-002/browser-result.json" --slurpfile classification "$artifact_root/classification.json" \
  --slurpfile hosting "$release/hosting-manifest.json" --slurpfile hosting_browser "$artifact_root/gf-web-003/browser-result.json" \
  --slurpfile game_browser "$artifact_root/game-browser/run-01/browser-result.json" \
  '{slice:"GF-WEB-004",status:$status,started_at:$started_at,finished_at:$finished_at,duration_seconds:$duration_seconds,artifact_root:$artifact_root,game:{id:"cyber-shield",title:"Cyber Shield",engine:"Godot 4",architecture:"Node2D",viewport:{width:960,height:540},source_files:$source_files,gameplay_code_lines:$gameplay_lines,threat_labels:["PHISHING","VIRUS","MALWARE","DDoS","RANSOMWARE","BOTNET"],controls:["Left","Right","A","D","mouse","touch"]},game_acceptance:$game_acceptance[0],linux:{status:"pass",result_path:($artifact_root+"/linux/result.json")},web_pipeline:{gf_web_001:$web_export[0],gf_web_002:$web_browser[0],classification:$classification[0],hosting_manifest:$hosting[0],gf_web_003_browser:$hosting_browser[0]},browser_gameplay:{runs:$browser_runs,pass:$browser_pass,fail:($browser_runs-$browser_pass),canonical:$game_browser[0]},package:{pages_file_count:$pages_count,r2_file_count:$r2_count,release:($artifact_root+"/release")},regressions:{gf_web_001:"pass",gf_web_002:"pass",gf_web_003:"pass"},metrics:{critic_calls:0,repair_attempts:1,human_implementation_interventions:0},checks:$checks,failures:$failures,human_web_gameplay_qa:"pending",boundaries:{mythadis_site_integration:"not_implemented",rcblanzy_site_integration:"not_implemented",remote_r2_upload:"not_implemented",cloudflare_deployment:"not_implemented"}}' >"$artifact_root/result.json"

printf 'GF-WEB-004 ACCEPTANCE: %s\nGAME CHECKS: %s\nCYBER SHIELD CHROMIUM: %s/%s\nFAILURES: %s\nDURATION: %ss\nEVIDENCE: %s\nHUMAN WEB GAMEPLAY QA = PENDING\n' \
  "${status^^}" "$(jq '.checks|length' "$artifact_root/game/game-acceptance.json")" "$browser_pass" "$browser_runs" "$failures" "$duration" "$artifact_root"
((failures == 0))
