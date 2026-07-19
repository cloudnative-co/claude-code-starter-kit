#!/bin/bash
# tests/unit/test-update-refactor.sh - update path refactor guards

# Source production dependencies explicitly so this test is independent of
# state left behind by earlier files in tests/run-unit-tests.sh.
# shellcheck source=lib/colors.sh
source "$PROJECT_DIR/lib/colors.sh"
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
# shellcheck source=lib/dryrun.sh
source "$PROJECT_DIR/lib/dryrun.sh"
# shellcheck source=lib/deploy.sh
source "$PROJECT_DIR/lib/deploy.sh"
# shellcheck source=lib/update.sh
source "$PROJECT_DIR/lib/update.sh"

{
  test_name="update-refactor: hook script updates are registry driven"
  if grep -q 'for feature_name in "${_FEATURE_SCRIPT_ORDER' "$PROJECT_DIR/lib/update.sh" \
    && grep -q '_FEATURE_HAS_SCRIPTS' "$PROJECT_DIR/lib/update.sh" \
    && ! grep -q '_update_hook_feature "memory-persistence"' "$PROJECT_DIR/lib/update.sh" \
    && ! grep -q '_update_hook_feature "strategic-compact"' "$PROJECT_DIR/lib/update.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="update-refactor: hook feature updater does not use eval"
  if ! grep -q 'eval ' "$PROJECT_DIR/lib/update.sh" \
    && grep -q '_UPDATE_UPDATED_FILES+=' "$PROJECT_DIR/lib/update.sh" \
    && grep -q '_UPDATE_SKIPPED_FILES+=' "$PROJECT_DIR/lib/update.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="update-refactor: hook update arrays flow into the run accumulators"
  if grep -q '_update_hook_scripts "$claude_dir" "$snapshot_dir"' "$PROJECT_DIR/lib/update.sh" \
    && grep -q '_UPDATE_ALL_UPDATED_FILES+=(.*_UPDATE_UPDATED_FILES' "$PROJECT_DIR/lib/update.sh" \
    && grep -q '_UPDATE_ALL_SKIPPED_FILES+=(.*_UPDATE_SKIPPED_FILES' "$PROJECT_DIR/lib/update.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="update-refactor: run_update is decomposed into phase functions"
  ok_all=true
  for fn in _update_phase_settings _update_phase_claude_md _update_phase_content \
            _update_phase_hooks _update_phase_snapshot _update_report; do
    if ! grep -q "^${fn}() {" "$PROJECT_DIR/lib/update.sh"; then
      ok_all=false
      break
    fi
    # Each phase must also be invoked from run_update
    if ! grep -q "^  ${fn} " "$PROJECT_DIR/lib/update.sh"; then
      ok_all=false
      break
    fi
  done
  if [[ "$ok_all" == "true" ]]; then
    pass "$test_name"
  else
    fail "$test_name (missing definition or call for $fn)"
  fi
}

