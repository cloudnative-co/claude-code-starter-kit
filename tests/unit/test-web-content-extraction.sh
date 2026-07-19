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
    ENABLE_BIOME_HOOKS \
    ENABLE_PR_CREATION_LOG ENABLE_PRE_COMPACT_COMMIT ENABLE_AUTO_UPDATE ENABLE_WEB_CONTENT_UPDATE \
    ENABLE_STATUSLINE ENABLE_DOC_SIZE_GUARD ENABLE_NO_FLICKER ENABLE_FEATURE_RECOMMENDATION \
    ENABLE_CODEX_PLUGIN INSTALL_SKILLS; do
    printf -v "$v" '%s' "false"
  done
  LANGUAGE="en"; COMMIT_ATTRIBUTION="false"; ENABLE_NEW_INIT="true"; EDITOR_CHOICE="none"
}

_wce_tmp="$(mktemp -d)"
_wce_tmp="$(builtin cd -P "$_wce_tmp" && pwd -P)"

# --- 1. Skill payload files present in the repo ---
_wce_missing=""
for f in SKILL.md README.md package.json package-lock.json .gitignore \
  scripts/run-node.sh scripts/defuddle-url.mjs scripts/defuddle-file.mjs \
  scripts/update-deps.mjs \
  scripts/lib/defuddle-core.mjs scripts/lib/url-guard.mjs scripts/lib/pdf-extract.mjs \
  test/url-guard.test.mjs test/defuddle-core.test.mjs test/extract-smoke.test.mjs; do
  [[ -f "$WCE_DIR/$f" ]] || _wce_missing="$_wce_missing $f"
done
if [[ -z "$_wce_missing" && -x "$WCE_DIR/scripts/run-node.sh" ]]; then
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

if grep -qF "const TARGETS = ['defuddle', 'jsdom', 'pdfjs-dist', 'undici']" \
  "$WCE_DIR/scripts/update-deps.mjs"; then
  pass "web-content-extraction: dependency updater covers every documented runtime dependency"
