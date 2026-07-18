#!/bin/bash
# lib/deploy.sh - Build + deploy functions extracted from setup.sh
#
# Dependencies (must be sourced before this file):
#   lib/colors.sh       (ok, warn, info, error, section)
#   lib/features.sh     (_FEATURE_FLAGS, _FEATURE_ORDER, _FEATURE_HAS_SCRIPTS)
#   lib/template.sh     (_has_kit_markers, _extract_kit_section, etc.)
#   lib/json-builder.sh (build_settings_json, merge_deep, replace_home_path)
#   lib/snapshot.sh     (_write_snapshot, _snapshot_claude_md, _snapshot_exists)
#   lib/merge.sh        (_merge_settings_bootstrap)
#   lib/dryrun.sh       (_dryrun_init, etc.)
#
# Globals expected from setup.sh:
#   CLAUDE_DIR, PROJECT_DIR, DRY_RUN, _SETUP_TMP_FILES[], _FRESH_SKIPPED_FILES[]
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
is_true() {
  local v
  v="$(printf '%s' "${1:-}" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  case "$v" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

_deploy_mdm_managed() {
  case "$(printf '%s' "${KIT_MDM_MANAGED:-}" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
    true|1|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

_deploy_outer_transaction_active() {
  [[ "${KIT_MDM_OUTER_TRANSACTION:-}" == true ]] \
    && _deploy_mdm_managed
}

_deploy_validate_outer_transaction_carrier() {
  case "${KIT_MDM_OUTER_TRANSACTION:-}" in
    '') [[ -z "${KIT_MDM_OUTER_TRANSACTION_BACKUP:-}" ]] ;;
    true)
      _deploy_mdm_managed || return 1
      if [[ -n "${KIT_MDM_OUTER_TRANSACTION_BACKUP:-}" ]]; then
        [[ "$KIT_MDM_OUTER_TRANSACTION_BACKUP" \
          == "$HOME"/.claude.mdm-backup.* \
          && -d "$KIT_MDM_OUTER_TRANSACTION_BACKUP" \
          && ! -L "$KIT_MDM_OUTER_TRANSACTION_BACKUP" ]]
      fi ;;
    *) return 1 ;;
  esac
}

# language_code - returns the code Claude Code expects in settings.json
language_code() {
  case "${LANGUAGE:-en}" in
    ja) printf "ja" ;;
    *)  printf "en" ;;
  esac
}

_bool_to_string() {
  if is_true "${1:-false}"; then
    printf "true"
  else
    printf "false"
  fi
}

_version_ge() {
  local lhs="${1:-0}"
  local rhs="${2:-0}"
  local lhs_a lhs_b lhs_c rhs_a rhs_b rhs_c _

  IFS='.' read -r lhs_a lhs_b lhs_c _ <<< "$lhs"
  IFS='.' read -r rhs_a rhs_b rhs_c _ <<< "$rhs"
  lhs_a="${lhs_a:-0}"; lhs_b="${lhs_b:-0}"; lhs_c="${lhs_c:-0}"
  rhs_a="${rhs_a:-0}"; rhs_b="${rhs_b:-0}"; rhs_c="${rhs_c:-0}"

  (( lhs_a > rhs_a )) && return 0
  (( lhs_a < rhs_a )) && return 1
  (( lhs_b > rhs_b )) && return 0
  (( lhs_b < rhs_b )) && return 1
  (( lhs_c >= rhs_c ))
}

_CLAUDE_SEMVER_CACHE="${_CLAUDE_SEMVER_CACHE-}"
_CLAUDE_SEMVER_CACHE_SET="${_CLAUDE_SEMVER_CACHE_SET:-false}"

_claude_cli_semver() {
  local raw version
  command -v claude &>/dev/null || return 1
  if [[ "$_CLAUDE_SEMVER_CACHE_SET" == "true" ]]; then
    [[ -n "$_CLAUDE_SEMVER_CACHE" ]] || return 1
    printf '%s\n' "$_CLAUDE_SEMVER_CACHE"
    return 0
  fi
  _CLAUDE_SEMVER_CACHE_SET=true
  raw="$(claude --version 2>/dev/null | head -1)"
  if ! [[ "$raw" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    _CLAUDE_SEMVER_CACHE=""
    return 1
  fi
  version="${BASH_REMATCH[1]}"
  _CLAUDE_SEMVER_CACHE="$version"
  printf '%s\n' "$version"
}

_claude_supports_async_hooks() {
  local min_version="${1:-2.1.89}"
  local current_version=""

  # The privileged MDM launcher pins this internal decision before running
  # setup so both deployment and independent postcondition rendering use the
  # same hook schema. It is deliberately not a public MDM config key.
  if _deploy_mdm_managed; then
    case "${KIT_MDM_ASYNC_HOOKS:-}" in
      true) return 0 ;;
      false) return 1 ;;
    esac
  fi

  # Fail open when Claude is absent so generated config stays forward-looking
  # during offline tests or first install. Fail closed when a present CLI has an
  # unparsable version because we cannot prove async hook support.
  if ! command -v claude &>/dev/null; then
    return 0
  fi

  current_version="$(_claude_cli_semver 2>/dev/null || true)"
  [[ -n "$current_version" ]] || return 1
  _version_ge "$current_version" "$min_version"
}

_versioned_hooks_fragment() {
  local feature="$1"
  local src="$PROJECT_DIR/features/${feature}/hooks.json"
  local legacy_src="$PROJECT_DIR/features/${feature}/hooks.legacy.json"

  if _claude_supports_async_hooks "2.1.89"; then
    printf '%s\n' "$src"
  else
    printf '%s\n' "$legacy_src"
  fi
}

_auto_update_hooks_fragment() {
  _versioned_hooks_fragment "auto-update"
}

_pr_creation_log_hooks_fragment() {
  _versioned_hooks_fragment "pr-creation-log"
}

apply_settings_preferences() {
  local file="$1"
  local lang_name tmp_file attribution_enabled
  lang_name="$(language_code)"
  if is_true "${COMMIT_ATTRIBUTION:-false}"; then
    attribution_enabled="true"
  else
    attribution_enabled="false"
  fi

  tmp_file="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$tmp_file")

  jq \
    --arg lang "$lang_name" \
    --arg new_init "$(_bool_to_string "${ENABLE_NEW_INIT:-false}")" \
    --argjson attribution_enabled "$attribution_enabled" \
    '.language = $lang
    | .env.CLAUDE_CODE_NEW_INIT = $new_init
    | if $attribution_enabled then del(.attribution) else .attribution = {commit: "", pr: ""} end' \
    "$file" > "$tmp_file" || return 1

  mv "$tmp_file" "$file" || return 1
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
_BACKUP_TIMESTAMP=""
_BACKUP_PATH=""

_wce_scrub_fresh_lock_from_backup() { # <backup-dir>
  local backup="$1"
  [[ "${_WCE_FRESH_LOCK_BACKUP_SCRUB:-false}" == true ]] || return 0
  [[ -n "${_WCE_RUNTIME_LOCK_TOKEN:-}" \
    && "${_WCE_RUNTIME_LOCK_HOLDER_PID:-}" == "$BASHPID" ]] || return 1

  local backup_skills="$backup/skills"
  local backup_skill="$backup_skills/web-content-extraction"
  local backup_logs="$backup_skill/logs"
  _wce_runtime_update_lock_owner_matches \
    "$backup_skill" "$_WCE_RUNTIME_LOCK_TOKEN" || return 1
  _wce_runtime_update_lock_release \
    "$backup_skill" "$_WCE_RUNTIME_LOCK_TOKEN" || return 1

  # Lock acquisition may have created missing ancestors before backup_existing
  # ran. Remove only those newly-created, now-empty directories so the recovery
  # copy remains byte-for-byte equivalent to the pre-transaction tree.
  if [[ "${_WCE_FRESH_LOGS_PREEXISTED:-true}" != true ]]; then
    rmdir "$backup_logs" || return 1
  fi
  if [[ "${_WCE_FRESH_SKILL_PREEXISTED:-true}" != true ]]; then
    rmdir "$backup_skill" || return 1
  fi
  if [[ "${_WCE_FRESH_SKILLS_PREEXISTED:-true}" != true ]]; then
    rmdir "$backup_skills" || return 1
  fi
}

_mdm_rotate_backups() { # <new-backup>
  local new_backup="$1" candidate suffix
  for candidate in "$HOME"/.claude.mdm-backup.*; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    [[ "$candidate" == "$new_backup" ]] && continue
    suffix="${candidate#"$HOME"/.claude.mdm-backup.}"
    [[ "$suffix" =~ ^[0-9]{14}(\.[0-9]+)?$ ]] || continue
    # This prefix is reserved exclusively for bounded MDM rotation. Removing
    # the entry itself is safe for symlinks/FIFOs too and never opens copied
    # user-controlled marker content.
    if ! rm -rf "$candidate"; then
      warn "Could not rotate old MDM backup: $candidate"
      return 1
    fi
  done
}

backup_existing() {
  # Do not expose a stale recovery point if this attempt fails before the
  # candidate marker commits.
  _BACKUP_TIMESTAMP=""
  _BACKUP_PATH=""

  # Dry-run: no real backup needed (sim dir protects the real filesystem)
  [[ "${DRY_RUN:-false}" == "true" ]] && return 0

  if _deploy_outer_transaction_active; then
    local outer_backup="${KIT_MDM_OUTER_TRANSACTION_BACKUP:-}"
    local outer_marker="$CLAUDE_DIR/.starter-kit-last-backup"
    if [[ -z "$outer_backup" ]]; then
      # Initial absence is represented by no backup and must not inherit a
      # stale marker into the newly-created live candidate.
      [[ ! -e "$outer_marker" && ! -L "$outer_marker" ]] || return 1
      return 0
    fi
    [[ "$outer_backup" == "$HOME"/.claude.mdm-backup.* \
      && -d "$outer_backup" && ! -L "$outer_backup" ]] || return 1
    local outer_marker_tmp
    outer_marker_tmp="$(mktemp)" || return 1
    _SETUP_TMP_FILES+=("$outer_marker_tmp")
    printf '%s\n' "$outer_backup" > "$outer_marker_tmp" \
      && _mdm_atomic_replace_managed_file "$outer_marker_tmp" "$outer_marker" \
      || return 1
    _BACKUP_PATH="$outer_backup"
    _BACKUP_TIMESTAMP="${outer_backup#"$HOME/.claude.mdm-backup."}"
    return 0
  fi

  if [[ -e "$CLAUDE_DIR" ]]; then
    local backup_timestamp
    backup_timestamp="$(date +%Y%m%d%H%M%S)" || return 1
    local backup_prefix="$HOME/.claude.backup."
    _deploy_mdm_managed && backup_prefix="$HOME/.claude.mdm-backup."
    local backup_base="${backup_prefix}${backup_timestamp}"
    local backup="$backup_base" collision=0
    while [[ -e "$backup" || -L "$backup" ]]; do
      collision=$((collision + 1))
      [[ "$collision" -le 100 ]] || { warn "Could not allocate backup path"; return 1; }
      backup="$backup_base.$collision"
    done
    if ! cp -a "$CLAUDE_DIR" "$backup"; then
      rm -rf "$backup" 2>/dev/null || true
      return 1
    fi
    if ! _wce_scrub_fresh_lock_from_backup "$backup"; then
      rm -rf "$backup" 2>/dev/null || true
      return 1
    fi
    if _deploy_mdm_managed; then
      if [[ ! -d "$backup" || -L "$backup" ]]; then
        rm -rf "$backup" 2>/dev/null || true
        return 1
      fi
      local backup_marker_tmp
      backup_marker_tmp="$(mktemp)" || { rm -rf "$backup" 2>/dev/null || true; return 1; }
      _SETUP_TMP_FILES+=("$backup_marker_tmp")
      if ! printf '%s\n' "$backup" > "$backup_marker_tmp" \
        || ! _mdm_atomic_replace_managed_file \
          "$backup_marker_tmp" "$CLAUDE_DIR/.starter-kit-last-backup"; then
        rm -rf "$backup" 2>/dev/null || true
        return 1
      fi

      # The marker is the commit point. Only now publish in-process globals;
      # old-backup rotation is best-effort because recovery already points at
      # the complete new candidate.
      _BACKUP_TIMESTAMP="${backup#"$backup_prefix"}"
      _BACKUP_PATH="$backup"
      if ! _mdm_rotate_backups "$backup"; then
        warn "Could not finish rotating old MDM backups; the new backup remains active"
      fi
    else
      _BACKUP_TIMESTAMP="${backup#"$backup_prefix"}"
      _BACKUP_PATH="$backup"
      printf '%s\n' "$backup" > "$CLAUDE_DIR/.starter-kit-last-backup" || return 1
    fi
    ok "Backed up existing ~/.claude to $backup"
  fi
}

