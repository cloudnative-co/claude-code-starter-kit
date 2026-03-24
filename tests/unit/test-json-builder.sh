#!/bin/bash
# tests/unit/test-json-builder.sh - Unit tests for lib/json-builder.sh
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded).
# Requires: jq

# Source dependencies
# shellcheck source=lib/colors.sh
source "$PROJECT_DIR/lib/colors.sh"

# Provide _SETUP_TMP_FILES so _register_tmp works
declare -a _SETUP_TMP_FILES=()

# shellcheck source=lib/json-builder.sh
source "$PROJECT_DIR/lib/json-builder.sh"

# ── validate_json ─────────────────────────────────────────────────────────

# Test: validate_json accepts valid JSON
_tmp="$(mktemp)"
printf '{"key": "value"}' > "$_tmp"
run_func validate_json "$_tmp"
if assert_exit_code 0 "$_RF_RC" "validate_json should accept valid JSON"; then
  pass "validate_json: valid JSON returns 0"
else
  fail "validate_json: valid JSON returns 0"
fi
rm -f "$_tmp"

# Test: validate_json rejects invalid JSON
_tmp="$(mktemp)"
printf '{broken' > "$_tmp"
run_func validate_json "$_tmp"
if assert_exit_code 1 "$_RF_RC" "validate_json should reject invalid JSON"; then
  pass "validate_json: invalid JSON returns 1"
else
  fail "validate_json: invalid JSON returns 1"
fi
rm -f "$_tmp"

# Test: validate_json rejects missing file
run_func validate_json "/nonexistent/file.json"
if assert_exit_code 1 "$_RF_RC" "validate_json should fail for missing file"; then
  pass "validate_json: missing file returns 1"
else
  fail "validate_json: missing file returns 1"
fi

# ── replace_home_path ─────────────────────────────────────────────────────

# Test: replace_home_path substitutes __HOME__ with $HOME
_tmp="$(mktemp)"
printf '{"path": "__HOME__/.claude/hooks/test.sh"}' > "$_tmp"
run_func replace_home_path "$_tmp"
_actual="$(jq -r '.path' "$_tmp")"
if assert_equals "$HOME/.claude/hooks/test.sh" "$_actual" "replace_home_path should substitute __HOME__"; then
  pass "replace_home_path: substitutes __HOME__ with \$HOME"
else
  fail "replace_home_path: substitutes __HOME__ with \$HOME"
fi
rm -f "$_tmp"

# Test: replace_home_path handles multiple __HOME__ occurrences
_tmp="$(mktemp)"
printf '{"a": "__HOME__/one", "b": "__HOME__/two"}' > "$_tmp"
run_func replace_home_path "$_tmp"
_a="$(jq -r '.a' "$_tmp")"
_b="$(jq -r '.b' "$_tmp")"
if assert_equals "$HOME/one" "$_a" && assert_equals "$HOME/two" "$_b"; then
  pass "replace_home_path: handles multiple __HOME__ in one file"
else
  fail "replace_home_path: handles multiple __HOME__ in one file"
fi
rm -f "$_tmp"

# Test: replace_home_path returns 1 for missing file
run_func replace_home_path "/nonexistent/file.json"
if assert_exit_code 1 "$_RF_RC" "replace_home_path should fail for missing file"; then
  pass "replace_home_path: missing file returns 1"
else
  fail "replace_home_path: missing file returns 1"
fi

# ── build_settings_json (base + permissions, no fragments) ────────────────

# Test: build_settings_json merges base and permissions
_base="$(mktemp)"
_perms="$(mktemp)"
_out="$(mktemp)"
printf '{"a": 1, "hooks": {}}' > "$_base"
printf '{"b": 2}' > "$_perms"
run_func build_settings_json "$_base" "$_perms" "$_out"
if assert_exit_code 0 "$_RF_RC"; then
  _a_val="$(jq -r '.a' "$_out")"
  _b_val="$(jq -r '.b' "$_out")"
  if assert_equals "1" "$_a_val" && assert_equals "2" "$_b_val"; then
    pass "build_settings_json: merges base + permissions"
  else
    fail "build_settings_json: merges base + permissions"
  fi
else
  fail "build_settings_json: merges base + permissions"
fi
rm -f "$_base" "$_perms" "$_out"

# ── build_settings_json with hook fragments (merge_deep) ──────────────────

# Test: merge_deep concatenates arrays
_base="$(mktemp)"
_perms="$(mktemp)"
_out="$(mktemp)"
_frag1="$(mktemp)"
_frag2="$(mktemp)"
printf '{"hooks": {"PreToolUse": [{"cmd": "first"}]}}' > "$_base"
printf '{}' > "$_perms"
printf '{"hooks": {"PreToolUse": [{"cmd": "second"}]}}' > "$_frag1"
printf '{"hooks": {"PreToolUse": [{"cmd": "third"}]}}' > "$_frag2"
run_func build_settings_json "$_base" "$_perms" "$_out" "$_frag1" "$_frag2"
if assert_exit_code 0 "$_RF_RC"; then
  _count="$(jq '.hooks.PreToolUse | length' "$_out")"
  if assert_equals "3" "$_count" "merge_deep should concatenate arrays"; then
    pass "build_settings_json: merge_deep concatenates hook arrays"
  else
    fail "build_settings_json: merge_deep concatenates hook arrays (got $_count)"
  fi
else
  fail "build_settings_json: merge_deep concatenates hook arrays"
fi
rm -f "$_base" "$_perms" "$_out" "$_frag1" "$_frag2"

# Test: merge_deep deep-merges nested objects
_base="$(mktemp)"
_perms="$(mktemp)"
_out="$(mktemp)"
_frag="$(mktemp)"
printf '{"env": {"A": "1"}}' > "$_base"
printf '{}' > "$_perms"
printf '{"env": {"B": "2"}}' > "$_frag"
run_func build_settings_json "$_base" "$_perms" "$_out" "$_frag"
if assert_exit_code 0 "$_RF_RC"; then
  _a="$(jq -r '.env.A' "$_out")"
  _b="$(jq -r '.env.B' "$_out")"
  if assert_equals "1" "$_a" && assert_equals "2" "$_b"; then
    pass "build_settings_json: merge_deep preserves existing keys in nested objects"
  else
    fail "build_settings_json: merge_deep preserves existing keys in nested objects"
  fi
else
  fail "build_settings_json: merge_deep preserves existing keys in nested objects"
fi
rm -f "$_base" "$_perms" "$_out" "$_frag"

# Test: build_settings_json skips invalid fragment files
_base="$(mktemp)"
_perms="$(mktemp)"
_out="$(mktemp)"
_bad="$(mktemp)"
printf '{"ok": true}' > "$_base"
printf '{}' > "$_perms"
printf '{broken' > "$_bad"
run_func build_settings_json "$_base" "$_perms" "$_out" "$_bad"
if assert_exit_code 0 "$_RF_RC"; then
  _val="$(jq -r '.ok' "$_out")"
  if assert_equals "true" "$_val"; then
    pass "build_settings_json: skips invalid fragment, keeps base"
  else
    fail "build_settings_json: skips invalid fragment, keeps base"
  fi
else
  fail "build_settings_json: skips invalid fragment, keeps base"
fi
rm -f "$_base" "$_perms" "$_out" "$_bad"

# Cleanup tracking array
unset _SETUP_TMP_FILES
