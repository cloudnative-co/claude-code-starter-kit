#!/bin/bash
# wizard/wizard.sh - Interactive setup wizard for Claude Code Starter Kit
# This file is meant to be sourced by setup.sh, not run standalone.
#
# Interface boundary (public functions called by setup.sh):
#   parse_cli_args "$@"    — Parse CLI flags, set WIZARD_* and ENABLE_* globals
#   run_wizard             — Interactive prompt flow (skipped in non-interactive)
#   save_config <path>     — Persist wizard config to file
#   load_config <path>     — Restore wizard config from file
#
# Sets globals: PROFILE, LANGUAGE, EDITOR_CHOICE, COMMIT_ATTRIBUTION,
#               ENABLE_*, INSTALL_*, SELECTED_PLUGINS, SELECTED_HOOKS,
#               UPDATE_MODE, DRY_RUN, WIZARD_NONINTERACTIVE, _RESET_MERGE_PREFS

# ---------------------------------------------------------------------------
# Globals (defaults can be overridden by defaults.conf or loaded config)
# ---------------------------------------------------------------------------
LANGUAGE="${LANGUAGE:-}"
PROFILE="${PROFILE:-}"
EDITOR_CHOICE="${EDITOR_CHOICE:-}"
COMMIT_ATTRIBUTION="${COMMIT_ATTRIBUTION:-}"
ENABLE_NEW_INIT="${ENABLE_NEW_INIT:-}"

INSTALL_AGENTS="${INSTALL_AGENTS:-}"
INSTALL_RULES="${INSTALL_RULES:-}"
INSTALL_COMMANDS="${INSTALL_COMMANDS:-}"
INSTALL_SKILLS="${INSTALL_SKILLS:-}"
INSTALL_MEMORY="${INSTALL_MEMORY:-}"

ENABLE_CODEX_PLUGIN="${ENABLE_CODEX_PLUGIN:-}"
ENABLE_CODEX_MCP="${ENABLE_CODEX_MCP:-}"  # legacy compat (read-only, migrated by _normalize_codex_state)
ENABLE_TMUX_HOOKS="${ENABLE_TMUX_HOOKS:-}"
ENABLE_GIT_PUSH_REVIEW="${ENABLE_GIT_PUSH_REVIEW:-}"
ENABLE_DOC_BLOCKER="${ENABLE_DOC_BLOCKER:-}"
ENABLE_PRETTIER_HOOKS="${ENABLE_PRETTIER_HOOKS:-}"
ENABLE_BIOME_HOOKS="${ENABLE_BIOME_HOOKS:-}"
ENABLE_CONSOLE_LOG_GUARD="${ENABLE_CONSOLE_LOG_GUARD:-}"
ENABLE_MEMORY_PERSISTENCE="${ENABLE_MEMORY_PERSISTENCE:-}"
ENABLE_STRATEGIC_COMPACT="${ENABLE_STRATEGIC_COMPACT:-}"
ENABLE_PR_CREATION_LOG="${ENABLE_PR_CREATION_LOG:-}"
ENABLE_PRE_COMPACT_COMMIT="${ENABLE_PRE_COMPACT_COMMIT:-}"
ENABLE_SAFETY_NET="${ENABLE_SAFETY_NET:-}"
ENABLE_AUTO_UPDATE="${ENABLE_AUTO_UPDATE:-}"
ENABLE_WEB_CONTENT_UPDATE="${ENABLE_WEB_CONTENT_UPDATE:-}"
ENABLE_STATUSLINE="${ENABLE_STATUSLINE:-}"
ENABLE_GHOSTTY_SETUP="${ENABLE_GHOSTTY_SETUP:-}"
ENABLE_FONTS_SETUP="${ENABLE_FONTS_SETUP:-}"
ENABLE_DOC_SIZE_GUARD="${ENABLE_DOC_SIZE_GUARD:-}"
ENABLE_NO_FLICKER="${ENABLE_NO_FLICKER:-}"
ENABLE_FEATURE_RECOMMENDATION="${ENABLE_FEATURE_RECOMMENDATION:-}"

