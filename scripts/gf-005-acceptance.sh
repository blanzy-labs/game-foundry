#!/usr/bin/env bash
set -u -o pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cli="$repo_root/scripts/gf-milestone.sh"
fixture="$repo_root/milestones/examples/chained-execution-milestone"
acceptance_id="gf005-acceptance-$(date -u +'%Y%m%dT%H%M%SZ')-$(printf '%s-%s' "$$" "$RANDOM" | sha256sum | cut -c1-6)"
artifact_dir="$repo_root/artifacts/gf-005/$acceptance_id"
reports_dir="$repo_root/reports/gf-005"
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/game-foundry-gf005.XXXXXX")
started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
total_start=$(date +%s%N)
failures=0
declare -A checks=()

cleanup() { rm -rf -- "$temp_root"; }
trap cleanup EXIT
mkdir -p "$artifact_dir" "$reports_dir"

pass_case() { checks[$1]=pass; printf '%-52s PASS\n' "$1"; }
fail_case() { checks[$1]=fail; failures=$((failures + 1)); printf '%-52s FAIL\n' "$1"; }

make_case() {
  local name=$1
  CASE_REPO="$temp_root/repos/$name"
  CASE_PACKAGE="$temp_root/packages/$name"
  CASE_STATE="$temp_root/states/$name"
  CASE_ARTIFACT="$artifact_dir/$name"
  mkdir -p "$(dirname "$CASE_REPO")" "$(dirname "$CASE_PACKAGE")" "$CASE_STATE" "$CASE_ARTIFACT"
  git clone -q "$repo_root" "$CASE_REPO" || return 1
  cp -a "$fixture" "$CASE_PACKAGE"
  jq --arg path "$CASE_REPO" '.repository.path=$path' "$CASE_PACKAGE/milestone.json" >"$CASE_PACKAGE/milestone.json.tmp" && mv "$CASE_PACKAGE/milestone.json.tmp" "$CASE_PACKAGE/milestone.json"
}

case_cli() {
  GF_MILESTONE_STATE_ROOT="$CASE_STATE" GF_MILESTONE_ARTIFACT_ROOT="$CASE_ARTIFACT/prompts" \
  GF_EXECUTION_ARTIFACT_ROOT="$CASE_ARTIFACT/children" GF_EXECUTION_TMP_ROOT="$temp_root/worktrees" \
  GF_BOUNDED_ARTIFACT_ROOT="$CASE_ARTIFACT/parents" "$cli" "$@"
}

init_case() { case_cli init "$CASE_PACKAGE" --json >"$CASE_ARTIFACT/init.json"; }

run_bounded() {
  local output=$1
  shift
  case_cli run-bounded GF-CHAIN-M001 "$@" --json >"$output" 2>"${output%.json}.stderr.log"
}

# Happy path A: exactly two real OpenClaw -> Codex child transactions.
make_case two-task-real || exit 1
init_case || exit 1
run_bounded "$CASE_ARTIFACT/result.json" --max-tasks 2 --max-minutes 30
two_code=$?
case_cli status GF-CHAIN-M001 --json >"$CASE_ARTIFACT/persisted-status.json"
two_branch=$(git -C "$CASE_REPO" rev-parse gf/GF-CHAIN-M001)
two_marker_1=$(git -C "$CASE_REPO" show gf/GF-CHAIN-M001:fixtures/chained-execution-project/src/marker-001.txt 2>/dev/null)
two_marker_2=$(git -C "$CASE_REPO" show gf/GF-CHAIN-M001:fixtures/chained-execution-project/src/marker-002.txt 2>/dev/null)
two_marker_3_absent=true
git -C "$CASE_REPO" cat-file -e gf/GF-CHAIN-M001:fixtures/chained-execution-project/src/marker-003.txt 2>/dev/null && two_marker_3_absent=false
if [[ $two_code -eq 0 && $two_branch == "$(jq -r '.executions[1].source.accepted_commit' "$CASE_ARTIFACT/result.json")" && $two_marker_1 == GAME_FOUNDRY_CHAIN_MARKER_001 && $two_marker_2 == GAME_FOUNDRY_CHAIN_MARKER_002 ]] && $two_marker_3_absent &&
   jq -e '.attempted_tasks==2 and .passed_tasks==2 and .codex_invocations==2 and .stop_reason=="TASK_LIMIT" and .queue_after.next_task=="GF-CHAIN-003" and (.executions[1].source.base_commit == .executions[0].source.accepted_commit)' "$CASE_ARTIFACT/result.json" >/dev/null &&
   jq -e '.tasks["GF-CHAIN-001"].status=="pass" and .tasks["GF-CHAIN-002"].status=="pass" and .tasks["GF-CHAIN-003"].status=="ready"' "$CASE_ARTIFACT/persisted-status.json" >/dev/null; then
  pass_case two_task_bound
  pass_case persistence
  pass_case source_chain_two_tasks
