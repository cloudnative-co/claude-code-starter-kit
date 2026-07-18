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

# A manifest entry beneath a symlinked ancestor must not turn that ancestor
# into authority to delete the referent. Exercise the complete uninstaller so
# the check covers the actual files[] loop and its directory cleanup phase.
_ut_boundary_home="$_ut_tmp/boundary-home"
_ut_boundary_skill="$_ut_boundary_home/.claude/skills/web-content-extraction"
_ut_boundary_external="$_ut_tmp/boundary-external"
_ut_boundary_output="$_ut_tmp/boundary-uninstall.out"
_ut_bin="$_ut_tmp/bin"
mkdir -p "$_ut_boundary_home/.claude/skills" "$_ut_boundary_external" "$_ut_bin"
printf 'outside managed-looking bytes\n' > "$_ut_boundary_external/SKILL.md"
printf '{"managed":true}\n' > "$_ut_boundary_home/.claude/settings.json"
printf '%s\n' \
  '<!-- BEGIN STARTER-KIT-MANAGED -->' \
  'kit content' \
  '<!-- END STARTER-KIT-MANAGED -->' \
  '' \
  'user content' > "$_ut_boundary_home/.claude/CLAUDE.md"
ln -s "$_ut_boundary_external" "$_ut_boundary_skill"
ln -s "$(command -v jq)" "$_ut_bin/jq"

_ut_run_uninstall() { # <home> <output>
  local case_home="$1" output="$2" rc=0
  printf 'y\n' | HOME="$case_home" \
    STARTER_KIT_DIR="$case_home/nonexistent-kit" \
    PATH="$_ut_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$PROJECT_DIR/uninstall.sh" > "$output" 2>&1 || rc=$?
  return "$rc"
}

jq -n \
  --arg settings "$_ut_boundary_home/.claude/settings.json" \
  --arg claude_md "$_ut_boundary_home/.claude/CLAUDE.md" \
  --arg escaped "$_ut_boundary_skill/SKILL.md" \
  --arg cleanup "$_ut_boundary_home/.claude/.starter-kit-update.lock" \
  '{version:"2", profile:"standard", language:"en", timestamp:"test",
    files:[$settings,$claude_md,$escaped], cleanup_paths:[$cleanup]}' \
  > "$_ut_boundary_home/.claude/.starter-kit-manifest.json"

_ut_boundary_rc=0
_ut_run_uninstall "$_ut_boundary_home" "$_ut_boundary_output" \
  || _ut_boundary_rc=$?

if [[ "$_ut_boundary_rc" -ne 0 ]] \
  && grep -q 'managed' "$_ut_boundary_home/.claude/settings.json" \
  && [[ -f "$_ut_boundary_home/.claude/.starter-kit-manifest.json" ]] \
  && grep -qx 'user content' "$_ut_boundary_home/.claude/CLAUDE.md" \
  && grep -q 'STARTER-KIT-MANAGED' \
    "$_ut_boundary_home/.claude/CLAUDE.md" \
  && [[ -L "$_ut_boundary_skill" ]] \
  && grep -qx 'outside managed-looking bytes' \
    "$_ut_boundary_external/SKILL.md" \
  && grep -q 'Existing or unsafe web-content-extraction update lock' \
    "$_ut_boundary_output" \
  && ! grep -q 'Uninstall complete' "$_ut_boundary_output"; then
  pass "uninstall: unsafe WCE lock preflight prevents every mutation"
else
  fail "uninstall: tracked-file cleanup crossed or removed an unsafe symlink boundary (rc=$_ut_boundary_rc)"
fi

# The managed root itself is never a deletion authority when it is a symlink.
# Preflight must stop before tracked, generic, legacy, or empty-dir mutation.
_ut_root_home="$_ut_tmp/root-link-home"
_ut_root_referent="$_ut_tmp/root-link-referent"
_ut_root_output="$_ut_tmp/root-link-uninstall.out"
mkdir -p "$_ut_root_home" "$_ut_root_referent/sessions" \
  "$_ut_root_referent/hooks/empty-feature"
