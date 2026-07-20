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

# Large inline Python helpers must travel as one `-c` argv value. Feeding the
# source through stdin can block before Python starts when the shell's pipe
# buffer is smaller than the source. Keep the mutation tests bound to that
# production transport while still compiling the exact extracted source.
_prereq_test_extract_inline_python() { # <function-name>
  declare -f "$1" | /usr/bin/awk '
    BEGIN { quote = sprintf("%c", 39) }
    !capture && index($0, "/usr/bin/python3 -I -B -c ") \
      && substr($0, length($0), 1) == quote {
        capture = 1
        begin_count++
        next
      }
    capture && substr($0, 1, 1) == quote {
      capture = 0
      end_count++
      exit
    }
    capture { print }
    END {
      if (begin_count != 1 || end_count != 1) exit 96
    }
  '
}

_prereq_python_transport_ok=true
for _prereq_python_function in \
  _prereq_exact_text_file \
  _mdm_atomic_replace_component_leaf \
  _mdm_rollback_preserved_component_leaf \
  _mdm_finalize_preserved_component_leaf; do
  _prereq_python_definition="$(declare -f "$_prereq_python_function")"
  _prereq_python_source="$(
    _prereq_test_extract_inline_python "$_prereq_python_function"
  )" || _prereq_python_transport_ok=false
  if [[ "${#_prereq_python_source}" -le 512 \
    || "$_prereq_python_source" == *"'"* \
    || "$_prereq_python_definition" == *'<<'* ]] \
    || ! /usr/bin/python3 -I -B -c \
      'import ast, sys; ast.parse(sys.argv[1])' \
      "$_prereq_python_source"; then
    _prereq_python_transport_ok=false
  fi
done
if [[ "$_prereq_python_transport_ok" == true ]]; then
  pass "prerequisites: large inline Python uses syntax-safe argv transport"
else
  fail "prerequisites: inline Python transport can block or break quoting"
fi
unset _prereq_python_definition _prereq_python_function
unset _prereq_python_source _prereq_python_transport_ok

# The zsh nvm block keeps its historical leading blank line and exact bytes,
# and a second call remains idempotent without a heredoc-backed writer.
_nvm_zshrc_saved_home="$HOME"
_nvm_zshrc_saved_shell_set=0
[[ -n "${SHELL+x}" ]] && _nvm_zshrc_saved_shell_set=1
_nvm_zshrc_saved_shell="${SHELL:-}"
_nvm_zshrc_tmp="$(mktemp -d)"
export HOME="$_nvm_zshrc_tmp" SHELL=/bin/zsh
_nvm_zshrc_expected='
# nvm - Node Version Manager (added by claude-code-starter-kit)
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'
_nvm_zshrc_ok=false
if _ensure_nvm_in_zshrc >/dev/null \
  && _prereq_exact_text_file "$HOME/.zshrc" "$_nvm_zshrc_expected" \
  && _ensure_nvm_in_zshrc >/dev/null \
  && _prereq_exact_text_file "$HOME/.zshrc" "$_nvm_zshrc_expected"; then
  _nvm_zshrc_ok=true
fi
export HOME="$_nvm_zshrc_saved_home"
if [[ "$_nvm_zshrc_saved_shell_set" -eq 1 ]]; then
  export SHELL="$_nvm_zshrc_saved_shell"
else
  unset SHELL
fi
/bin/rm -rf "$_nvm_zshrc_tmp"
if [[ "$_nvm_zshrc_ok" == true ]]; then
  pass "prerequisites: zsh nvm initialization keeps exact idempotent bytes"
else
  fail "prerequisites: zsh nvm initialization changed its output contract"
fi
unset _nvm_zshrc_expected _nvm_zshrc_ok _nvm_zshrc_saved_home
unset _nvm_zshrc_saved_shell _nvm_zshrc_saved_shell_set _nvm_zshrc_tmp

# MDM-owned CLI versions are an exact stdout protocol, not a first-line hint.
# Pipe raw bytes to the trusted comparator so NUL, CRLF, extra lines, and a
# failing producer cannot be hidden by command substitution.
_mdm_test_cli_output() {
  case "$1" in
    exact) printf '1.2.3\n' ;;
    version) printf 'Version: 1.2.3\n' ;;
    biome) printf 'biome 1.2.3\n' ;;
    safety) printf 'cc-safety-net 1.2.3\n' ;;
    no-lf) printf '1.2.3' ;;
    crlf) printf '1.2.3\r\n' ;;
    extra) printf '1.2.3\nextra\n' ;;
    blank) printf '1.2.3\n\n' ;;
    nul) printf '1.2.3\000\n' ;;
    failing) printf '1.2.3\n'; return 7 ;;
    *) return 1 ;;
  esac
}
if _prereq_cli_output_matches 1.2.3 false _mdm_test_cli_output exact \
  && _prereq_cli_output_matches 1.2.3 true _mdm_test_cli_output version \
  && _prereq_cli_output_matches 1.2.3 true _mdm_test_cli_output biome \
  && _prereq_cli_output_matches 1.2.3 true _mdm_test_cli_output safety \
  && ! _prereq_cli_output_matches 1.2.3 false _mdm_test_cli_output version \
  && ! _prereq_cli_output_matches 1.2.3 true _mdm_test_cli_output no-lf \
  && ! _prereq_cli_output_matches 1.2.3 true _mdm_test_cli_output crlf \
  && ! _prereq_cli_output_matches 1.2.3 true _mdm_test_cli_output extra \
  && ! _prereq_cli_output_matches 1.2.3 true _mdm_test_cli_output blank \
  && ! _prereq_cli_output_matches 1.2.3 true _mdm_test_cli_output nul \
  && ! _prereq_cli_output_matches 1.2.3 true _mdm_test_cli_output failing; then
  pass "prerequisites: MDM CLI version output requires exact successful bytes"
else
  fail "prerequisites: MDM CLI version output accepted a malformed result"
fi

# GNU tool detection must consume complete version output under pipefail.
# A short-circuiting reader makes this producer exit with SIGPIPE.
_gnu_detect_saved_path="$PATH"
_gnu_detect_saved_sed="$_GNU_SED"
_gnu_detect_saved_awk="$_GNU_AWK"
_gnu_detect_tmp="$(mktemp -d)"
cat > "$_gnu_detect_tmp/version-tool" <<'EOF'
#!/bin/bash
case "${0##*/}" in
  sed) marker="GNU sed" ;;
  awk) marker="GNU Awk" ;;
  *) exit 1 ;;
esac
printf '%s\n' "$marker"
i=0
while [[ "$i" -lt 10000 ]]; do
  printf 'version-output-padding-%s\n' "$i"
  i=$((i + 1))
done
EOF
chmod +x "$_gnu_detect_tmp/version-tool"
ln -s version-tool "$_gnu_detect_tmp/sed"
ln -s version-tool "$_gnu_detect_tmp/awk"
export PATH="$_gnu_detect_tmp:$_gnu_detect_saved_path"
_GNU_SED=""
_GNU_AWK=""
if _detect_gnu_sed && _detect_gnu_awk \
  && [[ "$_GNU_SED" == "sed" && "$_GNU_AWK" == "awk" ]]; then
  pass "prerequisites: GNU tool detection consumes long version output"
else
  fail "prerequisites: GNU tool detection failed on long version output"
fi
export PATH="$_gnu_detect_saved_path"
_GNU_SED="$_gnu_detect_saved_sed"
_GNU_AWK="$_gnu_detect_saved_awk"
rm -rf "$_gnu_detect_tmp"

# MDM setup must never fall back to independently downloaded shell installers.
_mdm_prereq_original_brew="$(declare -f _brew_is_usable)"
_mdm_prereq_original_curl="$(declare -f curl 2>/dev/null || true)"
_mdm_prereq_original_brew_command="$(declare -f brew 2>/dev/null || true)"
_mdm_prereq_saved_distro="$DISTRO_FAMILY"
_mdm_prereq_saved_nvm="${NVM_DIR:-}"
_mdm_prereq_saved_dry_run="${DRY_RUN:-}"
_mdm_prereq_dry_run_set=0
[[ -n "${DRY_RUN+x}" ]] && _mdm_prereq_dry_run_set=1
_mdm_prereq_managed_set=0
[[ -n "${KIT_MDM_MANAGED+x}" ]] && _mdm_prereq_managed_set=1
_mdm_prereq_saved_managed="${KIT_MDM_MANAGED:-}"
_mdm_prereq_mode_set=0
[[ -n "${KIT_MDM_PREREQ_MODE+x}" ]] && _mdm_prereq_mode_set=1
_mdm_prereq_saved_mode="${KIT_MDM_PREREQ_MODE:-}"
export KIT_MDM_MANAGED=true
DISTRO_FAMILY=macos
_tmp_mdm_prereq="$(mktemp -d)"
_brew_is_usable() { return 1; }
curl() { : > "$_tmp_mdm_prereq/curl-called"; return 0; }
if _ensure_homebrew >/dev/null 2>&1 \
  && [[ ! -e "$_tmp_mdm_prereq/curl-called" ]]; then
  pass "prerequisites: MDM mode disables Homebrew curl bootstrap"