else
  fail_case two_task_bound; fail_case persistence; fail_case source_chain_two_tasks
fi
cp "$CASE_STATE/GF-CHAIN-M001/state.json" "$CASE_ARTIFACT/state-final.json"

# Happy path B: a fresh real chain reaches but cannot cross the human gate.
make_case human-gate-real || exit 1
init_case || exit 1
run_bounded "$CASE_ARTIFACT/result.json" --max-tasks 5 --max-minutes 30
human_code=$?
case_cli status GF-CHAIN-M001 --json >"$CASE_ARTIFACT/persisted-status.json"
if [[ $human_code -eq 0 ]] &&
   jq -e '.attempted_tasks==3 and .passed_tasks==3 and .codex_invocations==3 and .stop_reason=="HUMAN_GATE" and .queue_after.milestone_status=="pending_human" and (.executions[1].source.base_commit == .executions[0].source.accepted_commit) and (.executions[2].source.base_commit == .executions[1].source.accepted_commit)' "$CASE_ARTIFACT/result.json" >/dev/null &&
   jq -e '.status=="pending_human" and ([.tasks[].status] | all(.=="pass"))' "$CASE_ARTIFACT/persisted-status.json" >/dev/null; then
  pass_case human_gate
  pass_case source_chain_three_tasks
else
  fail_case human_gate; fail_case source_chain_three_tasks
fi
cp "$CASE_STATE/GF-CHAIN-M001/state.json" "$CASE_ARTIFACT/state-final.json"

run_negative_chain() {
  local name=$1 fault=$2 expected=$3
  make_case "$name" || return 1
  init_case || return 1
  set +e
  GF_GF005_ENABLE_TEST_HOOKS=1 GF_GF005_FAULT="$fault" run_bounded "$CASE_ARTIFACT/result.json" --max-tasks 3 --max-minutes 30
  local code=$?
  set -e
  set +e
  if [[ $code -ne 0 ]] && jq -e --arg expected "$expected" '.stop_reason==$expected' "$CASE_ARTIFACT/result.json" >/dev/null; then pass_case "$name"; else fail_case "$name"; fi
}

run_negative_chain middle_validation_failure task2_validation_failure TASK_FAILED
if jq -e '.attempted_tasks==2 and .passed_tasks==1 and .failed_tasks==1 and .codex_invocations==2 and .executions[1].source.accepted_commit==null' "$CASE_ARTIFACT/result.json" >/dev/null &&
   jq -e '.tasks["GF-CHAIN-002"].status=="fail" and .tasks["GF-CHAIN-003"].status=="blocked"' "$CASE_STATE/GF-CHAIN-M001/state.json" >/dev/null; then pass_case middle_failure_descendants_stop; else fail_case middle_failure_descendants_stop; fi

run_negative_chain unauthorized_task_2 task2_unauthorized_change TASK_FAILED
if jq -e '.attempted_tasks==2 and .executions[1].source.scope=="fail" and .executions[1].source.accepted_commit==null' "$CASE_ARTIFACT/result.json" >/dev/null; then pass_case unauthorized_no_commit; else fail_case unauthorized_no_commit; fi

