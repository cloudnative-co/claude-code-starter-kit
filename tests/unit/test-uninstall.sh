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

_ut_host_command_fingerprint() { # <command>; never executes the command
  local path value
  path="$(command -v "$1" 2>/dev/null || true)"
  [[ -n "$path" ]] || { printf 'absent\n'; return; }
  value="$(stat -f '%d:%i:%m:%z' "$path" 2>/dev/null \
    || stat -c '%d:%i:%Y:%s' "$path" 2>/dev/null || true)"
  printf '%s|%s|' "$path" "$value"
  [[ -f "$path" ]] && cksum < "$path" 2>/dev/null || printf 'not-regular\n'
}

_ut_host_claude_before="$(_ut_host_command_fingerprint claude)"
_ut_host_safety_before="$(_ut_host_command_fingerprint cc-safety-net)"
_ut_extract_fn "$PROJECT_DIR/uninstall.sh" "_detect_language" > "$_ut_tmp/detect_language.sh"

# The standalone uninstaller must retain the exact self-contained parser used
# during setup. Exercise its streaming input with the matching entry after
# 4 KiB, which would block in Bash 5.3 when implemented as a here-string on a
# 512-byte pipe.
_ut_extract_fn "$PROJECT_DIR/uninstall.sh" "_claude_plugin_list_has" \
  > "$_ut_tmp/uninstall-plugin-list-has.sh"
_ut_extract_fn "$PROJECT_DIR/lib/codex-setup.sh" "_claude_plugin_list_has" \
  > "$_ut_tmp/setup-plugin-list-has.sh"
_ut_long_plugin_list="Installed plugins:"$'\n'
_ut_long_plugin_index=0
while [[ "$_ut_long_plugin_index" -lt 512 ]]; do
  _ut_long_plugin_list="${_ut_long_plugin_list}  filler-${_ut_long_plugin_index}@marketplace"$'\n'
  _ut_long_plugin_index=$((_ut_long_plugin_index + 1))
done
_ut_long_plugin_list="${_ut_long_plugin_list}  ❯ codex@openai-codex"$'\n'
# shellcheck source=/dev/null
source "$_ut_tmp/uninstall-plugin-list-has.sh"
if cmp -s "$_ut_tmp/uninstall-plugin-list-has.sh" \
    "$_ut_tmp/setup-plugin-list-has.sh" \
  && [[ "${#_ut_long_plugin_list}" -gt 4096 ]] \
  && _claude_plugin_list_has "$_ut_long_plugin_list" "codex" \
  && ! _claude_plugin_list_has "$_ut_long_plugin_list" "codex-tools"; then
  pass "uninstall: self-contained plugin parser matches setup and streams lists larger than 4 KiB"
else
  fail "uninstall: self-contained plugin parser drifted, blocked, or misparsed a large list"
fi
unset -f _claude_plugin_list_has
unset _ut_long_plugin_list _ut_long_plugin_index

_ut_home="$_ut_tmp/home"
mkdir -p "$_ut_home"

# conf present but missing the LANGUAGE= line (malformed/older conf)
cat > "$_ut_home/.claude-starter-kit.conf" <<'EOF'
PROFILE="standard"
EOF

_ut_out="$(env -i HOME="$_ut_home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  LC_ALL=C TERM=dumb bash -c '
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

_ut_out2="$(env -i HOME="$_ut_home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  LC_ALL=C TERM=dumb bash -c '
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
# Host isolation: uninstall.sh probes optional external commands and shows
# extra prompts when it finds them, which would (a) desync the queued answers
# and (b) on the cc-safety-net prompt REALLY run `npm uninstall -g` against
# the host. The e2e PATH keeps /usr/bin, where Linux distros commonly install
# npm — stub it so `npm list -g cc-safety-net` fails and the prompt is
# skipped deterministically. A controlled failing `claude` stub keeps its
# unavoidable CLI-uninstall prompt harmless; queued answers always decline it.
printf '#!/bin/sh\nexit 1\n' > "$_ut_bin/npm"
chmod +x "$_ut_bin/npm"
printf '%s\n' '#!/bin/bash
printf "%s\n" "$*" >> "${UNINSTALL_CLAUDE_LOG:-/dev/null}"
exit 1
' > "$_ut_bin/claude"
chmod +x "$_ut_bin/claude"
_ut_resolved_claude="$(PATH="$_ut_bin:/usr/bin:/bin:/usr/sbin:/sbin" command -v claude || true)"
_ut_resolved_npm="$(PATH="$_ut_bin:/usr/bin:/bin:/usr/sbin:/sbin" command -v npm || true)"
if [[ "$_ut_resolved_claude" != "$_ut_bin/claude" \
  || "$_ut_resolved_npm" != "$_ut_bin/npm" ]]; then
  fail "uninstall: isolated e2e PATH did not bind both external CLI stubs"
  exit 1
