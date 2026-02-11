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

SELECTED_PLUGINS="${SELECTED_PLUGINS:-}"
WIZARD_RESULT="${WIZARD_RESULT:-}"

WIZARD_NONINTERACTIVE="${WIZARD_NONINTERACTIVE:-false}"
WIZARD_CONFIG_FILE=""

# Track CLI-overridden variables (restored after load_config/profile)
_CLI_OVERRIDES=""

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
  eval "$var=\"\$(_bool_normalize \"$val\")\""
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
load_defaults() {
  local dir
  dir="$(_wizard_dir)"
  if [[ -f "$dir/defaults.conf" ]]; then
    # shellcheck source=/dev/null
    . "$dir/defaults.conf"
  fi
}

load_profile_config() {
  local profile="$1"
  local dir
  dir="$(_project_dir)"
  if [[ -f "$dir/profiles/${profile}.conf" ]]; then
    # shellcheck source=/dev/null
    . "$dir/profiles/${profile}.conf"
  fi
}

load_config() {
  local file="${1:-$HOME/.claude-starter-kit.conf}"
  if [[ -f "$file" ]]; then
    # shellcheck source=/dev/null
    . "$file"
  fi
}

save_config() {
  local file="${1:-$HOME/.claude-starter-kit.conf}"
  cat > "$file" <<EOF
# Claude Code Starter Kit - Wizard Config
LANGUAGE="${LANGUAGE}"
PROFILE="${PROFILE}"
EDITOR_CHOICE="${EDITOR_CHOICE}"
COMMIT_ATTRIBUTION="${COMMIT_ATTRIBUTION}"

INSTALL_AGENTS="${INSTALL_AGENTS}"
INSTALL_RULES="${INSTALL_RULES}"
INSTALL_COMMANDS="${INSTALL_COMMANDS}"
INSTALL_SKILLS="${INSTALL_SKILLS}"
INSTALL_MEMORY="${INSTALL_MEMORY}"

ENABLE_CODEX_MCP="${ENABLE_CODEX_MCP}"
ENABLE_TMUX_HOOKS="${ENABLE_TMUX_HOOKS}"
ENABLE_GIT_PUSH_REVIEW="${ENABLE_GIT_PUSH_REVIEW}"
ENABLE_DOC_BLOCKER="${ENABLE_DOC_BLOCKER}"
ENABLE_PRETTIER_HOOKS="${ENABLE_PRETTIER_HOOKS}"
ENABLE_CONSOLE_LOG_GUARD="${ENABLE_CONSOLE_LOG_GUARD}"
ENABLE_MEMORY_PERSISTENCE="${ENABLE_MEMORY_PERSISTENCE}"
ENABLE_STRATEGIC_COMPACT="${ENABLE_STRATEGIC_COMPACT}"
ENABLE_PR_CREATION_LOG="${ENABLE_PR_CREATION_LOG}"
ENABLE_GHOSTTY_SETUP="${ENABLE_GHOSTTY_SETUP}"

SELECTED_PLUGINS="${SELECTED_PLUGINS}"
EOF
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
    eval "${HOOK_KEYS[$i]}=\"false\""
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
      --language=*)      LANGUAGE="${arg#*=}"; _CLI_OVERRIDES="${_CLI_OVERRIDES} LANGUAGE" ;;
      --language)        shift; LANGUAGE="${1:-}"; _CLI_OVERRIDES="${_CLI_OVERRIDES} LANGUAGE" ;;
      --profile=*)       PROFILE="${arg#*=}"; _CLI_OVERRIDES="${_CLI_OVERRIDES} PROFILE" ;;
      --profile)         shift; PROFILE="${1:-}"; _CLI_OVERRIDES="${_CLI_OVERRIDES} PROFILE" ;;
      --editor=*)        EDITOR_CHOICE="${arg#*=}"; _CLI_OVERRIDES="${_CLI_OVERRIDES} EDITOR_CHOICE" ;;
      --editor)          shift; EDITOR_CHOICE="${1:-}"; _CLI_OVERRIDES="${_CLI_OVERRIDES} EDITOR_CHOICE" ;;
      --codex-mcp=*)     _set_bool ENABLE_CODEX_MCP "${arg#*=}"; _CLI_OVERRIDES="${_CLI_OVERRIDES} ENABLE_CODEX_MCP" ;;
      --codex-mcp)       shift; _set_bool ENABLE_CODEX_MCP "${1:-}"; _CLI_OVERRIDES="${_CLI_OVERRIDES} ENABLE_CODEX_MCP" ;;
      --commit-attribution=*) _set_bool COMMIT_ATTRIBUTION "${arg#*=}"; _CLI_OVERRIDES="${_CLI_OVERRIDES} COMMIT_ATTRIBUTION" ;;
      --commit-attribution)   shift; _set_bool COMMIT_ATTRIBUTION "${1:-}"; _CLI_OVERRIDES="${_CLI_OVERRIDES} COMMIT_ATTRIBUTION" ;;
      --ghostty=*)     _set_bool ENABLE_GHOSTTY_SETUP "${arg#*=}"; _CLI_OVERRIDES="${_CLI_OVERRIDES} ENABLE_GHOSTTY_SETUP" ;;
      --ghostty)       shift; _set_bool ENABLE_GHOSTTY_SETUP "${1:-}"; _CLI_OVERRIDES="${_CLI_OVERRIDES} ENABLE_GHOSTTY_SETUP" ;;
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
  printf "  3) %s\n" "$STR_PROFILE_FULL"
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
  if [[ "$_CLI_OVERRIDES" == *"ENABLE_CODEX_MCP"* ]]; then return; fi
  # Only ask for custom profile; other profiles use their preset value
  if [[ "$PROFILE" != "custom" ]]; then return; fi

  section "$STR_CODEX_TITLE"
  printf "  1) %s\n" "$STR_CODEX_YES"
  printf "  2) %s\n" "$STR_CODEX_NO"
  local choice=""
  read -r -p "${STR_CHOICE}: " choice
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
  # Skip on WSL and MSYS/Git Bash — Ghostty not supported on Windows
  # This MUST come first to override profile presets (e.g. full.conf sets ENABLE_GHOSTTY_SETUP=true)
  if is_wsl || is_msys; then ENABLE_GHOSTTY_SETUP="false"; return; fi
  # Skip if explicitly set by CLI arg
  if [[ "$_CLI_OVERRIDES" == *"ENABLE_GHOSTTY_SETUP"* ]]; then return; fi
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
      local state=""
      eval "state=\${$key}"
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
        for i in "${!HOOK_KEYS[@]}"; do eval "${HOOK_KEYS[$i]}=\"true\""; done
        ;;
      n|N|none)
        for i in "${!HOOK_KEYS[@]}"; do eval "${HOOK_KEYS[$i]}=\"false\""; done
        ;;
      *)
        for token in $choice; do
          if [[ "$token" =~ ^[0-9]+$ ]] && [[ "$token" -ge 1 ]] && [[ "$token" -le "${#HOOK_KEYS[@]}" ]]; then
            local idx=$((token-1))
            local key="${HOOK_KEYS[$idx]}"
            local current=""
            eval "current=\${$key}"
            if [[ "$current" == "true" ]]; then
              eval "$key=\"false\""
            else
              eval "$key=\"true\""
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
        for token in $choice; do
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
  if ! is_wsl && ! is_msys; then
    printf "%-20s : %s\n" "$STR_CONFIRM_GHOSTTY" "$(_bool_label_enabled "$ENABLE_GHOSTTY_SETUP")"
  fi

  # Hooks summary
  local hook_labels=()
  local i
  for i in "${!HOOK_KEYS[@]}"; do
    local key="${HOOK_KEYS[$i]}"
    local state=""
    eval "state=\${$key}"
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
  for _var in $_CLI_OVERRIDES; do
    eval "_val=\${$_var:-}"
    if [[ -n "$_val" ]]; then
      _saved_overrides+=("${_var}=${_val}")
    fi
  done

  load_profile_config "$PROFILE"

  # Restore CLI-overridden values (CLI takes precedence over profile/config)
  local _pair
  for _pair in "${_saved_overrides[@]+"${_saved_overrides[@]}"}"; do
    [[ -n "$_pair" ]] && eval "$_pair"
  done

  [[ -z "$EDITOR_CHOICE" ]] && EDITOR_CHOICE="none"
  [[ -z "$COMMIT_ATTRIBUTION" ]] && COMMIT_ATTRIBUTION="false"
  [[ -z "$ENABLE_GHOSTTY_SETUP" ]] && ENABLE_GHOSTTY_SETUP="false"

  # Force-disable Ghostty on Windows (WSL and MSYS) regardless of profile
  if is_wsl || is_msys; then
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
  for _v in $_CLI_OVERRIDES; do
    eval "_vl=\${$_v:-}"
    if [[ -n "$_vl" ]]; then
      _saved_cli+=("${_v}=${_vl}")
    fi
  done

  # Load previous config if available
  load_config "${WIZARD_CONFIG_FILE:-$HOME/.claude-starter-kit.conf}"

  # Restore CLI-overridden values (CLI takes precedence over saved config)
  local _p
  for _p in "${_saved_cli[@]+"${_saved_cli[@]}"}"; do
    [[ -n "$_p" ]] && eval "$_p"
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
    # Reset for fresh start
    LANGUAGE=""
    PROFILE=""
    EDITOR_CHOICE=""
    COMMIT_ATTRIBUTION=""
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
    _step_hooks
    _step_plugins
    _step_commit
    _step_confirm

    if [[ "$WIZARD_RESULT" == "edit" ]]; then
      # Reset for re-run
      LANGUAGE=""
      PROFILE=""
      EDITOR_CHOICE=""
      COMMIT_ATTRIBUTION=""
      continue
    fi
    break
  done
}
