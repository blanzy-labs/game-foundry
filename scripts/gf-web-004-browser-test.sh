#!/usr/bin/env bash
set -u -o pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/scripts/lib/gf-web-browser-common.sh"

(($# == 2)) || { printf 'usage: %s HOSTING_RELEASE ARTIFACT_DIR\n' "$0" >&2; exit 2; }
release=$(realpath "$1" 2>/dev/null) || { printf 'hosting release is missing\n' >&2; exit 2; }
artifact=$(realpath -m "$2")
mkdir -p "$artifact"

source_fingerprint() {
  local relative
  while IFS= read -r -d '' relative; do
    printf '%s\0' "$relative"
    if [[ -L $repo_root/$relative ]]; then
      printf 'symlink:%s\0' "$(readlink "$repo_root/$relative")"
    elif [[ -f $repo_root/$relative ]]; then
      sha256sum "$repo_root/$relative"
    else
      printf 'missing\0'
    fi
  done < <(git -C "$repo_root" ls-files --cached --others --exclude-standard -z)
}

if ! gf_web_browser_ready; then
  jq -n '{status:"fail",failure_reason:"PLAYWRIGHT_OR_CHROMIUM_MISSING"}' >"$artifact/browser-result.json"
  printf 'browser prerequisite missing; run npm ci and npx playwright install chromium\n' >&2
  exit 1
fi

"$repo_root/scripts/gf-web-hosting-verify.sh" "$release" >"$artifact/hosting-verification.json" || exit 1
before=$(source_fingerprint | sha256sum | cut -d' ' -f1)
node "$repo_root/scripts/web/cyber-shield-acceptance.mjs" --hosting-release "$release" --artifact "$artifact" >"$artifact/playwright.log" 2>"$artifact/playwright.stderr"
code=$?
after=$(source_fingerprint | sha256sum | cut -d' ' -f1)
jq -n --arg before "$before" --arg after "$after" '{before:$before,after:$after,unchanged:($before==$after)}' >"$artifact/source-state.json"
if [[ $before != "$after" ]]; then
  jq '.status="fail" | .failure_reason="browser acceptance mutated source"' "$artifact/browser-result.json" >"$artifact/browser-result.tmp" && mv "$artifact/browser-result.tmp" "$artifact/browser-result.json"
  exit 1
fi
exit "$code"
