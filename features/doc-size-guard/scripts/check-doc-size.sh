#!/usr/bin/env bash
# Doc Size Guard - Warns when CLAUDE.md/AGENTS.md grows beyond size-hygiene targets
# Runs as PostToolUse hook when Write tool modifies these files

set -euo pipefail

# Read hook input from stdin (required by Claude Code hook protocol)
input=$(cat)

# Only act when the Write tool targeted CLAUDE.md / AGENTS.md. The Claude Code
# matcher can only filter by tool name, so the file_path filter lives here.
written_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)
if [[ ! "$written_path" =~ (CLAUDE|AGENTS)\.md$ ]]; then
    exit 0
fi

WARN_LINES_AGENTS=150
WARN_LINES_CLAUDE=250

check_file_size() {
    local file="$1"
    local warn_limit="$2"
    local label="$3"

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    local line_count
    line_count=$(wc -l < "$file" | tr -d ' ')

    if (( line_count > warn_limit )); then
        echo "WARNING: ${label} is ${line_count} lines (size-hygiene target: <${warn_limit}). Always-loaded lines cost context every turn — consider moving details to skills/ or docs/ (progressive disclosure)." >&2
    fi
    return 0
}

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Check AGENTS.md
for agents_path in "${PROJECT_ROOT}/AGENTS.md" "${PROJECT_ROOT}/.claude/AGENTS.md"; do
    check_file_size "$agents_path" "$WARN_LINES_AGENTS" "AGENTS.md"
done

# Check CLAUDE.md
for claude_path in "${PROJECT_ROOT}/CLAUDE.md" "${PROJECT_ROOT}/.claude/CLAUDE.md"; do
    check_file_size "$claude_path" "$WARN_LINES_CLAUDE" "CLAUDE.md"
done

exit 0
