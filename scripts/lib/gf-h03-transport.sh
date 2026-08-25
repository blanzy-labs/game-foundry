#!/usr/bin/env bash

# GF-H03 canonical OpenClaw transport.  OpenClaw remains the orchestrator and
# its explicitly supported embedded mode runs the configured Codex harness.
readonly GFH03_CANONICAL_MODE=explicit_local_openclaw_codex
readonly GFH03_MAX_TRANSPORT_ATTEMPTS=2
readonly GFH03_PREFLIGHT_TIMEOUT=20
readonly GFH03_PREFLIGHT_RETRIES=2
readonly GFH03_STARTUP_TIMEOUT=30
readonly GFH03_AGENT_TIMEOUT=1800
readonly GFH03_OUTER_TIMEOUT=1830
readonly GFH03_RECONCILE_TIMEOUT=30

gfh03_sessions_file() {
  printf '%s/.openclaw/agents/%s/sessions/sessions.json\n' "${HOME:?}" "$1"
}

gfh03_configured_workspace() {
  local agent_id=$1
  openclaw config get agents.list 2>/dev/null | jq -er --arg id "$agent_id" '.[] | select(.id==$id) | .workspace'
}

gfh03_session_start_proven() {
  local sessions=$1 key=${2,,}
  [[ -f $sessions ]] || return 1
  jq -e --arg key "$key" '.[$key].agentHarnessId == "codex"' "$sessions" >/dev/null 2>&1
}

gfh03_session_exists() {
  local sessions=$1 key=${2,,}
  [[ -f $sessions ]] && jq -e --arg key "$key" 'has($key)' "$sessions" >/dev/null 2>&1
}

gfh03_session_state() {
  local sessions=$1 key=${2,,}
  if [[ ! -r $sessions ]] || ! jq -e 'type=="object"' "$sessions" >/dev/null 2>&1; then
    printf 'UNAVAILABLE\n'
  elif jq -e --arg key "$key" 'has($key)' "$sessions" >/dev/null 2>&1; then
    printf 'PRESENT\n'
  else
    printf 'ABSENT\n'
  fi
}

gfh03_workspace_mutated() {
  local workspace=$1 expected_head=${2:-}
  [[ -n $(git -C "$workspace" status --porcelain=v1 --untracked-files=all 2>/dev/null) ]] && return 0
  [[ -n $expected_head ]] && [[ $(git -C "$workspace" rev-parse HEAD 2>/dev/null) != "$expected_head" ]]
}

gfh03_process_group_active() {
  pgrep -g "$1" >/dev/null 2>&1
}

gfh03_classify() {
  local start_proven=$1 mutated=$2 completion_proven=$3 result_valid=$4 process_active=${5:-false}
  if [[ $result_valid == true && $completion_proven == true ]]; then
    printf 'COMPLETED_RESULT_RECOVERABLE\n'
  elif [[ $mutated == true ]]; then
    printf 'CANDIDATE_PRESENT_RESULT_LOST\n'
  elif [[ $start_proven == true || $process_active == true ]]; then
    printf 'STARTED_NO_RESULT\n'
  elif [[ $start_proven == false && $mutated == false && $process_active == false ]]; then
    printf 'SAFE_NOT_STARTED\n'
  else
    printf 'UNRESOLVED_AMBIGUITY\n'
  fi
}

gfh03_recovery_action() {
  case "$1" in
    SAFE_NOT_STARTED) printf 'BOUNDED_NEW_TRANSPORT_GENERATION\n' ;;
    COMPLETED_RESULT_RECOVERABLE) printf 'CONTINUE_EXISTING_CANDIDATE\n' ;;
    CANDIDATE_PRESENT_RESULT_LOST) printf 'SNAPSHOT_AND_ESCALATE\n' ;;
    STARTED_NO_RESULT|UNRESOLVED_AMBIGUITY) printf 'ESCALATE_NO_RERUN\n' ;;
    *) printf 'ESCALATE_NO_RERUN\n' ;;
  esac
}

