#!/bin/bash
# auto-update.sh - Check for and apply starter kit updates on SessionStart
# Runs once per 24 hours. Fast-path exits in < 1ms when cache is fresh.
set -euo pipefail

KIT_DIR="$HOME/.claude-starter-kit"
CACHE_FILE="$HOME/.claude/.starter-kit-update-cache"
CACHE_TTL=86400  # 24 hours in seconds

# Exit silently if not a one-liner install (no git repo at standard path)
[[ -d "$KIT_DIR/.git" ]] || exit 0

# Fast path: skip if checked recently
if [[ -f "$CACHE_FILE" ]]; then
  last_check="$(cat "$CACHE_FILE" 2>/dev/null || echo "0")"
  now="$(date +%s)"
  if (( now - last_check < CACHE_TTL )); then
    exit 0
  fi
fi

# Update cache timestamp immediately (prevent concurrent checks from parallel sessions)
mkdir -p "$(dirname "$CACHE_FILE")"
date +%s > "$CACHE_FILE"

# Fetch remote tags (typically 1-2 seconds on a small repo)
if ! git -C "$KIT_DIR" fetch --tags --quiet 2>/dev/null; then
  exit 0  # Network failure — skip silently
fi

# Compare local HEAD tag with remote main tag
local_ver="$(git -C "$KIT_DIR" describe --tags --abbrev=0 HEAD 2>/dev/null || echo "v0.0.0")"
remote_ver="$(git -C "$KIT_DIR" describe --tags --abbrev=0 origin/main 2>/dev/null || echo "v0.0.0")"

[[ "$local_ver" == "$remote_ver" ]] && exit 0

# Run update in background so it doesn't block session startup
(
  echo "[Starter Kit] Updating ${local_ver} → ${remote_ver}..." >&2
  cd "$KIT_DIR"
  if git pull --quiet 2>/dev/null; then
    if bash setup.sh --update 2>/dev/null; then
      echo "[Starter Kit] Updated to ${remote_ver}. Changes take effect next session." >&2
    else
      echo "[Starter Kit] Update failed. Run manually: ~/.claude-starter-kit/setup.sh --update" >&2
    fi
  else
    echo "[Starter Kit] git pull failed. Run manually: cd ~/.claude-starter-kit && git pull && ./setup.sh --update" >&2
  fi
) &

exit 0
