#!/bin/bash
# MDM_TEST_BASH_MIN=4
# MDM managed writes must never follow user-controlled links outside CLAUDE_DIR.
# shellcheck disable=SC2034

# shellcheck source=wizard/wizard.sh
source "$PROJECT_DIR/wizard/wizard.sh"
# shellcheck source=lib/colors.sh
source "$PROJECT_DIR/lib/colors.sh"
# shellcheck source=lib/progress.sh
source "$PROJECT_DIR/lib/progress.sh"
# shellcheck source=lib/prerequisites.sh
source "$PROJECT_DIR/lib/prerequisites.sh"
# shellcheck source=lib/features.sh
source "$PROJECT_DIR/lib/features.sh"
# shellcheck source=lib/template.sh
source "$PROJECT_DIR/lib/template.sh"
# shellcheck source=lib/json-builder.sh
source "$PROJECT_DIR/lib/json-builder.sh"
# shellcheck source=lib/snapshot.sh
source "$PROJECT_DIR/lib/snapshot.sh"
# shellcheck source=lib/merge.sh
source "$PROJECT_DIR/lib/merge.sh"
# shellcheck source=lib/update.sh
source "$PROJECT_DIR/lib/update.sh"
# shellcheck source=lib/deploy.sh
source "$PROJECT_DIR/lib/deploy.sh"
load_strings en

(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  CLAUDE_DIR="$_tmp/claude"
  mkdir -p "$CLAUDE_DIR" "$_tmp/external"
  printf 'external claude\n' > "$_tmp/external/CLAUDE.md"
  printf '{"external":true}\n' > "$_tmp/external/settings.json"
  ln -s "$_tmp/external/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
  ln -s "$_tmp/external/settings.json" "$CLAUDE_DIR/settings.json"
  INSTALL_COMMANDS=false
  INSTALL_SKILLS=false
  ENABLE_CODEX_PLUGIN=false
  _SETUP_TMP_FILES=()
  _claude_rc=0
  build_claude_md >/dev/null 2>&1 || _claude_rc=$?
  _settings_rc=0
  _build_settings_managed_file "$CLAUDE_DIR/settings.json" \
    >/dev/null 2>&1 || _settings_rc=$?
  if [[ "$_claude_rc" -ne 0 && "$_settings_rc" -ne 0 ]] \
    && [[ "$(< "$_tmp/external/CLAUDE.md")" == "external claude" ]] \
    && [[ "$(jq -r '.external' "$_tmp/external/settings.json")" == true ]] \
    && [[ -L "$CLAUDE_DIR/CLAUDE.md" && -L "$CLAUDE_DIR/settings.json" ]]; then
    pass "mdm-write: fresh CLAUDE/settings symlink target を上書きしない"
  else
    fail "mdm-write: fresh CLAUDE/settings が symlink を追従した"
  fi
  rm -rf "$_tmp"
)

(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  CLAUDE_DIR="$_tmp/claude"
  mkdir -p "$CLAUDE_DIR" "$_tmp/external"
  printf 'external claude\n' > "$_tmp/external/CLAUDE.md"
  printf '{"external":true}\n' > "$_tmp/external/settings.json"
  ln "$_tmp/external/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
  ln "$_tmp/external/settings.json" "$CLAUDE_DIR/settings.json"
  INSTALL_COMMANDS=false
  INSTALL_SKILLS=false
  ENABLE_CODEX_PLUGIN=false
  _SETUP_TMP_FILES=()
  _claude_rc=0
  build_claude_md >/dev/null 2>&1 || _claude_rc=$?
  _settings_rc=0
  _build_settings_managed_file "$CLAUDE_DIR/settings.json" \
    >/dev/null 2>&1 || _settings_rc=$?
  if [[ "$_claude_rc" -eq 0 && "$_settings_rc" -eq 0 ]] \
    && [[ "$(< "$_tmp/external/CLAUDE.md")" == "external claude" ]] \
    && [[ "$(jq -r '.external' "$_tmp/external/settings.json")" == true ]] \
    && grep -qF '<!-- BEGIN STARTER-KIT-MANAGED -->' "$CLAUDE_DIR/CLAUDE.md" \
    && [[ "$(jq -r 'has("external")' "$CLAUDE_DIR/settings.json")" == false ]]; then
    pass "mdm-write: fresh CLAUDE/settings hardlink を別inodeへ置換"
  else
    fail "mdm-write: fresh CLAUDE/settings が hardlink 参照先を変更した"
  fi
  rm -rf "$_tmp"
)

