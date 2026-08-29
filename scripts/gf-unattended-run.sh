#!/usr/bin/env bash
set -u -o pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cli="$repo_root/scripts/gf-milestone.sh"
state_root=$(realpath -m "${GF_MILESTONE_STATE_ROOT:-$repo_root/state}")
artifact_root=$(realpath -m "${GF_UNATTENDED_ARTIFACT_ROOT:-$repo_root/artifacts/unattended}")
milestone_artifact_root=$(realpath -m "${GF_MILESTONE_ARTIFACT_ROOT:-$repo_root/artifacts/milestones}")
execution_artifact_root=$(realpath -m "${GF_EXECUTION_ARTIFACT_ROOT:-$repo_root/artifacts/executions}")
execution_tmp_root=$(realpath -m "${GF_EXECUTION_TMP_ROOT:-$repo_root/tmp/executions}")
bounded_artifact_root=''
json_output=false
max_tasks=${GF_UNATTENDED_MAX_TASKS:-1}
max_minutes=${GF_UNATTENDED_MAX_MINUTES:-45}
readonly max_tasks_limit=10
readonly max_minutes_limit=240
milestone_id=''
configuration_error=''

usage() {
  printf 'usage: %s [--json] [--max-tasks N] [--max-minutes N] MILESTONE_ID\n' "$0" >&2
}

