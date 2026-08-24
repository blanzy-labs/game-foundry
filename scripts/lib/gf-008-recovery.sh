#!/usr/bin/env bash

GF008_CHECKPOINTS='CLAIMED WORKTREE_READY AGENT_STARTED AGENT_COMPLETED CANDIDATE_SNAPSHOTTED DETERMINISTIC_PASSED CRITIC_STARTED CRITIC_PASSED CRITIC_BLOCKED REPAIR_STARTED REPAIR_AGENT_COMPLETED REPAIR_SNAPSHOTTED REPAIR_DETERMINISTIC_PASSED REPAIR_CRITIC_PASSED REPAIR_CRITIC_BLOCKED ACCEPTED_COMMIT_CREATED CLEANUP_COMPLETED STATE_PASSED STATE_FAILED STATE_ESCALATED'

gf008_boot_id() { cat /proc/sys/kernel/random/boot_id; }
gf008_process_start_ticks() { awk '{print $22}' "/proc/${1:-$$}/stat" 2>/dev/null; }

gf008_atomic_replace() {
  local target=$1 temporary=$2
  jq -e . "$temporary" >/dev/null 2>&1 || { rm -f -- "$temporary"; return 1; }
  sync -f "$temporary" 2>/dev/null || sync "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "$target" || return 1
  sync -f "$(dirname "$target")" 2>/dev/null || true
}

gf008_journal() {
  local event=$1 details=${2:-'{}'}
  [[ -n ${GF004_ARTIFACT_DIR:-} ]] || return 0
  mkdir -p "$GF004_ARTIFACT_DIR"
  jq -cn --arg event "$event" --arg timestamp "$(gf_now)" --argjson details "$details" \
    '{event:$event,timestamp:$timestamp} + $details' >>"$GF004_ARTIFACT_DIR/journal.jsonl"
  sync -f "$GF004_ARTIFACT_DIR/journal.jsonl" 2>/dev/null || true
}

gf008_maybe_crash() {
  local checkpoint=$1
  if [[ ${GF_GF008_ENABLE_TEST_HOOKS:-0} == 1 && ${GF_GF008_PAUSE_AT:-} == "$checkpoint" ]]; then
    sleep "${GF_GF008_PAUSE_SECONDS:-30}"
  fi
  [[ ${GF_GF008_ENABLE_TEST_HOOKS:-0} == 1 && ${GF_GF008_CRASH_AT:-} == "$checkpoint" ]] || return 0
  jq -n --arg checkpoint "$checkpoint" --arg timestamp "$(gf_now)" --arg pid "$$" \
    '{test_hook:true,checkpoint:$checkpoint,timestamp:$timestamp,pid:($pid|tonumber)}' >"$GF004_ARTIFACT_DIR/crash-evidence.json"
  sync -f "$GF004_ARTIFACT_DIR/crash-evidence.json" 2>/dev/null || true
  kill -KILL "$$"
}

gf008_checkpoint() {
  local checkpoint=$1 stage=${2:-${GF004_STAGE_DIR:-}} temporary active_tmp snapshot_ref='' snapshot_commit='' snapshot_tree='' changed='[]'
  [[ " $GF008_CHECKPOINTS " == *" $checkpoint "* ]] || return 1
  if [[ -n ${GF004_SNAPSHOT_REF:-} ]]; then
    snapshot_ref=$GF004_SNAPSHOT_REF snapshot_commit=$GF004_SNAPSHOT_COMMIT snapshot_tree=$GF004_SNAPSHOT_TREE
  fi
  if declare -p GF004_CHANGED_FILES >/dev/null 2>&1; then
    changed=$(printf '%s\n' "${GF004_CHANGED_FILES[@]:-}" | jq -Rsc 'split("\n")|map(select(length>0))')
  fi
  temporary=$(mktemp "$GF004_ARTIFACT_DIR/checkpoint.json.tmp.XXXXXX") || return 1
  jq -n --arg checkpoint "$checkpoint" --arg timestamp "$(gf_now)" --arg milestone "$GF004_MILESTONE" --arg task "$GF004_TASK" \
    --arg run "$GF004_RUN_ID" --arg pre "$GF004_PRE_COMMIT" --arg branch "$GF004_EXECUTION_BRANCH" --arg stage "$stage" \
    --arg snapshot_ref "$snapshot_ref" --arg snapshot_commit "$snapshot_commit" --arg snapshot_tree "$snapshot_tree" \
    --arg accepted "${GF004_ACCEPTED_COMMIT:-}" --argjson candidate "${GF004_CANDIDATE_ORDINAL:-0}" \
    --argjson repair "${GF004_REPAIR_ATTEMPTS_USED:-0}" --argjson changed "$changed" \
    '{version:1,checkpoint:$checkpoint,timestamp:$timestamp,milestone_id:$milestone,task_id:$task,run_id:$run,
      pre_task_commit:$pre,execution_branch:$branch,stage_path:$stage,candidate_ordinal:$candidate,repair_attempt:$repair,
      snapshot:{ref:(if $snapshot_ref=="" then null else $snapshot_ref end),commit:(if $snapshot_commit=="" then null else $snapshot_commit end),tree:(if $snapshot_tree=="" then null else $snapshot_tree end),changed_files:$changed},
      accepted_commit:(if $accepted=="" then null else $accepted end)}' >"$temporary" || return 1
  gf008_atomic_replace "$GF004_ARTIFACT_DIR/checkpoint.json" "$temporary" || return 1
  active_tmp=$(mktemp "$GF004_STATE_FILE.tmp.XXXXXX") || return 1
  jq --arg checkpoint "$checkpoint" --arg updated "$(gf_now)" --arg snapshot_ref "$snapshot_ref" --arg snapshot_commit "$snapshot_commit" \
    --arg snapshot_tree "$snapshot_tree" --arg accepted "${GF004_ACCEPTED_COMMIT:-}" --arg stage "$stage" \
    --argjson candidate "${GF004_CANDIDATE_ORDINAL:-0}" --argjson repair "${GF004_REPAIR_ATTEMPTS_USED:-0}" '
      .active_execution.checkpoint=$checkpoint | .active_execution.updated_at=$updated |
      .active_execution.stage_path=$stage | .active_execution.candidate_ordinal=$candidate |
      .active_execution.repair_attempt=$repair |
      .active_execution.snapshot={ref:(if $snapshot_ref=="" then null else $snapshot_ref end),commit:(if $snapshot_commit=="" then null else $snapshot_commit end),tree:(if $snapshot_tree=="" then null else $snapshot_tree end)} |
      .active_execution.accepted_commit=(if $accepted=="" then null else $accepted end)' "$GF004_STATE_FILE" >"$active_tmp" || return 1
  gf008_atomic_replace "$GF004_STATE_FILE" "$active_tmp" || return 1
  gf008_journal checkpoint "$(jq -cn --arg checkpoint "$checkpoint" '{checkpoint:$checkpoint}')"
  gf008_maybe_crash "$checkpoint"
}

