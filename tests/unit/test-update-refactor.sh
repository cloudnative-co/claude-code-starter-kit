#!/bin/bash
# tests/unit/test-update-refactor.sh - update path refactor guards

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
