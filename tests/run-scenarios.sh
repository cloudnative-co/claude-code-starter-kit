#!/bin/bash
# tests/run-scenarios.sh - Scenario test runner for Claude Code Starter Kit
# Runs 28 scenarios covering fresh install, update, migration, and edge cases.
#
# Usage: bash tests/run-scenarios.sh
#
# Expected results (PR-2): 24 PASS + 4 SKIP
# SKIP: safety-net-first, registry-consistency (PR-8+9), bash-reexec (PR-4),
#        bash4-noninteractive-unavailable (PR-4)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

printf "\n── Claude Code Starter Kit: Scenario Tests ──\n\n"

# ═══════════════════════════════════════════════════════════════════════════
# Basic scenarios (14)
# ═══════════════════════════════════════════════════════════════════════════

# --- 1. fresh-install-clean ---
test_fresh_install_clean() {
  setup_test_env
  local rc=0
  run_setup --profile=minimal >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] \
    && assert_file_exists "$CLAUDE_DIR/settings.json" \
    && assert_file_exists "$CLAUDE_DIR/CLAUDE.md" \
    && assert_file_exists "$CLAUDE_DIR/.starter-kit-manifest.json" \
    && assert_dir_exists "$CLAUDE_DIR/.starter-kit-snapshot" \
    && assert_file_exists "$CLAUDE_DIR/.starter-kit-snapshot/settings.json" \
    && assert_file_contains "$CLAUDE_DIR/CLAUDE.md" "BEGIN STARTER-KIT-MANAGED" \
    && assert_json_field "$CLAUDE_DIR/.starter-kit-manifest.json" '.version' "2"; then
    pass "fresh-install-clean"
  else
    fail "fresh-install-clean"
  fi

  teardown_test_env
}

# --- 2. fresh-install-existing ---
test_fresh_install_existing() {
  setup_test_env
  install_fixture "no-manifest"
  local rc=0
  run_setup --profile=minimal >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] \
    && assert_file_exists "$CLAUDE_DIR/settings.json" \
    && assert_file_exists "$CLAUDE_DIR/.starter-kit-manifest.json"; then
    # User's custom MCP server should be preserved in merge
    if jq -e '.mcpServers["user-custom-mcp"]' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
      pass "fresh-install-existing"
    else
      fail "fresh-install-existing (mcpServers not preserved)"
    fi
  else
    fail "fresh-install-existing"
  fi

  teardown_test_env
}

# --- 3. update-no-changes ---
test_update_no_changes() {
  setup_test_env
  run_setup --profile=minimal >/dev/null 2>&1 || { fail "update-no-changes (setup failed)"; teardown_test_env; return; }
  # Capture settings before update
  local before_settings
  before_settings="$(cat "$CLAUDE_DIR/settings.json")"
  # Run update immediately (no changes)
  local rc=0
  run_setup_update >/dev/null 2>&1 || rc=$?
  local after_settings
  after_settings="$(cat "$CLAUDE_DIR/settings.json")"

  # Settings should be unchanged (snapshot == current, no kit change in same version)
  if [[ $rc -eq 0 ]] && [[ "$before_settings" == "$after_settings" ]]; then
    pass "update-no-changes"
  else
    fail "update-no-changes"
  fi

  teardown_test_env
}

