#!/bin/bash
# tests/run-scenarios.sh - Scenario test runner for Claude Code Starter Kit
# Runs scenario coverage for fresh install, update, migration, and edge cases.
#
# Usage: bash tests/run-scenarios.sh
#
# Expected: all scenarios pass; Bash 4+ CI may skip bash4-noninteractive-unavailable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

printf "\n── Claude Code Starter Kit: Scenario Tests ──\n\n"
SCENARIO_GROUP="${SCENARIO_GROUP:-all}"

case "$SCENARIO_GROUP" in
  all|core|update|update-merge|features) ;;
  *)
    printf "ERROR: invalid SCENARIO_GROUP '%s' (expected: all, core, update, update-merge, features)\n" "$SCENARIO_GROUP" >&2
    exit 1
    ;;
esac

run_scenario() {
  local group="$1"
  local name="$2"
  if [[ "$SCENARIO_GROUP" == "all" || "$SCENARIO_GROUP" == "$group" ]]; then
    "$name"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Basic scenarios
# ═══════════════════════════════════════════════════════════════════════════

# --- 1. fresh-install-clean ---
test_fresh_install_clean() {
  setup_test_env
  local rc=0 pending_reader
  pending_reader="$CLAUDE_DIR/hooks/feature-recommendation/check-pending.sh"
  run_setup --profile=minimal >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] \
    && assert_file_exists "$CLAUDE_DIR/settings.json" \
    && assert_file_exists "$CLAUDE_DIR/CLAUDE.md" \
    && assert_file_exists "$CLAUDE_DIR/.starter-kit-manifest.json" \
    && assert_dir_exists "$CLAUDE_DIR/.starter-kit-snapshot" \
    && assert_file_exists "$CLAUDE_DIR/.starter-kit-snapshot/settings.json" \
    && assert_file_contains "$CLAUDE_DIR/settings.json" "feature-recommendation/check-pending.sh" \
    && [[ -x "$pending_reader" ]] \
    && assert_file_exists \
      "$CLAUDE_DIR/.starter-kit-snapshot/hooks/feature-recommendation/check-pending.sh" \
    && jq -e --arg reader "$pending_reader" '.files | index($reader) != null' \
      "$CLAUDE_DIR/.starter-kit-manifest.json" >/dev/null 2>&1 \
    && assert_file_contains "$CLAUDE_DIR/CLAUDE.md" "BEGIN STARTER-KIT-MANAGED" \
    && assert_json_field "$CLAUDE_DIR/.starter-kit-manifest.json" '.version' "2"; then
    pass "fresh-install-clean"
  else
    fail "fresh-install-clean"
  fi

  teardown_test_env
}

