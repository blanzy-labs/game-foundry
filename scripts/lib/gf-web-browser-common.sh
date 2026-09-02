#!/usr/bin/env bash

gf_web_browser_repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

gf_web_playwright_version() {
  local root
  root=$(gf_web_browser_repo_root)
  node -p "require('$root/node_modules/playwright/package.json').version" 2>/dev/null
}

gf_web_chromium_path() {
  local root
  root=$(gf_web_browser_repo_root)
  node -e "const {chromium}=require('$root/node_modules/playwright'); process.stdout.write(chromium.executablePath())" 2>/dev/null
}

gf_web_chromium_version() {
  local executable=$1
  "$executable" --version 2>/dev/null | head -n 1
}

gf_web_browser_ready() {
  local root playwright chromium
  root=$(gf_web_browser_repo_root)
  [[ -f $root/package-lock.json && -d $root/node_modules/playwright ]] || return 1
  playwright=$(gf_web_playwright_version) || return 1
  [[ $playwright == 1.62.1 ]] || return 1
  chromium=$(gf_web_chromium_path) || return 1
  [[ -x $chromium ]] || return 1
}