(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  CLAUDE_DIR="$_tmp/claude"
  mkdir -p "$CLAUDE_DIR/.starter-kit-snapshot" "$_tmp/external"
  printf 'external claude\n' > "$_tmp/external/CLAUDE.md"
  ln -s "$_tmp/external/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
  printf '%s\n' \
    '<!-- BEGIN STARTER-KIT-MANAGED -->' '# desired' \
    '<!-- END STARTER-KIT-MANAGED -->' '' '# User Settings' > "$_tmp/new.md"
  _SETUP_TMP_FILES=()
  LANGUAGE=en
  _rc=0
  _update_claude_md "$CLAUDE_DIR/CLAUDE.md" \
    "$CLAUDE_DIR/.starter-kit-snapshot/CLAUDE.md" "$_tmp/new.md" \
    >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 && "$(< "$_tmp/external/CLAUDE.md")" == "external claude" ]] \
    && [[ -L "$CLAUDE_DIR/CLAUDE.md" ]]; then
    pass "mdm-write: update markerless CLAUDE symlink target を上書きしない"
  else
    fail "mdm-write: update markerless CLAUDE が symlink を追従した"
  fi
  rm -rf "$_tmp"
)

(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  CLAUDE_DIR="$_tmp/claude"
  mkdir -p "$CLAUDE_DIR" "$_tmp/external-snapshot"
  printf '{"desired":true}\n' > "$CLAUDE_DIR/settings.json"
  printf 'external snapshot\n' > "$_tmp/external-snapshot/personal.md"
  ln -s "$_tmp/external-snapshot" "$CLAUDE_DIR/.starter-kit-snapshot"
  _SETUP_TMP_FILES=()
  _rc=0
  _write_snapshot "$CLAUDE_DIR" "$CLAUDE_DIR/settings.json" \
    >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && [[ "$(< "$_tmp/external-snapshot/personal.md")" == "external snapshot" ]] \
    && [[ -d "$CLAUDE_DIR/.starter-kit-snapshot" ]] \
    && [[ ! -L "$CLAUDE_DIR/.starter-kit-snapshot" ]] \
    && [[ -f "$CLAUDE_DIR/.starter-kit-snapshot/settings.json" ]]; then
    pass "mdm-write: snapshot dir symlink をunlinkして実ディレクトリへ収束"
  else
    fail "mdm-write: snapshot dir symlink の参照先を変更した"
  fi
  rm -rf "$_tmp"
)

(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  CLAUDE_DIR="$_tmp/claude"
  mkdir -p "$CLAUDE_DIR" "$_tmp/external"
  printf 'external manifest\n' > "$_tmp/external/manifest.json"
  ln -s "$_tmp/external/manifest.json" "$CLAUDE_DIR/.starter-kit-manifest.json"
  _SETUP_TMP_FILES=()
  collect_managed_target_files() { _MANAGED_TARGET_FILES=(); }
  _rc=0
  write_manifest >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]] \
    && [[ "$(< "$_tmp/external/manifest.json")" == "external manifest" ]] \
    && [[ -L "$CLAUDE_DIR/.starter-kit-manifest.json" ]]; then
    pass "mdm-write: manifest symlink target を上書きしない"
  else
    fail "mdm-write: manifest が symlink を追従した"
  fi
  rm -rf "$_tmp"
)

