#!/usr/bin/env bash
set -u

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fault_gate="$repo_root/scripts/lib/gf-002-fault-gate.sh"
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/game-foundry-gf002-suite.XXXXXX")
report_dir="$temp_root/reports"
report_json="$report_dir/fault-injection.json"
report_md="$report_dir/fault-injection.md"
canonical_report_dir="$repo_root/reports/gf-002"
started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
failures=0

cleanup() { rm -rf -- "$temp_root"; }
trap cleanup EXIT
mkdir -p "$report_dir"

faults=(broken-gdscript wrong-token scope-violation missing-screenshot agent-success-engine-failure)
labels=(
  'A — Broken GDScript'
  'B — Wrong mutation token'
  'C — Unauthorized source change'
  'D — Missing screenshot'
  'E — Agent success / Godot failure'
)

for index in "${!faults[@]}"; do
  fault=${faults[$index]}
  evidence="$temp_root/$fault.json"
  GF001_TEST_MODE=1 GF001_TEST_FAULT="$fault" GF001_TEST_EVIDENCE_FILE="$evidence" "$fault_gate"
  pipeline_exit=$?
  if [[ $pipeline_exit -ne 0 && -s $evidence ]]; then
    status=pass
    printf '%-40s PASS (production gate exit %s)\n' "${labels[$index]}" "$pipeline_exit"
  else
    status=fail
    ((failures += 1))
    printf '%-40s FAIL (false acceptance or no evidence)\n' "${labels[$index]}"
  fi
  jq --arg status "$status" --argjson pipeline_exit "$pipeline_exit" \
    '. + {negative_test_status:$status,pipeline_exit_code:$pipeline_exit}' "$evidence" >"$temp_root/$fault.result.json" 2>/dev/null ||
    jq -n --arg fault "$fault" --arg status "$status" --argjson pipeline_exit "$pipeline_exit" \
      '{fault:$fault,negative_test_status:$status,pipeline_exit_code:$pipeline_exit,evidence_error:true}' >"$temp_root/$fault.result.json"
done

completed_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
overall=pass
((failures > 0)) && overall=fail
jq -s \
  --arg status "$overall" --arg started_at "$started_at" --arg completed_at "$completed_at" \
  '{slice:"GF-002",status:$status,started_at:$started_at,completed_at:$completed_at,semantics:"A negative-test PASS means the shared production gate returned non-zero for the injected fault.",faults:.}' \
  "$temp_root"/*.result.json >"$report_json"

{
  printf '# GF-002 fault-injection evidence\n\n'
  printf 'A negative-test **PASS** means the shared production acceptance gate returned a real non-zero process exit for the injected fault.\n\n'
  printf '| Test | Result | Gate exit | Command exit |\n|---|---:|---:|---:|\n'
  for index in "${!faults[@]}"; do
    fault=${faults[$index]}
    result="$temp_root/$fault.result.json"
    printf '| %s | %s | %s | %s |\n' "${labels[$index]}" \
      "$(jq -r '.negative_test_status | ascii_upcase' "$result")" \
      "$(jq -r '.pipeline_exit_code' "$result")" \
      "$(jq -r '.command_exit_code // "n/a"' "$result")"
  done
  printf '\nOverall: **%s**\n' "${overall^^}"
} >"$report_md"

if [[ ${GF002_UPDATE_REPORTS:-0} == 1 ]]; then
  mkdir -p "$canonical_report_dir"
  cp "$report_json" "$canonical_report_dir/fault-injection.json"
  cp "$report_md" "$canonical_report_dir/fault-injection.md"
fi

if ((failures > 0)); then
  printf '\nGF-002 FAILURE INJECTION: FAIL (%s false acceptances)\n' "$failures"
  exit 1
fi
printf '\nGF-002 FAILURE INJECTION: PASS (5/5 faults rejected)\n'
