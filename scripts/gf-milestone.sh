#!/usr/bin/env bash
set -u -o pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GF_SCHEMA_ROOT="$repo_root/schemas"
GF_CONTROL_ROOT="$repo_root"
source "$repo_root/scripts/lib/milestone-common.sh"
source "$repo_root/scripts/lib/gf-004-execution.sh"
source "$repo_root/scripts/lib/gf-005-runner.sh"
source "$repo_root/scripts/lib/gf-008-recovery.sh"
GF_STATE_ROOT=$(realpath -m "${GF_MILESTONE_STATE_ROOT:-$repo_root/state}")
GF_ARTIFACT_ROOT=$(realpath -m "${GF_MILESTONE_ARTIFACT_ROOT:-$repo_root/artifacts/milestones}")
GF_EXECUTION_ARTIFACT_ROOT=$(realpath -m "${GF_EXECUTION_ARTIFACT_ROOT:-$repo_root/artifacts/executions}")
GF_EXECUTION_TMP_ROOT=$(realpath -m "${GF_EXECUTION_TMP_ROOT:-$repo_root/tmp/executions}")
GF_BOUNDED_ARTIFACT_ROOT=$(realpath -m "${GF_BOUNDED_ARTIFACT_ROOT:-$repo_root/artifacts/bounded-runs}")
json_output=false
declare -a positional=()
for argument in "$@"; do
  if [[ $argument == --json ]]; then json_output=true; else positional+=("$argument"); fi
done
set -- "${positional[@]}"

usage() {
  printf 'usage: %s [--json] {validate|init|status|next|transition|render-prompt|dry-run|execute-one|run-bounded|recovery-status|recover} ...\n' "$0" >&2
  exit 2
}

require_state() {
  local milestone_id=$1 state_dir
  state_dir=$(gf_state_dir "$milestone_id")
  [[ -f $state_dir/state.json ]] || { printf 'MILESTONE STATE MISSING: %s\n' "$milestone_id" >&2; return 1; }
}

lock_state() {
  local milestone_id=$1 state_dir
  state_dir=$(gf_state_dir "$milestone_id")
  mkdir -p "$state_dir"
  exec 9>"$state_dir/.state.lock"
  flock -x 9
}

render_prompt() {
  local milestone_id=$1 task_id=$2 state_dir state_file task_file status attempts attempt max_attempts prompt_dir prompt_path
  state_dir=$(gf_state_dir "$milestone_id")
  state_file="$state_dir/state.json"
  task_file=${GF_TASK_FILES[$task_id]:-}
  [[ -n $task_file ]] || { printf 'TASK NOT FOUND: %s\n' "$task_id" >&2; return 1; }
  status=$(jq -r --arg task "$task_id" '.tasks[$task].status' "$state_file")
  [[ $status == ready || ( ${GF_RENDER_ALLOW_RUNNING:-false} == true && $status == running ) ]] || { printf 'PROMPT REJECTED: task %s is %s, not READY\n' "$task_id" "${status^^}" >&2; return 1; }
  attempts=$(jq -r --arg task "$task_id" '.tasks[$task].attempts' "$state_file")
  attempt=$((attempts + 1))
  max_attempts=${GF_TASK_MAX_ATTEMPTS[$task_id]}
  prompt_dir="$GF_ARTIFACT_ROOT/$milestone_id/$task_id"
  prompt_path="$prompt_dir/prompt.md"
  mkdir -p "$prompt_dir"
  {
    printf '# Game Foundry task contract\n\n'
    printf 'MILESTONE_ID=%s\n' "$milestone_id"
    printf 'MILESTONE_TITLE=%s\n' "$GF_TITLE"
    printf 'MILESTONE_DESIGN_SHA256=%s\n' "$(jq -r '.design_sha256' "$state_dir/lock.json")"
    printf 'MILESTONE_LOCK_SHA256=%s\n\n' "$(gf_sha256 "$state_dir/lock.json")"
    printf '## Authoritative design context\n\n'
    cat "$GF_DESIGN"
    printf '\n\n## Global guidelines\n\n'
    cat "$GF_GUIDELINES"
    printf '\n\n## Task\n\n'
    printf 'Task ID: %s\n\n' "$task_id"
    printf 'Title: %s\n\n' "$(jq -r '.title' "$task_file")"
    printf 'Objective: %s\n\n' "$(jq -r '.objective' "$task_file")"
    if [[ -n ${GF_PROMPT_WORKTREE:-} ]]; then
      printf 'Execution worktree: `%s`\n\nChange into that directory before inspecting or modifying repository files.\n\n' "$GF_PROMPT_WORKTREE"
    fi
    printf '## Dependencies already satisfied\n\n'
    if [[ -z ${GF_TASK_DEPS[$task_id]} ]]; then printf -- '- None\n'; else
      for dependency in ${GF_TASK_DEPS[$task_id]}; do printf -- '- %s: PASS\n' "$dependency"; done
    fi
    printf '\n## Allowed source scope\n\n'
    jq -r '.allowed_scope[] | "- " + .' "$task_file"
    printf '\n## Acceptance requirements\n\n'
    jq -r '.acceptance[] | "- " + .' "$task_file"
    printf '\n## Retry attempt\n\nAttempt %d of %d.\n' "$attempt" "$max_attempts"
    printf '\n## Game Foundry safety rules\n\n'
    printf -- '- Inspect before modifying.\n'
    printf -- '- Stay within the declared allowed scope.\n'
    printf -- '- Do not weaken or delete acceptance tests to obtain PASS.\n'
    printf -- '- Do not modify milestone state directly.\n'
    printf -- '- Do not mark your own task PASS.\n'
    printf -- '- Codex completion claims are advisory only.\n'
    printf -- '- Deterministic Game Foundry validation owns acceptance.\n'
    printf -- '- Do not commit, merge, publish, deploy, or release unless explicitly required by a future approved execution policy.\n'
  } >"$prompt_path"
  printf '%s\n' "$prompt_path"
}

