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
_sn_wrapper="$PROJECT_DIR/features/safety-net/scripts/run-cc-safety-net.sh"

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

_sn_hook_command="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$_sn_hooks")"
if jq -e '.hooks.PreToolUse[0].matcher == "Bash"' "$_sn_hooks" >/dev/null 2>&1 \
  && [[ "$_sn_hook_command" \
    == '"$HOME/.claude/hooks/safety-net/run-cc-safety-net.sh" --claude-code' ]] \
  && grep -q '\[safety-net\]=true' "$PROJECT_DIR/lib/features.sh" \
  && [[ -x "$_sn_wrapper" ]]; then
  pass "safety-net: PreToolUse uses the tracked external wrapper"
else
  fail "safety-net: external wrapper wiring or tracking is incomplete"
fi

_sn_snapshot_impl="$(awk '
  /^_ccsk_safety_snapshot_cli\(\)/ { capture = 1 }
  capture { print }
  capture && /^}/ { exit }
' "$_sn_wrapper")"
if [[ "$_sn_snapshot_impl" == *"/usr/bin/python3 -I -B -c '"* \
  && "$_sn_snapshot_impl" != *"<<"* ]]; then
  pass "safety-net: private snapshot avoids delimiter stdin transport"
else
  fail "safety-net: private snapshot reintroduced delimiter stdin transport"
fi

# ── wrapper pins managed Node/JS and keeps a non-recursive normal fallback ─

_sn_wrapper_tmp="$(mktemp -d)"
_sn_wrapper_tmp="$(builtin cd -P "$_sn_wrapper_tmp" && pwd -P)"

# The hook shell expands a quoted $HOME at execution time. Values containing
# whitespace or shell metacharacters therefore remain one literal pathname and
# are never parsed as command syntax after expansion.
_sn_hook_home="$_sn_wrapper_tmp/Home Space;\$(not-run)\"quoted"
_sn_hook_log="$_sn_wrapper_tmp/home-hook.log"
mkdir -p "$_sn_hook_home/.claude/hooks/safety-net"
cat > "$_sn_hook_home/.claude/hooks/safety-net/run-cc-safety-net.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" > "$SAFETY_HOOK_HOME_LOG"
EOF
chmod +x "$_sn_hook_home/.claude/hooks/safety-net/run-cc-safety-net.sh"
_sn_wrapper_rc=0
HOME="$_sn_hook_home" SAFETY_HOOK_HOME_LOG="$_sn_hook_log" \
  /bin/sh -c "$_sn_hook_command" >/dev/null 2>&1 || _sn_wrapper_rc=$?
if [[ "$_sn_wrapper_rc" -eq 0 \
  && "$(< "$_sn_hook_log")" == "--claude-code" ]]; then
  pass "safety-net: quoted runtime HOME preserves spaces and shell metacharacters"
else
  fail "safety-net: hook command reparsed or split the runtime HOME path"
fi

_sn_runtime="$_sn_wrapper_tmp/runtime"
_sn_component="$_sn_wrapper_tmp/component"
_sn_node="$_sn_runtime/node-v24.18.0-darwin-arm64/bin/node"
_sn_js="$_sn_component/dist/bin/cc-safety-net.js"
mkdir -p "${_sn_node%/*}" "${_sn_js%/*}" "$_sn_wrapper_tmp/path"
printf 'managed-js\n' > "$_sn_js"
_sn_expected_sha="$(_prereq_sha256_file "$_sn_js")"
cat > "$_sn_node" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" > "$SAFETY_WRAPPER_SNAPSHOT"
/bin/cat "$1" > "$SAFETY_WRAPPER_CONTENT"
shift
printf '%s\n' "$*" > "$SAFETY_WRAPPER_LOG"
printf '%s|%s\n' "${NODE_OPTIONS-unset}" "${NODE_PATH-unset}" \
  > "$SAFETY_WRAPPER_ENV"
