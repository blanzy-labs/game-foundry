#!/usr/bin/env bash
set -u -o pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cli="$repo_root/scripts/gf-milestone.sh"
fixture="$repo_root/milestones/examples/recovery-milestone"
acceptance_id="gf008-acceptance-$(date -u +'%Y%m%dT%H%M%SZ')-$(printf '%s-%s' "$$" "$RANDOM" | sha256sum | cut -c1-6)"
artifact_dir="$repo_root/artifacts/gf-008/$acceptance_id"
reports_dir="$repo_root/reports/gf-008"
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/game-foundry-gf008.XXXXXX")
started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ'); total_start=$(date +%s%N); failures=0
declare -A checks=()

cleanup() {
  find "$temp_root" -type d -path '*/work/*/workspace' -prune -print0 2>/dev/null | while IFS= read -r -d '' workspace; do
    repo=$(git -C "$workspace" rev-parse --git-common-dir 2>/dev/null || true)
    [[ -z $repo ]] || git -C "$workspace" worktree remove --force "$workspace" >/dev/null 2>&1 || true
  done
  rm -rf -- "$temp_root"
}
trap cleanup EXIT
mkdir -p "$artifact_dir/cases" "$artifact_dir/regression" "$reports_dir"
pass_case() { checks[$1]=pass; printf '%-52s PASS\n' "$1"; }
fail_case() { checks[$1]=fail; failures=$((failures + 1)); printf '%-52s FAIL\n' "$1"; }

if [[ -z ${OPENAI_API_KEY:-} || -z ${GF_OPENAI_CRITIC_MODEL:-} ]]; then
  jq -n --arg slice GF-008 --arg status fail --arg acceptance_id "$acceptance_id" '{slice:$slice,status:$status,acceptance_id:$acceptance_id,checks:{api_preflight:"fail"},false_acceptances:1}' >"$reports_dir/evidence-summary.json"
  printf '# GF-008 evidence summary\n\nStatus: **FAIL**\n\nRequired OpenAI critic configuration is unavailable.\n' >"$reports_dir/evidence-summary.md"
  exit 1
fi
pass_case api_preflight
main_before=$(git -C "$repo_root" rev-parse main)

make_case() {
  local name=$1
  CASE_REPO="$temp_root/repos/$name"; CASE_PACKAGE="$temp_root/packages/$name"; CASE_STATE="$temp_root/states/$name"; CASE_ARTIFACT="$artifact_dir/cases/$name"; CASE_WORK="$temp_root/work/$name"
  mkdir -p "$(dirname "$CASE_REPO")" "$(dirname "$CASE_PACKAGE")" "$CASE_STATE" "$CASE_ARTIFACT" "$CASE_WORK"
  git clone -q "$repo_root" "$CASE_REPO" || return 1
  cp -a "$fixture" "$CASE_PACKAGE"
  jq --arg path "$CASE_REPO" '.repository.path=$path' "$CASE_PACKAGE/milestone.json" >"$CASE_PACKAGE/milestone.tmp" && mv "$CASE_PACKAGE/milestone.tmp" "$CASE_PACKAGE/milestone.json"
}