else
  fail "prerequisites: MDM mode attempted Homebrew curl bootstrap"
fi

export NVM_DIR="$_tmp_mdm_prereq/nvm"
if ! _install_node_via_nvm >/dev/null 2>&1 \
  && [[ ! -e "$_tmp_mdm_prereq/curl-called" && ! -e "$NVM_DIR" ]]; then
  pass "prerequisites: MDM mode disables nvm curl bootstrap"
else
  fail "prerequisites: MDM mode attempted nvm curl bootstrap"
fi

export KIT_MDM_PREREQ_MODE=fail DRY_RUN=false
_brew_is_usable() { return 0; }
brew() { : > "$_tmp_mdm_prereq/brew-called"; return 0; }
if ! _pkg_install jq >/dev/null 2>&1 \
  && ! _install_node >/dev/null 2>&1 \
  && [[ ! -e "$_tmp_mdm_prereq/brew-called" ]]; then
  pass "prerequisites: MDM fail mode blocks package-manager and direct Node installs"
else
  fail "prerequisites: MDM fail mode attempted a package or Node install"
fi

# A malformed managed mode is a configuration error, never an alias for auto.
# Reject it before resolving or acquiring any runtime or touching user state.
export KIT_MDM_PREREQ_MODE=invalid
rm -f "$_tmp_mdm_prereq/curl-called" "$_tmp_mdm_prereq/brew-called" \
  "$_tmp_mdm_prereq/resolver-called"
_invalid_orig_resolver="$(declare -f _mdm_resolve_private_node_toolchain)"
_mdm_resolve_private_node_toolchain() {
  : > "$_tmp_mdm_prereq/resolver-called"
  return 0
}
if ! check_node >/dev/null 2>&1 \
  && ! _ensure_homebrew >/dev/null 2>&1 \
  && ! _install_node >/dev/null 2>&1 \
  && [[ ! -e "$_tmp_mdm_prereq/resolver-called" \
    && ! -e "$_tmp_mdm_prereq/curl-called" \
    && ! -e "$_tmp_mdm_prereq/brew-called" ]]; then
  pass "prerequisites: invalid managed prerequisite mode fails before mutation or download"
else
  fail "prerequisites: invalid managed prerequisite mode fell through to auto behavior"
fi
eval "$_invalid_orig_resolver"
export KIT_MDM_PREREQ_MODE=fail

_mdm_prereq_original_pkg_install="$(declare -f _pkg_install)"
_pkg_install() { : > "$_tmp_mdm_prereq/pkg-called"; return 0; }
if ! _install_bash4 >/dev/null 2>&1 \
  && [[ ! -e "$_tmp_mdm_prereq/pkg-called" ]]; then
  pass "prerequisites: MDM fail mode blocks Bash 4 installation"
else
  fail "prerequisites: MDM fail mode attempted Bash 4 installation"
fi
eval "$_mdm_prereq_original_pkg_install"

# Positive regression: outside MDM, the existing Homebrew and nvm download
# fallbacks must remain reachable.
unset KIT_MDM_MANAGED KIT_MDM_PREREQ_MODE
_brew_is_usable() { return 1; }
curl() {
  : > "$_tmp_mdm_prereq/non-mdm-curl-called"
  printf ': > "%s"\n' "$_tmp_mdm_prereq/non-mdm-homebrew-installer"
}
_ensure_homebrew >/dev/null 2>&1 || true
if [[ -e "$_tmp_mdm_prereq/non-mdm-curl-called" \
  && -e "$_tmp_mdm_prereq/non-mdm-homebrew-installer" ]]; then
  pass "prerequisites: non-MDM Homebrew curl bootstrap remains enabled"
else
  fail "prerequisites: non-MDM Homebrew curl bootstrap regressed"
fi

rm -f "$_tmp_mdm_prereq/non-mdm-curl-called"
export NVM_DIR="$_tmp_mdm_prereq/non-mdm-nvm"
curl() {
  : > "$_tmp_mdm_prereq/non-mdm-curl-called"
  printf 'exit 1\n'
}
_install_node_via_nvm >/dev/null 2>&1 || true
if [[ -e "$_tmp_mdm_prereq/non-mdm-curl-called" && -d "$NVM_DIR" ]]; then
  pass "prerequisites: non-MDM nvm curl fallback remains enabled"
else
  fail "prerequisites: non-MDM nvm curl fallback regressed"
fi

rm -rf "$_tmp_mdm_prereq"
eval "$_mdm_prereq_original_brew"
if [[ -n "$_mdm_prereq_original_curl" ]]; then
  eval "$_mdm_prereq_original_curl"
else
  unset -f curl
fi
if [[ -n "$_mdm_prereq_original_brew_command" ]]; then
  eval "$_mdm_prereq_original_brew_command"
else
  unset -f brew
fi
DISTRO_FAMILY="$_mdm_prereq_saved_distro"
if [[ "$_mdm_prereq_managed_set" -eq 1 ]]; then
  export KIT_MDM_MANAGED="$_mdm_prereq_saved_managed"
else
  unset KIT_MDM_MANAGED
fi
if [[ "$_mdm_prereq_mode_set" -eq 1 ]]; then
  export KIT_MDM_PREREQ_MODE="$_mdm_prereq_saved_mode"
else
  unset KIT_MDM_PREREQ_MODE
fi
if [[ -n "$_mdm_prereq_saved_nvm" ]]; then
  export NVM_DIR="$_mdm_prereq_saved_nvm"
else
  unset NVM_DIR
fi
if [[ "$_mdm_prereq_dry_run_set" -eq 1 ]]; then
  DRY_RUN="$_mdm_prereq_saved_dry_run"
else
  unset DRY_RUN
fi

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

# ── Node path persistence reuses generic PATH helper ─────────────────────

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
_add_to_path_now_and_persist "$_node_bin" "Node.js (brew keg-only, added by claude-code-starter-kit)"
_add_to_path_now_and_persist "$_node_bin" "Node.js (brew keg-only, added by claude-code-starter-kit)"

_node_profile_count="$(grep -c "$_node_bin" "$_tmpdir/.bash_profile")"
_node_bashrc_count="$(grep -c "$_node_bin" "$_tmpdir/.bashrc")"
if assert_equals "1" "$_node_profile_count" "bash_profile should contain node path once" \
  && assert_equals "1" "$_node_bashrc_count" "bashrc should contain node path once"; then
  pass "prerequisites: Node path persistence reuses generic PATH helper"
else
  fail "prerequisites: Node path persistence did not use generic PATH helper"
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
echo v24.0.0
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

# ── MDM pinned Node activation and native hook CLI artifacts ──────────────

_saved_home="$HOME"
_saved_path="$PATH"
_saved_mdm_managed="${KIT_MDM_MANAGED:-}"
_saved_mdm_mode="${KIT_MDM_PREREQ_MODE:-}"
_saved_mdm_require_node="${KIT_MDM_REQUIRE_NODE_RUNTIME:-}"
_orig_mdm_arch="$(declare -f _mdm_current_darwin_arch)"
_orig_mdm_toolchain="$(declare -f _mdm_resolve_private_node_toolchain)"
_orig_mdm_download="$(declare -f _mdm_download_pinned_artifact)"
_orig_mdm_codesign="$(declare -f _mdm_prereq_codesign)"
_saved_biome_archive_sha="$_MDM_BIOME_ARM64_ARCHIVE_SHA256"
_saved_biome_binary_sha="$_MDM_BIOME_ARM64_BINARY_SHA256"
_saved_biome_package_sha="$_MDM_BIOME_ARM64_PACKAGE_SHA256"
_saved_safety_archive_sha="$_MDM_CC_SAFETY_NET_ARCHIVE_SHA256"
_saved_safety_js_sha="$_MDM_CC_SAFETY_NET_JS_SHA256"
_saved_safety_package_sha="$_MDM_CC_SAFETY_NET_PACKAGE_SHA256"
_tmpdir="$(mktemp -d)"
_tmpdir="$(cd -P "$_tmpdir" && pwd -P)"
export HOME="$_tmpdir/home"
export KIT_MDM_MANAGED=true KIT_MDM_PREREQ_MODE=auto
export KIT_MDM_REQUIRE_NODE_RUNTIME=true
mkdir -p "$HOME" "$_tmpdir/artifacts/biome/package" \
  "$_tmpdir/artifacts/safety/package/dist/bin" "$_tmpdir/fake"

_mdm_test_node="$(_prereq_canonical_file "$(command -v node)")"

# The target-user resolver must reproduce the privileged installer's canonical
# official-tree digest, not merely trust a signed node executable. Use a small
# local inventory to lock the canonicalization properties without downloading
# release archives during the unit suite.
_mdm_digest_root="$_tmpdir/node-digest-root"
mkdir -p "$_mdm_digest_root/bin"
ln -s "$_mdm_test_node" "$_mdm_digest_root/bin/node"
printf 'payload\n' > "$_mdm_digest_root/payload.txt"
printf \
  'schema=1\nversion=v24.18.0\narch=arm64\nurl=%s\nsha256=%s\n' \
  "$_MDM_NODE_ARM64_SOURCE_URL" "$_MDM_NODE_ARM64_SOURCE_SHA256" \
  > "$_mdm_digest_root/$_MDM_NODE_PROVENANCE_FILE"
