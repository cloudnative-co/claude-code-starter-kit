#!/bin/bash
set -euo pipefail

input="$(cat)"

if [[ "${PR_CREATION_LOG_LEGACY:-0}" == "1" ]]; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
  printf '%s' "$cmd" | grep -qE 'gh pr create' || exit 0
fi

output="$(printf '%s' "$input" | jq -r '[.tool_response.stdout // "", .tool_response.stderr // ""] | join("\n")')"
pr_url="$(printf '%s' "$output" | grep -oE 'https://github.com/[^/]+/[^/]+/pull/[0-9]+' | head -1)"
if [[ -n "$pr_url" ]]; then
  echo "[Hook] PR created: $pr_url" >&2
fi