case_cli() {
  GF_MILESTONE_STATE_ROOT="$CASE_STATE" GF_MILESTONE_ARTIFACT_ROOT="$CASE_ARTIFACT/prompts" GF_EXECUTION_ARTIFACT_ROOT="$CASE_ARTIFACT/executions" \
    GF_EXECUTION_TMP_ROOT="$CASE_WORK" GF_BOUNDED_ARTIFACT_ROOT="$CASE_ARTIFACT/bounded" "$cli" "$@"
}
init_case() { case_cli init "$CASE_PACKAGE" --json >"$CASE_ARTIFACT/init.json"; }
controlled_execute() {
  local checkpoint=$1
  GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_GF007_ENABLE_TEST_HOOKS=1 GF_GF007_CRITIC_SEQUENCE="${GF008_SEQUENCE:-warning_only}" \
    GF_GF007_INITIAL_FORBIDDEN="${GF008_FORBIDDEN:-0}" GF_GF007_REPAIR_AGENT_TEST_DOUBLE="${GF008_REPAIR_DOUBLE:-0}" GF_GF007_REPAIR_FAULT="${GF008_REPAIR_FAULT:-repair_success}" \
    GF_OPENAI_CRITIC_MODEL=test GF_GF008_ENABLE_TEST_HOOKS=1 GF_GF008_CRASH_AT="$checkpoint" GF_GF008_CRASH_REPAIR_ORDINAL="${GF008_CRASH_REPAIR_ORDINAL:-}" case_cli execute-one GF-RECOVERY-M001 --json
}
controlled_recover() {
  GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_GF007_ENABLE_TEST_HOOKS=1 GF_GF007_CRITIC_SEQUENCE="${GF008_SEQUENCE:-warning_only}" \
    GF_GF007_REPAIR_AGENT_TEST_DOUBLE="${GF008_REPAIR_DOUBLE:-0}" GF_GF007_REPAIR_FAULT="${GF008_REPAIR_FAULT:-repair_success}" GF_OPENAI_CRITIC_MODEL=test \
    GF_GF008_ENABLE_TEST_HOOKS="${GF008_RECOVERY_HOOKS:-0}" GF_GF008_CRASH_AT="${GF008_RECOVERY_CRASH:-}" case_cli recover GF-RECOVERY-M001 --json
}
run_crash() {
  local checkpoint=$1
  set +e; controlled_execute "$checkpoint" >"$CASE_ARTIFACT/crash.stdout.log" 2>"$CASE_ARTIFACT/crash.stderr.log"; CRASH_CODE=$?; set -e; set +e
  case_cli recovery-status GF-RECOVERY-M001 --json >"$CASE_ARTIFACT/recovery-status.json" 2>"$CASE_ARTIFACT/recovery-status.stderr.log"; STATUS_CODE=$?; set -e; set +e
}

# A — claimed work safely restarts.
make_case before-agent; init_case; run_crash CLAIMED
controlled_recover >"$CASE_ARTIFACT/recovery-result.json" 2>"$CASE_ARTIFACT/recovery.stderr.log"; rc=$?
if [[ $CRASH_CODE -eq 137 && $rc -eq 0 ]] && jq -e '.recovery_action=="RESTART_TASK" and .result=="pass" and .codex_calls==1 and .counters.agent_restarts==1' "$CASE_ARTIFACT/recovery-result.json" >/dev/null; then pass_case A_before_agent_recovery; else fail_case A_before_agent_recovery; fi

# B — partial agent work is discarded and the same logical task restarts once.
make_case during-agent; init_case; run_crash AGENT_STARTED
controlled_recover >"$CASE_ARTIFACT/recovery-result.json" 2>"$CASE_ARTIFACT/recovery.stderr.log"; rc=$?
if [[ $rc -eq 0 ]] && jq -e '.recovery_action=="RESTART_TASK" and .codex_calls==1 and .counters.agent_restarts==1 and .state.task=="pass"' "$CASE_ARTIFACT/recovery-result.json" >/dev/null; then pass_case B_during_agent_restart; else fail_case B_during_agent_restart; fi

# C — candidate snapshot resumes deterministic work without Codex.
make_case candidate-snapshot; init_case; run_crash CANDIDATE_SNAPSHOTTED
controlled_recover >"$CASE_ARTIFACT/recovery-result.json" 2>"$CASE_ARTIFACT/recovery.stderr.log"; rc=$?
if [[ $rc -eq 0 ]] && jq -e '.recovery_action=="RESUME_DETERMINISTIC" and .codex_calls==0 and .work_reused.codex_candidate' "$CASE_ARTIFACT/recovery-result.json" >/dev/null; then pass_case C_candidate_snapshot_resume; else fail_case C_candidate_snapshot_resume; fi