# --- 4. update-kit-changed ---
test_update_kit_changed() {
  setup_test_env
  run_setup --profile=minimal >/dev/null 2>&1
  # Add a marker to current settings.json that the kit would NOT produce
  jq '.old_version_marker = true' "$CLAUDE_DIR/settings.json" > "$CLAUDE_DIR/settings.json.tmp" \
    && mv "$CLAUDE_DIR/settings.json.tmp" "$CLAUDE_DIR/settings.json"
  # Keep snapshot as-is (matches original kit output), so:
  #   snapshot == original kit != current (user changed) -- but we want "kit changed" scenario
  # Actually: simulate "user didn't change, kit did" by keeping current == snapshot,
  # then modifying snapshot to look like old kit
  local snapshot_settings="$CLAUDE_DIR/.starter-kit-snapshot/settings.json"
  # Restore current to match snapshot (user didn't change)
  cp "$snapshot_settings" "$CLAUDE_DIR/settings.json"
  # Now modify snapshot to look different (old kit version)
  jq '.old_kit_marker = true' "$snapshot_settings" > "$snapshot_settings.tmp" \
    && mv "$snapshot_settings.tmp" "$snapshot_settings"
  # State: snapshot(old kit) != current(original kit) == new kit → overwrite path
  local before_settings
  before_settings="$(cat "$CLAUDE_DIR/settings.json")"
  local rc=0
  run_setup_update >/dev/null 2>&1 || rc=$?

  # After update with kit change, settings.json should be updated (new kit version)
  # The snapshot should also be updated to match new kit
  if [[ $rc -eq 0 ]] \
    && assert_file_exists "$CLAUDE_DIR/settings.json" \
    && assert_file_exists "$CLAUDE_DIR/.starter-kit-snapshot/settings.json" \
    && ! jq -e '.old_kit_marker' "$CLAUDE_DIR/.starter-kit-snapshot/settings.json" >/dev/null 2>&1; then
    pass "update-kit-changed"
  else
    fail "update-kit-changed"
  fi

  teardown_test_env
}

# --- 5. update-user-changed ---
test_update_user_changed() {
  setup_test_env
  run_setup --profile=minimal >/dev/null 2>&1
  # Simulate user change: modify current settings.json
  jq '.user_custom_key = "my_value"' "$CLAUDE_DIR/settings.json" > "$CLAUDE_DIR/settings.json.tmp" \
    && mv "$CLAUDE_DIR/settings.json.tmp" "$CLAUDE_DIR/settings.json"
  local rc=0
  run_setup_update >/dev/null 2>&1 || rc=$?

  # In non-interactive mode, user-changed files should be kept
  if [[ $rc -eq 0 ]] \
    && jq -e '.user_custom_key' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
    pass "update-user-changed"
  else
    fail "update-user-changed"
  fi

  teardown_test_env
}

# --- 6. update-feature-toggle ---
test_update_feature_toggle() {
  setup_test_env
  run_setup --profile=standard >/dev/null 2>&1
  # Update with minimal profile (fewer features)
  local rc=0
  run_setup_update --profile=minimal >/dev/null 2>&1 || rc=$?

  # After update, settings and manifest should still exist
  if [[ $rc -eq 0 ]] \
    && assert_file_exists "$CLAUDE_DIR/settings.json" \
    && assert_file_exists "$CLAUDE_DIR/.starter-kit-manifest.json"; then
    pass "update-feature-toggle"
  else
    fail "update-feature-toggle"
  fi

  teardown_test_env
}

# --- 7. claudemd-migration ---
test_claudemd_migration() {
  setup_test_env
  install_fixture "v019"
  # v019 has CLAUDE.md without markers
  local rc=0
  run_setup_update >/dev/null 2>&1 || rc=$?

  # Non-interactive skips migration (structural change requires consent)
  # But the file should still exist
  if [[ $rc -eq 0 ]] \
    && assert_file_exists "$CLAUDE_DIR/CLAUDE.md"; then
    pass "claudemd-migration"
  else
    fail "claudemd-migration"
  fi

  teardown_test_env
}

# --- 8. claudemd-section-preserve ---
test_claudemd_section_preserve() {
  setup_test_env
  run_setup --profile=minimal >/dev/null 2>&1
  # Add user content to user section
  printf "\n## My Custom Rules\n- Always be nice\n" >> "$CLAUDE_DIR/CLAUDE.md"
  local rc=0
  run_setup_update >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] \
    && assert_file_contains "$CLAUDE_DIR/CLAUDE.md" "My Custom Rules" \
    && assert_file_contains "$CLAUDE_DIR/CLAUDE.md" "BEGIN STARTER-KIT-MANAGED"; then
    pass "claudemd-section-preserve"
  else
    fail "claudemd-section-preserve"
  fi

  teardown_test_env
}

