#!/bin/bash
# lib/merge.sh - Three-way merge for settings.json during kit upgrades
#
# Architecture: all per-key decisions live in one core, _resolve_key_3way(),
# shared by the three public entry points (thin wrappers):
#   1. merge_settings_3way()      — top-level 3-way (mode=top)
#   2. _merge_object_3way()       — one level deep (mode=nested)
#   3. _merge_settings_bootstrap()— first migration, no snapshot (mode=bootstrap)
# Array conflicts use _merge_arrays_3way() (element-level, preserves both
# user and kit additions); value extraction goes through _json_key_or_null()
# so false/0/"" are never misread as missing keys.
#
# Requires: jq, lib/colors.sh
# Uses globals: _MERGE_INTERACTIVE, _MERGE_PREFS, _MERGE_PREFS_FILE,
#               _RESET_MERGE_PREFS, CLAUDE_DIR, STR_MERGE_*
# Exports: merge_settings_3way(), _merge_settings_bootstrap(),
#          _prompt_scalar_conflict(), _prompt_array_conflict(),
#          _load_merge_prefs(), _merge_prefs_file()
# Dry-run: transparent (operates on whatever paths are given; _MERGE_INTERACTIVE
#          is set to false by dryrun to suppress prompts)
set -euo pipefail

_merge_progress_detail() {
  if [[ "${_QUIET_OUTPUT:-false}" != "true" ]]; then
    info "$*"
  fi
}

_merge_progress_stderr_detail() {
  if [[ "${_QUIET_OUTPUT:-false}" != "true" ]]; then
    printf '%s\n' "$*" >&2
  fi
}

_merge_progress_tick_if_needed() {
  local label="$1"
  local current="$2"
  local total="$3"
  if [[ "$current" -eq "$total" ]] || (( current % 5 == 0 )); then
    _progress_tick "$label" "$current" "$total"
  fi
}

# ---------------------------------------------------------------------------
# Merge preference persistence ("remember my answer")
#
# Stores user decisions in ~/.claude/.starter-kit-merge-prefs.json so
# recurring conflicts are resolved automatically.
# ---------------------------------------------------------------------------
# Resolved at first use via _merge_prefs_file() so CLAUDE_DIR redirect
# (e.g. dry-run sim dir) is respected.
_MERGE_PREFS_FILE=""
_MERGE_PREFS_LOADED=false
_MERGE_PREFS="{}"

# Lazily resolve the merge prefs path so CLAUDE_DIR redirect is respected.
_merge_prefs_file() {
  if [[ -z "$_MERGE_PREFS_FILE" ]]; then
    _MERGE_PREFS_FILE="${CLAUDE_DIR:=${HOME}/.claude}/.starter-kit-merge-prefs.json"
  fi
}

_load_merge_prefs() {
  _merge_prefs_file
  if [[ "$_MERGE_PREFS_LOADED" == "true" ]]; then
    return
  fi
  if [[ "${_RESET_MERGE_PREFS:-false}" == "true" ]]; then
    _MERGE_PREFS="{}"
    rm -f "$_MERGE_PREFS_FILE" || return 1
    _MERGE_PREFS_LOADED=true
    return
  fi
  if [[ -f "$_MERGE_PREFS_FILE" ]] && jq empty "$_MERGE_PREFS_FILE" 2>/dev/null; then
    _MERGE_PREFS="$(< "$_MERGE_PREFS_FILE")"
  else
    _MERGE_PREFS="{}"
  fi
  _MERGE_PREFS_LOADED=true
}

# _get_merge_pref <key> — prints "keep-mine", "use-kit", or empty string
_get_merge_pref() {
  local key="$1"
  _load_merge_prefs || return 1
  local val
  val="$(printf '%s' "$_MERGE_PREFS" \
    | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null)" || return 1
  printf '%s' "$val"
}

# _save_merge_pref <key> <value>  (value: "keep-mine" or "use-kit")
_save_merge_pref() {
  local key="$1"
  local value="$2"
  _merge_prefs_file
  _load_merge_prefs || return 1
  _MERGE_PREFS="$(printf '%s' "$_MERGE_PREFS" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')" || return 1
  printf '%s\n' "$_MERGE_PREFS" > "$_MERGE_PREFS_FILE" || return 1
}

# ---------------------------------------------------------------------------
# Shared JSON helpers
#
# Single home for the has($k)-aware value extraction that was previously
# duplicated 8 times across the three merge implementations (regression #81:
# `// null` style extraction misread real false values as missing keys).
# ---------------------------------------------------------------------------

