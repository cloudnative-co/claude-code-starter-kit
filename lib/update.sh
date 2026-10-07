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
  case "$(printf '%s' "${KIT_MDM_MANAGED:-}" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
    true|1|yes|y|on) return 0 ;;
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
  [[ -f "$settings_file" ]] || return 1

  local lang_value
  lang_value="$(jq -r '.language // empty' "$settings_file" 2>/dev/null)" \
    || return 1

  case "$lang_value" in
    "日本語"|ja) LANGUAGE="ja" ;;
    English|en)  LANGUAGE="en" ;;
    "") ;;  # no language key, keep current
    *)  ;;  # unknown value, keep current
  esac

  # Sync COMMIT_ATTRIBUTION from merged settings (used by setup.sh write_manifest)
  local has_attribution _commit_attr
  has_attribution="$(jq -r \
    'if has("attribution") then "has" else "none" end' \
    "$settings_file" 2>/dev/null)" || return 1
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
  new_init_val="$(jq -r '.env.CLAUDE_CODE_NEW_INIT // empty' \
    "$settings_file" 2>/dev/null)" || return 1
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
  new_kit_section="$(mktemp)" || return 2
  _SETUP_TMP_FILES+=("$new_kit_section")
  if _update_mdm_managed; then
    # Keep the call simple in the privileged production path so Bash errexit
    # remains active inside the helper's dynamic call tree.
    _extract_kit_section "$new_kit_file" > "$new_kit_section"
  else
    _extract_kit_section "$new_kit_file" > "$new_kit_section" || return 2
  fi

  # Case 1: current does not exist → write full new file
  if [[ ! -f "$current" ]]; then
    if _update_mdm_managed; then
      _mdm_atomic_replace_managed_file "$new_kit_file" "$current" || return 1
    else
      cp -a "$new_kit_file" "$current" || return 2
    fi
    return 0
  fi

  # Case 2: current has no markers → detect old kit-generated file
  if ! _has_kit_markers "$current"; then
    # Reconstruct what old kit (no markers) would have generated
    local old_kit_output user_heading
    old_kit_output="$(mktemp)" || return 2
    _SETUP_TMP_FILES+=("$old_kit_output")
    user_heading="$(_user_section_heading)" || return 2
    _awk \
      -v begin='<!-- BEGIN STARTER-KIT-MANAGED -->' \
      -v end='<!-- END STARTER-KIT-MANAGED -->' \
      -v heading="$user_heading" '
        index($0, begin) || index($0, end) || index($0, heading) \
          || $0 ~ /^<!-- .*custom instructions/ { next }
        { print }
      ' "$new_kit_file" > "$old_kit_output" || return 2

    # Compare ignoring blank lines: exact match = no user edits
    local current_trimmed old_kit_trimmed
    current_trimmed="$(_sed '/^[[:space:]]*$/d' "$current")" || return 2
    old_kit_trimmed="$(_sed '/^[[:space:]]*$/d' "$old_kit_output")" || return 2

    if [[ "$current_trimmed" == "$old_kit_trimmed" ]]; then
      # Unmodified old kit output → safe to auto-upgrade
      if _update_mdm_managed; then
        _mdm_atomic_replace_managed_file "$new_kit_file" "$current" || return 1
      else
        cp -a "$new_kit_file" "$current" || return 2
      fi
      info "CLAUDE.md upgraded to section-aware format"
      return 0
    fi

    if _update_mdm_managed; then
      local kit_section existing_content user_heading merged_current
      kit_section="$(< "$new_kit_section")"
      existing_content="$(< "$current")"
      user_heading="$(_user_section_heading)" || return 2
      merged_current="$(mktemp)" || return 2
      _SETUP_TMP_FILES+=("$merged_current")
      {
        printf '%s\n' "$kit_section"
        printf '\n%s\n\n' "$user_heading"
        printf '%s\n' "$existing_content"
      } > "$merged_current" || return 2
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
        user_heading="$(_user_section_heading)" || return 2
        {
          printf '%s\n' "$kit_section"
          printf '\n%s\n\n' "$user_heading"
          printf '%s\n' "$existing_content"
        } > "$current" || return 2
        info "CLAUDE.md upgraded — your content preserved in user section"
        return 0
        ;;
      *) return 1 ;;
    esac
  fi

  # Case 3: current has markers → section-aware 3-way compare
  local current_kit_section
  current_kit_section="$(mktemp)" || return 2
  _SETUP_TMP_FILES+=("$current_kit_section")
  _extract_kit_section "$current" > "$current_kit_section" || return 2

  if _update_mdm_managed; then
    local mdm_current
    mdm_current="$(mktemp)" || return 1
    _SETUP_TMP_FILES+=("$mdm_current")
    cp -a "$current" "$mdm_current" || return 1
    _replace_kit_section "$mdm_current" "$new_kit_section" || return 1
    _mdm_atomic_replace_managed_file "$mdm_current" "$current" || return 1
    info "$STR_CLAUDEMD_USER_PRESERVED"
    return 0
  fi

  if [[ ! -f "$snapshot_kit" ]]; then
    # No snapshot → treat as first update, replace kit section
    _replace_kit_section "$current" "$new_kit_section" || return 2
    return 0
  fi

  # Repair stale snapshot with duplicated markers (pre-v0.30.0 bug)
  _repair_snapshot_markers "$snapshot_kit" || return 2

  # Compare kit sections only
  if ! _file_changed "$snapshot_kit" "$current_kit_section"; then
    # User did not edit kit section → safe to replace
    _replace_kit_section "$current" "$new_kit_section" || return 2
    info "$STR_CLAUDEMD_USER_PRESERVED"
    return 0
  fi

  if ! _file_changed "$snapshot_kit" "$new_kit_section"; then
    # Kit has no changes → keep current
    return 1
  fi

  if ! _file_changed "$current_kit_section" "$new_kit_section"; then
    # The kit section already holds this version's content while the snapshot
    # is older: an earlier run wrote it and stopped before refreshing the
    # baseline (for example on the dependency lock after Step 2). That is not
    # a user edit. Leave the file as it is and let the caller refresh the
    # snapshot so the next update compares against the right baseline.
    return 3
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
        _replace_kit_section "$current" "$new_kit_section" || return 2
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

# Runtime dependency updates intentionally rewrite the WCE package files.
# Dependency versions are runtime-owned, while dependency keys and all other
# JSON structure remain kit-owned. The package and lock files are validated,
# rendered, and committed as one rollback-protected transaction below.
_wce_package_file_is_valid() {
  local path="$1"
  case "$(basename "$path")" in
    package.json|package.json.*)
      jq -e '
        type == "object" and
        ((has("dependencies") | not) or
          (.dependencies | type == "object")) and
        ((.dependencies // {}) | all(.[]; type == "string"))
      ' "$path" >/dev/null 2>&1
      ;;
    package-lock.json|package-lock.json.*)
      jq -e '
        type == "object" and
        (.packages | type == "object") and
        (.packages[""] | type == "object") and
        ((.packages[""] | has("dependencies") | not) or
          (.packages[""].dependencies | type == "object")) and
        ((.packages[""].dependencies // {}) |
          all(.[]; type == "string"))
      ' "$path" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

_wce_package_dependency_keys() {
  local path="$1"
  case "$(basename "$path")" in
    package.json|package.json.*)
      jq -c '(.dependencies // {}) | keys' "$path"
      ;;
    package-lock.json|package-lock.json.*)
      jq -c '(.packages[""].dependencies // {}) | keys' "$path"
      ;;
    *) return 1 ;;
  esac
}

_wce_package_dependency_keys_equal() {
  local left="$1" right="$2" left_keys right_keys
  left_keys="$(_wce_package_dependency_keys "$left")" || return 2
  right_keys="$(_wce_package_dependency_keys "$right")" || return 2
  [[ "$left_keys" == "$right_keys" ]]
}

_wce_package_root_dependencies() {
  local path="$1"
  case "$(basename "$path")" in
    package.json|package.json.*)
      jq -cS '(.dependencies // {})' "$path"
      ;;
    package-lock.json|package-lock.json.*)
      jq -cS '(.packages[""].dependencies // {})' "$path"
      ;;
    *) return 1 ;;
  esac
}

_wce_package_root_dependencies_equal() {
  local left="$1" right="$2" left_dependencies right_dependencies
  left_dependencies="$(_wce_package_root_dependencies "$left")" || return 2
  right_dependencies="$(_wce_package_root_dependencies "$right")" || return 2
  [[ "$left_dependencies" == "$right_dependencies" ]]
}

_wce_package_pair_is_valid() { # <package.json> <package-lock.json>
  local package_file="$1" lock_file="$2"
  _wce_package_file_is_valid "$package_file" || return 1
  _wce_package_file_is_valid "$lock_file" || return 1
  # npm records the root dependency specifications in both files. Matching
  # names with different ranges is not a coherent package/lock contract.
  _wce_package_root_dependencies_equal "$package_file" "$lock_file"
}

_wce_package_pair_runtime_state() { # <package.json> <package-lock.json>
  local package_file="$1" lock_file="$2"
  jq -cS -n \
    --slurpfile package_file "$package_file" \
    --slurpfile lock_file "$lock_file" '
      {
        dependencies: ($package_file[0].dependencies // {}),
        packages: (($lock_file[0].packages // {}) | del(.[""])),
        legacyDependencies: (
          if ($lock_file[0] | has("dependencies")) then
            $lock_file[0].dependencies
          else null end
        )
      }
    '
}

_wce_package_pair_runtime_state_equal() { # <left-pkg> <left-lock> <right-pkg> <right-lock>
  local left_package="$1" left_lock="$2" right_package="$3" right_lock="$4"
  local left_state right_state
  left_state="$(_wce_package_pair_runtime_state \
    "$left_package" "$left_lock")" || return 2
  right_state="$(_wce_package_pair_runtime_state \
    "$right_package" "$right_lock")" || return 2
  [[ "$left_state" == "$right_state" ]]
}

_wce_render_auto_managed_package_file() { # <current> <newkit> <reset> <output>
  local current="$1" newkit="$2" reset_to_kit="$3" output="$4"
  local filename
  filename="$(basename "$newkit")"
  if [[ "$reset_to_kit" == "true" ]]; then
    cp -p "$newkit" "$output" || return 1
  elif [[ "$filename" == "package.json" ]]; then
    cp -p "$current" "$output" || return 1
    jq -n --slurpfile current "$current" --slurpfile newkit "$newkit" '
      $current[0] as $current_package |
      $newkit[0]
      | if has("dependencies") then
          .dependencies |= with_entries(
            .value = ($current_package.dependencies[.key] // .value)
          )
        else . end
    ' > "$output" 2>/dev/null || return 1
  elif [[ "$filename" == "package-lock.json" ]]; then
    cp -p "$current" "$output" || return 1
    jq -n --slurpfile current "$current" --slurpfile newkit "$newkit" '
      $current[0] as $current_lock |
      $newkit[0]
      | .packages = $current_lock.packages
      | if ($current_lock | has("dependencies")) then
          .dependencies = $current_lock.dependencies
        else
          del(.dependencies)
        end
      | .packages[""] = (
          $newkit[0].packages[""]
          | if has("dependencies") then
              .dependencies |= with_entries(
                .value = (
                  $current_lock.packages[""].dependencies[.key] // .value
                )
              )
            else . end
        )
    ' > "$output" 2>/dev/null || return 1
  else
    return 1
  fi
  _wce_package_file_is_valid "$output"
}

# Single-file fallback used by _update_file callers outside the content phase.
# The production content phase commits package.json and package-lock.json with
# _update_auto_managed_wce_package_pair so they cannot diverge on an error.
_merge_auto_managed_web_content_package() { # <current> <snapshot> <newkit>
  local current="$1" snapshot="$2" newkit="$3"
  local reset_to_kit=false tmp compare_rc=0
  _wce_package_file_is_valid "$newkit" || return 1
  if ! _wce_package_file_is_valid "$current" \
    || ! _wce_package_file_is_valid "$snapshot"; then
    reset_to_kit=true
  elif [[ "${_SNAPSHOT_BOOTSTRAPPED:-false}" != "true" ]] \
    && ! _file_changed "$snapshot" "$current"; then
    reset_to_kit=true
  else
    _wce_package_dependency_keys_equal "$snapshot" "$newkit" \
      || compare_rc=$?
    case "$compare_rc" in
      0) ;;
      1) reset_to_kit=true ;;
      *) return 1 ;;
    esac
    compare_rc=0
    _wce_package_dependency_keys_equal "$current" "$newkit" \
      || compare_rc=$?
    case "$compare_rc" in
      0) ;;
      1) reset_to_kit=true ;;
      *) return 1 ;;
    esac
  fi
  tmp="$(mktemp "${current}.merge.XXXXXX")" || return 1
  _SETUP_TMP_FILES+=("$tmp")
  _wce_render_auto_managed_package_file \
    "$current" "$newkit" "$reset_to_kit" "$tmp" \
    || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$current" || { rm -f "$tmp"; return 1; }
}

