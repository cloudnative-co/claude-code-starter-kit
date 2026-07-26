#!/bin/bash
# wizard/registry.sh - Config key/plugin/hook registries and CLI parsing helpers.
# Sourced by wizard.sh.
# shellcheck disable=SC2034 # This module sets globals consumed after sourcing.

# ---------------------------------------------------------------------------
# Config key registry (single source of truth)
# ---------------------------------------------------------------------------
# All wizard config keys in allowlist/save order. Empty string entries mark
# blank-line separators in the saved config file. To add a new key, append it
# here (and initialize the matching global in wizard.sh); the derived lists
# below are generated automatically.
_CONFIG_KEYS=(
  LANGUAGE PROFILE EDITOR_CHOICE COMMIT_ATTRIBUTION ENABLE_NEW_INIT KIT_REPO
  ""
  INSTALL_AGENTS INSTALL_RULES INSTALL_COMMANDS INSTALL_SKILLS INSTALL_MEMORY
  ""
  ENABLE_CODEX_PLUGIN ENABLE_CODEX_MCP ENABLE_TMUX_HOOKS ENABLE_GIT_PUSH_REVIEW
  ENABLE_DOC_BLOCKER ENABLE_PRETTIER_HOOKS ENABLE_BIOME_HOOKS ENABLE_CONSOLE_LOG_GUARD
  ENABLE_MEMORY_PERSISTENCE ENABLE_STRATEGIC_COMPACT ENABLE_PR_CREATION_LOG
  ENABLE_PRE_COMPACT_COMMIT ENABLE_SAFETY_NET ENABLE_AUTO_UPDATE ENABLE_WEB_CONTENT_UPDATE
  ENABLE_STATUSLINE ENABLE_GHOSTTY_SETUP ENABLE_FONTS_SETUP ENABLE_DOC_SIZE_GUARD
  ENABLE_NO_FLICKER ENABLE_FEATURE_RECOMMENDATION ENABLE_AGENT_TEAMS
  ""
  DISMISSED_FEATURES
  ""
  KNOWN_PLUGINS DISMISSED_PLUGINS
  ""
  SELECTED_PLUGINS
)

# Legacy keys: accepted when loading saved config (kept in the allowlist) but
# never written back by save_config (e.g., ENABLE_CODEX_MCP is migrated to
# ENABLE_CODEX_PLUGIN by _normalize_codex_state; INSTALL_MEMORY is retired —
# the kit no longer ships seed memory files).
_CONFIG_LEGACY_KEYS="ENABLE_CODEX_MCP INSTALL_MEMORY ENABLE_MEMORY_PERSISTENCE ENABLE_STRATEGIC_COMPACT ENABLE_CONSOLE_LOG_GUARD ENABLE_GIT_PUSH_REVIEW"

# Generated lists (do not edit by hand — extend _CONFIG_KEYS instead):
#   _CONFIG_ALLOWED_KEYS — space-separated allowlist for _safe_source_config
#   _CONFIG_SAVE_KEYS    — array of keys to save ("" = blank line separator)
_CONFIG_ALLOWED_KEYS=""
_CONFIG_SAVE_KEYS=()
_build_config_key_lists() {
  local _key
  _CONFIG_ALLOWED_KEYS=""
  _CONFIG_SAVE_KEYS=()
  for _key in "${_CONFIG_KEYS[@]}"; do
    if [[ -z "$_key" ]]; then
      _CONFIG_SAVE_KEYS+=("")
      continue
    fi
    _CONFIG_ALLOWED_KEYS="${_CONFIG_ALLOWED_KEYS:+${_CONFIG_ALLOWED_KEYS} }${_key}"
    if [[ " $_CONFIG_LEGACY_KEYS " == *" $_key "* ]]; then
      continue
    fi
    _CONFIG_SAVE_KEYS+=("$_key")
  done
}
_build_config_key_lists

PLUGIN_NAMES=()
PLUGIN_PROFILES=()
PLUGIN_SELECTED=()
PLUGIN_MARKETPLACES=()

