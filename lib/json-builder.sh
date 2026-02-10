#!/bin/bash
# lib/json-builder.sh - JSON construction and manipulation using jq
# Requires: jq, lib/colors.sh to be sourced first
set -euo pipefail

# ---------------------------------------------------------------------------
# validate_json - Verify that a file contains valid JSON
#
# Usage: validate_json <file>
# Returns 0 on valid JSON, 1 otherwise.
# ---------------------------------------------------------------------------
validate_json() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    error "File not found: $file"
    return 1
  fi

  if jq empty "$file" 2>/dev/null; then
    return 0
  else
    error "Invalid JSON: $file"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# replace_home_path - Replace __HOME__ placeholder with actual $HOME in JSON
#
# Usage: replace_home_path <file>
#
# Edits the file in place. The __HOME__ token is replaced in all string
# values throughout the JSON structure.
# ---------------------------------------------------------------------------
replace_home_path() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    error "File not found: $file"
    return 1
  fi

  local home_escaped
  # Escape HOME for use in jq string (handle slashes)
  home_escaped="$(printf '%s' "$HOME" | sed 's/\\/\\\\/g')"

  local tmp_file
  tmp_file="$(mktemp)"

  jq --arg home "$home_escaped" '
    walk(
      if type == "string" then gsub("__HOME__"; $home)
      else .
      end
    )
  ' "$file" > "$tmp_file"

  mv "$tmp_file" "$file"
}

# ---------------------------------------------------------------------------
# build_settings_json - Merge base settings, permissions, and hook fragments
#
# Usage: build_settings_json <base_file> <permissions_file> <output_file> [hook_fragments...]
#
# Merges:
#   1. settings-base.json   (foundation)
#   2. permissions.json      (deep-merged on top)
#   3. Each hook fragment    (merged into the appropriate hooks section)
#
# The result is written to <output_file>.
# ---------------------------------------------------------------------------
build_settings_json() {
  local base_file="$1"
  local permissions_file="$2"
  local output_file="$3"
  shift 3
  local hook_fragments=("$@")

  # Validate inputs
  if [[ ! -f "$base_file" ]]; then
    error "Base settings file not found: $base_file"
    return 1
  fi
  if [[ ! -f "$permissions_file" ]]; then
    error "Permissions file not found: $permissions_file"
    return 1
  fi
  validate_json "$base_file" || return 1
  validate_json "$permissions_file" || return 1

  # Start with base merged with permissions (deep merge via * operator)
  local merged
  merged="$(jq -s '.[0] * .[1]' "$base_file" "$permissions_file")"

  # Merge each hook fragment
  for fragment in "${hook_fragments[@]}"; do
    if [[ ! -f "$fragment" ]]; then
      warn "Hook fragment not found, skipping: $fragment"
      continue
    fi
    if ! validate_json "$fragment"; then
      warn "Invalid JSON in hook fragment, skipping: $fragment"
      continue
    fi
    merged="$(echo "$merged" | jq --slurpfile frag "$fragment" '. * $frag[0]')"
  done

  printf '%s\n' "$merged" > "$output_file"

  # Final validation
  if validate_json "$output_file"; then
    ok "Built settings JSON: $output_file"
  else
    error "Generated JSON is invalid: $output_file"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# filter_plugins - Filter a plugins JSON array to only selected plugins
#
# Usage: filter_plugins <plugins_file> <output_file> <plugin_name> [plugin_name...]
#
# Expects <plugins_file> to contain a JSON array of objects, each with a
# "name" field. Only objects whose "name" matches one of the given names
# are kept.
# ---------------------------------------------------------------------------
filter_plugins() {
  local plugins_file="$1"
  local output_file="$2"
  shift 2
  local selected_names=("$@")

  if [[ ! -f "$plugins_file" ]]; then
    error "Plugins file not found: $plugins_file"
    return 1
  fi
  validate_json "$plugins_file" || return 1

  if [[ ${#selected_names[@]} -eq 0 ]]; then
    warn "No plugin names specified; output will be an empty array"
    echo '[]' > "$output_file"
    return 0
  fi

  # Build a jq filter array from the selected names
  local jq_array
  jq_array="$(printf '%s\n' "${selected_names[@]}" | jq -R . | jq -s .)"

  jq --argjson names "$jq_array" '
    [.[] | select(.name as $n | $names | index($n))]
  ' "$plugins_file" > "$output_file"

  if validate_json "$output_file"; then
    ok "Filtered plugins written to: $output_file"
  else
    error "Filtered plugins JSON is invalid: $output_file"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# merge_json_files - Generic deep merge of multiple JSON files
#
# Usage: merge_json_files <output_file> <file1> <file2> [file3...]
#
# Files are merged left-to-right; later files override earlier ones.
# ---------------------------------------------------------------------------
merge_json_files() {
  local output_file="$1"
  shift
  local files=("$@")

  if [[ ${#files[@]} -lt 1 ]]; then
    error "At least one input file is required"
    return 1
  fi

  local merged
  merged="$(< "${files[0]}")"

  for ((i = 1; i < ${#files[@]}; i++)); do
    local next_file="${files[$i]}"
    if [[ ! -f "$next_file" ]]; then
      warn "File not found, skipping: $next_file"
      continue
    fi
    merged="$(echo "$merged" | jq --slurpfile next "$next_file" '. * $next[0]')"
  done

  printf '%s\n' "$merged" > "$output_file"
  validate_json "$output_file"
}
