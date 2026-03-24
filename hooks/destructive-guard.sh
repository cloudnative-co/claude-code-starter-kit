#!/bin/bash
# destructive-guard.sh — Block destructive commands
# PreToolUse hook, matcher: Bash
# Blocks: rm -rf /, git reset --hard, git clean -fd
COMMAND=$(cat | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0
# Skip echo/printf context
echo "$COMMAND" | grep -qE '^\s*(echo|printf)\s' && exit 0
# Check destructive patterns
if echo "$COMMAND" | grep -qE '\brm\s+.*-rf\s+(/|~/?\s*$|\.\./)|git\s+reset\s+--hard|git\s+clean\s+-[a-zA-Z]*f|chmod\s+(-R\s+)?777\s+/|--no-preserve-root'; then
    echo "BLOCKED: Destructive command detected" >&2
    echo "Command: $COMMAND" >&2
    exit 2
fi
exit 0
