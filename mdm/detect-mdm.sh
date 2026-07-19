#!/bin/bash -p
# mdm/detect-mdm.sh - MDM receipt and deployed-state compliance detection.

# Bash imports functions before executing the first script line.  Start in
# privileged mode from the shebang, validate and snapshot the script before
# root sources it, then discard the inherited environment.  There is no
# argv/env bypass token: every directly executed invocation crosses this
# boundary.
_mdm_launcher_mode_safe() {
  local _mode="$1"
  [[ "$_mode" =~ ^[0-7]+$ ]] || return 1
  while [[ ${#_mode} -gt 3 ]]; do _mode="${_mode#?}"; done
  while [[ ${#_mode} -lt 3 ]]; do _mode="0$_mode"; done
  case "$_mode" in *[2367]|?[2367]?) return 1 ;; esac
  return 0
}

_mdm_username_is_safe() {
  local _user="$1"
  [[ ${#_user} -ge 1 && ${#_user} -le 32 ]] || return 1
  [[ "$_user" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*([.@][A-Za-z0-9_-]+)*$ ]] \
    || return 1
  case "$_user" in
    _[Uu][Nn][Rr][Ee][Ss][Oo][Ll][Vv][Ee][Dd]) return 1 ;;
  esac
  return 0
}

_mdm_launcher_stat_owner() {
  if [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]]; then
    /usr/bin/stat -f '%u' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%u' "$1" 2>/dev/null
  fi
}

_mdm_launcher_stat_mode() {
  if [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]]; then
    # %Lp omits setuid/setgid/sticky bits; prefix it with %Mp so 01777 is
    # distinguishable from an unsafe ordinary 0777 directory.
    /usr/bin/stat -f '%Mp%Lp' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%a' "$1" 2>/dev/null
  fi
}

_mdm_launcher_acl_safe() {
  local _path="$1" _listing _first _permissions
  [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]] || return 0
  _listing="$(LC_ALL=C /bin/ls -lde "$_path" 2>/dev/null)" || return 1
  _first="${_listing%%$'\n'*}"
  _permissions="${_first%%[[:space:]]*}"
  [[ "$_first" == *[[:space:]]* \
    && "$_permissions" =~ ^[-bcdlps][rwxStTs-]{9}[@+]?$ ]] || return 1
  [[ "$_permissions" != *+* && "$_listing" != *$'\n'* ]]
}

_mdm_launcher_path_trusted() {
  local _script="$1" _dir _base _canonical _path _owner _mode
  [[ -f "$_script" && ! -L "$_script" ]] || return 1
  case "$_script" in
    */*) _dir="${_script%/*}"; _base="${_script##*/}" ;;
    *) _dir=.; _base="$_script" ;;
  esac
  [[ -n "$_dir" ]] || _dir=/
  _canonical="$(builtin cd -P -- "$_dir" 2>/dev/null && printf '%s' "$PWD")" \
    || return 1
  [[ "$_canonical" == / ]] && _canonical=""
  _canonical="$_canonical/$_base"
  [[ -f "$_canonical" && ! -L "$_canonical" ]] || return 1

  _path="$_canonical"
  while :; do
    [[ ! -L "$_path" ]] || return 1
    _owner="$(_mdm_launcher_stat_owner "$_path" || true)"
    _mode="$(_mdm_launcher_stat_mode "$_path" || true)"
    [[ "$_owner" == 0 ]] || return 1
    if ! _mdm_launcher_mode_safe "$_mode"; then
      # A root-owned sticky directory protects root-owned entries from rename
      # and is the only writable component accepted in the physical chain.
      [[ -d "$_path" && "$_mode" == 1777 ]] || return 1
    fi
    _mdm_launcher_acl_safe "$_path" || return 1
    [[ "$_path" == / ]] && break
    _path="${_path%/*}"
    [[ -n "$_path" ]] || _path=/
  done
  _MDM_LAUNCHER_PHYSICAL="$_canonical"
  return 0
}

_mdm_launcher_cleanup_snapshot() {
  local _path
  for _path in "${_mdm_launcher_inflight:-}" "${_mdm_clean_snapshot:-}"; do
    [[ -z "$_path" ]] || /bin/rm -f "$_path"
  done
}

_mdm_launcher_exit_on_signal() { # <signal> <exit-code>
  local _signal="$1" _rc="$2" _pid _pgid
  _pid="${_mdm_clean_child_pid:-}"
  _pgid="${_mdm_clean_child_pgid:-}"
  if [[ ! "$_pid" =~ ^[1-9][0-9]*$ \
    && "${_mdm_clean_child_starting:-0}" == 1 ]]; then
    _pid="$(jobs -p 2>/dev/null)"
    _pgid="$_pid"
  fi
  if [[ "$_pid" =~ ^[1-9][0-9]*$ ]]; then
    if [[ "$_pgid" =~ ^[1-9][0-9]*$ && "$_pgid" == "$_pid" ]]; then
      /bin/kill "-$_signal" "-$_pgid" 2>/dev/null \
        || /bin/kill "-$_signal" "$_pid" 2>/dev/null \
        || true
    else
      /bin/kill "-$_signal" "$_pid" 2>/dev/null || true
    fi
    wait "$_pid" 2>/dev/null || true
  fi
  _mdm_launcher_cleanup_snapshot
  exit "$_rc"
}

_mdm_launcher_snapshot() { # <source> <output-variable>
  local _source="$1" _output="$2" _before _opened _tmp_base _old_umask
  local _mdm_launcher_inflight=""
  [[ "$_output" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  printf -v "$_output" '%s' ""
  if [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]]; then
    _before="$(/usr/bin/stat -f '%i:%z' "$_source" 2>/dev/null)" || return 1
  else
    _before="$(/usr/bin/stat -c '%i:%s' "$_source" 2>/dev/null)" || return 1
  fi
  exec 9<"$_source" || return 1
  if [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]]; then
    _opened="$(/usr/bin/stat -Lf '%i:%z' /dev/fd/9 2>/dev/null)" \
      || { exec 9<&-; return 1; }
    _tmp_base=/private/tmp
  else
    _opened="$(/usr/bin/stat -Lc '%i:%s' /dev/fd/9 2>/dev/null)" \
      || { exec 9<&-; return 1; }
    _tmp_base=/tmp
  fi
  [[ "$_before" == "$_opened" ]] || { exec 9<&-; return 1; }
  _old_umask="$(umask)"
  umask 077
  _mdm_launcher_inflight="$(
    /usr/bin/mktemp "$_tmp_base/claude-kit-mdm-launcher.XXXXXX"
  )" \
    || { umask "$_old_umask"; exec 9<&-; return 1; }
  umask "$_old_umask"
  # Publish the pathname to the already-trapped parent before copying bytes.
  # The dynamically scoped inflight value covers the few builtins before this
  # assignment, so EXIT/HUP/INT/TERM always see the file once mktemp returns.
  if ! printf -v "$_output" '%s' "$_mdm_launcher_inflight"; then
    /bin/rm -f "$_mdm_launcher_inflight"
    _mdm_launcher_inflight=""
    return 1
  fi
  if ! /bin/cat <&9 > "$_mdm_launcher_inflight"; then
    exec 9<&-
    /bin/rm -f "$_mdm_launcher_inflight"
    printf -v "$_output" '%s' ""
    _mdm_launcher_inflight=""
    return 1
  fi
  exec 9<&-
  if ! /bin/chmod 500 "$_mdm_launcher_inflight"; then
    /bin/rm -f "$_mdm_launcher_inflight"
    printf -v "$_output" '%s' ""
    _mdm_launcher_inflight=""
    return 1
  fi
  _mdm_launcher_inflight=""
  return 0
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  _mdm_clean_home=/var/root
  _mdm_clean_script="$0"
  _mdm_clean_snapshot=""
  _mdm_clean_child_pid=""
  _mdm_clean_child_pgid=""
  _mdm_clean_child_starting=0
  trap '_mdm_launcher_cleanup_snapshot' EXIT
  trap '_mdm_launcher_exit_on_signal HUP 129' HUP
  trap '_mdm_launcher_exit_on_signal INT 130' INT
  trap '_mdm_launcher_exit_on_signal TERM 143' TERM
  if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
    _mdm_clean_home="${HOME:-/tmp}"
  else
    if ! _mdm_launcher_path_trusted "$_mdm_clean_script"; then
      printf 'MDM detector launcher path is not trusted\n' >&2
      exit 50
    fi
    _mdm_clean_script="$_MDM_LAUNCHER_PHYSICAL"
  fi
  if ! _mdm_launcher_snapshot "$_mdm_clean_script" _mdm_clean_snapshot; then
    printf 'MDM detector launcher snapshot failed\n' >&2
    exit 50
  fi
  _mdm_clean_script="$_mdm_clean_snapshot"
  _mdm_clean_rc=0
  _mdm_clean_monitor_was_on=false
  case $- in *m*) _mdm_clean_monitor_was_on=true ;; esac
  set -m
  _mdm_clean_child_starting=1
  /usr/bin/env -i \
    "HOME=$_mdm_clean_home" \
    'PATH=/usr/bin:/bin:/usr/sbin:/sbin' \
    'LC_ALL=C' \
    /bin/bash --noprofile --norc -p -c '
      _mdm_script=$1
      shift
      trap '\''/bin/rm -f "$_mdm_script"'\'' EXIT
      trap '\''/bin/rm -f "$_mdm_script"; exit 129'\'' HUP
      trap '\''/bin/rm -f "$_mdm_script"; exit 130'\'' INT
      trap '\''/bin/rm -f "$_mdm_script"; exit 143'\'' TERM
      if ! . "$_mdm_script"; then
        /bin/rm -f "$_mdm_script"
        exit 50
      fi
      /bin/rm -f "$_mdm_script"
      trap - EXIT HUP INT TERM
      trap "_mdm_cleanup_active_workspace" EXIT
      trap "_mdm_cleanup_active_workspace; exit 129" HUP
      trap "_mdm_cleanup_active_workspace; exit 130" INT
      trap "_mdm_cleanup_active_workspace; exit 143" TERM
      mdm_detect_main "$@"
      exit $?
    ' mdm-detect-clean "$_mdm_clean_script" "$@" &
  _mdm_clean_child_pid=$!
  _mdm_clean_child_pgid="$_mdm_clean_child_pid"
  _mdm_clean_child_starting=0
  [[ "$_mdm_clean_monitor_was_on" == true ]] || set +m
  wait "$_mdm_clean_child_pid" || _mdm_clean_rc=$?
  _mdm_clean_child_pid=""
  _mdm_clean_child_pgid=""
  _mdm_launcher_cleanup_snapshot
  trap - EXIT HUP INT TERM
  exit "$_mdm_clean_rc"
fi

# Everything below this line runs in Bash: either the clean production shell
# above or a source-only unit-test shell.
set -o pipefail

_MDM_DETECT_TEST_MODE=0
if [[ "${MDM_SOURCE_ONLY:-0}" == "1" ]]; then
  _MDM_DETECT_TEST_MODE=1
fi

_mdm_test_value() { # <variable-name>
  [[ "$_MDM_DETECT_TEST_MODE" == "1" ]] || return 1
  local _name="$1"
  [[ -n "${!_name:-}" ]] || return 1
  printf '%s' "${!_name}"
}

_mdm_is_darwin() {
  [[ "$(/usr/bin/uname -s 2>/dev/null)" == "Darwin" ]]
}

_mdm_detect_system_python() {
  local _python=/usr/bin/python3 _details
  if [[ "$_MDM_DETECT_TEST_MODE" == 1 ]]; then
    _python="${MDM_DETECT_PYTHON_OVERRIDE:-/usr/bin/python3}"
    [[ "$_python" == /* && -x "$_python" && ! -L "$_python" ]] || return 1
    printf '%s' "$_python"
    return 0
  fi
  [[ -x "$_python" && ! -L "$_python" && -x /usr/bin/codesign ]] || return 1
  /usr/bin/codesign --verify --strict "$_python" >/dev/null 2>&1 || return 1
  _details="$(/usr/bin/codesign -dv --verbose=4 "$_python" 2>&1)" || return 1
  printf '%s\n' "$_details" | /usr/bin/grep -q '^Platform identifier=' || return 1
  printf '%s\n' "$_details" | /usr/bin/grep -qx 'Authority=Software Signing' || return 1
  printf '%s\n' "$_details" | /usr/bin/grep -qx 'Authority=Apple Root CA' || return 1
  printf '%s' "$_python"
}

_mdm_json_query() { # <file> <key-path> <raw|count|type> [expected-type]
  local _file="$1" _key="$2" _operation="$3" _expected="${4:-}"
  local _python
  _python="$(_mdm_detect_system_python)" || return 1
  "$_python" -I -B - "$_file" "$_key" "$_operation" "$_expected" <<'PY'
import json
import math
import sys

path, key_path, operation, expected = sys.argv[1:]

def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate object key")
        value[key] = item
    return value

def reject_constant(_value):
    raise ValueError("non-finite JSON number")

def control_free(value):
    return not any(ord(char) < 32 or 127 <= ord(char) <= 159
                   or 0xD800 <= ord(char) <= 0xDFFF for char in value)

try:
    with open(path, "rb") as handle:
        source = handle.read().decode("utf-8", errors="strict")
    value = json.loads(source, object_pairs_hook=unique_object,
                       parse_constant=reject_constant)
    for segment in key_path.split("."):
        if isinstance(value, list):
            if not segment.isascii() or not segment.isdecimal():
                raise ValueError("invalid array index")
            value = value[int(segment)]
        elif isinstance(value, dict):
            value = value[segment]
        else:
            raise ValueError("invalid key path")

    if operation == "type":
        valid = {
            "integer": type(value) is int,
            "string": type(value) is str,
            "bool": type(value) is bool,
            "array": type(value) is list,
        }
        if expected not in valid or not valid[expected]:
            raise ValueError("JSON type mismatch")
        raise SystemExit(0)
    if operation == "count":
        if type(value) is not list:
            raise ValueError("JSON value is not an array")
        output = str(len(value))
    elif operation == "raw":
        if type(value) is str:
            if not control_free(value):
                raise ValueError("control character in JSON scalar")
            output = value
        elif type(value) is bool:
            output = "true" if value else "false"
        elif type(value) is int:
            output = str(value)
        elif type(value) is float and math.isfinite(value):
            output = json.dumps(value, allow_nan=False, separators=(",", ":"))
        else:
            raise ValueError("JSON value is not a raw scalar")
    else:
        raise ValueError("invalid JSON query operation")
    sys.stdout.buffer.write(output.encode("utf-8") + b"\n")
except (IndexError, KeyError, OSError, RecursionError, UnicodeError,
        ValueError, json.JSONDecodeError):
    raise SystemExit(1)
PY
}

# Keep the producer's terminator distinguishable from scalar bytes until the
# control-free contract has been checked.  The outer callers may safely use
# command substitution because accepted values cannot end in a newline.
_mdm_json_capture_scalar() { # <file> <key-path> <raw|count>
  local _raw _rc=0
  _raw="$({
    _mdm_json_query "$@" || _rc=$?
    printf '\036'
    exit "$_rc"
  })" || return 1
  [[ "$_raw" == *$'\036' ]] || return 1
  _raw="${_raw%$'\036'}"
  [[ "$_raw" == *$'\n' ]] || return 1
  _raw="${_raw%$'\n'}"
  [[ ! "$_raw" =~ [[:cntrl:]] ]] || return 1
  printf '%s' "$_raw"
}

_mdm_json_get() { # <file> <key-path>
  _mdm_json_capture_scalar "$1" "$2" raw
}

_mdm_json_array_count() { # <file> <key-path>
  _mdm_json_capture_scalar "$1" "$2" count
}

_mdm_json_array_get() { # <file> <key-path> <index>
  [[ "$3" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  _mdm_json_capture_scalar "$1" "${2}.${3}" raw
}

_mdm_json_type_is() { # <file> <key-path> <integer|string|bool|array>
  case "$3" in integer|string|bool|array) : ;; *) return 1 ;; esac
  _mdm_json_query "$1" "$2" type "$3" >/dev/null 2>&1
}

_mdm_issuer_json_is_canonical() { # <file> <receipt|component|deployment>
  local _file="$1" _kind="$2" _python
  case "$_kind" in receipt|component|deployment) : ;; *) return 1 ;; esac
  _python="$(_mdm_detect_system_python)" || return 1
  "$_python" -I -B - "$_file" "$_kind" <<'PY'
import json
import sys

path, kind = sys.argv[1:]

def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate object key")
        value[key] = item
    return value

def reject_constant(_value):
    raise ValueError("non-finite JSON number")

def control_free(value):
    if isinstance(value, str):
        return not any(ord(char) < 32 or 127 <= ord(char) <= 159
                       or 0xD800 <= ord(char) <= 0xDFFF for char in value)
    if isinstance(value, list):
        return all(control_free(item) for item in value)
    if isinstance(value, dict):
        return all(control_free(key) and control_free(item)
                   for key, item in value.items())
    return True

def exact_types(value, strings=(), integers=(), arrays=(), booleans=()):
    return (all(type(value[key]) is str for key in strings)
            and all(type(value[key]) is int for key in integers)
            and all(type(value[key]) is list for key in arrays)
            and all(type(value[key]) is bool for key in booleans))

def quote(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

try:
    with open(path, "rb") as handle:
        actual = handle.read()
    text = actual.decode("utf-8", errors="strict")
    value = json.loads(text, object_pairs_hook=unique_object,
                       parse_constant=reject_constant)
    if type(value) is not dict or not control_free(value):
        raise ValueError("invalid JSON root")

    if kind == "receipt":
        order = (
            "schema_version", "kit_version", "git_ref", "resolved_sha",
            "install_dir", "required_components", "profile", "language",
            "manifest_path", "manifest_sha256", "deployment_sha256",
            "policy_sha256", "component_manifest_path",
            "component_manifest_sha256", "target_user", "target_uid",
            "target_generated_uid", "result", "exit_code", "partial",
            "timestamp", "log_path",
        )
        strings = tuple(key for key in order if key not in {
            "schema_version", "required_components", "target_uid",
            "exit_code", "partial",
        })
        if (set(value) != set(order)
                or not exact_types(value, strings=strings,
                                   integers=("schema_version", "target_uid",
                                             "exit_code"),
                                   arrays=("required_components", "partial"))
                or value["schema_version"] != 3
                or not all(type(item) is str
                           for item in value["required_components"])):
            raise ValueError("invalid receipt shape")
        lines = ["{"]
        for index, key in enumerate(order):
            if type(value[key]) is str:
                rendered = quote(value[key])
            elif type(value[key]) is int:
                rendered = str(value[key])
            else:
                rendered = json.dumps(value[key], ensure_ascii=False,
                                      separators=(",", ":"), allow_nan=False)
            comma = "," if index + 1 < len(order) else ""
            lines.append(f'  {quote(key)}: {rendered}{comma}')
        expected = ("\n".join(lines) + "\n}\n").encode("utf-8")

    elif kind == "component":
        outer = (
            "schema_version", "target_user", "target_uid",
            "target_generated_uid", "policy_sha256", "entries",
        )
        entry_keys = {"component", "kind", "path", "sha256"}
        entries = value.get("entries")
        if (set(value) != set(outer)
                or not exact_types(value,
                                   strings=("target_user",
                                            "target_generated_uid",
                                            "policy_sha256"),
                                   integers=("schema_version", "target_uid"),
                                   arrays=("entries",))
                or value["schema_version"] != 1):
            raise ValueError("invalid component manifest shape")
        for entry in entries:
            if (type(entry) is not dict or set(entry) != entry_keys
                    or not all(type(entry[key]) is str for key in entry_keys)):
                raise ValueError("invalid component entry shape")
        lines = [
            "{",
            '  "schema_version": 1,',
            f'  "target_user": {quote(value["target_user"])},',
            f'  "target_uid": {value["target_uid"]},',
            f'  "target_generated_uid": '
            f'{quote(value["target_generated_uid"])},',
            f'  "policy_sha256": {quote(value["policy_sha256"])},',
            '  "entries": [',
        ]
        for index, entry in enumerate(entries):
            rendered = json.dumps(entry, ensure_ascii=True, sort_keys=True,
                                  separators=(",", ":"), allow_nan=False)
            comma = "," if index + 1 < len(entries) else ""
            lines.append(f"    {rendered}{comma}")
        lines.extend(["  ]", "}"])
        expected = ("\n".join(lines) + "\n").encode("utf-8")

    else:
        order = (
            "version", "timestamp", "kit_version", "kit_commit", "profile",
            "language", "editor", "commit_attribution", "new_init",
            "plugins", "codex_plugin", "files", "cleanup_paths",
            "mdm_absent_files", "mdm_managed", "snapshot_dir", "claude_dir",
            "policy_sha256",
        )
        strings = tuple(key for key in order if key not in {
            "files", "cleanup_paths", "mdm_absent_files", "mdm_managed",
        })
        arrays = ("files", "cleanup_paths", "mdm_absent_files")
        if (set(value) != set(order)
                or not exact_types(value, strings=strings, arrays=arrays,
                                   booleans=("mdm_managed",))
                or not all(type(item) is str
                           for key in arrays for item in value[key])):
            raise ValueError("invalid deployment manifest shape")
        ordered = {key: value[key] for key in order}
        expected = (json.dumps(ordered, ensure_ascii=False, indent=2,
                               separators=(",", ": "), allow_nan=False)
                    + "\n").encode("utf-8")

    if actual != expected:
        raise ValueError("non-canonical JSON bytes")
except (KeyError, OSError, RecursionError, UnicodeError, ValueError,
        json.JSONDecodeError):
    raise SystemExit(1)
PY
}

_mdm_stat_owner() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%Su' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%U' "$1" 2>/dev/null
  fi
}

_mdm_stat_uid() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%u' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%u' "$1" 2>/dev/null
  fi
}

_mdm_stat_gid() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%g' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%g' "$1" 2>/dev/null
  fi
}

_mdm_stat_mode() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%Lp' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%a' "$1" 2>/dev/null
  fi
}

_mdm_stat_identity() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%i:%HT:%z' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%i:%F:%s' "$1" 2>/dev/null
  fi
}

_mdm_stat_metadata() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%i:%HT:%z:%u:%Mp%Lp:%l' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%i:%F:%s:%u:%a:%h' "$1" 2>/dev/null
  fi
}

_mdm_stat_fd_identity() {
  local _fd="$1"
  if _mdm_is_darwin; then
    /usr/bin/stat -Lf '%i:%HT:%z' "/dev/fd/$_fd" 2>/dev/null
  else
    /usr/bin/stat -Lc '%i:%F:%s' "/dev/fd/$_fd" 2>/dev/null
  fi
}

_mdm_stat_dir_identity() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%d:%i:%HT' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%d:%i:%F' "$1" 2>/dev/null
  fi
}

_mdm_mode_normalize() {
  local _mode="$1"
  [[ "$_mode" =~ ^[0-7]{1,4}$ ]] || return 1
  while [[ ${#_mode} -lt 4 ]]; do _mode="0$_mode"; done
  printf '%s' "$_mode"
}

_mdm_mode_is_safe() {
  local _mode="$1"
  [[ "$_mode" =~ ^[0-7]{1,4}$ ]] || return 1
  while [[ ${#_mode} -lt 3 ]]; do _mode="0$_mode"; done
  (( (8#$_mode & 8#022) == 0 ))
}

_mdm_has_acl() {
  _mdm_is_darwin || return 1
  ! _mdm_launcher_acl_safe "$1"
}

_mdm_expected_trust_owner() {
  if [[ "$_MDM_DETECT_TEST_MODE" == "1" ]]; then
    _mdm_test_value MDM_DETECT_EXPECTED_OWNER_OVERRIDE
  else
    printf 'root'
  fi
}

_mdm_receipt_trust_base() {
  if [[ "$_MDM_DETECT_TEST_MODE" == "1" ]]; then
    # Tests must opt in to a concrete trust root.  An arbitrary receipt path is
    # never trusted merely because source-only mode is active.
    _mdm_test_value MDM_DETECT_TRUST_BASE_OVERRIDE
  else
    printf '%s' '/Library/Application Support'
  fi
}

_mdm_trusted_component() { # <path> <owner> <dir|file>
  local _path="$1" _owner="$2" _kind="$3" _actual_owner _mode _metadata
  [[ -e "$_path" && ! -L "$_path" ]] || return 1
  case "$_kind" in
    dir) [[ -d "$_path" ]] || return 1 ;;
    file)
      [[ -f "$_path" ]] || return 1
      _metadata="$(_mdm_stat_metadata "$_path")" || return 1
      [[ "${_metadata##*:}" == 1 ]] || return 1 ;;
    *) return 1 ;;
  esac
  _actual_owner="$(_mdm_stat_owner "$_path")" || return 1
  [[ "$_actual_owner" == "$_owner" ]] || return 1
  _mode="$(_mdm_stat_mode "$_path")" || return 1
  _mdm_mode_is_safe "$_mode" || return 1
  ! _mdm_has_acl "$_path" || return 1
}

_mdm_verify_trusted_dir_chain() { # <target-dir> <trust-base> <owner>
  local _target="$1" _base="$2" _owner="$3" _rest _current _segment
  [[ -n "$_base" && "$_base" == /* ]] || return 1
  case "$_target" in "$_base"|"$_base"/*) : ;; *) return 1 ;; esac
  [[ "$(_mdm_canonical_dir "$_base")" == "$_base" ]] || return 1
  _mdm_trusted_component "$_base" "$_owner" dir || return 1
  _rest="${_target#"$_base"}"
  _current="$_base"
  while [[ -n "$_rest" ]]; do
    _rest="${_rest#/}"
    [[ -n "$_rest" ]] || break
    _segment="${_rest%%/*}"
    [[ -n "$_segment" && ! "$_segment" =~ [[:cntrl:]] ]] || return 1
    _rest="${_rest#"$_segment"}"
    _current="$_current/$_segment"
    _mdm_trusted_component "$_current" "$_owner" dir || return 1
  done
  [[ "$(_mdm_canonical_dir "$_target")" == "$_target" ]]
}

_mdm_verify_trusted_dir_chain_exact_mode() {
  # <target-dir> <trust-base> <owner> <mode> [gid]
  local _target="$1" _base="$2" _owner="$3" _expected="$4"
  local _expected_gid="${5:-}" _rest _current _segment _mode
  _expected="$(_mdm_mode_normalize "$_expected")" || return 1
  [[ -z "$_expected_gid" || "$_expected_gid" =~ ^[0-9]+$ ]] || return 1
  _mdm_verify_trusted_dir_chain "$_target" "$_base" "$_owner" || return 1
  _rest="${_target#"$_base"}"
  _current="$_base"
  while :; do
    _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_current")")" \
      || return 1
    [[ "$_mode" == "$_expected" ]] || return 1
    [[ -z "$_expected_gid" \
      || "$(_mdm_stat_gid "$_current")" == "$_expected_gid" ]] || return 1
    [[ -n "$_rest" ]] || break
    _rest="${_rest#/}"
    _segment="${_rest%%/*}"
    [[ -n "$_segment" ]] || return 1
    _rest="${_rest#"$_segment"}"
    _current="$_current/$_segment"
  done
}

# The runtime issuer requires the fixed macOS system ancestors to remain
# canonical root-owned ACL-free directories with their platform mode, rather
# than accepting every non-writable/searchable variant such as 0711.
_mdm_runtime_system_ancestors_are_trusted() {
  local _owner _dir _mode
  [[ "$_MDM_DETECT_TEST_MODE" != 1 ]] || return 0
  _owner="$(_mdm_expected_trust_owner)" || return 1
  for _dir in / /Library "/Library/Application Support"; do
    [[ "$(_mdm_canonical_dir "$_dir")" == "$_dir" ]] || return 1
    _mdm_trusted_component "$_dir" "$_owner" dir || return 1
    _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_dir")")" \
      || return 1
    [[ "$_mode" == 0755 ]] || return 1
  done
}

_mdm_receipt_is_trusted() { # <receipt> <target-user>
  local _receipt="$1" _user="$2" _base _owner _receipt_dir _canonical _mode
  _base="$(_mdm_receipt_trust_base)" || return 1
  _owner="$(_mdm_expected_trust_owner)" || return 1
  _receipt_dir="$_base/ClaudeCodeStarterKit"
  [[ "$_receipt" == "$_receipt_dir/receipt-$_user.json" ]] || return 1

  if [[ "$_MDM_DETECT_TEST_MODE" != "1" ]]; then
    _mdm_trusted_component / root dir || return 1
    _mdm_trusted_component /Library root dir || return 1
  fi
  _mdm_verify_trusted_dir_chain "$_receipt_dir" "$_base" "$_owner" || return 1
  _mdm_trusted_component "$_receipt" "$_owner" file || return 1
  _mode="$(_mdm_stat_mode "$_receipt")" || return 1
  [[ "$(_mdm_mode_normalize "$_mode")" == 0600 ]] || return 1
  _canonical="$(_mdm_canonical_file "$_receipt")" || return 1
  [[ "$_canonical" == "$_receipt" ]]
}

_mdm_detect_read_user_home_record() {
  /usr/bin/dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null
}

_mdm_detect_parse_user_home() {
  LC_ALL=C /usr/bin/awk '
    BEGIN { state = "key"; bad = 0 }

    state == "key" && $0 == "NFSHomeDirectory:" {
      state = "continuation"
      next
    }

    state == "key" && $0 ~ /^NFSHomeDirectory:[ \t]/ {
      value = substr($0, length("NFSHomeDirectory:") + 2)
      if (value ~ /[[:space:]]/) bad = 1
      state = "done"
      next
    }

    state == "continuation" && $0 ~ /^[ \t]/ {
      value = substr($0, 2)
      state = "done"
      next
    }

    { bad = 1 }

    END {
      if (!bad && state == "done" && value ~ /^\// \
          && value !~ /[[:cntrl:]]/) {
        print value
        exit 0
      }
      exit 1
    }
  '
}

_mdm_detect_user_home() {
  local _user="$1" _override _home
  if _override="$(_mdm_test_value MDM_DETECT_HOME_OVERRIDE)"; then
    printf '%s' "$_override"
    return 0
  fi
  _home="$(_mdm_detect_read_user_home_record "$_user" \
    | _mdm_detect_parse_user_home)" || return 1
  printf '%s' "$_home"
}

_mdm_detect_read_user_uid_record() {
  /usr/bin/dscl . -read "/Users/$1" UniqueID 2>/dev/null
}

_mdm_detect_parse_user_uid() {
  LC_ALL=C /usr/bin/awk '
    BEGIN { state = "key"; bad = 0 }

    state == "key" && $0 == "UniqueID:" {
      state = "continuation"
      next
    }

    state == "key" && $0 ~ /^UniqueID:[ \t]/ {
      value = substr($0, length("UniqueID:") + 2)
      state = "done"
      next
    }

    state == "continuation" && $0 ~ /^[ \t]/ {
      value = substr($0, 2)
      state = "done"
      next
    }

    { bad = 1 }

    END {
      if (!bad && state == "done" && value ~ /^[0-9]+$/ \
          && length(value) <= 10 \
          && !(length(value) > 1 && substr(value, 1, 1) == "0")) {
        print value
        exit 0
      }
      exit 1
    }
  '
}

_mdm_detect_read_local_identity_record() {
  /usr/bin/dscl . -read "/Users/$1" UniqueID GeneratedUID 2>/dev/null
}

_mdm_detect_read_search_identity_record() {
  /usr/bin/dscl /Search -read "/Users/$1" UniqueID GeneratedUID 2>/dev/null
}

_mdm_detect_parse_identity_tuple() {
  LC_ALL=C /usr/bin/awk '
    BEGIN { pending = ""; bad = 0; uid_seen = 0; generated_seen = 0 }

    pending != "" && $0 ~ /^[ \t]/ {
      value = substr($0, 2)
      if (pending == "uid") { uid = value; uid_seen++ }
      else { generated = value; generated_seen++ }
      pending = ""
      next
    }

    pending != "" { bad = 1; pending = "" }

    $0 == "UniqueID:" { pending = "uid"; next }
    $0 == "GeneratedUID:" { pending = "generated"; next }

    $0 ~ /^UniqueID:[ \t]/ {
      uid = substr($0, length("UniqueID:") + 2)
      uid_seen++
      next
    }

    $0 ~ /^GeneratedUID:[ \t]/ {
      generated = substr($0, length("GeneratedUID:") + 2)
      generated_seen++
      next
    }

    { bad = 1 }

    END {
      generated = toupper(generated)
      if (!bad && pending == "" && uid_seen == 1 && generated_seen == 1 \
          && uid ~ /^[0-9]+$/ && length(uid) <= 10 \
          && !(length(uid) > 1 && substr(uid, 1, 1) == "0") \
          && length(generated) == 36 && generated ~ /^[0-9A-F-]+$/) {
        printf "%s\t%s", uid, generated
        exit 0
      }
      exit 1
    }
  '
}

_mdm_detect_target_identity_tuple() {
  local _user="$1" _uid_override _generated_override _local _search
  local _uid _generated
  if _uid_override="$(_mdm_test_value MDM_DETECT_EXPECTED_UID_OVERRIDE)" \
    && _generated_override="$(_mdm_test_value \
      MDM_DETECT_GENERATED_UID_OVERRIDE)"; then
    _local="$_uid_override"$'\t'"$_generated_override"
    _search="$_local"
  else
    _local="$(_mdm_detect_read_local_identity_record "$_user" \
      | _mdm_detect_parse_identity_tuple)" || return 1
    _search="$(_mdm_detect_read_search_identity_record "$_user" \
      | _mdm_detect_parse_identity_tuple)" || return 1
  fi
  [[ "$_local" == "$_search" ]] || return 1
  _uid="${_local%%$'\t'*}"
  _generated="${_local#*$'\t'}"
  [[ "$_uid" =~ ^[0-9]+$ && "$_uid" -ge 501 && ${#_uid} -le 10 ]] \
    || return 1
  [[ "$_generated" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ \
    && "$_generated" != 00000000-0000-0000-0000-000000000000 ]] \
    || return 1
  printf '%s\t%s' "$_uid" "$_generated"
}

_mdm_detect_target_binding_tuple() { # <target-user>
  local _user="$1" _identity _home
  _identity="$(_mdm_detect_target_identity_tuple "$_user")" || return 1
  _home="$(_mdm_detect_user_home "$_user")" || return 1
  [[ "$_home" == /* && ! "$_home" =~ [[:cntrl:]] ]] || return 1
  printf '%s\t%s' "$_identity" "$_home"
}

_mdm_detect_user_uid() {
  local _tuple
  _tuple="$(_mdm_detect_target_identity_tuple "$1")" || return 1
  printf '%s' "${_tuple%%$'\t'*}"
}

_mdm_detect_user_generated_uid() {
  local _tuple
  _tuple="$(_mdm_detect_target_identity_tuple "$1")" || return 1
  printf '%s' "${_tuple#*$'\t'}"
}

_mdm_detect_read_console_user_record() {
  printf 'show State:/Users/ConsoleUser\n' | /usr/sbin/scutil 2>/dev/null
}

_mdm_detect_parse_console_user_record() {
  LC_ALL=C /usr/bin/awk '
    BEGIN { seen = 0; bad = 0 }

    /^[[:space:]]*Name[[:space:]]*:/ {
      remainder = $0
      sub(/^[[:space:]]*Name[[:space:]]*:/, "", remainder)
      if (seen || remainder !~ /^ [^[:space:][:cntrl:]]+$/) bad = 1
      value = substr(remainder, 2)
      seen = 1
    }

    END {
      if (!bad && seen == 1) {
        print value
        exit 0
      }
      exit 1
    }
  '
}

_mdm_detect_console_user() {
  local _override _user
  if _override="$(_mdm_test_value MDM_CONSOLE_USER_OVERRIDE)"; then
    printf '%s' "$_override"
    return 0
  fi
  if _user="$(_mdm_detect_read_console_user_record \
    | _mdm_detect_parse_console_user_record)"; then
    printf '%s' "$_user"
    return 0
  fi
  _user="$(_mdm_stat_owner /dev/console 2>/dev/null || true)"
  printf '%s' "$_user"
}

_mdm_claude_cli_codesign_requirement() {
  # An external Apple-anchored requirement is required here.  Verifying only
  # the binary's own designated requirement plus display strings would allow a
  # locally signed binary to choose matching identifier/subject text.
  printf '%s' '=identifier "com.anthropic.claude-code" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "Q6L2SF6YDW"'
}

_mdm_claude_codesign() {
  /usr/bin/codesign "$@"
}

_mdm_claude_cli_signature_trusted() { # <fd-bound-snapshot>
  local _snapshot="$1" _requirement _details
  _requirement="$(_mdm_claude_cli_codesign_requirement)" || return 1
  _mdm_claude_codesign --verify --strict -R "$_requirement" \
    "$_snapshot" >/dev/null 2>&1 \
    && _details="$(_mdm_claude_codesign -dv --verbose=4 "$_snapshot" 2>&1)" \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx 'Identifier=com.anthropic.claude-code' \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx 'TeamIdentifier=Q6L2SF6YDW' \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx \
      'Authority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)'
}

_mdm_ghostty_codesign_requirement() {
  printf '%s' '=identifier "com.mitchellh.ghostty" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "24VZTF6M5V"'
}

_mdm_ghostty_codesign() {
  /usr/bin/codesign "$@"
}

_mdm_ghostty_xattr() {
  /usr/bin/xattr "$@"
}

_mdm_node_codesign_requirement() {
  printf '%s' '=identifier "node" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "HX7739G8FX"'
}

_mdm_node_codesign() {
  /usr/bin/codesign "$@"
}

_mdm_node_signature_trusted() { # <node-binary>
  local _node="$1" _requirement _details
  [[ -f "$_node" && ! -L "$_node" ]] || return 1
  _requirement="$(_mdm_node_codesign_requirement)" || return 1
  _mdm_node_codesign --verify --strict -R "$_requirement" -- "$_node" \
    >/dev/null 2>&1 \
    && _details="$(_mdm_node_codesign -dv --verbose=4 -- "$_node" 2>&1)" \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx 'Identifier=node' \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx \
      'TeamIdentifier=HX7739G8FX' \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx \
      'Authority=Developer ID Application: Node.js Foundation (HX7739G8FX)' \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx \
      'Authority=Developer ID Certification Authority' \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx \
      'Authority=Apple Root CA'
}

_mdm_ghostty_signature_trusted() { # <application-bundle>
  local _app="$1" _requirement _details _executable _mode
  [[ -d "$_app" && ! -L "$_app" ]] || return 1
  _executable="$_app/Contents/MacOS/ghostty"
  [[ -f "$_executable" && ! -L "$_executable" \
    && "$(_mdm_canonical_file "$_executable")" == "$_executable" ]] \
    || return 1
  _mode="$(_mdm_stat_mode "$_executable")" || return 1
  _mdm_mode_owner_executable "$_mode" || return 1
  if _mdm_ghostty_xattr -p com.apple.quarantine -- "$_app" \
    >/dev/null 2>&1; then
    return 1
  fi
  _requirement="$(_mdm_ghostty_codesign_requirement)" || return 1
  _mdm_ghostty_codesign --verify --deep --strict -R "$_requirement" \
    -- "$_app" >/dev/null 2>&1 \
    && _details="$(_mdm_ghostty_codesign \
      -dv --verbose=4 -- "$_app" 2>&1)" \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx \
      'Identifier=com.mitchellh.ghostty' \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx \
      'TeamIdentifier=24VZTF6M5V' \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx \
      'Authority=Developer ID Application: Mitchell Hashimoto (24VZTF6M5V)' \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx \
      'Authority=Developer ID Certification Authority' \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx \
      'Authority=Apple Root CA'
}

_mdm_ttf_magic_is_valid() { # <font-file>
  local _path="$1" _magic
  [[ -f "$_path" && ! -L "$_path" ]] || return 1
  _magic="$(LC_ALL=C /usr/bin/head -c 4 "$_path" 2>/dev/null \
    | /usr/bin/od -An -tx1 | /usr/bin/tr -d '[:space:]')" || return 1
  case "$_magic" in
    00010000|74727565|4f54544f) return 0 ;;
    *) return 1 ;;
  esac
}

_mdm_font_expected_inventory() {
  printf '%s\n' \
    'IBMPlexMono-Bold.ttf ca403c56931baef307d20ba64b69acb71abcad61f75e66414661d57484b690ec ibm' \
    'IBMPlexMono-BoldItalic.ttf 0e45a5a540992163229d2a29662553f313fab391757ca2ab3dc8f4e0d9be0979 ibm' \
    'IBMPlexMono-ExtraLight.ttf 9c84b764bfc85441f53ce5d261c369156b0612a02837f1483ae525916c846486 ibm' \
    'IBMPlexMono-ExtraLightItalic.ttf 2c168787c187535d0d42e2150e10841887e0f94bddc0ebd0ee936520621ca854 ibm' \
    'IBMPlexMono-Italic.ttf 8ebe04c8c6cc82f0be19896ddc61d9935cdd0f027b0173c1945b8d247d7dfc2a ibm' \
    'IBMPlexMono-Light.ttf f2a7e41a2bb183a1ba82b415eb176ac2dd81d2ca9fc8d2a2c23e5d413b89540e ibm' \
    'IBMPlexMono-LightItalic.ttf 14c3e18514d64a95b82cacf8a6d77a173fadff92c90aed9905faf9a71fa83876 ibm' \
    'IBMPlexMono-Medium.ttf 0bede3debdea8488bbb927f8f0650d915073209734a67fe8cd5a3320b572511c ibm' \
    'IBMPlexMono-MediumItalic.ttf 71bd1f5f16fa0d10b101e050c67db3a2276f274e59cccfb3e9f9af3fc007a5a3 ibm' \
    'IBMPlexMono-Regular.ttf fe11304a5fe956d5744e9b6a246cc83d90425245e75a62230044966ca96a7f50 ibm' \
    'IBMPlexMono-SemiBold.ttf c9417148ce13f8fa7d2d5c9180bbc141f72aa0d814ffeb280f6904dc2b1bbd7a ibm' \
    'IBMPlexMono-SemiBoldItalic.ttf 7b4b32e3b8beb4fda5605a619671e61c27efc98f64fdc078ce225556f40aa8c5 ibm' \
    'IBMPlexMono-Text.ttf 650b37d83353821b19000dc8db573e27290aa82bb3b5e7366613eaa7260ca0fe ibm' \
    'IBMPlexMono-TextItalic.ttf fd037a88a0f0b29b95db086ee50450a69ac3a7cbb752ed286fca23d65711bc9c ibm' \
    'IBMPlexMono-Thin.ttf 34ce19c385afdd31726866c4797314f78ae59de41da04e898e4b3a04fc709ecd ibm' \
    'IBMPlexMono-ThinItalic.ttf 059d9f9bdd35a26bbdfd8e68ccc18a4a5fe4f9af22cbc80509206936583f122c ibm' \
    'HackGen35ConsoleNF-Bold.ttf ba3f1d6f97961d18cedc565f6a7399d1d0fd115e0d9d2f251f5d8d6ac6453f1c hackgen' \
    'HackGen35ConsoleNF-Regular.ttf 83c32fe20da5e5a8fd3c5624db872811282b6380774436b2011bfc42bba149c1 hackgen' \
    'HackGenConsoleNF-Bold.ttf 43b554e7ffccca4c1587d34ec139605bd3fa4b4843446bfb3334ab95cfb44e53 hackgen' \
    'HackGenConsoleNF-Regular.ttf 6c2d654cceb7ad2164d23e068bbae69647295413432ecfc970400b401d6f9873 hackgen'
}

_mdm_font_expected_record() { # <basename>
  local _wanted="$1" _name _sha _family
  while read -r _name _sha _family; do
    if [[ "$_name" == "$_wanted" ]]; then
      printf '%s\t%s' "$_sha" "$_family"
      return 0
    fi
  done < <(_mdm_font_expected_inventory)
  return 1
}

_mdm_font_file_is_trusted() { # <font-file>
  local _path="$1" _name="${1##*/}" _record _sha _family _python
  _record="$(_mdm_font_expected_record "$_name")" || return 1
  _sha="${_record%%$'\t'*}"
  _family="${_record#*$'\t'}"
  _python="$(_mdm_detect_system_python)" || return 1
  "$_python" -I -B - "$_path" "$_name" "$_sha" "$_family" <<'PY'
import hashlib
import os
import stat
import struct
import sys

path, logical_name, expected_sha, family = sys.argv[1:]
IBM_NAMES = {
    "IBMPlexMono-Bold.ttf", "IBMPlexMono-BoldItalic.ttf",
    "IBMPlexMono-ExtraLight.ttf", "IBMPlexMono-ExtraLightItalic.ttf",
    "IBMPlexMono-Italic.ttf", "IBMPlexMono-Light.ttf",
    "IBMPlexMono-LightItalic.ttf", "IBMPlexMono-Medium.ttf",
    "IBMPlexMono-MediumItalic.ttf", "IBMPlexMono-Regular.ttf",
    "IBMPlexMono-SemiBold.ttf", "IBMPlexMono-SemiBoldItalic.ttf",
    "IBMPlexMono-Text.ttf", "IBMPlexMono-TextItalic.ttf",
    "IBMPlexMono-Thin.ttf", "IBMPlexMono-ThinItalic.ttf",
}
HACK_NAMES = {
    "HackGen35ConsoleNF-Bold.ttf", "HackGen35ConsoleNF-Regular.ttf",
    "HackGenConsoleNF-Bold.ttf", "HackGenConsoleNF-Regular.ttf",
}

def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_uid, value.st_gid, value.st_size, value.st_mtime_ns,
            value.st_ctime_ns, getattr(value, "st_flags", 0),
            getattr(value, "st_gen", 0))

try:
    allowed = IBM_NAMES if family == "ibm" else HACK_NAMES
    if family not in ("ibm", "hackgen") or logical_name not in allowed:
        raise ValueError("unexpected font name")
    before = os.lstat(path)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (not stat.S_ISREG(opened.st_mode)
                or identity(opened) != identity(before)
                or opened.st_nlink != 1
                or opened.st_size < 256
                or opened.st_size > 16 * 1024 * 1024):
            raise ValueError("unsafe font file")
        chunks = []
        remaining = opened.st_size
        while remaining:
            block = os.read(descriptor, min(1024 * 1024, remaining))
            if not block:
                raise ValueError("short font read")
            chunks.append(block)
            remaining -= len(block)
        data = b"".join(chunks)
    finally:
        os.close(descriptor)
    if identity(os.lstat(path)) != identity(before):
        raise ValueError("font changed during validation")
    if hashlib.sha256(data).hexdigest() != expected_sha:
        raise ValueError("font digest mismatch")
    if data[:4] != b"\x00\x01\x00\x00":
        raise ValueError("not TrueType sfnt")
    table_count = struct.unpack_from(">H", data, 4)[0]
    directory_end = 12 + table_count * 16
    if table_count < 8 or table_count > 256 or directory_end > len(data):
        raise ValueError("invalid sfnt directory")
    tables = {}
    for index in range(table_count):
        offset = 12 + index * 16
        tag, _checksum, table_offset, table_length = struct.unpack_from(
            ">4sIII", data, offset)
        if (tag in tables or table_offset < directory_end
                or table_length == 0
                or table_offset + table_length > len(data)):
            raise ValueError("invalid sfnt table")
        tables[tag] = (table_offset, table_length)
    required = {b"cmap", b"glyf", b"head", b"hhea", b"hmtx", b"loca",
                b"maxp", b"name"}
    if not required.issubset(tables):
        raise ValueError("missing sfnt table")
    head_offset, head_length = tables[b"head"]
    if (head_length < 54
            or data[head_offset + 12:head_offset + 16] != b"_\x0f<\xf5"):
        raise ValueError("invalid head table")
    name_offset, name_length = tables[b"name"]
    if name_length < 6:
        raise ValueError("invalid name table")
    name_format, record_count, strings_offset = struct.unpack_from(
        ">HHH", data, name_offset)
    records_end = 6 + record_count * 12
    if name_format not in (0, 1) or not 1 <= record_count <= 4096:
        raise ValueError("invalid name records")
    if (records_end > name_length or strings_offset < records_end
            or strings_offset > name_length):
        raise ValueError("invalid name storage")
    names = {1: set(), 5: set(), 6: set()}
    for index in range(record_count):
        record = name_offset + 6 + index * 12
        platform, _encoding, _language, name_id, length, relative = (
            struct.unpack_from(">HHHHHH", data, record))
        if name_id not in names:
            continue
        start = name_offset + strings_offset + relative
        end = start + length
        if start < name_offset or end > name_offset + name_length:
            raise ValueError("invalid name string")
        codec = "utf-16-be" if platform in (0, 3) else "mac_roman"
        try:
            value = data[start:end].decode(codec)
        except UnicodeError:
            continue
        if value:
            names[name_id].add(value)
    if not all(names.values()):
        raise ValueError("missing internal font names")
    if family == "ibm":
        if (not any(value.startswith("IBM Plex Mono") for value in names[1])
                or "Version 2.004" not in names[5]
                or not any(value.startswith("IBMPlexMono")
                           for value in names[6])):
            raise ValueError("IBM font identity mismatch")
    else:
        expected_family = ("HackGen35 Console NF"
                           if logical_name.startswith("HackGen35")
                           else "HackGen Console NF")
        if (expected_family not in names[1]
                or not any(value.startswith("Version 2.10.0")
                           for value in names[5])
                or logical_name[:-4] not in names[6]):
            raise ValueError("HackGen font identity mismatch")
except (OSError, ValueError, struct.error):
    sys.exit(1)
PY
}

_mdm_readlink_value() { # <symlink>
  local _link="$1" _raw _sentinel=':claude-kit-mdm-readlink-end:'
  _raw="$({
    /usr/bin/readlink -n "$_link" 2>/dev/null || exit 1
    printf '%s' "$_sentinel"
  })" || return 1
  [[ "$_raw" == *"$_sentinel" ]] || return 1
  _raw="${_raw%"$_sentinel"}"
  [[ -n "$_raw" && ! "$_raw" =~ [[:cntrl:]] ]] || return 1
  printf '%s' "$_raw"
}