chmod 755 "$_mdm_digest_root" "$_mdm_digest_root/bin"
chmod 644 "$_mdm_digest_root/payload.txt"
chmod 444 "$_mdm_digest_root/$_MDM_NODE_PROVENANCE_FILE"
_mdm_digest_one="$(_mdm_private_node_content_sha256 \
  "$_mdm_digest_root" "$_mdm_digest_root/bin/node" \
  "$(id -u)" "$(id -g)" 2>/dev/null || true)"
chmod 644 "$_mdm_digest_root/$_MDM_NODE_PROVENANCE_FILE"
printf 'locally-issued marker changes do not affect release content\n' \
  > "$_mdm_digest_root/$_MDM_NODE_PROVENANCE_FILE"
chmod 444 "$_mdm_digest_root/$_MDM_NODE_PROVENANCE_FILE"
_mdm_digest_marker_changed="$(_mdm_private_node_content_sha256 \
  "$_mdm_digest_root" "$_mdm_digest_root/bin/node" \
  "$(id -u)" "$(id -g)" 2>/dev/null || true)"
printf 'tamper\n' >> "$_mdm_digest_root/payload.txt"
_mdm_digest_payload_changed="$(_mdm_private_node_content_sha256 \
  "$_mdm_digest_root" "$_mdm_digest_root/bin/node" \
  "$(id -u)" "$(id -g)" 2>/dev/null || true)"
chmod 666 "$_mdm_digest_root/payload.txt"
_mdm_digest_writable_rc=0
_mdm_private_node_content_sha256 \
  "$_mdm_digest_root" "$_mdm_digest_root/bin/node" \
  "$(id -u)" "$(id -g)" >/dev/null 2>&1 || _mdm_digest_writable_rc=$?
if [[ "$_mdm_digest_one" =~ ^[0-9a-f]{64}$ \
  && "$_mdm_digest_marker_changed" == "$_mdm_digest_one" \
  && "$_mdm_digest_payload_changed" =~ ^[0-9a-f]{64}$ \
  && "$_mdm_digest_payload_changed" != "$_mdm_digest_one" \
  && "$_mdm_digest_writable_rc" -ne 0 ]]; then
  pass "prerequisites: private Node canonical digest binds the official tree"
else
  fail "prerequisites: private Node canonical digest contract is incomplete"
fi

# Provenance is a byte-exact root-issued record. Stub only the ownership
# predicate so the ordinary-user fixture can exercise the production reader.
_mdm_provenance_marker="$_mdm_digest_root/$_MDM_NODE_PROVENANCE_FILE"
_mdm_provenance_expected="$(printf \
  'schema=1\nversion=v%s\narch=arm64\nurl=%s\nsha256=%s' \
  "$_MDM_NODE_VERSION" "$_MDM_NODE_ARM64_SOURCE_URL" \
  "$_MDM_NODE_ARM64_SOURCE_SHA256")"
/bin/chmod 644 "$_mdm_provenance_marker"
printf '%s\n' "$_mdm_provenance_expected" > "$_mdm_provenance_marker"
/bin/chmod 444 "$_mdm_provenance_marker"
_orig_mdm_root_owned="$(declare -f _prereq_root_owned_not_writable)"
_prereq_root_owned_not_writable() {
  [[ "$1" == "$_mdm_provenance_marker" ]]
}
_mdm_provenance_exact_rc=0
_mdm_private_node_provenance_valid "$_mdm_digest_root" arm64 \
  >/dev/null 2>&1 || _mdm_provenance_exact_rc=$?
/bin/chmod 644 "$_mdm_provenance_marker"
printf '\000' >> "$_mdm_provenance_marker"
/bin/chmod 444 "$_mdm_provenance_marker"
_mdm_provenance_nul_rc=0
_mdm_private_node_provenance_valid "$_mdm_digest_root" arm64 \
  >/dev/null 2>&1 || _mdm_provenance_nul_rc=$?
/bin/chmod 644 "$_mdm_provenance_marker"
printf '%s\n' "$_mdm_provenance_expected" > "$_mdm_provenance_marker"
/bin/chmod 444 "$_mdm_provenance_marker"
_mdm_provenance_restored_rc=0
_mdm_private_node_provenance_valid "$_mdm_digest_root" arm64 \
  >/dev/null 2>&1 || _mdm_provenance_restored_rc=$?
eval "$_orig_mdm_root_owned"
if [[ "$_mdm_provenance_exact_rc" -eq 0 \
  && "$_mdm_provenance_nul_rc" -ne 0 \
  && "$_mdm_provenance_restored_rc" -eq 0 ]]; then
  pass "prerequisites: private Node provenance requires exact canonical bytes"
else
  fail "prerequisites: private Node provenance exact-byte validation failed"
fi

_mdm_resolver_source="$(declare -f _mdm_resolve_private_node_toolchain)"
if [[ "$_mdm_resolver_source" == *'_mdm_private_node_content_sha256'* \
  && "$_mdm_resolver_source" == *'_mdm_private_node_provenance_valid'* \
  && "$_mdm_resolver_source" == *'_MDM_NODE_NPM_VERSION'* \
  && "$_mdm_resolver_source" == *'process.arch'* \
  && "$_MDM_NODE_ARM64_CONTENT_SHA256" == \
    3b87679d20e675468b9281755c823b528b6406ba7af6cc7086ef00e5c8af6533 \
  && "$_MDM_NODE_X64_CONTENT_SHA256" == \
    a9f69014ea08981c1b1822f565a39ae6970a319518ebf3e43d96ba9fc70aa209 ]]; then
  pass "prerequisites: private Node resolver pins provenance, arch, npm, and tree digest"
else
  fail "prerequisites: private Node resolver omitted a pinned runtime binding"
fi

_mdm_resolver_gid_contract="$(
  printf '%s\n' "$_mdm_resolver_source" | /usr/bin/awk '
    /for dir in \/ \/Library "\/Library\/Application Support"/ {
      block = "system"; system_seen = 1; next
    }
    /for dir in "\/Library\/Application Support\/ClaudeCodeStarterKit"/ {
      block = "managed"; managed_seen = 1; next
    }
    block == "system" && /_prereq_stat_gid/ { system_gid = 1 }
    block == "managed" && /_prereq_stat_gid/ && /== 0/ {
      managed_gid_zero = 1
    }
    block != "" && /^[[:space:]]*done/ { block = "" }
    END {
      printf "%d:%d:%d:%d", system_seen + 0, system_gid + 0,
        managed_seen + 0, managed_gid_zero + 0
    }
  '
)"
if [[ "$_mdm_resolver_gid_contract" == "1:0:1:1" ]]; then
  pass "prerequisites: private Node resolver scopes gid 0 to managed directories"
else
  fail "prerequisites: private Node resolver gid trust boundary drifted"
fi

# Component publication must preserve the candidate inode for both creation
# and replacement, then remove the old leaf without legacy backup residue.
_mdm_test_inode() {
  if [[ "$(/usr/bin/uname -s 2>/dev/null)" == Darwin ]]; then
    /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%d:%i' "$1" 2>/dev/null
  fi
}
_mdm_atomic_parent="$_tmpdir/atomic-parent"
_mdm_atomic_other_parent="$_tmpdir/atomic-other-parent"
/bin/mkdir -p "$_mdm_atomic_parent" "$_mdm_atomic_other_parent"
_mdm_atomic_destination="$_mdm_atomic_parent/component"
_mdm_atomic_candidate="$_mdm_atomic_parent/.candidate-create"
/bin/mkdir "$_mdm_atomic_candidate"
printf 'created\n' > "$_mdm_atomic_candidate/payload"
_mdm_atomic_create_inode="$(_mdm_test_inode "$_mdm_atomic_candidate")"
_mdm_atomic_create_rc=0
_mdm_atomic_replace_component_leaf \
  "$_mdm_atomic_candidate" "$_mdm_atomic_destination" \
  >/dev/null 2>&1 || _mdm_atomic_create_rc=$?
_mdm_atomic_create_after="$(_mdm_test_inode \
  "$_mdm_atomic_destination" 2>/dev/null || true)"
if [[ "$_mdm_atomic_create_rc" -eq 0 \
  && "$_mdm_atomic_create_after" == "$_mdm_atomic_create_inode" \
  && "$(< "$_mdm_atomic_destination/payload")" == created \
  && ! -e "$_mdm_atomic_candidate" && ! -L "$_mdm_atomic_candidate" \
  && -z "$(compgen -G "$_mdm_atomic_parent/.starter-kit-old.*" || true)" ]]; then
  pass "prerequisites: atomic component create publishes the candidate inode"
else
  fail "prerequisites: atomic component create changed the candidate identity"
fi

_mdm_atomic_candidate="$_mdm_atomic_parent/.candidate-swap"
/bin/mkdir "$_mdm_atomic_candidate"
printf 'swapped\n' > "$_mdm_atomic_candidate/payload"
_mdm_atomic_swap_inode="$(_mdm_test_inode "$_mdm_atomic_candidate")"
_mdm_atomic_swap_rc=0
_mdm_atomic_replace_component_leaf \
  "$_mdm_atomic_candidate" "$_mdm_atomic_destination" \
  >/dev/null 2>&1 || _mdm_atomic_swap_rc=$?
