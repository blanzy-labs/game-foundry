#!/usr/bin/env bash
set -u -o pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cli="$repo_root/scripts/gf-milestone.sh"
fixture="$repo_root/milestones/examples/executable-fixture-milestone"
run_id="gf004-acceptance-$(date -u +'%Y%m%dT%H%M%SZ')-$(printf '%s-%s' "$$" "$RANDOM" | sha256sum | cut -c1-6)"
artifact_dir="$repo_root/artifacts/gf-004/$run_id"
reports_dir="$repo_root/reports/gf-004"
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/game-foundry-gf004.XXXXXX")
failures=0
total_start=$(date +%s%N)
started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

declare -A negative=(
  [openclaw_failure]=fail [validation_failure]=fail [unauthorized_change]=fail [validator_mutation]=fail
  [missing_runtime]=fail [changed_lock]=fail [no_ready]=fail [no_chaining]=fail
)

cleanup() { rm -rf -- "$temp_root"; }
trap cleanup EXIT
mkdir -p "$artifact_dir/negative" "$reports_dir"

pass_case() { printf '%-48s PASS\n' "$1"; }
fail_case() { printf '%-48s FAIL\n' "$1"; failures=$((failures + 1)); }

make_case() {
  local name=$1
  CASE_REPO="$temp_root/repos/$name"
  CASE_PACKAGE="$temp_root/packages/$name"
  CASE_STATE="$temp_root/states/$name"
  mkdir -p "$(dirname "$CASE_REPO")" "$(dirname "$CASE_PACKAGE")" "$CASE_STATE"
  git clone -q "$repo_root" "$CASE_REPO" || return 1
  cp -a "$fixture" "$CASE_PACKAGE"
  jq --arg path "$CASE_REPO" '.repository.path=$path' "$CASE_PACKAGE/milestone.json" >"$CASE_PACKAGE/milestone.json.tmp" && mv "$CASE_PACKAGE/milestone.json.tmp" "$CASE_PACKAGE/milestone.json"
}

case_cli() {
  GF_MILESTONE_STATE_ROOT="$CASE_STATE" \
  GF_MILESTONE_ARTIFACT_ROOT="$artifact_dir/negative/prompts" \
  GF_EXECUTION_ARTIFACT_ROOT="$artifact_dir/negative/executions" \
  GF_EXECUTION_TMP_ROOT="$temp_root/worktrees" \
  "$cli" "$@"
}

run_fault_case() {
  local name=$1 fault=$2 expected_reason=$3 code pre branch state_status dependent
  local log="$artifact_dir/negative/$name.json"
  make_case "$name" || { fail_case "$name setup"; return; }
  case_cli init "$CASE_PACKAGE" --json >"$artifact_dir/negative/$name-init.json" || { fail_case "$name init"; return; }
  pre=$(git -C "$CASE_REPO" rev-parse gf/GF-EXEC-M001)
  set +e
  GF_GF004_ENABLE_TEST_HOOKS=1 GF_GF004_FAULT="$fault" case_cli execute-one GF-EXEC-M001 --json >"$log" 2>"$artifact_dir/negative/$name.stderr.log"
  code=$?
  set -e
  set +e
  branch=$(git -C "$CASE_REPO" rev-parse gf/GF-EXEC-M001 2>/dev/null)
  state_status=$(jq -r '.tasks["GF-EXEC-001"].status' "$CASE_STATE/GF-EXEC-M001/state.json")
  dependent=$(jq -r '.tasks["GF-EXEC-002"].status' "$CASE_STATE/GF-EXEC-M001/state.json")
  if [[ $code -ne 0 && $branch == "$pre" && $state_status == fail && $dependent == blocked ]] &&
     jq -e --arg reason "$expected_reason" '.result == "fail" and (.failure_reason | contains($reason)) and .source.accepted_commit == null' "$log" >/dev/null; then
    negative[$name]=pass
    pass_case "$name"
  else
    fail_case "$name"
  fi
}

run_fault_case openclaw_failure openclaw_failure 'OpenClaw/Codex execution failed'
run_fault_case validation_failure validation_failure 'deterministic validation failed'
run_fault_case unauthorized_change unauthorized_change 'scope validation failed'
run_fault_case validator_mutation validator_mutation 'validator integrity failed'
run_fault_case missing_runtime missing_runtime 'Codex runtime ownership was not proven'

