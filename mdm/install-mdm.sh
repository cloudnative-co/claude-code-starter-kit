#!/bin/bash -p
# mdm/install-mdm.sh — macOS 向け MDM サイレントインストーラ

# Bash reads BASH_ENV and imported functions before the first script line.  A
# root MDM launcher therefore starts in privileged mode from the shebang,
# discards the inherited environment, then starts a clean privileged Bash with
# every startup-file path disabled.  There is deliberately no argv/env bypass
# token: every directly executed invocation crosses this boundary.  Callers
# that explicitly wrap the script must use the clean invocation documented in
# docs/mdm/README.md.
_mdm_launcher_mode_safe() {
  local _mode="$1"
  [[ "$_mode" =~ ^[0-7]+$ ]] || return 1
  while [[ ${#_mode} -gt 3 ]]; do _mode="${_mode#?}"; done
  while [[ ${#_mode} -lt 3 ]]; do _mode="0$_mode"; done
  case "$_mode" in *[2367]|?[2367]?) return 1 ;; esac
  return 0
}

_mdm_launcher_stat_uid() {
  if [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]]; then
    /usr/bin/stat -f '%u' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%u' "$1" 2>/dev/null
  fi
}

_mdm_launcher_stat_mode() {
  if [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]]; then
    # %Lp omits special bits on macOS; %Mp%Lp preserves sticky (1777).
    /usr/bin/stat -f '%Mp%Lp' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%a' "$1" 2>/dev/null
  fi
}

_mdm_launcher_acl_safe() {
  local _path="$1" _line _perms
  [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]] || return 0
  _line="$(LC_ALL=C /bin/ls -lde "$_path" 2>/dev/null || true)"
  _perms="${_line%%[[:space:]]*}"
  [[ -n "$_perms" && "$_perms" != *+* ]]
}

_mdm_launcher_path_trusted() {
  local _script="$1" _dir _base _canonical _path _owner _mode
  [[ -f "$_script" && ! -L "$_script" ]] || return 1
  case "$_script" in
    */*) _dir="${_script%/*}"; _base="${_script##*/}" ;;
    *) _dir=.; _base="$_script" ;;
  esac
  [[ -n "$_dir" ]] || _dir=/
  _canonical="$(builtin cd -P -- "$_dir" 2>/dev/null && printf '%s' "$PWD")" || return 1
  [[ "$_canonical" == / ]] && _canonical=""
  _canonical="$_canonical/$_base"
  [[ -f "$_canonical" && ! -L "$_canonical" ]] || return 1

  _path="$_canonical"
  while :; do
    [[ ! -L "$_path" ]] || return 1
    _owner="$(_mdm_launcher_stat_uid "$_path" || true)"
    _mode="$(_mdm_launcher_stat_mode "$_path" || true)"
    [[ "$_owner" == 0 ]] || return 1
    if ! _mdm_launcher_mode_safe "$_mode"; then
      # A root-owned sticky directory protects root-owned entries from rename
      # by other users and is the only writable parent shape accepted here.
      [[ -d "$_path" && "$_mode" == 1777 ]] || return 1
    fi
    _mdm_launcher_acl_safe "$_path" || return 1
    [[ "$_path" == / ]] && break
    _path="${_path%/*}"; [[ -n "$_path" ]] || _path=/
  done
  _MDM_LAUNCHER_PHYSICAL="$_canonical"
  return 0
}

_mdm_launcher_snapshot() {
  local _source="$1" _before _opened _tmp_base _tmp _old_umask
  if [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]]; then
    _before="$(/usr/bin/stat -f '%i:%z' "$_source" 2>/dev/null)" || return 1
  else
    _before="$(/usr/bin/stat -c '%i:%s' "$_source" 2>/dev/null)" || return 1
  fi
  exec 9<"$_source" || return 1
  if [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]]; then
    _opened="$(/usr/bin/stat -Lf '%i:%z' /dev/fd/9 2>/dev/null)" \
      || { exec 9<&-; return 1; }
    _tmp_base=/private/tmp
  else
    # $$ is not changed by Bash command-substitution subshells, so a
    # /proc/$$/fd lookup would inspect the parent shell instead of the shell
    # running stat.  /dev/fd/9 names the inherited descriptor directly.
    _opened="$(/usr/bin/stat -Lc '%i:%s' /dev/fd/9 2>/dev/null)" \
      || { exec 9<&-; return 1; }
    _tmp_base=/tmp
  fi
  [[ "$_before" == "$_opened" ]] || { exec 9<&-; return 1; }
  _old_umask="$(umask)"; umask 077
  _tmp="$(/usr/bin/mktemp "$_tmp_base/claude-kit-mdm-launcher.XXXXXX")" \
    || { umask "$_old_umask"; exec 9<&-; return 1; }
  umask "$_old_umask"
  /bin/cat <&9 > "$_tmp" || { exec 9<&-; /bin/rm -f "$_tmp"; return 1; }
  exec 9<&-
  /bin/chmod 500 "$_tmp" || { /bin/rm -f "$_tmp"; return 1; }
  printf '%s' "$_tmp"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  _mdm_clean_home="/var/root"
  _mdm_clean_script="$0"
  _mdm_clean_renderer=""
  if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
    _mdm_clean_home="${HOME:-/tmp}"
  else
    if ! _mdm_launcher_path_trusted "$_mdm_clean_script"; then
      printf 'MDM launcher path is not trusted\n' >&2
      exit 50
    fi
    _mdm_clean_script="$_MDM_LAUNCHER_PHYSICAL"
    _mdm_clean_renderer="${_mdm_clean_script%/*}/render-expected.py"
    if ! _mdm_launcher_path_trusted "$_mdm_clean_renderer"; then
      printf 'MDM expected-state renderer path is not trusted\n' >&2
      exit 50
    fi
    _mdm_clean_renderer="$(_mdm_launcher_snapshot "$_MDM_LAUNCHER_PHYSICAL")" || {
      printf 'MDM expected-state renderer snapshot failed\n' >&2
      exit 50
    }
  fi
  _mdm_clean_script="$(_mdm_launcher_snapshot "$_mdm_clean_script")" || {
    [[ -z "$_mdm_clean_renderer" ]] || /bin/rm -f "$_mdm_clean_renderer"
    printf 'MDM launcher snapshot failed\n' >&2
    exit 50
  }
  exec /usr/bin/env -i \
    "HOME=$_mdm_clean_home" \
    'PATH=/usr/bin:/bin:/usr/sbin:/sbin' \
    'LC_ALL=C' \
    /bin/bash --noprofile --norc -p -c '
      _mdm_script=$1
      _mdm_renderer=$2
      shift 2
      trap '\''/bin/rm -f "$_mdm_script"; [[ -z "$_mdm_renderer" ]] || /bin/rm -f "$_mdm_renderer"'\'' EXIT INT TERM
      . "$_mdm_script"
      /bin/rm -f "$_mdm_script"
      _MDM_EXPECTED_RENDERER="$_mdm_renderer"
      [[ -z "$_mdm_renderer" ]] || _MDM_EXPECTED_RENDERER_SNAPSHOT=1
      trap '\''[[ -z "${_MDM_EXPECTED_RENDERER:-}" ]] || /bin/rm -f "$_MDM_EXPECTED_RENDERER"'\'' EXIT INT TERM
      mdm_main "$@"
    ' mdm-install-clean "$_mdm_clean_script" "$_mdm_clean_renderer" "$@"
fi
set -euo pipefail
_MDM_TEST_MODE="${MDM_SOURCE_ONLY:-0}"
_MDM_EXPECTED_RENDERER="${_MDM_EXPECTED_RENDERER:-}"
_MDM_EXPECTED_RENDERER_SNAPSHOT="${_MDM_EXPECTED_RENDERER_SNAPSHOT:-0}"
# MDM agent の umask（000 のことがある）を継承しない（契約: dir 755 /
# file 644。レシート/ログが group/other 書込可で生成されると detect の
# compliant 偽装に直結する。R2-High）。setup.sh は自身で umask 077 を設定する。
umask 022

# ── 終了コード定数（固定契約）────────────────────────────
# 後続タスク(mdm_main / 各フェーズ、Task 4-9 で本ファイルに追加)で参照される契約定数。
# NOTE: ';' 区切り複数代入の2つ目以降には disable ディレクティブが効かないため1行1個に分割。
# shellcheck disable=SC2034
MDM_EXIT_OK=0
# shellcheck disable=SC2034
MDM_EXIT_PREREQ=10
# shellcheck disable=SC2034
MDM_EXIT_BREW=11
# shellcheck disable=SC2034
MDM_EXIT_USER=20
# shellcheck disable=SC2034
MDM_EXIT_CONTEXT=21
# shellcheck disable=SC2034
MDM_EXIT_SETUP=30
# shellcheck disable=SC2034
MDM_EXIT_CLI=40
# shellcheck disable=SC2034
MDM_EXIT_CONFIG=50
# shellcheck disable=SC2034
MDM_EXIT_OS=60

# 配布元リポジトリ（install.sh と同一 URL。KIT_MDM_GIT_REF で SHA を固定する
# ため URL 自体は固定でよい）。
# テスト時は MDM_KIT_REPO_URL_OVERRIDE でローカル fixture repo に差し替え可能
# （参照箇所で call-time に解決する — source 時点の環境に縛られない）。
_MDM_KIT_REPO_URL="https://github.com/cloudnative-co/claude-code-starter-kit.git"

# 管理設定ファイルの固定パス。テスト時は MDM_CONFIG_PATH_OVERRIDE。
_mdm_config_path() {
  printf '%s' "${MDM_CONFIG_PATH_OVERRIDE:-/Library/Application Support/ClaudeCodeStarterKit/mdm-config.conf}"
}

# root が使う一時領域を安全に選ぶ（R7-High）。TMPDIR は対象ユーザー所有を
# 指し得て、親の所有者がエントリを rename/置換できるため、root フェーズでは
# 無視して macOS の sticky・root 管理領域 /private/tmp を使う（/tmp は
# /private/tmp への symlink）。非 root は従来どおり TMPDIR を尊重。
_mdm_safe_tmpdir() {
  local _euid
  _euid="${MDM_EUID_OVERRIDE:-$(id -u)}"
  if [[ "$_euid" -eq 0 ]]; then
    printf '%s' "/private/tmp"
  else
    printf '%s' "${TMPDIR:-/tmp}"
  fi
}

# ── レシート用グローバル（各フェーズが埋める）──────────────
MDM_RCPT_KIT_VERSION=""; MDM_RCPT_GIT_REF=""; MDM_RCPT_RESOLVED_SHA=""
MDM_RCPT_INSTALL_DIR=""; MDM_RCPT_REQUIRED_COMPONENTS='["kit"]'; MDM_RCPT_PROFILE=""
MDM_RCPT_LANGUAGE=""; MDM_RCPT_MANIFEST_PATH=""; MDM_RCPT_MANIFEST_SHA256=""
MDM_RCPT_DEPLOYMENT_SHA256=""
MDM_RCPT_TARGET_USER=""; MDM_RCPT_PARTIAL='[]'; MDM_RCPT_TIMESTAMP=""; MDM_RCPT_LOG_PATH=""

MDM_LOG_FILE="${MDM_LOG_FILE:-}"
# ログは検証済みの保持 fd（fd 7）へ書く（R4-High）。ファイルを一度だけ排他
# 作成して fd 7 に束縛し、以降の追記はパスでなく fd へ行うことで、lstat 後の
# symlink 差し替えや予測パスへの先置きの影響を受けない。MDM_LOG_FD_OPEN=1 の
# ときのみ fd 7 を使う（未確立時＝早期の失敗ログは stderr のみ）。
MDM_LOG_FD_OPEN="${MDM_LOG_FD_OPEN:-0}"

mdm_log() {
  local _phase="$1"; shift
  local _msg="$*"
  local _line="[$_phase] $_msg"
  printf '%s\n' "$_line" >&2
  if [[ "$MDM_LOG_FD_OPEN" == "1" ]]; then
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" "$_line" >&7 2>/dev/null || true
  elif [[ -n "$MDM_LOG_FILE" ]]; then
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" "$_line" >> "$MDM_LOG_FILE" 2>/dev/null || true
  fi
}

# JSON 文字列値のエスケープ。backslash / double-quote に加え、改行・CR・タブは
# \n \r \t へ変換し、残る制御文字（JSON で不正）は除去する（Medium 対応:
# 想定外の値が混じってもレシートが不正 JSON にならない）。
mdm_json_escape() {
  local _s="$1"
  _s="${_s//\\/\\\\}"
  _s="${_s//\"/\\\"}"
  _s="${_s//$'\n'/\\n}"
  _s="${_s//$'\r'/\\r}"
  _s="${_s//$'\t'/\\t}"
  printf '%s' "$_s" | LC_ALL=C tr -d '[:cntrl:]'
}

_mdm_is_darwin() {
  [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == "Darwin" ]]
}

_mdm_stat_mode() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%Lp' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%a' "$1" 2>/dev/null
  fi
}

_mdm_stat_owner() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%Su' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%U' "$1" 2>/dev/null
  fi
}

_mdm_stat_uid() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%u' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%u' "$1" 2>/dev/null
  fi
}

_mdm_stat_managed_metadata() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%u:%l:%Mp%Lp' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%u:%h:%a' "$1" 2>/dev/null
  fi
}

_mdm_stat_inode() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%i' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%i' "$1" 2>/dev/null
  fi
}

_mdm_stat_fd_inode() {
  local _fd="$1"
  if _mdm_is_darwin; then
    /usr/bin/stat -Lf '%i' "/dev/fd/$_fd" 2>/dev/null
  else
    # Command substitutions preserve $$ from the parent shell, and access to
    # that process via /proc can be restricted even for the same UID.  The
    # inherited /dev/fd entry binds directly to the descriptor in this child.
    /usr/bin/stat -Lc '%i' "/dev/fd/$_fd" 2>/dev/null
  fi
}

_mdm_mode_is_safe() {
  local _mode="$1"
  [[ "$_mode" =~ ^[0-7]+$ ]] || return 1
  while [[ ${#_mode} -gt 3 ]]; do _mode="${_mode#?}"; done
  while [[ ${#_mode} -lt 3 ]]; do _mode="0$_mode"; done
  case "$_mode" in
    *[2367]|?[2367]?) return 1 ;;
  esac
  return 0
}

_mdm_mode_normalize() {
  local _mode="$1"
  [[ "$_mode" =~ ^[0-7]{1,4}$ ]] || return 1
  while [[ ${#_mode} -lt 4 ]]; do _mode="0$_mode"; done
  printf '%s' "$_mode"
}

# macOS marks extended ACLs with '+' in the permission token emitted by ls.
# Any ACL is rejected; POSIX owner/mode checks remain the primary Linux test
# fallback because the production surface is macOS-only.
_mdm_has_extended_acl() {
  local _path="$1" _line _perms
  _mdm_is_darwin || return 1
  _line="$(LC_ALL=C /bin/ls -lde "$_path" 2>/dev/null | /usr/bin/sed -n '1p')" || return 0
  [[ -n "$_line" ]] || return 0
  _perms="${_line%%[[:space:]]*}"
  [[ "$_perms" == *+* ]]
}

_mdm_sha256_file() {
  local _path="$1"
  if [[ -x /usr/bin/shasum ]]; then
    /usr/bin/shasum -a 256 "$_path" 2>/dev/null | /usr/bin/awk '{print $1}'
  elif [[ -x /usr/bin/sha256sum ]]; then
    /usr/bin/sha256sum "$_path" 2>/dev/null | /usr/bin/awk '{print $1}'
  else
    return 1
  fi
}

_mdm_stat_identity() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%i:%HT:%z' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%i:%F:%s' "$1" 2>/dev/null
  fi
}

_mdm_stat_fd_identity() {
  local _fd="$1"
  if _mdm_is_darwin; then
    /usr/bin/stat -Lf '%i:%HT:%z' "/dev/fd/$_fd" 2>/dev/null
  else
    /usr/bin/stat -Lc '%i:%F:%s' "/dev/fd/$_fd" 2>/dev/null
  fi
}

# Copy bounded bytes in a child because a checked user-owned pathname can be
# replaced by a FIFO before open(2).  The watchdog bounds that open, head reads
# at most limit+1 bytes, and the copied size plus source metadata must remain
# identical to the pre-open snapshot.
_MDM_BOUND_SNAPSHOT_MODE=""
_mdm_snapshot_bound_to() { # <source> <snapshot> <label> [target-uid]
  local _source="$1" _snapshot="$2" _label="$3" _expected_uid="${4:-}"
  local _before _opened _after _meta _meta_after _uid _rest _links _mode_raw _mode
  local _size _limit _copy_limit _copied _copied_size _done _child _watchdog _rc
  local _copy_rc _timer _watch_seconds=5
  _MDM_BOUND_SNAPSHOT_MODE=""
  [[ -f "$_source" && ! -L "$_source" ]] || return 1
  [[ -f "$_snapshot" && ! -L "$_snapshot" ]] || return 1
  _before="$(_mdm_stat_identity "$_source")" || return 1
  case "$_before" in *:Regular\ File:*|*:regular\ file:*) : ;; *) return 1 ;; esac
  _size="${_before##*:}"
  _meta="$(_mdm_stat_managed_metadata "$_source")" || return 1
  [[ "$_meta" =~ ^[0-9]+:[0-9]+:[0-7]+$ ]] || return 1
  _uid="${_meta%%:*}"; _rest="${_meta#*:}"
  _links="${_rest%%:*}"; _mode_raw="${_rest#*:}"
  _mode="$(_mdm_mode_normalize "$_mode_raw")" || return 1
  _mdm_mode_is_safe "$_mode" || return 1
  [[ "$_links" == 1 ]] || return 1
  _mdm_has_extended_acl "$_source" && return 1
  if [[ "$_label" == managed || "$_label" == cli ]] \
    || [[ "$_label" == head && -n "$_expected_uid" ]]; then
    [[ "$_expected_uid" =~ ^[0-9]+$ && "$_uid" == "$_expected_uid" ]] || return 1
  fi
  case "$_label" in
    manifest|receipt) _limit=4194304 ;;
    managed) _limit=67108864 ;;
    cli) _limit=536870912 ;;
    head) _limit=41 ;;
    *) return 1 ;;
  esac
  [[ "$_size" =~ ^[0-9]+$ && "$_size" -le "$_limit" ]] || return 1
  _copy_limit=$((_limit + 1))
  _done="$_snapshot.done"
  [[ ! -e "$_done" && ! -L "$_done" ]] || return 1
  ( umask 077; set -C; printf 'pending\n' > "$_done" ) 2>/dev/null || return 1
  /bin/chmod 600 "$_done" || { /bin/rm -f "$_done"; return 1; }
  if [[ "${_MDM_TEST_MODE:-0}" == "1" \
    && "${MDM_SNAPSHOT_WATCHDOG_SECONDS_OVERRIDE:-}" =~ ^[1-5]$ ]]; then
    _watch_seconds="$MDM_SNAPSHOT_WATCHDOG_SECONDS_OVERRIDE"
  fi

  (
    _copy_rc=0
    exec 9<"$_source" || _copy_rc=1
    if [[ "$_copy_rc" -eq 0 ]]; then
      _opened="$(_mdm_stat_fd_identity 9)" || _copy_rc=1
    fi
    [[ "$_copy_rc" -ne 0 || "$_opened" == "$_before" ]] || _copy_rc=1
    if [[ "$_copy_rc" -eq 0 ]] \
      && ! /usr/bin/head -c "$_copy_limit" <&9 > "$_snapshot"; then
      _copy_rc=1
    fi
    exec 9<&- 2>/dev/null || true
    if [[ "$_copy_rc" -eq 0 ]]; then
      _copied="$(_mdm_stat_identity "$_snapshot")" || _copy_rc=1
    fi
    if [[ "$_copy_rc" -eq 0 ]]; then
      case "$_copied" in *:Regular\ File:*|*:regular\ file:*) : ;; *) _copy_rc=1 ;; esac
      _copied_size="${_copied##*:}"
      [[ "$_copied_size" == "$_size" ]] || _copy_rc=1
    fi
    if [[ "$_copy_rc" -eq 0 ]]; then
      _after="$(_mdm_stat_identity "$_source")" || _copy_rc=1
      _meta_after="$(_mdm_stat_managed_metadata "$_source")" || _copy_rc=1
      [[ "$_after" == "$_before" && "$_meta_after" == "$_meta" ]] || _copy_rc=1
      ! _mdm_has_extended_acl "$_source" || _copy_rc=1
    fi
    [[ "$_copy_rc" -ne 0 ]] || /bin/chmod 600 "$_snapshot" || _copy_rc=1
    printf '%s\n' "$_copy_rc" > "$_done"
    exit "$_copy_rc"
  ) &
  _child=$!
  (
    _timer=""
    trap '[[ -z "${_timer:-}" ]] || kill "$_timer" 2>/dev/null || true; exit 0' TERM INT
    /bin/sleep "$_watch_seconds" >/dev/null 2>&1 & _timer=$!
    wait "$_timer" 2>/dev/null || true
    if ! /usr/bin/grep -Eq '^[01]$' "$_done" 2>/dev/null; then
      kill -TERM "$_child" 2>/dev/null || true
      /bin/sleep 1 >/dev/null 2>&1 & _timer=$!
      wait "$_timer" 2>/dev/null || true
      /usr/bin/grep -Eq '^[01]$' "$_done" 2>/dev/null || kill -KILL "$_child" 2>/dev/null || true
    fi
  ) &
  _watchdog=$!
  if wait "$_child" 2>/dev/null; then _rc=0; else _rc=$?; fi
  kill "$_watchdog" 2>/dev/null || true
  wait "$_watchdog" 2>/dev/null || true
  /bin/rm -f "$_done"
  if [[ "$_rc" -ne 0 || ! -f "$_snapshot" || -L "$_snapshot" ]]; then
    /bin/rm -f "$_snapshot"
    return 1
  fi
  _MDM_BOUND_SNAPSHOT_MODE="$_mode"
}

_mdm_stable_file_snapshot() { # <source> <label>
  local _source="$1" _label="$2" _tmp _old_umask
  _old_umask="$(umask)"; umask 077
  _tmp="$(/usr/bin/mktemp "$(_mdm_safe_tmpdir)/claude-kit-mdm-${_label}.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  if _mdm_snapshot_bound_to "$_source" "$_tmp" "$_label"; then
    printf '%s' "$_tmp"
  else
    /bin/rm -f "$_tmp"
    return 1
  fi
}

_mdm_stable_managed_snapshot() { # <source> <label> <uid> <copy-var> <mode-var>
  local _source="$1" _label="$2" _uid="$3" _copy_var="$4" _mode_var="$5"
  local _tmp _old_umask
  _old_umask="$(umask)"; umask 077
  _tmp="$(/usr/bin/mktemp "$(_mdm_safe_tmpdir)/claude-kit-mdm-${_label}.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  if ! _mdm_snapshot_bound_to "$_source" "$_tmp" managed "$_uid"; then
    /bin/rm -f "$_tmp"
    return 1
  fi
  printf -v "$_copy_var" '%s' "$_tmp"
  printf -v "$_mode_var" '%s' "$_MDM_BOUND_SNAPSHOT_MODE"
}

# パス構成要素の信頼性検証（R5-High）: 非 symlink・root 所有・group/other
# 書込不可。テスト（非 root）は MDM_LOG_SKIP_OWNER_CHECK=1 で owner 検査を無効化。
# _mdm_boot_mode_is_safe は launcher ヘルパー領域で定義（実行時に解決される）。
_mdm_component_trusted() {
  local _p="$1"
  [[ -L "$_p" ]] && return 1
  local _mode
  _mode="$(_mdm_stat_mode "$_p" || true)"
  _mdm_mode_is_safe "$_mode" || return 1
  _mdm_has_extended_acl "$_p" && return 1
  local _skip_owner="false"
  if [[ "${_MDM_TEST_MODE:-0}" == "1" ]] \
    && { [[ "${MDM_LOG_SKIP_OWNER_CHECK:-0}" == "1" ]] || [[ "${MDM_CONFIG_SKIP_OWNER_CHECK:-0}" == "1" ]]; }; then
    _skip_owner="true"
  fi
  if [[ "$_skip_owner" != "true" ]]; then
    local _owner
    _owner="$(_mdm_stat_owner "$_p" || true)"
    [[ "$_owner" == "root" ]] || return 1
  fi
  return 0
}