command_name=${1:-}
[[ -n $command_name ]] || usage
shift

case "$command_name" in
  validate)
    (($# == 1)) || usage
    package=$1
    if gf_validate_package "$package"; then
      if $json_output; then
        jq -n --arg milestone_id "$GF_ID" --arg title "$GF_TITLE" --argjson tasks "${#GF_TASK_ORDER[@]}" '{valid:true,milestone_id:$milestone_id,title:$title,tasks:$tasks}'
      else
        printf 'MILESTONE VALID\nMILESTONE: %s\nTASKS: %d\n' "$GF_ID" "${#GF_TASK_ORDER[@]}"
      fi
    else
      $json_output && jq -n '{valid:false,error:"MILESTONE INVALID"}'
      exit 1
    fi
    ;;

  init)
    (($# == 1)) || usage
    package=$1
    gf_validate_package "$package" || { $json_output && jq -n '{initialized:false,error:"MILESTONE INVALID"}'; exit 1; }
    state_dir=$(gf_state_dir "$GF_ID")
    [[ ! -e $state_dir/lock.json && ! -e $state_dir/state.json ]] || { printf 'MILESTONE ALREADY INITIALIZED: %s\n' "$GF_ID" >&2; exit 1; }
    mkdir -p "$state_dir"
    lock_state "$GF_ID"
    files_json=$(gf_package_files_json) || exit 1
    tasks_sha=$(gf_tasks_sha256) || exit 1
    jq -n \
      --arg milestone_id "$GF_ID" --arg package_path "$GF_PACKAGE" --arg locked_at "$(gf_now)" \
      --arg design_sha256 "$(gf_sha256 "$GF_DESIGN")" --arg guidelines_sha256 "$(gf_sha256 "$GF_GUIDELINES")" \
      --arg manifest_sha256 "$(gf_sha256 "$GF_MANIFEST")" --arg tasks_sha256 "$tasks_sha" --argjson files "$files_json" \
      '{milestone_id:$milestone_id,locked:true,locked_at:$locked_at,package_path:$package_path,design_sha256:$design_sha256,guidelines_sha256:$guidelines_sha256,manifest_sha256:$manifest_sha256,tasks_sha256:$tasks_sha256,files:$files}' \
      >"$state_dir/lock.json"
    tasks_json=$(
      for task in "${GF_TASK_ORDER[@]}"; do
        initial=blocked
        [[ -z ${GF_TASK_DEPS[$task]} ]] && initial=ready
        jq -cn --arg key "$task" --arg status "$initial" '{key:$key,value:{status:$status,attempts:0}}'
      done | jq -s 'from_entries'
    )
    order_json=$(printf '%s\n' "${GF_TASK_ORDER[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
    jq -n --arg milestone_id "$GF_ID" --arg title "$GF_TITLE" --arg status active --arg completion_gate "$GF_COMPLETION_GATE" \
      --arg package_path "$GF_PACKAGE" --argjson task_order "$order_json" --argjson tasks "$tasks_json" \
      '{milestone_id:$milestone_id,title:$title,status:$status,completion_gate:$completion_gate,package_path:$package_path,task_order:$task_order,tasks:$tasks}' \
      >"$state_dir/state.json"
    if $GF_EXECUTABLE; then
      source_path=$(jq -r '.repository.path' "$GF_MANIFEST")
      if [[ $source_path != /* ]]; then source_path="$GF_CONTROL_ROOT/$source_path"; fi
      source_repo=$(git -C "$source_path" rev-parse --show-toplevel 2>/dev/null) || { printf 'SOURCE INIT FAIL: repository path is not inside Git\n' >&2; exit 1; }
      [[ -z $(git -C "$source_repo" status --short) ]] || { printf 'SOURCE INIT FAIL: repository is not clean\n' >&2; exit 1; }
      source_head=$(git -C "$source_repo" rev-parse HEAD) || exit 1
      source_branch=$(git -C "$source_repo" branch --show-current)
      execution_branch="gf/$GF_ID"
      if git -C "$source_repo" show-ref --verify --quiet "refs/heads/$execution_branch"; then
        [[ $(git -C "$source_repo" rev-parse "$execution_branch") == "$source_head" ]] || { printf 'SOURCE INIT FAIL: execution branch already exists at another commit\n' >&2; exit 1; }
      else
        git -C "$source_repo" branch "$execution_branch" "$source_head" || exit 1
      fi
      gf_atomic_state_update "$state_dir/state.json" '.source={repository_path:$repo,git_root:$repo,base_commit:$head,initial_branch:$branch,execution_branch:$execution_branch,head_commit:$head}' \
        --arg repo "$source_repo" --arg head "$source_head" --arg branch "$source_branch" --arg execution_branch "$execution_branch" || exit 1
    fi
    : >"$state_dir/history.jsonl"
    for task in "${GF_TASK_ORDER[@]}"; do
      initial=$(jq -r --arg task "$task" '.tasks[$task].status' "$state_dir/state.json")
      gf_append_history "$state_dir" "$task" uninitialized "$initial" initialization 0
    done
    if $json_output; then
      jq -n --arg milestone_id "$GF_ID" --arg status active --arg state_path "$state_dir/state.json" '{initialized:true,milestone_id:$milestone_id,status:$status,state_path:$state_path}'
    else
      printf 'MILESTONE: %s\nSTATUS: ACTIVE\n\n' "$GF_ID"
      for task in "${GF_TASK_ORDER[@]}"; do printf '%-14s %s\n' "$task" "$(jq -r --arg task "$task" '.tasks[$task].status | ascii_upcase' "$state_dir/state.json")"; done
    fi
    ;;

  status|next)
    (($# == 1)) || usage
    milestone_id=$1
    require_state "$milestone_id" || exit 1
    lock_state "$milestone_id"
    gf_verify_lock "$milestone_id" || exit 1
    gf_recalculate "$milestone_id" || exit 1
    state_file="$(gf_state_dir "$milestone_id")/state.json"
    next_result=$(gf_next_result "$milestone_id")
    if [[ $command_name == next ]]; then
      if $json_output; then
        case "$next_result" in
          NEXT_TASK=*) jq -n --arg milestone_id "$milestone_id" --arg next_task "${next_result#NEXT_TASK=}" '{milestone_id:$milestone_id,result:"next_task",next_task:$next_task}' ;;
          *) jq -n --arg milestone_id "$milestone_id" --arg result "${next_result,,}" '{milestone_id:$milestone_id,result:$result,next_task:null}' ;;
        esac
      else
        printf '%s\n' "$next_result"
      fi
    elif $json_output; then
      progress=$(jq '[.tasks[] | select(.status == "pass")] | length' "$state_file")
      total=$(jq '.tasks | length' "$state_file")
      jq --arg next "$next_result" --argjson progress "$progress" --argjson total "$total" '. + {progress:{passed:$progress,total:$total},next:$next}' "$state_file"
    else
      printf 'GAME FOUNDRY MILESTONE\n======================\n\n%s — %s\n\n' "$milestone_id" "$GF_TITLE"
      for task in "${GF_TASK_ORDER[@]}"; do printf '%-14s %s\n' "$task" "$(jq -r --arg task "$task" '.tasks[$task].status | ascii_upcase' "$state_file")"; done
      progress=$(jq '[.tasks[] | select(.status == "pass")] | length' "$state_file")
      printf '\nProgress: %s / %s\nNext: %s\n' "$progress" "${#GF_TASK_ORDER[@]}" "${next_result#NEXT_TASK=}"
    fi
    ;;

  transition)
    (($# == 3)) || usage
    milestone_id=$1 task_id=$2 requested=${3,,}
    require_state "$milestone_id" || exit 1
    lock_state "$milestone_id"
    gf_verify_lock "$milestone_id" || exit 1
    gf_recalculate "$milestone_id" || exit 1
    [[ -n ${GF_TASK_FILES[$task_id]:-} ]] || { printf 'TRANSITION REJECTED: unknown task %s\n' "$task_id" >&2; exit 1; }
    gf_transition_task "$milestone_id" "$task_id" "$requested" operator_transition || exit 1
    if $json_output; then
      jq -n --arg milestone_id "$milestone_id" --arg task "$task_id" --arg from "$GF_TRANSITION_FROM" --arg to "$GF_TRANSITION_TO" --argjson attempts "$GF_TRANSITION_ATTEMPTS" '{accepted:true,milestone_id:$milestone_id,task:$task,from:$from,to:$to,attempts:$attempts}'
    else
      printf 'TRANSITION ACCEPTED: %s %s -> %s\n' "$task_id" "${GF_TRANSITION_FROM^^}" "${GF_TRANSITION_TO^^}"
    fi
    ;;

  render-prompt)
    (($# == 2)) || usage
    milestone_id=$1 task_id=$2
    require_state "$milestone_id" || exit 1
    lock_state "$milestone_id"
    gf_verify_lock "$milestone_id" || exit 1
    gf_recalculate "$milestone_id" || exit 1
    prompt_path=$(render_prompt "$milestone_id" "$task_id") || exit 1
    if $json_output; then jq -n --arg milestone_id "$milestone_id" --arg task_id "$task_id" --arg prompt_path "$prompt_path" '{milestone_id:$milestone_id,task_id:$task_id,prompt_path:$prompt_path}'; else printf 'PROMPT=%s\n' "$prompt_path"; fi
    ;;

  dry-run)
    (($# == 1)) || usage
    milestone_id=$1
    require_state "$milestone_id" || exit 1
    lock_state "$milestone_id"
    gf_verify_lock "$milestone_id" || exit 1
    gf_recalculate "$milestone_id" || exit 1
    next_result=$(gf_next_result "$milestone_id")
    [[ $next_result == NEXT_TASK=* ]] || {
      if $json_output; then jq -n --arg milestone_id "$milestone_id" --arg result "${next_result,,}" '{milestone_id:$milestone_id,result:$result,execution:"not_started",codex_invocations:0,source_modifications:0}'; else printf '%s\nExecution: NOT STARTED — DRY RUN\n' "$next_result"; fi
      exit 0
    }
    task_id=${next_result#NEXT_TASK=}
    prompt_path=$(render_prompt "$milestone_id" "$task_id") || exit 1
    attempts=$(jq -r --arg task "$task_id" '.tasks[$task].attempts' "$(gf_state_dir "$milestone_id")/state.json")
    max_attempts=${GF_TASK_MAX_ATTEMPTS[$task_id]}
    if $json_output; then
      jq -n --arg milestone_id "$milestone_id" --arg status active --arg next_task "$task_id" --arg prompt_path "$prompt_path" \
        --argjson attempt "$((attempts + 1))" --argjson max_attempts "$max_attempts" \
        '{milestone_id:$milestone_id,status:$status,design_lock:"pass",next_task:$next_task,dependencies:"pass",attempt:$attempt,max_attempts:$max_attempts,prompt_path:$prompt_path,execution:"not_started",dry_run:true,codex_invocations:0,source_modifications:0}'
    else
      printf 'GAME FOUNDRY MILESTONE DRY RUN\n==============================\n\n'
      printf 'Milestone ........... %s\nStatus .............. ACTIVE\nDesign lock ......... PASS\n\n' "$milestone_id"
      printf 'Next task ........... %s\nDependencies ........ PASS\nAttempt ............. %d / %d\n\n' "$task_id" "$((attempts + 1))" "$max_attempts"
      printf 'Prompt:\n%s\n\nExecution:\nNOT STARTED — DRY RUN\n' "$prompt_path"
    fi
    ;;
  execute-one)
    (($# == 1)) || usage
    gf_execute_one "$1"
    ;;
  run-bounded)
    gf_run_bounded "$@"
    ;;
  recovery-status)
    (($# == 1)) || usage
    milestone_id=$1
    require_state "$milestone_id" || exit 1
    lock_state "$milestone_id"
    gf_verify_lock "$milestone_id" || exit 1
    gf008_classify "$milestone_id" || exit 1
    gf008_emit_status "$milestone_id"
    ;;
  recover)
    (($# == 1)) || usage
    gf008_recover "$1"
    ;;
  *) usage ;;
esac