else
  fail "web-content-extraction: dependency updater omits a documented runtime dependency"
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
      .async == true and .asyncTimeout == 720000 and
      (.command | contains("scripts/run-node.sh")) and
      (.command | contains("update-deps.mjs"))) and
  ((.hooks.SessionEnd // []) | length == 0)
' "$PROJECT_DIR/features/web-content-update/hooks.json" >/dev/null 2>&1; then
  pass "web-content-update: hooks.json registers async SessionStart with sufficient timeout"
else
  fail "web-content-update: hooks.json should register async SessionStart with sufficient timeout"
fi

_wce_hook_command="$(jq -r '.hooks.SessionStart[0].hooks[0].command' \
  "$PROJECT_DIR/features/web-content-update/hooks.json")"
_wce_hook_home="$_wce_tmp/User Home'\$;semi\`tick\`"
mkdir -p "$_wce_hook_home/.claude/skills/web-content-extraction/scripts"
cat > "$_wce_hook_home/.claude/skills/web-content-extraction/scripts/run-node.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" > "$WCE_HOOK_QUOTE_LOG"
EOF
chmod +x "$_wce_hook_home/.claude/skills/web-content-extraction/scripts/run-node.sh"
: > "$_wce_hook_home/.claude/skills/web-content-extraction/scripts/update-deps.mjs"
export WCE_HOOK_QUOTE_LOG="$_wce_tmp/hook-quote.log"
_wce_hook_rc=0
HOME="$_wce_hook_home" /bin/sh -c "$_wce_hook_command" \
  >/dev/null 2>&1 || _wce_hook_rc=$?
if [[ "$_wce_hook_rc" -eq 0 \
  && "$(< "$WCE_HOOK_QUOTE_LOG")" \
    == "$_wce_hook_home/.claude/skills/web-content-extraction/scripts/update-deps.mjs" ]]; then
  pass "web-content-update: hook safely expands homes containing shell metacharacters"
else
  fail "web-content-update: hook command does not quote the target home safely"
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


# --- spec-kit partial: gated on INSTALL_COMMANDS (mirror of the wce gate) ---
_wce_reset_flags
INSTALL_COMMANDS="true"
CLAUDE_DIR="$_wce_tmp/cmds-on"; mkdir -p "$CLAUDE_DIR"
build_claude_md >/dev/null 2>&1 || true
_wce_reset_flags
INSTALL_COMMANDS="false"
CLAUDE_DIR="$_wce_tmp/cmds-off"; mkdir -p "$CLAUDE_DIR"
build_claude_md >/dev/null 2>&1 || true
if grep -q "spec-kit-init" "$_wce_tmp/cmds-on/CLAUDE.md" \
  && ! grep -q "spec-kit-init" "$_wce_tmp/cmds-off/CLAUDE.md" \
  && ! grep -q "{{FEATURE:" "$_wce_tmp/cmds-on/CLAUDE.md" \
  && ! grep -q "{{FEATURE:" "$_wce_tmp/cmds-off/CLAUDE.md"; then
  pass "spec-kit: CLAUDE.md pointer gated on INSTALL_COMMANDS, no stray markers"
else
  fail "spec-kit: CLAUDE.md pointer gating/markers incorrect"
fi

# --- 8. Syntax check skill scripts when Node is available ---
bash -n "$WCE_DIR/scripts/run-node.sh" 2>/dev/null
if [[ "$?" -eq 0 ]] \
  && ! grep -ERq \
    'node[[:space:]]+(~|__HOME__)/\.claude/skills/web-content-extraction/' \
    "$WCE_DIR/SKILL.md" "$WCE_DIR/README.md" \
    "$PROJECT_DIR/commands" "$PROJECT_DIR/features"; then
  pass "web-content-extraction: documented executions use the runtime wrapper"
else
  fail "web-content-extraction: runtime wrapper is invalid or bypassed in SKILL.md"
fi

_wce_wrapper="$WCE_DIR/scripts/run-node.sh"
_wce_run_tmp="$_wce_tmp/runtime-wrapper"
_wce_managed_root="$_wce_run_tmp/managed-root"
_wce_runtime_root="$_wce_managed_root/runtime"
_wce_receipt="$_wce_managed_root/receipt-managed-user.json"
_wce_expected_node="$_wce_runtime_root/node-v24.18.0-darwin-arm64/bin/node"
_wce_node_link="$_wce_run_tmp/home/.local/bin/node"
mkdir -p "${_wce_expected_node%/*}" "${_wce_node_link%/*}" "$_wce_run_tmp/path"
: > "$_wce_receipt"
cat > "$_wce_expected_node" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$WCE_MANAGED_NODE_LOG"
printf '%s\n' "$0" > "$WCE_MANAGED_NODE_ARGV0"
printf '%s|%s\n' "${NODE_OPTIONS-unset}" "${NODE_PATH-unset}" \
  > "$WCE_MANAGED_NODE_ENV"
EOF
cat > "$_wce_run_tmp/path/node" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$WCE_FALLBACK_NODE_LOG"
EOF
chmod +x "$_wce_expected_node" "$_wce_run_tmp/path/node"
ln -s "$_wce_expected_node" "$_wce_node_link"
export WCE_MANAGED_NODE_LOG="$_wce_run_tmp/managed.log"
export WCE_MANAGED_NODE_ARGV0="$_wce_run_tmp/managed.argv0"
export WCE_MANAGED_NODE_ENV="$_wce_run_tmp/managed.env"
export WCE_FALLBACK_NODE_LOG="$_wce_run_tmp/fallback.log"
export NODE_OPTIONS="--require=$_wce_run_tmp/hostile-preload.cjs"
export NODE_PATH="$_wce_run_tmp/hostile-modules"
_wce_wrapper_rc=0
(
  # shellcheck source=/dev/null
  source "$_wce_wrapper"
  PATH="$_wce_run_tmp/path:/usr/bin:/bin" \
    _ccsk_wce_run true "$_wce_runtime_root" \
      "$_wce_node_link" "$_wce_expected_node" "$_wce_wrapper" \
      --check managed.mjs
) >/dev/null 2>&1 || _wce_wrapper_rc=$?
if [[ "$_wce_wrapper_rc" -eq 0 ]] \
  && [[ "$(< "$WCE_MANAGED_NODE_LOG")" == "--check managed.mjs" ]] \
  && [[ "$(< "$WCE_MANAGED_NODE_ARGV0")" == "$_wce_expected_node" ]] \
  && [[ "$(< "$WCE_MANAGED_NODE_ENV")" == "unset|unset" ]] \
  && [[ ! -e "$WCE_FALLBACK_NODE_LOG" ]]; then
  pass "web-content-extraction: managed marker pins the exact Node activation"
else
  fail "web-content-extraction: managed execution did not use the exact Node activation"
fi

rm -f "$_wce_node_link" "$WCE_MANAGED_NODE_LOG"
ln -s "$_wce_run_tmp/path/node" "$_wce_node_link"
_wce_wrapper_rc=0
(
  # shellcheck source=/dev/null
  source "$_wce_wrapper"
  PATH="$_wce_run_tmp/path:/usr/bin:/bin" \
    _ccsk_wce_run true "$_wce_runtime_root" \
      "$_wce_node_link" "$_wce_expected_node" "$_wce_wrapper" bad.mjs
) >/dev/null 2>&1 || _wce_wrapper_rc=$?
if [[ "$_wce_wrapper_rc" -ne 0 && ! -e "$WCE_FALLBACK_NODE_LOG" ]]; then
  pass "web-content-extraction: malformed managed activation fails closed"
else
  fail "web-content-extraction: malformed managed activation reached PATH"
fi

rm -rf "$_wce_managed_root"
_wce_wrapper_rc=0
(
  # shellcheck source=/dev/null
  source "$_wce_wrapper"
  PATH="$_wce_run_tmp/path:/usr/bin:/bin" \
    _ccsk_wce_run false "$_wce_runtime_root" \
      "$_wce_node_link" "" "$_wce_wrapper" normal.mjs
) >/dev/null 2>&1 || _wce_wrapper_rc=$?
if [[ "$_wce_wrapper_rc" -eq 0 \
  && "$(< "$WCE_FALLBACK_NODE_LOG")" == "normal.mjs" ]]; then
  pass "web-content-extraction: non-MDM execution retains PATH Node fallback"
else
  fail "web-content-extraction: non-MDM Node fallback was broken"
fi

mkdir -p "$_wce_runtime_root"
rm -f "$WCE_FALLBACK_NODE_LOG" "$_wce_node_link"
_wce_other_receipt="$_wce_managed_root/receipt-other-user.json"
: > "$_wce_other_receipt"
_wce_marker_rc=0
(
  # shellcheck source=/dev/null
  source "$_wce_wrapper"
  _ccsk_wce_managed_marker \
    "$_wce_managed_root/receipt-current-user.json" \
    "$_wce_runtime_root" "$_wce_node_link"
) >/dev/null 2>&1 || _wce_marker_rc=$?
_wce_wrapper_rc=0
(
  # shellcheck source=/dev/null
  source "$_wce_wrapper"
  PATH="$_wce_run_tmp/path:/usr/bin:/bin" \
    _ccsk_wce_run false "$_wce_runtime_root" "$_wce_node_link" \
      "" "$_wce_wrapper" multi-user.mjs
) >/dev/null 2>&1 || _wce_wrapper_rc=$?
if [[ "$_wce_marker_rc" -ne 0 && "$_wce_wrapper_rc" -eq 0 \
  && "$(< "$WCE_FALLBACK_NODE_LOG")" == "multi-user.mjs" ]]; then
  pass "web-content-extraction: another user's MDM runtime does not disable PATH fallback"
else
  fail "web-content-extraction: global MDM state leaked across local users"
fi

_wce_current_receipt="$_wce_managed_root/receipt-current-user.json"
: > "$_wce_current_receipt"
_wce_marker_rc=0
(
  # shellcheck source=/dev/null
  source "$_wce_wrapper"
  _ccsk_wce_managed_marker \
    "$_wce_current_receipt" "$_wce_runtime_root" "$_wce_node_link"
) >/dev/null 2>&1 || _wce_marker_rc=$?
if [[ "$_wce_marker_rc" -eq 0 ]]; then
  pass "web-content-extraction: current user's root receipt is a managed marker"
else
  fail "web-content-extraction: current user's authoritative receipt was ignored"
fi
unset WCE_MANAGED_NODE_LOG WCE_MANAGED_NODE_ARGV0 WCE_MANAGED_NODE_ENV \
  WCE_HOOK_QUOTE_LOG \
  WCE_FALLBACK_NODE_LOG NODE_OPTIONS NODE_PATH

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

  _wce_mdm_home="$_wce_tmp/mdm-home"
  _wce_mdm_skill="$_wce_mdm_home/.claude/skills/web-content-extraction"
  _wce_mdm_bin="$_wce_tmp/mdm-bin"
  mkdir -p "$_wce_mdm_skill/scripts" "$_wce_mdm_bin"
  cp "$WCE_DIR/scripts/update-deps.mjs" "$_wce_mdm_skill/scripts/update-deps.mjs"
  printf '{"version":"2","mdm_managed":true}\n' \
    > "$_wce_mdm_home/.claude/.starter-kit-manifest.json"
  printf '%s\n' \
    '#!/bin/sh' \
    ": > \"$_wce_tmp/mdm-npm-called\"" \
    'exit 99' \
    > "$_wce_mdm_bin/npm"
  chmod +x "$_wce_mdm_bin/npm"
  _wce_node="$(command -v node)"
  _wce_mdm_rc=0
  PATH="$_wce_mdm_bin:/usr/bin:/bin" \
    "$_wce_node" "$_wce_mdm_skill/scripts/update-deps.mjs" --force \
    >/dev/null 2>&1 || _wce_mdm_rc=$?
  if [[ "$_wce_mdm_rc" -eq 0 && ! -e "$_wce_tmp/mdm-npm-called" ]] \
    && grep -q 'pinned by MDM expected state' \
      "$_wce_mdm_skill/logs/update.log"; then
    pass "web-content-update: MDM expected state では package mutation をスキップ"
  else
    fail "web-content-update: MDM managed package を runtime 更新し得る"
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

# --- 10. Auto-managed package files merge runtime versions with kit structure ---
_wce_pkg_cur="$_wce_tmp/home/.claude/skills/web-content-extraction/package.json"
_wce_pkg_snap="$_wce_tmp/snapshot/skills/web-content-extraction/package.json"
_wce_pkg_new="$_wce_tmp/new/skills/web-content-extraction/package.json"
mkdir -p "$(dirname "$_wce_pkg_cur")" "$(dirname "$_wce_pkg_snap")" "$(dirname "$_wce_pkg_new")"
printf '{"engines":{"node":">=18"},"dependencies":{"defuddle":"1.0.0"}}\n' > "$_wce_pkg_snap"
printf '{"engines":{"node":">=18"},"dependencies":{"defuddle":"1.1.0"}}\n' > "$_wce_pkg_cur"
printf '{"scripts":{"test":"node --test"},"engines":{"node":">=22.19.0"},"dependencies":{"defuddle":"1.2.0"}}\n' > "$_wce_pkg_new"
_MERGE_INTERACTIVE="true"
if _update_file "$_wce_pkg_cur" "$_wce_pkg_snap" "$_wce_pkg_new" \
  && [[ "$(jq -r '.dependencies.defuddle' "$_wce_pkg_cur")" == "1.1.0" ]] \
  && [[ "$(jq -r '.engines.node' "$_wce_pkg_cur")" == ">=22.19.0" ]] \
  && [[ "$(jq -r '.scripts.test' "$_wce_pkg_cur")" == "node --test" ]]; then
  pass "web-content-extraction: runtime dependency versions merge with kit package structure"
else
  fail "web-content-extraction: package merge lost runtime versions or kit structure"
fi

_wce_lock_cur="$_wce_tmp/home/.claude/skills/web-content-extraction/package-lock.json"
_wce_lock_snap="$_wce_tmp/snapshot/skills/web-content-extraction/package-lock.json"
_wce_lock_new="$_wce_tmp/new/skills/web-content-extraction/package-lock.json"
printf '{"name":"old","lockfileVersion":3,"requires":true,"packages":{"":{"engines":{"node":">=18"},"dependencies":{"defuddle":"1.0.0"}},"node_modules/defuddle":{"version":"1.0.0"}}}\n' > "$_wce_lock_snap"
printf '{"name":"old","lockfileVersion":3,"requires":true,"packages":{"":{"engines":{"node":">=18"},"dependencies":{"defuddle":"1.1.0"}},"node_modules/defuddle":{"version":"1.1.0"}}}\n' > "$_wce_lock_cur"
printf '{"name":"web-content-extraction","lockfileVersion":3,"requires":true,"packages":{"":{"engines":{"node":">=22.19.0"},"dependencies":{"defuddle":"1.2.0"}},"node_modules/defuddle":{"version":"1.2.0"}}}\n' > "$_wce_lock_new"
if _update_file "$_wce_lock_cur" "$_wce_lock_snap" "$_wce_lock_new" \
  && [[ "$(jq -r '.name' "$_wce_lock_cur")" == "web-content-extraction" ]] \
  && [[ "$(jq -r '.packages[""].engines.node' "$_wce_lock_cur")" == ">=22.19.0" ]] \
  && [[ "$(jq -r '.packages[""].dependencies.defuddle' "$_wce_lock_cur")" == "1.1.0" ]] \
  && [[ "$(jq -r '.packages["node_modules/defuddle"].version' "$_wce_lock_cur")" == "1.1.0" ]]; then
  pass "web-content-extraction: runtime lock graph merges with kit root metadata"
else
  fail "web-content-extraction: lock merge lost runtime graph or kit metadata"
fi

# A new direct dependency is structural, not a runtime version update. Keeping
# the old package/lock pair here would make npm ci succeed without the new
# module and the shipped extractor would fail only when it imports that module.
_wce_added_root="$_wce_tmp/added-dependency"
_wce_added_cur="$_wce_added_root/home/.claude/skills/web-content-extraction"
_wce_added_snap="$_wce_added_root/snapshot/skills/web-content-extraction"
_wce_added_new="$_wce_added_root/new/skills/web-content-extraction"
mkdir -p "$_wce_added_cur" "$_wce_added_snap" "$_wce_added_new"
printf '{"dependencies":{"defuddle":"1.0.0"}}\n' > "$_wce_added_snap/package.json"
printf '{"dependencies":{"defuddle":"1.1.0"}}\n' > "$_wce_added_cur/package.json"
printf '{"dependencies":{"defuddle":"1.2.0","undici":"8.7.0"}}\n' > "$_wce_added_new/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"defuddle":"1.0.0"}},"node_modules/defuddle":{"version":"1.0.0"}}}\n' > "$_wce_added_snap/package-lock.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"defuddle":"1.1.0"}},"node_modules/defuddle":{"version":"1.1.0"}}}\n' > "$_wce_added_cur/package-lock.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"defuddle":"1.2.0","undici":"8.7.0"}},"node_modules/defuddle":{"version":"1.2.0"},"node_modules/undici":{"version":"8.7.0"}}}\n' > "$_wce_added_new/package-lock.json"
if _update_auto_managed_wce_package_pair \
    "$_wce_added_cur" "$_wce_added_snap" "$_wce_added_new" \
  && cmp -s "$_wce_added_cur/package.json" "$_wce_added_new/package.json" \
  && cmp -s "$_wce_added_cur/package-lock.json" "$_wce_added_new/package-lock.json"; then
  pass "web-content-extraction: added direct dependency resets package and lock together"
else
  fail "web-content-extraction: added direct dependency did not converge package and lock"
fi

_SNAPSHOT_BOOTSTRAPPED="true"
cp "$_wce_added_cur/package.json" "$_wce_added_snap/package.json"
printf '{"dependencies":{"defuddle":"1.3.0","undici":"8.7.0","jsdom":"29.1.1"}}\n' \
  > "$_wce_added_new/package.json"
if _update_file "$_wce_added_cur/package.json" "$_wce_added_snap/package.json" \
    "$_wce_added_new/package.json" \
  && cmp -s "$_wce_added_cur/package.json" "$_wce_added_new/package.json"; then
  pass "web-content-extraction: bootstrapped snapshot adopts a new direct dependency"
else
  fail "web-content-extraction: bootstrapped snapshot hid a new direct dependency"
fi
_SNAPSHOT_BOOTSTRAPPED="false"

printf '{"dependencies":' > "$_wce_added_cur/package.json"
_wce_invalid_rc=0
_update_file "$_wce_added_cur/package.json" "$_wce_added_snap/package.json" \
  "$_wce_added_new/package.json" >/dev/null 2>&1 || _wce_invalid_rc=$?
if [[ "$_wce_invalid_rc" == "0" ]] \
  && cmp -s "$_wce_added_cur/package.json" "$_wce_added_new/package.json"; then
  pass "web-content-extraction: malformed runtime package repairs to the kit version"
else
  fail "web-content-extraction: malformed runtime package did not recover"
fi

