#!/usr/bin/env bash
# mdm/install-mdm.sh — macOS 向け MDM サイレントインストーラ兼自己ブートストラップ launcher
# 詳細契約: docs/superpowers/specs/2026-07-16-mdm-silent-install-design.md
set -euo pipefail

# ── 終了コード定数（固定契約 spec §8.1）────────────────────
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

# ── レシート用グローバル（各フェーズが埋める）──────────────
MDM_RCPT_KIT_VERSION=""; MDM_RCPT_GIT_REF=""; MDM_RCPT_RESOLVED_SHA=""
MDM_RCPT_INSTALL_DIR=""; MDM_RCPT_REQUIRED_COMPONENTS='["kit"]'; MDM_RCPT_PROFILE=""
MDM_RCPT_TARGET_USER=""; MDM_RCPT_PARTIAL='[]'; MDM_RCPT_TIMESTAMP=""; MDM_RCPT_LOG_PATH=""

MDM_LOG_FILE="${MDM_LOG_FILE:-}"

mdm_log() {
  local _phase="$1"; shift
  local _msg="$*"
  local _line="[$_phase] $_msg"
  printf '%s\n' "$_line" >&2
  if [[ -n "$MDM_LOG_FILE" ]]; then
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" "$_line" >> "$MDM_LOG_FILE" 2>/dev/null || true
  fi
}

# JSON 文字列値のエスケープ（backslash と double-quote のみ。改行等は呼び出し側が渡さない）
mdm_json_escape() {
  local _s="$1"
  _s="${_s//\\/\\\\}"
  _s="${_s//\"/\\\"}"
  printf '%s' "$_s"
}

# jq 非依存でレシート JSON を書く。required_components / partial は既に JSON 配列文字列。
mdm_receipt_write() {
  local _path="$1" _result="$2" _exit="$3"
  local _dir; _dir="$(dirname "$_path")"
  mkdir -p "$_dir" 2>/dev/null || true
  {
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "kit_version": "%s",\n'  "$(mdm_json_escape "$MDM_RCPT_KIT_VERSION")"
    printf '  "git_ref": "%s",\n'      "$(mdm_json_escape "$MDM_RCPT_GIT_REF")"
    printf '  "resolved_sha": "%s",\n' "$(mdm_json_escape "$MDM_RCPT_RESOLVED_SHA")"
    printf '  "install_dir": "%s",\n'  "$(mdm_json_escape "$MDM_RCPT_INSTALL_DIR")"
    printf '  "required_components": %s,\n' "$MDM_RCPT_REQUIRED_COMPONENTS"
    printf '  "profile": "%s",\n'      "$(mdm_json_escape "$MDM_RCPT_PROFILE")"
    printf '  "target_user": "%s",\n'  "$(mdm_json_escape "$MDM_RCPT_TARGET_USER")"
    printf '  "result": "%s",\n'       "$(mdm_json_escape "$_result")"
    printf '  "exit_code": %s,\n'      "$_exit"
    printf '  "partial": %s,\n'        "$MDM_RCPT_PARTIAL"
    printf '  "timestamp": "%s",\n'    "$(mdm_json_escape "$MDM_RCPT_TIMESTAMP")"
    printf '  "log_path": "%s"\n'      "$(mdm_json_escape "$MDM_RCPT_LOG_PATH")"
    printf '}\n'
  } > "$_path"
}

# コンソールユーザーを取得（テスト時は MDM_CONSOLE_USER_OVERRIDE を優先）
_mdm_console_user() {
  if [[ -n "${MDM_CONSOLE_USER_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_CONSOLE_USER_OVERRIDE"; return 0
  fi
  # scutil の ConsoleUser、フォールバック stat /dev/console
  local _u
  _u="$(printf 'show State:/Users/ConsoleUser\n' | scutil 2>/dev/null | awk '/Name :/{print $3; exit}' || true)"
  [[ -z "$_u" ]] && _u="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
  printf '%s' "$_u"
}

mdm_resolve_target_user() {
  local _u="${KIT_MDM_TARGET_USER:-}"
  [[ -z "$_u" ]] && _u="$(_mdm_console_user)"
  case "$_u" in
    ''|root|_mbsetupuser|loginwindow|daemon|nobody)
      mdm_log R2 "対象ユーザーを解決できない（'$_u' は無効）"
      return "$MDM_EXIT_USER" ;;
  esac
  printf '%s' "$_u"
  return 0
}

# 対象ユーザーの canonical home を取得・検証。dscl はモック可能。
mdm_validate_user_home() {
  local _user="$1" _home
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
  if [[ "${MDM_VALIDATE_HOME_SKIP_OWNER:-0}" != "1" ]]; then
    local _owner; _owner="$(stat -f '%Su' "$_home" 2>/dev/null || echo '')"
    if [[ "$_owner" != "$_user" ]]; then
      mdm_log R2 "home の所有者が対象ユーザーでない: $_owner"
      return "$MDM_EXIT_USER"
    fi
  fi
  # canonical 化
  ( cd "$_home" 2>/dev/null && pwd -P )
}

# ── main は Task 8 で実装。source-only 時は実行しない。────────
if [[ "${MDM_SOURCE_ONLY:-0}" != "1" ]] && { [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; }; then
  mdm_main "$@"   # Task 8 で定義
fi
