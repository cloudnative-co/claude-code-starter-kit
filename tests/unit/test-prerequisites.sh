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

# ── _get_shell_rc_file and _get_shell_rc_files shell choices ──────────────

_saved_shell="$SHELL"
_saved_os="${OS:-}"
export SHELL="/bin/bash"
OS="macos"

run_func _get_shell_rc_file
if assert_equals "$HOME/.bash_profile" "$_RF_STDOUT"; then
  pass "prerequisites: _get_shell_rc_file uses .bash_profile for macOS bash"
else
  fail "prerequisites: _get_shell_rc_file did not use .bash_profile for macOS bash"
fi

_tmp_rc_home="$(mktemp -d)"
_saved_home_for_rc="$HOME"
export HOME="$_tmp_rc_home"
run_func _get_shell_rc_files
if [[ "$_RF_STDOUT" == *"$HOME/.bash_profile"* && "$_RF_STDOUT" == *"$HOME/.bashrc"* ]]; then
  pass "prerequisites: _get_shell_rc_files covers login and non-login macOS bash"
else
  fail "prerequisites: _get_shell_rc_files did not cover both macOS bash files"
fi

printf '%s\n' '[[ -f "$HOME/.bashrc" ]] && . "$HOME/.bashrc"' > "$HOME/.bash_profile"
run_func _get_shell_rc_files
if assert_equals "$HOME/.bashrc" "$_RF_STDOUT"; then
  pass "prerequisites: _get_shell_rc_files avoids duplicate PATH when bash_profile sources bashrc"
else
  fail "prerequisites: _get_shell_rc_files did not avoid duplicate sourced bashrc"
fi

printf '%s\n' 'source "${HOME}/.bashrc"' > "$HOME/.bash_profile"
run_func _get_shell_rc_files
if assert_equals "$HOME/.bashrc" "$_RF_STDOUT"; then
  pass "prerequisites: _get_shell_rc_files recognizes braced HOME bashrc source"
else
  fail "prerequisites: _get_shell_rc_files missed braced HOME bashrc source"
fi

printf '%s\n' '# source ~/.bashrc' > "$HOME/.bash_profile"
run_func _get_shell_rc_files
if [[ "$_RF_STDOUT" == *"$HOME/.bash_profile"* && "$_RF_STDOUT" == *"$HOME/.bashrc"* ]]; then
  pass "prerequisites: _get_shell_rc_files ignores commented bashrc source"
else
  fail "prerequisites: _get_shell_rc_files treated commented bashrc source as active"
fi
export HOME="$_saved_home_for_rc"
rm -rf "$_tmp_rc_home"

OS="linux"
run_func _get_shell_rc_file
if assert_equals "$HOME/.bashrc" "$_RF_STDOUT"; then
  pass "prerequisites: _get_shell_rc_file keeps .bashrc for Linux bash"
else
  fail "prerequisites: _get_shell_rc_file did not keep .bashrc for Linux bash"
fi

export SHELL="/bin/zsh"
OS="macos"
run_func _get_shell_rc_file
if assert_equals "$HOME/.zshrc" "$_RF_STDOUT"; then
  pass "prerequisites: _get_shell_rc_file keeps .zshrc for zsh"
else
  fail "prerequisites: _get_shell_rc_file did not keep .zshrc for zsh"
fi

export SHELL="$_saved_shell"
OS="$_saved_os"

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

# ── _is_bash4_candidate validates candidate version ──────────────────────

_tmpdir="$(mktemp -d)"
cat > "$_tmpdir/bash4" <<'EOF'
#!/bin/bash
if [[ "$1" == "-c" ]]; then
  echo 5
fi
EOF
cat > "$_tmpdir/bash3" <<'EOF'
#!/bin/bash
if [[ "$1" == "-c" ]]; then
  echo 3
fi
EOF
cat > "$_tmpdir/bashbad" <<'EOF'
#!/bin/bash
if [[ "$1" == "-c" ]]; then
  echo not-a-version
fi
EOF
chmod +x "$_tmpdir/bash4" "$_tmpdir/bash3" "$_tmpdir/bashbad"

if _is_bash4_candidate "$_tmpdir/bash4"; then
  pass "prerequisites: _is_bash4_candidate accepts Bash 4+ candidate"
else
  fail "prerequisites: _is_bash4_candidate rejected Bash 4+ candidate"
fi

if _is_bash4_candidate "$_tmpdir/bash3"; then
  fail "prerequisites: _is_bash4_candidate accepted Bash 3 candidate"
else
  pass "prerequisites: _is_bash4_candidate rejects Bash 3 candidate"