_mdm_mode_owner_executable() {
  local _mode
  _mode="$(_mdm_mode_normalize "$1")" || return 1
  (( (8#$_mode & 8#0100) != 0 ))
}

_mdm_cli_activation_target() { # <home> <target-uid>
  local _home="$1" _uid="$2" _link _versions _value _version _metadata _target
  _link="$_home/.local/bin/claude"
  _versions="$_home/.local/share/claude/versions"
  [[ "$_uid" =~ ^[0-9]+$ && -L "$_link" ]] || return 1
  _value="$(_mdm_readlink_value "$_link")" || return 1
  case "$_value" in "$_versions"/*) : ;; *) return 1 ;; esac
  _version="${_value#"$_versions"/}"
  [[ -n "$_version" && "$_version" != */* \
    && "$_version" =~ ^[0-9A-Za-z._+-]+$ \
    && "$(_mdm_stat_uid "$_link")" == "$_uid" ]] || return 1
  _metadata="$(_mdm_stat_metadata "$_link")" || return 1
  [[ "${_metadata##*:}" == 1 ]] || return 1
  _target="$(_mdm_canonical_file "$_value")" || return 1
  [[ "$_target" == "$_value" ]] || return 1
  printf '%s' "$_target"
}

_mdm_cli_present() { # <home> <expected-uid> <private-workspace>
  local _home="$1" _expected_uid="${2:-}" _workspace="${3:-}"
  local _override _cli _target _dir _versions _snapshot _rc=1
  if _override="$(_mdm_test_value MDM_DETECT_CLI_PRESENT_OVERRIDE)"; then
    [[ "$_override" == "1" ]]
    return
  fi
  _cli="$_home/.local/bin/claude"
  _versions="$_home/.local/share/claude/versions"
  [[ -n "$_home" && -L "$_cli" ]] || return 1
  [[ "$_expected_uid" =~ ^[0-9]+$ && -d "$_workspace" \
    && ! -L "$_workspace" ]] || return 1
  for _dir in "$_home" "$_home/.local" "$_home/.local/bin" \
    "$_home/.local/share" "$_home/.local/share/claude" "$_versions"; do
    _mdm_target_dir_is_accessible "$_dir" "$_expected_uid" || return 1
  done
  _target="$(_mdm_cli_activation_target "$_home" "$_expected_uid")" || return 1
  [[ -x /usr/bin/codesign ]] || return 1
  _snapshot="$_workspace/claude-cli"
  _mdm_snapshot_bound_file "$_target" "$_snapshot" cli "$_expected_uid" || return 1
  _mdm_mode_owner_executable "$_MDM_DETECT_SNAPSHOT_MODE" \
    || { /bin/rm -f "$_snapshot"; return 1; }
  /bin/chmod 700 "$_snapshot" || { /bin/rm -f "$_snapshot"; return 1; }
  if _mdm_claude_cli_signature_trusted "$_snapshot"; then
    _rc=0
  fi
  /bin/rm -f "$_snapshot"
  return "$_rc"
}

_mdm_sha256() {
  if _mdm_is_darwin; then
    /usr/bin/shasum -a 256 "$1" 2>/dev/null | /usr/bin/awk '{print $1}'
  elif [[ -x /usr/bin/sha256sum ]]; then
    /usr/bin/sha256sum "$1" 2>/dev/null | /usr/bin/awk '{print $1}'
  else
    return 1
  fi
}

# Must remain byte-for-byte algorithm-compatible with the installer issuer.
# A double capture binds type, path, mode, ownership, link target, size and
# regular-file content without invoking Git or following repository symlinks.
_mdm_artifact_digest() { # <file|tree> <absolute-path> [owner-uid-csv] [group-gid-csv]
  local _kind="$1" _path="$2" _owner_csv="${3:-}" _group_csv="${4:-}"
  local _python _canonical
  case "$_kind" in file|tree) : ;; *) return 1 ;; esac
  [[ "$_path" == /* && ! "$_path" =~ [[:cntrl:]] ]] || return 1
  [[ -z "$_owner_csv" || "$_owner_csv" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
  [[ -z "$_group_csv" || "$_group_csv" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
  [[ ! -L "$_path" ]] || return 1
  _canonical="$(_mdm_canonical_any "$_path")" || return 1
  [[ "$_canonical" == /* && ! "$_canonical" =~ [[:cntrl:]] ]] || return 1
  _path="$_canonical"
  _python="$(_mdm_detect_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B - "$_kind" "$_path" "$_owner_csv" "$_group_csv" <<'PY'
import base64
import collections
import ctypes
import errno
import hashlib
import json
import os
import stat
import sys

kind, root, owner_csv, group_csv = sys.argv[1:]
allowed_owners = ({int(value) for value in owner_csv.split(",")}
                  if owner_csv else None)
allowed_groups = ({int(value) for value in group_csv.split(",")}
                  if group_csv else None)
MAX_ENTRIES = 100000
MAX_DEPTH = 256
MAX_FILE = 512 * 1024 * 1024
MAX_TOTAL = 2 * 1024 * 1024 * 1024
MAX_PATH_TOTAL = 64 * 1024 * 1024
MAX_SYMLINK_TARGET = 64 * 1024
MAX_SYMLINKS = 40
MAX_SYMLINK_COMPONENTS = 4096
MAX_XATTRS = 262144
MAX_XATTRS_PER_ENTRY = 256
MAX_XATTR_LIST = 64 * 1024
MAX_XATTR_VALUE = 16 * 1024 * 1024
MAX_XATTR_TOTAL = 64 * 1024 * 1024

ACL_TYPE_EXTENDED = 0x00000100
O_SYMLINK = 0x00200000
XATTR_SHOWCOMPRESSION = 0x0020
DARWIN = sys.platform == "darwin"

if kind not in ("file", "tree"):
    raise SystemExit(1)

if DARWIN:
    libc = ctypes.CDLL(None, use_errno=True)
    libc.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    libc.acl_get_fd_np.restype = ctypes.c_void_p
    libc.acl_free.argtypes = [ctypes.c_void_p]
    libc.acl_free.restype = ctypes.c_int
    libc.flistxattr.argtypes = [
        ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int
    ]
    libc.flistxattr.restype = ctypes.c_ssize_t
    libc.fgetxattr.argtypes = [
        ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p,
        ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int,
    ]
    libc.fgetxattr.restype = ctypes.c_ssize_t
    libc.freadlink.argtypes = [
        ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t
    ]
    libc.freadlink.restype = ctypes.c_ssize_t
else:
    libc = None

DIR_FLAGS = (os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
             | getattr(os, "O_CLOEXEC", 0))
FILE_FLAGS = (os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
              | getattr(os, "O_CLOEXEC", 0))
# Darwin O_SYMLINK opens the link object. Linux O_PATH|O_NOFOLLOW provides the
# same fstat binding for the portable MDM test contract.
LINK_FLAGS = ((os.O_RDONLY | os.O_NONBLOCK | O_SYMLINK
               | getattr(os, "O_CLOEXEC", 0)) if DARWIN else
              (getattr(os, "O_PATH", os.O_RDONLY) | os.O_NOFOLLOW
               | getattr(os, "O_CLOEXEC", 0)))


def weak_identity(value):
    return (value.st_dev, value.st_ino, value.st_mode,
            value.st_uid, value.st_gid, getattr(value, "st_flags", 0),
            getattr(value, "st_gen", 0))


def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
            value.st_gid, value.st_nlink, value.st_size,
            getattr(value, "st_flags", 0), getattr(value, "st_gen", 0),
            value.st_mtime_ns, value.st_ctime_ns)


def assert_bound(parent, name, descriptor, before, strong=True):
    opened = os.fstat(descriptor)
    current = os.stat(name, dir_fd=parent, follow_symlinks=False)
    compare = identity if strong else weak_identity
    if compare(opened) != compare(before) or compare(current) != compare(before):
        raise ValueError("artifact path changed")
    return opened


def open_entry(parent, name, before):
    if stat.S_ISDIR(before.st_mode):
        flags = DIR_FLAGS
    elif stat.S_ISREG(before.st_mode):
        flags = FILE_FLAGS
    elif stat.S_ISLNK(before.st_mode):
        flags = LINK_FLAGS
    else:
        raise ValueError("unsupported artifact entry")
    descriptor = os.open(name, flags, dir_fd=parent)
    try:
        opened = assert_bound(parent, name, descriptor, before)
        if stat.S_IFMT(opened.st_mode) != stat.S_IFMT(before.st_mode):
            raise ValueError("artifact type changed")
        if not stat.S_ISDIR(opened.st_mode) and opened.st_nlink != 1:
            raise ValueError("hard-linked artifact entry")
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def no_extended_acl(descriptor):
    if not DARWIN:
        names = os.listxattr(descriptor)
        if "system.posix_acl_access" in names or "system.posix_acl_default" in names:
            raise ValueError("extended ACL is not allowed")
        return
    ctypes.set_errno(0)
    acl = libc.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
    if not acl:
        error = ctypes.get_errno()
        if error == errno.ENOENT:
            return
        raise OSError(error or errno.EIO, "acl_get_fd_np")
    ctypes.set_errno(0)
    result = libc.acl_free(acl)
    error = ctypes.get_errno()
    if result != 0:
        raise OSError(error or errno.EIO, "acl_free")
    raise ValueError("extended ACL is not allowed")


def list_xattr_names(descriptor, is_link=False):
    if not DARWIN:
        if is_link:
            return []
        names = [os.fsencode(value) for value in os.listxattr(descriptor)]
        if len(names) > MAX_XATTRS_PER_ENTRY or len(set(names)) != len(names):
            raise ValueError("too many or duplicate xattrs")
        if sum(len(value) + 1 for value in names) > MAX_XATTR_LIST:
            raise ValueError("xattr name list too large")
        return sorted(names)
    ctypes.set_errno(0)
    needed = libc.flistxattr(descriptor, None, 0, XATTR_SHOWCOMPRESSION)
    if needed < 0:
        error = ctypes.get_errno()
        raise OSError(error or errno.EIO, "flistxattr")
    if needed > MAX_XATTR_LIST:
        raise ValueError("xattr name list too large")
    if needed == 0:
        return []
    buffer = ctypes.create_string_buffer(needed)
    ctypes.set_errno(0)
    actual = libc.flistxattr(descriptor, ctypes.cast(buffer, ctypes.c_void_p),
                            needed, XATTR_SHOWCOMPRESSION)
    if actual != needed:
        if actual < 0:
            error = ctypes.get_errno()
            raise OSError(error or errno.EIO, "flistxattr")
        raise ValueError("xattr name list changed")
    raw = bytes(buffer[:actual])
    if not raw.endswith(b"\0"):
        raise ValueError("invalid xattr name list")
    names = raw[:-1].split(b"\0")
    if any(not name or b"\0" in name or len(name) > 127 for name in names):
        raise ValueError("invalid xattr name")
    if len(names) > MAX_XATTRS_PER_ENTRY or len(set(names)) != len(names):
        raise ValueError("too many or duplicate xattrs")
    return sorted(names)


def read_xattr(descriptor, name):
    def read_once():
        if not DARWIN:
            value = os.getxattr(descriptor, os.fsdecode(name))
            if len(value) > MAX_XATTR_VALUE:
                raise ValueError("xattr value too large")
            return value
        ctypes.set_errno(0)
        needed = libc.fgetxattr(descriptor, name, None, 0, 0,
                                XATTR_SHOWCOMPRESSION)
        if needed < 0:
            error = ctypes.get_errno()
            raise OSError(error or errno.EIO, "fgetxattr")
        if needed > MAX_XATTR_VALUE:
            raise ValueError("xattr value too large")
        buffer = ctypes.create_string_buffer(max(needed, 1))
        ctypes.set_errno(0)
        actual = libc.fgetxattr(descriptor, name,
                                ctypes.cast(buffer, ctypes.c_void_p),
                                needed, 0, XATTR_SHOWCOMPRESSION)
        if actual != needed:
            if actual < 0:
                error = ctypes.get_errno()
                raise OSError(error or errno.EIO, "fgetxattr")
            raise ValueError("xattr value changed")
        return bytes(buffer[:actual])
    first = read_once()
    second = read_once()
    if first != second:
        raise ValueError("xattr value changed")
    return first


def fd_readlink(descriptor):
    before = os.fstat(descriptor)
    if (not stat.S_ISLNK(before.st_mode) or before.st_nlink != 1
            or before.st_size <= 0 or before.st_size > MAX_SYMLINK_TARGET):
        raise ValueError("unsafe artifact symlink")

    def read_once():
        if not DARWIN:
            value = os.readlink(b"", dir_fd=descriptor)
            return value if isinstance(value, bytes) else os.fsencode(value)
        buffer = ctypes.create_string_buffer(before.st_size + 1)
        ctypes.set_errno(0)
        actual = libc.freadlink(descriptor,
                                ctypes.cast(buffer, ctypes.c_void_p),
                                before.st_size + 1)
        if actual < 0:
            error = ctypes.get_errno()
            raise OSError(error or errno.EIO, "freadlink")
        return bytes(buffer[:actual])

    first = read_once()
    second = read_once()
    after = os.fstat(descriptor)
    if (not first or first != second or len(first) != before.st_size
            or identity(after) != identity(before)):
        raise ValueError("artifact symlink changed")
    return first


def capture():
    records = []
    total = 0
    path_total = 0
    xattr_count = 0
    xattr_total = 0
    root_bytes = os.fsencode(root)
    if not root_bytes.startswith(b"/"):
        raise ValueError("artifact path is not absolute")
    parts = root_bytes.split(b"/")[1:]
    if not parts or any(part in (b"", b".", b"..") for part in parts):
        raise ValueError("artifact path is not canonical")
    slash = os.open(b"/", DIR_FLAGS)
    held = [slash]
    bindings = []
    try:
        current = slash
        for index, part in enumerate(parts):
            before = os.stat(part, dir_fd=current, follow_symlinks=False)
            final = index == len(parts) - 1
            if not final:
                if not stat.S_ISDIR(before.st_mode):
                    raise ValueError("non-directory artifact parent")
                flags = DIR_FLAGS
            elif kind == "tree" and stat.S_ISDIR(before.st_mode):
                flags = DIR_FLAGS
            elif kind == "file" and stat.S_ISREG(before.st_mode):
                flags = FILE_FLAGS
            else:
                raise ValueError("artifact root type mismatch")
            child = os.open(part, flags, dir_fd=current)
            try:
                opened = assert_bound(current, part, child, before, final)
                if final and not stat.S_ISDIR(opened.st_mode) and opened.st_nlink != 1:
                    raise ValueError("hard-linked artifact root")
            except Exception:
                os.close(child)
                raise
            bindings.append((current, part, child, before, final))
            held.append(child)
            current = child
        root_fd = current
        root_dev = os.fstat(root_fd).st_dev

        def metadata(descriptor, before):
            nonlocal xattr_count, xattr_total
            is_link = stat.S_ISLNK(before.st_mode)
            if not (is_link and not DARWIN):
                no_extended_acl(descriptor)
            names = list_xattr_names(descriptor, is_link)
            values = []
            for name in names:
                value = read_xattr(descriptor, name)
                xattr_count += 1
                xattr_total += len(name) + len(value)
                if xattr_count > MAX_XATTRS or xattr_total > MAX_XATTR_TOTAL:
                    raise ValueError("artifact xattrs too large")
                values.append({"name": base64.b64encode(name).decode("ascii"),
                               "value": base64.b64encode(value).decode("ascii")})
            if list_xattr_names(descriptor, is_link) != names:
                raise ValueError("xattr names changed")
            if identity(os.fstat(descriptor)) != identity(before):
                raise ValueError("artifact metadata changed")
            return values

        def validate_symlink(parent_parts, target):
            if target.startswith(b"/") or len(target) > MAX_SYMLINK_TARGET:
                raise ValueError("invalid artifact symlink")
            pending = collections.deque(list(parent_parts) + target.split(b"/"))
            descriptors = [os.dup(root_fd)]
            target_bindings = []
            symlinks = 0
            processed = 0
            try:
                while pending:
                    component = pending.popleft()
                    processed += 1
                    if processed > MAX_SYMLINK_COMPONENTS:
                        raise ValueError("symlink target too complex")
                    if component in (b"", b"."):
                        continue
                    if component == b"..":
                        if len(descriptors) == 1:
                            raise ValueError("artifact symlink escapes root")
                        parent, name, descriptor, before = target_bindings.pop()
                        assert_bound(parent, name, descriptor, before, False)
                        os.close(descriptors.pop())
                        continue
                    current_fd = descriptors[-1]
                    before = os.stat(component, dir_fd=current_fd,
                                     follow_symlinks=False)
                    if before.st_dev != root_dev:
                        raise ValueError("artifact symlink crosses filesystem")
                    if stat.S_ISLNK(before.st_mode):
                        if before.st_nlink != 1:
                            raise ValueError("hard-linked artifact symlink")
                        link_fd = os.open(component, LINK_FLAGS, dir_fd=current_fd)
                        try:
                            assert_bound(current_fd, component, link_fd, before)
                            nested = fd_readlink(link_fd)
                            assert_bound(current_fd, component, link_fd, before)
                        finally:
                            os.close(link_fd)
                        if nested.startswith(b"/") or len(nested) > MAX_SYMLINK_TARGET:
                            raise ValueError("invalid nested artifact symlink")
                        symlinks += 1
                        if symlinks > MAX_SYMLINKS:
                            raise ValueError("too many symlink hops")
                        pending.extendleft(reversed(nested.split(b"/")))
                        continue
                    if pending:
                        if not stat.S_ISDIR(before.st_mode):
                            raise ValueError("dangling artifact symlink")
                        child = os.open(component, DIR_FLAGS, dir_fd=current_fd)
                        try:
                            assert_bound(current_fd, component, child, before, False)
                        except Exception:
                            os.close(child)
                            raise
                        target_bindings.append((current_fd, component, child, before))
                        descriptors.append(child)
                        continue
                    if stat.S_ISDIR(before.st_mode):
                        flags = DIR_FLAGS
                    elif stat.S_ISREG(before.st_mode):
                        if before.st_nlink != 1:
                            raise ValueError("hard-linked symlink target")
                        flags = FILE_FLAGS
                    else:
                        raise ValueError("unsupported symlink target")
                    terminal = os.open(component, flags, dir_fd=current_fd)
                    try:
                        assert_bound(current_fd, component, terminal, before, False)
                    finally:
                        os.close(terminal)
                for parent, name, descriptor, before in reversed(target_bindings):
                    assert_bound(parent, name, descriptor, before, False)
            finally:
                for descriptor in reversed(descriptors):
                    try:
                        os.close(descriptor)
                    except OSError:
                        pass

        def visit(descriptor, parent, name, before, relative_parts, depth):
            nonlocal total, path_total
            if depth > MAX_DEPTH or len(records) >= MAX_ENTRIES:
                raise ValueError("artifact tree too large")
            if before.st_dev != root_dev:
                raise ValueError("artifact crosses filesystem")
            if allowed_owners is not None and before.st_uid not in allowed_owners:
                raise ValueError("unexpected artifact owner")
            if allowed_groups is not None and before.st_gid not in allowed_groups:
                raise ValueError("unexpected artifact group")
            if not stat.S_ISLNK(before.st_mode) and stat.S_IMODE(before.st_mode) & 0o022:
                raise ValueError("writable artifact entry")
            relative_bytes = b"/".join(relative_parts)
            path_total += len(relative_bytes)
            if path_total > MAX_PATH_TOTAL:
                raise ValueError("artifact paths too large")
            base = {"path": os.fsdecode(relative_bytes),
                    "mode": format(stat.S_IMODE(before.st_mode), "04o"),
                    "uid": before.st_uid, "gid": before.st_gid,
                    "nlink": before.st_nlink,
                    "size": before.st_size,
                    "flags": getattr(before, "st_flags", 0),
                    "xattrs": metadata(descriptor, before)}
            if stat.S_ISDIR(before.st_mode):
                records.append(dict(base, kind="dir"))
                names = sorted(os.listdir(descriptor), key=os.fsencode)
                for child_name in names:
                    child_bytes = os.fsencode(child_name)
                    if child_bytes in (b"", b".", b"..") or b"/" in child_bytes:
                        raise ValueError("invalid artifact entry")
                    child_before = os.stat(child_bytes, dir_fd=descriptor,
                                           follow_symlinks=False)
                    child = open_entry(descriptor, child_bytes, child_before)
                    try:
                        visit(child, descriptor, child_bytes, child_before,
                              relative_parts + [child_bytes], depth + 1)
                        assert_bound(descriptor, child_bytes, child, child_before)
                    finally:
                        os.close(child)
                names_after = sorted(os.listdir(descriptor), key=os.fsencode)
                if names_after != names:
                    raise ValueError("directory entries changed")
            elif stat.S_ISREG(before.st_mode):
                if before.st_nlink != 1 or before.st_size > MAX_FILE:
                    raise ValueError("unsafe artifact file")
                digest = hashlib.sha256()
                size = 0
                os.lseek(descriptor, 0, os.SEEK_SET)
                while True:
                    block = os.read(descriptor, 1024 * 1024)
                    if not block:
                        break
                    size += len(block)
                    if size > MAX_FILE:
                        raise ValueError("artifact file grew")
                    digest.update(block)
                if size != before.st_size:
                    raise ValueError("artifact file size changed")
                total += size
                if total > MAX_TOTAL:
                    raise ValueError("artifact aggregate too large")
                records.append(dict(base, kind="file", size=size,
                                    sha256=digest.hexdigest()))
            elif stat.S_ISLNK(before.st_mode):
                if before.st_nlink != 1:
                    raise ValueError("hard-linked artifact symlink")
                target = fd_readlink(descriptor)
                validate_symlink(relative_parts[:-1], target)
                records.append(dict(base, kind="symlink",
                                    target=base64.b64encode(target).decode("ascii")))
            else:
                raise ValueError("unsupported artifact entry")
            if identity(os.fstat(descriptor)) != identity(before):
                raise ValueError("artifact changed")
            if parent is not None:
                assert_bound(parent, name, descriptor, before)

        root_before = os.fstat(root_fd)
        visit(root_fd, None, None, root_before, [], 0)
        for parent, name, descriptor, before, strong in reversed(bindings):
            assert_bound(parent, name, descriptor, before, strong)
        return (json.dumps(records, ensure_ascii=True, sort_keys=True,
                           separators=(",", ":")) + "\n").encode("ascii")
    finally:
        for descriptor in reversed(held):
            try:
                os.close(descriptor)
            except OSError:
                pass


try:
    first = capture()
    second = capture()
    if first != second:
        raise ValueError("artifact changed during capture")
    print(hashlib.sha256(first).hexdigest())
except (OSError, UnicodeError, ValueError, MemoryError, OverflowError,
        RuntimeError, ctypes.ArgumentError):
    sys.exit(1)
PY
}

_mdm_path_is_absent_with_real_parents() { # <root> <relative>
  local _root="$1" _relative="$2" _python
  [[ -d "$_root" && ! -L "$_root" && -n "$_relative" \
    && "$_relative" != /* && ! "$_relative" =~ [[:cntrl:]] ]] || return 1
  case "/$_relative/" in */../*|*/./*|*//*) return 1 ;; esac
  _python="${_MDM_DETECT_ABSENCE_PYTHON:-}"
  [[ -n "$_python" ]] || _python="$(_mdm_detect_system_python)" || return 1
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -c '
import os, stat, sys
root, relative = sys.argv[1], sys.argv[2]
parts = relative.split("/")
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
held = []
try:
    current = os.open(root, flags)
except OSError:
    raise SystemExit(1)
try:
    held.append(current)
    identities = [(os.fstat(current).st_dev, os.fstat(current).st_ino)]
    missing = None
    for index, part in enumerate(parts):
        try:
            before = os.stat(part, dir_fd=current, follow_symlinks=False)
        except FileNotFoundError:
            missing = index
            break
        except OSError:
            raise SystemExit(1)
        if index == len(parts) - 1:
            raise SystemExit(1)
        if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
            raise SystemExit(1)
        try:
            child = os.open(part, flags, dir_fd=current)
        except OSError:
            raise SystemExit(1)
        opened = os.fstat(child)
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            os.close(child)
            raise SystemExit(1)
        held.append(child)
        identities.append((opened.st_dev, opened.st_ino))
        current = child

    if missing is None:
        raise SystemExit(1)

    # Rebind after ENOENT so a renamed-away parent cannot make a detached tree
    # look compliant while the current pathname contains the retired file.
    def rebound_absent():
        try:
            rebound = os.open(root, flags)
        except OSError:
            return False
        try:
            opened = os.fstat(rebound)
            if (opened.st_dev, opened.st_ino) != identities[0]:
                return False
            for edge in range(missing):
                try:
                    entry = os.stat(parts[edge], dir_fd=rebound, follow_symlinks=False)
                except OSError:
                    return False
                if not stat.S_ISDIR(entry.st_mode) or stat.S_ISLNK(entry.st_mode):
                    return False
                if (entry.st_dev, entry.st_ino) != identities[edge + 1]:
                    return False
                try:
                    child = os.open(parts[edge], flags, dir_fd=rebound)
                except OSError:
                    return False
                child_stat = os.fstat(child)
                if (child_stat.st_dev, child_stat.st_ino) != identities[edge + 1]:
                    os.close(child)
                    return False
                os.close(rebound)
                rebound = child
            try:
                os.stat(parts[missing], dir_fd=rebound, follow_symlinks=False)
            except FileNotFoundError:
                return True
            except OSError:
                return False
            return False
        finally:
            os.close(rebound)

    if not rebound_absent() or not rebound_absent():
        raise SystemExit(1)
    raise SystemExit(0)
finally:
    for descriptor in reversed(held):
        try:
            os.close(descriptor)
        except OSError:
            pass
' "$_root" "$_relative"
}

_MDM_MARKER_BEGIN='<!-- BEGIN STARTER-KIT-MANAGED -->'
_MDM_MARKER_END='<!-- END STARTER-KIT-MANAGED -->'
_mdm_text_file_is_byte_exact() { # <input>
  local _input="$1" _last_byte
  [[ -f "$_input" && ! -L "$_input" ]] || return 1
  _last_byte="$(LC_ALL=C /usr/bin/tail -c 1 "$_input" \
    | /usr/bin/od -An -tu1 | /usr/bin/tr -d '[:space:]')" || return 1
  [[ "$_last_byte" == 10 ]] || return 1
  LC_ALL=C /usr/bin/tr -d '\000' < "$_input" \
    | /usr/bin/cmp -s "$_input" -
}

_mdm_extract_managed_section() { # <input> <output> <require-entire:0|1>
  local _input="$1" _output="$2" _require_entire="$3"
  [[ "$_require_entire" == 0 || "$_require_entire" == 1 ]] || return 1
  _mdm_text_file_is_byte_exact "$_input" || return 1
  if ! /usr/bin/awk -v begin="$_MDM_MARKER_BEGIN" -v end="$_MDM_MARKER_END" \
    -v entire="$_require_entire" '
      {
        if ($0 == begin) {
          begins++
          if (state != 0) bad = 1
          state = 1
          print
          next
        }
        if ($0 == end) {
          ends++
          if (state != 1) bad = 1
          if (state == 1) print
          state = 2
          next
        }
        if (state == 1) { print; next }
        if (entire == 1) bad = 1
      }
      END {
        if (bad || begins != 1 || ends != 1 || state != 2) exit 1
      }
    ' "$_input" > "$_output"; then
    /bin/rm -f "$_output"
    return 1
  fi
  /bin/chmod 600 "$_output" || { /bin/rm -f "$_output"; return 1; }
  return 0
}

_mdm_canonical_dir() {
  [[ -d "$1" && ! -L "$1" ]] || return 1
  (builtin cd -P -- "$1" 2>/dev/null && printf '%s' "$PWD")
}

_mdm_canonical_file() {
  local _file="$1" _dir _base _physical
  [[ -f "$_file" && ! -L "$_file" ]] || return 1
  _dir="${_file%/*}"
  _base="${_file##*/}"
  [[ "$_dir" != "$_file" ]] || _dir=.
  _physical="$(_mdm_canonical_dir "$_dir")" || return 1
  printf '%s/%s' "$_physical" "$_base"
}

