#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
port=${GF_DASHBOARD_PORT:-8787}

command -v python3 >/dev/null 2>&1 || {
  printf 'GAME FOUNDRY DASHBOARD ERROR: python3 is required\n' >&2
  exit 1
}

required_files=(
  "$repo_root/config/projects.json"
  "$repo_root/dashboard/server.py"
  "$repo_root/dashboard/static/index.html"
  "$repo_root/dashboard/static/app.js"
  "$repo_root/dashboard/static/styles.css"
)

for required_file in "${required_files[@]}"; do
  [[ -f $required_file ]] || {
    printf 'GAME FOUNDRY DASHBOARD ERROR: missing %s\n' "$required_file" >&2
    exit 1
  }
done

exec python3 "$repo_root/dashboard/server.py" --port "$port"
