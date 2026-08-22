#!/usr/bin/env bash
set -u

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/scripts/lib/gf-001-common.sh"
godot_bin=${GODOT_BIN:-godot}
failures=0
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/game-foundry-gf001-negative.XXXXXX")
trap 'rm -rf -- "$temp_root"' EXIT

report_expected_rejection() {
  local name=$1 result=$2
  if [[ $result -eq 0 ]]; then
    printf '%-36s PASS (failure detected)\n' "$name"
  else
    printf '%-36s FAIL (false success)\n' "$name"
    ((failures += 1))
  fi
}

cp -a "$repo_root/fixtures/godot-smoke" "$temp_root/broken-gdscript"
printf 'extends SceneTree\nfunc definitely broken syntax\n' >"$temp_root/broken-gdscript/validate.gd"
timeout 30 "$godot_bin" --headless --path "$temp_root/broken-gdscript" --script validate.gd >"$temp_root/broken.log" 2>&1
broken_code=$?
[[ $broken_code -ne 0 ]] && grep -Fq 'Parse Error' "$temp_root/broken.log"
report_expected_rejection "Broken GDScript" $?

printf 'GAME_FOUNDRY_RUNTIME_OK\nGAME_FOUNDRY_TOKEN=GF001_WRONG\n' >"$temp_root/wrong-token.log"
gf001_require_marker "$temp_root/wrong-token.log" 'GAME_FOUNDRY_TOKEN=GF001_EXPECTED'
wrong_token_code=$?
[[ $wrong_token_code -ne 0 ]]
report_expected_rejection "Wrong mutation token" $?

git -C "$repo_root" worktree add --detach "$temp_root/scope-worktree" HEAD >/dev/null 2>&1
printf '\nunauthorized\n' >>"$temp_root/scope-worktree/README.md"
gf001_verify_scope "$temp_root/scope-worktree" 'fixtures/godot-smoke/automation_target.gd'
scope_code=$?
[[ $scope_code -ne 0 ]]
report_expected_rejection "Unauthorized file change" $?
git -C "$repo_root" worktree remove --force "$temp_root/scope-worktree" >/dev/null 2>&1

gf001_validate_png "$temp_root/does-not-exist.png" 640 360
screenshot_code=$?
[[ $screenshot_code -ne 0 ]]
report_expected_rejection "Missing screenshot" $?

if ((failures > 0)); then
  printf '\nGF-001 FAILURE INJECTION: FAIL (%s false successes)\n' "$failures"
  exit 1
fi
printf '\nGF-001 FAILURE INJECTION: PASS (4/4 failures detected)\n'
