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
. "$PROJECT_DIR/lib/snapshot.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/merge.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/update.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/dryrun.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/ghostty.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/fonts.sh"

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

_bool_to_string() {
  if is_true "${1:-false}"; then
    printf "true"
  else
    printf "false"
  fi
}

apply_settings_preferences() {
  local file="$1"
  local lang_name tmp_file attribution_enabled
  lang_name="$(language_name)"
  if is_true "${COMMIT_ATTRIBUTION:-false}"; then
    attribution_enabled="true"
  else
    attribution_enabled="false"
  fi

  tmp_file="$(mktemp)"
  _SETUP_TMP_FILES+=("$tmp_file")

  jq \
    --arg lang "$lang_name" \
    --arg new_init "$(_bool_to_string "${ENABLE_NEW_INIT:-false}")" \
    --argjson attribution_enabled "$attribution_enabled" \
    '.language = $lang
    | .env.CLAUDE_CODE_NEW_INIT = $new_init
    | if $attribution_enabled then del(.attribution) else .attribution = {commit: "", pr: ""} end' \
    "$file" > "$tmp_file"

  mv "$tmp_file" "$file"
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
  # Dry-run: no real backup needed (sim dir protects the real filesystem)
  [[ "${DRY_RUN:-false}" == "true" ]] && return 0

  if [[ -e "$CLAUDE_DIR" ]]; then
    local ts backup
    ts="$(date +%Y%m%d%H%M%S)"
    backup="$HOME/.claude.backup.${ts}"
    cp -a "$CLAUDE_DIR" "$backup"
    ok "Backed up existing ~/.claude to $backup"
  fi
}

_MANAGED_TARGET_FILES=()

_add_managed_tree_targets() {
  local src_root="$1"
  local dest_root="$2"
  [[ -d "$src_root" ]] || return 0

  local src_file rel_path
  while IFS= read -r -d '' src_file; do
    rel_path="${src_file#"$src_root"/}"
    _MANAGED_TARGET_FILES+=("${dest_root}/${rel_path}")
  done < <(find "$src_root" -type f -print0 2>/dev/null)
}

# Files preserved (skipped) during fresh install with existing user data.
# These must NOT appear in manifest or snapshot — they are user-owned.
_FRESH_SKIPPED_FILES=()

