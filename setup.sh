#!/bin/bash
# setup.sh - Main deployment script for Claude Code Starter Kit
set -euo pipefail

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------
_script_dir() {
  local src
  src="${BASH_SOURCE[0]}"
  while [[ -h "$src" ]]; do
    src="$(readlink "$src")"
  done
  cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}

PROJECT_DIR="$(_script_dir)"
CLAUDE_DIR="$HOME/.claude"

# ---------------------------------------------------------------------------
# Source wizard first, parse CLI args
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. "$PROJECT_DIR/wizard/wizard.sh"

parse_cli_args "$@"

# ---------------------------------------------------------------------------
# Source libraries
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/colors.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/detect.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/prerequisites.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/template.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/json-builder.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/ghostty.sh"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
detect_os
check_prerequisites

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------
run_wizard

case "${WIZARD_RESULT:-cancel}" in
  save)
    save_config "${WIZARD_CONFIG_FILE:-$HOME/.claude-starter-kit.conf}"
    ok "Saved configuration to ${WIZARD_CONFIG_FILE:-$HOME/.claude-starter-kit.conf}"
    exit 0
    ;;
  cancel|"")
    info "Setup canceled."
    exit 0
    ;;
  deploy)
    ;;
  *)
    warn "Unknown wizard result: ${WIZARD_RESULT}. Aborting."
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
is_true() {
  local v
  v="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

language_name() {
  case "${LANGUAGE:-en}" in
    ja) printf "日本語" ;;
    *)  printf "English" ;;
  esac
}

editor_command() {
  case "${1:-none}" in
    vscode) printf "code --diff" ;;
    cursor) printf "cursor --diff" ;;
    zed)    printf "zed" ;;
    neovim) printf "nvim -d" ;;
    *)      printf "" ;;
  esac
}

backup_existing() {
  if [[ -e "$CLAUDE_DIR" ]]; then
    local ts backup
    ts="$(date +%Y%m%d%H%M%S)"
    backup="$HOME/.claude.backup.${ts}"
    cp -a "$CLAUDE_DIR" "$backup"
    ok "Backed up existing ~/.claude to $backup"
  fi
}

ensure_dirs() {
  mkdir -p "$CLAUDE_DIR"/{agents,rules,commands,skills,memory,hooks}
}

copy_if_enabled() {
  local flag="$1"
  local src="$2"
  local dest="$3"

  if is_true "$flag"; then
    cp -a "$src"/. "$dest"/
    ok "Installed $(basename "$dest")"
  else
    info "Skipped $(basename "$dest")"
  fi
}

# ---------------------------------------------------------------------------
# Build CLAUDE.md
# ---------------------------------------------------------------------------
build_claude_md() {
  local lang="${LANGUAGE:-en}"
  local base="$PROJECT_DIR/i18n/${lang}/CLAUDE.md.base"
  local out="$CLAUDE_DIR/CLAUDE.md"

  cp -a "$base" "$out"

  if is_true "$ENABLE_CODEX_MCP"; then
    local partial="$PROJECT_DIR/features/codex-mcp/CLAUDE.md.partial.${lang}"
    inject_feature "$out" "codex-mcp" "$partial"
  fi

  remove_unresolved "$out"
  ok "Built CLAUDE.md"
}

