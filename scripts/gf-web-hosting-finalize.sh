#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
site_origin=
asset_origin=
while (($#)); do
  case "$1" in
    --site-origin) site_origin=${2:?--site-origin requires a value}; shift 2 ;;
    --asset-origin) asset_origin=${2:?--asset-origin requires a value}; shift 2 ;;
    --) shift; break ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) break ;;
  esac
done
(($# == 2)) || { printf 'usage: %s --site-origin ORIGIN [--asset-origin ORIGIN] RELEASE OUTPUT\n' "$0" >&2; exit 2; }
[[ -n $site_origin ]] || { printf '%s\n' '--site-origin is required' >&2; exit 2; }
python3 "$repo_root/scripts/lib/gf-web-hosting.py" finalize "$1" "$2" --site-origin "$site_origin" --asset-origin "$asset_origin" --profile "$repo_root/config/hosting/cloudflare-pages.json"