printf 'tracked settings\n' > "$_ut_root_referent/settings.json"
printf 'generic session\n' > "$_ut_root_referent/sessions/marker"
printf 'legacy file\n' > "$_ut_root_referent/AGENTS.md"
printf 'user referent\n' > "$_ut_root_referent/user-marker"
ln -s "$_ut_root_referent" "$_ut_root_home/.claude"
jq -n \
  --arg settings "$_ut_root_home/.claude/settings.json" \
  --arg sessions "$_ut_root_home/.claude/sessions" \
  '{version:"2", profile:"standard", language:"en", timestamp:"test",
    files:[$settings], cleanup_paths:[$sessions]}' \
  > "$_ut_root_referent/.starter-kit-manifest.json"

_ut_root_rc=0
_ut_run_uninstall "$_ut_root_home" "$_ut_root_output" || _ut_root_rc=$?
if [[ "$_ut_root_rc" -ne 0 ]] \
  && [[ -L "$_ut_root_home/.claude" ]] \
  && grep -qx 'tracked settings' "$_ut_root_referent/settings.json" \
  && grep -qx 'generic session' "$_ut_root_referent/sessions/marker" \
  && grep -qx 'legacy file' "$_ut_root_referent/AGENTS.md" \
  && grep -qx 'user referent' "$_ut_root_referent/user-marker" \
  && [[ -d "$_ut_root_referent/hooks/empty-feature" ]] \
  && [[ -f "$_ut_root_referent/.starter-kit-manifest.json" ]] \
  && grep -q 'Unsafe managed root' "$_ut_root_output" \
  && ! grep -q 'Uninstall complete' "$_ut_root_output"; then
  pass "uninstall: symlinked managed root preserves the complete referent"
else
  fail "uninstall: symlinked managed root allowed mutation (rc=$_ut_root_rc)"
fi

# Runtime glob and hook-directory cleanup must refuse symlinked ancestors
# before expanding or listing anything in their external referents.
_ut_cleanup_home="$_ut_tmp/cleanup-boundary-home"
_ut_cleanup_external_tmp="$_ut_tmp/cleanup-external-tmp"
_ut_cleanup_external_hooks="$_ut_tmp/cleanup-external-hooks"
_ut_cleanup_output="$_ut_tmp/cleanup-boundary-uninstall.out"
mkdir -p "$_ut_cleanup_home/.claude" "$_ut_cleanup_external_tmp" \
  "$_ut_cleanup_external_hooks/empty-external"
printf 'outside counter\n' \
  > "$_ut_cleanup_external_tmp/tool-count-escaped"
ln -s "$_ut_cleanup_external_tmp" "$_ut_cleanup_home/.claude/tmp"
ln -s "$_ut_cleanup_external_hooks" "$_ut_cleanup_home/.claude/hooks"
jq -n --arg tool_glob "$_ut_cleanup_home/.claude/tmp/tool-count-*" \
  '{version:"2", profile:"standard", language:"en", timestamp:"test",
    files:[], cleanup_paths:[$tool_glob]}' \
  > "$_ut_cleanup_home/.claude/.starter-kit-manifest.json"

_ut_cleanup_rc=0
_ut_run_uninstall "$_ut_cleanup_home" "$_ut_cleanup_output" \
  || _ut_cleanup_rc=$?
if [[ "$_ut_cleanup_rc" -ne 0 ]] \
  && [[ -L "$_ut_cleanup_home/.claude/tmp" ]] \
  && [[ -L "$_ut_cleanup_home/.claude/hooks" ]] \
  && [[ -f "$_ut_cleanup_home/.claude/.starter-kit-manifest.json" ]] \
  && grep -qx 'outside counter' \
    "$_ut_cleanup_external_tmp/tool-count-escaped" \
  && [[ -d "$_ut_cleanup_external_hooks/empty-external" ]] \
  && grep -q 'tool-count runtime under an unsafe path' "$_ut_cleanup_output" \
  && grep -q 'hook directories under an unsafe path' "$_ut_cleanup_output" \
  && ! grep -q 'Uninstall complete' "$_ut_cleanup_output"; then
  pass "uninstall: runtime boundary failure retains retry manifest"
