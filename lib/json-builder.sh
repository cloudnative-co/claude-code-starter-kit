#!/bin/bash
# lib/json-builder.sh - JSON construction and manipulation using jq
#
# Requires: jq, lib/colors.sh
# Uses globals: _SETUP_TMP_FILES[]
# Exports: validate_json(), replace_home_path(), build_settings_json()
# Dry-run: transparent (operates on whatever file paths are given)
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

  local tmp_file
  tmp_file="$(mktemp)" || return 1
  _register_tmp "$tmp_file" || return 1

  # jq --arg passes HOME as a literal string; replacement-side escaping would
  # corrupt Windows-style paths that contain backslashes.
  jq --arg home "$HOME" '
    walk(
      if type == "string" then gsub("__HOME__"; $home)
      else .
      end
    )
  ' "$file" > "$tmp_file" || return 1

  mv "$tmp_file" "$file" || return 1
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
  # Remaining positional args are hook fragment files (may be empty)

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
  merged="$(jq -s '.[0] * .[1]' "$base_file" "$permissions_file")" || return 1

  # Merge each hook fragment (iterating "$@" is safe even when empty on Bash 3.2)
  for fragment in "$@"; do
    if [[ ! -f "$fragment" ]]; then
      warn "Hook fragment not found, skipping: $fragment"
      continue
    fi
    if ! validate_json "$fragment"; then
      warn "Invalid JSON in hook fragment, skipping: $fragment"
      continue
    fi
    merged="$(printf '%s' "$merged" | jq --slurpfile frag "$fragment" '
      def merge_deep(a; b):
        reduce (b | to_entries[]) as $e (a;
          if (.[$e.key] | type) == "array" and ($e.value | type) == "array"
          then .[$e.key] = (.[$e.key] + $e.value)
          elif (.[$e.key] | type) == "object" and ($e.value | type) == "object"
          then .[$e.key] = merge_deep(.[$e.key]; $e.value)
          else .[$e.key] = $e.value
          end
        );
      merge_deep(.; $frag[0])')" || return 1
  done

  local tmp_file
  tmp_file="$(mktemp)" || return 1
  _register_tmp "$tmp_file" || return 1
  printf '%s\n' "$merged" > "$tmp_file" || return 1

  # Final validation
  if validate_json "$tmp_file"; then
    mv "$tmp_file" "$output_file" || return 1
    ok "Built settings JSON: $output_file"
  else
    error "Generated JSON is invalid: $output_file"
    return 1
  fi
}
