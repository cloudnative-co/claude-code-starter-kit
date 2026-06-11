#!/bin/bash
set -euo pipefail

input="$(cat)"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')"

if [[ "$file_path" =~ \.(ts|tsx|js|jsx)$ ]] && [[ -f "$file_path" ]]; then
  console_logs="$(grep -n "console\\.log" "$file_path" 2>/dev/null || true)"
  if [[ -n "$console_logs" ]]; then
    echo "[Hook] WARNING: console.log found in $file_path" >&2
    printf '%s\n' "$console_logs" | head -5 >&2
  fi
fi