else
  fail "uninstall: runtime cleanup crossed a symlink ancestor (rc=$_ut_cleanup_rc)"
fi

# A real removal error has the same retry contract as an unsafe ancestor.
_ut_failure_home="$_ut_tmp/cleanup-failure-home"
_ut_failure_output="$_ut_tmp/cleanup-failure-uninstall.out"
_ut_failure_bin="$_ut_tmp/failure-bin"
mkdir -p "$_ut_failure_home/.claude/tmp" "$_ut_failure_bin"
printf 'retry me\n' > "$_ut_failure_home/.claude/tmp/tool-count-fail"
ln -s "$(command -v jq)" "$_ut_failure_bin/jq"
cat > "$_ut_failure_bin/rm" <<'EOF'
#!/bin/bash
case " $* " in
  *tool-count-fail*) exit 1 ;;
esac
exec /bin/rm "$@"
EOF
chmod +x "$_ut_failure_bin/rm"
jq -n --arg tool_glob "$_ut_failure_home/.claude/tmp/tool-count-*" \
  '{version:"2", profile:"standard", language:"en", timestamp:"test",
    files:[], cleanup_paths:[$tool_glob]}' \
  > "$_ut_failure_home/.claude/.starter-kit-manifest.json"

_ut_failure_rc=0
printf 'y\n' | HOME="$_ut_failure_home" \
  STARTER_KIT_DIR="$_ut_failure_home/nonexistent-kit" \
  PATH="$_ut_failure_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$PROJECT_DIR/uninstall.sh" > "$_ut_failure_output" 2>&1 \
  || _ut_failure_rc=$?
if [[ "$_ut_failure_rc" -ne 0 ]] \
  && grep -qx 'retry me' \
    "$_ut_failure_home/.claude/tmp/tool-count-fail" \
  && [[ -f "$_ut_failure_home/.claude/.starter-kit-manifest.json" ]] \
  && ! grep -q 'Uninstall complete' "$_ut_failure_output"; then
  pass "uninstall: runtime removal error retains retry manifest"
else
  fail "uninstall: runtime removal error lost retry authority (rc=$_ut_failure_rc)"
fi

# The same CWD-bound paths must retain their normal behavior for real managed
# directories: tool counters and empty hook children are removed, user data is
# kept, and the default cleanup fallback remains effective.
_ut_safe_home="$_ut_tmp/cleanup-safe-home"
_ut_safe_output="$_ut_tmp/cleanup-safe-uninstall.out"
mkdir -p "$_ut_safe_home/.claude/tmp" \
  "$_ut_safe_home/.claude/hooks/empty-feature" \
  "$_ut_safe_home/.claude/hooks/nonempty-feature"
printf 'counter\n' > "$_ut_safe_home/.claude/tmp/tool-count-normal"
printf 'keep\n' > "$_ut_safe_home/.claude/tmp/user-file"
printf 'keep hook\n' \
  > "$_ut_safe_home/.claude/hooks/nonempty-feature/user-file"
jq -n '{version:"2", profile:"standard", language:"en", timestamp:"test",
  files:[], cleanup_paths:[]}' \
  > "$_ut_safe_home/.claude/.starter-kit-manifest.json"