# --- 1b. fresh-install-ja ---
test_fresh_install_ja() {
  setup_test_env
  local rc=0
  run_setup --profile=minimal --language=ja >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] \
    && assert_file_exists "$CLAUDE_DIR/CLAUDE.md" \
    && assert_file_contains "$CLAUDE_DIR/CLAUDE.md" "# グローバル設定" \
    && assert_file_contains "$CLAUDE_DIR/CLAUDE.md" "# ユーザー設定"; then
    pass "fresh-install-ja"
  else
    fail "fresh-install-ja"
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
    (any(.hooks.SessionEnd[]?.hooks[]?; ((.command? // "") | contains("auto-update"))) | not)
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

# --- update-adopts-new-catalog-plugin (F10 + F13) ---
#
# End-to-end through the real setup.sh and the real config/plugins.json:
#   F10: a fresh install stamps the profile's default plugin set into
#        KNOWN_PLUGINS, so a default the user deselected here is not treated as
#        a newcomer and re-offered on the first update.
#   F13: a plugin the install has not seen (simulated by dropping it from
#        KNOWN_PLUGINS) is detected on update and recorded for the user.
# The last full-only catalog entry stands in for "the newly catalogued plugin"
# (after #152 merges this generalizes to claude-security, the 15th full plugin).
test_update_adopts_new_catalog_plugin() {
  setup_test_env
  local conf="$HOME/.claude-starter-kit.conf"
  local pending="$CLAUDE_DIR/.starter-kit-pending-features.json"
  local q='def q: if (.marketplace // "claude-plugins-official")=="claude-plugins-official" then .name else .name+"@"+.marketplace end;'
  local victim old_set
  victim="$(jq -r "$q"' [.plugins[] | select(.profiles | index("full"))] | .[-1] | q' "$PROJECT_DIR/config/plugins.json")"
  old_set="$(jq -r "$q"' ([.plugins[] | select(.profiles | index("full"))] | .[-1] | q) as $v | [.plugins[] | select(.profiles | index("full")) | q] | map(select(. != $v)) | join(",")' "$PROJECT_DIR/config/plugins.json")"

  # 1. Fresh full install with the victim explicitly deselected.
  run_setup --profile=full --fonts=false --ghostty=false --codex-plugin=false \
    --plugins="$old_set" >/dev/null 2>&1

  # F10: the fresh install must record the profile defaults (incl. victim).
  local known
  known="$(grep '^KNOWN_PLUGINS=' "$conf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"

  # 2. Non-interactive update must NOT re-offer the deselected default.
  run_setup_update --profile=full >/dev/null 2>&1
  local reoffered=no
  if [[ -f "$pending" ]] \
    && jq -e --arg v "$victim" '(.plugins // []) | index($v)' "$pending" >/dev/null 2>&1; then
    reoffered=yes
  fi
  local f10_ok=no
  [[ ",$known," == *",$victim,"* ]] && [[ "$reoffered" == "no" ]] && f10_ok=yes

  # 3. Simulate the victim being catalogued after the user was last asked: drop
  #    it from KNOWN_PLUGINS (SELECTED already lacks it), then update again.
  local tmpconf
  tmpconf="$(mktemp)"
  grep -v '^KNOWN_PLUGINS=' "$conf" > "$tmpconf" 2>/dev/null || true
  printf 'KNOWN_PLUGINS="%s"\n' "$old_set" >> "$tmpconf"
  mv "$tmpconf" "$conf"

  run_setup_update --profile=full >/dev/null 2>&1
  local f13_ok=no
  if [[ -f "$pending" ]] \
    && jq -e --arg v "$victim" '(.plugins // []) | index($v)' "$pending" >/dev/null 2>&1; then
    f13_ok=yes
  fi

  # 4. Simulate /update-kit accepting the newcomer on an older conf that has
  #    no SELECTED_PLUGINS line. The command contract initializes that line
  #    from the current manifest before appending, so earlier choices survive.
  local manifest="$CLAUDE_DIR/.starter-kit-manifest.json"
  local manifest_selected accepted adopted
  manifest_selected="$(jq -er '.plugins | select(type == "string")' "$manifest")"
  accepted="$manifest_selected"
  if [[ ",$accepted," != *",$victim,"* ]]; then
    accepted="${accepted:+${accepted},}${victim}"
  fi
  tmpconf="$(mktemp "${conf}.XXXXXX")"
  grep -v '^SELECTED_PLUGINS=' "$conf" > "$tmpconf" 2>/dev/null || true
  printf 'SELECTED_PLUGINS="%s"\n' "$accepted" >> "$tmpconf"
  chmod 600 "$tmpconf"
  mv "$tmpconf" "$conf"

  run_setup_update --profile=full >/dev/null 2>&1
  adopted="$(jq -r '.plugins // ""' "$manifest")"
  local f14_ok=no command_contract=no
  if [[ "$adopted" == "$accepted" ]] \
    && { [[ ! -f "$pending" ]] \
      || ! jq -e --arg v "$victim" '(.plugins // []) | index($v)' \
        "$pending" >/dev/null 2>&1; }; then
    f14_ok=yes
  fi
  if grep -Fq 'If the `SELECTED_PLUGINS` line is absent' \
    "$PROJECT_DIR/commands/update-kit.md"; then
    command_contract=yes
  fi

  if [[ "$f10_ok" == "yes" ]] && [[ "$f13_ok" == "yes" ]] \
    && [[ "$f14_ok" == "yes" ]] && [[ "$command_contract" == "yes" ]]; then
    pass "update-adopts-new-catalog-plugin"
  else
    fail "update-adopts-new-catalog-plugin (f10=$f10_ok f13=$f13_ok f14=$f14_ok contract=$command_contract victim=$victim known=[$known])"
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
    && grep -q "Step 1/5:" < <(printf '%s\n' "$output") \
    && grep -q "Managed files:" < <(printf '%s\n' "$output") \
    && grep -q "Step 5/5:" < <(printf '%s\n' "$output"); then
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
    && grep -q "Preview Mode: Simulating update without modifying ~/.claude" \
      < <(printf '%s\n' "$output") \
    && grep -q "Preview 1/5:" < <(printf '%s\n' "$output"); then
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
    && grep -q "settings.json merge:" < <(printf '%s\n' "$output") \
    && grep -q "settings.json merge summary:" < <(printf '%s\n' "$output") \
    && ! grep -q "\[kit-update\]" < <(printf '%s\n' "$output") \
    && ! grep -q "\[merge-array\]" < <(printf '%s\n' "$output"); then
    pass "dry-run-quiet-merge-summary"
  else
    fail "dry-run-quiet-merge-summary"
  fi

  teardown_test_env
}

# --- 34. update-kit-command-paths ---
test_update_kit_command_paths() {
  local update_cmd dry_run_cmd update_resolver dry_run_resolver
  update_cmd="$(cat "$PROJECT_DIR/commands/update-kit.md")"
  dry_run_cmd="$(cat "$PROJECT_DIR/commands/update-kit-dry-run.md")"
  update_resolver="$(awk '
    /^## Instructions$/ { within_section = 1; next }
    within_section && /^```bash$/ { in_code = 1; next }
    in_code && /^printf .*Resolved kit repo:/ { exit }
    in_code { print }
  ' "$PROJECT_DIR/commands/update-kit.md")"
  dry_run_resolver="$(awk '
    /^## Instructions$/ { within_section = 1; next }
    within_section && /^```bash$/ { in_code = 1; next }
    in_code && /^printf .*Resolved kit repo:/ { exit }
    in_code { print }
  ' "$PROJECT_DIR/commands/update-kit-dry-run.md")"

  if grep -Fq 'default_config_file="$HOME/.claude-starter-kit.conf"' < <(printf '%s\n' "$update_cmd") \
    && grep -Fq 'KIT_REPO="...' < <(printf '%s\n' "$update_cmd") \
    && grep -Fq 'repo_top="$(git -C "$kit_repo_physical" rev-parse --show-toplevel' < <(printf '%s\n' "$update_cmd") \
    && grep -Fq 'setup_args=(--update)' < <(printf '%s\n' "$update_cmd") \
    && grep -Fq 'setup_args+=("--config=$config_file")' < <(printf '%s\n' "$update_cmd") \
    && grep -Fq 'bash setup.sh "${setup_args[@]}"' < <(printf '%s\n' "$update_cmd") \
    && grep -Fq 'exact key in `_FEATURE_FLAGS`' < <(printf '%s\n' "$update_cmd") \
    && ! grep -Fq 'cd ~/.claude-starter-kit' < <(printf '%s\n' "$update_cmd") \
    && ! grep -Fq 'Read `~/.claude-starter-kit/' < <(printf '%s\n' "$update_cmd") \
    && ! grep -Fq 're-run in Step 9' < <(printf '%s\n' "$update_cmd") \
    && grep -Fq 'default_config_file="$HOME/.claude-starter-kit.conf"' < <(printf '%s\n' "$dry_run_cmd") \
    && grep -Fq 'setup_args=(--update --dry-run)' < <(printf '%s\n' "$dry_run_cmd") \
    && grep -Fq 'setup_args+=("--config=$config_file")' < <(printf '%s\n' "$dry_run_cmd") \
    && grep -Fq 'bash setup.sh "${setup_args[@]}"' < <(printf '%s\n' "$dry_run_cmd") \
    && ! grep -Fq 'cd ~/.claude-starter-kit' < <(printf '%s\n' "$dry_run_cmd") \
    && [[ "$update_resolver" == "$dry_run_resolver" ]]; then
    pass "update-kit-command-paths"
  else
    fail "update-kit-command-paths"
  fi
}

# --- 34a. update-kit-repo-resolution ---
test_update_kit_repo_resolution() {
  setup_test_env
  local command_file="$PROJECT_DIR/commands/update-kit.md"
  local config_file="$HOME/.claude-starter-kit.conf"
  local manifest_file="$HOME/.claude/.starter-kit-manifest.json"
  local custom_repo="$HOME/キット+custom checkout"
  local default_repo="$HOME/.claude-starter-kit"
  local repo
  for repo in "$custom_repo" "$default_repo"; do
    mkdir -p "$repo/lib" "$repo/config"
    : > "$repo/setup.sh"
    : > "$repo/lib/features.sh"
    printf '%s\n' '{}' > "$repo/config/plugins.json"
    git init -q "$repo"
  done

  local resolver_script resolver_command
  resolver_script="$(awk '
    /^## Instructions$/ { within_section = 1; next }
    within_section && /^```bash$/ { in_code = 1; next }
    in_code && /^printf .*Resolved kit repo:/ { exit }
    in_code { print }
  ' "$command_file")"
  resolver_command="${resolver_script}"$'\n''printf "%s" "$kit_repo_physical"'

  printf 'KIT_REPO="%s"\n' "$custom_repo" > "$config_file"
  local custom_actual custom_rc=0
  custom_actual="$(HOME="$HOME" bash -eu -c "$resolver_command")" || custom_rc=$?
  local custom_ok=no
  if [[ $custom_rc -eq 0 ]] \
    && [[ "$custom_actual" == "$(cd "$custom_repo" && pwd -P)" ]]; then
    custom_ok=yes
  fi

  local bound_config="$HOME/custom wizard.conf"
  printf 'KIT_REPO="%s"\n' "$custom_repo" > "$bound_config"
  mkdir -p "${manifest_file%/*}"
  jq -n --arg repo "$custom_repo" --arg config "$bound_config" \
    '{version:2,mdm_managed:false,kit_repo:$repo,config_file:$config}' \
    > "$manifest_file"
  local bound_actual bound_rc=0
  bound_actual="$(HOME="$HOME" bash -eu -c \
    "${resolver_script}"$'\n''printf "%s|%s|%s" "$kit_repo_physical" "$config_file" "$manifest_bound"')" \
    || bound_rc=$?
  local bound_ok=no
  if [[ $bound_rc -eq 0 ]] \
    && [[ "$bound_actual" == "$(cd "$custom_repo" && pwd -P)|$bound_config|true" ]]; then
    bound_ok=yes
  fi

  local fallback_manifest_ok=yes manifest_json manifest_actual manifest_rc
  for manifest_json in '{"version":2}' '{"version":2,"mdm_managed":true}'; do
    printf '%s\n' "$manifest_json" > "$manifest_file"
    manifest_rc=0
    manifest_actual="$(HOME="$HOME" bash -eu -c \
      "${resolver_script}"$'\n''printf "%s|%s|%s" "$kit_repo_physical" "$config_file" "$manifest_bound"')" \
      || manifest_rc=$?
    if [[ $manifest_rc -ne 0 ]] \
      || [[ "$manifest_actual" != "$(cd "$custom_repo" && pwd -P)|$config_file|false" ]]; then
      fallback_manifest_ok=no
    fi
  done
  rm -f "$manifest_file"

  rm -f "$config_file"
  local fallback_actual fallback_rc=0
  fallback_actual="$(HOME="$HOME" bash -eu -c "$resolver_command")" || fallback_rc=$?
  local fallback_ok=no
  if [[ $fallback_rc -eq 0 ]] \
    && [[ "$fallback_actual" == "$(cd "$default_repo" && pwd -P)" ]]; then
    fallback_ok=yes
  fi

  printf '%s\n' 'PROFILE="standard"' > "$config_file"
  local legacy_actual legacy_rc=0
  legacy_actual="$(HOME="$HOME" bash -eu -c "$resolver_command")" || legacy_rc=$?
  local legacy_ok=no
  if [[ $legacy_rc -eq 0 ]] \
    && [[ "$legacy_actual" == "$(cd "$default_repo" && pwd -P)" ]]; then
    legacy_ok=yes
  fi

  printf '%s\n' 'KIT_REPO="relative/path"' > "$config_file"
  local relative_rc=0
  HOME="$HOME" bash -eu -c "$resolver_command" >/dev/null 2>&1 || relative_rc=$?

  printf 'KIT_REPO="%s"\nKIT_REPO="%s"\n' "$custom_repo" "$default_repo" > "$config_file"
  local duplicate_rc=0
  HOME="$HOME" bash -eu -c "$resolver_command" >/dev/null 2>&1 || duplicate_rc=$?

  local marker="$HOME/config-was-evaluated"
  printf 'KIT_REPO="$(touch %s)"\n' "$marker" > "$config_file"
  local injection_rc=0
  HOME="$HOME" bash -eu -c "$resolver_command" >/dev/null 2>&1 || injection_rc=$?

  local nongit_repo="$HOME/not-a-repo"
  mkdir -p "$nongit_repo/lib" "$nongit_repo/config"
  : > "$nongit_repo/setup.sh"
  : > "$nongit_repo/lib/features.sh"
  printf '%s\n' '{}' > "$nongit_repo/config/plugins.json"
  printf 'KIT_REPO="%s"\n' "$nongit_repo" > "$config_file"
  local nongit_rc=0
  HOME="$HOME" bash -eu -c "$resolver_command" >/dev/null 2>&1 || nongit_rc=$?

  local incomplete_repo="$HOME/incomplete-repo"
  mkdir -p "$incomplete_repo/lib"
  : > "$incomplete_repo/setup.sh"
  : > "$incomplete_repo/lib/features.sh"
  git init -q "$incomplete_repo"
  printf 'KIT_REPO="%s"\n' "$incomplete_repo" > "$config_file"
  local incomplete_rc=0
  HOME="$HOME" bash -eu -c "$resolver_command" >/dev/null 2>&1 || incomplete_rc=$?

  if [[ "$custom_ok" == "yes" && "$bound_ok" == "yes" ]] \
    && [[ "$fallback_manifest_ok" == "yes" ]] \
    && [[ "$fallback_ok" == "yes" && "$legacy_ok" == "yes" ]] \
    && [[ $relative_rc -ne 0 && $duplicate_rc -ne 0 ]] \
    && [[ $injection_rc -ne 0 && ! -e "$marker" ]] \
    && [[ $nongit_rc -ne 0 && $incomplete_rc -ne 0 ]]; then
    pass "update-kit-repo-resolution"
  else
    fail "update-kit-repo-resolution (custom=$custom_ok bound=$bound_ok legacy-mdm=$fallback_manifest_ok fallback=$fallback_ok legacy=$legacy_ok relative=$relative_rc duplicate=$duplicate_rc injection=$injection_rc nongit=$nongit_rc incomplete=$incomplete_rc)"
  fi

  teardown_test_env
}

# --- 34b. update-kit-pending-finalize-safe ---
test_update_kit_pending_finalize_safe() {
  setup_test_env
  mkdir -p "$CLAUDE_DIR"
  local command_file="$PROJECT_DIR/commands/update-kit.md"
  local pending="$CLAUDE_DIR/.starter-kit-pending-features.json"
  local step1_script step7_script
  step1_script="$(awk '
    /^#### Step 1:/ { within_step = 1; next }
    /^#### Step 2:/ { exit }
    within_step && /^```bash$/ { in_code = 1; next }
    within_step && in_code && /^```$/ { in_code = 0; next }
    within_step && in_code { print }
  ' "$command_file")"
  step7_script="$(awk '
    /^#### Step 7:/ { within_step = 1; next }
    /^#### Step 8:/ { exit }
    within_step && /^```bash$/ { in_code = 1; next }
    within_step && in_code && /^```$/ { in_code = 0; next }
    within_step && in_code { print }
  ' "$command_file")"

  local static_ok=no
  if grep -Fq 'mktemp "$pending_dir/.starter-kit-pending-features.json.tmp.XXXXXX"' "$command_file" \
    && grep -Fq 'mktemp "$pending_dir/.starter-kit-pending-features.json.snapshot.XXXXXX"' "$command_file" \
    && grep -Fq 'chmod 600 "$pending_tmp"' "$command_file" \
    && grep -Fq 'mv "$pending_tmp" "$pending_file" || exit 1' "$command_file" \
    && [[ "$(grep -Fc 'jq -e -s' "$command_file")" -eq 2 ]] \
    && grep -Fq '"$pending_snapshot" > "$pending_tmp" || exit 1' "$command_file" \
    && [[ "$(grep -Fc 'Invalid pending file; preserved unchanged' "$command_file")" -eq 3 ]] \
    && ! grep -Fq '/tmp/pf.$$' "$command_file"; then
    static_ok=yes
  fi

  printf '%s\n' \
    '{"features":["doc-size-guard","keep-feature"],"plugins":["claude-security","keep-plugin"],"meta":"keep"}' \
    > "$pending"
  chmod 644 "$pending"
  local keep_rc=0
  HOME="$HOME" bash -eu -c "$step7_script" >/dev/null 2>&1 || keep_rc=$?
  local keep_ok=no
  if [[ $keep_rc -eq 0 ]] \
    && jq -e '.features == ["keep-feature"] and .plugins == ["keep-plugin"] and .meta == "keep"' "$pending" >/dev/null 2>&1 \
    && [[ "$(test_stat_mode "$pending")" == "600" ]]; then
    keep_ok=yes
  fi

  printf '%s\n' '{"features":["doc-size-guard"],"plugins":["claude-security"]}' > "$pending"
  local empty_rc=0
  HOME="$HOME" bash -eu -c "$step7_script" >/dev/null 2>&1 || empty_rc=$?
  local empty_ok=no
  [[ $empty_rc -eq 0 && ! -e "$pending" ]] && empty_ok=yes

  : > "$pending"
  chmod 640 "$pending"
  local zero_step1_rc=0 zero_step7_rc=0
  HOME="$HOME" bash -eu -c "$step1_script" >/dev/null 2>&1 || zero_step1_rc=$?
  HOME="$HOME" bash -eu -c "$step7_script" >/dev/null 2>&1 || zero_step7_rc=$?
  local zero_ok=no
  if [[ $zero_step1_rc -ne 0 && $zero_step7_rc -ne 0 ]] \
    && [[ -f "$pending" && ! -s "$pending" ]] \
    && [[ "$(test_stat_mode "$pending")" == "640" ]]; then
    zero_ok=yes
  fi

  printf '%s\n' '{not-json' > "$pending"
  chmod 640 "$pending"
  local malformed_before malformed_after malformed_step1_rc=0 malformed_step7_rc=0
  malformed_before="$(cat "$pending")"
  HOME="$HOME" bash -eu -c "$step1_script" >/dev/null 2>&1 || malformed_step1_rc=$?
  HOME="$HOME" bash -eu -c "$step7_script" >/dev/null 2>&1 || malformed_step7_rc=$?
  malformed_after="$(cat "$pending")"
  local malformed_ok=no
  if [[ $malformed_step1_rc -ne 0 && $malformed_step7_rc -ne 0 ]] \
    && [[ "$malformed_after" == "$malformed_before" ]] \
    && [[ "$(test_stat_mode "$pending")" == "640" ]] \
    && [[ -z "$(find "$CLAUDE_DIR" -name '.starter-kit-pending-features.json.*' -prune -print)" ]]; then
    malformed_ok=yes
  fi

  printf '%s\n' \
    '{"features":"not-an-array"}' \
    '{"features":["doc-size-guard"],"plugins":["claude-security"]}' \
    > "$pending"
  chmod 640 "$pending"
  local multiple_before="$HOME/pending-multiple-before"
  cp "$pending" "$multiple_before"
  local multiple_step1_rc=0 multiple_step7_rc=0
  HOME="$HOME" bash -eu -c "$step1_script" >/dev/null 2>&1 || multiple_step1_rc=$?
  local multiple_step1_preserved=no
  if [[ $multiple_step1_rc -ne 0 ]] && cmp -s "$multiple_before" "$pending"; then
    multiple_step1_preserved=yes
  fi
  HOME="$HOME" bash -eu -c "$step7_script" >/dev/null 2>&1 || multiple_step7_rc=$?
  local multiple_ok=no
  if [[ "$multiple_step1_preserved" == "yes" && $multiple_step7_rc -ne 0 ]] \
    && cmp -s "$multiple_before" "$pending" \
    && [[ "$(test_stat_mode "$pending")" == "640" ]] \
    && [[ -z "$(find "$CLAUDE_DIR" -name '.starter-kit-pending-features.json.*' -prune -print)" ]]; then
    multiple_ok=yes
  fi

  local symlink_target="$CLAUDE_DIR/pending-target"
  printf '%s\n' 'sentinel' > "$symlink_target"
  rm -f "$pending"
  ln -s "$symlink_target" "$pending"
  local symlink_rc=0
  HOME="$HOME" bash -eu -c "$step7_script" >/dev/null 2>&1 || symlink_rc=$?
  local symlink_ok=no
  if [[ $symlink_rc -ne 0 && -L "$pending" ]] \
    && [[ "$(cat "$symlink_target")" == "sentinel" ]]; then
    symlink_ok=yes
  fi

  if [[ "$static_ok" == "yes" && "$keep_ok" == "yes" \
    && "$empty_ok" == "yes" && "$zero_ok" == "yes" \
    && "$malformed_ok" == "yes" && "$multiple_ok" == "yes" \
    && "$symlink_ok" == "yes" ]]; then
    pass "update-kit-pending-finalize-safe"
  else
    fail "update-kit-pending-finalize-safe (static=$static_ok keep=$keep_ok empty=$empty_ok zero=$zero_ok malformed=$malformed_ok multiple=$multiple_ok symlink=$symlink_ok)"
  fi

  teardown_test_env
}

# --- 35. biome-hooks-full-profile ---
test_biome_hooks_full_profile() {
  setup_test_env
  local rc=0
  run_setup --profile=full >/dev/null 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] \
    && jq -e 'any(.hooks.PostToolUse[]?; (.hooks[0].command? // "") | contains("biome-hooks/format-file.sh"))' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1 \
    && ! jq -e 'any(.hooks.PostToolUse[]?; (.hooks[0].command? // "") | contains("prettier-hooks/format-file.sh"))' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
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
    && jq -e 'any(.hooks.PostToolUse[]?; (.hooks[0].command? // "") | contains("prettier-hooks/format-file.sh"))' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1 \
    && ! jq -e 'any(.hooks.PostToolUse[]?; (.hooks[0].command? // "") | contains("biome-hooks/format-file.sh"))' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
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
    && ! jq -e 'any(.hooks.PostToolUse[]?; (.hooks[0].command? // "") | contains("prettier-hooks/format-file.sh") or contains("biome-hooks/format-file.sh"))' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
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
  printf '%s\n' \
    '#!/bin/bash' \
    'if [[ "$1" == "--prefix" ]]; then' \
    "  echo \"$stub_dir\"" \
    '  exit 0' \
    'fi' \
    'if [[ "$1" == "install" && "$2" == "biome" ]]; then' \
    "  printf '%s\\n' '#!/bin/bash' 'echo \"biome 1.0.0\"' > \"$stub_dir/biome\"" \
    "  chmod +x \"$stub_dir/biome\"" \
    '  exit 0' \
    'fi' \
    'exit 1' \
    > "$stub_dir/brew"
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
    && jq -e 'any(.hooks.PostToolUse[]?; (.hooks[0].command? // "") | contains("prettier-hooks/format-file.sh"))' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1 \
    && ! jq -e 'any(.hooks.PostToolUse[]?; (.hooks[0].command? // "") | contains("biome-hooks/format-file.sh"))' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
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
    && ! jq -e 'any(.hooks.PostToolUse[]?; (.hooks[0].command? // "") | contains("prettier-hooks/format-file.sh") or contains("biome-hooks/format-file.sh"))' "$CLAUDE_DIR/settings.json" >/dev/null 2>&1; then
    pass "biome-auto-install-respects-legacy-disable-on-full"
  else
    fail "biome-auto-install-respects-legacy-disable-on-full"
  fi

  teardown_test_env
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

run_scenario core test_fresh_install_clean
run_scenario core test_fresh_install_ja
run_scenario core test_fresh_install_existing
run_scenario core test_dry_run_no_mutation
run_scenario core test_uninstall_preserve_user
run_scenario core test_snapshot_baseline
run_scenario core test_merge_prefs_persist
run_scenario core test_settings_array_merge
run_scenario core test_safety_net_first
run_scenario core test_registry_consistency
run_scenario core test_bash_version_check
run_scenario core test_bash_reexec
run_scenario core test_bash4_noninteractive_unavailable
run_scenario core test_dry_run_progress_output
run_scenario core test_dry_run_quiet_merge_summary

# update: update execution flow (version migrations, recovery, hooks, output)
run_scenario update test_update_no_changes
run_scenario update test_update_feature_toggle
run_scenario update test_update_from_v019
run_scenario update test_update_from_v020
run_scenario update test_update_from_no_manifest
run_scenario update test_update_v019_to_latest_direct
run_scenario update test_update_partial_failure_recovery
run_scenario update test_update_progress_output
run_scenario update test_auto_update_session_hooks
run_scenario update test_auto_update_legacy_claude_fallback
run_scenario update test_update_kit_command_paths
run_scenario update test_update_kit_repo_resolution
run_scenario update test_update_kit_pending_finalize_safe
run_scenario update test_update_adopts_new_catalog_plugin

# update-merge: 3-way merge decisions, CLAUDE.md sections, snapshot handling
run_scenario update-merge test_update_kit_changed
run_scenario update-merge test_update_user_changed
run_scenario update-merge test_claudemd_migration
run_scenario update-merge test_claudemd_section_preserve
run_scenario update-merge test_claudemd_kit_edit_conflict
run_scenario update-merge test_update_from_v020_customized
run_scenario update-merge test_update_noninteractive_safe
run_scenario update-merge test_snapshot_format_v019_to_latest
run_scenario update-merge test_snapshot_format_v020_compat
run_scenario update-merge test_snapshot_double_marker_repair

run_scenario features test_biome_hooks_full_profile
run_scenario features test_biome_hooks_standard_profile
run_scenario features test_biome_hooks_minimal_profile
run_scenario features test_biome_auto_install_full_profile
run_scenario features test_biome_auto_install_opt_in
run_scenario features test_biome_auto_install_disabled_standard
run_scenario features test_biome_auto_install_disabled_minimal
run_scenario features test_biome_auto_install_respects_saved_prettier_on_full
run_scenario features test_biome_auto_install_respects_legacy_disable_on_full

print_summary
