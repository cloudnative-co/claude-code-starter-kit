#!/bin/bash
# lib/plugin-adoption.sh - Adopt newly catalogued plugins on update
#
# An update restores SELECTED_PLUGINS verbatim from the manifest and never
# recomputes it (wizard/wizard.sh:_restore_config_from_manifest, and
# wizard/steps.sh only recomputes when the CSV is empty). That is deliberate —
# it preserves an explicit user choice — but it also means a plugin added to
# config/plugins.json after someone installed never reaches them.
#
# This module closes that gap without overriding explicit choices. It compares
# the profile's current default plugin set against KNOWN_PLUGINS (what the user
# was last asked about) and offers only the genuine newcomers.
#
# Two rules keep it honest:
#
#   1. KNOWN_PLUGINS only advances when the user could actually answer. The
#      auto-update hook runs `setup.sh --update --non-interactive`, and
#      ENABLE_AUTO_UPDATE defaults to true on standard/full — advancing there
#      would consume the offer in the background and the interactive update
#      would then find nothing to ask about.
#   2. Nothing is installed without consent. Non-interactive runs only write
#      the SessionStart notification.
#
# State lives in ~/.claude-starter-kit.conf, never the manifest: MDM validates
# the manifest by exact key set AND byte-exact canonical JSON AND SHA256, so a
# new manifest key fails MDM installs outright. save_config is called only
# under `if ! _deploy_mdm_managed` (setup.sh), so conf-based state is invisible
# to MDM by construction.
#
# Requires: wizard/registry.sh (_load_plugins, _init_plugins_for_profile,
#                               _plugin_has_collision, PLUGIN_* arrays)
#           wizard/wizard.sh   (KNOWN_PLUGINS, DISMISSED_PLUGINS,
#                               SELECTED_PLUGINS, PROFILE, _MERGE_INTERACTIVE)
#           lib/features.sh    (_feature_deploy_enabled)
# Exports: _validate_plugin_csv, _plugin_csv_has, _plugin_csv_add,
#          _profile_default_plugins, _compute_new_plugins,
#          _write_pending_plugins, _detect_and_offer_new_plugins
set -euo pipefail

