#!/bin/bash
# wizard/wizard.sh - Interactive setup wizard for Claude Code Starter Kit
# This file is meant to be sourced by setup.sh, not run standalone.
# Provides: run_wizard, parse_cli_args, save_config, load_config

# ---------------------------------------------------------------------------
# Globals (defaults can be overridden by defaults.conf or loaded config)
# ---------------------------------------------------------------------------
LANGUAGE="${LANGUAGE:-}"
PROFILE="${PROFILE:-}"
EDITOR_CHOICE="${EDITOR_CHOICE:-}"
COMMIT_ATTRIBUTION="${COMMIT_ATTRIBUTION:-}"

INSTALL_AGENTS="${INSTALL_AGENTS:-}"
INSTALL_RULES="${INSTALL_RULES:-}"
INSTALL_COMMANDS="${INSTALL_COMMANDS:-}"
INSTALL_SKILLS="${INSTALL_SKILLS:-}"
INSTALL_MEMORY="${INSTALL_MEMORY:-}"

ENABLE_CODEX_MCP="${ENABLE_CODEX_MCP:-}"
ENABLE_TMUX_HOOKS="${ENABLE_TMUX_HOOKS:-}"
ENABLE_GIT_PUSH_REVIEW="${ENABLE_GIT_PUSH_REVIEW:-}"
ENABLE_DOC_BLOCKER="${ENABLE_DOC_BLOCKER:-}"
ENABLE_PRETTIER_HOOKS="${ENABLE_PRETTIER_HOOKS:-}"
ENABLE_CONSOLE_LOG_GUARD="${ENABLE_CONSOLE_LOG_GUARD:-}"
ENABLE_MEMORY_PERSISTENCE="${ENABLE_MEMORY_PERSISTENCE:-}"
ENABLE_STRATEGIC_COMPACT="${ENABLE_STRATEGIC_COMPACT:-}"
ENABLE_PR_CREATION_LOG="${ENABLE_PR_CREATION_LOG:-}"
ENABLE_GHOSTTY_SETUP="${ENABLE_GHOSTTY_SETUP:-}"
ENABLE_FONTS_SETUP="${ENABLE_FONTS_SETUP:-}"

SELECTED_PLUGINS="${SELECTED_PLUGINS:-}"
WIZARD_RESULT="${WIZARD_RESULT:-}"

WIZARD_NONINTERACTIVE="${WIZARD_NONINTERACTIVE:-false}"
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

