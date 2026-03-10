# Update Mechanism Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `install.sh` 再実行時に既存ユーザー設定（MCP, hooks, permissions 等）を保持しつつ kit を更新する仕組みを構築する

**Architecture:** Snapshot 比較方式。kit デプロイ時にスナップショットを保存し、update 時に snapshot/current/new_kit の3者比較でユーザー変更を検出・保持する。settings.json は jq でキー単位マージ、テキストファイルは diff ベースの対話型更新。

**Tech Stack:** Bash 3.2 互換, jq, diff

---

## Chunk 1: Snapshot Infrastructure

### Task 1: lib/snapshot.sh — スナップショット保存・比較

**Files:**
- Create: `lib/snapshot.sh`

- [ ] **Step 1: Create `lib/snapshot.sh` with `_write_snapshot()`**

```bash
#!/bin/bash
# lib/snapshot.sh - Snapshot management for update mechanism
# Requires: lib/colors.sh to be sourced first
set -euo pipefail

SNAPSHOT_DIR="${CLAUDE_DIR:?}/.starter-kit-snapshot"

# ---------------------------------------------------------------------------
# _write_snapshot - Save current kit-deployed files as snapshot
#
# Usage: _write_snapshot <claude_dir> <file_list...>
# Copies each deployed file into the snapshot directory, preserving paths.
# ---------------------------------------------------------------------------
_write_snapshot() {
  local claude_dir="$1"
  shift
  local snapshot_dir="${claude_dir}/.starter-kit-snapshot"

  rm -rf "$snapshot_dir"
  mkdir -p "$snapshot_dir"

  local file rel_path dest_dir
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    rel_path="${file#"${claude_dir}/"}"
    dest_dir="${snapshot_dir}/$(dirname "$rel_path")"
    mkdir -p "$dest_dir"
    cp -a "$file" "${snapshot_dir}/${rel_path}"
  done
}

# ---------------------------------------------------------------------------
# _snapshot_exists - Check if a valid snapshot exists
#
# Usage: _snapshot_exists <claude_dir>
# Returns 0 if snapshot directory exists with settings.json, 1 otherwise.
# ---------------------------------------------------------------------------
_snapshot_exists() {
  local claude_dir="$1"
  [[ -d "${claude_dir}/.starter-kit-snapshot" ]] && \
  [[ -f "${claude_dir}/.starter-kit-snapshot/settings.json" ]]
}

# ---------------------------------------------------------------------------
# _file_changed - Compare a file against its snapshot
#
# Usage: _file_changed <snapshot_file> <current_file>
# Returns 0 if files differ (user changed), 1 if identical.
# ---------------------------------------------------------------------------
_file_changed() {
  local snapshot="$1"
  local current="$2"
  [[ ! -f "$snapshot" ]] && return 0
  [[ ! -f "$current" ]] && return 0
  ! diff -q "$snapshot" "$current" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# _update_snapshot_file - Update a single file in the snapshot
#
# Usage: _update_snapshot_file <claude_dir> <file_path>
# ---------------------------------------------------------------------------
_update_snapshot_file() {
  local claude_dir="$1"
  local file="$2"
  local snapshot_dir="${claude_dir}/.starter-kit-snapshot"
  local rel_path="${file#"${claude_dir}/"}"
  local dest_dir="${snapshot_dir}/$(dirname "$rel_path")"
  mkdir -p "$dest_dir"
  cp -a "$file" "${snapshot_dir}/${rel_path}"
}
```

- [ ] **Step 2: Verify shellcheck passes**

Run: `shellcheck -S warning lib/snapshot.sh`
Expected: No warnings

- [ ] **Step 3: Commit**

```bash
git add lib/snapshot.sh
git commit -m "feat: add lib/snapshot.sh for snapshot management"
```

### Task 2: lib/merge.sh — settings.json の3者マージ

**Files:**
- Create: `lib/merge.sh`

- [ ] **Step 1: Create `lib/merge.sh` with core merge functions**

