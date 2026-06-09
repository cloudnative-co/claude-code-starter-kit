#!/bin/bash
# tests/unit/test-safety-net-install.sh - Unit tests for cc-safety-net auto-install (#68)
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

_sn_hooks="$PROJECT_DIR/features/safety-net/hooks.json"

# ── hooks.json uses the canonical STRICT env name ──────────────────────────

if jq -e '.env.CC_SAFETY_NET_STRICT == "1"' "$_sn_hooks" >/dev/null 2>&1; then
  pass "safety-net: hooks.json sets canonical CC_SAFETY_NET_STRICT=1"
else
  fail "safety-net: hooks.json is missing CC_SAFETY_NET_STRICT=1"
fi

if jq -e '.env.SAFETY_NET_STRICT == "1"' "$_sn_hooks" >/dev/null 2>&1; then
  pass "safety-net: hooks.json keeps legacy SAFETY_NET_STRICT=1 for pre-1.0 binaries"
else
  fail "safety-net: hooks.json dropped legacy SAFETY_NET_STRICT (breaks strict mode for old binaries)"
fi

# ── hooks.json hook wiring ─────────────────────────────────────────────────

if jq -e '.hooks.PreToolUse[0].matcher == "Bash"' "$_sn_hooks" >/dev/null 2>&1 \
  && jq -e '.hooks.PreToolUse[0].hooks[0].command == "cc-safety-net --claude-code"' "$_sn_hooks" >/dev/null 2>&1; then
  pass "safety-net: hooks.json PreToolUse targets Bash with cc-safety-net --claude-code"
else
  fail "safety-net: hooks.json PreToolUse matcher/command is not as expected"
fi

# ── profiles declare ENABLE_SAFETY_NET as designed ─────────────────────────

if grep -q 'ENABLE_SAFETY_NET=false' "$PROJECT_DIR/profiles/minimal.conf" \
  && grep -q 'ENABLE_SAFETY_NET=true' "$PROJECT_DIR/profiles/standard.conf" \
  && grep -q 'ENABLE_SAFETY_NET=true' "$PROJECT_DIR/profiles/full.conf"; then
  pass "safety-net: profiles declare ENABLE_SAFETY_NET as designed"
else
  fail "safety-net: profiles are missing expected ENABLE_SAFETY_NET values"
fi

# ── setup.sh wires the auto-install ────────────────────────────────────────

if grep -q '^should_auto_install_cc_safety_net()' "$PROJECT_DIR/setup.sh" \
  && grep -q '^maybe_install_cc_safety_net()' "$PROJECT_DIR/setup.sh" \
  && grep -q '^maybe_install_cc_safety_net$' "$PROJECT_DIR/setup.sh"; then
  pass "safety-net: setup.sh defines and invokes maybe_install_cc_safety_net"
else
  fail "safety-net: setup.sh is missing the cc-safety-net auto-install wiring"
fi

if grep -q 'SAFETY_NET_SKIP_NPM_INSTALL' "$PROJECT_DIR/setup.sh" \
  && grep -q 'SAFETY_NET_SKIP_NPM_INSTALL' "$PROJECT_DIR/tests/helpers.sh"; then
  pass "safety-net: test harness opt-out (SAFETY_NET_SKIP_NPM_INSTALL) is wired"
else
  fail "safety-net: SAFETY_NET_SKIP_NPM_INSTALL opt-out is missing"
fi

if grep -q '_dryrun_log "EXTERNAL" "cc-safety-net"' "$PROJECT_DIR/setup.sh"; then
  pass "safety-net: dry-run logs the npm install as an external action"
else
  fail "safety-net: dry-run external log entry is missing"
fi

# ── uninstall.sh offers prompted removal ───────────────────────────────────

if grep -q 'npm list -g cc-safety-net' "$PROJECT_DIR/uninstall.sh" \
  && grep -q 'npm uninstall -g cc-safety-net' "$PROJECT_DIR/uninstall.sh"; then
  pass "safety-net: uninstall.sh offers prompted cc-safety-net removal"
