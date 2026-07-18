#!/bin/bash
# lib/template.sh - Text template engine for CLAUDE.md and similar plain-text files
# NOT for JSON files - use lib/json-builder.sh for JSON.
#
# Requires: lib/colors.sh, lib/prerequisites.sh (_sed/_awk wrappers)
# Uses globals: _SETUP_TMP_FILES[], LANGUAGE
# Exports: inject_feature(), remove_unresolved(),
#          _has_kit_markers(), _extract_kit_section(),
#          _replace_kit_section(), _user_section_heading()
# Dry-run: transparent (operates on whatever file paths are given)
set -euo pipefail

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
  partial_content="$(< "$partial_file")" || return 1

  local grep_rc=0
  grep -qF "$marker" "$file" || grep_rc=$?
  if [[ "$grep_rc" -eq 1 ]]; then
    warn "Marker '$marker' not found in $file (skipping)"
    return 0
  elif [[ "$grep_rc" -ne 0 ]]; then
    return 1
  fi

  # Use bash string replacement (awk -v cannot handle multi-line content)
  local file_content tmp_file
  file_content="$(< "$file")" || return 1
  tmp_file="$(mktemp)" || return 1
  _register_tmp "$tmp_file" || return 1
  printf '%s\n' "${file_content//"$marker"/$partial_content}" > "$tmp_file" || return 1
  mv "$tmp_file" "$file" || return 1
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
  tmp_file="$(mktemp)" || return 1
  _register_tmp "$tmp_file" || return 1

  case "$mode" in
    delete)
      # Remove entire lines containing unresolved markers
      _awk '!/\{\{[^}]*\}\}/' "$file" > "$tmp_file" || return 1
      ;;
    replace|*)
      # Replace markers with empty strings, keep lines
      _sed 's/{{[^}]*}}//g' "$file" > "$tmp_file" || return 1
      ;;
  esac

  mv "$tmp_file" "$file" || return 1
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
  local count count_rc=0
  count="$(grep -cF "$_KIT_MARKER_BEGIN" "$file" 2>/dev/null)" || count_rc=$?
  if [[ "$count_rc" -gt 1 ]]; then
    return 1
  fi
  count="${count:-0}"
  if [[ "$count" -gt 1 ]]; then
    warn "Multiple STARTER-KIT-MANAGED marker pairs found in $file — using first pair only"
  fi

  # All awk marker comparisons strip trailing \r for CRLF tolerance
  _awk -v begin="$_KIT_MARKER_BEGIN" -v end="$_KIT_MARKER_END" '
    { sub(/\r$/, "") }
    $0 == begin { found = 1 }
    found { print }
    $0 == end && found { exit }
  ' "$file" || return 1
}

# _replace_kit_section <file> <new_kit_content_file>
# Replaces everything between (and including) the markers with new content.
# Preserves everything outside the markers (user section).
# Uses awk for reliable marker-based splitting with CRLF tolerance.
_replace_kit_section() {
  local file="$1"
  local new_kit_file="$2"

  local tmp_out
  tmp_out="$(mktemp)" || return 1
  _register_tmp "$tmp_out" || return 1

  # Phase 1: lines before BEGIN marker
  _awk -v marker="$_KIT_MARKER_BEGIN" '
    { sub(/\r$/, "") }
    $0 == marker { exit }
    { print }
  ' "$file" > "$tmp_out" || return 1

  # Phase 2: new kit content
  cat "$new_kit_file" >> "$tmp_out" || return 1

  # Phase 3: lines after END marker (user section)
  _awk -v marker="$_KIT_MARKER_END" '
    { sub(/\r$/, "") }
    found { print; next }
    $0 == marker { found = 1 }
  ' "$file" >> "$tmp_out" || return 1

  mv "$tmp_out" "$file" || return 1
}

# ---------------------------------------------------------------------------
# _user_section_heading - Returns the user section heading for current language
# Used by CLAUDE.md section separation logic in setup.sh and update.sh.
# ---------------------------------------------------------------------------
_user_section_heading() {
  case "${LANGUAGE:-en}" in
    ja) printf '# ユーザー設定' ;;
    *)  printf '# User Settings' ;;
  esac
}
