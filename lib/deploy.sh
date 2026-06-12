#!/bin/bash
# lib/deploy.sh - Build + deploy functions extracted from setup.sh
#
# Dependencies (must be sourced before this file):
#   lib/colors.sh       (ok, warn, info, error, section)
#   lib/features.sh     (_FEATURE_FLAGS, _FEATURE_ORDER, _FEATURE_HAS_SCRIPTS)
#   lib/template.sh     (_has_kit_markers, _extract_kit_section, etc.)
#   lib/json-builder.sh (build_settings_json, merge_deep, replace_home_path)
#   lib/snapshot.sh     (_write_snapshot, _snapshot_claude_md, _snapshot_exists)
#   lib/merge.sh        (_merge_settings_bootstrap)
#   lib/dryrun.sh       (_dryrun_init, etc.)
#
# Globals expected from setup.sh:
#   CLAUDE_DIR, PROJECT_DIR, DRY_RUN, _SETUP_TMP_FILES[], _FRESH_SKIPPED_FILES[]
# ---------------------------------------------------------------------------

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

# language_code - returns the code Claude Code expects in settings.json
language_code() {
  case "${LANGUAGE:-en}" in
    ja) printf "ja" ;;
    *)  printf "en" ;;
  esac
}

_bool_to_string() {
  if is_true "${1:-false}"; then
    printf "true"
  else
    printf "false"
  fi
}

_version_ge() {
  local lhs="${1:-0}"
  local rhs="${2:-0}"
  local lhs_a lhs_b lhs_c rhs_a rhs_b rhs_c _

  IFS='.' read -r lhs_a lhs_b lhs_c _ <<< "$lhs"
  IFS='.' read -r rhs_a rhs_b rhs_c _ <<< "$rhs"
  lhs_a="${lhs_a:-0}"; lhs_b="${lhs_b:-0}"; lhs_c="${lhs_c:-0}"
  rhs_a="${rhs_a:-0}"; rhs_b="${rhs_b:-0}"; rhs_c="${rhs_c:-0}"

  (( lhs_a > rhs_a )) && return 0
  (( lhs_a < rhs_a )) && return 1
  (( lhs_b > rhs_b )) && return 0
  (( lhs_b < rhs_b )) && return 1
  (( lhs_c >= rhs_c ))
}

_CLAUDE_SEMVER_CACHE="${_CLAUDE_SEMVER_CACHE-}"
_CLAUDE_SEMVER_CACHE_SET="${_CLAUDE_SEMVER_CACHE_SET:-false}"