# Allowed config variable names (used by _safe_source_config for allowlist validation)
_CONFIG_ALLOWED_KEYS="LANGUAGE PROFILE EDITOR_CHOICE COMMIT_ATTRIBUTION INSTALL_AGENTS INSTALL_RULES INSTALL_COMMANDS INSTALL_SKILLS INSTALL_MEMORY ENABLE_CODEX_MCP ENABLE_TMUX_HOOKS ENABLE_GIT_PUSH_REVIEW ENABLE_DOC_BLOCKER ENABLE_PRETTIER_HOOKS ENABLE_CONSOLE_LOG_GUARD ENABLE_MEMORY_PERSISTENCE ENABLE_STRATEGIC_COMPACT ENABLE_PR_CREATION_LOG ENABLE_GHOSTTY_SETUP ENABLE_FONTS_SETUP SELECTED_PLUGINS"

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
  fi
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
    printf 'LANGUAGE="%s"\n' "$(_sanitize_config_value "$LANGUAGE")"
    printf 'PROFILE="%s"\n' "$(_sanitize_config_value "$PROFILE")"
    printf 'EDITOR_CHOICE="%s"\n' "$(_sanitize_config_value "$EDITOR_CHOICE")"
    printf 'COMMIT_ATTRIBUTION="%s"\n' "$(_sanitize_config_value "$COMMIT_ATTRIBUTION")"
    printf '\n'
    printf 'INSTALL_AGENTS="%s"\n' "$(_sanitize_config_value "$INSTALL_AGENTS")"
    printf 'INSTALL_RULES="%s"\n' "$(_sanitize_config_value "$INSTALL_RULES")"
    printf 'INSTALL_COMMANDS="%s"\n' "$(_sanitize_config_value "$INSTALL_COMMANDS")"
    printf 'INSTALL_SKILLS="%s"\n' "$(_sanitize_config_value "$INSTALL_SKILLS")"
    printf 'INSTALL_MEMORY="%s"\n' "$(_sanitize_config_value "$INSTALL_MEMORY")"
    printf '\n'
    printf 'ENABLE_CODEX_MCP="%s"\n' "$(_sanitize_config_value "$ENABLE_CODEX_MCP")"
    printf 'ENABLE_TMUX_HOOKS="%s"\n' "$(_sanitize_config_value "$ENABLE_TMUX_HOOKS")"
    printf 'ENABLE_GIT_PUSH_REVIEW="%s"\n' "$(_sanitize_config_value "$ENABLE_GIT_PUSH_REVIEW")"
    printf 'ENABLE_DOC_BLOCKER="%s"\n' "$(_sanitize_config_value "$ENABLE_DOC_BLOCKER")"
    printf 'ENABLE_PRETTIER_HOOKS="%s"\n' "$(_sanitize_config_value "$ENABLE_PRETTIER_HOOKS")"
    printf 'ENABLE_CONSOLE_LOG_GUARD="%s"\n' "$(_sanitize_config_value "$ENABLE_CONSOLE_LOG_GUARD")"
    printf 'ENABLE_MEMORY_PERSISTENCE="%s"\n' "$(_sanitize_config_value "$ENABLE_MEMORY_PERSISTENCE")"
    printf 'ENABLE_STRATEGIC_COMPACT="%s"\n' "$(_sanitize_config_value "$ENABLE_STRATEGIC_COMPACT")"
    printf 'ENABLE_PR_CREATION_LOG="%s"\n' "$(_sanitize_config_value "$ENABLE_PR_CREATION_LOG")"
    printf 'ENABLE_GHOSTTY_SETUP="%s"\n' "$(_sanitize_config_value "$ENABLE_GHOSTTY_SETUP")"
    printf 'ENABLE_FONTS_SETUP="%s"\n' "$(_sanitize_config_value "$ENABLE_FONTS_SETUP")"
    printf '\n'
    printf 'SELECTED_PLUGINS="%s"\n' "$(_sanitize_config_value "$SELECTED_PLUGINS")"
  } > "$file"
  # Restrict config file permissions (contains user preferences)
  chmod 600 "$file"
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
# Plugin management
# ---------------------------------------------------------------------------
PLUGIN_NAMES=()
PLUGIN_PROFILES=()
PLUGIN_SELECTED=()

_load_plugins() {
  local dir
  dir="$(_project_dir)"
  local file="$dir/config/plugins.json"
  PLUGIN_NAMES=()
  PLUGIN_PROFILES=()
  PLUGIN_SELECTED=()

  if [[ ! -f "$file" ]] || ! command -v jq &>/dev/null; then
    return
  fi

  local count
  count="$(jq '.plugins | length' "$file")"
  local i
  for ((i = 0; i < count; i++)); do
    local name profiles_csv
    name="$(jq -r ".plugins[$i].name" "$file")"
    profiles_csv="$(jq -r ".plugins[$i].profiles | join(\",\")" "$file")"
    PLUGIN_NAMES+=("$name")
    PLUGIN_PROFILES+=("$profiles_csv")
    PLUGIN_SELECTED+=("false")
  done
}

_init_plugins_for_profile() {
  local profile="$1"
  local i
  for i in "${!PLUGIN_NAMES[@]}"; do
    if [[ ",${PLUGIN_PROFILES[$i]}," == *",$profile,"* ]]; then
      PLUGIN_SELECTED[$i]="true"
    else
      PLUGIN_SELECTED[$i]="false"
    fi
  done
}

_apply_plugins_from_csv() {
  local csv="$1"
  local i
  for i in "${!PLUGIN_SELECTED[@]}"; do
    PLUGIN_SELECTED[$i]="false"
  done

  IFS=',' read -r -a _wanted <<< "$csv"
  for i in "${!PLUGIN_NAMES[@]}"; do
    local w
    for w in "${_wanted[@]}"; do
      if [[ "$w" == "${PLUGIN_NAMES[$i]}" ]]; then
        PLUGIN_SELECTED[$i]="true"
      fi
    done
  done
}

