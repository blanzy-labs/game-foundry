#!/usr/bin/env bash
set -u

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/scripts/lib/gf-001-common.sh"
godot_bin=${GODOT_BIN:-godot}
model=openai/gpt-5.6-sol
agent_id=game-foundry
allowed_file=fixtures/godot-smoke/automation_target.gd
total_start_ns=$(date +%s%N)
started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
run_stamp=$(date -u +'%Y%m%dT%H%M%SZ')
run_suffix=$(printf '%s-%s-%s\n' "$run_stamp" "$$" "$RANDOM" | sha256sum | cut -c1-6)
run_id="gf001-${run_stamp}-${run_suffix}"
mutation_token="GF001_${run_suffix^^}"
artifact_rel="artifacts/gf-001/$run_id"
artifact_dir="$repo_root/$artifact_rel"
worktree="$repo_root/tmp/gf001/$run_id/workspace"
agent_workspace="$repo_root/tmp/gf001/agent-workspace"
bootstrap_workspace="$repo_root/tmp/gf001/bootstrap-workspace"
reports_dir="$repo_root/reports/gf-001"
session_key="agent:${agent_id}:${run_id}"
base_commit=""
execution_surface=gateway-agent
warning="Installed OpenClaw stable does not expose agent exec; used supported Gateway-backed openclaw agent with a dedicated isolated workspace."

declare -A stages=(
  [preflight]=not_run [openclaw]=not_run [codex_runtime]=not_run
  [mutation]=not_run [scope]=not_run [godot_static]=not_run
  [godot_runtime]=not_run [screenshot]=not_run [export]=not_run
  [export_runtime]=not_run
)
declare -A timing=(
  [preflight]=0 [agent]=0 [godot_validation]=0 [godot_runtime]=0
  [render]=0 [export]=0 [export_runtime]=0 [total]=0
)

changed_files_json='[]'
screenshot_sha=""
screenshot_bytes=0
failure_reason=""
openclaw_exit=-1
runtime_evidence=""

mkdir -p "$artifact_dir/build" "$reports_dir" "$repo_root/tmp/gf001" "$bootstrap_workspace"

