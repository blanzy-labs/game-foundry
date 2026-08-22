#!/usr/bin/env bash
set -u

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
godot_bin=${GODOT_BIN:-godot}
marker=GAME_FOUNDRY_GODOT_SMOKE_OK

if ! command -v "$godot_bin" >/dev/null 2>&1; then
  printf 'FAIL: Godot is not available: %s\n' "$godot_bin" >&2
  exit 1
fi

valid_output=$("$godot_bin" --headless --path "$repo_root/fixtures/godot-smoke" --script smoke.gd 2>&1)
valid_code=$?
if [[ $valid_code -ne 0 || $valid_output != *"$marker"* ]]; then
  printf 'FAIL: valid fixture was not accepted\n%s\n' "$valid_output" >&2
  exit 1
fi
printf 'PASS: valid fixture executed and emitted %s\n' "$marker"

temp_root=$(mktemp -d "${TMPDIR:-/tmp}/game-foundry-self-test.XXXXXX")
trap 'rm -rf -- "$temp_root"' EXIT
cp "$repo_root/fixtures/godot-smoke/project.godot" "$temp_root/project.godot"
printf 'extends SceneTree\nfunc this_is_not_valid gdscript syntax\n' >"$temp_root/smoke.gd"

broken_output=$("$godot_bin" --headless --path "$temp_root" --script smoke.gd 2>&1)
broken_code=$?
if [[ $broken_code -eq 0 || $broken_output != *"Parse Error"* ]]; then
  printf 'FAIL: deliberately broken GDScript was not detected\n%s\n' "$broken_output" >&2
  exit 1
fi
printf 'PASS: deliberately broken temporary GDScript was rejected\n'
printf 'GAME_FOUNDRY_DOCTOR_SELF_TEST_OK\n'

