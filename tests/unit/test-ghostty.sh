#!/bin/bash
# tests/unit/test-ghostty.sh - Unit tests for trusted Ghostty installation

_SETUP_TMP_FILES=()

source "$PROJECT_DIR/lib/colors.sh"
source "$PROJECT_DIR/lib/prerequisites.sh"
source "$PROJECT_DIR/lib/fonts.sh"
source "$PROJECT_DIR/lib/ghostty.sh"

_ghostty_test_managed_set=0
[[ -n "${KIT_MDM_MANAGED+x}" ]] && _ghostty_test_managed_set=1
_ghostty_test_managed="${KIT_MDM_MANAGED:-}"
_ghostty_test_mode_set=0
[[ -n "${KIT_MDM_PREREQ_MODE+x}" ]] && _ghostty_test_mode_set=1
_ghostty_test_mode="${KIT_MDM_PREREQ_MODE:-}"
unset KIT_MDM_MANAGED KIT_MDM_PREREQ_MODE

_ghostty_test_host_os="${GHOSTTY_TEST_HOST_OS_OVERRIDE:-$(/usr/bin/uname -s 2>/dev/null || true)}"
_ghostty_test_is_macos() {
  [[ "$_ghostty_test_host_os" == "Darwin" ]]
}

{
  test_name="ghostty: MDM boolean vocabulary accepts y consistently"
  if (
    export KIT_MDM_MANAGED=y
    _ghostty_mdm_managed
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

_ghostty_test_make_app() {
  local app="$1"
  mkdir -p "$app/Contents/MacOS"
  printf 'Mach-O fixture' > "$app/Contents/MacOS/ghostty"
  chmod +x "$app/Contents/MacOS/ghostty"
}

{
  test_name="ghostty: MDM verifies the exact Developer ID requirement"
  if (
    _tmpdir="$(mktemp -d)"
    _app="$_tmpdir/Ghostty.app"
    _ghostty_test_make_app "$_app"
    _codesign_args=()
    _ghostty_codesign() { _codesign_args=("$@"); return 0; }
    ghostty_mdm_is_trusted "$_app" \
      && [[ "${_codesign_args[0]}" == "--verify" \
        && "${_codesign_args[1]}" == "--deep" \
        && "${_codesign_args[2]}" == "--strict" \
        && "${_codesign_args[3]}" == "-R" \
        && "${_codesign_args[4]}" \
          == '=identifier "com.mitchellh.ghostty" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "24VZTF6M5V"' \
        && "${_codesign_args[5]}" == "--" \
        && "${_codesign_args[6]}" == "$_app" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="ghostty: MDM rejects a symlinked main executable before codesign"
  if (
    _tmpdir="$(mktemp -d)"
    _app="$_tmpdir/Ghostty.app"
    mkdir -p "$_app/Contents/MacOS"
    printf 'outside' > "$_tmpdir/ghostty"
    chmod +x "$_tmpdir/ghostty"
    ln -s "$_tmpdir/ghostty" "$_app/Contents/MacOS/ghostty"
    _codesign_called=0
    _ghostty_codesign() { _codesign_called=1; return 0; }
    ! ghostty_mdm_is_trusted "$_app" \
      && [[ "$_codesign_called" -eq 0 ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="ghostty: MDM rejects an app that fails the external requirement"
  if (
    _tmpdir="$(mktemp -d)"
    _app="$_tmpdir/Ghostty.app"
    _ghostty_test_make_app "$_app"
    _ghostty_codesign() { return 1; }
    ! ghostty_mdm_is_trusted "$_app"
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="ghostty: MDM fail mode validates without invoking Homebrew"
  if ! _ghostty_test_is_macos; then
    skip "$test_name" "requires macOS system APIs"
  elif (
    export KIT_MDM_MANAGED=true KIT_MDM_PREREQ_MODE=fail
    export STR_GHOSTTY_ALREADY_INSTALLED="already"
    _tmpdir="$(mktemp -d)"
    _ghostty_app_path() { printf '%s' "$_tmpdir/Ghostty.app"; }
    ghostty_mdm_is_trusted() { return 1; }
    _homebrew_called=0
    _ensure_homebrew() { _homebrew_called=1; }
    ! install_ghostty_mdm >/dev/null 2>&1 \
      && [[ "$_homebrew_called" -eq 0 ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="ghostty: trusted MDM auto baseline skips Homebrew"
  if ! _ghostty_test_is_macos; then
    skip "$test_name" "requires macOS system APIs"
  elif (
    export KIT_MDM_MANAGED=true KIT_MDM_PREREQ_MODE=auto
    STR_GHOSTTY_ALREADY_INSTALLED="already"
    _tmpdir="$(mktemp -d)"
    _ghostty_app_path() { printf '%s' "$_tmpdir/Ghostty.app"; }
    ghostty_mdm_is_trusted() { return 0; }
    _ghostty_quarantine_absent() { return 0; }
    _homebrew_called=0
    _ensure_homebrew() { _homebrew_called=1; }
    install_ghostty_mdm >/dev/null 2>&1 \
      && [[ "$_homebrew_called" -eq 0 ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="ghostty: MDM rejects a quarantined preinstalled app"
  if ! _ghostty_test_is_macos; then
    skip "$test_name" "requires macOS system APIs"
  elif (
    export KIT_MDM_MANAGED=true KIT_MDM_PREREQ_MODE=fail
    STR_GHOSTTY_ALREADY_INSTALLED="already"
    _tmpdir="$(mktemp -d)"
    _ghostty_app_path() { printf '%s' "$_tmpdir/Ghostty.app"; }
    ghostty_mdm_is_trusted() { return 0; }
    _ghostty_quarantine_absent() { return 1; }
    ! install_ghostty_mdm >/dev/null 2>&1
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="ghostty: invalid MDM auto baseline fails without invoking Homebrew"
  if ! _ghostty_test_is_macos; then
    skip "$test_name" "requires macOS system APIs"
  elif (
    export KIT_MDM_MANAGED=true KIT_MDM_PREREQ_MODE=auto
    STR_GHOSTTY_ALREADY_INSTALLED="already"
    _tmpdir="$(mktemp -d)"
    _ghostty_app_path() { printf '%s' "$_tmpdir/Ghostty.app"; }
    ghostty_mdm_is_trusted() { return 1; }
    _homebrew_called=0
    _ensure_homebrew() { _homebrew_called=1; return 0; }
    brew() { _homebrew_called=1; return 0; }
    ! install_ghostty_mdm >/dev/null 2>&1 \
      && [[ "$_homebrew_called" -eq 0 ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="ghostty: missing MDM auto baseline fails closed"
  if ! _ghostty_test_is_macos; then
    skip "$test_name" "requires macOS system APIs"
  elif (
    export KIT_MDM_MANAGED=true KIT_MDM_PREREQ_MODE=auto
    STR_GHOSTTY_ALREADY_INSTALLED="already"
    _tmpdir="$(mktemp -d)"
    _ghostty_app_path() { printf '%s' "$_tmpdir/Ghostty.app"; }
    ghostty_mdm_is_trusted() { return 1; }
    ! install_ghostty_mdm >/dev/null 2>&1
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="ghostty: MDM setup propagates failure and does not install unattested fonts"
  if ! _ghostty_test_is_macos; then
    skip "$test_name" "requires macOS system APIs"
  elif (
    export KIT_MDM_MANAGED=true KIT_MDM_PREREQ_MODE=auto
    GHOSTTY_INCOMPLETE=()
    _font_called=0
    install_ghostty() { return 1; }
    install_hackgen_nf() { _font_called=1; return 0; }
    ! setup_ghostty \
      && [[ "$_font_called" -eq 0 \
        && "${GHOSTTY_INCOMPLETE[*]}" == "Ghostty" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="ghostty: non-MDM setup keeps the existing HackGen side effect"
  if ! _ghostty_test_is_macos; then
    skip "$test_name" "requires macOS system APIs"
  elif (
    unset KIT_MDM_MANAGED KIT_MDM_PREREQ_MODE
    GHOSTTY_INCOMPLETE=()
    _font_called=0
    install_ghostty() { return 0; }
    install_hackgen_nf() { _font_called=1; return 0; }
    setup_ghostty \
      && [[ "$_font_called" -eq 1 ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

if [[ "$_ghostty_test_managed_set" -eq 1 ]]; then
  export KIT_MDM_MANAGED="$_ghostty_test_managed"
else
  unset KIT_MDM_MANAGED
fi
if [[ "$_ghostty_test_mode_set" -eq 1 ]]; then
  export KIT_MDM_PREREQ_MODE="$_ghostty_test_mode"
else
  unset KIT_MDM_PREREQ_MODE
fi
unset _ghostty_test_managed_set _ghostty_test_managed
unset _ghostty_test_mode_set _ghostty_test_mode
unset _ghostty_test_host_os
unset -f _ghostty_test_is_macos _ghostty_test_make_app
