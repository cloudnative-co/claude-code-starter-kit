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

# ══════════════════════════════════════════════════════════════════════════
# _detect_and_write_pending_features: preserve existing EXIT trap
# ══════════════════════════════════════════════════════════════════════════

_rec_tmp="$(mktemp -d)"
_SETUP_TMP_FILES+=("$_rec_tmp")
# shellcheck disable=SC2034  # consumed by sourced features.sh
PROFILE="minimal"
PROJECT_DIR="$PROJECT_DIR"
DISMISSED_FEATURES=""
# shellcheck source=lib/features.sh
source "$PROJECT_DIR/lib/features.sh"
for _rec_feat in "${_FEATURE_ORDER[@]}"; do
  _rec_flag="${_FEATURE_FLAGS[$_rec_feat]}"
  printf -v "$_rec_flag" '%s' ""
done
trap 'printf cleanup >/dev/null' EXIT
_rec_trap_before="$(trap -p EXIT)"
run_func _detect_and_write_pending_features "$_rec_tmp"
_rec_trap_after="$(trap -p EXIT)"
trap - EXIT

if [[ "$_RF_RC" -eq 0 ]] \
  && assert_equals "$_rec_trap_before" "$_rec_trap_after" \
  && assert_file_exists "$_rec_tmp/.starter-kit-pending-features.json" \
  && jq -e '.version == 1 and (.kit_version | type == "string")' \
    "$_rec_tmp/.starter-kit-pending-features.json" >/dev/null 2>&1; then
  pass "recommendation: pending feature detection preserves existing EXIT trap"
else
  fail "recommendation: pending feature detection should not replace EXIT trap"
fi

# ══════════════════════════════════════════════════════════════════════════
# _detect_and_write_pending_features: shared pending document
# ══════════════════════════════════════════════════════════════════════════

_rec_pending="$_rec_tmp/.starter-kit-pending-features.json"

# Full clears only its own key; plugin recommendations and unrelated metadata
# still belong to the other writer/reader and must survive.
printf '%s' '{"version":1,"kit_version":"old","features":["stale"],"plugins":["alpha"],"meta":{"keep":true}}' \
  > "$_rec_pending"
PROFILE="full"
run_func _detect_and_write_pending_features "$_rec_tmp"
if [[ "$_RF_RC" -eq 0 ]] \
  && jq -e 'has("features") | not' "$_rec_pending" >/dev/null 2>&1 \
  && jq -e '.plugins == ["alpha"] and .meta.keep == true and .kit_version == "old"' \
    "$_rec_pending" >/dev/null 2>&1; then
  pass "recommendation: full profile clears only features from a mixed pending file"
else
  fail "recommendation: full profile must preserve pending plugins and metadata"
fi

# Turning the reader off has the same ownership rule: do not consume a plugin
# offer that can become visible again if the reader is re-enabled.
printf '%s' '{"features":["stale"],"plugins":["alpha"],"meta":"keep"}' > "$_rec_pending"
PROFILE="minimal"
ENABLE_FEATURE_RECOMMENDATION="false"
run_func _detect_and_write_pending_features "$_rec_tmp"
if [[ "$_RF_RC" -eq 0 ]] \
  && jq -e 'has("features") | not' "$_rec_pending" >/dev/null 2>&1 \
  && jq -e '.plugins == ["alpha"] and .meta == "keep"' "$_rec_pending" >/dev/null 2>&1; then
  pass "recommendation: disabled reader clears only features from a mixed pending file"
else
  fail "recommendation: disabled reader must preserve pending plugins"
fi

# The ordinary no-new-feature path must also retain plugins. Set every feature
# flag non-empty so none qualifies as newly introduced.
ENABLE_FEATURE_RECOMMENDATION="true"
PROFILE="minimal"
for _rec_feat in "${_FEATURE_ORDER[@]}"; do
  _rec_flag="${_FEATURE_FLAGS[$_rec_feat]}"
  printf -v "$_rec_flag" '%s' "true"
done
printf '%s' '{"features":["stale"],"plugins":["alpha"],"meta":7}' > "$_rec_pending"
run_func _detect_and_write_pending_features "$_rec_tmp"
if [[ "$_RF_RC" -eq 0 ]] \
  && jq -e 'has("features") | not' "$_rec_pending" >/dev/null 2>&1 \
  && jq -e '.plugins == ["alpha"] and .meta == 7' "$_rec_pending" >/dev/null 2>&1; then
  pass "recommendation: no-new-feature cleanup preserves pending plugins"
