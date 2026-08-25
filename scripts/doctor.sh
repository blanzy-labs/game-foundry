#!/usr/bin/env bash
set -u

json_mode=false
case ${1:-} in
  "") ;;
  --json) json_mode=true ;;
  *) printf 'Usage: %s [--json]\n' "$0" >&2; exit 2 ;;
esac

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PATH="/home/${USER}/.local/bin:${PATH}"
godot_bin=${GODOT_BIN:-godot}
marker=GAME_FOUNDRY_GODOT_SMOKE_OK
timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

declare -a ids=() groups=() labels=() statuses=() versions=() details=()
critical_passed=0
critical_failed=0

add_check() {
  local id=$1 group=$2 label=$3 status=$4 version=${5:-} detail=${6:-}
  ids+=("$id"); groups+=("$group"); labels+=("$label"); statuses+=("$status")
  versions+=("$version"); details+=("$detail")
  if [[ $group == critical ]]; then
    if [[ $status == PASS ]]; then ((critical_passed += 1)); else ((critical_failed += 1)); fi
  fi
}

command_version() {
  local command_name=$1
  shift
  if ! command -v "$command_name" >/dev/null 2>&1; then
    add_check "$command_name" critical "$command_name" FAIL "" "command not found"
    return
  fi
  local value
  value=$("$@" 2>/dev/null | head -n 1) || value=""
  add_check "$command_name" critical "$command_name" PASS "$value" ""
}

os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
os_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
if [[ $os_id == ubuntu && $os_version == 26.04 ]]; then
  add_check os critical "Ubuntu 26.04" PASS "$os_version" ""
else
  add_check os critical "Ubuntu 26.04" FAIL "$os_id $os_version" "requires Ubuntu 26.04"
fi

arch=$(uname -m)
[[ $arch == x86_64 ]] && add_check arch critical "Architecture x86_64" PASS "$arch" "" || add_check arch critical "Architecture x86_64" FAIL "$arch" "requires x86_64"

command_version bash bash --version
command_version git git --version
command_version curl curl --version
command_version wget wget --version
command_version unzip unzip -v
command_version tar tar --version
command_version jq jq --version
command_version sed sed --version
command_version awk awk --version
command_version grep grep --version
command_version sha256sum sha256sum --version
command_version make make --version
command_version gh gh --version

if command -v gh >/dev/null 2>&1 && timeout 15 gh auth status >/dev/null 2>&1; then
  add_check github_auth critical "GitHub authentication" PASS "authenticated" ""
else
  add_check github_auth critical "GitHub authentication" FAIL "" "run: gh auth login"
fi