while (($#)); do
  case "$1" in
    --json) json_output=true; shift ;;
    --max-tasks) if (($# >= 2)); then max_tasks=$2; shift 2; else configuration_error='--max-tasks requires a value'; shift; fi ;;
    --max-minutes) if (($# >= 2)); then max_minutes=$2; shift 2; else configuration_error='--max-minutes requires a value'; shift; fi ;;
    --*) configuration_error="unknown option: $1"; shift ;;
    *) if [[ -z $milestone_id ]]; then milestone_id=$1; else configuration_error='only one milestone ID is accepted'; fi; shift ;;
  esac
done

[[ -n $milestone_id ]] || configuration_error=${configuration_error:-'milestone ID is required'}
[[ -z $milestone_id || $milestone_id =~ ^[A-Z0-9][A-Z0-9-]+$ ]] || configuration_error='invalid milestone ID'
[[ $max_tasks =~ ^[1-9][0-9]*$ && $max_tasks -le $max_tasks_limit ]] || configuration_error="max-tasks must be between 1 and $max_tasks_limit"
[[ $max_minutes =~ ^[1-9][0-9]*$ && $max_minutes -le $max_minutes_limit ]] || configuration_error="max-minutes must be between 1 and $max_minutes_limit"

started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
start_ns=$(date +%s%N)
run_id="gf009-$(date -u +'%Y%m%dT%H%M%SZ')-$(printf '%s-%s-%s' "$milestone_id" "$$" "$RANDOM" | sha256sum | cut -c1-8)"
milestone_key=$(printf '%s' "${milestone_id:-invalid}" | tr -c 'A-Za-z0-9._-' '_')
artifact_dir="$artifact_root/$milestone_key/$run_id"
mkdir -p "$artifact_dir"
bounded_artifact_root="$artifact_dir/bounded"
state_dir="$state_root/$milestone_id"
state_file="$state_dir/state.json"
receipt="$artifact_dir/result.json"

initial_state=null
final_state=null
source_before=''
source_after=''
tasks_attempted=0
tasks_passed=0
tasks_failed=0
tasks_escalated=0
codex_calls=0
critic_calls=0
repair_attempts=0
recovery_actions='[]'
accepted_commits='[]'
transport_classifications='[]'
artifact_references='[]'
runner_lock_result=not_attempted
stop_reason=INFRASTRUCTURE_FAILURE
exit_class=INFRASTRUCTURE_FAILURE
human_action_required=true
next_action=HUMAN_REVIEW
scheduler_should_invoke_again=false
shell_code=70

state_status() {
  local file=$1
  [[ -f $file ]] && jq -c '{status:(.status // null),tasks:(.tasks // {})}' "$file" 2>/dev/null || printf 'null\n'
}

source_head() {
  local file=$1 repo branch
  [[ -f $file ]] || return 0
  repo=$(jq -r '.source.git_root // empty' "$file")
  branch=$(jq -r '.source.execution_branch // empty' "$file")
  [[ -n $repo && -n $branch ]] || return 0
  git -C "$repo" rev-parse "refs/heads/$branch" 2>/dev/null || true
}

has_escalated() {
  [[ -f $state_file ]] && jq -e '[.tasks[] | select(.status=="escalated")] | length > 0' "$state_file" >/dev/null 2>&1
}

has_running() {
  [[ -f $state_file ]] && jq -e '[.tasks[] | select(.status=="running")] | length > 0' "$state_file" >/dev/null 2>&1
}

collect_transport() {
  local result_file=$1 evidence path file item
  local -a files=()
  [[ -f $result_file ]] || return 0
  while IFS= read -r evidence; do
    [[ -n $evidence ]] || continue
    path=$evidence
    [[ $path == /* ]] || path="$repo_root/$path"
    mapfile -t files < <(find "$path" -type f -path '*/transport-*/agent-transport.json' -print 2>/dev/null | LC_ALL=C sort -u)
    if ((${#files[@]} == 0)) && [[ -f $path/agent-transport.json ]]; then files=("$path/agent-transport.json"); fi
    for file in "${files[@]}"; do
      [[ -n $file ]] || continue
      item=$(jq -c '{classification:(.failure_class // null),recovery_action:(.recovery_action // null),generation:(.transport_generation // .generation // null),evidence_path:$path}' --arg path "${file#"$repo_root/"}" "$file")
      transport_classifications=$(jq --argjson item "$item" '. + [$item]' <<<"$transport_classifications")
    done
  done < <(jq -r '.executions[]?.evidence_path // empty' "$result_file" 2>/dev/null)
}

write_receipt() {
  local finished_at end_ns duration state_now
  finished_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  end_ns=$(date +%s%N)
  duration=$(awk -v start="$start_ns" -v end="$end_ns" 'BEGIN {printf "%.6f",(end-start)/1000000000}')
  state_now=$(state_status "$state_file")
  [[ $final_state != null ]] || final_state=$state_now
  [[ -n $source_after ]] || source_after=$(source_head "$state_file")
  local temporary
  temporary=$(mktemp "$receipt.tmp.XXXXXX") || return 1
  jq -n --arg run_id "$run_id" --arg started "$started_at" --arg finished "$finished_at" --argjson duration "$duration" \
    --arg milestone "$milestone_id" --argjson initial "$initial_state" --argjson final "$final_state" \
    --argjson attempted "$tasks_attempted" --argjson passed "$tasks_passed" --argjson failed "$tasks_failed" --argjson escalated "$tasks_escalated" \
    --argjson codex "$codex_calls" --argjson critic "$critic_calls" --argjson repairs "$repair_attempts" --argjson recovery "$recovery_actions" \
    --arg stop "$stop_reason" --argjson human "$human_action_required" --arg before "$source_before" --arg after "$source_after" \
    --argjson commits "$accepted_commits" --argjson transports "$transport_classifications" --arg lock "$runner_lock_result" \
    --arg exit_class "$exit_class" --argjson shell_code "$shell_code" --arg next "$next_action" --argjson invoke_again "$scheduler_should_invoke_again" \
    --arg max_tasks "$max_tasks" --arg max_minutes "$max_minutes" --argjson refs "$artifact_references" \
    '{schema_version:1,run_id:$run_id,started_at:$started,finished_at:$finished,duration_seconds:$duration,milestone:$milestone,
      initial_milestone_state:$initial,final_milestone_state:$final,
      bounds:{max_tasks:($max_tasks|try tonumber catch null),max_minutes:($max_minutes|try tonumber catch null)},
      tasks_attempted:$attempted,tasks_passed:$passed,tasks_failed:$failed,tasks_escalated:$escalated,
      codex_calls:$codex,critic_calls:$critic,repair_attempts:$repairs,recovery_actions:$recovery,
      stop_reason:$stop,human_action_required:$human,next_action:$next,scheduler_should_invoke_again:$invoke_again,
      source_head_before:(if $before=="" then null else $before end),source_head_after:(if $after=="" then null else $after end),
      accepted_commits:$commits,transport_classifications:$transports,runner_lock_result:$lock,
      exit_class:$exit_class,shell_exit_code:$shell_code,artifact_references:$refs}' >"$temporary" || return 1
  mv "$temporary" "$receipt"
}

emit_and_exit() {
  write_receipt || { printf 'could not write unattended receipt\n' >&2; exit 70; }
  if $json_output; then
    cat "$receipt"
  else
    printf 'GAME FOUNDRY — UNATTENDED RUN\nMilestone ............ %s\nStop reason .......... %s\nExit class ........... %s\nHuman action ......... %s\nReceipt .............. %s\n' \
      "$milestone_id" "$stop_reason" "$exit_class" "$human_action_required" "$receipt"
  fi
  exit "$shell_code"
}

mark_idle() {
  stop_reason=$1 exit_class=$2 human_action_required=$3 next_action=$4 scheduler_should_invoke_again=$5 shell_code=0
}

if [[ -n $configuration_error ]]; then
  usage
  runner_lock_result=not_acquired stop_reason=INVALID_INVOCATION exit_class=INFRASTRUCTURE_FAILURE human_action_required=true next_action=HUMAN_REVIEW scheduler_should_invoke_again=false shell_code=2
  artifact_references=$(jq --arg error "$configuration_error" '. + [{kind:"configuration_error",detail:$error}]' <<<"$artifact_references")
  emit_and_exit
fi

mkdir -p "$state_root"
exec 8>"$state_root/.unattended.lock"
if ! flock -n 8; then
  runner_lock_result=busy
  stop_reason=RUNNER_BUSY exit_class=BUSY human_action_required=false next_action=RUN_LATER scheduler_should_invoke_again=true shell_code=75
  emit_and_exit
fi
runner_lock_result=acquired

if [[ ! -f $state_file ]]; then
  stop_reason=MILESTONE_STATE_MISSING
  emit_and_exit
fi

if [[ ${GF_GF009_ENABLE_TEST_HOOKS:-0} == 1 && -n ${GF_GF009_LOCK_READY_FILE:-} ]]; then
  : >"$GF_GF009_LOCK_READY_FILE"
fi
if [[ ${GF_GF009_ENABLE_TEST_HOOKS:-0} == 1 && ${GF_GF009_HOLD_LOCK_SECONDS:-0} =~ ^[1-9][0-9]*$ ]]; then
  sleep "$GF_GF009_HOLD_LOCK_SECONDS"
fi

initial_state=$(state_status "$state_file")
source_before=$(source_head "$state_file")

status_file="$artifact_dir/status-initial.json"
if ! GF_MILESTONE_STATE_ROOT="$state_root" GF_MILESTONE_ARTIFACT_ROOT="$milestone_artifact_root" \
  "$cli" status "$milestone_id" --json >"$status_file" 2>"$artifact_dir/status-initial.stderr.log"; then
  stop_reason=STATE_PREFLIGHT_FAILED
  emit_and_exit
fi
artifact_references=$(jq --arg path "${status_file#"$repo_root/"}" '. + [{kind:"initial_status",path:$path}]' <<<"$artifact_references")

if has_escalated; then
  stop_reason=ESCALATED exit_class=ESCALATED human_action_required=true next_action=HUMAN_REVIEW scheduler_should_invoke_again=false shell_code=20
  emit_and_exit
fi

if has_running; then
  recovery_status_file="$artifact_dir/recovery-status.json"
  if ! GF_MILESTONE_STATE_ROOT="$state_root" "$cli" recovery-status "$milestone_id" --json >"$recovery_status_file" 2>"$artifact_dir/recovery-status.stderr.log"; then
    stop_reason=RECOVERY_STATUS_FAILED
    emit_and_exit
  fi
  recovery_action=$(jq -r '.recovery_action' "$recovery_status_file")
  recovery_actions=$(jq --arg action "$recovery_action" --arg status "${recovery_status_file#"$repo_root/"}" '. + [{action:$action,status_artifact:$status}]' <<<"$recovery_actions")
  if [[ $recovery_action == RECOVERY_BUSY ]]; then
    stop_reason=RUNNER_BUSY exit_class=BUSY human_action_required=false next_action=RUN_LATER scheduler_should_invoke_again=true shell_code=75
    emit_and_exit
  fi
  recovery_file="$artifact_dir/recovery-result.json"
  if GF_MILESTONE_STATE_ROOT="$state_root" GF_MILESTONE_ARTIFACT_ROOT="$milestone_artifact_root" \
    GF_EXECUTION_ARTIFACT_ROOT="$execution_artifact_root" GF_EXECUTION_TMP_ROOT="$execution_tmp_root" \
    "$cli" recover "$milestone_id" --json >"$recovery_file" 2>"$artifact_dir/recovery.stderr.log"; then recovery_code=0; else recovery_code=$?; fi
  if jq -e . "$recovery_file" >/dev/null 2>&1; then
    recovery_actions=$(jq --argjson item "$(jq -c '{action:.recovery_action,result:.result,original_checkpoint:.original_checkpoint,artifact_path:$path}' --arg path "${recovery_file#"$repo_root/"}" "$recovery_file")" '. + [$item]' <<<"$recovery_actions")
    codex_calls=$((codex_calls + $(jq -r '.codex_calls // 0' "$recovery_file")))
    critic_calls=$((critic_calls + $(jq -r '.critic_calls // 0' "$recovery_file")))
    recovery_result=$(jq -r '.result' "$recovery_file")
    if [[ $recovery_result == pass ]]; then
      tasks_attempted=$((tasks_attempted + 1)); tasks_passed=$((tasks_passed + 1))
      recovery_commit=$(jq -r '.commit.sha // empty' "$recovery_file")
      [[ -z $recovery_commit ]] || accepted_commits=$(jq --arg commit "$recovery_commit" '. + [$commit] | unique' <<<"$accepted_commits")
    elif [[ $recovery_result == escalated ]]; then
      tasks_escalated=$((tasks_escalated + 1))
    else
      tasks_failed=$((tasks_failed + 1))
    fi
  fi
  if [[ $recovery_code -ne 0 ]]; then
    if has_escalated; then
      stop_reason=ESCALATED exit_class=ESCALATED human_action_required=true next_action=HUMAN_REVIEW scheduler_should_invoke_again=false shell_code=20
    else
      stop_reason=RECOVERY_FAILED
    fi
    emit_and_exit
  fi
fi

status_after_recovery="$artifact_dir/status-after-recovery.json"
if ! GF_MILESTONE_STATE_ROOT="$state_root" "$cli" status "$milestone_id" --json >"$status_after_recovery" 2>"$artifact_dir/status-after-recovery.stderr.log"; then
  stop_reason=STATE_PREFLIGHT_FAILED
  emit_and_exit
fi

milestone_status=$(jq -r '.status' "$status_after_recovery")
if [[ $milestone_status == pending_human ]]; then
  mark_idle HUMAN_GATE SUCCESS_HUMAN_GATE true HUMAN_REVIEW false
  emit_and_exit
fi
if has_escalated; then
  stop_reason=ESCALATED exit_class=ESCALATED human_action_required=true next_action=HUMAN_REVIEW scheduler_should_invoke_again=false shell_code=20
  emit_and_exit
fi
if [[ $milestone_status == automated_work_complete ]]; then
  mark_idle MILESTONE_COMPLETE SUCCESS_MILESTONE_COMPLETE false MILESTONE_DONE false
  emit_and_exit
fi

next_value=$(jq -r '.next' "$status_after_recovery")
if ((tasks_attempted >= max_tasks)); then
  mark_idle TASK_LIMIT SUCCESS_WORK_COMPLETED false RUN_LATER true
  emit_and_exit
fi
case "$next_value" in
  MILESTONE_COMPLETE)
    if [[ $milestone_status == pending_human ]]; then mark_idle HUMAN_GATE SUCCESS_HUMAN_GATE true HUMAN_REVIEW false
    else mark_idle MILESTONE_COMPLETE SUCCESS_MILESTONE_COMPLETE false MILESTONE_DONE false; fi
    emit_and_exit ;;
  MILESTONE_BLOCKED|NO_READY_TASK)
    mark_idle NO_READY_WORK SUCCESS_IDLE false RUN_LATER true
    emit_and_exit ;;
  NEXT_TASK=*) ;;
  *) stop_reason=STATE_PREFLIGHT_FAILED; emit_and_exit ;;
esac

elapsed_whole_seconds=$((($(date +%s%N) - start_ns) / 1000000000))
max_seconds=$((max_minutes * 60))
if ((elapsed_whole_seconds >= max_seconds)); then
  mark_idle TIME_LIMIT SUCCESS_IDLE false RUN_LATER true
  emit_and_exit
fi
elapsed_minutes_ceiling=$(((elapsed_whole_seconds + 59) / 60))
remaining_minutes=$((max_minutes - elapsed_minutes_ceiling))
((remaining_minutes >= 1)) || remaining_minutes=1
remaining_tasks=$((max_tasks - tasks_attempted))
bounded_file="$artifact_dir/bounded-result.json"
if GF_MILESTONE_STATE_ROOT="$state_root" GF_MILESTONE_ARTIFACT_ROOT="$milestone_artifact_root" \
  GF_EXECUTION_ARTIFACT_ROOT="$execution_artifact_root" GF_EXECUTION_TMP_ROOT="$execution_tmp_root" \
  GF_BOUNDED_ARTIFACT_ROOT="$bounded_artifact_root" \
  "$cli" run-bounded "$milestone_id" --max-tasks "$remaining_tasks" --max-minutes "$remaining_minutes" --json >"$bounded_file" 2>"$artifact_dir/bounded.stderr.log"; then bounded_code=0; else bounded_code=$?; fi

if ! jq -e . "$bounded_file" >/dev/null 2>&1; then
  stop_reason=BOUNDED_RUN_FAILED
  emit_and_exit
fi
artifact_references=$(jq --arg path "${bounded_file#"$repo_root/"}" '. + [{kind:"bounded_run",path:$path}]' <<<"$artifact_references")
new_attempted=$(jq -r '.attempted_tasks // 0' "$bounded_file")
new_passed=$(jq -r '.passed_tasks // 0' "$bounded_file")
new_failed=$(jq -r '.failed_tasks // 0' "$bounded_file")
tasks_attempted=$((tasks_attempted + new_attempted))
tasks_passed=$((tasks_passed + new_passed))
tasks_failed=$((tasks_failed + new_failed))
codex_calls=$((codex_calls + $(jq -r '.codex_invocations // 0' "$bounded_file")))
critic_calls=$((critic_calls + $(jq -r '.critic.calls // 0' "$bounded_file")))
repair_attempts=$((repair_attempts + $(jq -r '.repair.attempts // 0' "$bounded_file")))
new_commits=$(jq '[.executions[]?.source.accepted_commit | select(. != null)]' "$bounded_file")
accepted_commits=$(jq --argjson new "$new_commits" '. + $new | unique' <<<"$accepted_commits")
tasks_escalated=$((tasks_escalated + $(jq '[.executions[]? | select(.result=="escalated")] | length' "$bounded_file")))
collect_transport "$bounded_file"

bounded_stop=$(jq -r '.stop_reason' "$bounded_file")
post_bounded_status=$(jq -r '.status // ""' "$state_file")
if [[ $post_bounded_status == pending_human ]]; then
  mark_idle HUMAN_GATE SUCCESS_HUMAN_GATE true HUMAN_REVIEW false
  emit_and_exit
fi
if [[ $post_bounded_status == automated_work_complete ]]; then
  mark_idle MILESTONE_COMPLETE SUCCESS_MILESTONE_COMPLETE false MILESTONE_DONE false
  emit_and_exit
fi
case "$bounded_stop" in
  TASK_LIMIT) mark_idle TASK_LIMIT SUCCESS_WORK_COMPLETED false RUN_LATER true ;;
  TIME_LIMIT) mark_idle TIME_LIMIT SUCCESS_WORK_COMPLETED false RUN_LATER true ;;
  HUMAN_GATE)
    if [[ $(jq -r '.status // ""' "$state_file") == automated_work_complete ]]; then
      mark_idle MILESTONE_COMPLETE SUCCESS_MILESTONE_COMPLETE false MILESTONE_DONE false
    else
      mark_idle HUMAN_GATE SUCCESS_HUMAN_GATE true HUMAN_REVIEW false
    fi ;;
  MILESTONE_COMPLETE) mark_idle MILESTONE_COMPLETE SUCCESS_MILESTONE_COMPLETE false MILESTONE_DONE false ;;
  NO_READY_TASK|MILESTONE_BLOCKED)
    if ((tasks_passed > 0)); then mark_idle NO_READY_WORK SUCCESS_WORK_COMPLETED false RUN_LATER true
    else mark_idle NO_READY_WORK SUCCESS_IDLE false RUN_LATER true; fi ;;
  RUNNER_BUSY) stop_reason=RUNNER_BUSY exit_class=BUSY human_action_required=false next_action=RUN_LATER scheduler_should_invoke_again=true shell_code=75 ;;
  ESCALATED) stop_reason=ESCALATED exit_class=ESCALATED human_action_required=true next_action=HUMAN_REVIEW scheduler_should_invoke_again=false shell_code=20 ;;
  TRANSPORT_REFUSED)
    stop_reason=TRANSPORT_REFUSED exit_class=INFRASTRUCTURE_FAILURE human_action_required=false next_action=RUN_LATER scheduler_should_invoke_again=true shell_code=70 ;;
  *)
    stop_reason=$bounded_stop exit_class=INFRASTRUCTURE_FAILURE human_action_required=true next_action=HUMAN_REVIEW scheduler_should_invoke_again=false shell_code=70 ;;
esac
[[ $bounded_code -eq 0 || $exit_class != SUCCESS_* ]] || { stop_reason=BOUNDED_RUN_FAILED; exit_class=INFRASTRUCTURE_FAILURE; human_action_required=true; next_action=HUMAN_REVIEW; scheduler_should_invoke_again=false; shell_code=70; }
emit_and_exit
