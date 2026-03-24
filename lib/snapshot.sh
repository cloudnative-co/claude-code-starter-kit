#!/bin/bash
# lib/snapshot.sh - Snapshot management for Claude Code Starter Kit update mechanism
# Saves and compares kit-deployed files to detect user modifications before updates.
#
# Requires: lib/colors.sh
# Uses globals: CLAUDE_DIR
# Exports: _write_snapshot(), _snapshot_exists(), _file_changed(),
#          _snapshot_claude_md(), _repair_snapshot_markers(), _update_snapshot_file()
# Dry-run: transparent (operates on CLAUDE_DIR which may be sim dir)
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
_SNAPSHOT_DIR_NAME=".starter-kit-snapshot"

# ---------------------------------------------------------------------------
# _write_snapshot <claude_dir> <file_path...>
#
# Remove any existing snapshot and create a fresh one by copying each listed
# file, preserving its path relative to <claude_dir>.
# ---------------------------------------------------------------------------
_write_snapshot() {
  local claude_dir="$1"
  shift
  local snapshot_dir="${claude_dir}/${_SNAPSHOT_DIR_NAME}"

  # Remove stale snapshot
  if [[ -d "$snapshot_dir" ]]; then
    rm -rf "$snapshot_dir"
  fi

  mkdir -p "$snapshot_dir"

  local file
  for file in "$@"; do
    # Derive relative path under claude_dir
    local rel_path="${file#"${claude_dir}"/}"
    local dest="${snapshot_dir}/${rel_path}"
    local dest_dir
    dest_dir="$(dirname "$dest")"

    mkdir -p "$dest_dir"

    if [[ -f "$file" ]]; then
      cp "$file" "$dest"
    else
      warn "snapshot: file not found, skipping: $file"
    fi
  done

  ok "Snapshot written to ${snapshot_dir}"
}

# ---------------------------------------------------------------------------
# _snapshot_exists <claude_dir>
#
# Returns 0 (true) if a valid snapshot exists, identified by the presence of
# settings.json inside the snapshot directory.
# ---------------------------------------------------------------------------
_snapshot_exists() {
  local claude_dir="$1"
  local marker="${claude_dir}/${_SNAPSHOT_DIR_NAME}/settings.json"

  [[ -f "$marker" ]]
}

# ---------------------------------------------------------------------------
# _file_changed <snapshot_file> <current_file>
#
# Returns 0 if the files differ, 1 if they are identical.
# Uses diff -q for a fast binary-safe comparison.
# ---------------------------------------------------------------------------
_file_changed() {
  local snapshot_file="$1"
  local current_file="$2"

  if diff -q "$snapshot_file" "$current_file" > /dev/null 2>&1; then
    # Files are identical
    return 1
  else
    # Files differ (or one is missing)
    return 0
  fi
}

# ---------------------------------------------------------------------------
# _update_snapshot_file <claude_dir> <file_path>
#
# Copy a single file into the snapshot, creating parent directories as needed.
# <file_path> must be an absolute path under <claude_dir>.
# ---------------------------------------------------------------------------
_update_snapshot_file() {
  local claude_dir="$1"
  local file_path="$2"
  local snapshot_dir="${claude_dir}/${_SNAPSHOT_DIR_NAME}"

  local rel_path="${file_path#"${claude_dir}"/}"
  local dest="${snapshot_dir}/${rel_path}"
  local dest_dir
  dest_dir="$(dirname "$dest")"

  mkdir -p "$dest_dir"

  if [[ -f "$file_path" ]]; then
    cp "$file_path" "$dest"
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
      info "Snapshot updated: ${rel_path}"
    fi
  else
    warn "snapshot: file not found, cannot update: $file_path"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# _repair_snapshot_markers <snapshot_file>
#
# Validates that a CLAUDE.md snapshot contains at most one BEGIN marker pair.
# If duplicates are found (from a pre-v0.30.0 bug), re-extracts the first
# kit section to repair. Safe to call on any file (no-ops if <=1 marker).
# Also callable from update flow to repair stale snapshots before comparison.
# ---------------------------------------------------------------------------
_repair_snapshot_markers() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  local begin_count
  begin_count="$(grep -cF "$_KIT_MARKER_BEGIN" "$file" 2>/dev/null)" || begin_count=0
  if [[ "$begin_count" -gt 1 ]]; then
    warn "snapshot: CLAUDE.md snapshot has $begin_count marker pairs — repairing"
    _extract_kit_section "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
  fi
}

# ---------------------------------------------------------------------------
# _snapshot_claude_md <claude_dir> <claude_md_path>
#
# Snapshot CLAUDE.md by extracting only the kit-managed section.
# If no markers are present, snapshots the full file (pre-migration state).
# ---------------------------------------------------------------------------
_snapshot_claude_md() {
  local claude_dir="$1"
  local file_path="$2"
  local snapshot_dir="${claude_dir}/${_SNAPSHOT_DIR_NAME}"
  local dest="${snapshot_dir}/CLAUDE.md"

  mkdir -p "$snapshot_dir"

  if [[ ! -f "$file_path" ]]; then
    warn "snapshot: CLAUDE.md not found, cannot snapshot"
    return 1
  fi

  if _has_kit_markers "$file_path"; then
    _extract_kit_section "$file_path" > "$dest"
  else
    # No markers (pre-migration) — snapshot full file
    cp "$file_path" "$dest"
  fi

  _repair_snapshot_markers "$dest"
}