# 信頼起点 _base から _dir までの全構成要素（存在するもの）が信頼できるか検証
# する。root 経路で root 書込領域へ書く前に、攻撃者所有の中間/最終
# ディレクトリや中間 symlink による許可プレフィックス外への誘導を排除する。
# パス分解に word splitting / glob 展開を一切使わない（`*`/`?`/`[`
# を含むコンポーネントが pathname expansion されて検証対象がすり替わるのを防ぐ）。
# 文字列の prefix 削除で 1 セグメントずつリテラルに処理する。
_mdm_verify_dir_chain() {
  local _dir="$1" _base="$2"
  case "$_dir" in
    "$_base"|"$_base"/*) : ;;
    *) return 1 ;;
  esac
  _mdm_component_trusted "$_base" || return 1
  local _rest="${_dir#"$_base"}" _cur="$_base" _seg
  while [[ -n "$_rest" ]]; do
    _rest="${_rest#/}"            # 先頭スラッシュ除去
    [[ -z "$_rest" ]] && break
    _seg="${_rest%%/*}"           # 最初のセグメント（リテラル。glob 展開しない）
    _rest="${_rest#"$_seg"}"      # 消費（残りは /… または空）
    [[ -z "$_seg" ]] && continue
    _cur="$_cur/$_seg"
    if [[ -e "$_cur" || -L "$_cur" ]]; then
      _mdm_component_trusted "$_cur" || return 1
    fi
  done
  return 0
}

# jq 非依存でレシート JSON を書く。required_components / partial は既に JSON 配列文字列。
# セキュリティ要件:
#   - root 経路はレシート dir の信頼チェーンを検証（攻撃者所有 dir を再利用しない）
#   - dir 権限を umask に依存させない（信頼チェーン成立で 755 を要求・chmod は不要）
#   - 既存パスの symlink は辿らず除去（root の書込を別ファイルへ誘導させない）
#   - 同一 dir の一時ファイルへ書いてから mv -f（atomic rename・部分書込を晒さない）
mdm_receipt_write() {
  local _path="$1" _result="$2" _exit="$3"
  local _dir; _dir="$(dirname "$_path")"
  local _euid; _euid="${MDM_EUID_OVERRIDE:-$(id -u)}"
  # root 書込（mkdir 含む）の前に既存コンポーネントを検証する。
  # 中間/最終が攻撃者所有 or symlink なら、mkdir がリンク先へ作成する前に
  # fail-closed する。成立すれば以降の mktemp/chmod/mv は攻撃者が介入できない。
  if [[ "$_euid" -eq 0 ]] && ! _mdm_verify_dir_chain "$_dir" "/Library/Application Support"; then
    mdm_log R4 "レシート dir の信頼チェーンが成立しない（fail-closed）: $_dir"
    return 1
  fi
  # umask 022 で dir を 755 作成（呼び出し時点の umask 変化に依存しない）
  local _rum; _rum="$(umask)"; umask 022
  mkdir -p "$_dir" 2>/dev/null || true
  umask "$_rum"
  # 作成後の最終 dir を再検証（root 755 で作られたこと）+ 既存 dir を契約の 755 へ収束
  if [[ "$_euid" -eq 0 ]]; then
    if ! _mdm_component_trusted "$_dir"; then
      mdm_log R4 "作成後のレシート dir が信頼できない（fail-closed）: $_dir"
      return 1
    fi
    if ! chmod 755 "$_dir" 2>/dev/null; then
      mdm_log R4 "レシート dir の権限（755）を設定できない（fail-closed）: $_dir"
      return 1
    fi
  fi
  if [[ -L "$_path" ]]; then
    rm -f "$_path" 2>/dev/null || true
    if [[ -L "$_path" || -e "$_path" ]]; then
      mdm_log R4 "レシートパスの symlink を除去できない: $_path"
      return 1
    fi
  fi
  local _tmp
  _tmp="$(mktemp "$_dir/.receipt-tmp.XXXXXX" 2>/dev/null)" || return 1
  {
    printf '{\n'
    printf '  "schema_version": 2,\n'
    printf '  "kit_version": "%s",\n'  "$(mdm_json_escape "$MDM_RCPT_KIT_VERSION")"
    printf '  "git_ref": "%s",\n'      "$(mdm_json_escape "$MDM_RCPT_GIT_REF")"
    printf '  "resolved_sha": "%s",\n' "$(mdm_json_escape "$MDM_RCPT_RESOLVED_SHA")"
    printf '  "install_dir": "%s",\n'  "$(mdm_json_escape "$MDM_RCPT_INSTALL_DIR")"
    printf '  "required_components": %s,\n' "$MDM_RCPT_REQUIRED_COMPONENTS"
    printf '  "profile": "%s",\n'      "$(mdm_json_escape "$MDM_RCPT_PROFILE")"
    printf '  "language": "%s",\n'     "$(mdm_json_escape "$MDM_RCPT_LANGUAGE")"
    printf '  "manifest_path": "%s",\n' "$(mdm_json_escape "$MDM_RCPT_MANIFEST_PATH")"
    printf '  "manifest_sha256": "%s",\n' "$(mdm_json_escape "$MDM_RCPT_MANIFEST_SHA256")"
    printf '  "deployment_sha256": "%s",\n' "$(mdm_json_escape "$MDM_RCPT_DEPLOYMENT_SHA256")"
    printf '  "target_user": "%s",\n'  "$(mdm_json_escape "$MDM_RCPT_TARGET_USER")"
    printf '  "result": "%s",\n'       "$(mdm_json_escape "$_result")"
    printf '  "exit_code": %s,\n'      "$_exit"
    printf '  "partial": %s,\n'        "$MDM_RCPT_PARTIAL"
    printf '  "timestamp": "%s",\n'    "$(mdm_json_escape "$MDM_RCPT_TIMESTAMP")"
    printf '  "log_path": "%s"\n'      "$(mdm_json_escape "$MDM_RCPT_LOG_PATH")"
    printf '}\n'
  } > "$_tmp" || { rm -f "$_tmp" 2>/dev/null || true; return 1; }
  # 信頼チェーン成立 dir 内の一時ファイルなので chmod のパス指定は安全
  # （攻撃者が dir 内エントリを差し替えられない）。失敗は fail-closed（R5-High）。
  if ! chmod 644 "$_tmp" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null || true
    mdm_log R4 "レシートの権限設定に失敗（fail-closed）: $_tmp"
    return 1
  fi
  mv -f "$_tmp" "$_path" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null || true; return 1; }
  return 0
}

# コンソールユーザーを取得（テスト時は MDM_CONSOLE_USER_OVERRIDE を優先）
_mdm_console_user() {
  if [[ -n "${MDM_CONSOLE_USER_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_CONSOLE_USER_OVERRIDE"; return 0
  fi
  # scutil の ConsoleUser、フォールバック stat /dev/console
  local _u
  _u="$(printf 'show State:/Users/ConsoleUser\n' | scutil 2>/dev/null | awk '/Name :/{print $3; exit}' || true)"
  [[ -z "$_u" ]] && _u="$(_mdm_stat_owner /dev/console 2>/dev/null || true)"
  printf '%s' "$_u"
}

# 対象ユーザーの UID を dscl で取得（実在確認を兼ねる）。
# テスト時は MDM_DSCL_UID_OVERRIDE でモック可能。解決不能なら空を返す。
_mdm_user_uid() {
  local _user="$1"
  if [[ -n "${MDM_DSCL_UID_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_DSCL_UID_OVERRIDE"; return 0
  fi
  dscl . -read "/Users/$_user" UniqueID 2>/dev/null | awk '{print $2; exit}' || true
}

# 対象ユーザー契約: 予約名 denylist に加えて、username 文字種・dscl 実在確認・
# UID >= 501（システムアカウント除外）を必須とする（最終レビュー High#8）。
mdm_resolve_target_user() {
  local _u="${KIT_MDM_TARGET_USER:-}"
  [[ -z "$_u" ]] && _u="$(_mdm_console_user)"
  case "$_u" in
    ''|root|_mbsetupuser|loginwindow|daemon|nobody)
      mdm_log R2 "対象ユーザーを解決できない（'$_u' は無効）"
      return "$MDM_EXIT_USER" ;;
  esac
  if ! printf '%s' "$_u" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$'; then
    mdm_log R2 "対象ユーザー名の文字種が不正: '$_u'"
    return "$MDM_EXIT_USER"
  fi
  local _uid
  _uid="$(_mdm_user_uid "$_u")"
  if ! printf '%s' "$_uid" | grep -qE '^[0-9]+$'; then
    mdm_log R2 "対象ユーザーが実在しない（dscl で解決不能）: '$_u'"
    return "$MDM_EXIT_USER"
  fi
  if [[ "$_uid" -lt 501 ]]; then
    mdm_log R2 "対象ユーザーの UID がシステム領域（<501）: '$_u' (uid=$_uid)"
    return "$MDM_EXIT_USER"
  fi
  printf '%s' "$_u"
  return 0
}

# 対象ユーザーの canonical home を取得・検証。dscl はモック可能。
mdm_validate_user_home() {
  local _user="$1" _home _canonical
  if [[ -n "${MDM_DSCL_HOME_OVERRIDE:-}" ]]; then
    _home="$MDM_DSCL_HOME_OVERRIDE"
  else
    _home="$(dscl . -read "/Users/$_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
  fi
  if [[ -z "$_home" || ! -d "$_home" ]]; then
    mdm_log R2 "home が存在しない: '$_home'"
    return "$MDM_EXIT_USER"
  fi
  if [[ -L "$_home" ]]; then
    mdm_log R2 "home が symlink: $_home"
    return "$MDM_EXIT_USER"
  fi
  _canonical="$(builtin cd -P -- "$_home" 2>/dev/null && printf '%s' "$PWD")" \
    || return "$MDM_EXIT_USER"
  if [[ "$_canonical" != "$_home" ]]; then
    mdm_log R2 "home が canonical path でない: $_home"
    return "$MDM_EXIT_USER"
  fi
  if [[ "${MDM_VALIDATE_HOME_SKIP_OWNER:-0}" != "1" ]]; then
    local _owner; _owner="$(_mdm_stat_owner "$_home" 2>/dev/null || true)"
    if [[ "$_owner" != "$_user" ]]; then
      mdm_log R2 "home の所有者が対象ユーザーでない: $_owner"
      return "$MDM_EXIT_USER"
    fi
  fi
  printf '%s' "$_canonical"
}

# ref を確定 SHA に解決。install.sh は再実行せず wrapper が直接管理する。
mdm_resolve_ref_sha() {
  local _repo="$1" _ref="$2" _remote_url="${3:-}" _sha
  # 形式検証（SHA or check-ref-format --branch）
  if ! _mdm_boot_validate_gitref "$_ref" >/dev/null 2>&1; then
    mdm_log U1b "不正な git ref 形式: $_ref"
    return "$MDM_EXIT_CONFIG"
  fi
  # Production always fetches from the fixed official URL passed by the
  # caller.  Never trust an existing checkout's user-editable origin or local
  # URL rewrite configuration as the authority for a managed ref.
  # NOTE: --verify 必須。無指定の `git rev-parse <ref>` は解決失敗時でも
  # 引数文字列をそのまま stdout へ echo して返す（exit code は非0でも stdout
  # が非空になる）ため、後段の `[[ -z "$_sha" ]]` チェックをすり抜けて
  # 未解決 ref をそのまま「確定 SHA」として誤って返してしまう（実機検証済み）。
  # --verify は失敗時に stdout を空にする。
  # git は _mdm_git 経由（root 時は検証済みユーザーへ降格。Critical#2）
  if [[ -n "$_remote_url" ]]; then
    _mdm_git -C "$_repo" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
      fetch --quiet "$_remote_url" "$_ref" 2>/dev/null || return "$MDM_EXIT_SETUP"
    _sha="$(_mdm_git -C "$_repo" rev-parse --verify "FETCH_HEAD^{commit}" 2>/dev/null || true)"
  elif printf '%s' "$_ref" | grep -qE '^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$'; then
    _sha="$(_mdm_git -C "$_repo" rev-parse --verify "${_ref}^{commit}" 2>/dev/null || true)"
  else
    # 明示 fetch → FETCH_HEAD の commit を真実とする（ローカル ref を更新しないことがあるため）
    if ! _mdm_git -C "$_repo" fetch --quiet origin "$_ref" 2>/dev/null; then
      # origin が無い（初回 clone 前のローカルテスト）場合はローカル ref 解決にフォールバック
      _sha="$(_mdm_git -C "$_repo" rev-parse --verify "${_ref}^{commit}" 2>/dev/null || true)"
    else
      _sha="$(_mdm_git -C "$_repo" rev-parse --verify "FETCH_HEAD^{commit}" 2>/dev/null || true)"
    fi
  fi
  if [[ -z "$_sha" ]]; then
    # U1b はキット取得と ref ピン留めのフェーズ。
    mdm_log U1b "ref を解決できない: $_ref"
    return "$MDM_EXIT_SETUP"
  fi
  printf '%s' "$_sha"
  return 0
}

# ── 前提ブートストラップの判定（brew 有無・CLT 方針）──────
# brew 有無検知。MDM_BREW_PRESENT_OVERRIDE でテスト時にモック可能（"1"=あり/それ以外=なし）。
_mdm_brew_present() {
  if [[ -n "${MDM_BREW_PRESENT_OVERRIDE:-}" ]]; then
    [[ "$MDM_BREW_PRESENT_OVERRIDE" == "1" ]]; return
  fi
  [[ -x /opt/homebrew/bin/brew || -x /usr/local/bin/brew ]] || command -v brew >/dev/null 2>&1
}

# 対象ユーザーでの brew usability × KIT_MDM_INSTALL_HOMEBREW ×
# KIT_MDM_PREREQ_MODE から方針を決定し stdout へ。引数省略時の実体検知と
# PREREQ_MODE=skip は source-only テスト互換用。
mdm_prereq_plan() {
  local _brew_usable="${1:-}"
  if [[ -z "$_brew_usable" ]]; then
    if _mdm_brew_present; then _brew_usable=true; else _brew_usable=false; fi
  fi
  [[ "$_brew_usable" == true || "$_brew_usable" == false ]] || return 1
  case "${KIT_MDM_PREREQ_MODE:-auto}" in
    skip) printf 'skip'; return 0 ;;
    fail)
      if [[ "$_brew_usable" == true ]]; then printf 'skip'; else printf 'fail'; fi
      return 0 ;;
  esac
  if [[ "$_brew_usable" == true ]]; then printf 'skip'; return 0; fi
  case "$(_mdm_root_bool "${KIT_MDM_INSTALL_HOMEBREW:-true}" 2>/dev/null || echo true)" in
    true) printf 'bootstrap' ;;
    *)    printf 'fail' ;;
  esac
  return 0
}

# 降格実行時に対象ユーザーへ引き継ぐ環境変数の許可リスト（env -i で root 環境を
# 継承しないため、渡すものだけを明示列挙する。
_MDM_PASSTHROUGH_KEYS="PROFILE LANGUAGE EDITOR_CHOICE COMMIT_ATTRIBUTION \
ENABLE_GHOSTTY_SETUP ENABLE_FONTS_SETUP ENABLE_STATUSLINE ENABLE_SAFETY_NET \
ENABLE_AUTO_UPDATE ENABLE_DOC_SIZE_GUARD ENABLE_FEATURE_RECOMMENDATION \
ENABLE_PRE_COMPACT_COMMIT ENABLE_WEB_CONTENT_UPDATE ENABLE_NO_FLICKER ENABLE_NEW_INIT \
ENABLE_CODEX_PLUGIN \
KIT_MDM_GIT_REF KIT_MDM_INSTALL_DIR KIT_MDM_INSTALL_CLAUDE_CLI KIT_MDM_DRY_RUN \
KIT_MDM_PREREQ_MODE \
HTTP_PROXY HTTPS_PROXY NO_PROXY"

# LANGUAGE（en/ja。本体の実キー値）を POSIX ロケール名へ変換する。
# 旧実装は "LANG=${LANGUAGE}_JP.UTF-8" と決め打ちしており
# LANGUAGE=en のとき不正ロケール "en_JP.UTF-8" を生成していた。正しくマップする。
_mdm_lang_to_locale() {
  case "${1:-}" in
    en) printf 'en_US.UTF-8' ;;
    ja) printf 'ja_JP.UTF-8' ;;
    *)  printf 'C.UTF-8' ;;
  esac
}

# 降格 argv をグローバル配列 MDM_DROP_ARGV へ直接構築する。
# 旧実装の「改行区切り stdout → read -r で配列化」は、改行を含む値（env 由来
# EDITOR_CHOICE 等）が env のコマンド位置に落ちて任意コマンド実行になり得たため
# 廃止。シリアライズ/再パースを一切行わず、値は常に単一の配列要素として保持する。
# 多層防御として、制御文字（改行/CR/タブ等）を含む passthrough 値は拒否する。
# 引数 $4 以降は実行するコマンド argv（インタプリタ込みで呼び出し側が絶対パス指定）。
MDM_DROP_ARGV=()
_MDM_GIT_SAFE_DIRECTORY=""
mdm_build_drop_argv() {
  local _uid="$1" _user="$2" _home="$3"; shift 3
  local _brewbin=""
  [[ -x /opt/homebrew/bin/brew ]] && _brewbin="/opt/homebrew/bin:"
  [[ -x /usr/local/bin/brew ]] && _brewbin="${_brewbin}/usr/local/bin:"
  MDM_DROP_ARGV=(
    /usr/bin/env -i
    "HOME=$_home"
    "USER=$_user"
    "LOGNAME=$_user"
    "PATH=${_brewbin}/usr/bin:/bin:/usr/sbin:/sbin"
    "GIT_CONFIG_NOSYSTEM=1"
    "GIT_CONFIG_GLOBAL=/dev/null"
    "GIT_TERMINAL_PROMPT=0"
    "GIT_NO_REPLACE_OBJECTS=1"
    # MDM 管理マーカー: setup.sh（wizard）が update/fresh の設定復元後に
    # MDM 注入 env を再適用するためのフラグ（固定値・R2-High）
    "KIT_MDM_MANAGED=true"
    # MDMの独立期待値レンダラーとsetupのhook schemaを固定する内部値。
    # 公開設定にはせず、互換性を優先してlegacy schemaへ収束させる。
    "KIT_MDM_ASYNC_HOOKS=false"
  )
  if [[ -n "${_MDM_GIT_SAFE_DIRECTORY:-}" ]]; then
    if [[ "$_MDM_GIT_SAFE_DIRECTORY" != /* ]] \
      || [[ "$_MDM_GIT_SAFE_DIRECTORY" =~ [[:cntrl:]] ]]; then
      mdm_log R1 "safe.directory の内部値が不正"
      MDM_DROP_ARGV=()
      return 1
    fi
    # Ephemeral command environment only: never write a target user's or
    # root's Git config file.  Exactly the authoritative checkout is trusted.
    MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="GIT_CONFIG_COUNT=1"
    MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="GIT_CONFIG_KEY_0=safe.directory"
    MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="GIT_CONFIG_VALUE_0=$_MDM_GIT_SAFE_DIRECTORY"
  fi
  if [[ -n "${_MDM_PRIOR_INVENTORY:-}" ]]; then
    case "$_MDM_PRIOR_INVENTORY" in
      /private/tmp/claude-kit-mdm-prior.*|/tmp/claude-kit-mdm-prior.*) ;;
      *) MDM_DROP_ARGV=(); return 1 ;;
    esac
    _mdm_component_trusted "$_MDM_PRIOR_INVENTORY" \
      || { MDM_DROP_ARGV=(); return 1; }
    MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="KIT_MDM_PRIOR_MANAGED_INVENTORY=$_MDM_PRIOR_INVENTORY"
  fi
  if [[ -n "${LANGUAGE:-}" ]]; then
    MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="LANG=$(_mdm_lang_to_locale "$LANGUAGE")"
  fi
  local _k _v
  for _k in $_MDM_PASSTHROUGH_KEYS; do
    _v="${!_k:-}"
    [[ -z "$_v" ]] && continue
    # 制御文字を含む値は不正として拒否（多層防御。printf %q 等での温存もしない）。
    # NOTE: grep は改行を行区切りとして扱い改行そのものを検出できないため、
    # 文字列全体を対象にする bash の =~ で判定する（Bash 3.2 対応）。
    if [[ "$_v" =~ [[:cntrl:]] ]]; then
      mdm_log R1 "passthrough 値に制御文字が含まれる: $_k"
      MDM_DROP_ARGV=()
      return 1
    fi
    MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="$_k=$_v"
  done
  local _a
  for _a in "$@"; do
    MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="$_a"
  done
  return 0
}

# setup.sh へ渡す引数をグローバル配列 MDM_SETUP_ARGV へ直接構築する
# （KIT_MDM_DRY_RUN=true のとき --dry-run を追加）。
# $1（任意）= 対象ユーザーの canonical home。既存インストール
# （manifest 存在）を検出した場合は --update を付与し本体の update パス
# を通す。
MDM_SETUP_ARGV=()
mdm_build_setup_argv() {
  local _home="${1:-}"
  MDM_SETUP_ARGV=(--non-interactive)
  if [[ -n "$_home" && -f "$_home/.claude/.starter-kit-manifest.json" ]]; then
    MDM_SETUP_ARGV[${#MDM_SETUP_ARGV[@]}]='--update'
  fi
  if [[ "$(_mdm_root_bool "${KIT_MDM_DRY_RUN:-false}" 2>/dev/null || echo false)" == "true" ]]; then
    MDM_SETUP_ARGV[${#MDM_SETUP_ARGV[@]}]='--dry-run'
  fi
}

# Single-file launcher helpers.  These validate data only; fetched code is
# never sourced or executed by root.
_mdm_boot_validate_gitref() {
  local _ref="$1"
  [[ -z "$_ref" ]] && return 1
  if printf '%s' "$_ref" | grep -qE '^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$'; then
    return 0
  fi
  /usr/bin/git check-ref-format --branch "$_ref" >/dev/null 2>&1
}

# 起動時検証向けの mode 文字列 group/other 書込ビット検査。
_mdm_boot_mode_is_safe() {
  _mdm_mode_is_safe "$1"
}

# 管理設定ファイルの安全性検証。
# 親ディレクトリの検証を含む — 書込可能な親では他者が差し替えを植えられる。
_mdm_boot_config_file_is_secure() {
  local _f="$1"
  [[ -e "$_f" ]] || return 1
  [[ -L "$_f" ]] && return 1
  local _mode _dir _dmode
  _mode="$(_mdm_stat_mode "$_f" || true)"
  _mdm_boot_mode_is_safe "$_mode" || return 1
  _mdm_has_extended_acl "$_f" && return 1
  _dir="$(dirname "$_f")"
  _dmode="$(_mdm_stat_mode "$_dir" || true)"
  _mdm_boot_mode_is_safe "$_dmode" || return 1
  _mdm_has_extended_acl "$_dir" && return 1
  if [[ "${_MDM_TEST_MODE:-0}" != "1" ]]; then
    case "$_dir" in
      "/Library/Application Support"|"/Library/Application Support"/*) ;;
      *) return 1 ;;
    esac
    _mdm_verify_dir_chain "$_dir" "/Library/Application Support" || return 1
  fi
  if [[ "${_MDM_TEST_MODE:-0}" != "1" || "${MDM_CONFIG_SKIP_OWNER_CHECK:-0}" != "1" ]]; then
    local _owner _downer
    _owner="$(_mdm_stat_owner "$_f" || true)"
    [[ "$_owner" == "root" ]] || return 1
    _downer="$(_mdm_stat_owner "$_dir" || true)"
    [[ "$_downer" == "root" ]] || return 1
  fi
  return 0
}

# Single-file root launcher configuration. Root never sources code from the
# user-owned checkout. In executable mode the privileged launcher has already
# discarded inherited environment, so only the root-owned config file and
# MDM-supplied KEY=VALUE argv are inputs.
_MDM_ROOT_ALLOWED_KEYS="PROFILE LANGUAGE EDITOR_CHOICE COMMIT_ATTRIBUTION \
ENABLE_GHOSTTY_SETUP ENABLE_FONTS_SETUP ENABLE_STATUSLINE ENABLE_SAFETY_NET \
ENABLE_AUTO_UPDATE ENABLE_DOC_SIZE_GUARD ENABLE_FEATURE_RECOMMENDATION \
ENABLE_PRE_COMPACT_COMMIT ENABLE_WEB_CONTENT_UPDATE ENABLE_NO_FLICKER ENABLE_NEW_INIT \
ENABLE_CODEX_PLUGIN \
KIT_MDM_TARGET_USER KIT_MDM_INSTALL_HOMEBREW KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE \
KIT_MDM_PREREQ_MODE KIT_MDM_WINDOWS_MODE KIT_MDM_INSTALL_CLAUDE_CLI \
KIT_MDM_GIT_REF KIT_MDM_INSTALL_DIR KIT_MDM_LOG_DIR KIT_MDM_DRY_RUN \
HTTP_PROXY HTTPS_PROXY NO_PROXY"

_mdm_root_key_allowed() {
  local _wanted="$1" _key
  for _key in $_MDM_ROOT_ALLOWED_KEYS; do
    [[ "$_key" == "$_wanted" ]] && return 0
  done
  return 1
}

_mdm_root_bool() {
  case "$1" in
    true|1|yes|on|TRUE|Yes|On|YES|ON) printf 'true' ;;
    false|0|no|off|FALSE|No|Off|NO|OFF) printf 'false' ;;
    *) return 1 ;;
  esac
}

_mdm_root_gitref_syntax() {
  local _ref="$1"
  [[ -n "$_ref" && "$_ref" != -* && "$_ref" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  case "$_ref" in
    *..*|*//*|*/.|.*|*/|*.lock) return 1 ;;
  esac
  printf '%s' "$_ref"
}

