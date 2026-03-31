#!/bin/bash
# setup.sh - Main deployment script for Claude Code Starter Kit
set -euo pipefail

# ---------------------------------------------------------------------------
# Preserve original CLI arguments and script path for Bash 4+ re-exec
# ---------------------------------------------------------------------------
_SETUP_ORIG_ARGS=("$@")
_SETUP_SCRIPT_PATH="${BASH_SOURCE[0]}"

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

# Restrict permissions on temporary files (may contain sensitive data like API keys)
umask 077

# Track temp files for cleanup on exit/interrupt
_SETUP_TMP_FILES=()
_cleanup_tmp() {
  local _item
  for _item in "${_SETUP_TMP_FILES[@]+"${_SETUP_TMP_FILES[@]}"}"; do
    if [[ -d "$_item" ]]; then
      rm -rf "$_item" 2>/dev/null || true
    else
      rm -f "$_item" 2>/dev/null || true
    fi
  done
}
trap _cleanup_tmp EXIT INT TERM

# ═══════════════════════════════════════════════════════════════════════════
# Stage 1: Bash 3.2-compatible bootstrap (wizard, detect, prerequisites)
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
# Source wizard first, parse CLI args
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. "$PROJECT_DIR/wizard/wizard.sh"

parse_cli_args "$@"

# ---------------------------------------------------------------------------
# Stage 1 libraries (must work on Bash 3.2)
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/colors.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/detect.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/prerequisites.sh"

# ---------------------------------------------------------------------------
# Prerequisites + Bash 4+ check
# ---------------------------------------------------------------------------
detect_os
check_prerequisites

# Check for Bash 4+ and re-exec if needed
check_bash4 || {
  error "Bash 4+ is required. Please install it and try again."
  if [[ "$(uname -s)" == "Darwin" ]]; then
    info "  brew install bash"
  else
    info "  sudo apt-get install bash  (or equivalent)"
  fi
  exit 1
}

# ═══════════════════════════════════════════════════════════════════════════
# Stage 2: Bash 4+ required from this point (template, json, merge, etc.)
# ═══════════════════════════════════════════════════════════════════════════

# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/features.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/template.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/json-builder.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/snapshot.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/merge.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/update.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/dryrun.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/deploy.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/ghostty.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/fonts.sh"

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

ensure_dirs() {
  mkdir -p "$CLAUDE_DIR"/{agents,rules,commands,skills,memory,hooks}
}

# ---------------------------------------------------------------------------
# Deploy hook scripts
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# deploy_hook_scripts - Registry-based hook script deployment
#
# Usage: deploy_hook_scripts [mode]
#   mode=simple (default): overwrite all scripts unconditionally
#   mode=merge-aware: check for existing hooks, offer O/N/S prompt (fresh install with existing)
#
# Uses _FEATURE_ORDER + _FEATURE_HAS_SCRIPTS from lib/features.sh.
# ---------------------------------------------------------------------------
deploy_hook_scripts() {
  local mode="${1:-simple}"
  local name flag
  for name in "${_FEATURE_ORDER[@]}"; do
    [[ "${_FEATURE_HAS_SCRIPTS[$name]+set}" ]] || continue

    flag="${_FEATURE_FLAGS[$name]}"
    is_true "${!flag:-false}" || continue

    local src="$PROJECT_DIR/features/$name/scripts"
    [[ -d "$src" ]] || continue

    local dest="$CLAUDE_DIR/hooks/$name"
    mkdir -p "$dest"

    if [[ "$mode" == "simple" ]]; then
      cp -a "$src"/. "$dest"/
      _make_hooks_executable "$dest"
      ok "Installed $name hooks"
    else
      # merge-aware: check for existing files
      if [[ -z "$(ls -A "$dest" 2>/dev/null)" ]]; then
        cp -a "$src"/. "$dest"/
        _make_hooks_executable "$dest"
        ok "Installed $name hooks"
      else
        local action="new"
        if [[ "${_MERGE_INTERACTIVE:-true}" == "true" ]]; then
          warn "$STR_FRESH_DIR_EXISTS hooks/$name/"
          printf "  %s " "$STR_FRESH_DIR_PROMPT" >&2
          local reply=""
          if read -r reply < /dev/tty 2>/dev/null; then true; else reply="n"; fi
          case "$reply" in
            [Oo]*) action="overwrite" ;;
            [Ss]*) action="skip" ;;
            *)     action="new" ;;
          esac
        fi
        case "$action" in
          overwrite)
            cp -a "$src"/. "$dest"/
            _make_hooks_executable "$dest"
            ok "Installed $name hooks (overwrite)"
            ;;
          skip)
            _FRESH_SKIPPED_FILES+=("$dest")
            ok "$name hooks: ${STR_FRESH_SKIPPED:-skipped}"
            ;;
          new)
            cp -an "$src"/. "$dest"/
            _make_hooks_executable "$dest"
            ok "$name hooks: ${STR_FRESH_NEW_ONLY:-new files only}"
            ;;
        esac
      fi
    fi
  done
}

