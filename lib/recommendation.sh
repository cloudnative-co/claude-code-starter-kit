#!/bin/bash
# lib/recommendation.sh - Feature recommendation helpers
#
# Provides dismissed-feature management, validation, and pending feature
# detection for the feature recommendation system.
#
# IMPORTANT: This file MUST be sourced AFTER wizard/wizard.sh (needs DISMISSED_FEATURES global)
# and AFTER lib/features.sh (needs _FEATURE_FLAGS).
#
# Requires: wizard/wizard.sh (DISMISSED_FEATURES, PROFILE, ENABLE_* globals, save_config)
#           lib/features.sh (_FEATURE_FLAGS)
# Exports: _is_feature_dismissed, _add_dismissed_feature, _validate_dismissed_features,
#          _detect_and_write_pending_features
set -euo pipefail

# ---------------------------------------------------------------------------
# Validate DISMISSED_FEATURES value: must contain only [a-z0-9,-]
# Clears the variable if invalid characters are found.
# ---------------------------------------------------------------------------
_validate_dismissed_features() {
  if [[ -n "${DISMISSED_FEATURES:-}" ]] && [[ ! "$DISMISSED_FEATURES" =~ ^[a-z0-9,-]+$ ]]; then
    DISMISSED_FEATURES=""
  fi
}

# ---------------------------------------------------------------------------
# Check if a feature name is in the DISMISSED_FEATURES CSV
# Usage: _is_feature_dismissed "feature-name"
# Returns: 0 if dismissed, 1 otherwise
# ---------------------------------------------------------------------------
_is_feature_dismissed() {
  [[ ",${DISMISSED_FEATURES:-}," == *",$1,"* ]]
}

# ---------------------------------------------------------------------------
# Add a feature name to the DISMISSED_FEATURES CSV (with dedup)
# Usage: _add_dismissed_feature "feature-name"
# ---------------------------------------------------------------------------
_add_dismissed_feature() {
  _is_feature_dismissed "$1" && return 0
  if [[ -z "${DISMISSED_FEATURES:-}" ]]; then
    DISMISSED_FEATURES="$1"
  else
    DISMISSED_FEATURES="${DISMISSED_FEATURES},$1"
  fi
}