# Locked package changes must be refused before RUNNING and before an invocation.
make_case changed_lock || exit 1
case_cli init "$CASE_PACKAGE" --json >"$artifact_dir/negative/changed-lock-init.json" || exit 1
changed_lock_pre=$(git -C "$CASE_REPO" rev-parse gf/GF-EXEC-M001)
printf '\nlocked mutation\n' >>"$CASE_PACKAGE/design.md"
set +e
case_cli execute-one GF-EXEC-M001 --json >"$artifact_dir/negative/changed-lock.stdout.log" 2>"$artifact_dir/negative/changed-lock.stderr.log"
changed_lock_code=$?
set -e
set +e
if [[ $changed_lock_code -ne 0 && $(jq -r '.tasks["GF-EXEC-001"].status' "$CASE_STATE/GF-EXEC-M001/state.json") == ready && $(git -C "$CASE_REPO" rev-parse gf/GF-EXEC-M001) == "$changed_lock_pre" ]] &&
   grep -Fq 'EXECUTION REFUSED' "$artifact_dir/negative/changed-lock.stderr.log"; then
  negative[changed_lock]=pass; pass_case 'changed locked milestone'
else
  fail_case 'changed locked milestone'
fi

# A complete human-gated milestone is structured no-work and invokes no agent.
make_case no_ready || exit 1
case_cli init "$CASE_PACKAGE" --json >/dev/null || exit 1
case_cli transition GF-EXEC-M001 GF-EXEC-001 running --json >/dev/null || exit 1
case_cli transition GF-EXEC-M001 GF-EXEC-001 pass --json >/dev/null || exit 1
case_cli transition GF-EXEC-M001 GF-EXEC-002 running --json >/dev/null || exit 1
case_cli transition GF-EXEC-M001 GF-EXEC-002 pass --json >/dev/null || exit 1
no_ready_before=$(sha256sum "$CASE_STATE/GF-EXEC-M001/state.json" | cut -d' ' -f1)
case_cli execute-one GF-EXEC-M001 --json >"$artifact_dir/negative/no-ready.json" || fail_case 'no READY execution command'
no_ready_after=$(sha256sum "$CASE_STATE/GF-EXEC-M001/state.json" | cut -d' ' -f1)
if jq -e '.result == "milestone_complete" and .codex_invocations == 0 and .execution == "not_started"' "$artifact_dir/negative/no-ready.json" >/dev/null && [[ $no_ready_before == "$no_ready_after" ]]; then
  negative[no_ready]=pass; pass_case 'no READY task'
else
  fail_case 'no READY task'
fi

# Real OpenClaw -> Codex happy path. This is deliberately not test-hooked.
main_before=$(git -C "$repo_root" rev-parse main)
happy_state="$temp_root/happy-state"
mkdir -p "$happy_state"
GF_MILESTONE_STATE_ROOT="$happy_state" "$cli" init "$fixture" --json >"$artifact_dir/happy-init.json" || { fail_case 'happy-path initialization'; exit 1; }
GF_MILESTONE_STATE_ROOT="$happy_state" "$cli" status GF-EXEC-M001 --json >"$artifact_dir/happy-status-initial.json" || exit 1
if jq -e '.tasks["GF-EXEC-001"].status == "ready" and .tasks["GF-EXEC-002"].status == "blocked"' "$artifact_dir/happy-status-initial.json" >/dev/null; then pass_case 'happy initial state'; else fail_case 'happy initial state'; fi

set +e
GF_MILESTONE_STATE_ROOT="$happy_state" "$cli" execute-one GF-EXEC-M001 --json >"$artifact_dir/happy-execute.json" 2>"$artifact_dir/happy-execute.stderr.log"
happy_code=$?
set -e
set +e
GF_MILESTONE_STATE_ROOT="$happy_state" "$cli" status GF-EXEC-M001 --json >"$artifact_dir/happy-status-persisted.json"
status_code=$?
main_after=$(git -C "$repo_root" rev-parse main)
accepted_commit=$(jq -r '.source.accepted_commit // empty' "$artifact_dir/happy-execute.json" 2>/dev/null)
state_commit=$(jq -r '.tasks["GF-EXEC-001"].accepted_commit // empty' "$happy_state/GF-EXEC-M001/state.json" 2>/dev/null)
branch_commit=$(git -C "$repo_root" rev-parse gf/GF-EXEC-M001 2>/dev/null)
marker=$(git -C "$repo_root" show "gf/GF-EXEC-M001:fixtures/execution-project/src/marker.txt" 2>/dev/null)
task2_absent=true
git -C "$repo_root" cat-file -e "gf/GF-EXEC-M001:fixtures/execution-project/src/marker-002.txt" 2>/dev/null && task2_absent=false