_ut_safe_rc=0
_ut_run_uninstall "$_ut_safe_home" "$_ut_safe_output" || _ut_safe_rc=$?
if [[ "$_ut_safe_rc" -eq 0 ]] \
  && [[ ! -e "$_ut_safe_home/.claude/tmp/tool-count-normal" ]] \
  && [[ ! -e "$_ut_safe_home/.claude/.starter-kit-manifest.json" ]] \
  && grep -qx 'keep' "$_ut_safe_home/.claude/tmp/user-file" \
  && [[ ! -e "$_ut_safe_home/.claude/hooks/empty-feature" ]] \
  && grep -qx 'keep hook' \
    "$_ut_safe_home/.claude/hooks/nonempty-feature/user-file" \
  && grep -q 'Uninstall complete' "$_ut_safe_output"; then
  pass "uninstall: verified runtime directories retain normal cleanup behavior"
else
  fail "uninstall: verified runtime cleanup did not remove only safe targets (rc=$_ut_safe_rc)"
fi

# The standalone uninstaller shares the updater's directory-lock contract.
# Existing owner state blocks before any tracked file or manifest is mutated.
_ut_lock_home="$_ut_tmp/directory-lock-home"
_ut_lock_output="$_ut_tmp/directory-lock-uninstall.out"
_ut_lock_skill="$_ut_lock_home/.claude/skills/web-content-extraction"
mkdir -p "$_ut_lock_skill/logs/.update.lock"
printf 'foreign-updater\n' > "$_ut_lock_skill/logs/.update.lock/owner"
printf 'tracked-before\n' > "$_ut_lock_home/.claude/settings.json"
jq -n --arg settings "$_ut_lock_home/.claude/settings.json" \
  '{version:"2", profile:"standard", language:"en", timestamp:"test",
    files:[$settings], cleanup_paths:[]}' \
  > "$_ut_lock_home/.claude/.starter-kit-manifest.json"
_ut_lock_rc=0
_ut_run_uninstall "$_ut_lock_home" "$_ut_lock_output" || _ut_lock_rc=$?
if [[ "$_ut_lock_rc" -ne 0 ]] \
  && grep -qx tracked-before "$_ut_lock_home/.claude/settings.json" \
  && grep -qx foreign-updater "$_ut_lock_skill/logs/.update.lock/owner" \
  && [[ -f "$_ut_lock_home/.claude/.starter-kit-manifest.json" ]]; then
  pass "uninstall: active directory lock blocks all mutation"
else
  fail "uninstall: active directory lock was removed or bypassed"
fi

# A FIFO at the canonical lock name must never be opened by noclobber output.
_ut_fifo_home="$_ut_tmp/fifo-lock-home"
_ut_fifo_output="$_ut_tmp/fifo-lock-uninstall.out"
_ut_fifo_skill="$_ut_fifo_home/.claude/skills/web-content-extraction"
mkdir -p "$_ut_fifo_skill/logs"
mkfifo "$_ut_fifo_skill/logs/.update.lock"
printf 'tracked-before\n' > "$_ut_fifo_home/.claude/settings.json"
jq -n --arg settings "$_ut_fifo_home/.claude/settings.json" \
  '{version:"2", profile:"standard", language:"en", timestamp:"test",
    files:[$settings], cleanup_paths:[]}' \
  > "$_ut_fifo_home/.claude/.starter-kit-manifest.json"
_ut_fifo_rc=0
_ut_run_uninstall "$_ut_fifo_home" "$_ut_fifo_output" || _ut_fifo_rc=$?
if [[ "$_ut_fifo_rc" -ne 0 && -p "$_ut_fifo_skill/logs/.update.lock" ]] \
  && grep -qx tracked-before "$_ut_fifo_home/.claude/settings.json" \
  && [[ -f "$_ut_fifo_home/.claude/.starter-kit-manifest.json" ]]; then
  pass "uninstall: FIFO lock fails closed without being opened"
else
  fail "uninstall: FIFO lock blocked, changed, or permitted mutation"
fi

