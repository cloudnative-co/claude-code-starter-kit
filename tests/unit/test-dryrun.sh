#!/bin/bash
# tests/unit/test-dryrun.sh - Unit tests for dry-run simulation setup

# shellcheck source=lib/colors.sh
source "$PROJECT_DIR/lib/colors.sh"
# shellcheck source=lib/template.sh
source "$PROJECT_DIR/lib/template.sh"
# shellcheck source=lib/dryrun.sh
source "$PROJECT_DIR/lib/dryrun.sh"

_dr_tmp="$(mktemp -d)"
_SETUP_TMP_FILES+=("$_dr_tmp")
_dr_real="$_dr_tmp/real-claude"
mkdir -p "$_dr_real/projects/project-a" "$_dr_real/hooks/example" "$_dr_real/.starter-kit-snapshot"

printf '{"env":{"A":"1"}}\n' > "$_dr_real/settings.json"
printf '# Claude\n' > "$_dr_real/CLAUDE.md"
printf 'secret transcript\n' > "$_dr_real/projects/project-a/session.jsonl"
printf '#!/bin/bash\n' > "$_dr_real/hooks/example/hook.sh"
printf '{"env":{"A":"1"}}\n' > "$_dr_real/.starter-kit-snapshot/settings.json"
cat > "$_dr_real/.starter-kit-manifest.json" <<EOF
{
  "version": "2",
  "files": [
    "$_dr_real/settings.json",
    "$_dr_real/hooks/example/hook.sh"
  ]
}
EOF

_dryrun_init "$_dr_real"

if assert_file_exists "$_DRYRUN_DIR/settings.json" \
  && assert_file_exists "$_DRYRUN_DIR/hooks/example/hook.sh" \
  && assert_file_exists "$_DRYRUN_DIR/.starter-kit-snapshot/settings.json" \
  && [[ ! -e "$_DRYRUN_DIR/projects/project-a/session.jsonl" ]]; then
  pass "dryrun: init copies kit-relevant state without runtime project transcripts"
else
  fail "dryrun: init should not copy projects runtime state"
fi

# ---------------------------------------------------------------------------
# No manifest (fresh install over an existing ~/.claude): user kit trees must
# be copied into the sim dir so the preview matches merge-aware deploy
# decisions instead of over-reporting MODIFY.
# ---------------------------------------------------------------------------
_dr_real_fresh="$_dr_tmp/real-claude-fresh"
mkdir -p "$_dr_real_fresh/agents" "$_dr_real_fresh/projects/project-b"
printf '# my custom agent\n' > "$_dr_real_fresh/agents/my-custom.md"
printf 'secret transcript\n' > "$_dr_real_fresh/projects/project-b/session.jsonl"
printf '{"env":{"B":"2"}}\n' > "$_dr_real_fresh/settings.json"

_dryrun_init "$_dr_real_fresh"

if assert_file_exists "$_DRYRUN_DIR/agents/my-custom.md" \
  && assert_file_exists "$_DRYRUN_DIR/settings.json"; then
  pass "dryrun: init without manifest copies existing user kit trees"
else
  fail "dryrun: init without manifest should copy existing agents tree"
fi

if [[ ! -e "$_DRYRUN_DIR/projects" ]]; then
  pass "dryrun: init without manifest still excludes projects runtime state"
else
  fail "dryrun: init without manifest must not copy projects/"
fi

# ---------------------------------------------------------------------------
# Manifest present: only manifest-listed files are copied — kit trees are not
# blanket-copied (user files outside the manifest stay out of the sim dir).
# ---------------------------------------------------------------------------
_dr_real_managed="$_dr_tmp/real-claude-managed"
mkdir -p "$_dr_real_managed/agents" "$_dr_real_managed/hooks/example"
printf '{"env":{"C":"3"}}\n' > "$_dr_real_managed/settings.json"
printf '#!/bin/bash\n' > "$_dr_real_managed/hooks/example/hook.sh"
printf '# user-added agent outside manifest\n' > "$_dr_real_managed/agents/unmanaged.md"
cat > "$_dr_real_managed/.starter-kit-manifest.json" <<EOF
{
  "version": "2",
  "files": [
    "$_dr_real_managed/settings.json",
    "$_dr_real_managed/hooks/example/hook.sh"
  ]
}
EOF

_dryrun_init "$_dr_real_managed"

if assert_file_exists "$_DRYRUN_DIR/settings.json" \
  && assert_file_exists "$_DRYRUN_DIR/hooks/example/hook.sh" \
  && [[ ! -e "$_DRYRUN_DIR/agents/unmanaged.md" ]]; then
  pass "dryrun: init with manifest copies only manifest-listed files"
else
  fail "dryrun: init with manifest must not blanket-copy kit trees"
fi
