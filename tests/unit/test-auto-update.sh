#!/bin/bash
# tests/unit/test-auto-update.sh - Unit tests for auto-update hook behavior
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded).

AUTO_UPDATE_SCRIPT="$PROJECT_DIR/features/auto-update/scripts/auto-update.sh"
REAL_BASH_BIN="${REAL_BASH_BIN:-$(command -v bash)}"

# Source dependencies explicitly so this test does not depend on prior files.
# shellcheck source=lib/colors.sh
source "$PROJECT_DIR/lib/colors.sh"
# shellcheck source=lib/features.sh
source "$PROJECT_DIR/lib/features.sh"
# shellcheck source=lib/template.sh
source "$PROJECT_DIR/lib/template.sh"
# shellcheck source=lib/json-builder.sh
source "$PROJECT_DIR/lib/json-builder.sh"
# shellcheck source=lib/snapshot.sh
source "$PROJECT_DIR/lib/snapshot.sh"
# shellcheck source=lib/merge.sh
source "$PROJECT_DIR/lib/merge.sh"
# shellcheck source=lib/dryrun.sh
source "$PROJECT_DIR/lib/dryrun.sh"
# shellcheck source=lib/deploy.sh
source "$PROJECT_DIR/lib/deploy.sh"

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
LANGUAGE="${LANGUAGE:-en}"
COMMIT_ATTRIBUTION="${COMMIT_ATTRIBUTION:-true}"
ENABLE_NEW_INIT="${ENABLE_NEW_INIT:-true}"
# shellcheck disable=SC2034  # build_settings_file reads feature flags via indirect expansion
ENABLE_AUTO_UPDATE="true"

run_auto_update_with_mocks() {
  local tmpdir="$1"
  local mockbin="$tmpdir/mockbin"
  mkdir -p "$mockbin"

  cat >"$mockbin/git" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_GIT_LOG}"
case "${1:-}" in
  -C)
    shift 2
    ;;
esac
case "${1:-}" in
  fetch)
    exit "${MOCK_GIT_FETCH_RC:-0}"
    ;;
  describe)
    if [[ "${*: -1}" == "HEAD" ]]; then
      printf '%s\n' "${MOCK_LOCAL_VER:-v0.0.0}"
    else
      printf '%s\n' "${MOCK_REMOTE_VER:-v0.0.0}"
    fi
    exit 0
    ;;
  status)
    printf '%s' "${MOCK_GIT_STATUS_OUTPUT:-}"
    exit 0
    ;;
  pull)
    exit "${MOCK_GIT_PULL_RC:-0}"
    ;;
esac
exit 0
EOF
  chmod +x "$mockbin/git"

  cat >"$mockbin/bash" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_BASH_LOG}"
exit "${MOCK_SETUP_RC:-0}"
EOF
  chmod +x "$mockbin/bash"

  cat >"$mockbin/claude" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' "${MOCK_CLAUDE_VERSION_SCRIPT:-2.1.89 (Claude Code)}"
  exit 0
fi
exit 0
EOF
  chmod +x "$mockbin/claude"

  env \
    HOME="$tmpdir/home" \
    PATH="$mockbin:${PATH}" \
    MOCK_GIT_LOG="$tmpdir/git.log" \
    MOCK_BASH_LOG="$tmpdir/bash.log" \
    MOCK_LOCAL_VER="${MOCK_LOCAL_VER:-v0.0.0}" \
    MOCK_REMOTE_VER="${MOCK_REMOTE_VER:-v0.0.0}" \
    MOCK_GIT_STATUS_OUTPUT="${MOCK_GIT_STATUS_OUTPUT:-}" \
    MOCK_GIT_FETCH_RC="${MOCK_GIT_FETCH_RC:-0}" \
    MOCK_GIT_PULL_RC="${MOCK_GIT_PULL_RC:-0}" \
    MOCK_SETUP_RC="${MOCK_SETUP_RC:-0}" \
    MOCK_CLAUDE_VERSION_SCRIPT="${MOCK_CLAUDE_VERSION_SCRIPT:-2.1.89 (Claude Code)}" \
    "$REAL_BASH_BIN" "$AUTO_UPDATE_SCRIPT"
}

_au_tmp="$(mktemp -d)"
_SETUP_TMP_FILES+=("$_au_tmp")
mkdir -p "$_au_tmp/home/.claude-starter-kit/.git"
mkdir -p "$_au_tmp/home/.claude"

