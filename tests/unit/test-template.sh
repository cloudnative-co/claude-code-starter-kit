#!/bin/bash
# tests/unit/test-template.sh - Unit tests for lib/template.sh
#
# Sourced by run-unit-tests.sh. Assumes helpers.sh is already loaded.
# Dependencies: lib/colors.sh, lib/template.sh

# Source dependencies
source "$PROJECT_DIR/lib/colors.sh"

# Provide _sed/_awk stubs (template.sh uses them, normally from prerequisites.sh)
_GNU_SED=""
_GNU_AWK=""
_sed() { sed "$@"; }
_awk() { awk "$@"; }

# _register_tmp needs this array (normally declared by setup.sh)
declare -a _SETUP_TMP_FILES=()

source "$PROJECT_DIR/lib/template.sh"

# =========================================================================
# _has_kit_markers
# =========================================================================

test_has_kit_markers_returns_0_when_markers_present() {
  local tmp; tmp="$(mktemp)"
  printf '%s\nsome content\n%s\n' "$_KIT_MARKER_BEGIN" "$_KIT_MARKER_END" > "$tmp"
  if _has_kit_markers "$tmp"; then
    pass "has_kit_markers: returns 0 when markers present"
  else
    fail "has_kit_markers: returns 0 when markers present"
  fi
  rm -f "$tmp"
}
test_has_kit_markers_returns_0_when_markers_present

test_has_kit_markers_returns_1_when_no_markers() {
  local tmp; tmp="$(mktemp)"
  printf 'no markers here\njust plain text\n' > "$tmp"
  if _has_kit_markers "$tmp"; then
    fail "has_kit_markers: returns 1 when no markers"
  else
    pass "has_kit_markers: returns 1 when no markers"
  fi
  rm -f "$tmp"
}
test_has_kit_markers_returns_1_when_no_markers

test_has_kit_markers_returns_1_for_nonexistent_file() {
  if _has_kit_markers "/nonexistent/file/path"; then
    fail "has_kit_markers: returns 1 for nonexistent file"
  else
    pass "has_kit_markers: returns 1 for nonexistent file"
  fi
}
test_has_kit_markers_returns_1_for_nonexistent_file

# =========================================================================
# _extract_kit_section
# =========================================================================

test_extract_kit_section_returns_content_between_markers() {
  local tmp; tmp="$(mktemp)"
  printf 'before\n%s\nkit line 1\nkit line 2\n%s\nafter\n' \
    "$_KIT_MARKER_BEGIN" "$_KIT_MARKER_END" > "$tmp"
  run_func _extract_kit_section "$tmp"
  local expected
  expected="$(printf '%s\nkit line 1\nkit line 2\n%s' "$_KIT_MARKER_BEGIN" "$_KIT_MARKER_END")"
  if assert_equals "$expected" "$_RF_STDOUT"; then
    pass "extract_kit_section: returns content between markers (inclusive)"
  else
    fail "extract_kit_section: returns content between markers (inclusive)"
  fi
  rm -f "$tmp"
}
test_extract_kit_section_returns_content_between_markers

test_extract_kit_section_fails_without_markers() {
  local tmp; tmp="$(mktemp)"
  printf 'no markers\n' > "$tmp"
  run_func _extract_kit_section "$tmp"
  if assert_equals "1" "$_RF_RC"; then
    pass "extract_kit_section: returns 1 without markers"
  else
    fail "extract_kit_section: returns 1 without markers"
  fi
  rm -f "$tmp"
}
test_extract_kit_section_fails_without_markers

# =========================================================================
# _extract_user_section
# =========================================================================

test_extract_user_section_returns_content_after_end_marker() {
  local tmp; tmp="$(mktemp)"
  printf '%s\nkit content\n%s\nuser line 1\nuser line 2\n' \
    "$_KIT_MARKER_BEGIN" "$_KIT_MARKER_END" > "$tmp"
  run_func _extract_user_section "$tmp"
  local expected
  expected="$(printf 'user line 1\nuser line 2')"
  if assert_equals "$expected" "$_RF_STDOUT"; then
    pass "extract_user_section: returns content after END marker"
  else
    fail "extract_user_section: returns content after END marker"
  fi
  rm -f "$tmp"
}
test_extract_user_section_returns_content_after_end_marker