# Structural ownership is measured against the last kit snapshot, not against
# current alone. If current happened to add the same key before the kit did,
# the kit addition must still reset both files to its canonical versions.
_wce_snapshot_root="$_wce_tmp/snapshot-structure"
_wce_snapshot_cur="$_wce_snapshot_root/home/.claude/skills/web-content-extraction"
_wce_snapshot_snap="$_wce_snapshot_root/snapshot/skills/web-content-extraction"
_wce_snapshot_new="$_wce_snapshot_root/new/skills/web-content-extraction"
mkdir -p "$_wce_snapshot_cur" "$_wce_snapshot_snap" "$_wce_snapshot_new"
printf '{"dependencies":{"a":"1.0.0"}}\n' > "$_wce_snapshot_snap/package.json"
printf '{"dependencies":{"a":"1.1.0","b":"9.0.0"}}\n' > "$_wce_snapshot_cur/package.json"
printf '{"dependencies":{"a":"1.2.0","b":"2.0.0"}}\n' > "$_wce_snapshot_new/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"1.0.0"}},"node_modules/a":{"version":"1.0.0"}}}\n' > "$_wce_snapshot_snap/package-lock.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"1.1.0","b":"9.0.0"}},"node_modules/a":{"version":"1.1.0"},"node_modules/b":{"version":"9.0.0"}}}\n' > "$_wce_snapshot_cur/package-lock.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"1.2.0","b":"2.0.0"}},"node_modules/a":{"version":"1.2.0"},"node_modules/b":{"version":"2.0.0"}}}\n' > "$_wce_snapshot_new/package-lock.json"
if _update_auto_managed_wce_package_pair \
    "$_wce_snapshot_cur" "$_wce_snapshot_snap" "$_wce_snapshot_new" \
  && cmp -s "$_wce_snapshot_cur/package.json" "$_wce_snapshot_new/package.json" \
  && cmp -s "$_wce_snapshot_cur/package-lock.json" "$_wce_snapshot_new/package-lock.json"; then
  pass "web-content-extraction: kit dependency addition is measured from snapshot"
else
  fail "web-content-extraction: current keys hid a structural kit change"
fi

# A user-added direct dependency is also structural even when the kit itself is
# unchanged. Auto-managed manifests must converge back to the exact kit key set
# instead of retaining a package that the shipped lockfile does not authorize.
printf '{"dependencies":{"a":"1.0.0"}}\n' > "$_wce_snapshot_snap/package.json"
cp "$_wce_snapshot_snap/package.json" "$_wce_snapshot_new/package.json"
printf '{"dependencies":{"a":"1.1.0","user-extra":"9.0.0"}}\n' \
  > "$_wce_snapshot_cur/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"1.0.0"}},"node_modules/a":{"version":"1.0.0"}}}\n' \
  > "$_wce_snapshot_snap/package-lock.json"
cp "$_wce_snapshot_snap/package-lock.json" \
  "$_wce_snapshot_new/package-lock.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"1.1.0","user-extra":"9.0.0"}},"node_modules/a":{"version":"1.1.0"},"node_modules/user-extra":{"version":"9.0.0"}}}\n' \
  > "$_wce_snapshot_cur/package-lock.json"
if _update_auto_managed_wce_package_pair \
    "$_wce_snapshot_cur" "$_wce_snapshot_snap" "$_wce_snapshot_new" \
  && cmp -s "$_wce_snapshot_cur/package.json" "$_wce_snapshot_new/package.json" \
  && cmp -s "$_wce_snapshot_cur/package-lock.json" "$_wce_snapshot_new/package-lock.json"; then
  pass "web-content-extraction: unchanged kit removes an extra direct dependency"
else
  fail "web-content-extraction: unchanged kit retained an unauthorized dependency"
fi

_wce_phase_root="$_wce_tmp/content-phase-pair"
_wce_phase_project="$_wce_phase_root/project"
_wce_phase_current="$_wce_phase_root/home/.claude"
_wce_phase_snapshot="$_wce_phase_root/snapshot"
mkdir -p "$_wce_phase_project/skills/web-content-extraction" \
  "$_wce_phase_current/skills/web-content-extraction" \
  "$_wce_phase_snapshot/skills/web-content-extraction"
cp "$_wce_snapshot_snap/package.json" \
  "$_wce_phase_snapshot/skills/web-content-extraction/package.json"
cp "$_wce_snapshot_snap/package-lock.json" \
  "$_wce_phase_snapshot/skills/web-content-extraction/package-lock.json"
cp "$_wce_snapshot_cur/package.json" \
  "$_wce_phase_current/skills/web-content-extraction/package.json"
cp "$_wce_snapshot_cur/package-lock.json" \
  "$_wce_phase_current/skills/web-content-extraction/package-lock.json"
cp "$_wce_snapshot_new/package.json" \
  "$_wce_phase_project/skills/web-content-extraction/package.json"
cp "$_wce_snapshot_new/package-lock.json" \
  "$_wce_phase_project/skills/web-content-extraction/package-lock.json"
_wce_phase_rc=0
(
  PROJECT_DIR="$_wce_phase_project"
  INSTALL_AGENTS=false INSTALL_RULES=false INSTALL_COMMANDS=false
  INSTALL_SKILLS=true KIT_MDM_MANAGED=false
  _UPDATE_ALL_UPDATED_FILES=(); _UPDATE_ALL_SKIPPED_FILES=()
  _progress_step() { :; }; _progress_tick() { :; }
  _update_phase_content "$PROJECT_DIR" \
    "$_wce_phase_current" "$_wce_phase_snapshot"
) >/dev/null 2>&1 || _wce_phase_rc=$?
if [[ "$_wce_phase_rc" == "0" ]] \
  && cmp -s "$_wce_phase_current/skills/web-content-extraction/package.json" \
    "$_wce_phase_project/skills/web-content-extraction/package.json" \
  && cmp -s "$_wce_phase_current/skills/web-content-extraction/package-lock.json" \
    "$_wce_phase_project/skills/web-content-extraction/package-lock.json"; then
  pass "web-content-extraction: content update phase commits the package pair together"
else
  fail "web-content-extraction: content update phase bypassed the package-pair transaction"
fi

# Dependency versions and the resolved lock graph are runtime-owned, but
# scripts/engines and other root metadata remain kit-owned even when the kit's
# direct dependency key set is unchanged.
_wce_metadata_root="$_wce_tmp/package-metadata-drift"
_wce_metadata_cur="$_wce_metadata_root/home/.claude/skills/web-content-extraction"
_wce_metadata_snap="$_wce_metadata_root/snapshot/skills/web-content-extraction"
_wce_metadata_new="$_wce_metadata_root/new/skills/web-content-extraction"
mkdir -p "$_wce_metadata_cur" "$_wce_metadata_snap" "$_wce_metadata_new"
printf '{"scripts":{"test":"kit-test"},"dependencies":{"a":"1.0.0"}}\n' \
  > "$_wce_metadata_snap/package.json"
cp "$_wce_metadata_snap/package.json" "$_wce_metadata_new/package.json"
printf '{"scripts":{"test":"user-test"},"dependencies":{"a":"1.1.0"}}\n' \
  > "$_wce_metadata_cur/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"scripts":{"test":"kit-test"},"dependencies":{"a":"1.0.0"}},"node_modules/a":{"version":"1.0.0"}}}\n' \
  > "$_wce_metadata_snap/package-lock.json"
cp "$_wce_metadata_snap/package-lock.json" \
  "$_wce_metadata_new/package-lock.json"
printf '{"lockfileVersion":3,"packages":{"":{"scripts":{"test":"user-test"},"dependencies":{"a":"1.1.0"}},"node_modules/a":{"version":"1.1.0"}}}\n' \
  > "$_wce_metadata_cur/package-lock.json"
_wce_metadata_rc=0
_update_auto_managed_wce_package_pair \
  "$_wce_metadata_cur" "$_wce_metadata_snap" "$_wce_metadata_new" \
  >/dev/null 2>&1 || _wce_metadata_rc=$?
if [[ "$_wce_metadata_rc" == "0" ]] \
  && [[ "$(jq -r '.scripts.test' "$_wce_metadata_cur/package.json")" \
    == kit-test ]] \
  && [[ "$(jq -r '.dependencies.a' "$_wce_metadata_cur/package.json")" \
    == 1.1.0 ]] \
  && [[ "$(jq -r '.packages[""].scripts.test' \
    "$_wce_metadata_cur/package-lock.json")" == kit-test ]] \
  && [[ "$(jq -r '.packages["node_modules/a"].version' \
    "$_wce_metadata_cur/package-lock.json")" == 1.1.0 ]]; then
  pass "web-content-extraction: unchanged dependency keys repair kit metadata drift"
else
  fail "web-content-extraction: unchanged dependency keys retained user metadata drift"
fi

# An exact desired pair is not a user-conflict skip. The phase should report
# neither updated nor skipped files, avoiding a warning on every idempotent run.
_wce_noop_root="$_wce_tmp/package-pair-noop"
_wce_noop_project="$_wce_noop_root/project"
_wce_noop_current="$_wce_noop_root/home/.claude"
_wce_noop_snapshot="$_wce_noop_root/snapshot"
mkdir -p "$_wce_noop_project/skills/web-content-extraction" \
  "$_wce_noop_current/skills/web-content-extraction" \
  "$_wce_noop_snapshot/skills/web-content-extraction"
for _wce_noop_file in package.json package-lock.json; do
  cp "$_wce_metadata_new/$_wce_noop_file" \
    "$_wce_noop_project/skills/web-content-extraction/$_wce_noop_file"
  cp "$_wce_metadata_new/$_wce_noop_file" \
    "$_wce_noop_current/skills/web-content-extraction/$_wce_noop_file"
  cp "$_wce_metadata_new/$_wce_noop_file" \
    "$_wce_noop_snapshot/skills/web-content-extraction/$_wce_noop_file"
done
_wce_noop_result="$_wce_noop_root/result"
_wce_noop_rc=0
(
  PROJECT_DIR="$_wce_noop_project"
  INSTALL_AGENTS=false INSTALL_RULES=false INSTALL_COMMANDS=false
  INSTALL_SKILLS=true KIT_MDM_MANAGED=false
  _UPDATE_ALL_UPDATED_FILES=(); _UPDATE_ALL_SKIPPED_FILES=()
  _progress_step() { :; }; _progress_tick() { :; }
  _update_phase_content "$PROJECT_DIR" \
    "$_wce_noop_current" "$_wce_noop_snapshot"
  printf '%s:%s\n' "${#_UPDATE_ALL_UPDATED_FILES[@]}" \
    "${#_UPDATE_ALL_SKIPPED_FILES[@]}" > "$_wce_noop_result"
) >/dev/null 2>&1 || _wce_noop_rc=$?
if [[ "$_wce_noop_rc" == "0" \
  && "$(< "$_wce_noop_result")" == "0:0" ]]; then
  pass "web-content-extraction: exact package pair is a no-op without a skip warning"
else
  fail "web-content-extraction: exact package pair produced a false skip warning"
fi