_compute_selected_plugins() {
  local out=()
  local i
  for i in "${!PLUGIN_NAMES[@]}"; do
    if [[ "${PLUGIN_SELECTED[$i]}" == "true" ]]; then
      out+=("${PLUGIN_NAMES[$i]}")
    fi
  done
  if [[ "${#out[@]}" -eq 0 ]]; then
    SELECTED_PLUGINS=""
  else
    local IFS=,
    SELECTED_PLUGINS="${out[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Hook management
# ---------------------------------------------------------------------------
HOOK_KEYS=(
  "ENABLE_TMUX_HOOKS"
  "ENABLE_GIT_PUSH_REVIEW"
  "ENABLE_DOC_BLOCKER"
  "ENABLE_PRETTIER_HOOKS"
  "ENABLE_CONSOLE_LOG_GUARD"
  "ENABLE_MEMORY_PERSISTENCE"
  "ENABLE_STRATEGIC_COMPACT"
  "ENABLE_PR_CREATION_LOG"
)

_apply_hooks_csv() {
  local csv="$1"
  local i
  for i in "${!HOOK_KEYS[@]}"; do
    printf -v "${HOOK_KEYS[$i]}" '%s' "false"
  done

  IFS=',' read -r -a _items <<< "$csv"
  local item
  for item in "${_items[@]}"; do
    case "$item" in
      tmux)       ENABLE_TMUX_HOOKS="true" ;;
      git-push)   ENABLE_GIT_PUSH_REVIEW="true" ;;
      doc-block)  ENABLE_DOC_BLOCKER="true" ;;
      prettier)   ENABLE_PRETTIER_HOOKS="true" ;;
      console)    ENABLE_CONSOLE_LOG_GUARD="true" ;;
      memory)     ENABLE_MEMORY_PERSISTENCE="true" ;;
      compact)    ENABLE_STRATEGIC_COMPACT="true" ;;
      pr-log)     ENABLE_PR_CREATION_LOG="true" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# CLI parsing for --non-interactive mode
# ---------------------------------------------------------------------------
parse_cli_args() {
  local arg
  while [[ "$#" -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --non-interactive)
        WIZARD_NONINTERACTIVE="true"
        ;;
      --language=*)      LANGUAGE="${arg#*=}"; _CLI_OVERRIDES+=("LANGUAGE") ;;
      --language)        shift; LANGUAGE="${1:-}"; _CLI_OVERRIDES+=("LANGUAGE") ;;
      --profile=*)       PROFILE="${arg#*=}"; _CLI_OVERRIDES+=("PROFILE") ;;
      --profile)         shift; PROFILE="${1:-}"; _CLI_OVERRIDES+=("PROFILE") ;;
      --editor=*)        EDITOR_CHOICE="${arg#*=}"; _CLI_OVERRIDES+=("EDITOR_CHOICE") ;;
      --editor)          shift; EDITOR_CHOICE="${1:-}"; _CLI_OVERRIDES+=("EDITOR_CHOICE") ;;
      --codex-mcp=*)     _set_bool ENABLE_CODEX_MCP "${arg#*=}"; _CLI_OVERRIDES+=("ENABLE_CODEX_MCP") ;;
      --codex-mcp)       shift; _set_bool ENABLE_CODEX_MCP "${1:-}"; _CLI_OVERRIDES+=("ENABLE_CODEX_MCP") ;;
      --commit-attribution=*) _set_bool COMMIT_ATTRIBUTION "${arg#*=}"; _CLI_OVERRIDES+=("COMMIT_ATTRIBUTION") ;;
      --commit-attribution)   shift; _set_bool COMMIT_ATTRIBUTION "${1:-}"; _CLI_OVERRIDES+=("COMMIT_ATTRIBUTION") ;;
      --ghostty=*)     _set_bool ENABLE_GHOSTTY_SETUP "${arg#*=}"; _CLI_OVERRIDES+=("ENABLE_GHOSTTY_SETUP") ;;
      --ghostty)       shift; _set_bool ENABLE_GHOSTTY_SETUP "${1:-}"; _CLI_OVERRIDES+=("ENABLE_GHOSTTY_SETUP") ;;
      --fonts=*)       _set_bool ENABLE_FONTS_SETUP "${arg#*=}"; _CLI_OVERRIDES+=("ENABLE_FONTS_SETUP") ;;
      --fonts)         shift; _set_bool ENABLE_FONTS_SETUP "${1:-}"; _CLI_OVERRIDES+=("ENABLE_FONTS_SETUP") ;;
      --hooks=*)
        _apply_hooks_csv "${arg#*=}"
        ;;
      --plugins=*)
        _load_plugins
        _apply_plugins_from_csv "${arg#*=}"
        _compute_selected_plugins
        ;;
      --config=*)
        WIZARD_CONFIG_FILE="${arg#*=}"
        load_config "$WIZARD_CONFIG_FILE"
        ;;
      --config)
        shift
        WIZARD_CONFIG_FILE="${1:-}"
        load_config "$WIZARD_CONFIG_FILE"
        ;;
    esac
    shift
  done
}

