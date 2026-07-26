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

_plugin_provenance_list_exact_entries() { # <claude-plugin-list-output>
  printf '%s\n' "$1" | awk '
    function emit() {
      if (candidate == "") return
      print candidate "\t" scope
      entry_count++
      candidate = ""
      scope = ""
      scope_seen = 0
    }
    {
      line = $0
      sub(/\r$/, "", line)
      sub(/^[[:space:]]+/, "", line)
      if (line == "") next
      if (line == "No plugins installed. Use `claude plugin install` to install a plugin.") {
        if (header_count || entry_count || candidate != "" || no_plugins) exit 2
        no_plugins = 1
        next
      }
      if (no_plugins) exit 2
      if (line == "Installed plugins:") {
        if (header_count || entry_count || candidate != "") exit 2
        header_count = 1
        next
      }
      n = split(line, parts, /[[:space:]]+/)
      value = parts[1]
      marker = ""
      if (value == "❯" || value == "-" || value == "*" || value == "+") {
        if (n != 2) exit 2
        marker = value
        value = parts[2]
      } else if (value !~ /^[A-Za-z0-9_]/ && n >= 2 \
        && parts[2] ~ /@/) {
        # An entry-looking line with an unknown marker is malformed, not
        # harmless metadata. Silently dropping it would weaken set equality.
        exit 2
      }
      if (value ~ /^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9._-]*$/) {
        if (!header_count || (marker == "" && n != 1)) exit 2
        if (candidate != "" && !scope_seen) exit 2
        emit()
        candidate = value
        scope = ""
        next
      }
      if (marker != "" || (value ~ /@/ && value !~ /:$/)) exit 2
      if (candidate != "" && line ~ /^Scope:[[:space:]]*/) {
        if (scope_seen) exit 2
        sub(/^Scope:[[:space:]]*/, "", line)
        if (line !~ /^[A-Za-z][A-Za-z0-9._-]*$/) exit 2
        scope = line
        scope_seen = 1
      } else if (candidate == "" && line ~ /^Scope:/) {
        exit 2
      } else if (line ~ /^(Version|Status|Error|Note):/) {
        if (candidate == "") exit 2
      } else {
        exit 2
      }
    }
    END {
      if (candidate != "" && !scope_seen) exit 2
      emit()
      if (!no_plugins && (header_count != 1 || entry_count == 0)) exit 2
    }
  '
}

