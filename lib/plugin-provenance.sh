#!/bin/bash
# lib/plugin-provenance.sh - Durable ownership record for plugin installs

_PLUGIN_PROVENANCE_BASENAME=".starter-kit-plugin-provenance.json"
_PLUGIN_PROVENANCE_LOCK_BASENAME=".starter-kit-plugin-provenance.lock"
_PLUGIN_PROVENANCE_VERSION=1
_PLUGIN_PROVENANCE_DEFAULT_MARKETPLACE="claude-plugins-official"

_plugin_provenance_qualify() { # <plugin-or-qualified-plugin>
  local value="${1:-}" name marketplace
  [[ -n "$value" && "${#value}" -le 255 ]] || return 1
  [[ "$value" != *[[:space:],/]* ]] || return 1
  case "$value" in
    *@*)
      name="${value%%@*}"
      marketplace="${value#*@}"
      [[ "$marketplace" != *"@"* ]] || return 1
      ;;
    *)
      name="$value"
      marketplace="$_PLUGIN_PROVENANCE_DEFAULT_MARKETPLACE"
      ;;
  esac
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [[ "$marketplace" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  printf '%s@%s\n' "$name" "$marketplace"
}

_plugin_provenance_list_has_exact() { # <claude-plugin-list-output> <qualified-id>
  local list="$1" qualified
  qualified="$(_plugin_provenance_qualify "$2")" || return 1
  printf '%s\n' "$list" | awk -v expected="$qualified" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line == "") next
      n = split(line, parts, /[[:space:]]+/)
      candidate = parts[1]
      if (candidate !~ /^[A-Za-z0-9_]/ && n >= 2) candidate = parts[2]
      if (candidate == expected) found = 1
    }
    END { exit found ? 0 : 1 }
  '
}

_plugin_provenance_stat() { # <field> <path>
  local field="$1" path="$2" value=""
  case "$field" in
    identity)
      value="$(stat -f '%d:%i' "$path" 2>/dev/null)" \
        || value="$(stat -c '%d:%i' "$path" 2>/dev/null)" || return 1
      ;;
    mode)
      value="$(stat -f '%Lp' "$path" 2>/dev/null)" \
        || value="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
      ;;
    links)
      value="$(stat -f '%l' "$path" 2>/dev/null)" \
        || value="$(stat -c '%h' "$path" 2>/dev/null)" || return 1
      ;;
    uid)
      value="$(stat -f '%u' "$path" 2>/dev/null)" \
        || value="$(stat -c '%u' "$path" 2>/dev/null)" || return 1
      ;;
    size)
      value="$(stat -f '%z' "$path" 2>/dev/null)" \
        || value="$(stat -c '%s' "$path" 2>/dev/null)" || return 1
      ;;
    *) return 1 ;;
  esac
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