DISMISSED_FEATURES="${DISMISSED_FEATURES:-}"

SELECTED_PLUGINS="${SELECTED_PLUGINS:-}"
WIZARD_RESULT="${WIZARD_RESULT:-}"

WIZARD_NONINTERACTIVE="${WIZARD_NONINTERACTIVE:-false}"
UPDATE_MODE="${UPDATE_MODE:-false}"
_RESET_MERGE_PREFS="${_RESET_MERGE_PREFS:-false}"
_MERGE_INTERACTIVE="${_MERGE_INTERACTIVE:-true}"
DRY_RUN="${DRY_RUN:-false}"
WIZARD_CONFIG_FILE=""

# Track CLI-overridden variables (restored after load_config/profile)
_CLI_OVERRIDES=()

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------
_wizard_dir() {
  local src
  src="${BASH_SOURCE[0]}"
  while [[ -h "$src" ]]; do
    src="$(readlink "$src")"
  done
  cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}

_project_dir() {
  cd -P "$(_wizard_dir)/.." >/dev/null 2>&1 && pwd
}

_bool_normalize() {
  local val
  val="$(printf "%s" "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$val" in
    1|true|yes|y|on) printf "true" ;;
    *) printf "false" ;;
  esac
}

_set_bool() {
  local var="$1"
  local val="$2"
  # Validate variable name to prevent injection
  if [[ ! "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    return 1
  fi
  printf -v "$var" '%s' "$(_bool_normalize "$val")"
}

_bool_label_enabled() {
  if [[ "$(_bool_normalize "$1")" == "true" ]]; then
    printf "%s" "$STR_ENABLED"
  else
    printf "%s" "$STR_DISABLED"
  fi
}

_bool_label_yesno() {
  if [[ "$(_bool_normalize "$1")" == "true" ]]; then
    printf "%s" "$STR_YES"
  else
    printf "%s" "$STR_NO"
  fi
}

_editor_label() {
  case "${1:-none}" in
    vscode) printf "%s" "$STR_EDITOR_VSCODE" ;;
    cursor) printf "%s" "$STR_EDITOR_CURSOR" ;;
    zed)    printf "%s" "$STR_EDITOR_ZED" ;;
    neovim) printf "%s" "$STR_EDITOR_NEOVIM" ;;
    *)      printf "%s" "$STR_EDITOR_NONE" ;;
  esac
}

_profile_label() {
  case "${1:-}" in
    minimal)  printf "%s" "$STR_PROFILE_MINIMAL" ;;
    standard) printf "%s" "$STR_PROFILE_STANDARD" ;;
    full)     printf "%s" "$STR_PROFILE_FULL" ;;
    custom)   printf "%s" "$STR_PROFILE_CUSTOM" ;;
    *)        printf "%s" "$STR_PROFILE_STANDARD" ;;
  esac
}

_language_label() {
  case "${1:-}" in
    ja) printf "日本語" ;;
    *)  printf "English" ;;
  esac
}

# ---------------------------------------------------------------------------
# Defaults, profiles, config persistence
# ---------------------------------------------------------------------------

# _CONFIG_ALLOWED_KEYS (allowlist for _safe_source_config) and _CONFIG_SAVE_KEYS
# (save order for save_config) are generated from the _CONFIG_KEYS registry in
# wizard/registry.sh (sourced below, before any of these functions run).

# Keys where empty string is a valid saved value (e.g., "" = "no plugins selected").
# All other keys: empty values in saved config are skipped so profile defaults are preserved.
_CONFIG_EMPTY_ALLOWED_KEYS="SELECTED_PLUGINS DISMISSED_FEATURES"

