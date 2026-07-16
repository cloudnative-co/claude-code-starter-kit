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

_mdm_cli_present() {
  if [[ -n "${MDM_DETECT_CLI_PRESENT_OVERRIDE:-}" ]]; then
    [[ "$MDM_DETECT_CLI_PRESENT_OVERRIDE" == "1" ]]; return
  fi
  command -v claude >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/claude" ]]
}

mdm_detect() {
  local _rcpt="$1"
  [[ -f "$_rcpt" ]] || return 1
  local _result _install _reqs
  _result="$(_mdm_json_get "$_rcpt" result)"
  [[ "$_result" == "success" ]] || return 1
  _install="$(_mdm_json_get "$_rcpt" install_dir)"
  [[ -n "$_install" && -d "$_install/.git" ]] || return 1
  _reqs="$(grep -o '"required_components"[^]]*]' "$_rcpt" 2>/dev/null || echo '')"
  case "$_reqs" in
    *claude_cli*)
      _mdm_cli_present || return 1 ;;
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
  # 引数処理: --user / --min-version / 既定はカレントユーザーのレシート（spec §8.4）
  _mdm_detect_user="$(id -un 2>/dev/null || echo unknown)"
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
  _rcpt_path="/Library/Application Support/ClaudeCodeStarterKit/receipt-$_mdm_detect_user.json"

  if ! mdm_detect "$_rcpt_path"; then
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