gf008_claim() {
  local max_restarts=${GF_RECOVERY_MAX_AGENT_RESTARTS:-2} lock_sha task_sha
  lock_sha=$(gf_sha256 "$(gf_state_dir "$GF004_MILESTONE")/lock.json")
  task_sha=$(gf_sha256 "${GF_TASK_FILES[$GF004_TASK]}")
  gf_atomic_state_update "$GF004_STATE_FILE" '.active_execution={version:1,task_id:$task,run_id:$run,started_at:$started,updated_at:$started,
      owner:{pid:$pid,boot_id:$boot,process_start_ticks:$ticks},pre_task_commit:$pre,execution_branch:$branch,
      worktree_path:$worktree,artifact_path:$artifact,checkpoint:"CLAIMED",stage_path:"",candidate_ordinal:0,repair_attempt:0,
      snapshot:{ref:null,commit:null,tree:null},accepted_commit:null,integrity:{lock_sha256:$lock_sha,task_sha256:$task_sha},
      policy:{max_agent_restarts:$max_restarts},counters:{recovery_invocations:0,agent_restarts:0,critic_retries:0,commit_reconciliations:0,worktree_recreations:0,repair_resumptions:0}}' \
    --arg task "$GF004_TASK" --arg run "$GF004_RUN_ID" --arg started "$(gf_now)" --argjson pid "$$" --arg boot "$(gf008_boot_id)" \
    --arg ticks "$(gf008_process_start_ticks $$)" --arg pre "$GF004_PRE_COMMIT" --arg branch "$GF004_EXECUTION_BRANCH" \
    --arg worktree "$GF004_WORKSPACE" --arg artifact "$GF004_ARTIFACT_DIR" --arg lock_sha "$lock_sha" --arg task_sha "$task_sha" \
    --argjson max_restarts "$max_restarts" || return 1
  : >"$GF004_ARTIFACT_DIR/journal.jsonl"
  gf008_checkpoint CLAIMED
}

gf008_snapshot_candidate() {
  local ordinal=$1 stage=$2 tree commit ref changed_json temporary
  git -C "$GF004_WORKSPACE" add -A -- "${GF004_CHANGED_FILES[@]}" || return 1
  tree=$(git -C "$GF004_WORKSPACE" write-tree) || return 1
  commit=$(printf 'Game Foundry recovery snapshot %s candidate %s\n' "$GF004_RUN_ID" "$ordinal" | \
    git -C "$GF004_WORKSPACE" -c user.name='Game Foundry Recovery' -c user.email='game-foundry@local.invalid' commit-tree "$tree" -p "$GF004_PRE_COMMIT") || return 1
  ref="refs/game-foundry/recovery/$GF004_RUN_ID/candidate-$(printf '%02d' "$ordinal")"
  git -C "$GF004_REPO" update-ref "$ref" "$commit" || return 1
  git -C "$GF004_WORKSPACE" reset --mixed "$GF004_PRE_COMMIT" >/dev/null || return 1
  GF004_SNAPSHOT_REF=$ref GF004_SNAPSHOT_COMMIT=$commit GF004_SNAPSHOT_TREE=$tree GF004_CANDIDATE_ORDINAL=$ordinal
  changed_json=$(printf '%s\n' "${GF004_CHANGED_FILES[@]}" | jq -Rsc 'split("\n")|map(select(length>0))')
  temporary=$(mktemp "$stage/candidate-snapshot.json.tmp.XXXXXX") || return 1
  jq -n --arg ref "$ref" --arg commit "$commit" --arg tree "$tree" --arg pre "$GF004_PRE_COMMIT" --argjson ordinal "$ordinal" --argjson repair "${GF004_REPAIR_ATTEMPTS_USED:-0}" --argjson changed "$changed_json" \
    '{snapshot_ref:$ref,snapshot_commit:$commit,snapshot_tree:$tree,pre_task_commit:$pre,candidate_ordinal:$ordinal,repair_ordinal:$repair,changed_files:$changed}' >"$temporary"
  gf008_atomic_replace "$stage/candidate-snapshot.json" "$temporary" || return 1
  if ((GF004_REPAIR_ATTEMPTS_USED > 0)); then gf008_checkpoint REPAIR_SNAPSHOTTED "$stage"; else gf008_checkpoint CANDIDATE_SNAPSHOTTED "$stage"; fi
}

gf008_owner_status() {
  local state_file=$1 pid boot ticks current_ticks
  pid=$(jq -r '.active_execution.owner.pid // 0' "$state_file")
  boot=$(jq -r '.active_execution.owner.boot_id // ""' "$state_file")
  ticks=$(jq -r '.active_execution.owner.process_start_ticks // ""' "$state_file")
  [[ -n $boot && $boot == "$(gf008_boot_id)" && $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/stat ]] || { printf stale; return; }
  current_ticks=$(gf008_process_start_ticks "$pid")
  [[ -n $ticks && $ticks == "$current_ticks" ]] && printf live || printf stale
}

gf008_checkpoint_valid() {
  local state_file=$1 checkpoint_file=$2
  jq -e . "$checkpoint_file" >/dev/null 2>&1 || return 1
  jq -e --arg milestone "$GF_ID" --arg task "$(jq -r '.active_execution.task_id' "$state_file")" --arg run "$(jq -r '.active_execution.run_id' "$state_file")" \
    --arg pre "$(jq -r '.active_execution.pre_task_commit' "$state_file")" --arg branch "$(jq -r '.active_execution.execution_branch' "$state_file")" \
    '(.version==1) and .milestone_id==$milestone and .task_id==$task and .run_id==$run and .pre_task_commit==$pre and .execution_branch==$branch and
     (.checkpoint|type=="string") and (.timestamp|type=="string")' "$checkpoint_file" >/dev/null
}

gf008_verify_snapshot() {
  local repo=$1 checkpoint_file=$2 ref commit tree pre actual_tree
  ref=$(jq -r '.snapshot.ref // ""' "$checkpoint_file"); commit=$(jq -r '.snapshot.commit // ""' "$checkpoint_file")
  tree=$(jq -r '.snapshot.tree // ""' "$checkpoint_file"); pre=$(jq -r '.pre_task_commit' "$checkpoint_file")
  [[ -n $ref && -n $commit && -n $tree ]] || return 1
  [[ $(git -C "$repo" rev-parse "$ref" 2>/dev/null) == "$commit" ]] || return 1
  [[ $(git -C "$repo" rev-parse "$commit^" 2>/dev/null) == "$pre" ]] || return 1
  actual_tree=$(git -C "$repo" rev-parse "$commit^{tree}" 2>/dev/null) || return 1
  [[ $actual_tree == "$tree" ]]
}