test_extract_user_section_returns_whole_file_without_markers() {
  local tmp; tmp="$(mktemp)"
  printf 'line 1\nline 2\n' > "$tmp"
  run_func _extract_user_section "$tmp"
  local expected
  expected="$(printf 'line 1\nline 2')"
  if assert_equals "$expected" "$_RF_STDOUT"; then
    pass "extract_user_section: returns whole file without markers"
  else
    fail "extract_user_section: returns whole file without markers"
  fi
  rm -f "$tmp"
}
test_extract_user_section_returns_whole_file_without_markers

test_extract_user_section_returns_empty_when_nothing_after_marker() {
  local tmp; tmp="$(mktemp)"
  printf '%s\nkit only\n%s\n' "$_KIT_MARKER_BEGIN" "$_KIT_MARKER_END" > "$tmp"
  run_func _extract_user_section "$tmp"
  if assert_empty "$_RF_STDOUT"; then
    pass "extract_user_section: empty when nothing after END marker"
  else
    fail "extract_user_section: empty when nothing after END marker"
  fi
  rm -f "$tmp"
}
test_extract_user_section_returns_empty_when_nothing_after_marker

# =========================================================================
# _replace_kit_section
# =========================================================================

test_replace_kit_section_swaps_kit_content_preserves_user() {
  local tmp; tmp="$(mktemp)"
  local new_kit; new_kit="$(mktemp)"
  printf 'preamble\n%s\nold kit\n%s\nuser stuff\n' \
    "$_KIT_MARKER_BEGIN" "$_KIT_MARKER_END" > "$tmp"
  printf '%s\nnew kit content\n%s\n' "$_KIT_MARKER_BEGIN" "$_KIT_MARKER_END" > "$new_kit"

  _replace_kit_section "$tmp" "$new_kit"
  cat "$tmp" > /dev/null  # verify file is readable

  if assert_file_contains "$tmp" "new kit content" && \
     assert_file_not_contains "$tmp" "old kit" && \
     assert_file_contains "$tmp" "user stuff" && \
     assert_file_contains "$tmp" "preamble"; then
    pass "replace_kit_section: swaps kit content, preserves surrounding"
  else
    fail "replace_kit_section: swaps kit content, preserves surrounding"
  fi
  rm -f "$tmp" "$new_kit"
}
test_replace_kit_section_swaps_kit_content_preserves_user

# =========================================================================
# process_template
# =========================================================================

test_process_template_replaces_placeholders_stdout() {
  local tmpl; tmpl="$(mktemp)"
  local conf; conf="$(mktemp)"
  printf 'Hello {{NAME}}, welcome to {{PROJECT}}!\n' > "$tmpl"
  printf 'NAME=World\nPROJECT=Test\n' > "$conf"

  run_func process_template "$tmpl" "$conf"
  if assert_equals "Hello World, welcome to Test!" "$_RF_STDOUT"; then
    pass "process_template: replaces placeholders (stdout)"
  else
    fail "process_template: replaces placeholders (stdout)"
  fi
  rm -f "$tmpl" "$conf"
}
test_process_template_replaces_placeholders_stdout

test_process_template_writes_to_output_file() {
  local tmpl; tmpl="$(mktemp)"
  local conf; conf="$(mktemp)"
  local out; out="$(mktemp)"
  printf 'Value is {{VAL}}\n' > "$tmpl"
  printf 'VAL=42\n' > "$conf"

  process_template "$tmpl" "$conf" "$out"
  if assert_file_contains "$out" "Value is 42"; then
    pass "process_template: writes to output file"
  else
    fail "process_template: writes to output file"
  fi
  rm -f "$tmpl" "$conf" "$out"
}
test_process_template_writes_to_output_file

test_process_template_skips_comments_and_blanks_in_config() {
  local tmpl; tmpl="$(mktemp)"
  local conf; conf="$(mktemp)"
  printf '{{A}} and {{B}}\n' > "$tmpl"
  printf '# this is a comment\n\nA=alpha\nB=beta\n' > "$conf"

  run_func process_template "$tmpl" "$conf"
  if assert_equals "alpha and beta" "$_RF_STDOUT"; then
    pass "process_template: skips comments and blank lines"
  else
    fail "process_template: skips comments and blank lines"
  fi
  rm -f "$tmpl" "$conf"
}
test_process_template_skips_comments_and_blanks_in_config

test_process_template_fails_on_missing_template() {
  local conf; conf="$(mktemp)"
  printf 'X=1\n' > "$conf"
  run_func process_template "/nonexistent/template" "$conf"
  if assert_equals "1" "$_RF_RC"; then
    pass "process_template: returns 1 for missing template"
  else
    fail "process_template: returns 1 for missing template"
  fi
  rm -f "$conf"
}
test_process_template_fails_on_missing_template

