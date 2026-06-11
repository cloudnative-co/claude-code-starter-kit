#!/bin/bash
# tests/unit/test-interactive-prompts.sh - Interactive prompt branches via _TTY_INPUT
#
# Covers the tty-injected interactive branches in lib/deploy.sh:
#   - _build_claude_md_safe → _claude_md_migration_prompt ([M]erge / [S]kip)
#   - _copy_dir_safe ([O]verwrite / [N]ew files only / [S]kip)
# Replies are injected by pointing _TTY_INPUT at a temp file
# (read -r x < "${_TTY_INPUT:-/dev/tty}").

source "$PROJECT_DIR/lib/colors.sh"

# Provide _sed/_awk stubs (normally from lib/prerequisites.sh)
_GNU_SED=""
_GNU_AWK=""
_sed() { sed "$@"; }
_awk() { awk "$@"; }

source "$PROJECT_DIR/lib/template.sh"
source "$PROJECT_DIR/lib/features.sh"
source "$PROJECT_DIR/lib/json-builder.sh"
source "$PROJECT_DIR/lib/snapshot.sh"
source "$PROJECT_DIR/lib/merge.sh"
source "$PROJECT_DIR/lib/dryrun.sh"

declare -a _SETUP_TMP_FILES=()

# i18n strings (STR_CLAUDEMD_*, STR_FRESH_*)
source "$PROJECT_DIR/i18n/en/strings.sh"

LANGUAGE="en"
# shellcheck disable=SC2034  # globals are consumed by sourced deploy.sh
INSTALL_SKILLS="false"
# shellcheck disable=SC2034  # globals are consumed by sourced deploy.sh
ENABLE_CODEX_PLUGIN="false"
# shellcheck disable=SC2034  # consumed by _copy_dir_safe / _build_claude_md_safe
_MERGE_INTERACTIVE="true"

source "$PROJECT_DIR/lib/deploy.sh"

# Shared reply file injected via _TTY_INPUT
_TTY_INPUT="$(mktemp)"
_SETUP_TMP_FILES+=("$_TTY_INPUT")

{
  test_name="interactive-prompts: _build_claude_md_safe [M]erge writes kit section + preserves user content"
  CLAUDE_DIR="$(mktemp -d)"
  _SETUP_TMP_FILES+=("$CLAUDE_DIR")
  printf '# My Rules\n\n- my custom user line\n' > "$CLAUDE_DIR/CLAUDE.md"
  printf 'm\n' > "$_TTY_INPUT"
  _FRESH_SKIPPED_FILES=()
  _rc=0
  _build_claude_md_safe >/dev/null 2>&1 || _rc=$?
  _kit_end_line="$(grep -nF "$_KIT_MARKER_END" "$CLAUDE_DIR/CLAUDE.md" | head -1 | cut -d: -f1)"
  _user_line="$(grep -nF "my custom user line" "$CLAUDE_DIR/CLAUDE.md" | head -1 | cut -d: -f1)"
  if [[ "$_rc" -eq 0 ]] \
    && grep -qF "$_KIT_MARKER_BEGIN" "$CLAUDE_DIR/CLAUDE.md" \
    && grep -qF "$_KIT_MARKER_END" "$CLAUDE_DIR/CLAUDE.md" \
    && grep -qF "$(_user_section_heading)" "$CLAUDE_DIR/CLAUDE.md" \
    && [[ -n "$_kit_end_line" ]] && [[ -n "$_user_line" ]] \
    && [[ "$_user_line" -gt "$_kit_end_line" ]] \
    && [[ ${#_FRESH_SKIPPED_FILES[@]} -eq 0 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="interactive-prompts: _build_claude_md_safe [S]kip leaves file untouched and registers skip"
  CLAUDE_DIR="$(mktemp -d)"
  _SETUP_TMP_FILES+=("$CLAUDE_DIR")
  printf '# My Rules\n\n- my custom user line\n' > "$CLAUDE_DIR/CLAUDE.md"
  _before="$(mktemp)"
  _SETUP_TMP_FILES+=("$_before")
  cp "$CLAUDE_DIR/CLAUDE.md" "$_before"
  printf 's\n' > "$_TTY_INPUT"
  _FRESH_SKIPPED_FILES=()
  _rc=0
  _build_claude_md_safe >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && cmp -s "$_before" "$CLAUDE_DIR/CLAUDE.md" \
    && [[ ${#_FRESH_SKIPPED_FILES[@]} -eq 1 ]] \
    && [[ "${_FRESH_SKIPPED_FILES[0]}" == "$CLAUDE_DIR/CLAUDE.md" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# Helper: build src tree (a.md + sub/b.md) and dest with pre-existing a.md
_ip_setup_copy_dirs() {
  _ip_src="$(mktemp -d)"
  _ip_dest="$(mktemp -d)"
  _SETUP_TMP_FILES+=("$_ip_src" "$_ip_dest")
  printf 'new-a\n' > "$_ip_src/a.md"
  mkdir -p "$_ip_src/sub"
  printf 'new-b\n' > "$_ip_src/sub/b.md"
  printf 'old-a\n' > "$_ip_dest/a.md"
}

{
  test_name="interactive-prompts: _copy_dir_safe [O]verwrite replaces existing and copies new files"
  _ip_setup_copy_dirs
  printf 'o\n' > "$_TTY_INPUT"
  _FRESH_SKIPPED_FILES=()
  _rc=0
  _copy_dir_safe "true" "$_ip_src" "$_ip_dest" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && [[ "$(cat "$_ip_dest/a.md")" == "new-a" ]] \
    && [[ "$(cat "$_ip_dest/sub/b.md")" == "new-b" ]] \
    && [[ ${#_FRESH_SKIPPED_FILES[@]} -eq 0 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="interactive-prompts: _copy_dir_safe [S]kip preserves dest and registers skip"
  _ip_setup_copy_dirs
  printf 's\n' > "$_TTY_INPUT"
  _FRESH_SKIPPED_FILES=()
  _rc=0
  _copy_dir_safe "true" "$_ip_src" "$_ip_dest" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && [[ "$(cat "$_ip_dest/a.md")" == "old-a" ]] \
    && [[ ! -e "$_ip_dest/sub/b.md" ]] \
    && [[ ${#_FRESH_SKIPPED_FILES[@]} -eq 1 ]] \
    && [[ "${_FRESH_SKIPPED_FILES[0]}" == "$_ip_dest" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="interactive-prompts: _copy_dir_safe [N]ew-only keeps existing and adds new files"
  _ip_setup_copy_dirs
  printf 'n\n' > "$_TTY_INPUT"
  _FRESH_SKIPPED_FILES=()
  _rc=0
  _copy_dir_safe "true" "$_ip_src" "$_ip_dest" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && [[ "$(cat "$_ip_dest/a.md")" == "old-a" ]] \
    && [[ "$(cat "$_ip_dest/sub/b.md")" == "new-b" ]] \
    && [[ ${#_FRESH_SKIPPED_FILES[@]} -eq 0 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# Reset shared-process state so later test files see defaults
unset _TTY_INPUT
unset _MERGE_INTERACTIVE
_FRESH_SKIPPED_FILES=()