```bash
#!/bin/bash
# lib/merge.sh - Three-way merge for settings.json
# Requires: jq, lib/colors.sh to be sourced first
set -euo pipefail

# ---------------------------------------------------------------------------
# _json_keys - List top-level keys of a JSON file
# ---------------------------------------------------------------------------
_json_keys() {
  jq -r 'keys[]' "$1"
}

# ---------------------------------------------------------------------------
# _json_get - Get a value by key from a JSON file
# ---------------------------------------------------------------------------
_json_get() {
  local file="$1"
  local key="$2"
  jq --arg k "$key" '.[$k]' "$file"
}

# ---------------------------------------------------------------------------
# _json_equal - Compare a key's value between two JSON files
# Returns 0 if equal, 1 if different
# ---------------------------------------------------------------------------
_json_equal() {
  local file_a="$1"
  local file_b="$2"
  local key="$3"
  local val_a val_b
  val_a="$(jq --arg k "$key" '.[$k] // null' "$file_a")"
  val_b="$(jq --arg k "$key" '.[$k] // null' "$file_b")"
  [[ "$val_a" == "$val_b" ]]
}

# ---------------------------------------------------------------------------
# _merge_arrays_3way - Three-way merge for JSON arrays
#
# Usage: _merge_arrays_3way <snapshot_val> <current_val> <newkit_val>
# Output: merged JSON array
#
# Logic:
#   - Items in current but not snapshot → user added → keep
#   - Items in newkit but not snapshot → kit added → add
#   - Items in snapshot but not newkit → kit removed → prompt
#   - Items in snapshot but not current → user removed → respect
# ---------------------------------------------------------------------------
_merge_arrays_3way() {
  local snapshot_val="$1"
  local current_val="$2"
  local newkit_val="$3"

  # User additions: in current but not in snapshot
  local user_added
  user_added="$(jq -n --argjson c "$current_val" --argjson s "$snapshot_val" \
    '[$c[] | select(. as $item | $s | index($item) | not)]')"

  # Kit additions: in newkit but not in snapshot
  local kit_added
  kit_added="$(jq -n --argjson n "$newkit_val" --argjson s "$snapshot_val" \
    '[$n[] | select(. as $item | $s | index($item) | not)]')"

  # Kit removals: in snapshot but not in newkit (and still in current)
  local kit_removed
  kit_removed="$(jq -n --argjson s "$snapshot_val" --argjson n "$newkit_val" --argjson c "$current_val" \
    '[$s[] | select(. as $item | ($n | index($item) | not) and ($c | index($item)))]')"

  # Base: newkit array + user additions
  local merged
  merged="$(jq -n --argjson n "$newkit_val" --argjson u "$user_added" '$n + $u')"

  # Handle kit removals interactively
  local kit_removed_count
  kit_removed_count="$(echo "$kit_removed" | jq 'length')"
  if [[ "$kit_removed_count" -gt 0 ]]; then
    local i item
    for ((i = 0; i < kit_removed_count; i++)); do
      item="$(echo "$kit_removed" | jq -r ".[$i]")"
      if [[ "${WIZARD_NONINTERACTIVE:-false}" == "true" ]]; then
        # Non-interactive: keep user's items (safe default)
        merged="$(jq -n --argjson m "$merged" --arg item "$item" '$m + [$item]')"
      else
        warn "Kit removed: $item (still in your config)"
        printf "  [K]eep / [R]emove ? "
        local choice=""
        read -r choice
        case "$choice" in
          r|R) ;; # Remove: don't add back
          *)
            merged="$(jq -n --argjson m "$merged" --arg item "$item" '$m + [$item]')"
            ;;
        esac
      fi
    done
  fi

  # Deduplicate
  merged="$(echo "$merged" | jq 'unique')"
  printf '%s' "$merged"
}

# ---------------------------------------------------------------------------
# _prompt_scalar_conflict - Ask user to resolve a scalar value conflict
#
# Usage: _prompt_scalar_conflict <key> <current_val> <newkit_val>
# Output: chosen value (JSON)
# ---------------------------------------------------------------------------
_prompt_scalar_conflict() {
  local key="$1"
  local current_val="$2"
  local newkit_val="$3"

  if [[ "${WIZARD_NONINTERACTIVE:-false}" == "true" ]]; then
    # Non-interactive: keep user's value
    printf '%s' "$current_val"
    return
  fi

  warn "Conflict on key: $key"
  printf "  Current: %s\n" "$current_val"
  printf "  Kit new: %s\n" "$newkit_val"
  printf "  [K]eep yours / [U]se kit's ? "
  local choice=""
  read -r choice
  case "$choice" in
    u|U) printf '%s' "$newkit_val" ;;
    *)   printf '%s' "$current_val" ;;
  esac
}

# ---------------------------------------------------------------------------
# merge_settings_3way - Three-way merge of settings.json
#
# Usage: merge_settings_3way <snapshot> <current> <new_kit> <output>
#
# For each top-level key:
#   - snapshot == current (user didn't change) → use new_kit value
#   - snapshot == new_kit (kit didn't change) → keep current value
#   - Both changed → type-specific merge or prompt
# ---------------------------------------------------------------------------
merge_settings_3way() {
  local snapshot="$1"
  local current="$2"
  local new_kit="$3"
  local output="$4"

  # Start with new_kit as base
  local merged
  merged="$(cat "$new_kit")"

  # Get all keys across all three files
  local all_keys
  all_keys="$(jq -n --slurpfile s "$snapshot" --slurpfile c "$current" --slurpfile n "$new_kit" \
    '[$s[0], $c[0], $n[0] | keys[]] | unique[]' | sort -u)"

  local key
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    # Skip $schema key
    [[ "$key" == '$schema' ]] && continue

    local s_val c_val n_val
    s_val="$(jq --arg k "$key" '.[$k] // null' "$snapshot")"
    c_val="$(jq --arg k "$key" '.[$k] // null' "$current")"
    n_val="$(jq --arg k "$key" '.[$k] // null' "$new_kit")"

    if [[ "$s_val" == "$c_val" ]]; then
      # User didn't change → use new_kit value (already in merged)
      continue
    elif [[ "$s_val" == "$n_val" ]]; then
      # Kit didn't change → keep current (user's) value
      merged="$(echo "$merged" | jq --arg k "$key" --argjson v "$c_val" '.[$k] = $v')"
    elif [[ "$c_val" == "null" ]] && [[ "$s_val" != "null" ]]; then
      # User deleted this key → respect deletion unless kit changed it
      if [[ "$s_val" != "$n_val" ]]; then
        # Kit also changed it - conflict
        local resolved
        resolved="$(_prompt_scalar_conflict "$key" "null" "$n_val")"
        if [[ "$resolved" == "null" ]]; then
          merged="$(echo "$merged" | jq --arg k "$key" 'del(.[$k])')"
        else
          merged="$(echo "$merged" | jq --arg k "$key" --argjson v "$resolved" '.[$k] = $v')"
        fi
      else
        merged="$(echo "$merged" | jq --arg k "$key" 'del(.[$k])')"
      fi
    elif [[ "$s_val" == "null" ]] && [[ "$c_val" != "null" ]] && [[ "$n_val" == "null" ]]; then
      # User added a new key that kit doesn't have → keep it
      merged="$(echo "$merged" | jq --arg k "$key" --argjson v "$c_val" '.[$k] = $v')"
    else
      # Both changed - type-specific handling
      local c_type n_type
      c_type="$(echo "$c_val" | jq -r 'type')"
      n_type="$(echo "$n_val" | jq -r 'type')"

      if [[ "$c_type" == "array" ]] && [[ "$n_type" == "array" ]]; then
        local merged_arr
        merged_arr="$(_merge_arrays_3way "$s_val" "$c_val" "$n_val")"
        merged="$(echo "$merged" | jq --arg k "$key" --argjson v "$merged_arr" '.[$k] = $v')"
      elif [[ "$c_type" == "object" ]] && [[ "$n_type" == "object" ]]; then
        # For nested objects (permissions, hooks, env), recurse on sub-keys
        merged="$(_merge_object_3way "$key" "$s_val" "$c_val" "$n_val" "$merged")"
      else
        local resolved
        resolved="$(_prompt_scalar_conflict "$key" "$c_val" "$n_val")"
        merged="$(echo "$merged" | jq --arg k "$key" --argjson v "$resolved" '.[$k] = $v')"
      fi
    fi
  done <<< "$all_keys"

  printf '%s\n' "$merged" | jq '.' > "$output"
}

# ---------------------------------------------------------------------------
# _merge_object_3way - Merge nested objects (e.g., permissions, hooks, env)
# ---------------------------------------------------------------------------
_merge_object_3way() {
  local parent_key="$1"
  local s_val="$2"
  local c_val="$3"
  local n_val="$4"
  local merged="$5"

  # Get all sub-keys
  local sub_keys
  sub_keys="$(jq -n --argjson s "$s_val" --argjson c "$c_val" --argjson n "$n_val" \
    '[$s, $c, $n | keys[]] | unique[]' | sort -u)"

  local sk
  while IFS= read -r sk; do
    [[ -z "$sk" ]] && continue
    local s_sub c_sub n_sub
    s_sub="$(echo "$s_val" | jq --arg k "$sk" '.[$k] // null')"
    c_sub="$(echo "$c_val" | jq --arg k "$sk" '.[$k] // null')"
    n_sub="$(echo "$n_val" | jq --arg k "$sk" '.[$k] // null')"

    if [[ "$s_sub" == "$c_sub" ]]; then
      # User didn't change this sub-key → use new_kit (already in merged)
      continue
    elif [[ "$s_sub" == "$n_sub" ]]; then
      # Kit didn't change → keep user's value
      merged="$(echo "$merged" | jq --arg pk "$parent_key" --arg sk "$sk" --argjson v "$c_sub" \
        '.[$pk][$sk] = $v')"
    else
      # Both changed
      local c_sub_type n_sub_type
      c_sub_type="$(echo "$c_sub" | jq -r 'type')"
      n_sub_type="$(echo "$n_sub" | jq -r 'type')"

      if [[ "$c_sub_type" == "array" ]] && [[ "$n_sub_type" == "array" ]]; then
        local merged_arr
        merged_arr="$(_merge_arrays_3way "$s_sub" "$c_sub" "$n_sub")"
        merged="$(echo "$merged" | jq --arg pk "$parent_key" --arg sk "$sk" --argjson v "$merged_arr" \
          '.[$pk][$sk] = $v')"
      else
        local resolved
        resolved="$(_prompt_scalar_conflict "${parent_key}.${sk}" "$c_sub" "$n_sub")"
        merged="$(echo "$merged" | jq --arg pk "$parent_key" --arg sk "$sk" --argjson v "$resolved" \
          '.[$pk][$sk] = $v')"
      fi
    fi
  done <<< "$sub_keys"

  printf '%s' "$merged"
}
```