write_results() {
  local status=$1
  local completed_at total_end_ns manifest_status
  completed_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  total_end_ns=$(date +%s%N)
  timing[total]=$(gf001_elapsed_seconds "$total_start_ns" "$total_end_ns")
  manifest_status=$status

  jq -n \
    --arg slice GF-001 --arg run_id "$run_id" --arg base_commit "$base_commit" \
    --arg mutation_token "$mutation_token" --arg started_at "$started_at" \
    --arg completed_at "$completed_at" --arg status "$manifest_status" \
    --arg orchestrator openclaw --arg runtime codex --arg model "$model" \
    --arg execution_surface "$execution_surface" --arg warning "$warning" \
    --arg failure_reason "$failure_reason" --arg allowed_file "$allowed_file" \
    --arg scope_status "${stages[scope]}" \
    --arg static "${stages[godot_static]}" --arg runtime_validation "${stages[godot_runtime]}" \
    --arg export_status "${stages[export]}" --arg export_runtime "${stages[export_runtime]}" \
    --arg screenshot_status "${stages[screenshot]}" --arg screenshot_path "$artifact_rel/screenshot.png" \
    --arg screenshot_sha "$screenshot_sha" --arg build_status "${stages[export]}" \
    --arg build_path "$artifact_rel/build/game-foundry-smoke" \
    --arg runtime_evidence "$runtime_evidence" --argjson changed_files "$changed_files_json" \
    --argjson screenshot_bytes "$screenshot_bytes" --argjson openclaw_exit "$openclaw_exit" \
    --argjson preflight_seconds "${timing[preflight]}" --argjson agent_seconds "${timing[agent]}" \
    --argjson validation_seconds "${timing[godot_validation]}" --argjson runtime_seconds "${timing[godot_runtime]}" \
    --argjson render_seconds "${timing[render]}" --argjson export_seconds "${timing[export]}" \
    --argjson export_runtime_seconds "${timing[export_runtime]}" --argjson total_seconds "${timing[total]}" \
    '{slice:$slice,run_id:$run_id,base_commit:$base_commit,mutation_token:$mutation_token,started_at:$started_at,completed_at:$completed_at,status:$status,failure_reason:$failure_reason,agent:{orchestrator:$orchestrator,runtime:$runtime,model:$model,execution_surface:$execution_surface,openclaw_exit_code:$openclaw_exit,runtime_evidence:$runtime_evidence,warning:$warning},source:{allowed_scope:($scope_status=="pass"),allowed_file:$allowed_file,changed_files:$changed_files},godot:{static_validation:$static,runtime_validation:$runtime_validation,export:$export_status,export_runtime:$export_runtime},screenshot:{status:$screenshot_status,path:$screenshot_path,sha256:$screenshot_sha,bytes:$screenshot_bytes,width:640,height:360},build:{status:$build_status,path:$build_path},timing_seconds:{preflight:$preflight_seconds,agent:$agent_seconds,godot_validation:$validation_seconds,godot_runtime:$runtime_seconds,render:$render_seconds,export:$export_seconds,export_runtime:$export_runtime_seconds,total:$total_seconds},human_interventions:0}' \
    >"$artifact_dir/manifest.json"

  jq -n --arg status "$status" --arg run_id "$run_id" --arg artifact_dir "$artifact_rel" \
    --arg preflight "${stages[preflight]}" --arg openclaw "${stages[openclaw]}" \
    --arg codex_runtime "${stages[codex_runtime]}" --arg mutation "${stages[mutation]}" \
    --arg scope "${stages[scope]}" --arg godot_static "${stages[godot_static]}" \
    --arg godot_runtime "${stages[godot_runtime]}" --arg screenshot "${stages[screenshot]}" \
    --arg export_status "${stages[export]}" --arg export_runtime "${stages[export_runtime]}" \
    '{status:$status,slice:"GF-001",run_id:$run_id,stages:{preflight:$preflight,openclaw:$openclaw,codex_runtime:$codex_runtime,mutation:$mutation,scope:$scope,godot_static:$godot_static,godot_runtime:$godot_runtime,screenshot:$screenshot,export:$export_status,export_runtime:$export_runtime},artifact_dir:$artifact_dir}' \
    >"$reports_dir/latest.json"

  {
    printf 'GAME FOUNDRY — GF-001 ACCEPTANCE\n================================\n\n'
    printf 'Run .................... %s\n' "$run_id"
    printf 'Base commit ............ %s\n' "$base_commit"
    printf 'Mutation token ......... %s\n\n' "$mutation_token"
    printf 'Orchestration\n  OpenClaw ............. %s\n  Codex runtime ........ %s\n  Agent task ........... %s\n  Scope enforcement .... %s\n\n' "${stages[openclaw]^^}" "${stages[codex_runtime]^^}" "${stages[mutation]^^}" "${stages[scope]^^}"
    printf 'Godot\n  Static validation .... %s\n  Runtime .............. %s\n  Expected token ....... %s\n\n' "${stages[godot_static]^^}" "${stages[godot_runtime]^^}" "${stages[godot_runtime]^^}"
    printf 'Visual\n  Screenshot ........... %s\n  Resolution ........... 640x360\n  SHA-256 .............. %s\n\n' "${stages[screenshot]^^}" "${screenshot_sha:-unavailable}"
    printf 'Build\n  Linux export ......... %s\n  Exported runtime ..... %s\n\n' "${stages[export]^^}" "${stages[export_runtime]^^}"
    printf 'Artifacts\n  Screenshot ........... %s/screenshot.png\n  Linux build .......... %s/build/game-foundry-smoke\n  Manifest ............. %s/manifest.json\n\n' "$artifact_rel" "$artifact_rel" "$artifact_rel"
    [[ -n $failure_reason ]] && printf 'Failure: %s\n\n' "$failure_reason"
    printf 'Pipeline status:\n\nGF-001 %s\n' "${status^^}"
  } | tee "$reports_dir/latest.txt"
}