# D/S — central real OpenClaw/Codex → deterministic crash → fresh real critic.
make_case real-deterministic; init_case
set +e
GF_GF008_ENABLE_TEST_HOOKS=1 GF_GF008_CRASH_AT=DETERMINISTIC_PASSED case_cli execute-one GF-RECOVERY-M001 --json >"$CASE_ARTIFACT/crash.stdout.log" 2>"$CASE_ARTIFACT/crash.stderr.log"
CRASH_CODE=$?
set -e; set +e
case_cli recovery-status GF-RECOVERY-M001 --json >"$CASE_ARTIFACT/recovery-status.json"
case_cli recover GF-RECOVERY-M001 --json >"$CASE_ARTIFACT/recovery-result.json" 2>"$CASE_ARTIFACT/recovery.stderr.log"; rc=$?
case_cli status GF-RECOVERY-M001 --json >"$CASE_ARTIFACT/final-status.json"
set -e; set +e
if [[ $CRASH_CODE -eq 137 && $rc -eq 0 ]] && jq -e '.recovery_action=="RESUME_CRITIC" and .result=="pass" and .codex_calls==0 and .critic_calls==1 and .commit.created and .commit.sha!=null and .human_interventions==0' "$CASE_ARTIFACT/recovery-result.json" >/dev/null; then pass_case D_real_deterministic_pass_resume; else fail_case D_real_deterministic_pass_resume; fi
if jq -e '.tasks["GF-RECOVERY-001"].status=="pass" and .tasks["GF-RECOVERY-002"].status=="ready"' "$CASE_ARTIFACT/final-status.json" >/dev/null; then pass_case S_no_descendant_execution; else fail_case S_no_descendant_execution; fi
real_case_dir="$CASE_ARTIFACT"

# E — interrupted critic is retried, never inferred PASS.
make_case critic-started; init_case; run_crash CRITIC_STARTED
controlled_recover >"$CASE_ARTIFACT/recovery-result.json" 2>"$CASE_ARTIFACT/recovery.stderr.log"; rc=$?
if [[ $rc -eq 0 ]] && jq -e '.recovery_action=="RESUME_CRITIC" and .codex_calls==0 and .critic_calls==1 and .counters.critic_retries==1' "$CASE_ARTIFACT/recovery-result.json" >/dev/null; then pass_case E_critic_started_retry; else fail_case E_critic_started_retry; fi

# F — persisted critic PASS creates one accepted commit without a new review.
make_case critic-pass; init_case; pre=$(git -C "$CASE_REPO" rev-parse gf/GF-RECOVERY-M001); run_crash CRITIC_PASSED
controlled_recover >"$CASE_ARTIFACT/recovery-result.json" 2>"$CASE_ARTIFACT/recovery.stderr.log"; rc=$?
count=$(git -C "$CASE_REPO" rev-list --count "$pre..gf/GF-RECOVERY-M001")
if [[ $rc -eq 0 && $count -eq 1 ]] && jq -e '.recovery_action=="RECONCILE_COMMIT" and .critic_calls==0 and .commit.created' "$CASE_ARTIFACT/recovery-result.json" >/dev/null; then pass_case F_critic_pass_resume; else fail_case F_critic_pass_resume; fi