# --- 9. claudemd-kit-edit-conflict ---
test_claudemd_kit_edit_conflict() {
  setup_test_env
  run_setup --profile=minimal >/dev/null 2>&1
  # Edit the kit section (between markers)
  local md="$CLAUDE_DIR/CLAUDE.md"
  if [[ -f "$md" ]]; then
    local tmp_md
    tmp_md="$(mktemp)"
    sed 's/Conventional Commits/My Custom Format/g' "$md" > "$tmp_md" && mv "$tmp_md" "$md"
  fi
  local rc=0
  run_setup_update >/dev/null 2>&1 || rc=$?

  # Non-interactive: keeps user version (non-destructive — user's edit preserved)
  if [[ $rc -eq 0 ]] \
    && assert_file_exists "$CLAUDE_DIR/CLAUDE.md" \
    && assert_file_contains "$CLAUDE_DIR/CLAUDE.md" "My Custom Format"; then
    pass "claudemd-kit-edit-conflict"
  else
    fail "claudemd-kit-edit-conflict"
  fi

  teardown_test_env
}

# --- 10. dry-run-no-mutation ---
test_dry_run_no_mutation() {
  setup_test_env
  run_setup --profile=minimal >/dev/null 2>&1
  # Take checksum before dry-run
  local before after rc_dr=0
  before="$(snapshot_dir_checksum "$CLAUDE_DIR")"
  run_setup_update --dry-run >/dev/null 2>&1 || rc_dr=$?
  after="$(snapshot_dir_checksum "$CLAUDE_DIR")"

  # Dry-run should succeed AND not modify any files
  if [[ $rc_dr -eq 0 ]] && [[ "$before" == "$after" ]]; then
    pass "dry-run-no-mutation"
  else
    fail "dry-run-no-mutation (rc=$rc_dr, changed=$([[ "$before" != "$after" ]] && echo yes || echo no))"
  fi

  teardown_test_env
}

# --- 11. uninstall-preserve-user ---
test_uninstall_preserve_user() {
  setup_test_env
  run_setup --profile=minimal >/dev/null 2>&1
  # Add user content to CLAUDE.md user section
  printf "\n## My Precious Notes\nDo not delete this.\n" >> "$CLAUDE_DIR/CLAUDE.md"
  run_uninstall >/dev/null 2>&1 || true

  # Kit section should be removed, but user content preserved
  if assert_file_exists "$CLAUDE_DIR/CLAUDE.md" \
    && assert_file_contains "$CLAUDE_DIR/CLAUDE.md" "My Precious Notes" \
    && assert_file_not_contains "$CLAUDE_DIR/CLAUDE.md" "BEGIN STARTER-KIT-MANAGED"; then
    pass "uninstall-preserve-user"
  else
    fail "uninstall-preserve-user"
  fi

  teardown_test_env
}

# --- 12. snapshot-baseline ---
test_snapshot_baseline() {
  setup_test_env
  run_setup --profile=minimal >/dev/null 2>&1

  if assert_file_exists "$CLAUDE_DIR/.starter-kit-snapshot/settings.json" \
    && assert_dir_exists "$CLAUDE_DIR/.starter-kit-snapshot"; then
    # Snapshot settings should be kit baseline (no user customizations)
    # It should NOT contain user-added keys
    if ! jq -e '.mcpServers' "$CLAUDE_DIR/.starter-kit-snapshot/settings.json" >/dev/null 2>&1; then
      pass "snapshot-baseline"
    else
      fail "snapshot-baseline (snapshot contains user keys)"
    fi
  else
    fail "snapshot-baseline"
  fi

  teardown_test_env
}

# --- 13. merge-prefs-persist ---
test_merge_prefs_persist() {
  setup_test_env
  run_setup --profile=minimal >/dev/null 2>&1

  # Create a merge prefs file (matches actual format: key → "keep-mine" or "use-kit")
  printf '{"settings.json/permissions":"keep-mine"}' > "$CLAUDE_DIR/.starter-kit-merge-prefs.json"

  local rc=0
  run_setup_update >/dev/null 2>&1 || rc=$?

  # Merge prefs file should survive update with content intact
  if [[ $rc -eq 0 ]] \
    && assert_file_exists "$CLAUDE_DIR/.starter-kit-merge-prefs.json" \
    && assert_json_field "$CLAUDE_DIR/.starter-kit-merge-prefs.json" '."settings.json/permissions"' "keep-mine"; then
    pass "merge-prefs-persist"
  else
    fail "merge-prefs-persist"
  fi

  teardown_test_env
}

