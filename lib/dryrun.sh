#!/bin/bash
# lib/dryrun.sh - Dry-run simulation infrastructure
# Requires: lib/colors.sh
# Compatible: Bash 3.2+ (macOS default) — no associative arrays, no mapfile
set -euo pipefail

# ---------------------------------------------------------------------------
# Dry-run log storage (indexed arrays — Bash 3.2 compatible)
#
# Each log entry is stored as "ACTION|TARGET|DETAIL" in _DRYRUN_LOG[].
# Actions: CREATE, MODIFY, MERGE, SKIP, EXTERNAL
# ---------------------------------------------------------------------------
_DRYRUN_LOG=()
_DRYRUN_DIR=""

# ---------------------------------------------------------------------------
# _dryrun_init - Create simulation directory and copy existing ~/.claude
#
# Usage: _dryrun_init <real_claude_dir>
#
# Copies the real ~/.claude into a temp directory so the normal flow can
# execute against it without touching the real filesystem.
# ---------------------------------------------------------------------------
_dryrun_init() {
  local real_dir="$1"

  _DRYRUN_DIR="$(mktemp -d)"
  _SETUP_TMP_FILES+=("$_DRYRUN_DIR")

  if [[ -d "$real_dir" ]]; then
    # Copy existing state for accurate simulation
    cp -a "$real_dir"/. "$_DRYRUN_DIR"/
  fi
}

# ---------------------------------------------------------------------------
# _dryrun_log - Record an action for the summary report
#
# Usage: _dryrun_log <action> <target> [detail]
#
# Actions: CREATE, MODIFY, MERGE, SKIP, EXTERNAL
# ---------------------------------------------------------------------------
_dryrun_log() {
  local action="$1"
  local target="$2"
  local detail="${3:-}"
  _DRYRUN_LOG+=("${action}|${target}|${detail}")
}

# ---------------------------------------------------------------------------
# _dryrun_show_results - Display dry-run summary and diff
#
# Usage: _dryrun_show_results <real_claude_dir>
#
# Comparison basis (fixed): real ~/.claude (current) vs sim dir (simulated).
# The sim dir's snapshot/manifest are temporary artifacts — never shown to
# the user as meaningful state.
# ---------------------------------------------------------------------------
_dryrun_show_results() {
  local real_dir="$1"

  printf "\n"
  section "=== ${STR_DRYRUN_TITLE:-Dry Run Summary} ==="
  printf "\n"

  # Group log entries by action
  local creates="" modifies="" merges="" deletes="" skips="" externals=""
  local entry action target detail
  for entry in "${_DRYRUN_LOG[@]+"${_DRYRUN_LOG[@]}"}"; do
    action="${entry%%|*}"
    local rest="${entry#*|}"
    target="${rest%%|*}"
    detail="${rest#*|}"

    case "$action" in
      CREATE)   creates="${creates}  ${target}${detail:+ ($detail)}\n" ;;
      MODIFY)   modifies="${modifies}  ${target}${detail:+ ($detail)}\n" ;;
      MERGE)    merges="${merges}  ${target}\n    ${detail}\n" ;;
      DELETE)   deletes="${deletes}  ${target}${detail:+ ($detail)}\n" ;;
      SKIP)     skips="${skips}  ${target}${detail:+ ($detail)}\n" ;;
      EXTERNAL) externals="${externals}  [WOULD RUN] ${target}${detail:+: $detail}\n" ;;
    esac
  done

  if [[ -n "$creates" ]]; then
    info "${STR_DRYRUN_CREATED:-Files to create:}"
    printf '%b' "$creates"
    printf "\n"
  fi

  if [[ -n "$modifies" ]]; then
    info "${STR_DRYRUN_MODIFIED:-Files to modify:}"
    printf '%b' "$modifies"
    printf "\n"
  fi

  if [[ -n "$merges" ]]; then
    info "${STR_DRYRUN_MERGED:-Files to merge:}"
    printf '%b' "$merges"
    printf "\n"
  fi

  if [[ -n "$deletes" ]]; then
    info "${STR_DRYRUN_DELETED:-Files to delete:}"
    printf '%b' "$deletes"
    printf "\n"
  fi

  if [[ -n "$skips" ]]; then
    info "${STR_DRYRUN_SKIPPED:-Files to skip (user-owned):}"
    printf '%b' "$skips"
    printf "\n"
  fi

  if [[ -n "$externals" ]]; then
    info "${STR_DRYRUN_EXTERNAL:-External operations:}"
    printf '%b' "$externals"
    printf "\n"
  fi

  # Show settings.json diff if both exist
  _dryrun_settings_diff "$real_dir"

  # Show CLAUDE.md kit section diff
  _dryrun_claudemd_diff "$real_dir"

  printf "\n"
  if [[ -n "$creates" || -n "$modifies" || -n "$deletes" || -n "$externals" ]]; then
    ok "${STR_DRYRUN_WOULD_CHANGE:-The above changes would be applied. This was a dry run — nothing was modified.}"
  else
    ok "${STR_DRYRUN_NO_CHANGES:-No changes detected. This was a dry run.}"
  fi
}

