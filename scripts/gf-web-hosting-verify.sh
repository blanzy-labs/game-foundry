#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
(($# == 1)) || { printf 'usage: %s HOSTING_RELEASE\n' "$0" >&2; exit 2; }
python3 "$repo_root/scripts/lib/gf-web-hosting.py" verify "$1" --profile "$repo_root/config/hosting/cloudflare-pages.json"
