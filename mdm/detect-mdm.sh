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
  [[ "$_user" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*([.@][A-Za-z0-9_-]+)*$ ]]
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

_mdm_launcher_path_trusted() {
  local _script="$1" _dir _base _canonical _path _owner _mode _line _perms
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
    if [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]]; then
      _line="$(LC_ALL=C /bin/ls -lde "$_path" 2>/dev/null || true)"
      _perms="${_line%%[[:space:]]*}"
      [[ -n "$_perms" && "$_perms" != *+* ]] || return 1
    fi
    [[ "$_path" == / ]] && break
    _path="${_path%/*}"
    [[ -n "$_path" ]] || _path=/
  done
  _MDM_LAUNCHER_PHYSICAL="$_canonical"
  return 0
}

_mdm_launcher_snapshot() {
  local _source="$1" _before _opened _tmp_base _tmp _old_umask
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
  _tmp="$(/usr/bin/mktemp "$_tmp_base/claude-kit-mdm-launcher.XXXXXX")" \
    || { umask "$_old_umask"; exec 9<&-; return 1; }
  umask "$_old_umask"
  /bin/cat <&9 > "$_tmp" || { exec 9<&-; /bin/rm -f "$_tmp"; return 1; }
  exec 9<&-
  /bin/chmod 500 "$_tmp" || { /bin/rm -f "$_tmp"; return 1; }
  printf '%s' "$_tmp"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  _mdm_clean_home=/var/root
  _mdm_clean_script="$0"
  if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
    _mdm_clean_home="${HOME:-/tmp}"
  else
    if ! _mdm_launcher_path_trusted "$_mdm_clean_script"; then
      printf 'MDM detector launcher path is not trusted\n' >&2
      exit 50
    fi
    _mdm_clean_script="$_MDM_LAUNCHER_PHYSICAL"
  fi
  _mdm_clean_script="$(_mdm_launcher_snapshot "$_mdm_clean_script")" || {
    printf 'MDM detector launcher snapshot failed\n' >&2
    exit 50
  }
  trap '/bin/rm -f "$_mdm_clean_script"' EXIT
  trap '/bin/rm -f "$_mdm_clean_script"; exit 130' INT TERM
  exec /usr/bin/env -i \
    "HOME=$_mdm_clean_home" \
    'PATH=/usr/bin:/bin:/usr/sbin:/sbin' \
    'LC_ALL=C' \
    /bin/bash --noprofile --norc -p -c '
      _mdm_script=$1
      shift
      trap '\''/bin/rm -f "$_mdm_script"'\'' EXIT
      trap '\''/bin/rm -f "$_mdm_script"; exit 130'\'' INT TERM
      . "$_mdm_script"
      /bin/rm -f "$_mdm_script"
      trap - EXIT INT TERM
      trap "_mdm_cleanup_active_workspace" EXIT
      trap "_mdm_cleanup_active_workspace; exit 130" INT TERM
      mdm_detect_main "$@"
      exit $?
    ' mdm-detect-clean "$_mdm_clean_script" "$@"
  exit 2
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

_mdm_json_get() { # <file> <key-path>
  local _file="$1" _key="$2"
  if _mdm_is_darwin; then
    /usr/bin/plutil -extract "$_key" raw -o - "$_file" 2>/dev/null || true
  elif [[ -x /usr/bin/jq ]]; then
    /usr/bin/jq -r --arg key "$_key" 'getpath($key | split(".")) // empty' \
      "$_file" 2>/dev/null || true
  fi
}

_mdm_json_array_count() { # <file> <key-path>
  local _file="$1" _key="$2"
  if _mdm_is_darwin; then
    /usr/bin/plutil -extract "$_key" raw -o - "$_file" 2>/dev/null || true
  elif [[ -x /usr/bin/jq ]]; then
    /usr/bin/jq -r --arg key "$_key" \
      'getpath($key | split(".")) | if type == "array" then length else empty end' \
      "$_file" 2>/dev/null || true
  fi
}

_mdm_json_array_get() { # <file> <key-path> <index>
  local _file="$1" _key="$2" _index="$3"
  if _mdm_is_darwin; then
    /usr/bin/plutil -extract "${_key}.${_index}" raw -o - "$_file" 2>/dev/null || true
  elif [[ -x /usr/bin/jq ]]; then
    /usr/bin/jq -r --arg key "$_key" --argjson index "$_index" \
      'getpath($key | split("."))[$index] // empty' "$_file" 2>/dev/null || true
  fi
}

_mdm_stat_owner() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%Su' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%U' "$1" 2>/dev/null
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
  local _listing
  _mdm_is_darwin || return 1
  _listing="$(/bin/ls -lde "$1" 2>/dev/null)" || return 0
  [[ "${_listing%%$'\n'*}" == *+* ]] && return 0
  printf '%s\n' "$_listing" | /usr/bin/grep -Eq '^[[:space:]]*[0-9]+:'
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
  local _path="$1" _owner="$2" _kind="$3" _actual_owner _mode
  [[ -e "$_path" && ! -L "$_path" ]] || return 1
  case "$_kind" in
    dir) [[ -d "$_path" ]] || return 1 ;;
    file) [[ -f "$_path" ]] || return 1 ;;
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