# ---------------------------------------------------------------------------
# Manifest: track all deployed files for clean uninstall
# ---------------------------------------------------------------------------
_MANAGED_TARGET_FILES=()

_is_distribution_excluded_relpath() {
  local rel_path="$1"
  case "$rel_path" in
    node_modules|node_modules/*|logs|logs/*|*.bak)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_is_wce_package_pair_relpath() {
  case "$1" in
    web-content-extraction/package.json|web-content-extraction/package-lock.json)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_find_distribution_files() {
  local src_root="$1"
  [[ -d "$src_root" ]] || return 0

  local find_output src_file rel_path
  find_output="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$find_output")
  if ! find "$src_root" \
    \( -type d \( -name node_modules -o -name logs \) -prune \) -o \
    \( -type f -name '*.bak' -prune \) -o \
    -type f -print0 2>/dev/null > "$find_output"; then
    rm -f "$find_output" 2>/dev/null || true
    return 1
  fi
  while IFS= read -r -d '' src_file; do
    rel_path="${src_file#"$src_root"/}"
    _is_distribution_excluded_relpath "$rel_path" && continue
    if ! printf '%s\0' "$src_file"; then
      rm -f "$find_output" 2>/dev/null || true
      return 1
    fi
  done < "$find_output"
  rm -f "$find_output" || return 1
}

_mdm_distribution_relpath_is_safe() {
  local rel="$1"
  [[ -n "$rel" && "$rel" != /* && ! "$rel" =~ [[:cntrl:]] ]] || return 1
  case "/$rel/" in
    */../*|*/./*|*//*) return 1 ;;
  esac
  return 0
}

_mdm_distribution_path_is_confined() {
  local path="$1"
  local root="${CLAUDE_DIR:-}"
  [[ "$root" == /* && "$path" == /* ]] || return 1
  while [[ "$root" != "/" && "$root" == */ ]]; do
    root="${root%/}"
  done
  [[ "$root" != "/" && -d "$root" && ! -L "$root" ]] || return 1
  [[ "$path" == "$root" ]] && return 0
  case "$path" in
    "$root"/*) ;;
    *) return 1 ;;
  esac
  _mdm_distribution_relpath_is_safe "${path#"$root"/}"
}

_mdm_ensure_real_distribution_dir() {
  local dir="$1"
  if ! _mdm_distribution_path_is_confined "$dir"; then
    warn "Refusing unsafe MDM distribution directory"
    return 1
  fi

  local root="${CLAUDE_DIR:-}"
  while [[ "$root" != "/" && "$root" == */ ]]; do
    root="${root%/}"
  done
  [[ "$dir" == "$root" ]] && return 0

  local rel="${dir#"$root"/}"
  local current="$root" rest="$rel" segment
  while [[ -n "$rest" ]]; do
    segment="${rest%%/*}"
    rest="${rest#"$segment"}"
    rest="${rest#/}"
    current="$current/$segment"
    if [[ -L "$current" ]]; then
      warn "Refusing symlinked MDM distribution directory: ${current#"$root"/}"
      return 1
    fi
    if [[ -e "$current" ]]; then
      if [[ ! -d "$current" ]]; then
        warn "Refusing non-directory MDM distribution parent: ${current#"$root"/}"
        return 1
      fi
    else
      mkdir "$current" || return 1
      if [[ ! -d "$current" || -L "$current" ]]; then
        warn "Failed to create a real MDM distribution directory: ${current#"$root"/}"
        return 1
      fi
    fi
  done
}

_mdm_distribution_target_is_safe() {
  local target="$1"
  if ! _mdm_distribution_path_is_confined "$target"; then
    warn "Refusing unsafe MDM distribution target"
    return 1
  fi

  local parent="${target%/*}"
  _mdm_ensure_real_distribution_dir "$parent" || return 1

  local root="${CLAUDE_DIR:-}"
  while [[ "$root" != "/" && "$root" == */ ]]; do
    root="${root%/}"
  done
  if [[ -L "$target" ]]; then
    warn "Refusing symlinked MDM distribution target: ${target#"$root"/}"
    return 1
  fi
  if [[ -e "$target" && ! -f "$target" ]]; then
    warn "Refusing special MDM distribution target: ${target#"$root"/}"
    return 1
  fi
  return 0
}

_mdm_atomic_replace_managed_file() {
  local src_file="$1"
  local dest_file="$2"
  local expected_mode="${3:-}"
  if [[ -n "$expected_mode" ]]; then
    case "$expected_mode" in
      600|700) ;;
      *) return 1 ;;
    esac
  fi
  _mdm_distribution_target_is_safe "$dest_file" || return 1

  # Copy to a fresh inode and rename it into place. This avoids following a
  # final symlink and also prevents an existing hard link from propagating the
  # managed write to another user-owned pathname.
  local parent="${dest_file%/*}"
  local tmp_file
  tmp_file="$(mktemp "$parent/.starter-kit-copy.XXXXXX")" || return 1
  _SETUP_TMP_FILES+=("$tmp_file")
  if ! cp -p "$src_file" "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi
  if [[ -n "$expected_mode" ]] && ! chmod "$expected_mode" "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi
  if ! _mdm_distribution_target_is_safe "$dest_file"; then
    rm -f "$tmp_file"
    return 1
  fi
  if ! mv -f "$tmp_file" "$dest_file"; then
    rm -f "$tmp_file"
    return 1
  fi
}

# Replace an authoritative file directly below CLAUDE_DIR while binding every
# filesystem operation to the already-opened real parent directory. Unlike
# ordinary distribution writes, the MDM manifest leaf is not user authority:
# a pre-created symlink, FIFO, or directory must converge to a fresh regular
# file without ever following the old leaf or a swapped parent path.
_mdm_atomic_replace_authoritative_root_file() {
  local src_file="$1" dest_file="$2" expected_mode="${3:-600}"
  [[ "$CLAUDE_DIR" == /* && ! "$CLAUDE_DIR" =~ [[:cntrl:]] \
    && "$dest_file" == "$CLAUDE_DIR/"* \
    && ! "$dest_file" =~ [[:cntrl:]] ]] || return 1
  [[ "${dest_file%/*}" == "$CLAUDE_DIR" ]] || return 1
  _mdm_distribution_relpath_is_safe "${dest_file#"$CLAUDE_DIR"/}" || return 1
  case "$expected_mode" in 600|700) ;; *) return 1 ;; esac
  [[ -x /usr/bin/python3 && ! -L /usr/bin/python3 ]] || return 1

  /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    /usr/bin/python3 -c '
import errno
import os
import secrets
import stat
import sys

root, source, destination, mode_text = sys.argv[1:]
mode = int(mode_text, 8)
if not os.path.isabs(root) or os.path.dirname(destination) != root:
    raise SystemExit(1)
leaf = os.path.basename(destination)
if not leaf or leaf in (".", "..") or "/" in leaf:
    raise SystemExit(1)
if os.path.realpath(root) != root:
    raise SystemExit(1)

nofollow = getattr(os, "O_NOFOLLOW", 0)
directory = getattr(os, "O_DIRECTORY", 0)
parent_fd = os.open(root, os.O_RDONLY | directory | nofollow)
temp_name = ".starter-kit-authoritative." + secrets.token_hex(12)
old_name = ".starter-kit-replaced." + secrets.token_hex(12)
temp_exists = False
old_exists = False

def same_parent():
    by_fd = os.fstat(parent_fd)
    by_path = os.stat(root, follow_symlinks=False)
    return (stat.S_ISDIR(by_path.st_mode) and
            by_fd.st_dev == by_path.st_dev and by_fd.st_ino == by_path.st_ino and
            os.path.realpath(root) == root)

def remove_entry(dir_fd, name):
    entry = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    if stat.S_ISDIR(entry.st_mode):
        child_fd = os.open(name, os.O_RDONLY | directory | nofollow, dir_fd=dir_fd)
        try:
            for child in os.listdir(child_fd):
                remove_entry(child_fd, child)
        finally:
            os.close(child_fd)
        os.rmdir(name, dir_fd=dir_fd)
    else:
        os.unlink(name, dir_fd=dir_fd)

try:
    if not same_parent():
        raise OSError(errno.ESTALE, "managed parent identity changed")
    source_fd = os.open(source, os.O_RDONLY | nofollow)
    try:
        source_stat = os.fstat(source_fd)
        if not stat.S_ISREG(source_stat.st_mode) or source_stat.st_nlink != 1:
            raise OSError(errno.EINVAL, "managed source is not a single-link regular file")
        temp_fd = os.open(temp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow,
                          mode, dir_fd=parent_fd)
        temp_exists = True
        try:
            while True:
                chunk = os.read(source_fd, 1024 * 1024)
                if not chunk:
                    break
                view = memoryview(chunk)
                while view:
                    written = os.write(temp_fd, view)
                    view = view[written:]
            os.fchmod(temp_fd, mode)
            os.fsync(temp_fd)
        finally:
            os.close(temp_fd)
    finally:
        os.close(source_fd)

    if not same_parent():
        raise OSError(errno.ESTALE, "managed parent identity changed")
    try:
        existing = os.stat(leaf, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        existing = None

    if existing is not None and stat.S_ISDIR(existing.st_mode):
        os.rename(leaf, old_name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        old_exists = True
    try:
        os.replace(temp_name, leaf, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        temp_exists = False
    except Exception:
        if old_exists:
            os.rename(old_name, leaf, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
            old_exists = False
        raise

    final = os.stat(leaf, dir_fd=parent_fd, follow_symlinks=False)
    if (not stat.S_ISREG(final.st_mode) or final.st_nlink != 1 or
            stat.S_IMODE(final.st_mode) != mode):
        raise OSError(errno.EIO, "managed destination postcondition failed")
    os.fsync(parent_fd)
    if not same_parent():
        raise OSError(errno.ESTALE, "managed parent identity changed")
    if old_exists:
        remove_entry(parent_fd, old_name)
        old_exists = False
finally:
    if temp_exists:
        try:
            remove_entry(parent_fd, temp_name)
        except FileNotFoundError:
            pass
    if old_exists:
        try:
            remove_entry(parent_fd, old_name)
        except FileNotFoundError:
            pass
    os.close(parent_fd)
' "$CLAUDE_DIR" "$src_file" "$dest_file" "$expected_mode"
}

_mdm_expected_managed_mode() {
  local file="$1"
  local rel source="" hook_script=false feature hook_rel
  case "$file" in
    "$CLAUDE_DIR/.starter-kit-snapshot/"*)
      rel="${file#"$CLAUDE_DIR/.starter-kit-snapshot/"}"
      ;;
    "$CLAUDE_DIR/"*)
      rel="${file#"$CLAUDE_DIR/"}"
      ;;
    *)
      return 1
      ;;
  esac
  _mdm_distribution_relpath_is_safe "$rel" || return 1

  case "$rel" in
    settings.json|CLAUDE.md)
      printf '600\n'
      return 0
      ;;
    agents/*)
      source="$PROJECT_DIR/agents/${rel#agents/}"
      ;;
    rules/*)
      source="$PROJECT_DIR/rules/${rel#rules/}"
      ;;
    commands/*)
      source="$PROJECT_DIR/commands/${rel#commands/}"
      ;;
    skills/*)
      source="$PROJECT_DIR/skills/${rel#skills/}"
      ;;
    hooks/*/*)
      hook_rel="${rel#hooks/}"
      feature="${hook_rel%%/*}"
      hook_rel="${hook_rel#*/}"
      source="$PROJECT_DIR/features/$feature/scripts/$hook_rel"
      hook_script=true
      ;;
    *)
      return 1
      ;;
  esac

  [[ -f "$source" && ! -L "$source" ]] || return 1
  if [[ -x "$source" ]] \
    || { [[ "$hook_script" == true ]] \
      && [[ "$source" == *.sh || "$source" == *.py ]]; }; then
    printf '700\n'
  else
    printf '600\n'
  fi
}

