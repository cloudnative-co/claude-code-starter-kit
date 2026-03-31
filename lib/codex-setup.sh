#!/bin/bash
# lib/codex-setup.sh - Codex Plugin setup (CLI install, auth, plugin registration)
# Requires: lib/colors.sh, lib/detect.sh, lib/prerequisites.sh (_get_shell_rc_file),
#           wizard/wizard.sh (is_true)
# Uses globals: ENABLE_CODEX_PLUGIN, WIZARD_NONINTERACTIVE, _SETUP_TMP_FILES[],
#               STR_CODEX_*, STR_CHOICE
# Exports: run_codex_setup(), _setup_codex_plugin(), _install_codex_cli(),
#          _run_with_timeout(), _verify_openai_key(), _save_openai_key()
# Dry-run: guarded externally (setup.sh logs EXTERNAL, does not call run_codex_setup)
set -euo pipefail

# ---------------------------------------------------------------------------
# Codex Plugin helpers
# ---------------------------------------------------------------------------

# Portable timeout wrapper (macOS lacks `timeout` from coreutils)
_run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout &>/dev/null; then
    timeout "$secs" "$@"
  else
    local _stdout_file _stderr_file
    _stdout_file="$(mktemp)"
    _stderr_file="$(mktemp)"
    _SETUP_TMP_FILES+=("$_stdout_file" "$_stderr_file")

    # Background the command and capture its output so command substitution
    # still works on macOS where `timeout` is unavailable.
    "$@" >"$_stdout_file" 2>"$_stderr_file" &
    local pid=$!
    ( sleep "$secs" && kill "$pid" 2>/dev/null ) &
    local watcher=$!
    # Capture exit code safely under set -e (bare wait would abort on non-zero)
    local rc=0
    wait "$pid" 2>/dev/null || rc=$?
    # Kill the watcher subshell and its sleep child to avoid orphan processes
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true

    cat "$_stdout_file"
    cat "$_stderr_file" >&2
    return "$rc"
  fi
}

_verify_openai_key() {
  local key="$1"
  # Pass auth header via --config stdin to avoid exposing the key in ps output
  local http_code
  http_code="$(printf 'header = "Authorization: Bearer %s"\n' "$key" | \
    curl -s --max-time 10 -o /dev/null -w '%{http_code}' \
    --config - \
    https://api.openai.com/v1/models 2>/dev/null || echo "000")"
  [[ "$http_code" == "200" ]]
}

_run_capture() {
  local __outvar="$1"
  shift
  local _output="" _rc=0
  _output="$("$@" 2>&1)" || _rc=$?
  printf -v "$__outvar" '%s' "$_output"
  return "$_rc"
}

_save_openai_key() {
  local key="$1"
  local rc_file="$2"
  # Remove existing OPENAI_API_KEY line (if any) then append via printf.
  # This avoids sed metacharacter injection from the API key value.
  # Match both 'export OPENAI_API_KEY=' and bare 'OPENAI_API_KEY='.
  if grep -q '^\(export \)\{0,1\}OPENAI_API_KEY=' "$rc_file" 2>/dev/null; then
    local tmp_rc orig_mode
    tmp_rc="$(mktemp)"
    _SETUP_TMP_FILES+=("$tmp_rc")
    # Preserve original file permissions (umask 077 would make the new file 0600)
    orig_mode="$(stat -f '%Lp' "$rc_file" 2>/dev/null || stat -c '%a' "$rc_file" 2>/dev/null || { warn "Could not detect permissions for $rc_file, defaulting to 600"; echo '600'; })"
    grep -v '^\(export \)\{0,1\}OPENAI_API_KEY=' "$rc_file" > "$tmp_rc"
    mv "$tmp_rc" "$rc_file"
    chmod "$orig_mode" "$rc_file"
  fi
  printf '\n# OpenAI API Key (added by claude-code-starter-kit)\nexport OPENAI_API_KEY=%q\n' "$key" >> "$rc_file"
  export OPENAI_API_KEY="$key"
}

# _get_shell_rc_file is now in lib/prerequisites.sh (moved in v0.24.0)

