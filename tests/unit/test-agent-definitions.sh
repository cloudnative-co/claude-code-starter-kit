#!/bin/bash
# tests/unit/test-agent-definitions.sh - Agent prompt hygiene checks

{
  test_name="agents: definitions stay compact"
  total_lines="$(find "$PROJECT_DIR/agents" -type f -name '*.md' -print0 | xargs -0 wc -l | awk '/ total$/ {print $1}')"
  total_lines="${total_lines:-0}"
  if [[ "$total_lines" -gt 0 && "$total_lines" -le 1600 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="agents: no upstream project residue or obsolete CI/API examples"
  stale_pattern='pmx|Privy|Solana|Supabase|Real Money|staging\.pmx|upload-artifact@v3|node-version: 18|browser\.startTracing|videosPath|OWASP Top 10 2017'
  if ! grep -REi "$stale_pattern" "$PROJECT_DIR/agents" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="agents: high-frequency roles do not pin opus"
  _agent_model() {
    sed -n 's/^model: //p' "$PROJECT_DIR/agents/$1.md" | head -1
  }

  if [[ "$(_agent_model code-reviewer)" == "sonnet" ]] \
    && [[ "$(_agent_model build-error-resolver)" == "sonnet" ]] \
    && [[ "$(_agent_model tdd-guide)" == "sonnet" ]] \
    && [[ "$(_agent_model e2e-runner)" == "sonnet" ]] \
    && [[ "$(_agent_model refactor-cleaner)" == "sonnet" ]] \
    && [[ "$(_agent_model security-reviewer)" == "sonnet" ]] \
    && [[ "$(_agent_model doc-updater)" == "haiku" ]] \
    && [[ "$(_agent_model architect)" == "opus" ]] \
    && [[ "$(_agent_model planner)" == "opus" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="agents: e2e and security guidance use current baselines"
  if grep -q 'actions/upload-artifact@v4' "$PROJECT_DIR/agents/e2e-runner.md" \
    && grep -q 'node-version: 22' "$PROJECT_DIR/agents/e2e-runner.md" \
    && grep -q 'context.tracing.start' "$PROJECT_DIR/agents/e2e-runner.md" \
    && grep -q 'OWASP Top 10 2021' "$PROJECT_DIR/agents/security-reviewer.md" \
    && grep -q 'Server-Side Request Forgery' "$PROJECT_DIR/agents/security-reviewer.md"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}