# ---------------------------------------------------------------------------
# Build settings.json
# ---------------------------------------------------------------------------
build_settings() {
  local base="$PROJECT_DIR/config/settings-base.json"
  local permissions="$PROJECT_DIR/config/permissions.json"
  local out="$CLAUDE_DIR/settings.json"

  local hook_fragments=()
  local tmp_files=()

  if is_true "$ENABLE_TMUX_HOOKS"; then
    hook_fragments+=("$PROJECT_DIR/features/tmux-hooks/hooks.json")
  fi
  if is_true "$ENABLE_DOC_BLOCKER"; then
    hook_fragments+=("$PROJECT_DIR/features/doc-blocker/hooks.json")
  fi
  if is_true "$ENABLE_PRETTIER_HOOKS"; then
    hook_fragments+=("$PROJECT_DIR/features/prettier-hooks/hooks.json")
  fi
  if is_true "$ENABLE_CONSOLE_LOG_GUARD"; then
    hook_fragments+=("$PROJECT_DIR/features/console-log-guard/hooks.json")
  fi
  if is_true "$ENABLE_MEMORY_PERSISTENCE"; then
    hook_fragments+=("$PROJECT_DIR/features/memory-persistence/hooks.json")
  fi
  if is_true "$ENABLE_STRATEGIC_COMPACT"; then
    hook_fragments+=("$PROJECT_DIR/features/strategic-compact/hooks.json")
  fi
  if is_true "$ENABLE_PR_CREATION_LOG"; then
    hook_fragments+=("$PROJECT_DIR/features/pr-creation-log/hooks.json")
  fi

  # Git push review: needs editor command substitution
  if is_true "$ENABLE_GIT_PUSH_REVIEW"; then
    if [[ "${EDITOR_CHOICE:-none}" == "none" ]]; then
      warn "Git push review hook skipped (no editor selected)"
    else
      local editor_cmd src tmp
      editor_cmd="$(editor_command "$EDITOR_CHOICE")"
      src="$PROJECT_DIR/features/git-push-review/hooks.json"
      tmp="$(mktemp)"
      if grep -q "__EDITOR_CMD__" "$src" 2>/dev/null; then
        sed "s|__EDITOR_CMD__|$editor_cmd|g" "$src" > "$tmp"
      else
        cp -a "$src" "$tmp"
      fi
      hook_fragments+=("$tmp")
      tmp_files+=("$tmp")
    fi
  fi

  build_settings_json "$base" "$permissions" "$out" ${hook_fragments[@]+"${hook_fragments[@]}"}

  # Set language name in settings
  local lang_name
  lang_name="$(language_name)"
  local tmp_lang
  tmp_lang="$(mktemp)"
  jq --arg lang "$lang_name" '.language = $lang' "$out" > "$tmp_lang"
  mv "$tmp_lang" "$out"

  replace_home_path "$out"

  # Clean up temp files
  if [[ ${#tmp_files[@]} -gt 0 ]]; then
    rm -f "${tmp_files[@]}"
  fi
}

# ---------------------------------------------------------------------------
# Deploy hook scripts
# ---------------------------------------------------------------------------
deploy_hook_scripts() {
  if is_true "$ENABLE_MEMORY_PERSISTENCE"; then
    local dest="$CLAUDE_DIR/hooks/memory-persistence"
    mkdir -p "$dest"
    cp -a "$PROJECT_DIR/features/memory-persistence/scripts"/. "$dest"/
    chmod +x "$dest"/*.sh
    ok "Installed memory-persistence hooks"
  fi

  if is_true "$ENABLE_STRATEGIC_COMPACT"; then
    local dest="$CLAUDE_DIR/hooks/strategic-compact"
    mkdir -p "$dest"
    cp -a "$PROJECT_DIR/features/strategic-compact/scripts"/. "$dest"/
    chmod +x "$dest"/*.sh
    ok "Installed strategic-compact hooks"
  fi
}

# ---------------------------------------------------------------------------
# Manifest: track all deployed files for clean uninstall
# ---------------------------------------------------------------------------
write_manifest() {
  local manifest="$CLAUDE_DIR/.starter-kit-manifest.json"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # Only track files in starter-kit-managed directories (not plugins, sessions, etc.)
  local files_json
  files_json="$({
    find "$CLAUDE_DIR/agents" "$CLAUDE_DIR/rules" "$CLAUDE_DIR/commands" \
         "$CLAUDE_DIR/skills" "$CLAUDE_DIR/memory" "$CLAUDE_DIR/hooks" \
         -type f 2>/dev/null || true
    [[ -f "$CLAUDE_DIR/CLAUDE.md" ]] && echo "$CLAUDE_DIR/CLAUDE.md"
    [[ -f "$CLAUDE_DIR/settings.json" ]] && echo "$CLAUDE_DIR/settings.json"
  } | sort -u | jq -R -s 'split("\n")[:-1]')"

  jq -n \
    --arg ts "$ts" \
    --arg profile "${PROFILE:-}" \
    --arg language "${LANGUAGE:-}" \
    --arg editor "${EDITOR_CHOICE:-}" \
    --arg plugins "${SELECTED_PLUGINS:-}" \
    --argjson files "$files_json" \
    '{
      timestamp: $ts,
      profile: $profile,
      language: $language,
      editor: $editor,
      plugins: $plugins,
      files: $files
    }' > "$manifest"
}

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
section "Deploying Claude Code Starter Kit"

backup_existing
ensure_dirs

copy_if_enabled "$INSTALL_AGENTS"  "$PROJECT_DIR/agents"   "$CLAUDE_DIR/agents"
copy_if_enabled "$INSTALL_RULES"   "$PROJECT_DIR/rules"    "$CLAUDE_DIR/rules"
copy_if_enabled "$INSTALL_COMMANDS" "$PROJECT_DIR/commands" "$CLAUDE_DIR/commands"
copy_if_enabled "$INSTALL_SKILLS"  "$PROJECT_DIR/skills"   "$CLAUDE_DIR/skills"
copy_if_enabled "$INSTALL_MEMORY"  "$PROJECT_DIR/memory"   "$CLAUDE_DIR/memory"

build_claude_md
build_settings
deploy_hook_scripts

# ---------------------------------------------------------------------------
# Ghostty terminal setup (macOS only)
# ---------------------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  ENABLE_GHOSTTY_SETUP="false"
fi

if is_true "${ENABLE_GHOSTTY_SETUP:-false}"; then
  section "Setting up Ghostty terminal"
  setup_ghostty "$PROJECT_DIR/features/ghostty/config.template"
fi

write_manifest

# Save config for re-runs
save_config "${WIZARD_CONFIG_FILE:-$HOME/.claude-starter-kit.conf}"

section "Setup Complete"
ok "Deployed to $CLAUDE_DIR"

# ---------------------------------------------------------------------------
# Helper: Ensure ~/.local/bin is in shell RC file for PATH persistence
# ---------------------------------------------------------------------------
_ensure_local_bin_in_path() {
  local local_bin="$HOME/.local/bin"
  local rc_file=""

  # Determine the correct shell RC file
  if is_msys; then
    # Git Bash sources .bash_profile, not .bashrc
    rc_file="$HOME/.bash_profile"
  else
    case "${SHELL:-/bin/bash}" in
      */zsh)  rc_file="$HOME/.zshrc" ;;
      */bash) rc_file="$HOME/.bashrc" ;;
      *)      rc_file="$HOME/.profile" ;;
    esac
  fi

  # Create RC file if it doesn't exist
  [[ -f "$rc_file" ]] || touch "$rc_file"

  # Add PATH entry if not already present
  if ! grep -q "$local_bin" "$rc_file" 2>/dev/null; then
    printf '\n# Claude Code CLI\nexport PATH="%s:$PATH"\n' "$local_bin" >> "$rc_file"
  fi
}

