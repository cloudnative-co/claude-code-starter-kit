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
_MDM_KIT_REPO_URL="https://github.com/cloudnative-co/claude-code-starter-kit.git"

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
  if printf '%s' "$_ref" | grep -qE '^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$'; then
    _sha="$(git -C "$_repo" rev-parse --verify "${_ref}^{commit}" 2>/dev/null || true)"
  else
    # 明示 fetch → FETCH_HEAD の commit を真実とする（ローカル ref を更新しないことがあるため）
    if ! git -C "$_repo" fetch --quiet origin "$_ref" 2>/dev/null; then
      # origin が無い（初回 clone 前のローカルテスト）場合はローカル ref 解決にフォールバック
      _sha="$(git -C "$_repo" rev-parse --verify "${_ref}^{commit}" 2>/dev/null || true)"
    else
      _sha="$(git -C "$_repo" rev-parse --verify "FETCH_HEAD^{commit}" 2>/dev/null || true)"
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

# 対象ユーザーへ降格するための argv を構築（env -i で root 環境を継承しない）。
# 実行は _mdm_exec_as_user（後述）。ここでは組み立てのみ（テスト可能に stdout へ改行区切りで出力）。
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

mdm_build_drop_argv() {
  local _uid="$1" _user="$2" _home="$3"; shift 3
  local _brewbin=""
  [[ -x /opt/homebrew/bin/brew ]] && _brewbin="/opt/homebrew/bin:"
  [[ -x /usr/local/bin/brew ]] && _brewbin="${_brewbin}/usr/local/bin:"
  {
    printf '%s\n' 'env'
    printf '%s\n' '-i'
    printf '%s\n' "HOME=$_home"
    printf '%s\n' "USER=$_user"
    printf '%s\n' "LOGNAME=$_user"
    printf '%s\n' "PATH=${_brewbin}/usr/bin:/bin:/usr/sbin:/sbin"
    [[ -n "${LANGUAGE:-}" ]] && printf '%s\n' "LANG=$(_mdm_lang_to_locale "$LANGUAGE")" || true
    local _k
    for _k in $_MDM_PASSTHROUGH_KEYS; do
      if [[ -n "${!_k:-}" ]]; then
        printf '%s\n' "$_k=${!_k}"
      fi
    done
    # 実行するスクリプトと引数
    printf '%s\n' /bin/bash
    local _a
    for _a in "$@"; do printf '%s\n' "$_a"; done
  }
}

# setup.sh へ渡す引数を組み立てる（KIT_MDM_DRY_RUN=true のとき --dry-run を
# 追加。spec §7.3: KIT_MDM_DRY_RUN は本体の --dry-run へ伝搬する契約）。
# stdout へ改行区切りで出力し、呼び出し側で配列化する（mdm_build_drop_argv
# と同じ形式・_mdm_exec_as_user 経由の呼び出しにもそのまま渡せる）。
mdm_build_setup_argv() {
  printf '%s\n' '--non-interactive'
  if [[ "$(mdm_validate_bool "${KIT_MDM_DRY_RUN:-false}" 2>/dev/null || echo false)" == "true" ]]; then
    printf '%s\n' '--dry-run'
  fi
}

# ── 自己ブートストラップ判定（spec §3.1・§5.1 U1a）─────────
# 隣接する lib-mdm-config.sh が無ければ要ブートストラップ（exit 0）。
# 判定ディレクトリは MDM_SELF_DIR（テスト用オーバーライド）、既定は自身の隣。
mdm_needs_bootstrap() {
  local _dir="${MDM_SELF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
  [[ -f "$_dir/lib-mdm-config.sh" ]] && return 1
  return 0
}