_plugin_provenance_list_has_user_exact() { # <list-output> <qualified-id>
  local list="$1" qualified entries
  qualified="$(_plugin_provenance_qualify "$2")" || return 1
  entries="$(_plugin_provenance_list_exact_entries "$list")" || return 1
  printf '%s\n' "$entries" | awk -F '\t' -v expected="$qualified" '
    $1 == expected && $2 == "user" { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

_plugin_provenance_list_has_exact() { # compatibility: exact user-scope ID
  _plugin_provenance_list_has_user_exact "$1" "$2"
}

_plugin_provenance_install_postcondition() { # <before-list> <after-list> <id>
  local before="$1" after="$2" qualified before_entries after_entries
  qualified="$(_plugin_provenance_qualify "$3")" || return 1
  before_entries="$(_plugin_provenance_list_exact_entries "$before")" \
    || return 1
  after_entries="$(_plugin_provenance_list_exact_entries "$after")" \
    || return 1
  before_entries="$(printf '%s\n' "$before_entries" | LC_ALL=C sort -u)" \
    || return 1
  after_entries="$(printf '%s\n' "$after_entries" | LC_ALL=C sort -u)" \
    || return 1
  printf '%s\n__START_AFTER__\n%s\n' \
    "$before_entries" "$after_entries" \
    | awk -v target="$qualified" '
      $0 == "__START_AFTER__" { in_after = 1; next }
      $0 == "" { next }
      !in_after { before[$0] = 1; next }
      { after[$0] = 1 }
      END {
        target_user = target "\tuser"
        if (!(target_user in after)) exit 1
        for (entry in before) {
          if (!(entry in after)) exit 1
        }
      }
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

_plugin_provenance_file_mode_valid() { # <native-mode>
  local mode="$1" platform=""
  [[ "$mode" == "600" ]] && return 0
  platform="$(uname -s 2>/dev/null)" || return 1
  case "$platform" in
    MSYS_NT*|MINGW*_NT*|CLANG*_NT*|UCRT*_NT*)
      # On Windows filesystems without POSIX ACL emulation, chmod succeeds but
      # stat exposes the native non-executable file mode instead of 0600.
      [[ "$mode" == "644" || "$mode" == "666" ]]
      ;;
    *) return 1 ;;
  esac
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
  _plugin_provenance_file_mode_valid "$mode" || return 1
  [[ "$links" == "1" && "$uid" == "$(id -u)" ]] || return 1
  [[ "$size" =~ ^[0-9]+$ && "$size" -le 65536 ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -s -e '
    length == 1
    and (.[0] | . as $root
    | type == "object"
    and ($root | has("version") and has("installed_by_kit"))
    and (($root | keys
      - ["installed_by_kit", "pending_install_by_kit",
        "verified_commit_by_kit", "version"]) | length == 0)
    and .version == 1
    and (.installed_by_kit | type == "array")
    and (.installed_by_kit | length <= 256)
    and all(.installed_by_kit[];
      type == "string"
      and test("^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9._-]*$"))
    and (.installed_by_kit == (.installed_by_kit | sort | unique))
    and (if $root | has("pending_install_by_kit") then
      ($root.pending_install_by_kit | type) == "array"
    else true end)
    and ((.installed_by_kit | length)
      + (($root.pending_install_by_kit // []) | length)
      + (($root.verified_commit_by_kit // []) | length) <= 256)
    and all(($root.pending_install_by_kit // [])[];
      type == "string"
      and test("^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9._-]*$"))
    and (($root.pending_install_by_kit // [])
      == (($root.pending_install_by_kit // []) | sort | unique))
    and (if $root | has("verified_commit_by_kit") then
      ($root.verified_commit_by_kit | type) == "array"
    else true end)
    and all(($root.verified_commit_by_kit // [])[];
      type == "string"
      and test("^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9._-]*$"))
    and (($root.verified_commit_by_kit // [])
      == (($root.verified_commit_by_kit // []) | sort | unique))
    and all(($root.pending_install_by_kit // [])[]; . as $plugin
      | ($root.installed_by_kit | index($plugin)) == null
      and (($root.verified_commit_by_kit // []) | index($plugin)) == null)
    and all(($root.verified_commit_by_kit // [])[]; . as $plugin
      | ($root.installed_by_kit | index($plugin)) == null)
    )
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

_plugin_provenance_field_contains_bound() { # <root> <physical> <dev:ino> <id> <field>
  local root="$1" physical="$2" identity="$3" qualified field="$5"
  local signature_before signature_after
  qualified="$(_plugin_provenance_qualify "$4")" || return 1
  case "$field" in
    installed_by_kit|pending_install_by_kit|verified_commit_by_kit) ;;
    *) return 1 ;;
  esac
  (
    cd -P "$root" 2>/dev/null || exit 1
    [[ "$(pwd -P)" == "$physical" ]] || exit 1
    [[ "$(_plugin_provenance_stat identity .)" == "$identity" ]] || exit 1
    signature_before="$(_plugin_provenance_file_signature "./$_PLUGIN_PROVENANCE_BASENAME")" \
      || exit 1
    jq -e --arg plugin "$qualified" --arg field "$field" \
      '(.[$field] // []) | index($plugin) != null' \
      "./$_PLUGIN_PROVENANCE_BASENAME" >/dev/null 2>&1 || exit 3
    signature_after="$(_plugin_provenance_file_signature "./$_PLUGIN_PROVENANCE_BASENAME")" \
      || exit 1
    [[ "$signature_after" == "$signature_before" ]] || exit 1
  )
}

_plugin_provenance_contains_bound() { # <root> <physical> <dev:ino> <id>
  _plugin_provenance_field_contains_bound "$@" installed_by_kit
}

_plugin_provenance_field_contains() { # <root> <qualified-id> <field>
  local root="$1" qualified="$2" field="$3" binding physical identity
  binding="$(_plugin_provenance_root_binding "$root")" || return 1
  physical="${binding%$'\t'*}"
  identity="${binding##*$'\t'}"
  _plugin_provenance_field_contains_bound \
    "$root" "$physical" "$identity" "$qualified" "$field"
}

_plugin_provenance_is_installed_by_kit() { # <root> <qualified-id>
  _plugin_provenance_field_contains "$1" "$2" installed_by_kit
}

_plugin_provenance_is_pending() { # <root> <qualified-id>
  _plugin_provenance_field_contains "$1" "$2" pending_install_by_kit
}

_plugin_provenance_is_verified() { # <root> <qualified-id>
  _plugin_provenance_field_contains "$1" "$2" verified_commit_by_kit
}

_plugin_provenance_process_identity() { # <pid>; stable for one OS process lifetime
  local pid="$1" raw="" stat_line="" stat_tail="" boot_id=""
  local ps_command="" digest="" old_ifs
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  if [[ -r "/proc/$pid/stat" && -r /proc/sys/kernel/random/boot_id ]]; then
    IFS= read -r stat_line < "/proc/$pid/stat" || return 1
    IFS= read -r boot_id < /proc/sys/kernel/random/boot_id || return 1
    stat_tail="${stat_line##*) }"
    [[ "$stat_tail" != "$stat_line" ]] || return 1
    old_ifs="$IFS"; IFS=' '; set -f
    # shellcheck disable=SC2086
    set -- $stat_tail
    set +f; IFS="$old_ifs"
    [[ "${20:-}" =~ ^[0-9]+$ \
      && "$boot_id" =~ ^[A-Fa-f0-9-]+$ ]] || return 1
    raw="proc:$boot_id:${20}"
  else
    [[ -x /bin/ps ]] && ps_command=/bin/ps
    [[ -n "$ps_command" || ! -x /usr/bin/ps ]] || ps_command=/usr/bin/ps
    [[ -n "$ps_command" ]] || return 1
    raw="$(LC_ALL=C "$ps_command" -o lstart= -p "$pid" 2>/dev/null)" \
      || raw="$(LC_ALL=C "$ps_command" -p "$pid" 2>/dev/null)" \
      || return 1
    [[ -n "$raw" && "$raw" != *$'\t'* ]] || return 1
  fi
  digest="$(printf '%s' "$raw" | cksum 2>/dev/null)" || return 1
  digest="${digest%% *}:${digest#* }"
  digest="${digest%% *}"
  [[ "$digest" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  printf '%s\n' "$digest"
}

_plugin_provenance_lock_owner_matches() { # <lock-dir> <token> <dev:ino>
  local lock_dir="$1" token="$2" expected_identity="$3"
  local owner="$lock_dir/owner" links uid size count value pid process_identity extra
  local expected_value
  [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 1
  [[ "$(_plugin_provenance_stat identity "$lock_dir")" == "$expected_identity" ]] \
    || return 1
  [[ -f "$owner" && ! -L "$owner" ]] || return 1
  links="$(_plugin_provenance_stat links "$owner")" || return 1
  uid="$(_plugin_provenance_stat uid "$owner")" || return 1
  size="$(_plugin_provenance_stat size "$owner")" || return 1
  [[ "$links" == "1" && "$uid" == "$(id -u)" ]] || return 1
  IFS=$'\t' read -r value pid process_identity extra < "$owner" || return 1
  [[ "$value" == "$token" && -z "$extra" ]] || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ \
    && "$process_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  expected_value="$token"$'\t'"$pid"$'\t'"$process_identity"
  [[ "$size" == "$((${#expected_value} + 1))" ]] || return 1
  count="$(find "$lock_dir" -mindepth 1 -maxdepth 1 -print 2>/dev/null \
    | wc -l | tr -d '[:space:]')" || return 1
  [[ "$count" == "1" ]]
}

_plugin_provenance_lock_reclaim_dead() { # <lock-dir>
  local lock_dir="$1" lock_identity token pid recorded_identity extra
  local self_identity observed_identity=""
  [[ -e "$lock_dir" || -L "$lock_dir" ]] || return 0
  [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 1
  lock_identity="$(_plugin_provenance_stat identity "$lock_dir")" || return 1
  IFS=$'\t' read -r token pid recorded_identity extra \
    < "$lock_dir/owner" || return 1
  [[ -n "$token" && -z "$extra" ]] || return 1
  _plugin_provenance_lock_owner_valid \
    "$lock_dir" "$token" "$lock_identity" || return 1
  self_identity="$(_plugin_provenance_process_identity "$$")" || return 1
  if observed_identity="$(_plugin_provenance_process_identity "$pid")"; then
    [[ "$observed_identity" != "$recorded_identity" ]] || return 1
  fi
  [[ -n "$self_identity" ]] || return 1
  _plugin_provenance_lock_cleanup_owned \
    "$lock_dir" "$token" "$lock_identity" || return 1
  [[ ! -e "$lock_dir" && ! -L "$lock_dir" ]]
}

_plugin_provenance_lock_owner_valid() { # <lock-dir> <token> <dev:ino>
  local lock_dir="$1" token="$2" expected_identity="$3" mode
  _plugin_provenance_lock_owner_matches \
    "$lock_dir" "$token" "$expected_identity" || return 1
  mode="$(_plugin_provenance_stat mode "$lock_dir/owner")" || return 1
  _plugin_provenance_file_mode_valid "$mode"
}

_plugin_provenance_lock_cleanup_owned() { # <lock-dir> <token> <dev:ino>
  local lock_dir="$1" token="$2" expected_identity="$3"
  local quarantine="${lock_dir}.cleanup-$token"
  _plugin_provenance_lock_owner_matches \
    "$lock_dir" "$token" "$expected_identity" || return 1
  [[ ! -e "$quarantine" && ! -L "$quarantine" ]] || return 1
  mv "$lock_dir" "$quarantine" || return 1
  _plugin_provenance_lock_owner_matches \
    "$quarantine" "$token" "$expected_identity" || return 1
  rm -f "$quarantine/owner" || return 1
  rmdir "$quarantine"
}

_plugin_provenance_lock_acquire_bound() { # <root> <physical> <dev:ino>
  local root="$1" physical="$2" identity="$3"
  local token="starter-kit-$$-${RANDOM}-${SECONDS:-0}"
  (
    local lock="./$_PLUGIN_PROVENANCE_LOCK_BASENAME" lock_identity
    local process_identity owner_value
    cd -P "$root" 2>/dev/null || exit 1
    [[ "$(pwd -P)" == "$physical" ]] || exit 1
    [[ "$(_plugin_provenance_stat identity .)" == "$identity" ]] || exit 1
    _plugin_provenance_lock_reclaim_dead "$lock" || exit 1
    [[ ! -e "$lock" && ! -L "$lock" ]] || exit 1
    process_identity="$(_plugin_provenance_process_identity "$$")" || exit 1
    (umask 077; mkdir "$lock") 2>/dev/null || exit 1
    lock_identity="$(_plugin_provenance_stat identity "$lock")" || exit 1
    owner_value="$token"$'\t'"$$"$'\t'"$process_identity"
    if ! (umask 077; printf '%s\n' "$owner_value" > "$lock/owner") 2>/dev/null; then
      if [[ ! -e "$lock/owner" && ! -L "$lock/owner" \
        && "$(_plugin_provenance_stat identity "$lock" 2>/dev/null || true)" \
          == "$lock_identity" ]]; then
        rmdir "$lock" 2>/dev/null || true
      else
        _plugin_provenance_lock_cleanup_owned \
          "$lock" "$token" "$lock_identity" >/dev/null 2>&1 || true
      fi
      exit 1
    fi
    if ! _plugin_provenance_lock_owner_valid \
        "$lock" "$token" "$lock_identity" \
      || ! _plugin_provenance_binding_matches \
        "$root" "$physical" "$identity"; then
      _plugin_provenance_lock_cleanup_owned \
        "$lock" "$token" "$lock_identity" >/dev/null 2>&1 || true
      exit 1
    fi
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

_plugin_provenance_mutate() { # <prepare|verify|commit|cancel> <root> <id>
  local operation="$1" root="$2" qualified binding physical identity
  local marker="$_PLUGIN_PROVENANCE_BASENAME"
  case "$operation" in
    prepare|verify|commit|cancel) ;;
    *) return 1 ;;
  esac
  [[ "${DRY_RUN:-false}" != "true" ]] || return 0
  qualified="$(_plugin_provenance_qualify "$3")" || return 1
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

    _plugin_provenance_mutate_locked_body() {
      if [[ -e "./$marker" || -L "./$marker" ]]; then
        before_signature="$(_plugin_provenance_file_signature "./$marker")" \
          || return 1
        existed=true
      fi
      if [[ "$existed" == "true" && "$operation" == "prepare" ]] \
        && jq -e --arg plugin "$qualified" '
          (.installed_by_kit | index($plugin) != null)
          or (((.verified_commit_by_kit // []) | index($plugin)) != null)
        ' \
          "./$marker" >/dev/null 2>&1; then
        return 0
      fi
      if [[ "$existed" == "true" && "$operation" == "verify" ]] \
        && jq -e --arg plugin "$qualified" '
          (.installed_by_kit | index($plugin) != null)
          or (((.verified_commit_by_kit // []) | index($plugin)) != null)
        ' "./$marker" >/dev/null 2>&1; then
        return 0
      fi
      if [[ "$existed" == "true" && "$operation" == "commit" ]] \
        && jq -e --arg plugin "$qualified" '
          (.installed_by_kit | index($plugin) != null)
        ' "./$marker" >/dev/null 2>&1; then
        return 0
      fi
      if [[ "$existed" == "true" && "$operation" == "cancel" ]] \
        && jq -e --arg plugin "$qualified" '
          ((.pending_install_by_kit // []) | index($plugin)) == null
        ' "./$marker" >/dev/null 2>&1; then
        return 0
      fi
      temp_file="$(mktemp "./.${marker}.tmp.XXXXXX")" || return 1
      case "$operation" in
        prepare)
          if [[ "$existed" == "true" ]]; then
            jq --arg plugin "$qualified" '
              if (.installed_by_kit | index($plugin)) != null then
                error("plugin already recorded")
              else
                .pending_install_by_kit = (
                  ((.pending_install_by_kit // []) + [$plugin])
                    | sort | unique)
              end
            ' "./$marker" > "$temp_file" || return 1
          else
            jq -n --arg plugin "$qualified" \
              '{version: 1, installed_by_kit: [],
                pending_install_by_kit: [$plugin]}' \
              > "$temp_file" || return 1
          fi
          ;;
        verify)
          [[ "$existed" == "true" ]] || return 1
          jq --arg plugin "$qualified" '
            if ((.pending_install_by_kit // [])
              | index($plugin)) == null then
              error("plugin install intent was not pending")
            else
              .pending_install_by_kit = ((.pending_install_by_kit // [])
                | map(select(. != $plugin)))
              | .verified_commit_by_kit = (
                ((.verified_commit_by_kit // []) + [$plugin])
                  | sort | unique)
              | if (.pending_install_by_kit | length) == 0
                then del(.pending_install_by_kit) else . end
            end
          ' "./$marker" > "$temp_file" || return 1
          ;;
        commit)
          [[ "$existed" == "true" ]] || return 1
          jq --arg plugin "$qualified" '
            if ((.verified_commit_by_kit // [])
              | index($plugin)) == null then
              error("plugin install was not verified")
            else
              .verified_commit_by_kit = ((.verified_commit_by_kit // [])
                | map(select(. != $plugin)))
              | .installed_by_kit = ((.installed_by_kit + [$plugin])
                | sort | unique)
              | if (.verified_commit_by_kit | length) == 0
                then del(.verified_commit_by_kit) else . end
            end
          ' "./$marker" > "$temp_file" || return 1
          ;;
        cancel)
          [[ "$existed" == "true" ]] || return 1
          jq --arg plugin "$qualified" '
            .pending_install_by_kit = ((.pending_install_by_kit // [])
              | map(select(. != $plugin)))
            | if (.pending_install_by_kit | length) == 0
              then del(.pending_install_by_kit) else . end
          ' "./$marker" > "$temp_file" || return 1
          ;;
      esac
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
      case "$operation" in
        prepare)
          jq -e --arg plugin "$qualified" \
            '(.pending_install_by_kit // []) | index($plugin) != null' \
            "./$marker" >/dev/null 2>&1
          ;;
        verify)
          jq -e --arg plugin "$qualified" '
            ((.verified_commit_by_kit // []) | index($plugin) != null)
            and (((.pending_install_by_kit // [])
              | index($plugin)) == null)
          ' "./$marker" >/dev/null 2>&1
          ;;
        commit)
          jq -e --arg plugin "$qualified" '
            (.installed_by_kit | index($plugin) != null)
            and (((.verified_commit_by_kit // [])
              | index($plugin)) == null)
          ' "./$marker" >/dev/null 2>&1
          ;;
        cancel)
          jq -e --arg plugin "$qualified" '
            ((.pending_install_by_kit // []) | index($plugin)) == null
          ' "./$marker" >/dev/null 2>&1
          ;;
      esac
    }

    _plugin_provenance_mutate_locked_body || operation_rc=$?
    [[ -z "$temp_file" ]] || rm -f "$temp_file" 2>/dev/null || true
    _plugin_provenance_lock_release_bound \
      "$root" "$physical" "$identity" "$lock_token" "$lock_identity" \
      || release_rc=$?
    trap - HUP INT TERM
    [[ "$operation_rc" -eq 0 && "$release_rc" -eq 0 ]]
  )
}

_plugin_provenance_prepare() { # <root> <qualified-id>
  _plugin_provenance_mutate prepare "$1" "$2"
}

_plugin_provenance_verify() { # <root> <qualified-id>
  _plugin_provenance_mutate verify "$1" "$2"
}

_plugin_provenance_record() { # <root> <qualified-id>
  _plugin_provenance_mutate commit "$1" "$2"
}

_plugin_provenance_cancel_pending() { # <root> <qualified-id>
  _plugin_provenance_mutate cancel "$1" "$2"
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