# ---------------------------------------------------------------------------
# Install Claude Code CLI if not present
# ---------------------------------------------------------------------------
if ! command -v claude &>/dev/null; then
  printf "\n"
  warn "$STR_CLI_NOT_FOUND"
  info "$STR_CLI_INSTALL_NOW"
  printf "  1) %s\n" "$STR_CLI_INSTALL_YES"
  printf "  2) %s\n" "$STR_CLI_INSTALL_NO"
  install_choice=""
  read -r -p "${STR_CHOICE}: " install_choice
  case "$install_choice" in
    1)
      info "$STR_CLI_INSTALLING"
      if is_msys; then
        # Native Windows: use PowerShell installer
        if powershell.exe -NoProfile -Command "irm https://claude.ai/install.ps1 | iex"; then
          # Probe common install locations (PowerShell installer, npm, etc.)
          for _win_dir in \
            "$(cygpath -u "${LOCALAPPDATA:-}/Programs/claude" 2>/dev/null)" \
            "$(cygpath -u "${APPDATA:-}/npm" 2>/dev/null)" \
            "$HOME/.local/bin"; do
            [[ -n "$_win_dir" ]] && export PATH="$_win_dir:$PATH"
          done
          _ensure_local_bin_in_path
          if command -v claude &>/dev/null; then
            ok "$STR_CLI_INSTALLED"
          else
            warn "$STR_CLI_PATH_WARN"
          fi
        else
          warn "$STR_CLI_INSTALL_FAILED"
          info "  powershell -c 'irm https://claude.ai/install.ps1 | iex'"
        fi
      else
        # Unix (macOS/Linux/WSL): use bash installer
        if curl -fsSL https://claude.ai/install.sh | bash; then
          export PATH="$HOME/.local/bin:$PATH"
          # Ensure ~/.local/bin is in shell RC for next login
          _ensure_local_bin_in_path
          if command -v claude &>/dev/null; then
            ok "$STR_CLI_INSTALLED"
          else
            warn "$STR_CLI_PATH_WARN"
          fi
        else
          warn "$STR_CLI_INSTALL_FAILED"
          info "  curl -fsSL https://claude.ai/install.sh | bash"
        fi
      fi
      ;;
    *)
      info "$STR_CLI_INSTALL_LATER"
      if is_msys; then
        printf "  powershell -c 'irm https://claude.ai/install.ps1 | iex'\n"
      else
        printf "  curl -fsSL https://claude.ai/install.sh | bash\n"
      fi
      ;;
  esac