- [ ] **Step 2: Verify shellcheck passes**

Run: `shellcheck -S warning lib/merge.sh`
Expected: No warnings

- [ ] **Step 3: Commit**

```bash
git add lib/merge.sh
git commit -m "feat: add lib/merge.sh for 3-way settings.json merge"
```

## Chunk 2: Update Logic

### Task 3: lib/update.sh — update モードのメインロジック

**Files:**
- Create: `lib/update.sh`

- [ ] **Step 1: Create `lib/update.sh`**

```bash
#!/bin/bash
# lib/update.sh - Update mode logic for Claude Code Starter Kit
# Requires: lib/colors.sh, lib/snapshot.sh, lib/merge.sh, lib/json-builder.sh
set -euo pipefail

# ---------------------------------------------------------------------------
# _prompt_file_action - Ask user what to do with a changed file
#
# Usage: _prompt_file_action <file_path> <snapshot_path> <newkit_path>
# Returns via global: _FILE_ACTION (overwrite|append|skip)
# ---------------------------------------------------------------------------
_FILE_ACTION=""
_prompt_file_action() {
  local current="$1"
  local snapshot="$2"
  local newkit="$3"
  local display_path="${current#"$HOME"/}"

  if [[ "${WIZARD_NONINTERACTIVE:-false}" == "true" ]]; then
    _FILE_ACTION="skip"
    return
  fi

  while true; do
    warn "$STR_UPDATE_FILE_CHANGED: ~/${display_path}"
    printf "  [A]ppend / [S]kip / [D]iff ? "
    local choice=""
    read -r choice
    case "$choice" in
      a|A)
        _FILE_ACTION="append"
        return
        ;;
      s|S)
        _FILE_ACTION="skip"
        return
        ;;
      d|D)
        printf "\n"
        info "--- Snapshot (kit original)"
        info "+++ Current (your version)"
        diff -u "$snapshot" "$current" 2>/dev/null || true
        printf "\n"
        info "--- Current (your version)"
        info "+++ New kit version"
        diff -u "$current" "$newkit" 2>/dev/null || true
        printf "\n"
        ;;
      *)
        _FILE_ACTION="skip"
        return
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# _update_file - Update a single file with user change detection
#
# Usage: _update_file <current_path> <snapshot_path> <newkit_path>
# Returns 0 if file was updated, 1 if skipped
# ---------------------------------------------------------------------------
_update_file() {
  local current="$1"
  local snapshot="$2"
  local newkit="$3"

  # New file from kit (not in snapshot)
  if [[ ! -f "$snapshot" ]]; then
    cp -a "$newkit" "$current"
    return 0
  fi

  # Current file was deleted by user
  if [[ ! -f "$current" ]]; then
    if [[ "${WIZARD_NONINTERACTIVE:-false}" == "true" ]]; then
      return 1
    fi
    info "File deleted by you: ${current#"$HOME"/}"
    printf "  [R]estore / [S]kip ? "
    local choice=""
    read -r choice
    case "$choice" in
      r|R) cp -a "$newkit" "$current"; return 0 ;;
      *)   return 1 ;;
    esac
  fi

  # No user change → safe to overwrite
  if ! _file_changed "$snapshot" "$current"; then
    cp -a "$newkit" "$current"
    return 0
  fi

  # No kit change → keep current
  if ! _file_changed "$snapshot" "$newkit"; then
    return 1
  fi

  # Both changed → ask user
  _prompt_file_action "$current" "$snapshot" "$newkit"
  case "$_FILE_ACTION" in
    append)
      # Append new kit content after current content
      printf "\n# --- Updated by Claude Code Starter Kit ---\n" >> "$current"
      cat "$newkit" >> "$current"
      return 0
      ;;
    skip)
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _collect_kit_files - Build list of files that kit would deploy
#
# Usage: _collect_kit_files <project_dir> <claude_dir>
# Sets global array: _KIT_FILES (relative paths)
# ---------------------------------------------------------------------------
_KIT_FILES=()
_collect_kit_files() {
  local project_dir="$1"
  local claude_dir="$2"
  _KIT_FILES=()

  local dir rel_file
  for dir in agents rules commands skills memory; do
    if [[ -d "$project_dir/$dir" ]]; then
      while IFS= read -r -d '' file; do
        rel_file="${file#"${project_dir}/"}"
        _KIT_FILES+=("$rel_file")
      done < <(find "$project_dir/$dir" -type f -print0 2>/dev/null)
    fi
  done
}

# ---------------------------------------------------------------------------
# run_update - Main update entry point
#
# Usage: run_update <project_dir> <claude_dir>
# ---------------------------------------------------------------------------
run_update() {
  local project_dir="$1"
  local claude_dir="$2"
  local snapshot_dir="${claude_dir}/.starter-kit-snapshot"

  section "$STR_UPDATE_TITLE"
  local skipped_files=()
  local updated_files=()

  # --- Phase 1: settings.json ---
  info "$STR_UPDATE_SETTINGS"

  # Build new kit settings to a temp file
  local new_settings
  new_settings="$(mktemp)"
  _SETUP_TMP_FILES+=("$new_settings")
  build_settings_to_file "$new_settings"

  local current_settings="${claude_dir}/settings.json"
  local snapshot_settings="${snapshot_dir}/settings.json"

  if [[ -f "$snapshot_settings" ]] && [[ -f "$current_settings" ]]; then
    if ! _file_changed "$snapshot_settings" "$current_settings"; then
      # User didn't change settings → safe to overwrite
      cp -a "$new_settings" "$current_settings"
      ok "$STR_UPDATE_SETTINGS_UPDATED"
    elif ! _file_changed "$snapshot_settings" "$new_settings"; then
      # Kit didn't change → keep current
      ok "$STR_UPDATE_SETTINGS_UNCHANGED"
    else
      # Both changed → 3-way merge
      info "$STR_UPDATE_SETTINGS_MERGING"
      merge_settings_3way "$snapshot_settings" "$current_settings" "$new_settings" "$current_settings"
      ok "$STR_UPDATE_SETTINGS_MERGED"
    fi
  else
    # No snapshot → treat as fresh install for settings
    cp -a "$new_settings" "$current_settings"
    ok "$STR_UPDATE_SETTINGS_UPDATED"
  fi
  updated_files+=("$current_settings")

  # --- Phase 2: CLAUDE.md ---
  info "$STR_UPDATE_CLAUDEMD"

  local new_claude_md
  new_claude_md="$(mktemp)"
  _SETUP_TMP_FILES+=("$new_claude_md")
  build_claude_md_to_file "$new_claude_md"

  local current_claude_md="${claude_dir}/CLAUDE.md"
  local snapshot_claude_md="${snapshot_dir}/CLAUDE.md"

  if _update_file "$current_claude_md" "$snapshot_claude_md" "$new_claude_md"; then
    updated_files+=("$current_claude_md")
    ok "$STR_UPDATE_CLAUDEMD_UPDATED"
  else
    skipped_files+=("CLAUDE.md")
    info "$STR_UPDATE_CLAUDEMD_SKIPPED"
  fi

  # --- Phase 3: Content directories ---
  local dir
  for dir in agents rules commands skills memory; do
    local src_dir="${project_dir}/${dir}"
    local dest_dir="${claude_dir}/${dir}"
    local snap_dir="${snapshot_dir}/${dir}"

    [[ -d "$src_dir" ]] || continue

    # Check INSTALL_* flag
    local flag_var="INSTALL_$(printf '%s' "$dir" | tr '[:lower:]' '[:upper:]')"
    if ! is_true "${!flag_var:-false}"; then
      continue
    fi

    mkdir -p "$dest_dir"

    while IFS= read -r -d '' src_file; do
      local basename
      basename="$(basename "$src_file")"
      local dest_file="${dest_dir}/${basename}"
      local snap_file="${snap_dir}/${basename}"

      if _update_file "$dest_file" "$snap_file" "$src_file"; then
        updated_files+=("$dest_file")
      else
        skipped_files+=("${dir}/${basename}")
      fi
    done < <(find "$src_dir" -type f -print0 2>/dev/null)
  done

  # --- Phase 4: Hook scripts ---
  deploy_hook_scripts

  # --- Phase 5: Update snapshot (only for updated files) ---
  info "$STR_UPDATE_SNAPSHOT"
  for file in "${updated_files[@]}"; do
    _update_snapshot_file "$claude_dir" "$file"
  done
  ok "$STR_UPDATE_SNAPSHOT_DONE"

  # --- Report ---
  if [[ ${#skipped_files[@]} -gt 0 ]]; then
    printf "\n"
    info "$STR_UPDATE_SKIPPED_TITLE"
    for f in "${skipped_files[@]}"; do
      info "  - $f"
    done
  fi

  printf "\n"
  ok "$STR_UPDATE_COMPLETE (${#updated_files[@]} updated, ${#skipped_files[@]} skipped)"
}
```

