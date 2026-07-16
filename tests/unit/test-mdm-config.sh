#!/bin/bash
# tests/unit/test-mdm-config.sh - Unit tests for mdm/lib-mdm-config.sh

# shellcheck source=mdm/lib-mdm-config.sh
source "$PROJECT_DIR/mdm/lib-mdm-config.sh"

# ── bool 検証 ─────────────────────────────────────────────
if out="$(mdm_validate_bool "true")" && [[ "$out" == "true" ]]; then
  pass "mdm-config: bool 'true' -> true"
else
  fail "mdm-config: bool 'true' should normalize to true (got '$out')"
fi

if out="$(mdm_validate_bool "yes")" && [[ "$out" == "true" ]]; then
  pass "mdm-config: bool 'yes' -> true"
else
  fail "mdm-config: bool 'yes' should normalize to true (got '$out')"
fi

if out="$(mdm_validate_bool "0")" && [[ "$out" == "false" ]]; then
  pass "mdm-config: bool '0' -> false"
else
  fail "mdm-config: bool '0' should normalize to false (got '$out')"
fi

if mdm_validate_bool "maybe" >/dev/null 2>&1; then
  fail "mdm-config: bool 'maybe' should be rejected"
else
  pass "mdm-config: bool 'maybe' rejected"
fi

# ── enum 検証 ─────────────────────────────────────────────
if out="$(mdm_validate_enum "standard" "minimal,standard,full")" && [[ "$out" == "standard" ]]; then
  pass "mdm-config: enum 'standard' accepted"
else
  fail "mdm-config: enum 'standard' should be accepted (got '$out')"
fi

if mdm_validate_enum "custom" "minimal,standard,full" >/dev/null 2>&1; then
  fail "mdm-config: enum 'custom' should be rejected"
else
  pass "mdm-config: enum 'custom' rejected"
fi

# ── git ref 検証（--branch 方式）────────────────────────────
for _ref in "main" "v0.72.0" "feature/x" "0123456789abcdef0123456789abcdef01234567"; do
  if mdm_validate_gitref "$_ref" >/dev/null 2>&1; then
    pass "mdm-config: gitref '$_ref' accepted"
  else
    fail "mdm-config: gitref '$_ref' should be accepted"
  fi
done
for _bad in "" "--force" "a b" "refs/../../etc" "x~1"; do
  if mdm_validate_gitref "$_bad" >/dev/null 2>&1; then
    fail "mdm-config: gitref '$_bad' should be rejected"
  else
    pass "mdm-config: gitref '$_bad' rejected"
  fi
done

# ── username 検証 ─────────────────────────────────────────
if mdm_validate_username "jane" >/dev/null 2>&1; then
  pass "mdm-config: username 'jane' accepted"
else
  fail "mdm-config: username 'jane' should be accepted"
fi
if mdm_validate_username "root; rm" >/dev/null 2>&1; then
  fail "mdm-config: username with metachar should be rejected"
else
  pass "mdm-config: username with metachar rejected"
fi

# ── abspath 検証 ──────────────────────────────────────────
if mdm_validate_abspath "/Users/jane/.claude-starter-kit" >/dev/null 2>&1; then
  pass "mdm-config: abspath accepted"
else
  fail "mdm-config: abspath should be accepted"
fi
if mdm_validate_abspath "relative/path" >/dev/null 2>&1; then
  fail "mdm-config: relative path should be rejected"
else
  pass "mdm-config: relative path rejected"
fi
if mdm_validate_abspath "/a/../../etc/passwd" >/dev/null 2>&1; then
  fail "mdm-config: path with .. should be rejected"
else
  pass "mdm-config: path with .. rejected"
fi
