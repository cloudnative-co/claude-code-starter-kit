#!/bin/bash
# wizard/steps.sh - Display helpers and interactive wizard steps.
# Sourced by wizard.sh.
# shellcheck disable=SC2034 # This module sets globals consumed after sourcing.

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
    local _saved_overrides=()
    local _override
    while IFS= read -r _override; do
      [[ -n "$_override" ]] && _saved_overrides+=("$_override")
    done < <(_capture_cli_overrides)
    load_profile_config "$PROFILE"
    _restore_cli_overrides "${_saved_overrides[@]+"${_saved_overrides[@]}"}"
    return
  fi
  section "$STR_PROFILE_TITLE"
  printf "  1) %s\n" "$STR_PROFILE_MINIMAL"
  printf "  2) %s (%s)\n" "$STR_PROFILE_STANDARD" "$STR_RECOMMENDED"
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

_prompt_yes_no() {
  local _var="$1"
  local _default="${2:-2}"
  local choice=""
  read -r -p "${STR_CHOICE} [${_default}]: " choice
  [[ -z "$choice" ]] && choice="$_default"
  case "$choice" in
    1) printf -v "$_var" '%s' "true" ;;
    *) printf -v "$_var" '%s' "false" ;;
  esac
}

_step_codex() {
  local _ov; for _ov in "${_CLI_OVERRIDES[@]+"${_CLI_OVERRIDES[@]}"}"; do [[ "$_ov" == "ENABLE_CODEX_PLUGIN" ]] && return; done

  section "$STR_CODEX_TITLE"
  printf "  1) %s\n" "$STR_CODEX_YES"
  printf "  2) %s\n" "$STR_CODEX_NO"
  local _default="2"
  if [[ "${ENABLE_CODEX_PLUGIN:-}" == "true" ]]; then _default="1"; fi
  _prompt_yes_no ENABLE_CODEX_PLUGIN "$_default"
}

_step_new_init() {
  local _ov; for _ov in "${_CLI_OVERRIDES[@]+"${_CLI_OVERRIDES[@]}"}"; do [[ "$_ov" == "ENABLE_NEW_INIT" ]] && return; done
  if [[ "$PROFILE" != "custom" ]]; then return; fi

  section "$STR_NEW_INIT_TITLE"
  printf "  %s\n\n" "$STR_NEW_INIT_DESC"
  printf "  1) %s\n" "$STR_NEW_INIT_YES"
  printf "  2) %s\n" "$STR_NEW_INIT_NO"
  local _default="2"
  if [[ "${ENABLE_NEW_INIT:-false}" == "true" ]]; then _default="1"; fi
  _prompt_yes_no ENABLE_NEW_INIT "$_default"
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
  if [[ "$(uname -s)" != "Darwin" ]]; then ENABLE_GHOSTTY_SETUP="false"; return; fi
  local _ov; for _ov in "${_CLI_OVERRIDES[@]+"${_CLI_OVERRIDES[@]}"}"; do [[ "$_ov" == "ENABLE_GHOSTTY_SETUP" ]] && return; done
  if [[ "$PROFILE" != "custom" ]]; then return; fi

  section "$STR_GHOSTTY_TITLE"
  printf "  %s\n\n" "$STR_GHOSTTY_DESC"
  printf "  1) %s\n" "$STR_GHOSTTY_YES"
  printf "  2) %s\n" "$STR_GHOSTTY_NO"
  _prompt_yes_no ENABLE_GHOSTTY_SETUP "2"
}

_step_fonts() {
  local _ov; for _ov in "${_CLI_OVERRIDES[@]+"${_CLI_OVERRIDES[@]}"}"; do [[ "$_ov" == "ENABLE_FONTS_SETUP" ]] && return; done
  if [[ "$PROFILE" != "custom" ]]; then return; fi

  section "$STR_FONTS_TITLE"
  printf "  %s\n\n" "$STR_FONTS_DESC"
  printf "  1) %s\n" "$STR_FONTS_YES"
  printf "  2) %s\n" "$STR_FONTS_NO"
  _prompt_yes_no ENABLE_FONTS_SETUP "2"
}