node_version=""
if command -v node >/dev/null 2>&1; then node_version=$(node --version 2>/dev/null | sed 's/^v//'); fi
node_supported=false
if [[ $node_version =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
  major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}; patch=${BASH_REMATCH[3]}
  if (( major == 22 && (minor > 22 || (minor == 22 && patch >= 3)) )); then node_supported=true; fi
  if (( major == 24 && minor >= 15 )); then node_supported=true; fi
  if (( major == 25 && minor >= 9 )); then node_supported=true; fi
  if (( major == 26 )); then node_supported=true; fi
fi
$node_supported && add_check node critical "Supported Node.js" PASS "$node_version" "" || add_check node critical "Supported Node.js" FAIL "$node_version" "requires 22.22.3+, 24.15+, 25.9+, or 26.x"

if command -v npm >/dev/null 2>&1; then add_check npm critical npm PASS "$(npm --version 2>/dev/null)" ""; else add_check npm critical npm FAIL "" "command not found"; fi

if command -v openclaw >/dev/null 2>&1; then
  openclaw_version=$(openclaw --version 2>/dev/null | head -n 1)
  add_check openclaw critical OpenClaw PASS "$openclaw_version" ""
else
  add_check openclaw critical OpenClaw FAIL "" "command not found"
fi

if command -v openclaw >/dev/null 2>&1 && timeout 20 openclaw config validate >/dev/null 2>&1; then
  add_check openclaw_config critical "OpenClaw configuration" PASS "valid" ""
else
  add_check openclaw_config critical "OpenClaw configuration" FAIL "" "run: openclaw config validate"
fi

if command -v openclaw >/dev/null 2>&1 && timeout 20 openclaw health >/dev/null 2>&1; then
  add_check openclaw_health optional "OpenClaw gateway (observational)" PASS "healthy" "not used by canonical Game Foundry execution"
else
  add_check openclaw_health optional "OpenClaw gateway (observational)" WARN "unavailable" "canonical local execution remains independent"
fi

if command -v openclaw >/dev/null 2>&1 && timeout 20 openclaw agent --help 2>/dev/null | grep -Fq -- '--local'; then
  add_check openclaw_local critical "OpenClaw explicit local mode" PASS "supported" "GF-H03 canonical mode"
else
  add_check openclaw_local critical "OpenClaw explicit local mode" FAIL "" "installed OpenClaw must support agent --local"
fi

if command -v openclaw >/dev/null 2>&1 &&
   timeout 20 openclaw config get agents.list 2>/dev/null | jq -e \
     '.[] | select(.id=="game-foundry" and .models[.model].agentRuntime.id=="codex")' >/dev/null; then
  add_check game_foundry_agent critical "Game Foundry Codex agent policy" PASS "stable configuration" ""
else
  add_check game_foundry_agent critical "Game Foundry Codex agent policy" FAIL "" "stable game-foundry agent must declare agentRuntime.id=codex"
fi

codex_version=""
if command -v openclaw >/dev/null 2>&1; then
  codex_info=$(timeout 20 openclaw plugins inspect codex 2>/dev/null) || codex_info=""
  codex_version=$(sed -n 's/^Version: //p' <<<"$codex_info" | head -n 1)
  if [[ $codex_info == *"Status: loaded"* ]]; then
    add_check codex_harness critical "Codex harness" PASS "$codex_version" ""
  else
    add_check codex_harness critical "Codex harness" FAIL "$codex_version" "run: openclaw plugins install @openclaw/codex"
  fi
else
  add_check codex_harness critical "Codex harness" FAIL "" "OpenClaw unavailable"
fi

if command -v openclaw >/dev/null 2>&1; then
  model_status=$(timeout 20 openclaw models status 2>/dev/null || true)
  if [[ $model_status == *"openai via codex"* && $model_status != *"effective=missing"* ]]; then
    add_check openai_auth critical "OpenAI/Codex authentication" PASS "configured" ""
  else
    add_check openai_auth critical "OpenAI/Codex authentication" FAIL "" "run: openclaw models auth login --provider openai"
  fi
else
  add_check openai_auth critical "OpenAI/Codex authentication" FAIL "" "OpenClaw unavailable"
fi

godot_version=""
if command -v "$godot_bin" >/dev/null 2>&1; then godot_version=$("$godot_bin" --version 2>/dev/null); fi
if [[ $godot_version == 4.7.2.stable.* && $godot_version != *mono* ]]; then
  add_check godot critical "Godot 4.7.2 Standard" PASS "$godot_version" ""
else
  add_check godot critical "Godot 4.7.2 Standard" FAIL "$godot_version" "install Godot 4.7.2 Standard x86_64"
fi

headless_version=""
if command -v "$godot_bin" >/dev/null 2>&1; then headless_version=$(timeout 20 "$godot_bin" --headless --version 2>/dev/null) || headless_version=""; fi
[[ $headless_version == 4.7.2.stable.* ]] && add_check godot_headless critical "Godot headless" PASS "$headless_version" "" || add_check godot_headless critical "Godot headless" FAIL "$headless_version" "headless version check failed"

templates_dir="${XDG_DATA_HOME:-/home/${USER}/.local/share}/godot/export_templates/4.7.2.stable"
fallback_templates_dir="/home/${USER}/.local/share/godot/export_templates/4.7.2.stable"
if [[ ! -f $templates_dir/version.txt || ! -f $templates_dir/linux_release.x86_64 ]]; then
  templates_dir=$fallback_templates_dir
fi
if [[ -f $templates_dir/version.txt && -f $templates_dir/linux_release.x86_64 ]]; then
  add_check export_templates critical "Godot export templates" PASS "4.7.2 Standard" "$templates_dir"
else
  add_check export_templates critical "Godot export templates" FAIL "" "install Godot_v4.7.2-stable_export_templates.tpz into $templates_dir"
fi

smoke_output=""
if command -v "$godot_bin" >/dev/null 2>&1; then smoke_output=$(timeout 30 "$godot_bin" --headless --path "$repo_root/fixtures/godot-smoke" --script smoke.gd 2>&1) || smoke_code=$?; else smoke_code=127; fi
smoke_code=${smoke_code:-0}
if [[ $smoke_code -eq 0 && $smoke_output == *"$marker"* ]]; then
  add_check godot_smoke critical "Godot smoke fixture" PASS "$marker" ""
else
  add_check godot_smoke critical "Godot smoke fixture" FAIL "" "project load, parse, execution, or marker check failed"
fi

if git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 && [[ $(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null) == "$repo_root" ]]; then
  add_check local_git critical "Local Git repository" PASS "$(git -C "$repo_root" branch --show-current 2>/dev/null)" ""
else
  add_check local_git critical "Local Git repository" FAIL "" "run: git init $repo_root"
fi

remote_url=$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)
if [[ $remote_url == *"github.com/blanzy-labs/game-foundry"* ]]; then
  add_check github_remote critical "GitHub remote" PASS "$remote_url" ""
