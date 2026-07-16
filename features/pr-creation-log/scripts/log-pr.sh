#!/bin/bash
set -euo pipefail

input="$(cat)"

if [[ "${PR_CREATION_LOG_LEGACY:-0}" == "1" ]]; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
  printf '%s' "$cmd" | grep -qE 'gh pr create' || exit 0
fi

output="$(printf '%s' "$input" | jq -r '[.tool_response.stdout // "", .tool_response.stderr // ""] | join("\n")')"
# `|| true` prevents pipefail from propagating grep's no-match exit code (1)
# when no PR URL is present, which would otherwise trigger `set -e` and
# silently kill the hook before the `[[ -n "$pr_url" ]]` fallback below.
pr_url="$(printf '%s' "$output" | grep -oE 'https://github.com/[^/]+/[^/]+/pull/[0-9]+' | head -1 || true)"
if [[ -n "$pr_url" ]]; then
  echo "[Hook] PR created: $pr_url" >&2
fi