# Current may already equal the kit while its baseline is missing or corrupt.
# Mark that as a managed refresh so phase 5 repairs the kit baseline; otherwise
# a later runtime version update would be mistaken for baseline corruption and
# reset to the pinned kit versions.
_wce_baseline_root="$_wce_tmp/package-pair-baseline-repair"
_wce_baseline_project="$_wce_baseline_root/project"
_wce_baseline_current="$_wce_baseline_root/home/.claude"
_wce_baseline_snapshot="$_wce_baseline_root/snapshot"
mkdir -p "$_wce_baseline_project/skills/web-content-extraction" \
  "$_wce_baseline_current/skills/web-content-extraction" \
  "$_wce_baseline_snapshot/skills/web-content-extraction"
for _wce_baseline_file in package.json package-lock.json; do
  cp "$_wce_metadata_new/$_wce_baseline_file" \
    "$_wce_baseline_project/skills/web-content-extraction/$_wce_baseline_file"
  cp "$_wce_metadata_new/$_wce_baseline_file" \
    "$_wce_baseline_current/skills/web-content-extraction/$_wce_baseline_file"
done
printf '{"dependencies":' \
  > "$_wce_baseline_snapshot/skills/web-content-extraction/package.json"
cp "$_wce_metadata_new/package-lock.json" \
  "$_wce_baseline_snapshot/skills/web-content-extraction/package-lock.json"
_wce_baseline_rc=0
(
  PROJECT_DIR="$_wce_baseline_project"
  INSTALL_AGENTS=false INSTALL_RULES=false INSTALL_COMMANDS=false
  INSTALL_SKILLS=true KIT_MDM_MANAGED=false DRY_RUN=false
  STR_UPDATE_SNAPSHOT=snapshot STR_UPDATE_SNAPSHOT_DONE="done"
  _UPDATE_ALL_UPDATED_FILES=(); _UPDATE_ALL_SKIPPED_FILES=()
  _progress_step() { :; }; _progress_tick() { :; }
  _update_phase_content "$PROJECT_DIR" \
    "$_wce_baseline_current" "$_wce_baseline_snapshot"
  [[ "${#_UPDATE_ALL_UPDATED_FILES[@]}" -eq 2 ]]
  _update_phase_snapshot \
    "$_wce_baseline_current" "$_wce_baseline_snapshot"
) >/dev/null 2>&1 || _wce_baseline_rc=$?
_wce_baseline_skill="$_wce_baseline_current/skills/web-content-extraction"
_wce_baseline_snap_skill="$_wce_baseline_snapshot/skills/web-content-extraction"
_wce_baseline_new_skill="$_wce_baseline_project/skills/web-content-extraction"
printf '{"scripts":{"test":"kit-test"},"dependencies":{"a":"9.0.0"}}\n' \
  > "$_wce_baseline_skill/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"scripts":{"test":"kit-test"},"dependencies":{"a":"9.0.0"}},"node_modules/a":{"version":"9.0.0"}}}\n' \
  > "$_wce_baseline_skill/package-lock.json"
_wce_baseline_followup_rc=0
_update_auto_managed_wce_package_pair \
  "$_wce_baseline_skill" "$_wce_baseline_snap_skill" \
  "$_wce_baseline_new_skill" >/dev/null 2>&1 \
  || _wce_baseline_followup_rc=$?
if [[ "$_wce_baseline_rc" == "0" \
  && "$_wce_baseline_followup_rc" -le 1 ]] \
  && cmp -s "$_wce_baseline_snap_skill/package.json" \
    "$_wce_baseline_new_skill/package.json" \
  && cmp -s "$_wce_baseline_snap_skill/package-lock.json" \
    "$_wce_baseline_new_skill/package-lock.json" \
  && [[ "$(jq -r '.dependencies.a' \
    "$_wce_baseline_skill/package.json")" == 9.0.0 ]] \
  && [[ "$(jq -r '.packages[""].dependencies.a' \
    "$_wce_baseline_skill/package-lock.json")" == 9.0.0 ]]; then
  pass "web-content-extraction: invalid baseline refresh preserves later runtime versions"
else
  fail "web-content-extraction: invalid baseline caused a later runtime version rollback"
fi

# A failure on the second rename must put the first file back byte-for-byte.
cp "$_wce_snapshot_new/package.json" "$_wce_snapshot_root/package.saved"
cp "$_wce_snapshot_new/package-lock.json" "$_wce_snapshot_root/lock.saved"
printf '{"dependencies":{"a":"1.3.0","b":"2.0.0","c":"3.0.0"}}\n' \
  > "$_wce_snapshot_new/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"1.3.0","b":"2.0.0","c":"3.0.0"}},"node_modules/a":{"version":"1.3.0"},"node_modules/b":{"version":"2.0.0"},"node_modules/c":{"version":"3.0.0"}}}\n' \
  > "$_wce_snapshot_new/package-lock.json"
_wce_pair_mv_original="$(declare -f _wce_package_pair_mv)"
_wce_package_pair_mv() {
  case "$1" in
    *package-lock.json.stage.*) return 1 ;;
    *) mv -f "$1" "$2" ;;
  esac
}
_wce_pair_rc=0
_update_auto_managed_wce_package_pair \
  "$_wce_snapshot_cur" "$_wce_snapshot_snap" "$_wce_snapshot_new" \
  >/dev/null 2>&1 || _wce_pair_rc=$?
eval "$_wce_pair_mv_original"
if [[ "$_wce_pair_rc" == "2" ]] \
  && cmp -s "$_wce_snapshot_cur/package.json" "$_wce_snapshot_root/package.saved" \
  && cmp -s "$_wce_snapshot_cur/package-lock.json" "$_wce_snapshot_root/lock.saved" \
  && ! compgen -G "$_wce_snapshot_cur/*.stage.*" >/dev/null \
  && ! compgen -G "$_wce_snapshot_cur/*.backup.*" >/dev/null; then
  pass "web-content-extraction: pair commit failure rolls both files back"
else
  fail "web-content-extraction: pair commit failure left mismatched files or residue"
fi

# The package and lock roots must agree on complete dependency specifications,
# not just names. A kit pair with the same key but a different range is invalid
# and must leave the installed pair byte-for-byte unchanged.
_wce_range_root="$_wce_tmp/mismatched-root-range"
_wce_range_cur="$_wce_range_root/home/.claude/skills/web-content-extraction"
_wce_range_snap="$_wce_range_root/snapshot/skills/web-content-extraction"
_wce_range_new="$_wce_range_root/new/skills/web-content-extraction"
mkdir -p "$_wce_range_cur" "$_wce_range_snap" "$_wce_range_new"
printf '{"dependencies":{"a":"1.1.0"}}\n' > "$_wce_range_cur/package.json"
printf '{"dependencies":{"a":"1.0.0"}}\n' > "$_wce_range_snap/package.json"
printf '{"dependencies":{"a":"2.0.0"}}\n' > "$_wce_range_new/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"1.1.0"}},"node_modules/a":{"version":"1.1.0"}}}\n' \
  > "$_wce_range_cur/package-lock.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"1.0.0"}},"node_modules/a":{"version":"1.0.0"}}}\n' \
  > "$_wce_range_snap/package-lock.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"9.0.0"}},"node_modules/a":{"version":"2.0.0"}}}\n' \
  > "$_wce_range_new/package-lock.json"
cp "$_wce_range_cur/package.json" "$_wce_range_root/package.saved"
cp "$_wce_range_cur/package-lock.json" "$_wce_range_root/lock.saved"
_wce_range_rc=0
_update_auto_managed_wce_package_pair \
  "$_wce_range_cur" "$_wce_range_snap" "$_wce_range_new" \
  >/dev/null 2>&1 || _wce_range_rc=$?
if [[ "$_wce_range_rc" == "2" ]] \
  && cmp -s "$_wce_range_cur/package.json" "$_wce_range_root/package.saved" \
  && cmp -s "$_wce_range_cur/package-lock.json" "$_wce_range_root/lock.saved"; then
  pass "web-content-extraction: pair validation rejects mismatched root dependency ranges"
else
  fail "web-content-extraction: pair validation accepted divergent root dependency ranges"
fi

# update-deps.mjs owns the same lock while it reads and mutates the manifests.
# A live runtime lock must make the kit updater fail closed without touching
# either current file or removing the other writer's lock.
mkdir -p "$_wce_range_cur/logs"
mkdir "$_wce_range_cur/logs/.update.lock"
printf 'runtime-updater\n' > "$_wce_range_cur/logs/.update.lock/owner"
printf '{"dependencies":{"a":"2.0.0"}}\n' > "$_wce_range_new/package-lock.json"
_wce_runtime_lock_rc=0
_update_auto_managed_wce_package_pair \
  "$_wce_range_cur" "$_wce_range_snap" "$_wce_range_new" \
  >/dev/null 2>&1 || _wce_runtime_lock_rc=$?
if [[ "$_wce_runtime_lock_rc" == "2" ]] \
  && cmp -s "$_wce_range_cur/package.json" "$_wce_range_root/package.saved" \
  && cmp -s "$_wce_range_cur/package-lock.json" "$_wce_range_root/lock.saved" \
  && [[ "$(< "$_wce_range_cur/logs/.update.lock/owner")" == runtime-updater ]]; then
  pass "web-content-extraction: kit update honors the runtime dependency lock"
else
  fail "web-content-extraction: kit update raced or removed the runtime dependency lock"
fi
touch -t 200001010000 "$_wce_range_cur/logs/.update.lock"
_wce_stale_lock_rc=0
_update_auto_managed_wce_package_pair \
  "$_wce_range_cur" "$_wce_range_snap" "$_wce_range_new" \
  >/dev/null 2>&1 || _wce_stale_lock_rc=$?
if [[ "$_wce_stale_lock_rc" == "2" ]] \
  && [[ "$(< "$_wce_range_cur/logs/.update.lock/owner")" == runtime-updater ]] \
  && cmp -s "$_wce_range_cur/package.json" "$_wce_range_root/package.saved" \
  && cmp -s "$_wce_range_cur/package-lock.json" "$_wce_range_root/lock.saved"; then
  pass "web-content-extraction: stale lock residue is never reclaimed implicitly"
else
  fail "web-content-extraction: stale lock reclaim permitted a second writer"
fi
rm -rf "$_wce_range_cur/logs/.update.lock"

