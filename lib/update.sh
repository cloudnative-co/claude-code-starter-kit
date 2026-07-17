#!/bin/bash
# lib/update.sh - Update mode logic for Claude Code Starter Kit
#
# Requires: lib/colors.sh, lib/snapshot.sh (_repair_snapshot_markers),
#           lib/merge.sh, lib/json-builder.sh,
#           lib/template.sh (_has_kit_markers, _extract_kit_section, _user_section_heading)
# Uses globals: PROJECT_DIR, CLAUDE_DIR, DRY_RUN, _MERGE_INTERACTIVE,
#               _SNAPSHOT_BOOTSTRAPPED, _BACKUP_TIMESTAMP, _SETUP_TMP_FILES[],
#               LANGUAGE, UPDATE_MODE, STR_UPDATE_*
# Exports: run_update(), _check_major_upgrade(), _sync_settings_metadata()
#          (run_update delegates to _update_phase_* functions, one per step)
# Dry-run: run_update has dry-run awareness (logs instead of deploying)
set -euo pipefail

_update_mdm_managed() {
  case "${KIT_MDM_MANAGED:-}" in
    true|TRUE|1|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# _check_major_upgrade - Detect major version jumps and warn the user
#
# Compares the manifest's kit_version with the current kit version.
# On major version bumps, displays recovery instructions.
# Does not block — warns only. The backup is created by backup_existing() before this runs.
# ---------------------------------------------------------------------------
_check_major_upgrade() {
  local claude_dir="$1"
  local manifest="${claude_dir}/.starter-kit-manifest.json"

  [[ -f "$manifest" ]] || return 0

  local old_ver
  old_ver="$(jq -r '.kit_version // empty' "$manifest" 2>/dev/null || true)"
  [[ -n "$old_ver" ]] || return 0

  local new_ver
  new_ver="$(git -C "$PROJECT_DIR" describe --tags --always 2>/dev/null || echo "unknown")"

  # Extract major version numbers (strip leading 'v')
  local old_major new_major
  old_major="${old_ver#v}"; old_major="${old_major%%.*}"
  new_major="${new_ver#v}"; new_major="${new_major%%.*}"

  # Only warn on parseable numeric majors that differ
  [[ "$old_major" =~ ^[0-9]+$ ]] || return 0
  [[ "$new_major" =~ ^[0-9]+$ ]] || return 0
  [[ "$old_major" -ne "$new_major" ]] || return 0

  warn "${STR_MAJOR_UPGRADE_WARN:-Major version upgrade detected}: $old_ver → $new_ver"
  info "${STR_MAJOR_UPGRADE_BACKUP:-A backup will be created before updating.}"

  # Show recovery instructions with actual backup path
  local backup_file="${claude_dir}/.starter-kit-last-backup"
  if [[ -f "$backup_file" ]]; then
    local backup_path
    backup_path="$(cat "$backup_file")"
    info "To restore: BACKUP=\"$backup_path\" && mv ~/.claude ~/.claude.broken && cp -a \"\$BACKUP\" ~/.claude"
  fi
}

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
# _merge_settings_bootstrap is now in lib/merge.sh (moved in v0.22.2)

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

  if _update_mdm_managed; then
    _mdm_distribution_target_is_safe "$current" || return 1
  fi

  # Build new kit content and extract its kit section
  local new_kit_section
  new_kit_section="$(mktemp)"
  _SETUP_TMP_FILES+=("$new_kit_section")
  _extract_kit_section "$new_kit_file" > "$new_kit_section"

  # Case 1: current does not exist → write full new file
  if [[ ! -f "$current" ]]; then
    if _update_mdm_managed; then
      _mdm_atomic_replace_managed_file "$new_kit_file" "$current" || return 1
    else
      cp -a "$new_kit_file" "$current"
    fi
    return 0
  fi

  # Case 2: current has no markers → detect old kit-generated file
  if ! _has_kit_markers "$current"; then
    # Reconstruct what old kit (no markers) would have generated
    local old_kit_output
    old_kit_output="$(mktemp)"
    _SETUP_TMP_FILES+=("$old_kit_output")
    grep -vF "<!-- BEGIN STARTER-KIT-MANAGED -->" "$new_kit_file" \
      | grep -vF "<!-- END STARTER-KIT-MANAGED -->" \
      | grep -vF "$(_user_section_heading)" \
      | grep -v '^<!-- .*custom instructions' \
      > "$old_kit_output" || true

    # Compare ignoring blank lines: exact match = no user edits
    local current_trimmed old_kit_trimmed
    current_trimmed="$(_sed '/^[[:space:]]*$/d' "$current")"
    old_kit_trimmed="$(_sed '/^[[:space:]]*$/d' "$old_kit_output")"

    if [[ "$current_trimmed" == "$old_kit_trimmed" ]]; then
      # Unmodified old kit output → safe to auto-upgrade
      if _update_mdm_managed; then
        _mdm_atomic_replace_managed_file "$new_kit_file" "$current" || return 1
      else
        cp -a "$new_kit_file" "$current"
      fi
      info "CLAUDE.md upgraded to section-aware format"
      return 0
    fi

    if _update_mdm_managed; then
      local kit_section existing_content user_heading merged_current
      kit_section="$(< "$new_kit_section")"
      existing_content="$(< "$current")"
      user_heading="$(_user_section_heading)"
      merged_current="$(mktemp)"
      _SETUP_TMP_FILES+=("$merged_current")
      {
        printf '%s\n' "$kit_section"
        printf '\n%s\n\n' "$user_heading"
        printf '%s\n' "$existing_content"
      } > "$merged_current"
      _mdm_atomic_replace_managed_file "$merged_current" "$current" || return 1
      info "CLAUDE.md upgraded — existing content preserved in user section"
      return 0
    fi

    # Differences found (additions, deletions, or edits) → user customization
    if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]]; then
      warn "$STR_CLAUDEMD_MIGRATION_SKIP"
      return 1
    fi

    warn "$STR_CLAUDEMD_MIGRATION"
    info "Differences from kit template:"
    diff -u "$old_kit_output" "$current" 2>/dev/null >&2 || true
    printf "\n" >&2
    printf "  %s " "$STR_CLAUDEMD_MIGRATION_PROMPT" >&2
    local reply=""
    if read -r reply < /dev/tty 2>/dev/null; then true; else reply="s"; fi
    case "$reply" in
      [Mm]*)
        # Keep the entire current content as user section
        local kit_section existing_content user_heading
        kit_section="$(< "$new_kit_section")"
        existing_content="$(< "$current")"
        user_heading="$(_user_section_heading)"
        {
          printf '%s\n' "$kit_section"
          printf '\n%s\n\n' "$user_heading"
          printf '%s\n' "$existing_content"
        } > "$current"
        info "CLAUDE.md upgraded — your content preserved in user section"
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

  if _update_mdm_managed; then
    local mdm_current
    mdm_current="$(mktemp)"
    _SETUP_TMP_FILES+=("$mdm_current")
    cp -a "$current" "$mdm_current"
    _replace_kit_section "$mdm_current" "$new_kit_section"
    _mdm_atomic_replace_managed_file "$mdm_current" "$current" || return 1
    info "$STR_CLAUDEMD_USER_PRESERVED"
    return 0
  fi

  if [[ ! -f "$snapshot_kit" ]]; then
    # No snapshot → treat as first update, replace kit section
    _replace_kit_section "$current" "$new_kit_section"
    return 0
  fi

  # Repair stale snapshot with duplicated markers (pre-v0.30.0 bug)
  _repair_snapshot_markers "$snapshot_kit"

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
    # Non-interactive: keep current (non-destructive). Without this warning the
    # caller's fallback message reads "no kit changes", hiding that a kit
    # update was actually skipped because the user edited the kit section.
    warn "${STR_CLAUDEMD_KIT_CONFLICT_KEPT:-CLAUDE.md kit section has updates, but your local edits were kept. Re-run interactively to choose.}"
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

