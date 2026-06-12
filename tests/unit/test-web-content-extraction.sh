#!/bin/bash
# tests/unit/test-web-content-extraction.sh
# Unit tests for the web-content-extraction skill payload + web-content-update feature wiring.
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded, PROJECT_DIR set).
# These tests do NOT require network or installed npm deps; full `npm test` runs
# in the dedicated CI workflow (.github/workflows/skill-web-content-extraction.yml).

# Flags below are consumed indirectly by build_settings_file()/build_claude_md()
# via ${!var}, which ShellCheck cannot see.
# shellcheck disable=SC2034
WCE_DIR="$PROJECT_DIR/skills/web-content-extraction"

# Source dependencies explicitly (do not depend on prior test files).
# shellcheck source=lib/colors.sh
source "$PROJECT_DIR/lib/colors.sh"
# shellcheck source=lib/prerequisites.sh
source "$PROJECT_DIR/lib/prerequisites.sh"
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
# shellcheck source=lib/update.sh
source "$PROJECT_DIR/lib/update.sh"

# Reset every hook/feature flag to false so build_* output is deterministic
# regardless of flags leaked by previously sourced unit tests.
_wce_reset_flags() {
  local v
  for v in ENABLE_SAFETY_NET ENABLE_TMUX_HOOKS ENABLE_DOC_BLOCKER ENABLE_PRETTIER_HOOKS \
    ENABLE_BIOME_HOOKS ENABLE_CONSOLE_LOG_GUARD \
    ENABLE_PR_CREATION_LOG ENABLE_PRE_COMPACT_COMMIT ENABLE_AUTO_UPDATE ENABLE_WEB_CONTENT_UPDATE \
    ENABLE_STATUSLINE ENABLE_DOC_SIZE_GUARD ENABLE_NO_FLICKER ENABLE_FEATURE_RECOMMENDATION \
    ENABLE_GIT_PUSH_REVIEW ENABLE_CODEX_PLUGIN INSTALL_SKILLS; do
    printf -v "$v" '%s' "false"
  done
  LANGUAGE="en"; COMMIT_ATTRIBUTION="false"; ENABLE_NEW_INIT="true"; EDITOR_CHOICE="none"
}

_wce_tmp="$(mktemp -d)"

# --- 1. Skill payload files present in the repo ---
_wce_missing=""
for f in SKILL.md README.md package.json package-lock.json .gitignore \
  scripts/defuddle-url.mjs scripts/defuddle-file.mjs scripts/update-deps.mjs \
  scripts/lib/defuddle-core.mjs scripts/lib/url-guard.mjs scripts/lib/pdf-extract.mjs \
  test/url-guard.test.mjs test/defuddle-core.test.mjs test/extract-smoke.test.mjs; do
  [[ -f "$WCE_DIR/$f" ]] || _wce_missing="$_wce_missing $f"
done
if [[ -z "$_wce_missing" ]]; then
  pass "web-content-extraction: all skill payload files present"
else
  fail "web-content-extraction: missing payload files:$_wce_missing"
fi

# --- 2. Distribution hygiene: node_modules / logs not committed to git ---
# (They may exist on disk after a local `npm install`; the guard is that they
#  are git-ignored, never tracked.)
if command -v git >/dev/null 2>&1 && git -C "$PROJECT_DIR" rev-parse >/dev/null 2>&1; then
  _wce_tracked="$(git -C "$PROJECT_DIR" ls-files -- \
    skills/web-content-extraction/node_modules skills/web-content-extraction/logs 2>/dev/null || true)"
  if [[ -z "$_wce_tracked" ]]; then
    pass "web-content-extraction: node_modules/logs are not tracked by git"
  else
    fail "web-content-extraction: node_modules/ or logs/ must not be committed"
  fi
elif grep -q 'node_modules' "$WCE_DIR/.gitignore" 2>/dev/null \
  && grep -q 'logs' "$WCE_DIR/.gitignore" 2>/dev/null; then
  pass "web-content-extraction: .gitignore excludes node_modules/logs (no git context)"
else
  fail "web-content-extraction: skill .gitignore must exclude node_modules/logs"
fi

# --- 3. package.json declares deps + scripts ---
if assert_json_has_key "$WCE_DIR/package.json" '.dependencies.defuddle' \
  && assert_json_has_key "$WCE_DIR/package.json" '.dependencies.jsdom' \
  && assert_json_has_key "$WCE_DIR/package.json" '.dependencies["pdfjs-dist"]' \
  && assert_json_has_key "$WCE_DIR/package.json" '.dependencies.undici' \
  && assert_json_field "$WCE_DIR/package.json" '.scripts.test' 'node --test'; then
  pass "web-content-extraction: package.json declares deps and test script"
