#!/bin/bash
set -euo pipefail

input="$(cat)"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')"

if [[ "$file_path" =~ \.(ts|tsx|js|jsx)$ ]] && [[ -f "$file_path" ]] && command -v prettier >/dev/null 2>&1; then
  prettier --write "$file_path" 2>&1 | head -5 >&2
fi
