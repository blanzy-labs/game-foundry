#!/usr/bin/env bash

gf005_elapsed() {
  awk -v start="$1" -v end="$2" 'BEGIN { printf "%.6f", (end-start)/1000000000 }'
}

gf005_source_matches_state() {
  local state_file=$1 repo branch expected actual
  repo=$(jq -r '.source.git_root // empty' "$state_file")
  branch=$(jq -r '.source.execution_branch // empty' "$state_file")
  expected=$(jq -r '.source.head_commit // empty' "$state_file")
  [[ -n $repo && -n $branch && -n $expected ]] || return 1
  actual=$(git -C "$repo" rev-parse "refs/heads/$branch" 2>/dev/null) || return 1
  [[ $actual == "$expected" ]]
}

gf005_queue_json() {
  local state_file=$1 next_task
  next_task=$(jq -r '.task_order[] as $id | select(.tasks[$id].status == "ready") | $id' "$state_file" | head -1)
  jq -n --arg status "$(jq -r '.status' "$state_file")" --arg next_task "$next_task" \
    '{milestone_status:$status,next_task:(if $next_task=="" then null else $next_task end)}'
}

gf005_finalize() {
  local stop_reason=$1 exit_code=$2 completed_at total_seconds attempted passed failed invocations average throughput
  local openclaw_seconds validation_seconds commit_seconds state_seconds queue_json critic_calls critic_passes critic_blocks critic_errors critic_seconds critic_average critic_input critic_output
  local repair_attempts repair_codex repair_critic repaired escalated repair_codex_seconds repair_critic_seconds
  completed_at=$(gf_now)
  total_seconds=$(gf005_elapsed "$GF005_START_NS" "$(date +%s%N)")
  attempted=$(jq 'length' "$GF005_TASK_RESULTS")
  passed=$(jq '[.[] | select(.result == "pass")] | length' "$GF005_TASK_RESULTS")
  failed=$(jq '[.[] | select(.result != "pass")] | length' "$GF005_TASK_RESULTS")
  invocations=$(jq '[.[].codex_invocations // 0] | add // 0' "$GF005_TASK_RESULTS")
  openclaw_seconds=$(jq '[.[].timing_seconds.openclaw_codex // 0] | add // 0' "$GF005_TASK_RESULTS")
  validation_seconds=$(jq '[.[].timing_seconds.deterministic_validation // 0] | add // 0' "$GF005_TASK_RESULTS")
  commit_seconds=$(jq '[.[].timing_seconds.commit // 0] | add // 0' "$GF005_TASK_RESULTS")
  state_seconds=$(jq '[.[].timing_seconds.state_update // 0] | add // 0' "$GF005_TASK_RESULTS")
  critic_calls=$(jq '[.[].critic.calls // 0] | add // 0' "$GF005_TASK_RESULTS")
  critic_passes=$(jq '[.[].critic_history[]? | select(.result == "pass")] | length' "$GF005_TASK_RESULTS")
  critic_blocks=$(jq '[.[].critic_history[]? | select(.result == "block")] | length' "$GF005_TASK_RESULTS")
  critic_errors=$(jq '[.[].critic_history[]? | select(.result == "error")] | length' "$GF005_TASK_RESULTS")
  critic_seconds=$(jq '[.[].critic.duration_seconds // 0] | add // 0' "$GF005_TASK_RESULTS")
  critic_input=$(jq '[.[].critic.input_tokens // 0] | add // 0' "$GF005_TASK_RESULTS")
  critic_output=$(jq '[.[].critic.output_tokens // 0] | add // 0' "$GF005_TASK_RESULTS")
  critic_average=$(awk -v total="$critic_seconds" -v count="$critic_calls" 'BEGIN {if(count==0) print 0; else printf "%.6f",total/count}')
  repair_attempts=$(jq '[.[].repair.attempts_used // 0] | add // 0' "$GF005_TASK_RESULTS")
  repair_codex=$(jq '[.[].repair.codex_calls // 0] | add // 0' "$GF005_TASK_RESULTS")
  repair_critic=$(jq '[.[].repair.critic_calls // 0] | add // 0' "$GF005_TASK_RESULTS")
  repaired=$(jq '[.[] | select(.repair.outcome == "repaired")] | length' "$GF005_TASK_RESULTS")
  escalated=$(jq '[.[] | select(.repair.outcome == "exhausted")] | length' "$GF005_TASK_RESULTS")
  repair_codex_seconds=$(jq '[.[].repair.duration_seconds.codex // 0] | add // 0' "$GF005_TASK_RESULTS")
  repair_critic_seconds=$(jq '[.[].repair.duration_seconds.critic // 0] | add // 0' "$GF005_TASK_RESULTS")
  average=$(awk -v total="$openclaw_seconds" -v count="$attempted" 'BEGIN {if(count==0) print 0; else printf "%.6f",total/count}')
  throughput=$(awk -v count="$passed" -v seconds="$total_seconds" 'BEGIN {if(seconds==0) print 0; else printf "%.6f",count*3600/seconds}')
  queue_json=$(gf005_queue_json "$GF005_STATE_FILE")
  jq -n --arg slice GF-005 --arg run_id "$GF005_RUN_ID" --arg milestone_id "$GF005_MILESTONE" \
    --arg started_at "$GF005_STARTED_AT" --arg completed_at "$completed_at" --arg stop_reason "$stop_reason" \
    --argjson max_tasks "$GF005_MAX_TASKS" --argjson max_minutes "$GF005_MAX_MINUTES" --argjson attempted "$attempted" \
    --argjson passed "$passed" --argjson failed "$failed" --argjson invocations "$invocations" --argjson executions "$(cat "$GF005_TASK_RESULTS")" \
    --argjson queue_after "$queue_json" --argjson total "$total_seconds" --argjson average "$average" --argjson throughput "$throughput" \
    --argjson openclaw "$openclaw_seconds" --argjson validation "$validation_seconds" --argjson commit "$commit_seconds" --argjson state "$state_seconds" \
    --argjson critic_calls "$critic_calls" --argjson critic_passes "$critic_passes" --argjson critic_blocks "$critic_blocks" --argjson critic_errors "$critic_errors" \
    --argjson critic_seconds "$critic_seconds" --argjson critic_average "$critic_average" --argjson critic_input "$critic_input" --argjson critic_output "$critic_output" \
    --argjson repair_attempts "$repair_attempts" --argjson repair_codex "$repair_codex" --argjson repair_critic "$repair_critic" --argjson repaired "$repaired" --argjson escalated "$escalated" \
    --argjson repair_codex_seconds "$repair_codex_seconds" --argjson repair_critic_seconds "$repair_critic_seconds" \
    '{slice:$slice,run_id:$run_id,milestone_id:$milestone_id,started_at:$started_at,completed_at:$completed_at,bounds:{max_tasks:$max_tasks,max_minutes:$max_minutes},attempted_tasks:$attempted,passed_tasks:$passed,failed_tasks:$failed,executions:$executions,stop_reason:$stop_reason,queue_after:$queue_after,codex_invocations:$invocations,critic:{calls:$critic_calls,passes:$critic_passes,blocks:$critic_blocks,errors:$critic_errors,duration_seconds:$critic_seconds,average_duration_seconds:$critic_average,input_tokens:$critic_input,output_tokens:$critic_output},repair:{attempts:$repair_attempts,codex_calls:$repair_codex,critic_calls:$repair_critic,tasks_repaired:$repaired,tasks_escalated_after_repair:$escalated,duration_seconds:{codex:$repair_codex_seconds,critic:$repair_critic_seconds}},human_interventions:0,metrics_seconds:{total_bounded_run:$total,average_openclaw_codex_per_attempt:$average,openclaw_codex:$openclaw,deterministic_validation:$validation,critic:$critic_seconds,repair_codex:$repair_codex_seconds,repair_critic:$repair_critic_seconds,commit:$commit,state_transition:$state},fixture_accepted_tasks_per_hour:$throughput}' \
    >"$GF005_ARTIFACT_DIR/run.json"
  cp "$GF005_TASK_RESULTS" "$GF005_ARTIFACT_DIR/task-results.json"
  {
    printf 'GAME FOUNDRY — BOUNDED RUN\n==========================\n\n'
    printf 'Milestone ............. %s\nRun ................... %s\nMax tasks ............. %s\nMax runtime ........... %sm\n\n' "$GF005_MILESTONE" "$GF005_RUN_ID" "$GF005_MAX_TASKS" "$GF005_MAX_MINUTES"
    jq -r 'to_entries[] | "\(.key + 1). \(.value.task_id)\n   Codex .............. \(.value.agent.runtime_status | ascii_upcase)\n   Validation ......... \(.value.validation.status | ascii_upcase)\n   Commit ............. \(.value.source.accepted_commit // "NONE")\n   State .............. \(.value.result | ascii_upcase)\n"' "$GF005_TASK_RESULTS"
    printf '%s\n\nAttempted ............. %s\nPassed ................ %s\nFailed ................ %s\n\n' '--------------------------------' "$attempted" "$passed" "$failed"
    printf 'Next READY ............ %s\n\nSTOP REASON ........... %s\n' "$(jq -r '.next_task // "NONE"' <<<"$queue_json")" "$stop_reason"
  } >"$GF005_ARTIFACT_DIR/run.log"
  rm -f -- "$GF005_TASK_RESULTS"
  if $json_output; then cat "$GF005_ARTIFACT_DIR/run.json"; else cat "$GF005_ARTIFACT_DIR/run.log"; fi
  return "$exit_code"
}

