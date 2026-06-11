#!/bin/bash
# lib/features.sh - Feature registry for Claude Code Starter Kit
#
# Centralizes the mapping between feature names, ENABLE_* flags, and
# whether they have deploy scripts. Replaces 12+ hardcoded is_true checks.
#
# IMPORTANT: This file MUST be sourced AFTER Bash 4+ re-exec is confirmed.
# Uses: declare -g/-A (Bash 4+ only)
#
# Requires: ENABLE_* globals. is_true is provided later by lib/deploy.sh.
# Sets globals: _FEATURE_FLAGS[], _FEATURE_HAS_SCRIPTS[], _FEATURE_ORDER[]
# Exports: (associative arrays only, no functions)
# Dry-run: transparent (data-only, no side effects)
set -euo pipefail

# ---------------------------------------------------------------------------
# Feature registry: maps feature name → ENABLE_* variable name
# ---------------------------------------------------------------------------
declare -g -A _FEATURE_FLAGS=(
  [safety-net]=ENABLE_SAFETY_NET
  [tmux-hooks]=ENABLE_TMUX_HOOKS
  [doc-blocker]=ENABLE_DOC_BLOCKER
  [prettier-hooks]=ENABLE_PRETTIER_HOOKS
  [biome-hooks]=ENABLE_BIOME_HOOKS
  [console-log-guard]=ENABLE_CONSOLE_LOG_GUARD
  [memory-persistence]=ENABLE_MEMORY_PERSISTENCE
  [strategic-compact]=ENABLE_STRATEGIC_COMPACT
  [pr-creation-log]=ENABLE_PR_CREATION_LOG
  [pre-compact-commit]=ENABLE_PRE_COMPACT_COMMIT
  [auto-update]=ENABLE_AUTO_UPDATE
  [web-content-update]=ENABLE_WEB_CONTENT_UPDATE
  [statusline]=ENABLE_STATUSLINE
  [doc-size-guard]=ENABLE_DOC_SIZE_GUARD
  [no-flicker]=ENABLE_NO_FLICKER
  [feature-recommendation]=ENABLE_FEATURE_RECOMMENDATION
  [git-push-review]=ENABLE_GIT_PUSH_REVIEW
)

# ---------------------------------------------------------------------------
# Features that have deploy scripts in features/<name>/scripts/
# ---------------------------------------------------------------------------
declare -g -A _FEATURE_HAS_SCRIPTS=(
  [doc-blocker]=true
  [tmux-hooks]=true
  [prettier-hooks]=true
  [biome-hooks]=true
  [console-log-guard]=true
  [pr-creation-log]=true
  [memory-persistence]=true
  [strategic-compact]=true
  [auto-update]=true
  [statusline]=true
  [doc-size-guard]=true
  [feature-recommendation]=true
  [git-push-review]=true
)

# ---------------------------------------------------------------------------
# Ordered feature list (determines hook fragment merge order)
# CRITICAL: safety-net MUST be first (PreToolUse runs in array order)
# ---------------------------------------------------------------------------
declare -g -a _FEATURE_ORDER=(
  safety-net tmux-hooks doc-blocker prettier-hooks biome-hooks console-log-guard
  memory-persistence strategic-compact pr-creation-log pre-compact-commit
  auto-update web-content-update statusline doc-size-guard no-flicker
  feature-recommendation
)

# ---------------------------------------------------------------------------
# Script deployment iteration list (= _FEATURE_ORDER + script-only specials).
#
# git-push-review is intentionally NOT in _FEATURE_ORDER: its settings fragment
# needs __EDITOR_CMD__ runtime substitution in build_settings_file(). But its
# hook script MUST still flow through deploy/update/manifest/snapshot like any
# other feature script — iterating only _FEATURE_ORDER here caused updates to
# ship a settings.json referencing a never-deployed remind.sh.
# ---------------------------------------------------------------------------
declare -g -a _FEATURE_SCRIPT_ORDER=("${_FEATURE_ORDER[@]}" git-push-review)

# ---------------------------------------------------------------------------
# Special-case features (not in _FEATURE_ORDER, handled individually):
#   - git-push-review: EDITOR_CHOICE runtime substitution in build_settings_file()
#     (scripts deploy via _FEATURE_SCRIPT_ORDER above)
#   - codex-plugin: managed by lib/codex-setup.sh + plugin install
#   - ghostty: platform-specific, managed by lib/ghostty.sh
#   - fonts: non-hook component, managed by lib/fonts.sh
# ---------------------------------------------------------------------------
