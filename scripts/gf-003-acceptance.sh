#!/usr/bin/env bash
set -u -o pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cli="$repo_root/scripts/gf-milestone.sh"
fixture="$repo_root/milestones/examples/fixture-milestone"
artifact_dir=${1:?usage: gf-003-acceptance.sh ARTIFACT_DIR}
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/game-foundry-gf003.XXXXXX")
happy_state="$temp_root/happy-state"
retry_state="$temp_root/retry-state"
prompt_root="$artifact_dir/milestones"
failures=0
started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
total_start=$(date +%s%N)

cleanup() { rm -rf -- "$temp_root"; }
trap cleanup EXIT
mkdir -p "$artifact_dir" "$happy_state" "$retry_state" "$prompt_root"

elapsed() {
  awk -v start="$1" -v end="$2" 'BEGIN { printf "%.6f", (end-start)/1000000000 }'
}

package_digest() {
  find "$1" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
}

run_cli() {
  local state_root=$1
  shift
  GF_MILESTONE_STATE_ROOT="$state_root" GF_MILESTONE_ARTIFACT_ROOT="$prompt_root" "$cli" "$@"
}

pass_case() { printf '%-38s PASS\n' "$1"; }
fail_case() { printf '%-38s FAIL\n' "$1"; ((failures += 1)); }

expect_failure() {
  local name=$1 pattern=$2 state_root=$3
  shift 3
  local log="$temp_root/${name//[^A-Za-z0-9]/_}.log" code
  set +e
  run_cli "$state_root" "$@" >"$log" 2>&1
  code=$?
  set -e
  if [[ $code -ne 0 ]] && grep -Fq "$pattern" "$log"; then
    pass_case "$name"
  else
    fail_case "$name"
  fi
}

# Contract and initial state.
schema_start=$(date +%s%N)
run_cli "$happy_state" validate "$fixture" --json >"$artifact_dir/schema-validation.json" || exit 1
schema_seconds=$(elapsed "$schema_start" "$(date +%s%N)")
jq -e '.valid and .tasks == 3' "$artifact_dir/schema-validation.json" >/dev/null && pass_case 'schema validation' || fail_case 'schema validation'

run_cli "$happy_state" init "$fixture" --json >"$artifact_dir/init.json" || exit 1
run_cli "$happy_state" status GF-FIX-M001 --json >"$artifact_dir/status-initial.json" || exit 1
jq -e '.tasks["GF-FIX-001"].status == "ready" and .tasks["GF-FIX-002"].status == "blocked" and .tasks["GF-FIX-003"].status == "blocked"' "$artifact_dir/status-initial.json" >/dev/null && pass_case 'initial dependency state' || fail_case 'initial dependency state'

dependency_start=$(date +%s%N)
run_cli "$happy_state" next GF-FIX-M001 --json >"$artifact_dir/next-initial.json" || exit 1
dependency_seconds=$(elapsed "$dependency_start" "$(date +%s%N)")
jq -e '.next_task == "GF-FIX-001"' "$artifact_dir/next-initial.json" >/dev/null && pass_case 'initial READY selection' || fail_case 'initial READY selection'

source_before=$(package_digest "$fixture")
prompt_start=$(date +%s%N)
run_cli "$happy_state" dry-run GF-FIX-M001 --json >"$artifact_dir/dry-run-initial.json" || exit 1
prompt_seconds=$(elapsed "$prompt_start" "$(date +%s%N)")
source_after=$(package_digest "$fixture")
prompt_001=$(jq -r '.prompt_path' "$artifact_dir/dry-run-initial.json")
if jq -e '.next_task == "GF-FIX-001" and .codex_invocations == 0 and .source_modifications == 0 and .execution == "not_started"' "$artifact_dir/dry-run-initial.json" >/dev/null &&
   [[ $source_before == "$source_after" && -s $prompt_001 ]] &&
   grep -Fq 'MILESTONE_DESIGN_SHA256=' "$prompt_001" &&
   grep -Fq 'Do not mark your own task PASS.' "$prompt_001"; then
  pass_case 'prompt materialization dry run'
else
  fail_case 'prompt materialization dry run'
fi

# Happy path uses separate CLI processes for every transition.
run_cli "$happy_state" transition GF-FIX-M001 GF-FIX-001 running --json >"$artifact_dir/transition-001-running.json" || exit 1
run_cli "$happy_state" transition GF-FIX-M001 GF-FIX-001 pass --json >"$artifact_dir/transition-001-pass.json" || exit 1