_mdm_atomic_swap_after="$(_mdm_test_inode \
  "$_mdm_atomic_destination" 2>/dev/null || true)"
if [[ "$_mdm_atomic_swap_rc" -eq 0 \
  && "$_mdm_atomic_swap_after" == "$_mdm_atomic_swap_inode" \
  && "$(< "$_mdm_atomic_destination/payload")" == swapped \
  && ! -e "$_mdm_atomic_candidate" && ! -L "$_mdm_atomic_candidate" \
  && -z "$(compgen -G "$_mdm_atomic_parent/.starter-kit-old.*" || true)" ]]; then
  pass "prerequisites: atomic component swap removes the old candidate leaf"
else
  fail "prerequisites: atomic component swap left stale replacement state"
fi

_mdm_atomic_cross_candidate="$_mdm_atomic_other_parent/candidate"
/bin/mkdir "$_mdm_atomic_cross_candidate"
printf 'cross-parent\n' > "$_mdm_atomic_cross_candidate/payload"
_mdm_atomic_cross_inode="$(_mdm_test_inode "$_mdm_atomic_cross_candidate")"
_mdm_atomic_destination_inode="$(_mdm_test_inode "$_mdm_atomic_destination")"
_mdm_atomic_cross_rc=0
_mdm_atomic_replace_component_leaf \
  "$_mdm_atomic_cross_candidate" "$_mdm_atomic_destination" \
  >/dev/null 2>&1 || _mdm_atomic_cross_rc=$?
if [[ "$_mdm_atomic_cross_rc" -ne 0 \
  && "$(_mdm_test_inode "$_mdm_atomic_cross_candidate")" \
    == "$_mdm_atomic_cross_inode" \
  && "$(_mdm_test_inode "$_mdm_atomic_destination")" \
    == "$_mdm_atomic_destination_inode" \
  && "$(< "$_mdm_atomic_cross_candidate/payload")" == cross-parent \
  && "$(< "$_mdm_atomic_destination/payload")" == swapped \
  && -z "$(compgen -G "$_mdm_atomic_parent/.starter-kit-old.*" || true)" \
  && -z "$(compgen -G "$_mdm_atomic_other_parent/.starter-kit-old.*" || true)" ]]; then
  pass "prerequisites: atomic component replacement rejects cross-parent input"
else
  fail "prerequisites: cross-parent rejection mutated a component leaf"
fi

# Reproduce the macOS/Linux RENAME_SWAP type race deterministically by
# injecting a directory replacement immediately after the embedded helper has
# inspected the old link.  The exact production Python body is used; only the
# concurrent rename is inserted.  A failed publication must reverse its one
# swap and leave the directory inode and contents at the destination path.
_mdm_atomic_link_parent="$_tmpdir/atomic-link-race"
_mdm_atomic_link_destination="$_mdm_atomic_link_parent/node_modules"
_mdm_atomic_link_candidate="$_mdm_atomic_link_parent/.link-candidate"
_mdm_atomic_link_race_dir="$_mdm_atomic_link_parent/.race-directory"
_mdm_atomic_link_prior="$_mdm_atomic_link_parent/.race-prior"
_mdm_atomic_link_python="$_mdm_atomic_link_parent/race-helper.py"
/bin/mkdir -p "$_mdm_atomic_link_race_dir"
/bin/ln -s /tmp/original-node-modules "$_mdm_atomic_link_destination"
/bin/ln -s /tmp/replacement-node-modules "$_mdm_atomic_link_candidate"
printf 'preserve\n' > "$_mdm_atomic_link_race_dir/keep.txt"
_mdm_atomic_link_race_inode="$(_mdm_test_inode "$_mdm_atomic_link_race_dir")"
_prereq_test_extract_inline_python \
  _mdm_atomic_replace_component_leaf | /usr/bin/awk '
  {
    if ($0 == "    operation = \"create\" if destination_before is None else \"swap\"") {
      print "    if replacement_kind == \"link\":"
      print "        rename_atomic(destination_name, \".race-prior\", \"create\")"
      print "        rename_atomic(\".race-directory\", destination_name, \"create\")"
      found++
    }
    print
  }
  END { if (found != 1) exit 97 }
' > "$_mdm_atomic_link_python"
_mdm_atomic_link_race_rc=0
/usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
  /usr/bin/python3 -I -B "$_mdm_atomic_link_python" \
    "$_mdm_atomic_link_candidate" "$_mdm_atomic_link_destination" link \
    >/dev/null 2>&1 || _mdm_atomic_link_race_rc=$?
if [[ "$_mdm_atomic_link_race_rc" -ne 0 \
  && -d "$_mdm_atomic_link_destination" \
  && ! -L "$_mdm_atomic_link_destination" \
  && "$(_mdm_test_inode "$_mdm_atomic_link_destination")" \
    == "$_mdm_atomic_link_race_inode" \
  && "$(< "$_mdm_atomic_link_destination/keep.txt")" == preserve \
  && ! -e "$_mdm_atomic_link_candidate" \
  && ! -L "$_mdm_atomic_link_candidate" \
  && -L "$_mdm_atomic_link_prior" \
  && "$(/usr/bin/readlink "$_mdm_atomic_link_prior")" \
    == /tmp/original-node-modules \
  && ! -e "$_mdm_atomic_link_race_dir" \
  && ! -L "$_mdm_atomic_link_race_dir" ]]; then
  pass "prerequisites: link swap race restores the directory and removes only its exact candidate"
else
  fail "prerequisites: link swap race displaced or changed a replacement directory"
fi

# Any error after the atomic swap but before postcondition capture must reverse
# the exact exchange. This is the WCE migration failure window where the old
# real dependency directory must return at its original inode.
_mdm_atomic_post_parent="$_tmpdir/atomic-post-publish"
_mdm_atomic_post_destination="$_mdm_atomic_post_parent/node_modules"
_mdm_atomic_post_candidate="$_mdm_atomic_post_parent/.candidate"
_mdm_atomic_post_python="$_mdm_atomic_post_parent/post-publish-helper.py"
/bin/mkdir -p "$_mdm_atomic_post_destination"
printf 'original\n' > "$_mdm_atomic_post_destination/keep.txt"
/bin/ln -s /tmp/replacement-node-modules "$_mdm_atomic_post_candidate"
_mdm_atomic_post_inode="$(_mdm_test_inode "$_mdm_atomic_post_destination")"
_prereq_test_extract_inline_python \
  _mdm_atomic_replace_component_leaf | /usr/bin/awk '
  {
    print
    if ($0 == "    published = True") {
      print "    raise OSError(errno.EIO, \"injected post-publication failure\")"
      found++
    }
  }
  END { if (found != 1) exit 97 }
' > "$_mdm_atomic_post_python"
_mdm_atomic_post_rc=0
/usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
  /usr/bin/python3 -I -B "$_mdm_atomic_post_python" \
    "$_mdm_atomic_post_candidate" "$_mdm_atomic_post_destination" \
    link-preserve-dir >/dev/null 2>&1 || _mdm_atomic_post_rc=$?
if [[ "$_mdm_atomic_post_rc" -ne 0 \
  && -d "$_mdm_atomic_post_destination" \
  && ! -L "$_mdm_atomic_post_destination" \
  && "$(_mdm_test_inode "$_mdm_atomic_post_destination")" \
    == "$_mdm_atomic_post_inode" \
  && "$(< "$_mdm_atomic_post_destination/keep.txt")" == original \
  && ! -e "$_mdm_atomic_post_candidate" \
  && ! -L "$_mdm_atomic_post_candidate" ]]; then
  pass "prerequisites: post-publication failure restores the exact preserved directory"
else
  fail "prerequisites: post-publication failure left a partial activation"
fi

# Once rollback has restored the preserved directory, a later durability
# failure must not swap the rejected activation back into the fixed leaf.
_mdm_atomic_inverse_parent="$_tmpdir/atomic-inverse-failure"
_mdm_atomic_inverse_destination="$_mdm_atomic_inverse_parent/node_modules"
_mdm_atomic_inverse_candidate="$_mdm_atomic_inverse_parent/.candidate"
_mdm_atomic_inverse_python="$_mdm_atomic_inverse_parent/inverse-helper.py"
/bin/mkdir -p "$_mdm_atomic_inverse_destination"
printf 'preserved\n' > "$_mdm_atomic_inverse_destination/keep.txt"
/bin/ln -s /tmp/rejected-node-modules "$_mdm_atomic_inverse_candidate"
_mdm_atomic_inverse_inode="$(_mdm_test_inode \
  "$_mdm_atomic_inverse_destination")"
_mdm_atomic_replace_component_leaf \
  "$_mdm_atomic_inverse_candidate" "$_mdm_atomic_inverse_destination" \
  link-preserve-dir >/dev/null 2>&1