_codex_login_status() {
  if ! command -v codex &>/dev/null; then
    return 1
  fi
  local _status
  _status="$(_run_with_timeout 15 codex login status 2>/dev/null)" || return 1
  [[ "$_status" == Logged\ in* ]] || return 1
  printf '%s\n' "$_status"
}

_smoke_test_openai_key() {
  local _key="${OPENAI_API_KEY:-}"
  if [[ -z "$_key" ]]; then
    return 1
  fi
  local _models_code _responses_code
  _models_code="$(printf 'header = "Authorization: Bearer %s"\n' "$_key" | \
    curl -s --max-time 10 -o /dev/null -w '%{http_code}' \
    --config - \
    https://api.openai.com/v1/models 2>/dev/null || echo "000")"
  _responses_code="$(printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$_key" | \
    curl -s --max-time 10 -o /dev/null -w '%{http_code}' \
    --config - \
    -X POST \
    -d '{"model":"gpt-4o-mini","input":"test"}' \
    https://api.openai.com/v1/responses 2>/dev/null || echo "000")"
  [[ "$_models_code" == "200" ]] && [[ "$_responses_code" != "401" ]] && [[ "$_responses_code" != "403" ]]
}

_ensure_openai_key_for_codex() {
  local rc_file="$1"
  local _existing_key=""
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    _existing_key="$OPENAI_API_KEY"
  elif grep -Eq '^[[:space:]]*(export[[:space:]]+)?OPENAI_API_KEY=' "$rc_file" 2>/dev/null; then
    _existing_key="$(grep -E '^[[:space:]]*(export[[:space:]]+)?OPENAI_API_KEY=' "$rc_file" \
      | tail -1 \
      | sed -E 's/^[[:space:]]*(export[[:space:]]+)?OPENAI_API_KEY=//; s/^"//; s/"$//')"
    export OPENAI_API_KEY="$_existing_key"
  fi

  if [[ -n "$_existing_key" ]]; then
    printf "\n"
    ok "$STR_CODEX_API_KEY_ALREADY"
    info "$STR_CODEX_API_KEY_VERIFYING"
    if _verify_openai_key "$_existing_key"; then
      ok "$STR_CODEX_API_KEY_VALID"
      return 0
    fi
    warn "$STR_CODEX_API_KEY_INVALID"
  else
    printf "\n"
  fi

  _prompt_openai_key "$rc_file"
}

_confirm_api_key_auth_ready() {
  while true; do
    printf "\n"
    info "$STR_CODEX_API_KEY_SMOKE_TESTING"
    if _smoke_test_openai_key; then
      ok "$STR_CODEX_API_KEY_SMOKE_OK"
      return 0
    fi
    warn "$STR_CODEX_API_KEY_SMOKE_FAILED"
    printf "  1) %s\n" "$STR_CODEX_API_KEY_RETRY_YES"
    printf "  2) %s\n" "$STR_CODEX_API_KEY_RETRY_NO"
    local _retry=""
    read -r -p "${STR_CHOICE}: " _retry
    if [[ "$_retry" != "1" ]]; then
      return 1
    fi
    if ! _ensure_openai_key_for_codex "$1"; then
      return 1
    fi
    printf "\n"
    info "$STR_CODEX_LOGIN_RUNNING"
    if ! printf '%s' "$OPENAI_API_KEY" | _run_with_timeout 30 codex login --with-api-key &>/dev/null; then
      warn "$STR_CODEX_LOGIN_FAILED"
      info "  printenv OPENAI_API_KEY | codex login --with-api-key"
    fi
  done
}

