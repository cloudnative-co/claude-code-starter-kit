#!/bin/bash
# tests/unit/test-merge.sh - Unit tests for lib/merge.sh
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded).
# Tests _merge_settings_bootstrap, _merge_arrays_3way,
# _prompt_scalar_conflict, _prompt_array_conflict, and merge prefs.

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
source "$PROJECT_DIR/lib/colors.sh"
source "$PROJECT_DIR/lib/merge.sh"

# Suppress interactive prompts for all tests
_MERGE_INTERACTIVE=false

# Provide i18n strings used by merge.sh (referenced indirectly via $STR_*)
# shellcheck disable=SC2034
STR_MERGE_SCALAR_CONFLICT="Conflict on key:"
# shellcheck disable=SC2034
STR_MERGE_SCALAR_YOUR_VALUE="Your value :"
# shellcheck disable=SC2034
STR_MERGE_SCALAR_KIT_VALUE="Kit's value:"
# shellcheck disable=SC2034
STR_MERGE_SCALAR_PROMPT="[K]eep yours / [U]se kit's:"
# shellcheck disable=SC2034
STR_MERGE_ARRAY_CONFLICT="Array conflict on:"
# shellcheck disable=SC2034
STR_MERGE_ARRAY_YOURS="Yours"
# shellcheck disable=SC2034
STR_MERGE_ARRAY_KITS="Kit's"
# shellcheck disable=SC2034
STR_MERGE_ARRAY_ENTRIES="entries"
# shellcheck disable=SC2034
STR_MERGE_ARRAY_PROMPT="[K]eep / [U]se kit's:"
# shellcheck disable=SC2034
STR_MERGE_ARRAY_REPROMPT="[K]eep / [U]se kit's:"
# shellcheck disable=SC2034
STR_MERGE_ARRAY_KIT_REMOVED="The kit removed an array item:"
# shellcheck disable=SC2034
STR_MERGE_ARRAY_KEEP_REMOVE="[K]eep / [R]emove:"
# shellcheck disable=SC2034
STR_MERGE_REMEMBERED_KEEP="-> keep yours"
# shellcheck disable=SC2034
STR_MERGE_REMEMBERED_KIT="-> use kit's"
# shellcheck disable=SC2034
STR_MERGE_OBJECT_CONFLICT_KIT_WINS="(both are objects) -- using kit version"
# shellcheck disable=SC2034
STR_MERGE_3WAY_STARTING="Starting 3-way merge:"

# ---------------------------------------------------------------------------
# Helper: write JSON to a temp file and print its path
# ---------------------------------------------------------------------------
_write_json() {
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$1" > "$tmp"
  printf '%s' "$tmp"
}

# ---------------------------------------------------------------------------
# 1. _merge_settings_bootstrap: kit-only keys adopted
# ---------------------------------------------------------------------------
{
  test_name="bootstrap: kit-only keys are adopted"
  current="$(_write_json '{"userKey": "custom"}')"
  new_kit="$(_write_json '{"userKey": "custom", "kitOnly": true}')"
  output="$(mktemp)"

  run_func _merge_settings_bootstrap "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] \
    && assert_json_field "$output" '.kitOnly' "true" \
    && assert_json_field "$output" '.userKey' "custom"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$current" "$new_kit" "$output"
}

# ---------------------------------------------------------------------------
# 2. _merge_settings_bootstrap: user-only keys preserved
# ---------------------------------------------------------------------------
{
  test_name="bootstrap: user-only keys are preserved"
  current="$(_write_json '{"mcpServers": {"my-server": {}}}')"
  new_kit="$(_write_json '{"allowedTools": ["Bash"]}')"
  output="$(mktemp)"

  run_func _merge_settings_bootstrap "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] \
    && assert_json_has_key "$output" '.mcpServers' \
    && assert_json_has_key "$output" '.allowedTools'; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$current" "$new_kit" "$output"
}

# ---------------------------------------------------------------------------
# 3. _merge_settings_bootstrap: shared key keeps user value (non-interactive)
# ---------------------------------------------------------------------------
{
  test_name="bootstrap: shared scalar keeps user value (non-interactive)"
  current="$(_write_json '{"theme": "dark"}')"
  new_kit="$(_write_json '{"theme": "light"}')"
  output="$(mktemp)"

  run_func _merge_settings_bootstrap "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] \
    && assert_json_field "$output" '.theme' "dark"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$current" "$new_kit" "$output"
}

# ---------------------------------------------------------------------------
# 4. _merge_settings_bootstrap: identical values unchanged
# ---------------------------------------------------------------------------
{
  test_name="bootstrap: identical values stay unchanged"
  current="$(_write_json '{"flag": true, "count": 42}')"
  new_kit="$(_write_json '{"flag": true, "count": 42}')"
  output="$(mktemp)"

  run_func _merge_settings_bootstrap "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] \
    && assert_json_field "$output" '.flag' "true" \
    && assert_json_field "$output" '.count' "42"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$current" "$new_kit" "$output"
}

# ---------------------------------------------------------------------------
# 5. _merge_settings_bootstrap: object merge adopts new sub-keys only
# ---------------------------------------------------------------------------
{
  test_name="bootstrap: object merge adopts kit-only sub-keys"
  current="$(_write_json '{"permissions": {"allow": ["Bash"], "deny": ["rm"]}}')"
  new_kit="$(_write_json '{"permissions": {"allow": ["Read"], "deny": ["rm"], "audit": true}}')"
  output="$(mktemp)"

  run_func _merge_settings_bootstrap "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] \
    && assert_json_field "$output" '.permissions.audit' "true" \
    && assert_json_field "$output" '.permissions.deny[0]' "rm"; then
    # User's "allow" should be kept (not overwritten by kit)
    actual_allow="$(jq -c '.permissions.allow' "$output")"
    if assert_equals '["Bash"]' "$actual_allow"; then
      pass "$test_name"
    else
      fail "$test_name"
    fi
  else
    fail "$test_name"
  fi
  rm -f "$current" "$new_kit" "$output"
}