fi

_ut_run_uninstall() { # <home> <output>
  local case_home="$1" output="$2" rc=0
  mkdir -p "$case_home/tmp" "$case_home/appdata" \
    "$case_home/localappdata" "$case_home/npm"
  printf 'y\nn\n' | env -i HOME="$case_home" TMPDIR="$case_home/tmp" \
    APPDATA="$case_home/appdata" LOCALAPPDATA="$case_home/localappdata" \
    NPM_CONFIG_PREFIX="$case_home/npm" npm_config_prefix="$case_home/npm" \
    STARTER_KIT_DIR="$case_home/nonexistent-kit" \
    PATH="$_ut_bin:/usr/bin:/bin:/usr/sbin:/sbin" LC_ALL=C TERM=dumb \
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
mkdir -p "$_ut_failure_home/tmp" "$_ut_failure_home/appdata" \
  "$_ut_failure_home/localappdata" "$_ut_failure_home/npm"
printf 'y\n' | env -i HOME="$_ut_failure_home" TMPDIR="$_ut_failure_home/tmp" \
  APPDATA="$_ut_failure_home/appdata" \
  LOCALAPPDATA="$_ut_failure_home/localappdata" \
  NPM_CONFIG_PREFIX="$_ut_failure_home/npm" npm_config_prefix="$_ut_failure_home/npm" \
  STARTER_KIT_DIR="$_ut_failure_home/nonexistent-kit" \
  PATH="$_ut_failure_bin:$_ut_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  LC_ALL=C TERM=dumb \
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
mkdir -p "$_ut_race_home/tmp" "$_ut_race_home/appdata" \
  "$_ut_race_home/localappdata" "$_ut_race_home/npm"
printf 'y\n' | env -i HOME="$_ut_race_home" TMPDIR="$_ut_race_home/tmp" \
  APPDATA="$_ut_race_home/appdata" LOCALAPPDATA="$_ut_race_home/localappdata" \
  NPM_CONFIG_PREFIX="$_ut_race_home/npm" npm_config_prefix="$_ut_race_home/npm" \
  STARTER_KIT_DIR="$_ut_race_home/nonexistent-kit" \
  WCE_MV_SENTINEL="$_ut_race_sentinel" \
  PATH="$_ut_race_bin:$_ut_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  LC_ALL=C TERM=dumb \
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
mkdir -p "$_ut_acquire_signal_home/tmp" "$_ut_acquire_signal_home/appdata" \
  "$_ut_acquire_signal_home/localappdata" "$_ut_acquire_signal_home/npm"
printf 'y\n' | env -i HOME="$_ut_acquire_signal_home" \
  TMPDIR="$_ut_acquire_signal_home/tmp" APPDATA="$_ut_acquire_signal_home/appdata" \
  LOCALAPPDATA="$_ut_acquire_signal_home/localappdata" \
  NPM_CONFIG_PREFIX="$_ut_acquire_signal_home/npm" \
  npm_config_prefix="$_ut_acquire_signal_home/npm" \
  STARTER_KIT_DIR="$_ut_acquire_signal_home/nonexistent-kit" \
  WCE_MKDIR_SENTINEL="$_ut_acquire_signal_sentinel" \
  PATH="$_ut_acquire_signal_bin:$_ut_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  LC_ALL=C TERM=dumb \
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
mkdir -p "$_ut_signal_home/tmp" "$_ut_signal_home/appdata" \
  "$_ut_signal_home/localappdata" "$_ut_signal_home/npm"
printf 'y\n' | env -i HOME="$_ut_signal_home" TMPDIR="$_ut_signal_home/tmp" \
  APPDATA="$_ut_signal_home/appdata" LOCALAPPDATA="$_ut_signal_home/localappdata" \
  NPM_CONFIG_PREFIX="$_ut_signal_home/npm" npm_config_prefix="$_ut_signal_home/npm" \
  STARTER_KIT_DIR="$_ut_signal_home/nonexistent-kit" \
  WCE_MV_SENTINEL="$_ut_signal_sentinel" \
  PATH="$_ut_signal_bin:$_ut_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  LC_ALL=C TERM=dumb \
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

# ── durable plugin provenance and security-guidance data ──────────────────

_ut_prepare_plugin_case() { # <name> <marker-kind>
  local name="$1" marker_kind="$2" case_home marker
  case_home="$_ut_tmp/provenance-$name"
  marker="$case_home/.claude/.starter-kit-plugin-provenance.json"
  mkdir -p "$case_home/.claude/security/agent-sdk-venv" "$case_home/tmp" \
    "$case_home/appdata" "$case_home/localappdata" "$case_home/npm"
  printf 'venv payload\n' > "$case_home/.claude/security/agent-sdk-venv/pyvenv.cfg"
  printf '{"session":1}\n' > "$case_home/.claude/security/security_warnings_state_x.json"
  printf '{"managed":true}\n' > "$case_home/.claude/settings.json"
  jq -n --arg settings "$case_home/.claude/settings.json" \
    '{version:"2", profile:"standard", language:"en", timestamp:"test",
      plugins:"security-guidance", files:[$settings], cleanup_paths:[]}' \
    > "$case_home/.claude/.starter-kit-manifest.json"
  case "$marker_kind" in
    valid-security)
      jq -n '{version:1, installed_by_kit:[
        "security-guidance@claude-plugins-official"]}' > "$marker"
      chmod 600 "$marker"
      ;;
    valid-other)
      jq -n '{version:1, installed_by_kit:[
        "code-review@claude-plugins-official"]}' > "$marker"
      chmod 600 "$marker"
      ;;
    invalid-version)
      jq -n '{version:2, installed_by_kit:[
        "security-guidance@claude-plugins-official"]}' > "$marker"
      chmod 600 "$marker"
      ;;
    invalid-mode)
      jq -n '{version:1, installed_by_kit:[
        "security-guidance@claude-plugins-official"]}' > "$marker"
      chmod 644 "$marker"
      ;;
    invalid-json)
      printf '{not-json\n' > "$marker"
      chmod 600 "$marker"
      ;;
    symlink)
      printf 'external marker\n' > "$case_home/external-marker"
      ln -s "$case_home/external-marker" "$marker"
      ;;
    fifo) mkfifo "$marker" ;;
    missing) ;;
    *) return 1 ;;
  esac
}

