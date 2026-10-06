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
run_auto_update_with_mocks "$_au_tmp" >/dev/null 2>"$_au_tmp/previous-failure.err" || true
if assert_matches "Previous auto-update failed: setup\\.sh --update --non-interactive failed" "$(cat "$_au_tmp/previous-failure.err")" \
  && assert_file_not_exists "$_au_tmp/home/.claude/.starter-kit-update-status"; then
  pass "auto-update: previous failure is surfaced once and cleared"
else
  fail "auto-update: previous failure should be surfaced once"
fi

# The 24h cache of the retired < 2.1.89 path is gone: a leftover legacy hook
# entry (AUTO_UPDATE_LEGACY=1) and a fresh cache file must neither throttle the
# check nor be written to.
_au_cache="$_au_tmp/home/.claude/.starter-kit-update-cache"
# One minute old: fresh for the former 24h TTL, yet any rewrite changes it.
printf '%s\n' "$(( $(date +%s) - 60 ))" > "$_au_cache"
_au_cache_before="$(cat "$_au_cache")"
: > "$_au_tmp/git.log"
MOCK_LOCAL_VER="v0.1.0"
MOCK_REMOTE_VER="v0.1.0"
AUTO_UPDATE_LEGACY=1 run_auto_update_with_mocks "$_au_tmp" >/dev/null 2>&1 || true
_au_first_git_log="$(cat "$_au_tmp/git.log")"
: > "$_au_tmp/git.log"
AUTO_UPDATE_LEGACY=1 run_auto_update_with_mocks "$_au_tmp" >/dev/null 2>&1 || true
if assert_matches "fetch --tags --quiet" "$_au_first_git_log" \
  && assert_matches "fetch --tags --quiet" "$(cat "$_au_tmp/git.log")" \
  && assert_equals "$_au_cache_before" "$(cat "$_au_cache")"; then
  pass "auto-update: AUTO_UPDATE_LEGACY and a fresh update cache no longer throttle the check"
else
  fail "auto-update: the retired 24h cache must not skip or record an update check"
fi
rm -f "$_au_cache"

# Hook fragment should expose both async session-boundary hooks.
if jq -e '
  any(.hooks.SessionStart[]?; .matcher == "startup" and any(.hooks[]?; .async == true and .asyncTimeout == 300000 and (.command | contains("auto-update.sh")))) and
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
  any(.hooks.SessionStart[]?; .matcher == "startup" and any(.hooks[]?; .async == true and .asyncTimeout == 300000 and (.command | contains("auto-update.sh")))) and
  any(.hooks.SessionEnd[]?.hooks[]?; .async == true and .asyncTimeout == 300000 and (.command | contains("auto-update.sh")))
' "$_au_settings" >/dev/null 2>&1; then
  pass "auto-update: merged settings include async SessionStart and SessionEnd hooks with timeout"
else
  fail "auto-update: merged settings should include async SessionStart and SessionEnd hooks with timeout"
fi

# The hook shape no longer depends on the installed Claude Code (legacy path
# retired in v0.79.0, #136): a current CLI, an older one and one whose version
# cannot be parsed all get byte-identical settings, and building never starts
# `claude`. Each build runs in a fresh process so no shell state carried over
# from an earlier build can make the variants agree.
_au_spy_log="$_au_tmp/claude-spy.log"
: > "$_au_spy_log"
mkdir -p "$_au_tmp/claude-spy-bin"
cat >"$_au_tmp/claude-spy-bin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${AU_CLAUDE_SPY_LOG:?}"
printf '%s\n' "${AU_CLAUDE_SPY_VERSION:?}"
EOF
chmod +x "$_au_tmp/claude-spy-bin/claude"

_au_build_fresh() { # <claude --version output> <output-file>
  AU_CLAUDE_SPY_LOG="$_au_spy_log" AU_CLAUDE_SPY_VERSION="$1" \
    HOME="$_au_tmp/home" PATH="$_au_tmp/claude-spy-bin:$PATH" \
    "$BASH" -c '
      set -euo pipefail
      PROJECT_DIR="$1"
      _SETUP_TMP_FILES=()
      _au_child_cleanup() {
        [[ "${#_SETUP_TMP_FILES[@]}" -eq 0 ]] || rm -rf "${_SETUP_TMP_FILES[@]}"
      }
      trap _au_child_cleanup EXIT
      source "$PROJECT_DIR/lib/colors.sh"
      source "$PROJECT_DIR/lib/features.sh"
      source "$PROJECT_DIR/lib/template.sh"
      source "$PROJECT_DIR/lib/json-builder.sh"
      source "$PROJECT_DIR/lib/snapshot.sh"
      source "$PROJECT_DIR/lib/merge.sh"
      source "$PROJECT_DIR/lib/dryrun.sh"
      source "$PROJECT_DIR/lib/deploy.sh"
      source "$PROJECT_DIR/profiles/standard.conf"
      LANGUAGE=en
      build_settings_file "$2" >/dev/null
    ' au-build-fresh "$PROJECT_DIR" "$2"
}

