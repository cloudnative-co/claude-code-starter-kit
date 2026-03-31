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

# ── _install_bash4 uses package installer when needed ────────────────────

_orig_pkg_install="$(declare -f _pkg_install)"
_pkg_install() { [[ "$1" == "bash" ]]; }
run_func _install_bash4
if assert_exit_code 0 "$_RF_RC" "_install_bash4 should install bash via package manager"; then
  pass "prerequisites: _install_bash4 delegates to package installer"
else
  fail "prerequisites: _install_bash4 did not succeed"
fi
eval "$_orig_pkg_install"

# ── check_tmux auto-installs when missing ────────────────────────────────

_saved_path="$PATH"
_tmpdir="$(mktemp -d)"
export PATH="$_tmpdir:$_saved_path"
_orig_pkg_install="$(declare -f _pkg_install)"
_pkg_install() {
  if [[ "$1" == "tmux" ]]; then
    cat > "$_tmpdir/tmux" <<'EOF'
#!/bin/bash
echo "tmux 3.4"
EOF
    chmod +x "$_tmpdir/tmux"
    return 0
  fi
  return 1
}
run_func check_tmux
if assert_exit_code 0 "$_RF_RC" \
  && command -v tmux >/dev/null 2>&1; then
  pass "prerequisites: check_tmux auto-installs tmux when missing"
else
  fail "prerequisites: check_tmux did not auto-install tmux"
fi
eval "$_orig_pkg_install"
export PATH="$_saved_path"
rm -rf "$_tmpdir"

# ── check_node fails when auto-install fails ─────────────────────────────

_orig_install_node="$(declare -f _install_node)"
_install_node() { return 1; }
command() {
  if [[ "$1" == "-v" && "$2" == "node" ]]; then
    return 1
  fi
  builtin command "$@"
}
run_func check_node
if assert_exit_code 1 "$_RF_RC" "check_node should fail when auto-install fails"; then
  pass "prerequisites: check_node fails when Node.js auto-install fails"
else
  fail "prerequisites: check_node unexpectedly succeeded on install failure"
fi
unset -f command
eval "$_orig_install_node"

# ── check_gh auto-installs when missing ──────────────────────────────────

_saved_path="$PATH"
_tmpdir="$(mktemp -d)"
export PATH="$_tmpdir:$_saved_path"
_orig_pkg_install="$(declare -f _pkg_install)"
_pkg_install() {
  if [[ "$1" == "gh" ]]; then
    cat > "$_tmpdir/gh" <<'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
  echo "gh version 2.83.2"
fi
EOF
    chmod +x "$_tmpdir/gh"
    return 0
  fi
  return 1
}
run_func check_gh
if assert_exit_code 0 "$_RF_RC" \
  && command -v gh >/dev/null 2>&1; then
  pass "prerequisites: check_gh auto-installs gh when missing"
else
  fail "prerequisites: check_gh did not auto-install gh"
fi
eval "$_orig_pkg_install"
export PATH="$_saved_path"
rm -rf "$_tmpdir"

# ── check_dos2unix fails on WSL when auto-install fails ──────────────────

_saved_is_wsl="${IS_WSL:-false}"
IS_WSL="true"
_saved_path="$PATH"
_tmpdir="$(mktemp -d)"
export PATH="$_tmpdir:$_saved_path"
_orig_pkg_install="$(declare -f _pkg_install)"
_pkg_install() { return 1; }
run_func check_dos2unix
if assert_exit_code 1 "$_RF_RC" "check_dos2unix should fail when WSL install fails"; then
  pass "prerequisites: check_dos2unix fails when dos2unix auto-install fails on WSL"
else
  fail "prerequisites: check_dos2unix unexpectedly succeeded on install failure"
fi
eval "$_orig_pkg_install"
IS_WSL="$_saved_is_wsl"
export PATH="$_saved_path"
rm -rf "$_tmpdir"
