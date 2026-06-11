#!/bin/bash
# tests/unit/test-update-refactor.sh - update path refactor guards

{
  test_name="update-refactor: hook script updates are registry driven"
  if grep -q 'for feature_name in "${_FEATURE_ORDER' "$PROJECT_DIR/lib/update.sh" \
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
  test_name="update-refactor: run_update receives hook update arrays explicitly"
  if grep -q '_update_hook_scripts "$claude_dir" "$snapshot_dir"' "$PROJECT_DIR/lib/update.sh" \
    && grep -q 'updated_files+=(.*_UPDATE_UPDATED_FILES' "$PROJECT_DIR/lib/update.sh" \
    && grep -q 'skipped_files+=(.*_UPDATE_SKIPPED_FILES' "$PROJECT_DIR/lib/update.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}