# Safe key=value parser: reads a config file line-by-line and only sets
# variables whose names appear in the allowlist. This replaces the previous
# `. "$file"` pattern to prevent arbitrary code execution.
_safe_source_config() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local key value
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    # Skip blank lines and comments
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    # Strip surrounding whitespace and quotes
    key="$(printf '%s' "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*"//;s/"[[:space:]]*$//')"
    # Validate key is alphanumeric/underscore and in allowlist
    if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && [[ " $_CONFIG_ALLOWED_KEYS " == *" $key "* ]]; then
      # Skip empty values unless the key is in _CONFIG_EMPTY_ALLOWED_KEYS.
      # This preserves profile defaults for new feature flags (ENABLE_*) that
      # were saved as empty in older config files before the feature existed.
      if [[ -z "$value" ]] && [[ " $_CONFIG_EMPTY_ALLOWED_KEYS " != *" $key "* ]]; then
        continue
      fi
      printf -v "$key" '%s' "$value"
    fi
  done < "$file"
}

load_defaults() {
  local dir
  dir="$(_wizard_dir)"
  if [[ -f "$dir/defaults.conf" ]]; then
    _safe_source_config "$dir/defaults.conf"
  fi
}

_normalize_formatter_hooks() {
  local prefer="${1:-biome}"
  if [[ "${ENABLE_BIOME_HOOKS:-false}" == "true" ]] && [[ "${ENABLE_PRETTIER_HOOKS:-false}" == "true" ]]; then
    case "$prefer" in
      prettier) ENABLE_BIOME_HOOKS="false" ;;
      *)        ENABLE_PRETTIER_HOOKS="false" ;;
    esac
  fi
}

load_profile_config() {
  local profile="$1"
  # Validate profile against allowlist to prevent path traversal
  case "$profile" in
    minimal|standard|full|custom) ;;
    *) return 1 ;;
  esac
  local dir
  dir="$(_project_dir)"
  if [[ -f "$dir/profiles/${profile}.conf" ]]; then
    _safe_source_config "$dir/profiles/${profile}.conf"
  fi
}

load_config() {
  local file="${1:-$HOME/.claude-starter-kit.conf}"
  if [[ -f "$file" ]]; then
    _safe_source_config "$file"
    local prefer="biome"
    if grep -q '^ENABLE_PRETTIER_HOOKS=' "$file" 2>/dev/null \
      && ! grep -q '^ENABLE_BIOME_HOOKS=' "$file" 2>/dev/null; then
      ENABLE_BIOME_HOOKS="false"
      prefer="prettier"
    fi
    _normalize_formatter_hooks "$prefer"
  fi
}

# Migrate legacy ENABLE_CODEX_MCP to ENABLE_CODEX_PLUGIN.
# Called after config loading + CLI override restore in each path.
_normalize_codex_state() {
  if [[ -n "${ENABLE_CODEX_MCP:-}" ]]; then
    # Only migrate if not already explicitly set via CLI (check both old and new keys)
    local _codex_from_cli=false _ov
    for _ov in "${_CLI_OVERRIDES[@]+"${_CLI_OVERRIDES[@]}"}"; do
      case "$_ov" in
        ENABLE_CODEX_PLUGIN|ENABLE_CODEX_MCP) _codex_from_cli=true ;;
      esac
    done
    if [[ "$_codex_from_cli" == "false" ]]; then
      ENABLE_CODEX_PLUGIN="$ENABLE_CODEX_MCP"
    fi
    ENABLE_CODEX_MCP=""
  fi

  # Scrub stale Codex entries from SELECTED_PLUGINS (field-by-field)
  if [[ -n "${SELECTED_PLUGINS:-}" ]]; then
    local _cleaned="" _field
    IFS=',' read -r -a _sp_arr <<< "$SELECTED_PLUGINS"
    for _field in "${_sp_arr[@]}"; do
      case "$_field" in
        codex@*|codex) continue ;;
      esac
      _cleaned="${_cleaned:+${_cleaned},}${_field}"
    done
    SELECTED_PLUGINS="$_cleaned"
  fi
}

