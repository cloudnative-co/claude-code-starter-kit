#!/bin/bash
# tests/helpers.sh - Shared test helpers for scenario tests
# Provides isolation, assertions, and fixture management.
set -euo pipefail

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
_TEST_COUNT=0
_TEST_PASS=0
_TEST_FAIL=0
_TEST_SKIP=0
_TEST_TMPDIR=""
_ORIG_HOME="${HOME:-}"
_ORIG_PATH="${PATH:-}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# setup_test_env - Create an isolated test environment
#
# Creates a temporary HOME directory so setup.sh operates in a sandbox.
# Sets CLAUDE_DIR, HOME, and suppresses interactive prompts.
# ---------------------------------------------------------------------------
setup_test_env() {
  _TEST_TMPDIR="$(mktemp -d)"
  export HOME="$_TEST_TMPDIR"
  export CLAUDE_DIR="$_TEST_TMPDIR/.claude"
  export WIZARD_NONINTERACTIVE=true

  # Place a dummy 'claude' binary so setup.sh skips CLI installation
  mkdir -p "$_TEST_TMPDIR/.local/bin"
  printf '#!/bin/bash\nexit 0\n' > "$_TEST_TMPDIR/.local/bin/claude"
  chmod +x "$_TEST_TMPDIR/.local/bin/claude"
  export PATH="$_TEST_TMPDIR/.local/bin:$_ORIG_PATH"
}

# ---------------------------------------------------------------------------
# teardown_test_env - Clean up the isolated test environment
# ---------------------------------------------------------------------------
teardown_test_env() {
  # Restore original HOME and PATH to prevent cross-test contamination
  export HOME="$_ORIG_HOME"
  export PATH="$_ORIG_PATH"

  if [[ -n "${_TEST_TMPDIR:-}" ]] && [[ -d "$_TEST_TMPDIR" ]]; then
    rm -rf "$_TEST_TMPDIR"
  fi
  _TEST_TMPDIR=""
}

# Ensure cleanup on unexpected exit (set -e abort, signal, etc.)
trap 'teardown_test_env' EXIT

# ---------------------------------------------------------------------------
# run_setup - Run setup.sh with given args in the test environment
#
# Usage: run_setup [args...]
# Does NOT hardcode --profile; caller must pass it if needed.
# Returns the exit code of setup.sh
# ---------------------------------------------------------------------------
run_setup() {
  bash "$PROJECT_DIR/setup.sh" --non-interactive --language=en "$@" 2>&1
}

# ---------------------------------------------------------------------------
# run_setup_update - Run setup.sh in update mode
# ---------------------------------------------------------------------------
run_setup_update() {
  bash "$PROJECT_DIR/setup.sh" --update --non-interactive "$@" 2>&1
}

# ---------------------------------------------------------------------------
# run_uninstall - Run uninstall.sh in the test environment
# ---------------------------------------------------------------------------
run_uninstall() {
  # uninstall.sh reads from stdin for confirmation; provide auto-answers
  printf 'y\nn\n' | bash "$PROJECT_DIR/uninstall.sh" 2>&1 || true
}

