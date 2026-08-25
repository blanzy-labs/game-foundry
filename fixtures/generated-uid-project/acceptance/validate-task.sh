#!/usr/bin/env bash
set -u -o pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo_root=$(git -C "$project_root" rev-parse --show-toplevel)
candidate="$project_root/src/example.gd"

[[ -f $candidate ]] || exit 1
grep -Fxq 'extends RefCounted # GF_H02_CANDIDATE' "$candidate" || exit 1

case "${GF_H02_FIXTURE_MODE:-clean}" in
  clean) ;;
  expected_uid)
    printf 'uid://gfh02expected123\n' >"$candidate.uid"
    ;;
  malformed_uid)
    printf 'not-a-godot-uid\n' >"$candidate.uid"
    ;;
  unexpected_untracked)
    printf 'unexpected\n' >"$repo_root/unexpected.txt"
    ;;
  unexpected_source)
    printf '\nGF-H02 unexpected validator mutation\n' >>"$repo_root/README.md"
    ;;
  *) exit 2 ;;
esac

printf 'GF_H02_FIXTURE_ACCEPTED\n'
