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

# ── H1 regression: _detect_linux_distro must not die via pipefail/set -e ──
#
# `DISTRO="$(grep '^ID=' /etc/os-release | ... )"` propagates grep's
# no-match exit code (1) through the pipeline under `set -euo pipefail`.
# Called directly (as detect_os() does — not wrapped in a further command
# substitution), that used to kill the whole script silently before it
# could fall back to DISTRO="unknown". Mock /etc/os-release by sourcing a
# copy of lib/detect.sh with the path swapped for a fixture file, so the
# real detection logic runs unmodified against test input.

_dt_tmp="$(mktemp -d)"
cat > "$_dt_tmp/os-release-no-id" <<'EOF'
NAME="Weird Linux"
VERSION_ID="1.0"
EOF
cat > "$_dt_tmp/os-release-normal" <<'EOF'
NAME="Ubuntu"
ID=ubuntu
VERSION_ID="22.04"
EOF

_dt_mock_lib="$_dt_tmp/detect-mock.sh"
sed "s#/etc/os-release#$_dt_tmp/CURRENT_OS_RELEASE#g" "$PROJECT_DIR/lib/detect.sh" > "$_dt_mock_lib"

cp "$_dt_tmp/os-release-no-id" "$_dt_tmp/CURRENT_OS_RELEASE"
_dt_out="$(bash -c '
  source "$1"
  OS="linux"; ARCH="x86_64"
  _detect_linux_distro
  printf "DISTRO=%s DISTRO_FAMILY=%s" "$DISTRO" "$DISTRO_FAMILY"
' _ "$_dt_mock_lib" 2>&1)"
_dt_rc=$?
if [[ "$_dt_rc" -eq 0 ]] && [[ "$_dt_out" == "DISTRO=unknown DISTRO_FAMILY=unknown" ]]; then
  pass "detect: _detect_linux_distro falls back to unknown instead of dying when os-release lacks ID= (H1 regression)"
else
  fail "detect: _detect_linux_distro should survive a missing ID= line (rc=$_dt_rc out='$_dt_out')"
fi

cp "$_dt_tmp/os-release-normal" "$_dt_tmp/CURRENT_OS_RELEASE"
_dt_out2="$(bash -c '
  source "$1"
  OS="linux"; ARCH="x86_64"
  _detect_linux_distro
  printf "DISTRO=%s DISTRO_FAMILY=%s" "$DISTRO" "$DISTRO_FAMILY"
' _ "$_dt_mock_lib" 2>&1)"
_dt_rc2=$?
if [[ "$_dt_rc2" -eq 0 ]] && [[ "$_dt_out2" == "DISTRO=ubuntu DISTRO_FAMILY=debian" ]]; then
  pass "detect: _detect_linux_distro still resolves DISTRO/DISTRO_FAMILY normally when ID= is present"
else
  fail "detect: _detect_linux_distro should resolve ubuntu/debian normally (rc=$_dt_rc2 out='$_dt_out2')"
fi

rm -rf "$_dt_tmp"
