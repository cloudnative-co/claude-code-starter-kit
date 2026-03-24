#!/bin/bash
# tests/unit/test-detect.sh - Unit tests for lib/detect.sh
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded).

# shellcheck source=lib/detect.sh
source "$PROJECT_DIR/lib/detect.sh"

# Run detection
detect_os

# ── OS variable is set after sourcing ─────────────────────────────────────

if assert_not_empty "$OS" "OS should be set after detect_os"; then
  pass "detect: OS is set ('$OS')"
else
  fail "detect: OS is not set"
fi

# ── ARCH variable is set after sourcing ───────────────────────────────────

if assert_not_empty "$ARCH" "ARCH should be set after detect_os"; then
  pass "detect: ARCH is set ('$ARCH')"
else
  fail "detect: ARCH is not set"
fi

# ── At least one of is_macos/is_linux returns 0 on standard platforms ─────

_uname="$(uname -s)"
case "$_uname" in
  Darwin)
    if is_macos; then
      pass "detect: is_macos returns 0 on Darwin"
    else
      fail "detect: is_macos should return 0 on Darwin"
    fi
    if ! is_linux; then
      pass "detect: is_linux returns 1 on Darwin"
    else
      fail "detect: is_linux should return 1 on Darwin"
    fi
    ;;
  Linux)
    if is_linux; then
      pass "detect: is_linux returns 0 on Linux"
    else
      fail "detect: is_linux should return 0 on Linux"
    fi
    if ! is_macos; then
      pass "detect: is_macos returns 1 on Linux"
    else
      fail "detect: is_macos should return 1 on Linux"
    fi
    ;;
  *)
    skip "detect: platform-specific is_macos/is_linux" "unsupported uname: $_uname"
    ;;
esac

# ── is_wsl should return 1 on non-WSL systems ────────────────────────────

# If WSL_DISTRO_NAME is not set and /proc/version does not contain "microsoft",
# we are not in WSL.
if [[ -z "${WSL_DISTRO_NAME:-}" ]] && ! { [[ -f /proc/version ]] && grep -qi "microsoft" /proc/version 2>/dev/null; }; then
  if ! is_wsl; then
    pass "detect: is_wsl returns 1 on non-WSL system"
  else
    fail "detect: is_wsl should return 1 on non-WSL system"
  fi
else
  skip "detect: is_wsl non-WSL check" "running inside WSL"
fi

# ── is_msys should return 1 on non-MSYS systems ──────────────────────────

if [[ "$_uname" != MSYS_NT* && "$_uname" != MINGW* ]]; then
  if ! is_msys; then
    pass "detect: is_msys returns 1 on non-MSYS system"
  else
    fail "detect: is_msys should return 1 on non-MSYS system"
  fi
else
  skip "detect: is_msys non-MSYS check" "running inside MSYS/MinGW"
fi
