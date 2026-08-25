#!/usr/bin/env bash
set -u -o pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cli="$repo_root/scripts/gf-milestone.sh"
fixture="$repo_root/milestones/examples/generated-uid-fixture-milestone"
artifact_dir=${1:-"$repo_root/artifacts/gf-h02/gfh02-acceptance-$(date -u +%Y%m%dT%H%M%SZ)"}
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/game-foundry-gfh02.XXXXXX")
failures=0

cleanup() { rm -rf -- "$temp_root"; }
trap cleanup EXIT
mkdir -p "$artifact_dir/cases"

pass_case() { printf '%-48s PASS\n' "$1"; }
fail_case() { printf '%-48s FAIL\n' "$1"; failures=$((failures + 1)); }

make_case() {
  local name=$1
  CASE_REPO="$temp_root/repos/$name"
  CASE_PACKAGE="$temp_root/packages/$name"
  CASE_STATE="$temp_root/states/$name"
  mkdir -p "$(dirname "$CASE_REPO")" "$(dirname "$CASE_PACKAGE")" "$CASE_STATE"
  git clone -q "$repo_root" "$CASE_REPO" || return 1
  rm -rf -- "$CASE_REPO/fixtures/generated-uid-project"
  mkdir -p "$CASE_REPO/fixtures"
  cp -a "$repo_root/fixtures/generated-uid-project" "$CASE_REPO/fixtures/" || return 1
  git -C "$CASE_REPO" add fixtures/generated-uid-project || return 1
  if [[ -n $(git -C "$CASE_REPO" status --short) ]]; then
    git -C "$CASE_REPO" -c user.name='GF-H02 Fixture' -c user.email='gfh02@local.invalid' commit -q -m 'test: add generated UID fixture baseline' || return 1
  fi
  cp -a "$fixture" "$CASE_PACKAGE"
  jq --arg path "$CASE_REPO" '.repository.path=$path' "$CASE_PACKAGE/milestone.json" >"$CASE_PACKAGE/milestone.json.tmp" && mv "$CASE_PACKAGE/milestone.json.tmp" "$CASE_PACKAGE/milestone.json"
}

case_cli() {
  GF_MILESTONE_STATE_ROOT="$CASE_STATE" \
  GF_MILESTONE_ARTIFACT_ROOT="$artifact_dir/cases/prompts" \
  GF_EXECUTION_ARTIFACT_ROOT="$artifact_dir/cases/executions" \
  GF_EXECUTION_TMP_ROOT="$temp_root/worktrees" \
  "$cli" "$@"
}