_mdm_private_tmpdir() {
  local _base _dir _old_umask
  if ! _base="$(_mdm_test_value MDM_DETECT_TMP_BASE_OVERRIDE)"; then
    if _mdm_is_darwin; then _base=/private/tmp; else _base=/tmp; fi
  fi
  [[ -d "$_base" && ! -L "$_base" ]] || return 1
  _old_umask="$(umask)"
  umask 077
  _dir="$(/usr/bin/mktemp -d "$_base/claude-kit-mdm-detect.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  /bin/chmod 700 "$_dir" || { /bin/rm -rf "$_dir"; return 1; }
  [[ -d "$_dir" && ! -L "$_dir" ]] || { /bin/rm -rf "$_dir"; return 1; }
  printf '%s' "$_dir"
}

_mdm_cleanup_private_tmpdir() { # <private-dir>
  local _dir="$1" _base
  [[ -n "$_dir" ]] || return 0
  if ! _base="$(_mdm_test_value MDM_DETECT_TMP_BASE_OVERRIDE)"; then
    if _mdm_is_darwin; then _base=/private/tmp; else _base=/tmp; fi
  fi
  case "$_dir" in "$_base"/claude-kit-mdm-detect.*) : ;; *) return 1 ;; esac
  [[ -d "$_dir" && ! -L "$_dir" ]] || return 1
  /bin/rm -rf "$_dir"
}

