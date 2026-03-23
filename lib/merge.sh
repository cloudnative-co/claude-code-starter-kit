#!/bin/bash
# lib/merge.sh - Three-way merge for settings.json during kit upgrades
#
# Provides a 3-way merge strategy that preserves user customizations while
# integrating upstream changes from the starter kit.
#
# Requires: jq, lib/colors.sh to be sourced first
# Compatible: Bash 3.2+ (macOS default) — no associative arrays, no mapfile
set -euo pipefail

# ---------------------------------------------------------------------------
# Merge preference persistence ("remember my answer")
#
# Stores user decisions in ~/.claude/.starter-kit-merge-prefs.json so
# recurring conflicts are resolved automatically.
# ---------------------------------------------------------------------------
_MERGE_PREFS_FILE="${HOME}/.claude/.starter-kit-merge-prefs.json"
_MERGE_PREFS_LOADED=false
_MERGE_PREFS="{}"

_load_merge_prefs() {
  if [[ "$_MERGE_PREFS_LOADED" == "true" ]]; then
    return
  fi
  if [[ "${_RESET_MERGE_PREFS:-false}" == "true" ]]; then
    _MERGE_PREFS="{}"
    rm -f "$_MERGE_PREFS_FILE"
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
  _load_merge_prefs
  local val
  val="$(printf '%s' "$_MERGE_PREFS" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null || true)"
  printf '%s' "$val"
}

