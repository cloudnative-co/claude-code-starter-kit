#!/bin/bash
# tests/unit/test-pr-creation-log.sh - Unit tests for pr-creation-log hook config

# shellcheck source=lib/colors.sh
source "$PROJECT_DIR/lib/colors.sh"
# shellcheck source=lib/json-builder.sh
source "$PROJECT_DIR/lib/json-builder.sh"
# shellcheck source=lib/features.sh
source "$PROJECT_DIR/lib/features.sh"
# shellcheck source=lib/template.sh
source "$PROJECT_DIR/lib/template.sh"
# shellcheck source=lib/snapshot.sh
source "$PROJECT_DIR/lib/snapshot.sh"
# shellcheck source=lib/merge.sh
source "$PROJECT_DIR/lib/merge.sh"
# shellcheck source=lib/dryrun.sh
source "$PROJECT_DIR/lib/dryrun.sh"
# shellcheck source=lib/deploy.sh
source "$PROJECT_DIR/lib/deploy.sh"

_pr_tmp="$(mktemp -d)"
_SETUP_TMP_FILES+=("$_pr_tmp")
_pr_hooks="$PROJECT_DIR/features/pr-creation-log/hooks.json"
_pr_settings="$_pr_tmp/settings.json"
# shellcheck disable=SC2034  # build_settings_file reads feature flags via indirect expansion
ENABLE_PR_CREATION_LOG="true"

if jq -e '.hooks.PostToolUse[0].hooks[0].if == "Bash(gh pr create *)"' "$_pr_hooks" >/dev/null 2>&1 \
  && jq -e '.hooks.PostToolUse[0].hooks[0].async == true' "$_pr_hooks" >/dev/null 2>&1; then
  pass "pr-creation-log: hook fragment declares if and async"
else
  fail "pr-creation-log: hook fragment should declare if and async"
fi

_pr_command="$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$_pr_hooks")"
if [[ "$_pr_command" == "__HOME__/.claude/hooks/pr-creation-log/log-pr.sh" ]] \
  && grep -q "tool_response.stdout" "$PROJECT_DIR/features/pr-creation-log/scripts/log-pr.sh" \
  && ! grep -q "tool_output" "$PROJECT_DIR/features/pr-creation-log/scripts/log-pr.sh"; then
  pass "pr-creation-log: hook uses external script and real tool_response schema"
else
  fail "pr-creation-log: hook should use external script with tool_response schema"
fi