/bin/cat > "$SAFETY_WRAPPER_STDIN"
EOF
chmod +x "$_sn_node"
export SAFETY_WRAPPER_LOG="$_sn_wrapper_tmp/managed.log"
export SAFETY_WRAPPER_STDIN="$_sn_wrapper_tmp/managed.stdin"
export SAFETY_WRAPPER_ENV="$_sn_wrapper_tmp/managed.env"
export SAFETY_WRAPPER_SNAPSHOT="$_sn_wrapper_tmp/managed.snapshot"
export SAFETY_WRAPPER_CONTENT="$_sn_wrapper_tmp/managed.content"
export SAFETY_TEST_EXPECTED_SHA="$_sn_expected_sha"
export NODE_OPTIONS="--require=$_sn_wrapper_tmp/hostile-preload.cjs"
export NODE_PATH="$_sn_wrapper_tmp/hostile-modules"
_sn_payload='{"tool_name":"Bash"}'
_sn_wrapper_rc=0
(
  # shellcheck source=/dev/null
  source "$_sn_wrapper"
  _ccsk_safety_expected_cli_sha256() {
    printf '%s' "$SAFETY_TEST_EXPECTED_SHA"
  }
  printf '%s' "$_sn_payload" | _ccsk_safety_run \
    true "$_sn_node" "$_sn_js" "$_sn_component" "$_sn_runtime" \
    "$_sn_wrapper" --claude-code
) || _sn_wrapper_rc=$?
if [[ "$_sn_wrapper_rc" -eq 0 ]] \
  && [[ "$(< "$SAFETY_WRAPPER_LOG")" == "--claude-code" ]] \
  && [[ "$(< "$SAFETY_WRAPPER_CONTENT")" == "managed-js" ]] \
  && [[ "$(< "$SAFETY_WRAPPER_SNAPSHOT")" != "$_sn_js" ]] \
  && [[ ! -e "$(< "$SAFETY_WRAPPER_SNAPSHOT")" ]] \
  && [[ "$(< "$SAFETY_WRAPPER_ENV")" == "unset|unset" ]] \
  && [[ "$(< "$SAFETY_WRAPPER_STDIN")" == "$_sn_payload" ]]; then
  pass "safety-net: managed wrapper executes a hash-bound private JS snapshot"
else
  fail "safety-net: managed wrapper did not preserve the pinned runtime contract"
fi

cat > "$_sn_wrapper_tmp/path/cc-safety-net" <<'EOF'
#!/bin/bash
: > "$SAFETY_FALLBACK_LOG"
exit 0
EOF
chmod +x "$_sn_wrapper_tmp/path/cc-safety-net"
export SAFETY_FALLBACK_LOG="$_sn_wrapper_tmp/fallback.log"
rm -f "$_sn_node"
_sn_wrapper_rc=0
(
  # shellcheck source=/dev/null
  source "$_sn_wrapper"
  _ccsk_safety_expected_cli_sha256() {
    printf '%s' "$SAFETY_TEST_EXPECTED_SHA"
  }
  PATH="$_sn_wrapper_tmp/path:/usr/bin:/bin" \
    _ccsk_safety_run true "$_sn_node" "$_sn_js" "$_sn_component" \
      "$_sn_runtime" "$_sn_wrapper" --claude-code
) >/dev/null 2>&1 || _sn_wrapper_rc=$?
if [[ "$_sn_wrapper_rc" -ne 0 && ! -e "$SAFETY_FALLBACK_LOG" ]]; then
  pass "safety-net: partial managed runtime fails closed without PATH fallback"
else
  fail "safety-net: partial managed runtime fell through to an untrusted PATH command"
fi

# A symlinked component root is itself a managed marker, but must never be
# followed to an arbitrary JS payload.
mkdir -p "$_sn_runtime/node-v24.18.0-darwin-arm64/bin" \
  "$_sn_wrapper_tmp/alternate-component/dist/bin"
