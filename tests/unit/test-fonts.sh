#!/bin/bash
# tests/unit/test-fonts.sh - Unit tests for lib/fonts.sh helpers
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded).

_SETUP_TMP_FILES=()

source "$PROJECT_DIR/lib/colors.sh"
source "$PROJECT_DIR/lib/prerequisites.sh"
source "$PROJECT_DIR/lib/fonts.sh"

_fonts_test_mdm_managed_set=0
[[ -n "${KIT_MDM_MANAGED+x}" ]] && _fonts_test_mdm_managed_set=1
_fonts_test_mdm_managed="${KIT_MDM_MANAGED:-}"
_fonts_test_mdm_mode_set=0
[[ -n "${KIT_MDM_PREREQ_MODE+x}" ]] && _fonts_test_mdm_mode_set=1
_fonts_test_mdm_mode="${KIT_MDM_PREREQ_MODE:-}"
unset KIT_MDM_MANAGED KIT_MDM_PREREQ_MODE

_fonts_test_host_os="${FONTS_TEST_HOST_OS_OVERRIDE:-$(/usr/bin/uname -s 2>/dev/null || true)}"
_fonts_test_is_macos() {
  [[ "$_fonts_test_host_os" == "Darwin" ]]
}

{
  test_name="fonts: MDM boolean vocabulary accepts y consistently"
  if (
    export KIT_MDM_MANAGED=y
    _fonts_mdm_managed
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

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

{
  test_name="fonts: MDM archives and every installed TTF have pinned SHA-256"
  if [[ "$MDM_IBM_PLEX_MONO_ZIP_SHA256" \
      == "4bfc936d0e1fd19db6327a3786eabdbc3dc0d464500576f6458f6706df68d26c" \
    && "$MDM_HACKGEN_NF_ZIP_SHA256" \
      == "f8abd483d5edfad88a78ed511978f43c83b43c48e364aa29ebe4a68217474428" \
    && "$(_font_mdm_expected_inventory ibm | wc -l | tr -d ' ')" == "16" \
    && "$(_font_mdm_expected_inventory hackgen | wc -l | tr -d ' ')" == "4" ]] \
    && ! _font_mdm_expected_inventory ibm \
      | grep -Ev '^[^ ]+\.ttf [0-9a-f]{64}$' >/dev/null \
    && ! _font_mdm_expected_inventory hackgen \
      | grep -Ev '^[^ ]+\.ttf [0-9a-f]{64}$' >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="fonts: MDM does not accept files by name or TTF magic alone"
  if (
    _tmpdir="$(mktemp -d)"
    mkdir -p "$_tmpdir/Fonts"
    printf '\000\001\000\000fake' > "$_tmpdir/Fonts/IBMPlexMono-Regular.ttf"
    printf '\000\001\000\000fake' > "$_tmpdir/Fonts/HackGenConsoleNF-Regular.ttf"
    ! fonts_mdm_are_trusted "$_tmpdir/Fonts"
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="fonts: MDM TTF validation requires the per-file pinned hash"
  if (
    _tmpfile="$(mktemp)"
    printf 'fixture' > "$_tmpfile"
    _font_mdm_ttf_structure_is_valid() { return 0; }
    _font_mdm_sha256_file() { printf '%064d' 0; }
    ! _font_mdm_ttf_is_trusted \
      "$_tmpfile" ibm IBMPlexMono-Regular.ttf
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="fonts: MDM fail mode validates baseline without downloading"
  if ! _fonts_test_is_macos; then
    skip "$test_name" "requires macOS system APIs"
  elif (
    export KIT_MDM_MANAGED=true KIT_MDM_PREREQ_MODE=fail
    _downloaded=0
    fonts_mdm_are_trusted() { return 0; }
    _font_mdm_download() { _downloaded=1; return 1; }
    install_fonts_mdm "$(mktemp -d)" \
      && [[ "$_downloaded" -eq 0 ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="fonts: MDM auto always reinstalls both pinned families"
  if ! _fonts_test_is_macos; then
    skip "$test_name" "requires macOS system APIs"
  elif (
    export KIT_MDM_MANAGED=true KIT_MDM_PREREQ_MODE=auto
    _tmpdir="$(mktemp -d)"
    mkdir "$_tmpdir/Library"
    export HOME="$_tmpdir"
    _families=""
    _font_mdm_prepare_target_dir() { return 0; }
    _font_mdm_workspace() { printf -v "$1" '%s' "$_tmpdir/work"; }
    _font_mdm_install_family_auto() {
      _families="${_families}${_families:+,}$1"
      return 0
    }
    fonts_mdm_are_trusted() { return 0; }
    install_fonts_mdm \
      && [[ "$_families" == "ibm,hackgen" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="fonts: MDM extraction rejects traversal without writing outside staging"
  if (
    _tmpdir="$(mktemp -d)"
    mkdir "$_tmpdir/out"
    /usr/bin/python3 -I -B - "$_tmpdir/unsafe.zip" <<'PY'
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("../escaped.ttf", b"not-a-font")
    for name in (
        "HackGen35ConsoleNF-Bold.ttf", "HackGen35ConsoleNF-Regular.ttf",
        "HackGenConsoleNF-Bold.ttf", "HackGenConsoleNF-Regular.ttf",
    ):
        archive.writestr("HackGen_NF_v2.10.0/" + name, b"not-a-font")
PY
    ! _font_mdm_extract_archive hackgen "$_tmpdir/unsafe.zip" "$_tmpdir/out" \
      && [[ ! -e "$_tmpdir/escaped.ttf" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="fonts: MDM replacement does not follow an existing font symlink"
  if ! _fonts_test_is_macos; then
    skip "$test_name" "requires macOS filesystem tools"
  elif (
    _tmpdir="$(mktemp -d)"
    mkdir "$_tmpdir/staged" "$_tmpdir/Fonts"
    while IFS= read -r _name; do
      printf 'new-font' > "$_tmpdir/staged/$_name"
    done < <(_font_mdm_expected_names ibm)
    printf 'outside' > "$_tmpdir/outside"
    ln -s "$_tmpdir/outside" "$_tmpdir/Fonts/IBMPlexMono-Bold.ttf"
    _font_mdm_ttf_is_trusted() { return 0; }
    _font_mdm_replace_family ibm "$_tmpdir/staged" "$_tmpdir/Fonts" \
      && [[ "$(< "$_tmpdir/outside")" == "outside" ]] \
      && [[ -f "$_tmpdir/Fonts/IBMPlexMono-Bold.ttf" \
        && ! -L "$_tmpdir/Fonts/IBMPlexMono-Bold.ttf" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="fonts: MDM workspace registration survives helper return"
  if (
    _tmpdir="$(mktemp -d)"
    export TMPDIR="$_tmpdir"
    _SETUP_TMP_FILES=()
    _workspace=""
    _font_mdm_workspace _workspace \
      && [[ -d "$_workspace" \
        && "${_SETUP_TMP_FILES[0]}" == "$_workspace" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

if [[ "$_fonts_test_mdm_managed_set" -eq 1 ]]; then
  export KIT_MDM_MANAGED="$_fonts_test_mdm_managed"
else
  unset KIT_MDM_MANAGED
fi
if [[ "$_fonts_test_mdm_mode_set" -eq 1 ]]; then
  export KIT_MDM_PREREQ_MODE="$_fonts_test_mdm_mode"
else
  unset KIT_MDM_PREREQ_MODE
fi
unset _fonts_test_mdm_managed_set _fonts_test_mdm_managed
unset _fonts_test_mdm_mode_set _fonts_test_mdm_mode
unset _fonts_test_host_os
unset -f _fonts_test_is_macos