_mdm_atomic_inverse_token="$_MDM_COMPONENT_PRESERVE_TOKEN"
_prereq_test_extract_inline_python \
  _mdm_rollback_preserved_component_leaf | /usr/bin/awk '
  {
    print
    if ($0 == "        rename_atomic(preserved_name, destination_name, \"swap\")") {
      print "        raise OSError(errno.EIO, \"injected inverse durability failure\")"
      found++
    }
  }
  END { if (found != 1) exit 97 }
' > "$_mdm_atomic_inverse_python"
_mdm_atomic_inverse_rc=0
/usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
  /usr/bin/python3 -I -B "$_mdm_atomic_inverse_python" \
    "$_mdm_atomic_inverse_candidate" "$_mdm_atomic_inverse_destination" \
    "$_mdm_atomic_inverse_token" >/dev/null 2>&1 \
    || _mdm_atomic_inverse_rc=$?
if [[ "$_mdm_atomic_inverse_rc" -ne 0 \
  && -d "$_mdm_atomic_inverse_destination" \
  && ! -L "$_mdm_atomic_inverse_destination" \
  && "$(_mdm_test_inode "$_mdm_atomic_inverse_destination")" \
    == "$_mdm_atomic_inverse_inode" \
  && "$(< "$_mdm_atomic_inverse_destination/keep.txt")" == preserved \
  && -L "$_mdm_atomic_inverse_candidate" \
  && "$(/usr/bin/readlink "$_mdm_atomic_inverse_candidate")" \
    == /tmp/rejected-node-modules ]]; then
  pass "prerequisites: rollback durability failure never republishes the rejected link"
else
  fail "prerequisites: rollback durability failure republished the rejected link"
fi

# Finalize is allowed to remove only the token-bound old file/link. Replacing
# that random name before finalize must fail without deleting the replacement.
_mdm_atomic_finalize_parent="$_tmpdir/atomic-finalize-race"
_mdm_atomic_finalize_destination="$_mdm_atomic_finalize_parent/node_modules"
_mdm_atomic_finalize_candidate="$_mdm_atomic_finalize_parent/.candidate"
_mdm_atomic_finalize_captured="$_mdm_atomic_finalize_parent/.captured-old"
/bin/mkdir -p "$_mdm_atomic_finalize_parent"
/bin/ln -s /tmp/old-node-modules "$_mdm_atomic_finalize_destination"
/bin/ln -s /tmp/published-node-modules "$_mdm_atomic_finalize_candidate"
_mdm_atomic_replace_component_leaf \
  "$_mdm_atomic_finalize_candidate" "$_mdm_atomic_finalize_destination" \
  link-preserve-dir >/dev/null 2>&1
_mdm_atomic_finalize_token="$_MDM_COMPONENT_PRESERVE_TOKEN"
/bin/mv "$_mdm_atomic_finalize_candidate" "$_mdm_atomic_finalize_captured"
/bin/ln -s /tmp/foreign-finalize "$_mdm_atomic_finalize_candidate"
_mdm_atomic_finalize_rc=0
_mdm_finalize_preserved_component_leaf \
  "$_mdm_atomic_finalize_candidate" "$_mdm_atomic_finalize_destination" \
  "$_mdm_atomic_finalize_token" >/dev/null 2>&1 \
  || _mdm_atomic_finalize_rc=$?
if [[ "$_mdm_atomic_finalize_rc" -ne 0 \
  && "$(/usr/bin/readlink "$_mdm_atomic_finalize_destination")" \
    == /tmp/published-node-modules \
  && "$(/usr/bin/readlink "$_mdm_atomic_finalize_candidate")" \
    == /tmp/foreign-finalize \
  && "$(/usr/bin/readlink "$_mdm_atomic_finalize_captured")" \
    == /tmp/old-node-modules ]]; then
  pass "prerequisites: finalize refuses a replaced backup path without deleting it"
else
  fail "prerequisites: finalize deleted or displaced a replaced backup path"
fi

# A malformed token or replaced published path must leave both the preserved
# directory and every current path object untouched.
_mdm_atomic_token_parent="$_tmpdir/atomic-token-race"
_mdm_atomic_token_destination="$_mdm_atomic_token_parent/node_modules"
_mdm_atomic_token_candidate="$_mdm_atomic_token_parent/.candidate"
_mdm_atomic_token_published="$_mdm_atomic_token_parent/.captured-published"
/bin/mkdir -p "$_mdm_atomic_token_destination"
printf 'token-preserve\n' > "$_mdm_atomic_token_destination/keep.txt"
/bin/ln -s /tmp/token-published "$_mdm_atomic_token_candidate"
_mdm_atomic_token_inode="$(_mdm_test_inode "$_mdm_atomic_token_destination")"
_mdm_atomic_replace_component_leaf \
  "$_mdm_atomic_token_candidate" "$_mdm_atomic_token_destination" \
  link-preserve-dir >/dev/null 2>&1
_mdm_atomic_token_value="$_MDM_COMPONENT_PRESERVE_TOKEN"
_mdm_atomic_token_bad="${_mdm_atomic_token_value%?}x"
_mdm_atomic_token_rc=0
_mdm_rollback_preserved_component_leaf \
  "$_mdm_atomic_token_candidate" "$_mdm_atomic_token_destination" \
  "$_mdm_atomic_token_bad" >/dev/null 2>&1 || _mdm_atomic_token_rc=$?
_mdm_atomic_token_first_ok=false
if [[ "$_mdm_atomic_token_rc" -ne 0 \
  && -d "$_mdm_atomic_token_candidate" \
  && "$(_mdm_test_inode "$_mdm_atomic_token_candidate")" \
    == "$_mdm_atomic_token_inode" \
  && "$(< "$_mdm_atomic_token_candidate/keep.txt")" == token-preserve \
  && "$(/usr/bin/readlink "$_mdm_atomic_token_destination")" \
    == /tmp/token-published ]]; then
  _mdm_atomic_token_first_ok=true
fi
/bin/mv "$_mdm_atomic_token_destination" "$_mdm_atomic_token_published"
/bin/ln -s /tmp/foreign-published "$_mdm_atomic_token_destination"
_mdm_atomic_token_rc=0
_mdm_rollback_preserved_component_leaf \
  "$_mdm_atomic_token_candidate" "$_mdm_atomic_token_destination" \
  "$_mdm_atomic_token_value" >/dev/null 2>&1 || _mdm_atomic_token_rc=$?
if [[ "$_mdm_atomic_token_first_ok" == true \
  && "$_mdm_atomic_token_rc" -ne 0 \
  && -d "$_mdm_atomic_token_candidate" \
  && "$(_mdm_test_inode "$_mdm_atomic_token_candidate")" \
    == "$_mdm_atomic_token_inode" \
  && "$(/usr/bin/readlink "$_mdm_atomic_token_destination")" \
    == /tmp/foreign-published \
  && "$(/usr/bin/readlink "$_mdm_atomic_token_published")" \
    == /tmp/token-published ]]; then
  pass "prerequisites: rollback token and published-path replacement are non-destructive"
else
  fail "prerequisites: rollback changed state after token or path replacement"
fi

# A caller must not clean a candidate pathname after the fd-bound helper
# returns. Reproduce a replacement after the helper captured its candidate;
# exact cleanup must leave the foreign symlink untouched.
_mdm_atomic_foreign_parent="$_tmpdir/atomic-foreign-candidate"
_mdm_atomic_foreign_destination="$_mdm_atomic_foreign_parent/tool"
_mdm_atomic_foreign_candidate="$_mdm_atomic_foreign_parent/.candidate"
_mdm_atomic_foreign_captured="$_mdm_atomic_foreign_parent/.captured-candidate"
_mdm_atomic_foreign_python="$_mdm_atomic_foreign_parent/foreign-helper.py"
/bin/mkdir -p "$_mdm_atomic_foreign_parent"
/bin/ln -s /tmp/original-tool "$_mdm_atomic_foreign_destination"
/bin/ln -s /tmp/our-candidate "$_mdm_atomic_foreign_candidate"
_prereq_test_extract_inline_python \
  _mdm_atomic_replace_component_leaf | /usr/bin/awk '
  {
    print
    if ($0 == "    candidate_before = at(candidate_name)") {
      print "    os.rename(candidate_name, \".captured-candidate\", src_dir_fd=parent, dst_dir_fd=parent)"
      print "    os.symlink(\"/tmp/foreign-candidate\", candidate_name, dir_fd=parent)"
      print "    raise ValueError(\"injected candidate replacement\")"
      found++
    }
  }
  END { if (found != 1) exit 97 }
' > "$_mdm_atomic_foreign_python"
_mdm_atomic_foreign_rc=0
/usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
  /usr/bin/python3 -I -B "$_mdm_atomic_foreign_python" \
    "$_mdm_atomic_foreign_candidate" "$_mdm_atomic_foreign_destination" link \
    >/dev/null 2>&1 || _mdm_atomic_foreign_rc=$?
