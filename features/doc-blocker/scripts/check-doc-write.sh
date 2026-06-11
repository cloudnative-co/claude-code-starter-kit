#!/bin/bash
# Block ad-hoc docs while allowing documented Starter Kit output locations.
set -euo pipefail

input="$(cat)"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')"

_doc_blocker_allowed_path() {
  local path="$1"
  case "$path" in
    *README.md|*CLAUDE.md|*AGENTS.md|*CONTRIBUTING.md) return 0 ;;
    *HANDOVER.md|*research.md) return 0 ;;
    *docs/CONTRIB.md|*docs/RUNBOOK.md|*docs/DELETION_LOG.md|*docs/SECURITY.md) return 0 ;;
    *docs/CODEMAPS/*.md|*docs/GUIDES/*.md|*codemaps/*.md) return 0 ;;
    *.claude/evals/*.md|*.claude/skills/*|*.claude/projects/*/memory/*) return 0 ;;
    *.reports/*.md|*.reports/*.txt) return 0 ;;
    *.specify/memory/constitution.md) return 0 ;;
  esac
  return 1
}

if [[ "$file_path" =~ \.(md|txt)$ ]] && ! _doc_blocker_allowed_path "$file_path"; then
  echo "[Hook] BLOCKED: Use README.md or an approved Starter Kit output path for documentation" >&2
  exit 2
fi

printf '%s\n' "$input"
