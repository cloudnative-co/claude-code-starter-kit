#!/bin/bash
# lib/features.sh - Feature registry for Claude Code Starter Kit
#
# Centralizes the mapping between feature names, ENABLE_* flags, and
# whether they have deploy scripts. Replaces 12+ hardcoded is_true checks.
#
# IMPORTANT: This file MUST be sourced AFTER Bash 4+ re-exec is confirmed.
# Uses: declare -A (Bash 4+ only)
#
# Requires: wizard/wizard.sh (is_true, ENABLE_* globals)
# Sets globals: _FEATURE_FLAGS[], _FEATURE_HAS_SCRIPTS[], _FEATURE_ORDER[]
# Exports: (associative arrays only, no functions)
# Dry-run: transparent (data-only, no side effects)
set -euo pipefail

# ---------------------------------------------------------------------------
# Feature registry: maps feature name → ENABLE_* variable name
# ---------------------------------------------------------------------------
declare -A _FEATURE_FLAGS=(
  [safety-net]=ENABLE_SAFETY_NET
  [tmux-hooks]=ENABLE_TMUX_HOOKS
  [doc-blocker]=ENABLE_DOC_BLOCKER
  [prettier-hooks]=ENABLE_PRETTIER_HOOKS
  [console-log-guard]=ENABLE_CONSOLE_LOG_GUARD
  [memory-persistence]=ENABLE_MEMORY_PERSISTENCE
  [strategic-compact]=ENABLE_STRATEGIC_COMPACT
  [pr-creation-log]=ENABLE_PR_CREATION_LOG
  [pre-compact-commit]=ENABLE_PRE_COMPACT_COMMIT
  [auto-update]=ENABLE_AUTO_UPDATE
  [statusline]=ENABLE_STATUSLINE
  [doc-size-guard]=ENABLE_DOC_SIZE_GUARD
)

# ---------------------------------------------------------------------------
# Features that have deploy scripts in features/<name>/scripts/
# ---------------------------------------------------------------------------
declare -A _FEATURE_HAS_SCRIPTS=(
  [memory-persistence]=true
  [strategic-compact]=true
  [auto-update]=true
  [statusline]=true
  [doc-size-guard]=true
)

# ---------------------------------------------------------------------------
# Ordered feature list (determines hook fragment merge order)
# CRITICAL: safety-net MUST be first (PreToolUse runs in array order)
# ---------------------------------------------------------------------------
_FEATURE_ORDER=(
  safety-net tmux-hooks doc-blocker prettier-hooks console-log-guard
  memory-persistence strategic-compact pr-creation-log pre-compact-commit
  auto-update statusline doc-size-guard
)

# ---------------------------------------------------------------------------
# Special-case features (not in _FEATURE_ORDER, handled individually):
#   - git-push-review: EDITOR_CHOICE runtime substitution in build_settings_file()
#   - codex-plugin: managed by lib/codex-setup.sh + plugin install
#   - ghostty: platform-specific, managed by lib/ghostty.sh
#   - fonts: non-hook component, managed by lib/fonts.sh
# ---------------------------------------------------------------------------