_mdm_root_proxy_url() {
  local _value="$1" _rest _authority _tail
  [[ ! "$_value" =~ [[:space:][:cntrl:]] ]] || return 1
  case "$_value" in
    http://*) _rest="${_value#http://}" ;;
    https://*) _rest="${_value#https://}" ;;
    *) return 1 ;;
  esac
  [[ -n "$_rest" && "$_rest" != *'@'* && "$_rest" != *'?'* && "$_rest" != *'#'* ]] || return 1
  _authority="${_rest%%/*}"; _tail="${_rest#"$_authority"}"
  [[ -n "$_authority" && ( -z "$_tail" || "$_tail" == / ) ]] || return 1
  [[ "$_authority" =~ ^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+)(:[0-9]{1,5})?$ ]] || return 1
  printf '%s' "$_value"
}

_mdm_root_value() {
  local _key="$1" _value="$2"
  [[ ! "$_value" =~ [[:cntrl:]] ]] || return 1
  case "$_key" in
    PROFILE)
      case "$_value" in minimal|standard|full) printf '%s' "$_value" ;; *) return 1 ;; esac ;;
    LANGUAGE)
      case "$_value" in en|ja) printf '%s' "$_value" ;; *) return 1 ;; esac ;;
    KIT_MDM_PREREQ_MODE)
      case "$_value" in
        auto|fail) printf '%s' "$_value" ;;
        skip) [[ "${_MDM_TEST_MODE:-0}" == 1 ]] && printf '%s' "$_value" || return 1 ;;
        *) return 1 ;;
      esac ;;
    KIT_MDM_WINDOWS_MODE)
      case "$_value" in gitbash|wsl) printf '%s' "$_value" ;; *) return 1 ;; esac ;;
    ENABLE_AUTO_UPDATE|ENABLE_WEB_CONTENT_UPDATE|ENABLE_CODEX_PLUGIN)
      _value="$(_mdm_root_bool "$_value")" || return 1
      [[ "$_value" == false ]] || return 1
      printf '%s' "$_value" ;;
    ENABLE_*|COMMIT_ATTRIBUTION|KIT_MDM_INSTALL_HOMEBREW|KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE|KIT_MDM_INSTALL_CLAUDE_CLI|KIT_MDM_DRY_RUN)
      _mdm_root_bool "$_value" ;;
    KIT_MDM_TARGET_USER)
      [[ "$_value" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
      printf '%s' "$_value" ;;
    KIT_MDM_GIT_REF) _mdm_root_gitref_syntax "$_value" ;;
    KIT_MDM_INSTALL_DIR|KIT_MDM_LOG_DIR)
      [[ "$_value" == /* && "$_value" != *..* ]] || return 1
      printf '%s' "$_value" ;;
    HTTP_PROXY|HTTPS_PROXY)
      _mdm_root_proxy_url "$_value" ;;
    NO_PROXY)
      [[ ! "$_value" =~ [[:space:][:cntrl:]] ]] || return 1
      printf '%s' "$_value" ;;
    EDITOR_CHOICE)
      case "$_value" in vscode|cursor|zed|neovim|none) printf '%s' "$_value" ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

_mdm_root_config_apply() {
  local _file="$1"; shift || true
  local _key _value _line _arg _set_var _value_var _normalized
  for _key in $_MDM_ROOT_ALLOWED_KEYS; do
    unset "$_key"
    unset "_MDM_ROOT_STAGE_${_key}" "_MDM_ROOT_SET_${_key}"
  done

  if [[ -f "$_file" ]]; then
    local _pre_inode _fd_inode
    _pre_inode="$(_mdm_stat_inode "$_file" || echo pre-fail)"
    _mdm_boot_config_file_is_secure "$_file" || return "$MDM_EXIT_CONFIG"
    exec 8<"$_file" || return "$MDM_EXIT_CONFIG"
    _fd_inode="$(_mdm_stat_fd_inode 8 || echo fd-fail)"
    if [[ "$_pre_inode" != "$_fd_inode" ]]; then
      exec 8<&-
      return "$MDM_EXIT_CONFIG"
    fi
    while IFS= read -r _line || [[ -n "$_line" ]]; do
      case "$_line" in
        ''|'#'*) continue ;;
        *=*) : ;;
        *) exec 8<&-; mdm_log R1 "不正な管理設定行"; return "$MDM_EXIT_CONFIG" ;;
      esac
      _key="${_line%%=*}"; _value="${_line#*=}"
      _mdm_root_key_allowed "$_key" || {
        exec 8<&-
        mdm_log R1 "不明な管理設定キー: $_key"
        return "$MDM_EXIT_CONFIG"
      }
      _set_var="_MDM_ROOT_SET_${_key}"
      [[ -z "${!_set_var:-}" ]] || {
        exec 8<&-
        mdm_log R1 "管理設定キーが重複: $_key"
        return "$MDM_EXIT_CONFIG"
      }
      if [[ "$_value" == \"*\" ]]; then
        _value="${_value#\"}"; _value="${_value%\"}"
      elif [[ "$_value" == \"* || "$_value" == *\" ]]; then
        exec 8<&-
        mdm_log R1 "管理設定値の quote が不正: $_key"
        return "$MDM_EXIT_CONFIG"
      fi
      printf -v "_MDM_ROOT_STAGE_${_key}" '%s' "$_value"
      printf -v "$_set_var" '%s' 1
    done <&8
    exec 8<&-
  fi

  for _arg in "$@"; do
    [[ -z "$_arg" ]] && continue
    case "$_arg" in *=*) : ;; *) mdm_log R1 "不明な CLI 引数: $_arg"; return "$MDM_EXIT_CONFIG" ;; esac
    _key="${_arg%%=*}"; _value="${_arg#*=}"
    _mdm_root_key_allowed "$_key" || { mdm_log R1 "不明な CLI キー: $_key"; return "$MDM_EXIT_CONFIG"; }
    printf -v "_MDM_ROOT_STAGE_${_key}" '%s' "$_value"
    printf -v "_MDM_ROOT_SET_${_key}" '%s' 1
  done

  for _key in $_MDM_ROOT_ALLOWED_KEYS; do
    _set_var="_MDM_ROOT_SET_${_key}"; _value_var="_MDM_ROOT_STAGE_${_key}"
    [[ -n "${!_set_var:-}" ]] || continue
    _normalized="$(_mdm_root_value "$_key" "${!_value_var}")" || return "$MDM_EXIT_CONFIG"
    export "$_key=$_normalized"
  done
  : "${PROFILE:=standard}"
  : "${LANGUAGE:=en}"
  export PROFILE LANGUAGE
  return 0
}

# Compliance receipts are a system/root contract.  Non-root remediation is
# rejected and non-root dry-run never writes a receipt, so a user-owned receipt
# must never become authoritative.  The override is source-only test plumbing.
_mdm_receipt_dir_for() {
  : "$1"
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && -n "${MDM_SYSTEM_RCPT_DIR_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_SYSTEM_RCPT_DIR_OVERRIDE"
    return 0
  fi
  printf '%s' "/Library/Application Support/ClaudeCodeStarterKit"
}

# R4: レシート書き出し + 終了コード確定 + ログクローズ。
# 失敗保証は best-effort: 主経路が書けなければ root 領域の _unresolved へ
# フォールバックし、それも書けなければログ+終了コードのみを唯一のシグナルとする。
_mdm_finish() {
  local _user="$1" _home="$2" _result="$3" _code="$4"
  MDM_RCPT_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  MDM_RCPT_LOG_PATH="$MDM_LOG_FILE"
  : "${MDM_RCPT_PROFILE:=${PROFILE:-standard}}"
  : "${MDM_RCPT_LANGUAGE:=${LANGUAGE:-en}}"
  local _rcpt_dir; _rcpt_dir="$(_mdm_receipt_dir_for "$_home")"
  if [[ "$_result" == "success" && "$_code" -eq 0 ]]; then
    if ! mdm_receipt_write "$_rcpt_dir/receipt-$_user.json" "$_result" "$_code"; then
      # A successful remediation without its trusted receipt would leave MDM
      # reporting success while detection stays non-compliant.  Receipt write
      # is therefore part of the success postcondition.
      _result="failure"
      _code="$MDM_EXIT_SETUP"
      MDM_RCPT_PARTIAL='["receipt"]'
      mdm_receipt_write \
        "$_rcpt_dir/receipt-_unresolved.json" \
        "$_result" "$_code" 2>/dev/null || true
    fi
  else
    mdm_receipt_write "$_rcpt_dir/receipt-$_user.json" "$_result" "$_code" || \
      mdm_receipt_write "$_rcpt_dir/receipt-_unresolved.json" \
        "$_result" "$_code" 2>/dev/null || true
  fi
  mdm_log R4 "完了: result=$_result exit=$_code"
  exit "$_code"
}

# 設定・ユーザー解決失敗時の best-effort レシート。
# 対象ユーザーが未確定のため root 領域の receipt-_unresolved.json へ書く。
# 非 root 等で書けなければレシートは諦め、ログ + 終了コードのみを
# シグナルとする（無条件の「必ず receipt」保証はしない契約）。
_mdm_fail_unresolved() {
  local _code="$1"
  MDM_RCPT_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  MDM_RCPT_LOG_PATH="$MDM_LOG_FILE"
  : "${MDM_RCPT_PROFILE:=${PROFILE:-standard}}"
  : "${MDM_RCPT_LANGUAGE:=${LANGUAGE:-en}}"
  local _dir="${MDM_UNRESOLVED_RCPT_DIR_OVERRIDE:-/Library/Application Support/ClaudeCodeStarterKit}"
  mdm_receipt_write "$_dir/receipt-_unresolved.json" failure "$_code" 2>/dev/null || true
  mdm_log R4 "完了: result=failure exit=$_code (unresolved)"
  exit "$_code"
}

# A dry-run is an audit preview even when target resolution fails.  In that
# mode the compliance receipt must remain byte-for-byte unchanged; normal root
# remediation keeps the best-effort unresolved failure receipt above.
_mdm_fail_or_exit_unresolved() { # <exit-code> <dry-run>
  local _code="$1" _dry_run="$2"
  if [[ "$_dry_run" == "true" ]]; then
    exit "$_code"
  fi
  _mdm_fail_unresolved "$_code"
}

# MDM_DROP_ARGV（mdm_build_drop_argv が直接構築）を環境分離降格で実行する
# 共通ヘルパー。launchctl/sudo/env は絶対パス固定。
#   /bin/launchctl asuser <uid> /usr/bin/sudo -u <user> -H /usr/bin/env -i ... <cmd...>
# MDM_EXEC_AS_USER_DRYRUN=1 のとき実行せず argv を1行1要素で表示のみ
# （テスト用。表示は再パースされない）。
_mdm_exec_as_user() {
  local _uid="$1" _user="$2" _home="$3"; shift 3
  mdm_build_drop_argv "$_uid" "$_user" "$_home" "$@" || return 1
  if [[ "${MDM_EXEC_AS_USER_DRYRUN:-0}" == "1" ]]; then
    printf '%s\n' /bin/launchctl asuser "$_uid" /usr/bin/sudo -u "$_user" -H "${MDM_DROP_ARGV[@]}"
    return 0
  fi
  # The remediation lock belongs to the root coordinator.  Do not let a
  # target-user process (or one of its background descendants) inherit FD 19
  # and extend the lock lifetime after the coordinator exits.
  /bin/launchctl asuser "$_uid" /usr/bin/sudo -u "$_user" -H "${MDM_DROP_ARGV[@]}" 19>&-
}

# ── git 実行ディスパッチャ ──────────────────────────────────────
# root が対象ユーザー所有の git repo を直接操作すると、ユーザーが仕込んだ
# .git/config（core.fsmonitor / filter / credential helper 等）経由で
# 冪等再実行時に root コード実行になる。降格コンテキスト（下記グローバル）
# が設定されているとき、git は必ず検証済み対象ユーザーへ env -i 降格して実行する。
# コンテキストは _mdm_run_user_phase が root フェーズ開始時に設定する。
_MDM_GIT_DROP_UID=""
_MDM_GIT_DROP_USER=""
_MDM_GIT_DROP_HOME=""
_mdm_git() {
  if [[ -n "$_MDM_GIT_DROP_UID" ]]; then
    _mdm_exec_as_user "$_MDM_GIT_DROP_UID" "$_MDM_GIT_DROP_USER" "$_MDM_GIT_DROP_HOME" /usr/bin/git "$@"
  else
    git "$@"
  fi
}

# root なら検証済みユーザーへ降格して実行、非 root なら直接実行する汎用版
# （mkdir/chmod 等、repo 配下を触る git 以外の操作に使う）。
_mdm_run_maybe_as_user() {
  if [[ -n "$_MDM_GIT_DROP_UID" ]]; then
    _mdm_exec_as_user "$_MDM_GIT_DROP_UID" "$_MDM_GIT_DROP_USER" "$_MDM_GIT_DROP_HOME" "$@"
  else
    "$@"
  fi
}

_mdm_brew_usable_for_user() { # <uid> <user> <home>
  local _uid="$1" _user="$2" _home="$3"
  _mdm_exec_as_user "$_uid" "$_user" "$_home" /bin/bash --noprofile --norc -c '
    _brew=""
    if [[ -x /opt/homebrew/bin/brew ]]; then
      _brew=/opt/homebrew/bin/brew
    elif [[ -x /usr/local/bin/brew ]]; then
      _brew=/usr/local/bin/brew
    fi
    [[ -n "$_brew" ]] || exit 1
    _prefix="$("$_brew" --prefix 2>/dev/null)" || exit 1
    [[ -n "$_prefix" && -d "$_prefix" && -w "$_prefix" ]]
  '
}

# CLT on-demand marker の固定パス（Apple の機構が定める。テスト時は override）。
_MDM_ACTIVE_CLT_MARKER=""
_MDM_ACTIVE_BREW_PKG=""
_MDM_ACTIVE_BREW_PLIST=""
_mdm_clt_marker_path() {
  printf '%s' "${MDM_CLT_MARKER_OVERRIDE:-/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress}"
}

# CLT marker を安全に作成する（R2-High）。/tmp は sticky のため他ユーザーが
# symlink を先置きでき、旧実装の touch は root 権限で任意パスの作成/
# タイムスタンプ更新に悪用できた。rm → noclobber 排他作成 → lstat 検証。
_mdm_create_clt_marker() {
  local _marker
  _marker="$(_mdm_clt_marker_path)"
  rm -f "$_marker" 2>/dev/null || true
  if [[ -e "$_marker" || -L "$_marker" ]]; then
    return 1
  fi
  if ! ( set -C; : > "$_marker" ) 2>/dev/null; then
    return 1
  fi
  _MDM_ACTIVE_CLT_MARKER="$_marker"
  _mdm_arm_transient_cleanup
  if [[ -L "$_marker" || ! -f "$_marker" ]]; then
    return 1
  fi
  local _owner
  _owner="$(_mdm_stat_uid "$_marker" 2>/dev/null || true)"
  [[ "$_owner" == "$(id -u)" ]] || return 1
  return 0
}

_mdm_remove_clt_marker() {
  local _marker="${_MDM_ACTIVE_CLT_MARKER:-$(_mdm_clt_marker_path)}"
  [[ "$_marker" == "$(_mdm_clt_marker_path)" ]] || return 1
  rm -f "$_marker" 2>/dev/null || true
  _MDM_ACTIVE_CLT_MARKER=""
}

_mdm_cleanup_prereq_artifacts() {
  local _path _base
  _path="${_MDM_ACTIVE_BREW_PKG:-}"
  if [[ -n "$_path" ]]; then
    _base="$(_mdm_safe_tmpdir)"
    case "$_path" in "$_base"/mdm-homebrew-pkg.*) rm -f "$_path" 2>/dev/null || true ;; esac
    _MDM_ACTIVE_BREW_PKG=""
  fi
  _path="${_MDM_ACTIVE_BREW_PLIST:-}"
  if [[ -n "$_path" && "$_path" == "${MDM_BREW_PLIST_OVERRIDE:-/var/tmp/.homebrew_pkg_user.plist}" ]]; then
    rm -f "$_path" 2>/dev/null || true
    _MDM_ACTIVE_BREW_PLIST=""
  fi
  _path="${_MDM_ACTIVE_CLT_MARKER:-}"
  if [[ -n "$_path" && "$_path" == "$(_mdm_clt_marker_path)" ]]; then
    rm -f "$_path" 2>/dev/null || true
    _MDM_ACTIVE_CLT_MARKER=""
  fi
}

# CLT の存在確認（テスト時は MDM_CLT_PRESENT_OVERRIDE でモック可能）。
_mdm_clt_present() {
  if [[ -n "${MDM_CLT_PRESENT_OVERRIDE:-}" ]]; then
    [[ "$MDM_CLT_PRESENT_OVERRIDE" == "1" ]]; return
  fi
  [[ -d /Library/Developer/CommandLineTools/usr/bin ]] || xcode-select -p >/dev/null 2>&1
}

_mdm_check_dryrun_prerequisites() {
  if _mdm_clt_present; then
    return 0
  fi
  mdm_log R3 "dry-run: CLT が不足"
  return "$MDM_EXIT_PREREQ"
}

# Xcode Command Line Tools の導入確認。root 実行前提。
# 既定では不在時に MDM baseline での pkg 事前配布を要求して失敗を返す。
# KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=true のときのみ、Apple 公式手順として
# 文書化されていない softwareupdate 経由の導入をベストエフォートで試みる。
_mdm_ensure_clt() {
  if _mdm_clt_present; then
    return 0
  fi
  if [[ "$(_mdm_root_bool "${KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE:-false}" 2>/dev/null || echo false)" != "true" ]]; then
    mdm_log R3 "Xcode Command Line Tools が未導入。MDM baseline での pkg 事前配布が必要（KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=true で非公式フォールバックを許可可能）"
    return 1
  fi
  mdm_log R3 "非公式フォールバック: softwareupdate 経由で CLT 導入を試みる（Apple 公式手順として文書化されていない）"
  # marker パスは Apple の on-demand 機構が定める固定パス（/tmp = sticky で
  # 他ユーザーが symlink を先置きできる）。安全に作成できなければこの
  # opt-in 経路自体を中止する（fail-closed。R2-High）
  if ! _mdm_create_clt_marker; then
    mdm_log R3 "CLT marker を安全に作成できない（symlink 先置き等）。非公式フォールバックを中止"
    return 1
  fi
  local _label
  _label="$(softwareupdate -l 2>/dev/null | grep -E '\*.*Command Line Tools' | tail -n1 | sed -E 's/^[^*]*\*[[:space:]]*//' || true)"
  if [[ -n "$_label" ]]; then
    softwareupdate -i "$_label" --verbose >/dev/null 2>&1 || true
  else
    mdm_log R3 "softwareupdate に CLT の候補が見つからない"
  fi
  _mdm_remove_clt_marker
  if _mdm_clt_present; then
    mdm_log R3 "CLT 導入を確認"
    return 0
  fi
  mdm_log R3 "CLT の非公式導入に失敗"
  return 1
}

# GitHub API から Homebrew 公式 pkg（アセット名 Homebrew.pkg / 旧 Homebrew-<version>.pkg）
# の browser_download_url を解決する。
# 出典: https://github.com/Homebrew/brew/releases/latest （2026-07-16 確認）。
# root フェーズの前提導入より前に呼ばれるため jq が使える保証が無く、
# jq 非依存で grep/sed により JSON から値を抜き出す。
# MDM_BREW_RELEASES_JSON_OVERRIDE でテスト時にモック可能（curl を経由せずファイルから読む）。
_mdm_resolve_brew_pkg_url() {
  local _json
  if [[ -n "${MDM_BREW_RELEASES_JSON_OVERRIDE:-}" ]]; then
    _json="$(cat "$MDM_BREW_RELEASES_JSON_OVERRIDE" 2>/dev/null || true)"
  else
    _json="$(curl -fsSL "https://api.github.com/repos/Homebrew/brew/releases/latest" 2>/dev/null || true)"
  fi
  [[ -z "$_json" ]] && return 1
  local _url
  # 無ヒットの可能性がある grep は pipefail 下で非0を返し得るため `|| true` で
  # 握り潰し、後段の空文字チェックに委ねる（本ファイル既存の NOTE と同じ作法）。
  _url="$(printf '%s' "$_json" \
    | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*\.pkg"' \
    | head -n1 \
    | sed -E 's/^"browser_download_url"[[:space:]]*:[[:space:]]*"//; s/"$//' || true)"
  [[ -z "$_url" ]] && return 1
  # 解決した URL を公式リリース配布パスに制約する（最終レビュー High#7）。
  # API 応答の改ざん/汚染があっても github.com/Homebrew/brew 以外へ飛ばない。
  # アセット名は Homebrew-<version>.pkg（旧）と Homebrew.pkg（6.0.11 で実測の現行）
  # の両方を許容する。
  if ! printf '%s' "$_url" | grep -qE '^https://github\.com/Homebrew/brew/releases/download/[^/[:space:]]+/Homebrew[^/[:space:]]*\.pkg$'; then
    mdm_log R3 "Homebrew pkg URL が公式リリース配布パスでない: $_url"
    return 1
  fi
  printf '%s' "$_url"
  return 0
}

# pkgutil --check-signature の出力を検証する（最終レビュー High#7）。
# 汎用の "Developer ID Installer" 一致だけでは Apple 発行の任意の Developer ID
# 証明書で署名した悪性 pkg を通してしまうため、Homebrew の Team ID に pin する。
# Team ID 927JGANW46 は 2026-07-17 に release 6.0.11 の実 pkg を
# `pkgutil --check-signature` して確認した一次情報
# （"Developer ID Installer: Patrick Linnane (927JGANW46)"・notarized）。
# 証明書のローテーションで Team ID が変わった場合は fail-closed になる（導入失敗
# として exit 11 → ログで判別可能）。
_MDM_BREW_TEAM_ID="927JGANW46"
_mdm_check_brew_signature_output() {
  local _out="$1"
  printf '%s' "$_out" | grep -q 'Developer ID Installer' || return 1
  printf '%s' "$_out" | grep -q "Developer ID Installer: .*(${_MDM_BREW_TEAM_ID})" || return 1
  return 0
}

# HOMEBREW_PKG_USER plist を安全に作成する（最終レビュー High#7）。
# /var/tmp は world-writable + sticky のため、他ローカルユーザーが先回りで
# symlink を置け、旧実装（defaults write）は root がそれを辿って任意ファイルへ
# 書き込む経路になった。rm → noclobber 排他作成 → lstat 検証で排除する。
# Homebrew 側の homebrew-package-user は「非 symlink 通常ファイル・root 所有・
# mode 0600・ACL 無し」の場合のみ plist を尊重する（Homebrew/brew
# Library/Homebrew/utils/macos_user.sh で確認済み）ため mode 600 で作成する。
# 値は defaults read 互換の XML plist（username は R2 で文字種検証済み = XML 安全）。
_mdm_write_brew_pkg_user_plist() {
  local _user="$1"
  local _plist="${MDM_BREW_PLIST_OVERRIDE:-/var/tmp/.homebrew_pkg_user.plist}"
  rm -f "$_plist" 2>/dev/null || true
  if [[ -e "$_plist" || -L "$_plist" ]]; then
    mdm_log R3 "既存の plist を除去できない: $_plist"
    return 1
  fi
  # noclobber（set -C）で排他的に作成: rm と作成の間に他者が再作成した場合は
  # 上書きせず失敗する。umask 177 で最初から 600
  if ! ( set -C; umask 177; printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>HOMEBREW_PKG_USER</key>\n\t<string>%s</string>\n</dict>\n</plist>\n' "$_user" > "$_plist" ) 2>/dev/null; then
    mdm_log R3 "plist の排他作成に失敗: $_plist"
    return 1
  fi
  _MDM_ACTIVE_BREW_PLIST="$_plist"
  _mdm_arm_transient_cleanup
  # 作成後の実体検証（symlink でない・通常ファイル・自分所有・mode 600）
  if [[ -L "$_plist" || ! -f "$_plist" ]]; then
    mdm_log R3 "作成した plist の実体が不正: $_plist"
    return 1
  fi
  local _owner _mode
  _owner="$(_mdm_stat_uid "$_plist" 2>/dev/null || true)"
  _mode="$(_mdm_stat_mode "$_plist" 2>/dev/null || true)"
  if [[ "$_owner" != "$(id -u)" || "$_mode" != "600" ]]; then
    mdm_log R3 "作成した plist の所有者/mode が不正: owner=$_owner mode=$_mode"
    rm -f "$_plist" 2>/dev/null || true
    return 1
  fi
  return 0
}

# Homebrew の導入。公式 .pkg + HOMEBREW_PKG_USER 方式
# （出典: https://docs.brew.sh/Installation、2026-07-16 確認）。
#
# macOS の .pkg インストーラは Homebrew/brew の GitHub Releases に配置され、
# デフォルト prefix（Apple Silicon: /opt/homebrew, Intel: /usr/local）に
# 対象ユーザー単独所有で導入される。ログインウィンドウ/ユーザーログイン前でも
# 動作するため MDM の root コンテキストに適する（curl|bash 版と異なり、対象
# ユーザーのパスワードなし sudo に依存しない）。
#
# 手順（各ステップの一次情報根拠は上記 docs.brew.sh/Installation の記載）:
#   1. GitHub API から pkg の browser_download_url を解決し公式配布パスに制約
#      （_mdm_resolve_brew_pkg_url）
#   2. 代替インストールユーザーを /var/tmp/.homebrew_pkg_user.plist に書く
#      （_mdm_write_brew_pkg_user_plist による排他作成・root 所有 0600。
#      ファイルと対象ユーザーは install 前に存在必須 — 対象ユーザーは R2 で検証済み）
#   3. pkg をダウンロードし pkgutil --check-signature で Homebrew の Team ID に
#      pin した Developer ID 署名を確認
#      （検証失敗時は導入せず終了 — 呼び出し元経由で exit 11 = MDM_EXIT_BREW）
#   4. installer -pkg <pkg> -target / で導入（root 実行）
#   5. 一時ファイル（pkg・plist）をクリーンアップし、brew バイナリの存在で成否判定
#
# curl|bash 経路は撤去済み（パスワードなし sudo が無い環境での非対話ハング
# リスクを避けるため）。pkg 方式が不可能な場合は暗黙フォールバックせず失敗を返す。
_mdm_bootstrap_homebrew() {
  local _user="$1"

  local _pkg_url
  _pkg_url="$(_mdm_resolve_brew_pkg_url)" || {
    mdm_log R3 "Homebrew pkg の URL を解決できない（GitHub API 応答不正 or ネットワーク不可）"
    return 1
  }

  # NOTE: mktemp のテンプレートに XXXXXX の後ろへ拡張子等のサフィックスを
  # 付けると、macOS 標準 (BSD) mktemp は置換をスキップしてテンプレート文字列
  # をそのまま返す（exit 0・ファイル未作成・実機検証済み）。予測可能な
  # パスになりファイル未作成のまま以降の処理が進む重大な不具合になるため、
  # XXXXXX は末尾に置く（拡張子を付けない）。installer(1) は拡張子を要求しない。
  local _pkg
  _pkg="$(mktemp "$(_mdm_safe_tmpdir)/mdm-homebrew-pkg.XXXXXX" 2>/dev/null)" || {
    mdm_log R3 "Homebrew 導入: 一時 pkg パスの作成に失敗"
    return 1
  }
  _MDM_ACTIVE_BREW_PKG="$_pkg"
  _mdm_arm_transient_cleanup

  mdm_log R3 "Homebrew pkg をダウンロード中: $_pkg_url"
  if ! curl -fsSL -o "$_pkg" "$_pkg_url" 2>/dev/null; then
    mdm_log R3 "Homebrew pkg のダウンロードに失敗: $_pkg_url"
    _mdm_cleanup_prereq_artifacts
    return 1
  fi

  # 署名検証: exit code + 証明書チェーンの Developer ID Installer を Homebrew の
  # Team ID (927JGANW46) に pin して確認してから installer にかける（High#7）。
  local _sig_out _sig_rc=0
  _sig_out="$(pkgutil --check-signature "$_pkg" 2>&1)" || _sig_rc=$?
  if [[ $_sig_rc -ne 0 ]] || ! _mdm_check_brew_signature_output "$_sig_out"; then
    mdm_log R3 "Homebrew pkg の署名検証に失敗（Team ID ${_MDM_BREW_TEAM_ID} の Developer ID Installer 署名を確認できない）"
    _mdm_cleanup_prereq_artifacts
    return 1
  fi

  # 代替インストールユーザーの指定（install 直前に作成。ファイルと対象
  # ユーザーは install 前に存在必須 — 一次情報の記載どおり）。
  # symlink 追随を排除した排他作成 + root 所有 0600（brew 側の受理条件）
  local _plist_path="${MDM_BREW_PLIST_OVERRIDE:-/var/tmp/.homebrew_pkg_user.plist}"
  if ! _mdm_write_brew_pkg_user_plist "$_user"; then
    mdm_log R3 "Homebrew 導入: $_plist_path の安全な作成に失敗"
    _mdm_cleanup_prereq_artifacts
    return 1
  fi

  mdm_log R3 "Homebrew pkg を導入中 (HOMEBREW_PKG_USER=$_user)"
  local _rc=0
  installer -pkg "$_pkg" -target / >/dev/null 2>&1 || _rc=$?
  _mdm_cleanup_prereq_artifacts
  if [[ $_rc -ne 0 ]]; then
    mdm_log R3 "Homebrew pkg の導入に失敗 (exit=$_rc)"
    return 1
  fi

  if [[ -x /opt/homebrew/bin/brew || -x /usr/local/bin/brew ]]; then
    return 0
  fi
  mdm_log R3 "Homebrew 導入後もバイナリを検出できない"
  return 1
}

# R3: 前提ブートストラップ。root 実行前提、mdm_prereq_plan が
# "bootstrap" のときのみ呼ばれる。CLT → Homebrew の順（brew の導入自体が
# CLT のコンパイラ/git に依存するため）。
# NOTE: Homebrew は pkg + HOMEBREW_PKG_USER 方式のため対象ユーザーの home は
# 不要（_user のみ渡す）。
# 終了コード契約: CLT 不足=10（前提不足）と
# Homebrew 導入失敗=11 を区別して返す。
_mdm_bootstrap_prereqs() {
  local _user="$1"
  _mdm_ensure_clt || return "$MDM_EXIT_PREREQ"
  _mdm_bootstrap_homebrew "$_user" || return "$MDM_EXIT_BREW"
  return 0
}

# The official native installer creates this fixed symlink layout.  Existence
# or executability alone is not evidence: a target user could pre-place a fake
# executable and make both setup and MDM detection report success.
_mdm_claude_cli_codesign_requirement() {
  # This is the designated requirement emitted by the current Anthropic
  # Developer ID build.  An external requirement is mandatory: plain
  # `codesign --verify` checks a binary against its own (attacker-selected)
  # designated requirement and does not establish Apple trust policy.
  printf '%s' '=identifier "com.anthropic.claude-code" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "Q6L2SF6YDW"'
}

_mdm_claude_codesign() {
  /usr/bin/codesign "$@"
}

_mdm_claude_cli_signature_trusted() { # <fd-bound-snapshot>
  local _snapshot="$1" _requirement _details
  _requirement="$(_mdm_claude_cli_codesign_requirement)" || return 1
  _mdm_claude_codesign --verify --strict -R "$_requirement" \
    "$_snapshot" >/dev/null 2>&1 \
    && _details="$(_mdm_claude_codesign -dv --verbose=4 "$_snapshot" 2>&1)" \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx 'Identifier=com.anthropic.claude-code' \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx 'TeamIdentifier=Q6L2SF6YDW' \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx \
      'Authority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)'
}

_mdm_cli_present_for_home() {
  local _home="$1" _link
  _link="$_home/.local/bin/claude"
  local _versions="$_home/.local/share/claude/versions" _target _canonical
  local _target_uid _snapshot _old_umask _rc=1
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && -n "${MDM_CLAUDE_CLI_TRUST_OVERRIDE:-}" ]]; then
    [[ "$MDM_CLAUDE_CLI_TRUST_OVERRIDE" == "1" ]]
    return
  fi
  [[ -L "$_link" ]] || return 1
  _target="$(/usr/bin/readlink "$_link" 2>/dev/null)" || return 1
  case "$_target" in "$_versions"/*) : ;; *) return 1 ;; esac
  [[ "${_target#"$_versions"/}" =~ ^[0-9A-Za-z._+-]+$ ]] || return 1
  _canonical="$(_mdm_canonical_file "$_target")" || return 1
  [[ "$_canonical" == "$_target" && -x "$_target" ]] || return 1
  _target_uid="$(_mdm_stat_uid "$_home")" || return 1
  [[ "$_target_uid" =~ ^[0-9]+$ ]] || return 1
  _old_umask="$(umask)"; umask 077
  _snapshot="$(/usr/bin/mktemp "$(_mdm_safe_tmpdir)/claude-kit-mdm-cli.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  if ! _mdm_snapshot_bound_to "$_target" "$_snapshot" cli "$_target_uid"; then
    /bin/rm -f "$_snapshot"
    return 1
  fi
  /bin/chmod 700 "$_snapshot" || { /bin/rm -f "$_snapshot"; return 1; }
  if _mdm_claude_cli_signature_trusted "$_snapshot"; then
    _rc=0
  fi
  /bin/rm -f "$_snapshot"
  return "$_rc"
}

_mdm_repo_url() {
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && -n "${MDM_KIT_REPO_URL_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_KIT_REPO_URL_OVERRIDE"
  else
    printf '%s' "$_MDM_KIT_REPO_URL"
  fi
}

_mdm_auth_tmp_base() {
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && -n "${MDM_AUTH_TMPDIR_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_AUTH_TMPDIR_OVERRIDE"
  else
    printf '%s' /private/tmp
  fi
}

_mdm_auth_expected_uid() {
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && -n "${MDM_AUTH_OWNER_UID_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_AUTH_OWNER_UID_OVERRIDE"
  else
    printf '0'
  fi
}

_mdm_auth_base_trusted() {
  local _base="$1" _physical _uid _mode
  [[ -d "$_base" && ! -L "$_base" ]] || return 1
  _physical="$(builtin cd -P -- "$_base" 2>/dev/null && printf '%s' "$PWD")" || return 1
  [[ "$_physical" == "$_base" ]] || return 1
  _uid="$(_mdm_stat_uid "$_base" || true)"
  [[ "$_uid" == "$(_mdm_auth_expected_uid)" ]] || return 1
  _mdm_has_extended_acl "$_base" && return 1
  _mode="$(_mdm_launcher_stat_mode "$_base" || true)"
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && -n "${MDM_AUTH_TMPDIR_OVERRIDE:-}" ]]; then
    _mdm_mode_is_safe "$_mode"
  else
    [[ "$_base" == /private/tmp && "$_mode" == 1777 ]]
  fi
}

# Privileged Git never reads system/global configuration, credentials, hooks,
# or a target-user environment.  The only production remote is the constant
# official URL returned by _mdm_repo_url.
_mdm_auth_git() {
  local _key _value
  local _env=(
    /usr/bin/env -i
    HOME=/var/root
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    LC_ALL=C
    GIT_CONFIG_NOSYSTEM=1
    GIT_CONFIG_GLOBAL=/dev/null
    GIT_TERMINAL_PROMPT=0
    GIT_NO_REPLACE_OBJECTS=1
  )
  for _key in HTTP_PROXY HTTPS_PROXY; do
    _value="${!_key:-}"
    [[ -z "$_value" ]] && continue
    _mdm_root_proxy_url "$_value" >/dev/null || return "$MDM_EXIT_CONFIG"
    _env[${#_env[@]}]="$_key=$_value"
  done
  if [[ -n "${NO_PROXY:-}" ]]; then
    [[ ! "$NO_PROXY" =~ [[:space:][:cntrl:]] ]] || return "$MDM_EXIT_CONFIG"
    _env[${#_env[@]}]="NO_PROXY=$NO_PROXY"
  fi
  "${_env[@]}" /usr/bin/git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}

_mdm_canonical_any() {
  local _path="$1" _target _dir _base _physical _hops=0
  while [[ -L "$_path" ]]; do
    _hops=$((_hops + 1)); [[ "$_hops" -le 40 ]] || return 1
    _target="$(/usr/bin/readlink "$_path" 2>/dev/null)" || return 1
    [[ "$_target" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    if [[ "$_target" == /* ]]; then
      _path="$_target"
    else
      _path="$(/usr/bin/dirname "$_path")/$_target"
    fi
    _dir="$(/usr/bin/dirname "$_path")"
    _base="$(/usr/bin/basename "$_path")"
    _physical="$(builtin cd -P -- "$_dir" 2>/dev/null && printf '%s' "$PWD")" || return 1
    _path="$_physical/$_base"
  done
  if [[ -d "$_path" ]]; then
    builtin cd -P -- "$_path" 2>/dev/null && printf '%s' "$PWD"
  elif [[ -e "$_path" ]]; then
    _dir="$(/usr/bin/dirname "$_path")"
    _base="$(/usr/bin/basename "$_path")"
    _physical="$(builtin cd -P -- "$_dir" 2>/dev/null && printf '%s' "$PWD")" || return 1
    printf '%s/%s' "$_physical" "$_base"
  else
    return 1
  fi
}

_MDM_AUTH_ENTRY_LIST=""
_mdm_auth_entry_list() { # <tree> <output-var>
  local _tree="$1" _output_var="$2" _base _output _old_umask
  _base="$(_mdm_auth_tmp_base)"
  _old_umask="$(umask)"; umask 077
  _output="$(/usr/bin/mktemp "$_base/claude-kit-mdm-list.XXXXXX" 2>/dev/null)" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  _MDM_AUTH_ENTRY_LIST="$_output"
  /usr/bin/find "$_tree" -xdev -print0 > "$_output" || {
    /bin/rm -f "$_output"; _MDM_AUTH_ENTRY_LIST=""
    return 1
  }
  printf -v "$_output_var" '%s' "$_output"
}

_mdm_normalize_auth_tree() {
  local _tree="$1" _entry _mode_dir=755 _list=""
  local _mode_exec=755 _mode_file=644
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && "${MDM_AUTH_READONLY_OWNER_TEST:-0}" == "1" ]]; then
    _mode_dir=555; _mode_exec=555; _mode_file=444
  fi
  # Never let chmod follow a repository-provided setup.sh symlink. The
  # authoritative checkout is data until its complete tree has been validated.
  [[ -f "$_tree/setup.sh" && ! -L "$_tree/setup.sh" ]] || return 1
  _mdm_auth_entry_list "$_tree" _list || return 1
  while IFS= read -r -d '' _entry; do
    if [[ -L "$_entry" ]]; then
      :
    elif [[ -d "$_entry" ]]; then
      /bin/chmod "$_mode_dir" "$_entry" || { /bin/rm -f "$_list"; _MDM_AUTH_ENTRY_LIST=""; return 1; }
    elif [[ -f "$_entry" ]]; then
      if [[ -x "$_entry" ]]; then
        /bin/chmod "$_mode_exec" "$_entry" || { /bin/rm -f "$_list"; _MDM_AUTH_ENTRY_LIST=""; return 1; }
      else
        /bin/chmod "$_mode_file" "$_entry" || { /bin/rm -f "$_list"; _MDM_AUTH_ENTRY_LIST=""; return 1; }
      fi
    else
      /bin/rm -f "$_list"; _MDM_AUTH_ENTRY_LIST=""
      return 1
    fi
  done < "$_list"
  /bin/rm -f "$_list"; _MDM_AUTH_ENTRY_LIST=""
  /bin/chmod "$_mode_exec" "$_tree/setup.sh"
}

_mdm_auth_tree_trusted() {
  local _tree="$1" _expected _list _entry _uid _mode _target _rc=0
  _expected="$(_mdm_auth_expected_uid)"
  [[ -d "$_tree" && ! -L "$_tree" ]] || return 1
  _list=""
  _mdm_auth_entry_list "$_tree" _list || return 1
  while IFS= read -r -d '' _entry; do
    _uid="$(_mdm_stat_uid "$_entry" || true)"
    if [[ "$_uid" != "$_expected" ]] || _mdm_has_extended_acl "$_entry"; then
      _rc=1; break
    fi
    if [[ -L "$_entry" ]]; then
      _target="$(_mdm_canonical_any "$_entry" || true)"
      case "$_target" in "$_tree"|"$_tree"/*) : ;; *) _rc=1; break ;; esac
    elif [[ -d "$_entry" || -f "$_entry" ]]; then
      _mode="$(_mdm_stat_mode "$_entry" || true)"
      _mdm_mode_is_safe "$_mode" || { _rc=1; break; }
    else
      _rc=1; break
    fi
  done < "$_list"
  /bin/rm -f "$_list"; _MDM_AUTH_ENTRY_LIST=""
  [[ "$_rc" -eq 0 && -f "$_tree/setup.sh" && ! -L "$_tree/setup.sh" && -x "$_tree/setup.sh" ]]
}

_mdm_auth_tree_private_for_uid() { # <tree> <target-uid>
  local _tree="$1" _target_uid="$2"
  [[ "$_target_uid" =~ ^[0-9]+$ ]] || return 1
  [[ "$_target_uid" != "$(_mdm_auth_expected_uid)" ]] || return 1
  _mdm_auth_tree_trusted "$_tree"
}

_mdm_system_python() {
  local _python=/usr/bin/python3 _details
  if [[ "${_MDM_TEST_MODE:-0}" == 1 ]]; then
    _python="${MDM_SYSTEM_PYTHON_OVERRIDE:-/usr/bin/python3}"
    [[ "$_python" == /* && -x "$_python" && ! -L "$_python" ]] || return 1
    printf '%s' "$_python"
    return 0
  fi
  [[ -x "$_python" && ! -L "$_python" ]] || return 1
  /usr/bin/codesign --verify --strict "$_python" >/dev/null 2>&1 || return 1
  _details="$(/usr/bin/codesign -dv --verbose=4 "$_python" 2>&1)" || return 1
  printf '%s\n' "$_details" | /usr/bin/grep -q '^Platform identifier=' || return 1
  printf '%s\n' "$_details" | /usr/bin/grep -qx 'Authority=Software Signing' || return 1
  printf '%s\n' "$_details" | /usr/bin/grep -qx 'Authority=Apple Root CA' || return 1
  printf '%s' "$_python"
}

_mdm_expected_tree_trusted() { # <rendered-output>
  local _root="$1" _physical _list="" _entry _uid _mode _identity _size
  local _metadata _metadata_rest _links
  local _count=0 _aggregate=0 _expected
  [[ -d "$_root" && ! -L "$_root" ]] || return 1
  _physical="$(builtin cd -P -- "$_root" 2>/dev/null && printf '%s' "$PWD")" || return 1
  [[ "$_physical" == "$_root" ]] || return 1
  _expected="$(_mdm_auth_expected_uid)"
  _mdm_auth_entry_list "$_root" _list || return 1
  while IFS= read -r -d '' _entry; do
    _count=$((_count + 1)); [[ "$_count" -le 2000 ]] || { /bin/rm -f "$_list"; return 1; }
    [[ ! -L "$_entry" ]] || { /bin/rm -f "$_list"; return 1; }
    _uid="$(_mdm_stat_uid "$_entry" || true)"
    [[ "$_uid" == "$_expected" ]] || { /bin/rm -f "$_list"; return 1; }
    _mdm_has_extended_acl "$_entry" && { /bin/rm -f "$_list"; return 1; }
    _mode="$(_mdm_launcher_stat_mode "$_entry" || true)"
    _mdm_mode_is_safe "$_mode" || { /bin/rm -f "$_list"; return 1; }
    if [[ -f "$_entry" ]]; then
      _identity="$(_mdm_stat_identity "$_entry")" || { /bin/rm -f "$_list"; return 1; }
      case "$_identity" in *:Regular\ File:*|*:regular\ file:*) : ;; *) /bin/rm -f "$_list"; return 1 ;; esac
      _metadata="$(_mdm_stat_managed_metadata "$_entry")" \
        || { /bin/rm -f "$_list"; return 1; }
      [[ "$_metadata" =~ ^[0-9]+:[0-9]+:[0-7]+$ ]] \
        || { /bin/rm -f "$_list"; return 1; }
      _metadata_rest="${_metadata#*:}"
      _links="${_metadata_rest%%:*}"
      [[ "$_links" == 1 ]] || { /bin/rm -f "$_list"; return 1; }
      _size="${_identity##*:}"
      [[ "$_size" =~ ^[0-9]+$ && "$_size" -le 67108864 ]] \
        || { /bin/rm -f "$_list"; return 1; }
      _aggregate=$((_aggregate + 10#$_size))
      (( _aggregate <= 536870912 )) || { /bin/rm -f "$_list"; return 1; }
    elif [[ ! -d "$_entry" ]]; then
      /bin/rm -f "$_list"; return 1
    fi
  done < "$_list"
  /bin/rm -f "$_list"; _MDM_AUTH_ENTRY_LIST=""
  [[ "$_count" -gt 3 && -d "$_root/tree" && ! -L "$_root/tree" \
    && -f "$_root/modes.tsv" && ! -L "$_root/modes.tsv" \
    && -f "$_root/manifest.json" && ! -L "$_root/manifest.json" ]]
}

_mdm_prior_relative_is_safe() {
  local _relative="$1"
  [[ -n "$_relative" && "$_relative" != /* \
    && ! "$_relative" =~ [[:cntrl:]] ]] || return 1
  case "/$_relative/" in */../*|*/./*|*//*) return 1 ;; esac
  [[ "${#_relative}" -le 1024 ]]
}

# Deletion authority is independent of the target-user manifest and latest
# receipt.  Only paths that passed a prior root postcondition as actually
# deployed are persisted here; profile-disabled/absent candidates must never
# become deletion authority merely because a remediation was attempted.
_mdm_capture_prior_inventory() { # <user> <home> <target-uid>
  local _user="$1" _home="$2" _target_uid="$3"
  local _history_dir _history _history_copy="" _count _index _relative
  local _raw="" _inventory="" _old_umask _unique_count
  : "$_target_uid"
  _MDM_PRIOR_INVENTORY=""
  _history_dir="$(_mdm_receipt_dir_for "$_home")"
  _history="$_history_dir/managed-history-$_user.json"
  [[ -e "$_history" || -L "$_history" ]] || return 0
  if [[ "${_MDM_TEST_MODE:-0}" == 1 && -n "${MDM_SYSTEM_RCPT_DIR_OVERRIDE:-}" ]]; then
    _mdm_component_trusted "$_history_dir" && _mdm_component_trusted "$_history" \
      || return 1
  else
    _mdm_verify_dir_chain "$_history_dir" "/Library/Application Support" \
      && _mdm_component_trusted "$_history" || return 1
  fi
  _history_copy="$(_mdm_stable_file_snapshot "$_history" receipt)" || return 1
  if ! _mdm_json_valid "$_history_copy" \
    || [[ "$(_mdm_json_get "$_history_copy" schema_version)" != 1 ]] \
    || [[ "$(_mdm_json_get "$_history_copy" target_user)" != "$_user" ]] \
    || [[ "$(_mdm_json_get "$_history_copy" home)" != "$_home" ]]; then
    /bin/rm -f "$_history_copy"
    return 1
  fi
  _count="$(_mdm_json_array_count "$_history_copy" managed_inventory)"
  [[ "$_count" =~ ^[0-9]+$ && "$_count" -gt 0 && "$_count" -le 2000 ]] \
    || { /bin/rm -f "$_history_copy"; return 1; }
  _old_umask="$(umask)"; umask 077
  _raw="$(/usr/bin/mktemp "$(_mdm_safe_tmpdir)/claude-kit-mdm-prior-raw.XXXXXX")" \
    || { umask "$_old_umask"; /bin/rm -f "$_history_copy"; return 1; }
  _inventory="$(/usr/bin/mktemp "$(_mdm_safe_tmpdir)/claude-kit-mdm-prior.XXXXXX")" \
    || { umask "$_old_umask"; /bin/rm -f "$_history_copy" "$_raw"; return 1; }
  umask "$_old_umask"
  _index=0
  while (( _index < _count )); do
    _relative="$(_mdm_json_array_get "$_history_copy" managed_inventory "$_index")"
    _mdm_prior_relative_is_safe "$_relative" \
      && printf '%s\n' "$_relative" >> "$_raw" \
      || { /bin/rm -f "$_history_copy" "$_raw" "$_inventory"; return 1; }
    _index=$((_index + 1))
  done
  LC_ALL=C /usr/bin/sort -u "$_raw" > "$_inventory" \
    || { /bin/rm -f "$_history_copy" "$_raw" "$_inventory"; return 1; }
  _unique_count="$(/usr/bin/wc -l < "$_inventory" | /usr/bin/tr -d '[:space:]')"
  [[ "$_unique_count" == "$_count" ]] \
    && /bin/chmod 444 "$_inventory" \
    || { /bin/rm -f "$_history_copy" "$_raw" "$_inventory"; return 1; }
  /bin/rm -f "$_history_copy" "$_raw"
  _MDM_PRIOR_INVENTORY="$_inventory"
  _mdm_arm_transient_cleanup
}

_mdm_persist_managed_history() { # <user> <home>
  local _user="$1" _home="$2" _manifest="${_MDM_EXPECTED_OUTPUT:-}/manifest.json"
  local _dir _path _tmp _raw _count _index _relative _total=0 _old_umask _sep=""
  [[ -f "$_manifest" && ! -L "$_manifest" ]] || return 1
  _dir="$(_mdm_receipt_dir_for "$_home")"
  _path="$_dir/managed-history-$_user.json"
  if [[ "${_MDM_TEST_MODE:-0}" == 1 && -n "${MDM_SYSTEM_RCPT_DIR_OVERRIDE:-}" ]]; then
    [[ -d "$_dir" ]] || /bin/mkdir -p "$_dir" || return 1
    _mdm_component_trusted "$_dir" || return 1
  else
    _mdm_verify_dir_chain "$_dir" "/Library/Application Support" || return 1
    /bin/mkdir -p "$_dir" || return 1
    _mdm_component_trusted "$_dir" || return 1
  fi
  [[ ! -e "$_path" || -f "$_path" || -L "$_path" ]] || return 1
  _old_umask="$(umask)"; umask 077
  _raw="$(/usr/bin/mktemp "$(_mdm_safe_tmpdir)/claude-kit-mdm-history-raw.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  _tmp="$(/usr/bin/mktemp "$_dir/.managed-history.XXXXXX")" \
    || { umask "$_old_umask"; /bin/rm -f "$_raw"; return 1; }
  umask "$_old_umask"
  _count="$(_mdm_json_array_count "$_manifest" files)"
  [[ "$_count" =~ ^[0-9]+$ && "$_count" -gt 0 && "$_count" -le 1000 ]] \
    || { /bin/rm -f "$_raw" "$_tmp"; return 1; }
  _index=0
  while (( _index < _count )); do
    _relative="$(_mdm_json_array_get "$_manifest" files "$_index")"
    _mdm_prior_relative_is_safe "$_relative" \
      && printf '%s\n' "$_relative" >> "$_raw" \
      || { /bin/rm -f "$_raw" "$_tmp"; return 1; }
    _index=$((_index + 1)); _total=$((_total + 1))
  done
  [[ "$_total" -gt 0 && "$_total" -le 2000 ]] \
    || { /bin/rm -f "$_raw" "$_tmp"; return 1; }
  LC_ALL=C /usr/bin/sort -u -o "$_raw" "$_raw" \
    || { /bin/rm -f "$_raw" "$_tmp"; return 1; }
  _total="$(/usr/bin/wc -l < "$_raw" | /usr/bin/tr -d '[:space:]')"
  [[ "$_total" =~ ^[0-9]+$ && "$_total" -gt 0 && "$_total" -le 2000 ]] \
    || { /bin/rm -f "$_raw" "$_tmp"; return 1; }
  {
    printf '{\n  "schema_version": 1,\n'
    printf '  "target_user": "%s",\n' "$(mdm_json_escape "$_user")"
    printf '  "home": "%s",\n' "$(mdm_json_escape "$_home")"
    printf '  "managed_inventory": ['
    _sep=""
    while IFS= read -r _relative; do
      printf '%s"%s"' "$_sep" "$(mdm_json_escape "$_relative")"
      _sep=,
    done < "$_raw"
    printf ']\n}\n'
  } > "$_tmp" || { /bin/rm -f "$_raw" "$_tmp"; return 1; }
  /bin/chmod 644 "$_tmp" \
    && /bin/mv -f "$_tmp" "$_path" \
    && _mdm_component_trusted "$_path" \
    || { /bin/rm -f "$_raw" "$_tmp"; return 1; }
  /bin/rm -f "$_raw"
}

_mdm_prepare_expected_state() { # <logical-home>
  local _home="$1" _base _workspace _output _renderer _python _old_umask
  local _key _value _normalized
  local _args=() _override_keys
  _renderer="${_MDM_EXPECTED_RENDERER:-}"
  [[ -n "$_renderer" && -f "$_renderer" && ! -L "$_renderer" ]] || {
    mdm_log U1b "信頼済み期待状態rendererがない"
    return 1
  }
  if [[ "${_MDM_TEST_MODE:-0}" != 1 ]]; then
    [[ "${_MDM_EXPECTED_RENDERER_SNAPSHOT:-0}" == 1 ]] || return 1
    case "$_renderer" in /private/tmp/claude-kit-mdm-launcher.*) : ;; *) return 1 ;; esac
  fi
  _python="$(_mdm_system_python)" || { mdm_log U1b "Apple署名済みsystem Pythonを確認できない"; return 1; }
  _base="$(_mdm_auth_tmp_base)"
  _old_umask="$(umask)"; umask 077
  _workspace="$(/usr/bin/mktemp -d "$_base/claude-kit-mdm-expected.XXXXXX" 2>/dev/null)" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  /bin/chmod 700 "$_workspace" || return 1
  _MDM_EXPECTED_DIR="$_workspace"
  _MDM_EXPECTED_OUTPUT="$_workspace/rendered"
  _mdm_arm_transient_cleanup
  _output="$_MDM_EXPECTED_OUTPUT"
  _args=(
    --checkout "$_MDM_AUTH_CHECKOUT"
    --output "$_output"
    --profile "${PROFILE:-standard}"
    --language "${LANGUAGE:-en}"
    --logical-home "$_home"
  )
  _override_keys="COMMIT_ATTRIBUTION ENABLE_STATUSLINE ENABLE_SAFETY_NET \
ENABLE_AUTO_UPDATE ENABLE_DOC_SIZE_GUARD ENABLE_FEATURE_RECOMMENDATION \
ENABLE_PRE_COMPACT_COMMIT ENABLE_WEB_CONTENT_UPDATE ENABLE_NO_FLICKER ENABLE_NEW_INIT \
ENABLE_CODEX_PLUGIN"
  for _key in $_override_keys; do
    _value="${!_key:-}"
    [[ -n "$_value" ]] || continue
    _normalized="$(_mdm_root_bool "$_value")" || return 1
    _args[${#_args[@]}]=--override
    _args[${#_args[@]}]="$_key=$_normalized"
  done
  if [[ -n "${_MDM_PRIOR_INVENTORY:-}" ]]; then
    _mdm_component_trusted "$_MDM_PRIOR_INVENTORY" || return 1
    while IFS= read -r _value || [[ -n "$_value" ]]; do
      _mdm_prior_relative_is_safe "$_value" || return 1
      _args[${#_args[@]}]=--prior-managed
      _args[${#_args[@]}]="$_value"
    done < "$_MDM_PRIOR_INVENTORY"
  fi
  mdm_log U1b "信頼済みrendererで期待状態を生成"
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B "$_renderer" "${_args[@]}" >/dev/null 2>&1 || return 1
  _mdm_expected_tree_trusted "$_output" || return 1
}

# Detached HEAD is data, not an invitation to execute Git against a mutable
# checkout after setup. Copy it through the bounded watchdog path so a
# target-user race from a regular file to a FIFO cannot block root remediation.
_mdm_detached_head_matches() { # <repo> <full-sha> [expected-uid]
  local _repo="$1" _sha="$2" _expected_uid="${3:-}"
  local _head _before _size _value _snapshot _old_umask
  [[ "$_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ -d "$_repo/.git" && ! -L "$_repo/.git" ]] || return 1
  _head="$_repo/.git/HEAD"
  [[ -f "$_head" && ! -L "$_head" ]] || return 1
  _before="$(_mdm_stat_identity "$_head")" || return 1
  case "$_before" in *:Regular\ File:*|*:regular\ file:*) : ;; *) return 1 ;; esac
  _size="${_before##*:}"; [[ "$_size" == 41 ]] || return 1
  [[ -z "$_expected_uid" || "$_expected_uid" =~ ^[0-9]+$ ]] || return 1
  _old_umask="$(umask)"; umask 077
  _snapshot="$(/usr/bin/mktemp "$(_mdm_safe_tmpdir)/claude-kit-mdm-head.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  if ! _mdm_snapshot_bound_to "$_head" "$_snapshot" head "$_expected_uid"; then
    /bin/rm -f "$_snapshot"
    return 1
  fi
  IFS= read -r _value < "$_snapshot" || { /bin/rm -f "$_snapshot"; return 1; }
  /bin/rm -f "$_snapshot"
  [[ "$_value" == "$_sha" ]]
}

_MDM_AUTH_CHECKOUT=""
_MDM_DRYRUN_CHECKOUT=""
_MDM_PERSISTENT_STAGE=""
_MDM_PERSISTENT_STAGE_IDENTITY=""
_MDM_EXPECTED_DIR=""
_MDM_EXPECTED_OUTPUT=""
_MDM_PRIOR_INVENTORY=""
_MDM_RUN_LOCK_FILE=""
_MDM_RUN_LOCK_BASE=""
_MDM_RUN_LOCK_MODE=""
_MDM_RUN_LOCK_HOLDER_PID=""
_MDM_RUN_LOCK_WORKER_PID=""
_MDM_RUN_LOCK_CONTROL_DIR=""

_mdm_process_parent_pid() { # <pid>
  local _pid="$1"
  [[ "$_pid" =~ ^[0-9]+$ ]] || return 1
  /bin/ps -p "$_pid" -o ppid= 2>/dev/null | /usr/bin/tr -d '[:space:]'
}

_mdm_lock_control_cleanup() { # <base> <control-dir>
  local _base="$1" _control="$2" _entry
  [[ -n "$_control" ]] || return 0
  case "$_control" in "$_base"/.remediation-lock.*) : ;; *) return 1 ;; esac
  [[ ! -L "$_control" ]] || return 1
  [[ -e "$_control" ]] || return 0
  [[ -d "$_control" ]] || return 1
  _mdm_component_trusted "$_control" || return 1
  for _entry in owner ready release; do
    [[ ! -L "$_control/$_entry" ]] || return 1
    [[ ! -e "$_control/$_entry" || -f "$_control/$_entry" ]] || return 1
  done
  /bin/rm -f "$_control/owner" "$_control/ready" "$_control/release" || return 1
  /bin/rmdir "$_control" 2>/dev/null || [[ ! -e "$_control" ]]
}

_mdm_wait_lock_holder() { # <holder-pid>
  local _holder="$1" _watchdog _wait_rc=0
  [[ "$_holder" =~ ^[0-9]+$ ]] || return 1
  (
    trap 'exit 0' TERM
    _watch_count=0
    while [[ "$_watch_count" -lt 500 ]]; do
      /bin/sleep 0.01
      _watch_count=$((_watch_count + 1))
    done
    /bin/kill -TERM "$_holder" 2>/dev/null || exit 0
    /bin/sleep 0.2
    /bin/kill -KILL "$_holder" 2>/dev/null || true
  ) &
  _watchdog=$!
  wait "$_holder" 2>/dev/null || _wait_rc=$?
  /bin/kill -TERM "$_watchdog" 2>/dev/null || true
  wait "$_watchdog" 2>/dev/null || true
  return "$_wait_rc"
}

_mdm_abort_legacy_lock_holder() { # <base> <control-dir> <holder-pid> <worker-pid>
  local _base="$1" _control="$2" _holder="$3" _worker="$4"
  if [[ "$_worker" =~ ^[0-9]+$ ]]; then
    /bin/kill -TERM "$_worker" 2>/dev/null || true
  fi
  if [[ "$_holder" =~ ^[0-9]+$ ]]; then
    /bin/kill -TERM "$_holder" 2>/dev/null || true
    _mdm_wait_lock_holder "$_holder" || true
  fi
  _mdm_lock_control_cleanup "$_base" "$_control" || true
}

_mdm_acquire_run_lock() { # <user> <home>
  local _user="$1" _home="$2" _base _lock _lockf=/usr/bin/lockf
  local _old_umask _path_identity _fd_identity _lock_rc=0
  local _control="" _owner_file _ready _release _holder="" _worker="" _reported_holder
  local _owner_pid _ready_line _wait_count=0
  _base="$(_mdm_receipt_dir_for "$_home")"
  if [[ "${_MDM_TEST_MODE:-0}" == 1 && -n "${MDM_SYSTEM_RCPT_DIR_OVERRIDE:-}" ]]; then
    [[ -d "$_base" ]] || /bin/mkdir -p "$_base" || return 1
    _mdm_component_trusted "$_base" || return 1
  else
    _mdm_verify_dir_chain "$_base" "/Library/Application Support" || return 1
    /bin/mkdir -p "$_base" || return 1
    _mdm_component_trusted "$_base" || return 1
  fi
  if [[ "${_MDM_TEST_MODE:-0}" == 1 && -n "${MDM_LOCKF_OVERRIDE:-}" ]]; then
    _lockf="$MDM_LOCKF_OVERRIDE"
  fi
  [[ "$_lockf" == /* && -x "$_lockf" && ! -L "$_lockf" ]] || return 1
  _lock="$_base/remediation-$_user.lock"
  [[ ! -e "$_lock" || ( -f "$_lock" && ! -L "$_lock" ) ]] || return 1
  _old_umask="$(umask)"; umask 077
  if [[ ! -e "$_lock" ]]; then
    (set -o noclobber; : > "$_lock") 2>/dev/null || true
  fi
  umask "$_old_umask"
  [[ -f "$_lock" && ! -L "$_lock" ]] || return 1
  /bin/chmod 600 "$_lock" || return 1
  exec 19>>"$_lock" || return 1
  _path_identity="$(_mdm_stat_identity "$_lock")" || { exec 19>&-; return 1; }
  _fd_identity="$(_mdm_stat_fd_identity 19)" || { exec 19>&-; return 1; }
  [[ "$_path_identity" == "$_fd_identity" ]] || { exec 19>&-; return 1; }

  # shell_cmds-319 added lockf's fd-only form.  Keep that race-free form on
  # current macOS, but fall back to the traditional command form on older
  # managed releases where a missing command exits with EX_USAGE (64).
  "$_lockf" -s -t 0 19 >/dev/null 2>&1 || _lock_rc=$?
  if [[ "$_lock_rc" -eq 0 ]]; then
    _MDM_RUN_LOCK_MODE="fd"
  elif [[ "$_lock_rc" -eq 64 ]]; then
    exec 19>&-
    _old_umask="$(umask)"; umask 077
    _control="$(/usr/bin/mktemp -d "$_base/.remediation-lock.XXXXXX" 2>/dev/null)" \
      || { umask "$_old_umask"; return 1; }
    umask "$_old_umask"
    case "$_control" in "$_base"/.remediation-lock.*) : ;; *) return 1 ;; esac
    [[ -d "$_control" && ! -L "$_control" ]] || return 1
    /bin/chmod 700 "$_control" || return 1
    _mdm_component_trusted "$_control" || return 1
    _owner_file="$_control/owner"
    _ready="$_control/ready"
    _release="$_control/release"
    _old_umask="$(umask)"; umask 077
    /bin/sh -c 'printf "%s\n" "$PPID"' > "$_owner_file"
    _lock_rc=$?
    umask "$_old_umask"
    if [[ "$_lock_rc" -ne 0 || ! -f "$_owner_file" || -L "$_owner_file" ]] \
      || ! _mdm_component_trusted "$_owner_file"; then
      _mdm_lock_control_cleanup "$_base" "$_control" || true
      return 1
    fi
    _owner_pid="$(/bin/cat "$_owner_file" 2>/dev/null || true)"
    /bin/rm -f "$_owner_file" || return 1
    [[ "$_owner_pid" =~ ^[0-9]+$ ]] \
      || { _mdm_lock_control_cleanup "$_base" "$_control" || true; return 1; }

    "$_lockf" -k -n -s -t 0 "$_lock" /bin/sh -c '
      _owner_pid=$1
      _control=$2
      _ready=$3
      _release=$4
      _lockf_pid=$PPID
      _cleanup() {
        /bin/rm -f "$_control/owner" "$_ready" "$_release"
        /bin/rmdir "$_control" 2>/dev/null || :
      }
      trap _cleanup EXIT
      trap "exit 0" INT TERM
      umask 077
      printf "%s:%s\n" "$$" "$_lockf_pid" > "$_ready" || exit 1
      while [ ! -e "$_release" ]; do
        _parent="$(/bin/ps -p "$_lockf_pid" -o ppid= 2>/dev/null \
          | /usr/bin/tr -d "[:space:]")"
        [ "$_parent" = "$_owner_pid" ] || break
        /bin/sleep 0.1
      done
    ' mdm-lock-holder "$_owner_pid" "$_control" "$_ready" "$_release" &
    _holder=$!

    while [[ ! -e "$_ready" && "$_wait_count" -lt 500 ]]; do
      /bin/kill -0 "$_holder" 2>/dev/null || break
      /bin/sleep 0.01
      _wait_count=$((_wait_count + 1))
    done
    if [[ ! -f "$_ready" || -L "$_ready" ]] \
      || ! _mdm_component_trusted "$_ready"; then
      _mdm_abort_legacy_lock_holder "$_base" "$_control" "$_holder" "$_worker"
      return 1
    fi
    _ready_line="$(/bin/cat "$_ready" 2>/dev/null || true)"
    if [[ ! "$_ready_line" =~ ^[0-9]+:[0-9]+$ ]]; then
      _mdm_abort_legacy_lock_holder "$_base" "$_control" "$_holder" "$_worker"
      return 1
    fi
    _worker="${_ready_line%%:*}"
    _reported_holder="${_ready_line#*:}"
    if [[ "$_reported_holder" != "$_holder" ]] \
      || [[ "$(_mdm_process_parent_pid "$_holder" || true)" != "$_owner_pid" ]] \
      || [[ "$(_mdm_process_parent_pid "$_worker" || true)" != "$_holder" ]]; then
      _mdm_abort_legacy_lock_holder "$_base" "$_control" "$_holder" "$_worker"
      return 1
    fi
    _MDM_RUN_LOCK_MODE="legacy"
    _MDM_RUN_LOCK_HOLDER_PID="$_holder"
    _MDM_RUN_LOCK_WORKER_PID="$_worker"
    _MDM_RUN_LOCK_CONTROL_DIR="$_control"
  else
    exec 19>&-
    return 1
  fi
  _MDM_RUN_LOCK_FILE="$_lock"
  _MDM_RUN_LOCK_BASE="$_base"
  _mdm_arm_transient_cleanup
}

_mdm_release_run_lock() {
  local _lock="${_MDM_RUN_LOCK_FILE:-}" _base="${_MDM_RUN_LOCK_BASE:-}"
  local _mode="${_MDM_RUN_LOCK_MODE:-}" _control="${_MDM_RUN_LOCK_CONTROL_DIR:-}"
  local _holder="${_MDM_RUN_LOCK_HOLDER_PID:-}" _worker="${_MDM_RUN_LOCK_WORKER_PID:-}"
  local _release _old_umask _wait_rc=0
  [[ -n "$_lock" ]] || return 0
  [[ -n "$_base" && "$_lock" == "$_base"/remediation-*.lock \
    && -f "$_lock" && ! -L "$_lock" ]] || return 1
  case "$_mode" in
    fd)
      exec 19>&- || return 1 ;;
    legacy)
      [[ "$_holder" =~ ^[0-9]+$ && "$_worker" =~ ^[0-9]+$ ]] || return 1
      [[ -n "$_control" ]] || return 1
      case "$_control" in "$_base"/.remediation-lock.*) : ;; *) return 1 ;; esac
      [[ -d "$_control" && ! -L "$_control" ]] || return 1
      _mdm_component_trusted "$_control" || return 1
      _release="$_control/release"
      [[ ! -e "$_release" && ! -L "$_release" ]] || return 1
      _old_umask="$(umask)"; umask 077
      (set -o noclobber; : > "$_release") 2>/dev/null \
        || { umask "$_old_umask"; return 1; }
      umask "$_old_umask"
      _mdm_wait_lock_holder "$_holder" || _wait_rc=$?
      _mdm_lock_control_cleanup "$_base" "$_control" || return 1
      [[ "$_wait_rc" -eq 0 ]] || return 1 ;;
    *) return 1 ;;
  esac
  _MDM_RUN_LOCK_FILE=""
  _MDM_RUN_LOCK_BASE=""
  _MDM_RUN_LOCK_MODE=""
  _MDM_RUN_LOCK_HOLDER_PID=""
  _MDM_RUN_LOCK_WORKER_PID=""
  _MDM_RUN_LOCK_CONTROL_DIR=""
}
_mdm_cleanup_auth_entry_list() {
  local _path="${_MDM_AUTH_ENTRY_LIST:-}" _base _uid
  [[ -n "$_path" ]] || return 0
  _base="$(_mdm_auth_tmp_base)"
  case "$_path" in "$_base"/claude-kit-mdm-list.*) : ;; *) return 1 ;; esac
  [[ -f "$_path" && ! -L "$_path" ]] || return 1
  _uid="$(_mdm_stat_uid "$_path" || true)"
  [[ "$_uid" == "$(_mdm_auth_expected_uid)" ]] || return 1
  /bin/rm -f "$_path" || return 1
  _MDM_AUTH_ENTRY_LIST=""
}

_mdm_cleanup_auth_checkout() {
  local _path="${_MDM_AUTH_CHECKOUT:-}" _base _uid
  [[ -n "$_path" ]] || return 0
  _base="$(_mdm_auth_tmp_base)"
  case "$_path" in "$_base"/claude-kit-mdm-auth.*) : ;; *) return 1 ;; esac
  [[ -d "$_path" && ! -L "$_path" ]] || return 1
  _uid="$(_mdm_stat_uid "$_path" || true)"
  [[ "$_uid" == "$(_mdm_auth_expected_uid)" ]] || return 1
  /usr/bin/find "$_path" -xdev -type d -exec /bin/chmod 700 '{}' + 2>/dev/null || true
  /bin/rm -rf "$_path" 2>/dev/null || return 1
  _MDM_AUTH_CHECKOUT=""
}

_mdm_cleanup_dryrun_checkout() {
  local _path="${_MDM_DRYRUN_CHECKOUT:-}"
  [[ -n "$_path" ]] || return 0
  case "$_path" in
    /private/tmp/claude-kit-mdm-dryrun.*|/tmp/claude-kit-mdm-dryrun.*) ;;
    *) mdm_log R4 "dry-run 一時パスの形式が不正。削除しない: $_path"; return 1 ;;
  esac
  _mdm_run_maybe_as_user /bin/rm -rf "$_path" 2>/dev/null || true
  _MDM_DRYRUN_CHECKOUT=""
}

_mdm_cleanup_persistent_stage() {
  local _path="${_MDM_PERSISTENT_STAGE:-}" _expected _name _current
  [[ -n "$_path" ]] || return 0
  _expected="${_MDM_PERSISTENT_STAGE_IDENTITY:-}"
  [[ -n "$_expected" ]] || return 1
  _name="${_path##*/}"
  case "$_name" in .claude-starter-kit.mdm-stage.*) : ;; *) return 1 ;; esac
  if [[ ! -e "$_path" && ! -L "$_path" ]]; then
    _MDM_PERSISTENT_STAGE=""
    _MDM_PERSISTENT_STAGE_IDENTITY=""
    return 0
  fi
  [[ -d "$_path" && ! -L "$_path" ]] || return 1
  _current="$(_mdm_persistent_dir_identity "$_path" || true)"
  [[ "$_current" == "$_expected" ]] || return 1
  # The stage and its parent belong to the target user. Cleanup stays in the
  # same dropped-privilege context and is identity-bound so a pathname swap
  # cannot redirect recursive deletion to an unrelated directory.
  _mdm_run_maybe_as_user /bin/rm -rf "$_path" 2>/dev/null || return 1
  [[ ! -e "$_path" && ! -L "$_path" ]] || return 1
  _MDM_PERSISTENT_STAGE=""
  _MDM_PERSISTENT_STAGE_IDENTITY=""
}

