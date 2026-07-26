#!/bin/bash
# uninstall.sh - Clean uninstall for Claude Code Starter Kit
# Only removes files tracked in the manifest. User-added files are preserved.
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
MANIFEST="$CLAUDE_DIR/.starter-kit-manifest.json"

# Ensure ~/.local/bin is in PATH (jq may have been installed there)
export PATH="$HOME/.local/bin:$PATH"

# ---------------------------------------------------------------------------
# Platform detection (inline — uninstall.sh is standalone, no lib/detect.sh)
# ---------------------------------------------------------------------------
_uname_s="$(uname -s 2>/dev/null || echo "Unknown")"
_IS_MSYS=false
_IS_WSL=false

case "$_uname_s" in
  MSYS_NT*|MINGW*_NT*|CLANG*_NT*|UCRT*_NT*) _IS_MSYS=true ;;
esac

if [[ -f /proc/version ]] && grep -qi "microsoft" /proc/version 2>/dev/null; then
  _IS_WSL=true
fi

# On MSYS/Git Bash, probe Windows install paths for Claude CLI
if [[ "$_IS_MSYS" == "true" ]]; then
  for _win_dir in \
    "$(cygpath -u "${LOCALAPPDATA:-}/Programs/claude" 2>/dev/null)" \
    "$(cygpath -u "${APPDATA:-}/npm" 2>/dev/null)"; do
    [[ -n "$_win_dir" ]] && export PATH="$_win_dir:$PATH"
  done
fi

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

info()  { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[  OK]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }

# ---------------------------------------------------------------------------
# JSON helpers (jq with grep/sed fallback)
# ---------------------------------------------------------------------------
_json_get() {
  # Usage: _json_get <file> <key>
  # Returns the string value for a simple top-level key
  local file="$1" key="$2"
  if command -v jq &>/dev/null; then
    jq -r ".$key // \"\"" "$file" 2>/dev/null
  else
    grep "\"$key\"" "$file" 2>/dev/null | sed 's/.*: *"\(.*\)".*/\1/' | head -1
  fi
}

_json_files() {
  # Usage: _json_files <file>
  # Returns one file path per line from the "files" array
  local file="$1"
  if command -v jq &>/dev/null; then
    jq -r '.files[]' "$file" 2>/dev/null
  else
    # Extract lines that look like file paths from the JSON files array
    grep '^ *"/' "$file" 2>/dev/null | sed 's/^ *"//; s/"[, ]*$//'
  fi
}

_json_cleanup_paths() {
  local file="$1"
  if command -v jq &>/dev/null; then
    jq -r '.cleanup_paths[]? // empty' "$file" 2>/dev/null
  fi
}

_json_file_count() {
  # Usage: _json_file_count <file>
  local file="$1"
  if command -v jq &>/dev/null; then
    jq '.files | length' "$file" 2>/dev/null
  else
    _json_files "$file" | wc -l | tr -d ' '
  fi
}