# Replace the canonical lock after its first owner check. The quarantine
# verification must reject the changed exact bytes and restore the replacement.
_ut_race_home="$_ut_tmp/release-race-home"
_ut_race_output="$_ut_tmp/release-race-uninstall.out"
_ut_race_skill="$_ut_race_home/.claude/skills/web-content-extraction"
_ut_race_bin="$_ut_tmp/release-race-bin"
_ut_race_sentinel="$_ut_tmp/release-race-fired"
mkdir -p "$_ut_race_skill" "$_ut_race_bin"
ln -s "$(command -v jq)" "$_ut_race_bin/jq"
jq -n '{version:"2", profile:"standard", language:"en", timestamp:"test",
  files:[], cleanup_paths:[]}' \
  > "$_ut_race_home/.claude/.starter-kit-manifest.json"
cat > "$_ut_race_bin/mv" <<'EOF'
#!/bin/bash
if [[ "$1" == */logs/.update.lock && "$2" == */logs/.update.lock.release-* \
  && ! -e "$WCE_MV_SENTINEL" ]]; then
  : > "$WCE_MV_SENTINEL"
  owner="$(/bin/cat "$1/owner")"
  /bin/rm -rf "$1" || exit 1
  /bin/mkdir "$1" || exit 1
  printf '%s\nextra-owner-line\n' "$owner" > "$1/owner" || exit 1
fi
exec /bin/mv "$@"
EOF
chmod +x "$_ut_race_bin/mv"
_ut_race_rc=0
printf 'y\n' | HOME="$_ut_race_home" \
  STARTER_KIT_DIR="$_ut_race_home/nonexistent-kit" \
  WCE_MV_SENTINEL="$_ut_race_sentinel" \
  PATH="$_ut_race_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$PROJECT_DIR/uninstall.sh" > "$_ut_race_output" 2>&1 \
  || _ut_race_rc=$?
if [[ "$_ut_race_rc" -ne 0 ]] \
  && [[ "$(LC_ALL=C wc -l \
    < "$_ut_race_skill/logs/.update.lock/owner" | tr -d '[:space:]')" -eq 2 ]] \
  && grep -qx extra-owner-line "$_ut_race_skill/logs/.update.lock/owner" \
  && [[ -f "$_ut_race_home/.claude/.starter-kit-manifest.json" ]] \
  && ! compgen -G "$_ut_race_skill/logs/.update.lock.release-*" >/dev/null \
  && ! grep -q 'Uninstall complete' "$_ut_race_output"; then
  pass "uninstall: read-to-rename foreign replacement is retained"
else
  fail "uninstall: release deleted or accepted changed owner bytes"
fi

# TERM immediately after the acquire mkdir is deferred until owner publication;
# EXIT cleanup then releases that exact token before returning status 143.
_ut_acquire_signal_home="$_ut_tmp/acquire-signal-home"
_ut_acquire_signal_output="$_ut_tmp/acquire-signal-uninstall.out"
_ut_acquire_signal_skill="$_ut_acquire_signal_home/.claude/skills/web-content-extraction"
_ut_acquire_signal_bin="$_ut_tmp/acquire-signal-bin"
_ut_acquire_signal_sentinel="$_ut_tmp/acquire-signal-fired"
mkdir -p "$_ut_acquire_signal_skill" "$_ut_acquire_signal_bin"
ln -s "$(command -v jq)" "$_ut_acquire_signal_bin/jq"
printf 'tracked-before\n' > "$_ut_acquire_signal_home/.claude/settings.json"
jq -n --arg settings "$_ut_acquire_signal_home/.claude/settings.json" \
  '{version:"2", profile:"standard", language:"en", timestamp:"test",
    files:[$settings], cleanup_paths:[]}' \
  > "$_ut_acquire_signal_home/.claude/.starter-kit-manifest.json"
cat > "$_ut_acquire_signal_bin/mkdir" <<'EOF'
#!/bin/bash
/bin/mkdir "$@" || exit 1
last=""
for last do :; done
if [[ "$last" == */logs/.update.lock && ! -e "$WCE_MKDIR_SENTINEL" ]]; then
  : > "$WCE_MKDIR_SENTINEL"
  kill -TERM "$_WCE_UNINSTALL_ACQUIRE_WAITER_PID"