_install_codex_cli() {
  if command -v codex &>/dev/null; then
    ok "$STR_CODEX_CLI_ALREADY"
    return 0
  fi

  info "$STR_CODEX_CLI_INSTALLING"
  local _codex_installed=false _last_error=""

  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew &>/dev/null; then
    local _brew_output=""
    if _run_capture _brew_output brew install codex; then
      _codex_installed=true
    else
      _last_error="brew install codex: ${_brew_output:-unknown error}"
    fi
  fi

  if [[ "$_codex_installed" != "true" ]] && command -v npm &>/dev/null; then
    local _npm_prefix _npm_output=""
    _npm_prefix="$(npm config get prefix 2>/dev/null || echo '/usr/local')"
    if [[ -w "${_npm_prefix}/lib" ]]; then
      if _run_capture _npm_output npm install -g @openai/codex; then
        _codex_installed=true
      else
        _last_error="npm install -g @openai/codex: ${_npm_output:-unknown error}"
      fi
    elif [[ "${WIZARD_NONINTERACTIVE:-false}" == "true" ]]; then
      _last_error="${STR_CODEX_CLI_SUDO_SKIPPED:-Non-interactive mode cannot prompt for sudo. Install Codex CLI manually.}"
    else
      if _run_capture _npm_output sudo npm install -g @openai/codex; then
        _codex_installed=true
      else
        _last_error="sudo npm install -g @openai/codex: ${_npm_output:-unknown error}"
      fi
    fi
  fi

  if [[ "$_codex_installed" == "true" ]] && ! command -v codex &>/dev/null && is_msys; then
    for _npm_dir in \
      "$(cygpath -u "${APPDATA:-}/npm" 2>/dev/null)" \
      "$(npm config get prefix 2>/dev/null)/bin"; do
      [[ -n "$_npm_dir" ]] && [[ -d "$_npm_dir" ]] && export PATH="$_npm_dir:$PATH"
    done
  fi

  if command -v codex &>/dev/null; then
    ok "$STR_CODEX_CLI_INSTALLED"
    return 0
  fi

  warn "$STR_CODEX_CLI_FAILED"
  [[ -n "$_last_error" ]] && warn "$_last_error"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    info "  brew install codex"
  fi
  info "  npm install -g @openai/codex"
  return 1
}

_prompt_codex_auth() {
  local rc_file="$1"
  while true; do
    printf "\n"
    info "$STR_CODEX_AUTH_REQUIRED"
    printf "  1) %s\n" "$STR_CODEX_AUTH_CHATGPT"
    printf "  2) %s\n" "$STR_CODEX_AUTH_DEVICE"
    printf "  3) %s\n" "$STR_CODEX_API_KEY_PROMPT"
    printf "  4) %s\n" "$STR_CODEX_AUTH_SKIP"
    local _auth_choice=""
    read -r -p "${STR_CHOICE}: " _auth_choice

    case "$_auth_choice" in
      1)
        printf "\n"
        info "$STR_CODEX_LOGIN_CHATGPT_RUNNING"
        if codex login; then
          ok "$STR_CODEX_LOGIN_DONE"
          return 0
        fi
        warn "$STR_CODEX_LOGIN_CHATGPT_FAILED"
        info "  codex login"
        ;;
      2)
        printf "\n"
        info "$STR_CODEX_LOGIN_DEVICE_RUNNING"
        if codex login --device-auth; then
          ok "$STR_CODEX_LOGIN_DONE"
          return 0
        fi
        warn "$STR_CODEX_LOGIN_DEVICE_FAILED"
        info "  codex login --device-auth"
        ;;
      3)
        if _ensure_openai_key_for_codex "$rc_file"; then
          printf "\n"
          info "$STR_CODEX_LOGIN_RUNNING"
          if printf '%s' "$OPENAI_API_KEY" | _run_with_timeout 30 codex login --with-api-key &>/dev/null; then
            ok "$STR_CODEX_LOGIN_DONE"
            if _confirm_api_key_auth_ready "$rc_file"; then
              return 0
            fi
            warn "$STR_CODEX_SETUP_INCOMPLETE"
          fi
          warn "$STR_CODEX_LOGIN_FAILED"
          info "  printenv OPENAI_API_KEY | codex login --with-api-key"
        fi
        ;;
      *)
        info "$STR_CODEX_AUTH_SKIPPED"
        info "  codex login"
        info "  codex login --device-auth"
        info "  printenv OPENAI_API_KEY | codex login --with-api-key"
        return 1
        ;;
    esac
  done
}

