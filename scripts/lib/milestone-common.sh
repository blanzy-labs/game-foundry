#!/usr/bin/env bash

gf_now() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
gf_sha256() { sha256sum "$1" | cut -d' ' -f1; }

gf_error() {
  printf '%s\n' "$*" >&2
  return 1
}

gf_safe_package_file() {
  local package=$1 relative=$2 resolved
  [[ -n $relative && $relative != /* && $relative != *'..'* ]] || return 1
  resolved=$(realpath -m "$package/$relative") || return 1
  [[ $resolved == "$package/"* && -f $resolved ]] || return 1
  printf '%s\n' "$resolved"
}

gf_validate_package() {
  local supplied=$1 task_rel task_file task_id dependency progress all_satisfied
  local -A seen=() processed=()
  [[ -f $GF_SCHEMA_ROOT/milestone.schema.json && -f $GF_SCHEMA_ROOT/task.schema.json ]] || { gf_error 'VALIDATION FAIL: contract schema is missing'; return 1; }
  jq -e . "$GF_SCHEMA_ROOT/milestone.schema.json" "$GF_SCHEMA_ROOT/task.schema.json" >/dev/null 2>&1 || { gf_error 'VALIDATION FAIL: contract schema JSON is invalid'; return 1; }
  GF_PACKAGE=$(realpath "$supplied" 2>/dev/null) || return 1
  GF_MANIFEST="$GF_PACKAGE/milestone.json"
  [[ -f $GF_MANIFEST ]] || { gf_error 'VALIDATION FAIL: milestone.json is missing'; return 1; }
  jq -e . "$GF_MANIFEST" >/dev/null 2>&1 || { gf_error 'VALIDATION FAIL: invalid milestone JSON'; return 1; }
  jq -e '
    (.id | type == "string" and test("^[A-Z0-9][A-Z0-9-]+$")) and
    (.title | type == "string" and length > 0) and
    (.version | type == "number" and . >= 1 and floor == .) and
    (.repository | type == "object") and
    (.repository.name | type == "string" and length > 0) and
    (.repository.path | type == "string" and length > 0) and
    (.design | type == "string" and length > 0) and
    (.guidelines | type == "string" and length > 0) and
    (.tasks | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) and
    (.completion_gate == "human_review" or .completion_gate == "automated")
  ' "$GF_MANIFEST" >/dev/null || { gf_error 'VALIDATION FAIL: milestone contract does not match schema'; return 1; }

  GF_ID=$(jq -r '.id' "$GF_MANIFEST")
  GF_TITLE=$(jq -r '.title' "$GF_MANIFEST")
  GF_DESIGN_REL=$(jq -r '.design' "$GF_MANIFEST")
  GF_GUIDELINES_REL=$(jq -r '.guidelines' "$GF_MANIFEST")
  GF_COMPLETION_GATE=$(jq -r '.completion_gate' "$GF_MANIFEST")
  GF_DESIGN=$(gf_safe_package_file "$GF_PACKAGE" "$GF_DESIGN_REL") || { gf_error 'VALIDATION FAIL: invalid design path'; return 1; }
  GF_GUIDELINES=$(gf_safe_package_file "$GF_PACKAGE" "$GF_GUIDELINES_REL") || { gf_error 'VALIDATION FAIL: invalid guidelines path'; return 1; }

  declare -g -a GF_TASK_ORDER=() GF_TASK_RELS=()
  declare -g -A GF_TASK_FILES=() GF_TASK_DEPS=() GF_TASK_MAX_ATTEMPTS=()
  mapfile -t GF_TASK_RELS < <(jq -r '.tasks[]' "$GF_MANIFEST")
  if [[ $(printf '%s\n' "${GF_TASK_RELS[@]}" | sort | uniq -d | wc -l) -ne 0 ]]; then
    gf_error 'VALIDATION FAIL: duplicate task path'
    return 1
  fi

  for task_rel in "${GF_TASK_RELS[@]}"; do
    task_file=$(gf_safe_package_file "$GF_PACKAGE" "$task_rel") || { gf_error "VALIDATION FAIL: invalid task path $task_rel"; return 1; }
    jq -e . "$task_file" >/dev/null 2>&1 || { gf_error "VALIDATION FAIL: invalid task JSON $task_rel"; return 1; }
    jq -e '
      (.id | type == "string" and test("^[A-Z0-9][A-Z0-9-]+$")) and
      (.title | type == "string" and length > 0) and
      (.objective | type == "string" and length > 0) and
      (.depends_on | type == "array" and all(.[]; type == "string" and test("^[A-Z0-9][A-Z0-9-]+$"))) and
      (.depends_on | length == (unique | length)) and
      (.allowed_scope | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) and
      (.acceptance | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) and
      (.retry_policy | type == "object") and
      (.retry_policy.max_attempts | type == "number" and . >= 1 and floor == .) and
      (.on_failure == "retry" or .on_failure == "escalate")
    ' "$task_file" >/dev/null || { gf_error "VALIDATION FAIL: task contract does not match schema: $task_rel"; return 1; }
    task_id=$(jq -r '.id' "$task_file")
    [[ -z ${seen[$task_id]+x} ]] || { gf_error "VALIDATION FAIL: duplicate task ID $task_id"; return 1; }
    [[ ${task_rel##*/} == "$task_id.json" ]] || { gf_error "VALIDATION FAIL: task filename does not match ID $task_id"; return 1; }
    seen[$task_id]=1
    GF_TASK_ORDER+=("$task_id")
    GF_TASK_FILES[$task_id]=$task_file
    GF_TASK_DEPS[$task_id]=$(jq -r '.depends_on | join(" ")' "$task_file")
    GF_TASK_MAX_ATTEMPTS[$task_id]=$(jq -r '.retry_policy.max_attempts' "$task_file")
  done

  for task_id in "${GF_TASK_ORDER[@]}"; do
    for dependency in ${GF_TASK_DEPS[$task_id]}; do
      [[ $dependency != "$task_id" ]] || { gf_error "VALIDATION FAIL: self dependency $task_id"; return 1; }
      [[ -n ${seen[$dependency]+x} ]] || { gf_error "VALIDATION FAIL: unknown dependency $task_id -> $dependency"; return 1; }
    done
  done

  while ((${#processed[@]} < ${#GF_TASK_ORDER[@]})); do
    progress=false
    for task_id in "${GF_TASK_ORDER[@]}"; do
      [[ -z ${processed[$task_id]+x} ]] || continue
      all_satisfied=true
      for dependency in ${GF_TASK_DEPS[$task_id]}; do
        [[ -n ${processed[$dependency]+x} ]] || { all_satisfied=false; break; }
      done
      if $all_satisfied; then
        processed[$task_id]=1
        progress=true
      fi
    done
    $progress || { gf_error 'VALIDATION FAIL: dependency cycle detected'; return 1; }
  done
}

gf_package_files_json() {
  local relative absolute
  {
    printf '%s\n' 'milestone.json' "$GF_DESIGN_REL" "$GF_GUIDELINES_REL"
    printf '%s\n' "${GF_TASK_RELS[@]}"
  } | while IFS= read -r relative; do
    absolute=$(gf_safe_package_file "$GF_PACKAGE" "$relative") || exit 1
    jq -cn --arg path "$relative" --arg sha256 "$(gf_sha256 "$absolute")" '{path:$path,sha256:$sha256}'
  done | jq -s .
}

gf_tasks_sha256() {
  local relative absolute
  for relative in "${GF_TASK_RELS[@]}"; do
    absolute=$(gf_safe_package_file "$GF_PACKAGE" "$relative") || return 1
    printf '%s %s\n' "$relative" "$(gf_sha256 "$absolute")"
  done | sha256sum | cut -d' ' -f1
}

gf_state_dir() { printf '%s/%s\n' "$GF_STATE_ROOT" "$1"; }

gf_verify_lock() {
  local milestone_id=$1 state_dir lock package relative expected actual
  state_dir=$(gf_state_dir "$milestone_id")
  lock="$state_dir/lock.json"
  [[ -f $lock ]] || { gf_error "LOCK VALIDATION FAIL: state not initialized for $milestone_id"; return 1; }
  jq -e . "$lock" >/dev/null 2>&1 || { gf_error 'LOCK VALIDATION FAIL: lock JSON is invalid'; return 1; }
  package=$(jq -r '.package_path' "$lock")
  while IFS=$'\t' read -r relative expected; do
    [[ -n $relative ]] || continue
    local absolute
    absolute=$(gf_safe_package_file "$package" "$relative") || { gf_error "LOCK VALIDATION FAIL: missing or unsafe file $relative"; return 1; }
    actual=$(gf_sha256 "$absolute")
    [[ $actual == "$expected" ]] || { gf_error "LOCK VALIDATION FAIL: changed file $relative"; return 1; }
  done < <(jq -r '.files[] | [.path,.sha256] | @tsv' "$lock")
  gf_validate_package "$package" || { gf_error 'LOCK VALIDATION FAIL: locked package is no longer valid'; return 1; }
  [[ $GF_ID == "$milestone_id" ]] || { gf_error 'LOCK VALIDATION FAIL: milestone identity changed'; return 1; }
}

gf_append_history() {
  local state_dir=$1 task=$2 from=$3 to=$4 reason=$5 attempts=$6
  jq -cn --arg timestamp "$(gf_now)" --arg task "$task" --arg from "$from" --arg to "$to" --arg reason "$reason" --argjson attempts "$attempts" \
    '{timestamp:$timestamp,task:$task,from:$from,to:$to,reason:$reason,attempts:$attempts}' >>"$state_dir/history.jsonl"
}

gf_atomic_state_update() {
  local state_file=$1 filter=$2
  shift 2
  local temporary
  temporary=$(mktemp "${state_file}.tmp.XXXXXX") || return 1
  if jq "$@" "$filter" "$state_file" >"$temporary"; then
    mv "$temporary" "$state_file"
  else
    rm -f -- "$temporary"
    return 1
  fi
}

gf_recalculate() {
  local milestone_id=$1 state_dir state_file task status desired dependency dependency_status attempts all_pass=true
  state_dir=$(gf_state_dir "$milestone_id")
  state_file="$state_dir/state.json"
  for task in "${GF_TASK_ORDER[@]}"; do
    status=$(jq -r --arg task "$task" '.tasks[$task].status' "$state_file")
    [[ $status == blocked || $status == ready ]] || { [[ $status == pass ]] || all_pass=false; continue; }
    desired=ready
    for dependency in ${GF_TASK_DEPS[$task]}; do
      dependency_status=$(jq -r --arg task "$dependency" '.tasks[$task].status' "$state_file")
      [[ $dependency_status == pass ]] || { desired=blocked; break; }
    done
    if [[ $status != "$desired" ]]; then
      attempts=$(jq -r --arg task "$task" '.tasks[$task].attempts' "$state_file")
      gf_atomic_state_update "$state_file" '.tasks[$task].status=$status' --arg task "$task" --arg status "$desired" || return 1
      gf_append_history "$state_dir" "$task" "$status" "$desired" dependency_recalculation "$attempts"
    fi
    [[ $desired == pass ]] || all_pass=false
  done

  all_pass=true
  for task in "${GF_TASK_ORDER[@]}"; do
    [[ $(jq -r --arg task "$task" '.tasks[$task].status' "$state_file") == pass ]] || { all_pass=false; break; }
  done
  if $all_pass; then
    local final_status=automated_work_complete
    [[ $GF_COMPLETION_GATE == human_review ]] && final_status=pending_human
    gf_atomic_state_update "$state_file" '.status=$status' --arg status "$final_status" || return 1
  else
    gf_atomic_state_update "$state_file" '.status="active"' || return 1
  fi
}

gf_next_result() {
  local milestone_id=$1 state_file task status has_running=false has_blocked=false has_escalated=false
  state_file="$(gf_state_dir "$milestone_id")/state.json"
  for task in "${GF_TASK_ORDER[@]}"; do
    status=$(jq -r --arg task "$task" '.tasks[$task].status' "$state_file")
    case "$status" in
      ready) printf 'NEXT_TASK=%s\n' "$task"; return 0 ;;
      running) has_running=true ;;
      blocked|fail) has_blocked=true ;;
      escalated) has_escalated=true ;;
    esac
  done
  if [[ $(jq -r '.status' "$state_file") == pending_human || $(jq -r '.status' "$state_file") == automated_work_complete ]]; then
    printf 'MILESTONE_COMPLETE\n'
  elif $has_escalated || $has_blocked; then
    printf 'MILESTONE_BLOCKED\n'
  elif $has_running; then
    printf 'NO_READY_TASK\n'
  else
    printf 'NO_READY_TASK\n'
  fi
}
