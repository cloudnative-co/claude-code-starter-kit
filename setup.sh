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
setup_stage1() {

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
  error "Bash 4+ is required and automatic installation did not succeed."
  if [[ "$(uname -s)" == "Darwin" ]]; then
    info "  brew install bash"
  else
    info "  sudo apt-get install bash  (or equivalent)"
  fi
  exit 1
}
}

# ═══════════════════════════════════════════════════════════════════════════
# Stage 2: Bash 4+ required from this point (template, json, merge, etc.)
# ═══════════════════════════════════════════════════════════════════════════
setup_source_stage2() {

# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/features.sh"

# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/recommendation.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/progress.sh"
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
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/codex-setup.sh"
}

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------
setup_run_wizard() {
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
}

ensure_dirs() {
  mkdir -p "$CLAUDE_DIR"/{agents,rules,commands,skills,memory,hooks}
}

should_auto_install_biome() {
  command -v biome &>/dev/null && return 1
  is_true "${ENABLE_BIOME_HOOKS:-false}"
}

maybe_install_biome() {
  should_auto_install_biome || return 0

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    _dryrun_log "EXTERNAL" "Biome" "brew install biome || npm install -g @biomejs/biome"
    return 0
  fi

  check_biome || true
}

should_auto_install_cc_safety_net() {
  command -v cc-safety-net &>/dev/null && return 1
  is_true "${ENABLE_SAFETY_NET:-false}"
}

