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
