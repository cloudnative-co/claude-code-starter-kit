#!/bin/bash
# tests/unit/test-uninstall.sh - Regression tests for uninstall.sh
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded).
#
# uninstall.sh has no BASH_SOURCE guard around its top-level flow (unlike
# install.sh), so it cannot be `source`d directly in a test without running
# its full interactive uninstall. Instead, extract the single function under
# test with the same technique used in test-install-bootstrap.sh
# (_ib_extract_fn) and source only that.

_ut_extract_fn() {
  # Usage: _ut_extract_fn <file> <function-name>
  awk -v fn="$2" '
    !inside && $0 ~ ("^" fn "\\(\\)") { inside = 1 }
    inside { print }
    inside && /^}/ { exit }
  ' "$1"
}

# ── H2 regression: _detect_language must not die via pipefail/set -e ──────
#
# `lang="$(grep '^LANGUAGE=' "$conf" | ... )"` propagates grep's no-match
# exit code (1) through the pipeline under `set -euo pipefail`. Called
# directly (not wrapped in a further command substitution), that used to
# kill the function — and the whole script — before it could reach the
# `printf 'en'` fallback at the bottom.

_ut_tmp="$(mktemp -d)"
_ut_extract_fn "$PROJECT_DIR/uninstall.sh" "_detect_language" > "$_ut_tmp/detect_language.sh"

_ut_home="$_ut_tmp/home"
mkdir -p "$_ut_home"

# conf present but missing the LANGUAGE= line (malformed/older conf)
cat > "$_ut_home/.claude-starter-kit.conf" <<'EOF'
PROFILE="standard"
EOF

_ut_out="$(HOME="$_ut_home" bash -c '
  set -euo pipefail
  MANIFEST="/nonexistent-manifest.json"
  source "$1"
  _detect_language
' _ "$_ut_tmp/detect_language.sh" 2>&1)"
_ut_rc=$?
if [[ "$_ut_rc" -eq 0 ]] && [[ "$_ut_out" == "en" ]]; then
  pass "uninstall: _detect_language falls back to 'en' instead of dying when conf lacks LANGUAGE= (H2 regression)"
else
  fail "uninstall: _detect_language should fall back to 'en' (rc=$_ut_rc out='$_ut_out')"
fi

# Normal case must still resolve LANGUAGE= from the conf correctly.
cat > "$_ut_home/.claude-starter-kit.conf" <<'EOF'
PROFILE="standard"
LANGUAGE="ja"
EOF

_ut_out2="$(HOME="$_ut_home" bash -c '
  set -euo pipefail
  MANIFEST="/nonexistent-manifest.json"
  source "$1"
  _detect_language
' _ "$_ut_tmp/detect_language.sh" 2>&1)"
_ut_rc2=$?
if [[ "$_ut_rc2" -eq 0 ]] && [[ "$_ut_out2" == "ja" ]]; then
  pass "uninstall: _detect_language still resolves LANGUAGE= from conf normally"
else
  fail "uninstall: _detect_language should resolve 'ja' from conf (rc=$_ut_rc2 out='$_ut_out2')"
fi

rm -rf "$_ut_tmp"