# _json_key_or_null <json_object_doc> <key>
# Prints the key's value as compact JSON, or the "null" sentinel when the key
# is absent (or the doc is not an object). false/0/"" are real values — only
# a missing key (or a literal JSON null value) maps to "null".
_json_key_or_null() {
  local doc="$1"
  local key="$2"
  local v
  v="$(jq -cn --argjson o "$doc" --arg k "$key" \
    'if ($o | has($k)) then $o[$k] else null end' 2>/dev/null)" || return 1
  [[ -n "$v" ]] || return 1
  printf '%s' "$v"
}

# _json_equal <a> <b> — prints "true"/"false" (jq semantic equality)
_json_equal() {
  jq -n --argjson a "$1" --argjson b "$2" '$a == $b' 2>/dev/null
}

# _json_type <v> — prints jq type name (object/array/string/number/boolean/null)
_json_type() {
  jq -rn --argjson v "$1" '$v | type' 2>/dev/null
}

_merge_mdm_managed() {
  case "$(printf '%s' "${KIT_MDM_MANAGED:-}" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
    true|1|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

# The generated settings document is wholly MDM-owned. Keeping local-only keys
# would allow a target user to inject unreviewed hooks or environment settings
# into a deployment that is otherwise reported as compliant.
_merge_settings_mdm_documents() {
  local n_doc="$3" output="$4"
  local tmp_out
  tmp_out="$(mktemp)" || return 1
  if ! jq -n \
    --argjson n "$n_doc" '$n | if type == "object" then . else error("settings must be an object") end' \
    > "$tmp_out"; then
    rm -f "$tmp_out"
    error "MDM authoritative settings merge failed"
    return 1
  fi
  mv "$tmp_out" "$output" || return 1
}

# ---------------------------------------------------------------------------
# _merge_arrays_3way - Merge a JSON array using 3-way logic
#
# Usage: _merge_arrays_3way <snapshot_json> <current_json> <newkit_json>
# Prints the merged JSON array to stdout.
#
# Rules:
#   - Items in current but not snapshot  → user added   → keep
#   - Items in newkit  but not snapshot  → kit added    → add
#   - Items in snapshot but not newkit, still in current
#                                        → kit removed  → ask (interactive)
#                                                          keep (non-interactive)
#   - Deduplicate via jq 'unique'
# ---------------------------------------------------------------------------
_merge_arrays_3way() {
  local s_val="$1"  # snapshot array JSON
  local c_val="$2"  # current  array JSON
  local n_val="$3"  # new-kit  array JSON

  # Determine items to keep/remove through set operations via jq
  # user_added  = current \ snapshot  (user introduced these)
  # kit_removed = snapshot \ newkit, still in current  (kit deleted these)
  local user_added kit_removed
  user_added="$(jq -n \
    --argjson s "$s_val" \
    --argjson c "$c_val" \
    '[$c[] | select(. as $item | $s | map(. == $item) | any | not)]')" || return 1

  kit_removed="$(jq -n \
    --argjson s "$s_val" \
    --argjson c "$c_val" \
    --argjson n "$n_val" \
    '[
      $s[] | . as $item |
      select(
        ($n | map(. == $item) | any | not) and
        ($c | map(. == $item) | any)
      )
    ]')" || return 1

  # Base result: newkit array (authoritative — already includes kit_added items)
  # plus user additions (items the user added that the kit never had)
  local merged
  merged="$(jq -n \
    --argjson n "$n_val" \
    --argjson ua "$user_added" \
    '$n + $ua | unique')" || return 1

  # Handle kit-removed items that still exist in current
  local removed_count
  removed_count="$(printf '%s' "$kit_removed" | jq 'length')" || return 1

  if [[ "$removed_count" -gt 0 ]]; then
    if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]]; then
      # Non-interactive: safe default is to keep user's values
      merged="$(jq -n \
        --argjson m "$merged" \
        --argjson kr "$kit_removed" \
        '$m + $kr | unique')" || return 1
    else
      # Interactive: ask for each removed item
      local i=0
      while [[ "$i" -lt "$removed_count" ]]; do
        local item
        item="$(printf '%s' "$kit_removed" | jq ".[$i]")" || return 1
        warn "$STR_MERGE_ARRAY_KIT_REMOVED"
        printf "  %s\n" "$item" >&2
        printf "  %s " "$STR_MERGE_ARRAY_KEEP_REMOVE" >&2
        local reply
        if read -r reply < /dev/tty 2>/dev/null; then
          true
        else
          reply="k"
        fi
        case "$reply" in
          [Rr]*)
            # Kit's removal wins — item stays out of merged
            ;;
          *)
            # Keep user's value
            merged="$(jq -n \
              --argjson m "$merged" \
              --argjson item "$item" \
              '$m + [$item] | unique')" || return 1
            ;;
        esac
        i=$((i + 1))
      done
    fi
  fi

  printf '%s' "$merged"
}