_safe_cleanup_path() {
  local path="${1%/}"
  [[ -z "$path" ]] && return 1
  case "$path" in
    "$CLAUDE_DIR"/*|"$HOME/.claude-starter-kit.conf") return 0 ;;
    *) return 1 ;;
  esac
}

_remove_tracked_file() {
  # Return 0=handled, 2=absent, 1=unsafe/failed. Operations stay bound to the
  # verified parent inode; final-leaf symlinks are unlinked, never followed.
  local path="$1" relative root_physical current_physical expected_physical
  local component leaf managed_tmp="" rc=0 index
  local -a components=()

  case "$path" in
    "$CLAUDE_DIR"/*) relative="${path#"$CLAUDE_DIR"/}" ;;
    *) return 1 ;;
  esac
  [[ -n "$relative" ]] || return 1
  case "/$relative/" in
    *//*|*/./*|*/../*) return 1 ;;
  esac

  [[ -e "$CLAUDE_DIR" || -L "$CLAUDE_DIR" ]] || return 2
  [[ -d "$CLAUDE_DIR" && ! -L "$CLAUDE_DIR" ]] || return 1
  root_physical="$(cd -P "$CLAUDE_DIR" 2>/dev/null && pwd -P)" || return 1

  IFS='/' read -r -a components < <(printf '%s\n' "$relative")
  [[ "${#components[@]}" -gt 0 ]] || return 1
  leaf="${components[${#components[@]} - 1]}"
  [[ -n "$leaf" ]] || return 1

  (
    cd -P "$CLAUDE_DIR" 2>/dev/null || exit 1
    current_physical="$(pwd -P)" || exit 1
    [[ "$current_physical" == "$root_physical" ]] || exit 1
    expected_physical="$root_physical"

    for ((index = 0; index < ${#components[@]} - 1; index++)); do
      component="${components[$index]}"
      [[ -e "./$component" || -L "./$component" ]] || exit 2
      [[ -d "./$component" && ! -L "./$component" ]] || exit 1
      cd -P "./$component" 2>/dev/null || exit 1
      current_physical="$(pwd -P)" || exit 1
      expected_physical="$expected_physical/$component"
      [[ "$current_physical" == "$expected_physical" ]] || exit 1
    done

    [[ -f "./$leaf" || -L "./$leaf" ]] || exit 2
    if [[ -L "./$leaf" ]]; then
      rm -f "./$leaf" 2>/dev/null || exit 1
    elif [[ "$leaf" == "CLAUDE.md" ]]; then
      if grep -qF "<!-- BEGIN STARTER-KIT-MANAGED -->" "./$leaf" 2>/dev/null; then
        managed_tmp="$(mktemp "./.${leaf}.tmp.XXXXXX")" || exit 1
        if ! awk '/<!-- BEGIN STARTER-KIT-MANAGED -->/{skip=1} /<!-- END STARTER-KIT-MANAGED -->/{skip=0; next} !skip' \
          "./$leaf" > "$managed_tmp"; then
          rm -f "$managed_tmp" 2>/dev/null || true
          exit 1
        fi
        if [[ -z "$(sed '/^[[:space:]]*$/d' "$managed_tmp" 2>/dev/null)" ]]; then
          rm -f "./$leaf" "$managed_tmp" 2>/dev/null || exit 1
        else
          mv "$managed_tmp" "./$leaf" || exit 1
        fi
      else
        rm -f "./$leaf" 2>/dev/null || exit 1
      fi
    else
      rm -f "./$leaf" 2>/dev/null || exit 1
    fi
  ) || rc=$?
  return "$rc"
}

_managed_root_physical() {
  [[ -e "$CLAUDE_DIR" || -L "$CLAUDE_DIR" ]] || return 0
  [[ -d "$CLAUDE_DIR" && ! -L "$CLAUDE_DIR" ]] || return 1
  cd -P "$CLAUDE_DIR" 2>/dev/null && pwd -P
}

_wce_uninstall_lock_token=""
_wce_uninstall_pending_signal=0

_wce_uninstall_lock_owner_matches() { # <token> [lock-dir]
  local token="$1"
  local lock_dir="${2:-$CLAUDE_DIR/skills/web-content-extraction/logs/.update.lock}"
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

_wce_uninstall_lock_owner_only() { # <lock-dir>
  local lock_dir="$1" entry count=0
  while IFS= read -r -d '' entry; do
    [[ "$entry" == "$lock_dir/owner" ]] || return 1
    count=$((count + 1))
  done < <(find "$lock_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  [[ "$count" -eq 1 ]]
}

_wce_uninstall_lock_acquire() {
  local skills="$CLAUDE_DIR/skills"
  local skill="$skills/web-content-extraction"
  local logs="$skill/logs"
  local lock="$logs/.update.lock" now token acquire_pid
  local acquire_rc=0 wait_rc=0
  [[ -e "$skills" || -L "$skills" ]] || return 0
  [[ -d "$skills" && ! -L "$skills" ]] || return 1
  [[ -e "$skill" || -L "$skill" ]] || return 0
  [[ -d "$skill" && ! -L "$skill" ]] || return 1
  now="$(date +%s)" || return 1
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  token="starter-kit-uninstall-$$-${RANDOM}-$now"
  _WCE_UNINSTALL_ACQUIRE_WAITER_PID="$$"
  export _WCE_UNINSTALL_ACQUIRE_WAITER_PID
  (
    trap '' HUP INT TERM
    : "$_WCE_UNINSTALL_ACQUIRE_WAITER_PID"
    [[ -d "$skills" && ! -L "$skills" \
      && -d "$skill" && ! -L "$skill" ]] || exit 1
    if [[ -e "$logs" || -L "$logs" ]]; then
      [[ -d "$logs" && ! -L "$logs" ]] || exit 1
    else
      mkdir "$logs" || exit 1
    fi
    # Atomic directory creation never opens an existing FIFO, symlink, or
    # device. Existing state is never reclaimed implicitly, regardless of age.
    (umask 077; mkdir "$lock") 2>/dev/null || exit 1
    if ! (umask 077; printf '%s\n' "$token" > "$lock/owner") 2>/dev/null; then
      rmdir "$lock" 2>/dev/null || true
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
  [[ "$acquire_rc" -eq 0 ]] || return 1
  _wce_uninstall_lock_owner_matches "$token" "$lock" || return 1
  _wce_uninstall_lock_owner_only "$lock" || return 1
  _wce_uninstall_lock_token="$token"
  return 0
}

_wce_uninstall_lock_release() {
  local skill="$CLAUDE_DIR/skills/web-content-extraction"
  local logs="$skill/logs"
  local lock="$logs/.update.lock"
  local quarantine="${lock}.release-${_wce_uninstall_lock_token}"
  [[ -n "$_wce_uninstall_lock_token" ]] || return 0
  [[ -d "$skill" && ! -L "$skill" && -d "$logs" && ! -L "$logs" ]] || return 1

  if [[ -e "$quarantine" || -L "$quarantine" ]]; then
    _wce_uninstall_lock_owner_matches \
      "$_wce_uninstall_lock_token" "$quarantine" || return 1
    _wce_uninstall_lock_owner_only "$quarantine" || return 1
  else
    _wce_uninstall_lock_owner_matches \
      "$_wce_uninstall_lock_token" "$lock" || return 1
    _wce_uninstall_lock_owner_only "$lock" || return 1
    mv "$lock" "$quarantine" || return 1
  fi

  if ! _wce_uninstall_lock_owner_matches \
      "$_wce_uninstall_lock_token" "$quarantine" \
    || ! _wce_uninstall_lock_owner_only "$quarantine"; then
    if [[ ! -e "$lock" && ! -L "$lock" ]]; then
      mv "$quarantine" "$lock" 2>/dev/null || true
    fi
    return 1
  fi
  if ! rm -f "$quarantine/owner"; then
    [[ ! -e "$quarantine/owner" && ! -L "$quarantine/owner" ]] || return 1
  fi
  rmdir "$quarantine" || return 1
  rmdir "$logs" "$skill" 2>/dev/null || true
}

_wce_uninstall_defer_signal() {
  _wce_uninstall_pending_signal="$1"
}

_wce_uninstall_on_signal() {
  _wce_uninstall_pending_signal="$1"
  exit "$1"
}

_wce_uninstall_lock_release_wait() {
  local release_pid release_rc=0 wait_rc=0
  [[ -n "$_wce_uninstall_lock_token" ]] || return 0
  _WCE_UNINSTALL_RELEASE_WAITER_PID="$$"
  export _WCE_UNINSTALL_RELEASE_WAITER_PID
  (
    trap '' HUP INT TERM
    _wce_uninstall_lock_release
  ) &
  release_pid=$!
  while true; do
    wait_rc=0
    wait "$release_pid" 2>/dev/null || wait_rc=$?
    case "$wait_rc" in
      129|130|143) continue ;;
      *) release_rc="$wait_rc"; break ;;
    esac
  done
  if [[ "$release_rc" -eq 0 ]]; then
    _wce_uninstall_lock_token=""
    return 0
  fi
  return 1
}

_wce_uninstall_lock_cleanup() {
  local cleanup_rc=0 pending
  trap '_wce_uninstall_defer_signal 129' HUP
  trap '_wce_uninstall_defer_signal 130' INT
  trap '_wce_uninstall_defer_signal 143' TERM
  _wce_uninstall_lock_release_wait || cleanup_rc=1
  trap '_wce_uninstall_on_signal 129' HUP
  trap '_wce_uninstall_on_signal 130' INT
  trap '_wce_uninstall_on_signal 143' TERM
  pending="$_wce_uninstall_pending_signal"
  [[ "$pending" -eq 0 ]] || exit "$pending"
  return "$cleanup_rc"
}

_wce_uninstall_finish() {
  local cleanup_rc=$? release_rc=0
  trap - EXIT
  trap '_wce_uninstall_defer_signal 129' HUP
  trap '_wce_uninstall_defer_signal 130' INT
  trap '_wce_uninstall_defer_signal 143' TERM
  _wce_uninstall_lock_release_wait || release_rc=1
  trap - HUP INT TERM
  [[ "$_wce_uninstall_pending_signal" -eq 0 ]] \
    || cleanup_rc="$_wce_uninstall_pending_signal"
  if [[ "$release_rc" -ne 0 && "$cleanup_rc" -eq 0 ]]; then
    cleanup_rc=1
  fi
  exit "$cleanup_rc"
}

_remove_tool_count_files() {
  local root_physical current_physical match rc=0
  root_physical="$(_managed_root_physical)" || return 1
  [[ -n "$root_physical" ]] || return 0
  (
    cd -P "$CLAUDE_DIR" 2>/dev/null || exit 1
    current_physical="$(pwd -P)" || exit 1
    [[ "$current_physical" == "$root_physical" ]] || exit 1
    [[ -e ./tmp || -L ./tmp ]] || exit 0
    [[ -d ./tmp && ! -L ./tmp ]] || exit 1
    cd -P ./tmp 2>/dev/null || exit 1
    current_physical="$(pwd -P)" || exit 1
    [[ "$current_physical" == "$root_physical/tmp" ]] || exit 1
    shopt -s nullglob
    for match in ./tool-count-*; do
      [[ -f "$match" || -L "$match" ]] || continue
      rm -f "$match" 2>/dev/null || exit 1
    done
  ) || rc=$?
  [[ "$rc" -eq 0 ]]
}

_remove_empty_hook_dirs() {
  local root_physical current_physical entry name contents rc=0
  root_physical="$(_managed_root_physical)" || return 1
  [[ -n "$root_physical" ]] || return 0
  (
    cd -P "$CLAUDE_DIR" 2>/dev/null || exit 1
    current_physical="$(pwd -P)" || exit 1
    [[ "$current_physical" == "$root_physical" ]] || exit 1
    [[ -e ./hooks || -L ./hooks ]] || exit 0
    [[ -d ./hooks && ! -L ./hooks ]] || exit 1
    cd -P ./hooks 2>/dev/null || exit 1
    current_physical="$(pwd -P)" || exit 1
    [[ "$current_physical" == "$root_physical/hooks" ]] || exit 1
    shopt -s nullglob
    for entry in ./*; do
      [[ -d "$entry" && ! -L "$entry" ]] || continue
      name="${entry#./}"
      cd -P "$entry" 2>/dev/null || exit 1
      current_physical="$(pwd -P)" || exit 1
      [[ "$current_physical" == "$root_physical/hooks/$name" ]] || exit 1
      contents="$(ls -A . 2>/dev/null)" || exit 1
      cd -P .. 2>/dev/null || exit 1
      current_physical="$(pwd -P)" || exit 1
      [[ "$current_physical" == "$root_physical/hooks" ]] || exit 1
      [[ -n "$contents" ]] || rmdir "./$name" 2>/dev/null || exit 1
    done
    contents="$(ls -A . 2>/dev/null)" || exit 1
    cd -P .. 2>/dev/null || exit 1
    current_physical="$(pwd -P)" || exit 1
    [[ "$current_physical" == "$root_physical" ]] || exit 1
    [[ -n "$contents" ]] || rmdir ./hooks 2>/dev/null || exit 1
  ) || rc=$?
  [[ "$rc" -eq 0 ]]
}

_remove_wce_runtime_path() {
  # Remove only kit-created runtime leaves. The sibling
  # .node-modules.pre-mdm.* namespace contains the original activation leaf
  # preserved during MDM activation (normally a user-owned npm dependency
  # directory, but a safely replaceable symlink/regular file can also land
  # there). It is deliberately never enumerated or traversed here. "all" is
  # used only to safely interpret the broad cleanup path emitted by older
  # manifests.
  local requested="$1" root_physical="" current_physical="" rc=0
  case "$requested" in
    node_modules|logs|all) ;;
    *) return 1 ;;
  esac

  [[ -e "$CLAUDE_DIR" || -L "$CLAUDE_DIR" ]] || return 0
  if [[ ! -d "$CLAUDE_DIR" || -L "$CLAUDE_DIR" ]]; then
    return 1
  fi
  root_physical="$(cd -P "$CLAUDE_DIR" 2>/dev/null && pwd -P)" || return 1

  # Descend one real component at a time and bind cleanup to the resulting
  # working-directory inode. A concurrently substituted symlink resolves to a
  # different physical path and is rejected before either runtime leaf is
  # removed. Final-leaf symlinks are unlinked, never followed.
  (
    cd -P "$CLAUDE_DIR" 2>/dev/null || exit 1
    current_physical="$(pwd -P)" || exit 1
    [[ "$current_physical" == "$root_physical" ]] || exit 1

    [[ -e skills || -L skills ]] || exit 0
    [[ -d skills && ! -L skills ]] || exit 1
    cd -P skills 2>/dev/null || exit 1
    current_physical="$(pwd -P)" || exit 1
    [[ "$current_physical" == "$root_physical/skills" ]] || exit 1

    [[ -e web-content-extraction || -L web-content-extraction ]] || exit 0
    [[ -d web-content-extraction && ! -L web-content-extraction ]] || exit 1
    cd -P web-content-extraction 2>/dev/null || exit 1
    current_physical="$(pwd -P)" || exit 1
    [[ "$current_physical" == "$root_physical/skills/web-content-extraction" ]] \
      || exit 1

    case "$requested" in
      node_modules|all) rm -rf ./node_modules 2>/dev/null || exit 1 ;;
    esac
    case "$requested" in
      logs|all)
        if [[ -n "$_wce_uninstall_lock_token" ]]; then
          [[ -d ./logs && ! -L ./logs ]] || exit 1
          cd -P ./logs 2>/dev/null || exit 1
          current_physical="$(pwd -P)" || exit 1
          [[ "$current_physical" == "$root_physical/skills/web-content-extraction/logs" ]] || exit 1
          GLOBIGNORE='./.update.lock'; shopt -s dotglob nullglob
          rm -rf ./* 2>/dev/null || exit 1
          cd -P .. 2>/dev/null || exit 1
        else
          rm -rf ./logs 2>/dev/null || exit 1
        fi
        ;;
    esac

    # Remove the skill directory only when tracked-file cleanup and the two
    # runtime removals left it genuinely empty. A preserved pre-MDM backup (or
    # any other user file) keeps the directory in place.
    cd .. || exit 1
    rmdir ./web-content-extraction 2>/dev/null || true
  ) || rc=$?
  [[ "$rc" -eq 0 ]]
}

_remove_cleanup_path() {
  local path="$1" normalized
  [[ -n "$path" ]] || return 0
  normalized="$path"
  while [[ "$normalized" == */ ]]; do
    normalized="${normalized%/}"
  done

  # Current manifests list only the two disposable WCE runtime leaves. Older
  # manifests listed the complete skill directory; reinterpret that exact
  # legacy value as selective cleanup so pre-MDM backups survive upgrades and
  # uninstall. Never send these paths through the generic recursive remover.
  case "$normalized" in
    "$CLAUDE_DIR/skills/web-content-extraction/node_modules")
      _remove_wce_runtime_path node_modules \
        || { warn "Keeping web-content-extraction runtime under an unsafe path"; _uninstall_cleanup_failed=true; }
      return 0
      ;;
    "$CLAUDE_DIR/skills/web-content-extraction/logs")
      _remove_wce_runtime_path logs \
        || { warn "Keeping web-content-extraction logs under an unsafe path"; _uninstall_cleanup_failed=true; }
      return 0
      ;;
    "$CLAUDE_DIR/skills/web-content-extraction")
      _remove_wce_runtime_path all \
        || { warn "Keeping legacy web-content-extraction runtime under an unsafe path"; _uninstall_cleanup_failed=true; }
      return 0
      ;;
  esac
  if [[ "$path" == *'*'* ]]; then
    if [[ "$path" == "$CLAUDE_DIR/tmp/tool-count-*" ]]; then
      _remove_tool_count_files \
        || { warn "Keeping tool-count runtime under an unsafe path"; _uninstall_cleanup_failed=true; }
    else
      warn "Skipping unsupported cleanup glob: $path"
      _uninstall_cleanup_failed=true
    fi
    return 0
  fi
  if _safe_cleanup_path "$path"; then
    rm -rf "$path" 2>/dev/null || _uninstall_cleanup_failed=true
  else
    warn "Skipping unsafe cleanup path: $path"
    _uninstall_cleanup_failed=true
  fi
}