_wce_package_pair_mv() {
  mv -f "$1" "$2"
}

_wce_runtime_update_lock_owner_matches() { # <current-dir> <token> [lock-dir]
  local current_dir="$1" token="$2"
  local lock_dir="${3:-$current_dir/logs/.update.lock}"
  local owner_file="$lock_dir/owner" owner bytes
  case "$token" in ""|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 1
  [[ -f "$owner_file" && ! -L "$owner_file" ]] || return 1
  bytes="$(LC_ALL=C wc -c < "$owner_file" 2>/dev/null | tr -d '[:space:]')" \
    || return 1
  [[ "$bytes" == "$((${#token} + 1))" ]] || return 1
  IFS= read -r owner < "$owner_file" || return 1
  [[ "$owner" == "$token" ]]
}

_wce_runtime_update_lock_owner_only() { # <lock-dir>
  local lock_dir="$1" entry count=0
  while IFS= read -r -d '' entry; do
    [[ "$entry" == "$lock_dir/owner" ]] || return 1
    count=$((count + 1))
  done < <(find "$lock_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  [[ "$count" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# Lock inspection, diagnosis, and bounded recovery
#
# A writer that is killed while holding the lock (SIGKILL, power loss, an async
# hook torn down with its session) cannot release it. Acquisition never takes
# over an existing lock, so such a lock used to block every later update with
# a bare exit 75. The helpers below (1) classify what is on disk without
# changing it, (2) explain a failure, and (3) let the pre-write preflight — and
# only the preflight — remove a lock whose owner provably no longer exists.
# ---------------------------------------------------------------------------

# Minimum age of the owner file before an ownerless lock may be recovered.
# Deliberately not overridable from the environment.
_WCE_RUNTIME_LOCK_STALE_MINUTES=60
# How long an acquisition that found the reclaim mutex waits for the
# reclaimer to finish before withdrawing (update-deps.mjs uses the same).
_WCE_RUNTIME_LOCK_WITHDRAW_WAIT_SECONDS=3

_WCE_LOCK_STATE=""      # free | busy | stale | unknown | unusable
_WCE_LOCK_OWNER=""      # exact token when recognized; display-safe otherwise
_WCE_LOCK_OWNER_PID=""  # set only for a recognized token
_WCE_LOCK_PID_STATE=""  # alive | dead | unknown
_WCE_LOCK_CREATED=""    # owner file mtime, for display
_WCE_LOCK_UNUSABLE=""   # the symlink / non-directory that makes the path unusable
_WCE_LOCK_MUTEX=false   # whether the reclaim mutex exists beside the lock

# Git Bash cannot tell whether a lock owner is alive: Windows node.exe and
# MSYS use different PID spaces.
_wce_runtime_update_lock_pid_probe_unsupported() {
  if declare -F is_msys >/dev/null 2>&1 && is_msys; then
    return 0
  fi
  case "$(uname -s 2>/dev/null || true)" in
    MSYS_NT*|MINGW*_NT*|CLANG*_NT*|UCRT*_NT*) return 0 ;;
  esac
  return 1
}

_wce_runtime_update_lock_pid_state() { # <pid> -> alive | dead | unknown
  local pid="$1" ps_out="" ps_rc=0
  case "$pid" in
    ""|0*|*[!0123456789]*) printf 'unknown'; return 0 ;;
  esac
  if _wce_runtime_update_lock_pid_probe_unsupported; then
    printf 'unknown'
    return 0
  fi
  if kill -0 "$pid" 2>/dev/null; then
    printf 'alive'
    return 0
  fi
  # `kill -0` fails the same way for "no such process" and "not permitted"
  # (another user's process that reused the PID), so ask the process table.
  if [[ -d /proc/self ]]; then
    if [[ -e "/proc/$pid" ]]; then
      printf 'alive'
    else
      printf 'dead'
    fi
    return 0
  fi
  ps_out="$(ps -p "$pid" -o pid= 2>/dev/null)" || ps_rc=$?
  ps_out="${ps_out//[[:space:]]/}"
  if [[ "$ps_rc" -eq 0 && "$ps_out" == "$pid" ]]; then
    printf 'alive'
  elif [[ "$ps_rc" -eq 1 && -z "$ps_out" ]]; then
    printf 'dead'
  else
    printf 'unknown'
  fi
  return 0
}

_wce_runtime_update_lock_owner_mtime() { # <owner-file> -> "YYYY-MM-DD HH:MM:SS +ZZZZ"
  local file="$1" out=""
  local stamp_re='^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?( [-+][0-9]{4})?$'
  # BSD stat first. GNU stat rejects these operands with a non-zero status, so
  # its unrelated stdout is replaced by the fallback assignment.
  out="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S %z' "$file" 2>/dev/null)" \
    || out="$(stat -c '%y' "$file" 2>/dev/null)" || out=""
  if [[ "$out" =~ $stamp_re ]]; then
    printf '%s%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
  fi
  return 0
}

_wce_runtime_update_lock_owner_is_aged() { # <lock-dir>
  local lock_dir="$1" aged=""
  # -mmin +N is "more than N minutes" on BSD, GNU, and BusyBox find. A symlink
  # is not followed and never matches -type f.
  aged="$(find "$lock_dir/owner" -prune -type f \
    -mmin "+$_WCE_RUNTIME_LOCK_STALE_MINUTES" -print 2>/dev/null)" || return 1
  [[ -n "$aged" ]]
}

# Classify one lock directory without modifying anything.
#
#   free     - nothing exists at the path
#   busy     - recognized owner token whose PID is running
#   stale    - recognized owner token whose PID does not exist
#   unusable - the lock path itself is a symlink or not a directory. No lock
#              is held; the recovery commands for a lock must not be offered
#              because `rm -f <lock>/owner` would resolve through a symlink
#   unknown  - everything else: a missing or non-regular owner, any entry
#              besides `owner`, an owner that is not exactly one LF-terminated
#              line of a recognized token, or a PID whose state cannot be
#              determined
#
# _WCE_LOCK_MUTEX records whether `<lock>.reclaim` exists. Acquisition backs
# off while it does, so a mutex left by a killed reclaimer blocks the lock
# even when nothing holds the canonical name.
#
# Recognized tokens are the two this kit writes: `<pid>:<uuid>` from
# update-deps.mjs and `starter-kit-update-<pid>-<random>-<epoch>` from setup.
_wce_runtime_update_lock_inspect_dir() { # <lock-dir>
  local lock_dir="$1" owner_file="$1/owner"
  local bytes="" raw="" shown="" rest="" pid=""
  local updater_re='^([1-9][0-9]{0,9}):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  local setup_re='^([1-9][0-9]{0,9})-[0-9]+-[0-9]+$'
  _WCE_LOCK_STATE=unknown
  _WCE_LOCK_OWNER=""
  _WCE_LOCK_OWNER_PID=""
  _WCE_LOCK_PID_STATE=""
  _WCE_LOCK_CREATED=""
  _WCE_LOCK_UNUSABLE=""
  _WCE_LOCK_MUTEX=false
  if [[ -e "${lock_dir}.reclaim" || -L "${lock_dir}.reclaim" ]]; then
    _WCE_LOCK_MUTEX=true
  fi

  if [[ ! -e "$lock_dir" && ! -L "$lock_dir" ]]; then
    _WCE_LOCK_STATE=free
    return 0
  fi
  if [[ ! -d "$lock_dir" || -L "$lock_dir" ]]; then
    _WCE_LOCK_STATE=unusable
    _WCE_LOCK_UNUSABLE="$lock_dir"
    return 0
  fi
  [[ -f "$owner_file" && ! -L "$owner_file" ]] || return 0

  _WCE_LOCK_CREATED="$(_wce_runtime_update_lock_owner_mtime "$owner_file")" \
    || _WCE_LOCK_CREATED=""
  # For display only: first line, bounded, restricted to a safe alphabet so a
  # foreign owner file cannot inject terminal control sequences.
  { IFS= read -r -n 64 shown < "$owner_file" || true; } 2>/dev/null
  _WCE_LOCK_OWNER="${shown//[^A-Za-z0-9._:@+=,-]/?}"

  _wce_runtime_update_lock_owner_only "$lock_dir" || return 0
  bytes="$(LC_ALL=C wc -c < "$owner_file" 2>/dev/null | tr -d '[:space:]')" \
    || return 0
  case "$bytes" in ""|*[!0123456789]*) return 0 ;; esac
  [[ "$bytes" -ge 2 && "$bytes" -le 128 ]] || return 0
  # `read` fails without the LF terminator; the byte count rejects a second
  # line, NUL bytes, and multibyte content.
  { IFS= read -r raw < "$owner_file"; } 2>/dev/null || return 0
  [[ "$bytes" == "$((${#raw} + 1))" ]] || return 0

  # Explicit character lists first: bracket ranges are locale-dependent.
  case "$raw" in
    starter-kit-update-*)
      rest="${raw#starter-kit-update-}"
      case "$rest" in *[!0123456789-]*) return 0 ;; esac
      [[ "$rest" =~ $setup_re ]] || return 0
      ;;
    *)
      case "$raw" in *[!0123456789abcdef:-]*) return 0 ;; esac
      [[ "$raw" =~ $updater_re ]] || return 0
      ;;
  esac
  pid="${BASH_REMATCH[1]}"

  _WCE_LOCK_OWNER="$raw"
  _WCE_LOCK_OWNER_PID="$pid"
  _WCE_LOCK_PID_STATE="$(_wce_runtime_update_lock_pid_state "$pid")" \
    || _WCE_LOCK_PID_STATE=unknown
  case "$_WCE_LOCK_PID_STATE" in
    alive) _WCE_LOCK_STATE=busy ;;
    dead) _WCE_LOCK_STATE=stale ;;
    *) _WCE_LOCK_PID_STATE=unknown ;;
  esac
  return 0
}

# Same classification for the canonical lock of a skill directory. The skill
# and logs directories must be real directories, exactly as acquisition
# requires; anything else is `unusable` so a symlink is never followed and
# no lock-removal command is offered for a lock that does not exist.
_wce_runtime_update_lock_inspect() { # <current-dir>
  local current_dir="$1" log_dir="$1/logs" ancestor
  for ancestor in "$current_dir" "$log_dir"; do
    if [[ -e "$ancestor" || -L "$ancestor" ]] \
      && [[ ! -d "$ancestor" || -L "$ancestor" ]]; then
      _WCE_LOCK_STATE=unusable
      _WCE_LOCK_OWNER=""
      _WCE_LOCK_OWNER_PID=""
      _WCE_LOCK_PID_STATE=""
      _WCE_LOCK_CREATED=""
      _WCE_LOCK_UNUSABLE="$ancestor"
      _WCE_LOCK_MUTEX=false
      return 0
    fi
  done
  _wce_runtime_update_lock_inspect_dir "$log_dir/.update.lock"
  return 0
}

# Recovery is refused wherever "the owner PID does not exist" is not evidence:
# MDM (which never takes this lock) and Git Bash (no shared PID space).
_wce_runtime_update_lock_reclaim_allowed() {
  _update_mdm_managed && return 1
  _wce_runtime_update_lock_pid_probe_unsupported && return 1
  return 0
}