# _user_section_heading is now in lib/template.sh (moved in v0.22.2)

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

_is_auto_managed_web_content_package() {
  local path="$1"
  case "$path" in
    */skills/web-content-extraction/package.json|*/skills/web-content-extraction/package-lock.json)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_find_update_content_files() {
  local src_dir="$1"
  if declare -F _find_distribution_files >/dev/null 2>&1; then
    _find_distribution_files "$src_dir"
  else
    find "$src_dir" -type f -print0 2>/dev/null
  fi
}

_count_update_files_in_dir() {
  local src_dir="$1"
  local total=0 _file
  while IFS= read -r -d '' _file; do
    total=$((total + 1))
  done < <(_find_update_content_files "$src_dir")
  printf '%s' "$total"
}

# ---------------------------------------------------------------------------
# _update_file - Update a single file with user change detection
#
# Usage: _update_file <current_path> <snapshot_path> <newkit_path> [kit_owned]
# Returns 0 if file was updated, 1 if skipped
#
# Logic:
#   1. No snapshot file → new from kit → copy, return 0
#   2. Current deleted by user → interactive: ask Restore/Skip; non-interactive: skip
#   3. No user change (snapshot == current) → overwrite with newkit, return 0
#   4. No kit change (snapshot == newkit) → keep current, return 1
#   5. Both changed → prompt user, handle append or skip
#
# When kit_owned=true (e.g., hook scripts), bootstrapped-snapshot overwrites
# unconditionally (both interactive and non-interactive) because these files are
# fully managed by the kit and user customization is not expected.
# ---------------------------------------------------------------------------
_update_file() {
  local current="$1"
  local snapshot="$2"
  local newkit="$3"
  local kit_owned="${4:-false}"

  # MDM mode treats every distributed path as kit-owned desired state. Files
  # outside the distribution are not visited and remain user-owned.
  if _update_mdm_managed; then
    _mdm_atomic_replace_managed_file "$newkit" "$current" || return 1
    return 0
  fi

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
      # Kit differs from current — kit_owned files (hook scripts) are safe
      # to overwrite unconditionally. Other files: non-interactive keeps
      # current (protects user customizations); interactive asks user.
      if _is_auto_managed_web_content_package "$current"; then
        return 0
      fi
      if [[ "$kit_owned" != "true" ]]; then
        if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]]; then
          return 1
        fi
      else
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
  if _is_auto_managed_web_content_package "$current"; then
    return 0
  fi
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
# Usage: _update_hook_feature <feature_name> <src_dir> <claude_dir> <snapshot_dir>
# ---------------------------------------------------------------------------
_UPDATE_UPDATED_FILES=()
_UPDATE_SKIPPED_FILES=()