# ---------------------------------------------------------------------------
# Validate a plugin-name CSV. Plugin entries may carry an "@marketplace"
# suffix, so this accepts more than _validate_dismissed_features' [a-z0-9,-]:
# "@" and "." are legal in marketplace names. Anything else means the value was
# hand-edited or corrupted — clear it rather than act on it.
#
# Usage: _validate_plugin_csv <varname>
# ---------------------------------------------------------------------------
_validate_plugin_csv() {
  local _var="$1" _val
  _val="${!_var:-}"
  [[ -n "$_val" ]] || return 0
  if [[ ! "$_val" =~ ^[a-zA-Z0-9,@._-]+$ ]]; then
    printf -v "$_var" '%s' ""
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Whole-element membership test against a plugin CSV.
# Usage: _plugin_csv_has <csv> <entry>
# ---------------------------------------------------------------------------
_plugin_csv_has() {
  [[ ",${1:-}," == *",${2},"* ]]
}

# ---------------------------------------------------------------------------
# Append an entry to a plugin CSV variable, with dedup.
# Usage: _plugin_csv_add <varname> <entry>
# ---------------------------------------------------------------------------
_plugin_csv_add() {
  local _var="$1" _entry="$2" _cur
  _cur="${!_var:-}"
  _plugin_csv_has "$_cur" "$_entry" && return 0
  if [[ -z "$_cur" ]]; then
    printf -v "$_var" '%s' "$_entry"
  else
    printf -v "$_var" '%s' "${_cur},${_entry}"
  fi
  return 0
}

# Union two plugin CSVs without losing entries learned under another profile.
# Official bare and fully-qualified spellings compare as the same identity, but
# the spelling already persisted on the left is retained.
_plugin_csv_union() {
  local left="${1:-}" right="${2:-}" csv entry canon
  local out=() seen="" entries=()
  for csv in "$left" "$right"; do
    [[ -n "$csv" ]] || continue
    entries=()
    IFS=',' read -r -a entries < <(printf '%s\n' "$csv")
    for entry in "${entries[@]+"${entries[@]}"}"; do
      [[ -n "$entry" ]] || continue
      canon="$(_canonical_plugin_entry "$entry")"
      _plugin_csv_has "$seen" "$canon" && continue
      seen="${seen:+${seen},}${canon}"
      out+=("$entry")
    done
  done
  [[ "${#out[@]}" -eq 0 ]] && return 0
  local IFS=,
  printf '%s' "${out[*]}"
}

# ---------------------------------------------------------------------------
# Qualify a plugin index the same way _compute_selected_plugins does, so the
# sets being compared use identical spelling: bare name unless the name
# collides across marketplaces or the marketplace is not the official one.
#
# Usage: _qualified_plugin_entry <index>
# ---------------------------------------------------------------------------
_qualified_plugin_entry() {
  local i="$1"
  if _plugin_has_collision "${PLUGIN_NAMES[$i]}" \
     || [[ "${PLUGIN_MARKETPLACES[$i]}" != "claude-plugins-official" ]]; then
    printf '%s@%s' "${PLUGIN_NAMES[$i]}" "${PLUGIN_MARKETPLACES[$i]}"
  else
    printf '%s' "${PLUGIN_NAMES[$i]}"
  fi
}

# ---------------------------------------------------------------------------
# The profile's current default plugin set, as a CSV of qualified entries.
#
# The set — not the whole catalog — is the unit of comparison, so a plugin
# that gains a profile in config/plugins.json is detected as new for that
# profile even though its name was already catalogued.
#
# Update runs never loaded the plugin arrays (the wizard returns early), so
# this loads them itself.
#
# Usage: _profile_default_plugins <profile>  -> prints CSV
# ---------------------------------------------------------------------------
_profile_default_plugins() {
  local profile="$1"
  local out=() i
  _load_plugins || return 1
  _init_plugins_for_profile "$profile" || return 1
  for i in "${!PLUGIN_NAMES[@]}"; do
    [[ "${PLUGIN_SELECTED[$i]}" == "true" ]] || continue
    out+=("$(_qualified_plugin_entry "$i")")
  done
  [[ "${#out[@]}" -eq 0 ]] && return 0
  local IFS=,
  printf '%s' "${out[*]}"
}

# ---------------------------------------------------------------------------
# Canonical spelling for comparing plugin entries. A bare name and
# "name@claude-plugins-official" are the same plugin, so both collapse to the
# bare name; non-official entries keep their "@marketplace" suffix.
#
# This is what lets a legacy bare-official entry stored in SELECTED/KNOWN/
# DISMISSED still match a default that became "name@claude-plugins-official"
# once the name started colliding across marketplaces (and vice-versa) — the
# spellings differ but the plugin is the same, so it must not be re-offered.
# It is pure string work: no PLUGIN_* arrays, so it is safe inside the
# command-substitution call sites that never populate them.
#
# Usage: _canonical_plugin_entry <entry> -> prints canonical entry
# ---------------------------------------------------------------------------
_canonical_plugin_entry() {
  local entry="$1"
  case "$entry" in
    *@claude-plugins-official) printf '%s' "${entry%@claude-plugins-official}" ;;
    *) printf '%s' "$entry" ;;
  esac
}

# ---------------------------------------------------------------------------
# Canonicalize every element of a plugin CSV. Usage: _canonical_plugin_csv <csv>
# ---------------------------------------------------------------------------
_canonical_plugin_csv() {
  local csv="${1:-}" out=() e parts=()
  [[ -n "$csv" ]] || return 0
  # read -a, not an unquoted array assignment: the latter also globs, and this
  # is the one call site fed a value the kit never validates (SELECTED_PLUGINS
  # comes back from the manifest / a hand-editable conf unsanitized), so a "*"
  # in it would expand against the working directory instead of comparing.
  IFS=',' read -r -a parts < <(printf '%s\n' "$csv")
  for e in "${parts[@]+"${parts[@]}"}"; do
    [[ -n "$e" ]] || continue
    out+=("$(_canonical_plugin_entry "$e")")
  done
  [[ "${#out[@]}" -eq 0 ]] && return 0
  local IFS=,
  printf '%s' "${out[*]}"
}

