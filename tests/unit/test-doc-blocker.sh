#!/bin/bash
# tests/unit/test-doc-blocker.sh - doc-blocker path allowlist tests

_doc_blocker_script="$PROJECT_DIR/features/doc-blocker/scripts/check-doc-write.sh"

_run_doc_blocker_path() {
  local path="$1"
  printf '{"tool_input":{"file_path":"%s"}}' "$path" | "$_doc_blocker_script" >/dev/null
}

{
  test_name="doc-blocker: allows Starter Kit command and agent output paths"
  allowed=(
    "$PROJECT_DIR/HANDOVER.md"
    "$PROJECT_DIR/research.md"
    "$PROJECT_DIR/notes/research.md"
    "$PROJECT_DIR/sessions/HANDOVER.md"
    "$PROJECT_DIR/docs/CONTRIB.md"
    "$PROJECT_DIR/docs/RUNBOOK.md"
    "$PROJECT_DIR/docs/CODEMAPS/frontend.md"
    "$PROJECT_DIR/docs/CODEMAPS/architecture.md"
    "$PROJECT_DIR/codemaps/backend.md"
    "$PROJECT_DIR/docs/GUIDES/setup.md"
    "$PROJECT_DIR/docs/DELETION_LOG.md"
    "$PROJECT_DIR/.reports/dead-code-analysis.md"
    "$PROJECT_DIR/.reports/codemap-diff.txt"
    "$PROJECT_DIR/.claude/evals/feature-name.md"
    "$HOME/.claude/skills/learned/pattern.md"
    "$PROJECT_DIR/.specify/memory/constitution.md"
  )
  ok_all=true
  for path in "${allowed[@]}"; do
    _run_doc_blocker_path "$path" || ok_all=false
  done

  if [[ "$ok_all" == "true" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="doc-blocker: still blocks ad-hoc markdown and text files"
  if ! _run_doc_blocker_path "$PROJECT_DIR/random-notes.md" \
    && ! _run_doc_blocker_path "$PROJECT_DIR/tmp/scratch.txt"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="doc-blocker: rejects suffix variants of research.md / HANDOVER.md with exit 2"
  rc_research=0
  _run_doc_blocker_path "$PROJECT_DIR/market-research.md" 2>/dev/null || rc_research=$?
  rc_handover=0
  _run_doc_blocker_path "$PROJECT_DIR/PROJECT-HANDOVER.md" 2>/dev/null || rc_handover=$?

  if [[ "$rc_research" -eq 2 && "$rc_handover" -eq 2 ]]; then
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