# G/H — exact existing commit reconciliation and duplicate recovery idempotency.
make_case commit-reconcile; init_case; pre=$(git -C "$CASE_REPO" rev-parse gf/GF-RECOVERY-M001); run_crash ACCEPTED_COMMIT_CREATED; existing=$(git -C "$CASE_REPO" rev-parse gf/GF-RECOVERY-M001)
controlled_recover >"$CASE_ARTIFACT/recovery-result.json" 2>"$CASE_ARTIFACT/recovery.stderr.log"; rc=$?; after=$(git -C "$CASE_REPO" rev-parse gf/GF-RECOVERY-M001)
controlled_recover >"$CASE_ARTIFACT/recovery-again.json" 2>"$CASE_ARTIFACT/recovery-again.stderr.log"; again=$?; count=$(git -C "$CASE_REPO" rev-list --count "$pre..gf/GF-RECOVERY-M001")
jq -n --arg pre "$pre" --arg existing "$existing" --arg after "$after" --argjson count "$count" '{pre_task_commit:$pre,existing_accepted_commit:$existing,branch_head:$after,new_commits_created_by_recovery:0,total_task_commits:$count}' >"$CASE_ARTIFACT/commit-reconciliation.json"
if [[ $rc -eq 0 && $existing == "$after" && $count -eq 1 ]] && jq -e '.commit.created==false and .counters.commit_reconciliations==1 and .state.task=="pass"' "$CASE_ARTIFACT/recovery-result.json" >/dev/null; then pass_case G_commit_before_state_reconciliation; else fail_case G_commit_before_state_reconciliation; fi
if [[ $again -eq 0 && $count -eq 1 ]] && jq -e '.recovery_action=="NO_RECOVERY_NEEDED"' "$CASE_ARTIFACT/recovery-again.json" >/dev/null; then pass_case H_duplicate_recovery; else fail_case H_duplicate_recovery; fi
commit_case_dir="$CASE_ARTIFACT"

# I — blocker resumes repair at ordinal one.
make_case repair-block; init_case; GF008_SEQUENCE=blocker,warning_only GF008_REPAIR_DOUBLE=1 GF008_REPAIR_FAULT=repair_success run_crash CRITIC_BLOCKED
GF008_SEQUENCE=blocker,warning_only GF008_REPAIR_DOUBLE=1 GF008_REPAIR_FAULT=repair_success controlled_recover >"$CASE_ARTIFACT/recovery-result.json" 2>"$CASE_ARTIFACT/recovery.stderr.log"; rc=$?
if [[ $rc -eq 0 ]] && jq -e '.recovery_action=="RESUME_REPAIR" and .result=="pass" and .counters.repair_resumptions==1' "$CASE_ARTIFACT/recovery-result.json" >/dev/null; then pass_case I_critic_block_repair_resume; else fail_case I_critic_block_repair_resume; fi
repair_case_dir="$CASE_ARTIFACT"

# J — crash during repair reruns the same ordinal.
make_case repair-agent; init_case; GF008_SEQUENCE=blocker,warning_only GF008_REPAIR_DOUBLE=1 GF008_REPAIR_FAULT=repair_success run_crash REPAIR_STARTED
GF008_SEQUENCE=blocker,warning_only GF008_REPAIR_DOUBLE=1 GF008_REPAIR_FAULT=repair_success controlled_recover >"$CASE_ARTIFACT/recovery-result.json" 2>"$CASE_ARTIFACT/recovery.stderr.log"; rc=$?
if [[ $rc -eq 0 ]] && jq -e '.result=="pass" and .codex_calls==1 and .counters.repair_resumptions==1' "$CASE_ARTIFACT/recovery-result.json" >/dev/null && jq -e '.tasks["GF-RECOVERY-001"].repair_attempts==1' "$CASE_STATE/GF-RECOVERY-M001/state.json" >/dev/null; then pass_case J_repair_agent_same_ordinal; else fail_case J_repair_agent_same_ordinal; fi

# K — repair deterministic PASS resumes only critic re-review.
make_case repair-deterministic; init_case; GF008_SEQUENCE=blocker,warning_only GF008_REPAIR_DOUBLE=1 GF008_REPAIR_FAULT=repair_success run_crash REPAIR_DETERMINISTIC_PASSED
GF008_SEQUENCE=blocker,warning_only GF008_REPAIR_DOUBLE=1 GF008_REPAIR_FAULT=repair_success controlled_recover >"$CASE_ARTIFACT/recovery-result.json" 2>"$CASE_ARTIFACT/recovery.stderr.log"; rc=$?
if [[ $rc -eq 0 ]] && jq -e '.recovery_action=="RESUME_REPAIR_CRITIC" and .codex_calls==0 and .critic_calls==1' "$CASE_ARTIFACT/recovery-result.json" >/dev/null; then pass_case K_repair_deterministic_resume; else fail_case K_repair_deterministic_resume; fi