# ---------------------------------------------------------------------------
# _dryrun_settings_diff - Show unified diff of settings.json changes
#
# Comparison: real ~/.claude/settings.json vs sim dir settings.json
# ---------------------------------------------------------------------------
_dryrun_settings_diff() {
  local real_dir="$1"
  local real_settings="${real_dir}/settings.json"
  local sim_settings="${_DRYRUN_DIR}/settings.json"

  if [[ ! -f "$sim_settings" ]]; then
    return
  fi

  if [[ ! -f "$real_settings" ]]; then
    info "${STR_DRYRUN_SETTINGS_NEW:-New settings.json would be created:}"
    printf "\n"
    jq '.' "$sim_settings" 2>/dev/null || cat "$sim_settings"
    return
  fi

  # Normalize both for clean diff (sorted keys)
  local real_norm sim_norm
  real_norm="$(mktemp)"
  sim_norm="$(mktemp)"
  _SETUP_TMP_FILES+=("$real_norm" "$sim_norm")

  jq -S '.' "$real_settings" > "$real_norm" 2>/dev/null || cp "$real_settings" "$real_norm"
  jq -S '.' "$sim_settings" > "$sim_norm" 2>/dev/null || cp "$sim_settings" "$sim_norm"

  if ! diff -q "$real_norm" "$sim_norm" >/dev/null 2>&1; then
    info "${STR_DRYRUN_SETTINGS_DIFF:-settings.json diff (current → simulated):}"
    printf "\n"
    diff -u \
      --label "current (~/.claude/settings.json)" \
      --label "simulated (after install/update)" \
      "$real_norm" "$sim_norm" 2>/dev/null || true
    printf "\n"
  fi
}

# ---------------------------------------------------------------------------
# _dryrun_claudemd_diff - Show kit-section-only diff for CLAUDE.md
#
# Compares real CLAUDE.md kit section vs sim dir CLAUDE.md kit section.
# User section changes are not shown (they are preserved untouched).
# ---------------------------------------------------------------------------
_dryrun_claudemd_diff() {
  local real_dir="$1"
  local real_md="${real_dir}/CLAUDE.md"
  local sim_md="${_DRYRUN_DIR}/CLAUDE.md"

  [[ -f "$sim_md" ]] || return 0

  if [[ ! -f "$real_md" ]]; then
    # New file — already shown as CREATE in file list
    return 0
  fi

  # Extract kit sections for comparison
  local real_kit sim_kit
  real_kit="$(mktemp)"
  sim_kit="$(mktemp)"
  _SETUP_TMP_FILES+=("$real_kit" "$sim_kit")

  if _has_kit_markers "$real_md"; then
    _extract_kit_section "$real_md" > "$real_kit"
  else
    # No markers — compare full file
    cp "$real_md" "$real_kit"
  fi

  if _has_kit_markers "$sim_md"; then
    _extract_kit_section "$sim_md" > "$sim_kit"
  else
    cp "$sim_md" "$sim_kit"
  fi

  if ! diff -q "$real_kit" "$sim_kit" >/dev/null 2>&1; then
    info "CLAUDE.md kit section diff (current → simulated):"
    printf "\n"
    diff -u \
      --label "current (kit section)" \
      --label "simulated (kit section)" \
      "$real_kit" "$sim_kit" 2>/dev/null || true
    printf "\n"
  fi
}

# ---------------------------------------------------------------------------
# _dryrun_collect_file_changes - Scan sim dir for changes vs real dir
#
# Populates _DRYRUN_LOG with CREATE/MODIFY entries by comparing
# sim dir contents against the real ~/.claude directory.
# ---------------------------------------------------------------------------
_dryrun_collect_file_changes() {
  local real_dir="$1"
  local sim_dir="$_DRYRUN_DIR"

  # Walk sim dir and compare against real dir
  while IFS= read -r -d '' sim_file; do
    local rel_path="${sim_file#"$sim_dir"/}"

    # Skip internal kit files from summary
    case "$rel_path" in
      .starter-kit-manifest.json|.starter-kit-snapshot|.starter-kit-snapshot/*) continue ;;
      .starter-kit-merge-prefs.json) continue ;;
    esac

    local real_file="${real_dir}/${rel_path}"

    if [[ ! -f "$real_file" ]]; then
      _dryrun_log "CREATE" "\$HOME/.claude/${rel_path}"
    elif ! diff -q "$real_file" "$sim_file" >/dev/null 2>&1; then
      _dryrun_log "MODIFY" "\$HOME/.claude/${rel_path}"
    fi
  done < <(find "$sim_dir" -type f -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------
# _dryrun_collect_deletions - Detect files that would be deleted
#
# Compares kit-managed files in real dir that are absent from sim dir.
# Only checks files tracked in the manifest (not arbitrary user files).
# ---------------------------------------------------------------------------
_dryrun_collect_deletions() {
  local real_dir="$1"
  local manifest="${real_dir}/.starter-kit-manifest.json"

  # Legacy AGENTS.md removal only happens in update mode
  if [[ "${UPDATE_MODE:-false}" == "true" ]] && [[ -f "${real_dir}/AGENTS.md" ]]; then
    _dryrun_log "DELETE" "\$HOME/.claude/AGENTS.md" "legacy file removed during update"
  fi

  # If no manifest, we can't know what's kit-managed
  [[ -f "$manifest" ]] || return 0

  # Walk manifest-tracked files; if missing from sim dir, it would be deleted
  local file
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    [[ -f "$file" ]] || continue

    local rel_path="${file#"$real_dir"/}"
    local sim_file="${_DRYRUN_DIR}/${rel_path}"

    if [[ ! -f "$sim_file" ]]; then
      _dryrun_log "DELETE" "\$HOME/.claude/${rel_path}"
    fi
  done < <(jq -r '.files[]? // empty' "$manifest" 2>/dev/null)
}