_step_hooks() {
  _init_hook_labels

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
              case "$key" in
                ENABLE_PRETTIER_HOOKS) ENABLE_BIOME_HOOKS="false" ;;
                ENABLE_BIOME_HOOKS) ENABLE_PRETTIER_HOOKS="false" ;;
              esac
            fi
          fi
        done
        ;;
    esac
    _normalize_formatter_hooks
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
    local i _display_name
    for i in "${!PLUGIN_NAMES[@]}"; do
      local mark="[ ]"
      if [[ "${PLUGIN_SELECTED[$i]}" == "true" ]]; then mark="[*]"; fi
      _display_name="${PLUGIN_NAMES[$i]}"
      if _plugin_has_collision "${PLUGIN_NAMES[$i]}"; then
        _display_name="${PLUGIN_NAMES[$i]} [${PLUGIN_MARKETPLACES[$i]}]"
      fi
      printf "  %2d) %s %s\n" "$((i+1))" "$mark" "$_display_name"
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
  _init_hook_labels

  section "$STR_CONFIRM_TITLE"
  printf "%-20s : %s\n" "$STR_CONFIRM_LANGUAGE" "$(_language_label "$LANGUAGE")"
  printf "%-20s : %s\n" "$STR_CONFIRM_PROFILE" "$(_profile_label "$PROFILE")"
  printf "%-20s : %s\n" "$STR_CONFIRM_CODEX" "$(_bool_label_enabled "$ENABLE_CODEX_PLUGIN")"
  printf "%-20s : %s\n" "$STR_CONFIRM_NEW_INIT" "$(_bool_label_enabled "$ENABLE_NEW_INIT")"
  printf "%-20s : %s\n" "$STR_CONFIRM_EDITOR" "$(_editor_label "$EDITOR_CHOICE")"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    printf "%-20s : %s\n" "$STR_CONFIRM_GHOSTTY" "$(_bool_label_enabled "$ENABLE_GHOSTTY_SETUP")"
  fi
  printf "%-20s : %s\n" "$STR_CONFIRM_FONTS" "$(_bool_label_enabled "$ENABLE_FONTS_SETUP")"
  printf "%-20s : %s\n" "$STR_CONFIRM_STATUSLINE" "$(_bool_label_enabled "${ENABLE_STATUSLINE:-false}")"
  printf "%-20s : %s\n" "$STR_CONFIRM_NO_FLICKER" "$(_bool_label_enabled "${ENABLE_NO_FLICKER:-false}")"
  printf "%-20s : %s\n" "$STR_CONFIRM_AGENT_TEAMS" "$(_bool_label_enabled "${ENABLE_AGENT_TEAMS:-false}")"
  printf "%-20s : %s\n" "${STR_CONFIRM_FEATURE_RECOMMENDATION:-Feature Rec.}" "$(_bool_label_enabled "${ENABLE_FEATURE_RECOMMENDATION:-false}")"

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

  if [[ -z "$SELECTED_PLUGINS" ]]; then
    printf "%-20s : %s\n" "$STR_CONFIRM_PLUGINS" "$STR_NONE"
  else
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

_fill_noninteractive_defaults() {
  local _rc=0
  [[ -z "$LANGUAGE" ]] && LANGUAGE="en"
  [[ -z "$PROFILE" ]] && PROFILE="standard"

  local _saved_overrides=()
  while IFS= read -r _override; do
    [[ -n "$_override" ]] && _saved_overrides+=("$_override")
  done < <(_capture_cli_overrides)

  _load_profile_preserving_values "$PROFILE"
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"

  _restore_cli_overrides "${_saved_overrides[@]+"${_saved_overrides[@]}"}"
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"

  [[ -z "$EDITOR_CHOICE" ]] && EDITOR_CHOICE="none"
  [[ -z "$COMMIT_ATTRIBUTION" ]] && COMMIT_ATTRIBUTION="false"
  [[ -z "$ENABLE_NEW_INIT" ]] && ENABLE_NEW_INIT="true"
  [[ -z "${ENABLE_STATUSLINE:-}" ]] && ENABLE_STATUSLINE="true"
  [[ -z "${ENABLE_NO_FLICKER:-}" ]] && ENABLE_NO_FLICKER="false"
  [[ -z "${ENABLE_AGENT_TEAMS:-}" ]] && ENABLE_AGENT_TEAMS="true"
  [[ -z "${ENABLE_FEATURE_RECOMMENDATION:-}" ]] && ENABLE_FEATURE_RECOMMENDATION="false"
  [[ -z "${ENABLE_WEB_CONTENT_UPDATE:-}" ]] && ENABLE_WEB_CONTENT_UPDATE="false"
  [[ -z "$ENABLE_GHOSTTY_SETUP" ]] && ENABLE_GHOSTTY_SETUP="false"
  [[ -z "$ENABLE_FONTS_SETUP" ]] && ENABLE_FONTS_SETUP="false"
  _normalize_formatter_hooks "$_PROFILE_FILL_FORMATTER_PREFER"
  _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"

  if [[ "$(uname -s)" != "Darwin" ]]; then
    ENABLE_GHOSTTY_SETUP="false"
  fi

  if _wizard_mdm_managed; then
    ENABLE_AUTO_UPDATE="false"
    ENABLE_WEB_CONTENT_UPDATE="false"
    ENABLE_CODEX_PLUGIN="false"
    SELECTED_PLUGINS=""
  elif [[ -z "$SELECTED_PLUGINS" ]]; then
    _load_plugins
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
    _init_plugins_for_profile "$PROFILE"
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
    _compute_selected_plugins
    _rc=$?
    [[ "$_rc" -eq 0 ]] || return "$_rc"
  fi

  WIZARD_RESULT="deploy"
}
