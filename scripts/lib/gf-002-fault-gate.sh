#!/usr/bin/env bash
set -u

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$repo_root/scripts/lib/gf-001-common.sh"

if [[ ${GF001_TEST_MODE:-0} != 1 ]]; then
  printf 'GF001_TEST_MODE=1 is required; fault injection is disabled by default.\n' >&2
  exit 2
fi

fault=${GF001_TEST_FAULT:-}
evidence_file=${GF001_TEST_EVIDENCE_FILE:-}
godot_bin=${GODOT_BIN:-godot}
allowed_file=fixtures/godot-smoke/automation_target.gd
expected_token=GF001_EXPECTED
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/game-foundry-gf002-fault.XXXXXX")
scope_worktree="$temp_root/scope-worktree"

cleanup() {
  if git -C "$repo_root" worktree list --porcelain | grep -Fqx "worktree $scope_worktree"; then
    git -C "$repo_root" worktree remove --force "$scope_worktree" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$temp_root"
}
trap cleanup EXIT

[[ -n $evidence_file ]] || { printf 'GF001_TEST_EVIDENCE_FILE is required.\n' >&2; exit 2; }
mkdir -p "$(dirname "$evidence_file")"

command_exit=-1
gate_exit=-1
source_gate_exit=-1
agent_status=not_applicable
changed_files_json='[]'
log_excerpt=''

case "$fault" in
  broken-gdscript)
    cp -a "$repo_root/fixtures/godot-smoke" "$temp_root/fixture"
    printf 'extends SceneTree\nfunc definitely broken syntax\n' >"$temp_root/fixture/validate.gd"
    timeout 30 "$godot_bin" --headless --path "$temp_root/fixture" --script validate.gd -- --expected-token=GF001_INITIAL >"$temp_root/gate.log" 2>&1
    command_exit=$?
    gf001_gate_static "$temp_root/gate.log" "$command_exit" GF001_INITIAL
    gate_exit=$?
    ;;
  wrong-token)
    cp -a "$repo_root/fixtures/godot-smoke" "$temp_root/fixture"
    sed -i 's/GF001_INITIAL/GF001_WRONG/' "$temp_root/fixture/automation_target.gd"
    timeout 30 "$godot_bin" --headless --path "$temp_root/fixture" -- --runtime-test >"$temp_root/gate.log" 2>&1
    command_exit=$?
    gf001_gate_runtime "$temp_root/gate.log" "$command_exit" "$expected_token"
    gate_exit=$?
    ;;
  scope-violation)
    git -C "$repo_root" worktree add --detach "$scope_worktree" HEAD >/dev/null 2>&1 || exit 2
    sed -i 's/GF001_INITIAL/GF001_SCOPE_TEST/' "$scope_worktree/$allowed_file"
    printf '\nGF-002 unauthorized scope test\n' >>"$scope_worktree/README.md"
    mapfile -t changed_files < <(git -C "$scope_worktree" status --porcelain=v1 | sed -E 's/^.. //' | sort)
    changed_files_json=$(printf '%s\n' "${changed_files[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
    command_exit=0
    gf001_verify_scope "$scope_worktree" "$allowed_file"
    gate_exit=$?
    printf '%s\n' "${changed_files[@]}" >"$temp_root/gate.log"
    ;;
  missing-screenshot)
    printf 'GAME_FOUNDRY_TOKEN=%s\n' "$expected_token" >"$temp_root/gate.log"
    command_exit=0
    gf001_gate_screenshot "$temp_root/gate.log" "$command_exit" "$temp_root/missing.png" "$expected_token"
    gate_exit=$?
    ;;
  agent-success-engine-failure)
    cp -a "$repo_root/fixtures/godot-smoke" "$temp_root/fixture"
    printf '{"status":"success","reported_by":"mock-agent","changed_file":"%s"}\n' "$allowed_file" >"$temp_root/agent-result.json"
    agent_status=success
    sed -i "s/GF001_INITIAL/$expected_token/" "$temp_root/fixture/automation_target.gd"
    gf001_gate_source_token "$temp_root/fixture/automation_target.gd" "$expected_token"
    source_gate_exit=$?
    printf 'extends SceneTree\nfunc definitely broken syntax\n' >"$temp_root/fixture/validate.gd"
    timeout 30 "$godot_bin" --headless --path "$temp_root/fixture" --script validate.gd -- --expected-token="$expected_token" >"$temp_root/gate.log" 2>&1
    command_exit=$?
    gf001_gate_static "$temp_root/gate.log" "$command_exit" "$expected_token"
    gate_exit=$?
    ;;
  *)
    printf 'Unknown GF001_TEST_FAULT: %s\n' "$fault" >&2
    exit 2
    ;;
esac

log_excerpt=$(tail -n 10 "$temp_root/gate.log" 2>/dev/null || true)
jq -n \
  --arg fault "$fault" --arg agent_status "$agent_status" --arg log_excerpt "$log_excerpt" \
  --argjson command_exit "$command_exit" --argjson gate_exit "$gate_exit" \
  --argjson source_gate_exit "$source_gate_exit" --argjson changed_files "$changed_files_json" \
  '{fault:$fault,test_mode:true,agent_status:$agent_status,command_exit_code:$command_exit,source_gate_exit_code:$source_gate_exit,production_gate_exit_code:$gate_exit,changed_files:$changed_files,log_excerpt:$log_excerpt}' \
  >"$evidence_file"

exit "$gate_exit"