# ---------------------------------------------------------------------------
# 6. _merge_settings_bootstrap: output is valid JSON
# ---------------------------------------------------------------------------
{
  test_name="bootstrap: output is always valid JSON"
  current="$(_write_json '{"a": 1, "b": [1,2], "c": {"x": true}}')"
  new_kit="$(_write_json '{"b": [3,4], "c": {"y": false}, "d": "new"}')"
  output="$(mktemp)"

  run_func _merge_settings_bootstrap "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] && jq empty "$output" 2>/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$current" "$new_kit" "$output"
}

# ---------------------------------------------------------------------------
# 7. _merge_arrays_3way: user additions preserved, kit additions added
# ---------------------------------------------------------------------------
{
  test_name="arrays_3way: user additions + kit additions merged"
  snapshot='["a","b"]'
  current='["a","b","user-added"]'
  new_kit='["a","b","kit-added"]'

  run_func _merge_arrays_3way "$snapshot" "$current" "$new_kit"

  # Result should contain: a, b, kit-added, user-added (deduplicated, sorted by unique)
  result="$_RF_STDOUT"
  has_user="$(printf '%s' "$result" | jq 'map(select(. == "user-added")) | length')"
  has_kit="$(printf '%s' "$result" | jq 'map(select(. == "kit-added")) | length')"
  has_a="$(printf '%s' "$result" | jq 'map(select(. == "a")) | length')"
  has_b="$(printf '%s' "$result" | jq 'map(select(. == "b")) | length')"

  if [[ "$_RF_RC" -eq 0 ]] \
    && [[ "$has_user" -eq 1 ]] \
    && [[ "$has_kit" -eq 1 ]] \
    && [[ "$has_a" -eq 1 ]] \
    && [[ "$has_b" -eq 1 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# ---------------------------------------------------------------------------
# 8. _merge_arrays_3way: kit-removed items kept in non-interactive mode
# ---------------------------------------------------------------------------
{
  test_name="arrays_3way: kit-removed items kept (non-interactive)"
  snapshot='["a","b","c"]'
  current='["a","b","c"]'
  new_kit='["a","b"]'

  run_func _merge_arrays_3way "$snapshot" "$current" "$new_kit"

  result="$_RF_STDOUT"
  has_c="$(printf '%s' "$result" | jq 'map(select(. == "c")) | length')"

  if [[ "$_RF_RC" -eq 0 ]] && [[ "$has_c" -eq 1 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# ---------------------------------------------------------------------------
# 9. _prompt_scalar_conflict: non-interactive keeps user value
# ---------------------------------------------------------------------------
{
  test_name="scalar_conflict: non-interactive keeps user value"

  run_func _prompt_scalar_conflict "testKey" '"user-val"' '"kit-val"'

  if [[ "$_RF_RC" -eq 0 ]] \
    && assert_equals '"user-val"' "$_RF_STDOUT"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# ---------------------------------------------------------------------------
# 10. _prompt_array_conflict: non-interactive merges at element level
# ---------------------------------------------------------------------------
{
  test_name="array_conflict: non-interactive merges elements"

  run_func _prompt_array_conflict "hooks" '["orig"]' '["orig","user-item"]' '["orig","kit-item"]'

  result="$_RF_STDOUT"
  has_user="$(printf '%s' "$result" | jq 'map(select(. == "user-item")) | length')"
  has_kit="$(printf '%s' "$result" | jq 'map(select(. == "kit-item")) | length')"

  if [[ "$_RF_RC" -eq 0 ]] \
    && [[ "$has_user" -eq 1 ]] \
    && [[ "$has_kit" -eq 1 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# ---------------------------------------------------------------------------
# 11. merge prefs: save and retrieve
# ---------------------------------------------------------------------------
{
  test_name="merge_prefs: save and get round-trip"
  prefs_dir="$(mktemp -d)"
  _MERGE_PREFS_FILE=""
  _MERGE_PREFS_LOADED=false
  _MERGE_PREFS="{}"
  # shellcheck disable=SC2034
  CLAUDE_DIR="$prefs_dir"

  _save_merge_pref "myKey" "keep-mine"
  got="$(_get_merge_pref "myKey")"

  if assert_equals "keep-mine" "$got"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$prefs_dir"

  # Reset for subsequent tests
  _MERGE_PREFS_FILE=""
  _MERGE_PREFS_LOADED=false
  _MERGE_PREFS="{}"
}

# ---------------------------------------------------------------------------
# 12. merge_settings_3way: full three-way merge
# ---------------------------------------------------------------------------
{
  test_name="3way: user-untouched key updated, user-changed key kept"
  snapshot="$(_write_json '{"unchanged": "v1", "usermod": "v1", "kitonly_new": null}')"
  # Patch snapshot to remove the null key so it's truly absent
  snapshot_clean="$(mktemp)"
  jq 'del(.kitonly_new)' "$snapshot" > "$snapshot_clean"
  mv "$snapshot_clean" "$snapshot"

  current="$(_write_json '{"unchanged": "v1", "usermod": "user-v2"}')"
  new_kit="$(_write_json '{"unchanged": "v2", "usermod": "v1", "kitonly_new": "added"}')"
  output="$(mktemp)"

  run_func merge_settings_3way "$snapshot" "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] \
    && assert_json_field "$output" '.unchanged' "v2" \
    && assert_json_field "$output" '.usermod' "user-v2" \
    && assert_json_field "$output" '.kitonly_new' "added"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$snapshot" "$current" "$new_kit" "$output"
}