_mdm_receipt_is_trusted() { # <receipt> <target-user>
  local _receipt="$1" _user="$2" _base _owner _receipt_dir _canonical
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
  _canonical="$(_mdm_canonical_file "$_receipt")" || return 1
  [[ "$_canonical" == "$_receipt" ]]
}

_mdm_detect_user_home() {
  local _user="$1" _override
  if _override="$(_mdm_test_value MDM_DETECT_HOME_OVERRIDE)"; then
    printf '%s' "$_override"
    return 0
  fi
  /usr/bin/dscl . -read "/Users/$_user" NFSHomeDirectory 2>/dev/null \
    | /usr/bin/awk '{print $2; exit}' || true
}

_mdm_detect_user_uid() {
  local _user="$1" _override
  if _override="$(_mdm_test_value MDM_DETECT_EXPECTED_UID_OVERRIDE)"; then
    printf '%s' "$_override"
    return 0
  fi
  /usr/bin/id -u "$_user" 2>/dev/null
}

_mdm_detect_console_user() {
  local _override _user
  if _override="$(_mdm_test_value MDM_CONSOLE_USER_OVERRIDE)"; then
    printf '%s' "$_override"
    return 0
  fi
  _user="$(printf 'show State:/Users/ConsoleUser\n' \
    | /usr/sbin/scutil 2>/dev/null \
    | /usr/bin/awk '/Name :/{print $3; exit}' || true)"
  [[ -n "$_user" ]] || _user="$(_mdm_stat_owner /dev/console 2>/dev/null || true)"
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

_mdm_cli_present() { # <home> <expected-uid> <private-workspace>
  local _home="$1" _expected_uid="${2:-}" _workspace="${3:-}"
  local _override _cli _link_value _candidate _target
  local _versions _version _snapshot _rc=1
  if _override="$(_mdm_test_value MDM_DETECT_CLI_PRESENT_OVERRIDE)"; then
    [[ "$_override" == "1" ]]
    return
  fi
  _cli="$_home/.local/bin/claude"
  _versions="$_home/.local/share/claude/versions"
  [[ -n "$_home" && -L "$_cli" ]] || return 1
  [[ "$(_mdm_canonical_dir "$_home")" == "$_home" ]] || return 1
  [[ "$(_mdm_canonical_dir "$_home/.local/bin")" == "$_home/.local/bin" ]] || return 1
  [[ "$(_mdm_canonical_dir "$_versions")" == "$_versions" ]] || return 1
  _link_value="$(/usr/bin/readlink "$_cli" 2>/dev/null)" || return 1
  case "$_link_value" in
    /*) _candidate="$_link_value" ;;
    *) _candidate="${_cli%/*}/$_link_value" ;;
  esac
  _target="$(_mdm_canonical_file "$_candidate")" || return 1
  case "$_target" in "$_versions"/*) : ;; *) return 1 ;; esac
  _version="${_target#"$_versions"/}"
  [[ -n "$_version" && "$_version" != */* && -x "$_target" ]] || return 1
  [[ -x /usr/bin/codesign ]] || return 1
  [[ "$_expected_uid" =~ ^[0-9]+$ && -d "$_workspace" && ! -L "$_workspace" ]] || return 1
  _snapshot="$_workspace/claude-cli"
  _mdm_snapshot_bound_file "$_target" "$_snapshot" cli "$_expected_uid" || return 1
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
_mdm_extract_managed_section() { # <input> <output> <require-entire:0|1>
  local _input="$1" _output="$2" _require_entire="$3"
  [[ "$_require_entire" == 0 || "$_require_entire" == 1 ]] || return 1
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
_mdm_snapshot_bound_file() { # <source> <snapshot> <receipt|manifest|managed|head> [uid]
  local _source="$1" _snapshot="$2" _label="$3" _expected_uid="${4:-}"
  local _metadata _metadata_check _before _opened _size _uid _mode_raw _mode _nlink
  local _limit _copy_limit _copied _copied_size
  local _done="$_snapshot.done" _child _watchdog _rc _mdm_copy_rc
  _MDM_DETECT_SNAPSHOT_SIZE=""
  _MDM_DETECT_SNAPSHOT_MODE=""
  [[ -f "$_source" && ! -L "$_source" ]] || return 1
  _metadata="$(_mdm_stat_metadata "$_source")" || return 1
  _nlink="${_metadata##*:}"; _metadata_check="${_metadata%:*}"
  _mode_raw="${_metadata_check##*:}"; _metadata_check="${_metadata_check%:*}"
  _uid="${_metadata_check##*:}"; _before="${_metadata_check%:*}"
  _mode="$(_mdm_mode_normalize "$_mode_raw")" || return 1
  case "$_before" in *:Regular\ File:*|*:regular\ file:*) : ;; *) return 1 ;; esac
  _size="${_before##*:}"
  case "$_label" in
    receipt|manifest) _limit=4194304 ;;
    managed) _limit=67108864 ;;
    cli) _limit=536870912 ;;
    head) _limit=41 ;;
    *) return 1 ;;
  esac
  [[ "$_size" =~ ^[0-9]+$ && "$_size" -le "$_limit" ]] || return 1
  [[ "$_label" != head || "$_size" == 41 ]] || return 1
  if [[ "$_label" == managed || "$_label" == cli ]]; then
    [[ "$_expected_uid" =~ ^[0-9]+$ && "$_uid" == "$_expected_uid" ]] || return 1
    [[ "$_nlink" == 1 ]] || return 1
    ! _mdm_has_acl "$_source" || return 1
    [[ "$(_mdm_stat_metadata "$_source")" == "$_metadata" ]] || return 1
  fi
  _copy_limit=$((_limit + 1))
  /bin/rm -f "$_snapshot" "$_done"

  (
    _mdm_copy_rc=0
    exec 8<"$_source" || _mdm_copy_rc=1
    if [[ "$_mdm_copy_rc" -eq 0 ]]; then
      _opened="$(_mdm_stat_fd_identity 8)" || _mdm_copy_rc=1
    fi
    if [[ "$_mdm_copy_rc" -eq 0 && "$_before" != "$_opened" ]]; then
      _mdm_copy_rc=1
    fi
    if [[ "$_mdm_copy_rc" -eq 0 ]] \
      && ! (umask 077; /usr/bin/head -c "$_copy_limit" <&8 > "$_snapshot"); then
      _mdm_copy_rc=1
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
    if [[ "$_mdm_copy_rc" -eq 0 \
      && ( "$_label" == managed || "$_label" == cli ) ]]; then
      [[ "$(_mdm_stat_metadata "$_source")" == "$_metadata" ]] \
        && ! _mdm_has_acl "$_source" || _mdm_copy_rc=1
    fi
    [[ "$_mdm_copy_rc" -eq 0 ]] || /bin/rm -f "$_snapshot"
    printf '%s\n' "$_mdm_copy_rc" > "$_done"
    exit "$_mdm_copy_rc"
  ) &
  _child=$!
  (
    _mdm_watchdog_timer=""
    trap '[[ -z "${_mdm_watchdog_timer:-}" ]] \
      || kill "$_mdm_watchdog_timer" 2>/dev/null || true; exit 0' TERM INT
    /bin/sleep 5 >/dev/null 2>&1 &
    _mdm_watchdog_timer=$!
    wait "$_mdm_watchdog_timer" 2>/dev/null || true
    if [[ ! -f "$_done" ]]; then
      kill -TERM "$_child" 2>/dev/null || true
      /bin/sleep 1 >/dev/null 2>&1 &
      _mdm_watchdog_timer=$!
      wait "$_mdm_watchdog_timer" 2>/dev/null || true
      [[ -f "$_done" ]] || kill -KILL "$_child" 2>/dev/null || true
    fi
    trap - TERM INT
  ) &
  _watchdog=$!
  if wait "$_child" 2>/dev/null; then _rc=0; else _rc=$?; fi
  kill "$_watchdog" 2>/dev/null || true
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
  local _receipt="$1" _count _index _value _kit=0 _cli=0
  _count="$(_mdm_json_array_count "$_receipt" required_components)"
  [[ "$_count" =~ ^[0-9]+$ && "$_count" -ge 1 && "$_count" -le 2 ]] || return 1
  _index=0
  while (( _index < _count )); do
    _value="$(_mdm_json_array_get "$_receipt" required_components "$_index")"
    case "$_value" in
      kit) _kit=$((_kit + 1)) ;;
      claude_cli) _cli=$((_cli + 1)) ;;
      *) return 1 ;;
    esac
    _index=$((_index + 1))
  done
  [[ "$_kit" -eq 1 && "$_cli" -le 1 ]]
}

