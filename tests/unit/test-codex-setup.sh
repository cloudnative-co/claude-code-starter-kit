#!/bin/bash
# tests/unit/test-codex-setup.sh - Unit tests for lib/codex-setup.sh state handling
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded).
# shellcheck disable=SC2034

# Minimal stubs required by lib/codex-setup.sh
info() { printf '%s\n' "$*"; }
ok() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
section() { printf '%s\n' "$*"; }
is_true() { [[ "${1:-false}" == "true" ]]; }
is_msys() { return 1; }
_get_shell_rc_file() { printf '%s\n' "$HOME/.bashrc"; }

# shellcheck disable=SC2034  # globals are consumed by sourced codex-setup.sh
STR_CODEX_SETUP_INCOMPLETE="Codex setup incomplete"
STR_CODEX_PLUGIN_ALREADY="Codex plugin already configured"
STR_CODEX_MCP_DRIFT_CLEANUP="Cleaning Codex MCP drift"
STR_CODEX_MCP_DRIFT_DONE="Removed duplicate Codex MCP"
STR_CODEX_MCP_DRIFT_KEEPING="Keeping MCP because cleanup failed"
STR_CODEX_MCP_KEEP_UNTIL_READY="Keeping MCP until plugin is fully ready"
STR_CODEX_MIGRATE_PROMPT="Migrate Codex MCP?"
STR_CODEX_MIGRATE_YES="Yes"
STR_CODEX_MIGRATE_NO="No"
STR_CODEX_MIGRATE_DONE="Migration complete"
STR_CODEX_MIGRATE_KEEP_MCP="Plugin setup incomplete. Keeping MCP."
STR_CODEX_MIGRATE_SKIP_NONINTERACTIVE="Migration needs interactive mode"
STR_CODEX_AUTH_NONINTERACTIVE_REQUIRED="Auth still needs interactive setup"

MOCK_HAS_PLUGIN=false
MOCK_HAS_MCP=false
MOCK_CLI_READY=false
MOCK_AUTH_READY=false
MOCK_SETUP_SUCCESS=false
MOCK_INSTALL_CLI_SUCCESS=true
MOCK_INSTALL_PLUGIN_SUCCESS=true
MOCK_REMOVE_MCP_SUCCESS=true
MOCK_SETUP_CALLS=0
MOCK_INSTALL_CLI_CALLS=0
MOCK_INSTALL_PLUGIN_CALLS=0
MOCK_REMOVE_MCP_CALLS=0

# shellcheck source=lib/codex-setup.sh
source "$PROJECT_DIR/lib/codex-setup.sh"

reset_codex_mocks() {
  # shellcheck disable=SC2034  # globals are consumed by sourced codex-setup.sh
  MOCK_HAS_PLUGIN=false
  MOCK_HAS_MCP=false
  MOCK_CLI_READY=false
  MOCK_AUTH_READY=false
  MOCK_SETUP_SUCCESS=false
  MOCK_INSTALL_CLI_SUCCESS=true
  MOCK_INSTALL_PLUGIN_SUCCESS=true
  MOCK_REMOVE_MCP_SUCCESS=true
  MOCK_SETUP_CALLS=0
  MOCK_INSTALL_CLI_CALLS=0
  MOCK_INSTALL_PLUGIN_CALLS=0
  MOCK_REMOVE_MCP_CALLS=0
  ENABLE_CODEX_PLUGIN=true
  WIZARD_NONINTERACTIVE=false
}

setup_fake_claude() {
  MOCK_CLAUDE_DIR="$(mktemp -d)"
  MOCK_CLAUDE_LOG="$MOCK_CLAUDE_DIR/claude.log"
  export MOCK_CLAUDE_LOG
  _SETUP_TMP_FILES+=("$MOCK_CLAUDE_DIR")
  cat >"$MOCK_CLAUDE_DIR/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "${MOCK_CLAUDE_LOG}"
if [[ "${1:-}" == "mcp" && "${2:-}" == "list" ]]; then
  printf '%s' "${MOCK_CLAUDE_LIST_OUTPUT:-}"
  exit 0
fi
if [[ "${1:-}" == "mcp" && "${2:-}" == "remove" ]]; then
  printf '%s' "${MOCK_CLAUDE_REMOVE_OUTPUT:-}"
  exit "${MOCK_CLAUDE_REMOVE_RC:-0}"
fi
exit 1
EOF
  chmod +x "$MOCK_CLAUDE_DIR/claude"
  MOCK_ORIG_PATH="$PATH"
  export PATH="$MOCK_CLAUDE_DIR:$PATH"
}

teardown_fake_claude() {
  export PATH="$MOCK_ORIG_PATH"
}

# Legacy MCP detection should scan all scopes, not only -s user
setup_fake_claude
export MOCK_CLAUDE_LIST_OUTPUT=$'codex\n'
if _has_legacy_mcp \
  && assert_equals "mcp list" "$(cat "$MOCK_CLAUDE_LOG")"; then
  pass "codex-setup: _has_legacy_mcp checks all scopes via claude mcp list"
else
  fail "codex-setup: _has_legacy_mcp should not hardcode -s user"
fi
teardown_fake_claude

# Legacy MCP removal should rely on scope-agnostic CLI removal
setup_fake_claude
export MOCK_CLAUDE_LIST_OUTPUT=$'codex\n'
export MOCK_CLAUDE_REMOVE_OUTPUT="removed"
if _remove_legacy_mcp \
  && assert_equals "mcp remove codex" "$(cat "$MOCK_CLAUDE_LOG")"; then
  pass "codex-setup: _remove_legacy_mcp removes codex without scope pinning"
