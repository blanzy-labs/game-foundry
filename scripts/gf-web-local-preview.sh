#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
(($# == 1)) || { printf 'usage: %s HOSTING_RELEASE\n' "$0" >&2; exit 2; }
exec node "$repo_root/scripts/web/hosting-server.mjs" "$1"