# L — repair 1 remains consumed while interrupted repair 2 restarts as ordinal 2.
make_case repair-budget; init_case; GF008_SEQUENCE=blocker,blocker,warning_only GF008_REPAIR_DOUBLE=1 GF008_REPAIR_FAULT=repair_success GF008_CRASH_REPAIR_ORDINAL=2 run_crash REPAIR_STARTED
GF008_SEQUENCE=blocker,blocker,warning_only GF008_REPAIR_DOUBLE=1 GF008_REPAIR_FAULT=repair_success controlled_recover >"$CASE_ARTIFACT/recovery-result.json" 2>"$CASE_ARTIFACT/recovery.stderr.log"; rc=$?
if [[ $rc -eq 0 ]] && jq -e '.original_checkpoint=="REPAIR_STARTED" and .codex_calls==1 and .result=="pass"' "$CASE_ARTIFACT/recovery-result.json" >/dev/null && jq -e '.tasks["GF-RECOVERY-001"].repair_attempts==2' "$CASE_STATE/GF-RECOVERY-M001/state.json" >/dev/null; then pass_case L_repair_budget_persistence; else fail_case L_repair_budget_persistence; fi

# M — repeated process loss exhausts the independent recovery restart budget.
make_case restart-exhaustion; init_case; run_crash AGENT_STARTED
for iteration in 1 2; do
  set +e; GF008_RECOVERY_HOOKS=1 GF008_RECOVERY_CRASH=AGENT_STARTED controlled_recover >"$CASE_ARTIFACT/restart-$iteration.json" 2>"$CASE_ARTIFACT/restart-$iteration.stderr.log"; set -e; set +e
done
controlled_recover >"$CASE_ARTIFACT/recovery-result.json" 2>"$CASE_ARTIFACT/recovery.stderr.log"; rc=$?
if [[ $rc -ne 0 ]] && jq -e '.result=="escalated"' "$CASE_ARTIFACT/recovery-result.json" >/dev/null && jq -e '.tasks["GF-RECOVERY-001"].status=="escalated" and .tasks["GF-RECOVERY-002"].status=="blocked"' "$CASE_STATE/GF-RECOVERY-M001/state.json" >/dev/null; then pass_case M_recovery_restart_exhaustion; else fail_case M_recovery_restart_exhaustion; fi

# N — corrupt checkpoint escalates without source movement or Codex.
make_case corrupt-checkpoint; init_case; pre=$(git -C "$CASE_REPO" rev-parse gf/GF-RECOVERY-M001); run_crash CLAIMED
checkpoint=$(jq -r '.active_execution.artifact_path' "$CASE_STATE/GF-RECOVERY-M001/state.json")/checkpoint.json; printf '{corrupt\n' >"$checkpoint"
controlled_recover >"$CASE_ARTIFACT/recovery-result.json" 2>"$CASE_ARTIFACT/recovery.stderr.log"; rc=$?; post=$(git -C "$CASE_REPO" rev-parse gf/GF-RECOVERY-M001)
if [[ $rc -ne 0 && $pre == "$post" ]] && jq -e '.result=="escalated" and .codex_calls==0' "$CASE_ARTIFACT/recovery-result.json" >/dev/null; then pass_case N_corrupt_checkpoint; else fail_case N_corrupt_checkpoint; fi