test_process_template_fails_on_missing_config() {
  local tmpl; tmpl="$(mktemp)"
  printf 'hello\n' > "$tmpl"
  run_func process_template "$tmpl" "/nonexistent/config"
  if assert_equals "1" "$_RF_RC"; then
    pass "process_template: returns 1 for missing config"
  else
    fail "process_template: returns 1 for missing config"
  fi
  rm -f "$tmpl"
}
test_process_template_fails_on_missing_config

# =========================================================================
# inject_feature
# =========================================================================

test_inject_feature_replaces_marker_with_partial() {
  local target; target="$(mktemp)"
  local partial; partial="$(mktemp)"
  printf 'before\n{{FEATURE:myfeature}}\nafter\n' > "$target"
  printf 'injected content\n' > "$partial"

  inject_feature "$target" "myfeature" "$partial"
  if assert_file_contains "$target" "injected content" && \
     assert_file_not_contains "$target" '{{FEATURE:myfeature}}' && \
     assert_file_contains "$target" "before" && \
     assert_file_contains "$target" "after"; then
    pass "inject_feature: replaces marker with partial content"
  else
    fail "inject_feature: replaces marker with partial content"
  fi
  rm -f "$target" "$partial"
}
test_inject_feature_replaces_marker_with_partial

test_inject_feature_skips_missing_marker() {
  local target; target="$(mktemp)"
  local partial; partial="$(mktemp)"
  printf 'no marker here\n' > "$target"
  printf 'partial\n' > "$partial"

  run_func inject_feature "$target" "absent" "$partial"
  if assert_equals "0" "$_RF_RC" && assert_file_contains "$target" "no marker here"; then
    pass "inject_feature: skips gracefully when marker absent"
  else
    fail "inject_feature: skips gracefully when marker absent"
  fi
  rm -f "$target" "$partial"
}
test_inject_feature_skips_missing_marker

test_inject_feature_skips_missing_partial_file() {
  local target; target="$(mktemp)"
  printf '{{FEATURE:gone}}\n' > "$target"

  run_func inject_feature "$target" "gone" "/nonexistent/partial"
  if assert_equals "0" "$_RF_RC"; then
    pass "inject_feature: returns 0 when partial file missing"
  else
    fail "inject_feature: returns 0 when partial file missing"
  fi
  rm -f "$target"
}
test_inject_feature_skips_missing_partial_file

# =========================================================================
# remove_unresolved
# =========================================================================

test_remove_unresolved_replaces_markers_with_empty() {
  local tmp; tmp="$(mktemp)"
  printf 'keep this\nprefix {{GONE}} suffix\nend\n' > "$tmp"

  remove_unresolved "$tmp"
  if assert_file_contains "$tmp" "prefix  suffix" && \
     assert_file_not_contains "$tmp" '{{GONE}}'; then
    pass "remove_unresolved: replaces markers with empty (default mode)"
  else
    fail "remove_unresolved: replaces markers with empty (default mode)"
  fi
  rm -f "$tmp"
}
test_remove_unresolved_replaces_markers_with_empty

test_remove_unresolved_delete_mode_removes_lines() {
  local tmp; tmp="$(mktemp)"
  printf 'keep\n{{REMOVE_ME}}\nalso keep\n' > "$tmp"

  remove_unresolved "$tmp" "delete"
  if assert_file_contains "$tmp" "keep" && \
     assert_file_contains "$tmp" "also keep" && \
     assert_file_not_contains "$tmp" '{{REMOVE_ME}}'; then
    pass "remove_unresolved: delete mode removes entire lines"
  else
    fail "remove_unresolved: delete mode removes entire lines"
  fi
  rm -f "$tmp"
}
test_remove_unresolved_delete_mode_removes_lines

# =========================================================================
# _user_section_heading
# =========================================================================

test_user_section_heading_english() {
  LANGUAGE="en"
  run_func _user_section_heading
  if assert_equals "# User Settings" "$_RF_STDOUT"; then
    pass "_user_section_heading: returns English heading"
  else
    fail "_user_section_heading: returns English heading"
  fi
}
test_user_section_heading_english

test_user_section_heading_japanese() {
  LANGUAGE="ja"
  run_func _user_section_heading
  if assert_equals "# ユーザー設定" "$_RF_STDOUT"; then
    pass "_user_section_heading: returns Japanese heading"
  else
    fail "_user_section_heading: returns Japanese heading"
  fi
  LANGUAGE="en"  # reset
}
test_user_section_heading_japanese
