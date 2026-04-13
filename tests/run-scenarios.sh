#!/bin/bash
# tests/run-scenarios.sh - Scenario test runner for Claude Code Starter Kit
# Runs 34 scenarios covering fresh install, update, migration, and edge cases.
#
# Usage: bash tests/run-scenarios.sh
#
# Expected results (PR-8+9+): 27 PASS + 1 SKIP
# SKIP: bash4-noninteractive-unavailable (always SKIP on Bash 4+ CI)
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

# --- 4b. auto-update-session-hooks ---
test_auto_update_session_hooks() {
  setup_test_env
  run_setup --profile=standard >/dev/null 2>&1 || { fail "auto-update-session-hooks (setup failed)"; teardown_test_env; return; }

  if jq -e '
    any(.hooks.SessionStart[]?.hooks[]?; .async == true and ((.command? // "") | contains("auto-update"))) and
    any(.hooks.SessionEnd[]?.hooks[]?; .async == true and ((.command? // "") | contains("auto-update")))
  ' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
    pass "auto-update-session-hooks"
  else
    fail "auto-update-session-hooks"
  fi

  teardown_test_env
}

# --- 4c. auto-update-legacy-claude-fallback ---
test_auto_update_legacy_claude_fallback() {
  setup_test_env
  export MOCK_CLAUDE_VERSION="2.1.88 (Claude Code)"
  run_setup --profile=standard >/dev/null 2>&1 || { fail "auto-update-legacy-claude-fallback (setup failed)"; teardown_test_env; unset MOCK_CLAUDE_VERSION; return; }

  if jq -e '
    any(.hooks.SessionStart[]?.hooks[]?; ((.command? // "") | contains("auto-update")) and ((has("async") | not) or (.async != true))) and
    ((.hooks.SessionEnd // []) | length == 0)
  ' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
    pass "auto-update-legacy-claude-fallback"
  else
    fail "auto-update-legacy-claude-fallback"
  fi

  unset MOCK_CLAUDE_VERSION
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
# Registry tests (2)
# ═══════════════════════════════════════════════════════════════════════════

# --- 15. safety-net-first ---
test_safety_net_first() {
  # Guard: features.sh requires Bash 4+ (declare -A)
  if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    skip "safety-net-first" "Bash 4+ required for declare -A"
    return
  fi
  # shellcheck source=/dev/null
  source "$PROJECT_DIR/lib/features.sh"

  if [[ "${_FEATURE_ORDER[0]}" == "safety-net" ]]; then
    pass "safety-net-first"
  else
    fail "safety-net-first (got: ${_FEATURE_ORDER[0]:-empty})"
  fi
}

# --- 16. registry-consistency ---
test_registry_consistency() {
  if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    skip "registry-consistency" "Bash 4+ required for declare -A"
    return
  fi
  # shellcheck source=/dev/null
  source "$PROJECT_DIR/lib/features.sh"

  local missing=()
  local name
  for name in "${_FEATURE_ORDER[@]}"; do
    if [[ -z "${_FEATURE_FLAGS[$name]+set}" ]]; then
      missing+=("$name")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    pass "registry-consistency"
  else
    fail "registry-consistency (missing in _FEATURE_FLAGS: ${missing[*]})"
  fi
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

# --- 29. snapshot-double-marker-repair ---
test_snapshot_double_marker_repair() {
  setup_test_env
  run_setup --profile=minimal >/dev/null 2>&1

  local snapshot_claude="$CLAUDE_DIR/.starter-kit-snapshot/CLAUDE.md"
  if [[ ! -f "$snapshot_claude" ]]; then
    fail "snapshot-double-marker-repair (no snapshot created)"
    teardown_test_env
    return
  fi

  # Corrupt the snapshot by appending a second copy (simulates pre-v0.30.0 bug)
  local original
  original="$(cat "$snapshot_claude")"
  {
    printf '%s\n' "$original"
    printf '%s\n' "$original"
  } > "$snapshot_claude"

  local marker_count
  marker_count="$(grep -cF '<!-- BEGIN STARTER-KIT-MANAGED -->' "$snapshot_claude")" || marker_count=0
  if [[ "$marker_count" -lt 2 ]]; then
    fail "snapshot-double-marker-repair (corruption setup failed)"
    teardown_test_env
    return
  fi

  # Run update — should auto-repair the snapshot before comparison
  local rc=0
  run_setup_update >/dev/null 2>&1 || rc=$?

  # Verify snapshot was repaired to exactly 1 marker pair
  local after_count
  after_count="$(grep -cF '<!-- BEGIN STARTER-KIT-MANAGED -->' "$snapshot_claude")" || after_count=0
  if [[ "$after_count" -eq 1 ]]; then
    pass "snapshot-double-marker-repair"
  else
    fail "snapshot-double-marker-repair (expected 1 marker, got $after_count)"
  fi

  teardown_test_env
}

# --- 30. update-progress-output ---
test_update_progress_output() {
  setup_test_env
  run_setup --profile=minimal >/dev/null 2>&1 || { fail "update-progress-output (setup failed)"; teardown_test_env; return; }

  local output rc=0
  output="$(run_setup_update 2>&1)" || rc=$?

  if [[ $rc -eq 0 ]] \
    && grep -q "Step 1/5:" <<< "$output" \
    && grep -q "Managed files:" <<< "$output" \
    && grep -q "Step 5/5:" <<< "$output"; then
    pass "update-progress-output"
  else
    fail "update-progress-output"
  fi

  teardown_test_env
}

# --- 32. dry-run-progress-output ---
test_dry_run_progress_output() {
  setup_test_env
  run_setup --profile=minimal >/dev/null 2>&1 || { fail "dry-run-progress-output (setup failed)"; teardown_test_env; return; }

  local output rc=0
  output="$(run_setup_update --dry-run 2>&1)" || rc=$?

  if [[ $rc -eq 0 ]] \
    && grep -q "Preview Mode: Simulating update without modifying ~/.claude" <<< "$output" \
    && grep -q "Preview 1/5:" <<< "$output"; then
    pass "dry-run-progress-output"
  else
    fail "dry-run-progress-output"
  fi

  teardown_test_env
}

# --- 33. dry-run-quiet-merge-summary ---
test_dry_run_quiet_merge_summary() {
  setup_test_env
  run_setup --profile=minimal >/dev/null 2>&1 || { fail "dry-run-quiet-merge-summary (setup failed)"; teardown_test_env; return; }

  jq '.user_custom_key = "mine"' "$CLAUDE_DIR/settings.json" > "$CLAUDE_DIR/settings.json.tmp" \
    && mv "$CLAUDE_DIR/settings.json.tmp" "$CLAUDE_DIR/settings.json"
  jq '.old_kit_marker = true' "$CLAUDE_DIR/.starter-kit-snapshot/settings.json" > "$CLAUDE_DIR/.starter-kit-snapshot/settings.json.tmp" \
    && mv "$CLAUDE_DIR/.starter-kit-snapshot/settings.json.tmp" "$CLAUDE_DIR/.starter-kit-snapshot/settings.json"

  local output rc=0
  output="$(run_setup_update --dry-run 2>&1)" || rc=$?

  if [[ $rc -eq 0 ]] \
    && grep -q "settings.json merge:" <<< "$output" \
    && grep -q "settings.json merge summary:" <<< "$output" \
    && ! grep -q "\[kit-update\]" <<< "$output" \
    && ! grep -q "\[merge-array\]" <<< "$output"; then
    pass "dry-run-quiet-merge-summary"
  else
    fail "dry-run-quiet-merge-summary"
  fi

  teardown_test_env
}

# --- 34. update-kit-command-paths ---
test_update_kit_command_paths() {
  local update_cmd dry_run_cmd
  update_cmd="$(sed -n '1,20p' "$PROJECT_DIR/commands/update-kit.md")"
  dry_run_cmd="$(sed -n '1,20p' "$PROJECT_DIR/commands/update-kit-dry-run.md")"

  if grep -q "bash setup.sh --update" <<< "$update_cmd" \
    && grep -q "bash setup.sh --update --dry-run" <<< "$dry_run_cmd"; then
    pass "update-kit-command-paths"
  else
    fail "update-kit-command-paths"
  fi
}

# --- 35. biome-hooks-full-profile ---
test_biome_hooks_full_profile() {
  setup_test_env
  local rc=0
  run_setup --profile=full >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] \
    && jq -e 'any(.hooks.PostToolUse[]?; (.hooks[0].command? // "") | contains("biome check --write"))' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1 \
    && ! jq -e 'any(.hooks.PostToolUse[]?; (.hooks[0].command? // "") | contains("prettier --write"))' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
    pass "biome-hooks-full-profile"
  else
    fail "biome-hooks-full-profile"
  fi

  teardown_test_env
}

# --- 36. biome-hooks-standard-profile ---
test_biome_hooks_standard_profile() {
  setup_test_env
  local rc=0
  run_setup --profile=standard >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] \
    && jq -e 'any(.hooks.PostToolUse[]?; (.hooks[0].command? // "") | contains("prettier --write"))' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1 \
    && ! jq -e 'any(.hooks.PostToolUse[]?; (.hooks[0].command? // "") | contains("biome check --write"))' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
    pass "biome-hooks-standard-profile"
  else
    fail "biome-hooks-standard-profile"
  fi

  teardown_test_env
}

# --- 37. biome-hooks-minimal-profile ---
test_biome_hooks_minimal_profile() {
  setup_test_env
  local rc=0
  run_setup --profile=minimal >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] \
    && ! jq -e 'any(.hooks.PostToolUse[]?; (.hooks[0].command? // "") | contains("prettier --write") or contains("biome check --write"))' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
    pass "biome-hooks-minimal-profile"
  else
    fail "biome-hooks-minimal-profile"
  fi

  teardown_test_env
}

setup_biome_auto_install_stub() {
  local stub_dir="$HOME/test-bin"
  mkdir -p "$stub_dir"

  local tool tool_path
  for tool in gsed gawk node npm tmux gh; do
    tool_path="$(PATH="$_ORIG_PATH" command -v "$tool" 2>/dev/null || true)"
    if [[ -n "$tool_path" ]]; then
      ln -sf "$tool_path" "$stub_dir/$tool"
    fi
  done

  export PATH="$stub_dir:$HOME/.local/bin:/usr/bin:/bin"
  cat > "$stub_dir/brew" <<EOF
#!/bin/bash
if [[ "\$1" == "--prefix" ]]; then
  echo "$stub_dir"
  exit 0
fi
if [[ "\$1" == "install" && "\$2" == "biome" ]]; then
  cat > "$stub_dir/biome" <<'INNER'
#!/bin/bash
echo "biome 1.0.0"
INNER
  chmod +x "$stub_dir/biome"
  exit 0
fi
exit 1
EOF
  chmod +x "$stub_dir/brew"
}

# --- 38. biome-auto-install-full-profile ---
test_biome_auto_install_full_profile() {
  setup_test_env
  local stub_dir="$HOME/test-bin"
  setup_biome_auto_install_stub

  local rc=0
  run_setup --profile=full >/dev/null 2>&1 || rc=$?

  local biome_path=""
  biome_path="$(command -v biome 2>/dev/null || true)"
  if [[ $rc -eq 0 ]] && [[ "$biome_path" == "$stub_dir/biome" ]]; then
    pass "biome-auto-install-full-profile"
  else
    fail "biome-auto-install-full-profile"
  fi

  teardown_test_env
}

# --- 39. biome-auto-install-opt-in ---
test_biome_auto_install_opt_in() {
  setup_test_env
  local stub_dir="$HOME/test-bin"
  setup_biome_auto_install_stub

  local rc=0
  run_setup --profile=standard --hooks=biome >/dev/null 2>&1 || rc=$?

  local biome_path=""
  biome_path="$(command -v biome 2>/dev/null || true)"
  if [[ $rc -eq 0 ]] && [[ "$biome_path" == "$stub_dir/biome" ]]; then
    pass "biome-auto-install-opt-in"
  else
    fail "biome-auto-install-opt-in"
  fi

  teardown_test_env
}

# --- 40. biome-auto-install-disabled-standard ---
test_biome_auto_install_disabled_standard() {
  setup_test_env
  local stub_dir="$HOME/test-bin"
  setup_biome_auto_install_stub

  local rc=0
  run_setup --profile=standard >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] && [[ ! -x "$stub_dir/biome" ]]; then
    pass "biome-auto-install-disabled-standard"
  else
    fail "biome-auto-install-disabled-standard"
  fi

  teardown_test_env
}

# --- 41. biome-auto-install-disabled-minimal ---
test_biome_auto_install_disabled_minimal() {
  setup_test_env
  local stub_dir="$HOME/test-bin"
  setup_biome_auto_install_stub

  local rc=0
  run_setup --profile=minimal >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] && [[ ! -x "$stub_dir/biome" ]]; then
    pass "biome-auto-install-disabled-minimal"
  else
    fail "biome-auto-install-disabled-minimal"
  fi

  teardown_test_env
}

# --- 42. biome-auto-install-respects-saved-prettier-on-full ---
test_biome_auto_install_respects_saved_prettier_on_full() {
  setup_test_env
  cat > "$HOME/.claude-starter-kit.conf" <<'EOF'
PROFILE="full"
ENABLE_PRETTIER_HOOKS="true"
EOF

  local stub_dir="$HOME/test-bin"
  setup_biome_auto_install_stub

  local rc=0
  run_setup >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] \
    && [[ ! -x "$stub_dir/biome" ]] \
    && jq -e 'any(.hooks.PostToolUse[]?; (.hooks[0].command? // "") | contains("prettier --write"))' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1 \
    && ! jq -e 'any(.hooks.PostToolUse[]?; (.hooks[0].command? // "") | contains("biome check --write"))' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
    pass "biome-auto-install-respects-saved-prettier-on-full"
  else
    fail "biome-auto-install-respects-saved-prettier-on-full"
  fi

  teardown_test_env
}

# --- 43. biome-auto-install-respects-legacy-disable-on-full ---
test_biome_auto_install_respects_legacy_disable_on_full() {
  setup_test_env
  cat > "$HOME/.claude-starter-kit.conf" <<'EOF'
PROFILE="full"
ENABLE_PRETTIER_HOOKS="false"
EOF

  local stub_dir="$HOME/test-bin"
  setup_biome_auto_install_stub

  local rc=0
  run_setup >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] \
    && [[ ! -x "$stub_dir/biome" ]] \
    && ! jq -e 'any(.hooks.PostToolUse[]?; (.hooks[0].command? // "") | contains("prettier --write") or contains("biome check --write"))' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
    pass "biome-auto-install-respects-legacy-disable-on-full"
  else
    fail "biome-auto-install-respects-legacy-disable-on-full"
  fi

  teardown_test_env
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

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
test_snapshot_double_marker_repair
test_update_progress_output
test_auto_update_session_hooks
test_auto_update_legacy_claude_fallback
test_dry_run_progress_output
test_dry_run_quiet_merge_summary
test_update_kit_command_paths
test_biome_hooks_full_profile
test_biome_hooks_standard_profile
test_biome_hooks_minimal_profile
test_biome_auto_install_full_profile
test_biome_auto_install_opt_in
test_biome_auto_install_disabled_standard
test_biome_auto_install_disabled_minimal
test_biome_auto_install_respects_saved_prettier_on_full
test_biome_auto_install_respects_legacy_disable_on_full

print_summary
