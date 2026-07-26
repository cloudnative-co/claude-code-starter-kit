#!/bin/bash
# check-pending.sh - SessionStart hook: notify user about pending features
#
# Self-contained script (does NOT source lib/*.sh).
# Reads ~/.claude/.starter-kit-pending-features.json and displays
# available features with displayName/description from kit repo.
#
# Bash 3.2 compatible (macOS default). No mapfile, no associative arrays.
#
# Exit codes: always 0 (never block session start)
set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
PENDING_FILE="$CLAUDE_DIR/.starter-kit-pending-features.json"

# Exit silently if no pending features
[[ -f "$PENDING_FILE" ]] || exit 0

# Validate JSON (exit silently on parse error)
jq empty "$PENDING_FILE" 2>/dev/null || exit 0

# Read feature names (Bash 3.2 compatible - no mapfile)
FEATURES=()
while IFS= read -r line; do
  [[ -n "$line" ]] && FEATURES+=("$line")
done < <(jq -r '.features[]? // empty' "$PENDING_FILE" 2>/dev/null)

# Plugins catalogued since the user was last asked. Written by a separate
# detector, so the file may carry plugins with no features (the full profile
# has no pending features by definition) or features with no plugins.
PLUGINS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && PLUGINS+=("$line")
done < <(jq -r '.plugins[]? // empty' "$PENDING_FILE" 2>/dev/null)