if [[ "$_mdm_atomic_foreign_rc" -ne 0 \
  && -L "$_mdm_atomic_foreign_destination" \
  && "$(/usr/bin/readlink "$_mdm_atomic_foreign_destination")" \
    == /tmp/original-tool \
  && -L "$_mdm_atomic_foreign_candidate" \
  && "$(/usr/bin/readlink "$_mdm_atomic_foreign_candidate")" \
    == /tmp/foreign-candidate \
  && -L "$_mdm_atomic_foreign_captured" \
  && "$(/usr/bin/readlink "$_mdm_atomic_foreign_captured")" \
    == /tmp/our-candidate ]]; then
  pass "prerequisites: failed atomic helper does not unlink a foreign candidate replacement"
else
  fail "prerequisites: failed atomic helper deleted or displaced a foreign candidate replacement"
fi
unset -f _mdm_test_inode

cat > "$_tmpdir/artifacts/biome/package/biome" <<'EOF'
#!/bin/bash
printf 'Version: 2.5.4\n'
EOF
printf '%s\n' '{"name":"@biomejs/cli-darwin-arm64","version":"2.5.4"}' \
  > "$_tmpdir/artifacts/biome/package/package.json"
chmod 755 "$_tmpdir/artifacts/biome/package/biome"
( cd "$_tmpdir/artifacts/biome" && /usr/bin/tar -czf ../biome.tgz package )

cat > "$_tmpdir/artifacts/safety/package/dist/bin/cc-safety-net.js" <<'EOF'
if (process.argv.includes("--version")) process.stdout.write("1.0.6\n");
EOF
printf '%s\n' '{"name":"cc-safety-net","version":"1.0.6"}' \
  > "$_tmpdir/artifacts/safety/package/package.json"
( cd "$_tmpdir/artifacts/safety" && /usr/bin/tar -czf ../safety.tgz package )

_MDM_BIOME_ARM64_ARCHIVE_SHA256="$(_prereq_sha256_file "$_tmpdir/artifacts/biome.tgz")"
_MDM_BIOME_ARM64_BINARY_SHA256="$(_prereq_sha256_file "$_tmpdir/artifacts/biome/package/biome")"
_MDM_BIOME_ARM64_PACKAGE_SHA256="$(_prereq_sha256_file "$_tmpdir/artifacts/biome/package/package.json")"
_MDM_CC_SAFETY_NET_ARCHIVE_SHA256="$(_prereq_sha256_file "$_tmpdir/artifacts/safety.tgz")"
_MDM_CC_SAFETY_NET_JS_SHA256="$(_prereq_sha256_file "$_tmpdir/artifacts/safety/package/dist/bin/cc-safety-net.js")"
_MDM_CC_SAFETY_NET_PACKAGE_SHA256="$(_prereq_sha256_file "$_tmpdir/artifacts/safety/package/package.json")"

_mdm_current_darwin_arch() { printf '%s' arm64; }
_mdm_resolve_private_node_toolchain() {
  _MDM_PREREQ_NODE="$_mdm_test_node"
  _MDM_PREREQ_NPM="$_tmpdir/fake/npm"
  KIT_MDM_NODE_RUNTIME_ROOT="$_tmpdir/private-node"
  KIT_MDM_NODE_PATH="$_MDM_PREREQ_NODE"
  KIT_MDM_NPM_PATH="$_MDM_PREREQ_NPM"
  export KIT_MDM_NODE_RUNTIME_ROOT KIT_MDM_NODE_PATH KIT_MDM_NPM_PATH
}
_mdm_download_pinned_artifact() {
  local url="$1" expected="$2" destination="$3" source
  case "$url" in
    "$_MDM_BIOME_ARM64_URL") source="$_tmpdir/artifacts/biome.tgz" ;;
    "$_MDM_CC_SAFETY_NET_URL") source="$_tmpdir/artifacts/safety.tgz" ;;
    *) return 90 ;;
  esac
  [[ "$(_prereq_sha256_file "$source")" == "$expected" ]] || return 91
  printf '%s\n' "$url" >> "$_tmpdir/downloads.log"
  /bin/cp "$source" "$destination"
}
printf '%s\n' \
  '#!/bin/bash' \
  ": > \"$_tmpdir/npm-called\"" \
  'exit 99' \
  > "$_tmpdir/fake/npm"
chmod +x "$_tmpdir/fake/npm"
export PATH="$_tmpdir/fake:/usr/bin:/bin"

# The managed requirement is authoritative and strict. Profiles with no Node
# consumer skip it; malformed values fail instead of silently selecting PATH.
export KIT_MDM_REQUIRE_NODE_RUNTIME=false
run_func check_node
_node_skip_rc="$_RF_RC"
export KIT_MDM_REQUIRE_NODE_RUNTIME=invalid
run_func check_node
_node_invalid_rc="$_RF_RC"
if [[ "$_node_skip_rc" -eq 0 && "$_node_invalid_rc" -ne 0 ]]; then
  pass "prerequisites: MDM Node requirement skips false and rejects malformed values"
else
  fail "prerequisites: MDM Node requirement flag was not enforced strictly"
fi

export KIT_MDM_REQUIRE_NODE_RUNTIME=true KIT_MDM_PREREQ_MODE=auto
run_func check_node
if assert_exit_code 0 "$_RF_RC" \
  && [[ -L "$HOME/.local/bin/node" ]] \
  && [[ "$(/usr/bin/readlink "$HOME/.local/bin/node")" == "$_mdm_test_node" ]]; then
  pass "prerequisites: MDM auto activates only the exact private Node path"
else
  fail "prerequisites: MDM auto did not create the exact private Node activation"
fi

/bin/rm -f "$HOME/.local/bin/node"
export KIT_MDM_PREREQ_MODE=fail
run_func check_node
if [[ "$_RF_RC" -eq 0 && -L "$HOME/.local/bin/node" \
  && "$(/usr/bin/readlink "$HOME/.local/bin/node")" == "$_mdm_test_node" \
  && ! -e "$_tmpdir/downloads.log" ]]; then
  pass "prerequisites: MDM fail activates a preseeded private Node tree offline"
else
  fail "prerequisites: MDM fail did not create the missing offline activation"
fi

/bin/rm -f "$HOME/.local/bin/node"
/bin/ln -s "$_tmpdir/fake/node" "$HOME/.local/bin/node"
run_func check_node
if [[ "$_RF_RC" -eq 0 \
  && "$(/usr/bin/readlink "$HOME/.local/bin/node")" == "$_mdm_test_node" \
  && ! -e "$_tmpdir/downloads.log" ]]; then
  pass "prerequisites: MDM fail repairs only the user activation offline"
else
  fail "prerequisites: MDM fail retained an invalid Node activation"
fi

/bin/rm -f "$HOME/.local/bin/node"
/bin/mkdir "$HOME/.local/bin/node"
printf 'user data\n' > "$HOME/.local/bin/node/keep.txt"
run_func check_node
if [[ "$_RF_RC" -ne 0 && -d "$HOME/.local/bin/node" \
  && "$(< "$HOME/.local/bin/node/keep.txt")" == 'user data' \
  && -z "$(compgen -G "$HOME/.local/bin/.node.*" || true)" ]]; then
  pass "prerequisites: MDM fail never replaces or deletes a Node activation directory"
else
  fail "prerequisites: MDM fail mutated a user-owned Node activation directory"
fi
/bin/rm -rf "$HOME/.local/bin/node"
/bin/ln -s "$_mdm_test_node" "$HOME/.local/bin/node"

# PATH shadows and hostile pre-created leaves are never accepted as baselines.
cat > "$_tmpdir/fake/biome" <<'EOF'
#!/bin/bash
printf 'Version: 9.9.9\n'
EOF
cat > "$_tmpdir/fake/cc-safety-net" <<'EOF'
#!/bin/bash
printf '9.9.9\n'
EOF
chmod +x "$_tmpdir/fake/biome" "$_tmpdir/fake/cc-safety-net"
_fake_biome_rc=0 _fake_safety_rc=0
check_mdm_biome_baseline >/dev/null 2>&1 || _fake_biome_rc=$?
check_mdm_cc_safety_net_baseline >/dev/null 2>&1 || _fake_safety_rc=$?
if [[ "$_fake_biome_rc" -ne 0 && "$_fake_safety_rc" -ne 0 ]]; then
  pass "prerequisites: MDM fail rejects arbitrary PATH hook binaries"
else
  fail "prerequisites: MDM fail trusted an arbitrary PATH hook binary"
fi

mkdir -p "$HOME/.local/bin/biome" "$_tmpdir/external-biome"
printf 'preserve\n' > "$HOME/.local/bin/biome/untrusted"
printf 'preserve\n' > "$_tmpdir/external-biome/preserve"
mkdir -p "$HOME/.local/lib/claude-code-starter-kit/biome"
ln -s "$_tmpdir/external-biome" \
  "$HOME/.local/lib/claude-code-starter-kit/biome/2.5.4"
export KIT_MDM_PREREQ_MODE=auto
_auto_biome_dir_rc=0
install_mdm_biome >/dev/null 2>&1 || _auto_biome_dir_rc=$?
if [[ "$_auto_biome_dir_rc" -ne 0 \
  && "$(< "$HOME/.local/bin/biome/untrusted")" == preserve ]]; then
  pass "prerequisites: MDM component link never replaces a user-owned directory"
else
  fail "prerequisites: MDM component link mutated a user-owned directory"