fi
EOF
chmod +x "$_ut_acquire_signal_bin/mkdir"
_ut_acquire_signal_rc=0
printf 'y\n' | HOME="$_ut_acquire_signal_home" \
  STARTER_KIT_DIR="$_ut_acquire_signal_home/nonexistent-kit" \
  WCE_MKDIR_SENTINEL="$_ut_acquire_signal_sentinel" \
  PATH="$_ut_acquire_signal_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$PROJECT_DIR/uninstall.sh" \
  > "$_ut_acquire_signal_output" 2>&1 || _ut_acquire_signal_rc=$?
if [[ "$_ut_acquire_signal_rc" -eq 143 ]] \
  && grep -qx tracked-before \
    "$_ut_acquire_signal_home/.claude/settings.json" \
  && [[ -f "$_ut_acquire_signal_home/.claude/.starter-kit-manifest.json" ]] \
  && [[ ! -e "$_ut_acquire_signal_skill/logs/.update.lock" ]] \
  && ! compgen -G \
    "$_ut_acquire_signal_skill/logs/.update.lock.release-*" >/dev/null; then
  pass "uninstall: TERM during acquisition releases ownership with status 143"
else
  fail "uninstall: TERM during acquisition leaked partial lock state"
fi

# TERM during quarantine release is deferred until release completes. The
# signal status wins and the retry manifest remains, without lock residue.
_ut_signal_home="$_ut_tmp/release-signal-home"
_ut_signal_output="$_ut_tmp/release-signal-uninstall.out"
_ut_signal_skill="$_ut_signal_home/.claude/skills/web-content-extraction"
_ut_signal_bin="$_ut_tmp/release-signal-bin"
_ut_signal_sentinel="$_ut_tmp/release-signal-fired"
mkdir -p "$_ut_signal_skill" "$_ut_signal_bin"
ln -s "$(command -v jq)" "$_ut_signal_bin/jq"
jq -n '{version:"2", profile:"standard", language:"en", timestamp:"test",
  files:[], cleanup_paths:[]}' \
  > "$_ut_signal_home/.claude/.starter-kit-manifest.json"
cat > "$_ut_signal_bin/mv" <<'EOF'
#!/bin/bash
/bin/mv "$@" || exit 1
if [[ "$1" == */logs/.update.lock && "$2" == */logs/.update.lock.release-* \
  && ! -e "$WCE_MV_SENTINEL" ]]; then
  : > "$WCE_MV_SENTINEL"
  kill -TERM "$_WCE_UNINSTALL_RELEASE_WAITER_PID"
fi
EOF
chmod +x "$_ut_signal_bin/mv"
_ut_signal_rc=0
printf 'y\n' | HOME="$_ut_signal_home" \
  STARTER_KIT_DIR="$_ut_signal_home/nonexistent-kit" \
  WCE_MV_SENTINEL="$_ut_signal_sentinel" \
  PATH="$_ut_signal_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$PROJECT_DIR/uninstall.sh" > "$_ut_signal_output" 2>&1 \
  || _ut_signal_rc=$?
if [[ "$_ut_signal_rc" -eq 143 ]] \
  && [[ -f "$_ut_signal_home/.claude/.starter-kit-manifest.json" ]] \
  && [[ ! -e "$_ut_signal_skill/logs/.update.lock" ]] \
  && ! compgen -G "$_ut_signal_skill/logs/.update.lock.release-*" >/dev/null \
  && ! grep -q 'Uninstall complete' "$_ut_signal_output"; then
  pass "uninstall: TERM waits for release and preserves status 143"
else
  fail "uninstall: TERM interrupted release or lost its signal status"
fi

rm -rf "$_ut_tmp"
