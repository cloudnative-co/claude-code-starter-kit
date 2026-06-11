#!/bin/bash
set -euo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"

if printf '%s' "$cmd" | grep -qE '(npm run dev|pnpm( run)? dev|yarn dev|bun run dev)' \
  && [[ -z "${TMUX:-}" ]] \
  && ! printf '%s' "$cmd" | grep -qE 'tmux[[:space:]]+(new-session|new|send-keys)'; then
  echo '[Hook] BLOCKED: Dev server must run in tmux for log access' >&2
  echo '[Hook] Use: tmux new-session -d -s dev "npm run dev"' >&2
  echo '[Hook] Then: tmux attach -t dev' >&2
  exit 2
fi

if printf '%s' "$cmd" | grep -qE '(npm (install|test)|pnpm (install|test)|yarn (install|test)|bun (install|test)|cargo build|make|docker|pytest|vitest|playwright)' \
  && [[ -z "${TMUX:-}" ]]; then
  echo '[Hook] Consider running in tmux for session persistence' >&2
fi