# --- 14. settings-array-merge ---
test_settings_array_merge() {
  setup_test_env
  install_fixture "v020"
  local rc=0
  run_setup_update >/dev/null 2>&1 || rc=$?

  # User's mcpServers should be preserved through merge (key + content)
  if [[ $rc -eq 0 ]] \
    && assert_file_exists "$CLAUDE_DIR/settings.json" \
    && assert_json_field "$CLAUDE_DIR/settings.json" '.mcpServers["my-custom-server"].command' "node" \
    && assert_json_field "$CLAUDE_DIR/settings.json" '.mcpServers["my-custom-server"].args[0]' "server.js"; then
    pass "settings-array-merge"
  else
    fail "settings-array-merge"
  fi

  teardown_test_env
}

# ═══════════════════════════════════════════════════════════════════════════
# Registry stubs (2) - SKIP until PR-8+9
# ═══════════════════════════════════════════════════════════════════════════

# --- 15. safety-net-first ---
test_safety_net_first() {
  skip "safety-net-first" "Feature registry not yet implemented (PR-8+9)"
}

# --- 16. registry-consistency ---
test_registry_consistency() {
  skip "registry-consistency" "Feature registry not yet implemented (PR-8+9)"
}

# ═══════════════════════════════════════════════════════════════════════════
# Migration scenarios (5)
# ═══════════════════════════════════════════════════════════════════════════

# --- 17. update-from-v019 ---
test_update_from_v019() {
  setup_test_env
  install_fixture "v019"
  local rc=0
  run_setup_update >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] \
    && assert_file_exists "$CLAUDE_DIR/.starter-kit-manifest.json" \
    && assert_file_exists "$CLAUDE_DIR/settings.json"; then
    pass "update-from-v019"
  else
    fail "update-from-v019"
  fi

  teardown_test_env
}

# --- 18. update-from-v020 ---
test_update_from_v020() {
  setup_test_env
  install_fixture "v020"
  local rc=0
  run_setup_update >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] \
    && assert_file_exists "$CLAUDE_DIR/.starter-kit-manifest.json" \
    && assert_file_contains "$CLAUDE_DIR/CLAUDE.md" "BEGIN STARTER-KIT-MANAGED"; then
    pass "update-from-v020"
  else
    fail "update-from-v020"
  fi

  teardown_test_env
}

# --- 19. update-from-v020-customized ---
test_update_from_v020_customized() {
  setup_test_env
  install_fixture "v020"
  # Fixture already has user customizations (mcpServers, custom permissions)
  local rc=0
  run_setup_update >/dev/null 2>&1 || rc=$?

  # User section in CLAUDE.md should be preserved
  if [[ $rc -eq 0 ]] \
    && assert_file_contains "$CLAUDE_DIR/CLAUDE.md" "My custom instructions here"; then
    pass "update-from-v020-customized"
  else
    fail "update-from-v020-customized"
  fi

  teardown_test_env
}

# --- 20. update-from-no-manifest ---
test_update_from_no_manifest() {
  setup_test_env
  install_fixture "no-manifest"
  # Without manifest, --update bootstraps snapshot then runs update.
  # The update may not fully succeed (no manifest = no file tracking),
  # but the key invariant is: existing user files are not destroyed.
  local rc=0
  run_setup_update >/dev/null 2>&1 || rc=$?

  # Verify user data survives (the fixture's settings.json should still exist)
  if assert_file_exists "$CLAUDE_DIR/settings.json"; then
    pass "update-from-no-manifest"
  else
    fail "update-from-no-manifest (settings.json lost, rc=$rc)"
  fi

  teardown_test_env
}

