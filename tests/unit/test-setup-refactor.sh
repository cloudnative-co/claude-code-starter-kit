#!/bin/bash
# tests/unit/test-setup-refactor.sh - setup.sh functionization guards

{
  test_name="setup-refactor: top-level setup flow is driven by setup_main"
  if grep -q '^setup_main()' "$PROJECT_DIR/setup.sh" \
    && [[ "$(grep -c '^setup_main "$@"' "$PROJECT_DIR/setup.sh")" -eq 1 ]] \
    && grep -q 'setup_stage1 "$@"' "$PROJECT_DIR/setup.sh" \
    && grep -q '^setup_source_stage2()' "$PROJECT_DIR/setup.sh" \
    && grep -q '^setup_deploy()' "$PROJECT_DIR/setup.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="setup-refactor: Claude CLI install path is centralized"
  if grep -q '^_need_claude_cli_install()' "$PROJECT_DIR/setup.sh" \
    && grep -q '^_install_claude_cli()' "$PROJECT_DIR/setup.sh" \
    && grep -q '^install_claude_cli_if_needed()' "$PROJECT_DIR/setup.sh" \
    && [[ "$(grep -c 'curl -fsSL https://claude.ai/install.sh | bash' "$PROJECT_DIR/setup.sh")" -le 3 ]] \
    && [[ "$(grep -c 'powershell.exe -NoProfile -Command "irm https://claude.ai/install.ps1 | iex"' "$PROJECT_DIR/setup.sh")" -le 2 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="setup-refactor: plugin install block is a callable function using exact matching"
  if grep -q '^install_selected_plugins()' "$PROJECT_DIR/setup.sh" \
    && grep -q '_claude_plugin_list_has "$installed_plugins" "$p_name"' "$PROJECT_DIR/setup.sh" \
    && ! grep -q '_installed_plugins.*grep' "$PROJECT_DIR/setup.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="setup-refactor: final platform messaging uses detect helpers"
  if grep -q '^print_final_message()' "$PROJECT_DIR/setup.sh" \
    && grep -q 'elif is_wsl;' "$PROJECT_DIR/setup.sh" \
    && grep -q 'elif is_msys;' "$PROJECT_DIR/setup.sh" \
    && ! grep -q '_is_wsl_final' "$PROJECT_DIR/setup.sh" \
    && ! grep -q '_is_msys_final' "$PROJECT_DIR/setup.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="codex-setup: repeated MSYS PATH and MCP cleanup blocks are helperized"
  if grep -q '^_ensure_msys_npm_path()' "$PROJECT_DIR/lib/codex-setup.sh" \
    && grep -q '^_cleanup_legacy_mcp_with_report()' "$PROJECT_DIR/lib/codex-setup.sh" \
    && [[ "$(grep -c '_ensure_msys_npm_path' "$PROJECT_DIR/lib/codex-setup.sh")" -ge 3 ]] \
    && [[ "$(grep -c '_cleanup_legacy_mcp_with_report' "$PROJECT_DIR/lib/codex-setup.sh")" -ge 4 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}