_ut_run_plugin_case() { # <name> <answers> [path] [ENV=value ...]
  local name="$1" answers="$2" case_home rc=0
  local case_path="${3:-$_ut_bin:/usr/bin:/bin:/usr/sbin:/sbin}"
  case_home="$_ut_tmp/provenance-$name"
  shift 3 || true
  printf '%b' "${answers}n\n" | env -i \
    HOME="$case_home" TMPDIR="$case_home/tmp" \
    APPDATA="$case_home/appdata" LOCALAPPDATA="$case_home/localappdata" \
    NPM_CONFIG_PREFIX="$case_home/npm" npm_config_prefix="$case_home/npm" \
    STARTER_KIT_DIR="$case_home/nonexistent-kit" \
    PATH="$case_path" LC_ALL=C TERM=dumb "$@" \
    bash "$PROJECT_DIR/uninstall.sh" > "$case_home/output" 2>&1 || rc=$?
  return "$rc"
}

_ut_prepare_plugin_case removed valid-security
_ut_removed_rc=0
_ut_run_plugin_case removed 'y\ny\n' "$_ut_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  || _ut_removed_rc=$?
if [[ "$_ut_removed_rc" -eq 0 ]] \
  && [[ ! -e "$_ut_tmp/provenance-removed/.claude/security" ]] \
  && [[ ! -e "$_ut_tmp/provenance-removed/.claude/.starter-kit-plugin-provenance.json" ]] \
  && grep -q 'Removed local data from the security-guidance plugin' \
    "$_ut_tmp/provenance-removed/output"; then
  pass "uninstall: valid exact provenance authorizes accepted data removal"