# ---------------------------------------------------------------------------
# Newcomers: profile defaults minus what is already selected, already declined,
# or already known.
#
# Comparison is done on canonical spellings so a stored bare-official entry and
# a now-qualified default (or the reverse) are recognized as the same plugin.
#
# When KNOWN_PLUGINS is unset the install predates this mechanism. That is the
# one-time catch-up: every profile default the user does not already have is
# offered once, which is the only way a plugin catalogued before the mechanism
# existed can still reach them. Their answer is recorded, so it is asked once
# and not again.
#
# Usage: _compute_new_plugins <profile-defaults-csv> -> prints CSV
# ---------------------------------------------------------------------------
_compute_new_plugins() {
  local defaults="$1"
  local out=() entry canon
  [[ -n "$defaults" ]] || return 0
  local _sel _dis _kno entries=()
  _sel="$(_canonical_plugin_csv "${SELECTED_PLUGINS:-}")"
  _dis="$(_canonical_plugin_csv "${DISMISSED_PLUGINS:-}")"
  _kno="$(_canonical_plugin_csv "${KNOWN_PLUGINS:-}")"
  IFS=',' read -r -a entries < <(printf '%s\n' "$defaults")
  for entry in "${entries[@]+"${entries[@]}"}"; do
    [[ -n "$entry" ]] || continue
    canon="$(_canonical_plugin_entry "$entry")"
    _plugin_csv_has "$_sel" "$canon" && continue
    _plugin_csv_has "$_dis" "$canon" && continue
    _plugin_csv_has "$_kno" "$canon" && continue
    # Emit the default's own spelling, not the canonical one, so the offer and
    # the install use the fully qualified identity the catalog defines.
    out+=("$entry")
  done
  [[ "${#out[@]}" -eq 0 ]] && return 0
  local IFS=,
  printf '%s' "${out[*]}"
}