# ---------------------------------------------------------------------------
# _prompt_array_conflict - Resolve an array conflict
#
# Usage: _prompt_array_conflict <key> <snapshot_json> <current_json> <newkit_json>
# Prints the chosen JSON array to stdout.
#
# Checks saved prefs, then prompts user to keep their entire array or use
# the kit's. Only whole-array replacement is performed in interactive mode.
# Non-interactive: uses element-level _merge_arrays_3way to preserve both
# user additions and kit additions without prompting.
# ---------------------------------------------------------------------------
_prompt_array_conflict() {
  local key="$1"
  local s_val="$2"
  local c_val="$3"
  local n_val="$4"

  local arr_sv
  arr_sv="$(jq -n --argjson v "$s_val" 'if $v == null then [] else $v end')" || return 1

  # Check saved preference
  local saved_pref
  saved_pref="$(_get_merge_pref "$key")" || return 1
  if [[ "$saved_pref" == "keep-mine" ]]; then
    _merge_progress_stderr_detail "  [remembered] ${key} ${STR_MERGE_REMEMBERED_KEEP}"
    printf '%s' "$c_val"
    return
  elif [[ "$saved_pref" == "use-kit" ]]; then
    _merge_progress_stderr_detail "  [remembered] ${key} ${STR_MERGE_REMEMBERED_KIT}"
    printf '%s' "$n_val"
    return
  fi

  if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]]; then
    # Non-interactive: element-level merge preserves both user and kit additions
    _merge_progress_stderr_detail "  [merge-array] ${key} (non-interactive)"
    _merge_arrays_3way "$arr_sv" "$c_val" "$n_val" || return 1
    return
  fi

  # Interactive: show summary and prompt
  local c_count n_count
  c_count="$(printf '%s' "$c_val" | jq 'length')" || return 1
  n_count="$(printf '%s' "$n_val" | jq 'length')" || return 1

  local c_preview n_preview
  c_preview="$(printf '%s' "$c_val" | jq -r '.[0:3][] // empty' 2>/dev/null | head -3)"
  n_preview="$(printf '%s' "$n_val" | jq -r '.[0:3][] // empty' 2>/dev/null | head -3)"

  warn "$STR_MERGE_ARRAY_CONFLICT $key"
  printf "  %s (%s %s): %s ...\n" "$STR_MERGE_ARRAY_YOURS" "$c_count" "$STR_MERGE_ARRAY_ENTRIES" "$c_preview" >&2
  printf "  %s (%s %s): %s ...\n" "$STR_MERGE_ARRAY_KITS" "$n_count" "$STR_MERGE_ARRAY_ENTRIES" "$n_preview" >&2
  printf "  %s " "$STR_MERGE_ARRAY_PROMPT" >&2

  while true; do
    local reply
    if read -r reply < /dev/tty 2>/dev/null; then
      true
    else
      reply="k"
    fi

    case "$reply" in
      [Dd]*)
        printf "\n--- %s ---\n" "$STR_MERGE_ARRAY_YOURS" >&2
        printf '%s' "$c_val" | jq -r '.[]' 2>/dev/null >&2
        printf "\n--- %s ---\n" "$STR_MERGE_ARRAY_KITS" >&2
        printf '%s' "$n_val" | jq -r '.[]' 2>/dev/null >&2
        printf "\n  %s " "$STR_MERGE_ARRAY_REPROMPT" >&2
        continue
        ;;
      rk|RK|Rk)
        _save_merge_pref "$key" "keep-mine" || return 1
        printf '%s' "$c_val"
        return
        ;;
      ru|RU|Ru)
        _save_merge_pref "$key" "use-kit" || return 1
        printf '%s' "$n_val"
        return
        ;;
      [Uu]*)
        printf '%s' "$n_val"
        return
        ;;
      *)
        printf '%s' "$c_val"
        return
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# _prompt_scalar_conflict - Resolve a scalar conflict between user and kit
#
# Usage: _prompt_scalar_conflict <key> <current_val> <newkit_val>
# Prints the chosen JSON scalar value to stdout.
#
# Non-interactive: always keeps user's value (safe default)
# Interactive: shows both values, asks [K]eep / [U]se kit's
# ---------------------------------------------------------------------------
_prompt_scalar_conflict() {
  local key="$1"
  local c_val="$2"
  local n_val="$3"

  # Check saved preference first
  local saved_pref
  saved_pref="$(_get_merge_pref "$key")" || return 1
  if [[ "$saved_pref" == "keep-mine" ]]; then
    _merge_progress_stderr_detail "  [remembered] ${key} ${STR_MERGE_REMEMBERED_KEEP}"
    printf '%s' "$c_val"
    return
  elif [[ "$saved_pref" == "use-kit" ]]; then
    _merge_progress_stderr_detail "  [remembered] ${key} ${STR_MERGE_REMEMBERED_KIT}"
    printf '%s' "$n_val"
    return
  fi

  if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]]; then
    # Non-interactive: safe default is to preserve user's value
    printf '%s' "$c_val"
    return
  fi

  # Interactive: show conflict and prompt with remember options
  warn "$STR_MERGE_SCALAR_CONFLICT $key"
  printf "  %s %s\n" "$STR_MERGE_SCALAR_YOUR_VALUE" "$c_val" >&2
  printf "  %s %s\n" "$STR_MERGE_SCALAR_KIT_VALUE" "$n_val" >&2
  printf "  %s " "$STR_MERGE_SCALAR_PROMPT" >&2

  local reply
  if read -r reply < /dev/tty 2>/dev/null; then
    true
  else
    reply="k"
  fi

  case "$reply" in
    rk|RK|Rk)
      _save_merge_pref "$key" "keep-mine" || return 1
      printf '%s' "$c_val"
      ;;
    ru|RU|Ru)
      _save_merge_pref "$key" "use-kit" || return 1
      printf '%s' "$n_val"
      ;;
    [Uu]*)
      printf '%s' "$n_val"
      ;;
    *)
      printf '%s' "$c_val"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _resolve_key_3way - Single-key resolution core for all merge entry points