else
  fail "codex-setup: _remove_legacy_mcp should not hardcode -s user"
fi
teardown_fake_claude

_has_codex_plugin() { [[ "$MOCK_HAS_PLUGIN" == "true" ]]; }
_has_legacy_mcp() { [[ "$MOCK_HAS_MCP" == "true" ]]; }
_codex_cli_ready() { [[ "$MOCK_CLI_READY" == "true" ]]; }
_codex_auth_ready() { [[ "$MOCK_AUTH_READY" == "true" ]]; }
_codex_fully_ready() { [[ "$MOCK_CLI_READY" == "true" && "$MOCK_AUTH_READY" == "true" && "$MOCK_HAS_PLUGIN" == "true" ]]; }
_setup_codex_plugin() { MOCK_SETUP_CALLS=$((MOCK_SETUP_CALLS + 1)); [[ "$MOCK_SETUP_SUCCESS" == "true" ]]; }
_install_codex_cli() { MOCK_INSTALL_CLI_CALLS=$((MOCK_INSTALL_CLI_CALLS + 1)); [[ "$MOCK_INSTALL_CLI_SUCCESS" == "true" ]]; }
_install_codex_plugin() { MOCK_INSTALL_PLUGIN_CALLS=$((MOCK_INSTALL_PLUGIN_CALLS + 1)); [[ "$MOCK_INSTALL_PLUGIN_SUCCESS" == "true" ]]; }
_remove_legacy_mcp() { MOCK_REMOVE_MCP_CALLS=$((MOCK_REMOVE_MCP_CALLS + 1)); [[ "$MOCK_REMOVE_MCP_SUCCESS" == "true" ]]; }

# _run_with_timeout fallback must preserve stdout for command substitution
command() {
  if [[ "$1" == "-v" && "$2" == "timeout" ]]; then
    return 1
  fi
  builtin command "$@"
}
_timeout_result="$(_run_with_timeout 5 bash -lc 'printf "Logged in using ChatGPT"')"
_timeout_rc=$?
unset -f command
if assert_equals "0" "$_timeout_rc" \
  && assert_equals "Logged in using ChatGPT" "$_timeout_result"; then
  pass "codex-setup: _run_with_timeout fallback preserves stdout for command substitution"
else
  fail "codex-setup: _run_with_timeout fallback should preserve stdout"
fi
unset -f codex 2>/dev/null || true
codex() {
  if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
    printf 'Logged in using ChatGPT\n' >&2
    return 0
  fi
  return 1
}
if _status="$(_codex_login_status)"; then
  if assert_equals "Logged in using ChatGPT" "$_status"; then
    pass "codex-setup: _codex_login_status accepts stderr-based status output"
  else
    fail "codex-setup: _codex_login_status should preserve stderr-based status text"
  fi
else
  fail "codex-setup: _codex_login_status should succeed when status is printed to stderr"
fi
unset -f codex
unset -f command

# State A: plugin present / MCP absent / auth incomplete should not be treated as done
reset_codex_mocks
MOCK_HAS_PLUGIN=true
run_func run_codex_setup
if assert_equals "0" "$_RF_RC" \
  && assert_equals "1" "$MOCK_SETUP_CALLS" \
  && assert_matches "Codex setup incomplete" "$_RF_STDERR"; then
  pass "codex-setup: State A keeps setup path when plugin exists but auth is incomplete"
else
  fail "codex-setup: State A should continue setup when auth is incomplete"
fi

# State B: cleanup failure should be visible and keep MCP
reset_codex_mocks
MOCK_HAS_PLUGIN=true
MOCK_HAS_MCP=true
MOCK_CLI_READY=true
MOCK_AUTH_READY=true
MOCK_REMOVE_MCP_SUCCESS=false
run_func run_codex_setup
if assert_equals "0" "$_RF_RC" \
  && assert_equals "1" "$MOCK_REMOVE_MCP_CALLS" \
  && assert_matches "Keeping MCP because cleanup failed" "$_RF_STDERR"; then
  pass "codex-setup: State B surfaces cleanup failure instead of silently swallowing it"
else
  fail "codex-setup: State B should warn when MCP cleanup fails"
fi

# State C: migration must keep MCP when setup is incomplete
reset_codex_mocks
MOCK_HAS_MCP=true
run_func run_codex_setup <<< $'1\n'
if assert_equals "0" "$_RF_RC" \
  && assert_equals "1" "$MOCK_SETUP_CALLS" \
  && assert_equals "0" "$MOCK_REMOVE_MCP_CALLS" \
  && assert_matches "Plugin setup incomplete. Keeping MCP." "$_RF_STDERR"; then
  pass "codex-setup: State C keeps MCP when plugin setup is incomplete"
else
  fail "codex-setup: State C should keep MCP until setup is fully ready"
fi

# State D: non-interactive fresh install should attempt both installs and warn on failure
reset_codex_mocks
WIZARD_NONINTERACTIVE=true
MOCK_INSTALL_CLI_SUCCESS=false
MOCK_INSTALL_PLUGIN_SUCCESS=false
run_func run_codex_setup
if assert_equals "0" "$_RF_RC" \
  && assert_equals "1" "$MOCK_INSTALL_CLI_CALLS" \
  && assert_equals "1" "$MOCK_INSTALL_PLUGIN_CALLS" \
  && assert_matches "Codex setup incomplete" "$_RF_STDERR"; then
  pass "codex-setup: State D reports incomplete non-interactive setup instead of silently ignoring failures"
else
  fail "codex-setup: State D should report incomplete setup on install failures"
fi
