#!/bin/bash
# tests/unit/test-features.sh - Unit tests for lib/features.sh data integrity
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded).

# Source dependencies: features.sh requires is_true() which lives in setup.sh.
# We define a minimal stub so we don't need to source all of setup.sh.
is_true() {
  local v
  v="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

# shellcheck source=lib/features.sh
source "$PROJECT_DIR/lib/features.sh"

# ── _FEATURE_FLAGS has entries for all _FEATURE_ORDER items ───────────────

_missing=""
for _feat in "${_FEATURE_ORDER[@]}"; do
  if [[ -z "${_FEATURE_FLAGS[$_feat]+x}" ]]; then
    _missing="$_missing $_feat"
  fi
done
if assert_empty "$_missing" "All _FEATURE_ORDER entries should be in _FEATURE_FLAGS"; then
  pass "features: _FEATURE_FLAGS covers all _FEATURE_ORDER items"
else
  fail "features: _FEATURE_FLAGS missing entries:$_missing"
fi

# ── _FEATURE_HAS_SCRIPTS entries exist in _FEATURE_FLAGS ─────────────────

_orphan=""
for _feat in "${!_FEATURE_HAS_SCRIPTS[@]}"; do
  if [[ -z "${_FEATURE_FLAGS[$_feat]+x}" ]]; then
    _orphan="$_orphan $_feat"
  fi
done
if assert_empty "$_orphan" "All _FEATURE_HAS_SCRIPTS entries should be in _FEATURE_FLAGS"; then
  pass "features: _FEATURE_HAS_SCRIPTS entries all exist in _FEATURE_FLAGS"
else
  fail "features: _FEATURE_HAS_SCRIPTS orphans:$_orphan"
fi

# ── _FEATURE_ORDER[0] is "safety-net" ────────────────────────────────────

if assert_equals "safety-net" "${_FEATURE_ORDER[0]}" "First feature must be safety-net"; then
  pass "features: _FEATURE_ORDER[0] is safety-net"
else
  fail "features: _FEATURE_ORDER[0] is '${_FEATURE_ORDER[0]}', expected 'safety-net'"
fi

# ── No duplicate entries in _FEATURE_ORDER ────────────────────────────────

declare -A _seen_features=()
_dupes=""
for _feat in "${_FEATURE_ORDER[@]}"; do
  if [[ -n "${_seen_features[$_feat]+x}" ]]; then
    _dupes="$_dupes $_feat"
  fi
  _seen_features[$_feat]=1
done
unset _seen_features
if assert_empty "$_dupes" "_FEATURE_ORDER should have no duplicates"; then
  pass "features: no duplicate entries in _FEATURE_ORDER"
else
  fail "features: duplicate entries in _FEATURE_ORDER:$_dupes"
fi

# ── All _FEATURE_FLAGS values start with ENABLE_ ─────────────────────────

_bad_prefix=""
for _feat in "${!_FEATURE_FLAGS[@]}"; do
  _flag="${_FEATURE_FLAGS[$_feat]}"
  if [[ "$_flag" != ENABLE_* ]]; then
    _bad_prefix="$_bad_prefix $_feat=$_flag"
  fi
done
if assert_empty "$_bad_prefix" "All _FEATURE_FLAGS values should start with ENABLE_"; then
  pass "features: all _FEATURE_FLAGS values have ENABLE_ prefix"
else
  fail "features: _FEATURE_FLAGS values missing ENABLE_ prefix:$_bad_prefix"
fi

# ── _FEATURE_HAS_SCRIPTS scripts directories actually exist ──────────────

_missing_dirs=""
for _feat in "${!_FEATURE_HAS_SCRIPTS[@]}"; do
  if [[ ! -d "$PROJECT_DIR/features/$_feat/scripts" ]]; then
    _missing_dirs="$_missing_dirs $_feat"
  fi
done
if assert_empty "$_missing_dirs" "All _FEATURE_HAS_SCRIPTS entries should have features/<name>/scripts/ directory"; then
  pass "features: all _FEATURE_HAS_SCRIPTS have scripts directories on disk"
else
  fail "features: missing scripts directories:$_missing_dirs"
fi

unset is_true