_mdm_cleanup_expected_dir() {
  local _path="${_MDM_EXPECTED_DIR:-}" _base _uid
  [[ -n "$_path" ]] || return 0
  _base="$(_mdm_auth_tmp_base)"
  case "$_path" in "$_base"/claude-kit-mdm-expected.*) : ;; *) return 1 ;; esac
  [[ -d "$_path" && ! -L "$_path" ]] || return 1
  _uid="$(_mdm_stat_uid "$_path" || true)"
  [[ "$_uid" == "$(_mdm_auth_expected_uid)" ]] || return 1
  /usr/bin/find "$_path" -xdev -type d -exec /bin/chmod 700 '{}' + 2>/dev/null || true
  /bin/rm -rf "$_path" 2>/dev/null || return 1
  _MDM_EXPECTED_DIR=""
  _MDM_EXPECTED_OUTPUT=""
}

_mdm_cleanup_prior_inventory() {
  local _path="${_MDM_PRIOR_INVENTORY:-}" _uid
  [[ -n "$_path" ]] || return 0
  case "$_path" in
    /private/tmp/claude-kit-mdm-prior.*|/tmp/claude-kit-mdm-prior.*) ;;
    *) return 1 ;;
  esac
  [[ -f "$_path" && ! -L "$_path" ]] || return 1
  _uid="$(_mdm_stat_uid "$_path" || true)"
  [[ "$_uid" == "$(_mdm_auth_expected_uid)" ]] || return 1
  /bin/rm -f "$_path" || return 1
  _MDM_PRIOR_INVENTORY=""
}

