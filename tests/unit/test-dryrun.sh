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