else
  add_check github_remote critical "GitHub remote" FAIL "$remote_url" "create blanzy-labs/game-foundry and configure origin"
fi

ollama_state=not_installed
ollama_version=""
ollama_models=0
if command -v ollama >/dev/null 2>&1; then
  ollama_version=$(ollama --version 2>/dev/null | head -n 1)
  if timeout 5 curl -fsS http://localhost:11434/api/version >/dev/null 2>&1; then
    ollama_models=$(timeout 10 ollama list 2>/dev/null | tail -n +2 | sed '/^[[:space:]]*$/d' | wc -l)
    if (( ollama_models > 0 )); then ollama_state=ready; else ollama_state=available_no_models; fi
  else
    ollama_state=error
  fi
fi
case $ollama_state in
  ready) add_check ollama optional Ollama PASS "$ollama_version" "$ollama_models models" ;;
  available_no_models) add_check ollama optional Ollama WARN "$ollama_version" "AVAILABLE_NO_MODELS" ;;
  not_installed) add_check ollama optional Ollama SKIP "" "NOT_INSTALLED" ;;
  *) add_check ollama optional Ollama WARN "$ollama_version" "ERROR" ;;
esac

overall=ready
(( critical_failed > 0 )) && overall=blocked

if $json_mode; then
  checks_json='[]'
  for i in "${!ids[@]}"; do
    check=$(jq -n --arg id "${ids[$i]}" --arg group "${groups[$i]}" --arg label "${labels[$i]}" --arg status "${statuses[$i],,}" --arg version "${versions[$i]}" --arg detail "${details[$i]}" '{id:$id,group:$group,label:$label,status:$status,version:$version,detail:$detail}')
    checks_json=$(jq --argjson check "$check" '. + [$check]' <<<"$checks_json")
  done
  jq -n --arg status "$overall" --arg timestamp "$timestamp" --arg ollama "$ollama_state" --arg godot "$godot_version" --arg openclaw "${openclaw_version:-}" --arg codex "$codex_version" --argjson passed "$critical_passed" --argjson failed "$critical_failed" --argjson models "$ollama_models" --argjson checks "$checks_json" '{status:$status,timestamp:$timestamp,critical:{passed:$passed,failed:$failed},optional:{ollama:$ollama,ollama_models:$models},tools:{godot:{status:(if $godot|startswith("4.7.2.stable") then "pass" else "fail" end),version:$godot},openclaw:{status:(if $openclaw=="" then "fail" else "pass" end),version:$openclaw},codex_harness:{version:$codex}},checks:$checks}'
else
  printf 'GAME FOUNDRY DOCTOR\n===================\n\n'
  for i in "${!ids[@]}"; do
    printf '  %-34s %s' "${labels[$i]}" "${statuses[$i]}"
    [[ -n ${versions[$i]} ]] && printf '  %s' "${versions[$i]}"
    printf '\n'
    [[ ${statuses[$i]} != PASS && -n ${details[$i]} ]] && printf '    %s\n' "${details[$i]}"
  done
  printf '\n----------------------------------------\n'
  printf 'Critical checks: %s PASS, %s FAIL\n' "$critical_passed" "$critical_failed"
  printf 'Optional Ollama: %s (%s models)\n\n' "${ollama_state^^}" "$ollama_models"
  printf 'GAME FOUNDRY STATUS: %s\n' "${overall^^}"
fi

(( critical_failed == 0 ))