- [ ] **Step 2: Verify shellcheck passes**

Run: `shellcheck -S warning lib/update.sh`
Expected: No warnings

- [ ] **Step 3: Commit**

```bash
git add lib/update.sh
git commit -m "feat: add lib/update.sh for update mode logic"
```

### Task 4: i18n — update 用文字列の追加

**Files:**
- Modify: `i18n/en/strings.sh`
- Modify: `i18n/ja/strings.sh`

- [ ] **Step 1: Add English strings to `i18n/en/strings.sh`**

Append before `# Errors` section (line 234):

```bash
# Update mode
STR_UPDATE_TITLE="Updating Claude Code Starter Kit"
STR_UPDATE_DETECTED="Existing installation detected. Running in update mode."
STR_UPDATE_NO_SNAPSHOT="No snapshot found. Full re-setup required for first update."
STR_UPDATE_SETTINGS="Checking settings.json..."
STR_UPDATE_SETTINGS_UPDATED="settings.json updated"
STR_UPDATE_SETTINGS_UNCHANGED="settings.json unchanged (kit has no changes)"
STR_UPDATE_SETTINGS_MERGING="Merging settings.json (both you and kit have changes)..."
STR_UPDATE_SETTINGS_MERGED="settings.json merged successfully"
STR_UPDATE_CLAUDEMD="Checking CLAUDE.md..."
STR_UPDATE_CLAUDEMD_UPDATED="CLAUDE.md updated"
STR_UPDATE_CLAUDEMD_SKIPPED="CLAUDE.md skipped (keeping your version)"
STR_UPDATE_FILE_CHANGED="File has been modified by you"
STR_UPDATE_SNAPSHOT="Updating snapshot..."
STR_UPDATE_SNAPSHOT_DONE="Snapshot updated"
STR_UPDATE_SKIPPED_TITLE="Skipped files (user-modified):"
STR_UPDATE_COMPLETE="Update complete"
STR_UPDATE_V1_WARN="Previous installation uses old manifest format. Running full setup with snapshot creation."
```

