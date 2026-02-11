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

_json_file_count() {
  # Usage: _json_file_count <file>
  local file="$1"
  if command -v jq &>/dev/null; then
    jq '.files | length' "$file" 2>/dev/null
  else
    _json_files "$file" | wc -l | tr -d ' '
  fi
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
    lang="$(grep '^LANGUAGE=' "$conf" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"')"
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
      STR_NO_MANIFEST="マニフェストが見つかりません: %s"
      STR_NO_MANIFEST_HINT="スターターキットがデプロイしたファイルを特定できません。"
      STR_NO_MANIFEST_MANUAL="すべての Claude Code 設定を削除するには %s を手動で削除してください"
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
      ;;
    *)
      STR_TITLE="Claude Code Starter Kit - Uninstall"
      STR_NO_MANIFEST="No manifest found at %s"
      STR_NO_MANIFEST_HINT="Cannot determine which files were deployed by the starter kit."
      STR_NO_MANIFEST_MANUAL="If you want to remove all Claude Code config, manually delete %s"
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

# ---------------------------------------------------------------------------
# Remove tracked files
# ---------------------------------------------------------------------------
removed=0
skipped=0

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  if [[ -f "$file" ]]; then
    rm -f "$file"
    ((removed++))
  else
    ((skipped++))
  fi
done < <(_json_files "$MANIFEST")

# Remove manifest itself
rm -f "$MANIFEST"

# ---------------------------------------------------------------------------
# Clean up empty directories
# ---------------------------------------------------------------------------
for dir in agents rules commands skills memory hooks; do
  target="$CLAUDE_DIR/$dir"
  if [[ -d "$target" ]] && [[ -z "$(ls -A "$target" 2>/dev/null)" ]]; then
    rmdir "$target" 2>/dev/null || true
  fi
done

# Clean hooks subdirectories
for dir in "$CLAUDE_DIR"/hooks/*/; do
  if [[ -d "$dir" ]] && [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
    rmdir "$dir" 2>/dev/null || true
  fi
done

# ---------------------------------------------------------------------------
# Clean saved config
# ---------------------------------------------------------------------------
if [[ -f "$HOME/.claude-starter-kit.conf" ]]; then
  rm -f "$HOME/.claude-starter-kit.conf"
  ok "$STR_REMOVED_CONFIG"
fi

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