{
  test_name="update-refactor: phase comments match the 1-5 progress steps"
  if grep -q '_progress_step 4 5 "Hook scripts"' "$PROJECT_DIR/lib/update.sh" \
    && grep -q '_progress_step 5 5 "Snapshot and summary"' "$PROJECT_DIR/lib/update.sh" \
    && grep -q 'Phase 4/5: Hook scripts' "$PROJECT_DIR/lib/update.sh" \
    && grep -q 'Phase 5/5: Snapshot' "$PROJECT_DIR/lib/update.sh" \
    && ! grep -q 'Phase 6' "$PROJECT_DIR/lib/update.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="update: production simple-command context stops on an internal phase failure"
  _update_tmp="$(mktemp -d)"
  _update_failure_probe="$_update_tmp/after-failure"
  _update_later_probe="$_update_tmp/later-phase"
  _update_rc=0
  PROJECT_DIR="$PROJECT_DIR" \
    UPDATE_FAILURE_PROBE="$_update_failure_probe" \
    UPDATE_LATER_PROBE="$_update_later_probe" \
    "$BASH" --noprofile --norc -c '
      set -euo pipefail
      source "$PROJECT_DIR/setup.sh"
      source "$PROJECT_DIR/lib/update.sh"
      _cleanup_tmp() { :; }
      _prepare_mdm_claude_root() { return 0; }
      _has_user_customizations() { return 1; }
      backup_existing() { return 0; }
      _snapshot_exists() { return 0; }
      _validate_dismissed_features() { return 0; }
      _detect_and_write_pending_features() { return 0; }
      _check_major_upgrade() { return 0; }
      section() { return 0; }
      _update_phase_settings() {
        false
        : > "$UPDATE_FAILURE_PROBE"
      }
      _update_phase_claude_md() { : > "$UPDATE_LATER_PROBE"; }
      _update_phase_content() { return 0; }
      _update_phase_hooks() { return 0; }
      _update_phase_snapshot() { return 0; }
      _update_report() { return 0; }
      UPDATE_MODE=true
      CLAUDE_DIR=/nonexistent-claude
      _CONFIG_ALLOWED_KEYS=""
      STR_UPDATE_TITLE=Update
      setup_deploy
    ' >/dev/null 2>&1 || _update_rc=$?
  if [[ "$_update_rc" -ne 0 \
    && ! -e "$_update_failure_probe" \
    && ! -e "$_update_later_probe" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_update_tmp"
}

{
  test_name="update: MDM CLAUDE phase keeps errexit active inside the real updater"
  _update_tmp="$(mktemp -d)"
  _update_extract_probe="$_update_tmp/after-extract-failure"
  _update_later_probe="$_update_tmp/later-phase"
  _update_rc=0
  PROJECT_DIR="$PROJECT_DIR" \
    UPDATE_TEST_ROOT="$_update_tmp" \
    UPDATE_EXTRACT_PROBE="$_update_extract_probe" \
    UPDATE_LATER_PROBE="$_update_later_probe" \
    "$BASH" --noprofile --norc -c '
      set -euo pipefail
      source "$PROJECT_DIR/setup.sh"
      source "$PROJECT_DIR/lib/update.sh"
      KIT_MDM_MANAGED=true
      DRY_RUN=false
      _RESET_MERGE_PREFS=false
      STR_UPDATE_TITLE=Update
      STR_UPDATE_CLAUDEMD=CLAUDE
      STR_CLAUDEMD_KIT_UPDATED=updated
      _check_major_upgrade() { return 0; }
      section() { return 0; }
      _progress_step() { return 0; }
      info() { return 0; }
      ok() { return 0; }
      _update_phase_settings() { return 0; }
      _update_phase_content() { : > "$UPDATE_LATER_PROBE"; }
      _update_phase_hooks() { return 0; }
      _update_phase_snapshot() { return 0; }
      _update_report() { return 0; }
      build_claude_md_to_file() { printf "fixture\n" > "$1"; }
      _extract_kit_section() {
        false
        : > "$UPDATE_EXTRACT_PROBE"
      }
      _mdm_distribution_target_is_safe() { return 0; }
      _mdm_atomic_replace_managed_file() { return 0; }
      mkdir -p "$UPDATE_TEST_ROOT/claude"
      run_update "$PROJECT_DIR" "$UPDATE_TEST_ROOT/claude"
    ' >/dev/null 2>&1 || _update_rc=$?
  if [[ "$_update_rc" -ne 0 \
    && ! -e "$_update_extract_probe" \
    && ! -e "$_update_later_probe" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_update_tmp"
}

{
  test_name="update: MDM merge entry points propagate destination write failure"
  if (
    _update_tmp="$(mktemp -d)"
    printf '{"value":1}\n' > "$_update_tmp/snapshot.json"
    printf '{"value":2}\n' > "$_update_tmp/current.json"
    printf '{"value":3}\n' > "$_update_tmp/new.json"
    export KIT_MDM_MANAGED=true
    export STR_MERGE_3WAY_STARTING=starting
    _merge3_rc=0
    merge_settings_3way \
      "$_update_tmp/snapshot.json" "$_update_tmp/current.json" \
      "$_update_tmp/new.json" "$_update_tmp/missing/merge.json" \
      >/dev/null 2>&1 || _merge3_rc=$?
    _bootstrap_rc=0
    _merge_settings_bootstrap \
      "$_update_tmp/current.json" "$_update_tmp/new.json" \
      "$_update_tmp/missing/bootstrap.json" \
      >/dev/null 2>&1 || _bootstrap_rc=$?
    [[ "$_merge3_rc" -ne 0 && "$_bootstrap_rc" -ne 0 ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="merge: JSON helper failures propagate instead of becoming null or false"
  if (
    # shellcheck source=lib/colors.sh
    source "$PROJECT_DIR/lib/colors.sh"
    # shellcheck source=lib/merge.sh
    source "$PROJECT_DIR/lib/merge.sh"
    _MERGE_PREFS_LOADED=true
    _MERGE_PREFS='{}'
    jq() { return 42; }
    _key_rc=0 _equal_rc=0 _type_rc=0 _pref_rc=0 _resolve_rc=0
    _json_key_or_null '{}' key >/dev/null 2>&1 || _key_rc=$?
    _json_equal '1' '1' >/dev/null 2>&1 || _equal_rc=$?
    _json_type '1' >/dev/null 2>&1 || _type_rc=$?
    _get_merge_pref key >/dev/null 2>&1 || _pref_rc=$?
    _resolve_conflict_by_type top key null '1' '2' independent \
      >/dev/null 2>&1 || _resolve_rc=$?
    [[ "$_key_rc" -ne 0 && "$_equal_rc" -ne 0 && "$_type_rc" -ne 0 \
      && "$_pref_rc" -ne 0 && "$_resolve_rc" -ne 0 ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="update: settings metadata and migration probes propagate jq errors"
  if (
    _update_tmp="$(mktemp -d)"
    _settings="$_update_tmp/settings.json"
    printf '{}\n' > "$_settings"
    # shellcheck disable=SC2034 # consumed indirectly by the sourced updater
    ENABLE_STATUSLINE=true
    is_true() { return 0; }
    jq() { return 42; }
    _sync_rc=0 _migrate_rc=0 _strip_rc=0
    _sync_settings_metadata "$_settings" >/dev/null 2>&1 || _sync_rc=$?
    _migrate_statusline_command "$_settings" >/dev/null 2>&1 \
      || _migrate_rc=$?
    _strip_retired_hook_entries "$_settings" >/dev/null 2>&1 \
      || _strip_rc=$?
    [[ "$_sync_rc" -ne 0 && "$_migrate_rc" -ne 0 && "$_strip_rc" -ne 0 ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="update: blocked hook destination propagates failure without recording success"
  if (
    _update_tmp="$(mktemp -d)"
    PROJECT_DIR="$_update_tmp/project"
    _claude_dir="$_update_tmp/claude"
    _snapshot_dir="$_update_tmp/snapshot"
    mkdir -p "$PROJECT_DIR/features/test-feature/scripts" "$_claude_dir" "$_snapshot_dir"
    printf '#!/bin/bash\nexit 0\n' > "$PROJECT_DIR/features/test-feature/scripts/test.sh"
    printf 'blocks hook directory\n' > "$_claude_dir/hooks"
    export KIT_MDM_MANAGED=false
    declare -A _FEATURE_HAS_SCRIPTS _FEATURE_FLAGS
    _FEATURE_SCRIPT_ORDER=(test-feature)
    _FEATURE_HAS_SCRIPTS=(["test-feature"]=true)
    _FEATURE_FLAGS=(["test-feature"]=ENABLE_TEST_FEATURE)
    # shellcheck disable=SC2034 # consumed indirectly through _FEATURE_FLAGS
    ENABLE_TEST_FEATURE=true
    _UPDATE_ALL_UPDATED_FILES=()
    _UPDATE_ALL_SKIPPED_FILES=()
    _update_rc=0
    _update_phase_hooks "$_claude_dir" "$_snapshot_dir" >/dev/null 2>&1 \
      || _update_rc=$?
    [[ "$_update_rc" -ne 0 && "${#_UPDATE_ALL_UPDATED_FILES[@]}" -eq 0 ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="update: content and hook enumeration failures propagate"
  if (
    _update_tmp="$(mktemp -d)"
    PROJECT_DIR="$_update_tmp/project"
    _claude_dir="$_update_tmp/claude"
    _snapshot_dir="$_update_tmp/snapshot"
    mkdir -p "$PROJECT_DIR/agents" "$PROJECT_DIR/features/test/scripts" \
      "$_claude_dir" "$_snapshot_dir"
    printf 'managed\n' > "$PROJECT_DIR/agents/test.md"
    printf '#!/bin/bash\n' > "$PROJECT_DIR/features/test/scripts/test.sh"
    # shellcheck disable=SC2034 # consumed indirectly by update phase
    INSTALL_AGENTS=true INSTALL_RULES=false INSTALL_COMMANDS=false INSTALL_SKILLS=false
    declare -A _FEATURE_HAS_SCRIPTS _FEATURE_FLAGS
    _FEATURE_SCRIPT_ORDER=(test)
    _FEATURE_HAS_SCRIPTS=([test]=true)
    _FEATURE_FLAGS=([test]=ENABLE_TEST)
    # shellcheck disable=SC2034 # consumed through _FEATURE_FLAGS
    ENABLE_TEST=true
    _SETUP_TMP_FILES=()
    _find_update_content_files() { return 42; }
    _count_rc=0
    _count_update_content_files >/dev/null 2>&1 || _count_rc=$?
    _content_rc=0
    _update_phase_content "$PROJECT_DIR" "$_claude_dir" "$_snapshot_dir" \
      >/dev/null 2>&1 || _content_rc=$?
    _hook_rc=0
    _update_hook_feature test "$PROJECT_DIR/features/test/scripts" \
      "$_claude_dir" "$_snapshot_dir" >/dev/null 2>&1 || _hook_rc=$?
    [[ "$_count_rc" -ne 0 && "$_content_rc" -ne 0 && "$_hook_rc" -ne 0 ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="update: malformed non-MDM manifest cannot false-success retired cleanup"
  if (
    _update_tmp="$(mktemp -d)"
    _claude_dir="$_update_tmp/claude"
    _snapshot_dir="$_update_tmp/snapshot"
    mkdir -p "$_claude_dir" "$_snapshot_dir"
    printf '{malformed\n' > "$_claude_dir/.starter-kit-manifest.json"
    export KIT_MDM_MANAGED=false
    _mdm_reconcile_absent_managed_files() { return 0; }
    _cleanup_rc=0
    _remove_retired_managed_files "$_claude_dir" "$_snapshot_dir" \
      >/dev/null 2>&1 || _cleanup_rc=$?
    [[ "$_cleanup_rc" -ne 0 ]]
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="update: retired inventory is streamed to jq without a here-string"
  _retired_cleanup_body="$(declare -f _remove_retired_managed_files)"
  if [[ "$_retired_cleanup_body" == *"printf '%s\\n' \"\$kit_rel_json\""* \
    && "$_retired_cleanup_body" != *"<<< \"\$kit_rel_json\""* ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="update-refactor: merge entry points share the _resolve_key_3way core"
  core_calls="$(grep -c '_resolve_key_3way "' "$PROJECT_DIR/lib/merge.sh" || true)"
  if grep -q '_resolve_key_3way() {' "$PROJECT_DIR/lib/merge.sh" \
    && grep -q '_resolve_key_3way "top"' "$PROJECT_DIR/lib/merge.sh" \
    && grep -q '_resolve_key_3way "nested"' "$PROJECT_DIR/lib/merge.sh" \
    && grep -q '_resolve_key_3way "bootstrap"' "$PROJECT_DIR/lib/merge.sh" \
    && [[ "$core_calls" -eq 3 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="update-refactor: has(\$k) extraction is centralized in _json_key_or_null"
  helper_uses="$(grep -c '_json_key_or_null "' "$PROJECT_DIR/lib/merge.sh" || true)"
  inline_has="$(grep -c "if has(\$k) then" "$PROJECT_DIR/lib/merge.sh" || true)"
  if [[ "$helper_uses" -ge 8 ]] && [[ "$inline_has" -eq 0 ]]; then
    pass "$test_name"
  else
    fail "$test_name (helper_uses=$helper_uses inline_has=$inline_has)"
  fi
}

{
  test_name="update: user-section content detection drives the rules/user-* tip"
  _ust_tmp="$(mktemp -d)"
  _SETUP_TMP_FILES+=("$_ust_tmp")
  # scaffold only (heading + placeholder comment) → no tip
  cat > "$_ust_tmp/scaffold.md" <<'MD'
<!-- BEGIN STARTER-KIT-MANAGED -->
# Global Settings
<!-- END STARTER-KIT-MANAGED -->

# User Settings

<!-- Add your custom instructions below -->
MD
  # real user content → tip
  cat > "$_ust_tmp/content.md" <<'MD'
<!-- BEGIN STARTER-KIT-MANAGED -->
# Global Settings
<!-- END STARTER-KIT-MANAGED -->

# ユーザー設定

- 個人ルールがここにある
MD
  # markerless → no tip (migration path handles it)
  printf '# my own file\n- stuff\n' > "$_ust_tmp/markerless.md"
  _ust_rc_scaffold=0; _claude_md_user_section_has_content "$_ust_tmp/scaffold.md" || _ust_rc_scaffold=$?
  _ust_rc_content=0; _claude_md_user_section_has_content "$_ust_tmp/content.md" || _ust_rc_content=$?
  _ust_rc_markerless=0; _claude_md_user_section_has_content "$_ust_tmp/markerless.md" || _ust_rc_markerless=$?
  if [[ "$_ust_rc_scaffold" -ne 0 ]] && [[ "$_ust_rc_content" -eq 0 ]] && [[ "$_ust_rc_markerless" -ne 0 ]]; then
    pass "$test_name"
  else
    fail "$test_name (scaffold=$_ust_rc_scaffold content=$_ust_rc_content markerless=$_ust_rc_markerless)"
  fi
}
