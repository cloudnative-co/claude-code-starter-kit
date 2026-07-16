#!/usr/bin/env bash
# mdm/lib-mdm-config.sh — MDM 管理設定の型検証パーサ（Bash 3.2 互換・source/eval なし）
# install-mdm.sh / detect-mdm.sh が source する。

# 正規化した bool を stdout へ。不正なら exit 1。
mdm_validate_bool() {
  case "$1" in
    true|1|yes|on|TRUE|Yes|On|YES|ON)   printf 'true';  return 0 ;;
    false|0|no|off|FALSE|No|Off|NO|OFF)  printf 'false'; return 0 ;;
    *) return 1 ;;
  esac
}

# 値が allowed-csv に含まれれば stdout へ。含まれなければ exit 1。
mdm_validate_enum() {
  local _val="$1" _allowed="$2" _item
  local _oldifs="$IFS"; IFS=','
  for _item in $_allowed; do
    if [[ "$_val" == "$_item" ]]; then IFS="$_oldifs"; printf '%s' "$_val"; return 0; fi
  done
  IFS="$_oldifs"; return 1
}

# git ref: 40/64 桁 hex は SHA として許可、それ以外は check-ref-format --branch。
# 素の check-ref-format は bare な main/tag を弾くため --branch を使う（spec §5.5）。
mdm_validate_gitref() {
  local _ref="$1"
  [[ -z "$_ref" ]] && return 1
  if printf '%s' "$_ref" | grep -qE '^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$'; then
    printf '%s' "$_ref"; return 0
  fi
  if git check-ref-format --branch "$_ref" >/dev/null 2>&1; then
    printf '%s' "$_ref"; return 0
  fi
  return 1
}

# OS ユーザー名文字種のみ許可。
mdm_validate_username() {
  local _u="$1"
  printf '%s' "$_u" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$' || return 1
  printf '%s' "$_u"; return 0
}

# 絶対パスかつ .. を含まない。
mdm_validate_abspath() {
  local _p="$1"
  case "$_p" in
    /*) : ;;
    *)  return 1 ;;
  esac
  case "$_p" in
    *..*) return 1 ;;
  esac
  printf '%s' "$_p"; return 0
}