# NOTE: copy of _safe_install_dir in install.sh — keep all 4 copies in sync
# (CI compares normalized bodies in tests/unit/test-install-bootstrap.sh).
_safe_install_dir() {
  # Normalize: strip ALL trailing slashes (so "$HOME//" cannot bypass checks)
  local dir="$1"
  while [[ "$dir" == */ ]]; do
    dir="${dir%/}"
  done
  [[ -z "$dir" ]] && return 1
  # Require an absolute path
  [[ "$dir" != /* ]] && return 1
  # Block $HOME itself
  [[ "$dir" == "$HOME" || "$dir" == "${HOME%/}" ]] && return 1
  # Block system directories and their subtrees
  case "$dir" in
    /|/bin|/bin/*|/sbin|/sbin/*|/etc|/etc/*|/usr|/usr/*|/var|/var/*|/tmp|/tmp/*)
      return 1 ;;
    /home|/root|/opt|/Applications|/Applications/*|/Library|/Library/*)
      return 1 ;;
    /System|/System/*|/dev|/dev/*|/proc|/proc/*)
      return 1 ;;
  esac
  # Require at least 3 path components (e.g. /home/user/dir)
  local depth
  depth="$(printf '%s' "$dir" | tr -cd '/' | wc -c | tr -d ' ')"
  [[ "$depth" -lt 3 ]] && return 1
  return 0
}

# ---------------------------------------------------------------------------
# i18n - detect language from manifest or saved config
# ---------------------------------------------------------------------------
_detect_language() {
  if [[ -f "$MANIFEST" ]]; then
    local lang
    lang="$(_json_get "$MANIFEST" "language")"
    if [[ -n "$lang" ]]; then
      printf '%s' "$lang"
      return
    fi
  fi
  local conf="$HOME/.claude-starter-kit.conf"
  if [[ -f "$conf" ]]; then
    local lang
    # `|| true` prevents pipefail from propagating grep's no-match exit code
    # (1) when the conf lacks a LANGUAGE= line, which would otherwise
    # trigger `set -e` and abort before the printf 'en' fallback below.
    lang="$(grep '^LANGUAGE=' "$conf" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' || true)"
    if [[ -n "$lang" ]]; then
      printf '%s' "$lang"
      return
    fi
  fi
  printf 'en'
}

_load_strings() {
  local lang="${1:-en}"
  case "$lang" in
    ja)
      STR_TITLE="Claude Code Starter Kit - アンインストール"
      STR_FOUND_MANIFEST="%s のマニフェストが見つかりました（プロファイル: %s）"
      STR_WILL_REMOVE="追跡されている %s 個のファイルを削除します"
      STR_CONFIRM="アンインストールを実行しますか？ [y/N]"
      STR_CANCELED="アンインストールを中止しました。"
      STR_REMOVED_CONFIG="保存された設定ファイルを削除しました"
      STR_COMPLETE="アンインストール完了"
      STR_REMOVED="削除: %s ファイル"
      STR_SKIPPED="スキップ: %s ファイル（既に存在しない）"
      STR_REMAINING="%s のユーザーファイルが %s に残っています（スターターキット管理外）"
      STR_DIR_EMPTY="%s は空になりました"
      STR_CLI_UNINSTALL_ASK="Claude Code CLI もアンインストールしますか？ [y/N]"
      STR_CLI_UNINSTALL_NATIVE="ネイティブ版 Claude Code をアンインストール中..."
      STR_CLI_UNINSTALL_NPM="npm 版 Claude Code をアンインストール中..."
      STR_CLI_UNINSTALL_BREW="Homebrew 版 Claude Code をアンインストール中..."
      STR_CLI_UNINSTALL_DONE="Claude Code CLI をアンインストールしました"
      STR_CLI_UNINSTALL_FAILED="Claude Code CLI のアンインストールに失敗しました。手動で削除してください。"
      STR_CLI_UNINSTALL_SKIP="Claude Code CLI のアンインストールをスキップしました"
      STR_CLI_NOT_INSTALLED="Claude Code CLI はインストールされていません"
      STR_CODEX_PLUGIN_REMOVE_ASK="Codex プラグインを削除しますか？ [y/N] "
      STR_CODEX_PLUGIN_REMOVED="Codex プラグインを削除しました"
      STR_CODEX_PLUGIN_REMOVE_FAILED="Codex プラグインの削除に失敗しました。手動で実行してください:"
      STR_CODEX_MCP_REMOVE_ASK="legacy Codex MCP サーバーを削除しますか？ [y/N] "
      STR_CODEX_MCP_REMOVED="Codex MCP サーバーを削除しました"
      STR_CODEX_MCP_REMOVE_FAILED="Codex MCP サーバーの削除に失敗しました。手動で実行してください:"
      STR_SAFETY_NET_REMOVE_ASK="cc-safety-net (npm) も削除しますか？他の AI CLI でも使用中なら残してください [y/N] "
      STR_SAFETY_NET_REMOVED="cc-safety-net を削除しました"
      STR_SAFETY_NET_REMOVE_FAILED="cc-safety-net の削除に失敗しました。手動で実行してください:"
      ;;
    *)
      STR_TITLE="Claude Code Starter Kit - Uninstall"
      STR_FOUND_MANIFEST="Found manifest from %s (profile: %s)"
      STR_WILL_REMOVE="Will remove %s tracked files"
      STR_CONFIRM="Continue with uninstall? [y/N]"
      STR_CANCELED="Uninstall canceled."
      STR_REMOVED_CONFIG="Removed saved configuration"
      STR_COMPLETE="Uninstall complete"
      STR_REMOVED="Removed: %s files"
      STR_SKIPPED="Skipped: %s files (already missing)"
      STR_REMAINING="%s user files remain in %s (not managed by starter kit)"
      STR_DIR_EMPTY="%s is now empty"
      STR_CLI_UNINSTALL_ASK="Also uninstall Claude Code CLI? [y/N]"
      STR_CLI_UNINSTALL_NATIVE="Uninstalling native Claude Code..."
      STR_CLI_UNINSTALL_NPM="Uninstalling npm Claude Code..."
      STR_CLI_UNINSTALL_BREW="Uninstalling Homebrew Claude Code..."
      STR_CLI_UNINSTALL_DONE="Claude Code CLI uninstalled"
      STR_CLI_UNINSTALL_FAILED="Failed to uninstall Claude Code CLI. Please remove it manually."
      STR_CLI_UNINSTALL_SKIP="Skipped Claude Code CLI uninstall"
      STR_CLI_NOT_INSTALLED="Claude Code CLI is not installed"
      STR_CODEX_PLUGIN_REMOVE_ASK="Remove Codex plugin? [y/N] "
      STR_CODEX_PLUGIN_REMOVED="Codex plugin removed"
      STR_CODEX_PLUGIN_REMOVE_FAILED="Failed to remove Codex plugin. Remove it manually:"
      STR_CODEX_MCP_REMOVE_ASK="Remove legacy Codex MCP server? [y/N] "
      STR_CODEX_MCP_REMOVED="Codex MCP server removed"
      STR_CODEX_MCP_REMOVE_FAILED="Failed to remove Codex MCP server. Remove it manually:"
      STR_SAFETY_NET_REMOVE_ASK="Also remove cc-safety-net (npm)? Keep it if other AI CLIs use it [y/N] "
      STR_SAFETY_NET_REMOVED="cc-safety-net removed"
      STR_SAFETY_NET_REMOVE_FAILED="Failed to remove cc-safety-net. Remove it manually:"
      ;;
  esac
}

LANG_CODE="$(_detect_language)"
_load_strings "$LANG_CODE"

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
printf "\n${BOLD}%s${NC}\n\n" "$STR_TITLE"

if [[ ! -f "$MANIFEST" ]]; then
  warn "マニフェストが見つかりません / Manifest not found"
  info ""
  info "  セットアップが途中で失敗した場合、マニフェストが作成されていない"
  info "  可能性があります。その場合は以下の方法で対処できます："
  info ""
  info "  1) もう一度セットアップを実行する（推奨）："
  info "     ~/.claude-starter-kit/setup.sh"
  info ""
  info "  2) Claude Code の設定をすべて手動で削除する："
  info "     rm -rf $CLAUDE_DIR"
  info ""
  info "  ---"
  info ""
  info "  If the setup was interrupted, the manifest may not have been created."
  info "  You can either re-run setup or manually remove $CLAUDE_DIR"
  exit 1
fi

file_count="$(_json_file_count "$MANIFEST")"
profile="$(_json_get "$MANIFEST" "profile")"
timestamp="$(_json_get "$MANIFEST" "timestamp")"
[[ -z "$profile" ]] && profile="unknown"
[[ -z "$timestamp" ]] && timestamp="unknown"

# shellcheck disable=SC2059
info "$(printf "$STR_FOUND_MANIFEST" "$timestamp" "$profile")"
# shellcheck disable=SC2059
info "$(printf "$STR_WILL_REMOVE" "$file_count")"
printf "\n"

read -r -p "$STR_CONFIRM " confirm
case "$confirm" in
  y|Y|yes|YES) ;;
  *)
    info "$STR_CANCELED"
    exit 0
    ;;
esac
if ! ( _managed_root_physical >/dev/null ); then
  warn "Unsafe managed root; uninstall made no changes: $CLAUDE_DIR"
  exit 1
fi
trap '_wce_uninstall_finish' EXIT
trap '_wce_uninstall_defer_signal 129' HUP
trap '_wce_uninstall_defer_signal 130' INT
trap '_wce_uninstall_defer_signal 143' TERM
_wce_uninstall_acquire_rc=0
_wce_uninstall_lock_acquire || _wce_uninstall_acquire_rc=$?
if [[ "$_wce_uninstall_pending_signal" -ne 0 ]]; then
  exit "$_wce_uninstall_pending_signal"
fi
trap '_wce_uninstall_on_signal 129' HUP
trap '_wce_uninstall_on_signal 130' INT
trap '_wce_uninstall_on_signal 143' TERM
if [[ "$_wce_uninstall_pending_signal" -ne 0 ]]; then
  exit "$_wce_uninstall_pending_signal"
fi
if [[ "$_wce_uninstall_acquire_rc" -ne 0 ]]; then
  warn "Existing or unsafe web-content-extraction update lock; verify and remove it manually before retrying"
  exit 1
fi
# ---------------------------------------------------------------------------
# Remove tracked files
# ---------------------------------------------------------------------------
removed=0
skipped=0
_uninstall_cleanup_failed=false

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  _tracked_remove_rc=0
  _remove_tracked_file "$file" || _tracked_remove_rc=$?
  case "$_tracked_remove_rc" in
    0) removed=$((removed + 1)) ;;
    2) skipped=$((skipped + 1)) ;;
    *)
      warn "Skipping tracked file under an unsafe managed path: $file"
      _uninstall_cleanup_failed=true
      skipped=$((skipped + 1))
      ;;
  esac
done < <(_json_files "$MANIFEST")

# Legacy cleanup for pre-manifest-v2 releases that deployed AGENTS.md.
if [[ -f "$CLAUDE_DIR/AGENTS.md" ]]; then
  rm -f "$CLAUDE_DIR/AGENTS.md"
  removed=$((removed + 1))
fi

# ---------------------------------------------------------------------------
# Remove manifest-declared runtime artifacts. Older manifests may not have this
# list yet; the fallback below covers the legacy v2 transition.
# ---------------------------------------------------------------------------
_cleanup_paths_seen=false
while IFS= read -r _cleanup_path; do
  [[ -z "$_cleanup_path" ]] && continue
  _cleanup_paths_seen=true
  _remove_cleanup_path "$_cleanup_path"
done < <(_json_cleanup_paths "$MANIFEST")

if [[ "$_cleanup_paths_seen" != "true" ]]; then
  for _cleanup_path in \
    "$CLAUDE_DIR/skills/web-content-extraction/node_modules" \
    "$CLAUDE_DIR/skills/web-content-extraction/logs" \
    "$CLAUDE_DIR/.starter-kit-update.lock" \
    "$CLAUDE_DIR/.starter-kit-update-status" \
    "$CLAUDE_DIR/.starter-kit-update-cache" \
    "$CLAUDE_DIR/.starter-kit-merge-prefs.json" \
    "$CLAUDE_DIR/.starter-kit-pending-features.json" \
    "$CLAUDE_DIR/sessions" \
    "$CLAUDE_DIR/tmp/tool-count-*" \
    "$CLAUDE_DIR/.starter-kit-snapshot" \
    "$CLAUDE_DIR/.starter-kit-last-backup" \
    "$HOME/.claude-starter-kit.conf"; do
    _remove_cleanup_path "$_cleanup_path"
  done
fi

if ! _wce_uninstall_lock_cleanup; then
  warn "Failed to release the web-content-extraction update lock"
  _uninstall_cleanup_failed=true
fi

# ---------------------------------------------------------------------------
# Clean up empty directories
# ---------------------------------------------------------------------------
for dir in agents rules commands skills memory; do
  target="$CLAUDE_DIR/$dir"
  if [[ -d "$target" && ! -L "$target" ]] \
    && [[ -z "$(ls -A "$target" 2>/dev/null)" ]]; then
    rmdir "$target" 2>/dev/null || true
  fi
done

_remove_empty_hook_dirs \
  || { warn "Keeping hook directories under an unsafe path"; _uninstall_cleanup_failed=true; }

if [[ "$_uninstall_cleanup_failed" == "true" ]]; then
  warn "Uninstall incomplete; manifest kept for retry: $MANIFEST"
  exit 1
fi

rm -f "$MANIFEST"

[[ ! -f "$HOME/.claude-starter-kit.conf" ]] && ok "$STR_REMOVED_CONFIG"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n"
ok "$STR_COMPLETE"
# shellcheck disable=SC2059
info "$(printf "$STR_REMOVED" "$removed")"
if [[ "$skipped" -gt 0 ]]; then
  # shellcheck disable=SC2059
  info "$(printf "$STR_SKIPPED" "$skipped")"
fi

# ---------------------------------------------------------------------------
# Codex Plugin / legacy MCP cleanup
# ---------------------------------------------------------------------------
# _claude_plugin_list_has(): structured match against `claude plugin list`
# output (self-contained port of lib/codex-setup.sh's helper of the same
# name — uninstall.sh does not source lib/ — with the marker check widened
# from a fixed "-"/"*"/"+" set to "any token not starting with an
# alnum/underscore", since the installed CLI renders the marker as "❯" and
# a literal multibyte marker in the awk regex would be locale-fragile).
# A plain `grep -qw "codex"` false-positives on names like "codex-tools"
# (word-boundary matching treats "-" as a boundary); this requires the
# first non-marker token to equal the name exactly (ignoring an "@marketplace"
# suffix).
_claude_plugin_list_has() {
  local _list="$1" _name="$2"
  printf '%s\n' "$_list" | awk -v name="$_name" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line == "") next
      n = split(line, parts, /[[:space:]]+/)
      candidate = parts[1]
      if (candidate !~ /^[A-Za-z0-9_]/ && n >= 2) {
        candidate = parts[2]
      }
      if (name ~ /@/) {
        if (candidate == name) { found = 1 }
      } else {
        sub(/@.*/, "", candidate)
        if (candidate == name) { found = 1 }
      }
    }
    END { exit found ? 0 : 1 }
  '
}