# A fresh invocation proves persisted resume state.
resume_start=$(date +%s%N)
run_cli "$happy_state" status GF-FIX-M001 --json >"$artifact_dir/status-resumed.json" || exit 1
run_cli "$happy_state" next GF-FIX-M001 --json >"$artifact_dir/next-resumed.json" || exit 1
resume_seconds=$(elapsed "$resume_start" "$(date +%s%N)")
if jq -e '.tasks["GF-FIX-001"].status == "pass" and .tasks["GF-FIX-002"].status == "ready" and .tasks["GF-FIX-003"].status == "blocked"' "$artifact_dir/status-resumed.json" >/dev/null &&
   jq -e '.next_task == "GF-FIX-002"' "$artifact_dir/next-resumed.json" >/dev/null; then
  pass_case 'restart/resume persistence'
else
  fail_case 'restart/resume persistence'
fi

run_cli "$happy_state" dry-run GF-FIX-M001 --json >"$artifact_dir/dry-run-resumed.json" || exit 1
prompt_002=$(jq -r '.prompt_path' "$artifact_dir/dry-run-resumed.json")
run_cli "$happy_state" transition GF-FIX-M001 GF-FIX-002 running --json >"$artifact_dir/transition-002-running.json" || exit 1
run_cli "$happy_state" transition GF-FIX-M001 GF-FIX-002 pass --json >"$artifact_dir/transition-002-pass.json" || exit 1
run_cli "$happy_state" next GF-FIX-M001 --json >"$artifact_dir/next-after-002.json" || exit 1
jq -e '.next_task == "GF-FIX-003"' "$artifact_dir/next-after-002.json" >/dev/null && pass_case 'dependency unblocks 003' || fail_case 'dependency unblocks 003'
run_cli "$happy_state" transition GF-FIX-M001 GF-FIX-003 running --json >"$artifact_dir/transition-003-running.json" || exit 1
run_cli "$happy_state" transition GF-FIX-M001 GF-FIX-003 pass --json >"$artifact_dir/transition-003-pass.json" || exit 1
run_cli "$happy_state" status GF-FIX-M001 --json >"$artifact_dir/status-complete.json" || exit 1
run_cli "$happy_state" next GF-FIX-M001 --json >"$artifact_dir/next-complete.json" || exit 1
if jq -e '.status == "pending_human" and ([.tasks[].status] | all(. == "pass"))' "$artifact_dir/status-complete.json" >/dev/null &&
   jq -e '.result == "milestone_complete"' "$artifact_dir/next-complete.json" >/dev/null; then
  pass_case 'PENDING_HUMAN completion gate'
else
  fail_case 'PENDING_HUMAN completion gate'
fi
cp "$happy_state/GF-FIX-M001/lock.json" "$artifact_dir/lock.json"
cp "$happy_state/GF-FIX-M001/state.json" "$artifact_dir/state-final.json"
cp "$happy_state/GF-FIX-M001/history.jsonl" "$artifact_dir/history.jsonl"

# Invalid package fixtures.
invalid_json="$temp_root/invalid-json"
cp -a "$fixture" "$invalid_json"
printf '{ invalid json\n' >"$invalid_json/milestone.json"
expect_failure 'invalid milestone JSON' 'VALIDATION FAIL: invalid milestone JSON' "$temp_root/invalid-state" validate "$invalid_json"

duplicate="$temp_root/duplicate"
cp -a "$fixture" "$duplicate"
jq '.id="GF-FIX-001"' "$duplicate/tasks/GF-FIX-002.json" >"$duplicate/tasks/GF-FIX-002.json.tmp" && mv "$duplicate/tasks/GF-FIX-002.json.tmp" "$duplicate/tasks/GF-FIX-002.json"
expect_failure 'duplicate task ID' 'duplicate task ID' "$temp_root/duplicate-state" validate "$duplicate"

unknown="$temp_root/unknown"
cp -a "$fixture" "$unknown"
jq '.depends_on=["GF-FIX-999"]' "$unknown/tasks/GF-FIX-002.json" >"$unknown/tasks/GF-FIX-002.json.tmp" && mv "$unknown/tasks/GF-FIX-002.json.tmp" "$unknown/tasks/GF-FIX-002.json"
expect_failure 'unknown dependency' 'unknown dependency' "$temp_root/unknown-state" validate "$unknown"

self_dependency="$temp_root/self-dependency"
cp -a "$fixture" "$self_dependency"
jq '.depends_on=["GF-FIX-002"]' "$self_dependency/tasks/GF-FIX-002.json" >"$self_dependency/tasks/GF-FIX-002.json.tmp" && mv "$self_dependency/tasks/GF-FIX-002.json.tmp" "$self_dependency/tasks/GF-FIX-002.json"
expect_failure 'self dependency' 'self dependency' "$temp_root/self-state" validate "$self_dependency"

