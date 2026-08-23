#!/usr/bin/env bash
set -u

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/scripts/lib/gf-001-common.sh"
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/game-foundry-gf002-helpers.XXXXXX")
scope_repo="$temp_root/scope"
failures=0

cleanup() { rm -rf -- "$temp_root"; }
trap cleanup EXIT

expect_pass() {
  local name=$1
  shift
  if "$@"; then printf '%-34s PASS\n' "$name"; else printf '%-34s FAIL\n' "$name"; ((failures += 1)); fi
}

expect_fail() {
  local name=$1
  shift
  if "$@"; then printf '%-34s FAIL (false acceptance)\n' "$name"; ((failures += 1)); else printf '%-34s PASS\n' "$name"; fi
}

printf 'GAME_FOUNDRY_RUNTIME_OK\nGAME_FOUNDRY_TOKEN=GF002_TEST\n' >"$temp_root/markers.log"
expect_pass 'valid marker set' gf001_gate_runtime "$temp_root/markers.log" 0 GF002_TEST
expect_fail 'missing marker' gf001_gate_runtime "$temp_root/markers.log" 0 GF002_MISSING

historical_png="$repo_root/artifacts/gf-001/gf001-20260822T201203Z-45de91/screenshot.png"
if [[ -f $historical_png ]]; then
  cp "$historical_png" "$temp_root/valid.png"
else
  timeout 60 xvfb-run -a -s '-screen 0 640x360x24' "${GODOT_BIN:-godot}" --display-driver x11 \
    --path "$repo_root/fixtures/godot-smoke" --resolution 640x360 -- --screenshot="$temp_root/valid.png" \
    >"$temp_root/godot-screenshot.log" 2>&1 || true
fi
expect_pass 'valid PNG' gf001_validate_png "$temp_root/valid.png" 640 360
expect_fail 'missing PNG' gf001_validate_png "$temp_root/missing.png" 640 360

git init -q "$scope_repo"
git -C "$scope_repo" config user.name 'GF-002 Test'
git -C "$scope_repo" config user.email 'gf002@example.invalid'
mkdir -p "$scope_repo/fixtures"
printf 'initial\n' >"$scope_repo/fixtures/allowed.txt"
printf 'initial\n' >"$scope_repo/README.md"
git -C "$scope_repo" add .
git -C "$scope_repo" commit -qm initial
printf 'allowed\n' >"$scope_repo/fixtures/allowed.txt"
expect_pass 'allowed diff only' gf001_verify_scope "$scope_repo" fixtures/allowed.txt
printf 'unexpected\n' >>"$scope_repo/README.md"
expect_fail 'unexpected file' gf001_verify_scope "$scope_repo" fixtures/allowed.txt

if ((failures > 0)); then
  printf '\nGF-002 SHARED GATES: FAIL (%s)\n' "$failures"
  exit 1
fi
printf '\nGF-002 SHARED GATES: PASS (6/6)\n'