_mdm_manifest_is_valid() {
  # <manifest-snapshot> <sha256> <resolved-sha> <home> <profile> <language>
  # <deployment-sha256> <private-workspace> <expected-uid>
  local _manifest="$1" _expected_hash="$2" _resolved_sha="$3" _home="$4"
  local _receipt_profile="$5" _receipt_language="$6" _expected_deployment="$7"
  local _workspace="$8" _expected_uid="${9:-}"
  local _claude_dir="$_home/.claude" _snapshot="$_home/.claude/.starter-kit-snapshot"
  local _actual_hash _kit_commit _manifest_profile _manifest_language
  local _count _index=0 _file _relative _snapshot_file _canonical
  local _live_copy _snapshot_copy _live_hash _snapshot_hash _live_size _snapshot_size
  local _live_mode _snapshot_mode _live_managed _snapshot_managed
  local _aggregate_size=0 _aggregate_limit=536870912 _digest_input _digest
  local _absent_count _absent_index=0 _absent_relative

  _actual_hash="$(_mdm_sha256 "$_manifest")" || return 1
  [[ "$_actual_hash" == "$_expected_hash" ]] || return 1
  [[ "$(_mdm_json_get "$_manifest" version)" == "2" ]] || return 1
  [[ "$(_mdm_json_get "$_manifest" mdm_managed)" == "true" ]] || return 1
  [[ "$(_mdm_json_get "$_manifest" claude_dir)" == "$_claude_dir" ]] || return 1
  [[ "$(_mdm_json_get "$_manifest" snapshot_dir)" == "$_snapshot" ]] || return 1
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
_mdm_detect_from_snapshots() { # <receipt-snapshot> <user> <expected-commit> <workspace>
  local _receipt="$1" _user="$2" _expected_commit="$3" _workspace="$4"
  local _schema _result _target _install _install_canonical _sha
  local _git_dir _head_path _head_snapshot _head_size _head
  local _home _home_canonical _manifest _manifest_from_receipt _manifest_hash
  local _manifest_snapshot _manifest_canonical _profile _language _deployment_hash
  local _expected_uid

  _schema="$(_mdm_json_get "$_receipt" schema_version)"
  [[ "$_schema" == "2" ]] || return 1
  _result="$(_mdm_json_get "$_receipt" result)"
  [[ "$_result" == "success" ]] || return 1
  [[ "$(_mdm_json_get "$_receipt" exit_code)" == "0" ]] || return 1
  _target="$(_mdm_json_get "$_receipt" target_user)"
  [[ -n "$_user" && "$_target" == "$_user" ]] || return 1
  _mdm_required_components_are_valid "$_receipt" || return 1

  _sha="$(_mdm_json_get "$_receipt" resolved_sha)"
  [[ "$_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ -z "$_expected_commit" || "$_sha" == "$_expected_commit" ]] || return 1
  _profile="$(_mdm_json_get "$_receipt" profile)"
  _language="$(_mdm_json_get "$_receipt" language)"
  case "$_profile" in minimal|standard|full) : ;; *) return 1 ;; esac
  case "$_language" in en|ja) : ;; *) return 1 ;; esac
  _deployment_hash="$(_mdm_json_get "$_receipt" deployment_sha256)"
  [[ "$_deployment_hash" =~ ^[0-9a-f]{64}$ ]] || return 1

  _install="$(_mdm_json_get "$_receipt" install_dir)"
  _install_canonical="$(_mdm_canonical_dir "$_install")" || return 1
  [[ "$_install_canonical" == "$_install" ]] || return 1
  _git_dir="$_install/.git"
  [[ "$(_mdm_canonical_dir "$_git_dir")" == "$_git_dir" ]] || return 1
  _head_path="$_git_dir/HEAD"
  [[ "$(_mdm_canonical_file "$_head_path")" == "$_head_path" ]] || return 1
  _head_snapshot="$_workspace/git-head"
  _mdm_snapshot_bound_file "$_head_path" "$_head_snapshot" head || return 1
  _head_size="$(/usr/bin/wc -c < "$_head_snapshot" \
    | /usr/bin/tr -d '[:space:]')" || return 1
  [[ "$_head_size" == "41" ]] || return 1
  _head="$(/bin/cat "$_head_snapshot")" || return 1
  [[ "$_head" =~ ^[0-9a-f]{40}$ && "$_head" == "$_sha" ]] || return 1

  _home="$(_mdm_detect_user_home "$_user")"
  _home_canonical="$(_mdm_canonical_dir "$_home")" || return 1
  [[ "$_home_canonical" == "$_home" ]] || return 1
  _expected_uid="$(_mdm_detect_user_uid "$_user")" || return 1
  [[ "$_expected_uid" =~ ^[0-9]+$ ]] || return 1
  _manifest="$_home/.claude/.starter-kit-manifest.json"
  _manifest_from_receipt="$(_mdm_json_get "$_receipt" manifest_path)"
  [[ "$_manifest_from_receipt" == "$_manifest" ]] || return 1
  _manifest_hash="$(_mdm_json_get "$_receipt" manifest_sha256)"
  [[ "$_manifest_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  _manifest_canonical="$(_mdm_canonical_file "$_manifest")" || return 1
  [[ "$_manifest_canonical" == "$_manifest" ]] || return 1
  _manifest_snapshot="$_workspace/manifest.json"
  _mdm_snapshot_bound_file "$_manifest" "$_manifest_snapshot" manifest || return 1
  _mdm_manifest_is_valid "$_manifest_snapshot" "$_manifest_hash" "$_sha" "$_home" \
    "$_profile" "$_language" "$_deployment_hash" "$_workspace" \
    "$_expected_uid" || return 1

  if _mdm_required_component_present "$_receipt" claude_cli; then
    _mdm_cli_present "$_home" "$_expected_uid" "$_workspace" || return 1
  fi
  _MDM_DETECT_VERIFIED_KIT_VERSION="$(_mdm_json_get "$_receipt" kit_version)"
  [[ -n "$_MDM_DETECT_VERIFIED_KIT_VERSION" ]]
}

mdm_detect() { # <receipt> <target-user> [expected-commit]
  local _receipt="$1" _user="$2" _expected_commit="${3:-}"
  local _workspace="" _receipt_snapshot _rc=1
  _MDM_DETECT_VERIFIED_KIT_VERSION=""
  _mdm_receipt_is_trusted "$_receipt" "$_user" || return 1
  _workspace="$(_mdm_private_tmpdir)" || return 1
  _MDM_DETECT_ACTIVE_WORKSPACE="$_workspace"
  _receipt_snapshot="$_workspace/receipt.json"
  if _mdm_snapshot_bound_file "$_receipt" "$_receipt_snapshot" receipt \
    && _mdm_detect_from_snapshots "$_receipt_snapshot" "$_user" \
      "$_expected_commit" "$_workspace"; then
    _rc=0
  fi
  _mdm_cleanup_active_workspace || _rc=1
  return "$_rc"
}

_mdm_semver_is_valid() {
  [[ "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]
}

_mdm_version_lt() {
  local _a="${1#v}" _b="${2#v}" _ifs_bak="$IFS"
  _a="${_a%%[-+]*}"
  _b="${_b%%[-+]*}"
  IFS=.
  # shellcheck disable=SC2206
  local -a _a_parts=($_a) _b_parts=($_b)
  IFS="$_ifs_bak"
  local _index _ai _bi
  for _index in 0 1 2; do
    _ai="${_a_parts[_index]}"
    _bi="${_b_parts[_index]}"
    if ((10#$_ai < 10#$_bi)); then return 0; fi
    if ((10#$_ai > 10#$_bi)); then return 1; fi
  done
  return 1
}

_mdm_detect_usage() {
  printf 'usage: detect-mdm.sh [--user USER] [--min-version X.Y.Z] [--expected-commit FULL_SHA]\n' >&2
}

mdm_detect_main() {
  local _user="" _min_version="" _expected_commit="" _user_explicit=0
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
      --*)
        _mdm_detect_usage; return 2 ;;
      *)
        _mdm_detect_usage; return 2 ;;
    esac
  done

  [[ -z "$_min_version" ]] || _mdm_semver_is_valid "$_min_version" \
    || { _mdm_detect_usage; return 2; }
  [[ -z "$_expected_commit" || "$_expected_commit" =~ ^[0-9a-f]{40}$ ]] \
    || { _mdm_detect_usage; return 2; }

  if [[ -z "$_user" ]]; then
    if _euid="$(_mdm_test_value MDM_EUID_OVERRIDE)"; then :; else _euid="$(/usr/bin/id -u)"; fi
    if [[ "$_euid" -eq 0 ]]; then
      _user="$(_mdm_detect_console_user)"
    else
      _user="$(/usr/bin/id -un 2>/dev/null || true)"
    fi
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
  if ! mdm_detect "$_receipt" "$_user" "$_expected_commit"; then
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