gf008_classify() {
  local milestone_id=$1 state_file state_dir running task artifact checkpoint_file checkpoint owner branch_head pre accepted action
  state_dir=$(gf_state_dir "$milestone_id"); state_file="$state_dir/state.json"
  running=$(jq -r '[.tasks|to_entries[]|select(.value.status=="running")|.key] | if length==1 then .[0] elif length==0 then "" else "MULTIPLE" end' "$state_file")
  if [[ -z $running ]]; then GF008_ACTION=NO_RECOVERY_NEEDED; GF008_TASK=''; GF008_RUN=''; GF008_OWNER=none; GF008_CHECKPOINT=''; return 0; fi
  [[ $running != MULTIPLE ]] || { GF008_ACTION=ESCALATE; GF008_REASON='multiple RUNNING tasks'; return 0; }
  GF008_TASK=$running
  jq -e --arg task "$running" '.active_execution|type=="object" and .task_id==$task' "$state_file" >/dev/null 2>&1 || { GF008_ACTION=ESCALATE; GF008_REASON='RUNNING task lacks matching active_execution'; return 0; }
  GF008_RUN=$(jq -r '.active_execution.run_id' "$state_file"); artifact=$(jq -r '.active_execution.artifact_path' "$state_file"); checkpoint_file="$artifact/checkpoint.json"
  GF008_ARTIFACT=$artifact GF008_CHECKPOINT_FILE=$checkpoint_file
  GF008_OWNER=$(gf008_owner_status "$state_file")
  if [[ $GF008_OWNER == live ]]; then GF008_ACTION=RECOVERY_BUSY; GF008_CHECKPOINT=$(jq -r '.active_execution.checkpoint // ""' "$state_file"); return 0; fi
  gf008_checkpoint_valid "$state_file" "$checkpoint_file" || { GF008_ACTION=ESCALATE; GF008_REASON='checkpoint missing, corrupt, or contradictory'; return 0; }
  checkpoint=$(jq -r '.checkpoint' "$checkpoint_file"); GF008_CHECKPOINT=$checkpoint
  [[ " $GF008_CHECKPOINTS " == *" $checkpoint "* ]] || { GF008_ACTION=ESCALATE; GF008_REASON='unknown checkpoint'; return 0; }
  [[ $(gf_sha256 "$state_dir/lock.json") == $(jq -r '.active_execution.integrity.lock_sha256' "$state_file") ]] || { GF008_ACTION=ESCALATE; GF008_REASON='milestone lock identity changed'; return 0; }
  [[ $(gf_sha256 "${GF_TASK_FILES[$running]}") == $(jq -r '.active_execution.integrity.task_sha256' "$state_file") ]] || { GF008_ACTION=ESCALATE; GF008_REASON='task identity changed'; return 0; }
  GF008_REPO=$(jq -r '.source.git_root' "$state_file"); pre=$(jq -r '.active_execution.pre_task_commit' "$state_file"); branch_head=$(git -C "$GF008_REPO" rev-parse "$(jq -r '.source.execution_branch' "$state_file")" 2>/dev/null) || { GF008_ACTION=ESCALATE; GF008_REASON='execution branch missing'; return 0; }
  accepted=$(jq -r '.accepted_commit // ""' "$checkpoint_file")
  case "$checkpoint" in
    ACCEPTED_COMMIT_CREATED|CLEANUP_COMPLETED)
      [[ -n $accepted && $branch_head == "$accepted" ]] || { GF008_ACTION=ESCALATE; GF008_REASON='accepted commit and branch disagree'; return 0; } ;;
    *) [[ $branch_head == "$pre" ]] || { GF008_ACTION=ESCALATE; GF008_REASON='unknown execution branch movement'; return 0; } ;;
  esac
  case "$checkpoint" in
    CANDIDATE_SNAPSHOTTED|DETERMINISTIC_PASSED|CRITIC_STARTED|CRITIC_PASSED|CRITIC_BLOCKED|REPAIR_STARTED|REPAIR_AGENT_COMPLETED|REPAIR_SNAPSHOTTED|REPAIR_DETERMINISTIC_PASSED|REPAIR_CRITIC_PASSED|REPAIR_CRITIC_BLOCKED|ACCEPTED_COMMIT_CREATED|CLEANUP_COMPLETED)
      gf008_verify_snapshot "$GF008_REPO" "$checkpoint_file" || { GF008_ACTION=ESCALATE; GF008_REASON='required candidate snapshot is missing or invalid'; return 0; } ;;
  esac
  case "$checkpoint" in
    CLAIMED|WORKTREE_READY|AGENT_STARTED) action=RESTART_TASK ;;
    AGENT_COMPLETED) action=RESTART_TASK ;;
    CANDIDATE_SNAPSHOTTED) action=RESUME_DETERMINISTIC ;;
    DETERMINISTIC_PASSED|CRITIC_STARTED) action=RESUME_CRITIC ;;
    CRITIC_PASSED|REPAIR_CRITIC_PASSED) action=RECONCILE_COMMIT ;;
    CRITIC_BLOCKED|REPAIR_CRITIC_BLOCKED|REPAIR_STARTED|REPAIR_AGENT_COMPLETED) action=RESUME_REPAIR ;;
    REPAIR_SNAPSHOTTED) action=RESUME_REPAIR_DETERMINISTIC ;;
    REPAIR_DETERMINISTIC_PASSED) action=RESUME_REPAIR_CRITIC ;;
    ACCEPTED_COMMIT_CREATED) action=RECONCILE_COMMIT ;;
    CLEANUP_COMPLETED) action=COMPLETE_STATE_PASS ;;
    *) action=ESCALATE; GF008_REASON='terminal or contradictory checkpoint while task is RUNNING' ;;
  esac
  GF008_ACTION=$action
}

gf008_emit_status() {
  local milestone_id=$1
  if $json_output; then
    jq -n --arg milestone_id "$milestone_id" --arg task "${GF008_TASK:-}" --arg run "${GF008_RUN:-}" --arg owner "${GF008_OWNER:-unknown}" \
      --arg checkpoint "${GF008_CHECKPOINT:-}" --arg action "$GF008_ACTION" --arg reason "${GF008_REASON:-}" \
      '{milestone_id:$milestone_id,task_id:(if $task=="" then null else $task end),run_id:(if $run=="" then null else $run end),owner:$owner,
        checkpoint:(if $checkpoint=="" then null else $checkpoint end),recovery_action:$action,reason:(if $reason=="" then null else $reason end)}'
  else
    printf 'GAME FOUNDRY — RECOVERY STATUS\n==============================\n\nMilestone ............ %s\nTask ................. %s\nRun .................. %s\nExecution owner ...... %s\nLast checkpoint ...... %s\nRecovery action ...... %s\n' \
      "$milestone_id" "${GF008_TASK:-NONE}" "${GF008_RUN:-NONE}" "${GF008_OWNER^^}" "${GF008_CHECKPOINT:-NONE}" "$GF008_ACTION"
    [[ -z ${GF008_REASON:-} ]] || printf 'Reason ................ %s\n' "$GF008_REASON"
  fi
}

gf008_restore_worktree() {
  local use_snapshot=${1:-true}
  if git -C "$GF004_REPO" worktree list --porcelain | grep -Fxq "worktree $GF004_WORKSPACE"; then
    git -C "$GF004_REPO" worktree remove --force "$GF004_WORKSPACE" >>"$GF004_ARTIFACT_DIR/worktree.log" 2>&1 || return 1
  elif [[ -e $GF004_WORKSPACE ]]; then
    mv "$GF004_WORKSPACE" "$GF004_ARTIFACT_DIR/interrupted-worktree-$(date -u +%Y%m%dT%H%M%SZ)" || return 1
  fi
  git -C "$GF004_REPO" worktree prune
  mkdir -p "$(dirname "$GF004_WORKSPACE")"
  git -C "$GF004_REPO" worktree add "$GF004_WORKSPACE" "$GF004_EXECUTION_BRANCH" >>"$GF004_ARTIFACT_DIR/worktree.log" 2>&1 || return 1
  if [[ $use_snapshot == true ]]; then
    git -C "$GF004_WORKSPACE" read-tree --reset -u "$GF004_SNAPSHOT_COMMIT" || return 1
  fi
  gf_atomic_state_update "$GF004_STATE_FILE" '.active_execution.counters.worktree_recreations += 1' || return 1
  gf008_journal worktree_recreated "$(jq -cn --argjson snapshot "$([[ $use_snapshot == true ]] && printf true || printf false)" '{from_snapshot:$snapshot}')"
}