else
  fail "web-content-extraction: package.json missing expected deps/scripts"
fi

# --- 4. Feature registry wiring ---
if [[ "${_FEATURE_FLAGS[web-content-update]:-}" == "ENABLE_WEB_CONTENT_UPDATE" ]] \
  && [[ " ${_FEATURE_ORDER[*]} " == *" web-content-update "* ]] \
  && [[ -z "${_FEATURE_HAS_SCRIPTS[web-content-update]+set}" ]]; then
  pass "web-content-update: registered in _FEATURE_FLAGS/_FEATURE_ORDER, not in _FEATURE_HAS_SCRIPTS"
else
  fail "web-content-update: feature registry wiring incorrect"
fi

# --- 5. hooks.json registers async SessionStart calling update-deps.mjs ---
if jq -e '
  any(.hooks.SessionStart[]?.hooks[]?;
      .async == true and .asyncTimeout == 720000 and (.command | contains("update-deps.mjs"))) and
  ((.hooks.SessionEnd // []) | length == 0)
' "$PROJECT_DIR/features/web-content-update/hooks.json" >/dev/null 2>&1; then
  pass "web-content-update: hooks.json registers async SessionStart with sufficient timeout"
else
  fail "web-content-update: hooks.json should register async SessionStart with sufficient timeout"
fi

# --- 6. build_settings_file hook gating: present iff ENABLE_WEB_CONTENT_UPDATE=true AND INSTALL_SKILLS=true ---
_wce_hook() { jq -e '.. | objects | select(.command? != null) | select(.command | test("update-deps.mjs"))' "$1" >/dev/null 2>&1; }
_wce_reset_flags; INSTALL_SKILLS="true"; ENABLE_WEB_CONTENT_UPDATE="true"
build_settings_file "$_wce_tmp/settings-on.json" >/dev/null 2>&1 || true
_wce_reset_flags; INSTALL_SKILLS="true"; ENABLE_WEB_CONTENT_UPDATE="false"
build_settings_file "$_wce_tmp/settings-off.json" >/dev/null 2>&1 || true
_wce_reset_flags; INSTALL_SKILLS="false"; ENABLE_WEB_CONTENT_UPDATE="true"
build_settings_file "$_wce_tmp/settings-noskill.json" >/dev/null 2>&1 || true
if _wce_hook "$_wce_tmp/settings-on.json" \
  && ! _wce_hook "$_wce_tmp/settings-off.json" \
  && ! _wce_hook "$_wce_tmp/settings-noskill.json"; then
  pass "web-content-update: settings hook present only when enabled AND skill installed"
else
  fail "web-content-update: settings hook gating incorrect (enabled+skill / disabled / enabled-no-skill)"
fi

# --- 7. build_claude_md: rule injected iff INSTALL_SKILLS=true, no stray markers ---
_wce_reset_flags
INSTALL_SKILLS="true"
CLAUDE_DIR="$_wce_tmp/skills-on"; mkdir -p "$CLAUDE_DIR"
build_claude_md >/dev/null 2>&1 || true
_wce_reset_flags
INSTALL_SKILLS="false"
CLAUDE_DIR="$_wce_tmp/skills-off"; mkdir -p "$CLAUDE_DIR"
build_claude_md >/dev/null 2>&1 || true
if grep -q "web-content-extraction" "$_wce_tmp/skills-on/CLAUDE.md" \
  && ! grep -q "web-content-extraction" "$_wce_tmp/skills-off/CLAUDE.md" \
  && ! grep -q "{{FEATURE:" "$_wce_tmp/skills-on/CLAUDE.md" \
  && ! grep -q "{{FEATURE:" "$_wce_tmp/skills-off/CLAUDE.md"; then
  pass "web-content-extraction: CLAUDE.md rule gated on INSTALL_SKILLS, no stray markers"
else
  fail "web-content-extraction: CLAUDE.md rule gating/markers incorrect"
fi

# --- 8. Syntax check skill scripts when Node is available ---
if command -v node >/dev/null 2>&1; then
  _wce_check_ok=true
  for f in "$WCE_DIR"/scripts/*.mjs "$WCE_DIR"/scripts/lib/*.mjs; do
    node --check "$f" 2>/dev/null || _wce_check_ok=false
  done
  if [[ "$_wce_check_ok" == "true" ]]; then
    pass "web-content-extraction: node --check passes on all skill scripts"
  else
    fail "web-content-extraction: node --check failed on a skill script"
  fi
  if grep -q '.update-in-progress' "$WCE_DIR/scripts/update-deps.mjs" \
    && grep -q 'recoverInterruptedUpdate' "$WCE_DIR/scripts/update-deps.mjs"; then
    pass "web-content-update: interrupted updates rerun the test gate"
  else
    fail "web-content-update: interrupted update recovery is missing"
  fi
else
  skip "web-content-extraction: node --check" "node not available"
fi

# --- 9. Deploy/update hygiene excludes local dependency and log artifacts ---
_wce_dist_src="$_wce_tmp/dist-src"
_wce_dist_dest="$_wce_tmp/dist-dest"
mkdir -p "$_wce_dist_src/node_modules/pkg" "$_wce_dist_src/logs" "$_wce_dist_src/scripts"
printf 'real\n' > "$_wce_dist_src/scripts/defuddle-url.mjs"
printf 'dep\n' > "$_wce_dist_src/node_modules/pkg/index.js"
printf 'log\n' > "$_wce_dist_src/logs/update.log"
printf 'bak\n' > "$_wce_dist_src/package.json.bak"
_copy_distribution_tree "$_wce_dist_src" "$_wce_dist_dest" "overwrite"
if [[ -f "$_wce_dist_dest/scripts/defuddle-url.mjs" ]] \
  && [[ ! -e "$_wce_dist_dest/node_modules" ]] \
  && [[ ! -e "$_wce_dist_dest/logs" ]] \
  && [[ ! -e "$_wce_dist_dest/package.json.bak" ]]; then
  pass "web-content-extraction: deploy copy excludes node_modules/logs/*.bak"
else
  fail "web-content-extraction: deploy copy should exclude node_modules/logs/*.bak"
fi

_MANAGED_TARGET_FILES=()
_add_managed_tree_targets "$_wce_dist_src" "$_wce_dist_dest"
_wce_managed="$(printf '%s\n' "${_MANAGED_TARGET_FILES[@]+"${_MANAGED_TARGET_FILES[@]}"}")"
if [[ "$_wce_managed" == *"scripts/defuddle-url.mjs"* ]] \
  && [[ "$_wce_managed" != *"node_modules"* ]] \
  && [[ "$_wce_managed" != *"logs/"* ]] \
  && [[ "$_wce_managed" != *".bak"* ]]; then
  pass "web-content-extraction: manifest excludes node_modules/logs/*.bak"
else
  fail "web-content-extraction: manifest should exclude node_modules/logs/*.bak"
fi

if [[ "$(_count_update_files_in_dir "$_wce_dist_src")" == "1" ]]; then
  pass "web-content-extraction: update scan excludes node_modules/logs/*.bak"
else
  fail "web-content-extraction: update scan should exclude node_modules/logs/*.bak"
fi

# --- 10. Auto-managed package files do not trigger interactive merge conflicts ---
_wce_pkg_cur="$_wce_tmp/home/.claude/skills/web-content-extraction/package.json"
_wce_pkg_snap="$_wce_tmp/snapshot/skills/web-content-extraction/package.json"
_wce_pkg_new="$_wce_tmp/new/skills/web-content-extraction/package.json"
mkdir -p "$(dirname "$_wce_pkg_cur")" "$(dirname "$_wce_pkg_snap")" "$(dirname "$_wce_pkg_new")"
printf '{"dependencies":{"defuddle":"1.0.0"}}\n' > "$_wce_pkg_snap"
printf '{"dependencies":{"defuddle":"1.1.0"}}\n' > "$_wce_pkg_cur"
printf '{"dependencies":{"defuddle":"1.2.0"}}\n' > "$_wce_pkg_new"
_MERGE_INTERACTIVE="true"
if _update_file "$_wce_pkg_cur" "$_wce_pkg_snap" "$_wce_pkg_new" \
  && grep -q '1.1.0' "$_wce_pkg_cur"; then
  pass "web-content-extraction: auto-managed package conflict resolves without prompt"
else
  fail "web-content-extraction: auto-managed package conflict should keep runtime-updated package"
fi

rm -rf "$_wce_tmp"
unset WCE_DIR _wce_tmp _wce_missing _wce_check_ok _wce_tracked _wce_dist_src _wce_dist_dest _wce_managed _wce_pkg_cur _wce_pkg_snap _wce_pkg_new