# _save_merge_pref <key> <value>  (value: "keep-mine" or "use-kit")
_save_merge_pref() {
  local key="$1"
  local value="$2"
  _load_merge_prefs
  _MERGE_PREFS="$(printf '%s' "$_MERGE_PREFS" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')"
  printf '%s\n' "$_MERGE_PREFS" > "$_MERGE_PREFS_FILE"
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
    '[$c[] | select(. as $item | $s | map(. == $item) | any | not)]')"

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
    ]')"

  # Base result: newkit array (authoritative — already includes kit_added items)
  # plus user additions (items the user added that the kit never had)
  local merged
  merged="$(jq -n \
    --argjson n "$n_val" \
    --argjson ua "$user_added" \
    '$n + $ua | unique')"

  # Handle kit-removed items that still exist in current
  local removed_count
  removed_count="$(printf '%s' "$kit_removed" | jq 'length')"

  if [[ "$removed_count" -gt 0 ]]; then
    if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]]; then
      # Non-interactive: safe default is to keep user's values
      merged="$(jq -n \
        --argjson m "$merged" \
        --argjson kr "$kit_removed" \
        '$m + $kr | unique')"
    else
      # Interactive: ask for each removed item
      local i=0
      while [[ "$i" -lt "$removed_count" ]]; do
        local item
        item="$(printf '%s' "$kit_removed" | jq ".[$i]")"
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
              '$m + [$item] | unique')"
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
  arr_sv="$(jq -n --argjson v "$s_val" 'if $v == null then [] else $v end')"

  # Check saved preference
  local saved_pref
  saved_pref="$(_get_merge_pref "$key")"
  if [[ "$saved_pref" == "keep-mine" ]]; then
    printf '  [remembered] %s %s\n' "$key" "$STR_MERGE_REMEMBERED_KEEP" >&2
    printf '%s' "$c_val"
    return
  elif [[ "$saved_pref" == "use-kit" ]]; then
    printf '  [remembered] %s %s\n' "$key" "$STR_MERGE_REMEMBERED_KIT" >&2
    printf '%s' "$n_val"
    return
  fi

  if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]]; then
    # Non-interactive: element-level merge preserves both user and kit additions
    printf '  [merge-array] %s (non-interactive)\n' "$key" >&2
    _merge_arrays_3way "$arr_sv" "$c_val" "$n_val"
    return
  fi

  # Interactive: show summary and prompt
  local c_count n_count
  c_count="$(printf '%s' "$c_val" | jq 'length')"
  n_count="$(printf '%s' "$n_val" | jq 'length')"

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
        _save_merge_pref "$key" "keep-mine"
        printf '%s' "$c_val"
        return
        ;;
      ru|RU|Ru)
        _save_merge_pref "$key" "use-kit"
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
  saved_pref="$(_get_merge_pref "$key")"
  if [[ "$saved_pref" == "keep-mine" ]]; then
    printf '  [remembered] %s %s\n' "$key" "$STR_MERGE_REMEMBERED_KEEP" >&2
    printf '%s' "$c_val"
    return
  elif [[ "$saved_pref" == "use-kit" ]]; then
    printf '  [remembered] %s %s\n' "$key" "$STR_MERGE_REMEMBERED_KIT" >&2
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
      _save_merge_pref "$key" "keep-mine"
      printf '%s' "$c_val"
      ;;
    ru|RU|Ru)
      _save_merge_pref "$key" "use-kit"
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
# _merge_object_3way - Merge a JSON object one level deep using 3-way logic
#
# Usage: _merge_object_3way <parent_key> <s_val> <c_val> <n_val> <merged_var>
#
# Applies 3-way logic to sub-keys within a parent object.
# Handles nested arrays via _merge_arrays_3way.
# Writes the updated top-level merged JSON to the variable named <merged_var>
# (passed by name; uses printf -v for Bash 3.2 compatibility).
#
# Rules mirror merge_settings_3way but operate one level deeper:
#   snapshot == current → use newkit sub-value
#   snapshot == newkit  → keep current sub-value
#   user added sub-key  → keep it
#   both changed:
#     arrays   → _merge_arrays_3way
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
    '(($s // {} | keys) + ($c // {} | keys) + ($n // {} | keys)) | unique[]')"

  # Start with the current state of the parent key in merged
  local obj_merged
  obj_merged="$(printf '%s' "${!merged_var}" | jq --arg k "$parent_key" '.[$k] // {}')"

  local sub_key
  while IFS= read -r sub_key; do
    [[ -z "$sub_key" ]] && continue

    local sv cv nv
    sv="$(jq -n --argjson o "$s_val" --arg k "$sub_key" '$o[$k] // empty' 2>/dev/null || printf 'null')"
    cv="$(jq -n --argjson o "$c_val" --arg k "$sub_key" '$o[$k] // empty' 2>/dev/null || printf 'null')"
    nv="$(jq -n --argjson o "$n_val" --arg k "$sub_key" '$o[$k] // empty' 2>/dev/null || printf 'null')"

    # Normalize missing values to null
    [[ -z "$sv" ]] && sv="null"
    [[ -z "$cv" ]] && cv="null"
    [[ -z "$nv" ]] && nv="null"

    local s_eq_c s_eq_n
    s_eq_c="$(jq -n --argjson a "$sv" --argjson b "$cv" '$a == $b' 2>/dev/null || printf 'false')"
    s_eq_n="$(jq -n --argjson a "$sv" --argjson b "$nv" '$a == $b' 2>/dev/null || printf 'false')"

    local chosen

    if [[ "$sv" == "null" && "$nv" == "null" ]]; then
      # User added sub-key: keep it
      chosen="$cv"
    elif [[ "$sv" == "null" && "$cv" == "null" ]]; then
      # Kit added sub-key: use it
      chosen="$nv"
    elif [[ "$s_eq_c" == "true" ]]; then
      # User didn't change → use newkit value
      if [[ "$nv" == "null" ]]; then
        # Kit removed sub-key → delete it
        obj_merged="$(jq -n \
          --argjson obj "$obj_merged" \
          --arg k "$sub_key" \
          '$obj | del(.[$k])')"
        continue
      fi
      chosen="$nv"
    elif [[ "$s_eq_n" == "true" ]]; then
      # Kit didn't change → keep current value
      chosen="$cv"
    else
      # Both changed: type-specific handling
      local cv_type nv_type
      cv_type="$(jq -n --argjson v "$cv" '$v | type')"
      nv_type="$(jq -n --argjson v "$nv" '$v | type')"

      if [[ "$cv_type" == '"array"' && "$nv_type" == '"array"' ]]; then
        chosen="$(_prompt_array_conflict "${parent_key}.${sub_key}" "$sv" "$cv" "$nv")"
      elif [[ "$cv_type" == '"object"' && "$nv_type" == '"object"' ]]; then
        # Shallow conflict at object level: kit wins (no deeper recursion)
        warn "$STR_MERGE_SCALAR_CONFLICT ${parent_key}.${sub_key} $STR_MERGE_OBJECT_CONFLICT_KIT_WINS"
        chosen="$nv"
      else
        chosen="$(_prompt_scalar_conflict "${parent_key}.${sub_key}" "$cv" "$nv")"
      fi
    fi

    obj_merged="$(jq -n \
      --argjson obj "$obj_merged" \
      --arg k "$sub_key" \
      --argjson v "$chosen" \
      '$obj | .[$k] = $v')"
  done <<EOF