# Make all script files in a directory executable
_make_hooks_executable() {
  local dir="$1"
  chmod +x "$dir"/*.sh 2>/dev/null || true
  chmod +x "$dir"/*.py 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Dry-run: redirect CLAUDE_DIR to simulation directory
# ---------------------------------------------------------------------------
_ORIG_CLAUDE_DIR=""
if [[ "${DRY_RUN:-false}" == "true" ]]; then
  _ORIG_CLAUDE_DIR="$CLAUDE_DIR"
  _dryrun_init "$CLAUDE_DIR"
  CLAUDE_DIR="$_DRYRUN_DIR"
  _MERGE_INTERACTIVE="false"  # dry-run is always non-interactive
  _QUIET_OUTPUT="true"        # suppress progress messages, show only summary
fi

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
  if _has_user_customizations "$CLAUDE_DIR"; then
    _offer_dryrun_preview "$STR_DRYRUN_OFFER_EXISTING"
  fi
  backup_existing
  if ! _snapshot_exists "$CLAUDE_DIR"; then
    bootstrap_snapshot_from_current
  fi
  # Update mode: run update with merge logic
  run_update "$PROJECT_DIR" "$CLAUDE_DIR"
else
  # Fresh install / full re-setup
  section "Deploying Claude Code Starter Kit"
  warn_existing_claude_reconfigure

  backup_existing
  ensure_dirs

  if [[ -f "$CLAUDE_DIR/settings.json" ]] && [[ ! -f "$CLAUDE_DIR/.starter-kit-manifest.json" ]]; then
    # Existing Claude Code user without starter-kit: merge-aware deploy
    _offer_dryrun_preview "$STR_DRYRUN_OFFER_EXISTING"
    _deploy_fresh_with_existing
  else
    # Clean slate: original behavior
    copy_if_enabled "$INSTALL_AGENTS"  "$PROJECT_DIR/agents"   "$CLAUDE_DIR/agents"
    copy_if_enabled "$INSTALL_RULES"   "$PROJECT_DIR/rules"    "$CLAUDE_DIR/rules"
    copy_if_enabled "$INSTALL_COMMANDS" "$PROJECT_DIR/commands" "$CLAUDE_DIR/commands"
    copy_if_enabled "$INSTALL_SKILLS"  "$PROJECT_DIR/skills"   "$CLAUDE_DIR/skills"
    copy_if_enabled "$INSTALL_MEMORY"  "$PROJECT_DIR/memory"   "$CLAUDE_DIR/memory"

    build_claude_md

    build_settings_file "$CLAUDE_DIR/settings.json"
    deploy_hook_scripts
  fi

  # Write snapshot for future updates
  write_managed_snapshot
  ok "Created snapshot for future updates"
fi

# ---------------------------------------------------------------------------
# Dry-run: collect file changes, log external operations, show results, exit
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN:-false}" == "true" ]]; then
  _dryrun_collect_file_changes "$_ORIG_CLAUDE_DIR"

  # Log external operations that would happen
  if [[ "$(uname -s)" == "Darwin" ]] && is_true "${ENABLE_GHOSTTY_SETUP:-false}"; then
    _dryrun_log "EXTERNAL" "Ghostty" "brew install --cask ghostty"
  fi
  if is_true "${ENABLE_FONTS_SETUP:-false}"; then
    _dryrun_log "EXTERNAL" "Fonts" "IBM Plex Mono + HackGen NF"
  fi
  # Match the real install logic: WSL always installs local Linux binary
  _dr_need_cli=false
  if [[ -x "$HOME/.local/bin/claude" ]]; then
    _dr_need_cli=false
  elif is_wsl; then
    _dr_need_cli=true
  elif ! command -v claude &>/dev/null; then
    _dr_need_cli=true
  fi
  if $_dr_need_cli; then
    _dr_cli_cmd="curl -fsSL https://claude.ai/install.sh | bash"
    if is_msys; then
      _dr_cli_cmd='powershell.exe -NoProfile -Command "irm https://claude.ai/install.ps1 | iex"'
    fi
    _dryrun_log "EXTERNAL" "Claude CLI" "$_dr_cli_cmd"
  fi
  if [[ -n "${SELECTED_PLUGINS:-}" ]]; then
    IFS=',' read -r -a _dr_plugins <<< "$SELECTED_PLUGINS"
    for _dr_p in "${_dr_plugins[@]}"; do
      _dr_name="${_dr_p%%@*}"
      [[ -n "$_dr_name" ]] && _dryrun_log "EXTERNAL" "Plugin" "claude plugin install $_dr_name"
    done
  fi
  if is_true "${ENABLE_CODEX_PLUGIN:-false}"; then
    _dryrun_log "EXTERNAL" "Codex Plugin" "claude plugin marketplace add openai/codex-plugin-cc"
    _dryrun_log "EXTERNAL" "Codex Plugin" "claude plugin install codex --scope user"
  fi

  # Shell RC modification (PATH entry for ~/.local/bin)
  _dryrun_log "EXTERNAL" "Shell RC" "append PATH=\$HOME/.local/bin to shell RC file"

  # Log skipped files from fresh install safety
  for _sk in "${_FRESH_SKIPPED_FILES[@]+"${_FRESH_SKIPPED_FILES[@]}"}"; do
    _dryrun_log "SKIP" "\$HOME/.claude/${_sk#"$CLAUDE_DIR"/}" "user file preserved"
  done

  # Detect files that would be deleted (exist in real dir but not in sim dir)
  _dryrun_collect_deletions "$_ORIG_CLAUDE_DIR"

  _dryrun_show_results "$_ORIG_CLAUDE_DIR"
  exit 0
fi

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

# ---------------------------------------------------------------------------
# Programming font installation (cross-platform)
# ---------------------------------------------------------------------------
if is_true "${ENABLE_FONTS_SETUP:-false}"; then
  section "$STR_FONTS_SECTION_TITLE"
  setup_fonts
fi

write_manifest

# Save config for re-runs
save_config "${WIZARD_CONFIG_FILE:-$HOME/.claude-starter-kit.conf}"

section "Setup Complete"
ok "Deployed to $CLAUDE_DIR"

# _ensure_local_bin_in_path is now _add_to_path_now_and_persist in lib/prerequisites.sh

# ---------------------------------------------------------------------------
# Install Claude Code CLI if not present
# In WSL, Windows PATH can leak (e.g. /mnt/c/.../npm/claude) causing false
# positives for 'command -v claude'. Check for the actual Linux binary first.
# ---------------------------------------------------------------------------
_need_cli_install=false
if [[ -x "$HOME/.local/bin/claude" ]]; then
  _need_cli_install=false
elif is_wsl; then
  # In WSL, ignore Windows PATH — require local Linux binary
  _need_cli_install=true
elif ! command -v claude &>/dev/null; then
  _need_cli_install=true
fi

if $_need_cli_install; then
  printf "\n"
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
      _add_to_path_now_and_persist "$HOME/.local/bin"
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
      _add_to_path_now_and_persist "$HOME/.local/bin"
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
else
  ok "$STR_CLI_ALREADY"
fi

# Always ensure ~/.local/bin is in PATH config (even if CLI was found via
# inherited PATH from another user or transient session)
_add_to_path_now_and_persist "$HOME/.local/bin"

# ---------------------------------------------------------------------------
# Install plugins
# ---------------------------------------------------------------------------
if [[ -n "${SELECTED_PLUGINS:-}" ]]; then
  printf "\n"
  IFS=',' read -r -a _plugins <<< "$SELECTED_PLUGINS"
  if command -v claude &>/dev/null; then
    # Get list of already installed plugins
    _installed_plugins="$(claude plugin list 2>/dev/null || true)"

    # Check if any plugins need installing (update mode always proceeds)
    _need_install=false
    if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
      _need_install=true
    else
      for _p in "${_plugins[@]}"; do
        _p_name="${_p%%@*}"
        if [[ -n "$_p_name" ]] && ! echo "$_installed_plugins" | grep -q "$_p_name" 2>/dev/null; then
          _need_install=true
          break
        fi
      done
    fi

    if [[ "$_need_install" == "true" ]]; then
      # Register required marketplaces (deduplicated)
      _registered_mps=""
      for _p in "${_plugins[@]}"; do
        [[ -z "$_p" ]] && continue
        if [[ "$_p" == *"@"* ]]; then
          _p_mp="${_p#*@}"
        else
          _p_mp="claude-plugins-official"
        fi
        # Skip if already registered in this run
        if [[ ",$_registered_mps," == *",$_p_mp,"* ]]; then
          continue
        fi
        # Resolve GitHub repo from plugins.json marketplaces map
        _mp_repo="$(jq -r --arg mp "$_p_mp" '.marketplaces[$mp] // empty' "$PROJECT_DIR/config/plugins.json")"
        if [[ -n "$_mp_repo" ]]; then
          claude plugin marketplace add "$_mp_repo" 2>/dev/null || true
        fi
        _registered_mps="${_registered_mps:+${_registered_mps},}${_p_mp}"
      done
      info "$STR_DEPLOY_PLUGINS_INSTALLING"
    fi

    for _p in "${_plugins[@]}"; do
      _p_name="${_p%%@*}"
      if [[ -n "$_p_name" ]]; then
        if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
          # Update mode: always re-install to pick up latest versions
          if claude plugin install "$_p_name" --scope user 2>/dev/null; then
            ok "${STR_DEPLOY_PLUGINS_UPDATED:-Updated} $_p_name"
          else
            warn "$STR_DEPLOY_PLUGINS_FAILED $_p_name"
          fi
        elif echo "$_installed_plugins" | grep -q "$_p_name" 2>/dev/null; then
          ok "$STR_DEPLOY_PLUGINS_ALREADY $_p_name"
        elif claude plugin install "$_p_name" --scope user; then
          ok "$STR_DEPLOY_PLUGINS_INSTALLED $_p_name"
        else
          warn "$STR_DEPLOY_PLUGINS_FAILED $_p_name"
        fi
      fi
    done
  else
    warn "$STR_DEPLOY_PLUGINS_SKIP"
    info "$STR_DEPLOY_PLUGINS_HINT"
    for _p in "${_plugins[@]}"; do
      _p_name="${_p%%@*}"
      [[ -n "$_p_name" ]] && printf "  /install %s\n" "$_p_name"
    done
  fi
fi

# ---------------------------------------------------------------------------
# Codex Plugin setup (sourced from lib/codex-setup.sh)
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/codex-setup.sh"
run_codex_setup

# ---------------------------------------------------------------------------
# Final safety net: ensure Claude CLI is actually installed
# (catches edge cases where the earlier installation was skipped or failed)
# ---------------------------------------------------------------------------
if [[ ! -x "$HOME/.local/bin/claude" ]] && ! command -v claude &>/dev/null; then
  printf "\n"
  warn "Claude CLI not found after setup. Running installer..."
  if curl -fsSL https://claude.ai/install.sh | bash; then
    _add_to_path_now_and_persist "$HOME/.local/bin"
    ok "$STR_CLI_INSTALLED"
  else
    warn "$STR_CLI_INSTALL_FAILED"
    info "  curl -fsSL https://claude.ai/install.sh | bash"
  fi
fi

# ---------------------------------------------------------------------------
# Final message
# ---------------------------------------------------------------------------
printf "\n"
# Ghostty incomplete message is only relevant on macOS
if [[ "${#GHOSTTY_INCOMPLETE[@]}" -gt 0 ]] && [[ "$(uname -s)" == "Darwin" ]]; then
  section "$STR_FINAL_INCOMPLETE_TITLE"
  warn "$STR_FINAL_INCOMPLETE_GHOSTTY"
  for _item in "${GHOSTTY_INCOMPLETE[@]}"; do
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
    if [[ -x "/Applications/Ghostty.app/Contents/MacOS/ghostty" ]]; then
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
  # Font incomplete warning
  if [[ "${#FONTS_INCOMPLETE[@]}" -gt 0 ]]; then
    printf "\n"
    warn "$STR_FINAL_INCOMPLETE_FONTS"
    for _item in "${FONTS_INCOMPLETE[@]}"; do
      warn "  - $_item"
    done
  fi
  printf "\n"
  warn "${STR_FINAL_RESTART_WARN:-Important: Restart your terminal for settings to take effect.}"
  info "${STR_FINAL_RESTART_HINT:-Close this terminal and open a new one before running claude.}"
  printf "\n"
  ok "$STR_FINAL_ENJOY"
fi
printf "\n"
