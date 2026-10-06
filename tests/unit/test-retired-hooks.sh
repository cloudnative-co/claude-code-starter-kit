#!/bin/bash
# tests/unit/test-retired-hooks.sh - _strip_retired_hook_entries behavior

_rh_tmp="$(mktemp -d)"

_rh_run() {
  HOME=/home/u bash -c '
    set -uo pipefail
    PROJECT_DIR="'"$PROJECT_DIR"'"
    ok(){ :; }; warn(){ :; }; info(){ :; }; is_true(){ [[ "$1" == "true" ]]; }
    source "$PROJECT_DIR/lib/features.sh"
    source "$PROJECT_DIR/lib/snapshot.sh"
    source "$PROJECT_DIR/lib/update.sh" 2>/dev/null || true
    _strip_retired_hook_entries "'"$1"'"
  '
}

{
  test_name="retired-hooks: all retired feature entries are stripped in one pass"
  _rh_all="$_rh_tmp/all-retired.json"
  printf '%s\n' '{
  "hooks": {
    "PreToolUse": [
      {"matcher": "*", "hooks": [
        {"type": "command", "command": "/home/u/.claude/hooks/strategic-compact/suggest-compact.sh"},
        {"type": "command", "command": "/home/u/.claude/hooks/git-push-review/remind.sh"}
      ]}
    ],
    "PostToolUse": [
      {"matcher": "Edit|Write", "hooks": [
        {"type": "command", "command": "/home/u/.claude/hooks/console-log-guard/check-file.sh"}
      ]}
    ],
    "SessionStart": [
      {"matcher": "*", "hooks": [
        {"type": "command", "command": "/home/u/.claude/hooks/memory-persistence/session-start.sh"}
      ]}
    ]
  }
}' > "$_rh_all"
  _rh_run "$_rh_all" >/dev/null 2>&1
  if [[ "$(jq -r '.hooks | length' "$_rh_all")" == "0" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="retired-hooks: user script under a same-named dir outside ~/.claude is kept"
  _rh_user="$_rh_tmp/user-dir.json"
  printf '{"hooks":{"PreCompact":[{"matcher":"*","hooks":[{"type":"command","command":"/home/u/dotfiles/hooks/memory-persistence/mine.sh"},{"type":"command","command":"/tmp/.claude/hooks/memory-persistence/mine.sh"}]}]}}\n' > "$_rh_user"
  _rh_run "$_rh_user" >/dev/null 2>&1
  if [[ "$(jq -r '.hooks.PreCompact[0].hooks | length' "$_rh_user")" == "2" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="retired-hooks: memory-persistence entries are stripped, others kept"
  _rh_settings="$_rh_tmp/settings.json"
  printf '%s\n' '{
  "hooks": {
    "PreCompact": [
      {"matcher": "*", "hooks": [
        {"type": "command", "command": "/home/u/.claude/hooks/memory-persistence/pre-compact.sh"},
        {"type": "command", "command": "/home/u/.claude/hooks/custom/my-hook.sh"}
      ]}
    ],
    "PostCompact": [
      {"matcher": "*", "hooks": [
        {"type": "command", "command": "/home/u/.claude/hooks/memory-persistence/post-compact.sh"}
      ]}
    ],
    "SessionStart": [
      {"matcher": "*", "hooks": [
        {"type": "command", "command": "/home/u/.claude/hooks/auto-update/check.sh"}
      ]}
    ]
  },
  "statusLine": {"type": "command", "command": "x"}
}' > "$_rh_settings"
  _rh_run "$_rh_settings" >/dev/null 2>&1
  if [[ "$(jq -r '.hooks.PreCompact[0].hooks | length' "$_rh_settings")" == "1" ]] \
    && [[ "$(jq -r '.hooks.PreCompact[0].hooks[0].command' "$_rh_settings")" == *custom/my-hook.sh ]] \
    && [[ "$(jq -r '.hooks | has("PostCompact")' "$_rh_settings")" == "false" ]] \
    && [[ "$(jq -r '.hooks.SessionStart[0].hooks | length' "$_rh_settings")" == "1" ]] \
    && [[ "$(jq -r '.statusLine.command' "$_rh_settings")" == "x" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="retired-hooks: settings without retired entries are untouched"
  _rh_clean="$_rh_tmp/clean.json"
  printf '{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"/h/.claude/hooks/auto-update/check.sh"}]}]},"env":{"A":"1"}}\n' > "$_rh_clean"
  _rh_before="$(cat "$_rh_clean")"
  _rh_run "$_rh_clean" >/dev/null 2>&1
  if [[ "$(cat "$_rh_clean")" == "$_rh_before" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="retired-hooks: superseded inline hooks are removed without touching wrappers or user hooks"
  _rh_superseded="$_rh_tmp/superseded-inline.json"
  printf '%s\n' '{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [
        {"type": "command", "command": "cc-safety-net --claude-code"},
        {"type": "command", "command": "\"$HOME/.claude/hooks/safety-net/run-cc-safety-net.sh\" --claude-code"},
        {"type": "command", "command": "/home/u/bin/my-safety-check"}
      ]}
    ],
    "SessionStart": [
      {"matcher": "startup", "hooks": [
        {"type": "command", "command": "node /home/u/.claude/skills/web-content-extraction/scripts/update-deps.mjs", "async": true},
        {"type": "command", "command": "node __HOME__/.claude/skills/web-content-extraction/scripts/update-deps.mjs", "async": true},
        {"type": "command", "command": "node /tmp/.claude/skills/web-content-extraction/scripts/update-deps.mjs", "async": true},
        {"type": "command", "command": "\"$HOME/.claude/skills/web-content-extraction/scripts/run-node.sh\" \"$HOME/.claude/skills/web-content-extraction/scripts/update-deps.mjs\"", "async": true}
      ]}
    ]
  }
}' > "$_rh_superseded"
  _rh_run "$_rh_superseded" >/dev/null 2>&1
  if [[ "$(jq -r '[.. | objects | .command? // empty] | any(. == "cc-safety-net --claude-code")' "$_rh_superseded")" == "false" ]] \
    && [[ "$(jq -r '[.. | objects | .command? // empty] | any(. == "node /home/u/.claude/skills/web-content-extraction/scripts/update-deps.mjs")' "$_rh_superseded")" == "false" ]] \
    && [[ "$(jq -r '[.. | objects | .command? // empty] | any(. == "node __HOME__/.claude/skills/web-content-extraction/scripts/update-deps.mjs")' "$_rh_superseded")" == "false" ]] \
    && [[ "$(jq -r '[.. | objects | .command? // empty] | any(. == "node /tmp/.claude/skills/web-content-extraction/scripts/update-deps.mjs")' "$_rh_superseded")" == "true" ]] \
    && [[ "$(jq -r '[.. | objects | .command? // empty] | any(contains("run-cc-safety-net.sh"))' "$_rh_superseded")" == "true" ]] \
    && [[ "$(jq -r '[.. | objects | .command? // empty] | any(contains("scripts/run-node.sh"))' "$_rh_superseded")" == "true" ]] \
    && [[ "$(jq -r '[.. | objects | .command? // empty] | any(. == "/home/u/bin/my-safety-check")' "$_rh_superseded")" == "true" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="retired-hooks: feature registry no longer contains memory-persistence"
  if ! grep -q 'memory-persistence' "$PROJECT_DIR/lib/features.sh" \
    && [[ ! -d "$PROJECT_DIR/features/memory-persistence" ]] \
    && grep -q 'ENABLE_MEMORY_PERSISTENCE' \
      < <(grep '_CONFIG_LEGACY_KEYS=' "$PROJECT_DIR/wizard/registry.sh"); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="retired-hooks: matcher entries without inner hooks key do not break stripping"
  _rh_odd="$_rh_tmp/odd.json"
  cat > "$_rh_odd" <<'JSON'
{
  "hooks": {
    "PreCompact": [
      {"matcher": "*.py"},
      {"matcher": "*", "hooks": [
        {"type": "command", "command": "/home/u/.claude/hooks/memory-persistence/pre-compact.sh"}
      ]}
    ]
  }
}
JSON
  _rh_run "$_rh_odd" >/dev/null 2>&1
  if [[ "$(jq -r '.hooks | has("PreCompact")' "$_rh_odd")" == "false" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# ── _strip_superseded_kit_hook_generations ─────────────────────────────────
#
# The 3-way merge only runs when snapshot, current and new kit all differ, so
# a hooks array that already carries a stale kit generation next to the kit's
# current entry (#163) would persist until the kit next edits that very array.
# This post-merge sweep heals it on every update.
_rh_sweep() { # <settings-file> <kit-file>
  HOME=/home/u bash -c '
    set -uo pipefail
    PROJECT_DIR="'"$PROJECT_DIR"'"
    ok(){ :; }; warn(){ :; }; info(){ :; }; is_true(){ [[ "$1" == "true" ]]; }
    _SETUP_TMP_FILES=()
    source "$PROJECT_DIR/lib/features.sh"
    source "$PROJECT_DIR/lib/snapshot.sh"
    source "$PROJECT_DIR/lib/update.sh" 2>/dev/null || true
    _strip_superseded_kit_hook_generations "'"$1"'" "'"$2"'"
  '
}

_rh_kit="$_rh_tmp/kit-built.json"
printf '%s\n' '{
  "hooks": {
    "SessionStart": [
      {"matcher": "startup", "hooks": [{"type": "command", "command": "A.sh"}]}
    ],
    "PreToolUse": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "safety.sh"}]}
    ]
  }
}' > "$_rh_kit"

{
  test_name="superseded-generations: a stale kit generation next to the current entry is dropped"
  _rh_dup="$_rh_tmp/dup.json"
  printf '%s\n' '{
  "hooks": {
    "SessionStart": [
      {"matcher": "startup", "hooks": [{"type": "command", "command": "A.sh"}]},
      {"matcher": "*", "hooks": [{"type": "command", "command": "A.sh"}]}
    ],
    "PreToolUse": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "safety.sh"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "mine.sh"}]}
    ]
  }
}' > "$_rh_dup"
  _rh_sweep "$_rh_dup" "$_rh_kit" >/dev/null 2>&1
  if jq -e '
      (.hooks.SessionStart | length) == 1
      and .hooks.SessionStart[0].matcher == "startup"
      and (.hooks.PreToolUse | length) == 2
      and .hooks.PreToolUse[1].hooks[0].command == "mine.sh"' \
      "$_rh_dup" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="superseded-generations: a kit entry edited in place is left alone"
  _rh_edited="$_rh_tmp/edited.json"
  printf '%s\n' '{
  "hooks": {
    "SessionStart": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "A.sh"}]}
    ]
  }
}' > "$_rh_edited"
  _rh_sweep "$_rh_edited" "$_rh_kit" >/dev/null 2>&1
  if jq -e '
      (.hooks.SessionStart | length) == 1
      and .hooks.SessionStart[0].matcher == "*"' \
      "$_rh_edited" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="superseded-generations: user hooks and unknown events are untouched"
  _rh_mixed="$_rh_tmp/mixed.json"
  printf '%s\n' '{
  "hooks": {
    "SessionStart": [
      {"matcher": "startup", "hooks": [{"type": "command", "command": "A.sh"}]},
      {"matcher": "startup", "hooks": [{"type": "command", "command": "mine.sh"}]}
    ],
    "Stop": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "A.sh"}]}
    ]
  },
  "permissions": {"allow": ["Read"]}
}' > "$_rh_mixed"
  _rh_before="$(jq -cS . "$_rh_mixed")"
  _rh_sweep "$_rh_mixed" "$_rh_kit" >/dev/null 2>&1
  if [[ "$(jq -cS . "$_rh_mixed")" == "$_rh_before" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="superseded-generations: a missing or broken kit build changes nothing"
  _rh_safe="$_rh_tmp/safe.json"
  printf '{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"A.sh"}]}]}}\n' > "$_rh_safe"
  printf 'not json' > "$_rh_tmp/broken-kit.json"
  _rh_before="$(jq -cS . "$_rh_safe")"
  _rh_rc1=0; _rh_sweep "$_rh_safe" "$_rh_tmp/no-such-kit.json" >/dev/null 2>&1 || _rh_rc1=$?
  _rh_rc2=0; _rh_sweep "$_rh_safe" "$_rh_tmp/broken-kit.json" >/dev/null 2>&1 || _rh_rc2=$?
  if [[ "$_rh_rc1" -eq 0 && "$_rh_rc2" -eq 0 \
    && "$(jq -cS . "$_rh_safe")" == "$_rh_before" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# ── _migrate_legacy_hook_entries ───────────────────────────────────────────
#
# Until v0.78.x the kit generated a second shape of the auto-update and
# pr-creation-log hooks for Claude Code < 2.1.89 (hooks.legacy.json, retired
# in v0.79.0 / #136). Their commands carry an env prefix, so they are a
# different identity from the current entries and neither the 3-way merge nor
# the two sweeps above can pair them.
_rh_migrate() { # <settings-file> <kit-file>
  HOME=/home/u "${BASH:-bash}" -c '
    set -uo pipefail
    PROJECT_DIR="'"$PROJECT_DIR"'"
    ok(){ :; }; warn(){ :; }; info(){ :; }; is_true(){ [[ "$1" == "true" ]]; }
    _SETUP_TMP_FILES=()
    source "$PROJECT_DIR/lib/features.sh"
    source "$PROJECT_DIR/lib/snapshot.sh"
    source "$PROJECT_DIR/lib/update.sh" 2>/dev/null || true
    _migrate_legacy_hook_entries "'"$1"'" "'"$2"'"
  '
}

_rh_inode() { # <file> -> inode number (a rewrite through mktemp + mv changes it)
  # shellcheck disable=SC2012 # one known path; only the inode column is read
  ls -i "$1" | awk '{print $1}'
}

_rh_au='/home/u/.claude/hooks/auto-update/auto-update.sh'
_rh_pr='/home/u/.claude/hooks/pr-creation-log/log-pr.sh'
_rh_h_au_legacy='{"type":"command","command":"AUTO_UPDATE_LEGACY=1 AUTO_UPDATE_HOOK=SessionStart '"$_rh_au"'"}'
_rh_h_au_now='{"type":"command","command":"AUTO_UPDATE_HOOK=SessionStart '"$_rh_au"'","async":true,"asyncTimeout":300000}'
_rh_h_au_end='{"type":"command","command":"AUTO_UPDATE_HOOK=SessionEnd '"$_rh_au"'","async":true,"asyncTimeout":300000}'
_rh_h_pr_legacy='{"type":"command","command":"PR_CREATION_LOG_LEGACY=1 '"$_rh_pr"'"}'
_rh_h_pr_now='{"type":"command","if":"Bash(gh pr create *)","async":true,"command":"'"$_rh_pr"'"}'
_rh_h_user='{"type":"command","command":"echo user-hook"}'
_rh_e_au_legacy='{"matcher":"startup","hooks":['"$_rh_h_au_legacy"']}'
_rh_e_au_now='{"matcher":"startup","hooks":['"$_rh_h_au_now"']}'
_rh_e_au_end='{"matcher":"*","hooks":['"$_rh_h_au_end"']}'
_rh_e_pr_legacy='{"matcher":"Bash","hooks":['"$_rh_h_pr_legacy"']}'
_rh_e_pr_now='{"matcher":"Bash","hooks":['"$_rh_h_pr_now"']}'
_rh_e_user_start='{"matcher":"startup","hooks":['"$_rh_h_user"']}'
_rh_e_user_post='{"matcher":"Bash","hooks":['"$_rh_h_user"']}'

_rh_lg_kit="$_rh_tmp/legacy-kit.json"
printf '%s\n' '{"hooks":{"SessionStart":['"$_rh_e_au_now"'],"SessionEnd":['"$_rh_e_au_end"'],"PostToolUse":['"$_rh_e_pr_now"']}}' > "$_rh_lg_kit"
_rh_lg_kit_off="$_rh_tmp/legacy-kit-features-off.json"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"safety.sh"}]}]}}' > "$_rh_lg_kit_off"

