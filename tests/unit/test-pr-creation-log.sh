#!/bin/bash
# tests/unit/test-pr-creation-log.sh - Unit tests for pr-creation-log hook config

# shellcheck source=lib/colors.sh
source "$PROJECT_DIR/lib/colors.sh"
# shellcheck source=lib/json-builder.sh
source "$PROJECT_DIR/lib/json-builder.sh"

_pr_tmp="$(mktemp -d)"
_SETUP_TMP_FILES+=("$_pr_tmp")
_pr_hooks="$PROJECT_DIR/features/pr-creation-log/hooks.json"
_pr_settings="$_pr_tmp/settings.json"

if jq -e '.hooks.PostToolUse[0].hooks[0].if == "Bash(gh pr create *)"' "$_pr_hooks" >/dev/null 2>&1 \
  && jq -e '.hooks.PostToolUse[0].hooks[0].async == true' "$_pr_hooks" >/dev/null 2>&1; then
  pass "pr-creation-log: hooks.json includes if condition and async execution"
else
  fail "pr-creation-log: hooks.json should include if condition and async execution"
fi

if jq -e '.hooks.PostToolUse[0].hooks[0].command | contains("grep -qE '\\''gh pr create'\\''") | not' "$_pr_hooks" >/dev/null 2>&1; then
  pass "pr-creation-log: shell command no longer re-checks gh pr create"
else
  fail "pr-creation-log: shell command should not re-check gh pr create"
fi

build_settings_json \
  "$PROJECT_DIR/config/settings-base.json" \
  "$PROJECT_DIR/config/permissions.json" \
  "$_pr_settings" \
  "$_pr_hooks" >/dev/null

if jq -e '.hooks.PostToolUse[] | select(.matcher == "tool == \"Bash\"") | .hooks[0].if == "Bash(gh pr create *)"' "$_pr_settings" >/dev/null 2>&1 \
  && jq -e '.hooks.PostToolUse[] | select(.matcher == "tool == \"Bash\"") | .hooks[0].async == true' "$_pr_settings" >/dev/null 2>&1; then
  pass "pr-creation-log: merged settings keep if condition and async execution"
else
  fail "pr-creation-log: merged settings should keep if condition and async execution"
fi

_pr_script="$_pr_tmp/pr-hook.sh"
_pr_input="$_pr_tmp/input.json"
_pr_out="$_pr_tmp/out.json"
_pr_err="$_pr_tmp/err.log"

jq -r '.hooks.PostToolUse[0].hooks[0].command' "$_pr_hooks" >"$_pr_script"
cat >"$_pr_input" <<'EOF'
{
  "tool_input": {
    "command": "gh pr create --fill"
  },
  "tool_output": {
    "output": "Created pull request: https://github.com/cloudnative-co/claude-code-starter-kit/pull/99"
  }
}
EOF

bash "$_pr_script" <"$_pr_input" >"$_pr_out" 2>"$_pr_err"

if assert_equals "$(cat "$_pr_input")" "$(cat "$_pr_out")" \
  && assert_matches "\\[Hook\\] PR created: https://github.com/cloudnative-co/claude-code-starter-kit/pull/99" "$(cat "$_pr_err")"; then
  pass "pr-creation-log: command extracts PR URL and passes input through"
else
  fail "pr-creation-log: command should extract PR URL and pass input through"
fi