_MDM_DETECT_ACTIVE_WORKSPACE=""
_mdm_cleanup_active_workspace() {
  local _dir="${_MDM_DETECT_ACTIVE_WORKSPACE:-}"
  [[ -n "$_dir" ]] || return 0
  if _mdm_cleanup_private_tmpdir "$_dir"; then
    _MDM_DETECT_ACTIVE_WORKSPACE=""
    return 0
  fi
  return 1
}

# Bind a checked regular pathname to one descriptor, then copy bounded bytes
# into the private detector workspace.  The child isolates a potentially
# blocking open after a user-owned pathname swap; its watchdog guarantees that
# a FIFO/device substitution cannot hang the root detector indefinitely.
_MDM_DETECT_SNAPSHOT_SIZE=""
_MDM_DETECT_SNAPSHOT_MODE=""
_mdm_snapshot_timeout_for_size() {
  local _size="$1" _timeout
  [[ "$_size" =~ ^[0-9]+$ ]] || return 1
  _timeout=$((5 + (_size / 8388608)))
  (( _timeout <= 60 )) || _timeout=60
  printf '%s' "$_timeout"
}

_mdm_snapshot_bound_file() { # <source> <snapshot> <receipt|manifest|managed|head> [uid]
  local _source="$1" _snapshot="$2" _label="$3" _expected_uid="${4:-}"
  local _metadata _metadata_check _before _opened _size _uid _mode_raw _mode _nlink
  local _limit _copy_limit _copied _copied_size _strict_bind=0
  local _done="$_snapshot.done" _child _watchdog _rc _mdm_copy_rc
  local _timeout _started
  _MDM_DETECT_SNAPSHOT_SIZE=""
  _MDM_DETECT_SNAPSHOT_MODE=""
  [[ -f "$_source" && ! -L "$_source" ]] || return 1
  _metadata="$(_mdm_stat_metadata "$_source")" || return 1
  _nlink="${_metadata##*:}"; _metadata_check="${_metadata%:*}"
  _mode_raw="${_metadata_check##*:}"; _metadata_check="${_metadata_check%:*}"
  _uid="${_metadata_check##*:}"; _before="${_metadata_check%:*}"
  _mode="$(_mdm_mode_normalize "$_mode_raw")" || return 1
  _mdm_mode_is_safe "$_mode" || return 1
  case "$_before" in *:Regular\ File:*|*:regular\ file:*) : ;; *) return 1 ;; esac
  _size="${_before##*:}"
  case "$_label" in
    receipt|manifest|history) _limit=4194304 ;;
    managed) _limit=67108864 ;;
    cli) _limit=536870912 ;;
    head) _limit=41 ;;
    *) return 1 ;;
  esac
  [[ "$_size" =~ ^[0-9]+$ && "$_size" -le "$_limit" ]] || return 1
  [[ "$_label" != head || "$_size" == 41 ]] || return 1
  if [[ "$_label" == managed || "$_label" == cli || "$_label" == receipt \
    || "$_label" == manifest || "$_label" == history ]] \
    || [[ "$_label" == head && -n "$_expected_uid" ]]; then
    _strict_bind=1
  fi
  if [[ "$_strict_bind" -eq 1 ]]; then
    if [[ "$_label" == managed || "$_label" == cli \
      || -n "$_expected_uid" ]]; then
      [[ "$_expected_uid" =~ ^[0-9]+$ && "$_uid" == "$_expected_uid" ]] \
        || return 1
    fi
    [[ "$_nlink" == 1 ]] || return 1
    ! _mdm_has_acl "$_source" || return 1
    [[ "$(_mdm_stat_metadata "$_source")" == "$_metadata" ]] || return 1
  fi
  _copy_limit=$((_limit + 1))
  /bin/rm -f "$_snapshot" "$_done"

  (
    _mdm_copy_rc=0
    _mdm_copy_pid=""
    trap '[[ -z "${_mdm_copy_pid:-}" ]] \
      || kill -TERM "$_mdm_copy_pid" 2>/dev/null || true; exit 124' TERM INT
    exec 8<"$_source" || _mdm_copy_rc=1
    if [[ "$_mdm_copy_rc" -eq 0 ]]; then
      _opened="$(_mdm_stat_fd_identity 8)" || _mdm_copy_rc=1
    fi
    if [[ "$_mdm_copy_rc" -eq 0 && "$_before" != "$_opened" ]]; then
      _mdm_copy_rc=1
    fi
    if [[ "$_mdm_copy_rc" -eq 0 ]]; then
      (umask 077; /usr/bin/head -c "$_copy_limit" <&8 > "$_snapshot") &
      _mdm_copy_pid=$!
      if ! wait "$_mdm_copy_pid"; then _mdm_copy_rc=1; fi
      _mdm_copy_pid=""
    fi
    exec 8<&- 2>/dev/null || true
    if [[ "$_mdm_copy_rc" -eq 0 ]]; then
      _copied="$(_mdm_stat_identity "$_snapshot")" || _mdm_copy_rc=1
    fi
    if [[ "$_mdm_copy_rc" -eq 0 ]]; then
      case "$_copied" in
        *:Regular\ File:*|*:regular\ file:*) : ;;
        *) _mdm_copy_rc=1 ;;
      esac
    fi
    if [[ "$_mdm_copy_rc" -eq 0 ]]; then
      _copied_size="${_copied##*:}"
      [[ "$_copied_size" == "$_size" ]] || _mdm_copy_rc=1
    fi
    if [[ "$_mdm_copy_rc" -eq 0 ]]; then
      /bin/chmod 600 "$_snapshot" || _mdm_copy_rc=1
    fi
    if [[ "$_mdm_copy_rc" -eq 0 && "$_strict_bind" -eq 1 ]]; then
      [[ "$(_mdm_stat_metadata "$_source")" == "$_metadata" ]] \
        && ! _mdm_has_acl "$_source" || _mdm_copy_rc=1
    fi
    [[ "$_mdm_copy_rc" -eq 0 ]] || /bin/rm -f "$_snapshot"
    printf '%s\n' "$_mdm_copy_rc" > "$_done"
    exit "$_mdm_copy_rc"
  ) &
  _child=$!
  # Keep the child unreaped while polling so its PID cannot be reused.  Allow
  # larger signed CLI snapshots proportionally more time, while retaining a
  # hard upper bound for FIFO/device swaps and degraded storage.
  _timeout="$(_mdm_snapshot_timeout_for_size "$_size")" || return 1
  _started=$SECONDS
  (
    _mdm_watchdog_timer=""
    trap '[[ -z "${_mdm_watchdog_timer:-}" ]] \
      || kill -TERM "$_mdm_watchdog_timer" 2>/dev/null || true; exit 0' TERM INT
    /bin/sleep "$_timeout" >/dev/null 2>&1 &
    _mdm_watchdog_timer=$!
    wait "$_mdm_watchdog_timer" 2>/dev/null || exit 0
    [[ -f "$_done" ]] || kill -TERM "$_child" 2>/dev/null || true
  ) &
  _watchdog=$!
  if wait "$_child" 2>/dev/null; then _rc=0; else _rc=$?; fi
  # Before the deadline the watchdog is necessarily still the process we
  # launched, so cancellation cannot hit a recycled PID.  At/after the
  # deadline, let it finish naturally and only reap it.
  if (( SECONDS - _started < _timeout )); then
    kill -TERM "$_watchdog" 2>/dev/null || true
  fi
  wait "$_watchdog" 2>/dev/null || true
  /bin/rm -f "$_done"
  if [[ "$_rc" -ne 0 || ! -f "$_snapshot" || -L "$_snapshot" ]]; then
    /bin/rm -f "$_snapshot"
    return 1
  fi
  _MDM_DETECT_SNAPSHOT_SIZE="$_size"
  _MDM_DETECT_SNAPSHOT_MODE="$_mode"
  return 0
}

_MDM_DETECT_PERSISTENT_IDENTITY=""
_MDM_DETECT_GIT_IDENTITY=""
_mdm_target_dir_matches_identity() { # <dir> <target-uid> [dev:inode:type]
  local _dir="$1" _expected_uid="$2" _expected_identity="${3:-}"
  local _identity _mode
  [[ "$_expected_uid" =~ ^[0-9]+$ && -d "$_dir" && ! -L "$_dir" ]] || return 1
  [[ "$(_mdm_canonical_dir "$_dir")" == "$_dir" ]] || return 1
  [[ "$(_mdm_stat_uid "$_dir")" == "$_expected_uid" ]] || return 1
  _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_dir")")" || return 1
  _mdm_mode_is_safe "$_mode" || return 1
  _mdm_mode_owner_executable "$_mode" || return 1
  _mdm_user_dir_acl_is_supported "$_dir" || return 1
  _identity="$(_mdm_stat_dir_identity "$_dir")" || return 1
  case "$_identity" in *:Directory|*:directory) : ;; *) return 1 ;; esac
  [[ -z "$_expected_identity" || "$_identity" == "$_expected_identity" ]]
}

_mdm_target_dir_is_accessible() { # <dir> <target-uid>
  local _dir="$1" _expected_uid="$2" _before _after _mode
  [[ "$_expected_uid" =~ ^[0-9]+$ && -d "$_dir" && ! -L "$_dir" ]] \
    || return 1
  [[ "$(_mdm_canonical_dir "$_dir")" == "$_dir" \
    && "$(_mdm_stat_uid "$_dir")" == "$_expected_uid" ]] || return 1
  _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_dir")")" || return 1
  _mdm_mode_is_safe "$_mode" || return 1
  _before="$(_mdm_stat_dir_identity "$_dir")" || return 1
  case "$_before" in *:Directory|*:directory) : ;; *) return 1 ;; esac
  _mdm_user_dir_acl_is_supported "$_dir" || return 1
  _mdm_component_effective_test "$_expected_uid" -x "$_dir" || return 1
  _after="$(_mdm_stat_dir_identity "$_dir")" || return 1
  [[ "$_after" == "$_before" ]] || return 1
  _mdm_user_dir_acl_is_supported "$_dir" || return 1
  [[ "$(_mdm_stat_dir_identity "$_dir")" == "$_before" ]]
}

_mdm_user_dir_acl_is_supported() { # <target-owned-dir>
  local _dir="$1" _listing _first _permissions _entries
  _mdm_is_darwin || return 0
  _listing="$(LC_ALL=C /bin/ls -lde "$_dir" 2>/dev/null)" || return 1
  _first="${_listing%%$'\n'*}"
  _permissions="${_first%%[[:space:]]*}"
  [[ "$_first" == *[[:space:]]* \
    && "$_permissions" =~ ^d[rwxStTs-]{9}[@+]?$ ]] || return 1
  if [[ "$_listing" != *$'\n'* ]]; then
    [[ "$_permissions" != *+* ]]
    return
  fi
  _entries="${_listing#*$'\n'}"
  [[ "$_entries" == ' 0: group:everyone deny delete' ]]
}

_mdm_home_acl_is_supported() { # <home>
  _mdm_user_dir_acl_is_supported "$1"
}

_mdm_home_boundary_is_safe() { # <home> <target-uid>
  local _home="$1" _uid="$2"
  _mdm_target_dir_is_accessible "$_home" "$_uid" || return 1
  # Rebind the path and ACL after the first complete boundary check.
  _mdm_target_dir_is_accessible "$_home" "$_uid"
}

_mdm_persistent_checkout_trusted() { # <install-dir> <target-uid> <workspace>
  local _install="$1" _expected_uid="$2" _workspace="$3"
  local _before _git_before _mode _marker _snapshot _value _extra="" _rc=1
  local _git_dir="$_install/.git"
  _MDM_DETECT_PERSISTENT_IDENTITY=""
  _MDM_DETECT_GIT_IDENTITY=""
  [[ "$_expected_uid" =~ ^[0-9]+$ && -d "$_workspace" \
    && ! -L "$_workspace" ]] || return 1
  _before="$(_mdm_stat_dir_identity "$_install")" || return 1
  _mdm_target_dir_matches_identity "$_install" "$_expected_uid" "$_before" \
    || return 1
  _git_before="$(_mdm_stat_dir_identity "$_git_dir")" || return 1
  _mdm_target_dir_matches_identity "$_git_dir" "$_expected_uid" \
    "$_git_before" || return 1

  _marker="$_install/.claude-starter-kit-mdm-managed"
  _snapshot="$_workspace/persistent-marker"
  _mdm_snapshot_bound_file "$_marker" "$_snapshot" managed \
    "$_expected_uid" || return 1
  _mode="$_MDM_DETECT_SNAPSHOT_MODE"
  if [[ "$_mode" == 0444 && "$_MDM_DETECT_SNAPSHOT_SIZE" == 36 ]]; then
    exec 6<"$_snapshot" || { /bin/rm -f "$_snapshot"; return 1; }
    if IFS= read -r _value <&6 \
      && ! IFS= read -r _extra <&6 \
      && [[ -z "$_extra" ]] \
      && [[ "$_value" == claude-code-starter-kit-mdm-user-v1 ]]; then
      _rc=0
    fi
    exec 6<&-
  fi
  /bin/rm -f "$_snapshot"
  [[ "$_rc" -eq 0 ]] || return 1
  _mdm_target_dir_matches_identity "$_install" "$_expected_uid" "$_before" \
    && _mdm_target_dir_matches_identity \
      "$_git_dir" "$_expected_uid" "$_git_before" || return 1
  _MDM_DETECT_PERSISTENT_IDENTITY="$_before"
  _MDM_DETECT_GIT_IDENTITY="$_git_before"
}

_mdm_required_component_present() { # <receipt> <component>
  local _receipt="$1" _wanted="$2" _count _index _value
  _count="$(_mdm_json_array_count "$_receipt" required_components)"
  [[ "$_count" =~ ^[0-9]+$ ]] || return 1
  _index=0
  while (( _index < _count )); do
    _value="$(_mdm_json_array_get "$_receipt" required_components "$_index")"
    [[ "$_value" == "$_wanted" ]] && return 0
    _index=$((_index + 1))
  done
  return 1
}

_mdm_required_components_are_valid() {
  local _receipt="$1" _count _index _value _previous="" _kit=0 LC_ALL=C
  local _node=0 _safety=0 _web=0
  _count="$(_mdm_json_array_count "$_receipt" required_components)"
  [[ "$_count" =~ ^[0-9]+$ && "$_count" -ge 1 && "$_count" -le 8 ]] || return 1
  _index=0
  while (( _index < _count )); do
    _mdm_json_type_is "$_receipt" "required_components.$_index" string \
      || return 1
    _value="$(_mdm_json_array_get "$_receipt" required_components "$_index")"
    case "$_value" in
      biome|claude_cli|fonts|ghostty|kit|node_runtime|safety_net|web_content_runtime) : ;;
      *) return 1 ;;
    esac
    [[ -z "$_previous" || "$_previous" < "$_value" ]] || return 1
    [[ "$_value" != kit ]] || _kit=$((_kit + 1))
    [[ "$_value" != node_runtime ]] || _node=$((_node + 1))
    [[ "$_value" != safety_net ]] || _safety=$((_safety + 1))
    [[ "$_value" != web_content_runtime ]] || _web=$((_web + 1))
    _previous="$_value"
    _index=$((_index + 1))
  done
  [[ "$_kit" -eq 1 ]] || return 1
  if [[ "$_safety" -eq 1 || "$_web" -eq 1 ]]; then
    [[ "$_node" -eq 1 ]]
  else
    [[ "$_node" -eq 0 ]]
  fi
}