else
  ok "$STR_CLI_ALREADY"
fi

# ---------------------------------------------------------------------------
# Install plugins
# ---------------------------------------------------------------------------
if [[ -n "${SELECTED_PLUGINS:-}" ]]; then
  printf "\n"
  IFS=',' read -r -a _plugins <<< "$SELECTED_PLUGINS"
  if command -v claude &>/dev/null; then
    # Get list of already installed plugins
    _installed_plugins="$(claude plugin list 2>/dev/null || true)"

    # Check if any plugins need installing
    _need_install=false
    for p in "${_plugins[@]}"; do
      if [[ -n "$p" ]] && ! echo "$_installed_plugins" | grep -q "$p" 2>/dev/null; then
        _need_install=true
        break
      fi
    done

    if [[ "$_need_install" == "true" ]]; then
      # Ensure the official marketplace is registered
      claude plugin marketplace add anthropics/claude-plugins-official 2>/dev/null || true
      info "$STR_DEPLOY_PLUGINS_INSTALLING"
    fi

    for p in "${_plugins[@]}"; do
      if [[ -n "$p" ]]; then
        if echo "$_installed_plugins" | grep -q "$p" 2>/dev/null; then
          ok "$STR_DEPLOY_PLUGINS_ALREADY $p"
        elif claude plugin install "$p" --scope user; then
          ok "$STR_DEPLOY_PLUGINS_INSTALLED $p"
        else
          warn "$STR_DEPLOY_PLUGINS_FAILED $p"
        fi
      fi
    done
  else
    warn "$STR_DEPLOY_PLUGINS_SKIP"
    info "$STR_DEPLOY_PLUGINS_HINT"
    for p in "${_plugins[@]}"; do
      [[ -n "$p" ]] && printf "  /install %s\n" "$p"
    done
  fi
fi

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
    wait "$pid" 2>/dev/null
    local rc=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null 2>&1 || true
    return "$rc"
  fi
}

_verify_openai_key() {
  local key="$1"
  local http_code
  http_code="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $key" \
    https://api.openai.com/v1/models 2>/dev/null || echo "000")"
  [[ "$http_code" == "200" ]]
}

_save_openai_key() {
  local key="$1"
  local rc_file="$2"
  if grep -q 'OPENAI_API_KEY' "$rc_file" 2>/dev/null; then
    local tmp_rc
    tmp_rc="$(mktemp)"
    sed "s|^export OPENAI_API_KEY=.*|export OPENAI_API_KEY=\"$key\"|" "$rc_file" > "$tmp_rc"
    mv "$tmp_rc" "$rc_file"
  else
    printf '\n# OpenAI API Key (added by claude-code-starter-kit)\nexport OPENAI_API_KEY="%s"\n' "$key" >> "$rc_file"
  fi
  export OPENAI_API_KEY="$key"
}

