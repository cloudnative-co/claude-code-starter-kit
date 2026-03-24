#!/bin/bash
# lib/codex-setup.sh - Codex MCP setup (CLI install, auth, MCP registration)
# Requires: lib/colors.sh, lib/detect.sh, wizard/wizard.sh (is_true)
# Uses globals: ENABLE_CODEX_MCP, WIZARD_NONINTERACTIVE, _SETUP_TMP_FILES[],
#               STR_CODEX_*, STR_CHOICE
# Exports: run_codex_setup(), _setup_codex_mcp(), _install_codex_cli(),
#          _run_with_timeout(), _verify_openai_key(), _save_openai_key(),
#          _get_shell_rc_file()
# Dry-run: guarded externally (setup.sh logs EXTERNAL, does not call run_codex_setup)
set -euo pipefail

# ---------------------------------------------------------------------------
# Codex MCP helpers
# ---------------------------------------------------------------------------

# Portable timeout wrapper (macOS lacks `timeout` from coreutils)
_run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout &>/dev/null; then
    timeout "$secs" "$@"
  else
    # Background the command and kill if it exceeds the limit
    "$@" &
    local pid=$!
    ( sleep "$secs" && kill "$pid" 2>/dev/null ) &
    local watcher=$!
    # Capture exit code safely under set -e (bare wait would abort on non-zero)
    local rc=0
    wait "$pid" 2>/dev/null || rc=$?
    # Kill the watcher subshell and its sleep child to avoid orphan processes
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
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
  printf '\n# OpenAI API Key (added by claude-code-starter-kit)\nexport OPENAI_API_KEY="%s"\n' "$key" >> "$rc_file"
  export OPENAI_API_KEY="$key"
}

_get_shell_rc_file() {
  local _rc_file="$HOME/.bashrc"
  if is_msys; then
    # Git Bash sources .bash_profile, not .bashrc
    _rc_file="$HOME/.bash_profile"
  else
    local _login_shell
    _login_shell="$(basename "${SHELL:-bash}")"
    if [[ "$_login_shell" == "zsh" ]]; then
      _rc_file="$HOME/.zshrc"
    fi
  fi
  printf '%s\n' "$_rc_file"
}

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
  elif grep -q 'OPENAI_API_KEY' "$rc_file" 2>/dev/null; then
    _existing_key="$(grep 'OPENAI_API_KEY' "$rc_file" | sed 's/.*OPENAI_API_KEY=["]*//;s/["]*$//' | tail -1)"
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
  local _codex_installed=false

  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew &>/dev/null; then
    brew install codex 2>/dev/null && _codex_installed=true
  fi

  if [[ "$_codex_installed" != "true" ]] && command -v npm &>/dev/null; then
    local _npm_prefix
    _npm_prefix="$(npm config get prefix 2>/dev/null || echo '/usr/local')"
    if [[ -w "${_npm_prefix}/lib" ]]; then
      npm install -g @openai/codex 2>/dev/null && _codex_installed=true
    else
      sudo npm install -g @openai/codex 2>/dev/null && _codex_installed=true
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
# Codex MCP interactive setup
# ---------------------------------------------------------------------------
_setup_codex_mcp() {
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
    && command -v claude &>/dev/null \
    && claude mcp list -s user 2>/dev/null | grep -q "codex" 2>/dev/null; then
    ok "$STR_CODEX_CLI_ALREADY"
    ok "$STR_CODEX_LOGIN_ALREADY"
    ok "$STR_CODEX_MCP_ALREADY"
    return
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
  local _mcp_ready=false

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

  # Step 3: Register MCP server with Claude Code
  # Note: codex login handles authentication; no need to embed API key in MCP config
  if command -v claude &>/dev/null && command -v codex &>/dev/null; then
    printf "\n"
    local _mcp_list
    _mcp_list="$(claude mcp list -s user 2>/dev/null || true)"
    if echo "$_mcp_list" | grep -q "codex" 2>/dev/null; then
      ok "$STR_CODEX_MCP_ALREADY"
      _mcp_ready=true
    else
      info "$STR_CODEX_MCP_REGISTERING"
      if claude mcp add -s user codex -- codex mcp-server 2>/dev/null; then
        ok "$STR_CODEX_MCP_REGISTERED"
        _mcp_ready=true
      else
        warn "$STR_CODEX_MCP_REG_FAILED"
        info "  claude mcp add -s user codex -- codex mcp-server"
      fi
    fi
  fi

  printf "\n"
  info "$STR_CODEX_RESTART_HINT"
  if [[ "$_auth_ready" == "true" ]] && [[ "$_mcp_ready" == "true" ]]; then
    ok "$STR_CODEX_SETUP_DONE"
  else
    warn "$STR_CODEX_SETUP_INCOMPLETE"
  fi
}

# ---------------------------------------------------------------------------
# run_codex_setup - Entry point called from setup.sh
# ---------------------------------------------------------------------------
run_codex_setup() {
  is_true "${ENABLE_CODEX_MCP:-false}" || return 0

  # Skip if already fully configured (codex CLI + login + MCP registered)
  local _codex_already_done=false
  if command -v codex &>/dev/null \
    && _codex_login_status >/dev/null 2>&1 \
    && command -v claude &>/dev/null \
    && claude mcp list -s user 2>/dev/null | grep -q "codex" 2>/dev/null; then
    _codex_already_done=true
  fi

  if [[ "$_codex_already_done" == "true" ]]; then
    ok "${STR_CODEX_MCP_ALREADY:-Codex MCP already configured}"
  elif [[ "${WIZARD_NONINTERACTIVE:-false}" == "true" ]]; then
    info "${STR_CODEX_SETUP_SKIPPED:-Codex MCP setup skipped (non-interactive)}"
  else
    printf "\n"
    info "${STR_CODEX_SETUP_CONFIRM:-Start Codex MCP setup?}"
    printf "  1) %s\n" "${STR_CODEX_SETUP_CONFIRM_YES:-Yes}"
    printf "  2) %s\n" "${STR_CODEX_SETUP_CONFIRM_NO:-No, skip}"
    local _codex_confirm=""
    read -r -p "${STR_CHOICE:-Choice}: " _codex_confirm
    case "$_codex_confirm" in
      1) _setup_codex_mcp ;;
      *) info "${STR_CODEX_SETUP_SKIPPED:-Codex MCP setup skipped}" ;;
    esac
  fi
}
