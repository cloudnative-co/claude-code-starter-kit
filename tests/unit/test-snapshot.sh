#!/bin/bash
# tests/unit/test-snapshot.sh - Unit tests for lib/snapshot.sh
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded).
# Dependencies: lib/colors.sh, lib/template.sh, lib/snapshot.sh

# ---------------------------------------------------------------------------
# Setup: source dependencies
# ---------------------------------------------------------------------------

# Provide portable _sed/_awk stubs (snapshot.sh does not use them directly,
# but template.sh references them)
_GNU_SED=""
_GNU_AWK=""
_sed() { sed "$@"; }
_awk() { awk "$@"; }

# shellcheck source=lib/colors.sh
source "$PROJECT_DIR/lib/colors.sh"
# shellcheck source=lib/template.sh
source "$PROJECT_DIR/lib/template.sh"
# shellcheck source=lib/snapshot.sh
source "$PROJECT_DIR/lib/snapshot.sh"

# Ensure _SETUP_TMP_FILES exists for _register_tmp
declare -a _SETUP_TMP_FILES=() 2>/dev/null || true

# ---------------------------------------------------------------------------
# 1. _file_changed: identical files
# ---------------------------------------------------------------------------
test_file_changed_identical() {
  local name="file_changed: identical files return 1"
  local tmp_a tmp_b
  tmp_a="$(mktemp)"
  tmp_b="$(mktemp)"
  echo "same content" > "$tmp_a"
  echo "same content" > "$tmp_b"

  run_func _file_changed "$tmp_a" "$tmp_b"
  if assert_equals "1" "$_RF_RC" "identical files should return 1"; then
    pass "$name"
  else
    fail "$name"
  fi
  rm -f "$tmp_a" "$tmp_b"
}
test_file_changed_identical

# ---------------------------------------------------------------------------
# 2. _file_changed: different files
# ---------------------------------------------------------------------------
test_file_changed_different() {
  local name="file_changed: different files return 0"
  local tmp_a tmp_b
  tmp_a="$(mktemp)"
  tmp_b="$(mktemp)"
  echo "content A" > "$tmp_a"
  echo "content B" > "$tmp_b"

  run_func _file_changed "$tmp_a" "$tmp_b"
  if assert_equals "0" "$_RF_RC" "different files should return 0"; then
    pass "$name"
  else
    fail "$name"
  fi
  rm -f "$tmp_a" "$tmp_b"
}
test_file_changed_different

# ---------------------------------------------------------------------------
# 3. _file_changed: missing file treated as changed
# ---------------------------------------------------------------------------
test_file_changed_missing() {
  local name="file_changed: missing file returns 0"
  local tmp_a
  tmp_a="$(mktemp)"
  echo "exists" > "$tmp_a"

  run_func _file_changed "$tmp_a" "/nonexistent-path-$$"
  if assert_equals "0" "$_RF_RC" "missing file should return 0 (changed)"; then
    pass "$name"
  else
    fail "$name"
  fi
  rm -f "$tmp_a"
}
test_file_changed_missing

# ---------------------------------------------------------------------------
# 4. _write_snapshot: creates snapshot with correct structure
# ---------------------------------------------------------------------------
test_write_snapshot_creates_files() {
  local name="write_snapshot: creates snapshot directory with files"
  local tmpdir
  tmpdir="$(mktemp -d)"
  local claude_dir="$tmpdir/.claude"
  mkdir -p "$claude_dir"

  # Create source files
  echo '{"key":"value"}' > "$claude_dir/settings.json"
  mkdir -p "$claude_dir/rules"
  echo "# rule" > "$claude_dir/rules/test.md"

  run_func _write_snapshot "$claude_dir" \
    "$claude_dir/settings.json" \
    "$claude_dir/rules/test.md"

  local snapshot_dir="$claude_dir/$_SNAPSHOT_DIR_NAME"
  local ok_all=true
  assert_file_exists "$snapshot_dir/settings.json" || ok_all=false
  assert_file_exists "$snapshot_dir/rules/test.md" || ok_all=false
  assert_file_contains "$snapshot_dir/settings.json" '"key"' || ok_all=false

  if $ok_all; then
    pass "$name"
  else
    fail "$name"
  fi
  rm -rf "$tmpdir"
}
test_write_snapshot_creates_files

# ---------------------------------------------------------------------------
# 5. _write_snapshot: replaces existing snapshot
# ---------------------------------------------------------------------------
test_write_snapshot_replaces_existing() {
  local name="write_snapshot: replaces stale snapshot"
  local tmpdir
  tmpdir="$(mktemp -d)"
  local claude_dir="$tmpdir/.claude"
  local snapshot_dir="$claude_dir/$_SNAPSHOT_DIR_NAME"
  mkdir -p "$snapshot_dir"

  # Plant a stale file
  echo "stale" > "$snapshot_dir/old-file.txt"
  echo '{}' > "$claude_dir/settings.json"

  run_func _write_snapshot "$claude_dir" "$claude_dir/settings.json"

  local ok_all=true
  assert_file_exists "$snapshot_dir/settings.json" || ok_all=false
  assert_file_not_exists "$snapshot_dir/old-file.txt" "stale file should be removed" || ok_all=false

  if $ok_all; then
    pass "$name"
  else
    fail "$name"
  fi
  rm -rf "$tmpdir"
}
test_write_snapshot_replaces_existing

