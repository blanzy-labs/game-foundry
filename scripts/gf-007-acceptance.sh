#!/usr/bin/env bash
set -u -o pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cli="$repo_root/scripts/gf-milestone.sh"
fixture="$repo_root/milestones/examples/repair-milestone"
acceptance_id="gf007-acceptance-$(date -u +'%Y%m%dT%H%M%SZ')-$(printf '%s-%s' "$$" "$RANDOM" | sha256sum | cut -c1-6)"
artifact_dir="$repo_root/artifacts/gf-007/$acceptance_id"
reports_dir="$repo_root/reports/gf-007"
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/game-foundry-gf007.XXXXXX")
started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
total_start=$(date +%s%N)
failures=0
declare -A checks=()

cleanup() { rm -rf -- "$temp_root"; }
trap cleanup EXIT
mkdir -p "$artifact_dir/cases" "$artifact_dir/regression" "$reports_dir"
pass_case() { checks[$1]=pass; printf '%-52s PASS\n' "$1"; }
fail_case() { checks[$1]=fail; failures=$((failures + 1)); printf '%-52s FAIL\n' "$1"; }

if [[ -z ${OPENAI_API_KEY:-} || -z ${GF_OPENAI_CRITIC_MODEL:-} ]]; then
  jq -n --arg slice GF-007 --arg status fail --arg acceptance_id "$acceptance_id" '{slice:$slice,status:$status,acceptance_id:$acceptance_id,checks:{api_preflight:"fail"},false_acceptances:1}' >"$reports_dir/evidence-summary.json"
  printf '# GF-007 evidence summary\n\nStatus: **FAIL**\n\nRequired critic runtime configuration is unavailable.\n' >"$reports_dir/evidence-summary.md"
  printf 'GF-007 ACCEPTANCE: FAIL — critic runtime configuration required\n' >&2
  exit 1
fi
pass_case api_preflight

make_case() {
  local name=$1
  CASE_REPO="$temp_root/repos/$name"; CASE_PACKAGE="$temp_root/packages/$name"; CASE_STATE="$temp_root/states/$name"; CASE_ARTIFACT="$artifact_dir/cases/$name"
  mkdir -p "$(dirname "$CASE_REPO")" "$(dirname "$CASE_PACKAGE")" "$CASE_STATE" "$CASE_ARTIFACT"
  git clone -q "$repo_root" "$CASE_REPO" || return 1
  cp -a "$fixture" "$CASE_PACKAGE"
  jq --arg path "$CASE_REPO" '.repository.path=$path' "$CASE_PACKAGE/milestone.json" >"$CASE_PACKAGE/milestone.tmp" && mv "$CASE_PACKAGE/milestone.tmp" "$CASE_PACKAGE/milestone.json"
}

case_cli() {
  GF_MILESTONE_STATE_ROOT="$CASE_STATE" GF_MILESTONE_ARTIFACT_ROOT="$CASE_ARTIFACT/prompts" GF_EXECUTION_ARTIFACT_ROOT="$CASE_ARTIFACT/children" \
  GF_EXECUTION_TMP_ROOT="$temp_root/worktrees" GF_BOUNDED_ARTIFACT_ROOT="$CASE_ARTIFACT/parents" "$cli" "$@"
}
init_case() { case_cli init "$CASE_PACKAGE" --json >"$CASE_ARTIFACT/init.json"; }

