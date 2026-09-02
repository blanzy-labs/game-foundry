#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
profile=${GF_WEB_HOSTING_PROFILE_CONFIG:-$repo_root/config/hosting/cloudflare-pages.json}
hosting_profile=auto
slug=
route=
skip_compression=false
while (($#)); do
  case "$1" in
    --profile) profile=${2:?--profile requires a value}; shift 2 ;;
    --hosting-profile) hosting_profile=${2:?--hosting-profile requires a value}; shift 2 ;;
    --slug) slug=${2:?--slug requires a value}; shift 2 ;;
    --route) route=${2:?--route requires a value}; shift 2 ;;
    --skip-compression-analysis) skip_compression=true; shift ;;
    --) shift; break ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) break ;;
  esac
done
(($# == 3)) || { printf 'usage: %s --slug SLUG --route ROUTE [--hosting-profile PROFILE] WEB_MANIFEST BUNDLE OUTPUT\n' "$0" >&2; exit 2; }
[[ -n $slug && -n $route ]] || { printf '%s\n' '--slug and --route are required' >&2; exit 2; }
"$repo_root/scripts/gf-web-verify.sh" "$1" "$2" >/dev/null
python_args=(package "$1" "$2" "$3" --profile "$profile" --hosting-profile "$hosting_profile" --slug "$slug" --route "$route")
$skip_compression && python_args+=(--skip-compression-analysis)
python3 "$repo_root/scripts/lib/gf-web-hosting.py" "${python_args[@]}"
