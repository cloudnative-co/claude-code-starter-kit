#!/bin/bash
# tests/unit/test-deploy-refactor.sh - deploy.sh refactor guards

source "$PROJECT_DIR/lib/colors.sh"
source "$PROJECT_DIR/lib/template.sh"
source "$PROJECT_DIR/lib/features.sh"
source "$PROJECT_DIR/lib/json-builder.sh"
source "$PROJECT_DIR/lib/snapshot.sh"
source "$PROJECT_DIR/lib/merge.sh"
source "$PROJECT_DIR/lib/dryrun.sh"

declare -a _SETUP_TMP_FILES=()
CLAUDE_DIR="$(mktemp -d)"
_SETUP_TMP_FILES+=("$CLAUDE_DIR")
LANGUAGE="en"
# shellcheck disable=SC2034  # globals are consumed by sourced deploy.sh
INSTALL_SKILLS="false"
# shellcheck disable=SC2034  # globals are consumed by sourced deploy.sh
ENABLE_CODEX_PLUGIN="false"

source "$PROJECT_DIR/lib/deploy.sh"

{
  test_name="deploy-refactor: build_claude_md delegates to build_claude_md_to_file"
  if grep -q 'build_claude_md_to_file "$out"' "$PROJECT_DIR/lib/deploy.sh" \
    && [[ "$(grep -c 'cp -a "$base" "$out"' "$PROJECT_DIR/lib/deploy.sh")" == "1" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy-refactor: Claude semver lookup is cached"
  _semver_tmp="$(mktemp -d)"
  _SETUP_TMP_FILES+=("$_semver_tmp")
  cat >"$_semver_tmp/claude" <<'EOF'
#!/bin/bash
count_file="${CLAUDE_VERSION_COUNT_FILE:?}"
count="$(cat "$count_file" 2>/dev/null || echo 0)"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
printf 'Claude Code 2.1.90\n'
EOF
  chmod +x "$_semver_tmp/claude"
  CLAUDE_VERSION_COUNT_FILE="$_semver_tmp/count"
  export CLAUDE_VERSION_COUNT_FILE
  _old_path="$PATH"
  PATH="$_semver_tmp:$PATH"
  hash -r 2>/dev/null || true
  _CLAUDE_SEMVER_CACHE=""
  _CLAUDE_SEMVER_CACHE_SET=false
  printf '0\n' > "$CLAUDE_VERSION_COUNT_FILE"
  _claude_cli_semver >/dev/null
  _claude_cli_semver >/dev/null
  PATH="$_old_path"
  hash -r 2>/dev/null || true
  if [[ "$(cat "$CLAUDE_VERSION_COUNT_FILE")" == "1" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy-refactor: migrated CLAUDE.md composition preserves kit and user sections"
  _kit_file="$(mktemp)"
  _existing_file="$(mktemp)"
  _SETUP_TMP_FILES+=("$_kit_file" "$_existing_file")
  printf '%s\nkit line\n%s\n' "$_KIT_MARKER_BEGIN" "$_KIT_MARKER_END" > "$_kit_file"
  printf 'user line 1\nuser line 2\n' > "$_existing_file"
  _composed="$(_compose_migrated_claude_md "$_kit_file" "$_existing_file")"
  if [[ "$_composed" == *"kit line"* ]] \
    && [[ "$_composed" == *"$(_user_section_heading)"* ]] \
    && [[ "$_composed" == *"user line 1"* ]] \
    && [[ "$_composed" == *"user line 2"* ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy: manifest render failure preserves the existing manifest"
  if (
    _manifest_tmp="$(mktemp -d)"
    CLAUDE_DIR="$_manifest_tmp/.claude"
    mkdir -p "$CLAUDE_DIR"
    printf '{"sentinel":true}\n' > "$CLAUDE_DIR/.starter-kit-manifest.json"
    KIT_MDM_MANAGED=false
    managed_files_json() { printf 'invalid-json'; }
    cleanup_paths_json() { printf '[]'; }
    _manifest_rc=0
    write_manifest >/dev/null 2>&1 || _manifest_rc=$?
    [[ "$_manifest_rc" -ne 0 ]] \
      && [[ "$(< "$CLAUDE_DIR/.starter-kit-manifest.json")" == '{"sentinel":true}' ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy: manifest input producer failures preserve the existing manifest"
  if (
    _manifest_tmp="$(mktemp -d)"
    CLAUDE_DIR="$_manifest_tmp/.claude"
    mkdir -p "$CLAUDE_DIR"
    printf '{"sentinel":true}\n' > "$CLAUDE_DIR/.starter-kit-manifest.json"
    KIT_MDM_MANAGED=false
    managed_files_json() { printf '[]'; return 42; }
    cleanup_paths_json() { printf '[]'; }
    _manifest_rc=0
    write_manifest >/dev/null 2>&1 || _manifest_rc=$?
    [[ "$_manifest_rc" -ne 0 ]] || exit 1
    [[ "$(< "$CLAUDE_DIR/.starter-kit-manifest.json")" == '{"sentinel":true}' ]] || exit 1
    managed_files_json() { printf '[]'; }
    cleanup_paths_json() { printf '[]'; return 43; }
    _manifest_rc=0
    write_manifest >/dev/null 2>&1 || _manifest_rc=$?
    [[ "$_manifest_rc" -ne 0 ]] \
      && [[ "$(< "$CLAUDE_DIR/.starter-kit-manifest.json")" == '{"sentinel":true}' ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy: manifest destination must be a regular non-symlink file"
  if (
    _manifest_tmp="$(mktemp -d)"
    CLAUDE_DIR="$_manifest_tmp/.claude"
    mkdir -p "$CLAUDE_DIR/.starter-kit-manifest.json"
    KIT_MDM_MANAGED=false
    managed_files_json() { printf '[]'; }
    cleanup_paths_json() { printf '[]'; }
    _manifest_rc=0
    write_manifest >/dev/null 2>&1 || _manifest_rc=$?
    [[ "$_manifest_rc" -ne 0 ]] \
      && [[ -d "$CLAUDE_DIR/.starter-kit-manifest.json" ]] \
      && [[ -z "$(find "$CLAUDE_DIR/.starter-kit-manifest.json" -mindepth 1 -print -quit)" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}
