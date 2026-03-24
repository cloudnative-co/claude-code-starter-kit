#!/bin/bash
# lib/update.sh - Update mode logic for Claude Code Starter Kit
# Requires: lib/colors.sh, lib/snapshot.sh, lib/merge.sh, lib/json-builder.sh
# Compatible: Bash 3.2+ (macOS default) — no associative arrays, no mapfile
set -euo pipefail


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
# _merge_settings_bootstrap - Merge settings.json when no real snapshot exists
#
# Usage: _merge_settings_bootstrap <current> <new_kit> <output>
#
# Strategy: current is the base (user's customizations are preserved).
# Kit-only keys are adopted. Value conflicts are prompted (interactive)
# or resolved in favor of current (non-interactive).
# Objects are recursed one level to adopt new sub-keys.
# ---------------------------------------------------------------------------
_merge_settings_bootstrap() {
  local current="$1"
  local new_kit="$2"
  local output="$3"

  local merged
  merged="$(< "$current")"

  # Collect all keys from both files
  local all_keys
  all_keys="$(jq -rn \
    --slurpfile c "$current" \
    --slurpfile n "$new_kit" \
    '(($c[0] | keys) + ($n[0] | keys)) | unique[]')"

  local key
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    [[ "$key" == "\$schema" ]] && continue

    local cv nv
    cv="$(jq -c --arg k "$key" '.[$k] // empty' "$current"  2>/dev/null || printf '')"
    nv="$(jq -c --arg k "$key" '.[$k] // empty' "$new_kit"  2>/dev/null || printf '')"
    [[ -z "$cv" ]] && cv="null"
    [[ -z "$nv" ]] && nv="null"

    if [[ "$cv" == "null" && "$nv" != "null" ]]; then
      # Kit-only key → adopt
      info "  [kit-add] $key"
      merged="$(printf '%s' "$merged" | jq \
        --arg k "$key" --argjson v "$nv" '.[$k] = $v')"

    elif [[ "$cv" != "null" && "$nv" == "null" ]]; then
      # User-only key → keep
      continue

    elif [[ "$cv" == "$nv" ]]; then
      # Same value → keep
      continue

    else
      # Both have the key with different values
      local cv_type nv_type
      cv_type="$(jq -n --argjson v "$cv" '$v | type')"
      nv_type="$(jq -n --argjson v "$nv" '$v | type')"

      if [[ "$cv_type" == '"object"' && "$nv_type" == '"object"' ]]; then
        # Object: adopt kit-only sub-keys, keep existing sub-keys
        local sub_merged
        sub_merged="$(jq -n --argjson c "$cv" --argjson n "$nv" '
          $c + ($n | to_entries | map(select(.key as $k | $c | has($k) | not)) | from_entries)
        ')"
        merged="$(printf '%s' "$merged" | jq \
          --arg k "$key" --argjson v "$sub_merged" '.[$k] = $v')"
        info "  [merge-object] $key"

      elif [[ "$cv_type" == '"array"' && "$nv_type" == '"array"' ]]; then
        # Array: use _prompt_array_conflict (has remember + non-interactive fallback)
        local chosen
        chosen="$(_prompt_array_conflict "$key" "[]" "$cv" "$nv")"
        merged="$(printf '%s' "$merged" | jq \
          --arg k "$key" --argjson v "$chosen" '.[$k] = $v')"

      else
        # Scalar: prompt or keep current
        local chosen
        chosen="$(_prompt_scalar_conflict "$key" "$cv" "$nv")"
        merged="$(printf '%s' "$merged" | jq \
          --arg k "$key" --argjson v "$chosen" '.[$k] = $v')"
      fi
    fi
  done <<EOF
$all_keys
EOF

  local tmp_out
  tmp_out="$(mktemp)"
  printf '%s\n' "$merged" > "$tmp_out"

  if ! jq empty "$tmp_out" 2>/dev/null; then
    error "Bootstrap merge produced invalid JSON — aborting"
    rm -f "$tmp_out"
    return 1
  fi

  mv "$tmp_out" "$output"
}