# Load profile defaults while preserving already-set (non-empty) config values,
# including legacy formatter state (saved configs that predate ENABLE_BIOME_HOOKS
# must not have Biome silently enabled by a profile default).
# Sets _PROFILE_FILL_FORMATTER_PREFER ("biome" or "prettier") for the caller to
# pass to _normalize_formatter_hooks once its remaining overrides are applied.
_PROFILE_FILL_FORMATTER_PREFER="biome"
_load_profile_preserving_values() {
  local profile="$1"
  local _saved_pairs=()
  local _var _val _pair _restore_key _restore_val
  local _legacy_formatter_state=false
  _PROFILE_FILL_FORMATTER_PREFER="biome"
  for _var in $_CONFIG_ALLOWED_KEYS; do
    _val="${!_var:-}"
    if [[ -n "$_val" ]]; then
      _saved_pairs+=("${_var}=${_val}")
    fi
  done
  if [[ "${ENABLE_PRETTIER_HOOKS:-}" == "true" ]] && [[ -z "${ENABLE_BIOME_HOOKS:-}" ]]; then
    _PROFILE_FILL_FORMATTER_PREFER="prettier"
  fi
  if [[ -n "${ENABLE_PRETTIER_HOOKS:-}" ]] && [[ -z "${ENABLE_BIOME_HOOKS:-}" ]]; then
    _legacy_formatter_state=true
  fi

  load_profile_config "$profile"
  for _pair in "${_saved_pairs[@]+"${_saved_pairs[@]}"}"; do
    _restore_key="${_pair%%=*}"
    _restore_val="${_pair#*=}"
    printf -v "$_restore_key" '%s' "$_restore_val"
  done
  if [[ "$_legacy_formatter_state" == "true" ]]; then
    ENABLE_BIOME_HOOKS="false"
  fi
}

fill_missing_profile_defaults() {
  local profile="$1"
  case "$profile" in
    minimal|standard|full|custom) ;;
    *) return 1 ;;
  esac

  _load_profile_preserving_values "$profile"
  _normalize_formatter_hooks "$_PROFILE_FILL_FORMATTER_PREFER"
}

# Sanitize a value for safe inclusion in a key=value config file.
# Strips characters that could be interpreted as shell metacharacters.
_sanitize_config_value() {
  printf '%s' "$1" | tr -cd 'a-zA-Z0-9_,.:@/ -'
}

save_config() {
  local file="${1:-$HOME/.claude-starter-kit.conf}"
  {
    printf '# Claude Code Starter Kit - Wizard Config\n'
    local _key
    for _key in "${_CONFIG_SAVE_KEYS[@]}"; do
      if [[ -z "$_key" ]]; then
        printf '\n'
      else
        local _val="${!_key:-}"
        # Don't save empty values unless the key allows it (see _CONFIG_EMPTY_ALLOWED_KEYS).
        # This prevents stale empty entries from overriding profile defaults on update.
        if [[ -z "$_val" ]] && [[ " $_CONFIG_EMPTY_ALLOWED_KEYS " != *" $_key "* ]]; then
          continue
        fi
        printf '%s="%s"\n' "$_key" "$(_sanitize_config_value "$_val")"
      fi
    done
  } > "$file"
  # Restrict config file permissions (contains user preferences)
  chmod 600 "$file"
}

