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
source "$PROJECT_DIR/lib/progress.sh"
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
# 12. merge_settings_3way: false is a real kit value, not a missing key
# ---------------------------------------------------------------------------
{
  test_name="3way: kit false values are preserved instead of treated as missing"
  snapshot="$(_write_json '{"flag": true}')"
  current="$(_write_json '{"flag": true}')"
  new_kit="$(_write_json '{"flag": false, "newFalse": false}')"
  output="$(mktemp)"

  run_func merge_settings_3way "$snapshot" "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] \
    && jq -e '.flag == false' "$output" >/dev/null \
    && jq -e '.newFalse == false' "$output" >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$snapshot" "$current" "$new_kit" "$output"
}

# ---------------------------------------------------------------------------
# 13. _merge_object_3way: false sub-key values are preserved
#     (current carries a user-added sub-key so the parent object is
#      both-changed and the merge actually descends into _merge_object_3way
#      instead of adopting the kit object wholesale at top level)
# ---------------------------------------------------------------------------
{
  test_name="3way: nested kit false values are preserved"
  snapshot="$(_write_json '{"features": {"enabled": true}}')"
  current="$(_write_json '{"features": {"enabled": true, "userFlag": "custom"}}')"
  new_kit="$(_write_json '{"features": {"enabled": false, "newFlag": false}}')"
  output="$(mktemp)"

  run_func merge_settings_3way "$snapshot" "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] \
    && jq -e '.features.enabled == false' "$output" >/dev/null \
    && jq -e '.features.newFlag == false' "$output" >/dev/null \
    && jq -e '.features.userFlag == "custom"' "$output" >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$snapshot" "$current" "$new_kit" "$output"
}

# ---------------------------------------------------------------------------
# 14. merge_settings_3way: full three-way merge
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

# ---------------------------------------------------------------------------
# 15. _merge_object_3way: kit-removed sub-key + use-kit pref deletes the key
#     (regression: literal JSON null used to be written instead)
# ---------------------------------------------------------------------------
{
  test_name="3way: kit-removed env sub-key with use-kit pref is deleted, not null"
  snapshot="$(_write_json '{"env": {"OLDKEY": "1", "KEEP": "x"}}')"
  current="$(_write_json '{"env": {"OLDKEY": "0", "KEEP": "x"}}')"
  new_kit="$(_write_json '{"env": {"NEWKEY": "1", "KEEP": "x"}}')"
  output="$(mktemp)"

  # Remembered "use kit's" answer for the conflicting sub-key (no prompt)
  _MERGE_PREFS='{"env.OLDKEY": "use-kit"}'
  _MERGE_PREFS_LOADED=true

  run_func merge_settings_3way "$snapshot" "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] \
    && jq -e '.env | has("OLDKEY") | not' "$output" >/dev/null \
    && assert_json_field "$output" '.env.NEWKEY' "1" \
    && assert_json_field "$output" '.env.KEEP' "x"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$snapshot" "$current" "$new_kit" "$output"

  # Reset prefs for subsequent tests
  _MERGE_PREFS_FILE=""
  _MERGE_PREFS_LOADED=false
  _MERGE_PREFS="{}"
}

# ---------------------------------------------------------------------------
# 16. _merge_object_3way: user-deleted sub-key stays deleted
#     (regression: kit-unchanged sub-key was resurrected as literal null)
# ---------------------------------------------------------------------------
{
  test_name="3way: user-deleted env sub-key is not resurrected as null"
  snapshot="$(_write_json '{"env": {"A": "1", "B": "2"}}')"
  current="$(_write_json '{"env": {"B": "2"}}')"
  new_kit="$(_write_json '{"env": {"A": "1", "B": "2", "C": "3"}}')"
  output="$(mktemp)"

  run_func merge_settings_3way "$snapshot" "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] \
    && jq -e '.env | has("A") | not' "$output" >/dev/null \
    && assert_json_field "$output" '.env.B' "2" \
    && assert_json_field "$output" '.env.C' "3"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$snapshot" "$current" "$new_kit" "$output"
}