_load_plugins() {
  local dir rows file
  PLUGIN_NAMES=()
  PLUGIN_PROFILES=()
  PLUGIN_SELECTED=()
  PLUGIN_MARKETPLACES=()
  dir="$(_project_dir)" || return 1
  file="$dir/config/plugins.json"

  if [[ ! -f "$file" ]] || ! command -v jq &>/dev/null; then
    return 1
  fi

  # Validate the complete catalog before exposing any entry. Reading jq
  # directly through process substitution would hide its exit status and could
  # leave a partial allowlist when a later catalog row is malformed.
  if ! rows="$(jq -rs '
    if length == 1 then .[0] else error("invalid plugin catalog document") end
    | . as $catalog
    | if (
        (type == "object")
        and ((.marketplaces | type) == "object")
        and all(.marketplaces | to_entries[];
          (.key | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
          and ((.value | type) == "string")
          and ((.value | length) > 0))
        and ((.plugins | type) == "array")
        and all(.plugins[];
          (type == "object")
          and ((.name | type) == "string")
          and (.name | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
          and ((.description | type) == "string")
          and ((.profiles | type) == "array")
          and all(.profiles[];
            (type == "string")
            and test("^(minimal|standard|full)$"))
          and ((if has("marketplace") then .marketplace
                else "claude-plugins-official" end) as $marketplace
            | (($marketplace | type) == "string")
            and ($marketplace | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
            and ($catalog.marketplaces | has($marketplace))))
      ) then
        .plugins[]
        | [
            .name,
            (.profiles | join(",")),
            (if has("marketplace") then .marketplace
             else "claude-plugins-official" end)
          ]
        | join("\u001f")
      else
        error("invalid plugin catalog")
      end
  ' "$file" 2>/dev/null)"; then
    return 1
  fi

  local name profiles_csv marketplace
  # Unit separator is non-whitespace IFS, so an intentionally empty profiles
  # array retains its empty middle field rather than shifting the marketplace.
  while IFS=$'\x1f' read -r name profiles_csv marketplace; do
    [[ -n "$name" ]] || continue
    PLUGIN_NAMES+=("$name")
    PLUGIN_PROFILES+=("$profiles_csv")
    PLUGIN_SELECTED+=("false")
    PLUGIN_MARKETPLACES+=("${marketplace:-claude-plugins-official}")
  done < <(if [[ -n "$rows" ]]; then printf '%s\n' "$rows"; fi)
}

_plugin_has_collision() {
  local target="$1" i
  local seen_mp=""
  for i in "${!PLUGIN_NAMES[@]}"; do
    if [[ "${PLUGIN_NAMES[$i]}" == "$target" ]]; then
      if [[ -n "$seen_mp" ]] && [[ "$seen_mp" != "${PLUGIN_MARKETPLACES[$i]}" ]]; then
        return 0
      fi
      seen_mp="${PLUGIN_MARKETPLACES[$i]}"
    fi
  done
  return 1
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

  IFS=',' read -r -a _wanted < <(printf '%s\n' "$csv")
  local w _w_name _w_mp
  for i in "${!PLUGIN_NAMES[@]}"; do
    for w in "${_wanted[@]}"; do
      if [[ "$w" == *"@"* ]]; then
        _w_name="${w%%@*}"
        _w_mp="${w#*@}"
        if [[ "$_w_name" == "${PLUGIN_NAMES[$i]}" ]] && [[ "$_w_mp" == "${PLUGIN_MARKETPLACES[$i]}" ]]; then
          PLUGIN_SELECTED[$i]="true"
        fi
      elif _plugin_has_collision "$w"; then
        if [[ "$w" == "${PLUGIN_NAMES[$i]}" ]] && [[ "${PLUGIN_MARKETPLACES[$i]}" == "claude-plugins-official" ]]; then
          PLUGIN_SELECTED[$i]="true"
        fi
      elif [[ "$w" == "${PLUGIN_NAMES[$i]}" ]]; then
        PLUGIN_SELECTED[$i]="true"
      fi
    done
  done
}

_compute_selected_plugins() {
  local out=()
  local i entry
  for i in "${!PLUGIN_NAMES[@]}"; do
    if [[ "${PLUGIN_SELECTED[$i]}" == "true" ]]; then
      entry="${PLUGIN_NAMES[$i]}"
      if _plugin_has_collision "${PLUGIN_NAMES[$i]}" \
         || [[ "${PLUGIN_MARKETPLACES[$i]}" != "claude-plugins-official" ]]; then
        entry="${PLUGIN_NAMES[$i]}@${PLUGIN_MARKETPLACES[$i]}"
      fi
      out+=("$entry")
    fi
  done
  if [[ "${#out[@]}" -eq 0 ]]; then
    SELECTED_PLUGINS=""
  else
    local IFS=,
    SELECTED_PLUGINS="${out[*]}"
  fi
}

# Re-resolve a persisted selection against the current catalog. This upgrades
# legacy bare official entries to name@claude-plugins-official when a later
# catalog adds a same-named plugin in another marketplace. Unknown entries are
# dropped rather than handed to the external plugin installer.
_normalize_selected_plugins_for_catalog() {
  local csv="${SELECTED_PLUGINS:-}"
  _load_plugins || return 1
  _apply_plugins_from_csv "$csv"
  _compute_selected_plugins
}

HOOK_KEYS=(
  "ENABLE_SAFETY_NET"
  "ENABLE_AUTO_UPDATE"
  "ENABLE_WEB_CONTENT_UPDATE"
  "ENABLE_TMUX_HOOKS"
  "ENABLE_DOC_BLOCKER"
  "ENABLE_PRETTIER_HOOKS"
  "ENABLE_BIOME_HOOKS"
  "ENABLE_PR_CREATION_LOG"
  "ENABLE_PRE_COMPACT_COMMIT"
  "ENABLE_DOC_SIZE_GUARD"
  "ENABLE_FEATURE_RECOMMENDATION"
  "ENABLE_AGENT_TEAMS"
)

HOOK_TOKENS=(
  "safety-net"
  "auto-update"
  "web-content"
  "tmux"
  "doc-block"
  "prettier"
  "biome"
  "pr-log"
  "pre-commit"
  "doc-size"
  "feature-rec"
  "agent-teams"
)

HOOK_LABELS=()
_init_hook_labels() {
  [[ ${#HOOK_LABELS[@]} -gt 0 ]] && return
  HOOK_LABELS=(
    "${STR_HOOKS_SAFETY_NET:-Safety Net - Helps prevent accidental destructive git/filesystem commands}"
    "${STR_HOOKS_AUTO_UPDATE:-Auto Update - Automatically update starter kit on session start}"
    "${STR_HOOKS_WEB_CONTENT_UPDATE:-Web Content Update - Auto-update web-content-extraction skill deps on session start}"
    "$STR_HOOKS_TMUX"
    "$STR_HOOKS_DOC_BLOCK"
    "$STR_HOOKS_PRETTIER"
    "${STR_HOOKS_BIOME:-Biome Auto-format - Format and lint JS/TS files after edits}"
    "$STR_HOOKS_PR_LOG"
    "${STR_HOOKS_PRE_COMMIT:-Pre-compact Snapshot}"
    "${STR_HOOKS_DOC_SIZE:-Doc Size Guard - Warn when CLAUDE.md/AGENTS.md is too large}"
    "${STR_HOOKS_FEATURE_RECOMMENDATION:-Feature Recommendation - Notify about new features on session start}"
    "${STR_HOOKS_AGENT_TEAMS:-Agent Teams (experimental) - Enable Claude Code agent teams}"
  )
}

_apply_hooks_csv() {
  local csv="$1"
  local i
  for i in "${!HOOK_KEYS[@]}"; do
    printf -v "${HOOK_KEYS[$i]}" '%s' "false"
  done

  IFS=',' read -r -a _items < <(printf '%s\n' "$csv")
  local item
  for item in "${_items[@]}"; do
    item="$(printf '%s' "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    for i in "${!HOOK_TOKENS[@]}"; do
      if [[ "$item" == "${HOOK_TOKENS[$i]}" ]]; then
        printf -v "${HOOK_KEYS[$i]}" '%s' "true"
        break
      fi
    done
  done
  _normalize_formatter_hooks "biome"
}

_register_hooks_cli_overrides() {
  local key
  for key in "${HOOK_KEYS[@]}"; do
    _CLI_OVERRIDES+=("$key")
  done
}

parse_cli_args() {
  local arg plugins_arg
  while [[ "$#" -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --non-interactive)
        WIZARD_NONINTERACTIVE="true"
        _MERGE_INTERACTIVE="false"
        ;;
      --update)
        UPDATE_MODE="true"
        WIZARD_NONINTERACTIVE="true"
        ;;
      --reset-prefs)
        _RESET_MERGE_PREFS="true"
        ;;
      --dry-run)
        DRY_RUN="true"
        ;;
      --language=*)      LANGUAGE="${arg#*=}"; _CLI_OVERRIDES+=("LANGUAGE") ;;
      --language)        shift; LANGUAGE="${1:-}"; _CLI_OVERRIDES+=("LANGUAGE") ;;
      --profile=*)       PROFILE="${arg#*=}"; _CLI_OVERRIDES+=("PROFILE") ;;
      --profile)         shift; PROFILE="${1:-}"; _CLI_OVERRIDES+=("PROFILE") ;;
      --editor=*)        EDITOR_CHOICE="${arg#*=}"; _CLI_OVERRIDES+=("EDITOR_CHOICE") ;;
      --editor)          shift; EDITOR_CHOICE="${1:-}"; _CLI_OVERRIDES+=("EDITOR_CHOICE") ;;
      --new-init=*)      _set_bool ENABLE_NEW_INIT "${arg#*=}"; _CLI_OVERRIDES+=("ENABLE_NEW_INIT") ;;
      --new-init)        shift; _set_bool ENABLE_NEW_INIT "${1:-}"; _CLI_OVERRIDES+=("ENABLE_NEW_INIT") ;;
      --codex-plugin=*)  _set_bool ENABLE_CODEX_PLUGIN "${arg#*=}"; _CLI_OVERRIDES+=("ENABLE_CODEX_PLUGIN") ;;
      --codex-plugin)    shift; _set_bool ENABLE_CODEX_PLUGIN "${1:-}"; _CLI_OVERRIDES+=("ENABLE_CODEX_PLUGIN") ;;
      --codex-mcp=*)     _set_bool ENABLE_CODEX_PLUGIN "${arg#*=}"; _CLI_OVERRIDES+=("ENABLE_CODEX_PLUGIN") ;;
      --codex-mcp)       shift; _set_bool ENABLE_CODEX_PLUGIN "${1:-}"; _CLI_OVERRIDES+=("ENABLE_CODEX_PLUGIN") ;;
      --commit-attribution=*) _set_bool COMMIT_ATTRIBUTION "${arg#*=}"; _CLI_OVERRIDES+=("COMMIT_ATTRIBUTION") ;;
      --commit-attribution)   shift; _set_bool COMMIT_ATTRIBUTION "${1:-}"; _CLI_OVERRIDES+=("COMMIT_ATTRIBUTION") ;;
      --ghostty=*)     _set_bool ENABLE_GHOSTTY_SETUP "${arg#*=}"; _CLI_OVERRIDES+=("ENABLE_GHOSTTY_SETUP") ;;
      --ghostty)       shift; _set_bool ENABLE_GHOSTTY_SETUP "${1:-}"; _CLI_OVERRIDES+=("ENABLE_GHOSTTY_SETUP") ;;
      --fonts=*)       _set_bool ENABLE_FONTS_SETUP "${arg#*=}"; _CLI_OVERRIDES+=("ENABLE_FONTS_SETUP") ;;
      --fonts)         shift; _set_bool ENABLE_FONTS_SETUP "${1:-}"; _CLI_OVERRIDES+=("ENABLE_FONTS_SETUP") ;;
      --hooks=*)
        _apply_hooks_csv "${arg#*=}"
        _register_hooks_cli_overrides
        ;;
      --plugins=*)
        # Capture raw input during the Bash 3.2-compatible bootstrap. Catalog
        # resolution needs jq and therefore runs only after prerequisites.
        plugins_arg="${arg#*=}"
        if [[ "$plugins_arg" =~ ^[a-zA-Z0-9,@._-]*$ ]]; then
          SELECTED_PLUGINS="$plugins_arg"
        else
          # Fail closed before the newline-based override transport sees it.
          SELECTED_PLUGINS=""
        fi
        _SELECTED_PLUGINS_EXPLICIT="true"
        _CLI_OVERRIDES+=("SELECTED_PLUGINS")
        ;;
      --config=*)
        WIZARD_CONFIG_FILE="${arg#*=}"
        _load_config_preserving_cli_overrides "$WIZARD_CONFIG_FILE"
        ;;
      --config)
        shift
        WIZARD_CONFIG_FILE="${1:-}"
        _load_config_preserving_cli_overrides "$WIZARD_CONFIG_FILE"
        ;;
    esac
    shift
  done
}