# 単一ファイル配布時の自己ブートストラップ launcher（spec §3.1・§5.1 U1a）。
# lib-mdm-config.sh が隣に無い状態で起動された場合、KIT_MDM_GIT_REF 固定で
# 一時ディレクトリへ mdm/ を含むリポジトリを取得し、取得実体の install-mdm.sh
# を子プロセスとして実行して結果を引き継ぐ。
#
# NOTE: ref 解決 (mdm_resolve_ref_sha) は lib-mdm-config.sh の mdm_validate_gitref
# に依存するが、このパスに入る時点では隣接 lib が無い（＝まだ source されていない）。
# git clone 直後はデフォルトブランチの working tree が展開されており、そこに
# 含まれる mdm/lib-mdm-config.sh を「一時的に」source することで mdm_resolve_ref_sha
# を使えるようにする。対象 ref 固有の実装差異は無視できるほど小さい前提（実際の
# インストールは再実行後、対象 ref で checkout された install-mdm.sh が担う）。
_mdm_bootstrap_and_reexec() {
  local _ref="${KIT_MDM_GIT_REF:-main}"
  local _bootstrap_dir
  _bootstrap_dir="$(mktemp -d "${TMPDIR:-/tmp}/mdm-bootstrap.XXXXXX" 2>/dev/null)" || {
    mdm_log U1a "bootstrap 一時ディレクトリの作成に失敗"
    return "$MDM_EXIT_SETUP"
  }

  mdm_log U1a "mdm/ 一式を取得中 (ref=$_ref)"
  if ! git clone --quiet "$_MDM_KIT_REPO_URL" "$_bootstrap_dir" 2>/dev/null; then
    mdm_log U1a "リポジトリの取得に失敗: $_MDM_KIT_REPO_URL"
    rm -rf "$_bootstrap_dir"
    return "$MDM_EXIT_SETUP"
  fi
  if [[ ! -f "$_bootstrap_dir/mdm/lib-mdm-config.sh" ]]; then
    mdm_log U1a "取得したリポジトリに mdm/lib-mdm-config.sh が無い"
    rm -rf "$_bootstrap_dir"
    return "$MDM_EXIT_SETUP"
  fi
  # shellcheck source=mdm/lib-mdm-config.sh
  source "$_bootstrap_dir/mdm/lib-mdm-config.sh"

  local _sha _rc=0
  _sha="$(mdm_resolve_ref_sha "$_bootstrap_dir" "$_ref")" || _rc=$?
  if [[ $_rc -ne 0 || -z "$_sha" ]]; then
    [[ "$_rc" -eq 0 ]] && _rc="$MDM_EXIT_SETUP"
    mdm_log U1a "ref を解決できない: $_ref"
    rm -rf "$_bootstrap_dir"
    return "$_rc"
  fi
  if ! git -C "$_bootstrap_dir" checkout --quiet --detach "$_sha" 2>/dev/null; then
    mdm_log U1a "checkout に失敗: $_sha"
    rm -rf "$_bootstrap_dir"
    return "$MDM_EXIT_SETUP"
  fi
  local _head_sha
  _head_sha="$(git -C "$_bootstrap_dir" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$_head_sha" != "$_sha" ]]; then
    mdm_log U1a "checkout 後の HEAD が解決 SHA と不一致: $_head_sha != $_sha"
    rm -rf "$_bootstrap_dir"
    return "$MDM_EXIT_SETUP"
  fi
  if [[ ! -f "$_bootstrap_dir/mdm/install-mdm.sh" || ! -f "$_bootstrap_dir/mdm/lib-mdm-config.sh" ]]; then
    mdm_log U1a "取得した mdm/ 一式が不完全 (ref=$_ref sha=$_sha)"
    rm -rf "$_bootstrap_dir"
    return "$MDM_EXIT_SETUP"
  fi

  mdm_log U1a "取得実体から再実行: $_bootstrap_dir/mdm/install-mdm.sh"
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

# mdm_build_drop_argv の出力（改行区切り argv）を配列化し、環境分離降格で
# 実行する共通ヘルパー（spec §5.3）。
#   launchctl asuser <uid> sudo -u <user> -H <mdm_build_drop_argv の出力>
_mdm_exec_as_user() {
  local _uid="$1" _user="$2" _home="$3"; shift 3
  local -a _argv=()
  local _line
  while IFS= read -r _line; do _argv+=("$_line"); done < <(mdm_build_drop_argv "$_uid" "$_user" "$_home" "$@")
  launchctl asuser "$_uid" sudo -u "$_user" -H "${_argv[@]}"
}

# Xcode Command Line Tools の導入確認（spec §5.2）。root 実行前提。
# 既定では不在時に MDM baseline での pkg 事前配布を要求して失敗を返す。
# KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=true のときのみ、Apple 公式手順として
# 文書化されていない softwareupdate 経由の導入をベストエフォートで試みる。
_mdm_ensure_clt() {
  if [[ -d /Library/Developer/CommandLineTools/usr/bin ]] || xcode-select -p >/dev/null 2>&1; then
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
  if [[ -d /Library/Developer/CommandLineTools/usr/bin ]] || xcode-select -p >/dev/null 2>&1; then
    mdm_log R3 "CLT 導入を確認"
    return 0
  fi
  mdm_log R3 "CLT の非公式導入に失敗"
  return 1
}