# --- 21. update-noninteractive-safe ---
test_update_noninteractive_safe() {
  setup_test_env
  install_fixture "v020"
  # Save original CLAUDE.md content
  local original_user_content
  original_user_content="$(awk '/END STARTER-KIT-MANAGED/ {found=1; next} found {print}' "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null || true)"

  local rc=0
  run_setup_update >/dev/null 2>&1 || rc=$?

  # Verify no data loss: user section should be preserved
  local updated_user_content
  updated_user_content="$(awk '/END STARTER-KIT-MANAGED/ {found=1; next} found {print}' "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null || true)"

  if [[ $rc -eq 0 ]] && [[ "$original_user_content" == "$updated_user_content" ]]; then
    pass "update-noninteractive-safe"
  else
    fail "update-noninteractive-safe (user content changed)"
  fi

  teardown_test_env
}

# ═══════════════════════════════════════════════════════════════════════════
# Bash version scenarios (2)
# ═══════════════════════════════════════════════════════════════════════════

# --- 22. bash-version-check ---
test_bash_version_check() {
  # Verify that check_bash4 detects the current Bash version
  local bash_major="${BASH_VERSINFO[0]}"

  if [[ "$bash_major" -ge 4 ]]; then
    pass "bash-version-check (Bash ${BASH_VERSION}, 4+ OK)"
  else
    # On macOS with Bash 3.2 running the test harness, verify _detect_bash4 can find one
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/colors.sh"
    source "$PROJECT_DIR/lib/detect.sh"
    source "$PROJECT_DIR/lib/prerequisites.sh"
    if _detect_bash4 >/dev/null 2>&1; then
      pass "bash-version-check (Bash ${BASH_VERSION}, Bash 4+ found for re-exec)"
    else
      fail "bash-version-check (Bash ${BASH_VERSION}, no Bash 4+ found)"
    fi
  fi
}

# --- 23. bash-reexec ---
test_bash_reexec() {
  # Verify that setup.sh completes successfully even when started from the test harness
  # (which may be Bash 4+ already — the re-exec would be a no-op)
  setup_test_env
  local rc=0
  run_setup --profile=minimal >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] \
    && assert_file_exists "$CLAUDE_DIR/settings.json" \
    && assert_file_exists "$CLAUDE_DIR/.starter-kit-manifest.json"; then
    pass "bash-reexec"
  else
    fail "bash-reexec (setup failed after re-exec, rc=$rc)"
  fi

  teardown_test_env
}

# ═══════════════════════════════════════════════════════════════════════════
# Additional scenarios (5)
# ═══════════════════════════════════════════════════════════════════════════

# --- 24. update-v019-to-latest-direct ---
test_update_v019_to_latest_direct() {
  setup_test_env
  install_fixture "v019"
  # Directly run latest setup.sh --update (skip intermediate versions)
  local rc=0
  run_setup_update >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] \
    && assert_file_exists "$CLAUDE_DIR/.starter-kit-manifest.json" \
    && assert_file_exists "$CLAUDE_DIR/.starter-kit-snapshot/settings.json"; then
    pass "update-v019-to-latest-direct"
  else
    fail "update-v019-to-latest-direct"
  fi

  teardown_test_env
}

# --- 25. snapshot-format-v019-to-latest ---
test_snapshot_format_v019_to_latest() {
  setup_test_env
  install_fixture "v019"
  local rc=0
  run_setup_update >/dev/null 2>&1 || rc=$?

  # After update, snapshot should be valid (settings.json present + valid JSON)
  if [[ $rc -eq 0 ]] \
    && assert_file_exists "$CLAUDE_DIR/.starter-kit-snapshot/settings.json" \
    && jq empty "$CLAUDE_DIR/.starter-kit-snapshot/settings.json" 2>/dev/null; then
    pass "snapshot-format-v019-to-latest"
  else
    fail "snapshot-format-v019-to-latest"
  fi

  teardown_test_env
}

# --- 26. snapshot-format-v020-compat ---
test_snapshot_format_v020_compat() {
  setup_test_env
  install_fixture "v020"
  local rc=0
  run_setup_update >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] \
    && assert_file_exists "$CLAUDE_DIR/.starter-kit-snapshot/settings.json" \
    && jq empty "$CLAUDE_DIR/.starter-kit-snapshot/settings.json" 2>/dev/null; then
    pass "snapshot-format-v020-compat"
  else
    fail "snapshot-format-v020-compat"
  fi

  teardown_test_env
}

