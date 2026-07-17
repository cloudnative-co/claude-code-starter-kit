#!/bin/bash
# tests/unit/test-setup-refactor.sh - setup.sh functionization guards

{
  test_name="setup-refactor: top-level setup flow is driven by setup_main"
  if grep -q '^setup_main()' "$PROJECT_DIR/setup.sh" \
    && [[ "$(grep -cF 'setup_main "$@"' "$PROJECT_DIR/setup.sh")" -eq 1 ]] \
    && grep -q 'setup_stage1 "$@"' "$PROJECT_DIR/setup.sh" \
    && grep -q '^setup_source_stage2()' "$PROJECT_DIR/setup.sh" \
    && grep -q '^setup_deploy()' "$PROJECT_DIR/setup.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="setup-refactor: setup_main is guarded so sourcing does not run it"
  if grep -qF 'if [[ "${BASH_SOURCE[0]:-}" == "" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then' "$PROJECT_DIR/setup.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="setup-refactor: MDM prerequisite failures retain exit 10"
  if (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/prerequisites.sh"
    unset KIT_MDM_MANAGED
    [[ "$(_setup_prerequisite_exit_code)" == 1 ]] || exit 1
    export KIT_MDM_MANAGED=true
    [[ "$(_setup_prerequisite_exit_code)" == 10 ]] || exit 1
    [[ "$(grep -cF 'return "$(_setup_prerequisite_exit_code)"' "$PROJECT_DIR/setup.sh")" -eq 2 ]]
  ); then
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

# ---------------------------------------------------------------------------
# install_selected_plugins() behavior tests
#
# setup.sh を source すると set -euo pipefail / umask / trap がこのシェルに
# 漏れるため、必ずサブシェル ( ... ) 内で source し、アサーション材料
# (fake claude の呼び出しログ・関数出力・終了コード) はファイルに書いて
# 親シェルで判定する。
# ---------------------------------------------------------------------------

_ISP_DIR="$(mktemp -d)"
mkdir -p "$_ISP_DIR/bin"
cat > "$_ISP_DIR/bin/claude" <<'FAKE_CLAUDE'
#!/bin/bash
# Fake claude CLI: logs every invocation; `plugin list` output is controllable.
printf '%s\n' "$*" >> "${FAKE_CLAUDE_LOG:?}"
if [[ "${1:-}" == "plugin" && "${2:-}" == "list" ]]; then
  printf '%s\n' "${FAKE_CLAUDE_PLUGIN_LIST:-}"
  exit 0
fi
if [[ "${1:-}" == "plugin" && "${2:-}" == "marketplace" && "${3:-}" == "add" ]]; then
  if [[ "${FAKE_CLAUDE_MARKETPLACE_RC:-0}" -ne 0 ]]; then
    echo "fake-marketplace-error: cannot add ${4:-}" >&2
    exit "${FAKE_CLAUDE_MARKETPLACE_RC}"
  fi
  exit 0
fi
exit 0
FAKE_CLAUDE
chmod +x "$_ISP_DIR/bin/claude"

# _isp_run_case <selected_plugins> <plugin_list_output> <marketplace_rc> <with_claude>
#
# Runs install_selected_plugins in an isolated subshell with the fake claude.
# Results: $_ISP_DIR/calls.log (fake claude invocations, one per line),
#          $_ISP_DIR/out.log (function stdout+stderr), $_ISP_DIR/rc.txt (exit code)
_isp_run_case() {
  local _sel="$1" _plist="$2" _mp_rc="$3" _with_claude="$4"
  : > "$_ISP_DIR/calls.log"
  rm -f "$_ISP_DIR/out.log" "$_ISP_DIR/rc.txt"
  (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    # setup_stage1/setup_source_stage2 は実行しないので、依存を手動で source する
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/colors.sh"
    # _run_capture / _claude_plugin_list_has
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/codex-setup.sh"
    # STR_DEPLOY_PLUGINS_*
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/i18n/en/strings.sh"
    export FAKE_CLAUDE_LOG="$_ISP_DIR/calls.log"
    export FAKE_CLAUDE_PLUGIN_LIST="$_plist"
    export FAKE_CLAUDE_MARKETPLACE_RC="$_mp_rc"
    # install_selected_plugins (sourced from setup.sh) が参照するグローバル
    # shellcheck disable=SC2034
    SELECTED_PLUGINS="$_sel"
    # shellcheck disable=SC2034
    UPDATE_MODE="false"
    if [[ "$_with_claude" == "true" ]]; then
      PATH="$_ISP_DIR/bin:$PATH"
    else
      # claude が見つからない最小 PATH (この分岐は builtin のみで動く)
      PATH="/usr/bin:/bin"
    fi
    hash -r
    _rc=0
    install_selected_plugins > "$_ISP_DIR/out.log" 2>&1 || _rc=$?
    printf '%s\n' "$_rc" > "$_ISP_DIR/rc.txt"
  )
}

{
  test_name="install_selected_plugins: exact-match already-installed plugin skips install"
  if _isp_run_case "codex" "codex@1.0.0" 0 true \
    && grep -qx "plugin list" "$_ISP_DIR/calls.log" \
    && ! grep -q "plugin install" "$_ISP_DIR/calls.log" \
    && ! grep -q "plugin marketplace add" "$_ISP_DIR/calls.log" \
    && grep -qF "Already installed: codex" "$_ISP_DIR/out.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: prefix-similar name (codex-companion) does not mask codex"
  if _isp_run_case "codex" "codex-companion@1.0.0" 0 true \
    && grep -qx "plugin marketplace add anthropics/claude-plugins-official" "$_ISP_DIR/calls.log" \
    && grep -qx "plugin install codex --scope user" "$_ISP_DIR/calls.log" \
    && grep -qF "Plugin: codex" "$_ISP_DIR/out.log" \
    && ! grep -qF "Already installed:" "$_ISP_DIR/out.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: marketplace add failure warns with output and continues"
  if _isp_run_case "codex" "" 1 true \
    && grep -qF "Failed to add plugin marketplace" "$_ISP_DIR/out.log" \
    && grep -qF "fake-marketplace-error" "$_ISP_DIR/out.log" \
    && grep -qx "plugin install codex --scope user" "$_ISP_DIR/calls.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: missing claude CLI skips gracefully with hint"
  if _isp_run_case "codex" "" 0 false \
    && grep -qF "Skipping plugin install" "$_ISP_DIR/out.log" \
    && grep -qF "/install codex" "$_ISP_DIR/out.log" \
    && [[ ! -s "$_ISP_DIR/calls.log" ]] \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

rm -rf "$_ISP_DIR"
unset _ISP_DIR
unset -f _isp_run_case
