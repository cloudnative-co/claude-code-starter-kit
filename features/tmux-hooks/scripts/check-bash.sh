#!/bin/bash
set -euo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
run_in_background="$(printf '%s' "$input" | jq -r '.tool_input.run_in_background // false')"

# Native background execution manages the process and its logs — nothing to add.
if [[ "$run_in_background" == "true" ]]; then
  exit 0
fi

# Foreground dev server outside tmux: non-blocking reminder only.
if printf '%s' "$cmd" | grep -qE '(npm run dev|pnpm( run)? dev|yarn dev|bun run dev)' \
  && [[ -z "${TMUX:-}" ]] \
  && ! printf '%s' "$cmd" | grep -qE 'tmux[[:space:]]+(new-session|new|send-keys)'; then
  echo '[Hook] Reminder: prefer run_in_background for dev servers (or tmux new-session for a persistent session)' >&2
fi

exit 0