if command -v claude &>/dev/null; then
  # Check for Codex plugin
  _codex_plugin_list="$(claude plugin list 2>/dev/null || true)"
  if _claude_plugin_list_has "$_codex_plugin_list" "codex"; then
    printf "\n"
    read -r -p "$STR_CODEX_PLUGIN_REMOVE_ASK" _codex_plugin_confirm
    case "$_codex_plugin_confirm" in
      y|Y|yes|YES)
        if claude plugin uninstall codex --scope user; then
          info "$STR_CODEX_PLUGIN_REMOVED"
        else
          warn "$STR_CODEX_PLUGIN_REMOVE_FAILED"
          info "  claude plugin uninstall codex --scope user"
        fi
        ;;
    esac
  fi
  # Check for legacy Codex MCP.
  # NOTE: `-s user` is not a valid `claude mcp list` option on current CLIs
  # (it errors with "unknown option '-s'"), so it always fell through to the
  # `|| true` empty-list fallback and this check never fired. Use the same
  # scope-less invocation as lib/codex-setup.sh's _has_legacy_mcp(). The mcp
  # list format is "<name>: <command...>" (not the plugin-list marker
  # format), so match on an anchored "name:" prefix instead of the
  # plugin-list helper above — a bare `grep -qw "codex"` would also
  # false-positive on e.g. "codex-tools: ...".
  _codex_mcp_list="$(claude mcp list 2>/dev/null || true)"
  if echo "$_codex_mcp_list" | grep -qE '^codex:' 2>/dev/null; then
    printf "\n"
    read -r -p "$STR_CODEX_MCP_REMOVE_ASK" _codex_mcp_confirm
    case "$_codex_mcp_confirm" in
      y|Y|yes|YES)
        if claude mcp remove -s user codex; then
          info "$STR_CODEX_MCP_REMOVED"
        else
          warn "$STR_CODEX_MCP_REMOVE_FAILED"
          info "  claude mcp remove -s user codex"
        fi
        ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# Claude Code CLI uninstall