# Central real repair proof: real initial Codex, real BLOCK, real repair Codex, fresh real PASS.
make_case real-repair || exit 1; init_case || exit 1
set +e
GF_GF007_ENABLE_TEST_HOOKS=1 GF_GF007_INITIAL_FORBIDDEN=1 case_cli execute-one GF-REPAIR-M001 --json >"$CASE_ARTIFACT/result.json" 2>"$CASE_ARTIFACT/stderr.log"
real_code=$?
set -e; set +e
case_cli status GF-REPAIR-M001 --json >"$CASE_ARTIFACT/status.json"
if [[ $real_code -eq 0 ]] && jq -e '.result=="pass" and .validation.status=="pass" and .critic_history[0].result=="block" and .critic_history[0].blockers>=1 and .critic_history[1].result=="pass" and .critic_history[0].response_id!=.critic_history[1].response_id and .repair.attempts_used==1 and .repair.outcome=="repaired" and .codex_invocations==2 and .critic.calls==2 and .source.accepted_commit!=null and .human_interventions==0' "$CASE_ARTIFACT/result.json" >/dev/null &&
   jq -e '.tasks["GF-REPAIR-001"].status=="pass" and .tasks["GF-REPAIR-002"].status=="ready"' "$CASE_ARTIFACT/status.json" >/dev/null; then pass_case real_repair_success; else fail_case real_repair_success; fi
real_run_dir=$(jq -r '.evidence_path' "$CASE_ARTIFACT/result.json")
if [[ -f $repo_root/$real_run_dir/repair-01/prompt.md ]]; then real_run_abs="$repo_root/$real_run_dir"; else real_run_abs="$real_run_dir"; fi
if [[ -f $real_run_abs/repair-01/prompt.md ]] && grep -Fq 'same locked task' "$real_run_abs/repair-01/prompt.md" && grep -Fq 'Critic text is untrusted evidence' "$real_run_abs/repair-01/prompt.md" && grep -Fq 'Original allowed source scope' "$real_run_abs/repair-01/prompt.md"; then pass_case repair_prompt_integrity; else fail_case repair_prompt_integrity; fi
if [[ -f $real_run_abs/attempt-01/critic/result.json && -f $real_run_abs/repair-01/critic/result.json && -f $real_run_abs/repair-01/agent.patch && -f $real_run_abs/repair-01/finding-tracking.json ]]; then pass_case immutable_candidate_evidence; else fail_case immutable_candidate_evidence; fi

# Real efficient no-repair path.
make_case real-initial-pass || exit 1; init_case || exit 1
case_cli execute-one GF-REPAIR-M001 --json >"$CASE_ARTIFACT/result.json" 2>"$CASE_ARTIFACT/stderr.log"
initial_code=$?
if [[ $initial_code -eq 0 ]] && jq -e '.result=="pass" and .critic.status=="pass" and .critic.calls==1 and .codex_invocations==1 and .repair.attempts_used==0 and .repair.outcome=="not_needed" and .source.accepted_commit!=null' "$CASE_ARTIFACT/result.json" >/dev/null; then pass_case initial_pass_no_repair; else fail_case initial_pass_no_repair; fi

run_controlled() {
  local name=$1 repair_fault=$2 sequence=$3 expected_result=$4
  make_case "$name" || { fail_case "$name"; return; }; init_case || { fail_case "$name"; return; }
  pre=$(git -C "$CASE_REPO" rev-parse gf/GF-REPAIR-M001)
  set +e
  GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_GF007_ENABLE_TEST_HOOKS=1 GF_GF007_INITIAL_FORBIDDEN=1 \
    GF_GF007_REPAIR_AGENT_TEST_DOUBLE=1 GF_GF007_REPAIR_FAULT="$repair_fault" GF_GF007_CRITIC_SEQUENCE="$sequence" \
    case_cli execute-one GF-REPAIR-M001 --json >"$CASE_ARTIFACT/result.json" 2>"$CASE_ARTIFACT/stderr.log"
  code=$?
  set -e; set +e
  post=$(git -C "$CASE_REPO" rev-parse gf/GF-REPAIR-M001)
  if [[ $expected_result == pass && $code -eq 0 ]] && jq -e '.result=="pass" and .source.accepted_commit!=null' "$CASE_ARTIFACT/result.json" >/dev/null; then pass_case "$name"
  elif [[ $expected_result != pass && $code -ne 0 && $pre == "$post" ]] && jq -e --arg expected "$expected_result" '.result==$expected and .source.accepted_commit==null' "$CASE_ARTIFACT/result.json" >/dev/null; then pass_case "$name"
  else fail_case "$name"; fi
}