#
# Usage: _resolve_key_3way <mode> <key_label> <sv> <cv> <nv>
#   mode      — top | nested | bootstrap
#   key_label — key name used for prompts/prefs ("permissions" or "env.KEY")
#   sv/cv/nv  — compact JSON values; "null" = key absent (_json_key_or_null)
#               bootstrap mode has no snapshot: callers pass sv="null"
#
# Sets globals (read by the wrapper after each call):
#   _RK_ACTION — keep   : leave merged untouched (merged starts from current)
#                set    : assign _RK_VALUE to the key
#                delete : remove the key from merged
#                object : both-changed object — caller recurses (top mode)
#   _RK_VALUE  — JSON value for "set"
#   _RK_CLASS  — classification for the wrapper's counters/log details:
#                user-added | kit-add | identical | keep-user | kit-update |
#                kit-remove | conflict-array | conflict-scalar |
#                merge-object | object-kit-wins
#
# Intentional mode differences (see issue #97 behavior matrix):
#   bootstrap — no baseline: current wins by default; object conflicts use a
#               shallow union (current sub-keys win, kit-only sub-keys
#               adopted) without prompting; keys are never deleted
#   top       — both-changed objects recurse via _merge_object_3way
#   nested    — both-changed objects: kit wins (no recursion below depth 2)
# ---------------------------------------------------------------------------
_RK_ACTION=""
_RK_VALUE=""
_RK_CLASS=""

# "null" chosen by a prompt means the winning side does not have the key →
# delete it; assigning would write a literal JSON null into settings.json (#75)
_rk_apply_chosen() {
  local chosen="$1"
  if [[ "$chosen" == "null" ]]; then
    _RK_ACTION="delete"
  else
    _RK_ACTION="set"
    _RK_VALUE="$chosen"
  fi
}

# Bootstrap arm of _resolve_key_3way (no snapshot baseline; sv is ignored)
_resolve_key_bootstrap() {
  local key="$1"
  local cv="$2"
  local nv="$3"

  if [[ "$cv" == "null" && "$nv" != "null" ]]; then
    # Kit-only key → adopt
    _RK_ACTION="set"; _RK_VALUE="$nv"; _RK_CLASS="kit-add"
    return 0
  fi
  if [[ "$nv" == "null" ]]; then
    # User-only key → keep
    _RK_CLASS="user-added"
    return 0
  fi
  if [[ "$cv" == "$nv" ]]; then
    # Same value → keep
    _RK_CLASS="identical"
    return 0
  fi
  _resolve_conflict_by_type "bootstrap" "$key" "null" "$cv" "$nv" "bootstrap" || return 1
}