else
  fail "safety-net: uninstall.sh is missing the cc-safety-net removal section"
fi

# ── check_cc_safety_net: functional tests with stubbed PATH ────────────────

_sn_tmpdir="$(mktemp -d)"
export CC_SN_TEST_PREFIX="$_sn_tmpdir/prefix"
export CC_SN_TEST_LOG="$_sn_tmpdir/npm.log"
mkdir -p "$CC_SN_TEST_PREFIX/bin" "$_sn_tmpdir/stub-installed" "$_sn_tmpdir/stub-npm" "$_sn_tmpdir/stub-empty"
: > "$CC_SN_TEST_LOG"

# Stub npm: answers `config get prefix` and creates the binary on `install -g`
cat > "$_sn_tmpdir/stub-npm/npm" <<'EOF'
#!/bin/bash
PATH="/usr/bin:/bin"
if [[ "${1:-}" == "config" && "${2:-}" == "get" && "${3:-}" == "prefix" ]]; then
  printf '%s\n' "$CC_SN_TEST_PREFIX"
  exit 0
fi
if [[ "${1:-}" == "install" && "${2:-}" == "-g" && "${*: -1}" == "cc-safety-net" ]]; then
  printf '%s\n' "$*" >> "$CC_SN_TEST_LOG"
  printf '#!/bin/bash\necho 1.0.1\n' > "$CC_SN_TEST_PREFIX/bin/cc-safety-net"
  chmod +x "$CC_SN_TEST_PREFIX/bin/cc-safety-net"
  exit 0
fi
exit 1
EOF
chmod +x "$_sn_tmpdir/stub-npm/npm"

# Pre-installed cc-safety-net stub
printf '#!/bin/bash\necho 1.0.1\n' > "$_sn_tmpdir/stub-installed/cc-safety-net"
chmod +x "$_sn_tmpdir/stub-installed/cc-safety-net"

# Case 1: binary already present → success without calling npm
_sn_rc=0
( PATH="$_sn_tmpdir/stub-installed:/usr/bin:/bin"; check_cc_safety_net >/dev/null 2>&1 ) || _sn_rc=$?
if [[ "$_sn_rc" -eq 0 ]] && ! grep -q 'install' "$CC_SN_TEST_LOG"; then
  pass "safety-net: check_cc_safety_net is a no-op when binary already exists"
else
  fail "safety-net: check_cc_safety_net misbehaved for an existing binary (rc=$_sn_rc)"
fi

# Case 2: binary missing, writable npm prefix → installs via npm and succeeds
_sn_rc=0
# shellcheck disable=SC2123  # intentionally restrict the search path to the stubs
( PATH="$_sn_tmpdir/stub-npm"; check_cc_safety_net >/dev/null 2>&1 ) || _sn_rc=$?
if [[ "$_sn_rc" -eq 0 ]] && grep -q 'install -g' "$CC_SN_TEST_LOG" \
  && grep -q -- '--ignore-scripts' "$CC_SN_TEST_LOG"; then
  pass "safety-net: check_cc_safety_net installs via npm with --ignore-scripts"
else
  fail "safety-net: check_cc_safety_net did not install via npm with --ignore-scripts (rc=$_sn_rc)"
fi

# Case 3: no npm available → non-fatal failure (returns 1, no crash)
_sn_rc=0
# shellcheck disable=SC2123  # intentionally restrict the search path to the stubs
( PATH="$_sn_tmpdir/stub-empty"; check_cc_safety_net >/dev/null 2>&1 ) || _sn_rc=$?
if [[ "$_sn_rc" -eq 1 ]]; then
  pass "safety-net: check_cc_safety_net fails gracefully without npm"
else
  fail "safety-net: check_cc_safety_net returned rc=$_sn_rc without npm (expected 1)"
fi

unset CC_SN_TEST_PREFIX CC_SN_TEST_LOG
rm -rf "$_sn_tmpdir"
