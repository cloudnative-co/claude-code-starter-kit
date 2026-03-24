#!/bin/bash
# lib/template.sh - Text template engine for CLAUDE.md and similar plain-text files
# NOT for JSON files - use lib/json-builder.sh for JSON.
# Requires: lib/colors.sh and lib/prerequisites.sh (_sed/_awk wrappers) to be sourced first
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
      _sed 's/{{[^}]*}}//g' "$file" > "$tmp_file"
      ;;
  esac

  mv "$tmp_file" "$file"
}

# ---------------------------------------------------------------------------
# CLAUDE.md section markers — kit-managed vs user-owned separation
# ---------------------------------------------------------------------------
_KIT_MARKER_BEGIN="<!-- BEGIN STARTER-KIT-MANAGED -->"
_KIT_MARKER_END="<!-- END STARTER-KIT-MANAGED -->"

# _has_kit_markers <file>
# Returns 0 if file contains the BEGIN marker, 1 otherwise.
_has_kit_markers() {
  grep -qF "$_KIT_MARKER_BEGIN" "$1" 2>/dev/null
}

# _extract_kit_section <file>
# Prints the content between (and including) the BEGIN/END markers.
# If multiple marker pairs exist, only the first is used (with a warning).
_extract_kit_section() {
  local file="$1"
  if ! _has_kit_markers "$file"; then
    return 1
  fi

  # Warn on multiple marker pairs
  local count
  count="$(grep -cF "$_KIT_MARKER_BEGIN" "$file" 2>/dev/null || echo 0)"
  if [[ "$count" -gt 1 ]]; then
    warn "Multiple STARTER-KIT-MANAGED marker pairs found in $file — using first pair only"
  fi

  # All awk marker comparisons strip trailing \r for CRLF tolerance
  _awk -v begin="$_KIT_MARKER_BEGIN" -v end="$_KIT_MARKER_END" '
    { sub(/\r$/, "") }
    $0 == begin { found = 1 }
    found { print }
    $0 == end && found { exit }
  ' "$file"
}

# _extract_user_section <file>
# Prints everything after the END marker line.
# If no markers found, returns the entire file content.
_extract_user_section() {
  local file="$1"
  if ! _has_kit_markers "$file"; then
    cat "$file"
    return
  fi
  _awk -v marker="$_KIT_MARKER_END" '
    { sub(/\r$/, "") }
    found { print; next }
    $0 == marker { found = 1 }
  ' "$file"
}

# _replace_kit_section <file> <new_kit_content_file>
# Replaces everything between (and including) the markers with new content.
# Preserves everything outside the markers (user section).
# Uses awk for reliable marker-based splitting with CRLF tolerance.
_replace_kit_section() {
  local file="$1"
  local new_kit_file="$2"

  local tmp_out
  tmp_out="$(mktemp)"

  # Phase 1: lines before BEGIN marker
  _awk -v marker="$_KIT_MARKER_BEGIN" '
    { sub(/\r$/, "") }
    $0 == marker { exit }
    { print }
  ' "$file" > "$tmp_out"

  # Phase 2: new kit content
  cat "$new_kit_file" >> "$tmp_out"

  # Phase 3: lines after END marker (user section)
  _awk -v marker="$_KIT_MARKER_END" '
    { sub(/\r$/, "") }
    found { print; next }
    $0 == marker { found = 1 }
  ' "$file" >> "$tmp_out"

  mv "$tmp_out" "$file"
}