# O — a snapshot-dependent checkpoint with a deleted ref escalates.
make_case missing-snapshot; init_case; pre=$(git -C "$CASE_REPO" rev-parse gf/GF-RECOVERY-M001); run_crash DETERMINISTIC_PASSED
checkpoint=$(jq -r '.active_execution.artifact_path' "$CASE_STATE/GF-RECOVERY-M001/state.json")/checkpoint.json; ref=$(jq -r '.snapshot.ref' "$checkpoint"); git -C "$CASE_REPO" update-ref -d "$ref"
controlled_recover >"$CASE_ARTIFACT/recovery-result.json" 2>"$CASE_ARTIFACT/recovery.stderr.log"; rc=$?; post=$(git -C "$CASE_REPO" rev-parse gf/GF-RECOVERY-M001)
if [[ $rc -ne 0 && $pre == "$post" ]] && jq -e '.result=="escalated" and .codex_calls==0' "$CASE_ARTIFACT/recovery-result.json" >/dev/null; then pass_case O_missing_snapshot; else fail_case O_missing_snapshot; fi

# P — unexpected execution-branch movement is preserved and escalated.
make_case branch-movement; init_case; run_crash DETERMINISTIC_PASSED
workspace=$(jq -r '.active_execution.worktree_path' "$CASE_STATE/GF-RECOVERY-M001/state.json"); git -C "$workspace" -c user.name=Unexpected -c user.email=unexpected@invalid commit --allow-empty -m unexpected >/dev/null; moved=$(git -C "$CASE_REPO" rev-parse gf/GF-RECOVERY-M001)
controlled_recover >"$CASE_ARTIFACT/recovery-result.json" 2>"$CASE_ARTIFACT/recovery.stderr.log"; rc=$?; after=$(git -C "$CASE_REPO" rev-parse gf/GF-RECOVERY-M001)
if [[ $rc -ne 0 && $moved == "$after" ]] && jq -e '.result=="escalated" and .codex_calls==0' "$CASE_ARTIFACT/recovery-result.json" >/dev/null; then pass_case P_unknown_branch_movement; else fail_case P_unknown_branch_movement; fi

# Q — live PID/boot/start identity and the long execution lock reject recovery.
make_case active-owner; init_case
GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_GF007_ENABLE_TEST_HOOKS=1 GF_GF007_CRITIC_SEQUENCE=warning_only GF_OPENAI_CRITIC_MODEL=test \
  GF_GF008_ENABLE_TEST_HOOKS=1 GF_GF008_PAUSE_AT=CLAIMED GF_GF008_PAUSE_SECONDS=30 case_cli execute-one GF-RECOVERY-M001 --json >"$CASE_ARTIFACT/child.json" 2>"$CASE_ARTIFACT/child.stderr.log" &
child_pid=$!
for _ in $(seq 1 100); do [[ -f $CASE_STATE/GF-RECOVERY-M001/state.json ]] && jq -e '.active_execution.checkpoint=="CLAIMED"' "$CASE_STATE/GF-RECOVERY-M001/state.json" >/dev/null 2>&1 && break; sleep 0.05; done
set +e; case_cli recovery-status GF-RECOVERY-M001 --json >"$CASE_ARTIFACT/recovery-status.json"; busy_status=$?; case_cli recover GF-RECOVERY-M001 --json >"$CASE_ARTIFACT/recovery-result.json"; busy_recover=$?; set -e; set +e
owner_pid=$(jq -r '.active_execution.owner.pid' "$CASE_STATE/GF-RECOVERY-M001/state.json")
kill -KILL "$owner_pid" 2>/dev/null || true; kill -KILL "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true
if [[ $busy_status -eq 0 && $busy_recover -eq 2 ]] && jq -e '.recovery_action=="RECOVERY_BUSY" and .owner=="live"' "$CASE_ARTIFACT/recovery-status.json" >/dev/null && jq -e '.recovery_action=="RECOVERY_BUSY"' "$CASE_ARTIFACT/recovery-result.json" >/dev/null; then pass_case Q_active_owner_rejection; else fail_case Q_active_owner_rejection; fi