fi

if _is_bash4_candidate "$_tmpdir/bashbad" 2>/dev/null; then
  fail "prerequisites: _is_bash4_candidate accepted non-numeric version"
else
  pass "prerequisites: _is_bash4_candidate rejects non-numeric version"
fi

if _is_bash4_candidate "$_tmpdir/missing"; then
  fail "prerequisites: _is_bash4_candidate accepted missing path"
else
  pass "prerequisites: _is_bash4_candidate rejects missing path"
fi
rm -rf "$_tmpdir"

# ── _add_to_path_now_and_persist with isolated HOME ──────────────────────

_saved_home="$HOME"
_saved_shell="$SHELL"
_saved_os="$OS"
_tmpdir="$(mktemp -d)"
export HOME="$_tmpdir"
export SHELL="/bin/bash"
OS="macos"

# Create the RC file so _add_to_path_now_and_persist can append to it
touch "$_tmpdir/.bash_profile"

_test_dir="$_tmpdir/mybin"
mkdir -p "$_test_dir"

run_func _add_to_path_now_and_persist "$_test_dir"
if assert_exit_code 0 "$_RF_RC"; then
  # Check PATH contains the directory
  if [[ ":${PATH}:" == *":${_test_dir}:"* ]]; then
    if assert_file_contains "$_tmpdir/.bash_profile" "$_test_dir" \
      && assert_file_contains "$_tmpdir/.bashrc" "$_test_dir"; then
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
OS="$_saved_os"
# Remove the test dir from PATH
PATH="${PATH//:$_test_dir:/:}"; PATH="${PATH/#$_test_dir:/}"; PATH="${PATH/%:$_test_dir/}"; export PATH
rm -rf "$_tmpdir"

# ── _add_to_path_now_and_persist is idempotent ───────────────────────────

_saved_home="$HOME"
_saved_shell="$SHELL"
_saved_os="$OS"
_tmpdir="$(mktemp -d)"
export HOME="$_tmpdir"
export SHELL="/bin/bash"
OS="macos"
touch "$_tmpdir/.bash_profile"

_test_dir="$_tmpdir/mybin2"
mkdir -p "$_test_dir"

# Call twice
_add_to_path_now_and_persist "$_test_dir"
_add_to_path_now_and_persist "$_test_dir"

_line_count="$(grep -c "$_test_dir" "$_tmpdir/.bash_profile")"
_bashrc_line_count="$(grep -c "$_test_dir" "$_tmpdir/.bashrc")"
if assert_equals "1" "$_line_count" "RC file should contain path only once" \
  && assert_equals "1" "$_bashrc_line_count" "bashrc should contain path only once"; then
  pass "prerequisites: _add_to_path_now_and_persist is idempotent"
else
  fail "prerequisites: _add_to_path_now_and_persist wrote path duplicate entries"
fi

export HOME="$_saved_home"
export SHELL="$_saved_shell"
OS="$_saved_os"
PATH="${PATH//:$_test_dir:/:}"; PATH="${PATH/#$_test_dir:/}"; PATH="${PATH/%:$_test_dir/}"; export PATH
rm -rf "$_tmpdir"

# ── _add_to_path_now_and_persist avoids sourced bashrc duplicate ──────────

_saved_home="$HOME"
_saved_shell="$SHELL"
_saved_os="${OS:-}"
_tmpdir="$(mktemp -d)"
export HOME="$_tmpdir"
export SHELL="/bin/bash"
OS="macos"
printf '%s\n' 'source "${HOME}/.bashrc"' > "$_tmpdir/.bash_profile"
touch "$_tmpdir/.bashrc"

_test_dir="$_tmpdir/sourced-bin"
mkdir -p "$_test_dir"

run_func _add_to_path_now_and_persist "$_test_dir"
if assert_exit_code 0 "$_RF_RC" \
  && assert_file_contains "$_tmpdir/.bashrc" "$_test_dir" \
  && ! grep -q "$_test_dir" "$_tmpdir/.bash_profile"; then
  pass "prerequisites: _add_to_path_now_and_persist avoids sourced bashrc duplicate"
else
  fail "prerequisites: _add_to_path_now_and_persist duplicated sourced bashrc path"
fi

export HOME="$_saved_home"
export SHELL="$_saved_shell"
OS="$_saved_os"
PATH="${PATH//:$_test_dir:/:}"; PATH="${PATH/#$_test_dir:/}"; PATH="${PATH/%:$_test_dir/}"; export PATH
rm -rf "$_tmpdir"

# ── _add_to_path_now_and_persist writes .bashrc on Linux bash ─────────────