_au_version_independent=true
_au_build_fresh "2.1.89 (Claude Code)" "$_au_tmp/fresh-current.json" \
  || _au_version_independent=false
_au_build_fresh "2.1.88 (Claude Code)" "$_au_tmp/fresh-old.json" \
  || _au_version_independent=false
_au_build_fresh "not a version" "$_au_tmp/fresh-unparsable.json" \
  || _au_version_independent=false
if [[ "$_au_version_independent" == "true" ]] \
  && jq -e 'any(.hooks.SessionEnd[]?.hooks[]?; .async == true and (.command | contains("auto-update.sh")))' \
    "$_au_tmp/fresh-current.json" >/dev/null 2>&1 \
  && cmp -s "$_au_tmp/fresh-current.json" "$_au_tmp/fresh-old.json" \
  && cmp -s "$_au_tmp/fresh-current.json" "$_au_tmp/fresh-unparsable.json" \
  && [[ ! -s "$_au_spy_log" ]]; then
  pass "auto-update: build_settings_file does not depend on the installed Claude Code version"
else
  fail "auto-update: build_settings_file must emit one hook shape without starting claude (claude ran $(wc -l < "$_au_spy_log" | tr -d ' ') time(s))"
fi

# ── _check_auto_update_health: hook detection ──────────────────────────────
#
# `jq -e` derives its exit code from the LAST output, so the original
# `.hooks.SessionStart[]?.hooks[]?.command | contains("auto-update")` filter
# answered "not registered" whenever any other SessionStart hook was merged
# after auto-update. _FEATURE_ORDER puts feature-recommendation last and
# _feature_deploy_enabled deploys it on every non-MDM install, so a healthy
# standard/full install reported the warning on every update and fresh install.
#
# HOME is redirected because the function resolves $HOME/.claude-starter-kit
# for its repo and version checks, which would otherwise fold the developer's
# own machine state into the same issues[] array these cases assert on.
# shellcheck source=lib/update.sh
source "$PROJECT_DIR/lib/update.sh"

_auh_home="$_au_tmp/auh-home"
mkdir -p "$_auh_home/.claude-starter-kit/.git"

_auh_run() { # <settings-body> -> health check output
  local body="$1" dir
  dir="$(mktemp -d "$_au_tmp/auh-XXXXXX")"
  printf '%s' "$body" > "$dir/settings.json"
  # shellcheck disable=SC2034 # STR_* are read by _check_auto_update_health
  (
    HOME="$_auh_home"
    STR_AUTOUPDATE_NO_HOOK="NOHOOK"
    STR_AUTOUPDATE_NOTICE="NOTICE"
    STR_AUTOUPDATE_HINT_HOOK="HINT"
    STR_AUTOUPDATE_NO_REPO="NOREPO"
    STR_AUTOUPDATE_OUTDATED="OUTDATED"
    STR_AUTOUPDATE_OK="ACTIVE"
    info() { printf '%s\n' "$*"; }
    ok() { printf '%s\n' "$*"; }
    _check_auto_update_health "$dir"
  ) 2>&1
}

_auh_start_au='{"matcher":"startup","hooks":[{"type":"command","command":"AUTO_UPDATE_HOOK=SessionStart /h/auto-update/auto-update.sh"}]}'
_auh_start_other='{"matcher":"startup","hooks":[{"type":"command","command":"/h/feature-recommendation/check-pending.sh"}]}'
_auh_start_nocmd='{"matcher":"startup","hooks":[{"type":"other"}]}'
_auh_end_au='{"matcher":"*","hooks":[{"type":"command","command":"AUTO_UPDATE_HOOK=SessionEnd /h/auto-update/auto-update.sh"}]}'
_auh_end_other='{"matcher":"*","hooks":[{"type":"command","command":"echo bye"}]}'

# The regression itself: auto-update registered, another hook after it.
_auh_out="$(_auh_run "{\"hooks\":{\"SessionStart\":[$_auh_start_au,$_auh_start_other],\"SessionEnd\":[$_auh_end_au]}}")"
if [[ "$_auh_out" != *NOHOOK* ]] && [[ "$_auh_out" == *ACTIVE* ]]; then
  pass "auto-update health: a hook registered after auto-update is not read as missing"
else
  fail "auto-update health: trailing SessionStart hook must not fake a missing registration (got '$_auh_out')"
fi

