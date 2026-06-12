#!/bin/bash
# tests/unit/test-content-cleanup.sh - Commands/skills hygiene checks

{
  test_name="content-cleanup: duplicated or dead command/skill payloads are removed"
  if [[ ! -e "$PROJECT_DIR/commands/code-review.md" ]] \
    && [[ ! -d "$PROJECT_DIR/skills/continuous-learning" ]] \
    && [[ ! -e "$PROJECT_DIR/skills/strategic-compact/suggest-compact.sh" ]] \
    && [[ ! -e "$PROJECT_DIR/features/statusline/scripts/statusline-command.sh" ]] \
    && [[ ! -d "$PROJECT_DIR/docs/superpowers" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="content-cleanup: dead helpers and strings stay removed"
  if ! grep -Rqs 'process_template()' "$PROJECT_DIR/lib" \
    && ! grep -Rqs '_extract_user_section()' "$PROJECT_DIR/lib" \
    && ! grep -Rqs 'language_name()' "$PROJECT_DIR/lib" \
    && ! grep -Rqs 'WIN_BUILD' "$PROJECT_DIR/lib/detect.sh" \
    && ! grep -Rqs 'STR_CONFIRM_BIOME=' "$PROJECT_DIR/i18n" \
    && ! grep -Rqs 'STR_DRYRUN_MERGED=' "$PROJECT_DIR/i18n"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="content-cleanup: retired managed files are removed during update"
  if grep -q '_remove_retired_managed_files' "$PROJECT_DIR/lib/update.sh" \
    && grep -q 'Removed retired managed file' "$PROJECT_DIR/lib/update.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="content-cleanup: bulky slash commands are compact entrypoints"
  _cmd_lines_ok=true
  for _cmd in tdd e2e verify eval plan; do
    _lines="$(wc -l < "$PROJECT_DIR/commands/${_cmd}.md" | tr -d ' ')"
    [[ "$_lines" -le 80 ]] || _cmd_lines_ok=false
  done
  if [[ "$_cmd_lines_ok" == "true" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="content-cleanup: command docs omit stale project residue"
  stale_pattern='PMX|Privy|Solana|Supabase|Real Money|upload-artifact@v3|node-version: 18|Opus 4\.6|/rpi:|browser\.startTracing|videosPath|market liquidity|semantic search'
  if ! grep -RE "$stale_pattern" "$PROJECT_DIR/commands" "$PROJECT_DIR/skills/security-review" "$PROJECT_DIR/skills/strategic-compact" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="content-cleanup: command entrypoints defer to canonical skills/agents"
  if grep -q 'verification-loop' "$PROJECT_DIR/commands/verify.md" \
    && grep -q 'eval-harness' "$PROJECT_DIR/commands/eval.md" \
    && grep -q 'tdd-guide' "$PROJECT_DIR/commands/tdd.md" \
    && grep -q 'e2e-runner' "$PROJECT_DIR/commands/e2e.md" \
    && grep -q 'web-content-extraction skill' "$PROJECT_DIR/commands/web-article.md" \
    && grep -q 'web-content-extraction skill' "$PROJECT_DIR/commands/web-source-review.md" \
    && grep -q 'web-content-extraction skill' "$PROJECT_DIR/commands/oss-analyze.md"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="content-cleanup: orchestrate prefers parallel reviews over fixed chains"
  if ! grep -q 'explorer ->' "$PROJECT_DIR/commands/orchestrate.md" \
    && ! grep -q 'planner -> tdd-guide -> code-reviewer' "$PROJECT_DIR/commands/orchestrate.md" \
    && grep -q 'spawn independent reviewers in parallel' "$PROJECT_DIR/commands/orchestrate.md"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="content-cleanup: seed memory distribution is retired"
  if [[ ! -d "$PROJECT_DIR/memory" ]] \
    && ! grep -q 'PROJECT_DIR/memory' "$PROJECT_DIR/lib/deploy.sh" \
    && ! grep -q 'INSTALL_MEMORY' "$PROJECT_DIR/setup.sh" \
    && grep -q 'INSTALL_MEMORY' <<< "$(grep '_CONFIG_LEGACY_KEYS=' "$PROJECT_DIR/wizard/registry.sh")"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="content-cleanup: settings-base has no generation-dependent pins (env / effortLevel)"
  if ! jq -e 'has("env") or has("effortLevel")' "$PROJECT_DIR/config/settings-base.json" >/dev/null \
    && jq -e '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS == "1"' "$PROJECT_DIR/features/agent-teams/hooks.json" >/dev/null \
    && grep -q '\[agent-teams\]=ENABLE_AGENT_TEAMS' "$PROJECT_DIR/lib/features.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}
