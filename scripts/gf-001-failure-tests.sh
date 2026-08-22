#!/usr/bin/env bash
set -u

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/scripts/lib/gf-001-common.sh"
godot_bin=${GODOT_BIN:-godot}
report_json="$repo_root/reports/gf-001/negative-test-evidence.json"
report_md="$repo_root/reports/gf-001/negative-test-evidence.md"
failures=0
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/game-foundry-gf001-negative.XXXXXX")
scope_worktree="$temp_root/scope-worktree"
started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

cleanup() {
  if git -C "$repo_root" worktree list --porcelain | grep -Fqx "worktree $scope_worktree"; then
    git -C "$repo_root" worktree remove --force "$scope_worktree" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$temp_root"
}
trap cleanup EXIT
mkdir -p "$(dirname "$report_json")"

report_expected_rejection() {
  local name=$1 detected=$2
  if [[ $detected == true ]]; then
    printf '%-36s PASS (fault rejected)\n' "$name"
  else
    printf '%-36s FAIL (false acceptance)\n' "$name"
    ((failures += 1))
  fi
}

# A: real Godot parse failure; the critical stage returns non-zero.
cp -a "$repo_root/fixtures/godot-smoke" "$temp_root/broken-gdscript"
printf 'extends SceneTree\nfunc definitely broken syntax\n' >"$temp_root/broken-gdscript/validate.gd"
timeout 30 "$godot_bin" --headless --path "$temp_root/broken-gdscript" --script validate.gd >"$temp_root/broken.txt" 2>&1
broken_godot_code=$?
if [[ $broken_godot_code -ne 0 ]] && grep -Fq 'Parse Error' "$temp_root/broken.txt"; then
  broken_pipeline_code=$broken_godot_code
  broken_detected=true
else
  broken_pipeline_code=0
  broken_detected=false
fi
broken_excerpt=$(tail -n 8 "$temp_root/broken.txt")
report_expected_rejection "A — Broken GDScript" "$broken_detected"

# B: the application exits zero and reports a wrong token; exact-token validation fails.
cp -a "$repo_root/fixtures/godot-smoke" "$temp_root/wrong-token"
sed -i 's/GF001_INITIAL/GF001_WRONG/' "$temp_root/wrong-token/automation_target.gd"
timeout 30 "$godot_bin" --headless --path "$temp_root/wrong-token" -- --runtime-test >"$temp_root/wrong-token.txt" 2>&1
wrong_application_code=$?
gf001_require_marker "$temp_root/wrong-token.txt" GAME_FOUNDRY_RUNTIME_OK
wrong_runtime_marker_code=$?
gf001_require_marker "$temp_root/wrong-token.txt" GAME_FOUNDRY_TOKEN=GF001_EXPECTED
wrong_token_validation_code=$?
if [[ $wrong_application_code -eq 0 && $wrong_runtime_marker_code -eq 0 && $wrong_token_validation_code -ne 0 ]]; then
  wrong_pipeline_code=1
  wrong_detected=true
else
  wrong_pipeline_code=0
  wrong_detected=false
fi
wrong_excerpt=$(tail -n 8 "$temp_root/wrong-token.txt")
report_expected_rejection "B — Wrong mutation token" "$wrong_detected"

# C: both the allowed target and an unauthorized harmless file change.
git -C "$repo_root" worktree add --detach "$scope_worktree" HEAD >/dev/null 2>&1
sed -i 's/GF001_INITIAL/GF001_SCOPE_TEST/' "$scope_worktree/fixtures/godot-smoke/automation_target.gd"
printf '\nGF-001 unauthorized scope test\n' >>"$scope_worktree/README.md"
mapfile -t scope_changed < <(git -C "$scope_worktree" status --porcelain=v1 | sed -E 's/^.. //' | sort)
gf001_verify_scope "$scope_worktree" fixtures/godot-smoke/automation_target.gd
scope_validation_code=$?
if [[ $scope_validation_code -ne 0 ]] && printf '%s\n' "${scope_changed[@]}" | grep -Fxq README.md && printf '%s\n' "${scope_changed[@]}" | grep -Fxq fixtures/godot-smoke/automation_target.gd; then
  scope_pipeline_code=1
  scope_detected=true
else
  scope_pipeline_code=0
  scope_detected=false