# A TERM delivered by mv immediately after publishing the first file used to
# arrive before the replaced flag was set. The pre-mv intent flag must make the
# EXIT trap restore both originals and release the shared runtime lock.
_wce_term_root="$_wce_tmp/term-after-first-rename"
_wce_term_cur="$_wce_term_root/home/.claude/skills/web-content-extraction"
_wce_term_snap="$_wce_term_root/snapshot/skills/web-content-extraction"
_wce_term_new="$_wce_term_root/new/skills/web-content-extraction"
mkdir -p "$_wce_term_cur" "$_wce_term_snap" "$_wce_term_new"
printf '{"dependencies":{"a":"1.1.0"}}\n' > "$_wce_term_cur/package.json"
printf '{"dependencies":{"a":"1.0.0"}}\n' > "$_wce_term_snap/package.json"
printf '{"dependencies":{"a":"2.0.0","b":"3.0.0"}}\n' > "$_wce_term_new/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"1.1.0"}},"node_modules/a":{"version":"1.1.0"}}}\n' \
  > "$_wce_term_cur/package-lock.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"1.0.0"}},"node_modules/a":{"version":"1.0.0"}}}\n' \
  > "$_wce_term_snap/package-lock.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"2.0.0","b":"3.0.0"}},"node_modules/a":{"version":"2.0.0"},"node_modules/b":{"version":"3.0.0"}}}\n' \
  > "$_wce_term_new/package-lock.json"
cp "$_wce_term_cur/package.json" "$_wce_term_root/package.saved"
cp "$_wce_term_cur/package-lock.json" "$_wce_term_root/lock.saved"

# Signals before the inner rename transaction must still release the outer
# runtime lock and preserve the caller's signal status/traps.
_wce_render_original="$(declare -f _wce_render_auto_managed_package_file)"
_wce_render_auto_managed_package_file() {
  kill -TERM "$BASHPID"
}
_wce_caller_term_trap_before="$(trap -p TERM)"
trap ':' TERM
_wce_caller_term_trap_expected="$(trap -p TERM)"
_wce_outer_signal_rc=0
_update_auto_managed_wce_package_pair \
  "$_wce_term_cur" "$_wce_term_snap" "$_wce_term_new" \
  >/dev/null 2>&1 || _wce_outer_signal_rc=$?
_wce_caller_term_trap_after="$(trap -p TERM)"
if [[ -n "$_wce_caller_term_trap_before" ]]; then
  eval "$_wce_caller_term_trap_before"
else
  trap - TERM
fi
eval "$_wce_render_original"
if [[ "$_wce_outer_signal_rc" == "143" ]] \
  && cmp -s "$_wce_term_cur/package.json" "$_wce_term_root/package.saved" \
  && cmp -s "$_wce_term_cur/package-lock.json" "$_wce_term_root/lock.saved" \
  && [[ ! -e "$_wce_term_cur/logs/.update.lock" ]] \
  && [[ "$_wce_caller_term_trap_after" \
    == "$_wce_caller_term_trap_expected" ]]; then
  pass "web-content-extraction: outer TERM releases the lock with signal status"
else
  fail "web-content-extraction: outer TERM left package state or lock behind"
fi

_wce_pair_mv_original="$(declare -f _wce_package_pair_mv)"
_wce_package_pair_mv() {
  mv -f "$1" "$2" || return 1
  case "$1" in
    *package.json.stage.*) kill -TERM "$BASHPID" ;;
  esac
}
_wce_term_rc=0
_update_auto_managed_wce_package_pair \
  "$_wce_term_cur" "$_wce_term_snap" "$_wce_term_new" \
  >/dev/null 2>&1 || _wce_term_rc=$?
eval "$_wce_pair_mv_original"
if [[ "$_wce_term_rc" == "143" ]] \
  && cmp -s "$_wce_term_cur/package.json" "$_wce_term_root/package.saved" \
  && cmp -s "$_wce_term_cur/package-lock.json" "$_wce_term_root/lock.saved" \
  && [[ ! -e "$_wce_term_cur/logs/.update.lock" ]] \
  && ! compgen -G "$_wce_term_cur/*.backup.*" >/dev/null; then
  pass "web-content-extraction: TERM after first rename rolls the pair back"
else
  fail "web-content-extraction: TERM exposed a partial package-pair commit"
fi

# If restoration itself fails, the only known-good copy must remain available
# instead of being deleted by generic transaction cleanup.
_wce_pair_mv_original="$(declare -f _wce_package_pair_mv)"
_wce_package_pair_mv() {
  case "$1" in
    *package-lock.json.stage.*|*package.json.backup.*) return 1 ;;
    *) mv -f "$1" "$2" ;;
  esac
}
_wce_rollback_rc=0
_update_auto_managed_wce_package_pair \
  "$_wce_term_cur" "$_wce_term_snap" "$_wce_term_new" \
  >/dev/null 2>&1 || _wce_rollback_rc=$?
eval "$_wce_pair_mv_original"
_wce_preserved_backup="$(compgen -G "$_wce_term_cur/package.json.backup.*" || true)"
if [[ "$_wce_rollback_rc" == "2" && -f "$_wce_preserved_backup" ]] \
  && cmp -s "$_wce_preserved_backup" "$_wce_term_root/package.saved" \
  && cmp -s "$_wce_term_cur/package-lock.json" "$_wce_term_root/lock.saved"; then
  pass "web-content-extraction: failed rollback preserves the recoverable backup"
else
  fail "web-content-extraction: failed rollback deleted its only recoverable backup"
fi

# Paths are opaque strings. A literal pipe in an installation root must not be
# parsed as an internal pair delimiter.
_wce_pipe_root="$_wce_tmp/path|with-pipe"
_wce_pipe_cur="$_wce_pipe_root/home/.claude/skills/web-content-extraction"
_wce_pipe_snap="$_wce_pipe_root/snapshot/skills/web-content-extraction"
_wce_pipe_new="$_wce_pipe_root/new/skills/web-content-extraction"
mkdir -p "$_wce_pipe_cur" "$_wce_pipe_snap" "$_wce_pipe_new"
printf '{"dependencies":{"a":"1.1.0"}}\n' > "$_wce_pipe_cur/package.json"
printf '{"dependencies":{"a":"1.0.0"}}\n' > "$_wce_pipe_snap/package.json"
printf '{"engines":{"node":">=22.19.0"},"dependencies":{"a":"1.2.0"}}\n' \
  > "$_wce_pipe_new/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"1.1.0"}},"node_modules/a":{"version":"1.1.0"}}}\n' \
  > "$_wce_pipe_cur/package-lock.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"1.0.0"}},"node_modules/a":{"version":"1.0.0"}}}\n' \
  > "$_wce_pipe_snap/package-lock.json"
printf '{"lockfileVersion":3,"packages":{"":{"engines":{"node":">=22.19.0"},"dependencies":{"a":"1.2.0"}},"node_modules/a":{"version":"1.2.0"}}}\n' \
  > "$_wce_pipe_new/package-lock.json"
if _update_auto_managed_wce_package_pair \
    "$_wce_pipe_cur" "$_wce_pipe_snap" "$_wce_pipe_new" \
  && [[ "$(jq -r '.dependencies.a' "$_wce_pipe_cur/package.json")" == 1.1.0 ]] \
  && [[ "$(jq -r '.packages[""].dependencies.a' "$_wce_pipe_cur/package-lock.json")" == 1.1.0 ]] \
  && [[ "$(jq -r '.engines.node' "$_wce_pipe_cur/package.json")" == ">=22.19.0" ]]; then
  pass "web-content-extraction: package-pair update supports a pipe in its path"
else
  fail "web-content-extraction: package-pair update parsed a pipe-containing path"
fi

# A kit with no direct dependencies is valid; npm omits the key entirely.
_wce_zero_root="$_wce_tmp/zero-dependencies"
_wce_zero_cur="$_wce_zero_root/home/.claude/skills/web-content-extraction"
_wce_zero_snap="$_wce_zero_root/snapshot/skills/web-content-extraction"
_wce_zero_new="$_wce_zero_root/new/skills/web-content-extraction"
mkdir -p "$_wce_zero_cur" "$_wce_zero_snap" "$_wce_zero_new"
printf '{"dependencies":{"a":"1.1.0"}}\n' > "$_wce_zero_cur/package.json"
printf '{"dependencies":{"a":"1.0.0"}}\n' > "$_wce_zero_snap/package.json"
printf '{}\n' > "$_wce_zero_new/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"1.1.0"}},"node_modules/a":{"version":"1.1.0"}}}\n' > "$_wce_zero_cur/package-lock.json"
printf '{"lockfileVersion":3,"packages":{"":{"dependencies":{"a":"1.0.0"}},"node_modules/a":{"version":"1.0.0"}}}\n' > "$_wce_zero_snap/package-lock.json"
printf '{"lockfileVersion":3,"packages":{"":{}}}\n' > "$_wce_zero_new/package-lock.json"
if _update_auto_managed_wce_package_pair \
    "$_wce_zero_cur" "$_wce_zero_snap" "$_wce_zero_new" \
  && cmp -s "$_wce_zero_cur/package.json" "$_wce_zero_new/package.json" \
  && cmp -s "$_wce_zero_cur/package-lock.json" "$_wce_zero_new/package-lock.json"; then
  pass "web-content-extraction: removing the final dependency converges to an omitted key"
else
  fail "web-content-extraction: final dependency removal was rejected"
fi

# Generic unchanged/fresh branches must validate new kit JSON before copying.
_wce_bad_root="$_wce_tmp/malformed-new"
_wce_bad_current="$_wce_bad_root/home/.claude/skills/web-content-extraction/package.json"
_wce_bad_snapshot="$_wce_bad_root/snapshot/skills/web-content-extraction/package.json"
_wce_bad_new="$_wce_bad_root/new/skills/web-content-extraction/package.json"
mkdir -p "$(dirname "$_wce_bad_current")" \
  "$(dirname "$_wce_bad_snapshot")" "$(dirname "$_wce_bad_new")"
printf '{"dependencies":{"a":"1.0.0"}}\n' > "$_wce_bad_current"
cp "$_wce_bad_current" "$_wce_bad_snapshot"
cp "$_wce_bad_current" "$_wce_bad_root/current.saved"
printf '{"dependencies":' > "$_wce_bad_new"
_wce_bad_new_rc=0
_update_file "$_wce_bad_current" "$_wce_bad_snapshot" "$_wce_bad_new" \
  >/dev/null 2>&1 || _wce_bad_new_rc=$?
if [[ "$_wce_bad_new_rc" == "2" ]] \
  && cmp -s "$_wce_bad_current" "$_wce_bad_root/current.saved"; then
  pass "web-content-extraction: malformed new kit JSON is rejected before copy"
else
  fail "web-content-extraction: malformed new kit JSON replaced the current file"
fi

_wce_orig_arch="$(declare -f _mdm_current_darwin_arch)"
_mdm_current_darwin_arch() { printf '%s' x64; }
_wce_expected_x64="$(_wce_mdm_expected_bundle 2>/dev/null || true)"
eval "$_wce_orig_arch"
if [[ "$_wce_expected_x64" == \
  "/Library/Application Support/ClaudeCodeStarterKit/runtime/web-content-extraction/node-v24.18.0-npm-v11.16.0-darwin-x64/${_WCE_MDM_PACKAGE_SHA256}-${_WCE_MDM_LOCK_SHA256}" ]]; then
  pass "web-content-extraction: Intel runtime uses the canonical x64 label"