- [ ] **Step 2: Add Japanese strings to `i18n/ja/strings.sh`**

Append before `# Errors` section (line 232):

```bash
# Update mode
STR_UPDATE_TITLE="Claude Code Starter Kit を更新中"
STR_UPDATE_DETECTED="既存のインストールを検出しました。更新モードで実行します。"
STR_UPDATE_NO_SNAPSHOT="スナップショットが見つかりません。初回の更新にはフルセットアップが必要です。"
STR_UPDATE_SETTINGS="settings.json を確認中..."
STR_UPDATE_SETTINGS_UPDATED="settings.json を更新しました"
STR_UPDATE_SETTINGS_UNCHANGED="settings.json に変更なし（kit 側の変更なし）"
STR_UPDATE_SETTINGS_MERGING="settings.json をマージ中（あなたと kit の両方に変更あり）..."
STR_UPDATE_SETTINGS_MERGED="settings.json のマージが完了しました"
STR_UPDATE_CLAUDEMD="CLAUDE.md を確認中..."
STR_UPDATE_CLAUDEMD_UPDATED="CLAUDE.md を更新しました"
STR_UPDATE_CLAUDEMD_SKIPPED="CLAUDE.md をスキップしました（あなたのバージョンを維持）"
STR_UPDATE_FILE_CHANGED="ファイルがあなたによって変更されています"
STR_UPDATE_SNAPSHOT="スナップショットを更新中..."
STR_UPDATE_SNAPSHOT_DONE="スナップショットを更新しました"
STR_UPDATE_SKIPPED_TITLE="スキップしたファイル（ユーザーが変更済み）:"
STR_UPDATE_COMPLETE="更新完了"
STR_UPDATE_V1_WARN="以前のインストールは古いマニフェスト形式です。スナップショット作成付きでフルセットアップを実行します。"
```

- [ ] **Step 3: Commit**

```bash
git add i18n/en/strings.sh i18n/ja/strings.sh
git commit -m "feat: add i18n strings for update mode"
```

## Chunk 3: Integration

### Task 5: manifest v2 への拡張

**Files:**
- Modify: `setup.sh:274-304` (`write_manifest()` function)

- [ ] **Step 1: Update `write_manifest()` to v2 format**

In `setup.sh`, replace the `write_manifest()` function with:

```bash
write_manifest() {
  local manifest="$CLAUDE_DIR/.starter-kit-manifest.json"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # Read kit version from VERSION file or git tag
  local kit_version="unknown"
  if [[ -f "$PROJECT_DIR/VERSION" ]]; then
    kit_version="$(cat "$PROJECT_DIR/VERSION")"
  elif git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null; then
    kit_version="$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null)"
  fi

  # Only track files in starter-kit-managed directories (not plugins, sessions, etc.)
  local files_json
  files_json="$({
    find "$CLAUDE_DIR/agents" "$CLAUDE_DIR/rules" "$CLAUDE_DIR/commands" \
         "$CLAUDE_DIR/skills" "$CLAUDE_DIR/memory" "$CLAUDE_DIR/hooks" \
         -type f 2>/dev/null || true
    [[ -f "$CLAUDE_DIR/CLAUDE.md" ]] && echo "$CLAUDE_DIR/CLAUDE.md"
    [[ -f "$CLAUDE_DIR/settings.json" ]] && echo "$CLAUDE_DIR/settings.json"
  } | sort -u | jq -R -s 'split("\n")[:-1]')"

  jq -n \
    --arg version "2" \
    --arg ts "$ts" \
    --arg kit_version "$kit_version" \
    --arg profile "${PROFILE:-}" \
    --arg language "${LANGUAGE:-}" \
    --arg editor "${EDITOR_CHOICE:-}" \
    --arg plugins "${SELECTED_PLUGINS:-}" \
    --argjson files "$files_json" \
    --arg snapshot_dir "$CLAUDE_DIR/.starter-kit-snapshot" \
    '{
      version: $version,
      timestamp: $ts,
      kit_version: $kit_version,
      profile: $profile,
      language: $language,
      editor: $editor,
      plugins: $plugins,
      files: $files,
      snapshot_dir: $snapshot_dir
    }' > "$manifest"
}
```

- [ ] **Step 2: Commit**

```bash
git add setup.sh
git commit -m "feat: upgrade write_manifest() to v2 format"
```

### Task 6: setup.sh に update モード分岐と snapshot 書き出しを追加

**Files:**
- Modify: `setup.sh`

- [ ] **Step 1: Add `lib/snapshot.sh`, `lib/merge.sh`, `lib/update.sh` sourcing (after line 52)**

After `. "$PROJECT_DIR/lib/json-builder.sh"`, add:

```bash
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/snapshot.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/merge.sh"
# shellcheck source=/dev/null
. "$PROJECT_DIR/lib/update.sh"
```

- [ ] **Step 2: Add `build_settings_to_file()` helper function**

Add after `build_settings()` (around line 240):

```bash
# ---------------------------------------------------------------------------
# Build settings.json to a specified file (for update mode comparison)
# ---------------------------------------------------------------------------
build_settings_to_file() {
  local out="$1"
  local base="$PROJECT_DIR/config/settings-base.json"
  local permissions="$PROJECT_DIR/config/permissions.json"

  local hook_fragments=()
  local tmp_files=()

  if is_true "$ENABLE_TMUX_HOOKS"; then
    hook_fragments+=("$PROJECT_DIR/features/tmux-hooks/hooks.json")
  fi
  if is_true "$ENABLE_DOC_BLOCKER"; then
    hook_fragments+=("$PROJECT_DIR/features/doc-blocker/hooks.json")
  fi
  if is_true "$ENABLE_PRETTIER_HOOKS"; then
    hook_fragments+=("$PROJECT_DIR/features/prettier-hooks/hooks.json")
  fi
  if is_true "$ENABLE_CONSOLE_LOG_GUARD"; then
    hook_fragments+=("$PROJECT_DIR/features/console-log-guard/hooks.json")
  fi
  if is_true "$ENABLE_MEMORY_PERSISTENCE"; then
    hook_fragments+=("$PROJECT_DIR/features/memory-persistence/hooks.json")
  fi
  if is_true "$ENABLE_STRATEGIC_COMPACT"; then
    hook_fragments+=("$PROJECT_DIR/features/strategic-compact/hooks.json")
  fi
  if is_true "$ENABLE_PR_CREATION_LOG"; then
    hook_fragments+=("$PROJECT_DIR/features/pr-creation-log/hooks.json")
  fi
  if is_true "${ENABLE_PRE_COMPACT_COMMIT:-false}"; then
    hook_fragments+=("$PROJECT_DIR/features/pre-compact-commit/hooks.json")
  fi
  if is_true "${ENABLE_STATUSLINE:-false}"; then
    hook_fragments+=("$PROJECT_DIR/features/statusline/hooks.json")
  fi

  if is_true "$ENABLE_GIT_PUSH_REVIEW"; then
    if [[ "${EDITOR_CHOICE:-none}" != "none" ]]; then
      local editor_cmd editor_cmd_escaped src tmp
      editor_cmd="$(editor_command "$EDITOR_CHOICE")"
      editor_cmd_escaped="$(printf '%s\n' "$editor_cmd" | sed 's/[&\\|]/\\&/g')"
      src="$PROJECT_DIR/features/git-push-review/hooks.json"
      tmp="$(mktemp)"
      _SETUP_TMP_FILES+=("$tmp")
      if grep -q "__EDITOR_CMD__" "$src" 2>/dev/null; then
        sed "s|__EDITOR_CMD__|$editor_cmd_escaped|g" "$src" > "$tmp"
      else
        cp -a "$src" "$tmp"
      fi
      hook_fragments+=("$tmp")
      tmp_files+=("$tmp")
    fi
  fi

  build_settings_json "$base" "$permissions" "$out" ${hook_fragments[@]+"${hook_fragments[@]}"}

  local lang_name
  lang_name="$(language_name)"
  local tmp_lang
  tmp_lang="$(mktemp)"
  _SETUP_TMP_FILES+=("$tmp_lang")
  jq --arg lang "$lang_name" '.language = $lang' "$out" > "$tmp_lang"
  mv "$tmp_lang" "$out"

  replace_home_path "$out"

  if [[ ${#tmp_files[@]} -gt 0 ]]; then
    rm -f "${tmp_files[@]}"
  fi
}

# ---------------------------------------------------------------------------
# Build CLAUDE.md to a specified file (for update mode comparison)
# ---------------------------------------------------------------------------
build_claude_md_to_file() {
  local out="$1"
  local lang="${LANGUAGE:-en}"
  local base="$PROJECT_DIR/i18n/${lang}/CLAUDE.md.base"

  cp -a "$base" "$out"

  if is_true "$ENABLE_CODEX_MCP"; then
    local partial="$PROJECT_DIR/features/codex-mcp/CLAUDE.md.partial.${lang}"
    inject_feature "$out" "codex-mcp" "$partial"
  fi

  remove_unresolved "$out"
}
```