# ---------------------------------------------------------------------------
# Write the SessionStart notification for plugins the user has not answered.
#
# This deliberately does not ride on _detect_and_write_pending_features: that
# function returns early for the full profile and deletes the pending file,
# and full is precisely the profile where every catalogued plugin is a default
# and newcomers matter most. It writes the same file so there is still one
# notification artifact to clean up (already covered by cleanup_paths_json,
# uninstall.sh, and lib/dryrun.sh), merging into whatever features were
# recorded moments earlier.
#
# Usage: _write_pending_plugins <claude_dir> <plugins-csv>
# ---------------------------------------------------------------------------
_write_pending_plugins() {
  local claude_dir="$1" plugins_csv="$2"
  local pending_file="$claude_dir/.starter-kit-pending-features.json"
  local pending_dir base='{}' tmp_pending=""

  command -v jq &>/dev/null || return 0

  if [[ -e "$pending_file" || -L "$pending_file" ]]; then
    # Never follow symlinks or read devices/FIFOs. Malformed ordinary files are
    # also left byte-for-byte untouched rather than silently discarding a
    # sibling payload owned by the feature recommendation writer.
    [[ -f "$pending_file" && ! -L "$pending_file" ]] || return 1
    if ! base="$(jq -cse '
      if length == 1 and (.[0]
        | type == "object"
          and ((has("features") | not)
            or (.features | type == "array" and all(.[]; type == "string")))
          and ((has("plugins") | not)
            or (.plugins | type == "array" and all(.[]; type == "string"))))
      then .[0]
      else error("invalid pending document")
      end
    ' "$pending_file" 2>/dev/null)"; then
      return 1
    fi
  fi

  if [[ -z "$plugins_csv" ]]; then
    # Nothing outstanding: drop a stale plugins list but keep any features.
    [[ -e "$pending_file" ]] || return 0
    # A file holding neither features nor plugins is noise — remove it.
    if [[ "$(jq -r '(.features // []) | length' <<< "$base")" == "0" ]]; then
      rm -f -- "$pending_file"
      return 0
    fi
  fi

  local plugins_json='[]'
  if [[ -n "$plugins_csv" ]]; then
    plugins_json="$(printf '%s' "$plugins_csv" | tr ',' '\n' | jq -R . | jq -s .)" \
      || return 1
  fi
  jq -e 'type == "array" and all(.[]; type == "string")' \
    >/dev/null 2>&1 <<< "$plugins_json" || return 1

  local kit_version=""
  kit_version="$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null \
    || printf 'unknown')"

  pending_dir="${pending_file%/*}"
  tmp_pending="$(mktemp "$pending_dir/.starter-kit-pending-features.json.tmp.XXXXXX")" \
    || return 1
  if ! chmod 600 "$tmp_pending"; then
    rm -f -- "$tmp_pending"
    return 1
  fi

  if [[ "$plugins_json" == "[]" ]]; then
    if ! jq -n --argjson base "$base" '$base | del(.plugins)' > "$tmp_pending"; then
      rm -f -- "$tmp_pending"
      return 1
    fi
  elif ! jq -n --argjson base "$base" --argjson plugins "$plugins_json" \
    --arg kit_version "$kit_version" \
    '$base + { version: 1, kit_version: $kit_version, plugins: $plugins }' \
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
# Write the SessionStart notification when the shared reader belongs in the
# effective deployment. Normal installs carry it for plugin adoption; MDM keeps
# the exact flag-driven feature surface.
#
# Usage: _notify_pending_plugins <claude_dir> <plugins-csv>
# ---------------------------------------------------------------------------
_notify_pending_plugins() {
  local claude_dir="$1" plugins_csv="$2"
  _feature_deploy_enabled feature-recommendation || return 0
  _write_pending_plugins "$claude_dir" "$plugins_csv" || true
}

# ---------------------------------------------------------------------------
# Detect plugins added to the catalog since the user was last asked, and either
# offer them (interactive) or record a notification (non-interactive).
#
# Called from setup.sh's UPDATE_MODE branch with `|| true`, so a detection
# failure never aborts an otherwise good update.
#
# Usage: _detect_and_offer_new_plugins <claude_dir>
# ---------------------------------------------------------------------------
_detect_and_offer_new_plugins() {
  local claude_dir="$1"
  local defaults newcomers

  command -v jq &>/dev/null || return 0

  defaults="$(_profile_default_plugins "${PROFILE:-standard}")" || return 1
  newcomers="$(_compute_new_plugins "$defaults")" || return 1

  if ! _feature_deploy_enabled feature-recommendation; then
    _write_pending_plugins "$claude_dir" "" || true
    return 0
  fi

  if [[ -z "$newcomers" ]]; then
    # Everything catalogued has been answered: advance the marker so a later
    # profile change is measured from here, and clear any stale notification.
    KNOWN_PLUGINS="$(_plugin_csv_union "${KNOWN_PLUGINS:-}" "$defaults")"
    _write_pending_plugins "$claude_dir" "" || true
    return 0
  fi

  # Notify-only when the user cannot be asked: the auto-update hook and CI pass
  # --non-interactive, dry-run forces the same flag, and a session with no
  # readable controlling terminal cannot answer either. KNOWN_PLUGINS is
  # deliberately left alone in all of these — advancing it would silently
  # consume the offer and the next interactive update would find nothing to ask.
  if [[ "${_MERGE_INTERACTIVE:-true}" != "true" ]] \
    || [[ ! -r "${_TTY_INPUT:-/dev/tty}" ]]; then
    _notify_pending_plugins "$claude_dir" "$newcomers"
    if [[ "${DRY_RUN:-false}" == "true" ]] \
      && declare -F _dryrun_log_plugin_operations >/dev/null 2>&1; then
      _dryrun_log_plugin_operations "$newcomers" "Plugin (new, would prompt)" \
        || return 1
    fi
    return 0
  fi

  local _rc=0
  _offer_new_plugins_interactive "$newcomers" || _rc=$?
  if [[ "$_rc" -eq 2 ]]; then
    # The terminal went away mid-prompt. Entries answered before it vanished are
    # already recorded in SELECTED_PLUGINS / DISMISSED_PLUGINS, so recompute the
    # still-unanswered set rather than re-notifying about answered ones. The
    # marker must not advance while anything is still outstanding.
    local remaining
    remaining="$(_compute_new_plugins "$defaults")" || remaining="$newcomers"
    _notify_pending_plugins "$claude_dir" "$remaining"
    return 0
  fi
  [[ "$_rc" -eq 0 ]] || return "$_rc"

  # Every newcomer now has an answer recorded, so the marker can advance.
  KNOWN_PLUGINS="$(_plugin_csv_union "${KNOWN_PLUGINS:-}" "$defaults")"
  _write_pending_plugins "$claude_dir" "" || true
  return 0
}

# ---------------------------------------------------------------------------
# Prompt for each newcomer. Default is No: a plugin is added only on an
# explicit yes, and any other answer is recorded as declined so the same
# question is not asked again.
#
# Reads from _TTY_INPUT/dev/tty like the kit's other post-wizard prompts. A
# read that fails is NOT an answer — the terminal disappeared, and recording a
# dismissal there would silently bury the offer forever. Returns 2 so the
# caller leaves the marker where it is and asks again next time.
#
# Usage: _offer_new_plugins_interactive <plugins-csv>
# Returns: 0 = every entry answered, 2 = terminal unavailable
# ---------------------------------------------------------------------------
_offer_new_plugins_interactive() {
  local csv="$1" entry reply entries=()
  IFS=',' read -r -a entries < <(printf '%s\n' "$csv")

  printf "\n"
  info "${STR_NEW_PLUGINS_FOUND:-Plugins added since your last setup:}"

  for entry in "${entries[@]+"${entries[@]}"}"; do
    [[ -n "$entry" ]] || continue
    local desc
    desc="$(_plugin_description "$entry")"
    printf "  %s%s%s%s\n" "${BOLD:-}" "$entry" "${NC:-}" "${desc:+ — $desc}"
    # shellcheck disable=SC2059 # STR_* carries the %s placeholder
    if ! read -r -p "$(printf "${STR_NEW_PLUGINS_ASK:-Add %s? [y/N]}" "$entry") " \
      reply < "${_TTY_INPUT:-/dev/tty}" 2>/dev/null; then
      return 2
    fi
    case "$reply" in
      y|Y|yes|YES)
        _plugin_csv_add SELECTED_PLUGINS "$entry"
        # shellcheck disable=SC2059 # STR_* carries the %s placeholder
        ok "$(printf "${STR_NEW_PLUGINS_ADDED:-Adding: %s}" "$entry")"
        ;;
      *)
        _plugin_csv_add DISMISSED_PLUGINS "$entry"
        ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------------------
# Description for a plugin entry, read from the catalog. Accepts a bare name or
# a "name@marketplace" entry and selects on both name and marketplace, so a
# name that collides across marketplaces resolves to the right description. A
# bare name defaults to the official marketplace. Best effort: an empty result
# just means the line is printed without one.
#
# Usage: _plugin_description <name | name@marketplace>
# ---------------------------------------------------------------------------
_plugin_description() {
  local entry="$1" name mp dir
  name="${entry%%@*}"
  if [[ "$entry" == *"@"* ]]; then
    mp="${entry#*@}"
  else
    mp="claude-plugins-official"
  fi
  dir="$(_project_dir)"
  [[ -f "$dir/config/plugins.json" ]] || return 0
  command -v jq &>/dev/null || return 0
  jq -r --arg n "$name" --arg mp "$mp" \
    'first(.plugins[] | select(.name == $n and ((.marketplace // "claude-plugins-official") == $mp)) | .description) // ""' \
    "$dir/config/plugins.json" 2>/dev/null || true
}