_mdm_copy_distribution_file() {
  _mdm_atomic_replace_managed_file "$1" "$2"
}

_mdm_make_distribution_scripts_executable() {
  local src_root="$1" dest_root="$2"
  local src_file rel_path dest_file source_list
  source_list="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$source_list")
  _find_distribution_files "$src_root" > "$source_list" \
    || { rm -f "$source_list"; return 1; }
  while IFS= read -r -d '' src_file; do
    case "$src_file" in
      *.sh|*.py) ;;
      *) continue ;;
    esac
    rel_path="${src_file#"$src_root"/}"
    dest_file="$dest_root/$rel_path"
    _mdm_distribution_target_is_safe "$dest_file" \
      || { rm -f "$source_list"; return 1; }
    chmod +x "$dest_file" || { rm -f "$source_list"; return 1; }
  done < "$source_list"
  rm -f "$source_list" || return 1
}

_prepare_mdm_claude_root() {
  _deploy_mdm_managed || return 0
  if [[ -L "$CLAUDE_DIR" ]] || [[ -e "$CLAUDE_DIR" && ! -d "$CLAUDE_DIR" ]]; then
    error "FATAL: MDM requires CLAUDE_DIR to be a real directory"
    return 1
  fi
  if [[ ! -e "$CLAUDE_DIR" ]]; then
    mkdir "$CLAUDE_DIR" || return 1
  fi
  if [[ ! -d "$CLAUDE_DIR" || -L "$CLAUDE_DIR" ]]; then
    error "FATAL: could not establish a real MDM CLAUDE_DIR"
    return 1
  fi
}

_copy_distribution_tree() {
  local src_root="$1"
  local dest_root="$2"
  local mode="${3:-overwrite}"
  local preserve_wce_pair="${4:-false}"

  [[ -d "$src_root" ]] || return 0

  if _deploy_mdm_managed; then
    _mdm_ensure_real_distribution_dir "$dest_root" || return 1

    local -a src_files=()
    local src_file rel_path dest_file source_list
    source_list="$(mktemp)" || return 1
    _SETUP_TMP_FILES+=("$source_list")
    _find_distribution_files "$src_root" > "$source_list" \
      || { rm -f "$source_list"; return 1; }
    while IFS= read -r -d '' src_file; do
      src_files+=("$src_file")
    done < "$source_list"

    # Preflight the complete tree before replacing any managed file. Parent
    # directories may be created, but an unsafe destination fails closed before
    # managed content is changed.
    for src_file in "${src_files[@]+"${src_files[@]}"}"; do
      rel_path="${src_file#"$src_root"/}"
      if [[ "$preserve_wce_pair" == true ]] \
        && _is_wce_package_pair_relpath "$rel_path"; then
        continue
      fi
      if ! _mdm_distribution_relpath_is_safe "$rel_path"; then
        warn "Refusing unsafe MDM distribution source path"
        rm -f "$source_list" 2>/dev/null || true
        return 1
      fi
      dest_file="$dest_root/$rel_path"
      _mdm_distribution_target_is_safe "$dest_file" \
        || { rm -f "$source_list"; return 1; }
    done

    for src_file in "${src_files[@]+"${src_files[@]}"}"; do
      rel_path="${src_file#"$src_root"/}"
      if [[ "$preserve_wce_pair" == true ]] \
        && _is_wce_package_pair_relpath "$rel_path"; then
        continue
      fi
      dest_file="$dest_root/$rel_path"
      if [[ "$mode" == "new" && -e "$dest_file" ]]; then
        continue
      fi
      _mdm_copy_distribution_file "$src_file" "$dest_file" \
        || { rm -f "$source_list"; return 1; }
    done
    rm -f "$source_list" || return 1
    return 0
  fi

  mkdir -p "$dest_root" || return 1

  local src_file rel_path dest_file source_list
  source_list="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$source_list")
  _find_distribution_files "$src_root" > "$source_list" \
    || { rm -f "$source_list"; return 1; }
  while IFS= read -r -d '' src_file; do
    rel_path="${src_file#"$src_root"/}"
    if [[ "$preserve_wce_pair" == true ]] \
      && _is_wce_package_pair_relpath "$rel_path"; then
      continue
    fi
    dest_file="${dest_root}/${rel_path}"
    [[ "$mode" == "new" && -e "$dest_file" ]] && continue
    mkdir -p "$(dirname "$dest_file")" \
      || { rm -f "$source_list"; return 1; }
    cp -p "$src_file" "$dest_file" \
      || { rm -f "$source_list"; return 1; }
  done < "$source_list"
  rm -f "$source_list" || return 1
}

_add_managed_tree_targets() {
  local src_root="$1"
  local dest_root="$2"
  [[ -d "$src_root" ]] || return 0

  local src_file rel_path source_list
  source_list="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$source_list")
  _find_distribution_files "$src_root" > "$source_list" \
    || { rm -f "$source_list"; return 1; }
  while IFS= read -r -d '' src_file; do
    rel_path="${src_file#"$src_root"/}"
    _MANAGED_TARGET_FILES+=("${dest_root}/${rel_path}")
  done < "$source_list"
  rm -f "$source_list" || return 1
}

# Files preserved (skipped) during fresh install with existing user data.
# These must NOT appear in manifest or snapshot — they are user-owned.
_FRESH_SKIPPED_FILES=()

