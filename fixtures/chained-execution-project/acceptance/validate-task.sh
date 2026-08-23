#!/usr/bin/env bash
set -u -o pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "${1:-}" in
  GF-CHAIN-001) file=marker-001.txt; expected=GAME_FOUNDRY_CHAIN_MARKER_001; accepted=GF_CHAIN_001_ACCEPTED ;;
  GF-CHAIN-002) file=marker-002.txt; expected=GAME_FOUNDRY_CHAIN_MARKER_002; accepted=GF_CHAIN_002_ACCEPTED ;;
  GF-CHAIN-003) file=marker-003.txt; expected=GAME_FOUNDRY_CHAIN_MARKER_003; accepted=GF_CHAIN_003_ACCEPTED ;;
  *) printf 'unknown task\n' >&2; exit 2 ;;
esac
[[ -f $project_root/src/$file ]] || exit 1
[[ $(cat "$project_root/src/$file") == "$expected" ]] || exit 1
printf '%s\n' "$accepted"
