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
# Confirmation
# ---------------------------------------------------------------------------
printf "\n${BOLD}Claude Code Starter Kit - Uninstall${NC}\n\n"

if [[ ! -f "$MANIFEST" ]]; then
  error "No manifest found at $MANIFEST"
  error "Cannot determine which files were deployed by the starter kit."
  error "If you want to remove all Claude Code config, manually delete $CLAUDE_DIR"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  error "jq is required for uninstall. Install it and try again."
  exit 1
fi

file_count="$(jq '.files | length' "$MANIFEST")"
profile="$(jq -r '.profile // "unknown"' "$MANIFEST")"
timestamp="$(jq -r '.timestamp // "unknown"' "$MANIFEST")"

info "Found manifest from $timestamp (profile: $profile)"
info "Will remove $file_count tracked files"
printf "\n"

read -r -p "Continue with uninstall? [y/N] " confirm
case "$confirm" in
  y|Y|yes|YES) ;;
  *)
    info "Uninstall canceled."
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
  ok "Removed saved configuration"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n"
ok "Uninstall complete"
info "Removed: $removed files"
if [[ "$skipped" -gt 0 ]]; then
  info "Skipped: $skipped files (already missing)"
fi

# Check if ~/.claude still has content
if [[ -d "$CLAUDE_DIR" ]]; then
  remaining="$(find "$CLAUDE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$remaining" -gt 0 ]]; then
    info "$remaining user files remain in $CLAUDE_DIR (not managed by starter kit)"
  else
    info "$CLAUDE_DIR is now empty"
  fi
fi