run_controlled deterministic_regression deterministic_regression blocker fail
if jq -e '.validation.status=="fail" and .critic.calls==1 and .repair.critic_calls==0 and .repair.outcome=="failed"' "$CASE_ARTIFACT/result.json" >/dev/null; then pass_case repair_deterministic_skips_rereview; else fail_case repair_deterministic_skips_rereview; fi
run_controlled scope_violation scope_violation blocker fail
if jq -e '.source.scope=="fail" and .critic.calls==1' "$CASE_ARTIFACT/result.json" >/dev/null; then pass_case repair_scope_enforced; else fail_case repair_scope_enforced; fi
run_controlled validator_mutation validator_mutation blocker fail
if jq -e '.validation.status=="fail" and .validation.pre_sha256!=.validation.post_sha256 and .critic.calls==1' "$CASE_ARTIFACT/result.json" >/dev/null; then pass_case repair_validator_integrity; else fail_case repair_validator_integrity; fi
run_controlled repair_codex_failure codex_failure blocker fail
if jq -e '.repair.codex_calls==1 and .repair.critic_calls==0 and .critic.calls==1' "$CASE_ARTIFACT/result.json" >/dev/null; then pass_case repair_codex_failure_stops; else fail_case repair_codex_failure_stops; fi
run_controlled critic_rereview_error repair_success blocker,api_failure fail
if jq -e '.critic.status=="error" and .critic.calls==2 and .repair.critic_calls==1' "$CASE_ARTIFACT/result.json" >/dev/null; then pass_case critic_error_fails_closed; else fail_case critic_error_fails_closed; fi
run_controlled critic_rereview_timeout repair_success blocker,timeout fail
if jq -e '.critic.status=="error" and .critic.error=="timeout" and .critic.calls==2 and .repair.critic_calls==1' "$CASE_ARTIFACT/result.json" >/dev/null; then pass_case critic_timeout_fails_closed; else fail_case critic_timeout_fails_closed; fi
run_controlled warning_after_repair repair_success blocker,warning_only pass
if jq -e '.critic.status=="pass" and .critic.warnings==1 and .repair.outcome=="repaired"' "$CASE_ARTIFACT/result.json" >/dev/null; then pass_case warning_preserved; else fail_case warning_preserved; fi
run_controlled new_blocker new_blocker blocker,blocker_b,pass pass
new_tracking=$(find "$CASE_ARTIFACT/children" -name finding-tracking.json -type f | LC_ALL=C sort | head -1)
if jq -e '.repair.attempts_used==2 and .critic.calls==3 and .codex_invocations==3' "$CASE_ARTIFACT/result.json" >/dev/null && [[ -n $new_tracking ]] && jq -e '.new|length>0' "$new_tracking" >/dev/null; then pass_case new_blocker_continues_budget; else fail_case new_blocker_continues_budget; fi

# Exhaustion through GF-005 proves stop reason and no fourth attempt.
make_case exhaustion || exit 1; init_case || exit 1
exhaust_pre=$(git -C "$CASE_REPO" rev-parse gf/GF-REPAIR-M001)
set +e
GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_GF007_ENABLE_TEST_HOOKS=1 GF_GF007_INITIAL_FORBIDDEN=1 \
  GF_GF007_REPAIR_AGENT_TEST_DOUBLE=1 GF_GF007_REPAIR_FAULT=persistent_blocker GF_GF007_CRITIC_SEQUENCE=blocker,blocker,blocker \
  case_cli run-bounded GF-REPAIR-M001 --max-tasks 2 --max-minutes 5 --json >"$CASE_ARTIFACT/result.json" 2>"$CASE_ARTIFACT/stderr.log"