gfh03_preflight() {
  local artifact_dir=$1 agent_id=$2 model=$3 agent_workspace=$4 start_ns end_ns config sessions_file
  start_ns=$(date +%s%N)
  mkdir -p "$artifact_dir"
  sessions_file=$(gfh03_sessions_file "$agent_id")
  if ! timeout "$GFH03_PREFLIGHT_TIMEOUT" openclaw --version >"$artifact_dir/openclaw-version.txt" 2>"$artifact_dir/preflight.stderr.log" ||
     ! timeout "$GFH03_PREFLIGHT_TIMEOUT" openclaw agent --help >"$artifact_dir/openclaw-agent-help.txt" 2>>"$artifact_dir/preflight.stderr.log" ||
     ! grep -Fq -- '--local' "$artifact_dir/openclaw-agent-help.txt" ||
     ! config=$(timeout "$GFH03_PREFLIGHT_TIMEOUT" openclaw config get agents.list 2>>"$artifact_dir/preflight.stderr.log") ||
     ! jq -e --arg id "$agent_id" --arg model "$model" --arg workspace "$agent_workspace" \
       '.[] | select(.id==$id and .workspace==$workspace and .model==$model and .models[$model].agentRuntime.id=="codex")' <<<"$config" >/dev/null ||
     [[ $(gfh03_session_state "$sessions_file" '__gfh03_preflight_nonexistent__') != ABSENT ]] ||
     ! gfh03_preflight_runtime_checks "$artifact_dir" "$agent_id"; then
    end_ns=$(date +%s%N)
    jq -n --arg mode "$GFH03_CANONICAL_MODE" --arg status fail --argjson seconds "$(gf004_elapsed "$start_ns" "$end_ns")" \
      '{canonical_execution_mode:$mode,status:$status,seconds:$seconds}' >"$artifact_dir/transport-preflight.json"
    return 1
  fi
  systemctl --user is-active openclaw-gateway.service >"$artifact_dir/gateway-observational-status.txt" 2>&1 || true
  end_ns=$(date +%s%N)
  jq -n --arg mode "$GFH03_CANONICAL_MODE" --arg status pass --arg gateway_role observational_only \
    --argjson seconds "$(gf004_elapsed "$start_ns" "$end_ns")" \
    '{canonical_execution_mode:$mode,status:$status,gateway_role:$gateway_role,seconds:$seconds}' >"$artifact_dir/transport-preflight.json"
}

gfh03_preflight_runtime_checks() {
  local artifact_dir=$1 agent_id=$2 attempt plugin_ok=false model_ok=false
  for ((attempt=1; attempt<=GFH03_PREFLIGHT_RETRIES; attempt++)); do
    if timeout "$GFH03_PREFLIGHT_TIMEOUT" openclaw plugins inspect codex >"$artifact_dir/codex-plugin.txt" 2>>"$artifact_dir/preflight.stderr.log" &&
       grep -Fq 'Status: loaded' "$artifact_dir/codex-plugin.txt"; then plugin_ok=true; break; fi
  done
  $plugin_ok || return 1
  for ((attempt=1; attempt<=GFH03_PREFLIGHT_RETRIES; attempt++)); do
    if timeout "$GFH03_PREFLIGHT_TIMEOUT" openclaw models status --agent "$agent_id" --json >"$artifact_dir/model-status.json" 2>>"$artifact_dir/preflight.stderr.log" &&
       jq -e '.auth.runtimeAuthRoutes[] | select(.provider=="openai" and .runtime=="codex" and .status=="usable")' "$artifact_dir/model-status.json" >/dev/null; then model_ok=true; break; fi
  done
  $model_ok
}

gfh03_write_transport_evidence() {
  local file=$1 logical=$2 session=$3 generation=$4 preflight=$5 dispatch=$6 start=$7 completion=$8 exit_code=$9
  shift 9
  local class=$1 mutated=$2 safe=$3 action=$4 preflight_s=$5 startup_s=$6 agent_s=$7 reconcile_s=$8 total_s=$9
  jq -n --arg logical "$logical" --arg session "$session" --argjson generation "$generation" \
    --arg mode "$GFH03_CANONICAL_MODE" --arg preflight "$preflight" --arg dispatch "$dispatch" --arg class "$class" \
    --arg action "$action" --argjson started "$start" --argjson completed "$completion" --argjson exit "$exit_code" \
    --argjson mutated "$mutated" --argjson safe "$safe" --argjson attempts "$generation" \
    --argjson preflight_s "$preflight_s" --argjson startup_s "$startup_s" --argjson agent_s "$agent_s" \
    --argjson reconcile_s "$reconcile_s" --argjson total_s "$total_s" \
    '{version:1,logical_run_id:$logical,session_key:$session,transport_generation:$generation,
      canonical_execution_mode:$mode,preflight_status:$preflight,dispatch_status:$dispatch,
      agent_start_proven:$started,agent_completion_proven:$completed,openclaw_exit_code:$exit,
      failure_class:$class,workspace_mutated:$mutated,audit_available:false,safe_to_retry:$safe,
      recovery_action:$action,transport_attempt_count:$attempts,process_active_after_cli:false,gateway:{role:"observational_only",automatic_restart:false},
      fallback:{enabled:false,seconds:0},timing_seconds:{preflight:$preflight_s,dispatch_startup:$startup_s,
      agent_execution:$agent_s,reconciliation:$reconcile_s,fallback:0,total:$total_s}}' >"$file"
}
