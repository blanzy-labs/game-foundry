#!/usr/bin/env bash
set -u -o pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "${1:-}" in
  GF-REPAIR-001) file=marker-001.txt; required=REQUIRED_REPAIR_MARKER; accepted=GF_REPAIR_001_ACCEPTED ;;
  GF-REPAIR-002) file=marker-002.txt; required=REQUIRED_REPAIR_MARKER_002; accepted=GF_REPAIR_002_ACCEPTED ;;
  *) printf 'unknown task\n' >&2; exit 2 ;;
esac
[[ -f $project_root/src/$file ]] || exit 1
grep -Fq -- "$required" "$project_root/src/$file" || exit 1
printf '%s\n' "$accepted"
