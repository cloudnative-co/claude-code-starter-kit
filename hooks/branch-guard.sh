#!/bin/bash
# branch-guard.sh — Block push to main/master and force-push
# PreToolUse hook, matcher: Bash
COMMAND=$(cat | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*\b(main|master)\b'; then
    echo "BLOCKED: Direct push to main/master" >&2; exit 2
fi
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--force|-f\b'; then
    echo "BLOCKED: Force push" >&2; exit 2
fi
exit 0
