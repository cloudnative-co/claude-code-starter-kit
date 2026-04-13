#!/bin/bash
# tests/unit/test-recommendation.sh - Unit tests for lib/recommendation.sh
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded).

# Source dependency: recommendation.sh needs DISMISSED_FEATURES global
DISMISSED_FEATURES=""

# shellcheck source=lib/recommendation.sh
source "$PROJECT_DIR/lib/recommendation.sh"

# ══════════════════════════════════════════════════════════════════════════
# _validate_dismissed_features: unset variable
# ══════════════════════════════════════════════════════════════════════════

unset DISMISSED_FEATURES 2>/dev/null || true
_validate_dismissed_features
if assert_equals "" "${DISMISSED_FEATURES:-}" "Unset variable should become empty after validation"; then
  pass "recommendation: _validate_dismissed_features handles unset variable"
else
  fail "recommendation: _validate_dismissed_features failed on unset variable"
fi
DISMISSED_FEATURES=""

# ══════════════════════════════════════════════════════════════════════════
# _validate_dismissed_features
# ══════════════════════════════════════════════════════════════════════════

# Valid: lowercase, hyphens, commas
DISMISSED_FEATURES="biome-hooks,safety-net"
_validate_dismissed_features
if assert_equals "biome-hooks,safety-net" "$DISMISSED_FEATURES" "Valid CSV should be preserved"; then
  pass "recommendation: _validate_dismissed_features preserves valid CSV"
else
  fail "recommendation: _validate_dismissed_features altered valid CSV"
fi

# Valid: single item
DISMISSED_FEATURES="biome-hooks"
_validate_dismissed_features
if assert_equals "biome-hooks" "$DISMISSED_FEATURES" "Single item should be preserved"; then
  pass "recommendation: _validate_dismissed_features preserves single item"
else
  fail "recommendation: _validate_dismissed_features altered single item"
fi

# Valid: empty string
DISMISSED_FEATURES=""
_validate_dismissed_features
if assert_equals "" "$DISMISSED_FEATURES" "Empty string should be preserved"; then
  pass "recommendation: _validate_dismissed_features preserves empty string"
else
  fail "recommendation: _validate_dismissed_features altered empty string"
fi

# Invalid: uppercase characters
DISMISSED_FEATURES="Biome-Hooks"
_validate_dismissed_features
if assert_equals "" "$DISMISSED_FEATURES" "Uppercase should be cleared"; then
  pass "recommendation: _validate_dismissed_features clears uppercase"
else
  fail "recommendation: _validate_dismissed_features did not clear uppercase"
fi

# Invalid: spaces
DISMISSED_FEATURES="biome hooks"
_validate_dismissed_features
if assert_equals "" "$DISMISSED_FEATURES" "Spaces should be cleared"; then
  pass "recommendation: _validate_dismissed_features clears spaces"
else
  fail "recommendation: _validate_dismissed_features did not clear spaces"
fi

# Invalid: special characters
DISMISSED_FEATURES="biome;rm -rf /"
_validate_dismissed_features
if assert_equals "" "$DISMISSED_FEATURES" "Special chars should be cleared"; then
  pass "recommendation: _validate_dismissed_features clears special chars"
else
  fail "recommendation: _validate_dismissed_features did not clear special chars"
fi

# ══════════════════════════════════════════════════════════════════════════
# _is_feature_dismissed
# ══════════════════════════════════════════════════════════════════════════

# Match in multi-item CSV
DISMISSED_FEATURES="biome-hooks,safety-net,doc-size-guard"
if _is_feature_dismissed "safety-net"; then
  pass "recommendation: _is_feature_dismissed finds item in middle of CSV"
else
  fail "recommendation: _is_feature_dismissed missed item in CSV"
fi

# Match first item
if _is_feature_dismissed "biome-hooks"; then
  pass "recommendation: _is_feature_dismissed finds first item"
else
  fail "recommendation: _is_feature_dismissed missed first item"
fi

# Match last item
if _is_feature_dismissed "doc-size-guard"; then
  pass "recommendation: _is_feature_dismissed finds last item"
else
  fail "recommendation: _is_feature_dismissed missed last item"
fi

# No match
if ! _is_feature_dismissed "prettier-hooks"; then
  pass "recommendation: _is_feature_dismissed returns 1 for missing item"
else
  fail "recommendation: _is_feature_dismissed false positive for missing item"
fi

# Partial string should NOT match (critical edge case)
DISMISSED_FEATURES="safety-net"
if ! _is_feature_dismissed "net"; then
  pass "recommendation: _is_feature_dismissed does not partial-match 'net' in 'safety-net'"
else
  fail "recommendation: _is_feature_dismissed partial-matched 'net' in 'safety-net'"
fi

if ! _is_feature_dismissed "safety"; then
  pass "recommendation: _is_feature_dismissed does not partial-match 'safety' in 'safety-net'"
else
  fail "recommendation: _is_feature_dismissed partial-matched 'safety' in 'safety-net'"
fi

# Single item CSV (no commas)
DISMISSED_FEATURES="biome-hooks"
if _is_feature_dismissed "biome-hooks"; then
  pass "recommendation: _is_feature_dismissed matches single-item CSV"
else
  fail "recommendation: _is_feature_dismissed missed single-item CSV"
fi

# Empty DISMISSED_FEATURES
DISMISSED_FEATURES=""
if ! _is_feature_dismissed "biome-hooks"; then
  pass "recommendation: _is_feature_dismissed returns 1 for empty CSV"
else
  fail "recommendation: _is_feature_dismissed false positive on empty CSV"
fi

# ══════════════════════════════════════════════════════════════════════════
# _add_dismissed_feature
# ══════════════════════════════════════════════════════════════════════════

# Add to empty
DISMISSED_FEATURES=""
_add_dismissed_feature "biome-hooks"
if assert_equals "biome-hooks" "$DISMISSED_FEATURES" "Should add to empty CSV"; then
  pass "recommendation: _add_dismissed_feature adds to empty CSV"
else
  fail "recommendation: _add_dismissed_feature failed on empty CSV"
fi

# Add second item
_add_dismissed_feature "safety-net"
if assert_equals "biome-hooks,safety-net" "$DISMISSED_FEATURES" "Should append with comma"; then
  pass "recommendation: _add_dismissed_feature appends second item"
else
  fail "recommendation: _add_dismissed_feature failed appending"
fi

# Duplicate prevention
_add_dismissed_feature "biome-hooks"
if assert_equals "biome-hooks,safety-net" "$DISMISSED_FEATURES" "Should not add duplicate"; then
  pass "recommendation: _add_dismissed_feature prevents duplicates"
else
  fail "recommendation: _add_dismissed_feature added duplicate"
fi

# Add third item
_add_dismissed_feature "doc-size-guard"
if assert_equals "biome-hooks,safety-net,doc-size-guard" "$DISMISSED_FEATURES" "Should append third"; then
  pass "recommendation: _add_dismissed_feature appends third item"
else
  fail "recommendation: _add_dismissed_feature failed on third item"
fi

# Add with unset DISMISSED_FEATURES
unset DISMISSED_FEATURES 2>/dev/null || true
_add_dismissed_feature "new-feature"
if assert_equals "new-feature" "${DISMISSED_FEATURES:-}" "Should handle unset DISMISSED_FEATURES"; then
  pass "recommendation: _add_dismissed_feature handles unset DISMISSED_FEATURES"
else
  fail "recommendation: _add_dismissed_feature failed on unset DISMISSED_FEATURES"
fi
DISMISSED_FEATURES=""