gf008_load_execution_context() {
  local milestone_id=$1 active checkpoint task_file
  GF004_TOTAL_START=$(date +%s%N); GF004_MILESTONE=$milestone_id
  GF004_STATE_FILE="$(gf_state_dir "$milestone_id")/state.json"
  active=$(jq '.active_execution' "$GF004_STATE_FILE")
  GF004_TASK=$(jq -r '.task_id' <<<"$active"); GF004_RUN_ID=$(jq -r '.run_id' <<<"$active")
  GF004_REPO=$(jq -r '.source.git_root' "$GF004_STATE_FILE"); GF004_EXECUTION_BRANCH=$(jq -r '.execution_branch' <<<"$active")
  GF004_PRE_COMMIT=$(jq -r '.pre_task_commit' <<<"$active"); GF004_WORKSPACE=$(jq -r '.worktree_path' <<<"$active")
  GF004_ARTIFACT_DIR=$(jq -r '.artifact_path' <<<"$active"); GF004_ARTIFACT_REL=${GF004_ARTIFACT_DIR#"$GF_CONTROL_ROOT/"}
  checkpoint="$GF004_ARTIFACT_DIR/checkpoint.json"; task_file=${GF_TASK_FILES[$GF004_TASK]}
  GF004_STAGE_DIR=$(jq -r '.stage_path // ""' "$checkpoint")
  GF004_CANDIDATE_ORDINAL=$(jq -r '.candidate_ordinal // 0' "$checkpoint")
  GF004_REPAIR_ATTEMPTS_USED=$(jq -r '.repair_attempt // 0' "$checkpoint")
  GF004_SNAPSHOT_REF=$(jq -r '.snapshot.ref // ""' "$checkpoint"); GF004_SNAPSHOT_COMMIT=$(jq -r '.snapshot.commit // ""' "$checkpoint"); GF004_SNAPSHOT_TREE=$(jq -r '.snapshot.tree // ""' "$checkpoint")
  GF004_ACCEPTED_COMMIT=$(jq -r '.accepted_commit // ""' "$checkpoint")
  GF004_ATTEMPT=$(( $(jq -r --arg task "$GF004_TASK" '.tasks[$task].attempts' "$GF004_STATE_FILE") + 1 )); GF004_MAX_ATTEMPTS=${GF_TASK_MAX_ATTEMPTS[$GF004_TASK]}
  GF004_VALIDATOR_REL=$(jq -r '.validation.path' "$task_file"); GF004_VALIDATOR_PRE=''; GF004_VALIDATOR_POST=''; GF004_VALIDATION_EXIT=-1
  GF004_OPENCLAW_EXIT=-1 GF004_AGENT_LINK='' GF004_AGENT_INDEX='' GF004_AGENT_ORIGINAL_WORKSPACE=''
  GF004_RUNTIME_STATUS=not_run GF004_RUNTIME_EVIDENCE='' GF004_SCOPE_STATUS=not_run GF004_VALIDATOR_STATUS=not_run GF004_CANDIDATE_FAILURE=''
  GF004_CRITIC_REQUIRED=$GF_REVIEW_REQUIRED GF004_CRITIC_STATUS=$([[ $GF_REVIEW_REQUIRED == true ]] && printf not_run || printf disabled)
  GF004_CRITIC_MODEL='' GF004_CRITIC_RESPONSE_ID='' GF004_CRITIC_ERROR='' GF004_CRITIC_EVIDENCE_REL=''
  GF004_CRITIC_HISTORY="$GF004_ARTIFACT_DIR/critic-history.json"; GF004_AGENT_HISTORY="$GF004_ARTIFACT_DIR/agent-history.json"
  [[ -f $GF004_CRITIC_HISTORY ]] || printf '[]\n' >"$GF004_CRITIC_HISTORY"; [[ -f $GF004_AGENT_HISTORY ]] || printf '[]\n' >"$GF004_AGENT_HISTORY"
  GF004_CRITIC_CALLS=$(jq 'length' "$GF004_CRITIC_HISTORY"); GF004_CODEX_INVOCATIONS=$(jq 'length' "$GF004_AGENT_HISTORY")
  GF004_CRITIC_BLOCKERS=0 GF004_CRITIC_WARNINGS=0 GF004_CRITIC_OBSERVATIONS=0 GF004_CRITIC_DURATION=0 GF004_CRITIC_INPUT_TOKENS=0 GF004_CRITIC_OUTPUT_TOKENS=0
  GF004_REPAIR_ENABLED=$GF_REPAIR_ENABLED GF004_REPAIR_MAX_ATTEMPTS=$GF_REPAIR_MAX_ATTEMPTS GF004_REPAIR_OUTCOME=not_needed
  GF004_REPAIR_CODEX_CALLS=$(jq '[.[]|select(.kind=="repair")]|length' "$GF004_AGENT_HISTORY")
  GF004_REPAIR_CRITIC_CALLS=$(jq '[.[]|select(.candidate>1)]|length' "$GF004_CRITIC_HISTORY")
  GF004_REPAIR_SUCCESSES=0 GF004_REPAIR_EXHAUSTIONS=0 GF004_REPAIR_CODEX_DURATION=0 GF004_REPAIR_CRITIC_DURATION=0
  GF004_T_SELECTION=0 GF004_T_PROMPT=0 GF004_T_AGENT=0 GF004_T_SCOPE=0 GF004_T_VALIDATION=0 GF004_T_CRITIC=0 GF004_T_COMMIT=0 GF004_T_STATE=0 GF004_T_CLEANUP=0 GF004_T_TOTAL=0
  declare -g -a GF004_CHANGED_FILES=() GF004_MARKERS=() GF004_SCOPE_PATTERNS=()
  mapfile -t GF004_SCOPE_PATTERNS < <(jq -r '.allowed_scope[]' "$task_file"); mapfile -t GF004_MARKERS < <(jq -r '.validation.success_markers[]' "$task_file")
  mapfile -t GF004_CHANGED_FILES < <(jq -r '.snapshot.changed_files[]?' "$checkpoint")
}

gf008_load_validation_evidence() {
  local stage=$1 validator_abs=$2 marker
  [[ -f $stage/scope.json && -f $stage/validator-integrity.json && -f $stage/validation.stdout.log ]] || return 1
  jq -e '.status=="pass"' "$stage/scope.json" >/dev/null || return 1
  jq -e '.status=="pass" and .pre_sha256==.post_sha256' "$stage/validator-integrity.json" >/dev/null || return 1
  GF004_VALIDATOR_PRE=$(jq -r '.pre_sha256' "$stage/validator-integrity.json"); GF004_VALIDATOR_POST=$(jq -r '.post_sha256' "$stage/validator-integrity.json")
  [[ $(gf_sha256 "$validator_abs") == "$GF004_VALIDATOR_PRE" ]] || return 1
  for marker in "${GF004_MARKERS[@]}"; do grep -Fq -- "$marker" "$stage/validation.stdout.log" || return 1; done
  GF004_SCOPE_STATUS=pass GF004_VALIDATOR_STATUS=pass GF004_VALIDATION_EXIT=0
  return 0
}

gf008_verify_critic_pass() {
  local stage=$1
  [[ -f $stage/critic/result.json && -f $stage/critic/review.json && -f $stage/critic/evidence.json ]] || return 1
  jq -e '.status=="pass" and .finding_counts.blocker==0' "$stage/critic/result.json" >/dev/null || return 1
  jq -e '.decision=="pass" and ([.findings[]|select(.severity=="blocker")]|length)==0' "$stage/critic/review.json" >/dev/null || return 1
}

gf008_commit_matches() {
  local commit=$1 task_file=$2 parent tree author message expected_message changed expected_changed
  parent=$(git -C "$GF004_REPO" rev-parse "$commit^" 2>/dev/null) || return 1
  tree=$(git -C "$GF004_REPO" rev-parse "$commit^{tree}" 2>/dev/null) || return 1
  author=$(git -C "$GF004_REPO" show -s --format='%an <%ae>' "$commit")
  message=$(git -C "$GF004_REPO" show -s --format='%s' "$commit")
  expected_message="$GF004_TASK: $(jq -r '.title' "$task_file")"
  [[ $parent == "$GF004_PRE_COMMIT" && $tree == "$GF004_SNAPSHOT_TREE" && $author == 'Game Foundry <game-foundry@local.invalid>' && $message == "$expected_message" ]] || return 1
  changed=$(git -C "$GF004_REPO" diff-tree --no-commit-id --name-only -r "$commit" | LC_ALL=C sort)
  expected_changed=$(printf '%s\n' "${GF004_CHANGED_FILES[@]}" | LC_ALL=C sort)
  [[ $changed == "$expected_changed" ]]
}

gf008_escalate_recovery() {
  local milestone_id=$1 reason=$2 state_file task run artifact result_file
  state_file="$(gf_state_dir "$milestone_id")/state.json"; task=${GF008_TASK:-$(jq -r '.active_execution.task_id // ""' "$state_file")}; run=${GF008_RUN:-$(jq -r '.active_execution.run_id // ""' "$state_file")}
  artifact=${GF008_ARTIFACT:-$(jq -r '.active_execution.artifact_path // empty' "$state_file")}; [[ -n $artifact ]] || artifact="$GF_EXECUTION_ARTIFACT_ROOT/$milestone_id/recovery-unknown"
  mkdir -p "$artifact"; result_file="$artifact/recovery-result.json"
  if [[ -n $task ]]; then
    gf_transition_task "$milestone_id" "$task" escalated recovery_evidence_ambiguous || true
    gf_atomic_state_update "$state_file" '.tasks[$task].recovery_execution=.active_execution | .tasks[$task].last_result="escalated" | .tasks[$task].failure_reason=$reason | del(.active_execution)' --arg task "$task" --arg reason "$reason" || true
  fi
  jq -n --arg milestone_id "$milestone_id" --arg task "$task" --arg run "$run" --arg checkpoint "${GF008_CHECKPOINT:-}" --arg action ESCALATE --arg reason "$reason" \
    '{milestone_id:$milestone_id,task_id:(if $task=="" then null else $task end),run_id:(if $run=="" then null else $run end),original_checkpoint:(if $checkpoint=="" then null else $checkpoint end),recovery_action:$action,result:"escalated",failure_reason:$reason,codex_calls:0,critic_calls:0,commit:{created:false,sha:null}}' >"$result_file"
  if $json_output; then cat "$result_file"; else printf 'GAME FOUNDRY — RECOVERY\nRecovery action ....... ESCALATE\nReason ................ %s\n' "$reason"; fi
  return 1
}

gf008_prepare_recovery_owner() {
  gf_atomic_state_update "$GF004_STATE_FILE" '.active_execution.owner={pid:$pid,boot_id:$boot,process_start_ticks:$ticks} |
    .active_execution.counters.recovery_invocations += 1 | .active_execution.updated_at=$now' \
    --argjson pid "$$" --arg boot "$(gf008_boot_id)" --arg ticks "$(gf008_process_start_ticks $$)" --arg now "$(gf_now)"
}

gf008_finish_pass() {
  local original=$1 action=$2 created=$3 task_file=$4 next_result next_task='' result_file cleanup_start
  if [[ $action == RECONCILE_COMMIT || $action == COMPLETE_STATE_PASS ]]; then
    gf008_commit_matches "$GF004_ACCEPTED_COMMIT" "$task_file" || { gf008_escalate_recovery "$GF004_MILESTONE" 'accepted commit verification failed'; return 1; }
  fi
  cleanup_start=$(date +%s%N)
  if [[ -d $GF004_WORKSPACE ]] || git -C "$GF004_REPO" worktree list --porcelain | grep -Fxq "worktree $GF004_WORKSPACE"; then git -C "$GF004_REPO" worktree remove --force "$GF004_WORKSPACE" >>"$GF004_ARTIFACT_DIR/worktree.log" 2>&1 || return 1; fi
  gf004_restore_agent_workspace
  gf008_checkpoint CLEANUP_COMPLETED "$GF004_STAGE_DIR" || return 1
  GF004_T_CLEANUP=$(gf004_elapsed "$cleanup_start" "$(date +%s%N)")
  gf_transition_task "$GF004_MILESTONE" "$GF004_TASK" pass recovery_reconciliation || return 1
  gf_atomic_state_update "$GF004_STATE_FILE" '.source.head_commit=$commit | .tasks[$task] += {last_run_id:$run,accepted_commit:$commit,last_result:"pass",last_evidence:$evidence,critic_status:$critic_status,repair_attempts:$repairs,repair_outcome:$outcome}' \
    --arg task "$GF004_TASK" --arg run "$GF004_RUN_ID" --arg commit "$GF004_ACCEPTED_COMMIT" --arg evidence "$GF004_ARTIFACT_REL" --arg critic_status "$GF004_CRITIC_STATUS" --argjson repairs "$GF004_REPAIR_ATTEMPTS_USED" --arg outcome "$GF004_REPAIR_OUTCOME" || return 1
  gf008_checkpoint STATE_PASSED "$GF004_STAGE_DIR" || return 1
  recovery_counters=$(jq '.active_execution.counters' "$GF004_STATE_FILE")
  gf_atomic_state_update "$GF004_STATE_FILE" 'del(.active_execution)' || return 1
  git -C "$GF004_REPO" for-each-ref --format='%(refname)' "refs/game-foundry/recovery/$GF004_RUN_ID/" | while IFS= read -r recovery_ref; do [[ -z $recovery_ref ]] || git -C "$GF004_REPO" update-ref -d "$recovery_ref"; done
  next_result=$(gf_next_result "$GF004_MILESTONE"); [[ $next_result == NEXT_TASK=* ]] && next_task=${next_result#NEXT_TASK=}
  result_file="$GF004_ARTIFACT_DIR/recovery-result.json"
  jq -n --arg milestone_id "$GF004_MILESTONE" --arg task "$GF004_TASK" --arg run "$GF004_RUN_ID" --arg original "$original" --arg action "$action" \
    --arg commit "$GF004_ACCEPTED_COMMIT" --arg next "$next_task" --argjson created "$created" --argjson codex "${GF008_RECOVERY_CODEX_CALLS:-0}" --argjson critic "${GF008_RECOVERY_CRITIC_CALLS:-0}" \
    --argjson counters "$recovery_counters" --argjson reused_codex "$([[ $action != RESTART_TASK ]] && printf true || printf false)" --argjson reused_validation "$([[ $original == DETERMINISTIC_PASSED || $original == CRITIC_* || $original == REPAIR_DETERMINISTIC_PASSED || $original == REPAIR_CRITIC_* ]] && printf true || printf false)" \
    '{milestone_id:$milestone_id,task_id:$task,run_id:$run,original_checkpoint:$original,recovery_action:$action,result:"pass",resumed_from:($original|ascii_downcase),codex_calls:$codex,critic_calls:$critic,commit:{created:$created,sha:$commit},state:{task:"pass",next_task:(if $next=="" then null else $next end)},counters:$counters,work_reused:{codex_candidate:$reused_codex,deterministic_result:$reused_validation,critic_result:($action=="RECONCILE_COMMIT" or $action=="COMPLETE_STATE_PASS")},human_interventions:0}' >"$result_file"
  gf008_journal recovery_completed "$(jq -cn --arg result pass '{result:$result}')"
  if $json_output; then cat "$result_file"; else printf 'GAME FOUNDRY — RECOVERY\n=======================\n\nMilestone ............ %s\nTask .................. %s\nRun ................... %s\nRecovery action ....... %s\nTask .................. PASS\nNext READY ............ %s\nCodex calls ........... %s\nCritic calls .......... %s\n' "$GF004_MILESTONE" "$GF004_TASK" "$GF004_RUN_ID" "$action" "${next_task:-NONE}" "${GF008_RECOVERY_CODEX_CALLS:-0}" "${GF008_RECOVERY_CRITIC_CALLS:-0}"; fi
}

gf008_fail_recovery() {
  local reason=$1 result_file="$GF004_ARTIFACT_DIR/recovery-result.json"
  if [[ -d $GF004_WORKSPACE ]] || git -C "$GF004_REPO" worktree list --porcelain | grep -Fxq "worktree $GF004_WORKSPACE"; then git -C "$GF004_REPO" worktree remove --force "$GF004_WORKSPACE" >>"$GF004_ARTIFACT_DIR/worktree.log" 2>&1 || true; fi
  gf004_restore_agent_workspace
  gf_transition_task "$GF004_MILESTONE" "$GF004_TASK" fail recovery_failure || true
  gf_atomic_state_update "$GF004_STATE_FILE" '.tasks[$task] += {last_run_id:$run,last_result:"fail",last_evidence:$evidence,failure_reason:$reason} | del(.active_execution)' \
    --arg task "$GF004_TASK" --arg run "$GF004_RUN_ID" --arg evidence "$GF004_ARTIFACT_REL" --arg reason "$reason" || true
  jq -n --arg milestone_id "$GF004_MILESTONE" --arg task "$GF004_TASK" --arg run "$GF004_RUN_ID" --arg checkpoint "$GF008_CHECKPOINT" --arg action "$GF008_ACTION" --arg reason "$reason" \
    --argjson codex "${GF008_RECOVERY_CODEX_CALLS:-0}" --argjson critic "${GF008_RECOVERY_CRITIC_CALLS:-0}" \
    '{milestone_id:$milestone_id,task_id:$task,run_id:$run,original_checkpoint:$checkpoint,recovery_action:$action,result:"fail",failure_reason:$reason,codex_calls:$codex,critic_calls:$critic,commit:{created:false,sha:null}}' >"$result_file"
  if $json_output; then cat "$result_file"; else printf 'GAME FOUNDRY — RECOVERY\nTask result ........... FAIL\nFailure ............... %s\n' "$reason"; fi
  return 1
}

gf008_create_accepted_commit() {
  local task_file=$1 message
  [[ $(git -C "$GF004_REPO" rev-parse "$GF004_EXECUTION_BRANCH") == "$GF004_PRE_COMMIT" ]] || return 1
  git -C "$GF004_WORKSPACE" reset >/dev/null || return 1
  git -C "$GF004_WORKSPACE" add -- "${GF004_CHANGED_FILES[@]}" || return 1
  [[ $(git -C "$GF004_WORKSPACE" write-tree) == "$GF004_SNAPSHOT_TREE" ]] || return 1
  message="$GF004_TASK: $(jq -r '.title' "$task_file")"
  git -C "$GF004_WORKSPACE" -c user.name='Game Foundry' -c user.email='game-foundry@local.invalid' commit -m "$message" >"$GF004_ARTIFACT_DIR/commit.log" 2>&1 || return 1
  GF004_ACCEPTED_COMMIT=$(git -C "$GF004_WORKSPACE" rev-parse HEAD)
  gf008_commit_matches "$GF004_ACCEPTED_COMMIT" "$task_file" || return 1
  jq -n --arg pre_task_commit "$GF004_PRE_COMMIT" --arg accepted_commit "$GF004_ACCEPTED_COMMIT" --arg message "$message" --arg run "$GF004_RUN_ID" --arg task "$GF004_TASK" \
    --argjson changed_files "$(printf '%s\n' "${GF004_CHANGED_FILES[@]}" | jq -Rsc 'split("\n")|map(select(length>0))')" \
    '{pre_task_commit:$pre_task_commit,accepted_commit:$accepted_commit,commit_message:$message,changed_files:$changed_files,owner:"Game Foundry",run_id:$run,task_id:$task}' >"$GF004_ARTIFACT_DIR/commit.json"
  gf008_checkpoint ACCEPTED_COMMIT_CREATED "$GF004_STAGE_DIR"
}

gf008_recover() {
  local milestone_id=$1 state_dir original action task_file validator_abs validator_real stage prompt_generated test_fault='' repair_fault='' agent_ok runtime_ok
  local agent_start agent_duration critic_code candidate repair previous_review created=false max_restarts restarts
  state_dir=$(gf_state_dir "$milestone_id")
  [[ -f $state_dir/state.json ]] || { gf_error "MILESTONE STATE MISSING: $milestone_id"; return 1; }
  mkdir -p "$state_dir"; exec 8>"$state_dir/.execution.lock"
  if ! flock -n 8; then
    GF008_ACTION=RECOVERY_BUSY GF008_TASK='' GF008_RUN='' GF008_OWNER=live GF008_CHECKPOINT=''
    gf008_emit_status "$milestone_id"; return 2
  fi
  lock_state "$milestone_id"; gf_verify_lock "$milestone_id" || return 1
  gf008_classify "$milestone_id" || return 1
  case "$GF008_ACTION" in
    NO_RECOVERY_NEEDED) gf008_emit_status "$milestone_id"; return 0 ;;
    RECOVERY_BUSY) gf008_emit_status "$milestone_id"; return 2 ;;
    ESCALATE) gf008_escalate_recovery "$milestone_id" "${GF008_REASON:-ambiguous recovery evidence}"; return $? ;;
  esac
  original=$GF008_CHECKPOINT action=$GF008_ACTION
  gf008_load_execution_context "$milestone_id" || return 1
  task_file=${GF_TASK_FILES[$GF004_TASK]}; validator_abs="$GF004_WORKSPACE/$GF004_VALIDATOR_REL"
  GF008_RECOVERY_CODEX_CALLS=0 GF008_RECOVERY_CRITIC_CALLS=0
  gf008_prepare_recovery_owner || return 1
  flock -u 9
  gf008_journal owner_stale_detected
  gf008_journal recovery_started "$(jq -cn --arg action "$action" --arg checkpoint "$original" '{action:$action,checkpoint:$checkpoint}')"

  if [[ $action == COMPLETE_STATE_PASS ]]; then
    GF004_CRITIC_STATUS=pass
    gf008_finish_pass "$original" "$action" false "$task_file"; return $?
  fi

  if [[ $action == RECONCILE_COMMIT && $original == ACCEPTED_COMMIT_CREATED ]]; then
    [[ -f $GF004_ARTIFACT_DIR/commit.json ]] || { gf008_escalate_recovery "$milestone_id" 'accepted commit record missing'; return 1; }
    GF004_ACCEPTED_COMMIT=$(jq -r '.accepted_commit' "$GF004_ARTIFACT_DIR/commit.json")
    gf008_commit_matches "$GF004_ACCEPTED_COMMIT" "$task_file" || { gf008_escalate_recovery "$milestone_id" 'accepted commit evidence contradicts branch'; return 1; }
    gf_atomic_state_update "$GF004_STATE_FILE" '.active_execution.counters.commit_reconciliations += 1' || return 1
    GF004_CRITIC_STATUS=pass
    gf008_journal accepted_commit_reconciled "$(jq -cn --arg sha "$GF004_ACCEPTED_COMMIT" '{sha:$sha}')"
    gf008_finish_pass "$original" "$action" false "$task_file"; return $?
  fi

  if [[ $action == RESUME_CRITIC || $action == RESUME_REPAIR || $action == RESUME_REPAIR_CRITIC || ($action == RESTART_TASK && $GF004_CRITIC_REQUIRED == true) || ($action == RESUME_DETERMINISTIC && $GF004_CRITIC_REQUIRED == true) || ($action == RESUME_REPAIR_DETERMINISTIC && $GF004_CRITIC_REQUIRED == true) ]]; then
    gf004_critic_preflight || { gf008_fail_recovery "CRITIC_ERROR: $GF004_CRITIC_ERROR"; return 1; }
  fi

  case "$action" in
    RESTART_TASK)
      restarts=$(jq -r '.active_execution.counters.agent_restarts' "$GF004_STATE_FILE"); max_restarts=$(jq -r '.active_execution.policy.max_agent_restarts' "$GF004_STATE_FILE")
      if ((restarts >= max_restarts)); then gf008_escalate_recovery "$milestone_id" 'recovery agent restart budget exhausted'; return 1; fi
      if [[ -d $GF004_WORKSPACE ]]; then
        mkdir -p "$GF004_ARTIFACT_DIR/interruption-evidence"
        git -C "$GF004_WORKSPACE" diff --binary >"$GF004_ARTIFACT_DIR/interruption-evidence/partial.patch" 2>/dev/null || true
      fi
      gf008_restore_worktree false || { gf008_escalate_recovery "$milestone_id" 'could not recreate worktree from accepted HEAD'; return 1; }
      gf_atomic_state_update "$GF004_STATE_FILE" '.active_execution.counters.agent_restarts += 1' || return 1
      stage="$GF004_ARTIFACT_DIR/attempt-01"; GF004_STAGE_DIR=$stage; mkdir -p "$stage"
      GF_RENDER_ALLOW_RUNNING=true GF_PROMPT_WORKTREE=workspace prompt_generated=$(render_prompt "$milestone_id" "$GF004_TASK") || { gf008_fail_recovery 'authoritative prompt rendering failed'; return 1; }
      cp "$prompt_generated" "$stage/prompt.md"
      GF004_REPAIR_ATTEMPTS_USED=0 GF004_CANDIDATE_ORDINAL=1
      gf008_checkpoint AGENT_STARTED "$stage" || return 1
      test_fault=''; [[ ${GF_GF004_ENABLE_TEST_HOOKS:-0} == 1 ]] && test_fault=${GF_GF004_FAULT:-simulate_success}
      agent_start=$(date +%s%N); GF008_RECOVERY_CODEX_CALLS=1; GF004_CODEX_INVOCATIONS=$((GF004_CODEX_INVOCATIONS + 1))
      if [[ -n $test_fault ]]; then gf004_test_agent "$GF004_WORKSPACE" "$stage" "$test_fault"; agent_ok=$?; else gf004_real_agent "$GF004_WORKSPACE" "$stage/prompt.md" "$stage" "$GF004_RUN_ID-recovery-initial"; agent_ok=$?; fi
      agent_duration=$(gf004_elapsed "$agent_start" "$(date +%s%N)")
      [[ $agent_ok -eq 0 ]] || { gf008_fail_recovery "OpenClaw/Codex recovery execution failed (exit $GF004_OPENCLAW_EXIT)"; return 1; }
      if [[ -n $test_fault ]]; then runtime_ok=true; elif gf004_runtime_is_proven "$stage"; then runtime_ok=true; else runtime_ok=false; fi
      $runtime_ok || { gf008_fail_recovery 'Codex runtime ownership was not proven'; return 1; }
      GF004_RUNTIME_STATUS=pass; gf004_append_agent_history initial 1 "$stage" "$agent_duration" pass || return 1
      gf008_checkpoint AGENT_COMPLETED "$stage" || return 1
      ;;
    *)
      gf008_restore_worktree true || { gf008_escalate_recovery "$milestone_id" 'could not recreate worktree from candidate snapshot'; return 1; }
      stage=$GF004_STAGE_DIR
      ;;
  esac

  validator_abs="$GF004_WORKSPACE/$GF004_VALIDATOR_REL"
  [[ $GF004_VALIDATOR_REL != /* && $GF004_VALIDATOR_REL != *'..'* && -f $validator_abs && -x $validator_abs && ! -L $validator_abs ]] || { gf008_escalate_recovery "$milestone_id" 'validator path no longer trustworthy'; return 1; }
  validator_real=$(realpath "$validator_abs") || return 1; [[ $validator_real == "$GF004_WORKSPACE/"* ]] || { gf008_escalate_recovery "$milestone_id" 'validator escapes worktree'; return 1; }
  GF004_VALIDATOR_PRE=$(gf_sha256 "$validator_abs")

  case "$action" in
    RESTART_TASK|RESUME_DETERMINISTIC)
      GF004_REPAIR_ATTEMPTS_USED=0; GF004_CANDIDATE_ORDINAL=1
      gf004_validate_candidate "$task_file" "$validator_abs" "$stage" || { gf008_fail_recovery "$GF004_CANDIDATE_FAILURE"; return 1; }
      ;;
    RESUME_REPAIR_DETERMINISTIC)
      GF004_CANDIDATE_ORDINAL=$((GF004_REPAIR_ATTEMPTS_USED + 1))
      gf004_validate_candidate "$task_file" "$validator_abs" "$stage" || { gf008_fail_recovery "$GF004_CANDIDATE_FAILURE"; return 1; }
      ;;
    *)
      gf008_load_validation_evidence "$stage" "$validator_abs" || { gf008_escalate_recovery "$milestone_id" 'deterministic PASS evidence is incomplete or contradictory'; return 1; }
      ;;
  esac

  if [[ $action == RECONCILE_COMMIT ]]; then
    gf008_verify_critic_pass "$stage" || { gf008_escalate_recovery "$milestone_id" 'critic PASS evidence is incomplete'; return 1; }
    GF004_CRITIC_STATUS=pass
  elif [[ $action == RESUME_REPAIR || $action == RESUME_REPAIR_CRITIC ]]; then
    :
  else
    if [[ $original == CRITIC_STARTED ]]; then
      [[ -d $stage/critic ]] && mv "$stage/critic" "$stage/critic-interrupted-$(date -u +%Y%m%dT%H%M%SZ)"
      gf_atomic_state_update "$GF004_STATE_FILE" '.active_execution.counters.critic_retries += 1' || return 1
    fi
    GF004_STAGE_DIR=$stage; GF004_CRITIC_EVIDENCE_REL="${stage#"$GF_CONTROL_ROOT/"}/critic"; GF008_RECOVERY_CRITIC_CALLS=$((GF008_RECOVERY_CRITIC_CALLS + 1))
    gf004_run_critic "$task_file" "$validator_abs" "$GF004_CANDIDATE_ORDINAL"; critic_code=$?
    if [[ $critic_code -ne 0 && $critic_code -ne 3 ]]; then gf008_fail_recovery "CRITIC_ERROR: ${GF004_CRITIC_ERROR:-invalid critic result}"; return 1; fi
    [[ $critic_code -eq 3 ]] && action=RESUME_REPAIR
  fi

  if [[ $action == RESUME_REPAIR || $action == RESUME_REPAIR_CRITIC ]]; then
    if [[ $action == RESUME_REPAIR_CRITIC ]]; then
      GF004_STAGE_DIR=$stage; GF008_RECOVERY_CRITIC_CALLS=$((GF008_RECOVERY_CRITIC_CALLS + 1))
      gf004_run_critic "$task_file" "$validator_abs" "$GF004_CANDIDATE_ORDINAL"; critic_code=$?
      if [[ $critic_code -eq 0 ]]; then action=RECONCILE_COMMIT; else [[ $critic_code -eq 3 ]] || { gf008_fail_recovery "CRITIC_ERROR: ${GF004_CRITIC_ERROR:-invalid critic result}"; return 1; }; action=RESUME_REPAIR; fi
    fi
    if [[ $action == RESUME_REPAIR ]]; then
      repair=$GF004_REPAIR_ATTEMPTS_USED
      if [[ $original == CRITIC_BLOCKED || $original == REPAIR_CRITIC_BLOCKED ]]; then repair=$((repair + 1)); fi
      ((repair < 1)) && repair=1
      for ((; repair<=GF004_REPAIR_MAX_ATTEMPTS; repair++)); do
        previous_review=$(jq -r '[.[]|select(.result=="block")][-1].evidence_path // ""' "$GF004_CRITIC_HISTORY")/review.json
        [[ -f $previous_review ]] || { gf008_escalate_recovery "$milestone_id" 'repair blocker evidence missing'; return 1; }
        GF004_REPAIR_ATTEMPTS_USED=$repair; GF004_CANDIDATE_ORDINAL=$((repair + 1)); GF004_REPAIR_OUTCOME=failed
        stage="$GF004_ARTIFACT_DIR/repair-$(printf '%02d' "$repair")"; GF004_STAGE_DIR=$stage; mkdir -p "$stage"
        gf004_render_repair_prompt "$task_file" "$repair" "$previous_review" "$stage/prompt.md" || return 1
        gf_atomic_state_update "$GF004_STATE_FILE" '.active_execution.counters.repair_resumptions += 1' || return 1
        gf008_checkpoint REPAIR_STARTED "$stage" || return 1
        repair_fault=''; [[ ${GF_GF007_REPAIR_AGENT_TEST_DOUBLE:-0} == 1 ]] && repair_fault=${GF_GF007_REPAIR_FAULT:-repair_success}
        agent_start=$(date +%s%N); GF008_RECOVERY_CODEX_CALLS=$((GF008_RECOVERY_CODEX_CALLS + 1)); GF004_CODEX_INVOCATIONS=$((GF004_CODEX_INVOCATIONS + 1)); GF004_REPAIR_CODEX_CALLS=$((GF004_REPAIR_CODEX_CALLS + 1))
        if [[ -n $repair_fault ]]; then gf004_test_repair_agent "$GF004_WORKSPACE" "$stage" "$repair_fault"; agent_ok=$?; else gf004_real_agent "$GF004_WORKSPACE" "$stage/prompt.md" "$stage" "$GF004_RUN_ID-recovery-repair-$repair"; agent_ok=$?; fi
        agent_duration=$(gf004_elapsed "$agent_start" "$(date +%s%N)")
        [[ $agent_ok -eq 0 ]] || { gf008_fail_recovery "OpenClaw/Codex repair recovery failed (exit $GF004_OPENCLAW_EXIT)"; return 1; }
        if [[ -n $repair_fault ]]; then runtime_ok=true; elif gf004_runtime_is_proven "$stage"; then runtime_ok=true; else runtime_ok=false; fi
        $runtime_ok || { gf008_fail_recovery 'Codex repair runtime ownership was not proven'; return 1; }
        gf004_append_agent_history repair "$repair" "$stage" "$agent_duration" pass || return 1; gf008_checkpoint REPAIR_AGENT_COMPLETED "$stage" || return 1
        gf004_validate_candidate "$task_file" "$validator_abs" "$stage" "$repair_fault" || { gf008_fail_recovery "$GF004_CANDIDATE_FAILURE"; return 1; }
        GF008_RECOVERY_CRITIC_CALLS=$((GF008_RECOVERY_CRITIC_CALLS + 1)); gf004_run_critic "$task_file" "$validator_abs" "$GF004_CANDIDATE_ORDINAL"; critic_code=$?
        if [[ $critic_code -eq 0 ]]; then GF004_REPAIR_OUTCOME=repaired; GF004_REPAIR_SUCCESSES=1; action=RECONCILE_COMMIT; break; fi
        [[ $critic_code -eq 3 ]] || { gf008_fail_recovery "CRITIC_ERROR: ${GF004_CRITIC_ERROR:-invalid repair critic result}"; return 1; }
      done
      [[ $action == RECONCILE_COMMIT ]] || { gf008_escalate_recovery "$milestone_id" 'CRITIC_REPAIR_EXHAUSTED: blocker remains after bounded repairs'; return 1; }
    fi
  fi

  if [[ -z $GF004_ACCEPTED_COMMIT ]]; then
    gf008_create_accepted_commit "$task_file" || { gf008_escalate_recovery "$milestone_id" 'accepted commit creation or verification failed'; return 1; }
    created=true
  fi
  GF004_CRITIC_STATUS=$([[ $GF004_CRITIC_REQUIRED == true ]] && printf pass || printf disabled)
  gf008_finish_pass "$original" "$GF008_ACTION" "$created" "$task_file"
}