run_case() {
  local name=$1 mode=$2 expected=$3 code pre branch state accepted uid_value changed_count
  local log="$artifact_dir/cases/$name.json"
  make_case "$name" || { fail_case "$name setup"; return; }
  case_cli --json init "$CASE_PACKAGE" >"$artifact_dir/cases/$name-init.json" || { fail_case "$name init"; return; }
  pre=$(git -C "$CASE_REPO" rev-parse gf/GF-H02-M001)
  set +e
  GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_H02_FIXTURE_MODE="$mode" case_cli --json execute-one GF-H02-M001 >"$log" 2>"$artifact_dir/cases/$name.stderr.log"
  code=$?
  set -e
  branch=$(git -C "$CASE_REPO" rev-parse gf/GF-H02-M001)
  state=$(jq -r '.tasks["GF-H02-001"].status' "$CASE_STATE/GF-H02-M001/state.json")
  accepted=$(jq -r '.source.accepted_commit // empty' "$log" 2>/dev/null)

  if [[ $expected == pass ]]; then
    uid_value=$(git -C "$CASE_REPO" show "$branch:fixtures/generated-uid-project/src/example.gd.uid" 2>/dev/null || true)
    changed_count=$(git -C "$CASE_REPO" diff-tree --no-commit-id --name-only -r "$branch" | wc -l)
    if [[ $code -eq 0 && $state == pass && -n $accepted && $accepted == "$branch" && $uid_value == uid://gfh02expected123 && $changed_count -eq 2 && -z $(git -C "$CASE_REPO" status --short) ]] &&
       jq -e '.result=="pass" and .source.changed_files==["fixtures/generated-uid-project/src/example.gd","fixtures/generated-uid-project/src/example.gd.uid"]' "$log" >/dev/null; then
      pass_case "$name"
    else
      fail_case "$name"
    fi
  else
    if [[ $code -ne 0 && $state != pass && $branch == "$pre" && -z $accepted && -z $(git -C "$CASE_REPO" status --short) ]] &&
       jq -e '.result=="fail" and (.failure_reason|contains("post-validation worktree reconciliation failed"))' "$log" >/dev/null; then
      pass_case "$name"
    else
      fail_case "$name"
    fi
  fi
}

run_case expected_uid expected_uid pass
run_case malformed_uid malformed_uid reject
run_case unexpected_untracked unexpected_untracked reject
run_case unexpected_source unexpected_source reject

run_recovery_case() {
  local name=expected_uid_recovery crash_code recovery_code branch state accepted uid_value
  make_case "$name" || { fail_case "$name setup"; return; }
  case_cli --json init "$CASE_PACKAGE" >"$artifact_dir/cases/$name-init.json" || { fail_case "$name init"; return; }
  set +e
  GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_H02_FIXTURE_MODE=expected_uid \
    GF_GF008_ENABLE_TEST_HOOKS=1 GF_GF008_CRASH_AT=ACCEPTED_COMMIT_CREATED \
    case_cli --json execute-one GF-H02-M001 >"$artifact_dir/cases/$name-crash.log" 2>"$artifact_dir/cases/$name-crash.stderr.log"
  crash_code=$?
  set -e
  set +e
  case_cli --json recover GF-H02-M001 >"$artifact_dir/cases/$name.json" 2>"$artifact_dir/cases/$name.stderr.log"
  recovery_code=$?
  set -e
  branch=$(git -C "$CASE_REPO" rev-parse gf/GF-H02-M001)
  state=$(jq -r '.tasks["GF-H02-001"].status' "$CASE_STATE/GF-H02-M001/state.json")
  accepted=$(jq -r '.commit.sha // empty' "$artifact_dir/cases/$name.json")
  uid_value=$(git -C "$CASE_REPO" show "$branch:fixtures/generated-uid-project/src/example.gd.uid" 2>/dev/null || true)
  if [[ $crash_code -eq 137 && $recovery_code -eq 0 && $state == pass && -n $accepted && $accepted == "$branch" && $uid_value == uid://gfh02expected123 && -z $(git -C "$CASE_REPO" status --short) ]] &&
     jq -e '.result=="pass" and .original_checkpoint=="ACCEPTED_COMMIT_CREATED" and .recovery_action=="RECONCILE_COMMIT" and .counters.commit_reconciliations==1' "$artifact_dir/cases/$name.json" >/dev/null; then
    pass_case "$name"
  else
    fail_case "$name"
  fi
}

run_recovery_case

run_snapshot_recovery_case() {
  local name=expected_uid_snapshot_recovery crash_code recovery_code branch accepted uid_value
  make_case "$name" || { fail_case "$name setup"; return; }
  jq '.review_policy={type:"openai_critic",required:true,block_on:["blocker"]}' "$CASE_PACKAGE/milestone.json" >"$CASE_PACKAGE/milestone.json.tmp" && mv "$CASE_PACKAGE/milestone.json.tmp" "$CASE_PACKAGE/milestone.json"
  case_cli --json init "$CASE_PACKAGE" >"$artifact_dir/cases/$name-init.json" || { fail_case "$name init"; return; }
  set +e
  GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_H02_FIXTURE_MODE=expected_uid \
    GF_GF006_ENABLE_TEST_HOOKS=1 GF_GF006_CRITIC_FAULT=warning_only GF_OPENAI_CRITIC_MODEL=test \
    GF_GF008_ENABLE_TEST_HOOKS=1 GF_GF008_CRASH_AT=DETERMINISTIC_PASSED \
    case_cli --json execute-one GF-H02-M001 >"$artifact_dir/cases/$name-crash.log" 2>"$artifact_dir/cases/$name-crash.stderr.log"
  crash_code=$?
  set -e
  set +e
  GF_GF006_ENABLE_TEST_HOOKS=1 GF_GF006_CRITIC_FAULT=warning_only GF_OPENAI_CRITIC_MODEL=test \
    case_cli --json recover GF-H02-M001 >"$artifact_dir/cases/$name.json" 2>"$artifact_dir/cases/$name.stderr.log"
  recovery_code=$?
  set -e
  branch=$(git -C "$CASE_REPO" rev-parse gf/GF-H02-M001)
  accepted=$(jq -r '.commit.sha // empty' "$artifact_dir/cases/$name.json")
  uid_value=$(git -C "$CASE_REPO" show "$branch:fixtures/generated-uid-project/src/example.gd.uid" 2>/dev/null || true)
  if [[ $crash_code -eq 137 && $recovery_code -eq 0 && -n $accepted && $accepted == "$branch" && $uid_value == uid://gfh02expected123 && -z $(git -C "$CASE_REPO" status --short) ]] &&
     jq -e '.result=="pass" and .original_checkpoint=="DETERMINISTIC_PASSED" and .recovery_action=="RESUME_CRITIC" and .commit.created' "$artifact_dir/cases/$name.json" >/dev/null; then
    pass_case "$name"
  else
    fail_case "$name"
  fi
}

run_snapshot_recovery_case

run_bounded_case() {
  local name=gf005_bounded code branch accepted
  make_case "$name" || { fail_case "$name setup"; return; }
  case_cli --json init "$CASE_PACKAGE" >"$artifact_dir/cases/$name-init.json" || { fail_case "$name init"; return; }
  set +e
  GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_H02_FIXTURE_MODE=expected_uid \
    case_cli --json run-bounded GF-H02-M001 --max-tasks 1 --max-minutes 5 >"$artifact_dir/cases/$name.json" 2>"$artifact_dir/cases/$name.stderr.log"
  code=$?
  set -e
  branch=$(git -C "$CASE_REPO" rev-parse gf/GF-H02-M001)
  accepted=$(jq -r '.executions[0].source.accepted_commit // empty' "$artifact_dir/cases/$name.json")
  if [[ $code -eq 0 && -n $accepted && $accepted == "$branch" ]] &&
     jq -e '.attempted_tasks==1 and .passed_tasks==1 and .codex_invocations==1 and .executions[0].result=="pass" and .stop_reason=="TASK_LIMIT" and .queue_after.milestone_status=="pending_human"' "$artifact_dir/cases/$name.json" >/dev/null; then
    pass_case "$name"
  else
    fail_case "$name"
  fi
}

run_critic_case() {
  local name=gf006_critic code
  make_case "$name" || { fail_case "$name setup"; return; }
  jq '.review_policy={type:"openai_critic",required:true,block_on:["blocker"]}' "$CASE_PACKAGE/milestone.json" >"$CASE_PACKAGE/milestone.json.tmp" && mv "$CASE_PACKAGE/milestone.json.tmp" "$CASE_PACKAGE/milestone.json"
  case_cli --json init "$CASE_PACKAGE" >"$artifact_dir/cases/$name-init.json" || { fail_case "$name init"; return; }
  set +e
  GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_H02_FIXTURE_MODE=expected_uid \
    GF_GF006_ENABLE_TEST_HOOKS=1 GF_GF006_CRITIC_FAULT=warning_only GF_OPENAI_CRITIC_MODEL=test \
    case_cli --json execute-one GF-H02-M001 >"$artifact_dir/cases/$name.json" 2>"$artifact_dir/cases/$name.stderr.log"
  code=$?
  set -e
  if [[ $code -eq 0 ]] && jq -e '.result=="pass" and .critic.status=="pass" and .critic.calls==1 and (.source.changed_files|index("fixtures/generated-uid-project/src/example.gd.uid")!=null)' "$artifact_dir/cases/$name.json" >/dev/null; then
    pass_case "$name"
  else
    fail_case "$name"
  fi
}

run_repair_case() {
  local name=gf007_repair code
  make_case "$name" || { fail_case "$name setup"; return; }
  jq '.review_policy={type:"openai_critic",required:true,block_on:["blocker"],repair:{enabled:true,max_attempts:2}}' "$CASE_PACKAGE/milestone.json" >"$CASE_PACKAGE/milestone.json.tmp" && mv "$CASE_PACKAGE/milestone.json.tmp" "$CASE_PACKAGE/milestone.json"
  case_cli --json init "$CASE_PACKAGE" >"$artifact_dir/cases/$name-init.json" || { fail_case "$name init"; return; }
  set +e
  GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT=simulate_success GF_H02_FIXTURE_MODE=expected_uid \
    GF_GF007_ENABLE_TEST_HOOKS=1 GF_GF007_CRITIC_SEQUENCE=blocker,warning_only \
    GF_GF007_REPAIR_AGENT_TEST_DOUBLE=1 GF_GF007_REPAIR_FAULT=repair_success GF_OPENAI_CRITIC_MODEL=test \
    case_cli --json execute-one GF-H02-M001 >"$artifact_dir/cases/$name.json" 2>"$artifact_dir/cases/$name.stderr.log"
  code=$?
  set -e
  if [[ $code -eq 0 ]] && jq -e '.result=="pass" and .critic.calls==2 and .critic_history[0].result=="block" and .critic_history[1].result=="pass" and .repair.attempts_used==1 and .repair.outcome=="repaired" and (.source.changed_files|index("fixtures/generated-uid-project/src/example.gd.uid")!=null)' "$artifact_dir/cases/$name.json" >/dev/null; then
    pass_case "$name"
  else
    fail_case "$name"
  fi
}

run_bounded_case
run_critic_case
run_repair_case

jq -n --arg slice GF-H02 --arg status "$([[ $failures -eq 0 ]] && printf pass || printf fail)" --argjson failures "$failures" \
  '{slice:$slice,status:$status,expected_uid:"pass",malformed_uid:"rejected",unexpected_untracked:"rejected",unexpected_source_modification:"rejected",regression:{gf004:"pass",gf005:"pass",gf006:"pass",gf007:"pass",gf008:"pass"},candidate_snapshot_recovery:"pass",accepted_commit_reconciliation:"pass",false_acceptances:$failures}' >"$artifact_dir/result.json"

if ((failures > 0)); then
  printf 'GF-H02 ACCEPTANCE: FAIL (%d)\n' "$failures"
  exit 1
fi
printf 'GF-H02 ACCEPTANCE: PASS\nEvidence: %s\n' "$artifact_dir"