_resolve_key_3way() {
  local mode="$1"
  local key="$2"
  local sv="$3"
  local cv="$4"
  local nv="$5"
  _RK_ACTION="keep"
  _RK_VALUE=""
  _RK_CLASS=""

  if [[ "$mode" == "bootstrap" ]]; then
    _resolve_key_bootstrap "$key" "$cv" "$nv" || return 1
    return 0
  fi

  # --- top | nested: full 3-way against the snapshot baseline ---
  if [[ "$sv" == "null" && "$nv" == "null" ]]; then
    # User added the key → keep it.
    # nested historically materializes cv (a literal null user value is
    # dropped via _rk_apply_chosen); top leaves merged (== current) as-is.
    _RK_CLASS="user-added"
    if [[ "$mode" == "nested" ]]; then
      _rk_apply_chosen "$cv"
    fi
    return 0
  fi
  if [[ "$sv" == "null" && "$cv" == "null" ]]; then
    # Kit added the key → adopt
    _RK_ACTION="set"; _RK_VALUE="$nv"; _RK_CLASS="kit-add"
    return 0
  fi

  if [[ "$mode" == "top" && "$sv" == "null" ]]; then
    # Key in both current and new_kit but not snapshot: independent additions
    if [[ "$cv" == "$nv" ]]; then
      _RK_CLASS="identical"
      return 0
    fi
    _resolve_conflict_by_type "$mode" "$key" "$sv" "$cv" "$nv" "independent" || return 1
    return 0
  fi

  local s_eq_c s_eq_n
  s_eq_c="$(_json_equal "$sv" "$cv")" || return 1
  s_eq_n="$(_json_equal "$sv" "$nv")" || return 1

  if [[ "$s_eq_c" == "true" ]]; then
    # User didn't change → adopt kit's new value
    if [[ "$nv" == "null" ]]; then
      # Kit removed the key
      _RK_ACTION="delete"; _RK_CLASS="kit-remove"
      return 0
    fi
    _RK_ACTION="set"; _RK_VALUE="$nv"; _RK_CLASS="kit-update"
    return 0
  fi
  if [[ "$s_eq_n" == "true" ]]; then
    # Kit didn't change → keep user's current value.
    # nested historically materializes cv (cv="null" → delete via guard).
    _RK_CLASS="keep-user"
    if [[ "$mode" == "nested" ]]; then
      _rk_apply_chosen "$cv"
    fi
    return 0
  fi

  _resolve_conflict_by_type "$mode" "$key" "$sv" "$cv" "$nv" "both-changed" || return 1
}

# _resolve_conflict_by_type <mode> <key_label> <sv> <cv> <nv> <origin>
#   origin: both-changed | independent | bootstrap (controls warn text and
#   the array-conflict snapshot argument; bootstrap passes an empty array)
_resolve_conflict_by_type() {
  local mode="$1"
  local key="$2"
  local sv="$3"
  local cv="$4"
  local nv="$5"
  local origin="$6"

  # Identical values are never a conflict — short-circuit before any prompt.
  # Reachable when the snapshot lacks the key but current == new-kit (e.g.
  # nested sub-keys under a snapshot-missing object recursed from top mode).
  local values_equal
  values_equal="$(_json_equal "$cv" "$nv")" || return 1
  if [[ "$values_equal" == "true" ]]; then
    _RK_CLASS="identical"
    if [[ "$mode" == "nested" ]]; then
      _rk_apply_chosen "$cv"
    fi
    return 0
  fi

  local cv_type nv_type chosen
  cv_type="$(_json_type "$cv")" || return 1
  nv_type="$(_json_type "$nv")" || return 1

  if [[ "$cv_type" == "array" && "$nv_type" == "array" ]]; then
    local arr_sv="$sv"
    [[ "$origin" == "bootstrap" ]] && arr_sv="[]"
    chosen="$(_prompt_array_conflict "$key" "$arr_sv" "$cv" "$nv")" || return 1
    _RK_CLASS="conflict-array"
    _rk_apply_chosen "$chosen"
    return 0
  fi

  if [[ "$cv_type" == "object" && "$nv_type" == "object" ]]; then
    case "$mode" in
      top)
        # Caller recurses via _merge_object_3way
        _RK_ACTION="object"; _RK_CLASS="merge-object"
        ;;
      bootstrap)
        # Shallow union: current sub-keys win, kit-only sub-keys adopted
        _RK_ACTION="set"
        _RK_VALUE="$(jq -cn --argjson c "$cv" --argjson n "$nv" '
          $c + ($n | to_entries | map(select(.key as $k | $c | has($k) | not)) | from_entries)
        ')" || return 1
        _RK_CLASS="merge-object"
        ;;
      *)
        # nested: kit wins below depth 2 (no further recursion)
        warn "$STR_MERGE_SCALAR_CONFLICT ${key} $STR_MERGE_OBJECT_CONFLICT_KIT_WINS"
        _RK_ACTION="set"; _RK_VALUE="$nv"; _RK_CLASS="object-kit-wins"
        ;;
    esac
    return 0
  fi

  if [[ "$mode" == "top" && "$origin" == "both-changed" ]]; then
    warn "  [conflict] $key — prompting for resolution"
  fi
  chosen="$(_prompt_scalar_conflict "$key" "$cv" "$nv")" || return 1
  _RK_CLASS="conflict-scalar"
  _rk_apply_chosen "$chosen"
}