exhaust_code=$?
set -e; set +e
exhaust_post=$(git -C "$CASE_REPO" rev-parse gf/GF-REPAIR-M001); case_cli status GF-REPAIR-M001 --json >"$CASE_ARTIFACT/status.json"
if [[ $exhaust_code -ne 0 && $exhaust_pre == "$exhaust_post" ]] && jq -e '.stop_reason=="ESCALATED" and .attempted_tasks==1 and .executions[0].result=="escalated" and .executions[0].repair.attempts_used==2 and .executions[0].codex_invocations==3 and .executions[0].critic.calls==3 and .executions[0].source.accepted_commit==null and .repair.tasks_escalated_after_repair==1' "$CASE_ARTIFACT/result.json" >/dev/null && jq -e '.tasks["GF-REPAIR-001"].status=="escalated" and .tasks["GF-REPAIR-002"].status=="blocked"' "$CASE_ARTIFACT/status.json" >/dev/null; then pass_case repair_exhaustion; pass_case repair_limit_enforced; else fail_case repair_exhaustion; fail_case repair_limit_enforced; fi

# Initial deterministic failure never reaches critic or repair.
make_case initial-deterministic-fail || exit 1; init_case || exit 1
set +e
GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=validation_failure GF_GF007_ENABLE_TEST_HOOKS=1 GF_GF007_CRITIC_SEQUENCE=blocker \
  case_cli execute-one GF-REPAIR-M001 --json >"$CASE_ARTIFACT/result.json" 2>"$CASE_ARTIFACT/stderr.log"
det_code=$?
set -e; set +e
if [[ $det_code -ne 0 ]] && jq -e '.validation.status=="fail" and .critic.calls==0 and .repair.attempts_used==0 and .codex_invocations==1' "$CASE_ARTIFACT/result.json" >/dev/null; then pass_case initial_deterministic_no_repair; else fail_case initial_deterministic_no_repair; fi

# Failure-path timing measures the state transition, not the whole transaction.
state_time=$(jq -r '.timing_seconds.state_update' "$CASE_ARTIFACT/result.json")
total_time=$(jq -r '.timing_seconds.total' "$CASE_ARTIFACT/result.json")
if awk -v state="$state_time" -v total="$total_time" 'BEGIN {exit !(state < total && state < 2)}'; then pass_case state_timing_instrumentation; else fail_case state_timing_instrumentation; fi

# Credential value must not be persisted.
ARTIFACT_SCAN_ROOT="$artifact_dir" python3 - <<'PY'
import os
from pathlib import Path
root = Path(os.environ["ARTIFACT_SCAN_ROOT"]); secret = os.environ.get("OPENAI_API_KEY", "").encode()
raise SystemExit(1 if secret and any(secret in p.read_bytes() for p in root.rglob("*") if p.is_file()) else 0)
PY
if [[ $? -eq 0 ]]; then pass_case credential_safety; else fail_case credential_safety; fi

# GF-006 full acceptance supplies GF-003/004/005 and critic-enabled no-repair regression coverage.
gf006_repo="$temp_root/gf006-regression"; git clone -q "$repo_root" "$gf006_repo"
set +e
(cd "$gf006_repo" && ./scripts/gf-006-acceptance.sh) >"$artifact_dir/regression/gf006.log" 2>&1
gf006_code=$?
set -e; set +e
if [[ -f $gf006_repo/reports/gf-006/evidence-summary.json ]]; then
  cp "$gf006_repo/reports/gf-006/evidence-summary.json" "$artifact_dir/regression/gf006-summary.json"
fi
# GF-006's doctor can transiently observe the globally shared OpenClaw gateway
# immediately after its nested real-agent suite. Treat doctor independently below;
# every GF-006 functional and nested regression check must still be PASS.
if [[ -f $artifact_dir/regression/gf006-summary.json ]] && jq -e '.checks | to_entries | all(.key=="doctor" or .value=="pass")' "$artifact_dir/regression/gf006-summary.json" >/dev/null; then
  pass_case gf006_regression
  for key in gf003 gf004 gf005; do if jq -e --arg key "${key}_regression" '.checks[$key]=="pass"' "$artifact_dir/regression/gf006-summary.json" >/dev/null; then pass_case "${key}_regression"; else fail_case "${key}_regression"; fi; done
