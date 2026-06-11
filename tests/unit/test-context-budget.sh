#!/bin/bash
# tests/unit/test-context-budget.sh - Always-loaded context budget checks

{
  test_name="context-budget: always-loaded rules stay under 200 lines"
  rules_lines="$(find "$PROJECT_DIR/rules" -type f -name '*.md' -print0 | xargs -0 wc -l | awk '/ total$/ {print $1}')"
  rules_lines="${rules_lines:-0}"
  if [[ "$rules_lines" -gt 0 && "$rules_lines" -le 200 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="context-budget: standard plugin default set is narrow"
  standard_plugins="$(jq -r '[.plugins[] | select(.profiles | index("standard")) | .name] | join(",")' "$PROJECT_DIR/config/plugins.json")"
  standard_count="$(jq '[.plugins[] | select(.profiles | index("standard"))] | length' "$PROJECT_DIR/config/plugins.json")"
  if [[ "$standard_count" -le 5 ]] \
    && [[ "$standard_plugins" == *"security-guidance"* ]] \
    && [[ "$standard_plugins" == *"commit-commands"* ]] \
    && [[ "$standard_plugins" != *"document-skills"* ]] \
    && [[ "$standard_plugins" != *"example-skills"* ]] \
    && [[ "$standard_plugins" != *"superpowers"* ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="context-budget: always-loaded rules avoid stale model/tool/language-specific guidance"
  stale_pattern='Sonnet 4\.5|Opus 4\.5|Zed|tsc|allowedTools|ALL required|No user prompt needed|Attribution disabled|useDebounce|zod|console\.log|RED|GREEN|REFACTOR'
  if ! grep -RE "$stale_pattern" "$PROJECT_DIR/rules" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="permissions: allow list omits removed Claude Code tool names"
  if jq -e '
    (.permissions.allow // []) as $allow
    | ($allow | index("MultiEdit") | not)
    and ($allow | index("TodoRead") | not)
    and ($allow | index("LS") | not)
    and ($allow | index("Edit") != null)
    and ($allow | index("TodoWrite") != null)
  ' "$PROJECT_DIR/config/permissions.json" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  # Fable 5 safety-classifier regression guard (#76 / #90): the kit-managed
  # CLAUDE.md section is assembled from CLAUDE.md.base + injected partials and
  # is ALWAYS in context. Keep the per-language total small so cumulative
  # security-adjacent prose can't re-trigger the classifier.
  test_name="context-budget: kit-managed CLAUDE.md sources stay minimal per language"
  _cb_ok=true
  for _cb_lang in ja en; do
    _cb_total="$(cat "$PROJECT_DIR/i18n/$_cb_lang/CLAUDE.md.base" \
      "$PROJECT_DIR/i18n/$_cb_lang/partials/"*.md \
      "$PROJECT_DIR/features/codex-plugin/CLAUDE.md.partial.$_cb_lang" 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${_cb_total:-0}" -le 0 || "${_cb_total:-0}" -gt 60 ]]; then
      _cb_ok=false
    fi
  done
  if [[ "$_cb_ok" == "true" ]]; then
    pass "$test_name"
  else
    fail "$test_name (ja/en kit-managed sources exceed 60 lines)"
  fi
}