- [ ] **Step 3: Add update mode detection and snapshot writing to deploy section**

Replace the deploy section (lines 309-351) with:

```bash
# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
  # Update mode: restore config from manifest and run update
  section "$STR_UPDATE_DETECTED"
  run_update "$PROJECT_DIR" "$CLAUDE_DIR"
else
  # Fresh install / full re-setup
  section "Deploying Claude Code Starter Kit"

  backup_existing
  ensure_dirs

  copy_if_enabled "$INSTALL_AGENTS"  "$PROJECT_DIR/agents"   "$CLAUDE_DIR/agents"
  copy_if_enabled "$INSTALL_RULES"   "$PROJECT_DIR/rules"    "$CLAUDE_DIR/rules"
  copy_if_enabled "$INSTALL_COMMANDS" "$PROJECT_DIR/commands" "$CLAUDE_DIR/commands"
  copy_if_enabled "$INSTALL_SKILLS"  "$PROJECT_DIR/skills"   "$CLAUDE_DIR/skills"
  copy_if_enabled "$INSTALL_MEMORY"  "$PROJECT_DIR/memory"   "$CLAUDE_DIR/memory"

  build_claude_md
  build_settings
  deploy_hook_scripts

  # Write snapshot for future updates
  local _snapshot_files=()
  [[ -f "$CLAUDE_DIR/settings.json" ]] && _snapshot_files+=("$CLAUDE_DIR/settings.json")
  [[ -f "$CLAUDE_DIR/CLAUDE.md" ]] && _snapshot_files+=("$CLAUDE_DIR/CLAUDE.md")
  while IFS= read -r -d '' _sf; do
    _snapshot_files+=("$_sf")
  done < <(find "$CLAUDE_DIR/agents" "$CLAUDE_DIR/rules" "$CLAUDE_DIR/commands" \
               "$CLAUDE_DIR/skills" "$CLAUDE_DIR/memory" "$CLAUDE_DIR/hooks" \
               -type f -print0 2>/dev/null)
  _write_snapshot "$CLAUDE_DIR" "${_snapshot_files[@]}"
  ok "Created snapshot for future updates"
fi

write_manifest

# Save config for re-runs
save_config "${WIZARD_CONFIG_FILE:-$HOME/.claude-starter-kit.conf}"

section "Setup Complete"
ok "Deployed to $CLAUDE_DIR"
```

- [ ] **Step 4: Verify shellcheck passes**

Run: `shellcheck -S warning setup.sh`
Expected: No warnings

- [ ] **Step 5: Commit**

```bash
git add setup.sh
git commit -m "feat: integrate update mode and snapshot writing into setup.sh"
```

### Task 7: wizard/wizard.sh に `--update` フラグ追加

**Files:**
- Modify: `wizard/wizard.sh:397-439` (`parse_cli_args()`)

- [ ] **Step 1: Add `UPDATE_MODE` global and `--update` parsing**

Add global (after line 37):

```bash
UPDATE_MODE="${UPDATE_MODE:-false}"
```

Add to `parse_cli_args()` case (after `--non-interactive)` case):

```bash
      --update)
        UPDATE_MODE="true"
        WIZARD_NONINTERACTIVE="true"
        ;;
```

- [ ] **Step 2: Add `_restore_config_from_manifest()` function**

Add after `save_config()` (around line 216):

```bash
# ---------------------------------------------------------------------------
# Restore configuration from manifest (for update mode)
# ---------------------------------------------------------------------------
_restore_config_from_manifest() {
  local manifest="$HOME/.claude/.starter-kit-manifest.json"
  [[ -f "$manifest" ]] || return 1

  PROFILE="$(jq -r '.profile // "standard"' "$manifest")"
  LANGUAGE="$(jq -r '.language // "en"' "$manifest")"
  EDITOR_CHOICE="$(jq -r '.editor // "none"' "$manifest")"
  SELECTED_PLUGINS="$(jq -r '.plugins // ""' "$manifest")"

  # Load profile config to get INSTALL_* and ENABLE_* flags
  load_profile_config "$PROFILE"

  # Load saved wizard config for feature toggles
  load_config "${WIZARD_CONFIG_FILE:-$HOME/.claude-starter-kit.conf}"

  load_strings "$LANGUAGE"
}
```

- [ ] **Step 3: Update `run_wizard()` to skip wizard in update mode**

At the beginning of `run_wizard()` (after sourcing libraries), add:

```bash
  # Update mode: restore from manifest, skip wizard
  if [[ "$UPDATE_MODE" == "true" ]]; then
    _restore_config_from_manifest
    WIZARD_RESULT="deploy"
    return
  fi
```

- [ ] **Step 4: Verify shellcheck passes**

Run: `shellcheck -S warning wizard/wizard.sh`
Expected: No warnings

- [ ] **Step 5: Commit**

```bash
git add wizard/wizard.sh
git commit -m "feat: add --update flag and manifest config restore to wizard"
```

### Task 8: install.sh に manifest v2 自動判定を追加

**Files:**
- Modify: `install.sh:139-174`

- [ ] **Step 1: Add manifest detection after `clone_or_update()`**