# ---------------------------------------------------------------------------
# Display width helper (ASCII=1col, CJK/fullwidth=2col)
# ---------------------------------------------------------------------------
_display_width() {
  local str="$1"
  local bytes chars multibyte
  bytes=$(printf '%s' "$str" | LC_ALL=C wc -c | tr -d ' ')
  chars=$(printf '%s' "$str" | wc -m | tr -d ' ')
  multibyte=$(( (bytes - chars) / 2 ))
  printf '%d' $(( chars + multibyte ))
}

_print_banner() {
  local line1="$1"
  local line2="$2"
  local w1 w2 max_w box_inner pad1 pad2

  w1=$(_display_width "$line1")
  w2=$(_display_width "$line2")
  max_w=$w1
  [[ $w2 -gt $max_w ]] && max_w=$w2

  box_inner=$((max_w + 4))

  local border=""
  local i
  for ((i = 0; i < box_inner; i++)); do border+="═"; done

  pad1=$((max_w - w1))
  pad2=$((max_w - w2))

  printf "${BOLD}${CYAN}╔%s╗${NC}\n" "$border"
  printf "${BOLD}${CYAN}║  %s%*s  ║${NC}\n" "$line1" "$pad1" ""
  printf "${BOLD}${CYAN}║  %s%*s  ║${NC}\n" "$line2" "$pad2" ""
  printf "${BOLD}${CYAN}╚%s╝${NC}\n" "$border"
}

# ---------------------------------------------------------------------------
# Interactive steps
# ---------------------------------------------------------------------------
_step_language() {
  if [[ -n "$LANGUAGE" ]]; then return; fi
  printf "\nSelect language: 1) English 2) 日本語\n"
  local choice=""
  read -r -p "Choice: " choice
  case "$choice" in
    2) LANGUAGE="ja" ;;
    *) LANGUAGE="en" ;;
  esac
}

_step_profile() {
  if [[ -n "$PROFILE" ]]; then
    load_profile_config "$PROFILE"
    return
  fi
  section "$STR_PROFILE_TITLE"
  printf "  1) %s\n" "$STR_PROFILE_MINIMAL"
  printf "  2) %s (%s)\n" "$STR_PROFILE_STANDARD" "$STR_RECOMMENDED"
  # Windows (WSL/MSYS) では Ghostty 非対応のため説明文を切り替え
  local _full_label="$STR_PROFILE_FULL"
  if [[ "$(uname -s)" != "Darwin" ]]; then _full_label="${STR_PROFILE_FULL_NO_GHOSTTY:-$STR_PROFILE_FULL}"; fi
  printf "  3) %s\n" "$_full_label"
  printf "  4) %s\n" "$STR_PROFILE_CUSTOM"
  local choice=""
  read -r -p "${STR_CHOICE}: " choice
  case "$choice" in
    1) PROFILE="minimal" ;;
    3) PROFILE="full" ;;
    4) PROFILE="custom" ;;
    *) PROFILE="standard" ;;
  esac

  if [[ "$PROFILE" == "custom" ]]; then
    load_defaults
  else
    load_profile_config "$PROFILE"
  fi
}

