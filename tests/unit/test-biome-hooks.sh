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
  && grep -q 'claude-code-starter-kit/biome/2.5.4' \
    "$PROJECT_DIR/features/biome-hooks/scripts/format-file.sh" \
  && grep -q 'managed="$component_root/biome"' \
    "$PROJECT_DIR/features/biome-hooks/scripts/format-file.sh" \
  && grep -q "|| true" "$PROJECT_DIR/features/biome-hooks/scripts/format-file.sh"; then
  pass "biome-hooks: hook prefers the pinned managed binary and handles failures"
else
  fail "biome-hooks: managed binary priority or graceful failure handling is missing"
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
_tmpdir="$(builtin cd -P "$_tmpdir" && pwd -P)"
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

_saved_home="$HOME"
export HOME="$_tmpdir/home"
export BIOME_MANAGED_LOG="$_tmpdir/managed.log"
export BIOME_FALLBACK_LOG="$_tmpdir/fallback.log"
_managed_biome="$HOME/.local/lib/claude-code-starter-kit/biome/2.5.4/biome"
mkdir -p "${_managed_biome%/*}"
cat > "$_managed_biome" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$BIOME_MANAGED_LOG"
exit 0
EOF
chmod +x "$_managed_biome"
_managed_biome_sha="$(/usr/bin/shasum -a 256 "$_managed_biome" | /usr/bin/awk '{print $1}')"
cat > "$_tmpdir/biome" <<'EOF'
#!/bin/bash
: > "$BIOME_FALLBACK_LOG"
exit 0
EOF
chmod +x "$_tmpdir/biome"
if printf '%s' "$_input" | BIOME_TEST_SHA="$_managed_biome_sha" \
  bash -c 'source "$1"; _ccsk_biome_expected_sha256() { printf "%s" "$BIOME_TEST_SHA"; }; _ccsk_biome_main' \
    _ "$_script" >/dev/null \
  && grep -q 'check --write' "$BIOME_MANAGED_LOG" \
  && [[ ! -e "$BIOME_FALLBACK_LOG" ]]; then
  pass "biome-hooks: pinned managed binary wins over a PATH shadow"
else
  fail "biome-hooks: PATH shadow replaced the pinned managed binary"
fi

rm -f "$_managed_biome" "$BIOME_FALLBACK_LOG"
ln -s "$_tmpdir/biome" "$_managed_biome"
if printf '%s' "$_input" | bash "$_script" >/dev/null \
  && [[ ! -e "$BIOME_FALLBACK_LOG" ]]; then
  pass "biome-hooks: symlinked managed binary is rejected without PATH fallback"
else
  fail "biome-hooks: symlinked managed binary reached a PATH shadow"
fi

rm -f "$_managed_biome" "$BIOME_FALLBACK_LOG"
printf '#!/bin/bash\nexit 0\n' > "$_managed_biome"
chmod 755 "$_managed_biome"
if printf '%s' "$_input" | bash "$_script" >/dev/null \
  && [[ ! -e "$BIOME_FALLBACK_LOG" ]]; then
  pass "biome-hooks: managed binary with the wrong digest is rejected"
else
  fail "biome-hooks: managed binary digest was not enforced"
fi

_managed_biome_sha="$(/usr/bin/shasum -a 256 "$_managed_biome" | /usr/bin/awk '{print $1}')"
chmod 777 "$_managed_biome"
if printf '%s' "$_input" | BIOME_TEST_SHA="$_managed_biome_sha" \
  bash -c 'source "$1"; _ccsk_biome_expected_sha256() { printf "%s" "$BIOME_TEST_SHA"; }; _ccsk_biome_main' \
    _ "$_script" >/dev/null \
  && [[ ! -e "$BIOME_FALLBACK_LOG" ]]; then
  pass "biome-hooks: writable managed binary is rejected"
else
  fail "biome-hooks: managed binary mode was not enforced"
fi

rm -f "$_managed_biome" "$BIOME_FALLBACK_LOG"
if printf '%s' "$_input" | bash "$_script" >/dev/null \
  && [[ ! -e "$BIOME_FALLBACK_LOG" ]]; then
  pass "biome-hooks: partial managed component does not fall through to PATH"
else
  fail "biome-hooks: partial managed component executed a PATH shadow"
fi

_biome_receipt="$_tmpdir/receipt-current-user.json"
: > "$_biome_receipt"
_biome_resolved="$(
  # shellcheck source=/dev/null
  source "$_script"
  _ccsk_biome_receipt_path() { printf '%s' "$_biome_receipt"; }
  _ccsk_biome_command 2>/dev/null || true
)"
if [[ -z "$_biome_resolved" && ! -e "$BIOME_FALLBACK_LOG" ]]; then
  pass "biome-hooks: current user's root receipt keeps a missing component fail-closed"
else
  fail "biome-hooks: authoritative managed receipt was ignored"
fi

export HOME="$_saved_home"
export PATH="$_saved_path"
unset BIOME_MANAGED_LOG BIOME_FALLBACK_LOG _biome_receipt _biome_resolved \
  _managed_biome_sha
rm -rf "$_tmpdir"