$all_keys
EOF

  # Write updated merged JSON back to the caller's variable
  local new_merged
  new_merged="$(printf '%s' "${!merged_var}" | jq \
    --arg k "$parent_key" \
    --argjson v "$obj_merged" \
    '.[$k] = $v')"
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
#     arrays   → _merge_arrays_3way
#     objects  → _merge_object_3way
#     scalars  → _prompt_scalar_conflict
#   $schema is always skipped (taken from new_kit unchanged)
# ---------------------------------------------------------------------------
merge_settings_3way() {
  local snapshot="$1"
  local current="$2"
  local new_kit="$3"
  local output="$4"

  # Input validation
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

  info "$STR_MERGE_3WAY_STARTING"
  info "  snapshot : $snapshot"
  info "  current  : $current"
  info "  new_kit  : $new_kit"

  # Collect all top-level keys from all three files
  local all_keys
  all_keys="$(jq -rn \
    --slurpfile s "$snapshot" \
    --slurpfile c "$current" \
    --slurpfile n "$new_kit" \
    '(($s[0] | keys) + ($c[0] | keys) + ($n[0] | keys)) | unique[]')"

  # Start merged from current (preserves everything by default)
  local merged
  merged="$(< "$current")"

  local key
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue

    # Always take $schema from new_kit unchanged
    if [[ "$key" == "\$schema" ]]; then
      local schema_val
      schema_val="$(jq -r '.["$schema"] // empty' "$new_kit")"
      if [[ -n "$schema_val" ]]; then
        merged="$(printf '%s' "$merged" | jq \
          --arg v "$schema_val" \
          '.["$schema"] = $v')"
      fi
      continue
    fi

    local sv cv nv
    sv="$(jq -c --arg k "$key" '.[$k] // empty' "$snapshot" 2>/dev/null || printf '')"
    cv="$(jq -c --arg k "$key" '.[$k] // empty' "$current"  2>/dev/null || printf '')"
    nv="$(jq -c --arg k "$key" '.[$k] // empty' "$new_kit"  2>/dev/null || printf '')"

    # Normalize missing values to null sentinel
    [[ -z "$sv" ]] && sv="null"
    [[ -z "$cv" ]] && cv="null"
    [[ -z "$nv" ]] && nv="null"

    local s_eq_c s_eq_n
    s_eq_c="$(jq -n --argjson a "$sv" --argjson b "$cv" '$a == $b' 2>/dev/null || printf 'false')"
    s_eq_n="$(jq -n --argjson a "$sv" --argjson b "$nv" '$a == $b' 2>/dev/null || printf 'false')"

    local chosen

    if [[ "$sv" == "null" && "$nv" == "null" ]]; then
      # Key exists only in current: user added → keep it
      info "  [keep-user] $key (user-added)"
      continue

    elif [[ "$sv" == "null" && "$cv" == "null" ]]; then
      # Key exists only in new_kit: kit added → adopt it
      info "  [kit-add]   $key"
      chosen="$nv"

    elif [[ "$sv" == "null" ]]; then
      # Key in both current and new_kit but not snapshot
      # Treat as independent additions; new_kit wins (conservative)
      if [[ "$cv" == "$nv" ]]; then
        continue  # identical, no change needed
      fi
      # Both independently added with different values: prompt
      chosen="$(_prompt_scalar_conflict "$key" "$cv" "$nv")"

    elif [[ "$s_eq_c" == "true" ]]; then
      # User didn't touch it → adopt kit's new value
      if [[ "$nv" == "null" ]]; then
        # Kit removed the key
        info "  [kit-remove] $key"
        merged="$(printf '%s' "$merged" | jq --arg k "$key" 'del(.[$k])')"
        continue
      fi
      info "  [kit-update] $key"
      chosen="$nv"

    elif [[ "$s_eq_n" == "true" ]]; then
      # Kit didn't change it → keep user's current value
      info "  [keep-user] $key"
      continue

    else
      # Both user and kit changed the key: type-specific conflict resolution
      local cv_type nv_type
      cv_type="$(jq -n --argjson v "$cv" '$v | type')"
      nv_type="$(jq -n --argjson v "$nv" '$v | type')"

      if [[ "$cv_type" == '"array"' && "$nv_type" == '"array"' ]]; then
        chosen="$(_prompt_array_conflict "$key" "$sv" "$cv" "$nv")"

      elif [[ "$cv_type" == '"object"' && "$nv_type" == '"object"' ]]; then
        info "  [merge-object] $key"
        local obj_sv
        obj_sv="$(jq -n --argjson v "$sv" 'if $v == null then {} else $v end')"
        _merge_object_3way "$key" "$obj_sv" "$cv" "$nv" merged
        continue

      else
        warn "  [conflict] $key — prompting for resolution"
        chosen="$(_prompt_scalar_conflict "$key" "$cv" "$nv")"
      fi
    fi

    # Apply the chosen value into merged
    merged="$(printf '%s' "$merged" | jq \
      --arg k "$key" \
      --argjson v "$chosen" \
      '.[$k] = $v')"
  done <<EOF
$all_keys
EOF

  # Write output
  local tmp_out
  tmp_out="$(mktemp)"
  printf '%s\n' "$merged" > "$tmp_out"

  if ! jq empty "$tmp_out" 2>/dev/null; then
    error "Merge produced invalid JSON — aborting"
    rm -f "$tmp_out"
    return 1
  fi

  mv "$tmp_out" "$output"
  ok "3-way merge complete: $output"
}
