#!/bin/bash
# tests/unit/test-memory-persistence.sh - Unit tests for memory-persistence hooks

MEMORY_PERSISTENCE_POST="$PROJECT_DIR/features/memory-persistence/scripts/post-compact.sh"

# shellcheck source=lib/colors.sh
source "$PROJECT_DIR/lib/colors.sh"
# shellcheck source=lib/json-builder.sh
source "$PROJECT_DIR/lib/json-builder.sh"

# PostCompact script should emit a concise reminder on stdout without creating
# extra runtime files.
_mp_tmp="$(mktemp -d)"
_SETUP_TMP_FILES+=("$_mp_tmp")
_mp_home="$_mp_tmp/home"
mkdir -p "$_mp_home"
_mp_out="$_mp_tmp/post.out"
_mp_err="$_mp_tmp/post.err"
env HOME="$_mp_home" bash "$MEMORY_PERSISTENCE_POST" >"$_mp_out" 2>"$_mp_err"

if assert_equals "" "$(cat "$_mp_err")" \
  && assert_matches "Compaction complete\\. Recent session notes and learned context will be available on the next SessionStart\\." "$(cat "$_mp_out")" \
  && assert_file_not_exists "$_mp_home/.claude/sessions/compaction-log.txt"; then
  pass "memory-persistence: post-compact hook emits stdout reminder without runtime log files"
else
  fail "memory-persistence: post-compact hook should emit stdout reminder without runtime log files"
fi

# Hook fragment should expose PostCompact so settings assembly can merge it.
_mp_hooks="$PROJECT_DIR/features/memory-persistence/hooks.json"
if jq -e '.hooks.PostCompact[0].hooks[0].command | contains("post-compact.sh")' "$_mp_hooks" >/dev/null 2>&1; then
  pass "memory-persistence: hooks.json registers PostCompact command"
else
  fail "memory-persistence: hooks.json should register PostCompact command"
fi

# Merged settings should also contain the PostCompact hook entry.
_mp_settings="$_mp_tmp/settings.json"
build_settings_json \
  "$PROJECT_DIR/config/settings-base.json" \
  "$PROJECT_DIR/config/permissions.json" \
  "$_mp_settings" \
  "$_mp_hooks" >/dev/null
if jq -e '.hooks.PostCompact[0].hooks[0].command | contains("post-compact.sh")' "$_mp_settings" >/dev/null 2>&1; then
  pass "memory-persistence: merged settings include PostCompact hook"
else
  fail "memory-persistence: merged settings should include PostCompact hook"
fi

# PostCompact should still merge as an array when another fragment adds the same hook type.
_mp_extra_fragment="$_mp_tmp/post-compact-extra.json"
cat >"$_mp_extra_fragment" <<'EOF'
{
  "hooks": {
    "PostCompact": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "__HOME__/.claude/hooks/example/post-compact-extra.sh"
          }
        ]
      }
    ]
  }
}
EOF
_mp_merged="$_mp_tmp/settings-merged.json"
build_settings_json \
  "$PROJECT_DIR/config/settings-base.json" \
  "$PROJECT_DIR/config/permissions.json" \
  "$_mp_merged" \
  "$_mp_hooks" \
  "$_mp_extra_fragment" >/dev/null
if assert_equals "2" "$(jq -r '.hooks.PostCompact | length' "$_mp_merged")"; then
  pass "memory-persistence: PostCompact hook arrays merge without replacement"
else
  fail "memory-persistence: PostCompact hook arrays should concatenate"
fi