_saved_home="$HOME"
_saved_shell="$SHELL"
_saved_os="${OS:-}"
_tmpdir="$(mktemp -d)"
export HOME="$_tmpdir"
export SHELL="/bin/bash"
OS="linux"
touch "$_tmpdir/.bashrc"

_test_dir="$_tmpdir/linux-bin"
mkdir -p "$_test_dir"

run_func _add_to_path_now_and_persist "$_test_dir"
if assert_exit_code 0 "$_RF_RC" \
  && assert_file_contains "$_tmpdir/.bashrc" "$_test_dir" \
  && [[ ! -f "$_tmpdir/.bash_profile" ]]; then
  pass "prerequisites: _add_to_path_now_and_persist writes .bashrc on Linux bash"
else
  fail "prerequisites: _add_to_path_now_and_persist did not use Linux bashrc"
fi

export HOME="$_saved_home"
export SHELL="$_saved_shell"
OS="$_saved_os"
PATH="${PATH//:$_test_dir:/:}"; PATH="${PATH/#$_test_dir:/}"; PATH="${PATH/%:$_test_dir/}"; export PATH
rm -rf "$_tmpdir"

# ── _persist_node_path follows macOS bash rc selection ───────────────────

_saved_home="$HOME"
_saved_shell="$SHELL"
_saved_os="${OS:-}"
_tmpdir="$(mktemp -d)"
export HOME="$_tmpdir"
export SHELL="/bin/bash"
OS="macos"
touch "$_tmpdir/.bash_profile" "$_tmpdir/.bashrc"

_node_bin="$_tmpdir/node-bin"
mkdir -p "$_node_bin"
_persist_node_path "$_node_bin"
_persist_node_path "$_node_bin"

_node_profile_count="$(grep -c "$_node_bin" "$_tmpdir/.bash_profile")"
_node_bashrc_count="$(grep -c "$_node_bin" "$_tmpdir/.bashrc")"
if assert_equals "1" "$_node_profile_count" "bash_profile should contain node path once" \
  && assert_equals "1" "$_node_bashrc_count" "bashrc should contain node path once"; then
  pass "prerequisites: _persist_node_path writes macOS bash rc files idempotently"
else
  fail "prerequisites: _persist_node_path did not write macOS bash rc files idempotently"
fi

export HOME="$_saved_home"
export SHELL="$_saved_shell"
OS="$_saved_os"
rm -rf "$_tmpdir"

# ── _install_node persists brew keg-only node path on macOS bash ──────────

_saved_home="$HOME"
_saved_shell="$SHELL"
_saved_os="${OS:-}"
_saved_distro_family="${DISTRO_FAMILY:-}"
_saved_path="$PATH"
_orig_brew_is_usable="$(declare -f _brew_is_usable)"
_tmpdir="$(mktemp -d)"
export HOME="$_tmpdir/home"
export SHELL="/bin/bash"
OS="macos"
DISTRO_FAMILY="macos"
mkdir -p "$HOME" "$_tmpdir/prefix/bin"
touch "$HOME/.bash_profile" "$HOME/.bashrc"
cat > "$_tmpdir/prefix/bin/node" <<'EOF'
#!/bin/bash
echo v20.0.0
EOF
chmod +x "$_tmpdir/prefix/bin/node"

_brew_is_usable() { return 0; }
brew() {
  case "$1" in
    install) return 0 ;;
    --prefix) printf '%s\n' "$_tmpdir/prefix" ;;
  esac
}

run_func _install_node
if assert_exit_code 0 "$_RF_RC" \
  && assert_file_contains "$HOME/.bash_profile" "$_tmpdir/prefix/bin" \
  && assert_file_contains "$HOME/.bashrc" "$_tmpdir/prefix/bin" \
  && command -v node >/dev/null 2>&1; then
  pass "prerequisites: _install_node persists brew keg-only node path on macOS bash"
else
  fail "prerequisites: _install_node did not persist brew keg-only node path"
fi

unset -f brew
eval "$_orig_brew_is_usable"
export HOME="$_saved_home"
export SHELL="$_saved_shell"
OS="$_saved_os"
DISTRO_FAMILY="$_saved_distro_family"
export PATH="$_saved_path"
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

# ── _install_bash4 skips package installer during dry-run ────────────────