# Select this feature's entry by its command, never by matcher.
# `.hooks.PostToolUse[] | select(.matcher == "Bash")` emits one output per
# matching entry and `jq -e` derives its exit code from the LAST one, so a
# second Bash-matcher PostToolUse hook would silently decide the verdict,
# masking exactly the regression this check exists to catch. Collect first,
# then assert on the whole set: `length == 1` pins the entry and `all(...)`
# cannot be satisfied by some other entry (`any(...)` would still pass on a
# regressed pr-creation-log entry). Selection walks the PARENT PostToolUse
# entries (not the inner hooks) so the matcher stays visible: this feature must
# remain bound to matcher "Bash".
_pr_entries='[.hooks.PostToolUse[]?
  | select(any(.hooks[]?; (.command? // "") | contains("pr-creation-log/log-pr.sh")))]'

_pr_modern_hook_ok() { # <settings-file>
  jq -e "$_pr_entries
    | length == 1
      and all(.matcher == \"Bash\"
              and (.hooks | length == 1)
              and all(.hooks[]; .if == \"Bash(gh pr create *)\" and .async == true))" \
    "$1" >/dev/null 2>&1
}

build_settings_json \
  "$PROJECT_DIR/config/settings-base.json" \
  "$PROJECT_DIR/config/permissions.json" \
  "$_pr_settings" \
  "$_pr_hooks" >/dev/null

if _pr_modern_hook_ok "$_pr_settings"; then
  pass "pr-creation-log: merged settings keep if condition and async execution"
else
  fail "pr-creation-log: merged settings should keep if condition and async execution"
fi

# The hook shape does not depend on the installed Claude Code (the < 2.1.89
# fallback fragment was retired in v0.79.0, #136). The old CLI is built first so
# this case does not lean on anything an earlier build left in the shell.
_pr_old_cli_settings="$_pr_tmp/settings-old-cli.json"
mkdir -p "$_pr_tmp/claude-old-bin"
cat >"$_pr_tmp/claude-old-bin/claude" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' '2.1.88 (Claude Code)'
fi
EOF
chmod +x "$_pr_tmp/claude-old-bin/claude"
PATH="$_pr_tmp/claude-old-bin:$PATH" build_settings_file "$_pr_old_cli_settings" >/dev/null

if _pr_modern_hook_ok "$_pr_old_cli_settings" \
  && ! grep -q 'PR_CREATION_LOG_LEGACY' "$_pr_old_cli_settings"; then
  pass "pr-creation-log: an old Claude Code gets the same if/async hook"
else
  fail "pr-creation-log: the hook shape must not depend on the installed Claude Code"
fi

_pr_supported_settings="$_pr_tmp/settings-supported.json"
mkdir -p "$_pr_tmp/claude-current-bin"
cat >"$_pr_tmp/claude-current-bin/claude" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' '2.1.89 (Claude Code)'
fi
EOF
chmod +x "$_pr_tmp/claude-current-bin/claude"
PATH="$_pr_tmp/claude-current-bin:$PATH" build_settings_file "$_pr_supported_settings" >/dev/null

if _pr_modern_hook_ok "$_pr_supported_settings" \
  && cmp -s "$_pr_supported_settings" "$_pr_old_cli_settings"; then
  pass "pr-creation-log: supported Claude Code gets if/async hook"
else
  fail "pr-creation-log: supported Claude Code should get if/async hook"
fi

# The arity guard itself. Regress the pr-creation-log entry (no `if`, no
# `async`) and append a second Bash-matcher PostToolUse entry that does carry
# both: the assertion must now fail. A `select(.matcher == "Bash") | .hooks[0]
# | .if == ...` filter returns 0 here (the appended entry is the last output),
# and so does an `any(...)` rewrite — only selecting by command and collapsing
# with `all(...)` reports the regression. The reverse arrangement (intact
# entry, unrelated second hook without `if`) must keep passing.
_pr_arity_settings="$_pr_tmp/settings-two-bash.json"
jq '.hooks.PostToolUse = [
      {"matcher":"Bash","hooks":[{"type":"command",
        "command":"__HOME__/.claude/hooks/pr-creation-log/log-pr.sh"}]},
      {"matcher":"Bash","hooks":[{"type":"command",
        "command":"/somewhere/future-hook.sh",
        "if":"Bash(gh pr create *)","async":true}]}
    ]' "$_pr_supported_settings" > "$_pr_arity_settings"
_pr_arity_ok_settings="$_pr_tmp/settings-two-bash-ok.json"
jq '.hooks.PostToolUse = [
      {"matcher":"Bash","hooks":[{"type":"command",
        "command":"__HOME__/.claude/hooks/pr-creation-log/log-pr.sh",
        "if":"Bash(gh pr create *)","async":true}]},
      {"matcher":"Bash","hooks":[{"type":"command",
        "command":"/somewhere/future-hook.sh"}]}
    ]' "$_pr_supported_settings" > "$_pr_arity_ok_settings"

if ! _pr_modern_hook_ok "$_pr_arity_settings" \
  && _pr_modern_hook_ok "$_pr_arity_ok_settings"; then
  pass "pr-creation-log: a second Bash-matcher hook cannot decide the verdict"
else
  fail "pr-creation-log: assertions must select this feature's entry by command"
fi

_pr_script="$_pr_tmp/pr-hook.sh"
_pr_input="$_pr_tmp/input.json"
_pr_out="$_pr_tmp/out.json"
_pr_err="$_pr_tmp/err.log"

cp "$PROJECT_DIR/features/pr-creation-log/scripts/log-pr.sh" "$_pr_script"
cat >"$_pr_input" <<'EOF'
{
  "tool_input": {
    "command": "gh pr create --fill"
  },
  "tool_response": {
    "stdout": "Created pull request: https://github.com/cloudnative-co/claude-code-starter-kit/pull/99",
    "stderr": ""
  }
}
EOF

bash "$_pr_script" <"$_pr_input" >"$_pr_out" 2>"$_pr_err"

if assert_empty "$(cat "$_pr_out")" \
  && assert_matches "\\[Hook\\] PR created: https://github.com/cloudnative-co/claude-code-starter-kit/pull/99" "$(cat "$_pr_err")"; then
  pass "pr-creation-log: command extracts PR URL without stdin passthrough"
else
  fail "pr-creation-log: command should extract PR URL without stdin passthrough"
fi