_step_codex() {
  # Skip if explicitly set by CLI arg
  local _ov; for _ov in "${_CLI_OVERRIDES[@]+"${_CLI_OVERRIDES[@]}"}"; do [[ "$_ov" == "ENABLE_CODEX_MCP" ]] && return; done

  section "$STR_CODEX_TITLE"
  printf "  1) %s\n" "$STR_CODEX_YES"
  printf "  2) %s\n" "$STR_CODEX_NO"
  # Default: "yes" for full profile, "no" for others
  local _default="2"
  if [[ "${ENABLE_CODEX_MCP:-}" == "true" ]]; then _default="1"; fi
  local choice=""
  read -r -p "${STR_CHOICE} [${_default}]: " choice
  [[ -z "$choice" ]] && choice="$_default"
  case "$choice" in
    1) ENABLE_CODEX_MCP="true" ;;
    *) ENABLE_CODEX_MCP="false" ;;
  esac
}

_step_editor() {
  if [[ -n "$EDITOR_CHOICE" ]]; then return; fi
  section "$STR_EDITOR_TITLE"
  printf "  1) %s\n" "$STR_EDITOR_VSCODE"
  printf "  2) %s\n" "$STR_EDITOR_CURSOR"
  printf "  3) %s\n" "$STR_EDITOR_ZED"
  printf "  4) %s\n" "$STR_EDITOR_NEOVIM"
  printf "  5) %s\n" "$STR_EDITOR_NONE"
  local choice=""
  read -r -p "${STR_CHOICE}: " choice
  case "$choice" in
    1) EDITOR_CHOICE="vscode" ;;
    2) EDITOR_CHOICE="cursor" ;;
    3) EDITOR_CHOICE="zed" ;;
    4) EDITOR_CHOICE="neovim" ;;
    *) EDITOR_CHOICE="none" ;;
  esac
}

_step_ghostty() {
  # Ghostty is macOS only — skip on all non-macOS platforms
  if [[ "$(uname -s)" != "Darwin" ]]; then ENABLE_GHOSTTY_SETUP="false"; return; fi
  # Skip if explicitly set by CLI arg
  local _ov; for _ov in "${_CLI_OVERRIDES[@]+"${_CLI_OVERRIDES[@]}"}"; do [[ "$_ov" == "ENABLE_GHOSTTY_SETUP" ]] && return; done
  # Only ask for custom profile; other profiles use their preset value
  if [[ "$PROFILE" != "custom" ]]; then return; fi

  section "$STR_GHOSTTY_TITLE"
  printf "  %s\n\n" "$STR_GHOSTTY_DESC"
  printf "  1) %s\n" "$STR_GHOSTTY_YES"
  printf "  2) %s\n" "$STR_GHOSTTY_NO"
  local choice=""
  read -r -p "${STR_CHOICE}: " choice
  case "$choice" in
    1) ENABLE_GHOSTTY_SETUP="true" ;;
    *) ENABLE_GHOSTTY_SETUP="false" ;;
  esac
}

_step_fonts() {
  # Skip if explicitly set by CLI arg
  local _ov; for _ov in "${_CLI_OVERRIDES[@]+"${_CLI_OVERRIDES[@]}"}"; do [[ "$_ov" == "ENABLE_FONTS_SETUP" ]] && return; done
  # Only ask for custom profile; other profiles use their preset value
  if [[ "$PROFILE" != "custom" ]]; then return; fi

  section "$STR_FONTS_TITLE"
  printf "  %s\n\n" "$STR_FONTS_DESC"
  printf "  1) %s\n" "$STR_FONTS_YES"
  printf "  2) %s\n" "$STR_FONTS_NO"
  local choice=""
  read -r -p "${STR_CHOICE}: " choice
  case "$choice" in
    1) ENABLE_FONTS_SETUP="true" ;;
    *) ENABLE_FONTS_SETUP="false" ;;
  esac
}