# ---------------------------------------------------------------------------
# Restore configuration from manifest (for update mode)
# ---------------------------------------------------------------------------
_restore_config_from_manifest() {
  local manifest="$HOME/.claude/.starter-kit-manifest.json"
  [[ -f "$manifest" ]] || return 1

  local config_file current_settings
  local manifest_commit_attribution manifest_new_init manifest_codex_plugin
  local saved_has_commit_attribution="false" saved_has_new_init="false" saved_has_codex_plugin="false"
  local current_commit_attribution="" current_new_init=""
  PROFILE="$(jq -r '.profile // "standard"' "$manifest")"
  LANGUAGE="$(jq -r '.language // "en"' "$manifest")"
  EDITOR_CHOICE="$(jq -r '.editor // "none"' "$manifest")"
  SELECTED_PLUGINS="$(jq -r '.plugins // ""' "$manifest")"
  manifest_commit_attribution="$(jq -r '.commit_attribution // ""' "$manifest")"
  manifest_new_init="$(jq -r '.new_init // ""' "$manifest")"
  manifest_codex_plugin="$(jq -r '.codex_plugin // ""' "$manifest")"
  config_file="${WIZARD_CONFIG_FILE:-$HOME/.claude-starter-kit.conf}"
  current_settings="$HOME/.claude/settings.json"

  if [[ -f "$config_file" ]]; then
    grep -q '^COMMIT_ATTRIBUTION=' "$config_file" && saved_has_commit_attribution="true"
    grep -q '^ENABLE_NEW_INIT=' "$config_file" && saved_has_new_init="true"
    if grep -Eq '^ENABLE_CODEX_(PLUGIN|MCP)=' "$config_file"; then
      saved_has_codex_plugin="true"
    fi
  fi

  if [[ -f "$current_settings" ]]; then
    current_commit_attribution="$(
      jq -r 'if has("attribution") then "false" else "true" end' "$current_settings" 2>/dev/null || echo ""
    )"
    current_new_init="$(jq -r '.env.CLAUDE_CODE_NEW_INIT // ""' "$current_settings" 2>/dev/null || echo "")"
  fi

  # Load profile config to get INSTALL_* and ENABLE_* flags
  load_profile_config "$PROFILE"

  # Load saved wizard config for feature toggles
  load_config "$config_file"

  # Fallback order for keys introduced after older installs:
  # saved config > current deployed settings.json > manifest > profile default.
  if [[ "$saved_has_commit_attribution" != "true" ]]; then
    if [[ -n "$current_commit_attribution" ]]; then
      COMMIT_ATTRIBUTION="$current_commit_attribution"
    elif [[ -n "$manifest_commit_attribution" ]]; then
      COMMIT_ATTRIBUTION="$manifest_commit_attribution"
    fi
  fi

  if [[ "$saved_has_new_init" != "true" ]]; then
    if [[ -n "$current_new_init" ]]; then
      ENABLE_NEW_INIT="$current_new_init"
    elif [[ -n "$manifest_new_init" ]]; then
      ENABLE_NEW_INIT="$manifest_new_init"
    fi
  fi

  # Codex plugin: fallback to manifest if saved config has neither old nor new key
  if [[ "$saved_has_codex_plugin" != "true" ]] && [[ -n "$manifest_codex_plugin" ]]; then
    ENABLE_CODEX_PLUGIN="$manifest_codex_plugin"
  fi

  _normalize_formatter_hooks
  _normalize_codex_state
  load_strings "$LANGUAGE"
}

_capture_cli_overrides() {
  local _saved=()
  local _var _val
  for _var in "${_CLI_OVERRIDES[@]+"${_CLI_OVERRIDES[@]}"}"; do
    _val="${!_var:-}"
    if [[ -n "$_val" ]]; then
      _saved+=("${_var}=${_val}")
    fi
  done

  printf '%s\n' "${_saved[@]+"${_saved[@]}"}"
}

_restore_cli_overrides() {
  local _pair _restore_key _restore_val
  for _pair in "$@"; do
    if [[ -n "$_pair" ]]; then
      _restore_key="${_pair%%=*}"
      _restore_val="${_pair#*=}"
      printf -v "$_restore_key" '%s' "$_restore_val"
    fi
  done
}

_load_config_preserving_cli_overrides() {
  local file="$1"
  local _saved_overrides=()
  local _override
  while IFS= read -r _override; do
    [[ -n "$_override" ]] && _saved_overrides+=("$_override")
  done < <(_capture_cli_overrides)

  load_config "$file"
  _restore_cli_overrides "${_saved_overrides[@]+"${_saved_overrides[@]}"}"
}