# True when the lock inspected last meets every recovery condition that does
# not change by waiting: recognized owner, PID gone, old enough, allowed here.
# Read-only. The reclaim mutex is checked by the reclaimer itself.
_wce_runtime_update_lock_reclaim_eligible() { # <current-dir>
  [[ "$_WCE_LOCK_STATE" == stale ]] || return 1
  _wce_runtime_update_lock_reclaim_allowed || return 1
  _wce_runtime_update_lock_owner_is_aged "$1/logs/.update.lock"
}

# Put a quarantined lock directory back under the canonical name. `mv dir
# name` would move the directory *into* a lock that a writer created at that
# name in the meantime, so the name is claimed with an atomic mkdir first and
# the entries are moved one by one. Returns 1 and leaves the quarantine in
# place when the name is taken; the caller reports the path.
_wce_runtime_update_lock_restore_quarantine() { # <quarantine> <lock-dir>
  local quarantine="$1" lock_dir="$2" entry
  (umask 077; mkdir "$lock_dir") 2>/dev/null || return 1
  while IFS= read -r -d '' entry; do
    mv "$entry" "$lock_dir/" 2>/dev/null || return 1
  done < <(find "$quarantine" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  rmdir "$quarantine" 2>/dev/null || return 1
  return 0
}

# Runs with HUP/INT/TERM ignored (see the wrapper below). Every exit path after
# the mkdir releases the mutex; nothing here may abort early.
_wce_runtime_update_lock_reclaim_stale_locked() { # <current-dir> <observed-owner>
  local current_dir="$1" observed="$2"
  local lock_dir="$current_dir/logs/.update.lock"
  local mutex="${lock_dir}.reclaim"
  local quarantine="${lock_dir}.stale-$$-${RANDOM}"
  local rc=1

  # mkdir is atomic, so exactly one reclaimer proceeds. A mutex left behind by
  # a killed reclaimer is never removed here: recovery then stays manual.
  # Acquisition (bash and update-deps.mjs) fails when it finds this mutex
  # after writing its owner (withdrawing its lock once the mutex is gone, or
  # leaving it in place if the mutex outlasts its wait), so a writer that
  # completed an acquisition after this point is impossible; one that
  # completed before it is seen by the inspection below. A release
  # (_wce_runtime_update_lock_release) holds the same mutex from its owner
  # check through its rename, so it never renames while this runs.
  (umask 077; mkdir "$mutex") 2>/dev/null || return 1

  # Re-read everything under the mutex. The caller's observation may be old:
  # another reclaimer can have recovered that lock and a new writer acquired
  # the name since. Only the exact owner that was observed may be removed.
  _wce_runtime_update_lock_inspect "$current_dir"
  if [[ "$_WCE_LOCK_STATE" == stale && "$_WCE_LOCK_OWNER" == "$observed" ]] \
    && _wce_runtime_update_lock_owner_is_aged "$lock_dir" \
    && [[ ! -e "$quarantine" && ! -L "$quarantine" ]] \
    && mv "$lock_dir" "$quarantine" 2>/dev/null; then
    # rename(2) moved whichever inode held the name at that instant. Verify
    # the quarantined one before deleting anything.
    _wce_runtime_update_lock_inspect_dir "$quarantine"
    if [[ "$_WCE_LOCK_STATE" == stale && "$_WCE_LOCK_OWNER" == "$observed" ]] \
      && _wce_runtime_update_lock_owner_is_aged "$quarantine"; then
      if rm -f "$quarantine/owner" 2>/dev/null \
        && rmdir "$quarantine" 2>/dev/null; then
        rc=0
      fi
    elif ! _wce_runtime_update_lock_restore_quarantine \
        "$quarantine" "$lock_dir"; then
      # A different lock won the read-to-rename race and a third writer has
      # taken the canonical name since. Keep the quarantine for inspection.
      # Releasing the mutex below stays safe: a writer whose directory this
      # is may pass its mutex check afterwards, but acquisition (here and in
      # update-deps.mjs) then requires its token on the canonical path, which
      # the third writer holds, and fails.
      warn "${STR_WCE_LOCK_QUARANTINE_LEFT:-A lock that was moved aside during recovery could not be put back and was left for inspection:}" >&2
      info "    $quarantine" >&2
    fi
  fi
  rmdir "$mutex" 2>/dev/null || rc=1
  return "$rc"
}

# Remove a lock whose recognized owner no longer exists. Preflight only.
_wce_runtime_update_lock_reclaim_stale() { # <current-dir> <observed-owner>
  local current_dir="$1" observed="$2"
  local reclaim_pid="" reclaim_rc=0 wait_rc=0
  [[ -n "$observed" ]] || return 1
  _wce_runtime_update_lock_reclaim_allowed || return 1
  (
    trap '' HUP INT TERM
    _wce_runtime_update_lock_reclaim_stale_locked "$current_dir" "$observed" \
      || exit 1
    exit 0
  ) &
  reclaim_pid=$!
  # A trapped signal interrupts wait(1), not the signal-ignoring child.
  while true; do
    wait_rc=0
    wait "$reclaim_pid" 2>/dev/null || wait_rc=$?
    case "$wait_rc" in
      129|130|143) continue ;;
      *) reclaim_rc="$wait_rc"; break ;;
    esac
  done
  [[ "$reclaim_rc" -eq 0 ]]
}

# Path / owner / creation time / PID lines for the lock inspected last. stderr.
_wce_runtime_update_lock_print_details() { # <current-dir>
  local lock_dir="$1/logs/.update.lock" pid_label=""
  info "  ${STR_WCE_LOCK_LABEL_PATH:-Lock}: $lock_dir" >&2
  if [[ -n "$_WCE_LOCK_UNUSABLE" ]]; then
    info "  ${STR_WCE_LOCK_LABEL_UNUSABLE:-Not a directory}: $_WCE_LOCK_UNUSABLE" >&2
  fi
  if [[ -n "$_WCE_LOCK_OWNER" ]]; then
    info "  ${STR_WCE_LOCK_LABEL_OWNER:-Owner}: $_WCE_LOCK_OWNER" >&2
  fi
  if [[ -n "$_WCE_LOCK_CREATED" ]]; then
    info "  ${STR_WCE_LOCK_LABEL_CREATED:-Created}: $_WCE_LOCK_CREATED" >&2
  fi
  if [[ -n "$_WCE_LOCK_OWNER_PID" ]]; then
    case "$_WCE_LOCK_PID_STATE" in
      alive) pid_label="${STR_WCE_LOCK_PID_ALIVE:-running}" ;;
      dead) pid_label="${STR_WCE_LOCK_PID_DEAD:-not running}" ;;
      *) pid_label="${STR_WCE_LOCK_PID_UNKNOWN:-cannot be determined}" ;;
    esac
    info "  ${STR_WCE_LOCK_LABEL_PID:-Owner PID}: $_WCE_LOCK_OWNER_PID ($pid_label)" >&2
  fi
  return 0
}

# What to do about the lock inspected last, by state. stderr.
_wce_runtime_update_lock_print_recovery() { # <current-dir>
  local lock_dir="$1/logs/.update.lock"
  local mutex="${lock_dir}.reclaim"
  local quoted_owner="" quoted_lock="" quoted_mutex=""
  printf -v quoted_owner '%q' "$lock_dir/owner"
  printf -v quoted_lock '%q' "$lock_dir"
  printf -v quoted_mutex '%q' "$mutex"
  case "$_WCE_LOCK_STATE" in
    free)
      # Nothing to remove. Only the mutex hint below may apply.
      ;;
    unusable)
      # No lock is held: the path itself is a symlink or not a directory.
      # Removing "the lock" would act on whatever that path points to.
      info "${STR_WCE_LOCK_HINT_UNUSABLE:-Check what that path is and replace it with a regular directory (or remove it), then run the same command again. Do not remove anything through it.}" >&2
      ;;
    busy)
      info "${STR_WCE_LOCK_HINT_BUSY:-Wait for it to finish, then run the same command again. Only if that PID is not update-deps.mjs, setup.sh, or npm (a PID can be reused), remove the lock:}" >&2
      info "    rm -f $quoted_owner && rmdir $quoted_lock" >&2
      ;;
    stale)
      info "${STR_WCE_LOCK_HINT_STALE:-setup.sh recovers it automatically once it is 60 minutes old. To recover now, confirm that PID is not running, then run:}" >&2
      info "    rm -f $quoted_owner && rmdir $quoted_lock" >&2
      ;;
    *)
      info "${STR_WCE_LOCK_HINT_UNKNOWN:-Confirm that no update-deps.mjs, setup.sh, or npm ci process is running, then remove the lock and run the same command again:}" >&2
      info "    rm -f $quoted_owner && rmdir $quoted_lock" >&2
      ;;
  esac
  if [[ -e "$mutex" || -L "$mutex" ]]; then
    info "${STR_WCE_LOCK_HINT_MUTEX:-An interrupted recovery left a marker that disables automatic recovery. After the same check, remove it too:}" >&2
    info "    rmdir $quoted_mutex" >&2
  fi
  return 0
}

# Explain an exit 75 (could not acquire) or 74 (could not release) from the
# lock inspected last. stderr.
_wce_runtime_update_lock_report_last() { # <current-dir> <74|75>
  local current_dir="$1" code="${2:-75}"
  if [[ "$code" == 74 ]]; then
    error "${STR_WCE_LOCK_RELEASE_FAILED:-The web-content-extraction dependency lock could not be released cleanly (exit 74).}"
  else
    case "$_WCE_LOCK_STATE" in
      busy)
        error "${STR_WCE_LOCK_BUSY:-Another web-content-extraction dependency update or kit setup is still running, so this run stopped (exit 75).}"
        ;;
      stale)
        error "${STR_WCE_LOCK_STALE:-A web-content-extraction dependency lock was left behind by a process that is no longer running, so this run stopped (exit 75).}"
        ;;
      free)
        if [[ "$_WCE_LOCK_MUTEX" == true ]]; then
          error "${STR_WCE_LOCK_MUTEX_BLOCKED:-The web-content-extraction dependency lock could not be acquired because a marker from an interrupted recovery exists, so this run stopped (exit 75).}"
        else
          error "${STR_WCE_LOCK_UNAVAILABLE:-The web-content-extraction dependency lock could not be acquired, so this run stopped (exit 75). Nothing holds it right now: run the same command again, and if this repeats, check that its parent is a writable directory.}"
        fi
        ;;
      unusable)
        error "${STR_WCE_LOCK_UNUSABLE:-The web-content-extraction dependency lock path cannot be used because it is a symlink or not a directory, so this run stopped (exit 75). No lock is held.}"
        ;;
      *)
        error "${STR_WCE_LOCK_UNKNOWN:-The web-content-extraction dependency lock is held in a form the kit cannot verify, so it was left untouched and this run stopped (exit 75).}"
        ;;
    esac
  fi
  _wce_runtime_update_lock_print_details "$current_dir"
  _wce_runtime_update_lock_print_recovery "$current_dir"
  # The caller's note describes what an acquisition failure left undone. A
  # release failure (74) comes after the callback finished, so it gets the
  # caller's release note instead: setup stops on a 74 before its remaining
  # steps (manifest, saved config, plugins) just as on a 75.
  if [[ "$code" == 74 ]]; then
    if [[ -n "${_WCE_RUNTIME_LOCK_RELEASE_NOTE:-}" ]]; then
      warn "$_WCE_RUNTIME_LOCK_RELEASE_NOTE"
    fi
  elif [[ -n "${_WCE_RUNTIME_LOCK_FAILURE_NOTE:-}" ]]; then
    warn "$_WCE_RUNTIME_LOCK_FAILURE_NOTE"
  fi
  return 0
}

_wce_runtime_update_lock_report() { # <current-dir> <74|75>
  _wce_runtime_update_lock_inspect "$1"
  _wce_runtime_update_lock_report_last "$1" "${2:-75}"
  return 0
}

