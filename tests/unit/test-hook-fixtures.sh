#!/bin/bash
# tests/unit/test-hook-fixtures.sh - Real Claude Code hook input fixture smoke tests

_hook_fixture_dir="$PROJECT_DIR/tests/fixtures/hooks"

_fixture_ok=true
for _fixture in "$_hook_fixture_dir"/*.json; do
  if ! jq -e '
    (.session_id | type == "string" and length > 0) and
    (.hook_event_name | type == "string" and length > 0) and
    (
      if .hook_event_name == "PreToolUse" then
        (.tool_name | type == "string") and (.tool_input | type == "object")
      elif .hook_event_name == "PostToolUse" then
        (.tool_name | type == "string") and (.tool_input | type == "object") and (.tool_response | type == "object")
      elif .hook_event_name == "SessionStart" then
        (.source | type == "string")
      elif .hook_event_name == "PreCompact" then
        (.trigger | type == "string")
      elif .hook_event_name == "PostCompact" then
        (.trigger | type == "string")
      elif .hook_event_name == "SessionEnd" then
        (.reason | type == "string")
      else
        false
      end
    )
  ' "$_fixture" >/dev/null 2>&1; then
    _fixture_ok=false
  fi
done

if [[ "$_fixture_ok" == "true" ]]; then
  pass "hook-fixtures: distributed hook fixtures use real event schemas"
else
  fail "hook-fixtures: hook fixtures should include required event fields"
fi

_hook_tmp="$(mktemp -d)"
_SETUP_TMP_FILES+=("$_hook_tmp")

_covered_events="$(jq -r '.hook_event_name' "$_hook_fixture_dir"/*.json | sort -u)"
_hook_events="$(
  find "$PROJECT_DIR/features" -maxdepth 3 -name 'hooks*.json' -print | sort | while read -r _hooks_file; do
    jq -r '.hooks? // {} | keys[]' "$_hooks_file" 2>/dev/null || true
  done | sort -u
)"
_missing_event=false
while IFS= read -r _event; do
  [[ -n "$_event" ]] || continue
  if ! printf '%s\n' "$_covered_events" | grep -qx "$_event"; then
    _missing_event=true
  fi
done <<< "$_hook_events"

if [[ "$_missing_event" == "false" ]]; then
  pass "hook-fixtures: fixture set covers every distributed hook event"
else
  fail "hook-fixtures: every distributed hook event should have a real-schema fixture"
fi

_pr_fixture="$_hook_fixture_dir/posttooluse-gh-pr-create.json"
_pr_err="$_hook_tmp/pr.err"
bash "$PROJECT_DIR/features/pr-creation-log/scripts/log-pr.sh" <"$_pr_fixture" >/dev/null 2>"$_pr_err"

if assert_matches "\\[Hook\\] PR created: https://github.com/cloudnative-co/claude-code-starter-kit/pull/99" "$(cat "$_pr_err")"; then
  pass "hook-fixtures: pr-creation-log consumes PostToolUse fixture"
else
  fail "hook-fixtures: pr-creation-log should consume PostToolUse fixture"
fi

_sc_fixture="$_hook_fixture_dir/pretooluse-edit-file.json"
_sc_out="$_hook_tmp/sc.out"
_sc_err="$_hook_tmp/sc.err"
_sc_runtime="$_hook_tmp/runtime"
mkdir -p "$_sc_runtime"

XDG_RUNTIME_DIR="$_sc_runtime" COMPACT_THRESHOLD=2 \
  bash "$PROJECT_DIR/features/strategic-compact/scripts/suggest-compact.sh" <"$_sc_fixture" >"$_sc_out" 2>"$_sc_err"

if cmp -s "$_sc_fixture" "$_sc_out" \
  && [[ -f "$_sc_runtime/tool-count-fixture-session-edit" ]] \
  && assert_matches "\\[FIC\\] Context ~50% used \\(1 tool calls\\)" "$(cat "$_sc_err")"; then
  pass "hook-fixtures: strategic-compact consumes PreToolUse fixture"
else
  fail "hook-fixtures: strategic-compact should preserve fixture input and key by session_id"
fi

_doc_fixture="$_hook_fixture_dir/pretooluse-write-doc.json"
_doc_err="$_hook_tmp/doc.err"
_doc_rc=0
bash "$PROJECT_DIR/features/doc-blocker/scripts/check-doc-write.sh" <"$_doc_fixture" >/dev/null 2>"$_doc_err" || _doc_rc=$?

if [[ "$_doc_rc" -eq 2 ]] \
  && assert_matches "\\[Hook\\] BLOCKED: Use README.md" "$(cat "$_doc_err")"; then
  pass "hook-fixtures: doc-blocker consumes PreToolUse Write fixture"
else
  fail "hook-fixtures: doc-blocker should block ad-hoc docs from fixture input"
fi

_post_edit_fixture="$_hook_tmp/post-edit.json"
_post_write_fixture="$_hook_tmp/post-write.json"
_pre_push_fixture="$_hook_fixture_dir/pretooluse-bash-git-push.json"
_pre_dev_fixture="$_hook_fixture_dir/pretooluse-bash-npm-dev.json"
_sample_ts="$_hook_tmp/sample.ts"
_sample_claude="$_hook_tmp/CLAUDE.md"
printf "console.log('fixture')\n" >"$_sample_ts"
printf "# CLAUDE\n" >"$_sample_claude"
jq --arg path "$_sample_ts" '.tool_input.file_path = $path' \
  "$_hook_fixture_dir/posttooluse-edit-file.json" >"$_post_edit_fixture"
jq --arg path "$_sample_claude" '.tool_input.file_path = $path' \
  "$_hook_fixture_dir/posttooluse-write-claude.json" >"$_post_write_fixture"

_script_smoke_ok=true
bash "$PROJECT_DIR/features/biome-hooks/scripts/format-file.sh" <"$_post_edit_fixture" >/dev/null 2>/dev/null || _script_smoke_ok=false
bash "$PROJECT_DIR/features/prettier-hooks/scripts/format-file.sh" <"$_post_edit_fixture" >/dev/null 2>/dev/null || _script_smoke_ok=false
bash "$PROJECT_DIR/features/console-log-guard/scripts/check-file.sh" <"$_post_edit_fixture" >/dev/null 2>"$_hook_tmp/console.err" || _script_smoke_ok=false
(cd "$_hook_tmp" && bash "$PROJECT_DIR/features/doc-size-guard/scripts/check-doc-size.sh" <"$_post_write_fixture" >/dev/null 2>/dev/null) || _script_smoke_ok=false
bash "$PROJECT_DIR/features/git-push-review/scripts/remind.sh" <"$_pre_push_fixture" >/dev/null 2>"$_hook_tmp/push.err" || _script_smoke_ok=false
bash "$PROJECT_DIR/features/feature-recommendation/scripts/check-pending.sh" <"$_hook_fixture_dir/sessionstart-startup.json" >/dev/null 2>/dev/null || _script_smoke_ok=false
HOME="$_hook_tmp/home" bash "$PROJECT_DIR/features/memory-persistence/scripts/pre-compact.sh" <"$_hook_fixture_dir/precompact-manual.json" >/dev/null 2>/dev/null || _script_smoke_ok=false
HOME="$_hook_tmp/home" bash "$PROJECT_DIR/features/memory-persistence/scripts/post-compact.sh" <"$_hook_fixture_dir/postcompact-manual.json" >/dev/null 2>/dev/null || _script_smoke_ok=false
HOME="$_hook_tmp/home" bash "$PROJECT_DIR/features/memory-persistence/scripts/session-start.sh" <"$_hook_fixture_dir/sessionstart-startup.json" >/dev/null 2>/dev/null || _script_smoke_ok=false
HOME="$_hook_tmp/home" bash "$PROJECT_DIR/features/memory-persistence/scripts/session-end.sh" <"$_hook_fixture_dir/sessionend-stop.json" >/dev/null 2>/dev/null || _script_smoke_ok=false

_tmux_rc=0
bash "$PROJECT_DIR/features/tmux-hooks/scripts/check-bash.sh" <"$_pre_dev_fixture" >/dev/null 2>"$_hook_tmp/tmux.err" || _tmux_rc=$?

if [[ "$_script_smoke_ok" == "true" ]] \
  && assert_matches "console\\.log found" "$(cat "$_hook_tmp/console.err")" \
  && assert_matches "Reminder: review your staged changes" "$(cat "$_hook_tmp/push.err")" \
  && [[ "$_tmux_rc" -eq 2 ]] \
  && assert_matches "Dev server must run in tmux" "$(cat "$_hook_tmp/tmux.err")"; then
  pass "hook-fixtures: distributed hook scripts consume real-schema fixtures"
else
  fail "hook-fixtures: distributed hook scripts should consume real-schema fixtures"
fi