# Clear all wizard-prompted choices so the interactive flow asks again.
_reset_user_choices() {
  LANGUAGE=""
  PROFILE=""
  EDITOR_CHOICE=""
  COMMIT_ATTRIBUTION=""
  ENABLE_NEW_INIT=""
  ENABLE_CODEX_PLUGIN=""
  ENABLE_GHOSTTY_SETUP=""
  ENABLE_FONTS_SETUP=""
}

# ---------------------------------------------------------------------------
# i18n
# ---------------------------------------------------------------------------
load_strings() {
  local lang="${1:-en}"
  local dir
  dir="$(_project_dir)"
  case "$lang" in
    ja)
      # shellcheck source=/dev/null
      . "$dir/i18n/ja/strings.sh"
      ;;
    *)
      # shellcheck source=/dev/null
      . "$dir/i18n/en/strings.sh"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Registry and interactive step modules
# ---------------------------------------------------------------------------
# shellcheck source=wizard/registry.sh
. "$(_wizard_dir)/registry.sh"
# shellcheck source=wizard/steps.sh
. "$(_wizard_dir)/steps.sh"

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
run_wizard() {
  local dir
  dir="$(_project_dir)"

  # Source libraries
  # shellcheck source=/dev/null
  . "$dir/lib/colors.sh"
  # shellcheck source=/dev/null
  . "$dir/lib/detect.sh"

  # Update mode: restore from manifest, skip wizard
  local _saved_cli=()
  while IFS= read -r _override; do
    [[ -n "$_override" ]] && _saved_cli+=("$_override")
  done < <(_capture_cli_overrides)

  if [[ "$UPDATE_MODE" == "true" ]]; then
    _restore_config_from_manifest
    _restore_cli_overrides "${_saved_cli[@]+"${_saved_cli[@]}"}"
    _normalize_codex_state
    WIZARD_RESULT="deploy"
    return
  fi

  _load_config_preserving_cli_overrides "${WIZARD_CONFIG_FILE:-$HOME/.claude-starter-kit.conf}"
  _normalize_codex_state

  # Non-interactive mode: fill defaults and return
  if [[ "$WIZARD_NONINTERACTIVE" == "true" ]]; then
    _fill_noninteractive_defaults
    load_strings "$LANGUAGE"
    info "Non-interactive mode: PROFILE=$PROFILE LANGUAGE=$LANGUAGE"
    return
  fi

  # Detect saved config and offer to reuse
  local _config_file="${WIZARD_CONFIG_FILE:-$HOME/.claude-starter-kit.conf}"
  if [[ -f "$_config_file" ]]; then
    load_strings "${LANGUAGE:-en}"
    printf "\n"
    info "$STR_SAVED_CONFIG_FOUND"
    printf "  1) %s\n" "$STR_SAVED_CONFIG_REUSE"
    printf "  2) %s\n" "$STR_SAVED_CONFIG_FRESH"
    local _config_choice=""
    read -r -p "${STR_CHOICE}: " _config_choice
    if [[ "$_config_choice" == "1" ]]; then
      if [[ -n "$PROFILE" ]]; then
        fill_missing_profile_defaults "$PROFILE"
      fi
      # Show confirm with saved settings
      _step_confirm
      if [[ "$WIZARD_RESULT" != "edit" ]]; then
        return
      fi
      # User chose to edit - fall through to full wizard
    fi
    # Reset for fresh start (all user choices cleared so wizard asks again)
    _reset_user_choices
  fi

  # Interactive wizard loop
  while true; do
    _step_language
    load_strings "$LANGUAGE"

    printf "\n"
    _print_banner "$STR_BANNER" "$STR_BANNER_SUB"

    _step_profile
    _step_codex
    _step_new_init
    _step_editor
    _step_ghostty
    _step_fonts
    _step_hooks
    _step_plugins
    _step_commit
    _step_confirm

    if [[ "$WIZARD_RESULT" == "edit" ]]; then
      # Reset for re-run (all user choices cleared so wizard asks again)
      _reset_user_choices
      continue
    fi
    break
  done
}