# Settle the lock before the caller writes anything.
#
#   free                     -> 0
#   busy                     -> wait up to _WCE_RUNTIME_LOCK_WAIT_SECONDS (60)
#   stale, old, recoverable  -> remove it under the reclaim mutex, then 0
#   anything else            -> diagnosis on stderr, 75
#
# A writer can still take the lock between this check and the caller's own
# acquisition; that later failure is diagnosed by the lock helper itself.
_wce_runtime_update_lock_preflight() { # <current-dir>
  local current_dir="$1"
  local wait_limit="${_WCE_RUNTIME_LOCK_WAIT_SECONDS:-60}"
  local waited=0 relooks=0 changes=0 announced=false seen=""
  case "$wait_limit" in ""|*[!0123456789]*) wait_limit=60 ;; esac
  while true; do
    _wce_runtime_update_lock_inspect "$current_dir"
    seen="$_WCE_LOCK_STATE|$_WCE_LOCK_OWNER|$_WCE_LOCK_MUTEX"
    case "$_WCE_LOCK_STATE" in
      free)
        [[ "$_WCE_LOCK_MUTEX" == true ]] || return 0
        # A reclaimer that is finishing holds the mutex for a moment after
        # the lock is gone. Acquisition backs off while it exists, so a mutex
        # that stays is reported rather than passed through to a later 75.
        if [[ "$relooks" -lt 2 && "$waited" -lt "$wait_limit" ]]; then
          relooks=$((relooks + 1))
          sleep 1
          waited=$((waited + 1))
          continue
        fi
        ;;
      unusable)
        # A symlink or non-directory does not go away by waiting.
        ;;
      busy)
        if [[ "$waited" -lt "$wait_limit" ]]; then
          if [[ "$announced" != true ]]; then
            announced=true
            info "${STR_WCE_LOCK_WAITING:-Waiting for a running web-content-extraction dependency update or kit setup to finish} (PID $_WCE_LOCK_OWNER_PID)..."
          fi
          sleep 1
          waited=$((waited + 1))
          continue
        fi
        ;;
      stale)
        if _wce_runtime_update_lock_reclaim_eligible "$current_dir"; then
          if _wce_runtime_update_lock_reclaim_stale \
            "$current_dir" "$_WCE_LOCK_OWNER"; then
            warn "${STR_WCE_LOCK_RECOVERED:-Recovered a web-content-extraction dependency lock left behind by a process that is no longer running.}"
            _wce_runtime_update_lock_print_details "$current_dir"
            return 0
          fi
          # A concurrent reclaimer holds the mutex for a moment and then
          # frees the lock; losing to it is not a failure. Look again before
          # giving up. A mutex that is still there afterwards was left by a
          # killed reclaimer and is reported.
          if [[ "$relooks" -lt 2 && "$waited" -lt "$wait_limit" ]]; then
            relooks=$((relooks + 1))
            sleep 1
            waited=$((waited + 1))
            continue
          fi
        fi
        ;;
      *)
        # Acquisition is mkdir followed by the owner write, so a writer that
        # is acquiring right now looks ownerless for an instant. Look again
        # before calling the lock unverifiable.
        if [[ "$relooks" -lt 2 && "$waited" -lt "$wait_limit" ]]; then
          relooks=$((relooks + 1))
          sleep 1
          waited=$((waited + 1))
          continue
        fi
        ;;
    esac
    # Every branch above falls through to here to give up. Do that only for a
    # lock that is still the one this pass evaluated: a concurrent reclaimer
    # or writer can remove or replace it between the look at the top and the
    # checks that followed (the age probe then fails on a path that is gone).
    _wce_runtime_update_lock_inspect "$current_dir"
    if [[ "$_WCE_LOCK_STATE" == free && "$_WCE_LOCK_MUTEX" != true ]]; then
      return 0
    fi
    if [[ "$_WCE_LOCK_STATE|$_WCE_LOCK_OWNER|$_WCE_LOCK_MUTEX" != "$seen" \
      && "$changes" -lt 5 ]]; then
      changes=$((changes + 1))
      continue
    fi
    _wce_runtime_update_lock_report_last "$current_dir" 75
    warn "${STR_WCE_LOCK_UNTOUCHED_NOTE:-No starter-kit file was changed by this run.}"
    return 75
  done
}

# Dry-run simulates in a temp dir that has no lock, so the real one is checked
# here, read-only. Warns only; the dry-run exit status is unchanged.
_wce_runtime_update_lock_dryrun_notice() { # <real-claude-dir>
  local current_dir="$1/skills/web-content-extraction"
  local mutex="$current_dir/logs/.update.lock.reclaim"
  _update_mdm_managed && return 0
  _wce_runtime_update_lock_inspect "$current_dir"
  if [[ "$_WCE_LOCK_STATE" == free && "$_WCE_LOCK_MUTEX" != true ]]; then
    return 0
  fi
  if _wce_runtime_update_lock_reclaim_eligible "$current_dir" \
    && [[ ! -e "$mutex" && ! -L "$mutex" ]]; then
    warn "${STR_WCE_LOCK_DRYRUN_RECOVERABLE:-A web-content-extraction dependency lock was left behind by a process that is no longer running. The real run recovers it automatically before updating.}"
    _wce_runtime_update_lock_print_details "$current_dir"
  else
    warn "${STR_WCE_LOCK_DRYRUN_BLOCKED:-The web-content-extraction dependency lock is held. The real run waits up to 60 seconds for a running owner and otherwise stops (exit 75) before changing any file.}"
    _wce_runtime_update_lock_print_details "$current_dir"
    _wce_runtime_update_lock_print_recovery "$current_dir"
  fi
  return 0
}

_wce_runtime_update_lock_acquire() { # <current-dir> <token-output-var>
  local current_dir="$1" output_var="$2"
  local current_parent current_grandparent
  local log_dir="$current_dir/logs"
  local lock_file="$log_dir/.update.lock"
  local generated_token now acquire_pid acquire_rc=0 wait_rc=0
  local withdraw_waited=0
  now="$(date +%s)" || return 1
  # Record the process that holds the lock, not the top-level shell ($$).
  # _wce_with_runtime_update_lock calls this from the subshell that runs the
  # writer callback, and that subshell outlives a parent killed on its own
  # (SIGKILL to setup.sh only). With $$ such a live writer would look
  # abandoned and become reclaimable.
  generated_token="starter-kit-update-${BASHPID}-${RANDOM}-$now"

  _WCE_RUNTIME_ACQUIRE_WAITER_PID="$BASHPID"
  (
    trap '' HUP INT TERM
    : "$_WCE_RUNTIME_ACQUIRE_WAITER_PID"
    if [[ -e "$current_dir" || -L "$current_dir" ]]; then
      [[ -d "$current_dir" && ! -L "$current_dir" ]] || exit 1
    else
      current_parent="$(dirname "$current_dir")" || exit 1
      if [[ -e "$current_parent" || -L "$current_parent" ]]; then
        [[ -d "$current_parent" && ! -L "$current_parent" ]] || exit 1
      else
        current_grandparent="$(dirname "$current_parent")" || exit 1
        [[ -d "$current_grandparent" && ! -L "$current_grandparent" ]] \
          || exit 1
        mkdir "$current_parent" || exit 1
      fi
      mkdir "$current_dir" || exit 1
    fi

    if [[ -e "$log_dir" || -L "$log_dir" ]]; then
      [[ -d "$log_dir" && ! -L "$log_dir" ]] || exit 1
    else
      mkdir "$log_dir" || exit 1
    fi

    # mkdir is atomic and never opens an existing FIFO, symlink, or device.
    # Acquisition itself never takes over an existing lock, whatever its age
    # or owner. The only recovery path is the pre-write preflight
    # (_wce_runtime_update_lock_preflight): recognized owner token, PID
    # provably gone, owner file old enough, all rechecked under a mutex.
    (umask 077; mkdir "$lock_file") 2>/dev/null || exit 1
    # noclobber, like the 'wx' flag in update-deps.mjs: between the mkdir and
    # this write a reclaimer can move this directory aside and another writer
    # can take the canonical name. A plain > would truncate that writer's
    # owner and replace it with this token, and both would hold the lock.
    if ! (umask 077; set -C; printf '%s\n' "$generated_token" \
        > "$lock_file/owner") 2>/dev/null; then
      rmdir "$lock_file" 2>/dev/null || true
      exit 1
    fi
    # The preflight reclaims an abandoned lock under `<lock>.reclaim`. It
    # re-reads the lock after taking that mutex, so a lock whose owner was
    # written before the mutex appeared is seen and left alone. A lock
    # completed after the mutex appeared would not be, so withdraw it: this
    # check runs after the owner write, which makes one of the two orderings
    # certain. The withdrawal is best effort because the reclaimer may have
    # moved this directory aside already; it then puts it back (busy) or
    # keeps it for inspection, and this run stops with a diagnosis either way.
    # Withdraw through the token-checked release: by now the recovery may
    # have finished and another writer may hold the canonical name, and that
    # writer's lock must not be removed.
    # Wait for the reclaimer to finish first. The release checks the owner
    # and then renames; while the reclaimer is active it can move this lock
    # aside between those two steps, and after it releases the mutex another
    # writer can take the canonical name, which the rename would then move.
    # Once the mutex is gone nothing else renames this live, fresh lock. A
    # mutex that outlasts the wait does not prove the reclaimer dead (it may
    # only be stalled), so the same race stays open: leave this lock in place
    # and fail. Its owner names this subshell, so once that exits the lock is
    # a recognized abandoned lock that the preflight diagnoses or recovers.
    if [[ -e "${lock_file}.reclaim" || -L "${lock_file}.reclaim" ]]; then
      withdraw_waited=0
      while [[ -e "${lock_file}.reclaim" || -L "${lock_file}.reclaim" ]] \
        && [[ "$withdraw_waited" -lt "${_WCE_RUNTIME_LOCK_WITHDRAW_WAIT_SECONDS:-3}" ]]; do
        sleep 1
        withdraw_waited=$((withdraw_waited + 1))
      done
      if [[ -e "${lock_file}.reclaim" || -L "${lock_file}.reclaim" ]]; then
        exit 1
      fi
      _wce_runtime_update_lock_release "$current_dir" "$generated_token" \
        >/dev/null 2>&1 || true
      exit 1
    fi
  ) &
  acquire_pid=$!
  while true; do
    wait_rc=0
    wait "$acquire_pid" 2>/dev/null || wait_rc=$?
    case "$wait_rc" in
      129|130|143) continue ;;
      *) acquire_rc="$wait_rc"; break ;;
    esac
  done
  if [[ "$acquire_rc" -ne 0 ]]; then
    # Existing/partial foreign state is never cleanup authority. The child
    # removes only a directory it created when its own owner write fails.
    return 1
  fi
  # Revalidate the child result before publishing the bearer token. This runs
  # after the child's mutex check, so it also catches a recovery that moved
  # the lock aside and finished between the owner write and that check.
  _wce_runtime_update_lock_owner_matches \
    "$current_dir" "$generated_token" || return 1
  _wce_runtime_update_lock_owner_only "$lock_file" || return 1
  printf -v "$output_var" '%s' "$generated_token"
  return 0
}

# Release under the reclaim mutex. The owner check and the rename below are
# two steps, and the release runs in a child of the lock holder whose PID is
# in the token. If only the holder is killed while the child is stalled
# between those steps, the lock is stale; a reclaimer could remove it, writer
# A take the name, the resumed rename move A's lock, and writer B take the
# freed name, leaving A and B both running. The reclaimer only acts under
# this mutex, so holding it from the check through the rename closes that.
# A mutex that outlasts the wait may belong to a stalled reclaimer: fail and
# rename nothing. An acquirer that writes its owner while this is held
# withdraws (it treats the mutex as a reclaimer), which is safe.
_wce_runtime_update_lock_release() { # <current-dir> <token>
  local current_dir="$1" token="$2"
  local mutex="$current_dir/logs/.update.lock.reclaim"
  local waited=0 rc=0
  case "$token" in ""|*[!A-Za-z0-9._-]*) return 1 ;; esac
  until (umask 077; mkdir "$mutex") 2>/dev/null; do
    # mkdir failed for a reason other than an existing mutex (missing or
    # unwritable logs directory): nothing to wait for.
    [[ -e "$mutex" || -L "$mutex" ]] || return 1
    [[ "$waited" -lt "${_WCE_RUNTIME_LOCK_WITHDRAW_WAIT_SECONDS:-3}" ]] \
      || return 1
    sleep 1
    waited=$((waited + 1))
  done
  _wce_runtime_update_lock_release_locked "$current_dir" "$token" || rc=1
  rmdir "$mutex" 2>/dev/null || rc=1
  return "$rc"
}

