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
  for feature in biome-hooks prettier-hooks console-log-guard doc-blocker tmux-hooks git-push-review pr-creation-log; do
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
  test_name="console-log-guard: session audit moved from Stop to SessionEnd and Write is covered"
  if jq -e 'has("hooks") and (.hooks | has("Stop") | not) and .hooks.SessionEnd[0].matcher == "*" and .hooks.PostToolUse[0].matcher == "Edit|Write"' "$PROJECT_DIR/features/console-log-guard/hooks.json" >/dev/null; then
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

{
  test_name="auto-update: runtime path no longer spawns claude --version"
  if grep -q 'AUTO_UPDATE_LEGACY' "$PROJECT_DIR/features/auto-update/hooks.legacy.json" \
    && ! grep -q '_auto_update_supports_async_hooks' "$PROJECT_DIR/features/auto-update/scripts/auto-update.sh"; then
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