# ---------------------------------------------------------------------------
# 17. merge_settings_3way: kit-removed top-level key + use-kit pref deletes it
#     (regression: literal JSON null used to be written instead)
# ---------------------------------------------------------------------------
{
  test_name="3way: kit-removed top-level key with use-kit pref is deleted, not null"
  snapshot="$(_write_json '{"oldTop": "1", "stay": "x"}')"
  current="$(_write_json '{"oldTop": "0", "stay": "x"}')"
  new_kit="$(_write_json '{"stay": "x"}')"
  output="$(mktemp)"

  _MERGE_PREFS='{"oldTop": "use-kit"}'
  _MERGE_PREFS_LOADED=true

  run_func merge_settings_3way "$snapshot" "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] \
    && jq -e 'has("oldTop") | not' "$output" >/dev/null \
    && assert_json_field "$output" '.stay' "x"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$snapshot" "$current" "$new_kit" "$output"

  # Reset prefs for subsequent tests
  _MERGE_PREFS_FILE=""
  _MERGE_PREFS_LOADED=false
  _MERGE_PREFS="{}"
}

# ---------------------------------------------------------------------------
# 18. merge_settings_3way: user-changed top-level false value is kept
#     (kit unchanged; false must not be misread as a missing key)
# ---------------------------------------------------------------------------
{
  test_name="3way: user-changed top-level false value is kept (kit unchanged)"
  snapshot="$(_write_json '{"flag": true, "stay": "x"}')"
  current="$(_write_json '{"flag": false, "stay": "x"}')"
  new_kit="$(_write_json '{"flag": true, "stay": "x"}')"
  output="$(mktemp)"

  run_func merge_settings_3way "$snapshot" "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] \
    && jq -e 'has("flag")' "$output" >/dev/null \
    && jq -e '.flag == false' "$output" >/dev/null \
    && assert_json_field "$output" '.stay' "x"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$snapshot" "$current" "$new_kit" "$output"
}

# ---------------------------------------------------------------------------
# 19. merge_settings_3way: both changed with user=false → key survives
#     (regression: pre-fix code mapped false to the missing-key sentinel and
#      the conflict resolution deleted the key from the output entirely)
# ---------------------------------------------------------------------------
{
  test_name="3way: both-changed top-level key with user false keeps false (keep-mine default)"
  snapshot="$(_write_json '{"flag": true}')"
  current="$(_write_json '{"flag": false}')"
  new_kit="$(_write_json '{"flag": "kit-v2"}')"
  output="$(mktemp)"

  run_func merge_settings_3way "$snapshot" "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] \
    && jq -e 'has("flag")' "$output" >/dev/null \
    && jq -e '.flag == false' "$output" >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$snapshot" "$current" "$new_kit" "$output"
}

# ---------------------------------------------------------------------------
# 20. _merge_object_3way: both-changed sub-key with user=false → key survives
#     (regression: pre-fix code deleted the sub-key from the output entirely)
# ---------------------------------------------------------------------------
{
  test_name="3way: nested both-changed sub-key with user false keeps false (keep-mine default)"
  snapshot="$(_write_json '{"env": {"DEBUG": true}}')"
  current="$(_write_json '{"env": {"DEBUG": false}}')"
  new_kit="$(_write_json '{"env": {"DEBUG": "verbose"}}')"
  output="$(mktemp)"

  run_func merge_settings_3way "$snapshot" "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] \
    && jq -e '.env | has("DEBUG")' "$output" >/dev/null \
    && jq -e '.env.DEBUG == false' "$output" >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$snapshot" "$current" "$new_kit" "$output"
}

# ---------------------------------------------------------------------------
# 21. _merge_settings_bootstrap: kit-only false values are adopted
#     (regression: pre-fix code mapped false to the missing-key sentinel so
#      a new kit key with value false was never adopted)
# ---------------------------------------------------------------------------
{
  test_name="bootstrap: kit-only false values are adopted, not dropped"
  current="$(_write_json '{"userKey": "custom"}')"
  new_kit="$(_write_json '{"newFlag": false, "feature": {"enabled": false}}')"
  output="$(mktemp)"

  run_func _merge_settings_bootstrap "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] \
    && jq -e 'has("newFlag")' "$output" >/dev/null \
    && jq -e '.newFlag == false' "$output" >/dev/null \
    && jq -e '.feature.enabled == false' "$output" >/dev/null \
    && assert_json_field "$output" '.userKey' "custom"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$current" "$new_kit" "$output"
}