_plugin_provenance_root_binding() { # <root>; prints physical-path<TAB>dev:ino
  local root="$1"
  [[ "$root" == /* && "$root" != *[$'\n\r\t']* ]] || return 1
  [[ -d "$root" && ! -L "$root" ]] || return 1
  (
    local physical identity
    cd -P "$root" 2>/dev/null || exit 1
    physical="$(pwd -P)" || exit 1
    identity="$(_plugin_provenance_stat identity .)" || exit 1
    [[ -n "$physical" && "$physical" != *[$'\n\r\t']* ]] || exit 1
    printf '%s\t%s\n' "$physical" "$identity"
  )
}

_plugin_provenance_binding_matches() { # <root> <physical-path> <dev:ino>
  local root="$1" expected_physical="$2" expected_identity="$3"
  (
    cd -P "$root" 2>/dev/null || exit 1
    [[ "$(pwd -P)" == "$expected_physical" ]] || exit 1
    [[ "$(_plugin_provenance_stat identity .)" == "$expected_identity" ]]
  )
}

_plugin_provenance_json_valid() { # <regular-file>
  local file="$1" mode links uid size
  [[ -f "$file" && ! -L "$file" ]] || return 1
  mode="$(_plugin_provenance_stat mode "$file")" || return 1
  links="$(_plugin_provenance_stat links "$file")" || return 1
  uid="$(_plugin_provenance_stat uid "$file")" || return 1
  size="$(_plugin_provenance_stat size "$file")" || return 1
  [[ "$mode" == "600" && "$links" == "1" && "$uid" == "$(id -u)" ]] \
    || return 1
  [[ "$size" =~ ^[0-9]+$ && "$size" -le 65536 ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '
    type == "object"
    and ((keys | sort) == ["installed_by_kit", "version"])
    and .version == 1
    and (.installed_by_kit | type == "array")
    and (.installed_by_kit | length <= 256)
    and all(.installed_by_kit[];
      type == "string"
      and test("^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9._-]*$"))
    and (.installed_by_kit == (.installed_by_kit | sort | unique))
  ' "$file" >/dev/null 2>&1
}

_plugin_provenance_file_signature() { # <regular-file>
  local file="$1" identity mode links uid size checksum
  _plugin_provenance_json_valid "$file" || return 1
  identity="$(_plugin_provenance_stat identity "$file")" || return 1
  mode="$(_plugin_provenance_stat mode "$file")" || return 1
  links="$(_plugin_provenance_stat links "$file")" || return 1
  uid="$(_plugin_provenance_stat uid "$file")" || return 1
  size="$(_plugin_provenance_stat size "$file")" || return 1
  checksum="$(cksum < "$file" 2>/dev/null)" || return 1
  checksum="${checksum%% *}:${checksum#* }"
  checksum="${checksum%% *}"
  printf '%s:%s:%s:%s:%s:%s\n' \
    "$identity" "$mode" "$links" "$uid" "$size" "$checksum"
}

_plugin_provenance_validate_bound() { # <root> <physical-path> <dev:ino>
  local root="$1" physical="$2" identity="$3"
  (
    cd -P "$root" 2>/dev/null || exit 1
    [[ "$(pwd -P)" == "$physical" ]] || exit 1
    [[ "$(_plugin_provenance_stat identity .)" == "$identity" ]] || exit 1
    [[ -e "./$_PLUGIN_PROVENANCE_BASENAME" \
      || -L "./$_PLUGIN_PROVENANCE_BASENAME" ]] || exit 2
    _plugin_provenance_json_valid "./$_PLUGIN_PROVENANCE_BASENAME"
  )
}

_plugin_provenance_signature_bound() { # <root> <physical-path> <dev:ino>
  local root="$1" physical="$2" identity="$3"
  (
    cd -P "$root" 2>/dev/null || exit 1
    [[ "$(pwd -P)" == "$physical" ]] || exit 1
    [[ "$(_plugin_provenance_stat identity .)" == "$identity" ]] || exit 1
    _plugin_provenance_file_signature "./$_PLUGIN_PROVENANCE_BASENAME"
  )
}

_plugin_provenance_contains_bound() { # <root> <physical-path> <dev:ino> <qualified-id>
  local root="$1" physical="$2" identity="$3" qualified signature_before signature_after
  qualified="$(_plugin_provenance_qualify "$4")" || return 1
  (
    cd -P "$root" 2>/dev/null || exit 1
    [[ "$(pwd -P)" == "$physical" ]] || exit 1
    [[ "$(_plugin_provenance_stat identity .)" == "$identity" ]] || exit 1
    signature_before="$(_plugin_provenance_file_signature "./$_PLUGIN_PROVENANCE_BASENAME")" \
      || exit 1
    jq -e --arg plugin "$qualified" \
      '.installed_by_kit | index($plugin) != null' \
      "./$_PLUGIN_PROVENANCE_BASENAME" >/dev/null 2>&1 || exit 3
    signature_after="$(_plugin_provenance_file_signature "./$_PLUGIN_PROVENANCE_BASENAME")" \
      || exit 1
    [[ "$signature_after" == "$signature_before" ]] || exit 1
  )
}

_plugin_provenance_lock_owner_valid() { # <lock-dir> <token> <dev:ino>
  local lock_dir="$1" token="$2" expected_identity="$3"
  local owner="$lock_dir/owner" mode links uid size count value
  [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 1
  [[ "$(_plugin_provenance_stat identity "$lock_dir")" == "$expected_identity" ]] \
    || return 1
  [[ -f "$owner" && ! -L "$owner" ]] || return 1
  mode="$(_plugin_provenance_stat mode "$owner")" || return 1
  links="$(_plugin_provenance_stat links "$owner")" || return 1
  uid="$(_plugin_provenance_stat uid "$owner")" || return 1
  size="$(_plugin_provenance_stat size "$owner")" || return 1
  [[ "$mode" == "600" && "$links" == "1" && "$uid" == "$(id -u)" ]] \
    || return 1
  [[ "$size" == "$((${#token} + 1))" ]] || return 1
  IFS= read -r value < "$owner" || return 1
  [[ "$value" == "$token" ]] || return 1
  count="$(find "$lock_dir" -mindepth 1 -maxdepth 1 -print 2>/dev/null \
    | wc -l | tr -d '[:space:]')" || return 1
  [[ "$count" == "1" ]]
}

_plugin_provenance_lock_acquire_bound() { # <root> <physical> <dev:ino>
  local root="$1" physical="$2" identity="$3"
  local token="starter-kit-$$-${RANDOM}-${SECONDS:-0}"
  (
    local lock="./$_PLUGIN_PROVENANCE_LOCK_BASENAME" lock_identity
    cd -P "$root" 2>/dev/null || exit 1
    [[ "$(pwd -P)" == "$physical" ]] || exit 1
    [[ "$(_plugin_provenance_stat identity .)" == "$identity" ]] || exit 1
    [[ ! -e "$lock" && ! -L "$lock" ]] || exit 1
    (umask 077; mkdir "$lock") 2>/dev/null || exit 1
    if ! (umask 077; printf '%s\n' "$token" > "$lock/owner") 2>/dev/null; then
      rmdir "$lock" 2>/dev/null || true
      exit 1
    fi
    lock_identity="$(_plugin_provenance_stat identity "$lock")" || exit 1
    _plugin_provenance_lock_owner_valid "$lock" "$token" "$lock_identity" \
      || exit 1
    _plugin_provenance_binding_matches "$root" "$physical" "$identity" \
      || exit 1
    printf '%s\t%s\n' "$token" "$lock_identity"
  )
}

_plugin_provenance_lock_release_bound() { # <root> <physical> <dev:ino> <token> <lock-dev:ino>
  local root="$1" physical="$2" identity="$3" token="$4"
  local lock_identity="$5"
  (
    local lock="./$_PLUGIN_PROVENANCE_LOCK_BASENAME"
    local quarantine="./${_PLUGIN_PROVENANCE_LOCK_BASENAME}.release-$token"
    cd -P "$root" 2>/dev/null || exit 1
    [[ "$(pwd -P)" == "$physical" ]] || exit 1
    [[ "$(_plugin_provenance_stat identity .)" == "$identity" ]] || exit 1
    _plugin_provenance_lock_owner_valid "$lock" "$token" "$lock_identity" \
      || exit 1
    [[ ! -e "$quarantine" && ! -L "$quarantine" ]] || exit 1
    mv "$lock" "$quarantine" || exit 1
    _plugin_provenance_lock_owner_valid \
      "$quarantine" "$token" "$lock_identity" || exit 1
    rm -f "$quarantine/owner" || exit 1
    rmdir "$quarantine" || exit 1
  )
}

_plugin_provenance_record() { # <root> <qualified-id>
  local root="$1" qualified binding physical identity
  local marker="$_PLUGIN_PROVENANCE_BASENAME"
  [[ "${DRY_RUN:-false}" != "true" ]] || return 0
  qualified="$(_plugin_provenance_qualify "$2")" || return 1
  command -v jq >/dev/null 2>&1 || return 1
  binding="$(_plugin_provenance_root_binding "$root")" || return 1
  physical="${binding%$'\t'*}"
  identity="${binding##*$'\t'}"
  (
    local existed=false before_signature="" temp_file="" operation_rc=0
    local release_rc=0
    local lock_binding="" lock_token="" lock_identity=""
    cd -P "$root" 2>/dev/null || exit 1
    [[ "$(pwd -P)" == "$physical" ]] || exit 1
    [[ "$(_plugin_provenance_stat identity .)" == "$identity" ]] || exit 1
    lock_binding="$(_plugin_provenance_lock_acquire_bound \
      "$root" "$physical" "$identity")" || exit 1
    lock_token="${lock_binding%$'\t'*}"
    lock_identity="${lock_binding##*$'\t'}"
    trap '_plugin_provenance_lock_release_bound "$root" "$physical" "$identity" "$lock_token" "$lock_identity" >/dev/null 2>&1 || true; exit 1' HUP INT TERM

    _plugin_provenance_record_locked_body() {
      if [[ -e "./$marker" || -L "./$marker" ]]; then
        before_signature="$(_plugin_provenance_file_signature "./$marker")" \
          || return 1
        existed=true
      fi
      temp_file="$(mktemp "./.${marker}.tmp.XXXXXX")" || return 1
      if [[ "$existed" == "true" ]]; then
        jq --arg plugin "$qualified" \
          '.installed_by_kit = ((.installed_by_kit + [$plugin]) | sort | unique)' \
          "./$marker" > "$temp_file" || return 1
      else
        jq -n --arg plugin "$qualified" \
          '{version: 1, installed_by_kit: [$plugin]}' > "$temp_file" \
          || return 1
      fi
      chmod 600 "$temp_file" || return 1
      _plugin_provenance_json_valid "$temp_file" || return 1
      _plugin_provenance_binding_matches "$root" "$physical" "$identity" \
        || return 1
      if [[ "$existed" == "true" ]]; then
        [[ "$(_plugin_provenance_file_signature "./$marker")" \
          == "$before_signature" ]] || return 1
      else
        [[ ! -e "./$marker" && ! -L "./$marker" ]] || return 1
      fi
      mv -f "$temp_file" "./$marker" || return 1
      temp_file=""
      _plugin_provenance_json_valid "./$marker" || return 1
      jq -e --arg plugin "$qualified" \
        '.installed_by_kit | index($plugin) != null' \
        "./$marker" >/dev/null 2>&1
    }

    _plugin_provenance_record_locked_body || operation_rc=$?
    [[ -z "$temp_file" ]] || rm -f "$temp_file" 2>/dev/null || true
    _plugin_provenance_lock_release_bound \
      "$root" "$physical" "$identity" "$lock_token" "$lock_identity" \
      || release_rc=$?
    trap - HUP INT TERM
    [[ "$operation_rc" -eq 0 && "$release_rc" -eq 0 ]]
  )
}

_plugin_provenance_remove_bound() { # <root> <physical> <dev:ino> <file-signature>
  local root="$1" physical="$2" identity="$3" expected_signature="$4"
  (
    local lock_binding lock_token lock_identity operation_rc=0 release_rc=0
    cd -P "$root" 2>/dev/null || exit 1
    [[ "$(pwd -P)" == "$physical" ]] || exit 1
    [[ "$(_plugin_provenance_stat identity .)" == "$identity" ]] || exit 1
    lock_binding="$(_plugin_provenance_lock_acquire_bound \
      "$root" "$physical" "$identity")" || exit 1
    lock_token="${lock_binding%$'\t'*}"
    lock_identity="${lock_binding##*$'\t'}"
    trap '_plugin_provenance_lock_release_bound "$root" "$physical" "$identity" "$lock_token" "$lock_identity" >/dev/null 2>&1 || true; exit 1' HUP INT TERM
    if [[ "$(_plugin_provenance_file_signature \
        "./$_PLUGIN_PROVENANCE_BASENAME")" != "$expected_signature" ]] \
      || ! _plugin_provenance_binding_matches \
        "$root" "$physical" "$identity" \
      || ! rm -f "./$_PLUGIN_PROVENANCE_BASENAME" \
      || [[ -e "./$_PLUGIN_PROVENANCE_BASENAME" \
        || -L "./$_PLUGIN_PROVENANCE_BASENAME" ]]; then
      operation_rc=1
    fi
    _plugin_provenance_lock_release_bound \
      "$root" "$physical" "$identity" "$lock_token" "$lock_identity" \
      || release_rc=$?
    trap - HUP INT TERM
    [[ "$operation_rc" -eq 0 && "$release_rc" -eq 0 ]]
  )
}