cp "$PROJECT_DIR/features/safety-net/scripts/run-cc-safety-net.sh" "$_sn_node"
chmod +x "$_sn_node"
cp "$_sn_js" "$_sn_wrapper_tmp/alternate-component/dist/bin/cc-safety-net.js"
rm -rf "$_sn_component"
ln -s "$_sn_wrapper_tmp/alternate-component" "$_sn_component"
rm -f "$SAFETY_FALLBACK_LOG"
_sn_wrapper_rc=0
(
  # shellcheck source=/dev/null
  source "$_sn_wrapper"
  _ccsk_safety_expected_cli_sha256() {
    printf '%s' "$SAFETY_TEST_EXPECTED_SHA"
  }
  PATH="$_sn_wrapper_tmp/path:/usr/bin:/bin" \
    _ccsk_safety_run true "$_sn_node" "$_sn_js" "$_sn_component" \
      "$_sn_runtime" "$_sn_wrapper" --claude-code
) >/dev/null 2>&1 || _sn_wrapper_rc=$?
if [[ "$_sn_wrapper_rc" -ne 0 && ! -e "$SAFETY_FALLBACK_LOG" ]]; then
  pass "safety-net: symlinked managed component root fails closed"
else
  fail "safety-net: symlinked managed component root was followed"
fi

# A per-user component marker plus a dangling system runtime must also fail
# closed. A dangling global runtime alone is deliberately not user authority.
rm -f "$_sn_component"
mkdir -p "$_sn_component/dist/bin"
printf 'managed-js\n' > "$_sn_js"
rm -rf "$_sn_runtime"
ln -s "$_sn_wrapper_tmp/missing-runtime" "$_sn_runtime"
_sn_wrapper_rc=0
(
  # shellcheck source=/dev/null
  source "$_sn_wrapper"
  _ccsk_safety_expected_cli_sha256() {
    printf '%s' "$SAFETY_TEST_EXPECTED_SHA"
  }
  PATH="$_sn_wrapper_tmp/path:/usr/bin:/bin" \
    _ccsk_safety_run true "$_sn_node" "$_sn_js" "$_sn_component" \
      "$_sn_runtime" "$_sn_wrapper" --claude-code
) >/dev/null 2>&1 || _sn_wrapper_rc=$?
if [[ "$_sn_wrapper_rc" -ne 0 && ! -e "$SAFETY_FALLBACK_LOG" ]]; then
  pass "safety-net: dangling managed runtime fails closed"
else
  fail "safety-net: dangling managed runtime reached PATH or JS"
fi

rm -rf "$_sn_runtime" "$_sn_component"
_sn_wrapper_rc=0
(
  # shellcheck source=/dev/null
  source "$_sn_wrapper"
  PATH="$_sn_wrapper_tmp/path:/usr/bin:/bin" \
    _ccsk_safety_run false "" "$_sn_js" "$_sn_component" \
      "$_sn_runtime" "$_sn_wrapper" --claude-code
) >/dev/null 2>&1 || _sn_wrapper_rc=$?
if [[ "$_sn_wrapper_rc" -eq 0 && -e "$SAFETY_FALLBACK_LOG" ]]; then
  pass "safety-net: non-MDM wrapper retains the normal PATH fallback"
else
  fail "safety-net: non-MDM PATH fallback was broken"
fi

rm -f "$SAFETY_FALLBACK_LOG" "$_sn_wrapper_tmp/path/cc-safety-net"
ln -s "$_sn_wrapper" "$_sn_wrapper_tmp/path/cc-safety-net"
_sn_wrapper_rc=0
(
  # shellcheck source=/dev/null
  source "$_sn_wrapper"
  PATH="$_sn_wrapper_tmp/path:/usr/bin:/bin" \
    _ccsk_safety_run false "" "$_sn_js" "$_sn_component" \
      "$_sn_runtime" "$_sn_wrapper" --claude-code
) >/dev/null 2>&1 || _sn_wrapper_rc=$?
if [[ "$_sn_wrapper_rc" -ne 0 ]]; then
  pass "safety-net: PATH symlink back to the wrapper cannot recurse"