_claude_cli_semver() {
  local raw version
  command -v claude &>/dev/null || return 1
  if [[ "$_CLAUDE_SEMVER_CACHE_SET" == "true" ]]; then
    [[ -n "$_CLAUDE_SEMVER_CACHE" ]] || return 1
    printf '%s\n' "$_CLAUDE_SEMVER_CACHE"
    return 0
  fi
  _CLAUDE_SEMVER_CACHE_SET=true
  raw="$(claude --version 2>/dev/null | head -1)"
  if ! [[ "$raw" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    _CLAUDE_SEMVER_CACHE=""
    return 1
  fi
  version="${BASH_REMATCH[1]}"
  _CLAUDE_SEMVER_CACHE="$version"
  printf '%s\n' "$version"
}

_claude_supports_async_hooks() {
  local min_version="${1:-2.1.89}"
  local current_version=""

  # Fail open when Claude is absent so generated config stays forward-looking
  # during offline tests or first install. Fail closed when a present CLI has an
  # unparsable version because we cannot prove async hook support.
  if ! command -v claude &>/dev/null; then
    return 0
  fi

  current_version="$(_claude_cli_semver 2>/dev/null || true)"
  [[ -n "$current_version" ]] || return 1
  _version_ge "$current_version" "$min_version"
}

_versioned_hooks_fragment() {
  local feature="$1"
  local src="$PROJECT_DIR/features/${feature}/hooks.json"
  local legacy_src="$PROJECT_DIR/features/${feature}/hooks.legacy.json"

  if _claude_supports_async_hooks "2.1.89"; then
    printf '%s\n' "$src"
  else
    printf '%s\n' "$legacy_src"
  fi
}

_auto_update_hooks_fragment() {
  _versioned_hooks_fragment "auto-update"
}

_pr_creation_log_hooks_fragment() {
  _versioned_hooks_fragment "pr-creation-log"
}

apply_settings_preferences() {
  local file="$1"
  local lang_name tmp_file attribution_enabled
  lang_name="$(language_code)"
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

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
_BACKUP_TIMESTAMP=""

backup_existing() {
  # Dry-run: no real backup needed (sim dir protects the real filesystem)
  [[ "${DRY_RUN:-false}" == "true" ]] && return 0

  if [[ -e "$CLAUDE_DIR" ]]; then
    _BACKUP_TIMESTAMP="$(date +%Y%m%d%H%M%S)"
    local backup="$HOME/.claude.backup.${_BACKUP_TIMESTAMP}"
    cp -a "$CLAUDE_DIR" "$backup"
    ok "Backed up existing ~/.claude to $backup"

    # Persist backup path for cross-process recovery (e.g., auto-update.sh)
    printf '%s\n' "$backup" > "$CLAUDE_DIR/.starter-kit-last-backup"
  fi
}

# ---------------------------------------------------------------------------
# Manifest: track all deployed files for clean uninstall
# ---------------------------------------------------------------------------
_MANAGED_TARGET_FILES=()

_is_distribution_excluded_relpath() {
  local rel_path="$1"
  case "$rel_path" in
    node_modules|node_modules/*|logs|logs/*|*.bak)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_find_distribution_files() {
  local src_root="$1"
  [[ -d "$src_root" ]] || return 0

  local src_file rel_path
  while IFS= read -r -d '' src_file; do
    rel_path="${src_file#"$src_root"/}"
    _is_distribution_excluded_relpath "$rel_path" && continue
    printf '%s\0' "$src_file"
  done < <(find "$src_root" \
    \( -type d \( -name node_modules -o -name logs \) -prune \) -o \
    \( -type f -name '*.bak' -prune \) -o \
    -type f -print0 2>/dev/null)
}

_copy_distribution_tree() {
  local src_root="$1"
  local dest_root="$2"
  local mode="${3:-overwrite}"

  [[ -d "$src_root" ]] || return 0
  mkdir -p "$dest_root"

  local src_file rel_path dest_file
  while IFS= read -r -d '' src_file; do
    rel_path="${src_file#"$src_root"/}"
    dest_file="${dest_root}/${rel_path}"
    [[ "$mode" == "new" && -e "$dest_file" ]] && continue
    mkdir -p "$(dirname "$dest_file")"
    cp -p "$src_file" "$dest_file"
  done < <(_find_distribution_files "$src_root")
}

_add_managed_tree_targets() {
  local src_root="$1"
  local dest_root="$2"
  [[ -d "$src_root" ]] || return 0

  local src_file rel_path
  while IFS= read -r -d '' src_file; do
    rel_path="${src_file#"$src_root"/}"
    _MANAGED_TARGET_FILES+=("${dest_root}/${rel_path}")
  done < <(_find_distribution_files "$src_root")
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
  # Registry-driven: hook script paths from _FEATURE_HAS_SCRIPTS
  local _feat_name
  for _feat_name in "${_FEATURE_SCRIPT_ORDER[@]}"; do
    [[ "${_FEATURE_HAS_SCRIPTS[$_feat_name]+set}" ]] || continue
    _add_managed_tree_targets "$PROJECT_DIR/features/$_feat_name/scripts" "$CLAUDE_DIR/hooks/$_feat_name"
  done

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
    true  # Ensure non-zero from last [[ -f ]] miss doesn't trigger pipefail
  } | sort -u | jq -R -s 'split("\n")[:-1]'
}

cleanup_paths_json() {
  jq -n \
    --arg claude_dir "$CLAUDE_DIR" \
    --arg config "$HOME/.claude-starter-kit.conf" \
    '[
      ($claude_dir + "/skills/web-content-extraction"),
      ($claude_dir + "/.starter-kit-update.lock"),
      ($claude_dir + "/.starter-kit-update-status"),
      ($claude_dir + "/.starter-kit-update-cache"),
      ($claude_dir + "/.starter-kit-merge-prefs.json"),
      ($claude_dir + "/.starter-kit-pending-features.json"),
      ($claude_dir + "/sessions"),
      ($claude_dir + "/tmp/tool-count-*"),
      ($claude_dir + "/.starter-kit-snapshot"),
      ($claude_dir + "/.starter-kit-last-backup"),
      $config
    ]'
}

write_managed_snapshot() {
  collect_managed_target_files
  local snapshot_files=()
  local file
  for file in "${_MANAGED_TARGET_FILES[@]+"${_MANAGED_TARGET_FILES[@]}"}"; do
    [[ -f "$file" ]] && snapshot_files+=("$file")
  done
  _write_snapshot "$CLAUDE_DIR" "${snapshot_files[@]+"${snapshot_files[@]}"}"

  # CLAUDE.md: replace full-file snapshot with kit-section-only snapshot
  if [[ -f "$CLAUDE_DIR/CLAUDE.md" ]]; then
    _snapshot_claude_md "$CLAUDE_DIR" "$CLAUDE_DIR/CLAUDE.md"
  fi
}

_SNAPSHOT_BOOTSTRAPPED=false

bootstrap_snapshot_from_current() {
  warn "$STR_UPDATE_V1_WARN"
  info "$STR_UPDATE_MIGRATION_BOOTSTRAP"
  write_managed_snapshot
  _SNAPSHOT_BOOTSTRAPPED=true
  if [[ -n "${_BACKUP_TIMESTAMP:-}" ]]; then
    info "Backup available at: ~/.claude.backup.${_BACKUP_TIMESTAMP}"
  fi
}

# ---------------------------------------------------------------------------
# Pre-deploy warnings
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# File copy helpers
# ---------------------------------------------------------------------------
copy_if_enabled() {
  local flag="$1"
  local src="$2"
  local dest="$3"

  if is_true "$flag"; then
    _copy_distribution_tree "$src" "$dest" "overwrite"
    ok "Installed $(basename "$dest")"
  else
    info "Skipped $(basename "$dest")"
  fi
}

# _copy_dir_safe <flag> <src> <dest>
#
# Like copy_if_enabled but checks for existing files in <dest>.
# Interactive: asks [O]verwrite all / [N]ew files only / [S]kip
# Non-interactive: new files only (safe default)
# Prompt replies are read from ${_TTY_INPUT:-/dev/tty} (tests may inject a file).
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
    _copy_distribution_tree "$src" "$dest" "overwrite"
    ok "Installed $label"
    return
  fi

  # Existing files found — decide what to do
  local action="new"  # default for non-interactive

  if [[ "${_MERGE_INTERACTIVE:-true}" == "true" ]]; then
    warn "$STR_FRESH_DIR_EXISTS $label/"
    printf "  %s " "$STR_FRESH_DIR_PROMPT" >&2
    local reply=""
    if read -r reply < "${_TTY_INPUT:-/dev/tty}" 2>/dev/null; then
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
      _copy_distribution_tree "$src" "$dest" "overwrite"
      ok "Installed $label (overwrite)"
      ;;
    skip)
      _FRESH_SKIPPED_FILES+=("$dest")
      ok "$label: $STR_FRESH_SKIPPED"
      ;;
    new)
      _copy_distribution_tree "$src" "$dest" "new"
      ok "$label: $STR_FRESH_NEW_ONLY"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# maybe_install_web_content_deps - npm deps for the web-content-extraction skill
#
# The web-content-extraction skill ships executable Node scripts that depend on
# defuddle/jsdom/pdfjs-dist/undici. After the skill is deployed, install its
# production dependencies in place.
#
# - Only runs when INSTALL_SKILLS is enabled and the skill's package.json exists.
# - Node-optional: if node/npm is missing, warns and returns 0 (never fails the
#   install). The skill's pure-JS guard logic still ships; URL/PDF fetch needs deps.
# - Idempotent: safe to re-run (npm install is idempotent).
# - Dry-run: logs a [WOULD RUN] entry and does not execute.
# Covers fresh, fresh-with-existing, and update paths (called once after deploy).
# ---------------------------------------------------------------------------
maybe_install_web_content_deps() {
  is_true "${INSTALL_SKILLS:-false}" || return 0
  local skill_dir="$CLAUDE_DIR/skills/web-content-extraction"
  [[ -f "$skill_dir/package.json" ]] || return 0

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    _dryrun_log "EXTERNAL" "web-content-extraction" "npm ci --omit=dev (in ~/.claude/skills/web-content-extraction)"
    return 0
  fi

  # Test harness opt-out: skip the (network) npm install during automated tests.
  [[ -n "${WCE_SKIP_NPM_INSTALL:-}" ]] && return 0

  if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
    warn "${STR_WCE_NODE_MISSING:-Node.js not found — web-content-extraction URL/PDF features are disabled until dependencies are installed.}"
    info "${STR_WCE_NODE_HINT:-Install Node.js 22+ then run: (cd ~/.claude/skills/web-content-extraction && npm ci --omit=dev)}"
    return 0
  fi

  info "${STR_WCE_NPM_INSTALLING:-Installing web-content-extraction skill dependencies...}"
  mkdir -p "$skill_dir/logs"
  # Use `npm ci` to install strictly from the committed package-lock.json
  # (reproducible, version-pinned — matches update-deps.mjs's rollback path).
  # Output is kept in the skill's logs/ for debuggability instead of discarded.
  if ( cd "$skill_dir" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund >"$skill_dir/logs/install.log" 2>&1 ); then
    ok "${STR_WCE_NPM_DONE:-web-content-extraction dependencies installed}"
  else
    warn "${STR_WCE_NPM_FAILED:-npm install failed for web-content-extraction; skill scripts may not run until dependencies are installed.}"
    info "  → ~/.claude/skills/web-content-extraction/logs/install.log"
  fi
}

# ---------------------------------------------------------------------------
# Build CLAUDE.md
# ---------------------------------------------------------------------------
build_claude_md() {
  local out="$CLAUDE_DIR/CLAUDE.md"
  build_claude_md_to_file "$out"
  ok "Built CLAUDE.md"
}

build_claude_md_to_file() {
  local out="$1"
  local lang="${LANGUAGE:-en}"
  local base="$PROJECT_DIR/i18n/${lang}/CLAUDE.md.base"

  cp -a "$base" "$out"

  # Spec Kit pointer — only when commands (incl. /spec-kit-init) are installed
  if is_true "${INSTALL_COMMANDS:-false}"; then
    local sk_partial="$PROJECT_DIR/i18n/${lang}/partials/spec-kit.md"
    inject_feature "$out" "spec-kit" "$sk_partial"
  fi

  # Web content extraction standard rule — only when the skill is installed
  if is_true "${INSTALL_SKILLS:-false}"; then
    local wce_partial="$PROJECT_DIR/i18n/${lang}/partials/web-content-extraction.md"
    inject_feature "$out" "web-content-extraction" "$wce_partial"
  fi

  if is_true "$ENABLE_CODEX_PLUGIN"; then
    local partial="$PROJECT_DIR/features/codex-plugin/CLAUDE.md.partial.${lang}"
    inject_feature "$out" "codex-plugin" "$partial"
  fi

  remove_unresolved "$out" "delete"
}

# ---------------------------------------------------------------------------
# Build settings.json
# ---------------------------------------------------------------------------
# build_settings_file - Registry-based settings.json builder (unified)
#
# Usage: build_settings_file <output_path>
#
# Uses _FEATURE_ORDER and _FEATURE_FLAGS from lib/features.sh to iterate
# Assertion: safety-net must be _FEATURE_ORDER[0].
# ---------------------------------------------------------------------------
build_settings_file() {
  local out="$1"
  local base="$PROJECT_DIR/config/settings-base.json"
  local permissions="$PROJECT_DIR/config/permissions.json"

  local hook_fragments=()
  local tmp_files=()

  # Prime the semver cache in THIS shell: the fragment helpers below run in
  # $(...) subshells, so cache writes made there never persist and `claude
  # --version` would otherwise be spawned once per fragment.
  _claude_cli_semver >/dev/null 2>&1 || true

  # Assertion: safety-net must be first in _FEATURE_ORDER
  if [[ "${_FEATURE_ORDER[0]}" != "safety-net" ]]; then
    error "FATAL: safety-net must be first in _FEATURE_ORDER (got: ${_FEATURE_ORDER[0]:-empty})"
    return 1
  fi

  # Registry-driven hook fragment collection
  local name flag
  for name in "${_FEATURE_ORDER[@]}"; do
    flag="${_FEATURE_FLAGS[$name]:-}"
    if [[ -z "$flag" ]]; then
      error "FATAL: _FEATURE_FLAGS[$name] is empty — registry inconsistency"
      return 1
    fi
    is_true "${!flag:-false}" || continue
    # web-content-update's hook targets a script inside the skill dir; only emit
    # it when the skill is actually installed (avoids a dangling SessionStart hook
    # if the flag is enabled via CLI/hand-edited config without INSTALL_SKILLS).
    if [[ "$name" == "web-content-update" ]] && ! is_true "${INSTALL_SKILLS:-false}"; then
      continue
    fi
    local hooks_json="$PROJECT_DIR/features/$name/hooks.json"
    if [[ "$name" == "auto-update" ]]; then
      hooks_json="$(_auto_update_hooks_fragment)"
    elif [[ "$name" == "pr-creation-log" ]]; then
      hooks_json="$(_pr_creation_log_hooks_fragment)"
    fi
    [[ -f "$hooks_json" ]] && hook_fragments+=("$hooks_json")
  done

  build_settings_json "$base" "$permissions" "$out" ${hook_fragments[@]+"${hook_fragments[@]}"}
  apply_settings_preferences "$out"
  replace_home_path "$out"

  # Clean up temp files
  if [[ ${#tmp_files[@]} -gt 0 ]]; then
    rm -f "${tmp_files[@]}"
  fi
}

_compose_migrated_claude_md() {
  local new_kit_file="$1"
  local existing_file="$2"
  local kit_section user_heading
  kit_section="$(_extract_kit_section "$new_kit_file")"
  user_heading="$(_user_section_heading)"
  printf '%s\n' "$kit_section"
  printf '\n%s\n\n' "$user_heading"
  cat "$existing_file"
  printf '\n'
}

# _claude_md_migration_prompt <new_claude_md> <target>
#
# Interactive [M]erge / [D]iff / [S]kip loop for migrating a marker-less
# CLAUDE.md. Replies are read from ${_TTY_INPUT:-/dev/tty} (tests may inject
# a file). Default (no tty / unrecognized reply) is skip, which registers
# <target> in _FRESH_SKIPPED_FILES.
_claude_md_migration_prompt() {
  local new_claude_md="$1"
  local target="$2"

  while true; do
    printf "  %s " "$STR_CLAUDEMD_MIGRATION_PROMPT" >&2
    local reply=""
    if read -r reply < "${_TTY_INPUT:-/dev/tty}" 2>/dev/null; then true; else reply="s"; fi
    case "$reply" in
      [Mm]*)
        local merged
        merged="$(mktemp)"
        _SETUP_TMP_FILES+=("$merged")
        _compose_migrated_claude_md "$new_claude_md" "$target" > "$merged"
        mv "$merged" "$target"
        ok "CLAUDE.md upgraded — your content preserved in user section"
        return
        ;;
      [Dd]*)
        # Show what the merged result would look like
        local preview
        preview="$(mktemp)"
        _SETUP_TMP_FILES+=("$preview")
        _compose_migrated_claude_md "$new_claude_md" "$target" > "$preview"
        diff -u "$target" "$preview" 2>/dev/null >&2 || true
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

# ---------------------------------------------------------------------------
# Section-aware CLAUDE.md deployment for fresh install with existing file
# ---------------------------------------------------------------------------
# _build_claude_md_safe
#
# - No existing file → build normally (kit + user skeleton)
# - Existing with markers → replace kit section only
# - Existing without markers (migration) → wrap existing as user section
_build_claude_md_safe() {
  local target="$CLAUDE_DIR/CLAUDE.md"

  if [[ ! -f "$target" ]]; then
    build_claude_md
    return
  fi

  # Generate new kit version to temp
  local new_claude_md
  new_claude_md="$(mktemp)"
  _SETUP_TMP_FILES+=("$new_claude_md")
  build_claude_md_to_file "$new_claude_md"

  if _has_kit_markers "$target"; then
    # Existing file has markers → replace kit section, preserve user section
    local new_kit_section
    new_kit_section="$(mktemp)"
    _SETUP_TMP_FILES+=("$new_kit_section")
    _extract_kit_section "$new_claude_md" > "$new_kit_section"
    _replace_kit_section "$target" "$new_kit_section"
    ok "$STR_CLAUDEMD_KIT_UPDATED"
    info "$STR_CLAUDEMD_USER_PRESERVED"
    return
  fi

  # No markers — detect old kit-generated file
  local old_kit_output
  old_kit_output="$(mktemp)"
  _SETUP_TMP_FILES+=("$old_kit_output")
  grep -vF "<!-- BEGIN STARTER-KIT-MANAGED -->" "$new_claude_md" \
    | grep -vF "<!-- END STARTER-KIT-MANAGED -->" \
    | grep -vF "$(_user_section_heading)" \
    | grep -v '^<!-- .*custom instructions' \
    > "$old_kit_output" || true

  # Compare ignoring blank lines: exact match = no user edits
  local current_trimmed old_kit_trimmed
  current_trimmed="$(_sed '/^[[:space:]]*$/d' "$target")"
  old_kit_trimmed="$(_sed '/^[[:space:]]*$/d' "$old_kit_output")"

  if [[ "$current_trimmed" == "$old_kit_trimmed" ]]; then
    cp -a "$new_claude_md" "$target"
    ok "CLAUDE.md upgraded to section-aware format"
    return
  fi

  # Differences found (additions, deletions, or edits) → user customization
  if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]]; then
    _FRESH_SKIPPED_FILES+=("$target")
    warn "$STR_CLAUDEMD_MIGRATION_SKIP"
    return
  fi

  warn "$STR_CLAUDEMD_MIGRATION"
  info "Differences from kit template:"
  diff -u "$old_kit_output" "$target" 2>/dev/null >&2 || true
  printf "\n" >&2

  _claude_md_migration_prompt "$new_claude_md" "$target"
}

# _build_settings_safe
#
# Merges existing settings.json with kit-generated settings using
# _merge_settings_bootstrap(). If no existing file, builds normally.
_build_settings_safe() {
  local target="$CLAUDE_DIR/settings.json"

  if [[ ! -f "$target" ]]; then
    build_settings_file "$target"
    return
  fi

  # Generate kit settings to temp file
  local new_settings
  new_settings="$(mktemp)"
  _SETUP_TMP_FILES+=("$new_settings")
  build_settings_file "$new_settings"

  info "$STR_FRESH_MERGE_SETTINGS"
  _merge_settings_bootstrap "$target" "$new_settings" "$target"
  ok "$STR_FRESH_MERGE_SETTINGS_DONE"
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

  _build_claude_md_safe
  _build_settings_safe
  deploy_hook_scripts "merge-aware"
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
write_manifest() {
  local manifest="$CLAUDE_DIR/.starter-kit-manifest.json"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  local kit_version
  kit_version="$(git -C "$PROJECT_DIR" describe --tags --always 2>/dev/null || echo "unknown")"

  local kit_commit
  kit_commit="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"

  # Only track files that the starter kit itself manages.
  local files_json
  files_json="$(managed_files_json)"
  local cleanup_paths
  cleanup_paths="$(cleanup_paths_json)"

  jq -n \
    --arg version "2" \
    --arg ts "$ts" \
    --arg kit_version "$kit_version" \
    --arg kit_commit "$kit_commit" \
    --arg profile "${PROFILE:-}" \
    --arg language "${LANGUAGE:-}" \
    --arg editor "${EDITOR_CHOICE:-}" \
    --arg commit_attribution "${COMMIT_ATTRIBUTION:-}" \
    --arg new_init "${ENABLE_NEW_INIT:-}" \
    --arg plugins "${SELECTED_PLUGINS:-}" \
    --arg codex_plugin "${ENABLE_CODEX_PLUGIN:-false}" \
    --argjson files "$files_json" \
    --argjson cleanup_paths "$cleanup_paths" \
    --arg snapshot_dir "$CLAUDE_DIR/.starter-kit-snapshot" \
    --arg claude_dir "$CLAUDE_DIR" \
    '{
      version: $version,
      timestamp: $ts,
      kit_version: $kit_version,
      kit_commit: $kit_commit,
      profile: $profile,
      language: $language,
      editor: $editor,
      commit_attribution: $commit_attribution,
      new_init: $new_init,
      plugins: $plugins,
      codex_plugin: $codex_plugin,
      files: $files,
      cleanup_paths: $cleanup_paths,
      snapshot_dir: $snapshot_dir,
      claude_dir: $claude_dir
    }' > "$manifest"
}

# ---------------------------------------------------------------------------
# _offer_dryrun_preview - Offer interactive dry-run before deploying
#
# Only called when existing files could be affected. Clean-slate installs
# skip this entirely. The message can be customized via the first argument.
#
# NOTE: Uses $0 to re-exec setup.sh — this is intentional even though this
# function lives in deploy.sh. $0 always points to setup.sh (the entry point).
# ---------------------------------------------------------------------------
_offer_dryrun_preview() {
  local message="${1:-$STR_DRYRUN_OFFER}"

  # Skip if already in dry-run, or non-interactive (merge prompts disabled)
  [[ "${DRY_RUN:-false}" == "true" ]] && return 0
  [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]] && return 0

  printf "\n"
  info "$message"
  printf "  [Y]es / [N]o ? " >&2
  local _dr_offer=""
  if read -r _dr_offer < /dev/tty 2>/dev/null; then true; else _dr_offer="n"; fi
  case "$_dr_offer" in
    [Yy]*)
      info "Preview requested. Launching simulation..."
      info "$STR_DRYRUN_RUNNING"
      printf "\n"

      # Save current wizard state to temp config so subprocess inherits
      # all ENABLE_*, INSTALL_*, plugins, etc. exactly as chosen.
      local _dr_config
      _dr_config="$(mktemp)"
      _SETUP_TMP_FILES+=("$_dr_config")
      save_config "$_dr_config"

      # Build subprocess args
      local _dr_args=("--non-interactive" "--dry-run" "--config=$_dr_config")
      if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
        _dr_args+=("--update")
      fi

      DRY_RUN="true" bash "$0" "${_dr_args[@]}"
      printf "\n"
      info "Preview complete. Continue with actual update?"
      info "$STR_DRYRUN_PROCEED"
      printf "  [Y]es / [N]o ? " >&2
      local _dr_proceed=""
      if read -r _dr_proceed < /dev/tty 2>/dev/null; then true; else _dr_proceed="n"; fi
      case "$_dr_proceed" in
        [Yy]*) ;;
        *)
          info "Setup canceled."
          exit 0
          ;;
      esac
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _has_user_customizations - Check if user modified any kit-managed files
#
# Compares snapshot (what kit deployed) vs current (what's on disk).
# Returns 0 if at least one kit-managed file was modified by the user.
# ---------------------------------------------------------------------------
_has_user_customizations() {
  local claude_dir="$1"
  local snapshot_dir="${claude_dir}/.starter-kit-snapshot"

  [[ -d "$snapshot_dir" ]] || return 0  # no snapshot = can't tell, assume yes

  while IFS= read -r -d '' snap_file; do
    local rel_path="${snap_file#"$snapshot_dir"/}"
    local current_file="${claude_dir}/${rel_path}"
    if [[ ! -f "$current_file" ]]; then
      return 0  # user deleted a kit-managed file
    fi
    if _file_changed "$snap_file" "$current_file"; then
      return 0  # user modified a kit-managed file
    fi
  done < <(find "$snapshot_dir" -type f -print0 2>/dev/null)

  return 1  # no user modifications detected
}
