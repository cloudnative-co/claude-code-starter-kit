#!/bin/bash
# tests/unit/test-prerequisites.sh - Unit tests for lib/prerequisites.sh
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded).

# Source dependencies (prerequisites.sh requires colors.sh + detect.sh)
# shellcheck source=lib/colors.sh
source "$PROJECT_DIR/lib/colors.sh"
# shellcheck source=lib/detect.sh
source "$PROJECT_DIR/lib/detect.sh"
detect_os

# shellcheck source=lib/prerequisites.sh
source "$PROJECT_DIR/lib/prerequisites.sh"

# ── _get_shell_rc_file returns a valid path ───────────────────────────────

run_func _get_shell_rc_file
if assert_exit_code 0 "$_RF_RC" "_get_shell_rc_file should succeed"; then
  if assert_not_empty "$_RF_STDOUT" "_get_shell_rc_file should output a path"; then
    if assert_matches '\.(bashrc|zshrc|bash_profile|profile)$' "$_RF_STDOUT" \
      "RC file should end with a known RC name"; then
      pass "prerequisites: _get_shell_rc_file returns valid RC path ('$_RF_STDOUT')"
    else
      fail "prerequisites: _get_shell_rc_file returned unexpected path: '$_RF_STDOUT'"
    fi
  else
    fail "prerequisites: _get_shell_rc_file returned empty"
  fi
else
  fail "prerequisites: _get_shell_rc_file failed with rc=$_RF_RC"
fi

# ── _get_shell_rc_file path starts with HOME ──────────────────────────────

run_func _get_shell_rc_file
if [[ "$_RF_STDOUT" == "$HOME/"* ]]; then
  pass "prerequisites: _get_shell_rc_file path starts with \$HOME"
else
  fail "prerequisites: _get_shell_rc_file path does not start with \$HOME ('$_RF_STDOUT')"
fi

# ── _detect_bash4 finds a Bash 4+ binary ─────────────────────────────────

# We are running under Bash 4+ (run-unit-tests.sh enforces this),
# so _detect_bash4 should find at least the current shell.
run_func _detect_bash4
if assert_exit_code 0 "$_RF_RC" "_detect_bash4 should find Bash 4+"; then
  if assert_not_empty "$_RF_STDOUT" "_detect_bash4 should output a path"; then
    pass "prerequisites: _detect_bash4 finds Bash 4+ ('$_RF_STDOUT')"
  else
    fail "prerequisites: _detect_bash4 returned empty output"
  fi
else
  fail "prerequisites: _detect_bash4 could not find Bash 4+"
fi

# ── _add_to_path_now_and_persist with isolated HOME ──────────────────────

_saved_home="$HOME"
_saved_shell="$SHELL"
_tmpdir="$(mktemp -d)"
export HOME="$_tmpdir"
export SHELL="/bin/bash"

# Create the RC file so _add_to_path_now_and_persist can append to it
touch "$_tmpdir/.bashrc"

_test_dir="$_tmpdir/mybin"
mkdir -p "$_test_dir"

run_func _add_to_path_now_and_persist "$_test_dir"
if assert_exit_code 0 "$_RF_RC"; then
  # Check PATH contains the directory
  if [[ ":${PATH}:" == *":${_test_dir}:"* ]]; then
    # Check RC file was updated
    if assert_file_contains "$_tmpdir/.bashrc" "$_test_dir" \
      "RC file should contain the added path"; then
      pass "prerequisites: _add_to_path_now_and_persist adds to PATH and RC file"
    else
      fail "prerequisites: _add_to_path_now_and_persist did not update RC file"
    fi
  else
    fail "prerequisites: _add_to_path_now_and_persist did not add to PATH"
  fi
else
  fail "prerequisites: _add_to_path_now_and_persist failed with rc=$_RF_RC"
fi

# Restore
export HOME="$_saved_home"
export SHELL="$_saved_shell"
# Remove the test dir from PATH
PATH="${PATH//:$_test_dir:/:}"; PATH="${PATH/#$_test_dir:/}"; PATH="${PATH/%:$_test_dir/}"; export PATH
rm -rf "$_tmpdir"

# ── _add_to_path_now_and_persist is idempotent ───────────────────────────

_saved_home="$HOME"
_saved_shell="$SHELL"
_tmpdir="$(mktemp -d)"
export HOME="$_tmpdir"
export SHELL="/bin/bash"
touch "$_tmpdir/.bashrc"

_test_dir="$_tmpdir/mybin2"
mkdir -p "$_test_dir"

# Call twice
_add_to_path_now_and_persist "$_test_dir"
_add_to_path_now_and_persist "$_test_dir"

_line_count="$(grep -c "$_test_dir" "$_tmpdir/.bashrc")"
if assert_equals "1" "$_line_count" "RC file should contain path only once"; then
  pass "prerequisites: _add_to_path_now_and_persist is idempotent"
else
  fail "prerequisites: _add_to_path_now_and_persist wrote path $_line_count times"
fi

export HOME="$_saved_home"
export SHELL="$_saved_shell"
PATH="${PATH//:$_test_dir:/:}"; PATH="${PATH/#$_test_dir:/}"; PATH="${PATH/%:$_test_dir/}"; export PATH
rm -rf "$_tmpdir"