# ---------------------------------------------------------------------------
if command -v claude &>/dev/null; then
  printf "\n"
  read -r -p "$STR_CLI_UNINSTALL_ASK " cli_confirm
  case "$cli_confirm" in
    y|Y|yes|YES)
      if [[ "$_IS_MSYS" == "true" ]]; then
        # Windows native (Git Bash): Claude was installed via PowerShell installer
        # Binary is typically at %LOCALAPPDATA%\Programs\claude\claude.exe
        info "$STR_CLI_UNINSTALL_NATIVE"
        _win_claude_dir="$(cygpath -u "${LOCALAPPDATA:-}/Programs/claude" 2>/dev/null)"
        if [[ -n "$_win_claude_dir" ]] && [[ -d "$_win_claude_dir" ]]; then
          rm -rf "$_win_claude_dir" 2>/dev/null && ok "$STR_CLI_UNINSTALL_DONE" || warn "$STR_CLI_UNINSTALL_FAILED"
        elif claude uninstall 2>/dev/null; then
          ok "$STR_CLI_UNINSTALL_DONE"
        else
          warn "$STR_CLI_UNINSTALL_FAILED"
        fi
      else
        # Unix (macOS / Linux / WSL)
        local_bin_claude="$HOME/.local/bin/claude"
        if [[ -f "$local_bin_claude" ]] || [[ -L "$local_bin_claude" ]]; then
          # Native installer: use claude uninstall
          info "$STR_CLI_UNINSTALL_NATIVE"
          if claude uninstall 2>/dev/null; then
            ok "$STR_CLI_UNINSTALL_DONE"
          else
            # Fallback: remove binary directly
            rm -f "$local_bin_claude"
            ok "$STR_CLI_UNINSTALL_DONE"
          fi
        elif npm list -g @anthropic-ai/claude-code &>/dev/null 2>&1; then
          # npm installation
          info "$STR_CLI_UNINSTALL_NPM"
          if npm uninstall -g @anthropic-ai/claude-code 2>/dev/null; then
            ok "$STR_CLI_UNINSTALL_DONE"
          else
            warn "$STR_CLI_UNINSTALL_FAILED"
          fi
        elif brew list claude-code &>/dev/null 2>&1; then
          # Homebrew installation
          info "$STR_CLI_UNINSTALL_BREW"
          if brew uninstall claude-code 2>/dev/null; then
            ok "$STR_CLI_UNINSTALL_DONE"
          else
            warn "$STR_CLI_UNINSTALL_FAILED"
          fi
        else
          # Unknown installation method — try claude uninstall
          info "$STR_CLI_UNINSTALL_NATIVE"
          if claude uninstall 2>/dev/null; then
            ok "$STR_CLI_UNINSTALL_DONE"
          else
            warn "$STR_CLI_UNINSTALL_FAILED"
          fi
        fi
      fi
      ;;
    *)
      info "$STR_CLI_UNINSTALL_SKIP"
      ;;
  esac