_prompt_openai_key() {
  local rc_file="$1"
  while true; do
    info "$STR_CODEX_API_KEY_HINT"
    printf "\n"
    printf "  1) %s\n" "$STR_CODEX_API_KEY_PROMPT"
    printf "  2) %s\n" "$STR_CODEX_API_KEY_SKIP"
    local _key_choice=""
    read -r -p "${STR_CHOICE}: " _key_choice

    case "$_key_choice" in
      1)
        printf "\n"
        local _api_key=""
        read -rs -p "  API Key: " _api_key
        printf "\n"
        if [[ -z "$_api_key" ]]; then
          info "$STR_CODEX_API_KEY_SKIPPED"
          info "  export OPENAI_API_KEY=\"your-api-key-here\""
          return 1
        fi
        # Verify the key against OpenAI API
        info "$STR_CODEX_API_KEY_VERIFYING"
        if _verify_openai_key "$_api_key"; then
          ok "$STR_CODEX_API_KEY_VALID"
          _save_openai_key "$_api_key" "$rc_file"
          ok "$STR_CODEX_API_KEY_SAVED ($rc_file)"
          return 0
        else
          warn "$STR_CODEX_API_KEY_INVALID"
          printf "\n"
          printf "  1) %s\n" "$STR_CODEX_API_KEY_RETRY_YES"
          printf "  2) %s\n" "$STR_CODEX_API_KEY_RETRY_NO"
          local _retry=""
          read -r -p "${STR_CHOICE}: " _retry
          if [[ "$_retry" != "1" ]]; then
            info "$STR_CODEX_API_KEY_SKIPPED"
            info "  export OPENAI_API_KEY=\"your-api-key-here\""
            return 1
          fi
          printf "\n"
        fi
        ;;
      *)
        info "$STR_CODEX_API_KEY_SKIPPED"
        info "  export OPENAI_API_KEY=\"your-api-key-here\""
        return 1
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Codex Plugin detection and management helpers
# ---------------------------------------------------------------------------

_codex_cli_ready() {
  command -v codex &>/dev/null
}

_codex_auth_ready() {
  _codex_login_status >/dev/null 2>&1
}

_codex_fully_ready() {
  _codex_cli_ready && _codex_auth_ready && _has_codex_plugin
}

_has_codex_plugin() {
  command -v claude &>/dev/null && claude plugin list 2>/dev/null | grep -qw "codex" 2>/dev/null
}

_has_legacy_mcp() {
  command -v claude &>/dev/null && claude mcp list 2>/dev/null | grep -qw "codex" 2>/dev/null
}

_install_codex_plugin() {
  if ! command -v claude &>/dev/null; then
    warn "${STR_CODEX_PLUGIN_FAILED:-Failed to install Codex plugin}"
    info "  claude plugin marketplace add openai/codex-plugin-cc"
    info "  claude plugin install codex --scope user"
    return 1
  fi
  local _marketplace_output="" _install_output=""
  if ! _run_capture _marketplace_output claude plugin marketplace add openai/codex-plugin-cc; then
    warn "${STR_CODEX_PLUGIN_MARKETPLACE_FAILED:-Failed to add Codex plugin marketplace. Continuing to install attempt:}"
    [[ -n "$_marketplace_output" ]] && info "  $_marketplace_output"
  fi
  if _run_capture _install_output claude plugin install codex --scope user; then
    return 0
  fi
  warn "${STR_CODEX_PLUGIN_FAILED:-Failed to install Codex plugin}"
  [[ -n "$_install_output" ]] && info "  $_install_output"
  info "  claude plugin marketplace add openai/codex-plugin-cc"
  info "  claude plugin install codex --scope user"
  return 1
}

_remove_legacy_mcp() {
  if _has_legacy_mcp; then
    local _remove_output=""
    if _run_capture _remove_output claude mcp remove codex; then
      return 0
    fi
    warn "${STR_CODEX_MCP_REMOVE_FAILED:-Failed to remove Codex MCP. Remove manually:}"
    [[ -n "$_remove_output" ]] && info "  $_remove_output"
    info "  claude mcp remove codex"
    return 1
  fi
  return 0  # nothing to remove
}