# ---------------------------------------------------------------------------
# _update_claude_md - Section-aware CLAUDE.md update
#
# Usage: _update_claude_md <current> <snapshot_kit_section> <new_kit_file>
#
# Compares only the kit-managed section (between markers).
# User section is always preserved untouched.
# Returns 0 if file was updated, 1 if skipped.
# ---------------------------------------------------------------------------
_update_claude_md() {
  local current="$1"
  local snapshot_kit="$2"
  local new_kit_file="$3"

  # Build new kit content and extract its kit section
  local new_kit_section
  new_kit_section="$(mktemp)"
  _SETUP_TMP_FILES+=("$new_kit_section")
  _extract_kit_section "$new_kit_file" > "$new_kit_section"

  # Case 1: current does not exist → write full new file
  if [[ ! -f "$current" ]]; then
    cp -a "$new_kit_file" "$current"
    return 0
  fi

  # Case 2: current has no markers → migration
  if ! _has_kit_markers "$current"; then
    warn "$STR_CLAUDEMD_MIGRATION"
    if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]]; then
      warn "$STR_CLAUDEMD_MIGRATION_SKIP"
      return 1
    fi
    printf "  %s " "$STR_CLAUDEMD_MIGRATION_PROMPT" >&2
    local reply=""
    if read -r reply < /dev/tty 2>/dev/null; then true; else reply="s"; fi
    case "$reply" in
      [Mm]*)
        local kit_section existing_content user_heading
        kit_section="$(< "$new_kit_section")"
        existing_content="$(< "$current")"
        user_heading="$(_user_section_heading)"
        {
          printf '%s\n' "$kit_section"
          printf '\n%s\n\n' "$user_heading"
          printf '%s\n' "$existing_content"
        } > "$current"
        return 0
        ;;
      *) return 1 ;;
    esac
  fi

  # Case 3: current has markers → section-aware 3-way compare
  local current_kit_section
  current_kit_section="$(mktemp)"
  _SETUP_TMP_FILES+=("$current_kit_section")
  _extract_kit_section "$current" > "$current_kit_section"

  if [[ ! -f "$snapshot_kit" ]]; then
    # No snapshot → treat as first update, replace kit section
    _replace_kit_section "$current" "$new_kit_section"
    return 0
  fi

  # Compare kit sections only
  if ! _file_changed "$snapshot_kit" "$current_kit_section"; then
    # User did not edit kit section → safe to replace
    _replace_kit_section "$current" "$new_kit_section"
    info "$STR_CLAUDEMD_USER_PRESERVED"
    return 0
  fi

  if ! _file_changed "$snapshot_kit" "$new_kit_section"; then
    # Kit has no changes → keep current
    return 1
  fi

  # Both changed → conflict on kit section
  if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]]; then
    # Non-interactive: keep current (non-destructive)
    return 1
  fi

  warn "$STR_CLAUDEMD_KIT_CONFLICT"
  while true; do
    printf "  %s " "$STR_CLAUDEMD_KIT_CONFLICT_PROMPT" >&2
    local choice=""
    if read -r choice < /dev/tty 2>/dev/null; then true; else choice="k"; fi
    case "$choice" in
      [Uu]*)
        _replace_kit_section "$current" "$new_kit_section"
        info "$STR_CLAUDEMD_USER_PRESERVED"
        return 0
        ;;
      [Kk]*)
        return 1
        ;;
      [Dd]*)
        diff -u "$current_kit_section" "$new_kit_section" 2>/dev/null >&2 || true
        printf "\n" >&2
        continue
        ;;
      *) return 1 ;;
    esac
  done
}

# _user_section_heading — returns the user section heading for current language
_user_section_heading() {
  case "${LANGUAGE:-en}" in
    ja) printf '# ユーザー設定' ;;
    *)  printf '# User Settings' ;;
  esac
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
    info "$STR_MERGE_FILE_DELETED ${current#"$HOME"/}"
    printf "  %s " "$STR_MERGE_FILE_RESTORE_PROMPT" >&2
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
      # Snapshot IS current — no real baseline exists.
      if ! _file_changed "$current" "$newkit"; then
        # Current already matches new kit — nothing to do
        return 1
      fi
      # Kit differs from current — non-interactive: keep current (protect
      # user customizations; kit additions come in on subsequent updates
      # once a real snapshot exists). Interactive: ask user.
      if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]]; then
        return 1
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
    _merge_prefs_file
    rm -f "$_MERGE_PREFS_FILE"
    info "$STR_MERGE_PREFS_CLEARED"
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
      # Use current-preserving merge: keep all existing keys, adopt new
      # kit-only keys, prompt on value differences (interactive only).
      info "$STR_UPDATE_SETTINGS_MERGING"
      _merge_settings_bootstrap "$current_settings" "$new_settings" "$current_settings"
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

  # --- Phase 2: CLAUDE.md (section-aware) ---
  info "$STR_UPDATE_CLAUDEMD"

  local new_claude_md
  new_claude_md="$(mktemp)"
  _SETUP_TMP_FILES+=("$new_claude_md")
  build_claude_md_to_file "$new_claude_md"

  local current_claude_md="${claude_dir}/CLAUDE.md"
  local snapshot_claude_md="${snapshot_dir}/CLAUDE.md"

  if _update_claude_md "$current_claude_md" "$snapshot_claude_md" "$new_claude_md"; then
    updated_files+=("$current_claude_md")
    ok "$STR_CLAUDEMD_KIT_UPDATED"
  else
    skipped_files+=("CLAUDE.md")
    info "$STR_CLAUDEMD_KIT_UNCHANGED"
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

  # --- Phase 6: Update snapshot for each updated file ---
  # Snapshot is updated here (after all file merges complete) so the
  # snapshot reflects the actual deployed state. This prevents stale
  # snapshots from accumulating when post-update steps (plugins, Codex
  # MCP) fail on retry.
  info "$STR_UPDATE_SNAPSHOT"
  local file
  for file in "${updated_files[@]+"${updated_files[@]}"}"; do
    if [[ "$(basename "$file")" == "CLAUDE.md" ]]; then
      # CLAUDE.md: snapshot kit section only
      _snapshot_claude_md "$claude_dir" "$file"
    else
      _update_snapshot_file "$claude_dir" "$file"
    fi
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
