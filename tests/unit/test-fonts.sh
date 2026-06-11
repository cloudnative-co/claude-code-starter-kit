#!/bin/bash
# tests/unit/test-fonts.sh - Unit tests for lib/fonts.sh helpers
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded).

_SETUP_TMP_FILES=()

source "$PROJECT_DIR/lib/colors.sh"
source "$PROJECT_DIR/lib/prerequisites.sh"
source "$PROJECT_DIR/lib/fonts.sh"

{
  test_name="fonts: IBM Plex Mono uses a stable GitHub release zip"
  if [[ "$IBM_PLEX_MONO_ZIP_URL" == https://github.com/IBM/plex/releases/download/*/ibm-plex-mono.zip ]] \
    && ! grep -q 'fonts.google.com/download' "$PROJECT_DIR/lib/fonts.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="fonts: direct downloads validate zip magic bytes"
  zip_file="$(mktemp)"
  html_file="$(mktemp)"
  printf 'PK\003\004' >"$zip_file"
  printf '<!doctype html>' >"$html_file"

  if _font_zip_has_magic "$zip_file" && ! _font_zip_has_magic "$html_file"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$zip_file" "$html_file"
}

{
  test_name="fonts: Windows helpers use _run_with_timeout wrapper"
  if ! grep -Eq '(^|[;&|[:space:]])timeout[[:space:]]+[0-9]' "$PROJECT_DIR/lib/fonts.sh" \
    && grep -q '_run_with_timeout 120 powershell.exe' "$PROJECT_DIR/lib/fonts.sh" \
    && grep -q '_run_with_timeout 15 powershell.exe' "$PROJECT_DIR/lib/fonts.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="fonts: font installers are data driven wrappers"
  if grep -q '^_install_font()' "$PROJECT_DIR/lib/fonts.sh" \
    && grep -A20 '^install_ibm_plex_mono()' "$PROJECT_DIR/lib/fonts.sh" | grep -q '_install_font' \
    && grep -A20 '^install_hackgen_nf()' "$PROJECT_DIR/lib/fonts.sh" | grep -q '_install_font'; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="fonts: brew success skips direct download"
  _orig_brew="$(declare -f _brew_is_usable)"
  _orig_install_macos="$(declare -f _install_font_macos)"
  _orig_uname="$(declare -f uname 2>/dev/null || true)"
  _brew_calls=0
  _direct_calls=0
  uname() { printf 'Darwin\n'; }
  _brew_is_usable() { return 0; }
  brew() {
    if [[ "$1" == "list" ]]; then return 1; fi
    if [[ "$1" == "install" && "$2" == "--cask" && "$3" == "font-ibm-plex-mono" ]]; then
      _brew_calls=$((_brew_calls + 1))
      return 0
    fi
    return 1
  }
  _install_font_macos() { _direct_calls=$((_direct_calls + 1)); return 0; }

  run_func install_ibm_plex_mono
  if assert_exit_code 0 "$_RF_RC" \
    && assert_equals "1" "$_brew_calls" \
    && assert_equals "0" "$_direct_calls"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  unset -f brew uname
  eval "$_orig_brew"
  eval "$_orig_install_macos"
  [[ -n "$_orig_uname" ]] && eval "$_orig_uname" || true
}

{
  test_name="fonts: direct download fallback receives font definition"
  _orig_brew="$(declare -f _brew_is_usable)"
  _orig_install_macos="$(declare -f _install_font_macos)"
  _orig_uname="$(declare -f uname 2>/dev/null || true)"
  _direct_args=""
  uname() { printf 'Darwin\n'; }
  _brew_is_usable() { return 0; }
  brew() { return 1; }
  _install_font_macos() {
    _direct_args="$1|$2|$3"
    return 0
  }

  run_func install_hackgen_nf
  if assert_exit_code 0 "$_RF_RC" \
    && assert_equals "$HACKGEN_NF_ZIP_URL|HackGen_NF.zip|*.ttf" "$_direct_args"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  unset -f brew uname
  eval "$_orig_brew"
  eval "$_orig_install_macos"
  [[ -n "$_orig_uname" ]] && eval "$_orig_uname" || true
}

{
  test_name="fonts: Windows path uses PowerShell installer definition"
  _saved_path="$PATH"
  _tmpdir="$(mktemp -d)"
  : > "$_tmpdir/powershell.exe"
  chmod +x "$_tmpdir/powershell.exe"
  export PATH="$_tmpdir:$PATH"
  _orig_uname="$(declare -f uname 2>/dev/null || true)"
  _orig_is_font_installed_windows="$(declare -f _is_font_installed_windows)"
  _orig_install_windows="$(declare -f _install_font_windows)"
  _windows_args=""
  uname() { printf 'Linux\n'; }
  _is_font_installed_windows() { return 1; }
  _install_font_windows() {
    _windows_args="$1|$2|$3"
    return 0
  }

  run_func install_ibm_plex_mono
  if assert_exit_code 0 "$_RF_RC" \
    && assert_equals "$IBM_PLEX_MONO_ZIP_URL|IBMPlexMono.zip|*.ttf" "$_windows_args"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  unset -f uname
  eval "$_orig_is_font_installed_windows"
  eval "$_orig_install_windows"
  [[ -n "$_orig_uname" ]] && eval "$_orig_uname" || true
  export PATH="$_saved_path"
  rm -rf "$_tmpdir"
}
