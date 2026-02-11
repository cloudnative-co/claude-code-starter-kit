#!/bin/bash
# lib/template.sh - Text template engine for CLAUDE.md and similar plain-text files
# NOT for JSON files - use lib/json-builder.sh for JSON.
# Requires: lib/colors.sh to be sourced first
set -euo pipefail

# ---------------------------------------------------------------------------
# process_template - Replace {{VAR}} placeholders with values from a config file
#
# Usage: process_template <template_file> <config_file> [output_file]
#
# Config file format (one per line):
#   VAR_NAME=value
#   ANOTHER_VAR=some other value
#
# If output_file is omitted, writes to stdout.
# ---------------------------------------------------------------------------
process_template() {
  local template_file="$1"
  local config_file="$2"
  local output_file="${3:-}"

  if [[ ! -f "$template_file" ]]; then
    error "Template file not found: $template_file"
    return 1
  fi
  if [[ ! -f "$config_file" ]]; then
    error "Config file not found: $config_file"
    return 1
  fi

  local content
  content="$(< "$template_file")"

  # Read each KEY=VALUE line from config, skipping comments and blank lines
  while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue

    # Trim whitespace from key
    key="$(echo "$key" | xargs)"
    # Value keeps everything after the first '='
    value="${value:-}"

    # Replace all occurrences of {{KEY}} in content
    content="${content//\{\{${key}\}\}/${value}}"
  done < "$config_file"

  if [[ -n "$output_file" ]]; then
    printf '%s\n' "$content" > "$output_file"
  else
    printf '%s\n' "$content"
  fi
}

# ---------------------------------------------------------------------------
# inject_feature - Replace {{FEATURE:name}} markers with partial file content
#
# Usage: inject_feature <file> <feature_name> <partial_file>
#
# Looks for {{FEATURE:<feature_name>}} in <file> and replaces it with the
# contents of <partial_file>. Edits the file in place.
# ---------------------------------------------------------------------------
inject_feature() {
  local file="$1"
  local feature_name="$2"
  local partial_file="$3"

  if [[ ! -f "$file" ]]; then
    error "Target file not found: $file"
    return 1
  fi
  if [[ ! -f "$partial_file" ]]; then
    warn "Partial file not found: $partial_file (skipping feature '$feature_name')"
    return 0
  fi

  local marker="{{FEATURE:${feature_name}}}"
  local partial_content
  partial_content="$(< "$partial_file")"

  if ! grep -qF "$marker" "$file"; then
    warn "Marker '$marker' not found in $file (skipping)"
    return 0
  fi

  # Use bash string replacement (awk -v cannot handle multi-line content)
  local file_content
  file_content="$(< "$file")"
  printf '%s\n' "${file_content//"$marker"/$partial_content}" > "$file"
}

# ---------------------------------------------------------------------------
# remove_unresolved - Clean up any remaining {{...}} markers in a file
#
# Usage: remove_unresolved <file>
#
# Removes lines that contain unresolved {{...}} placeholders, or optionally
# replaces them with empty strings. Default behaviour: replace with empty.
# ---------------------------------------------------------------------------
remove_unresolved() {
  local file="$1"
  local mode="${2:-replace}" # "replace" (default) or "delete"

  if [[ ! -f "$file" ]]; then
    error "File not found: $file"
    return 1
  fi

  local tmp_file
  tmp_file="$(mktemp)"

  case "$mode" in
    delete)
      # Remove entire lines containing unresolved markers
      grep -v '{{[^}]*}}' "$file" > "$tmp_file" || true
      ;;
    replace|*)
      # Replace markers with empty strings, keep lines
      sed 's/{{[^}]*}}//g' "$file" > "$tmp_file"
      ;;
  esac

  mv "$tmp_file" "$file"
}