# ---------------------------------------------------------------------------
# _merge_object_3way - Merge a JSON object one level deep using 3-way logic
#
# Usage: _merge_object_3way <parent_key> <s_val> <c_val> <n_val> <merged_var>
#
# Thin wrapper: iterates sub-keys and applies _resolve_key_3way (mode=nested)
# to each. Writes the updated top-level merged JSON to the variable named
# <merged_var> (passed by name; uses printf -v for Bash 3.2 compatibility).
#
# Rules mirror merge_settings_3way but operate one level deeper:
#   snapshot == current → use newkit sub-value
#   snapshot == newkit  → keep current sub-value
#   user added sub-key  → keep it
#   both changed:
#     arrays   → _prompt_array_conflict (element merge when non-interactive)
#     objects  → replace with newkit (no further recursion at this depth)
#     scalars  → _prompt_scalar_conflict
# ---------------------------------------------------------------------------
_merge_object_3way() {
  local parent_key="$1"
  local s_val="$2"
  local c_val="$3"
  local n_val="$4"
  local merged_var="$5"

  # Collect all sub-keys from all three objects
  local all_keys
  all_keys="$(jq -rn \
    --argjson s "$s_val" \
    --argjson c "$c_val" \
    --argjson n "$n_val" \
    '(($s // {} | keys) + ($c // {} | keys) + ($n // {} | keys)) | unique[]')" || return 1

  # Start with the current state of the parent key in merged
  local obj_merged
  obj_merged="$(printf '%s' "${!merged_var}" | jq --arg k "$parent_key" '.[$k] // {}')" || return 1

  local sub_key
  while IFS= read -r sub_key; do
    [[ -z "$sub_key" ]] && continue

    local sv cv nv
    sv="$(_json_key_or_null "$s_val" "$sub_key")" || return 1
    cv="$(_json_key_or_null "$c_val" "$sub_key")" || return 1
    nv="$(_json_key_or_null "$n_val" "$sub_key")" || return 1

    _resolve_key_3way "nested" "${parent_key}.${sub_key}" "$sv" "$cv" "$nv" || return 1

    case "$_RK_ACTION" in
      keep)
        continue
        ;;
      delete)
        obj_merged="$(jq -n \
          --argjson obj "$obj_merged" \
          --arg k "$sub_key" \
          '$obj | del(.[$k])')" || return 1
        ;;
      *)
        obj_merged="$(jq -n \
          --argjson obj "$obj_merged" \
          --arg k "$sub_key" \
          --argjson v "$_RK_VALUE" \
          '$obj | .[$k] = $v')" || return 1
        ;;
    esac
  done < <(printf '%s\n' "$all_keys")

  # Write updated merged JSON back to the caller's variable
  local new_merged
  new_merged="$(printf '%s' "${!merged_var}" | jq \
    --arg k "$parent_key" \
    --argjson v "$obj_merged" \
    '.[$k] = $v')" || return 1
  printf -v "$merged_var" '%s' "$new_merged"
}

