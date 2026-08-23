#!/usr/bin/env bash
set -u -o pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "${1:-}" in
  GF-EXEC-001)
    [[ -f $project_root/src/marker.txt ]] || exit 1
    [[ $(cat "$project_root/src/marker.txt") == GAME_FOUNDRY_EXECUTION_MARKER_001 ]] || exit 1
    printf 'GF_EXEC_001_ACCEPTED\n'
    ;;
  GF-EXEC-002)
    [[ -f $project_root/src/marker-002.txt ]] || exit 1
    [[ $(cat "$project_root/src/marker-002.txt") == GAME_FOUNDRY_EXECUTION_MARKER_002 ]] || exit 1
    printf 'GF_EXEC_002_ACCEPTED\n'
    ;;
  *)
    printf 'unknown task\n' >&2
    exit 2
    ;;
esac
