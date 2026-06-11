#!/bin/bash
# tests/unit/test-strategic-compact.sh - Unit tests for strategic-compact hook script

_sc_tmp="$(mktemp -d)"
_SETUP_TMP_FILES+=("$_sc_tmp")
_sc_script="$PROJECT_DIR/features/strategic-compact/scripts/suggest-compact.sh"
_sc_runtime="$_sc_tmp/runtime"
mkdir -p "$_sc_runtime"

_sc_input_a='{"session_id":"session-a","tool_name":"Edit"}'
_sc_input_b='{"session_id":"session-b","tool_name":"Write"}'

_sc_seed_rc=0
XDG_RUNTIME_DIR="$_sc_runtime" COMPACT_THRESHOLD=5 bash "$_sc_script" <<< "$_sc_input_a" >/dev/null 2>/dev/null || _sc_seed_rc=$?
XDG_RUNTIME_DIR="$_sc_runtime" COMPACT_THRESHOLD=5 bash "$_sc_script" <<< "$_sc_input_a" >/dev/null 2>/dev/null || _sc_seed_rc=$?
XDG_RUNTIME_DIR="$_sc_runtime" COMPACT_THRESHOLD=5 bash "$_sc_script" <<< "$_sc_input_b" >/dev/null 2>/dev/null || _sc_seed_rc=$?

if [[ "$_sc_seed_rc" -eq 0 ]] \
  && assert_equals "2" "$(cat "$_sc_runtime/tool-count-session-a")" \
  && assert_equals "1" "$(cat "$_sc_runtime/tool-count-session-b")" \
  && [[ ! -e "$_sc_runtime/tool-count-$$" ]]; then
  pass "strategic-compact: counter is keyed by session_id instead of process id"
else
  fail "strategic-compact: counter should accumulate per session_id"
fi

_sc_out="$_sc_tmp/out.json"
_sc_err="$_sc_tmp/err.log"
_sc_warn_rc=0
XDG_RUNTIME_DIR="$_sc_runtime" COMPACT_THRESHOLD=5 bash "$_sc_script" <<< "$_sc_input_a" >"$_sc_out" 2>"$_sc_err" || _sc_warn_rc=$?

if [[ "$_sc_warn_rc" -eq 0 ]] \
  && assert_equals "$_sc_input_a" "$(cat "$_sc_out")" \
  && assert_matches "\\[FIC\\] Context ~50% used \\(3 tool calls\\)" "$(cat "$_sc_err")"; then
  pass "strategic-compact: hook passes input through and emits threshold warning"
else
  fail "strategic-compact: hook should pass input through and warn at threshold"
fi