else
  fail "recommendation: no-new-feature cleanup must not consume plugins"
fi

# A feature write merges into the same document, retains the plugin payload and
# metadata, replaces stale features, and leaves a private regular file.
for _rec_feat in "${_FEATURE_ORDER[@]}"; do
  _rec_flag="${_FEATURE_FLAGS[$_rec_feat]}"
  printf -v "$_rec_flag" '%s' ""
done
printf '%s' '{"version":2,"kit_version":"old","features":["stale"],"plugins":["alpha"],"meta":{"keep":true}}' \
  > "$_rec_pending"
run_func _detect_and_write_pending_features "$_rec_tmp"
_rec_mode="$(test_stat_mode "$_rec_pending")"
if [[ "$_RF_RC" -eq 0 ]] \
  && jq -e '.features | length > 0 and index("stale") == null' "$_rec_pending" >/dev/null 2>&1 \
  && jq -e '.plugins == ["alpha"] and .meta.keep == true
    and .version == 2 and .kit_version == "old"' "$_rec_pending" >/dev/null 2>&1 \
  && assert_equals "600" "$_rec_mode" \
  && [[ -z "$(find "$_rec_tmp" -name '.starter-kit-pending-features.json.tmp.*' -print)" ]]; then
  pass "recommendation: feature write atomically preserves plugins and metadata"
else
  fail "recommendation: feature write must merge the shared document with mode 0600"
fi

# Without either payload, the shared notification is just stale metadata and
# can be removed.
printf '%s' '{"features":["stale"],"meta":"obsolete"}' > "$_rec_pending"
PROFILE="full"
run_func _detect_and_write_pending_features "$_rec_tmp"
if [[ "$_RF_RC" -eq 0 ]] && [[ ! -e "$_rec_pending" ]]; then
  pass "recommendation: empty shared payload removes the pending file"
else
  fail "recommendation: a pending file with neither payload should be removed"
fi

# Malformed JSON and invalid recommendation shapes are not repaired in place:
# preserving the original lets a later trusted path diagnose/recover it.
printf '%s' '{not-json' > "$_rec_pending"
cp "$_rec_pending" "$_rec_tmp/malformed.before"
run_func _detect_and_write_pending_features "$_rec_tmp"
if [[ "$_RF_RC" -ne 0 ]] && cmp -s "$_rec_pending" "$_rec_tmp/malformed.before"; then
  pass "recommendation: malformed JSON fails closed without destroying the original"
else
  fail "recommendation: malformed pending JSON must remain untouched"
fi

printf '%s' '{"features":[],"plugins":"not-an-array","meta":"keep"}' > "$_rec_pending"
cp "$_rec_pending" "$_rec_tmp/invalid-shape.before"
run_func _detect_and_write_pending_features "$_rec_tmp"
if [[ "$_RF_RC" -ne 0 ]] && cmp -s "$_rec_pending" "$_rec_tmp/invalid-shape.before"; then
  pass "recommendation: invalid pending shape fails closed"
else
  fail "recommendation: invalid pending arrays must remain untouched"
fi

# Never follow a pending-file symlink. The link and its target both survive.
printf '%s' '{"features":["target"],"plugins":["alpha"]}' > "$_rec_tmp/symlink-target"
rm -f "$_rec_pending"
ln -s "$_rec_tmp/symlink-target" "$_rec_pending"
cp "$_rec_tmp/symlink-target" "$_rec_tmp/symlink-target.before"
run_func _detect_and_write_pending_features "$_rec_tmp"
if [[ "$_RF_RC" -ne 0 ]] && [[ -L "$_rec_pending" ]] \
  && cmp -s "$_rec_tmp/symlink-target" "$_rec_tmp/symlink-target.before"; then
  pass "recommendation: special pending file fails closed without following it"
else
  fail "recommendation: a pending symlink and its target must remain untouched"
fi

rm -f "$_rec_pending"
unset _rec_pending _rec_mode
# shellcheck disable=SC2034 # Later sourced tests read this shared global.
PROFILE="minimal"
# shellcheck disable=SC2034 # Later sourced tests read this shared global.
ENABLE_FEATURE_RECOMMENDATION=""