# ---------------------------------------------------------------------------
# 22. unified core: empty-snapshot 3way matches bootstrap for
#     kit-only / user-only / identical / differing-scalar keys
#     (issue #97: both entry points must resolve through _resolve_key_3way)
# ---------------------------------------------------------------------------
{
  test_name="unified: empty-snapshot 3way equals bootstrap (kit-only/user-only/scalar)"
  snapshot="$(_write_json '{}')"
  current="$(_write_json '{"userOnly": "u", "same": 1, "diff": "mine"}')"
  new_kit="$(_write_json '{"kitOnly": false, "same": 1, "diff": "kit"}')"
  out_3way="$(mktemp)"
  out_boot="$(mktemp)"

  run_func merge_settings_3way "$snapshot" "$current" "$new_kit" "$out_3way"
  rc_3way="$_RF_RC"
  run_func _merge_settings_bootstrap "$current" "$new_kit" "$out_boot"
  rc_boot="$_RF_RC"

  same_doc="$(jq -n --slurpfile a "$out_3way" --slurpfile b "$out_boot" '$a[0] == $b[0]')"

  if [[ "$rc_3way" -eq 0 ]] && [[ "$rc_boot" -eq 0 ]] \
    && [[ "$same_doc" == "true" ]] \
    && jq -e '.kitOnly == false' "$out_3way" >/dev/null \
    && jq -e '.userOnly == "u"' "$out_3way" >/dev/null \
    && jq -e '.diff == "mine"' "$out_3way" >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$snapshot" "$current" "$new_kit" "$out_3way" "$out_boot"
}

# ---------------------------------------------------------------------------
# 23. unified core: empty-snapshot 3way matches bootstrap for array conflicts
#     (drift fix #97: independent top-level array additions now element-merge
#      instead of falling into the raw-JSON scalar prompt)
# ---------------------------------------------------------------------------
{
  test_name="unified: empty-snapshot 3way equals bootstrap for array conflicts"
  snapshot="$(_write_json '{}')"
  current="$(_write_json '{"list": ["a", "user-item"]}')"
  new_kit="$(_write_json '{"list": ["a", "kit-item"]}')"
  out_3way="$(mktemp)"
  out_boot="$(mktemp)"

  run_func merge_settings_3way "$snapshot" "$current" "$new_kit" "$out_3way"
  rc_3way="$_RF_RC"
  run_func _merge_settings_bootstrap "$current" "$new_kit" "$out_boot"
  rc_boot="$_RF_RC"

  same_doc="$(jq -n --slurpfile a "$out_3way" --slurpfile b "$out_boot" '$a[0] == $b[0]')"

  if [[ "$rc_3way" -eq 0 ]] && [[ "$rc_boot" -eq 0 ]] \
    && [[ "$same_doc" == "true" ]] \
    && jq -e '.list | index("user-item") != null' "$out_3way" >/dev/null \
    && jq -e '.list | index("kit-item") != null' "$out_3way" >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$snapshot" "$current" "$new_kit" "$out_3way" "$out_boot"
}

# ---------------------------------------------------------------------------
# 24. drift fix #97: independent top-level object additions recurse into
#     sub-key resolution (kit-only sub-keys adopted, user sub-keys kept,
#     array sub-keys element-merged) instead of one raw-JSON scalar prompt
#     — mirrors a real v020→latest upgrade where the kit newly ships
#     "permissions" while the user already has their own
# ---------------------------------------------------------------------------
{
  test_name="3way: independent object additions merge per sub-key (drift fix)"
  snapshot="$(_write_json '{"language": "en"}')"
  current="$(_write_json '{"language": "en", "permissions": {"allow": ["Bash(npm run *)"], "custom": true}}')"
  new_kit="$(_write_json '{"language": "en", "permissions": {"allow": ["Read(**)"], "deny": ["rm"]}}')"
  output="$(mktemp)"

  run_func merge_settings_3way "$snapshot" "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] \
    && jq -e '.permissions.allow | index("Bash(npm run *)") != null' "$output" >/dev/null \
    && jq -e '.permissions.allow | index("Read(**)") != null' "$output" >/dev/null \
    && jq -e '.permissions.deny == ["rm"]' "$output" >/dev/null \
    && jq -e '.permissions.custom == true' "$output" >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$snapshot" "$current" "$new_kit" "$output"
}

