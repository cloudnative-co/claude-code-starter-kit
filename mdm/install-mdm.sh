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

# 配布元リポジトリ（install.sh と同一 URL。KIT_MDM_GIT_REF で SHA を固定する
# ため URL 自体は固定でよい。spec §9.1）。
# テスト時は MDM_KIT_REPO_URL_OVERRIDE でローカル fixture repo に差し替え可能
# （参照箇所で call-time に解決する — source 時点の環境に縛られない）。
_MDM_KIT_REPO_URL="https://github.com/cloudnative-co/claude-code-starter-kit.git"

# 管理設定ファイルの固定パス（spec §7.2）。テスト時は MDM_CONFIG_PATH_OVERRIDE。
_mdm_config_path() {
  printf '%s' "${MDM_CONFIG_PATH_OVERRIDE:-/Library/Application Support/ClaudeCodeStarterKit/mdm-config.conf}"
}

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

# 対象ユーザーの UID を dscl で取得（実在確認を兼ねる）。
# テスト時は MDM_DSCL_UID_OVERRIDE でモック可能。解決不能なら空を返す。
_mdm_user_uid() {
  local _user="$1"
  if [[ -n "${MDM_DSCL_UID_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_DSCL_UID_OVERRIDE"; return 0
  fi
  dscl . -read "/Users/$_user" UniqueID 2>/dev/null | awk '{print $2; exit}' || true
}

# spec §5.4: 予約名 denylist に加えて、username 文字種・dscl 実在確認・
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

# ref を確定 SHA に解決（spec §5.5）。install.sh は再実行しない前提で wrapper が直接管理。
mdm_resolve_ref_sha() {
  local _repo="$1" _ref="$2" _sha
  # 形式検証（SHA or check-ref-format --branch）
  if ! mdm_validate_gitref "$_ref" >/dev/null 2>&1; then
    mdm_log U1b "不正な git ref 形式: $_ref"
    return "$MDM_EXIT_CONFIG"
  fi
  # SHA 直指定ならそのまま commit 解決を試す
  # NOTE: --verify 必須。無指定の `git rev-parse <ref>` は解決失敗時でも
  # 引数文字列をそのまま stdout へ echo して返す（exit code は非0でも stdout
  # が非空になる）ため、後段の `[[ -z "$_sha" ]]` チェックをすり抜けて
  # 未解決 ref をそのまま「確定 SHA」として誤って返してしまう（実機検証済み）。
  # --verify は失敗時に stdout を空にする。
  # git は _mdm_git 経由（root 時は検証済みユーザーへ降格。Critical#2）
  if printf '%s' "$_ref" | grep -qE '^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$'; then
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
    # NOTE: spec §5.5 のフェーズ番号は U1b（キット取得+refピン留め）。
    mdm_log U1b "ref を解決できない: $_ref"
    return "$MDM_EXIT_SETUP"
  fi
  printf '%s' "$_sha"
  return 0
}

# ── 前提ブートストラップの判定（brew 有無・CLT 方針）spec §5.x ──
# brew 有無検知。MDM_BREW_PRESENT_OVERRIDE でテスト時にモック可能（"1"=あり/それ以外=なし）。
_mdm_brew_present() {
  if [[ -n "${MDM_BREW_PRESENT_OVERRIDE:-}" ]]; then
    [[ "$MDM_BREW_PRESENT_OVERRIDE" == "1" ]]; return
  fi
  [[ -x /opt/homebrew/bin/brew || -x /usr/local/bin/brew ]] || command -v brew >/dev/null 2>&1
}

# brew 有無 × KIT_MDM_INSTALL_HOMEBREW × KIT_MDM_PREREQ_MODE から方針を決定し stdout へ。
# skip=brew あり(または PREREQ_MODE=skip)で何もしない / bootstrap=brew 導入が必要 / fail=導入せず不足で終了。
# 実際の CLT/Homebrew 導入は _mdm_bootstrap_prereqs（後述）が担う。
mdm_prereq_plan() {
  case "${KIT_MDM_PREREQ_MODE:-auto}" in
    skip) printf 'skip'; return 0 ;;
  esac
  if _mdm_brew_present; then printf 'skip'; return 0; fi
  case "$(mdm_validate_bool "${KIT_MDM_INSTALL_HOMEBREW:-true}" 2>/dev/null || echo true)" in
    true) printf 'bootstrap' ;;
    *)    printf 'fail' ;;
  esac
  return 0
}

# 降格実行時に対象ユーザーへ引き継ぐ環境変数の許可リスト（env -i で root 環境を
# 継承しないため、渡すものだけを明示列挙する。spec §5.3）。
_MDM_PASSTHROUGH_KEYS="PROFILE LANGUAGE EDITOR_CHOICE COMMIT_ATTRIBUTION \
ENABLE_GHOSTTY_SETUP ENABLE_FONTS_SETUP ENABLE_STATUSLINE ENABLE_SAFETY_NET \
ENABLE_AUTO_UPDATE ENABLE_DOC_SIZE_GUARD ENABLE_FEATURE_RECOMMENDATION \
ENABLE_PRE_COMPACT_COMMIT ENABLE_WEB_CONTENT_UPDATE ENABLE_NO_FLICKER ENABLE_NEW_INIT \
KIT_MDM_GIT_REF KIT_MDM_INSTALL_DIR KIT_MDM_INSTALL_CLAUDE_CLI KIT_MDM_DRY_RUN \
HTTP_PROXY HTTPS_PROXY NO_PROXY"

