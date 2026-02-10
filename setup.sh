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

  build_settings_json "$base" "$permissions" "$out" "${hook_fragments[@]}"

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

  local files_json
  files_json="$(find "$CLAUDE_DIR" -type f ! -name ".starter-kit-manifest.json" | sort | jq -R -s 'split("\n")[:-1]')"

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
write_manifest

# Save config for re-runs
save_config "${WIZARD_CONFIG_FILE:-$HOME/.claude-starter-kit.conf}"

section "Setup Complete"
ok "Deployed to $CLAUDE_DIR"

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
      if command -v npm &>/dev/null; then
        info "$STR_CLI_INSTALLING"
        local npm_prefix
        npm_prefix="$(npm config get prefix 2>/dev/null || echo '/usr/local')"
        if [[ -w "${npm_prefix}/lib" ]]; then
          npm install -g @anthropic-ai/claude-code
        else
          sudo npm install -g @anthropic-ai/claude-code
        fi
        if command -v claude &>/dev/null; then
          ok "$STR_CLI_INSTALLED"
        else
          warn "$STR_CLI_PATH_WARN"
        fi
      else
        error "$STR_CLI_NPM_MISSING"
        printf "  npm install -g @anthropic-ai/claude-code\n"
      fi
      ;;
    *)
      info "$STR_CLI_INSTALL_LATER"
      printf "  npm install -g @anthropic-ai/claude-code\n"
      ;;
  esac
else
  ok "$STR_CLI_ALREADY"
fi

# ---------------------------------------------------------------------------
# Plugin hints
# ---------------------------------------------------------------------------
if [[ -n "${SELECTED_PLUGINS:-}" ]]; then
  printf "\n"
  info "$STR_DEPLOY_PLUGINS_HINT"
  IFS=',' read -r -a _plugins <<< "$SELECTED_PLUGINS"
  for p in "${_plugins[@]}"; do
    [[ -n "$p" ]] && printf "  /install %s\n" "$p"
  done
fi

# ---------------------------------------------------------------------------
# WSL hint
# ---------------------------------------------------------------------------
if is_wsl; then
  printf "\n"
  warn "$STR_WSL_IMPORTANT"
  info "$STR_WSL_HOW_TO"
  info "  $STR_WSL_STEP1"
  info "  $STR_WSL_STEP2"
  info "  $STR_WSL_STEP3"
fi