else
  info "$STR_CLI_NOT_INSTALLED"
fi

# ---------------------------------------------------------------------------
# cc-safety-net uninstall (auto-installed by setup.sh for the safety-net hook)
# ---------------------------------------------------------------------------
if command -v npm &>/dev/null && npm list -g cc-safety-net &>/dev/null; then
  printf "\n"
  # EOF-tolerant read: piped/automated runs default to keeping the package
  read -r -p "$STR_SAFETY_NET_REMOVE_ASK" _safety_net_confirm || _safety_net_confirm="n"
  case "$_safety_net_confirm" in
    y|Y|yes|YES)
      if npm uninstall -g cc-safety-net 2>/dev/null; then
        ok "$STR_SAFETY_NET_REMOVED"
      else
        warn "$STR_SAFETY_NET_REMOVE_FAILED"
        info "  npm uninstall -g cc-safety-net"
      fi
      ;;
  esac
fi

# Starter kit repository cleanup. Default to keeping it for non-interactive
# runs, because this script may be executing from inside that directory.
KIT_INSTALL_DIR="${STARTER_KIT_DIR:-$HOME/.claude-starter-kit}"
if [[ -d "$KIT_INSTALL_DIR" ]]; then
  printf "\n"
  if [[ -t 0 ]]; then
    read -r -p "Also remove starter kit repository $KIT_INSTALL_DIR? [y/N] " _kit_repo_confirm || _kit_repo_confirm="n"
    case "$_kit_repo_confirm" in
      y|Y|yes|YES)
        if _safe_install_dir "$KIT_INSTALL_DIR"; then
          rm -rf "$KIT_INSTALL_DIR"
          ok "Starter kit repository removed"
        else
          warn "Skipped unsafe starter kit repository path: $KIT_INSTALL_DIR"
        fi
        ;;
    esac
  else
    info "Starter kit repository remains: $KIT_INSTALL_DIR"
    info "  Remove manually if desired: rm -rf \"$KIT_INSTALL_DIR\""
  fi
fi

# Check if ~/.claude still has content
if [[ -d "$CLAUDE_DIR" ]]; then
  remaining="$(find "$CLAUDE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$remaining" -gt 0 ]]; then
    # shellcheck disable=SC2059
    info "$(printf "$STR_REMAINING" "$remaining" "$CLAUDE_DIR")"
  else
    # shellcheck disable=SC2059
    info "$(printf "$STR_DIR_EMPTY" "$CLAUDE_DIR")"
  fi
fi
