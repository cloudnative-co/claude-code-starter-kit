#!/bin/bash
# tests/unit/test-wizard-utils.sh - Unit tests for wizard/wizard.sh utility functions
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded).
# wizard.sh sources lib/colors.sh and lib/detect.sh internally.

# Provide i18n stubs that wizard.sh label functions reference (used indirectly)
# shellcheck disable=SC2034
STR_ENABLED="Enabled"
# shellcheck disable=SC2034
STR_DISABLED="Disabled"
# shellcheck disable=SC2034
STR_YES="Yes"
# shellcheck disable=SC2034
STR_NO="No"
# shellcheck disable=SC2034
STR_EDITOR_VSCODE="VS Code"
# shellcheck disable=SC2034
STR_EDITOR_CURSOR="Cursor"
# shellcheck disable=SC2034
STR_EDITOR_ZED="Zed"
# shellcheck disable=SC2034
STR_EDITOR_NEOVIM="Neovim"
# shellcheck disable=SC2034
STR_EDITOR_NONE="None"
# shellcheck disable=SC2034
STR_PROFILE_MINIMAL="Minimal"
# shellcheck disable=SC2034
STR_PROFILE_STANDARD="Standard"
# shellcheck disable=SC2034
STR_PROFILE_FULL="Full"
# shellcheck disable=SC2034
STR_PROFILE_CUSTOM="Custom"

# shellcheck source=wizard/wizard.sh
source "$PROJECT_DIR/wizard/wizard.sh"

# ── _bool_normalize ───────────────────────────────────────────────────────

# Test: truthy values normalize to "true"
_all_pass=true
for _val in true True TRUE 1 yes Yes YES y Y on On ON; do
  run_func _bool_normalize "$_val"
  if ! assert_equals "true" "$_RF_STDOUT" "_bool_normalize('$_val') should be 'true'"; then
    _all_pass=false
  fi
done
if [[ "$_all_pass" == "true" ]]; then
  pass "wizard: _bool_normalize truthy values -> 'true'"
else
  fail "wizard: _bool_normalize truthy values -> 'true'"
fi

# Test: falsy values normalize to "false"
_all_pass=true
for _val in false False FALSE 0 no No NO n off Off OFF "" "random"; do
  run_func _bool_normalize "$_val"
  if ! assert_equals "false" "$_RF_STDOUT" "_bool_normalize('$_val') should be 'false'"; then
    _all_pass=false
  fi
done
if [[ "$_all_pass" == "true" ]]; then
  pass "wizard: _bool_normalize falsy values -> 'false'"
else
  fail "wizard: _bool_normalize falsy values -> 'false'"
fi

# ── _set_bool ─────────────────────────────────────────────────────────────

# Test: _set_bool sets variable via printf -v
_TEST_BOOL_VAR=""
run_func _set_bool _TEST_BOOL_VAR "yes"
if assert_equals "true" "$_TEST_BOOL_VAR" "_set_bool should set variable to 'true'"; then
  pass "wizard: _set_bool sets variable to normalized value"
else
  fail "wizard: _set_bool sets variable to normalized value (got '$_TEST_BOOL_VAR')"
fi

# Test: _set_bool rejects invalid variable names
run_func _set_bool "123invalid" "true"
if assert_exit_code 1 "$_RF_RC" "_set_bool should reject names starting with digit"; then
  pass "wizard: _set_bool rejects invalid variable names"
else
  fail "wizard: _set_bool should reject invalid variable names"
fi

# ── _sanitize_config_value ────────────────────────────────────────────────

# Test: safe characters pass through
run_func _sanitize_config_value "hello-world_123"
if assert_equals "hello-world_123" "$_RF_STDOUT"; then
  pass "wizard: _sanitize_config_value preserves safe characters"
else
  fail "wizard: _sanitize_config_value preserves safe characters (got '$_RF_STDOUT')"
fi

