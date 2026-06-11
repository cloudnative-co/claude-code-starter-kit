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
  test_name="pre-compact-commit: cd failure cannot fall through to git commit"
  cmd="$(jq -r '.hooks.PreCompact[0].hooks[0].command' "$PROJECT_DIR/features/pre-compact-commit/hooks.json")"
  if jq -e '.hooks.PreCompact[0].matcher == "*"' "$PROJECT_DIR/features/pre-compact-commit/hooks.json" >/dev/null \
    && [[ "$cmd" == if\ cd* ]] \
    && [[ "$cmd" == *"git add -A &&"* ]]; then
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