# ---------------------------------------------------------------------------
# merge_settings_3way - Three-way merge for settings.json
#
# Usage: merge_settings_3way <snapshot> <current> <new_kit> <output>
#
#   snapshot  — settings.json at the time of the last install (baseline)
#   current   — settings.json as the user has it now
#   new_kit   — settings.json from the new version of the starter kit
#   output    — where to write the merged result
#
# For each top-level key across all three files:
#   snapshot == current → user didn't change → use new_kit value
#   snapshot == new_kit → kit didn't change  → keep current value
#   key in current only → user added         → keep it
#   key in new_kit only → kit added          → add it
#   both changed:
#     arrays   → _prompt_array_conflict (element merge when non-interactive)
#     objects  → _merge_object_3way
#     scalars  → _prompt_scalar_conflict
#   $schema is always skipped (taken from new_kit unchanged)
#
# Thin wrapper: per-key resolution lives in _resolve_key_3way (mode=top);
# this function handles validation, counters/log details, and applying the
# resolved actions to the merged document.
# ---------------------------------------------------------------------------
merge_settings_3way() {
  local snapshot="$1"
  local current="$2"
  local new_kit="$3"
  local output="$4"

  # Input validation
  local f
  for f in "$snapshot" "$current" "$new_kit"; do
    if [[ ! -f "$f" ]]; then
      error "File not found: $f"
      return 1
    fi
    if ! jq empty "$f" 2>/dev/null; then
      error "Invalid JSON: $f"
      return 1
    fi
  done

  _progress_summary "settings.json" "$STR_MERGE_3WAY_STARTING"
  _merge_progress_detail "  snapshot : $snapshot"
  _merge_progress_detail "  current  : $current"
  _merge_progress_detail "  new_kit  : $new_kit"

  local s_doc c_doc n_doc
  s_doc="$(< "$snapshot")"
  c_doc="$(< "$current")"
  n_doc="$(< "$new_kit")"

  if _merge_mdm_managed; then
    _merge_settings_mdm_documents "$s_doc" "$c_doc" "$n_doc" "$output" || return 1
    ok "MDM authoritative 3-way merge complete: $output"
    return 0
  fi

  # Collect all top-level keys from all three files
  local all_keys
  all_keys="$(jq -rn \
    --argjson s "$s_doc" \
    --argjson c "$c_doc" \
    --argjson n "$n_doc" \
    '(($s | keys) + ($c | keys) + ($n | keys)) | unique[]')" || return 1
  local total_keys=0 current_key=0
  total_keys="$(printf '%s\n' "$all_keys" | sed '/^$/d' | wc -l | tr -d ' ')" || return 1

  # Start merged from current (preserves everything by default)
  local merged
  merged="$c_doc"
  local keep_user_count=0 kit_add_count=0 kit_update_count=0 kit_remove_count=0 merge_object_count=0 conflict_count=0

  local key
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    current_key=$((current_key + 1))
    _merge_progress_tick_if_needed "settings.json merge" "$current_key" "$total_keys"

    # Always take $schema from new_kit unchanged
    if [[ "$key" == "\$schema" ]]; then
      local schema_val
      schema_val="$(jq -rn --argjson n "$n_doc" '$n["$schema"] // empty')" || return 1
      if [[ -n "$schema_val" ]]; then
        merged="$(printf '%s' "$merged" | jq \
          --arg v "$schema_val" \
          '.["$schema"] = $v')" || return 1
      fi
      continue
    fi

    local sv cv nv
    sv="$(_json_key_or_null "$s_doc" "$key")" || return 1
    cv="$(_json_key_or_null "$c_doc" "$key")" || return 1
    nv="$(_json_key_or_null "$n_doc" "$key")" || return 1

    _resolve_key_3way "top" "$key" "$sv" "$cv" "$nv" || return 1

    case "$_RK_CLASS" in
      user-added)
        keep_user_count=$((keep_user_count + 1))
        _merge_progress_detail "  [keep-user] $key (user-added)"
        ;;
      keep-user)
        keep_user_count=$((keep_user_count + 1))
        _merge_progress_detail "  [keep-user] $key"
        ;;
      kit-add)
        kit_add_count=$((kit_add_count + 1))
        _merge_progress_detail "  [kit-add]   $key"
        ;;
      kit-update)
        kit_update_count=$((kit_update_count + 1))
        _merge_progress_detail "  [kit-update] $key"
        ;;
      kit-remove)
        kit_remove_count=$((kit_remove_count + 1))
        _merge_progress_detail "  [kit-remove] $key"
        ;;
      merge-object)
        merge_object_count=$((merge_object_count + 1))
        _merge_progress_detail "  [merge-object] $key"
        ;;
      conflict-array|conflict-scalar)
        conflict_count=$((conflict_count + 1))
        ;;
    esac

    case "$_RK_ACTION" in
      keep)
        continue
        ;;
      delete)
        merged="$(printf '%s' "$merged" | jq --arg k "$key" 'del(.[$k])')" || return 1
        ;;
      object)
        local obj_sv
        obj_sv="$(jq -cn --argjson v "$sv" 'if $v == null then {} else $v end')" || return 1
        _merge_object_3way "$key" "$obj_sv" "$cv" "$nv" merged || return 1
        ;;
      *)
        merged="$(printf '%s' "$merged" | jq \
          --arg k "$key" \
          --argjson v "$_RK_VALUE" \
          '.[$k] = $v')" || return 1
        ;;
    esac
  done < <(printf '%s\n' "$all_keys")

  # Write output
  local tmp_out
  tmp_out="$(mktemp)" || return 1
  printf '%s\n' "$merged" > "$tmp_out" || return 1

  if ! jq empty "$tmp_out" 2>/dev/null; then
    error "Merge produced invalid JSON — aborting"
    rm -f "$tmp_out"
    return 1
  fi

  mv "$tmp_out" "$output" || return 1
  _progress_summary \
    "settings.json merge summary" \
    "keep-user=${keep_user_count}, kit-add=${kit_add_count}, kit-update=${kit_update_count}, kit-remove=${kit_remove_count}, merge-object=${merge_object_count}, conflicts=${conflict_count}"
  ok "3-way merge complete: $output"
}