# Running lock should skip without touching git.
mkdir -p "$_au_tmp/home/.claude/.starter-kit-update.lock"
printf '%s\n' "$$" > "$_au_tmp/home/.claude/.starter-kit-update.lock/pid"
printf '%s\n' "$(date +%s)" > "$_au_tmp/home/.claude/.starter-kit-update.lock/timestamp"
: > "$_au_tmp/git.log"
: > "$_au_tmp/bash.log"
MOCK_LOCAL_VER="v0.1.0"
MOCK_REMOTE_VER="v0.2.0"
if run_auto_update_with_mocks "$_au_tmp" >/dev/null 2>&1 \
  && assert_empty "$(cat "$_au_tmp/git.log")"; then
  pass "auto-update: running lock skips duplicate execution"
else
  fail "auto-update: running lock should skip duplicate execution"
fi
rm -rf "$_au_tmp/home/.claude/.starter-kit-update.lock"

# Stale lock should be recovered and removed after a no-op run.
mkdir -p "$_au_tmp/home/.claude/.starter-kit-update.lock"
printf '%s\n' "999999" > "$_au_tmp/home/.claude/.starter-kit-update.lock/pid"
printf '%s\n' "1" > "$_au_tmp/home/.claude/.starter-kit-update.lock/timestamp"
: > "$_au_tmp/git.log"
MOCK_LOCAL_VER="v0.1.0"
MOCK_REMOTE_VER="v0.1.0"
if run_auto_update_with_mocks "$_au_tmp" >/dev/null 2>&1 \
  && assert_matches "fetch --tags --quiet" "$(cat "$_au_tmp/git.log")" \
  && assert_file_not_exists "$_au_tmp/home/.claude/.starter-kit-update.lock/pid"; then
  pass "auto-update: stale lock is recovered and cleaned up"
else
  fail "auto-update: stale lock should be recoverable"
fi

# Version mismatch should fetch, pull, and invoke setup update.
: > "$_au_tmp/git.log"
: > "$_au_tmp/bash.log"
MOCK_LOCAL_VER="v0.1.0"
MOCK_REMOTE_VER="v0.2.0"
MOCK_GIT_STATUS_OUTPUT=""
MOCK_SETUP_RC="0"
if run_auto_update_with_mocks "$_au_tmp" >/dev/null 2>&1 \
  && assert_matches "pull --ff-only --quiet" "$(cat "$_au_tmp/git.log")" \
  && assert_matches "setup\\.sh --update --non-interactive" "$(cat "$_au_tmp/bash.log")"; then
  pass "auto-update: version mismatch pulls and runs setup update"
else
  fail "auto-update: version mismatch should run setup update"
fi

# Dirty repo should skip before setup update.
: > "$_au_tmp/git.log"
: > "$_au_tmp/bash.log"
MOCK_LOCAL_VER="v0.1.0"
MOCK_REMOTE_VER="v0.2.0"
MOCK_GIT_STATUS_OUTPUT=" M README.md"
if run_auto_update_with_mocks "$_au_tmp" >/dev/null 2>&1 \
  && assert_not_empty "$(cat "$_au_tmp/git.log")" \
  && assert_empty "$(cat "$_au_tmp/bash.log")"; then
  pass "auto-update: dirty repo skips setup update"
else
  fail "auto-update: dirty repo should skip setup update"
fi

# Failed setup should still release the lock.
rm -rf "$_au_tmp/home/.claude/.starter-kit-update.lock"
: > "$_au_tmp/git.log"
: > "$_au_tmp/bash.log"
MOCK_LOCAL_VER="v0.1.0"
MOCK_REMOTE_VER="v0.2.0"
MOCK_GIT_STATUS_OUTPUT=""
MOCK_SETUP_RC="1"
run_auto_update_with_mocks "$_au_tmp" >/dev/null 2>&1 || true
if assert_file_not_exists "$_au_tmp/home/.claude/.starter-kit-update.lock/pid"; then
  pass "auto-update: lock is released after failed setup update"
else
  fail "auto-update: lock should be released after failed setup update"
fi

if assert_file_exists "$_au_tmp/home/.claude/.starter-kit-update-status" \
  && assert_matches "setup\\.sh --update --non-interactive failed" "$(cat "$_au_tmp/home/.claude/.starter-kit-update-status")"; then
  pass "auto-update: failed setup persists status for next session"
else
  fail "auto-update: failed setup should persist status"
fi

