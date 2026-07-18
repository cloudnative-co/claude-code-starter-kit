#!/bin/bash
# tests/unit/test-deploy-refactor.sh - deploy.sh refactor guards

source "$PROJECT_DIR/lib/colors.sh"
source "$PROJECT_DIR/lib/detect.sh"
source "$PROJECT_DIR/lib/prerequisites.sh"
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
  test_name="deploy: migrated CLAUDE.md composition propagates unreadable input"
  _kit_file="$(mktemp)"
  _missing_file="${_kit_file}.missing"
  _SETUP_TMP_FILES+=("$_kit_file")
  printf '%s\nkit line\n%s\n' "$_KIT_MARKER_BEGIN" "$_KIT_MARKER_END" > "$_kit_file"
  _compose_rc=0
  _compose_migrated_claude_md "$_kit_file" "$_missing_file" >/dev/null 2>&1 \
    || _compose_rc=$?
  if [[ "$_compose_rc" -ne 0 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy: CLAUDE.md build propagates base copy failure under conditional caller"
  if (
    _build_tmp="$(mktemp -d)"
    PROJECT_DIR="$_build_tmp/missing-project"
    LANGUAGE=en
    INSTALL_COMMANDS=false
    INSTALL_SKILLS=false
    ENABLE_CODEX_PLUGIN=false
    _build_rc=0
    build_claude_md_to_file "$_build_tmp/out.md" >/dev/null 2>&1 || _build_rc=$?
    [[ "$_build_rc" -ne 0 && ! -e "$_build_tmp/out.md" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy: markerless migration propagates template filter failure"
  if (
    _deploy_tmp="$(mktemp -d)"
    CLAUDE_DIR="$_deploy_tmp/.claude"
    mkdir -p "$CLAUDE_DIR"
    printf 'existing user content\n' > "$CLAUDE_DIR/CLAUDE.md"
    build_claude_md_to_file() {
      printf '%s\n' \
        '<!-- BEGIN STARTER-KIT-MANAGED -->' '# kit' \
        '<!-- END STARTER-KIT-MANAGED -->' '# User Settings' > "$1"
    }
    _has_kit_markers() { return 1; }
    _awk() { return 42; }
    _build_claude_md_safe >/dev/null 2>&1
  ); then
    fail "$test_name"
  else
    pass "$test_name"
  fi
}

{
  test_name="deploy: settings build propagates JSON builder failure"
  if (
    _build_tmp="$(mktemp -d)"
    build_settings_json() { return 42; }
    _build_rc=0
    build_settings_file "$_build_tmp/settings.json" >/dev/null 2>&1 || _build_rc=$?
    [[ "$_build_rc" -ne 0 && ! -e "$_build_tmp/settings.json" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy: _build_settings_safe propagates invalid bootstrap input"
  if (
    _build_tmp="$(mktemp -d)"
    CLAUDE_DIR="$_build_tmp/.claude"
    mkdir -p "$CLAUDE_DIR"
    printf '{invalid existing settings\n' > "$CLAUDE_DIR/settings.json"
    build_settings_file() { printf '{"kit":true}\n' > "$1"; }
    export KIT_MDM_MANAGED=false
    STR_FRESH_MERGE_SETTINGS=merge
    STR_FRESH_MERGE_SETTINGS_DONE="done"
    _build_rc=0
    _build_settings_safe >/dev/null 2>&1 || _build_rc=$?
    [[ "$_build_rc" -ne 0 \
      && "$(< "$CLAUDE_DIR/settings.json")" == '{invalid existing settings' ]]
  ); then
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
    export KIT_MDM_MANAGED=false
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
    export KIT_MDM_MANAGED=false
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
    export KIT_MDM_MANAGED=false
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

{
  test_name="deploy: MDM manifest requires and records a lowercase policy SHA-256"
  if (
    _manifest_tmp="$(mktemp -d)"
    CLAUDE_DIR="$_manifest_tmp/.claude"
    mkdir -p "$CLAUDE_DIR"
    export KIT_MDM_MANAGED=true
    managed_files_json() { printf '[]'; }
    cleanup_paths_json() { printf '[]'; }
    mdm_absent_files_json() { printf '[]'; }
    _mdm_atomic_replace_authoritative_root_file() { cp "$1" "$2"; }
    unset KIT_MDM_POLICY_SHA256
    write_manifest >/dev/null 2>&1 && exit 1
    KIT_MDM_POLICY_SHA256="$(printf 'A%.0s' {1..64})"
    export KIT_MDM_POLICY_SHA256
    write_manifest >/dev/null 2>&1 && exit 1
    KIT_MDM_POLICY_SHA256="$(printf 'a%.0s' {1..64})"
    export KIT_MDM_POLICY_SHA256
    write_manifest >/dev/null 2>&1 || exit 1
    [[ "$(jq -r '.policy_sha256' \
      "$CLAUDE_DIR/.starter-kit-manifest.json")" == "$KIT_MDM_POLICY_SHA256" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy: non-MDM manifest remains policy-field compatible"
  if (
    _manifest_tmp="$(mktemp -d)"
    CLAUDE_DIR="$_manifest_tmp/.claude"
    mkdir -p "$CLAUDE_DIR"
    export KIT_MDM_MANAGED=false KIT_MDM_POLICY_SHA256=invalid
    managed_files_json() { printf '[]'; }
    cleanup_paths_json() { printf '[]'; }
    write_manifest >/dev/null 2>&1 \
      && jq -e 'has("policy_sha256") | not' \
        "$CLAUDE_DIR/.starter-kit-manifest.json" >/dev/null
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy: MDM manifest replaces untrusted leaf types without following them"
  if (
    _manifest_tmp="$(mktemp -d)"
    _manifest_tmp="$(cd -P "$_manifest_tmp" && pwd -P)"
    CLAUDE_DIR="$_manifest_tmp/.claude"
    mkdir -p "$CLAUDE_DIR"
    _manifest="$CLAUDE_DIR/.starter-kit-manifest.json"
    _outside="$_manifest_tmp/outside.json"
    printf 'outside-sentinel\n' > "$_outside"
    export KIT_MDM_MANAGED=true
    KIT_MDM_POLICY_SHA256="$(printf 'b%.0s' {1..64})"
    export KIT_MDM_POLICY_SHA256
    managed_files_json() { printf '[]'; }
    cleanup_paths_json() { printf '[]'; }
    mdm_absent_files_json() { printf '[]'; }

    ln -s "$_outside" "$_manifest"
    write_manifest >/dev/null 2>&1 || exit 1
    [[ -f "$_manifest" && ! -L "$_manifest" ]] || exit 1
    [[ "$(< "$_outside")" == "outside-sentinel" ]] || exit 1
    [[ "$(test_stat_mode "$_manifest")" == "600" ]] || exit 1

    rm -f "$_manifest"
    mkfifo "$_manifest"
    write_manifest >/dev/null 2>&1 || exit 1
    [[ -f "$_manifest" && ! -L "$_manifest" ]] || exit 1

    rm -f "$_manifest"
    mkdir -p "$_manifest/nested"
    printf 'user-controlled\n' > "$_manifest/nested/value"
    ln -s "$_outside" "$_manifest/nested/external-link"
    write_manifest >/dev/null 2>&1 || exit 1
    [[ -f "$_manifest" && ! -L "$_manifest" ]] || exit 1
    [[ "$(< "$_outside")" == "outside-sentinel" ]] || exit 1
    jq -e --arg policy "$KIT_MDM_POLICY_SHA256" \
      '.mdm_managed == true and .policy_sha256 == $policy' \
      "$_manifest" >/dev/null
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy: MDM manifest refuses a symlinked parent directory"
  if (
    _manifest_tmp="$(mktemp -d)"
    _manifest_tmp="$(cd -P "$_manifest_tmp" && pwd -P)"
    _real_claude="$_manifest_tmp/real-claude"
    CLAUDE_DIR="$_manifest_tmp/claude-link"
    mkdir -p "$_real_claude"
    ln -s "$_real_claude" "$CLAUDE_DIR"
    export KIT_MDM_MANAGED=true
    KIT_MDM_POLICY_SHA256="$(printf 'c%.0s' {1..64})"
    export KIT_MDM_POLICY_SHA256
    managed_files_json() { printf '[]'; }
    cleanup_paths_json() { printf '[]'; }
    mdm_absent_files_json() { printf '[]'; }
    _manifest_rc=0
    write_manifest >/dev/null 2>&1 || _manifest_rc=$?
    [[ "$_manifest_rc" -ne 0 && -L "$CLAUDE_DIR" \
      && ! -e "$_real_claude/.starter-kit-manifest.json" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy: distribution enumeration failures propagate to copy and manifest collection"
  if (
    _dist_tmp="$(mktemp -d)"
    PROJECT_DIR="$_dist_tmp/project"
    CLAUDE_DIR="$_dist_tmp/claude"
    mkdir -p "$PROJECT_DIR/agents" "$CLAUDE_DIR"
    printf 'managed\n' > "$PROJECT_DIR/agents/test.md"
    INSTALL_AGENTS=true INSTALL_RULES=false INSTALL_COMMANDS=false INSTALL_SKILLS=false
    _FEATURE_SCRIPT_ORDER=()
    _SETUP_TMP_FILES=()
    _find_distribution_files() { return 42; }
    _collect_rc=0
    collect_managed_target_files >/dev/null 2>&1 || _collect_rc=$?
    _copy_rc=0
    _copy_distribution_tree "$PROJECT_DIR/agents" "$CLAUDE_DIR/agents" \
      overwrite >/dev/null 2>&1 || _copy_rc=$?
    [[ "$_collect_rc" -ne 0 && "$_copy_rc" -ne 0 ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy: snapshot enumeration failure conservatively reports customization"
  if (
    _custom_tmp="$(mktemp -d)"
    mkdir -p "$_custom_tmp/.starter-kit-snapshot"
    find() { return 42; }
    _has_user_customizations "$_custom_tmp"
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy: failed backup copy removes the partial candidate"
  if (
    _backup_tmp="$(mktemp -d)"
    export HOME="$_backup_tmp/home"
    CLAUDE_DIR="$HOME/.claude"
    export KIT_MDM_MANAGED=true DRY_RUN=false
    mkdir -p "$CLAUDE_DIR" "$HOME/.claude.mdm-backup.20000101000000"
    printf 'managed\n' > "$CLAUDE_DIR/settings.json"
    cp() { mkdir -p "$2"; printf 'partial\n' > "$2/partial"; return 42; }
    _backup_rc=0
    backup_existing >/dev/null 2>&1 || _backup_rc=$?
    _count=0
    for _candidate in "$HOME"/.claude.mdm-backup.*; do
      [[ -e "$_candidate" ]] && _count=$((_count + 1))
    done
    [[ "$_backup_rc" -ne 0 && "$_count" -eq 1 ]] \
      && [[ -z "$_BACKUP_TIMESTAMP" && -z "$_BACKUP_PATH" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}


{
  test_name="deploy: MDM backup marker failure preserves the previous recovery point"
  if (
    _backup_tmp="$(mktemp -d)"
    export HOME="$_backup_tmp/home"
    CLAUDE_DIR="$HOME/.claude"
    export KIT_MDM_MANAGED=true DRY_RUN=false
    mkdir -p "$CLAUDE_DIR" "$HOME/.claude.mdm-backup.20000101000000"
    printf 'managed\n' > "$CLAUDE_DIR/settings.json"
    printf '%s\n' "$HOME/.claude.mdm-backup.20000101000000" \
      > "$CLAUDE_DIR/.starter-kit-last-backup"
    _SETUP_TMP_FILES=()
    _mdm_atomic_replace_managed_file() { return 42; }
    _backup_rc=0
    backup_existing >/dev/null 2>&1 || _backup_rc=$?
    _reserved_count=0
    for _candidate in "$HOME"/.claude.mdm-backup.*; do
      _suffix="${_candidate#"$HOME"/.claude.mdm-backup.}"
      [[ "$_suffix" =~ ^[0-9]{14}(\.[0-9]+)?$ ]] \
        && _reserved_count=$((_reserved_count + 1))
    done
    [[ "$_backup_rc" -ne 0 && "$_reserved_count" -eq 1 ]] \
      && [[ "$(< "$CLAUDE_DIR/.starter-kit-last-backup")" \
        == "$HOME/.claude.mdm-backup.20000101000000" ]] \
      && [[ -z "$_BACKUP_TIMESTAMP" && -z "$_BACKUP_PATH" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy: MDM backup rotation failure keeps the committed new marker"
  if (
    _backup_tmp="$(mktemp -d)"
    export HOME="$_backup_tmp/home"
    CLAUDE_DIR="$HOME/.claude"
    export KIT_MDM_MANAGED=true DRY_RUN=false
    mkdir -p "$CLAUDE_DIR" "$HOME/.claude.mdm-backup.20000101000000"
    printf 'managed\n' > "$CLAUDE_DIR/settings.json"
    _SETUP_TMP_FILES=()
    _mdm_rotate_backups() { return 42; }
    _backup_rc=0
    backup_existing >/dev/null 2>&1 || _backup_rc=$?
    [[ "$_backup_rc" -eq 0 && -d "$_BACKUP_PATH" ]] \
      && [[ "$(< "$CLAUDE_DIR/.starter-kit-last-backup")" == "$_BACKUP_PATH" ]] \
      && [[ -d "$HOME/.claude.mdm-backup.20000101000000" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy: outer transaction publishes only its fixed backup marker"
  if (
    _outer_tmp="$(cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
    export HOME="$_outer_tmp/home"
    CLAUDE_DIR="$HOME/.claude"
    _outer_backup="$HOME/.claude.mdm-backup.20000101000001"
    _outer_old="$HOME/.claude.mdm-backup.20000101000000"
    export KIT_MDM_MANAGED=true KIT_MDM_OUTER_TRANSACTION=true
    export KIT_MDM_OUTER_TRANSACTION_BACKUP="$_outer_backup"
    export DRY_RUN=false
    mkdir -p "$CLAUDE_DIR" "$_outer_backup" "$_outer_old"
    printf 'candidate\n' > "$CLAUDE_DIR/state"
    printf 'previous\n' > "$_outer_backup/state"
    printf 'older\n' > "$_outer_old/state"
    _SETUP_TMP_FILES=()
    _outer_rotate_called=0
    _mdm_rotate_backups() { _outer_rotate_called=1; return 42; }
    _outer_rc=0
    backup_existing >/dev/null 2>&1 || _outer_rc=$?
    [[ "$_outer_rc" -eq 0 && "$_outer_rotate_called" -eq 0 \
      && "$(cat "$CLAUDE_DIR/state")" == candidate \
      && "$(cat "$_outer_backup/state")" == previous \
      && "$(cat "$_outer_old/state")" == older \
      && "$(cat "$CLAUDE_DIR/.starter-kit-last-backup")" \
        == "$_outer_backup" \
      && "$_BACKUP_PATH" == "$_outer_backup" \
      && "$_BACKUP_TIMESTAMP" == 20000101000001 ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy: initial outer transaction preserves absence and rejects stale marker"
  if (
    _outer_tmp="$(cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
    export HOME="$_outer_tmp/home"
    CLAUDE_DIR="$HOME/.claude"
    export KIT_MDM_MANAGED=true KIT_MDM_OUTER_TRANSACTION=true
    export KIT_MDM_OUTER_TRANSACTION_BACKUP=""
    export DRY_RUN=false
    mkdir -p "$CLAUDE_DIR"
    _SETUP_TMP_FILES=()
    _outer_first_rc=0
    backup_existing >/dev/null 2>&1 || _outer_first_rc=$?
    printf 'stale\n' > "$CLAUDE_DIR/.starter-kit-last-backup"
    _outer_stale_rc=0
    backup_existing >/dev/null 2>&1 || _outer_stale_rc=$?
    [[ "$_outer_first_rc" -eq 0 && "$_outer_stale_rc" -ne 0 \
      && "$(cat "$CLAUDE_DIR/.starter-kit-last-backup")" == stale \
      && -z "$_BACKUP_PATH" && -z "$_BACKUP_TIMESTAMP" ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="deploy: outer transaction carrier is internal and fail-closed"
  if (
    _outer_tmp="$(cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
    export HOME="$_outer_tmp/home"
    mkdir -p "$HOME/.claude.mdm-backup.20000101000000" \
      "$_outer_tmp/outside"
    export KIT_MDM_MANAGED=true KIT_MDM_OUTER_TRANSACTION=true
    KIT_MDM_OUTER_TRANSACTION_BACKUP="$HOME/.claude.mdm-backup.20000101000000" \
      _deploy_validate_outer_transaction_carrier \
      || exit 1
    if KIT_MDM_OUTER_TRANSACTION_BACKUP="$_outer_tmp/outside" \
      _deploy_validate_outer_transaction_carrier; then
      exit 1
    fi
    KIT_MDM_OUTER_TRANSACTION=false
    KIT_MDM_OUTER_TRANSACTION_BACKUP=""
    ! _deploy_validate_outer_transaction_carrier \
      && grep -q '_deploy_validate_outer_transaction_carrier' \
        "$PROJECT_DIR/setup.sh"
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}