_wce_runtime_update_lock_release_locked() { # <current-dir> <token>
  local current_dir="$1" token="$2"
  local lock_file="$current_dir/logs/.update.lock"
  local quarantine="${lock_file}.release-${token}"
  case "$token" in ""|*[!A-Za-z0-9._-]*) return 1 ;; esac

  if [[ -e "$quarantine" || -L "$quarantine" ]]; then
    _wce_runtime_update_lock_owner_matches \
      "$current_dir" "$token" "$quarantine" || return 1
    _wce_runtime_update_lock_owner_only "$quarantine" || return 1
  else
    _wce_runtime_update_lock_owner_matches \
      "$current_dir" "$token" "$lock_file" || return 1
    _wce_runtime_update_lock_owner_only "$lock_file" || return 1
    mv "$lock_file" "$quarantine" || return 1
  fi

  if ! _wce_runtime_update_lock_owner_matches \
      "$current_dir" "$token" "$quarantine" \
    || ! _wce_runtime_update_lock_owner_only "$quarantine"; then
    # The inode renamed into quarantine was replaced after our first check.
    # Put that foreign directory back unless a successor owns the canonical
    # name; then retain both paths for manual inspection.
    _wce_runtime_update_lock_restore_quarantine "$quarantine" "$lock_file" \
      || true
    return 1
  fi
  if ! rm -f "$quarantine/owner"; then
    [[ ! -e "$quarantine/owner" && ! -L "$quarantine/owner" ]] || return 1
  fi
  rmdir "$quarantine" || return 1
  return 0
}

_wce_with_runtime_update_lock() { # <current-dir> <callback> [args...]
  local current_dir="$1"
  local requested_physical=""
  shift
  if [[ -n "${_WCE_RUNTIME_LOCK_TOKEN:-}" ]] \
    && [[ "${_WCE_RUNTIME_LOCK_HOLDER_PID:-}" == "$BASHPID" ]] \
    && requested_physical="$(cd -P "$current_dir" 2>/dev/null && pwd -P)" \
    && [[ "$requested_physical" == "${_WCE_RUNTIME_LOCK_DIR:-}" ]] \
    && _wce_runtime_update_lock_owner_matches \
      "$current_dir" "$_WCE_RUNTIME_LOCK_TOKEN"; then
    "$@"
    return $?
  fi
  (
    local runtime_lock_token="" cleanup_pending_signal=0 acquire_rc=0
    _wce_runtime_lock_signal() {
      cleanup_pending_signal="$1"
      exit "$1"
    }
    _wce_runtime_lock_defer_signal() {
      cleanup_pending_signal="$1"
    }
    _wce_runtime_lock_cleanup() {
      local cleanup_rc=$? release_rc=0 release_pid="" wait_rc=0
      trap - EXIT
      # Do not exit in the ownership-check/unlink critical section. Record the
      # signal and return its conventional status after release completes.
      trap '_wce_runtime_lock_defer_signal 129' HUP
      trap '_wce_runtime_lock_defer_signal 130' INT
      trap '_wce_runtime_lock_defer_signal 143' TERM
      if [[ -n "$runtime_lock_token" ]]; then
        _WCE_RUNTIME_RELEASE_WAITER_PID="$BASHPID"
        (
          trap '' HUP INT TERM
          : "$_WCE_RUNTIME_RELEASE_WAITER_PID"
          _wce_runtime_update_lock_release \
            "$current_dir" "$runtime_lock_token"
        ) &
        release_pid=$!
        # A trapped signal interrupts wait(1), not the signal-ignoring child.
        # Repeat wait until it yields the child's real (non-signal) result.
        while true; do
          wait_rc=0
          wait "$release_pid" 2>/dev/null || wait_rc=$?
          case "$wait_rc" in
            129|130|143) continue ;;
            *) release_rc="$wait_rc"; break ;;
          esac
        done
        if [[ "$release_rc" -ne 0 ]]; then
          release_rc=74
          _wce_runtime_update_lock_report "$current_dir" 74 || true
        fi
      fi
      trap - HUP INT TERM
      [[ "$cleanup_pending_signal" -eq 0 ]] || cleanup_rc="$cleanup_pending_signal"
      if [[ "$release_rc" -ne 0 && "$cleanup_rc" -eq 0 ]]; then
        cleanup_rc="$release_rc"
      fi
      exit "$cleanup_rc"
    }
    trap '_wce_runtime_lock_cleanup' EXIT
    # Acquisition also mutates lock state. Defer exit while its
    # signal-ignoring child completes, then release if a signal was pending.
    trap '_wce_runtime_lock_defer_signal 129' HUP
    trap '_wce_runtime_lock_defer_signal 130' INT
    trap '_wce_runtime_lock_defer_signal 143' TERM
    _wce_runtime_update_lock_acquire "$current_dir" runtime_lock_token \
      || acquire_rc=$?
    if [[ "$acquire_rc" -ne 0 ]]; then
      [[ "$cleanup_pending_signal" -eq 0 ]] || exit "$cleanup_pending_signal"
      # Callers invoke this helper as a simple command under errexit, so the
      # exit below ends the whole run. Say why here; nobody else can.
      _wce_runtime_update_lock_report "$current_dir" 75 || true
      exit 75
    fi
    _WCE_RUNTIME_LOCK_TOKEN="$runtime_lock_token"
    _WCE_RUNTIME_LOCK_HOLDER_PID="$BASHPID"
    _WCE_RUNTIME_LOCK_DIR="$(cd -P "$current_dir" && pwd -P)" || exit 74
    [[ "$cleanup_pending_signal" -eq 0 ]] || exit "$cleanup_pending_signal"
    trap '_wce_runtime_lock_signal 129' HUP
    trap '_wce_runtime_lock_signal 130' INT
    trap '_wce_runtime_lock_signal 143' TERM
    "$@"
  )
}

_update_auto_managed_wce_package_pair_locked() { # <current-dir> <snapshot-dir> <newkit-dir>
  local current_dir="$1" snapshot_dir="$2" newkit_dir="$3"
  local current_package="$current_dir/package.json"
  local current_lock="$current_dir/package-lock.json"
  local snapshot_package="$snapshot_dir/package.json"
  local snapshot_lock="$snapshot_dir/package-lock.json"
  local newkit_package="$newkit_dir/package.json"
  local newkit_lock="$newkit_dir/package-lock.json"
  local current_valid=false snapshot_valid=false reset_to_kit=false
  local compare_rc=0 package_stage lock_stage package_backup="" lock_backup=""
  local package_had=false lock_had=false txn_rc=0
  local kit_changed=true

  _wce_package_pair_is_valid "$newkit_package" "$newkit_lock" || return 2

  if [[ -f "$current_package" && ! -L "$current_package" \
    && -f "$current_lock" && ! -L "$current_lock" ]] \
    && _wce_package_pair_is_valid "$current_package" "$current_lock"; then
    current_valid=true
  elif [[ -e "$current_package" || -L "$current_package" \
    || -e "$current_lock" || -L "$current_lock" ]]; then
    # A partially missing or malformed pair is auto-managed and recoverable,
    # but a non-regular leaf must not be traversed or overwritten implicitly.
    [[ ! -e "$current_package" || -f "$current_package" ]] || return 2
    [[ ! -L "$current_package" ]] || return 2
    [[ ! -e "$current_lock" || -f "$current_lock" ]] || return 2
    [[ ! -L "$current_lock" ]] || return 2
  fi

  if [[ -f "$snapshot_package" && ! -L "$snapshot_package" \
    && -f "$snapshot_lock" && ! -L "$snapshot_lock" ]] \
    && _wce_package_pair_is_valid "$snapshot_package" "$snapshot_lock"; then
    snapshot_valid=true
  fi

  if [[ "$snapshot_valid" == true && "$current_valid" == true ]] \
    && ! _file_changed "$snapshot_package" "$newkit_package" \
    && ! _file_changed "$snapshot_lock" "$newkit_lock"; then
    kit_changed=false
  fi

  if [[ "$current_valid" != true || "$snapshot_valid" != true ]]; then
    reset_to_kit=true
  elif [[ "$kit_changed" != true ]]; then
    compare_rc=0
    _wce_package_dependency_keys_equal \
      "$current_package" "$newkit_package" || compare_rc=$?
    case "$compare_rc" in
      0) ;;
      1) reset_to_kit=true ;;
      *) return 2 ;;
    esac
    compare_rc=0
    _wce_package_dependency_keys_equal \
      "$current_lock" "$newkit_lock" || compare_rc=$?
    case "$compare_rc" in
      0) ;;
      1) reset_to_kit=true ;;
      *) return 2 ;;
    esac
  else
    if [[ "${_SNAPSHOT_BOOTSTRAPPED:-false}" != "true" ]]; then
      compare_rc=0
      _wce_package_pair_runtime_state_equal \
        "$snapshot_package" "$snapshot_lock" \
        "$current_package" "$current_lock" || compare_rc=$?
      case "$compare_rc" in
        0) reset_to_kit=true ;;
        1) ;;
        *) return 2 ;;
      esac
    fi
    if [[ "$reset_to_kit" != true ]]; then
      local -a compare_paths=(
        "$snapshot_package" "$newkit_package"
        "$snapshot_lock" "$newkit_lock"
        "$current_package" "$newkit_package"
        "$current_lock" "$newkit_lock"
      )
      local compare_index
      for ((compare_index = 0; compare_index < ${#compare_paths[@]}; compare_index += 2)); do
        compare_rc=0
        _wce_package_dependency_keys_equal \
          "${compare_paths[$compare_index]}" \
          "${compare_paths[$((compare_index + 1))]}" || compare_rc=$?
        case "$compare_rc" in
          0) ;;
          1) reset_to_kit=true ;;
          *) return 2 ;;
        esac
      done
    fi
  fi

  if [[ "$current_valid" == true ]] \
    && cmp -s "$current_package" "$newkit_package" \
    && cmp -s "$current_lock" "$newkit_lock"; then
    # A missing/invalid/old baseline still needs phase 5 to snapshot the kit
    # pair. Report a managed refresh (without rewriting current) in that case.
    [[ "$snapshot_valid" == true && "$kit_changed" == false ]] \
      && return 1
    return 0
  fi

  package_stage="$(mktemp "${current_package}.stage.XXXXXX")" || return 2
  lock_stage="$(mktemp "${current_lock}.stage.XXXXXX")" \
    || { rm -f "$package_stage"; return 2; }
  _SETUP_TMP_FILES+=("$package_stage" "$lock_stage")
  _wce_render_auto_managed_package_file \
    "$current_package" "$newkit_package" "$reset_to_kit" "$package_stage" \
    || { rm -f "$package_stage" "$lock_stage"; return 2; }
  _wce_render_auto_managed_package_file \
    "$current_lock" "$newkit_lock" "$reset_to_kit" "$lock_stage" \
    || { rm -f "$package_stage" "$lock_stage"; return 2; }
  _wce_package_pair_is_valid "$package_stage" "$lock_stage" \
    || { rm -f "$package_stage" "$lock_stage"; return 2; }

  # Rendering applies kit-owned metadata while preserving only runtime-owned
  # versions/lock graph. If that exact desired pair is already installed, it
  # is a true no-op; otherwise metadata drift must be committed even when the
  # kit's dependency key set did not change.
  if [[ "$current_valid" == true ]] \
    && cmp -s "$package_stage" "$current_package" \
    && cmp -s "$lock_stage" "$current_lock"; then
    rm -f "$package_stage" "$lock_stage" || return 2
    # No live rewrite is needed, but a stale/missing baseline must still be
    # refreshed by phase 5 so a later runtime update is not misclassified.
    [[ "$snapshot_valid" == true && "$kit_changed" == false ]] && return 1
    return 0
  fi

  if [[ -f "$current_package" && ! -L "$current_package" ]]; then
    package_backup="$(mktemp "${current_package}.backup.XXXXXX")" \
      || { rm -f "$package_stage" "$lock_stage"; return 2; }
    cp -p "$current_package" "$package_backup" \
      || { rm -f "$package_stage" "$lock_stage" "$package_backup"; return 2; }
    package_had=true
  fi
  if [[ -f "$current_lock" && ! -L "$current_lock" ]]; then
    lock_backup="$(mktemp "${current_lock}.backup.XXXXXX")" \
      || { rm -f "$package_stage" "$lock_stage" "$package_backup"; return 2; }
    cp -p "$current_lock" "$lock_backup" \
      || { rm -f "$package_stage" "$lock_stage" "$package_backup" "$lock_backup"; return 2; }
    lock_had=true
  fi

  (
    _wce_package_replace_started=false
    _wce_lock_replace_started=false
    _wce_pair_committed=false
    _wce_pair_rollback() {
      local _rollback_rc=$?
      if [[ "$_wce_pair_committed" != true ]]; then
        if [[ "$_wce_lock_replace_started" == true ]]; then
          if [[ "$lock_had" == true ]]; then
            if _wce_package_pair_mv "$lock_backup" "$current_lock"; then
              lock_backup=""
            else
              _rollback_rc=1
            fi
          else
            rm -f "$current_lock" || _rollback_rc=1
          fi
        elif [[ -n "$lock_backup" ]]; then
          rm -f "$lock_backup" || _rollback_rc=1
          lock_backup=""
        fi
        if [[ "$_wce_package_replace_started" == true ]]; then
          if [[ "$package_had" == true ]]; then
            if _wce_package_pair_mv "$package_backup" "$current_package"; then
              package_backup=""
            else
              _rollback_rc=1
            fi
          else
            rm -f "$current_package" || _rollback_rc=1
          fi
        elif [[ -n "$package_backup" ]]; then
          rm -f "$package_backup" || _rollback_rc=1
          package_backup=""
        fi
      else
        rm -f ${package_backup:+"$package_backup"} \
          ${lock_backup:+"$lock_backup"} || _rollback_rc=1
        package_backup=""
        lock_backup=""
      fi
      rm -f "$package_stage" "$lock_stage" 2>/dev/null || _rollback_rc=1
      return "$_rollback_rc"
    }
    trap '_wce_pair_rollback' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Mark an attempted replacement before mv. A signal delivered after mv
    # returns but before the next shell statement must still restore the pair.
    _wce_package_replace_started=true
    _wce_package_pair_mv "$package_stage" "$current_package" || exit 1
    _wce_lock_replace_started=true
    _wce_package_pair_mv "$lock_stage" "$current_lock" || exit 1
    _wce_pair_committed=true
  ) || txn_rc=$?
  case "$txn_rc" in
    0) ;;
    129|130|143) return "$txn_rc" ;;
    *) return 2 ;;
  esac
  return 0
}