# Simulated reboot identity mismatch is stale even if the recorded PID exists.
jq '.active_execution.owner.boot_id="00000000-0000-0000-0000-000000000000"' "$CASE_STATE/GF-RECOVERY-M001/state.json" >"$CASE_STATE/GF-RECOVERY-M001/state.tmp" && mv "$CASE_STATE/GF-RECOVERY-M001/state.tmp" "$CASE_STATE/GF-RECOVERY-M001/state.json"
case_cli recovery-status GF-RECOVERY-M001 --json >"$CASE_ARTIFACT/reboot-status.json"
if jq -e '.owner=="stale" and .recovery_action=="RESTART_TASK"' "$CASE_ARTIFACT/reboot-status.json" >/dev/null; then pass_case simulated_boot_change; else fail_case simulated_boot_change; fi

# T — a fresh bounded process executes only the newly READY second task.
CASE_ARTIFACT=$real_case_dir; CASE_REPO="$temp_root/repos/real-deterministic"; CASE_PACKAGE="$temp_root/packages/real-deterministic"; CASE_STATE="$temp_root/states/real-deterministic"; CASE_WORK="$temp_root/work/real-deterministic"
GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_GF007_ENABLE_TEST_HOOKS=1 GF_GF007_CRITIC_SEQUENCE=warning_only GF_OPENAI_CRITIC_MODEL=test case_cli run-bounded GF-RECOVERY-M001 --max-tasks 1 --max-minutes 30 --json >"$CASE_ARTIFACT/fresh-run.json" 2>"$CASE_ARTIFACT/fresh-run.stderr.log"; fresh_rc=$?
case_cli status GF-RECOVERY-M001 --json >"$CASE_ARTIFACT/after-fresh-status.json"
if [[ $fresh_rc -eq 0 ]] && jq -e '.attempted_tasks==1 and .executions[0].task_id=="GF-RECOVERY-002" and .executions[0].result=="pass"' "$CASE_ARTIFACT/fresh-run.json" >/dev/null && jq -e '.status=="pending_human"' "$CASE_ARTIFACT/after-fresh-status.json" >/dev/null; then pass_case T_fresh_bounded_continuation; pass_case human_gate_authoritative; else fail_case T_fresh_bounded_continuation; fail_case human_gate_authoritative; fi

main_after=$(git -C "$repo_root" rev-parse main)
if [[ $main_before == "$main_after" ]]; then pass_case R_main_branch_isolation; else fail_case R_main_branch_isolation; fi

# Required regressions. GF-007 executes GF-006, whose acceptance executes
# GF-003/GF-004/GF-005. Consume that nested evidence instead of repeating the
# same real OpenClaw/Codex suites several times in one GF-008 invocation.
set +e; (cd "$repo_root" && ./scripts/gf-007-acceptance.sh) >"$artifact_dir/regression/gf007.log" 2>&1; gf007_code=$?; set -e; set +e
if [[ $gf007_code -eq 0 ]]; then
  pass_case gf007_regression
  for slice in 003 004 005 006; do
    key="gf${slice}_regression"
    if jq -e --arg key "$key" '.checks[$key]=="pass"' "$repo_root/reports/gf-007/evidence-summary.json" >/dev/null; then pass_case "$key"; else fail_case "$key"; fi
  done
else
  fail_case gf007_regression; fail_case gf003_regression; fail_case gf004_regression; fail_case gf005_regression; fail_case gf006_regression
fi
if "$repo_root/scripts/gf-002-shared-gate-tests.sh" >"$artifact_dir/regression/gf002.log" 2>&1; then pass_case gf002_shared_regression; else fail_case gf002_shared_regression; fi
if "$repo_root/scripts/doctor.sh" >"$artifact_dir/regression/doctor.log" 2>&1; then pass_case doctor; else fail_case doctor; fi

