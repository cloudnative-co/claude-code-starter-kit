#!/bin/bash
# uninstall.sh - Clean uninstall for Claude Code Starter Kit
# Only removes files tracked in the manifest. User-added files are preserved.
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
MANIFEST="$CLAUDE_DIR/.starter-kit-manifest.json"

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
# i18n - detect language from manifest or saved config
# ---------------------------------------------------------------------------
_detect_language() {
  # Try manifest first
  if [[ -f "$MANIFEST" ]] && command -v jq &>/dev/null; then
    local lang
    lang="$(jq -r '.language // ""' "$MANIFEST" 2>/dev/null)"
    if [[ -n "$lang" ]]; then
      printf '%s' "$lang"
      return
    fi
  fi
  # Try saved config
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
      STR_JQ_REQUIRED="アンインストールには jq が必要です。インストールしてから再実行してください。"
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
      ;;
    *)
      STR_TITLE="Claude Code Starter Kit - Uninstall"
      STR_NO_MANIFEST="No manifest found at %s"
      STR_NO_MANIFEST_HINT="Cannot determine which files were deployed by the starter kit."
      STR_NO_MANIFEST_MANUAL="If you want to remove all Claude Code config, manually delete %s"
      STR_JQ_REQUIRED="jq is required for uninstall. Install it and try again."
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

if ! command -v jq &>/dev/null; then
  error "$STR_JQ_REQUIRED"
  exit 1
fi

file_count="$(jq '.files | length' "$MANIFEST")"
profile="$(jq -r '.profile // "unknown"' "$MANIFEST")"
timestamp="$(jq -r '.timestamp // "unknown"' "$MANIFEST")"

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
  if [[ -f "$file" ]]; then
    rm -f "$file"
    ((removed++))
  else
    ((skipped++))
  fi
done < <(jq -r '.files[]' "$MANIFEST")

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