_mdm_managed_history_is_valid() { # <user> <uid> <generated-uid> <home> <workspace>
  local _user="$1" _expected_uid="$2" _generated_uid="$3"
  local _home="$4" _workspace="$5"
  local _base _owner _history _snapshot _canonical
  local _count _index=0 _relative
  _base="$(_mdm_receipt_trust_base)" || return 1
  _owner="$(_mdm_expected_trust_owner)" || return 1
  _history="$_base/ClaudeCodeStarterKit/managed-history-$_generated_uid.json"
  _mdm_trusted_component "$_history" "$_owner" file || return 1
  _canonical="$(_mdm_canonical_file "$_history")" || return 1
  [[ "$_canonical" == "$_history" ]] || return 1
  _snapshot="$_workspace/managed-history.json"
  _mdm_snapshot_bound_file "$_history" "$_snapshot" history || return 1
  [[ "$_MDM_DETECT_SNAPSHOT_MODE" == 0600 ]] || return 1

  _mdm_json_type_is "$_snapshot" schema_version integer || return 1
  _mdm_json_type_is "$_snapshot" target_user string || return 1
  _mdm_json_type_is "$_snapshot" target_uid integer || return 1
  _mdm_json_type_is "$_snapshot" target_generated_uid string || return 1
  _mdm_json_type_is "$_snapshot" home string || return 1
  _mdm_json_type_is "$_snapshot" managed_inventory array || return 1
  [[ "$(_mdm_json_get "$_snapshot" schema_version)" == 2 ]] || return 1
  [[ "$(_mdm_json_get "$_snapshot" target_user)" == "$_user" ]] || return 1
  [[ "$(_mdm_json_get "$_snapshot" target_uid)" == "$_expected_uid" ]] || return 1
  [[ "$(_mdm_json_get "$_snapshot" home)" == "$_home" ]] || return 1
  [[ "$(_mdm_json_get "$_snapshot" target_generated_uid)" \
    == "$_generated_uid" ]] || return 1
  _count="$(_mdm_json_array_count "$_snapshot" managed_inventory)"
  [[ "$_count" =~ ^[0-9]+$ && "$_count" -le 2000 ]] || return 1
  while (( _index < _count )); do
    _mdm_json_type_is "$_snapshot" "managed_inventory.$_index" string \
      || return 1
    _relative="$(_mdm_json_array_get \
      "$_snapshot" managed_inventory "$_index")"
    [[ -n "$_relative" && "$_relative" != /* \
      && ! "$_relative" =~ [[:cntrl:]] ]] || return 1
    case "/$_relative/" in */../*|*/./*|*//*) return 1 ;; esac
    _index=$((_index + 1))
  done
  return 0
}

_mdm_canonical_any() {
  local _path="$1" _target _dir _base _physical _hops=0
  while [[ -L "$_path" ]]; do
    _hops=$((_hops + 1))
    [[ "$_hops" -le 40 ]] || return 1
    _target="$(_mdm_readlink_value "$_path")" || return 1
    if [[ "$_target" == /* ]]; then
      _path="$_target"
    else
      _path="${_path%/*}/$_target"
    fi
    _dir="${_path%/*}"; _base="${_path##*/}"
    _physical="$(builtin cd -P -- "$_dir" 2>/dev/null \
      && printf '%s' "$PWD")" || return 1
    _path="$_physical/$_base"
  done
  if [[ -d "$_path" ]]; then
    _mdm_canonical_dir "$_path"
  else
    _mdm_canonical_file "$_path"
  fi
}

_mdm_component_effective_test() { # <target-uid> <-r|-x> <path>
  local _uid="$1" _test="$2" _path="$3"
  [[ "$_uid" =~ ^[0-9]+$ ]] || return 1
  case "$_test" in -r|-x) : ;; *) return 1 ;; esac
  if [[ "$_MDM_DETECT_TEST_MODE" == 1 \
    && "$(/usr/bin/id -u 2>/dev/null || true)" == "$_uid" ]]; then
    /bin/test "$_test" "$_path"
  else
    [[ "$(/usr/bin/id -u 2>/dev/null || true)" == 0 \
      && -x /usr/bin/sudo ]] || return 1
    /usr/bin/sudo -n -u "#$_uid" /bin/test "$_test" "$_path" \
      >/dev/null 2>&1
  fi
}

_mdm_component_ancestors_searchable() { # <path> <target-uid> [home]
  local _path="$1" _uid="$2" _home="${3:-}" _current
  [[ "$_path" == /* && "$_uid" =~ ^[0-9]+$ ]] || return 1
  [[ -z "$_home" || "$_home" == /* ]] || return 1
  _current="${_path%/*}"
  [[ -n "$_current" ]] || _current=/
  while :; do
    [[ -d "$_current" && ! -L "$_current" ]] || return 1
    if [[ -n "$_home" ]]; then
      case "$_current" in
        "$_home"|"$_home"/*)
          _mdm_target_dir_is_accessible "$_current" "$_uid" || return 1 ;;
        *)
          _mdm_user_dir_acl_is_supported "$_current" || return 1
          _mdm_component_effective_test "$_uid" -x "$_current" || return 1 ;;
      esac
    else
      _mdm_user_dir_acl_is_supported "$_current" || return 1
      _mdm_component_effective_test "$_uid" -x "$_current" || return 1
    fi
    [[ "$_current" == / ]] && break
    _current="${_current%/*}"
    [[ -n "$_current" ]] || _current=/
  done
}

_mdm_component_path_accessible() { # <canonical-command> <target-uid> [home]
  _mdm_component_ancestors_searchable "$1" "$2" "${3:-}" \
    && _mdm_component_effective_test "$2" -x "$1"
}

_mdm_component_tree_accessible() { # <canonical-tree> <target-uid> [home]
  [[ -d "$1" && ! -L "$1" ]] || return 1
  _mdm_component_ancestors_searchable "$1" "$2" "${3:-}" || return 1
  if [[ -n "${3:-}" ]]; then
    case "$1" in
      "$3"|"$3"/*) _mdm_target_dir_is_accessible "$1" "$2" || return 1 ;;
      *) ! _mdm_has_acl "$1" || return 1 ;;
    esac
  else
    ! _mdm_has_acl "$1" || return 1
  fi
  _mdm_component_effective_test "$2" -r "$1" \
    && _mdm_component_effective_test "$2" -x "$1"
}

_mdm_component_file_readable() { # <canonical-file> <target-uid> [home]
  [[ -f "$1" && ! -L "$1" ]] || return 1
  _mdm_component_ancestors_searchable "$1" "$2" "${3:-}" \
    && ! _mdm_has_acl "$1" \
    && _mdm_component_effective_test "$2" -r "$1"
}

_mdm_component_owner_is_valid() { # <component> <path> <home> <target-uid>
  local _component="$1" _path="$2" _home="$3" _uid="$4" _actual
  local _expected_owner
  _actual="$(_mdm_stat_uid "$_path")" || return 1
  case "$_component" in
    kit|claude_cli|fonts|safety_net)
      [[ "$_actual" == "$_uid" ]] ;;
    biome)
      case "$_path" in
        "$_home/"*) [[ "$_actual" == "$_uid" ]] ;;
        *) [[ "$_actual" == 0 || "$_actual" == "$_uid" ]] ;;
      esac ;;
    ghostty) [[ "$_actual" == 0 || "$_actual" == "$_uid" ]] ;;
    node_runtime|web_content_runtime)
      _expected_owner="$(_mdm_expected_trust_owner)" || return 1
      [[ "$(_mdm_stat_owner "$_path")" == "$_expected_owner" ]] ;;
    *) return 1 ;;
  esac
}

_mdm_component_command_path() { # <home> <command> <target-uid>
  local _home="$1" _command="$2" _uid="$3"
  local _root _link _target _value _metadata _mode _dir _relative _link_value
  case "$_command" in
    biome)
      _root="$_home/.local/lib/claude-code-starter-kit/biome/2.5.4"
      _relative=biome ;;
    cc-safety-net)
      _root="$_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6"
      _relative=bin/cc-safety-net ;;
    *) return 1 ;;
  esac
  _link="$_home/.local/bin/$_command"
  _target="$_root/$_relative"
  _link_value="../lib/claude-code-starter-kit/$_command/${_root##*/}/$_relative"
  for _dir in "$_home" "$_home/.local" "$_home/.local/bin" \
    "$_home/.local/lib" "$_home/.local/lib/claude-code-starter-kit" \
    "${_root%/*}" "$_root"; do
    _mdm_target_dir_is_accessible "$_dir" "$_uid" || return 1
  done
  _dir="${_target%/*}"
  while [[ "$_dir" != "$_root" ]]; do
    _mdm_target_dir_is_accessible "$_dir" "$_uid" || return 1
    _dir="${_dir%/*}"
  done
  [[ -L "$_link" && "$(_mdm_stat_uid "$_link")" == "$_uid" ]] \
    || return 1
  ! _mdm_has_acl "$_link" || return 1
  _metadata="$(_mdm_stat_metadata "$_link")" || return 1
  [[ "${_metadata##*:}" == 1 ]] || return 1
  _value="$(_mdm_readlink_value "$_link")" || return 1
  [[ "$_value" == "$_link_value" ]] || return 1
  [[ -f "$_target" && ! -L "$_target" \
    && "$(_mdm_canonical_file "$_target")" == "$_target" \
    && "$(_mdm_stat_uid "$_target")" == "$_uid" ]] || return 1
  _mode="$(_mdm_stat_mode "$_target")" || return 1
  _mdm_mode_owner_executable "$_mode" || return 1
  _mdm_component_path_accessible "$_link" "$_uid" "$_home" || return 1
  _mdm_component_path_accessible "$_target" "$_uid" "$_home" || return 1
  printf '%s' "$_target"
}

_mdm_safety_package_root() { # <home> <canonical-command>
  local _home="$1" _command="$2" _root _canonical
  _root="$_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6"
  _canonical="$(_mdm_canonical_dir "$_root")" || return 1
  [[ "$_canonical" == "$_root" ]] || return 1
  [[ "$_command" == "$_root/bin/cc-safety-net" ]] || return 1
  printf '%s' "$_root"
}

_mdm_biome_package_root() { # <home> <canonical-command>
  local _home="$1" _command="$2" _root _canonical
  _root="$_home/.local/lib/claude-code-starter-kit/biome/2.5.4"
  _canonical="$(_mdm_canonical_dir "$_root")" || return 1
  [[ "$_canonical" == "$_root" && "$_command" == "$_root/biome" ]] || return 1
  printf '%s' "$_root"
}

_mdm_private_component_shape_is_valid() { # <biome|safety_net> <tree>
  local _component="$1" _root="$2" _python
  case "$_component" in biome|safety_net) : ;; *) return 1 ;; esac
  _python="$(_mdm_detect_system_python)" || return 1
  "$_python" -I -B - "$_component" "$_root" <<'PY'
import os
import stat
import sys

component, root = sys.argv[1:]
try:
    if component == "biome":
        expected = {
            "": {"biome", "package.json"},
        }
        files = {"biome", "package.json"}
        directories = set()
    else:
        expected = {
            "": {"bin", "dist", "package.json"},
            "bin": {"cc-safety-net"},
            "dist": {"bin"},
            "dist/bin": {"cc-safety-net.js"},
        }
        files = {"bin/cc-safety-net", "dist/bin/cc-safety-net.js",
                 "package.json"}
        directories = {"bin", "dist", "dist/bin"}
    root_stat = os.lstat(root)
    if not stat.S_ISDIR(root_stat.st_mode):
        raise ValueError("component root is not a directory")
    for relative, names in expected.items():
        path = os.path.join(root, relative) if relative else root
        if set(os.listdir(path)) != names:
            raise ValueError("component inventory mismatch")
    for relative in files:
        if not stat.S_ISREG(os.lstat(os.path.join(root, relative)).st_mode):
            raise ValueError("component file type mismatch")
    for relative in directories:
        if not stat.S_ISDIR(os.lstat(os.path.join(root, relative)).st_mode):
            raise ValueError("component directory type mismatch")
except (OSError, ValueError):
    sys.exit(1)
PY
}

_mdm_component_version_is_valid() { # <component> <command> <uid> <home>
  local _component="$1" _command="$2" _uid="$3" _home="$4"
  local _expected _raw _value _rc=0
  case "$_component" in
    biome) _expected=2.5.4 ;;
    safety_net) _expected=1.0.6 ;;
    *) return 1 ;;
  esac
  if [[ "$_MDM_DETECT_TEST_MODE" == 1 \
    && "$(/usr/bin/id -u 2>/dev/null || true)" == "$_uid" ]]; then
    _raw="$({
      ( builtin cd -- "$_home" \
        && /usr/bin/env -i HOME="$_home" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
          "$_command" --version 2>/dev/null ) || _rc=$?
      printf '\036'
      exit "$_rc"
    })" || return 1
  else
    [[ "$(/usr/bin/id -u 2>/dev/null || true)" == 0 \
      && -x /usr/bin/sudo ]] || return 1
    _raw="$({
      /usr/bin/sudo -n -u "#$_uid" /usr/bin/env -i HOME="$_home" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        /bin/bash --noprofile --norc -c \
          'builtin cd -- "$1" && exec "$2" --version' \
          mdm-component-version "$_home" "$_command" 2>/dev/null || _rc=$?
      printf '\036'
      exit "$_rc"
    })" || return 1
  fi
  [[ "$_raw" == *$'\036' ]] || return 1
  _value="${_raw%$'\036'}"
  [[ "$_value" == *$'\n' ]] || return 1
  _value="${_value%$'\n'}"
  [[ "$_value" != *$'\n'* ]] || return 1
  case "$_value" in
    "$_expected"|"Version: $_expected"|"biome $_expected" \
      |"cc-safety-net $_expected") return 0 ;;
    *) return 1 ;;
  esac
}

_mdm_biome_tree_is_trusted() { # <tree> <command> <uid> <home>
  local _root="$1" _command="$2" _uid="$3" _home="$4"
  local _arch _binary_sha _package_sha
  _arch="$(_mdm_node_runtime_arch)" || return 1
  case "$_arch" in
    arm64)
      _binary_sha=1250bb41a0409cf6c3133fc47819237eb61251624297f87158d2bed3ec123c3c
      _package_sha=54947a4827f0a6960d84eae39de98dba707b6f9222a276beaaa54ab4014dc68c ;;
    x64)
      _binary_sha=b3dfae5422dbd86272bb8ed40afec66670ea7754531d8fbcbae7e445e5430387
      _package_sha=f25fac4d876cbd18fe78753dd06fde9a12607a76006546cf6a9549a8f1fb511f ;;
    *) return 1 ;;
  esac
  _mdm_private_component_shape_is_valid biome "$_root" || return 1
  [[ "$_command" == "$_root/biome" \
    && "$(_mdm_sha256 "$_root/biome")" == "$_binary_sha" \
    && "$(_mdm_sha256 "$_root/package.json")" == "$_package_sha" ]] \
    || return 1
  [[ "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_root/biome")")" == 0755 \
    && "$(_mdm_mode_normalize \
      "$(_mdm_stat_mode "$_root/package.json")")" == 0644 ]] || return 1
  _mdm_component_version_is_valid biome "$_command" "$_uid" "$_home"
}

_mdm_safety_wrapper_is_bound() { # <home> <wrapper> <private-node>
  local _home="$1" _wrapper="$2" _node="$3" _script _expected _python LC_ALL=C
  _script="$_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6/dist/bin/cc-safety-net.js"
  [[ "$_wrapper" \
    == "$_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6/bin/cc-safety-net" \
    && -f "$_script" && ! -L "$_script" ]] || return 1
  _expected="$({
    printf '#!/bin/bash\nunset NODE_OPTIONS NODE_PATH\nexec %q %q "$@"\n' \
      "$_node" "$_script"
    printf '\036'
  })" || return 1
  [[ "$_expected" == *$'\036' ]] || return 1
  _expected="${_expected%$'\036'}"
  _python="$(_mdm_detect_system_python)" || return 1
  "$_python" -I -B - "$_wrapper" "$_expected" <<'PY'
import os
import stat
import sys

path, expected_text = sys.argv[1:]
expected = os.fsencode(expected_text)

def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_uid, value.st_gid, value.st_size, value.st_mtime_ns,
            value.st_ctime_ns, getattr(value, "st_flags", 0),
            getattr(value, "st_gen", 0))

try:
    before = os.lstat(path)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                         | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(descriptor)
        if (not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1
                or opened.st_size != len(expected)
                or identity(opened) != identity(before)):
            raise ValueError("unsafe safety wrapper")
        chunks = []
        remaining = len(expected) + 1
        while remaining:
            chunk = os.read(descriptor, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        actual = b"".join(chunks)
    finally:
        os.close(descriptor)
    if actual != expected or identity(os.lstat(path)) != identity(before):
        raise ValueError("safety wrapper drift")
except (OSError, ValueError):
    raise SystemExit(1)
PY
}

_mdm_safety_tree_is_trusted() { # <home> <tree> <command> <node> <uid>
  local _home="$1" _root="$2" _command="$3" _node="$4" _uid="$5"
  _mdm_private_component_shape_is_valid safety_net "$_root" || return 1
  [[ "$_command" == "$_root/bin/cc-safety-net" \
    && "$(_mdm_sha256 "$_root/dist/bin/cc-safety-net.js")" \
      == 1ffbfafabf2fe4fc9b6bf64a8088ca3a96c2714cf8fd8afd5b1b326582c982d4 \
    && "$(_mdm_sha256 "$_root/package.json")" \
      == 2e57b465553ba97e1e6f7a37655fc52e31cad4ca739140bb7af40d052e3d88c8 ]] \
    || return 1
  [[ "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_command")")" == 0755 \
    && "$(_mdm_mode_normalize \
      "$(_mdm_stat_mode "$_root/dist/bin/cc-safety-net.js")")" == 0644 \
    && "$(_mdm_mode_normalize \
      "$(_mdm_stat_mode "$_root/package.json")")" == 0644 ]] || return 1
  _mdm_safety_wrapper_is_bound "$_home" "$_command" "$_node" || return 1
  _mdm_component_version_is_valid safety_net "$_command" "$_uid" "$_home"
}

_mdm_node_runtime_root() {
  local _base _arch
  _base="$(_mdm_receipt_trust_base)" || return 1
  _arch="$(_mdm_node_runtime_arch)" || return 1
  printf '%s' "$_base/ClaudeCodeStarterKit/runtime/node-v24.18.0-darwin-$_arch"
}

_mdm_node_runtime_source() { # <arch> <url-var> <sha256-var>
  local _arch="$1" _url_var="$2" _sha_var="$3"
  local _resolved_url _resolved_sha
  [[ "$_url_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_sha_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  _resolved_url="https://nodejs.org/dist/v24.18.0/node-v24.18.0-darwin-${_arch}.tar.xz"
  case "$_arch" in
    arm64) _resolved_sha=4477b9f78efb77744cf5eb57a0e9594dba66466b38b4e93fa9f35cb907a095a6 ;;
    x64) _resolved_sha=4a3b6bc81542154430825128d9a279e8b364e8d90581544e506ef7579fd1ab6f ;;
    *) return 1 ;;
  esac
  printf -v "$_url_var" '%s' "$_resolved_url"
  printf -v "$_sha_var" '%s' "$_resolved_sha"
}

_mdm_node_runtime_expected_content_sha256() { # <logical-arch>
  local _override
  if _override="$(_mdm_test_value \
      MDM_DETECT_NODE_CONTENT_SHA256_OVERRIDE)"; then
    [[ "$_override" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$_override"
    return 0
  fi
  case "$1" in
    arm64) printf '%s' 3b87679d20e675468b9281755c823b528b6406ba7af6cc7086ef00e5c8af6533 ;;
    x64) printf '%s' a9f69014ea08981c1b1822f565a39ae6970a319518ebf3e43d96ba9fc70aa209 ;;
    *) return 1 ;;
  esac
}

# Owner, group, timestamps, xattrs, and the local provenance marker are not
# release content. Everything else is canonicalized exactly like the pinned
# official tar inventory: UTF-8 byte-sorted path/type/mode plus file bytes or
# symlink target.
_mdm_node_runtime_content_sha256() { # <runtime-tree>
  local _tree="$1" _python
  _python="$(_mdm_detect_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B - "$_tree" \
      .claude-code-starter-kit-node-runtime <<'PY'
import hashlib
import json
import os
import stat
import sys

root, provenance = sys.argv[1:]
records = []
count = 0
total = 0


def visit(path, relative):
    global count, total
    before = os.lstat(path)
    count += 1
    if count > 100000:
        raise ValueError("runtime inventory too large")
    mode = format(stat.S_IMODE(before.st_mode), "04o")
    base = {"path": relative, "mode": mode}
    if stat.S_ISDIR(before.st_mode):
        records.append(dict(base, kind="dir"))
        names = sorted(os.listdir(path), key=lambda value: value.encode("utf-8", "strict"))
        for name in names:
            if not relative and name == provenance:
                continue
            visit(os.path.join(path, name), name if not relative else relative + "/" + name)
        if sorted(os.listdir(path), key=lambda value: value.encode("utf-8", "strict")) != names:
            raise ValueError("runtime inventory changed")
    elif stat.S_ISREG(before.st_mode):
        digest = hashlib.sha256()
        size = 0
        with open(path, "rb", buffering=0) as handle:
            while True:
                block = handle.read(1024 * 1024)
                if not block:
                    break
                digest.update(block)
                size += len(block)
                total += len(block)
                if size > 512 * 1024 * 1024 or total > 2 * 1024 * 1024 * 1024:
                    raise ValueError("runtime content too large")
        if size != before.st_size:
            raise ValueError("runtime file changed")
        records.append(dict(base, kind="file", sha256=digest.hexdigest(), size=size))
    elif stat.S_ISLNK(before.st_mode):
        target = os.readlink(path)
        target.encode("utf-8", "strict")
        records.append(dict(base, kind="symlink", mode="0777", target=target))
    else:
        raise ValueError("unsupported runtime entry")
    after = os.lstat(path)
    if (before.st_dev, before.st_ino, before.st_mode, before.st_nlink,
            before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
            after.st_dev, after.st_ino, after.st_mode, after.st_nlink,
            after.st_size, after.st_mtime_ns, after.st_ctime_ns):
        raise ValueError("runtime entry changed")


try:
    visit(root, "")
    records.sort(key=lambda value: value["path"].encode("utf-8", "strict"))
    canonical = (json.dumps(records, ensure_ascii=True, sort_keys=True,
                            separators=(",", ":")) + "\n").encode("ascii")
    print(hashlib.sha256(canonical).hexdigest())
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
}

_mdm_node_sysctl() {
  /usr/sbin/sysctl "$@"
}

_mdm_node_uname() {
  /usr/bin/uname "$@"
}

_mdm_node_runtime_arch() {
  local _arm64 _machine
  if _mdm_is_darwin; then
    # Intel macOS does not expose hw.optional.arm64.  -i turns that expected
    # unknown OID into an empty value, while the hardware bit remains stable
    # across native and Rosetta-translated processes on Apple Silicon.
    _arm64="$(_mdm_node_sysctl -in hw.optional.arm64 2>/dev/null)" || return 1
    _machine="$(_mdm_node_uname -m 2>/dev/null)" || return 1
    case "$_arm64:$_machine" in
      1:arm64|1:x86_64) printf '%s' arm64 ;;
      0:x86_64|:x86_64) printf '%s' x64 ;;
      *) return 1 ;;
    esac
  else
    case "$(_mdm_node_uname -m 2>/dev/null)" in
      arm64|aarch64) printf '%s' arm64 ;;
      x86_64) printf '%s' x64 ;;
      *) return 1 ;;
    esac
  fi
}