fi
/bin/rm -rf "$HOME/.local/bin/biome"
_auto_biome_rc=0 _auto_safety_rc=0
install_mdm_biome >/dev/null 2>&1 || _auto_biome_rc=$?
install_mdm_cc_safety_net >/dev/null 2>&1 || _auto_safety_rc=$?
if [[ "$_auto_biome_rc" -eq 0 && "$_auto_safety_rc" -eq 0 \
  && "$KIT_MDM_BIOME_COMPONENT_ROOT" == \
    "$HOME/.local/lib/claude-code-starter-kit/biome/2.5.4" \
  && "$KIT_MDM_BIOME_COMMAND_PATH" == \
    "$HOME/.local/lib/claude-code-starter-kit/biome/2.5.4/biome" \
  && "$KIT_MDM_CC_SAFETY_NET_COMPONENT_ROOT" == \
    "$HOME/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6" \
  && "$KIT_MDM_CC_SAFETY_NET_COMMAND_PATH" == \
    "$HOME/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6/bin/cc-safety-net" \
  && -f "$_tmpdir/external-biome/preserve" \
  && ! -e "$_tmpdir/npm-called" \
  && "$(wc -l < "$_tmpdir/downloads.log" | /usr/bin/tr -d '[:space:]')" == 2 ]]; then
  pass "prerequisites: MDM auto converges hook CLIs from pinned native artifacts"
else
  fail "prerequisites: MDM pinned hook CLI installation did not converge"
fi

_baseline_before="$(snapshot_dir_checksum "$HOME/.local/lib/claude-code-starter-kit")"
_downloads_before="$(wc -l < "$_tmpdir/downloads.log" | /usr/bin/tr -d '[:space:]')"
export KIT_MDM_PREREQ_MODE=fail
if check_mdm_biome_baseline >/dev/null 2>&1 \
  && check_mdm_cc_safety_net_baseline >/dev/null 2>&1 \
  && [[ "$(snapshot_dir_checksum "$HOME/.local/lib/claude-code-starter-kit")" \
      == "$_baseline_before" \
    && "$(wc -l < "$_tmpdir/downloads.log" | /usr/bin/tr -d '[:space:]')" \
      == "$_downloads_before" ]]; then
  pass "prerequisites: MDM fail validates pinned hook trees offline and read-only"
else
  fail "prerequisites: MDM fail mutated or rejected the pinned hook baseline"
fi

# The installed wrapper is executable text, but its trust decision remains
# byte-exact: shell-visible canonical text plus a trailing NUL is not valid.
_safety_wrapper="$HOME/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6/bin/cc-safety-net"
_safety_script="$HOME/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6/dist/bin/cc-safety-net.js"
_safety_unicode_node="$HOME/利用者 node"
_safety_unicode_script="$HOME/安全 script.js"
_safety_wrapper_utf8="$(
  /usr/bin/env LC_ALL=C.UTF-8 /bin/bash --noprofile --norc -c '
    source "$1"
    _mdm_expected_safety_wrapper "$2" "$3"
  ' prerequisite-wrapper-locale "$PROJECT_DIR/lib/prerequisites.sh" \
    "$_safety_unicode_node" "$_safety_unicode_script"
)"
_safety_user_octets='\345\210\251\347\224\250\350\200\205'
_safety_script_octets='\345\256\211\345\205\250'
if [[ "$_safety_wrapper_utf8" == *"$_safety_user_octets"* \
  && "$_safety_wrapper_utf8" == *"$_safety_script_octets"* \
  && "$_safety_wrapper_utf8" != *'利用者'* \
  && "$_safety_wrapper_utf8" != *'安全'* ]]; then
  pass "prerequisites: MDM Safety wrapper uses canonical C-locale bytes"
else
  fail "prerequisites: MDM Safety wrapper depends on the caller locale"
fi
_safety_wrapper_exact_rc=0
check_mdm_cc_safety_net_baseline \
  >/dev/null 2>&1 || _safety_wrapper_exact_rc=$?
printf '\000' >> "$_safety_wrapper"
_safety_wrapper_nul_rc=0
check_mdm_cc_safety_net_baseline \
  >/dev/null 2>&1 || _safety_wrapper_nul_rc=$?
_mdm_expected_safety_wrapper "$_mdm_test_node" "$_safety_script" \
  > "$_safety_wrapper"
/bin/chmod 755 "$_safety_wrapper"
_safety_wrapper_restored_rc=0
check_mdm_cc_safety_net_baseline \
  >/dev/null 2>&1 || _safety_wrapper_restored_rc=$?
if [[ "$_safety_wrapper_exact_rc" -eq 0 \
  && "$_safety_wrapper_nul_rc" -ne 0 \
  && "$_safety_wrapper_restored_rc" -eq 0 ]]; then
  pass "prerequisites: MDM Safety wrapper requires exact canonical bytes"
else
  fail "prerequisites: MDM Safety wrapper accepted trailing bytes"
fi

printf 'tamper\n' >> "$HOME/.local/lib/claude-code-starter-kit/biome/2.5.4/biome"
if ! check_mdm_biome_baseline >/dev/null 2>&1; then
  pass "prerequisites: MDM Biome baseline rejects inner artifact tampering"
else
  fail "prerequisites: MDM Biome baseline accepted a tampered binary"
fi

_safety_wrapper="$HOME/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6/bin/cc-safety-net"
/usr/bin/sed -e "s|$_mdm_test_node|$_tmpdir/fake/node|" \
  "$_safety_wrapper" > "$_tmpdir/wrapper-tampered"
/bin/mv "$_tmpdir/wrapper-tampered" "$_safety_wrapper"
/bin/chmod 755 "$_safety_wrapper"
if ! check_mdm_cc_safety_net_baseline >/dev/null 2>&1; then
  pass "prerequisites: MDM Safety baseline rejects a changed private Node binding"
else
  fail "prerequisites: MDM Safety baseline accepted a changed Node binding"
fi

mkdir -p "$_tmpdir/symlink-archive/package"
ln -s /etc/passwd "$_tmpdir/symlink-archive/package/biome"
( cd "$_tmpdir/symlink-archive" && /usr/bin/tar -czf ../symlink.tgz package )
if ! _mdm_extract_pinned_regular_member "$_tmpdir/symlink.tgz" package/biome \
    "$_tmpdir/extracted-biome" \
  && [[ ! -e "$_tmpdir/extracted-biome" ]]; then
  pass "prerequisites: MDM safe extraction rejects non-regular archive members"
else
  fail "prerequisites: MDM safe extraction accepted a symlink member"
fi

_mdm_codesign_requirement=""
_mdm_prereq_codesign() {
  if [[ "$1" == "--verify" ]]; then
    _mdm_codesign_requirement="$*"
    return 0
  fi
  printf '%s\n' \
    'Identifier=node' \
    'TeamIdentifier=HX7739G8FX' \
    'Authority=Developer ID Application: Node.js Foundation (HX7739G8FX)' \
    'Authority=Developer ID Certification Authority' \
    'Authority=Apple Root CA'
}
if _mdm_private_node_signature_trusted "$_mdm_test_node" \
  && [[ "$_mdm_codesign_requirement" == *'identifier "node"'* \
    && "$_mdm_codesign_requirement" == *'1.2.840.113635.100.6.2.6'* \
    && "$_mdm_codesign_requirement" == *'1.2.840.113635.100.6.1.13'* \
    && "$_mdm_codesign_requirement" == *'HX7739G8FX'* ]]; then
  pass "prerequisites: private Node requires the full Developer ID identity"
else
  fail "prerequisites: private Node codesign requirement is incomplete"
fi
_mdm_prereq_codesign() {
  [[ "$1" == "--verify" ]] && return 0
  printf '%s\n' 'Identifier=node' 'TeamIdentifier=HX7739G8FX'
}
if ! _mdm_private_node_signature_trusted "$_mdm_test_node"; then
  pass "prerequisites: private Node rejects an incomplete certificate chain"
else
  fail "prerequisites: private Node accepted incomplete codesign details"
fi

if (
  eval "$_orig_mdm_arch"
  _mdm_prereq_sysctl() {
    [[ "$#" -eq 2 && "$1" == -in && "$2" == hw.optional.arm64 ]] \
      || return 9
    printf '%s' "$_mdm_prereq_arch_sysctl_value"
    return "$_mdm_prereq_arch_sysctl_rc"
  }
  _mdm_prereq_uname() {
    case "$1" in
      -s) printf '%s' Darwin ;;
      -m) printf '%s' "$_mdm_prereq_arch_machine" ;;
      *) return 9 ;;
    esac
  }
  _mdm_prereq_arch_case() { # <sysctl-value> <sysctl-rc> <uname-m> <expected>
    _mdm_prereq_arch_sysctl_value="$1"
    _mdm_prereq_arch_sysctl_rc="$2"
    _mdm_prereq_arch_machine="$3"
    if _mdm_prereq_arch_actual="$(_mdm_current_darwin_arch 2>/dev/null)"; then
      _mdm_prereq_arch_rc=0
    else
      _mdm_prereq_arch_rc=$?
    fi
    if [[ "$4" == FAIL ]]; then
      [[ "$_mdm_prereq_arch_rc" -ne 0 && -z "$_mdm_prereq_arch_actual" ]]
    else
      [[ "$_mdm_prereq_arch_rc" -eq 0 \
        && "$_mdm_prereq_arch_actual" == "$4" ]]
    fi
  }
  _mdm_prereq_arch_case '' 0 x86_64 x64 \
    && _mdm_prereq_arch_case 0 0 x86_64 x64 \
    && _mdm_prereq_arch_case 1 0 arm64 arm64 \
    && _mdm_prereq_arch_case 1 0 x86_64 arm64 \
    && _mdm_prereq_arch_case invalid 0 x86_64 FAIL \
    && _mdm_prereq_arch_case 1 0 unknown FAIL \
    && _mdm_prereq_arch_case '' 1 x86_64 FAIL
); then
  pass "prerequisites: MDM architecture handles Intel, native ARM, and Rosetta"
