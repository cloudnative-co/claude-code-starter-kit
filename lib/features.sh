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
  [pr-creation-log]=ENABLE_PR_CREATION_LOG
  [pre-compact-commit]=ENABLE_PRE_COMPACT_COMMIT
  [auto-update]=ENABLE_AUTO_UPDATE
  [web-content-update]=ENABLE_WEB_CONTENT_UPDATE
  [statusline]=ENABLE_STATUSLINE
  [doc-size-guard]=ENABLE_DOC_SIZE_GUARD
  [no-flicker]=ENABLE_NO_FLICKER
  [agent-teams]=ENABLE_AGENT_TEAMS
  [feature-recommendation]=ENABLE_FEATURE_RECOMMENDATION
)

# ---------------------------------------------------------------------------
# Features that have deploy scripts in features/<name>/scripts/
# ---------------------------------------------------------------------------
declare -g -A _FEATURE_HAS_SCRIPTS=(
  [safety-net]=true
  [doc-blocker]=true
  [tmux-hooks]=true
  [prettier-hooks]=true
  [biome-hooks]=true
  [pr-creation-log]=true
  [auto-update]=true
  [statusline]=true
  [doc-size-guard]=true
  [feature-recommendation]=true
)

# ---------------------------------------------------------------------------
# Ordered feature list (determines hook fragment merge order)
# CRITICAL: safety-net MUST be first (PreToolUse runs in array order)
# ---------------------------------------------------------------------------
declare -g -a _FEATURE_ORDER=(
  safety-net tmux-hooks doc-blocker prettier-hooks biome-hooks
  pr-creation-log pre-compact-commit
  auto-update web-content-update statusline doc-size-guard no-flicker agent-teams
  feature-recommendation
)

# ---------------------------------------------------------------------------
# Script deployment iteration list (currently identical to _FEATURE_ORDER;
# kept as a separate registry for script-only special cases).
# ---------------------------------------------------------------------------
declare -g -a _FEATURE_SCRIPT_ORDER=("${_FEATURE_ORDER[@]}")

# ---------------------------------------------------------------------------
# Special-case features (not in _FEATURE_ORDER, handled individually):
#   - codex-plugin: managed by lib/codex-setup.sh + plugin install
#   - ghostty: platform-specific, managed by lib/ghostty.sh
#   - fonts: non-hook component, managed by lib/fonts.sh
# ---------------------------------------------------------------------------