_mdm_cleanup_renderer_snapshot() {
  local _path="${_MDM_EXPECTED_RENDERER:-}" _uid
  [[ "${_MDM_EXPECTED_RENDERER_SNAPSHOT:-0}" == 1 && -n "$_path" ]] || return 0
  case "$_path" in
    /private/tmp/claude-kit-mdm-launcher.*|/tmp/claude-kit-mdm-launcher.*) ;;
    *) return 1 ;;
  esac
  [[ -f "$_path" && ! -L "$_path" ]] || return 1
  _uid="$(_mdm_stat_uid "$_path" || true)"
  [[ "$_uid" == "$(_mdm_auth_expected_uid)" ]] || return 1
  /bin/rm -f "$_path" || return 1
  _MDM_EXPECTED_RENDERER=""
  _MDM_EXPECTED_RENDERER_SNAPSHOT=0
}

_mdm_cleanup_transient_checkouts() {
  trap - EXIT INT TERM
  _mdm_cleanup_prereq_artifacts || true
  _mdm_cleanup_auth_entry_list || true
  _mdm_cleanup_dryrun_checkout || true
  _mdm_cleanup_persistent_stage || true
  _mdm_cleanup_auth_checkout || true
  _mdm_cleanup_expected_dir || true
  _mdm_cleanup_prior_inventory || true
  _mdm_cleanup_renderer_snapshot || true
  _mdm_release_run_lock || true
}