else
  fail "uninstall: valid exact provenance did not authorize safe removal"
fi

for _ut_choice in kept eof; do
  _ut_prepare_plugin_case "$_ut_choice" valid-security
done
_ut_kept_rc=0
_ut_run_plugin_case kept 'y\nn\n' "$_ut_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  || _ut_kept_rc=$?
_ut_eof_rc=0
_ut_run_plugin_case eof 'y\n' "$_ut_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  || _ut_eof_rc=$?
if [[ "$_ut_kept_rc" -eq 0 && "$_ut_eof_rc" -eq 0 ]] \
  && [[ -f "$_ut_tmp/provenance-kept/.claude/security/agent-sdk-venv/pyvenv.cfg" ]] \
  && [[ -f "$_ut_tmp/provenance-eof/.claude/security/agent-sdk-venv/pyvenv.cfg" ]] \
  && [[ ! -e "$_ut_tmp/provenance-kept/.claude/.starter-kit-plugin-provenance.json" ]] \
  && [[ ! -e "$_ut_tmp/provenance-eof/.claude/.starter-kit-plugin-provenance.json" ]]; then
  pass "uninstall: decline/EOF keep data but remove completed provenance"
else
  fail "uninstall: decline/EOF provenance lifecycle is incorrect"
fi

for _ut_case in legacy other; do
  if [[ "$_ut_case" == legacy ]]; then
    _ut_prepare_plugin_case "$_ut_case" missing
  else
    _ut_prepare_plugin_case "$_ut_case" valid-other
  fi
  _ut_run_plugin_case "$_ut_case" 'y\ny\n' \
    "$_ut_bin:/usr/bin:/bin:/usr/sbin:/sbin" || true
done
if [[ -f "$_ut_tmp/provenance-legacy/.claude/security/agent-sdk-venv/pyvenv.cfg" ]] \
  && [[ -f "$_ut_tmp/provenance-other/.claude/security/agent-sdk-venv/pyvenv.cfg" ]] \
  && ! grep -q 'Local data from the security-guidance plugin' \
    "$_ut_tmp/provenance-legacy/output" \
  && ! grep -q 'Local data from the security-guidance plugin' \
    "$_ut_tmp/provenance-other/output" \
  && [[ ! -e "$_ut_tmp/provenance-other/.claude/.starter-kit-plugin-provenance.json" ]]; then
  pass "uninstall: profile/manifest inference and non-exact provenance grant no authority"
else
  fail "uninstall: non-authoritative state offered plugin-data removal"
fi

_ut_invalid_ok=true
for _ut_kind in invalid-version invalid-mode invalid-json symlink fifo; do
  _ut_prepare_plugin_case "invalid-$_ut_kind" "$_ut_kind"
  _ut_invalid_rc=0
  _ut_run_plugin_case "invalid-$_ut_kind" 'y\ny\n' \
    "$_ut_bin:/usr/bin:/bin:/usr/sbin:/sbin" || _ut_invalid_rc=$?
  _ut_invalid_home="$_ut_tmp/provenance-invalid-$_ut_kind"
  [[ "$_ut_invalid_rc" -ne 0 ]] || _ut_invalid_ok=false
  [[ -f "$_ut_invalid_home/.claude/security/agent-sdk-venv/pyvenv.cfg" ]] \
    || _ut_invalid_ok=false
  [[ -f "$_ut_invalid_home/.claude/.starter-kit-manifest.json" ]] \
    || _ut_invalid_ok=false
  [[ -e "$_ut_invalid_home/.claude/.starter-kit-plugin-provenance.json" \
    || -L "$_ut_invalid_home/.claude/.starter-kit-plugin-provenance.json" ]] \
    || _ut_invalid_ok=false
  grep -q 'Unsafe plugin provenance' "$_ut_invalid_home/output" \
    || _ut_invalid_ok=false
  grep -q 'Local data from the security-guidance plugin' "$_ut_invalid_home/output" \
    && _ut_invalid_ok=false