# Test Codex MCP connectivity by verifying the API key works with
# the OpenAI Responses API endpoint (which Codex actually uses).
_test_codex_mcp() {
  local _key="${OPENAI_API_KEY:-}"
  if [[ -z "$_key" ]]; then
    return 1
  fi
  # Test /v1/models (basic auth) and /v1/responses (Codex endpoint)
  local _models_code _responses_code
  _models_code="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $_key" \
    https://api.openai.com/v1/models 2>/dev/null || echo "000")"
  _responses_code="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer $_key" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o-mini","input":"test"}' \
    https://api.openai.com/v1/responses 2>/dev/null || echo "000")"
  # 200=success, 400=bad request (but auth works), 401/403=auth failure
  if [[ "$_models_code" == "200" ]] && [[ "$_responses_code" != "401" ]] && [[ "$_responses_code" != "403" ]]; then
    return 0
  fi
  return 1
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
    && [[ -n "${OPENAI_API_KEY:-}" ]] \
    && command -v claude &>/dev/null \
    && claude mcp list -s user 2>/dev/null | grep -q "codex" 2>/dev/null; then
    ok "$STR_CODEX_CLI_ALREADY"
    ok "$STR_CODEX_MCP_ALREADY"
    return
  fi

  warn "$STR_CODEX_SETUP_NOTE"
  printf "\n"

  # Step 1: Install Codex CLI
  if command -v codex &>/dev/null; then
    ok "$STR_CODEX_CLI_ALREADY"
  else
    info "$STR_CODEX_CLI_INSTALLING"
    local _codex_installed=false
    if command -v npm &>/dev/null; then
      local _npm_prefix
      _npm_prefix="$(npm config get prefix 2>/dev/null || echo '/usr/local')"
      if [[ -w "${_npm_prefix}/lib" ]]; then
        npm install -g @openai/codex 2>/dev/null && _codex_installed=true
      else
        sudo npm install -g @openai/codex 2>/dev/null && _codex_installed=true
      fi
    fi
    # After npm install, re-probe PATH on MSYS (npm global bin may not be in PATH)
    if [[ "$_codex_installed" == "true" ]] && ! command -v codex &>/dev/null && is_msys; then
      for _npm_dir in \
        "$(cygpath -u "${APPDATA:-}/npm" 2>/dev/null)" \
        "$(npm config get prefix 2>/dev/null)/bin"; do
        [[ -n "$_npm_dir" ]] && [[ -d "$_npm_dir" ]] && export PATH="$_npm_dir:$PATH"
      done
    fi
    if [[ "$_codex_installed" == "true" ]] && command -v codex &>/dev/null; then
      ok "$STR_CODEX_CLI_INSTALLED"
    else
      warn "$STR_CODEX_CLI_FAILED"
      info "  npm install -g @openai/codex"
    fi
  fi

  # Step 2: OpenAI API key (setup + verification)
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

  local _existing_key=""
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    _existing_key="$OPENAI_API_KEY"
  elif grep -q 'OPENAI_API_KEY' "$_rc_file" 2>/dev/null; then
    _existing_key="$(grep 'OPENAI_API_KEY' "$_rc_file" | sed 's/.*OPENAI_API_KEY=["]*//;s/["]*$//' | tail -1)"
    # Load into current session
    export OPENAI_API_KEY="$_existing_key"
  fi

  local _key_ok=false
  if [[ -n "$_existing_key" ]]; then
    printf "\n"
    ok "$STR_CODEX_API_KEY_ALREADY"
    info "$STR_CODEX_API_KEY_VERIFYING"
    if _verify_openai_key "$_existing_key"; then
      ok "$STR_CODEX_API_KEY_VALID"
      _key_ok=true
    else
      warn "$STR_CODEX_API_KEY_INVALID"
      if _prompt_openai_key "$_rc_file"; then
        _key_ok=true
      fi
    fi
  else
    printf "\n"
    if _prompt_openai_key "$_rc_file"; then
      _key_ok=true
    fi
  fi

  # Step 3: Log in to Codex CLI with the API key
  if command -v codex &>/dev/null && [[ -n "${OPENAI_API_KEY:-}" ]]; then
    printf "\n"
    # Check if already logged in
    if _run_with_timeout 15 codex login status &>/dev/null 2>&1; then
      ok "$STR_CODEX_LOGIN_ALREADY"
    else
      info "$STR_CODEX_LOGIN_RUNNING"
      if printf '%s' "$OPENAI_API_KEY" | _run_with_timeout 30 codex login --with-api-key &>/dev/null; then
        ok "$STR_CODEX_LOGIN_DONE"
      else
        warn "$STR_CODEX_LOGIN_FAILED"
        info "  printenv OPENAI_API_KEY | codex login --with-api-key"
      fi
    fi
  fi

  # Step 4: Register MCP server with Claude Code
  # Note: codex login handles authentication; no need to embed API key in MCP config
  if command -v claude &>/dev/null && command -v codex &>/dev/null; then
    printf "\n"
    local _mcp_list
    _mcp_list="$(claude mcp list -s user 2>/dev/null || true)"
    if echo "$_mcp_list" | grep -q "codex" 2>/dev/null; then
      ok "$STR_CODEX_MCP_ALREADY"
    else
      info "$STR_CODEX_MCP_REGISTERING"
      if claude mcp add -s user codex -- codex mcp-server 2>/dev/null; then
        ok "$STR_CODEX_MCP_REGISTERED"
      else
        warn "$STR_CODEX_MCP_REG_FAILED"
        info "  claude mcp add -s user codex -- codex mcp-server"
      fi
    fi
  fi

  # Step 5: End-to-end smoke test (retry loop)
  if command -v codex &>/dev/null; then
    while true; do
      printf "\n"
      info "$STR_CODEX_E2E_TESTING"
      if _test_codex_mcp; then
        ok "$STR_CODEX_E2E_SUCCESS"
        break
      else
        warn "$STR_CODEX_E2E_FAILED"
        printf "\n"
        printf "  1) %s\n" "$STR_CODEX_E2E_RETRY"
        printf "  2) %s\n" "$STR_CODEX_E2E_SKIP"
        local _e2e_choice=""
        read -r -p "${STR_CHOICE}: " _e2e_choice
        case "$_e2e_choice" in
          1)
            printf "\n"
            info "$STR_CODEX_API_KEY_HINT"
            local _retry_key=""
            read -rs -p "  API Key: " _retry_key
            printf "\n"
            if [[ -n "$_retry_key" ]]; then
              info "$STR_CODEX_API_KEY_VERIFYING"
              if _verify_openai_key "$_retry_key"; then
                ok "$STR_CODEX_API_KEY_VALID"
                _save_openai_key "$_retry_key" "$_rc_file"
                ok "$STR_CODEX_API_KEY_SAVED ($_rc_file)"
                # Re-login with updated key
                if command -v codex &>/dev/null; then
                  printf '%s' "$_retry_key" | codex login --with-api-key &>/dev/null || true
                fi
              else
                warn "$STR_CODEX_API_KEY_INVALID"
              fi
            fi
            # Loop continues to re-test
            ;;
          *)
            warn "$STR_CODEX_E2E_SKIP_HINT"
            info "  1. export OPENAI_API_KEY=\"your-api-key-here\""
            info "  2. printenv OPENAI_API_KEY | codex login --with-api-key"
            info "  3. claude mcp add -s user codex -- codex mcp-server"
            break
            ;;
        esac
      fi
    done
  fi

  printf "\n"
  ok "$STR_CODEX_SETUP_DONE"
}

