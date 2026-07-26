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
  local src link dir
  src="${BASH_SOURCE[0]}"
  while [[ -h "$src" ]]; do
    link="$(/usr/bin/readlink "$src")" || return 1
    case "$link" in
      /*) src="$link" ;;
      *)
        case "$src" in
          */*) dir="${src%/*}"; [[ -n "$dir" ]] || dir=/ ;;
          *) dir=. ;;
        esac
        src="$dir/$link"
        ;;
    esac
  done
  case "$src" in
    */*) dir="${src%/*}"; [[ -n "$dir" ]] || dir=/ ;;
    *) dir=. ;;
  esac
  cd -P "$dir" >/dev/null 2>&1 && pwd
}

_setup_prerequisite_exit_code() {
  if _prereq_mdm_managed; then
    printf '10'
  else
    printf '1'
  fi
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
if ! check_prerequisites; then
  return "$(_setup_prerequisite_exit_code)"
fi

# Check for Bash 4+ and re-exec if needed
check_bash4 || {
  error "Bash 4+ is required and automatic installation did not succeed."
  if [[ "$(uname -s)" == "Darwin" ]]; then
    info "  brew install bash"
  else
    info "  sudo apt-get install bash  (or equivalent)"
  fi
  return "$(_setup_prerequisite_exit_code)"
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
. "$PROJECT_DIR/lib/plugin-adoption.sh"
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
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/plugin-provenance.sh"
}

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------
setup_run_wizard() {
run_wizard
local _rc=$?
[[ "$_rc" -eq 0 ]] || return "$_rc"

case "${WIZARD_RESULT:-cancel}" in
  save)
    save_config "${WIZARD_CONFIG_FILE:-$HOME/.claude-starter-kit.conf}"
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
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
  local _rc=0
  if _deploy_mdm_managed; then
    _prepare_mdm_claude_root
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
    local dir
    for dir in agents rules commands skills hooks; do
      _mdm_ensure_real_distribution_dir "$CLAUDE_DIR/$dir"
      _rc=$?
      [[ "$_rc" -eq 0 ]] || return "$_rc"
    done
  else
    mkdir -p "$CLAUDE_DIR"/{agents,rules,commands,skills,hooks}
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
  fi
}

should_auto_install_biome() {
  is_true "${ENABLE_BIOME_HOOKS:-false}" || return 1
  _prereq_mdm_managed && return 0
  ! command -v biome &>/dev/null
}

maybe_install_biome() {
  local _rc=0
  should_auto_install_biome || return 0

  if _prereq_mdm_managed; then
    if _prereq_mdm_fail_mode; then
      check_mdm_biome_baseline
      _rc=$?
      [[ "$_rc" -eq 0 ]] || return "$_rc"
      return 0
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
      _dryrun_log "EXTERNAL" "Biome" "managed clean install of @biomejs/biome"
      return 0
    fi
    install_mdm_biome
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
    return 0
  fi

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    _dryrun_log "EXTERNAL" "Biome" "brew install biome || npm install -g @biomejs/biome"
    return 0
  fi

  if check_biome; then
    return 0
  fi
  _prereq_mdm_managed && return 1
  return 0
}

should_auto_install_cc_safety_net() {
  is_true "${ENABLE_SAFETY_NET:-false}" || return 1
  _prereq_mdm_managed && return 0
  ! command -v cc-safety-net &>/dev/null
}

maybe_install_cc_safety_net() {
  local _rc=0
  should_auto_install_cc_safety_net || return 0

  if _prereq_mdm_managed; then
    if _prereq_mdm_fail_mode; then
      check_mdm_cc_safety_net_baseline
      _rc=$?
      [[ "$_rc" -eq 0 ]] || return "$_rc"
      return 0
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
      _dryrun_log "EXTERNAL" "cc-safety-net" "managed clean install of cc-safety-net"
      return 0
    fi
    install_mdm_cc_safety_net
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
    return 0
  fi

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    _dryrun_log "EXTERNAL" "cc-safety-net" "npm install -g --ignore-scripts --no-audit --no-fund cc-safety-net"
    return 0
  fi

  # Test harness opt-out for the non-managed, best-effort install path.
  [[ -n "${SAFETY_NET_SKIP_NPM_INSTALL:-}" ]] && return 0

  if check_cc_safety_net; then
    return 0
  fi
  _prereq_mdm_managed && return 1
  return 0
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
  local name _rc=0
  for name in "${_FEATURE_SCRIPT_ORDER[@]}"; do
    [[ "${_FEATURE_HAS_SCRIPTS[$name]+set}" ]] || continue

    _feature_deploy_enabled "$name" || continue

    local src="$PROJECT_DIR/features/$name/scripts"
    [[ -d "$src" ]] || continue

    local dest="$CLAUDE_DIR/hooks/$name"
    if _deploy_mdm_managed; then
      _mdm_ensure_real_distribution_dir "$dest"
      _rc=$?
      [[ "$_rc" -eq 0 ]] || return "$_rc"
    else
      mkdir -p "$dest"
      _rc=$?
      [[ "$_rc" -eq 0 ]] || return "$_rc"
    fi

    if _deploy_mdm_managed; then
      _copy_distribution_tree "$src" "$dest" overwrite
      _rc=$?
      [[ "$_rc" -eq 0 ]] || return "$_rc"
      _mdm_make_distribution_scripts_executable "$src" "$dest"
      _rc=$?
      [[ "$_rc" -eq 0 ]] || return "$_rc"
      ok "Installed $name hooks"
    elif [[ "$mode" == "simple" ]]; then
      cp -a "$src"/. "$dest"/
      _rc=$?
      [[ "$_rc" -eq 0 ]] || return "$_rc"
      _make_hooks_executable "$dest"
      _rc=$?
      [[ "$_rc" -eq 0 ]] || return "$_rc"
      ok "Installed $name hooks"
    else
      # merge-aware: check for existing files
      if [[ -z "$(ls -A "$dest" 2>/dev/null)" ]]; then
        cp -a "$src"/. "$dest"/
        _rc=$?
        [[ "$_rc" -eq 0 ]] || return "$_rc"
        _make_hooks_executable "$dest"
        _rc=$?
        [[ "$_rc" -eq 0 ]] || return "$_rc"
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
            _rc=$?
            [[ "$_rc" -eq 0 ]] || return "$_rc"
            _make_hooks_executable "$dest"
            _rc=$?
            [[ "$_rc" -eq 0 ]] || return "$_rc"
            ok "Installed $name hooks (overwrite)"
            ;;
          skip)
            _FRESH_SKIPPED_FILES+=("$dest")
            ok "$name hooks: ${STR_FRESH_SKIPPED:-skipped}"
            ;;
          new)
            cp -an "$src"/. "$dest"/
            _rc=$?
            [[ "$_rc" -eq 0 ]] || return "$_rc"
            _make_hooks_executable "$dest"
            _rc=$?
            [[ "$_rc" -eq 0 ]] || return "$_rc"
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
  local _script
  for _script in "$dir"/*.sh "$dir"/*.py; do
    [[ -f "$_script" ]] || continue
    chmod +x "$_script" || return 1
  done
}

# ---------------------------------------------------------------------------
# Dry-run: redirect CLAUDE_DIR to simulation directory
# ---------------------------------------------------------------------------
setup_prepare_runtime() {
local _rc=0
_ORIG_CLAUDE_DIR=""
if [[ "${DRY_RUN:-false}" == "true" ]]; then
  _ORIG_CLAUDE_DIR="$CLAUDE_DIR"
  _dryrun_init "$CLAUDE_DIR"
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  CLAUDE_DIR="$_DRYRUN_DIR"
  _MERGE_INTERACTIVE="false"  # dry-run is always non-interactive
  _QUIET_OUTPUT="true"        # suppress progress messages, show only summary
fi

_mdm_validate_claude_cli_prerequisite_policy
_rc=$?
[[ "$_rc" -eq 0 ]] || return "$_rc"
maybe_install_biome
_rc=$?
[[ "$_rc" -eq 0 ]] || return "$_rc"
maybe_install_cc_safety_net
_rc=$?
[[ "$_rc" -eq 0 ]] || return "$_rc"
}

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
_setup_fresh_requires_wce_lock() {
  _deploy_mdm_managed && return 1
  [[ "${DRY_RUN:-false}" != true ]] || return 1
  local current_dir="$CLAUDE_DIR/skills/web-content-extraction"
  local snapshot_dir="$CLAUDE_DIR/.starter-kit-snapshot/skills/web-content-extraction"
  if is_true "${INSTALL_SKILLS:-false}" \
    && [[ -d "$PROJECT_DIR/skills/web-content-extraction" ]]; then
    return 0
  fi
  [[ -e "$current_dir" || -L "$current_dir" \
    || -e "$snapshot_dir" || -L "$snapshot_dir" ]]
}

_setup_write_fresh_deploy_state() { # <state-file>
  local state_file="$1" skipped
  [[ -n "$state_file" ]] || return 0
  : > "$state_file" || return 1
  printf '%s\0%s\0' "${_BACKUP_TIMESTAMP:-}" "${_BACKUP_PATH:-}" \
    >> "$state_file" || return 1
  for skipped in "${_FRESH_SKIPPED_FILES[@]+"${_FRESH_SKIPPED_FILES[@]}"}"; do
    printf '%s\0' "$skipped" >> "$state_file" || return 1
  done
}

_setup_restore_fresh_deploy_state() { # <state-file>
  local state_file="$1" value
  local -a state_values=()
  while IFS= read -r -d '' value; do
    state_values+=("$value")
  done < "$state_file"
  [[ "${#state_values[@]}" -ge 2 ]] || return 1
  _BACKUP_TIMESTAMP="${state_values[0]}"
  _BACKUP_PATH="${state_values[1]}"
  _FRESH_SKIPPED_FILES=("${state_values[@]:2}")
}

_setup_deploy_fresh_body() { # <locked> <root> <skills> <skill> <logs> <skills-content> <state-file>
  local _WCE_FRESH_LOCK_BACKUP_SCRUB="$1"
  local _WCE_FRESH_ROOT_PREEXISTED="$2"
  local _WCE_FRESH_SKILLS_PREEXISTED="$3"
  local _WCE_FRESH_SKILL_PREEXISTED="$4"
  local _WCE_FRESH_LOGS_PREEXISTED="$5"
  local _WCE_FRESH_SKILLS_HAD_ENTRIES="$6"
  local fresh_state_file="$7"
  local _WCE_FRESH_KIT_PAIR_BASELINE=false
  local _rc=0 preserve_wce_pair=false
  _deploy_mdm_managed || _WCE_FRESH_KIT_PAIR_BASELINE=true

  if [[ "$_WCE_FRESH_LOCK_BACKUP_SCRUB" == true \
    && "$_WCE_FRESH_ROOT_PREEXISTED" != true ]]; then
    # Lock acquisition created the previously absent root. It is deployment
    # scaffolding, not pre-existing user state that needs a backup.
    _BACKUP_TIMESTAMP=""
    _BACKUP_PATH=""
  else
    backup_existing
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
  fi
  ensure_dirs
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"

  if ! _deploy_mdm_managed \
    && [[ -f "$CLAUDE_DIR/settings.json" ]] \
    && [[ ! -f "$CLAUDE_DIR/.starter-kit-manifest.json" ]]; then
    _offer_dryrun_preview "$STR_DRYRUN_OFFER_EXISTING"
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
    _deploy_fresh_with_existing
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
  else
    _deploy_mdm_managed || preserve_wce_pair=true
    copy_if_enabled "$INSTALL_AGENTS" "$PROJECT_DIR/agents" \
      "$CLAUDE_DIR/agents"
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
    copy_if_enabled "$INSTALL_RULES" "$PROJECT_DIR/rules" \
      "$CLAUDE_DIR/rules"
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
    copy_if_enabled "$INSTALL_COMMANDS" "$PROJECT_DIR/commands" \
      "$CLAUDE_DIR/commands"
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
    copy_if_enabled "$INSTALL_SKILLS" "$PROJECT_DIR/skills" \
      "$CLAUDE_DIR/skills" "$preserve_wce_pair"
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"

    build_claude_md
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
    _build_settings_managed_file "$CLAUDE_DIR/settings.json"
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
    deploy_hook_scripts
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
  fi

  reconcile_fresh_wce_package_pair
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  _mdm_reconcile_absent_managed_files \
    "$CLAUDE_DIR" "$CLAUDE_DIR/.starter-kit-snapshot"
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  write_managed_snapshot
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  refresh_fresh_wce_snapshot_pair
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  ok "Created snapshot for future updates"

  maybe_install_web_content_deps
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  _setup_write_fresh_deploy_state "$fresh_state_file"
}

_setup_deploy_fresh() {
  if ! _setup_fresh_requires_wce_lock; then
    _setup_deploy_fresh_body false true true true true true ""
    return $?
  fi

  local root_preexisted=false skills_preexisted=false
  local skill_preexisted=false logs_preexisted=false
  local skills_had_entries=false
  local current_dir="$CLAUDE_DIR/skills/web-content-extraction"
  [[ -e "$CLAUDE_DIR" || -L "$CLAUDE_DIR" ]] && root_preexisted=true
  [[ -e "$CLAUDE_DIR/skills" || -L "$CLAUDE_DIR/skills" ]] \
    && skills_preexisted=true
  if [[ -d "$CLAUDE_DIR/skills" && ! -L "$CLAUDE_DIR/skills" \
    && -n "$(ls -A "$CLAUDE_DIR/skills" 2>/dev/null)" ]]; then
    skills_had_entries=true
  fi
  [[ -e "$current_dir" || -L "$current_dir" ]] && skill_preexisted=true
  [[ -e "$current_dir/logs" || -L "$current_dir/logs" ]] \
    && logs_preexisted=true
  if [[ "$root_preexisted" != true ]]; then
    mkdir -p "$CLAUDE_DIR" || return 1
  fi

  local state_file _rc=0
  state_file="$(mktemp)" || return 1
  _SETUP_TMP_FILES+=("$state_file")
  _wce_with_runtime_update_lock "$current_dir" \
    _setup_deploy_fresh_body true "$root_preexisted" \
    "$skills_preexisted" "$skill_preexisted" "$logs_preexisted" \
    "$skills_had_entries" "$state_file"
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  _setup_restore_fresh_deploy_state "$state_file"
}

setup_deploy() {
local _rc=0
_deploy_validate_outer_transaction_carrier
_rc=$?
[[ "$_rc" -eq 0 ]] || return "$_rc"
_prepare_mdm_claude_root
_rc=$?
[[ "$_rc" -eq 0 ]] || return "$_rc"
if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
  # Remove legacy 24h update cache so the old auto-update.sh (pre-v0.39.0)
  # won't skip the next check. Once the new hook scripts are deployed by this
  # update, the cache file is no longer used.
  rm -f "$CLAUDE_DIR/.starter-kit-update-cache" 2>/dev/null || true

  if _has_user_customizations "$CLAUDE_DIR"; then
    _offer_dryrun_preview "$STR_DRYRUN_OFFER_EXISTING"
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
  fi
  backup_existing
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  if ! _snapshot_exists "$CLAUDE_DIR"; then
    bootstrap_snapshot_from_current
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
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
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"

  # Plugin CSVs get the same treatment, minus the migration marker: KNOWN_PLUGINS
  # must stay absent on installs that predate this mechanism, since that absence
  # is what earns them the one-time catch-up offer.
  _validate_plugin_csv KNOWN_PLUGINS
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  _validate_plugin_csv DISMISSED_PLUGINS
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"

  # Update mode: run update with merge logic
  # Keep this as a simple command. Placing a function call on the left side of
  # `||` disables errexit throughout its dynamic call tree in Bash.
  run_update "$PROJECT_DIR" "$CLAUDE_DIR"
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"

  # Detect new features and write pending notification (non-fatal)
  _detect_and_write_pending_features "$CLAUDE_DIR" || true

  # Offer plugins catalogued since the user was last asked (non-fatal).
  # Must run after the feature detection above: that one deletes the pending
  # file outright on the full profile, and plugin newcomers still matter there.
  # Appending to SELECTED_PLUGINS here is enough — write_manifest, save_config,
  # the dry-run plugin log, and install_selected_plugins all read it later.
  _detect_and_offer_new_plugins "$CLAUDE_DIR" || true

  maybe_install_web_content_deps
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
else
  # Fresh install / full re-setup
  section "Deploying Claude Code Starter Kit"
  warn_existing_claude_reconfigure
  _setup_deploy_fresh
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"

  # A fresh/full reconfiguration starts a new adoption baseline. Record the
  # profile's current defaults as known and discard declines inherited from a
  # prior setup, so later updates compare only against choices made for this
  # installation.
  # shellcheck disable=SC2034 # persisted later by save_config()
  DISMISSED_PLUGINS=""
  # Record the profile's current default plugin set as already-known, so the
  # first update after this install does not mistake a fresh install for one
  # that predates the adoption mechanism and re-offer defaults the user
  # explicitly deselected here. Only standard/full have defaults; minimal/custom
  # yield an empty set, which save_config skips — correctly leaving KNOWN_PLUGINS
  # absent to mean "nothing to catch up on". This runs on the fresh path only:
  # the update path restores KNOWN_PLUGINS from the conf (or leaves it absent for
  # the one-time catch-up), and must not have it stamped here.
  # shellcheck disable=SC2034 # KNOWN_PLUGINS is persisted by save_config()
  KNOWN_PLUGINS="$(_profile_default_plugins "${PROFILE:-standard}" 2>/dev/null || printf '')"
fi
}

_mdm_requires_native_claude_cli() {
  _prereq_mdm_managed || return 1
  case "${KIT_MDM_REQUIRE_NATIVE_CLAUDE_CLI:-}" in
    [tT][rR][uU][eE]|1|[yY][eE][sS]|[oO][nN]) return 0 ;;
  esac
  case "${KIT_MDM_INSTALL_CLAUDE_CLI:-}" in
    [fF][aA][lL][sS][eE]|0|[nN][oO]|[oO][fF][fF]) return 1 ;;
    *) return 0 ;;
  esac
}

_mdm_claude_cli_install_disabled() {
  _prereq_mdm_managed || return 1
  case "${KIT_MDM_INSTALL_CLAUDE_CLI:-}" in
    [fF][aA][lL][sS][eE]|0|[nN][oO]|[oO][fF][fF]) return 0 ;;
    *) return 1 ;;
  esac
}

_mdm_validate_claude_cli_prerequisite_policy() {
  _prereq_mdm_managed || return 0

  if _mdm_claude_cli_install_disabled; then
    if _mdm_requires_native_claude_cli; then
      warn "Conflicting managed Claude CLI policy: native CLI is required but installation is disabled."
      return 1
    fi
    return 0
  fi

  if _prereq_mdm_fail_mode && ! _mdm_native_claude_cli_present; then
    warn "The managed Claude CLI requirement is not satisfied and prerequisite mode is fail."
    return 1
  fi
  return 0
}

_mdm_claude_cli_codesign_requirement() {
  printf '%s' '=identifier "com.anthropic.claude-code" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "Q6L2SF6YDW"'
}

_mdm_claude_codesign() {
  /usr/bin/codesign "$@"
}

_mdm_native_cli_acl_safe() {
  local _path="$1" _allow_deny_only="${2:-false}"
  local _listing _first _perms _remaining _entry _saw_acl="false"
  [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == "Darwin" ]] || return 0
  _listing="$(LC_ALL=C /bin/ls -lde "$_path" 2>/dev/null)" || return 1
  _first="${_listing%%$'\n'*}"
  _perms="${_first%%[[:space:]]*}"
  [[ "$_first" == *[[:space:]]* \
    && "$_perms" =~ ^[-bcdlps][rwxStTs-]{9}[@+]?$ ]] || return 1
  if [[ "$_perms" != *+* && "$_listing" != *$'\n'* ]]; then
    return 0
  fi
  [[ "$_allow_deny_only" == "true" && "$_listing" == *$'\n'* \
    && "$_listing" != *$'\r'* ]] || return 1
  _remaining="${_listing#*$'\n'}"
  while IFS= read -r _entry; do
    [[ "$_entry" =~ ^[[:space:]]+[0-9]+:[^[:cntrl:]]+[[:space:]]deny[[:space:]][^[:cntrl:]]+$ ]] \
      || return 1
    _saw_acl="true"
  done < <(printf '%s\n' "$_remaining")
  [[ "$_saw_acl" == "true" ]]
}

_mdm_snapshot_native_cli() {
  local _target="$1" _snapshot="$2" _python="/usr/bin/python3"
  [[ -x "$_python" ]] || return 1
  "$_python" -I -B -c '
import hashlib
import os
import stat
import sys

source, snapshot = sys.argv[1:]
nofollow = getattr(os, "O_NOFOLLOW", 0)
nonblock = getattr(os, "O_NONBLOCK", 0)
if not nofollow:
    raise SystemExit(1)

def validate_source(metadata):
    return (stat.S_ISREG(metadata.st_mode)
            and metadata.st_uid == os.geteuid()
            and metadata.st_nlink == 1
            and not metadata.st_mode & 0o022
            and metadata.st_mode & stat.S_IXUSR
            and metadata.st_size <= 512 * 1024 * 1024)

def identity(metadata):
    return (metadata.st_dev, metadata.st_ino, metadata.st_uid,
            metadata.st_nlink, stat.S_IMODE(metadata.st_mode),
            metadata.st_size, metadata.st_mtime_ns, metadata.st_ctime_ns)

def copy_and_digest(source_fd, destination_fd=None):
    digest = hashlib.sha256()
    total = 0
    while True:
        chunk = os.read(source_fd, 1024 * 1024)
        if not chunk:
            break
        total += len(chunk)
        if total > 512 * 1024 * 1024:
            raise OSError("native CLI exceeds size limit")
        digest.update(chunk)
        if destination_fd is not None:
            view = memoryview(chunk)
            while view:
                written = os.write(destination_fd, view)
                view = view[written:]
    return digest.digest()

source_fd = os.open(source, os.O_RDONLY | nofollow | nonblock)
try:
    before = os.fstat(source_fd)
    if not validate_source(before):
        raise OSError("unsafe native CLI metadata")
    snapshot_fd = os.open(snapshot, os.O_WRONLY | os.O_TRUNC | nofollow)
    try:
        snapshot_metadata = os.fstat(snapshot_fd)
        if (not stat.S_ISREG(snapshot_metadata.st_mode)
                or snapshot_metadata.st_uid != os.geteuid()
                or snapshot_metadata.st_nlink != 1):
            raise OSError("unsafe snapshot metadata")
        first_digest = copy_and_digest(source_fd, snapshot_fd)
        os.fchmod(snapshot_fd, 0o700)
        os.fsync(snapshot_fd)
    finally:
        os.close(snapshot_fd)
finally:
    os.close(source_fd)

source_fd = os.open(source, os.O_RDONLY | nofollow | nonblock)
try:
    after = os.fstat(source_fd)
    if not validate_source(after) or identity(after) != identity(before):
        raise OSError("native CLI identity changed")
    if copy_and_digest(source_fd) != first_digest:
        raise OSError("native CLI bytes changed")
finally:
    os.close(source_fd)
' "$_target" "$_snapshot"
}

_mdm_native_cli_matches_snapshot() {
  local _target="$1" _snapshot="$2" _python="/usr/bin/python3"
  [[ -x "$_python" ]] || return 1
  "$_python" -I -B -c '
import hashlib
import os
import stat
import sys

target, snapshot = sys.argv[1:]
nofollow = getattr(os, "O_NOFOLLOW", 0)
nonblock = getattr(os, "O_NONBLOCK", 0)
if not nofollow:
    raise SystemExit(1)

def digest(path, require_executable):
    descriptor = os.open(path, os.O_RDONLY | nofollow | nonblock)
    try:
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1
                or metadata.st_uid != os.geteuid()
                or metadata.st_size > 512 * 1024 * 1024
                or (require_executable and
                    (metadata.st_mode & 0o022 or
                     not metadata.st_mode & stat.S_IXUSR))):
            raise OSError("unsafe native CLI comparison metadata")
        value = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > 512 * 1024 * 1024:
                raise OSError("native CLI exceeds size limit")
            value.update(chunk)
        return value.digest()
    finally:
        os.close(descriptor)

if digest(target, True) != digest(snapshot, False):
    raise SystemExit(1)
' "$_target" "$_snapshot"
}

_mdm_native_claude_cli_present() {
  local _link="$HOME/.local/bin/claude"
  local _versions="$HOME/.local/share/claude/versions"
  local _python="/usr/bin/python3"
  local _target _requirement _details _snapshot _tmp_base _acl_path _rc=1

  [[ -x "$_python" ]] || return 1
  _target="$("$_python" -I -B -c '
import os
import re
import stat
import sys

def quiet_failure(_exc_type, _exc_value, _traceback):
    os._exit(1)

sys.excepthook = quiet_failure

link, versions = sys.argv[1:]
if any(any(ord(char) < 32 or ord(char) == 127 for char in value)
       for value in (link, versions)):
    raise SystemExit(1)
if not os.path.islink(link):
    raise SystemExit(1)
link_parent = os.path.dirname(link)
home = os.path.dirname(os.path.dirname(link_parent))

def safe_directory(path):
    metadata = os.stat(path, follow_symlinks=False)
    return (stat.S_ISDIR(metadata.st_mode)
            and metadata.st_uid == os.geteuid()
            and not metadata.st_mode & 0o022
            and os.path.realpath(path) == path)

for directory in (home, os.path.join(home, ".local"), link_parent,
                  os.path.join(home, ".local", "share"),
                  os.path.join(home, ".local", "share", "claude"),
                  versions):
    if not safe_directory(directory):
        raise SystemExit(1)
link_metadata = os.stat(link, follow_symlinks=False)
if not stat.S_ISLNK(link_metadata.st_mode) or link_metadata.st_uid != os.geteuid():
    raise SystemExit(1)
target = os.readlink(link)
if any(ord(char) < 32 or ord(char) == 127 for char in target):
    raise SystemExit(1)
if not os.path.isabs(target) or os.path.normpath(target) != target:
    raise SystemExit(1)
if os.path.dirname(target) != versions:
    raise SystemExit(1)
version = os.path.basename(target)
if not re.fullmatch(r"[0-9A-Za-z._+-]+", version):
    raise SystemExit(1)
try:
    if os.path.islink(target) or os.path.realpath(target) != target:
        raise SystemExit(1)
    metadata = os.stat(target)
except OSError:
    raise SystemExit(1)
if (not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
        or metadata.st_mode & 0o022
        or not metadata.st_mode & stat.S_IXUSR
        or not os.access(target, os.X_OK)):
    raise SystemExit(1)
sys.stdout.write(target)
' "$_link" "$_versions"
  )" || return 1
  [[ -n "$_target" ]] || return 1

  _mdm_native_cli_acl_safe "$HOME" true || return 1
  for _acl_path in "$HOME/.local" "$HOME/.local/bin" \
    "$HOME/.local/share" "$HOME/.local/share/claude" \
    "$HOME/.local/share/claude/versions" "$HOME/.local/bin/claude" \
    "$_target"; do
    _mdm_native_cli_acl_safe "$_acl_path" || return 1
  done

  _tmp_base="${TMPDIR:-}"
  if [[ "$_tmp_base" == /* && -d "$_tmp_base" ]]; then
    :
  elif [[ "$(/usr/bin/uname -s 2>/dev/null)" == Darwin ]]; then
    _tmp_base=/private/tmp
  else
    # MDM production is Darwin-only. Keep the same snapshot contract testable
    # on Linux CI, where /private/tmp does not normally exist.
    _tmp_base=/tmp
  fi
  _snapshot="$(/usr/bin/mktemp "$_tmp_base/claude-kit-cli.XXXXXX")" \
    || return 1
  _SETUP_TMP_FILES+=("$_snapshot")
  if ! _mdm_snapshot_native_cli "$_target" "$_snapshot"; then
    /bin/rm -f "$_snapshot"
    return 1
  fi

  _requirement="$(_mdm_claude_cli_codesign_requirement)" || return 1
  _mdm_claude_codesign --verify --strict -R "$_requirement" \
    "$_snapshot" >/dev/null 2>&1 \
    && _details="$(_mdm_claude_codesign -dv --verbose=4 "$_snapshot" 2>&1)" \
    && printf '%s\n' "$_details" \
      | /usr/bin/grep -qx 'Identifier=com.anthropic.claude-code' \
    && printf '%s\n' "$_details" \
      | /usr/bin/grep -qx 'TeamIdentifier=Q6L2SF6YDW' \
    && printf '%s\n' "$_details" \
      | /usr/bin/grep -qx \
        'Authority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)' \
    && _mdm_native_cli_matches_snapshot "$_target" "$_snapshot" \
    && _mdm_native_cli_acl_safe "$_target" \
    && _rc=0
  /bin/rm -f "$_snapshot"
  return "$_rc"
}

_mdm_prepare_native_claude_cli_reinstall() {
  _prereq_mdm_managed || return 0
  local _link="$HOME/.local/bin/claude"
  local _versions="$HOME/.local/share/claude/versions"
  local _python="/usr/bin/python3"

  [[ -x "$_python" ]] || return 1
  _mdm_native_cli_acl_safe "$HOME" true || return 1
  "$_python" -I -B -c '
import os
import re
import secrets
import stat
import subprocess
import sys

def quiet_failure(_exc_type, _exc_value, _traceback):
    os._exit(1)

sys.excepthook = quiet_failure

link, versions = sys.argv[1:]
link_parent = os.path.dirname(link)
home = os.path.dirname(os.path.dirname(link_parent))
local_dir = os.path.join(home, ".local")
claude_root = os.path.dirname(versions)
share_dir = os.path.dirname(claude_root)

def validate_existing_directory(path):
    if not os.path.lexists(path):
        return False
    metadata = os.stat(path, follow_symlinks=False)
    if (not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or os.path.realpath(path) != path):
        raise OSError("untrusted directory")
    return True

def open_bound_directory(path):
    before = os.stat(path, follow_symlinks=False)
    if not stat.S_ISDIR(before.st_mode) or before.st_uid != os.geteuid():
        raise OSError("untrusted directory")
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    after = os.fstat(descriptor)
    if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
        os.close(descriptor)
        raise OSError("directory identity changed")
    return descriptor

def normalize_reserved_directory(path):
    if not validate_existing_directory(path):
        return False
    descriptor = open_bound_directory(path)
    try:
        before = os.fstat(descriptor)
        # Preserve any existing group/other read and search permissions while
        # removing write authority and ensuring the owner can manage the path.
        os.fchmod(descriptor, 0o700 | (stat.S_IMODE(before.st_mode) & 0o055))
        if sys.platform == "darwin":
            subprocess.run(
                ["/bin/chmod", "-N", "/dev/fd/{}".format(descriptor)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
                close_fds=True,
                pass_fds=(descriptor,),
                check=True,
            )
        after = os.fstat(descriptor)
        if ((before.st_dev, before.st_ino) != (after.st_dev, after.st_ino)
                or after.st_mode & 0o022):
            raise OSError("directory normalization failed")
    finally:
        os.close(descriptor)
    current = os.stat(path, follow_symlinks=False)
    if ((current.st_dev, current.st_ino) != (after.st_dev, after.st_ino)
            or not stat.S_ISDIR(current.st_mode)
            or os.path.realpath(path) != path):
        raise OSError("directory identity changed after normalization")
    return True

if not validate_existing_directory(home):
    raise SystemExit(1)
home_metadata = os.stat(home, follow_symlinks=False)
if home_metadata.st_mode & 0o022:
    raise SystemExit(1)
if not normalize_reserved_directory(local_dir):
    raise SystemExit(0)

# Normalize every existing reserved ancestor before the official installer
# can write through it. A missing suffix is a clean-install case; a symlink,
# foreign owner, or non-directory anywhere in the existing prefix is fatal.
versions_exists = False
if normalize_reserved_directory(share_dir):
    if normalize_reserved_directory(claude_root):
        versions_exists = normalize_reserved_directory(versions)

if not normalize_reserved_directory(link_parent):
    raise SystemExit(0)

link_dir_fd = open_bound_directory(link_parent)
link_name = os.path.basename(link)
candidate = None
try:
    link_metadata = os.stat(link_name, dir_fd=link_dir_fd, follow_symlinks=False)
except FileNotFoundError:
    link_metadata = None
if link_metadata is not None and stat.S_ISLNK(link_metadata.st_mode):
    target = os.readlink(link_name, dir_fd=link_dir_fd)
    if (not any(ord(char) < 32 or ord(char) == 127 for char in target)
            and os.path.isabs(target)
            and os.path.normpath(target) == target
            and os.path.dirname(target) == versions
            and re.fullmatch(r"[0-9A-Za-z._+-]+", os.path.basename(target))
            and versions_exists):
        candidate = target

def remove_or_move_aside(directory_fd, name):
    try:
        metadata = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    if stat.S_ISDIR(metadata.st_mode):
        for _ in range(32):
            replacement = ".%s.mdm-replaced-%s" % (name, secrets.token_hex(8))
            try:
                os.rename(
                    name, replacement,
                    src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
                return
            except FileExistsError:
                continue
        raise OSError("could not reserve a replacement path")
    os.unlink(name, dir_fd=directory_fd)

# Never follow the launcher or its target.  Only the exact launcher and an
# exact, direct versions/<safe-name> entry are eligible for replacement; an
# external symlink target is deliberately left untouched.
try:
    remove_or_move_aside(link_dir_fd, link_name)
finally:
    os.close(link_dir_fd)
if candidate is not None and os.path.lexists(candidate):
    versions_fd = open_bound_directory(versions)
    try:
        remove_or_move_aside(versions_fd, os.path.basename(candidate))
    finally:
        os.close(versions_fd)
' "$_link" "$_versions"
}

_need_claude_cli_install() {
  _mdm_claude_cli_install_disabled && return 1
  if _mdm_requires_native_claude_cli; then
    ! _mdm_native_claude_cli_present
    return
  fi
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

_ensure_claude_cli_path() {
  local _bin="$HOME/.local/bin"
  if _prereq_mdm_managed; then
    # Managed success must not depend on target-user shell state.  In
    # particular, reading or rewriting a pre-created FIFO/symlink RC file can
    # block remediation or make user-controlled state a completion authority.
    case ":$PATH:" in
      *":$_bin:"*) ;;
      *) export PATH="$_bin:$PATH" ;;
    esac
    return 0
  fi
  _add_to_path_now_and_persist "$_bin"
}

_run_claude_cli_installer() {
  if _prereq_mdm_managed; then
    local _proxy
    local -a _proxy_env=()
    [[ -x /usr/bin/curl && -x /usr/bin/env && -x /bin/bash ]] || return 1
    # The MDM entry point validates and allowlists exactly these variables.
    # Preserve them for proxy-required networks without inheriting any other
    # target-user environment as installer authority.
    for _proxy in HTTP_PROXY HTTPS_PROXY NO_PROXY; do
      [[ -n "${!_proxy:-}" ]] && _proxy_env+=("$_proxy=${!_proxy}")
    done
    # The managed installer is an authority boundary: do not let a target
    # user's PATH, shell startup variables, or curl config select executables
    # or alter either stage of the official installer.
    /usr/bin/env -i HOME=/var/empty CURL_HOME=/var/empty \
      XDG_CONFIG_HOME=/var/empty PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      "${_proxy_env[@]}" \
      /usr/bin/curl -qfsSL https://claude.ai/install.sh \
      | /usr/bin/env -i HOME="$HOME" CURL_HOME=/var/empty \
        XDG_CONFIG_HOME=/var/empty TMPDIR=/private/tmp \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin "${_proxy_env[@]}" /bin/bash
  else
    curl -fsSL https://claude.ai/install.sh | bash
  fi
}

_install_claude_cli() {
  local _rc=0
  if is_msys; then
    if powershell.exe -NoProfile -Command "irm https://claude.ai/install.ps1 | iex"; then
      _ensure_windows_claude_path
      _rc=$?
      [[ "$_rc" -eq 0 ]] || return "$_rc"
      _ensure_claude_cli_path
      _rc=$?
      [[ "$_rc" -eq 0 ]] || return "$_rc"
      command -v claude &>/dev/null && ok "$STR_CLI_INSTALLED" || warn "$STR_CLI_PATH_WARN"
      return 0
    fi
    warn "$STR_CLI_INSTALL_FAILED"
    info "  powershell -c 'irm https://claude.ai/install.ps1 | iex'"
    return 1
  fi

  if _run_claude_cli_installer; then
    _ensure_claude_cli_path
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
    command -v claude &>/dev/null && ok "$STR_CLI_INSTALLED" || warn "$STR_CLI_PATH_WARN"
    return 0
  fi
  warn "$STR_CLI_INSTALL_FAILED"
  info "  curl -fsSL https://claude.ai/install.sh | bash"
  return 1
}

install_claude_cli_if_needed() {
  local mode="${1:-normal}"
  local _native_required="false"
  local _rc=0
  if _mdm_requires_native_claude_cli; then
    _native_required="true"
  fi
  # MDM 配布（spec §11(a)・mdm/install-mdm.sh が環境変数で注入）:
  # KIT_MDM_INSTALL_CLAUDE_CLI が明示的に false のときのみ CLI 導入を行わない。
  # 不正値・未設定は fail-closed（従来どおり導入）— 無検証の値で機能を黙って
  # 無効化しない。false 判定は MDM 層の bool 正規化と同じ語彙に限定する。
  if _prereq_mdm_managed; then
    case "${KIT_MDM_INSTALL_CLAUDE_CLI:-}" in
      [fF][aA][lL][sS][eE]|0|[nN][oO]|[oO][fF][fF])
        if [[ "$_native_required" == "true" ]]; then
          warn "Conflicting managed Claude CLI policy: native CLI is required but installation is disabled."
          return 1
        fi
        [[ "$mode" == "quiet" || "$mode" == "safety" ]] || info "Skipping Claude CLI install (KIT_MDM_INSTALL_CLAUDE_CLI=false)"
        return 0 ;;
    esac
  fi
  if ! _need_claude_cli_install; then
    [[ "$mode" == "quiet" || "$mode" == "safety" ]] || ok "$STR_CLI_ALREADY"
    _ensure_claude_cli_path
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
    return 0
  fi

  if _prereq_mdm_fail_mode; then
    warn "The managed Claude CLI requirement is not satisfied and prerequisite mode is fail."
    return 1
  fi

  if [[ "$_native_required" == "true" ]]; then
    _mdm_prepare_native_claude_cli_reinstall
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
  fi

  printf "\n"
  if [[ "$mode" == "safety" ]]; then
    warn "Claude CLI not found after setup. Running installer..."
  else
    info "$STR_CLI_INSTALLING"
  fi
  if ! _install_claude_cli; then
    [[ "$_native_required" == "true" ]] && return 1
    # Preserve the normal installer's historical best-effort behavior: even
    # when the network installer fails, make an already-present local CLI
    # discoverable. Managed/native failures remain fatal above.
    _ensure_claude_cli_path
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
    return 0
  fi
  _ensure_claude_cli_path
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  if [[ "$_native_required" == "true" ]] && ! _mdm_native_claude_cli_present; then
    warn "The official installer did not produce the required native Claude CLI layout."
    return 1
  fi
}

# Build a catalog-validated install plan. The output arrays deliberately carry
# both the exact install identity and its registered marketplace repository so
# real and dry-run paths cannot drift. Any unknown plugin/marketplace is
# skipped at this final external-execution boundary.
_PLUGIN_INSTALL_ENTRIES=()
_PLUGIN_INSTALL_MARKETPLACES=()
_PLUGIN_INSTALL_REPOS=()

_validated_plugin_catalog_snapshot() { # <catalog-file>
  jq -cse '
    if length == 1 and (.[0] as $catalog
      | ($catalog | type) == "object"
      and (($catalog.marketplaces | type) == "object")
      and all($catalog.marketplaces | to_entries[];
        (.key | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
        and ((.value | type) == "string")
        and ((.value | length) > 0))
      and (($catalog.plugins | type) == "array")
      and all($catalog.plugins[];
        (type == "object")
        and ((.name | type) == "string")
        and (.name | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
        and ((.description | type) == "string")
        and ((.profiles | type) == "array")
        and all(.profiles[];
          (type == "string") and test("^(minimal|standard|full)$"))
        and ((if has("marketplace") then .marketplace
              else "claude-plugins-official" end) as $marketplace
          | (($marketplace | type) == "string")
          and ($marketplace | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
          and ($catalog.marketplaces | has($marketplace)))))
    then .[0]
    else error("invalid plugin catalog")
    end
  ' "$1" 2>/dev/null
}

_build_plugin_install_plan() { # <plugins-csv>
  local csv="${1:-}" raw name mp record repo collision resolved catalog
  local raw_entries=() seen_entries=""
  _PLUGIN_INSTALL_ENTRIES=()
  _PLUGIN_INSTALL_MARKETPLACES=()
  _PLUGIN_INSTALL_REPOS=()
  [[ -n "$csv" ]] || return 0
  if ! catalog="$(_validated_plugin_catalog_snapshot \
    "$PROJECT_DIR/config/plugins.json")"; then
    warn "${STR_DEPLOY_PLUGINS_CATALOG_INVALID:-Skipping plugin install because config/plugins.json is invalid.}"
    return 1
  fi
  IFS=',' read -r -a raw_entries < <(printf '%s\n' "$csv")
  for raw in "${raw_entries[@]+"${raw_entries[@]}"}"; do
    [[ -n "$raw" ]] || continue
    name="${raw%%@*}"
    if [[ "$raw" == *"@"* ]]; then
      mp="${raw#*@}"
    else
      mp="claude-plugins-official"
    fi
    record="$(printf '%s' "$catalog" | jq -cer --arg n "$name" --arg mp "$mp" '
      (.marketplaces[$mp] // empty) as $repo
      | select(($repo | type) == "string" and ($repo | length) > 0)
      | select(any(.plugins[];
          .name == $n and ((if has("marketplace") then .marketplace
            else "claude-plugins-official" end) == $mp)))
      | {repo: $repo, collision: ([.plugins[] | select(.name == $n)
          | if has("marketplace") then .marketplace
            else "claude-plugins-official" end] | unique | length)}
    ' 2>/dev/null || true)"
    if [[ -z "$record" ]]; then
      warn "${STR_DEPLOY_PLUGINS_UNKNOWN:-Skipping plugin outside the current catalog or marketplace mapping:} $raw"
      continue
    fi
    repo="$(printf '%s' "$record" | jq -r '.repo')" || return 1
    collision="$(printf '%s' "$record" | jq -r '.collision')" || return 1
    resolved="$raw"
    if [[ "$raw" != *"@"* ]] && [[ "${collision:-0}" -gt 1 ]]; then
      resolved="${name}@claude-plugins-official"
    fi
    [[ ",$seen_entries," == *",$resolved,"* ]] && continue
    seen_entries="${seen_entries:+${seen_entries},}${resolved}"
    _PLUGIN_INSTALL_ENTRIES+=("$resolved")
    _PLUGIN_INSTALL_MARKETPLACES+=("$mp")
    _PLUGIN_INSTALL_REPOS+=("$repo")
  done
}

# Marketplace-strict installed check for regular catalog plugins. The shared
# Codex helper intentionally keeps its historical bare-name semantics, so a
# regular bare target needs this stricter official-marketplace interpretation.
_selected_plugin_list_has() { # <plugin-list> <resolved-target>
  local list="$1" target="$2"
  if [[ "$target" == *"@"* ]]; then
    _claude_plugin_list_has "$list" "$target"
    return
  fi
  printf '%s\n' "$list" | awk -v name="$target" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line == "") next
      n = split(line, parts, /[[:space:]]+/)
      candidate = parts[1]
      if (candidate !~ /^[A-Za-z0-9_]/ && n >= 2) candidate = parts[2]
      if (candidate == name || candidate == name "@claude-plugins-official") found = 1
    }
    END { exit found ? 0 : 1 }
  '
}

# Capture an installed-plugin snapshot only when `claude plugin list` succeeds.
# A failing command may still emit partial stdout; treating that as authoritative
# would make both the real install and its dry-run preview skip required work.
_read_claude_plugin_list() { # <output-variable>
  local output_var="$1" plugin_snapshot=""
  printf -v "$output_var" '%s' ""
  command -v claude &>/dev/null || return 1
  if ! plugin_snapshot="$(claude plugin list 2>/dev/null)"; then
    return 1
  fi
  printf -v "$output_var" '%s' "$plugin_snapshot"
}

_plugin_install_plan_needs_work() { # <installed-plugin-list>
  local installed_plugins="$1" entry
  [[ "${UPDATE_MODE:-false}" == "true" ]] \
    && [[ "${#_PLUGIN_INSTALL_ENTRIES[@]}" -gt 0 ]] \
    && return 0
  for entry in "${_PLUGIN_INSTALL_ENTRIES[@]+"${_PLUGIN_INSTALL_ENTRIES[@]}"}"; do
    if ! _selected_plugin_list_has "$installed_plugins" "$entry"; then
      return 0
    fi
  done
  return 1
}

_dryrun_log_plugin_operations() { # <plugins-csv> [label]
  local csv="${1:-}" label="${2:-Plugin}" i repo entry
  local installed_plugins="" registered_repos=""
  _build_plugin_install_plan "$csv" || return 1
  [[ "${#_PLUGIN_INSTALL_ENTRIES[@]}" -gt 0 ]] || return 0

  # When no CLI exists yet, setup_finish_dryrun has already previewed the CLI
  # bootstrap that precedes plugin installation. Keep an empty snapshot so the
  # follow-on plugin operations remain visible in that case. A present CLI is
  # trusted as an installed-state source only when its list command succeeds.
  if command -v claude &>/dev/null; then
    _read_claude_plugin_list installed_plugins || true
  fi
  _plugin_install_plan_needs_work "$installed_plugins" || return 0

  # The real path registers every selected repository before installing any
  # missing entry (and refreshes every entry during update mode).
  for i in "${!_PLUGIN_INSTALL_ENTRIES[@]}"; do
    repo="${_PLUGIN_INSTALL_REPOS[$i]}"
    if [[ ",$registered_repos," != *",$repo,"* ]]; then
      _dryrun_log "EXTERNAL" "$label marketplace" \
        "claude plugin marketplace add $repo"
      registered_repos="${registered_repos:+${registered_repos},}${repo}"
    fi
  done
  for i in "${!_PLUGIN_INSTALL_ENTRIES[@]}"; do
    entry="${_PLUGIN_INSTALL_ENTRIES[$i]}"
    if [[ "${UPDATE_MODE:-false}" != "true" ]] \
      && _selected_plugin_list_has "$installed_plugins" "$entry"; then
      continue
    fi
    _dryrun_log "EXTERNAL" "$label" \
      "claude plugin install $entry --scope user"
  done
}

install_selected_plugins() {
  [[ -n "${SELECTED_PLUGINS:-}" ]] || return 0
  printf "\n"
  _build_plugin_install_plan "$SELECTED_PLUGINS" || return 1
  [[ "${#_PLUGIN_INSTALL_ENTRIES[@]}" -gt 0 ]] || return 0
  if ! command -v claude &>/dev/null; then
    warn "$STR_DEPLOY_PLUGINS_SKIP"
    info "$STR_DEPLOY_PLUGINS_HINT"
    local p p_name
    for p in "${_PLUGIN_INSTALL_ENTRIES[@]}"; do
      p_name="${p%%@*}"
      # Keep the @marketplace suffix: /install resolves a specific marketplace
      # only from a "name@marketplace" argument.
      [[ -n "$p_name" ]] && printf "  /install %s\n" "$p"
    done
    return 0
  fi

  local installed_plugins="" plugin_list_trusted=false need_install=false
  if _read_claude_plugin_list installed_plugins \
    && _plugin_provenance_list_exact_entries \
      "$installed_plugins" >/dev/null; then
    plugin_list_trusted=true
  fi
  if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
    need_install=true
  elif [[ "$plugin_list_trusted" != "true" ]]; then
    need_install=true
  else
    local p p_qualified
    for p in "${_PLUGIN_INSTALL_ENTRIES[@]}"; do
      p_qualified="$(_plugin_provenance_qualify "$p")" || continue
      if _plugin_provenance_is_pending "$CLAUDE_DIR" "$p_qualified" \
        || ! _plugin_provenance_list_has_exact \
          "$installed_plugins" "$p_qualified"; then
        need_install=true
        break
      fi
    done
  fi

  local failed_repos=""
  if [[ "$need_install" == "true" ]]; then
    local registered_repos="" i p_mp mp_repo mp_output
    for i in "${!_PLUGIN_INSTALL_ENTRIES[@]}"; do
      p_mp="${_PLUGIN_INSTALL_MARKETPLACES[$i]}"
      mp_repo="${_PLUGIN_INSTALL_REPOS[$i]}"
      [[ ",$registered_repos," == *",$mp_repo,"* ]] && continue
      mp_output=""
      if ! _run_capture mp_output claude plugin marketplace add "$mp_repo"; then
        warn "${STR_DEPLOY_PLUGINS_MARKETPLACE_FAILED:-Failed to add plugin marketplace} $p_mp"
        [[ -n "$mp_output" ]] && info "  $mp_output"
        failed_repos="${failed_repos:+${failed_repos},}${mp_repo}"
      fi
      registered_repos="${registered_repos:+${registered_repos},}${mp_repo}"
    done
    info "$STR_DEPLOY_PLUGINS_INSTALLING"
    installed_plugins=""
    if ! _read_claude_plugin_list installed_plugins \
      || ! _plugin_provenance_list_exact_entries \
        "$installed_plugins" >/dev/null; then
      warn "Could not refresh installed plugins after marketplace setup"
      return 1
    fi
    plugin_list_trusted=true
  fi

  local p p_name p_qualified plugin_output post_install_plugins
  local was_absent provenance_pending provenance_verified provenance_installed
  local plugin_setup_failed=false
  for i in "${!_PLUGIN_INSTALL_ENTRIES[@]}"; do
    p="${_PLUGIN_INSTALL_ENTRIES[$i]}"
    mp_repo="${_PLUGIN_INSTALL_REPOS[$i]}"
    if [[ ",$failed_repos," == *",$mp_repo,"* ]]; then
      continue
    fi
    p_qualified="$(_plugin_provenance_qualify "$p")" || {
      warn "$STR_DEPLOY_PLUGINS_FAILED $p"
      continue
    }
    p_name="${p_qualified%%@*}"
    was_absent=false
    if [[ "$plugin_list_trusted" == "true" ]] \
      && ! _plugin_provenance_list_has_exact \
        "$installed_plugins" "$p_qualified"; then
      was_absent=true
    fi
    provenance_pending=false
    provenance_verified=false
    provenance_installed=false
    _plugin_provenance_is_pending "$CLAUDE_DIR" "$p_qualified" \
      && provenance_pending=true
    _plugin_provenance_is_verified "$CLAUDE_DIR" "$p_qualified" \
      && provenance_verified=true
    _plugin_provenance_is_installed_by_kit "$CLAUDE_DIR" "$p_qualified" \
      && provenance_installed=true

    # Only a postcondition verified in the same earlier attempt can be
    # committed on a later run without installing again.
    if [[ "$provenance_verified" == "true" ]]; then
      if _plugin_provenance_record "$CLAUDE_DIR" "$p_qualified"; then
        provenance_verified=false
        provenance_installed=true
        if [[ "$plugin_list_trusted" == "true" ]] \
          && _plugin_provenance_list_has_exact \
            "$installed_plugins" "$p_qualified"; then
          continue
        fi
      else
        warn "Could not record starter-kit plugin ownership: $p_qualified"
        plugin_setup_failed=true
        continue
      fi
    fi

    # Pending intent alone does not prove installation. Preserve a plugin that
    # appeared between attempts as pre-existing and cancel only the stale intent.
    if [[ "$provenance_pending" == "true" ]]; then
      if [[ "$plugin_list_trusted" != "true" ]]; then
        warn "Could not resume starter-kit plugin install safely: $p_qualified"
        plugin_setup_failed=true
        continue
      fi
      if _plugin_provenance_list_has_exact \
          "$installed_plugins" "$p_qualified"; then
        if _plugin_provenance_cancel_pending \
            "$CLAUDE_DIR" "$p_qualified"; then
          provenance_pending=false
        else
          warn "Could not cancel stale starter-kit plugin intent: $p_qualified"
          plugin_setup_failed=true
          continue
        fi
      fi
    fi

    # Record intent only after an exact, trusted user-scope list proves absence.
    if [[ "$was_absent" == "true" \
      && "$provenance_pending" != "true" \
      && "$provenance_installed" != "true" ]]; then
      if _plugin_provenance_prepare "$CLAUDE_DIR" "$p_qualified"; then
        provenance_pending=true
      else
        warn "Could not prepare starter-kit plugin ownership: $p_qualified"
        plugin_setup_failed=true
        continue
      fi
    fi

    if [[ "${UPDATE_MODE:-false}" != "true" \
      && "$provenance_pending" != "true" \
      && "$plugin_list_trusted" == "true" ]] \
      && _plugin_provenance_list_has_exact \
        "$installed_plugins" "$p_qualified"; then
      ok "$STR_DEPLOY_PLUGINS_ALREADY $p"
      continue
    fi

    plugin_output=""
    if _run_capture plugin_output \
        claude plugin install "$p" --scope user; then
      post_install_plugins=""
      if ! _read_claude_plugin_list post_install_plugins; then
        warn "Could not verify installed plugin exactly: $p_qualified"
        plugin_setup_failed=true
        continue
      fi
      if [[ "$plugin_list_trusted" != "true" ]] \
        || ! _plugin_provenance_install_postcondition \
          "$installed_plugins" "$post_install_plugins" "$p_qualified"; then
        warn "Could not verify installed plugin exactly: $p_qualified"
        plugin_setup_failed=true
        continue
      fi
      installed_plugins="$post_install_plugins"
      plugin_list_trusted=true
      if [[ "$provenance_pending" == "true" ]] \
        && ! _plugin_provenance_verify "$CLAUDE_DIR" "$p_qualified"; then
          warn "Could not persist verified plugin install: $p_qualified"
          plugin_setup_failed=true
          continue
      fi
      if [[ "$provenance_pending" == "true" ]]; then
        provenance_pending=false
        provenance_verified=true
      fi
      if [[ "$provenance_verified" == "true" ]] \
        && ! _plugin_provenance_record "$CLAUDE_DIR" "$p_qualified"; then
          warn "Could not record starter-kit plugin ownership: $p_qualified"
          plugin_setup_failed=true
          continue
      fi
      if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
        ok "${STR_DEPLOY_PLUGINS_UPDATED:-Updated} $p"
      else
        ok "$STR_DEPLOY_PLUGINS_INSTALLED $p"
      fi
    else
      warn "$STR_DEPLOY_PLUGINS_FAILED $p"
      [[ -n "$plugin_output" ]] && info "  $plugin_output"
      plugin_setup_failed=true
    fi
  done
  [[ "$plugin_setup_failed" != "true" ]]
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
    if is_true "${KIT_MDM_MANAGED:-false}"; then
      _dryrun_log "EXTERNAL" "Ghostty" "verify MDM-preinstalled /Applications/Ghostty.app"
    else
      _dryrun_log "EXTERNAL" "Ghostty" "brew install --cask ghostty"
    fi
  fi
  if is_true "${ENABLE_FONTS_SETUP:-false}"; then
    _dryrun_log "EXTERNAL" "Fonts" "IBM Plex Mono + HackGen NF"
  fi
  if _need_claude_cli_install; then
    _dryrun_log "EXTERNAL" "Claude CLI" "$(_claude_cli_install_command)"
  fi
  _dryrun_log_plugin_operations "${SELECTED_PLUGINS:-}" || return 1
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
local _rc=0
if [[ "$(uname -s)" != "Darwin" ]]; then
  ENABLE_GHOSTTY_SETUP="false"
fi

if is_true "${ENABLE_GHOSTTY_SETUP:-false}"; then
  section "Setting up Ghostty terminal"
  setup_ghostty "$PROJECT_DIR/features/ghostty/config.template"
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
fi

# ---------------------------------------------------------------------------
# Programming font installation (cross-platform)
# ---------------------------------------------------------------------------
if is_true "${ENABLE_FONTS_SETUP:-false}"; then
  section "$STR_FONTS_SECTION_TITLE"
  setup_fonts
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
fi

# Preserve the normal installer's historical checkpoint: its manifest and
# reusable wizard config describe the completed file deployment and are
# written before best-effort external CLI/plugin setup.  MDM instead needs a
# completion marker only after every required managed component succeeds.
if ! _deploy_mdm_managed; then
  write_manifest
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  save_config "${WIZARD_CONFIG_FILE:-$HOME/.claude-starter-kit.conf}"
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
fi

# _ensure_local_bin_in_path is now _add_to_path_now_and_persist in lib/prerequisites.sh
install_claude_cli_if_needed
_rc=$?
[[ "$_rc" -eq 0 ]] || return "$_rc"

install_selected_plugins
_rc=$?
[[ "$_rc" -eq 0 ]] || return "$_rc"

# ---------------------------------------------------------------------------
# Codex Plugin setup (sourced from lib/codex-setup.sh)
# ---------------------------------------------------------------------------
run_codex_setup
_rc=$?
[[ "$_rc" -eq 0 ]] || return "$_rc"

# ---------------------------------------------------------------------------
# Final safety net: ensure Claude CLI is actually installed
# (catches edge cases where the earlier installation was skipped or failed)
# ---------------------------------------------------------------------------
install_claude_cli_if_needed "safety"
_rc=$?
[[ "$_rc" -eq 0 ]] || return "$_rc"

# Commit the managed deployment marker only after every required component has
# succeeded.  Saved config is neither policy nor state authority in this mode,
# so do not rewrite it; the next run is rebuilt from validated wrapper input.
if _deploy_mdm_managed; then
  write_manifest
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
fi

# ---------------------------------------------------------------------------
# Auto-update health check (fresh install path — update path runs inside run_update)
# ---------------------------------------------------------------------------
if [[ "${UPDATE_MODE:-false}" != "true" ]] && [[ "${DRY_RUN:-false}" != "true" ]]; then
  _check_auto_update_health "$CLAUDE_DIR"
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
fi

section "Setup Complete"
ok "Deployed to $CLAUDE_DIR"

# ---------------------------------------------------------------------------
# Final message
# ---------------------------------------------------------------------------
print_final_message
_rc=$?
[[ "$_rc" -eq 0 ]] || return "$_rc"
}

setup_main() {
  local _rc=0
  setup_stage1 "$@"
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  setup_source_stage2
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  setup_run_wizard
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  setup_prepare_runtime
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  setup_deploy
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  setup_finish_dryrun
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  setup_finalize
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
}

# テストから source して関数を直接検証できるようにする（install.sh 末尾と同形式）。
# unset（パイプ実行）または $0 一致（ファイル実行）で main を呼び、source 時のみスキップ。
if [[ "${BASH_SOURCE[0]:-}" == "" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  setup_main "$@"
fi