_step_hooks() {
  local HOOK_LABELS=(
    "$STR_HOOKS_TMUX"
    "$STR_HOOKS_GIT_PUSH"
    "$STR_HOOKS_DOC_BLOCK"
    "$STR_HOOKS_PRETTIER"
    "$STR_HOOKS_CONSOLE"
    "$STR_HOOKS_MEMORY"
    "$STR_HOOKS_COMPACT"
    "$STR_HOOKS_PR_LOG"
  )

  section "$STR_HOOKS_TITLE"
  while true; do
    local i
    for i in "${!HOOK_KEYS[@]}"; do
      local key="${HOOK_KEYS[$i]}"
      local state="${!key}"
      local mark="[ ]"
      if [[ "$state" == "true" ]]; then mark="[*]"; fi
      printf "  %2d) %s %s\n" "$((i+1))" "$mark" "${HOOK_LABELS[$i]}"
    done
    printf "\n  %s\n\n" "$STR_TOGGLE_HINT"

    local choice=""
    read -r -p "${STR_CHOICE}: " choice
    if [[ -z "$choice" ]]; then break; fi

    case "$choice" in
      a|A|all)
        for i in "${!HOOK_KEYS[@]}"; do printf -v "${HOOK_KEYS[$i]}" '%s' "true"; done
        ;;
      n|N|none)
        for i in "${!HOOK_KEYS[@]}"; do printf -v "${HOOK_KEYS[$i]}" '%s' "false"; done
        ;;
      *)
        local -a _tokens=()
        read -r -a _tokens <<< "$choice"
        for token in "${_tokens[@]}"; do
          if [[ "$token" =~ ^[0-9]+$ ]] && [[ "$token" -ge 1 ]] && [[ "$token" -le "${#HOOK_KEYS[@]}" ]]; then
            local idx=$((token-1))
            local key="${HOOK_KEYS[$idx]}"
            local current="${!key}"
            if [[ "$current" == "true" ]]; then
              printf -v "$key" '%s' "false"
            else
              printf -v "$key" '%s' "true"
            fi
          fi
        done
        ;;
    esac
    printf "\n"
  done
}

_step_plugins() {
  _load_plugins
  _init_plugins_for_profile "$PROFILE"

  if [[ -n "$SELECTED_PLUGINS" ]]; then
    _apply_plugins_from_csv "$SELECTED_PLUGINS"
  fi

  section "$STR_PLUGINS_TITLE"
  printf "%s\n\n" "$STR_PLUGINS_NOTE"

  while true; do
    local i
    for i in "${!PLUGIN_NAMES[@]}"; do
      local mark="[ ]"
      if [[ "${PLUGIN_SELECTED[$i]}" == "true" ]]; then mark="[*]"; fi
      printf "  %2d) %s %s\n" "$((i+1))" "$mark" "${PLUGIN_NAMES[$i]}"
    done
    printf "\n  %s\n\n" "$STR_TOGGLE_HINT"

    local choice=""
    read -r -p "${STR_CHOICE}: " choice
    if [[ -z "$choice" ]]; then break; fi

    case "$choice" in
      a|A|all)
        for i in "${!PLUGIN_SELECTED[@]}"; do PLUGIN_SELECTED[$i]="true"; done
        ;;
      n|N|none)
        for i in "${!PLUGIN_SELECTED[@]}"; do PLUGIN_SELECTED[$i]="false"; done
        ;;
      *)
        local -a _tokens=()
        read -r -a _tokens <<< "$choice"
        for token in "${_tokens[@]}"; do
          if [[ "$token" =~ ^[0-9]+$ ]] && [[ "$token" -ge 1 ]] && [[ "$token" -le "${#PLUGIN_NAMES[@]}" ]]; then
            local idx=$((token-1))
            if [[ "${PLUGIN_SELECTED[$idx]}" == "true" ]]; then
              PLUGIN_SELECTED[$idx]="false"
            else
              PLUGIN_SELECTED[$idx]="true"
            fi
          fi
        done
        ;;
    esac
    printf "\n"
  done

  _compute_selected_plugins
}