if is_true "${ENABLE_CODEX_MCP:-false}"; then
  # Confirm before starting Codex MCP setup (in case saved config had it enabled)
  printf "\n"
  info "${STR_CODEX_SETUP_CONFIRM:-Start Codex MCP setup?}"
  printf "  1) %s\n" "${STR_CODEX_SETUP_CONFIRM_YES:-Yes}"
  printf "  2) %s\n" "${STR_CODEX_SETUP_CONFIRM_NO:-No, skip}"
  _codex_confirm=""
  read -r -p "${STR_CHOICE:-Choice}: " _codex_confirm
  case "$_codex_confirm" in
    1) _setup_codex_mcp ;;
    *) info "${STR_CODEX_SETUP_SKIPPED:-Codex MCP setup skipped}" ;;
  esac
fi

# ---------------------------------------------------------------------------
# Final message
# ---------------------------------------------------------------------------
printf "\n"
# Ghostty incomplete message is only relevant on macOS
if [[ -n "${GHOSTTY_INCOMPLETE:-}" ]] && [[ "$(uname -s)" == "Darwin" ]]; then
  section "$STR_FINAL_INCOMPLETE_TITLE"
  warn "$STR_FINAL_INCOMPLETE_GHOSTTY"
  for _item in $GHOSTTY_INCOMPLETE; do
    warn "  - $_item"
  done
  printf "\n"
  info "$STR_FINAL_INCOMPLETE_HINT"
  info "  $STR_FINAL_INCOMPLETE_BREW"
  info "    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  info ""
  info "  $STR_FINAL_INCOMPLETE_RERUN"
  info "    ~/.claude-starter-kit/setup.sh"
  printf "\n"
  info "$STR_FINAL_NEXT"
  info "  $STR_FINAL_STEP1"
  info "  $STR_FINAL_STEP2"
  info "  $STR_FINAL_STEP3"