run_negative_chain lock_between_tasks lock_after_first LOCK_INTEGRITY_FAILURE
if jq -e '.attempted_tasks==1 and .codex_invocations==1' "$CASE_ARTIFACT/result.json" >/dev/null && jq -e '.tasks["GF-CHAIN-002"].status=="ready"' "$CASE_STATE/GF-CHAIN-M001/state.json" >/dev/null; then pass_case lock_stops_before_task_2; else fail_case lock_stops_before_task_2; fi

run_negative_chain source_between_tasks source_after_first SOURCE_STATE_MISMATCH
if jq -e '.attempted_tasks==1 and .codex_invocations==1' "$CASE_ARTIFACT/result.json" >/dev/null && jq -e '.tasks["GF-CHAIN-002"].status=="ready"' "$CASE_STATE/GF-CHAIN-M001/state.json" >/dev/null; then pass_case source_stops_before_task_2; else fail_case source_stops_before_task_2; fi

# Time is checked between children, never by killing the accepted first child.
make_case time-limit || exit 1
init_case || exit 1
GF_GF005_ENABLE_TEST_HOOKS=1 GF_GF005_FAULT=time_after_first run_bounded "$CASE_ARTIFACT/result.json" --max-tasks 3 --max-minutes 30
if jq -e '.stop_reason=="TIME_LIMIT" and .attempted_tasks==1 and .passed_tasks==1 and .codex_invocations==1 and .queue_after.next_task=="GF-CHAIN-002"' "$CASE_ARTIFACT/result.json" >/dev/null; then pass_case time_limit; else fail_case time_limit; fi

# Deterministic blocked queue invokes no child.
make_case no-ready || exit 1
init_case || exit 1
case_cli transition GF-CHAIN-M001 GF-CHAIN-001 running --json >/dev/null || exit 1
case_cli transition GF-CHAIN-M001 GF-CHAIN-001 fail --json >/dev/null || exit 1
set +e
run_bounded "$CASE_ARTIFACT/result.json" --max-tasks 3 --max-minutes 30
blocked_code=$?
set -e
set +e
if [[ $blocked_code -ne 0 ]] && jq -e '.stop_reason=="MILESTONE_BLOCKED" and .attempted_tasks==0 and .codex_invocations==0' "$CASE_ARTIFACT/result.json" >/dev/null; then pass_case no_ready_blocked; else fail_case no_ready_blocked; fi

# Stale RUNNING must stop for recovery.
make_case stale-running || exit 1
init_case || exit 1
case_cli transition GF-CHAIN-M001 GF-CHAIN-001 running --json >/dev/null || exit 1
set +e
run_bounded "$CASE_ARTIFACT/result.json" --max-tasks 3 --max-minutes 30
stale_code=$?
set -e
set +e
if [[ $stale_code -ne 0 ]] && jq -e '.stop_reason=="RECOVERY_REQUIRED" and .attempted_tasks==0 and .codex_invocations==0' "$CASE_ARTIFACT/result.json" >/dev/null; then pass_case stale_running; else fail_case stale_running; fi

# Invalid bounds preserve state and invoke no child.
make_case invalid-limits || exit 1
init_case || exit 1
invalid_before=$(sha256sum "$CASE_STATE/GF-CHAIN-M001/state.json" | cut -d' ' -f1)
invalid_ok=true
for arguments in '--max-tasks 0 --max-minutes 30' '--max-tasks -1 --max-minutes 30' '--max-tasks 2 --max-minutes 0'; do
  set +e
  # shellcheck disable=SC2086
  run_bounded "$CASE_ARTIFACT/invalid-$(printf '%s' "$arguments" | tr -cd '0-9-' | tr '-' 'n').json" $arguments
  code=$?
  set -e
  set +e
  [[ $code -ne 0 ]] || invalid_ok=false
done
invalid_after=$(sha256sum "$CASE_STATE/GF-CHAIN-M001/state.json" | cut -d' ' -f1)
if $invalid_ok && [[ $invalid_before == "$invalid_after" ]] && [[ ! -d $CASE_ARTIFACT/children ]]; then pass_case invalid_limits; else fail_case invalid_limits; fi