_mdm_arm_transient_cleanup() {
  trap '_mdm_cleanup_transient_checkouts' EXIT
  trap '_mdm_cleanup_transient_checkouts; exit 130' INT
  trap '_mdm_cleanup_transient_checkouts; exit 143' TERM
}

_mdm_prepare_authoritative_checkout() { # <ref> <target-uid>
  local _ref="$1" _target_uid="$2" _base _repo_url _auth _sha _head _status _privacy_uid
  _mdm_boot_validate_gitref "$_ref" >/dev/null 2>&1 || return "$MDM_EXIT_CONFIG"
  _base="$(_mdm_auth_tmp_base)"
  _mdm_auth_base_trusted "$_base" || {
    mdm_log U1b "authoritative checkout の一時領域が信頼できない"
    return 1
  }
  _auth="$(/usr/bin/mktemp -d "$_base/claude-kit-mdm-auth.XXXXXX" 2>/dev/null)" || return 1
  case "$_auth" in "$_base"/claude-kit-mdm-auth.*) : ;; *) return 1 ;; esac
  [[ -d "$_auth" && ! -L "$_auth" ]] || return 1
  [[ "$(_mdm_stat_uid "$_auth" || true)" == "$(_mdm_auth_expected_uid)" ]] || return 1
  /bin/chmod 700 "$_auth" || return 1
  _MDM_AUTH_CHECKOUT="$_auth"
  _mdm_arm_transient_cleanup

  _repo_url="$(_mdm_repo_url)"
  mdm_log U1b "root authoritative checkout を作成"
  _mdm_auth_git clone --quiet --no-checkout --no-local "$_repo_url" "$_auth" 2>/dev/null || return 1
  _mdm_auth_git -C "$_auth" fetch --quiet "$_repo_url" "$_ref" 2>/dev/null || return 1
  _sha="$(_mdm_auth_git -C "$_auth" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null || true)"
  [[ "$_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  _mdm_auth_git -C "$_auth" checkout --quiet --force --detach "$_sha" 2>/dev/null || return 1
  _head="$(_mdm_auth_git -C "$_auth" rev-parse --verify HEAD 2>/dev/null || true)"
  [[ "$_head" == "$_sha" ]] || return 1
  _status="$(_mdm_auth_git -C "$_auth" status --porcelain --untracked-files=all 2>/dev/null || true)"
  [[ -z "$_status" ]] || return 1

  MDM_RCPT_RESOLVED_SHA="$_sha"
  MDM_RCPT_KIT_VERSION="$(_mdm_auth_git -C "$_auth" describe --tags --always 2>/dev/null || echo unknown)"
  _mdm_normalize_auth_tree "$_auth" || return 1
  _privacy_uid="$_target_uid"
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && -n "${MDM_AUTH_PRIVACY_UID_OVERRIDE:-}" ]]; then
    _privacy_uid="$MDM_AUTH_PRIVACY_UID_OVERRIDE"
  fi
  _mdm_auth_tree_private_for_uid "$_auth" "$_privacy_uid" || {
    mdm_log U1b "authoritative checkout が対象ユーザーから書込可能"
    return 1
  }
}

_mdm_root_ref_allowed() { # <ref> <dry-run>
  local _ref="$1" _dry_run="$2"
  _mdm_boot_validate_gitref "$_ref" >/dev/null 2>&1 || return 1
  if [[ "${_MDM_TEST_MODE:-0}" != "1" && "$_dry_run" != "true" ]]; then
    [[ "$_ref" =~ ^[0-9a-f]{40}$ ]]
  fi
}

_mdm_persistent_marker_path() {
  printf '%s/.claude-starter-kit-mdm-managed' "$1"
}

_mdm_persistent_dir_identity() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%d:%i:%HT' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%d:%i:%F' "$1" 2>/dev/null
  fi
}

_mdm_persistent_marker_trusted() { # <install-dir> <target-uid>
  local _marker _expected_uid="$2" _copy="" _mode="" _value _extra _rc=1
  [[ "$_expected_uid" =~ ^[0-9]+$ ]] || return 1
  _marker="$(_mdm_persistent_marker_path "$1")"
  _mdm_stable_managed_snapshot "$_marker" persistent-marker "$_expected_uid" \
    _copy _mode || return 1
  [[ "$_mode" == 0444 ]] || { /bin/rm -f "$_copy"; return 1; }
  exec 6<"$_copy" || { /bin/rm -f "$_copy"; return 1; }
  if IFS= read -r _value <&6 \
    && ! IFS= read -r _extra <&6 \
    && [[ "$_value" == claude-code-starter-kit-mdm-user-v1 ]]; then
    _rc=0
  fi
  exec 6<&-
  /bin/rm -f "$_copy"
  return "$_rc"
}

_mdm_persistent_checkout_matches_identity() { # <dir> <target-uid> <dev:inode:type>
  local _dir="$1" _target_uid="$2" _expected="$3" _before _after _mode
  [[ "$_target_uid" =~ ^[0-9]+$ && -n "$_expected" ]] || return 1
  [[ -d "$_dir" && ! -L "$_dir" ]] || return 1
  [[ "$(_mdm_canonical_dir "$_dir" || true)" == "$_dir" ]] || return 1
  [[ "$(_mdm_stat_uid "$_dir" || true)" == "$_target_uid" ]] || return 1
  _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_dir" || true)" || true)"
  _mdm_mode_is_safe "$_mode" || return 1
  _mdm_has_extended_acl "$_dir" && return 1
  _before="$(_mdm_persistent_dir_identity "$_dir" || true)"
  [[ "$_before" == "$_expected" ]] || return 1
  case "$_before" in *:Directory|*:directory) : ;; *) return 1 ;; esac
  _mdm_persistent_marker_trusted "$_dir" "$_target_uid" || return 1
  _after="$(_mdm_persistent_dir_identity "$_dir" || true)"
  [[ "$_after" == "$_expected" ]]
}

_mdm_create_persistent_marker() { # <install-dir> <target-uid>
  local _marker _target_uid="$2"
  [[ "$_target_uid" =~ ^[0-9]+$ ]] || return 1
  _marker="$(_mdm_persistent_marker_path "$1")"
  [[ ! -e "$_marker" && ! -L "$_marker" ]] || return 1
  # The checkout parent is target-user writable. Never let root open a marker
  # path below it: a concurrent directory-to-symlink swap would redirect the
  # privileged write. Creation and chmod stay in the already-clean user
  # context; root only consumes a bounded, inode-bound snapshot afterwards.
  _mdm_run_maybe_as_user /bin/sh -c '
    set -eu
    umask 022
    set -C
    printf "%s\n" claude-code-starter-kit-mdm-user-v1 > "$1"
    /bin/chmod 444 "$1"
  ' mdm-persistent-marker "$_marker" 2>/dev/null || return 1
  _mdm_persistent_marker_trusted "$1" "$_target_uid"
}

_mdm_promote_persistent_stage() { # <stage> <install-dir> <create|swap>
  local _stage="$1" _install_dir="$2" _operation="$3" _python
  case "$_operation" in create|swap) : ;; *) return 1 ;; esac
  _python="$(_mdm_system_python)" || return 1
  # Both paths share one target-user-owned parent.  RENAME_EXCL/NOREPLACE makes
  # the first install fail if a destination appears concurrently; RENAME_SWAP/
  # EXCHANGE replaces an existing managed checkout without an absent window.
  _mdm_run_maybe_as_user "$_python" -I -B -c '
import ctypes
import os
import sys

source, destination, operation = sys.argv[1:]
libc = ctypes.CDLL(None, use_errno=True)
source_b = os.fsencode(source)
destination_b = os.fsencode(destination)

if sys.platform == "darwin":
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    flags = 4 if operation == "create" else 2  # RENAME_EXCL / RENAME_SWAP
    result = rename(source_b, destination_b, flags)
elif sys.platform.startswith("linux"):
    rename = libc.renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p,
                       ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    flags = 1 if operation == "create" else 2  # NOREPLACE / EXCHANGE
    result = rename(-100, source_b, -100, destination_b, flags)  # AT_FDCWD
else:
    raise SystemExit(2)

if result != 0:
    raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()))
' "$_stage" "$_install_dir" "$_operation" >/dev/null 2>&1
}

_mdm_restore_previous_persistent_checkout() { # <stage> <install> <uid> <candidate-id> <previous-id>
  local _stage="$1" _install_dir="$2" _target_uid="$3"
  local _candidate_identity="$4" _previous_identity="$5" _stage_identity
  if ! _mdm_promote_persistent_stage "$_stage" "$_install_dir" swap; then
    # A failed exchange leaves the previous checkout at the stage pathname.
    # Disarm cleanup so that known prior state is preserved for recovery.
    _MDM_PERSISTENT_STAGE=""
    _MDM_PERSISTENT_STAGE_IDENTITY=""
    mdm_log U1b "保持用 checkout の rollback に失敗。旧 checkout を recovery stage に保持"
    return 1
  fi
  _stage_identity="$(_mdm_persistent_dir_identity "$_stage" || true)"
  if [[ "$_stage_identity" != "$_candidate_identity" ]] \
    || ! _mdm_persistent_checkout_matches_identity \
      "$_install_dir" "$_target_uid" "$_previous_identity"; then
    # The exchange happened, but a concurrent pathname replacement means we
    # cannot prove which tree is disposable. Preserve both rather than rm -rf.
    _MDM_PERSISTENT_STAGE=""
    _MDM_PERSISTENT_STAGE_IDENTITY=""
    mdm_log U1b "rollback 後の checkout identity を証明できないため両方を保持"
    return 1
  fi
  _MDM_PERSISTENT_STAGE_IDENTITY="$_candidate_identity"
  _mdm_cleanup_persistent_stage
}

_mdm_retract_initial_persistent_checkout() { # <stage-path> <install-dir> <candidate-id>
  local _stage="$1" _install_dir="$2" _candidate_identity="$3" _current
  # Move the promoted object back to its now-absent stage name before deleting
  # it. A raced replacement is preserved when its identity is not the candidate.
  if ! _mdm_promote_persistent_stage "$_install_dir" "$_stage" create; then
    _MDM_PERSISTENT_STAGE=""
    _MDM_PERSISTENT_STAGE_IDENTITY=""
    return 1
  fi
  _current="$(_mdm_persistent_dir_identity "$_stage" || true)"
  if [[ "$_current" != "$_candidate_identity" ]]; then
    # The active pathname was replaced after promotion. Put that unrelated
    # directory back at the fixed path when it is still absent; otherwise keep
    # the recovery stage untouched. Neither branch authorizes deletion.
    _mdm_promote_persistent_stage "$_stage" "$_install_dir" create || true
    _MDM_PERSISTENT_STAGE=""
    _MDM_PERSISTENT_STAGE_IDENTITY=""
    return 1
  fi
  _MDM_PERSISTENT_STAGE_IDENTITY="$_candidate_identity"
  _mdm_cleanup_persistent_stage
}

_mdm_rebuild_persistent_checkout() { # <install-dir> <repo-url> <full-sha> <target-uid>
  local _install_dir="$1" _repo_url="$2" _sha="$3" _target_uid="$4"
  local _parent _stage _stage_name _fetched _head _status _mode _existing=false
  local _install_identity="" _stage_identity _current_install _current_stage
  [[ "$_sha" =~ ^[0-9a-f]{40}$ && "$_target_uid" =~ ^[0-9]+$ ]] || return 1
  _parent="$(/usr/bin/dirname "$_install_dir")"
  _mdm_run_maybe_as_user /bin/mkdir -p "$_parent" 2>/dev/null || return 1

  if [[ -e "$_install_dir" || -L "$_install_dir" ]]; then
    [[ -d "$_install_dir" && ! -L "$_install_dir" ]] || return 1
    _install_identity="$(_mdm_persistent_dir_identity "$_install_dir" || true)"
    _mdm_persistent_checkout_matches_identity \
      "$_install_dir" "$_target_uid" "$_install_identity" || return 1
    _existing=true
  fi

  _stage="$(_mdm_run_maybe_as_user /usr/bin/mktemp -d \
    "$_parent/.claude-starter-kit.mdm-stage.XXXXXX" 2>/dev/null)" || return 1
  _stage_name="${_stage##*/}"
  case "$_stage" in "$_parent"/.claude-starter-kit.mdm-stage.*) : ;; *) return 1 ;; esac
  case "$_stage_name" in .claude-starter-kit.mdm-stage.*) : ;; *) return 1 ;; esac
  _stage_identity="$(_mdm_persistent_dir_identity "$_stage" || true)"
  case "$_stage_identity" in *:Directory|*:directory) : ;; *) return 1 ;; esac
  _MDM_PERSISTENT_STAGE="$_stage"
  _MDM_PERSISTENT_STAGE_IDENTITY="$_stage_identity"
  _mdm_arm_transient_cleanup
  [[ -d "$_stage" && ! -L "$_stage" \
    && "$(_mdm_canonical_dir "$_stage" || true)" == "$_stage" \
    && "$(_mdm_stat_uid "$_stage" || true)" == "$_target_uid" ]] \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_stage" || true)" || true)"
  [[ "$_mode" == 0700 ]] \
    || { _mdm_cleanup_persistent_stage || true; return 1; }

  _mdm_git -c core.hooksPath=/dev/null clone --quiet --no-checkout --no-local \
    "$_repo_url" "$_stage" 2>/dev/null \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  _mdm_git -C "$_stage" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    fetch --quiet "$_repo_url" "$_sha" 2>/dev/null \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  _fetched="$(_mdm_git -C "$_stage" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null || true)"
  [[ "$_fetched" == "$_sha" ]] \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  _mdm_git -C "$_stage" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    checkout --quiet --force --detach "$_sha" 2>/dev/null \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  _head="$(_mdm_git -C "$_stage" rev-parse --verify HEAD 2>/dev/null || true)"
  [[ "$_head" == "$_sha" ]] \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  _status="$(_mdm_git -C "$_stage" status --porcelain --untracked-files=all 2>/dev/null)" \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  [[ -z "$_status" ]] \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  _mdm_create_persistent_marker "$_stage" "$_target_uid" \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  _mdm_persistent_checkout_matches_identity \
    "$_stage" "$_target_uid" "$_stage_identity" \
    && _mdm_detached_head_matches "$_stage" "$_sha" "$_target_uid" \
    || { _mdm_cleanup_persistent_stage || true; return 1; }

  if [[ "$_existing" == true ]]; then
    # Bind the destination again after the long clone/fetch window. This does
    # not claim to defeat continuous hostile mutation, but prevents a stale
    # preflight result from authorizing deletion of a replacement directory.
    _mdm_persistent_checkout_matches_identity \
      "$_install_dir" "$_target_uid" "$_install_identity" \
      || { _mdm_cleanup_persistent_stage || true; return 1; }
    _mdm_promote_persistent_stage "$_stage" "$_install_dir" swap \
      || { _mdm_cleanup_persistent_stage || true; return 1; }
    _current_stage="$(_mdm_persistent_dir_identity "$_stage" || true)"
    _current_install="$(_mdm_persistent_dir_identity "$_install_dir" || true)"
    if [[ "$_current_stage" != "$_install_identity" \
      || "$_current_install" != "$_stage_identity" ]]; then
      _mdm_restore_previous_persistent_checkout \
        "$_stage" "$_install_dir" "$_target_uid" \
        "$_stage_identity" "$_install_identity" || return 1
      return 1
    fi
    _MDM_PERSISTENT_STAGE_IDENTITY="$_install_identity"
    if ! _mdm_persistent_checkout_matches_identity \
        "$_install_dir" "$_target_uid" "$_stage_identity" \
      || ! _mdm_detached_head_matches \
        "$_install_dir" "$_sha" "$_target_uid"; then
      _mdm_restore_previous_persistent_checkout \
        "$_stage" "$_install_dir" "$_target_uid" \
        "$_stage_identity" "$_install_identity" || return 1
      return 1
    fi
    # The stage pathname still names the exact directory bound before swap.
    _mdm_cleanup_persistent_stage || return 1
  else
    _mdm_promote_persistent_stage "$_stage" "$_install_dir" create \
      || { _mdm_cleanup_persistent_stage || true; return 1; }
    if ! _mdm_persistent_checkout_matches_identity \
        "$_install_dir" "$_target_uid" "$_stage_identity" \
      || ! _mdm_detached_head_matches \
        "$_install_dir" "$_sha" "$_target_uid"; then
      _mdm_retract_initial_persistent_checkout \
        "$_stage" "$_install_dir" "$_stage_identity" || return 1
      return 1
    fi
    _MDM_PERSISTENT_STAGE=""
    _MDM_PERSISTENT_STAGE_IDENTITY=""
  fi
  return 0
}

_mdm_run_root_user_phase() { # <user> <home>
  local _user="$1" _home="$2" _uid _ref _dry_run _install_dir _repo_url _cli_required
  local _setup_rc=0
  _uid="$(/usr/bin/id -u "$_user" 2>/dev/null || true)"
  [[ "$_uid" =~ ^[0-9]+$ ]] || { mdm_log U1b "対象ユーザー UID を解決できない"; return 1; }
  _ref="${KIT_MDM_GIT_REF:-main}"
  _dry_run="$(_mdm_root_bool "${KIT_MDM_DRY_RUN:-false}" 2>/dev/null || echo false)"
  if ! _mdm_root_ref_allowed "$_ref" "$_dry_run"; then
    mdm_log U1b "production remediation の KIT_MDM_GIT_REF は full SHA 必須"
    return "$MDM_EXIT_CONFIG"
  fi
  _install_dir="$_home/.claude-starter-kit"
  if [[ "$_dry_run" != "true" && -n "${KIT_MDM_INSTALL_DIR:-}" \
    && "$KIT_MDM_INSTALL_DIR" != "$_install_dir" ]]; then
    mdm_log U1b "KIT_MDM_INSTALL_DIR は専用パス $_install_dir のみ許可"
    return "$MDM_EXIT_CONFIG"
  fi
  if [[ "$_dry_run" != "true" ]]; then
    if [[ -L "$_install_dir" || ( -e "$_install_dir" && ! -d "$_install_dir" ) ]]; then
      mdm_log U1b "管理 checkout パスの実体が不正"
      return "$MDM_EXIT_CONFIG"
    fi
    if [[ -d "$_install_dir" ]] \
      && [[ "$(_mdm_canonical_dir "$_install_dir")" != "$_install_dir" ]]; then
      mdm_log U1b "管理 checkout パスが canonical でない"
      return "$MDM_EXIT_CONFIG"
    fi
    if [[ -d "$_install_dir" ]] && ! _mdm_persistent_marker_trusted "$_install_dir" "$_uid"; then
      mdm_log U1b "管理 marker の無い既存 checkout は削除しない"
      return "$MDM_EXIT_CONFIG"
    fi
  fi

  MDM_RCPT_GIT_REF="$_ref"
  MDM_RCPT_INSTALL_DIR="$_install_dir"
  _MDM_GIT_SAFE_DIRECTORY=""
  _MDM_GIT_DROP_UID=""
  _MDM_GIT_DROP_USER=""
  _MDM_GIT_DROP_HOME=""
  _mdm_prepare_authoritative_checkout "$_ref" "$_uid" || return $?
  _repo_url="$(_mdm_repo_url)"
  if [[ "$_dry_run" != "true" ]]; then
    _mdm_capture_prior_inventory "$_user" "$_home" "$_uid" || return 1
    _mdm_prepare_expected_state "$_home" || return 1
  fi

  # The target-user-owned checkout is a persistence artifact only.  It is
  # rebuilt fresh at the already-resolved SHA and is never used as code.
  if [[ "$_dry_run" != "true" ]]; then
    _MDM_GIT_DROP_UID="$_uid"
    _MDM_GIT_DROP_USER="$_user"
    _MDM_GIT_DROP_HOME="$_home"
    mdm_log U1b "保持用 checkout を固定 SHA で再構築"
    _mdm_rebuild_persistent_checkout \
      "$_install_dir" "$_repo_url" "$MDM_RCPT_RESOLVED_SHA" "$_uid" || return 1
  fi

  _cli_required="true"
  if [[ -n "${KIT_MDM_INSTALL_CLAUDE_CLI:-}" ]]; then
    _cli_required="$(_mdm_root_bool "$KIT_MDM_INSTALL_CLAUDE_CLI" 2>/dev/null || echo true)"
  fi
  if [[ "$_cli_required" == "true" && "$_dry_run" != "true" ]]; then
    MDM_RCPT_REQUIRED_COMPONENTS='["kit","claude_cli"]'
  else
    MDM_RCPT_REQUIRED_COMPONENTS='["kit"]'
  fi

  mdm_build_setup_argv "$_home"
  mdm_log U2 "authoritative setup.sh を対象ユーザーで実行: ${MDM_SETUP_ARGV[*]}"
  _MDM_GIT_SAFE_DIRECTORY="$_MDM_AUTH_CHECKOUT"
  _mdm_exec_as_user "$_uid" "$_user" "$_home" \
    /bin/bash "$_MDM_AUTH_CHECKOUT/setup.sh" "${MDM_SETUP_ARGV[@]}" || _setup_rc=$?
  if [[ "$_setup_rc" -ne 0 ]]; then
    _MDM_GIT_SAFE_DIRECTORY=""
    mdm_log U2 "setup.sh の実行に失敗 (exit=$_setup_rc)"
    [[ "$_setup_rc" -eq "$MDM_EXIT_PREREQ" ]] && return "$MDM_EXIT_PREREQ"
    return 1
  fi
  _MDM_GIT_SAFE_DIRECTORY=""

  # No post-setup Git process is allowed against either checkout.
  _mdm_auth_tree_trusted "$_MDM_AUTH_CHECKOUT" || return 1
  _mdm_detached_head_matches "$_MDM_AUTH_CHECKOUT" "$MDM_RCPT_RESOLVED_SHA" \
    "$(_mdm_auth_expected_uid)" || return 1
  if [[ "$_dry_run" != "true" ]]; then
    _mdm_detached_head_matches "$_install_dir" "$MDM_RCPT_RESOLVED_SHA" "$_uid" || return 1
  fi
  _mdm_cleanup_auth_entry_list || return 1
  _mdm_cleanup_auth_checkout || return 1

  if [[ "$_cli_required" == "true" && "$_dry_run" != "true" ]]; then
    mdm_log U3 "Claude Code CLI 導入を確認"
    if ! _mdm_cli_present_for_home "$_home"; then
      MDM_RCPT_PARTIAL='["claude_cli"]'
      return "$MDM_EXIT_CLI"
    fi
  fi
  return 0
}

