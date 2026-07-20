#!/bin/bash
# tests/unit/test-mdm-install.sh - Unit tests for mdm/install-mdm.sh (関数単位)

# install-mdm.sh は main を末尾で条件実行する（BASH_SOURCE ガード）。source して関数だけ得る。
# shellcheck source=mdm/install-mdm.sh
MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"
_MDM_TEST_PYTHON_COMMAND="$(command -v python3)"
MDM_SYSTEM_PYTHON_OVERRIDE="$("$_MDM_TEST_PYTHON_COMMAND" -I -B -c \
  'import os, sys; print(os.path.realpath(sys.executable))')"
export MDM_SYSTEM_PYTHON_OVERRIDE

# Keep the process privilege under test separate from the real target-user
# identity used by ownership-sensitive fixtures.  Root CI selects an existing
# login account instead of turning UID 0 into a synthetic managed user.
_MDM_TEST_RUNNER_UID="$(/usr/bin/id -u)"
_MDM_TEST_TARGET_USER="$(/usr/bin/id -un)"
_MDM_TEST_TARGET_UID="$_MDM_TEST_RUNNER_UID"
_MDM_TEST_TARGET_GID="$(/usr/bin/id -g)"
if [[ "$_MDM_TEST_RUNNER_UID" -eq 0 ]]; then
  _MDM_TEST_TARGET_RECORD="$("$_MDM_TEST_PYTHON_COMMAND" -I -B - <<'PY'
import pwd

invalid_shells = {"", "/bin/false", "/usr/bin/false",
                  "/sbin/nologin", "/usr/sbin/nologin"}
users = [entry for entry in pwd.getpwall()
         if 501 <= entry.pw_uid <= 60000
         and entry.pw_shell not in invalid_shells]
if users:
    selected = min(users, key=lambda entry: entry.pw_uid)
    print(f"{selected.pw_name}\t{selected.pw_uid}\t{selected.pw_gid}")
PY
)"
  IFS=$'\t' read -r _MDM_TEST_TARGET_USER _MDM_TEST_TARGET_UID \
    _MDM_TEST_TARGET_GID <<< "$_MDM_TEST_TARGET_RECORD"
elif [[ "$_MDM_TEST_RUNNER_UID" -lt 501 ]]; then
  printf 'test-mdm-install.sh refuses a non-root runner with UID below 501\n' >&2
  exit 2
fi
_MDM_TEST_TARGET_BOUND_UID="$(/usr/bin/id -u \
  "$_MDM_TEST_TARGET_USER" 2>/dev/null || true)"
_MDM_TEST_TARGET_BOUND_GID="$(/usr/bin/id -g \
  "$_MDM_TEST_TARGET_USER" 2>/dev/null || true)"
if [[ -z "$_MDM_TEST_TARGET_USER" \
  || ! "$_MDM_TEST_TARGET_UID" =~ ^[0-9]+$ \
  || "$_MDM_TEST_TARGET_UID" -lt 501 \
  || "$_MDM_TEST_TARGET_UID" -gt 60000 \
  || ! "$_MDM_TEST_TARGET_GID" =~ ^[0-9]+$ \
  || "$_MDM_TEST_TARGET_BOUND_UID" != "$_MDM_TEST_TARGET_UID" \
  || "$_MDM_TEST_TARGET_BOUND_GID" != "$_MDM_TEST_TARGET_GID" ]]; then
  printf 'test-mdm-install.sh requires a real target account with UID 501..60000\n' >&2
  exit 2
fi

_MDM_TEST_TMP_ROOT_ORIGINAL_MODE=""
_MDM_TEST_TMP_ROOT_IDENTITY=""
_MDM_TEST_TMP_ROOT_OPEN_MODE=""
_MDM_TEST_TMP_ROOT_MODE_GUARD_PID=""
_MDM_TEST_TMP_ROOT_MODE_GUARD_DIR=""

_mdm_test_start_tmp_root_mode_guard() {
  local _wait_ticks=0
  [[ "$_MDM_TEST_RUNNER_UID" -eq 0 ]] || return 0
  printf -v _MDM_TEST_TMP_ROOT_OPEN_MODE '%04o' \
    "$(( _MDM_TEST_TMP_ROOT_ORIGINAL_MODE | 0011 ))"
  _MDM_TEST_TMP_ROOT_MODE_GUARD_DIR="$(/usr/bin/mktemp -d \
    "$MDM_TEST_TMP_ROOT/.mdm-install-mode-guard.XXXXXX")" || return 1
  [[ -d "$_MDM_TEST_TMP_ROOT_MODE_GUARD_DIR" \
    && ! -L "$_MDM_TEST_TMP_ROOT_MODE_GUARD_DIR" \
    && "$(_mdm_stat_uid "$_MDM_TEST_TMP_ROOT_MODE_GUARD_DIR" \
      2>/dev/null || true)" == 0 \
    && "$(_mdm_mode_normalize "$(_mdm_stat_mode \
      "$_MDM_TEST_TMP_ROOT_MODE_GUARD_DIR" 2>/dev/null || true)" \
      2>/dev/null || true)" == 0700 ]] || return 1
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    /bin/bash --noprofile --norc -c '
    _parent_pid="$1"
    _root="$2"
    _original_mode="$3"
    _open_mode="$4"
    _expected_identity="$5"
    _guard="$6"
    _identity() {
      if [[ "$(/usr/bin/uname -s)" == Darwin ]]; then
        /usr/bin/stat -f "%d:%i:%HT" "$1" 2>/dev/null
      else
        /usr/bin/stat -c "%d:%i:%F" "$1" 2>/dev/null
      fi
    }
    _uid() {
      if [[ "$(/usr/bin/uname -s)" == Darwin ]]; then
        /usr/bin/stat -f "%u" "$1" 2>/dev/null
      else
        /usr/bin/stat -c "%u" "$1" 2>/dev/null
      fi
    }
    _mode() {
      if [[ "$(/usr/bin/uname -s)" == Darwin ]]; then
        _raw="$(/usr/bin/stat -f "%Lp" "$1" 2>/dev/null)" || return 1
      else
        _raw="$(/usr/bin/stat -c "%a" "$1" 2>/dev/null)" || return 1
      fi
      printf "%04d" "$_raw"
    }
    _restore() {
      _restore_rc=0
      if [[ "$(_identity .)" == "$_expected_identity" \
        && "$(_uid .)" == 0 ]]; then
        /bin/chmod "$_original_mode" . || _restore_rc=1
        [[ "$(_mode .)" == "$_original_mode" ]] || _restore_rc=1
      else
        _restore_rc=1
      fi
      [[ ! -e "$_guard/ready" ]] || /bin/rmdir "$_guard/ready" \
        || _restore_rc=1
      [[ ! -e "$_guard/done" ]] || /bin/rmdir "$_guard/done" \
        || _restore_rc=1
      /bin/rmdir "$_guard" || _restore_rc=1
      return "$_restore_rc"
    }
    [[ "$_parent_pid" =~ ^[1-9][0-9]*$ \
      && "$_root" == /* && -d "$_root" && ! -L "$_root" \
      && "$_original_mode" =~ ^[0-7]{4}$ \
      && "$_open_mode" =~ ^[0-7]{4}$ \
      && "$_guard" == "$_root"/.mdm-install-mode-guard.* ]] \
      || exit 2
    builtin cd -P -- "$_root" || exit 2
    [[ "$PWD" == "$_root" && "$(_identity .)" == "$_expected_identity" \
      && "$(_uid .)" == 0 && "$(_mode .)" == "$_original_mode" ]] || exit 2
    trap '\''_exit_rc=$?; trap - EXIT; _restore || _exit_rc=1; exit "$_exit_rc"'\'' EXIT
    trap "exit 0" HUP INT TERM
    /bin/chmod go+x . || exit 2
    [[ "$(_identity .)" == "$_expected_identity" && "$(_uid .)" == 0 \
      && "$(_mode .)" == "$_open_mode" ]] || exit 2
    /bin/mkdir "$_guard/ready" || exit 2
    while [[ ! -d "$_guard/done" ]]; do
      _current_parent="$(/bin/ps -p "$$" -o ppid= 2>/dev/null \
        | /usr/bin/tr -d "[:space:]")"
      [[ "$_current_parent" == "$_parent_pid" ]] || exit 0
      /bin/sleep 0.05
    done
    exit 0
  ' mdm-mode-guard "$$" "$MDM_TEST_TMP_ROOT" \
    "$_MDM_TEST_TMP_ROOT_ORIGINAL_MODE" "$_MDM_TEST_TMP_ROOT_OPEN_MODE" \
    "$_MDM_TEST_TMP_ROOT_IDENTITY" \
    "$_MDM_TEST_TMP_ROOT_MODE_GUARD_DIR" >/dev/null 2>&1 &
  _MDM_TEST_TMP_ROOT_MODE_GUARD_PID=$!
  while [[ ! -d "$_MDM_TEST_TMP_ROOT_MODE_GUARD_DIR/ready" \
    && "$_wait_ticks" -lt 200 ]]; do
    /bin/sleep 0.01
    _wait_ticks=$((_wait_ticks + 1))
  done
  [[ -d "$_MDM_TEST_TMP_ROOT_MODE_GUARD_DIR/ready" \
    && ! -L "$_MDM_TEST_TMP_ROOT_MODE_GUARD_DIR/ready" \
    && "$(_mdm_persistent_dir_identity "$MDM_TEST_TMP_ROOT" \
      2>/dev/null || true)" == "$_MDM_TEST_TMP_ROOT_IDENTITY" \
    && "$(_mdm_mode_normalize "$(_mdm_stat_mode \
      "$MDM_TEST_TMP_ROOT" 2>/dev/null || true)" 2>/dev/null || true)" \
      == "$_MDM_TEST_TMP_ROOT_OPEN_MODE" ]] || return 1
}

_mdm_test_stop_tmp_root_mode_guard() {
  local _guard_rc=0
  [[ "$_MDM_TEST_RUNNER_UID" -eq 0 ]] || return 0
  [[ "$_MDM_TEST_TMP_ROOT_MODE_GUARD_PID" =~ ^[1-9][0-9]*$ \
    && -d "$_MDM_TEST_TMP_ROOT_MODE_GUARD_DIR/ready" \
    && ! -e "$_MDM_TEST_TMP_ROOT_MODE_GUARD_DIR/done" ]] || return 1
  /bin/mkdir "$_MDM_TEST_TMP_ROOT_MODE_GUARD_DIR/done" || return 1
  wait "$_MDM_TEST_TMP_ROOT_MODE_GUARD_PID" || _guard_rc=$?
  if [[ "$(_mdm_persistent_dir_identity "$MDM_TEST_TMP_ROOT" \
    2>/dev/null || true)" == "$_MDM_TEST_TMP_ROOT_IDENTITY" \
    && "$(_mdm_stat_uid "$MDM_TEST_TMP_ROOT" 2>/dev/null || true)" == 0 ]]; then
    /bin/chmod "$_MDM_TEST_TMP_ROOT_ORIGINAL_MODE" "$MDM_TEST_TMP_ROOT" \
      || _guard_rc=1
  else
    _guard_rc=1
  fi
  [[ "$_guard_rc" -eq 0 \
    && "$(_mdm_persistent_dir_identity "$MDM_TEST_TMP_ROOT" \
      2>/dev/null || true)" == "$_MDM_TEST_TMP_ROOT_IDENTITY" \
    && "$(_mdm_mode_normalize "$(_mdm_stat_mode \
      "$MDM_TEST_TMP_ROOT" 2>/dev/null || true)" 2>/dev/null || true)" \
      == "$_MDM_TEST_TMP_ROOT_ORIGINAL_MODE" \
    && ! -e "$_MDM_TEST_TMP_ROOT_MODE_GUARD_DIR" \
    && ! -L "$_MDM_TEST_TMP_ROOT_MODE_GUARD_DIR" ]]
}

if [[ "$_MDM_TEST_RUNNER_UID" -eq 0 ]]; then
  if [[ "${MDM_TEST_TMP_ROOT:-}" != /* || ! -d "$MDM_TEST_TMP_ROOT" \
    || -L "$MDM_TEST_TMP_ROOT" \
    || "$(_mdm_stat_uid "$MDM_TEST_TMP_ROOT" 2>/dev/null || true)" != 0 \
    || "$(builtin cd -P -- "$MDM_TEST_TMP_ROOT" 2>/dev/null \
      && printf '%s' "$PWD")" != "$MDM_TEST_TMP_ROOT" ]]; then
    printf 'test-mdm-install.sh requires a root-owned runner MDM_TEST_TMP_ROOT\n' >&2
    exit 2
  fi
  _MDM_TEST_TMP_ROOT_ORIGINAL_MODE="$(_mdm_mode_normalize \
    "$(_mdm_stat_mode "$MDM_TEST_TMP_ROOT")")"
  _MDM_TEST_TMP_ROOT_IDENTITY="$(_mdm_persistent_dir_identity \
    "$MDM_TEST_TMP_ROOT")"
  if ! _mdm_mode_is_safe "$_MDM_TEST_TMP_ROOT_ORIGINAL_MODE" \
    || _mdm_has_extended_acl "$MDM_TEST_TMP_ROOT"; then
    printf 'test-mdm-install.sh requires a safe runner MDM_TEST_TMP_ROOT\n' >&2
    exit 2
  fi
  _mdm_test_start_tmp_root_mode_guard || exit 2
fi

_mdm_test_target_tmpdir() {
  local _dir _base _mode
  if [[ "$_MDM_TEST_RUNNER_UID" -eq 0 ]]; then
    _base="$MDM_TEST_TMP_ROOT"
    [[ -d "$_base" && ! -L "$_base" \
      && "$(builtin cd -P -- "$_base" && printf '%s' "$PWD")" == "$_base" ]] \
      || return 1
    _dir="$(/usr/bin/mktemp -d \
      "$_base/mdm-install-target.XXXXXX")" || return 1
    _dir="$(builtin cd -P -- "$_dir" && printf '%s' "$PWD")" \
      || { /bin/rm -rf "$_dir"; return 1; }
    case "$_dir" in "$_base"/mdm-install-target.*) : ;; *) return 1 ;; esac
    [[ -d "$_dir" && ! -L "$_dir" \
      && "$(_mdm_stat_uid "$_dir" 2>/dev/null || true)" == 0 ]] \
      || { /bin/rm -rf "$_dir"; return 1; }
    chmod 0755 "$_dir" || { /bin/rm -rf "$_dir"; return 1; }
    _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_dir")")"
    [[ "$_mode" == 0755 ]] || { /bin/rm -rf "$_dir"; return 1; }
  else
    _dir="$(/usr/bin/mktemp -d)" || return 1
  fi
  builtin cd -P -- "$_dir" && printf '%s' "$PWD"
}

_mdm_test_chown_target() {
  [[ "$_MDM_TEST_RUNNER_UID" -eq 0 ]] || return 0
  chown -R "$_MDM_TEST_TARGET_UID:$_MDM_TEST_TARGET_GID" "$@"
}

_mdm_test_exec_as_target() {
  local _uid="$1" _user="$2" _home="$3"
  local -a _target_argv
  shift 3
  _target_argv=(
    /usr/bin/env -i
    "HOME=$_home"
    "USER=$_user"
    "LOGNAME=$_user"
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    LC_ALL=C
    /bin/sh -c 'umask 022; cd "$HOME" || exit 1; exec "$@"'
    mdm-target-user
    "$@"
  )
  if [[ "$_MDM_TEST_RUNNER_UID" -eq 0 ]]; then
    /usr/bin/sudo -n -u "#$_uid" -H "${_target_argv[@]}"
  elif [[ "$_MDM_TEST_RUNNER_UID" -eq "$_uid" ]]; then
    "${_target_argv[@]}"
  else
    return 1
  fi
}

# ── 終了コード定数 ────────────────────────────────────────
if [[ "$MDM_EXIT_CONFIG" == "50" && "$MDM_EXIT_USER" == "20" ]]; then
  pass "mdm-install: 終了コード定数が定義されている"
else
  fail "mdm-install: 終了コード定数が不正"
fi

(
  MDM_TIMEOUT_OVERRIDE_SECONDS=1
  _MDM_TEST_MODE=0
  _timeout_production="$(_mdm_timeout_seconds "$_MDM_TIMEOUT_QUERY_SECONDS")"
  _MDM_TEST_MODE=1
  _timeout_source_test="$(_mdm_timeout_seconds "$_MDM_TIMEOUT_QUERY_SECONDS")"
  if [[ "$_MDM_TIMEOUT_QUERY_SECONDS" -eq 120 \
    && "$_MDM_TIMEOUT_GIT_SECONDS" -eq 300 \
    && "$_MDM_TIMEOUT_PACKAGE_SECONDS" -eq 600 \
    && "$_MDM_TIMEOUT_PKGUTIL_SECONDS" -eq 60 \
    && "$_MDM_TIMEOUT_WCE_NPM_SECONDS" -eq 900 \
    && "$_MDM_TIMEOUT_LOCAL_VALIDATION_SECONDS" -eq 120 \
    && "$_MDM_TIMEOUT_SETUP_SECONDS" -eq 1200 \
    && "$_MDM_TIMEOUT_CLT_INSTALL_SECONDS" -eq 1200 \
    && "$_timeout_production" -eq 120 && "$_timeout_source_test" -eq 1 ]]; then
    pass "mdm-install: production timeout は固定、短縮 override は source-test 限定"
  else
    fail "mdm-install: timeout 固定値または source-test 限定 override が不正"
  fi
)

# Generic deadline supervisor: ordinary I/O/status stays transparent, while a
# timeout removes a TERM-ignoring process tree and permits an immediate retry.
(
  _timeout_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _timeout_status_fixture() {
    printf 'fixture-out'
    printf 'fixture-err' >&2
    return 37
  }
  _timeout_rc=0
  _mdm_run_with_timeout 2 _timeout_status_fixture \
    > "$_timeout_tmp/out" 2> "$_timeout_tmp/err" || _timeout_rc=$?
  if [[ "$_timeout_rc" -eq 37 \
    && "$(< "$_timeout_tmp/out")" == fixture-out \
    && "$(< "$_timeout_tmp/err")" == fixture-err ]]; then
    pass "mdm-install: timeout supervisor は通常時の stdout/stderr/status を保持"
  else
    fail "mdm-install: timeout supervisor が通常実行を変質 (rc=$_timeout_rc)"
  fi

  _timeout_started=$SECONDS
  _timeout_rc=0
  _mdm_run_with_timeout 1 /bin/sh -c '
    trap "" TERM
    ( trap "" TERM; while :; do /bin/sleep 1; done ) &
    printf "%s" "$!" > "$1/grandchild.pid"
    printf "%s" "$$" > "$1/leader.pid"
    while :; do /bin/sleep 1; done
  ' mdm-timeout-fixture "$_timeout_tmp" >/dev/null 2>&1 || _timeout_rc=$?
  _timeout_elapsed=$((SECONDS - _timeout_started))
  _timeout_leader="$(< "$_timeout_tmp/leader.pid")"
  _timeout_grandchild="$(< "$_timeout_tmp/grandchild.pid")"
  /bin/sleep 0.2
  _timeout_retry_rc=0
  _mdm_run_with_timeout 1 /usr/bin/true || _timeout_retry_rc=$?
  if [[ "$_timeout_rc" -eq 124 && "$_timeout_elapsed" -le 5 \
    && "$_timeout_retry_rc" -eq 0 ]] \
    && ! _mdm_timeout_group_live "$_timeout_leader" \
    && ! /bin/ps -p "$_timeout_grandchild" -o stat= 2>/dev/null \
      | /usr/bin/grep -Ev '^[[:space:]]*Z' | /usr/bin/grep -q . \
    && ! /usr/bin/find "$_timeout_tmp" -maxdepth 1 \
      -name 'claude-kit-mdm-timeout.*' -print -quit | /usr/bin/grep -q .; then
    pass "mdm-install: timeout は TERM 無視の孫を停止し124・5秒以内・即時再試行可能"
  else
    fail "mdm-install: timeout cleanup/retry 契約が不正 (rc=$_timeout_rc elapsed=$_timeout_elapsed retry=$_timeout_retry_rc)"
  fi
  /bin/rm -rf "$_timeout_tmp"
)
(
  _timeout_signal_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _timeout_signal_ok=true
  _timeout_signal_failures=""
  for _timeout_signal in HUP INT TERM; do
    case "$_timeout_signal" in
      HUP) _timeout_signal_expected=129 ;;
      INT) _timeout_signal_expected=130 ;;
      TERM) _timeout_signal_expected=143 ;;
    esac
    _timeout_signal_dir="$_timeout_signal_tmp/$_timeout_signal"
    /bin/mkdir "$_timeout_signal_dir"
    TMPDIR="$_timeout_signal_dir"
    set -m
    _mdm_timeout_coordinator 30 /bin/sh -c '
      trap "" HUP INT TERM
      (
        trap "" HUP INT TERM
        while :; do /bin/sleep 1; done
      ) &
      printf "%s" "$!" > "$1/grandchild.pid"
      printf "%s" "$$" > "$1/leader.pid"
      while :; do /bin/sleep 1; done
    ' mdm-timeout-signal "$_timeout_signal_dir" \
      > "$_timeout_signal_dir/out" 2> "$_timeout_signal_dir/err" &
    _timeout_coordinator=$!
    set +m
    _timeout_wait_ticks=0
    while [[ ! -s "$_timeout_signal_dir/leader.pid" \
      || ! -s "$_timeout_signal_dir/grandchild.pid" ]] \
      && [[ "$_timeout_wait_ticks" -lt 200 ]]; do
      /bin/sleep 0.01
      _timeout_wait_ticks=$((_timeout_wait_ticks + 1))
    done
    _timeout_signal_started=$SECONDS
    /bin/kill "-$_timeout_signal" "$_timeout_coordinator" 2>/dev/null || true
    _timeout_signal_rc=0
    wait "$_timeout_coordinator" 2>/dev/null || _timeout_signal_rc=$?
    _timeout_signal_elapsed=$((SECONDS - _timeout_signal_started))
    _timeout_signal_leader="$(/bin/cat \
      "$_timeout_signal_dir/leader.pid" 2>/dev/null || true)"
    _timeout_signal_grandchild="$(/bin/cat \
      "$_timeout_signal_dir/grandchild.pid" 2>/dev/null || true)"
    _timeout_signal_retry=0
    _mdm_run_with_timeout 1 /usr/bin/true || _timeout_signal_retry=$?
    _timeout_signal_group_state=0
    _mdm_timeout_group_live "$_timeout_signal_leader" \
      || _timeout_signal_group_state=$?
    _timeout_signal_grandchild_live=false
    if /bin/ps -p "$_timeout_signal_grandchild" -o stat= 2>/dev/null \
      | /usr/bin/grep -Ev '^[[:space:]]*Z' | /usr/bin/grep -q .; then
      _timeout_signal_grandchild_live=true
    fi
    _timeout_signal_controls="$(/usr/bin/find "$_timeout_signal_dir" \
      -maxdepth 1 -name 'claude-kit-mdm-timeout.*' -print -quit)"
    if [[ "$_timeout_signal_rc" -ne "$_timeout_signal_expected" \
      || "$_timeout_signal_elapsed" -gt 15 || "$_timeout_signal_retry" -ne 0 ]] \
      || [[ ! "$_timeout_signal_leader" =~ ^[1-9][0-9]*$ \
        || ! "$_timeout_signal_grandchild" =~ ^[1-9][0-9]*$ ]] \
      || [[ "$_timeout_signal_group_state" -ne 1 \
        || "$_timeout_signal_grandchild_live" != false \
        || -n "$_timeout_signal_controls" ]]; then
      _timeout_signal_ok=false
      _timeout_signal_failures="${_timeout_signal_failures}${_timeout_signal}:rc=${_timeout_signal_rc}/expected=${_timeout_signal_expected}/elapsed=${_timeout_signal_elapsed}/retry=${_timeout_signal_retry}/group=${_timeout_signal_group_state}/grandchild=${_timeout_signal_grandchild_live}/controls=${_timeout_signal_controls:-none} "
    fi
  done
  if [[ "$_timeout_signal_ok" == true ]]; then
    pass "mdm-install: timeout coordinator は HUP/INT/TERM で全PG回収し129/130/143・再試行可能"
  else
    fail "mdm-install: timeout coordinator signal cleanup/status が不正 (${_timeout_signal_failures% })"
  fi
  /bin/rm -rf "$_timeout_signal_tmp"
)

(
  _json_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _json_file="$_json_tmp/value.json"
  printf '%s\n' '{"value":"kit","items":["one"],"count":2}' \
    > "$_json_file"
  if [[ "$(_mdm_json_get "$_json_file" value)" == kit \
    && "$(_mdm_json_array_get "$_json_file" items 0)" == one \
    && "$(_mdm_json_array_count "$_json_file" items)" == 1 ]]; then
    _json_good=0
  else
    _json_good=1
  fi
  _json_range_rc=0
  _mdm_json_array_get "$_json_file" items 9 \
    > "$_json_tmp/range.out" 2> "$_json_tmp/range.err" || _json_range_rc=$?
  _json_control_ok=1
  for _json_operation in get item; do
    for _json_control in lf cr nul; do
      case "$_json_control" in
        lf) printf '%s\n' '{"value":"kit\n","items":["one\n"]}' ;;
        cr) printf '%s\n' '{"value":"kit\r","items":["one\r"]}' ;;
        nul) printf '%s\n' '{"value":"kit\u0000","items":["one\u0000"]}' ;;
      esac > "$_json_file"
      _json_control_rc=0
      if [[ "$_json_operation" == get ]]; then
        _mdm_json_get "$_json_file" value \
          > "$_json_tmp/control.out" 2> "$_json_tmp/control.err" \
          || _json_control_rc=$?
      else
        _mdm_json_array_get "$_json_file" items 0 \
          > "$_json_tmp/control.out" 2> "$_json_tmp/control.err" \
          || _json_control_rc=$?
      fi
      if [[ "$_json_control_rc" -eq 0 || -s "$_json_tmp/control.out" \
        || -s "$_json_tmp/control.err" ]]; then
        _json_control_ok=0
      fi
    done
  done
  printf '{"value":"kit\302\205","items":[]}\n' > "$_json_file"
  _json_c1_rc=0
  _mdm_json_get "$_json_file" value > "$_json_tmp/c1.out" 2>/dev/null \
    || _json_c1_rc=$?
  printf '%s\n' '{"value":"first","value":"second"}' > "$_json_file"
  _json_duplicate_rc=0
  _mdm_json_valid "$_json_file" >/dev/null 2>&1 || _json_duplicate_rc=$?
  _json_eof_ok=1
  for _json_suffix in lf space tab cr nul no_lf; do
    printf '{}\n' > "$_json_file"
    case "$_json_suffix" in
      lf) printf '\n' >> "$_json_file" ;;
      space) printf ' ' >> "$_json_file" ;;
      tab) printf '\t' >> "$_json_file" ;;
      cr) printf '\r' >> "$_json_file" ;;
      nul) printf '\0' >> "$_json_file" ;;
      no_lf) printf '{}' > "$_json_file" ;;
    esac
    if _mdm_json_valid "$_json_file" >/dev/null 2>&1; then
      _json_eof_ok=0
    fi
  done
  printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' \
    > "$_json_file"
  _json_plist_rc=0
  _mdm_json_valid "$_json_file" >/dev/null 2>&1 || _json_plist_rc=$?
  : > "$_json_file"
  for ((_json_depth = 0; _json_depth < 1100; _json_depth++)); do
    printf '{"a":' >> "$_json_file"
  done
  printf '0' >> "$_json_file"
  for ((_json_depth = 0; _json_depth < 1100; _json_depth++)); do
    printf '}' >> "$_json_file"
  done
  printf '\n' >> "$_json_file"
  _json_depth_rc=0
  _mdm_json_valid "$_json_file" > "$_json_tmp/depth.out" \
    2> "$_json_tmp/depth.err" || _json_depth_rc=$?
  if [[ "$_json_good" -eq 0 && "$_json_control_ok" -eq 1 \
    && "$_json_c1_rc" -ne 0 && "$_json_duplicate_rc" -ne 0 \
    && "$_json_eof_ok" -eq 1 \
    && "$_json_plist_rc" -ne 0 && "$_json_range_rc" -ne 0 \
    && "$_json_depth_rc" -ne 0 && ! -s "$_json_tmp/range.err" \
    && ! -s "$_json_tmp/depth.err" && ! -s "$_json_tmp/c1.out" ]]; then
    pass "mdm-install: JSON getterはJSON-only/duplicate/EOF/controlを厳格拒否"
  else
    fail "mdm-install: strict JSON getter契約が不正"
  fi
  rm -rf "$_json_tmp"
)

if ! _mdm_macos_version_supported 13.4.9 \
  && _mdm_macos_version_supported 13.5 \
  && _mdm_macos_version_supported 13.5.0 \
  && _mdm_macos_version_supported 14.0 \
  && ! _mdm_macos_version_supported 13.05 \
  && ! _mdm_macos_version_supported 13.5.0.1 \
  && ! _mdm_macos_version_supported 13.5beta; then
  pass "mdm-install: private Node 24 用 macOS 13.5+ gate を厳格比較"
else
  fail "mdm-install: macOS 13.5+ version gate が不正"
fi

_post_setup_git_block="$(/usr/bin/sed -n \
  '/No post-setup Git process/,/_mdm_cleanup_auth_entry_list/p' \
  "$PROJECT_DIR/mdm/install-mdm.sh")"
if [[ -n "$_post_setup_git_block" ]] \
  && ! /usr/bin/grep -Fq '_mdm_git ' <<< "$_post_setup_git_block" \
  && /usr/bin/grep -Fq '_MDM_EXPECTED_KIT_COMPONENT_SHA256' \
    <<< "$_post_setup_git_block"; then
  pass "mdm-install: setup 後は Git を起動せず事前 kit digest と再照合"
else
  fail "mdm-install: setup 後の Git 禁止/digest 再照合契約が不正"
fi

(
  _clean_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _clean_repo="$_clean_tmp/repo"
  /usr/bin/git init -q "$_clean_repo"
  printf 'ignored-*\n' > "$_clean_repo/.gitignore"
  /usr/bin/git -C "$_clean_repo" add .gitignore
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$_clean_repo" commit -q -m fixture
  printf 'claude-code-starter-kit-mdm-user-v1\n' \
    > "$_clean_repo/.claude-starter-kit-mdm-managed"
  _clean_marker_only=false _clean_ignored_rejected=false
  _mdm_persistent_worktree_clean "$_clean_repo" \
    && _clean_marker_only=true
  printf 'injected\n' > "$_clean_repo/ignored-payload"
  _mdm_persistent_worktree_clean "$_clean_repo" \
    || _clean_ignored_rejected=true
  if [[ "$_clean_marker_only" == true \
    && "$_clean_ignored_rejected" == true ]]; then
    pass "mdm-install: retained checkout は managed marker のみ除外し ignored 注入を拒否"
  else
    fail "mdm-install: retained checkout が ignored 注入を clean と誤判定"
  fi
  /bin/rm -rf "$_clean_tmp"
)
(
  _content_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _content_auth="$_content_tmp/authority"
  _content_retained="$_content_tmp/retained"
  /usr/bin/git init -q "$_content_auth"
  printf 'original\n' > "$_content_auth/tracked.txt"
  printf 'ignored-*\n' > "$_content_auth/.gitignore"
  /usr/bin/git -C "$_content_auth" add tracked.txt .gitignore
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$_content_auth" commit -q -m fixture
  /usr/bin/git clone -q "$_content_auth" "$_content_retained"
  printf 'claude-code-starter-kit-mdm-user-v1\n' \
    > "$_content_retained/.claude-starter-kit-mdm-managed"
  _content_expected="$(_mdm_worktree_content_digest \
    "$_content_auth" authority 2>/dev/null || true)"
  _content_initial="$(_mdm_worktree_content_digest \
    "$_content_retained" retained 2>/dev/null || true)"
  /usr/bin/git -C "$_content_retained" update-index --skip-worktree tracked.txt
  printf 'concealed change\n' > "$_content_retained/tracked.txt"
  _content_status="$(/usr/bin/git -C "$_content_retained" status --porcelain \
    --untracked-files=all -- . \
    ':(exclude).claude-starter-kit-mdm-managed')"
  _content_concealed="$(_mdm_worktree_content_digest \
    "$_content_retained" retained 2>/dev/null || true)"
  if [[ "$_content_expected" =~ ^[0-9a-f]{64}$ \
    && "$_content_initial" == "$_content_expected" \
    && -z "$_content_status" \
    && "$_content_concealed" != "$_content_expected" ]]; then
    pass "mdm-install: content walker は skip-worktree で隠した tracked 改変を拒否"
  else
    fail "mdm-install: target-owned Git index を content authority として採用"
  fi
  /usr/bin/git -C "$_content_retained" update-index --no-skip-worktree tracked.txt
  printf 'original\n' > "$_content_retained/tracked.txt"
  /bin/chmod 0100 "$_content_retained/tracked.txt"
  if ! _mdm_worktree_content_digest "$_content_retained" retained \
    >/dev/null 2>&1; then
    pass "mdm-install: retained content walker は unreadable/noncanonical mode を拒否"
  else
    fail "mdm-install: retained checkout の mode drift を baseline 化"
  fi
  /bin/rm -rf "$_content_tmp"
)
(
  _ancestor_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _ancestor_parent="$_ancestor_tmp/outer"
  _ancestor_tree="$_ancestor_parent/worktree"
  _ancestor_awk="$_ancestor_tmp/inject-walker.awk"
  _ancestor_noise_wrapper="$_ancestor_tmp/python-noise"
  _ancestor_mode_wrapper="$_ancestor_tmp/python-mode"
  /bin/mkdir -p "$_ancestor_tree"
  /bin/chmod 0755 "$_ancestor_parent" "$_ancestor_tree"
  printf 'bound content\n' > "$_ancestor_tree/tracked.txt"
  /bin/chmod 0644 "$_ancestor_tree/tracked.txt"
  printf '%s\n' \
    '{ print }' \
    '$0 == "        root_fd = current" { print mutation; found++ }' \
    'END { if (found != 1) exit 97 }' > "$_ancestor_awk"
  _ancestor_python_cmd="$(command -v python3)"
  _ancestor_python="$($_ancestor_python_cmd -c \
    'import os, sys; print(os.path.realpath(sys.executable))')"
  _ancestor_write_wrapper() {
    local _wrapper="$1" _mutation="$2"
    {
      printf '%s\n' '#!/bin/bash' 'set -o pipefail'
      printf 'REAL_PYTHON=%q\n' "$_ancestor_python"
      printf 'AWK_SCRIPT=%q\n' "$_ancestor_awk"
      printf 'MUTATION=%q\n' "$_mutation"
      printf '%s\n' \
        '/usr/bin/awk -v mutation="$MUTATION" -f "$AWK_SCRIPT" | "$REAL_PYTHON" -I -B -S - "$5" "$6"'
    } > "$_wrapper"
    /bin/chmod 0755 "$_wrapper"
  }
  _ancestor_write_wrapper "$_ancestor_noise_wrapper" \
    '        noise = os.path.join(os.path.dirname(root), ".mdm-ancestor-noise"); os.unlink(noise) if os.path.exists(noise) else os.close(os.open(noise, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))'
  _ancestor_write_wrapper "$_ancestor_mode_wrapper" \
    '        os.chmod(os.path.dirname(root), 0o711)'

  _mdm_system_python() { printf '%s' "$_ancestor_noise_wrapper"; }
  _ancestor_noise_digest="$(_mdm_worktree_content_digest \
    "$_ancestor_tree" authority 2>/dev/null || true)"
  _mdm_system_python() { printf '%s' "$_ancestor_mode_wrapper"; }
  _ancestor_mode_accepted=false
  _mdm_worktree_content_digest "$_ancestor_tree" authority \
    >/dev/null 2>&1 && _ancestor_mode_accepted=true
  _ancestor_mode_after="$(_mdm_mode_normalize \
    "$(_mdm_stat_mode "$_ancestor_parent")")"
  /bin/chmod 0755 "$_ancestor_parent"
  if [[ "$_ancestor_noise_digest" =~ ^[0-9a-f]{64}$ \
    && ! -e "$_ancestor_parent/.mdm-ancestor-noise" \
    && "$_ancestor_mode_after" == 0711 \
    && "$_ancestor_mode_accepted" == false ]]; then
    pass "mdm-install: worktree 外祖先は unrelated mutation を許容し trust identity drift を拒否"
  else
    fail "mdm-install: worktree 外祖先の weak/strong identity 境界が不正"
  fi
  /bin/rm -rf "$_ancestor_tmp"
)

# Exact SemVer tags preserve prerelease meaning.  Commits after a tag encode
# git-describe distance/hash as build metadata, not as a false prerelease.
(
  unset HTTP_PROXY HTTPS_PROXY NO_PROXY
  _version_tmp="$(mktemp -d)"
  _version_repo="$_version_tmp/tagged"
  _version_untagged="$_version_tmp/untagged"
  /usr/bin/git -C "$_version_tmp" init -q tagged
  printf 'one\n' > "$_version_repo/file"
  /usr/bin/git -C "$_version_repo" add file
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$_version_repo" commit -q -m one
  /usr/bin/git -C "$_version_repo" tag v1.2.3-rc.1
  _version_exact_rc="$(_mdm_describe_kit_version _mdm_git "$_version_repo")"
  printf 'two\n' >> "$_version_repo/file"
  /usr/bin/git -C "$_version_repo" add file
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$_version_repo" commit -q -m two
  _version_after_rc="$(_mdm_describe_kit_version _mdm_git "$_version_repo")"
  _version_after_rc_auth="$(_mdm_describe_kit_version _mdm_auth_git "$_version_repo")"
  /usr/bin/git -C "$_version_repo" tag v1.2.3
  _version_exact_stable="$(_mdm_describe_kit_version _mdm_git "$_version_repo")"
  printf 'three\n' >> "$_version_repo/file"
  /usr/bin/git -C "$_version_repo" add file
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$_version_repo" commit -q -m three
  _version_after_stable="$(_mdm_describe_kit_version _mdm_git "$_version_repo")"
  /usr/bin/git -C "$_version_repo" tag 'v1.2.4+vendor'
  _version_exact_build="$(_mdm_describe_kit_version _mdm_git "$_version_repo")"
  printf 'four\n' >> "$_version_repo/file"
  /usr/bin/git -C "$_version_repo" add file
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$_version_repo" commit -q -m four
  _version_after_build="$(_mdm_describe_kit_version _mdm_git "$_version_repo")"

  /usr/bin/git -C "$_version_tmp" init -q untagged
  printf 'untagged\n' > "$_version_untagged/file"
  /usr/bin/git -C "$_version_untagged" add file
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$_version_untagged" commit -q -m untagged
  _version_no_tag="$(_mdm_describe_kit_version _mdm_git "$_version_untagged")"

  if [[ "$_version_exact_rc" == v1.2.3-rc.1 ]] \
    && [[ "$_version_after_rc" =~ ^v1\.2\.3-rc\.1\+1\.g[0-9a-f]+$ ]] \
    && [[ "$_version_after_rc_auth" == "$_version_after_rc" ]] \
    && [[ "$_version_exact_stable" == v1.2.3 ]] \
    && [[ "$_version_after_stable" =~ ^v1\.2\.3\+1\.g[0-9a-f]+$ ]] \
    && [[ "$_version_exact_build" == v1.2.4+vendor ]] \
    && [[ "$_version_after_build" =~ ^v1\.2\.4\+vendor\.1\.g[0-9a-f]+$ ]] \
    && [[ "$_version_no_tag" =~ ^[0-9a-f]+$ ]]; then
    pass "mdm-install: git describe の距離を SemVer build metadata へ正規化"
  else
    fail "mdm-install: kit_version の git describe 正規化が不正"
  fi
  rm -rf "$_version_tmp"
)

# ── JSON エスケープ ───────────────────────────────────────
if out="$(mdm_json_escape 'a"b\c')" && [[ "$out" == 'a\"b\\c' ]]; then
  pass "mdm-install: JSON エスケープ（quote/backslash）"
else
  fail "mdm-install: JSON エスケープ失敗 (got '$out')"
fi

# ── レシート生成 ──────────────────────────────────────────
# NOTE: 以下の MDM_RCPT_* はこのファイルでは直接参照せず mdm_receipt_write
# 側が間接参照するグローバル。shellcheck は静的にそれを追えないため、Task 3
# の install-mdm.sh 自身の終了コード定数と同じ「1行1定数+個別disable」方式で
# 個別に SC2034 を無効化する。
_tmpd="$(mktemp -d)"
# shellcheck disable=SC2034
MDM_RCPT_KIT_VERSION="0.73.0"
# shellcheck disable=SC2034
MDM_RCPT_GIT_REF="abcdef0123456789abcdef0123456789abcdef01"
# shellcheck disable=SC2034
MDM_RCPT_RESOLVED_SHA="abcdef0123456789abcdef0123456789abcdef01"
# shellcheck disable=SC2034
MDM_RCPT_INSTALL_DIR="/Users/jane/.claude-starter-kit"
# shellcheck disable=SC2034
MDM_RCPT_REQUIRED_COMPONENTS='["claude_cli","kit"]'
# shellcheck disable=SC2034
MDM_RCPT_PROFILE="standard"
# shellcheck disable=SC2034
MDM_RCPT_LANGUAGE="ja"
# shellcheck disable=SC2034
MDM_RCPT_MANIFEST_PATH="/Users/jane/.claude/.starter-kit-manifest.json"
# shellcheck disable=SC2034
MDM_RCPT_MANIFEST_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
# shellcheck disable=SC2034
MDM_RCPT_DEPLOYMENT_SHA256="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
# shellcheck disable=SC2034
MDM_RCPT_POLICY_SHA256="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
# shellcheck disable=SC2034
MDM_RCPT_COMPONENT_MANIFEST_PATH="$_tmpd/components-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.json"
# shellcheck disable=SC2034
MDM_RCPT_COMPONENT_MANIFEST_SHA256="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
# shellcheck disable=SC2034
MDM_RCPT_TARGET_USER="jane"
# shellcheck disable=SC2034
MDM_RCPT_TARGET_UID=501
# shellcheck disable=SC2034
MDM_RCPT_TARGET_GENERATED_UID="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
# shellcheck disable=SC2034
MDM_RCPT_PARTIAL='[]'
# shellcheck disable=SC2034
MDM_RCPT_TIMESTAMP="2026-07-16T00:00:00Z"
# shellcheck disable=SC2034
MDM_RCPT_LOG_PATH="/Library/Logs/ClaudeCodeStarterKit/install.log"
_receipt_path="$_tmpd/receipt-jane.json"
MDM_EUID_OVERRIDE=501 mdm_receipt_write "$_receipt_path" "success" "0"

# NOTE: assert_json_field は field を `jq -r "$field"` にそのまま渡すため、
# フィルタ式として先頭ドット (.result 等) が必須。ドット無し ("result") は
# jq のコンパイルエラーになり __JQ_ERROR__ 比較で常に失敗する。
if assert_json_field "$_receipt_path" ".result" "success" "result=success"; then
  pass "mdm-install: レシート result フィールド"
else
  fail "mdm-install: レシート result フィールド不正"
fi
if assert_json_field "$_receipt_path" ".exit_code" "0" "exit_code=0"; then
  pass "mdm-install: レシート exit_code フィールド"
else
  fail "mdm-install: レシート exit_code フィールド不正"
fi
if assert_json_field "$_receipt_path" ".install_dir" "/Users/jane/.claude-starter-kit" "install_dir 記録"; then
  pass "mdm-install: レシート install_dir 記録"
else
  fail "mdm-install: レシート install_dir 未記録"
fi
if assert_json_field "$_receipt_path" ".schema_version" "3" "schema_version=3" \
  && assert_json_field "$_receipt_path" ".language" "ja" "language=ja" \
  && assert_json_field "$_receipt_path" ".manifest_path" "/Users/jane/.claude/.starter-kit-manifest.json" "manifest_path 記録" \
  && assert_json_field "$_receipt_path" ".manifest_sha256" "$MDM_RCPT_MANIFEST_SHA256" "manifest_sha256 記録" \
  && assert_json_field "$_receipt_path" ".deployment_sha256" "$MDM_RCPT_DEPLOYMENT_SHA256" "deployment_sha256 記録" \
  && assert_json_field "$_receipt_path" ".policy_sha256" "$MDM_RCPT_POLICY_SHA256" "policy_sha256 記録" \
  && assert_json_field "$_receipt_path" ".component_manifest_path" "$MDM_RCPT_COMPONENT_MANIFEST_PATH" "component manifest path 記録" \
  && assert_json_field "$_receipt_path" ".component_manifest_sha256" "$MDM_RCPT_COMPONENT_MANIFEST_SHA256" "component manifest sha256 記録" \
  && assert_json_field "$_receipt_path" ".target_uid" "501" "target_uid 記録" \
  && assert_json_field "$_receipt_path" ".target_generated_uid" "$MDM_RCPT_TARGET_GENERATED_UID" "GeneratedUID 記録"; then
  pass "mdm-install: レシート v3 が policy・component・対象 identity 証跡を記録"
else
  fail "mdm-install: レシート v3 の証跡が不正"
fi
# jq でパース可能な妥当 JSON か
if jq -e . "$_receipt_path" >/dev/null 2>&1; then
  pass "mdm-install: レシートは妥当な JSON"
else
  fail "mdm-install: レシートが不正な JSON"
fi

# A successful receipt represents one immutable source authority. Both fields
# must contain the same lowercase full object ID; abbreviated, uppercase, or
# mismatched values are never compliance evidence.
(
  _saved_git_ref="$MDM_RCPT_GIT_REF"
  _saved_resolved_sha="$MDM_RCPT_RESOLVED_SHA"
  for _bad_ref_case in short long uppercase mismatch; do
    MDM_RCPT_GIT_REF="$_saved_git_ref"
    MDM_RCPT_RESOLVED_SHA="$_saved_resolved_sha"
    case "$_bad_ref_case" in
      short) MDM_RCPT_GIT_REF="${_saved_git_ref%?}" ;;
      long) MDM_RCPT_RESOLVED_SHA="${_saved_resolved_sha}0" ;;
      uppercase) MDM_RCPT_GIT_REF="$(printf '%s' "$_saved_git_ref" | /usr/bin/tr '[:lower:]' '[:upper:]')" ;;
      mismatch) MDM_RCPT_RESOLVED_SHA="0123456789abcdef0123456789abcdef01234567" ;;
    esac
    _bad_ref_dir="$_tmpd/bad-ref-${_bad_ref_case}"
    MDM_RCPT_COMPONENT_MANIFEST_PATH="$_bad_ref_dir/components-$MDM_RCPT_TARGET_GENERATED_UID.json"
    _bad_ref_receipt="$_bad_ref_dir/receipt-jane.json"
    _bad_ref_rc=0
    MDM_EUID_OVERRIDE=501 mdm_receipt_write \
      "$_bad_ref_receipt" success 0 >/dev/null 2>&1 || _bad_ref_rc=$?
    if [[ "$_bad_ref_rc" -ne 0 && ! -e "$_bad_ref_receipt" ]]; then
      pass "mdm-install: success receipt は ${_bad_ref_case} source SHA を拒否"
    else
      fail "mdm-install: success receipt が ${_bad_ref_case} source SHA を許可"
    fi
  done
)

# A successful receipt binds one canonical deployment claim. The manifest is
# fixed relative to the managed checkout home, and every digest is lowercase
# SHA-256 rather than merely a non-empty string.
(
  _saved_manifest_path="$MDM_RCPT_MANIFEST_PATH"
  _saved_manifest_hash="$MDM_RCPT_MANIFEST_SHA256"
  _saved_deployment_hash="$MDM_RCPT_DEPLOYMENT_SHA256"
  for _bad_deployment_case in \
    relative-path mismatched-path manifest-short manifest-uppercase \
    deployment-short deployment-uppercase; do
    MDM_RCPT_MANIFEST_PATH="$_saved_manifest_path"
    MDM_RCPT_MANIFEST_SHA256="$_saved_manifest_hash"
    MDM_RCPT_DEPLOYMENT_SHA256="$_saved_deployment_hash"
    case "$_bad_deployment_case" in
      relative-path) MDM_RCPT_MANIFEST_PATH=.claude/.starter-kit-manifest.json ;;
      mismatched-path) MDM_RCPT_MANIFEST_PATH=/Users/jane/.claude/other.json ;;
      manifest-short) MDM_RCPT_MANIFEST_SHA256="${_saved_manifest_hash%?}" ;;
      manifest-uppercase)
        MDM_RCPT_MANIFEST_SHA256="$(printf '%s' "$_saved_manifest_hash" \
          | /usr/bin/tr '[:lower:]' '[:upper:]')" ;;
      deployment-short) MDM_RCPT_DEPLOYMENT_SHA256="${_saved_deployment_hash%?}" ;;
      deployment-uppercase)
        MDM_RCPT_DEPLOYMENT_SHA256="$(printf '%s' "$_saved_deployment_hash" \
          | /usr/bin/tr '[:lower:]' '[:upper:]')" ;;
    esac
    _bad_deployment_dir="$_tmpd/bad-deployment-${_bad_deployment_case}"
    MDM_RCPT_COMPONENT_MANIFEST_PATH="$_bad_deployment_dir/components-$MDM_RCPT_TARGET_GENERATED_UID.json"
    _bad_deployment_receipt="$_bad_deployment_dir/receipt-jane.json"
    _bad_deployment_rc=0
    MDM_EUID_OVERRIDE=501 mdm_receipt_write \
      "$_bad_deployment_receipt" success 0 >/dev/null 2>&1 \
      || _bad_deployment_rc=$?
    if [[ "$_bad_deployment_rc" -ne 0 && ! -e "$_bad_deployment_receipt" ]]; then
      pass "mdm-install: success receipt は ${_bad_deployment_case} deployment claim を拒否"
    else
      fail "mdm-install: success receipt が ${_bad_deployment_case} deployment claim を許可"
    fi
  done
)

# success は component manifest の path と digest が揃うまで成立しない。
(
  _saved_component_hash="$MDM_RCPT_COMPONENT_MANIFEST_SHA256"
  for _missing_component in path hash; do
    _missing_dir="$_tmpd/missing-component-${_missing_component}"
    MDM_RCPT_COMPONENT_MANIFEST_PATH="$_missing_dir/components-$MDM_RCPT_TARGET_GENERATED_UID.json"
    MDM_RCPT_COMPONENT_MANIFEST_SHA256="$_saved_component_hash"
    case "$_missing_component" in
      path) MDM_RCPT_COMPONENT_MANIFEST_PATH="" ;;
      hash) MDM_RCPT_COMPONENT_MANIFEST_SHA256="" ;;
    esac
    _missing_receipt="$_missing_dir/receipt-jane.json"
    _missing_rc=0
    MDM_EUID_OVERRIDE=501 mdm_receipt_write "$_missing_receipt" success 0 \
      >/dev/null 2>&1 || _missing_rc=$?
    if [[ "$_missing_rc" -ne 0 && ! -e "$_missing_receipt" ]]; then
      pass "mdm-install: success receipt は component ${_missing_component} 欠落を拒否"
    else
      fail "mdm-install: success receipt が component ${_missing_component} 欠落を許可"
    fi
  done
)

# ══ R2-High: レシートは umask に依存せず 600/755 で作成され、特殊 inode を残さない ══
(
  # MDM agent の umask が 000 でもレシート 600 / ディレクトリ 755。
  umask 000
  _u0dir="$_tmpd/umask0/sub"
  MDM_RCPT_COMPONENT_MANIFEST_PATH="$_u0dir/components-$MDM_RCPT_TARGET_GENERATED_UID.json"
  MDM_EUID_OVERRIDE=501 mdm_receipt_write "$_u0dir/receipt-jane.json" success 0
  _fmode="$(test_stat_mode "$_u0dir/receipt-jane.json")"
  _dmode="$(test_stat_mode "$_u0dir")"
  [[ "$_fmode" == "600" ]] \
    && pass "mdm-install: umask 000 でもレシートは 600" \
    || fail "mdm-install: umask 000 でレシートが ${_fmode}（書換可能な contract 違反）"
  [[ "$_dmode" == "755" ]] \
    && pass "mdm-install: umask 000 でもレシート dir は 755" \
    || fail "mdm-install: umask 000 でレシート dir が $_dmode"
)
(
  # 既存レシートが hardlink 化されていても、その inode へ上書きせず、同一
  # directory の fresh inode を atomic rename して nlink=1 へ自己修復する。
  _hldir="$_tmpd/rcpt-hardlink"
  mkdir -p "$_hldir"
  _hlreceipt="$_hldir/receipt-jane.json"
  _hlalias="$_hldir/receipt-alias"
  printf 'prior-receipt\n' > "$_hlreceipt"
  chmod 600 "$_hlreceipt"
  ln "$_hlreceipt" "$_hlalias"
  MDM_RCPT_COMPONENT_MANIFEST_PATH="$_hldir/components-$MDM_RCPT_TARGET_GENERATED_UID.json"
  _hl_before_inode="$(_mdm_stat_inode "$_hlreceipt")"
  _hl_rc=0
  MDM_EUID_OVERRIDE=501 mdm_receipt_write "$_hlreceipt" success 0 \
    >/dev/null 2>&1 || _hl_rc=$?
  _hl_meta="$(_mdm_stat_managed_metadata "$_hlreceipt" 2>/dev/null || true)"
  _hl_rest="${_hl_meta#*:}"
  _hl_links="${_hl_rest%%:*}"
  _hl_mode="$(_mdm_mode_normalize "${_hl_rest#*:}" 2>/dev/null || true)"
  if [[ "$_hl_rc" -eq 0 && "$_hl_links" == 1 && "$_hl_mode" == 0600 ]] \
    && [[ "$(_mdm_stat_inode "$_hlreceipt")" != "$_hl_before_inode" ]] \
    && [[ "$(_mdm_stat_inode "$_hlalias")" == "$_hl_before_inode" ]] \
    && [[ "$(cat "$_hlalias")" == prior-receipt ]] \
    && jq -e '.schema_version == 3 and .result == "success"' \
      "$_hlreceipt" >/dev/null \
    && [[ "$(_mdm_stat_uid "$_hlreceipt")" == "$(/usr/bin/id -u)" ]] \
    && ! _mdm_has_extended_acl "$_hlreceipt"; then
    pass "mdm-install: hardlinked receipt を fresh inode・nlink 1・mode 600・test-owner・ACLなしへ回復"
  else
    fail "mdm-install: hardlinked receipt の atomic fresh-inode 回復契約が不正"
  fi
)
(
  # レシートパスに先置きされた symlink を辿らない（標的ファイル無傷 + 実体化）
  _sldir="$_tmpd/rcpt-symlink"
  mkdir -p "$_sldir"
  printf 'victim\n' > "$_sldir/victim-file"
  ln -s "$_sldir/victim-file" "$_sldir/receipt-jane.json"
  MDM_RCPT_COMPONENT_MANIFEST_PATH="$_sldir/components-$MDM_RCPT_TARGET_GENERATED_UID.json"
  MDM_EUID_OVERRIDE=501 mdm_receipt_write "$_sldir/receipt-jane.json" success 0
  if [[ ! -L "$_sldir/receipt-jane.json" && -f "$_sldir/receipt-jane.json" ]] \
     && [[ "$(cat "$_sldir/victim-file")" == "victim" ]]; then
    pass "mdm-install: レシート書込は symlink を辿らない（標的無傷・実体化）"
  else
    fail "mdm-install: レシート書込が symlink を辿る/実体化しない"
  fi
)
rm -rf "$_tmpd"

# ── JSON エスケープ: 制御文字（Medium: 無検証環境値の改行等で JSON が壊れない）──
(
  out="$(mdm_json_escape "$(printf 'a\nb\tc')")"
  if [[ "$out" == 'a\nb\tc' ]]; then
    pass "mdm-install: JSON エスケープが改行/タブを \\n \\t に変換"
  else
    fail "mdm-install: 制御文字のエスケープが不正 (got '$out')"
  fi
)

# ── 終了コード契約: CLT 不足=10 / Homebrew 失敗=11 を区別 ──
(
  export MDM_CLT_PRESENT_OVERRIDE=0 KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=false
  _rc=0
  _mdm_bootstrap_prereqs jane >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_PREREQ" "$_rc" "CLT 不足は exit 10" \
    && pass "mdm-install: CLT 不足を exit 10（前提不足）で返す" \
    || fail "mdm-install: CLT 不足の終了コードが不正 (got $_rc)"
)
(
  export MDM_CLT_PRESENT_OVERRIDE=1 MDM_BREW_PRESENT_OVERRIDE=0
  export MDM_BREW_RELEASES_JSON_OVERRIDE=/nonexistent-brew-json
  _rc=0
  _mdm_bootstrap_prereqs jane >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_BREW" "$_rc" "brew 失敗は exit 11" \
    && pass "mdm-install: Homebrew 失敗を exit 11 で返す" \
    || fail "mdm-install: Homebrew 失敗の終了コードが不正 (got $_rc)"
)

# ── 設定・ユーザー解決失敗時の best-effort _unresolved レシート ──
(
  _tmpu="$(mktemp -d)"
  export MDM_UNRESOLVED_RCPT_DIR_OVERRIDE="$_tmpu"
  # shellcheck disable=SC2034
  MDM_RCPT_TARGET_USER=""
  # shellcheck disable=SC2034
  MDM_RCPT_TARGET_UID=0
  MDM_RCPT_TARGET_GENERATED_UID=""
  _rc=0
  ( MDM_EUID_OVERRIDE="$_MDM_TEST_TARGET_UID" MDM_LOG_FILE="" \
      _mdm_fail_unresolved 50 ) >/dev/null 2>&1 || _rc=$?
  assert_exit_code 50 "$_rc" "_mdm_fail_unresolved は指定コードで exit" \
    && pass "mdm-install: _mdm_fail_unresolved が指定コードで終了" \
    || fail "mdm-install: _mdm_fail_unresolved の exit code 不一致 (got $_rc)"
  if jq -e '.result == "failure" and .target_user == ""
      and .target_uid == 0 and .target_generated_uid == ""' \
      "$_tmpu/receipt-_unresolved.json" >/dev/null 2>&1; then
    pass "mdm-install: _unresolved レシートが best-effort で書かれる"
  else
    fail "mdm-install: _unresolved レシートが生成されない"
  fi
  rm -rf "$_tmpu"
)

# ── 成功時は trusted receipt の書込成功までを postcondition とする ──
(
  _finish_rc=0
  (
    mdm_receipt_prepare() { return 1; }
    mdm_receipt_write() { return 0; }
    MDM_LOG_FILE=""
    MDM_LOG_FD_OPEN=0
    _mdm_finish jane /tmp/mdm-finish-home success "$MDM_EXIT_OK"
  ) >/dev/null 2>&1 || _finish_rc=$?
  assert_exit_code "$MDM_EXIT_SETUP" "$_finish_rc" "success receipt 書込失敗は exit 30" \
    && pass "mdm-install: success receipt 書込失敗を exit 30 に変換" \
    || fail "mdm-install: success receipt 書込失敗の終了コードが不正 (got $_finish_rc)"
)

# The success receipt rename is the commit point.  Post-commit cleanup errors
# remain exit 0 and must never call rollback; publication failure rolls back
# before a failure receipt is attempted.
(
  _finish_tmp="$(mktemp -d)"
  _finish_order="$_finish_tmp/success-order"
  _finish_rc=0
  (
    mdm_receipt_prepare() {
      printf 'prepare\n' >> "$_finish_order"
      return 0
    }
    _mdm_receipt_prepared_ready() { return 0; }
    _mdm_transaction_ready_to_commit() { return 0; }
    _mdm_receipt_publish_prepared() {
      printf 'publish\n' >> "$_finish_order"
      _MDM_RECEIPT_PUBLISHED=1
      return 0
    }
    _mdm_transaction_commit() {
      printf 'commit\n' >> "$_finish_order"
      _MDM_TRANSACTION_STATE=committed
      return 1
    }
    _mdm_transaction_abort() {
      printf 'abort\n' >> "$_finish_order"
      return 0
    }
    _MDM_TRANSACTION_STATE=active
    MDM_LOG_FILE=""; MDM_LOG_FD_OPEN=0
    _mdm_finish jane /tmp/mdm-finish-home success "$MDM_EXIT_OK"
  ) >/dev/null 2>&1 || _finish_rc=$?
  if [[ "$_finish_rc" -eq 0 \
    && "$(cat "$_finish_order")" == $'prepare\npublish\ncommit' ]]; then
    pass "mdm-install: success receipt publish 後は commit cleanup failure でも rollback しない"
  else
    fail "mdm-install: success receipt/commit の不可逆順序が不正"
  fi

  _finish_order="$_finish_tmp/failure-order"
  _finish_rc=0
  (
    mdm_receipt_prepare() {
      printf 'prepare\n' >> "$_finish_order"
      return 0
    }
    _mdm_receipt_prepared_ready() { return 0; }
    _mdm_transaction_ready_to_commit() { return 0; }
    _mdm_receipt_publish_prepared() {
      printf 'publish-attempt\n' >> "$_finish_order"
      _MDM_RECEIPT_PUBLISHED=0
      return 1
    }
    mdm_receipt_write() {
      printf 'failure-receipt\n' >> "$_finish_order"
      return 0
    }
    _mdm_transaction_abort() {
      [[ "${_MDM_TRANSACTION_STATE:-idle}" == active ]] || return 0
      printf 'abort\n' >> "$_finish_order"
      _MDM_TRANSACTION_STATE=aborted
      return 0
    }
    _mdm_transaction_commit() {
      printf 'commit\n' >> "$_finish_order"
      return 0
    }
    _MDM_TRANSACTION_STATE=active
    MDM_LOG_FILE=""; MDM_LOG_FD_OPEN=0
    _mdm_finish jane /tmp/mdm-finish-home success "$MDM_EXIT_OK"
  ) >/dev/null 2>&1 || _finish_rc=$?
  if [[ "$_finish_rc" -eq "$MDM_EXIT_SETUP" \
    && "$(cat "$_finish_order")" \
      == $'prepare\npublish-attempt\nabort\nfailure-receipt' ]]; then
    pass "mdm-install: receipt publish failure は rollback 後に failure receipt"
  else
    fail "mdm-install: receipt failure/rollback の順序が不正"
  fi
  rm -rf "$_finish_tmp"
)

# Exercise the real receipt writer and outer transaction together.  Invalid
# raw arrays must never become success evidence, receipt validation remains
# signal-interruptible, and a post-commit diagnostic write cannot change rc 0.
(
  _finish_real_fixture() { # <root> <malformed-required|malformed-partial|signal|stderr>
    local _root="$1" _mode="$2"
    PROJECT_DIR="$PROJECT_DIR" MDM_FINISH_ROOT="$_root" \
      MDM_FINISH_MODE="$_mode" \
      MDM_FINISH_USER="$_MDM_TEST_TARGET_USER" \
      MDM_FINISH_UID="$_MDM_TEST_TARGET_UID" \
      MDM_FINISH_GID="$_MDM_TEST_TARGET_GID" \
      MDM_FINISH_GUID=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE \
      "$BASH" --noprofile --norc -c '
        MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"
        _root="$MDM_FINISH_ROOT"
        _home="$_root/home"
        _receipts="$_root/receipts"
        _user="$MDM_FINISH_USER"
        _uid="$MDM_FINISH_UID"
        _gid="$MDM_FINISH_GID"
        _guid="$MDM_FINISH_GUID"
        /bin/chmod 0755 "$_root" || exit 91
        /bin/mkdir -m 700 "$_home" || exit 91
        if [[ "$(/usr/bin/id -u)" -eq 0 ]]; then
          chown "$_uid:$_gid" "$_home" || exit 91
        fi
        export MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_receipts"
        export MDM_CONFIG_SKIP_OWNER_CHECK=1
        _mdm_exec_as_user() {
          local _drop_uid="$1" _drop_user="$2" _drop_home="$3"
          shift 3
          if [[ "$(/usr/bin/id -u)" -eq 0 ]]; then
            /usr/bin/sudo -n -u "#$_drop_uid" -H /usr/bin/env -i \
              "HOME=$_drop_home" "USER=$_drop_user" "LOGNAME=$_drop_user" \
              PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C "$@"
          else
            "$@"
          fi
        }
        _MDM_GIT_DROP_UID="$_uid"
        _MDM_GIT_DROP_USER="$_user"
        _MDM_GIT_DROP_HOME="$_home"
        _MDM_TRANSACTION_STATE=idle
        _MDM_CLAUDE_TRANSACTION_STATE=idle
        _MDM_PERSISTENT_TRANSACTION_STATE=idle
        _mdm_transaction_begin "$_user" "$_home" "$_uid" "$_guid" || exit 92
        # This receipt/outer-transaction fixture intentionally has no managed
        # leaves outside the Claude and persistent trees.
        _MDM_EXTERNAL_TRANSACTION_STATE=none
        _mdm_transaction_prepare_claude "$_home" "$_uid" || exit 93
        printf "transaction-candidate\n" \
          > "$_home/.claude/transaction-payload" || exit 93
        /bin/chmod 600 "$_home/.claude/transaction-payload" || exit 93

        MDM_RCPT_KIT_VERSION=0.73.0
        MDM_RCPT_GIT_REF=abcdef0123456789abcdef0123456789abcdef01
        MDM_RCPT_RESOLVED_SHA="$MDM_RCPT_GIT_REF"
        MDM_RCPT_INSTALL_DIR="$_home/.claude-starter-kit"
        MDM_RCPT_REQUIRED_COMPONENTS='"'"'["kit"]'"'"'
        MDM_RCPT_PROFILE=minimal
        MDM_RCPT_LANGUAGE=en
        MDM_RCPT_MANIFEST_PATH="$_home/.claude/.starter-kit-manifest.json"
        MDM_RCPT_MANIFEST_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        MDM_RCPT_DEPLOYMENT_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        MDM_RCPT_POLICY_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
        MDM_RCPT_COMPONENT_MANIFEST_PATH="$_receipts/components-$_guid.json"
        MDM_RCPT_COMPONENT_MANIFEST_SHA256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
        MDM_RCPT_TARGET_USER="$_user"
        MDM_RCPT_TARGET_UID="$_uid"
        MDM_RCPT_TARGET_GENERATED_UID="$_guid"
        MDM_RCPT_PARTIAL='"'"'[]'"'"'
        MDM_LOG_FILE=""
        MDM_LOG_FD_OPEN=0

        case "$MDM_FINISH_MODE" in
          malformed-required)
            MDM_RCPT_REQUIRED_COMPONENTS='"'"'["kit","kit"]'"'"' ;;
          malformed-partial)
            MDM_RCPT_PARTIAL='"'"'["receipt"]'"'"' ;;
          signal)
            _mdm_generated_receipt_is_exact() {
              /bin/kill -TERM "$$"
              return 1
            } ;;
          stderr)
            _install="$_home/.claude-starter-kit"
            /bin/mkdir -m 700 "$_install" || exit 94
            printf "candidate\n" > "$_install/state" || exit 94
            /bin/chmod 600 "$_install/state" || exit 94
            if [[ "$(/usr/bin/id -u)" -eq 0 ]]; then
              chown -R "$_uid:$_gid" "$_install" || exit 94
            fi
            _MDM_PERSISTENT_INSTALL_DIR="$_install"
            _MDM_PERSISTENT_STAGE="$_home/.claude-starter-kit.mdm-stage.fixture"
            _MDM_PERSISTENT_TARGET_UID="$_uid"
            _MDM_PERSISTENT_PARENT_IDENTITY="$(_mdm_persistent_dir_identity "$_home")"
            _MDM_PERSISTENT_CANDIDATE_IDENTITY="$(_mdm_persistent_dir_identity "$_install")"
            _MDM_PERSISTENT_CANDIDATE_DIGEST="$(_mdm_artifact_digest tree "$_install" "$_uid")"
            _MDM_PERSISTENT_PREVIOUS_IDENTITY=""
            _MDM_PERSISTENT_PREVIOUS_DIGEST=""
            _MDM_PERSISTENT_TRANSACTION_STATE=created
            # Managed-parent behavior has dedicated real journal tests below.
            # Keep this fixture focused on the post-commit diagnostic boundary
            # while the rest of _mdm_transaction_ready_to_commit stays real.
            _MDM_PARENT_MODE_STATE=applied
            _mdm_managed_parent_journal_trusted() { return 0; }
            _mdm_managed_parent_modes_final() { return 0; } ;;
          *) exit 95 ;;
        esac
        if [[ "$MDM_FINISH_MODE" == stderr ]]; then
          MDM_EUID_OVERRIDE="$_uid" \
            _mdm_finish "$_user" "$_home" success 0 2>&-
        else
          MDM_EUID_OVERRIDE="$_uid" \
            _mdm_finish "$_user" "$_home" success 0
        fi
      '
  }

  _finish_real_tmp="$(_mdm_test_target_tmpdir)"
  _finish_receipt_name="receipt-${_MDM_TEST_TARGET_USER}.json"
  _finish_invalid_ok=true
  for _finish_invalid_mode in malformed-required malformed-partial; do
    _finish_case="$_finish_real_tmp/$_finish_invalid_mode"
    /bin/mkdir "$_finish_case"
    _finish_case_rc=0
    _finish_real_fixture "$_finish_case" "$_finish_invalid_mode" \
      >/dev/null 2>&1 || _finish_case_rc=$?
    if [[ "$_finish_case_rc" -ne "$MDM_EXIT_SETUP" ]] \
      || ! jq -e '.result == "failure" and .exit_code == 30
        and .required_components == ["kit"] and .partial == ["receipt"]' \
        "$_finish_case/receipts/$_finish_receipt_name" >/dev/null 2>&1 \
      || [[ -e "$_finish_case/home/.claude" \
        || -L "$_finish_case/home/.claude" ]] \
      || /usr/bin/find "$_finish_case/receipts" -maxdepth 1 \
        -name '.receipt-tmp.*' -print -quit | /usr/bin/grep -q .; then
      _finish_invalid_ok=false
    fi
  done
  [[ "$_finish_invalid_ok" == true ]] \
    && pass "mdm-install: malformed receipt arrays は success 公開前に rollback と failure 化" \
    || fail "mdm-install: malformed receipt arrays が success evidence/transaction を確定"

  _finish_signal_case="$_finish_real_tmp/signal"
  /bin/mkdir "$_finish_signal_case"
  _finish_signal_rc=0
  _finish_real_fixture "$_finish_signal_case" signal \
    >/dev/null 2>&1 || _finish_signal_rc=$?
  _finish_signal_failed="$(/usr/bin/find "$_finish_signal_case/home" \
    -maxdepth 1 -type d -name '.claude.mdm-failed.*' -print -quit)"
  if [[ "$_finish_signal_rc" -eq 143 \
    && ! -e "$_finish_signal_case/receipts/$_finish_receipt_name" \
    && ! -L "$_finish_signal_case/receipts/$_finish_receipt_name" \
    && ! -e "$_finish_signal_case/home/.claude" \
    && ! -L "$_finish_signal_case/home/.claude" \
    && -n "$_finish_signal_failed" \
    && "$(cat "$_finish_signal_failed/transaction-payload")" \
      == transaction-candidate ]] \
    && ! /usr/bin/find "$_finish_signal_case/receipts" -maxdepth 1 \
      -name '.receipt-tmp.*' -print -quit | /usr/bin/grep -q .; then
    pass "mdm-install: receipt validation 中 TERM は143・rollback・success/tempなし"
  else
    fail "mdm-install: receipt validation 中 TERM が mask/commit または residue を残す"
  fi

  _finish_stderr_case="$_finish_real_tmp/stderr"
  /bin/mkdir "$_finish_stderr_case"
  _finish_stderr_rc=0
  _finish_real_fixture "$_finish_stderr_case" stderr \
    >/dev/null 2>&1 || _finish_stderr_rc=$?
  if [[ "$_finish_stderr_rc" -eq 0 \
    && -d "$_finish_stderr_case/home/.claude" \
    && -d "$_finish_stderr_case/home/.claude-starter-kit" \
    && ! -e "$_finish_stderr_case/home/.claude/.claude-starter-kit-mdm-transaction" ]] \
    && jq -e '.result == "success" and .exit_code == 0' \
      "$_finish_stderr_case/receipts/$_finish_receipt_name" >/dev/null 2>&1; then
    pass "mdm-install: commit 後 stderr failure は成功 receipt の exit 0 を保持"
  else
    fail "mdm-install: commit 後 diagnostic failure が成功 status を上書き"
  fi
  /bin/rm -rf "$_finish_real_tmp"
)

# ── root launcher の data-only config parser は曖昧な入力を拒否 ──
(
  _root_cfg_tmp="$(mktemp -d)"
  _root_cfg="$_root_cfg_tmp/mdm-config.conf"
  chmod 700 "$_root_cfg_tmp"
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  for _root_case in unknown malformed duplicate invalid-editor invalid-policy; do
    case "$_root_case" in
      unknown)
        printf 'UNKNOWN_ROOT_KEY=true\n' > "$_root_cfg"
        _root_label="unknown key" ;;
      malformed)
        printf 'PROFILE\n' > "$_root_cfg"
        _root_label="malformed line" ;;
      duplicate)
        printf 'PROFILE=standard\nPROFILE=full\n' > "$_root_cfg"
        _root_label="duplicate key" ;;
      invalid-editor)
        printf 'EDITOR_CHOICE=arbitrary\n' > "$_root_cfg"
        _root_label="invalid editor enum" ;;
      invalid-policy)
        printf 'KIT_MDM_EXPECTED_POLICY_SHA256=ABC123\n' > "$_root_cfg"
        _root_label="invalid expected policy SHA-256" ;;
    esac
    chmod 600 "$_root_cfg"
    _root_rc=0
    _mdm_root_config_apply "$_root_cfg" >/dev/null 2>&1 || _root_rc=$?
    if [[ "$_root_rc" -eq "$MDM_EXIT_CONFIG" ]]; then
      pass "mdm-install: root config parser が $_root_label を exit 50 で拒否"
    else
      fail "mdm-install: root config parser が $_root_label を許可 (got $_root_rc)"
    fi
  done
  rm -rf "$_root_cfg_tmp"
)

# MDM cannot delegate lifecycle control back to user-scope updaters/plugins.
(
  _root_fixed_rc=0
  for _root_fixed_key in ENABLE_AUTO_UPDATE ENABLE_WEB_CONTENT_UPDATE ENABLE_CODEX_PLUGIN; do
    if _mdm_root_value "$_root_fixed_key" true >/dev/null 2>&1 \
      || [[ "$(_mdm_root_value "$_root_fixed_key" false)" != false ]]; then
      _root_fixed_rc=1
    fi
  done
  if [[ "$_root_fixed_rc" -eq 0 ]]; then
    pass "mdm-install: 自己更新・user plugin の true 指定を拒否し false のみ許可"
  else
    fail "mdm-install: MDM 固定 false コンポーネントの parser 契約が不正"
  fi
)

# ── root parser の省略値は fresh/update とも明示 export ──
(
  _defaults_tmp="$(mktemp -d)"
  _defaults_home="$_defaults_tmp/home"
  mkdir -p "$_defaults_home/.claude"
  unset PROFILE LANGUAGE KIT_MDM_DRY_RUN
  _mdm_root_config_apply "$_defaults_tmp/no-config" >/dev/null 2>&1 \
    || fail "mdm-install: 省略設定の root parser が失敗"
  if [[ "$PROFILE" == standard && "$LANGUAGE" == en ]] \
    && [[ "$(/usr/bin/printenv PROFILE)" == standard ]] \
    && [[ "$(/usr/bin/printenv LANGUAGE)" == en ]]; then
    pass "mdm-install: root parser は省略 PROFILE/LANGUAGE を standard/en で export"
  else
    fail "mdm-install: root parser の省略 PROFILE/LANGUAGE が不正"
  fi

  for _defaults_state in fresh update; do
    rm -f "$_defaults_home/.claude/.starter-kit-manifest.json"
    [[ "$_defaults_state" == update ]] && : > "$_defaults_home/.claude/.starter-kit-manifest.json"
    mdm_build_setup_argv "$_defaults_home"
    mdm_build_drop_argv 501 jane "$_defaults_home" /bin/bash /auth/setup.sh "${MDM_SETUP_ARGV[@]}"
    _defaults_profile=0; _defaults_language=0; _defaults_update=0
    for _defaults_arg in "${MDM_DROP_ARGV[@]}"; do
      [[ "$_defaults_arg" == PROFILE=standard ]] && _defaults_profile=1
      [[ "$_defaults_arg" == LANGUAGE=en ]] && _defaults_language=1
      [[ "$_defaults_arg" == --update ]] && _defaults_update=1
    done
    if [[ "$_defaults_profile" -eq 1 && "$_defaults_language" -eq 1 \
      && "$_defaults_update" -eq 0 ]]; then
      pass "mdm-install: $_defaults_state setup に既定 standard/en を明示伝搬"
    else
      fail "mdm-install: $_defaults_state setup の既定値/update argv が不正"
    fi
  done
  rm -rf "$_defaults_tmp"
)

# proxy は credential/query/空 authority を拒否し、検証済み値だけ auth Git へ渡す。
(
  for _proxy_bad in \
    'http://user:pass@proxy.example:8080' \
    'https://proxy.example:8080?x=1' \
    'http://' \
    'http://:8080' \
    'http://bad proxy:8080'; do
    if _mdm_root_value HTTP_PROXY "$_proxy_bad" >/dev/null 2>&1; then
      fail "mdm-install: 危険な proxy URL を許可 ($_proxy_bad)"
    else
      pass "mdm-install: 危険な proxy URL を拒否"
    fi
  done
  export HTTP_PROXY=http://proxy.example:8080 HTTPS_PROXY=https://proxy.example:8443
  export NO_PROXY=localhost,.example.invalid
  _proxy_env="$(_mdm_auth_git -c 'alias.mdm-env=!/usr/bin/env' mdm-env 2>/dev/null || true)"
  if printf '%s\n' "$_proxy_env" | grep -qx "HTTP_PROXY=$HTTP_PROXY" \
    && printf '%s\n' "$_proxy_env" | grep -qx "HTTPS_PROXY=$HTTPS_PROXY" \
    && printf '%s\n' "$_proxy_env" | grep -qx "NO_PROXY=$NO_PROXY"; then
    pass "mdm-install: 検証済み proxy だけを isolated auth Git へ伝搬"
  else
    fail "mdm-install: auth Git への proxy 伝搬が不正"
  fi
)

# ── receipt は EUID に関係なく system/root 契約のみ ─────
(
  unset MDM_SYSTEM_RCPT_DIR_OVERRIDE
  MDM_EUID_OVERRIDE=0; _root_receipt="$(_mdm_receipt_dir_for /tmp/fake-home)"
  MDM_EUID_OVERRIDE=501; _user_receipt="$(_mdm_receipt_dir_for /tmp/fake-home)"
  if [[ "$_root_receipt" == "/Library/Application Support/ClaudeCodeStarterKit" \
    && "$_user_receipt" == "$_root_receipt" ]]; then
    pass "mdm-install: 成功/失敗 receipt は system root パスだけを使用"
  else
    fail "mdm-install: user-owned receipt パスが残存"
  fi
)

# ── non-root 通常実行は副作用前に exit 21、dry-run のみ別契約 ──
(
  _context_tmp="$(mktemp -d)"
  _context_home="$_context_tmp/home"; mkdir -p "$_context_home"
  _context_uid="$_MDM_TEST_TARGET_UID"
  printf 'unchanged\n' > "$_context_home/sentinel"
  unset KIT_MDM_DRY_RUN KIT_MDM_INSTALL_DIR
  _context_rc=0
  _mdm_run_user_phase "$_context_uid" "$_MDM_TEST_TARGET_USER" "$_context_home" \
    >/dev/null 2>&1 || _context_rc=$?
  if [[ "$_context_rc" -eq "$MDM_EXIT_CONTEXT" ]] \
    && [[ "$(cat "$_context_home/sentinel")" == unchanged ]] \
    && [[ ! -e "$_context_home/.claude-starter-kit" ]]; then
    pass "mdm-install: non-root remediation は副作用前に exit 21"
  else
    fail "mdm-install: non-root remediation の root-only 契約が不正 (rc=$_context_rc)"
  fi
  rm -rf "$_context_tmp"
)

# ── 対象ユーザー解決（モック）────────────────────────────
# ── launcher は sticky bit と fd snapshot を platform 正しく扱う ──
if [[ "$_MDM_LAUNCHER_SOURCE_CONTEXT" == 1 ]] \
  && /usr/bin/awk '
    /^_MDM_LAUNCHER_SOURCE_CONTEXT=0$/ { binding = NR }
    /^_mdm_launcher_snapshot\(\)/ { snapshot = NR }
    /_MDM_LAUNCHER_SOURCE_CONTEXT" == 1/ { gate = NR }
    END { exit(binding && gate && snapshot && binding < snapshot && gate > binding ? 0 : 1) }
  ' "$PROJECT_DIR/mdm/install-mdm.sh"; then
  pass "mdm-install: test tmp overrideはsource済みlauncherだけに限定"
else
  fail "mdm-install: direct launcherがpre-clean test tmpを信頼し得る"
fi

(
  _launcher_tmp="$(mktemp -d)"
  _launcher_sticky="$_launcher_tmp/sticky"
  mkdir -p "$_launcher_sticky/root-entry"
  printf '#!/bin/bash\nexit 0\n' > "$_launcher_sticky/root-entry/install-mdm.sh"
  chmod 755 "$_launcher_sticky/root-entry/install-mdm.sh"
  _mdm_launcher_stat_uid() { printf '0'; }
  _mdm_launcher_stat_mode() {
    if [[ "$1" == "$_launcher_sticky" ]]; then printf '1777'; else printf '755'; fi
  }
  _mdm_launcher_acl_safe() { return 0; }
  if _mdm_launcher_path_trusted "$_launcher_sticky/root-entry/install-mdm.sh"; then
    pass "mdm-install: root-owned entry は physical sticky parent 配下で信頼可能"
  else
    fail "mdm-install: sticky parent の root-owned entry を誤拒否"
  fi
  rm -rf "$_launcher_tmp"
)
(
  _launcher_tmp="$(mktemp -d)"
  _launcher_script="$_launcher_tmp/install-mdm.sh"
  printf '#!/bin/bash\nexit 0\n' > "$_launcher_script"
  chmod 755 "$_launcher_script"
  _mdm_launcher_stat_uid() {
    [[ "$1" == */install-mdm.sh ]] && printf '501' || printf '0'
  }
  _mdm_launcher_stat_mode() { printf '755'; }
  _mdm_launcher_acl_safe() { return 0; }
  if _mdm_launcher_path_trusted "$_launcher_script"; then
    fail "mdm-install: non-root owner の launcher を許可"
  else
    pass "mdm-install: non-root owner の launcher を拒否"
  fi
  rm -rf "$_launcher_tmp"
)
(
  _launcher_tmp="$(mktemp -d)"
  _launcher_script="$_launcher_tmp/install-mdm.sh"
  printf '#!/bin/bash\nexit 0\n' > "$_launcher_script"
  chmod 755 "$_launcher_script"
  _mdm_launcher_stat_uid() { printf '0'; }
  _mdm_launcher_stat_mode() {
    [[ "$1" == */install-mdm.sh ]] && printf '775' || printf '755'
  }
  _mdm_launcher_acl_safe() { return 0; }
  if _mdm_launcher_path_trusted "$_launcher_script"; then
    fail "mdm-install: group-writable launcher を許可"
  else
    pass "mdm-install: group-writable launcher を拒否"
  fi
  rm -rf "$_launcher_tmp"
)
(
  _launcher_tmp="$(mktemp -d)"
  _launcher_script="$_launcher_tmp/install-mdm.sh"
  _launcher_link="$_launcher_tmp/install-link.sh"
  printf '#!/bin/bash\nexit 0\n' > "$_launcher_script"
  chmod 755 "$_launcher_script"
  ln -s "$_launcher_script" "$_launcher_link"
  _mdm_launcher_stat_uid() { printf '0'; }
  _mdm_launcher_stat_mode() { printf '755'; }
  _mdm_launcher_acl_safe() { return 0; }
  if _mdm_launcher_path_trusted "$_launcher_link"; then
    fail "mdm-install: symlink launcher を許可"
  else
    pass "mdm-install: symlink launcher を拒否"
  fi
  rm -rf "$_launcher_tmp"
)
(
  _launcher_tmp="$(mktemp -d)"
  _launcher_script="$_launcher_tmp/install-mdm.sh"
  printf '#!/bin/bash\nexit 0\n' > "$_launcher_script"
  chmod 755 "$_launcher_script"
  _mdm_launcher_stat_uid() { printf '0'; }
  _mdm_launcher_stat_mode() { printf '755'; }
  _mdm_launcher_acl_safe() {
    [[ "$1" != */install-mdm.sh ]]
  }
  if _mdm_launcher_path_trusted "$_launcher_script"; then
    fail "mdm-install: extended ACL launcher を許可"
  else
    pass "mdm-install: extended ACL launcher を拒否"
  fi
  rm -rf "$_launcher_tmp"
)
(
  _launcher_tmp="$(mktemp -d)"
  _launcher_acl_xattr="$_launcher_tmp/acl-xattr"
  : > "$_launcher_acl_xattr"
  if _mdm_is_darwin \
    && /usr/bin/xattr -w com.cloudnative.mdm-test 1 \
      "$_launcher_acl_xattr" 2>/dev/null \
    && /bin/chmod +a 'everyone allow write' \
      "$_launcher_acl_xattr" 2>/dev/null; then
    _launcher_acl_listing="$(LC_ALL=C /bin/ls -lde \
      "$_launcher_acl_xattr")"
    _launcher_acl_perms="${_launcher_acl_listing%%[[:space:]]*}"
    if [[ "$_launcher_acl_perms" != *@ ]]; then
      skip "mdm-install: xattr 併存 ACL の continuation を拒否" \
        "ls permission token did not retain @"
    elif ! _mdm_launcher_acl_safe "$_launcher_acl_xattr" \
      && _mdm_has_extended_acl "$_launcher_acl_xattr"; then
      pass "mdm-install: xattr 併存 ACL の continuation を拒否"
    else
      fail "mdm-install: xattr 併存 ACL を launcher/postcondition が許可"
    fi
    /bin/chmod -N "$_launcher_acl_xattr" 2>/dev/null || true
    /usr/bin/xattr -d com.cloudnative.mdm-test \
      "$_launcher_acl_xattr" 2>/dev/null || true
  else
    skip "mdm-install: xattr 併存 ACL の continuation を拒否" \
      "ACL+xattr fixture unavailable on this platform"
  fi
  rm -rf "$_launcher_tmp"
)
(
  _launcher_sticky_base=/tmp
  _mdm_is_darwin && _launcher_sticky_base=/private/tmp
  _launcher_mode="$(_mdm_launcher_stat_mode "$_launcher_sticky_base")"
  if [[ "$_launcher_mode" == 1777 ]] \
    && _mdm_launcher_tmp_base_trusted "$_launcher_sticky_base"; then
    pass "mdm-install: launcher は root-owned sticky tmp chain を信頼"
  else
    fail "mdm-install: launcher tmp chain 契約が不正 (got $_launcher_mode)"
  fi
)
(
  _launcher_sticky_base=/tmp
  _mdm_is_darwin && _launcher_sticky_base=/private/tmp
  _launcher_unsafe_marker="$(mktemp -d)/mktemp-called"
  _mdm_launcher_stat_uid() { printf '0'; }
  _mdm_launcher_stat_mode() {
    if [[ "$1" == "$_launcher_sticky_base" ]]; then
      printf '0777'
    else
      printf '0755'
    fi
  }
  _mdm_launcher_acl_safe() { return 0; }
  function /usr/bin/mktemp {
    : > "$_launcher_unsafe_marker"
    return 1
  }
  _launcher_copy=sentinel
  if _mdm_launcher_snapshot \
      "$PROJECT_DIR/mdm/install-mdm.sh" _launcher_copy \
    || [[ -e "$_launcher_unsafe_marker" ]] \
    || [[ -n "$_launcher_copy" ]]; then
    fail "mdm-install: unsafe non-sticky tmp base を使用"
  else
    pass "mdm-install: unsafe tmp base を mktemp 前に拒否"
  fi
  rm -rf "${_launcher_unsafe_marker%/*}"
)
(
  _launcher_sticky_base=/tmp
  _mdm_is_darwin && _launcher_sticky_base=/private/tmp
  _mdm_launcher_stat_uid() { printf '501'; }
  if _mdm_launcher_tmp_base_trusted "$_launcher_sticky_base"; then
    fail "mdm-install: non-root tmp base を信頼"
  else
    pass "mdm-install: tmp base の root owner を必須化"
  fi
)
(
  _launcher_sticky_base=/tmp
  _mdm_is_darwin && _launcher_sticky_base=/private/tmp
  _mdm_launcher_stat_uid() { printf '0'; }
  _mdm_launcher_stat_mode() {
    if [[ "$1" == "$_launcher_sticky_base" ]]; then
      printf '1777'
    else
      printf '0755'
    fi
  }
  _mdm_launcher_acl_safe() { return 1; }
  if _mdm_launcher_tmp_base_trusted "$_launcher_sticky_base"; then
    fail "mdm-install: ACL-bearing tmp chain を信頼"
  else
    pass "mdm-install: ACL-bearing tmp chain を拒否"
  fi
)
(
  _launcher_tmp="$(mktemp -d)"; _launcher_src="$_launcher_tmp/source.sh"
  printf '#!/bin/bash\nprintf snapshot\n' > "$_launcher_src"
  _launcher_copy=""
  if _mdm_launcher_snapshot "$_launcher_src" _launcher_copy \
    && [[ -f "$_launcher_copy" \
      && "$(cat "$_launcher_copy")" == "$(cat "$_launcher_src")" ]] \
    && ! grep -Fq '/proc/$$/fd/9' "$PROJECT_DIR/mdm/install-mdm.sh"; then
    pass "mdm-install: launcher snapshot は inherited /dev/fd を照合"
  else
    fail "mdm-install: launcher fd snapshot 契約が不正"
  fi
  rm -f "$_launcher_copy"; rm -rf "$_launcher_tmp"
)

# Launcher signal cleanup owns only handed-off temporary snapshots.  The
# persistent root-managed installer/renderer bundle must survive signals both
# before the first snapshot and between the renderer/script snapshots.
(
  _launcher_tmp="$(mktemp -d)"
  _launcher_original_script="$_launcher_tmp/install-mdm.sh"
  _launcher_original_renderer="$_launcher_tmp/render-expected.py"
  printf '#!/bin/bash\nprintf installer\n' > "$_launcher_original_script"
  printf '#!/usr/bin/python3\nprint("renderer")\n' \
    > "$_launcher_original_renderer"
  _launcher_script_inode="$(_mdm_stat_inode "$_launcher_original_script")"
  _launcher_renderer_inode="$(_mdm_stat_inode "$_launcher_original_renderer")"
  _launcher_script_hash="$(_mdm_sha256_file "$_launcher_original_script")"
  _launcher_renderer_hash="$(_mdm_sha256_file "$_launcher_original_renderer")"

  for _launcher_signal_case in HUP:129 INT:130 TERM:143; do
    _launcher_signal="${_launcher_signal_case%%:*}"
    _launcher_expected_rc="${_launcher_signal_case#*:}"
    for _launcher_phase in before between; do
      _launcher_snapshot=""
      if [[ "$_launcher_phase" == between ]]; then
        _launcher_snapshot="$_launcher_tmp/renderer-${_launcher_signal}.snapshot"
        /bin/cp "$_launcher_original_renderer" "$_launcher_snapshot"
      fi
      _launcher_signal_rc=0
      /bin/bash --noprofile --norc -c '
        MDM_SOURCE_ONLY=1 source "$1"
        _mdm_clean_script_source="$2"
        _mdm_clean_renderer_source="$3"
        _mdm_clean_script_snapshot=""
        _mdm_clean_renderer_snapshot="$4"
        _mdm_launcher_arm_cleanup_traps
        /bin/kill "-$5" "$$"
        exit 99
      ' _ "$PROJECT_DIR/mdm/install-mdm.sh" \
        "$_launcher_original_script" "$_launcher_original_renderer" \
        "$_launcher_snapshot" "$_launcher_signal" >/dev/null 2>&1 \
        || _launcher_signal_rc=$?
      if [[ "$_launcher_signal_rc" == "$_launcher_expected_rc" \
        && "$(_mdm_stat_inode "$_launcher_original_script")" \
          == "$_launcher_script_inode" \
        && "$(_mdm_stat_inode "$_launcher_original_renderer")" \
          == "$_launcher_renderer_inode" \
        && "$(_mdm_sha256_file "$_launcher_original_script")" \
          == "$_launcher_script_hash" \
        && "$(_mdm_sha256_file "$_launcher_original_renderer")" \
          == "$_launcher_renderer_hash" \
        && ( -z "$_launcher_snapshot" || ! -e "$_launcher_snapshot" ) ]]; then
        pass "mdm-install: ${_launcher_signal}/${_launcher_phase} cleanupは原本を保持"
      else
        fail "mdm-install: ${_launcher_signal}/${_launcher_phase} cleanupが原本を破壊"
      fi
    done
  done
  rm -rf "$_launcher_tmp"
)

# Hold the copy open on a FIFO and inject each supported signal after mktemp.
# The trapped caller must collect the published privileged snapshot.
(
  _launcher_tmp="$(mktemp -d)"
  _launcher_signal_base="$MDM_TEST_TMP_ROOT"
  _launcher_original_script="$_launcher_tmp/install-mdm.sh"
  _launcher_original_renderer="$_launcher_tmp/render-expected.py"
  printf '#!/bin/bash\nprintf installer\n' > "$_launcher_original_script"
  printf '#!/usr/bin/python3\nprint("renderer")\n' \
    > "$_launcher_original_renderer"
  _launcher_script_inode="$(_mdm_stat_inode "$_launcher_original_script")"
  _launcher_renderer_inode="$(_mdm_stat_inode "$_launcher_original_renderer")"
  _launcher_script_hash="$(_mdm_sha256_file "$_launcher_original_script")"
  _launcher_renderer_hash="$(_mdm_sha256_file "$_launcher_original_renderer")"

  _mdm_install_launcher_copy_signal_case() { # <signal> <exit-code>
    local _signal="$1" _expected="$2" _fifo _record _token _candidate _rc=0
    _fifo="$_launcher_tmp/copy-$_signal.fifo"
    _record="$_launcher_tmp/copy-$_signal.path"
    _token="installer-launcher-copy-$_signal-$$"
    /usr/bin/mkfifo "$_fifo"
    (
      _mdm_clean_script_source="$_launcher_original_script"
      _mdm_clean_renderer_source="$_launcher_original_renderer"
      _mdm_clean_script_snapshot=""
      _mdm_clean_renderer_snapshot=""
      _mdm_launcher_arm_cleanup_traps
      {
        printf '%s\n' "$_token"
        _launcher_slow_count=0
        while [[ "$_launcher_slow_count" -lt 40 ]]; do
          printf '.\n'
          /bin/sleep 0.01
          _launcher_slow_count=$((_launcher_slow_count + 1))
        done
      } > "$_fifo" &
      /bin/sh -c '
        target=$PPID
        count=0
        while [ "$count" -lt 300 ]; do
          for candidate in "$2"/claude-kit-mdm-launcher.*; do
            if [ -f "$candidate" ] \
              && /usr/bin/grep -Fq -- "$3" "$candidate"; then
              printf "%s" "$candidate" > "$4"
              /bin/kill "-$1" "$target"
              exit $?
            fi
          done
          /bin/sleep 0.01
          count=$((count + 1))
        done
        exit 90
      ' launcher-signal "$_signal" "$_launcher_signal_base" \
        "$_token" "$_record" &
      _mdm_launcher_snapshot "$_fifo" _mdm_clean_script_snapshot
      exit 91
    ) || _rc=$?
    _candidate="$(/bin/cat "$_record" 2>/dev/null || true)"
    if [[ "$_rc" -eq "$_expected" && -n "$_candidate" \
      && "$_candidate" != *$'\n'* && ! -e "$_candidate" \
      && "$(_mdm_stat_inode "$_launcher_original_script")" \
        == "$_launcher_script_inode" \
      && "$(_mdm_stat_inode "$_launcher_original_renderer")" \
        == "$_launcher_renderer_inode" \
      && "$(_mdm_sha256_file "$_launcher_original_script")" \
        == "$_launcher_script_hash" \
      && "$(_mdm_sha256_file "$_launcher_original_renderer")" \
        == "$_launcher_renderer_hash" ]]; then
      pass "mdm-install: copy中の$_signal でlauncher snapshotを回収"
    else
      fail "mdm-install: copy中の$_signal cleanupが不正 (rc=$_rc)"
    fi
    [[ -z "$_candidate" ]] || /bin/rm -f "$_candidate"
    /bin/rm -f "$_fifo" "$_record"
  }

  _mdm_install_launcher_copy_signal_case HUP 129
  _mdm_install_launcher_copy_signal_case INT 130
  _mdm_install_launcher_copy_signal_case TERM 143

  _mdm_install_launcher_supervisor_signal_case() { # <signal> <exit-code>
    local _signal="$1" _expected="$2" _ready _marker _cleanup_marker
    local _pgid_record _sender_record _sender_done _script_snapshot
    local _renderer_snapshot _observed _sender _sender_gone=false
    local _cleanup_observed _record _recorded_pid _recorded_ppid
    local _actual_ppid _recorded_pgid _second_signal
    local _group_state _diagnostic _sender_attempt=0 _sender_completed=false
    local _diagnostic_clean=true _group_gone=false _rc=0
    _ready="$_launcher_tmp/supervisor-$_signal.ready"
    _marker="$_launcher_tmp/supervisor-$_signal.marker"
    _cleanup_marker="$_launcher_tmp/supervisor-$_signal.cleanup"
    _pgid_record="$_launcher_tmp/supervisor-$_signal.pgid"
    _sender_record="$_launcher_tmp/supervisor-$_signal.sender"
    _sender_done="$_launcher_tmp/supervisor-$_signal.sender-done"
    _script_snapshot="$_launcher_tmp/supervisor-$_signal.script"
    _renderer_snapshot="$_launcher_tmp/supervisor-$_signal.renderer"
    _diagnostic="$_launcher_tmp/supervisor-$_signal.diagnostic"
    (
      _mdm_clean_script_source="$_launcher_original_script"
      _mdm_clean_renderer_source="$_launcher_original_renderer"
      _mdm_clean_script_snapshot="$_script_snapshot"
      _mdm_clean_renderer_snapshot="$_renderer_snapshot"
      _mdm_clean_child_pid=""
      _mdm_clean_child_pgid=""
      _mdm_clean_child_starting=0
      /bin/cp "$_launcher_original_script" "$_mdm_clean_script_snapshot"
      /bin/cp "$_launcher_original_renderer" \
        "$_mdm_clean_renderer_snapshot"
      _mdm_launcher_arm_cleanup_traps
      set -m
      /bin/bash --noprofile --norc -c '
        _ready=$1
        _marker=$2
        _cleanup_marker=$3
        _mdm_child_finish() {
          printf "%s" "$1" > "$_marker"
          /bin/sleep 0.1
          printf "%s" "$1" > "$_cleanup_marker"
          exit "$2"
        }
        _mdm_child_hup() { _mdm_child_finish HUP 129; }
        _mdm_child_int() { _mdm_child_finish INT 130; }
        _mdm_child_term() { _mdm_child_finish TERM 143; }
        trap _mdm_child_hup HUP
        trap _mdm_child_int INT
        trap _mdm_child_term TERM
        : > "$_ready"
        [[ "$4" != TERM ]] || /bin/kill -STOP "$$"
        while :; do /bin/sleep 1; done
      ' launcher-child "$_ready" "$_marker" "$_cleanup_marker" \
        "$_signal" &
      _mdm_clean_child_pid=$!
      _mdm_clean_child_pgid="$_mdm_clean_child_pid"
      _child_identity="$(
        LC_ALL=C /bin/ps -p "$_mdm_clean_child_pid" -o ppid= -o pgid= \
          2>/dev/null \
          | /usr/bin/awk 'NF >= 2 { print $1 ":" $2; exit }'
      )"
      _supervisor_pid="${_child_identity%%:*}"
      _mdm_clean_supervisor_pid="$_supervisor_pid"
      printf '%s:%s:%s' "$_mdm_clean_child_pid" "$_supervisor_pid" \
        "$_child_identity" > "$_pgid_record"
      set +m
      _launcher_ready_count=0
      while [[ ! -e "$_ready" && "$_launcher_ready_count" -lt 300 ]]; do
        /bin/sleep 0.01
        _launcher_ready_count=$((_launcher_ready_count + 1))
      done
      if [[ ! -e "$_ready" ]]; then
        /bin/kill -TERM -- "-$_mdm_clean_child_pgid" 2>/dev/null || true
        wait "$_mdm_clean_child_pid" 2>/dev/null || true
        _mdm_clean_child_pid=""
        _mdm_clean_child_pgid=""
        exit 90
      fi
      if [[ "$_signal" == TERM ]]; then
        _stopped_count=0
        while [[ "$(LC_ALL=C /bin/ps -p "$_mdm_clean_child_pid" \
          -o stat= 2>/dev/null)" != *T* \
          && "$_stopped_count" -lt 300 ]]; do
          /bin/sleep 0.01
          _stopped_count=$((_stopped_count + 1))
        done
        [[ "$_stopped_count" -lt 300 ]] || exit 90
      fi
      case "$_signal" in
        TERM) _second_signal=HUP ;;
        *) _second_signal=TERM ;;
      esac
      /bin/sh -c '
        trap "" HUP INT TERM
        _target=$PPID
        _attempt=0
        while [ ! -e "$1" ] && [ "$_attempt" -lt 500 ]; do
          /bin/sleep 0.01
          _attempt=$((_attempt + 1))
        done
        if [ -e "$1" ]; then
          /bin/kill "-$2" "$_target" 2>/dev/null || true
        fi
        : > "$3"
      ' launcher-second-signal "$_marker" "$_second_signal" \
        "$_sender_done" &
      printf '%s' "$!" > "$_sender_record"
      /bin/sh -c '/bin/kill "-$1" "$PPID"' launcher-signal "$_signal"
      exit 91
    ) > "$_diagnostic" 2>&1 || _rc=$?
    _observed="$(/bin/cat "$_marker" 2>/dev/null || true)"
    _cleanup_observed="$(/bin/cat "$_cleanup_marker" 2>/dev/null || true)"
    _record="$(/bin/cat "$_pgid_record" 2>/dev/null || true)"
    _recorded_pid="${_record%%:*}"; _record="${_record#*:}"
    _recorded_ppid="${_record%%:*}"; _record="${_record#*:}"
    _actual_ppid="${_record%%:*}"; _recorded_pgid="${_record#*:}"
    _sender="$(/bin/cat "$_sender_record" 2>/dev/null || true)"
    while [[ "$_sender" =~ ^[1-9][0-9]*$ \
      && "$_sender_attempt" -lt 600 ]]; do
      if ! /bin/kill -0 "$_sender" 2>/dev/null; then
        _sender_gone=true
        break
      fi
      /bin/sleep 0.01
      _sender_attempt=$((_sender_attempt + 1))
    done
    [[ ! -e "$_sender_done" ]] || _sender_completed=true
    if [[ "$_recorded_pgid" =~ ^[1-9][0-9]*$ ]]; then
      _group_state=0
      _mdm_launcher_group_state "$_recorded_pgid" || _group_state=$?
      [[ "$_group_state" -ne 1 ]] || _group_gone=true
    fi
    [[ ! -s "$_diagnostic" ]] || _diagnostic_clean=false
    if [[ "$_rc" -eq "$_expected" && "$_observed" == "$_signal" \
      && "$_cleanup_observed" == "$_signal" && "$_group_gone" == true \
      && "$_recorded_pid" == "$_recorded_pgid" \
      && "$_recorded_ppid" == "$_actual_ppid" \
      && "$_sender_completed" == true && "$_sender_gone" == true \
      && "$_diagnostic_clean" == true \
      && ! -e "$_script_snapshot" && ! -e "$_renderer_snapshot" \
      && "$(_mdm_stat_inode "$_launcher_original_script")" \
        == "$_launcher_script_inode" \
      && "$(_mdm_stat_inode "$_launcher_original_renderer")" \
        == "$_launcher_renderer_inode" \
      && "$(_mdm_sha256_file "$_launcher_original_script")" \
        == "$_launcher_script_hash" \
      && "$(_mdm_sha256_file "$_launcher_original_renderer")" \
        == "$_launcher_renderer_hash" ]]; then
      pass "mdm-install: outer $_signal でleader cleanupとchild group回収を完了"
    else
      fail "mdm-install: outer $_signal supervisorが不正 (rc=$_rc child=$_observed cleanup=$_cleanup_observed group=$_group_gone pid=$_recorded_pid ppid=$_recorded_ppid/$_actual_ppid pgid=$_recorded_pgid sender=$_sender_completed/$_sender_gone snapshots=$([[ ! -e "$_script_snapshot" && ! -e "$_renderer_snapshot" ]] && printf gone || printf remain) noise=$_diagnostic_clean)"
    fi
    if [[ "$_recorded_pgid" =~ ^[1-9][0-9]*$ ]]; then
      /bin/kill -STOP -- "-$_recorded_pgid" 2>/dev/null || true
      /bin/kill -KILL -- "-$_recorded_pgid" 2>/dev/null || true
    fi
    [[ ! "$_sender" =~ ^[1-9][0-9]*$ ]] \
      || /bin/kill -KILL "$_sender" 2>/dev/null || true
    /bin/rm -f "$_ready" "$_marker" "$_cleanup_marker" "$_pgid_record" \
      "$_sender_record" "$_sender_done" "$_script_snapshot" \
      "$_renderer_snapshot" "$_diagnostic"
  }

  _mdm_install_launcher_supervisor_signal_case HUP 129
  _mdm_install_launcher_supervisor_signal_case INT 130
  _mdm_install_launcher_supervisor_signal_case TERM 143

  _mdm_install_launcher_noncooperative_signal_case() { # <signal> <exit-code>
    local _signal="$1" _expected="$2"
    local _ready _pid_record _pgid_record _script_snapshot
    local _renderer_snapshot _diagnostic _child _actual_pgid _group_state
    local _started _elapsed _attempt=0 _diagnostic_clean=true
    local _group_gone=false _rc=0
    _ready="$_launcher_tmp/noncooperative-$_signal.ready"
    _pid_record="$_launcher_tmp/noncooperative-$_signal.pid"
    _pgid_record="$_launcher_tmp/noncooperative-$_signal.pgid"
    _script_snapshot="$_launcher_tmp/noncooperative-$_signal.script"
    _renderer_snapshot="$_launcher_tmp/noncooperative-$_signal.renderer"
    _diagnostic="$_launcher_tmp/noncooperative-$_signal.diagnostic"
    _started="$(/bin/date +%s)"
    (
      _mdm_clean_script_source="$_launcher_original_script"
      _mdm_clean_renderer_source="$_launcher_original_renderer"
      _mdm_clean_script_snapshot="$_script_snapshot"
      _mdm_clean_renderer_snapshot="$_renderer_snapshot"
      _mdm_clean_child_pid=""
      _mdm_clean_child_pgid=""
      _mdm_clean_child_starting=0
      _MDM_LAUNCHER_SIGNAL_WAIT_ITERATIONS=20
      /bin/cp "$_launcher_original_script" "$_mdm_clean_script_snapshot"
      /bin/cp "$_launcher_original_renderer" \
        "$_mdm_clean_renderer_snapshot"
      _mdm_launcher_arm_cleanup_traps
      set -m
      /bin/bash --noprofile --norc -c '
        trap "" HUP INT TERM
        : > "$1"
        while :; do /bin/sleep 30; done
      ' launcher-child "$_ready" &
      _mdm_clean_child_pid=$!
      _mdm_clean_child_pgid=""
      _mdm_clean_child_starting=1
      printf '%s' "$_mdm_clean_child_pid" > "$_pid_record"
      _child_identity="$(
        LC_ALL=C /bin/ps -p "$_mdm_clean_child_pid" -o ppid= -o pgid= \
          2>/dev/null \
          | /usr/bin/awk 'NF >= 2 { print $1 ":" $2; exit }'
      )"
      _mdm_clean_supervisor_pid="${_child_identity%%:*}"
      _actual_pgid="${_child_identity#*:}"
      printf '%s' "$_actual_pgid" > "$_pgid_record"
      set +m
      while [[ ! -e "$_ready" && "$_attempt" -lt 300 ]]; do
        /bin/sleep 0.01
        _attempt=$((_attempt + 1))
      done
      [[ -e "$_ready" ]] || exit 90
      /bin/sh -c '/bin/kill "-$1" "$PPID"' launcher-signal "$_signal"
      exit 91
    ) > "$_diagnostic" 2>&1 || _rc=$?
    _elapsed=$(( $(/bin/date +%s) - _started ))
    _child="$(/bin/cat "$_pid_record" 2>/dev/null || true)"
    _actual_pgid="$(/bin/cat "$_pgid_record" 2>/dev/null || true)"
    _attempt=0
    while [[ "$_child" =~ ^[1-9][0-9]*$ \
      && "$_attempt" -lt 100 ]]; do
      _group_state=0
      _mdm_launcher_group_state "$_child" || _group_state=$?
      if [[ "$_group_state" -eq 1 ]]; then
        _group_gone=true
        break
      fi
      /bin/sleep 0.01
      _attempt=$((_attempt + 1))
    done
    [[ ! -s "$_diagnostic" ]] || _diagnostic_clean=false
    if [[ "$_rc" -eq "$_expected" && "$_group_gone" == true \
      && "$_child" == "$_actual_pgid" && "$_elapsed" -le 5 \
      && "$_diagnostic_clean" == true \
      && ! -e "$_script_snapshot" && ! -e "$_renderer_snapshot" \
      && "$(_mdm_stat_inode "$_launcher_original_script")" \
        == "$_launcher_script_inode" \
      && "$(_mdm_stat_inode "$_launcher_original_renderer")" \
        == "$_launcher_renderer_inode" \
      && "$(_mdm_sha256_file "$_launcher_original_script")" \
        == "$_launcher_script_hash" \
      && "$(_mdm_sha256_file "$_launcher_original_renderer")" \
        == "$_launcher_renderer_hash" ]]; then
      pass "mdm-install: PID-only handoffの$_signal でもchild groupを期限回収"
    else
      fail "mdm-install: PID-only handoffの$_signal 回収が不正 (rc=$_rc group=$_group_gone pgid=$_actual_pgid elapsed=$_elapsed noise=$_diagnostic_clean)"
    fi
    if [[ "$_child" =~ ^[1-9][0-9]*$ ]]; then
      /bin/kill -STOP -- "-$_child" 2>/dev/null || true
      /bin/kill -KILL -- "-$_child" 2>/dev/null || true
    fi
    /bin/rm -f "$_ready" "$_pid_record" "$_pgid_record" "$_script_snapshot" \
      "$_renderer_snapshot" "$_diagnostic"
  }

  _mdm_install_launcher_noncooperative_signal_case HUP 129
  _mdm_install_launcher_noncooperative_signal_case INT 130
  _mdm_install_launcher_noncooperative_signal_case TERM 143

  _mdm_install_launcher_quiescence_case() {
    local _ready _member_record _diagnostic _rc=0
    _ready="$_launcher_tmp/quiescence.ready"
    _member_record="$_launcher_tmp/quiescence.member"
    _diagnostic="$_launcher_tmp/quiescence.diagnostic"
    (
      _leader=""
      _cleanup_quiescence_case() {
        if [[ "$_leader" =~ ^[1-9][0-9]*$ ]]; then
          /bin/kill -STOP -- "-$_leader" 2>/dev/null || true
          /bin/kill -KILL -- "-$_leader" 2>/dev/null || true
          _mdm_launcher_wait_child_bounded "$_leader" 100 || true
        fi
      }
      trap _cleanup_quiescence_case EXIT
      set -m
      /bin/bash --noprofile --norc -c '
        trap "" HUP INT TERM
        /bin/sleep 30 &
        printf "%s" "$!" > "$1"
        : > "$2"
        wait
      ' launcher-quiescence "$_member_record" "$_ready" &
      _leader=$!
      _actual_pgid="$(
        LC_ALL=C /bin/ps -p "$_leader" -o pgid= 2>/dev/null || true
      )"
      _actual_pgid="${_actual_pgid//[[:space:]]/}"
      set +m
      _attempt=0
      while [[ ! -e "$_ready" && "$_attempt" -lt 300 ]]; do
        /bin/sleep 0.01
        _attempt=$((_attempt + 1))
      done
      [[ -e "$_ready" && "$_actual_pgid" == "$_leader" ]]
      /bin/kill -STOP -- "-$_leader"
      _attempt=0
      while ! _mdm_launcher_group_quiesced "$_leader" \
        && [[ "$_attempt" -lt 100 ]]; do
        /bin/sleep 0.01
        _attempt=$((_attempt + 1))
      done
      _listing="$(LC_ALL=C /bin/ps -axo pgid=,stat= 2>/dev/null)"
      _member_count="$(printf '%s\n' "$_listing" \
        | /usr/bin/awk -v pgid="$_leader" '$1 == pgid { count++ }
          END { print count + 0 }')"
      [[ "$_member_count" -ge 2 ]]
      _mdm_launcher_group_quiesced "$_leader"
      exec 2>/dev/null
      /bin/kill -KILL -- "-$_leader" 2>/dev/null || true
      _mdm_launcher_wait_child_bounded "$_leader" 100 || true
      _state=0
      _mdm_launcher_group_state "$_leader" || _state=$?
      [[ "$_state" -eq 1 ]]
      _leader=""
      trap - EXIT
    ) > "$_diagnostic" 2>&1 || _rc=$?
    if [[ "$_rc" -eq 0 && ! -s "$_diagnostic" ]]; then
      pass "mdm-install: 2-member child groupはSTOP後T/t/Zまで静止してから回収"
    else
      fail "mdm-install: child group quiescence確認が不正 (rc=$_rc)"
    fi
    /bin/rm -f "$_ready" "$_member_record" "$_diagnostic"
  }

  _mdm_install_launcher_quiescence_case

  _mdm_install_launcher_quick_exit_case() {
    local _diagnostic _rc=0
    _diagnostic="$_launcher_tmp/quick-exit.diagnostic"
    (
      _attempt=0
      while [[ "$_attempt" -lt 100 ]]; do
        set -m
        /usr/bin/true &
        _quick_pid=$! \
          _quick_pgid=$! \
          _quick_starting=1
        set +m
        _actual_pgid="$(
          LC_ALL=C /bin/ps -p "$_quick_pid" -o pgid= 2>/dev/null || true
        )"
        _actual_pgid="${_actual_pgid//[[:space:]]/}"
        [[ -z "$_actual_pgid" || "$_actual_pgid" == "$_quick_pgid" ]]
        wait "$_quick_pid"
        _quick_pid="" _quick_pgid="" _quick_starting=0
        _attempt=$((_attempt + 1))
      done
    ) > "$_diagnostic" 2>&1 || _rc=$?
    if [[ "$_rc" -eq 0 && ! -s "$_diagnostic" ]]; then
      pass "mdm-install: quick-exit childのPGID検証でもjob診断を出さない"
    else
      fail "mdm-install: quick-exit childのPGID検証が不正 (rc=$_rc)"
    fi
    /bin/rm -f "$_diagnostic"
  }

  _mdm_install_launcher_quick_exit_case

  _mdm_install_launcher_starting_signal_case() { # <signal> <exit-code>
    local _signal="$1" _expected="$2" _pid_record _pgid_record
    local _script_snapshot _renderer_snapshot _diagnostic _child _actual_pgid
    local _group_state=0 _rc=0
    _pid_record="$_launcher_tmp/starting-$_signal.pid"
    _pgid_record="$_launcher_tmp/starting-$_signal.pgid"
    _script_snapshot="$_launcher_tmp/starting-$_signal.script"
    _renderer_snapshot="$_launcher_tmp/starting-$_signal.renderer"
    _diagnostic="$_launcher_tmp/starting-$_signal.diagnostic"
    (
      _mdm_clean_script_source="$_launcher_original_script"
      _mdm_clean_renderer_source="$_launcher_original_renderer"
      _mdm_clean_script_snapshot="$_script_snapshot"
      _mdm_clean_renderer_snapshot="$_renderer_snapshot"
      _mdm_clean_child_pid=""
      _mdm_clean_child_pgid=""
      _mdm_clean_child_starting=0
      /bin/cp "$_launcher_original_script" "$_mdm_clean_script_snapshot"
      /bin/cp "$_launcher_original_renderer" \
        "$_mdm_clean_renderer_snapshot"
      _mdm_launcher_arm_cleanup_traps
      set -m
      _mdm_clean_child_starting=1
      /bin/sleep 10 &
      _starting_child=$!
      _child_identity="$(
        LC_ALL=C /bin/ps -p "$_starting_child" -o ppid= -o pgid= \
          2>/dev/null \
          | /usr/bin/awk 'NF >= 2 { print $1 ":" $2; exit }'
      )"
      _mdm_clean_supervisor_pid="${_child_identity%%:*}"
      _actual_pgid="${_child_identity#*:}"
      printf '%s' "$_starting_child" > "$_pid_record"
      printf '%s' "$_actual_pgid" > "$_pgid_record"
      /bin/sh -c '/bin/kill "-$1" "$PPID"' launcher-signal "$_signal"
      exit 91
    ) > "$_diagnostic" 2>&1 || _rc=$?
    _child="$(/bin/cat "$_pid_record" 2>/dev/null || true)"
    _actual_pgid="$(/bin/cat "$_pgid_record" 2>/dev/null || true)"
    if [[ "$_actual_pgid" =~ ^[1-9][0-9]*$ ]]; then
      _mdm_launcher_group_state "$_actual_pgid" || _group_state=$?
    fi
    if [[ "$_rc" -eq "$_expected" && "$_child" =~ ^[1-9][0-9]*$ \
      && "$_child" == "$_actual_pgid" && "$_group_state" -eq 1 \
      && ! -s "$_diagnostic" \
      && ! -e "$_script_snapshot" && ! -e "$_renderer_snapshot" \
      && "$(_mdm_stat_inode "$_launcher_original_script")" \
        == "$_launcher_script_inode" \
      && "$(_mdm_stat_inode "$_launcher_original_renderer")" \
        == "$_launcher_renderer_inode" \
      && "$(_mdm_sha256_file "$_launcher_original_script")" \
        == "$_launcher_script_hash" \
      && "$(_mdm_sha256_file "$_launcher_original_renderer")" \
        == "$_launcher_renderer_hash" ]]; then
      pass "mdm-install: child PID handoff前のouter $_signal もorphanなく回収"
    else
      fail "mdm-install: child PID handoff前のouter $_signal cleanupが不正 (rc=$_rc)"
    fi
    if [[ "$_actual_pgid" =~ ^[1-9][0-9]*$ ]]; then
      /bin/kill -STOP -- "-$_actual_pgid" 2>/dev/null || true
      /bin/kill -KILL -- "-$_actual_pgid" 2>/dev/null || true
    fi
    /bin/rm -f "$_pid_record" "$_pgid_record" "$_script_snapshot" \
      "$_renderer_snapshot" "$_diagnostic"
  }

  _mdm_install_launcher_starting_signal_case HUP 129
  _mdm_install_launcher_starting_signal_case INT 130
  _mdm_install_launcher_starting_signal_case TERM 143
  /bin/rm -f "$_launcher_original_script" "$_launcher_original_renderer"
  /bin/rmdir "$_launcher_tmp"
)

# ── detached HEAD は fd-bound 41 byte full SHA のみ許可 ──
(
  _head_tmp="$(mktemp -d)"
  _head_tmp="$(builtin cd -P "$_head_tmp" && printf '%s' "$PWD")"
  mkdir -p "$_head_tmp/.git"
  _head_sha=0123456789abcdef0123456789abcdef01234567
  _head_uid="$(/usr/bin/id -u)"
  printf '%s\n' "$_head_sha" > "$_head_tmp/.git/HEAD"
  if _mdm_detached_head_matches "$_head_tmp" "$_head_sha"; then
    fail "mdm-install: detached HEAD の空 expected UID を受理"
  else
    pass "mdm-install: detached HEAD は expected UID 束縛を必須化"
  fi
  if _mdm_detached_head_matches "$_head_tmp" "$_head_sha" "$_head_uid"; then
    pass "mdm-install: fd-bound detached HEAD の full SHA を許可"
  else
    fail "mdm-install: 正常な detached HEAD を拒否"
  fi
  chmod 777 "$_head_tmp/.git"
  if _mdm_detached_head_matches "$_head_tmp" "$_head_sha" "$_head_uid"; then
    fail "mdm-install: writable .git directory を許可"
  else
    pass "mdm-install: detached HEAD の .git trust metadata を検証"
  fi
  chmod 755 "$_head_tmp/.git"
  printf 'ref: refs/heads/main\n' > "$_head_tmp/.git/HEAD"
  if _mdm_detached_head_matches "$_head_tmp" "$_head_sha" "$_head_uid"; then
    fail "mdm-install: symbolic HEAD を許可"
  else
    pass "mdm-install: symbolic/非41byte HEAD を拒否"
  fi
  rm -f "$_head_tmp/.git/HEAD"
  printf '%s\n' "$_head_sha" > "$_head_tmp/target"
  ln -s "$_head_tmp/target" "$_head_tmp/.git/HEAD"
  if _mdm_detached_head_matches "$_head_tmp" "$_head_sha" "$_head_uid"; then
    fail "mdm-install: symlink HEAD を許可"
  else
    pass "mdm-install: symlink HEAD を拒否"
  fi
  rm -f "$_head_tmp/.git/HEAD"
  printf '%s\n' "$_head_sha" > "$_head_tmp/.git/HEAD"
  _mdm_persistent_dir_identity() {
    [[ "$1" != "$_head_tmp/.git" ]] || return 1
    return 1
  }
  if _mdm_detached_head_matches "$_head_tmp" "$_head_sha" \
    "$_head_uid" \
    >/dev/null 2>&1; then
    fail "mdm-install: .git identity 捕捉失敗を束縛スキップとして受理"
  else
    pass "mdm-install: .git identity 捕捉失敗は fail-closed"
  fi
  rm -rf "$_head_tmp"
)

# Repository content must not make root chmod follow setup.sh outside the
# authoritative checkout.
(
  _auth_link_tmp="$(mktemp -d)"
  mkdir -p "$_auth_link_tmp/tree"
  printf '#!/bin/bash\n' > "$_auth_link_tmp/external.sh"
  chmod 600 "$_auth_link_tmp/external.sh"
  ln -s "$_auth_link_tmp/external.sh" "$_auth_link_tmp/tree/setup.sh"
  _auth_link_rc=0
  _mdm_normalize_auth_tree "$_auth_link_tmp/tree" >/dev/null 2>&1 || _auth_link_rc=$?
  if [[ "$_auth_link_rc" -ne 0 ]] \
    && [[ "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_auth_link_tmp/external.sh")")" == 0600 ]]; then
    pass "mdm-install: authoritative setup symlink を chmod せず拒否"
  else
    fail "mdm-install: authoritative setup symlink の参照先 mode を変更し得る"
  fi
  rm -rf "$_auth_link_tmp"
)

# A target-user race that swaps HEAD to a FIFO must fail within the watchdog
# window instead of blocking privileged remediation indefinitely.
(
  _head_fifo_tmp="$(mktemp -d)"
  _head_fifo_tmp="$(builtin cd -P "$_head_fifo_tmp" && printf '%s' "$PWD")"
  mkdir -p "$_head_fifo_tmp/.git"
  _head_fifo_sha=0123456789abcdef0123456789abcdef01234567
  _head_fifo_path="$_head_fifo_tmp/.git/HEAD"
  _head_fifo_seen="$_head_fifo_tmp/seen"
  _head_fifo_swapped="$_head_fifo_tmp/swapped"
  printf '%s\n' "$_head_fifo_sha" > "$_head_fifo_path"
  export MDM_SNAPSHOT_WATCHDOG_SECONDS_OVERRIDE=1
  _mdm_stat_identity() {
    local _path="$1" _identity
    if [[ "$_path" == "$_head_fifo_path" && ! -e "$_head_fifo_seen" ]]; then
      if _mdm_is_darwin; then
        _identity="$(/usr/bin/stat -f '%i:%HT:%z' "$_path")"
      else
        _identity="$(/usr/bin/stat -c '%i:%F:%s' "$_path")"
      fi
      : > "$_head_fifo_seen"; printf '%s' "$_identity"
    elif [[ "$_path" == "$_head_fifo_path" && ! -e "$_head_fifo_swapped" ]]; then
      if _mdm_is_darwin; then
        _identity="$(/usr/bin/stat -f '%i:%HT:%z' "$_path")"
      else
        _identity="$(/usr/bin/stat -c '%i:%F:%s' "$_path")"
      fi
      rm -f "$_path"; /usr/bin/mkfifo "$_path"; : > "$_head_fifo_swapped"
      printf '%s' "$_identity"
    elif _mdm_is_darwin; then
      /usr/bin/stat -f '%i:%HT:%z' "$_path" 2>/dev/null
    else
      /usr/bin/stat -c '%i:%F:%s' "$_path" 2>/dev/null
    fi
  }
  _head_fifo_start="$SECONDS"; _head_fifo_rc=0
  _mdm_detached_head_matches "$_head_fifo_tmp" "$_head_fifo_sha" \
    "$(/usr/bin/id -u)" >/dev/null 2>&1 || _head_fifo_rc=$?
  _head_fifo_elapsed=$((SECONDS - _head_fifo_start))
  if [[ "$_head_fifo_rc" -ne 0 && "$_head_fifo_elapsed" -le 4 ]]; then
    pass "mdm-install: target-user HEAD の FIFO race を watchdog で拒否"
  else
    fail "mdm-install: target-user HEAD の FIFO race が bounded でない"
  fi
  rm -f "$_head_fifo_path"; rm -rf "$_head_fifo_tmp"
)

# Bind ENOENT to the current pathname, not to a directory inode renamed out
# from under the walk.  The Python wrapper pauses immediately after the helper
# opens the original directory, so renamex_np can atomically replace the live
# entry with a different real directory that contains the allegedly absent
# target.  The helper must rebind and fail closed.
if _mdm_is_darwin && [[ -x /usr/bin/python3 ]]; then
  (
    _absence_tmp="$(mktemp -d)"
    _absence_root="$_absence_tmp/root"
    _absence_slot="$_absence_root/slot"
    _absence_spare="$_absence_root/spare"
    _absence_wrapper="$_absence_tmp/python-wrapper"
    mkdir -p "$_absence_slot" "$_absence_spare"
    : > "$_absence_spare/target"
    cat > "$_absence_wrapper" <<'WRAPPER'
#!/bin/bash
[[ "$#" -eq 7 && "$1" == -I && "$2" == -B && "$3" == -S \
  && "$4" == -c ]] || exit 64
exec /usr/bin/python3 -I -B -S -c '
import os
import sys
import time

root, relative, original_code = sys.argv[1], sys.argv[2], sys.argv[3]
real_open = os.open
ready = os.path.join(root, ".absence-ready")
proceed = os.path.join(root, ".absence-proceed")
blocked = False

def controlled_open(path, flags, *args, **kwargs):
    global blocked
    descriptor = real_open(path, flags, *args, **kwargs)
    if (
        not blocked
        and path == relative.split("/", 1)[0]
        and kwargs.get("dir_fd") is not None
    ):
        blocked = True
        marker = real_open(ready, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(marker)
        deadline = time.monotonic() + 5
        while not os.path.exists(proceed):
            if time.monotonic() >= deadline:
                raise SystemExit(70)
            time.sleep(0.005)
    return descriptor

os.open = controlled_open
exec(compile(original_code, "<absence-helper>", "exec"))
' "$6" "$7" "$5"
WRAPPER
    chmod 700 "$_absence_wrapper"
    _absence_python_saved="${_MDM_ABSENCE_PYTHON:-}"
    _MDM_ABSENCE_PYTHON="$_absence_wrapper"
    _mdm_path_is_absent_with_real_parents \
      "$_absence_root" slot/target >/dev/null 2>&1 &
    _absence_pid=$!
    _absence_wait=0
    while [[ ! -e "$_absence_root/.absence-ready" && "$_absence_wait" -lt 500 ]]; do
      /bin/sleep 0.01
      _absence_wait=$((_absence_wait + 1))
    done
    _absence_swap_rc=1
    if [[ -e "$_absence_root/.absence-ready" ]]; then
      /usr/bin/python3 -I -B -c '
import ctypes
import sys

renamex_np = ctypes.CDLL(None).renamex_np
renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
renamex_np.restype = ctypes.c_int
raise SystemExit(0 if renamex_np(sys.argv[1].encode(), sys.argv[2].encode(), 2) == 0 else 1)
' "$_absence_slot" "$_absence_spare" && _absence_swap_rc=0
    fi
    : > "$_absence_root/.absence-proceed"
    _absence_rc=0
    wait "$_absence_pid" || _absence_rc=$?
    _MDM_ABSENCE_PYTHON="$_absence_python_saved"
    if [[ "$_absence_swap_rc" -ne 0 ]]; then
      skip "mdm-install: absent path is rebound after a real-parent swap" \
        "renamex_np fixture unavailable"
    elif [[ "$_absence_rc" -ne 0 && -f "$_absence_slot/target" ]]; then
      pass "mdm-install: absent path is rebound after a real-parent swap"
    else
      fail "mdm-install: renamed-away parent produced false absence (rc=$_absence_rc)"
    fi
    rm -rf "$_absence_tmp"
  )
else
  skip "mdm-install: absent path is rebound after a real-parent swap" \
    "Darwin renamex_np fixture only"
fi

# 実在するローカルアカウント（dscl 実在確認）かつ UID >= 501 を要求。
# テストは MDM_DSCL_UID_OVERRIDE で UID をモックする。
(
  _console_user=""; _console_rc=0
  _console_user="$(printf '<dictionary> {\n  Name : jane42\n}\n' \
    | _mdm_parse_console_user_record)" || _console_rc=$?
  if [[ "$_console_rc" -eq 0 && "$_console_user" == jane42 ]]; then
    pass "mdm-install: 正常な scutil ConsoleUser record を解析"
  else
    fail "mdm-install: 正常な scutil ConsoleUser record を拒否"
  fi
)
(
  unset MDM_CONSOLE_USER_OVERRIDE
  _mdm_read_console_user_record() {
    printf '<dictionary> {\n  Name : jane42\n}\n'
  }
  _mdm_stat_owner() { printf 'fallback-user'; }
  if [[ "$(_mdm_console_user)" == jane42 ]]; then
    pass "mdm-install: 正常な scutil ConsoleUser を fallback せず採用"
  else
    fail "mdm-install: 正常な scutil ConsoleUser から stat へ退化"
  fi
)
(
  unset MDM_CONSOLE_USER_OVERRIDE
  _mdm_read_console_user_record() {
    printf '<dictionary> {\n  Name : wrong-user\n}\n'
    return 42
  }
  _mdm_stat_owner() { printf 'fallback-user'; }
  if [[ "$(_mdm_console_user)" == fallback-user ]]; then
    pass "mdm-install: scutil 非0の valid-looking stdout を破棄して stat へfallback"
  else
    fail "mdm-install: 失敗した scutil の ConsoleUser を採用"
  fi
)
(
  _console_user=""; _console_rc=0
  _console_user="$(_mdm_parse_console_user_record <<'EOF'
<dictionary> {
  Name : jane
  Name : alice
}
EOF
)" || _console_rc=$?
  if [[ "$_console_rc" -ne 0 && -z "$_console_user" ]]; then
    pass "mdm-install: scutil record の重複 Name を拒否"
  else
    fail "mdm-install: 曖昧な scutil ConsoleUser を許可"
  fi
)
(
  _console_records_rejected=true
  for _console_record in $'Name :  jane\n' $'Name : \tjane\n'; do
    if printf '%s' "$_console_record" | _mdm_parse_console_user_record \
      >/dev/null 2>&1; then
      _console_records_rejected=false
    fi
  done
  [[ "$_console_records_rejected" == true ]] \
    && pass "mdm-install: scutil Name 値の余分な空白/tabを拒否" \
    || fail "mdm-install: malformed ConsoleUser delimiter を正規化"
)
(
  if [[ "$(printf 'UniqueID: 501\n' | _mdm_parse_dscl_uid)" == 501 ]] \
    && [[ "$(printf 'UniqueID:\n 502\n' | _mdm_parse_dscl_uid)" == 502 ]]; then
    pass "mdm-install: dscl UniqueID の同一行/2行単一値を解析"
  else
    fail "mdm-install: valid な dscl UniqueID record を拒否"
  fi
)
(
  _identity_guid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
  _identity_record="$(printf 'UniqueID: 501\nGeneratedUID: %s\n' \
    "$_identity_guid" | _mdm_parse_dscl_identity_record 2>/dev/null || true)"
  unset MDM_DSCL_UID_OVERRIDE MDM_SEARCH_UID_OVERRIDE
  unset MDM_DSCL_GENERATED_UID_OVERRIDE MDM_SEARCH_GENERATED_UID_OVERRIDE
  _mdm_read_local_identity_record() {
    printf 'UniqueID: 501\nGeneratedUID: %s\n' "$_identity_guid"
  }
  _mdm_read_search_identity_record() {
    printf 'GeneratedUID: %s\nUniqueID: 501\n' "$_identity_guid"
  }
  _identity_tuple="$(_mdm_bind_target_identity_tuple jane 501 \
    2>/dev/null || true)"
  if [[ "$_identity_record" == $'501\t'"$_identity_guid" \
    && "$_identity_tuple" == $'501\t'"$_identity_guid" ]]; then
    pass "mdm-install: standard dscl identity record の delimiter を除いて束縛"
  else
    fail "mdm-install: standard same-line UniqueID/GeneratedUID を拒否"
  fi
)
(
  _canonical_guid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
  export MDM_CANONICAL_USER_OVERRIDE=Jane42
  _mdm_bind_target_identity_tuple() {
    [[ "$1" == Jane42 && "$2" == 501 ]] || return 1
    printf '501\t%s' "$_canonical_guid"
  }
  mdm_validate_user_home() {
    [[ "$1" == jane42 || "$1" == Jane42 ]] || return 1
    printf '%s' /Users/Jane42
  }
  _canonical_user=""
  if _mdm_bind_canonical_target_username _canonical_user jane42 501 \
      "$_canonical_guid" && [[ "$_canonical_user" == Jane42 ]]; then
    pass "mdm-install: UIDから得たcase-sensitive canonical short nameへ再束縛"
  else
    fail "mdm-install: requested spellingをcanonical short nameへ置換できない"
  fi
)
(
  _canonical_record="$(_mdm_parse_dscacheutil_user_for_uid 501 <<'EOF'
name: Jane42
password: ********
uid: 501
gid: 20
dir: /Users/Jane42
shell: /bin/zsh

EOF
)"
  if [[ "$_canonical_record" == Jane42 ]]; then
    pass "mdm-install: dscacheutilの単一name/uid recordを厳密解析"
  else
    fail "mdm-install: 正常なdscacheutil user recordを拒否"
  fi
)
(
  _dscache_bad_records=(
    ''
    $'name: Jane\nname: Other\nuid: 501\n'
    $'name: Jane\nuid: 501\nuid: 501\n'
    $'name: Jane\nuid: 501\n\nname: Other\nuid: 501\n'
    $'uid: 501\n'
    $'name: Jane\n'
    $'name:\tJane\nuid: 501\n'
    $'name:  Jane\nuid: 501\n'
    $'name: Jane\001\nuid: 501\n'
    $'name: Jane\r\nuid: 501\n'
    $'name: Jane\nuid: 0501\n'
    $'name: Jane\nuid: 502\n'
  )
  _dscache_bad_accepted=false
  for _dscache_record in "${_dscache_bad_records[@]}"; do
    if printf '%s' "$_dscache_record" \
      | _mdm_parse_dscacheutil_user_for_uid 501 >/dev/null 2>&1; then
      _dscache_bad_accepted=true
    fi
  done
  [[ "$_dscache_bad_accepted" == false ]] \
    && pass "mdm-install: dscacheutilの空/重複/複数/欠落/制御文字/不正UIDを拒否" \
    || fail "mdm-install: malformed dscacheutil recordを受理"
)
(
  unset MDM_CANONICAL_USER_OVERRIDE
  _mdm_read_search_user_for_uid() {
    [[ "$1" == 501 ]] || return 1
    printf 'name: Jane42\nuid: 501\n'
  }
  _search_name="$(_mdm_search_policy_username_for_uid 501 2>/dev/null || true)"
  _mdm_read_search_user_for_uid() {
    printf 'name: Jane42\nuid: 501\n'
    return 9
  }
  _producer_rc=0
  _mdm_search_policy_username_for_uid 501 >/dev/null 2>&1 || _producer_rc=$?
  if [[ "$_search_name" == Jane42 && "$_producer_rc" -ne 0 ]]; then
    pass "mdm-install: UID属性検索でcanonical nameを解決しproducer非0を拒否"
  else
    fail "mdm-install: dscacheutil producerの成否を束縛できない"
  fi
)
(
  _requested_255="a$(printf '%254s' '' | /usr/bin/tr ' ' b)"
  _requested_256="${_requested_255}c"
  _canonical_32="a$(printf '%31s' '' | /usr/bin/tr ' ' b)"
  _canonical_33="${_canonical_32}c"
  KIT_MDM_TARGET_USER="$_requested_255"
  _resolved_requested=""
  if _mdm_requested_username_is_safe "$_requested_255" \
    && ! _mdm_requested_username_is_safe "$_requested_256" \
    && _mdm_requested_username_is_safe 'long.alias+mdm@example.test' \
    && [[ "$(_mdm_root_value KIT_MDM_TARGET_USER "$_requested_255")" \
      == "$_requested_255" ]] \
    && ! _mdm_root_value KIT_MDM_TARGET_USER "$_requested_256" >/dev/null 2>&1 \
    && _mdm_resolve_target_username _resolved_requested \
    && [[ "$_resolved_requested" == "$_requested_255" ]] \
    && _mdm_canonical_username_is_safe "$_canonical_32" \
    && ! _mdm_canonical_username_is_safe "$_canonical_33" \
    && ! _mdm_canonical_username_is_safe 'short+alias'; then
    pass "mdm-install: requested 255/canonical 32の各username境界を分離"
  else
    fail "mdm-install: requested/canonical username長・grammar境界が不正"
  fi
)
(
  _unsafe_requested_accepted=false
  for _unsafe_requested in 'bad/user' 'bad user' 'bad;user' 'bad:user' \
    'bad$user' $'bad\tuser' $'bad\nuser' '.leading'; do
    if _mdm_requested_username_is_safe "$_unsafe_requested"; then
      _unsafe_requested_accepted=true
    fi
  done
  [[ "$_unsafe_requested_accepted" == false ]] \
    && pass "mdm-install: requested aliasのunsafe ASCII/control/path文字を拒否" \
    || fail "mdm-install: unsafe requested aliasを受理"
)
(
  _alias_guid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
  _long_alias='this.is.a.long+appleid.alias@example.test'
  export MDM_CANONICAL_USER_OVERRIDE=shortname
  _mdm_bind_target_identity_tuple() {
    [[ "$1" == shortname && "$2" == 501 ]] || return 1
    printf '501\t%s' "$_alias_guid"
  }
  mdm_validate_user_home() {
    case "$1" in "$_long_alias"|shortname) printf '%s' /Users/shortname ;; *) return 1 ;; esac
  }
  _alias_output=unchanged
  if _mdm_bind_canonical_target_username _alias_output "$_long_alias" 501 \
      "$_alias_guid" && [[ "$_alias_output" == shortname ]]; then
    pass "mdm-install: 長いrequested aliasを同homeのcanonical short nameへ束縛"
  else
    fail "mdm-install: 有効な長aliasをcanonical short nameへ解決できない"
  fi
)
(
  _alias_guid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
  export MDM_CANONICAL_USER_OVERRIDE=shortname
  _mdm_bind_target_identity_tuple() { printf '501\t%s' "$_alias_guid"; }
  mdm_validate_user_home() {
    case "$1" in alias@example.test) printf '%s' /Users/alias ;; shortname) printf '%s' /Users/shortname ;; esac
  }
  _alias_output=unchanged
  if ! _mdm_bind_canonical_target_username _alias_output alias@example.test 501 \
      "$_alias_guid" && [[ "$_alias_output" == unchanged ]]; then
    pass "mdm-install: alias/canonical home不一致をoutput非更新で拒否"
  else
    fail "mdm-install: 別homeのaliasをcanonical accountとして受理"
  fi
)
(
  _canonical_guid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
  export MDM_CANONICAL_USER_OVERRIDE=Jane42
  _mdm_bind_target_identity_tuple() {
    [[ "$1" == Jane42 && "$2" == 501 ]] || return 1
    printf '501\t%s' FFFFFFFF-BBBB-CCCC-DDDD-EEEEEEEEEEEE
  }
  _canonical_user=unchanged
  if ! _mdm_bind_canonical_target_username _canonical_user jane42 501 \
      "$_canonical_guid" && [[ "$_canonical_user" == unchanged ]]; then
    pass "mdm-install: canonical short nameのGeneratedUID不一致をfail-closed"
  else
    fail "mdm-install: canonical short nameを別account generationへ再束縛"
  fi
)
(
  _identity_guid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
  _identity_bad_records=(
    $'UniqueID: 501\nUniqueID: 502\nGeneratedUID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\n'
    $'UniqueID: 501\nGeneratedUID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\nGeneratedUID: FFFFFFFF-BBBB-CCCC-DDDD-EEEEEEEEEEEE\n'
    $'UniqueID: 501 502\nGeneratedUID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\n'
    $'UniqueID: 501\001\nGeneratedUID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\n'
    $'UniqueID:  501\nGeneratedUID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\n'
    $'UniqueID: 0501\nGeneratedUID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\n'
    $'UniqueID: 501\nGeneratedUID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE\n'
    $'UniqueID: 501\nGeneratedUID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE \n'
    $'UniqueID: 501\nGeneratedUID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\nOther: value\n'
  )
  _identity_records_rejected=true
  for _identity_record in "${_identity_bad_records[@]}"; do
    if printf '%s' "$_identity_record" \
      | _mdm_parse_dscl_identity_record >/dev/null 2>&1; then
      _identity_records_rejected=false
    fi
  done
  if [[ "$_identity_records_rejected" == true ]]; then
    pass "mdm-install: dscl identity の duplicate/multiple/control/noncanonical を拒否"
  else
    fail "mdm-install: malformed dscl identity record を許可"
  fi
)
(
  _shell_tmp="$(mktemp -d)"
  _shell_tmp="$(builtin cd -P "$_shell_tmp" && printf '%s' "$PWD")"
  mkdir -p "$_shell_tmp/store"
  printf '#!/bin/bash\nexit 0\n' > "$_shell_tmp/store/zsh"
  chmod 755 "$_shell_tmp/store/zsh"
  ln -s "$_shell_tmp/store/zsh" "$_shell_tmp/zsh"
  _resolved_shell="$(_mdm_resolve_user_shell_path "$_shell_tmp/zsh" 2>/dev/null || true)"
  if [[ "$_resolved_shell" == "$_shell_tmp/store/zsh" ]]; then
    pass "mdm-install: Nix/Homebrew型UserShell symlinkをcanonical executableへ解決"
  else
    fail "mdm-install: 正当なUserShell symlinkを拒否 (got=$_resolved_shell)"
  fi
  ln -s "$_shell_tmp/store/missing" "$_shell_tmp/dangling"
  printf '#!/bin/bash\nexit 0\n' > "$_shell_tmp/store/not-executable"
  chmod 644 "$_shell_tmp/store/not-executable"
  if ! _mdm_resolve_user_shell_path "$_shell_tmp/dangling" >/dev/null 2>&1 \
    && ! _mdm_resolve_user_shell_path "$_shell_tmp/store/not-executable" >/dev/null 2>&1 \
    && ! _mdm_resolve_user_shell_path "relative/zsh" >/dev/null 2>&1; then
    pass "mdm-install: dangling/non-executable/relative UserShellを拒否"
  else
    fail "mdm-install: unsafe UserShell pathを許可"
  fi
  rm -rf "$_shell_tmp"
)
(
  _uid_records_are_rejected=true
  for _uid_record in $'UniqueID: 501 777\n' \
    $'UniqueID: 501\nUniqueID: 777\n' $'Garbage: 501\n'; do
    _uid_value=""; _uid_rc=0
    _uid_value="$(printf '%s' "$_uid_record" | _mdm_parse_dscl_uid)" \
      || _uid_rc=$?
    if [[ "$_uid_rc" -eq 0 || -n "$_uid_value" ]]; then
      _uid_records_are_rejected=false
    fi
  done
  [[ "$_uid_records_are_rejected" == true ]] \
    && pass "mdm-install: dscl UniqueID の複数値/重複/別キーを拒否" \
    || fail "mdm-install: 曖昧な dscl UniqueID record を許可"
)
(
  export KIT_MDM_TARGET_USER=jane
  unset MDM_DSCL_UID_OVERRIDE
  dscl() { printf 'UniqueID: 501\n'; return 42; }
  _uid_user=""; _uid_rc=0
  _uid_user="$(mdm_resolve_target_user 2>/dev/null)" || _uid_rc=$?
  if [[ "$_uid_rc" -eq "$MDM_EXIT_USER" && -z "$_uid_user" ]]; then
    pass "mdm-install: dscl 非0は valid-looking UniqueID ごと拒否"
  else
    fail "mdm-install: 失敗した dscl の UniqueID を採用 (rc=$_uid_rc)"
  fi
)
(
  export KIT_MDM_TARGET_USER=jane
  unset MDM_DSCL_UID_OVERRIDE
  dscl() { printf 'UniqueID: 501 777\n'; }
  _uid_user=""; _uid_rc=0
  _uid_user="$(mdm_resolve_target_user 2>/dev/null)" || _uid_rc=$?
  if [[ "$_uid_rc" -eq "$MDM_EXIT_USER" && -z "$_uid_user" ]]; then
    pass "mdm-install: dscl の複数 UniqueID を対象ユーザーに採用しない"
  else
    fail "mdm-install: 複数 UniqueID を採用 (rc=$_uid_rc)"
  fi
)
(
  export KIT_MDM_TARGET_USER="jane" MDM_DSCL_UID_OVERRIDE=501
  if out="$(mdm_resolve_target_user 2>/dev/null)" && [[ "$out" == "jane" ]]; then
    pass "mdm-install: KIT_MDM_TARGET_USER が優先される"
  else
    fail "mdm-install: KIT_MDM_TARGET_USER 優先が効かない (got '$out')"
  fi
)
(
  export KIT_MDM_TARGET_USER="jane" MDM_DSCL_UID_OVERRIDE=501
  _identity_user="" _identity_uid=""
  if _mdm_resolve_target_identity _identity_user _identity_uid 2>/dev/null \
    && [[ "$_identity_user" == jane && "$_identity_uid" == 501 ]]; then
    pass "mdm-install: local identity resolver が対象 user と UID を同時に返す"
  else
    fail "mdm-install: 対象 user と local UID の束縛に失敗"
  fi
)
(
  _mdm_search_policy_uid() { printf '%s' "${_search_uid_fixture:?}"; }
  _search_uid_fixture=501
  _bound_uid="$(_mdm_bind_target_uid jane 501 2>/dev/null)" || _bound_rc=$?
  _mismatch_rc=0
  _search_uid_fixture=777
  _mdm_bind_target_uid jane 501 >/dev/null 2>&1 || _mismatch_rc=$?
  if [[ "${_bound_uid:-}" == 501 && "${_bound_rc:-0}" -eq 0 \
    && "$_mismatch_rc" -ne 0 ]]; then
    pass "mdm-install: local dscl UID と search-policy UID の一致だけを受理"
  else
    fail "mdm-install: local/search-policy UID の束縛が不正"
  fi
)
(
  unset KIT_MDM_TARGET_USER
  export MDM_CONSOLE_USER_OVERRIDE="alice" MDM_DSCL_UID_OVERRIDE=502   # テスト用フック
  if out="$(mdm_resolve_target_user 2>/dev/null)" && [[ "$out" == "alice" ]]; then
    pass "mdm-install: コンソールユーザーにフォールバック"
  else
    fail "mdm-install: コンソールユーザー解決失敗 (got '$out')"
  fi
)
# UID < 501（システムアカウント）は明示指定でも拒否（最終レビュー High#8）
(
  export KIT_MDM_TARGET_USER="svcaccount" MDM_DSCL_UID_OVERRIDE=89
  _rc=0
  mdm_resolve_target_user >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "UID<501 は exit USER" \
    && pass "mdm-install: UID<501 のシステムアカウントを拒否" \
    || fail "mdm-install: UID<501 を拒否すべき (got $_rc)"
)
# 実在しないユーザー（dscl 解決不能 = UID 空）は拒否
(
  export KIT_MDM_TARGET_USER="mdm-no-such-user-x"
  unset MDM_DSCL_UID_OVERRIDE
  _rc=0
  mdm_resolve_target_user >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "実在しないユーザーは exit USER" \
    && pass "mdm-install: 実在しないユーザーを拒否" \
    || fail "mdm-install: 実在しないユーザーを拒否すべき (got $_rc)"
)
# username 文字種違反は拒否（injection/パス操作防止）
(
  export MDM_DSCL_UID_OVERRIDE=501
  _username_ok=true
  for KIT_MDM_TARGET_USER in John.Smith 123.user alice@corp; do
    export KIT_MDM_TARGET_USER
    if [[ "$(mdm_resolve_target_user 2>/dev/null)" != "$KIT_MDM_TARGET_USER" ]] \
      || [[ "$(_mdm_root_value KIT_MDM_TARGET_USER "$KIT_MDM_TARGET_USER")" != "$KIT_MDM_TARGET_USER" ]]; then
      _username_ok=false
    fi
  done
  [[ "$_username_ok" == true ]] \
    && pass "mdm-install: 大文字・数字先頭・dot/@ 区切りの short name を許可" \
    || fail "mdm-install: 有効な macOS short name を拒否"
)
(
  _username_bad_accepted=false
  for _username_bad in .john john. john..smith @john john@ 'bad;user' \
    'john/smith' 'john smith' $'john\nsmith' 123456789012345678901234567890123; do
    if _mdm_canonical_username_is_safe "$_username_bad"; then
      _username_bad_accepted=true
    fi
  done
  [[ "$_username_bad_accepted" == false ]] \
    && pass "mdm-install: path-like / injection username を拒否" \
    || fail "mdm-install: 不正な username を許可"
)
(
  export KIT_MDM_TARGET_USER='bad;user' MDM_DSCL_UID_OVERRIDE=501
  _rc=0
  mdm_resolve_target_user >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "文字種違反は exit USER" \
    && pass "mdm-install: username 文字種違反を拒否" \
    || fail "mdm-install: username 文字種違反を拒否すべき (got $_rc)"
)
(
  unset KIT_MDM_TARGET_USER
  export MDM_CONSOLE_USER_OVERRIDE="root"     # 無効ユーザー
  # NOTE: 関数呼び出しを裸のステートメントとして書き $? を後で参照すると、
  # 失敗時(20)に継承された set -e でこのサブシェルが assert 行の手前で
  # 即終了し、外側の test runner (set -euo pipefail 下で source) まで
  # 停止する。`|| _rc=$?` で明示的に捕捉して errexit を回避する。
  _rc=0
  mdm_resolve_target_user >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "root は無効ユーザーで exit USER" \
    && pass "mdm-install: root/システムユーザーを拒否" \
    || fail "mdm-install: root を拒否すべき"
)

# ── home 検証（モック）────────────────────────────────────
_tmpd="$(mktemp -d)"
# macOS では mktemp -d が /var/... (実体は /private/var/... へのシンボリックリンク)
# を返すため、実装側の canonical 化 (cd && pwd -P) と比較する前に _tmpd 自体も
# 正規化しておかないと期待値がシンボリックリンク経由のパスのままズレる。
_tmpd="$(cd "$_tmpd" && pwd -P)"
_fakehome="$_tmpd/Users/jane"
mkdir -p "$_fakehome"
(
  export MDM_DSCL_HOME_OVERRIDE="$_fakehome"
  export MDM_VALIDATE_HOME_SKIP_OWNER=1        # テストは非root所有のため owner 検査を切替
  if out="$(mdm_validate_user_home "jane" 2>/dev/null)" && [[ "$out" == "$_fakehome" ]]; then
    pass "mdm-install: home 検証が canonical パスを返す"
  else
    fail "mdm-install: home 検証失敗 (got '$out')"
  fi
)
(
  export MDM_DSCL_HOME_OVERRIDE="$_fakehome"
  export MDM_VALIDATE_HOME_SKIP_OWNER=1
  chmod 0777 "$_fakehome"
  _unsafe_home_rc=0
  mdm_validate_user_home jane >/dev/null 2>&1 || _unsafe_home_rc=$?
  chmod 0755 "$_fakehome"
  if [[ "$_unsafe_home_rc" -eq "$MDM_EXIT_USER" ]]; then
    pass "mdm-install: home の group/other writable mode を拒否"
  else
    fail "mdm-install: unsafe home mode を許可 (rc=$_unsafe_home_rc)"
  fi
)
(
  export MDM_DSCL_HOME_OVERRIDE="$_fakehome"
  export MDM_VALIDATE_HOME_SKIP_OWNER=1
  if _mdm_is_darwin \
    && /bin/chmod +a 'group:everyone deny delete' "$_fakehome" 2>/dev/null; then
    _standard_acl_rc=0
    mdm_validate_user_home jane >/dev/null 2>&1 || _standard_acl_rc=$?
    /bin/chmod -N "$_fakehome"
    if [[ "$_standard_acl_rc" -eq 0 ]]; then
      pass "mdm-install: macOS 標準 home deny-delete ACL だけを許可"
    else
      fail "mdm-install: 標準 home deny-delete ACL を拒否"
    fi
  elif _mdm_is_darwin; then
    fail "mdm-install: 標準 home ACL fixture を作成できない"
  else
    pass "mdm-install: 標準 home ACL は Darwin 契約として固定"
  fi
)
(
  export MDM_DSCL_HOME_OVERRIDE="$_fakehome"
  export MDM_VALIDATE_HOME_SKIP_OWNER=1
  if _mdm_is_darwin \
    && /bin/chmod +a \
      'group:everyone allow list,search,readattr,readextattr,readsecurity,file_inherit,directory_inherit' \
      "$_fakehome" 2>/dev/null; then
    _inheritable_acl_rc=0
    mdm_validate_user_home jane >/dev/null 2>&1 || _inheritable_acl_rc=$?
    /bin/chmod -N "$_fakehome"
    if [[ "$_inheritable_acl_rc" -eq "$MDM_EXIT_USER" ]]; then
      pass "mdm-install: home の inheritable/nonstandard ACL を拒否"
    else
      fail "mdm-install: inheritable home ACL を許可"
    fi
  elif _mdm_is_darwin; then
    fail "mdm-install: inheritable home ACL fixture を作成できない"
  else
    pass "mdm-install: inheritable home ACL 拒否は Darwin 契約として固定"
  fi
)
(
  _space_home="$_tmpd/Users/Jane Doe"
  mkdir -p "$_space_home"
  unset MDM_DSCL_HOME_OVERRIDE
  export MDM_VALIDATE_HOME_SKIP_OWNER=1
  dscl() { printf 'NFSHomeDirectory:\n %s\n' "$_space_home"; }
  if out="$(mdm_validate_user_home "jane" 2>/dev/null)" \
    && [[ "$out" == "$_space_home" ]]; then
    pass "mdm-install: dscl 2行形式の home 内部空白を保持"
  else
    fail "mdm-install: 空白を含む dscl home の解析が不正 (got '$out')"
  fi
)
(
  if [[ "$(printf 'NFSHomeDirectory: /Users/jane\n' \
    | _mdm_parse_dscl_home)" == /Users/jane ]]; then
    pass "mdm-install: dscl 同一行形式の home を維持"
  else
    fail "mdm-install: dscl 同一行形式の home を拒否"
  fi
)
(
  _invalid_home=""; _invalid_rc=0
  _invalid_home="$(_mdm_parse_dscl_home <<'EOF'
NFSHomeDirectory:
 /Users/jane
 /Users/other
EOF
)" || _invalid_rc=$?
  if [[ "$_invalid_rc" -ne 0 && -z "$_invalid_home" ]]; then
    pass "mdm-install: dscl の複数 home 値を出力前に拒否"
  else
    fail "mdm-install: dscl の曖昧な複数 home 値を許可"
  fi
)
(
  _invalid_home=""; _invalid_rc=0
  _invalid_home="$(printf 'NFSHomeDirectory:  /Users/jane\n' \
    | _mdm_parse_dscl_home)" || _invalid_rc=$?
  if [[ "$_invalid_rc" -ne 0 && -z "$_invalid_home" ]]; then
    pass "mdm-install: dscl 同一行の余分な delimiter を拒否"
  else
    fail "mdm-install: dscl の曖昧な delimiter を正規化"
  fi
)
(
  unset MDM_DSCL_HOME_OVERRIDE
  export MDM_VALIDATE_HOME_SKIP_OWNER=1
  dscl() { printf 'NFSHomeDirectory: %s\n' "$_fakehome"; return 1; }
  _invalid_home=""; _invalid_rc=0
  _invalid_home="$(mdm_validate_user_home jane 2>/dev/null)" || _invalid_rc=$?
  if [[ "$_invalid_rc" -eq "$MDM_EXIT_USER" && -z "$_invalid_home" ]]; then
    pass "mdm-install: dscl の非0終了は valid-looking stdout ごと拒否"
  else
    fail "mdm-install: 失敗した dscl の stdout を home として許可"
  fi
)
(
  export MDM_DSCL_HOME_OVERRIDE="$_tmpd/Users/nonexistent"
  export MDM_VALIDATE_HOME_SKIP_OWNER=1
  _rc=0
  mdm_validate_user_home "jane" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "存在しない home は exit USER" \
    && pass "mdm-install: 存在しない home を拒否" \
    || fail "mdm-install: 存在しない home を拒否すべき"
)
(
  ln -s "$_tmpd/Users" "$_tmpd/home-link"
  export MDM_DSCL_HOME_OVERRIDE="$_tmpd/home-link/jane"
  export MDM_VALIDATE_HOME_SKIP_OWNER=1
  _rc=0
  mdm_validate_user_home "jane" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "祖先 symlink の home は exit USER" \
    && pass "mdm-install: 祖先 symlink を含む home を拒否" \
    || fail "mdm-install: 祖先 symlink の home を拒否すべき"
)
(
  export MDM_DSCL_HOME_OVERRIDE="$_tmpd/Users/../Users/jane"
  export MDM_VALIDATE_HOME_SKIP_OWNER=1
  _rc=0
  mdm_validate_user_home "jane" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "非canonical home は exit USER" \
    && pass "mdm-install: .. を含む非canonical home を拒否" \
    || fail "mdm-install: 非canonical home を拒否すべき"
)
(
  export MDM_DSCL_HOME_OVERRIDE="$_fakehome"
  unset MDM_VALIDATE_HOME_SKIP_OWNER
  _actual_owner="$(_mdm_stat_owner "$_fakehome")"
  _expected_owner=root
  [[ "$_actual_owner" == root ]] && _expected_owner=nobody
  _rc=0
  mdm_validate_user_home "$_expected_owner" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "owner mismatch は exit USER" \
    && pass "mdm-install: 対象ユーザー以外が所有する home を拒否" \
    || fail "mdm-install: home owner mismatch を許可 (rc=$_rc)"
)
(
  export MDM_DSCL_HOME_OVERRIDE="$_fakehome"
  unset MDM_VALIDATE_HOME_SKIP_OWNER
  _mdm_stat_uid() { printf '777'; }
  _rc=0
  mdm_validate_user_home jane 501 >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "numeric owner mismatch は exit USER" \
    && pass "mdm-install: home の数値 owner UID 不一致を拒否" \
    || fail "mdm-install: home owner UID mismatch を許可 (rc=$_rc)"
)
rm -rf "$_tmpd"

# ── CLT marker の安全な作成（R2-High: /tmp 固定パスの symlink 追随排除）──
(
  _clt_labels="$(_mdm_select_clt_label <<'EOF'
Software Update Tool
* Command Line Tools for Xcode-15.0
* Label: Command Line Tools for Xcode 16.4-16.4
EOF
)"
  [[ "$_clt_labels" == "Command Line Tools for Xcode 16.4-16.4" ]] \
    && pass "mdm-install: softwareupdate の現行 Label 形式を正規化して最新 CLT を選択" \
    || fail "mdm-install: softwareupdate の CLT label 抽出が不正 (got '$_clt_labels')"
)
(
  sort() { return 97; }
  _clt_labels="$(_mdm_select_clt_label <<'EOF'
* Label: Command Line Tools for Xcode 16.9-16.9
* Label: Command Line Tools for Xcode 16.10-16.10
EOF
)"
  if [[ "$_clt_labels" == "Command Line Tools for Xcode 16.10-16.10" ]] \
    && ! /usr/bin/grep -Fq 'sort -V' "$PROJECT_DIR/mdm/install-mdm.sh"; then
    pass "mdm-install: CLT label は macOS 非対応 sort -V なしで数値比較"
  else
    fail "mdm-install: portable CLT version comparison が不正"
  fi
)
(
  _python_fixture="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK="$_python_fixture/Library/Frameworks/Python3.framework"
  _MDM_SYSTEM_PYTHON_SOURCE_LINK="$_python_fixture/usr/bin/python3"
  /bin/mkdir -p "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK/Versions/3.9/bin" \
    "$_python_fixture/usr/bin"
  printf '#!/bin/sh\nexit 0\n' \
    > "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK/Versions/3.9/bin/python3.9"
  /bin/chmod 0755 "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK/Versions/3.9/bin/python3.9"
  /bin/ln -s python3.9 \
    "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK/Versions/3.9/bin/python3"
  /bin/ln -s ../../Library/Frameworks/Python3.framework/Versions/3.9/bin/python3 \
    "$_MDM_SYSTEM_PYTHON_SOURCE_LINK"
  _mdm_system_python_dir_chain_trusted() { return 0; }
  _mdm_system_python_link_trusted() {
    local _fixture_target
    _mdm_readlink_exact "$1" _fixture_target || return 1
    printf -v "$2" '%s' "$1:$_fixture_target"
  }
  _resolved=""; _chain=""
  _mdm_system_python_resolve_fixed_link _resolved _chain
  _expected="$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK/Versions/3.9/bin/python3.9"
  _positive_ok=false
  [[ "$_resolved" == "$_expected" \
    && "$(printf '%s' "$_chain" | /usr/bin/grep -c 'python3')" -eq 2 ]] \
    && _positive_ok=true

  /bin/rm -f "$_MDM_SYSTEM_PYTHON_SOURCE_LINK"
  /bin/mkdir -p "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK/Versions/current/bin"
  printf '#!/bin/sh\nexit 0\n' \
    > "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK/Versions/current/bin/pythoncurrent"
  /bin/chmod 0755 \
    "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK/Versions/current/bin/pythoncurrent"
  /bin/ln -s ../../Library/Frameworks/Python3.framework/Versions/current/bin/pythoncurrent \
    "$_MDM_SYSTEM_PYTHON_SOURCE_LINK"
  _nonnumeric_rejected=false
  _mdm_system_python_resolve_fixed_link _resolved _chain >/dev/null 2>&1 \
    || _nonnumeric_rejected=true

  /bin/rm -f "$_MDM_SYSTEM_PYTHON_SOURCE_LINK"
  /bin/mkdir -p "$_python_fixture/outside"
  printf '#!/bin/sh\nexit 0\n' > "$_python_fixture/outside/python3"
  /bin/chmod 0755 "$_python_fixture/outside/python3"
  /bin/ln -s ../../outside/python3 "$_MDM_SYSTEM_PYTHON_SOURCE_LINK"
  _escape_rejected=false
  _mdm_system_python_resolve_fixed_link _resolved _chain >/dev/null 2>&1 \
    || _escape_rejected=true
  if [[ "$_positive_ok" == true && "$_nonnumeric_rejected" == true \
    && "$_escape_rejected" == true ]]; then
    pass "mdm-install: fixed CLT python3を2-hop解決しversion偽装/escapeを拒否"
  else
    fail "mdm-install: fixed CLT Python resolverのbounded/path契約が不正"
  fi
  /bin/rm -rf "$_python_fixture"
)
(
  _python_meta="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK="$_python_meta/Python3.framework"
  _python_binary="$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK/Versions/3.9/bin/python3.9"
  /bin/mkdir -p "$(/usr/bin/dirname "$_python_binary")"
  printf '#!/bin/sh\nexit 0\n' > "$_python_binary"
  /bin/chmod 0755 "$_python_binary"
  MDM_AUTH_OWNER_UID_OVERRIDE="$(/usr/bin/id -u)"
  _mdm_system_python_dir_chain_trusted() { return 0; }
  _identity=""; _metadata=""
  _valid_metadata=false
  _mdm_system_python_target_trusted "$_python_binary" _identity _metadata \
    && _valid_metadata=true
  /bin/chmod 0777 "$_python_binary"
  _writable_rejected=false
  _mdm_system_python_target_trusted "$_python_binary" _identity _metadata \
    >/dev/null 2>&1 || _writable_rejected=true
  /bin/chmod 0755 "$_python_binary"
  /bin/ln "$_python_binary" "$_python_binary.hardlink"
  _hardlink_allowed=false
  _mdm_system_python_target_trusted "$_python_binary" _identity _metadata \
    >/dev/null 2>&1 && _hardlink_allowed=true
  /bin/rm -f "$_python_binary.hardlink"
  /bin/ln -s python3.9 "$_python_binary.link"
  _symlink_rejected=false
  _mdm_system_python_target_trusted "$_python_binary.link" _identity _metadata \
    >/dev/null 2>&1 || _symlink_rejected=true
  if [[ "$_valid_metadata" == true && "$_writable_rejected" == true \
    && "$_hardlink_allowed" == true && "$_symlink_rejected" == true ]]; then
    pass "mdm-install: source CLT Pythonはhardlink DoSを許さずmode/symlinkを拒否"
  else
    fail "mdm-install: CLT Python実体のmetadata検証が不正"
  fi
  /bin/rm -rf "$_python_meta"
)
(
  _override_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _override_bin="$_override_tmp/python"
  printf '#!/bin/sh\nexit 0\n' > "$_override_bin"
  /bin/chmod 0755 "$_override_bin"
  MDM_SYSTEM_PYTHON_OVERRIDE="$_override_bin"
  _override_valid="$(_mdm_source_test_system_python 2>/dev/null || true)"
  /bin/ln -s "$_override_bin" "$_override_tmp/python-link"
  MDM_SYSTEM_PYTHON_OVERRIDE="$_override_tmp/python-link"
  _symlink_override_rejected=false
  _mdm_source_test_system_python >/dev/null 2>&1 \
    || _symlink_override_rejected=true
  MDM_SYSTEM_PYTHON_OVERRIDE=relative/python
  _relative_override_rejected=false
  _mdm_source_test_system_python >/dev/null 2>&1 \
    || _relative_override_rejected=true
  /bin/chmod 0644 "$_override_bin"
  MDM_SYSTEM_PYTHON_OVERRIDE="$_override_bin"
  _nonexec_override_rejected=false
  _mdm_source_test_system_python >/dev/null 2>&1 \
    || _nonexec_override_rejected=true
  if [[ "$_override_valid" == "$_override_bin" \
    && "$_symlink_override_rejected" == true \
    && "$_relative_override_rejected" == true \
    && "$_nonexec_override_rejected" == true ]]; then
    pass "mdm-install: source-only Python overrideはcanonical regular executable限定"
  else
    fail "mdm-install: source-only Python overrideがunsafe pathを受理"
  fi
  /bin/rm -rf "$_override_tmp"
)
(
  _clt_present_impl="$(declare -f _mdm_clt_present)"
  _python_validate_impl="$(declare -f _mdm_validate_system_python)"
  _private_validate_impl="$(declare -f _mdm_validate_private_system_python)"
  _python_tree_impl="$(declare -f _mdm_system_python_framework_tree_properties)"
  _python_full_impl="$(declare -f _mdm_system_python_framework_full_spec)"
  _python_copy_impl="$(declare -f _mdm_system_python_copy_tool)"
  _python_rebind_impl="$(declare -f _mdm_system_python_cache_rebound)"
  _python_accessor_impl="$(declare -f _mdm_system_python)"
  _external_transaction_impl="$(declare -f _mdm_external_transaction_invoke)"
  _target_calls="$(/usr/bin/grep -cF '$(_mdm_target_system_python)' \
    "$PROJECT_DIR/mdm/install-mdm.sh")"
  if [[ "$(_mdm_system_python_codesign_requirement)" \
      == '=identifier "com.apple.python3" and anchor apple' \
    && "$_clt_present_impl" != *xcode-select* \
    && "$_python_validate_impl" == *'--verify --deep --strict -R'* \
    && "$_python_validate_impl" == *'_mdm_system_python_resource_envelope_v2'* \
    && "$_private_validate_impl" == *'--verify --deep --strict -R'* \
    && "$_private_validate_impl" == *'_mdm_system_python_resource_envelope_v2'* \
    && "$_python_tree_impl" == *'-flags +uchg'* \
    && "$_python_full_impl" == *'nlink'* \
    && "$_python_full_impl" == *'xattrsdigest'* \
    && "$_python_copy_impl" == *'--noclone --rsrc --extattr --qtn --acl'* \
    && "$_python_copy_impl" == *'--nopersistRootless'* \
    && "$_python_rebind_impl" == *'_MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL'* \
    && "$_python_accessor_impl" != *'_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK'* \
    && "$_external_transaction_impl" == *'_mdm_target_system_python'* \
    && "$_external_transaction_impl" == *'_mdm_system_python'* \
    && "$_target_calls" -eq 4 ]]; then
    pass "mdm-install: CLT Pythonは0700 private full-sealと4 user callsiteへ限定"
  else
    fail "mdm-install: CLT Pythonがshim/Xcode/self-selected署名へfallback"
  fi
)
(
  _envelope_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE="$_envelope_tmp/workspace"
  _MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK="$_envelope_tmp/source/Python3.framework"
  _MDM_SYSTEM_PYTHON_SOURCE_LINK="$_envelope_tmp/source/usr/bin/python3"
  /bin/mkdir -p "$_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE" \
    "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK" \
    "$(/usr/bin/dirname "$_MDM_SYSTEM_PYTHON_SOURCE_LINK")"
  _envelope_mode=v2
  _mdm_system_python_codesign() {
    if [[ "$1" == -dvv ]]; then
      case "$_envelope_mode" in
        v2) printf '%s\n' 'Sealed Resources version=2 rules=13 files=42' >&2 ;;
        v1) printf '%s\n' 'Sealed Resources version=1 rules=13 files=42' >&2 ;;
        missing) printf '%s\n' 'Executable=fixture' >&2 ;;
        stdout) printf '%s\n' 'unexpected stdout'
          printf '%s\n' 'Sealed Resources version=2 rules=13 files=42' >&2 ;;
        failure) return 97 ;;
      esac
    fi
  }
  _v2_ok=false
  _mdm_system_python_resource_envelope_v2 \
    "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK" && _v2_ok=true
  _envelope_rejects=true
  for _envelope_mode in v1 missing stdout failure; do
    _mdm_system_python_resource_envelope_v2 \
      "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK" >/dev/null 2>&1 \
      && _envelope_rejects=false
  done

  _envelope_mode=v2
  _mdm_system_python_dir_chain_trusted() { return 0; }
  _mdm_auth_expected_uid() { /usr/bin/id -u; }
  _mdm_stat_gid() { /usr/bin/id -g; }
  _mdm_system_python_framework_tree_properties() { return 0; }
  _mdm_system_python_dir_identity() { printf 'framework-identity'; }
  _mdm_system_python_link_trusted() { printf -v "$2" '%s' link-identity; }
  _dynamic_resolve_calls=0
  _mdm_system_python_resolve_fixed_link() {
    _dynamic_resolve_calls=$((_dynamic_resolve_calls + 1))
    printf -v "$1" '%s' \
      "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK/Versions/3.9/bin/python3.9"
    printf -v "$2" '%s' resolution-identity
  }
  _mdm_system_python_target_trusted() {
    printf -v "$2" '%s' target-identity
    printf -v "$3" '%s' 0:1:0755
  }
  _dynamic_path=""; _dynamic_framework=""; _dynamic_target=""
  _dynamic_ok=false
  _mdm_validate_system_python _dynamic_path _dynamic_framework _dynamic_target \
    && [[ "$_dynamic_path" == \
      "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK/Versions/3.9/bin/python3.9" \
      && "$_dynamic_framework" == framework-identity \
      && "$_dynamic_target" == target-identity ]] && _dynamic_ok=true
  if [[ "$_v2_ok" == true && "$_envelope_rejects" == true \
    && "$_dynamic_ok" == true && "$_dynamic_resolve_calls" -eq 2 ]]; then
    pass "mdm-install: resource envelope v2後にsource identityを再束縛"
  else
    fail "mdm-install: codesign envelopeまたはsource再束縛契約が不正"
  fi
  /bin/rm -rf "$_envelope_tmp"
)
(
  _MDM_TEST_MODE=0
  _MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL=""
  _MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK=/private/fixture/Python3.framework
  _baseline_full_called=false
  _mdm_system_python_private_identity_matches() { return 0; }
  _mdm_system_python_runtime_uid() { printf '0'; }
  _mdm_stat_uid() { printf '0'; }
  _mdm_stat_gid() { printf '0'; }
  _mdm_system_python_framework_tree_properties() { return 97; }
  _mdm_system_python_framework_full_seal() {
    _baseline_full_called=true
    printf 'unexpected'
  }
  _baseline_rejected=false
  _mdm_system_python_cache_baseline >/dev/null 2>&1 \
    || _baseline_rejected=true

  _private_validation_calls=0
  _mdm_system_python_create_workspace() {
    _MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE=/private/fixture/workspace
    _MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE_IDENTITY=workspace-identity
  }
  _mdm_validate_system_python() {
    printf -v "$1" '%s' \
      "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK/Versions/3.9/bin/python3.9"
    printf -v "$2" '%s' source-framework-identity
    printf -v "$3" '%s' source-target-identity
  }
  _mdm_system_python_copy_framework() { return 98; }
  _mdm_validate_private_system_python() {
    _private_validation_calls=$((_private_validation_calls + 1))
  }
  _copy_failure_rejected=false
  _mdm_initialize_system_python >/dev/null 2>&1 \
    || _copy_failure_rejected=true
  if [[ "$_baseline_rejected" == true \
    && "$_baseline_full_called" == false \
    && "$_copy_failure_rejected" == true \
    && "$_private_validation_calls" -eq 0 \
    && -z "$_MDM_SYSTEM_PYTHON_TARGET_PATH" ]]; then
    pass "mdm-install: self-test後property driftとcopy失敗を未publishで拒否"
  else
    fail "mdm-install: baseline/copy failureがunsafe runtimeを公開"
  fi
)
(
  _MDM_TEST_MODE=0
  _init_failure_unpublished=true
  for _init_failure_mode in self-test baseline; do
    _MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE=""
    _MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE_IDENTITY=""
    _mdm_clear_system_python_runtime_state
    _MDM_FAILURE_ROLLBACK_ACTIVE=0
    _MDM_FAILURE_ROLLBACK_SOURCE_PATH=""
    _MDM_FAILURE_ROLLBACK_SOURCE_FRAMEWORK_IDENTITY=""
    _MDM_FAILURE_ROLLBACK_SOURCE_TARGET_IDENTITY=""
    _mdm_system_python_create_workspace() {
      _MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE=/private/fixture/workspace
      _MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE_IDENTITY=workspace-identity
    }
    _mdm_validate_system_python() {
      printf -v "$1" '%s' \
        "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK/Versions/3.9/bin/python3.9"
      printf -v "$2" '%s' source-framework-identity
      printf -v "$3" '%s' source-target-identity
    }
    _mdm_system_python_copy_framework() { return 0; }
    _mdm_validate_private_system_python() {
      printf -v "$5" '%s' \
        "$1/Versions/3.9/bin/python3.9"
      printf -v "$6" '%s' private-framework-identity
      printf -v "$7" '%s' private-target-identity
    }
    _mdm_system_python_private_self_test() {
      [[ "$_init_failure_mode" != self-test ]]
    }
    _mdm_system_python_cache_baseline() {
      [[ "$_init_failure_mode" != baseline ]] || return 98
      _MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL="$(printf '%064d' 0)"
    }
    _init_failure_rc=0
    _mdm_initialize_system_python >/dev/null 2>&1 \
      || _init_failure_rc=$?
    _runtime_failure_rc=0
    _mdm_system_python >/dev/null 2>&1 || _runtime_failure_rc=$?
    _target_failure_rc=0
    _mdm_target_system_python >/dev/null 2>&1 || _target_failure_rc=$?
    if [[ "$_init_failure_rc" -eq 0 \
      || "$_runtime_failure_rc" -eq 0 \
      || "$_target_failure_rc" -eq 0 \
      || -n "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH" \
      || -n "$_MDM_SYSTEM_PYTHON_TARGET_PATH" \
      || -n "$_MDM_FAILURE_ROLLBACK_SOURCE_PATH" ]]; then
      _init_failure_unpublished=false
    fi
  done
  _MDM_TEST_MODE=1
  _MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE=""
  _MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE_IDENTITY=""
  _mdm_clear_system_python_runtime_state
  _test_init_failure_rc=0
  _mdm_initialize_system_python >/dev/null 2>&1 \
    || _test_init_failure_rc=$?
  if [[ "$_test_init_failure_rc" -eq 0 \
    || -n "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH" \
    || -n "$_MDM_SYSTEM_PYTHON_TARGET_PATH" ]]; then
    _init_failure_unpublished=false
  fi
  if [[ "$_init_failure_unpublished" == true ]]; then
    pass "mdm-install: Python self-test/baseline失敗時は全modeで未publish"
  else
    fail "mdm-install: Python初期化失敗後に未承認runtimeを参照可能"
  fi
)
(
  _MDM_TEST_MODE=0
  _MDM_TRANSACTION_STATE=active
  _MDM_FAILURE_ROLLBACK_ACTIVE=1
  _MDM_FAILURE_ROLLBACK_SOURCE_PATH=/fixed/clt/python3
  _MDM_FAILURE_ROLLBACK_SOURCE_FRAMEWORK_IDENTITY=source-framework
  _MDM_FAILURE_ROLLBACK_SOURCE_TARGET_IDENTITY=source-target
  _MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK=/private/old/Python3.framework
  _MDM_SYSTEM_PYTHON_PRIVATE_PATH=/private/old/Python3.framework/Versions/3.9/bin/python3.9
  _recovery_mode=success
  _mdm_failure_rollback_source_python() { printf '%s' /fixed/clt/python3; }
  _mdm_cleanup_system_python_workspace() {
    _mdm_clear_system_python_runtime_state
  }
  _mdm_initialize_system_python() {
    [[ "$_recovery_mode" == success ]] || return 97
    _MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK=/private/new/Python3.framework
    _MDM_SYSTEM_PYTHON_PRIVATE_PATH=/private/new/Python3.framework/Versions/3.9/bin/python3.9
  }
  _mdm_system_python_cache_rebound() {
    [[ "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH" == /private/new/* ]]
  }
  _fresh_ok=false
  _mdm_system_python_recover_after_rebound_failure \
    && [[ "$(_mdm_system_python)" == /private/new/* ]] && _fresh_ok=true
  _MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK=/private/old/Python3.framework
  _MDM_SYSTEM_PYTHON_PRIVATE_PATH=/private/old/Python3.framework/Versions/3.9/bin/python3.9
  _recovery_mode=failure
  _fresh_failure_rejected=false
  _mdm_system_python_recover_after_rebound_failure >/dev/null 2>&1 \
    || _fresh_failure_rejected=true
  _failure_fallback="$(_mdm_system_python 2>/dev/null || true)"
  if [[ "$_fresh_ok" == true && "$_fresh_failure_rejected" == true \
    && "$_failure_fallback" == /fixed/clt/python3 ]]; then
    pass "mdm-install: rebound recoveryはfresh private優先・失敗時source fallback"
  else
    fail "mdm-install: rebound recoveryが旧privateを再利用またはfallback喪失"
  fi
)
(
  _fallback_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _fallback_log="$_fallback_tmp/validate.log"
  _MDM_TEST_MODE=0
  _MDM_TRANSACTION_STATE=active
  _MDM_FAILURE_ROLLBACK_ACTIVE=1
  _MDM_FAILURE_ROLLBACK_FRESH_PRIVATE=0
  _MDM_FAILURE_ROLLBACK_SOURCE_PATH="$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK/Versions/3.9/bin/python3.9"
  _MDM_FAILURE_ROLLBACK_SOURCE_FRAMEWORK_IDENTITY=source-framework
  _MDM_FAILURE_ROLLBACK_SOURCE_TARGET_IDENTITY=source-target
  _MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK=/private/old/Python3.framework
  _MDM_SYSTEM_PYTHON_PRIVATE_PATH=/private/old/Python3.framework/Versions/3.9/bin/python3.9
  _validation_mode=stable
  _mdm_auth_tmp_base() { printf '%s' /private/tmp; }
  _mdm_auth_base_trusted() { return 0; }
  _mdm_validate_system_python() {
    printf 'validate\n' >> "$_fallback_log"
    printf -v "$1" '%s' "$_MDM_FAILURE_ROLLBACK_SOURCE_PATH"
    printf -v "$2" '%s' "$_MDM_FAILURE_ROLLBACK_SOURCE_FRAMEWORK_IDENTITY"
    if [[ "$_validation_mode" == stable ]]; then
      printf -v "$3" '%s' "$_MDM_FAILURE_ROLLBACK_SOURCE_TARGET_IDENTITY"
    else
      printf -v "$3" '%s' drifted-target
    fi
  }
  _fallback_root="$(_mdm_system_python)"
  _fallback_target="$(_mdm_target_system_python)"
  _validation_mode=drift
  _fallback_drift_rejected=false
  _mdm_system_python >/dev/null 2>&1 || _fallback_drift_rejected=true
  _fallback_calls="$(/usr/bin/wc -l < "$_fallback_log" | /usr/bin/tr -d ' ')"
  _fallback_impl="$(declare -f _mdm_failure_rollback_source_python)"
  if [[ "$_fallback_root" == "$_MDM_FAILURE_ROLLBACK_SOURCE_PATH" \
    && "$_fallback_target" == "$_MDM_FAILURE_ROLLBACK_SOURCE_PATH" \
    && "$_fallback_calls" -eq 3 && "$_fallback_drift_rejected" == true \
    && "$_fallback_impl" == *'_mdm_validate_system_python'* \
    && "$_fallback_impl" == *'_mdm_auth_base_trusted'* ]]; then
    pass "mdm-install: failure-only sourceは各呼出しでfull再検証・identity再束縛"
  else
    fail "mdm-install: failure-only sourceの再検証または旧private遮断が不正"
  fi
  /bin/rm -rf "$_fallback_tmp"
)
(
  _main_behavior_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"

  # Exercise the production entry point while replacing only its external
  # boundaries. The trace therefore proves mdm_main's real success/failure
  # control flow instead of merely matching its function text.
  _mdm_main_behavior_fixture() { # <success|rebound-failure> <trace>
    local _main_mode="$1" _main_trace_file="$2"
    local _main_home="$_main_behavior_tmp/home"
    local _main_init_calls=0 _main_source_calls=0
    /bin/mkdir -p "$_main_home"

    _main_trace() { printf '%s\n' "$1" >> "$_main_trace_file"; }
    _mdm_supported_macos_host() { return 0; }
    _mdm_config_path() { printf '%s' /fixture/mdm-config.conf; }
    _mdm_root_config_apply() { return 0; }
    _mdm_apply_mdm_defaults() {
      KIT_MDM_DRY_RUN=false
      PROFILE=standard
      LANGUAGE=en
    }
    _mdm_main_euid() { printf '%s' 0; }
    _mdm_expected_policy_input_valid() { return 0; }
    _mdm_resolve_target_username() { printf -v "$1" '%s' jane; }
    _mdm_bind_target_identity_tuple() {
      printf '501\tAAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'
    }
    _mdm_bind_canonical_target_username() {
      printf -v "$1" '%s' jane
    }
    mdm_validate_user_home() { printf '%s' "$_main_home"; }
    _mdm_user_shell() { printf '%s' /bin/zsh; }
    _mdm_validate_semantic_config() { return 0; }
    _mdm_acquire_run_lock() { return 0; }
    _mdm_setup_log_file() {
      MDM_LOG_FILE="$_main_behavior_tmp/mdm.log"
      return 0
    }
    mdm_log() { :; }
    _mdm_ensure_clt() { return 0; }
    _mdm_brew_usable_for_user() { return 0; }
    mdm_prereq_plan() { printf '%s' skip; }
    _mdm_transaction_begin() {
      _MDM_TRANSACTION_STATE=active
      _main_trace transaction-begin
    }
    _mdm_run_user_phase() {
      _main_trace user-phase
      return 0
    }
    _mdm_revalidate_target_identity() {
      _main_trace identity
      return 0
    }
    _mdm_capture_postcondition() {
      _main_trace postcondition
      return 0
    }
    _mdm_attest_components() {
      _main_trace attest
      return 0
    }
    _mdm_persist_managed_history() {
      _main_trace history
      return 0
    }
    _mdm_revalidate_success_state() {
      _main_trace revalidate
      return 0
    }
    _mdm_initialize_system_python() {
      _main_init_calls=$((_main_init_calls + 1))
      if [[ "$_main_mode" == rebound-failure \
        && "$_main_init_calls" -gt 1 ]]; then
        _main_trace \
          "fresh-recovery:active=${_MDM_FAILURE_ROLLBACK_ACTIVE:-0}"
        return 97
      fi
      return 0
    }
    _mdm_system_python_cache_rebound() {
      _main_trace "seal:active=${_MDM_FAILURE_ROLLBACK_ACTIVE:-0}"
      [[ "$_main_mode" == success ]]
    }
    _mdm_arm_transient_signal_cleanup() {
      _main_trace \
        "signal-cleanup-rearm:active=${_MDM_FAILURE_ROLLBACK_ACTIVE:-0}:state=${_MDM_TRANSACTION_STATE:-idle}"
    }
    _mdm_failure_rollback_source_python() {
      _main_source_calls=$((_main_source_calls + 1))
      _main_trace \
        "source-${_main_source_calls}:active=${_MDM_FAILURE_ROLLBACK_ACTIVE:-0}"
      printf '%s' /fixed/clt/python3
    }
    _mdm_cleanup_system_python_workspace() {
      _main_trace \
        "recovery-clean:active=${_MDM_FAILURE_ROLLBACK_ACTIVE:-0}"
      return 0
    }
    _mdm_transaction_abort() {
      local _rollback_python=""
      case "${_MDM_TRANSACTION_STATE:-idle}" in
        active|partial)
          _rollback_python="$(_mdm_system_python)" || return 1
          _main_trace \
            "abort:active=${_MDM_FAILURE_ROLLBACK_ACTIVE:-0}:python=$_rollback_python"
          _MDM_TRANSACTION_STATE=aborted ;;
        *) : ;;
      esac
      return 0
    }
    _mdm_transaction_mark_partial() { _MDM_TRANSACTION_STATE=partial; }
    _mdm_arm_transient_cleanup() {
      _main_trace \
        "cleanup-rearm:active=${_MDM_FAILURE_ROLLBACK_ACTIVE:-0}:state=${_MDM_TRANSACTION_STATE:-idle}"
    }
    _mdm_receipt_dir_for() { printf '%s' "$_main_behavior_tmp/receipts"; }
    mdm_receipt_prepare() {
      _main_trace \
        "finish:$2:active=${_MDM_FAILURE_ROLLBACK_ACTIVE:-0}:code=$3"
      [[ "$2" == success && "$3" -eq 0 ]]
    }
    _mdm_receipt_prepared_ready() { return 0; }
    _mdm_transaction_ready_to_commit() { return 0; }
    _mdm_receipt_publish_prepared() {
      _MDM_RECEIPT_PUBLISHED=1
      return 0
    }
    _mdm_receipt_discard_prepared() { return 0; }
    mdm_receipt_write() {
      _main_trace \
        "finish:$2:active=${_MDM_FAILURE_ROLLBACK_ACTIVE:-0}:code=$3"
      return 0
    }
    _mdm_transaction_commit() {
      _main_trace \
        "commit:active=${_MDM_FAILURE_ROLLBACK_ACTIVE:-0}"
      _MDM_TRANSACTION_STATE=committed
    }

    _MDM_TEST_MODE=1
    _MDM_TRANSACTION_STATE=idle
    _MDM_FAILURE_ROLLBACK_ACTIVE=0
    _MDM_FAILURE_ROLLBACK_FRESH_PRIVATE=0
    _MDM_RECEIPT_PUBLISHED=0
    _MDM_SYSTEM_PYTHON_REBOUND_PENDING_SIGNAL=""
    mdm_main
  }

  _main_success_trace="$_main_behavior_tmp/success.trace"
  _main_success_expected="$_main_behavior_tmp/success.expected"
  _main_success_rc=0
  (_mdm_main_behavior_fixture success "$_main_success_trace") \
    >/dev/null 2>&1 || _main_success_rc=$?
  printf '%s\n' \
    transaction-begin \
    user-phase \
    identity \
    postcondition \
    attest \
    history \
    revalidate \
    'seal:active=1' \
    'signal-cleanup-rearm:active=1:state=active' \
    'finish:success:active=0:code=0' \
    'commit:active=0' > "$_main_success_expected"
  if [[ "$_main_success_rc" -eq 0 ]] \
    && /usr/bin/cmp -s "$_main_success_expected" "$_main_success_trace"; then
    pass "mdm-install: mdm_main successは全検証後にfallback解除・finish・commit"
  else
    fail "mdm-install: mdm_main successの実行順またはfallback状態が不正"
  fi

  _main_failure_trace="$_main_behavior_tmp/rebound-failure.trace"
  _main_failure_expected="$_main_behavior_tmp/rebound-failure.expected"
  _main_failure_rc=0
  (_mdm_main_behavior_fixture rebound-failure "$_main_failure_trace") \
    >/dev/null 2>&1 || _main_failure_rc=$?
  printf '%s\n' \
    transaction-begin \
    user-phase \
    identity \
    postcondition \
    attest \
    history \
    revalidate \
    'seal:active=1' \
    'signal-cleanup-rearm:active=1:state=active' \
    'source-1:active=1' \
    'recovery-clean:active=1' \
    'fresh-recovery:active=1' \
    'source-2:active=1' \
    'abort:active=1:python=/fixed/clt/python3' \
    'cleanup-rearm:active=1:state=aborted' \
    "finish:failure:active=1:code=$MDM_EXIT_PREREQ" \
    > "$_main_failure_expected"
  if [[ "$_main_failure_rc" -eq "$MDM_EXIT_PREREQ" ]] \
    && /usr/bin/cmp -s "$_main_failure_expected" "$_main_failure_trace"; then
    pass "mdm-install: mdm_main final seal失敗はfresh失敗後もsourceでrollback"
  else
    fail "mdm-install: mdm_main rebound failureのfallback/rollback順序が不正"
  fi
  /bin/rm -rf "$_main_behavior_tmp"
)
(
  _workspace_probe="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _MDM_TEST_MODE=1
  export MDM_SYSTEM_PYTHON_TMP_BASE_OVERRIDE="$_workspace_probe"
  _mdm_system_python_dir_identity() { return 97; }
  _identity_rejected=false
  _mdm_system_python_create_workspace >/dev/null 2>&1 \
    || _identity_rejected=true
  _identity_orphans="$(/usr/bin/find "$_workspace_probe" -maxdepth 1 \
    -name 'claude-kit-mdm-python.*' -print -quit)"
  if [[ "$_identity_rejected" == true && -z "$_identity_orphans" \
    && -z "$_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE" ]]; then
    pass "mdm-install: workspace identity初回失敗もorphanなし"
  else
    fail "mdm-install: workspace identity初回失敗でorphan残留"
  fi
  /bin/rm -rf "$_workspace_probe"
)
(
  _signal_probe="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _signal_rc=0
  /bin/bash --noprofile --norc -c '
    MDM_SOURCE_ONLY=1 source "$1"
    _MDM_TEST_MODE=1
    MDM_SYSTEM_PYTHON_TMP_BASE_OVERRIDE="$2"
    _mdm_arm_transient_cleanup() {
      /bin/kill -TERM "$$"
      trap '\''_mdm_cleanup_transient_checkouts'\'' EXIT
      trap '\''_mdm_cleanup_transient_checkouts HUP; exit 129'\'' HUP
      trap '\''_mdm_cleanup_transient_checkouts INT; exit 130'\'' INT
      trap '\''_mdm_cleanup_transient_checkouts TERM; exit 143'\'' TERM
    }
    _mdm_system_python_create_workspace
    : > "$3"
  ' mdm-python-signal "$PROJECT_DIR/mdm/install-mdm.sh" \
    "$_signal_probe" "$_signal_probe/survived" >/dev/null 2>&1 \
    || _signal_rc=$?
  _signal_orphans="$(/usr/bin/find "$_signal_probe" -maxdepth 1 \
    -name 'claude-kit-mdm-python.*' -print -quit)"
  if [[ "$_signal_rc" -eq 143 && ! -e "$_signal_probe/survived" \
    && -z "$_signal_orphans" ]]; then
    pass "mdm-install: workspace pending TERMをtrap切替後に再配送"
  else
    fail "mdm-install: workspace pending TERMを飲み込み"
  fi
  /bin/rm -rf "$_signal_probe"
)
if _mdm_is_darwin; then
  (
    _tree_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
    _MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE="$_tree_tmp/workspace"
    _tree_framework="$_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE/Python3.framework"
    _tree_binary="$_tree_framework/Versions/3.9/bin/python3.9"
    _tree_site="$_tree_framework/Versions/3.9/lib/python3.9/site-packages"
    /bin/mkdir -p "$(/usr/bin/dirname "$_tree_binary")" "$_tree_site"
    /bin/chmod 0700 "$_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE"
    printf '#!/bin/sh\nexit 0\n' > "$_tree_binary"
    printf 'fixture\n' > "$_tree_site/module.py"
    /bin/chmod 0755 "$_tree_binary"
    /bin/ln -s Versions/3.9/bin/python3.9 \
      "$_tree_framework/Python3"
    _tree_uid="$(/usr/bin/id -u)"
    _tree_gid="$(_mdm_stat_gid "$_tree_framework")"
    _tree_positive=false
    _mdm_system_python_framework_tree_properties \
      "$_tree_framework" "$_tree_uid" "$_tree_gid" true \
      && _tree_positive=true
    _tree_seal_before="$(_mdm_system_python_framework_full_seal \
      "$_tree_framework")"
    /bin/chmod 0777 "$_tree_site"
    _tree_writable_rejected=false
    _mdm_system_python_framework_tree_properties \
      "$_tree_framework" "$_tree_uid" "$_tree_gid" true >/dev/null 2>&1 \
      || _tree_writable_rejected=true
    /bin/chmod 0755 "$_tree_site"
    /bin/rm -f "$_tree_framework/Python3"
    printf 'outside\n' > "$_tree_tmp/outside"
    /bin/ln -s "$_tree_tmp/outside" "$_tree_framework/Python3"
    _tree_escape_rejected=false
    _mdm_system_python_framework_tree_properties \
      "$_tree_framework" "$_tree_uid" "$_tree_gid" true >/dev/null 2>&1 \
      || _tree_escape_rejected=true
    /bin/rm -f "$_tree_framework/Python3"
    /bin/ln -s Versions/3.9/bin/python3.9 \
      "$_tree_framework/Python3"
    _tree_seal_same="$(_mdm_system_python_framework_full_seal \
      "$_tree_framework")"
    printf 'mutated\n' >> "$_tree_site/module.py"
    _tree_seal_after="$(_mdm_system_python_framework_full_seal \
      "$_tree_framework")"
    _tree_seal_drift=false
    [[ "$_tree_seal_same" == "$_tree_seal_before" \
      && "$_tree_seal_after" != "$_tree_seal_before" ]] \
      && _tree_seal_drift=true
    _tree_acl_available=false; _tree_acl_rejected=false
    if /bin/chmod +a 'everyone deny write' "$_tree_site/module.py" 2>/dev/null; then
      _tree_acl_available=true
      _mdm_system_python_framework_tree_properties \
        "$_tree_framework" "$_tree_uid" "$_tree_gid" true >/dev/null 2>&1 \
        || _tree_acl_rejected=true
      /bin/chmod -N "$_tree_site/module.py" 2>/dev/null || true
    fi
    _tree_flags_available=false; _tree_flags_rejected=false
    if /usr/bin/chflags uchg,hidden "$_tree_site/module.py" 2>/dev/null; then
      _tree_flags_available=true
      _mdm_system_python_framework_tree_properties \
        "$_tree_framework" "$_tree_uid" "$_tree_gid" true >/dev/null 2>&1 \
        || _tree_flags_rejected=true
      /usr/bin/chflags nouchg,nohidden "$_tree_site/module.py" 2>/dev/null || true
    fi
    if [[ "$_tree_positive" == true && "$_tree_writable_rejected" == true \
      && "$_tree_escape_rejected" == true \
      && "$_tree_seal_drift" == true ]]; then
      pass "mdm-install: CLT framework全treeのtrustとsymlink sealを強制"
    else
      fail "mdm-install: CLT framework全treeのtrust検査が不正"
    fi
    if [[ "$_tree_acl_available" == true && "$_tree_acl_rejected" == true ]]; then
      pass "mdm-install: CLT framework内ACLを拒否"
    elif [[ "$_tree_acl_available" == false ]]; then
      skip "mdm-install: CLT framework内ACLを拒否" "ACL fixture unavailable"
    else
      fail "mdm-install: CLT framework内ACLを受理"
    fi
    if [[ "$_tree_flags_available" == true \
      && "$_tree_flags_rejected" == true ]]; then
      pass "mdm-install: CLT framework内の複合immutable flagsを拒否"
    elif [[ "$_tree_flags_available" == false ]]; then
      skip "mdm-install: CLT framework内の複合immutable flagsを拒否" \
        "chflags fixture unavailable"
    else
      fail "mdm-install: CLT framework内の複合immutable flagsを受理"
    fi
    /bin/rm -rf "$_tree_tmp"
  )
  (
    _MDM_TEST_MODE=0
    MDM_SYSTEM_PYTHON_TMP_BASE_OVERRIDE="${MDM_TEST_TMP_ROOT:-}"
    _MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE=""
    _MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE_IDENTITY=""
    _mdm_clear_system_python_runtime_state
    _real_init=false
    _mdm_initialize_system_python && _real_init=true
    _real_python="$_MDM_SYSTEM_PYTHON_PRIVATE_PATH"
    _real_framework="$_MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK"
    _real_workspace="$_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE"
    _real_seal="$_MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL"
    _target_python="$(_mdm_target_system_python 2>/dev/null || true)"
    _mdm_system_python_codesign() { return 97; }
    _cached_python="$(_mdm_system_python 2>/dev/null || true)"
    _rebound_ok=false
    _mdm_system_python_cache_rebound && _rebound_ok=true
    _MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL="$(printf '0%.0s' {1..64})"
    _drift_rejected=false
    _mdm_system_python_cache_rebound >/dev/null 2>&1 || _drift_rejected=true
    _MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL="$_real_seal"
    _exec_ok=false
    [[ -n "$_real_python" ]] \
      && "$_real_python" -I -B -S -c 'raise SystemExit(0)' && _exec_ok=true
    case "$_real_python" in
      "$_real_framework"/Versions/*/bin/python*) _shape_ok=true ;;
      *) _shape_ok=false ;;
    esac
    _mode_ok=false
    [[ "$(_mdm_launcher_stat_mode "$_real_workspace")" == 0700 ]] \
      && _mode_ok=true
    _mdm_cleanup_system_python_workspace
    _cleanup_ok=false
    [[ ! -e "$_real_workspace" \
      && -z "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH" \
      && -z "$_MDM_SYSTEM_PYTHON_TARGET_PATH" ]] && _cleanup_ok=true
    if [[ "$_real_init" == true && "$_cached_python" == "$_real_python" \
      && "$_rebound_ok" == true && "$_drift_rejected" == true \
      && "$_exec_ok" == true && "$_shape_ok" == true \
      && "$_mode_ok" == true && "$_cleanup_ok" == true \
      && "$_target_python" == "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK"/* \
      && "$_real_python" != "$_target_python" \
      && "${#_real_seal}" -eq 64 ]]; then
      pass "mdm-install: 実CLT Pythonを0700 private sealへ固定しcleanup"
    else
      fail "mdm-install: 実CLT Pythonの署名/path/cache再束縛に失敗"
    fi
  )
else
  skip "mdm-install: 実CLT Pythonを署名検証しcache越し再束縛で直接実行" \
    "macOS CLT only"
fi
(
  _clt_tmpd="$(mktemp -d)"
  export MDM_CLT_MARKER_OVERRIDE="$_clt_tmpd/marker"
  export KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=true
  _clt_checks=0
  _mdm_clt_present() {
    _clt_checks=$((_clt_checks + 1))
    [[ "$_clt_checks" -gt 1 ]]
  }
  softwareupdate() {
    if [[ "$1" == "-l" ]]; then
      printf '%s\n' '* Label: Command Line Tools for Xcode 16.4-16.4'
    else
      printf '%s\n' "$*" > "$_clt_tmpd/install-args"
    fi
  }
  _clt_rc=0
  _mdm_ensure_clt >/dev/null 2>&1 || _clt_rc=$?
  if [[ "$_clt_rc" -eq 0 ]] \
    && [[ "$(< "$_clt_tmpd/install-args")" == '-i Command Line Tools for Xcode 16.4-16.4 --verbose' ]] \
    && [[ ! -e "$MDM_CLT_MARKER_OVERRIDE" ]]; then
    pass "mdm-install: 正規化した CLT label を softwareupdate -i へ渡す"
  else
    fail "mdm-install: softwareupdate CLT positive 経路が不正 (rc=$_clt_rc)"
  fi
  rm -rf "$_clt_tmpd"
)
(
  _clt_timeout_root="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _MDM_TEST_MODE=1
  MDM_EUID_OVERRIDE=501
  MDM_TIMEOUT_OVERRIDE_SECONDS=1
  KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=true
  _clt_timeout_ok=true
  _mdm_clt_present() { return 1; }
  softwareupdate() {
    printf '%s\n' "$*" >> "$_clt_timeout_dir/calls"
    if [[ "$_clt_timeout_mode" == list && "$1" == -l ]] \
      || [[ "$_clt_timeout_mode" == install && "$1" == -i ]]; then
      trap '' TERM
      while :; do /bin/sleep 1; done
    fi
    printf '%s\n' '* Label: Command Line Tools for Xcode 16.4-16.4'
  }
  for _clt_timeout_mode in list install; do
    _clt_timeout_dir="$_clt_timeout_root/$_clt_timeout_mode"
    /bin/mkdir "$_clt_timeout_dir"
    TMPDIR="$_clt_timeout_dir"
    MDM_CLT_MARKER_OVERRIDE="$_clt_timeout_dir/marker"
    _clt_timeout_started=$SECONDS
    _clt_timeout_rc=0
    _mdm_ensure_clt >/dev/null 2>&1 || _clt_timeout_rc=$?
    _clt_timeout_elapsed=$((SECONDS - _clt_timeout_started))
    _clt_expected_calls=1
    [[ "$_clt_timeout_mode" == install ]] && _clt_expected_calls=2
    if [[ "$_clt_timeout_rc" -eq 0 || "$_clt_timeout_elapsed" -gt 5 \
      || -e "$MDM_CLT_MARKER_OVERRIDE" \
      || "$(/usr/bin/wc -l < "$_clt_timeout_dir/calls" | /usr/bin/tr -d ' ')" \
        -ne "$_clt_expected_calls" ]] \
      || /usr/bin/find "$_clt_timeout_dir" -maxdepth 1 \
        -name 'claude-kit-mdm-timeout.*' -print -quit | /usr/bin/grep -q .; then
      _clt_timeout_ok=false
    fi
  done
  if [[ "$_clt_timeout_ok" == true ]]; then
    pass "mdm-install: CLT list/install は120/1200秒境界で停止し marker cleanup"
  else
    fail "mdm-install: CLT list/install timeout または cleanup が不正"
  fi
  /bin/rm -rf "$_clt_timeout_root"
)
(
  _mk_tmpd="$(mktemp -d)"
  printf 'victim\n' > "$_mk_tmpd/victim"
  export MDM_CLT_MARKER_OVERRIDE="$_mk_tmpd/marker"
  ln -s "$_mk_tmpd/victim" "$MDM_CLT_MARKER_OVERRIDE"
  _rc=0
  _mdm_create_clt_marker >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 && ! -L "$MDM_CLT_MARKER_OVERRIDE" && -f "$MDM_CLT_MARKER_OVERRIDE" ]] \
     && [[ "$(cat "$_mk_tmpd/victim")" == "victim" ]]; then
    pass "mdm-install: CLT marker が先置き symlink を辿らず実体作成される"
  else
    fail "mdm-install: CLT marker 作成が symlink を辿る/失敗する (rc=$_rc)"
  fi
  rm -rf "$_mk_tmpd"
)
(
  _mk_tmpd="$(mktemp -d)"
  export MDM_CLT_MARKER_OVERRIDE="$_mk_tmpd/marker"
  _rc=0
  _mdm_create_clt_marker >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq 0 && -f "$MDM_CLT_MARKER_OVERRIDE" ]] \
    && pass "mdm-install: CLT marker の通常作成が成功する" \
    || fail "mdm-install: CLT marker の通常作成に失敗 (rc=$_rc)"
  rm -rf "$_mk_tmpd"
)
(
  _cleanup_tmp="$(mktemp -d)"
  export MDM_EUID_OVERRIDE=501 TMPDIR="$_cleanup_tmp"
  export MDM_BREW_PLIST_OVERRIDE="$_cleanup_tmp/homebrew.plist"
  export MDM_CLT_MARKER_OVERRIDE="$_cleanup_tmp/clt.marker"
  _MDM_ACTIVE_BREW_PKG="$_cleanup_tmp/mdm-homebrew-pkg.fixture"
  _MDM_ACTIVE_BREW_PLIST="$MDM_BREW_PLIST_OVERRIDE"
  _MDM_ACTIVE_CLT_MARKER="$MDM_CLT_MARKER_OVERRIDE"
  : > "$_MDM_ACTIVE_BREW_PKG"; : > "$_MDM_ACTIVE_BREW_PLIST"; : > "$_MDM_ACTIVE_CLT_MARKER"
  _mdm_arm_transient_cleanup
  _mdm_cleanup_transient_checkouts
  if [[ ! -e "$_cleanup_tmp/mdm-homebrew-pkg.fixture" \
    && ! -e "$MDM_BREW_PLIST_OVERRIDE" && ! -e "$MDM_CLT_MARKER_OVERRIDE" ]] \
    && [[ -z "$_MDM_ACTIVE_BREW_PKG$_MDM_ACTIVE_BREW_PLIST$_MDM_ACTIVE_CLT_MARKER" ]]; then
    pass "mdm-install: pkg/plist/CLT marker を統一 EXIT/INT/TERM cleanup"
  else
    fail "mdm-install: prerequisite 一時 artifact cleanup が不完全"
  fi
  rm -rf "$_cleanup_tmp"
)
(
  _cleanup_signal_tmp="$(mktemp -d)"
  _cleanup_expected=$'timeout-supervisor\ndrop-supervisor\ntransaction\nprereq\nauth-entry\ndryrun\nstage\nauth-checkout\nexpected\nprior\nrenderer\nlock'
  _cleanup_signal_ok=true
  for _cleanup_entry in normal HUP INT TERM; do
    _cleanup_log="$_cleanup_signal_tmp/${_cleanup_entry}.log"
    case "$_cleanup_entry" in
      normal) _cleanup_expected_rc=77 ;;
      HUP) _cleanup_expected_rc=129 ;;
      INT) _cleanup_expected_rc=130 ;;
      TERM) _cleanup_expected_rc=143 ;;
    esac
    _cleanup_signal_rc=0
    /bin/bash --noprofile --norc -c '
      MDM_SOURCE_ONLY=1
      source "$1"
      _cleanup_log=$2
      _cleanup_entry=$3
      _cleanup_record() { printf "%s\n" "$1" >> "$_cleanup_log"; }
      _mdm_stop_active_timeout_supervisor() {
        _cleanup_record timeout-supervisor
      }
      _mdm_stop_active_drop_supervisor() {
        _cleanup_record drop-supervisor
        /bin/kill -HUP "$$"
      }
      _mdm_transaction_abort() { _cleanup_record transaction; }
      _mdm_cleanup_prereq_artifacts() { _cleanup_record prereq; }
      _mdm_cleanup_auth_entry_list() { _cleanup_record auth-entry; }
      _mdm_cleanup_dryrun_checkout() { _cleanup_record dryrun; }
      _mdm_cleanup_persistent_stage() { _cleanup_record stage; }
      _mdm_cleanup_auth_checkout() { _cleanup_record auth-checkout; }
      _mdm_cleanup_expected_dir() { _cleanup_record expected; }
      _mdm_cleanup_prior_inventory() { _cleanup_record prior; }
      _mdm_cleanup_renderer_snapshot() { _cleanup_record renderer; }
      _mdm_release_run_lock() { _cleanup_record lock; }
      _mdm_arm_transient_cleanup
      case "$_cleanup_entry" in
        normal) _mdm_cleanup_transient_checkouts; exit 77 ;;
        HUP) /bin/kill -HUP "$$"; exit 98 ;;
        INT) /bin/kill -INT "$$"; exit 98 ;;
        TERM) /bin/kill -TERM "$$"; exit 98 ;;
      esac
    ' _ "$PROJECT_DIR/mdm/install-mdm.sh" "$_cleanup_log" \
      "$_cleanup_entry" >/dev/null 2>&1 || _cleanup_signal_rc=$?
    _cleanup_observed="$(/bin/cat "$_cleanup_log" 2>/dev/null || true)"
    if [[ "$_cleanup_signal_rc" -ne "$_cleanup_expected_rc" \
      || "$_cleanup_observed" != "$_cleanup_expected" ]]; then
      _cleanup_signal_ok=false
    fi
  done
  if [[ "$_cleanup_signal_ok" == true ]]; then
    pass "mdm-install: cleanup 中の HUP を無視し stage/lock 後に元の exit を維持"
  else
    fail "mdm-install: cleanup が再入 HUP で中断または exit を上書き"
  fi
  rm -rf "$_cleanup_signal_tmp"
)

(
  _validation_timeout_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _MDM_TEST_MODE=1
  MDM_EUID_OVERRIDE=501
  MDM_TIMEOUT_OVERRIDE_SECONDS=1
  TMPDIR="$_validation_timeout_tmp"
  MDM_AUTH_TMPDIR_OVERRIDE="$_validation_timeout_tmp"
  MDM_AUTH_OWNER_UID_OVERRIDE="$(/usr/bin/id -u)"
  _validation_fake_python="$_validation_timeout_tmp/fake-python"
  printf '%s\n' '#!/bin/sh' 'trap "" TERM' \
    'while :; do /bin/sleep 1; done' > "$_validation_fake_python"
  /bin/chmod 700 "$_validation_fake_python"
  printf 'artifact\n' > "$_validation_timeout_tmp/artifact"
  _mdm_system_python() { printf '%s' "$_validation_fake_python"; }
  _validation_started=$SECONDS
  _validation_digest_rc=0
  _mdm_artifact_digest file "$_validation_timeout_tmp/artifact" \
    >/dev/null 2>&1 || _validation_digest_rc=$?
  _validation_digest_elapsed=$((SECONDS - _validation_started))

  _validation_renderer="$_validation_timeout_tmp/renderer.py"
  printf '%s\n' 'import signal, time' \
    'signal.signal(signal.SIGTERM, signal.SIG_IGN)' \
    'while True: time.sleep(1)' > "$_validation_renderer"
  _validation_python="$(command -v python3)"
  _mdm_system_python() { printf '%s' "$_validation_python"; }
  _MDM_EXPECTED_RENDERER="$_validation_renderer"
  _MDM_EXPECTED_RENDERER_SNAPSHOT=0
  _MDM_AUTH_CHECKOUT="$_validation_timeout_tmp/checkout"
  KIT_MDM_EXPECTED_POLICY_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  /bin/mkdir "$_MDM_AUTH_CHECKOUT"
  _validation_started=$SECONDS
  _validation_renderer_rc=0
  _mdm_prepare_expected_state /Users/fixture \
    >/dev/null 2>&1 || _validation_renderer_rc=$?
  _validation_renderer_elapsed=$((SECONDS - _validation_started))
  _validation_expected="${_MDM_EXPECTED_DIR:-}"
  _mdm_cleanup_expected_dir >/dev/null 2>&1 || true
  if [[ "$_validation_digest_rc" -eq 124 \
    && "$_validation_digest_elapsed" -le 5 \
    && "$_validation_renderer_rc" -ne 0 \
    && "$_validation_renderer_elapsed" -le 5 \
    && ! -e "$_validation_expected" && ! -L "$_validation_expected" ]] \
    && ! /usr/bin/find "$_validation_timeout_tmp" -maxdepth 1 \
      -name 'claude-kit-mdm-timeout.*' -print -quit | /usr/bin/grep -q .; then
    pass "mdm-install: renderer/local walker は各120秒で停止し workspace cleanup"
  else
    fail "mdm-install: renderer/local validation timeout/cleanup が不正"
  fi
  /bin/rm -rf "$_validation_timeout_tmp"
)

# ── 前提方針判定 ─────────────────────────────────────────
(
  _mdm_clt_present() { return 1; }
  mdm_log() { :; }
  _dry_prereq_rc=0
  _mdm_check_dryrun_prerequisites || _dry_prereq_rc=$?
  if [[ "$_dry_prereq_rc" -eq "$MDM_EXIT_PREREQ" ]]; then
    pass "mdm-install: root/non-root dry-run は CLT 不足を exit 10 で報告"
  else
    fail "mdm-install: dry-run CLT 不足の終了コードが不正 (got $_dry_prereq_rc)"
  fi
)
( export MDM_BREW_PRESENT_OVERRIDE=1
  out="$(mdm_prereq_plan 2>/dev/null)"
  [[ "$out" == "skip" ]] && pass "mdm-install: brew あり -> skip" || fail "mdm-install: brew あり時は skip (got '$out')" )
( export MDM_BREW_PRESENT_OVERRIDE=0 KIT_MDM_INSTALL_HOMEBREW=true KIT_MDM_PREREQ_MODE=auto
  out="$(mdm_prereq_plan 2>/dev/null)"
  [[ "$out" == "bootstrap" ]] && pass "mdm-install: brew なし+install=true -> bootstrap" || fail "mdm-install: bootstrap 期待 (got '$out')" )
( export MDM_BREW_PRESENT_OVERRIDE=0 KIT_MDM_INSTALL_HOMEBREW=false
  out="$(mdm_prereq_plan 2>/dev/null)"
  [[ "$out" == "fail" ]] && pass "mdm-install: brew なし+install=false -> fail" || fail "mdm-install: fail 期待 (got '$out')" )
( export MDM_BREW_PRESENT_OVERRIDE=0 KIT_MDM_PREREQ_MODE=skip
  out="$(mdm_prereq_plan 2>/dev/null)"
  [[ "$out" == "skip" ]] && pass "mdm-install: PREREQ_MODE=skip は skip" || fail "mdm-install: skip 期待 (got '$out')" )
( export MDM_BREW_PRESENT_OVERRIDE=0 KIT_MDM_PREREQ_MODE=fail
  out="$(mdm_prereq_plan 2>/dev/null)"
  [[ "$out" == "fail" ]] && pass "mdm-install: PREREQ_MODE=fail は不足時 fail" || fail "mdm-install: fail mode 期待 (got '$out')" )
( export MDM_BREW_PRESENT_OVERRIDE=1 KIT_MDM_PREREQ_MODE=auto
  out="$(mdm_prereq_plan false 2>/dev/null)"
  [[ "$out" == "bootstrap" ]] && pass "mdm-install: 対象ユーザーで非writableな brew は bootstrap" || fail "mdm-install: target unusable brew は bootstrap 期待 (got '$out')" )
(
  _brew_tmp="$(mktemp -d)"
  _mdm_brew_present() { return 0; }
  _mdm_resolve_brew_pkg_url() { : > "$_brew_tmp/pkg-resolution-called"; return 1; }
  if ! _mdm_bootstrap_homebrew jane >/dev/null 2>&1 \
    && [[ -e "$_brew_tmp/pkg-resolution-called" ]]; then
    pass "mdm-install: unusableな既存brewにも公式pkg再適用を試行"
  else
    fail "mdm-install: 既存brewの存在だけでpkg再適用をskip"
  fi
  rm -rf "$_brew_tmp"
)
(
  _brew_timeout_root="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _MDM_TEST_MODE=1
  MDM_EUID_OVERRIDE=501
  MDM_TIMEOUT_OVERRIDE_SECONDS=1
  _brew_timeout_ok=true
  _brew_timeout_dir="$_brew_timeout_root/api"
  /bin/mkdir "$_brew_timeout_dir"
  TMPDIR="$_brew_timeout_dir"
  unset MDM_BREW_RELEASES_JSON_OVERRIDE
  curl() {
    printf '%s\n' "$*" >> "$_brew_timeout_dir/curl.log"
    trap '' TERM
    while :; do /bin/sleep 1; done
  }
  _brew_timeout_started=$SECONDS
  _brew_timeout_rc=0
  _mdm_resolve_brew_pkg_url >/dev/null 2>&1 || _brew_timeout_rc=$?
  _brew_timeout_elapsed=$((SECONDS - _brew_timeout_started))
  [[ "$_brew_timeout_rc" -ne 0 && "$_brew_timeout_elapsed" -le 5 \
    && "$(/usr/bin/wc -l < "$_brew_timeout_dir/curl.log" | /usr/bin/tr -d ' ')" -eq 1 ]] \
    || _brew_timeout_ok=false

  _mdm_resolve_brew_pkg_url() {
    printf '%s' https://github.com/Homebrew/brew/releases/download/fixture/Homebrew.pkg
  }
  _mdm_write_brew_pkg_user_plist() { return 0; }
  for _brew_timeout_mode in download pkgutil installer; do
    _brew_timeout_dir="$_brew_timeout_root/$_brew_timeout_mode"
    /bin/mkdir "$_brew_timeout_dir"
    : > "$_brew_timeout_dir/curl.log"
    : > "$_brew_timeout_dir/pkgutil.log"
    : > "$_brew_timeout_dir/installer.log"
    TMPDIR="$_brew_timeout_dir"
    curl() {
      printf '%s\n' "$*" >> "$_brew_timeout_dir/curl.log"
      if [[ "$_brew_timeout_mode" == download ]]; then
        trap '' TERM
        while :; do /bin/sleep 1; done
      fi
      return 0
    }
    pkgutil() {
      printf '%s\n' "$*" >> "$_brew_timeout_dir/pkgutil.log"
      if [[ "$_brew_timeout_mode" == pkgutil ]]; then
        trap '' TERM
        while :; do /bin/sleep 1; done
      fi
      printf '%s\n' 'Developer ID Installer: Fixture (927JGANW46)'
    }
    installer() {
      printf '%s\n' "$*" >> "$_brew_timeout_dir/installer.log"
      if [[ "$_brew_timeout_mode" == installer ]]; then
        trap '' TERM
        while :; do /bin/sleep 1; done
      fi
      return 0
    }
    _brew_timeout_started=$SECONDS
    _brew_timeout_rc=0
    _mdm_bootstrap_homebrew jane >/dev/null 2>&1 || _brew_timeout_rc=$?
    _brew_timeout_elapsed=$((SECONDS - _brew_timeout_started))
    _brew_expected_pkgutil=0; _brew_expected_installer=0
    [[ "$_brew_timeout_mode" == pkgutil ]] && _brew_expected_pkgutil=1
    [[ "$_brew_timeout_mode" == installer ]] \
      && { _brew_expected_pkgutil=1; _brew_expected_installer=1; }
    _brew_actual_pkgutil="$(/usr/bin/wc -l \
      < "$_brew_timeout_dir/pkgutil.log" 2>/dev/null | /usr/bin/tr -d ' ')"
    _brew_actual_installer="$(/usr/bin/wc -l \
      < "$_brew_timeout_dir/installer.log" 2>/dev/null | /usr/bin/tr -d ' ')"
    : "${_brew_actual_pkgutil:=0}" "${_brew_actual_installer:=0}"
    if [[ "$_brew_timeout_rc" -eq 0 || "$_brew_timeout_elapsed" -gt 5 \
      || "$(/usr/bin/wc -l < "$_brew_timeout_dir/curl.log" | /usr/bin/tr -d ' ')" -ne 1 \
      || "$_brew_actual_pkgutil" -ne "$_brew_expected_pkgutil" \
      || "$_brew_actual_installer" -ne "$_brew_expected_installer" ]] \
      || /usr/bin/find "$_brew_timeout_dir" -maxdepth 1 \
        \( -name 'claude-kit-mdm-timeout.*' -o -name 'mdm-homebrew-pkg.*' \) \
        -print -quit | /usr/bin/grep -q .; then
      _brew_timeout_ok=false
    fi
  done
  if [[ "$_brew_timeout_ok" == true ]]; then
    pass "mdm-install: Brew API/pkg/pkgutil/installer は120/600/60/600秒で停止・cleanup"
  else
    fail "mdm-install: Brew timeout seam/operation count/cleanup が不正"
  fi
  /bin/rm -rf "$_brew_timeout_root"
)
(
  _MDM_TEST_MODE=0
  if _mdm_root_value KIT_MDM_PREREQ_MODE skip >/dev/null 2>&1; then
    fail "mdm-install: production parser が PREREQ_MODE=skip を許可"
  else
    pass "mdm-install: production parser は PREREQ_MODE=skip を拒否"
  fi
)
(
  _mdm_exec_as_user() {
    [[ "$1" == 501 && "$2" == jane && "$3" == /Users/jane \
      && "$4" == /bin/bash && "$5" == --noprofile && "$6" == --norc \
      && "$7" == -c && "$8" == *'/opt/homebrew/bin/brew'* \
      && "$8" == *'-w "$_prefix"'* ]]
  }
  if _mdm_brew_usable_for_user 501 jane /Users/jane; then
    pass "mdm-install: brew usability は対象ユーザーの clean shell で検証"
  else
    fail "mdm-install: brew usability の降格 argv が不正"
  fi
)

# ── MDM private Node.js runtime: fixed source / trust / download ──────────
(
  _url=""; _sha=""; _top=""
  _mdm_node_runtime_source arm64 _url _sha _top
  _arm_ok=0
  [[ "$_url" == "https://nodejs.org/dist/v24.18.0/node-v24.18.0-darwin-arm64.tar.xz" \
    && "$_sha" == "4477b9f78efb77744cf5eb57a0e9594dba66466b38b4e93fa9f35cb907a095a6" \
    && "$_top" == "node-v24.18.0-darwin-arm64" ]] && _arm_ok=1
  _mdm_node_runtime_source x64 _url _sha _top
  if [[ "$_arm_ok" -eq 1 \
    && "$_url" == "https://nodejs.org/dist/v24.18.0/node-v24.18.0-darwin-x64.tar.xz" \
    && "$_sha" == "4a3b6bc81542154430825128d9a279e8b364e8d90581544e506ef7579fd1ab6f" \
    && "$_top" == "node-v24.18.0-darwin-x64" \
    && "$(_mdm_node_runtime_expected_content_sha256 arm64)" \
      == "3b87679d20e675468b9281755c823b528b6406ba7af6cc7086ef00e5c8af6533" \
    && "$(_mdm_node_runtime_expected_content_sha256 x64)" \
      == "a9f69014ea08981c1b1822f565a39ae6970a319518ebf3e43d96ba9fc70aa209" ]]; then
    pass "mdm-install: Node v24.18.0 tar.xz URL/archive SHA/content SHA をarch別固定"
  else
    fail "mdm-install: Node固定配布物またはdynamic-scope output契約が不正"
  fi
  if _mdm_node_runtime_source ppc64 _url _sha _top >/dev/null 2>&1; then
    fail "mdm-install: Node runtime が未対応archを許可"
  else
    pass "mdm-install: Node runtime は arm64/x64 以外を拒否"
  fi
  unset MDM_NODE_ARCH_OVERRIDE
  _mdm_is_darwin() { return 0; }
  _mdm_node_sysctl() {
    [[ "$#" -eq 2 && "$1" == -in && "$2" == hw.optional.arm64 ]] \
      || return 9
    printf '%s' "$_mdm_install_arch_sysctl_value"
    return "$_mdm_install_arch_sysctl_rc"
  }
  _mdm_node_uname() {
    [[ "$#" -eq 1 && "$1" == -m ]] || return 9
    printf '%s' "$_mdm_install_arch_machine"
  }
  _mdm_install_arch_case() { # <sysctl-value> <sysctl-rc> <uname-m> <expected>
    _mdm_install_arch_sysctl_value="$1"
    _mdm_install_arch_sysctl_rc="$2"
    _mdm_install_arch_machine="$3"
    if _mdm_install_arch_actual="$(_mdm_node_runtime_arch 2>/dev/null)"; then
      _mdm_install_arch_rc=0
    else
      _mdm_install_arch_rc=$?
    fi
    if [[ "$4" == FAIL ]]; then
      [[ "$_mdm_install_arch_rc" -ne 0 && -z "$_mdm_install_arch_actual" ]]
    else
      [[ "$_mdm_install_arch_rc" -eq 0 \
        && "$_mdm_install_arch_actual" == "$4" ]]
    fi
  }
  if _mdm_install_arch_case '' 0 x86_64 x64 \
    && _mdm_install_arch_case 0 0 x86_64 x64 \
    && _mdm_install_arch_case 1 0 arm64 arm64 \
    && _mdm_install_arch_case 1 0 x86_64 arm64 \
    && _mdm_install_arch_case invalid 0 x86_64 FAIL \
    && _mdm_install_arch_case 1 0 unknown FAIL \
    && _mdm_install_arch_case '' 1 x86_64 FAIL; then
    pass "mdm-install: Node runtime arch はIntel/native ARM/Rosettaを厳格判定"
  else
    fail "mdm-install: Node runtime arch のhardware判定契約が不正"
  fi
)

(
  _node_tmp="$(builtin cd -P -- "$(mktemp -d)" && printf '%s' "$PWD")"
  export MDM_NODE_RUNTIME_ROOT_OVERRIDE="$_node_tmp/runtime"
  export MDM_NODE_ARCH_OVERRIDE=x64
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  _node_root="$(_mdm_node_runtime_path)"
  mkdir -p "$_node_root/bin" "$_node_root/lib/node_modules/npm/bin"
  # macOS inherits a new entry's group from its parent.  The formal runner
  # anchors TMPDIR below root:wheel /private/tmp, so id -g is not necessarily
  # the fixture tree's actual group.  Bind the trust expectation to the tree
  # we just created before adding files or the provenance marker.
  MDM_NODE_OWNER_UID_OVERRIDE="$(_mdm_stat_uid "$_node_root")"
  MDM_NODE_OWNER_GID_OVERRIDE="$(_mdm_stat_gid "$_node_root")"
  export MDM_NODE_OWNER_UID_OVERRIDE MDM_NODE_OWNER_GID_OVERRIDE
  chmod 755 "$_node_tmp" "$_node_tmp/runtime" "$_node_root" \
    "$_node_root/bin" "$_node_root/lib" "$_node_root/lib/node_modules" \
    "$_node_root/lib/node_modules/npm" "$_node_root/lib/node_modules/npm/bin"
  printf '#!/bin/sh\ncase "$1" in --version) echo v24.18.0;; -p) echo x64;; *) exit 1;; esac\n' \
    > "$_node_root/bin/node"
  printf '#!/bin/sh\necho 11.16.0\n' \
    > "$_node_root/lib/node_modules/npm/bin/npm-cli.js"
  printf '#!/bin/sh\necho npx\n' \
    > "$_node_root/lib/node_modules/npm/bin/npx-cli.js"
  printf '{"version":"11.16.0"}\n' > "$_node_root/lib/node_modules/npm/package.json"
  chmod 755 "$_node_root/bin/node" \
    "$_node_root/lib/node_modules/npm/bin/npm-cli.js" \
    "$_node_root/lib/node_modules/npm/bin/npx-cli.js"
  chmod 644 "$_node_root/lib/node_modules/npm/package.json"
  ln -s ../lib/node_modules/npm/bin/npm-cli.js "$_node_root/bin/npm"
  ln -s ../lib/node_modules/npm/bin/npx-cli.js "$_node_root/bin/npx"
  export MDM_NODE_CONTENT_SHA256_OVERRIDE
  MDM_NODE_CONTENT_SHA256_OVERRIDE="$(_mdm_node_runtime_content_sha256 "$_node_root")"
  _node_url=""; _node_sha=""; _node_top=""
  _mdm_node_runtime_source x64 _node_url _node_sha _node_top
  _mdm_node_runtime_write_provenance \
    "$_node_root" x64 "$_node_url" "$_node_sha"
  _node_requirement_log="$_node_tmp/requirement.log"
  _mdm_node_runtime_codesign() {
    if [[ "$1" == --verify ]]; then
      printf '%s\n' "$@" > "$_node_requirement_log"
      return 0
    fi
    printf '%s\n' \
      'Identifier=node' \
      'TeamIdentifier=HX7739G8FX' \
      'Authority=Developer ID Application: Node.js Foundation (HX7739G8FX)' \
      'Authority=Developer ID Certification Authority' \
      'Authority=Apple Root CA'
  }
  _mdm_node_runtime_lipo() { printf '%s\n' x86_64; }
  _mdm_node_runtime_otool() {
    printf '%s:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n' "$2"
  }
  _node_requirement="$(_mdm_node_runtime_codesign_requirement)"
  if _mdm_node_runtime_trusted "$_node_root" \
    && /usr/bin/grep -Fxq -- "$_node_requirement" "$_node_requirement_log" \
    && [[ "$_node_requirement" == *'certificate 1[field.1.2.840.113635.100.6.2.6] exists'* \
      && "$_node_requirement" == *'certificate leaf[field.1.2.840.113635.100.6.1.13] exists'* ]]; then
    pass "mdm-install: Node treeはcontent pin・thin arch・Developer ID OID・npm/dylibを検証"
  else
    fail "mdm-install: Node private tree trust契約が不正"
  fi
  _node_marker="$_node_root/$_MDM_NODE_PROVENANCE_FILE"
  chmod 644 "$_node_marker"
  printf '\0' >> "$_node_marker"
  chmod 444 "$_node_marker"
  if _mdm_node_runtime_trusted "$_node_root" >/dev/null 2>&1; then
    fail "mdm-install: Node provenance marker の末尾 NUL を許可"
  else
    pass "mdm-install: Node provenance marker は末尾 NUL を含め byte-exact"
  fi
  chmod 644 "$_node_marker"
  _mdm_node_runtime_provenance x64 "$_node_url" "$_node_sha" \
    > "$_node_marker"
  chmod 444 "$_node_marker"
  printf 'drift\n' > "$_node_root/lib/drift"
  if _mdm_node_runtime_trusted "$_node_root" >/dev/null 2>&1; then
    fail "mdm-install: Node content pinが追加fileを許可"
  else
    pass "mdm-install: Node content pinは初回fail TOFU/追加fileを拒否"
  fi
  rm -f "$_node_root/lib/drift"
  _mdm_node_runtime_lipo() { printf '%s\n' 'x86_64 arm64'; }
  if _mdm_node_runtime_trusted "$_node_root" >/dev/null 2>&1; then
    fail "mdm-install: Node thin arch検証がuniversal binaryを許可"
  else
    pass "mdm-install: Node runtimeはarch単一sliceだけを許可"
  fi
  _mdm_node_runtime_lipo() { printf '%s\n' x86_64; }
  _mdm_node_runtime_process_arch() { printf '%s\n' arm64; }
  if _mdm_node_runtime_trusted "$_node_root" >/dev/null 2>&1; then
    fail "mdm-install: x64 Node runtimeがprocess.arch不一致を許可"
  else
    pass "mdm-install: x64 Node runtimeはthin sliceとprocess.archを独立照合"
  fi
  _mdm_node_runtime_process_arch() { printf '%s\n' x64; }
  rm -f "$_node_root/bin/npx"
  ln -s ../lib/node_modules/npm/bin/npm-cli.js "$_node_root/bin/npx"
  export MDM_NODE_CONTENT_SHA256_OVERRIDE
  MDM_NODE_CONTENT_SHA256_OVERRIDE="$(_mdm_node_runtime_content_sha256 "$_node_root")"
  if _mdm_node_runtime_trusted "$_node_root" >/dev/null 2>&1; then
    fail "mdm-install: Node runtimeが誤ったbundled npx targetを許可"
  else
    pass "mdm-install: bundled npm/npx layoutをexact relative targetへ固定"
  fi
  rm -rf "$_node_tmp"
)

(
  _curl_tmp="$(mktemp -d)"; _curl_destination="$_curl_tmp/archive"
  : > "$_curl_destination"
  export HTTPS_PROXY=https://proxy.example.invalid:8443
  export NO_PROXY=nodejs.org
  _mdm_node_runtime_curl() {
    printf '%s\n' "$@" > "$_curl_tmp/argv"
    /bin/cat > "$_curl_tmp/config"
  }
  _curl_url=https://nodejs.org/dist/v24.18.0/node-v24.18.0-darwin-arm64.tar.xz
  if _mdm_node_runtime_download "$_curl_url" "$_curl_destination" \
    && /usr/bin/grep -Fxq -- '-q' "$_curl_tmp/argv" \
    && /usr/bin/grep -Fxq -- '--config' "$_curl_tmp/argv" \
    && /usr/bin/grep -Fq "url = \"$_curl_url\"" "$_curl_tmp/config" \
    && /usr/bin/grep -Fq 'proxy = "https://proxy.example.invalid:8443"' \
      "$_curl_tmp/config" \
    && /usr/bin/grep -Fq 'noproxy = "nodejs.org"' "$_curl_tmp/config" \
    && ! /usr/bin/grep -Fq 'proxy.example.invalid' "$_curl_tmp/argv" \
    && /usr/bin/grep -Fq 'connect-timeout = 30' "$_curl_tmp/config" \
    && /usr/bin/grep -Fq 'max-time = 600' "$_curl_tmp/config" \
    && /usr/bin/grep -Fq 'max-filesize = 104857600' "$_curl_tmp/config"; then
    pass "mdm-install: Node downloadは30/600秒・固定HTTPS・proxy・100MiB上限"
  else
    fail "mdm-install: Node downloadのURL/proxy/argv/size上限契約が不正"
  fi
  if _mdm_node_runtime_download https://example.invalid/node.tar.xz \
    "$_curl_destination" >/dev/null 2>&1; then
    fail "mdm-install: Node downloadが固定nodejs.org URL外を許可"
  else
    pass "mdm-install: Node downloadは2つの固定nodejs.org URLだけを許可"
  fi
  rm -rf "$_curl_tmp"
)

(
  _extract_tmp="$(builtin cd -P -- "$(mktemp -d)" && printf '%s' "$PWD")"
  _extract_top="node-v24.18.0-darwin-x64"
  MDM_NODE_OWNER_UID_OVERRIDE="$(/usr/bin/id -u)"
  MDM_NODE_OWNER_GID_OVERRIDE="$(/usr/bin/id -g)"
  export MDM_NODE_OWNER_UID_OVERRIDE MDM_NODE_OWNER_GID_OVERRIDE
  /usr/bin/python3 - "$_extract_tmp" "$_extract_top" <<'PY'
import hashlib
import io
import json
import os
import tarfile
import sys

root, top = sys.argv[1:]


def directory(package, name, mode=0o755):
    value = tarfile.TarInfo(name)
    value.type = tarfile.DIRTYPE
    value.mode = mode
    package.addfile(value)


def regular(package, name, payload=b"payload\n", mode=0o644, pax=None):
    value = tarfile.TarInfo(name)
    value.size = len(payload)
    value.mode = mode
    value.pax_headers = pax or {}
    package.addfile(value, io.BytesIO(payload))


def symlink(package, name, target, mode=0o755):
    value = tarfile.TarInfo(name)
    value.type = tarfile.SYMTYPE
    value.linkname = target
    value.mode = mode
    package.addfile(value)


good = os.path.join(root, "good.tar.xz")
with tarfile.open(good, "w:xz", format=tarfile.PAX_FORMAT) as package:
    for name in (top, f"{top}/bin", f"{top}/lib",
                 f"{top}/lib/node_modules", f"{top}/lib/node_modules/npm",
                 f"{top}/lib/node_modules/npm/bin"):
        directory(package, name)
    regular(package, f"{top}/bin/node", b"node\n", 0o755)
    regular(package, f"{top}/lib/node_modules/npm/bin/npm-cli.js", b"npm\n", 0o755)
    regular(package, f"{top}/lib/node_modules/npm/bin/npx-cli.js", b"npx\n", 0o755)
    regular(package, f"{top}/lib/node_modules/npm/package.json", b"{}\n")
    symlink(package, f"{top}/bin/npm", "../lib/node_modules/npm/bin/npm-cli.js", 0o777)
    symlink(package, f"{top}/bin/npx", "../lib/node_modules/npm/bin/npx-cli.js", 0o777)

records = []
with tarfile.open(good, "r:xz") as package:
    for value in package.getmembers():
        name = value.name.rstrip("/")
        path = "" if name == top else name.removeprefix(top + "/")
        base = {"path": path, "mode": f"{value.mode & 0o7777:04o}"}
        if value.isdir():
            record = dict(base, kind="dir")
        elif value.isreg():
            digest = hashlib.sha256()
            size = 0
            with package.extractfile(value) as source:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(block)
                    size += len(block)
            record = dict(base, kind="file", sha256=digest.hexdigest(), size=size)
        elif value.issym():
            record = dict(base, kind="symlink", mode="0777", target=value.linkname)
        else:
            raise SystemExit(1)
        records.append(record)
records.sort(key=lambda record: record["path"].encode("utf-8", "strict"))
canonical = (json.dumps(records, ensure_ascii=True, sort_keys=True,
                        separators=(",", ":")) + "\n").encode("ascii")
with open(os.path.join(root, "good.sha"), "w", encoding="ascii") as handle:
    handle.write(hashlib.sha256(canonical).hexdigest() + "\n")

cases = {
    "traversal": ("regular", f"{top}/../../escape", None, 0o644, None),
    "escape-link": ("symlink", f"{top}/escape", "../../../outside", 0o777, None),
    "hardlink": ("hardlink", f"{top}/hard", f"{top}/bin/node", 0o644, None),
    "writable": ("regular", f"{top}/writable", None, 0o666, None),
    "acl": ("regular", f"{top}/acl", None, 0o644,
            {"SCHILY.acl.access": "user::rw-,group::r--,other::r--"}),
}
for label, (kind, name, target, mode, pax) in cases.items():
    with tarfile.open(os.path.join(root, label + ".tar.xz"), "w:xz",
                      format=tarfile.PAX_FORMAT) as package:
        directory(package, top)
        if kind == "regular":
            regular(package, name, mode=mode, pax=pax)
        elif kind == "symlink":
            symlink(package, name, target, mode)
        else:
            value = tarfile.TarInfo(name)
            value.type = tarfile.LNKTYPE
            value.linkname = target
            value.mode = mode
            package.addfile(value)
PY
  _extract_dest="$_extract_tmp/destination"; mkdir "$_extract_dest"
  _extract_rc=0
  _mdm_node_runtime_extract_archive \
    "$_extract_tmp/good.tar.xz" "$_extract_dest" "$_extract_top" \
    || _extract_rc=$?
  _archive_content="$(/bin/cat "$_extract_tmp/good.sha")"
  _tree_content="$(_mdm_node_runtime_content_sha256 "$_extract_dest" 2>/dev/null || true)"
  if [[ "$_extract_rc" -eq 0 \
    && "$(/usr/bin/readlink "$_extract_dest/bin/npm")" \
      == ../lib/node_modules/npm/bin/npm-cli.js \
    && "$_tree_content" == "$_archive_content" ]] \
    && /usr/bin/grep -Fq 'key=lambda item: item[1].offset_data' \
      "$PROJECT_DIR/mdm/install-mdm.sh" \
    && /usr/bin/grep -Fq 'with tarfile.open(archive, mode="r:xz") as payloads:' \
      "$PROJECT_DIR/mdm/install-mdm.sh" \
    && /usr/bin/grep -Fq 'source = payloads.extractfile(member)' \
      "$PROJECT_DIR/mdm/install-mdm.sh"; then
    pass "mdm-install: Node tarは検証後streamを再openしoffset順抽出・content digest一致"
  else
    fail "mdm-install: Node safe extractor/content digest/offset順契約が不正"
  fi
  _malicious_ok=1
  for _extract_case in traversal escape-link hardlink writable acl; do
    rm -rf "$_extract_dest"; mkdir "$_extract_dest"
    if _mdm_node_runtime_extract_archive \
      "$_extract_tmp/${_extract_case}.tar.xz" \
      "$_extract_dest" "$_extract_top" >/dev/null 2>&1 \
      || [[ -n "$(/usr/bin/find "$_extract_dest" -mindepth 1 -print -quit)" ]]; then
      _malicious_ok=0
    fi
  done
  if [[ "$_malicious_ok" -eq 1 ]]; then
    pass "mdm-install: Node extractorはtraversal/symlink escape/hardlink/writable/ACLを事前拒否"
  else
    fail "mdm-install: Node extractorが危険archiveを許可または部分展開"
  fi
  rm -rf "$_extract_tmp"
)

# A fresh managed Node directory under Application Support can inherit the
# parent admin group. The issuer binds that exact inode and normalizes only a
# safe root-owned equivalent to the managed owner/GID contract.
(
  _gid_tmp="$(builtin cd -P -- "$(mktemp -d)" && printf '%s' "$PWD")"
  _gid_support="$_gid_tmp/support"
  mkdir -p "$_gid_support"
  _gid_primary="$(/usr/bin/id -g)"
  _gid_alternate="$(/usr/bin/id -G | /usr/bin/awk -v primary="$_gid_primary" \
    '{ for (i = 1; i <= NF; i++) if ($i != primary) { print $i; exit } }')"
  if [[ -n "$_gid_alternate" ]] \
    && /usr/bin/chgrp "$_gid_alternate" "$_gid_support" 2>/dev/null; then
    chmod 2755 "$_gid_support"
    mkdir "$_gid_support/runtime"
    chmod 0755 "$_gid_support"
    export MDM_NODE_RUNTIME_ROOT_OVERRIDE="$_gid_support/runtime"
    MDM_NODE_OWNER_UID_OVERRIDE="$(/usr/bin/id -u)"
    MDM_NODE_OWNER_GID_OVERRIDE="$_gid_primary"
    export MDM_NODE_OWNER_UID_OVERRIDE MDM_NODE_OWNER_GID_OVERRIDE
    export MDM_CONFIG_SKIP_OWNER_CHECK=1
    _gid_before="$(_mdm_stat_gid "$_gid_support/runtime")"
    _gid_initial_mode="$(_mdm_mode_normalize \
      "$(_mdm_stat_mode "$_gid_support/runtime")")"
    _gid_setgid_guard=1
    if [[ "$_gid_initial_mode" == 2755 ]]; then
      _gid_unsafe_rc=0
      _mdm_node_runtime_prepare_base >/dev/null 2>&1 || _gid_unsafe_rc=$?
      if [[ "$_gid_unsafe_rc" -eq 0 \
        || "$(_mdm_stat_gid "$_gid_support/runtime")" != "$_gid_alternate" \
        || "$(_mdm_mode_normalize \
          "$(_mdm_stat_mode "$_gid_support/runtime")")" != 2755 ]]; then
        _gid_setgid_guard=0
      fi
      /bin/chmod g-s "$_gid_support/runtime"
    fi
    _gid_rc=0
    _mdm_node_runtime_prepare_base >/dev/null 2>&1 || _gid_rc=$?
    if [[ "$_gid_before" == "$_gid_alternate" \
      && "$_gid_setgid_guard" -eq 1 && "$_gid_rc" -eq 0 \
      && "$(_mdm_stat_gid "$_gid_support/runtime")" == "$_gid_primary" \
      && "$(_mdm_mode_normalize \
        "$(_mdm_stat_mode "$_gid_support/runtime")")" == 0755 ]]; then
      pass "mdm-install: fresh Node managed dir の inherited GID を fd-bound 正規化"
    else
      fail "mdm-install: fresh Node parent GID 継承を正規化できない"
    fi
  else
    skip "mdm-install: fresh Node parent GID 継承" \
      "test user has no usable supplementary group"
  fi
  rm -rf "$_gid_tmp"
)

# The fd-bound normalizer must preserve and reject an unsafe directory instead
# of allowing the following ACL check to mask the Python verifier's failure.
(
  _normalize_tmp="$(builtin cd -P -- "$(mktemp -d)" && printf '%s' "$PWD")"
  chmod 0777 "$_normalize_tmp"
  _normalize_identity="$(_mdm_stat_identity "$_normalize_tmp")"
  _normalize_rc=0
  _mdm_wce_runtime_normalize_base_dir "$_normalize_tmp" \
    "$(/usr/bin/id -u)" "$(/usr/bin/id -g)" >/dev/null 2>&1 \
    || _normalize_rc=$?
  if [[ "$_normalize_rc" -ne 0 \
    && "$(_mdm_stat_identity "$_normalize_tmp")" == "$_normalize_identity" \
    && "$(_mdm_mode_normalize \
      "$(_mdm_stat_mode "$_normalize_tmp")")" == 0777 ]]; then
    pass "mdm-install: runtime base normalizer は危険modeを非変更で拒否"
  else
    fail "mdm-install: runtime base normalizer の失敗がACL検査で消失"
  fi
  rm -rf "$_normalize_tmp"
)

(
  _ensure_tmp="$(builtin cd -P -- "$(mktemp -d)" && printf '%s' "$PWD")"
  _ensure_support="$_ensure_tmp/support"
  _ensure_home="$_ensure_tmp/home"
  _ensure_template="$_ensure_tmp/template"
  mkdir -p "$_ensure_support" "$_ensure_home" \
    "$_ensure_template/bin" "$_ensure_template/lib/node_modules/npm/bin"
  chmod 755 "$_ensure_support" "$_ensure_home" "$_ensure_template" \
    "$_ensure_template/bin" "$_ensure_template/lib" \
    "$_ensure_template/lib/node_modules" "$_ensure_template/lib/node_modules/npm" \
    "$_ensure_template/lib/node_modules/npm/bin"
  printf '#!/bin/sh\ncase "$1" in --version) echo v24.18.0;; -p) echo x64;; *) exit 1;; esac\n' \
    > "$_ensure_template/bin/node"
  printf '#!/bin/sh\necho 11.16.0\n' \
    > "$_ensure_template/lib/node_modules/npm/bin/npm-cli.js"
  printf '#!/bin/sh\necho npx\n' \
    > "$_ensure_template/lib/node_modules/npm/bin/npx-cli.js"
  printf '{"version":"11.16.0"}\n' \
    > "$_ensure_template/lib/node_modules/npm/package.json"
  chmod 755 "$_ensure_template/bin/node" \
    "$_ensure_template/lib/node_modules/npm/bin/npm-cli.js" \
    "$_ensure_template/lib/node_modules/npm/bin/npx-cli.js"
  chmod 644 "$_ensure_template/lib/node_modules/npm/package.json"
  ln -s ../lib/node_modules/npm/bin/npm-cli.js "$_ensure_template/bin/npm"
  ln -s ../lib/node_modules/npm/bin/npx-cli.js "$_ensure_template/bin/npx"

  export MDM_NODE_RUNTIME_ROOT_OVERRIDE="$_ensure_support/runtime"
  export MDM_NODE_ARCH_OVERRIDE=x64
  MDM_NODE_OWNER_UID_OVERRIDE="$(/usr/bin/id -u)"
  MDM_NODE_OWNER_GID_OVERRIDE="$(/usr/bin/id -g)"
  export MDM_NODE_OWNER_UID_OVERRIDE MDM_NODE_OWNER_GID_OVERRIDE
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  export KIT_MDM_PREREQ_MODE=auto KIT_MDM_REQUIRE_NODE_RUNTIME=true
  export MDM_NODE_CONTENT_SHA256_OVERRIDE
  MDM_NODE_CONTENT_SHA256_OVERRIDE="$(_mdm_node_runtime_content_sha256 \
    "$_ensure_template")"
  _ensure_count="$_ensure_tmp/download-count"
  _mdm_node_runtime_download() {
    [[ ! -e "$_ensure_tmp/fail-download" ]] || return 1
    printf 'archive\n' > "$2"
    printf '1\n' >> "$_ensure_count"
  }
  _mdm_node_runtime_archive_sha256() {
    printf '%s' 4a3b6bc81542154430825128d9a279e8b364e8d90581544e506ef7579fd1ab6f
  }
  _mdm_node_runtime_extract_archive() {
    [[ ! -e "$_ensure_tmp/fail-extract" ]] || return 1
    /bin/cp -R "$_ensure_template/." "$2/" && /bin/chmod 755 "$2"
  }
  _mdm_node_runtime_codesign() {
    if [[ "$1" == --verify ]]; then
      if [[ -e "$_ensure_tmp/fail-post-swap" ]]; then
        printf '1\n' >> "$_ensure_tmp/codesign-count"
        [[ "$(/usr/bin/wc -l < "$_ensure_tmp/codesign-count" \
          | /usr/bin/tr -d '[:space:]')" -lt 2 ]] || return 1
      fi
      return 0
    fi
    printf '%s\n' \
      'Identifier=node' \
      'TeamIdentifier=HX7739G8FX' \
      'Authority=Developer ID Application: Node.js Foundation (HX7739G8FX)' \
      'Authority=Developer ID Certification Authority' \
      'Authority=Apple Root CA'
  }
  _mdm_node_runtime_lipo() { printf '%s\n' x86_64; }
  _mdm_node_runtime_otool() {
    printf '%s:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n' "$2"
  }
  _mdm_exec_as_user() { shift 3; "$@"; }
  _node_download_count() {
    if [[ -f "$_ensure_count" ]]; then
      /usr/bin/wc -l < "$_ensure_count" | /usr/bin/tr -d '[:space:]'
    else
      printf '0'
    fi
  }
  _node_quarantine_count() {
    local _candidate _count=0
    for _candidate in "$(_mdm_node_runtime_base)"/.node-quarantine.*; do
      [[ -e "$_candidate" || -L "$_candidate" ]] || continue
      _count=$((_count + 1))
    done
    printf '%s' "$_count"
  }
  _node_work_count() {
    local _candidate _count=0
    for _candidate in "$(_mdm_node_runtime_base)"/.node-download.* \
      "$(_mdm_node_runtime_base)"/.node-stage.*; do
      [[ -e "$_candidate" || -L "$_candidate" ]] || continue
      _count=$((_count + 1))
    done
    printf '%s' "$_count"
  }

  _ensure_user="$(/usr/bin/id -un)"; _ensure_uid="$(/usr/bin/id -u)"
  _ensure_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _ensure_rc=$?
  _ensure_root="$(_mdm_node_runtime_path)"
  _ensure_link="$_ensure_home/.local/bin/node"
  _ensure_target="$_ensure_root/bin/node"
  if [[ "$_ensure_rc" -eq 0 && -d "$_ensure_root" \
    && -L "$_ensure_link" \
    && "$(/usr/bin/readlink "$_ensure_link")" == "$_ensure_target" \
    && "$(/usr/bin/wc -l < "$_ensure_count" | /usr/bin/tr -d '[:space:]')" == 1 ]]; then
    pass "mdm-install: Node auto freshはpinned stageをatomic publishしabsolute activation作成"
  else
    fail "mdm-install: Node auto fresh provision/activation契約が不正 (rc=$_ensure_rc)"
  fi

  _ensure_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _ensure_rc=$?
  if [[ "$_ensure_rc" -eq 0 \
    && "$(/usr/bin/wc -l < "$_ensure_count" | /usr/bin/tr -d '[:space:]')" == 1 ]]; then
    pass "mdm-install: Node autoはexact content treeをnetworkなしで再利用"
  else
    fail "mdm-install: Node auto再実行が不要なdownload/mutationを実行"
  fi

  if _mdm_is_darwin \
    && /bin/chmod +a 'everyone deny write' \
      "$(_mdm_node_runtime_base)" 2>/dev/null; then
    _ancestor_acl_identity="$(_mdm_stat_identity "$_ensure_root")"
    _ancestor_acl_downloads="$(_node_download_count)"
    _ancestor_acl_rc=0
    _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
      >/dev/null 2>&1 || _ancestor_acl_rc=$?
    /bin/chmod -N "$(_mdm_node_runtime_base)"
    _ancestor_recover_rc=0
    _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
      >/dev/null 2>&1 || _ancestor_recover_rc=$?
    if [[ "$_ancestor_acl_rc" -ne 0 && "$_ancestor_recover_rc" -eq 0 \
      && "$(_mdm_stat_identity "$_ensure_root")" == "$_ancestor_acl_identity" \
      && "$(_node_download_count)" == "$_ancestor_acl_downloads" ]]; then
      pass "mdm-install: Node managed ancestor ACL を通信・tree変更なしで拒否"
    else
      fail "mdm-install: Node managed ancestor ACL 契約が不正"
    fi
  elif _mdm_is_darwin; then
    fail "mdm-install: Node ancestor ACL fixtureを作成できない"
  else
    pass "mdm-install: Node ancestor ACL 拒否は Darwin 契約として固定"
  fi

  printf 'drift\n' > "$_ensure_root/lib/drift"
  _ensure_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _ensure_rc=$?
  if [[ "$_ensure_rc" -eq 0 && ! -e "$_ensure_root/lib/drift" \
    && "$(/usr/bin/wc -l < "$_ensure_count" | /usr/bin/tr -d '[:space:]')" == 2 ]]; then
    pass "mdm-install: Node autoはcontent driftを固定archiveへatomic収束"
  else
    fail "mdm-install: Node autoがcontent driftを再baseline化/未修復"
  fi

  # A failed rebuild must leave the old fixed inode in place and remove every
  # download/stage artifact.  Exercise download, extraction, and post-swap
  # validation failures before allowing the same drift to converge.
  printf 'failure-drift\n' > "$_ensure_root/lib/failure-drift"
  _rebuild_identity="$(_mdm_stat_identity "$_ensure_root")"
  _rebuild_downloads="$(_node_download_count)"
  : > "$_ensure_tmp/fail-download"
  _rebuild_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _rebuild_rc=$?
  rm -f "$_ensure_tmp/fail-download"
  if [[ "$_rebuild_rc" -ne 0 \
    && "$(_mdm_stat_identity "$_ensure_root")" == "$_rebuild_identity" \
    && -f "$_ensure_root/lib/failure-drift" \
    && "$(_node_download_count)" == "$_rebuild_downloads" \
    && "$(_node_work_count)" == 0 ]]; then
    pass "mdm-install: Node download失敗は既存tree不変・work残骸なし"
  else
    fail "mdm-install: Node download失敗時のrollback/cleanupが不正"
  fi

  : > "$_ensure_tmp/fail-extract"
  _rebuild_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _rebuild_rc=$?
  rm -f "$_ensure_tmp/fail-extract"
  if [[ "$_rebuild_rc" -ne 0 \
    && "$(_mdm_stat_identity "$_ensure_root")" == "$_rebuild_identity" \
    && -f "$_ensure_root/lib/failure-drift" \
    && "$(_node_download_count)" -eq $((_rebuild_downloads + 1)) \
    && "$(_node_work_count)" == 0 ]]; then
    pass "mdm-install: Node extract失敗は既存tree不変・work残骸なし"
  else
    fail "mdm-install: Node extract失敗時のrollback/cleanupが不正"
  fi

  : > "$_ensure_tmp/fail-post-swap"
  : > "$_ensure_tmp/codesign-count"
  _rebuild_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _rebuild_rc=$?
  rm -f "$_ensure_tmp/fail-post-swap" "$_ensure_tmp/codesign-count"
  if [[ "$_rebuild_rc" -ne 0 \
    && "$(_mdm_stat_identity "$_ensure_root")" == "$_rebuild_identity" \
    && -f "$_ensure_root/lib/failure-drift" \
    && "$(_node_download_count)" -eq $((_rebuild_downloads + 2)) \
    && "$(_node_work_count)" == 0 ]]; then
    pass "mdm-install: Node post-swap検証失敗は旧inodeへatomic rollback"
  else
    fail "mdm-install: Node post-swap検証失敗時のrollbackが不正"
  fi
  _rebuild_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _rebuild_rc=$?
  if [[ "$_rebuild_rc" -eq 0 \
    && ! -e "$_ensure_root/lib/failure-drift" \
    && "$(_node_download_count)" -eq $((_rebuild_downloads + 3)) ]]; then
    pass "mdm-install: Node rebuild失敗後の次回autoは固定archiveへ収束"
  else
    fail "mdm-install: Node rebuild失敗後の再試行が未収束"
  fi

  # fail is read-only even for unsafe metadata.  auto quarantines the exact
  # old inode and publishes a verified candidate without traversing it.
  /bin/chmod 0777 "$_ensure_root/bin"
  export KIT_MDM_PREREQ_MODE=fail
  _unsafe_identity="$(_mdm_stat_identity "$_ensure_root")"
  _unsafe_downloads="$(_node_download_count)"
  _unsafe_quarantines="$(_node_quarantine_count)"
  _unsafe_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _unsafe_rc=$?
  if [[ "$_unsafe_rc" -ne 0 \
    && "$(_mdm_stat_identity "$_ensure_root")" == "$_unsafe_identity" \
    && "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_ensure_root/bin")")" == 0777 \
    && "$(_node_download_count)" == "$_unsafe_downloads" \
    && "$(_node_quarantine_count)" == "$_unsafe_quarantines" ]]; then
    pass "mdm-install: Node failはg/o-write treeを通信・変更・隔離せず拒否"
  else
    fail "mdm-install: Node failがunsafe treeを変更または通信"
  fi
  export KIT_MDM_PREREQ_MODE=auto
  _unsafe_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _unsafe_rc=$?
  if [[ "$_unsafe_rc" -eq 0 \
    && "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_ensure_root/bin")")" == 0755 \
    && "$(_node_download_count)" -eq $((_unsafe_downloads + 1)) \
    && "$(_node_quarantine_count)" -eq $((_unsafe_quarantines + 1)) ]]; then
    pass "mdm-install: Node autoはg/o-write旧treeを隔離して再配備"
  else
    fail "mdm-install: Node autoがunsafe mode driftを未修復"
  fi

  _unsafe_downloads="$(_node_download_count)"
  _unsafe_quarantines="$(_node_quarantine_count)"
  /bin/ln "$_ensure_root/bin/node" "$_ensure_root/bin/node-hard"
  _unsafe_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _unsafe_rc=$?
  if [[ "$_unsafe_rc" -eq 0 && ! -e "$_ensure_root/bin/node-hard" \
    && "$(_node_download_count)" -eq $((_unsafe_downloads + 1)) \
    && "$(_node_quarantine_count)" -eq $((_unsafe_quarantines + 1)) ]]; then
    pass "mdm-install: Node autoはhardlink treeを削除せず隔離して再配備"
  else
    fail "mdm-install: Node hardlink treeの隔離再配備が不正"
  fi

  if _mdm_is_darwin \
    && /bin/chmod +a 'everyone deny write' "$_ensure_root/bin/node" 2>/dev/null; then
    _unsafe_downloads="$(_node_download_count)"
    _unsafe_quarantines="$(_node_quarantine_count)"
    _unsafe_rc=0
    _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
      >/dev/null 2>&1 || _unsafe_rc=$?
    if [[ "$_unsafe_rc" -eq 0 \
      && "$(_node_download_count)" -eq $((_unsafe_downloads + 1)) \
      && "$(_node_quarantine_count)" -eq $((_unsafe_quarantines + 1)) ]]; then
      pass "mdm-install: Node autoはACL付き旧treeを隔離して再配備"
    else
      fail "mdm-install: Node ACL付きtreeの隔離再配備が不正"
    fi
  elif _mdm_is_darwin; then
    fail "mdm-install: Node ACL fixtureを作成できない"
  else
    pass "mdm-install: Node ACL quarantine fixtureはDarwinで検証"
  fi

  _unsafe_downloads="$(_node_download_count)"
  _unsafe_quarantines="$(_node_quarantine_count)"
  /bin/mv "$_ensure_root" "$_ensure_tmp/pre-symlink-runtime"
  /bin/ln -s "$_ensure_template" "$_ensure_root"
  _unsafe_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _unsafe_rc=$?
  _symlink_quarantined=0
  for _unsafe_path in "$(_mdm_node_runtime_base)"/.node-quarantine.*; do
    [[ -L "$_unsafe_path" ]] || continue
    [[ "$(/usr/bin/readlink "$_unsafe_path")" == "$_ensure_template" ]] \
      && _symlink_quarantined=1
  done
  if [[ "$_unsafe_rc" -eq 0 && "$_symlink_quarantined" -eq 1 \
    && "$(_node_download_count)" -eq $((_unsafe_downloads + 1)) \
    && "$(_node_quarantine_count)" -eq $((_unsafe_quarantines + 1)) ]]; then
    pass "mdm-install: Node autoはfixed target symlink自体を隔離して再配備"
  else
    fail "mdm-install: Node fixed target symlinkの隔離再配備が不正"
  fi

  _unsafe_downloads="$(_node_download_count)"
  _unsafe_quarantines="$(_node_quarantine_count)"
  /bin/mv "$_ensure_root" "$_ensure_tmp/pre-fifo-runtime"
  /usr/bin/mkfifo "$_ensure_root"
  _unsafe_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _unsafe_rc=$?
  _fifo_quarantined=0
  for _unsafe_path in "$(_mdm_node_runtime_base)"/.node-quarantine.*; do
    [[ -p "$_unsafe_path" ]] && _fifo_quarantined=1
  done
  if [[ "$_unsafe_rc" -eq 0 && "$_fifo_quarantined" -eq 1 \
    && "$(_node_download_count)" -eq $((_unsafe_downloads + 1)) \
    && "$(_node_quarantine_count)" -eq $((_unsafe_quarantines + 1)) ]]; then
    pass "mdm-install: Node autoはfixed target FIFOをopenせず隔離して再配備"
  else
    fail "mdm-install: Node fixed target FIFOの隔離再配備が不正"
  fi

  _unsafe_downloads="$(_node_download_count)"
  _unsafe_quarantines="$(_node_quarantine_count)"
  _foreign_identity="$(_mdm_stat_identity "$_ensure_root")"
  _mdm_node_runtime_root_metadata_valid() {
    [[ "$(_mdm_stat_identity "$1" 2>/dev/null || true)" != "$_foreign_identity" ]]
  }
  _unsafe_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _unsafe_rc=$?
  if [[ "$_unsafe_rc" -eq 0 \
    && "$(_node_download_count)" -eq $((_unsafe_downloads + 1)) \
    && "$(_node_quarantine_count)" -eq $((_unsafe_quarantines + 1)) ]]; then
    pass "mdm-install: Node autoはforeign-owner判定の旧inodeを隔離して再配備"
  else
    fail "mdm-install: Node foreign-owner treeの隔離再配備が不正"
  fi

  # If publishing after quarantine fails, restore the exact old inode to the
  # fixed pathname and keep no orphan work/quarantine entry from that attempt.
  /bin/chmod 0777 "$_ensure_root/bin"
  _restore_identity="$(_mdm_stat_identity "$_ensure_root")"
  _restore_downloads="$(_node_download_count)"
  _restore_quarantines="$(_node_quarantine_count)"
  : > "$_ensure_tmp/fail-quarantine-publish"
  _mdm_node_runtime_atomic_rename() {
    if [[ -e "$_ensure_tmp/fail-quarantine-publish" \
      && "$1" == "$(_mdm_node_runtime_base)"/.node-stage.* \
      && "$2" == "$_ensure_root" && "$3" == create ]]; then
      return 1
    fi
    _mdm_node_runtime_atomic_rename_system "$@"
  }
  _restore_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _restore_rc=$?
  rm -f "$_ensure_tmp/fail-quarantine-publish"
  if [[ "$_restore_rc" -ne 0 \
    && "$(_mdm_stat_identity "$_ensure_root")" == "$_restore_identity" \
    && "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_ensure_root/bin")")" == 0777 \
    && "$(_node_download_count)" -eq $((_restore_downloads + 1)) \
    && "$(_node_quarantine_count)" == "$_restore_quarantines" \
    && "$(_node_work_count)" == 0 ]]; then
    pass "mdm-install: Node quarantine後publish失敗は旧inodeをfixed pathへ復元"
  else
    fail "mdm-install: Node quarantine publish失敗時のidentity rollbackが不正"
  fi
  _restore_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _restore_rc=$?
  if [[ "$_restore_rc" -eq 0 \
    && "$(_node_quarantine_count)" -eq $((_restore_quarantines + 1)) ]]; then
    pass "mdm-install: Node quarantine rollback後の次回autoは正常収束"
  else
    fail "mdm-install: Node quarantine rollback後の再試行が未収束"
  fi

  rm -f "$_ensure_link"; printf 'stale\n' > "$_ensure_link"; chmod 600 "$_ensure_link"
  _activation_downloads="$(_node_download_count)"
  _ensure_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _ensure_rc=$?
  if [[ "$_ensure_rc" -eq 0 && -L "$_ensure_link" \
    && "$(/usr/bin/readlink "$_ensure_link")" == "$_ensure_target" \
    && "$(_node_download_count)" == "$_activation_downloads" ]]; then
    pass "mdm-install: Node autoはuser-owned stale activation leafだけをatomic修復"
  else
    fail "mdm-install: Node auto activation修復がroot tree再取得/失敗"
  fi

  _MDM_TARGET_SHELL=/bin/bash
  mdm_build_drop_argv "$_ensure_uid" "$_ensure_user" "$_ensure_home" \
    /bin/true >/dev/null 2>&1 || true
  _ensure_drop_path=""
  for _ensure_arg in "${MDM_DROP_ARGV[@]}"; do
    case "$_ensure_arg" in PATH=*) _ensure_drop_path="${_ensure_arg#PATH=}" ;; esac
  done
  if [[ "$_ensure_drop_path" == "$_ensure_root/bin:"* \
    && ":$_ensure_drop_path:" != *":$_ensure_home/.local/bin:"* ]]; then
    pass "mdm-install: required時のclean PATHはprivate Node bin先頭・home-local除外"
  else
    fail "mdm-install: private Node clean PATHの優先順/隔離が不正"
  fi

  export KIT_MDM_PREREQ_MODE=fail
  _fail_downloads="$(_node_download_count)"
  _fail_quarantines="$(_node_quarantine_count)"
  _fail_tree_identity="$(_mdm_stat_identity "$_ensure_root")"
  _ensure_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _ensure_rc=$?

  _expected_content="$MDM_NODE_CONTENT_SHA256_OVERRIDE"
  MDM_NODE_CONTENT_SHA256_OVERRIDE=0000000000000000000000000000000000000000000000000000000000000000
  _fail_content_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _fail_content_rc=$?
  MDM_NODE_CONTENT_SHA256_OVERRIDE="$_expected_content"
  if [[ "$_fail_content_rc" -ne 0 \
    && "$(_mdm_stat_identity "$_ensure_root")" == "$_fail_tree_identity" \
    && "$(_node_download_count)" == "$_fail_downloads" \
    && "$(_node_quarantine_count)" == "$_fail_quarantines" ]]; then
    pass "mdm-install: Node failは公式expected content不一致をread-only拒否"
  else
    fail "mdm-install: Node failがexpected content不一致を受理または変更"
  fi

  rm -f "$_ensure_link"
  /bin/ln -s /bin/false "$_ensure_link"
  _fail_link_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _fail_link_rc=$?
  if [[ "$_fail_link_rc" -eq 0 && -L "$_ensure_link" \
    && "$(/usr/bin/readlink "$_ensure_link")" == /bin/false \
    && "$(_node_download_count)" == "$_fail_downloads" ]]; then
    pass "mdm-install: Node failはroot runtimeだけ検証しwrong activationをsetupへ委譲"
  else
    fail "mdm-install: Node failがwrong activationを変更またはroot runtime検証失敗"
  fi

  export KIT_MDM_PREREQ_MODE=auto
  _activation_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _activation_rc=$?
  if [[ "$_activation_rc" -eq 0 \
    && "$(/usr/bin/readlink "$_ensure_link")" == "$_ensure_target" \
    && "$(_node_download_count)" == "$_fail_downloads" ]]; then
    pass "mdm-install: Node autoはwrong activationだけを修復"
  else
    fail "mdm-install: Node auto wrong activation修復がroot treeを変更"
  fi

  rm -f "$_ensure_link"; /bin/mkdir "$_ensure_link"
  _activation_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _activation_rc=$?
  if [[ "$_activation_rc" -ne 0 && -d "$_ensure_link" \
    && "$(_node_download_count)" == "$_fail_downloads" ]]; then
    pass "mdm-install: Node activation directoryは非破壊拒否"
  else
    fail "mdm-install: Node activation directoryを置換または受理"
  fi
  /bin/rmdir "$_ensure_link"
  export KIT_MDM_PREREQ_MODE=auto
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || fail "mdm-install: directory fixture後のactivation復旧に失敗"

  rm -f "$_ensure_link"
  printf 'activation-hardlink\n' > "$_ensure_home/activation-hardlink"
  /bin/chmod 0700 "$_ensure_home/activation-hardlink"
  /bin/ln "$_ensure_home/activation-hardlink" "$_ensure_link"
  _activation_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _activation_rc=$?
  if [[ "$_activation_rc" -ne 0 && -f "$_ensure_link" \
    && "$(_mdm_stat_managed_metadata "$_ensure_link")" == *:2:* \
    && "$(_node_download_count)" == "$_fail_downloads" ]]; then
    pass "mdm-install: Node activation hardlinkは非破壊拒否"
  else
    fail "mdm-install: Node activation hardlinkを置換または受理"
  fi
  rm -f "$_ensure_link" "$_ensure_home/activation-hardlink"
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || fail "mdm-install: hardlink fixture後のactivation復旧に失敗"

  /bin/chmod 0777 "$_ensure_home/.local/bin"
  _activation_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _activation_rc=$?
  if [[ "$_activation_rc" -ne 0 && -L "$_ensure_link" \
    && "$(/usr/bin/readlink "$_ensure_link")" == "$_ensure_target" \
    && "$(_node_download_count)" == "$_fail_downloads" ]]; then
    pass "mdm-install: Node activation unsafe parentは非破壊拒否"
  else
    fail "mdm-install: Node activation unsafe parentを受理または変更"
  fi
  /bin/chmod 0755 "$_ensure_home/.local/bin"
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || fail "mdm-install: unsafe parent fixture後のactivation復旧に失敗"

  export KIT_MDM_PREREQ_MODE=fail
  _ensure_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _ensure_rc=$?
  rm -f "$_ensure_link"
  _fail_missing_rc=0
  _mdm_ensure_node_runtime "$_ensure_user" "$_ensure_home" "$_ensure_uid" \
    >/dev/null 2>&1 || _fail_missing_rc=$?
  if [[ "$_ensure_rc" -eq 0 && "$_fail_missing_rc" -eq 0 \
    && ! -e "$_ensure_link" && ! -L "$_ensure_link" \
    && "$(_node_download_count)" == "$_fail_downloads" ]]; then
    pass "mdm-install: Node failはactivation有無によらずroot runtimeをread-only検証"
  else
    fail "mdm-install: Node fail modeが通信/activation変更またはroot runtime拒否"
  fi
  rm -rf "$_ensure_tmp"
)

(
  _node_phase="$(declare -f _mdm_run_root_user_phase 2>/dev/null || true)"
  _load_line="$(printf '%s\n' "$_node_phase" | /usr/bin/grep -n \
    '_mdm_load_expected_required_components' | /usr/bin/head -n1 | /usr/bin/cut -d: -f1)"
  _ensure_line="$(printf '%s\n' "$_node_phase" | /usr/bin/grep -n \
    '_mdm_ensure_node_runtime' | /usr/bin/head -n1 | /usr/bin/cut -d: -f1)"
  _setup_line="$(printf '%s\n' "$_node_phase" | /usr/bin/grep -n \
    'authoritative setup.sh' | /usr/bin/head -n1 | /usr/bin/cut -d: -f1)"
  if [[ "$_load_line" =~ ^[0-9]+$ && "$_ensure_line" =~ ^[0-9]+$ \
    && "$_setup_line" =~ ^[0-9]+$ \
    && "$_load_line" -lt "$_ensure_line" && "$_ensure_line" -lt "$_setup_line" ]]; then
    pass "mdm-install: required Node provisionはexpected解決後・target setup前"
  else
    fail "mdm-install: Node provision main orderingが不正"
  fi
)

# ── 降格 argv 構築（グローバル配列 MDM_DROP_ARGV へ直接構築。最終レビュー High#4）──
# 旧実装の「改行区切り stdout → read -r で配列化」は、改行を含む値（env 由来
# EDITOR_CHOICE 等）で env のコマンド位置に任意コマンドを注入できたため廃止。
(
  export PROFILE="standard" LANGUAGE="ja" KIT_MDM_GIT_REF="main"
  export KIT_MDM_PREREQ_MODE="fail"
  export PATH="/attacker-controlled"
  _MDM_TARGET_SHELL="/bin/zsh"
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh --non-interactive 2>/dev/null \
    || fail "mdm-install: mdm_build_drop_argv が失敗した"
  [[ "${MDM_DROP_ARGV[0]}" == "/usr/bin/env" && "${MDM_DROP_ARGV[1]}" == "-i" ]] \
    && pass "mdm-install: /usr/bin/env -i を絶対パスで先頭に置く" \
    || fail "mdm-install: env -i が絶対パスで先頭に無い (got '${MDM_DROP_ARGV[0]}' '${MDM_DROP_ARGV[1]:-}')"
  _has() { local _e; for _e in "${MDM_DROP_ARGV[@]}"; do [[ "$_e" == "$1" ]] && return 0; done; return 1; }
  _has 'HOME=/Users/jane' && pass "mdm-install: HOME を固定" || fail "mdm-install: HOME 固定なし"
  _has 'SHELL=/bin/zsh' && pass "mdm-install: 束縛済み UserShell を固定" || fail "mdm-install: SHELL 固定なし"
  _drop_path=""
  for _drop_arg in "${MDM_DROP_ARGV[@]}"; do
    case "$_drop_arg" in PATH=*) _drop_path="$_drop_arg" ;; esac
  done
  _drop_path_value="${_drop_path#PATH=}"
  if [[ ":$_drop_path_value:" == *:/usr/bin:/bin:/usr/sbin:/sbin: ]] \
    && [[ "$_drop_path" != *attacker-controlled* \
      && "$_drop_path" != *'/Users/jane/'* \
      && "$_drop_path" != *'/.local/bin'* ]]; then
    pass "mdm-install: 降格 PATH は user-local を除く既知ツール・system の clean 値"
  else
    fail "mdm-install: 降格 PATH が user-local/呼出元 PATH を継承または system path を欠落"
  fi
  _has 'KIT_MDM_MANAGED=true' && pass "mdm-install: KIT_MDM_MANAGED を注入" || fail "mdm-install: KIT_MDM_MANAGED 注入なし（update 復元で MDM 設定が巻き戻る）"
  _has 'USER=jane' && pass "mdm-install: USER を固定" || fail "mdm-install: USER 固定なし"
  _has 'PROFILE=standard' && pass "mdm-install: PROFILE を伝搬" || fail "mdm-install: PROFILE 伝搬なし"
  _has 'LANGUAGE=ja' && pass "mdm-install: LANGUAGE を伝搬" || fail "mdm-install: LANGUAGE 伝搬なし"
  _has 'KIT_MDM_PREREQ_MODE=fail' \
    && pass "mdm-install: 正規化済みPREREQ_MODEを対象ユーザーへ伝搬" \
    || fail "mdm-install: PREREQ_MODE の対象ユーザー伝搬なし"
  # 実行コマンドは呼び出し側指定の位置に単一要素で並ぶ
  _has '/bin/bash' && _has '/path/to/setup.sh' && _has '--non-interactive' \
    && pass "mdm-install: 実行コマンドと引数が argv に含まれる" \
    || fail "mdm-install: 実行コマンド/引数が argv に無い"
)

(
  _mdm_run_root_user_phase() {
    [[ "$3" == 501 ]] || return 99
    return "$MDM_EXIT_PREREQ"
  }
  _phase_rc=0
  _mdm_run_user_phase 0 jane /Users/jane 501 >/dev/null 2>&1 || _phase_rc=$?
  if [[ "$_phase_rc" -eq "$MDM_EXIT_PREREQ" ]]; then
    pass "mdm-install: root user phase は束縛済み UID と setup exit 10 を保持"
  else
    fail "mdm-install: root user phase が exit 10 を変換 (got $_phase_rc)"
  fi
)

(
  _phase_tmp="$(mktemp -d)"
  _phase_user="$(/usr/bin/id -un)"
  _mdm_root_ref_allowed() { return 0; }
  _mdm_prepare_authoritative_checkout() {
    _MDM_AUTH_CHECKOUT="$_phase_tmp/authoritative"
    MDM_RCPT_RESOLVED_SHA=0123456789abcdef0123456789abcdef01234567
    return 0
  }
  _phase_prior_captures=0
  _mdm_capture_prior_inventory() {
    _phase_prior_captures=$((_phase_prior_captures + 1))
    return 0
  }
  _mdm_prepare_expected_state() { return 0; }
  _mdm_load_expected_required_components() {
    # shellcheck disable=SC2034
    MDM_REQUIRED_COMPONENTS=(kit)
    # shellcheck disable=SC2034
    MDM_RCPT_REQUIRED_COMPONENTS='["kit"]'
    return 0
  }
  _mdm_worktree_content_digest() {
    printf '%064d' 0
  }
  _mdm_exec_as_user() { return "$MDM_EXIT_PREREQ"; }
  mdm_log() { printf '%s\n' "$*" >> "$_phase_tmp/wrapper.log"; }
  export KIT_MDM_DRY_RUN=true KIT_MDM_GIT_REF=main KIT_MDM_INSTALL_CLAUDE_CLI=false
  export KIT_MDM_EXPECTED_POLICY_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  _phase_rc=0
  _mdm_run_root_user_phase "$_phase_user" "$_phase_tmp/home" 501 \
    >/dev/null 2>&1 || _phase_rc=$?
  if [[ "$_phase_rc" -eq "$MDM_EXIT_PREREQ" \
    && "$_phase_prior_captures" -eq 1 ]] \
    && grep -q 'setup.sh の実行に失敗 (exit=10)' "$_phase_tmp/wrapper.log"; then
    pass "mdm-install: root dry-runもprior inventoryを捕捉しsetup exit 10を保持"
  else
    fail "mdm-install: root dry-runのprior inventory/exit 10伝播が不正 (got $_phase_rc)"
  fi
  rm -rf "$_phase_tmp"
)

(
  if [[ "$(_mdm_user_phase_exit_code "$MDM_EXIT_PREREQ" false)" == "$MDM_EXIT_PREREQ" \
    && "$(_mdm_user_phase_exit_code "$MDM_EXIT_PREREQ" true)" == "$MDM_EXIT_PREREQ" \
    && "$(_mdm_user_phase_exit_code 1 false)" == "$MDM_EXIT_SETUP" \
    && "$(_mdm_user_phase_exit_code "$MDM_EXIT_CONFIG" true)" == "$MDM_EXIT_CONFIG" ]]; then
    pass "mdm-install: main exit mapping は前提不足10を保持し他setup失敗を30化"
  else
    fail "mdm-install: main user-phase exit mapping が不正"
  fi
)
(
  unset PROFILE
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh 2>/dev/null || true
  _found=0
  for _e in "${MDM_DROP_ARGV[@]}"; do case "$_e" in PROFILE=*) _found=1 ;; esac; done
  if [[ "$_found" -eq 1 ]]; then
    fail "mdm-install: 未設定の PROFILE は渡さない"
  else
    pass "mdm-install: 未設定変数は伝搬しない"
  fi
)
# 注入回帰: 改行を含む passthrough 値は拒否する（env のコマンド位置注入防止）
(
  export EDITOR_CHOICE=$'none\n/usr/bin/id'
  _rc=0
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    pass "mdm-install: 改行を含む passthrough 値を拒否"
  else
    fail "mdm-install: 改行を含む passthrough 値が argv に混入し得る（注入回帰）"
  fi
)
# 空白を含む値は単一の argv 要素のまま保持される（word splitting されない）
(
  export EDITOR_CHOICE='none plus extra'
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh 2>/dev/null \
    || fail "mdm-install: 空白入り値で失敗した"
  _found=0
  for _e in "${MDM_DROP_ARGV[@]}"; do [[ "$_e" == 'EDITOR_CHOICE=none plus extra' ]] && _found=1; done
  [[ "$_found" -eq 1 ]] \
    && pass "mdm-install: 空白入り値が単一要素で保持される" \
    || fail "mdm-install: 空白入り値が単一要素で保持されない"
)

# root authoritative setup だけに ephemeral safe.directory を注入する。
(
  export PROFILE=standard LANGUAGE=en
  _MDM_GIT_SAFE_DIRECTORY=/private/tmp/claude-kit-mdm-auth.fixture
  mdm_build_drop_argv 501 jane /Users/jane \
    /bin/bash "$_MDM_GIT_SAFE_DIRECTORY/setup.sh" --non-interactive
  _safe_count=0; _safe_key=0; _safe_value=0; _auth_setup=0; _persistent_setup=0
  for _safe_arg in "${MDM_DROP_ARGV[@]}"; do
    [[ "$_safe_arg" == GIT_CONFIG_COUNT=1 ]] && _safe_count=$((_safe_count + 1))
    [[ "$_safe_arg" == GIT_CONFIG_KEY_0=safe.directory ]] && _safe_key=1
    [[ "$_safe_arg" == "GIT_CONFIG_VALUE_0=$_MDM_GIT_SAFE_DIRECTORY" ]] && _safe_value=1
    [[ "$_safe_arg" == "$_MDM_GIT_SAFE_DIRECTORY/setup.sh" ]] && _auth_setup=1
    [[ "$_safe_arg" == /Users/jane/.claude-starter-kit/setup.sh ]] && _persistent_setup=1
  done
  _MDM_GIT_SAFE_DIRECTORY=""
  if [[ "$_safe_count" -eq 1 && "$_safe_key" -eq 1 && "$_safe_value" -eq 1 \
    && "$_auth_setup" -eq 1 && "$_persistent_setup" -eq 0 ]]; then
    pass "mdm-install: env config は authoritative dir だけを safe.directory 化"
  else
    fail "mdm-install: safe.directory/setup authority argv が不正"
  fi
)

# ── LANG マッピング回帰テスト（Task 8 バグ修正）─────────────
# 旧実装は "LANG=${LANGUAGE}_JP.UTF-8" と決め打ちしており、LANGUAGE=en のとき
# 不正ロケール "en_JP.UTF-8" を生成していた。_mdm_lang_to_locale 経由で
# en->en_US.UTF-8 / ja->ja_JP.UTF-8 に正しくマップされることを確認する。
(
  export LANGUAGE="en"
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh 2>/dev/null || true
  _found=0
  for _e in "${MDM_DROP_ARGV[@]}"; do [[ "$_e" == 'LANG=en_US.UTF-8' ]] && _found=1; done
  [[ "$_found" -eq 1 ]] \
    && pass "mdm-install: LANGUAGE=en は LANG=en_US.UTF-8 にマップ" \
    || fail "mdm-install: LANGUAGE=en の LANG マッピングが不正"
)
(
  export LANGUAGE="ja"
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh 2>/dev/null || true
  _found=0
  for _e in "${MDM_DROP_ARGV[@]}"; do [[ "$_e" == 'LANG=ja_JP.UTF-8' ]] && _found=1; done
  [[ "$_found" -eq 1 ]] \
    && pass "mdm-install: LANGUAGE=ja は LANG=ja_JP.UTF-8 にマップ" \
    || fail "mdm-install: LANGUAGE=ja の LANG マッピングが不正"
)

# ── _mdm_exec_as_user は launchctl/sudo を絶対パスで組み立てる ──
# MDM_EXEC_AS_USER_DRYRUN=1 で実行せず argv を表示のみ（表示は再パースされない）。
(
  export MDM_EXEC_AS_USER_DRYRUN=1
  out="$(_mdm_exec_as_user 501 jane /Users/jane /bin/bash /path/to/setup.sh --non-interactive 2>/dev/null)"
  printf '%s' "$out" | head -1 | grep -q '^/bin/launchctl$' \
    && pass "mdm-install: launchctl を絶対パスで起動" \
    || fail "mdm-install: launchctl が絶対パスでない (out: $(printf '%s' "$out" | head -1))"
  printf '%s\n' "$out" | grep -q '^/usr/bin/sudo$' \
    && pass "mdm-install: sudo を絶対パスで起動" \
    || fail "mdm-install: sudo が絶対パスでない"
  printf '%s\n' "$out" | grep -qx '#501' \
    && pass "mdm-install: sudo 降格先は再解決しない numeric UID" \
    || fail "mdm-install: sudo 降格先が short name を再解決し得る"
)

# 実行元が対象ユーザーから探索不能でも、降格前に検証済み home へ移動する。
(
  _cwd_tmp="$(mktemp -d)"
  _cwd_tmp="$(builtin cd -P "$_cwd_tmp" && printf '%s' "$PWD")"
  _cwd_home="$_cwd_tmp/home"
  _cwd_blocked="$_cwd_tmp/root-private"
  _cwd_launchctl="$_cwd_tmp/launchctl"
  _cwd_sudo="$_cwd_tmp/sudo"
  mkdir -p "$_cwd_home" "$_cwd_blocked"
  printf '%s\n' '#!/bin/sh' \
    '[ "$1" = asuser ] || exit 91' \
    'shift 2' \
    'exec "$@"' > "$_cwd_launchctl"
  printf '%s\n' '#!/bin/sh' \
    '[ "$1" = -u ] || exit 92' \
    'shift 2' \
    '[ "$1" = -H ] || exit 93' \
    'shift' \
    'exec "$@"' > "$_cwd_sudo"
  chmod 755 "$_cwd_launchctl" "$_cwd_sudo"
  _cwd_rc=0
  _cwd_output="$(
    builtin cd -P "$_cwd_blocked" || exit 1
    _MDM_TEST_MODE=1 \
      MDM_LAUNCHCTL_OVERRIDE="$_cwd_launchctl" \
      MDM_SUDO_OVERRIDE="$_cwd_sudo" \
      _mdm_exec_as_user 501 "$(/usr/bin/id -un)" "$_cwd_home" \
        /bin/bash --noprofile --norc -c \
        '[[ "$PWD" == "$1" ]] && printf "%s" "$PWD"' \
        mdm-cwd "$_cwd_home"
  )" || _cwd_rc=$?
  if [[ "$_cwd_rc" -eq 0 && "$_cwd_output" == "$_cwd_home" ]]; then
    pass "mdm-install: 降格前に対象ユーザーが探索可能な home CWD へ移動"
  else
    fail "mdm-install: 降格コマンドが root-private CWD を継承 (rc=$_cwd_rc)"
  fi
  rm -rf "$_cwd_tmp"
)

(
  _setup_timeout_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _setup_timeout_home="$_setup_timeout_tmp/home"
  _setup_timeout_support="$_setup_timeout_tmp/support"
  _setup_timeout_launchctl="$_setup_timeout_tmp/launchctl"
  _setup_timeout_sudo="$_setup_timeout_tmp/sudo"
  _setup_timeout_uid="$(/usr/bin/id -u)"
  _setup_timeout_user="$(/usr/bin/id -un)"
  /bin/mkdir "$_setup_timeout_home" "$_setup_timeout_support"
  /bin/chmod 755 "$_setup_timeout_support"
  printf '%s\n' '#!/bin/sh' \
    '[ "$1" = asuser ] || exit 91' 'shift 2' 'exec "$@"' \
    > "$_setup_timeout_launchctl"
  printf '%s\n' '#!/bin/sh' \
    '[ "$1" = -u ] || exit 92' 'shift 2' \
    '[ "$1" = -H ] || exit 93' 'shift' 'exec "$@"' \
    > "$_setup_timeout_sudo"
  /bin/chmod 755 "$_setup_timeout_launchctl" "$_setup_timeout_sudo"
  if [[ "$_setup_timeout_uid" -lt 501 || ! -x /usr/bin/lockf ]]; then
    skip "mdm-install: setup timeout descendant/lock" "UID<501 or lockf unavailable"
  else
    _MDM_TEST_MODE=1
    MDM_TIMEOUT_OVERRIDE_SECONDS=1
    # Consumed indirectly by the sourced production helpers.
    # shellcheck disable=SC2034
    MDM_LAUNCHCTL_OVERRIDE="$_setup_timeout_launchctl"
    # shellcheck disable=SC2034
    MDM_SUDO_OVERRIDE="$_setup_timeout_sudo"
    MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_setup_timeout_support"
    MDM_CONFIG_SKIP_OWNER_CHECK=1
    _MDM_RUN_LOCK_FILE=""; _MDM_RUN_LOCK_BASE=""
    _setup_lock_rc=0
    _mdm_acquire_run_lock "$_setup_timeout_user" "$_setup_timeout_home" \
      || _setup_lock_rc=$?
    (
      exec 18>&- 19>&-
      _setup_wait=0
      while [[ ! -s "$_setup_timeout_tmp/leader.pid" \
        && "$_setup_wait" -lt 300 ]]; do
        /bin/sleep 0.01
        _setup_wait=$((_setup_wait + 1))
      done
      _setup_contender_rc=0
      /bin/bash --noprofile --norc -c '
        MDM_SOURCE_ONLY=1
        source "$1"
        _MDM_TEST_MODE=1
        MDM_SYSTEM_RCPT_DIR_OVERRIDE=$2
        MDM_CONFIG_SKIP_OWNER_CHECK=1
        _MDM_RUN_LOCK_FILE=""; _MDM_RUN_LOCK_BASE=""
        _mdm_acquire_run_lock "$3" "$4"
      ' mdm-lock-contender "$PROJECT_DIR/mdm/install-mdm.sh" \
        "$_setup_timeout_support" "$_setup_timeout_user" \
        "$_setup_timeout_home" >/dev/null 2>&1 || _setup_contender_rc=$?
      printf '%s' "$_setup_contender_rc" > "$_setup_timeout_tmp/contender.rc"
    ) &
    _setup_contender=$!
    _setup_timeout_started=$SECONDS
    _setup_timeout_rc=0
    _mdm_exec_setup_as_user "$_setup_timeout_uid" "$_setup_timeout_user" \
      "$_setup_timeout_home" /bin/sh -c '
        trap "" TERM
        ( trap "" TERM; while :; do /bin/sleep 1; done ) &
        printf "%s" "$!" > "$1/grandchild.pid"
        printf "%s" "$$" > "$1/leader.pid"
        while :; do /bin/sleep 1; done
      ' mdm-setup-timeout "$_setup_timeout_tmp" \
      > "$_setup_timeout_tmp/setup.out" \
      2> "$_setup_timeout_tmp/setup.err" || _setup_timeout_rc=$?
    _setup_timeout_elapsed=$((SECONDS - _setup_timeout_started))
    wait "$_setup_contender" 2>/dev/null || true
    _setup_timeout_leader="$(/bin/cat \
      "$_setup_timeout_tmp/leader.pid" 2>/dev/null || true)"
    _setup_timeout_grandchild="$(/bin/cat \
      "$_setup_timeout_tmp/grandchild.pid" 2>/dev/null || true)"
    _setup_contender_rc="$(/bin/cat \
      "$_setup_timeout_tmp/contender.rc" 2>/dev/null || true)"
    _setup_retry_rc=0
    _mdm_exec_setup_as_user "$_setup_timeout_uid" "$_setup_timeout_user" \
      "$_setup_timeout_home" /usr/bin/true \
      >/dev/null 2>&1 || _setup_retry_rc=$?
    _mdm_release_run_lock >/dev/null 2>&1 || _setup_lock_rc=$?
    _setup_reuse_rc=0
    _mdm_acquire_run_lock "$_setup_timeout_user" "$_setup_timeout_home" \
      >/dev/null 2>&1 || _setup_reuse_rc=$?
    _mdm_release_run_lock >/dev/null 2>&1 || _setup_reuse_rc=$?
    if [[ "$_setup_lock_rc" -eq 0 && "$_setup_timeout_rc" -eq 124 \
      && "$_setup_timeout_elapsed" -le 15 && "$_setup_contender_rc" -ne 0 \
      && "$_setup_retry_rc" -eq 0 && "$_setup_reuse_rc" -eq 0 \
      && -z "${_MDM_ACTIVE_DROP_SUPERVISOR_PID:-}" \
      && ! -s "$_setup_timeout_tmp/setup.err" ]] \
      && ! _mdm_timeout_group_live "$_setup_timeout_leader" \
      && ! /bin/ps -p "$_setup_timeout_grandchild" -o stat= 2>/dev/null \
        | /usr/bin/grep -Ev '^[[:space:]]*Z' | /usr/bin/grep -q .; then
      pass "mdm-install: setup 1200秒timeoutは孫停止後124・lock保持/解放・即時再試行"
    else
      fail "mdm-install: setup timeout descendant/supervisor/lock 契約が不正 (lock=$_setup_lock_rc timeout=$_setup_timeout_rc elapsed=$_setup_timeout_elapsed contender=$_setup_contender_rc retry=$_setup_retry_rc reuse=$_setup_reuse_rc drop=${_MDM_ACTIVE_DROP_SUPERVISOR_PID:-none} err=$(/usr/bin/wc -c < "$_setup_timeout_tmp/setup.err" | /usr/bin/tr -d ' ') leader=$_setup_timeout_leader grandchild=$_setup_timeout_grandchild)"
    fi
  fi
  /bin/rm -rf "$_setup_timeout_tmp"
)

# ══ CRITICAL 回帰（最終レビュー #2）: root は対象ユーザー所有 repo を直接
#    git 操作しない。git は _mdm_git 経由で検証済みユーザーへ降格する ══
(
  # 降格コンテキスト設定時: /usr/bin/git が sudo -u #<uid> 配下で組み立てられる
  export MDM_EXEC_AS_USER_DRYRUN=1
  _MDM_GIT_DROP_UID=501; _MDM_GIT_DROP_USER=jane; _MDM_GIT_DROP_HOME=/Users/jane
  # NOTE: 未実装時（関数未定義 = 127）に set -e でサブシェルごと即死しないよう捕捉
  out="$(_mdm_git -C /Users/jane/.claude-starter-kit fetch origin main 2>/dev/null)" || true
  printf '%s\n' "$out" | grep -q '^/usr/bin/sudo$' \
    && printf '%s\n' "$out" | grep -q '^/usr/bin/git$' \
    && pass "mdm-install: _mdm_git が root 時に降格 argv で git を実行" \
    || fail "mdm-install: _mdm_git の降格が効いていない (out: $out)"
  printf '%s\n' "$out" | grep -q '^-u$' && printf '%s\n' "$out" | grep -qx '#501' \
    && pass "mdm-install: _mdm_git の降格先が束縛済み numeric UID" \
    || fail "mdm-install: _mdm_git の降格先が不正"
)
(
  # 降格コンテキスト未設定時（非 root）: 直接実行される
  _MDM_GIT_DROP_UID=""
  out="$(_mdm_git --version 2>/dev/null)" || true
  printf '%s' "$out" | grep -q 'git version' \
    && pass "mdm-install: _mdm_git が非 root 時は直接実行" \
    || fail "mdm-install: _mdm_git の直接実行が失敗 (out: $out)"
)
(
  _git_timeout_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _MDM_TEST_MODE=1
  MDM_EUID_OVERRIDE=501
  MDM_TIMEOUT_OVERRIDE_SECONDS=1
  TMPDIR="$_git_timeout_tmp"
  _MDM_GIT_DROP_UID=""
  _git_network_mode=hang
  _mdm_git() {
    printf '%s\n' "$*" >> "$_git_timeout_tmp/git.log"
    if [[ "$_git_network_mode" == hang ]]; then
      trap '' TERM
      while :; do /bin/sleep 1; done
    fi
    [[ "$_git_network_mode" != drop ]] \
      || printf '%s' "${_MDM_EXEC_AS_USER_DEADLINE_SECONDS:-}" \
        > "$_git_timeout_tmp/drop-deadline"
  }
  _mdm_auth_git() {
    printf '%s\n' "$*" >> "$_git_timeout_tmp/auth.log"
    if [[ "$_git_network_mode" == hang ]]; then
      trap '' TERM
      while :; do /bin/sleep 1; done
    fi
  }
  _git_timeout_rc=0
  _mdm_git_network clone https://example.invalid/repo.git checkout \
    >/dev/null 2>&1 || _git_timeout_rc=$?
  _git_network_mode=retry
  _git_retry_rc=0
  _mdm_git_network fetch https://example.invalid/repo.git main \
    >/dev/null 2>&1 || _git_retry_rc=$?
  _git_network_mode=hang
  _auth_timeout_rc=0
  _mdm_auth_git_network clone https://example.invalid/repo.git auth \
    >/dev/null 2>&1 || _auth_timeout_rc=$?
  _git_network_mode=retry
  _auth_retry_rc=0
  _mdm_auth_git_network fetch https://example.invalid/repo.git main \
    >/dev/null 2>&1 || _auth_retry_rc=$?
  _git_network_mode=drop
  _MDM_GIT_DROP_UID=501
  _mdm_git_network fetch https://example.invalid/repo.git main \
    >/dev/null 2>&1
  if [[ "$_git_timeout_rc" -eq 124 && "$_auth_timeout_rc" -eq 124 \
    && "$_git_retry_rc" -eq 0 && "$_auth_retry_rc" -eq 0 \
    && "$(/usr/bin/wc -l < "$_git_timeout_tmp/git.log" | /usr/bin/tr -d ' ')" -eq 3 \
    && "$(/usr/bin/wc -l < "$_git_timeout_tmp/auth.log" | /usr/bin/tr -d ' ')" -eq 2 \
    && "$(< "$_git_timeout_tmp/drop-deadline")" == 1 ]] \
    && [[ "$(/usr/bin/grep -c -- '-c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60' \
      "$_git_timeout_tmp/git.log")" -eq 3 \
    && "$(/usr/bin/grep -c -- '-c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60' \
      "$_git_timeout_tmp/auth.log")" -eq 2 ]] \
    && ! /usr/bin/find "$_git_timeout_tmp" -maxdepth 1 \
      -name 'claude-kit-mdm-timeout.*' -print -quit | /usr/bin/grep -q .; then
    pass "mdm-install: network Git は300秒/low-speed・timeout124・即時再試行・drop deadline"
  else
    fail "mdm-install: network Git timeout/low-speed seam が不正"
  fi
  /bin/rm -rf "$_git_timeout_tmp"
)
# chown -R は撤去済み（clone を初回からユーザー実行するため不要になった）
if grep -q 'chown -R' "$PROJECT_DIR/mdm/install-mdm.sh"; then
  fail "mdm-install: chown -R が残存している（root の任意 repo chown 経路）"
else
  pass "mdm-install: chown -R が撤去されている"
fi

# ── KIT_MDM_INSTALL_DIR は対象ユーザーの canonical home 配下に制約 ──
_tmpd="$(mktemp -d)"; _tmpd="$(cd "$_tmpd" && pwd -P)"
_fakehome="$_tmpd/Users/jane"; mkdir -p "$_fakehome"
export KIT_MDM_EXPECTED_POLICY_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
(
  export KIT_MDM_INSTALL_DIR="$_tmpd/outside-home"
  export MDM_KIT_REPO_URL_OVERRIDE="$_tmpd/no-such-repo"
  _rc=0
  _mdm_run_user_phase 0 "$(/usr/bin/id -un)" "$_fakehome" 501 \
    >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "home 外 install_dir は exit 50" \
    && pass "mdm-install: home 外の KIT_MDM_INSTALL_DIR を拒否" \
    || fail "mdm-install: home 外の KIT_MDM_INSTALL_DIR を拒否すべき (got $_rc)"
)
(
  export KIT_MDM_INSTALL_DIR="$_fakehome/../escape"
  export MDM_KIT_REPO_URL_OVERRIDE="$_tmpd/no-such-repo"
  _rc=0
  _mdm_run_user_phase 0 "$(/usr/bin/id -un)" "$_fakehome" 501 \
    >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" ".. 含みの install_dir は exit 50" \
    && pass "mdm-install: .. を含む KIT_MDM_INSTALL_DIR を拒否" \
    || fail "mdm-install: .. を含む KIT_MDM_INSTALL_DIR を拒否すべき (got $_rc)"
)
(
  # home そのもの（配下でなく一致）も拒否
  export KIT_MDM_INSTALL_DIR="$_fakehome"
  export MDM_KIT_REPO_URL_OVERRIDE="$_tmpd/no-such-repo"
  _rc=0
  _mdm_run_user_phase 0 "$(/usr/bin/id -un)" "$_fakehome" 501 \
    >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "home 自体は exit 50" \
    && pass "mdm-install: home 自体を install_dir にするのを拒否" \
    || fail "mdm-install: home 自体の install_dir を拒否すべき (got $_rc)"
)
rm -rf "$_tmpd"
unset KIT_MDM_EXPECTED_POLICY_SHA256

# ── Homebrew pkg URL 解決（GitHub API レスポンスのモック。jq 非依存 grep/sed）──
_brew_tmpd="$(mktemp -d)"
_brew_fixture_ok="$_brew_tmpd/release-ok.json"
cat > "$_brew_fixture_ok" <<'EOF'
{
  "tag_name": "4.6.15",
  "assets": [
    {
      "name": "Homebrew-4.6.15.pkg.sha256",
      "browser_download_url": "https://github.com/Homebrew/brew/releases/download/4.6.15/Homebrew-4.6.15.pkg.sha256"
    },
    {
      "name": "Homebrew-4.6.15.pkg",
      "browser_download_url": "https://github.com/Homebrew/brew/releases/download/4.6.15/Homebrew-4.6.15.pkg"
    }
  ]
}
EOF
(
  export MDM_BREW_RELEASES_JSON_OVERRIDE="$_brew_fixture_ok"
  out="$(_mdm_resolve_brew_pkg_url 2>/dev/null)"
  if [[ "$out" == "https://github.com/Homebrew/brew/releases/download/4.6.15/Homebrew-4.6.15.pkg" ]]; then
    pass "mdm-install: brew pkg URL を .pkg アセットから解決"
  else
    fail "mdm-install: brew pkg URL 解決が不正 (got '$out')"
  fi
)

_brew_fixture_nopkg="$_brew_tmpd/release-nopkg.json"
cat > "$_brew_fixture_nopkg" <<'EOF'
{
  "tag_name": "4.6.15",
  "assets": [
    {
      "name": "Homebrew-4.6.15.pkg.sha256",
      "browser_download_url": "https://github.com/Homebrew/brew/releases/download/4.6.15/Homebrew-4.6.15.pkg.sha256"
    }
  ]
}
EOF
(
  export MDM_BREW_RELEASES_JSON_OVERRIDE="$_brew_fixture_nopkg"
  _rc=0
  _mdm_resolve_brew_pkg_url >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    pass "mdm-install: .pkg アセットが無い場合は失敗を返す"
  else
    fail "mdm-install: .pkg アセットが無いのに成功してしまう"
  fi
)

(
  export MDM_BREW_RELEASES_JSON_OVERRIDE="$_brew_tmpd/does-not-exist.json"
  _rc=0
  _mdm_resolve_brew_pkg_url >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    pass "mdm-install: JSON 取得不可（空応答）時は失敗を返す"
  else
    fail "mdm-install: 空応答なのに成功してしまう"
  fi
)

# ══ Homebrew 導入経路の固定（最終レビュー High#7）══

# URL は https://github.com/Homebrew/brew/releases/download/ 配下の
# Homebrew*.pkg のみ許可（API 応答が改ざん/汚染されても他ホストへ飛ばない）
_brew_fixture_evil="$_brew_tmpd/release-evil.json"
cat > "$_brew_fixture_evil" <<'EOF'
{
  "assets": [
    {
      "name": "Homebrew-4.6.15.pkg",
      "browser_download_url": "https://evil.example.com/Homebrew-4.6.15.pkg"
    }
  ]
}
EOF
(
  export MDM_BREW_RELEASES_JSON_OVERRIDE="$_brew_fixture_evil"
  _rc=0
  _mdm_resolve_brew_pkg_url >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    pass "mdm-install: 公式リリース URL 以外の .pkg を拒否"
  else
    fail "mdm-install: 非公式ホストの .pkg URL を許容してしまう"
  fi
)
# 現行リリースの実アセット名（バージョンなし Homebrew.pkg・6.0.11 で実測）も許可
_brew_fixture_new="$_brew_tmpd/release-new.json"
cat > "$_brew_fixture_new" <<'EOF'
{
  "assets": [
    {
      "name": "Homebrew.pkg",
      "browser_download_url": "https://github.com/Homebrew/brew/releases/download/6.0.11/Homebrew.pkg"
    }
  ]
}
EOF
(
  export MDM_BREW_RELEASES_JSON_OVERRIDE="$_brew_fixture_new"
  out="$(_mdm_resolve_brew_pkg_url 2>/dev/null)" || true
  [[ "$out" == "https://github.com/Homebrew/brew/releases/download/6.0.11/Homebrew.pkg" ]] \
    && pass "mdm-install: バージョンなしアセット名 Homebrew.pkg を許容" \
    || fail "mdm-install: 現行アセット名 Homebrew.pkg が拒否される (got '$out')"
)

# 署名検証は Homebrew の Team ID (927JGANW46) に pin する
# （2026-07-17 に release 6.0.11 の pkgutil --check-signature で実測:
#  "Developer ID Installer: Patrick Linnane (927JGANW46)" + notarized）
(
  _sig_ok='Package "Homebrew.pkg":
   Status: signed by a developer certificate issued by Apple for distribution
   Notarization: trusted by the Apple notary service
   Certificate Chain:
    1. Developer ID Installer: Patrick Linnane (927JGANW46)'
  _rc=0
  _mdm_check_brew_signature_output "$_sig_ok" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq 0 ]] \
    && pass "mdm-install: 正規 Team ID の署名を許容" \
    || fail "mdm-install: 正規 Team ID の署名が拒否される"
)
(
  _sig_evil='Package "Homebrew.pkg":
   Status: signed by a developer certificate issued by Apple for distribution
   Certificate Chain:
    1. Developer ID Installer: Evil Corp (EVIL123456)'
  _rc=0
  _mdm_check_brew_signature_output "$_sig_evil" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -ne 0 ]] \
    && pass "mdm-install: 別 Team ID の Developer ID 署名を拒否" \
    || fail "mdm-install: 別 Team ID の署名を許容してしまう（pin 不成立）"
)

# HOMEBREW_PKG_USER plist は symlink を辿らず root 所有 0600 で安全に作成する
# （Homebrew 側 homebrew-package-user は「非symlink 通常ファイル・root 所有・
#  mode 0600・ACL 無し」の場合のみ plist を尊重する — brew 実装で確認済み）
(
  _pl_tmpd="$(mktemp -d)"
  _victim="$_pl_tmpd/victim-file"
  printf 'original\n' > "$_victim"
  export MDM_BREW_PLIST_OVERRIDE="$_pl_tmpd/pkg_user.plist"
  ln -s "$_victim" "$MDM_BREW_PLIST_OVERRIDE"
  _rc=0
  _mdm_write_brew_pkg_user_plist "jane" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 && ! -L "$MDM_BREW_PLIST_OVERRIDE" && -f "$MDM_BREW_PLIST_OVERRIDE" ]] \
     && [[ "$(cat "$_victim")" == "original" ]]; then
    pass "mdm-install: 先回り symlink を辿らず plist を作成（標的ファイル無傷）"
  else
    fail "mdm-install: plist 作成が symlink を辿る/失敗する (rc=$_rc)"
  fi
  grep -q '<string>jane</string>' "$MDM_BREW_PLIST_OVERRIDE" 2>/dev/null \
    && pass "mdm-install: plist に対象ユーザーが記録される" \
    || fail "mdm-install: plist の内容が不正"
  _mode="$(test_stat_mode "$MDM_BREW_PLIST_OVERRIDE")"
  [[ "$_mode" == "600" ]] \
    && pass "mdm-install: plist が mode 600 で作成される（brew 側の受理条件）" \
    || fail "mdm-install: plist の mode が 600 でない (got $_mode)"
  rm -rf "$_pl_tmpd"
)
rm -rf "$_brew_tmpd"

# ── ログ出力先の決定（最終レビュー High#3: 設定確定後に決定・許可プレフィックス制約）──
_tmpd="$(mktemp -d)"; _tmpd="$(cd "$_tmpd" && pwd -P)"
_loghome="$_tmpd/Users/jane"; mkdir -p "$_loghome"
(
  # 非 root（ユーザーモード）の既定は ~/Library/Logs 配下
  unset KIT_MDM_LOG_DIR
  MDM_LOG_FILE=""
  _mdm_setup_log_file 501 "$_loghome" 2>/dev/null || fail "mdm-install: ログ既定パスの決定に失敗"
  case "$MDM_LOG_FILE" in
    "$_loghome/Library/Logs/ClaudeCodeStarterKit/install-"*.log)
      pass "mdm-install: ユーザーモードのログ既定が ~/Library/Logs 配下" ;;
    *)
      fail "mdm-install: ユーザーモードのログ既定が不正 (got '$MDM_LOG_FILE')" ;;
  esac
)
(
  # root の既定は /Library/Logs 配下（実 I/O を伴わない dir 決定のみ検証。
  # 実ファイル準備は root 権限が要り非 root テスト環境では走らせられない）
  unset KIT_MDM_LOG_DIR
  out="$(_mdm_log_dir_for 0 "$_loghome" 2>/dev/null)" || fail "mdm-install: root ログ dir 決定に失敗"
  [[ "$out" == "/Library/Logs/ClaudeCodeStarterKit" ]] \
    && pass "mdm-install: root のログ既定が /Library/Logs 配下" \
    || fail "mdm-install: root のログ既定が不正 (got '$out')"
)
(
  # KIT_MDM_LOG_DIR の明示指定（許可プレフィックス配下）は尊重される
  export KIT_MDM_LOG_DIR="$_loghome/Library/Logs/CustomDir"
  MDM_LOG_FILE=""
  _mdm_setup_log_file 501 "$_loghome" 2>/dev/null || fail "mdm-install: LOG_DIR 明示指定の決定に失敗"
  case "$MDM_LOG_FILE" in
    "$_loghome/Library/Logs/CustomDir/install-"*.log)
      pass "mdm-install: KIT_MDM_LOG_DIR 明示指定がログパスに反映される" ;;
    *)
      fail "mdm-install: KIT_MDM_LOG_DIR 明示指定が反映されない (got '$MDM_LOG_FILE')" ;;
  esac
)
(
  # 許可プレフィックス外の KIT_MDM_LOG_DIR は exit 50（root 書込先の制約）
  export KIT_MDM_LOG_DIR="/etc/evil-logs"
  _rc=0
  _mdm_setup_log_file 0 "$_loghome" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "許可外 LOG_DIR は exit 50" \
    && pass "mdm-install: 許可プレフィックス外の LOG_DIR を拒否" \
    || fail "mdm-install: 許可外 LOG_DIR を拒否すべき (got $_rc)"
)
(
  # root はユーザー home 配下の LOG_DIR を指定できない（ユーザーが植えた
  # symlink を root が辿って任意 append する経路を塞ぐ）
  export KIT_MDM_LOG_DIR="$_loghome/Library/Logs/UserControlled"
  _rc=0
  _mdm_setup_log_file 0 "$_loghome" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "root は home 配下 LOG_DIR 不可" \
    && pass "mdm-install: root 時にユーザー home 配下の LOG_DIR を拒否" \
    || fail "mdm-install: root 時の home 配下 LOG_DIR を拒否すべき (got $_rc)"
)
(
  # 非 root はシステム領域 /Library/Logs を指定できない（書けないだけでなく契約外）
  export KIT_MDM_LOG_DIR="/Library/Logs/ClaudeCodeStarterKit"
  _rc=0
  _mdm_setup_log_file 501 "$_loghome" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "非rootはシステム LOG_DIR 不可" \
    && pass "mdm-install: 非 root 時にシステム領域の LOG_DIR を拒否" \
    || fail "mdm-install: 非 root 時のシステム LOG_DIR を拒否すべき (got $_rc)"
)
# ── ログファイルは umask 非依存で実体作成され、fd を保持する（R3/R4-High）──
(
  umask 000
  unset KIT_MDM_LOG_DIR
  MDM_LOG_FILE=""; MDM_LOG_FD_OPEN=0
  _mdm_setup_log_file 501 "$_loghome" 2>/dev/null || fail "mdm-install: ログ準備に失敗"
  _dmode="$(test_stat_mode "$(dirname "$MDM_LOG_FILE")")"
  [[ "$_dmode" == "755" ]] \
    && pass "mdm-install: umask 000 でもログ dir は 755" \
    || fail "mdm-install: umask 000 でログ dir が ${_dmode}"
  [[ -f "$MDM_LOG_FILE" && ! -L "$MDM_LOG_FILE" ]] \
    && pass "mdm-install: ログファイルが実体で作成される" \
    || fail "mdm-install: ログファイルが実体作成されない"
  _fmode="$(test_stat_mode "$MDM_LOG_FILE")"
  [[ "$_fmode" == "644" ]] \
    && pass "mdm-install: umask 000 でもログファイルは 644" \
    || fail "mdm-install: umask 000 でログファイルが ${_fmode}"
  [[ "$MDM_LOG_FD_OPEN" == "1" ]] \
    && pass "mdm-install: ログは保持 fd 経由（MDM_LOG_FD_OPEN=1）" \
    || fail "mdm-install: ログ fd が保持されていない"
  exec 7>&- 2>/dev/null || true
  MDM_LOG_FD_OPEN=0
)
(
  # ログパスに symlink dir を指定したら拒否（exit 50）
  _evildir="$_loghome/Library/Logs/EvilLink"
  ln -s "/etc" "$_evildir"
  export KIT_MDM_LOG_DIR="$_evildir"
  MDM_LOG_FILE=""
  _rc=0
  _mdm_setup_log_file 501 "$_loghome" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "symlink のログ dir は exit 50" \
    && pass "mdm-install: symlink のログディレクトリを拒否" \
    || fail "mdm-install: symlink のログディレクトリを拒否すべき (got $_rc)"
)

# ── stderr が open 後も生きている（R5-Medium 回帰: exec ... 2>/dev/null の fd2 汚染）──
(
  _od="$_loghome/Library/Logs/stderrprobe"; mkdir -p "$_od"
  MDM_LOG_FILE=""; MDM_LOG_FD_OPEN=0
  _errf="$(mktemp)"
  (
    exec 2>"$_errf"
    _mdm_open_log_fd "$_od/probe.log"
    printf 'PROBE_AFTER_OPEN\n' >&2
  )
  if grep -q 'PROBE_AFTER_OPEN' "$_errf"; then
    pass "mdm-install: ログ fd open 後も stderr が生きている"
  else
    fail "mdm-install: open 後に stderr が /dev/null へ汚染された（R5-M 回帰）"
  fi
  rm -f "$_errf"
  exec 7>&- 2>/dev/null || true; MDM_LOG_FD_OPEN=0
)

# ── 信頼チェーン検証（R5/R6-High）──
(
  # チェーン中の symlink コンポーネントを拒否（owner 検査は skip して symlink 判定に到達させる）
  _cd="$_tmpd/chain"; mkdir -p "$_cd/Library/Logs"
  chmod 755 "$_cd/Library" "$_cd/Library/Logs"
  ln -s /tmp "$_cd/Library/Logs/app"
  export MDM_LOG_SKIP_OWNER_CHECK=1
  if _mdm_verify_dir_chain "$_cd/Library/Logs/app" "$_cd/Library/Logs"; then
    fail "mdm-install: チェーン中の symlink コンポーネントを許容してしまう"
  else
    pass "mdm-install: チェーン中の symlink コンポーネントを拒否"
  fi
  unset MDM_LOG_SKIP_OWNER_CHECK
)
(
  # owner 不一致（非 root 所有）コンポーネントを拒否（owner 検査有効）
  _cd="$_tmpd/chain-owner"; mkdir -p "$_cd/Library/Logs/app"
  chmod 755 "$_cd/Library" "$_cd/Library/Logs" "$_cd/Library/Logs/app"
  # root runner でも最終 component だけを実在する target persona 所有にする。
  _mdm_test_chown_target "$_cd/Library/Logs/app"
  if _mdm_verify_dir_chain "$_cd/Library/Logs/app" "$_cd/Library/Logs"; then
    fail "mdm-install: 非 root 所有コンポーネントを許容してしまう"
  else
    pass "mdm-install: 非 root 所有コンポーネントを拒否（owner 検査）"
  fi
)
(
  # glob 文字（*）を含むコンポーネントも word splitting/glob 展開で
  # 見逃さず検証する。cwd に glob がマッチするファイルを置き、未クォート
  # 分割なら検証対象がすり替わって symlink を見逃す状況を再現する。
  _cd="$_tmpd/chain-glob"; mkdir -p "$_cd/Library/Logs"
  chmod 755 "$_cd/Library" "$_cd/Library/Logs"
  ln -s /tmp "$_cd/Library/Logs/a*b"
  mkdir -p "$_tmpd/globcwd"; : > "$_tmpd/globcwd/aXb"
  export MDM_LOG_SKIP_OWNER_CHECK=1
  _rc_glob=0
  ( cd "$_tmpd/globcwd" && _mdm_verify_dir_chain "$_cd/Library/Logs/a*b" "$_cd/Library/Logs" ) || _rc_glob=$?
  if [[ "$_rc_glob" -eq 0 ]]; then
    fail "mdm-install: glob 文字を含む symlink コンポーネントを見逃す（迂回可能）"
  else
    pass "mdm-install: glob 文字を含むコンポーネントも正しく検証"
  fi
  unset MDM_LOG_SKIP_OWNER_CHECK
)
(
  # 全コンポーネントが非 symlink（owner 検査は skip して mode のみ）なら許容
  _cd="$_tmpd/chain-ok"; mkdir -p "$_cd/Library/Logs/app"
  chmod 755 "$_cd/Library" "$_cd/Library/Logs" "$_cd/Library/Logs/app"
  export MDM_LOG_SKIP_OWNER_CHECK=1
  if _mdm_verify_dir_chain "$_cd/Library/Logs/app" "$_cd/Library/Logs"; then
    pass "mdm-install: 健全なチェーン（非symlink・755）は許容"
  else
    fail "mdm-install: 健全なチェーンが拒否される"
  fi
  unset MDM_LOG_SKIP_OWNER_CHECK
)
(
  # group/other 書込可のコンポーネントを拒否
  _cd="$_tmpd/chain-writable"; mkdir -p "$_cd/Library/Logs/app"
  chmod 755 "$_cd/Library" "$_cd/Library/Logs"
  chmod 777 "$_cd/Library/Logs/app"
  export MDM_LOG_SKIP_OWNER_CHECK=1
  if _mdm_verify_dir_chain "$_cd/Library/Logs/app" "$_cd/Library/Logs"; then
    fail "mdm-install: 777 コンポーネントを許容してしまう"
  else
    pass "mdm-install: 書込可能コンポーネントを拒否"
  fi
  unset MDM_LOG_SKIP_OWNER_CHECK
)

# ── _mdm_open_log_fd: 既存 regular file は再利用せず別名・symlink は辿らない（R4-High）──
(
  _od="$_loghome/Library/Logs/openfd"; mkdir -p "$_od"
  MDM_LOG_FILE=""; MDM_LOG_FD_OPEN=0
  _mdm_open_log_fd "$_od/install-x.log" 2>/dev/null || fail "mdm-install: open_log_fd 失敗"
  [[ "$MDM_LOG_FILE" == "$_od/install-x.log" && -f "$MDM_LOG_FILE" && ! -L "$MDM_LOG_FILE" ]] \
    && pass "mdm-install: open_log_fd が新規ログを排他作成" \
    || fail "mdm-install: open_log_fd の新規作成が不正 (got '$MDM_LOG_FILE')"
  exec 7>&- 2>/dev/null || true; MDM_LOG_FD_OPEN=0
)
(
  # 攻撃者が予測パスに regular file を先置き → 再利用せず別名を作る
  _od="$_loghome/Library/Logs/openfd2"; mkdir -p "$_od"
  printf 'attacker\n' > "$_od/install-y.log"
  MDM_LOG_FILE=""; MDM_LOG_FD_OPEN=0
  _mdm_open_log_fd "$_od/install-y.log" 2>/dev/null || fail "mdm-install: open_log_fd(既存) 失敗"
  if [[ "$MDM_LOG_FILE" != "$_od/install-y.log" && -f "$MDM_LOG_FILE" ]] \
     && [[ "$(cat "$_od/install-y.log")" == "attacker" ]]; then
    pass "mdm-install: 既存 regular file を再利用せず別名で作成（先置き無視）"
  else
    fail "mdm-install: 既存ファイルを再利用してしまう (got '$MDM_LOG_FILE')"
  fi
  exec 7>&- 2>/dev/null || true; MDM_LOG_FD_OPEN=0
)
(
  # 攻撃者が予測パスに symlink を先置き → 辿らず標的無傷・実体化
  _od="$_loghome/Library/Logs/openfd3"; mkdir -p "$_od"
  printf 'victim\n' > "$_od/victim"
  ln -s "$_od/victim" "$_od/install-z.log"
  MDM_LOG_FILE=""; MDM_LOG_FD_OPEN=0
  _mdm_open_log_fd "$_od/install-z.log" 2>/dev/null || fail "mdm-install: open_log_fd(symlink) 失敗"
  if [[ ! -L "$MDM_LOG_FILE" && -f "$MDM_LOG_FILE" ]] \
     && [[ "$(cat "$_od/victim")" == "victim" ]]; then
    pass "mdm-install: 先置き symlink を辿らず実体化（標的無傷）"
  else
    fail "mdm-install: 先置き symlink を辿る/実体化しない"
  fi
  exec 7>&- 2>/dev/null || true; MDM_LOG_FD_OPEN=0
)
rm -rf "$_tmpd"

# ── MDM 既定値の適用（Ghostty は MDM 既定 off）──────────
# _mdm_root_config_apply と同じ「既存値は上書きしない」優先順位を踏襲する
# ことを確認する: 未設定時のみ false を既定にし、conf/env で明示済みの
# true/false はそのまま維持されなければならない。
(
  unset ENABLE_GHOSTTY_SETUP
  _mdm_apply_mdm_defaults
  if [[ "$ENABLE_GHOSTTY_SETUP" == "false" ]]; then
    pass "mdm-install: ENABLE_GHOSTTY_SETUP 未設定時は既定 false"
  else
    fail "mdm-install: ENABLE_GHOSTTY_SETUP 未設定時の既定が不正 (got '$ENABLE_GHOSTTY_SETUP')"
  fi
)
(
  export ENABLE_GHOSTTY_SETUP=true
  _mdm_apply_mdm_defaults
  if [[ "$ENABLE_GHOSTTY_SETUP" == "true" ]]; then
    pass "mdm-install: ENABLE_GHOSTTY_SETUP=true の明示指定を維持"
  else
    fail "mdm-install: ENABLE_GHOSTTY_SETUP=true の明示指定が上書きされた (got '$ENABLE_GHOSTTY_SETUP')"
  fi
)
(
  export ENABLE_GHOSTTY_SETUP=false
  _mdm_apply_mdm_defaults
  if [[ "$ENABLE_GHOSTTY_SETUP" == "false" ]]; then
    pass "mdm-install: ENABLE_GHOSTTY_SETUP=false の明示指定を維持"
  else
    fail "mdm-install: ENABLE_GHOSTTY_SETUP=false の明示指定が上書きされた (got '$ENABLE_GHOSTTY_SETUP')"
  fi
)

# ══ authoritative fresh 経路 + CLI 無効化の setup.sh 接続 ══

# 対象ユーザーの manifest の有無で --update に切り替えない
_tmpd="$(mktemp -d)"; _tmpd="$(cd "$_tmpd" && pwd -P)"
_updhome="$_tmpd/Users/jane"
mkdir -p "$_updhome/.claude"
(
  unset KIT_MDM_DRY_RUN
  mdm_build_setup_argv "$_updhome" 2>/dev/null || true
  _found=0
  for _e in "${MDM_SETUP_ARGV[@]}"; do [[ "$_e" == '--update' ]] && _found=1; done
  if [[ "$_found" -eq 1 ]]; then
    fail "mdm-install: manifest 無しなのに --update が付与された"
  else
    pass "mdm-install: manifest 無しでは --update を付けない"
  fi
)
touch "$_updhome/.claude/.starter-kit-manifest.json"
(
  unset KIT_MDM_DRY_RUN
  mdm_build_setup_argv "$_updhome" 2>/dev/null || true
  _found=0
  for _e in "${MDM_SETUP_ARGV[@]}"; do [[ "$_e" == '--update' ]] && _found=1; done
  [[ "$_found" -eq 0 ]] \
    && pass "mdm-install: 既存 manifest があっても authoritative fresh を維持" \
    || fail "mdm-install: 既存 manifest で --update に退行した (argv: ${MDM_SETUP_ARGV[*]})"
)

# root 実行時の CLI 確認は root の PATH を成功扱いにしない
(
  export MDM_EUID_OVERRIDE=0
  _rc=0
  _mdm_cli_present_for_home "$_updhome" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    pass "mdm-install: root 時は PATH 上の claude を成功扱いにしない"
  else
    fail "mdm-install: root 時に root PATH の claude で成功扱いになる"
  fi
)
(
  export MDM_EUID_OVERRIDE=0
  mkdir -p "$_updhome/.local/bin"
  printf '#!/bin/sh\nexit 0\n' > "$_updhome/.local/bin/claude"
  chmod +x "$_updhome/.local/bin/claude"
  _rc=0
  _mdm_cli_present_for_home "$_updhome" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -ne 0 ]] \
    && pass "mdm-install: 対象ユーザーの fake claude を拒否" \
    || fail "mdm-install: 未署名 fake claude を成功扱いにした"
  export MDM_CLAUDE_CLI_TRUST_OVERRIDE=1
  _mdm_cli_present_for_home "$_updhome" \
    && pass "mdm-install: source-only CLI trust override はテスト可能" \
    || fail "mdm-install: source-only CLI trust override が効かない"
)

# Identifier/TeamIdentifier/Authority are display fields, not a trust anchor.
# The verifier must pass an external Apple-anchored Developer ID requirement.
(
  _cli_requirement_log="$_updhome/cli-requirement.log"
  _cli_requirement="$(_mdm_claude_cli_codesign_requirement)"
  _mdm_claude_codesign() {
    if [[ "$1" == --verify ]]; then
      printf '%s\n' "$@" > "$_cli_requirement_log"
      return 0
    fi
    printf '%s\n' \
      'Identifier=com.anthropic.claude-code' \
      'Authority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)' \
      'TeamIdentifier=Q6L2SF6YDW'
  }
  if _mdm_claude_cli_signature_trusted /dev/null \
    && /usr/bin/grep -Fxq -- '-R' "$_cli_requirement_log" \
    && /usr/bin/grep -Fxq -- "$_cli_requirement" "$_cli_requirement_log" \
    && [[ "$_cli_requirement" == *'anchor apple generic'* ]] \
    && [[ "$_cli_requirement" == *'certificate 1[field.1.2.840.113635.100.6.2.6]'* ]] \
    && [[ "$_cli_requirement" == *'certificate leaf[field.1.2.840.113635.100.6.1.13]'* ]]; then
    pass "mdm-install: Claude CLI は明示 Apple Developer ID requirement で検証"
  else
    fail "mdm-install: Claude CLI codesign に外部 trust requirement がない"
  fi
)
(
  _spoof_details=$'Identifier=com.anthropic.claude-code\nAuthority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)\nTeamIdentifier=Q6L2SF6YDW'
  _mdm_claude_codesign() {
    [[ "$1" == --verify ]] && return 3
    printf '%s\n' "$_spoof_details"
  }
  if [[ "$_spoof_details" == *'TeamIdentifier=Q6L2SF6YDW'* ]] \
    && ! _mdm_claude_cli_signature_trusted /dev/null; then
    pass "mdm-install: 表示文字列を模倣した自己署名 CLI を拒否"
  else
    fail "mdm-install: 表示文字列だけで自己署名 CLI を許容し得る"
  fi
)
rm -rf "$_tmpd"

# setup.sh: KIT_MDM_INSTALL_CLAUDE_CLI=false で CLI 導入をスキップ。
# 隔離 bash プロセスで setup.sh を source し、導入関数をスタブして挙動を検証する。
_setup_cli_probe() {  # $1=policy（"__unset__"可）, $2=managed（既定true）
  local _probe_tmp _probe_home _probe_rc=0
  # The managed reinstall preflight may normalize or quarantine CLI paths.
  # Keep this unit probe completely isolated from the developer's real HOME.
  _probe_tmp="$(mktemp -d)" || return 1
  _probe_home="$(builtin cd -P "$_probe_tmp" && printf '%s' "$PWD")" || {
    /bin/rm -rf -- "$_probe_tmp"
    return 1
  }
  HOME="$_probe_home" PROJECT_DIR="$PROJECT_DIR" KIT_CLI_VAL="$1" \
    KIT_CLI_MANAGED="${2:-true}" /bin/bash -c '
    source "$PROJECT_DIR/setup.sh"
    set +u   # STR_*（i18n）はスタブ実行では未ロードのため
    info(){ :; }; ok(){ :; }; warn(){ :; }
    _prereq_mdm_managed() { [[ "${KIT_MDM_MANAGED:-}" == true ]]; }
    _prereq_mdm_fail_mode() { return 1; }
    _need_claude_cli_install(){ return 0; }
    _install_claude_cli(){ echo INSTALL_CALLED; }
    _add_to_path_now_and_persist(){ :; }
    if [[ "$KIT_CLI_VAL" != "__unset__" ]]; then
      export KIT_MDM_INSTALL_CLAUDE_CLI="$KIT_CLI_VAL"
    fi
    if [[ "$KIT_CLI_MANAGED" == "true" ]]; then
      export KIT_MDM_MANAGED=true
    else
      unset KIT_MDM_MANAGED
    fi
    install_claude_cli_if_needed
  ' 2>/dev/null || _probe_rc=$?
  /bin/rm -rf -- "$_probe_home"
  return "$_probe_rc"
}
(
  out="$(_setup_cli_probe false)" || true
  if printf '%s' "$out" | grep -q 'INSTALL_CALLED'; then
    fail "mdm-install: KIT_MDM_INSTALL_CLAUDE_CLI=false でも CLI 導入が実行される"
  else
    pass "mdm-install: KIT_MDM_INSTALL_CLAUDE_CLI=false で CLI 導入をスキップ"
  fi
)
(
  out="$(_setup_cli_probe false false)" || true
  printf '%s' "$out" | grep -q 'INSTALL_CALLED' \
    && pass "mdm-install: 非 MDM では同名 CLI policy env を無視" \
    || fail "mdm-install: 非 MDM の CLI 導入が MDM policy env に抑止された"
)
(
  out="$(_setup_cli_probe __unset__)" || true
  printf '%s' "$out" | grep -q 'INSTALL_CALLED' \
    && pass "mdm-install: KIT_MDM_INSTALL_CLAUDE_CLI 未設定では従来どおり導入" \
    || fail "mdm-install: 未設定なのに CLI 導入がスキップされた"
)
(
  # 不正値は fail-closed（導入する）— 検証済みでない値で機能を黙って無効化しない
  out="$(_setup_cli_probe garbage)" || true
  printf '%s' "$out" | grep -q 'INSTALL_CALLED' \
    && pass "mdm-install: KIT_MDM_INSTALL_CLAUDE_CLI 不正値は fail-closed で導入" \
    || fail "mdm-install: 不正値で CLI 導入がスキップされた（fail-open）"
)

# ── setup.sh 引数の組み立て（グローバル配列 MDM_SETUP_ARGV へ直接構築）──
# 実 setup.sh 実行は副作用があるため、argv 組み立て (mdm_build_setup_argv)
# のみを検証する。
_setup_argv_has() { local _e; for _e in "${MDM_SETUP_ARGV[@]}"; do [[ "$_e" == "$1" ]] && return 0; done; return 1; }
(
  unset KIT_MDM_DRY_RUN
  mdm_build_setup_argv 2>/dev/null
  _setup_argv_has '--non-interactive' \
    && pass "mdm-install: setup.sh argv に --non-interactive を含む" \
    || fail "mdm-install: setup.sh argv に --non-interactive が無い (argv: ${MDM_SETUP_ARGV[*]})"
  if _setup_argv_has '--dry-run'; then
    fail "mdm-install: KIT_MDM_DRY_RUN 未設定なのに --dry-run が含まれる"
  else
    pass "mdm-install: KIT_MDM_DRY_RUN 未設定時は --dry-run を含まない"
  fi
)
(
  export KIT_MDM_DRY_RUN=true
  mdm_build_setup_argv 2>/dev/null
  _setup_argv_has '--dry-run' \
    && pass "mdm-install: KIT_MDM_DRY_RUN=true で --dry-run を配線" \
    || fail "mdm-install: KIT_MDM_DRY_RUN=true なのに --dry-run が無い (argv: ${MDM_SETUP_ARGV[*]})"
)
(
  export KIT_MDM_DRY_RUN=false
  mdm_build_setup_argv 2>/dev/null
  if _setup_argv_has '--dry-run'; then
    fail "mdm-install: KIT_MDM_DRY_RUN=false なのに --dry-run が含まれる"
  else
    pass "mdm-install: KIT_MDM_DRY_RUN=false 時は --dry-run を含まない"
  fi
)

# CLI trust verification reads only an fd-bound, UID-checked private snapshot;
# hard-linked binaries are not accepted as an attestation source.
(
  _cli_bound_tmp="$(mktemp -d)"
  _cli_bound_src="$_cli_bound_tmp/claude"
  _cli_bound_dst="$_cli_bound_tmp/claude-copy"
  printf '#!/bin/sh\nexit 0\n' > "$_cli_bound_src"; chmod 500 "$_cli_bound_src"
  : > "$_cli_bound_dst"
  _cli_bound_uid="$(/usr/bin/id -u)"; _cli_bound_rc=0
  _mdm_snapshot_bound_to "$_cli_bound_src" "$_cli_bound_dst" cli \
    "$_cli_bound_uid" || _cli_bound_rc=$?
  _cli_bound_mode="$_MDM_BOUND_SNAPSHOT_MODE"
  _cli_bound_hard_rc=0
  ln "$_cli_bound_src" "$_cli_bound_tmp/claude-hard"
  : > "$_cli_bound_tmp/hard-copy"
  _mdm_snapshot_bound_to "$_cli_bound_src" "$_cli_bound_tmp/hard-copy" cli \
    "$_cli_bound_uid" >/dev/null 2>&1 || _cli_bound_hard_rc=$?
  if [[ "$_cli_bound_rc" -eq 0 && "$_cli_bound_mode" == 0500 ]] \
    && cmp -s "$_cli_bound_src" "$_cli_bound_dst" \
    && [[ "$_cli_bound_hard_rc" -ne 0 ]]; then
    pass "mdm-install: Claude CLI snapshot は UID/bytes を固定し hardlink を拒否"
  else
    fail "mdm-install: Claude CLI fd-bound snapshot 契約が不正"
  fi
  rm -rf "$_cli_bound_tmp"
)

# fd open が FIFO に差し替わっても watchdog で bounded に失敗する。
(
  _bound_tmp="$(mktemp -d)"; _bound_src="$_bound_tmp/source"; _bound_dst="$_bound_tmp/copy"
  _bound_swap="$_bound_tmp/swapped"
  printf 'regular\n' > "$_bound_src"; : > "$_bound_dst"
  export MDM_SNAPSHOT_WATCHDOG_SECONDS_OVERRIDE=1
  _mdm_stat_identity() {
    local _path="$1" _identity
    if [[ "$_path" == "$_bound_src" && ! -e "$_bound_swap" ]]; then
      if _mdm_is_darwin; then
        _identity="$(/usr/bin/stat -f '%i:%HT:%z' "$_path")"
      else
        _identity="$(/usr/bin/stat -c '%i:%F:%s' "$_path")"
      fi
      rm -f "$_path"; /usr/bin/mkfifo "$_path"; : > "$_bound_swap"
      printf '%s' "$_identity"
    elif _mdm_is_darwin; then
      /usr/bin/stat -f '%i:%HT:%z' "$_path" 2>/dev/null
    else
      /usr/bin/stat -c '%i:%F:%s' "$_path" 2>/dev/null
    fi
  }
  _bound_start="$SECONDS"; _bound_rc=0
  _mdm_snapshot_bound_to "$_bound_src" "$_bound_dst" manifest >/dev/null 2>&1 || _bound_rc=$?
  _bound_elapsed=$((SECONDS - _bound_start))
  if [[ "$_bound_rc" -ne 0 && "$_bound_elapsed" -le 4 && ! -e "$_bound_dst" ]] \
    && grep -Fq '/usr/bin/head -c "$_copy_limit"' "$PROJECT_DIR/mdm/install-mdm.sh" \
    && grep -Fq '[[ "$_copied_size" == "$_size" ]]' "$PROJECT_DIR/mdm/install-mdm.sh"; then
    pass "mdm-install: stable snapshot は FIFO/open と append を watchdog+bounded size で拒否"
  else
    fail "mdm-install: stable snapshot の bounded copy 契約が不正 (rc=$_bound_rc elapsed=$_bound_elapsed)"
  fi
  rm -f "$_bound_src"; rm -rf "$_bound_tmp"
)

# Component attestation の artifact digest は tree 内だけで完結する symlink
# を記録できる一方、tree 外参照・dangling link・複数名を持つ regular inode・
# ACL を権威ある入力として受理しない。内容変更も digest に反映する。
(
  _artifact_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _artifact_tree="$_artifact_tmp/tree"
  mkdir -p "$_artifact_tree/sub"
  printf 'payload-one\n' > "$_artifact_tree/sub/value"
  ln -s sub/value "$_artifact_tree/internal-link"
  _artifact_initial="$(_mdm_artifact_digest tree "$_artifact_tree" 2>/dev/null || true)"
  printf 'payload-two\n' > "$_artifact_tree/sub/value"
  _artifact_changed="$(_mdm_artifact_digest tree "$_artifact_tree" 2>/dev/null || true)"
  if [[ "$_artifact_initial" =~ ^[0-9a-f]{64}$ \
    && "$_artifact_changed" =~ ^[0-9a-f]{64}$ \
    && "$_artifact_initial" != "$_artifact_changed" ]]; then
    pass "mdm-install: artifact digest は内部相対 symlink を許可し内容変更を検出"
  else
    fail "mdm-install: artifact digest の内部 symlink/改変検出契約が不正"
  fi

  printf 'newline target\n' > "$_artifact_tree/sub/"$'value\n'
  ln -s $'sub/value\n' "$_artifact_tree/newline-link"
  _artifact_newline="$(_mdm_artifact_digest tree \
    "$_artifact_tree" 2>/dev/null || true)"
  if [[ "$_artifact_newline" =~ ^[0-9a-f]{64}$ ]]; then
    pass "mdm-install: artifact digest は末尾改行を含む symlink target を fd から保持"
  else
    fail "mdm-install: artifact digest の fd-bound symlink target 読取が不正"
  fi
  rm -f "$_artifact_tree/newline-link" "$_artifact_tree/sub/"$'value\n'

  rm -f "$_artifact_tree/internal-link"
  printf 'outside\n' > "$_artifact_tmp/outside"
  ln -s ../outside "$_artifact_tree/escaping-link"
  if _mdm_artifact_digest tree "$_artifact_tree" >/dev/null 2>&1; then
    fail "mdm-install: artifact digest が tree 外へ逃げる symlink を許可"
  else
    pass "mdm-install: artifact digest は tree 外 symlink を拒否"
  fi

  rm -f "$_artifact_tree/escaping-link"
  ln -s sub/missing "$_artifact_tree/dangling-link"
  if _mdm_artifact_digest tree "$_artifact_tree" >/dev/null 2>&1; then
    fail "mdm-install: artifact digest が dangling symlink を許可"
  else
    pass "mdm-install: artifact digest は dangling symlink を拒否"
  fi

  rm -f "$_artifact_tree/dangling-link"
  printf 'hardlink\n' > "$_artifact_tree/hardlink-source"
  ln "$_artifact_tree/hardlink-source" "$_artifact_tree/hardlink-alias"
  if _mdm_artifact_digest tree "$_artifact_tree" >/dev/null 2>&1; then
    fail "mdm-install: artifact digest が regular hardlink を許可"
  else
    pass "mdm-install: artifact digest は regular hardlink を拒否"
  fi

  rm -f "$_artifact_tree/hardlink-source" "$_artifact_tree/hardlink-alias"
  if _mdm_is_darwin; then
    printf 'xattr\n' > "$_artifact_tree/xattr-file"
    if /usr/bin/xattr -w com.cloudnative.mdm-test one \
      "$_artifact_tree/xattr-file" 2>/dev/null; then
      _artifact_xattr_one="$(_mdm_artifact_digest tree "$_artifact_tree" 2>/dev/null || true)"
      /usr/bin/xattr -w com.cloudnative.mdm-test two \
        "$_artifact_tree/xattr-file" 2>/dev/null || true
      _artifact_xattr_two="$(_mdm_artifact_digest tree "$_artifact_tree" 2>/dev/null || true)"
      if [[ "$_artifact_xattr_one" =~ ^[0-9a-f]{64}$ \
        && "$_artifact_xattr_two" =~ ^[0-9a-f]{64}$ \
        && "$_artifact_xattr_one" != "$_artifact_xattr_two" ]]; then
        pass "mdm-install: artifact digest は xattr 名・値の変更を検出"
      else
        fail "mdm-install: artifact digest が xattr 値の変更を検出しない"
      fi
    else
      skip "mdm-install: artifact digest xattr 値" "fixture filesystem does not support xattr"
    fi
    printf 'acl\n' > "$_artifact_tree/acl-file"
    if /bin/chmod +a 'everyone deny write' "$_artifact_tree/acl-file" 2>/dev/null; then
      if _mdm_artifact_digest tree "$_artifact_tree" >/dev/null 2>&1; then
        fail "mdm-install: artifact digest が ACL 付き entry を許可"
      else
        pass "mdm-install: artifact digest は ACL 付き entry を拒否"
      fi
    else
      skip "mdm-install: artifact digest ACL 拒否" "fixture filesystem does not support ACL"
    fi
  fi
  rm -rf "$_artifact_tmp"
)

# ~/.claude の copy-equivalence は directory allocation metadata を無視し、
# user-visible な bytes/link/mode/ACL/xattr を fd-bound capture で比較する。
(
  _copy_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _copy_source="$_copy_tmp/source"
  _copy_candidate="$_copy_tmp/candidate"
  mkdir -m 700 "$_copy_source" "$_copy_source/nested" "$_copy_candidate"
  printf 'user-content\n' > "$_copy_source/nested/user-file"
  printf 'other-content\n' > "$_copy_source/nested/other-file"
  chmod 600 "$_copy_source/nested/user-file" \
    "$_copy_source/nested/other-file"
  ln -s nested/user-file "$_copy_source/user-link"
  _copy_xattr_supported=false
  if _mdm_is_darwin && /usr/bin/xattr -w com.cloudnative.mdm-copy-test \
      original "$_copy_source/nested/user-file" 2>/dev/null; then
    _copy_xattr_supported=true
  fi
  cp -a "$_copy_source/." "$_copy_candidate/"
  chmod 700 "$_copy_candidate"
  _copy_source_digest="$(_mdm_copy_semantics_digest "$_copy_source" \
    2>/dev/null || true)"
  _copy_candidate_digest="$(_mdm_copy_semantics_digest "$_copy_candidate" \
    2>/dev/null || true)"
  if [[ "$_copy_source_digest" =~ ^[0-9a-f]{64}$ \
    && "$_copy_candidate_digest" == "$_copy_source_digest" \
    && -f "$_copy_candidate/nested/user-file" \
    && "$(/usr/bin/readlink "$_copy_candidate/user-link")" \
      == nested/user-file ]]; then
    pass "mdm-install: copy semantics は正常な cp -a の nested file/symlink を同値判定"
  else
    fail "mdm-install: copy semantics が正常な cp -a を拒否"
  fi
  _copy_artifact_digest="$(_mdm_artifact_digest tree "$_copy_source" \
    2>/dev/null || true)"
  _copy_combined="$(_mdm_artifact_copy_semantics_digests "$_copy_source" \
    2>/dev/null || true)"
  if [[ "$_copy_combined" =~ ^[0-9a-f]{64}:[0-9a-f]{64}$ \
    && "${_copy_combined%%:*}" == "$_copy_artifact_digest" \
    && "${_copy_combined#*:}" == "$_copy_source_digest" ]]; then
    pass "mdm-install: artifact/copy digest は同じ double capture から同値に算出"
  else
    fail "mdm-install: artifact/copy combined digest 契約が不正"
  fi

  rm -f "$_copy_candidate/nested/user-file"
  _copy_missing="$(_mdm_copy_semantics_digest "$_copy_candidate" \
    2>/dev/null || true)"
  [[ "$_copy_missing" != "$_copy_source_digest" ]] \
    && pass "mdm-install: copy semantics は nested user file 欠落を検出" \
    || fail "mdm-install: copy semantics が nested user file 欠落を見逃す"

  rm -rf "$_copy_candidate"
  mkdir -m 700 "$_copy_candidate"
  cp -a "$_copy_source/." "$_copy_candidate/"
  chmod 700 "$_copy_candidate"
  rm -f "$_copy_candidate/user-link"
  ln -s nested/other-file "$_copy_candidate/user-link"
  _copy_link_changed="$(_mdm_copy_semantics_digest "$_copy_candidate" \
    2>/dev/null || true)"
  [[ "$_copy_link_changed" =~ ^[0-9a-f]{64}$ \
    && "$_copy_link_changed" != "$_copy_source_digest" ]] \
    && pass "mdm-install: copy semantics は symlink target 不一致を検出" \
    || fail "mdm-install: copy semantics が symlink target 不一致を見逃す"

  rm -f "$_copy_candidate/user-link"
  ln -s nested/user-file "$_copy_candidate/user-link"
  chmod 400 "$_copy_candidate/nested/user-file"
  _copy_mode_changed="$(_mdm_copy_semantics_digest "$_copy_candidate" \
    2>/dev/null || true)"
  [[ "$_copy_mode_changed" =~ ^[0-9a-f]{64}$ \
    && "$_copy_mode_changed" != "$_copy_source_digest" ]] \
    && pass "mdm-install: copy semantics は mode 不一致を検出" \
    || fail "mdm-install: copy semantics が mode 不一致を見逃す"

  if [[ "$_copy_xattr_supported" == true ]]; then
    chmod 600 "$_copy_candidate/nested/user-file"
    /usr/bin/xattr -w com.cloudnative.mdm-copy-test changed \
      "$_copy_candidate/nested/user-file"
    _copy_xattr_changed="$(_mdm_copy_semantics_digest "$_copy_candidate" \
      2>/dev/null || true)"
    [[ "$_copy_xattr_changed" =~ ^[0-9a-f]{64}$ \
      && "$_copy_xattr_changed" != "$_copy_source_digest" ]] \
      && pass "mdm-install: copy semantics は Darwin xattr 不一致を検出" \
      || fail "mdm-install: copy semantics が Darwin xattr 不一致を見逃す"
  else
    skip "mdm-install: copy semantics Darwin xattr" \
      "fixture filesystem does not support xattr"
  fi
  if _mdm_is_darwin && /bin/chmod +a 'everyone deny write' \
      "$_copy_source/nested/user-file" 2>/dev/null; then
    rm -rf "$_copy_candidate"
    mkdir -m 700 "$_copy_candidate"
    cp -a "$_copy_source/." "$_copy_candidate/"
    chmod 700 "$_copy_candidate"
    _copy_acl_source="$(_mdm_copy_semantics_digest "$_copy_source" \
      2>/dev/null || true)"
    _copy_acl_preserved="$(_mdm_copy_semantics_digest "$_copy_candidate" \
      2>/dev/null || true)"
    /bin/chmod -N "$_copy_candidate/nested/user-file"
    _copy_acl_removed="$(_mdm_copy_semantics_digest "$_copy_candidate" \
      2>/dev/null || true)"
    if [[ "$_copy_acl_source" =~ ^[0-9a-f]{64}$ \
      && "$_copy_acl_preserved" == "$_copy_acl_source" \
      && "$_copy_acl_removed" =~ ^[0-9a-f]{64}$ \
      && "$_copy_acl_removed" != "$_copy_acl_source" ]]; then
      pass "mdm-install: copy semantics は Darwin ACL 保持と不一致を検出"
    else
      fail "mdm-install: copy semantics の Darwin ACL 比較が不正"
    fi
    /bin/chmod -N "$_copy_source/nested/user-file"
  else
    skip "mdm-install: copy semantics Darwin ACL" \
      "fixture filesystem does not support ACL"
  fi
  rm -rf "$_copy_tmp"
)

# Tree capture は pathname の再解決ではなく、root directory fd からの
# openat 相当操作へ束縛する。Darwin の symlink 自体を安全に読む O_SYMLINK
# も含め、path join/os.walk へ退行しないことを静的に固定する。
(
  _artifact_impl="$(/usr/bin/sed -n \
    '/^_mdm_artifact_digest()/,/^_mdm_stat_identity()/p' \
    "$PROJECT_DIR/mdm/install-mdm.sh")"
  if /usr/bin/grep -Fq 'dir_fd=' <<< "$_artifact_impl" \
    && /usr/bin/grep -Eq 'root_fd|rootfd|root_descriptor' \
      <<< "$_artifact_impl" \
    && /usr/bin/grep -Fq 'os.open(' <<< "$_artifact_impl" \
    && /usr/bin/grep -Fq 'O_NOFOLLOW' <<< "$_artifact_impl" \
    && /usr/bin/grep -Fq 'O_SYMLINK' <<< "$_artifact_impl" \
    && /usr/bin/grep -Fq 'freadlink' <<< "$_artifact_impl" \
    && /usr/bin/grep -Fq 'os.readlink(b"", dir_fd=descriptor)' \
      <<< "$_artifact_impl" \
    && ! /usr/bin/grep -Eq 'os\.readlink\((name|component),' \
      <<< "$_artifact_impl" \
    && ! /usr/bin/grep -Fq 'os.path.join(path, name)' \
      <<< "$_artifact_impl" \
    && ! /usr/bin/grep -Fq 'os.walk' <<< "$_artifact_impl"; then
    pass "mdm-install: artifact tree walker は root dirfd/openat 相当に束縛"
  else
    fail "mdm-install: artifact tree walker の dirfd 静的契約が不正"
  fi
)

# Component manifest writer を最小 componentで直接実行し、schema・identity・
# policy・mode/nlink/owner と特殊 destination の拒否を固定する。
(
  _component_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _component_support="$_component_tmp/support"
  _component_home="$_component_tmp/home"
  _component_kit="$_component_home/.claude-starter-kit"
  _component_guid="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
  _component_uid="$(/usr/bin/id -u)"
  mkdir -p "$_component_support" "$_component_kit"
  chmod 755 "$_component_support"
  printf 'kit\n' > "$_component_kit/setup.sh"
  export MDM_NODE_ARCH_OVERRIDE=arm64
  if [[ "$_component_uid" -lt 501 ]]; then
    _component_uid=501
    _component_chown="$(command -v chown || true)"
    [[ "$_component_chown" == /* && -x "$_component_chown" ]] \
      && "$_component_chown" -R "$_component_uid" "$_component_home"
  fi
  export MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_component_support"
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  MDM_RCPT_POLICY_SHA256="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  MDM_RCPT_COMPONENT_MANIFEST_PATH=""
  MDM_RCPT_COMPONENT_MANIFEST_SHA256=""
  _MDM_EXPECTED_KIT_COMPONENT_SHA256="$(_mdm_artifact_digest tree \
    "$_component_kit" 2>/dev/null || true)"
  MDM_REQUIRED_COMPONENTS=(kit)
  _component_rc=0
  _mdm_attest_components jane "$_component_home" "$_component_uid" \
    "$_component_guid" >/dev/null 2>&1 || _component_rc=$?
  _component_manifest="$_component_support/components-${_component_guid}.json"
  _component_meta="$(_mdm_stat_managed_metadata \
    "$_component_manifest" 2>/dev/null || true)"
  _component_rest="${_component_meta#*:}"
  _component_links="${_component_rest%%:*}"
  _component_mode="$(_mdm_mode_normalize \
    "${_component_rest#*:}" 2>/dev/null || true)"
  if [[ "$_component_rc" -eq 0 && "$_component_links" == 1 \
    && "$_component_mode" == 0600 ]] \
    && [[ "$(_mdm_stat_uid "$_component_manifest")" == "$(/usr/bin/id -u)" ]] \
    && ! _mdm_has_extended_acl "$_component_manifest" \
    && [[ "$MDM_RCPT_COMPONENT_MANIFEST_PATH" == "$_component_manifest" ]] \
    && [[ "$MDM_RCPT_COMPONENT_MANIFEST_SHA256" \
      == "$(_mdm_sha256_file "$_component_manifest")" ]] \
    && jq -e --arg home "$_component_home" --arg guid "$_component_guid" \
      --arg policy "$MDM_RCPT_POLICY_SHA256" --argjson uid "$_component_uid" \
      '.schema_version == 1 and .target_user == "jane"
       and .target_uid == $uid and .target_generated_uid == $guid
       and .policy_sha256 == $policy and (.entries | length) == 1
       and (keys | sort) == ["entries","policy_sha256","schema_version",
         "target_generated_uid","target_uid","target_user"]
       and all(.entries[]; (.component | type) == "string"
         and (keys | sort) == ["component","kind","path","sha256"]
         and (.path | type) == "string" and (.kind == "file" or .kind == "tree")
         and (.sha256 | test("^[0-9a-f]{64}$")))
       and ([.entries[].path] | index($home + "/.claude-starter-kit")) != null' \
      "$_component_manifest" >/dev/null; then
    pass "mdm-install: component manifest は schema 1・policy・identity・mode 600・test-owner・ACLなしを固定"
  else
    fail "mdm-install: component manifest の schema/identity/metadata 契約が不正"
  fi
  if jq -e \
    '.entries == (.entries | sort_by(.component, .path))
     and [.entries[].component] == ["kit"]' \
    "$_component_manifest" >/dev/null 2>&1; then
    pass "mdm-install: component manifest entries は component/path 順に canonical sort"
  else
    fail "mdm-install: component manifest entries が canonical sort されない"
  fi

  _component_extra_manifest="$_component_tmp/components-extra.json"
  jq '.unexpected=true' "$_component_manifest" > "$_component_extra_manifest"
  if _mdm_component_generated_manifest_is_exact \
    "$_component_extra_manifest" "$_component_home" jane "$_component_uid" \
    "$_component_guid" "$MDM_RCPT_POLICY_SHA256" \
    kit >/dev/null 2>&1; then
    fail "mdm-install: component manifest の未知 top-level key を許可"
  else
    pass "mdm-install: component manifest は schema 1 の exact keys のみ許可"
  fi
  _component_duplicate_manifest="$_component_tmp/components-duplicate.json"
  /usr/bin/awk 'NR == 2 { print; print "  \"schema_version\": 1,"; next }
    { print }' "$_component_manifest" > "$_component_duplicate_manifest"
  if _mdm_component_generated_manifest_is_exact \
    "$_component_duplicate_manifest" "$_component_home" jane \
    "$_component_uid" "$_component_guid" "$MDM_RCPT_POLICY_SHA256" \
    kit >/dev/null 2>&1; then
    fail "mdm-install: component manifest の duplicate JSON key を許可"
  else
    pass "mdm-install: component manifest は duplicate JSON key を拒否"
  fi

  _component_noncanonical_ok=1
  for _component_suffix in lf space tab cr nul; do
    _component_noncanonical="$_component_tmp/components-${_component_suffix}.json"
    cp "$_component_manifest" "$_component_noncanonical"
    case "$_component_suffix" in
      lf) printf '\n' >> "$_component_noncanonical" ;;
      space) printf ' ' >> "$_component_noncanonical" ;;
      tab) printf '\t' >> "$_component_noncanonical" ;;
      cr) printf '\r' >> "$_component_noncanonical" ;;
      nul) printf '\0' >> "$_component_noncanonical" ;;
    esac
    if _mdm_component_generated_manifest_is_exact \
      "$_component_noncanonical" "$_component_home" jane \
      "$_component_uid" "$_component_guid" "$MDM_RCPT_POLICY_SHA256" \
      kit >/dev/null 2>&1; then
      _component_noncanonical_ok=0
    fi
  done
  _component_noncanonical="$_component_tmp/components-no-lf.json"
  _component_size="$(/usr/bin/wc -c < "$_component_manifest" \
    | /usr/bin/tr -d '[:space:]')"
  /bin/dd if="$_component_manifest" of="$_component_noncanonical" bs=1 \
    count=$((_component_size - 1)) 2>/dev/null
  if _mdm_component_generated_manifest_is_exact \
    "$_component_noncanonical" "$_component_home" jane \
    "$_component_uid" "$_component_guid" "$MDM_RCPT_POLICY_SHA256" \
    kit >/dev/null 2>&1; then
    _component_noncanonical_ok=0
  fi
  if [[ "$_component_noncanonical_ok" -eq 1 ]]; then
    pass "mdm-install: component manifest は writer canonical bytes だけ許可"
  else
    fail "mdm-install: component manifest の EOF/whitespace drift を許可"
  fi

  _component_sort_fixture="$_component_tmp/component-sort.jsonl"
  printf '%s\n' \
    '{"component":"fonts","path":"/tmp/\u0062","kind":"file","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
    '{"component":"fonts","path":"/tmp/a","kind":"file","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' \
    > "$_component_sort_fixture"
  if _mdm_component_sort_entries "$_component_sort_fixture" \
    && jq -s -e '[.[].path] == ["/tmp/a","/tmp/b"]' \
      "$_component_sort_fixture" >/dev/null; then
    pass "mdm-install: component/path は JSON decode 後の値で canonical sort"
  else
    fail "mdm-install: component/path の decoded-value sort が不正"
  fi
  printf '%s\n' \
    '{"component":"fonts","path":"/tmp/a","kind":"file","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
    '{"component":"fonts","path":"/tmp/\u0061","kind":"file","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' \
    > "$_component_sort_fixture"
  if _mdm_component_sort_entries "$_component_sort_fixture" \
    >/dev/null 2>&1; then
    fail "mdm-install: decoded component/path duplicate を許可"
  else
    pass "mdm-install: decoded component/path duplicate を拒否"
  fi
  printf '%s\n' \
    '{"component":"kit","component":"kit","path":"/tmp/kit","kind":"tree","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
    > "$_component_sort_fixture"
  if _mdm_component_sort_entries "$_component_sort_fixture" \
    >/dev/null 2>&1; then
    fail "mdm-install: component entry の duplicate JSON key を許可"
  else
    pass "mdm-install: component entry の duplicate JSON key を拒否"
  fi

  MDM_REQUIRED_COMPONENTS=(kit)
  rm -f "$_component_manifest"
  chmod 775 "$_component_support"
  _component_untrusted_dir_rc=0
  _mdm_attest_components jane "$_component_home" "$_component_uid" \
    "$_component_guid" >/dev/null 2>&1 || _component_untrusted_dir_rc=$?
  chmod 755 "$_component_support"
  if [[ "$_component_untrusted_dir_rc" -ne 0 \
    && ! -e "$_component_manifest" ]]; then
    pass "mdm-install: component manifest 書込直前に receipt dir trust を再検査"
  else
    fail "mdm-install: untrusted receipt dir へ component manifest を書込み"
  fi

  rm -f "$_component_manifest"
  mkdir "$_component_manifest"
  _component_special_rc=0
  _mdm_attest_components jane "$_component_home" "$_component_uid" \
    "$_component_guid" >/dev/null 2>&1 || _component_special_rc=$?
  if [[ "$_component_special_rc" -ne 0 && -d "$_component_manifest" ]]; then
    pass "mdm-install: component manifest destination の directory を拒否"
  else
    fail "mdm-install: component manifest destination の directory を許可/破壊"
  fi
  rmdir "$_component_manifest"
  /usr/bin/mkfifo "$_component_manifest"
  _component_special_rc=0
  _mdm_attest_components jane "$_component_home" "$_component_uid" \
    "$_component_guid" >/dev/null 2>&1 || _component_special_rc=$?
  if [[ "$_component_special_rc" -ne 0 && -p "$_component_manifest" ]]; then
    pass "mdm-install: component manifest destination の FIFO を拒否"
  else
    fail "mdm-install: component manifest destination の FIFO を許可/破壊"
  fi
  rm -f "$_component_manifest"
  _component_dir_victim="$_component_support/component-victim-dir"
  mkdir "$_component_dir_victim"
  ln -s "$_component_dir_victim" "$_component_manifest"
  _component_special_rc=0
  _mdm_attest_components jane "$_component_home" "$_component_uid" \
    "$_component_guid" >/dev/null 2>&1 || _component_special_rc=$?
  if [[ "$_component_special_rc" -eq 0 && -f "$_component_manifest" \
    && ! -L "$_component_manifest" \
    && -z "$(/bin/ls -A "$_component_dir_victim")" ]]; then
    pass "mdm-install: directory向けsymlinkを除去し外部へroot fileを書かない"
  else
    fail "mdm-install: component manifest のsymlink-to-directory処理が不正"
  fi
  rm -f "$_component_manifest"
  rmdir "$_component_dir_victim"
  _component_victim="$_component_support/component-victim"
  printf 'victim\n' > "$_component_victim"
  ln -s "$_component_victim" "$_component_manifest"
  _component_special_rc=0
  _mdm_attest_components jane "$_component_home" "$_component_uid" \
    "$_component_guid" >/dev/null 2>&1 || _component_special_rc=$?
  if [[ "$_component_special_rc" -eq 0 && -f "$_component_manifest" \
    && ! -L "$_component_manifest" ]] \
    && [[ "$(cat "$_component_victim")" == victim ]] \
    && jq -e '.schema_version == 1' "$_component_manifest" >/dev/null; then
    pass "mdm-install: component manifest の symlink を標的無傷で実体化"
  else
    fail "mdm-install: component manifest symlink の安全な回復契約が不正"
  fi
  rm -rf "$_component_tmp"
)

# Runtime entriesはgeneric path regexやuser node_modulesでなく、同じroot
# helperが返すexact treeへ束縛する。
(
  _runtime_manifest_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _runtime_manifest="$_runtime_manifest_tmp/components.json"
  _runtime_home="$_runtime_manifest_tmp/home"
  _runtime_node="$_runtime_manifest_tmp/system/node-v24.18.0-darwin-arm64"
  _runtime_wce="$_runtime_manifest_tmp/system/wce-pinned-bundle"
  _runtime_guid="CCCCCCCC-DDDD-EEEE-FFFF-AAAAAAAAAAAA"
  _runtime_policy="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  _mdm_node_runtime_path() { printf '%s' "$_runtime_node"; }
  _mdm_wce_runtime_path() { printf '%s' "$_runtime_wce"; }
  _MDM_WCE_PACKAGE_SHA256="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  _MDM_WCE_LOCK_SHA256="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  _runtime_write_manifest() { # <output> <wce-path>
    local _output="$1" _wce_path="$2"
    {
      printf '{\n  "schema_version": 1,\n'
      printf '  "target_user": "jane",\n'
      printf '  "target_uid": 501,\n'
      printf '  "target_generated_uid": "%s",\n' "$_runtime_guid"
      printf '  "policy_sha256": "%s",\n' "$_runtime_policy"
      printf '  "entries": [\n'
      printf '    {"component":"kit","kind":"tree","path":"%s","sha256":"%s"},\n' \
        "$(mdm_json_escape "$_runtime_home/.claude-starter-kit")" \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      printf '    {"component":"node_runtime","kind":"tree","path":"%s","sha256":"%s"},\n' \
        "$(mdm_json_escape "$_runtime_node")" \
        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      printf '    {"component":"web_content_runtime","kind":"tree","path":"%s","sha256":"%s"}\n' \
        "$(mdm_json_escape "$_wce_path")" \
        cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
      printf '  ]\n}\n'
    } > "$_output"
  }
  _runtime_write_manifest "$_runtime_manifest" "$_runtime_wce"
  _runtime_exact_rc=0
  _mdm_component_generated_manifest_is_exact "$_runtime_manifest" \
    "$_runtime_home" jane 501 "$_runtime_guid" "$_runtime_policy" \
    kit node_runtime web_content_runtime >/dev/null 2>&1 \
    || _runtime_exact_rc=$?
  _runtime_write_manifest "$_runtime_manifest_tmp/old-user-runtime.json" \
    "$_runtime_home/.claude/skills/web-content-extraction/node_modules"
  _runtime_old_rc=0
  _mdm_component_generated_manifest_is_exact \
    "$_runtime_manifest_tmp/old-user-runtime.json" "$_runtime_home" jane 501 \
    "$_runtime_guid" "$_runtime_policy" kit node_runtime web_content_runtime \
    >/dev/null 2>&1 || _runtime_old_rc=$?
  if [[ "$_runtime_exact_rc" -eq 0 && "$_runtime_old_rc" -ne 0 ]]; then
    pass "mdm-install: Node/WCE manifest entryはhelper-derived exact rootへ束縛"
  else
    fail "mdm-install: runtime component のexact path契約が不正"
  fi
  rm -rf "$_runtime_manifest_tmp"
)

(
  _wce_timeout_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _MDM_TEST_MODE=1
  MDM_EUID_OVERRIDE=501
  # Consumed indirectly by the sourced production helpers.
  # shellcheck disable=SC2034
  MDM_TIMEOUT_OVERRIDE_SECONDS=1
  TMPDIR="$_wce_timeout_tmp"
  # shellcheck disable=SC2034
  MDM_WCE_RUNTIME_ROOT_OVERRIDE="$_wce_timeout_tmp/runtime"
  # shellcheck disable=SC2034
  MDM_WCE_ARCH_OVERRIDE=arm64
  unset HTTP_PROXY HTTPS_PROXY NO_PROXY
  _wce_node="$_wce_timeout_tmp/node"
  /bin/mkdir -p "$_wce_node/bin" \
    "$_wce_node/lib/node_modules/npm/bin"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$_wce_node/bin/node"
  /bin/chmod 700 "$_wce_node/bin/node"
  : > "$_wce_node/lib/node_modules/npm/bin/npm-cli.js"
  _mdm_node_runtime_path() { printf '%s' "$_wce_node"; }
  _mdm_node_runtime_trusted() { return 0; }
  _mdm_wce_runtime_source_hashes() {
    printf -v "$1" '%s' "$_MDM_WCE_PACKAGE_SHA256"
    printf -v "$2" '%s' "$_MDM_WCE_LOCK_SHA256"
  }
  _mdm_wce_runtime_prepare_base() {
    /bin/mkdir -p "${_wce_target%/*}"
  }
  _mdm_wce_runtime_copy_sources() {
    printf 'new-runtime\n' > "$1/package.json"
    printf 'lock\n' > "$1/package-lock.json"
  }
  _mdm_wce_runtime_write_marker() { return 0; }
  _mdm_wce_runtime_normalize_stage() { return 0; }
  _mdm_wce_runtime_trusted() { return 0; }
  _mdm_wce_runtime_promote() { /bin/mv "$1" "$2"; }
  _mdm_wce_runtime_npm_command() {
    printf '%s\n' "$*" >> "$_wce_timeout_tmp/npm.log"
    if [[ "$_wce_npm_mode" == hang ]]; then
      trap '' TERM
      while :; do /bin/sleep 1; done
    fi
    printf 'npm-complete\n' > "$PWD/npm-complete"
  }
  _wce_target="$(_mdm_wce_runtime_path)"
  /bin/mkdir -p "$_wce_target"
  printf 'old-runtime\n' > "$_wce_target/old-sentinel"
  _wce_npm_mode=hang
  _wce_timeout_started=$SECONDS
  _wce_timeout_rc=0
  _mdm_wce_runtime_rebuild "$_wce_target" \
    >/dev/null 2>&1 || _wce_timeout_rc=$?
  _wce_timeout_elapsed=$((SECONDS - _wce_timeout_started))
  _wce_old_preserved=false
  [[ "$(/bin/cat "$_wce_target/old-sentinel" 2>/dev/null || true)" \
    == old-runtime ]] && _wce_old_preserved=true
  _wce_npm_mode=retry
  _wce_retry_rc=0
  _mdm_wce_runtime_rebuild "$_wce_target" \
    >/dev/null 2>&1 || _wce_retry_rc=$?
  if [[ "$_wce_timeout_rc" -ne 0 && "$_wce_timeout_elapsed" -le 5 \
    && "$_wce_old_preserved" == true && "$_wce_retry_rc" -eq 0 \
    && -f "$_wce_target/npm-complete" && ! -e "$_wce_target/old-sentinel" \
    && "$(/usr/bin/wc -l < "$_wce_timeout_tmp/npm.log" | /usr/bin/tr -d ' ')" -eq 2 ]] \
    && ! /usr/bin/find "${_wce_target%/*}" -maxdepth 1 \
      \( -name '.wce-stage.*' -o -name '.wce-work.*' \) \
      -print -quit | /usr/bin/grep -q . \
    && ! /usr/bin/find "$_wce_timeout_tmp" -maxdepth 1 \
      -name 'claude-kit-mdm-timeout.*' -print -quit | /usr/bin/grep -q .; then
    pass "mdm-install: npm ci は900秒で停止し旧runtime保持・cleanup後に即時再構築"
  else
    fail "mdm-install: npm timeout rollback/retry 契約が不正"
  fi
  /bin/rm -rf "$_wce_timeout_tmp"
)

# required_components は private Node を必要とする component と完全同期する。
# Biome は native pinned binary なので単独では Node を要求しない。
(
  _required_tmp="$(mktemp -d)"
  _MDM_EXPECTED_OUTPUT="$_required_tmp"
  KIT_MDM_INSTALL_CLAUDE_CLI=false
  _required_write() {
    jq -n --argjson components "$1" \
      '{required_components:$components}' > "$_required_tmp/manifest.json"
  }
  _required_write '["biome","kit"]'
  _required_biome=0
  _mdm_load_expected_required_components >/dev/null 2>&1 \
    || _required_biome=$?
  _required_write '["kit","node_runtime","safety_net"]'
  _required_safety=0
  _mdm_load_expected_required_components >/dev/null 2>&1 \
    || _required_safety=$?
  _required_write '["kit","safety_net"]'
  _required_missing_safety=0
  _mdm_load_expected_required_components >/dev/null 2>&1 \
    || _required_missing_safety=$?
  _required_write '["kit","web_content_runtime"]'
  _required_missing_web=0
  _mdm_load_expected_required_components >/dev/null 2>&1 \
    || _required_missing_web=$?
  _required_write '["kit","node_runtime"]'
  _required_orphan=0
  _mdm_load_expected_required_components >/dev/null 2>&1 \
    || _required_orphan=$?
  if [[ "$_required_biome" -eq 0 && "$_required_safety" -eq 0 \
    && "$_required_missing_safety" -ne 0 \
    && "$_required_missing_web" -ne 0 && "$_required_orphan" -ne 0 ]]; then
    pass "mdm-install: required set は safety/WCE と node_runtime を iff で同期"
  else
    fail "mdm-install: required set の private Node dependency invariant が不正"
  fi
  rm -rf "$_required_tmp"
)

# Biome/Safety launcher は versioned private tree への exact relative symlink
# だけを許可し、対象 UID からの実行可否は macOS の /bin/test で確認する。
(
  _launcher_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _launcher_home="$_launcher_tmp/home"
  _launcher_uid="$(/usr/bin/id -u)"
  mkdir -p \
    "$_launcher_home/.local/bin" \
    "$_launcher_home/.local/lib/claude-code-starter-kit/biome/2.5.4" \
    "$_launcher_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6/bin"
  printf '#!/bin/bash\nexit 0\n' \
    > "$_launcher_home/.local/lib/claude-code-starter-kit/biome/2.5.4/biome"
  printf '#!/bin/bash\nexit 0\n' \
    > "$_launcher_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6/bin/cc-safety-net"
  chmod 755 \
    "$_launcher_home/.local/lib/claude-code-starter-kit/biome/2.5.4/biome" \
    "$_launcher_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6/bin/cc-safety-net"
  ln -s ../lib/claude-code-starter-kit/biome/2.5.4/biome \
    "$_launcher_home/.local/bin/biome"
  ln -s ../lib/claude-code-starter-kit/cc-safety-net/1.0.6/bin/cc-safety-net \
    "$_launcher_home/.local/bin/cc-safety-net"
  _mdm_exec_as_user() { shift 3; "$@"; }
  _mdm_has_extended_acl() { return 1; }
  _launcher_biome="" _launcher_safety=""
  if [[ "$_launcher_uid" -ge 501 ]] \
    && _mdm_component_fixed_launcher "$_launcher_uid" test \
      "$_launcher_home" biome 2.5.4 biome _launcher_biome \
    && _mdm_component_fixed_launcher "$_launcher_uid" test \
      "$_launcher_home" cc-safety-net 1.0.6 bin/cc-safety-net \
      _launcher_safety \
    && [[ "$_launcher_biome" == \
      "$_launcher_home/.local/lib/claude-code-starter-kit/biome/2.5.4/biome" \
      && "$_launcher_safety" == \
      "$_launcher_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6/bin/cc-safety-net" ]]; then
    pass "mdm-install: Biome/Safety launcher は fixed version tree へ束縛"
  elif [[ "$_launcher_uid" -lt 501 ]]; then
    skip "mdm-install: Biome/Safety fixed launcher" "test UID is below 501"
  else
    fail "mdm-install: Biome/Safety fixed launcher 契約が不正"
  fi
  _launcher_biome_hardlink="$_launcher_home/.local/bin/biome-hardlink"
  if /bin/ln -P "$_launcher_home/.local/bin/biome" \
    "$_launcher_biome_hardlink" 2>/dev/null; then
    _launcher_hardlink_rc=0
    _mdm_component_fixed_launcher "$_launcher_uid" test \
      "$_launcher_home" biome 2.5.4 biome _launcher_biome \
      >/dev/null 2>&1 || _launcher_hardlink_rc=$?
    rm -f "$_launcher_biome_hardlink"
    if [[ "$_launcher_hardlink_rc" -ne 0 ]]; then
      pass "mdm-install: fixed launcher のsymlink hardlinkを拒否"
    else
      fail "mdm-install: fixed launcher のnlink>1 symlinkを許可"
    fi
  else
    skip "mdm-install: fixed launcher hardlink" "symlink hardlink unsupported"
  fi
  rm -f "$_launcher_home/.local/bin/biome"
  ln -s "$_launcher_home/.local/lib/claude-code-starter-kit/biome/2.5.4/biome" \
    "$_launcher_home/.local/bin/biome"
  if [[ "$_launcher_uid" -ge 501 ]] \
    && _mdm_component_fixed_launcher "$_launcher_uid" test \
      "$_launcher_home" biome 2.5.4 biome _launcher_biome \
      >/dev/null 2>&1; then
    fail "mdm-install: Biome launcher の absolute symlink を許可"
  else
    pass "mdm-install: fixed launcher は exact relative symlink 以外を拒否"
  fi
  _launcher_impl="$(declare -f _mdm_component_resolve_command; \
    declare -f _mdm_component_fixed_executable; \
    declare -f _mdm_component_fixed_launcher)"
  if [[ "$_launcher_impl" == *'/bin/test -x'* \
    && "$_launcher_impl" != *'/usr/bin/test -x'* ]]; then
    pass "mdm-install: macOS executable test は /bin/test に固定"
  else
    fail "mdm-install: executable test に /usr/bin/test が残存"
  fi
  rm -rf "$_launcher_tmp"
)

# Root issuer は user phase の launcher 観測だけを信頼せず、固定 version
# tree の exact shape・payload pin・mode・Safety wrapper binding を再検証する。
(
  export LC_ALL=C.UTF-8
  _semantic_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _semantic_home="$_semantic_tmp/home 利用者"
  _semantic_biome="$_semantic_home/.local/lib/claude-code-starter-kit/biome/2.5.4"
  _semantic_safety="$_semantic_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6"
  _semantic_node="/Library/Application Support/ClaudeCodeStarterKit/runtime/node-v24.18.0-darwin-arm64/bin/node"
  mkdir -p "$_semantic_biome" "$_semantic_safety/bin" \
    "$_semantic_safety/dist/bin"
  printf 'pinned-biome\n' > "$_semantic_biome/biome"
  printf '{}\n' > "$_semantic_biome/package.json"
  printf 'pinned-js\n' > "$_semantic_safety/dist/bin/cc-safety-net.js"
  printf '{}\n' > "$_semantic_safety/package.json"
  _semantic_write_safety_wrapper() {
    local output="$1" node="$2" script="$3" LC_ALL=C
    printf '#!/bin/bash\nunset NODE_OPTIONS NODE_PATH\nexec %q %q "$@"\n' \
      "$node" "$script" > "$output"
  }
  _semantic_write_safety_wrapper \
    "$_semantic_safety/bin/cc-safety-net" "$_semantic_node" \
    "$_semantic_safety/dist/bin/cc-safety-net.js"
  chmod 755 "$_semantic_biome/biome" \
    "$_semantic_safety/bin/cc-safety-net"
  chmod 644 "$_semantic_biome/package.json" \
    "$_semantic_safety/dist/bin/cc-safety-net.js" \
    "$_semantic_safety/package.json"
  _mdm_node_runtime_arch() { printf '%s' arm64; }
  _semantic_bad=""
  _mdm_sha256_file() {
    case "$1" in
      "$_semantic_biome/biome")
        [[ "$_semantic_bad" != biome ]] || { printf '%064d' 0; return; }
        printf '%s' 1250bb41a0409cf6c3133fc47819237eb61251624297f87158d2bed3ec123c3c ;;
      "$_semantic_biome/package.json")
        printf '%s' 54947a4827f0a6960d84eae39de98dba707b6f9222a276beaaa54ab4014dc68c ;;
      "$_semantic_safety/dist/bin/cc-safety-net.js")
        printf '%s' 1ffbfafabf2fe4fc9b6bf64a8088ca3a96c2714cf8fd8afd5b1b326582c982d4 ;;
      "$_semantic_safety/package.json")
        printf '%s' 2e57b465553ba97e1e6f7a37655fc52e31cad4ca739140bb7af40d052e3d88c8 ;;
      *) return 1 ;;
    esac
  }
  _semantic_valid=0
  _mdm_component_biome_tree_is_trusted \
    "$_semantic_biome" "$_semantic_biome/biome" \
    && _mdm_component_safety_tree_is_trusted "$_semantic_home" \
      "$_semantic_safety" "$_semantic_safety/bin/cc-safety-net" \
      "$_semantic_node" || _semantic_valid=$?
  printf '\0' >> "$_semantic_safety/bin/cc-safety-net"
  _semantic_wrapper_nul_rc=0
  _mdm_component_safety_tree_is_trusted "$_semantic_home" \
    "$_semantic_safety" "$_semantic_safety/bin/cc-safety-net" \
    "$_semantic_node" >/dev/null 2>&1 || _semantic_wrapper_nul_rc=$?
  _semantic_write_safety_wrapper \
    "$_semantic_safety/bin/cc-safety-net" "$_semantic_node" \
    "$_semantic_safety/dist/bin/cc-safety-net.js"
  chmod 755 "$_semantic_safety/bin/cc-safety-net"
  _semantic_bad=biome
  _semantic_hash_rc=0
  _mdm_component_biome_tree_is_trusted \
    "$_semantic_biome" "$_semantic_biome/biome" >/dev/null 2>&1 \
    || _semantic_hash_rc=$?
  _semantic_bad=""
  printf 'extra\n' > "$_semantic_biome/extra"
  _semantic_shape_rc=0
  _mdm_component_biome_tree_is_trusted \
    "$_semantic_biome" "$_semantic_biome/biome" >/dev/null 2>&1 \
    || _semantic_shape_rc=$?
  rm -f "$_semantic_biome/extra"
  printf 'extra\n' >> "$_semantic_safety/bin/cc-safety-net"
  _semantic_wrapper_rc=0
  _mdm_component_safety_tree_is_trusted "$_semantic_home" \
    "$_semantic_safety" "$_semantic_safety/bin/cc-safety-net" \
    "$_semantic_node" >/dev/null 2>&1 || _semantic_wrapper_rc=$?
  if [[ "$_semantic_valid" -eq 0 && "$_semantic_wrapper_nul_rc" -ne 0 \
    && "$_semantic_hash_rc" -ne 0 && "$_semantic_shape_rc" -ne 0 \
    && "$_semantic_wrapper_rc" -ne 0 ]]; then
    pass "mdm-install: Biome/Safety issuer は fixed payload/shape/wrapper を検証"
  else
    fail "mdm-install: Biome/Safety issuer の semantic pin 契約が不正"
  fi
  rm -rf "$_semantic_tmp"
)

# Issuer と detector は Ghostty の Apple Developer ID requirement と表示
# authority chainを同一に扱い、実 main executable 自体も要求する。
(
  _ghost_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _ghost_app="$_ghost_tmp/Ghostty.app"
  _ghost_bin="$_ghost_app/Contents/MacOS/ghostty"
  _ghost_log="$_ghost_tmp/codesign.log"
  mkdir -p "${_ghost_bin%/*}"
  printf '#!/bin/bash\nexit 0\n' > "$_ghost_bin"
  chmod 755 "$_ghost_bin"
  _ghost_details=$'Identifier=com.mitchellh.ghostty\nAuthority=Developer ID Application: Mitchell Hashimoto (24VZTF6M5V)\nAuthority=Developer ID Certification Authority\nAuthority=Apple Root CA\nTeamIdentifier=24VZTF6M5V'
  _ghost_quarantined=false
  _ghost_xattr_args=()
  _mdm_component_ghostty_codesign() {
    if [[ "$1" == --verify ]]; then
      printf '%s\n' "$@" > "$_ghost_log"
      return 0
    fi
    printf '%s\n' "$_ghost_details" >&2
  }
  _mdm_component_ghostty_xattr() {
    _ghost_xattr_args=("$@")
    [[ "$_ghost_quarantined" == true ]]
  }
  _ghost_detect_requirement="$(MDM_SOURCE_ONLY=1 /bin/bash -c \
    '. "$1"; _mdm_ghostty_codesign_requirement' _ \
    "$PROJECT_DIR/mdm/detect-mdm.sh")"
  _ghost_install_requirement="$(_mdm_component_ghostty_codesign_requirement)"
  if _mdm_component_ghostty_signed "$_ghost_app" \
    && [[ "$_ghost_install_requirement" == "$_ghost_detect_requirement" ]] \
    && /usr/bin/grep -Fxq -- "$_ghost_install_requirement" "$_ghost_log"; then
    pass "mdm-install: Ghostty trust requirement は detector と byte-exact"
  else
    fail "mdm-install: Ghostty trust requirement/authority 契約が不正"
  fi
  chmod 644 "$_ghost_bin"
  if _mdm_component_ghostty_signed "$_ghost_app" >/dev/null 2>&1; then
    fail "mdm-install: 非 executable Ghostty main binary を許可"
  else
    pass "mdm-install: Ghostty main binary に /bin/test -x を要求"
  fi
  chmod 755 "$_ghost_bin"
  _ghost_quarantined=true
  if _mdm_component_ghostty_signed "$_ghost_app" >/dev/null 2>&1; then
    fail "mdm-install: quarantine付きGhosttyを許可"
  elif [[ "${#_ghost_xattr_args[@]}" -eq 4 \
    && "${_ghost_xattr_args[0]}" == -p \
    && "${_ghost_xattr_args[1]}" == com.apple.quarantine \
    && "${_ghost_xattr_args[2]}" == -- \
    && "${_ghost_xattr_args[3]}" == "$_ghost_app" ]]; then
    pass "mdm-install: quarantine付きGhosttyをreceipt発行前に拒否"
  else
    fail "mdm-install: Ghostty quarantine検査の引数が不正"
  fi
  _ghost_quarantined=false
  _ghost_details="${_ghost_details/Mitchell Hashimoto/Spoof}"
  if _mdm_component_ghostty_signed "$_ghost_app" >/dev/null 2>&1; then
    fail "mdm-install: Ghostty の spoofed Authority を許可"
  else
    pass "mdm-install: Ghostty codesign authorities を exact match"
  fi
  rm -rf "$_ghost_tmp"
)

# Font issuer inventory is the exact 16 IBM + 4 HackGen files deployed by
# lib/fonts-mdm.sh. Matching extra files remain user data and are not sealed.
(
  _font_lib_inventory="$(/bin/bash -c '
    . "$1"
    for family in ibm hackgen; do
      while read -r name sha; do
        printf "%s %s %s\n" "$name" "$sha" "$family"
      done < <(_font_mdm_expected_inventory "$family")
    done
  ' _ "$PROJECT_DIR/lib/fonts-mdm.sh")"
  _font_issuer_inventory="$(_mdm_component_font_expected_inventory)"
  if [[ "$_font_issuer_inventory" == "$_font_lib_inventory" \
    && "$(printf '%s\n' "$_font_issuer_inventory" | /usr/bin/wc -l \
      | /usr/bin/tr -d '[:space:]')" == 20 ]]; then
    pass "mdm-install: font issuer inventory は lib の固定20件と byte-exact"
  else
    fail "mdm-install: font issuer inventory が lib/fonts-mdm.sh と drift"
  fi

  _font_fake="$(mktemp -d)/IBMPlexMono-Regular.ttf"
  printf '\000\001\000\000fake-font-with-only-valid-magic' > "$_font_fake"
  if _mdm_component_font_file_is_trusted "$_font_fake" \
    >/dev/null 2>&1; then
    fail "mdm-install: 名前とTrueType magicだけのfontを許可"
  else
    pass "mdm-install: fontはpinned raw SHAとSFNT identityを必須化"
  fi
  rm -rf "${_font_fake%/*}"
)

(
  _font_tmp="$(_mdm_test_target_tmpdir)"
  _font_support="$_font_tmp/support"
  _font_home="$_font_tmp/home"
  _font_dir="$_font_home/Library/Fonts"
  _font_kit="$_font_home/.claude-starter-kit"
  _font_guid="BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"
  _font_uid="$_MDM_TEST_TARGET_UID"
  _font_user="$_MDM_TEST_TARGET_USER"
  mkdir -p "$_font_support" "$_font_dir" "$_font_kit"
  chmod 755 "$_font_support"
  printf 'kit\n' > "$_font_kit/setup.sh"
  export MDM_NODE_ARCH_OVERRIDE=arm64
  while read -r _font_name _font_sha _font_family; do
    printf 'pinned-fixture\n' > "$_font_dir/$_font_name"
  done < <(_mdm_component_font_expected_inventory)
  printf 'user-extra\n' > "$_font_dir/IBMPlexMono-UserExtra.ttf"
  _mdm_test_chown_target "$_font_home"
  _mdm_exec_as_user() { _mdm_test_exec_as_target "$@"; }
  export MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_font_support"
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  MDM_RCPT_POLICY_SHA256="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  _MDM_EXPECTED_KIT_COMPONENT_SHA256="$(_mdm_artifact_digest tree \
    "$_font_kit" 2>/dev/null || true)"
  _mdm_component_font_file_is_trusted() {
    [[ "$(/bin/cat "$1")" == pinned-fixture ]]
  }
  MDM_REQUIRED_COMPONENTS=(fonts kit)
  _font_attest_rc=0
  _mdm_attest_components "$_font_user" "$_font_home" "$_font_uid" \
    "$_font_guid" >/dev/null 2>&1 || _font_attest_rc=$?
  _font_manifest="$_font_support/components-$_font_guid.json"
  _font_expected_names="$(_mdm_component_font_expected_inventory \
    | /usr/bin/awk '{print $1}' | LC_ALL=C /usr/bin/sort)"
  _font_actual_names=""
  if [[ -f "$_font_manifest" && ! -L "$_font_manifest" ]]; then
    _font_actual_names="$(jq -r \
      '.entries[] | select(.component == "fonts") | .path | split("/")[-1]' \
      "$_font_manifest" 2>/dev/null | LC_ALL=C /usr/bin/sort)" || true
  fi
  if [[ "$_font_attest_rc" -eq 0 \
    && "$_font_actual_names" == "$_font_expected_names" ]] \
    && jq -e \
      '([.entries[] | select(.component == "fonts")] | length) == 20
       and (.entries | length) == 21
       and ([.entries[].path] | index($extra)) == null' \
      --arg extra "$_font_dir/IBMPlexMono-UserExtra.ttf" \
      "$_font_manifest" >/dev/null; then
    pass "mdm-install: fonts はexact20件だけをsealしmatching extraを除外"
  else
    fail "mdm-install: font component の exact inventory 契約が不正"
  fi

  _font_append_mutation="$_font_dir/IBMPlexMono-Bold.ttf"
  (
    eval "$(declare -f _mdm_component_append_entry \
      | /usr/bin/sed '1s/_mdm_component_append_entry/_mdm_component_append_entry_unmutated/')"
    eval "$(declare -f _mdm_component_file_readable \
      | /usr/bin/sed '1s/_mdm_component_file_readable/_mdm_component_file_readable_unmutated/')"
    _font_mutation_done=false
    _font_mutation_readable_calls=0
    _font_mutation_trust_calls=0
    _mdm_component_file_readable() {
      _font_mutation_readable_calls=$((_font_mutation_readable_calls + 1))
      _mdm_component_file_readable_unmutated "$@"
    }
    _mdm_component_font_file_is_trusted() {
      _font_mutation_trust_calls=$((_font_mutation_trust_calls + 1))
      return 0
    }
    _mdm_component_append_entry() {
      _mdm_component_append_entry_unmutated "$@" || return 1
      if [[ "$1" == fonts && "$_font_mutation_done" == false ]]; then
        printf 'mutated-after-append\n' > "$2"
        _font_mutation_done=true
      fi
    }
    rm -f "$_font_manifest"
    _font_mutation_rc=0
    _mdm_attest_components "$_font_user" "$_font_home" "$_font_uid" \
      "$_font_guid" >/dev/null 2>&1 || _font_mutation_rc=$?
    if [[ "$_font_mutation_rc" -ne 0 && ! -e "$_font_manifest" \
      && "$_font_mutation_done" == true \
      && "$_font_mutation_readable_calls" -eq 2 \
      && "$_font_mutation_trust_calls" -eq 2 ]]; then
      pass "mdm-install: font は append 後に path/semantic/digest を再束縛"
    else
      fail "mdm-install: append 後の font 改変で component manifest を発行"
    fi
  )
  printf 'pinned-fixture\n' > "$_font_append_mutation"

  _font_regular="$_font_dir/IBMPlexMono-Regular.ttf"
  printf 'modified\n' > "$_font_regular"
  rm -f "$_font_manifest"
  _font_modified_rc=0
  _mdm_attest_components "$_font_user" "$_font_home" "$_font_uid" \
    "$_font_guid" >/dev/null 2>&1 || _font_modified_rc=$?
  printf 'pinned-fixture\n' > "$_font_regular"
  _font_missing="$_font_dir/HackGenConsoleNF-Regular.ttf"
  rm -f "$_font_missing" "$_font_manifest"
  _font_missing_rc=0
  _mdm_attest_components "$_font_user" "$_font_home" "$_font_uid" \
    "$_font_guid" >/dev/null 2>&1 || _font_missing_rc=$?
  printf 'pinned-fixture\n' > "$_font_missing"
  _mdm_test_chown_target "$_font_missing"
  if [[ "$_font_modified_rc" -ne 0 && "$_font_missing_rc" -ne 0 ]]; then
    pass "mdm-install: font exact20の欠落・semantic改変を拒否"
  else
    fail "mdm-install: font欠落または改変をcomponent attestationが許可"
  fi

  # 旧 lower-bound 判定は20 font entriesで欠落Nodeをmaskした。このfixtureは
  # required setと実component setの完全一致を要求する。
  MDM_REQUIRED_COMPONENTS=(fonts kit node_runtime)
  rm -f "$_font_manifest"
  _mdm_node_runtime_path() { printf '%s' "$_font_tmp/missing-node-runtime"; }
  _mdm_node_runtime_trusted() { return 1; }
  _font_mask_rc=0
  _mdm_attest_components "$_font_user" "$_font_home" "$_font_uid" \
    "$_font_guid" >/dev/null 2>&1 || _font_mask_rc=$?
  if [[ "$_font_mask_rc" -ne 0 && ! -e "$_font_manifest" ]]; then
    pass "mdm-install: extra font entriesでmissing node_runtimeをmask不可"
  else
    fail "mdm-install: font entry countがrequired component欠落をmask"
  fi
  rm -rf "$_font_tmp"
)

# CLI activation は executable の実体だけでなく、入口 symlink 自体も
# 対象 UID / nlink=1 に束縛する。
(
  _cli_link_tmp="$(_mdm_test_target_tmpdir)"
  _cli_link_uid="$_MDM_TEST_TARGET_UID"
  _cli_link_user="$_MDM_TEST_TARGET_USER"
  _cli_link_target="$_cli_link_tmp/.local/share/claude/versions/1.2.3"
  mkdir -p "$_cli_link_tmp/.local/bin" "${_cli_link_target%/*}"
  printf '#!/bin/sh\nexit 0\n' > "$_cli_link_target"
  chmod 755 "$_cli_link_target"
  ln -s "$_cli_link_target" "$_cli_link_tmp/.local/bin/claude"
  _mdm_test_chown_target "$_cli_link_tmp"
  _mdm_exec_as_user() { _mdm_test_exec_as_target "$@"; }
  _cli_link_out="" _cli_link_ok=0 _cli_link_wrong=0 _cli_link_hard=0
  _cli_link_blocked=0
  _mdm_component_cli_target \
    "$_cli_link_user" "$_cli_link_tmp" "$_cli_link_uid" _cli_link_out \
    || _cli_link_ok=$?
  _mdm_component_cli_target \
    "$_cli_link_user" "$_cli_link_tmp" "$((_cli_link_uid + 1))" _cli_link_out \
    || _cli_link_wrong=$?
  chmod 600 "$_cli_link_tmp/.local/share/claude"
  _mdm_component_cli_target \
    "$_cli_link_user" "$_cli_link_tmp" "$_cli_link_uid" _cli_link_out \
    || _cli_link_blocked=$?
  chmod 755 "$_cli_link_tmp/.local/share/claude"
  (
    _mdm_stat_managed_metadata() { printf '%s:2:0777' "$_cli_link_uid"; }
    _mdm_component_cli_target \
      "$_cli_link_user" "$_cli_link_tmp" "$_cli_link_uid" _cli_link_out
  ) || _cli_link_hard=$?
  if [[ "$_cli_link_ok" -eq 0 && "$_cli_link_out" == "$_cli_link_target" \
    && "$_cli_link_wrong" -ne 0 && "$_cli_link_blocked" -ne 0 \
    && "$_cli_link_hard" -ne 0 ]]; then
    pass "mdm-install: Claude CLI activation symlink を対象UIDとnlink=1へ束縛"
  else
    fail "mdm-install: Claude CLI activation symlink のidentity束縛が不正"
  fi
  rm -rf "$_cli_link_tmp"
)

# Claude CLI も entry append 後に activation path・signature・artifact
# digest を同じ実体へ再束縛し、その間の mutation を manifest に封じない。
(
  _cli_mutation_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _cli_mutation_home="$_cli_mutation_tmp/home"
  _cli_mutation_support="$_cli_mutation_tmp/support"
  _cli_mutation_uid="$(/usr/bin/id -u)"
  _cli_mutation_user="$(/usr/bin/id -un)"
  _cli_mutation_guid=DDDDDDDD-EEEE-FFFF-AAAA-BBBBBBBBBBBB
  _cli_mutation_target="$_cli_mutation_home/.local/share/claude/versions/1.2.3"
  mkdir -p "$_cli_mutation_support" "$_cli_mutation_home/.local/bin" \
    "${_cli_mutation_target%/*}"
  chmod 755 "$_cli_mutation_support"
  printf '#!/bin/sh\nexit 0\n' > "$_cli_mutation_target"
  chmod 755 "$_cli_mutation_target"
  ln -s "$_cli_mutation_target" "$_cli_mutation_home/.local/bin/claude"
  export MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_cli_mutation_support"
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  MDM_RCPT_POLICY_SHA256="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  MDM_REQUIRED_COMPONENTS=(claude_cli)
  _cli_mutation_manifest="$_cli_mutation_support/components-${_cli_mutation_guid}.json"
  eval "$(declare -f _mdm_component_append_entry \
    | /usr/bin/sed '1s/_mdm_component_append_entry/_mdm_component_append_entry_unmutated/')"
  eval "$(declare -f _mdm_component_cli_target \
    | /usr/bin/sed '1s/_mdm_component_cli_target/_mdm_component_cli_target_unmutated/')"
  _cli_mutation_done=false
  _cli_mutation_target_calls=0
  _cli_mutation_sign_calls=0
  _mdm_component_cli_target() {
    _cli_mutation_target_calls=$((_cli_mutation_target_calls + 1))
    _mdm_component_cli_target_unmutated "$@"
  }
  _mdm_component_cli_path_signed() {
    _cli_mutation_sign_calls=$((_cli_mutation_sign_calls + 1))
    return 0
  }
  _mdm_component_append_entry() {
    _mdm_component_append_entry_unmutated "$@" || return 1
    if [[ "$1" == claude_cli ]]; then
      printf 'mutated-after-append\n' >> "$2"
      _cli_mutation_done=true
    fi
  }
  _cli_mutation_rc=0
  if [[ "$_cli_mutation_uid" -ge 501 ]]; then
    _mdm_attest_components "$_cli_mutation_user" "$_cli_mutation_home" \
      "$_cli_mutation_uid" "$_cli_mutation_guid" >/dev/null 2>&1 \
      || _cli_mutation_rc=$?
  else
    _cli_mutation_rc=99
  fi
  if [[ "$_cli_mutation_uid" -lt 501 ]]; then
    skip "mdm-install: Claude CLI post-append mutation" "test UID is below 501"
  elif [[ "$_cli_mutation_rc" -ne 0 && ! -e "$_cli_mutation_manifest" \
    && "$_cli_mutation_done" == true \
    && "$_cli_mutation_target_calls" -eq 2 \
    && "$_cli_mutation_sign_calls" -eq 2 ]]; then
    pass "mdm-install: Claude CLI は append 後に path/signature/digest を再束縛"
  else
    fail "mdm-install: append 後の Claude CLI 改変で component manifest を発行"
  fi
  rm -rf "$_cli_mutation_tmp"
)

# Component manifest が記録する artifact は、対象ユーザーから実際に
# read/search/execute できる状態でなければ成功 postcondition にしない。
(
  _access_tmp="$(_mdm_test_target_tmpdir)"
  _access_uid="$_MDM_TEST_TARGET_UID"; _access_user="$_MDM_TEST_TARGET_USER"
  _access_tree="$_access_tmp/tree"; _access_file="$_access_tree/payload"
  mkdir -p "$_access_tree"
  printf 'payload\n' > "$_access_file"
  chmod 755 "$_access_tree"; chmod 644 "$_access_file"
  _mdm_test_chown_target "$_access_tmp"
  _mdm_exec_as_user() { _mdm_test_exec_as_target "$@"; }
  _access_tree_ok=0 _access_file_ok=0 _access_tree_blocked=0
  _access_file_blocked=0 _access_acl_blocked=0
  _mdm_component_tree_accessible \
    "$_access_tree" "$_access_uid" "$_access_user" "$_access_tmp" \
    || _access_tree_ok=$?
  _mdm_component_file_readable \
    "$_access_file" "$_access_uid" "$_access_user" "$_access_tmp" \
    || _access_file_ok=$?
  chmod 600 "$_access_tree"
  _mdm_component_tree_accessible \
    "$_access_tree" "$_access_uid" "$_access_user" "$_access_tmp" \
    || _access_tree_blocked=$?
  chmod 755 "$_access_tree"; chmod 000 "$_access_file"
  _mdm_component_file_readable \
    "$_access_file" "$_access_uid" "$_access_user" "$_access_tmp" \
    || _access_file_blocked=$?
  chmod 644 "$_access_file"
  (
    _mdm_has_extended_acl() { [[ "$1" == "$_access_file" ]]; }
    _mdm_component_file_readable \
      "$_access_file" "$_access_uid" "$_access_user" "$_access_tmp"
  ) || _access_acl_blocked=$?
  if [[ "$_access_tree_ok" -eq 0 && "$_access_file_ok" -eq 0 \
    && "$_access_tree_blocked" -ne 0 && "$_access_file_blocked" -ne 0 \
    && "$_access_acl_blocked" -ne 0 ]]; then
    pass "mdm-install: component artifact の対象UID read/search/executeを束縛"
  else
    fail "mdm-install: component artifact の実効access束縛が不正"
  fi
  rm -rf "$_access_tmp"
)

# The effective target-user probe is an execution boundary. Rebind canonical
# path, owner, mode, ACL, and inode after it instead of trusting pre-probe data.
(
  _rebind_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _rebind_dir="$_rebind_tmp/target"
  _rebind_uid="$(/usr/bin/id -u)"
  _rebind_user="$(/usr/bin/id -un)"
  /bin/mkdir -m 0755 "$_rebind_dir"
  _mdm_component_effective_test() {
    /bin/chmod 0777 "$_rebind_dir"
    return 0
  }
  _rebind_rc=0
  _mdm_component_target_dir_accessible \
    "$_rebind_dir" "$_rebind_uid" "$_rebind_user" "$_rebind_tmp" \
    >/dev/null 2>&1 || _rebind_rc=$?
  if [[ "$_rebind_rc" -ne 0 ]]; then
    pass "mdm-install: component target dirはeffective probe後に全metadataを再束縛"
  else
    fail "mdm-install: component target dirがprobe後mode driftを受理"
  fi
  /bin/chmod 0700 "$_rebind_dir"
  /bin/rm -rf "$_rebind_tmp"
)

# User-owned directory ACLs are authority, not merely effective-access hints.
# Each ancestor permits no ACL or the platform's exact non-inheriting
# deny-delete ACE; mutating, inheritable, or multiple ACEs fail closed.
(
  _acl_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _acl_home="$_acl_tmp/home"; _acl_child="$_acl_home/.local"
  _acl_file="$_acl_child/font.ttf"
  _acl_external="$_acl_tmp/external"; _acl_external_file="$_acl_external/tool"
  _acl_uid="$(/usr/bin/id -u)"; _acl_user="$(/usr/bin/id -un)"
  mkdir -p "$_acl_child" "$_acl_external"
  chmod 0700 "$_acl_home" "$_acl_child"; chmod 0755 "$_acl_external"
  printf 'font\n' > "$_acl_file"; chmod 0600 "$_acl_file"
  printf 'tool\n' > "$_acl_external_file"; chmod 0644 "$_acl_external_file"
  if _mdm_is_darwin \
    && /bin/chmod +a \
      'group:everyone allow search,list,add_file,add_subdirectory,delete_child' \
      "$_acl_child" 2>/dev/null; then
    _mutating_child_rc=0
    _mdm_component_target_dir_accessible \
      "$_acl_child" "$_acl_uid" "$_acl_user" "$_acl_home" \
      >/dev/null 2>&1 || _mutating_child_rc=$?
    _font_ancestor_acl_rc=0
    _mdm_component_file_readable \
      "$_acl_file" "$_acl_uid" "$_acl_user" "$_acl_home" \
      >/dev/null 2>&1 || _font_ancestor_acl_rc=$?
    /bin/chmod -N "$_acl_child"
    /bin/chmod +a 'group:everyone deny delete' "$_acl_child"
    _standard_child_rc=0
    _mdm_component_file_readable \
      "$_acl_file" "$_acl_uid" "$_acl_user" "$_acl_home" \
      >/dev/null 2>&1 || _standard_child_rc=$?
    /bin/chmod -N "$_acl_child"
    /bin/chmod +a 'group:everyone deny delete' "$_acl_home"
    _standard_home_rc=0
    _mdm_component_target_dir_accessible \
      "$_acl_home" "$_acl_uid" "$_acl_user" "$_acl_home" \
      >/dev/null 2>&1 || _standard_home_rc=$?
    /bin/chmod -N "$_acl_home"
    /bin/chmod +a \
      'group:everyone allow search,list,add_file,add_subdirectory,delete_child' \
      "$_acl_external"
    _external_allow_write_rc=0
    _mdm_component_file_readable \
      "$_acl_external_file" "$_acl_uid" "$_acl_user" "$_acl_home" \
      >/dev/null 2>&1 || _external_allow_write_rc=$?
    /bin/chmod -N "$_acl_external"
    /bin/chmod +a 'group:everyone deny delete' "$_acl_external"
    _external_deny_only_rc=0
    _mdm_component_file_readable \
      "$_acl_external_file" "$_acl_uid" "$_acl_user" "$_acl_home" \
      >/dev/null 2>&1 || _external_deny_only_rc=$?
    /bin/chmod -N "$_acl_external"
    if [[ "$_mutating_child_rc" -ne 0 && "$_font_ancestor_acl_rc" -ne 0 \
      && "$_standard_child_rc" -eq 0 && "$_standard_home_rc" -eq 0 \
      && "$_external_allow_write_rc" -ne 0 \
      && "$_external_deny_only_rc" -eq 0 ]]; then
      pass "mdm-install: 全物理ancestorでallow-write ACLを拒否し標準deny-deleteだけ許可"
    else
      fail "mdm-install: component ancestor ACL authority契約が不正"
    fi
  elif _mdm_is_darwin; then
    fail "mdm-install: target-owned mutating ACL fixtureを作成できない"
  else
    pass "mdm-install: target-owned ACL authorityは Darwin 契約として固定"
  fi
  rm -rf "$_acl_tmp"
)

(
  _access_attest="$(declare -f _mdm_attest_components)"
  _access_fixed="$(declare -f _mdm_component_fixed_launcher)"
  _access_cli="$(declare -f _mdm_component_cli_target)"
  _access_ghost_signatures="$(printf '%s\n' "$_access_attest" \
    | /usr/bin/grep -c '_mdm_component_ghostty_signed "$_path"')"
  if /usr/bin/grep -Fq '_mdm_component_target_dir_accessible' \
      <<< "$_access_fixed" \
    && /usr/bin/grep -Fq '_mdm_component_tree_accessible' \
      <<< "$_access_fixed" \
    && /usr/bin/grep -Fq '_mdm_component_path_accessible' \
      <<< "$_access_fixed" \
    && /usr/bin/grep -Fq '_mdm_component_target_dir_accessible' \
      <<< "$_access_cli" \
    && /usr/bin/grep -Fq '_mdm_component_path_accessible' \
      <<< "$_access_cli" \
    && /usr/bin/grep -Fq \
      '_mdm_component_tree_accessible "$_path" "$_uid" "$_user" "$_home"' \
      <<< "$_access_attest" \
    && /usr/bin/grep -Fq '_mdm_component_file_readable' \
      <<< "$_access_attest" \
    && [[ "$_access_ghost_signatures" -eq 2 ]]; then
    pass "mdm-install: CLI/private tree/fonts/Ghosttyのaccessをattestationへ配線"
  else
    fail "mdm-install: component access postconditionの配線が不正"
  fi
)

# Semantic validationとartifact digestの間をexpected digestで束縛し、active
# launcherはappend後に同じcanonical targetへ再解決することを静的に固定する。
(
  _attest_impl="$(/usr/bin/sed -n \
    '/^_mdm_attest_components()/,/^_mdm_user_phase_exit_code()/p' \
    "$PROJECT_DIR/mdm/install-mdm.sh")"
  _cli_resolves="$(printf '%s\n' "$_attest_impl" \
    | /usr/bin/grep -c '_mdm_component_cli_target "$_user" "$_home" "$_uid"')"
  _biome_resolves="$(printf '%s\n' "$_attest_impl" \
    | /usr/bin/grep -c 'biome 2.5.4 biome')"
  _safety_resolves="$(printf '%s\n' "$_attest_impl" \
    | /usr/bin/grep -c 'cc-safety-net 1.0.6 bin/cc-safety-net')"
  _biome_semantics="$(printf '%s\n' "$_attest_impl" \
    | /usr/bin/grep -c '_mdm_component_biome_tree_is_trusted')"
  _safety_semantics="$(printf '%s\n' "$_attest_impl" \
    | /usr/bin/grep -c '_mdm_component_safety_tree_is_trusted')"
  _wce_trusts="$(printf '%s\n' "$_attest_impl" \
    | /usr/bin/grep -c '_mdm_wce_runtime_trusted "$_path"')"
  _wce_activations="$(printf '%s\n' "$_attest_impl" \
    | /usr/bin/grep -c '_mdm_wce_runtime_activation_valid')"
  _wce_expected_refs="$(printf '%s\n' "$_attest_impl" \
    | /usr/bin/grep -c '_MDM_EXPECTED_WCE_COMPONENT_SHA256')"
  _wce_verified_refs="$(printf '%s\n' "$_attest_impl" \
    | /usr/bin/grep -c '_MDM_WCE_VERIFIED_BUNDLE')"
  _exact_impl="$(declare -f _mdm_component_generated_manifest_is_exact)"
  _append_impl="$(declare -f _mdm_component_append_entry)"
  if [[ "$_cli_resolves" -eq 2 && "$_biome_resolves" -eq 2 \
    && "$_safety_resolves" -eq 2 && "$_biome_semantics" -eq 2 \
    && "$_safety_semantics" -eq 2 && "$_wce_trusts" -eq 2 \
    && "$_wce_activations" -eq 2 && "$_wce_expected_refs" -ge 4 \
    && "$_wce_verified_refs" -ge 1 ]] \
    && /usr/bin/grep -Fq \
      '_mdm_component_append_entry fonts "$_canonical" file "$_pre_digest"' \
      <<< "$_attest_impl" \
    && /usr/bin/grep -Fq \
      '_mdm_component_append_entry biome "$_dir" tree "$_pre_digest"' \
      <<< "$_attest_impl" \
    && /usr/bin/grep -Fq \
      '_mdm_component_append_entry safety_net "$_dir" tree "$_pre_digest"' \
      <<< "$_attest_impl" \
    && /usr/bin/grep -Fq \
      '_mdm_component_append_entry web_content_runtime "$_path" tree' \
      <<< "$_attest_impl" \
    && /usr/bin/grep -Fq '"$_MDM_EXPECTED_WCE_COMPONENT_SHA256"' \
      <<< "$_attest_impl" \
    && /usr/bin/grep -Fq '_wce_runtime_path' <<< "$_exact_impl" \
    && /usr/bin/grep -Fq '_MDM_WCE_PACKAGE_SHA256' <<< "$_exact_impl" \
    && /usr/bin/grep -Fq \
      '"web_content_runtime": (wce_runtime, "tree")' <<< "$_exact_impl" \
    && ! /usr/bin/grep -Fq \
      '.claude/skills/web-content-extraction/node_modules' <<< "$_exact_impl" \
    && /usr/bin/grep -Fq 'node_runtime | web_content_runtime)' \
      <<< "$_append_impl" \
    && /usr/bin/grep -Fq '_group_csv=0' <<< "$_append_impl"; then
    pass "mdm-install: semantic→digest TOCTOUとactive launcherを前後束縛"
  else
    fail "mdm-install: component semantic/digest/activationの再束縛が不正"
  fi
)

# ── 成功レシート前の postcondition 検証 ──────────────────
(
  _auth_list_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _auth_list_tree="$_auth_list_tmp/tree"
  mkdir -p "$_auth_list_tree"
  printf 'fixture\n' > "$_auth_list_tree/file"
  _MDM_TEST_MODE=1
  MDM_AUTH_TMPDIR_OVERRIDE="$_auth_list_tmp"
  _mdm_stat_identity() { printf '1:regular empty file:0'; }
  _auth_list=""
  if _mdm_auth_entry_list "$_auth_list_tree" _auth_list \
    && [[ -f "$_auth_list" && ! -L "$_auth_list" ]]; then
    pass "mdm-install: GNU stat の空 regular file 表記を auth list で許可"
  else
    fail "mdm-install: GNU stat の空 regular file 表記を auth list が拒否"
  fi
  _mdm_cleanup_auth_entry_list >/dev/null 2>&1 || true
  /bin/rm -rf "$_auth_list_tmp"
)

(
  _digest_guard_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _digest_guard_bash=""
  for _digest_guard_candidate in \
    "$(command -v bash 2>/dev/null || true)" \
    /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash; do
    [[ "$_digest_guard_candidate" == /* \
      && -x "$_digest_guard_candidate" ]] || continue
    _digest_guard_major="$("$_digest_guard_candidate" -c \
      'printf "%s" "${BASH_VERSINFO[0]}"' 2>/dev/null || true)"
    [[ "$_digest_guard_major" =~ ^[0-9]+$ \
      && "$_digest_guard_major" -ge 4 ]] || continue
    _digest_guard_bash="$_digest_guard_candidate"
    break
  done
  if [[ -z "$_digest_guard_bash" ]]; then
    skip "mdm-install: Bash 4+ がなく nounset 早期拒否を未検証"
  else
    _digest_guard_rc=0
    "$_digest_guard_bash" -uc '
      MDM_SOURCE_ONLY=1 source "$1"
      _mdm_deployment_digest /nonexistent /nonexistent /nonexistent invalid
    ' mdm-digest-guard "$PROJECT_DIR/mdm/install-mdm.sh" \
      > /dev/null 2> "$_digest_guard_tmp/stderr" || _digest_guard_rc=$?
    if [[ "$_digest_guard_rc" -ne 0 ]] \
      && ! /usr/bin/grep -Fq 'unbound variable' "$_digest_guard_tmp/stderr"; then
      pass "mdm-install: deployment digest の早期拒否は nounset 下でも安全"
    else
      fail "mdm-install: deployment digest の早期拒否で未初期化変数を参照"
    fi
  fi
  /bin/rm -rf "$_digest_guard_tmp"
)

(
  _post_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _post_home="$_post_tmp/home"
  _post_claude="$_post_home/.claude"
  _post_snapshot="$_post_claude/.starter-kit-snapshot"
  _post_manifest="$_post_claude/.starter-kit-manifest.json"
  _post_uid="$(/usr/bin/id -u)"
  _post_expected="$_post_tmp/expected"
  export MDM_AUTH_OWNER_UID_OVERRIDE="$_post_uid"
  export MDM_AUTH_TMPDIR_OVERRIDE="$_post_tmp"
  _MDM_EXPECTED_OUTPUT="$_post_expected"
  mkdir -p "$_post_snapshot" "$_post_expected/tree"
  printf '{}\n' > "$_post_claude/settings.json"
  cat > "$_post_claude/CLAUDE.md" <<'MD'
<!-- BEGIN STARTER-KIT-MANAGED -->
# managed
<!-- END STARTER-KIT-MANAGED -->

# User Settings
personal
MD
  printf '{}\n' > "$_post_snapshot/settings.json"
  cat > "$_post_snapshot/CLAUDE.md" <<'MD'
<!-- BEGIN STARTER-KIT-MANAGED -->
# managed
<!-- END STARTER-KIT-MANAGED -->
MD
  cp "$_post_snapshot/CLAUDE.md" "$_post_expected/tree/CLAUDE.md"
  cp "$_post_snapshot/settings.json" "$_post_expected/tree/settings.json"
  printf 'CLAUDE.md\t0600\t0600\nsettings.json\t0600\t0600\n' > "$_post_expected/modes.tsv"
  printf '{"profile":"standard","language":"ja"}\n' > "$_post_expected/policy.json"
  _post_policy_hash="$(_mdm_sha256_file "$_post_expected/policy.json")"
  jq -n --arg policy "$_post_policy_hash" \
    '{profile:"standard",language:"ja",policy_sha256:$policy,
      files:["CLAUDE.md","settings.json"],absent_files:[]}' \
    > "$_post_expected/manifest.json"
  chmod 700 "$_post_expected" "$_post_expected/tree"
  chmod 600 "$_post_claude/settings.json" "$_post_claude/CLAUDE.md" \
    "$_post_snapshot/settings.json" "$_post_snapshot/CLAUDE.md" \
    "$_post_expected/tree/CLAUDE.md" "$_post_expected/tree/settings.json" \
    "$_post_expected/modes.tsv" "$_post_expected/policy.json" \
    "$_post_expected/manifest.json"
  jq -n \
    --arg commit abcdef0 \
    --arg profile standard \
    --arg language ja \
    --arg claude_dir "$_post_claude" \
    --arg snapshot_dir "$_post_snapshot" \
    --arg settings "$_post_claude/settings.json" \
    --arg claude_md "$_post_claude/CLAUDE.md" \
    --arg policy "$_post_policy_hash" \
    '{version:"2", timestamp:"2026-07-18T00:00:00Z", kit_version:"test",
      kit_commit:$commit, profile:$profile, language:$language,
      editor:"none", commit_attribution:"false", new_init:"true", plugins:"",
      codex_plugin:"false", files:[$claude_md,$settings], cleanup_paths:[],
      mdm_absent_files:[], mdm_managed:true, snapshot_dir:$snapshot_dir,
      claude_dir:$claude_dir, policy_sha256:$policy}' > "$_post_manifest"

  MDM_RCPT_RESOLVED_SHA="abcdef0123456789abcdef0123456789abcdef01"
  MDM_RCPT_POLICY_SHA256="$_post_policy_hash"
  PROFILE=standard
  LANGUAGE=ja
  if _mdm_capture_postcondition "$_post_home" "$_post_uid" \
    && [[ "$MDM_RCPT_MANIFEST_PATH" == "$_post_manifest" ]] \
    && [[ "$MDM_RCPT_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    && [[ "$MDM_RCPT_DEPLOYMENT_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    && jq -e --arg policy "$MDM_RCPT_POLICY_SHA256" \
      '.version == "2" and (.policy_sha256 | type) == "string"
       and .policy_sha256 == $policy' "$_post_manifest" >/dev/null \
    && [[ "$MDM_RCPT_PROFILE" == "standard" && "$MDM_RCPT_LANGUAGE" == "ja" ]]; then
    pass "mdm-install: postcondition が manifest v2 policy と配備実体をレシートへ固定"
  else
    fail "mdm-install: 正常な postcondition を検証できない"
  fi

  cp "$_post_manifest" "$_post_tmp/manifest-strict.backup"
  _post_strict_ok=1
  printf '\n' >> "$_post_manifest"
  _mdm_capture_postcondition "$_post_home" "$_post_uid" \
    >/dev/null 2>&1 && _post_strict_ok=0
  cp "$_post_tmp/manifest-strict.backup" "$_post_manifest"
  printf ' ' >> "$_post_manifest"
  _mdm_capture_postcondition "$_post_home" "$_post_uid" \
    >/dev/null 2>&1 && _post_strict_ok=0
  printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' \
    > "$_post_manifest"
  _mdm_capture_postcondition "$_post_home" "$_post_uid" \
    >/dev/null 2>&1 && _post_strict_ok=0
  cp "$_post_tmp/manifest-strict.backup" "$_post_manifest"
  jq '.unexpected=true' "$_post_manifest" > "$_post_tmp/manifest-extra"
  mv "$_post_tmp/manifest-extra" "$_post_manifest"
  _mdm_capture_postcondition "$_post_home" "$_post_uid" \
    >/dev/null 2>&1 && _post_strict_ok=0
  if _mdm_is_darwin \
    && /usr/bin/plutil -convert binary1 -o "$_post_tmp/manifest.binary" \
      "$_post_tmp/manifest-strict.backup" >/dev/null 2>&1; then
    mv "$_post_tmp/manifest.binary" "$_post_manifest"
    chmod 600 "$_post_manifest"
    _mdm_capture_postcondition "$_post_home" "$_post_uid" \
      >/dev/null 2>&1 && _post_strict_ok=0
  fi
  cp "$_post_tmp/manifest-strict.backup" "$_post_manifest"
  chmod 600 "$_post_manifest"
  jq -S . "$_post_tmp/manifest-strict.backup" > "$_post_manifest"
  _mdm_capture_postcondition "$_post_home" "$_post_uid" \
    >/dev/null 2>&1 && _post_strict_ok=0
  cp "$_post_tmp/manifest-strict.backup" "$_post_manifest"
  /usr/bin/awk 'NR == 2 { sub(": ", ":  ") } { print }' \
    "$_post_tmp/manifest-strict.backup" > "$_post_manifest"
  _mdm_capture_postcondition "$_post_home" "$_post_uid" \
    >/dev/null 2>&1 && _post_strict_ok=0
  /usr/bin/sed 's/"standard"/"\\u0073tandard"/' \
    "$_post_tmp/manifest-strict.backup" > "$_post_manifest"
  _mdm_capture_postcondition "$_post_home" "$_post_uid" \
    >/dev/null 2>&1 && _post_strict_ok=0
  cp "$_post_tmp/manifest-strict.backup" "$_post_manifest"
  chmod 600 "$_post_manifest"
  if [[ "$_post_strict_ok" -eq 1 ]]; then
    pass "mdm-install: deployment manifest は writer-canonical bytes のみ許可"
  else
    fail "mdm-install: 等価escape/order/whitespace drift の deployment manifest を許可"
  fi

  cp "$_post_manifest" "$_post_tmp/manifest-policy.backup"
  jq '.policy_sha256=123' "$_post_tmp/manifest-policy.backup" \
    > "$_post_manifest"
  chmod 600 "$_post_manifest"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid" >/dev/null 2>&1; then
    fail "mdm-install: manifest v2 の非 string policy_sha256 を許可"
  else
    pass "mdm-install: manifest v2 の policy_sha256 型不正を拒否"
  fi
  jq '.policy_sha256="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"' \
    "$_post_tmp/manifest-policy.backup" > "$_post_manifest"
  chmod 600 "$_post_manifest"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid" >/dev/null 2>&1; then
    fail "mdm-install: manifest v2 の policy_sha256 不一致を許可"
  else
    pass "mdm-install: manifest v2 の policy_sha256 不一致を拒否"
  fi
  mv "$_post_tmp/manifest-policy.backup" "$_post_manifest"
  chmod 600 "$_post_manifest"

  _post_digest_initial="$MDM_RCPT_DEPLOYMENT_SHA256"
  jq '.absent_files=["commands/retired.md"]' \
    "$_post_expected/manifest.json" > "$_post_tmp/expected-with-absent"
  mv "$_post_tmp/expected-with-absent" "$_post_expected/manifest.json"
  jq '.mdm_absent_files=["commands/retired.md"]' \
    "$_post_manifest" > "$_post_tmp/manifest-with-absent"
  mv "$_post_tmp/manifest-with-absent" "$_post_manifest"
  _post_absent_ok=0
  _mdm_capture_postcondition "$_post_home" "$_post_uid" || _post_absent_ok=$?
  mkdir -p "$_post_claude/commands"; printf 'stale\n' \
    > "$_post_claude/commands/retired.md"
  _post_absent_live_rc=0
  _mdm_capture_postcondition "$_post_home" "$_post_uid" >/dev/null 2>&1 \
    || _post_absent_live_rc=$?
  rm -rf "$_post_claude/commands"
  mkdir -p "$_post_snapshot/commands"; printf 'stale\n' \
    > "$_post_snapshot/commands/retired.md"
  _post_absent_snapshot_rc=0
  _mdm_capture_postcondition "$_post_home" "$_post_uid" >/dev/null 2>&1 \
    || _post_absent_snapshot_rc=$?
  rm -rf "$_post_snapshot/commands"
  if [[ "$_post_absent_ok" -eq 0 && "$_post_absent_live_rc" -ne 0 \
    && "$_post_absent_snapshot_rc" -ne 0 ]]; then
    pass "mdm-install: postcondition は live/snapshot の absent path を固定"
  else
    fail "mdm-install: postcondition の absent path 契約が不正"
  fi
  jq '.absent_files=[]' "$_post_expected/manifest.json" \
    > "$_post_tmp/expected-without-absent"
  mv "$_post_tmp/expected-without-absent" "$_post_expected/manifest.json"
  jq '.mdm_absent_files=[]' "$_post_manifest" > "$_post_tmp/manifest-without-absent"
  mv "$_post_tmp/manifest-without-absent" "$_post_manifest"

  printf '{"live":"changed"}\n' > "$_post_claude/settings.json"
  chmod 600 "$_post_claude/settings.json"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: expectedと異なるlive内容を許可"
  else
    pass "mdm-install: expectedと異なるlive内容を拒否"
  fi

  printf '{}\n' > "$_post_claude/settings.json"
  chmod 600 "$_post_claude/settings.json"
  printf '{"snapshot":"changed"}\n' > "$_post_snapshot/settings.json"
  chmod 600 "$_post_snapshot/settings.json"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: expectedと異なるsnapshot内容を許可"
  else
    pass "mdm-install: expectedと異なるsnapshot内容を拒否"
  fi
  printf '{}\n' > "$_post_snapshot/settings.json"
  chmod 600 "$_post_snapshot/settings.json"

  chmod 644 "$_post_claude/settings.json"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: expectedと異なるmodeを許可"
  else
    pass "mdm-install: live/snapshot modeを期待値と照合"
  fi
  chmod 600 "$_post_claude/settings.json"

  printf 'changed personal section\n' >> "$_post_claude/CLAUDE.md"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid" \
    && [[ "$MDM_RCPT_DEPLOYMENT_SHA256" == "$_post_digest_initial" ]]; then
    pass "mdm-install: CLAUDE user sectionはattestation対象外"
  else
    fail "mdm-install: CLAUDE user sectionがdeployment digestを変えた"
  fi

  cp "$_post_claude/CLAUDE.md" "$_post_tmp/claude.lf"
  /usr/bin/awk '{ printf "%s\r\n", $0 }' "$_post_tmp/claude.lf" \
    > "$_post_claude/CLAUDE.md"
  chmod 600 "$_post_claude/CLAUDE.md"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: CLAUDE managed section の CRLF drift を許可"
  else
    pass "mdm-install: CLAUDE managed section は byte-exact に CRLF drift を拒否"
  fi
  mv "$_post_tmp/claude.lf" "$_post_claude/CLAUDE.md"
  chmod 600 "$_post_claude/CLAUDE.md"

  _section_input="$_post_tmp/managed-section.input"
  _section_output="$_post_tmp/managed-section.output"
  printf '%s\nmanaged\n%s\n' \
    "$_MDM_MARKER_BEGIN" "$_MDM_MARKER_END" > "$_section_input"
  _section_exact_rc=0
  _mdm_extract_managed_section \
    "$_section_input" "$_section_output" 1 || _section_exact_rc=$?
  printf '\0' >> "$_section_input"
  _section_nul_rc=0
  _mdm_extract_managed_section \
    "$_section_input" "$_section_output" 1 >/dev/null 2>&1 \
    || _section_nul_rc=$?
  printf '%s\nmanaged\n%s' \
    "$_MDM_MARKER_BEGIN" "$_MDM_MARKER_END" > "$_section_input"
  _section_lf_rc=0
  _mdm_extract_managed_section \
    "$_section_input" "$_section_output" 1 >/dev/null 2>&1 \
    || _section_lf_rc=$?
  if [[ "$_section_exact_rc" -eq 0 && "$_section_nul_rc" -ne 0 \
    && "$_section_lf_rc" -ne 0 ]]; then
    pass "mdm-install: managed section は NUL/終端LFを含め byte-exact"
  else
    fail "mdm-install: managed section の NUL/終端LF 契約が不正"
  fi

  cp "$_post_manifest" "$_post_tmp/manifest.backup"
  printf 'attacker-controlled\n' > "$_post_claude/forged.txt"
  printf 'attacker-controlled\n' > "$_post_snapshot/forged.txt"
  chmod 600 "$_post_claude/forged.txt" "$_post_snapshot/forged.txt"
  jq -n \
    --arg commit abcdef0 \
    --arg profile standard \
    --arg language ja \
    --arg claude_dir "$_post_claude" \
    --arg snapshot_dir "$_post_snapshot" \
    --arg forged "$_post_claude/forged.txt" \
    '{version:"2", mdm_managed:true, kit_commit:$commit, profile:$profile, language:$language,
      claude_dir:$claude_dir, snapshot_dir:$snapshot_dir, files:[$forged], mdm_absent_files:[]}' > "$_post_manifest"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: forged manifest と一致する配備を許可"
  else
    pass "mdm-install: forged manifest は root 期待状態との差分として拒否"
  fi
  mv "$_post_tmp/manifest.backup" "$_post_manifest"
  rm -f "$_post_claude/forged.txt" "$_post_snapshot/forged.txt"

  _post_wrong_uid=$((_post_uid + 1))
  if _mdm_capture_postcondition "$_post_home" "$_post_wrong_uid"; then
    fail "mdm-install: target UID 不一致の managed file を許可"
  else
    pass "mdm-install: live/snapshot の target UID 不一致を拒否"
  fi

  rm -f "$_post_snapshot/settings.json"
  ln "$_post_claude/settings.json" "$_post_snapshot/settings.json"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: hardlink managed file を許可"
  else
    pass "mdm-install: live/snapshot の nlink!=1 を拒否"
  fi
  rm -f "$_post_snapshot/settings.json"; printf '{}\n' > "$_post_snapshot/settings.json"
  chmod 600 "$_post_snapshot/settings.json"

  if (
    _mdm_has_extended_acl() { [[ "$1" == "$_post_claude/settings.json" ]]; }
    _mdm_capture_postcondition "$_post_home" "$_post_uid"
  ); then
    fail "mdm-install: ACL 付き managed file を許可"
  else
    pass "mdm-install: live/snapshot の ACL を拒否"
  fi

  PROFILE=full
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: profile 不一致を postcondition が許可"
  else
    pass "mdm-install: profile 不一致を postcondition が拒否"
  fi
  PROFILE=standard
  LANGUAGE=en
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: language 不一致を postcondition が許可"
  else
    pass "mdm-install: language 不一致を postcondition が拒否"
  fi
  LANGUAGE=ja

  rm -f "$_post_claude/CLAUDE.md"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: manifest 記載ファイル欠落を postcondition が許可"
  else
    pass "mdm-install: manifest 記載ファイル欠落を postcondition が拒否"
  fi
  cp "$_post_snapshot/CLAUDE.md" "$_post_claude/CLAUDE.md"
  chmod 600 "$_post_claude/CLAUDE.md"
  # implementation reads this receipt global indirectly
  # shellcheck disable=SC2034
  MDM_RCPT_RESOLVED_SHA="1111111111111111111111111111111111111111"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: manifest kit_commit 不一致を postcondition が許可"
  else
    pass "mdm-install: manifest kit_commit 不一致を postcondition が拒否"
  fi
  rm -rf "$_post_tmp"
)

# Revalidation after history persistence must recompute both deployment and
# component claims. Stable bytes pass; either class of post-capture drift fails.
(
  _reval_reset_claims() {
    MDM_RCPT_MANIFEST_PATH=/tmp/mdm-revalidate/manifest.json
    MDM_RCPT_MANIFEST_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    MDM_RCPT_DEPLOYMENT_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    MDM_RCPT_COMPONENT_MANIFEST_PATH=/tmp/mdm-revalidate/components.json
    MDM_RCPT_COMPONENT_MANIFEST_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    MDM_RCPT_PROFILE=standard
    MDM_RCPT_LANGUAGE=ja
  }
  _reval_reset_claims
  _reval_capture_calls=0; _reval_attest_calls=0; _reval_identity_calls=0
  _mdm_revalidate_target_identity() { _reval_identity_calls=$((_reval_identity_calls + 1)); }
  _mdm_capture_postcondition() { _reval_capture_calls=$((_reval_capture_calls + 1)); }
  _mdm_attest_components() { _reval_attest_calls=$((_reval_attest_calls + 1)); }
  if _mdm_revalidate_success_state jane /tmp/mdm-revalidate 501 \
      AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE \
    && [[ "$_reval_capture_calls" -eq 2 && "$_reval_attest_calls" -eq 1 \
      && "$_reval_identity_calls" -eq 2 ]]; then
    pass "mdm-install: success直前にdeployment/component/accountを再束縛"
  else
    fail "mdm-install: success直前再検証の呼出順または安定系が不正"
  fi

  _reval_reset_claims
  _mdm_capture_postcondition() {
    MDM_RCPT_DEPLOYMENT_SHA256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
  }
  if ! _mdm_revalidate_success_state jane /tmp/mdm-revalidate 501 \
      AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE; then
    pass "mdm-install: success直前再検証はdeployment driftを拒否"
  else
    fail "mdm-install: stale deployment digestでsuccessへ進行可能"
  fi

  _reval_reset_claims
  _mdm_capture_postcondition() { :; }
  _mdm_attest_components() {
    MDM_RCPT_COMPONENT_MANIFEST_SHA256=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  }
  if ! _mdm_revalidate_success_state jane /tmp/mdm-revalidate 501 \
      AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE; then
    pass "mdm-install: success直前再検証はcomponent driftを拒否"
  else
    fail "mdm-install: stale component digestでsuccessへ進行可能"
  fi
)

# ── root authority: private checkout を実行し、persistent clone は保持専用 ──
(
  _auth_tmp="$(_mdm_test_target_tmpdir)"
  _auth_repo="$_auth_tmp/repo"; _auth_home="$_auth_tmp/home"; _auth_base="$_auth_tmp/auth-base"
  mkdir -p "$_auth_repo" "$_auth_home" "$_auth_base"
  chmod 711 "$_auth_base"
  _mdm_test_chown_target "$_auth_home"
  /usr/bin/git -C "$_auth_repo" init -q
  printf '%s\n' \
    '#!/bin/bash' \
    'set -eu' \
    'auth_dir=$(/usr/bin/dirname "$0")' \
    'printf "%s\n" "$0" > "$HOME/root-authority-path"' \
    'printf "%s\n" "${PROFILE:-}" > "$HOME/root-authority-profile"' \
    'printf "%s\n" "${LANGUAGE:-}" > "$HOME/root-authority-language"' \
    'printf "%s\n" "$@" > "$HOME/root-authority-args"' \
    '/usr/bin/git -C "$auth_dir" rev-parse --verify HEAD > "$HOME/root-authority-head"' \
    'if [[ -f "$HOME/mutate-marker-on-setup" ]]; then /bin/chmod 644 "$HOME/.claude-starter-kit/.claude-starter-kit-mdm-managed"; fi' \
    'if /usr/bin/touch "$auth_dir/target-write-probe" 2>/dev/null; then exit 88; fi' \
    > "$_auth_repo/setup.sh"
  mkdir -p "$_auth_repo/fixture-dir"
  printf '# fixture\n' > "$_auth_repo/CLAUDE.md"
  printf 'nested fixture\n' > "$_auth_repo/fixture-dir/data.txt"
  ln -s CLAUDE.md "$_auth_repo/AGENTS.md"
  chmod +x "$_auth_repo/setup.sh"
  /usr/bin/git -C "$_auth_repo" add setup.sh CLAUDE.md AGENTS.md fixture-dir/data.txt
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$_auth_repo" commit -q -m fixture
  _auth_sha="$(/usr/bin/git -C "$_auth_repo" rev-parse HEAD)"
  _auth_bundle="$_auth_tmp/repo.bundle"
  /usr/bin/git -C "$_auth_repo" bundle create "$_auth_bundle" --all
  chmod 0644 "$_auth_bundle"
  _auth_user="$_MDM_TEST_TARGET_USER"; _auth_uid="$_MDM_TEST_TARGET_UID"

  _mdm_exec_as_user() {
    local _uid="$1" _user="$2" _home="$3"; shift 3
    mdm_build_drop_argv "$_uid" "$_user" "$_home" "$@" || return 1
    _mdm_test_exec_as_target "$_uid" "$_user" "$_home" \
      "${MDM_DROP_ARGV[@]}"
  }
  _mdm_prepare_expected_state() { return 0; }
  _mdm_capture_prior_inventory() { return 0; }
  _mdm_load_expected_required_components() {
    # shellcheck disable=SC2034
    MDM_REQUIRED_COMPONENTS=(kit)
    # shellcheck disable=SC2034
    MDM_RCPT_REQUIRED_COMPONENTS='["kit"]'
    return 0
  }
  _mdm_persist_managed_history() { return 0; }
  _auth_python_cmd="$(command -v python3)"
  _auth_python="$($_auth_python_cmd -c 'import os, sys; print(os.path.realpath(sys.executable))')"
  _mdm_system_python() { printf '%s' "$_auth_python"; }
  unset PROFILE LANGUAGE
  _mdm_root_config_apply "$_auth_tmp/no-config" >/dev/null 2>&1 || exit 1
  export MDM_AUTH_TMPDIR_OVERRIDE="$_auth_base"
  export MDM_AUTH_OWNER_UID_OVERRIDE="$_MDM_TEST_RUNNER_UID"
  export MDM_AUTH_PRIVACY_UID_OVERRIDE=99999
  export MDM_AUTH_READONLY_OWNER_TEST=1
  export MDM_KIT_REPO_URL_OVERRIDE="$_auth_bundle"
  export KIT_MDM_GIT_REF="$_auth_sha"
  export KIT_MDM_EXPECTED_POLICY_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export KIT_MDM_INSTALL_CLAUDE_CLI=false
  export KIT_MDM_DRY_RUN=false
  unset KIT_MDM_INSTALL_DIR

  _auth_rc=0
  _mdm_run_user_phase 0 "$_auth_user" "$_auth_home" "$_auth_uid" \
    >"$_auth_tmp/first.out" 2>&1 || _auth_rc=$?
  _auth_path="$(cat "$_auth_home/root-authority-path" 2>/dev/null || true)"
  _auth_persistent="$_auth_home/.claude-starter-kit"
  if [[ "$_auth_rc" -eq 0 && "$_auth_path" == "$_auth_base"/claude-kit-mdm-auth.*/setup.sh ]] \
    && [[ "$_auth_path" != "$_auth_persistent/setup.sh" ]] \
    && [[ "$(cat "$_auth_home/root-authority-head")" == "$_auth_sha" ]] \
    && [[ "$(cat "$_auth_home/root-authority-profile")" == standard ]] \
    && [[ "$(cat "$_auth_home/root-authority-language")" == en ]] \
    && [[ ! -e "${_auth_path%/setup.sh}" && -z "$_MDM_AUTH_CHECKOUT" ]] \
    && _mdm_detached_head_matches "$_auth_persistent" "$_auth_sha" \
      "$_auth_uid" \
    && _mdm_persistent_marker_trusted "$_auth_persistent" "$_auth_uid"; then
    pass "mdm-install: root は private authoritative setup のみを対象ユーザー実行"
    pass "mdm-install: target user は authoritative tree に書込不能、Git read は成功"
  else
    /usr/bin/tail -120 "$_auth_tmp/first.out" >&2 || true
    fail "mdm-install: root authoritative/persistent 分離が不正 (rc=$_auth_rc path=$_auth_path)"
  fi
  if [[ "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_auth_persistent")")" == 0755 \
    && "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_auth_persistent/setup.sh")")" == 0755 \
    && "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_auth_persistent/CLAUDE.md")")" == 0644 \
    && "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_auth_persistent/fixture-dir")")" == 0755 \
    && "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_auth_persistent/fixture-dir/data.txt")")" == 0644 ]]; then
    pass "mdm-install: retained worktree を Git executable class の canonical mode へ正規化"
  else
    fail "mdm-install: retained worktree の canonical mode 正規化が不正"
  fi
  if grep -qx -- --non-interactive "$_auth_home/root-authority-args" \
    && ! grep -qx -- --update "$_auth_home/root-authority-args"; then
    pass "mdm-install: fresh authoritative setup argv が正しい"
  else
    fail "mdm-install: fresh authoritative setup argv が不正"
  fi

  printf 'stale\n' > "$_auth_persistent/stale-user-file"
  mkdir -p "$_auth_home/.claude"; printf '{}\n' > "$_auth_home/.claude/.starter-kit-manifest.json"
  _mdm_test_chown_target "$_auth_persistent/stale-user-file" \
    "$_auth_home/.claude"
  _auth_rc=0
  _mdm_run_user_phase 0 "$_auth_user" "$_auth_home" "$_auth_uid" \
    >/dev/null 2>&1 || _auth_rc=$?
  if [[ "$_auth_rc" -eq 0 && ! -e "$_auth_persistent/stale-user-file" ]] \
    && ! grep -qx -- --update "$_auth_home/root-authority-args" \
    && [[ "$(cat "$_auth_home/root-authority-profile")" == standard ]] \
    && [[ "$(cat "$_auth_home/root-authority-language")" == en ]]; then
    pass "mdm-install: 既存導入も authoritative fresh と既定 standard/en を維持"
  else
    fail "mdm-install: 既存導入の authoritative fresh/default 契約が不正 (rc=$_auth_rc)"
  fi

  printf 'keep\n' > "$_auth_persistent/dryrun-sentinel"
  _mdm_test_chown_target "$_auth_persistent/dryrun-sentinel"
  _auth_head_before="$(cat "$_auth_persistent/.git/HEAD")"
  export KIT_MDM_DRY_RUN=true
  _auth_rc=0
  _mdm_run_user_phase 0 "$_auth_user" "$_auth_home" "$_auth_uid" \
    >/dev/null 2>&1 || _auth_rc=$?
  _auth_dry_path="$(cat "$_auth_home/root-authority-path" 2>/dev/null || true)"
  if [[ "$_auth_rc" -eq 0 && "$(cat "$_auth_persistent/dryrun-sentinel")" == keep ]] \
    && [[ "$(cat "$_auth_persistent/.git/HEAD")" == "$_auth_head_before" ]] \
    && grep -qx -- --dry-run "$_auth_home/root-authority-args" \
    && [[ "$_auth_dry_path" == "$_auth_base"/claude-kit-mdm-auth.*/setup.sh ]] \
    && [[ ! -e "${_auth_dry_path%/setup.sh}" ]]; then
    pass "mdm-install: root dry-run は auth temp だけを実行し persistent を不変化"
  else
    fail "mdm-install: root dry-run が persistent を変更 (rc=$_auth_rc)"
  fi
  export KIT_MDM_DRY_RUN=false
  : > "$_auth_home/mutate-marker-on-setup"
  _mdm_test_chown_target "$_auth_home/mutate-marker-on-setup"
  _auth_rc=0
  _mdm_run_user_phase 0 "$_auth_user" "$_auth_home" "$_auth_uid" \
    >/dev/null 2>&1 || _auth_rc=$?
  if [[ "$_auth_rc" -ne 0 ]] \
    && ! _mdm_persistent_marker_trusted "$_auth_persistent" "$_auth_uid"; then
    pass "mdm-install: setup 後の persistent trust drift を成功扱いしない"
  else
    fail "mdm-install: setup 後の marker/mode drift を見逃す (rc=$_auth_rc)"
  fi
  _mdm_cleanup_auth_entry_list >/dev/null 2>&1 || true
  _mdm_cleanup_auth_checkout >/dev/null 2>&1 || true
  rm -rf "$_auth_tmp"
)

# 既存 persistent directory は管理 marker が無ければ削除しない。
(
  _marker_tmp="$(mktemp -d)"; _marker_home="$_marker_tmp/home"
  mkdir -p "$_marker_home/.claude-starter-kit"
  printf 'preserve\n' > "$_marker_home/.claude-starter-kit/user-data"
  export KIT_MDM_DRY_RUN=false KIT_MDM_GIT_REF=0123456789abcdef0123456789abcdef01234567
  export KIT_MDM_EXPECTED_POLICY_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  unset KIT_MDM_INSTALL_DIR
  _marker_rc=0
  _mdm_run_user_phase 0 "$(/usr/bin/id -un)" "$_marker_home" \
    "$(/usr/bin/id -u)" >/dev/null 2>&1 || _marker_rc=$?
  if [[ "$_marker_rc" -eq "$MDM_EXIT_CONFIG" \
    && "$(cat "$_marker_home/.claude-starter-kit/user-data")" == preserve ]]; then
    pass "mdm-install: 管理 marker 無し既存 checkout を fail-closed で保持"
  else
    fail "mdm-install: marker 無し checkout を削除/許可 (rc=$_marker_rc)"
  fi
  rm -rf "$_marker_tmp"
)

# marker は固定1行に見える prefix だけでなく、末尾 bytes まで照合する。
(
  _marker_tmp="$(mktemp -d)"
  _marker_install="$_marker_tmp/.claude-starter-kit"
  mkdir -p "$_marker_install"
  printf 'claude-code-starter-kit-mdm-user-v1\n\0' \
    > "$_marker_install/.claude-starter-kit-mdm-managed"
  chmod 444 "$_marker_install/.claude-starter-kit-mdm-managed"
  if _mdm_persistent_marker_trusted "$_marker_install" "$(/usr/bin/id -u)"; then
    fail "mdm-install: marker の末尾追加データを許可"
  else
    pass "mdm-install: persistent marker は末尾改行を含め byte-exact"
  fi
  rm -rf "$_marker_tmp"
)

# target-user writable checkout 配下へ root が marker を直接書かない。
(
  _marker_tmp="$(mktemp -d)"
  _marker_install="$_marker_tmp/.claude-starter-kit"
  mkdir -p "$_marker_install"
  _marker_drop_called=0
  _mdm_run_maybe_as_user() { _marker_drop_called=1; return 77; }
  if ! _mdm_create_persistent_marker "$_marker_install" "$(/usr/bin/id -u)" \
    && [[ "$_marker_drop_called" -eq 1 ]] \
    && [[ ! -e "$_marker_install/.claude-starter-kit-mdm-managed" ]]; then
    pass "mdm-install: persistent marker 作成は対象ユーザー権限へ降格"
  else
    fail "mdm-install: persistent marker を root で直接作成し得る"
  fi
  rm -rf "$_marker_tmp"
)

# 保持用 checkout は stage 完成前に既存状態を破壊せず、失敗後も再試行可能。
(
  _txn_tmp="$(mktemp -d)"
  _txn_tmp="$(builtin cd -P "$_txn_tmp" && printf '%s' "$PWD")"
  _txn_repo="$_txn_tmp/repo"
  _txn_home="$_txn_tmp/home"
  _txn_install="$_txn_home/.claude-starter-kit"
  _txn_uid="$(/usr/bin/id -u)"
  mkdir -p "$_txn_repo" "$_txn_home"
  /usr/bin/git -C "$_txn_repo" init -q
  printf 'transaction fixture\n' > "$_txn_repo/payload.txt"
  /usr/bin/git -C "$_txn_repo" add payload.txt
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$_txn_repo" commit -q -m fixture
  _txn_sha="$(/usr/bin/git -C "$_txn_repo" rev-parse HEAD)"
  /usr/bin/git clone --quiet --no-checkout --no-local "$_txn_repo" "$_txn_install"
  /usr/bin/git -C "$_txn_install" checkout --quiet --force --detach "$_txn_sha"
  _MDM_GIT_DROP_UID=""
  _MDM_GIT_DROP_USER=""
  _MDM_GIT_DROP_HOME=""
  _MDM_TEST_MODE=1
  _txn_python_cmd="$(command -v python3)"
  MDM_SYSTEM_PYTHON_OVERRIDE="$($_txn_python_cmd -c \
    'import os, sys; print(os.path.realpath(sys.executable))')"
  export MDM_SYSTEM_PYTHON_OVERRIDE
  _mdm_create_persistent_marker "$_txn_install" "$_txn_uid" || exit 1
  printf 'old checkout\n' > "$_txn_install/old-sentinel"
  _txn_old_head="$(cat "$_txn_install/.git/HEAD")"

  _txn_fail_fetch=0
  _txn_swap_install=1
  _txn_displaced="$_txn_home/displaced-managed-checkout"
  _mdm_git() {
    local _txn_arg _txn_is_status=0 _txn_git_rc=0
    for _txn_arg in "$@"; do
      if [[ "$_txn_fail_fetch" == 1 && "$_txn_arg" == fetch ]]; then
        return 86
      fi
      [[ "$_txn_arg" == status ]] && _txn_is_status=1
    done
    if [[ "$_txn_swap_install" == 1 && "$_txn_is_status" == 1 ]]; then
      /usr/bin/git "$@" || _txn_git_rc=$?
      /bin/mv "$_txn_install" "$_txn_displaced" || return 87
      /bin/mkdir "$_txn_install" || return 88
      printf 'unmanaged replacement\n' > "$_txn_install/user-data"
      _txn_swap_install=0
      return "$_txn_git_rc"
    fi
    /usr/bin/git "$@"
  }

  _txn_rc=0
  _mdm_rebuild_persistent_checkout \
    "$_txn_install" "$_txn_repo" "$_txn_sha" "$_txn_uid" || _txn_rc=$?
  if [[ "$_txn_rc" -ne 0 \
    && "$(cat "$_txn_install/user-data" 2>/dev/null || true)" == 'unmanaged replacement' \
    && "$(cat "$_txn_displaced/old-sentinel" 2>/dev/null || true)" == 'old checkout' ]] \
    && _mdm_persistent_marker_trusted "$_txn_displaced" "$_txn_uid" \
    && ! /usr/bin/find "$_txn_home" -maxdepth 1 \
      -name '.claude-starter-kit.mdm-stage.*' -print -quit | /usr/bin/grep -q .; then
    pass "mdm-install: pre-swap identity 差替え時は未管理 directory を削除しない"
  else
    fail "mdm-install: pre-swap TOCTOU で未管理 directory を削除し得る"
  fi
  /bin/rm -rf "$_txn_install"
  /bin/mv "$_txn_displaced" "$_txn_install"

  _txn_fail_fetch=1
  _txn_swap_install=0
  _txn_rc=0
  _mdm_rebuild_persistent_checkout \
    "$_txn_install" "$_txn_repo" "$_txn_sha" "$_txn_uid" || _txn_rc=$?
  if [[ "$_txn_rc" -ne 0 \
    && "$(cat "$_txn_install/old-sentinel" 2>/dev/null || true)" == 'old checkout' \
    && "$(cat "$_txn_install/.git/HEAD" 2>/dev/null || true)" == "$_txn_old_head" ]] \
    && _mdm_persistent_marker_trusted "$_txn_install" "$_txn_uid" \
    && ! /usr/bin/find "$_txn_home" -maxdepth 1 \
      -name '.claude-starter-kit.mdm-stage.*' -print -quit | /usr/bin/grep -q .; then
    pass "mdm-install: rebuild 失敗時は既存 persistent checkout を不変保持"
  else
    fail "mdm-install: rebuild 失敗が既存 persistent checkout を破壊"
  fi

  _txn_fail_fetch=0
  if _mdm_rebuild_persistent_checkout \
      "$_txn_install" "$_txn_repo" "$_txn_sha" "$_txn_uid" \
    && [[ ! -e "$_txn_install/old-sentinel" ]] \
    && _mdm_persistent_marker_trusted "$_txn_install" "$_txn_uid" \
    && _mdm_detached_head_matches "$_txn_install" "$_txn_sha" "$_txn_uid" \
    && ! /usr/bin/find "$_txn_home" -maxdepth 1 \
      -name '.claude-starter-kit.mdm-stage.*' -print -quit | /usr/bin/grep -q .; then
    pass "mdm-install: 完成済み stage を原子的に persistent checkout へ切替"
  else
    fail "mdm-install: transactional rebuild の成功切替が不正"
  fi

  /bin/rm -rf "$_txn_install"
  _txn_fail_fetch=1
  _txn_rc=0
  _mdm_rebuild_persistent_checkout \
    "$_txn_install" "$_txn_repo" "$_txn_sha" "$_txn_uid" || _txn_rc=$?
  if [[ "$_txn_rc" -ne 0 && ! -e "$_txn_install" && ! -L "$_txn_install" ]] \
    && ! /usr/bin/find "$_txn_home" -maxdepth 1 \
      -name '.claude-starter-kit.mdm-stage.*' -print -quit | /usr/bin/grep -q .; then
    pass "mdm-install: 初回 rebuild 失敗は marker 無し残骸を残さない"
  else
    fail "mdm-install: 初回 rebuild 失敗が再試行不能な残骸を作成"
  fi

  _txn_fail_fetch=0
  if _mdm_rebuild_persistent_checkout \
      "$_txn_install" "$_txn_repo" "$_txn_sha" "$_txn_uid" \
    && _mdm_persistent_marker_trusted "$_txn_install" "$_txn_uid" \
    && _mdm_detached_head_matches "$_txn_install" "$_txn_sha" "$_txn_uid"; then
    pass "mdm-install: 初回途中失敗の次回 remediation で自動復旧"
  else
    fail "mdm-install: 初回途中失敗後に自動復旧できない"
  fi

  _txn_fresh_install="$_txn_home/fresh-raced-install"
  _txn_fresh_stage="$_txn_home/.claude-starter-kit.mdm-stage.fresh-race"
  /bin/mkdir "$_txn_fresh_install"
  printf 'unmanaged fresh replacement\n' > "$_txn_fresh_install/user-data"
  _MDM_PERSISTENT_STAGE="$_txn_fresh_stage"
  _MDM_PERSISTENT_STAGE_IDENTITY='0:0:directory'
  _txn_rc=0
  _mdm_retract_initial_persistent_checkout \
    "$_txn_fresh_stage" "$_txn_fresh_install" '0:0:directory' || _txn_rc=$?
  if [[ "$_txn_rc" -ne 0 \
    && "$(cat "$_txn_fresh_install/user-data" 2>/dev/null || true)" \
      == 'unmanaged fresh replacement' \
    && ! -e "$_txn_fresh_stage" && ! -L "$_txn_fresh_stage" \
    && -z "$_MDM_PERSISTENT_STAGE" && -z "$_MDM_PERSISTENT_STAGE_IDENTITY" ]]; then
    pass "mdm-install: fresh post-swap identity 差替えは固定pathへ復元し削除しない"
  else
    fail "mdm-install: fresh post-swap TOCTOU で未管理 directory を削除し得る"
  fi

  _txn_rollback_install="$_txn_home/rollback-active"
  _txn_rollback_stage="$_txn_home/.claude-starter-kit.mdm-stage.rollback"
  /bin/mkdir "$_txn_rollback_install" "$_txn_rollback_stage"
  printf 'rejected candidate\n' > "$_txn_rollback_install/new"
  printf 'previous checkout\n' > "$_txn_rollback_stage/old"
  _MDM_PERSISTENT_STAGE="$_txn_rollback_stage"
  _MDM_PERSISTENT_STAGE_IDENTITY="$(_mdm_persistent_dir_identity "$_txn_rollback_stage")"
  _mdm_promote_persistent_stage() { return 89; }
  _txn_rc=0
  _mdm_restore_previous_persistent_checkout \
    "$_txn_rollback_stage" "$_txn_rollback_install" "$_txn_uid" \
    "$(_mdm_persistent_dir_identity "$_txn_rollback_install")" \
    "$(_mdm_persistent_dir_identity "$_txn_rollback_stage")" || _txn_rc=$?
  if [[ "$_txn_rc" -ne 0 \
    && "$(cat "$_txn_rollback_stage/old" 2>/dev/null || true)" == 'previous checkout' \
    && "$(cat "$_txn_rollback_install/new" 2>/dev/null || true)" == 'rejected candidate' \
    && -z "$_MDM_PERSISTENT_STAGE" && -z "$_MDM_PERSISTENT_STAGE_IDENTITY" ]]; then
    pass "mdm-install: rollback swap 失敗時は旧 checkout を recovery stage に保持"
  else
    fail "mdm-install: rollback swap 失敗時に旧 checkout を削除"
  fi
  rm -rf "$_txn_tmp"
)

# production remediation は named ref で authority を曖昧にしない。
(
  _MDM_TEST_MODE=0
  _sha_full=0123456789abcdef0123456789abcdef01234567
  if ! _mdm_root_ref_allowed main false \
    && ! _mdm_root_ref_allowed main true \
    && _mdm_root_ref_allowed "$_sha_full" false \
    && _mdm_root_ref_allowed "$_sha_full" true; then
    pass "mdm-install: production remediation/dry-run はともに40桁 SHA必須"
  else
    fail "mdm-install: production ref/dry-run 契約が不正"
  fi
)

# Every production execution is semantically invalid without a predeployed
# desired-policy binding, including a non-mutating preview.
(
  _policy_semantic_tmp="$(mktemp -d)"
  _policy_semantic_home="$_policy_semantic_tmp/home"
  _policy_semantic_sha=0123456789abcdef0123456789abcdef01234567
  _policy_semantic_hash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  /bin/mkdir -p "$_policy_semantic_home"
  _MDM_TEST_MODE=0
  unset KIT_MDM_INSTALL_DIR KIT_MDM_LOG_DIR KIT_MDM_EXPECTED_POLICY_SHA256

  _missing_rc=0
  KIT_MDM_GIT_REF="$_policy_semantic_sha" KIT_MDM_DRY_RUN=false \
    _mdm_validate_semantic_config 0 "$_policy_semantic_home" 501 false \
      >/dev/null 2>&1 || _missing_rc=$?
  _invalid_rc=0
  KIT_MDM_GIT_REF="$_policy_semantic_sha" KIT_MDM_DRY_RUN=false \
    KIT_MDM_EXPECTED_POLICY_SHA256=ABC123 \
    _mdm_validate_semantic_config 0 "$_policy_semantic_home" 501 false \
      >/dev/null 2>&1 || _invalid_rc=$?
  _valid_rc=0
  KIT_MDM_GIT_REF="$_policy_semantic_sha" KIT_MDM_DRY_RUN=false \
    KIT_MDM_EXPECTED_POLICY_SHA256="$_policy_semantic_hash" \
    _mdm_validate_semantic_config 0 "$_policy_semantic_home" 501 false \
      >/dev/null 2>&1 || _valid_rc=$?
  _preview_missing_rc=0
  KIT_MDM_GIT_REF="$_policy_semantic_sha" KIT_MDM_DRY_RUN=true \
    _mdm_validate_semantic_config 0 "$_policy_semantic_home" 501 true \
      >/dev/null 2>&1 || _preview_missing_rc=$?
  _preview_valid_rc=0
  KIT_MDM_GIT_REF="$_policy_semantic_sha" KIT_MDM_DRY_RUN=true \
    KIT_MDM_EXPECTED_POLICY_SHA256="$_policy_semantic_hash" \
    _mdm_validate_semantic_config 0 "$_policy_semantic_home" 501 true \
      >/dev/null 2>&1 || _preview_valid_rc=$?

  if [[ "$_missing_rc" -eq "$MDM_EXIT_CONFIG" \
    && "$_invalid_rc" -eq "$MDM_EXIT_CONFIG" && "$_valid_rc" -eq 0 \
    && "$_preview_missing_rc" -eq "$MDM_EXIT_CONFIG" \
    && "$_preview_valid_rc" -eq 0 ]]; then
    pass "mdm-install: remediation/dry-run の policy binding入力を厳密検証"
  else
    fail "mdm-install: expected policy のsemantic検証が不正 (missing=$_missing_rc invalid=$_invalid_rc valid=$_valid_rc preview-missing=$_preview_missing_rc preview-valid=$_preview_valid_rc)"
  fi
  /bin/rm -rf "$_policy_semantic_tmp"
)
(
  _policy_precedence_tmp="$(mktemp -d)"
  _MDM_TEST_MODE=1
  MDM_EUID_OVERRIDE=0
  MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_policy_precedence_tmp"
  KIT_MDM_TARGET_USER='invalid/name'
  unset KIT_MDM_EXPECTED_POLICY_SHA256
  _mdm_supported_macos_host() { return 0; }
  _mdm_root_config_apply() { return 0; }
  _mdm_apply_mdm_defaults() { KIT_MDM_DRY_RUN=false; }
  mdm_log() { :; }
  _precedence_rc=0
  (mdm_main) >/dev/null 2>&1 || _precedence_rc=$?
  if [[ "$_precedence_rc" -eq "$MDM_EXIT_CONFIG" \
    && -z "$(/usr/bin/find "$_policy_precedence_tmp" -mindepth 1 -print -quit)" ]]; then
    pass "mdm-install: policy SHA欠落はinvalid user/receiptより先にexit 50"
  else
    fail "mdm-install: policy SHA欠落がuser解決より後段 (rc=$_precedence_rc)"
  fi
  /bin/rm -rf "$_policy_precedence_tmp"
)

# ── dry-run は一時 checkout のみを使い、終了時に除去 ─────
(
  _dry_alias_root="$(_mdm_test_target_tmpdir)"
  _dry_alias_physical="$_dry_alias_root/physical"
  _dry_alias="$_dry_alias_root/alias"
  _dry_alias_home="$_dry_alias_root/home"
  _dry_alias_installer="$_dry_alias_root/install-mdm.sh"
  /bin/mkdir "$_dry_alias_physical" "$_dry_alias_home"
  /bin/ln -s "$_dry_alias_physical" "$_dry_alias"
  /bin/cp "$PROJECT_DIR/mdm/install-mdm.sh" "$_dry_alias_installer"
  /bin/chmod 0644 "$_dry_alias_installer"
  _mdm_test_chown_target "$_dry_alias_root"
  _dry_alias_rc=0
  _mdm_test_exec_as_target "$_MDM_TEST_TARGET_UID" \
    "$_MDM_TEST_TARGET_USER" "$_dry_alias_home" \
    /bin/bash --noprofile --norc -s -- \
      "$_dry_alias_installer" "$_dry_alias_root" "$_dry_alias" \
      "$_dry_alias_physical" "$_MDM_TEST_TARGET_UID" \
      "$_MDM_TEST_TARGET_USER" <<'DRY_ALIAS_CHILD' \
      >/dev/null 2>&1 || _dry_alias_rc=$?
_installer="$1"
_root="$2"
_alias="$3"
_physical="$4"
_expected_uid="$5"
_expected_user="$6"
MDM_SOURCE_ONLY=1 source "$_installer"
_uid="$(/usr/bin/id -u)"
_user="$(/usr/bin/id -un)"
[[ "$_uid" == "$_expected_uid" && "$_user" == "$_expected_user" \
  && "$_uid" -ge 501 ]] || exit 97
_MDM_TEST_MODE=1
MDM_TEST_TMP_ROOT="$_root"
KIT_MDM_DRY_RUN=true
KIT_MDM_EXPECTED_POLICY_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
KIT_MDM_INSTALL_CLAUDE_CLI=false
_dry_runner_helper="$(declare -f _mdm_test_runner_tmp_base)"
_mdm_test_runner_tmp_base() { printf '%s' "$_alias"; }
function /usr/bin/mktemp {
  local _created
  [[ "$#" -eq 2 && "$1" == -d \
    && "$2" == "$_alias/claude-kit-mdm-dryrun.XXXXXX" ]] || return 2
  _created="$(builtin command /usr/bin/mktemp -d \
    "$_physical/claude-kit-mdm-dryrun.XXXXXX")" || return 1
  if [[ ! -d "$_created" || -L "$_created" \
    || "$(_mdm_stat_uid "$_created" 2>/dev/null || true)" != "$_uid" ]]; then
    /bin/rm -rf "$_created"
    return 1
  fi
  : > "$_root/allocation-ok" || return 1
  printf '%s%s\n' "$_alias" "${_created#"$_physical"}"
}
_mdm_git_network() { return 1; }
_MDM_DRYRUN_CHECKOUT=""
_run_rc=0
_mdm_run_user_phase "$_uid" "$_user" "$_root/home" "$_uid" \
  >/dev/null 2>&1 || _run_rc=$?
_checkout="$_MDM_DRYRUN_CHECKOUT"
printf '%s\n' "$_checkout" > "$_root/checkout-record"
[[ "$_run_rc" -eq 1 && -f "$_root/allocation-ok" \
  && "$_checkout" == "$_physical"/claude-kit-mdm-dryrun.* ]] || exit 98
eval "$_dry_runner_helper"
_cleanup_rc=0
_mdm_cleanup_dryrun_checkout >/dev/null 2>&1 || _cleanup_rc=$?
[[ "$_cleanup_rc" -eq 0 && ! -e "$_checkout" && ! -L "$_checkout" \
  && -z "$_MDM_DRYRUN_CHECKOUT" ]] || exit 99
: > "$_root/result"
DRY_ALIAS_CHILD
  _dry_alias_checkout="$(/bin/cat \
    "$_dry_alias_root/checkout-record" 2>/dev/null || true)"
  if [[ "$_dry_alias_rc" -eq 0 && -f "$_dry_alias_root/result" \
    && "$_dry_alias_checkout" == "$_dry_alias_physical"/claude-kit-mdm-dryrun.* \
    && ! -e "$_dry_alias_checkout" && ! -L "$_dry_alias_checkout" ]]; then
    pass "mdm-install: symlink 一時baseはlexical割当後にphysical pathへ束縛"
  else
    fail "mdm-install: symlink 一時baseのcanonical束縛が不正 (rc=$_dry_alias_rc)"
  fi
  /bin/rm -rf "$_dry_alias_root"
)

(
  _managed_tmp_probe="$(mktemp -d)"
  _managed_tmp_checkout="$_managed_tmp_probe/claude-kit-mdm-dryrun.fixture"
  /bin/mkdir "$_managed_tmp_checkout"
  _MDM_DRYRUN_CHECKOUT="$_managed_tmp_checkout"
  _mdm_run_maybe_as_user() { return 97; }
  _managed_tmp_cleanup_rejected=false
  _mdm_cleanup_dryrun_checkout >/dev/null 2>&1 \
    || _managed_tmp_cleanup_rejected=true
  if ! _mdm_managed_tmp_path_matches \
      /private/tmp/claude-kit-mdm-dryrun.x/../../victim \
      claude-kit-mdm-dryrun \
    && ! _mdm_managed_tmp_path_matches \
      /tmp/claude-kit-mdm-launcher.x/../victim claude-kit-mdm-launcher \
    && [[ "$_managed_tmp_cleanup_rejected" == true \
      && "$_MDM_DRYRUN_CHECKOUT" == "$_managed_tmp_checkout" \
      && -d "$_managed_tmp_checkout" ]]; then
    pass "mdm-install: managed tmp cleanupは単一basenameへ固定し失敗時authorityを保持"
  else
    fail "mdm-install: managed tmp cleanupがescapeまたは失敗を成功扱い"
  fi
  /bin/rm -rf "$_managed_tmp_probe"
)

(
  _dry_tmp="$(_mdm_test_target_tmpdir)"
  _dry_repo="$_dry_tmp/repo"
  _dry_home="$_dry_tmp/home"
  _dry_installer="$_dry_tmp/install-mdm.sh"
  mkdir -p "$_dry_home"
  git clone -q --no-hardlinks "$PROJECT_DIR" "$_dry_repo"
  /bin/cp "$PROJECT_DIR/mdm/install-mdm.sh" "$_dry_installer"
  chmod 0644 "$_dry_installer"
  printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "$HOME/mdm-dryrun-args"\nprintf "%%s\\n" "$PATH" > "$HOME/mdm-dryrun-path"\n' > "$_dry_repo/setup.sh"
  chmod +x "$_dry_repo/setup.sh"
  git -C "$_dry_repo" add setup.sh
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    git -C "$_dry_repo" commit -q -m fixture
  _dry_sha="$(git -C "$_dry_repo" rev-parse HEAD)"
  /bin/mkdir "$_dry_tmp/runtime"
  _mdm_test_chown_target "$_dry_tmp"
  chmod 0700 "$_dry_tmp" "$_dry_home" "$_dry_tmp/runtime"

  _dry_child_rc=0
  _mdm_test_exec_as_target \
    "$_MDM_TEST_TARGET_UID" "$_MDM_TEST_TARGET_USER" "$_dry_home" \
    /usr/bin/env \
    "HOME=$_dry_home" \
    "USER=$_MDM_TEST_TARGET_USER" \
    "LOGNAME=$_MDM_TEST_TARGET_USER" \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    "LC_ALL=C" \
    "GIT_CONFIG_NOSYSTEM=1" \
    "GIT_CONFIG_GLOBAL=/dev/null" \
    "_MDM_TEST_MODE=1" \
    "MDM_SYSTEM_PYTHON_OVERRIDE=$MDM_SYSTEM_PYTHON_OVERRIDE" \
    "MDM_TEST_TMP_ROOT=$_dry_tmp/runtime" \
    "TMPDIR=$_dry_tmp/runtime" \
    /bin/bash --noprofile --norc -s -- \
    "$_dry_installer" "$_dry_tmp" "$_dry_repo" "$_dry_home" "$_dry_sha" \
    "$_MDM_TEST_TARGET_UID" "$_MDM_TEST_TARGET_USER" <<'DRYRUN_CHILD' \
    >/dev/null 2>&1 || _dry_child_rc=$?
_dry_installer="$1"
_dry_tmp="$2"
_dry_repo="$3"
_dry_home="$4"
_dry_sha="$5"
_dry_expected_uid="$6"
_dry_expected_user="$7"
MDM_SOURCE_ONLY=1 source "$_dry_installer"
_dry_runtime_uid="$(/usr/bin/id -u)"
_dry_runtime_user="$(/usr/bin/id -un)"
[[ "$_dry_runtime_uid" -ge 501 \
  && "$_dry_runtime_uid" == "$_dry_expected_uid" \
  && "$_dry_runtime_user" == "$_dry_expected_user" ]] || exit 97

export HOME="$_dry_home"
export MDM_KIT_REPO_URL_OVERRIDE="$_dry_repo"
export KIT_MDM_GIT_REF="$_dry_sha"
export KIT_MDM_EXPECTED_POLICY_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export KIT_MDM_DRY_RUN=true
export KIT_MDM_INSTALL_CLAUDE_CLI=false
export KIT_MDM_INSTALL_DIR="$_dry_home/should-not-be-used"
export MDM_AUTH_TMPDIR_OVERRIDE="$MDM_TEST_TMP_ROOT"
_MDM_GIT_DROP_UID=""; _MDM_GIT_DROP_USER=""; _MDM_GIT_DROP_HOME=""
KIT_MDM_POLICY_SHA256=""
MDM_RCPT_POLICY_SHA256=""
export KIT_MDM_POLICY_SHA256 MDM_RCPT_POLICY_SHA256
printf '%s\n' receipt-sentinel > "$_dry_tmp/receipt.json"
_dry_receipt_before="$(_mdm_sha256_file "$_dry_tmp/receipt.json")"
_dry_cleanup() {
  local _cleanup_rc=0
  _mdm_cleanup_dryrun_checkout >/dev/null 2>&1 || _cleanup_rc=1
  _mdm_cleanup_expected_dir >/dev/null 2>&1 || _cleanup_rc=1
  _mdm_cleanup_checkout_renderer_snapshot >/dev/null 2>&1 || _cleanup_rc=1
  _mdm_cleanup_renderer_snapshot >/dev/null 2>&1 || _cleanup_rc=1
  return "$_cleanup_rc"
}

_dry_wrong_rc=0
_mdm_run_user_phase "$_dry_runtime_uid" "$_dry_runtime_user" "$_dry_home" \
  >/dev/null 2>&1 || _dry_wrong_rc=$?
_dry_calculated_policy="$(_mdm_sha256_file \
  "$_MDM_EXPECTED_OUTPUT/policy.json" 2>/dev/null || true)"
_dry_wrong_setup_absent=true
[[ ! -e "$_dry_home/mdm-dryrun-args" ]] || _dry_wrong_setup_absent=false
_dry_wrong_receipt_after="$(_mdm_sha256_file "$_dry_tmp/receipt.json")"
_dry_wrong_cleanup_rc=0
_dry_cleanup || _dry_wrong_cleanup_rc=$?
if [[ "$_dry_wrong_rc" -eq "$MDM_EXIT_CONFIG" \
  && "$_dry_calculated_policy" =~ ^[0-9a-f]{64}$ \
  && "$_dry_wrong_setup_absent" == true \
  && "$_dry_wrong_cleanup_rc" -eq 0 \
  && "$_dry_receipt_before" == "$_dry_wrong_receipt_after" ]]; then
  : > "$_dry_tmp/result-policy"
fi

export KIT_MDM_EXPECTED_POLICY_SHA256="$_dry_calculated_policy"
_dry_rc=0
_mdm_run_user_phase "$_dry_runtime_uid" "$_dry_runtime_user" "$_dry_home" \
  >/dev/null 2>&1 || _dry_rc=$?
_dry_checkout="$_MDM_DRYRUN_CHECKOUT"
_dry_owner_bound=false
if [[ "${_MDM_EXPECTED_OWNER_UID:-}" == "$_dry_runtime_uid" \
  && "${_MDM_EXPECTED_RENDERER_OWNER_UID:-}" == "$_dry_runtime_uid" \
  && "$(_mdm_stat_uid "$_MDM_EXPECTED_DIR" 2>/dev/null || true)" \
    == "$_dry_runtime_uid" \
  && "$(_mdm_stat_uid "$_MDM_EXPECTED_RENDERER" 2>/dev/null || true)" \
    == "$_dry_runtime_uid" ]]; then
  _dry_owner_bound=true
fi
_dry_path="$(/bin/cat "$_dry_home/mdm-dryrun-path" 2>/dev/null || true)"
_dry_path_ok=true
if [[ -x /opt/homebrew/bin/brew \
  && ":$_dry_path:" != *:/opt/homebrew/bin:* ]]; then
  _dry_path_ok=false
fi
if [[ -x /usr/local/bin/brew \
  && ":$_dry_path:" != *:/usr/local/bin:* ]]; then
  _dry_path_ok=false
fi
for _dry_tool_dir in /opt/homebrew/opt/gnu-sed/libexec/gnubin \
  /usr/local/opt/gnu-sed/libexec/gnubin \
  /opt/homebrew/opt/gawk/libexec/gnubin \
  /usr/local/opt/gawk/libexec/gnubin; do
  [[ -d "$_dry_tool_dir" && ! -L "$_dry_tool_dir" ]] || continue
  [[ ":$_dry_path:" == *":$_dry_tool_dir:"* ]] || _dry_path_ok=false
done
if [[ "$_dry_rc" -eq 0 && -d "$_dry_checkout" ]] \
  && /usr/bin/grep -qx -- '--dry-run' "$_dry_home/mdm-dryrun-args" \
  && [[ ! -e "$_dry_home/should-not-be-used" \
    && "$_dry_path_ok" == true \
    && "$_dry_owner_bound" == true \
    && "$(_mdm_sha256_file "$_dry_tmp/receipt.json")" \
      == "$_dry_receipt_before" ]]; then
  : > "$_dry_tmp/result-setup"
fi
_dry_cleanup_rc=0
_dry_cleanup || _dry_cleanup_rc=$?
if [[ "$_dry_cleanup_rc" -eq 0 && -n "$_dry_checkout" \
  && ! -e "$_dry_checkout" && -z "$_MDM_DRYRUN_CHECKOUT" ]]; then
  : > "$_dry_tmp/result-cleanup"
fi

export KIT_MDM_INSTALL_CLAUDE_CLI=true
_mdm_cli_present_for_home() { return 1; }
/bin/rm -f "$_dry_home/mdm-dryrun-args" "$_dry_home/mdm-dryrun-path"
export KIT_MDM_EXPECTED_POLICY_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
_dry_cli_probe_rc=0
_mdm_run_user_phase "$_dry_runtime_uid" "$_dry_runtime_user" "$_dry_home" \
  >/dev/null 2>&1 || _dry_cli_probe_rc=$?
_dry_cli_policy="$(_mdm_sha256_file \
  "$_MDM_EXPECTED_OUTPUT/policy.json" 2>/dev/null || true)"
_dry_cli_probe_cleanup_rc=0
_dry_cleanup || _dry_cli_probe_cleanup_rc=$?
export KIT_MDM_EXPECTED_POLICY_SHA256="$_dry_cli_policy"
_dry_cli_rc=0
_mdm_run_user_phase "$_dry_runtime_uid" "$_dry_runtime_user" "$_dry_home" \
  >/dev/null 2>&1 || _dry_cli_rc=$?
_dry_cli_cleanup_rc=0
_dry_cleanup || _dry_cli_cleanup_rc=$?
if [[ "$_dry_cli_probe_rc" -eq "$MDM_EXIT_CONFIG" \
  && "$_dry_cli_policy" =~ ^[0-9a-f]{64}$ \
  && "$_dry_cli_probe_cleanup_rc" -eq 0 \
  && "$_dry_cli_rc" -eq 0 && "$_dry_cli_cleanup_rc" -eq 0 ]]; then
  : > "$_dry_tmp/result-cli"
fi
exit 0
DRYRUN_CHILD

  if [[ "$_dry_child_rc" -eq 0 && -f "$_dry_tmp/result-policy" ]]; then
    pass "mdm-install: non-root dry-runもpolicy不一致をsetup前exit 50で拒否"
  else
    fail "mdm-install: non-root dry-runがpolicy不一致でsetup/receiptを変更 (child=$_dry_child_rc)"
  fi
  if [[ "$_dry_child_rc" -eq 0 && -f "$_dry_tmp/result-setup" ]]; then
    pass "mdm-install: 正policyのnon-root dry-runは一時checkoutからsetupへ到達"
  else
    fail "mdm-install: dry-run の一時checkout/PATH契約が不正 (child=$_dry_child_rc)"
  fi
  if [[ "$_dry_child_rc" -eq 0 && -f "$_dry_tmp/result-cleanup" ]]; then
    pass "mdm-install: dry-run 一時 checkout を完了時に除去"
  else
    fail "mdm-install: dry-run 一時 checkout が残存 (child=$_dry_child_rc)"
  fi
  if [[ "$_dry_child_rc" -eq 0 && -f "$_dry_tmp/result-cli" ]]; then
    pass "mdm-install: non-root dry-run は未導入 CLI を失敗扱いにしない"
  else
    fail "mdm-install: non-root dry-run が未導入 CLI で失敗 (child=$_dry_child_rc)"
  fi
  /bin/rm -rf "$_dry_tmp"
)

# Log setup failure during a preview must return a config error without
# invoking the receipt-writing finish path.
(
  _dry_finish_called=0
  _mdm_finish() { _dry_finish_called=1; return 0; }
  _dry_log_rc=0
  _mdm_handle_log_setup_failure jane /Users/jane true || _dry_log_rc=$?
  if [[ "$_dry_log_rc" -eq "$MDM_EXIT_CONFIG" && "$_dry_finish_called" -eq 0 ]]; then
    pass "mdm-install: dry-run log 初期化失敗は receipt を変更しない"
  else
    fail "mdm-install: dry-run log 初期化失敗が receipt finish を呼び得る"
  fi
)

# Root history is independent of a user manifest/receipt, but grants deletion
# authority only to files that passed a successful root postcondition.  An
# absent candidate is never promoted merely by rendering or a failed attempt.
(
  _history_tmp="$(mktemp -d)"
  _history_support="$_history_tmp/support"
  _history_rendered="$_history_tmp/rendered"
  _history_home="$_history_tmp/home"
  _history_user="$_MDM_TEST_TARGET_USER"
  _history_uid="$_MDM_TEST_TARGET_UID"
  _history_guid="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
  mkdir -p "$_history_support" "$_history_rendered" "$_history_home/.claude"
  chmod 755 "$_history_support"
  jq -n '{files:["CLAUDE.md","settings.json"],absent_files:["commands/retired.md"]}' \
    > "$_history_rendered/manifest.json"
  export MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_history_support"
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  export MDM_DSCL_UID_OVERRIDE="$_history_uid"
  export MDM_SEARCH_UID_OVERRIDE="$_history_uid"
  export MDM_DSCL_GENERATED_UID_OVERRIDE="$_history_guid"
  export MDM_SEARCH_GENERATED_UID_OVERRIDE="$_history_guid"
  _MDM_EXPECTED_OUTPUT="$_history_rendered"
  _history_rc=0
  _history_file="$_history_support/managed-history-${_history_guid}.json"
  _history_seed="$_history_support/history-seed"
  jq -n --arg home "$_history_home" --arg guid "$_history_guid" \
    --arg user "$_history_user" \
    --argjson uid "$_history_uid" \
    '{schema_version:2,target_user:$user,target_uid:$uid,
      target_generated_uid:$guid,home:$home,
      managed_inventory:["CLAUDE.md","settings.json"]}' > "$_history_seed"
  chmod 600 "$_history_seed"
  ln "$_history_seed" "$_history_file"
  _history_before_meta="$(_mdm_stat_managed_metadata "$_history_file")"
  _history_before_rest="${_history_before_meta#*:}"
  _history_before_links="${_history_before_rest%%:*}"
  _history_before_mode="$(_mdm_mode_normalize "${_history_before_rest#*:}" 2>/dev/null || true)"
  printf '{"files":["commands/forged.md"]}\n' \
    > "$_history_home/.claude/.starter-kit-manifest.json"
  _mdm_test_chown_target "$_history_home"
  printf '{"result":"failure"}\n' \
    > "$_history_support/receipt-${_history_user}.json"
  _mdm_capture_prior_inventory "$_history_user" "$_history_home" \
    "$_history_uid" "$_history_guid" \
    || _history_rc=$?
  if [[ "$_history_rc" -eq 0 && "$_history_before_links" == 2 \
    && "$_history_before_mode" == 0600 ]] \
    && jq -e '.managed_inventory == ["CLAUDE.md","settings.json"]' \
      "$_history_file" >/dev/null \
    && grep -qx CLAUDE.md "$_MDM_PRIOR_INVENTORY" \
    && grep -qx settings.json "$_MDM_PRIOR_INVENTORY" \
    && ! grep -q retired "$_history_file"; then
    pass "mdm-install: schema 2 GUID-key history は mode 600 hardlink source から capture"
  else
    fail "mdm-install: schema 2 GUID-key history の hardlink capture 契約が不正"
  fi
  _mdm_persist_managed_history "$_history_user" "$_history_home" \
    "$_history_uid" "$_history_guid" \
    || _history_rc=$?
  _history_after_meta="$(_mdm_stat_managed_metadata "$_history_file" 2>/dev/null || true)"
  _history_after_rest="${_history_after_meta#*:}"
  _history_after_links="${_history_after_rest%%:*}"
  _history_after_mode="$(_mdm_mode_normalize "${_history_after_rest#*:}" 2>/dev/null || true)"
  if [[ "$_history_rc" -eq 0 && "$_history_after_links" == 1 \
    && "$_history_after_mode" == 0600 ]] \
    && jq -e --arg guid "$_history_guid" --arg home "$_history_home" \
      --argjson uid "$_history_uid" \
      '.schema_version == 2 and .target_uid == $uid
       and .target_generated_uid == $guid and .home == $home
       and .managed_inventory == ["CLAUDE.md","settings.json"]' \
      "$_history_file" >/dev/null \
    && ! grep -q retired "$_history_file"; then
    pass "mdm-install: history persist は schema 2・mode 600・fresh inode nlink 1 へ収束"
  else
    fail "mdm-install: history persist の schema/mode/nlink 契約が不正"
  fi
  _mdm_cleanup_prior_inventory || true
  rm -rf "$_history_tmp"
)

# A fixed root-owned lock serializes the entire mutating run.  A contender
# fails without touching compliance, and the retained lock path is reusable.
if [[ -x /usr/bin/lockf ]]; then
  (
    _lock_tmp="$(mktemp -d)"; _lock_support="$_lock_tmp/support"
    mkdir -p "$_lock_support"; chmod 755 "$_lock_support"
    printf 'sentinel\n' > "$_lock_support/receipt-jane.json"
    export MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_lock_support"
    export MDM_CONFIG_SKIP_OWNER_CHECK=1
    (
      _MDM_RUN_LOCK_FILE=""; _MDM_RUN_LOCK_BASE=""
      _mdm_acquire_run_lock jane "$_lock_tmp/home" || exit 1
      : > "$_lock_tmp/ready"
      _lock_wait=0
      while [[ ! -e "$_lock_tmp/release" && "$_lock_wait" -lt 500 ]]; do
        /bin/sleep 0.01; _lock_wait=$((_lock_wait + 1))
      done
      _mdm_release_run_lock
    ) &
    _lock_holder=$!
    _lock_wait=0
    while [[ ! -e "$_lock_tmp/ready" && "$_lock_wait" -lt 500 ]]; do
      /bin/sleep 0.01; _lock_wait=$((_lock_wait + 1))
    done
    _MDM_RUN_LOCK_FILE=""; _MDM_RUN_LOCK_BASE=""
    _lock_contender_rc=0
    _mdm_acquire_run_lock jane "$_lock_tmp/home" >/dev/null 2>&1 \
      || _lock_contender_rc=$?
    : > "$_lock_tmp/release"; wait "$_lock_holder"
    _lock_reuse_rc=0
    _mdm_acquire_run_lock jane "$_lock_tmp/home" || _lock_reuse_rc=$?
    _mdm_release_run_lock || _lock_reuse_rc=$?
    if [[ "$_lock_contender_rc" -ne 0 && "$_lock_reuse_rc" -eq 0 \
      && "$(cat "$_lock_support/receipt-jane.json")" == sentinel ]]; then
      pass "mdm-install: per-user lock は競合を拒否し receipt 不変で再利用可能"
    else
      fail "mdm-install: per-user remediation lock の排他/再利用契約が不正"
    fi
    rm -rf "$_lock_tmp"
  )
else
  skip "mdm-install: per-user remediation lock" "/usr/bin/lockf unavailable"
fi

# Atomic directory publication must classify the namespace after a helper
# reports failure: rename may already have happened before fsync/postcheck.
(
  _atomic_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _atomic_uid="$(/usr/bin/id -u)"
  mkdir "$_atomic_tmp/source"
  _atomic_parent_id="$(_mdm_persistent_dir_identity "$_atomic_tmp")"
  _atomic_source_id="$(_mdm_persistent_dir_identity "$_atomic_tmp/source")"
  _atomic_publish=true
  _mdm_run_maybe_as_user() {
    while [[ "$#" -gt 8 ]]; do shift; done
    if [[ "$_atomic_publish" == true ]]; then
      /bin/mv "$1/$2" "$1/$3" || return 98
    fi
    return 97
  }
  _atomic_rc=0
  _mdm_atomic_user_dir_operation "$_atomic_tmp" source destination create \
    "$_atomic_uid" "$_atomic_parent_id" "$_atomic_source_id" absent \
    || _atomic_rc=$?
  if [[ "$_atomic_rc" -eq 0 \
    && "$(_mdm_user_dir_operation_outcome "$_atomic_tmp" source destination \
      create "$_atomic_uid" "$_atomic_parent_id" "$_atomic_source_id" absent)" \
      == published \
    && "$(_mdm_persistent_dir_identity "$_atomic_tmp/destination")" \
      == "$_atomic_source_id" ]]; then
    pass "mdm-install: atomic helper 非0でも published inode layout を採用"
  else
    fail "mdm-install: rename 後 helper failure を未公開と誤判定"
  fi

  mkdir "$_atomic_tmp/source-unchanged"
  _atomic_unchanged_id="$(_mdm_persistent_dir_identity \
    "$_atomic_tmp/source-unchanged")"
  _atomic_publish=false
  _atomic_rc=0
  _mdm_atomic_user_dir_operation "$_atomic_tmp" source-unchanged destination-unchanged \
    create "$_atomic_uid" "$_atomic_parent_id" "$_atomic_unchanged_id" absent \
    || _atomic_rc=$?
  if [[ "$_atomic_rc" -ne 0 \
    && "$(_mdm_user_dir_operation_outcome "$_atomic_tmp" source-unchanged \
      destination-unchanged create "$_atomic_uid" "$_atomic_parent_id" \
      "$_atomic_unchanged_id" absent)" == unchanged ]]; then
    pass "mdm-install: atomic helper 非0の unchanged layout は公開扱いしない"
  else
    fail "mdm-install: atomic helper unchanged/published 分類が不正"
  fi
  rm -rf "$_atomic_tmp"
)

# Allocation ownership is registered before the first identity lookup so
# faults and signals cannot strand an untracked Claude candidate/stage.
(
  _allocation_window_fixture() { # <root> <claude|persistent> <FAULT|HUP|INT|TERM>
    local _root="$1" _mode="$2" _signal="$3"
    PROJECT_DIR="$PROJECT_DIR" MDM_ALLOCATION_ROOT="$_root" \
      MDM_ALLOCATION_MODE="$_mode" MDM_ALLOCATION_SIGNAL="$_signal" \
      MDM_ALLOCATION_USER="$_MDM_TEST_TARGET_USER" \
      MDM_ALLOCATION_UID="$_MDM_TEST_TARGET_UID" \
      MDM_ALLOCATION_GID="$_MDM_TEST_TARGET_GID" \
      MDM_ALLOCATION_GUID=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE \
      "$BASH" --noprofile --norc -c '
        MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"
        _root="$MDM_ALLOCATION_ROOT"
        _home="$_root/home"
        _receipts="$_root/receipts"
        _user="$MDM_ALLOCATION_USER"
        _uid="$MDM_ALLOCATION_UID"
        _gid="$MDM_ALLOCATION_GID"
        /bin/chmod 0755 "$_root" || exit 90
        /bin/mkdir -m 700 "$_home"
        if [[ "$(/usr/bin/id -u)" -eq 0 ]]; then
          chown "$_uid:$_gid" "$_home" || exit 90
        fi
        export MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_receipts"
        export MDM_CONFIG_SKIP_OWNER_CHECK=1
        _mdm_exec_as_user() {
          local _drop_uid="$1" _drop_user="$2" _drop_home="$3"
          shift 3
          if [[ "$(/usr/bin/id -u)" -eq 0 ]]; then
            /usr/bin/sudo -n -u "#$_drop_uid" -H /usr/bin/env -i \
              "HOME=$_drop_home" "USER=$_drop_user" "LOGNAME=$_drop_user" \
              PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C "$@"
          else
            "$@"
          fi
        }
        _MDM_GIT_DROP_UID="$_uid"
        _MDM_GIT_DROP_USER="$_user"
        _MDM_GIT_DROP_HOME="$_home"
        _MDM_TRANSACTION_STATE=idle
        _MDM_CLAUDE_TRANSACTION_STATE=idle
        _MDM_PERSISTENT_TRANSACTION_STATE=idle
        _mdm_transaction_begin "$_user" "$_home" "$_uid" \
          "$MDM_ALLOCATION_GUID" || exit 91
        _allocation_home_identity="$(_mdm_persistent_dir_identity "$_home")" \
          || exit 92
        _mdm_persistent_dir_identity() {
          case "$1" in
            "$_home") printf "%s" "$_allocation_home_identity" ;;
            "$_home"/.claude.mdm-backup.*|\
            "$_home"/.claude-starter-kit.mdm-stage.*)
              if [[ "$MDM_ALLOCATION_SIGNAL" == FAULT ]]; then
                return 1
              fi
              /bin/kill "-$MDM_ALLOCATION_SIGNAL" "$$"
              return 1 ;;
            *) return 1 ;;
          esac
        }
        _allocation_rc=0
        if [[ "$MDM_ALLOCATION_MODE" == claude ]]; then
          _mdm_transaction_prepare_claude "$_home" "$_uid" \
            || _allocation_rc=$?
        else
          _mdm_rebuild_persistent_checkout \
            "$_home/.claude-starter-kit" fixture.invalid \
            abcdef0123456789abcdef0123456789abcdef01 "$_uid" \
            || _allocation_rc=$?
        fi
        [[ "$MDM_ALLOCATION_SIGNAL" == FAULT ]] || exit 98
        [[ "$_allocation_rc" -ne 0 ]] || exit 93
        _mdm_transaction_abort || exit 94
        if [[ "$MDM_ALLOCATION_MODE" == claude ]]; then
          ! /usr/bin/find "$_home" -maxdepth 1 \
            -name ".claude.mdm-backup.*" -print -quit \
            | /usr/bin/grep -q . || exit 95
        else
          ! /usr/bin/find "$_home" -maxdepth 1 \
            -name ".claude-starter-kit.mdm-stage.*" -print -quit \
            | /usr/bin/grep -q . || exit 96
        fi
        [[ "$_MDM_TRANSACTION_STATE" == aborted ]] || exit 97
      '
  }

  _allocation_root="$(_mdm_test_target_tmpdir)"
  _allocation_ok=true
  for _allocation_mode in claude persistent; do
    for _allocation_signal in FAULT HUP INT TERM; do
      case "$_allocation_signal" in
        FAULT) _allocation_expected=0 ;;
        HUP) _allocation_expected=129 ;;
        INT) _allocation_expected=130 ;;
        TERM) _allocation_expected=143 ;;
      esac
      _allocation_case="$_allocation_root/${_allocation_mode}-${_allocation_signal}"
      /bin/mkdir "$_allocation_case"
      _allocation_case_rc=0
      _allocation_window_fixture "$_allocation_case" "$_allocation_mode" \
        "$_allocation_signal" >/dev/null 2>&1 \
        || _allocation_case_rc=$?
      if [[ "$_allocation_case_rc" -ne "$_allocation_expected" ]]; then
        _allocation_ok=false
      fi
      if [[ "$_allocation_mode" == claude ]]; then
        if /usr/bin/find "$_allocation_case/home" -maxdepth 1 \
          -name '.claude.mdm-backup.*' -print -quit \
          | /usr/bin/grep -q .; then
          _allocation_ok=false
        fi
      elif /usr/bin/find "$_allocation_case/home" -maxdepth 1 \
        -name '.claude-starter-kit.mdm-stage.*' -print -quit \
        | /usr/bin/grep -q .; then
        _allocation_ok=false
      fi
    done
  done
  [[ "$_allocation_ok" == true ]] \
    && pass "mdm-install: Claude/persistent allocation identity窓はfault・HUP/INT/TERMでorphanなし" \
    || fail "mdm-install: allocation→identity ownership handoff に orphan window"
  /bin/rm -rf "$_allocation_root"
)

# Candidate copy は marker 作成・swap より前に source/candidate/source の
# semantic digest を一致させる。欠落と source drift は旧 inode を公開中の
# まま fail-closed にし、途中 candidate は failed generation へ隔離する。
(
  _copy_transaction_fault=""
  _copy_transaction_source=""
  _copy_transaction_candidate=""
  _mdm_run_maybe_as_user() {
    local _source _candidate
    if [[ "$1" == /bin/cp && "${2:-}" == -a ]]; then
      "$@" || return 1
      _source="$3"
      _source="${_source%/.}"
      _candidate="${4%/}"
      _copy_transaction_source="$_source"
      _copy_transaction_candidate="$_candidate"
      case "$_copy_transaction_fault" in
        omit)
          /bin/rm -f "$_candidate/nested/user-file" ;;
        source-drift)
          printf 'source-drift\n' > "$_source/nested/user-file" ;;
      esac
      return 0
    fi
    "$@"
  }

  _copy_transaction_case() { # <omit|source-drift>
    local _fault="$1" _root _home _uid _old_identity _rc=0
    _root="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
    _home="$_root/home"
    _uid="$(/usr/bin/id -u)"
    /bin/mkdir -m 700 "$_home" "$_home/.claude" \
      "$_home/.claude/nested"
    printf 'user-content\n' > "$_home/.claude/nested/user-file"
    printf 'other-content\n' > "$_home/.claude/nested/other-file"
    /bin/chmod 700 "$_home/.claude" "$_home/.claude/nested"
    /bin/chmod 600 "$_home/.claude/nested/user-file" \
      "$_home/.claude/nested/other-file"
    /bin/ln -s nested/user-file "$_home/.claude/user-link"
    _old_identity="$(_mdm_persistent_dir_identity "$_home/.claude")" \
      || return 1
    _copy_transaction_fault="$_fault"
    _copy_transaction_source=""
    _copy_transaction_candidate=""
    _MDM_TRANSACTION_STATE=active
    _MDM_TRANSACTION_HOME="$_home"
    _MDM_TRANSACTION_UID="$_uid"
    _MDM_CLAUDE_TRANSACTION_STATE=idle
    _MDM_CLAUDE_LIVE=""
    _MDM_CLAUDE_BACKUP=""
    _MDM_CLAUDE_FAILED=""
    _mdm_transaction_prepare_claude "$_home" "$_uid" \
      >/dev/null 2>&1 || _rc=$?
    trap - EXIT HUP INT TERM
    if [[ "$_rc" -ne 0 \
      && "$_MDM_CLAUDE_TRANSACTION_STATE" == aborted \
      && "$(_mdm_persistent_dir_identity "$_home/.claude")" \
        == "$_old_identity" \
      && ! -e "$_home/.claude/.claude-starter-kit-mdm-transaction" \
      && ! -e "$_MDM_CLAUDE_BACKUP" && ! -L "$_MDM_CLAUDE_BACKUP" \
      && -d "$_MDM_CLAUDE_FAILED" \
      && -n "$_copy_transaction_source" \
      && -n "$_copy_transaction_candidate" ]]; then
      _MDM_TRANSACTION_STATE=aborted
      /bin/rm -rf "$_root"
      return 0
    fi
    _MDM_TRANSACTION_STATE=aborted
    /bin/rm -rf "$_root"
    return 1
  }

  _copy_transaction_case omit \
    && pass "mdm-install: candidate nested file 欠落は marker/swap 前に拒否" \
    || fail "mdm-install: candidate nested file 欠落を公開または残留"
  _copy_transaction_case source-drift \
    && pass "mdm-install: copy 中の source drift は marker/swap 前に拒否" \
    || fail "mdm-install: copy 中の source drift を公開または残留"
)

# Managed live/snapshot parents are fully inventoried before mutation. Unsafe
# modes are journaled and normalized top-down; rollback restores exact modes
# bottom-up, while commit deliberately keeps the private result.
(
  _parent_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _parent_home="$_parent_tmp/home"
  _parent_auth="$_parent_tmp/auth"
  _parent_expected="$_parent_tmp/expected"
  _parent_uid="$(/usr/bin/id -u)"
  _parent_user="$(/usr/bin/id -un)"
  /bin/mkdir -m 0700 "$_parent_home" "$_parent_auth" "$_parent_expected" \
    "$_parent_home/.claude" \
    "$_parent_home/.claude/.starter-kit-snapshot" \
    "$_parent_home/.claude/rules" \
    "$_parent_home/.claude/.starter-kit-snapshot/rules" \
    "$_parent_home/.claude/commands" \
    "$_parent_home/.claude/.starter-kit-snapshot/commands" \
    "$_parent_home/.claude/user-only"
  printf '%s\n' \
    '{"files":["rules/managed.md"],"absent_files":["commands/old.md"]}' \
    > "$_parent_expected/manifest.json"
  printf 'live\n' > "$_parent_home/.claude/rules/managed.md"
  printf 'snapshot\n' \
    > "$_parent_home/.claude/.starter-kit-snapshot/rules/managed.md"
  /bin/chmod 0755 "$_parent_home/.claude"
  /bin/chmod 0500 "$_parent_home/.claude/rules" \
    "$_parent_home/.claude/user-only"
  /bin/chmod 0777 "$_parent_home/.claude/.starter-kit-snapshot/rules"
  /bin/chmod 0711 "$_parent_home/.claude/commands"
  /bin/chmod 0755 "$_parent_home/.claude/.starter-kit-snapshot/commands"

  _MDM_EXPECTED_OUTPUT="$_parent_expected"
  MDM_AUTH_TMPDIR_OVERRIDE="$_parent_auth"
  MDM_AUTH_OWNER_UID_OVERRIDE="$_parent_uid"
  _MDM_TRANSACTION_STATE=active
  _MDM_TRANSACTION_USER="$_parent_user"
  _MDM_TRANSACTION_HOME="$_parent_home"
  _MDM_TRANSACTION_UID="$_parent_uid"
  _MDM_PARENT_MODE_STATE=idle
  _MDM_PARENT_MODE_JOURNAL=""
  _MDM_PARENT_MODE_JOURNAL_IDENTITY=""
  _parent_prepare_rc=0
  _mdm_managed_parent_modes_prepare \
    "$_parent_user" "$_parent_home" "$_parent_uid" || _parent_prepare_rc=$?
  _parent_journal="$_MDM_PARENT_MODE_JOURNAL"
  _parent_final_ok=0 _parent_unsafe_rejected=0 _parent_missing_rejected=0
  _mdm_managed_parent_modes_final "$_parent_home" "$_parent_uid" \
    || _parent_final_ok=$?
  /bin/chmod 0777 "$_parent_home/.claude/commands"
  _mdm_managed_parent_modes_final "$_parent_home" "$_parent_uid" \
    >/dev/null 2>&1 || _parent_unsafe_rejected=$?
  /bin/chmod 0711 "$_parent_home/.claude/commands"
  /bin/mv "$_parent_home/.claude/rules" \
    "$_parent_home/.claude/rules-held"
  _mdm_managed_parent_modes_final "$_parent_home" "$_parent_uid" \
    >/dev/null 2>&1 || _parent_missing_rejected=$?
  /bin/mv "$_parent_home/.claude/rules-held" \
    "$_parent_home/.claude/rules"
  _parent_restore_rc=0
  _mdm_managed_parent_modes_restore || _parent_restore_rc=$?
  if [[ "$_parent_prepare_rc" -eq 0 && "$_parent_final_ok" -eq 0 \
    && "$_parent_unsafe_rejected" -ne 0 \
    && "$_parent_missing_rejected" -ne 0 && "$_parent_restore_rc" -eq 0 \
    && "$(_mdm_stat_mode "$_parent_home/.claude")" == 755 \
    && "$(_mdm_stat_mode "$_parent_home/.claude/rules")" == 500 \
    && "$(_mdm_stat_mode \
      "$_parent_home/.claude/.starter-kit-snapshot/rules")" == 777 \
    && "$(_mdm_stat_mode "$_parent_home/.claude/commands")" == 711 \
    && "$(_mdm_stat_mode "$_parent_home/.claude/user-only")" == 500 \
    && ! -e "$_parent_journal" && ! -L "$_parent_journal" ]]; then
    pass "mdm-install: managed parentはpreflight/final検証しrollbackでexact mode復元"
  else
    fail "mdm-install: managed parent preflight/final/rollback契約が不正"
  fi

  _parent_commit_prepare=0 _parent_commit_rc=0
  _mdm_managed_parent_modes_prepare \
    "$_parent_user" "$_parent_home" "$_parent_uid" \
    || _parent_commit_prepare=$?
  _parent_commit_journal="$_MDM_PARENT_MODE_JOURNAL"
  _mdm_managed_parent_modes_commit || _parent_commit_rc=$?
  if [[ "$_parent_commit_prepare" -eq 0 && "$_parent_commit_rc" -eq 0 \
    && "$(_mdm_stat_mode "$_parent_home/.claude/rules")" == 700 \
    && "$(_mdm_stat_mode \
      "$_parent_home/.claude/.starter-kit-snapshot/rules")" == 700 \
    && "$(_mdm_stat_mode "$_parent_home/.claude")" == 755 \
    && "$(_mdm_stat_mode "$_parent_home/.claude/user-only")" == 500 \
    && ! -e "$_parent_commit_journal" \
    && "$_MDM_PARENT_MODE_STATE" == idle ]]; then
    pass "mdm-install: managed parent commitは修復済み0700を保持しjournal削除"
  else
    fail "mdm-install: managed parent commit/mode保持契約が不正"
  fi

  /bin/chmod 0500 "$_parent_home/.claude/rules"
  /bin/chmod 0777 "$_parent_home/.claude/.starter-kit-snapshot/rules"
  export MDM_PARENT_MODE_FAULT_AFTER_OVERRIDE=1
  _parent_fault_rc=0
  _mdm_managed_parent_modes_prepare \
    "$_parent_user" "$_parent_home" "$_parent_uid" \
    >/dev/null 2>&1 || _parent_fault_rc=$?
  unset MDM_PARENT_MODE_FAULT_AFTER_OVERRIDE
  _parent_fault_restore_rc=0
  _mdm_managed_parent_modes_restore || _parent_fault_restore_rc=$?
  if [[ "$_parent_fault_rc" -ne 0 && "$_parent_fault_restore_rc" -eq 0 \
    && "$(_mdm_stat_mode "$_parent_home/.claude/rules")" == 500 \
    && "$(_mdm_stat_mode \
      "$_parent_home/.claude/.starter-kit-snapshot/rules")" == 777 \
    && "$_MDM_PARENT_MODE_STATE" == idle ]]; then
    pass "mdm-install: managed parent partial apply faultは全original modeへ回収"
  else
    fail "mdm-install: managed parent partial apply fault rollbackが不正"
  fi

  _parent_best_prepare=0 _parent_best_restore=0 _parent_best_retry=0
  _mdm_managed_parent_modes_prepare \
    "$_parent_user" "$_parent_home" "$_parent_uid" \
    || _parent_best_prepare=$?
  /bin/chmod 0770 "$_parent_home/.claude/rules"
  _mdm_managed_parent_modes_restore >/dev/null 2>&1 \
    || _parent_best_restore=$?
  _parent_other_restored="$(_mdm_stat_mode \
    "$_parent_home/.claude/.starter-kit-snapshot/rules")"
  /bin/chmod 0700 "$_parent_home/.claude/rules"
  _mdm_managed_parent_modes_restore || _parent_best_retry=$?
  if [[ "$_parent_best_prepare" -eq 0 && "$_parent_best_restore" -ne 0 \
    && "$_parent_other_restored" == 777 && "$_parent_best_retry" -eq 0 \
    && "$(_mdm_stat_mode "$_parent_home/.claude/rules")" == 500 ]]; then
    pass "mdm-install: managed parent restoreは不正record後もbottom-up継続し再試行可能"
  else
    fail "mdm-install: managed parent best-effort restore/retry契約が不正"
  fi

  _parent_plan_valid="$_parent_auth/plan-valid"
  _parent_plan_no_lf="$_parent_auth/plan-no-lf"
  _parent_plan_nul="$_parent_auth/plan-nul"
  _parent_plan_tabs="$_parent_auth/plan-tabs"
  printf 'v1\t%s\t%s\nend\t0\n' "$_parent_uid" "$_parent_home" \
    > "$_parent_plan_valid"
  printf 'v1\t%s\t%s\nend\t0' "$_parent_uid" "$_parent_home" \
    > "$_parent_plan_no_lf"
  printf 'v1\t%s\t%s\nend\t0\n\0' "$_parent_uid" "$_parent_home" \
    > "$_parent_plan_nul"
  printf 'v1\t%s\t%s\n%s\t1:1\t0500\t\t1\nend\t1\n' \
    "$_parent_uid" "$_parent_home" "$_parent_home/.claude" \
    > "$_parent_plan_tabs"
  /bin/chmod 0600 "$_parent_plan_valid" "$_parent_plan_no_lf" \
    "$_parent_plan_nul" "$_parent_plan_tabs"
  _parent_valid_bytes=0 _parent_no_lf_rejected=0
  _parent_nul_rejected=0 _parent_tabs_rejected=0 _parent_phase_rejected=0
  _mdm_managed_parent_plan_bytes_valid \
    "$_parent_plan_valid" "$_parent_home" "$_parent_uid" \
    || _parent_valid_bytes=$?
  _mdm_managed_parent_plan_bytes_valid \
    "$_parent_plan_no_lf" "$_parent_home" "$_parent_uid" \
    >/dev/null 2>&1 || _parent_no_lf_rejected=$?
  _mdm_managed_parent_plan_bytes_valid \
    "$_parent_plan_nul" "$_parent_home" "$_parent_uid" \
    >/dev/null 2>&1 || _parent_nul_rejected=$?
  _mdm_managed_parent_plan_bytes_valid \
    "$_parent_plan_tabs" "$_parent_home" "$_parent_uid" \
    >/dev/null 2>&1 || _parent_tabs_rejected=$?
  _mdm_managed_parent_plan_valid \
    "$_parent_plan_valid" "$_parent_home" "$_parent_uid" unknown \
    >/dev/null 2>&1 || _parent_phase_rejected=$?
  if [[ "$_parent_valid_bytes" -eq 0 && "$_parent_no_lf_rejected" -ne 0 \
    && "$_parent_nul_rejected" -ne 0 && "$_parent_tabs_rejected" -ne 0 \
    && "$_parent_phase_rejected" -ne 0 ]]; then
    pass "mdm-install: managed parent journalはNUL/LF/TAB/phaseをbyte厳密検証"
  else
    fail "mdm-install: managed parent journal byte grammarが不正"
  fi

  if [[ "$_parent_uid" -eq 0 ]]; then
    /bin/chmod 0000 "$_parent_home/.claude/rules"
    _parent_zero_prepare=0 _parent_zero_restore=0
    _mdm_managed_parent_modes_prepare \
      "$_parent_user" "$_parent_home" "$_parent_uid" \
      || _parent_zero_prepare=$?
    _parent_zero_applied="$(_mdm_stat_mode "$_parent_home/.claude/rules")"
    _mdm_managed_parent_modes_restore || _parent_zero_restore=$?
    _parent_zero_restored="$(_mdm_stat_mode "$_parent_home/.claude/rules")"
    if [[ "$_parent_zero_prepare" -eq 0 && "$_parent_zero_restore" -eq 0 \
      && "$_parent_zero_applied" == 700 && "$_parent_zero_restored" == 0 ]]; then
      pass "mdm-install: root-private fd mutatorは実mode000 parentを修復・復元"
    else
      fail "mdm-install: 実mode000 parentのroot-private修復が不正"
    fi
    /bin/chmod 0500 "$_parent_home/.claude/rules"
  else
    skip "mdm-install: 実mode000 parent修復" "root実行時のみ"
  fi

  _parent_target_impl="$(declare -f _mdm_managed_parent_target_modes)"
  if [[ "$_parent_target_impl" == *'_mdm_system_python'* \
    && "$_parent_target_impl" != *'_mdm_target_system_python'* \
    && "$_parent_target_impl" == *'os.O_NOFOLLOW'* \
    && "$_parent_target_impl" == *'os.fchmod'* ]]; then
    pass "mdm-install: mode000修復はroot-private Pythonのfd-bound fchmodへ限定"
  else
    fail "mdm-install: mode000 managed parentのroot-private修復契約が不正"
  fi
  /bin/chmod -R u+rwx "$_parent_tmp"
  /bin/rm -rf "$_parent_tmp"
)

# A signal after managed parent modes have been applied runs the same outer
# rollback and removes the root-private journal before returning the launcher
# signal status.
(
  _parent_signal_root="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _parent_signal_ok=true
  for _parent_signal in HUP INT TERM; do
    case "$_parent_signal" in
      HUP) _parent_signal_expected=129 ;;
      INT) _parent_signal_expected=130 ;;
      TERM) _parent_signal_expected=143 ;;
    esac
    _parent_signal_case="$_parent_signal_root/$_parent_signal"
    /bin/mkdir -m 0700 "$_parent_signal_case" \
      "$_parent_signal_case/auth" "$_parent_signal_case/expected" \
      "$_parent_signal_case/home" \
      "$_parent_signal_case/home/.claude" \
      "$_parent_signal_case/home/.claude/rules" \
      "$_parent_signal_case/home/.claude/.starter-kit-snapshot" \
      "$_parent_signal_case/home/.claude/.starter-kit-snapshot/rules"
    printf '%s\n' \
      '{"files":["rules/managed.md"],"absent_files":[]}' \
      > "$_parent_signal_case/expected/manifest.json"
    printf 'live\n' > "$_parent_signal_case/home/.claude/rules/managed.md"
    printf 'snapshot\n' \
      > "$_parent_signal_case/home/.claude/.starter-kit-snapshot/rules/managed.md"
    /bin/chmod 0500 "$_parent_signal_case/home/.claude/rules"
    /bin/chmod 0777 \
      "$_parent_signal_case/home/.claude/.starter-kit-snapshot/rules"
    _parent_signal_rc=0
    MDM_SOURCE_ONLY=1 MDM_SYSTEM_PYTHON_OVERRIDE="$MDM_SYSTEM_PYTHON_OVERRIDE" \
      /bin/bash -c '
        source "$1/mdm/install-mdm.sh"
        _MDM_EXPECTED_OUTPUT="$2/expected"
        MDM_AUTH_TMPDIR_OVERRIDE="$2/auth"
        MDM_AUTH_OWNER_UID_OVERRIDE="$(/usr/bin/id -u)"
        _MDM_TRANSACTION_STATE=active
        _MDM_TRANSACTION_USER="$(/usr/bin/id -un)"
        _MDM_TRANSACTION_HOME="$2/home"
        _MDM_TRANSACTION_UID="$(/usr/bin/id -u)"
        _MDM_TRANSACTION_HISTORY_STATE=untouched
        _MDM_TRANSACTION_COMPONENT_STATE=untouched
        _mdm_transaction_restore_root_file() { return 0; }
        _mdm_transaction_cleanup_root_snapshots() { return 0; }
        _mdm_managed_parent_modes_prepare \
          "$_MDM_TRANSACTION_USER" "$_MDM_TRANSACTION_HOME" \
          "$_MDM_TRANSACTION_UID" >/dev/null 2>&1 || exit 90
        [[ "${_MDM_PARENT_MODE_STATE:-}" == applied \
          && "$(_mdm_stat_mode \
            "$_MDM_TRANSACTION_HOME/.claude/rules")" == 700 \
          && "$(_mdm_stat_mode \
            "$_MDM_TRANSACTION_HOME/.claude/.starter-kit-snapshot/rules")" \
              == 700 ]] || exit 90
        _MDM_FAILURE_ROLLBACK_SOURCE_PATH="$MDM_SYSTEM_PYTHON_OVERRIDE"
        _MDM_FAILURE_ROLLBACK_SOURCE_FRAMEWORK_IDENTITY=source-framework
        _MDM_FAILURE_ROLLBACK_SOURCE_TARGET_IDENTITY=source-target
        _MDM_FAILURE_ROLLBACK_ACTIVE=1
        _MDM_FAILURE_ROLLBACK_FRESH_PRIVATE=0
        _mdm_validate_system_python() {
          printf -v "$1" "%s" "$_MDM_FAILURE_ROLLBACK_SOURCE_PATH"
          printf -v "$2" "%s" \
            "$_MDM_FAILURE_ROLLBACK_SOURCE_FRAMEWORK_IDENTITY"
          printf -v "$3" "%s" \
            "$_MDM_FAILURE_ROLLBACK_SOURCE_TARGET_IDENTITY"
        }
        _mdm_cleanup_system_python_workspace() {
          _mdm_clear_system_python_runtime_state
        }
        _recovery_signal="$3"
        _mdm_initialize_system_python() {
          /bin/kill "-$_recovery_signal" "$$"
          /bin/sleep 2
          return 97
        }
        _mdm_arm_transient_cleanup
        _mdm_system_python_recover_after_rebound_failure
        exit 91
      ' mdm-parent-signal "$PROJECT_DIR" "$_parent_signal_case" \
        "$_parent_signal" > "$_parent_signal_case/out" 2>&1 \
      || _parent_signal_rc=$?
    if [[ "$_parent_signal_rc" -ne "$_parent_signal_expected" \
      || "$(_mdm_stat_mode \
        "$_parent_signal_case/home/.claude/rules")" != 500 \
      || "$(_mdm_stat_mode \
        "$_parent_signal_case/home/.claude/.starter-kit-snapshot/rules")" != 777 ]] \
      || /usr/bin/find "$_parent_signal_case/auth" -maxdepth 1 \
        -name 'claude-kit-mdm-parent-modes.*' -print -quit \
        | /usr/bin/grep -q .; then
      _parent_signal_ok=false
    fi
  done
  [[ "$_parent_signal_ok" == true ]] \
    && pass "mdm-install: fresh recovery中HUP/INT/TERMもsource fallbackでexact復元" \
    || fail "mdm-install: recovery signal時のfallback rollbackが不正"
  /bin/chmod -R u+rwx "$_parent_signal_root"
  /bin/rm -rf "$_parent_signal_root"
)

# The outer installer swaps a copied candidate into ~/.claude and restores the
# exact previous inode on failure, even if setup removes its advisory marker.
(
  _claude_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _claude_home="$_claude_tmp/home"
  _claude_uid="$(/usr/bin/id -u)"
  mkdir -m 700 "$_claude_home" "$_claude_home/.claude"
  printf 'old-state\n' > "$_claude_home/.claude/state"
  printf 'old-backup-marker\n' \
    > "$_claude_home/.claude/.starter-kit-last-backup"
  chmod 600 "$_claude_home/.claude/state" \
    "$_claude_home/.claude/.starter-kit-last-backup"
  _claude_old_id="$(_mdm_persistent_dir_identity "$_claude_home/.claude")"
  _MDM_GIT_DROP_UID=""
  _MDM_TRANSACTION_STATE=active
  _MDM_TRANSACTION_HOME="$_claude_home"
  _MDM_TRANSACTION_UID="$_claude_uid"
  _MDM_CLAUDE_TRANSACTION_STATE=idle
  _claude_prepare_rc=0
  _mdm_transaction_prepare_claude "$_claude_home" "$_claude_uid" \
    || _claude_prepare_rc=$?
  _claude_candidate_id="$_MDM_CLAUDE_CANDIDATE_IDENTITY"
  _claude_backup="$_MDM_CLAUDE_BACKUP"
  _claude_ready_before=0
  _claude_ready_after=0
  _claude_replacement_equivalent=false
  if [[ "$_claude_prepare_rc" -eq 0 ]]; then
    printf '%s\n' "$_claude_backup" \
      > "$_claude_home/.claude/.starter-kit-last-backup"
    chmod 600 "$_claude_home/.claude/.starter-kit-last-backup"
    _claude_persistent="$_claude_home/.claude-starter-kit"
    mkdir "$_claude_persistent"
    printf 'candidate-checkout\n' > "$_claude_persistent/state"
    chmod 600 "$_claude_persistent/state"
    _MDM_PERSISTENT_TRANSACTION_STATE=created
    _MDM_PERSISTENT_INSTALL_DIR="$_claude_persistent"
    _MDM_PERSISTENT_STAGE="$_claude_home/.claude-starter-kit.mdm-stage.ready"
    _MDM_PERSISTENT_TARGET_UID="$_claude_uid"
    _MDM_PERSISTENT_PARENT_IDENTITY="$(_mdm_persistent_dir_identity \
      "$_claude_home")"
    _MDM_PERSISTENT_CANDIDATE_IDENTITY="$(_mdm_persistent_dir_identity \
      "$_claude_persistent")"
    _MDM_PERSISTENT_CANDIDATE_DIGEST="$(_mdm_artifact_digest tree \
      "$_claude_persistent" "$_claude_uid")"
    _MDM_PERSISTENT_PREVIOUS_IDENTITY=""
    _MDM_PERSISTENT_PREVIOUS_DIGEST=""
    _MDM_TRANSACTION_HISTORY_STATE=absent
    _MDM_TRANSACTION_COMPONENT_STATE=absent
    _MDM_PARENT_MODE_STATE=applied
    _MDM_EXTERNAL_TRANSACTION_STATE=none
    _mdm_managed_parent_journal_trusted() { return 0; }
    _mdm_managed_parent_modes_final() { return 0; }
    _mdm_transaction_ready_to_commit || _claude_ready_before=$?
    mv "$_claude_backup" "$_claude_backup.replaced"
    mkdir "$_claude_backup"
    cp -a "$_claude_backup.replaced/." "$_claude_backup/"
    chmod "$(_mdm_stat_mode "$_claude_backup.replaced")" "$_claude_backup"
    if [[ "$(_mdm_persistent_dir_identity "$_claude_backup")" \
        != "$_MDM_CLAUDE_PREVIOUS_IDENTITY" \
      && "$(_mdm_artifact_digest tree "$_claude_backup")" \
        == "$_MDM_CLAUDE_PREVIOUS_DIGEST" ]]; then
      _claude_replacement_equivalent=true
    fi
    _mdm_transaction_ready_to_commit || _claude_ready_after=$?
    rm -rf "$_claude_backup"
    mv "$_claude_backup.replaced" "$_claude_backup"
    rm -f "$_claude_persistent/state"
    rmdir "$_claude_persistent"
    _MDM_PERSISTENT_TRANSACTION_STATE=idle
    _MDM_PERSISTENT_INSTALL_DIR=""
    _MDM_PERSISTENT_STAGE=""
    rm -f "$_claude_home/.claude/.claude-starter-kit-mdm-transaction"
    printf 'new-state\n' > "$_claude_home/.claude/state"
    printf 'candidate-only\n' > "$_claude_home/.claude/new-file"
    chmod 600 "$_claude_home/.claude/state" \
      "$_claude_home/.claude/new-file"
  fi
  _claude_abort_rc=0
  _mdm_transaction_abort_claude || _claude_abort_rc=$?
  if [[ "$_claude_prepare_rc" -eq 0 && "$_claude_abort_rc" -eq 0 \
    && "$_claude_ready_before" -eq 0 && "$_claude_ready_after" -ne 0 \
    && "$_claude_replacement_equivalent" == true \
    && "$(_mdm_persistent_dir_identity "$_claude_home/.claude")" \
      == "$_claude_old_id" \
    && "$(cat "$_claude_home/.claude/state")" == old-state \
    && "$(cat "$_claude_home/.claude/.starter-kit-last-backup")" \
      == old-backup-marker \
    && ! -e "$_claude_backup" && ! -L "$_claude_backup" \
    && -d "$_MDM_CLAUDE_FAILED" \
    && "$(_mdm_persistent_dir_identity "$_MDM_CLAUDE_FAILED")" \
      == "$_claude_candidate_id" \
    && "$(cat "$_MDM_CLAUDE_FAILED/new-file")" == candidate-only \
    && "${_claude_backup#"$_claude_home"/.claude.mdm-backup.}" \
      =~ ^[0-9]{14}(\.[0-9]+)?$ ]]; then
    pass "mdm-install: commit直前は replaced backup を拒否し rollback で旧 inode を復元"
  else
    fail "mdm-install: outer backup 最終再検証または rollback 契約が不正"
  fi

  _claude_home="$_claude_tmp/fresh-home"
  mkdir -m 700 "$_claude_home"
  _MDM_TRANSACTION_STATE=active
  _MDM_TRANSACTION_HOME="$_claude_home"
  _MDM_TRANSACTION_UID="$_claude_uid"
  _MDM_CLAUDE_TRANSACTION_STATE=idle
  _MDM_CLAUDE_LIVE=""; _MDM_CLAUDE_BACKUP=""; _MDM_CLAUDE_FAILED=""
  _claude_prepare_rc=0
  _mdm_transaction_prepare_claude "$_claude_home" "$_claude_uid" \
    || _claude_prepare_rc=$?
  _claude_candidate_id="$_MDM_CLAUDE_CANDIDATE_IDENTITY"
  _claude_collision=""
  if [[ "$_claude_prepare_rc" -eq 0 ]]; then
    rm -f "$_claude_home/.claude/.claude-starter-kit-mdm-transaction"
    printf 'first-attempt\n' > "$_claude_home/.claude/new-file"
    chmod 600 "$_claude_home/.claude/new-file"
    _claude_collision="$(_mdm_transaction_failed_path \
      "$_MDM_CLAUDE_BACKUP" .mdm-backup. .mdm-failed.)"
    mkdir "$_claude_collision"
    printf 'preseeded\n' > "$_claude_collision/sentinel"
  fi
  _claude_abort_rc=0
  _mdm_transaction_abort_claude || _claude_abort_rc=$?
  if [[ "$_claude_prepare_rc" -eq 0 && "$_claude_abort_rc" -eq 0 \
    && ! -e "$_claude_home/.claude" && ! -L "$_claude_home/.claude" \
    && -d "$_MDM_CLAUDE_FAILED" \
    && "$_MDM_CLAUDE_FAILED" == "$_claude_collision.1" \
    && "$(_mdm_persistent_dir_identity "$_MDM_CLAUDE_FAILED")" \
      == "$_claude_candidate_id" \
    && "$(cat "$_MDM_CLAUDE_FAILED/new-file")" == first-attempt \
    && "$(cat "$_claude_collision/sentinel")" == preseeded ]]; then
    pass "mdm-install: initial ~/.claude rollback は failed 衝突を保持し candidate を連番退避"
  else
    fail "mdm-install: initial ~/.claude failed 衝突時の outer rollback 契約が不正"
  fi
  _MDM_TRANSACTION_STATE=aborted
  trap - EXIT
  rm -rf "$_claude_tmp"
)

# Root history/component state joins the same rollback boundary.  A prior file
# is restored byte-for-byte while a file absent at entry is retracted.
(
  _root_tmp="$(_mdm_test_target_tmpdir)"
  _root_support="$_root_tmp/support"
  _root_home="$_root_tmp/home"
  _root_guid=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
  mkdir -m 755 "$_root_support"
  mkdir -m 700 "$_root_home"
  _mdm_test_chown_target "$_root_home"
  printf 'history-before\n' \
    > "$_root_support/managed-history-$_root_guid.json"
  chmod 600 "$_root_support/managed-history-$_root_guid.json"
  export MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_root_support"
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  export MDM_EUID_OVERRIDE=0
  _MDM_TEST_MODE=1
  _MDM_TRANSACTION_STATE=idle
  _MDM_CLAUDE_TRANSACTION_STATE=idle
  _MDM_PERSISTENT_TRANSACTION_STATE=idle
  _root_begin_rc=0
  _mdm_transaction_begin "$_MDM_TEST_TARGET_USER" "$_root_home" \
    "$_MDM_TEST_TARGET_UID" "$_root_guid" \
    || _root_begin_rc=$?
  _root_snapshot="$_MDM_TRANSACTION_HISTORY_SNAPSHOT"
  if [[ "$_root_begin_rc" -eq 0 ]]; then
    printf 'history-after\n' \
      > "$_root_support/managed-history-$_root_guid.json"
    printf 'component-after\n' > "$_root_support/components-$_root_guid.json"
    chmod 600 "$_root_support/managed-history-$_root_guid.json" \
      "$_root_support/components-$_root_guid.json"
  fi
  _root_abort_rc=0
  _mdm_transaction_abort || _root_abort_rc=$?
  if [[ "$_root_begin_rc" -eq 0 && "$_root_abort_rc" -eq 0 \
    && "$_MDM_TRANSACTION_STATE" == aborted \
    && "$(cat "$_root_support/managed-history-$_root_guid.json")" \
      == history-before \
    && ! -e "$_root_support/components-$_root_guid.json" \
    && ! -L "$_root_support/components-$_root_guid.json" \
    && -n "$_root_snapshot" && ! -e "$_root_snapshot" \
    && -z "$_MDM_TRANSACTION_HISTORY_SNAPSHOT" \
    && -z "$_MDM_TRANSACTION_COMPONENT_SNAPSHOT" ]]; then
    pass "mdm-install: outer rollback は root history present/component absent を復元"
  else
    fail "mdm-install: root history/component transaction 復元が不正"
  fi
  trap - EXIT
  unset MDM_EUID_OVERRIDE MDM_SYSTEM_RCPT_DIR_OVERRIDE \
    MDM_CONFIG_SKIP_OWNER_CHECK
  rm -rf "$_root_tmp"
)

# Root snapshot copy runs in a registered process group.  Repeated catchable
# termination signals must stop/wait it before cleanup, with an immediate
# successful retry and no child or snapshot residue after every attempt.
(
  _snapshot_signal_fixture() { # <root> <HUP|INT|TERM>
    local _root="$1" _signal="$2"
    PROJECT_DIR="$PROJECT_DIR" MDM_SNAPSHOT_ROOT="$_root" \
      MDM_SNAPSHOT_SIGNAL="$_signal" \
      MDM_SNAPSHOT_USER="$_MDM_TEST_TARGET_USER" \
      MDM_SNAPSHOT_UID="$_MDM_TEST_TARGET_UID" \
      MDM_SNAPSHOT_GID="$_MDM_TEST_TARGET_GID" \
      MDM_SNAPSHOT_GUID=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE \
      "$BASH" --noprofile --norc -c '
        MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"
        _root="$MDM_SNAPSHOT_ROOT"
        _home="$_root/home"
        _receipts="$_root/receipts"
        _user="$MDM_SNAPSHOT_USER"
        _uid="$MDM_SNAPSHOT_UID"
        _gid="$MDM_SNAPSHOT_GID"
        _guid="$MDM_SNAPSHOT_GUID"
        /bin/chmod 0755 "$_root" || exit 90
        /bin/mkdir -m 700 "$_home"
        if [[ "$(/usr/bin/id -u)" -eq 0 ]]; then
          chown "$_uid:$_gid" "$_home" || exit 90
        fi
        /bin/mkdir -m 755 "$_receipts"
        printf "history-before\n" \
          > "$_receipts/managed-history-$_guid.json"
        /bin/chmod 600 "$_receipts/managed-history-$_guid.json"
        export MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_receipts"
        export MDM_CONFIG_SKIP_OWNER_CHECK=1 MDM_EUID_OVERRIDE=0
        MDM_SNAPSHOT_PARENT_PID="$$"
        _mdm_stat_fd_identity() {
          printf "%s\n" "$_MDM_ACTIVE_BOUND_SNAPSHOT_PATH" \
            > "$_root/snapshot-path"
          /bin/sh -c '"'"'printf "%s\n" "$PPID"'"'"' \
            > "$_root/copy-pid"
          /bin/ps -p "$(cat "$_root/copy-pid")" -o pgid= \
            | /usr/bin/tr -d "[:space:]" > "$_root/copy-pgid"
          : > "$_root/ready"
          trap "" HUP INT TERM
          /bin/kill "-$MDM_SNAPSHOT_SIGNAL" "$MDM_SNAPSHOT_PARENT_PID"
          /bin/sleep 2
          printf "late\n" > "$_root/late-marker"
          return 1
        }
        _MDM_TRANSACTION_STATE=idle
        _MDM_CLAUDE_TRANSACTION_STATE=idle
        _MDM_PERSISTENT_TRANSACTION_STATE=idle
        _mdm_transaction_begin "$_user" "$_home" "$_uid" "$_guid"
      '
  }

  _snapshot_presignal_fixture() { # <root> <HUP|INT|TERM>
    local _root="$1" _signal="$2"
    PROJECT_DIR="$PROJECT_DIR" MDM_SNAPSHOT_ROOT="$_root" \
      MDM_SNAPSHOT_SIGNAL="$_signal" \
      MDM_SNAPSHOT_USER="$_MDM_TEST_TARGET_USER" \
      MDM_SNAPSHOT_UID="$_MDM_TEST_TARGET_UID" \
      MDM_SNAPSHOT_GID="$_MDM_TEST_TARGET_GID" \
      MDM_SNAPSHOT_GUID=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE \
      "$BASH" --noprofile --norc -c '
        MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"
        _root="$MDM_SNAPSHOT_ROOT"
        _home="$_root/home"
        _receipts="$_root/receipts"
        _user="$MDM_SNAPSHOT_USER"
        _uid="$MDM_SNAPSHOT_UID"
        _gid="$MDM_SNAPSHOT_GID"
        _guid="$MDM_SNAPSHOT_GUID"
        /bin/chmod 0755 "$_root" || exit 90
        /bin/mkdir -m 700 "$_home"
        if [[ "$(/usr/bin/id -u)" -eq 0 ]]; then
          chown "$_uid:$_gid" "$_home" || exit 90
        fi
        /bin/mkdir -m 755 "$_receipts"
        printf "history-before\n" \
          > "$_receipts/managed-history-$_guid.json"
        /bin/chmod 600 "$_receipts/managed-history-$_guid.json"
        export MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_receipts"
        export MDM_CONFIG_SKIP_OWNER_CHECK=1 MDM_EUID_OVERRIDE=0
        _MDM_SNAPSHOT_PRESIGNAL_INJECTED=0
        _mdm_arm_transient_signal_cleanup() {
          if [[ "${_MDM_BOUND_SNAPSHOT_SUPERVISOR_STARTING:-0}" == 1 \
            && -n "${_MDM_ACTIVE_BOUND_SNAPSHOT_PATH:-}" \
            && "$_MDM_SNAPSHOT_PRESIGNAL_INJECTED" == 0 ]]; then
            _MDM_SNAPSHOT_PRESIGNAL_INJECTED=1
            printf "%s\n" "$_MDM_ACTIVE_BOUND_SNAPSHOT_PATH" \
              > "$_root/snapshot-path"
            /bin/kill "-$MDM_SNAPSHOT_SIGNAL" "$$"
          fi
          trap '"'"'_mdm_cleanup_transient_checkouts HUP; exit 129'"'"' HUP
          trap '"'"'_mdm_cleanup_transient_checkouts INT; exit 130'"'"' INT
          trap '"'"'_mdm_cleanup_transient_checkouts TERM; exit 143'"'"' TERM
        }
        _mdm_snapshot_copy_bound() {
          : > "$_root/child-started"
          return 1
        }
        _MDM_TRANSACTION_STATE=idle
        _MDM_CLAUDE_TRANSACTION_STATE=idle
        _MDM_PERSISTENT_TRANSACTION_STATE=idle
        _mdm_transaction_begin "$_user" "$_home" "$_uid" "$_guid"
        : > "$_root/survived"
      '
  }

  _snapshot_presignal_root="$(_mdm_test_target_tmpdir)"
  _snapshot_presignal_ok=true
  for _snapshot_attempt in 1 2 3; do
    for _snapshot_signal in HUP INT TERM; do
      case "$_snapshot_signal" in
        HUP) _snapshot_expected=129 ;;
        INT) _snapshot_expected=130 ;;
        TERM) _snapshot_expected=143 ;;
      esac
      _snapshot_case="$_snapshot_presignal_root/${_snapshot_signal}-${_snapshot_attempt}"
      /bin/mkdir "$_snapshot_case"
      _snapshot_rc=0
      _snapshot_presignal_fixture "$_snapshot_case" "$_snapshot_signal" \
        > "$_snapshot_case/out" 2>&1 || _snapshot_rc=$?
      _snapshot_path="$(cat "$_snapshot_case/snapshot-path" 2>/dev/null || true)"
      if [[ "$_snapshot_rc" -ne "$_snapshot_expected" \
        || -z "$_snapshot_path" \
        || -e "$_snapshot_path" || -L "$_snapshot_path" \
        || -e "$_snapshot_path.done" || -L "$_snapshot_path.done" \
        || -e "$_snapshot_case/child-started" \
        || -e "$_snapshot_case/survived" \
        || "$(cat "$_snapshot_case/receipts/managed-history-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.json")" \
          != history-before \
        || -e "$_snapshot_case/receipts/components-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.json" \
        || -L "$_snapshot_case/receipts/components-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.json" ]] \
        || LC_ALL=C /usr/bin/grep -Eq 'Terminated|Killed' \
          "$_snapshot_case/out"; then
        _snapshot_presignal_ok=false
      fi
    done
  done
  if [[ "$_snapshot_presignal_ok" == true ]]; then
    pass "mdm-install: root snapshot spawn前 HUP/INT/TERM は保留後に回収し129/130/143"
  else
    fail "mdm-install: root snapshot spawn前 signal が破棄または残留"
  fi
  /bin/rm -rf "$_snapshot_presignal_root"

  _snapshot_signal_root="$(_mdm_test_target_tmpdir)"
  _snapshot_signal_ok=true
  for _snapshot_attempt in 1 2 3; do
    for _snapshot_signal in HUP INT TERM; do
      case "$_snapshot_signal" in
        HUP) _snapshot_expected=129 ;;
        INT) _snapshot_expected=130 ;;
        TERM) _snapshot_expected=143 ;;
      esac
      _snapshot_case="$_snapshot_signal_root/${_snapshot_signal}-${_snapshot_attempt}"
      /bin/mkdir "$_snapshot_case"
      _snapshot_rc=0
      _snapshot_signal_fixture "$_snapshot_case" "$_snapshot_signal" \
        > "$_snapshot_case/out" 2>&1 || _snapshot_rc=$?
      if LC_ALL=C /usr/bin/grep -Eq 'Terminated|Killed' \
        "$_snapshot_case/out"; then
        _snapshot_signal_ok=false
      fi
      /bin/sleep 0.2
      _snapshot_path="$(cat "$_snapshot_case/snapshot-path" 2>/dev/null || true)"
      _snapshot_copy_pid="$(cat "$_snapshot_case/copy-pid" 2>/dev/null || true)"
      _snapshot_copy_pgid="$(cat "$_snapshot_case/copy-pgid" 2>/dev/null || true)"
      if [[ "$_snapshot_rc" -ne "$_snapshot_expected" \
        || -z "$_snapshot_path" \
        || -e "$_snapshot_path" || -L "$_snapshot_path" \
        || -e "$_snapshot_path.done" || -L "$_snapshot_path.done" \
        || -e "$_snapshot_case/late-marker" \
        || "$(cat "$_snapshot_case/receipts/managed-history-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.json")" \
          != history-before \
        || -e "$_snapshot_case/receipts/components-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.json" \
        || -L "$_snapshot_case/receipts/components-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.json" ]] \
        || { [[ "$_snapshot_copy_pid" =~ ^[1-9][0-9]*$ ]] \
          && /bin/kill -0 "$_snapshot_copy_pid" 2>/dev/null; } \
        || { [[ "$_snapshot_copy_pgid" =~ ^[1-9][0-9]*$ ]] \
          && _mdm_timeout_group_live "$_snapshot_copy_pgid"; }; then
        _snapshot_signal_ok=false
      fi

      printf 'retry-%s-%s\n' "$_snapshot_signal" "$_snapshot_attempt" \
        > "$_snapshot_case/retry-source"
      chmod 600 "$_snapshot_case/retry-source"
      : > "$_snapshot_case/retry-snapshot"
      _snapshot_retry_rc=0
      _mdm_snapshot_bound_to "$_snapshot_case/retry-source" \
        "$_snapshot_case/retry-snapshot" history \
        2> "$_snapshot_case/retry-stderr" || _snapshot_retry_rc=$?
      if [[ "$_snapshot_retry_rc" -ne 0 \
        || "$(cat "$_snapshot_case/retry-snapshot")" \
          != "retry-${_snapshot_signal}-${_snapshot_attempt}" \
        || -n "${_MDM_ACTIVE_BOUND_SNAPSHOT_SUPERVISOR_PID:-}" \
        || -n "${_MDM_ACTIVE_BOUND_SNAPSHOT_PATH:-}" ]] \
        || LC_ALL=C /usr/bin/grep -Eq 'Terminated|Killed' \
          "$_snapshot_case/retry-stderr"; then
        _snapshot_signal_ok=false
      fi
    done
  done
  trap - EXIT HUP INT TERM
  if [[ "$_snapshot_signal_ok" == true \
    && -z "${_MDM_ACTIVE_BOUND_SNAPSHOT_SUPERVISOR_PID:-}" \
    && -z "${_MDM_ACTIVE_BOUND_SNAPSHOT_PATH:-}" ]]; then
    pass "mdm-install: root snapshot HUP/INT/TERM 反復はPG停止・回収後に即時再試行可能"
  else
    fail "mdm-install: root snapshot signal cleanup に child/path/done residue"
  fi
  /bin/rm -rf "$_snapshot_signal_root"
)

# A persistent checkout already exchanged into place remains reversible until
# the success receipt commits.  Rollback restores the old inode and preserves
# the rejected candidate under the recovery namespace.
(
  _persistent_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _persistent_install="$_persistent_tmp/.claude-starter-kit"
  _persistent_stage="$_persistent_tmp/.claude-starter-kit.mdm-stage.outer"
  _persistent_uid="$(/usr/bin/id -u)"
  mkdir "$_persistent_install" "$_persistent_stage"
  printf 'candidate\n' > "$_persistent_install/state"
  printf 'previous\n' > "$_persistent_stage/state"
  chmod 600 "$_persistent_install/state" "$_persistent_stage/state"
  _persistent_candidate_id="$(_mdm_persistent_dir_identity \
    "$_persistent_install")"
  _persistent_previous_id="$(_mdm_persistent_dir_identity \
    "$_persistent_stage")"
  _persistent_candidate_digest="$(_mdm_artifact_digest tree \
    "$_persistent_install" "$_persistent_uid")"
  _persistent_previous_digest="$(_mdm_artifact_digest tree \
    "$_persistent_stage" "$_persistent_uid")"
  _MDM_GIT_DROP_UID=""
  _MDM_PERSISTENT_TRANSACTION_STATE=swapped
  _MDM_PERSISTENT_INSTALL_DIR="$_persistent_install"
  _MDM_PERSISTENT_STAGE="$_persistent_stage"
  _MDM_PERSISTENT_STAGE_IDENTITY="$_persistent_previous_id"
  _MDM_PERSISTENT_TARGET_UID="$_persistent_uid"
  _MDM_PERSISTENT_PARENT_IDENTITY="$(_mdm_persistent_dir_identity \
    "$_persistent_tmp")"
  _MDM_PERSISTENT_CANDIDATE_IDENTITY="$_persistent_candidate_id"
  _MDM_PERSISTENT_CANDIDATE_DIGEST="$_persistent_candidate_digest"
  _MDM_PERSISTENT_PREVIOUS_IDENTITY="$_persistent_previous_id"
  _MDM_PERSISTENT_PREVIOUS_DIGEST="$_persistent_previous_digest"
  _persistent_collision="$_persistent_tmp/.claude-starter-kit.mdm-failed.outer"
  mkdir "$_persistent_collision"
  printf 'preseeded\n' > "$_persistent_collision/sentinel"
  _persistent_abort_rc=0
  _mdm_transaction_abort_persistent || _persistent_abort_rc=$?
  if [[ "$_persistent_abort_rc" -eq 0 \
    && "$_MDM_PERSISTENT_TRANSACTION_STATE" == aborted \
    && "$(_mdm_persistent_dir_identity "$_persistent_install")" \
      == "$_persistent_previous_id" \
    && "$(cat "$_persistent_install/state")" == previous \
    && -d "$_persistent_collision" \
    && "$(cat "$_persistent_collision/sentinel")" == preseeded \
    && -d "$_persistent_collision.1" \
    && "$(_mdm_persistent_dir_identity \
      "$_persistent_collision.1")" \
      == "$_persistent_candidate_id" \
    && "$(cat \
      "$_persistent_collision.1/state")" \
      == candidate \
    && ! -e "$_persistent_stage" && ! -L "$_persistent_stage" ]]; then
    pass "mdm-install: persistent rollback は failed 衝突を保持し candidate を連番退避"
  else
    fail "mdm-install: persistent failed 衝突時の outer rollback 契約が不正"
  fi
  rm -rf "$_persistent_tmp"
)

# Receipt publication commits both retained-stage cleanup and Claude recovery
# rotation.  Cleanup failure after this point must never re-arm rollback.
(
  _commit_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _commit_home="$_commit_tmp/home"
  _commit_live="$_commit_home/.claude"
  _commit_current="$_commit_home/.claude.mdm-backup.20000101000002"
  _commit_old="$_commit_home/.claude.mdm-backup.20000101000001"
  _commit_manual="$_commit_home/.claude.mdm-backup.manual"
  _commit_stage="$_commit_home/.claude-starter-kit.mdm-stage.commit"
  mkdir -m 700 "$_commit_home" "$_commit_live" "$_commit_current" \
    "$_commit_old" "$_commit_manual" "$_commit_stage"
  printf 'live\n' > "$_commit_live/state"
  printf 'marker\n' \
    > "$_commit_live/.claude-starter-kit-mdm-transaction"
  printf 'current\n' > "$_commit_current/state"
  printf 'old\n' > "$_commit_old/state"
  printf 'manual\n' > "$_commit_manual/state"
  printf 'old-checkout\n' > "$_commit_stage/state"
  chmod 600 "$_commit_live/state" \
    "$_commit_live/.claude-starter-kit-mdm-transaction" \
    "$_commit_current/state" "$_commit_old/state" \
    "$_commit_manual/state" "$_commit_stage/state"
  _MDM_GIT_DROP_UID=""
  _MDM_TRANSACTION_STATE=active
  _MDM_TRANSACTION_HOME="$_commit_home"
  _MDM_EXTERNAL_TRANSACTION_STATE=none
  _MDM_CLAUDE_TRANSACTION_STATE=swapped
  _MDM_CLAUDE_LIVE="$_commit_live"
  _MDM_CLAUDE_BACKUP="$_commit_current"
  _MDM_PERSISTENT_TRANSACTION_STATE=swapped
  _MDM_PERSISTENT_STAGE="$_commit_stage"
  _MDM_PERSISTENT_STAGE_IDENTITY="$(_mdm_persistent_dir_identity \
    "$_commit_stage")"
  _MDM_TRANSACTION_HISTORY_SNAPSHOT=""
  _MDM_TRANSACTION_COMPONENT_SNAPSHOT=""
  _commit_rc=0
  _mdm_transaction_commit || _commit_rc=$?
  if [[ "$_commit_rc" -eq 0 && "$_MDM_TRANSACTION_STATE" == committed \
    && "$_MDM_CLAUDE_TRANSACTION_STATE" == committed \
    && "$_MDM_PERSISTENT_TRANSACTION_STATE" == committed \
    && ! -e "$_commit_stage" && ! -L "$_commit_stage" \
    && ! -e "$_commit_live/.claude-starter-kit-mdm-transaction" \
    && -d "$_commit_current" && "$(cat "$_commit_current/state")" == current \
    && ! -e "$_commit_old" && ! -L "$_commit_old" \
    && -d "$_commit_manual" && "$(cat "$_commit_manual/state")" == manual \
    && "$(cat "$_commit_live/state")" == live ]]; then
    pass "mdm-install: success commit は stage cleanup と bounded backup rotation"
  else
    fail "mdm-install: success receipt 後 commit cleanup/rotation が不正"
  fi
  trap - EXIT
  rm -rf "$_commit_tmp"
)

_mdm_test_stop_tmp_root_mode_guard || exit 2
mdm_test_reached_end
