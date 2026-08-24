#!/usr/bin/env bash
set -u -o pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "${1:-}" in
  GF-RECOVERY-001) file=marker-001.txt; required=REQUIRED_RECOVERY_MARKER; accepted=GF_RECOVERY_001_ACCEPTED ;;
  GF-RECOVERY-002) file=marker-002.txt; required=REQUIRED_RECOVERY_MARKER_002; accepted=GF_RECOVERY_002_ACCEPTED ;;
  *) printf 'unknown task\n' >&2; exit 2 ;;
esac
[[ -f $project_root/src/$file ]] || exit 1
grep -Fxq -- "$required" "$project_root/src/$file" || exit 1
! grep -Eq 'FORBIDDEN_DESIGN_MARKER|SECOND_FORBIDDEN_MARKER' "$project_root/src/$file" || exit 1
printf '%s\n' "$accepted"
