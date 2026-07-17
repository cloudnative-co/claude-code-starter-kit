#!/usr/bin/env bash
# mdm/detect-mdm.sh — レシート実体照合による compliant 判定（spec §8.4）
set -euo pipefail

_mdm_json_get() {  # <file> <key>
  local _f="$1" _k="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$_k" '.[$k] // empty' "$_f" 2>/dev/null || true
  else
    grep -oE "\"$_k\"[[:space:]]*:[[:space:]]*\"?[^,\"}]*" "$_f" 2>/dev/null \
      | head -1 | sed -E "s/\"$_k\"[[:space:]]*:[[:space:]]*\"?//" || true
  fi
}

# 対象ユーザーの home を解決（テスト時は MDM_DETECT_HOME_OVERRIDE）。
_mdm_detect_user_home() {
  local _user="$1"
  if [[ -n "${MDM_DETECT_HOME_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_DETECT_HOME_OVERRIDE"; return 0
  fi
  dscl . -read "/Users/$_user" NFSHomeDirectory 2>/dev/null | awk '{print $2; exit}' || true
}

# コンソールユーザーを取得（install-mdm.sh の _mdm_console_user と同一契約の複製。
# detect-mdm.sh は単体配布されるため install-mdm.sh に依存しない）。
_mdm_detect_console_user() {
  if [[ -n "${MDM_CONSOLE_USER_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_CONSOLE_USER_OVERRIDE"; return 0
  fi
  local _u
  _u="$(printf 'show State:/Users/ConsoleUser\n' | scutil 2>/dev/null | awk '/Name :/{print $3; exit}' || true)"
  [[ -z "$_u" ]] && _u="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
  printf '%s' "$_u"
}

# Claude CLI の存在確認。★検知プロセスの PATH ではなく対象ユーザーの home
# 実体（~/.local/bin/claude）を基準にする（最終レビュー High#6）。
# PATH フォールバックは非 root（= 自分自身の self-check）のときのみ。
# $1 = 対象ユーザーの home（空なら home 解決失敗 = CLI 未確認扱い）
_mdm_cli_present() {
  if [[ -n "${MDM_DETECT_CLI_PRESENT_OVERRIDE:-}" ]]; then
    [[ "$MDM_DETECT_CLI_PRESENT_OVERRIDE" == "1" ]]; return
  fi
  local _home="${1:-}"
  [[ -n "$_home" && -x "$_home/.local/bin/claude" ]] && return 0
  local _euid
  _euid="${MDM_EUID_OVERRIDE:-$(id -u)}"
  [[ "$_euid" -eq 0 ]] && return 1
  command -v claude >/dev/null 2>&1
}

# レシート実体照合（spec §8.4）:
#   result=success / target_user 一致 / install_dir の clone 実在 /
#   HEAD == resolved_sha / claude_cli 必須時は対象ユーザー home の CLI 実在。
# $1=レシートパス $2=期待する対象ユーザー（空なら照合スキップ = テスト用）
mdm_detect() {
  local _rcpt="$1" _user="${2:-}"
  [[ -f "$_rcpt" ]] || return 1
  local _result _install _reqs _target _sha _head
  _result="$(_mdm_json_get "$_rcpt" result)"
  [[ "$_result" == "success" ]] || return 1
  # 退職者アカウント等、別ユーザーのレシートは対象ユーザー不一致で除外
  if [[ -n "$_user" ]]; then
    _target="$(_mdm_json_get "$_rcpt" target_user)"
    [[ "$_target" == "$_user" ]] || return 1
  fi
  _install="$(_mdm_json_get "$_rcpt" install_dir)"
  [[ -n "$_install" && -d "$_install/.git" ]] || return 1
  # 実体照合: clone の HEAD がレシートの resolved_sha と一致すること
  _sha="$(_mdm_json_get "$_rcpt" resolved_sha)"
  [[ -n "$_sha" ]] || return 1
  _head="$(git -C "$_install" rev-parse --verify HEAD 2>/dev/null || true)"
  [[ -n "$_head" && "$_head" == "$_sha" ]] || return 1
  _reqs="$(grep -o '"required_components"[^]]*]' "$_rcpt" 2>/dev/null || echo '')"
  case "$_reqs" in
    *claude_cli*)
      _mdm_cli_present "$(_mdm_detect_user_home "$_user")" || return 1 ;;
  esac
  return 0
}

# X.Y.Z 形式のバージョンを比較する（v プレフィックスと -N-gSHA サフィックスは無視）。
# $1 < $2 なら true (exit 0)。Bash 3.2 互換（配列 + 算術評価のみ使用）。
_mdm_version_lt() {
  local _a="${1#v}" _b="${2#v}"
  _a="${_a%%-*}"; _b="${_b%%-*}"
  local _ifs_bak="$IFS"
  IFS=.
  # shellcheck disable=SC2206
  local -a _a_parts=($_a) _b_parts=($_b)
  IFS="$_ifs_bak"
  local _i _ai _bi
  for _i in 0 1 2; do
    _ai="${_a_parts[_i]:-0}"; _bi="${_b_parts[_i]:-0}"
    [[ "$_ai" =~ ^[0-9]+$ ]] || _ai=0
    [[ "$_bi" =~ ^[0-9]+$ ]] || _bi=0
    if ((_ai < _bi)); then return 0; fi
    if ((_ai > _bi)); then return 1; fi
  done
  return 1
}

if [[ "${MDM_SOURCE_ONLY:-0}" != "1" ]] && [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  # 引数処理: --user / --min-version（spec §8.4）。
  # 既定の対象ユーザー: root 実行（MDM の検知コンテキスト）ではコンソール
  # ユーザーを解決する。旧実装の `id -un` は root 検知で receipt-root.json を
  # 探してしまい、正常端末が常に non-compliant になった（最終レビュー High#6）。
  # 非 root は self-check として自分自身。
  _mdm_detect_user=""
  _mdm_detect_min_version=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        _mdm_detect_user="${2:-}"; shift 2 ;;
      --min-version)
        _mdm_detect_min_version="${2:-}"; shift 2 ;;
      *)
        shift ;;
    esac
  done
  if [[ -z "$_mdm_detect_user" ]]; then
    _mdm_detect_euid="${MDM_EUID_OVERRIDE:-$(id -u)}"
    if [[ "$_mdm_detect_euid" -eq 0 ]]; then
      _mdm_detect_user="$(_mdm_detect_console_user)"
    else
      _mdm_detect_user="$(id -un 2>/dev/null || echo unknown)"
    fi
  fi
  # username 文字種検証（--user の未検証値でパス組み立てをしない）
  if ! printf '%s' "$_mdm_detect_user" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$'; then
    printf 'non-compliant: invalid target user (%s)\n' "$_mdm_detect_user"
    exit 1
  fi
  _rcpt_path="${MDM_RECEIPT_DIR_OVERRIDE:-/Library/Application Support/ClaudeCodeStarterKit}/receipt-$_mdm_detect_user.json"

  if ! mdm_detect "$_rcpt_path" "$_mdm_detect_user"; then
    printf 'non-compliant: receipt missing or verification failed (%s)\n' "$_rcpt_path"
    exit 1
  fi

  if [[ -n "$_mdm_detect_min_version" ]]; then
    _mdm_detect_kit_version="$(_mdm_json_get "$_rcpt_path" kit_version)"
    if _mdm_version_lt "$_mdm_detect_kit_version" "$_mdm_detect_min_version"; then
      printf 'non-compliant: kit_version %s < required %s\n' "$_mdm_detect_kit_version" "$_mdm_detect_min_version"
      exit 1
    fi
  fi

  printf 'compliant\n'
  exit 0
fi