# U1b→U2→U3: キット取得+refピン留め → setup.sh --non-interactive 実行 →
# Claude Code CLI 導入確認。
# root 実行時は clone を含む全 git 操作を初回から検証済み対象ユーザーへ
# env -i 降格して行う。root が対象ユーザー所有 repo を直接
# 操作すると .git/config 経由の root コード実行境界になるため、「root で
# clone してから所有権を対象ユーザーへ再帰変更する」旧方式は廃止
# （ユーザー実行の clone なら所有権は最初から正しい）。
# 戻り値: 0=成功 / MDM_EXIT_PREREQ=setup前提不足 /
#         MDM_EXIT_CLI=CLIのみ欠如（部分失敗）/
#         MDM_EXIT_CONFIG=install_dir 制約違反 / 1=それ以外の失敗
_mdm_run_user_phase() {
  local _euid="$1" _user="$2" _home="$3"
  # MDM 管理マーカー（非 root 経路は env 継承で setup.sh へ届く。root 経路は
  # mdm_build_drop_argv が固定要素として注入する）
  export KIT_MDM_MANAGED=true
  local _ref="${KIT_MDM_GIT_REF:-main}"
  local _dry_run="false"
  _dry_run="$(_mdm_root_bool "${KIT_MDM_DRY_RUN:-false}" 2>/dev/null || echo false)"

  if [[ "$_euid" -eq 0 ]]; then
    _mdm_run_root_user_phase "$_user" "$_home"
    return $?
  fi
  if [[ "$_dry_run" != "true" ]]; then
    mdm_log R2 "通常の MDM remediation は root 実行が必須"
    return "$MDM_EXIT_CONTEXT"
  fi
  _MDM_GIT_DROP_UID=""
  _MDM_GIT_DROP_USER=""
  _MDM_GIT_DROP_HOME=""
  _MDM_GIT_SAFE_DIRECTORY=""

  # Root returned through the authoritative path above.  The remaining path is
  # the explicitly allowed non-root preview and never writes a receipt.
  local _uid="" _setup_rc=0

  local _install_dir="${KIT_MDM_INSTALL_DIR:-}"
  if [[ "$_dry_run" == "true" ]]; then
    if [[ "$_euid" -eq 0 ]]; then
      _install_dir="$(_mdm_exec_as_user "$_uid" "$_user" "$_home" \
        /usr/bin/mktemp -d /private/tmp/claude-kit-mdm-dryrun.XXXXXX 2>/dev/null || true)"
    else
      _install_dir="$(/usr/bin/mktemp -d /tmp/claude-kit-mdm-dryrun.XXXXXX 2>/dev/null || true)"
    fi
    case "$_install_dir" in
      /private/tmp/claude-kit-mdm-dryrun.*|/tmp/claude-kit-mdm-dryrun.*) ;;
      *) mdm_log U1b "dry-run 一時 checkout を作成できない"; return 1 ;;
    esac
    [[ -d "$_install_dir" && ! -L "$_install_dir" ]] || return 1
    _MDM_DRYRUN_CHECKOUT="$_install_dir"
    _mdm_arm_transient_cleanup
  else
    [[ -z "$_install_dir" ]] && _install_dir="$_home/.claude-starter-kit"
  fi
  MDM_RCPT_GIT_REF="$_ref"
  MDM_RCPT_INSTALL_DIR="$_install_dir"

  # Normal MDM runs use one dedicated managed checkout.  A configurable
  # arbitrary home subdirectory cannot be safely replaced authoritatively
  # without risking unrelated user data, so custom paths fail closed.
  if [[ "$_dry_run" != "true" ]]; then
    if [[ "$_install_dir" != "$_home/.claude-starter-kit" ]]; then
      mdm_log U1b "KIT_MDM_INSTALL_DIR は専用パス $_home/.claude-starter-kit のみ許可"
      return "$MDM_EXIT_CONFIG"
    fi
    if [[ -L "$_install_dir" || ( -e "$_install_dir" && ! -d "$_install_dir" ) ]]; then
      mdm_log U1b "管理 checkout パスの実体が不正: $_install_dir"
      return "$MDM_EXIT_CONFIG"
    fi
    if [[ -d "$_install_dir" ]] \
      && [[ "$(_mdm_canonical_dir "$_install_dir")" != "$_install_dir" ]]; then
      mdm_log U1b "管理 checkout パスが canonical でない: $_install_dir"
      return "$MDM_EXIT_CONFIG"
    fi
  fi

  # U1b: キット取得 + ref ピン留め
  local _repo_url="$_MDM_KIT_REPO_URL"
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && -n "${MDM_KIT_REPO_URL_OVERRIDE:-}" ]]; then
    _repo_url="$MDM_KIT_REPO_URL_OVERRIDE"
  fi
  # Rebuild the managed checkout from the fixed URL on every run.  Reusing a
  # target-user-owned .git/config would let origin/url rewrites and filters
  # redefine the code that setup executes.
  mdm_log U1b "管理 checkout を再構築: $_install_dir"
  _mdm_run_maybe_as_user /bin/mkdir -p "$(dirname "$_install_dir")" 2>/dev/null || true
  if [[ -e "$_install_dir" || -L "$_install_dir" ]]; then
    _mdm_run_maybe_as_user /bin/rm -rf "$_install_dir" 2>/dev/null || return 1
  fi
  if ! _mdm_git -c core.hooksPath=/dev/null clone --quiet --no-checkout \
    "$_repo_url" "$_install_dir" 2>/dev/null; then
    mdm_log U1b "clone に失敗: $_install_dir"
    return 1
  fi

  local _sha _rc=0
  _sha="$(mdm_resolve_ref_sha "$_install_dir" "$_ref" "$_repo_url")" || _rc=$?
  if [[ $_rc -ne 0 || -z "$_sha" ]]; then
    mdm_log U1b "ref を解決できない: $_ref"
    return 1
  fi
  if ! _mdm_git -C "$_install_dir" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    checkout --quiet --force --detach "$_sha" 2>/dev/null; then
    mdm_log U1b "checkout に失敗: $_sha"
    return 1
  fi
  local _head_sha
  _head_sha="$(_mdm_git -C "$_install_dir" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$_head_sha" != "$_sha" ]]; then
    mdm_log U1b "checkout 後の HEAD が解決 SHA と不一致: $_head_sha != $_sha"
    return 1
  fi
  if [[ -n "$(_mdm_git -C "$_install_dir" status --porcelain --untracked-files=all 2>/dev/null)" ]]; then
    mdm_log U1b "checkout に未追跡または変更済みファイルがある"
    return 1
  fi
  MDM_RCPT_RESOLVED_SHA="$_sha"
  MDM_RCPT_KIT_VERSION="$(_mdm_git -C "$_install_dir" describe --tags --always 2>/dev/null || echo unknown)"
  _mdm_run_maybe_as_user /bin/chmod +x "$_install_dir/setup.sh" 2>/dev/null || true

  # required_components: kit は常時、claude_cli は KIT_MDM_INSTALL_CLAUDE_CLI!=false のとき（既定 true）
  local _cli_required="true"
  if [[ -n "${KIT_MDM_INSTALL_CLAUDE_CLI:-}" ]]; then
    _cli_required="$(_mdm_root_bool "$KIT_MDM_INSTALL_CLAUDE_CLI" 2>/dev/null || echo true)"
  fi
  if [[ "$_cli_required" == "true" && "$_dry_run" != "true" ]]; then
    MDM_RCPT_REQUIRED_COMPONENTS='["kit","claude_cli"]'
  else
    MDM_RCPT_REQUIRED_COMPONENTS='["kit"]'
  fi

  # U2: setup.sh を直接実行（root 時のみ環境分離降格）。
  # 引数は mdm_build_setup_argv がグローバル配列 MDM_SETUP_ARGV へ直接構築する
  # （既存 manifest 検出で --update、KIT_MDM_DRY_RUN=true で --dry-run を付与。
  # 改行シリアライズは行わない）。
  mdm_build_setup_argv "$_home"
  mdm_log U2 "setup.sh を実行: ${MDM_SETUP_ARGV[*]}"
  if [[ "$_euid" -eq 0 ]]; then
    _mdm_exec_as_user "$_uid" "$_user" "$_home" /bin/bash \
      "$_install_dir/setup.sh" "${MDM_SETUP_ARGV[@]}" || _setup_rc=$?
    if [[ "$_setup_rc" -ne 0 ]]; then
      mdm_log U2 "setup.sh の実行に失敗 (exit=$_setup_rc)"
      [[ "$_setup_rc" -eq "$MDM_EXIT_PREREQ" ]] && return "$MDM_EXIT_PREREQ"
      return 1
    fi
  else
    /bin/bash "$_install_dir/setup.sh" "${MDM_SETUP_ARGV[@]}" || _setup_rc=$?
    if [[ "$_setup_rc" -ne 0 ]]; then
      mdm_log U2 "setup.sh の実行に失敗 (exit=$_setup_rc)"
      [[ "$_setup_rc" -eq "$MDM_EXIT_PREREQ" ]] && return "$MDM_EXIT_PREREQ"
      return 1
    fi
  fi

  # U3: Claude Code CLI 導入の確認（KIT_MDM_INSTALL_CLAUDE_CLI=true のとき）
  if [[ "$_cli_required" == "true" && "$_dry_run" != "true" ]]; then
    mdm_log U3 "Claude Code CLI 導入を確認"
    if ! _mdm_cli_present_for_home "$_home"; then
      mdm_log U3 "Claude Code CLI が見つからない（部分失敗として記録）"
      MDM_RCPT_PARTIAL='["claude_cli"]'
      return "$MDM_EXIT_CLI"
    fi
  fi

  return 0
}

# ログ出力先を決定して MDM_LOG_FILE を設定する。
# 設定確定（_mdm_root_config_apply）と R2 のユーザー/home 解決後に呼ぶこと。
# 旧実装は設定読込前に KIT_MDM_LOG_DIR を参照していたため、管理設定ファイル
# からの指定がログパスに反映されなかった。
# - 既定: root は /Library/Logs/ClaudeCodeStarterKit、
#         ユーザーモードは <home>/Library/Logs/ClaudeCodeStarterKit
# - KIT_MDM_LOG_DIR は許可プレフィックス（/Library/Logs または
#   <home>/Library/Logs）配下のみ許可。違反は exit 50
# ログ出力先ディレクトリを決定し許可プレフィックスを検証して stdout へ返す
# （ファイル I/O を伴わないためテスト可能。違反は exit 50）。
# 許可プレフィックスは実行モードで分ける: root は /Library/Logs のみ
# （ユーザー home 配下を許すと、ユーザーが植えた symlink を root が辿って
# 任意ファイルへ append する経路になる）。非 root は自分の home 配下のみ。
_mdm_log_dir_for() {
  local _euid="$1" _home="$2"
  local _default_dir
  if [[ "$_euid" -eq 0 ]]; then
    _default_dir="/Library/Logs/ClaudeCodeStarterKit"
  else
    _default_dir="$_home/Library/Logs/ClaudeCodeStarterKit"
  fi
  local _dir="${KIT_MDM_LOG_DIR:-$_default_dir}"
  case "$_dir" in
    *..*)
      mdm_log R1 "KIT_MDM_LOG_DIR に .. を含む: $_dir"
      return "$MDM_EXIT_CONFIG" ;;
  esac
  if [[ "$_euid" -eq 0 ]]; then
    case "$_dir" in
      /Library/Logs|/Library/Logs/*) : ;;
      *)
        mdm_log R1 "KIT_MDM_LOG_DIR が root の許可プレフィックス（/Library/Logs）配下でない: $_dir"
        return "$MDM_EXIT_CONFIG" ;;
    esac
  else
    case "$_dir" in
      "$_home/Library/Logs"|"$_home/Library/Logs/"*) : ;;
      *)
        mdm_log R1 "KIT_MDM_LOG_DIR がユーザーの許可プレフィックス（~/Library/Logs）配下でない: $_dir"
        return "$MDM_EXIT_CONFIG" ;;
    esac
  fi
  printf '%s' "$_dir"
  return 0
}

_mdm_setup_log_file() {
  local _euid="$1" _home="$2"
  local _dir _dir_rc=0
  _dir="$(_mdm_log_dir_for "$_euid" "$_home")" || _dir_rc=$?
  [[ "$_dir_rc" -eq 0 ]] || return "$_dir_rc"
  # ログ dir が symlink 経由なら拒否（root が symlink を辿って任意領域へ書くのを防ぐ。R3-High）
  if [[ -L "$_dir" ]]; then
    mdm_log R1 "ログディレクトリが symlink: $_dir"
    return "$MDM_EXIT_CONFIG"
  fi
  # root 経路: /Library/Logs から _dir までの信頼チェーンを検証（R5-High）。
  # 全構成要素が非 symlink・root 所有・group/other 書込不可であることを要求し、
  # 攻撃者所有の中間/最終 dir の再利用と、中間 symlink による許可プレフィックス
  # 外への誘導を排除する。1つでも違反すれば fail-closed。
  if [[ "$_euid" -eq 0 ]] && ! _mdm_verify_dir_chain "$_dir" "/Library/Logs"; then
    mdm_log R1 "ログ dir の信頼チェーンが成立しない（fail-closed）: $_dir"
    return "$MDM_EXIT_CONFIG"
  fi
  # umask 022 で dir を 755 作成（スクリプト冒頭で umask 022 だが、呼び出し
  # 時点の umask 変化に依存しないよう明示制御する）
  local _um; _um="$(umask)"
  umask 022
  if ! mkdir -p "$_dir" 2>/dev/null; then
    umask "$_um"
    mdm_log R1 "ログディレクトリを作成できない: $_dir"
    return "$MDM_EXIT_CONFIG"
  fi
  # root 経路: 作成後の最終 dir も信頼できること（root 755 で作られたこと）を再確認し、
  # 既存 dir を契約の 755 へ収束（信頼チェーン成立後なので chmod は race しない）
  if [[ "$_euid" -eq 0 ]]; then
    if ! _mdm_component_trusted "$_dir"; then
      umask "$_um"
      mdm_log R1 "作成後のログディレクトリが信頼できない: $_dir"
      return "$MDM_EXIT_CONFIG"
    fi
    if ! chmod 755 "$_dir" 2>/dev/null; then
      umask "$_um"
      mdm_log R1 "ログディレクトリの権限（755）を設定できない: $_dir"
      return "$MDM_EXIT_CONFIG"
    fi
  fi
  local _ts
  _ts="$(date -u +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
  local _open_rc=0
  _mdm_open_log_fd "$_dir/install-$_ts.log" || _open_rc=$?
  umask "$_um"
  return "$_open_rc"
}

# ログファイルを新規排他作成して fd 7 に束縛する。
# 既存ファイルは一切再利用しない。攻撃者が予測パスに先置きした regular file
# は noclobber で拒否 → 別名（.1, .2 …）へ。symlink は事前に除去してから
# 新規作成する（symlink 追随を断つ）。以降 mdm_log は fd 7 へ書くため、
# 検証後のパス差し替えの影響を受けない（パス再オープンを避ける）。
# 呼び出し側が umask 022 を設定済み前提で、ファイルは 644 で作られる（chmod 不要）。
# `exec 7>... 2>/dev/null` は引数なし exec のリダイレクトが現在の
# shell の fd 2 を恒久的に /dev/null へ向けてしまう。stderr 抑制は必ず
# `{ exec 7>...; } 2>/dev/null` のようにグループの一時リダイレクトに閉じ込める。
_mdm_open_log_fd() {
  local _base="$1" _cand="$1" _n=0 _opened=0
  local _noclob=0
  [[ -o noclobber ]] && _noclob=1
  while [[ "$_n" -le 50 ]]; do
    # symlink 先置きは自身を除去（noclobber は dangling symlink を追随作成し得るため）
    [[ -L "$_cand" ]] && rm -f "$_cand" 2>/dev/null
    if [[ ! -L "$_cand" ]]; then
      set -o noclobber
      if { exec 7>"$_cand"; } 2>/dev/null; then
        _opened=1
      fi
      [[ "$_noclob" -eq 0 ]] && set +o noclobber
    fi
    [[ "$_opened" -eq 1 ]] && break
    _n=$((_n + 1))
    _cand="$_base.$_n"
  done
  if [[ "$_opened" -ne 1 ]]; then
    mdm_log R1 "ログファイルを安全に作成できない（先置き衝突が解消しない）: $_base"
    return "$MDM_EXIT_CONFIG"
  fi
  if [[ -L "$_cand" || ! -f "$_cand" ]]; then
    { exec 7>&-; } 2>/dev/null || true
    mdm_log R1 "作成したログファイルの実体が不正: $_cand"
    return "$MDM_EXIT_CONFIG"
  fi
  MDM_LOG_FILE="$_cand"
  MDM_LOG_FD_OPEN=1
  return 0
}

# MDM 配布固有の既定値を適用する（本体 profiles/*.conf の既定と異なる値を
# MDM 配布でだけ上書きする場所）。_mdm_root_config_apply の**後**に呼ぶこと —
# conf/env で既に明示された値（既存 env 値）は変更せず、未設定のキーにのみ
# MDM 既定を適用する（_mdm_root_config_apply と同じ「既存 env 値は
# 上書きしない」優先順位を踏襲）。
#   - ENABLE_GHOSTTY_SETUP: 本体既定は standard/full プロファイルで true だが、
#     MDM 配布では GUI アプリの既定導入を避けるため既定 off とする。
#     mdm-config.conf で ENABLE_GHOSTTY_SETUP=true を明示すれば on にできる。
_mdm_apply_mdm_defaults() {
  : "${ENABLE_GHOSTTY_SETUP:=false}"
  : "${ENABLE_FONTS_SETUP:=false}"
  ENABLE_AUTO_UPDATE=false
  ENABLE_WEB_CONTENT_UPDATE=false
  ENABLE_CODEX_PLUGIN=false
  export ENABLE_GHOSTTY_SETUP ENABLE_FONTS_SETUP ENABLE_AUTO_UPDATE \
    ENABLE_WEB_CONTENT_UPDATE ENABLE_CODEX_PLUGIN
}

_mdm_json_valid() {
  if _mdm_is_darwin; then
    /usr/bin/plutil -convert json -o /dev/null -- "$1" >/dev/null 2>&1
  elif [[ -x /usr/bin/jq ]]; then
    /usr/bin/jq empty "$1" >/dev/null 2>&1
  else
    return 1
  fi
}

_mdm_json_get() { # <file> <key>
  local _file="$1" _key="$2"
  if _mdm_is_darwin; then
    /usr/bin/plutil -extract "$_key" raw -o - "$_file" 2>/dev/null
  elif [[ -x /usr/bin/jq ]]; then
    /usr/bin/jq -r --arg key "$_key" \
      'getpath($key | split(".")) // empty' "$_file" 2>/dev/null
  else
    return 1
  fi
}

_mdm_json_array_count() { # <file> <key>
  local _file="$1" _key="$2"
  if _mdm_is_darwin; then
    /usr/bin/plutil -extract "$_key" raw -o - "$_file" 2>/dev/null
  elif [[ -x /usr/bin/jq ]]; then
    /usr/bin/jq -r --arg key "$_key" \
      'getpath($key | split(".")) | if type == "array" then length else empty end' \
      "$_file" 2>/dev/null
  else
    return 1
  fi
}

_mdm_json_array_get() { # <file> <key> <index>
  local _file="$1" _key="$2" _index="$3"
  if _mdm_is_darwin; then
    /usr/bin/plutil -extract "${_key}.${_index}" raw -o - "$_file" 2>/dev/null
  elif [[ -x /usr/bin/jq ]]; then
    /usr/bin/jq -r --arg key "$_key" --argjson index "$_index" \
      'getpath($key | split("."))[$index] // empty' "$_file" 2>/dev/null
  else
    return 1
  fi
}

_mdm_canonical_dir() {
  [[ -d "$1" && ! -L "$1" ]] || return 1
  (builtin cd -P -- "$1" 2>/dev/null && printf '%s' "$PWD")
}

_mdm_canonical_file() {
  local _file="$1" _dir _base _physical
  [[ -f "$_file" && ! -L "$_file" ]] || return 1
  _dir="${_file%/*}"
  _base="${_file##*/}"
  [[ "$_dir" != "$_file" ]] || _dir=.
  _physical="$(_mdm_canonical_dir "$_dir")" || return 1
  printf '%s/%s' "$_physical" "$_base"
}

_MDM_MARKER_BEGIN='<!-- BEGIN STARTER-KIT-MANAGED -->'
_MDM_MARKER_END='<!-- END STARTER-KIT-MANAGED -->'
_mdm_extract_managed_section() { # <input> <output> <require-entire:0|1>
  local _input="$1" _output="$2" _require_entire="$3"
  [[ "$_require_entire" == 0 || "$_require_entire" == 1 ]] || return 1
  if ! /usr/bin/awk -v begin="$_MDM_MARKER_BEGIN" -v end="$_MDM_MARKER_END" \
    -v entire="$_require_entire" '
      {
        if ($0 == begin) {
          begins++
          if (state != 0) bad = 1
          state = 1
          print
          next
        }
        if ($0 == end) {
          ends++
          if (state != 1) bad = 1
          if (state == 1) print
          state = 2
          next
        }
        if (state == 1) { print; next }
        if (entire == 1) bad = 1
      }
      END {
        if (bad || begins != 1 || ends != 1 || state != 2) exit 1
      }
    ' "$_input" > "$_output"; then
    /bin/rm -f "$_output"
    return 1
  fi
  /bin/chmod 600 "$_output" || { /bin/rm -f "$_output"; return 1; }
}