completed_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ'); total_seconds=$(awk -v start="$total_start" -v end="$(date +%s%N)" 'BEGIN {printf "%.6f",(end-start)/1000000000}')
checks_json=$(for key in "${!checks[@]}"; do jq -cn --arg key "$key" --arg value "${checks[$key]}" '{key:$key,value:$value}'; done | jq -s from_entries)
overall=pass; ((failures > 0)) && overall=fail
real_result=$(cat "$real_case_dir/recovery-result.json"); commit_result=$(cat "$commit_case_dir/recovery-result.json"); repair_result=$(cat "$repair_case_dir/recovery-result.json")
successful=$(find "$artifact_dir/cases" -name recovery-result.json -type f -exec jq -r 'select(.result=="pass")|.result' {} \; | wc -l)
escalations=$(find "$artifact_dir/cases" -name recovery-result.json -type f -exec jq -r 'select(.result=="escalated")|.result' {} \; | wc -l)
jq -n --arg slice GF-008 --arg status "$overall" --arg acceptance_id "$acceptance_id" --arg started_at "$started_at" --arg completed_at "$completed_at" --arg artifact_dir "${artifact_dir#"$repo_root/"}" \
  --arg model "$GF_OPENAI_CRITIC_MODEL" --argjson total_seconds "$total_seconds" --argjson failures "$failures" --argjson checks "$checks_json" --argjson real "$real_result" --argjson commit "$commit_result" --argjson repair "$repair_result" \
  --argjson successful "$successful" --argjson escalations "$escalations" \
  '{slice:$slice,status:$status,acceptance_id:$acceptance_id,started_at:$started_at,completed_at:$completed_at,artifact_dir:$artifact_dir,configuration:{critic_model:$model,max_agent_restarts:2,repair_max_attempts:2},real_recovery:$real,commit_reconciliation:$commit,repair_recovery:$repair,checks:$checks,
    metrics:{acceptance_total_seconds:$total_seconds,recovery_invocations:([$real,$commit,$repair]|map(.counters.recovery_invocations//0)|add),successful_recoveries:$successful,escalations:$escalations,agent_restarts:([$real,$commit,$repair]|map(.counters.agent_restarts//0)|add),worktree_recreations:([$real,$commit,$repair]|map(.counters.worktree_recreations//0)|add),candidate_restores:([$real,$commit,$repair]|map(.counters.worktree_recreations//0)|add),codex_calls_avoided:([$real,$commit,$repair]|map(if .work_reused.codex_candidate then 1 else 0 end)|add),critic_calls_avoided:([$real,$commit,$repair]|map(if .work_reused.critic_result then 1 else 0 end)|add),average_recovery_seconds:($total_seconds/$successful),human_interventions:0},false_acceptances:$failures}' >"$reports_dir/evidence-summary.json"
{
  printf '# GF-008 evidence summary\n\nStatus: **%s**\n\n' "${overall^^}"
  printf -- '- Acceptance: `%s`\n- Real recovery run: `%s`\n- Crash checkpoint: `%s`\n- Recovery action: `%s`\n- Codex calls after restart: `%s`\n- Critic calls after restart: `%s`\n- Accepted commit: `%s`\n- Evidence: `%s`\n- Failed checks: `%s`\n' \
    "$acceptance_id" "$(jq -r .run_id <<<"$real_result")" "$(jq -r .original_checkpoint <<<"$real_result")" "$(jq -r .recovery_action <<<"$real_result")" "$(jq -r .codex_calls <<<"$real_result")" "$(jq -r .critic_calls <<<"$real_result")" "$(jq -r .commit.sha <<<"$real_result")" "${artifact_dir#"$repo_root/"}" "$failures"
} >"$reports_dir/evidence-summary.md"
if ((failures > 0)); then printf '\nGF-008 ACCEPTANCE: FAIL (%s)\n' "$failures"; exit 1; fi
printf '\nGF-008 ACCEPTANCE: PASS\nEvidence: %s\n' "${artifact_dir#"$repo_root/"}"
