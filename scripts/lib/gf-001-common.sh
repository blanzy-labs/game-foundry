#!/usr/bin/env bash

gf001_require_marker() {
  local file=$1 marker=$2
  [[ -f $file ]] && grep -Fq -- "$marker" "$file"
}

gf001_require_line() {
  local file=$1 line=$2
  [[ -f $file ]] && grep -Fxq -- "$line" "$file"
}

gf001_gate_source_token() {
  local file=$1 expected_token=$2
  gf001_require_line "$file" "const AUTOMATION_TOKEN := \"$expected_token\"" &&
    ! gf001_require_marker "$file" 'GF001_INITIAL'
}

gf001_verify_scope() {
  local workspace=$1 allowed=$2
  local changed found_allowed=false
  mapfile -t changed < <(git -C "$workspace" status --porcelain=v1 | sed -E 's/^.. //' | sed -E 's/.* -> //')
  ((${#changed[@]} > 0)) || return 1
  for file in "${changed[@]}"; do
    if [[ $file == "$allowed" ]]; then
      found_allowed=true
    else
      return 1
    fi
  done
  $found_allowed
}

gf001_validate_png() {
  local image_path=$1 expected_width=$2 expected_height=$3
  [[ -s $image_path ]] || return 1
  local description
  description=$(file -b "$image_path" 2>/dev/null) || return 1
  [[ $description == PNG\ image\ data,* ]] || return 1
  [[ $description == *"${expected_width} x ${expected_height}"* ]]
}

gf001_gate_static() {
  local log=$1 command_exit=$2 expected_token=$3
  [[ $command_exit -eq 0 ]] &&
    gf001_require_marker "$log" GAME_FOUNDRY_STATIC_OK &&
    gf001_require_line "$log" "GAME_FOUNDRY_TOKEN=$expected_token"
}

gf001_gate_runtime() {
  local log=$1 command_exit=$2 expected_token=$3
  [[ $command_exit -eq 0 ]] &&
    gf001_require_marker "$log" GAME_FOUNDRY_RUNTIME_OK &&
    gf001_require_line "$log" "GAME_FOUNDRY_TOKEN=$expected_token"
}

gf001_gate_screenshot() {
  local log=$1 command_exit=$2 image_path=$3 expected_token=$4
  [[ $command_exit -eq 0 ]] &&
    gf001_require_line "$log" "GAME_FOUNDRY_TOKEN=$expected_token" &&
    gf001_validate_png "$image_path" 640 360
}

gf001_gate_export() {
  local binary=$1 command_exit=$2
  [[ $command_exit -eq 0 ]] &&
    [[ -x $binary ]] &&
    file -b "$binary" 2>/dev/null | grep -Fq 'ELF 64-bit'
}

gf001_gate_export_runtime() {
  local log=$1 command_exit=$2 expected_token=$3
  [[ $command_exit -eq 0 ]] &&
    gf001_require_marker "$log" GAME_FOUNDRY_EXPORT_RUNTIME_OK &&
    gf001_require_line "$log" "GAME_FOUNDRY_TOKEN=$expected_token"
}

gf001_elapsed_seconds() {
  local start_ns=$1 end_ns=$2
  awk -v start="$start_ns" -v end="$end_ns" 'BEGIN { printf "%.3f", (end-start)/1000000000 }'
}