_mdm_path_is_absent_with_real_parents() { # <root> <relative>
  local _root="$1" _relative="$2" _python
  [[ -d "$_root" && ! -L "$_root" && -n "$_relative" \
    && "$_relative" != /* && ! "$_relative" =~ [[:cntrl:]] ]] || return 1
  case "/$_relative/" in */../*|*/./*|*//*) return 1 ;; esac
  _python="${_MDM_ABSENCE_PYTHON:-}"
  [[ -n "$_python" ]] || _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -c '
import os, stat, sys
root, relative = sys.argv[1], sys.argv[2]
parts = relative.split("/")
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
held = []
try:
    current = os.open(root, flags)
except OSError:
    raise SystemExit(1)
try:
    held.append(current)
    identities = [(os.fstat(current).st_dev, os.fstat(current).st_ino)]
    missing = None
    for index, part in enumerate(parts):
        try:
            before = os.stat(part, dir_fd=current, follow_symlinks=False)
        except FileNotFoundError:
            missing = index
            break
        except OSError:
            raise SystemExit(1)
        if index == len(parts) - 1:
            raise SystemExit(1)
        if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
            raise SystemExit(1)
        try:
            child = os.open(part, flags, dir_fd=current)
        except OSError:
            raise SystemExit(1)
        opened = os.fstat(child)
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            os.close(child)
            raise SystemExit(1)
        held.append(child)
        identities.append((opened.st_dev, opened.st_ino))
        current = child

    if missing is None:
        raise SystemExit(1)

    # ENOENT on an open directory is not enough: an untrusted user can swap an
    # ancestor out of the live pathname while this walk still holds the old
    # inode.  Rebind from the root pathname after ENOENT, compare every parent
    # inode with the held chain, and observe ENOENT again.  A second complete
    # pass makes an in-progress swap fail closed instead of certifying a stale
    # detached tree.
    def rebound_absent():
        try:
            rebound = os.open(root, flags)
        except OSError:
            return False
        try:
            opened = os.fstat(rebound)
            if (opened.st_dev, opened.st_ino) != identities[0]:
                return False
            for edge in range(missing):
                try:
                    entry = os.stat(parts[edge], dir_fd=rebound, follow_symlinks=False)
                except OSError:
                    return False
                if not stat.S_ISDIR(entry.st_mode) or stat.S_ISLNK(entry.st_mode):
                    return False
                if (entry.st_dev, entry.st_ino) != identities[edge + 1]:
                    return False
                try:
                    child = os.open(parts[edge], flags, dir_fd=rebound)
                except OSError:
                    return False
                child_stat = os.fstat(child)
                if (child_stat.st_dev, child_stat.st_ino) != identities[edge + 1]:
                    os.close(child)
                    return False
                os.close(rebound)
                rebound = child
            try:
                os.stat(parts[missing], dir_fd=rebound, follow_symlinks=False)
            except FileNotFoundError:
                return True
            except OSError:
                return False
            return False
        finally:
            os.close(rebound)

    if not rebound_absent() or not rebound_absent():
        raise SystemExit(1)
    raise SystemExit(0)
finally:
    for descriptor in reversed(held):
        try:
            os.close(descriptor)
        except OSError:
            pass
' "$_root" "$_relative"
}

_mdm_deployment_digest() { # <manifest-snapshot> <claude-dir> <snapshot-dir> <target-uid>
  local _manifest="$1" _claude_dir="$2" _snapshot="$3" _target_uid="$4"
  local _expected="${_MDM_EXPECTED_OUTPUT:-}" _expected_manifest _expected_modes _expected_tree
  local _count _expected_count _mode_count _index=0 _file _relative _snap_file _canonical
  local _expected_relative _expected_file _expected_live_mode _expected_snap_mode _extra _mode_line
  local _live_copy _snap_copy _live_hash _snap_hash _live_mode _snap_mode _input _digest
  local _live_size _snap_size _aggregate=0 _workspace _live_managed _snap_managed _expected_managed
  local _absent_count _expected_absent_count _absent_index=0 _absent_relative _expected_absent
  [[ "$_target_uid" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$_expected" ]] || return 1
  _mdm_expected_tree_trusted "$_expected" || return 1
  _expected_manifest="$_expected/manifest.json"
  _expected_modes="$_expected/modes.tsv"
  _expected_tree="$_expected/tree"
  _mdm_json_valid "$_expected_manifest" || return 1
  [[ "$(_mdm_json_get "$_expected_manifest" profile)" == "${PROFILE:-standard}" ]] || return 1
  [[ "$(_mdm_json_get "$_expected_manifest" language)" == "${LANGUAGE:-en}" ]] || return 1
  _count="$(_mdm_json_array_count "$_manifest" files)"
  _expected_count="$(_mdm_json_array_count "$_expected_manifest" files)"
  _mode_count="$(/usr/bin/wc -l < "$_expected_modes" | /usr/bin/tr -d '[:space:]')" || return 1
  [[ "$_count" =~ ^[0-9]+$ && "$_count" -gt 0 && "$_count" -le 1000 \
    && "$_expected_count" == "$_count" && "$_mode_count" == "$_count" ]] || return 1
  _workspace="$(/usr/bin/mktemp -d "$(_mdm_safe_tmpdir)/claude-kit-mdm-attest.XXXXXX")" || return 1
  /bin/chmod 700 "$_workspace" || { /bin/rm -rf "$_workspace"; return 1; }
  _input="$_workspace/deployment-input"
  (umask 077; : > "$_input") || { /bin/rm -rf "$_workspace"; return 1; }
  while (( _index < _count )); do
    _file="$(_mdm_json_array_get "$_manifest" files "$_index")"
    [[ -n "$_file" && ! "$_file" =~ [[:cntrl:]] ]] || { /bin/rm -rf "$_workspace"; return 1; }
    case "$_file" in "$_claude_dir"/*) : ;; *) /bin/rm -rf "$_workspace"; return 1 ;; esac
    _relative="${_file#"$_claude_dir"/}"
    [[ -n "$_relative" && ! "$_relative" =~ [[:cntrl:]] ]] \
      || { /bin/rm -rf "$_workspace"; return 1; }
    case "/$_relative/" in */../*|*/./*|*//*) /bin/rm -rf "$_workspace"; return 1 ;; esac
    _expected_relative="$(_mdm_json_array_get "$_expected_manifest" files "$_index")"
    [[ "$_relative" == "$_expected_relative" ]] || { /bin/rm -rf "$_workspace"; return 1; }
    _mode_line="$(/usr/bin/sed -n "$((_index + 1))p" "$_expected_modes")" \
      || { /bin/rm -rf "$_workspace"; return 1; }
    _expected_live_mode=""; _expected_snap_mode=""; _extra=""
    IFS=$'\t' read -r _expected_relative _expected_live_mode _expected_snap_mode _extra <<< "$_mode_line"
    [[ "$_expected_relative" == "$_relative" && -z "$_extra" \
      && "$_expected_live_mode" =~ ^[0-7]{4}$ && "$_expected_snap_mode" =~ ^[0-7]{4}$ ]] \
      || { /bin/rm -rf "$_workspace"; return 1; }
    _canonical="$(_mdm_canonical_file "$_file")" || { /bin/rm -rf "$_workspace"; return 1; }
    [[ "$_canonical" == "$_file" ]] || { /bin/rm -rf "$_workspace"; return 1; }
    _snap_file="$_snapshot/$_relative"
    _canonical="$(_mdm_canonical_file "$_snap_file")" || { /bin/rm -rf "$_workspace"; return 1; }
    [[ "$_canonical" == "$_snap_file" ]] || { /bin/rm -rf "$_workspace"; return 1; }
    _expected_file="$_expected_tree/$_relative"
    _canonical="$(_mdm_canonical_file "$_expected_file")" || { /bin/rm -rf "$_workspace"; return 1; }
    [[ "$_canonical" == "$_expected_file" ]] || { /bin/rm -rf "$_workspace"; return 1; }
    _live_copy=""; _live_mode=""
    _mdm_stable_managed_snapshot "$_file" managed "$_target_uid" _live_copy _live_mode \
      || { /bin/rm -rf "$_workspace"; return 1; }
    _snap_copy=""; _snap_mode=""
    _mdm_stable_managed_snapshot "$_snap_file" snapshot "$_target_uid" _snap_copy _snap_mode \
      || { /bin/rm -f "$_live_copy"; /bin/rm -rf "$_workspace"; return 1; }
    [[ "$_live_mode" == "$_expected_live_mode" && "$_snap_mode" == "$_expected_snap_mode" ]] \
      || { /bin/rm -f "$_live_copy" "$_snap_copy"; /bin/rm -rf "$_workspace"; return 1; }
    _live_size="$(/usr/bin/wc -c < "$_live_copy" | /usr/bin/tr -d '[:space:]')"
    _snap_size="$(/usr/bin/wc -c < "$_snap_copy" | /usr/bin/tr -d '[:space:]')"
    [[ "$_live_size" =~ ^[0-9]+$ && "$_snap_size" =~ ^[0-9]+$ ]] \
      || { /bin/rm -f "$_live_copy" "$_snap_copy"; /bin/rm -rf "$_workspace"; return 1; }
    _aggregate=$((_aggregate + 10#$_live_size + 10#$_snap_size))
    (( _aggregate <= 536870912 )) \
      || { /bin/rm -f "$_live_copy" "$_snap_copy"; /bin/rm -rf "$_workspace"; return 1; }
    if [[ "$_relative" == CLAUDE.md ]]; then
      _live_managed="$_workspace/live-managed.$_index"
      _snap_managed="$_workspace/snapshot-managed.$_index"
      _expected_managed="$_workspace/expected-managed.$_index"
      _mdm_extract_managed_section "$_live_copy" "$_live_managed" 0 \
        && _mdm_extract_managed_section "$_snap_copy" "$_snap_managed" 1 \
        && _mdm_extract_managed_section "$_expected_file" "$_expected_managed" 1 \
        && /usr/bin/cmp -s "$_snap_copy" "$_snap_managed" \
        && /usr/bin/cmp -s "$_expected_file" "$_expected_managed" \
        && /usr/bin/cmp -s "$_live_managed" "$_expected_file" \
        && /usr/bin/cmp -s "$_snap_copy" "$_expected_file" \
        || { /bin/rm -f "$_live_copy" "$_snap_copy"; /bin/rm -rf "$_workspace"; return 1; }
      _live_hash="$(_mdm_sha256_file "$_live_managed")"
      _snap_hash="$(_mdm_sha256_file "$_snap_copy")"
    else
      /usr/bin/cmp -s "$_live_copy" "$_expected_file" \
        && /usr/bin/cmp -s "$_snap_copy" "$_expected_file" \
        || { /bin/rm -f "$_live_copy" "$_snap_copy"; /bin/rm -rf "$_workspace"; return 1; }
      _live_hash="$(_mdm_sha256_file "$_live_copy")"
      _snap_hash="$(_mdm_sha256_file "$_snap_copy")"
    fi
    /bin/rm -f "$_live_copy" "$_snap_copy"
    [[ "$_live_hash" =~ ^[0-9a-f]{64}$ && "$_snap_hash" =~ ^[0-9a-f]{64}$ ]] \
      || { /bin/rm -rf "$_workspace"; return 1; }
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$_relative" "$_live_hash" "$_snap_hash" "$_live_mode" "$_snap_mode" >> "$_input" \
      || { /bin/rm -rf "$_workspace"; return 1; }
    _index=$((_index + 1))
  done
  _absent_count="$(_mdm_json_array_count "$_manifest" mdm_absent_files)"
  _expected_absent_count="$(_mdm_json_array_count "$_expected_manifest" absent_files)"
  [[ "$_absent_count" =~ ^[0-9]+$ && "$_absent_count" -le 1000 \
    && "$_expected_absent_count" == "$_absent_count" \
    && $((_count + _absent_count)) -le 2000 ]] \
    || { /bin/rm -rf "$_workspace"; return 1; }
  _MDM_ABSENCE_PYTHON="$(_mdm_system_python)" \
    || { /bin/rm -rf "$_workspace"; return 1; }
  while (( _absent_index < _absent_count )); do
    _absent_relative="$(_mdm_json_array_get "$_manifest" mdm_absent_files "$_absent_index")"
    _expected_absent="$(_mdm_json_array_get \
      "$_expected_manifest" absent_files "$_absent_index")"
    [[ -n "$_absent_relative" && "$_absent_relative" == "$_expected_absent" ]] \
      || { /bin/rm -rf "$_workspace"; return 1; }
    _mdm_path_is_absent_with_real_parents "$_claude_dir" "$_absent_relative" \
      && _mdm_path_is_absent_with_real_parents "$_snapshot" "$_absent_relative" \
      || { /bin/rm -rf "$_workspace"; return 1; }
    printf 'absent\t%s\n' "$_absent_relative" >> "$_input" \
      || { /bin/rm -rf "$_workspace"; return 1; }
    _absent_index=$((_absent_index + 1))
  done
  _MDM_ABSENCE_PYTHON=""
  _digest="$(_mdm_sha256_file "$_input")"
  /bin/rm -rf "$_workspace"
  [[ "$_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$_digest"
}

_mdm_validate_manifest_snapshot() { # <snapshot-file> <home> <target-uid>
  local _manifest="$1" _home="$2" _target_uid="$3"
  local _version _commit _claude_dir _snapshot _profile _language _digest
  _mdm_json_valid "$_manifest" || return 1
  _version="$(_mdm_json_get "$_manifest" version)"
  [[ "$_version" == "2" ]] || return 1
  [[ "$(_mdm_json_get "$_manifest" mdm_managed)" == "true" ]] || return 1
  _claude_dir="$(_mdm_json_get "$_manifest" claude_dir)"
  _snapshot="$(_mdm_json_get "$_manifest" snapshot_dir)"
  [[ "$_claude_dir" == "$_home/.claude" ]] || return 1
  [[ "$_snapshot" == "$_home/.claude/.starter-kit-snapshot" ]] || return 1
  [[ "$(_mdm_canonical_dir "$_claude_dir")" == "$_claude_dir" ]] || return 1
  [[ "$(_mdm_canonical_dir "$_snapshot")" == "$_snapshot" ]] || return 1
  _commit="$(_mdm_json_get "$_manifest" kit_commit)"
  [[ "$_commit" =~ ^[0-9a-f]{7,40}$ && "$MDM_RCPT_RESOLVED_SHA" =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ "$MDM_RCPT_RESOLVED_SHA" == "$_commit"* ]] || return 1
  _profile="$(_mdm_json_get "$_manifest" profile)"
  _language="$(_mdm_json_get "$_manifest" language)"
  [[ "$_profile" == "${PROFILE:-standard}" ]] || return 1
  [[ "$_language" == "${LANGUAGE:-en}" ]] || return 1
  _digest="$(_mdm_deployment_digest "$_manifest" "$_claude_dir" "$_snapshot" "$_target_uid")" || return 1
  MDM_RCPT_PROFILE="$_profile"
  MDM_RCPT_LANGUAGE="$_language"
  MDM_RCPT_DEPLOYMENT_SHA256="$_digest"
}

# Revalidate the user-phase result from one fd-bound manifest byte snapshot.
# Root treats the checkout/manifest only as data and signs the complete live +
# snapshot deployment digest into its receipt.
_mdm_capture_postcondition() {
  local _home="$1" _target_uid="$2" _manifest
  [[ "$_target_uid" =~ ^[0-9]+$ ]] || return 1
  _manifest="$_home/.claude/.starter-kit-manifest.json"
  local _canonical _manifest_copy _manifest_hash _rc=1
  _canonical="$(_mdm_canonical_file "$_manifest")" || return 1
  [[ "$_canonical" == "$_manifest" ]] || return 1
  _manifest_copy="$(_mdm_stable_file_snapshot "$_manifest" manifest)" || return 1
  _manifest_hash="$(_mdm_sha256_file "$_manifest_copy")"
  if [[ "$_manifest_hash" =~ ^[0-9a-f]{64}$ ]] \
    && _mdm_validate_manifest_snapshot "$_manifest_copy" "$_home" "$_target_uid"; then
    MDM_RCPT_MANIFEST_PATH="$_manifest"
    MDM_RCPT_MANIFEST_SHA256="$_manifest_hash"
    _rc=0
  fi
  /bin/rm -f "$_manifest_copy"
  return "$_rc"
}

_mdm_user_phase_exit_code() { # <user-phase-rc> <dry-run>
  local _rc="$1" _dry_run="$2"
  case "$_rc" in
    0|"$MDM_EXIT_PREREQ"|"$MDM_EXIT_CONFIG") printf '%s' "$_rc" ;;
    "$MDM_EXIT_CLI")
      if [[ "$_dry_run" == "true" ]]; then
        printf '%s' "$MDM_EXIT_SETUP"
      else
        printf '%s' "$MDM_EXIT_CLI"
      fi ;;
    *) printf '%s' "$MDM_EXIT_SETUP" ;;
  esac
}

_mdm_handle_log_setup_failure() { # <user> <home> <dry-run>
  local _user="$1" _home="$2" _dry_run="$3"
  if [[ "$_dry_run" == "true" ]]; then
    return "$MDM_EXIT_CONFIG"
  fi
  _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_CONFIG"
  return "$MDM_EXIT_CONFIG"
}

# R1..R4 のオーケストレーション。root フェーズは実副作用
# （brew 導入・降格）を伴うため、単体テストでは各フェーズ関数を個別に
# 検証し、エントリポイントは clean-launch 契約までを検証する。
mdm_main() {
  # 外部コマンド実行の前に PATH を固定する。対象ユーザーが PATH に
  # 自分の bin を先頭挿入していると、uname/stat/git/curl/pkgutil/installer/
  # softwareupdate 等の裸コマンドが root 権限で乗っ取られ得る（MDM の汎用契約
  # や sudo 経路では既定環境の安全性が保証されない）。Homebrew は絶対パスで
  # 検出するため brew bin を PATH に足す必要はない。
  PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  export PATH
  GIT_CONFIG_NOSYSTEM=1
  GIT_CONFIG_GLOBAL=/dev/null
  GIT_TERMINAL_PROMPT=0
  GIT_NO_REPLACE_OBJECTS=1
  export GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL GIT_TERMINAL_PROMPT GIT_NO_REPLACE_OBJECTS

  # OS ガード
  [[ "$(/usr/bin/uname -s)" == "Darwin" ]] || { mdm_log R1 "非対応 OS"; exit "$MDM_EXIT_OS"; }

  # R1: root never sources an adjacent/user-owned library.  The launcher has
  # a data-only parser and executable mode has already discarded inherited env.
  _mdm_root_config_apply "$(_mdm_config_path)" "$@" || {
    mdm_log R1 "設定エラー"
    # Configuration is not authoritative until the complete file and argv
    # validate.  In particular, a rejected payload may have requested
    # KIT_MDM_DRY_RUN=true, so this early failure must not mutate compliance.
    exit "$MDM_EXIT_CONFIG"
  }
  _mdm_apply_mdm_defaults

  # A real remediation is a privileged/system operation.  Reject non-root
  # normal runs before target resolution, log creation, checkout mutation, or
  # receipt creation.  Non-root remains useful only as an explicit preview.
  local _euid _dry_run="false"
  _euid="$(/usr/bin/id -u)"
  _dry_run="$(_mdm_root_bool "${KIT_MDM_DRY_RUN:-false}" 2>/dev/null || echo false)"
  if [[ "$_euid" -ne 0 && "$_dry_run" != "true" ]]; then
    mdm_log R2 "通常の MDM remediation は root 実行が必須"
    exit "$MDM_EXIT_CONTEXT"
  fi

  # R2: ユーザー・home 解決（root の失敗時だけ system receipt を best-effort で試す）
  local _user _home _target_uid
  if [[ "$_euid" -eq 0 ]]; then
    _user="$(mdm_resolve_target_user)" \
      || _mdm_fail_or_exit_unresolved "$MDM_EXIT_USER" "$_dry_run"
    _home="$(mdm_validate_user_home "$_user")" \
      || _mdm_fail_or_exit_unresolved "$MDM_EXIT_USER" "$_dry_run"
    _target_uid="$(/usr/bin/id -u "$_user" 2>/dev/null || true)"
    [[ "$_target_uid" =~ ^[0-9]+$ ]] \
      || _mdm_fail_or_exit_unresolved "$MDM_EXIT_USER" "$_dry_run"
  else
    _user="$(/usr/bin/id -un)"; _home="$HOME"     # ユーザーモード
    _target_uid="$_euid"
    if [[ -n "${KIT_MDM_TARGET_USER:-}" && "$KIT_MDM_TARGET_USER" != "$_user" ]]; then
      mdm_log R2 "非 root 実行で別ユーザーは指定できない"
      exit "$MDM_EXIT_USER"
    fi
  fi
  MDM_RCPT_TARGET_USER="$_user"

  # Serialize every mutating run before any path can write a receipt. A
  # competing run exits without changing checkout, history, or compliance.
  if [[ "$_euid" -eq 0 && "$_dry_run" != true ]] \
    && ! _mdm_acquire_run_lock "$_user" "$_home"; then
    mdm_log R2 "同一ユーザーの MDM remediation が実行中"
    exit "$MDM_EXIT_CONTEXT"
  fi

  # ログ開始（設定確定後 = KIT_MDM_LOG_DIR が管理設定/CLI からも効く）。
  if ! _mdm_setup_log_file "$_euid" "$_home"; then
    # A preview must not create or replace a compliance receipt, even when its
    # audit-log destination is invalid or unavailable.
    local _log_failure_rc=0
    _mdm_handle_log_setup_failure "$_user" "$_home" "$_dry_run" \
      || _log_failure_rc=$?
    exit "$_log_failure_rc"
  fi

  # R3: CLT is always checked before the first Git command.  Dry-run never
  # installs prerequisites; it only reports what is already available.
  if [[ "$_dry_run" == "true" ]]; then
    # Both root and non-root previews need Git before their temporary clone.
    # Report the same prerequisite code without attempting installation.
    local _dry_prereq_rc=0
    _mdm_check_dryrun_prerequisites || _dry_prereq_rc=$?
    [[ "$_dry_prereq_rc" -eq 0 ]] || exit "$_dry_prereq_rc"
  elif [[ "$_euid" -eq 0 ]]; then
    local _prereq_rc=0 _brew_usable=false
    _mdm_ensure_clt || _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_PREREQ"
    if _mdm_brew_usable_for_user "$_target_uid" "$_user" "$_home"; then
      _brew_usable=true
    fi
    case "$(mdm_prereq_plan "$_brew_usable")" in
      fail) mdm_log R3 "前提不足かつ導入無効"; _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_PREREQ" ;;
      bootstrap)
        _mdm_bootstrap_homebrew "$_user" || _prereq_rc=$?
        if [[ "$_prereq_rc" -ne 0 ]] \
          || ! _mdm_brew_usable_for_user "$_target_uid" "$_user" "$_home"; then
          mdm_log R3 "Homebrew が対象ユーザーで利用可能にならない"
          _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_BREW"
        fi ;;
    esac
  fi

  # U1b..U3: キット取得(ref 固定) + setup 実行 + CLI 導入の確認。
  # root 時は git 操作・setup.sh 実行とも検証済みユーザーへ環境分離降格（Critical#2）。
  local _user_rc=0 _final_user_rc
  _mdm_run_user_phase "$_euid" "$_user" "$_home" || _user_rc=$?
  _final_user_rc="$(_mdm_user_phase_exit_code "$_user_rc" "$_dry_run")"
  if [[ "$_dry_run" == "true" ]]; then
    _mdm_cleanup_transient_checkouts
    if [[ "$_final_user_rc" -eq 0 ]]; then
      mdm_log R4 "dry-run 完了（receipt/compliance は不変）"
      exit 0
    fi
    mdm_log R4 "dry-run 失敗: exit=$_user_rc"
    exit "$_final_user_rc"
  fi
  if [[ "$_final_user_rc" -eq "$MDM_EXIT_PREREQ" ]]; then
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_PREREQ"
  elif [[ "$_final_user_rc" -eq "$MDM_EXIT_CLI" ]]; then
    # キット配備自体は成功したが必須 CLI が欠如（部分失敗として報告）
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_CLI"
  elif [[ "$_final_user_rc" -eq "$MDM_EXIT_CONFIG" ]]; then
    # install_dir 制約違反等の設定エラーは 30 に潰さず 50 を維持
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_CONFIG"
  elif [[ "$_final_user_rc" -ne 0 ]]; then
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_SETUP"
  fi

  if ! _mdm_capture_postcondition "$_home" "$_target_uid"; then
    mdm_log R4 "配備 postcondition の検証に失敗"
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_SETUP"
  fi
  # Persist deletion authority only after root has verified that these paths
  # are the files actually deployed in both live and snapshot state.
  if ! _mdm_persist_managed_history "$_user" "$_home"; then
    mdm_log R4 "root managed history の永続化に失敗"
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_SETUP"
  fi

  # R4: 成功レシート
  _mdm_finish "$_user" "$_home" success "$MDM_EXIT_OK"
}

# ── エントリポイント。source-only 時（テスト）は実行しない。────
# --mdm-user-phase 等の内部専用フラグは持たない: 単一の mdm_main が全フェーズを配線する。
if [[ "${MDM_SOURCE_ONLY:-0}" != "1" ]] && { [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; }; then
  mdm_main "$@"
fi