(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  CLAUDE_DIR="$_tmp/claude"
  mkdir -p "$CLAUDE_DIR"
  printf '{"sentinel":true}\n' > "$CLAUDE_DIR/.starter-kit-manifest.json"
  _SETUP_TMP_FILES=()
  managed_files_json() { printf 'invalid-json'; }
  cleanup_paths_json() { printf '[]'; }
  mdm_absent_files_json() { printf '[]'; }
  _rc=0
  write_manifest >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]] \
    && [[ "$(< "$CLAUDE_DIR/.starter-kit-manifest.json")" == '{"sentinel":true}' ]]; then
    pass "mdm-write: manifest render 失敗時も既存 manifest を保持"
  else
    fail "mdm-write: manifest render 失敗で既存 manifest を破損"
  fi
  rm -rf "$_tmp"
)

(
  _tmp="$(mktemp -d)"
  printf 'external config\n' > "$_tmp/external.conf"
  ln -s "$_tmp/external.conf" "$_tmp/config.conf"
  PROFILE=standard
  _rc=0
  save_config "$_tmp/config.conf" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && [[ "$(< "$_tmp/external.conf")" == "external config" ]] \
    && [[ -f "$_tmp/config.conf" && ! -L "$_tmp/config.conf" ]] \
    && grep -q '^PROFILE="standard"$' "$_tmp/config.conf"; then
    pass "mdm-write: saved config は symlink を追従せずatomic replace"
  else
    fail "mdm-write: saved config が symlink を追従した"
  fi
  rm -rf "$_tmp"
)

(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  PROJECT_DIR="$_tmp/project"
  CLAUDE_DIR="$_tmp/claude"
  mkdir -p "$PROJECT_DIR/agents" "$CLAUDE_DIR/agents" \
    "$_tmp/snapshot/agents" "$_tmp/external"
  printf 'desired agent\n' > "$PROJECT_DIR/agents/example.md"
  printf 'external agent\n' > "$_tmp/external/example.md"
  ln -s "$_tmp/external/example.md" "$CLAUDE_DIR/agents/example.md"
  INSTALL_AGENTS=true
  INSTALL_RULES=false
  INSTALL_COMMANDS=false
  INSTALL_SKILLS=false
  _UPDATE_ALL_UPDATED_FILES=()
  _UPDATE_ALL_SKIPPED_FILES=()
  _rc=0
  _update_phase_content "$PROJECT_DIR" "$CLAUDE_DIR" "$_tmp/snapshot" \
    >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]] \
    && [[ "$(< "$_tmp/external/example.md")" == "external agent" ]] \
    && [[ -L "$CLAUDE_DIR/agents/example.md" ]]; then
    pass "mdm-write: update content の unsafe target を非0で伝播"
  else
    fail "mdm-write: update content の unsafe target が skip 扱いになった"
  fi
  rm -rf "$_tmp"
)

(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  PROJECT_DIR="$_tmp/project"
  CLAUDE_DIR="$_tmp/claude"
  mkdir -p "$PROJECT_DIR/features/test-feature/scripts" \
    "$CLAUDE_DIR/hooks/test-feature" "$_tmp/snapshot/hooks/test-feature" \
    "$_tmp/external"
  printf '#!/bin/bash\nprintf "desired hook\\n"\n' \
    > "$PROJECT_DIR/features/test-feature/scripts/test.sh"
  printf 'external hook\n' > "$_tmp/external/test.sh"
  ln -s "$_tmp/external/test.sh" "$CLAUDE_DIR/hooks/test-feature/test.sh"
  _FEATURE_SCRIPT_ORDER=(test-feature)
  _FEATURE_HAS_SCRIPTS=(["test-feature"]=true)
  _FEATURE_FLAGS=(["test-feature"]=ENABLE_TEST_FEATURE)
  ENABLE_TEST_FEATURE=true
  _UPDATE_ALL_UPDATED_FILES=()
  _UPDATE_ALL_SKIPPED_FILES=()
  _rc=0
  _update_phase_hooks "$CLAUDE_DIR" "$_tmp/snapshot" \
    >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]] \
    && [[ "$(< "$_tmp/external/test.sh")" == "external hook" ]] \
    && [[ -L "$CLAUDE_DIR/hooks/test-feature/test.sh" ]]; then
    pass "mdm-write: update hook の unsafe target を非0で伝播"
  else
    fail "mdm-write: update hook の unsafe target が skip 扱いになった"
  fi
  rm -rf "$_tmp"
)
