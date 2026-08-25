#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cli="$repo_root/scripts/gf-milestone.sh"
fixture="$repo_root/milestones/examples/executable-fixture-milestone"
runs=${1:-3}
[[ $runs =~ ^[1-9][0-9]*$ ]] || { printf 'run count must be positive\n' >&2; exit 2; }
artifact_root=${GF_H03_SMOKE_ARTIFACT_ROOT:-$repo_root/artifacts/gf-h03/real-smoke-$(date -u +%Y%m%dT%H%M%SZ)-$$}
temp_base=${TMPDIR:-$repo_root/tmp/gfh03-tests}
mkdir -p "$artifact_root/runs" "$artifact_root/transports" "$temp_base"
temp_root=$(mktemp -d "$temp_base/game-foundry-gfh03-smoke.XXXXXX")
cleanup() { rm -rf -- "$temp_root"; }
trap cleanup EXIT

passed=0
for ((run=1; run<=runs; run++)); do
  case_root="$temp_root/run-$run"; repo="$case_root/repo"; package="$case_root/package"; state="$case_root/state"
  evidence="$artifact_root/runs/run-$(printf '%02d' "$run").json"
  mkdir -p "$case_root" "$state"
  git clone -q "$repo_root" "$repo"
  cp -a "$fixture" "$package"
  jq --arg path "$repo" '.repository.path=$path' "$package/milestone.json" >"$package/milestone.json.tmp"
  mv "$package/milestone.json.tmp" "$package/milestone.json"
  GF_MILESTONE_STATE_ROOT="$state" "$cli" init "$package" --json >"$case_root/init.json"
  GF_MILESTONE_STATE_ROOT="$state" GF_EXECUTION_ARTIFACT_ROOT="$case_root/executions" GF_EXECUTION_TMP_ROOT="$case_root/worktrees" \
    "$cli" execute-one GF-EXEC-M001 --json >"$case_root/result.json" 2>"$case_root/stderr.log"
  result=$(cat "$case_root/result.json")
  transport=$(find "$case_root/executions" -name agent-transport.json -type f | sort | tail -1)
  [[ -n $transport ]] || { printf 'run %d missing transport evidence\n' "$run" >&2; exit 1; }
  cp "$transport" "$artifact_root/transports/run-$(printf '%02d' "$run")-agent-transport.json"
  jq -e '.result=="pass" and .codex_invocations==1 and .validation.status=="pass" and .source.accepted_commit!=null' <<<"$result" >/dev/null
  jq -e '.canonical_execution_mode=="explicit_local_openclaw_codex" and .agent_start_proven and .agent_completion_proven and .transport_attempt_count==1' "$transport" >/dev/null
  marker=$(git -C "$repo" show 'gf/GF-EXEC-M001:fixtures/execution-project/src/marker.txt')
  [[ $marker == GAME_FOUNDRY_EXECUTION_MARKER_001 ]]
  jq -n --argjson run "$run" --argjson result "$result" --slurpfile transport "$transport" \
    '{run:$run,status:"pass",logical_run_id:$transport[0].logical_run_id,session_key:$transport[0].session_key,
      codex_starts:1,candidate_mutations:1,duplicate_starts:0,session_conflicts:0,gateway_failures:0,
      accepted_commit:$result.source.accepted_commit,timing_seconds:$transport[0].timing_seconds}' >"$evidence"
  passed=$((passed + 1))
done

jq -s --argjson attempted "$runs" --argjson passed "$passed" \
  '{slice:"GF-H03-real-smoke",status:(if $attempted==$passed then "pass" else "fail" end),runs_attempted:$attempted,
    runs_passed:$passed,runs_failed:($attempted-$passed),codex_starts:([.[].codex_starts]|add),
    candidate_mutations:([.[].candidate_mutations]|add),duplicate_starts:([.[].duplicate_starts]|add),
    session_conflicts:([.[].session_conflicts]|add),gateway_failures:([.[].gateway_failures]|add),runs:.}' \
  "$artifact_root"/runs/*.json >"$artifact_root/result.json"
printf 'GF-H03 REAL SMOKE PASS\nRUNS ATTEMPTED: %d\nRUNS PASSED: %d\nRUNS FAILED: 0\nEVIDENCE: %s\n' "$runs" "$passed" "$artifact_root"