_is_fresh_skipped() {
  local path="$1"
  local skipped
  for skipped in "${_FRESH_SKIPPED_FILES[@]+"${_FRESH_SKIPPED_FILES[@]}"}"; do
    # Match exact file or prefix (for directory-level skips)
    if [[ "$path" == "$skipped" ]] || [[ "$path" == "$skipped"/* ]]; then
      return 0
    fi
  done
  return 1
}

collect_managed_target_files() {
  _MANAGED_TARGET_FILES=(
    "$CLAUDE_DIR/settings.json"
    "$CLAUDE_DIR/CLAUDE.md"
  )

  # Enumerate all starter-kit-owned file paths, then keep only paths that
  # currently exist under ~/.claude. This preserves tracking for leftovers from
  # previously enabled components without sweeping up arbitrary user files.
  _add_managed_tree_targets "$PROJECT_DIR/agents" "$CLAUDE_DIR/agents"
  _add_managed_tree_targets "$PROJECT_DIR/rules" "$CLAUDE_DIR/rules"
  _add_managed_tree_targets "$PROJECT_DIR/commands" "$CLAUDE_DIR/commands"
  _add_managed_tree_targets "$PROJECT_DIR/skills" "$CLAUDE_DIR/skills"
  _add_managed_tree_targets "$PROJECT_DIR/memory" "$CLAUDE_DIR/memory"
  _add_managed_tree_targets "$PROJECT_DIR/features/memory-persistence/scripts" "$CLAUDE_DIR/hooks/memory-persistence"
  _add_managed_tree_targets "$PROJECT_DIR/features/strategic-compact/scripts" "$CLAUDE_DIR/hooks/strategic-compact"
  _add_managed_tree_targets "$PROJECT_DIR/features/auto-update/scripts" "$CLAUDE_DIR/hooks/auto-update"
  _add_managed_tree_targets "$PROJECT_DIR/features/statusline/scripts" "$CLAUDE_DIR/hooks/statusline"
  _add_managed_tree_targets "$PROJECT_DIR/features/doc-size-guard/scripts" "$CLAUDE_DIR/hooks/doc-size-guard"

  # Filter out files that the user chose to preserve during fresh install.
  # These are user-owned and must not be tracked as kit-managed.
  if [[ ${#_FRESH_SKIPPED_FILES[@]} -gt 0 ]]; then
    local filtered=()
    local f
    for f in "${_MANAGED_TARGET_FILES[@]+"${_MANAGED_TARGET_FILES[@]}"}"; do
      if ! _is_fresh_skipped "$f"; then
        filtered+=("$f")
      fi
    done
    _MANAGED_TARGET_FILES=("${filtered[@]+"${filtered[@]}"}")
  fi
}

managed_files_json() {
  collect_managed_target_files
  {
    local file
    for file in "${_MANAGED_TARGET_FILES[@]+"${_MANAGED_TARGET_FILES[@]}"}"; do
      [[ -f "$file" ]] && printf '%s\n' "$file"
    done
  } | sort -u | jq -R -s 'split("\n")[:-1]'
}

write_managed_snapshot() {
  collect_managed_target_files
  local snapshot_files=()
  local file
  for file in "${_MANAGED_TARGET_FILES[@]+"${_MANAGED_TARGET_FILES[@]}"}"; do
    [[ -f "$file" ]] && snapshot_files+=("$file")
  done
  _write_snapshot "$CLAUDE_DIR" "${snapshot_files[@]+"${snapshot_files[@]}"}"
}

_SNAPSHOT_BOOTSTRAPPED=false

bootstrap_snapshot_from_current() {
  warn "$STR_UPDATE_V1_WARN"
  info "$STR_UPDATE_MIGRATION_BOOTSTRAP"
  write_managed_snapshot
  _SNAPSHOT_BOOTSTRAPPED=true
}

warn_existing_claude_reconfigure() {
  [[ -e "$CLAUDE_DIR" ]] || return 0
  [[ "${DRY_RUN:-false}" == "true" ]] && return 0

  printf "\n"
  warn "$STR_EXISTING_CLAUDE_WARN"
  info "$STR_EXISTING_CLAUDE_BACKUP"
  if [[ -f "$CLAUDE_DIR/settings.json" ]] && [[ ! -f "$CLAUDE_DIR/.starter-kit-manifest.json" ]]; then
    info "$STR_EXISTING_CLAUDE_MERGE_NOTE"
  else
    info "$STR_EXISTING_CLAUDE_REWRITE"
  fi
  info "$STR_EXISTING_CLAUDE_SIDE_EFFECTS"

  if [[ "${WIZARD_NONINTERACTIVE:-false}" == "true" ]]; then
    warn "$STR_EXISTING_CLAUDE_NONINTERACTIVE"
    return 0
  fi

  local confirm=""
  read -r -p "$STR_EXISTING_CLAUDE_CONFIRM " confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *)
      info "$STR_EXISTING_CLAUDE_CANCEL"
      exit 0
      ;;
  esac
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
# Fresh install safety: merge-aware deployment for existing users
# ---------------------------------------------------------------------------

# _copy_dir_safe <flag> <src> <dest>
#
# Like copy_if_enabled but checks for existing files in <dest>.
# Interactive: asks [O]verwrite all / [N]ew files only / [S]kip
# Non-interactive: new files only (safe default)
_copy_dir_safe() {
  local flag="$1"
  local src="$2"
  local dest="$3"
  local label
  label="$(basename "$dest")"

  if ! is_true "$flag"; then
    info "Skipped $label"
    return
  fi

  mkdir -p "$dest"

  # Check if dest has any existing files
  local has_existing=false
  if [[ -d "$dest" ]] && [[ -n "$(ls -A "$dest" 2>/dev/null)" ]]; then
    has_existing=true
  fi

  if [[ "$has_existing" == "false" ]]; then
    cp -a "$src"/. "$dest"/
    ok "Installed $label"
    return
  fi

  # Existing files found — decide what to do
  local action="new"  # default for non-interactive

  if [[ "${_MERGE_INTERACTIVE:-true}" == "true" ]]; then
    warn "$STR_FRESH_DIR_EXISTS $label/"
    printf "  %s " "$STR_FRESH_DIR_PROMPT" >&2
    local reply=""
    if read -r reply < /dev/tty 2>/dev/null; then
      true
    else
      reply="n"
    fi
    case "$reply" in
      [Oo]*) action="overwrite" ;;
      [Ss]*) action="skip" ;;
      *)     action="new" ;;
    esac
  fi

  case "$action" in
    overwrite)
      cp -a "$src"/. "$dest"/
      ok "Installed $label (overwrite)"
      ;;
    skip)
      _FRESH_SKIPPED_FILES+=("$dest")
      ok "$label: $STR_FRESH_SKIPPED"
      ;;
    new)
      # Copy only entries (files/directories) that do not exist in dest
      # -a : archive (recursive, preserve attributes)
      # -n : no-clobber (do not overwrite existing files)
      cp -an "$src"/. "$dest"/
      ok "$label: $STR_FRESH_NEW_ONLY"
      ;;
  esac
}

# _build_claude_md_safe
#
# Checks for existing CLAUDE.md before building.
# Interactive: asks [O]verwrite / [S]kip / [D]iff
# Non-interactive: skip (preserve user's file)
_build_claude_md_safe() {
  local target="$CLAUDE_DIR/CLAUDE.md"

  if [[ ! -f "$target" ]]; then
    build_claude_md
    return
  fi

  # Generate to temp for comparison
  local new_claude_md
  new_claude_md="$(mktemp)"
  _SETUP_TMP_FILES+=("$new_claude_md")
  build_claude_md_to_file "$new_claude_md"

  if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]]; then
    _FRESH_SKIPPED_FILES+=("$target")
    ok "CLAUDE.md: $STR_FRESH_SKIPPED"
    return
  fi

  warn "$STR_FRESH_FILE_EXISTS CLAUDE.md"
  while true; do
    printf "  %s " "$STR_FRESH_OVERWRITE_PROMPT" >&2
    local reply=""
    if read -r reply < /dev/tty 2>/dev/null; then
      true
    else
      reply="s"
    fi
    case "$reply" in
      [Oo]*)
        cp -a "$new_claude_md" "$target"
        ok "CLAUDE.md overwritten"
        return
        ;;
      [Dd]*)
        diff -u "$target" "$new_claude_md" 2>/dev/null >&2 || true
        printf "\n" >&2
        continue
        ;;
      *)
        _FRESH_SKIPPED_FILES+=("$target")
        ok "CLAUDE.md: $STR_FRESH_SKIPPED"
        return
        ;;
    esac
  done
}

# _build_settings_safe
#
# Merges existing settings.json with kit-generated settings using
# _merge_settings_bootstrap(). If no existing file, builds normally.
_build_settings_safe() {
  local target="$CLAUDE_DIR/settings.json"

  if [[ ! -f "$target" ]]; then
    build_settings
    return
  fi

  # Generate kit settings to temp file
  local new_settings
  new_settings="$(mktemp)"
  _SETUP_TMP_FILES+=("$new_settings")
  build_settings_to_file "$new_settings"

  info "$STR_FRESH_MERGE_SETTINGS"
  _merge_settings_bootstrap "$target" "$new_settings" "$target"
  ok "$STR_FRESH_MERGE_SETTINGS_DONE"
}

# _deploy_hook_scripts_safe
#
# Like deploy_hook_scripts but checks for existing hook dirs.
# Reuses _copy_dir_safe logic per feature.
_deploy_hook_scripts_safe() {
  local _features=(
    "ENABLE_MEMORY_PERSISTENCE:memory-persistence"
    "ENABLE_STRATEGIC_COMPACT:strategic-compact"
    "ENABLE_AUTO_UPDATE:auto-update"
    "ENABLE_STATUSLINE:statusline"
    "ENABLE_DOC_SIZE_GUARD:doc-size-guard"
  )
  local _entry _flag_var _feature_name _flag_val _src _dest

  for _entry in "${_features[@]}"; do
    _flag_var="${_entry%%:*}"
    _feature_name="${_entry#*:}"
    _flag_val="${!_flag_var:-false}"

    if ! is_true "$_flag_val"; then
      continue
    fi

    _src="$PROJECT_DIR/features/$_feature_name/scripts"
    _dest="$CLAUDE_DIR/hooks/$_feature_name"
    [[ -d "$_src" ]] || continue

    mkdir -p "$_dest"

    local has_existing=false
    if [[ -n "$(ls -A "$_dest" 2>/dev/null)" ]]; then
      has_existing=true
    fi

    if [[ "$has_existing" == "false" ]]; then
      cp -a "$_src"/. "$_dest"/
      chmod +x "$_dest"/*.sh 2>/dev/null || true
      chmod +x "$_dest"/*.py 2>/dev/null || true
      ok "Installed $_feature_name hooks"
      continue
    fi

    # Existing hooks — new files only (non-interactive default)
    local action="new"
    if [[ "${_MERGE_INTERACTIVE:-true}" == "true" ]]; then
      warn "$STR_FRESH_DIR_EXISTS hooks/$_feature_name/"
      printf "  %s " "$STR_FRESH_DIR_PROMPT" >&2
      local reply=""
      if read -r reply < /dev/tty 2>/dev/null; then
        true
      else
        reply="n"
      fi
      case "$reply" in
        [Oo]*) action="overwrite" ;;
        [Ss]*) action="skip" ;;
        *)     action="new" ;;
      esac
    fi

    case "$action" in
      overwrite)
        cp -a "$_src"/. "$_dest"/
        chmod +x "$_dest"/*.sh 2>/dev/null || true
        chmod +x "$_dest"/*.py 2>/dev/null || true
        ok "Installed $_feature_name hooks (overwrite)"
        ;;
      skip)
        _FRESH_SKIPPED_FILES+=("$_dest")
        ok "$_feature_name hooks: $STR_FRESH_SKIPPED"
        ;;
      new)
        cp -an "$_src"/. "$_dest"/
        chmod +x "$_dest"/*.sh 2>/dev/null || true
        chmod +x "$_dest"/*.py 2>/dev/null || true
        ok "$_feature_name hooks: $STR_FRESH_NEW_ONLY"
        ;;
    esac
  done
}

# _deploy_fresh_with_existing
#
# Merge-aware deployment for users with existing ~/.claude files
# but no starter-kit manifest (first-time kit users).
_deploy_fresh_with_existing() {
  info "$STR_EXISTING_CLAUDE_MERGE_NOTE"
  printf "\n"

  _copy_dir_safe "$INSTALL_AGENTS"  "$PROJECT_DIR/agents"   "$CLAUDE_DIR/agents"
  _copy_dir_safe "$INSTALL_RULES"   "$PROJECT_DIR/rules"    "$CLAUDE_DIR/rules"
  _copy_dir_safe "$INSTALL_COMMANDS" "$PROJECT_DIR/commands" "$CLAUDE_DIR/commands"
  _copy_dir_safe "$INSTALL_SKILLS"  "$PROJECT_DIR/skills"   "$CLAUDE_DIR/skills"
  _copy_dir_safe "$INSTALL_MEMORY"  "$PROJECT_DIR/memory"   "$CLAUDE_DIR/memory"

  _build_claude_md_safe
  _build_settings_safe
  _deploy_hook_scripts_safe
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

  # Safety Net must be first in PreToolUse array (runs before other hooks)
  if is_true "${ENABLE_SAFETY_NET:-false}"; then
    hook_fragments+=("$PROJECT_DIR/features/safety-net/hooks.json")
  fi
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
  if is_true "${ENABLE_PRE_COMPACT_COMMIT:-false}"; then
    hook_fragments+=("$PROJECT_DIR/features/pre-compact-commit/hooks.json")
  fi
  if is_true "${ENABLE_AUTO_UPDATE:-false}"; then
    hook_fragments+=("$PROJECT_DIR/features/auto-update/hooks.json")
  fi
  if is_true "${ENABLE_STATUSLINE:-false}"; then
    hook_fragments+=("$PROJECT_DIR/features/statusline/hooks.json")
  fi
  if is_true "${ENABLE_DOC_SIZE_GUARD:-false}"; then
    hook_fragments+=("$PROJECT_DIR/features/doc-size-guard/hooks.json")
  fi

  # Git push review: needs editor command substitution
  if is_true "$ENABLE_GIT_PUSH_REVIEW"; then
    if [[ "${EDITOR_CHOICE:-none}" == "none" ]]; then
      warn "Git push review hook skipped (no editor selected)"
    else
      local editor_cmd editor_cmd_escaped src tmp
      editor_cmd="$(editor_command "$EDITOR_CHOICE")"
      # Escape sed metacharacters in the replacement string
      editor_cmd_escaped="$(printf '%s\n' "$editor_cmd" | sed 's/[&\\|]/\\&/g')"
      src="$PROJECT_DIR/features/git-push-review/hooks.json"
      tmp="$(mktemp)"
      _SETUP_TMP_FILES+=("$tmp")
      if grep -q "__EDITOR_CMD__" "$src" 2>/dev/null; then
        sed "s|__EDITOR_CMD__|$editor_cmd_escaped|g" "$src" > "$tmp"
      else
        cp -a "$src" "$tmp"
      fi
      hook_fragments+=("$tmp")
      tmp_files+=("$tmp")
    fi
  fi

  build_settings_json "$base" "$permissions" "$out" ${hook_fragments[@]+"${hook_fragments[@]}"}
  apply_settings_preferences "$out"

  replace_home_path "$out"

  # Clean up temp files
  if [[ ${#tmp_files[@]} -gt 0 ]]; then
    rm -f "${tmp_files[@]}"
  fi
}

build_settings_to_file() {
  local out="$1"
  local base="$PROJECT_DIR/config/settings-base.json"
  local permissions="$PROJECT_DIR/config/permissions.json"

  local hook_fragments=()
  local tmp_files=()

  # Safety Net must be first in PreToolUse array (runs before other hooks)
  if is_true "${ENABLE_SAFETY_NET:-false}"; then
    hook_fragments+=("$PROJECT_DIR/features/safety-net/hooks.json")
  fi
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
  if is_true "${ENABLE_PRE_COMPACT_COMMIT:-false}"; then
    hook_fragments+=("$PROJECT_DIR/features/pre-compact-commit/hooks.json")
  fi
  if is_true "${ENABLE_AUTO_UPDATE:-false}"; then
    hook_fragments+=("$PROJECT_DIR/features/auto-update/hooks.json")
  fi
  if is_true "${ENABLE_STATUSLINE:-false}"; then
    hook_fragments+=("$PROJECT_DIR/features/statusline/hooks.json")
  fi
  if is_true "${ENABLE_DOC_SIZE_GUARD:-false}"; then
    hook_fragments+=("$PROJECT_DIR/features/doc-size-guard/hooks.json")
  fi
  if is_true "$ENABLE_GIT_PUSH_REVIEW"; then
    if [[ "${EDITOR_CHOICE:-none}" != "none" ]]; then
      local editor_cmd editor_cmd_escaped src tmp
      editor_cmd="$(editor_command "$EDITOR_CHOICE")"
      editor_cmd_escaped="$(printf '%s\n' "$editor_cmd" | sed 's/[&\\|]/\\&/g')"
      src="$PROJECT_DIR/features/git-push-review/hooks.json"
      tmp="$(mktemp)"
      _SETUP_TMP_FILES+=("$tmp")
      if grep -q "__EDITOR_CMD__" "$src" 2>/dev/null; then
        sed "s|__EDITOR_CMD__|$editor_cmd_escaped|g" "$src" > "$tmp"
      else
        cp -a "$src" "$tmp"
      fi
      hook_fragments+=("$tmp")
      tmp_files+=("$tmp")
    fi
  fi

  build_settings_json "$base" "$permissions" "$out" ${hook_fragments[@]+"${hook_fragments[@]}"}
  apply_settings_preferences "$out"

  replace_home_path "$out"

  if [[ ${#tmp_files[@]} -gt 0 ]]; then
    rm -f "${tmp_files[@]}"
  fi
}

build_claude_md_to_file() {
  local out="$1"
  local lang="${LANGUAGE:-en}"
  local base="$PROJECT_DIR/i18n/${lang}/CLAUDE.md.base"

  cp -a "$base" "$out"

  if is_true "$ENABLE_CODEX_MCP"; then
    local partial="$PROJECT_DIR/features/codex-mcp/CLAUDE.md.partial.${lang}"
    inject_feature "$out" "codex-mcp" "$partial"
  fi

  remove_unresolved "$out"
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

  if is_true "${ENABLE_AUTO_UPDATE:-false}"; then
    local dest="$CLAUDE_DIR/hooks/auto-update"
    mkdir -p "$dest"
    cp -a "$PROJECT_DIR/features/auto-update/scripts"/. "$dest"/
    chmod +x "$dest"/*.sh
    ok "Installed auto-update hook"
  fi

  if is_true "${ENABLE_STATUSLINE:-false}"; then
    local dest="$CLAUDE_DIR/hooks/statusline"
    mkdir -p "$dest"
    cp -a "$PROJECT_DIR/features/statusline/scripts"/. "$dest"/
    chmod +x "$dest"/*.py 2>/dev/null || true
    chmod +x "$dest"/*.sh 2>/dev/null || true
    ok "Installed statusline script"
  fi

  if is_true "${ENABLE_DOC_SIZE_GUARD:-false}"; then
    local dest="$CLAUDE_DIR/hooks/doc-size-guard"
    mkdir -p "$dest"
    cp -a "$PROJECT_DIR/features/doc-size-guard/scripts"/. "$dest"/
    chmod +x "$dest"/*.sh
    ok "Installed doc-size-guard hook"
  fi

}

# ---------------------------------------------------------------------------
# Manifest: track all deployed files for clean uninstall
# ---------------------------------------------------------------------------
write_manifest() {
  local manifest="$CLAUDE_DIR/.starter-kit-manifest.json"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  local kit_version
  kit_version="$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null || echo "unknown")"

  # Only track files that the starter kit itself manages.
  local files_json
  files_json="$(managed_files_json)"

  jq -n \
    --arg version "2" \
    --arg ts "$ts" \
    --arg kit_version "$kit_version" \
    --arg profile "${PROFILE:-}" \
    --arg language "${LANGUAGE:-}" \
    --arg editor "${EDITOR_CHOICE:-}" \
    --arg commit_attribution "${COMMIT_ATTRIBUTION:-}" \
    --arg new_init "${ENABLE_NEW_INIT:-}" \
    --arg plugins "${SELECTED_PLUGINS:-}" \
    --argjson files "$files_json" \
    --arg snapshot_dir "$CLAUDE_DIR/.starter-kit-snapshot" \
    '{
      version: $version,
      timestamp: $ts,
      kit_version: $kit_version,
      profile: $profile,
      language: $language,
      editor: $editor,
      commit_attribution: $commit_attribution,
      new_init: $new_init,
      plugins: $plugins,
      files: $files,
      snapshot_dir: $snapshot_dir
    }' > "$manifest"
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
fi

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
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
    _deploy_fresh_with_existing
  else
    # Clean slate: original behavior
    copy_if_enabled "$INSTALL_AGENTS"  "$PROJECT_DIR/agents"   "$CLAUDE_DIR/agents"
    copy_if_enabled "$INSTALL_RULES"   "$PROJECT_DIR/rules"    "$CLAUDE_DIR/rules"
    copy_if_enabled "$INSTALL_COMMANDS" "$PROJECT_DIR/commands" "$CLAUDE_DIR/commands"
    copy_if_enabled "$INSTALL_SKILLS"  "$PROJECT_DIR/skills"   "$CLAUDE_DIR/skills"
    copy_if_enabled "$INSTALL_MEMORY"  "$PROJECT_DIR/memory"   "$CLAUDE_DIR/memory"

    build_claude_md

    build_settings
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
  if [[ ! -x "$HOME/.local/bin/claude" ]] && ! command -v claude &>/dev/null; then
    _dryrun_log "EXTERNAL" "Claude CLI" "curl -fsSL https://claude.ai/install.sh | bash"
  fi
  if [[ -n "${SELECTED_PLUGINS:-}" ]]; then
    IFS=',' read -r -a _dr_plugins <<< "$SELECTED_PLUGINS"
    for _dr_p in "${_dr_plugins[@]}"; do
      _dr_name="${_dr_p%%@*}"
      [[ -n "$_dr_name" ]] && _dryrun_log "EXTERNAL" "Plugin" "claude plugin install $_dr_name"
    done
  fi
  if is_true "${ENABLE_CODEX_MCP:-false}"; then
    _dryrun_log "EXTERNAL" "Codex MCP" "claude mcp add -s user codex -- codex mcp-server"
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
else
  ok "$STR_CLI_ALREADY"
fi

# Always ensure ~/.local/bin is in PATH config (even if CLI was found via
# inherited PATH from another user or transient session)
_ensure_local_bin_in_path

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
    for _p in "${_plugins[@]}"; do
      _p_name="${_p%%@*}"
      if [[ -n "$_p_name" ]] && ! echo "$_installed_plugins" | grep -q "$_p_name" 2>/dev/null; then
        _need_install=true
        break
      fi
    done

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
        if echo "$_installed_plugins" | grep -q "$_p_name" 2>/dev/null; then
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
    orig_mode="$(stat -f '%Lp' "$rc_file" 2>/dev/null || stat -c '%a' "$rc_file" 2>/dev/null || echo '644')"
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
# Final safety net: ensure Claude CLI is actually installed
# (catches edge cases where the earlier installation was skipped or failed)
# ---------------------------------------------------------------------------
if [[ ! -x "$HOME/.local/bin/claude" ]] && ! command -v claude &>/dev/null; then
  printf "\n"
  warn "Claude CLI not found after setup. Running installer..."
  if curl -fsSL https://claude.ai/install.sh | bash; then
    export PATH="$HOME/.local/bin:$PATH"
    _ensure_local_bin_in_path
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
