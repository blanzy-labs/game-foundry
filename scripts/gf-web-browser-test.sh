#!/usr/bin/env bash
set -u -o pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/scripts/lib/gf-web-browser-common.sh"
fault=none
skip_integrity=false
startup_timeout=15000
input_timeout=5000
hosting_release=

while (($#)); do
  case "$1" in
    --fault) (($# >= 2)) || { printf '%s\n' '--fault requires a value' >&2; exit 2; }; fault=$2; shift 2 ;;
    --skip-integrity) skip_integrity=true; shift ;;
    --startup-timeout-ms) startup_timeout=$2; shift 2 ;;
    --input-timeout-ms) input_timeout=$2; shift 2 ;;
    --hosting-release) hosting_release=${2:?--hosting-release requires a value}; shift 2 ;;
    --) shift; break ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) break ;;
  esac
done
if [[ -n $hosting_release ]]; then
  (($# == 1)) || { printf 'usage: %s --hosting-release RELEASE [--fault NAME] ARTIFACT_DIR\n' "$0" >&2; exit 2; }
  hosting_release=$(realpath "$hosting_release" 2>/dev/null) || { printf 'hosting release is missing\n' >&2; exit 2; }
  artifact=$(realpath -m "$1")
  manifest=
  bundle=
else
  (($# == 3)) || { printf 'usage: %s [--fault NAME] [--skip-integrity] MANIFEST BUNDLE ARTIFACT_DIR\n' "$0" >&2; exit 2; }
  manifest=$(realpath "$1" 2>/dev/null) || { printf 'manifest is missing\n' >&2; exit 2; }
  bundle=$(realpath "$2" 2>/dev/null) || { printf 'bundle is missing\n' >&2; exit 2; }
  artifact=$(realpath -m "$3")
fi
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
if [[ -n $hosting_release ]]; then
  "$repo_root/scripts/gf-web-hosting-verify.sh" "$hosting_release" >"$artifact/hosting-verification.json" || exit 1
elif $skip_integrity; then
  [[ ${GF_GF_WEB002_ENABLE_TEST_HOOKS:-0} == 1 && $fault != none ]] || { printf 'integrity bypass is restricted to controlled GF-WEB-002 fault cases\n' >&2; exit 2; }
else
  "$repo_root/scripts/gf-web-verify.sh" "$manifest" "$bundle" >"$artifact/gf-web-001-verification.json" || exit 1
fi

before=$(source_fingerprint | sha256sum | cut -d' ' -f1)
node_args=(--artifact "$artifact" --fault "$fault" --startup-timeout-ms "$startup_timeout" --input-timeout-ms "$input_timeout")
if [[ -n $hosting_release ]]; then node_args+=(--hosting-release "$hosting_release"); else node_args+=(--manifest "$manifest" --bundle "$bundle"); fi
node "$repo_root/scripts/web/browser-acceptance.mjs" "${node_args[@]}" >"$artifact/playwright.log" 2>"$artifact/playwright.stderr"
code=$?
after=$(source_fingerprint | sha256sum | cut -d' ' -f1)
jq -n --arg before "$before" --arg after "$after" '{before:$before,after:$after,unchanged:($before==$after)}' >"$artifact/source-state.json"
if [[ $before != "$after" ]]; then
  jq '.status="fail" | .failure_reason="browser acceptance mutated source"' "$artifact/browser-result.json" >"$artifact/browser-result.tmp" && mv "$artifact/browser-result.tmp" "$artifact/browser-result.json"
  exit 1
fi
exit "$code"