else
  fail "prerequisites: MDM architecture contract is not fail-closed"
fi

eval "$_orig_mdm_arch"
eval "$_orig_mdm_toolchain"
eval "$_orig_mdm_download"
eval "$_orig_mdm_codesign"
_MDM_BIOME_ARM64_ARCHIVE_SHA256="$_saved_biome_archive_sha"
_MDM_BIOME_ARM64_BINARY_SHA256="$_saved_biome_binary_sha"
_MDM_BIOME_ARM64_PACKAGE_SHA256="$_saved_biome_package_sha"
_MDM_CC_SAFETY_NET_ARCHIVE_SHA256="$_saved_safety_archive_sha"
_MDM_CC_SAFETY_NET_JS_SHA256="$_saved_safety_js_sha"
_MDM_CC_SAFETY_NET_PACKAGE_SHA256="$_saved_safety_package_sha"
export HOME="$_saved_home" PATH="$_saved_path"
if [[ -n "$_saved_mdm_managed" ]]; then export KIT_MDM_MANAGED="$_saved_mdm_managed"; else unset KIT_MDM_MANAGED; fi
if [[ -n "$_saved_mdm_mode" ]]; then export KIT_MDM_PREREQ_MODE="$_saved_mdm_mode"; else unset KIT_MDM_PREREQ_MODE; fi
if [[ -n "$_saved_mdm_require_node" ]]; then export KIT_MDM_REQUIRE_NODE_RUNTIME="$_saved_mdm_require_node"; else unset KIT_MDM_REQUIRE_NODE_RUNTIME; fi
unset KIT_MDM_BIOME_COMPONENT_ROOT KIT_MDM_BIOME_COMMAND_PATH
unset KIT_MDM_CC_SAFETY_NET_COMPONENT_ROOT KIT_MDM_CC_SAFETY_NET_COMMAND_PATH
unset KIT_MDM_NODE_RUNTIME_ROOT KIT_MDM_NODE_PATH KIT_MDM_NPM_PATH
unset _MDM_PREREQ_NODE _MDM_PREREQ_NPM
unset _mdm_digest_root _mdm_digest_one _mdm_digest_marker_changed \
  _mdm_digest_payload_changed _mdm_digest_writable_rc _mdm_resolver_source
rm -rf "$_tmpdir"

# ── PATH persistence failures propagate across multiple RC files ─────────

_saved_path="$PATH"
_tmpdir="$(mktemp -d)"
_orig_get_shell_rc_files="$(declare -f _get_shell_rc_files)"
_get_shell_rc_files() {
  printf '%s\n' "$_tmpdir/missing/first.rc" "$_tmpdir/second.rc"
}
_path_rc=0
_add_to_path_now_and_persist "$_tmpdir/tool/bin" test \
  >/dev/null 2>&1 || _path_rc=$?
if [[ "$_path_rc" -ne 0 && ! -e "$_tmpdir/second.rc" ]]; then
  pass "prerequisites: RC persistence stops and fails on the first write error"
else
  fail "prerequisites: RC persistence write error was masked by a later RC file"
fi
export PATH="$_saved_path"
eval "$_orig_get_shell_rc_files"
rm -rf "$_tmpdir"

# An ordinary keg-only Node must not become transiently visible when its
# shell-RC persistence fails. check_node must surface the failure instead of
# accepting the PATH mutation left by the failed activation attempt.
_saved_path="$PATH"
_saved_distro_family="${DISTRO_FAMILY:-}"
_tmpdir="$(mktemp -d)"
mkdir -p "$_tmpdir/prefix/bin"
printf '#!/bin/bash\nprintf "v24.0.0\\n"\n' > "$_tmpdir/prefix/bin/node"
chmod +x "$_tmpdir/prefix/bin/node"
DISTRO_FAMILY=macos
export PATH="/usr/bin:/bin"
_orig_add_path="$(declare -f _add_to_path_now_and_persist)"
_orig_install_node="$(declare -f _install_node)"
brew() {
  [[ "$1" == --prefix ]] && printf '%s\n' "$_tmpdir/prefix"
}
_add_to_path_now_and_persist() {
  export PATH="$1:$PATH"
  return 1
}
_install_node() { return 1; }
_node_activation_rc=0
check_node >/dev/null 2>&1 || _node_activation_rc=$?
if [[ "$_node_activation_rc" -ne 0 && "$PATH" == "/usr/bin:/bin" ]]; then
  pass "prerequisites: keg-only Node RC failure rolls back PATH and remains fatal"
else
  fail "prerequisites: keg-only Node RC failure was masked by transient PATH"
fi
unset -f brew
eval "$_orig_add_path"
eval "$_orig_install_node"
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

# ── check_node upgrades existing Node.js below minimum ───────────────────

_saved_path="$PATH"
_tmpdir="$(mktemp -d)"
export PATH="$_tmpdir:/usr/bin:/bin"
cat > "$_tmpdir/node" <<'EOF'
#!/bin/bash
echo v20.19.0
EOF
chmod +x "$_tmpdir/node"
_orig_install_node="$(declare -f _install_node)"
_install_node() {
  cat > "$_tmpdir/node" <<'EOF'
#!/bin/bash
echo v24.3.0
EOF
  chmod +x "$_tmpdir/node"
}
run_func check_node
if assert_exit_code 0 "$_RF_RC" \
  && assert_matches "below required 22.19" "$_RF_STDERR" \
  && assert_matches "node v24.3.0 installed" "$_RF_STDOUT"; then
  pass "prerequisites: check_node upgrades Node.js below minimum major"
else
  fail "prerequisites: check_node did not upgrade old Node.js"
fi
eval "$_orig_install_node"
export PATH="$_saved_path"
rm -rf "$_tmpdir"

# ── macOS Node fallback checks the supported version, not command presence ─

_orig_brew_is_usable="$(declare -f _brew_is_usable)"
_orig_install_node_via_nvm="$(declare -f _install_node_via_nvm)"
_saved_distro_family="${DISTRO_FAMILY:-}"
_saved_mdm_managed="${KIT_MDM_MANAGED:-}"
_saved_mdm_mode="${KIT_MDM_PREREQ_MODE:-}"
DISTRO_FAMILY=macos
KIT_MDM_MANAGED=false
KIT_MDM_PREREQ_MODE=auto
_brew_is_usable() { return 1; }
_install_node_via_nvm() { _node_nvm_called=$((_node_nvm_called + 1)); }
node() { printf '%s\n' v22.18.9; }
_node_nvm_called=0
_node_old_rc=0
_install_node >/dev/null 2>&1 || _node_old_rc=$?
node() { printf '%s\n' v22.19.0; }
_node_supported_rc=0
_install_node >/dev/null 2>&1 || _node_supported_rc=$?
node() { printf '%s\n' v22.18.9; }
curl() { return 0; }
sudo() { return 0; }
for _node_fallback_family in debian rhel; do
  DISTRO_FAMILY="$_node_fallback_family"
  _install_node >/dev/null 2>&1 || _node_supported_rc=$?
done
if [[ "$_node_old_rc" -eq 0 && "$_node_supported_rc" -eq 0 \
  && "$_node_nvm_called" -eq 3 ]]; then
  pass "prerequisites: Node fallback upgrades an unsupported effective PATH version"
else
  fail "prerequisites: package-manager success incorrectly suppresses old-Node fallback"
fi
unset -f node curl sudo
eval "$_orig_brew_is_usable"
eval "$_orig_install_node_via_nvm"
DISTRO_FAMILY="$_saved_distro_family"
KIT_MDM_MANAGED="$_saved_mdm_managed"
KIT_MDM_PREREQ_MODE="$_saved_mdm_mode"
unset _node_fallback_family

{
  test_name="prerequisites: default Node.js install major is 24 and minimum is 22.19"
  if [[ "$NODE_MAJOR" == "24" && "$NODE_MIN_MAJOR" == "22" \
    && "$NODE_MIN_MINOR" == "19" ]] \
    && grep -q 'nvm/v0.40.5/install.sh' "$PROJECT_DIR/lib/prerequisites.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="prerequisites: Node runtime boundary rejects 22.18 and accepts 22.19"
  if ! _prereq_node_version_is_supported v22.18.9 \
    && _prereq_node_version_is_supported v22.19.0 \
    && _prereq_node_version_is_supported v23.0.0; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

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