# ---------------------------------------------------------------------------
# Replace only the feature portion of the shared pending-notification file.
#
# The plugin adoption flow owns the sibling "plugins" key, so feature cleanup
# must not unlink or overwrite the whole document while plugins are pending.
# Existing documents are accepted only when they are regular, non-symlink JSON
# objects with well-formed recommendation arrays. Invalid or special files are
# left byte-for-byte untouched (fail closed).
#
# Usage: _write_pending_features <pending-file> <features-json> <kit-version>
#        Pass [] to remove the features key.
# ---------------------------------------------------------------------------
_write_pending_features() {
  local pending_file="$1" features_json="$2" kit_version="$3"
  local pending_dir base='{}' tmp_pending=""

  # Reject an invalid value produced by the caller before touching the file.
  jq -e 'type == "array" and all(.[]; type == "string")' \
    >/dev/null 2>&1 <<< "$features_json" || return 1

  if [[ -e "$pending_file" || -L "$pending_file" ]]; then
    # Do not follow symlinks or read from devices/FIFOs. Besides being unsafe,
    # either would make an invalid notification capable of destroying itself.
    [[ -f "$pending_file" && ! -L "$pending_file" ]] || return 1
    if ! base="$(jq -ce '
      select(
        type == "object"
        and ((has("features") | not)
          or (.features | type == "array" and all(.[]; type == "string")))
        and ((has("plugins") | not)
          or (.plugins | type == "array" and all(.[]; type == "string")))
      )
    ' "$pending_file" 2>/dev/null)"; then
      return 1
    fi
  fi

  # With no feature recommendations, retain the shared file only while a
  # plugin recommendation remains. Metadata follows the surviving payload.
  if [[ "$features_json" == "[]" ]]; then
    [[ -e "$pending_file" ]] || return 0
    if [[ "$(jq -r '(.plugins // []) | length' <<< "$base")" == "0" ]]; then
      rm -f -- "$pending_file"
      return 0
    fi
  fi

  pending_dir="${pending_file%/*}"
  tmp_pending="$(mktemp "$pending_dir/.starter-kit-pending-features.json.tmp.XXXXXX")" \
    || return 1
  if ! chmod 600 "$tmp_pending"; then
    rm -f -- "$tmp_pending"
    return 1
  fi

  if [[ "$features_json" == "[]" ]]; then
    if ! jq -n --argjson base "$base" '$base | del(.features)' > "$tmp_pending"; then
      rm -f -- "$tmp_pending"
      return 1
    fi
  elif ! jq -n --argjson base "$base" --argjson features "$features_json" \
    --arg kit_version "$kit_version" \
    '$base
      | if has("version") then . else .version = 1 end
      | if has("kit_version") then . else .kit_version = $kit_version end
      | .features = $features' \
    > "$tmp_pending"; then
    rm -f -- "$tmp_pending"
    return 1
  fi

  if ! mv -- "$tmp_pending" "$pending_file"; then
    rm -f -- "$tmp_pending"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Detect new features and write pending-features.json for SessionStart notification.
#
# Called from setup.sh after run_update(), outside the update function with || true
# so detection failures never abort the update.
#
# Usage: _detect_and_write_pending_features <claude_dir>
# Requires: _FEATURE_FLAGS (lib/features.sh), PROFILE, DISMISSED_FEATURES, ENABLE_* globals
# ---------------------------------------------------------------------------
_detect_and_write_pending_features() {
  local claude_dir="$1"
  local pending_file="$claude_dir/.starter-kit-pending-features.json"

  # Full profile: all features auto-enabled, no pending needed
  if [[ "${PROFILE:-}" == "full" ]]; then
    _write_pending_features "$pending_file" '[]' "" || return 1
    return 0
  fi

  # The shared SessionStart reader may still be deployed for plugin adoption,
  # but this flag controls generation of feature recommendations themselves.
  # Clear only the feature payload; _write_pending_features preserves plugins.
  if [[ "${ENABLE_FEATURE_RECOMMENDATION:-true}" != "true" ]]; then
    _write_pending_features "$pending_file" '[]' "" || return 1
    return 0
  fi

  # Load profile defaults (if profile conf exists)
  local profile_conf="$PROJECT_DIR/profiles/${PROFILE:-standard}.conf"
  local _is_custom_profile=false
  if [[ ! -f "$profile_conf" ]]; then
    _is_custom_profile=true
  fi

  # Collect pending features (use _FEATURE_ORDER for deterministic output)
  local pending_names=()
  local feat flag_var flag_val
  for feat in "${_FEATURE_ORDER[@]}"; do
    # Skip ENABLE_FEATURE_RECOMMENDATION itself (self-referential)
    [[ "$feat" == "feature-recommendation" ]] && continue

    flag_var="${_FEATURE_FLAGS[$feat]}"

    # Already enabled (conf has non-empty value)
    flag_val="${!flag_var:-}"
    [[ -n "$flag_val" ]] && continue

    # Already dismissed
    _is_feature_dismissed "$feat" && continue

    # For non-custom profiles, check if feature is a profile default
    if [[ "$_is_custom_profile" == "false" ]]; then
      local profile_val=""
      profile_val="$(grep "^${flag_var}=" "$profile_conf" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' || true)"
      if [[ "$profile_val" == "true" ]]; then
        # Profile default: auto-enabled by existing update logic, not pending
        continue
      fi
    fi

    # This feature is pending
    pending_names+=("$feat")
  done

  # Write or clean up pending file
  if [[ ${#pending_names[@]} -eq 0 ]]; then
    _write_pending_features "$pending_file" '[]' "" || return 1
    return 0
  fi

  # Build JSON array of feature names
  local features_json
  features_json="$(printf '%s\n' "${pending_names[@]}" | jq -R . | jq -s .)"

  # Get kit version (best-effort from git tag)
  local kit_version=""
  kit_version="$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null || printf 'unknown')"

  _write_pending_features "$pending_file" "$features_json" "$kit_version"
}