# ---------------------------------------------------------------------------
# install_fixture - Copy a fixture set into the test CLAUDE_DIR
#
# Usage: install_fixture <fixture_name>
#   fixture_name: v019, v020, no-manifest
# ---------------------------------------------------------------------------
install_fixture() {
  local fixture="$1"
  local src="$PROJECT_DIR/tests/fixtures/$fixture"

  if [[ ! -d "$src" ]]; then
    echo "FIXTURE NOT FOUND: $src" >&2
    return 1
  fi

  mkdir -p "$CLAUDE_DIR"
  cp -a "$src"/. "$CLAUDE_DIR"/
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

assert_file_exists() {
  local file="$1"
  local msg="${2:-File should exist: $file}"
  if [[ -f "$file" ]]; then
    return 0
  else
    echo "  ASSERTION FAILED: $msg (file not found: $file)" >&2
    return 1
  fi
}

assert_file_not_exists() {
  local file="$1"
  local msg="${2:-File should not exist: $file}"
  if [[ ! -f "$file" ]]; then
    return 0
  else
    echo "  ASSERTION FAILED: $msg (file exists: $file)" >&2
    return 1
  fi
}

assert_dir_exists() {
  local dir="$1"
  local msg="${2:-Directory should exist: $dir}"
  if [[ -d "$dir" ]]; then
    return 0
  else
    echo "  ASSERTION FAILED: $msg (dir not found: $dir)" >&2
    return 1
  fi
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local msg="${3:-File should contain pattern: $pattern}"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    return 0
  else
    echo "  ASSERTION FAILED: $msg (pattern not found in $file)" >&2
    return 1
  fi
}

assert_file_not_contains() {
  local file="$1"
  local pattern="$2"
  local msg="${3:-File should not contain pattern: $pattern}"
  if ! grep -q "$pattern" "$file" 2>/dev/null; then
    return 0
  else
    echo "  ASSERTION FAILED: $msg (pattern found in $file)" >&2
    return 1
  fi
}

assert_json_field() {
  local file="$1"
  local field="$2"
  local expected="$3"
  local msg="${4:-JSON field $field should be $expected}"
  local actual
  actual="$(jq -r "$field" "$file" 2>/dev/null || echo "__JQ_ERROR__")"
  if [[ "$actual" == "$expected" ]]; then
    return 0
  else
    echo "  ASSERTION FAILED: $msg (got: $actual)" >&2
    return 1
  fi
}

assert_json_has_key() {
  local file="$1"
  local key="$2"
  local msg="${3:-JSON should have key: $key}"
  if jq -e "$key" "$file" >/dev/null 2>&1; then
    return 0
  else
    echo "  ASSERTION FAILED: $msg" >&2
    return 1
  fi
}

assert_exit_code() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-Exit code should be $expected}"
  if [[ "$actual" -eq "$expected" ]]; then
    return 0
  else
    echo "  ASSERTION FAILED: $msg (got: $actual)" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test runner helpers
# ---------------------------------------------------------------------------

# Record a test result
pass() {
  _TEST_COUNT=$((_TEST_COUNT + 1))
  _TEST_PASS=$((_TEST_PASS + 1))
  printf "  \033[0;32mPASS\033[0m  %s\n" "$1"
}

fail() {
  _TEST_COUNT=$((_TEST_COUNT + 1))
  _TEST_FAIL=$((_TEST_FAIL + 1))
  printf "  \033[0;31mFAIL\033[0m  %s\n" "$1"
}

skip() {
  _TEST_COUNT=$((_TEST_COUNT + 1))
  _TEST_SKIP=$((_TEST_SKIP + 1))
  printf "  \033[0;33mSKIP\033[0m  %s — %s\n" "$1" "${2:-not yet implemented}"
}

# Print summary and exit with appropriate code
print_summary() {
  printf "\n── Results ──\n"
  printf "  Total: %d  Pass: %d  Fail: %d  Skip: %d\n\n" \
    "$_TEST_COUNT" "$_TEST_PASS" "$_TEST_FAIL" "$_TEST_SKIP"
  if [[ "$_TEST_FAIL" -gt 0 ]]; then
    return 1
  fi
  return 0
}

# Check if running on macOS
is_macos() {
  [[ "$(uname -s)" == "Darwin" ]]
}

# Portable checksum of a directory (macOS uses shasum, Linux uses sha256sum)
snapshot_dir_checksum() {
  local dir="$1"
  local hash_cmd="sha256sum"
  if ! command -v sha256sum &>/dev/null; then
    hash_cmd="shasum -a 256"
  fi
  find "$dir" -type f -print0 2>/dev/null | sort -z | xargs -0 $hash_cmd 2>/dev/null | $hash_cmd | cut -d' ' -f1
}
