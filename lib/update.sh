#!/bin/bash
# lib/update.sh - Update mode logic for Claude Code Starter Kit
# Requires: lib/colors.sh, lib/snapshot.sh, lib/merge.sh, lib/json-builder.sh
# Compatible: Bash 3.2+ (macOS default) — no associative arrays, no mapfile
set -euo pipefail

# ---------------------------------------------------------------------------
# _prompt_file_action - Ask user what to do with a changed file
#
# Usage: _prompt_file_action <current_path> <snapshot_path> <newkit_path>
# Returns via global: _FILE_ACTION (append|skip)
#
# Non-interactive: always skip
# Interactive: offer [A]ppend / [S]kip / [D]iff
# ---------------------------------------------------------------------------
_FILE_ACTION=""
_prompt_file_action() {
  local current="$1"
  local snapshot="$2"
  local newkit="$3"
  local display_path="${current#"$HOME"/}"

  if [[ "${WIZARD_NONINTERACTIVE:-false}" == "true" ]]; then
    _FILE_ACTION="skip"
    return
  fi

  while true; do
    warn "$STR_UPDATE_FILE_CHANGED: ~/${display_path}"
    printf "  [A]ppend / [S]kip / [D]iff ? " >&2
    local choice=""
    if read -r choice < /dev/tty 2>/dev/null; then
      true
    else
      choice="s"
    fi
    case "$choice" in
      a|A)
        _FILE_ACTION="append"
        return
        ;;
      s|S)
        _FILE_ACTION="skip"
        return
        ;;
      d|D)
        printf "\n" >&2
        info "--- Snapshot (kit original)"
        info "+++ Current (your version)"
        diff -u "$snapshot" "$current" 2>/dev/null || true
        printf "\n" >&2
        info "--- Current (your version)"
        info "+++ New kit version"
        diff -u "$current" "$newkit" 2>/dev/null || true
        printf "\n" >&2
        ;;
      *)
        _FILE_ACTION="skip"
        return
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# _update_file - Update a single file with user change detection
#
# Usage: _update_file <current_path> <snapshot_path> <newkit_path>
# Returns 0 if file was updated, 1 if skipped
#
# Logic:
#   1. No snapshot file → new from kit → copy, return 0
#   2. Current deleted by user → interactive: ask Restore/Skip; non-interactive: skip
#   3. No user change (snapshot == current) → overwrite with newkit, return 0
#   4. No kit change (snapshot == newkit) → keep current, return 1
#   5. Both changed → prompt user, handle append or skip
# ---------------------------------------------------------------------------
_update_file() {
  local current="$1"
  local snapshot="$2"
  local newkit="$3"

  # New file from kit (not in snapshot)
  if [[ ! -f "$snapshot" ]]; then
    cp -a "$newkit" "$current"
    return 0
  fi

  # Current file was deleted by user
  if [[ ! -f "$current" ]]; then
    if [[ "${WIZARD_NONINTERACTIVE:-false}" == "true" ]]; then
      return 1
    fi
    info "File deleted by you: ${current#"$HOME"/}"
    printf "  [R]estore / [S]kip ? " >&2
    local choice=""
    if read -r choice < /dev/tty 2>/dev/null; then
      true
    else
      choice="s"
    fi
    case "$choice" in
      r|R)
        cp -a "$newkit" "$current"
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  fi

  # No user change → safe to overwrite
  if ! _file_changed "$snapshot" "$current"; then
    cp -a "$newkit" "$current"
    return 0
  fi

  # No kit change → keep current
  if ! _file_changed "$snapshot" "$newkit"; then
    return 1
  fi

  # Both changed → ask user
  _prompt_file_action "$current" "$snapshot" "$newkit"
  case "$_FILE_ACTION" in
    append)
      # Append new kit content after current content with separator
      printf "\n# --- Updated by Claude Code Starter Kit ---\n" >> "$current"
      cat "$newkit" >> "$current"
      return 0
      ;;
    skip|*)
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# run_update - Main entry point for update mode
#
# Usage: run_update <project_dir> <claude_dir>
#
# Phases:
#   1. settings.json: build new, 3-way compare/merge
#   2. CLAUDE.md: build new, _update_file
#   3. Content directories (agents, rules, commands, skills, memory)
#   4. Hook scripts: deploy_hook_scripts
#   5. Update snapshot for each updated file
#   6. Report: skipped files list + summary
# ---------------------------------------------------------------------------
run_update() {
  local project_dir="$1"
  local claude_dir="$2"
  local snapshot_dir="${claude_dir}/.starter-kit-snapshot"

  section "$STR_UPDATE_TITLE"

  local updated_files=()
  local skipped_files=()

  # --- Phase 1: settings.json ---
  info "$STR_UPDATE_SETTINGS"

  local new_settings
  new_settings="$(mktemp)"
  _SETUP_TMP_FILES+=("$new_settings")
  build_settings_to_file "$new_settings"

  local current_settings="${claude_dir}/settings.json"
  local snapshot_settings="${snapshot_dir}/settings.json"

  if [[ -f "$snapshot_settings" ]] && [[ -f "$current_settings" ]]; then
    if ! _file_changed "$snapshot_settings" "$current_settings"; then
      # User didn't change settings → safe to overwrite
      cp -a "$new_settings" "$current_settings"
      updated_files+=("$current_settings")
      ok "$STR_UPDATE_SETTINGS_UPDATED"
    elif ! _file_changed "$snapshot_settings" "$new_settings"; then
      # Kit didn't change → keep current
      ok "$STR_UPDATE_SETTINGS_UNCHANGED"
    else
      # Both changed → 3-way merge
      info "$STR_UPDATE_SETTINGS_MERGING"
      merge_settings_3way "$snapshot_settings" "$current_settings" "$new_settings" "$current_settings"
      updated_files+=("$current_settings")
      ok "$STR_UPDATE_SETTINGS_MERGED"
    fi
  else
    # No snapshot → treat as fresh install for settings
    cp -a "$new_settings" "$current_settings"
    updated_files+=("$current_settings")
    ok "$STR_UPDATE_SETTINGS_UPDATED"
  fi

  # --- Phase 2: CLAUDE.md ---
  info "$STR_UPDATE_CLAUDEMD"

  local new_claude_md
  new_claude_md="$(mktemp)"
  _SETUP_TMP_FILES+=("$new_claude_md")
  build_claude_md_to_file "$new_claude_md"

  local current_claude_md="${claude_dir}/CLAUDE.md"
  local snapshot_claude_md="${snapshot_dir}/CLAUDE.md"

  if _update_file "$current_claude_md" "$snapshot_claude_md" "$new_claude_md"; then
    updated_files+=("$current_claude_md")
    ok "$STR_UPDATE_CLAUDEMD_UPDATED"
  else
    skipped_files+=("CLAUDE.md")
    info "$STR_UPDATE_CLAUDEMD_SKIPPED"
  fi

  # Older releases deployed AGENTS.md into ~/.claude. The starter kit no
  # longer manages that file, so remove the stale copy during update.
  local legacy_agents_md="${claude_dir}/AGENTS.md"
  if [[ -f "$legacy_agents_md" ]]; then
    rm -f "$legacy_agents_md"
    ok "Removed legacy AGENTS.md"
  fi

  # --- Phase 3: Content directories ---
  local dir
  for dir in agents rules commands skills memory; do
    local src_dir="${project_dir}/${dir}"
    local dest_dir="${claude_dir}/${dir}"
    local snap_dir="${snapshot_dir}/${dir}"

    [[ -d "$src_dir" ]] || continue

    # Check INSTALL_* flag (e.g. INSTALL_AGENTS)
    local flag_var
    flag_var="INSTALL_$(printf '%s' "$dir" | tr '[:lower:]' '[:upper:]')"
    if ! is_true "${!flag_var:-false}"; then
      continue
    fi

    mkdir -p "$dest_dir"

    while IFS= read -r -d '' src_file; do
      local basename_file
      basename_file="$(basename "$src_file")"
      local dest_file="${dest_dir}/${basename_file}"
      local snap_file="${snap_dir}/${basename_file}"

      if _update_file "$dest_file" "$snap_file" "$src_file"; then
        updated_files+=("$dest_file")
      else
        skipped_files+=("${dir}/${basename_file}")
      fi
    done < <(find "$src_dir" -type f -print0 2>/dev/null)
  done

  # --- Phase 5: Hook scripts ---
  deploy_hook_scripts

  # --- Phase 6: Update snapshot for each updated file ---
  info "$STR_UPDATE_SNAPSHOT"
  local file
  for file in "${updated_files[@]+"${updated_files[@]}"}"; do
    _update_snapshot_file "$claude_dir" "$file"
  done
  ok "$STR_UPDATE_SNAPSHOT_DONE"

  # --- Report ---
  if [[ ${#skipped_files[@]} -gt 0 ]]; then
    printf "\n"
    info "$STR_UPDATE_SKIPPED_TITLE"
    local f
    for f in "${skipped_files[@]}"; do
      info "  - $f"
    done
  fi

  printf "\n"
  ok "$STR_UPDATE_COMPLETE (${#updated_files[@]} updated, ${#skipped_files[@]} skipped)"
}