_mdm_wce_runtime_root() {
  local _base _arch
  _base="$(_mdm_receipt_trust_base)" || return 1
  _arch="$(_mdm_node_runtime_arch)" || return 1
  printf '%s' \
    "$_base/ClaudeCodeStarterKit/runtime/web-content-extraction/node-v24.18.0-npm-v11.16.0-darwin-$_arch/e63fb86cb553a034ecafd4ca11334d317b8b5d115775daa728e56c3bf5b1749c-f39ea3b4028710e986afb1c423b7895845e0d41839521e6cee866ed37cdb33cd"
}

_mdm_wce_runtime_marker_is_valid() { # <runtime-root>
  local _root="$1" _marker _arch _python
  _marker="$_root/.claude-code-starter-kit-wce-runtime.json"
  _arch="$(_mdm_node_runtime_arch)" || return 1
  _python="$(_mdm_detect_system_python)" || return 1
  "$_python" -I -B - "$_marker" "$_arch" <<'PY'
import os
import stat
import sys

path, arch = sys.argv[1:]
package_digest = "e63fb86cb553a034ecafd4ca11334d317b8b5d115775daa728e56c3bf5b1749c"
lock_digest = "f39ea3b4028710e986afb1c423b7895845e0d41839521e6cee866ed37cdb33cd"
expected = (
    f'{{"arch":"{arch}","lock_sha256":"{lock_digest}",'
    f'"node_version":"v24.18.0","npm_version":"11.16.0",'
    f'"package_sha256":"{package_digest}",'
    '"registry":"https://registry.npmjs.org/","schema_version":1}\n'
).encode("ascii")

def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_uid, value.st_gid, value.st_size, value.st_mtime_ns,
            value.st_ctime_ns, getattr(value, "st_flags", 0),
            getattr(value, "st_gen", 0))

try:
    before = os.lstat(path)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                         | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(descriptor)
        if (not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1
                or identity(opened) != identity(before)
                or opened.st_size != len(expected)):
            raise ValueError("unsafe WCE marker")
        actual = os.read(descriptor, len(expected) + 1)
    finally:
        os.close(descriptor)
    if actual != expected or identity(os.lstat(path)) != identity(before):
        raise ValueError("WCE marker mismatch")
except (OSError, ValueError):
    sys.exit(1)
PY
}

_mdm_wce_runtime_metadata_is_valid() { # <runtime-root>
  local _root="$1" _base _managed _expected_uid _expected_gid _python
  _base="$(_mdm_receipt_trust_base)" || return 1
  _managed="$_base/ClaudeCodeStarterKit"
  if [[ "$_MDM_DETECT_TEST_MODE" == 1 ]]; then
    _expected_uid="$(_mdm_stat_uid "$_managed")" || return 1
    _expected_gid="$(_mdm_stat_gid "$_managed")" || return 1
  else
    _expected_uid=0
    _expected_gid=0
  fi
  _python="$(_mdm_detect_system_python)" || return 1
  "$_python" -I -B - "$_base" "$_root" \
    "$_expected_uid" "$_expected_gid" <<'PY'
import ctypes
import errno
import json
import os
import re
import stat
import sys

base, root, uid_text, gid_text = sys.argv[1:]
expected_uid = int(uid_text)
expected_gid = int(gid_text)
expected_top = {
    ".claude-code-starter-kit-wce-runtime.json",
    "package.json",
    "package-lock.json",
    "node_modules",
}
fixed_files = expected_top - {"node_modules"}
prefix = os.path.join(base, "ClaudeCodeStarterKit")
count = 0
package_part = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._~-]*$")
libc = ctypes.CDLL(None, use_errno=True)

if sys.platform == "darwin":
    libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p,
                               ctypes.c_size_t, ctypes.c_int]
    libc.listxattr.restype = ctypes.c_ssize_t
else:
    libc.llistxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p,
                                ctypes.c_size_t]
    libc.llistxattr.restype = ctypes.c_ssize_t

def xattrs_are_safe(path):
    encoded = os.fsencode(path)
    ctypes.set_errno(0)
    if sys.platform == "darwin":
        size = libc.listxattr(encoded, None, 0, 0x0001)
    else:
        size = libc.llistxattr(encoded, None, 0)
    if size < 0:
        error = ctypes.get_errno()
        raise OSError(error or errno.EIO, "listxattr")
    if size == 0:
        return True
    buffer = ctypes.create_string_buffer(size)
    ctypes.set_errno(0)
    if sys.platform == "darwin":
        actual = libc.listxattr(encoded, buffer, size, 0x0001)
    else:
        actual = libc.llistxattr(encoded, buffer, size)
    if actual < 0:
        error = ctypes.get_errno()
        raise OSError(error or errno.EIO, "listxattr")
    raw = bytes(buffer.raw[:actual])
    if actual != size or not raw.endswith(b"\0"):
        return False
    names = raw[:-1].split(b"\0")
    allowed = {b"com.apple.provenance"} if sys.platform == "darwin" else set()
    return len(names) == len(set(names)) and set(names).issubset(allowed)

def valid_package_name(name):
    if not isinstance(name, str):
        return False
    parts = name.split("/")
    if len(parts) == 1:
        return package_part.fullmatch(parts[0]) is not None
    return (len(parts) == 2 and parts[0].startswith("@")
            and package_part.fullmatch(parts[0][1:]) is not None
            and package_part.fullmatch(parts[1]) is not None)

try:
    relative = os.path.relpath(root, prefix)
    if relative == os.pardir or relative.startswith(os.pardir + os.sep):
        raise ValueError("runtime escapes trust prefix")
    current = prefix
    for segment in relative.split(os.sep):
        value = os.lstat(current)
        if (not stat.S_ISDIR(value.st_mode) or stat.S_IMODE(value.st_mode) != 0o755
                or value.st_uid != expected_uid or value.st_gid != expected_gid):
            raise ValueError("unsafe WCE parent")
        current = os.path.join(current, segment)
    if set(os.listdir(root)) != expected_top:
        raise ValueError("unexpected WCE top-level inventory")
    for current, directories, files in os.walk(root, topdown=True,
                                                followlinks=False):
        paths = [current] + [os.path.join(current, name)
                             for name in directories + files]
        for path in paths:
            value = os.lstat(path)
            count += 1
            if (count > 100000 or value.st_uid != expected_uid
                    or value.st_gid != expected_gid
                    or not xattrs_are_safe(path)):
                raise ValueError("unsafe WCE metadata")
            mode = stat.S_IMODE(value.st_mode)
            if stat.S_ISDIR(value.st_mode):
                if mode != 0o755:
                    raise ValueError("unsafe WCE directory mode")
            elif stat.S_ISREG(value.st_mode):
                if value.st_nlink != 1 or mode not in (0o644, 0o755):
                    raise ValueError("unsafe WCE file mode")
            elif stat.S_ISLNK(value.st_mode):
                raise ValueError("WCE bundle symlink is not allowed")
            else:
                raise ValueError("unsupported WCE entry")
    for name in fixed_files:
        path = os.path.join(root, name)
        value = os.lstat(path)
        if not stat.S_ISREG(value.st_mode) or stat.S_IMODE(value.st_mode) != 0o644:
            raise ValueError("unsafe fixed WCE file")
    if not os.path.isdir(os.path.join(root, "node_modules")) \
            or os.path.islink(os.path.join(root, "node_modules")):
        raise ValueError("missing WCE node_modules")
    with open(os.path.join(root, "package.json"), "r", encoding="utf-8",
              errors="strict") as handle:
        package = json.load(handle)
        if handle.read() != "":
            raise ValueError("trailing package JSON data")
    dependencies = package.get("dependencies") if isinstance(package, dict) else None
    if not isinstance(dependencies, dict) or not dependencies:
        raise ValueError("missing WCE direct dependencies")
    for name, version in dependencies.items():
        if (not valid_package_name(name)
                or not isinstance(version, str) or not version):
            raise ValueError("unsafe WCE dependency declaration")
        parts = name.split("/")
        package_root = os.path.join(root, "node_modules", *parts)
        manifest = os.path.join(package_root, "package.json")
        root_value = os.lstat(package_root)
        manifest_value = os.lstat(manifest)
        if (not stat.S_ISDIR(root_value.st_mode)
                or not stat.S_ISREG(manifest_value.st_mode)
                or manifest_value.st_nlink != 1):
            raise ValueError("missing WCE direct dependency")
except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
    sys.exit(1)
PY
}


_mdm_wce_runtime_tree_is_trusted() { # <runtime-root>
  local _root="$1" _expected _base _managed _owner _uid _gid _managed_gid
  _expected="$(_mdm_wce_runtime_root)" || return 1
  [[ "$_root" == "$_expected" ]] || return 1
  _base="$(_mdm_receipt_trust_base)" || return 1
  _owner="$(_mdm_expected_trust_owner)" || return 1
  _managed="$_base/ClaudeCodeStarterKit"
  _mdm_runtime_system_ancestors_are_trusted || return 1
  if [[ "$_MDM_DETECT_TEST_MODE" != 1 ]]; then
    _uid=0; _gid=0; _managed_gid=0
  else
    _uid="$(_mdm_stat_uid "$_managed")" || return 1
    _gid="$(_mdm_stat_gid "$_managed")" || return 1
    _managed_gid="$_gid"
    _mdm_verify_trusted_dir_chain "$_managed" "$_base" "$_owner" || return 1
  fi
  _mdm_verify_trusted_dir_chain_exact_mode \
    "$_root" "$_managed" "$_owner" 0755 "$_managed_gid" || return 1
  _mdm_wce_runtime_metadata_is_valid "$_root" || return 1
  _mdm_wce_runtime_marker_is_valid "$_root" || return 1
  [[ "$(_mdm_sha256 "$_root/package.json")" \
      == e63fb86cb553a034ecafd4ca11334d317b8b5d115775daa728e56c3bf5b1749c \
    && "$(_mdm_sha256 "$_root/package-lock.json")" \
      == f39ea3b4028710e986afb1c423b7895845e0d41839521e6cee866ed37cdb33cd ]] \
    || return 1
  _mdm_artifact_digest tree "$_root" "$_uid" "$_gid" >/dev/null
}

_mdm_wce_activation_record() { # <home> <target-uid> [runtime-root]
  local _home="$1" _uid="$2" _root="${3:-}" _link _target _dir _python
  [[ -n "$_root" ]] || _root="$(_mdm_wce_runtime_root)" || return 1
  _target="$_root/node_modules"
  _link="$_home/.claude/skills/web-content-extraction/node_modules"
  for _dir in "$_home" "$_home/.claude" "$_home/.claude/skills" \
    "$_home/.claude/skills/web-content-extraction"; do
    _mdm_target_dir_is_accessible "$_dir" "$_uid" || return 1
  done
  ! _mdm_has_acl "$_link" || return 1
  [[ "$(_mdm_canonical_dir "$_target")" == "$_target" ]] || return 1
  _mdm_component_ancestors_searchable "$_target" "$_uid" || return 1
  _mdm_component_effective_test "$_uid" -r "$_target" || return 1
  _mdm_component_effective_test "$_uid" -x "$_target" || return 1
  _python="$(_mdm_detect_system_python)" || return 1
  "$_python" -I -B - "$_link" "$_target" "$_uid" <<'PY'
import os
import stat
import sys

path, expected, uid_text = sys.argv[1:]
uid = int(uid_text)

def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_uid, value.st_gid, value.st_size, value.st_mtime_ns,
            value.st_ctime_ns, getattr(value, "st_flags", 0),
            getattr(value, "st_gen", 0))

try:
    before = os.lstat(path)
    first = os.readlink(path)
    second = os.readlink(path)
    after = os.lstat(path)
    if (not stat.S_ISLNK(before.st_mode) or before.st_nlink != 1
            or before.st_uid != uid or first != expected or second != expected
            or identity(after) != identity(before)):
        raise ValueError("unsafe WCE activation")
    print(":".join(str(value) for value in identity(before)), end="")
except (OSError, ValueError):
    sys.exit(1)
PY
}

_mdm_node_runtime_provenance_is_valid() { # <runtime-root>
  local _root="$1" _marker _arch _url _sha _python
  _marker="$_root/.claude-code-starter-kit-node-runtime"
  _arch="$(_mdm_node_runtime_arch)" || return 1
  _mdm_node_runtime_source "$_arch" _url _sha || return 1
  _python="$(_mdm_detect_system_python)" || return 1
  "$_python" -I -B - "$_marker" "$_arch" "$_url" "$_sha" <<'PY'
import os
import stat
import sys

path, arch, url, digest = sys.argv[1:]
expected = (f"schema=1\nversion=v24.18.0\narch={arch}\n"
            f"url={url}\nsha256={digest}\n").encode("ascii")

def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_uid, value.st_gid, value.st_size, value.st_mtime_ns,
            value.st_ctime_ns, getattr(value, "st_flags", 0),
            getattr(value, "st_gen", 0))

try:
    before = os.lstat(path)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
                         | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(descriptor)
        if (not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1
                or identity(opened) != identity(before)
                or opened.st_size != len(expected)):
            raise ValueError("unsafe provenance marker")
        actual = os.read(descriptor, len(expected) + 1)
    finally:
        os.close(descriptor)
    if actual != expected or identity(os.lstat(path)) != identity(before):
        raise ValueError("provenance mismatch")
except (OSError, ValueError):
    sys.exit(1)
PY
}

_mdm_node_runtime_metadata_is_valid() { # <runtime-root>
  local _root="$1" _expected_uid _expected_gid _python
  if [[ "$_MDM_DETECT_TEST_MODE" == 1 ]]; then
    _expected_uid="$(_mdm_stat_uid "$_root")" || return 1
    _expected_gid="$(_mdm_stat_gid "$_root")" || return 1
  else
    _expected_uid=0
    _expected_gid=0
  fi
  _python="$(_mdm_detect_system_python)" || return 1
  "$_python" -I -B - "$_root" "$_expected_uid" "$_expected_gid" <<'PY'
import os
import stat
import sys

root = sys.argv[1]
expected_uid = int(sys.argv[2])
expected_gid = int(sys.argv[3])
count = 0

try:
    for current, directories, files in os.walk(root, topdown=True,
                                                followlinks=False):
        names = [current] + [os.path.join(current, name)
                             for name in directories + files]
        for path in names:
            value = os.lstat(path)
            count += 1
            if count > 200000 or value.st_uid != expected_uid \
                    or value.st_gid != expected_gid:
                raise ValueError("runtime ownership mismatch")
            if stat.S_ISREG(value.st_mode):
                if value.st_nlink != 1 or value.st_mode & 0o022:
                    raise ValueError("unsafe runtime file")
            elif stat.S_ISDIR(value.st_mode):
                if value.st_mode & 0o022:
                    raise ValueError("unsafe runtime directory")
            elif stat.S_ISLNK(value.st_mode):
                if value.st_nlink != 1:
                    raise ValueError("unsafe runtime symlink")
            else:
                raise ValueError("unsupported runtime entry")
    if count < 1:
        raise ValueError("empty runtime")
except (OSError, ValueError):
    sys.exit(1)
PY
}

_mdm_node_runtime_bundled_npm_is_valid() { # <runtime-root>
  local _root="$1"
  local _npm="$_root/bin/npm" _npx="$_root/bin/npx"
  local _npm_target _npx_target
  [[ -L "$_npm" && -x "$_npm" && -L "$_npx" && -x "$_npx" \
    && -f "$_root/lib/node_modules/npm/package.json" \
    && ! -L "$_root/lib/node_modules/npm/package.json" ]] || return 1
  _npm_target="$(_mdm_readlink_value "$_npm")" || return 1
  _npx_target="$(_mdm_readlink_value "$_npx")" || return 1
  [[ "$_npm_target" == ../lib/node_modules/npm/bin/npm-cli.js \
    && "$_npx_target" == ../lib/node_modules/npm/bin/npx-cli.js \
    && -f "$_root/lib/node_modules/npm/bin/npm-cli.js" \
    && ! -L "$_root/lib/node_modules/npm/bin/npm-cli.js" \
    && -f "$_root/lib/node_modules/npm/bin/npx-cli.js" \
    && ! -L "$_root/lib/node_modules/npm/bin/npx-cli.js" ]]
}

_mdm_node_runtime_npm_version_is_valid() { # <runtime-root> <target-uid> <home>
  local _root="$1" _uid="$2" _home="$3"
  local _npm="$_root/bin/npm"
  local _raw _value _rc=0
  _mdm_node_runtime_bundled_npm_is_valid "$_root" || return 1
  if [[ "$_MDM_DETECT_TEST_MODE" == 1 \
    && "$(/usr/bin/id -u 2>/dev/null || true)" == "$_uid" ]]; then
    _raw="$({
      ( builtin cd -- "$_home" \
        && /usr/bin/env -i HOME="$_home" \
          "PATH=$_root/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
          "$_npm" --version 2>/dev/null ) || _rc=$?
      printf '\036'
      exit "$_rc"
    })" || return 1
  else
    [[ "$(/usr/bin/id -u 2>/dev/null || true)" == 0 \
      && -x /usr/bin/sudo ]] || return 1
    _raw="$({
      /usr/bin/sudo -n -u "#$_uid" /usr/bin/env -i HOME="$_home" \
        "PATH=$_root/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        /bin/bash --noprofile --norc -c \
          'builtin cd -- "$1" && exec "$2" --version' \
          mdm-npm-version "$_home" "$_npm" 2>/dev/null || _rc=$?
      printf '\036'
      exit "$_rc"
    })" || return 1
  fi
  [[ "$_raw" == *$'\036' ]] || return 1
  _value="${_raw%$'\036'}"
  [[ "$_value" == $'11.16.0\n' ]]
}

_mdm_node_lipo() {
  /usr/bin/lipo "$@"
}

_mdm_node_otool() {
  /usr/bin/otool "$@"
}

_mdm_node_runtime_platform_is_valid() { # <node-binary> <target-uid> <home>
  local _node="$1" _uid="$2" _home="$3" _arch _mach _line _dependency
  local _count=0 _otool _raw _value _rc=0
  _arch="$(_mdm_node_runtime_arch)" || return 1
  [[ "$_uid" =~ ^[0-9]+$ && -d "$_home" && ! -L "$_home" ]] || return 1
  [[ "$(type -t _mdm_node_lipo)" == function \
    && "$(type -t _mdm_node_otool)" == function ]] || return 1
  _mach="$(_mdm_node_lipo -archs "$_node" 2>/dev/null)" || return 1
  case "$_arch:$_mach" in arm64:arm64|x64:x86_64) : ;; *) return 1 ;; esac
  _otool="$({
    _mdm_node_otool -L "$_node" 2>/dev/null || exit 1
    printf '\036'
  })" || return 1
  [[ "$_otool" == *$'\036' ]] || return 1
  _otool="${_otool%$'\036'}"
  while IFS= read -r _line; do
    [[ -n "$_line" ]] || continue
    case "$_line" in
      "$_node:") continue ;;
    esac
    _dependency="${_line#${_line%%[![:space:]]*}}"
    _dependency="${_dependency%%[[:space:]]*}"
    case "$_dependency" in /usr/lib/*|/System/Library/*) : ;; *) return 1 ;; esac
    _count=$((_count + 1))
  done <<< "$_otool"
  [[ "$_count" -ge 1 ]] || return 1
  if [[ "$_MDM_DETECT_TEST_MODE" == 1 \
    && "$(/usr/bin/id -u 2>/dev/null || true)" == "$_uid" ]]; then
    _raw="$({
      ( builtin cd -- "$_home" \
        && /usr/bin/env -i HOME="$_home" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
          "$_node" -p process.arch 2>/dev/null ) || _rc=$?
      printf '\036'
      exit "$_rc"
    })" || return 1
  else
    [[ "$(/usr/bin/id -u 2>/dev/null || true)" == 0 \
      && -x /usr/bin/sudo ]] || return 1
    _raw="$({
      /usr/bin/sudo -n -u "#$_uid" /usr/bin/env -i HOME="$_home" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        /bin/bash --noprofile --norc -c \
          'builtin cd -- "$1" && exec "$2" -p process.arch' \
          mdm-node-arch "$_home" "$_node" 2>/dev/null || _rc=$?
      printf '\036'
      exit "$_rc"
    })" || return 1
  fi
  [[ "$_raw" == *$'\036' ]] || return 1
  _value="${_raw%$'\036'}"
  [[ "$_value" == *$'\n' ]] || return 1
  _value="${_value%$'\n'}"
  [[ "$_value" != *$'\n'* ]] || return 1
  case "$_arch:$_value" in arm64:arm64|x64:x64) : ;; *) return 1 ;; esac
}

_mdm_node_runtime_tree_is_trusted() { # <runtime-root>
  local _root="$1" _expected _base _managed _owner _node _mode _arch
  local _content _expected_content _managed_gid
  _expected="$(_mdm_node_runtime_root)" || return 1
  [[ "$_root" == "$_expected" ]] || return 1
  _base="$(_mdm_receipt_trust_base)" || return 1
  _owner="$(_mdm_expected_trust_owner)" || return 1
  _managed="$_base/ClaudeCodeStarterKit"
  _mdm_runtime_system_ancestors_are_trusted || return 1
  if [[ "$_MDM_DETECT_TEST_MODE" == 1 ]]; then
    _managed_gid="$(_mdm_stat_gid "$_managed")" || return 1
    _mdm_verify_trusted_dir_chain "$_managed" "$_base" "$_owner" || return 1
  else
    _managed_gid=0
  fi
  _mdm_verify_trusted_dir_chain_exact_mode \
    "$_root" "$_managed" "$_owner" 0755 "$_managed_gid" || return 1
  _mdm_node_runtime_metadata_is_valid "$_root" || return 1
  _mdm_node_runtime_provenance_is_valid "$_root" || return 1
  _arch="$(_mdm_node_runtime_arch)" || return 1
  _expected_content="$(_mdm_node_runtime_expected_content_sha256 "$_arch")" \
    || return 1
  _content="$(_mdm_node_runtime_content_sha256 "$_root")" || return 1
  [[ "$_content" == "$_expected_content" ]] || return 1
  _mdm_node_runtime_bundled_npm_is_valid "$_root" || return 1
  _mdm_trusted_component "$_root/bin" "$_owner" dir || return 1
  _node="$_root/bin/node"
  _mdm_trusted_component "$_node" "$_owner" file || return 1
  [[ "$(_mdm_canonical_file "$_node")" == "$_node" ]] || return 1
  _mode="$(_mdm_stat_mode "$_node")" || return 1
  _mdm_mode_owner_executable "$_mode"
}

_mdm_node_command_path() { # <home> <target-uid> [runtime-root]
  local _home="$1" _uid="$2" _root="${3:-}" _link _target _value _metadata
  local _dir
  [[ -n "$_root" ]] || _root="$(_mdm_node_runtime_root)" || return 1
  _mdm_node_runtime_tree_is_trusted "$_root" || return 1
  _target="$_root/bin/node"
  _link="$_home/.local/bin/node"
  for _dir in "$_home" "$_home/.local" "$_home/.local/bin"; do
    _mdm_target_dir_is_accessible "$_dir" "$_uid" || return 1
  done
  [[ -L "$_link" && "$(_mdm_stat_uid "$_link")" == "$_uid" ]] \
    || return 1
  ! _mdm_has_acl "$_link" || return 1
  _metadata="$(_mdm_stat_metadata "$_link")" || return 1
  [[ "${_metadata##*:}" == 1 ]] || return 1
  _value="$(_mdm_readlink_value "$_link")" || return 1
  [[ "$_value" == "$_target" ]] || return 1
  [[ "$(_mdm_canonical_file "$_target")" == "$_target" ]] || return 1
  _mdm_component_path_accessible "$_link" "$_uid" "$_home" || return 1
  _mdm_component_path_accessible "$_target" "$_uid" "$_home" || return 1
  printf '%s' "$_target"
}

_mdm_node_runtime_version_is_valid() { # <canonical-node> <uid> <home>
  local _node="$1" _uid="$2" _home="$3" _raw _value _rc=0
  if [[ "$_MDM_DETECT_TEST_MODE" == 1 \
    && "$(/usr/bin/id -u 2>/dev/null || true)" == "$_uid" ]]; then
    _raw="$({
      ( builtin cd -- "$_home" \
        && /usr/bin/env -i HOME="$_home" \
          PATH=/usr/bin:/bin:/usr/sbin:/sbin \
          "$_node" --version 2>/dev/null ) || _rc=$?
      printf '\036'
      exit "$_rc"
    })" || return 1
  else
    [[ "$(/usr/bin/id -u 2>/dev/null || true)" == 0 \
      && -x /usr/bin/sudo ]] || return 1
    _raw="$({
      /usr/bin/sudo -n -u "#$_uid" /usr/bin/env -i HOME="$_home" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        /bin/bash --noprofile --norc -c \
          'builtin cd -- "$1" && exec "$2" --version' \
          mdm-node-version "$_home" "$_node" 2>/dev/null || _rc=$?
      printf '\036'
      exit "$_rc"
    })" || return 1
  fi
  [[ "$_raw" == *$'\036' ]] || return 1
  _value="${_raw%$'\036'}"
  [[ "$_value" == *$'\n' ]] || return 1
  _value="${_value%$'\n'}"
  [[ "$_value" == v24.18.0 ]]
}

_mdm_cli_target_path() { # <home> <target-uid>
  local _home="$1" _uid="$2" _link _target _versions _dir
  _link="$_home/.local/bin/claude"
  _versions="$_home/.local/share/claude/versions"
  _target="$(_mdm_cli_activation_target "$_home" "$_uid")" || return 1
  for _dir in "$_home" "$_home/.local" "$_home/.local/bin" \
    "$_home/.local/share" "$_home/.local/share/claude" "$_versions"; do
    _mdm_target_dir_is_accessible "$_dir" "$_uid" || return 1
  done
  ! _mdm_has_acl "$_link" || return 1
  _mdm_component_path_accessible "$_link" "$_uid" "$_home" || return 1
  _mdm_component_path_accessible "$_target" "$_uid" "$_home" || return 1
  printf '%s' "$_target"
}

_mdm_component_entry_path_is_valid() {
  # <component> <path> <kind> <home> <cli-target> <safety-target>
  # <safety-root> <biome-target> <biome-root> <node-root> <wce-root>
  local _component="$1" _path="$2" _kind="$3" _home="$4"
  local _cli="$5" _safety="$6" _safety_root="$7" _biome="$8"
  local _biome_root="$9" _node_root="${10}" _wce_root="${11}" _canonical
  case "$_kind" in
    file) _canonical="$(_mdm_canonical_file "$_path")" || return 1 ;;
    tree) _canonical="$(_mdm_canonical_dir "$_path")" || return 1 ;;
    *) return 1 ;;
  esac
  [[ "$_canonical" == "$_path" ]] || return 1
  case "$_component:$_kind" in
    kit:tree) [[ "$_path" == "$_home/.claude-starter-kit" ]] ;;
    claude_cli:file) [[ -n "$_cli" && "$_path" == "$_cli" ]] ;;
    safety_net:tree)
      [[ -n "$_safety" && -n "$_safety_root" \
        && "$_path" == "$_safety_root" \
        && "$_path" == "$_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6" ]] ;;
    biome:tree)
      [[ -n "$_biome" && -n "$_biome_root" \
        && "$_path" == "$_biome_root" \
        && "$_path" == "$_home/.local/lib/claude-code-starter-kit/biome/2.5.4" ]] ;;
    node_runtime:tree)
      [[ -n "$_node_root" && "$_path" == "$_node_root" ]] ;;
    web_content_runtime:tree)
      [[ -n "$_wce_root" && "$_path" == "$_wce_root" ]] ;;
    ghostty:tree) [[ "$_path" == /Applications/Ghostty.app ]] ;;
    fonts:file)
      [[ "${_path%/*}" == "$_home/Library/Fonts" ]] || return 1
      _mdm_font_expected_record "${_path##*/}" >/dev/null ;;
    *) return 1 ;;
  esac
}