else
  section "$STR_FINAL_TITLE"
  _ghostty_found=false
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if [[ -d "/Applications/Ghostty.app" ]] || command -v ghostty &>/dev/null; then
      _ghostty_found=true
    fi
  fi
  # Detect platform for final message (inline — don't rely on is_wsl/is_msys)
  _uname_final="$(uname -s)"
  _is_wsl_final=false
  if [[ -f /proc/version ]] && grep -qi "microsoft" /proc/version 2>/dev/null; then
    _is_wsl_final=true
  elif [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ -n "${WSLENV:-}" ]]; then
    _is_wsl_final=true
  fi
  _is_msys_final=false
  case "$_uname_final" in
    MSYS_NT*|MINGW*_NT*|CLANG*_NT*|UCRT*_NT*) _is_msys_final=true ;;
  esac

  if [[ "$_ghostty_found" == "true" ]]; then
    # Ghostty is installed - guide user to launch it
    info "$STR_FINAL_GHOSTTY_NEXT"
    info "  $STR_FINAL_GHOSTTY_STEP1"
    info "  $STR_FINAL_GHOSTTY_STEP2"
    info "  $STR_FINAL_GHOSTTY_STEP3"
    printf "\n"
    ok "$STR_FINAL_GHOSTTY_FONT"
  elif [[ "$_is_wsl_final" == "true" ]]; then
    info "$STR_FINAL_WSL_NEXT"
    info "  $STR_FINAL_WSL_STEP1"
    info "  $STR_FINAL_WSL_STEP2"
    info "  $STR_FINAL_WSL_STEP3"
  elif [[ "$_is_msys_final" == "true" ]]; then
    info "$STR_FINAL_MSYS_NEXT"
    info "  $STR_FINAL_MSYS_STEP1"
    info "  ${STR_FINAL_MSYS_STEP1_HINT:-}"
    info "  $STR_FINAL_MSYS_STEP2"
    info "  $STR_FINAL_MSYS_STEP3"
  else
    info "$STR_FINAL_NEXT"
    info "  $STR_FINAL_STEP1"
    info "  $STR_FINAL_STEP2"
    info "  $STR_FINAL_STEP3"
  fi
  printf "\n"
  warn "${STR_FINAL_RESTART_WARN:-Important: Restart your terminal for settings to take effect.}"
  info "${STR_FINAL_RESTART_HINT:-Close this terminal and open a new one before running claude.}"
  printf "\n"
  ok "$STR_FINAL_ENJOY"
fi
printf "\n"
