#!/usr/bin/env bash

# Shared Godot Web target discovery used by doctor and the export helper.

gf_web_godot_bin() {
  printf '%s\n' "${GODOT_BIN:-godot}"
}

gf_web_godot_version() {
  local godot_bin
  godot_bin=$(gf_web_godot_bin)
  command -v "$godot_bin" >/dev/null 2>&1 || return 1
  "$godot_bin" --version 2>/dev/null | head -n 1
}

gf_web_template_version() {
  local version=$1
  printf '%s\n' "${version%%.official*}"
}

gf_web_templates_dir() {
  local version=$1 template_version candidate
  if [[ -n ${GODOT_EXPORT_TEMPLATES_DIR:-} ]]; then
    printf '%s\n' "$GODOT_EXPORT_TEMPLATES_DIR"
    return
  fi
  template_version=$(gf_web_template_version "$version")
  for candidate in \
    "${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$template_version" \
    "$HOME/.local/share/godot/export_templates/$template_version"; do
    if [[ -f $candidate/version.txt ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$template_version"
}

gf_web_templates_ready() {
  local templates_dir=$1
  [[ -f $templates_dir/version.txt && -f $templates_dir/web_nothreads_release.zip ]]
}

gf_web_linux_templates_ready() {
  local templates_dir=$1
  [[ -f $templates_dir/version.txt && -f $templates_dir/linux_release.x86_64 ]]
}

gf_web_elapsed_seconds() {
  local start_ns=$1 end_ns=$2
  awk -v start="$start_ns" -v end="$end_ns" 'BEGIN { printf "%.6f", (end-start)/1000000000 }'
}
