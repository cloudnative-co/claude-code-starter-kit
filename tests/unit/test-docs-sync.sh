#!/bin/bash
# tests/unit/test-docs-sync.sh - Documentation drift checks

{
  test_name="docs-sync: CLAUDE.md stays below doc-size hard limit"
  _claude_lines="$(wc -l < "$PROJECT_DIR/CLAUDE.md" | tr -d ' ')"
  if [[ "$_claude_lines" -le 300 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="docs-sync: CLAUDE.md reflects current deploy/update behavior"
  if ! grep -q 'AGENTS.md.template' "$PROJECT_DIR/CLAUDE.md" \
    && grep -q 'existing manifest' "$PROJECT_DIR/CLAUDE.md" \
    && grep -q 'cleanup_paths' "$PROJECT_DIR/CLAUDE.md" \
    && grep -q 'lib/progress.sh' "$PROJECT_DIR/CLAUDE.md" \
    && grep -q 'lib/codex-setup.sh' "$PROJECT_DIR/CLAUDE.md"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="docs-sync: wizard mapping covers current feature flags"
  _ok=true
  for _doc in "$PROJECT_DIR/docs/wizard-config-mapping.md" "$PROJECT_DIR/docs/wizard-config-mapping.en.md"; do
    for _flag in ENABLE_BIOME_HOOKS ENABLE_WEB_CONTENT_UPDATE ENABLE_FEATURE_RECOMMENDATION ENABLE_NO_FLICKER; do
      grep -q "$_flag" "$_doc" || _ok=false
    done
  done
  if [[ "$_ok" == "true" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="docs-sync: web content docs describe opt-in updates and current deps/tests"
  if grep -q 'opt-in' "$PROJECT_DIR/skills/web-content-extraction/README.md" \
    && grep -q 'undici' "$PROJECT_DIR/skills/web-content-extraction/README.md" \
    && grep -q 'defuddle-url.test.mjs' "$PROJECT_DIR/skills/web-content-extraction/README.md" \
    && grep -q 'web-content-update' "$PROJECT_DIR/skills/web-content-extraction/SKILL.md"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="docs-sync: statusline description matches implementation"
  if jq -e '.description | test("5h/7d rate limits")' "$PROJECT_DIR/features/statusline/feature.json" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}
