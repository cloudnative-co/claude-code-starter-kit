#!/bin/bash
# tests/unit/test-runtime-hooks.sh - Runtime hook cost/regression checks

{
  test_name="tmux-hooks: Bash checks are consolidated into one external hook"
  if [[ "$(jq '.hooks.PreToolUse | map(select(.matcher == "Bash")) | length' "$PROJECT_DIR/features/tmux-hooks/hooks.json")" == "1" ]] \
    && jq -e '.hooks.PreToolUse[0].hooks[0].command == "__HOME__/.claude/hooks/tmux-hooks/check-bash.sh"' "$PROJECT_DIR/features/tmux-hooks/hooks.json" >/dev/null \
    && [[ -x "$PROJECT_DIR/features/tmux-hooks/scripts/check-bash.sh" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="runtime hooks: high-frequency inline bash hooks are external scripts"
  ok_all=true
  for feature in biome-hooks prettier-hooks doc-blocker tmux-hooks pr-creation-log; do
    if jq -r '.. | objects | .command? // empty' "$PROJECT_DIR/features/$feature"/hooks*.json \
      | grep -q '#!/bin/bash'; then
      ok_all=false
    fi
  done
  if [[ "$ok_all" == "true" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="SessionStart hooks: expensive background work only runs on startup"
  if jq -e '.hooks.SessionStart[0].matcher == "startup"' "$PROJECT_DIR/features/auto-update/hooks.json" >/dev/null \
    && jq -e '.hooks.SessionStart[0].matcher == "startup"' "$PROJECT_DIR/features/feature-recommendation/hooks.json" >/dev/null \
    && jq -e '.hooks.SessionStart[0].matcher == "startup"' "$PROJECT_DIR/features/web-content-update/hooks.json" >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="pre-compact-commit: cd failure cannot fall through to git stash"
  cmd="$(jq -r '.hooks.PreCompact[0].hooks[0].command' "$PROJECT_DIR/features/pre-compact-commit/hooks.json")"
  # Guard must check non-empty BEFORE cd: Linux bash treats `cd ""` as a
  # successful no-op, so a bare `if cd "${VAR:-}"` fail-opens into the cwd.
  # The snapshot must use stash create/store (no history commits, no add -A).
  if jq -e '.hooks.PreCompact[0].matcher == "*"' "$PROJECT_DIR/features/pre-compact-commit/hooks.json" >/dev/null \
    && [[ "$cmd" == 'if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && cd '* ]] \
    && [[ "$cmd" == *"git stash create"* ]] \
    && [[ "$cmd" == *"git stash store"* ]] \
    && [[ "$cmd" != *"git add -A"* ]] \
    && [[ "$cmd" != *"git commit"* ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# ── Legacy hook path (Claude Code < 2.1.89) stays retired ───────────────────
#
# v0.79.0 (#136) removed the second hook shape the kit generated for Claude
# Code < 2.1.89 together with the CLI version gate that selected it. These
# guards keep a later change from quietly bringing either back.
{
  test_name="legacy hook path: no hooks.legacy.json fragment is shipped"
  _lhp_fragments="$(find "$PROJECT_DIR/features" -name 'hooks.legacy*' -print)"
  if [[ -z "$_lhp_fragments" ]]; then
    pass "$test_name"
  else
    fail "$test_name (found: $_lhp_fragments)"
  fi
}

{
  test_name="legacy hook path: shipped code has no reference to the retired version gate"
  _lhp_gate='_versioned_hooks_fragment|_claude_supports_async_hooks|_claude_cli_semver|_CLAUDE_SEMVER_CACHE|_version_ge|_auto_update_hooks_fragment|_pr_creation_log_hooks_fragment|require_session_end|LEGACY_CACHE_(FILE|TTL)|_auto_update_(legacy_cache_fresh|touch_legacy_cache)|KIT_MDM_ASYNC_HOOKS|async_hooks'
  _lhp_markers='hooks\.legacy|AUTO_UPDATE_LEGACY|PR_CREATION_LOG_LEGACY'
  # lib/update.sh is the one place that still names the two legacy commands:
  # _migrate_legacy_hook_entries has to recognise them to rewrite them.
  _lhp_hits="$(
    cd "$PROJECT_DIR" && {
      grep -rnE "$_lhp_gate|$_lhp_markers" \
        setup.sh install.sh install.ps1 uninstall.sh wizard mdm features \
        config profiles i18n commands 2>/dev/null || true
      find lib -type f ! -name update.sh -exec grep -nE "$_lhp_gate|$_lhp_markers" {} + 2>/dev/null || true
      grep -nE "$_lhp_gate" lib/update.sh 2>/dev/null || true
    }
  )"
  if [[ -z "$_lhp_hits" ]]; then
    pass "$test_name"
  else
    fail "$test_name (hits: $(printf '%s' "$_lhp_hits" | tr '\n' ';'))"
  fi
}

{
  test_name="legacy hook path: auto-update and pr-creation-log scripts never start claude"
  # The bare word only: paths such as ~/.claude and ~/.claude-starter-kit are
  # everywhere in these scripts and are not invocations.
  if ! grep -nE '(^|[^[:alnum:]_./~-])claude([^[:alnum:]_./-]|$)' \
      "$PROJECT_DIR/features/auto-update/scripts/auto-update.sh" \
      "$PROJECT_DIR/features/pr-creation-log/scripts/log-pr.sh" >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}


{
  test_name="tmux-hooks: run_in_background dev server passes without any output"
  _th_tmp="$(mktemp -d)"
  _SETUP_TMP_FILES+=("$_th_tmp")
  _th_rc=0
  printf '{"tool_name":"Bash","tool_input":{"command":"%s","run_in_background":true}}' "npm run dev" \
    | env -u TMUX bash "$PROJECT_DIR/features/tmux-hooks/scripts/check-bash.sh" >/dev/null 2>"$_th_tmp/bg.err" || _th_rc=$?
  if [[ "$_th_rc" -eq 0 ]] && [[ ! -s "$_th_tmp/bg.err" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="tmux-hooks: foreground dev server is a non-blocking reminder (no exit 2)"
  _th_tmp2="$(mktemp -d)"
  _SETUP_TMP_FILES+=("$_th_tmp2")
  _th_rc=0
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "npm run dev" \
    | env -u TMUX bash "$PROJECT_DIR/features/tmux-hooks/scripts/check-bash.sh" >/dev/null 2>"$_th_tmp2/fg.err" || _th_rc=$?
  if [[ "$_th_rc" -eq 0 ]] \
    && grep -q "prefer run_in_background" "$_th_tmp2/fg.err" \
    && ! grep -q "BLOCKED" "$_th_tmp2/fg.err"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="tmux-hooks: build/test commands no longer trigger advisory noise"
  _th_tmp3="$(mktemp -d)"
  _SETUP_TMP_FILES+=("$_th_tmp3")
  _th_rc=0
  printf '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' \
    | env -u TMUX bash "$PROJECT_DIR/features/tmux-hooks/scripts/check-bash.sh" >/dev/null 2>"$_th_tmp3/adv.err" || _th_rc=$?
  if [[ "$_th_rc" -eq 0 ]] && [[ ! -s "$_th_tmp3/adv.err" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="tmux-hooks: dev server inside tmux session stays silent"
  _th_tmp4="$(mktemp -d)"
  _SETUP_TMP_FILES+=("$_th_tmp4")
  _th_rc=0
  printf '{"tool_name":"Bash","tool_input":{"command":"npm run %s"}}' "dev" \
    | env TMUX=fake-session bash "$PROJECT_DIR/features/tmux-hooks/scripts/check-bash.sh" >/dev/null 2>"$_th_tmp4/in-tmux.err" || _th_rc=$?
  if [[ "$_th_rc" -eq 0 ]] && [[ ! -s "$_th_tmp4/in-tmux.err" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}