_orig_pkg_install="$(declare -f _pkg_install)"
_saved_dry_run="${DRY_RUN:-}"
DRY_RUN="true"
_pkg_install_called=0
_pkg_install() {
  _pkg_install_called=1
  return 0
}
run_func _install_bash4
if assert_exit_code 1 "$_RF_RC" "_install_bash4 should not install bash during dry-run"; then
  if [[ "$_pkg_install_called" -eq 0 ]]; then
    pass "prerequisites: _install_bash4 skips package installer during dry-run"
  else
    fail "prerequisites: _install_bash4 called package installer during dry-run"
  fi
else
  fail "prerequisites: _install_bash4 attempted install during dry-run"
fi
eval "$_orig_pkg_install"
DRY_RUN="$_saved_dry_run"

# ── check_tmux auto-installs when missing ────────────────────────────────

_saved_path="$PATH"
_tmpdir="$(mktemp -d)"
export PATH="$_tmpdir:/usr/bin:/bin"
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
export PATH="$_tmpdir:/usr/bin:/bin"
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

# ── check_biome installs via brew when available ──────────────────────────

_saved_path="$PATH"
_tmpdir="$(mktemp -d)"
export PATH="$_tmpdir:/usr/bin:/bin"
_orig_brew_usable="$(declare -f _brew_is_usable)"
_brew_is_usable() { return 0; }
cat > "$_tmpdir/brew" <<'EOF'
#!/bin/bash
if [[ "$1" == "install" && "$2" == "biome" ]]; then
  cat > "$(dirname "$0")/biome" <<'INNER'
#!/bin/bash
echo "biome 1.0.0"
INNER
  chmod +x "$(dirname "$0")/biome"
  exit 0
fi
exit 1
EOF
chmod +x "$_tmpdir/brew"
run_func check_biome
_biome_path="$(command -v biome 2>/dev/null || true)"
if assert_exit_code 0 "$_RF_RC" && assert_equals "$_tmpdir/biome" "$_biome_path"; then
  pass "prerequisites: check_biome installs via brew when available"
else
  fail "prerequisites: check_biome did not install via brew"
fi
eval "$_orig_brew_usable"
export PATH="$_saved_path"
rm -rf "$_tmpdir"

# ── check_biome falls back to npm when brew is unavailable ───────────────

_saved_path="$PATH"
_tmpdir="$(mktemp -d)"
mkdir -p "$_tmpdir/prefix/lib"
export PATH="$_tmpdir:/usr/bin:/bin"
_orig_brew_usable="$(declare -f _brew_is_usable)"
_brew_is_usable() { return 1; }
_npm_script="$(cat <<'EOF'
#!/bin/bash
if [[ "$1" == "config" && "$2" == "get" && "$3" == "prefix" ]]; then
  echo "__PREFIX__"
  exit 0
fi
if [[ "$1" == "install" && "$2" == "-g" && "$3" == "@biomejs/biome" ]]; then
  mkdir -p "__PREFIX__/bin"
  cat > "__PREFIX__/bin/biome" <<'INNER'
#!/bin/bash
echo "biome 1.0.0"
INNER
  chmod +x "__PREFIX__/bin/biome"
  exit 0
fi
exit 1
EOF
)"
printf '%s\n' "${_npm_script//__PREFIX__/$_tmpdir/prefix}" > "$_tmpdir/npm"
chmod +x "$_tmpdir/npm"
run_func check_biome
_biome_path="$(command -v biome 2>/dev/null || true)"
if assert_exit_code 0 "$_RF_RC" && assert_equals "$_tmpdir/prefix/bin/biome" "$_biome_path"; then
  pass "prerequisites: check_biome falls back to npm when brew is unavailable"
else
  fail "prerequisites: check_biome did not fall back to npm"
fi
eval "$_orig_brew_usable"
export PATH="$_saved_path"
rm -rf "$_tmpdir"

# ── check_biome returns failure when both brew and npm fail ──────────────

_saved_path="$PATH"
_tmpdir="$(mktemp -d)"
export PATH="$_tmpdir:/usr/bin:/bin"
_orig_brew_usable="$(declare -f _brew_is_usable)"
_brew_is_usable() { return 1; }
cat > "$_tmpdir/npm" <<'EOF'
#!/bin/bash
if [[ "$1" == "config" && "$2" == "get" && "$3" == "prefix" ]]; then
  echo "/nonexistent"
  exit 0
fi
exit 1
EOF
chmod +x "$_tmpdir/npm"
run_func check_biome
if assert_exit_code 1 "$_RF_RC" "check_biome should fail when brew and npm both fail"; then
  pass "prerequisites: check_biome fails when brew and npm both fail"
else
  fail "prerequisites: check_biome unexpectedly succeeded when brew and npm failed"
fi
eval "$_orig_brew_usable"
export PATH="$_saved_path"
rm -rf "$_tmpdir"