fail_stage() {
  local stage=$1 reason=$2
  stages[$stage]=fail
  failure_reason=$reason
  printf 'FAIL [%s]: %s\n' "$stage" "$reason" >&2
  write_results fail
  exit 1
}

printf 'GF-001 run: %s\nMutation token: %s\n' "$run_id" "$mutation_token"

phase_start=$(date +%s%N)
base_commit=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null) || fail_stage preflight 'could not resolve base commit'
primary_status=$(git -C "$repo_root" status --short)
[[ -z $primary_status ]] || fail_stage preflight 'primary checkout is not clean'
"$repo_root/scripts/doctor.sh" --json >"$artifact_dir/preflight.json" || fail_stage preflight 'GF-000 doctor failed'
jq -e '.status == "ready" and .critical.failed == 0' "$artifact_dir/preflight.json" >/dev/null || fail_stage preflight 'GF-000 is not ready'
command -v Xvfb >/dev/null 2>&1 || fail_stage preflight 'Xvfb is required for rendered screenshot capture'
command -v file >/dev/null 2>&1 || fail_stage preflight 'file is required for PNG validation'
stages[preflight]=pass
timing[preflight]=$(gf001_elapsed_seconds "$phase_start" "$(date +%s%N)")

git -C "$repo_root" worktree add --detach "$worktree" "$base_commit" >"$artifact_dir/worktree.log" 2>&1 || fail_stage preflight 'could not create isolated worktree'
ln -sfn "$worktree" "$agent_workspace"

cat >"$artifact_dir/task.md" <<EOF
# GF-001 scoped mutation task