# ---------------------------------------------------------------------------
# 25. _merge_object_3way wrapper: direct call regression
#     (kit-update / kit-remove / kit-add / user-added in one pass)
# ---------------------------------------------------------------------------
{
  test_name="object_3way: direct call resolves update/remove/add/user-added"
  merged='{"env": {"A": "1", "B": "2", "USER": "u"}}'
  s_val='{"A": "1", "B": "2"}'
  c_val='{"A": "1", "B": "2", "USER": "u"}'
  n_val='{"A": "9", "C": "3"}'

  run_func _merge_object_3way "env" "$s_val" "$c_val" "$n_val" merged

  if [[ "$_RF_RC" -eq 0 ]] \
    && jq -ne --argjson m "$merged" '$m.env.A == "9"' >/dev/null \
    && jq -ne --argjson m "$merged" '$m.env | has("B") | not' >/dev/null \
    && jq -ne --argjson m "$merged" '$m.env.C == "3"' >/dev/null \
    && jq -ne --argjson m "$merged" '$m.env.USER == "u"' >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  unset merged s_val c_val n_val
}

# ---------------------------------------------------------------------------
# 26. retained drift pin: nested both-changed object (depth 2) → kit wins
#     (documented in _resolve_key_3way; no recursion below depth 2)
# ---------------------------------------------------------------------------
{
  test_name="3way: depth-2 both-changed object resolves kit-wins (pinned)"
  snapshot="$(_write_json '{"parent": {"child": {"x": 1}}}')"
  current="$(_write_json '{"parent": {"child": {"x": 2}, "u": "keep"}}')"
  new_kit="$(_write_json '{"parent": {"child": {"x": 3}}}')"
  output="$(mktemp)"

  run_func merge_settings_3way "$snapshot" "$current" "$new_kit" "$output"

  if [[ "$_RF_RC" -eq 0 ]] \
    && jq -e '.parent.child.x == 3' "$output" >/dev/null \
    && jq -e '.parent.u == "keep"' "$output" >/dev/null; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -f "$snapshot" "$current" "$new_kit" "$output"
}

# ---------------------------------------------------------------------------
# 27. _json_key_or_null: false is a real value; missing and literal null
#     both map to the "null" sentinel (single home for the has($k) guard)
# ---------------------------------------------------------------------------
{
  test_name="json_key_or_null: false kept, missing/literal-null → sentinel"
  doc='{"f": false, "z": 0, "e": "", "n": null}'

  got_f="$(_json_key_or_null "$doc" "f")"
  got_z="$(_json_key_or_null "$doc" "z")"
  got_e="$(_json_key_or_null "$doc" "e")"
  got_n="$(_json_key_or_null "$doc" "n")"
  got_missing="$(_json_key_or_null "$doc" "missing")"

  if [[ "$got_f" == "false" ]] \
    && [[ "$got_z" == "0" ]] \
    && [[ "$got_e" == '""' ]] \
    && [[ "$got_n" == "null" ]] \
    && [[ "$got_missing" == "null" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  unset doc got_f got_z got_e got_n got_missing
}

# ---------------------------------------------------------------------------
# Interactive: identical values must never prompt (snapshot-missing object
# recursion — PR #106 review finding)
# ---------------------------------------------------------------------------
{
  test_name="3way: identical sub-keys under snapshot-missing object never prompt"
  snapshot="$(_write_json '{}')"
  current="$(_write_json '{"permissions": {"allow": ["a", "b"], "deny": ["x"]}}')"
  new_kit="$(_write_json '{"permissions": {"allow": ["a", "b"], "deny": ["x"], "ask": ["q"]}}')"
  output="$(mktemp)"

  _prev_interactive="${_MERGE_INTERACTIVE:-}"
  _MERGE_INTERACTIVE=true
  run_func merge_settings_3way "$snapshot" "$current" "$new_kit" "$output"
  if [[ -n "$_prev_interactive" ]]; then
    _MERGE_INTERACTIVE="$_prev_interactive"
  else
    unset _MERGE_INTERACTIVE
  fi

  # Identical allow/deny must merge silently (no conflict prompt on stderr);
  # the kit-only "ask" is adopted.
  if [[ "$_RF_RC" -eq 0 ]] \
    && jq -e '.permissions.allow == ["a", "b"]' "$output" >/dev/null \
    && jq -e '.permissions.deny == ["x"]' "$output" >/dev/null \
    && jq -e '.permissions.ask == ["q"]' "$output" >/dev/null \
    && ! grep -Eq 'conflict.*(allow|deny)' <<< "$_RF_STDERR"; then
    pass "$test_name"
  else
    fail "$test_name (stderr=$_RF_STDERR)"
  fi
  rm -f "$snapshot" "$current" "$new_kit" "$output"
  unset _prev_interactive
}
