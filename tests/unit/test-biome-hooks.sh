#!/bin/bash
# tests/unit/test-biome-hooks.sh - Unit tests for biome hook feature files
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded).

_biome_feature="$PROJECT_DIR/features/biome-hooks/feature.json"
_biome_hooks="$PROJECT_DIR/features/biome-hooks/hooks.json"
_prettier_feature="$PROJECT_DIR/features/prettier-hooks/feature.json"
_permissions="$PROJECT_DIR/config/permissions.json"

if jq -e '.name == "biome-hooks" and (.conflicts | index("prettier-hooks")) != null' "$_biome_feature" >/dev/null 2>&1; then
  pass "biome-hooks: feature.json declares conflict with prettier-hooks"
else
  fail "biome-hooks: feature.json is missing required conflicts metadata"
fi

if jq -e '.conflicts | index("biome-hooks") != null' "$_prettier_feature" >/dev/null 2>&1; then
  pass "biome-hooks: prettier feature declares reverse conflict"
else
  fail "biome-hooks: prettier feature is missing reverse conflict"
fi

if jq -e '.hooks.PostToolUse[0].matcher == "Edit|Write"' "$_biome_hooks" >/dev/null 2>&1; then
  pass "biome-hooks: hooks.json matcher targets Edit and Write tools"
else
  fail "biome-hooks: hooks.json matcher is not the expected Edit|Write matcher"
fi

_biome_cmd="$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$_biome_hooks")"
if [[ "$_biome_cmd" == "__HOME__/.claude/hooks/biome-hooks/format-file.sh" ]] \
  && grep -q "biome check --write" "$PROJECT_DIR/features/biome-hooks/scripts/format-file.sh" \
  && grep -q "|| true" "$PROJECT_DIR/features/biome-hooks/scripts/format-file.sh"; then
  pass "biome-hooks: hook command uses external script and handles failures"
else
  fail "biome-hooks: hook command should use external script with graceful failure handling"
fi

if jq -e '.permissions.allow | index("Bash(biome:*)") != null' "$_permissions" >/dev/null 2>&1; then
  pass "biome-hooks: permissions allow biome command execution"
else
  fail "biome-hooks: permissions.json is missing Bash(biome:*)"
fi

if grep -q 'ENABLE_BIOME_HOOKS="false"' "$PROJECT_DIR/wizard/defaults.conf" \
  && grep -q 'ENABLE_BIOME_HOOKS=false' "$PROJECT_DIR/profiles/minimal.conf" \
  && grep -q 'ENABLE_BIOME_HOOKS=false' "$PROJECT_DIR/profiles/standard.conf" \
  && grep -q 'ENABLE_BIOME_HOOKS=true' "$PROJECT_DIR/profiles/full.conf"; then
  pass "biome-hooks: defaults and profiles declare ENABLE_BIOME_HOOKS as designed"
else
  fail "biome-hooks: defaults or profiles are missing expected ENABLE_BIOME_HOOKS values"
fi

if grep -q 'STR_HOOKS_BIOME=' "$PROJECT_DIR/i18n/en/strings.sh" \
  && grep -q 'STR_HOOKS_BIOME=' "$PROJECT_DIR/i18n/ja/strings.sh"; then
  pass "biome-hooks: i18n strings exist in both languages"
else
  fail "biome-hooks: missing Biome i18n strings"
fi

_tmpdir="$(mktemp -d)"
_input='{"tool_input":{"file_path":"'"$_tmpdir"'/sample.ts"}}'
printf 'const value=1\n' > "$_tmpdir/sample.ts"
_script="$PROJECT_DIR/features/biome-hooks/scripts/format-file.sh"

cat > "$_tmpdir/biome" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$_tmpdir/biome"
_saved_path="$PATH"
export PATH="$_tmpdir:$PATH"
if printf '%s' "$_input" | bash "$_script" >/dev/null; then
  pass "biome-hooks: hook succeeds when biome succeeds"
else
  fail "biome-hooks: hook failed when biome succeeded"
fi

cat > "$_tmpdir/biome" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$_tmpdir/biome"
if printf '%s' "$_input" | bash "$_script" >/dev/null; then
  pass "biome-hooks: hook preserves success when biome fails"
else
  fail "biome-hooks: hook should remain successful when biome fails"
fi

export PATH="$_saved_path"
rm -rf "$_tmpdir"