maybe_install_cc_safety_net() {
  should_auto_install_cc_safety_net || return 0

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    _dryrun_log "EXTERNAL" "cc-safety-net" "npm install -g --ignore-scripts --no-audit --no-fund cc-safety-net"
    return 0
  fi

  # Test harness opt-out: skip the (network) npm install during automated tests.
  [[ -n "${SAFETY_NET_SKIP_NPM_INSTALL:-}" ]] && return 0

  check_cc_safety_net || true
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
# Uses _FEATURE_SCRIPT_ORDER + _FEATURE_HAS_SCRIPTS from lib/features.sh.
# ---------------------------------------------------------------------------
deploy_hook_scripts() {
  local mode="${1:-simple}"
  local name flag
  for name in "${_FEATURE_SCRIPT_ORDER[@]}"; do
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
setup_prepare_runtime() {
_ORIG_CLAUDE_DIR=""
if [[ "${DRY_RUN:-false}" == "true" ]]; then
  _ORIG_CLAUDE_DIR="$CLAUDE_DIR"
  _dryrun_init "$CLAUDE_DIR"
  CLAUDE_DIR="$_DRYRUN_DIR"
  _MERGE_INTERACTIVE="false"  # dry-run is always non-interactive
  _QUIET_OUTPUT="true"        # suppress progress messages, show only summary
fi

maybe_install_biome
maybe_install_cc_safety_net
}

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
setup_deploy() {
if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
  # Remove legacy 24h update cache so the old auto-update.sh (pre-v0.39.0)
  # won't skip the next check. Once the new hook scripts are deployed by this
  # update, the cache file is no longer used.
  rm -f "$CLAUDE_DIR/.starter-kit-update-cache" 2>/dev/null || true

  if _has_user_customizations "$CLAUDE_DIR"; then
    _offer_dryrun_preview "$STR_DRYRUN_OFFER_EXISTING"
  fi
  backup_existing
  if ! _snapshot_exists "$CLAUDE_DIR"; then
    bootstrap_snapshot_from_current
  fi

  # Migrate: initialize DISMISSED_FEATURES if not present in saved config.
  # This prevents all existing features from being treated as "new" on the
  # first update after the feature recommendation system is deployed.
  # The key's existence (even empty) serves as the migration marker.
  _conf_path="${WIZARD_CONFIG_FILE:-$HOME/.claude-starter-kit.conf}"
  if [[ " $_CONFIG_ALLOWED_KEYS " == *" DISMISSED_FEATURES "* ]] \
     && ! grep -q '^DISMISSED_FEATURES=' "$_conf_path" 2>/dev/null; then
    # shellcheck disable=SC2034 # DISMISSED_FEATURES is used by save_config() and lib/recommendation.sh
    DISMISSED_FEATURES=""
  fi
  _validate_dismissed_features

  # Update mode: run update with merge logic
  run_update "$PROJECT_DIR" "$CLAUDE_DIR"

  # Detect new features and write pending notification (non-fatal)
  _detect_and_write_pending_features "$CLAUDE_DIR" || true
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
# Install heavy-skill npm dependencies (web-content-extraction)
# Node-optional (warns + continues if Node/npm missing); dry-run logs only.
# Placed after the deploy branch so it covers update / fresh / fresh-with-existing.
# ---------------------------------------------------------------------------
maybe_install_web_content_deps
}

_need_claude_cli_install() {
  if [[ -x "$HOME/.local/bin/claude" ]]; then
    return 1
  fi
  if is_wsl; then
    return 0
  fi
  ! command -v claude &>/dev/null
}

_claude_cli_install_command() {
  if is_msys; then
    printf '%s\n' 'powershell.exe -NoProfile -Command "irm https://claude.ai/install.ps1 | iex"'
  else
    printf '%s\n' 'curl -fsSL https://claude.ai/install.sh | bash'
  fi
}

_ensure_windows_claude_path() {
  is_msys || return 0
  local win_dir
  for win_dir in \
    "$(cygpath -u "${LOCALAPPDATA:-}/Programs/claude" 2>/dev/null)" \
    "$(cygpath -u "${APPDATA:-}/npm" 2>/dev/null)" \
    "$HOME/.local/bin"; do
    [[ -n "$win_dir" ]] && export PATH="$win_dir:$PATH"
  done
}

_install_claude_cli() {
  if is_msys; then
    if powershell.exe -NoProfile -Command "irm https://claude.ai/install.ps1 | iex"; then
      _ensure_windows_claude_path
      _add_to_path_now_and_persist "$HOME/.local/bin"
      command -v claude &>/dev/null && ok "$STR_CLI_INSTALLED" || warn "$STR_CLI_PATH_WARN"
      return 0
    fi
    warn "$STR_CLI_INSTALL_FAILED"
    info "  powershell -c 'irm https://claude.ai/install.ps1 | iex'"
    return 1
  fi

  if curl -fsSL https://claude.ai/install.sh | bash; then
    _add_to_path_now_and_persist "$HOME/.local/bin"
    command -v claude &>/dev/null && ok "$STR_CLI_INSTALLED" || warn "$STR_CLI_PATH_WARN"
    return 0
  fi
  warn "$STR_CLI_INSTALL_FAILED"
  info "  curl -fsSL https://claude.ai/install.sh | bash"
  return 1
}

install_claude_cli_if_needed() {
  local mode="${1:-normal}"
  if ! _need_claude_cli_install; then
    [[ "$mode" == "quiet" || "$mode" == "safety" ]] || ok "$STR_CLI_ALREADY"
    _add_to_path_now_and_persist "$HOME/.local/bin"
    return 0
  fi

  printf "\n"
  if [[ "$mode" == "safety" ]]; then
    warn "Claude CLI not found after setup. Running installer..."
  else
    info "$STR_CLI_INSTALLING"
  fi
  _install_claude_cli || true
  _add_to_path_now_and_persist "$HOME/.local/bin"
}

install_selected_plugins() {
  [[ -n "${SELECTED_PLUGINS:-}" ]] || return 0
  printf "\n"
  local plugins
  IFS=',' read -r -a plugins <<< "$SELECTED_PLUGINS"
  if ! command -v claude &>/dev/null; then
    warn "$STR_DEPLOY_PLUGINS_SKIP"
    info "$STR_DEPLOY_PLUGINS_HINT"
    local p p_name
    for p in "${plugins[@]}"; do
      p_name="${p%%@*}"
      [[ -n "$p_name" ]] && printf "  /install %s\n" "$p_name"
    done
    return 0
  fi

  local installed_plugins need_install=false
  installed_plugins="$(claude plugin list 2>/dev/null || true)"
  if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
    need_install=true
  else
    local p p_name
    for p in "${plugins[@]}"; do
      p_name="${p%%@*}"
      if [[ -n "$p_name" ]] && ! _claude_plugin_list_has "$installed_plugins" "$p_name"; then
        need_install=true
        break
      fi
    done
  fi

  if [[ "$need_install" == "true" ]]; then
    local registered_mps="" p p_mp mp_repo mp_output
    for p in "${plugins[@]}"; do
      [[ -z "$p" ]] && continue
      [[ "$p" == *"@"* ]] && p_mp="${p#*@}" || p_mp="claude-plugins-official"
      [[ ",$registered_mps," == *",$p_mp,"* ]] && continue
      mp_repo="$(jq -r --arg mp "$p_mp" '.marketplaces[$mp] // empty' "$PROJECT_DIR/config/plugins.json")"
      if [[ -n "$mp_repo" ]]; then
        mp_output=""
        if ! _run_capture mp_output claude plugin marketplace add "$mp_repo"; then
          warn "${STR_DEPLOY_PLUGINS_MARKETPLACE_FAILED:-Failed to add plugin marketplace} $p_mp"
          [[ -n "$mp_output" ]] && info "  $mp_output"
        fi
      fi
      registered_mps="${registered_mps:+${registered_mps},}${p_mp}"
    done
    info "$STR_DEPLOY_PLUGINS_INSTALLING"
  fi

  local p p_name plugin_output
  for p in "${plugins[@]}"; do
    p_name="${p%%@*}"
    [[ -z "$p_name" ]] && continue
    if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
      plugin_output=""
      if _run_capture plugin_output claude plugin install "$p_name" --scope user; then
        ok "${STR_DEPLOY_PLUGINS_UPDATED:-Updated} $p_name"
      else
        warn "$STR_DEPLOY_PLUGINS_FAILED $p_name"
        [[ -n "$plugin_output" ]] && info "  $plugin_output"
      fi
    elif _claude_plugin_list_has "$installed_plugins" "$p_name"; then
      ok "$STR_DEPLOY_PLUGINS_ALREADY $p_name"
    else
      plugin_output=""
      if _run_capture plugin_output claude plugin install "$p_name" --scope user; then
        ok "$STR_DEPLOY_PLUGINS_INSTALLED $p_name"
      else
        warn "$STR_DEPLOY_PLUGINS_FAILED $p_name"
        [[ -n "$plugin_output" ]] && info "  $plugin_output"
      fi
    fi
  done
}

print_final_message() {
  printf "\n"
  if [[ "${#GHOSTTY_INCOMPLETE[@]}" -gt 0 ]] && [[ "$(uname -s)" == "Darwin" ]]; then
    section "$STR_FINAL_INCOMPLETE_TITLE"
    warn "$STR_FINAL_INCOMPLETE_GHOSTTY"
    local item
    for item in "${GHOSTTY_INCOMPLETE[@]}"; do
      warn "  - $item"
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
    printf "\n"
    return 0
  fi

  section "$STR_FINAL_TITLE"
  local ghostty_found=false
  if [[ "$(uname -s)" == "Darwin" && -x "/Applications/Ghostty.app/Contents/MacOS/ghostty" ]]; then
    ghostty_found=true
  fi

  if [[ "$ghostty_found" == "true" ]]; then
    info "$STR_FINAL_GHOSTTY_NEXT"
    info "  $STR_FINAL_GHOSTTY_STEP1"
    info "  $STR_FINAL_GHOSTTY_STEP2"
    info "  $STR_FINAL_GHOSTTY_STEP3"
    printf "\n"
    ok "$STR_FINAL_GHOSTTY_FONT"
  elif is_wsl; then
    info "$STR_FINAL_WSL_NEXT"
    info "  $STR_FINAL_WSL_STEP1"
    info "  $STR_FINAL_WSL_STEP2"
    info "  $STR_FINAL_WSL_STEP3"
  elif is_msys; then
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
  if [[ "${#FONTS_INCOMPLETE[@]}" -gt 0 ]]; then
    printf "\n"
    warn "$STR_FINAL_INCOMPLETE_FONTS"
    local item
    for item in "${FONTS_INCOMPLETE[@]}"; do
      warn "  - $item"
    done
  fi
  printf "\n"
  warn "${STR_FINAL_RESTART_WARN:-Important: Restart your terminal for settings to take effect.}"
  info "${STR_FINAL_RESTART_HINT:-Close this terminal and open a new one before running claude.}"
  printf "\n"
  ok "$STR_FINAL_ENJOY"
  printf "\n"
}

# ---------------------------------------------------------------------------
# Dry-run: collect file changes, log external operations, show results, exit
# ---------------------------------------------------------------------------
setup_finish_dryrun() {
if [[ "${DRY_RUN:-false}" == "true" ]]; then
  _dryrun_collect_file_changes "$_ORIG_CLAUDE_DIR"

  # Log external operations that would happen
  if [[ "$(uname -s)" == "Darwin" ]] && is_true "${ENABLE_GHOSTTY_SETUP:-false}"; then
    _dryrun_log "EXTERNAL" "Ghostty" "brew install --cask ghostty"
  fi
  if is_true "${ENABLE_FONTS_SETUP:-false}"; then
    _dryrun_log "EXTERNAL" "Fonts" "IBM Plex Mono + HackGen NF"
  fi
  if _need_claude_cli_install; then
    _dryrun_log "EXTERNAL" "Claude CLI" "$(_claude_cli_install_command)"
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
}

# ---------------------------------------------------------------------------
# Ghostty terminal setup (macOS only)
# ---------------------------------------------------------------------------
setup_finalize() {
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

install_claude_cli_if_needed

install_selected_plugins

# ---------------------------------------------------------------------------
# Codex Plugin setup (sourced from lib/codex-setup.sh)
# ---------------------------------------------------------------------------
run_codex_setup

# ---------------------------------------------------------------------------
# Final safety net: ensure Claude CLI is actually installed
# (catches edge cases where the earlier installation was skipped or failed)
# ---------------------------------------------------------------------------
install_claude_cli_if_needed "safety"

# ---------------------------------------------------------------------------
# Auto-update health check (fresh install path — update path runs inside run_update)
# ---------------------------------------------------------------------------
if [[ "${UPDATE_MODE:-false}" != "true" ]] && [[ "${DRY_RUN:-false}" != "true" ]]; then
  _check_auto_update_health "$CLAUDE_DIR"
fi

# ---------------------------------------------------------------------------
# Final message
# ---------------------------------------------------------------------------
print_final_message
}

setup_main() {
  setup_stage1 "$@"
  setup_source_stage2
  setup_run_wizard
  setup_prepare_runtime
  setup_deploy
  setup_finish_dryrun
  setup_finalize
}

setup_main "$@"
