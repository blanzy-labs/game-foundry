#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
profile=${GF_WEB_HOSTING_PROFILE_CONFIG:-$repo_root/config/hosting/cloudflare-pages.json}
(($# >= 1 && $# <= 2)) || { printf 'usage: %s WEB_RELEASE_MANIFEST [HOSTING_PROFILE_JSON]\n' "$0" >&2; exit 2; }
[[ $# -lt 2 ]] || profile=$2
python3 "$repo_root/scripts/lib/gf-web-hosting.py" classify "$1" "$profile"