_mdm_component_manifest_shape_is_valid() { # <manifest-snapshot>
  _mdm_issuer_json_is_canonical "$1" component
}

_mdm_component_manifest_is_valid() {
  # <receipt> <user> <uid> <generated-uid> <home> <policy> <workspace>
  local _receipt="$1" _user="$2" _uid="$3" _generated="$4" _home="$5"
  local _policy="$6" _workspace="$7" _override _base _owner _path _hash
  local _canonical _snapshot _actual_hash _count _index=0 _component _entry_path
  local _kind _entry_hash _previous_component="" _previous_path="" _digest
  local _cli="" _safety="" _safety_root="" _biome="" _biome_root=""
  local _node="" _node_root="" _wce_root="" _wce_activation=""
  local _required_count _required_index _active_root
  local _required _seen _component_count _fonts=0 _active _owner_csv
  local _group_csv LC_ALL=C
  _mdm_required_components_are_valid "$_receipt" || return 1
  if _override="$(_mdm_test_value MDM_DETECT_COMPONENT_MANIFEST_OVERRIDE)"; then
    [[ "$_override" == 1 ]]
    return
  fi
  _base="$(_mdm_receipt_trust_base)" || return 1
  _owner="$(_mdm_expected_trust_owner)" || return 1
  _path="$(_mdm_json_get "$_receipt" component_manifest_path)"
  _hash="$(_mdm_json_get "$_receipt" component_manifest_sha256)"
  [[ "$_path" == "$_base/ClaudeCodeStarterKit/components-$_generated.json" \
    && "$_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  _mdm_trusted_component "$_path" "$_owner" file || return 1
  _canonical="$(_mdm_canonical_file "$_path")" || return 1
  [[ "$_canonical" == "$_path" ]] || return 1
  _snapshot="$_workspace/components.json"
  _mdm_snapshot_bound_file "$_path" "$_snapshot" history || return 1
  [[ "$_MDM_DETECT_SNAPSHOT_MODE" == 0600 ]] || return 1
  _actual_hash="$(_mdm_sha256 "$_snapshot")" || return 1
  [[ "$_actual_hash" == "$_hash" ]] || return 1
  _mdm_component_manifest_shape_is_valid "$_snapshot" || return 1

  _mdm_json_type_is "$_snapshot" schema_version integer || return 1
  _mdm_json_type_is "$_snapshot" target_user string || return 1
  _mdm_json_type_is "$_snapshot" target_uid integer || return 1
  _mdm_json_type_is "$_snapshot" target_generated_uid string || return 1
  _mdm_json_type_is "$_snapshot" policy_sha256 string || return 1
  _mdm_json_type_is "$_snapshot" entries array || return 1
  [[ "$(_mdm_json_get "$_snapshot" schema_version)" == 1 \
    && "$(_mdm_json_get "$_snapshot" target_user)" == "$_user" \
    && "$(_mdm_json_get "$_snapshot" target_uid)" == "$_uid" \
    && "$(_mdm_json_get "$_snapshot" target_generated_uid)" == "$_generated" \
    && "$(_mdm_json_get "$_snapshot" policy_sha256)" == "$_policy" ]] \
    || return 1

  _count="$(_mdm_json_array_count "$_snapshot" entries)"
  [[ "$_count" =~ ^[0-9]+$ && "$_count" -ge 1 && "$_count" -le 1000 ]] \
    || return 1
  _cli="$(_mdm_cli_target_path "$_home" "$_uid" 2>/dev/null || true)"
  _safety="$(_mdm_component_command_path \
    "$_home" cc-safety-net "$_uid" 2>/dev/null || true)"
  if [[ -n "$_safety" ]]; then
    _safety_root="$(_mdm_safety_package_root \
      "$_home" "$_safety" 2>/dev/null || true)"
  fi
  _biome="$(_mdm_component_command_path \
    "$_home" biome "$_uid" 2>/dev/null || true)"
  if [[ -n "$_biome" ]]; then
    _biome_root="$(_mdm_biome_package_root \
      "$_home" "$_biome" 2>/dev/null || true)"
  fi
  _node_root="$(_mdm_node_runtime_root 2>/dev/null || true)"
  if [[ -n "$_node_root" ]]; then
    _node="$(_mdm_node_command_path \
      "$_home" "$_uid" "$_node_root" 2>/dev/null || true)"
  fi
  _wce_root="$(_mdm_wce_runtime_root 2>/dev/null || true)"
  if [[ -n "$_wce_root" ]]; then
    _wce_activation="$(_mdm_wce_activation_record \
      "$_home" "$_uid" "$_wce_root" 2>/dev/null || true)"
  fi
  while (( _index < _count )); do
    for _required in component path kind sha256; do
      _mdm_json_type_is "$_snapshot" "entries.$_index.$_required" string \
        || return 1
    done
    _component="$(_mdm_json_get "$_snapshot" "entries.$_index.component")"
    _entry_path="$(_mdm_json_get "$_snapshot" "entries.$_index.path")"
    _kind="$(_mdm_json_get "$_snapshot" "entries.$_index.kind")"
    _entry_hash="$(_mdm_json_get "$_snapshot" "entries.$_index.sha256")"
    case "$_component" in
      biome|claude_cli|fonts|ghostty|kit|node_runtime|safety_net|web_content_runtime) : ;;
      *) return 1 ;;
    esac
    _mdm_required_component_present "$_receipt" "$_component" || return 1
    [[ -n "$_entry_path" && "$_entry_path" == /* \
      && ! "$_entry_path" =~ [[:cntrl:]] \
      && "$_entry_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    if [[ -n "$_previous_component" ]]; then
      [[ "$_previous_component" < "$_component" \
        || ( "$_previous_component" == "$_component" \
          && "$_previous_path" < "$_entry_path" ) ]] || return 1
    fi
    _mdm_component_entry_path_is_valid "$_component" "$_entry_path" \
      "$_kind" "$_home" "$_cli" "$_safety" "$_safety_root" \
      "$_biome" "$_biome_root" "$_node_root" "$_wce_root" || return 1
    _mdm_component_owner_is_valid "$_component" "$_entry_path" \
      "$_home" "$_uid" || return 1
    case "$_kind" in
      tree)
        _mdm_component_tree_accessible "$_entry_path" "$_uid" "$_home" \
          || return 1 ;;
      file)
        if [[ "$_component" == claude_cli ]]; then
          _mdm_component_path_accessible "$_entry_path" "$_uid" "$_home" \
            || return 1
        else
          _mdm_component_file_readable "$_entry_path" "$_uid" "$_home" \
            || return 1
        fi ;;
    esac
    case "$_component" in
      ghostty) _owner_csv="0,$_uid"; _group_csv="" ;;
      node_runtime|web_content_runtime)
        _owner_csv="$(_mdm_stat_uid "$_entry_path")" || return 1
        _group_csv="$(_mdm_stat_gid "$_entry_path")" || return 1 ;;
      *) _owner_csv="$_uid"; _group_csv="" ;;
    esac
    _digest="$(_mdm_artifact_digest \
      "$_kind" "$_entry_path" "$_owner_csv" "$_group_csv")" || return 1
    [[ "$_digest" == "$_entry_hash" ]] || return 1
    case "$_component" in
      ghostty)
        _mdm_ghostty_signature_trusted "$_entry_path" || return 1
        _digest="$(_mdm_artifact_digest \
          "$_kind" "$_entry_path" "$_owner_csv" "$_group_csv")" \
          || return 1
        [[ "$_digest" == "$_entry_hash" ]] || return 1 ;;
      fonts)
        _mdm_font_file_is_trusted "$_entry_path" || return 1
        _digest="$(_mdm_artifact_digest \
          "$_kind" "$_entry_path" "$_owner_csv" "$_group_csv")" \
          || return 1
        [[ "$_digest" == "$_entry_hash" ]] || return 1
        _fonts=$((_fonts + 1)) ;;
    esac
    case "$_component" in
      claude_cli)
        _mdm_cli_present "$_home" "$_uid" "$_workspace" || return 1
        _digest="$(_mdm_artifact_digest \
          "$_kind" "$_entry_path" "$_owner_csv" "$_group_csv")" \
          || return 1
        [[ "$_digest" == "$_entry_hash" ]] || return 1
        _active="$(_mdm_cli_target_path "$_home" "$_uid")" || return 1
        [[ "$_active" == "$_cli" ]] || return 1 ;;
      safety_net)
        [[ -n "$_node" ]] || return 1
        _mdm_required_component_present "$_receipt" node_runtime || return 1
        _active="$(_mdm_component_command_path \
          "$_home" cc-safety-net "$_uid")" || return 1
        _active_root="$(_mdm_safety_package_root "$_home" "$_active")" \
          || return 1
        [[ "$_active" == "$_safety" \
          && "$_active_root" == "$_safety_root" ]] || return 1
        _mdm_safety_tree_is_trusted \
          "$_home" "$_entry_path" "$_active" "$_node" "$_uid" \
          || return 1
        _digest="$(_mdm_artifact_digest \
          "$_kind" "$_entry_path" "$_owner_csv" "$_group_csv")" \
          || return 1
        [[ "$_digest" == "$_entry_hash" ]] || return 1
        _active="$(_mdm_component_command_path \
          "$_home" cc-safety-net "$_uid")" || return 1
        [[ "$_active" == "$_safety" ]] || return 1
        _digest="$(_mdm_artifact_digest \
          "$_kind" "$_entry_path" "$_owner_csv" "$_group_csv")" \
          || return 1
        [[ "$_digest" == "$_entry_hash" ]] || return 1 ;;
      biome)
        _active="$(_mdm_component_command_path \
          "$_home" biome "$_uid")" || return 1
        _active_root="$(_mdm_biome_package_root "$_home" "$_active")" \
          || return 1
        [[ "$_active" == "$_biome" \
          && "$_active_root" == "$_biome_root" ]] || return 1
        _mdm_biome_tree_is_trusted \
          "$_entry_path" "$_active" "$_uid" "$_home" || return 1
        _digest="$(_mdm_artifact_digest \
          "$_kind" "$_entry_path" "$_owner_csv" "$_group_csv")" \
          || return 1
        [[ "$_digest" == "$_entry_hash" ]] || return 1
        _active="$(_mdm_component_command_path \
          "$_home" biome "$_uid")" || return 1
        [[ "$_active" == "$_biome" ]] || return 1
        _digest="$(_mdm_artifact_digest \
          "$_kind" "$_entry_path" "$_owner_csv" "$_group_csv")" \
          || return 1
        [[ "$_digest" == "$_entry_hash" ]] || return 1 ;;
      node_runtime)
        [[ -n "$_node" && "$_node" == "$_entry_path/bin/node" ]] \
          || return 1
        _mdm_node_runtime_tree_is_trusted "$_entry_path" || return 1
        _mdm_node_signature_trusted "$_node" || return 1
        _mdm_node_runtime_platform_is_valid "$_node" "$_uid" "$_home" \
          || return 1
        _mdm_node_runtime_version_is_valid "$_node" "$_uid" "$_home" \
          || return 1
        _mdm_node_runtime_npm_version_is_valid \
          "$_entry_path" "$_uid" "$_home" || return 1
        _digest="$(_mdm_artifact_digest \
          "$_kind" "$_entry_path" "$_owner_csv" "$_group_csv")" \
          || return 1
        [[ "$_digest" == "$_entry_hash" ]] || return 1
        _active="$(_mdm_node_command_path \
          "$_home" "$_uid" "$_node_root")" || return 1
        [[ "$_active" == "$_node" ]] || return 1
        _mdm_node_signature_trusted "$_active" || return 1
        _mdm_node_runtime_platform_is_valid "$_active" "$_uid" "$_home" \
          || return 1
        _mdm_node_runtime_version_is_valid "$_active" "$_uid" "$_home" \
          || return 1
        _mdm_node_runtime_npm_version_is_valid \
          "$_entry_path" "$_uid" "$_home" || return 1
        _digest="$(_mdm_artifact_digest \
          "$_kind" "$_entry_path" "$_owner_csv" "$_group_csv")" || return 1
        [[ "$_digest" == "$_entry_hash" ]] || return 1
        _active="$(_mdm_node_command_path \
          "$_home" "$_uid" "$_node_root")" || return 1
        [[ "$_active" == "$_node" ]] || return 1 ;;
      web_content_runtime)
        [[ -n "$_node" ]] || return 1
        [[ -n "$_wce_activation" ]] || return 1
        _mdm_required_component_present "$_receipt" node_runtime || return 1
        _mdm_wce_runtime_tree_is_trusted "$_entry_path" || return 1
        _digest="$(_mdm_artifact_digest \
          "$_kind" "$_entry_path" "$_owner_csv" "$_group_csv")" \
          || return 1
        [[ "$_digest" == "$_entry_hash" ]] || return 1
        [[ "$(_mdm_wce_activation_record \
          "$_home" "$_uid" "$_wce_root")" == "$_wce_activation" ]] \
          || return 1
        _digest="$(_mdm_artifact_digest \
          "$_kind" "$_entry_path" "$_owner_csv" "$_group_csv")" \
          || return 1
        [[ "$_digest" == "$_entry_hash" ]] || return 1
        [[ "$(_mdm_wce_activation_record \
          "$_home" "$_uid" "$_wce_root")" == "$_wce_activation" ]] \
          || return 1 ;;
    esac
    _previous_component="$_component"; _previous_path="$_entry_path"
    _index=$((_index + 1))
  done

  _required_count="$(_mdm_json_array_count "$_receipt" required_components)"
  _required_index=0
  while (( _required_index < _required_count )); do
    _required="$(_mdm_json_array_get \
      "$_receipt" required_components "$_required_index")"
    _seen=0; _index=0
    while (( _index < _count )); do
      _component="$(_mdm_json_get "$_snapshot" "entries.$_index.component")"
      [[ "$_component" != "$_required" ]] || _seen=$((_seen + 1))
      _index=$((_index + 1))
    done
    [[ "$_seen" -ge 1 ]] || return 1
    [[ "$_required" == fonts || "$_seen" -eq 1 ]] || return 1
    _required_index=$((_required_index + 1))
  done
  if _mdm_required_component_present "$_receipt" fonts; then
    [[ "$_fonts" -eq 20 ]] || return 1
  fi
  _component_count=0
  for _required in biome claude_cli fonts ghostty kit node_runtime safety_net \
    web_content_runtime; do
    if _mdm_required_component_present "$_receipt" "$_required"; then
      _component_count=$((_component_count + 1))
    fi
  done
  [[ "$_component_count" == "$_required_count" ]]
}

_mdm_manifest_is_valid() {
  # <manifest-snapshot> <sha256> <resolved-sha> <home> <profile> <language>
  # <deployment-sha256> <policy-sha256> <private-workspace> <expected-uid>
  local _manifest="$1" _expected_hash="$2" _resolved_sha="$3" _home="$4"
  local _receipt_profile="$5" _receipt_language="$6" _expected_deployment="$7"
  local _expected_policy="$8" _workspace="$9" _expected_uid="${10:-}"
  local _claude_dir="$_home/.claude" _snapshot="$_home/.claude/.starter-kit-snapshot"
  local _actual_hash _kit_commit _manifest_profile _manifest_language
  local _count _index=0 _file _relative _snapshot_file _canonical
  local _live_copy _snapshot_copy _live_hash _snapshot_hash _live_size _snapshot_size
  local _live_mode _snapshot_mode _live_managed _snapshot_managed
  local _aggregate_size=0 _aggregate_limit=536870912 _digest_input _digest
  local _absent_count _absent_index=0 _absent_relative

  _actual_hash="$(_mdm_sha256 "$_manifest")" || return 1
  [[ "$_actual_hash" == "$_expected_hash" ]] || return 1
  _mdm_issuer_json_is_canonical "$_manifest" deployment || return 1
  _mdm_json_type_is "$_manifest" version string || return 1
  _mdm_json_type_is "$_manifest" mdm_managed bool || return 1
  _mdm_json_type_is "$_manifest" kit_commit string || return 1
  _mdm_json_type_is "$_manifest" profile string || return 1
  _mdm_json_type_is "$_manifest" language string || return 1
  _mdm_json_type_is "$_manifest" claude_dir string || return 1
  _mdm_json_type_is "$_manifest" snapshot_dir string || return 1
  _mdm_json_type_is "$_manifest" policy_sha256 string || return 1
  _mdm_json_type_is "$_manifest" mdm_absent_files array || return 1
  _mdm_json_type_is "$_manifest" files array || return 1
  [[ "$(_mdm_json_get "$_manifest" version)" == "2" ]] || return 1
  [[ "$(_mdm_json_get "$_manifest" mdm_managed)" == "true" ]] || return 1
  [[ "$(_mdm_json_get "$_manifest" claude_dir)" == "$_claude_dir" ]] || return 1
  [[ "$(_mdm_json_get "$_manifest" snapshot_dir)" == "$_snapshot" ]] || return 1
  [[ "$(_mdm_json_get "$_manifest" policy_sha256)" == "$_expected_policy" ]] \
    || return 1
  _kit_commit="$(_mdm_json_get "$_manifest" kit_commit)"
  [[ "$_kit_commit" =~ ^[0-9a-f]{7,40}$ ]] || return 1
  [[ "${_resolved_sha:0:${#_kit_commit}}" == "$_kit_commit" ]] || return 1
  _manifest_profile="$(_mdm_json_get "$_manifest" profile)"
  _manifest_language="$(_mdm_json_get "$_manifest" language)"
  [[ "$_manifest_profile" == "$_receipt_profile" ]] || return 1
  [[ "$_manifest_language" == "$_receipt_language" ]] || return 1

  [[ "$(_mdm_canonical_dir "$_claude_dir")" == "$_claude_dir" ]] || return 1
  [[ "$(_mdm_canonical_dir "$_snapshot")" == "$_snapshot" ]] || return 1
  _count="$(_mdm_json_array_count "$_manifest" files)"
  [[ "$_count" =~ ^[0-9]+$ && "$_count" -gt 0 && "$_count" -le 1000 ]] || return 1
  _digest_input="$_workspace/deployment-input"
  (umask 077; : > "$_digest_input") || return 1
  /bin/chmod 600 "$_digest_input" || return 1

  while (( _index < _count )); do
    _mdm_json_type_is "$_manifest" "files.$_index" string || return 1
    _file="$(_mdm_json_array_get "$_manifest" files "$_index")"
    [[ -n "$_file" && ! "$_file" =~ [[:cntrl:]] ]] || return 1
    case "$_file" in "$_claude_dir"/*) : ;; *) return 1 ;; esac
    _relative="${_file#"$_claude_dir"/}"
    [[ -n "$_relative" && ! "$_relative" =~ [[:cntrl:]] ]] || return 1
    case "/$_relative/" in */../*|*/./*|*//*) return 1 ;; esac

    _canonical="$(_mdm_canonical_file "$_file")" || return 1
    [[ "$_canonical" == "$_file" ]] || return 1
    _snapshot_file="$_snapshot/$_relative"
    _canonical="$(_mdm_canonical_file "$_snapshot_file")" || return 1
    [[ "$_canonical" == "$_snapshot_file" ]] || return 1

    _live_copy="$_workspace/live.$_index"
    _snapshot_copy="$_workspace/snapshot.$_index"
    _mdm_snapshot_bound_file "$_file" "$_live_copy" managed "$_expected_uid" || return 1
    _live_size="$_MDM_DETECT_SNAPSHOT_SIZE"
    _live_mode="$_MDM_DETECT_SNAPSHOT_MODE"
    [[ "$_live_size" =~ ^[0-9]+$ ]] || return 1
    [[ "$_live_mode" =~ ^[0-7]{4}$ ]] || return 1
    _aggregate_size=$((_aggregate_size + 10#$_live_size))
    if (( _aggregate_size > _aggregate_limit )); then
      /bin/rm -f "$_live_copy"
      return 1
    fi
    _mdm_snapshot_bound_file "$_snapshot_file" "$_snapshot_copy" managed \
      "$_expected_uid" || return 1
    _snapshot_size="$_MDM_DETECT_SNAPSHOT_SIZE"
    _snapshot_mode="$_MDM_DETECT_SNAPSHOT_MODE"
    [[ "$_snapshot_size" =~ ^[0-9]+$ ]] || return 1
    [[ "$_snapshot_mode" =~ ^[0-7]{4}$ ]] || return 1
    _aggregate_size=$((_aggregate_size + 10#$_snapshot_size))
    if (( _aggregate_size > _aggregate_limit )); then
      /bin/rm -f "$_live_copy" "$_snapshot_copy"
      return 1
    fi
    if [[ "$_relative" == CLAUDE.md ]]; then
      _live_managed="$_workspace/live-managed.$_index"
      _snapshot_managed="$_workspace/snapshot-managed.$_index"
      _mdm_extract_managed_section "$_live_copy" "$_live_managed" 0 || return 1
      _mdm_extract_managed_section "$_snapshot_copy" "$_snapshot_managed" 1 || return 1
      /usr/bin/cmp -s "$_snapshot_copy" "$_snapshot_managed" || return 1
      _live_hash="$(_mdm_sha256 "$_live_managed")" || return 1
      _snapshot_hash="$(_mdm_sha256 "$_snapshot_copy")" || return 1
    else
      _live_hash="$(_mdm_sha256 "$_live_copy")" || return 1
      _snapshot_hash="$(_mdm_sha256 "$_snapshot_copy")" || return 1
    fi
    [[ "$_live_hash" =~ ^[0-9a-f]{64}$ && "$_snapshot_hash" =~ ^[0-9a-f]{64}$ ]] \
      || return 1
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$_relative" "$_live_hash" "$_snapshot_hash" "$_live_mode" "$_snapshot_mode" \
      >> "$_digest_input" || return 1
    /bin/rm -f "$_live_copy" "$_snapshot_copy" \
      "${_live_managed:-}" "${_snapshot_managed:-}"
    _live_managed=""; _snapshot_managed=""
    _index=$((_index + 1))
  done

  _absent_count="$(_mdm_json_array_count "$_manifest" mdm_absent_files)"
  [[ "$_absent_count" =~ ^[0-9]+$ && "$_absent_count" -le 1000 \
    && $((_count + _absent_count)) -le 2000 ]] || return 1
  _MDM_DETECT_ABSENCE_PYTHON="$(_mdm_detect_system_python)" || return 1
  while (( _absent_index < _absent_count )); do
    _mdm_json_type_is "$_manifest" \
      "mdm_absent_files.$_absent_index" string || return 1
    _absent_relative="$(_mdm_json_array_get \
      "$_manifest" mdm_absent_files "$_absent_index")"
    [[ -n "$_absent_relative" ]] || return 1
    _mdm_path_is_absent_with_real_parents "$_claude_dir" "$_absent_relative" \
      && _mdm_path_is_absent_with_real_parents "$_snapshot" "$_absent_relative" \
      || return 1
    printf 'absent\t%s\n' "$_absent_relative" >> "$_digest_input" || return 1
    _absent_index=$((_absent_index + 1))
  done
  _MDM_DETECT_ABSENCE_PYTHON=""

  _digest="$(_mdm_sha256 "$_digest_input")" || return 1
  [[ "$_digest" =~ ^[0-9a-f]{64}$ && "$_digest" == "$_expected_deployment" ]]
}

_MDM_DETECT_VERIFIED_KIT_VERSION=""
_mdm_detect_from_snapshots() {
  # <receipt-snapshot> <user> <expected-commit> <expected-policy> <workspace>
  local _receipt="$1" _user="$2" _expected_commit="$3"
  local _expected_policy="$4" _workspace="$5"
  local _schema _result _target _install _install_canonical _sha _git_ref
  local _git_dir _head_path _head_snapshot _head_size _head
  local _home _home_canonical _manifest _manifest_from_receipt _manifest_hash
  local _manifest_snapshot _manifest_canonical _profile _language _deployment_hash
  local _receipt_policy
  local _expected_uid _expected_generated_uid _binding_remainder
  local _initial_binding_tuple _final_binding_tuple
  local _persistent_identity _git_identity
  local _receipt_uid _receipt_generated

  _mdm_issuer_json_is_canonical "$_receipt" receipt || return 1
  _mdm_json_type_is "$_receipt" schema_version integer || return 1
  _mdm_json_type_is "$_receipt" kit_version string || return 1
  _mdm_json_type_is "$_receipt" git_ref string || return 1
  _mdm_json_type_is "$_receipt" resolved_sha string || return 1
  _mdm_json_type_is "$_receipt" install_dir string || return 1
  _mdm_json_type_is "$_receipt" manifest_path string || return 1
  _mdm_json_type_is "$_receipt" manifest_sha256 string || return 1
  _mdm_json_type_is "$_receipt" deployment_sha256 string || return 1
  _mdm_json_type_is "$_receipt" policy_sha256 string || return 1
  _mdm_json_type_is "$_receipt" required_components array || return 1
  _mdm_json_type_is "$_receipt" profile string || return 1
  _mdm_json_type_is "$_receipt" language string || return 1
  _mdm_json_type_is "$_receipt" target_user string || return 1
  _mdm_json_type_is "$_receipt" target_uid integer || return 1
  _mdm_json_type_is "$_receipt" target_generated_uid string || return 1
  _mdm_json_type_is "$_receipt" result string || return 1
  _mdm_json_type_is "$_receipt" exit_code integer || return 1
  _mdm_json_type_is "$_receipt" partial array || return 1
  _mdm_json_type_is "$_receipt" timestamp string || return 1
  _mdm_json_type_is "$_receipt" log_path string || return 1
  _mdm_json_type_is "$_receipt" component_manifest_path string || return 1
  _mdm_json_type_is "$_receipt" component_manifest_sha256 string || return 1

  _schema="$(_mdm_json_get "$_receipt" schema_version)"
  [[ "$_schema" == "3" ]] || return 1
  _result="$(_mdm_json_get "$_receipt" result)"
  [[ "$_result" == "success" ]] || return 1
  [[ "$(_mdm_json_get "$_receipt" exit_code)" == "0" ]] || return 1
  [[ "$(_mdm_json_array_count "$_receipt" partial)" == 0 ]] || return 1
  _target="$(_mdm_json_get "$_receipt" target_user)"
  [[ -n "$_user" && "$_target" == "$_user" ]] || return 1
  _mdm_required_components_are_valid "$_receipt" || return 1

  _sha="$(_mdm_json_get "$_receipt" resolved_sha)"
  [[ "$_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  _git_ref="$(_mdm_json_get "$_receipt" git_ref)"
  [[ "$_git_ref" == "$_sha" ]] || return 1
  [[ -z "$_expected_commit" || "$_sha" == "$_expected_commit" ]] || return 1
  _profile="$(_mdm_json_get "$_receipt" profile)"
  _language="$(_mdm_json_get "$_receipt" language)"
  case "$_profile" in minimal|standard|full) : ;; *) return 1 ;; esac
  case "$_language" in en|ja) : ;; *) return 1 ;; esac
  _deployment_hash="$(_mdm_json_get "$_receipt" deployment_sha256)"
  [[ "$_deployment_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  _receipt_policy="$(_mdm_json_get "$_receipt" policy_sha256)"
  [[ "$_expected_policy" =~ ^[0-9a-f]{64}$ \
    && "$_receipt_policy" == "$_expected_policy" ]] || return 1

  _initial_binding_tuple="$(_mdm_detect_target_binding_tuple "$_user")" \
    || return 1
  _expected_uid="${_initial_binding_tuple%%$'\t'*}"
  _binding_remainder="${_initial_binding_tuple#*$'\t'}"
  _expected_generated_uid="${_binding_remainder%%$'\t'*}"
  _home="${_binding_remainder#*$'\t'}"
  _home_canonical="$(_mdm_canonical_dir "$_home")" || return 1
  [[ "$_home_canonical" == "$_home" ]] || return 1
  _receipt_uid="$(_mdm_json_get "$_receipt" target_uid)"
  _receipt_generated="$(_mdm_json_get "$_receipt" target_generated_uid)"
  [[ "$_receipt_uid" == "$_expected_uid" \
    && "$_receipt_generated" == "$_expected_generated_uid" ]] || return 1
  _mdm_home_boundary_is_safe "$_home" "$_expected_uid" || return 1
  _mdm_managed_history_is_valid "$_user" "$_expected_uid" \
    "$_expected_generated_uid" "$_home" "$_workspace" || return 1

  _install="$(_mdm_json_get "$_receipt" install_dir)"
  [[ "$_install" == "$_home/.claude-starter-kit" ]] || return 1
  _install_canonical="$(_mdm_canonical_dir "$_install")" || return 1
  [[ "$_install_canonical" == "$_install" ]] || return 1
  _mdm_persistent_checkout_trusted "$_install" "$_expected_uid" \
    "$_workspace" || return 1
  _persistent_identity="$_MDM_DETECT_PERSISTENT_IDENTITY"
  _git_identity="$_MDM_DETECT_GIT_IDENTITY"
  _git_dir="$_install/.git"
  [[ "$(_mdm_canonical_dir "$_git_dir")" == "$_git_dir" ]] || return 1
  _head_path="$_git_dir/HEAD"
  [[ "$(_mdm_canonical_file "$_head_path")" == "$_head_path" ]] || return 1
  _head_snapshot="$_workspace/git-head"
  _mdm_snapshot_bound_file "$_head_path" "$_head_snapshot" head \
    "$_expected_uid" || return 1
  _head_size="$(/usr/bin/wc -c < "$_head_snapshot" \
    | /usr/bin/tr -d '[:space:]')" || return 1
  [[ "$_head_size" == "41" ]] || return 1
  IFS= read -r _head < "$_head_snapshot" || return 1
  [[ "$_head" =~ ^[0-9a-f]{40}$ && "$_head" == "$_sha" ]] || return 1
  _mdm_target_dir_matches_identity \
    "$_install" "$_expected_uid" "$_persistent_identity" \
    && _mdm_target_dir_matches_identity \
      "$_git_dir" "$_expected_uid" "$_git_identity" || return 1

  _manifest="$_home/.claude/.starter-kit-manifest.json"
  _manifest_from_receipt="$(_mdm_json_get "$_receipt" manifest_path)"
  [[ "$_manifest_from_receipt" == "$_manifest" ]] || return 1
  _manifest_hash="$(_mdm_json_get "$_receipt" manifest_sha256)"
  [[ "$_manifest_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  _manifest_canonical="$(_mdm_canonical_file "$_manifest")" || return 1
  [[ "$_manifest_canonical" == "$_manifest" ]] || return 1
  _manifest_snapshot="$_workspace/manifest.json"
  _mdm_snapshot_bound_file "$_manifest" "$_manifest_snapshot" manifest \
    "$_expected_uid" || return 1
  _mdm_manifest_is_valid "$_manifest_snapshot" "$_manifest_hash" "$_sha" "$_home" \
    "$_profile" "$_language" "$_deployment_hash" "$_expected_policy" \
    "$_workspace" "$_expected_uid" || return 1

  if _mdm_required_component_present "$_receipt" claude_cli; then
    _mdm_cli_present "$_home" "$_expected_uid" "$_workspace" || return 1
  fi
  _mdm_component_manifest_is_valid "$_receipt" "$_user" "$_expected_uid" \
    "$_expected_generated_uid" "$_home" "$_expected_policy" "$_workspace" \
    || return 1
  _final_binding_tuple="$(_mdm_detect_target_binding_tuple "$_user")" \
    || return 1
  [[ "$_final_binding_tuple" == "$_initial_binding_tuple" ]] || return 1
  _mdm_home_boundary_is_safe "$_home" "$_expected_uid" || return 1
  _MDM_DETECT_VERIFIED_KIT_VERSION="$(_mdm_json_get "$_receipt" kit_version)"
  [[ -n "$_MDM_DETECT_VERIFIED_KIT_VERSION" ]]
}

mdm_detect() { # <receipt> <target-user> [expected-commit] [expected-policy]
  local _receipt="$1" _user="$2" _expected_commit="${3:-}"
  local _expected_policy="${4:-}" _override
  local _workspace="" _receipt_snapshot _rc=1
  _MDM_DETECT_VERIFIED_KIT_VERSION=""
  if [[ -z "$_expected_commit" ]] \
    && _override="$(_mdm_test_value MDM_DETECT_EXPECTED_COMMIT_OVERRIDE)"; then
    _expected_commit="$_override"
  fi
  if [[ -z "$_expected_policy" ]] \
    && _override="$(_mdm_test_value MDM_DETECT_EXPECTED_POLICY_SHA_OVERRIDE)"; then
    _expected_policy="$_override"
  fi
  [[ "$_expected_commit" =~ ^[0-9a-f]{40}$ \
    && "$_expected_policy" =~ ^[0-9a-f]{64}$ ]] || return 1
  _mdm_receipt_is_trusted "$_receipt" "$_user" || return 1
  _workspace="$(_mdm_private_tmpdir)" || return 1
  _MDM_DETECT_ACTIVE_WORKSPACE="$_workspace"
  _receipt_snapshot="$_workspace/receipt.json"
  if _mdm_snapshot_bound_file "$_receipt" "$_receipt_snapshot" receipt \
    && _mdm_detect_from_snapshots "$_receipt_snapshot" "$_user" \
      "$_expected_commit" "$_expected_policy" "$_workspace"; then
    _rc=0
  fi
  _mdm_cleanup_active_workspace || _rc=1
  return "$_rc"
}

_mdm_semver_identifiers_are_valid() { # <dot-list> <prerelease|build>
  local _rest="$1" _kind="$2" _identifier
  case "$_kind" in prerelease|build) : ;; *) return 1 ;; esac
  [[ -n "$_rest" && "$_rest" != .* && "$_rest" != *. \
    && "$_rest" != *..* ]] || return 1
  while :; do
    if [[ "$_rest" == *.* ]]; then
      _identifier="${_rest%%.*}"
      _rest="${_rest#*.}"
    else
      _identifier="$_rest"
      _rest=""
    fi
    [[ "$_identifier" =~ ^[0-9A-Za-z-]+$ ]] || return 1
    if [[ "$_kind" == prerelease && "$_identifier" =~ ^[0-9]+$ \
      && ${#_identifier} -gt 1 && "${_identifier:0:1}" == 0 ]]; then
      return 1
    fi
    [[ -n "$_rest" ]] || break
  done
  return 0
}

_mdm_semver_is_valid() {
  local _version="${1#v}" _main _core _prerelease="" _build=""
  local _major _minor _patch _rest _number
  [[ -n "$_version" ]] || return 1
  if [[ "$_version" == *+* ]]; then
    _build="${_version#*+}"
    _main="${_version%%+*}"
    [[ "$_build" != *+* ]] || return 1
    _mdm_semver_identifiers_are_valid "$_build" build || return 1
  else
    _main="$_version"
  fi
  if [[ "$_main" == *-* ]]; then
    _prerelease="${_main#*-}"
    _core="${_main%%-*}"
    _mdm_semver_identifiers_are_valid "$_prerelease" prerelease || return 1
  else
    _core="$_main"
  fi

  _major="${_core%%.*}"
  _rest="${_core#*.}"
  [[ "$_rest" != "$_core" ]] || return 1
  _minor="${_rest%%.*}"
  _patch="${_rest#*.}"
  [[ "$_patch" != "$_rest" && "$_patch" != *.* ]] || return 1
  for _number in "$_major" "$_minor" "$_patch"; do
    [[ "$_number" == 0 || "$_number" =~ ^[1-9][0-9]*$ ]] || return 1
  done
  return 0
}

_mdm_decimal_compare() { # <canonical-decimal-a> <canonical-decimal-b>
  local _a="$1" _b="$2" LC_ALL=C
  if [[ ${#_a} -lt ${#_b} ]]; then printf '%s' -1; return 0; fi
  if [[ ${#_a} -gt ${#_b} ]]; then printf '%s' 1; return 0; fi
  if [[ "$_a" < "$_b" ]]; then printf '%s' -1; return 0; fi
  if [[ "$_b" < "$_a" ]]; then printf '%s' 1; return 0; fi
  printf '%s' 0
}

_mdm_version_lt() {
  local _a="${1#v}" _b="${2#v}" _a_core _b_core _a_pre="" _b_pre=""
  local _a_major _a_minor _a_patch _b_major _b_minor _b_patch
  local _index _cmp _a_rest _b_rest _a_id _b_id _a_more _b_more
  local LC_ALL=C
  _a="${_a%%+*}"
  _b="${_b%%+*}"
  if [[ "$_a" == *-* ]]; then _a_pre="${_a#*-}"; _a_core="${_a%%-*}"; else _a_core="$_a"; fi
  if [[ "$_b" == *-* ]]; then _b_pre="${_b#*-}"; _b_core="${_b%%-*}"; else _b_core="$_b"; fi
  IFS=. read -r _a_major _a_minor _a_patch <<< "$_a_core"
  IFS=. read -r _b_major _b_minor _b_patch <<< "$_b_core"
  local -a _a_parts=("$_a_major" "$_a_minor" "$_a_patch")
  local -a _b_parts=("$_b_major" "$_b_minor" "$_b_patch")
  for _index in 0 1 2; do
    _cmp="$(_mdm_decimal_compare "${_a_parts[_index]}" "${_b_parts[_index]}")"
    case "$_cmp" in -1) return 0 ;; 1) return 1 ;; esac
  done

  [[ -n "$_a_pre" || -n "$_b_pre" ]] || return 1
  [[ -n "$_a_pre" ]] || return 1
  [[ -n "$_b_pre" ]] || return 0
  _a_rest="$_a_pre"
  _b_rest="$_b_pre"
  while :; do
    if [[ "$_a_rest" == *.* ]]; then
      _a_id="${_a_rest%%.*}"; _a_rest="${_a_rest#*.}"; _a_more=1
    else
      _a_id="$_a_rest"; _a_rest=""; _a_more=0
    fi
    if [[ "$_b_rest" == *.* ]]; then
      _b_id="${_b_rest%%.*}"; _b_rest="${_b_rest#*.}"; _b_more=1
    else
      _b_id="$_b_rest"; _b_rest=""; _b_more=0
    fi

    if [[ "$_a_id" =~ ^[0-9]+$ && "$_b_id" =~ ^[0-9]+$ ]]; then
      _cmp="$(_mdm_decimal_compare "$_a_id" "$_b_id")"
      case "$_cmp" in -1) return 0 ;; 1) return 1 ;; esac
    elif [[ "$_a_id" =~ ^[0-9]+$ ]]; then
      return 0
    elif [[ "$_b_id" =~ ^[0-9]+$ ]]; then
      return 1
    else
      [[ "$_a_id" < "$_b_id" ]] && return 0
      [[ "$_b_id" < "$_a_id" ]] && return 1
    fi

    [[ "$_a_more" -eq 1 || "$_b_more" -eq 1 ]] || return 1
    [[ "$_a_more" -eq 1 ]] || return 0
    [[ "$_b_more" -eq 1 ]] || return 1
  done
}

_mdm_detect_usage() {
  printf 'usage: detect-mdm.sh [--user USER] [--min-version X.Y.Z] --expected-commit FULL_SHA --expected-policy-sha256 SHA256\n' >&2
}

_mdm_user_is_not_applicable() {
  case "$1" in
    ''|[Rr][Oo][Oo][Tt] \
      |_[Mm][Bb][Ss][Ee][Tt][Uu][Pp][Uu][Ss][Ee][Rr] \
      |_[Uu][Nn][Rr][Ee][Ss][Oo][Ll][Vv][Ee][Dd] \
      |[Ll][Oo][Gg][Ii][Nn][Ww][Ii][Nn][Dd][Oo][Ww] \
      |[Dd][Aa][Ee][Mm][Oo][Nn]|[Nn][Oo][Bb][Oo][Dd][Yy]) return 0 ;;
    *) return 1 ;;
  esac
}

mdm_detect_main() {
  local _user="" _min_version="" _expected_commit="" _expected_policy=""
  local _user_explicit=0
  local _euid _receipt_dir _receipt _kit_version
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        [[ $# -ge 2 && -n "$2" ]] || { _mdm_detect_usage; return 2; }
        _user="$2"; _user_explicit=1; shift 2 ;;
      --min-version)
        [[ $# -ge 2 && -n "$2" ]] || { _mdm_detect_usage; return 2; }
        _min_version="$2"; shift 2 ;;
      --expected-commit)
        [[ $# -ge 2 && -n "$2" ]] || { _mdm_detect_usage; return 2; }
        _expected_commit="$2"; shift 2 ;;
      --expected-policy-sha256)
        [[ $# -ge 2 && -n "$2" ]] || { _mdm_detect_usage; return 2; }
        _expected_policy="$2"; shift 2 ;;
      --*)
        _mdm_detect_usage; return 2 ;;
      *)
        _mdm_detect_usage; return 2 ;;
    esac
  done

  [[ -z "$_min_version" ]] || _mdm_semver_is_valid "$_min_version" \
    || { _mdm_detect_usage; return 2; }
  [[ "$_expected_commit" =~ ^[0-9a-f]{40}$ ]] \
    || { _mdm_detect_usage; return 2; }
  [[ "$_expected_policy" =~ ^[0-9a-f]{64}$ ]] \
    || { _mdm_detect_usage; return 2; }

  if _euid="$(_mdm_test_value MDM_EUID_OVERRIDE)"; then :
  else _euid="$(/usr/bin/id -u 2>/dev/null || true)"; fi
  [[ "$_euid" =~ ^[0-9]+$ ]] || return 4
  if [[ "$_euid" -ne 0 ]]; then
    printf 'indeterminate: root privileges required\n'
    return 4
  fi

  if [[ -z "$_user" ]]; then
    _user="$(_mdm_detect_console_user)"
  fi
  if _mdm_user_is_not_applicable "$_user"; then
    if [[ "$_user_explicit" == 1 ]]; then
      _mdm_detect_usage
      return 2
    fi
    printf 'not-applicable: no eligible console user\n'
    return 3
  fi
  if ! _mdm_username_is_safe "$_user"; then
    if [[ "$_user_explicit" == "1" ]]; then _mdm_detect_usage; return 2; fi
    printf 'non-compliant: invalid target user (%s)\n' "$_user"
    return 1
  fi

  # Root remediation has one receipt contract.  Both root inventory and a
  # non-root self-check read the same root-owned system receipt.
  if _receipt_dir="$(_mdm_test_value MDM_RECEIPT_DIR_OVERRIDE)"; then :; else
    _receipt_dir='/Library/Application Support/ClaudeCodeStarterKit'
  fi
  _receipt="$_receipt_dir/receipt-$_user.json"
  if ! mdm_detect "$_receipt" "$_user" "$_expected_commit" \
    "$_expected_policy"; then
    printf 'non-compliant: receipt or deployed state verification failed (%s)\n' "$_receipt"
    return 1
  fi

  if [[ -n "$_min_version" ]]; then
    # mdm_detect parsed the fd-bound receipt snapshot.  Never reopen the
    # original receipt pathname after the trust check.
    _kit_version="$_MDM_DETECT_VERIFIED_KIT_VERSION"
    if ! _mdm_semver_is_valid "$_kit_version" \
      || _mdm_version_lt "$_kit_version" "$_min_version"; then
      printf 'non-compliant: kit_version %s does not meet required %s\n' \
        "$_kit_version" "$_min_version"
      return 1
    fi
  fi
  printf 'compliant\n'
  return 0
}
