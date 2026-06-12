#!/bin/bash
# tests/unit/test-retired-hooks.sh - _strip_retired_hook_entries behavior

_rh_tmp="$(mktemp -d)"

_rh_run() {
  bash -c '
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
  cat > "$_rh_all" <<'JSON'
{
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
}
JSON
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
  printf '{"hooks":{"PreCompact":[{"matcher":"*","hooks":[{"type":"command","command":"/home/u/dotfiles/hooks/memory-persistence/mine.sh"}]}]}}\n' > "$_rh_user"
  _rh_run "$_rh_user" >/dev/null 2>&1
  if [[ "$(jq -r '.hooks.PreCompact[0].hooks | length' "$_rh_user")" == "1" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="retired-hooks: memory-persistence entries are stripped, others kept"
  _rh_settings="$_rh_tmp/settings.json"
  cat > "$_rh_settings" <<'JSON'
{
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
}
JSON
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
  test_name="retired-hooks: feature registry no longer contains memory-persistence"
  if ! grep -q 'memory-persistence' "$PROJECT_DIR/lib/features.sh" \
    && [[ ! -d "$PROJECT_DIR/features/memory-persistence" ]] \
    && grep -q 'ENABLE_MEMORY_PERSISTENCE' <<< "$(grep '_CONFIG_LEGACY_KEYS=' "$PROJECT_DIR/wizard/registry.sh")"; then
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
        {"type": "command", "command": "/h/.claude/hooks/memory-persistence/pre-compact.sh"}
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

rm -rf "$_rh_tmp"