_update_auto_managed_wce_package_pair() { # <current-dir> <snapshot-dir> <newkit-dir>
  local current_dir="$1" snapshot_dir="$2" newkit_dir="$3"
  local update_rc=0

  # update-deps.mjs uses this exact lock for its mutate/test cycle: its
  # registry check runs without the lock, and it re-reads the installed
  # versions after acquiring. Hold it across validation, rendering, and both
  # renames so neither writer can derive output from a moving package/lock
  # pair. The subshell boundary preserves caller traps while guaranteeing
  # signal-time release.
  _wce_with_runtime_update_lock "$current_dir" \
    _update_auto_managed_wce_package_pair_locked \
    "$current_dir" "$snapshot_dir" "$newkit_dir" || update_rc=$?
  case "$update_rc" in
    74|75) return 2 ;;
    *) return "$update_rc" ;;
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
  local total=0 _file source_list
  source_list="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$source_list")
  _find_update_content_files "$src_dir" > "$source_list" \
    || { rm -f "$source_list"; return 1; }
  while IFS= read -r -d '' _file; do
    total=$((total + 1))
  done < "$source_list"
  rm -f "$source_list" || return 1
  printf '%s' "$total" || return 1
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

  # These JSON files are executable dependency inputs. Never copy malformed
  # kit bytes through a generic no-user-change or fresh-file branch.
  if _is_auto_managed_web_content_package "$current"; then
    _wce_package_file_is_valid "$newkit" || return 2
  fi

  # MDM mode treats every distributed path as kit-owned desired state. Files
  # outside the distribution are not visited and remain user-owned.
  if _update_mdm_managed; then
    _mdm_atomic_replace_managed_file "$newkit" "$current" || return 1
    return 0
  fi

  # New file from kit (not in snapshot)
  if [[ ! -f "$snapshot" ]]; then
    cp -a "$newkit" "$current" || return 2
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
        cp -a "$newkit" "$current" || return 2
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
        _merge_auto_managed_web_content_package \
          "$current" "$snapshot" "$newkit" \
          || return 2
        return 0
      fi
      if [[ "$kit_owned" != "true" ]]; then
        if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]]; then
          return 1
        fi
      else
        cp -a "$newkit" "$current" || return 2
        return 0
      fi
      _prompt_file_action "$current" "$snapshot" "$newkit"
      case "$_FILE_ACTION" in
        append)
          printf "\n# --- Updated by Claude Code Starter Kit ---\n" >> "$current" || return 2
          cat "$newkit" >> "$current" || return 2
          return 0
          ;;
        skip|*)
          return 1
          ;;
      esac
    fi
    cp -a "$newkit" "$current" || return 2
    return 0
  fi

  # No kit change → keep current
  if ! _file_changed "$snapshot" "$newkit"; then
    return 1
  fi

  # Both changed → ask user
  if _is_auto_managed_web_content_package "$current"; then
    _merge_auto_managed_web_content_package \
      "$current" "$snapshot" "$newkit" \
      || return 2
    return 0
  fi
  _prompt_file_action "$current" "$snapshot" "$newkit"
  case "$_FILE_ACTION" in
    append)
      # Append new kit content after current content with separator
      printf "\n# --- Updated by Claude Code Starter Kit ---\n" >> "$current" || return 2
      cat "$newkit" >> "$current" || return 2
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
    mkdir -p "$dest_dir" || return 1
  fi

  local src_file source_list
  source_list="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$source_list")
  _find_update_content_files "$src_dir" > "$source_list" \
    || { rm -f "$source_list"; return 1; }
  while IFS= read -r -d '' src_file; do
    local basename_file
    basename_file="$(basename "$src_file")"
    local dest_file="${dest_dir}/${basename_file}"
    local snap_file="${snap_dir}/${basename_file}"

    local update_rc=0
    if _update_file "$dest_file" "$snap_file" "$src_file" "true"; then
      if ! chmod +x "$dest_file" 2>/dev/null; then
        rm -f "$source_list" 2>/dev/null || true
        return 1
      fi
      _UPDATE_UPDATED_FILES+=("$dest_file")
    else
      update_rc=$?
      if _update_mdm_managed || [[ "$update_rc" -gt 1 ]]; then
        rm -f "$source_list" 2>/dev/null || true
        return 1
      fi
      _UPDATE_SKIPPED_FILES+=("hooks/${feature_name}/${basename_file}")
    fi
  done < "$source_list"
  rm -f "$source_list" || return 1
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

  local feature_name src_dir
  for feature_name in "${_FEATURE_SCRIPT_ORDER[@]}"; do
    [[ "${_FEATURE_HAS_SCRIPTS[$feature_name]+set}" ]] || continue
    _feature_deploy_enabled "$feature_name" || continue
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
  [[ -f "$settings_file" ]] || return 1
  is_true "${ENABLE_STATUSLINE:-false}" || return 0

  local current_cmd
  current_cmd="$(jq -r '.statusLine.command // empty' \
    "$settings_file" 2>/dev/null)" || return 1
  [[ "$current_cmd" == *statusline-command.sh* ]] || return 0

  local fragment="$PROJECT_DIR/features/statusline/hooks.json"
  [[ -f "$fragment" ]] || return 1
  local new_status
  new_status="$(jq -c '.statusLine // empty' "$fragment" 2>/dev/null)" \
    || return 1
  [[ -n "$new_status" ]] || return 0

  local tmp
  tmp="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$tmp")
  if jq --argjson sl "$new_status" '.statusLine = $sl' "$settings_file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$settings_file" || return 1
    replace_home_path "$settings_file" || return 1
    ok "Migrated statusLine to the current kit implementation"
  else
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

# Hook features the kit no longer ships. Their settings.json entries must be
# stripped during update even when the user customized "hooks" (merge keeps
# user-touched values, which would leave commands pointing at deleted scripts).
_RETIRED_HOOK_FEATURES=(memory-persistence strategic-compact console-log-guard git-push-review)