You are operating inside an isolated Git worktree for Game Foundry acceptance run \`$run_id\`.

Update the Godot smoke fixture automation token to exactly \`$mutation_token\`.

Allowed mutation target only:

\`fixtures/godot-smoke/automation_target.gd\`

Requirements:

- Inspect the existing target before changing it.
- Make only the minimum source change needed: replace \`GF001_INITIAL\` with \`$mutation_token\`.
- Do not modify any other file.
- Do not install packages or change system, Git, GitHub, OpenClaw, Codex, or credential configuration.
- Do not commit, push, publish, or delete external resources.
- Run an appropriate local validation of the Godot fixture.
- Report the exact file changed and validation result.

The acceptance harness already exists. Do not modify or implement the harness.
EOF

if ! openclaw agents list --json | jq -e --arg id "$agent_id" '.[] | select(.id == $id)' >/dev/null; then
  openclaw agents add "$agent_id" --workspace "$agent_workspace" --model "$model" --non-interactive --json >"$artifact_dir/agent-create.json" 2>"$artifact_dir/agent-create.stderr.log" || fail_stage openclaw 'could not create dedicated agent'
fi
agents_config=$(openclaw config get agents.list) || fail_stage codex_runtime 'could not read agent config'
agent_index=$(jq -r --arg id "$agent_id" 'to_entries[] | select(.value.id == $id) | .key' <<<"$agents_config")
[[ -n $agent_index ]] || fail_stage codex_runtime 'dedicated agent not found in config'
openclaw config set "agents.list[$agent_index].workspace" "$agent_workspace" >/dev/null || fail_stage codex_runtime 'could not set dedicated workspace'
openclaw config set "agents.list[$agent_index].model" "$model" >/dev/null || fail_stage codex_runtime 'could not set requested model'
openclaw config set "agents.list[$agent_index].models[\"$model\"].agentRuntime.id" codex >/dev/null || fail_stage codex_runtime 'could not set Codex runtime policy'
openclaw config get "agents.list[$agent_index]" >"$artifact_dir/runtime-policy.json" || fail_stage codex_runtime 'could not capture runtime policy'
jq -e --arg model "$model" '.model == $model and .models[$model].agentRuntime.id == "codex"' "$artifact_dir/runtime-policy.json" >/dev/null || fail_stage codex_runtime 'runtime policy is not fail-closed to Codex'
openclaw plugins inspect codex >"$artifact_dir/codex-plugin.txt" 2>&1 || fail_stage codex_runtime 'Codex plugin not recognized'
grep -Fq 'Status: loaded' "$artifact_dir/codex-plugin.txt" || fail_stage codex_runtime 'Codex plugin not loaded'
openclaw models status --agent "$agent_id" --json >"$artifact_dir/model-status.json" 2>/dev/null || fail_stage codex_runtime 'could not inspect dedicated agent auth'
jq -e '.auth.runtimeAuthRoutes[] | select(.provider == "openai" and .runtime == "codex" and .status == "usable")' "$artifact_dir/model-status.json" >/dev/null || fail_stage codex_runtime 'Codex runtime authentication is not usable'

phase_start=$(date +%s%N)
set +e
timeout 900 openclaw agent --agent "$agent_id" --session-key "$session_key" --model "$model" --thinking medium --message-file "$artifact_dir/task.md" --timeout 840 --json >"$artifact_dir/openclaw.stdout.log" 2>"$artifact_dir/openclaw.stderr.log"
openclaw_exit=$?
set -e
timing[agent]=$(gf001_elapsed_seconds "$phase_start" "$(date +%s%N)")
[[ $openclaw_exit -eq 0 ]] || fail_stage openclaw "OpenClaw exited $openclaw_exit"
jq -e . "$artifact_dir/openclaw.stdout.log" >/dev/null || fail_stage openclaw 'OpenClaw output is not valid JSON'
cp "$artifact_dir/openclaw.stdout.log" "$artifact_dir/openclaw-result.json"
stages[openclaw]=pass

openclaw audit --session "$session_key" --kind agent_run --limit 20 --json >"$artifact_dir/openclaw-audit.json" 2>"$artifact_dir/openclaw-audit.stderr.log" || true
journalctl --user -u openclaw-gateway.service --since "$started_at" --no-pager >"$artifact_dir/openclaw-gateway.log" 2>&1 || true
if jq -e '.. | objects | select((.agentRuntime? == "codex") or (.runtime? == "codex") or (.runtimeId? == "codex") or (.agentHarnessId? == "codex"))' "$artifact_dir/openclaw-result.json" "$artifact_dir/openclaw-audit.json" >/dev/null 2>&1; then
  runtime_evidence='OpenClaw result/audit recorded agentHarnessId/runtime=codex'
elif grep -Eqi 'codex.*(app-server|harness|runtime)|(app-server|harness|runtime).*codex' "$artifact_dir/openclaw-gateway.log"; then
  runtime_evidence='OpenClaw gateway log recorded Codex harness/app-server execution'
else
  fail_stage codex_runtime 'actual Codex runtime selection was not present in OpenClaw evidence'
fi
stages[codex_runtime]=pass

git -C "$worktree" diff --binary >"$artifact_dir/agent.patch"
mapfile -t changed_files < <(git -C "$worktree" status --porcelain=v1 | sed -E 's/^.. //' | sed -E 's/.* -> //')
changed_files_json=$(printf '%s\n' "${changed_files[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
gf001_verify_scope "$worktree" "$allowed_file" || fail_stage scope 'agent changed files outside the allowlist or did not change the target'
stages[scope]=pass
grep -Fq "AUTOMATION_TOKEN := \"$mutation_token\"" "$worktree/$allowed_file" || fail_stage mutation 'expected token is absent from mutation target'
grep -Fq 'GF001_INITIAL' "$worktree/$allowed_file" && fail_stage mutation 'initial token remains in mutation target'
stages[mutation]=pass

phase_start=$(date +%s%N)
timeout 60 "$godot_bin" --headless --path "$worktree/fixtures/godot-smoke" --editor --quit-after 3 >"$artifact_dir/godot-import.log" 2>&1 || fail_stage godot_static 'Godot import/load failed'
timeout 30 "$godot_bin" --headless --path "$worktree/fixtures/godot-smoke" --script validate.gd -- --expected-token="$mutation_token" >"$artifact_dir/godot-validation.log" 2>&1 || fail_stage godot_static 'Godot static validation failed'
gf001_require_marker "$artifact_dir/godot-validation.log" GAME_FOUNDRY_STATIC_OK || fail_stage godot_static 'static success marker missing'
gf001_require_marker "$artifact_dir/godot-validation.log" "GAME_FOUNDRY_TOKEN=$mutation_token" || fail_stage godot_static 'static token marker missing'
stages[godot_static]=pass
timing[godot_validation]=$(gf001_elapsed_seconds "$phase_start" "$(date +%s%N)")

phase_start=$(date +%s%N)
timeout 30 "$godot_bin" --headless --path "$worktree/fixtures/godot-smoke" -- --runtime-test >"$artifact_dir/godot-runtime.log" 2>&1 || fail_stage godot_runtime 'Godot runtime failed'
gf001_require_marker "$artifact_dir/godot-runtime.log" GAME_FOUNDRY_RUNTIME_OK || fail_stage godot_runtime 'runtime success marker missing'
gf001_require_marker "$artifact_dir/godot-runtime.log" "GAME_FOUNDRY_TOKEN=$mutation_token" || fail_stage godot_runtime 'runtime token marker missing'
stages[godot_runtime]=pass
timing[godot_runtime]=$(gf001_elapsed_seconds "$phase_start" "$(date +%s%N)")

phase_start=$(date +%s%N)
timeout 60 xvfb-run -a -s '-screen 0 640x360x24' "$godot_bin" --display-driver x11 --path "$worktree/fixtures/godot-smoke" --resolution 640x360 -- --screenshot="$artifact_dir/screenshot.png" >"$artifact_dir/godot-screenshot.log" 2>&1 || fail_stage screenshot 'rendered screenshot command failed'
gf001_require_marker "$artifact_dir/godot-screenshot.log" "GAME_FOUNDRY_TOKEN=$mutation_token" || fail_stage screenshot 'screenshot run token marker missing'
gf001_validate_png "$artifact_dir/screenshot.png" 640 360 || fail_stage screenshot 'PNG validation failed'
screenshot_sha=$(sha256sum "$artifact_dir/screenshot.png" | cut -d' ' -f1)
screenshot_bytes=$(wc -c <"$artifact_dir/screenshot.png")
stages[screenshot]=pass
timing[render]=$(gf001_elapsed_seconds "$phase_start" "$(date +%s%N)")

phase_start=$(date +%s%N)
timeout 120 "$godot_bin" --headless --path "$worktree/fixtures/godot-smoke" --export-release 'Linux x86_64' "$artifact_dir/build/game-foundry-smoke" >"$artifact_dir/export.log" 2>&1 || fail_stage export 'Linux export failed'
[[ -x $artifact_dir/build/game-foundry-smoke ]] || fail_stage export 'exported executable is missing'
file "$artifact_dir/build/game-foundry-smoke" >"$artifact_dir/build-file.txt"
grep -Fq 'ELF 64-bit' "$artifact_dir/build-file.txt" || fail_stage export 'export is not an ELF 64-bit executable'
stages[export]=pass
timing[export]=$(gf001_elapsed_seconds "$phase_start" "$(date +%s%N)")

phase_start=$(date +%s%N)
timeout 30 "$artifact_dir/build/game-foundry-smoke" --headless -- --export-self-test >"$artifact_dir/exported-runtime.log" 2>&1 || fail_stage export_runtime 'exported executable failed'
gf001_require_marker "$artifact_dir/exported-runtime.log" GAME_FOUNDRY_EXPORT_RUNTIME_OK || fail_stage export_runtime 'export runtime success marker missing'
gf001_require_marker "$artifact_dir/exported-runtime.log" "GAME_FOUNDRY_TOKEN=$mutation_token" || fail_stage export_runtime 'export runtime token marker missing'
stages[export_runtime]=pass
timing[export_runtime]=$(gf001_elapsed_seconds "$phase_start" "$(date +%s%N)")

write_results pass
ln -sfn "$bootstrap_workspace" "$agent_workspace"
git -C "$repo_root" worktree remove --force "$worktree" >>"$artifact_dir/worktree.log" 2>&1 || {
  printf 'WARN: successful worktree cleanup failed: %s\n' "$worktree" >&2
  exit 1
}
printf '\nGF-001 PASS: %s\n' "$run_id"