done
if [[ "$_ut_invalid_ok" == true ]]; then
  pass "uninstall: invalid provenance aborts before mutation and remains retryable"
else
  fail "uninstall: invalid provenance did not retain retry authority"
fi

# A copied/partial uninstaller without the shared helper cannot safely
# interpret or retire an existing ownership marker, so it must stop before
# either the manifest or plugin data changes.
_ut_prepare_plugin_case helper-missing valid-security
_ut_helper_missing_home="$_ut_tmp/provenance-helper-missing"
cp "$PROJECT_DIR/uninstall.sh" "$_ut_helper_missing_home/uninstall-copy.sh"
_ut_helper_missing_rc=0
printf 'y\ny\nn\n' | env -i HOME="$_ut_helper_missing_home" \
  TMPDIR="$_ut_helper_missing_home/tmp" APPDATA="$_ut_helper_missing_home/appdata" \
  LOCALAPPDATA="$_ut_helper_missing_home/localappdata" \
  NPM_CONFIG_PREFIX="$_ut_helper_missing_home/npm" \
  npm_config_prefix="$_ut_helper_missing_home/npm" \
  STARTER_KIT_DIR="$_ut_helper_missing_home/nonexistent-kit" \
  PATH="$_ut_bin:/usr/bin:/bin:/usr/sbin:/sbin" LC_ALL=C TERM=dumb \
  bash "$_ut_helper_missing_home/uninstall-copy.sh" \
  > "$_ut_helper_missing_home/output" 2>&1 || _ut_helper_missing_rc=$?
if [[ "$_ut_helper_missing_rc" -ne 0 ]] \
  && [[ -f "$_ut_helper_missing_home/.claude/.starter-kit-manifest.json" ]] \
  && [[ -f "$_ut_helper_missing_home/.claude/.starter-kit-plugin-provenance.json" ]] \
  && [[ -f "$_ut_helper_missing_home/.claude/security/agent-sdk-venv/pyvenv.cfg" ]] \
  && grep -q 'Plugin provenance helper unavailable' \
    "$_ut_helper_missing_home/output"; then
  pass "uninstall: missing shared provenance helper aborts before mutation"
else
  fail "uninstall: missing provenance helper consumed ownership state"
fi

_ut_prepare_plugin_case canceled valid-security
_ut_run_plugin_case canceled 'n\n' "$_ut_bin:/usr/bin:/bin:/usr/sbin:/sbin" || true
if [[ -f "$_ut_tmp/provenance-canceled/.claude/.starter-kit-manifest.json" ]] \
  && [[ -f "$_ut_tmp/provenance-canceled/.claude/.starter-kit-plugin-provenance.json" ]] \
  && [[ -f "$_ut_tmp/provenance-canceled/.claude/security/agent-sdk-venv/pyvenv.cfg" ]]; then
  pass "uninstall: whole-uninstall cancellation retains provenance and data"
else
  fail "uninstall: cancellation mutated provenance-owned state"
fi

# A symlinked data leaf is not followed or offered, while a completed uninstall
# still retires the valid ownership marker.
_ut_prepare_plugin_case data-link valid-security
_ut_data_link_target="$_ut_tmp/data-link-target"
mkdir -p "$_ut_data_link_target"
printf 'external data\n' > "$_ut_data_link_target/value"
rm -rf "$_ut_tmp/provenance-data-link/.claude/security"
ln -s "$_ut_data_link_target" "$_ut_tmp/provenance-data-link/.claude/security"
_ut_run_plugin_case data-link 'y\ny\n' "$_ut_bin:/usr/bin:/bin:/usr/sbin:/sbin" || true
if [[ -L "$_ut_tmp/provenance-data-link/.claude/security" ]] \
  && grep -qx 'external data' "$_ut_data_link_target/value" \
  && [[ ! -e "$_ut_tmp/provenance-data-link/.claude/.starter-kit-plugin-provenance.json" ]] \
  && ! grep -q 'Local data from the security-guidance plugin' \
    "$_ut_tmp/provenance-data-link/output"; then
  pass "uninstall: symlinked security leaf is never followed"