# _strip_retired_hook_entries - Remove hook commands referencing retired
# feature script dirs (~/.claude/hooks/<feature>/) from settings.json, then
# drop matchers/events left empty. Match the actual HOME (or the unexpanded
# kit token) exactly so an unrelated /tmp/.claude tree is never removed.
_strip_retired_hook_entries() {
  local settings_file="$1"
  [[ -f "$settings_file" ]] || return 1
  local feature tmp probe_rc changed=false
  for feature in "${_RETIRED_HOOK_FEATURES[@]}"; do
    probe_rc=0
    jq -e --arg p "$HOME/.claude/hooks/${feature}/" \
      --arg token "__HOME__/.claude/hooks/${feature}/" '
      def retired: type == "string" and
        (startswith($p) or startswith($token));
      [(.hooks // {}) | to_entries[] | .value[]?.hooks[]? | (.command // "")]
      | any(retired)
    ' "$settings_file" >/dev/null 2>&1 || probe_rc=$?
    case "$probe_rc" in
      0) ;;
      1) continue ;;
      *) return 1 ;;
    esac
    tmp="$(mktemp)" || return 1
    _SETUP_TMP_FILES+=("$tmp")
    if jq --arg p "$HOME/.claude/hooks/${feature}/" \
      --arg token "__HOME__/.claude/hooks/${feature}/" '
      def retired: type == "string" and
        (startswith($p) or startswith($token));
      if .hooks then
        .hooks |= (to_entries
          | map(.value |= (map((.hooks //= []) | .hooks |= map(select((.command // "") | retired | not)))
                           | map(select((.hooks | length) > 0))))
          | map(select((.value | length) > 0))
          | from_entries)
      else . end
    ' "$settings_file" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$settings_file" || return 1
      changed=true
    else
      rm -f "$tmp" 2>/dev/null || true
      warn "Could not strip retired ${feature} hook entries from settings.json (unexpected hooks structure)"
      return 1
    fi
  done

  # These features are still shipped, but their former inline commands were
  # replaced by managed wrapper scripts. A user-touched hooks array can make
  # the 3-way merge retain both generations, causing the old and new hooks to
  # run together. Remove only the exact legacy safety-net command and the
  # kit-owned legacy WCE updater path; unrelated user commands are preserved.
  probe_rc=0
  jq -e --arg home "$HOME" '
    def superseded_inline:
      type == "string" and
      (. == "cc-safety-net --claude-code" or
       . == "node __HOME__/.claude/skills/web-content-extraction/scripts/update-deps.mjs" or
       . == ("node " + $home + "/.claude/skills/web-content-extraction/scripts/update-deps.mjs"));
    [(.hooks // {}) | to_entries[] | .value[]?.hooks[]? | (.command // "")]
    | any(superseded_inline)
  ' "$settings_file" >/dev/null 2>&1 || probe_rc=$?
  case "$probe_rc" in
    0)
      tmp="$(mktemp)" || return 1
      _SETUP_TMP_FILES+=("$tmp")
      if jq --arg home "$HOME" '
        def superseded_inline:
          type == "string" and
          (. == "cc-safety-net --claude-code" or
           . == "node __HOME__/.claude/skills/web-content-extraction/scripts/update-deps.mjs" or
           . == ("node " + $home + "/.claude/skills/web-content-extraction/scripts/update-deps.mjs"));
        if .hooks then
          .hooks |= (to_entries
            | map(.value |= (map((.hooks //= [])
                                 | .hooks |= map(select((.command // "")
                                                       | superseded_inline
                                                       | not)))
                             | map(select((.hooks | length) > 0))))
            | map(select((.value | length) > 0))
            | from_entries)
        else . end
      ' "$settings_file" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$settings_file" || return 1
        changed=true
      else
        rm -f "$tmp" 2>/dev/null || true
        warn "Could not strip superseded inline hook entries from settings.json"
        return 1
      fi
      ;;
    1) ;;
    *) return 1 ;;
  esac
  if [[ "$changed" == "true" ]]; then
    ok "Removed retired or superseded hook entries from settings.json"
  fi
}

# ---------------------------------------------------------------------------
# _strip_superseded_kit_hook_generations - Drop stale generations of kit hooks
#
# Usage: _strip_superseded_kit_hook_generations <settings-file> <kit-built-file>
#
# A hooks array that carries BOTH the kit's current entry and an older kit
# generation of it (same command set, different matcher/async/etc — the
# pre-identity-merge failure mode, #163) runs the same hook twice. The 3-way
# merge only executes when snapshot, current and new kit all differ, so an
# already-duplicated array would otherwise persist until the kit next edits
# that very array. This sweep runs on every update, after the merge, against
# the freshly built kit settings.
#
# An entry is dropped ONLY when all three hold: it differs from every kit
# entry, its command set matches a kit entry's, and that kit entry is itself
# present in the array. A kit entry the user edited IN PLACE (kit's exact
# version absent) is left alone — removing it would deregister the hook.
# User hooks with their own commands never match a kit identity.
# ---------------------------------------------------------------------------
_strip_superseded_kit_hook_generations() {
  local settings_file="$1"
  local kit_file="$2"
  [[ -f "$settings_file" ]] || return 1
  [[ -f "$kit_file" ]] || return 0
  local filter='
    def ident: if type == "object" and ((.hooks? | type) == "array")
               then [.hooks[]?.command?] else null end;
    def stale($K; $L):
      . as $e |
      (($K | any(. == $e)) | not) and
      (($e | ident) != null) and
      ($K | any(ident == ($e | ident))) and
      ([$K[] | select(ident == ($e | ident))] | any(. as $k | $L | any(. == $k)));
    ($kit[0].hooks // {}) as $KH'
  local probe_rc=0
  jq -e --slurpfile kit "$kit_file" "$filter"' |
    any((.hooks // {}) | to_entries[];
        ($KH[.key] // []) as $K | .value as $L |
        ($L | type) == "array" and any($L[]; stale($K; $L)))
  ' "$settings_file" >/dev/null 2>&1 || probe_rc=$?
  case "$probe_rc" in
    0) ;;
    1) return 0 ;;
    *) return 0 ;;  # unreadable kit build or settings — nothing safe to do
  esac
  local tmp
  tmp="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$tmp")
  if jq --slurpfile kit "$kit_file" "$filter"' |
    if .hooks then
      .hooks |= (to_entries
        | map(($KH[.key] // []) as $K
              | .value as $L
              | .value |= (if type == "array"
                           then map(select(stale($K; $L) | not))
                           else . end))
        | from_entries)
    else . end
  ' "$settings_file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$settings_file" || return 1
    ok "Removed superseded kit hook generations from settings.json"
  else
    rm -f "$tmp" 2>/dev/null || true
    warn "Could not strip superseded kit hook generations from settings.json"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# _migrate_legacy_hook_entries - Rewrite hook entries generated for
# Claude Code < 2.1.89
#
# Usage: _migrate_legacy_hook_entries <settings-file> <kit-built-file>
#
# Until v0.78.x the kit generated a second shape of the auto-update and
# pr-creation-log hooks for Claude Code < 2.1.89 (hooks.legacy.json, retired
# in v0.79.0, #136). Those commands carry an env prefix, so they are a
# different identity from the current entries: a user-touched hooks array
# keeps the legacy hook NEXT TO the kit's current one (non-interactive 3-way
# merge treats it as "removed by the kit" and keeps it), and a bootstrap merge
# keeps it INSTEAD of the current one. Neither _merge_arrays_3way nor
# _strip_superseded_kit_hook_generations can pair them. The current scripts
# ignore the prefix, so a leftover auto-update entry (no `async`) would check
# for updates on every session start without the former 24h throttle.
#
# Per hooks array, for each of the two exact commands the kit itself wrote:
#   - the current command is already registered there -> the legacy hook is
#     removed;
#   - otherwise the first legacy hook is replaced in place by the kit's
#     current hook object for that script (removed when the freshly built kit
#     settings do not ship it, e.g. the feature is disabled) and any further
#     copy is removed.
# An entry left without hooks is dropped, and so is an array left empty. Only
# the legacy hooks are touched: other hooks, other entries and their order stay
# as they are, and a file without a legacy hook is not rewritten at all.
# Matching is exact against this $HOME (same premise as
# _strip_retired_hook_entries); a hand-edited variant is left alone.
# ---------------------------------------------------------------------------
_migrate_legacy_hook_entries() {
  local settings_file="$1"
  local kit_file="$2"
  [[ -f "$settings_file" ]] || return 1
  [[ -f "$kit_file" ]] || return 0
  local filter='
    def current_command:
      if type != "string" then null
      elif . == ("AUTO_UPDATE_LEGACY=1 AUTO_UPDATE_HOOK=SessionStart " + $home
                 + "/.claude/hooks/auto-update/auto-update.sh")
        then "AUTO_UPDATE_HOOK=SessionStart " + $home
             + "/.claude/hooks/auto-update/auto-update.sh"
      elif . == ("PR_CREATION_LOG_LEGACY=1 " + $home
                 + "/.claude/hooks/pr-creation-log/log-pr.sh")
        then $home + "/.claude/hooks/pr-creation-log/log-pr.sh"
      else null end;
    def cmd: if type == "object" then .command else null end;
    def inner: if type == "object" and (.hooks | type) == "array"
               then .hooks else [] end;
    def has_legacy: any(.[]; any(inner[]; (cmd | current_command) != null));
    def migrate($K):
      . as $L
      | [$L[] | inner[] | cmd | strings] as $registered
      | reduce $L[] as $entry ({out: [], done: []};
          if [$entry] | has_legacy then
            (reduce $entry.hooks[] as $hook ({hooks: [], done: .done};
               ($hook | cmd | current_command) as $now
               | if $now == null then .hooks += [$hook]
                 elif any(($registered + .done)[]; . == $now) then .
                 else ([$K[]? | inner[] | select(cmd == $now)] | first) as $kit_hook
                   | if $kit_hook == null then .
                     else .hooks += [$kit_hook] | .done += [$now] end
                 end)) as $result
            | .done = $result.done
            | if ($result.hooks | length) > 0
              then .out += [$entry | .hooks = $result.hooks] else . end
          else .out += [$entry] end)
      | .out;
    ($kit[0].hooks // {}) as $KH'
  local probe_rc=0
  jq -e --arg home "$HOME" --slurpfile kit "$kit_file" "$filter"' |
    any((.hooks // {}) | to_entries[] | .value;
        type == "array" and has_legacy)
  ' "$settings_file" >/dev/null 2>&1 || probe_rc=$?
  case "$probe_rc" in
    0) ;;
    1) return 0 ;;
    *) return 0 ;;  # unreadable kit build or settings — nothing safe to do
  esac
  local tmp
  tmp="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$tmp")
  if jq --arg home "$HOME" --slurpfile kit "$kit_file" "$filter"' |
    .hooks |= with_entries(
      ($KH[.key] // []) as $K
      | if (.value | type) == "array" and (.value | has_legacy)
        then .value |= migrate($K) | select((.value | length) > 0)
        else . end)
  ' "$settings_file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$settings_file" || return 1
    ok "Migrated hook entries generated for Claude Code < 2.1.89 to the current kit hooks"
  else
    rm -f "$tmp" 2>/dev/null || true
    warn "Could not migrate legacy hook entries in settings.json"
    return 1
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

  # In MDM mode, the target-user manifest is never deletion authority. The
  # privileged launcher supplies a root-authenticated prior inventory, and the
  # reconciler combines only that inventory with the pinned checkout universe.
  # This path must therefore work even when the user manifest is missing or
  # malformed.
  if _update_mdm_managed; then
    _mdm_reconcile_absent_managed_files "$claude_dir" "$snapshot_dir" || return 1
    return 0
  fi

  [[ -f "$manifest" ]] || return 0
  _mdm_reconcile_absent_managed_files "$claude_dir" "$snapshot_dir" || return 1
  jq -e '
    ((.files // []) | type == "array")
    and all((.files // [])[]; type == "string")
    and ((.claude_dir // "") | type == "string")
  ' "$manifest" >/dev/null 2>&1 || return 1

  # Retired = the CURRENT KIT no longer ships the path. Compare against the
  # full kit enumeration, NOT the on-disk-filtered managed_files_json():
  # a kit-shipped file the user deleted must keep its snapshot baseline so
  # _update_file's restore/skip protection keeps working on later updates.
  collect_managed_target_files || return 1
  local kit_rel_json
  kit_rel_json="$({
    local kit_file
    for kit_file in "${_MANAGED_TARGET_FILES[@]+"${_MANAGED_TARGET_FILES[@]}"}"; do
      printf '%s\n' "${kit_file#"$claude_dir"/}"
    done
    true
  } | jq -R -s 'split("\n")[:-1]')" || return 1

  # Manifest entries are absolute paths recorded at install time. Under
  # --dry-run, claude_dir points at the sim dir while the copied manifest
  # still holds real-home paths, so resolve relative paths against every
  # known root before giving up.
  local manifest_root
  manifest_root="$(jq -r '.claude_dir // empty' "$manifest" 2>/dev/null)" || return 1

  local old_file rel_file target baseline baseline_trusted manifest_entries
  manifest_entries="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$manifest_entries")
  jq -r '.files[]? // empty' "$manifest" > "$manifest_entries" 2>/dev/null \
    || { rm -f "$manifest_entries"; return 1; }
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
    # Feed the inventory through a normal pipeline. Bash 5.3 implements a
    # here-string with a pipe and may fill a small pipe before jq is started.
    if printf '%s\n' "$kit_rel_json" \
      | jq -e --arg file "$rel_file" 'index($file) != null' >/dev/null 2>&1; then
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
      rm -f "$target" || return 1
      rm -f "$baseline" || return 1
      ok "Removed retired managed file: $rel_file"
      _prune_empty_dirs "$(dirname "$target")" "$claude_dir"
      _prune_empty_dirs "$(dirname "$baseline")" "$snapshot_dir"
    else
      # Already absent on disk — drop only the stale baseline.
      if [[ "$baseline_trusted" == "true" ]]; then
        rm -f "$baseline" || return 1
        _prune_empty_dirs "$(dirname "$baseline")" "$snapshot_dir"
      fi
    fi
  done < "$manifest_entries"
  rm -f "$manifest_entries" || return 1
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
  local total=0 dir_count
  local dir
  for dir in agents rules commands skills; do
    local src_dir="${PROJECT_DIR}/${dir}"
    local flag_var
    flag_var="INSTALL_$(printf '%s' "$dir" | tr '[:lower:]' '[:upper:]')"
    [[ -d "$src_dir" ]] || continue
    is_true "${!flag_var:-false}" || continue
    dir_count="$(_count_update_files_in_dir "$src_dir")" || return 1
    [[ "$dir_count" =~ ^[0-9]+$ ]] || return 1
    total=$((total + dir_count))
  done
  printf '%s' "$total" || return 1
}

_count_update_hook_files() {
  local total=0 feature_count
  local feature_name src_dir
  for feature_name in "${_FEATURE_SCRIPT_ORDER[@]}"; do
    [[ "${_FEATURE_HAS_SCRIPTS[$feature_name]+set}" ]] || continue
    _feature_deploy_enabled "$feature_name" || continue
    src_dir="$PROJECT_DIR/features/${feature_name}/scripts"
    [[ -d "$src_dir" ]] || continue
    feature_count="$(_count_update_files_in_dir "$src_dir")" || return 1
    [[ "$feature_count" =~ ^[0-9]+$ ]] || return 1
    total=$((total + feature_count))
  done
  printf '%s' "$total" || return 1
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
  new_settings="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$new_settings")
  build_settings_file "$new_settings" || return 1
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
      _merge_settings_bootstrap "$current_settings" "$new_settings" "$current_settings" || return 1
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
        cp -a "$new_settings" "$current_settings" || return 1
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
      merge_settings_3way "$snapshot_settings" "$current_settings" "$new_settings" "$current_settings" || return 1
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
      cp -a "$new_settings" "$current_settings" || return 1
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
  _sync_settings_metadata "$current_settings" || return 1

  # Bootstrap merges keep existing sub-key values, so a manifest-v1 install
  # can come out of Phase 1 still pointing statusLine at the retired bash
  # implementation. Rewrite it to the current kit fragment.
  _migrate_statusline_command "$current_settings" || return 1

  # User-touched "hooks" survive the merge with kit-removed entries intact,
  # which would leave commands pointing at scripts the retired-file sweep
  # deletes. Strip them explicitly.
  _strip_retired_hook_entries "$current_settings" || return 1

  # Hook entries generated for Claude Code < 2.1.89 (retired in v0.79.0, #136)
  # carry a different command, so neither the merge above nor the sweep below
  # can pair them with the kit's current entry. Rewrite them first; the sweep
  # then sees only current commands.
  _migrate_legacy_hook_entries "$current_settings" "$new_settings" || return 1

  # Heal arrays that already carry a stale kit hook generation next to the
  # kit's current entry (#163). The 3-way merge above only runs when snapshot,
  # current and new kit all differ, so without this sweep an already-duplicated
  # array persists until the kit next edits that very array.
  _strip_superseded_kit_hook_generations "$current_settings" "$new_settings" || return 1
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
  new_claude_md="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$new_claude_md")
  build_claude_md_to_file "$new_claude_md" || return 1

  local current_claude_md="${claude_dir}/CLAUDE.md"
  local snapshot_claude_md="${snapshot_dir}/CLAUDE.md"

  local _updated=false _baseline_only=false
  if _update_mdm_managed; then
    # MDM always converges CLAUDE.md to desired state. Keep this call out of
    # an `if` condition so errexit remains active throughout its call tree.
    _update_claude_md "$current_claude_md" "$snapshot_claude_md" "$new_claude_md"
    _updated=true
  else
    local update_rc=0
    if _update_claude_md "$current_claude_md" "$snapshot_claude_md" "$new_claude_md"; then
      _updated=true
    else
      update_rc=$?
      case "$update_rc" in
        1) ;;
        # Content already current, snapshot behind: refresh the baseline only.
        # Listing the file as updated is what drives the snapshot phase.
        3) _updated=true; _baseline_only=true ;;
        *) return 1 ;;
      esac
    fi
  fi

  if [[ "$_updated" == "true" ]]; then
    _UPDATE_ALL_UPDATED_FILES+=("$current_claude_md")
    if [[ "$_baseline_only" == "true" ]]; then
      info "${STR_CLAUDEMD_KIT_BASELINE_REFRESHED:-CLAUDE.md kit section already matches this version; snapshot refreshed}"
    elif [[ "$_dr" == "true" ]]; then
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
    rm -f "$legacy_agents_md" || return 1
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
  _content_total="$(_count_update_content_files)" || return 1
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
      mkdir -p "$dest_dir" || return 1
    fi

    local src_file source_list wce_pair_processed=false
    source_list="$(mktemp)" || return 1
    _SETUP_TMP_FILES+=("$source_list")
    _find_update_content_files "$src_dir" > "$source_list" \
      || { rm -f "$source_list"; return 1; }
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
        _mdm_ensure_real_distribution_dir "$(dirname "$dest_file")" \
          || { rm -f "$source_list"; return 1; }
      else
        mkdir -p "$(dirname "$dest_file")" \
          || { rm -f "$source_list"; return 1; }
      fi

      # package.json and package-lock.json form one npm contract. The runtime
      # updater may change their versions, but a kit update must validate and
      # commit both together so an error cannot leave a mismatched pair.
      if ! _update_mdm_managed && [[ "$dir" == skills ]] \
        && [[ "$rel_file" == web-content-extraction/package.json \
          || "$rel_file" == web-content-extraction/package-lock.json ]]; then
        if [[ "$wce_pair_processed" != true ]]; then
          local wce_pair_rc=0
          if _update_auto_managed_wce_package_pair \
            "$dest_dir/web-content-extraction" \
            "$snap_dir/web-content-extraction" \
            "$src_dir/web-content-extraction"; then
            _UPDATE_ALL_UPDATED_FILES+=(
              "$dest_dir/web-content-extraction/package.json"
              "$dest_dir/web-content-extraction/package-lock.json"
            )
          else
            wce_pair_rc=$?
            case "$wce_pair_rc" in
              1) ;; # Desired auto-managed pair already present: true no-op.
              129|130|143)
                rm -f "$source_list" 2>/dev/null || true
                return "$wce_pair_rc"
                ;;
              *)
                rm -f "$source_list" 2>/dev/null || true
                return 1
                ;;
            esac
          fi
          wce_pair_processed=true
        fi
        continue
      fi

      local update_rc=0
      if _update_file "$dest_file" "$snap_file" "$src_file"; then
        _UPDATE_ALL_UPDATED_FILES+=("$dest_file")
      else
        update_rc=$?
        if _update_mdm_managed || [[ "$update_rc" -gt 1 ]]; then
          rm -f "$source_list" 2>/dev/null || true
          return 1
        fi
        _UPDATE_ALL_SKIPPED_FILES+=("${dir}/${rel_file}")
      fi
    done < "$source_list"
    rm -f "$source_list" || return 1
  done
}

