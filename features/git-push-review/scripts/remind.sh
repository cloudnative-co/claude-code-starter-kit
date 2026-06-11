#!/bin/bash
set -euo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"

if printf '%s' "$cmd" | grep -qE 'git[[:space:]]+push'; then
  echo '[Hook] Reminder: review your staged changes and target branch before pushing.' >&2
  echo '[Hook] Tip: run `git log origin/HEAD..HEAD --oneline` and `git diff origin/HEAD..HEAD` to review.' >&2
fi