# LANGUAGE（en/ja。本体の実キー値）を POSIX ロケール名へ変換する。
# NOTE(Task8 バグ修正): 旧実装は "LANG=${LANGUAGE}_JP.UTF-8" と決め打ちしており
# LANGUAGE=en のとき不正ロケール "en_JP.UTF-8" を生成していた。正しくマップする。
_mdm_lang_to_locale() {
  case "${1:-}" in
    en) printf 'en_US.UTF-8' ;;
    ja) printf 'ja_JP.UTF-8' ;;
    *)  printf 'C.UTF-8' ;;
  esac
}

# 降格 argv をグローバル配列 MDM_DROP_ARGV へ直接構築する（最終レビュー High#4）。
# ★旧実装の「改行区切り stdout → read -r で配列化」は、改行を含む値（env 由来
# EDITOR_CHOICE 等）が env のコマンド位置に落ちて任意コマンド実行になり得たため
# 廃止。シリアライズ/再パースを一切行わず、値は常に単一の配列要素として保持する。
# 多層防御として、制御文字（改行/CR/タブ等）を含む passthrough 値は拒否する。
# 引数 $4 以降は実行するコマンド argv（インタプリタ込みで呼び出し側が絶対パス指定）。
MDM_DROP_ARGV=()
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
  )
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
# （KIT_MDM_DRY_RUN=true のとき --dry-run を追加。spec §7.3）。
# $1（任意）= 対象ユーザーの canonical home。既存インストール
# （manifest 存在）を検出した場合は --update を付与し本体の update パス
# を通す（spec §8.5、最終レビュー High#5）。
MDM_SETUP_ARGV=()
mdm_build_setup_argv() {
  local _home="${1:-}"
  MDM_SETUP_ARGV=(--non-interactive)
  if [[ -n "$_home" && -f "$_home/.claude/.starter-kit-manifest.json" ]]; then
    MDM_SETUP_ARGV[${#MDM_SETUP_ARGV[@]}]='--update'
  fi
  if [[ "$(mdm_validate_bool "${KIT_MDM_DRY_RUN:-false}" 2>/dev/null || echo false)" == "true" ]]; then
    MDM_SETUP_ARGV[${#MDM_SETUP_ARGV[@]}]='--dry-run'
  fi
}

# 隣接 lib が root にとって信頼可能か（R2-Critical 対応）。
# 通常ファイル・非 symlink・root 所有・ファイルと親 dir とも group/other 書込不可。
# _mdm_boot_config_file_is_secure と同じ検査だが、対象が「これから root で
# source する実行コード」なので独立関数として明示する。
_mdm_adjacent_lib_is_trusted() {
  local _lib="$1"
  [[ -f "$_lib" && ! -L "$_lib" ]] || return 1
  local _dir _mode _dmode
  _dir="$(dirname "$_lib")"
  _mode="$(stat -f '%Lp' "$_lib" 2>/dev/null || stat -c '%a' "$_lib" 2>/dev/null || echo '')"
  _mdm_boot_mode_is_safe "$_mode" || return 1
  _dmode="$(stat -f '%Lp' "$_dir" 2>/dev/null || stat -c '%a' "$_dir" 2>/dev/null || echo '')"
  _mdm_boot_mode_is_safe "$_dmode" || return 1
  if [[ "${MDM_CONFIG_SKIP_OWNER_CHECK:-0}" != "1" ]]; then
    local _owner _downer
    _owner="$(stat -f '%Su' "$_lib" 2>/dev/null || stat -c '%U' "$_lib" 2>/dev/null || echo '')"
    [[ "$_owner" == "root" ]] || return 1
    _downer="$(stat -f '%Su' "$_dir" 2>/dev/null || stat -c '%U' "$_dir" 2>/dev/null || echo '')"
    [[ "$_downer" == "root" ]] || return 1
  fi
  return 0
}

# ── 自己ブートストラップ判定（spec §3.1・§5.1 U1a）─────────
# 隣接する lib-mdm-config.sh が無ければ要ブートストラップ（exit 0）。
# ★R2-Critical: root 実行時は隣接 lib の存在だけでなく信頼可能性
# （_mdm_adjacent_lib_is_trusted）も要求する。sticky/共有ディレクトリに
# 単一ファイル配置された場合、攻撃者が隣に lib を植えて次回 root 実行で
# 任意コード実行できるため、信頼できない隣接 lib は**無視**して
# 自己ブートストラップ（pin 済み取得）に切り替える。
# 判定ディレクトリは MDM_SELF_DIR（テスト用オーバーライド）、既定は自身の隣。
mdm_needs_bootstrap() {
  local _dir="${MDM_SELF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
  local _lib="$_dir/lib-mdm-config.sh"
  [[ -f "$_lib" ]] || return 0
  local _euid
  _euid="${MDM_EUID_OVERRIDE:-$(id -u)}"
  if [[ "$_euid" -eq 0 ]] && ! _mdm_adjacent_lib_is_trusted "$_lib"; then
    mdm_log R1 "隣接する lib-mdm-config.sh が信頼できない（symlink/所有者/権限）。無視して自己ブートストラップする: $_lib"
    return 0
  fi
  return 1
}

# ── 自己ブートストラップ launcher 専用ヘルパー（lib 非依存・自己完結）────
# ★CRITICAL 修正（最終レビュー #1）: 旧実装は clone 直後の default branch の
# lib-mdm-config.sh を ref 固定**前**に root で source していた。default branch
# が侵害されると KIT_MDM_GIT_REF の SHA/tag 固定を無視して pin 前のコードが
# root 実行される。launcher は取得物のコードを一切 source せず、以下の
# 自己完結ヘルパーだけで ref 検証 → 解決 → checkout → HEAD 照合を行い、
# 固定後の実体のみを子プロセスとして実行する。
# （lib-mdm-config.sh と一部ロジックが重複するのは、この信頼境界を成立させる
# ための意図的な複製。変更時は両方を更新すること。）

# git ref 形式検証（lib の mdm_validate_gitref と同一契約の複製）。
_mdm_boot_validate_gitref() {
  local _ref="$1"
  [[ -z "$_ref" ]] && return 1
  if printf '%s' "$_ref" | grep -qE '^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$'; then
    return 0
  fi
  /usr/bin/git check-ref-format --branch "$_ref" >/dev/null 2>&1
}

# mode 文字列の group/other 書込ビット検査（lib の _mdm_mode_is_safe と同一契約の複製）。
_mdm_boot_mode_is_safe() {
  local _mode="$1"
  [[ -z "$_mode" ]] && return 1
  while [[ ${#_mode} -gt 3 ]]; do _mode="${_mode#?}"; done
  case "$_mode" in
    *[2367])  return 1 ;;
  esac
  case "$_mode" in
    ?[2367]?) return 1 ;;
  esac
  return 0
}

# 管理設定ファイルの安全性検証（lib の mdm_config_file_is_secure と同一契約の複製。
# 親ディレクトリの検証を含む — 書込可能な親では他者が差し替えを植えられる）。
_mdm_boot_config_file_is_secure() {
  local _f="$1"
  [[ -e "$_f" ]] || return 1
  [[ -L "$_f" ]] && return 1
  local _mode _dir _dmode
  _mode="$(stat -f '%Lp' "$_f" 2>/dev/null || stat -c '%a' "$_f" 2>/dev/null || echo '')"
  _mdm_boot_mode_is_safe "$_mode" || return 1
  _dir="$(dirname "$_f")"
  _dmode="$(stat -f '%Lp' "$_dir" 2>/dev/null || stat -c '%a' "$_dir" 2>/dev/null || echo '')"
  _mdm_boot_mode_is_safe "$_dmode" || return 1
  if [[ "${MDM_CONFIG_SKIP_OWNER_CHECK:-0}" != "1" ]]; then
    local _owner _downer
    _owner="$(stat -f '%Su' "$_f" 2>/dev/null || stat -c '%U' "$_f" 2>/dev/null || echo '')"
    [[ "$_owner" == "root" ]] || return 1
    _downer="$(stat -f '%Su' "$_dir" 2>/dev/null || stat -c '%U' "$_dir" 2>/dev/null || echo '')"
    [[ "$_downer" == "root" ]] || return 1
  fi
  return 0
}

# 管理設定ファイルから KIT_MDM_GIT_REF のみを安全に読む（単一ファイル配布時、
# 設定ファイルの ref 固定を launcher にも効かせるため）。
# ファイル無し: 空出力 + exit 0 / 不安全: exit 50 / 値は最初の一致行（parser と同じ優先）。
_mdm_boot_config_git_ref() {
  local _f="$1" _line _v
  [[ -f "$_f" ]] || return 0
  _mdm_boot_config_file_is_secure "$_f" || return "$MDM_EXIT_CONFIG"
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    case "$_line" in
      KIT_MDM_GIT_REF=*)
        _v="${_line#KIT_MDM_GIT_REF=}"
        _v="${_v%\"}"; _v="${_v#\"}"
        printf '%s' "$_v"
        return 0 ;;
    esac
  done < "$_f"
  return 0
}

# ref を確定 SHA に解決（lib の mdm_resolve_ref_sha と同一手順の複製。
# 形式検証は呼び出し側で実施済みの前提）。
_mdm_boot_resolve_sha() {
  local _repo="$1" _ref="$2" _sha=""
  if printf '%s' "$_ref" | grep -qE '^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$'; then
    _sha="$(/usr/bin/git -C "$_repo" rev-parse --verify "${_ref}^{commit}" 2>/dev/null || true)"
  else
    if /usr/bin/git -C "$_repo" fetch --quiet origin "$_ref" 2>/dev/null; then
      _sha="$(/usr/bin/git -C "$_repo" rev-parse --verify "FETCH_HEAD^{commit}" 2>/dev/null || true)"
    else
      _sha="$(/usr/bin/git -C "$_repo" rev-parse --verify "${_ref}^{commit}" 2>/dev/null || true)"
    fi
  fi
  [[ -z "$_sha" ]] && return 1
  printf '%s' "$_sha"
  return 0
}

# 単一ファイル配布時の自己ブートストラップ launcher（spec §3.1・§5.1 U1a）。
# lib-mdm-config.sh が隣に無い状態で起動された場合、KIT_MDM_GIT_REF 固定で
# 一時ディレクトリへ mdm/ を含むリポジトリを取得し、取得実体の install-mdm.sh
# を子プロセスとして実行して結果を引き継ぐ。
# ref の優先順位は §7.1 と同じ: CLI 引数（KEY=VALUE 形式）> 環境変数 > 管理設定ファイル > main。
_mdm_bootstrap_and_reexec() {
  local _ref="" _arg
  for _arg in "$@"; do
    case "$_arg" in
      KIT_MDM_GIT_REF=*) _ref="${_arg#KIT_MDM_GIT_REF=}" ;;
    esac
  done
  [[ -z "$_ref" ]] && _ref="${KIT_MDM_GIT_REF:-}"
  if [[ -z "$_ref" ]]; then
    local _cfg_rc=0
    _ref="$(_mdm_boot_config_git_ref "$(_mdm_config_path)")" || _cfg_rc=$?
    if [[ $_cfg_rc -ne 0 ]]; then
      mdm_log U1a "管理設定ファイルの安全性検証に失敗（launcher）"
      return "$MDM_EXIT_CONFIG"
    fi
  fi
  [[ -z "$_ref" ]] && _ref="main"
  if ! _mdm_boot_validate_gitref "$_ref"; then
    mdm_log U1a "不正な git ref 形式: $_ref"
    return "$MDM_EXIT_CONFIG"
  fi

  local _bootstrap_dir
  _bootstrap_dir="$(mktemp -d "${TMPDIR:-/tmp}/mdm-bootstrap.XXXXXX" 2>/dev/null)" || {
    mdm_log U1a "bootstrap 一時ディレクトリの作成に失敗"
    return "$MDM_EXIT_SETUP"
  }

  local _repo_url="${MDM_KIT_REPO_URL_OVERRIDE:-$_MDM_KIT_REPO_URL}"
  mdm_log U1a "mdm/ 一式を取得中 (ref=$_ref)"
  if ! /usr/bin/git clone --quiet "$_repo_url" "$_bootstrap_dir" 2>/dev/null; then
    mdm_log U1a "リポジトリの取得に失敗: $_repo_url"
    rm -rf "$_bootstrap_dir"
    return "$MDM_EXIT_SETUP"
  fi

  local _sha
  if ! _sha="$(_mdm_boot_resolve_sha "$_bootstrap_dir" "$_ref")" || [[ -z "$_sha" ]]; then
    mdm_log U1a "ref を解決できない: $_ref"
    rm -rf "$_bootstrap_dir"
    return "$MDM_EXIT_SETUP"
  fi
  if ! /usr/bin/git -C "$_bootstrap_dir" checkout --quiet --detach "$_sha" 2>/dev/null; then
    mdm_log U1a "checkout に失敗: $_sha"
    rm -rf "$_bootstrap_dir"
    return "$MDM_EXIT_SETUP"
  fi
  local _head_sha
  _head_sha="$(/usr/bin/git -C "$_bootstrap_dir" rev-parse --verify HEAD 2>/dev/null || true)"
  if [[ -z "$_head_sha" || "$_head_sha" != "$_sha" ]]; then
    mdm_log U1a "checkout 後の HEAD が解決 SHA と不一致: $_head_sha != $_sha"
    rm -rf "$_bootstrap_dir"
    return "$MDM_EXIT_SETUP"
  fi
  if [[ ! -f "$_bootstrap_dir/mdm/install-mdm.sh" || ! -f "$_bootstrap_dir/mdm/lib-mdm-config.sh" ]]; then
    mdm_log U1a "取得した mdm/ 一式が不完全 (ref=$_ref sha=$_sha)"
    rm -rf "$_bootstrap_dir"
    return "$MDM_EXIT_SETUP"
  fi

  mdm_log U1a "取得実体から再実行: $_bootstrap_dir/mdm/install-mdm.sh (sha=$_sha)"
  local _exec_rc=0
  /bin/bash "$_bootstrap_dir/mdm/install-mdm.sh" "$@" || _exec_rc=$?
  rm -rf "$_bootstrap_dir"
  return "$_exec_rc"
}

# レシート出力先ディレクトリを決定（root: システム領域 / それ以外: 対象ユーザー領域）。
# id -u 直呼びは非root環境では常に else 分岐になり単体テストできないため
# MDM_EUID_OVERRIDE でモック可能にする。
_mdm_receipt_dir_for() {
  local _home="$1" _euid
  _euid="${MDM_EUID_OVERRIDE:-$(id -u)}"
  if [[ "$_euid" -eq 0 ]]; then
    printf '%s' "/Library/Application Support/ClaudeCodeStarterKit"
  else
    printf '%s' "$_home/Library/Application Support/ClaudeCodeStarterKit"
  fi
}

# R4: レシート書き出し + 終了コード確定 + ログクローズ（spec §8.3）。
# 失敗保証は best-effort: 主経路が書けなければ root 領域の _unresolved へ
# フォールバックし、それも書けなければログ+終了コードのみを唯一のシグナルとする。
_mdm_finish() {
  local _user="$1" _home="$2" _result="$3" _code="$4"
  MDM_RCPT_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  MDM_RCPT_LOG_PATH="$MDM_LOG_FILE"
  MDM_RCPT_PROFILE="${PROFILE:-standard}"
  local _rcpt_dir; _rcpt_dir="$(_mdm_receipt_dir_for "$_home")"
  mdm_receipt_write "$_rcpt_dir/receipt-$_user.json" "$_result" "$_code" || \
    mdm_receipt_write "/Library/Application Support/ClaudeCodeStarterKit/receipt-_unresolved.json" "$_result" "$_code" 2>/dev/null || true
  mdm_log R4 "完了: result=$_result exit=$_code"
  exit "$_code"
}

# 設定・ユーザー解決失敗時の best-effort レシート（spec §8.3(a)・Medium 対応）。
# 対象ユーザーが未確定のため root 領域の receipt-_unresolved.json へ書く。
# 非 root 等で書けなければレシートは諦め、ログ + 終了コードのみを
# シグナルとする（無条件の「必ず receipt」保証はしない契約）。
_mdm_fail_unresolved() {
  local _code="$1"
  MDM_RCPT_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  MDM_RCPT_LOG_PATH="$MDM_LOG_FILE"
  MDM_RCPT_PROFILE="${PROFILE:-standard}"
  local _dir="${MDM_UNRESOLVED_RCPT_DIR_OVERRIDE:-/Library/Application Support/ClaudeCodeStarterKit}"
  mdm_receipt_write "$_dir/receipt-_unresolved.json" failure "$_code" 2>/dev/null || true
  mdm_log R4 "完了: result=failure exit=$_code (unresolved)"
  exit "$_code"
}

# MDM_DROP_ARGV（mdm_build_drop_argv が直接構築）を環境分離降格で実行する
# 共通ヘルパー（spec §5.3）。launchctl/sudo/env は絶対パス固定（最終レビュー High#4）。
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
  /bin/launchctl asuser "$_uid" /usr/bin/sudo -u "$_user" -H "${MDM_DROP_ARGV[@]}"
}

# ── git 実行ディスパッチャ（最終レビュー Critical#2）──────────
# ★root が対象ユーザー所有の git repo を直接操作すると、ユーザーが仕込んだ
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

# CLT の存在確認（テスト時は MDM_CLT_PRESENT_OVERRIDE でモック可能）。
_mdm_clt_present() {
  if [[ -n "${MDM_CLT_PRESENT_OVERRIDE:-}" ]]; then
    [[ "$MDM_CLT_PRESENT_OVERRIDE" == "1" ]]; return
  fi
  [[ -d /Library/Developer/CommandLineTools/usr/bin ]] || xcode-select -p >/dev/null 2>&1
}

# Xcode Command Line Tools の導入確認（spec §5.2）。root 実行前提。
# 既定では不在時に MDM baseline での pkg 事前配布を要求して失敗を返す。
# KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=true のときのみ、Apple 公式手順として
# 文書化されていない softwareupdate 経由の導入をベストエフォートで試みる。
_mdm_ensure_clt() {
  if _mdm_clt_present; then
    return 0
  fi
  if [[ "$(mdm_validate_bool "${KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE:-false}" 2>/dev/null || echo false)" != "true" ]]; then
    mdm_log R3 "Xcode Command Line Tools が未導入。MDM baseline での pkg 事前配布が必要（KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=true で非公式フォールバックを許可可能）"
    return 1
  fi
  mdm_log R3 "非公式フォールバック: softwareupdate 経由で CLT 導入を試みる（Apple 公式手順として文書化されていない・spec §5.2）"
  local _marker="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
  touch "$_marker" 2>/dev/null || true
  local _label
  _label="$(softwareupdate -l 2>/dev/null | grep -E '\*.*Command Line Tools' | tail -n1 | sed -E 's/^[^*]*\*[[:space:]]*//' || true)"
  if [[ -n "$_label" ]]; then
    softwareupdate -i "$_label" --verbose >/dev/null 2>&1 || true
  else
    mdm_log R3 "softwareupdate に CLT の候補が見つからない"
  fi
  rm -f "$_marker" 2>/dev/null || true
  if _mdm_clt_present; then
    mdm_log R3 "CLT 導入を確認"
    return 0
  fi
  mdm_log R3 "CLT の非公式導入に失敗"
  return 1
}

# GitHub API から Homebrew 公式 pkg（アセット名 Homebrew.pkg / 旧 Homebrew-<version>.pkg）
# の browser_download_url を解決する（spec §5.2 第一選択の一部）。
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
  # 作成後の実体検証（symlink でない・通常ファイル・自分所有・mode 600）
  if [[ -L "$_plist" || ! -f "$_plist" ]]; then
    mdm_log R3 "作成した plist の実体が不正: $_plist"
    return 1
  fi
  local _owner _mode
  _owner="$(stat -f '%u' "$_plist" 2>/dev/null || stat -c '%u' "$_plist" 2>/dev/null || echo '')"
  _mode="$(stat -f '%Lp' "$_plist" 2>/dev/null || stat -c '%a' "$_plist" 2>/dev/null || echo '')"
  if [[ "$_owner" != "$(id -u)" || "$_mode" != "600" ]]; then
    mdm_log R3 "作成した plist の所有者/mode が不正: owner=$_owner mode=$_mode"
    rm -f "$_plist" 2>/dev/null || true
    return 1
  fi
  return 0
}

# Homebrew の導入（spec §5.2）。公式 .pkg + HOMEBREW_PKG_USER 方式
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
  _mdm_brew_present && return 0

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
  _pkg="$(mktemp "${TMPDIR:-/tmp}/mdm-homebrew-pkg.XXXXXX" 2>/dev/null)" || {
    mdm_log R3 "Homebrew 導入: 一時 pkg パスの作成に失敗"
    return 1
  }

  mdm_log R3 "Homebrew pkg をダウンロード中: $_pkg_url"
  if ! curl -fsSL -o "$_pkg" "$_pkg_url" 2>/dev/null; then
    mdm_log R3 "Homebrew pkg のダウンロードに失敗: $_pkg_url"
    rm -f "$_pkg" 2>/dev/null || true
    return 1
  fi

  # 署名検証: exit code + 証明書チェーンの Developer ID Installer を Homebrew の
  # Team ID (927JGANW46) に pin して確認してから installer にかける（High#7）。
  local _sig_out _sig_rc=0
  _sig_out="$(pkgutil --check-signature "$_pkg" 2>&1)" || _sig_rc=$?
  if [[ $_sig_rc -ne 0 ]] || ! _mdm_check_brew_signature_output "$_sig_out"; then
    mdm_log R3 "Homebrew pkg の署名検証に失敗（Team ID ${_MDM_BREW_TEAM_ID} の Developer ID Installer 署名を確認できない）"
    rm -f "$_pkg" 2>/dev/null || true
    return 1
  fi

  # 代替インストールユーザーの指定（install 直前に作成。ファイルと対象
  # ユーザーは install 前に存在必須 — 一次情報の記載どおり）。
  # symlink 追随を排除した排他作成 + root 所有 0600（brew 側の受理条件）
  local _plist_path="${MDM_BREW_PLIST_OVERRIDE:-/var/tmp/.homebrew_pkg_user.plist}"
  if ! _mdm_write_brew_pkg_user_plist "$_user"; then
    mdm_log R3 "Homebrew 導入: $_plist_path の安全な作成に失敗"
    rm -f "$_pkg" 2>/dev/null || true
    return 1
  fi

  mdm_log R3 "Homebrew pkg を導入中 (HOMEBREW_PKG_USER=$_user)"
  local _rc=0
  installer -pkg "$_pkg" -target / >/dev/null 2>&1 || _rc=$?
  rm -f "$_pkg" "$_plist_path" 2>/dev/null || true
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

# R3: 前提ブートストラップ（spec §5.2）。root 実行前提、mdm_prereq_plan が
# "bootstrap" のときのみ呼ばれる。CLT → Homebrew の順（brew の導入自体が
# CLT のコンパイラ/git に依存するため）。
# NOTE: Homebrew は pkg + HOMEBREW_PKG_USER 方式のため対象ユーザーの home は
# 不要（_user のみ渡す）。
# 終了コード契約（spec §8.1・Medium 対応）: CLT 不足=10（前提不足）と
# Homebrew 導入失敗=11 を区別して返す。
_mdm_bootstrap_prereqs() {
  local _user="$1"
  _mdm_ensure_clt || return "$MDM_EXIT_PREREQ"
  _mdm_bootstrap_homebrew "$_user" || return "$MDM_EXIT_BREW"
  return 0
}

# 対象ユーザーの home 配下に claude CLI が存在するか。
# ★root 実行時は root の PATH 上の claude（system-wide の別導入等）を成功
# 扱いにしない — 対象ユーザーへの導入保証にならないため（最終レビュー High#5）。
# PATH フォールバックは非 root（ユーザーモード = 自分自身の PATH）のみ。
_mdm_cli_present_for_home() {
  local _home="$1"
  [[ -x "$_home/.local/bin/claude" ]] && return 0
  local _euid
  _euid="${MDM_EUID_OVERRIDE:-$(id -u)}"
  [[ "$_euid" -eq 0 ]] && return 1
  command -v claude >/dev/null 2>&1
}

# U1b→U2→U3: キット取得+refピン留め → setup.sh --non-interactive 実行 →
# Claude Code CLI 導入確認（spec §5.1・§5.5）。
# ★root 実行時は clone を含む全 git 操作を初回から検証済み対象ユーザーへ
# env -i 降格して行う（Critical#2）。root が対象ユーザー所有 repo を直接
# 操作すると .git/config 経由の root コード実行境界になるため、「root で
# clone してから所有権を対象ユーザーへ再帰変更する」旧方式は廃止
# （ユーザー実行の clone なら所有権は最初から正しい）。
# 戻り値: 0=成功 / MDM_EXIT_CLI=CLIのみ欠如（部分失敗）/
#         MDM_EXIT_CONFIG=install_dir 制約違反 / 1=それ以外の失敗
_mdm_run_user_phase() {
  local _euid="$1" _user="$2" _home="$3"
  local _ref="${KIT_MDM_GIT_REF:-main}"
  local _install_dir="${KIT_MDM_INSTALL_DIR:-}"
  [[ -z "$_install_dir" ]] && _install_dir="$_home/.claude-starter-kit"
  MDM_RCPT_GIT_REF="$_ref"
  MDM_RCPT_INSTALL_DIR="$_install_dir"

  # install_dir は対象ユーザーの canonical home 「配下」に制約する（spec §5.4/§7.4）。
  # home 一致（配下でない）と .. 含み（glob 前方一致をすり抜ける相対脱出）は拒否。
  case "$_install_dir" in
    *..*)
      mdm_log U1b "KIT_MDM_INSTALL_DIR に .. を含む: $_install_dir"
      return "$MDM_EXIT_CONFIG" ;;
    "$_home"/*) : ;;
    *)
      mdm_log U1b "KIT_MDM_INSTALL_DIR が対象ユーザーの home 配下でない: $_install_dir"
      return "$MDM_EXIT_CONFIG" ;;
  esac

  # root 時: 以降の git / ファイル操作を検証済みユーザーへ降格するコンテキストを設定
  local _uid=""
  if [[ "$_euid" -eq 0 ]]; then
    _uid="$(id -u "$_user" 2>/dev/null || true)"
    if [[ -z "$_uid" ]]; then
      mdm_log U1b "対象ユーザーの UID を解決できない"
      return 1
    fi
    _MDM_GIT_DROP_UID="$_uid"
    _MDM_GIT_DROP_USER="$_user"
    _MDM_GIT_DROP_HOME="$_home"
  fi

  # U1b: キット取得 + ref ピン留め（spec §5.5）
  local _repo_url="${MDM_KIT_REPO_URL_OVERRIDE:-$_MDM_KIT_REPO_URL}"
  if [[ ! -d "$_install_dir/.git" ]]; then
    mdm_log U1b "キットを取得中: $_install_dir"
    _mdm_run_maybe_as_user /bin/mkdir -p "$(dirname "$_install_dir")" 2>/dev/null || true
    if ! _mdm_git clone --quiet "$_repo_url" "$_install_dir" 2>/dev/null; then
      mdm_log U1b "clone に失敗: $_install_dir"
      return 1
    fi
  else
    mdm_log U1b "既存のキットを検出（冪等更新）: $_install_dir"
  fi

  local _sha _rc=0
  _sha="$(mdm_resolve_ref_sha "$_install_dir" "$_ref")" || _rc=$?
  if [[ $_rc -ne 0 || -z "$_sha" ]]; then
    mdm_log U1b "ref を解決できない: $_ref"
    return 1
  fi
  if ! _mdm_git -C "$_install_dir" checkout --quiet --detach "$_sha" 2>/dev/null; then
    mdm_log U1b "checkout に失敗: $_sha"
    return 1
  fi
  local _head_sha
  _head_sha="$(_mdm_git -C "$_install_dir" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$_head_sha" != "$_sha" ]]; then
    mdm_log U1b "checkout 後の HEAD が解決 SHA と不一致: $_head_sha != $_sha"
    return 1
  fi
  MDM_RCPT_RESOLVED_SHA="$_sha"
  MDM_RCPT_KIT_VERSION="$(_mdm_git -C "$_install_dir" describe --tags --always 2>/dev/null || echo unknown)"
  _mdm_run_maybe_as_user /bin/chmod +x "$_install_dir/setup.sh" 2>/dev/null || true

  # required_components: kit は常時、claude_cli は KIT_MDM_INSTALL_CLAUDE_CLI!=false のとき（既定 true）
  local _cli_required="true"
  if [[ -n "${KIT_MDM_INSTALL_CLAUDE_CLI:-}" ]]; then
    _cli_required="$(mdm_validate_bool "$KIT_MDM_INSTALL_CLAUDE_CLI" 2>/dev/null || echo true)"
  fi
  if [[ "$_cli_required" == "true" ]]; then
    MDM_RCPT_REQUIRED_COMPONENTS='["kit","claude_cli"]'
  else
    MDM_RCPT_REQUIRED_COMPONENTS='["kit"]'
  fi

  # U2: setup.sh を直接実行（root 時のみ環境分離降格。spec §5.1/§5.3）。
  # 引数は mdm_build_setup_argv がグローバル配列 MDM_SETUP_ARGV へ直接構築する
  # （既存 manifest 検出で --update、KIT_MDM_DRY_RUN=true で --dry-run を付与。
  # 改行シリアライズは行わない）。
  mdm_build_setup_argv "$_home"
  mdm_log U2 "setup.sh を実行: ${MDM_SETUP_ARGV[*]}"
  if [[ "$_euid" -eq 0 ]]; then
    if ! _mdm_exec_as_user "$_uid" "$_user" "$_home" /bin/bash "$_install_dir/setup.sh" "${MDM_SETUP_ARGV[@]}"; then
      mdm_log U2 "setup.sh の実行に失敗"
      return 1
    fi
  else
    if ! /bin/bash "$_install_dir/setup.sh" "${MDM_SETUP_ARGV[@]}"; then
      mdm_log U2 "setup.sh の実行に失敗"
      return 1
    fi
  fi

  # U3: Claude Code CLI 導入の確認（KIT_MDM_INSTALL_CLAUDE_CLI=true のとき。spec §5.1・§11(a)）
  if [[ "$_cli_required" == "true" ]]; then
    mdm_log U3 "Claude Code CLI 導入を確認"
    if ! _mdm_cli_present_for_home "$_home"; then
      mdm_log U3 "Claude Code CLI が見つからない（部分失敗として記録）"
      MDM_RCPT_PARTIAL='["claude_cli"]'
      return "$MDM_EXIT_CLI"
    fi
  fi

  return 0
}

# ログ出力先を決定して MDM_LOG_FILE を設定する（最終レビュー High#3）。
# ★設定確定（mdm_config_apply）と R2 のユーザー/home 解決の**後**に呼ぶこと。
# 旧実装は設定読込前に KIT_MDM_LOG_DIR を参照していたため、管理設定ファイル
# からの指定がログパスに反映されなかった。
# - 既定: root は /Library/Logs/ClaudeCodeStarterKit、
#         ユーザーモードは <home>/Library/Logs/ClaudeCodeStarterKit（spec §8.2）
# - KIT_MDM_LOG_DIR は許可プレフィックス（/Library/Logs または
#   <home>/Library/Logs）配下のみ許可（spec §9.2）。違反は exit 50
_mdm_setup_log_file() {
  local _euid="$1" _home="$2"
  local _default_dir
  if [[ "$_euid" -eq 0 ]]; then
    _default_dir="/Library/Logs/ClaudeCodeStarterKit"
  else
    _default_dir="$_home/Library/Logs/ClaudeCodeStarterKit"
  fi
  local _dir="${KIT_MDM_LOG_DIR:-$_default_dir}"
  # 許可プレフィックスは実行モードで分ける: root は /Library/Logs のみ
  # （ユーザー home 配下を許すと、ユーザーが植えた symlink を root が辿って
  # 任意ファイルへ append する経路になる）。非 root は自分の home 配下のみ。
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
  MDM_LOG_FILE="$_dir/install-$(date -u +%Y%m%d-%H%M%S 2>/dev/null || echo run).log"
  mkdir -p "$_dir" 2>/dev/null || true
  return 0
}

# MDM 配布固有の既定値を適用する（本体 profiles/*.conf の既定と異なる値を
# MDM 配布でだけ上書きする場所）。mdm_config_apply の**後**に呼ぶこと —
# conf/env で既に明示された値（既存 env 値）は変更せず、未設定のキーにのみ
# MDM 既定を適用する（mdm_config_apply と同じ「既存 env 値は上書きしない」
# 優先順位を踏襲）。
#   - ENABLE_GHOSTTY_SETUP: 本体既定は standard/full プロファイルで true だが、
#     MDM 配布では GUI アプリの既定導入を避けるため既定 off とする（spec §5.6）。
#     mdm-config.conf で ENABLE_GHOSTTY_SETUP=true を明示すれば on にできる。
_mdm_apply_mdm_defaults() {
  : "${ENABLE_GHOSTTY_SETUP:=false}"
  export ENABLE_GHOSTTY_SETUP
}

# R1..R4 のオーケストレーション（spec §5.1）。root フェーズは実副作用
# （brew 導入・降格）を伴うため、単体テストでは mdm_needs_bootstrap と各
# フェーズ関数を個別に検証する（実機確認は PR に手順記載）。
mdm_main() {
  # OS ガード
  [[ "$(uname -s)" == "Darwin" ]] || { mdm_log R1 "非対応 OS"; exit "$MDM_EXIT_OS"; }

  # 自己ブートストラップ: lib が隣に無ければ ref 固定で mdm/ を取得し再実行（spec §3.1・U1a）
  if mdm_needs_bootstrap; then
    mdm_log R1 "lib-mdm-config.sh が無いため mdm/ を取得して再実行する"
    local _boot_rc=0
    _mdm_bootstrap_and_reexec "$@" || _boot_rc=$?
    exit "$_boot_rc"
  fi

  # R1: 設定読込（CLI 引数 > env > 管理設定ファイル > 既定。High#3 staging 検証）。
  # ログファイルは設定確定 + R2 の home 解決後に開くため、ここでの失敗は
  # stderr（MDM 側が捕捉）と終了コードのみで報告される。
  #
  # 隣接 lib の source は inode 束縛で行う（R2-Critical）:
  # 事前 inode 記録 → root 時は信頼検証 → open → fd の inode 照合 → fd から
  # source。検証と読込の間の差し替えは inode 不一致で拒否される
  # （mdm_config_apply の fd 読みと同じ手法。/dev/fd の mode/デバイス番号は
  # macOS で信頼できないため inode のみ照合）。
  local _lib_path _lib_euid _lib_pre_ino _lib_fd_ino
  _lib_path="${MDM_SELF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}/lib-mdm-config.sh"
  _lib_pre_ino="$(stat -f '%i' "$_lib_path" 2>/dev/null || stat -c '%i' "$_lib_path" 2>/dev/null || echo 'pre-fail')"
  _lib_euid="${MDM_EUID_OVERRIDE:-$(id -u)}"
  if [[ "$_lib_euid" -eq 0 ]] && ! _mdm_adjacent_lib_is_trusted "$_lib_path"; then
    mdm_log R1 "隣接 lib が信頼できない（source 直前の再検証）"
    exit "$MDM_EXIT_CONFIG"
  fi
  exec 9<"$_lib_path" || { mdm_log R1 "lib-mdm-config.sh を開けない: $_lib_path"; exit "$MDM_EXIT_CONFIG"; }
  _lib_fd_ino="$(stat -Lf '%i' /dev/fd/9 2>/dev/null || stat -Lc '%i' /dev/fd/9 2>/dev/null || echo 'fd-fail')"
  if [[ "$_lib_pre_ino" != "$_lib_fd_ino" ]]; then
    exec 9<&-
    mdm_log R1 "lib-mdm-config.sh が検査と読込の間に差し替えられた（TOCTOU）"
    exit "$MDM_EXIT_CONFIG"
  fi
  # shellcheck source=mdm/lib-mdm-config.sh
  source /dev/fd/9
  exec 9<&-
  mdm_config_apply "$(_mdm_config_path)" "$@" || { mdm_log R1 "設定エラー"; _mdm_fail_unresolved "$MDM_EXIT_CONFIG"; }
  _mdm_apply_mdm_defaults

  # R2: ユーザー・home 解決（失敗時も best-effort で _unresolved レシートを試す）
  local _euid; _euid="$(id -u)"
  local _user _home
  if [[ "$_euid" -eq 0 ]]; then
    _user="$(mdm_resolve_target_user)" || _mdm_fail_unresolved "$MDM_EXIT_USER"
    _home="$(mdm_validate_user_home "$_user")" || _mdm_fail_unresolved "$MDM_EXIT_USER"
  else
    _user="$(id -un)"; _home="$HOME"     # ユーザーモード
  fi
  MDM_RCPT_TARGET_USER="$_user"

  # ログ開始（設定確定後 = KIT_MDM_LOG_DIR が管理設定/CLI からも効く。High#3）
  _mdm_setup_log_file "$_euid" "$_home" || _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_CONFIG"

  # R3: 前提ブートストラップ（root 時のみ）。CLT 不足=10 / brew 失敗=11 を
  # _mdm_bootstrap_prereqs の戻り値のままレシートへ反映する（spec §8.1）
  if [[ "$_euid" -eq 0 ]]; then
    local _prereq_rc=0
    case "$(mdm_prereq_plan)" in
      fail) mdm_log R3 "前提不足かつ導入無効"; _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_PREREQ" ;;
      bootstrap)
        _mdm_bootstrap_prereqs "$_user" || _prereq_rc=$?
        if [[ "$_prereq_rc" -ne 0 ]]; then
          _mdm_finish "$_user" "$_home" failure "$_prereq_rc"
        fi ;;
    esac
  fi

  # U1b..U3: キット取得(ref 固定) + setup 実行 + CLI 導入の確認。
  # root 時は git 操作・setup.sh 実行とも検証済みユーザーへ環境分離降格（Critical#2）。
  local _user_rc=0
  _mdm_run_user_phase "$_euid" "$_user" "$_home" || _user_rc=$?
  if [[ "$_user_rc" -eq "$MDM_EXIT_CLI" ]]; then
    # キット配備自体は成功したが必須 CLI が欠如（spec §10: 部分失敗として報告）
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_CLI"
  elif [[ "$_user_rc" -eq "$MDM_EXIT_CONFIG" ]]; then
    # install_dir 制約違反等の設定エラーは 30 に潰さず 50 を維持（spec §8.1）
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_CONFIG"
  elif [[ "$_user_rc" -ne 0 ]]; then
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