{
  test_name="legacy-migration: a legacy entry next to the current one leaves only the current one"
  _rh_lg="$_rh_tmp/legacy-dup.json"
  printf '%s\n' '{"hooks":{
    "SessionStart":['"$_rh_e_au_legacy"','"$_rh_e_user_start"','"$_rh_e_au_now"'],
    "SessionEnd":['"$_rh_e_au_end"'],
    "PostToolUse":['"$_rh_e_pr_now"','"$_rh_e_user_post"','"$_rh_e_pr_legacy"']}}' > "$_rh_lg"
  _rh_rc=0; _rh_migrate "$_rh_lg" "$_rh_lg_kit" >/dev/null 2>&1 || _rh_rc=$?
  if [[ "$_rh_rc" -eq 0 ]] \
    && jq -e --argjson au "$_rh_e_au_now" --argjson pr "$_rh_e_pr_now" \
      --argjson us "$_rh_e_user_start" --argjson up "$_rh_e_user_post" \
      --argjson end "$_rh_e_au_end" '
      .hooks.SessionStart == [$us, $au]
      and .hooks.SessionEnd == [$end]
      and .hooks.PostToolUse == [$pr, $up]' "$_rh_lg" >/dev/null 2>&1 \
    && ! grep -q '_LEGACY=1' "$_rh_lg"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="legacy-migration: a legacy-only array (bootstrap merge) becomes the kit's current entry"
  _rh_lg="$_rh_tmp/legacy-only.json"
  printf '%s\n' '{"hooks":{
    "SessionStart":['"$_rh_e_au_legacy"','"$_rh_e_user_start"'],
    "PostToolUse":['"$_rh_e_pr_legacy"']},"env":{"A":"1"}}' > "$_rh_lg"
  _rh_rc=0; _rh_migrate "$_rh_lg" "$_rh_lg_kit" >/dev/null 2>&1 || _rh_rc=$?
  if [[ "$_rh_rc" -eq 0 ]] \
    && jq -e --slurpfile kit "$_rh_lg_kit" --argjson us "$_rh_e_user_start" '
      .hooks.SessionStart == [$kit[0].hooks.SessionStart[0], $us]
      and .hooks.PostToolUse == $kit[0].hooks.PostToolUse
      and .env == {"A":"1"}' "$_rh_lg" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="legacy-migration: repeated legacy entries collapse to a single current entry"
  _rh_lg="$_rh_tmp/legacy-twice.json"
  printf '%s\n' '{"hooks":{"SessionStart":['"$_rh_e_au_legacy"','"$_rh_e_user_start"','"$_rh_e_au_legacy"']}}' > "$_rh_lg"
  _rh_rc=0; _rh_migrate "$_rh_lg" "$_rh_lg_kit" >/dev/null 2>&1 || _rh_rc=$?
  if [[ "$_rh_rc" -eq 0 ]] \
    && jq -e --argjson au "$_rh_e_au_now" --argjson us "$_rh_e_user_start" '
      .hooks.SessionStart == [$au, $us]' "$_rh_lg" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="legacy-migration: a legacy entry of a feature the kit no longer ships is removed"
  _rh_lg="$_rh_tmp/legacy-feature-off.json"
  printf '%s\n' '{"hooks":{
    "SessionStart":['"$_rh_e_au_legacy"','"$_rh_e_user_start"'],
    "PostToolUse":['"$_rh_e_pr_legacy"'],
    "Stop":[]}}' > "$_rh_lg"
  _rh_rc=0; _rh_migrate "$_rh_lg" "$_rh_lg_kit_off" >/dev/null 2>&1 || _rh_rc=$?
  if [[ "$_rh_rc" -eq 0 ]] \
    && jq -e --argjson us "$_rh_e_user_start" '
      .hooks.SessionStart == [$us]
      and (.hooks | has("PostToolUse") | not)
      and .hooks.Stop == []' "$_rh_lg" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="legacy-migration: a legacy hook inside a user entry is replaced in place"
  _rh_lg="$_rh_tmp/legacy-mixed.json"
  printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"*","hooks":['"$_rh_h_user"','"$_rh_h_au_legacy"']}]}}' > "$_rh_lg"
  _rh_lg2="$_rh_tmp/legacy-mixed-with-current.json"
  printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"*","hooks":['"$_rh_h_user"','"$_rh_h_au_legacy"']},'"$_rh_e_au_now"']}}' > "$_rh_lg2"
  _rh_rc1=0; _rh_migrate "$_rh_lg" "$_rh_lg_kit" >/dev/null 2>&1 || _rh_rc1=$?
  _rh_rc2=0; _rh_migrate "$_rh_lg2" "$_rh_lg_kit" >/dev/null 2>&1 || _rh_rc2=$?
  if [[ "$_rh_rc1" -eq 0 && "$_rh_rc2" -eq 0 ]] \
    && jq -e --argjson hu "$_rh_h_user" --argjson hau "$_rh_h_au_now" '
      .hooks.SessionStart == [{"matcher":"*","hooks":[$hu, $hau]}]' "$_rh_lg" >/dev/null 2>&1 \
    && jq -e --argjson hu "$_rh_h_user" --argjson au "$_rh_e_au_now" '
      .hooks.SessionStart == [{"matcher":"*","hooks":[$hu]}, $au]' "$_rh_lg2" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="legacy-migration: unrelated entries in a migrated file are left exactly as they were"
  _rh_lg="$_rh_tmp/legacy-bystanders.json"
  printf '%s\n' '{"permissions":{"allow":["Read"]},"hooks":{
    "SessionStart":['"$_rh_e_user_start"','"$_rh_e_au_legacy"','"$_rh_e_user_start"',{"matcher":"*.py"}],
    "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"mine.sh"}]},{"matcher":"Bash","hooks":[{"type":"command","command":"mine.sh"}]}],
    "Stop":[]},"statusLine":{"type":"command","command":"x"}}' > "$_rh_lg"
  _rh_before="$(jq -cS 'del(.hooks.SessionStart)' "$_rh_lg")"
  _rh_rc=0; _rh_migrate "$_rh_lg" "$_rh_lg_kit" >/dev/null 2>&1 || _rh_rc=$?
  if [[ "$_rh_rc" -eq 0 \
    && "$(jq -cS 'del(.hooks.SessionStart)' "$_rh_lg")" == "$_rh_before" ]] \
    && jq -e --argjson au "$_rh_e_au_now" --argjson us "$_rh_e_user_start" '
      .hooks.SessionStart == [$us, $au, $us, {"matcher":"*.py"}]' "$_rh_lg" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="legacy-migration: settings without a legacy entry are not rewritten"
  _rh_lg="$_rh_tmp/legacy-none.json"
  # Compact, key order the kit never writes: any jq round trip changes bytes.
  printf '{"hooks":{"SessionStart":[%s,%s],"PostToolUse":[%s]},"env":{"A":"1"}}\n' \
    "$_rh_e_au_now" "$_rh_e_user_start" "$_rh_e_pr_now" > "$_rh_lg"
  _rh_before="$(cat "$_rh_lg")"
  _rh_inode_before="$(_rh_inode "$_rh_lg")"
  _rh_rc=0; _rh_migrate "$_rh_lg" "$_rh_lg_kit" >/dev/null 2>&1 || _rh_rc=$?
  if [[ "$_rh_rc" -eq 0 && "$(cat "$_rh_lg")" == "$_rh_before" \
    && "$(_rh_inode "$_rh_lg")" == "$_rh_inode_before" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="legacy-migration: look-alike commands the kit never generated are untouched"
  _rh_lg="$_rh_tmp/legacy-lookalike.json"
  printf '{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[%s,%s,%s]}],"PostToolUse":[{"matcher":"Bash","hooks":[%s,%s]}]}}\n' \
    '{"type":"command","command":"AUTO_UPDATE_LEGACY=1 /opt/mine/auto-update.sh"}' \
    '{"type":"command","command":"AUTO_UPDATE_LEGACY=1 AUTO_UPDATE_HOOK=SessionStart /home/other/.claude/hooks/auto-update/auto-update.sh"}' \
    '{"type":"command","command":"AUTO_UPDATE_LEGACY=1 AUTO_UPDATE_HOOK=SessionStart '"$_rh_au"' --verbose"}' \
    '{"type":"command","command":"PR_CREATION_LOG_LEGACY=1 /opt/mine/log-pr.sh"}' \
    '{"type":"command","command":"PR_CREATION_LOG_LEGACY=1 '"$_rh_pr"' && echo done"}' > "$_rh_lg"
  _rh_before="$(cat "$_rh_lg")"
  _rh_inode_before="$(_rh_inode "$_rh_lg")"
  _rh_rc=0; _rh_migrate "$_rh_lg" "$_rh_lg_kit" >/dev/null 2>&1 || _rh_rc=$?
  if [[ "$_rh_rc" -eq 0 && "$(cat "$_rh_lg")" == "$_rh_before" \
    && "$(_rh_inode "$_rh_lg")" == "$_rh_inode_before" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="legacy-migration: a missing or broken kit build or invalid settings changes nothing"
  _rh_lg="$_rh_tmp/legacy-safe.json"
  printf '{"hooks":{"SessionStart":[%s]}}\n' "$_rh_e_au_legacy" > "$_rh_lg"
  printf 'not json' > "$_rh_tmp/legacy-broken-kit.json"
  printf '{"hooks": ' > "$_rh_tmp/legacy-broken-settings.json"
  _rh_before="$(cat "$_rh_lg")"
  _rh_rc1=0; _rh_migrate "$_rh_lg" "$_rh_tmp/no-such-kit.json" >/dev/null 2>&1 || _rh_rc1=$?
  _rh_rc2=0; _rh_migrate "$_rh_lg" "$_rh_tmp/legacy-broken-kit.json" >/dev/null 2>&1 || _rh_rc2=$?
  _rh_rc3=0; _rh_migrate "$_rh_tmp/legacy-broken-settings.json" "$_rh_lg_kit" >/dev/null 2>&1 || _rh_rc3=$?
  if [[ "$_rh_rc1" -eq 0 && "$_rh_rc2" -eq 0 && "$_rh_rc3" -eq 0 \
    && "$(cat "$_rh_lg")" == "$_rh_before" \
    && "$(cat "$_rh_tmp/legacy-broken-settings.json")" == '{"hooks": ' ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# Why a dedicated migration exists: with a user hook in the same array the
# non-interactive 3-way merge keeps the legacy entry as "removed by the kit"
# next to the kit's current one, and neither existing sweep pairs them.
{
  test_name="legacy-migration: merge and existing sweeps keep both generations; the migration heals them"
  _rh_m_snap="$_rh_tmp/legacy-merge-snapshot.json"
  _rh_m_cur="$_rh_tmp/legacy-merge-current.json"
  _rh_m_out="$_rh_tmp/legacy-merge-out.json"
  printf '%s\n' '{"hooks":{"SessionStart":['"$_rh_e_au_legacy"'],"PostToolUse":['"$_rh_e_pr_legacy"']}}' > "$_rh_m_snap"
  printf '%s\n' '{"hooks":{"SessionStart":['"$_rh_e_au_legacy"','"$_rh_e_user_start"'],"PostToolUse":['"$_rh_e_pr_legacy"','"$_rh_e_user_post"']}}' > "$_rh_m_cur"
  cp "$_rh_m_cur" "$_rh_m_out"
  _rh_count='[(.hooks.SessionStart[]?.hooks[]?.command? // "" | select(endswith("/auto-update/auto-update.sh"))),
              (.hooks.PostToolUse[]?.hooks[]?.command? // "" | select(endswith("/pr-creation-log/log-pr.sh")))] | length'
  _rh_rc=0
  HOME=/home/u CLAUDE_DIR="$_rh_tmp/legacy-merge-claude" "${BASH:-bash}" -c '
    set -uo pipefail
    PROJECT_DIR="$1"
    _SETUP_TMP_FILES=()
    _MERGE_INTERACTIVE=false
    source "$PROJECT_DIR/lib/colors.sh"
    source "$PROJECT_DIR/lib/progress.sh"
    source "$PROJECT_DIR/lib/features.sh"
    source "$PROJECT_DIR/lib/snapshot.sh"
    source "$PROJECT_DIR/lib/merge.sh"
    source "$PROJECT_DIR/lib/update.sh"
    source "$PROJECT_DIR/i18n/en/strings.sh"
    set +e
    mkdir -p "$CLAUDE_DIR"
    merge_settings_3way "$2" "$3" "$4" "$5" || exit 1
    _strip_retired_hook_entries "$5" || exit 1
    _strip_superseded_kit_hook_generations "$5" "$4" || exit 1
    cp "$5" "$5.before-migration"
    _migrate_legacy_hook_entries "$5" "$4" || exit 1
  ' legacy-merge "$PROJECT_DIR" "$_rh_m_snap" "$_rh_m_cur" "$_rh_lg_kit" "$_rh_m_out" \
    >/dev/null 2>&1 || _rh_rc=$?
  if [[ "$_rh_rc" -eq 0 ]] \
    && [[ "$(jq -r "$_rh_count" "$_rh_m_out.before-migration" 2>/dev/null)" == "4" ]] \
    && [[ "$(jq -r "$_rh_count" "$_rh_m_out" 2>/dev/null)" == "2" ]] \
    && jq -e --argjson au "$_rh_e_au_now" --argjson pr "$_rh_e_pr_now" \
      --argjson us "$_rh_e_user_start" --argjson up "$_rh_e_user_post" \
      --argjson end "$_rh_e_au_end" '
      (.hooks.SessionStart | sort) == ([$au, $us] | sort)
      and .hooks.SessionEnd == [$end]
      and (.hooks.PostToolUse | sort) == ([$pr, $up] | sort)' "$_rh_m_out" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

rm -rf "$_rh_tmp"
