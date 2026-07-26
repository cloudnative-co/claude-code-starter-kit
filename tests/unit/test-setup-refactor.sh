#!/bin/bash
# tests/unit/test-setup-refactor.sh - setup.sh functionization guards
# shellcheck disable=SC2034 # Test globals are consumed by sourced setup functions.

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
  test_name="setup-refactor: managed CLI policy ignores fake PATH tr"
  _bool_policy_tmp="$(mktemp -d)"
  if (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    _prereq_mdm_managed() { return 0; }
    _prereq_mdm_fail_mode() { return 1; }
    _need_claude_cli_install() { return 0; }
    _mdm_prepare_native_claude_cli_reinstall() { return 0; }
    _install_claude_cli() { : > "$_bool_policy_tmp/installer"; return 1; }
    info() { :; }
    warn() { :; }
    STR_CLI_INSTALLING="Installing Claude CLI"
    tr() { printf 'false'; }
    KIT_MDM_INSTALL_CLAUDE_CLI=FaLsE
    unset KIT_MDM_REQUIRE_NATIVE_CLAUDE_CLI
    _mdm_claude_cli_install_disabled || exit 1
    _mdm_requires_native_claude_cli && exit 1
    install_claude_cli_if_needed || exit 1
    [[ ! -e "$_bool_policy_tmp/installer" ]] || exit 1

    KIT_MDM_INSTALL_CLAUDE_CLI=TrUe
    install_claude_cli_if_needed >/dev/null 2>&1 || true
    [[ -e "$_bool_policy_tmp/installer" ]] || exit 1
    KIT_MDM_REQUIRE_NATIVE_CLAUDE_CLI=TrUe
    _mdm_requires_native_claude_cli
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_bool_policy_tmp"
  unset _bool_policy_tmp
}

{
  test_name="setup-refactor: Claude CLI install path is centralized"
  if grep -q '^_need_claude_cli_install()' "$PROJECT_DIR/setup.sh" \
    && grep -q '^_install_claude_cli()' "$PROJECT_DIR/setup.sh" \
    && grep -q '^install_claude_cli_if_needed()' "$PROJECT_DIR/setup.sh" \
    && grep -q '/usr/bin/curl -qfsSL https://claude.ai/install.sh' \
      "$PROJECT_DIR/setup.sh" \
    && grep -q 'PATH=/usr/bin:/bin:/usr/sbin:/sbin.* /bin/bash' \
      "$PROJECT_DIR/setup.sh" \
    && grep -q 'for _proxy in HTTP_PROXY HTTPS_PROXY NO_PROXY' \
      "$PROJECT_DIR/setup.sh" \
    && ! grep -q 'install.sh | "$BASH"' "$PROJECT_DIR/setup.sh" \
    && grep -q '/usr/bin/readlink "$src"' "$PROJECT_DIR/setup.sh" \
    && grep -q '/usr/bin/readlink "$src"' "$PROJECT_DIR/wizard/wizard.sh" \
    && ! grep -q 'src="$(readlink ' "$PROJECT_DIR/setup.sh" \
    && ! grep -q 'src="$(readlink ' "$PROJECT_DIR/wizard/wizard.sh" \
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
    && grep -q '_selected_plugin_list_has "$installed_plugins" "$entry"' \
      "$PROJECT_DIR/setup.sh" \
    && grep -q '_plugin_provenance_list_has_exact' "$PROJECT_DIR/setup.sh" \
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
  test_name="setup-refactor: MDM native CLI Python helpers pass source via argv"
  if (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    for _python_helper in \
      _mdm_snapshot_native_cli \
      _mdm_native_cli_matches_snapshot \
      _mdm_native_claude_cli_present \
      _mdm_prepare_native_claude_cli_reinstall; do
      _python_helper_body="$(declare -f "$_python_helper")" || exit 1
      [[ "$_python_helper_body" == *' -I -B -c '* ]] || exit 1
      _python_helper_tail="${_python_helper_body#* -I -B -c }"
      [[ "$_python_helper_tail" != *' -I -B -c '* \
        && "$_python_helper_body" != *'<<'* ]] || exit 1
      case "$_python_helper" in
        _mdm_snapshot_native_cli|_mdm_native_cli_matches_snapshot)
          [[ "$_python_helper_body" \
            == *"' \"\$_target\" \"\$_snapshot\""* ]] || exit 1
          ;;
        *)
          [[ "$_python_helper_body" \
            == *"' \"\$_link\" \"\$_versions\""* ]] || exit 1
          ;;
      esac
    done
    ! grep -qF -- '<<' "$PROJECT_DIR/setup.sh"
  ); then
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