[[ ${#FEATURES[@]} -gt 0 || ${#PLUGINS[@]} -gt 0 ]] || exit 0

# ---------------------------------------------------------------------------
# Resolve kit repo path
# ---------------------------------------------------------------------------
# Prefer an explicit runtime override, then the checkout recorded in the
# wizard config, and finally the legacy location. Config contents are parsed as
# data; they are never sourced or evaluated.
_KIT_REPO_OVERRIDE_SET=false
_KIT_REPO_OVERRIDE=""
if [[ ${KIT_REPO+x} ]]; then
  _KIT_REPO_OVERRIDE_SET=true
  _KIT_REPO_OVERRIDE="$KIT_REPO"
fi

_kit_repo_is_checkout() {
  [[ -n "$1" ]] || return 1
  [[ "$1" == /* ]] || return 1
  [[ -d "$1/features" ]] || return 1
  [[ -f "$1/lib/features.sh" ]] || return 1
  [[ -f "$1/config/plugins.json" ]]
}

_config_kit_repo() {
  local config_file="${HOME}/.claude-starter-kit.conf"
  local line="" value="" matches=0
  [[ -f "$config_file" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^KIT_REPO=\"([^\"]+)\"$ ]]; then
      matches=$((matches + 1))
      value="${BASH_REMATCH[1]}"
    elif [[ "$line" == KIT_REPO=* ]]; then
      # A malformed or ambiguous declaration must not be partially accepted.
      return 1
    fi
  done < "$config_file"

  [[ $matches -eq 1 ]] || return 1
  [[ "$value" == /* ]] || return 1
  printf '%s' "$value"
}

_resolve_kit_repo() {
  local candidate=""
  if [[ "$_KIT_REPO_OVERRIDE_SET" == true ]] \
    && _kit_repo_is_checkout "$_KIT_REPO_OVERRIDE"; then
    printf '%s' "$_KIT_REPO_OVERRIDE"
    return 0
  fi

  candidate="$(_config_kit_repo || true)"
  if _kit_repo_is_checkout "$candidate"; then
    printf '%s' "$candidate"
    return 0
  fi

  candidate="${HOME}/.claude-starter-kit"
  if _kit_repo_is_checkout "$candidate"; then
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

KIT_REPO="$(_resolve_kit_repo || true)"

# ---------------------------------------------------------------------------
# Catalog gate — nothing is displayed unless the kit still ships it.
#
# This script's stdout is injected into the Claude Code session context by the
# SessionStart hook, and the pending file is an ordinary file under ~/.claude.
# Without this gate, whatever can write that file chooses text that lands in
# front of the model. Treat every name as a lookup key into the kit's own
# catalog, never as free text: an entry that resolves is printed, an entry that
# does not is dropped silently.
#
# Fail closed. With no readable catalog a real entry cannot be told apart from
# an injected one, and the notification only ever says "run /update-kit", which
# needs that same checkout anyway — so staying quiet costs nothing.
# ---------------------------------------------------------------------------
FEATURE_CATALOG=""
if [[ -n "$KIT_REPO" ]]; then
  # Parse only the declarative _FEATURE_FLAGS table. Do not source this Bash 4
  # file from the Bash 3.2-compatible hook. Any malformed row invalidates the
  # complete catalog, avoiding a partially trusted allowlist.
  if _feature_catalog="$(awk '
    BEGIN { inside = 0; found = 0; closed = 0; invalid = 0 }
    /^[[:space:]]*declare[[:space:]]+-g[[:space:]]+-A[[:space:]]+_FEATURE_FLAGS=\([[:space:]]*$/ {
      if (found) invalid = 1
      inside = 1; found = 1; next
    }
    inside && /^[[:space:]]*\)[[:space:]]*$/ {
      inside = 0; closed = 1; next
    }
    inside {
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
      if ($0 !~ /^[[:space:]]*\[[A-Za-z0-9][A-Za-z0-9._-]*\]=[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/) {
        invalid = 1; next
      }
      entry = $0
      sub(/^[[:space:]]*\[/, "", entry)
      sub(/\]=[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/, "", entry)
      print entry
    }
    END { if (!found || !closed || inside || invalid) exit 1 }
  ' "$KIT_REPO/lib/features.sh" 2>/dev/null)"; then
    FEATURE_CATALOG="$_feature_catalog"
  fi
fi

PLUGIN_CATALOG=""
if [[ -n "$KIT_REPO" ]]; then
  _plugin_file="$KIT_REPO/config/plugins.json"
  # Validate the complete catalog before deriving any accepted spelling. In
  # particular, every plugin marketplace must be registered by the top-level
  # mapping. A parse/schema/generation failure leaves the allowlist empty.
  if jq -e '
    . as $root
    | (type == "object")
      and ((.marketplaces | type) == "object")
      and all(.marketplaces | to_entries[];
        (.key | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
        and ((.value | type) == "string")
        and ((.value | length) > 0))
      and ((.plugins | type) == "array")
      and all(.plugins[];
        (type == "object")
        and ((.name | type) == "string")
        and (.name | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
        and ((.marketplace // "claude-plugins-official") as $mp
          | (($mp | type) == "string")
          and ($mp | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
          and ($root.marketplaces | has($mp))))
  ' "$_plugin_file" >/dev/null 2>&1; then
    if _plugin_catalog="$(jq -r '
      .plugins[]
      | (.marketplace // "claude-plugins-official") as $mp
      | (.name + "@" + $mp),
        (if $mp == "claude-plugins-official" then .name else empty end)
    ' "$_plugin_file" 2>/dev/null)"; then
      PLUGIN_CATALOG="$_plugin_catalog"
    fi
  fi
fi

_feature_is_registered() {
  [[ -n "$FEATURE_CATALOG" ]] || return 1
  case $'\n'"$FEATURE_CATALOG"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

_feature_is_catalogued() {
  # Reject anything that is not a plain directory name before it is ever used
  # as a path component.
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [[ -n "$KIT_REPO" ]] || return 1
  case "$1" in
    feature-recommendation|fonts|ghostty|codex-plugin) return 1 ;;
  esac
  _feature_is_registered "$1" || return 1
  [[ -f "$KIT_REPO/features/$1/feature.json" ]]
}

_plugin_is_catalogued() {
  [[ -n "$PLUGIN_CATALOG" ]] || return 1
  # Whole-line membership. The quoted "$1" is literal, so a glob in the pending
  # file matches nothing rather than everything.
  case $'\n'"$PLUGIN_CATALOG"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

_KEPT=()
for _entry in "${FEATURES[@]+"${FEATURES[@]}"}"; do
  if _feature_is_catalogued "$_entry"; then
    _KEPT[${#_KEPT[@]}]="$_entry"
  fi
done
FEATURES=("${_KEPT[@]+"${_KEPT[@]}"}")

_KEPT=()
for _entry in "${PLUGINS[@]+"${PLUGINS[@]}"}"; do
  if _plugin_is_catalogued "$_entry"; then
    _KEPT[${#_KEPT[@]}]="$_entry"
  fi
done
PLUGINS=("${_KEPT[@]+"${_KEPT[@]}"}")

# Everything pending was unrecognized: say nothing.
[[ ${#FEATURES[@]} -gt 0 || ${#PLUGINS[@]} -gt 0 ]] || exit 0

# ---------------------------------------------------------------------------
# Sanitize display strings (strip ANSI escapes first, then non-printable chars)
# Order matters: sed removes escape sequences before tr strips control chars
# ---------------------------------------------------------------------------
_sanitize_display() {
  printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | LC_ALL=C tr -cd '[:print:] \t'
}

# ---------------------------------------------------------------------------
# Resolve displayName and description from feature.json
# The catalog gate above guarantees the file exists; the titlecase fallback now
# only covers a feature.json whose displayName is empty.
# ---------------------------------------------------------------------------
_resolve_feature_info() {
  local name="$1"
  local fj="${KIT_REPO}/features/${name}/feature.json"
  local display_name="" description=""

  if [[ -n "$KIT_REPO" ]] && [[ -f "$fj" ]]; then
    display_name="$(jq -r '.displayName // empty' "$fj" 2>/dev/null || true)"
    description="$(jq -r '.description // empty' "$fj" 2>/dev/null || true)"
  fi

  # Fallback: hyphen to space, titlecase (awk for BSD/GNU portability)
  if [[ -z "$display_name" ]]; then
    display_name="$(printf '%s' "$name" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')"
  fi

  _sanitize_display "$display_name"
  if [[ -n "$description" ]]; then
    printf ': '
    _sanitize_display "$description"
  fi
}

# ---------------------------------------------------------------------------
# Detect language from conf (lightweight grep, no full config parsing)
# ---------------------------------------------------------------------------
LANGUAGE="en"
CONF_FILE="${HOME}/.claude-starter-kit.conf"
if [[ -f "$CONF_FILE" ]]; then
  _lang_val="$(grep '^LANGUAGE=' "$CONF_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' || true)"
  [[ -n "$_lang_val" ]] && LANGUAGE="$_lang_val"
fi

# ---------------------------------------------------------------------------
# Build notification message
# ---------------------------------------------------------------------------
count=${#FEATURES[@]}
MAX_DISPLAY=3

_print_pending_plugins() {
  local idx=0 p total=${#PLUGINS[@]}
  [[ $total -gt 0 ]] || return 0
  if [[ "$LANGUAGE" == "ja" ]]; then
    if [[ $total -eq 1 ]]; then
      printf '[Starter Kit] 新しいプラグインが利用可能です:\n'
    else
      printf '[Starter Kit] %d 件の新しいプラグインが利用可能です:\n' "$total"
    fi
  else
    if [[ $total -eq 1 ]]; then
      printf '[Starter Kit] New plugin available:\n'
    else
      printf '[Starter Kit] %d new plugins available:\n' "$total"
    fi
  fi
  for p in "${PLUGINS[@]}"; do
    if [[ $idx -lt $MAX_DISPLAY ]]; then
      printf '  - %s\n' "$(_sanitize_display "$p")"
    fi
    idx=$((idx + 1))
  done
  if [[ "$LANGUAGE" == "ja" ]]; then
    [[ $total -gt $MAX_DISPLAY ]] && printf '  ...他 %d 件\n' $((total - MAX_DISPLAY))
    printf '  このセッションで /update-kit と入力すると、追加するか選べます。\n'
  else
    [[ $total -gt $MAX_DISPLAY ]] && printf '  ...and %d more\n' $((total - MAX_DISPLAY))
    printf '  Type /update-kit in this session to choose which to add.\n'
  fi
  return 0
}

if [[ $count -eq 0 ]]; then
  _print_pending_plugins
  exit 0
fi

if [[ "$LANGUAGE" == "ja" ]]; then
  if [[ $count -eq 1 ]]; then
    printf '[Starter Kit] 新機能が利用可能です:\n'
  else
    printf '[Starter Kit] %d 件の新機能が利用可能です:\n' "$count"
  fi

  idx=0
  for feat in "${FEATURES[@]}"; do
    if [[ $idx -lt $MAX_DISPLAY ]]; then
      printf '  - %s\n' "$(_resolve_feature_info "$feat")"
    fi
    idx=$((idx + 1))
  done
  if [[ $count -gt $MAX_DISPLAY ]]; then
    printf '  ...他 %d 件\n' $((count - MAX_DISPLAY))
  fi
  printf '  このセッションで /update-kit と入力すると、各機能の有効化・スキップを選べます。\n'
else
  if [[ $count -eq 1 ]]; then
    printf '[Starter Kit] New feature available:\n'
  else
    printf '[Starter Kit] %d new features available:\n' "$count"
  fi

  idx=0
  for feat in "${FEATURES[@]}"; do
    if [[ $idx -lt $MAX_DISPLAY ]]; then
      printf '  - %s\n' "$(_resolve_feature_info "$feat")"
    fi
    idx=$((idx + 1))
  done
  if [[ $count -gt $MAX_DISPLAY ]]; then
    printf '  ...and %d more\n' $((count - MAX_DISPLAY))
  fi
  printf '  Type /update-kit in this session to choose which features to enable or skip.\n'
fi

_print_pending_plugins