MOCK_SETUP_RC="0"
rm -f "$_au_tmp/home/.claude/.starter-kit-update-cache"
run_auto_update_with_mocks "$_au_tmp" >/dev/null 2>"$_au_tmp/previous-failure.err" || true
if assert_matches "Previous auto-update failed: setup\\.sh --update --non-interactive failed" "$(cat "$_au_tmp/previous-failure.err")" \
  && assert_file_not_exists "$_au_tmp/home/.claude/.starter-kit-update-status"; then
  pass "auto-update: previous failure is surfaced once and cleared"
else
  fail "auto-update: previous failure should be surfaced once"
fi

# Legacy Claude Code should keep 24h cache behavior.
rm -f "$_au_tmp/home/.claude/.starter-kit-update-cache"
: > "$_au_tmp/git.log"
MOCK_CLAUDE_VERSION_SCRIPT="2.1.88 (Claude Code)"
MOCK_LOCAL_VER="v0.1.0"
MOCK_REMOTE_VER="v0.1.0"
run_auto_update_with_mocks "$_au_tmp" >/dev/null 2>&1 || true
first_legacy_git_log="$(cat "$_au_tmp/git.log")"
: > "$_au_tmp/git.log"
run_auto_update_with_mocks "$_au_tmp" >/dev/null 2>&1 || true
if assert_matches "fetch --tags --quiet" "$first_legacy_git_log" \
  && assert_empty "$(cat "$_au_tmp/git.log")"; then
  pass "auto-update: legacy Claude Code keeps 24h cache behavior"
else
  fail "auto-update: legacy Claude Code should skip repeated checks within cache TTL"
fi
unset MOCK_CLAUDE_VERSION_SCRIPT

# Hook fragment should expose both async session-boundary hooks.
if jq -e '
  any(.hooks.SessionStart[]?.hooks[]?; .async == true and .asyncTimeout == 300000 and (.command | contains("auto-update.sh"))) and
  any(.hooks.SessionEnd[]?.hooks[]?; .async == true and .asyncTimeout == 300000 and (.command | contains("auto-update.sh")))
' "$PROJECT_DIR/features/auto-update/hooks.json" >/dev/null 2>&1; then
  pass "auto-update: hooks.json registers async SessionStart and SessionEnd with timeout"
else
  fail "auto-update: hooks.json should register async SessionStart and SessionEnd with timeout"
fi

# build_settings_file should keep both async hook entries on supported Claude Code.
_au_settings="$_au_tmp/auto-update-settings.json"
mkdir -p "$_au_tmp/claude-current-bin"
cat >"$_au_tmp/claude-current-bin/claude" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' '2.1.89 (Claude Code)'
fi
EOF
chmod +x "$_au_tmp/claude-current-bin/claude"
PATH="$_au_tmp/claude-current-bin:$PATH" build_settings_file "$_au_settings" >/dev/null
if jq -e '
  any(.hooks.SessionStart[]?.hooks[]?; .async == true and .asyncTimeout == 300000 and (.command | contains("auto-update.sh"))) and
  any(.hooks.SessionEnd[]?.hooks[]?; .async == true and .asyncTimeout == 300000 and (.command | contains("auto-update.sh")))
' "$_au_settings" >/dev/null 2>&1; then
  pass "auto-update: merged settings include async SessionStart and SessionEnd hooks with timeout"
else
  fail "auto-update: merged settings should include async SessionStart and SessionEnd hooks with timeout"
fi

# Older Claude Code should fall back to SessionStart-only without async.
_au_legacy_settings="$_au_tmp/auto-update-legacy-settings.json"
mkdir -p "$_au_tmp/claude-legacy-bin"
cat >"$_au_tmp/claude-legacy-bin/claude" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' '2.1.88 (Claude Code)'
fi
EOF
chmod +x "$_au_tmp/claude-legacy-bin/claude"
PATH="$_au_tmp/claude-legacy-bin:$PATH" build_settings_file "$_au_legacy_settings" >/dev/null
if jq -e '
  any(.hooks.SessionStart[]?.hooks[]?; (.command | contains("auto-update.sh"))) and
  ((.hooks.SessionEnd // []) | length == 0) and
  (any(.hooks.SessionStart[]?.hooks[]?; .async == true) | not)
' "$_au_legacy_settings" >/dev/null 2>&1; then
  pass "auto-update: legacy Claude Code falls back to SessionStart without async"
else
  fail "auto-update: legacy Claude Code should fall back to SessionStart without async"
fi