# --- Phase 4/5: Hook scripts (update-aware) ------------------------------------
_update_phase_hooks() {
  local claude_dir="$1"
  local snapshot_dir="$2"

  _progress_step 4 5 "Hook scripts"
  local _hook_total=0
  _hook_total="$(_count_update_hook_files)" || return 1
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
      _snapshot_claude_md "$claude_dir" "$file" || return 1
    elif [[ "$_basename" == "settings.json" ]]; then
      # Snapshot the kit-generated version, not the merge result
      local _snap_dest="${snapshot_dir}/settings.json"
      if _update_mdm_managed; then
        _mdm_atomic_replace_managed_file \
          "$_UPDATE_NEW_SETTINGS_FILE" "$_snap_dest" || return 1
      else
        mkdir -p "$snapshot_dir" || return 1
        cp "$_UPDATE_NEW_SETTINGS_FILE" "$_snap_dest" || return 1
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
          mkdir -p "$(dirname "${snapshot_dir}/${_wc_rel}")" || return 1
          cp -a "${PROJECT_DIR}/${_wc_rel}" "${snapshot_dir}/${_wc_rel}" || return 1
        fi
      fi
    else
      _update_snapshot_file "$claude_dir" "$file" || return 1
    fi
  done
  if _update_mdm_managed; then
    # MDM compliance attests deterministic owner-only modes. Normalize the
    # complete enabled managed set, including files whose content was already
    # current and therefore did not otherwise need a snapshot refresh.
    collect_managed_target_files || return 1
    local _managed _snapshot_file
    for _managed in "${_MANAGED_TARGET_FILES[@]+"${_MANAGED_TARGET_FILES[@]}"}"; do
      [[ -f "$_managed" ]] || continue
      _normalize_mdm_managed_modes "$_managed" || return 1
      _snapshot_file="$snapshot_dir/${_managed#"$claude_dir"/}"
      _normalize_mdm_managed_modes "$_snapshot_file" || return 1
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

_update_tail_with_wce_lock() { # <project-dir> <claude-dir> <snapshot-dir>
  local project_dir="$1" claude_dir="$2" snapshot_dir="$3"
  _update_phase_content "$project_dir" "$claude_dir" "$snapshot_dir"
  _update_phase_hooks "$claude_dir" "$snapshot_dir"
  _update_phase_snapshot "$claude_dir" "$snapshot_dir"
  _update_report "$claude_dir"
}

_update_requires_wce_lock() { # <project-dir> <claude-dir> <snapshot-dir>
  local project_dir="$1" claude_dir="$2" snapshot_dir="$3"
  _update_mdm_managed && return 1
  if is_true "${INSTALL_SKILLS:-false}" \
    && [[ -d "$project_dir/skills/web-content-extraction" ]]; then
    return 0
  fi
  [[ -e "$claude_dir/skills/web-content-extraction" \
    || -L "$claude_dir/skills/web-content-extraction" \
    || -e "$snapshot_dir/skills/web-content-extraction" \
    || -L "$snapshot_dir/skills/web-content-extraction" ]]
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
    rm -f "$_MERGE_PREFS_FILE" || return 1
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
  if _update_requires_wce_lock "$project_dir" "$claude_dir" "$snapshot_dir"; then
    # This is the transaction boundary shared with update-deps.mjs (its apply
    # phase) and fresh deployment: every WCE source update, retired-file
    # removal, and baseline refresh completes under one token-bound lock. A
    # contending writer fails before any live or snapshot WCE byte is read or
    # changed. setup_deploy already settled the lock before the backup, so
    # contention here means a writer started in the last few seconds; the
    # helper reports it and appends this note about the two finished steps.
    local _WCE_RUNTIME_LOCK_FAILURE_NOTE="${STR_WCE_LOCK_PARTIAL_NOTE:-settings.json and CLAUDE.md were already processed by this run; the remaining kit files were not. Resolve the lock and run the same command again to apply the rest.}"
    local _WCE_RUNTIME_LOCK_RELEASE_NOTE="${STR_WCE_LOCK_RELEASE_NOTE:-This run stopped before its remaining steps, including the install manifest, saving the settings, and plugin setup. Resolve the lock and run the same command again.}"
    _wce_with_runtime_update_lock \
      "$claude_dir/skills/web-content-extraction" \
      _update_tail_with_wce_lock "$project_dir" "$claude_dir" "$snapshot_dir"
  else
    _update_tail_with_wce_lock "$project_dir" "$claude_dir" "$snapshot_dir"
  fi
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
  local hook_state_known=true
  local hook_issue=false

  # `.hooks.<Event>[]?.hooks[]?.command | contains(...)` emits one output per
  # registered hook, and `jq -e` derives its exit code from the LAST output
  # only. Any hook registered after auto-update therefore reported "not
  # registered" for a perfectly healthy install. `any(GEN; COND)` collapses the
  # stream to a single boolean, and the `type == "string"` guard keeps an entry
  # without a string `command` from aborting the filter — an abort is exit 5,
  # which is indistinguishable from "absent" once the status is discarded.
  # Same shape as _strip_retired_hook_entries above.
  local probe_rc
  probe_rc=0
  jq -e 'any(.hooks.SessionStart[]?.hooks[]?.command?;
             type == "string" and contains("auto-update"))' \
    "$settings" >/dev/null 2>&1 || probe_rc=$?
  case "$probe_rc" in
    0) has_session_start=true ;;
    1) ;;
    *) hook_state_known=false ;;
  esac

  probe_rc=0
  jq -e 'any(.hooks.SessionEnd[]?.hooks[]?.command?;
             type == "string" and contains("auto-update"))' \
    "$settings" >/dev/null 2>&1 || probe_rc=$?
  case "$probe_rc" in
    0) has_session_end=true ;;
    1) ;;
    *) hook_state_known=false ;;
  esac

  # Check 1: hook registered. Anything other than a clean true/false answer
  # (jq missing, settings.json unreadable or invalid) means the state was never
  # determined, so report nothing rather than guess. The previous fallback
  # answered both questions from one file-wide `grep -q auto-update` and so
  # called a half-registered pair healthy — the opposite error, equally wrong.
  if [[ "$hook_state_known" == "true" ]]; then
    if [[ "$has_session_start" != "true" ]]; then
      hook_issue=true
    elif [[ "$has_session_end" != "true" ]]; then
      hook_issue=true
    fi
  fi
  if [[ "$hook_issue" == "true" ]]; then
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
    if [[ "$hook_issue" == "true" ]]; then
      info "${STR_AUTOUPDATE_HINT_HOOK:-To enable: re-run setup.sh and select auto-update in hooks, or use standard/full profile}"
    fi
    if [[ ! -d "${kit_dir}/.git" ]]; then
      info "${STR_AUTOUPDATE_HINT_REPO:-To enable: git clone https://github.com/cloudnative-co/claude-code-starter-kit.git ~/.claude-starter-kit}"
    fi
  elif [[ "$hook_state_known" == "true" ]]; then
    ok "${STR_AUTOUPDATE_OK:-Auto-update is active}"
  fi
}