fi
scope_changed_json=$(printf '%s\n' "${scope_changed[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
report_expected_rejection "C — Unauthorized source change" "$scope_detected"
git -C "$repo_root" worktree remove --force "$scope_worktree" >/dev/null 2>&1

# D: a genuinely nonexistent PNG must fail the visual validator.
missing_path="$temp_root/nonexistent-screenshot.png"
gf001_validate_png "$missing_path" 640 360
missing_validation_code=$?
if [[ ! -e $missing_path && $missing_validation_code -ne 0 ]]; then
  missing_pipeline_code=1
  missing_detected=true
else
  missing_pipeline_code=0
  missing_detected=false
fi
report_expected_rejection "D — Missing screenshot" "$missing_detected"

completed_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
overall=pass
((failures > 0)) && overall=fail

jq -n \
  --arg status "$overall" --arg started_at "$started_at" --arg completed_at "$completed_at" \
  --argjson broken_godot_code "$broken_godot_code" --argjson broken_pipeline_code "$broken_pipeline_code" --arg broken_excerpt "$broken_excerpt" --argjson broken_detected "$broken_detected" \
  --argjson wrong_application_code "$wrong_application_code" --argjson wrong_pipeline_code "$wrong_pipeline_code" --arg wrong_excerpt "$wrong_excerpt" --argjson wrong_detected "$wrong_detected" \
  --argjson scope_pipeline_code "$scope_pipeline_code" --argjson scope_detected "$scope_detected" --argjson scope_changed "$scope_changed_json" \
  --argjson missing_pipeline_code "$missing_pipeline_code" --argjson missing_detected "$missing_detected" --arg missing_path "$missing_path" \
  '{slice:"GF-001",status:$status,started_at:$started_at,completed_at:$completed_at,semantics:"A negative-test PASS means the injected fault was correctly rejected.",negative_tests:{broken_gdscript:{status:(if $broken_detected then "pass" else "fail" end),expected_failure:"Godot parse/static validation failure",actual_failure:$broken_detected,godot_exit_code:$broken_godot_code,pipeline_exit_code:$broken_pipeline_code,relevant_log:$broken_excerpt},wrong_token:{status:(if $wrong_detected then "pass" else "fail" end),expected_token:"GF001_EXPECTED",actual_token:"GF001_WRONG",application_exit_code:$wrong_application_code,runtime_marker_present:true,pipeline_exit_code:$wrong_pipeline_code,relevant_log:$wrong_excerpt},unauthorized_change:{status:(if $scope_detected then "pass" else "fail" end),allowed_files:["fixtures/godot-smoke/automation_target.gd"],changed_files:$scope_changed,unexpected_files:["README.md"],scope_result:"fail",pipeline_exit_code:$scope_pipeline_code},missing_screenshot:{status:(if $missing_detected then "pass" else "fail" end),path:$missing_path,screenshot_exists:false,visual_stage:"fail",pipeline_exit_code:$missing_pipeline_code}}}' >"$report_json"

{
  printf '# GF-001 negative-test evidence\n\n'
  printf 'A negative-test **PASS** means the injected defect was correctly rejected.\n\n'
  printf '| Test | Detection | Critical pipeline exit | Key evidence |\n|---|---:|---:|---|\n'
  printf '| A — Broken GDScript | %s | %s | Godot exit %s; Parse Error present |\n' "${broken_detected^^}" "$broken_pipeline_code" "$broken_godot_code"
  printf '| B — Wrong token | %s | %s | Application exit %s; actual GF001_WRONG; expected GF001_EXPECTED |\n' "${wrong_detected^^}" "$wrong_pipeline_code" "$wrong_application_code"
  printf '| C — Unauthorized change | %s | %s | Allowed target plus unexpected README.md detected |\n' "${scope_detected^^}" "$scope_pipeline_code"
  printf '| D — Missing screenshot | %s | %s | Nonexistent PNG rejected |\n\n' "${missing_detected^^}" "$missing_pipeline_code"
  printf 'Overall negative-test evidence: **%s**\n' "${overall^^}"
} >"$report_md"

if ((failures > 0)); then
  printf '\nGF-001 FAILURE INJECTION: FAIL (%s false acceptances)\n' "$failures"
  exit 1
fi
printf '\nGF-001 FAILURE INJECTION: PASS (4/4 faults rejected)\n'
