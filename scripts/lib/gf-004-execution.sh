#!/usr/bin/env bash

gf004_elapsed() {
  awk -v start="$1" -v end="$2" 'BEGIN { printf "%.6f", (end-start)/1000000000 }'
}

gf004_changed_files() {
  git -C "$1" status --porcelain=v1 --untracked-files=all | sed -E 's/^.. //' | sed -E 's/.* -> //' | LC_ALL=C sort -u
}

gf004_matches_scope() {
  local path=$1 pattern
  for pattern in "${GF004_SCOPE_PATTERNS[@]}"; do
    if [[ $path == $pattern ]]; then return 0; fi
  done
  return 1
}

gf004_verify_scope() {
  local workspace=$1 path resolved
  GF004_SCOPE_REASON=''
  ((${#GF004_CHANGED_FILES[@]} > 0)) || { GF004_SCOPE_REASON='no source mutation'; return 1; }
  for path in "${GF004_CHANGED_FILES[@]}"; do
    [[ -n $path && $path != /* && $path != *'..'* ]] || { GF004_SCOPE_REASON="unsafe changed path: $path"; return 1; }
    gf004_matches_scope "$path" || { GF004_SCOPE_REASON="outside allowed scope: $path"; return 1; }
    if [[ -L $workspace/$path ]]; then
      resolved=$(realpath "$workspace/$path" 2>/dev/null) || { GF004_SCOPE_REASON="broken changed symlink: $path"; return 1; }
      [[ $resolved == "$workspace/"* ]] || { GF004_SCOPE_REASON="symlink escape: $path"; return 1; }
    fi
  done
}

gf004_runtime_is_proven() {
  local artifact_dir=$1
  jq -e '.. | objects | select((.agentRuntime? == "codex") or (.runtime? == "codex") or (.runtimeId? == "codex") or (.agentHarnessId? == "codex"))' \
    "$artifact_dir/openclaw-result.json" "$artifact_dir/openclaw-audit.json" >/dev/null 2>&1 && return 0
  grep -Eqi 'codex.*(app-server|harness|runtime)|(app-server|harness|runtime).*codex' "$artifact_dir/openclaw-gateway.log" 2>/dev/null
}

gf004_real_agent() {
  local workspace=$1 prompt=$2 artifact_dir=$3 run_id=$4
  local model=${GF_EXECUTION_MODEL:-openai/gpt-5.6-sol}
  local agent_id=${GF_EXECUTION_AGENT_ID:-game-foundry-executor}
  local session_key="agent:${agent_id}:${run_id}" agents_config agent_index started_at
  started_at=$(gf_now)
  if ! openclaw agents list --json | jq -e --arg id "$agent_id" '.[] | select(.id == $id)' >/dev/null; then
    openclaw agents add "$agent_id" --workspace "$workspace" --model "$model" --non-interactive --json \
      >"$artifact_dir/agent-create.json" 2>"$artifact_dir/agent-create.stderr.log" || return 1
  fi
  agents_config=$(openclaw config get agents.list) || return 1
  agent_index=$(jq -r --arg id "$agent_id" 'to_entries[] | select(.value.id == $id) | .key' <<<"$agents_config")
  [[ -n $agent_index ]] || return 1
  openclaw config set "agents.list[$agent_index].workspace" "$workspace" >/dev/null || return 1
  openclaw config set "agents.list[$agent_index].model" "$model" >/dev/null || return 1
  openclaw config set "agents.list[$agent_index].models[\"$model\"].agentRuntime.id" codex >/dev/null || return 1
  openclaw config get "agents.list[$agent_index]" >"$artifact_dir/runtime-policy.json" || return 1
  jq -e --arg model "$model" '.model == $model and .models[$model].agentRuntime.id == "codex"' "$artifact_dir/runtime-policy.json" >/dev/null || return 1
  openclaw plugins inspect codex >"$artifact_dir/codex-plugin.txt" 2>&1 || return 1
  grep -Fq 'Status: loaded' "$artifact_dir/codex-plugin.txt" || return 1
  openclaw models status --agent "$agent_id" --json >"$artifact_dir/model-status.json" 2>"$artifact_dir/model-status.stderr.log" || return 1
  jq -e '.auth.runtimeAuthRoutes[] | select(.provider == "openai" and .runtime == "codex" and .status == "usable")' "$artifact_dir/model-status.json" >/dev/null || return 1
  timeout 900 openclaw agent --agent "$agent_id" --session-key "$session_key" --model "$model" --thinking medium \
    --message-file "$prompt" --timeout 840 --json >"$artifact_dir/openclaw.stdout.log" 2>"$artifact_dir/openclaw.stderr.log"
  GF004_OPENCLAW_EXIT=$?
  [[ $GF004_OPENCLAW_EXIT -eq 0 ]] || return 1
  jq -e . "$artifact_dir/openclaw.stdout.log" >/dev/null || return 1
  cp "$artifact_dir/openclaw.stdout.log" "$artifact_dir/openclaw-result.json"
  openclaw audit --session "$session_key" --kind agent_run --limit 20 --json >"$artifact_dir/openclaw-audit.json" 2>"$artifact_dir/openclaw-audit.stderr.log" || printf '[]\n' >"$artifact_dir/openclaw-audit.json"
  journalctl --user -u openclaw-gateway.service --since "$started_at" --no-pager >"$artifact_dir/openclaw-gateway.log" 2>&1 || :
  return 0
}

gf004_test_agent() {
  local workspace=$1 artifact_dir=$2 fault=$3
  GF004_OPENCLAW_EXIT=0
  printf '{"test_hook":true,"status":"ok","agentHarnessId":"codex"}\n' >"$artifact_dir/openclaw.stdout.log"
  cp "$artifact_dir/openclaw.stdout.log" "$artifact_dir/openclaw-result.json"
  printf '[]\n' >"$artifact_dir/openclaw-audit.json"
  : >"$artifact_dir/openclaw.stderr.log"
  : >"$artifact_dir/openclaw-gateway.log"
  case "$fault" in
    openclaw_failure)
      GF004_OPENCLAW_EXIT=71
      printf '{"test_hook":true,"status":"failed"}\n' >"$artifact_dir/openclaw-result.json"
      return 1
      ;;
    validation_failure)
      printf 'WRONG_MARKER\n' >"$workspace/fixtures/execution-project/src/marker.txt"
      ;;
    unauthorized_change)
      printf 'GAME_FOUNDRY_EXECUTION_MARKER_001\n' >"$workspace/fixtures/execution-project/src/marker.txt"
      printf '\nGF-004 unauthorized-change test hook\n' >>"$workspace/README.md"
      ;;
    *)
      printf 'GAME_FOUNDRY_EXECUTION_MARKER_001\n' >"$workspace/fixtures/execution-project/src/marker.txt"
      ;;
  esac
  return 0
}

gf004_emit_no_work() {
  local milestone_id=$1 next_result=$2
  if $json_output; then
    jq -n --arg milestone_id "$milestone_id" --arg result "${next_result,,}" \
      '{milestone_id:$milestone_id,result:$result,task_id:null,execution:"not_started",codex_invocations:0,source_modifications:0}'
  else
    printf 'GAME FOUNDRY — EXECUTE ONE\n==========================\n\nMilestone ............ %s\nResult ................ %s\nExecution ............. NOT STARTED\nCodex invocations .... 0\n' "$milestone_id" "$next_result"
  fi
}

gf004_write_result() {
  local file=$1 result=$2 reason=$3 next_task=$4
  local changed_json markers_json
  changed_json=$(printf '%s\n' "${GF004_CHANGED_FILES[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0))')
  markers_json=$(printf '%s\n' "${GF004_MARKERS[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0))')
  jq -n \
    --arg milestone_id "$GF004_MILESTONE" --arg task_id "$GF004_TASK" --arg run_id "$GF004_RUN_ID" --arg result "$result" --arg reason "$reason" \
    --arg runtime_status "$GF004_RUNTIME_STATUS" --arg runtime_evidence "$GF004_RUNTIME_EVIDENCE" --arg scope_status "$GF004_SCOPE_STATUS" \
    --arg validator_status "$GF004_VALIDATOR_STATUS" --arg validator_path "$GF004_VALIDATOR_REL" --arg validator_pre "$GF004_VALIDATOR_PRE" --arg validator_post "$GF004_VALIDATOR_POST" \
    --arg pre_commit "$GF004_PRE_COMMIT" --arg accepted_commit "$GF004_ACCEPTED_COMMIT" --arg execution_branch "$GF004_EXECUTION_BRANCH" --arg next_task "$next_task" \
    --arg evidence "$GF004_ARTIFACT_REL" --argjson attempt "$GF004_ATTEMPT" --argjson max_attempts "$GF004_MAX_ATTEMPTS" \
    --argjson openclaw_exit "$GF004_OPENCLAW_EXIT" --argjson validation_exit "$GF004_VALIDATION_EXIT" --argjson changed_files "$changed_json" --argjson markers "$markers_json" \
    --argjson codex_invocations "$GF004_CODEX_INVOCATIONS" --argjson selection "$GF004_T_SELECTION" --argjson prompt "$GF004_T_PROMPT" \
    --argjson agent "$GF004_T_AGENT" --argjson scope "$GF004_T_SCOPE" --argjson validation "$GF004_T_VALIDATION" --argjson commit "$GF004_T_COMMIT" \
    --argjson state "$GF004_T_STATE" --argjson cleanup "$GF004_T_CLEANUP" --argjson total "$GF004_T_TOTAL" \
    '{milestone_id:$milestone_id,task_id:$task_id,run_id:$run_id,attempt:$attempt,max_attempts:$max_attempts,result:$result,failure_reason:$reason,
      agent:{orchestrator:"openclaw",runtime:"codex",exit_code:$openclaw_exit,runtime_status:$runtime_status,runtime_evidence:$runtime_evidence},
      source:{base_commit:$pre_commit,accepted_commit:(if $accepted_commit=="" then null else $accepted_commit end),execution_branch:$execution_branch,changed_files:$changed_files,scope:$scope_status},
      validation:{status:$validator_status,path:$validator_path,pre_sha256:$validator_pre,post_sha256:$validator_post,exit_code:$validation_exit,success_markers:$markers},
      state:{task:$result,next_task:(if $next_task=="" then null else $next_task end)},evidence_path:$evidence,codex_invocations:$codex_invocations,human_interventions:0,
      timing_seconds:{task_selection:$selection,prompt_render:$prompt,openclaw_codex:$agent,scope_validation:$scope,deterministic_validation:$validation,commit:$commit,state_update:$state,cleanup:$cleanup,total:$total}}' >"$file"
}

gf004_fail_execution() {
  local reason=$1
  local cleanup_start next_result
  cleanup_start=$(date +%s%N)
  if [[ -d $GF004_WORKSPACE ]]; then
    git -C "$GF004_REPO" worktree remove --force "$GF004_WORKSPACE" >>"$GF004_ARTIFACT_DIR/worktree.log" 2>&1 || true
  fi
  GF004_T_CLEANUP=$(gf004_elapsed "$cleanup_start" "$(date +%s%N)")
  gf_transition_task "$GF004_MILESTONE" "$GF004_TASK" fail execution_failure || true
  gf_atomic_state_update "$GF004_STATE_FILE" '.tasks[$task] += {last_run_id:$run,last_result:"fail",last_evidence:$evidence,failure_reason:$reason}' \
    --arg task "$GF004_TASK" --arg run "$GF004_RUN_ID" --arg evidence "$GF004_ARTIFACT_REL" --arg reason "$reason" || true
  GF004_T_STATE=$(gf004_elapsed "$GF004_STATE_START" "$(date +%s%N)")
  next_result=$(gf_next_result "$GF004_MILESTONE")
  GF004_T_TOTAL=$(gf004_elapsed "$GF004_TOTAL_START" "$(date +%s%N)")
  gf004_write_result "$GF004_ARTIFACT_DIR/result.json" fail "$reason" ""
  if $json_output; then cat "$GF004_ARTIFACT_DIR/result.json"; else
    printf 'GAME FOUNDRY — EXECUTE ONE\n==========================\n\nMilestone ............ %s\nTask ................. %s\nTask result .......... FAIL\nFailure .............. %s\nNext ................. %s\nCodex invocations .... %s\nEvidence ............. %s\n' "$GF004_MILESTONE" "$GF004_TASK" "$reason" "$next_result" "$GF004_CODEX_INVOCATIONS" "$GF004_ARTIFACT_REL"
  fi
  return 1
}

gf_execute_one() {
  local milestone_id=$1 state_dir next_result selection_start prompt_start agent_start scope_start validation_start commit_start cleanup_start
  local task_file validator_abs validator_real timeout_seconds marker changed state_backup next_after test_fault=''
  GF004_TOTAL_START=$(date +%s%N)
  GF004_MILESTONE=$milestone_id
  state_dir=$(gf_state_dir "$milestone_id")
  GF004_STATE_FILE="$state_dir/state.json"
  [[ -f $GF004_STATE_FILE ]] || { gf_error "MILESTONE STATE MISSING: $milestone_id"; return 1; }
  mkdir -p "$state_dir"
  exec 8>"$state_dir/.execution.lock"
  flock -n 8 || { gf_error 'EXECUTION BUSY'; return 1; }
  lock_state "$milestone_id"
  gf_verify_lock "$milestone_id" || { gf_error 'EXECUTION REFUSED'; return 1; }
  $GF_EXECUTABLE || { gf_error 'EXECUTION REFUSED: milestone tasks have no deterministic validation contract'; return 1; }
  jq -e '.source | type == "object"' "$GF004_STATE_FILE" >/dev/null || { gf_error 'EXECUTION REFUSED: source state missing'; return 1; }
  GF004_REPO=$(jq -r '.source.git_root' "$GF004_STATE_FILE")
  GF004_PRE_COMMIT=$(jq -r '.source.head_commit' "$GF004_STATE_FILE")
  GF004_EXECUTION_BRANCH=$(jq -r '.source.execution_branch' "$GF004_STATE_FILE")
  [[ $(git -C "$GF004_REPO" rev-parse "refs/heads/$GF004_EXECUTION_BRANCH" 2>/dev/null) == "$GF004_PRE_COMMIT" ]] || { gf_error 'EXECUTION REFUSED: expected source HEAD mismatch'; return 1; }
  [[ -z $(git -C "$GF004_REPO" status --short) ]] || { gf_error 'EXECUTION REFUSED: source repository is not clean'; return 1; }
  if jq -e '[.tasks[] | select(.status == "running")] | length > 0' "$GF004_STATE_FILE" >/dev/null; then
    gf_error 'RECOVERY REQUIRED: milestone contains a stale RUNNING task'
    return 1
  fi
  gf_recalculate "$milestone_id" || return 1
  selection_start=$(date +%s%N)
  next_result=$(gf_next_result "$milestone_id")
  GF004_T_SELECTION=$(gf004_elapsed "$selection_start" "$(date +%s%N)")
  [[ $next_result == NEXT_TASK=* ]] || { gf004_emit_no_work "$milestone_id" "$next_result"; return 0; }
  GF004_TASK=${next_result#NEXT_TASK=}
  task_file=${GF_TASK_FILES[$GF004_TASK]}
  jq -e 'has("validation")' "$task_file" >/dev/null || { gf_error 'EXECUTION REFUSED: selected task lacks validation'; return 1; }
  GF004_ATTEMPT=$(( $(jq -r --arg task "$GF004_TASK" '.tasks[$task].attempts' "$GF004_STATE_FILE") + 1 ))
  GF004_MAX_ATTEMPTS=${GF_TASK_MAX_ATTEMPTS[$GF004_TASK]}
  GF004_RUN_ID="gf004-$(date -u +'%Y%m%dT%H%M%SZ')-$(printf '%s-%s-%s' "$milestone_id" "$$" "$RANDOM" | sha256sum | cut -c1-8)"
  GF004_ARTIFACT_DIR="$GF_EXECUTION_ARTIFACT_ROOT/$milestone_id/$GF004_TASK/$GF004_RUN_ID"
  GF004_ARTIFACT_REL=${GF004_ARTIFACT_DIR#"$GF_CONTROL_ROOT/"}
  GF004_WORKSPACE="$GF_EXECUTION_TMP_ROOT/$milestone_id/$GF004_TASK/$GF004_RUN_ID/workspace"
  mkdir -p "$GF004_ARTIFACT_DIR" "$(dirname "$GF004_WORKSPACE")"
  GF004_OPENCLAW_EXIT=-1 GF004_VALIDATION_EXIT=-1 GF004_ACCEPTED_COMMIT=''
  GF004_RUNTIME_STATUS=not_run GF004_RUNTIME_EVIDENCE='' GF004_SCOPE_STATUS=not_run GF004_VALIDATOR_STATUS=not_run
  GF004_VALIDATOR_REL=$(jq -r '.validation.path' "$task_file") GF004_VALIDATOR_PRE='' GF004_VALIDATOR_POST=''
  GF004_CODEX_INVOCATIONS=0 GF004_T_PROMPT=0 GF004_T_AGENT=0 GF004_T_SCOPE=0 GF004_T_VALIDATION=0 GF004_T_COMMIT=0 GF004_T_STATE=0 GF004_T_CLEANUP=0 GF004_T_TOTAL=0
  declare -a GF004_CHANGED_FILES=() GF004_MARKERS=() GF004_SCOPE_PATTERNS=()
  mapfile -t GF004_SCOPE_PATTERNS < <(jq -r '.allowed_scope[]' "$task_file")
  mapfile -t GF004_MARKERS < <(jq -r '.validation.success_markers[]' "$task_file")

  gf_transition_task "$milestone_id" "$GF004_TASK" running execution_claim || return 1
  gf_atomic_state_update "$GF004_STATE_FILE" '.tasks[$task] += {last_run_id:$run,last_result:"running",last_evidence:$evidence,started_at:$started,source_base_commit:$head}' \
    --arg task "$GF004_TASK" --arg run "$GF004_RUN_ID" --arg evidence "$GF004_ARTIFACT_REL" --arg started "$(gf_now)" --arg head "$GF004_PRE_COMMIT" || return 1
  GF004_STATE_START=$(date +%s%N)
  git -C "$GF004_REPO" worktree add "$GF004_WORKSPACE" "$GF004_EXECUTION_BRANCH" >"$GF004_ARTIFACT_DIR/worktree.log" 2>&1 || { gf004_fail_execution 'isolated worktree creation failed'; return 1; }
  jq -n --arg repository "$GF004_REPO" --arg branch "$GF004_EXECUTION_BRANCH" --arg commit "$GF004_PRE_COMMIT" '{repository:$repository,execution_branch:$branch,head_commit:$commit}' >"$GF004_ARTIFACT_DIR/source-before.json"

  validator_abs="$GF004_WORKSPACE/$GF004_VALIDATOR_REL"
  [[ $GF004_VALIDATOR_REL != /* && $GF004_VALIDATOR_REL != *'..'* && -f $validator_abs && -x $validator_abs && ! -L $validator_abs ]] || { gf004_fail_execution 'validator path is unsafe, missing, non-executable, or a symlink'; return 1; }
  validator_real=$(realpath "$validator_abs") || { gf004_fail_execution 'validator canonicalization failed'; return 1; }
  [[ $validator_real == "$GF004_WORKSPACE/"* ]] || { gf004_fail_execution 'validator escapes source repository'; return 1; }
  gf004_matches_scope "$GF004_VALIDATOR_REL" && { gf004_fail_execution 'validator is inside allowed source scope'; return 1; }
  GF004_VALIDATOR_PRE=$(gf_sha256 "$validator_abs")

  prompt_start=$(date +%s%N)
  GF_RENDER_ALLOW_RUNNING=true prompt_generated=$(render_prompt "$milestone_id" "$GF004_TASK") || { gf004_fail_execution 'authoritative prompt rendering failed'; return 1; }
  cp "$prompt_generated" "$GF004_ARTIFACT_DIR/prompt.md" || { gf004_fail_execution 'run prompt preservation failed'; return 1; }
  GF004_T_PROMPT=$(gf004_elapsed "$prompt_start" "$(date +%s%N)")

  if [[ ${GF_GF004_ENABLE_TEST_HOOKS:-0} == 1 ]]; then test_fault=${GF_GF004_FAULT:-simulate_success}; fi
  agent_start=$(date +%s%N)
  GF004_CODEX_INVOCATIONS=1
  if [[ -n $test_fault ]]; then
    gf004_test_agent "$GF004_WORKSPACE" "$GF004_ARTIFACT_DIR" "$test_fault"
    agent_ok=$?
  else
    gf004_real_agent "$GF004_WORKSPACE" "$GF004_ARTIFACT_DIR/prompt.md" "$GF004_ARTIFACT_DIR" "$GF004_RUN_ID"
    agent_ok=$?
  fi
  GF004_T_AGENT=$(gf004_elapsed "$agent_start" "$(date +%s%N)")
  [[ $agent_ok -eq 0 ]] || { GF004_RUNTIME_STATUS=fail; gf004_fail_execution "OpenClaw/Codex execution failed (exit $GF004_OPENCLAW_EXIT)"; return 1; }
  if [[ $test_fault == missing_runtime ]]; then runtime_ok=false
  elif [[ -n $test_fault ]]; then runtime_ok=true
  elif gf004_runtime_is_proven "$GF004_ARTIFACT_DIR"; then runtime_ok=true
  else runtime_ok=false; fi
  $runtime_ok || { GF004_RUNTIME_STATUS=fail; gf004_fail_execution 'Codex runtime ownership was not proven'; return 1; }
  GF004_RUNTIME_STATUS=pass
  GF004_RUNTIME_EVIDENCE='OpenClaw result/audit or Gateway evidence recorded Codex runtime ownership'

  scope_start=$(date +%s%N)
  mapfile -t GF004_CHANGED_FILES < <(gf004_changed_files "$GF004_WORKSPACE")
  for changed in "${GF004_CHANGED_FILES[@]}"; do
    if [[ -f $GF004_WORKSPACE/$changed ]] && ! git -C "$GF004_WORKSPACE" ls-files --error-unmatch -- "$changed" >/dev/null 2>&1; then git -C "$GF004_WORKSPACE" add -N -- "$changed"; fi
  done
  git -C "$GF004_WORKSPACE" diff --binary >"$GF004_ARTIFACT_DIR/agent.patch"
  if gf004_verify_scope "$GF004_WORKSPACE"; then GF004_SCOPE_STATUS=pass; else GF004_SCOPE_STATUS=fail; fi
  jq -n --arg status "$GF004_SCOPE_STATUS" --arg reason "$GF004_SCOPE_REASON" --argjson changed_files "$(printf '%s\n' "${GF004_CHANGED_FILES[@]:-}" | jq -Rsc 'split("\n")|map(select(length>0))')" --argjson allowed "$(printf '%s\n' "${GF004_SCOPE_PATTERNS[@]}" | jq -Rsc 'split("\n")|map(select(length>0))')" '{status:$status,reason:$reason,changed_files:$changed_files,allowed_scope:$allowed}' >"$GF004_ARTIFACT_DIR/scope.json"
  GF004_T_SCOPE=$(gf004_elapsed "$scope_start" "$(date +%s%N)")
  [[ $GF004_SCOPE_STATUS == pass ]] || { gf004_fail_execution "scope validation failed: $GF004_SCOPE_REASON"; return 1; }

  if [[ $test_fault == validator_mutation ]]; then printf '\n# GF-004 validator mutation test hook\n' >>"$validator_abs"; fi
  GF004_VALIDATOR_POST=$(gf_sha256 "$validator_abs")
  jq -n --arg path "$GF004_VALIDATOR_REL" --arg pre "$GF004_VALIDATOR_PRE" --arg post "$GF004_VALIDATOR_POST" --arg status "$([[ $GF004_VALIDATOR_PRE == "$GF004_VALIDATOR_POST" ]] && printf pass || printf fail)" '{path:$path,pre_sha256:$pre,post_sha256:$post,status:$status}' >"$GF004_ARTIFACT_DIR/validator-integrity.json"
  [[ $GF004_VALIDATOR_PRE == "$GF004_VALIDATOR_POST" ]] || { GF004_VALIDATOR_STATUS=fail; gf004_fail_execution 'validator integrity failed'; return 1; }

  validation_start=$(date +%s%N)
  timeout_seconds=$(jq -r '.validation.timeout_seconds' "$task_file")
  mapfile -t validator_args < <(jq -r '.validation.args[]' "$task_file")
  timeout "$timeout_seconds" "$validator_abs" "${validator_args[@]}" >"$GF004_ARTIFACT_DIR/validation.stdout.log" 2>"$GF004_ARTIFACT_DIR/validation.stderr.log"
  GF004_VALIDATION_EXIT=$?
  markers_ok=true
  for marker in "${GF004_MARKERS[@]}"; do grep -Fq -- "$marker" "$GF004_ARTIFACT_DIR/validation.stdout.log" || markers_ok=false; done
  if [[ $GF004_VALIDATION_EXIT -eq 0 ]] && $markers_ok; then GF004_VALIDATOR_STATUS=pass; else GF004_VALIDATOR_STATUS=fail; fi
  GF004_T_VALIDATION=$(gf004_elapsed "$validation_start" "$(date +%s%N)")
  [[ $GF004_VALIDATOR_STATUS == pass ]] || { gf004_fail_execution "deterministic validation failed (exit $GF004_VALIDATION_EXIT, markers=$markers_ok)"; return 1; }

  commit_start=$(date +%s%N)
  git -C "$GF004_WORKSPACE" reset >/dev/null || { gf004_fail_execution 'could not clear intent-to-add index'; return 1; }
  git -C "$GF004_WORKSPACE" add -- "${GF004_CHANGED_FILES[@]}" || { gf004_fail_execution 'could not stage verified source files'; return 1; }
  commit_message="$GF004_TASK: $(jq -r '.title' "$task_file")"
  git -C "$GF004_WORKSPACE" -c user.name='Game Foundry' -c user.email='game-foundry@local.invalid' commit -m "$commit_message" >"$GF004_ARTIFACT_DIR/commit.log" 2>&1 || { gf004_fail_execution 'Game Foundry commit failed'; return 1; }
  GF004_ACCEPTED_COMMIT=$(git -C "$GF004_WORKSPACE" rev-parse HEAD)
  jq -n --arg pre_task_commit "$GF004_PRE_COMMIT" --arg accepted_commit "$GF004_ACCEPTED_COMMIT" --arg message "$commit_message" --argjson changed_files "$(printf '%s\n' "${GF004_CHANGED_FILES[@]}" | jq -Rsc 'split("\n")|map(select(length>0))')" '{pre_task_commit:$pre_task_commit,accepted_commit:$accepted_commit,commit_message:$message,changed_files:$changed_files,owner:"Game Foundry"}' >"$GF004_ARTIFACT_DIR/commit.json"
  GF004_T_COMMIT=$(gf004_elapsed "$commit_start" "$(date +%s%N)")

  state_backup="$GF004_ARTIFACT_DIR/state-before-pass.json"
  cp "$GF004_STATE_FILE" "$state_backup"
  cleanup_start=$(date +%s%N)
  git -C "$GF004_REPO" worktree remove "$GF004_WORKSPACE" >>"$GF004_ARTIFACT_DIR/worktree.log" 2>&1 || {
    git -C "$GF004_REPO" worktree remove --force "$GF004_WORKSPACE" >>"$GF004_ARTIFACT_DIR/worktree.log" 2>&1 || true
    git -C "$GF004_REPO" branch -f "$GF004_EXECUTION_BRANCH" "$GF004_PRE_COMMIT" >/dev/null 2>&1 || true
    GF004_ACCEPTED_COMMIT=''
    gf004_fail_execution 'post-commit cleanup failed and execution branch was rolled back'; return 1;
  }
  [[ $(git -C "$GF004_REPO" rev-parse "$GF004_EXECUTION_BRANCH") == "$GF004_ACCEPTED_COMMIT" ]] || {
    git -C "$GF004_REPO" branch -f "$GF004_EXECUTION_BRANCH" "$GF004_PRE_COMMIT" >/dev/null 2>&1 || true
    GF004_ACCEPTED_COMMIT=''
    gf004_fail_execution 'accepted execution branch verification failed'; return 1;
  }
  GF004_T_CLEANUP=$(gf004_elapsed "$cleanup_start" "$(date +%s%N)")

  state_start=$(date +%s%N)
  if ! gf_transition_task "$milestone_id" "$GF004_TASK" pass deterministic_acceptance ||
     ! gf_atomic_state_update "$GF004_STATE_FILE" '.source.head_commit=$commit | .tasks[$task] += {last_run_id:$run,accepted_commit:$commit,last_result:"pass",last_evidence:$evidence}' \
       --arg task "$GF004_TASK" --arg run "$GF004_RUN_ID" --arg commit "$GF004_ACCEPTED_COMMIT" --arg evidence "$GF004_ARTIFACT_REL"; then
    cp "$state_backup" "$GF004_STATE_FILE"
    git -C "$GF004_REPO" branch -f "$GF004_EXECUTION_BRANCH" "$GF004_PRE_COMMIT" >/dev/null 2>&1 || true
    GF004_ACCEPTED_COMMIT=''
    gf004_fail_execution 'PASS state persistence failed and execution branch was rolled back'; return 1
  fi
  GF004_T_STATE=$(gf004_elapsed "$state_start" "$(date +%s%N)")
  next_after=$(gf_next_result "$milestone_id")
  next_task=''
  [[ $next_after == NEXT_TASK=* ]] && next_task=${next_after#NEXT_TASK=}
  GF004_T_TOTAL=$(gf004_elapsed "$GF004_TOTAL_START" "$(date +%s%N)")
  gf004_write_result "$GF004_ARTIFACT_DIR/result.json" pass '' "$next_task"
  if $json_output; then cat "$GF004_ARTIFACT_DIR/result.json"; else
    printf 'GAME FOUNDRY — EXECUTE ONE\n==========================\n\nMilestone ............ %s\nTask ................. %s\nAttempt .............. %s / %s\n\nOpenClaw ............. PASS\nCodex runtime ........ PASS\nSource mutation ...... PASS\nScope ................ PASS\nValidator integrity .. PASS\nAcceptance ........... PASS\nCommit ............... PASS\nCleanup .............. PASS\nState update ......... PASS\n\nTask result .......... PASS\nAccepted commit ...... %s\n\nNext READY ........... %s\nNext execution ....... NOT STARTED\n\nCodex invocations .... 1\nEvidence ............. %s\n' "$milestone_id" "$GF004_TASK" "$GF004_ATTEMPT" "$GF004_MAX_ATTEMPTS" "$GF004_ACCEPTED_COMMIT" "${next_task:-NONE}" "$GF004_ARTIFACT_REL"
  fi
}
