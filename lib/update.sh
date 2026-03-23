#!/bin/bash
# lib/update.sh - Update mode logic for Claude Code Starter Kit
# Requires: lib/colors.sh, lib/snapshot.sh, lib/merge.sh, lib/json-builder.sh
# Compatible: Bash 3.2+ (macOS default) — no associative arrays, no mapfile
set -euo pipefail

# Global: updated files list for deferred snapshot update
_UPDATE_UPDATED_FILES=()

# ---------------------------------------------------------------------------
# _sync_settings_metadata - Sync LANGUAGE (and other vars) from merged settings
#
# After 3-way merge, the merged settings.json is the ground truth.
# Read back key values so write_manifest() and save_config() record the
# actual deployed state, not the stale manifest/variable values.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # variables used by setup.sh (write_manifest, save_config)
_sync_settings_metadata() {
  local settings_file="$1"
  [[ -f "$settings_file" ]] || return 0

  local lang_value
  lang_value="$(jq -r '.language // empty' "$settings_file" 2>/dev/null || true)"

  case "$lang_value" in
    "日本語"|ja) LANGUAGE="ja" ;;
    English|en)  LANGUAGE="en" ;;
    "") ;;  # no language key, keep current
    *)  ;;  # unknown value, keep current
  esac

  # Sync COMMIT_ATTRIBUTION from merged settings (used by setup.sh write_manifest)
  local has_attribution _commit_attr
  has_attribution="$(jq -r 'if has("attribution") then "has" else "none" end' "$settings_file" 2>/dev/null || true)"
  case "$has_attribution" in
    none) _commit_attr="true"  ;;  # no attribution key = enabled
    has)  _commit_attr="false" ;;  # attribution key present = disabled
    *)    _commit_attr="" ;;
  esac
  if [[ -n "$_commit_attr" ]]; then
    COMMIT_ATTRIBUTION="$_commit_attr"  # used by setup.sh write_manifest/save_config
  fi

  # Sync ENABLE_NEW_INIT from merged settings (used by setup.sh)
  local new_init_val
  new_init_val="$(jq -r '.env.CLAUDE_CODE_NEW_INIT // empty' "$settings_file" 2>/dev/null || true)"
  if [[ -n "$new_init_val" ]]; then
    # shellcheck disable=SC2034
    ENABLE_NEW_INIT="$new_init_val"
  fi
}

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

  if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]]; then
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
    if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]]; then
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
  # But if snapshot was just bootstrapped from current, we can't tell if user
  # changed — compare current vs newkit directly instead.
  if ! _file_changed "$snapshot" "$current"; then
    if [[ "${_SNAPSHOT_BOOTSTRAPPED:-false}" == "true" ]]; then
      # Snapshot IS current — check if kit has something different
      if ! _file_changed "$current" "$newkit"; then
        # Current already matches new kit — nothing to do
        return 1
      fi
      # Kit has updates — non-interactive: safe to overwrite since we have
      # no real baseline (snapshot==current). Interactive: ask user.
      if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]]; then
        cp -a "$newkit" "$current"
        return 0
      fi
      _prompt_file_action "$current" "$snapshot" "$newkit"
      case "$_FILE_ACTION" in
        append)
          printf "\n# --- Updated by Claude Code Starter Kit ---\n" >> "$current"
          cat "$newkit" >> "$current"
          return 0
          ;;
        skip|*)
          return 1
          ;;
      esac
    fi
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
# _update_hook_feature - Update hook scripts for a single feature
#
# Usage: _update_hook_feature <feature_name> <src_dir> <claude_dir> <snapshot_dir> <updated_var> <skipped_var>
# ---------------------------------------------------------------------------
_update_hook_feature() {
  local feature_name="$1"
  local src_dir="$2"
  local claude_dir="$3"
  local snapshot_dir="$4"
  local updated_var="$5"
  local skipped_var="$6"

  local dest_dir="${claude_dir}/hooks/${feature_name}"
  local snap_dir="${snapshot_dir}/hooks/${feature_name}"

  [[ -d "$src_dir" ]] || return 0
  mkdir -p "$dest_dir"

  local src_file
  while IFS= read -r -d '' src_file; do
    local basename_file
    basename_file="$(basename "$src_file")"
    local dest_file="${dest_dir}/${basename_file}"
    local snap_file="${snap_dir}/${basename_file}"

    if _update_file "$dest_file" "$snap_file" "$src_file"; then
      chmod +x "$dest_file" 2>/dev/null || true
      eval "${updated_var}+=(\"\$dest_file\")"
    else
      eval "${skipped_var}+=(\"hooks/${feature_name}/${basename_file}\")"
    fi
  done < <(find "$src_dir" -type f -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------
# _update_hook_scripts - Update-aware hook script deployment
#
# Deploys hook scripts through _update_file() so user customizations
# are detected and preserved instead of being silently overwritten.
#
# Usage: _update_hook_scripts <claude_dir> <snapshot_dir> <updated_array_name> <skipped_array_name>
# ---------------------------------------------------------------------------
_update_hook_scripts() {
  local claude_dir="$1"
  local snapshot_dir="$2"
  local updated_var="$3"
  local skipped_var="$4"

  if is_true "$ENABLE_MEMORY_PERSISTENCE"; then
    _update_hook_feature "memory-persistence" \
      "$PROJECT_DIR/features/memory-persistence/scripts" \
      "$claude_dir" "$snapshot_dir" "$updated_var" "$skipped_var"
  fi

  if is_true "$ENABLE_STRATEGIC_COMPACT"; then
    _update_hook_feature "strategic-compact" \
      "$PROJECT_DIR/features/strategic-compact/scripts" \
      "$claude_dir" "$snapshot_dir" "$updated_var" "$skipped_var"
  fi

  if is_true "${ENABLE_AUTO_UPDATE:-false}"; then
    _update_hook_feature "auto-update" \
      "$PROJECT_DIR/features/auto-update/scripts" \
      "$claude_dir" "$snapshot_dir" "$updated_var" "$skipped_var"
  fi

  if is_true "${ENABLE_STATUSLINE:-false}"; then
    _update_hook_feature "statusline" \
      "$PROJECT_DIR/features/statusline/scripts" \
      "$claude_dir" "$snapshot_dir" "$updated_var" "$skipped_var"
  fi

  if is_true "${ENABLE_DOC_SIZE_GUARD:-false}"; then
    _update_hook_feature "doc-size-guard" \
      "$PROJECT_DIR/features/doc-size-guard/scripts" \
      "$claude_dir" "$snapshot_dir" "$updated_var" "$skipped_var"
  fi
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

  # Eagerly clear merge prefs if --reset-prefs was passed (even if no conflicts)
  if [[ "${_RESET_MERGE_PREFS:-false}" == "true" ]]; then
    rm -f "${HOME}/.claude/.starter-kit-merge-prefs.json"
    info "Merge preferences cleared"
  fi

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
    if [[ "${_SNAPSHOT_BOOTSTRAPPED:-false}" == "true" ]]; then
      # Snapshot was bootstrapped from current — no real baseline.
      # Use an empty snapshot so every key is treated as "independently added"
      # by both user and kit, triggering proper conflict resolution.
      local empty_snapshot
      empty_snapshot="$(mktemp)"
      _SETUP_TMP_FILES+=("$empty_snapshot")
      printf '{}\n' > "$empty_snapshot"
      info "$STR_UPDATE_SETTINGS_MERGING"
      merge_settings_3way "$empty_snapshot" "$current_settings" "$new_settings" "$current_settings"
      updated_files+=("$current_settings")
      ok "$STR_UPDATE_SETTINGS_MERGED"
    elif ! _file_changed "$snapshot_settings" "$current_settings"; then
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

  # Sync metadata variables from merged/deployed settings.json so that
  # write_manifest() and save_config() record the actual deployed values.
  _sync_settings_metadata "$current_settings"

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

  # --- Phase 5: Hook scripts (update-aware) ---
  _update_hook_scripts "$claude_dir" "$snapshot_dir" updated_files skipped_files

  # --- Phase 6: Defer snapshot update to end of script ---
  # Snapshot is written AFTER all post-update steps (plugins, Codex MCP, etc.)
  # succeed, so a partial failure doesn't cause snapshot==current on retry.
  _UPDATE_UPDATED_FILES=("${updated_files[@]+"${updated_files[@]}"}")

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