_is_fresh_skipped() {
  local path="$1"
  local skipped
  for skipped in "${_FRESH_SKIPPED_FILES[@]+"${_FRESH_SKIPPED_FILES[@]}"}"; do
    # Match exact file or prefix (for directory-level skips)
    if [[ "$path" == "$skipped" ]] || [[ "$path" == "$skipped"/* ]]; then
      return 0
    fi
  done
  return 1
}

collect_managed_target_files() {
  _MANAGED_TARGET_FILES=(
    "$CLAUDE_DIR/settings.json"
    "$CLAUDE_DIR/CLAUDE.md"
  )

  # Enumerate all starter-kit-owned file paths, then keep only paths that
  # currently exist under ~/.claude. This preserves tracking for leftovers from
  # previously enabled components without sweeping up arbitrary user files.
  if ! _deploy_mdm_managed || is_true "${INSTALL_AGENTS:-false}"; then
    _add_managed_tree_targets "$PROJECT_DIR/agents" "$CLAUDE_DIR/agents" || return 1
  fi
  if ! _deploy_mdm_managed || is_true "${INSTALL_RULES:-false}"; then
    _add_managed_tree_targets "$PROJECT_DIR/rules" "$CLAUDE_DIR/rules" || return 1
  fi
  if ! _deploy_mdm_managed || is_true "${INSTALL_COMMANDS:-false}"; then
    _add_managed_tree_targets "$PROJECT_DIR/commands" "$CLAUDE_DIR/commands" || return 1
  fi
  if ! _deploy_mdm_managed || is_true "${INSTALL_SKILLS:-false}"; then
    _add_managed_tree_targets "$PROJECT_DIR/skills" "$CLAUDE_DIR/skills" || return 1
  fi
  # Registry-driven: hook script paths from _FEATURE_HAS_SCRIPTS
  local _feat_name
  for _feat_name in "${_FEATURE_SCRIPT_ORDER[@]+"${_FEATURE_SCRIPT_ORDER[@]}"}"; do
    [[ "${_FEATURE_HAS_SCRIPTS[$_feat_name]+set}" ]] || continue
    if _deploy_mdm_managed; then
      local _feat_flag="${_FEATURE_FLAGS[$_feat_name]:-}"
      [[ -n "$_feat_flag" ]] && is_true "${!_feat_flag:-false}" || continue
    fi
    _add_managed_tree_targets \
      "$PROJECT_DIR/features/$_feat_name/scripts" \
      "$CLAUDE_DIR/hooks/$_feat_name" || return 1
  done

  # Filter out files that the user chose to preserve during fresh install.
  # These are user-owned and must not be tracked as kit-managed.
  if [[ ${#_FRESH_SKIPPED_FILES[@]} -gt 0 ]]; then
    local filtered=()
    local f
    for f in "${_MANAGED_TARGET_FILES[@]+"${_MANAGED_TARGET_FILES[@]}"}"; do
      if ! _is_fresh_skipped "$f"; then
        filtered+=("$f")
      fi
    done
    _MANAGED_TARGET_FILES=("${filtered[@]+"${filtered[@]}"}")
  fi
}

# MDM must attest both what is present and what must be absent.  The universe
# is every path shipped by the current pinned checkout across all profiles;
# profile-disabled paths are safe deletion candidates only when their bytes
# still match that checkout payload.
declare -g -A _MDM_UNIVERSE_SOURCE_BY_REL=()
declare -g -A _MDM_UNIVERSE_EXEC_BY_REL=()
declare -g -A _MDM_CURRENT_REL_SET=()
declare -g -A _MDM_PRIOR_REL_SET=()

_mdm_load_prior_inventory() {
  _MDM_PRIOR_REL_SET=()
  local inventory="${KIT_MDM_PRIOR_MANAGED_INVENTORY:-}" owner mode rel count=0
  [[ -n "$inventory" ]] || return 0
  case "$inventory" in
    /private/tmp/claude-kit-mdm-prior.*|/tmp/claude-kit-mdm-prior.*) ;;
    *) return 1 ;;
  esac
  [[ -f "$inventory" && ! -L "$inventory" ]] || return 1
  if [[ "$(uname -s 2>/dev/null || true)" == Darwin ]]; then
    owner="$(stat -f '%u' "$inventory" 2>/dev/null)" || return 1
  else
    owner="$(stat -c '%u' "$inventory" 2>/dev/null)" || return 1
  fi
  if [[ "${MDM_PRIOR_INVENTORY_SKIP_OWNER_CHECK:-0}" != 1 ]]; then
    [[ "$owner" == 0 ]] || return 1
  fi
  if [[ "$(uname -s 2>/dev/null || true)" == Darwin ]]; then
    mode="$(stat -f '%Mp%Lp' "$inventory" 2>/dev/null)" || return 1
  else
    mode="$(stat -c '%a' "$inventory" 2>/dev/null)" || return 1
  fi
  [[ "$mode" =~ ^[0-7]+$ ]] || return 1
  while [[ ${#mode} -gt 3 ]]; do mode="${mode#?}"; done
  case "$mode" in *[2367]|?[2367]?) return 1 ;; esac
  while IFS= read -r rel || [[ -n "$rel" ]]; do
    _mdm_distribution_relpath_is_safe "$rel" || return 1
    [[ -z "${_MDM_PRIOR_REL_SET[$rel]+set}" ]] || return 1
    _MDM_PRIOR_REL_SET[$rel]=1
    count=$((count + 1)); [[ "$count" -le 2000 ]] || return 1
  done < "$inventory"
}

_mdm_register_universe_tree() { # <source-root> <destination-prefix> <scripts:0|1>
  local src_root="$1" dest_prefix="$2" scripts="$3"
  local src_file source_rel managed_rel executable source_list
  source_list="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$source_list")
  _find_distribution_files "$src_root" > "$source_list" \
    || { rm -f "$source_list"; return 1; }
  while IFS= read -r -d '' src_file; do
    source_rel="${src_file#"$src_root"/}"
    _mdm_distribution_relpath_is_safe "$source_rel" \
      || { rm -f "$source_list"; return 1; }
    managed_rel="$dest_prefix/$source_rel"
    [[ -z "${_MDM_UNIVERSE_SOURCE_BY_REL[$managed_rel]+set}" ]] \
      || { rm -f "$source_list"; return 1; }
    executable=false
    if [[ -x "$src_file" ]] \
      || [[ "$scripts" == 1 && ( "$src_file" == *.sh || "$src_file" == *.py ) ]]; then
      executable=true
    fi
    _MDM_UNIVERSE_SOURCE_BY_REL[$managed_rel]="$src_file"
    _MDM_UNIVERSE_EXEC_BY_REL[$managed_rel]="$executable"
  done < "$source_list"
  rm -f "$source_list" || return 1
}

_mdm_build_managed_universe() {
  _MDM_UNIVERSE_SOURCE_BY_REL=()
  _MDM_UNIVERSE_EXEC_BY_REL=()
  _MDM_CURRENT_REL_SET=()
  _mdm_load_prior_inventory || return 1
  collect_managed_target_files || return 1
  local target feature
  for target in "${_MANAGED_TARGET_FILES[@]+"${_MANAGED_TARGET_FILES[@]}"}"; do
    case "$target" in
      "$CLAUDE_DIR"/*) _MDM_CURRENT_REL_SET[${target#"$CLAUDE_DIR"/}]=1 ;;
      *) return 1 ;;
    esac
  done
  _mdm_register_universe_tree "$PROJECT_DIR/agents" agents 0 || return 1
  _mdm_register_universe_tree "$PROJECT_DIR/rules" rules 0 || return 1
  _mdm_register_universe_tree "$PROJECT_DIR/commands" commands 0 || return 1
  _mdm_register_universe_tree "$PROJECT_DIR/skills" skills 0 || return 1
  for feature in "${_FEATURE_SCRIPT_ORDER[@]+"${_FEATURE_SCRIPT_ORDER[@]}"}"; do
    [[ "${_FEATURE_HAS_SCRIPTS[$feature]+set}" ]] || continue
    _mdm_register_universe_tree \
      "$PROJECT_DIR/features/$feature/scripts" "hooks/$feature" 1 || return 1
  done
}

mdm_absent_files_json() {
  _mdm_build_managed_universe || return 1
  {
    local rel
    for rel in "${!_MDM_UNIVERSE_SOURCE_BY_REL[@]}"; do
      [[ -n "${_MDM_CURRENT_REL_SET[$rel]+set}" ]] || printf '%s\n' "$rel"
    done
    for rel in "${!_MDM_PRIOR_REL_SET[@]}"; do
      [[ -n "${_MDM_CURRENT_REL_SET[$rel]+set}" ]] || printf '%s\n' "$rel"
    done
  } | LC_ALL=C sort -u | jq -R -s 'split("\n")[:-1]'
}

_mdm_claim_and_remove_absent_file() { # <root> <relative> <source> <exec> <prior>
  local root="$1" relative="$2" source="$3" expects_exec="$4" prior="$5"
  [[ -x /usr/bin/python3 ]] || return 1
  /usr/bin/python3 -I -B -c '
import hashlib, os, stat, sys

root, relative, source, expects_exec, prior = sys.argv[1:]
parts = relative.split("/")
dir_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
file_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)

def open_parent():
    try:
        current = os.open(root, dir_flags)
    except FileNotFoundError:
        return None, None
    except OSError:
        raise SystemExit(1)
    for component in parts[:-1]:
        try:
            before = os.stat(component, dir_fd=current, follow_symlinks=False)
        except FileNotFoundError:
            os.close(current)
            return None, None
        except OSError:
            os.close(current)
            raise SystemExit(1)
        if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
            os.close(current)
            raise SystemExit(1)
        try:
            child = os.open(component, dir_flags, dir_fd=current)
        except OSError:
            os.close(current)
            raise SystemExit(1)
        opened = os.fstat(child)
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            os.close(child)
            os.close(current)
            raise SystemExit(1)
        os.close(current)
        current = child
    return current, parts[-1]

parent, name = open_parent()
if parent is None:
    raise SystemExit(0)
try:
    try:
        os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        raise SystemExit(0)
    except OSError:
        raise SystemExit(1)
    quarantine = ".starter-kit-retired.{}.{}".format(os.getpid(), os.urandom(12).hex())
    try:
        os.rename(name, quarantine, src_dir_fd=parent, dst_dir_fd=parent)
    except OSError:
        raise SystemExit(1)

    def restore():
        try:
            os.stat(name, dir_fd=parent, follow_symlinks=False)
            return False
        except FileNotFoundError:
            try:
                os.rename(quarantine, name, src_dir_fd=parent, dst_dir_fd=parent)
                return True
            except OSError:
                return False
        except OSError:
            return False

    try:
        claimed = os.stat(quarantine, dir_fd=parent, follow_symlinks=False)
        if stat.S_ISDIR(claimed.st_mode):
            raise ValueError("directory")
        if prior == "true":
            os.unlink(quarantine, dir_fd=parent)
            raise SystemExit(0)
        if not stat.S_ISREG(claimed.st_mode) or claimed.st_mode & 0o022:
            raise ValueError("unsafe file")
        if bool(claimed.st_mode & stat.S_IXUSR) != (expects_exec == "true"):
            raise ValueError("mode mismatch")
        claimed_fd = os.open(quarantine, file_flags, dir_fd=parent)
        try:
            opened = os.fstat(claimed_fd)
            identity = (claimed.st_dev, claimed.st_ino, claimed.st_size, claimed.st_mtime_ns)
            if identity != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns):
                raise ValueError("claim changed")
            if opened.st_size > 64 * 1024 * 1024:
                raise ValueError("claim too large")
            claim_hash = hashlib.sha256()
            while True:
                chunk = os.read(claimed_fd, 1024 * 1024)
                if not chunk:
                    break
                claim_hash.update(chunk)
            after = os.fstat(claimed_fd)
            if identity != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
                raise ValueError("claim modified")
        finally:
            os.close(claimed_fd)
        source_fd = os.open(source, file_flags)
        try:
            source_before = os.fstat(source_fd)
            if not stat.S_ISREG(source_before.st_mode) or source_before.st_size > 64 * 1024 * 1024:
                raise ValueError("source invalid")
            source_identity = (
                source_before.st_dev, source_before.st_ino,
                source_before.st_size, source_before.st_mtime_ns,
            )
            source_hash = hashlib.sha256()
            while True:
                chunk = os.read(source_fd, 1024 * 1024)
                if not chunk:
                    break
                source_hash.update(chunk)
            source_after = os.fstat(source_fd)
            if source_identity != (
                source_after.st_dev, source_after.st_ino,
                source_after.st_size, source_after.st_mtime_ns,
            ):
                raise ValueError("source modified")
        finally:
            os.close(source_fd)
        if claim_hash.digest() != source_hash.digest():
            raise ValueError("content mismatch")
        os.unlink(quarantine, dir_fd=parent)
        raise SystemExit(0)
    except SystemExit:
        raise
    except (OSError, ValueError):
        restore()
        raise SystemExit(1)
finally:
    os.close(parent)
' "$root" "$relative" "$source" "$expects_exec" "$prior"
}

_mdm_reconcile_absent_managed_files() { # <claude-dir> <snapshot-dir>
  _deploy_mdm_managed || return 0
  local claude_dir="$1" snapshot_dir="$2" rel source expects_exec path_root path_rel
  local prior_authorized absent_unsorted absent_list
  _mdm_build_managed_universe || return 1
  absent_unsorted="$(mktemp)" || return 1
  absent_list="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$absent_unsorted" "$absent_list")
  {
    for rel in "${!_MDM_UNIVERSE_SOURCE_BY_REL[@]}"; do
      [[ -n "${_MDM_CURRENT_REL_SET[$rel]+set}" ]] \
        || printf '%s\n' "$rel" || return 1
    done
    for rel in "${!_MDM_PRIOR_REL_SET[@]}"; do
      [[ -n "${_MDM_CURRENT_REL_SET[$rel]+set}" ]] \
        || printf '%s\n' "$rel" || return 1
    done
  } > "$absent_unsorted" || return 1
  LC_ALL=C sort -u "$absent_unsorted" > "$absent_list" || return 1
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    source="${_MDM_UNIVERSE_SOURCE_BY_REL[$rel]:-}"
    expects_exec="${_MDM_UNIVERSE_EXEC_BY_REL[$rel]:-false}"
    prior_authorized=false
    [[ -n "${_MDM_PRIOR_REL_SET[$rel]+set}" ]] && prior_authorized=true
    for path_root in "$claude_dir" "$snapshot_dir"; do
      path_rel="$rel"
      if ! _mdm_claim_and_remove_absent_file \
        "$path_root" "$path_rel" "$source" "$expects_exec" "$prior_authorized"; then
        warn "Ambiguous disabled MDM managed file: $rel"
        rm -f "$absent_unsorted" "$absent_list" 2>/dev/null || true
        return 1
      fi
    done
  done < "$absent_list"
  rm -f "$absent_unsorted" "$absent_list" || return 1
}

managed_files_json() {
  collect_managed_target_files || return 1
  {
    local file
    for file in "${_MANAGED_TARGET_FILES[@]+"${_MANAGED_TARGET_FILES[@]}"}"; do
      [[ -f "$file" ]] && printf '%s\n' "$file"
    done
    true  # Ensure non-zero from last [[ -f ]] miss doesn't trigger pipefail
  } | LC_ALL=C sort -u | jq -R -s 'split("\n")[:-1]'
}

_normalize_mdm_managed_modes() {
  _deploy_mdm_managed || return 0
  local file mode link_count actual_mode
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    _mdm_distribution_target_is_safe "$file" || return 1
    mode="$(_mdm_expected_managed_mode "$file")" || return 1
    if [[ "$(uname -s 2>/dev/null || true)" == Darwin ]]; then
      link_count="$(stat -f '%l' "$file" 2>/dev/null || true)"
    else
      link_count="$(stat -c '%h' "$file" 2>/dev/null || true)"
    fi
    [[ "$link_count" =~ ^[0-9]+$ ]] || return 1

    # Always replace through a fresh inode and set mode before rename. This
    # breaks hostile hard links without chmod-ing their aliases, repairs mode
    # drift from the trusted checkout rather than the live executable bit, and
    # avoids a chmod race against a swapped destination pathname.
    _mdm_atomic_replace_managed_file "$file" "$file" "$mode" || return 1
    if [[ "$(uname -s 2>/dev/null || true)" == Darwin ]]; then
      link_count="$(stat -f '%l' "$file" 2>/dev/null)" || return 1
      actual_mode="$(stat -f '%Lp' "$file" 2>/dev/null)" || return 1
    else
      link_count="$(stat -c '%h' "$file" 2>/dev/null)" || return 1
      actual_mode="$(stat -c '%a' "$file" 2>/dev/null)" || return 1
    fi
    [[ "$link_count" == 1 && "$actual_mode" == "$mode" ]] || return 1
  done
}

cleanup_paths_json() {
  jq -n \
    --arg claude_dir "$CLAUDE_DIR" \
    --arg config "$HOME/.claude-starter-kit.conf" \
    '[
      ($claude_dir + "/skills/web-content-extraction/node_modules"),
      ($claude_dir + "/skills/web-content-extraction/logs"),
      ($claude_dir + "/.starter-kit-update.lock"),
      ($claude_dir + "/.starter-kit-update-status"),
      ($claude_dir + "/.starter-kit-update-cache"),
      ($claude_dir + "/.starter-kit-merge-prefs.json"),
      ($claude_dir + "/.starter-kit-pending-features.json"),
      ($claude_dir + "/sessions"),
      ($claude_dir + "/tmp/tool-count-*"),
      ($claude_dir + "/.starter-kit-snapshot"),
      ($claude_dir + "/.starter-kit-last-backup"),
      $config
    ]'
}

write_managed_snapshot() {
  collect_managed_target_files || return 1
  local snapshot_files=()
  local file
  for file in "${_MANAGED_TARGET_FILES[@]+"${_MANAGED_TARGET_FILES[@]}"}"; do
    if [[ "${_WCE_FRESH_KIT_PAIR_BASELINE:-false}" == true ]]; then
      case "$file" in
        "$CLAUDE_DIR/skills/web-content-extraction/package.json"|\
        "$CLAUDE_DIR/skills/web-content-extraction/package-lock.json")
          # Fresh deployment publishes these two kit baselines together after
          # the generic snapshot has completed. Never transiently promote the
          # live runtime graph into the baseline.
          continue
          ;;
      esac
    fi
    [[ -f "$file" ]] && snapshot_files+=("$file")
  done
  _normalize_mdm_managed_modes "${snapshot_files[@]+"${snapshot_files[@]}"}" || return 1
  _write_snapshot "$CLAUDE_DIR" "${snapshot_files[@]+"${snapshot_files[@]}"}" || return 1

  # CLAUDE.md: replace full-file snapshot with kit-section-only snapshot
  if [[ -f "$CLAUDE_DIR/CLAUDE.md" ]]; then
    _snapshot_claude_md "$CLAUDE_DIR" "$CLAUDE_DIR/CLAUDE.md" || return 1
  fi

  if _deploy_mdm_managed; then
    local snapshot_file
    for file in "${snapshot_files[@]+"${snapshot_files[@]}"}"; do
      snapshot_file="$CLAUDE_DIR/.starter-kit-snapshot/${file#"$CLAUDE_DIR"/}"
      _normalize_mdm_managed_modes "$snapshot_file" || return 1
    done
  fi
}

_SNAPSHOT_BOOTSTRAPPED=false

bootstrap_snapshot_from_current() {
  warn "$STR_UPDATE_V1_WARN"
  info "$STR_UPDATE_MIGRATION_BOOTSTRAP"
  write_managed_snapshot || return 1
  _SNAPSHOT_BOOTSTRAPPED=true
  if [[ -n "${_BACKUP_TIMESTAMP:-}" ]]; then
    info "Backup available at: ${_BACKUP_PATH:-$HOME/.claude.backup.${_BACKUP_TIMESTAMP}}"
  fi
}

# ---------------------------------------------------------------------------
# Pre-deploy warnings
# ---------------------------------------------------------------------------
warn_existing_claude_reconfigure() {
  [[ -e "$CLAUDE_DIR" ]] || return 0
  [[ "${DRY_RUN:-false}" == "true" ]] && return 0

  printf "\n"
  warn "$STR_EXISTING_CLAUDE_WARN"
  info "$STR_EXISTING_CLAUDE_BACKUP"
  if [[ -f "$CLAUDE_DIR/settings.json" ]] && [[ ! -f "$CLAUDE_DIR/.starter-kit-manifest.json" ]]; then
    info "$STR_EXISTING_CLAUDE_MERGE_NOTE"
  else
    info "$STR_EXISTING_CLAUDE_REWRITE"
  fi
  info "$STR_EXISTING_CLAUDE_SIDE_EFFECTS"

  if [[ "${WIZARD_NONINTERACTIVE:-false}" == "true" ]]; then
    warn "$STR_EXISTING_CLAUDE_NONINTERACTIVE"
    return 0
  fi

  local confirm=""
  read -r -p "$STR_EXISTING_CLAUDE_CONFIRM " confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      info "$STR_EXISTING_CLAUDE_CANCEL"
      exit 0
      ;;
  esac
}

# ---------------------------------------------------------------------------
# File copy helpers
# ---------------------------------------------------------------------------
copy_if_enabled() {
  local flag="$1"
  local src="$2"
  local dest="$3"
  local preserve_wce_pair="${4:-false}"

  if is_true "$flag"; then
    _copy_distribution_tree \
      "$src" "$dest" "overwrite" "$preserve_wce_pair" || return 1
    ok "Installed $(basename "$dest")"
  else
    info "Skipped $(basename "$dest")"
  fi
}

# _copy_dir_safe <flag> <src> <dest>
#
# Like copy_if_enabled but checks for existing files in <dest>.
# Interactive: asks [O]verwrite all / [N]ew files only / [S]kip
# Non-interactive: new files only (safe default)
# Prompt replies are read from ${_TTY_INPUT:-/dev/tty} (tests may inject a file).
_copy_dir_safe() {
  local flag="$1"
  local src="$2"
  local dest="$3"
  local preserve_wce_pair="${4:-false}"
  local label
  label="$(basename "$dest")"

  if ! is_true "$flag"; then
    info "Skipped $label"
    return
  fi

  mkdir -p "$dest" || return 1

  # Check if dest has any existing files
  local has_existing=false
  if [[ "${_WCE_FRESH_LOCK_BACKUP_SCRUB:-false}" == true \
    && "$dest" == "$CLAUDE_DIR/skills" \
    && "${_WCE_FRESH_SKILLS_HAD_ENTRIES:-true}" != true ]]; then
    # The outer WCE lock may be the only apparent entry in a skills directory
    # that was empty before acquisition; do not turn that scaffold into a false
    # merge prompt or a new-only deployment.
    has_existing=false
  elif [[ -d "$dest" ]] && [[ -n "$(ls -A "$dest" 2>/dev/null)" ]]; then
    has_existing=true
  fi

  if [[ "$has_existing" == "false" ]]; then
    _copy_distribution_tree \
      "$src" "$dest" "overwrite" "$preserve_wce_pair" || return 1
    ok "Installed $label"
    return
  fi

  # Existing files found — decide what to do
  local action="new"  # default for non-interactive

  if _deploy_mdm_managed; then
    action="overwrite"
  elif [[ "${_MERGE_INTERACTIVE:-true}" == "true" ]]; then
    warn "$STR_FRESH_DIR_EXISTS $label/"
    printf "  %s " "$STR_FRESH_DIR_PROMPT" >&2
    local reply=""
    if read -r reply < "${_TTY_INPUT:-/dev/tty}" 2>/dev/null; then
      true
    else
      reply="n"
    fi
    case "$reply" in
      [Oo]*) action="overwrite" ;;
      [Ss]*) action="skip" ;;
      *)     action="new" ;;
    esac
  fi

  case "$action" in
    overwrite)
      _copy_distribution_tree \
        "$src" "$dest" "overwrite" "$preserve_wce_pair" || return 1
      ok "Installed $label (overwrite)"
      ;;
    skip)
      _FRESH_SKIPPED_FILES+=("$dest")
      ok "$label: $STR_FRESH_SKIPPED"
      ;;
    new)
      _copy_distribution_tree \
        "$src" "$dest" "new" "$preserve_wce_pair" || return 1
      ok "$label: $STR_FRESH_NEW_ONLY"
      ;;
  esac
}

_fresh_wce_pair_is_skipped() {
  _is_fresh_skipped "$CLAUDE_DIR/skills" \
    || _is_fresh_skipped \
      "$CLAUDE_DIR/skills/web-content-extraction"
}

_reconcile_fresh_wce_package_pair_locked() { # <current-dir> <kit-dir>
  local current_dir="$1" kit_dir="$2" pair_rc=0
  _wce_package_pair_is_valid \
    "$kit_dir/package.json" "$kit_dir/package-lock.json" || return 1
  mkdir -p "$current_dir" || return 1

  # Treat the current kit pair as the baseline. A coherent runtime-updated pair
  # keeps only its runtime-owned dependency graph; a missing/malformed half is
  # reset to the kit pair. The shared transaction helper stages and rolls back
  # both files together.
  if _update_auto_managed_wce_package_pair_locked \
    "$current_dir" "$kit_dir" "$kit_dir"; then
    pair_rc=0
  else
    pair_rc=$?
    [[ "$pair_rc" -eq 1 ]] || return "$pair_rc"
  fi
  _wce_package_pair_is_valid \
    "$current_dir/package.json" "$current_dir/package-lock.json"
}

reconcile_fresh_wce_package_pair() {
  is_true "${INSTALL_SKILLS:-false}" || return 0
  _deploy_mdm_managed && return 0
  _fresh_wce_pair_is_skipped && return 0
  local current_dir="$CLAUDE_DIR/skills/web-content-extraction"
  local kit_dir="$PROJECT_DIR/skills/web-content-extraction"
  [[ -d "$kit_dir" ]] || return 0
  declare -F _wce_with_runtime_update_lock >/dev/null 2>&1 || return 1
  _wce_with_runtime_update_lock "$current_dir" \
    _reconcile_fresh_wce_package_pair_locked "$current_dir" "$kit_dir"
}

_refresh_fresh_wce_snapshot_pair_locked() { # <current-dir> <snapshot-dir> <kit-dir>
  local current_dir="$1" snapshot_dir="$2" kit_dir="$3" pair_rc=0
  local missing_baseline="$snapshot_dir/.starter-kit-no-wce-baseline"
  _wce_package_pair_is_valid \
    "$current_dir/package.json" "$current_dir/package-lock.json" || return 1
  _wce_package_pair_is_valid \
    "$kit_dir/package.json" "$kit_dir/package-lock.json" || return 1
  [[ ! -e "$missing_baseline" && ! -L "$missing_baseline" ]] || return 1
  mkdir -p "$snapshot_dir" || return 1

  # A deliberately absent baseline makes the pair helper reset the snapshot to
  # kit bytes instead of preserving runtime versions from the live pair.
  if _update_auto_managed_wce_package_pair_locked \
    "$snapshot_dir" "$missing_baseline" "$kit_dir"; then
    pair_rc=0
  else
    pair_rc=$?
    [[ "$pair_rc" -eq 1 ]] || return "$pair_rc"
  fi
  _wce_package_pair_is_valid \
    "$snapshot_dir/package.json" "$snapshot_dir/package-lock.json" \
    && cmp -s "$snapshot_dir/package.json" "$kit_dir/package.json" \
    && cmp -s "$snapshot_dir/package-lock.json" "$kit_dir/package-lock.json"
}

refresh_fresh_wce_snapshot_pair() {
  is_true "${INSTALL_SKILLS:-false}" || return 0
  _deploy_mdm_managed && return 0
  _fresh_wce_pair_is_skipped && return 0
  local current_dir="$CLAUDE_DIR/skills/web-content-extraction"
  local snapshot_dir="$CLAUDE_DIR/.starter-kit-snapshot/skills/web-content-extraction"
  local kit_dir="$PROJECT_DIR/skills/web-content-extraction"
  [[ -d "$kit_dir" ]] || return 0
  declare -F _wce_with_runtime_update_lock >/dev/null 2>&1 || return 1
  _wce_with_runtime_update_lock "$current_dir" \
    _refresh_fresh_wce_snapshot_pair_locked \
    "$current_dir" "$snapshot_dir" "$kit_dir"
}

# ---------------------------------------------------------------------------
# maybe_install_web_content_deps - activate/install web-content-extraction deps
#
# In MDM mode, the privileged installer owns an immutable dependency bundle;
# setup only validates it and atomically activates its node_modules directory.
# A missing or invalid managed bundle/activation is fatal, and npm is never
# invoked. Outside MDM, retain the existing best-effort local `npm ci` flow.
#
# The skill's Node scripts depend on defuddle/jsdom/pdfjs-dist/undici.
#
# - Only runs when INSTALL_SKILLS is enabled and package.json exists.
# - MDM: the root-owned bundle is mandatory and both prerequisite modes
#   activate it. `fail` forbids building a missing privileged prerequisite; it
#   does not make the target-user setup phase read-only. Both paths are offline
#   from user npm.
# - Non-MDM: Node/npm remain optional and `npm ci` remains best-effort.
# - Dry-run: logs the matching activation/install action without executing it.
# Covers fresh, fresh-with-existing, and update paths (called once after deploy).
# ---------------------------------------------------------------------------
_WCE_MDM_PACKAGE_SHA256="e63fb86cb553a034ecafd4ca11334d317b8b5d115775daa728e56c3bf5b1749c"
_WCE_MDM_LOCK_SHA256="f39ea3b4028710e986afb1c423b7895845e0d41839521e6cee866ed37cdb33cd"

_wce_mdm_trust_base() {
  printf '%s' "/Library/Application Support"
}

_wce_mdm_expected_owner_uid() {
  printf '0'
}

_wce_mdm_expected_owner_gid() {
  printf '0'
}

_wce_mdm_stat_gid() {
  if [[ "$(/usr/bin/uname -s 2>/dev/null)" == Darwin ]]; then
    /usr/bin/stat -f '%g' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%g' "$1" 2>/dev/null
  fi
}

_wce_mdm_expected_bundle() {
  local arch
  arch="$(_mdm_current_darwin_arch)" || return 1
  printf '%s' \
    "/Library/Application Support/ClaudeCodeStarterKit/runtime/web-content-extraction/node-v24.18.0-npm-v11.16.0-darwin-${arch}/${_WCE_MDM_PACKAGE_SHA256}-${_WCE_MDM_LOCK_SHA256}"
}

_wce_mdm_acl_safe() {
  local path="$1" listing first permissions
  [[ "$(/usr/bin/uname -s 2>/dev/null)" == Darwin ]] || return 0
  listing="$(LC_ALL=C /bin/ls -lde "$path" 2>/dev/null)" || return 1
  first="${listing%%$'\n'*}"
  permissions="${first%%[[:space:]]*}"
  [[ "$first" == *[[:space:]]* \
    && "$permissions" =~ ^[-bcdlps][rwxStTs-]{9}[@+]?$ \
    && "$permissions" != *+* \
    && "$listing" != *$'\n'* ]]
}

_wce_mdm_trusted_bundle_dirs() {
  local supplied="$1" target="$2" dir base uid gid
  local -a system_dirs managed_dirs
  base="$(_wce_mdm_trust_base)" || return 1
  uid="$(_wce_mdm_expected_owner_uid)" || return 1
  gid="$(_wce_mdm_expected_owner_gid)" || return 1
  [[ "$base" == /* && "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] \
    || return 1
  case "$supplied" in
    "$base/ClaudeCodeStarterKit/runtime/web-content-extraction/"*) ;;
    *) return 1 ;;
  esac
  system_dirs=("$base")
  managed_dirs=(
    "$base/ClaudeCodeStarterKit"
    "$base/ClaudeCodeStarterKit/runtime"
    "$base/ClaudeCodeStarterKit/runtime/web-content-extraction"
    "${supplied%/*}"
    "$supplied"
    "$target"
  )
  if [[ "$base" == "/Library/Application Support" ]]; then
    system_dirs=(/ /Library "$base")
  fi
  # macOS owns /Library/Application Support as root:admin on standard hosts.
  # System ancestors are a root-owned safe trust chain, while every kit-
  # managed directory below it is fixed to root:wheel.
  for dir in "${system_dirs[@]}"; do
    _prereq_canonical_real_dir "$dir" || return 1
    [[ "$(_prereq_stat_uid "$dir")" == "$uid" ]] || return 1
    _prereq_mode_is "$dir" 755 || return 1
    _wce_mdm_acl_safe "$dir" || return 1
  done
  for dir in "${managed_dirs[@]}"; do
    _prereq_canonical_real_dir "$dir" || return 1
    [[ "$(_prereq_stat_uid "$dir")" == "$uid" \
      && "$(_wce_mdm_stat_gid "$dir")" == "$gid" ]] || return 1
    _prereq_mode_is "$dir" 755 || return 1
    _wce_mdm_acl_safe "$dir" || return 1
  done
}

_wce_validate_mdm_bundle_tree() { # <bundle> <arch>
  local bundle="$1" arch="$2" uid gid
  uid="$(_wce_mdm_expected_owner_uid)" || return 1
  gid="$(_wce_mdm_expected_owner_gid)" || return 1
  [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ \
    && ( "$arch" == arm64 || "$arch" == x64 ) \
    && -x /usr/bin/python3 && ! -L /usr/bin/python3 ]] || return 1
  /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    /usr/bin/python3 -I -B - "$bundle" "$uid" "$gid" "$arch" \
      "$_WCE_MDM_PACKAGE_SHA256" "$_WCE_MDM_LOCK_SHA256" <<'PY'
import ctypes
import errno
import json
import os
import re
import stat
import sys

root, uid_text, gid_text, arch, package_digest, lock_digest = sys.argv[1:]
uid, gid = int(uid_text), int(gid_text)
marker_name = ".claude-code-starter-kit-wce-runtime.json"
expected_top = {marker_name, "package.json", "package-lock.json", "node_modules"}
allowed_xattrs = {"com.apple.provenance"}
name_part = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._~-]*$")
count = 0
libc = ctypes.CDLL(None, use_errno=True)


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def package_parts(name):
    if not isinstance(name, str) or not name or "\\" in name:
        raise ValueError("invalid dependency name")
    parts = name.split("/")
    if name.startswith("@"):
        if (len(parts) != 2 or not name_part.fullmatch(parts[0][1:])
                or not name_part.fullmatch(parts[1])):
            raise ValueError("invalid scoped dependency")
    elif len(parts) != 1 or not name_part.fullmatch(parts[0]):
        raise ValueError("invalid dependency path")
    return parts


def xattrs_allowed(path):
    raw = os.fsencode(path)
    ctypes.set_errno(0)
    if sys.platform == "darwin":
        call = libc.listxattr
        call.argtypes = [ctypes.c_char_p, ctypes.c_void_p,
                         ctypes.c_size_t, ctypes.c_int]
        call.restype = ctypes.c_ssize_t
        size = call(raw, None, 0, 1)  # XATTR_NOFOLLOW
        if size < 0:
            raise OSError(ctypes.get_errno() or errno.EIO, "listxattr")
        if not size:
            return True
        buffer = ctypes.create_string_buffer(size)
        actual = call(raw, buffer, size, 1)
    else:
        call = libc.llistxattr
        call.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t]
        call.restype = ctypes.c_ssize_t
        size = call(raw, None, 0)
        if size < 0:
            raise OSError(ctypes.get_errno() or errno.EIO, "listxattr")
        if not size:
            return True
        buffer = ctypes.create_string_buffer(size)
        actual = call(raw, buffer, size)
    if actual != size:
        raise OSError(ctypes.get_errno() or errno.EIO, "listxattr")
    names = {os.fsdecode(name) for name in bytes(buffer[:actual]).split(b"\0")
             if name}
    return names.issubset(allowed_xattrs)


def metadata(path, relative):
    global count
    value = os.lstat(path)
    count += 1
    if count > 100000 or value.st_uid != uid or value.st_gid != gid:
        raise ValueError("unsafe bundle ownership or size")
    depth = 0 if not relative else relative.count(os.sep) + 1
    if depth > 256:
        raise ValueError("bundle path is too deep")
    mode = stat.S_IMODE(value.st_mode)
    if stat.S_ISDIR(value.st_mode):
        if mode != 0o755:
            raise ValueError("invalid directory mode")
    elif stat.S_ISREG(value.st_mode):
        if value.st_nlink != 1 or mode not in (0o644, 0o755):
            raise ValueError("invalid regular file metadata")
    else:
        raise ValueError("bundle links and special files are forbidden")
    if not xattrs_allowed(path):
        raise ValueError("unsupported bundle xattr")


try:
    if set(os.listdir(root)) != expected_top:
        raise ValueError("bundle inventory mismatch")
    for directory, directories, files in os.walk(root, topdown=True,
                                                  followlinks=False):
        relative_dir = os.path.relpath(directory, root)
        metadata(directory, "" if relative_dir == "." else relative_dir)
        for name in directories + files:
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, root)
            metadata(path, relative)

    for name in (marker_name, "package.json", "package-lock.json"):
        value = os.lstat(os.path.join(root, name))
        if not stat.S_ISREG(value.st_mode) or stat.S_IMODE(value.st_mode) != 0o644:
            raise ValueError("invalid fixed-file mode")

    with open(os.path.join(root, "package.json"), "r", encoding="utf-8",
              errors="strict") as handle:
        package = json.load(handle, object_pairs_hook=strict_object)
    dependencies = package.get("dependencies") if isinstance(package, dict) else None
    if not isinstance(dependencies, dict) or not dependencies:
        raise ValueError("missing direct dependencies")
    for name, version in dependencies.items():
        if not isinstance(version, str) or not version:
            raise ValueError("invalid dependency version")
        dependency = os.path.join(root, "node_modules", *package_parts(name))
        manifest = os.path.join(dependency, "package.json")
        dependency_value = os.lstat(dependency)
        manifest_value = os.lstat(manifest)
        if (not stat.S_ISDIR(dependency_value.st_mode)
                or not stat.S_ISREG(manifest_value.st_mode)
                or manifest_value.st_nlink != 1):
            raise ValueError("direct dependency is missing")

    expected_marker = (
        f'{{"arch":"{arch}","lock_sha256":"{lock_digest}",'
        '"node_version":"v24.18.0","npm_version":"11.16.0",'
        f'"package_sha256":"{package_digest}",'
        '"registry":"https://registry.npmjs.org/","schema_version":1}\n'
    ).encode("ascii")
    with open(os.path.join(root, marker_name), "rb", buffering=0) as handle:
        actual_marker = handle.read(len(expected_marker) + 1)
    if actual_marker != expected_marker:
        raise ValueError("provenance marker mismatch")
except (OSError, UnicodeError, ValueError, TypeError, json.JSONDecodeError,
        ctypes.ArgumentError):
    raise SystemExit(1)
PY
}

_wce_validate_mdm_bundle() {
  local skill_dir="$1" supplied="${KIT_MDM_WCE_RUNTIME_BUNDLE:-}"
  local expected target arch
  expected="$(_wce_mdm_expected_bundle)" || return 1
  [[ "$supplied" == "$expected" && "$supplied" == /* \
    && ! "$supplied" =~ [[:cntrl:]] ]] || return 1
  [[ -f "$skill_dir/package.json" && ! -L "$skill_dir/package.json" \
    && -f "$skill_dir/package-lock.json" && ! -L "$skill_dir/package-lock.json" \
    && "$(_prereq_sha256_file "$skill_dir/package.json")" \
      == "$_WCE_MDM_PACKAGE_SHA256" \
    && "$(_prereq_sha256_file "$skill_dir/package-lock.json")" \
      == "$_WCE_MDM_LOCK_SHA256" ]] || return 1

  target="$supplied/node_modules"
  _wce_mdm_trusted_bundle_dirs "$supplied" "$target" || return 1
  [[ "$(_prereq_sha256_file "$supplied/package.json")" \
    == "$_WCE_MDM_PACKAGE_SHA256" \
    && "$(_prereq_sha256_file "$supplied/package-lock.json")" \
      == "$_WCE_MDM_LOCK_SHA256" ]] || return 1
  _prereq_tree_acl_safe "$supplied" || return 1
  arch="$(_mdm_current_darwin_arch)" || return 1
  _wce_validate_mdm_bundle_tree "$supplied" "$arch"
}

_wce_validate_mdm_activation() {
  local skill_dir="$1" bundle="${KIT_MDM_WCE_RUNTIME_BUNDLE:-}"
  local link="$skill_dir/node_modules" target="$bundle/node_modules"
  local canonical uid
  _wce_validate_mdm_bundle "$skill_dir" || return 1
  [[ -L "$link" ]] || return 1
  _prereq_symlink_value_exact "$link" "$target" || return 1
  _prereq_file_has_one_link "$link" || return 1
  uid="$(/usr/bin/id -u 2>/dev/null)" || return 1
  [[ "$(_prereq_stat_uid "$link")" == "$uid" ]] || return 1
  _wce_mdm_acl_safe "$link" || return 1
  canonical="$(builtin cd -P "$link" 2>/dev/null && pwd -P)" || return 1
  [[ "$canonical" == "$target" ]]
}

_wce_mdm_activation_leaf_replaceable() { # <node_modules leaf>
  local path="$1" uid mode
  [[ -e "$path" || -L "$path" ]] || return 0
  uid="$(/usr/bin/id -u 2>/dev/null)" || return 1
  [[ "$(_prereq_stat_uid "$path")" == "$uid" ]] || return 1
  _wce_mdm_acl_safe "$path" || return 1
  if [[ -L "$path" ]]; then
    # Symlink permission bits are not portable (Linux commonly reports 0777)
    # and do not control traversal. Owner, ACL, and link count are the leaf
    # replacement boundary for this case.
    _prereq_file_has_one_link "$path"
    return
  elif [[ -d "$path" && ! -L "$path" ]]; then
    # A normal non-MDM install creates a real npm dependency directory here.
    # It is eligible for an atomic, non-destructive migration only when this
    # user owns the leaf and its mode/ACL do not grant another writer access.
    :
  elif [[ -f "$path" && ! -L "$path" ]]; then
    _prereq_file_has_one_link "$path" || return 1
  else
    # Special inodes are never activation or migration inputs.
    return 1
  fi
  mode="$(_prereq_stat_mode "$path")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 8#022) == 0 ))
}

_wce_activate_mdm_runtime() {
  local skill_dir="$1" bundle="${KIT_MDM_WCE_RUNTIME_BUNDLE:-}"
  local target="$bundle/node_modules" link="$skill_dir/node_modules"
  local candidate preserve_token
  _wce_validate_mdm_bundle "$skill_dir" || return 1
  _prereq_canonical_real_dir "$skill_dir" || return 1
  # A correct activation is already the desired state. Besides avoiding an
  # unnecessary gap, this preserves the symlink inode across idempotent MDM
  # reconciliation and keeps fail/auto behavior symmetric.
  if _wce_validate_mdm_activation "$skill_dir"; then
    return 0
  fi
  _wce_mdm_activation_leaf_replaceable "$link" || return 1
  candidate="$(/usr/bin/mktemp "$skill_dir/.node-modules.pre-mdm.XXXXXX")" \
    || return 1
  /bin/rm -f "$candidate" || return 1
  /bin/ln -s "$target" "$candidate" || return 1
  _mdm_atomic_replace_component_leaf \
    "$candidate" "$link" link-preserve-dir || return 1
  preserve_token="${_MDM_COMPONENT_PRESERVE_TOKEN:-}"
  if ! _wce_validate_mdm_activation "$skill_dir"; then
    # Reverse only the exact exchange issued above. If either name was changed
    # concurrently, the rollback helper leaves both path objects untouched.
    _mdm_rollback_preserved_component_leaf \
      "$candidate" "$link" "$preserve_token" >/dev/null 2>&1 || true
    return 1
  fi
  _mdm_finalize_preserved_component_leaf \
    "$candidate" "$link" "$preserve_token" || return 1
  if [[ -e "$candidate" || -L "$candidate" ]]; then
    info "Preserved pre-MDM web-content-extraction dependencies at: $candidate"
  fi
  ok "${STR_WCE_NPM_DONE:-web-content-extraction dependencies installed}"
}

_wce_run_non_mdm_npm_ci() { # <skill-dir>
  local skill_dir="$1"
  (
    builtin cd "$skill_dir" \
      && npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
        >"$skill_dir/logs/install.log" 2>&1
  )
}

maybe_install_web_content_deps() {
  is_true "${INSTALL_SKILLS:-false}" || return 0
  if declare -F _fresh_wce_pair_is_skipped >/dev/null 2>&1 \
    && _fresh_wce_pair_is_skipped; then
    return 0
  fi
  local skill_dir="$CLAUDE_DIR/skills/web-content-extraction"
  [[ -f "$skill_dir/package.json" ]] || return 0

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    if _deploy_mdm_managed; then
      _dryrun_log "EXTERNAL" "web-content-extraction" \
        "activate the pinned root-owned dependency runtime"
    else
      _dryrun_log "EXTERNAL" "web-content-extraction" \
        "npm ci --omit=dev (in ~/.claude/skills/web-content-extraction)"
    fi
    return 0
  fi

  if _deploy_mdm_managed; then
    _wce_activate_mdm_runtime "$skill_dir" || return 1
    return 0
  fi

  # Test harness opt-out for the ordinary best-effort install path only. MDM
  # mode must never permit an environment flag to bypass its required state.
  [[ -n "${WCE_SKIP_NPM_INSTALL:-}" ]] && return 0

  if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
    warn "${STR_WCE_NODE_MISSING:-Node.js not found — web-content-extraction URL/PDF features are disabled until dependencies are installed.}"
    info "${STR_WCE_NODE_HINT:-Install Node.js 22.19+ then run: (cd ~/.claude/skills/web-content-extraction && npm ci --omit=dev)}"
    return 0
  fi

  info "${STR_WCE_NPM_INSTALLING:-Installing web-content-extraction skill dependencies...}"
  mkdir -p "$skill_dir/logs" || return 1
  # Use `npm ci` to install strictly from the committed package-lock.json
  # (reproducible, version-pinned — matches update-deps.mjs's rollback path).
  # Serialize it with both the runtime updater and kit package-pair merge:
  # npm ci replaces node_modules, while update-deps.mjs runs npm install/tests.
  # Output is kept in the skill's logs/ for debuggability instead of discarded.
  if ! declare -F _wce_with_runtime_update_lock >/dev/null 2>&1; then
    warn "web-content-extraction dependency lock helper is unavailable; retry setup"
    return 1
  fi
  local npm_rc=0
  _wce_with_runtime_update_lock \
    "$skill_dir" _wce_run_non_mdm_npm_ci "$skill_dir" || npm_rc=$?
  case "$npm_rc" in
    0)
      ok "${STR_WCE_NPM_DONE:-web-content-extraction dependencies installed}"
      ;;
    74)
      warn "web-content-extraction dependency lock could not be released; retry setup"
      return 1
      ;;
    75)
      warn "web-content-extraction dependency update is already active; retry setup after it finishes"
      return 1
      ;;
    129|130|143)
      return "$npm_rc"
      ;;
    *)
      warn "${STR_WCE_NPM_FAILED:-npm install failed for web-content-extraction; skill scripts may not run until dependencies are installed.}"
      info "  → ~/.claude/skills/web-content-extraction/logs/install.log"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Build CLAUDE.md
# ---------------------------------------------------------------------------
build_claude_md() {
  local out="$CLAUDE_DIR/CLAUDE.md"
  if _deploy_mdm_managed; then
    local tmp_out
    tmp_out="$(mktemp)" || return 1
    _SETUP_TMP_FILES+=("$tmp_out")
    build_claude_md_to_file "$tmp_out" || return 1
    _mdm_atomic_replace_managed_file "$tmp_out" "$out" || return 1
  else
    build_claude_md_to_file "$out" || return 1
  fi
  ok "Built CLAUDE.md"
}

build_claude_md_to_file() {
  local out="$1"
  local lang="${LANGUAGE:-en}"
  local base="$PROJECT_DIR/i18n/${lang}/CLAUDE.md.base"

  cp -a "$base" "$out" || return 1

  # Spec Kit pointer — only when commands (incl. /spec-kit-init) are installed
  if is_true "${INSTALL_COMMANDS:-false}"; then
    local sk_partial="$PROJECT_DIR/i18n/${lang}/partials/spec-kit.md"
    inject_feature "$out" "spec-kit" "$sk_partial" || return 1
  fi

  # Web content extraction standard rule — only when the skill is installed
  if is_true "${INSTALL_SKILLS:-false}"; then
    local wce_partial="$PROJECT_DIR/i18n/${lang}/partials/web-content-extraction.md"
    inject_feature "$out" "web-content-extraction" "$wce_partial" || return 1
  fi

  if is_true "$ENABLE_CODEX_PLUGIN"; then
    local partial="$PROJECT_DIR/features/codex-plugin/CLAUDE.md.partial.${lang}"
    inject_feature "$out" "codex-plugin" "$partial" || return 1
  fi

  remove_unresolved "$out" "delete" || return 1
}

# ---------------------------------------------------------------------------
# Build settings.json
# ---------------------------------------------------------------------------
# build_settings_file - Registry-based settings.json builder (unified)
#
# Usage: build_settings_file <output_path>
#
# Uses _FEATURE_ORDER and _FEATURE_FLAGS from lib/features.sh to iterate
# Assertion: safety-net must be _FEATURE_ORDER[0].
# ---------------------------------------------------------------------------
build_settings_file() {
  local out="$1"
  local base="$PROJECT_DIR/config/settings-base.json"
  local permissions="$PROJECT_DIR/config/permissions.json"

  local hook_fragments=()
  local tmp_files=()

  # Prime the semver cache in THIS shell: the fragment helpers below run in
  # $(...) subshells, so cache writes made there never persist and `claude
  # --version` would otherwise be spawned once per fragment.
  _claude_cli_semver >/dev/null 2>&1 || true

  # Assertion: safety-net must be first in _FEATURE_ORDER
  if [[ "${_FEATURE_ORDER[0]}" != "safety-net" ]]; then
    error "FATAL: safety-net must be first in _FEATURE_ORDER (got: ${_FEATURE_ORDER[0]:-empty})"
    return 1
  fi

  # Registry-driven hook fragment collection
  local name flag
  for name in "${_FEATURE_ORDER[@]}"; do
    flag="${_FEATURE_FLAGS[$name]:-}"
    if [[ -z "$flag" ]]; then
      error "FATAL: _FEATURE_FLAGS[$name] is empty — registry inconsistency"
      return 1
    fi
    is_true "${!flag:-false}" || continue
    # web-content-update's hook targets a script inside the skill dir; only emit
    # it when the skill is actually installed (avoids a dangling SessionStart hook
    # if the flag is enabled via CLI/hand-edited config without INSTALL_SKILLS).
    if [[ "$name" == "web-content-update" ]] && ! is_true "${INSTALL_SKILLS:-false}"; then
      continue
    fi
    local hooks_json="$PROJECT_DIR/features/$name/hooks.json"
    if [[ "$name" == "auto-update" ]]; then
      hooks_json="$(_auto_update_hooks_fragment)"
    elif [[ "$name" == "pr-creation-log" ]]; then
      hooks_json="$(_pr_creation_log_hooks_fragment)"
    fi
    [[ -f "$hooks_json" ]] && hook_fragments+=("$hooks_json")
  done

  build_settings_json "$base" "$permissions" "$out" ${hook_fragments[@]+"${hook_fragments[@]}"} || return 1
  apply_settings_preferences "$out" || return 1
  replace_home_path "$out" || return 1

  # Clean up temp files
  if [[ ${#tmp_files[@]} -gt 0 ]]; then
    rm -f "${tmp_files[@]}" || return 1
  fi
}

_build_settings_managed_file() {
  local out="$1"
  if ! _deploy_mdm_managed; then
    build_settings_file "$out" || return 1
    return
  fi

  local tmp_out
  tmp_out="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$tmp_out")
  build_settings_file "$tmp_out" || return 1
  _mdm_atomic_replace_managed_file "$tmp_out" "$out" || return 1
}

_compose_migrated_claude_md() {
  local new_kit_file="$1"
  local existing_file="$2"
  local kit_section user_heading
  kit_section="$(_extract_kit_section "$new_kit_file")" || return 1
  user_heading="$(_user_section_heading)" || return 1
  printf '%s\n' "$kit_section" || return 1
  printf '\n%s\n\n' "$user_heading" || return 1
  cat "$existing_file" || return 1
  printf '\n' || return 1
}

# _claude_md_migration_prompt <new_claude_md> <target>
#
# Interactive [M]erge / [D]iff / [S]kip loop for migrating a marker-less
# CLAUDE.md. Replies are read from ${_TTY_INPUT:-/dev/tty} (tests may inject
# a file). Default (no tty / unrecognized reply) is skip, which registers
# <target> in _FRESH_SKIPPED_FILES.
_claude_md_migration_prompt() {
  local new_claude_md="$1"
  local target="$2"

  while true; do
    printf "  %s " "$STR_CLAUDEMD_MIGRATION_PROMPT" >&2
    local reply=""
    if read -r reply < "${_TTY_INPUT:-/dev/tty}" 2>/dev/null; then true; else reply="s"; fi
    case "$reply" in
      [Mm]*)
        local merged
        merged="$(mktemp)" || return 1
        _SETUP_TMP_FILES+=("$merged")
        _compose_migrated_claude_md "$new_claude_md" "$target" > "$merged" || return 1
        mv "$merged" "$target" || return 1
        ok "CLAUDE.md upgraded — your content preserved in user section"
        return
        ;;
      [Dd]*)
        # Show what the merged result would look like
        local preview
        preview="$(mktemp)" || return 1
        _SETUP_TMP_FILES+=("$preview")
        _compose_migrated_claude_md "$new_claude_md" "$target" > "$preview" || return 1
        diff -u "$target" "$preview" 2>/dev/null >&2 || true
        printf "\n" >&2
        continue
        ;;
      *)
        _FRESH_SKIPPED_FILES+=("$target")
        ok "CLAUDE.md: $STR_FRESH_SKIPPED"
        return
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Section-aware CLAUDE.md deployment for fresh install with existing file
# ---------------------------------------------------------------------------
# _build_claude_md_safe
#
# - No existing file → build normally (kit + user skeleton)
# - Existing with markers → replace kit section only
# - Existing without markers (migration) → wrap existing as user section
_build_claude_md_safe() {
  local target="$CLAUDE_DIR/CLAUDE.md"

  if _deploy_mdm_managed; then
    _mdm_distribution_target_is_safe "$target" || return 1
  fi

  if [[ ! -f "$target" ]]; then
    build_claude_md || return 1
    return
  fi

  # Generate new kit version to temp
  local new_claude_md
  new_claude_md="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$new_claude_md")
  build_claude_md_to_file "$new_claude_md" || return 1

  if _has_kit_markers "$target"; then
    # Existing file has markers → replace kit section, preserve user section
    local new_kit_section
    new_kit_section="$(mktemp)" || return 1
    _SETUP_TMP_FILES+=("$new_kit_section")
    _extract_kit_section "$new_claude_md" > "$new_kit_section" || return 1
    _replace_kit_section "$target" "$new_kit_section" || return 1
    ok "$STR_CLAUDEMD_KIT_UPDATED"
    info "$STR_CLAUDEMD_USER_PRESERVED"
    return
  fi

  # No markers — detect old kit-generated file
  local old_kit_output user_heading
  old_kit_output="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$old_kit_output")
  user_heading="$(_user_section_heading)" || return 1
  _awk \
    -v begin='<!-- BEGIN STARTER-KIT-MANAGED -->' \
    -v end='<!-- END STARTER-KIT-MANAGED -->' \
    -v heading="$user_heading" '
      index($0, begin) || index($0, end) || index($0, heading) \
        || $0 ~ /^<!-- .*custom instructions/ { next }
      { print }
    ' "$new_claude_md" > "$old_kit_output" || return 1

  # Compare ignoring blank lines: exact match = no user edits
  local current_trimmed old_kit_trimmed
  current_trimmed="$(_sed '/^[[:space:]]*$/d' "$target")" || return 1
  old_kit_trimmed="$(_sed '/^[[:space:]]*$/d' "$old_kit_output")" || return 1

  if [[ "$current_trimmed" == "$old_kit_trimmed" ]]; then
    if _deploy_mdm_managed; then
      _mdm_atomic_replace_managed_file "$new_claude_md" "$target" || return 1
    else
      cp -a "$new_claude_md" "$target" || return 1
    fi
    ok "CLAUDE.md upgraded to section-aware format"
    return
  fi

  # MDM remediation must converge to the marker-managed document expected by
  # the independent renderer. Preserve an existing marker-less document as the
  # user section instead of taking the normal non-interactive "skip" path,
  # which would omit CLAUDE.md from the manifest and make attestation fail.
  if _deploy_mdm_managed; then
    local merged
    merged="$(mktemp)" || return 1
    _SETUP_TMP_FILES+=("$merged")
    _compose_migrated_claude_md "$new_claude_md" "$target" > "$merged" || return 1
    _mdm_atomic_replace_managed_file "$merged" "$target" || return 1
    ok "CLAUDE.md upgraded — existing content preserved in user section"
    return
  fi

  # Differences found (additions, deletions, or edits) → user customization
  if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]]; then
    _FRESH_SKIPPED_FILES+=("$target")
    warn "$STR_CLAUDEMD_MIGRATION_SKIP"
    return
  fi

  warn "$STR_CLAUDEMD_MIGRATION"
  info "Differences from kit template:"
  diff -u "$old_kit_output" "$target" 2>/dev/null >&2 || true
  printf "\n" >&2

  _claude_md_migration_prompt "$new_claude_md" "$target"
}

# _build_settings_safe
#
# Merges existing settings.json with kit-generated settings using
# _merge_settings_bootstrap(). If no existing file, builds normally.
_build_settings_safe() {
  local target="$CLAUDE_DIR/settings.json"

  if _deploy_mdm_managed; then
    _mdm_distribution_target_is_safe "$target" || return 1
  fi

  if [[ ! -f "$target" ]]; then
    _build_settings_managed_file "$target" || return 1
    return
  fi

  # Generate kit settings to temp file
  local new_settings
  new_settings="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$new_settings")
  build_settings_file "$new_settings" || return 1

  info "$STR_FRESH_MERGE_SETTINGS"
  _merge_settings_bootstrap "$target" "$new_settings" "$target" || return 1
  ok "$STR_FRESH_MERGE_SETTINGS_DONE"
}

# _deploy_fresh_with_existing
#
# Merge-aware deployment for users with existing ~/.claude files
# but no starter-kit manifest (first-time kit users).
_deploy_fresh_with_existing() {
  info "$STR_EXISTING_CLAUDE_MERGE_NOTE"
  printf "\n"

  local preserve_wce_pair=false
  _deploy_mdm_managed || preserve_wce_pair=true

  _copy_dir_safe "$INSTALL_AGENTS"  "$PROJECT_DIR/agents"   "$CLAUDE_DIR/agents" || return 1
  _copy_dir_safe "$INSTALL_RULES"   "$PROJECT_DIR/rules"    "$CLAUDE_DIR/rules" || return 1
  _copy_dir_safe "$INSTALL_COMMANDS" "$PROJECT_DIR/commands" "$CLAUDE_DIR/commands" || return 1
  _copy_dir_safe "$INSTALL_SKILLS" "$PROJECT_DIR/skills" \
    "$CLAUDE_DIR/skills" "$preserve_wce_pair" || return 1

  _build_claude_md_safe || return 1
  _build_settings_safe || return 1
  if _deploy_mdm_managed; then
    deploy_hook_scripts "simple" || return 1
  else
    deploy_hook_scripts "merge-aware" || return 1
  fi
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
write_manifest() {
  local manifest="$CLAUDE_DIR/.starter-kit-manifest.json"
  local mdm_managed=false
  local policy_sha256=""
  if _deploy_mdm_managed; then
    mdm_managed=true
    policy_sha256="${KIT_MDM_POLICY_SHA256:-}"
    [[ "$policy_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  fi
  if [[ "$mdm_managed" != true && ( -e "$manifest" || -L "$manifest" ) ]]; then
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
  fi

  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")" || return 1

  local kit_version
  kit_version="$(git -C "$PROJECT_DIR" describe --tags --always 2>/dev/null || echo "unknown")"

  local kit_commit
  kit_commit="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"

  # Only track files that the starter kit itself manages.
  local files_json
  files_json="$(managed_files_json)" || return 1
  local cleanup_paths
  cleanup_paths="$(cleanup_paths_json)" || return 1
  local mdm_absent_files='[]'
  if [[ "$mdm_managed" == true ]]; then
    mdm_absent_files="$(mdm_absent_files_json)" || return 1
  fi

  local manifest_out
  if [[ "$mdm_managed" == true ]]; then
    manifest_out="$(mktemp)" || return 1
  else
    manifest_out="$(mktemp "${manifest}.tmp.XXXXXX")" || return 1
  fi
  _SETUP_TMP_FILES+=("$manifest_out")

  if ! jq -n \
    --arg version "2" \
    --arg ts "$ts" \
    --arg kit_version "$kit_version" \
    --arg kit_commit "$kit_commit" \
    --arg profile "${PROFILE:-}" \
    --arg language "${LANGUAGE:-}" \
    --arg editor "${EDITOR_CHOICE:-}" \
    --arg commit_attribution "${COMMIT_ATTRIBUTION:-}" \
    --arg new_init "${ENABLE_NEW_INIT:-}" \
    --arg plugins "${SELECTED_PLUGINS:-}" \
    --arg codex_plugin "${ENABLE_CODEX_PLUGIN:-false}" \
    --argjson files "$files_json" \
    --argjson cleanup_paths "$cleanup_paths" \
    --argjson mdm_absent_files "$mdm_absent_files" \
    --argjson mdm_managed "$mdm_managed" \
    --arg policy_sha256 "$policy_sha256" \
    --arg snapshot_dir "$CLAUDE_DIR/.starter-kit-snapshot" \
    --arg claude_dir "$CLAUDE_DIR" \
    '({
      version: $version,
      timestamp: $ts,
      kit_version: $kit_version,
      kit_commit: $kit_commit,
      profile: $profile,
      language: $language,
      editor: $editor,
      commit_attribution: $commit_attribution,
      new_init: $new_init,
      plugins: $plugins,
      codex_plugin: $codex_plugin,
      files: $files,
      cleanup_paths: $cleanup_paths,
      mdm_absent_files: $mdm_absent_files,
      mdm_managed: $mdm_managed,
      snapshot_dir: $snapshot_dir,
      claude_dir: $claude_dir
    } + if $mdm_managed then {
      policy_sha256: $policy_sha256
    } else {} end)' > "$manifest_out"; then
    rm -f "$manifest_out"
    return 1
  fi

  if [[ "$mdm_managed" == true ]]; then
    _mdm_atomic_replace_authoritative_root_file \
      "$manifest_out" "$manifest" 600 \
      || { rm -f "$manifest_out"; return 1; }
  else
    mv -f "$manifest_out" "$manifest" \
      || { rm -f "$manifest_out"; return 1; }
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _offer_dryrun_preview - Offer interactive dry-run before deploying
#
# Only called when existing files could be affected. Clean-slate installs
# skip this entirely. The message can be customized via the first argument.
#
# NOTE: Uses $0 to re-exec setup.sh — this is intentional even though this
# function lives in deploy.sh. $0 always points to setup.sh (the entry point).
# ---------------------------------------------------------------------------
_offer_dryrun_preview() {
  local message="${1:-$STR_DRYRUN_OFFER}"

  # Skip if already in dry-run, or non-interactive (merge prompts disabled)
  [[ "${DRY_RUN:-false}" == "true" ]] && return 0
  [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]] && return 0

  printf "\n"
  info "$message"
  printf "  [Y]es / [N]o ? " >&2
  local _dr_offer=""
  if read -r _dr_offer < /dev/tty 2>/dev/null; then true; else _dr_offer="n"; fi
  case "$_dr_offer" in
    [Yy]*)
      info "Preview requested. Launching simulation..."
      info "$STR_DRYRUN_RUNNING"
      printf "\n"

      # Save current wizard state to temp config so subprocess inherits
      # all ENABLE_*, INSTALL_*, plugins, etc. exactly as chosen.
      local _dr_config
      _dr_config="$(mktemp)" || return 1
      _SETUP_TMP_FILES+=("$_dr_config")
      save_config "$_dr_config" || return 1

      # Build subprocess args
      local _dr_args=("--non-interactive" "--dry-run" "--config=$_dr_config")
      if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
        _dr_args+=("--update")
      fi

      DRY_RUN="true" bash "$0" "${_dr_args[@]}" || return 1
      printf "\n"
      info "Preview complete. Continue with actual update?"
      info "$STR_DRYRUN_PROCEED"
      printf "  [Y]es / [N]o ? " >&2
      local _dr_proceed=""
      if read -r _dr_proceed < /dev/tty 2>/dev/null; then true; else _dr_proceed="n"; fi
      case "$_dr_proceed" in
        [Yy]*) ;;
        *)
          info "Setup canceled."
          exit 0
          ;;
      esac
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _has_user_customizations - Check if user modified any kit-managed files
#
# Compares snapshot (what kit deployed) vs current (what's on disk).
# Returns 0 if at least one kit-managed file was modified by the user.
# ---------------------------------------------------------------------------
_has_user_customizations() {
  local claude_dir="$1"
  local snapshot_dir="${claude_dir}/.starter-kit-snapshot"

  [[ -d "$snapshot_dir" ]] || return 0  # no snapshot = can't tell, assume yes

  local snapshot_list snap_file
  snapshot_list="$(mktemp)" || return 0
  _SETUP_TMP_FILES+=("$snapshot_list")
  # Enumeration errors are conservative: if the snapshot cannot be read in
  # full, never claim that no user customizations exist.
  find "$snapshot_dir" -type f -print0 2>/dev/null > "$snapshot_list" \
    || return 0
  while IFS= read -r -d '' snap_file; do
    local rel_path="${snap_file#"$snapshot_dir"/}"
    local current_file="${claude_dir}/${rel_path}"
    if [[ ! -f "$current_file" ]]; then
      return 0  # user deleted a kit-managed file
    fi
    if _file_changed "$snap_file" "$current_file"; then
      return 0  # user modified a kit-managed file
    fi
  done < "$snapshot_list"

  return 1  # no user modifications detected
}