_step_commit() {
  if [[ -n "$COMMIT_ATTRIBUTION" ]]; then return; fi
  section "$STR_COMMIT_TITLE"
  printf "  1) %s\n" "$STR_COMMIT_YES"
  printf "  2) %s\n" "$STR_COMMIT_NO"
  local choice=""
  read -r -p "${STR_CHOICE}: " choice
  case "$choice" in
    1) COMMIT_ATTRIBUTION="true" ;;
    *) COMMIT_ATTRIBUTION="false" ;;
  esac
}

_step_confirm() {
  local HOOK_LABELS=(
    "$STR_HOOKS_TMUX"
    "$STR_HOOKS_GIT_PUSH"
    "$STR_HOOKS_DOC_BLOCK"
    "$STR_HOOKS_PRETTIER"
    "$STR_HOOKS_CONSOLE"
    "$STR_HOOKS_MEMORY"
    "$STR_HOOKS_COMPACT"
    "$STR_HOOKS_PR_LOG"
  )

  section "$STR_CONFIRM_TITLE"
  printf "%-20s : %s\n" "$STR_CONFIRM_LANGUAGE" "$(_language_label "$LANGUAGE")"
  printf "%-20s : %s\n" "$STR_CONFIRM_PROFILE" "$(_profile_label "$PROFILE")"
  printf "%-20s : %s\n" "$STR_CONFIRM_CODEX" "$(_bool_label_enabled "$ENABLE_CODEX_MCP")"
  printf "%-20s : %s\n" "$STR_CONFIRM_EDITOR" "$(_editor_label "$EDITOR_CHOICE")"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    printf "%-20s : %s\n" "$STR_CONFIRM_GHOSTTY" "$(_bool_label_enabled "$ENABLE_GHOSTTY_SETUP")"
  fi
  printf "%-20s : %s\n" "$STR_CONFIRM_FONTS" "$(_bool_label_enabled "$ENABLE_FONTS_SETUP")"

  # Hooks summary
  local hook_labels=()
  local i
  for i in "${!HOOK_KEYS[@]}"; do
    local key="${HOOK_KEYS[$i]}"
    local state="${!key}"
    if [[ "$state" == "true" ]]; then
      hook_labels+=("${HOOK_LABELS[$i]}")
    fi
  done
  if [[ "${#hook_labels[@]}" -eq 0 ]]; then
    printf "%-20s : %s\n" "$STR_CONFIRM_HOOKS" "$STR_NONE"
  else
    printf "%-20s : %d %s\n" "$STR_CONFIRM_HOOKS" "${#hook_labels[@]}" "$STR_SELECTED"
  fi

  # Plugins summary
  if [[ -z "$SELECTED_PLUGINS" ]]; then
    printf "%-20s : %s\n" "$STR_CONFIRM_PLUGINS" "$STR_NONE"
  else
    local count
    IFS=',' read -r -a _plist <<< "$SELECTED_PLUGINS"
    printf "%-20s : %d %s\n" "$STR_CONFIRM_PLUGINS" "${#_plist[@]}" "$STR_SELECTED"
  fi

  printf "%-20s : %s\n" "$STR_CONFIRM_COMMIT" "$(_bool_label_yesno "$COMMIT_ATTRIBUTION")"

  section "$STR_CONFIRM_DEPLOY"
  printf "  1) %s\n" "$STR_CONFIRM_YES"
  printf "  2) %s\n" "$STR_CONFIRM_EDIT"
  printf "  3) %s\n" "$STR_CONFIRM_SAVE"
  printf "  4) %s\n" "$STR_CONFIRM_CANCEL"

  local choice=""
  read -r -p "${STR_CHOICE}: " choice
  case "$choice" in
    1) WIZARD_RESULT="deploy" ;;
    2) WIZARD_RESULT="edit" ;;
    3) WIZARD_RESULT="save" ;;
    *) WIZARD_RESULT="cancel" ;;
  esac
}

