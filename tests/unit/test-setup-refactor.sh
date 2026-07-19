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
    run_update() { return 0; }
    _detect_and_write_pending_features() { return 0; }
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
if [[ "${1:-}" == "plugin" && "${2:-}" == "list" ]]; then
  printf "%s\n" "${FAKE_CLAUDE_PLUGIN_LIST:-}"
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
' > "$_ISP_DIR/bin/claude"
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
