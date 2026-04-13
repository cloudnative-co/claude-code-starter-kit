#!/bin/bash
# check-pending.sh - SessionStart hook: notify user about pending features
#
# Self-contained script (does NOT source lib/*.sh).
# Reads ~/.claude/.starter-kit-pending-features.json and displays
# available features with displayName/description from kit repo.
#
# Bash 3.2 compatible (macOS default). No mapfile, no associative arrays.
#
# Exit codes: always 0 (never block session start)
set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
PENDING_FILE="$CLAUDE_DIR/.starter-kit-pending-features.json"

# Exit silently if no pending features
[[ -f "$PENDING_FILE" ]] || exit 0

# Validate JSON (exit silently on parse error)
jq empty "$PENDING_FILE" 2>/dev/null || exit 0

# Read feature names (Bash 3.2 compatible - no mapfile)
FEATURES=()
while IFS= read -r line; do
  [[ -n "$line" ]] && FEATURES+=("$line")
done < <(jq -r '.features[]' "$PENDING_FILE" 2>/dev/null)
[[ ${#FEATURES[@]} -gt 0 ]] || exit 0

# ---------------------------------------------------------------------------
# Resolve kit repo path (same assumption as auto-update.sh)
# ---------------------------------------------------------------------------
KIT_REPO="${HOME}/.claude-starter-kit"
[[ -d "$KIT_REPO/features" ]] || KIT_REPO=""

# ---------------------------------------------------------------------------
# Sanitize display strings (strip ANSI escapes first, then non-printable chars)
# Order matters: sed removes escape sequences before tr strips control chars
# ---------------------------------------------------------------------------
_sanitize_display() {
  printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | LC_ALL=C tr -cd '[:print:] \t'
}

# ---------------------------------------------------------------------------
# Resolve displayName and description from feature.json
# Falls back to titlecased feature name if kit repo unavailable
# ---------------------------------------------------------------------------
_resolve_feature_info() {
  local name="$1"
  local fj="${KIT_REPO}/features/${name}/feature.json"
  local display_name="" description=""

  if [[ -n "$KIT_REPO" ]] && [[ -f "$fj" ]]; then
    display_name="$(jq -r '.displayName // empty' "$fj" 2>/dev/null || true)"
    description="$(jq -r '.description // empty' "$fj" 2>/dev/null || true)"
  fi

  # Fallback: hyphen to space, titlecase (awk for BSD/GNU portability)
  if [[ -z "$display_name" ]]; then
    display_name="$(printf '%s' "$name" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')"
  fi

  _sanitize_display "$display_name"
  if [[ -n "$description" ]]; then
    printf ': '
    _sanitize_display "$description"
  fi
}

# ---------------------------------------------------------------------------
# Detect language from conf (lightweight grep, no full config parsing)
# ---------------------------------------------------------------------------
LANGUAGE="en"
CONF_FILE="${HOME}/.claude-starter-kit.conf"
if [[ -f "$CONF_FILE" ]]; then
  _lang_val="$(grep '^LANGUAGE=' "$CONF_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' || true)"
  [[ -n "$_lang_val" ]] && LANGUAGE="$_lang_val"
fi

# ---------------------------------------------------------------------------
# Build notification message
# ---------------------------------------------------------------------------
count=${#FEATURES[@]}
MAX_DISPLAY=3

if [[ "$LANGUAGE" == "ja" ]]; then
  if [[ $count -eq 1 ]]; then
    printf '[Starter Kit] 新機能が利用可能です:\n'
  else
    printf '[Starter Kit] %d 件の新機能が利用可能です:\n' "$count"
  fi

  idx=0
  for feat in "${FEATURES[@]}"; do
    if [[ $idx -lt $MAX_DISPLAY ]]; then
      printf '  - %s\n' "$(_resolve_feature_info "$feat")"
    fi
    idx=$((idx + 1))
  done
  if [[ $count -gt $MAX_DISPLAY ]]; then
    printf '  ...他 %d 件\n' $((count - MAX_DISPLAY))
  fi
  printf '  このセッションで /update-kit と入力すると、各機能の有効化・スキップを選べます。\n'
else
  if [[ $count -eq 1 ]]; then
    printf '[Starter Kit] New feature available:\n'
  else
    printf '[Starter Kit] %d new features available:\n' "$count"
  fi

  idx=0
  for feat in "${FEATURES[@]}"; do
    if [[ $idx -lt $MAX_DISPLAY ]]; then
      printf '  - %s\n' "$(_resolve_feature_info "$feat")"
    fi
    idx=$((idx + 1))
  done
  if [[ $count -gt $MAX_DISPLAY ]]; then
    printf '  ...and %d more\n' $((count - MAX_DISPLAY))
  fi
  printf '  Type /update-kit in this session to choose which features to enable or skip.\n'
fi