# Test: dangerous characters are stripped
run_func _sanitize_config_value 'value;rm -rf /$HOME'
# Only a-zA-Z0-9_,.:@/ - should remain
if assert_equals "valuerm -rf /HOME" "$_RF_STDOUT" \
  "_sanitize_config_value should strip shell metacharacters"; then
  pass "wizard: _sanitize_config_value strips dangerous characters"
else
  fail "wizard: _sanitize_config_value strips dangerous characters (got '$_RF_STDOUT')"
fi

# ── _safe_source_config ──────────────────────────────────────────────────

# Test: parses valid config file with allowlisted keys
_tmp="$(mktemp)"
printf 'LANGUAGE="en"\nPROFILE="standard"\n' > "$_tmp"
# Clear variables first
LANGUAGE=""
PROFILE=""
run_func _safe_source_config "$_tmp"
if assert_equals "en" "$LANGUAGE" && assert_equals "standard" "$PROFILE"; then
  pass "wizard: _safe_source_config parses allowlisted key=value pairs"
else
  fail "wizard: _safe_source_config parse failed (LANGUAGE='$LANGUAGE', PROFILE='$PROFILE')"
fi
rm -f "$_tmp"

# Test: ignores non-allowlisted keys
_tmp="$(mktemp)"
printf 'EVIL_KEY="malicious"\nLANGUAGE="ja"\n' > "$_tmp"
LANGUAGE=""
run_func _safe_source_config "$_tmp"
# EVIL_KEY should not be set
if assert_equals "ja" "$LANGUAGE"; then
  if [[ -z "${EVIL_KEY:-}" ]]; then
    pass "wizard: _safe_source_config ignores non-allowlisted keys"
  else
    fail "wizard: _safe_source_config set non-allowlisted key EVIL_KEY='$EVIL_KEY'"
  fi
else
  fail "wizard: _safe_source_config failed to parse alongside non-allowlisted key"
fi
rm -f "$_tmp"

# Test: skips comments and blank lines
_tmp="$(mktemp)"
printf '# This is a comment\n\nLANGUAGE="en"\n  # Another comment\nPROFILE="full"\n' > "$_tmp"
LANGUAGE=""
PROFILE=""
run_func _safe_source_config "$_tmp"
if assert_equals "en" "$LANGUAGE" && assert_equals "full" "$PROFILE"; then
  pass "wizard: _safe_source_config skips comments and blank lines"
else
  fail "wizard: _safe_source_config did not skip comments properly"
fi
rm -f "$_tmp"

# ── _display_width ────────────────────────────────────────────────────────

# Test: ASCII string width equals character count
run_func _display_width "hello"
if assert_equals "5" "$_RF_STDOUT" "ASCII 'hello' should have width 5"; then
  pass "wizard: _display_width ASCII string"
else
  fail "wizard: _display_width ASCII string (got '$_RF_STDOUT')"
fi

# Test: CJK string has greater display width than its character count
# _display_width uses (bytes - chars) / 2 as multibyte count, then chars + multibyte.
# On systems where wc -m correctly counts characters (LC_ALL=UTF-8), "日本語" = 6.
# On systems where wc -m returns byte count (LC_ALL=C), result equals byte count.
# Either way, the width must be > length of a 3-char ASCII string.
run_func _display_width "日本語"
_ascii_width=3  # "abc" would be 3
if [[ "$_RF_STDOUT" -gt "$_ascii_width" ]]; then
  pass "wizard: _display_width CJK string width ($_RF_STDOUT) > ASCII equivalent"
else
  fail "wizard: _display_width CJK string width '$_RF_STDOUT' should be > $_ascii_width"
fi

# Test: mixed ASCII + CJK has width greater than pure ASCII of same char count
run_func _display_width "aあb"
# "aあb" = 3 chars but "あ" is multibyte, so width should be > 3
_mixed_width="$_RF_STDOUT"
if [[ "$_mixed_width" -gt 3 ]]; then
  pass "wizard: _display_width mixed ASCII+CJK width ($_mixed_width) > char count"
else
  fail "wizard: _display_width mixed string width '$_mixed_width' should be > 3"
fi