else
  fail "safety-net: wrapper recursion guard is missing"
fi

# The global runtime is shared by every account and cannot mark an unrelated
# user's normal install as managed. Arch selection is consequently skipped on
# unsupported non-MDM platforms and the historical PATH fallback still runs.
rm -f "$_sn_wrapper_tmp/path/cc-safety-net"
cat > "$_sn_wrapper_tmp/path/cc-safety-net" <<'EOF'
#!/bin/bash
: > "$SAFETY_FALLBACK_LOG"
EOF
chmod +x "$_sn_wrapper_tmp/path/cc-safety-net"
mkdir -p "$_sn_wrapper_tmp/global-runtime"
rm -f "$SAFETY_FALLBACK_LOG" "$_sn_wrapper_tmp/arch-called"
export SAFETY_TEST_RUNTIME="$_sn_wrapper_tmp/global-runtime"
export SAFETY_TEST_COMPONENT="$_sn_wrapper_tmp/unrelated-component"
export SAFETY_TEST_ARCH_CALLED="$_sn_wrapper_tmp/arch-called"
_sn_wrapper_rc=0
(
  # shellcheck source=/dev/null
  source "$_sn_wrapper"
  _ccsk_safety_runtime_base() { printf '%s' "$SAFETY_TEST_RUNTIME"; }
  _ccsk_safety_component_root() { printf '%s' "$SAFETY_TEST_COMPONENT"; }
  _ccsk_safety_receipt_path() { return 1; }
  _ccsk_safety_arch() { : > "$SAFETY_TEST_ARCH_CALLED"; return 1; }
  PATH="$_sn_wrapper_tmp/path:/usr/bin:/bin" _ccsk_safety_main --claude-code
) >/dev/null 2>&1 || _sn_wrapper_rc=$?
if [[ "$_sn_wrapper_rc" -eq 0 && -e "$SAFETY_FALLBACK_LOG" \
  && ! -e "$SAFETY_TEST_ARCH_CALLED" ]]; then
  pass "safety-net: global runtime does not mark another user or require an arch"
else
  fail "safety-net: global runtime broke the non-MDM PATH fallback"
fi

# Conversely, the root-issued receipt for this account remains authoritative
# even if the user removes both the manifest and the private component tree.
SAFETY_TEST_RECEIPT="$_sn_wrapper_tmp/current-user-receipt.json"
export SAFETY_TEST_RECEIPT
: > "$SAFETY_TEST_RECEIPT"
rm -f "$SAFETY_FALLBACK_LOG"
_sn_wrapper_rc=0
(
  # shellcheck source=/dev/null
  source "$_sn_wrapper"
  _ccsk_safety_runtime_base() { printf '%s' "$SAFETY_TEST_RUNTIME"; }
  _ccsk_safety_component_root() { printf '%s' "$SAFETY_TEST_COMPONENT"; }
  _ccsk_safety_receipt_path() { printf '%s' "$SAFETY_TEST_RECEIPT"; }
  _ccsk_safety_arch() { printf '%s' arm64; }
  PATH="$_sn_wrapper_tmp/path:/usr/bin:/bin" _ccsk_safety_main --claude-code
) >/dev/null 2>&1 || _sn_wrapper_rc=$?
if [[ "$_sn_wrapper_rc" -ne 0 && ! -e "$SAFETY_FALLBACK_LOG" ]]; then
  pass "safety-net: per-user root receipt keeps missing state fail-closed"
else
  fail "safety-net: deleted user state bypassed the authoritative receipt"
fi

# Hardware capability wins under Rosetta, while native ARM Linux aliases are
# accepted if managed arch selection is explicitly needed.
_sn_arch_result="$({
  # shellcheck source=/dev/null
  source "$_sn_wrapper"
  _ccsk_safety_hw_arm64() { printf '1'; }
  _ccsk_safety_machine_arch() { printf 'x86_64'; }
  printf '%s\n' "$(_ccsk_safety_arch)"
  _ccsk_safety_hw_arm64() { return 1; }
  _ccsk_safety_machine_arch() { printf 'aarch64'; }
  printf '%s\n' "$(_ccsk_safety_arch)"
})"
if [[ "$_sn_arch_result" == $'arm64\narm64' ]]; then
  pass "safety-net: Rosetta and aarch64 resolve to the pinned arm64 runtime"