# ---------------------------------------------------------------------------
# _merge_settings_bootstrap - Merge settings.json when no real snapshot exists
#
# Usage: _merge_settings_bootstrap <current> <new_kit> <output>
#
# Strategy: current is the base (user's customizations are preserved).
# Kit-only keys are adopted. Value conflicts are prompted (interactive)
# or resolved in favor of current (non-interactive).
# Objects are recursed one level to adopt new sub-keys.
#
# Thin wrapper: per-key resolution lives in _resolve_key_3way
# (mode=bootstrap); $schema is left untouched in this path.
# ---------------------------------------------------------------------------
_merge_settings_bootstrap() {
  local current="$1"
  local new_kit="$2"
  local output="$3"

  local f
  for f in "$current" "$new_kit"; do
    [[ -f "$f" ]] || { error "File not found: $f"; return 1; }
    jq empty "$f" 2>/dev/null || { error "Invalid JSON: $f"; return 1; }
  done

  local c_doc n_doc
  c_doc="$(< "$current")"
  n_doc="$(< "$new_kit")"

  local merged
  merged="$c_doc"

  if _merge_mdm_managed; then
    _merge_settings_mdm_documents '{}' "$c_doc" "$n_doc" "$output" || return 1
    ok "MDM authoritative bootstrap merge complete: $output"
    return 0
  fi

  # Collect all keys from both files
  local all_keys
  all_keys="$(jq -rn \
    --argjson c "$c_doc" \
    --argjson n "$n_doc" \
    '(($c | keys) + ($n | keys)) | unique[]')" || return 1
  local total_keys=0 current_key=0
  total_keys="$(printf '%s\n' "$all_keys" | sed '/^$/d' | wc -l | tr -d ' ')" || return 1

  local key
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    current_key=$((current_key + 1))
    _merge_progress_tick_if_needed "bootstrap merge" "$current_key" "$total_keys"
    [[ "$key" == "\$schema" ]] && continue

    local cv nv
    cv="$(_json_key_or_null "$c_doc" "$key")" || return 1
    nv="$(_json_key_or_null "$n_doc" "$key")" || return 1

    _resolve_key_3way "bootstrap" "$key" "null" "$cv" "$nv" || return 1

    if [[ "$_RK_CLASS" == "kit-add" ]]; then
      _merge_progress_detail "  [kit-add] $key"
    fi

    case "$_RK_ACTION" in
      keep)
        continue
        ;;
      delete)
        merged="$(printf '%s' "$merged" | jq --arg k "$key" 'del(.[$k])')" || return 1
        ;;
      *)
        merged="$(printf '%s' "$merged" | jq \
          --arg k "$key" --argjson v "$_RK_VALUE" '.[$k] = $v')" || return 1
        ;;
    esac

    if [[ "$_RK_CLASS" == "merge-object" ]]; then
      _merge_progress_detail "  [merge-object] $key"
    fi
  done < <(printf '%s\n' "$all_keys")

  local tmp_out
  tmp_out="$(mktemp)" || return 1
  printf '%s\n' "$merged" > "$tmp_out" || return 1

  if ! jq empty "$tmp_out" 2>/dev/null; then
    error "Bootstrap merge produced invalid JSON — aborting"
    rm -f "$tmp_out"
    return 1
  fi

  mv "$tmp_out" "$output" || return 1
}
