#!/usr/bin/env bash
set -u -o pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "${1:-}" in
  GF-CRITIC-001) file=marker-001.txt; required=REQUIRED_CRITIC_MARKER; accepted=GF_CRITIC_001_ACCEPTED ;;
  GF-CRITIC-002) file=marker-002.txt; required=REQUIRED_CRITIC_MARKER_002; accepted=GF_CRITIC_002_ACCEPTED ;;
  *) printf 'unknown task\n' >&2; exit 2 ;;
esac
[[ -f $project_root/src/$file ]] || exit 1
grep -Fq -- "$required" "$project_root/src/$file" || exit 1
printf '%s\n' "$accepted"