else
  fail "uninstall: symlinked security leaf crossed its boundary"
fi

# Swap ~/.claude after the size probe's bound-root check but before the removal
# prompt completes. Test both a symlink replacement and a real directory at the
# same textual path; physical path alone misses the latter, dev/inode catches it.
_ut_race_bin="$_ut_tmp/provenance-race-bin"
mkdir -p "$_ut_race_bin"
ln -s "$(command -v jq)" "$_ut_race_bin/jq"
ln -s "$_ut_bin/npm" "$_ut_race_bin/npm"
printf '%s\n' '#!/bin/bash
if [[ ! -e "$RACE_SENTINEL" ]]; then
  : > "$RACE_SENTINEL"
  /bin/mv "$RACE_HOME/.claude" "$RACE_OLD" || exit 1
  if [[ "$RACE_MODE" == symlink ]]; then
    /bin/ln -s "$RACE_VICTIM" "$RACE_HOME/.claude" || exit 1
  else
    /bin/mkdir -p "$RACE_HOME/.claude/security" || exit 1
    printf "replacement data\n" > "$RACE_HOME/.claude/security/value"
  fi
fi
printf "1K\t./security\n"
' > "$_ut_race_bin/du"
chmod +x "$_ut_race_bin/du"

_ut_races_ok=true
for _ut_mode in symlink real; do
  _ut_name="race-$_ut_mode"
  _ut_prepare_plugin_case "$_ut_name" valid-security
  _ut_race_home="$_ut_tmp/provenance-$_ut_name"
  _ut_race_old="$_ut_race_home/.claude-old"
  _ut_race_victim="$_ut_tmp/$_ut_name-victim"
  mkdir -p "$_ut_race_victim/security"
  printf 'victim data\n' > "$_ut_race_victim/security/value"
  _ut_race_rc=0
  _ut_run_plugin_case "$_ut_name" 'y\ny\n' \
    "$_ut_race_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    RACE_HOME="$_ut_race_home" RACE_OLD="$_ut_race_old" \
    RACE_VICTIM="$_ut_race_victim" RACE_MODE="$_ut_mode" \
    RACE_SENTINEL="$_ut_race_home/race-fired" || _ut_race_rc=$?
  [[ "$_ut_race_rc" -ne 0 ]] || _ut_races_ok=false
  [[ -f "$_ut_race_old/.starter-kit-plugin-provenance.json" ]] \
    || _ut_races_ok=false
  [[ -f "$_ut_race_old/.starter-kit-manifest.json" ]] || _ut_races_ok=false
  [[ -f "$_ut_race_old/security/agent-sdk-venv/pyvenv.cfg" ]] \
    || _ut_races_ok=false
  grep -qx 'victim data' "$_ut_race_victim/security/value" \
    || _ut_races_ok=false
done
if [[ "$_ut_races_ok" == true ]]; then
  pass "uninstall: symlink and real-directory prompt races retain bound state"
else
  fail "uninstall: root replacement bypassed path+dev/inode binding"
fi

_ut_host_claude_after="$(_ut_host_command_fingerprint claude)"
_ut_host_safety_after="$(_ut_host_command_fingerprint cc-safety-net)"
if [[ "$_ut_host_claude_before" == "$_ut_host_claude_after" \
  && "$_ut_host_safety_before" == "$_ut_host_safety_after" ]]; then
  pass "uninstall: isolated e2e cases leave host Claude and cc-safety-net unchanged"
else
  fail "uninstall: isolated e2e cases changed a host CLI"
fi

# The prompt must not become an unconditional cleanup_paths entry: those are
# deleted without asking, and the plugin outlives this uninstall.
if ! grep -A 20 'cleanup_paths_json()' "$PROJECT_DIR/lib/deploy.sh" | grep -q '/security"'; then
  pass "uninstall: plugin data dir stays out of cleanup_paths_json (prompted, not unconditional)"
else
  fail "uninstall: plugin data dir must not be added to cleanup_paths_json (it deletes unconditionally)"
fi

rm -rf "$_ut_tmp"
