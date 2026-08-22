#!/usr/bin/env bash

gf001_require_marker() {
  local file=$1 marker=$2
  [[ -f $file ]] && grep -Fq -- "$marker" "$file"
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

gf001_elapsed_seconds() {
  local start_ns=$1 end_ns=$2
  awk -v start="$start_ns" -v end="$end_ns" 'BEGIN { printf "%.3f", (end-start)/1000000000 }'
}

