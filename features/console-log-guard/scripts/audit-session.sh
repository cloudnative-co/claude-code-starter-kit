#!/bin/bash
set -euo pipefail

cat >/dev/null

if git rev-parse --git-dir >/dev/null 2>&1; then
  modified_files="$(git diff --name-only HEAD 2>/dev/null | grep -E '\.(ts|tsx|js|jsx)$' || true)"
  if [[ -n "$modified_files" ]]; then
    while IFS= read -r file; do
      if [[ -f "$file" ]] && grep -q "console\\.log" "$file" 2>/dev/null; then
        echo "[Hook] WARNING: console.log in $file" >&2
      fi
    done <<< "$modified_files"
  fi
fi
