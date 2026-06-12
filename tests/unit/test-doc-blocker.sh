#!/bin/bash
# tests/unit/test-doc-blocker.sh - deny-by-pattern doc guard tests

_doc_blocker_script="$PROJECT_DIR/features/doc-blocker/scripts/check-doc-write.sh"

_run_doc_blocker_path() {
  local path="$1"
  printf '{"tool_input":{"file_path":"%s"}}' "$path" | "$_doc_blocker_script"
}

_doc_blocker_decision() {
  local path="$1"
  _run_doc_blocker_path "$path" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || printf 'allow'
}

{
  test_name="doc-blocker: kit output paths stay allowed (even slop-like names)"
  allowed=(
    "$PROJECT_DIR/HANDOVER.md"
    "$PROJECT_DIR/research.md"
    "$PROJECT_DIR/docs/CONTRIB.md"
    "$PROJECT_DIR/docs/RUNBOOK.md"
    "$PROJECT_DIR/docs/CODEMAPS/architecture.md"
    "$PROJECT_DIR/codemaps/backend.md"
    "$PROJECT_DIR/docs/GUIDES/setup.md"
    "$PROJECT_DIR/.reports/dead-code-analysis.md"
    "$PROJECT_DIR/.reports/codemap-diff.txt"
    "$PROJECT_DIR/.reports/SUMMARY.md"
    "$PROJECT_DIR/docs/CODEMAPS/ANALYSIS.md"
    "$PROJECT_DIR/.claude/evals/feature-name.md"
    "$HOME/.claude/skills/learned/pattern.md"
    "$PROJECT_DIR/.specify/memory/constitution.md"
  )
  ok_all=true
  for path in "${allowed[@]}"; do
    [[ "$(_doc_blocker_decision "$path")" == "allow" ]] || ok_all=false
  done
  if [[ "$ok_all" == "true" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="doc-blocker: general docs pass without confirmation (inverted from allowlist)"
  general=(
    "$PROJECT_DIR/CHANGELOG.md"
    "$PROJECT_DIR/LICENSE.txt"
    "$PROJECT_DIR/docs/architecture.md"
    "$PROJECT_DIR/docs/adr/0001-record.md"
    "$PROJECT_DIR/release-notes.md"
    "$PROJECT_DIR/market-research.md"
  )
  ok_all=true
  for path in "${general[@]}"; do
    [[ "$(_doc_blocker_decision "$path")" == "allow" ]] || ok_all=false
  done
  if [[ "$ok_all" == "true" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="doc-blocker: slop doc names are downgraded to a permission ask (exit 0)"
  slop=(
    "$PROJECT_DIR/SUMMARY.md"
    "$PROJECT_DIR/FINAL_REPORT.md"
    "$PROJECT_DIR/analysis.md"
    "$PROJECT_DIR/sub/dir/FINDINGS.md"
    "$PROJECT_DIR/NOTES_2026.txt"
    "$PROJECT_DIR/results.md"
  )
  ok_all=true
  for path in "${slop[@]}"; do
    rc=0
    out="$(_run_doc_blocker_path "$path")" || rc=$?
    [[ "$rc" -eq 0 ]] || ok_all=false
    [[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty')" == "ask" ]] || ok_all=false
    printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("doc-blocker")' >/dev/null || ok_all=false
  done
  if [[ "$ok_all" == "true" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="doc-blocker: non-doc files pass and hard blocks are gone (no exit 2)"
  rc_code=0
  _run_doc_blocker_path "$PROJECT_DIR/src/main.ts" >/dev/null || rc_code=$?
  rc_slop=0
  _run_doc_blocker_path "$PROJECT_DIR/SUMMARY.md" >/dev/null || rc_slop=$?
  if [[ "$rc_code" -eq 0 && "$rc_slop" -eq 0 ]] \
    && ! grep -q 'exit 2' "$_doc_blocker_script"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="doc-blocker: feature deploys its external hook script"
  if grep -q '__HOME__/.claude/hooks/doc-blocker/check-doc-write.sh' "$PROJECT_DIR/features/doc-blocker/hooks.json" \
    && grep -q '\[doc-blocker\]=true' "$PROJECT_DIR/lib/features.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}
