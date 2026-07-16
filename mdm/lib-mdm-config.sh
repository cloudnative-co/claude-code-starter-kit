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

# 設定ファイルの安全性検証（読み取り直前に呼ぶ）。
mdm_config_file_is_secure() {
  local _f="$1"
  [[ -e "$_f" ]] || return 1
  [[ -L "$_f" ]] && return 1                  # symlink 拒否
  # group/other 書込ビットが立っていたら拒否（stat はBSD/GNU両対応）
  local _mode
  _mode="$(stat -f '%Lp' "$_f" 2>/dev/null || stat -c '%a' "$_f" 2>/dev/null || echo '')"
  case "$_mode" in
    *[2367])  return 1 ;;                       # other 書込
  esac
  case "$_mode" in
    ?[2367]?) return 1 ;;                       # group 書込
  esac
  if [[ "${MDM_CONFIG_SKIP_OWNER_CHECK:-0}" != "1" ]]; then
    local _owner
    _owner="$(stat -f '%Su' "$_f" 2>/dev/null || stat -c '%U' "$_f" 2>/dev/null || echo '')"
    [[ "$_owner" == "root" ]] || return 1
  fi
  return 0
}

# 許可キー allowlist（本体 _CONFIG_KEYS の実名 + KIT_MDM_ 群）。Task 10 で乖離検出テストが監視する。
_MDM_ALLOWED_KEYS="PROFILE LANGUAGE EDITOR_CHOICE COMMIT_ATTRIBUTION \
ENABLE_GHOSTTY_SETUP ENABLE_FONTS_SETUP ENABLE_STATUSLINE ENABLE_SAFETY_NET \
ENABLE_AUTO_UPDATE ENABLE_DOC_SIZE_GUARD ENABLE_FEATURE_RECOMMENDATION \
ENABLE_PRE_COMPACT_COMMIT ENABLE_WEB_CONTENT_UPDATE ENABLE_NO_FLICKER ENABLE_NEW_INIT \
KIT_MDM_TARGET_USER KIT_MDM_INSTALL_HOMEBREW KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE \
KIT_MDM_PREREQ_MODE KIT_MDM_WINDOWS_MODE KIT_MDM_INSTALL_CLAUDE_CLI \
KIT_MDM_GIT_REF KIT_MDM_INSTALL_DIR KIT_MDM_LOG_DIR KIT_MDM_DRY_RUN"

_mdm_key_is_allowed() {
  local _k="$1" _a
  for _a in $_MDM_ALLOWED_KEYS; do [[ "$_k" == "$_a" ]] && return 0; done
  return 1
}

# キーごとの型検証。合格すれば正規化値を stdout。不正なら exit 1。
_mdm_validate_key() {
  local _k="$1" _v="$2"
  case "$_k" in
    PROFILE)                 mdm_validate_enum "$_v" "minimal,standard,full" ;;
    KIT_MDM_PREREQ_MODE)     mdm_validate_enum "$_v" "auto,skip,fail" ;;
    KIT_MDM_WINDOWS_MODE)    mdm_validate_enum "$_v" "gitbash,wsl" ;;
    LANGUAGE)                mdm_validate_enum "$_v" "en,ja" ;;
    ENABLE_*|KIT_MDM_INSTALL_HOMEBREW|KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE|KIT_MDM_INSTALL_CLAUDE_CLI|KIT_MDM_DRY_RUN|COMMIT_ATTRIBUTION)
                             mdm_validate_bool "$_v" ;;
    KIT_MDM_GIT_REF)         mdm_validate_gitref "$_v" ;;
    KIT_MDM_TARGET_USER)     mdm_validate_username "$_v" ;;
    KIT_MDM_INSTALL_DIR|KIT_MDM_LOG_DIR) mdm_validate_abspath "$_v" ;;
    EDITOR_CHOICE)           printf '%s' "$_v" ;;   # 自由文字列（後段でさらに検証）
    *)                       printf '%s' "$_v" ;;
  esac
}

# 設定ファイルを読み、allowlist + 型検証し、未設定のキーのみ export（優先順位: 既存 env 値は保持）。
# 不正値は exit 50、ファイル不安全は exit 50。
mdm_config_apply() {
  local _f="$1"
  [[ -f "$_f" ]] || return 0                    # ファイルなしは何もしない
  mdm_config_file_is_secure "$_f" || return 50
  local _line _k _v _norm
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    case "$_line" in
      ''|'#'*) continue ;;
    esac
    case "$_line" in
      *=*) : ;;
      *)   continue ;;
    esac
    _k="${_line%%=*}"
    _v="${_line#*=}"
    _v="${_v%\"}"; _v="${_v#\"}"                 # 両端のダブルクォート除去
    if ! _mdm_key_is_allowed "$_k"; then
      printf '[mdm-config] WARN: unknown key ignored: %s\n' "$_k" >&2
      continue
    fi
    if ! _norm="$(_mdm_validate_key "$_k" "$_v")"; then
      printf '[mdm-config] ERROR: invalid value for %s\n' "$_k" >&2
      return 50
    fi
    # 優先順位: 既に非空の値が環境にあれば上書きしない（Bash 3.2 互換の間接展開。eval は使わない）
    if [[ -z "${!_k:-}" ]]; then
      export "$_k=$_norm"
    fi
  done < "$_f"
  return 0
}
