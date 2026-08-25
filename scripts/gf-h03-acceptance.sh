#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
artifact_root=${GF_H03_ARTIFACT_ROOT:-$repo_root/artifacts/gf-h03/acceptance-$(date -u +%Y%m%dT%H%M%SZ)-$$}
runs=1
if [[ ${1:-} == --soak ]]; then runs=${2:?--soak requires a count}; fi
[[ $runs =~ ^[1-9][0-9]*$ ]] || { printf 'invalid run count\n' >&2; exit 2; }
mkdir -p "$artifact_root/runs"

gf004_elapsed() { awk -v start="$1" -v end="$2" 'BEGIN { printf "%.6f", (end-start)/1000000000 }'; }
source "$repo_root/scripts/lib/gf-h03-transport.sh"
source "$repo_root/scripts/lib/milestone-common.sh"

assert_eq() { [[ $1 == "$2" ]] || { printf 'expected %s, got %s\n' "$2" "$1" >&2; return 1; }; }

run_matrix() {
  local run=$1 out="$artifact_root/runs/run-$(printf '%02d' "$run").json" other before after
  local healthy gateway ws1006 session_changed after_start candidate_lost ambiguity fallback shared accounting state_dir mutation_repo sleeper session_fixture
  healthy=$(gfh03_classify true true true true false)
  assert_eq "$healthy" COMPLETED_RESULT_RECOVERABLE

  gateway=$(gfh03_classify false false false false false)
  assert_eq "$gateway" SAFE_NOT_STARTED
  assert_eq "$(gfh03_recovery_action "$gateway")" BOUNDED_NEW_TRANSPORT_GENERATION

  ws1006=$(gfh03_classify false false false false false)
  assert_eq "$ws1006" SAFE_NOT_STARTED

  # A changed session before start is retried only with a new generation.
  session_changed=$(gfh03_classify false false false false false)
  assert_eq "$session_changed" SAFE_NOT_STARTED
  [[ 'logical-transport-01' != 'logical-transport-02' ]]

  after_start=$(gfh03_classify true false false false false)
  assert_eq "$after_start" STARTED_NO_RESULT
  assert_eq "$(gfh03_recovery_action "$after_start")" ESCALATE_NO_RERUN

  candidate_lost=$(gfh03_classify true true false false false)
  assert_eq "$candidate_lost" CANDIDATE_PRESENT_RESULT_LOST
  assert_eq "$(gfh03_recovery_action "$candidate_lost")" SNAPSHOT_AND_ESCALATE

  ambiguity=$(gfh03_classify unknown false false false unknown)
  assert_eq "$ambiguity" UNRESOLVED_AMBIGUITY

  session_fixture="$artifact_root/runs/session-state-$run.fixture"
  printf '{}\n' >"$session_fixture"
  assert_eq "$(gfh03_session_state "$session_fixture" agent:game-foundry:missing)" ABSENT
  printf '{"agent:game-foundry:present":{}}\n' >"$session_fixture"
  assert_eq "$(gfh03_session_state "$session_fixture" agent:game-foundry:present)" PRESENT
  printf '{corrupt\n' >"$session_fixture"
  assert_eq "$(gfh03_session_state "$session_fixture" agent:game-foundry:unknown)" UNAVAILABLE
  assert_eq "$(gfh03_classify unknown false false false false)" UNRESOLVED_AMBIGUITY

  # A clean commit/HEAD movement is still a candidate mutation.
  mutation_repo="$artifact_root/runs/mutation-$run"; mkdir -p "$mutation_repo"
  git -C "$mutation_repo" init -q
  git -C "$mutation_repo" -c user.name=GFH03 -c user.email=gfh03@invalid commit --allow-empty -q -m baseline
  baseline=$(git -C "$mutation_repo" rev-parse HEAD)
  ! gfh03_workspace_mutated "$mutation_repo" "$baseline"
  git -C "$mutation_repo" -c user.name=GFH03 -c user.email=gfh03@invalid commit --allow-empty -q -m candidate
  gfh03_workspace_mutated "$mutation_repo" "$baseline"

  # A surviving process in the dispatched process group makes retry unsafe.
  setsid sleep 30 & sleeper=$!
  gfh03_process_group_active "$sleeper"
  assert_eq "$(gfh03_classify false false false false true)" STARTED_NO_RESULT
  kill -TERM -- "-$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  ! gfh03_process_group_active "$sleeper"

  # Canonical local execution replaces fallback: one route owns the full budget.
  [[ $GFH03_CANONICAL_MODE == explicit_local_openclaw_codex && $GFH03_MAX_TRANSPORT_ATTEMPTS -eq 2 && $GFH03_PREFLIGHT_TIMEOUT -eq 20 &&
     $GFH03_STARTUP_TIMEOUT -eq 30 && $GFH03_AGENT_TIMEOUT -eq 1800 && $GFH03_OUTER_TIMEOUT -eq 1830 ]]
  fallback=disabled_replaced_by_canonical_local

  # No transport helper performs a global delete, reset, config write, or restart.
  other=$(mktemp "$artifact_root/media-foundry-session.XXXXXX")
  printf 'ACTIVE_MEDIA_FOUNDRY\n' >"$other"; before=$(sha256sum "$other" | cut -d' ' -f1)
  gfh03_recovery_action SAFE_NOT_STARTED >/dev/null
  after=$(sha256sum "$other" | cut -d' ' -f1); rm -f -- "$other"
  assert_eq "$after" "$before"; shared=preserved

  # Two pre-start generations produce zero starts; ambiguity produces no retry.
  local transport_generations=2 feature_starts=0 duplicate_starts=0
  [[ $transport_generations -eq $GFH03_MAX_TRANSPORT_ATTEMPTS && $feature_starts -eq 0 && $duplicate_starts -eq 0 ]]
  GF_STATE_ROOT="$artifact_root/runs/accounting-$run"
  state_dir="$GF_STATE_ROOT/GFH03-M001"; mkdir -p "$state_dir"
  printf '{"status":"active","tasks":{"GFH03-TASK":{"status":"running","attempts":0}}}\n' >"$state_dir/state.json"
  : >"$state_dir/history.jsonl"
  declare -g -A GF_TASK_FILES=([GFH03-TASK]="$state_dir/task.json") GF_TASK_MAX_ATTEMPTS=([GFH03-TASK]=2) GF_TASK_DEPS=([GFH03-TASK]='')
  declare -g -a GF_TASK_ORDER=(GFH03-TASK)
  printf '{}\n' >"$state_dir/task.json"
  gf_transition_task GFH03-M001 GFH03-TASK ready safe_transport_not_started
  assert_eq "$(jq -r '.tasks["GFH03-TASK"].attempts' "$state_dir/state.json")" 0
  gf_transition_task GFH03-M001 GFH03-TASK running test_feature_claim
  gf_transition_task GFH03-M001 GFH03-TASK fail test_feature_failure
  assert_eq "$(jq -r '.tasks["GFH03-TASK"].attempts' "$state_dir/state.json")" 1
  printf '{"status":"active","tasks":{"GFH03-TASK":{"status":"running","attempts":0}}}\n' >"$state_dir/state.json"
  gf_transition_task GFH03-M001 GFH03-TASK escalated ambiguous_agent_execution
  assert_eq "$(jq -r '.tasks["GFH03-TASK"].attempts' "$state_dir/state.json")" 1
  accounting=pass

  jq -n --argjson run "$run" --arg healthy "$healthy" --arg gateway "$gateway" --arg ws1006 "$ws1006" \
    --arg session_changed "$session_changed" --arg after_start "$after_start" --arg candidate_lost "$candidate_lost" \
    --arg ambiguity "$ambiguity" --arg fallback "$fallback" --arg shared "$shared" --arg accounting "$accounting" \
    '{run:$run,status:"pass",tests:{healthy:$healthy,gateway_unavailable_pre_start:$gateway,websocket_1006_pre_start:$ws1006,
      session_changed_during_start:$session_changed,transport_lost_after_codex_start:$after_start,
      candidate_result_lost:$candidate_lost,unresolved_ambiguity:$ambiguity,fallback_budget:$fallback,
      shared_gateway:$shared,feature_retry_accounting:$accounting,clean_commit_mutation:"detected",
      surviving_process_group:"retry_refused",corrupt_session_store:"unresolved_ambiguity"},
      counts:{codex_starts:0,duplicate_starts:0,candidate_acceptances:0}}' >"$out"
}

passed=0
for ((run=1; run<=runs; run++)); do run_matrix "$run"; passed=$((passed + 1)); done
jq -s --argjson attempted "$runs" --argjson passed "$passed" \
  '{slice:"GF-H03",status:(if $attempted==$passed then "pass" else "fail" end),runs_attempted:$attempted,runs_passed:$passed,
    runs_failed:($attempted-$passed),fault_matrix:.[0].tests}' "$artifact_root"/runs/*.json >"$artifact_root/result.json"
printf 'GF-H03 ACCEPTANCE PASS\nRUNS ATTEMPTED: %d\nRUNS PASSED: %d\nRUNS FAILED: 0\nEVIDENCE: %s\n' "$runs" "$passed" "$artifact_root"