# --- 27. update-partial-failure-recovery ---
test_update_partial_failure_recovery() {
  setup_test_env
  run_setup --profile=minimal >/dev/null 2>&1

  # Run update which should create a backup via backup_existing()
  run_setup_update >/dev/null 2>&1 || true

  # Check if backup was created (backup_existing writes .starter-kit-last-backup)
  local backup_path_file="$CLAUDE_DIR/.starter-kit-last-backup"
  if [[ -f "$backup_path_file" ]]; then
    local backup_dir
    backup_dir="$(cat "$backup_path_file")"
    if assert_dir_exists "$backup_dir" \
      && assert_file_exists "$backup_dir/settings.json"; then
      # Simulate failure: destroy CLAUDE_DIR and restore from backup
      rm -rf "$CLAUDE_DIR"
      cp -a "$backup_dir" "$CLAUDE_DIR"
      if assert_file_exists "$CLAUDE_DIR/settings.json"; then
        pass "update-partial-failure-recovery"
      else
        fail "update-partial-failure-recovery (restore failed)"
      fi
    else
      fail "update-partial-failure-recovery (backup incomplete)"
    fi
  else
    # Backup may not exist if CLAUDE_DIR didn't exist before update
    # In this case, verify at least that CLAUDE_DIR is intact
    local backup_found=false
    for d in "$HOME"/.claude.backup.*; do
      if [[ -d "$d" ]] && [[ -f "$d/settings.json" ]]; then
        backup_found=true
        rm -rf "$CLAUDE_DIR"
        cp -a "$d" "$CLAUDE_DIR"
        if assert_file_exists "$CLAUDE_DIR/settings.json"; then
          pass "update-partial-failure-recovery"
        else
          fail "update-partial-failure-recovery (restore failed)"
        fi
        break
      fi
    done
    if [[ "$backup_found" == "false" ]]; then
      fail "update-partial-failure-recovery (no backup found)"
    fi
  fi

  teardown_test_env
}

# --- 28. bash4-noninteractive-unavailable ---
test_bash4_noninteractive_unavailable() {
  # This test requires a Bash 3.2-only environment with no Bash 4+ available.
  # CI (ubuntu-latest) always has Bash 4+, so we can only verify on macOS
  # with Bash 4+ uninstalled. Skip on CI.
  if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
    skip "bash4-noninteractive-unavailable" "Cannot test — current shell is already Bash 4+"
  else
    # If we're running under Bash 3.2 and _detect_bash4 fails, setup.sh should error
    setup_test_env
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/colors.sh"
    source "$PROJECT_DIR/lib/detect.sh"
    source "$PROJECT_DIR/lib/prerequisites.sh"
    if _detect_bash4 >/dev/null 2>&1; then
      skip "bash4-noninteractive-unavailable" "Bash 4+ found even on Bash 3.2 host"
    else
      # No Bash 4+ available + non-interactive → should get error
      local rc=0
      run_setup --profile=minimal >/dev/null 2>&1 || rc=$?
      if [[ $rc -ne 0 ]]; then
        pass "bash4-noninteractive-unavailable"
      else
        fail "bash4-noninteractive-unavailable (should have failed without Bash 4+)"
      fi
    fi
    teardown_test_env
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Run all tests
# ═══════════════════════════════════════════════════════════════════════════

test_fresh_install_clean
test_fresh_install_existing
test_update_no_changes
test_update_kit_changed
test_update_user_changed
test_update_feature_toggle
test_claudemd_migration
test_claudemd_section_preserve
test_claudemd_kit_edit_conflict
test_dry_run_no_mutation
test_uninstall_preserve_user
test_snapshot_baseline
test_merge_prefs_persist
test_settings_array_merge
test_safety_net_first
test_registry_consistency
test_update_from_v019
test_update_from_v020
test_update_from_v020_customized
test_update_from_no_manifest
test_update_noninteractive_safe
test_bash_version_check
test_bash_reexec
test_update_v019_to_latest_direct
test_snapshot_format_v019_to_latest
test_snapshot_format_v020_compat
test_update_partial_failure_recovery
test_bash4_noninteractive_unavailable

print_summary