_auh_out="$(_auh_run "{\"hooks\":{\"SessionStart\":[$_auh_start_other,$_auh_start_au],\"SessionEnd\":[$_auh_end_au]}}")"
if [[ "$_auh_out" != *NOHOOK* ]]; then
  pass "auto-update health: detection is independent of position in the array"
else
  fail "auto-update health: auto-update last should still be detected (got '$_auh_out')"
fi

# A hook entry with no `command` key aborts an unguarded filter with jq exit 5,
# which looks exactly like "absent" once the status is discarded.
_auh_out="$(_auh_run "{\"hooks\":{\"SessionStart\":[$_auh_start_nocmd,$_auh_start_au],\"SessionEnd\":[$_auh_end_au]}}")"
if [[ "$_auh_out" != *NOHOOK* ]]; then
  pass "auto-update health: an entry without a command does not hide the registration"
else
  fail "auto-update health: commandless entry must not abort the probe (got '$_auh_out')"
fi

_auh_out="$(_auh_run "{\"hooks\":{\"SessionStart\":[$_auh_start_other]}}")"
if [[ "$_auh_out" == *NOHOOK* ]]; then
  pass "auto-update health: a genuinely absent hook is still reported"
else
  fail "auto-update health: missing auto-update must warn (got '$_auh_out')"
fi

_auh_out="$(_auh_run '{}')"
if [[ "$_auh_out" == *NOHOOK* ]]; then
  pass "auto-update health: settings with no hooks at all is reported"
else
  fail "auto-update health: empty settings must warn (got '$_auh_out')"
fi

# SessionEnd is always required, whichever hook follows auto-update.
_auh_out="$(_auh_run "{\"hooks\":{\"SessionStart\":[$_auh_start_au,$_auh_start_other],\"SessionEnd\":[$_auh_end_other]}}")"
if [[ "$_auh_out" == *NOHOOK* ]]; then
  pass "auto-update health: a missing SessionEnd hook is reported"
else
  fail "auto-update health: SessionEnd probe must not inherit the SessionStart answer (got '$_auh_out')"
fi

# The kit ships a single hook shape, so that answer must not change with the
# installed CLI: an old one on PATH used to switch the SessionEnd requirement
# off. A fresh process keeps shell state from the builds above out of it.
mkdir -p "$_au_tmp/auh-old-cli"
: > "$_au_spy_log"
printf '%s'"{\"hooks\":{\"SessionStart\":[$_auh_start_au],\"SessionEnd\":[$_auh_end_other]}}" \
  > "$_au_tmp/auh-old-cli/settings.json"
_auh_out="$(
  AU_CLAUDE_SPY_LOG="$_au_spy_log" AU_CLAUDE_SPY_VERSION="2.1.88 (Claude Code)" \
    HOME="$_auh_home" PATH="$_au_tmp/claude-spy-bin:$PATH" \
    "$BASH" -c '
      set -euo pipefail
      PROJECT_DIR="$1"
      _SETUP_TMP_FILES=()
      source "$PROJECT_DIR/lib/colors.sh"
      source "$PROJECT_DIR/lib/features.sh"
      source "$PROJECT_DIR/lib/template.sh"
      source "$PROJECT_DIR/lib/json-builder.sh"
      source "$PROJECT_DIR/lib/snapshot.sh"
      source "$PROJECT_DIR/lib/merge.sh"
      source "$PROJECT_DIR/lib/dryrun.sh"
      source "$PROJECT_DIR/lib/deploy.sh"
      source "$PROJECT_DIR/lib/update.sh"
      STR_AUTOUPDATE_NO_HOOK="NOHOOK"
      STR_AUTOUPDATE_NOTICE="NOTICE"
      STR_AUTOUPDATE_HINT_HOOK="HINT"
      STR_AUTOUPDATE_OK="ACTIVE"
      info() { printf "%s\n" "$*"; }
      ok() { printf "%s\n" "$*"; }
      _check_auto_update_health "$2"
    ' auh-old-cli "$PROJECT_DIR" "$_au_tmp/auh-old-cli" 2>&1
)" || true
if [[ "$_auh_out" == *NOHOOK* ]] && [[ ! -s "$_au_spy_log" ]]; then
  pass "auto-update health: the SessionEnd requirement does not depend on the installed CLI"
else
  fail "auto-update health: an old CLI on PATH must not relax the SessionEnd requirement (got '$_auh_out')"
fi

# An unreadable answer is not an answer: claim neither failure nor health.
_auh_out="$(_auh_run '{"hooks": ')"
if [[ "$_auh_out" != *NOHOOK* ]] && [[ "$_auh_out" != *ACTIVE* ]]; then
  pass "auto-update health: an unparseable settings.json reports neither state"
else
  fail "auto-update health: invalid JSON must not be read as a verdict (got '$_auh_out')"
fi
