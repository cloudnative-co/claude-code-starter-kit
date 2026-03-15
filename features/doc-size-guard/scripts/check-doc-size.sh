#!/usr/bin/env bash
# Doc Size Guard - Validates CLAUDE.md/AGENTS.md size and path integrity
# Runs as PostToolUse hook when Write tool modifies these files

set -euo pipefail

# Read hook input from stdin (required by Claude Code hook protocol)
input=$(cat)

WARN_LINES_AGENTS=60
ERROR_LINES_AGENTS=100
WARN_LINES_CLAUDE=150
ERROR_LINES_CLAUDE=300

check_file_size() {
    local file="$1"
    local warn_limit="$2"
    local error_limit="$3"
    local label="$4"

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    local line_count
    line_count=$(wc -l < "$file" | tr -d ' ')

    if (( line_count > error_limit )); then
        echo "ERROR: ${label} is ${line_count} lines (limit: ${error_limit}). Refactor content into sub-files and use Progressive Disclosure." >&2
        return 1
    elif (( line_count > warn_limit )); then
        echo "WARNING: ${label} is ${line_count} lines (recommended: <${warn_limit}). Consider moving details to skills/ or docs/." >&2
    fi
    return 0
}

check_path_references() {
    local file="$1"
    local label="$2"

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    local has_error=0
    while IFS= read -r path; do
        local expanded_path="${path/#\~/$HOME}"
        if [[ "$path" == http* || "$path" == "#"* ]]; then
            continue
        fi
        if [[ -n "$path" && ! -e "$expanded_path" && "$path" != http* && "$path" != "#"* ]]; then
            if [[ "$path" == *"/"* || "$path" == *"."* ]]; then
                echo "WARNING: Broken path reference in ${label}: ${path}" >&2
                has_error=1
            fi
        fi
    done < <(grep -oE '`[^`]+`' "$file" 2>/dev/null | tr -d '`' | grep -E '(/|\.)' || true)

    return $has_error
}

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
exit_code=0

# Check AGENTS.md
for agents_path in "${PROJECT_ROOT}/AGENTS.md" "${PROJECT_ROOT}/.claude/AGENTS.md"; do
    if [[ -f "$agents_path" ]]; then
        check_file_size "$agents_path" "$WARN_LINES_AGENTS" "$ERROR_LINES_AGENTS" "AGENTS.md" || exit_code=1
        check_path_references "$agents_path" "AGENTS.md" || true
    fi
done

# Check CLAUDE.md
for claude_path in "${PROJECT_ROOT}/CLAUDE.md" "${PROJECT_ROOT}/.claude/CLAUDE.md"; do
    if [[ -f "$claude_path" ]]; then
        check_file_size "$claude_path" "$WARN_LINES_CLAUDE" "$ERROR_LINES_CLAUDE" "CLAUDE.md" || exit_code=1
        check_path_references "$claude_path" "CLAUDE.md" || true
    fi
done

# Pass through the input
printf '%s\n' "$input"

exit $exit_code