else
  fail "web-content-extraction: Intel runtime path drifted from the x64 contract"
fi

# The ordinary npm ci path mutates node_modules and must serialize with the
# SessionStart dependency updater. A live updater lock fails closed and is not
# removed or followed by npm execution.
_wce_npm_lock_home="$_wce_tmp/npm-ci-runtime-lock"
_wce_npm_lock_skill="$_wce_npm_lock_home/.claude/skills/web-content-extraction"
mkdir -p "$_wce_npm_lock_skill/logs"
cp "$WCE_DIR/package.json" "$WCE_DIR/package-lock.json" \
  "$_wce_npm_lock_skill/"
mkdir "$_wce_npm_lock_skill/logs/.update.lock"
printf 'runtime-updater\n' > "$_wce_npm_lock_skill/logs/.update.lock/owner"
_wce_npm_lock_rc=0
(
  unset KIT_MDM_MANAGED WCE_SKIP_NPM_INSTALL
  INSTALL_SKILLS=true DRY_RUN=false
  CLAUDE_DIR="$_wce_npm_lock_home/.claude"
  node() { :; }
  npm() { : > "$_wce_npm_lock_home/npm-called"; }
  maybe_install_web_content_deps
) >/dev/null 2>&1 || _wce_npm_lock_rc=$?
if [[ "$_wce_npm_lock_rc" != "0" \
  && ! -e "$_wce_npm_lock_home/npm-called" \
  && "$(< "$_wce_npm_lock_skill/logs/.update.lock/owner")" \
    == runtime-updater ]]; then
  pass "web-content-extraction: npm ci honors an active runtime update lock"
else
  fail "web-content-extraction: npm ci raced or removed an active runtime lock"
fi

# --- 11. MDM activates a root-owned runtime without running user npm ---
_wce_activation_impl="$(declare -f _wce_activate_mdm_runtime)"
if /usr/bin/grep -Fq '"$candidate" "$link" link-preserve-dir' \
    < <(printf '%s\n' "$_wce_activation_impl") \
  && /usr/bin/grep -Fq '_mdm_finalize_preserved_component_leaf' \
    < <(printf '%s\n' "$_wce_activation_impl"); then
  pass "web-content-extraction: MDM activation preserves only real directories"
else
  fail "web-content-extraction: MDM activation lost its directory-only preservation contract"
fi

