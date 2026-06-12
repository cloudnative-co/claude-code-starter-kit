#!/bin/bash
# Deny-by-pattern doc guard: only ad-hoc summary/report style docs trigger a
# confirmation; everything else (CHANGELOG.md, LICENSE.txt, docs/**, ADRs, ...)
# passes through untouched.
set -euo pipefail

input="$(cat)"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')"

# Kit command/agent output locations: always allowed, even slop-like names.
_doc_blocker_allowed_path() {
  local path="$1"
  case "$path" in
    *README.md|*CLAUDE.md|*AGENTS.md|*CONTRIBUTING.md) return 0 ;;
    HANDOVER.md|*/HANDOVER.md|research.md|*/research.md) return 0 ;;
    *docs/CONTRIB.md|*docs/RUNBOOK.md|*docs/DELETION_LOG.md|*docs/SECURITY.md) return 0 ;;
    *docs/CODEMAPS/*.md|*docs/GUIDES/*.md|*codemaps/*.md) return 0 ;;
    *.claude/evals/*.md|*.claude/skills/*|*.claude/projects/*/memory/*) return 0 ;;
    *.reports/*.md|*.reports/*.txt) return 0 ;;
    *.specify/memory/constitution.md) return 0 ;;
  esac
  return 1
}

# Ad-hoc "model slop" doc names: SUMMARY.md, FINAL_REPORT.md, analysis.md,
# NOTES_2026.txt, ... (case-insensitive; underscore-joined variants included).
_doc_blocker_slop_name() {
  local base="$1"
  local matched=1
  shopt -s nocasematch
  if [[ "$base" =~ ^(.*_)?(SUMMARY|REPORT|FINDINGS|ANALYSIS|NOTES|RESULTS|TAKEAWAYS)(_.*)?\.(md|txt)$ ]]; then
    matched=0
  fi
  shopt -u nocasematch
  return "$matched"
}

if [[ "$file_path" =~ \.(md|txt)$ ]] && ! _doc_blocker_allowed_path "$file_path"; then
  base="$(basename "$file_path")"
  if _doc_blocker_slop_name "$base"; then
    jq -cn --arg path "$file_path" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "ask",
        permissionDecisionReason: ("doc-blocker: \($path) matches an ad-hoc summary/report doc pattern (SUMMARY/REPORT/FINDINGS/ANALYSIS/NOTES/RESULTS/TAKEAWAYS). Approve only if the user explicitly asked for this file. Kit output paths (HANDOVER.md, .reports/, docs/CODEMAPS/, ...) are always allowed; the guard can be disabled with ENABLE_DOC_BLOCKER=false.")
      }
    }'
    exit 0
  fi
fi

printf '%s\n' "$input"