Replace the main section (lines 140-174) with:

```bash
printf "\n${BOLD}Claude Code Starter Kit - Bootstrap${NC}\n\n"

check_required
clone_or_update

chmod +x "$INSTALL_DIR/setup.sh"
chmod +x "$INSTALL_DIR/uninstall.sh" 2>/dev/null || true

# Support NONINTERACTIVE env var (same convention as Homebrew)
_setup_args=("$@")
if [[ -n "${NONINTERACTIVE:-}" ]]; then
  _has_ni=false
  for _arg in "${_setup_args[@]+"${_setup_args[@]}"}"; do
    [[ "$_arg" == "--non-interactive" ]] && _has_ni=true
  done
  if [[ "$_has_ni" == "false" ]]; then
    _setup_args+=("--non-interactive")
  fi
fi

# ---------------------------------------------------------------------------
# Auto-detect update mode via manifest
# ---------------------------------------------------------------------------
_manifest="$HOME/.claude/.starter-kit-manifest.json"
_snapshot_dir="$HOME/.claude/.starter-kit-snapshot"
_update_mode=false

if [[ -f "$_manifest" ]]; then
  # Check manifest version
  _manifest_version=""
  if command -v jq &>/dev/null; then
    _manifest_version="$(jq -r '.version // "1"' "$_manifest" 2>/dev/null || echo "1")"
  fi

  if [[ "$_manifest_version" == "2" ]] && [[ -d "$_snapshot_dir" ]]; then
    _update_mode=true
    info "Existing installation detected (manifest v2). Running update mode."
    # Add --update flag if not already present
    _has_update=false
    for _arg in "${_setup_args[@]+"${_setup_args[@]}"}"; do
      [[ "$_arg" == "--update" ]] && _has_update=true
    done
    if [[ "$_has_update" == "false" ]]; then
      _setup_args+=("--update")
    fi
  else
    info "Existing installation detected (manifest v1). Running full setup with snapshot."
    warn "Your previous settings will be backed up before overwriting."
  fi
fi

# Check if non-interactive mode is requested
_is_noninteractive=false
for _arg in "${_setup_args[@]+"${_setup_args[@]}"}"; do
  [[ "$_arg" == "--non-interactive" || "$_arg" == "--update" ]] && _is_noninteractive=true
done

if [[ "$_is_noninteractive" == "true" ]]; then
  if [[ "$_update_mode" == "true" ]]; then
    info "Starting update..."
  else
    info "Starting non-interactive setup (standard profile)..."
  fi
  exec bash "$INSTALL_DIR/setup.sh" ${_setup_args[@]+"${_setup_args[@]}"}
else
  info "Starting interactive setup..."
  exec bash "$INSTALL_DIR/setup.sh" ${_setup_args[@]+"${_setup_args[@]}"} </dev/tty
fi
```

- [ ] **Step 2: Verify shellcheck passes**

Run: `shellcheck -S warning install.sh`
Expected: No warnings

- [ ] **Step 3: Commit**

```bash
git add install.sh
git commit -m "feat: auto-detect update mode via manifest v2 in install.sh"
```

## Chunk 4: Documentation & CLAUDE.md

### Task 9: CLAUDE.md にアップデート機能のドキュメントを追加

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add update mechanism section to CLAUDE.md**

Add after the `### Manifest-Based Uninstall` section:

```markdown
### Update Mechanism

When `install.sh` detects an existing installation with manifest v2 + snapshot, it automatically switches to update mode (`setup.sh --update`). This preserves user-customized settings while applying kit updates.

**Three-way comparison:** For each kit-managed file, the system compares:
- **Snapshot** (what kit deployed last time)
- **Current** (what's on disk now, possibly user-modified)
- **New kit** (what the updated kit would deploy)

**Decision matrix:**
| Snapshot vs Current | Snapshot vs New Kit | Action |
|---|---|---|
| Same | Different | Overwrite with new kit |
| Different | Same | Keep current (no kit changes) |
| Different | Different | Interactive prompt |

**settings.json merge:** Uses jq-based 3-way merge at the key level. Arrays (permissions, hooks) are merged with deduplication. User-added keys (e.g., `mcpServers`) are preserved. Scalar conflicts prompt the user.

**Non-interactive update:** `--non-interactive` skips all prompts, keeping user-modified files and only updating unchanged ones.

**Snapshot directory:** `~/.claude/.starter-kit-snapshot/` mirrors the structure of `~/.claude/` for kit-managed files only.
```

- [ ] **Step 2: Update Commands section**

Add to the Commands section:

```markdown
# Update existing installation (auto-detected)
curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh | bash

# Force update mode
bash setup.sh --update

# Force full re-setup (ignores existing installation)
bash setup.sh
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add update mechanism documentation to CLAUDE.md"
```

### Task 10: 最終検証

- [ ] **Step 1: Run shellcheck on all modified files**

```bash
shellcheck -S warning setup.sh install.sh lib/snapshot.sh lib/merge.sh lib/update.sh wizard/wizard.sh
```
Expected: No warnings

- [ ] **Step 2: Validate JSON files**

```bash
jq . config/plugins.json > /dev/null
jq . config/settings-base.json > /dev/null
jq . config/permissions.json > /dev/null
```
Expected: All valid

- [ ] **Step 3: Dry-run fresh install to verify snapshot creation**

```bash
# In a test environment or with backup
bash setup.sh --non-interactive
ls -la ~/.claude/.starter-kit-snapshot/
cat ~/.claude/.starter-kit-manifest.json | jq '.version'
```
Expected: Snapshot directory created, manifest version is "2"

- [ ] **Step 4: Commit all remaining changes**

```bash
git add -A
git commit -m "feat: update mechanism with snapshot-based 3-way merge"
```