# GitHub API から Homebrew 公式 pkg（アセット名 Homebrew-<version>.pkg）の
# browser_download_url を解決する（spec §5.2 第一選択の一部）。
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
  printf '%s' "$_url"
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
#   1. GitHub API から pkg の browser_download_url を解決（_mdm_resolve_brew_pkg_url）
#   2. 代替インストールユーザーを /var/tmp/.homebrew_pkg_user.plist に書く
#      （`defaults write /var/tmp/.homebrew_pkg_user HOMEBREW_PKG_USER <user>`。
#      ファイルと対象ユーザーは install 前に存在必須 — 対象ユーザーは R2 で検証済み）
#   3. pkg をダウンロードし pkgutil --check-signature で Developer ID 署名を確認
#      （検証失敗時は導入せず終了 — 呼び出し元経由で exit 11 = MDM_EXIT_BREW）
#   4. installer -pkg <pkg> -target / で導入（root 実行）
#   5. 一時ファイル（pkg・plist）をクリーンアップし、brew バイナリの存在で成否判定
#
# curl|bash 経路は撤去済み（パスワードなし sudo が無い環境での非対話ハング
# リスクを避けるため）。pkg 方式が不可能な場合は暗黙フォールバックせず失敗を返す。
_mdm_bootstrap_homebrew() {
  local _user="$1"
  [[ -x /opt/homebrew/bin/brew || -x /usr/local/bin/brew ]] && return 0

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

  # 署名検証: exit code に加えて証明書チェーンに "Developer ID Installer" が
  # 含まれることを確認してから installer にかける（spec 要求）。
  local _sig_out _sig_rc=0
  _sig_out="$(pkgutil --check-signature "$_pkg" 2>&1)" || _sig_rc=$?
  if [[ $_sig_rc -ne 0 ]] || ! printf '%s' "$_sig_out" | grep -q 'Developer ID Installer'; then
    mdm_log R3 "Homebrew pkg の署名検証に失敗（Developer ID 署名を確認できない）"
    rm -f "$_pkg" 2>/dev/null || true
    return 1
  fi

  # 代替インストールユーザーの指定（install 直前に作成。ファイルと対象
  # ユーザーは install 前に存在必須 — 一次情報の記載どおり）
  if ! defaults write /var/tmp/.homebrew_pkg_user HOMEBREW_PKG_USER "$_user" 2>/dev/null; then
    mdm_log R3 "Homebrew 導入: /var/tmp/.homebrew_pkg_user.plist の作成に失敗"
    rm -f "$_pkg" 2>/dev/null || true
    return 1
  fi

  mdm_log R3 "Homebrew pkg を導入中 (HOMEBREW_PKG_USER=$_user)"
  local _rc=0
  installer -pkg "$_pkg" -target / >/dev/null 2>&1 || _rc=$?
  rm -f "$_pkg" /var/tmp/.homebrew_pkg_user.plist 2>/dev/null || true
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
_mdm_bootstrap_prereqs() {
  local _user="$1"
  _mdm_ensure_clt || return 1
  _mdm_bootstrap_homebrew "$_user" || return 1
  return 0
}

# 対象ユーザーの home 配下（または PATH）に claude CLI が存在するか。
_mdm_cli_present_for_home() {
  local _home="$1"
  [[ -x "$_home/.local/bin/claude" ]] && return 0
  command -v claude >/dev/null 2>&1
}

# U1b→U2→U3: キット取得+refピン留め → setup.sh --non-interactive 実行 →
# Claude Code CLI 導入確認（spec §5.1・§5.5）。
# root 実行時は setup.sh の実行のみ環境分離降格し、clone/checkout はここで
# 直接行った上で対象ユーザーへ chown する。
# 戻り値: 0=成功 / MDM_EXIT_CLI=CLIのみ欠如（部分失敗） / 1=それ以外の失敗
_mdm_run_user_phase() {
  local _euid="$1" _user="$2" _home="$3"
  local _ref="${KIT_MDM_GIT_REF:-main}"
  local _install_dir="${KIT_MDM_INSTALL_DIR:-}"
  [[ -z "$_install_dir" ]] && _install_dir="$_home/.claude-starter-kit"
  MDM_RCPT_GIT_REF="$_ref"
  MDM_RCPT_INSTALL_DIR="$_install_dir"

  # U1b: キット取得 + ref ピン留め（spec §5.5）
  if [[ ! -d "$_install_dir/.git" ]]; then
    mdm_log U1b "キットを取得中: $_install_dir"
    mkdir -p "$(dirname "$_install_dir")" 2>/dev/null || true
    if ! git clone --quiet "$_MDM_KIT_REPO_URL" "$_install_dir" 2>/dev/null; then
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
  if ! git -C "$_install_dir" checkout --quiet --detach "$_sha" 2>/dev/null; then
    mdm_log U1b "checkout に失敗: $_sha"
    return 1
  fi
  local _head_sha
  _head_sha="$(git -C "$_install_dir" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$_head_sha" != "$_sha" ]]; then
    mdm_log U1b "checkout 後の HEAD が解決 SHA と不一致: $_head_sha != $_sha"
    return 1
  fi
  MDM_RCPT_RESOLVED_SHA="$_sha"
  MDM_RCPT_KIT_VERSION="$(git -C "$_install_dir" describe --tags --always 2>/dev/null || echo unknown)"
  chmod +x "$_install_dir/setup.sh" 2>/dev/null || true

  if [[ "$_euid" -eq 0 ]]; then
    chown -R "$_user" "$_install_dir" 2>/dev/null || mdm_log U1b "chown 失敗（続行）: $_install_dir"
  fi

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
  # 引数は mdm_build_setup_argv で組み立てる（KIT_MDM_DRY_RUN=true なら --dry-run も付与）。
  local -a _setup_argv=()
  local _sa_line
  while IFS= read -r _sa_line; do _setup_argv+=("$_sa_line"); done < <(mdm_build_setup_argv)
  mdm_log U2 "setup.sh を実行: ${_setup_argv[*]}"
  if [[ "$_euid" -eq 0 ]]; then
    local _uid
    _uid="$(id -u "$_user" 2>/dev/null || true)"
    if [[ -z "$_uid" ]]; then
      mdm_log U2 "対象ユーザーの UID を解決できない"
      return 1
    fi
    if ! _mdm_exec_as_user "$_uid" "$_user" "$_home" "$_install_dir/setup.sh" "${_setup_argv[@]}"; then
      mdm_log U2 "setup.sh の実行に失敗"
      return 1
    fi
  else
    if ! /bin/bash "$_install_dir/setup.sh" "${_setup_argv[@]}"; then
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

  # R1: 設定読込
  # shellcheck source=mdm/lib-mdm-config.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib-mdm-config.sh"
  MDM_LOG_FILE="${KIT_MDM_LOG_DIR:-/Library/Logs/ClaudeCodeStarterKit}/install-$(date -u +%Y%m%d-%H%M%S 2>/dev/null || echo run).log"
  mkdir -p "$(dirname "$MDM_LOG_FILE")" 2>/dev/null || true
  local _conf="/Library/Application Support/ClaudeCodeStarterKit/mdm-config.conf"
  mdm_config_apply "$_conf" || { mdm_log R1 "設定エラー"; exit "$MDM_EXIT_CONFIG"; }
  _mdm_apply_mdm_defaults

  # R2: ユーザー・home 解決
  local _euid; _euid="$(id -u)"
  local _user _home
  if [[ "$_euid" -eq 0 ]]; then
    _user="$(mdm_resolve_target_user)" || exit "$MDM_EXIT_USER"
    _home="$(mdm_validate_user_home "$_user")" || exit "$MDM_EXIT_USER"
  else
    _user="$(id -un)"; _home="$HOME"     # ユーザーモード
  fi
  MDM_RCPT_TARGET_USER="$_user"

  # R3: 前提ブートストラップ（root 時のみ）
  if [[ "$_euid" -eq 0 ]]; then
    case "$(mdm_prereq_plan)" in
      fail) mdm_log R3 "前提不足かつ導入無効"; _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_PREREQ" ;;
      bootstrap) _mdm_bootstrap_prereqs "$_user" || _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_BREW" ;;
    esac
  fi

  # U1b..U3: キット取得(ref 固定) + setup 実行 + CLI 導入の確認。root 時は setup.sh 実行のみ降格。
  local _user_rc=0
  _mdm_run_user_phase "$_euid" "$_user" "$_home" || _user_rc=$?
  if [[ "$_user_rc" -eq "$MDM_EXIT_CLI" ]]; then
    # キット配備自体は成功したが必須 CLI が欠如（spec §10: 部分失敗として報告）
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_CLI"
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