# ---------------------------------------------------------------------------
# Non-interactive mode: fill in missing values with profile defaults
# ---------------------------------------------------------------------------
_fill_noninteractive_defaults() {
  [[ -z "$LANGUAGE" ]] && LANGUAGE="en"
  [[ -z "$PROFILE" ]] && PROFILE="standard"

  # Save CLI-overridden values before loading profile/config
  # (both load_config and load_profile_config unconditionally set ENABLE_* flags)
  local _saved_overrides=()
  local _var _val
  for _var in "${_CLI_OVERRIDES[@]+"${_CLI_OVERRIDES[@]}"}"; do
    _val="${!_var:-}"
    if [[ -n "$_val" ]]; then
      _saved_overrides+=("${_var}=${_val}")
    fi
  done

  load_profile_config "$PROFILE"

  # Restore CLI-overridden values (CLI takes precedence over profile/config)
  local _pair _restore_key _restore_val
  for _pair in "${_saved_overrides[@]+"${_saved_overrides[@]}"}"; do
    if [[ -n "$_pair" ]]; then
      _restore_key="${_pair%%=*}"
      _restore_val="${_pair#*=}"
      printf -v "$_restore_key" '%s' "$_restore_val"
    fi
  done

  [[ -z "$EDITOR_CHOICE" ]] && EDITOR_CHOICE="none"
  [[ -z "$COMMIT_ATTRIBUTION" ]] && COMMIT_ATTRIBUTION="false"
  [[ -z "$ENABLE_GHOSTTY_SETUP" ]] && ENABLE_GHOSTTY_SETUP="false"
  [[ -z "$ENABLE_FONTS_SETUP" ]] && ENABLE_FONTS_SETUP="false"

  # Force-disable Ghostty on non-macOS platforms
  if [[ "$(uname -s)" != "Darwin" ]]; then
    ENABLE_GHOSTTY_SETUP="false"
  fi

  # Compute plugins if not already set
  if [[ -z "$SELECTED_PLUGINS" ]]; then
    _load_plugins
    _init_plugins_for_profile "$PROFILE"
    _compute_selected_plugins
  fi

  WIZARD_RESULT="deploy"
}

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

  # Save CLI-overridden values before loading config file
  local _saved_cli=()
  local _v _vl
  for _v in "${_CLI_OVERRIDES[@]+"${_CLI_OVERRIDES[@]}"}"; do
    _vl="${!_v:-}"
    if [[ -n "$_vl" ]]; then
      _saved_cli+=("${_v}=${_vl}")
    fi
  done

  # Load previous config if available
  load_config "${WIZARD_CONFIG_FILE:-$HOME/.claude-starter-kit.conf}"

  # Restore CLI-overridden values (CLI takes precedence over saved config)
  local _p _rk _rv
  for _p in "${_saved_cli[@]+"${_saved_cli[@]}"}"; do
    if [[ -n "$_p" ]]; then
      _rk="${_p%%=*}"
      _rv="${_p#*=}"
      printf -v "$_rk" '%s' "$_rv"
    fi
  done

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
      # Show confirm with saved settings
      _step_confirm
      if [[ "$WIZARD_RESULT" != "edit" ]]; then
        return
      fi
      # User chose to edit - fall through to full wizard
    fi
    # Reset for fresh start (all user choices cleared so wizard asks again)
    LANGUAGE=""
    PROFILE=""
    EDITOR_CHOICE=""
    COMMIT_ATTRIBUTION=""
    ENABLE_CODEX_MCP=""
    ENABLE_GHOSTTY_SETUP=""
    ENABLE_FONTS_SETUP=""
  fi

  # Interactive wizard loop
  while true; do
    _step_language
    load_strings "$LANGUAGE"

    printf "\n"
    _print_banner "$STR_BANNER" "$STR_BANNER_SUB"

    _step_profile
    _step_codex
    _step_editor
    _step_ghostty
    _step_fonts
    _step_hooks
    _step_plugins
    _step_commit
    _step_confirm

    if [[ "$WIZARD_RESULT" == "edit" ]]; then
      # Reset for re-run (all user choices cleared so wizard asks again)
      LANGUAGE=""
      PROFILE=""
      EDITOR_CHOICE=""
      COMMIT_ATTRIBUTION=""
      ENABLE_CODEX_MCP=""
      ENABLE_GHOSTTY_SETUP=""
      ENABLE_FONTS_SETUP=""
      continue
    fi
    break
  done
}