gf005_inject_after_pass() {
  local fault=$1 state_file=$2 attempted=$3 package repo branch head tree unexpected
  [[ ${GF_GF005_ENABLE_TEST_HOOKS:-0} == 1 && $attempted -eq 1 ]] || return 0
  case "$fault" in
    lock_after_first)
      package=$(jq -r '.package_path' "$state_file")
      printf '\nGF-005 lock-integrity test hook\n' >>"$package/design.md"
      ;;
    source_after_first)
      repo=$(jq -r '.source.git_root' "$state_file")
      branch=$(jq -r '.source.execution_branch' "$state_file")
      head=$(jq -r '.source.head_commit' "$state_file")
      tree=$(git -C "$repo" rev-parse "$head^{tree}") || return 1
      unexpected=$(printf 'GF-005 source mismatch test hook\n' | git -C "$repo" -c user.name='GF-005 Test' -c user.email='gf005-test@local.invalid' commit-tree "$tree" -p "$head") || return 1
      git -C "$repo" branch -f "$branch" "$unexpected" >/dev/null || return 1
      ;;
  esac
}

gf_run_bounded() {
  local milestone_id='' max_tasks=3 max_minutes=30 argument state_dir status_json status_err status_code state_status next_value selected
  local child_code child_json child_err result fault=${GF_GF005_FAULT:-} attempted deadline_ns now_ns stop_reason exit_code
  while (($#)); do
    argument=$1
    shift
    case "$argument" in
      --max-tasks) (($#)) || { gf_error 'INVALID LIMIT: --max-tasks requires a value'; return 2; }; max_tasks=$1; shift ;;
      --max-minutes) (($#)) || { gf_error 'INVALID LIMIT: --max-minutes requires a value'; return 2; }; max_minutes=$1; shift ;;
      --*) gf_error "unknown run-bounded option: $argument"; return 2 ;;
      *) [[ -z $milestone_id ]] || { gf_error 'run-bounded accepts one milestone ID'; return 2; }; milestone_id=$argument ;;
    esac
  done
  [[ -n $milestone_id ]] || { gf_error 'run-bounded requires a milestone ID'; return 2; }
  [[ $max_tasks =~ ^[1-9][0-9]*$ ]] || { gf_error 'INVALID LIMIT: max-tasks must be a positive integer'; return 2; }
  [[ $max_minutes =~ ^[1-9][0-9]*$ ]] || { gf_error 'INVALID LIMIT: max-minutes must be a positive integer'; return 2; }
  GF005_MILESTONE=$milestone_id GF005_MAX_TASKS=$max_tasks GF005_MAX_MINUTES=$max_minutes
  state_dir=$(gf_state_dir "$milestone_id")
  GF005_STATE_FILE="$state_dir/state.json"
  [[ -f $GF005_STATE_FILE ]] || { gf_error "MILESTONE STATE MISSING: $milestone_id"; return 1; }
  exec 7>"$state_dir/.runner.lock"
  if ! flock -n 7; then
    if $json_output; then jq -n --arg milestone_id "$milestone_id" '{slice:"GF-005",milestone_id:$milestone_id,stop_reason:"RUNNER_BUSY",attempted_tasks:0,codex_invocations:0}'; else printf 'RUNNER_BUSY\n'; fi
    return 1
  fi
  GF005_START_NS=$(date +%s%N)
  GF005_STARTED_AT=$(gf_now)
  GF005_RUN_ID="gf005-$(date -u +'%Y%m%dT%H%M%SZ')-$(printf '%s-%s-%s' "$milestone_id" "$$" "$RANDOM" | sha256sum | cut -c1-8)"
  GF005_ARTIFACT_DIR="$GF_BOUNDED_ARTIFACT_ROOT/$milestone_id/$GF005_RUN_ID"
  mkdir -p "$GF005_ARTIFACT_DIR/tasks"
  GF005_TASK_RESULTS="$GF005_ARTIFACT_DIR/.task-results.tmp.json"
  printf '[]\n' >"$GF005_TASK_RESULTS"
  deadline_ns=$(awk -v start="$GF005_START_NS" -v minutes="$max_minutes" 'BEGIN {printf "%.0f",start+(minutes*60*1000000000)}')

  while true; do
    attempted=$(jq 'length' "$GF005_TASK_RESULTS")
    if ((attempted >= max_tasks)); then gf005_finalize TASK_LIMIT 0; return $?; fi
    now_ns=$(date +%s%N)
    if [[ $fault == time_after_first && ${GF_GF005_ENABLE_TEST_HOOKS:-0} == 1 && $attempted -ge 1 ]] || ((now_ns >= deadline_ns)); then
      gf005_finalize TIME_LIMIT 0; return $?
    fi
    status_json="$GF005_ARTIFACT_DIR/preflight-$((attempted + 1)).json"
    status_err="$GF005_ARTIFACT_DIR/preflight-$((attempted + 1)).stderr.log"
    GF_MILESTONE_STATE_ROOT="$GF_STATE_ROOT" GF_MILESTONE_ARTIFACT_ROOT="$GF_ARTIFACT_ROOT" \
      "$GF_CONTROL_ROOT/scripts/gf-milestone.sh" status "$milestone_id" --json >"$status_json" 2>"$status_err"
    status_code=$?
    if [[ $status_code -ne 0 ]]; then
      if grep -Fq 'LOCK VALIDATION FAIL' "$status_err"; then stop_reason=LOCK_INTEGRITY_FAILURE; else stop_reason=INTERNAL_ERROR; fi
      gf005_finalize "$stop_reason" 1; return $?
    fi
    if jq -e '[.tasks[] | select(.status == "running")] | length > 0' "$status_json" >/dev/null; then gf005_finalize RECOVERY_REQUIRED 1; return $?; fi
    if jq -e '[.tasks[] | select(.status == "escalated")] | length > 0' "$status_json" >/dev/null; then gf005_finalize ESCALATED 1; return $?; fi
    state_status=$(jq -r '.status' "$status_json")
    if [[ $state_status == pending_human ]]; then gf005_finalize HUMAN_GATE 0; return $?; fi
    next_value=$(jq -r '.next' "$status_json")
    case "$next_value" in
      MILESTONE_BLOCKED) gf005_finalize MILESTONE_BLOCKED 1; return $? ;;
      NO_READY_TASK) gf005_finalize NO_READY_TASK 0; return $? ;;
      MILESTONE_COMPLETE) gf005_finalize HUMAN_GATE 0; return $? ;;
      NEXT_TASK=*) selected=${next_value#NEXT_TASK=} ;;
      *) gf005_finalize INTERNAL_ERROR 1; return $? ;;
    esac
    if ! gf005_source_matches_state "$GF005_STATE_FILE"; then gf005_finalize SOURCE_STATE_MISMATCH 1; return $?; fi

    child_json="$GF005_ARTIFACT_DIR/tasks/$selected.json"
    child_err="$GF005_ARTIFACT_DIR/tasks/$selected.stderr.log"
    child_fault=''
    if [[ ${GF_GF005_ENABLE_TEST_HOOKS:-0} == 1 ]]; then
      child_fault=simulate_success
      [[ $fault == task2_validation_failure && $selected == GF-CHAIN-002 ]] && child_fault=validation_failure
      [[ $fault == task2_unauthorized_change && $selected == GF-CHAIN-002 ]] && child_fault=unauthorized_change
      [[ $fault == task1_safe_not_started && $selected == GF-CHAIN-001 ]] && child_fault=safe_not_started
    fi
    if [[ -n $child_fault ]]; then
      GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT="$child_fault" GF_MILESTONE_STATE_ROOT="$GF_STATE_ROOT" GF_MILESTONE_ARTIFACT_ROOT="$GF_ARTIFACT_ROOT" \
        GF_EXECUTION_ARTIFACT_ROOT="$GF_EXECUTION_ARTIFACT_ROOT" GF_EXECUTION_TMP_ROOT="$GF_EXECUTION_TMP_ROOT" \
        "$GF_CONTROL_ROOT/scripts/gf-milestone.sh" execute-one "$milestone_id" --json >"$child_json" 2>"$child_err"
    else
      GF_MILESTONE_STATE_ROOT="$GF_STATE_ROOT" GF_MILESTONE_ARTIFACT_ROOT="$GF_ARTIFACT_ROOT" \
        GF_EXECUTION_ARTIFACT_ROOT="$GF_EXECUTION_ARTIFACT_ROOT" GF_EXECUTION_TMP_ROOT="$GF_EXECUTION_TMP_ROOT" \
        "$GF_CONTROL_ROOT/scripts/gf-milestone.sh" execute-one "$milestone_id" --json >"$child_json" 2>"$child_err"
    fi
    child_code=$?
    if ! jq -e . "$child_json" >/dev/null 2>&1; then
      if grep -Fq 'expected source HEAD mismatch' "$child_err"; then stop_reason=SOURCE_STATE_MISMATCH
      elif grep -Fq 'LOCK VALIDATION FAIL' "$child_err"; then stop_reason=LOCK_INTEGRITY_FAILURE
      elif grep -Fq 'RECOVERY REQUIRED' "$child_err"; then stop_reason=RECOVERY_REQUIRED
      else stop_reason=INTERNAL_ERROR; fi
      gf005_finalize "$stop_reason" 1; return $?
    fi
    result=$(jq -r '.result' "$child_json")
    temporary=$(mktemp "$GF005_TASK_RESULTS.tmp.XXXXXX") || { gf005_finalize INTERNAL_ERROR 1; return $?; }
    jq --slurpfile child "$child_json" '. + [$child[0]]' "$GF005_TASK_RESULTS" >"$temporary" && mv "$temporary" "$GF005_TASK_RESULTS"
    attempted=$(jq 'length' "$GF005_TASK_RESULTS")
    if [[ $result != pass || $child_code -ne 0 ]]; then
      if [[ $result == transport_refused || $result == execution_refused ]]; then stop_reason=TRANSPORT_REFUSED
      elif jq -e --arg task "$selected" '.tasks[$task].status == "escalated"' "$GF005_STATE_FILE" >/dev/null; then stop_reason=ESCALATED; else stop_reason=TASK_FAILED; fi
      gf005_finalize "$stop_reason" 1; return $?
    fi
    gf005_inject_after_pass "$fault" "$GF005_STATE_FILE" "$attempted" || { gf005_finalize INTERNAL_ERROR 1; return $?; }
  done
}