# ---------------------------------------------------------------------------
# Codex Plugin interactive setup
# ---------------------------------------------------------------------------
_setup_codex_plugin() {
  printf "\n"
  section "$STR_CODEX_SETUP_TITLE"

  # On MSYS/Git Bash, ensure npm global bin is in PATH
  if is_msys; then
    for _npm_dir in \
      "$(cygpath -u "${APPDATA:-}/npm" 2>/dev/null)" \
      "$(npm config get prefix 2>/dev/null)/bin"; do
      [[ -n "$_npm_dir" ]] && [[ -d "$_npm_dir" ]] && export PATH="$_npm_dir:$PATH"
    done
  fi

  # Fast path: if everything is already configured, skip all slow checks
  if command -v codex &>/dev/null \
    && _codex_login_status >/dev/null \
    && _has_codex_plugin; then
    ok "$STR_CODEX_CLI_ALREADY"
    ok "$STR_CODEX_LOGIN_ALREADY"
    ok "${STR_CODEX_PLUGIN_ALREADY:-Codex plugin is already installed}"
    return 0
  fi

  warn "$STR_CODEX_SETUP_NOTE"
  printf "\n"

  # Step 1: Install Codex CLI
  if ! _install_codex_cli; then
    printf "\n"
    warn "$STR_CODEX_SETUP_INCOMPLETE"
    return
  fi

  local _rc_file
  _rc_file="$(_get_shell_rc_file)"
  local _auth_ready=false
  local _plugin_ready=false

  # Step 2: Verify Codex CLI authentication
  printf "\n"
  info "$STR_CODEX_AUTH_CHECKING"
  local _login_status=""
  if _login_status="$(_codex_login_status)"; then
    ok "$STR_CODEX_LOGIN_ALREADY"
    info "  $_login_status"
    _auth_ready=true
  else
    warn "$STR_CODEX_AUTH_NOT_LOGGED_IN"
    if _prompt_codex_auth "$_rc_file" && _login_status="$(_codex_login_status)"; then
      _auth_ready=true
      info "  $_login_status"
    fi
  fi

  # Step 3: Install Codex Plugin
  if command -v claude &>/dev/null; then
    printf "\n"
    if _has_codex_plugin; then
      ok "${STR_CODEX_PLUGIN_ALREADY:-Codex plugin is already installed}"
      _plugin_ready=true
    else
      info "${STR_CODEX_PLUGIN_INSTALLING:-Installing Codex plugin...}"
      if _install_codex_plugin; then
        ok "${STR_CODEX_PLUGIN_INSTALLED:-Codex plugin installed}"
        _plugin_ready=true
      fi
    fi
  fi

  printf "\n"
  info "$STR_CODEX_RESTART_HINT"
  if [[ "$_auth_ready" == "true" ]] && [[ "$_plugin_ready" == "true" ]]; then
    ok "$STR_CODEX_SETUP_DONE"
    return 0
  else
    warn "$STR_CODEX_SETUP_INCOMPLETE"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# run_codex_setup - Entry point called from setup.sh
# 2-axis state machine: plugin × legacy MCP
# ---------------------------------------------------------------------------
run_codex_setup() {
  is_true "${ENABLE_CODEX_PLUGIN:-false}" || return 0

  # Detect state (2-axis: plugin × MCP)
  local _plugin_present=false _mcp_present=false
  _has_codex_plugin && _plugin_present=true
  _has_legacy_mcp && _mcp_present=true

  # State A: plugin installed, no MCP
  if [[ "$_plugin_present" == "true" ]] && [[ "$_mcp_present" == "false" ]]; then
    if _codex_fully_ready; then
      ok "${STR_CODEX_PLUGIN_ALREADY:-Codex plugin already configured}"
      return 0
    fi
    warn "${STR_CODEX_SETUP_INCOMPLETE:-Codex Plugin setup is not complete yet. Finish the remaining steps later}"
    if [[ "${WIZARD_NONINTERACTIVE:-false}" == "true" ]]; then
      _install_codex_cli || true
      if ! _codex_auth_ready; then
        info "${STR_CODEX_AUTH_NONINTERACTIVE_REQUIRED:-Codex CLI authentication still requires interactive setup.}"
      fi
      return 0
    fi
    _setup_codex_plugin || true
    return 0
  fi

  # State B: both present
  if [[ "$_plugin_present" == "true" ]] && [[ "$_mcp_present" == "true" ]]; then
    if _codex_fully_ready; then
      info "${STR_CODEX_MCP_DRIFT_CLEANUP:-Removing duplicate Codex MCP registration...}"
      if _remove_legacy_mcp; then
        ok "${STR_CODEX_MCP_DRIFT_DONE:-Codex MCP duplicate registration removed}"
      else
        warn "${STR_CODEX_MCP_DRIFT_KEEPING:-Keeping legacy Codex MCP because cleanup did not complete.}"
      fi
      return 0
    fi
    warn "${STR_CODEX_MCP_KEEP_UNTIL_READY:-Keeping legacy Codex MCP until Codex Plugin setup is fully ready.}"
    if [[ "${WIZARD_NONINTERACTIVE:-false}" == "true" ]]; then
      _install_codex_cli || true
      return 0
    fi
    if _setup_codex_plugin; then
      info "${STR_CODEX_MCP_DRIFT_CLEANUP:-Removing duplicate Codex MCP registration...}"
      if _remove_legacy_mcp; then
        ok "${STR_CODEX_MCP_DRIFT_DONE:-Codex MCP duplicate registration removed}"
      else
        warn "${STR_CODEX_MCP_DRIFT_KEEPING:-Keeping legacy Codex MCP because cleanup did not complete.}"
      fi
    fi
    return 0
  fi

  # State C: no plugin, MCP present → migration flow
  if [[ "$_plugin_present" == "false" ]] && [[ "$_mcp_present" == "true" ]]; then
    if [[ "${WIZARD_NONINTERACTIVE:-false}" == "true" ]]; then
      info "${STR_CODEX_MIGRATE_SKIP_NONINTERACTIVE:-Codex MCP migration requires interactive mode}"
      return 0
    fi

    printf "\n"
    info "${STR_CODEX_MIGRATE_PROMPT:-Codex MCP is registered. Migrate to Codex Plugin?}"
    printf "  1) %s\n" "${STR_CODEX_MIGRATE_YES:-Yes, migrate to plugin}"
    printf "  2) %s\n" "${STR_CODEX_MIGRATE_NO:-No, keep MCP}"
    local _migrate_choice=""
    read -r -p "${STR_CHOICE:-Choice}: " _migrate_choice
    case "$_migrate_choice" in
      1)
        # Remove MCP only after plugin + auth are both verified
        if _setup_codex_plugin; then
          if _remove_legacy_mcp; then
            ok "${STR_CODEX_MIGRATE_DONE:-Codex MCP → Plugin migration complete}"
          else
            warn "${STR_CODEX_MCP_DRIFT_KEEPING:-Keeping legacy Codex MCP because cleanup did not complete.}"
          fi
        else
          warn "${STR_CODEX_MIGRATE_KEEP_MCP:-Codex Plugin setup is incomplete. Keeping MCP.}"
        fi
        ;;
      *)
        info "${STR_CODEX_MIGRATE_DECLINED:-Keeping Codex MCP. Plugin not installed.}"
        ;;
    esac
    return 0
  fi

  # State D: neither present → fresh install
  if [[ "${WIZARD_NONINTERACTIVE:-false}" == "true" ]]; then
    local _fresh_ready=true
    if ! _install_codex_cli; then
      _fresh_ready=false
    fi
    if ! _install_codex_plugin; then
      _fresh_ready=false
    fi
    if [[ "$_fresh_ready" != "true" ]]; then
      warn "${STR_CODEX_SETUP_INCOMPLETE:-Codex Plugin setup is not complete yet. Finish the remaining steps later}"
    fi
    return 0
  fi

  printf "\n"
  info "${STR_CODEX_SETUP_CONFIRM:-Start Codex Plugin setup?}"
  printf "  1) %s\n" "${STR_CODEX_SETUP_CONFIRM_YES:-Yes}"
  printf "  2) %s\n" "${STR_CODEX_SETUP_CONFIRM_NO:-No, skip}"
  local _codex_confirm=""
  read -r -p "${STR_CHOICE:-Choice}: " _codex_confirm
  case "$_codex_confirm" in
    1) _setup_codex_plugin ;;
    *) info "${STR_CODEX_SETUP_SKIPPED:-Codex Plugin setup skipped}" ;;
  esac
}