{
  test_name="setup-refactor: MDM native CLI contract rejects PATH-only and malformed symlink layouts"
  _native_tmp="$(mktemp -d)"
  _native_tmp="$(cd "$_native_tmp" && pwd -P)"
  if (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/prerequisites.sh"
    export HOME="$_native_tmp/home" KIT_MDM_MANAGED=true KIT_MDM_INSTALL_CLAUDE_CLI=true
    mkdir -p "$HOME/.local/bin" "$HOME/.local/share/claude/versions" "$_native_tmp/path-bin"
    _mdm_claude_codesign() {
      if [[ "${1:-}" == "--verify" ]]; then
        printf '%s\n' "$*" >> "$_native_tmp/codesign-calls"
        [[ "${_native_signature_trusted:-true}" == "true" ]]
        return
      fi
      printf '%s\n' \
        'Identifier=com.anthropic.claude-code' \
        'TeamIdentifier=Q6L2SF6YDW' \
        'Authority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)' >&2
    }
    printf '#!/bin/bash\nexit 0\n' > "$_native_tmp/path-bin/claude"
    chmod +x "$_native_tmp/path-bin/claude"
    PATH="$_native_tmp/path-bin:/usr/bin:/bin"
    hash -r
    _need_claude_cli_install || exit 1

    printf '#!/bin/bash\nexit 0\n' > "$HOME/.local/share/claude/versions/1.2.3"
    chmod +x "$HOME/.local/share/claude/versions/1.2.3"
    ln -s "$HOME/.local/share/claude/versions/1.2.3" "$HOME/.local/bin/claude"
    ! _need_claude_cli_install || exit 1
    grep -qF 'anchor apple generic' "$_native_tmp/codesign-calls" || exit 1
    grep -qF 'certificate leaf[subject.OU] = "Q6L2SF6YDW"' \
      "$_native_tmp/codesign-calls" || exit 1
    ! grep -qF "$HOME/.local/share/claude/versions/1.2.3" \
      "$_native_tmp/codesign-calls" || exit 1

    if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
      /bin/chmod +a "everyone deny delete" "$HOME" || exit 1
      ! _need_claude_cli_install || exit 1
      /bin/chmod -N "$HOME" || exit 1
    fi

    chmod 777 "$HOME/.local/share/claude/versions/1.2.3"
    _need_claude_cli_install || exit 1
    chmod 700 "$HOME/.local/share/claude/versions/1.2.3"

    chmod 777 "$HOME/.local/share/claude/versions"
    _need_claude_cli_install || exit 1
    chmod 755 "$HOME/.local/share/claude/versions"

    if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
      /bin/chmod +a "everyone deny write" \
        "$HOME/.local/share/claude/versions/1.2.3" || exit 1
      _need_claude_cli_install || exit 1
      /bin/chmod -N "$HOME/.local/share/claude/versions/1.2.3" || exit 1
    fi

    _native_signature_trusted=false
    _need_claude_cli_install || exit 1
    _native_signature_trusted=true

    chmod 600 "$HOME/.local/share/claude/versions/1.2.3"
    _need_claude_cli_install || exit 1
    chmod 700 "$HOME/.local/share/claude/versions/1.2.3"

    rm -f "$HOME/.local/bin/claude"
    ln -s ../share/claude/versions/1.2.3 "$HOME/.local/bin/claude"
    _need_claude_cli_install || exit 1

    rm -f "$HOME/.local/bin/claude"
    ln -s "$HOME/.local/share/claude/versions/1.2.3"$'\n' "$HOME/.local/bin/claude"
    _need_claude_cli_install
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_native_tmp"
  unset _native_tmp
}

{
  test_name="setup-refactor: MDM native CLI repair replaces only reserved invalid paths"
  _native_repair_tmp="$(mktemp -d)"
  _native_repair_tmp="$(cd "$_native_repair_tmp" && pwd -P)"
  if (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/prerequisites.sh"
    export HOME="$_native_repair_tmp/home" KIT_MDM_MANAGED=true
    export KIT_MDM_INSTALL_CLAUDE_CLI=true KIT_MDM_PREREQ_MODE=auto
    mkdir -p "$HOME/.local/bin" "$HOME/.local/share/claude/versions"
    printf '#!/bin/bash\nexit 0\n' > "$_native_repair_tmp/external-claude"
    chmod 700 "$_native_repair_tmp/external-claude"
    ln -s "$_native_repair_tmp/external-claude" "$HOME/.local/bin/claude"

    _mdm_claude_codesign() {
      if [[ "${1:-}" == "--verify" ]]; then
        ! /usr/bin/grep -qF 'exit 99' "${*: -1}"
        return
      fi
      printf '%s\n' \
        'Identifier=com.anthropic.claude-code' \
        'TeamIdentifier=Q6L2SF6YDW' \
        'Authority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)' >&2
    }
    _install_claude_cli() {
      [[ ! -e "$HOME/.local/bin/claude" && ! -L "$HOME/.local/bin/claude" ]] \
        || return 1
      [[ -f "$_native_repair_tmp/external-claude" ]] || return 1
      _native_install_count=$((_native_install_count + 1))
      local _version="${_native_install_count}.0.0"
      mkdir -p "$HOME/.local/bin" "$HOME/.local/share/claude/versions"
      printf '#!/bin/bash\nexit 0\n' \
        > "$HOME/.local/share/claude/versions/$_version"
      chmod 700 "$HOME/.local/share/claude/versions/$_version"
      ln -s "$HOME/.local/share/claude/versions/$_version" \
        "$HOME/.local/bin/claude"
    }
    _add_to_path_now_and_persist() { return 0; }
    STR_CLI_ALREADY="Claude CLI already installed"
    STR_CLI_INSTALLING="Installing Claude CLI"
    info() { :; }
    warn() { :; }
    ok() { :; }
    _native_install_count=0
    install_claude_cli_if_needed || exit 1
    [[ "$_native_install_count" -eq 1 \
      && -f "$_native_repair_tmp/external-claude" ]] || exit 1

    rm -f "$HOME/.local/bin/claude" \
      "$HOME/.local/share/claude/versions/1.0.0"
    printf '#!/bin/bash\nexit 99\n' \
      > "$HOME/.local/share/claude/versions/0.0.0"
    chmod 700 "$HOME/.local/share/claude/versions/0.0.0"
    ln -s "$HOME/.local/share/claude/versions/0.0.0" \
      "$HOME/.local/bin/claude"
    install_claude_cli_if_needed || exit 1
    [[ "$_native_install_count" -eq 2 \
      && ! -e "$HOME/.local/share/claude/versions/0.0.0" \
      && -f "$_native_repair_tmp/external-claude" ]] || exit 1

    chmod 777 "$HOME/.local/share/claude/versions"
    install_claude_cli_if_needed || exit 1
    [[ "$_native_install_count" -eq 3 ]] || exit 1
    install_claude_cli_if_needed || exit 1
    [[ "$_native_install_count" -eq 3 \
      && -x "$HOME/.local/share/claude/versions/3.0.0" ]] || exit 1

    if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
      /bin/chmod +a "everyone deny write" \
        "$HOME/.local/share/claude/versions" || exit 1
      install_claude_cli_if_needed || exit 1
      [[ "$_native_install_count" -eq 4 ]] || exit 1
      install_claude_cli_if_needed || exit 1
      [[ "$_native_install_count" -eq 4 \
        && -x "$HOME/.local/share/claude/versions/4.0.0" ]] || exit 1
    fi

    rm -f "$HOME/.local/bin/claude" \
      "$HOME/.local/share/claude/versions/3.0.0" \
      "$HOME/.local/share/claude/versions/4.0.0"
    rmdir "$HOME/.local/bin"
    mkdir -p "$_native_repair_tmp/unrelated-bin"
    printf 'preserve\n' > "$_native_repair_tmp/unrelated-bin/claude"
    ln -s "$_native_repair_tmp/unrelated-bin" "$HOME/.local/bin"
    ! _mdm_prepare_native_claude_cli_reinstall || exit 1
    [[ "$(cat "$_native_repair_tmp/unrelated-bin/claude")" == "preserve" ]] \
      || exit 1

    export HOME="$_native_repair_tmp/fresh-home"
    mkdir -p "$HOME"
    install_claude_cli_if_needed || exit 1
    if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
      _expected_install_count=5
    else
      _expected_install_count=4
    fi
    [[ "$_native_install_count" -eq "$_expected_install_count" \
      && -L "$HOME/.local/bin/claude" \
      && -x "$HOME/.local/share/claude/versions/${_expected_install_count}.0.0" ]] \
      || exit 1

    export HOME="$_native_repair_tmp/unsafe-versions-home"
    mkdir -p "$HOME/.local/bin" "$HOME/.local/share/claude" \
      "$_native_repair_tmp/unrelated-versions"
    printf 'preserve\n' > "$_native_repair_tmp/unrelated-versions/user-file"
    ln -s "$_native_repair_tmp/unrelated-versions" \
      "$HOME/.local/share/claude/versions"
    ! _mdm_prepare_native_claude_cli_reinstall || exit 1
    [[ "$(cat "$_native_repair_tmp/unrelated-versions/user-file")" \
      == "preserve" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_native_repair_tmp"
  unset _native_repair_tmp
}

{
  test_name="setup-refactor: CLI policy env is ignored outside MDM mode"
  _cli_policy_tmp="$(mktemp -d)"
  if (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/prerequisites.sh"
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/colors.sh"
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/i18n/en/strings.sh"
    export HOME="$_cli_policy_tmp/home" KIT_MDM_INSTALL_CLAUDE_CLI=false
    unset KIT_MDM_MANAGED KIT_MDM_REQUIRE_NATIVE_CLAUDE_CLI
    mkdir -p "$HOME"
    _need_claude_cli_install() { return 0; }
    _mdm_prepare_native_claude_cli_reinstall() { return 0; }
    _install_claude_cli() { : > "${_cli_policy_marker:?}"; return 1; }
    _ensure_claude_cli_path() { : > "${_cli_path_marker:?}"; return 0; }
    _cli_policy_marker="$_cli_policy_tmp/unset-managed"
    _cli_path_marker="$_cli_policy_tmp/unset-managed-path"
    install_claude_cli_if_needed >/dev/null 2>&1
    [[ -f "$_cli_policy_marker" && -f "$_cli_path_marker" ]] || exit 1

    KIT_MDM_MANAGED=false
    _cli_policy_marker="$_cli_policy_tmp/false-managed"
    _cli_path_marker="$_cli_policy_tmp/false-managed-path"
    install_claude_cli_if_needed >/dev/null 2>&1
    [[ -f "$_cli_policy_marker" && -f "$_cli_path_marker" ]] || exit 1

    KIT_MDM_MANAGED=true
    _cli_policy_marker="$_cli_policy_tmp/true-false-policy"
    _cli_path_marker="$_cli_policy_tmp/true-false-policy-path"
    install_claude_cli_if_needed >/dev/null 2>&1
    [[ ! -e "$_cli_policy_marker" && ! -e "$_cli_path_marker" ]] || exit 1

    KIT_MDM_INSTALL_CLAUDE_CLI=garbage
    _cli_policy_marker="$_cli_policy_tmp/true-invalid-policy"
    _cli_path_marker="$_cli_policy_tmp/true-invalid-policy-path"
    install_claude_cli_if_needed >/dev/null 2>&1 || true
    [[ -f "$_cli_policy_marker" && ! -e "$_cli_path_marker" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_cli_policy_tmp"
  unset _cli_policy_tmp
}

{
  test_name="setup-refactor: MDM fail mode starts no optional package installer"
  _fail_mode_tmp="$(mktemp -d)"
  if (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    _deploy_validate_outer_transaction_carrier() { return 0; }
    _prereq_mdm_fail_mode() { return 0; }
    _prereq_mdm_managed() { return 0; }
    is_true() { [[ "${1:-}" == "true" ]]; }
    command() {
      if [[ "${1:-}" == "-v" ]] \
        && [[ "${2:-}" == "biome" || "${2:-}" == "cc-safety-net" ]]; then
        return 1
      fi
      builtin command "$@"
    }
    warn() { :; }
    check_mdm_biome_baseline() { : > "$_fail_mode_tmp/biome-baseline"; return 31; }
    check_mdm_cc_safety_net_baseline() { : > "$_fail_mode_tmp/safety-baseline"; return 32; }
    install_mdm_biome() { : > "$_fail_mode_tmp/biome-installer"; }
    install_mdm_cc_safety_net() { : > "$_fail_mode_tmp/safety-installer"; }
    ENABLE_BIOME_HOOKS=true
    ENABLE_SAFETY_NET=true
    _biome_rc=0 _safety_rc=0
    maybe_install_biome || _biome_rc=$?
    maybe_install_cc_safety_net || _safety_rc=$?

    _prepare_mdm_claude_root() { return 0; }
    _has_user_customizations() { return 1; }
    backup_existing() { return 0; }
    _snapshot_exists() { return 0; }
    _validate_dismissed_features() { return 0; }
    _validate_plugin_csv() { return 0; }
    run_update() { return 0; }
    _detect_and_write_pending_features() { return 0; }
    _detect_and_offer_new_plugins() { return 0; }
    maybe_install_web_content_deps() { return 23; }
    CLAUDE_DIR="$_fail_mode_tmp/claude"
    UPDATE_MODE=true
    _CONFIG_ALLOWED_KEYS=""
    _deploy_rc=0
    setup_deploy || _deploy_rc=$?
    [[ -e "$_fail_mode_tmp/biome-baseline" \
      && -e "$_fail_mode_tmp/safety-baseline" \
      && ! -e "$_fail_mode_tmp/biome-installer" \
      && ! -e "$_fail_mode_tmp/safety-installer" \
      && "$_biome_rc" -ne 0 && "$_safety_rc" -ne 0 && "$_deploy_rc" -eq 23 ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_fail_mode_tmp"
  unset _fail_mode_tmp
}

{
  test_name="setup-refactor: MDM fail mode starts no Claude CLI installer"
  _cli_fail_tmp="$(mktemp -d)"
  if (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    _prereq_mdm_managed() { return 0; }
    _prereq_mdm_fail_mode() { return 0; }
    _need_claude_cli_install() { return 0; }
    _install_claude_cli() { : > "$_cli_fail_tmp/installer-started"; }
    warn() { :; }
    export KIT_MDM_MANAGED=true KIT_MDM_INSTALL_CLAUDE_CLI=true
    unset KIT_MDM_REQUIRE_NATIVE_CLAUDE_CLI
    _cli_rc=0
    install_claude_cli_if_needed >/dev/null 2>&1 || _cli_rc=$?
    [[ "$_cli_rc" -ne 0 && ! -e "$_cli_fail_tmp/installer-started" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_cli_fail_tmp"
  unset _cli_fail_tmp
}

{
  test_name="setup-refactor: managed CLI path update never reads target-user shell RC"
  _cli_rc_tmp="$(mktemp -d)"
  if (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    export HOME="$_cli_rc_tmp/home" SHELL=/bin/zsh
    export PATH="/usr/bin:/bin"
    mkdir -p "$HOME"
    mkfifo "$HOME/.zshrc"
    _prereq_mdm_managed() { [[ "${_cli_rc_mode:-}" == "managed" ]]; }
    _need_claude_cli_install() { return 1; }
    _mdm_requires_native_claude_cli() { return 0; }
    _add_to_path_now_and_persist() { : > "$_cli_rc_tmp/rc-touched"; return 71; }
    info() { :; }
    ok() { :; }
    STR_CLI_ALREADY="Claude CLI already installed"
    _cli_rc_mode=managed
    install_claude_cli_if_needed >/dev/null 2>&1 || exit 1
    [[ "$PATH" == "$HOME/.local/bin:/usr/bin:/bin" \
      && ! -e "$_cli_rc_tmp/rc-touched" ]] || exit 1

    _cli_rc_mode=normal
    _ensure_claude_cli_path >/dev/null 2>&1 && exit 1
    [[ -e "$_cli_rc_tmp/rc-touched" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_cli_rc_tmp"
  unset _cli_rc_tmp
}

{
  test_name="setup-refactor: contradictory managed native CLI policy fails closed"
  if (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    _prereq_mdm_managed() { return 0; }
    _prereq_mdm_fail_mode() { return 1; }
    warn() { :; }
    export KIT_MDM_MANAGED=true KIT_MDM_INSTALL_CLAUDE_CLI=false
    export KIT_MDM_REQUIRE_NATIVE_CLAUDE_CLI=true
    ! install_claude_cli_if_needed >/dev/null 2>&1
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="setup-refactor: managed CLI fail policy validates without installing"
  if (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    _prereq_mdm_managed() { return 0; }
    _prereq_mdm_fail_mode() { return 0; }
    warn() { :; }
    export KIT_MDM_MANAGED=true KIT_MDM_INSTALL_CLAUDE_CLI=true
    unset KIT_MDM_REQUIRE_NATIVE_CLAUDE_CLI
    _mdm_native_claude_cli_present() { return 1; }
    ! _mdm_validate_claude_cli_prerequisite_policy || exit 1
    _mdm_native_claude_cli_present() { return 0; }
    _mdm_validate_claude_cli_prerequisite_policy || exit 1

    KIT_MDM_INSTALL_CLAUDE_CLI=false
    _need_claude_cli_install && exit 1
    _mdm_validate_claude_cli_prerequisite_policy
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="setup-refactor: managed component install failures are fatal only in MDM mode"
  if (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    _prereq_mdm_fail_mode() { return 1; }
    _prereq_mdm_managed() { [[ "${_component_mode:-}" == "managed" ]]; }
    is_true() { [[ "${1:-}" == "true" ]]; }
    command() {
      if [[ "${1:-}" == "-v" ]] \
        && [[ "${2:-}" == "biome" || "${2:-}" == "cc-safety-net" ]]; then
        return 1
      fi
      builtin command "$@"
    }
    warn() { :; }
    check_biome() { return 31; }
    check_cc_safety_net() { return 32; }
    install_mdm_biome() { return 31; }
    install_mdm_cc_safety_net() { return 32; }
    ENABLE_BIOME_HOOKS=true ENABLE_SAFETY_NET=true DRY_RUN=false
    unset SAFETY_NET_SKIP_NPM_INSTALL

    _component_mode=managed
    _managed_biome=0 _managed_safety=0
    maybe_install_biome || _managed_biome=$?
    maybe_install_cc_safety_net || _managed_safety=$?

    _component_mode=normal
    _normal_biome=0 _normal_safety=0
    maybe_install_biome || _normal_biome=$?
    maybe_install_cc_safety_net || _normal_safety=$?
    [[ "$_managed_biome" -ne 0 && "$_managed_safety" -ne 0 \
      && "$_normal_biome" -eq 0 && "$_normal_safety" -eq 0 ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="setup-refactor: managed Biome and safety ignore untrusted PATH shortcuts"
  _managed_tool_tmp="$(mktemp -d)"
  if (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    is_true() { [[ "${1:-}" == "true" ]]; }
    _prereq_mdm_managed() { [[ "${_tool_mode:-}" == "managed" ]]; }
    _prereq_mdm_fail_mode() { return 1; }
    command() {
      if [[ "${1:-}" == "-v" \
        && ( "${2:-}" == "biome" || "${2:-}" == "cc-safety-net" ) ]]; then
        return 0
      fi
      builtin command "$@"
    }
    install_mdm_biome() { : > "$_managed_tool_tmp/biome"; }
    install_mdm_cc_safety_net() { : > "$_managed_tool_tmp/safety"; }
    ENABLE_BIOME_HOOKS=true ENABLE_SAFETY_NET=true DRY_RUN=false

    _tool_mode=managed
    maybe_install_biome || exit 1
    maybe_install_cc_safety_net || exit 1
    [[ -f "$_managed_tool_tmp/biome" \
      && -f "$_managed_tool_tmp/safety" ]] || exit 1

    rm -f "$_managed_tool_tmp/biome" "$_managed_tool_tmp/safety"
    _tool_mode=normal
    maybe_install_biome || exit 1
    maybe_install_cc_safety_net || exit 1
    [[ ! -e "$_managed_tool_tmp/biome" \
      && ! -e "$_managed_tool_tmp/safety" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_managed_tool_tmp"
  unset _managed_tool_tmp
}

{
  test_name="setup-refactor: managed deploy ignores manifest presence and never enters merge-aware fresh"
  _authority_tmp="$(mktemp -d)"
  if (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    _deploy_validate_outer_transaction_carrier() { return 0; }
    _deploy_mdm_managed() { return 0; }
    _prereq_mdm_fail_mode() { return 0; }
    _prepare_mdm_claude_root() { return 0; }
    backup_existing() { return 0; }
    ensure_dirs() { return 0; }
    _deploy_fresh_with_existing() { : > "$_authority_tmp/merge-aware"; return 0; }
    copy_if_enabled() { : > "$_authority_tmp/authoritative-copy"; return 0; }
    build_claude_md() { return 0; }
    _build_settings_managed_file() { return 0; }
    deploy_hook_scripts() { return 0; }
    _mdm_reconcile_absent_managed_files() { return 0; }
    write_managed_snapshot() { return 0; }
    reconcile_fresh_wce_package_pair() { return 0; }
    refresh_fresh_wce_snapshot_pair() { return 0; }
    maybe_install_web_content_deps() { return 0; }
    section() { :; }
    warn_existing_claude_reconfigure() { :; }
    ok() { :; }
    CLAUDE_DIR="$_authority_tmp/claude"
    mkdir -p "$CLAUDE_DIR"
    printf '{}\n' > "$CLAUDE_DIR/settings.json"
    UPDATE_MODE=false
    INSTALL_AGENTS=true INSTALL_RULES=true INSTALL_COMMANDS=true INSTALL_SKILLS=true
    setup_deploy || exit $?
    [[ -f "$_authority_tmp/authoritative-copy" && ! -e "$_authority_tmp/merge-aware" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_authority_tmp"
  unset _authority_tmp
}

{
  test_name="setup-refactor: required deploy failure stops before later artifacts"
  _prop_tmp="$(mktemp -d)"
  _prop_rc=0
  set +e
  (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    _deploy_validate_outer_transaction_carrier() { return 0; }
    _deploy_mdm_managed() { return 0; }
    _prereq_mdm_fail_mode() { return 0; }
    _prepare_mdm_claude_root() { return 0; }
    backup_existing() { return 0; }
    ensure_dirs() { return 0; }
    copy_if_enabled() { return 0; }
    build_claude_md() { return 37; }
    _build_settings_managed_file() { : > "$_prop_tmp/settings"; return 0; }
    deploy_hook_scripts() { : > "$_prop_tmp/hooks"; return 0; }
    _mdm_reconcile_absent_managed_files() { return 0; }
    write_managed_snapshot() { : > "$_prop_tmp/snapshot"; return 0; }
    section() { :; }
    warn_existing_claude_reconfigure() { :; }
    CLAUDE_DIR="$_prop_tmp/claude"
    UPDATE_MODE=false
    INSTALL_AGENTS=true INSTALL_RULES=true INSTALL_COMMANDS=true INSTALL_SKILLS=true
    setup_deploy
  ) >/dev/null 2>&1
  _prop_rc=$?
  set -e
  if [[ "$_prop_rc" -eq 37 && ! -e "$_prop_tmp/settings" \
    && ! -e "$_prop_tmp/hooks" && ! -e "$_prop_tmp/snapshot" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_prop_tmp"
  unset _prop_tmp _prop_rc
}

{
  test_name="setup-refactor: required CLI failure precedes manifest and success log"
  _final_tmp="$(mktemp -d)"
  _final_rc=0
  set +e
  (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    uname() { printf 'Linux\n'; }
    is_true() { return 1; }
    install_claude_cli_if_needed() { return 42; }
    install_selected_plugins() { : > "$_final_tmp/plugins"; }
    run_codex_setup() { : > "$_final_tmp/codex"; }
    write_manifest() { : > "$_final_tmp/manifest"; }
    _deploy_mdm_managed() { return 0; }
    _check_auto_update_health() { :; }
    section() { :; }
    ok() { : > "$_final_tmp/success"; }
    ENABLE_GHOSTTY_SETUP=false ENABLE_FONTS_SETUP=false UPDATE_MODE=false DRY_RUN=false
    setup_finalize
  ) >/dev/null 2>&1
  _final_rc=$?
  set -e
  if [[ "$_final_rc" -eq 42 && ! -e "$_final_tmp/manifest" \
    && ! -e "$_final_tmp/success" && ! -e "$_final_tmp/plugins" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_final_tmp"
  unset _final_tmp _final_rc
}

{
  test_name="setup-refactor: non-MDM deployment checkpoint precedes external setup failure"
  _normal_final_tmp="$(mktemp -d)"
  _normal_final_rc=0
  set +e
  (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    uname() { printf 'Linux\n'; }
    is_true() { return 1; }
    _deploy_mdm_managed() { return 1; }
    write_manifest() { : > "$_normal_final_tmp/manifest"; }
    save_config() { : > "$_normal_final_tmp/config"; }
    install_claude_cli_if_needed() { return 0; }
    install_selected_plugins() { return 0; }
    run_codex_setup() { return 43; }
    section() { :; }
    ENABLE_GHOSTTY_SETUP=false ENABLE_FONTS_SETUP=false
    setup_finalize
  ) >/dev/null 2>&1
  _normal_final_rc=$?
  set -e
  if [[ "$_normal_final_rc" -eq 43 \
    && -f "$_normal_final_tmp/manifest" \
    && -f "$_normal_final_tmp/config" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_normal_final_tmp"
  unset _normal_final_tmp _normal_final_rc
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
printf '%s\n' '#!/bin/bash
# Fake claude CLI: logs every invocation; `plugin list` output is controllable.
printf "%s\n" "$*" >> "${FAKE_CLAUDE_LOG:?}"
_fake_print_entry() {
  local entry="$1"
  entry="${entry#"${entry%%[![:space:]]*}"}"
  [[ "$entry" == "❯ "* ]] && entry="${entry#❯ }"
  [[ -n "$entry" ]] || return 0
  printf "❯ %s\n  Scope: user\n" "$entry"
}
_fake_print_list() {
  local initial_list="${FAKE_CLAUDE_PLUGIN_LIST:-}"
  if [[ "${FAKE_CLAUDE_PLUGIN_LIST_RC:-0}" -ne 0 \
    && -e "${FAKE_CLAUDE_LIST_FAILED_FILE:?}" ]]; then
    initial_list=""
  fi
  if [[ -n "$initial_list" \
    || -s "${FAKE_CLAUDE_STATE_FILE:?}" ]]; then
    printf "Installed plugins:\n\n"
    while IFS= read -r entry; do
      _fake_print_entry "$entry"
    done <<< "$initial_list"
    [[ ! -s "$FAKE_CLAUDE_STATE_FILE" ]] || cat "$FAKE_CLAUDE_STATE_FILE"
  else
    printf "No plugins installed. Use \`claude plugin install\` to install a plugin.\n"
  fi
}
if [[ "${1:-}" == "plugin" && "${2:-}" == "list" ]]; then
  if [[ "${FAKE_CLAUDE_PLUGIN_LIST_RC:-0}" -ne 0 \
    && ! -e "${FAKE_CLAUDE_LIST_FAILED_FILE:?}" ]]; then
    : > "$FAKE_CLAUDE_LIST_FAILED_FILE"
    printf "%s\n" "${FAKE_CLAUDE_PLUGIN_LIST:-}"
    exit "${FAKE_CLAUDE_PLUGIN_LIST_RC}"
  fi
  _fake_print_list
  exit 0
fi
if [[ "${1:-}" == "plugin" && "${2:-}" == "marketplace" && "${3:-}" == "add" ]]; then
  if [[ "${FAKE_CLAUDE_MARKETPLACE_RC:-0}" -ne 0 ]]; then
    echo "fake-marketplace-error: cannot add ${4:-}" >&2
    exit "${FAKE_CLAUDE_MARKETPLACE_RC}"
  fi
  exit 0
fi
if [[ "${1:-}" == "plugin" && "${2:-}" == "install" ]]; then
  _fake_installed="${3:-}"
  [[ "$_fake_installed" == *"@"* ]] \
    || _fake_installed="${_fake_installed}@claude-plugins-official"
  printf "❯ %s\n  Scope: user\n" "$_fake_installed" \
    >> "${FAKE_CLAUDE_STATE_FILE:?}"
  exit 0
fi
exit 0
' > "$_ISP_DIR/bin/claude"
chmod +x "$_ISP_DIR/bin/claude"

# _isp_run_case <selected_plugins> <plugin_list_output> <marketplace_rc> <with_claude>
#               [catalog_body] [plugin_list_rc]
#
# Runs install_selected_plugins in an isolated subshell with the fake claude.
# Results: $_ISP_DIR/calls.log (fake claude invocations, one per line),
#          $_ISP_DIR/out.log (function stdout+stderr), $_ISP_DIR/rc.txt (exit code)
_isp_run_case() {
  local _sel="$1" _plist="$2" _mp_rc="$3" _with_claude="$4"
  local _catalog_dir="" _catalog_body="${5:-}" _list_rc="${6:-0}"
  : > "$_ISP_DIR/calls.log"
  rm -rf "$_ISP_DIR/claude"
  mkdir -p "$_ISP_DIR/claude"
  rm -f "$_ISP_DIR/out.log" "$_ISP_DIR/rc.txt" \
    "$_ISP_DIR/plugin-state" "$_ISP_DIR/list-failed"
  if [[ -n "$_catalog_body" ]]; then
    _catalog_dir="$_ISP_DIR/catalog"
    rm -rf "$_catalog_dir"
    mkdir -p "$_catalog_dir/config"
    printf '%s' "$_catalog_body" > "$_catalog_dir/config/plugins.json"
  fi
  (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    # setup_stage1/setup_source_stage2 は実行しないので、依存を手動で source する
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/colors.sh"
    # _run_capture / _claude_plugin_list_has
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/codex-setup.sh"
    # exact user-scope list parsing and durable ownership state
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/plugin-provenance.sh"
    # STR_DEPLOY_PLUGINS_*
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/i18n/en/strings.sh"
    if [[ -n "$_catalog_dir" ]]; then
      PROJECT_DIR="$_catalog_dir"
    fi
    export FAKE_CLAUDE_LOG="$_ISP_DIR/calls.log"
    export FAKE_CLAUDE_PLUGIN_LIST="$_plist"
    export FAKE_CLAUDE_PLUGIN_LIST_RC="$_list_rc"
    export FAKE_CLAUDE_MARKETPLACE_RC="$_mp_rc"
    export FAKE_CLAUDE_STATE_FILE="$_ISP_DIR/plugin-state"
    export FAKE_CLAUDE_LIST_FAILED_FILE="$_ISP_DIR/list-failed"
    CLAUDE_DIR="$_ISP_DIR/claude"
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

# _isp_run_dry_case <selected_plugins> <plugin_list_output> <plugin_list_rc>
#                   <update_mode> <with_claude>
_isp_run_dry_case() {
  local _sel="$1" _plist="$2" _list_rc="$3" _update="$4" _with_claude="$5"
  : > "$_ISP_DIR/calls.log"
  : > "$_ISP_DIR/dryrun.log"
  rm -f "$_ISP_DIR/out.log" "$_ISP_DIR/rc.txt" \
    "$_ISP_DIR/plugin-state" "$_ISP_DIR/list-failed"
  (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/colors.sh"
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/codex-setup.sh"
    export FAKE_CLAUDE_LOG="$_ISP_DIR/calls.log"
    export FAKE_CLAUDE_PLUGIN_LIST="$_plist"
    export FAKE_CLAUDE_PLUGIN_LIST_RC="$_list_rc"
    export FAKE_CLAUDE_STATE_FILE="$_ISP_DIR/plugin-state"
    export FAKE_CLAUDE_LIST_FAILED_FILE="$_ISP_DIR/list-failed"
    UPDATE_MODE="$_update"
    if [[ "$_with_claude" == "true" ]]; then
      PATH="$_ISP_DIR/bin:$PATH"
    else
      PATH="/usr/bin:/bin"
    fi
    hash -r
    _dryrun_log() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$_ISP_DIR/dryrun.log"; }
    _rc=0
    _dryrun_log_plugin_operations "$_sel" > "$_ISP_DIR/out.log" 2>&1 || _rc=$?
    printf '%s\n' "$_rc" > "$_ISP_DIR/rc.txt"
  )
}

{
  test_name="install_selected_plugins: exact official-marketplace match skips install"
  if _isp_run_case "security-guidance" "security-guidance@claude-plugins-official" 0 true \
    && grep -qx "plugin list" "$_ISP_DIR/calls.log" \
    && ! grep -q "plugin install" "$_ISP_DIR/calls.log" \
    && ! grep -q "plugin marketplace add" "$_ISP_DIR/calls.log" \
    && grep -qF "Already installed: security-guidance" "$_ISP_DIR/out.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: failed plugin list output is not trusted"
  if _isp_run_case "security-guidance" \
    "security-guidance@claude-plugins-official" 0 true "" 1 \
    && grep -qx "plugin list" "$_ISP_DIR/calls.log" \
    && grep -qx "plugin marketplace add anthropics/claude-plugins-official" "$_ISP_DIR/calls.log" \
    && grep -qx "plugin install security-guidance --scope user" "$_ISP_DIR/calls.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: prefix-similar name does not mask the selected plugin"
  if _isp_run_case "security-guidance" "security-guidance-companion@claude-plugins-official" 0 true \
    && grep -qx "plugin marketplace add anthropics/claude-plugins-official" "$_ISP_DIR/calls.log" \
    && grep -qx "plugin install security-guidance --scope user" "$_ISP_DIR/calls.log" \
    && grep -qF "Plugin: security-guidance" "$_ISP_DIR/out.log" \
    && ! grep -qF "Already installed:" "$_ISP_DIR/out.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: marketplace add failure suppresses that repository's installs"
  if _isp_run_case "security-guidance" "" 1 true \
    && grep -qF "Failed to add plugin marketplace" "$_ISP_DIR/out.log" \
    && grep -qF "fake-marketplace-error" "$_ISP_DIR/out.log" \
    && ! grep -q "plugin install" "$_ISP_DIR/calls.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: malformed late catalog row invalidates the whole plan"
  _isp_invalid_catalog='{"marketplaces":{"claude-plugins-official":"a/b","unused":7},"plugins":[
    {"name":"security-guidance","marketplace":"claude-plugins-official","description":"security","profiles":["standard"]}
  ]}'
  if _isp_run_case "security-guidance" "" 0 true "$_isp_invalid_catalog" \
    && [[ ! -s "$_ISP_DIR/calls.log" ]] \
    && grep -qF "config/plugins.json is invalid" "$_ISP_DIR/out.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "1" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  unset _isp_invalid_catalog
}

{
  test_name="install_selected_plugins: missing claude CLI skips gracefully with hint"
  if _isp_run_case "security-guidance" "" 0 false \
    && grep -qF "Skipping plugin install" "$_ISP_DIR/out.log" \
    && grep -qF "/install security-guidance" "$_ISP_DIR/out.log" \
    && [[ ! -s "$_ISP_DIR/calls.log" ]] \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# ── marketplace identity is preserved end-to-end (F12) ──────────────────────
{
  test_name="install_selected_plugins: qualified entry keeps @marketplace through to install argv"
  if _isp_run_case "document-skills@anthropic-agent-skills" "" 0 true \
    && grep -qx "plugin marketplace add anthropics/skills" "$_ISP_DIR/calls.log" \
    && grep -qx "plugin install document-skills@anthropic-agent-skills --scope user" "$_ISP_DIR/calls.log" \
    && ! grep -qx "plugin install document-skills --scope user" "$_ISP_DIR/calls.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: same name from another marketplace is not mistaken for installed"
  if _isp_run_case "document-skills@anthropic-agent-skills" "  ❯ document-skills@some-other-marketplace" 0 true \
    && ! grep -qF "Already installed:" "$_ISP_DIR/out.log" \
    && grep -qx "plugin install document-skills@anthropic-agent-skills --scope user" "$_ISP_DIR/calls.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: unambiguous official name remains bare for backward compatibility"
  if _isp_run_case "security-guidance" "" 0 true \
    && grep -qx "plugin install security-guidance --scope user" "$_ISP_DIR/calls.log" \
    && ! grep -qF "plugin install security-guidance@" "$_ISP_DIR/calls.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: no-CLI hint keeps the @marketplace suffix"
  if _isp_run_case "document-skills@anthropic-agent-skills" "" 0 false \
    && grep -qF "/install document-skills@anthropic-agent-skills" "$_ISP_DIR/out.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: bare official target does not match another marketplace"
  if _isp_run_case "security-guidance" "  ❯ security-guidance@some-other-marketplace" 0 true \
    && grep -qx "plugin install security-guidance --scope user" "$_ISP_DIR/calls.log" \
    && ! grep -qF "Already installed:" "$_ISP_DIR/out.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: unmapped marketplace fails closed before CLI execution"
  if _isp_run_case "security-guidance@missing-marketplace" "" 0 true \
    && [[ ! -s "$_ISP_DIR/calls.log" ]] \
    && grep -qF "Skipping plugin outside the current catalog or marketplace mapping" "$_ISP_DIR/out.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: marketplace and duplicate plugin operations are deduplicated"
  if _isp_run_case "security-guidance,commit-commands,security-guidance" "" 0 true \
    && [[ "$(grep -c '^plugin marketplace add anthropics/claude-plugins-official$' "$_ISP_DIR/calls.log")" -eq 1 ]] \
    && [[ "$(grep -c '^plugin install security-guidance --scope user$' "$_ISP_DIR/calls.log")" -eq 1 ]] \
    && [[ "$(grep -c '^plugin install commit-commands --scope user$' "$_ISP_DIR/calls.log")" -eq 1 ]] \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="dry-run plugins: installed entries produce no external-operation preview"
  if _isp_run_dry_case "security-guidance,document-skills@anthropic-agent-skills" \
    $'security-guidance@claude-plugins-official\ndocument-skills@anthropic-agent-skills' \
    0 false true \
    && grep -qx "plugin list" "$_ISP_DIR/calls.log" \
    && [[ ! -s "$_ISP_DIR/dryrun.log" ]] \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="dry-run plugins: only missing entries are previewed"
  if _isp_run_dry_case "security-guidance,commit-commands" \
    "security-guidance@claude-plugins-official" 0 false true \
    && [[ "$(grep -cF 'claude plugin marketplace add anthropics/claude-plugins-official' "$_ISP_DIR/dryrun.log")" -eq 1 ]] \
    && grep -qF 'claude plugin install commit-commands --scope user' "$_ISP_DIR/dryrun.log" \
    && ! grep -qF 'claude plugin install security-guidance --scope user' "$_ISP_DIR/dryrun.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="dry-run plugins: failed list output is treated as untrusted"
  if _isp_run_dry_case "document-skills@anthropic-agent-skills" \
    "document-skills@anthropic-agent-skills" 1 false true \
    && grep -qF 'claude plugin marketplace add anthropics/skills' "$_ISP_DIR/dryrun.log" \
    && grep -qF 'claude plugin install document-skills@anthropic-agent-skills --scope user' "$_ISP_DIR/dryrun.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="dry-run plugins: update previews reinstall even when already installed"
  if _isp_run_dry_case "security-guidance" \
    "security-guidance@claude-plugins-official" 0 true true \
    && grep -qF 'claude plugin marketplace add anthropics/claude-plugins-official' "$_ISP_DIR/dryrun.log" \
    && grep -qF 'claude plugin install security-guidance --scope user' "$_ISP_DIR/dryrun.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="dry-run plugins: absent Claude CLI previews the post-bootstrap plugin plan"
  if _isp_run_dry_case "security-guidance" "" 0 false false \
    && [[ ! -s "$_ISP_DIR/calls.log" ]] \
    && grep -qF 'claude plugin marketplace add anthropics/claude-plugins-official' "$_ISP_DIR/dryrun.log" \
    && grep -qF 'claude plugin install security-guidance --scope user' "$_ISP_DIR/dryrun.log" \
    && [[ "$(cat "$_ISP_DIR/rc.txt")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="dry-run plugins: invalid catalog propagates without logging a partial plan"
  _isp_dry_log="$_ISP_DIR/dryrun-invalid.log"
  _isp_invalid_dir="$_ISP_DIR/dryrun-invalid-kit"
  mkdir -p "$_isp_invalid_dir/config"
  printf '%s' '{"marketplaces":{"claude-plugins-official":"a/b"},"plugins":[
    {"name":"security-guidance","marketplace":false,"description":"security","profiles":["standard"]}
  ]}' > "$_isp_invalid_dir/config/plugins.json"
  : > "$_isp_dry_log"
  _isp_dry_rc=0
  (
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/setup.sh"
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/colors.sh"
    PROJECT_DIR="$_isp_invalid_dir"
    _dryrun_log() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$_isp_dry_log"; }
    _dryrun_log_plugin_operations "security-guidance"
  ) >/dev/null 2>&1 || _isp_dry_rc=$?
  if [[ "$_isp_dry_rc" -eq 1 && ! -s "$_isp_dry_log" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_isp_invalid_dir"
  rm -f "$_isp_dry_log"
  unset _isp_dry_log _isp_invalid_dir _isp_dry_rc
}

rm -rf "$_ISP_DIR"
unset _ISP_DIR
unset -f _isp_run_case _isp_run_dry_case

# ---------------------------------------------------------------------------
# install_selected_plugins() and durable provenance behavior
# ---------------------------------------------------------------------------

_PROV_DIR="$(mktemp -d)"
_PROV_FIXED_PATH="$_PROV_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$_PROV_DIR/bin" "$_PROV_DIR/no-cli" "$_PROV_DIR/state"
ln -s "$(command -v jq)" "$_PROV_DIR/bin/jq"
printf '%s\n' '#!/bin/bash
printf "%s\n" "$*" >> "${FAKE_CLAUDE_LOG:?}"
_fake_print_initial_list() {
  if [[ -n "${FAKE_CLAUDE_PLUGIN_LIST:-}" \
    || -s "${FAKE_CLAUDE_MARKETPLACE_STATE_FILE:?}" ]]; then
    printf "Installed plugins:\n\n"
    [[ -z "${FAKE_CLAUDE_PLUGIN_LIST:-}" ]] \
      || printf "%s\n" "$FAKE_CLAUDE_PLUGIN_LIST"
    [[ ! -s "${FAKE_CLAUDE_MARKETPLACE_STATE_FILE}" ]] \
      || cat "$FAKE_CLAUDE_MARKETPLACE_STATE_FILE"
  else
    printf "No plugins installed. Use \`claude plugin install\` to install a plugin.\n"
  fi
}
_fake_print_post_base() {
  printf "Installed plugins:\n\n"
  [[ -z "${FAKE_CLAUDE_PLUGIN_LIST:-}" ]] \
    || printf "%s\n" "$FAKE_CLAUDE_PLUGIN_LIST"
  [[ ! -s "${FAKE_CLAUDE_MARKETPLACE_STATE_FILE:?}" ]] \
    || cat "$FAKE_CLAUDE_MARKETPLACE_STATE_FILE"
}
if [[ "${1:-}" == plugin && "${2:-}" == list ]]; then
  if [[ -e "${FAKE_CLAUDE_INSTALL_SEEN:?}" ]]; then
    case "${FAKE_CLAUDE_POST_LIST_MODE:-auto}" in
      auto)
        _fake_print_post_base
        [[ ! -f "${FAKE_CLAUDE_STATE_FILE:?}" ]] \
          || cat "${FAKE_CLAUDE_STATE_FILE}"
        ;;
      no-op) _fake_print_initial_list ;;
      wrong-marketplace)
        _fake_print_post_base
        _fake_last_plugin="$(cat "${FAKE_CLAUDE_LAST_PLUGIN_FILE:?}")"
        printf "❯ %s@third-party\n  Scope: user\n" \
          "${_fake_last_plugin%%@*}"
        ;;
      wrong-scope)
        _fake_print_post_base
        _fake_last_plugin="$(cat "${FAKE_CLAUDE_LAST_PLUGIN_FILE:?}")"
        printf "❯ %s\n  Scope: project\n" "$_fake_last_plugin"
        ;;
      extra)
        _fake_print_post_base
        cat "${FAKE_CLAUDE_STATE_FILE:?}"
        printf "❯ unexpected-plugin@claude-plugins-official\n  Scope: user\n"
        ;;
      unknown-marker)
        _fake_print_post_base
        _fake_last_plugin="$(cat "${FAKE_CLAUDE_LAST_PLUGIN_FILE:?}")"
        printf "! %s\n  Scope: user\n" "$_fake_last_plugin"
        ;;
      malformed-entry)
        _fake_print_post_base
        cat "${FAKE_CLAUDE_STATE_FILE:?}"
        printf "❯ rogue@bad/market\n  Scope: user\n"
        ;;
      drop-existing)
        printf "Installed plugins:\n\n"
        cat "${FAKE_CLAUDE_STATE_FILE:?}"
        ;;
      fail) exit 8 ;;
      *) exit 9 ;;
    esac
    exit 0
  fi
  if [[ "${FAKE_CLAUDE_LIST_RC:-0}" -ne 0 ]]; then
    if [[ "${FAKE_CLAUDE_LIST_FAIL_ONCE:-false}" != true \
      || ! -e "${FAKE_CLAUDE_LIST_FAILED_FILE:?}" ]]; then
      : > "${FAKE_CLAUDE_LIST_FAILED_FILE:?}"
      exit "${FAKE_CLAUDE_LIST_RC}"
    fi
  fi
  _fake_print_initial_list
  exit 0
fi
if [[ "${1:-}" == plugin && "${2:-}" == marketplace && "${3:-}" == add ]]; then
  [[ "${FAKE_CLAUDE_MARKETPLACE_RC:-0}" -eq 0 ]] || {
    printf "fake-marketplace-error: %s\n" "${4:-}" >&2
    exit "${FAKE_CLAUDE_MARKETPLACE_RC}"
  }
  if [[ -n "${FAKE_CLAUDE_MARKETPLACE_PLUGIN:-}" ]]; then
    printf "❯ %s\n  Scope: user\n" \
      "$FAKE_CLAUDE_MARKETPLACE_PLUGIN" \
      > "${FAKE_CLAUDE_MARKETPLACE_STATE_FILE:?}"
  fi
  exit 0
fi
if [[ "${1:-}" == plugin && "${2:-}" == install ]]; then
  [[ "${FAKE_CLAUDE_INSTALL_RC:-0}" -eq 0 ]] \
    || exit "${FAKE_CLAUDE_INSTALL_RC}"
  _fake_installed="${3:-}"
  [[ "$_fake_installed" == *"@"* ]] \
    || _fake_installed="${_fake_installed}@claude-plugins-official"
  printf "❯ %s\n  Scope: user\n" "$_fake_installed" \
    >> "${FAKE_CLAUDE_STATE_FILE:?}"
  printf "%s\n" "$_fake_installed" > "${FAKE_CLAUDE_LAST_PLUGIN_FILE:?}"
  : > "${FAKE_CLAUDE_INSTALL_SEEN:?}"
  exit 0
fi
exit 0
' > "$_PROV_DIR/bin/claude"
chmod +x "$_PROV_DIR/bin/claude"

_prov_run_case() { # <name> <selected> <list> <list-rc> <market-rc> <install-rc> <cli> [dry-run] [update] [post-mode] [record-rc] [prior-manifest-plugins] [list-fail-once] [marketplace-plugin]
  local name="$1" selected="$2" plugin_list="$3" list_rc="$4"
  local market_rc="$5" install_rc="$6" with_cli="$7" dry_run="${8:-false}"
  local update_mode="${9:-false}"
  local post_mode="${10:-auto}" record_rc="${11:-0}"
  local prior_manifest_plugins="${12:-}"
  local list_fail_once="${13:-false}" marketplace_plugin="${14:-}"
  local case_dir="$_PROV_DIR/state/$name" case_home case_path
  case_home="$case_dir/home"
  mkdir -p "$case_home/.claude" "$case_dir/tmp" "$case_dir/npm" \
    "$case_dir/appdata" "$case_dir/localappdata"
  if [[ -n "$prior_manifest_plugins" ]]; then
    jq -n --arg plugins "$prior_manifest_plugins" \
      '{plugins: $plugins}' \
      > "$case_home/.claude/.starter-kit-manifest.json"
  fi
  : > "$case_dir/calls.log"
  if [[ "$with_cli" == "true" ]]; then
    case_path="$_PROV_FIXED_PATH"
  else
    case_path="$_PROV_DIR/no-cli:/usr/bin:/bin:/usr/sbin:/sbin"
  fi
  env -i \
    HOME="$case_home" TMPDIR="$case_dir/tmp" \
    APPDATA="$case_dir/appdata" LOCALAPPDATA="$case_dir/localappdata" \
    NPM_CONFIG_PREFIX="$case_dir/npm" npm_config_prefix="$case_dir/npm" \
    PATH="$case_path" LC_ALL=C TERM=dumb \
    FAKE_CLAUDE_LOG="$case_dir/calls.log" \
    FAKE_CLAUDE_PLUGIN_LIST="$plugin_list" FAKE_CLAUDE_LIST_RC="$list_rc" \
    FAKE_CLAUDE_MARKETPLACE_RC="$market_rc" \
    FAKE_CLAUDE_INSTALL_RC="$install_rc" \
    FAKE_CLAUDE_POST_LIST_MODE="$post_mode" \
    FAKE_CLAUDE_STATE_FILE="$case_dir/installed-state" \
    FAKE_CLAUDE_MARKETPLACE_STATE_FILE="$case_dir/marketplace-state" \
    FAKE_CLAUDE_LIST_FAILED_FILE="$case_dir/list-failed-once" \
    FAKE_CLAUDE_INSTALL_SEEN="$case_dir/install-seen" \
    FAKE_CLAUDE_LAST_PLUGIN_FILE="$case_dir/last-plugin" \
    FAKE_PROVENANCE_RECORD_RC="$record_rc" \
    FAKE_CLAUDE_LIST_FAIL_ONCE="$list_fail_once" \
    FAKE_CLAUDE_MARKETPLACE_PLUGIN="$marketplace_plugin" \
    bash -c '
      set -euo pipefail
      source "$1/setup.sh"
      source "$1/lib/colors.sh"
      source "$1/lib/codex-setup.sh"
      source "$1/lib/plugin-provenance.sh"
      source "$1/i18n/en/strings.sh"
      if [[ "${FAKE_PROVENANCE_RECORD_RC:-0}" -ne 0 ]]; then
        _plugin_provenance_record() {
          return "${FAKE_PROVENANCE_RECORD_RC}"
        }
      fi
      SELECTED_PLUGINS="$2"
      UPDATE_MODE="$5"
      DRY_RUN="$3"
      rc=0
      install_selected_plugins > "$4/out.log" 2>&1 || rc=$?
      printf "%s\n" "$rc" > "$4/rc.txt"
    ' _ "$PROJECT_DIR" "$selected" "$dry_run" "$case_dir" "$update_mode"
}

{
  test_name="install_selected_plugins: a pre-existing plugin is never adopted"
  _prov_run_case existing "security-guidance" \
    $'❯ security-guidance@claude-plugins-official\n  Scope: user' \
    0 0 0 true
  _case="$_PROV_DIR/state/existing"
  if grep -qx "plugin list" "$_case/calls.log" \
    && ! grep -q "plugin install" "$_case/calls.log" \
    && [[ ! -e "$_case/home/.claude/.starter-kit-plugin-provenance.json" ]] \
    && [[ "$(cat "$_case/rc.txt")" == 0 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: same name in another marketplace is not adopted"
  _prov_run_case other-marketplace "security-guidance" \
    $'❯ security-guidance@third-party\n  Scope: user' 0 0 0 true
  _case="$_PROV_DIR/state/other-marketplace"
  _marker="$_case/home/.claude/.starter-kit-plugin-provenance.json"
  if grep -qx \
      "plugin install security-guidance --scope user" \
      "$_case/calls.log" \
    && jq -e '.installed_by_kit == [
      "security-guidance@claude-plugins-official"]' "$_marker" >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: marketplace side effects are included in the pre-install baseline"
  _prov_run_case marketplace-adds-target "security-guidance" "" \
    0 0 0 true false false auto 0 "" false \
    security-guidance@claude-plugins-official
  _case="$_PROV_DIR/state/marketplace-adds-target"
  if grep -q '^plugin marketplace add ' "$_case/calls.log" \
    && ! grep -q '^plugin install ' "$_case/calls.log" \
    && [[ "$(cat "$_case/rc.txt")" == 0 ]] \
    && [[ ! -e \
      "$_case/home/.claude/.starter-kit-plugin-provenance.json" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: a successful exact install records strict provenance"
  _prov_run_case success "security-guidance,code-review@claude-plugins-official,security-guidance" \
    $'❯ codex-companion@claude-plugins-official\n  Scope: user' \
    0 0 0 true
  _case="$_PROV_DIR/state/success"
  _marker="$_case/home/.claude/.starter-kit-plugin-provenance.json"
  _mode="$(stat -f '%Lp' "$_marker" 2>/dev/null || stat -c '%a' "$_marker")"
  if grep -qx "plugin install security-guidance --scope user" \
      "$_case/calls.log" \
    && grep -qx "plugin install code-review@claude-plugins-official --scope user" \
      "$_case/calls.log" \
    && [[ "$_mode" == 600 ]] \
    && jq -e '.version == 1 and .installed_by_kit == [
      "code-review@claude-plugins-official",
      "security-guidance@claude-plugins-official"]' "$_marker" >/dev/null \
    && ! compgen -G "$_case/home/.claude/..starter-kit-plugin-provenance.json.tmp.*" \
      >/dev/null \
    && [[ ! -e "$_case/home/.claude/.starter-kit-plugin-provenance.lock" ]] \
    && ! compgen -G \
      "$_case/home/.claude/.starter-kit-plugin-provenance.lock.release-*" \
      >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: post-install list preserves prior entries and adds target"
  _postcondition_ok=true
  for _post_mode in no-op wrong-marketplace wrong-scope \
    unknown-marker malformed-entry fail; do
    _prov_run_case "post-$_post_mode" "security-guidance" "" \
      0 0 0 true false false "$_post_mode"
    _case="$_PROV_DIR/state/post-$_post_mode"
    _marker="$_case/home/.claude/.starter-kit-plugin-provenance.json"
    if [[ "$(cat "$_case/rc.txt")" != 1 ]] \
      || ! grep -q 'Could not verify installed plugin exactly' \
        "$_case/out.log" \
      || ! jq -e '.installed_by_kit == [] and .pending_install_by_kit == [
        "security-guidance@claude-plugins-official"]' \
        "$_marker" >/dev/null; then
      _postcondition_ok=false
    fi
  done
  _prov_run_case post-drop "security-guidance" \
    $'❯ existing-plugin@claude-plugins-official\n  Scope: user' \
    0 0 0 true false false drop-existing
  _case="$_PROV_DIR/state/post-drop"
  _marker="$_case/home/.claude/.starter-kit-plugin-provenance.json"
  if [[ "$(cat "$_case/rc.txt")" != 1 ]] \
    || ! grep -q 'Could not verify installed plugin exactly' "$_case/out.log" \
    || ! jq -e '.installed_by_kit == [] and .pending_install_by_kit == [
      "security-guidance@claude-plugins-official"]' "$_marker" >/dev/null; then
    _postcondition_ok=false
  fi
  _prov_run_case post-dependency "security-guidance" \
    $'❯ existing-plugin@claude-plugins-official\n  Scope: user' \
    0 0 0 true false false extra
  _case="$_PROV_DIR/state/post-dependency"
  _marker="$_case/home/.claude/.starter-kit-plugin-provenance.json"
  if [[ "$(cat "$_case/rc.txt")" != 0 ]] \
    || ! jq -e '.installed_by_kit == [
      "security-guidance@claude-plugins-official"]' \
      "$_marker" >/dev/null; then
    _postcondition_ok=false
  fi
  if [[ "$_postcondition_ok" == "true" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: unverified intent never adopts manual install"
  _prov_run_case manual-after-failure "security-guidance" "" \
    0 0 9 true
  _case="$_PROV_DIR/state/manual-after-failure"
  _marker="$_case/home/.claude/.starter-kit-plugin-provenance.json"
  if [[ "$(cat "$_case/rc.txt")" == 1 ]] \
    && jq -e '.installed_by_kit == [] and .pending_install_by_kit == [
      "security-guidance@claude-plugins-official"]' "$_marker" >/dev/null; then
    _manual_pending=true
  else
    _manual_pending=false
  fi
  printf "❯ security-guidance@claude-plugins-official\n  Scope: user\n" \
    > "$_case/installed-state"
  : > "$_case/install-seen"
  _prov_run_case manual-after-failure "security-guidance" "" 0 0 0 true
  if [[ "$_manual_pending" == "true" ]] \
    && [[ "$(cat "$_case/rc.txt")" == 0 ]] \
    && ! grep -q "plugin install" "$_case/calls.log" \
    && jq -e '.installed_by_kit == []
      and (has("pending_install_by_kit") | not)
      and (has("verified_commit_by_kit") | not)' "$_marker" >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: pending intent ignores project-scope appearance"
  _prov_run_case pending-project "security-guidance" "" 0 0 9 true
  _case="$_PROV_DIR/state/pending-project"
  _marker="$_case/home/.claude/.starter-kit-plugin-provenance.json"
  if jq -e '.pending_install_by_kit == [
      "security-guidance@claude-plugins-official"]' \
      "$_marker" >/dev/null; then
    _project_pending=true
  else
    _project_pending=false
  fi
  _prov_run_case pending-project "security-guidance" \
    $'❯ security-guidance@claude-plugins-official\n  Scope: project' \
    0 0 0 true
  if [[ "$_project_pending" == "true" ]] \
    && grep -qx \
      "plugin install security-guidance --scope user" \
      "$_case/calls.log" \
    && [[ "$(cat "$_case/rc.txt")" == 0 ]] \
    && jq -e '.installed_by_kit == [
      "security-guidance@claude-plugins-official"]' \
      "$_marker" >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: current update selection never adopts a pre-existing plugin"
  _prov_run_case update-existing "security-guidance" \
    $'❯ security-guidance@claude-plugins-official\n  Scope: user' \
    0 0 0 true false true
  _case="$_PROV_DIR/state/update-existing"
  if grep -qx \
      "plugin install security-guidance --scope user" \
      "$_case/calls.log" \
    && [[ ! -e "$_case/home/.claude/.starter-kit-plugin-provenance.json" ]] \
    && [[ "$(cat "$_case/rc.txt")" == 0 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: prior manifest selection never adopts a pre-existing plugin"
  _prov_run_case legacy-update "security-guidance" \
    $'❯ security-guidance@claude-plugins-official\n  Scope: user' \
    0 0 0 true false true auto 0 \
    "security-guidance,code-review@third-party"
  _case="$_PROV_DIR/state/legacy-update"
  if grep -qx \
      "plugin install security-guidance --scope user" \
      "$_case/calls.log" \
    && [[ "$(cat "$_case/rc.txt")" == 0 ]] \
    && [[ ! -e \
      "$_case/home/.claude/.starter-kit-plugin-provenance.json" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: prior manifest marketplace mismatch is not migrated"
  _prov_run_case legacy-wrong-market "security-guidance" \
    $'❯ security-guidance@claude-plugins-official\n  Scope: user' \
    0 0 0 true false true auto 0 "security-guidance@third-party"
  _case="$_PROV_DIR/state/legacy-wrong-market"
  if grep -qx \
      "plugin install security-guidance --scope user" \
      "$_case/calls.log" \
    && [[ "$(cat "$_case/rc.txt")" == 0 ]] \
    && [[ ! -e \
      "$_case/home/.claude/.starter-kit-plugin-provenance.json" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: project scope does not suppress user install"
  _prov_run_case project-only "security-guidance" \
    $'❯ security-guidance@claude-plugins-official\n  Scope: project' \
    0 0 0 true
  _case="$_PROV_DIR/state/project-only"
  _marker="$_case/home/.claude/.starter-kit-plugin-provenance.json"
  if grep -qx \
      "plugin install security-guidance --scope user" \
      "$_case/calls.log" \
    && [[ "$(cat "$_case/rc.txt")" == 0 ]] \
    && jq -e '.installed_by_kit == [
      "security-guidance@claude-plugins-official"]' \
      "$_marker" >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: failed commit keeps verified retry state"
  _prov_run_case provenance-retry "security-guidance" "" \
    0 0 0 true false true auto 17
  _case="$_PROV_DIR/state/provenance-retry"
  _marker="$_case/home/.claude/.starter-kit-plugin-provenance.json"
  if grep -q 'Could not record starter-kit plugin ownership' "$_case/out.log" \
    && [[ "$(cat "$_case/rc.txt")" == 1 ]] \
    && jq -e '.installed_by_kit == [] and .verified_commit_by_kit == [
      "security-guidance@claude-plugins-official"]' "$_marker" >/dev/null; then
    _first_pending=true
  else
    _first_pending=false
  fi
  _prov_run_case provenance-retry "security-guidance" "" \
    0 0 0 true false true
  if [[ "$_first_pending" == "true" ]] \
    && ! grep -q "plugin install" "$_case/calls.log" \
    && [[ "$(cat "$_case/rc.txt")" == 0 ]] \
    && jq -e '.installed_by_kit == [
      "security-guidance@claude-plugins-official"]
      and (has("pending_install_by_kit") | not)
      and (has("verified_commit_by_kit") | not)' "$_marker" >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: verified retry repairs a removed plugin"
  _prov_run_case provenance-repair "security-guidance" "" \
    0 0 0 true false true auto 17
  _case="$_PROV_DIR/state/provenance-repair"
  _marker="$_case/home/.claude/.starter-kit-plugin-provenance.json"
  if [[ "$(cat "$_case/rc.txt")" == 1 ]] \
    && jq -e '.installed_by_kit == [] and .verified_commit_by_kit == [
      "security-guidance@claude-plugins-official"]' \
      "$_marker" >/dev/null; then
    _first_pending=true
  else
    _first_pending=false
  fi
  rm -f "$_case/installed-state" "$_case/install-seen"
  _prov_run_case provenance-repair "security-guidance" "" \
    0 0 0 true false true
  if [[ "$_first_pending" == "true" ]] \
    && grep -qx \
      "plugin install security-guidance --scope user" \
      "$_case/calls.log" \
    && [[ "$(cat "$_case/rc.txt")" == 0 ]] \
    && jq -e '.installed_by_kit == [
      "security-guidance@claude-plugins-official"]
      and (has("pending_install_by_kit") | not)
      and (has("verified_commit_by_kit") | not)' "$_marker" >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: invalid prior provenance is never overwritten"
  _case="$_PROV_DIR/state/invalid-prior"
  mkdir -p "$_case/home/.claude"
  printf '{"version":99,"installed_by_kit":[]}\n' \
    > "$_case/home/.claude/.starter-kit-plugin-provenance.json"
  chmod 600 "$_case/home/.claude/.starter-kit-plugin-provenance.json"
  _before="$(cksum < "$_case/home/.claude/.starter-kit-plugin-provenance.json")"
  _prov_run_case invalid-prior "security-guidance" "" 0 0 0 true
  _after="$(cksum < "$_case/home/.claude/.starter-kit-plugin-provenance.json")"
  if [[ "$_before" == "$_after" ]] \
    && grep -q 'Could not prepare starter-kit plugin ownership' "$_case/out.log" \
    && ! grep -q 'plugin install' "$_case/calls.log" \
    && [[ "$(cat "$_case/rc.txt")" == 1 ]] \
    && [[ ! -e "$_case/home/.claude/.starter-kit-plugin-provenance.lock" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="plugin provenance: staged schema is strict and authority-free"
  _schema_dir="$_PROV_DIR/state/schema"
  mkdir -p "$_schema_dir"
  if (
    source "$PROJECT_DIR/lib/plugin-provenance.sh"
    jq -n '{version:1,installed_by_kit:["old@market"]}' \
      > "$_schema_dir/legacy"
    jq -n '{version:1,installed_by_kit:[],
      pending_install_by_kit:["new@market"]}' \
      > "$_schema_dir/pending"
    jq -n '{version:1,installed_by_kit:[],
      verified_commit_by_kit:["verified@market"]}' \
      > "$_schema_dir/verified"
    jq -n '{version:1,installed_by_kit:["owned@market"],
      pending_install_by_kit:["pending@market"],
      verified_commit_by_kit:["verified@market"]}' \
      > "$_schema_dir/staged-nonoverlap"
    jq -n '{version:1,installed_by_kit:["same@market"],
      pending_install_by_kit:["same@market"]}' > "$_schema_dir/overlap"
    jq -n '{version:1,installed_by_kit:[],
      pending_install_by_kit:["dup@market","dup@market"]}' \
      > "$_schema_dir/duplicate"
    jq -n '{version:1,installed_by_kit:[],
      verified_commit_by_kit:["dup@market","dup@market"]}' \
      > "$_schema_dir/duplicate-verified"
    jq -n '{version:1,installed_by_kit:["same@market"],
      verified_commit_by_kit:["same@market"]}' \
      > "$_schema_dir/overlap-verified"
    jq -n '{version:1,installed_by_kit:[],
      pending_install_by_kit:["same@market"],
      verified_commit_by_kit:["same@market"]}' \
      > "$_schema_dir/overlap-staged"
    jq -n '{version:1,installed_by_kit:[],
      pending_install_by_kit:[],extra:true}' \
      > "$_schema_dir/unknown"
    jq -n '{version:1,installed_by_kit:["owned@market"],
      pending_install_by_kit:false}' > "$_schema_dir/false-pending"
    jq -n '{version:1,installed_by_kit:["owned@market"],
      pending_install_by_kit:null}' > "$_schema_dir/null-pending"
    jq -n '{version:1,installed_by_kit:["owned@market"],
      verified_commit_by_kit:false}' > "$_schema_dir/false-verified"
    jq -n '{version:1,installed_by_kit:["owned@market"],
      verified_commit_by_kit:null}' > "$_schema_dir/null-verified"
    jq -n '{version:1,
      installed_by_kit:([range(0;256) | "p\(.)@market"] | sort),
      pending_install_by_kit:["overflow@market"]}' \
      > "$_schema_dir/overflow"
    jq -n '{version:1,
      installed_by_kit:([range(0;255) | "p\(.)@market"] | sort),
      verified_commit_by_kit:["verified@market"]}' \
      > "$_schema_dir/limit"
    jq -n '{version:1,installed_by_kit:[],
      pending_install_by_kit:[1]}' > "$_schema_dir/nonstring"
    jq -n '{version:1,installed_by_kit:[],
      verified_commit_by_kit:["bad/id@market"]}' \
      > "$_schema_dir/invalid-id"
    printf '%s\n%s\n' \
      '{"version":99,"installed_by_kit":[]}' \
      '{"version":1,"installed_by_kit":[]}' \
      > "$_schema_dir/multiple-documents"
    chmod 600 "$_schema_dir"/*
    _plugin_provenance_json_valid "$_schema_dir/legacy" \
      && _plugin_provenance_json_valid "$_schema_dir/pending" \
      && _plugin_provenance_json_valid "$_schema_dir/verified" \
      && _plugin_provenance_json_valid "$_schema_dir/staged-nonoverlap" \
      && _plugin_provenance_json_valid "$_schema_dir/limit" \
      && ! _plugin_provenance_json_valid "$_schema_dir/overlap" \
      && ! _plugin_provenance_json_valid "$_schema_dir/duplicate" \
      && ! _plugin_provenance_json_valid \
        "$_schema_dir/duplicate-verified" \
      && ! _plugin_provenance_json_valid \
        "$_schema_dir/overlap-verified" \
      && ! _plugin_provenance_json_valid "$_schema_dir/overlap-staged" \
      && ! _plugin_provenance_json_valid "$_schema_dir/unknown" \
      && ! _plugin_provenance_json_valid "$_schema_dir/false-pending" \
      && ! _plugin_provenance_json_valid "$_schema_dir/null-pending" \
      && ! _plugin_provenance_json_valid "$_schema_dir/false-verified" \
      && ! _plugin_provenance_json_valid "$_schema_dir/null-verified" \
      && ! _plugin_provenance_json_valid "$_schema_dir/overflow" \
      && ! _plugin_provenance_json_valid "$_schema_dir/nonstring" \
      && ! _plugin_provenance_json_valid "$_schema_dir/invalid-id" \
      && ! _plugin_provenance_json_valid \
        "$_schema_dir/multiple-documents"
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="plugin provenance: native Windows modes stay strict elsewhere"
  _platform_root="$_PROV_DIR/state/platform-modes"
  mkdir -p "$_platform_root/lock"
  printf '%s\n' '{"version":1,"installed_by_kit":[]}' \
    > "$_platform_root/marker"
  _platform_token=starter-kit-platform-fixture
  _platform_process_identity="$(
    source "$PROJECT_DIR/lib/plugin-provenance.sh"
    _plugin_provenance_process_identity "$$"
  )"
  printf '%s\t%s\t%s\n' "$_platform_token" "$$" \
    "$_platform_process_identity" > "$_platform_root/lock/owner"
  chmod 644 "$_platform_root/marker" "$_platform_root/lock/owner"
  if (
    source "$PROJECT_DIR/lib/plugin-provenance.sh"
    _platform_lock_identity="$(_plugin_provenance_stat \
      identity "$_platform_root/lock")" || exit 1
    for _platform in MSYS_NT-10.0 MINGW64_NT-10.0 \
      CLANG64_NT-10.0 UCRT64_NT-10.0; do
      uname() { printf '%s\n' "$_platform"; }
      _plugin_provenance_json_valid "$_platform_root/marker" \
        && _plugin_provenance_lock_owner_valid \
          "$_platform_root/lock" "$_platform_token" \
          "$_platform_lock_identity" \
        && _plugin_provenance_file_mode_valid 666 \
        && ! _plugin_provenance_file_mode_valid 640 \
        || exit 1
    done
    # WSL reports Linux from uname and must retain the POSIX 0600 rule.
    uname() { printf 'Linux\n'; }
    _plugin_provenance_file_mode_valid 600 \
      && ! _plugin_provenance_json_valid "$_platform_root/marker" \
      && ! _plugin_provenance_lock_owner_valid \
        "$_platform_root/lock" "$_platform_token" \
        "$_platform_lock_identity" \
      && ! _plugin_provenance_file_mode_valid 644 \
      && ! _plugin_provenance_file_mode_valid 666
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="plugin provenance: failed lock validation cleans only its own lock"
  _lock_failure_root="$_PROV_DIR/state/lock-failure"
  mkdir -p "$_lock_failure_root/mode" "$_lock_failure_root/binding" \
    "$_lock_failure_root/ownership"
  if (
    (
      source "$PROJECT_DIR/lib/plugin-provenance.sh"
      _mode_failure_flag="$_lock_failure_root/mode-failed-once"
      _plugin_provenance_file_mode_valid() {
        if [[ ! -e "$_mode_failure_flag" ]]; then
          : > "$_mode_failure_flag"
          return 1
        fi
        [[ "$1" == "600" ]]
      }
      ! _plugin_provenance_prepare "$_lock_failure_root/mode" \
        mode-check@market || exit 1
      [[ ! -e "$_lock_failure_root/mode/.starter-kit-plugin-provenance.lock" ]] \
        || exit 1
      _plugin_provenance_prepare "$_lock_failure_root/mode" \
        mode-check@market || exit 1
    ) || exit 1
    (
      source "$PROJECT_DIR/lib/plugin-provenance.sh"
      _binding_failure_flag="$_lock_failure_root/binding-failed-once"
      _plugin_provenance_binding_matches() {
        local root="$1" expected_physical="$2" expected_identity="$3"
        if [[ ! -e "$_binding_failure_flag" ]]; then
          : > "$_binding_failure_flag"
          return 1
        fi
        (
          cd -P "$root" 2>/dev/null || exit 1
          [[ "$(pwd -P)" == "$expected_physical" ]] || exit 1
          [[ "$(_plugin_provenance_stat identity .)" \
            == "$expected_identity" ]]
        )
      }
      ! _plugin_provenance_prepare "$_lock_failure_root/binding" \
        binding-check@market || exit 1
      [[ ! -e \
        "$_lock_failure_root/binding/.starter-kit-plugin-provenance.lock" ]] \
        || exit 1
      _plugin_provenance_prepare "$_lock_failure_root/binding" \
        binding-check@market || exit 1
    ) || exit 1
    (
      source "$PROJECT_DIR/lib/plugin-provenance.sh"
      _owned_lock="$_lock_failure_root/ownership/lock"
      _owned_token=starter-kit-owned-lock
      mkdir "$_owned_lock"
      _owned_process_identity="$(_plugin_provenance_process_identity "$$")" \
        || exit 1
      printf '%s\t%s\t%s\n' "$_owned_token" "$$" \
        "$_owned_process_identity" > "$_owned_lock/owner"
      chmod 600 "$_owned_lock/owner"
      _owned_identity="$(_plugin_provenance_stat identity "$_owned_lock")" \
        || exit 1
      ! _plugin_provenance_lock_cleanup_owned \
        "$_owned_lock" wrong-token "$_owned_identity" \
        && [[ -d "$_owned_lock" ]] \
        && ! _plugin_provenance_lock_cleanup_owned \
          "$_owned_lock" "$_owned_token" 0:0 \
        && [[ -d "$_owned_lock" ]] \
        && _plugin_provenance_lock_cleanup_owned \
          "$_owned_lock" "$_owned_token" "$_owned_identity"
    )
  ) \
    && [[ ! -e "$_lock_failure_root/mode/.starter-kit-plugin-provenance.lock" ]] \
    && [[ ! -e "$_lock_failure_root/binding/.starter-kit-plugin-provenance.lock" ]] \
    && ! compgen -G "$_lock_failure_root/*/*.cleanup-*" >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="plugin provenance: only an exact dead process owner is reclaimed"
  _dead_lock_root="$_PROV_DIR/state/dead-lock"
  _live_lock_root="$_PROV_DIR/state/live-lock"
  _bad_lock_root="$_PROV_DIR/state/bad-lock"
  mkdir -p "$_dead_lock_root/.starter-kit-plugin-provenance.lock" \
    "$_live_lock_root/.starter-kit-plugin-provenance.lock" \
    "$_bad_lock_root/.starter-kit-plugin-provenance.lock"
  if (
    source "$PROJECT_DIR/lib/plugin-provenance.sh"
    _live_identity="$(_plugin_provenance_process_identity "$$")" || exit 1
    printf 'dead-token\t99999999\t1:1\n' \
      > "$_dead_lock_root/.starter-kit-plugin-provenance.lock/owner"
    printf 'live-token\t%s\t%s\n' "$$" "$_live_identity" \
      > "$_live_lock_root/.starter-kit-plugin-provenance.lock/owner"
    printf 'malformed\n' \
      > "$_bad_lock_root/.starter-kit-plugin-provenance.lock/owner"
    chmod 600 \
      "$_dead_lock_root/.starter-kit-plugin-provenance.lock/owner" \
      "$_live_lock_root/.starter-kit-plugin-provenance.lock/owner" \
      "$_bad_lock_root/.starter-kit-plugin-provenance.lock/owner"

    _dead_binding="$(_plugin_provenance_root_binding "$_dead_lock_root")" \
      || exit 1
    _dead_physical="${_dead_binding%$'\t'*}"
    _dead_identity="${_dead_binding##*$'\t'}"
    _new_lock="$(_plugin_provenance_lock_acquire_bound \
      "$_dead_lock_root" "$_dead_physical" "$_dead_identity")" || exit 1
    _new_token="${_new_lock%$'\t'*}"
    _new_identity="${_new_lock##*$'\t'}"
    _plugin_provenance_lock_release_bound \
      "$_dead_lock_root" "$_dead_physical" "$_dead_identity" \
      "$_new_token" "$_new_identity" || exit 1

    for _blocked_root in "$_live_lock_root" "$_bad_lock_root"; do
      _blocked_binding="$(_plugin_provenance_root_binding "$_blocked_root")" \
        || exit 1
      _blocked_physical="${_blocked_binding%$'\t'*}"
      _blocked_identity="${_blocked_binding##*$'\t'}"
      ! _plugin_provenance_lock_acquire_bound \
        "$_blocked_root" "$_blocked_physical" "$_blocked_identity" \
        || exit 1
      [[ -d "$_blocked_root/.starter-kit-plugin-provenance.lock" ]] \
        || exit 1
    done
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="plugin provenance: list parser rejects ambiguous entries"
  if (
    source "$PROJECT_DIR/lib/plugin-provenance.sh"
    _valid_list=$'Installed plugins:\r\n\r\n  ❯ owned@market\r\n    Version: 1.0.0\r\n    Scope: user\r\n    Error: cached load failure\r\n    Note: retry available\r\n    Status: enabled\r\n'
    _plugin_provenance_list_has_user_exact "$_valid_list" owned@market \
      && _plugin_provenance_list_exact_entries \
        'No plugins installed. Use `claude plugin install` to install a plugin.' \
        >/dev/null \
      && ! _plugin_provenance_list_exact_entries \
        $'Installed plugins:\n\n! owned@market\n  Scope: user' >/dev/null \
      && ! _plugin_provenance_list_exact_entries \
        $'Installed plugins:\n\n❯ owned@market\n  Scope: user\n❯ rogue@bad/market\n  Scope: user' \
        >/dev/null \
      && ! _plugin_provenance_list_exact_entries \
        $'Installed plugins:\n\n❯ owned@market\n  Scope: project\n  Scope: user' >/dev/null \
      && ! _plugin_provenance_list_exact_entries \
        $'Installed plugins:\n\nScope: user\n❯ owned@market\n  Scope: user' >/dev/null \
      && ! _plugin_provenance_list_exact_entries \
        $'Installed plugins:\n\n❯ owned@market\n  Version: 1.0.0' >/dev/null \
      && ! _plugin_provenance_list_exact_entries \
        $'Installed plugins:\n\n❯ owned@market\n  Scope: user\n  Bogus: value' >/dev/null \
      && ! _plugin_provenance_list_has_user_exact \
        $'Installed plugins:\n\nowned@market' owned@market \
      && ! _plugin_provenance_list_exact_entries 'garbage' >/dev/null
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="plugin provenance: staged transitions preserve proof boundaries"
  _transition_root="$_PROV_DIR/state/transitions/home/.claude"
  _cancel_root="$_PROV_DIR/state/cancel/home/.claude"
  mkdir -p "$_transition_root" "$_cancel_root"
  if (
    source "$PROJECT_DIR/lib/plugin-provenance.sh"
    _plugin=security-guidance@claude-plugins-official
    _plugin_provenance_prepare "$_transition_root" "$_plugin" \
      || exit 1
    jq -e --arg plugin "$_plugin" '
      .installed_by_kit == []
      and .pending_install_by_kit == [$plugin]
      and (has("verified_commit_by_kit") | not)
    ' "$_transition_root/.starter-kit-plugin-provenance.json" \
      >/dev/null || exit 1
    _transition_before="$(cksum \
      < "$_transition_root/.starter-kit-plugin-provenance.json")"
    ! _plugin_provenance_record "$_transition_root" "$_plugin" \
      || exit 1
    [[ "$(cksum \
      < "$_transition_root/.starter-kit-plugin-provenance.json")" \
      == "$_transition_before" ]] || exit 1
    _plugin_provenance_verify "$_transition_root" "$_plugin" \
      || exit 1
    jq -e --arg plugin "$_plugin" '
      .installed_by_kit == []
      and .verified_commit_by_kit == [$plugin]
      and (has("pending_install_by_kit") | not)
    ' "$_transition_root/.starter-kit-plugin-provenance.json" \
      >/dev/null || exit 1
    _plugin_provenance_record "$_transition_root" "$_plugin" \
      || exit 1
    jq -e --arg plugin "$_plugin" '
      .installed_by_kit == [$plugin]
      and (has("pending_install_by_kit") | not)
      and (has("verified_commit_by_kit") | not)
    ' "$_transition_root/.starter-kit-plugin-provenance.json" \
      >/dev/null || exit 1
    _plugin_provenance_prepare "$_cancel_root" "$_plugin" || exit 1
    _plugin_provenance_cancel_pending "$_cancel_root" "$_plugin" \
      || exit 1
    jq -e '.installed_by_kit == []
      and (has("pending_install_by_kit") | not)
      and (has("verified_commit_by_kit") | not)' \
      "$_cancel_root/.starter-kit-plugin-provenance.json" \
      >/dev/null || exit 1
    _cancel_before="$(cksum \
      < "$_cancel_root/.starter-kit-plugin-provenance.json")"
    ! _plugin_provenance_verify "$_cancel_root" "$_plugin" \
      || exit 1
    [[ "$(cksum \
      < "$_cancel_root/.starter-kit-plugin-provenance.json")" \
      == "$_cancel_before" ]]
  ) \
    && [[ ! -e "$_transition_root/.starter-kit-plugin-provenance.lock" ]] \
    && [[ ! -e "$_cancel_root/.starter-kit-plugin-provenance.lock" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="plugin provenance: completed transitions are idempotent"
  _idempotent_root="$_PROV_DIR/state/idempotent/home/.claude"
  _untracked_root="$_PROV_DIR/state/untracked/home/.claude"
  mkdir -p "$_idempotent_root" "$_untracked_root"
  printf '%s\n' '{"version":1,"installed_by_kit":[
    "security-guidance@claude-plugins-official"]}' \
    > "$_idempotent_root/.starter-kit-plugin-provenance.json"
  chmod 600 "$_idempotent_root/.starter-kit-plugin-provenance.json"
  _idempotent_before="$(cksum \
    < "$_idempotent_root/.starter-kit-plugin-provenance.json")"
  if (
    source "$PROJECT_DIR/lib/plugin-provenance.sh"
    _plugin_provenance_prepare \
      "$_idempotent_root" security-guidance@claude-plugins-official \
      && _plugin_provenance_record \
        "$_idempotent_root" security-guidance@claude-plugins-official \
      && ! _plugin_provenance_record \
        "$_untracked_root" security-guidance@claude-plugins-official
  ) \
    && [[ "$(cksum \
      < "$_idempotent_root/.starter-kit-plugin-provenance.json")" \
      == "$_idempotent_before" ]] \
    && [[ ! -e "$_idempotent_root/.starter-kit-plugin-provenance.lock" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: untrusted list and failed install create no authority"
  _prov_run_case list-failed "security-guidance" "untrusted" 7 0 0 true
  _prov_run_case list-failed-update "security-guidance" "untrusted" \
    7 0 0 true false true
  _prov_run_case install-failed "security-guidance" "" 0 0 9 true
  _prov_run_case list-failed-extra "security-guidance" "" \
    7 0 0 true false false extra
  _prov_run_case list-failed-scope "security-guidance" "" \
    7 0 0 true false false wrong-scope
  _prov_run_case list-install-failed "security-guidance" "" \
    7 0 9 true false false auto 0 "" true
  _failed_marker="$_PROV_DIR/state/install-failed/home/.claude/.starter-kit-plugin-provenance.json"
  if ! grep -q "plugin install security-guidance --scope user" \
      "$_PROV_DIR/state/list-failed/calls.log" \
    && [[ ! -e "$_PROV_DIR/state/list-failed/home/.claude/.starter-kit-plugin-provenance.json" ]] \
    && ! grep -q "plugin install security-guidance --scope user" \
      "$_PROV_DIR/state/list-failed-update/calls.log" \
    && [[ ! -e "$_PROV_DIR/state/list-failed-update/home/.claude/.starter-kit-plugin-provenance.json" ]] \
    && [[ "$(cat "$_PROV_DIR/state/list-failed/rc.txt")" == 1 ]] \
    && [[ "$(cat "$_PROV_DIR/state/list-failed-update/rc.txt")" == 1 ]] \
    && [[ "$(cat "$_PROV_DIR/state/list-failed-extra/rc.txt")" == 1 ]] \
    && [[ "$(cat "$_PROV_DIR/state/list-failed-scope/rc.txt")" == 1 ]] \
    && [[ "$(cat "$_PROV_DIR/state/list-install-failed/rc.txt")" == 1 ]] \
    && [[ ! -e "$_PROV_DIR/state/list-failed-extra/home/.claude/.starter-kit-plugin-provenance.json" ]] \
    && [[ ! -e "$_PROV_DIR/state/list-failed-scope/home/.claude/.starter-kit-plugin-provenance.json" ]] \
    && grep -q "plugin install security-guidance --scope user" \
      "$_PROV_DIR/state/list-install-failed/calls.log" \
    && jq -e '.installed_by_kit == [] and .pending_install_by_kit == [
      "security-guidance@claude-plugins-official"]' \
      "$_PROV_DIR/state/list-install-failed/home/.claude/.starter-kit-plugin-provenance.json" \
      >/dev/null \
    && jq -e '.installed_by_kit == [] and .pending_install_by_kit == [
      "security-guidance@claude-plugins-official"]' \
      "$_failed_marker" >/dev/null \
    && [[ "$(cat "$_PROV_DIR/state/install-failed/rc.txt")" == 1 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: missing CLI and dry-run create no authority"
  _prov_run_case no-cli "security-guidance" "" 0 0 0 false
  _prov_run_case dry-run "security-guidance" "" 0 0 0 true true
  if grep -qF "Skipping plugin install" "$_PROV_DIR/state/no-cli/out.log" \
    && [[ ! -e "$_PROV_DIR/state/no-cli/home/.claude/.starter-kit-plugin-provenance.json" ]] \
    && [[ ! -e "$_PROV_DIR/state/dry-run/home/.claude/.starter-kit-plugin-provenance.json" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: a fresh empty selection creates no history"
  _prov_run_case fresh-deselect "" "" 0 0 0 true
  if [[ ! -s "$_PROV_DIR/state/fresh-deselect/calls.log" ]] \
    && [[ ! -e "$_PROV_DIR/state/fresh-deselect/home/.claude/.starter-kit-plugin-provenance.json" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install_selected_plugins: deselection preserves prior install history"
  _prov_run_case deselect "security-guidance" "" 0 0 0 true
  _case="$_PROV_DIR/state/deselect"
  _before="$(cksum < "$_case/home/.claude/.starter-kit-plugin-provenance.json")"
  env -i HOME="$_case/home" TMPDIR="$_case/tmp" APPDATA="$_case/appdata" \
    LOCALAPPDATA="$_case/localappdata" NPM_CONFIG_PREFIX="$_case/npm" \
    npm_config_prefix="$_case/npm" PATH="$_PROV_FIXED_PATH" LC_ALL=C TERM=dumb \
    bash -c '
      set -euo pipefail
      source "$1/setup.sh"
      source "$1/lib/plugin-provenance.sh"
      SELECTED_PLUGINS=""
      install_selected_plugins
    ' _ "$PROJECT_DIR"
  _after="$(cksum < "$_case/home/.claude/.starter-kit-plugin-provenance.json")"
  if [[ "$_before" == "$_after" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

if grep -qF '. "$PROJECT_DIR/lib/plugin-provenance.sh"' "$PROJECT_DIR/setup.sh" \
  && grep -qF '. "$_uninstall_source_dir/lib/plugin-provenance.sh"' \
    "$PROJECT_DIR/uninstall.sh"; then
  pass "plugin provenance: setup and uninstall source the same helper implementation"
else
  fail "plugin provenance: setup/uninstall helper loading drifted"
fi

rm -rf "$_PROV_DIR"
unset _PROV_DIR _PROV_FIXED_PATH _case _marker _mode _before _after _first_pending
unset _failed_marker _postcondition_ok _post_mode _schema_dir _project_pending
unset _idempotent_root _idempotent_before
unset _untracked_root _manual_pending _transition_root _cancel_root
unset -f _prov_run_case