else
  fail "safety-net: managed architecture mapping is incomplete"
fi

# Bind the JS bytes before Node starts. Replacing the original pathname after
# the snapshot is ready must not change what the trusted Node process opens.
rm -rf "$_sn_runtime" "$_sn_component"
mkdir -p "${_sn_node%/*}" "${_sn_js%/*}"
printf 'managed-js\n' > "$_sn_js"
cat > "$_sn_node" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" > "$SAFETY_TOCTOU_SNAPSHOT"
: > "$SAFETY_TOCTOU_READY"
while [[ ! -e "$SAFETY_TOCTOU_GO" ]]; do /bin/sleep 0.01; done
/bin/cat "$1" > "$SAFETY_TOCTOU_EXECUTED"
EOF
chmod +x "$_sn_node"
export SAFETY_TOCTOU_READY="$_sn_wrapper_tmp/toctou.ready"
export SAFETY_TOCTOU_GO="$_sn_wrapper_tmp/toctou.go"
export SAFETY_TOCTOU_EXECUTED="$_sn_wrapper_tmp/toctou.executed"
export SAFETY_TOCTOU_SNAPSHOT="$_sn_wrapper_tmp/toctou.snapshot"
(
  # shellcheck source=/dev/null
  source "$_sn_wrapper"
  _ccsk_safety_expected_cli_sha256() {
    printf '%s' "$SAFETY_TEST_EXPECTED_SHA"
  }
  _ccsk_safety_run true "$_sn_node" "$_sn_js" "$_sn_component" \
    "$_sn_runtime" "$_sn_wrapper" --claude-code
) >/dev/null 2>&1 &
_sn_toctou_pid=$!
_sn_wait=0
while [[ ! -e "$SAFETY_TOCTOU_READY" && "$_sn_wait" -lt 500 ]]; do
  /bin/sleep 0.01
  _sn_wait=$((_sn_wait + 1))
done
printf 'malicious-js\n' > "$_sn_wrapper_tmp/replacement.js"
/bin/mv -f "$_sn_wrapper_tmp/replacement.js" "$_sn_js"
: > "$SAFETY_TOCTOU_GO"
_sn_wrapper_rc=0
wait "$_sn_toctou_pid" || _sn_wrapper_rc=$?
if [[ "$_sn_wrapper_rc" -eq 0 \
  && "$(< "$SAFETY_TOCTOU_EXECUTED")" == "managed-js" \
  && "$(< "$SAFETY_TOCTOU_SNAPSHOT")" != "$_sn_js" \
  && ! -e "$(< "$SAFETY_TOCTOU_SNAPSHOT")" ]]; then
  pass "safety-net: CLI pathname replacement cannot change bound JS bytes"
else
  fail "safety-net: CLI JS remains vulnerable to check/use replacement"
fi

unset SAFETY_WRAPPER_LOG SAFETY_WRAPPER_STDIN SAFETY_WRAPPER_ENV \
  SAFETY_WRAPPER_SNAPSHOT SAFETY_WRAPPER_CONTENT SAFETY_FALLBACK_LOG \
  SAFETY_TEST_EXPECTED_SHA SAFETY_TEST_RUNTIME SAFETY_TEST_COMPONENT \
  SAFETY_TEST_RECEIPT SAFETY_TEST_ARCH_CALLED SAFETY_TOCTOU_READY \
  SAFETY_TOCTOU_GO SAFETY_TOCTOU_EXECUTED SAFETY_TOCTOU_SNAPSHOT \
  NODE_OPTIONS NODE_PATH
rm -rf "$_sn_wrapper_tmp"

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