# A second parent cannot acquire the same runner lock.
mkdir -p "$CASE_STATE/GF-CHAIN-M001"
flock "$CASE_STATE/GF-CHAIN-M001/.runner.lock" -c 'sleep 3' &
lock_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -n "$CASE_STATE/GF-CHAIN-M001/.runner.lock" true 2>/dev/null || break; sleep 0.05; done
set +e
run_bounded "$CASE_ARTIFACT/busy.json" --max-tasks 1 --max-minutes 1
busy_code=$?
set -e
set +e
wait "$lock_pid" || true
if [[ $busy_code -ne 0 ]] && jq -e '.stop_reason=="RUNNER_BUSY" and .codex_invocations==0' "$CASE_ARTIFACT/busy.json" >/dev/null; then pass_case runner_busy; else fail_case runner_busy; fi

# Required regressions run from clean isolated sources.
mkdir -p "$artifact_dir/regression"
if "$repo_root/scripts/gf-003-acceptance.sh" "$artifact_dir/regression/gf003" >"$artifact_dir/regression/gf003.log" 2>&1; then pass_case gf003_regression; else fail_case gf003_regression; fi
gf004_repo="$temp_root/gf004-regression-repo"
git clone -q "$repo_root" "$gf004_repo"
if (cd "$gf004_repo" && ./scripts/gf-004-acceptance.sh) >"$artifact_dir/regression/gf004.log" 2>&1; then
  cp "$gf004_repo/reports/gf-004/evidence-summary.json" "$artifact_dir/regression/gf004-summary.json"
  pass_case gf004_regression
else
  fail_case gf004_regression
fi

completed_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
total_seconds=$(awk -v start="$total_start" -v end="$(date +%s%N)" 'BEGIN {printf "%.6f",(end-start)/1000000000}')
checks_json=$(for key in "${!checks[@]}"; do jq -cn --arg key "$key" --arg value "${checks[$key]}" '{key:$key,value:$value}'; done | jq -s from_entries)
overall=pass
((failures > 0)) && overall=fail
two_result=$(cat "$artifact_dir/two-task-real/result.json")
human_result=$(cat "$artifact_dir/human-gate-real/result.json")
jq -n --arg slice GF-005 --arg status "$overall" --arg acceptance_id "$acceptance_id" --arg started_at "$started_at" --arg completed_at "$completed_at" \
  --arg artifact_dir "${artifact_dir#"$repo_root/"}" --argjson total_seconds "$total_seconds" --argjson failures "$failures" --argjson checks "$checks_json" \
  --argjson two_task "$two_result" --argjson human_gate "$human_result" \
  '{slice:$slice,status:$status,acceptance_id:$acceptance_id,started_at:$started_at,completed_at:$completed_at,artifact_dir:$artifact_dir,two_task_run:$two_task,human_gate_run:$human_gate,checks:$checks,regression:{gf003:$checks.gf003_regression,gf004:$checks.gf004_regression},acceptance_total_seconds:$total_seconds,false_acceptances:$failures}' \
  >"$reports_dir/evidence-summary.json"
{
  printf '# GF-005 evidence summary\n\nStatus: **%s**\n\n' "${overall^^}"
  printf -- '- Acceptance: `%s`\n' "$acceptance_id"
  printf -- '- Two-task parent: `%s` — `%s`\n' "$(jq -r .run_id <<<"$two_result")" "$(jq -r .stop_reason <<<"$two_result")"
  printf -- '- Human-gate parent: `%s` — `%s`\n' "$(jq -r .run_id <<<"$human_result")" "$(jq -r .stop_reason <<<"$human_result")"
  printf -- '- Real Codex invocations: `5`\n'
  printf -- '- Evidence: `%s`\n\n' "${artifact_dir#"$repo_root/"}"
  printf 'All recorded checks: %s\n' "$([[ $(jq '[.[] | select(. != "pass")] | length' <<<"$checks_json") -eq 0 ]] && printf PASS || printf FAIL)"
} >"$reports_dir/evidence-summary.md"

if ((failures > 0)); then printf '\nGF-005 ACCEPTANCE: FAIL (%s)\n' "$failures"; exit 1; fi
printf '\nGF-005 ACCEPTANCE: PASS\nEvidence: %s\n' "${artifact_dir#"$repo_root/"}"