_update_hook_feature() {
  local feature_name="$1"
  local src_dir="$2"
  local claude_dir="$3"
  local snapshot_dir="$4"

  local dest_dir="${claude_dir}/hooks/${feature_name}"
  local snap_dir="${snapshot_dir}/hooks/${feature_name}"

  [[ -d "$src_dir" ]] || return 0
  if _update_mdm_managed; then
    _mdm_ensure_real_distribution_dir "$dest_dir" || return 1
  else
    mkdir -p "$dest_dir"
  fi

  local src_file
  while IFS= read -r -d '' src_file; do
    local basename_file
    basename_file="$(basename "$src_file")"
    local dest_file="${dest_dir}/${basename_file}"
    local snap_file="${snap_dir}/${basename_file}"

    if _update_file "$dest_file" "$snap_file" "$src_file" "true"; then
      if ! chmod +x "$dest_file" 2>/dev/null && _update_mdm_managed; then
        return 1
      fi
      _UPDATE_UPDATED_FILES+=("$dest_file")
    else
      if _update_mdm_managed; then
        return 1
      fi
      _UPDATE_SKIPPED_FILES+=("hooks/${feature_name}/${basename_file}")
    fi
  done < <(find "$src_dir" -type f -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------
# _update_hook_scripts - Update-aware hook script deployment
#
# Deploys hook scripts through _update_file(kit_owned=true). With a real
# snapshot baseline, user customizations are detected and preserved. With a
# bootstrapped snapshot (no real baseline), kit versions overwrite unconditionally.
#
# Usage: _update_hook_scripts <claude_dir> <snapshot_dir>
# ---------------------------------------------------------------------------
_update_hook_scripts() {
  local claude_dir="$1"
  local snapshot_dir="$2"

  _UPDATE_UPDATED_FILES=()
  _UPDATE_SKIPPED_FILES=()

  local feature_name flag src_dir
  for feature_name in "${_FEATURE_SCRIPT_ORDER[@]}"; do
    [[ "${_FEATURE_HAS_SCRIPTS[$feature_name]+set}" ]] || continue
    flag="${_FEATURE_FLAGS[$feature_name]:-}"
    [[ -n "$flag" ]] || continue
    is_true "${!flag:-false}" || continue
    src_dir="$PROJECT_DIR/features/${feature_name}/scripts"
    _update_hook_feature "$feature_name" "$src_dir" "$claude_dir" "$snapshot_dir" || return 1
  done
}

# _migrate_statusline_command - Rewrite a statusLine that still points at the
# retired bash implementation (statusline-command.sh) to the current kit
# fragment. The bootstrap settings merge ("adopt kit-only sub-keys, keep
# existing sub-keys") preserves the old command value, which would otherwise
# reference a script the kit no longer ships.
_migrate_statusline_command() {
  local settings_file="$1"
  [[ -f "$settings_file" ]] || return 0
  is_true "${ENABLE_STATUSLINE:-false}" || return 0

  local current_cmd
  current_cmd="$(jq -r '.statusLine.command // empty' "$settings_file" 2>/dev/null)" || return 0
  [[ "$current_cmd" == *statusline-command.sh* ]] || return 0

  local fragment="$PROJECT_DIR/features/statusline/hooks.json"
  [[ -f "$fragment" ]] || return 0
  local new_status
  new_status="$(jq -c '.statusLine // empty' "$fragment" 2>/dev/null)" || return 0
  [[ -n "$new_status" ]] || return 0

  local tmp
  tmp="$(mktemp)"
  if jq --argjson sl "$new_status" '.statusLine = $sl' "$settings_file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$settings_file"
    replace_home_path "$settings_file"
    ok "Migrated statusLine to the current kit implementation"
  else
    rm -f "$tmp"
  fi
}

# Hook features the kit no longer ships. Their settings.json entries must be
# stripped during update even when the user customized "hooks" (merge keeps
# user-touched values, which would leave commands pointing at deleted scripts).
_RETIRED_HOOK_FEATURES=(memory-persistence strategic-compact console-log-guard git-push-review)

# _strip_retired_hook_entries - Remove hook commands referencing retired
# feature script dirs (~/.claude/hooks/<feature>/) from settings.json, then
# drop matchers/events left empty. The pattern is anchored on "/.claude/" so
# a user script that merely lives under a directory named after a retired
# feature (e.g. ~/dotfiles/hooks/memory-persistence/) never matches.
_strip_retired_hook_entries() {
  local settings_file="$1"
  [[ -f "$settings_file" ]] || return 0
  local feature tmp changed=false
  for feature in "${_RETIRED_HOOK_FEATURES[@]}"; do
    jq -e --arg p "/.claude/hooks/${feature}/" '
      [(.hooks // {}) | to_entries[] | .value[]?.hooks[]? | (.command // "")]
      | any(contains($p))
    ' "$settings_file" >/dev/null 2>&1 || continue
    tmp="$(mktemp)"
    if jq --arg p "/.claude/hooks/${feature}/" '
      if .hooks then
        .hooks |= (to_entries
          | map(.value |= (map((.hooks //= []) | .hooks |= map(select((.command // "") | contains($p) | not)))
                           | map(select((.hooks | length) > 0))))
          | map(select((.value | length) > 0))
          | from_entries)
      else . end
    ' "$settings_file" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$settings_file"
      changed=true
    else
      rm -f "$tmp"
      warn "Could not strip retired ${feature} hook entries from settings.json (unexpected hooks structure)"
    fi
  done
  if [[ "$changed" == "true" ]]; then
    ok "Removed retired hook entries from settings.json"
  fi
}

_retired_relative_path_is_safe() {
  local rel="$1"
  [[ -n "$rel" && "$rel" != /* && ! "$rel" =~ [[:cntrl:]] ]] || return 1
  case "/$rel/" in
    */../*|*/./*|*//*) return 1 ;;
  esac
  return 0
}

# Refuse to traverse a symlinked directory supplied through a user-writable
# manifest/snapshot tree. The final path itself may be a symlink: rm -f then
# removes the link rather than its referent, but every parent must be real.
_retired_path_has_real_parents() {
  local root="$1" rel="$2" parent_rel current rest segment
  [[ -d "$root" && ! -L "$root" ]] || return 1
  case "$rel" in
    */*) parent_rel="${rel%/*}" ;;
    *) return 0 ;;
  esac
  current="$root"
  rest="$parent_rel"
  while [[ -n "$rest" ]]; do
    segment="${rest%%/*}"
    rest="${rest#"$segment"}"
    rest="${rest#/}"
    current="$current/$segment"
    [[ -d "$current" && ! -L "$current" ]] || return 1
  done
  return 0
}

_remove_retired_managed_files() {
  local claude_dir="$1"
  local snapshot_dir="$2"
  local manifest="${claude_dir}/.starter-kit-manifest.json"
  [[ -f "$manifest" ]] || return 0

  _mdm_reconcile_absent_managed_files "$claude_dir" "$snapshot_dir" || return 1

  # Retired = the CURRENT KIT no longer ships the path. Compare against the
  # full kit enumeration, NOT the on-disk-filtered managed_files_json():
  # a kit-shipped file the user deleted must keep its snapshot baseline so
  # _update_file's restore/skip protection keeps working on later updates.
  collect_managed_target_files
  local kit_rel_json
  kit_rel_json="$({
    local kit_file
    for kit_file in "${_MANAGED_TARGET_FILES[@]+"${_MANAGED_TARGET_FILES[@]}"}"; do
      printf '%s\n' "${kit_file#"$claude_dir"/}"
    done
    true
  } | jq -R -s 'split("\n")[:-1]')"

  # Manifest entries are absolute paths recorded at install time. Under
  # --dry-run, claude_dir points at the sim dir while the copied manifest
  # still holds real-home paths, so resolve relative paths against every
  # known root before giving up.
  local manifest_root
  manifest_root="$(jq -r '.claude_dir // empty' "$manifest" 2>/dev/null)"

  local old_file rel_file target baseline baseline_trusted
  while IFS= read -r old_file; do
    [[ -n "$old_file" ]] || continue
    rel_file=""
    if [[ -n "$manifest_root" && "$old_file" == "$manifest_root"/* ]]; then
      rel_file="${old_file#"$manifest_root"/}"
    elif [[ "$old_file" == "$claude_dir"/* ]]; then
      rel_file="${old_file#"$claude_dir"/}"
    elif [[ "$old_file" == "$HOME/.claude"/* ]]; then
      rel_file="${old_file#"$HOME"/.claude/}"
    fi
    [[ -n "$rel_file" ]] || continue
    if ! _retired_relative_path_is_safe "$rel_file"; then
      warn "Keeping invalid retired manifest path"
      continue
    fi
    case "$rel_file" in
      settings.json|CLAUDE.md) continue ;;
    esac
    if jq -e --arg file "$rel_file" 'index($file) != null' <<< "$kit_rel_json" >/dev/null 2>&1; then
      continue
    fi
    target="$claude_dir/$rel_file"
    baseline="$snapshot_dir/$rel_file"
    if ! _retired_path_has_real_parents "$claude_dir" "$rel_file"; then
      warn "Keeping retired manifest path with unsafe parent: $rel_file"
      continue
    fi
    if _update_mdm_managed; then
      # Current-checkout disabled paths were reconciled above. A path removed
      # from the checkout has no byte oracle, so target-user manifest/snapshot
      # data alone is not deletion authority. Preserve it and fail closed
      # instead of issuing a success receipt that ignores active stale content.
      if [[ -n "${_MDM_UNIVERSE_SOURCE_BY_REL[$rel_file]+set}" \
        || -n "${_MDM_PRIOR_REL_SET[$rel_file]+set}" ]]; then
        continue
      fi
      if [[ -e "$target" || -L "$target" || -e "$baseline" || -L "$baseline" ]]; then
        warn "Ambiguous retired MDM managed file: $rel_file"
        return 1
      fi
      continue
    fi
    baseline_trusted=false
    if [[ -f "$baseline" && ! -L "$baseline" ]] \
      && _retired_path_has_real_parents "$snapshot_dir" "$rel_file"; then
      baseline_trusted=true
    fi
    if [[ -f "$target" ]]; then
      # Same protection policy as _update_file: never silently delete a file
      # the user customized; without a baseline we can't prove it's pristine.
      if [[ "$baseline_trusted" != "true" ]]; then
        warn "Keeping retired kit file (no baseline to verify local changes): $rel_file"
        continue
      fi
      if _file_changed "$baseline" "$target"; then
        warn "Keeping retired kit file with local changes: $rel_file"
        continue
      fi
      rm -f "$target"
      rm -f "$baseline"
      ok "Removed retired managed file: $rel_file"
      _prune_empty_dirs "$(dirname "$target")" "$claude_dir"
      _prune_empty_dirs "$(dirname "$baseline")" "$snapshot_dir"
    else
      # Already absent on disk — drop only the stale baseline.
      if [[ "$baseline_trusted" == "true" ]]; then
        rm -f "$baseline"
        _prune_empty_dirs "$(dirname "$baseline")" "$snapshot_dir"
      fi
    fi
  done < <(jq -r '.files[]? // empty' "$manifest" 2>/dev/null)
}

# Remove now-empty directories from dir upward, stopping at (and never
# removing) the stop directory itself. rmdir fails on non-empty dirs, which
# ends the walk — only genuinely empty parents are pruned.
_prune_empty_dirs() {
  local dir="$1"
  local stop="$2"
  while [[ "$dir" == "$stop"/* ]]; do
    rmdir "$dir" 2>/dev/null || break
    dir="$(dirname "$dir")"
  done
}

_count_update_content_files() {
  local total=0
  local dir
  for dir in agents rules commands skills; do
    local src_dir="${PROJECT_DIR}/${dir}"
    local flag_var
    flag_var="INSTALL_$(printf '%s' "$dir" | tr '[:lower:]' '[:upper:]')"
    [[ -d "$src_dir" ]] || continue
    is_true "${!flag_var:-false}" || continue
    total=$((total + $(_count_update_files_in_dir "$src_dir")))
  done
  printf '%s' "$total"
}

_count_update_hook_files() {
  local total=0
  local feature_name flag src_dir
  for feature_name in "${_FEATURE_SCRIPT_ORDER[@]}"; do
    [[ "${_FEATURE_HAS_SCRIPTS[$feature_name]+set}" ]] || continue
    flag="${_FEATURE_FLAGS[$feature_name]:-}"
    [[ -n "$flag" ]] || continue
    is_true "${!flag:-false}" || continue
    src_dir="$PROJECT_DIR/features/${feature_name}/scripts"
    [[ -d "$src_dir" ]] && total=$((total + $(find "$src_dir" -type f 2>/dev/null | wc -l | tr -d ' ')))
  done
  printf '%s' "$total"
}

# ---------------------------------------------------------------------------
# run_update phases
#
# run_update() delegates to one function per progress step (1-5) plus a
# final report. Phases communicate through shared globals (same pattern as
# _UPDATE_UPDATED_FILES / _UPDATE_SKIPPED_FILES in the hook updater; plain
# array appends, no dynamic variable names):
#   _UPDATE_ALL_UPDATED_FILES — absolute paths of files written this run
#   _UPDATE_ALL_SKIPPED_FILES — display-relative paths of skipped files
#   _UPDATE_NEW_SETTINGS_FILE — freshly built kit settings.json (temp file),
#                               set by phase 1, read by phase 5 so the
#                               snapshot stores the kit baseline
# ---------------------------------------------------------------------------
_UPDATE_ALL_UPDATED_FILES=()
_UPDATE_ALL_SKIPPED_FILES=()
_UPDATE_NEW_SETTINGS_FILE=""

# --- Phase 1/5: settings.json (build new, 3-way compare/merge) ---------------
_update_phase_settings() {
  local claude_dir="$1"
  local snapshot_dir="$2"
  local _dr="${DRY_RUN:-false}"

  _progress_step 1 5 "$STR_UPDATE_SETTINGS"

  local new_settings
  new_settings="$(mktemp)"
  _SETUP_TMP_FILES+=("$new_settings")
  build_settings_file "$new_settings"
  _UPDATE_NEW_SETTINGS_FILE="$new_settings"

  local current_settings="${claude_dir}/settings.json"
  local snapshot_settings="${snapshot_dir}/settings.json"

  if _update_mdm_managed; then
    _mdm_distribution_target_is_safe "$current_settings" || return 1
    _mdm_distribution_target_is_safe "$snapshot_settings" || return 1
  fi

  if [[ -f "$snapshot_settings" ]] && [[ -f "$current_settings" ]]; then
    if [[ "${_SNAPSHOT_BOOTSTRAPPED:-false}" == "true" ]]; then
      # Snapshot was bootstrapped from current — no real baseline.
      # Use current-preserving merge: keep all existing keys, adopt new
      # kit-only keys, prompt on value differences (interactive only).
      info "$STR_UPDATE_SETTINGS_MERGING"
      if [[ -n "${_BACKUP_TIMESTAMP:-}" ]]; then
        info "Restore from backup if needed: ${_BACKUP_PATH:-$HOME/.claude.backup.${_BACKUP_TIMESTAMP}}"
      fi
      _merge_settings_bootstrap "$current_settings" "$new_settings" "$current_settings"
      _UPDATE_ALL_UPDATED_FILES+=("$current_settings")
      if [[ "$_dr" == "true" ]]; then
        info "settings.json will be merged (bootstrap)"
      else
        ok "$STR_UPDATE_SETTINGS_MERGED"
      fi
    elif ! _file_changed "$snapshot_settings" "$current_settings"; then
      # User didn't change settings → safe to overwrite
      if _update_mdm_managed; then
        _mdm_atomic_replace_managed_file "$new_settings" "$current_settings" || return 1
      else
        cp -a "$new_settings" "$current_settings"
      fi
      _UPDATE_ALL_UPDATED_FILES+=("$current_settings")
      if [[ "$_dr" == "true" ]]; then
        info "settings.json will be updated"
      else
        ok "$STR_UPDATE_SETTINGS_UPDATED"
      fi
    elif ! _update_mdm_managed && ! _file_changed "$snapshot_settings" "$new_settings"; then
      # Kit didn't change → keep current
      if [[ "$_dr" == "true" ]]; then
        info "settings.json — no kit changes"
      else
        ok "$STR_UPDATE_SETTINGS_UNCHANGED"
      fi
    else
      # Both changed → 3-way merge
      info "$STR_UPDATE_SETTINGS_MERGING"
      merge_settings_3way "$snapshot_settings" "$current_settings" "$new_settings" "$current_settings"
      _UPDATE_ALL_UPDATED_FILES+=("$current_settings")
      if [[ "$_dr" == "true" ]]; then
        info "settings.json will be merged (3-way)"
      else
        ok "$STR_UPDATE_SETTINGS_MERGED"
      fi
    fi
  else
    # No snapshot → treat as fresh install for settings
    if _update_mdm_managed; then
      _mdm_atomic_replace_managed_file "$new_settings" "$current_settings" || return 1
    else
      cp -a "$new_settings" "$current_settings"
    fi
    _UPDATE_ALL_UPDATED_FILES+=("$current_settings")
    if [[ "$_dr" == "true" ]]; then
      info "settings.json will be created"
    else
      ok "$STR_UPDATE_SETTINGS_UPDATED"
    fi
  fi

  # Sync metadata variables from merged/deployed settings.json so that
  # write_manifest() and save_config() record the actual deployed values.
  _sync_settings_metadata "$current_settings"

  # Bootstrap merges keep existing sub-key values, so a manifest-v1 install
  # can come out of Phase 1 still pointing statusLine at the retired bash
  # implementation. Rewrite it to the current kit fragment.
  _migrate_statusline_command "$current_settings"

  # User-touched "hooks" survive the merge with kit-removed entries intact,
  # which would leave commands pointing at scripts the retired-file sweep
  # deletes. Strip them explicitly.
  _strip_retired_hook_entries "$current_settings"
}

# _claude_md_user_section_has_content - Returns 0 when the user section of a
# deployed CLAUDE.md (everything after the END marker) contains real content
# beyond the scaffold (section heading, HTML comments, blank lines).
_claude_md_user_section_has_content() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  _has_kit_markers "$file" || return 1
  awk '
    { gsub(/\r$/, "") }
    found && NF {
      if ($0 ~ /^[[:space:]]*<!--/) next
      if ($0 == "# ユーザー設定" || $0 == "# User Settings") next
      has = 1; exit
    }
    $0 == "<!-- END STARTER-KIT-MANAGED -->" { found = 1 }
    END { exit has ? 0 : 1 }
  ' "$file"
}

# --- Phase 2/5: CLAUDE.md (section-aware) -------------------------------------
_update_phase_claude_md() {
  local claude_dir="$1"
  local snapshot_dir="$2"
  local _dr="${DRY_RUN:-false}"

  _progress_step 2 5 "$STR_UPDATE_CLAUDEMD"

  local new_claude_md
  new_claude_md="$(mktemp)"
  _SETUP_TMP_FILES+=("$new_claude_md")
  build_claude_md_to_file "$new_claude_md"

  local current_claude_md="${claude_dir}/CLAUDE.md"
  local snapshot_claude_md="${snapshot_dir}/CLAUDE.md"

  local _updated=false
  if _update_mdm_managed; then
    # MDM always converges CLAUDE.md to desired state. Keep this call out of
    # an `if` condition so errexit remains active throughout its call tree.
    _update_claude_md "$current_claude_md" "$snapshot_claude_md" "$new_claude_md"
    _updated=true
  elif _update_claude_md "$current_claude_md" "$snapshot_claude_md" "$new_claude_md"; then
    _updated=true
  fi

  if [[ "$_updated" == "true" ]]; then
    _UPDATE_ALL_UPDATED_FILES+=("$current_claude_md")
    if [[ "$_dr" == "true" ]]; then
      info "CLAUDE.md kit section will be updated"
    else
      ok "$STR_CLAUDEMD_KIT_UPDATED"
    fi
  else
    _UPDATE_ALL_SKIPPED_FILES+=("CLAUDE.md")
    if [[ "$_dr" == "true" ]]; then
      info "CLAUDE.md — no kit section changes"
    else
      info "$STR_CLAUDEMD_KIT_UNCHANGED"
    fi
  fi

  # Non-blocking tip: personal always-loaded instructions live better in
  # ~/.claude/rules/user-*.md (reserved namespace the kit never ships) than
  # in the CLAUDE.md user section. One info line, no prompt, no nag loop.
  if _claude_md_user_section_has_content "$current_claude_md"; then
    info "${STR_UPDATE_USER_RULES_TIP:-Tip: personal instructions in the CLAUDE.md user section can live in ~/.claude/rules/user-*.md instead (reserved for you; never touched by updates). See README.}"
  fi

  # Older releases deployed AGENTS.md into ~/.claude. The starter kit no
  # longer manages that file, so remove the stale copy during update.
  local legacy_agents_md="${claude_dir}/AGENTS.md"
  if [[ -f "$legacy_agents_md" ]]; then
    rm -f "$legacy_agents_md"
    ok "Removed legacy AGENTS.md"
  fi
}

# --- Phase 3/5: Content directories (agents, rules, commands, skills) --------
_update_phase_content() {
  local project_dir="$1"
  local claude_dir="$2"
  local snapshot_dir="$3"

  _progress_step 3 5 "Managed content files"
  local _content_total=0 _content_current=0
  _content_total="$(_count_update_content_files)"
  local dir
  for dir in agents rules commands skills; do
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

    if _update_mdm_managed; then
      _mdm_ensure_real_distribution_dir "$dest_dir" || return 1
    else
      mkdir -p "$dest_dir"
    fi

    local src_file
    while IFS= read -r -d '' src_file; do
      _content_current=$((_content_current + 1))
      if [[ "$_content_total" -gt 0 ]] && { [[ "$_content_current" -eq "$_content_total" ]] || (( _content_current % 10 == 0 )); }; then
        _progress_tick "Managed files" "$_content_current" "$_content_total"
      fi
      local rel_file="${src_file#"$src_dir"/}"
      local dest_file="${dest_dir}/${rel_file}"
      local snap_file="${snap_dir}/${rel_file}"

      # Ensure parent directory exists for nested files (e.g. skills/subdir/file.md)
      if _update_mdm_managed; then
        _mdm_ensure_real_distribution_dir "$(dirname "$dest_file")" || return 1
      else
        mkdir -p "$(dirname "$dest_file")"
      fi

      if _update_file "$dest_file" "$snap_file" "$src_file"; then
        _UPDATE_ALL_UPDATED_FILES+=("$dest_file")
      else
        if _update_mdm_managed; then
          return 1
        fi
        _UPDATE_ALL_SKIPPED_FILES+=("${dir}/${rel_file}")
      fi
    done < <(_find_update_content_files "$src_dir")
  done
}

# --- Phase 4/5: Hook scripts (update-aware) ------------------------------------
_update_phase_hooks() {
  local claude_dir="$1"
  local snapshot_dir="$2"

  _progress_step 4 5 "Hook scripts"
  local _hook_total=0
  _hook_total="$(_count_update_hook_files)"
  if [[ "$_hook_total" -gt 0 ]]; then
    _progress_summary "Hook scripts" "${_hook_total} files to check"
  fi
  _update_hook_scripts "$claude_dir" "$snapshot_dir" || return 1
  _UPDATE_ALL_UPDATED_FILES+=("${_UPDATE_UPDATED_FILES[@]+"${_UPDATE_UPDATED_FILES[@]}"}")
  _UPDATE_ALL_SKIPPED_FILES+=("${_UPDATE_SKIPPED_FILES[@]+"${_UPDATE_SKIPPED_FILES[@]}"}")
  _remove_retired_managed_files "$claude_dir" "$snapshot_dir" || return 1
}

# --- Phase 5/5: Snapshot refresh for each updated file -------------------------
_update_phase_snapshot() {
  local claude_dir="$1"
  local snapshot_dir="$2"
  local _dr="${DRY_RUN:-false}"

  _progress_step 5 5 "Snapshot and summary"
  # CRITICAL: For settings.json, snapshot must store the NEW KIT version
  # (not the merge result). This ensures the next update's 3-way comparison
  # correctly detects user modifications against the kit baseline.
  # If we stored the merge result, next update would see snapshot==current
  # and conclude "user didn't change anything" — silently overwriting.
  if [[ "$_dr" != "true" ]]; then
    info "$STR_UPDATE_SNAPSHOT"
  fi
  local file
  for file in "${_UPDATE_ALL_UPDATED_FILES[@]+"${_UPDATE_ALL_UPDATED_FILES[@]}"}"; do
    local _basename
    _basename="$(basename "$file")"
    if [[ "$_basename" == "CLAUDE.md" ]]; then
      _snapshot_claude_md "$claude_dir" "$file"
    elif [[ "$_basename" == "settings.json" ]]; then
      # Snapshot the kit-generated version, not the merge result
      local _snap_dest="${snapshot_dir}/settings.json"
      if _update_mdm_managed; then
        _mdm_atomic_replace_managed_file \
          "$_UPDATE_NEW_SETTINGS_FILE" "$_snap_dest" || return 1
      else
        mkdir -p "$snapshot_dir"
        cp "$_UPDATE_NEW_SETTINGS_FILE" "$_snap_dest"
      fi
      if [[ "$_dr" != "true" ]]; then
        info "Snapshot updated: settings.json (kit baseline)"
      fi
    elif _is_auto_managed_web_content_package "$file"; then
      # Runtime auto-update rewrites these files. Snapshot the KIT version so
      # the baseline stays kit-owned (same invariant as settings.json above) —
      # a current-content baseline would make the next update read "user
      # unchanged" and silently roll runtime updates back to the kit state.
      local _wc_rel="${file#"$claude_dir"/}"
      if [[ -f "${PROJECT_DIR}/${_wc_rel}" ]]; then
        if _update_mdm_managed; then
          _mdm_atomic_replace_managed_file \
            "${PROJECT_DIR}/${_wc_rel}" "${snapshot_dir}/${_wc_rel}" || return 1
        else
          mkdir -p "$(dirname "${snapshot_dir}/${_wc_rel}")"
          cp -a "${PROJECT_DIR}/${_wc_rel}" "${snapshot_dir}/${_wc_rel}"
        fi
      fi
    else
      _update_snapshot_file "$claude_dir" "$file"
    fi
  done
  if _update_mdm_managed; then
    # MDM compliance attests deterministic owner-only modes. Normalize the
    # complete enabled managed set, including files whose content was already
    # current and therefore did not otherwise need a snapshot refresh.
    collect_managed_target_files
    local _managed _snapshot_file
    for _managed in "${_MANAGED_TARGET_FILES[@]+"${_MANAGED_TARGET_FILES[@]}"}"; do
      [[ -f "$_managed" ]] || continue
      _normalize_mdm_managed_modes "$_managed"
      _snapshot_file="$snapshot_dir/${_managed#"$claude_dir"/}"
      _normalize_mdm_managed_modes "$_snapshot_file"
    done
  fi
  if [[ "$_dr" != "true" ]]; then
    ok "$STR_UPDATE_SNAPSHOT_DONE"
  fi
}

# --- Final report (prints after Step 5/5; skipped entirely in dry-run) ---------
_update_report() {
  local claude_dir="$1"
  local _dr="${DRY_RUN:-false}"

  [[ "$_dr" == "true" ]] && return 0

  if [[ ${#_UPDATE_ALL_SKIPPED_FILES[@]} -gt 0 ]]; then
    printf "\n"
    info "$STR_UPDATE_SKIPPED_TITLE"
    local f
    for f in "${_UPDATE_ALL_SKIPPED_FILES[@]}"; do
      info "  - $f"
    done
  fi

  printf "\n"
  ok "$STR_UPDATE_COMPLETE (${#_UPDATE_ALL_UPDATED_FILES[@]} updated, ${#_UPDATE_ALL_SKIPPED_FILES[@]} skipped)"

  # Show skip notification with recovery info when files were skipped
  if [[ ${#_UPDATE_ALL_SKIPPED_FILES[@]} -gt 0 ]]; then
    info "${STR_UPDATE_SKIPPED_HINT:-Skipped files retain your changes. Kit updates for those files will apply on next update after you accept or reset.}"
    local backup_file="${claude_dir}/.starter-kit-last-backup"
    if [[ -f "$backup_file" ]]; then
      local _skip_backup
      _skip_backup="$(cat "$backup_file")"
      info "To restore kit defaults: cp -a \"$_skip_backup\" ~/.claude"
    fi
  fi

  # --- Auto-update health check ---
  _check_auto_update_health "$claude_dir"
}

# ---------------------------------------------------------------------------
# run_update - Main entry point for update mode
#
# Usage: run_update <project_dir> <claude_dir>
#
# Phases (one function per progress step):
#   1/5 _update_phase_settings  — settings.json: build new, 3-way compare/merge
#   2/5 _update_phase_claude_md — CLAUDE.md: build new, section-aware update
#   3/5 _update_phase_content   — agents, rules, commands, skills
#   4/5 _update_phase_hooks     — hook scripts + retired managed file cleanup
#   5/5 _update_phase_snapshot  — snapshot refresh for each updated file
#   _update_report              — skipped files list + summary (non-dry-run)
# ---------------------------------------------------------------------------
run_update() {
  local project_dir="$1"
  local claude_dir="$2"
  local snapshot_dir="${claude_dir}/.starter-kit-snapshot"

  # Check for major version jumps and show recovery info
  _check_major_upgrade "$claude_dir"

  # Eagerly clear merge prefs if --reset-prefs was passed (even if no conflicts)
  if [[ "${_RESET_MERGE_PREFS:-false}" == "true" ]]; then
    _merge_prefs_file
    rm -f "$_MERGE_PREFS_FILE"
    info "$STR_MERGE_PREFS_CLEARED"
  fi

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    section "Dry Run: Simulating update"
    _progress_summary "Preview Mode" "Simulating update without modifying ~/.claude"
  else
    section "$STR_UPDATE_TITLE"
  fi

  _UPDATE_ALL_UPDATED_FILES=()
  _UPDATE_ALL_SKIPPED_FILES=()
  _UPDATE_NEW_SETTINGS_FILE=""

  # These must remain simple commands. `cmd || return` would disable errexit
  # inside each phase and could turn an I/O failure into a successful update.
  _update_phase_settings "$claude_dir" "$snapshot_dir"
  _update_phase_claude_md "$claude_dir" "$snapshot_dir"
  _update_phase_content "$project_dir" "$claude_dir" "$snapshot_dir"
  _update_phase_hooks "$claude_dir" "$snapshot_dir"
  _update_phase_snapshot "$claude_dir" "$snapshot_dir"
  _update_report "$claude_dir"
}

# ---------------------------------------------------------------------------
# _check_auto_update_health - Warn if auto-update is not active
#
# Checks:
#   1. SessionStart / SessionEnd hooks registered in settings.json
#   2. Git repo exists at ~/.claude-starter-kit (one-liner install)
#   3. Remote is reachable and version matches
# ---------------------------------------------------------------------------
_check_auto_update_health() {
  local claude_dir="$1"
  local settings="${claude_dir}/settings.json"
  local kit_dir="$HOME/.claude-starter-kit"
  local issues=()
  local has_session_start=false
  local has_session_end=false
  local require_session_end=false

  if _claude_supports_async_hooks "2.1.89"; then
    require_session_end=true
  fi

  if command -v jq &>/dev/null; then
    if jq -e '.hooks.SessionStart[]?.hooks[]?.command | contains("auto-update")' "$settings" >/dev/null 2>&1; then
      has_session_start=true
    fi
    if jq -e '.hooks.SessionEnd[]?.hooks[]?.command | contains("auto-update")' "$settings" >/dev/null 2>&1; then
      has_session_end=true
    fi
  else
    if grep -q '"SessionStart"' "$settings" 2>/dev/null && grep -q "auto-update" "$settings" 2>/dev/null; then
      has_session_start=true
    fi
    if grep -q '"SessionEnd"' "$settings" 2>/dev/null && grep -q "auto-update" "$settings" 2>/dev/null; then
      has_session_end=true
    fi
  fi

  # Check 1: hook registered
  if [[ "$has_session_start" != "true" ]]; then
    issues+=("${STR_AUTOUPDATE_NO_HOOK:-SessionStart / SessionEnd hooks are not fully registered}")
  elif [[ "$require_session_end" == "true" ]] && [[ "$has_session_end" != "true" ]]; then
    issues+=("${STR_AUTOUPDATE_NO_HOOK:-SessionStart / SessionEnd hooks are not fully registered}")
  fi

  # Check 2: git repo exists
  if [[ ! -d "${kit_dir}/.git" ]]; then
    issues+=("${STR_AUTOUPDATE_NO_REPO:-Git repo not found at ${kit_dir} (one-liner install required)}")
  fi

  # Check 3: remote version comparison (only if repo exists)
  if [[ -d "${kit_dir}/.git" ]]; then
    local local_ver remote_ver
    local_ver="$(git -C "$kit_dir" describe --tags --abbrev=0 HEAD 2>/dev/null || echo "")"
    remote_ver="$(git -C "$kit_dir" describe --tags --abbrev=0 origin/main 2>/dev/null || echo "")"
    if [[ -n "$local_ver" ]] && [[ -n "$remote_ver" ]] && [[ "$local_ver" != "$remote_ver" ]]; then
      issues+=("${STR_AUTOUPDATE_OUTDATED:-Version mismatch}: ${local_ver} → ${remote_ver}")
    fi
  fi

  if [[ ${#issues[@]} -gt 0 ]]; then
    printf "\n"
    info "${STR_AUTOUPDATE_NOTICE:-Auto-update is not enabled:}"
    local issue
    for issue in "${issues[@]}"; do
      info "  - $issue"
    done
    # Show targeted hints based on what's missing
    if [[ "$has_session_start" != "true" ]] || { [[ "$require_session_end" == "true" ]] && [[ "$has_session_end" != "true" ]]; }; then
      info "${STR_AUTOUPDATE_HINT_HOOK:-To enable: re-run setup.sh and select auto-update in hooks, or use standard/full profile}"
    fi
    if [[ ! -d "${kit_dir}/.git" ]]; then
      info "${STR_AUTOUPDATE_HINT_REPO:-To enable: git clone https://github.com/cloudnative-co/claude-code-starter-kit.git ~/.claude-starter-kit}"
    fi
  else
    ok "${STR_AUTOUPDATE_OK:-Auto-update is active}"
  fi
}
