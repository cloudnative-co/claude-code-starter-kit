#!/bin/bash
# auto-update.sh - Check for and apply starter kit updates on session hooks
set -euo pipefail

KIT_DIR="${KIT_DIR:-${HOME}/.claude-starter-kit}"
LOCK_DIR="${LOCK_DIR:-${HOME}/.claude/.starter-kit-update.lock}"
BACKUP_PATH_FILE="${BACKUP_PATH_FILE:-$HOME/.claude/.starter-kit-last-backup}"
STATUS_FILE="${STATUS_FILE:-$HOME/.claude/.starter-kit-update-status}"
LEGACY_CACHE_FILE="${LEGACY_CACHE_FILE:-$HOME/.claude/.starter-kit-update-cache}"
LEGACY_CACHE_TTL="${LEGACY_CACHE_TTL:-86400}"
MIN_ASYNC_VERSION="${MIN_ASYNC_VERSION:-2.1.89}"
AUTO_UPDATE_HOOK="${AUTO_UPDATE_HOOK:-SessionStart}"

_LOCK_HELD=false

_auto_update_now() {
  date +%s
}

_auto_update_version_ge() {
  local lhs="${1:-0}" rhs="${2:-0}"
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

_auto_update_claude_semver() {
  local raw=""
  command -v claude >/dev/null 2>&1 || return 1
  raw="$(claude --version 2>/dev/null | head -1)"
  [[ "$raw" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

_auto_update_supports_async_hooks() {
  local current=""
  current="$(_auto_update_claude_semver 2>/dev/null || true)"
  [[ -n "$current" ]] || return 1
  _auto_update_version_ge "$current" "$MIN_ASYNC_VERSION"
}

_auto_update_log() {
  printf '%s\n' "$*" >&2
}

_auto_update_clear_status() {
  rm -f "$STATUS_FILE" 2>/dev/null || true
}

_auto_update_write_status() {
  local message="${1:-auto-update failed}"
  mkdir -p "$(dirname "$STATUS_FILE")"
  printf '%s\n' "$message" > "$STATUS_FILE"
}

_auto_update_emit_previous_failure() {
  local message=""
  [[ -f "$STATUS_FILE" ]] || return 0
  message="$(head -1 "$STATUS_FILE" 2>/dev/null || true)"
  [[ -n "$message" ]] || return 0
  _auto_update_log "[Starter Kit] Previous auto-update failed: $message"
  _auto_update_clear_status
}

_auto_update_repo_exists() {
  [[ -d "${KIT_DIR}/.git" ]]
}

_auto_update_legacy_cache_fresh() {
  local last_check now
  [[ -f "$LEGACY_CACHE_FILE" ]] || return 1
  last_check="$(cat "$LEGACY_CACHE_FILE" 2>/dev/null || echo "0")"
  [[ "$last_check" =~ ^[0-9]+$ ]] || return 1
  now="$(_auto_update_now)"
  (( now - last_check < LEGACY_CACHE_TTL ))
}

_auto_update_touch_legacy_cache() {
  mkdir -p "$(dirname "$LEGACY_CACHE_FILE")"
  _auto_update_now > "$LEGACY_CACHE_FILE"
}

_auto_update_release_lock() {
  if [[ "$_LOCK_HELD" == "true" ]]; then
    rm -rf "$LOCK_DIR"
  fi
}

_auto_update_pid_is_running() {
  local pid="${1:-}"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

_auto_update_maybe_detach() {
  if [[ "$AUTO_UPDATE_HOOK" == "SessionEnd" ]] && [[ "${AUTO_UPDATE_DETACHED:-false}" != "true" ]]; then
    nohup env \
      AUTO_UPDATE_DETACHED=true \
      AUTO_UPDATE_HOOK="$AUTO_UPDATE_HOOK" \
      KIT_DIR="$KIT_DIR" \
      LOCK_DIR="$LOCK_DIR" \
      BACKUP_PATH_FILE="$BACKUP_PATH_FILE" \
      STATUS_FILE="$STATUS_FILE" \
      LEGACY_CACHE_FILE="$LEGACY_CACHE_FILE" \
      LEGACY_CACHE_TTL="$LEGACY_CACHE_TTL" \
      MIN_ASYNC_VERSION="$MIN_ASYNC_VERSION" \
      "$0" >/dev/null 2>&1 &
    return 0
  fi
  return 1
}

_auto_update_acquire_lock() {
  local now existing_pid

  now="$(_auto_update_now)"
  mkdir -p "$(dirname "$LOCK_DIR")"

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    printf '%s\n' "$now" > "$LOCK_DIR/timestamp"
    _LOCK_HELD=true
    trap _auto_update_release_lock EXIT INT TERM
    return 0
  fi

  existing_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")"
  if _auto_update_pid_is_running "$existing_pid"; then
    return 1
  fi

  rm -rf "$LOCK_DIR" 2>/dev/null || return 1
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  printf '%s\n' "$now" > "$LOCK_DIR/timestamp"
  _LOCK_HELD=true
  trap _auto_update_release_lock EXIT INT TERM
  return 0
}

_auto_update_versions() {
  local local_ver remote_ver local_ref remote_ref

  local_ver="$(git -C "$KIT_DIR" describe --tags --abbrev=0 HEAD 2>/dev/null || echo "")"
  remote_ver="$(git -C "$KIT_DIR" describe --tags --abbrev=0 origin/main 2>/dev/null || echo "")"
  if [[ -z "$local_ver" ]]; then
    local_ref="$(git -C "$KIT_DIR" rev-parse HEAD 2>/dev/null || echo "")"
    [[ -n "$local_ref" ]] && local_ver="commit:${local_ref}"
  fi
  if [[ -z "$remote_ver" ]]; then
    remote_ref="$(git -C "$KIT_DIR" rev-parse origin/main 2>/dev/null || echo "")"
    [[ -n "$remote_ref" ]] && remote_ver="commit:${remote_ref}"
  fi
  printf '%s\n%s\n' "$local_ver" "$remote_ver"
}

_auto_update_run() {
  local local_ver remote_ver backup_path_file backup_path

  _auto_update_maybe_detach && return 0
  _auto_update_emit_previous_failure
  _auto_update_repo_exists || return 0

  if ! _auto_update_supports_async_hooks; then
    if _auto_update_legacy_cache_fresh; then
      return 0
    fi
    _auto_update_touch_legacy_cache
  fi

  _auto_update_acquire_lock || return 0

  if ! git -C "$KIT_DIR" fetch --tags --quiet 2>/dev/null; then
    return 0
  fi

  read -r local_ver remote_ver < <(_auto_update_versions | paste -sd ' ' -)
  [[ -n "$local_ver" ]] || return 0
  [[ -n "$remote_ver" ]] || return 0
  if [[ "$local_ver" == "$remote_ver" ]]; then
    _auto_update_clear_status
    return 0
  fi

  if [[ -n "$(git -C "$KIT_DIR" status --porcelain 2>/dev/null)" ]]; then
    _auto_update_log "[Starter Kit] Local changes in $KIT_DIR. Run: cd $KIT_DIR && git stash -u"
    return 0
  fi

  if ! git -C "$KIT_DIR" pull --ff-only --quiet 2>/dev/null; then
    _auto_update_write_status "git pull --ff-only failed"
    _auto_update_log "[Starter Kit] git pull failed. Run manually: cd ~/.claude-starter-kit && git pull --ff-only && ./setup.sh --update"
    return 0
  fi

  if (cd "$KIT_DIR" && bash setup.sh --update --non-interactive); then
    _auto_update_clear_status
    return 0
  fi

  _auto_update_write_status "setup.sh --update --non-interactive failed"
  _auto_update_log "[Starter Kit] Update failed."
  backup_path_file="$BACKUP_PATH_FILE"
  if [[ -f "$backup_path_file" ]]; then
    backup_path="$(cat "$backup_path_file")"
    _auto_update_log "[Starter Kit] Backup at: $backup_path"
    _auto_update_log "[Starter Kit] To restore: BACKUP=\"$backup_path\" && mv ~/.claude ~/.claude.broken && cp -a \"\$BACKUP\" ~/.claude"
  else
    _auto_update_log "[Starter Kit] Check ~/.claude.backup.* for backups"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _auto_update_run
fi
