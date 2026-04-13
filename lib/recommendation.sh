#!/bin/bash
# lib/recommendation.sh - Feature recommendation helpers
#
# Provides dismissed-feature management and validation for the
# feature recommendation system.
#
# IMPORTANT: This file MUST be sourced AFTER wizard/wizard.sh (needs DISMISSED_FEATURES global).
#
# Requires: wizard/wizard.sh (DISMISSED_FEATURES global, save_config)
# Exports: _is_feature_dismissed, _add_dismissed_feature, _validate_dismissed_features
set -euo pipefail

# ---------------------------------------------------------------------------
# Validate DISMISSED_FEATURES value: must contain only [a-z0-9,-]
# Clears the variable if invalid characters are found.
# ---------------------------------------------------------------------------
_validate_dismissed_features() {
  if [[ -n "${DISMISSED_FEATURES:-}" ]] && [[ ! "$DISMISSED_FEATURES" =~ ^[a-z0-9,-]+$ ]]; then
    DISMISSED_FEATURES=""
  fi
}

# ---------------------------------------------------------------------------
# Check if a feature name is in the DISMISSED_FEATURES CSV
# Usage: _is_feature_dismissed "feature-name"
# Returns: 0 if dismissed, 1 otherwise
# ---------------------------------------------------------------------------
_is_feature_dismissed() {
  [[ ",${DISMISSED_FEATURES:-}," == *",$1,"* ]]
}

# ---------------------------------------------------------------------------
# Add a feature name to the DISMISSED_FEATURES CSV (with dedup)
# Usage: _add_dismissed_feature "feature-name"
# ---------------------------------------------------------------------------
_add_dismissed_feature() {
  _is_feature_dismissed "$1" && return 0
  if [[ -z "${DISMISSED_FEATURES:-}" ]]; then
    DISMISSED_FEATURES="$1"
  else
    DISMISSED_FEATURES="${DISMISSED_FEATURES},$1"
  fi
}