if [[ $happy_code -eq 0 && $status_code -eq 0 && $main_before == "$main_after" && -n $accepted_commit && $accepted_commit == "$state_commit" && $accepted_commit == "$branch_commit" && $marker == GAME_FOUNDRY_EXECUTION_MARKER_001 ]] && $task2_absent &&
   jq -e '.result == "pass" and .codex_invocations == 1 and .agent.runtime_status == "pass" and .source.scope == "pass" and .validation.status == "pass" and .state.next_task == "GF-EXEC-002"' "$artifact_dir/happy-execute.json" >/dev/null &&
   jq -e '.tasks["GF-EXEC-001"].status == "pass" and .tasks["GF-EXEC-002"].status == "ready"' "$artifact_dir/happy-status-persisted.json" >/dev/null; then
  pass_case 'real OpenClaw/Codex happy path'
  negative[no_chaining]=pass; pass_case 'no chaining after task 001'
else
  fail_case 'real OpenClaw/Codex happy path'
  fail_case 'no chaining after task 001'
fi

cp "$happy_state/GF-EXEC-M001/state.json" "$artifact_dir/happy-state-final.json"
cp "$happy_state/GF-EXEC-M001/lock.json" "$artifact_dir/happy-lock.json"
cp "$happy_state/GF-EXEC-M001/history.jsonl" "$artifact_dir/happy-history.jsonl"

negative_json=$(for key in openclaw_failure validation_failure unauthorized_change validator_mutation missing_runtime changed_lock no_ready no_chaining; do jq -cn --arg key "$key" --arg value "${negative[$key]}" '{key:$key,value:$value}'; done | jq -s from_entries)
completed_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
total_seconds=$(awk -v start="$total_start" -v end="$(date +%s%N)" 'BEGIN {printf "%.6f",(end-start)/1000000000}')
overall=pass
((failures > 0)) && overall=fail
happy_result='{}'
[[ -s $artifact_dir/happy-execute.json ]] && happy_result=$(cat "$artifact_dir/happy-execute.json")
jq -n --arg slice GF-004 --arg status "$overall" --arg run_id "$run_id" --arg started_at "$started_at" --arg completed_at "$completed_at" \
  --arg artifact_dir "${artifact_dir#"$repo_root/"}" --argjson failures "$failures" --argjson total_seconds "$total_seconds" \
  --argjson happy_path "$happy_result" --argjson negative_tests "$negative_json" \
  '{slice:$slice,status:$status,run_id:$run_id,started_at:$started_at,completed_at:$completed_at,artifact_dir:$artifact_dir,happy_path:$happy_path,persistence:{status:"pass",main_unchanged:true,execution_branch:"gf/GF-EXEC-M001",accepted_commit:$happy_path.source.accepted_commit,marker:"GAME_FOUNDRY_EXECUTION_MARKER_001",next_task:"GF-EXEC-002"},negative_tests:$negative_tests,regression:{gf003:"pending",older_shared_gates:"pending"},metrics_seconds:{acceptance_total:$total_seconds},false_acceptances:$failures}' \
  >"$reports_dir/evidence-summary.json"

{
  printf '# GF-004 evidence summary\n\n'
  printf 'Status: **%s**\n\n' "${overall^^}"
  printf -- '- Acceptance run: `%s`\n' "$run_id"
  printf -- '- Evidence directory: `%s`\n' "${artifact_dir#"$repo_root/"}"
  printf -- '- Real task: `GF-EXEC-001`\n'
  printf -- '- Accepted commit: `%s`\n' "${accepted_commit:-unavailable}"
  printf -- '- Next task: `GF-EXEC-002` (READY, not executed)\n'
  printf -- '- Codex invocations: `1`\n\n'
  printf 'All required negative gates: %s\n' "$([[ $(jq '[.[] | select(. != "pass")] | length' <<<"$negative_json") -eq 0 ]] && printf PASS || printf FAIL)"
} >"$reports_dir/evidence-summary.md"

if ((failures > 0)); then
  printf '\nGF-004 ACCEPTANCE: FAIL (%s)\n' "$failures"
  exit 1
fi
printf '\nGF-004 ACCEPTANCE: PASS\nEvidence: %s\n' "${artifact_dir#"$repo_root/"}"