# ---------------------------------------------------------------------------
# 6. _snapshot_exists: true when settings.json present
# ---------------------------------------------------------------------------
test_snapshot_exists_true() {
  local name="snapshot_exists: returns 0 when settings.json present"
  local tmpdir
  tmpdir="$(mktemp -d)"
  local claude_dir="$tmpdir/.claude"
  mkdir -p "$claude_dir/$_SNAPSHOT_DIR_NAME"
  echo '{}' > "$claude_dir/$_SNAPSHOT_DIR_NAME/settings.json"

  run_func _snapshot_exists "$claude_dir"
  if assert_equals "0" "$_RF_RC" "should return 0 when snapshot exists"; then
    pass "$name"
  else
    fail "$name"
  fi
  rm -rf "$tmpdir"
}
test_snapshot_exists_true

# ---------------------------------------------------------------------------
# 7. _snapshot_exists: false when no snapshot
# ---------------------------------------------------------------------------
test_snapshot_exists_false() {
  local name="snapshot_exists: returns 1 when snapshot missing"
  local tmpdir
  tmpdir="$(mktemp -d)"
  local claude_dir="$tmpdir/.claude"
  mkdir -p "$claude_dir"

  run_func _snapshot_exists "$claude_dir"
  if assert_equals "1" "$_RF_RC" "should return 1 when snapshot is missing"; then
    pass "$name"
  else
    fail "$name"
  fi
  rm -rf "$tmpdir"
}
test_snapshot_exists_false

# ---------------------------------------------------------------------------
# 8. _update_snapshot_file: updates a single file in snapshot
# ---------------------------------------------------------------------------
test_update_snapshot_file() {
  local name="update_snapshot_file: copies file into snapshot"
  local tmpdir
  tmpdir="$(mktemp -d)"
  local claude_dir="$tmpdir/.claude"
  local snapshot_dir="$claude_dir/$_SNAPSHOT_DIR_NAME"
  mkdir -p "$snapshot_dir"

  # Source file to snapshot
  mkdir -p "$claude_dir/rules"
  echo "# updated rule" > "$claude_dir/rules/new.md"

  run_func _update_snapshot_file "$claude_dir" "$claude_dir/rules/new.md"

  local ok_all=true
  assert_equals "0" "$_RF_RC" "should succeed" || ok_all=false
  assert_file_exists "$snapshot_dir/rules/new.md" || ok_all=false
  assert_file_contains "$snapshot_dir/rules/new.md" "updated rule" || ok_all=false

  if $ok_all; then
    pass "$name"
  else
    fail "$name"
  fi
  rm -rf "$tmpdir"
}
test_update_snapshot_file

# ---------------------------------------------------------------------------
# 9. _snapshot_claude_md: extracts kit section only
# ---------------------------------------------------------------------------
test_snapshot_claude_md_kit_section() {
  local name="snapshot_claude_md: extracts kit section only"
  local tmpdir
  tmpdir="$(mktemp -d)"
  local claude_dir="$tmpdir/.claude"
  mkdir -p "$claude_dir"

  # Build a CLAUDE.md with markers
  {
    echo "$_KIT_MARKER_BEGIN"
    echo "# Kit content"
    echo "Kit managed stuff"
    echo "$_KIT_MARKER_END"
    echo ""
    echo "# User Settings"
    echo "My custom notes"
  } > "$claude_dir/CLAUDE.md"

  run_func _snapshot_claude_md "$claude_dir" "$claude_dir/CLAUDE.md"

  local snapshot_file="$claude_dir/$_SNAPSHOT_DIR_NAME/CLAUDE.md"
  local ok_all=true
  assert_equals "0" "$_RF_RC" "should succeed" || ok_all=false
  assert_file_exists "$snapshot_file" || ok_all=false
  assert_file_contains "$snapshot_file" "Kit managed stuff" || ok_all=false
  assert_file_not_contains "$snapshot_file" "My custom notes" \
    "user section should not be in snapshot" || ok_all=false

  if $ok_all; then
    pass "$name"
  else
    fail "$name"
  fi
  rm -rf "$tmpdir"
}
test_snapshot_claude_md_kit_section

# ---------------------------------------------------------------------------
# 10. _repair_snapshot_markers: repairs duplicated markers
# ---------------------------------------------------------------------------
test_repair_snapshot_markers() {
  local name="repair_snapshot_markers: deduplicates marker pairs"
  local tmpdir
  tmpdir="$(mktemp -d)"
  local file="$tmpdir/CLAUDE.md"

  # Create file with duplicated markers (pre-v0.30.0 bug)
  {
    echo "$_KIT_MARKER_BEGIN"
    echo "# First section"
    echo "$_KIT_MARKER_END"
    echo "$_KIT_MARKER_BEGIN"
    echo "# Duplicate section"
    echo "$_KIT_MARKER_END"
  } > "$file"

  run_func _repair_snapshot_markers "$file"

  local begin_count
  begin_count="$(grep -cF "$_KIT_MARKER_BEGIN" "$file")" || begin_count=0

  local ok_all=true
  assert_equals "1" "$begin_count" "should have exactly 1 BEGIN marker after repair" || ok_all=false
  assert_file_contains "$file" "First section" "first section should survive" || ok_all=false

  if $ok_all; then
    pass "$name"
  else
    fail "$name"
  fi
  rm -rf "$tmpdir"
}
test_repair_snapshot_markers