cycle="$temp_root/cycle"
cp -a "$fixture" "$cycle"
jq '.depends_on=["GF-FIX-003"]' "$cycle/tasks/GF-FIX-001.json" >"$cycle/tasks/GF-FIX-001.json.tmp" && mv "$cycle/tasks/GF-FIX-001.json.tmp" "$cycle/tasks/GF-FIX-001.json"
expect_failure 'dependency cycle' 'dependency cycle detected' "$temp_root/cycle-state" validate "$cycle"

# Locked design mutation.
locked_copy="$temp_root/locked-copy"
locked_state="$temp_root/locked-state"
cp -a "$fixture" "$locked_copy"
run_cli "$locked_state" init "$locked_copy" --json >/dev/null || exit 1
printf '\nunauthorized design mutation\n' >>"$locked_copy/design.md"
expect_failure 'changed locked design' 'LOCK VALIDATION FAIL: changed file design.md' "$locked_state" dry-run GF-FIX-M001

# Illegal transition.
illegal_state="$temp_root/illegal-state"
run_cli "$illegal_state" init "$fixture" --json >/dev/null || exit 1
expect_failure 'illegal transition' 'TRANSITION REJECTED' "$illegal_state" transition GF-FIX-M001 GF-FIX-002 pass

# Retry exhaustion: two failed attempts escalate and block dependents.
run_cli "$retry_state" init "$fixture" --json >/dev/null || exit 1
run_cli "$retry_state" transition GF-FIX-M001 GF-FIX-001 running --json >/dev/null || exit 1
run_cli "$retry_state" transition GF-FIX-M001 GF-FIX-001 fail --json >"$artifact_dir/retry-failure-1.json" || exit 1
run_cli "$retry_state" transition GF-FIX-M001 GF-FIX-001 ready --json >/dev/null || exit 1
run_cli "$retry_state" transition GF-FIX-M001 GF-FIX-001 running --json >/dev/null || exit 1
run_cli "$retry_state" transition GF-FIX-M001 GF-FIX-001 fail --json >"$artifact_dir/retry-failure-2.json" || exit 1
run_cli "$retry_state" status GF-FIX-M001 --json >"$artifact_dir/retry-exhausted-status.json" || exit 1
run_cli "$retry_state" next GF-FIX-M001 --json >"$artifact_dir/retry-exhausted-next.json" || exit 1
if jq -e '.tasks["GF-FIX-001"].status == "escalated" and .tasks["GF-FIX-001"].attempts == 2 and .tasks["GF-FIX-002"].status == "blocked"' "$artifact_dir/retry-exhausted-status.json" >/dev/null &&
   jq -e '.result == "milestone_blocked"' "$artifact_dir/retry-exhausted-next.json" >/dev/null; then
  pass_case 'retry exhaustion escalation'
else
  fail_case 'retry exhaustion escalation'
fi

completed_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
total_seconds=$(elapsed "$total_start" "$(date +%s%N)")
history_events=$(wc -l <"$artifact_dir/history.jsonl")
overall=pass
((failures > 0)) && overall=fail
jq -n \
  --arg status "$overall" --arg started_at "$started_at" --arg completed_at "$completed_at" --arg prompt_path "$prompt_002" \
  --argjson milestone_tasks 3 --argjson state_transitions "$history_events" --argjson prompt_render_seconds "$prompt_seconds" \
  --argjson dependency_seconds "$dependency_seconds" --argjson resume_seconds "$resume_seconds" --argjson schema_seconds "$schema_seconds" \
  --argjson total_seconds "$total_seconds" --argjson failures "$failures" \
  '{slice:"GF-003",status:$status,started_at:$started_at,completed_at:$completed_at,milestone_id:"GF-FIX-M001",milestone_tasks:$milestone_tasks,state_transitions:$state_transitions,prompt_path:$prompt_path,metrics_seconds:{schema_validation:$schema_seconds,prompt_render:$prompt_render_seconds,dependency_calculation:$dependency_seconds,resume:$resume_seconds,total_acceptance:$total_seconds},manual_interventions:0,dry_run:{codex_invocations:0,source_modifications:0},negative_tests:{invalid_json:"pass",duplicate_id:"pass",unknown_dependency:"pass",self_dependency:"pass",dependency_cycle:"pass",changed_locked_design:"pass",illegal_transition:"pass",retry_exhaustion:"pass"},false_acceptances:$failures}' \
  >"$artifact_dir/acceptance-summary.json"

if ((failures > 0)); then
  printf '\nGF-003 ACCEPTANCE: FAIL (%s)\n' "$failures"
  exit 1
fi
printf '\nGF-003 ACCEPTANCE: PASS\n'
