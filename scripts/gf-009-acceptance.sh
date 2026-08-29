#!/usr/bin/env bash
set -u -o pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cli="$repo_root/scripts/gf-milestone.sh"
runner="$repo_root/scripts/gf-unattended-run.sh"
iterations=1
artifact_root=${GF009_ARTIFACT_ROOT:-$repo_root/artifacts/gf-009/gf009-acceptance-$(date -u +%Y%m%dT%H%M%SZ)-$$}

while (($#)); do
  case "$1" in
    --iterations) (($# >= 2)) || { printf '%s\n' '--iterations requires a value' >&2; exit 2; }; iterations=$2; shift 2 ;;
    --artifact-root) (($# >= 2)) || { printf '%s\n' '--artifact-root requires a value' >&2; exit 2; }; artifact_root=$2; shift 2 ;;
    *) printf 'usage: %s [--iterations N] [--artifact-root PATH]\n' "$0" >&2; exit 2 ;;
  esac
done
[[ $iterations =~ ^[1-9][0-9]*$ ]] || { printf 'iterations must be positive\n' >&2; exit 2; }

temp_root=$(mktemp -d "${TMPDIR:-/tmp}/game-foundry-gf009.XXXXXX")
failures=0
checks='[]'
started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
start_ns=$(date +%s%N)
mkdir -p "$artifact_root/iterations"
cleanup() { find "$temp_root" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT

record() {
  local iteration=$1 name=$2 status=$3 detail=${4:-}
  checks=$(jq --argjson iteration "$iteration" --arg name "$name" --arg status "$status" --arg detail "$detail" '. + [{iteration:$iteration,name:$name,status:$status,detail:(if $detail=="" then null else $detail end)}]' <<<"$checks")
  printf 'iteration %02d %-38s %s\n' "$iteration" "$name" "${status^^}"
  [[ $status == pass ]] || failures=$((failures + 1))
}

make_case() {
  local iteration=$1 name=$2 gate=${3:-human_review}
  CASE_ROOT="$temp_root/iteration-$iteration/$name"
  CASE_REPO="$CASE_ROOT/repo"
  CASE_PACKAGE="$CASE_ROOT/package"
  CASE_STATE="$CASE_ROOT/state"
  CASE_ARTIFACT="$artifact_root/iterations/$(printf '%02d' "$iteration")/$name"
  mkdir -p "$CASE_ROOT" "$CASE_STATE" "$CASE_ARTIFACT"
  git clone --shared -q "$repo_root" "$CASE_REPO" || return 1
  cp -a "$repo_root/milestones/examples/chained-execution-milestone" "$CASE_PACKAGE" || return 1
  jq --arg path "$CASE_REPO" --arg gate "$gate" '.repository.path=$path | .completion_gate=$gate' "$CASE_PACKAGE/milestone.json" >"$CASE_PACKAGE/milestone.json.tmp" && mv "$CASE_PACKAGE/milestone.json.tmp" "$CASE_PACKAGE/milestone.json"
  GF_MILESTONE_STATE_ROOT="$CASE_STATE" "$cli" init "$CASE_PACKAGE" --json >"$CASE_ARTIFACT/init.json" || return 1
}

make_critic_case() {
  local iteration=$1 name=$2
  CASE_ROOT="$temp_root/iteration-$iteration/$name"
  CASE_REPO="$CASE_ROOT/repo"
  CASE_PACKAGE="$CASE_ROOT/package"
  CASE_STATE="$CASE_ROOT/state"
  CASE_ARTIFACT="$artifact_root/iterations/$(printf '%02d' "$iteration")/$name"
  mkdir -p "$CASE_ROOT" "$CASE_STATE" "$CASE_ARTIFACT"
  git clone --shared -q "$repo_root" "$CASE_REPO" || return 1
  cp -a "$repo_root/milestones/examples/critic-milestone" "$CASE_PACKAGE" || return 1
  jq --arg path "$CASE_REPO" '.repository.path=$path' "$CASE_PACKAGE/milestone.json" >"$CASE_PACKAGE/milestone.json.tmp" && mv "$CASE_PACKAGE/milestone.json.tmp" "$CASE_PACKAGE/milestone.json"
  GF_MILESTONE_STATE_ROOT="$CASE_STATE" "$cli" init "$CASE_PACKAGE" --json >"$CASE_ARTIFACT/init.json" || return 1
}

case_cli() {
  GF_MILESTONE_STATE_ROOT="$CASE_STATE" GF_MILESTONE_ARTIFACT_ROOT="$CASE_ARTIFACT/prompts" \
    GF_EXECUTION_ARTIFACT_ROOT="$CASE_ARTIFACT/executions" GF_EXECUTION_TMP_ROOT="$CASE_ROOT/worktrees" "$cli" "$@"
}

case_run() {
  GF_MILESTONE_STATE_ROOT="$CASE_STATE" GF_UNATTENDED_ARTIFACT_ROOT="$CASE_ARTIFACT/unattended" \
    GF_MILESTONE_ARTIFACT_ROOT="$CASE_ARTIFACT/prompts" GF_EXECUTION_ARTIFACT_ROOT="$CASE_ARTIFACT/executions" \
    GF_EXECUTION_TMP_ROOT="$CASE_ROOT/worktrees" "$runner" "$@"
}

transition_all_pass() {
  local task
  for task in GF-CHAIN-001 GF-CHAIN-002 GF-CHAIN-003; do
    case_cli transition GF-CHAIN-M001 "$task" running --json >/dev/null || return 1
    case_cli transition GF-CHAIN-M001 "$task" pass --json >/dev/null || return 1
  done
}

run_iteration() {
  local iteration=$1 before after code first_pid i crash_code

  make_case "$iteration" A_one_ready || { record "$iteration" A_one_ready fail setup; return; }
  GF_GF005_ENABLE_TEST_HOOKS=1 case_run --json GF-CHAIN-M001 >"$CASE_ARTIFACT/result.json"
  if jq -e '.tasks_attempted==1 and .tasks_passed==1 and .codex_calls==1 and .stop_reason=="TASK_LIMIT" and .exit_class=="SUCCESS_WORK_COMPLETED" and .human_action_required==false and (.accepted_commits|length)==1 and .final_milestone_state.tasks["GF-CHAIN-002"].status=="ready"' "$CASE_ARTIFACT/result.json" >/dev/null; then record "$iteration" A_one_ready pass; else record "$iteration" A_one_ready fail receipt; fi

  make_case "$iteration" B_task_limit || { record "$iteration" B_task_limit fail setup; return; }
  GF_GF005_ENABLE_TEST_HOOKS=1 case_run --json --max-tasks 2 GF-CHAIN-M001 >"$CASE_ARTIFACT/result.json"
  if jq -e '.tasks_attempted==2 and .tasks_passed==2 and .codex_calls==2 and .stop_reason=="TASK_LIMIT" and .final_milestone_state.tasks["GF-CHAIN-003"].status=="ready"' "$CASE_ARTIFACT/result.json" >/dev/null; then record "$iteration" B_task_limit pass; else record "$iteration" B_task_limit fail receipt; fi

  make_case "$iteration" C_time_limit || { record "$iteration" C_time_limit fail setup; return; }
  GF_GF005_ENABLE_TEST_HOOKS=1 GF_GF005_FAULT=time_after_first case_run --json --max-tasks 3 GF-CHAIN-M001 >"$CASE_ARTIFACT/result.json"
  if jq -e '.tasks_attempted==1 and .tasks_passed==1 and .codex_calls==1 and .stop_reason=="TIME_LIMIT" and .final_milestone_state.tasks["GF-CHAIN-002"].status=="ready"' "$CASE_ARTIFACT/result.json" >/dev/null; then record "$iteration" C_time_limit pass; else record "$iteration" C_time_limit fail receipt; fi

  make_case "$iteration" D_human_gate || { record "$iteration" D_human_gate fail setup; return; }
  GF_GF005_ENABLE_TEST_HOOKS=1 case_run --json --max-tasks 3 GF-CHAIN-M001 >"$CASE_ARTIFACT/result.json"
  if jq -e '.codex_calls==3 and .tasks_passed==3 and .stop_reason=="HUMAN_GATE" and .exit_class=="SUCCESS_HUMAN_GATE" and .human_action_required==true' "$CASE_ARTIFACT/result.json" >/dev/null; then record "$iteration" D_human_gate pass; else record "$iteration" D_human_gate fail receipt; fi

  make_case "$iteration" E_escalated || { record "$iteration" E_escalated fail setup; return; }
  case_cli transition GF-CHAIN-M001 GF-CHAIN-001 running --json >/dev/null
  case_cli transition GF-CHAIN-M001 GF-CHAIN-001 escalated --json >/dev/null
  set +e; case_run --json GF-CHAIN-M001 >"$CASE_ARTIFACT/result.json"; code=$?; set -e
  if [[ $code -eq 20 ]] && jq -e '.codex_calls==0 and .stop_reason=="ESCALATED" and .human_action_required==true' "$CASE_ARTIFACT/result.json" >/dev/null; then record "$iteration" E_escalated pass; else record "$iteration" E_escalated fail "exit=$code"; fi

  make_case "$iteration" F_no_ready || { record "$iteration" F_no_ready fail setup; return; }
  case_cli transition GF-CHAIN-M001 GF-CHAIN-001 running --json >/dev/null
  case_cli transition GF-CHAIN-M001 GF-CHAIN-001 fail --json >/dev/null
  case_run --json GF-CHAIN-M001 >"$CASE_ARTIFACT/result.json"
  if jq -e '.codex_calls==0 and .critic_calls==0 and .stop_reason=="NO_READY_WORK" and .exit_class=="SUCCESS_IDLE" and .human_action_required==false' "$CASE_ARTIFACT/result.json" >/dev/null; then record "$iteration" F_no_ready pass; else record "$iteration" F_no_ready fail receipt; fi

  make_case "$iteration" G_complete automated || { record "$iteration" G_complete fail setup; return; }
  GF_GF005_ENABLE_TEST_HOOKS=1 case_run --json --max-tasks 3 GF-CHAIN-M001 >"$CASE_ARTIFACT/result.json"
  if jq -e '.codex_calls==3 and .tasks_passed==3 and .stop_reason=="MILESTONE_COMPLETE" and .exit_class=="SUCCESS_MILESTONE_COMPLETE" and .human_action_required==false' "$CASE_ARTIFACT/result.json" >/dev/null; then record "$iteration" G_complete pass; else record "$iteration" G_complete fail receipt; fi

  make_case "$iteration" H_concurrent || { record "$iteration" H_concurrent fail setup; return; }
  GF_GF009_ENABLE_TEST_HOOKS=1 GF_GF009_LOCK_READY_FILE="$CASE_ROOT/lock-ready" GF_GF009_HOLD_LOCK_SECONDS=2 GF_GF005_ENABLE_TEST_HOOKS=1 case_run --json GF-CHAIN-M001 >"$CASE_ARTIFACT/first.json" & first_pid=$!
  for ((i=0; i<100; i++)); do [[ -e $CASE_ROOT/lock-ready ]] && break; sleep 0.02; done
  set +e; case_run --json GF-CHAIN-M001 >"$CASE_ARTIFACT/second.json"; code=$?; set -e
  wait "$first_pid" || true
  if [[ $code -eq 75 ]] && jq -e '.runner_lock_result=="busy" and .stop_reason=="RUNNER_BUSY" and .codex_calls==0 and .human_action_required==false' "$CASE_ARTIFACT/second.json" >/dev/null &&
     jq -e '.exit_class=="SUCCESS_WORK_COMPLETED" and .tasks_passed==1 and .codex_calls==1' "$CASE_ARTIFACT/first.json" >/dev/null; then record "$iteration" H_concurrent pass; else record "$iteration" H_concurrent fail "exit=$code"; fi

  make_case "$iteration" I_recovery_first || { record "$iteration" I_recovery_first fail setup; return; }
  set +e
  GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_GF008_ENABLE_TEST_HOOKS=1 GF_GF008_CRASH_AT=ACCEPTED_COMMIT_CREATED case_cli execute-one GF-CHAIN-M001 --json >"$CASE_ARTIFACT/crash.json" 2>"$CASE_ARTIFACT/crash.stderr"
  crash_code=$?
  set -e
  case_run --json GF-CHAIN-M001 >"$CASE_ARTIFACT/result.json"
  if [[ $crash_code -ne 0 ]] && jq -e '.tasks_attempted==1 and .tasks_passed==1 and .codex_calls==0 and .recovery_actions[0].action=="RECONCILE_COMMIT" and .stop_reason=="TASK_LIMIT" and (.accepted_commits|length)==1' "$CASE_ARTIFACT/result.json" >/dev/null; then record "$iteration" I_recovery_first pass; else record "$iteration" I_recovery_first fail "crash=$crash_code"; fi

  make_case "$iteration" J_ambiguity || { record "$iteration" J_ambiguity fail setup; return; }
  set +e
  GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_GF008_ENABLE_TEST_HOOKS=1 GF_GF008_CRASH_AT=AGENT_STARTED case_cli execute-one GF-CHAIN-M001 --json >"$CASE_ARTIFACT/crash.json" 2>"$CASE_ARTIFACT/crash.stderr"
  crash_code=$?
  case_run --json GF-CHAIN-M001 >"$CASE_ARTIFACT/result.json"; code=$?
  set -e
  if [[ $crash_code -ne 0 && $code -eq 20 ]] && jq -e '.codex_calls==0 and .stop_reason=="ESCALATED" and .human_action_required==true and .recovery_actions[0].action=="ESCALATE"' "$CASE_ARTIFACT/result.json" >/dev/null; then record "$iteration" J_ambiguity pass; else record "$iteration" J_ambiguity fail "crash=$crash_code exit=$code"; fi

  make_case "$iteration" K_safe_not_started || { record "$iteration" K_safe_not_started fail setup; return; }
  set +e
  GF_GF005_ENABLE_TEST_HOOKS=1 GF_GF005_FAULT=task1_safe_not_started case_run --json GF-CHAIN-M001 >"$CASE_ARTIFACT/result.json"; code=$?
  set -e
  if [[ $code -eq 70 ]] && jq -e '.codex_calls==0 and .stop_reason=="TRANSPORT_REFUSED" and .human_action_required==false and (.transport_classifications|map(select(.classification=="SAFE_NOT_STARTED"))|length)==1 and .final_milestone_state.tasks["GF-CHAIN-001"].status=="ready"' "$CASE_ARTIFACT/result.json" >/dev/null; then record "$iteration" K_safe_not_started pass; else record "$iteration" K_safe_not_started fail "exit=$code"; fi

  make_case "$iteration" L_dirty_repo || { record "$iteration" L_dirty_repo fail setup; return; }
  printf '\nGF-009 dirty fixture\n' >>"$CASE_REPO/README.md"
  set +e; GF_GF005_ENABLE_TEST_HOOKS=1 case_run --json GF-CHAIN-M001 >"$CASE_ARTIFACT/result.json"; code=$?; set -e
  if [[ $code -eq 70 ]] && jq -e '.codex_calls==0 and .exit_class=="INFRASTRUCTURE_FAILURE" and .human_action_required==true' "$CASE_ARTIFACT/result.json" >/dev/null && grep -Fq 'GF-009 dirty fixture' "$CASE_REPO/README.md"; then record "$iteration" L_dirty_repo pass; else record "$iteration" L_dirty_repo fail "exit=$code"; fi

  make_case "$iteration" L2_escalated_running || { record "$iteration" L2_escalated_running fail setup; return; }
  set +e
  GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_GF008_ENABLE_TEST_HOOKS=1 GF_GF008_CRASH_AT=WORKTREE_READY case_cli execute-one GF-CHAIN-M001 --json >"$CASE_ARTIFACT/crash.json" 2>"$CASE_ARTIFACT/crash.stderr"
  crash_code=$?
  set -e
  jq '.tasks["GF-CHAIN-002"].status="escalated"' "$CASE_STATE/GF-CHAIN-M001/state.json" >"$CASE_STATE/GF-CHAIN-M001/state.json.tmp" && mv "$CASE_STATE/GF-CHAIN-M001/state.json.tmp" "$CASE_STATE/GF-CHAIN-M001/state.json"
  set +e; GF_GF004_ENABLE_TEST_HOOKS=1 case_run --json GF-CHAIN-M001 >"$CASE_ARTIFACT/result.json"; code=$?; set -e
  if [[ $crash_code -ne 0 && $code -eq 20 ]] && jq -e '.codex_calls==0 and .recovery_actions==[] and .stop_reason=="ESCALATED"' "$CASE_ARTIFACT/result.json" >/dev/null; then record "$iteration" L2_escalated_running pass; else record "$iteration" L2_escalated_running fail "crash=$crash_code exit=$code"; fi

  make_case "$iteration" M_crash_next_invocation || { record "$iteration" M_crash_next_invocation fail setup; return; }
  set +e
  GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_GF008_ENABLE_TEST_HOOKS=1 GF_GF008_CRASH_AT=DETERMINISTIC_PASSED case_cli execute-one GF-CHAIN-M001 --json >"$CASE_ARTIFACT/crash.json" 2>"$CASE_ARTIFACT/crash.stderr"
  crash_code=$?
  set -e
  GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success case_run --json GF-CHAIN-M001 >"$CASE_ARTIFACT/result.json"
  if [[ $crash_code -ne 0 ]] && jq -e '.tasks_attempted==1 and .tasks_passed==1 and .codex_calls==0 and .recovery_actions[0].action=="RESUME_CRITIC" and (.accepted_commits|length)==1' "$CASE_ARTIFACT/result.json" >/dev/null; then record "$iteration" M_crash_next_invocation pass; else record "$iteration" M_crash_next_invocation fail "crash=$crash_code"; fi

  make_case "$iteration" N_repeated_idle || { record "$iteration" N_repeated_idle fail setup; return; }
  case_cli transition GF-CHAIN-M001 GF-CHAIN-001 running --json >/dev/null
  case_cli transition GF-CHAIN-M001 GF-CHAIN-001 fail --json >/dev/null
  before=$(sha256sum "$CASE_STATE/GF-CHAIN-M001/state.json" | cut -d' ' -f1)
  mkdir -p "$CASE_ARTIFACT/results"
  for ((i=1; i<=20; i++)); do case_run --json GF-CHAIN-M001 >"$CASE_ARTIFACT/results/$i.json" || break; done
  after=$(sha256sum "$CASE_STATE/GF-CHAIN-M001/state.json" | cut -d' ' -f1)
  if [[ $i -eq 21 && $before == "$after" && $(find "$CASE_ARTIFACT/results" -type f -name '*.json' | wc -l) -eq 20 ]] && jq -s 'length==20 and all(.[];.exit_class=="SUCCESS_IDLE" and .codex_calls==0 and .critic_calls==0)' "$CASE_ARTIFACT"/results/*.json >/dev/null; then record "$iteration" N_repeated_idle pass; else record "$iteration" N_repeated_idle fail "runs=$((i-1))"; fi

  CASE_ARTIFACT="$artifact_root/iterations/$(printf '%02d' "$iteration")/O_invalid_invocation"
  mkdir -p "$CASE_ARTIFACT"
  set +e; GF_UNATTENDED_ARTIFACT_ROOT="$CASE_ARTIFACT/unattended" "$runner" --json --max-tasks abc BAD/id >"$CASE_ARTIFACT/result.json" 2>"$CASE_ARTIFACT/stderr.log"; code=$?; set -e
  if [[ $code -eq 2 ]] && jq -e '.stop_reason=="INVALID_INVOCATION" and .shell_exit_code==2 and .runner_lock_result=="not_acquired" and .bounds.max_tasks==null' "$CASE_ARTIFACT/result.json" >/dev/null; then record "$iteration" O_invalid_receipt pass; else record "$iteration" O_invalid_receipt fail "exit=$code"; fi

  make_critic_case "$iteration" P_critic_evidence || { record "$iteration" P_critic_evidence fail setup; return; }
  set +e
  GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_GF006_ENABLE_TEST_HOOKS=1 GF_GF006_CRITIC_FAULT=warning_only GF_OPENAI_CRITIC_MODEL=test \
    GF_GF008_ENABLE_TEST_HOOKS=1 GF_GF008_CRASH_AT=ACCEPTED_COMMIT_CREATED case_cli execute-one GF-CRITIC-M001 --json >"$CASE_ARTIFACT/crash.json" 2>"$CASE_ARTIFACT/crash.stderr"
  crash_code=$?
  set -e
  critic_review=$(find "$CASE_ARTIFACT/executions" -type f -path '*/attempt-01/critic/evidence.json' -print -quit)
  [[ -n $critic_review ]] && printf '{}\n' >"$critic_review"
  set +e
  GF_GF006_ENABLE_TEST_HOOKS=1 GF_GF006_CRITIC_FAULT=warning_only GF_OPENAI_CRITIC_MODEL=test \
    GF_MILESTONE_STATE_ROOT="$CASE_STATE" GF_UNATTENDED_ARTIFACT_ROOT="$CASE_ARTIFACT/unattended" GF_MILESTONE_ARTIFACT_ROOT="$CASE_ARTIFACT/prompts" \
    GF_EXECUTION_ARTIFACT_ROOT="$CASE_ARTIFACT/executions" GF_EXECUTION_TMP_ROOT="$CASE_ROOT/worktrees" "$runner" --json GF-CRITIC-M001 >"$CASE_ARTIFACT/result.json"
  code=$?
  set -e
  if [[ $crash_code -ne 0 && $code -eq 20 ]] && jq -e '.tasks_passed==0 and .tasks_escalated==1 and .stop_reason=="ESCALATED" and .human_action_required==true' "$CASE_ARTIFACT/result.json" >/dev/null; then record "$iteration" P_critic_evidence pass; else record "$iteration" P_critic_evidence fail "crash=$crash_code exit=$code"; fi

  make_critic_case "$iteration" Q_real_critic_response || { record "$iteration" Q_real_critic_response fail setup; return; }
  set +e
  GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_GF006_ENABLE_TEST_HOOKS=1 GF_GF006_CRITIC_FAULT=warning_only GF_OPENAI_CRITIC_MODEL=test \
    GF_GF008_ENABLE_TEST_HOOKS=1 GF_GF008_CRASH_AT=ACCEPTED_COMMIT_CREATED case_cli execute-one GF-CRITIC-M001 --json >"$CASE_ARTIFACT/crash.json" 2>"$CASE_ARTIFACT/crash.stderr"
  crash_code=$?
  set -e
  critic_response=$(find "$CASE_ARTIFACT/executions" -type f -path '*/attempt-01/critic/response.json' -print -quit)
  if [[ -n $critic_response ]]; then
    jq '.output=[{type:"message",content:[{type:"output_text",text:.output_text}]}] | del(.output_text)' "$critic_response" >"$critic_response.tmp" && mv "$critic_response.tmp" "$critic_response"
  fi
  GF_GF006_ENABLE_TEST_HOOKS=1 GF_GF006_CRITIC_FAULT=warning_only GF_OPENAI_CRITIC_MODEL=test \
    GF_MILESTONE_STATE_ROOT="$CASE_STATE" GF_UNATTENDED_ARTIFACT_ROOT="$CASE_ARTIFACT/unattended" GF_MILESTONE_ARTIFACT_ROOT="$CASE_ARTIFACT/prompts" \
    GF_EXECUTION_ARTIFACT_ROOT="$CASE_ARTIFACT/executions" GF_EXECUTION_TMP_ROOT="$CASE_ROOT/worktrees" "$runner" --json GF-CRITIC-M001 >"$CASE_ARTIFACT/result.json"
  code=$?
  if [[ $crash_code -ne 0 && $code -eq 0 ]] && jq -e '.tasks_passed==1 and .critic_calls==0 and .recovery_actions[0].action=="RECONCILE_COMMIT" and .stop_reason=="TASK_LIMIT" and (.accepted_commits|length)==1' "$CASE_ARTIFACT/result.json" >/dev/null; then record "$iteration" Q_real_critic_response pass; else record "$iteration" Q_real_critic_response fail "crash=$crash_code exit=$code"; fi
}

for ((iteration=1; iteration<=iterations; iteration++)); do
  run_iteration "$iteration"
  find "$temp_root/iteration-$iteration" -depth -delete 2>/dev/null || true
done

unit_status=fail
if systemd-analyze verify "$repo_root/ops/systemd/game-foundry-unattended.service" "$repo_root/ops/systemd/game-foundry-unattended.timer" >"$artifact_root/systemd-verify.log" 2>&1 &&
   grep -Fq 'scripts/gf-unattended-run.sh' "$repo_root/ops/systemd/game-foundry-unattended.service" &&
   ! systemctl --user is-enabled game-foundry-unattended.timer >/dev/null 2>&1; then unit_status=pass; fi
record 0 systemd_units "$unit_status"

finished_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
duration=$(awk -v start="$start_ns" -v end="$(date +%s%N)" 'BEGIN {printf "%.6f",(end-start)/1000000000}')
overall=pass; ((failures == 0)) || overall=fail
jq -n --arg slice GF-009 --arg status "$overall" --arg started "$started_at" --arg finished "$finished_at" --argjson duration "$duration" \
  --argjson iterations "$iterations" --argjson failures "$failures" --argjson checks "$checks" \
  '{slice:$slice,status:$status,started_at:$started,finished_at:$finished,duration_seconds:$duration,iterations:$iterations,failures:$failures,checks:$checks}' >"$artifact_root/evidence-summary.json"
printf 'GF-009 DETERMINISTIC ACCEPTANCE: %s\nITERATIONS: %s\nFAILURES: %s\nEVIDENCE: %s\n' "${overall^^}" "$iterations" "$failures" "$artifact_root"
[[ $overall == pass ]]