_wce_mdm_results="$_wce_tmp/mdm-runtime-results"
: > "$_wce_mdm_results"
(
  _wce_record_mdm_result() {
    printf '%s\t%s\n' "$1" "$2" >> "$_wce_mdm_results"
  }
  _wce_lstat_inode() {
    if [[ "$(/usr/bin/uname -s 2>/dev/null)" == Darwin ]]; then
      /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null || true
    else
      /usr/bin/stat -c '%d:%i' "$1" 2>/dev/null || true
    fi
  }
  export KIT_MDM_MANAGED=true KIT_MDM_PREREQ_MODE=auto
  unset WCE_SKIP_NPM_INSTALL
  INSTALL_SKILLS=true
  DRY_RUN=false
  CLAUDE_DIR="$_wce_tmp/mdm-deps-home/.claude"
  _wce_skill="$CLAUDE_DIR/skills/web-content-extraction"
  _wce_bin="$_wce_tmp/mdm-deps-bin"
  _wce_trust_base="$_wce_tmp/root-runtime-base"
  _wce_bundle="$_wce_trust_base/ClaudeCodeStarterKit/runtime/web-content-extraction/node-v24.18.0-npm-v11.16.0-darwin-arm64/$_WCE_MDM_PACKAGE_SHA256-$_WCE_MDM_LOCK_SHA256"
  _wce_external="$_wce_tmp/external-runtime"
  mkdir -p "$_wce_skill" "$_wce_bin" "$_wce_external"
  cp "$WCE_DIR/package.json" "$WCE_DIR/package-lock.json" "$_wce_skill/"
  printf 'preserve\n' > "$_wce_external/preserve"

  _wce_reset_mdm_bundle() {
    local dep version
    rm -rf "$_wce_bundle"
    mkdir -p "$_wce_bundle/node_modules"
    cp "$WCE_DIR/package.json" "$WCE_DIR/package-lock.json" "$_wce_bundle/"
    cp "$WCE_DIR/package-lock.json" \
      "$_wce_bundle/node_modules/.package-lock.json"
    for dep in defuddle jsdom pdfjs-dist undici; do
      case "$dep" in
        defuddle) version=0.19.1 ;;
        jsdom) version=29.1.1 ;;
        pdfjs-dist) version=6.0.227 ;;
        undici) version=8.7.0 ;;
      esac
      mkdir -p "$_wce_bundle/node_modules/$dep/lib"
      printf '{"name":"%s","version":"%s"}\n' "$dep" "$version" \
        > "$_wce_bundle/node_modules/$dep/package.json"
      printf 'export const fixture = true;\n' \
        > "$_wce_bundle/node_modules/$dep/lib/index.js"
    done
    printf '#!/bin/sh\nexit 0\n' \
      > "$_wce_bundle/node_modules/defuddle/lib/cli.js"
    printf \
      '{"arch":"arm64","lock_sha256":"%s","node_version":"v24.18.0","npm_version":"11.16.0","package_sha256":"%s","registry":"https://registry.npmjs.org/","schema_version":1}\n' \
      "$_WCE_MDM_LOCK_SHA256" "$_WCE_MDM_PACKAGE_SHA256" \
      > "$_wce_bundle/.claude-code-starter-kit-wce-runtime.json"
    find "$_wce_trust_base" -type d -exec chmod 755 {} +
    find "$_wce_bundle" -type f -exec chmod 644 {} +
    chmod 755 "$_wce_bundle/node_modules/defuddle/lib/cli.js"
  }

  _wce_expect_bundle_rejected() {
    local message="$1"
    if _wce_validate_mdm_bundle "$_wce_skill" >/dev/null 2>&1; then
      _wce_record_mdm_result fail "$message"
    else
      _wce_record_mdm_result pass "$message"
    fi
  }

  _wce_reset_mdm_bundle
  printf '%s\n' \
    '#!/bin/bash' \
    ": > \"$_wce_tmp/mdm-npm-called\"" \
    'exit 99' \
    > "$_wce_bin/npm"
  chmod +x "$_wce_bin/npm"
  export PATH="$_wce_bin:/usr/bin:/bin"
  export KIT_MDM_WCE_RUNTIME_BUNDLE="$_wce_bundle"

  _wce_orig_expected_bundle="$(declare -f _wce_mdm_expected_bundle)"
  _wce_orig_trust_base="$(declare -f _wce_mdm_trust_base)"
  _wce_orig_owner_uid="$(declare -f _wce_mdm_expected_owner_uid)"
  _wce_orig_owner_gid="$(declare -f _wce_mdm_expected_owner_gid)"
  _wce_orig_runtime_arch="$(declare -f _mdm_current_darwin_arch)"
  _wce_mdm_expected_bundle() { printf '%s' "$_wce_bundle"; }
  _wce_mdm_trust_base() { printf '%s' "$_wce_trust_base"; }
  _wce_mdm_expected_owner_uid() { /usr/bin/id -u; }
  _wce_mdm_expected_owner_gid() { /usr/bin/id -g; }
  _mdm_current_darwin_arch() { printf '%s' arm64; }

  _wce_rc=0
  maybe_install_web_content_deps >/dev/null 2>&1 || _wce_rc=$?
  if [[ "$_wce_rc" -eq 0 && -L "$_wce_skill/node_modules" \
    && "$(/usr/bin/readlink "$_wce_skill/node_modules")" \
      == "$_wce_bundle/node_modules" \
    && -f "$_wce_skill/node_modules/defuddle/package.json" \
    && -f "$_wce_skill/node_modules/jsdom/package.json" \
    && -f "$_wce_skill/node_modules/pdfjs-dist/package.json" \
    && -f "$_wce_skill/node_modules/undici/package.json" \
    && ! -e "$_wce_tmp/mdm-npm-called" ]]; then
    _wce_record_mdm_result pass \
      "web-content-extraction: MDM auto activates root-owned dependencies without npm"
  else
    _wce_record_mdm_result fail \
      "web-content-extraction: MDM auto did not converge to the root-owned runtime"
  fi

  _wce_link_before="$(_wce_lstat_inode "$_wce_skill/node_modules")"
  _wce_rc=0
  maybe_install_web_content_deps >/dev/null 2>&1 || _wce_rc=$?
  _wce_link_after="$(_wce_lstat_inode "$_wce_skill/node_modules")"
  if [[ "$_wce_rc" -eq 0 && "$_wce_link_before" == "$_wce_link_after" \
    && ! -e "$_wce_tmp/mdm-npm-called" ]]; then
    _wce_record_mdm_result pass \
      "web-content-extraction: MDM auto keeps an exact activation inode unchanged"
  else
    _wce_record_mdm_result fail \
      "web-content-extraction: MDM auto replaced or rejected an exact activation"
  fi

  export KIT_MDM_PREREQ_MODE=fail
  _wce_link_before="$(_wce_lstat_inode "$_wce_skill/node_modules")"
  _wce_rc=0
  maybe_install_web_content_deps >/dev/null 2>&1 || _wce_rc=$?
  _wce_link_after="$(_wce_lstat_inode "$_wce_skill/node_modules")"
  if [[ "$_wce_rc" -eq 0 && "$_wce_link_before" == "$_wce_link_after" \
    && ! -e "$_wce_tmp/mdm-npm-called" ]]; then
    _wce_record_mdm_result pass \
      "web-content-extraction: MDM fail validates activation read-only and offline"
  else
    _wce_record_mdm_result fail \
      "web-content-extraction: MDM fail mutated or rejected the exact activation"
  fi

  rm -rf "$_wce_skill/node_modules"
  export KIT_MDM_PREREQ_MODE=fail
  _wce_rc=0
  maybe_install_web_content_deps >/dev/null 2>&1 || _wce_rc=$?
  if [[ "$_wce_rc" -eq 0 && -L "$_wce_skill/node_modules" \
    && "$(/usr/bin/readlink "$_wce_skill/node_modules")" \
      == "$_wce_bundle/node_modules" \
    && ! -e "$_wce_tmp/mdm-npm-called" ]]; then
    _wce_record_mdm_result pass \
      "web-content-extraction: MDM fail activates a valid initial preseed offline"
  else
    _wce_record_mdm_result fail \
      "web-content-extraction: MDM fail rejected or rebuilt a valid initial preseed"
  fi

  export KIT_MDM_PREREQ_MODE=auto
  rm -rf "$_wce_skill/node_modules"
  ln -s "$_wce_external" "$_wce_skill/node_modules"
  _wce_rc=0
  maybe_install_web_content_deps >/dev/null 2>&1 || _wce_rc=$?
  if [[ "$_wce_rc" -eq 0 \
    && "$(/usr/bin/readlink "$_wce_skill/node_modules")" \
      == "$_wce_bundle/node_modules" \
    && -f "$_wce_external/preserve" ]]; then
    _wce_record_mdm_result pass \
      "web-content-extraction: MDM auto repairs a wrong link without following it"
  else
    _wce_record_mdm_result fail \
      "web-content-extraction: MDM auto did not safely repair the activation"
  fi

  rm -f "$_wce_skill/node_modules"
  printf 'replaceable\n' > "$_wce_skill/node_modules"
  _wce_rc=0
  maybe_install_web_content_deps >/dev/null 2>&1 || _wce_rc=$?
  if [[ "$_wce_rc" -eq 0 && -L "$_wce_skill/node_modules" \
    && "$(/usr/bin/readlink "$_wce_skill/node_modules")" \
      == "$_wce_bundle/node_modules" \
    && -z "$(find "$_wce_skill" -maxdepth 1 \
      -name '.node-modules.pre-mdm.*' -print)" ]]; then
    _wce_record_mdm_result pass \
      "web-content-extraction: MDM repairs file/link leaves without backup residue"
  else
    _wce_record_mdm_result fail \
      "web-content-extraction: MDM left residue after repairing file/link leaves"
  fi

  # Force the post-publication validation to fail. The exact original real
  # directory must be restored, including its inode and contents, while only
  # the activation symlink published by this transaction is removed.
  rm -f "$_wce_skill/node_modules"
  mkdir -p "$_wce_skill/node_modules/preserve"
  printf 'rollback-original\n' \
    > "$_wce_skill/node_modules/preserve/index.js"
  _wce_directory_before="$(_wce_lstat_inode "$_wce_skill/node_modules")"
  _wce_orig_validate_activation="$(declare -f _wce_validate_mdm_activation)"
  _wce_validate_mdm_activation() { return 1; }
  _wce_rc=0
  maybe_install_web_content_deps >/dev/null 2>&1 || _wce_rc=$?
  eval "$_wce_orig_validate_activation"
  _wce_directory_after="$(_wce_lstat_inode "$_wce_skill/node_modules")"
  _wce_rollback_backups="$(find "$_wce_skill" -maxdepth 1 -type d \
    -name '.node-modules.pre-mdm.*' -print)"
  if [[ "$_wce_rc" -ne 0 \
    && "$_wce_directory_before" == "$_wce_directory_after" \
    && -d "$_wce_skill/node_modules" \
    && "$(< "$_wce_skill/node_modules/preserve/index.js")" \
      == rollback-original \
    && -z "$_wce_rollback_backups" ]]; then
    _wce_record_mdm_result pass \
      "web-content-extraction: failed MDM activation restores the exact dependency directory"
  else
    _wce_record_mdm_result fail \
      "web-content-extraction: failed MDM activation did not roll back exactly"
  fi

  # Build the source state through the ordinary non-MDM path, not by manually
  # fabricating only the final leaf. This fixes the real upgrade path: standard
  # installs run npm ci first and later MDM enrollment must converge offline.
  rm -rf "$_wce_skill/node_modules"
  unset KIT_MDM_MANAGED
  export KIT_MDM_PREREQ_MODE=auto
  node() { return 0; }
  npm() {
    printf '%s\n' "$PWD" "$*" > "$_wce_tmp/non-mdm-npm-call"
    [[ "$PWD" == "$_wce_skill" \
      && "$*" == 'ci --omit=dev --ignore-scripts --no-audit --no-fund' ]] \
      || return 97
    [[ -d "$_wce_skill/logs/.update.lock" \
      && -f "$_wce_skill/logs/.update.lock/owner" ]] || return 96
    mkdir -p node_modules/non-mdm-dependency
    printf 'ordinary-install\n' \
      > node_modules/non-mdm-dependency/package.json
  }
  _wce_non_mdm_rc=0
  maybe_install_web_content_deps >/dev/null 2>&1 || _wce_non_mdm_rc=$?
  unset -f npm node
  _wce_directory_before="$(_wce_lstat_inode "$_wce_skill/node_modules")"
  export KIT_MDM_MANAGED=true KIT_MDM_PREREQ_MODE=fail
  _wce_rc=0
  maybe_install_web_content_deps >/dev/null 2>&1 || _wce_rc=$?
  _wce_backup_dir="$(find "$_wce_skill" -maxdepth 1 -type d \
    -name '.node-modules.pre-mdm.*' -print)"
  _wce_backup_count="$(find "$_wce_skill" -maxdepth 1 -type d \
    -name '.node-modules.pre-mdm.*' -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  if [[ "$_wce_non_mdm_rc" -eq 0 && "$_wce_rc" -eq 0 \
    && "$_wce_backup_count" == 1 && -d "$_wce_backup_dir" \
    && ! -L "$_wce_backup_dir" \
    && "$(_wce_lstat_inode "$_wce_backup_dir")" \
      == "$_wce_directory_before" \
    && ! -e "$_wce_skill/logs/.update.lock" \
    && "$(< "$_wce_backup_dir/non-mdm-dependency/package.json")" \
      == ordinary-install \
    && -L "$_wce_skill/node_modules" \
    && "$(/usr/bin/readlink "$_wce_skill/node_modules")" \
      == "$_wce_bundle/node_modules" \
    && "$(< "$_wce_tmp/non-mdm-npm-call")" == "$_wce_skill"$'\n'"ci --omit=dev --ignore-scripts --no-audit --no-fund" ]]; then
    _wce_record_mdm_result pass \
      "web-content-extraction: MDM fail migrates a real non-MDM install without data loss"
  else
    _wce_record_mdm_result fail \
      "web-content-extraction: MDM fail did not preserve a real non-MDM install"
  fi

  _wce_link_before="$(_wce_lstat_inode "$_wce_skill/node_modules")"
  _wce_rc=0
  maybe_install_web_content_deps >/dev/null 2>&1 || _wce_rc=$?
  _wce_link_after="$(_wce_lstat_inode "$_wce_skill/node_modules")"
  _wce_backup_after="$(find "$_wce_skill" -maxdepth 1 -type d \
    -name '.node-modules.pre-mdm.*' -print)"
  if [[ "$_wce_rc" -eq 0 \
    && "$_wce_link_before" == "$_wce_link_after" \
    && "$_wce_backup_after" == "$_wce_backup_dir" \
    && -d "$_wce_backup_dir" \
    && "$(< "$_wce_backup_dir/non-mdm-dependency/package.json")" \
      == ordinary-install ]]; then
    _wce_record_mdm_result pass \
      "web-content-extraction: migrated MDM activation is idempotent and retains its backup"
  else
    _wce_record_mdm_result fail \
      "web-content-extraction: migrated MDM activation changed on reconciliation"
  fi
  rm -f "$_wce_skill/node_modules"

  mkdir -p "$_wce_skill/node_modules/preserve"
  printf 'unsafe-mode\n' > "$_wce_skill/node_modules/preserve/index.js"
  chmod 0777 "$_wce_skill/node_modules"
  _wce_unsafe_before="$(_wce_lstat_inode "$_wce_skill/node_modules")"
  _wce_rc=0
  maybe_install_web_content_deps >/dev/null 2>&1 || _wce_rc=$?
  _wce_unsafe_after="$(_wce_lstat_inode "$_wce_skill/node_modules")"
  if [[ "$_wce_rc" -ne 0 && "$_wce_unsafe_before" == "$_wce_unsafe_after" \
    && -d "$_wce_skill/node_modules" \
    && "$(< "$_wce_skill/node_modules/preserve/index.js")" == unsafe-mode ]]; then
    _wce_record_mdm_result pass \
      "web-content-extraction: MDM rejects a writable dependency directory unchanged"
  else
    _wce_record_mdm_result fail \
      "web-content-extraction: MDM changed or accepted a writable dependency directory"
  fi
  chmod 0755 "$_wce_skill/node_modules"
  rm -rf "$_wce_skill/node_modules"

  mkdir -p "$_wce_skill/node_modules/preserve"
  printf 'acl-preserve\n' > "$_wce_skill/node_modules/preserve/index.js"
  _wce_acl_ready=false
  if [[ "$(/usr/bin/uname -s 2>/dev/null)" == Darwin ]] \
    && /bin/chmod +a 'everyone allow write' \
      "$_wce_skill/node_modules" 2>/dev/null; then
    _wce_acl_ready=true
  elif command -v setfacl >/dev/null 2>&1 \
    && setfacl -m "u:$(/usr/bin/id -u):rwx" \
      "$_wce_skill/node_modules" 2>/dev/null; then
    _wce_acl_ready=true
  fi
  if [[ "$_wce_acl_ready" == true ]]; then
    _wce_unsafe_before="$(_wce_lstat_inode "$_wce_skill/node_modules")"
    _wce_rc=0
    maybe_install_web_content_deps >/dev/null 2>&1 || _wce_rc=$?
    _wce_unsafe_after="$(_wce_lstat_inode "$_wce_skill/node_modules")"
    if [[ "$_wce_rc" -ne 0 \
      && "$_wce_unsafe_before" == "$_wce_unsafe_after" \
      && "$(< "$_wce_skill/node_modules/preserve/index.js")" \
        == acl-preserve ]]; then
      _wce_record_mdm_result pass \
        "web-content-extraction: MDM rejects an ACL dependency directory unchanged"
    else
      _wce_record_mdm_result fail \
        "web-content-extraction: MDM changed or accepted an ACL dependency directory"
    fi
  else
    _wce_record_mdm_result skip \
      "web-content-extraction: MDM rejects an ACL dependency directory unchanged"
  fi
  rm -rf "$_wce_skill/node_modules"

  _wce_mkfifo="$(command -v mkfifo || true)"
  if [[ -n "$_wce_mkfifo" ]] && "$_wce_mkfifo" "$_wce_skill/node_modules"; then
    _wce_rc=0
    maybe_install_web_content_deps >/dev/null 2>&1 || _wce_rc=$?
    if [[ "$_wce_rc" -ne 0 && -p "$_wce_skill/node_modules" ]]; then
      _wce_record_mdm_result pass \
        "web-content-extraction: MDM rejects an activation FIFO unchanged"
    else
      _wce_record_mdm_result fail \
        "web-content-extraction: MDM changed or accepted an activation FIFO"
    fi
    rm -f "$_wce_skill/node_modules"
  else
    _wce_record_mdm_result skip \
      "web-content-extraction: MDM rejects an activation FIFO unchanged"
  fi

  export KIT_MDM_PREREQ_MODE=auto
  printf 'unsafe\n' > "$_wce_skill/node_modules"
  ln "$_wce_skill/node_modules" "$_wce_skill/node-modules-peer"
  _wce_unsafe_before="$(_wce_lstat_inode "$_wce_skill/node_modules")"
  _wce_rc=0
  maybe_install_web_content_deps >/dev/null 2>&1 || _wce_rc=$?
  _wce_unsafe_after="$(_wce_lstat_inode "$_wce_skill/node_modules")"
  if [[ "$_wce_rc" -ne 0 && "$_wce_unsafe_before" == "$_wce_unsafe_after" \
    && -f "$_wce_skill/node_modules" \
    && "$(< "$_wce_skill/node_modules")" == unsafe \
    && "$(_wce_lstat_inode "$_wce_skill/node-modules-peer")" \
      == "$_wce_unsafe_before" ]]; then
    _wce_record_mdm_result pass \
      "web-content-extraction: MDM auto preserves and rejects a hardlinked leaf"
  else
    _wce_record_mdm_result fail \
      "web-content-extraction: MDM auto changed or accepted a hardlinked leaf"
  fi
  rm -f "$_wce_skill/node_modules" "$_wce_skill/node-modules-peer"
  ln -s "$_wce_external" "$_wce_skill/node_modules"
  _wce_wrong_before="$(_wce_lstat_inode "$_wce_skill/node_modules")"
  _wce_rc=0
  _mdm_atomic_replace_component_leaf \
    "$_wce_skill/.missing-node-modules-candidate" \
    "$_wce_skill/node_modules" >/dev/null 2>&1 || _wce_rc=$?
  _wce_wrong_after="$(_wce_lstat_inode "$_wce_skill/node_modules")"
  if [[ "$_wce_rc" -ne 0 && "$_wce_wrong_before" == "$_wce_wrong_after" \
    && "$(/usr/bin/readlink "$_wce_skill/node_modules")" == "$_wce_external" \
    && -f "$_wce_external/preserve" ]]; then
    _wce_record_mdm_result pass \
      "web-content-extraction: failed atomic replacement restores its backup"
  else
    _wce_record_mdm_result fail \
      "web-content-extraction: failed atomic replacement lost the previous leaf"
  fi
  _wce_reset_mdm_bundle
  printf 'unexpected\n' > "$_wce_bundle/unexpected"
  _wce_expect_bundle_rejected \
    "web-content-extraction: MDM bundle rejects an unexpected top-level entry"
  _wce_reset_mdm_bundle
  printf 'changed\n' >> "$_wce_bundle/package.json"
  _wce_expect_bundle_rejected \
    "web-content-extraction: MDM bundle binds its package source hash"
  _wce_reset_mdm_bundle
  printf 'changed\n' >> "$_wce_bundle/package-lock.json"
  _wce_expect_bundle_rejected \
    "web-content-extraction: MDM bundle binds its lock source hash"

  _wce_reset_mdm_bundle
  cp "$_wce_skill/package.json" "$_wce_skill/package.json.saved"
  printf 'changed\n' >> "$_wce_skill/package.json"
  _wce_expect_bundle_rejected \
    "web-content-extraction: MDM bundle binds the deployed package source hash"
  mv "$_wce_skill/package.json.saved" "$_wce_skill/package.json"

  _wce_reset_mdm_bundle
  cp "$_wce_skill/package-lock.json" "$_wce_skill/package-lock.json.saved"
  printf 'changed\n' >> "$_wce_skill/package-lock.json"
  _wce_expect_bundle_rejected \
    "web-content-extraction: MDM bundle binds the deployed lock source hash"
  mv "$_wce_skill/package-lock.json.saved" "$_wce_skill/package-lock.json"
  _wce_reset_mdm_bundle
  printf '{}\n' > "$_wce_bundle/.claude-code-starter-kit-wce-runtime.json"
  _wce_expect_bundle_rejected \
    "web-content-extraction: MDM activation rejects a mismatched provenance marker"
  _wce_reset_mdm_bundle
  printf '\0' >> "$_wce_bundle/.claude-code-starter-kit-wce-runtime.json"
  _wce_expect_bundle_rejected \
    "web-content-extraction: MDM activation rejects a NUL-suffixed marker"
  _wce_reset_mdm_bundle
  rm -rf "$_wce_bundle/node_modules/undici"
  _wce_expect_bundle_rejected \
    "web-content-extraction: MDM bundle requires every direct dependency directory"
  _wce_reset_mdm_bundle
  rm "$_wce_bundle/node_modules/jsdom/package.json"
  _wce_expect_bundle_rejected \
    "web-content-extraction: MDM bundle requires each dependency package.json"
  _wce_reset_mdm_bundle
  chmod 700 "$_wce_bundle/node_modules/jsdom/lib"
  _wce_expect_bundle_rejected \
    "web-content-extraction: MDM bundle requires mode 0755 on every directory"
  _wce_reset_mdm_bundle
  chmod 600 "$_wce_bundle/node_modules/jsdom/lib/index.js"
  _wce_expect_bundle_rejected \
    "web-content-extraction: MDM bundle rejects noncanonical regular-file modes"
  _wce_reset_mdm_bundle
  chmod 755 "$_wce_bundle/package-lock.json"
  _wce_expect_bundle_rejected \
    "web-content-extraction: MDM bundle requires mode 0644 on fixed top files"
  _wce_reset_mdm_bundle
  ln "$_wce_bundle/node_modules/jsdom/lib/index.js" \
    "$_wce_tmp/wce-hardlink"
  _wce_expect_bundle_rejected \
    "web-content-extraction: MDM bundle rejects multiply linked regular files"
  rm "$_wce_tmp/wce-hardlink"
  _wce_reset_mdm_bundle
  ln -s ../jsdom "$_wce_bundle/node_modules/defuddle/jsdom-link"
  _wce_expect_bundle_rejected \
    "web-content-extraction: MDM bundle rejects internal symlinks"
  _wce_reset_mdm_bundle
  _wce_mkfifo="$(command -v mkfifo || true)"
  if [[ -n "$_wce_mkfifo" ]] \
    && "$_wce_mkfifo" "$_wce_bundle/node_modules/defuddle/special"; then
    _wce_expect_bundle_rejected \
      "web-content-extraction: MDM bundle rejects special files"
  else
    _wce_record_mdm_result skip \
      "web-content-extraction: MDM bundle rejects special files (mkfifo unavailable)"
  fi
  _wce_reset_mdm_bundle
  _wce_acl_tested=false
  if [[ "$(/usr/bin/uname -s 2>/dev/null)" == Darwin ]] \
    && /bin/chmod +a 'everyone deny write' \
      "$_wce_bundle/node_modules/jsdom/lib/index.js" 2>/dev/null; then
    _wce_acl_tested=true
  elif command -v setfacl >/dev/null 2>&1 \
    && setfacl -m "u:$(/usr/bin/id -u):rwx" \
      "$_wce_bundle/node_modules/jsdom/lib/index.js" 2>/dev/null; then
    _wce_acl_tested=true
  fi
  if [[ "$_wce_acl_tested" == true ]]; then
    _wce_expect_bundle_rejected \
      "web-content-extraction: MDM bundle rejects extended ACLs"
  else
    _wce_record_mdm_result skip \
      "web-content-extraction: MDM bundle rejects extended ACLs (ACL unavailable)"
  fi
  _wce_reset_mdm_bundle
  _wce_xattr_file="$_wce_bundle/node_modules/jsdom/lib/index.js"
  if [[ "$(/usr/bin/uname -s 2>/dev/null)" == Darwin ]] \
    && [[ -x /usr/bin/xattr ]] \
    && /usr/bin/xattr -w com.apple.provenance mdm-test \
      "$_wce_xattr_file" 2>/dev/null; then
    if _wce_validate_mdm_bundle "$_wce_skill" >/dev/null 2>&1; then
      _wce_record_mdm_result pass \
        "web-content-extraction: MDM bundle allows the provenance xattr"
    else
      _wce_record_mdm_result fail \
        "web-content-extraction: MDM bundle rejected the provenance xattr"
    fi
    /usr/bin/xattr -d com.apple.provenance "$_wce_xattr_file" \
      2>/dev/null || true
  else
    _wce_record_mdm_result skip \
      "web-content-extraction: MDM bundle allows the provenance xattr"
  fi
  if [[ "$(/usr/bin/uname -s 2>/dev/null)" == Darwin ]] \
    && [[ -x /usr/bin/xattr ]] \
    && /usr/bin/xattr -w com.cloudnative.mdm-test 1 \
      "$_wce_xattr_file" 2>/dev/null; then
    _wce_expect_bundle_rejected \
      "web-content-extraction: MDM bundle rejects non-provenance xattrs"
    /usr/bin/xattr -d com.cloudnative.mdm-test "$_wce_xattr_file" \
      2>/dev/null || true
  else
    _wce_record_mdm_result skip \
      "web-content-extraction: MDM bundle rejects non-provenance xattrs"
  fi
  eval "$_wce_orig_expected_bundle"
  eval "$_wce_orig_trust_base"
  eval "$_wce_orig_owner_uid"
  eval "$_wce_orig_owner_gid"
  eval "$_wce_orig_runtime_arch"
)
_wce_mdm_result_count=0
while IFS=$'\t' read -r _wce_result_status _wce_result_message; do
  _wce_mdm_result_count=$((_wce_mdm_result_count + 1))
  if [[ "$_wce_result_status" == "pass" ]]; then
    pass "$_wce_result_message"
  elif [[ "$_wce_result_status" == "skip" ]]; then
    skip "$_wce_result_message" "fixture unavailable on this platform"
  else
    fail "$_wce_result_message"
  fi
done < "$_wce_mdm_results"
if [[ "$_wce_mdm_result_count" -ne 32 ]]; then
  fail "web-content-extraction: MDM runtime test harness lost a result"
fi
rm -rf "$_wce_tmp"
unset WCE_DIR _wce_tmp _wce_missing _wce_check_ok _wce_tracked \
  _wce_dist_src _wce_dist_dest _wce_managed _wce_pkg_cur _wce_pkg_snap \
  _wce_pkg_new _wce_mdm_home _wce_mdm_skill _wce_mdm_bin _wce_node \
  _wce_mdm_rc _wce_wrapper _wce_run_tmp _wce_managed_root \
  _wce_runtime_root _wce_expected_node _wce_node_link _wce_wrapper_rc \
  _wce_receipt _wce_other_receipt _wce_current_receipt _wce_marker_rc \
  _wce_hook_command \
  _wce_hook_home _wce_hook_rc \
  _wce_mdm_results _wce_mdm_result_count _wce_result_status \
  _wce_result_message _wce_orig_arch _wce_expected_x64
unset _wce_activation_impl