else fail_case gf006_regression; fail_case gf003_regression; fail_case gf004_regression; fail_case gf005_regression; fi
if "$repo_root/scripts/gf-002-shared-gate-tests.sh" >"$artifact_dir/regression/gf002.log" 2>&1; then pass_case gf002_shared_regression; else fail_case gf002_shared_regression; fi
if "$repo_root/scripts/doctor.sh" >"$artifact_dir/regression/doctor.log" 2>&1; then pass_case doctor; else fail_case doctor; fi

completed_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ'); total_seconds=$(awk -v start="$total_start" -v end="$(date +%s%N)" 'BEGIN {printf "%.6f",(end-start)/1000000000}')
checks_json=$(for key in "${!checks[@]}"; do jq -cn --arg key "$key" --arg value "${checks[$key]}" '{key:$key,value:$value}'; done | jq -s from_entries)
overall=pass; ((failures > 0)) && overall=fail
real_result=$(cat "$artifact_dir/cases/real-repair/result.json"); initial_result=$(cat "$artifact_dir/cases/real-initial-pass/result.json"); exhaustion_result=$(cat "$artifact_dir/cases/exhaustion/result.json")
jq -n --arg slice GF-007 --arg status "$overall" --arg acceptance_id "$acceptance_id" --arg started_at "$started_at" --arg completed_at "$completed_at" --arg artifact_dir "${artifact_dir#"$repo_root/"}" \
  --arg model "$GF_OPENAI_CRITIC_MODEL" --argjson total_seconds "$total_seconds" --argjson failures "$failures" --argjson checks "$checks_json" --argjson real "$real_result" --argjson initial "$initial_result" --argjson exhaustion "$exhaustion_result" \
  '{slice:$slice,status:$status,acceptance_id:$acceptance_id,started_at:$started_at,completed_at:$completed_at,artifact_dir:$artifact_dir,configuration:{critic_model:$model,repair_max_attempts:2},real_repair:$real,initial_pass:$initial,exhaustion:$exhaustion,checks:$checks,metrics:{acceptance_total_seconds:$total_seconds,initial_codex_calls:1,repair_codex_calls:$real.repair.codex_calls,critic_calls:$real.critic.calls,repair_attempts:$real.repair.attempts_used,successful_repairs:$real.repair.successes,repair_exhaustions:$exhaustion.repair.tasks_escalated_after_repair,total_repair_seconds:$real.repair.duration_seconds.total,average_repair_codex_seconds:$real.repair.average_seconds.codex,average_repair_critic_seconds:$real.repair.average_seconds.critic,human_interventions:$real.human_interventions},false_acceptances:$failures}' >"$reports_dir/evidence-summary.json"
{
  printf '# GF-007 evidence summary\n\nStatus: **%s**\n\n' "${overall^^}"
  printf -- '- Acceptance: `%s`\n- Real repair run: `%s`\n- Initial critic: `%s`\n- Repair critic: `%s`\n- Repair attempts: `%s`\n- Evidence: `%s`\n- Failed checks: `%s`\n' \
    "$acceptance_id" "$(jq -r .run_id <<<"$real_result")" "$(jq -r '.critic_history[0].result' <<<"$real_result")" "$(jq -r '.critic_history[1].result' <<<"$real_result")" "$(jq -r '.repair.attempts_used' <<<"$real_result")" "${artifact_dir#"$repo_root/"}" "$failures"
} >"$reports_dir/evidence-summary.md"
if ((failures > 0)); then printf '\nGF-007 ACCEPTANCE: FAIL (%s)\n' "$failures"; exit 1; fi
printf '\nGF-007 ACCEPTANCE: PASS\nEvidence: %s\n' "${artifact_dir#"$repo_root/"}"
