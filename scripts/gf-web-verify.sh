#!/usr/bin/env bash
set -u -o pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tool="$repo_root/scripts/lib/gf-web.py"
max_file=''
max_bundle=''

while (($#)); do
  case "$1" in
    --max-file-bytes) (($# >= 2)) || { printf '%s\n' '--max-file-bytes requires a value' >&2; exit 2; }; max_file=$2; shift 2 ;;
    --max-bundle-bytes) (($# >= 2)) || { printf '%s\n' '--max-bundle-bytes requires a value' >&2; exit 2; }; max_bundle=$2; shift 2 ;;
    --) shift; break ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) break ;;
  esac
done

(($# == 2)) || { printf 'usage: %s [--max-file-bytes N] [--max-bundle-bytes N] MANIFEST BUNDLE\n' "$0" >&2; exit 2; }
command=("$tool" verify "$1" "$2")
[[ -z $max_file ]] || command+=(--max-file-bytes "$max_file")
[[ -z $max_bundle ]] || command+=(--max-bundle-bytes "$max_bundle")
"${command[@]}"
