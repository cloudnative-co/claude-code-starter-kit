#!/bin/bash -p
# mdm/install-mdm.sh — macOS 向け MDM サイレントインストーラ

# Bash reads BASH_ENV and imported functions before the first script line.  A
# root MDM launcher therefore starts in privileged mode from the shebang,
# discards the inherited environment, then starts a clean privileged Bash with
# every startup-file path disabled.  There is deliberately no argv/env bypass
# token: every directly executed invocation crosses this boundary.  Callers
# that explicitly wrap the script must use the clean invocation documented in
# docs/mdm/README.md.
_MDM_LAUNCHER_SOURCE_CONTEXT=0
[[ "${BASH_SOURCE[0]:-}" != "${0:-}" ]] \
  && _MDM_LAUNCHER_SOURCE_CONTEXT=1
readonly _MDM_LAUNCHER_SOURCE_CONTEXT

_mdm_launcher_mode_safe() {
  local _mode="$1"
  [[ "$_mode" =~ ^[0-7]+$ ]] || return 1
  while [[ ${#_mode} -gt 3 ]]; do _mode="${_mode#?}"; done
  while [[ ${#_mode} -lt 3 ]]; do _mode="0$_mode"; done
  case "$_mode" in *[2367]|?[2367]?) return 1 ;; esac
  return 0
}

_mdm_launcher_stat_uid() {
  if [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]]; then
    /usr/bin/stat -f '%u' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%u' "$1" 2>/dev/null
  fi
}

_mdm_launcher_stat_mode() {
  if [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]]; then
    # %Lp omits special bits on macOS; %Mp%Lp preserves sticky (1777).
    /usr/bin/stat -f '%Mp%Lp' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%a' "$1" 2>/dev/null
  fi
}

_mdm_launcher_acl_safe() {
  local _path="$1" _listing _first _perms
  [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]] || return 0
  _listing="$(LC_ALL=C /bin/ls -lde "$_path" 2>/dev/null)" || return 1
  _first="${_listing%%$'\n'*}"
  _perms="${_first%%[[:space:]]*}"
  [[ "$_first" == *[[:space:]]* \
    && "$_perms" =~ ^[-bcdlps][rwxStTs-]{9}[@+]?$ ]] || return 1
  [[ "$_perms" != *+* && "$_listing" != *$'\n'* ]]
}

_mdm_launcher_tmp_base_trusted() { # <fixed-temporary-base>
  local _base="$1" _physical _path _owner _mode
  case "$_base" in /private/tmp|/tmp) ;; *) return 1 ;; esac
  [[ -d "$_base" && ! -L "$_base" ]] || return 1
  _physical="$(builtin cd -P -- "$_base" 2>/dev/null && printf '%s' "$PWD")" \
    || return 1
  [[ "$_physical" == "$_base" ]] || return 1

  _path="$_physical"
  while :; do
    [[ -d "$_path" && ! -L "$_path" ]] || return 1
    _owner="$(_mdm_launcher_stat_uid "$_path" || true)"
    _mode="$(_mdm_launcher_stat_mode "$_path" || true)"
    [[ "$_owner" == 0 ]] || return 1
    if [[ "$_path" == "$_physical" ]]; then
      [[ "$_mode" == 1777 ]] || return 1
    else
      _mdm_launcher_mode_safe "$_mode" || return 1
    fi
    _mdm_launcher_acl_safe "$_path" || return 1
    [[ "$_path" == / ]] && break
    _path="${_path%/*}"
    [[ -n "$_path" ]] || _path=/
  done
  return 0
}

_mdm_launcher_path_trusted() {
  local _script="$1" _dir _base _canonical _path _owner _mode
  [[ -f "$_script" && ! -L "$_script" ]] || return 1
  case "$_script" in
    */*) _dir="${_script%/*}"; _base="${_script##*/}" ;;
    *) _dir=.; _base="$_script" ;;
  esac
  [[ -n "$_dir" ]] || _dir=/
  _canonical="$(builtin cd -P -- "$_dir" 2>/dev/null && printf '%s' "$PWD")" || return 1
  [[ "$_canonical" == / ]] && _canonical=""
  _canonical="$_canonical/$_base"
  [[ -f "$_canonical" && ! -L "$_canonical" ]] || return 1

  _path="$_canonical"
  while :; do
    [[ ! -L "$_path" ]] || return 1
    _owner="$(_mdm_launcher_stat_uid "$_path" || true)"
    _mode="$(_mdm_launcher_stat_mode "$_path" || true)"
    [[ "$_owner" == 0 ]] || return 1
    if ! _mdm_launcher_mode_safe "$_mode"; then
      # A root-owned sticky directory protects root-owned entries from rename
      # by other users and is the only writable parent shape accepted here.
      [[ -d "$_path" && "$_mode" == 1777 ]] || return 1
    fi
    _mdm_launcher_acl_safe "$_path" || return 1
    [[ "$_path" == / ]] && break
    _path="${_path%/*}"; [[ -n "$_path" ]] || _path=/
  done
  _MDM_LAUNCHER_PHYSICAL="$_canonical"
  return 0
}

_mdm_launcher_snapshot() { # <source> <output-variable>
  local _source="$1" _output="$2" _before _opened _tmp_base _allocation_base
  local _old_umask
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
    # $$ is not changed by Bash command-substitution subshells, so a
    # /proc/$$/fd lookup would inspect the parent shell instead of the shell
    # running stat.  /dev/fd/9 names the inherited descriptor directly.
    _opened="$(/usr/bin/stat -Lc '%i:%s' /dev/fd/9 2>/dev/null)" \
      || { exec 9<&-; return 1; }
    _tmp_base=/tmp
  fi
  [[ "$_before" == "$_opened" ]] || { exec 9<&-; return 1; }
  _mdm_launcher_tmp_base_trusted "$_tmp_base" \
    || { exec 9<&-; return 1; }
  _allocation_base="$_tmp_base"
  if [[ "$_MDM_LAUNCHER_SOURCE_CONTEXT" == 1 \
    && "${_MDM_TEST_MODE:-0}" == 1 \
    && "${MDM_TEST_TMP_ROOT:-}" == /* && -d "$MDM_TEST_TMP_ROOT" \
    && ! -L "$MDM_TEST_TMP_ROOT" \
    && "$(cd -P "$MDM_TEST_TMP_ROOT" && /bin/pwd -P)" \
      == "$MDM_TEST_TMP_ROOT" ]]; then
    _allocation_base="$MDM_TEST_TMP_ROOT"
  fi
  _old_umask="$(umask)"; umask 077
  _mdm_launcher_inflight="$(
    /usr/bin/mktemp "$_allocation_base/claude-kit-mdm-launcher.XXXXXX"
  )" \
    || { umask "$_old_umask"; exec 9<&-; return 1; }
  umask "$_old_umask"
  # Publish the pathname to the already-trapped caller before copying bytes.
  # Bash dynamic scope also exposes the inflight value to the cleanup helper
  # during the few builtins between mktemp and this assignment.
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

_mdm_launcher_cleanup_snapshots() {
  local _path
  for _path in "${_mdm_launcher_inflight:-}" \
    "${_mdm_clean_script_snapshot:-}" \
    "${_mdm_clean_renderer_snapshot:-}"; do
    [[ -z "$_path" ]] || /bin/rm -f "$_path"
  done
}

_MDM_LAUNCHER_SIGNAL_WAIT_ITERATIONS=1000
_MDM_LAUNCHER_GROUP_WAIT_ITERATIONS=100

_mdm_launcher_wait_child_bounded() { # <child-pid> [iterations]
  local _pid="$1" _attempt=0 _stat _limit
  _limit="${2:-${_MDM_LAUNCHER_SIGNAL_WAIT_ITERATIONS:-1000}}"
  [[ "$_limit" =~ ^[1-9][0-9]*$ && "$_limit" -le 1000 ]] || _limit=1000
  while [[ "$_attempt" -lt "$_limit" ]]; do
    _stat="$(LC_ALL=C /bin/ps -p "$_pid" -o stat= 2>/dev/null || true)"
    _stat="${_stat//[[:space:]]/}"
    case "$_stat" in
      Z*) wait "$_pid" 2>/dev/null || true; return 0 ;;
      "")
        if ! /bin/kill -0 "$_pid" 2>/dev/null; then
          wait "$_pid" 2>/dev/null || true
          return 0
        fi
        ;;
    esac
    /bin/sleep 0.01
    _attempt=$((_attempt + 1))
  done
  return 1
}

_mdm_launcher_job_running() { # <child-pid>
  local _pid="$1" _job
  for _job in $(jobs -r -p 2>/dev/null); do
    [[ "$_job" != "$_pid" ]] || return 0
  done
  return 1
}

_mdm_launcher_job_active() { # <child-pid>; running or stopped, never completed
  local _pid="$1" _job
  _mdm_launcher_job_running "$_pid" && return 0
  for _job in $(jobs -s -p 2>/dev/null); do
    [[ "$_job" != "$_pid" ]] || return 0
  done
  return 1
}

_mdm_launcher_group_state() { # <process-group-id>; 0=live, 1=gone/zombie, 2=unknown
  local _pgid="$1" _listing _platform
  _platform="$(/usr/bin/uname -s 2>/dev/null || true)"
  if [[ "$_platform" == Darwin ]]; then
    if ! _listing="$(LC_ALL=C /bin/ps -o stat= -g "$_pgid" 2>/dev/null)"; then
      /bin/kill -0 -- "-$_pgid" 2>/dev/null && return 2
      return 1
    fi
  else
    if ! _listing="$(
      LC_ALL=C /bin/ps -o stat= --pgroup "$_pgid" 2>/dev/null
    )"; then
      /bin/kill -0 -- "-$_pgid" 2>/dev/null && return 2
      return 1
    fi
  fi
  if printf '%s\n' "$_listing" \
    | /usr/bin/awk '$1 != "" && $1 !~ /^Z/ { found=1 }
      END { exit found ? 0 : 1 }'; then
    return 0
  fi
  return 1
}

_mdm_launcher_wait_group_bounded() { # <process-group-id>
  local _pgid="$1" _attempt=0 _state _limit
  _limit="${_MDM_LAUNCHER_GROUP_WAIT_ITERATIONS:-100}"
  [[ "$_limit" =~ ^[1-9][0-9]*$ && "$_limit" -le 1000 ]] || _limit=100
  while [[ "$_attempt" -lt "$_limit" ]]; do
    _state=0
    _mdm_launcher_group_state "$_pgid" || _state=$?
    [[ "$_state" -ne 1 ]] || return 0
    /bin/sleep 0.01
    _attempt=$((_attempt + 1))
  done
  return 1
}

_mdm_launcher_group_quiesced() { # <process-group-id>
  local _pgid="$1" _listing
  _listing="$(LC_ALL=C /bin/ps -axo pgid=,stat= 2>/dev/null)" || return 2
  printf '%s\n' "$_listing" | /usr/bin/awk -v pgid="$_pgid" '
    $1 == pgid && $2 !~ /^[TtZ]/ { running=1 }
    END { exit running ? 1 : 0 }
  '
}

_mdm_launcher_stop_group() { # <process-group-id>
  local _pgid="$1" _attempt=0 _state=0
  [[ "$_pgid" =~ ^[1-9][0-9]*$ ]] || return 2
  # GNU kill requires -- before a negative process-group target.
  if /bin/kill -0 -- "-$_pgid" 2>/dev/null; then
    /bin/kill -STOP -- "-$_pgid" 2>/dev/null || true
    while ! _mdm_launcher_group_quiesced "$_pgid" \
      && [[ "$_attempt" -lt "$_MDM_LAUNCHER_GROUP_WAIT_ITERATIONS" ]]; do
      /bin/sleep 0.01
      _attempt=$((_attempt + 1))
    done
    /bin/kill -KILL -- "-$_pgid" 2>/dev/null || true
    if ! _mdm_launcher_wait_group_bounded "$_pgid"; then
      /bin/kill -KILL -- "-$_pgid" 2>/dev/null || true
      _mdm_launcher_wait_group_bounded "$_pgid" && return 0
      _mdm_launcher_group_state "$_pgid" || _state=$?
      [[ "$_state" -ne 1 ]] || return 0
      [[ "$_state" -ne 2 ]] || return 2
      return 1
    fi
  fi
  return 0
}

_mdm_launcher_exit_on_signal() {
  trap '' HUP INT TERM
  local _signal="$1" _rc="$2" _pid _pgid _identity _actual_ppid
  local _actual_pgid _stop_rc=0
  # The supervisor is exiting because of the caller's signal; suppress its
  # own job-control notices while the child group is reaped.
  exec 2>/dev/null
  _pid="${_mdm_clean_child_pid:-}"
  _pgid="${_mdm_clean_child_pgid:-}"
  if [[ "${_mdm_clean_child_starting:-0}" == 1 ]]; then
    if [[ ! "$_pid" =~ ^[1-9][0-9]*$ ]]; then
      _pid="$(jobs -p 2>/dev/null)"
      _pgid="$_pid"
    elif [[ ! "$_pgid" =~ ^[1-9][0-9]*$ ]]; then
      _pgid="$_pid"
    fi
  fi
  if [[ "$_pid" =~ ^[1-9][0-9]*$ ]] \
    && ! _mdm_launcher_job_active "$_pid"; then
    _pid=""
    _pgid=""
  fi
  if [[ "$_pid" =~ ^[1-9][0-9]*$ ]]; then
    # Deliver only the caller's signal to the leader.  Sending it to a group
    # whose leader is Bash can make Bash print a job notice before its cleanup
    # trap runs.  The bounded wait preserves cooperative cleanup without
    # allowing a non-cooperative child to hold the MDM launcher indefinitely.
    _identity="$(
      LC_ALL=C /bin/ps -p "$_pid" -o ppid= -o pgid= 2>/dev/null \
        | /usr/bin/awk 'NF >= 2 { print $1 ":" $2; exit }'
    )"
    _actual_ppid="${_identity%%:*}"
    _actual_pgid="${_identity#*:}"
    if [[ "$_actual_ppid" == "${_mdm_clean_supervisor_pid:-}" ]]; then
      [[ "$_actual_pgid" == "$_pgid" ]] || _pgid=""
      builtin kill "-$_signal" "$_pid" 2>/dev/null || true
      builtin kill -CONT "$_pid" 2>/dev/null || true
    else
      _pid=""
      _pgid=""
    fi
    if ! _mdm_launcher_wait_child_bounded "$_pid"; then
      if [[ "$_pgid" =~ ^[1-9][0-9]*$ && "$_pgid" == "$_pid" ]]; then
        _mdm_launcher_stop_group "$_pgid" || _stop_rc=$?
      else
        /bin/kill -STOP "$_pid" 2>/dev/null || true
        /bin/kill -KILL "$_pid" 2>/dev/null || true
      fi
      _mdm_launcher_wait_child_bounded \
        "$_pid" "$_MDM_LAUNCHER_GROUP_WAIT_ITERATIONS" || true
    fi
    if [[ "$_pgid" =~ ^[1-9][0-9]*$ && "$_pgid" == "$_pid" ]]; then
      # Once the leader is reaped, no Bash remains to emit a job notice.
      # Quiesce and remove any descendant left in the dedicated group.
      _mdm_launcher_stop_group "$_pgid" || _stop_rc=$?
    fi
  fi
  if [[ "$_stop_rc" -ne 0 && "$_pgid" =~ ^[1-9][0-9]*$ \
    && "$_pgid" == "$_pid" ]]; then
    /bin/kill -KILL -- "-$_pgid" 2>/dev/null || true
  fi
  _mdm_launcher_cleanup_snapshots
  exit "$_rc"
}

_mdm_launcher_arm_cleanup_traps() {
  trap '_mdm_launcher_cleanup_snapshots' EXIT
  trap '_mdm_launcher_exit_on_signal HUP 129' HUP
  trap '_mdm_launcher_exit_on_signal INT 130' INT
  trap '_mdm_launcher_exit_on_signal TERM 143' TERM
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  _mdm_clean_home="/var/root"
  _mdm_clean_script_source="$0"
  _mdm_clean_renderer_source=""
  _mdm_clean_script_snapshot=""
  _mdm_clean_renderer_snapshot=""
  _mdm_clean_child_pid=""
  _mdm_clean_child_pgid=""
  _mdm_clean_child_starting=0
  _mdm_launcher_arm_cleanup_traps
  if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
    _mdm_clean_home="${HOME:-/tmp}"
  else
    if ! _mdm_launcher_path_trusted "$_mdm_clean_script_source"; then
      printf 'MDM launcher path is not trusted\n' >&2
      exit 50
    fi
    _mdm_clean_script_source="$_MDM_LAUNCHER_PHYSICAL"
    _mdm_clean_renderer_source="${_mdm_clean_script_source%/*}/render-expected.py"
    if ! _mdm_launcher_path_trusted "$_mdm_clean_renderer_source"; then
      printf 'MDM expected-state renderer path is not trusted\n' >&2
      exit 50
    fi
    _mdm_clean_renderer_source="$_MDM_LAUNCHER_PHYSICAL"
    if ! _mdm_launcher_snapshot \
      "$_mdm_clean_renderer_source" _mdm_clean_renderer_snapshot; then
      printf 'MDM expected-state renderer snapshot failed\n' >&2
      exit 50
    fi
  fi
  if ! _mdm_launcher_snapshot \
    "$_mdm_clean_script_source" _mdm_clean_script_snapshot; then
    _mdm_launcher_cleanup_snapshots
    printf 'MDM launcher snapshot failed\n' >&2
    exit 50
  fi
  # Keep this trapped supervisor alive until the clean shell exits.  Monitor
  # mode gives the asynchronous child its own process group and restores
  # catchable INT semantics.  An outer signal is delivered exactly to the
  # leader; after bounded cleanup grace, survivors are stopped and reaped.
  _mdm_clean_monitor_was_on=false
  _mdm_clean_supervisor_pid="$$"
  case $- in *m*) _mdm_clean_monitor_was_on=true ;; esac
  if ! set -m; then
    _mdm_launcher_cleanup_snapshots
    printf 'MDM launcher could not enable child process groups\n' >&2
    exit 50
  fi
  _mdm_clean_child_starting=1
  /usr/bin/env -i \
    "HOME=$_mdm_clean_home" \
    'PATH=/usr/bin:/bin:/usr/sbin:/sbin' \
    'LC_ALL=C' \
    /bin/bash --noprofile --norc -p -c '
      _mdm_script=$1
      _mdm_renderer=$2
      shift 2
      trap '\''/bin/rm -f "$_mdm_script"; [[ -z "$_mdm_renderer" ]] || /bin/rm -f "$_mdm_renderer"'\'' EXIT
      trap '\''/bin/rm -f "$_mdm_script"; [[ -z "$_mdm_renderer" ]] || /bin/rm -f "$_mdm_renderer"; exit 129'\'' HUP
      trap '\''/bin/rm -f "$_mdm_script"; [[ -z "$_mdm_renderer" ]] || /bin/rm -f "$_mdm_renderer"; exit 130'\'' INT
      trap '\''/bin/rm -f "$_mdm_script"; [[ -z "$_mdm_renderer" ]] || /bin/rm -f "$_mdm_renderer"; exit 143'\'' TERM
      . "$_mdm_script"
      /bin/rm -f "$_mdm_script"
      _MDM_EXPECTED_RENDERER="$_mdm_renderer"
      [[ -z "$_mdm_renderer" ]] || _MDM_EXPECTED_RENDERER_SNAPSHOT=1
      trap '\''[[ -z "${_MDM_EXPECTED_RENDERER:-}" ]] || /bin/rm -f "$_MDM_EXPECTED_RENDERER"'\'' EXIT
      trap '\''[[ -z "${_MDM_EXPECTED_RENDERER:-}" ]] || /bin/rm -f "$_MDM_EXPECTED_RENDERER"; exit 129'\'' HUP
      trap '\''[[ -z "${_MDM_EXPECTED_RENDERER:-}" ]] || /bin/rm -f "$_MDM_EXPECTED_RENDERER"; exit 130'\'' INT
      trap '\''[[ -z "${_MDM_EXPECTED_RENDERER:-}" ]] || /bin/rm -f "$_MDM_EXPECTED_RENDERER"; exit 143'\'' TERM
      mdm_main "$@"
    ' mdm-install-clean "$_mdm_clean_script_snapshot" \
      "$_mdm_clean_renderer_snapshot" "$@" &
  _mdm_clean_child_pid=$! \
    _mdm_clean_child_pgid=$! \
    _mdm_clean_child_starting=1
  [[ "$_mdm_clean_monitor_was_on" == true ]] || set +m
  _mdm_clean_child_identity="$(
    LC_ALL=C /bin/ps -p "$_mdm_clean_child_pid" -o ppid= -o pgid= \
      2>/dev/null \
      | /usr/bin/awk 'NF >= 2 { print $1 ":" $2; exit }'
  )"
  _mdm_clean_actual_ppid="${_mdm_clean_child_identity%%:*}"
  _mdm_clean_actual_pgid="${_mdm_clean_child_identity#*:}"
  if ! _mdm_launcher_job_active "$_mdm_clean_child_pid"; then
    _mdm_clean_completed_pid="$_mdm_clean_child_pid"
    _mdm_clean_child_pid="" \
      _mdm_clean_child_pgid="" \
      _mdm_clean_child_starting=0
    _mdm_clean_rc=0
    wait "$_mdm_clean_completed_pid" || _mdm_clean_rc=$?
    _mdm_launcher_cleanup_snapshots
    trap - EXIT HUP INT TERM
    exit "$_mdm_clean_rc"
  fi
  if [[ "$_mdm_clean_actual_ppid" != "$_mdm_clean_supervisor_pid" ]]; then
    _mdm_clean_child_pid="" \
      _mdm_clean_child_pgid="" \
      _mdm_clean_child_starting=0
    _mdm_launcher_cleanup_snapshots
    printf 'MDM launcher child parent verification failed\n' >&2
    exit 50
  fi
  if [[ "$_mdm_clean_actual_pgid" != "$_mdm_clean_child_pid" ]]; then
    /bin/kill -TERM "$_mdm_clean_child_pid" 2>/dev/null || true
    if ! _mdm_launcher_wait_child_bounded \
      "$_mdm_clean_child_pid" "$_MDM_LAUNCHER_GROUP_WAIT_ITERATIONS"; then
      /bin/kill -STOP "$_mdm_clean_child_pid" 2>/dev/null || true
      /bin/kill -KILL "$_mdm_clean_child_pid" 2>/dev/null || true
      _mdm_launcher_wait_child_bounded \
        "$_mdm_clean_child_pid" "$_MDM_LAUNCHER_GROUP_WAIT_ITERATIONS" \
        || true
    fi
    _mdm_launcher_cleanup_snapshots
    printf 'MDM launcher child process group verification failed\n' >&2
    exit 50
  fi
  _mdm_clean_child_starting=0
  _mdm_clean_rc=0
  wait "$_mdm_clean_child_pid" || _mdm_clean_rc=$?
  _mdm_clean_child_pid="" \
    _mdm_clean_child_pgid="" \
    _mdm_clean_child_starting=0
  _mdm_launcher_cleanup_snapshots
  trap - EXIT HUP INT TERM
  exit "$_mdm_clean_rc"
fi
set -euo pipefail
_MDM_TEST_MODE="${MDM_SOURCE_ONLY:-0}"
# Preserve whether this file was sourced explicitly for tests.  Individual
# production-path tests temporarily set _MDM_TEST_MODE=0 so they can exercise
# the real validation/copy/seal path without making the test runner's
# containment root available to a directly executed MDM process.
_MDM_SOURCE_TEST_ACTIVE="${MDM_SOURCE_ONLY:-0}"
_MDM_EXPECTED_RENDERER="${_MDM_EXPECTED_RENDERER:-}"
_MDM_EXPECTED_RENDERER_SNAPSHOT="${_MDM_EXPECTED_RENDERER_SNAPSHOT:-0}"
_MDM_EXPECTED_RENDERER_OWNER_UID="${_MDM_EXPECTED_RENDERER_OWNER_UID:-}"
# MDM agent の umask（000 のことがある）を継承しない（契約: dir 755 /
# file 644。レシート/ログが group/other 書込可で生成されると detect の
# compliant 偽装に直結する。R2-High）。setup.sh は自身で umask 077 を設定する。
umask 022

# ── 終了コード定数（固定契約）────────────────────────────
# 後続タスク(mdm_main / 各フェーズ、Task 4-9 で本ファイルに追加)で参照される契約定数。
# NOTE: ';' 区切り複数代入の2つ目以降には disable ディレクティブが効かないため1行1個に分割。
# shellcheck disable=SC2034
MDM_EXIT_OK=0
# shellcheck disable=SC2034
MDM_EXIT_PREREQ=10
# shellcheck disable=SC2034
MDM_EXIT_BREW=11
# shellcheck disable=SC2034
MDM_EXIT_USER=20
# shellcheck disable=SC2034
MDM_EXIT_CONTEXT=21
# shellcheck disable=SC2034
MDM_EXIT_SETUP=30
# shellcheck disable=SC2034
MDM_EXIT_CLI=40
# shellcheck disable=SC2034
MDM_EXIT_CONFIG=50
# shellcheck disable=SC2034
MDM_EXIT_OS=60

# Root-side external operations use fixed production deadlines.  An
# untrusted MDM environment cannot lengthen or disable these values.  A
# source-only test may set MDM_TIMEOUT_OVERRIDE_SECONDS to a smaller positive
# value so process-group and rollback behavior can be exercised quickly.
_MDM_TIMEOUT_QUERY_SECONDS=120
_MDM_TIMEOUT_GIT_SECONDS=300
_MDM_TIMEOUT_PACKAGE_SECONDS=600
_MDM_TIMEOUT_PKGUTIL_SECONDS=60
_MDM_TIMEOUT_WCE_NPM_SECONDS=900
_MDM_TIMEOUT_LOCAL_VALIDATION_SECONDS=120
_MDM_TIMEOUT_SETUP_SECONDS=1200
_MDM_TIMEOUT_CLT_INSTALL_SECONDS=1200

# 配布元リポジトリ（install.sh と同一 URL。KIT_MDM_GIT_REF で SHA を固定する
# ため URL 自体は固定でよい）。
# テスト時は MDM_KIT_REPO_URL_OVERRIDE でローカル fixture repo に差し替え可能
# （参照箇所で call-time に解決する — source 時点の環境に縛られない）。
_MDM_KIT_REPO_URL="https://github.com/cloudnative-co/claude-code-starter-kit.git"

# 管理設定ファイルの固定パス。テスト時は MDM_CONFIG_PATH_OVERRIDE。
_mdm_config_path() {
  printf '%s' "${MDM_CONFIG_PATH_OVERRIDE:-/Library/Application Support/ClaudeCodeStarterKit/mdm-config.conf}"
}

# root が使う一時領域を安全に選ぶ（R7-High）。TMPDIR は対象ユーザー所有を
# 指し得て、親の所有者がエントリを rename/置換できるため、root フェーズでは
# 無視する。macOS は sticky・root 管理領域 /private/tmp（/tmp はその
# symlink）、非 macOS の source-only test は /tmp を使う。非 root は
# 従来どおり TMPDIR を尊重する。
_mdm_test_runner_tmp_base() {
  local _base="${MDM_TEST_TMP_ROOT:-}" _physical
  [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && "$_base" == /* && -d "$_base" && ! -L "$_base" ]] || return 1
  _physical="$(builtin cd -P -- "$_base" 2>/dev/null \
    && printf '%s' "$PWD")" || return 1
  [[ "$_physical" == "$_base" ]] || return 1
  printf '%s' "$_base"
}

_mdm_managed_tmp_path_matches() { # <path> <basename-prefix>
  local _path="$1" _prefix="$2" _base="" _parent _physical _name
  [[ -n "$_path" && "$_prefix" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  _parent="${_path%/*}"
  _name="${_path##*/}"
  case "$_name" in "$_prefix".*) : ;; *) return 1 ;; esac
  case "$_parent" in /private/tmp|/tmp) return 0 ;; esac
  _base="$(_mdm_test_runner_tmp_base 2>/dev/null)" || return 1
  case "$_path" in "$_base"/*) : ;; *) return 1 ;; esac
  [[ -d "$_parent" && ! -L "$_parent" ]] || return 1
  _physical="$(builtin cd -P -- "$_parent" 2>/dev/null \
    && printf '%s' "$PWD")" || return 1
  [[ "$_physical" == "$_parent" ]] || return 1
  case "$_parent" in "$_base"|"$_base"/*) return 0 ;; *) return 1 ;; esac
}

_mdm_safe_tmpdir() {
  local _euid _test_base
  _euid="${MDM_EUID_OVERRIDE:-$(id -u)}"
  if [[ "$_euid" -eq 0 ]] \
    && _test_base="$(_mdm_test_runner_tmp_base)"; then
    printf '%s' "$_test_base"
    return 0
  fi
  if [[ "$_euid" -eq 0 ]]; then
    if _mdm_is_darwin; then
      printf '%s' "/private/tmp"
    else
      printf '%s' "/tmp"
    fi
  else
    printf '%s' "${TMPDIR:-/tmp}"
  fi
}

_mdm_timeout_seconds() { # <fixed-seconds>
  local _fixed="$1" _override="${MDM_TIMEOUT_OVERRIDE_SECONDS:-}"
  [[ "$_fixed" =~ ^[1-9][0-9]*$ && "$_fixed" -le 86400 ]] || return 1
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && "$_override" =~ ^[1-9][0-9]*$ \
    && "$_override" -le "$_fixed" ]]; then
    printf '%s' "$_override"
  else
    printf '%s' "$_fixed"
  fi
}

_mdm_timeout_group_live() { # <process-group-id>; zombies do not execute work
  local _pgid="$1" _listing="" _platform
  [[ "$_pgid" =~ ^[1-9][0-9]*$ ]] || return 2
  _platform="$(/usr/bin/uname -s 2>/dev/null || true)"
  if [[ "$_platform" == Darwin ]]; then
    _listing="$(/bin/ps -o stat= -g "$_pgid" 2>/dev/null)" || _listing=""
  else
    _listing="$(/bin/ps -o stat= --pgroup "$_pgid" 2>/dev/null)" || _listing=""
  fi
  if [[ -n "$_listing" ]]; then
    ! printf '%s\n' "$_listing" | /usr/bin/awk '$1 !~ /^Z/ { exit 1 }'
    return
  fi
  # Compatibility fallback for a ps implementation without direct PG lookup.
  _listing="$(/bin/ps -axo pgid=,stat= 2>/dev/null)" || return 2
  printf '%s\n' "$_listing" | /usr/bin/awk -v pgid="$_pgid" '
    $1 == pgid && $2 !~ /^Z/ { live=1 }
    END { exit(live ? 0 : 1) }
  '
}

_mdm_timeout_group_quiesced() { # <process-group-id>; every live member stopped
  local _pgid="$1" _listing=""
  [[ "$_pgid" =~ ^[1-9][0-9]*$ ]] || return 2
  _listing="$(/bin/ps -axo pgid=,stat= 2>/dev/null)" || return 2
  printf '%s\n' "$_listing" | /usr/bin/awk -v pgid="$_pgid" '
    $1 == pgid && $2 !~ /^[TtZ]/ { running=1 }
    END { exit(running ? 1 : 0) }
  '
}

_mdm_timeout_stop_group() { # <process-group-id>
  local _pgid="$1" _ticks=0 _state=0
  [[ "$_pgid" =~ ^[1-9][0-9]*$ ]] || return 1
  _mdm_timeout_group_live "$_pgid" || _state=$?
  if [[ "$_state" -ne 0 ]]; then
    [[ "$_state" -eq 1 ]] && return 0
    return 1
  fi
  # Give the group leader the graceful TERM window first.  Broadcasting TERM
  # to every member lets a TERM-ignoring shell survive a killed child long
  # enough to emit asynchronous "Killed: 9" diagnostics on the caller's
  # stderr.  The bounded KILL below still reaps the complete process group.
  /bin/kill -TERM "$_pgid" 2>/dev/null || true
  while /bin/kill -0 -- "-$_pgid" 2>/dev/null \
    && [[ "$_ticks" -lt 25 ]]; do
    /bin/sleep 0.01
    _ticks=$((_ticks + 1))
  done
  # Freeze survivors before SIGKILL.  Otherwise a TERM-ignoring shell can run
  # after one of its children dies and leak a job-control diagnostic to the
  # caller.  STOP follows the graceful TERM window, so cooperative leaders
  # still receive their normal shutdown opportunity.
  /bin/kill -STOP -- "-$_pgid" 2>/dev/null || true
  _ticks=0
  while ! _mdm_timeout_group_quiesced "$_pgid" \
    && [[ "$_ticks" -lt 25 ]]; do
    /bin/sleep 0.01
    _ticks=$((_ticks + 1))
  done
  /bin/kill -KILL -- "-$_pgid" 2>/dev/null || true
  _ticks=0
  while /bin/kill -0 -- "-$_pgid" 2>/dev/null \
    && [[ "$_ticks" -lt 10 ]]; do
    /bin/sleep 0.01
    _ticks=$((_ticks + 1))
  done
  _mdm_timeout_group_live "$_pgid" || _state=$?
  [[ "$_state" -eq 1 ]]
}

_mdm_timeout_cleanup_control() { # <control-dir> <marker> <wake-fifo>
  local _control="$1" _marker="$2" _wake="$3" _base
  _base="$(_mdm_safe_tmpdir)" || return 1
  case "$_control" in "$_base"/claude-kit-mdm-timeout.*) : ;; *) return 1 ;; esac
  [[ "$_marker" == "$_control/timed-out" \
    && "$_wake" == "$_control/wake" \
    && -d "$_control" && ! -L "$_control" ]] || return 1
  if [[ -e "$_marker" || -L "$_marker" ]]; then
    [[ -f "$_marker" && ! -L "$_marker" ]] || return 1
    /bin/rm -f "$_marker" || return 1
  fi
  if [[ -e "$_wake" || -L "$_wake" ]]; then
    [[ -p "$_wake" && ! -L "$_wake" ]] || return 1
    /bin/rm -f "$_wake" || return 1
  fi
  /bin/rmdir "$_control"
}

# Run an external command or shell function in its own process group.  The
# wrapper is transparent for stdin/stdout/stderr and ordinary status.  At the
# deadline it returns 124 only after TERM, bounded KILL, and group/control
# cleanup have completed.  Clearing inherited traps in the child prevents a
# helper subprocess from running the coordinator's EXIT cleanup.
_MDM_ACTIVE_TIMEOUT_SUPERVISOR_PID=""
_MDM_TIMEOUT_SUPERVISOR_STARTING=0
_MDM_TIMEOUT_SUPERVISOR_PREVIOUS_BG=""

_mdm_timeout_coordinator() { # <seconds> <command-or-function> [args...]
  local _seconds="$1"; shift
  local _base="" _control="" _marker="" _wake="" _old_umask
  local _child="" _watchdog="" _rc=0 _signal_child="" _signal_watchdog=""
  local _child_starting=false _watchdog_starting=false _last_bg=""
  local _monitor_was_on=false _timed_out=false _cleanup_rc=0 _watchdog_rc=0
  _mdm_timeout_capture_last_bg() { # <output-variable>
    local _output="$1" _value="" _nounset_was_on=false
    case $- in *u*) _nounset_was_on=true ;; esac
    set +u
    _value="$!"
    [[ "$_nounset_was_on" == true ]] && set -u
    printf -v "$_output" '%s' "$_value"
  }
  _mdm_timeout_capture_last_bg _last_bg
  _mdm_timeout_abort() {
    local _signal_rc="$1"
    trap - HUP INT TERM
    # Job-control diagnostics are coordinator noise, not command stderr.
    # Ordinary command stderr has already streamed directly before this point.
    exec 2>/dev/null
    _signal_watchdog="$_watchdog"
    if [[ ! "$_signal_watchdog" =~ ^[1-9][0-9]*$ \
      && "$_watchdog_starting" == true ]]; then
      _mdm_timeout_capture_last_bg _signal_watchdog
      [[ "$_signal_watchdog" != "$_last_bg" ]] || _signal_watchdog=""
    fi
    _signal_child="$_child"
    if [[ ! "$_signal_child" =~ ^[1-9][0-9]*$ \
      && "$_child_starting" == true ]]; then
      _mdm_timeout_capture_last_bg _signal_child
      [[ "$_signal_child" != "$_last_bg" ]] || _signal_child=""
    fi
    # Wake the watchdog first, but stop the command group before waiting for
    # it.  Bash 3.2 may keep read -t blocked briefly after TERM.
    if [[ "$_signal_watchdog" =~ ^[1-9][0-9]*$ ]]; then
      /bin/kill -TERM "$_signal_watchdog" 2>/dev/null || true
    fi
    if [[ "$_signal_child" =~ ^[1-9][0-9]*$ ]]; then
      # Freeze the complete group while its leader is still present.  If TERM
      # removes the leader first, a signal-ignoring command-substitution child
      # can keep running during Bash 3.2's deferred wait handling.
      /bin/kill -STOP -- "-$_signal_child" 2>/dev/null || true
      _mdm_timeout_stop_group "$_signal_child" || true
      wait "$_signal_child" 2>/dev/null || true
    fi
    if [[ "$_signal_watchdog" =~ ^[1-9][0-9]*$ ]]; then
      wait "$_signal_watchdog" 2>/dev/null || true
    fi
    if [[ -n "$_control" ]]; then
      [[ -n "$_marker" ]] || _marker="$_control/timed-out"
      [[ -n "$_wake" ]] || _wake="$_control/wake"
      _mdm_timeout_cleanup_control "$_control" "$_marker" "$_wake" || true
    fi
    exit "$_signal_rc"
  }
  trap '_mdm_timeout_abort 129' HUP
  trap '_mdm_timeout_abort 130' INT
  trap '_mdm_timeout_abort 143' TERM
  [[ "$_seconds" =~ ^[1-9][0-9]*$ && "$_seconds" -le 86400 \
    && "$#" -gt 0 ]] || return 1
  _base="$(_mdm_safe_tmpdir)" || return 1
  _old_umask="$(umask)"; umask 077
  _control="$(/usr/bin/mktemp -d \
    "$_base/claude-kit-mdm-timeout.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  _marker="$_control/timed-out"
  _wake="$_control/wake"
  [[ -d "$_control" && ! -L "$_control" ]] \
    || { _mdm_timeout_cleanup_control "$_control" "$_marker" "$_wake" || true; return 1; }
  /bin/chmod 700 "$_control" \
    || { _mdm_timeout_cleanup_control "$_control" "$_marker" "$_wake" || true; return 1; }
  /usr/bin/mkfifo -m 600 "$_wake" \
    || { _mdm_timeout_cleanup_control "$_control" "$_marker" "$_wake" || true; return 1; }

  case $- in *m*) _monitor_was_on=true ;; esac
  set -m \
    || { _mdm_timeout_cleanup_control "$_control" "$_marker" "$_wake" || true; return 1; }
  _child_starting=true
  ( trap - EXIT HUP INT TERM; "$@" ) <&0 &
  _child=$!
  _child_starting=false
  [[ "$_monitor_was_on" == true ]] || set +m || true
  _last_bg="$_child"
  _watchdog_starting=true
  (
    trap - EXIT HUP INT TERM
    # Bash read(1) supplies the clock without an external sleep descendant.
    # Opening the private FIFO read/write keeps it from returning EOF early.
    IFS= read -r -t "$_seconds" <> "$_wake" && exit 0
    [[ -d "$_control" && ! -L "$_control" \
      && ! -e "$_marker" && ! -L "$_marker" ]] || exit 1
    ( set -C; umask 077; : > "$_marker" ) 2>/dev/null || true
    _mdm_timeout_stop_group "$_child" || exit 1
    exit 124
  ) &
  _watchdog=$!
  _watchdog_starting=false

  wait "$_child" 2>/dev/null || _rc=$?
  if [[ ! -e "$_marker" ]]; then
    /bin/kill -TERM "$_watchdog" 2>/dev/null || true
  fi
  wait "$_watchdog" 2>/dev/null || _watchdog_rc=$?
  # The private marker is published before the watchdog starts termination.
  # A shell may report the killed leader before the watchdog's final `exit
  # 124` is observed, so the inode is the authoritative deadline event.
  if [[ -f "$_marker" && ! -L "$_marker" ]]; then
    _timed_out=true
  elif [[ "$_watchdog_rc" -eq 124 ]]; then
    _timed_out=true
  fi
  # A leader may exit after spawning a background descendant.  Preserve the
  # leader status, but never allow that process group to escape the wrapper.
  _mdm_timeout_stop_group "$_child" || _cleanup_rc=$?
  _mdm_timeout_cleanup_control "$_control" "$_marker" "$_wake" || _cleanup_rc=$?
  [[ "$_cleanup_rc" -eq 0 ]] || return 1
  [[ "$_timed_out" == true ]] && return 124
  return "$_rc"
}

_mdm_run_with_timeout() { # <seconds> <command-or-function> [args...]
  local _supervisor="" _rc=0 _previous=""
  _mdm_timeout_capture_parent_bg() {
    local _nounset_was_on=false
    case $- in *u*) _nounset_was_on=true ;; esac
    set +u
    _previous="$!"
    [[ "$_nounset_was_on" == true ]] && set -u
  }
  _mdm_timeout_capture_parent_bg
  _MDM_TIMEOUT_SUPERVISOR_PREVIOUS_BG="$_previous"
  _MDM_TIMEOUT_SUPERVISOR_STARTING=1
  # An explicit self-dup keeps a here-doc/pipe stdin attached; Bash otherwise
  # redirects stdin of an asynchronous command from /dev/null with job control
  # disabled.
  _mdm_timeout_coordinator "$@" <&0 &
  _supervisor=$!
  _MDM_ACTIVE_TIMEOUT_SUPERVISOR_PID="$_supervisor"
  _MDM_TIMEOUT_SUPERVISOR_STARTING=0
  wait "$_supervisor" 2>/dev/null || _rc=$?
  if [[ "$_MDM_ACTIVE_TIMEOUT_SUPERVISOR_PID" == "$_supervisor" ]]; then
    _MDM_ACTIVE_TIMEOUT_SUPERVISOR_PID=""
  fi
  return "$_rc"
}

# ── レシート用グローバル（各フェーズが埋める）──────────────
MDM_RCPT_KIT_VERSION=""; MDM_RCPT_GIT_REF=""; MDM_RCPT_RESOLVED_SHA=""
MDM_RCPT_INSTALL_DIR=""; MDM_RCPT_REQUIRED_COMPONENTS='["kit"]'; MDM_RCPT_PROFILE=""
MDM_RCPT_LANGUAGE=""; MDM_RCPT_MANIFEST_PATH=""; MDM_RCPT_MANIFEST_SHA256=""
MDM_RCPT_DEPLOYMENT_SHA256=""
MDM_RCPT_POLICY_SHA256=""; MDM_RCPT_COMPONENT_MANIFEST_PATH=""
MDM_RCPT_COMPONENT_MANIFEST_SHA256=""
MDM_RCPT_TARGET_UID=0; MDM_RCPT_TARGET_GENERATED_UID=""
MDM_RCPT_TARGET_USER=""; MDM_RCPT_PARTIAL='[]'; MDM_RCPT_TIMESTAMP=""; MDM_RCPT_LOG_PATH=""
_MDM_TARGET_GENERATED_UID=""
_MDM_TARGET_SHELL="/bin/bash"
KIT_MDM_POLICY_SHA256=""

MDM_LOG_FILE="${MDM_LOG_FILE:-}"
# ログは検証済みの保持 fd（fd 7）へ書く（R4-High）。ファイルを一度だけ排他
# 作成して fd 7 に束縛し、以降の追記はパスでなく fd へ行うことで、lstat 後の
# symlink 差し替えや予測パスへの先置きの影響を受けない。MDM_LOG_FD_OPEN=1 の
# ときのみ fd 7 を使う（未確立時＝早期の失敗ログは stderr のみ）。
MDM_LOG_FD_OPEN="${MDM_LOG_FD_OPEN:-0}"

mdm_log() {
  local _phase="$1"; shift
  local _msg="$*"
  local _line="[$_phase] $_msg"
  printf '%s\n' "$_line" >&2
  if [[ "$MDM_LOG_FD_OPEN" == "1" ]]; then
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" "$_line" >&7 2>/dev/null || true
  elif [[ -n "$MDM_LOG_FILE" ]]; then
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" "$_line" >> "$MDM_LOG_FILE" 2>/dev/null || true
  fi
}

# JSON 文字列値のエスケープ。backslash / double-quote に加え、改行・CR・タブは
# \n \r \t へ変換し、残る制御文字（JSON で不正）は除去する（Medium 対応:
# 想定外の値が混じってもレシートが不正 JSON にならない）。
mdm_json_escape() {
  local _s="$1"
  _s="${_s//\\/\\\\}"
  _s="${_s//\"/\\\"}"
  _s="${_s//$'\n'/\\n}"
  _s="${_s//$'\r'/\\r}"
  _s="${_s//$'\t'/\\t}"
  printf '%s' "$_s" | LC_ALL=C tr -d '[:cntrl:]'
}

_mdm_is_darwin() {
  [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == "Darwin" ]]
}

_mdm_macos_version_supported() { # <product-version>
  local _version="$1" _major _minor
  [[ "$_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?$ ]] \
    || return 1
  _major="${BASH_REMATCH[1]}"
  _minor="${BASH_REMATCH[2]}"
  [[ "${#_major}" -le 3 && "${#_minor}" -le 3 ]] || return 1
  (( _major > 13 || (_major == 13 && _minor >= 5) ))
}

_mdm_supported_macos_host() {
  local _version
  _mdm_is_darwin || return 1
  _version="$(/usr/bin/sw_vers -productVersion 2>/dev/null)" || return 1
  _mdm_macos_version_supported "$_version"
}

_mdm_stat_mode() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%Lp' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%a' "$1" 2>/dev/null
  fi
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

_mdm_stat_managed_metadata() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%u:%l:%Mp%Lp' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%u:%h:%a' "$1" 2>/dev/null
  fi
}

_mdm_stat_inode() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%i' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%i' "$1" 2>/dev/null
  fi
}

_mdm_stat_fd_inode() {
  local _fd="$1"
  if _mdm_is_darwin; then
    /usr/bin/stat -Lf '%i' "/dev/fd/$_fd" 2>/dev/null
  else
    # Command substitutions preserve $$ from the parent shell, and access to
    # that process via /proc can be restricted even for the same UID.  The
    # inherited /dev/fd entry binds directly to the descriptor in this child.
    /usr/bin/stat -Lc '%i' "/dev/fd/$_fd" 2>/dev/null
  fi
}

# Command substitution removes every trailing newline, so assigning plain
# `readlink` output can make two different link targets compare equal.  Suppress
# readlink's delimiter with `-n`, keep a non-newline sentinel through command
# substitution, remove only that sentinel, then reject every control character
# in the actual target.
_mdm_readlink_exact() { # <path> <output-var>
  local _path="$1" _out_var="$2" _raw _rc=0
  [[ "$_out_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  _raw="$(
    /usr/bin/readlink -n "$_path" 2>/dev/null || _rc=$?
    printf '\036'
    exit "$_rc"
  )" || return 1
  [[ "$_raw" == *$'\036' ]] || return 1
  _raw="${_raw%$'\036'}"
  [[ -n "$_raw" && ! "$_raw" =~ [[:cntrl:]] ]] || return 1
  printf -v "$_out_var" '%s' "$_raw"
}

_mdm_mode_is_safe() {
  local _mode="$1"
  [[ "$_mode" =~ ^[0-7]+$ ]] || return 1
  while [[ ${#_mode} -gt 3 ]]; do _mode="${_mode#?}"; done
  while [[ ${#_mode} -lt 3 ]]; do _mode="0$_mode"; done
  case "$_mode" in
    *[2367]|?[2367]?) return 1 ;;
  esac
  return 0
}

_mdm_mode_normalize() {
  local _mode="$1"
  [[ "$_mode" =~ ^[0-7]{1,4}$ ]] || return 1
  while [[ ${#_mode} -lt 4 ]]; do _mode="0$_mode"; done
  printf '%s' "$_mode"
}

_mdm_mode_owner_executable() {
  local _mode
  _mode="$(_mdm_mode_normalize "$1")" || return 1
  case "${_mode:1:1}" in 1|3|5|7) return 0 ;; *) return 1 ;; esac
}

# Any macOS ACL is rejected. With xattrs, ls can retain '@' in the permission
# token and emit the ACL only on continuation lines, so the launcher helper
# validates both the token and the complete listing.
_mdm_has_extended_acl() {
  _mdm_is_darwin || return 1
  ! _mdm_launcher_acl_safe "$1"
}

_mdm_sha256_file() {
  local _path="$1"
  if [[ -x /usr/bin/shasum ]]; then
    /usr/bin/shasum -a 256 "$_path" 2>/dev/null | /usr/bin/awk '{print $1}'
  elif [[ -x /usr/bin/sha256sum ]]; then
    /usr/bin/sha256sum "$_path" 2>/dev/null | /usr/bin/awk '{print $1}'
  else
    return 1
  fi
}

# Canonical artifact digest shared with the detector contract. Trees are
# walked through bound descriptors without following symlinks. Entry type,
# path, complete metadata, ACL absence, xattrs, link target, and file bytes are
# covered. Unsafe ownership, writable entries, hard links, and escaping or
# dangling links fail closed. Two complete captures must agree.
_mdm_artifact_digest() { # <file|tree> <absolute-path> [owner-uid-csv] [group-gid-csv] [contract]
  local _kind="$1" _path="$2" _owner_csv="${3:-}" _group_csv="${4:-}"
  local _contract="${5:-artifact}" _python _canonical
  case "$_kind" in file|tree) : ;; *) return 1 ;; esac
  case "$_contract" in
    artifact|copy-semantics|artifact-copy-semantics) : ;;
    *) return 1 ;;
  esac
  [[ "$_path" == /* && ! "$_path" =~ [[:cntrl:]] ]] || return 1
  [[ -z "$_owner_csv" || "$_owner_csv" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
  [[ -z "$_group_csv" || "$_group_csv" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
  [[ ! -L "$_path" ]] || return 1
  _canonical="$(_mdm_canonical_any "$_path")" || return 1
  [[ "$_canonical" == /* && ! "$_canonical" =~ [[:cntrl:]] ]] || return 1
  _path="$_canonical"
  _python="$(_mdm_system_python)" || return 1
  _mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_LOCAL_VALIDATION_SECONDS")" \
    /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_kind" "$_path" "$_owner_csv" \
    "$_group_csv" "$_contract" <<'PY'
import base64
import collections
import _ctypes
import ctypes
import errno
import hashlib
import json
import os
import stat
import sys

kind, root, owner_csv, group_csv, contract = sys.argv[1:]
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

if kind not in ("file", "tree") or contract not in (
        "artifact", "copy-semantics", "artifact-copy-semantics"):
    raise SystemExit(1)
ARTIFACT_CONTRACT = contract in ("artifact", "artifact-copy-semantics")
COPY_SEMANTICS = contract in ("copy-semantics", "artifact-copy-semantics")
COMBINED_CONTRACT = contract == "artifact-copy-semantics"

if DARWIN:
    libc = ctypes.CDLL(None, use_errno=True)
    libc.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    libc.acl_get_fd_np.restype = ctypes.c_void_p
    libc.acl_free.argtypes = [ctypes.c_void_p]
    libc.acl_free.restype = ctypes.c_int
    libc.acl_to_text.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_ssize_t)
    ]
    libc.acl_to_text.restype = ctypes.c_void_p
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


def copy_acl(descriptor):
    # Linux exposes POSIX ACLs as system.posix_acl_* xattrs, which are already
    # captured byte-for-byte below.  On Darwin, serialize the fd-bound ACL so
    # copy equivalence covers ACL presence, order, entries, and permissions.
    if not DARWIN:
        return "posix-xattr"
    ctypes.set_errno(0)
    acl = libc.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
    if not acl:
        error = ctypes.get_errno()
        if error == errno.ENOENT:
            return ""
        raise OSError(error or errno.EIO, "acl_get_fd_np")
    text_pointer = None
    try:
        length = ctypes.c_ssize_t()
        ctypes.set_errno(0)
        text_pointer = libc.acl_to_text(acl, ctypes.byref(length))
        if not text_pointer or length.value < 0 or length.value > 1024 * 1024:
            error = ctypes.get_errno()
            raise OSError(error or errno.EIO, "acl_to_text")
        value = ctypes.string_at(text_pointer, length.value)
        return base64.b64encode(value).decode("ascii")
    finally:
        if text_pointer:
            ctypes.set_errno(0)
            if libc.acl_free(text_pointer) != 0:
                raise OSError(ctypes.get_errno() or errno.EIO,
                              "acl_free text")
        ctypes.set_errno(0)
        if libc.acl_free(acl) != 0:
            raise OSError(ctypes.get_errno() or errno.EIO, "acl_free")


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
    artifact_records = [] if ARTIFACT_CONTRACT else None
    copy_records = [] if COPY_SEMANTICS else None
    entry_count = 0
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
            acl = None
            if ARTIFACT_CONTRACT and not (is_link and not DARWIN):
                no_extended_acl(descriptor)
            if COPY_SEMANTICS:
                acl = copy_acl(descriptor)
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
            return values, acl

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
            nonlocal total, path_total, entry_count
            if depth > MAX_DEPTH or entry_count >= MAX_ENTRIES:
                raise ValueError("artifact tree too large")
            entry_count += 1
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
            xattrs, acl = metadata(descriptor, before)
            common = {"path": os.fsdecode(relative_bytes),
                      "mode": format(stat.S_IMODE(before.st_mode), "04o"),
                      "uid": before.st_uid, "gid": before.st_gid,
                      "nlink": before.st_nlink,
                      "flags": getattr(before, "st_flags", 0),
                      "xattrs": xattrs}
            artifact_base = (dict(common, size=before.st_size)
                             if ARTIFACT_CONTRACT else None)
            copy_base = None
            if COPY_SEMANTICS:
                copy_base = dict(common, acl=acl)
                if not stat.S_ISDIR(before.st_mode):
                    copy_base["size"] = before.st_size
            if stat.S_ISDIR(before.st_mode):
                if artifact_records is not None:
                    artifact_records.append(dict(artifact_base, kind="dir"))
                if copy_records is not None:
                    copy_records.append(dict(copy_base, kind="dir"))
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
                if artifact_records is not None:
                    artifact_records.append(dict(
                        artifact_base, kind="file", size=size,
                        sha256=digest.hexdigest()))
                if copy_records is not None:
                    copy_records.append(dict(
                        copy_base, kind="file", size=size,
                        sha256=digest.hexdigest()))
            elif stat.S_ISLNK(before.st_mode):
                if before.st_nlink != 1:
                    raise ValueError("hard-linked artifact symlink")
                target = fd_readlink(descriptor)
                validate_symlink(relative_parts[:-1], target)
                encoded_target = base64.b64encode(target).decode("ascii")
                if artifact_records is not None:
                    artifact_records.append(dict(
                        artifact_base, kind="symlink", target=encoded_target))
                if copy_records is not None:
                    copy_records.append(dict(
                        copy_base, kind="symlink", target=encoded_target))
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
        captures = []
        if artifact_records is not None:
            captures.append((json.dumps(
                artifact_records, ensure_ascii=True, sort_keys=True,
                separators=(",", ":")) + "\n").encode("ascii"))
        if copy_records is not None:
            captures.append((json.dumps(
                copy_records, ensure_ascii=True, sort_keys=True,
                separators=(",", ":")) + "\n").encode("ascii"))
        return tuple(captures)
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
    digests = [hashlib.sha256(value).hexdigest() for value in first]
    if COMBINED_CONTRACT:
        print(":".join(digests))
    else:
        print(digests[0])
except (OSError, UnicodeError, ValueError, MemoryError, OverflowError,
        RuntimeError, ctypes.ArgumentError):
    sys.exit(1)
PY
}

# Compare the observable semantics of two directory copies.  This retains the
# fd/no-follow walker, bounded reads, metadata capture, and double-capture race
# checks used by the authoritative artifact digest.  Directory inode, times,
# and st_size are deliberately omitted because a faithful copy necessarily has
# a new inode and may have a filesystem-dependent directory allocation size.
_mdm_copy_semantics_digest() { # <absolute-tree> [owner-uid-csv] [group-gid-csv]
  _mdm_artifact_digest tree "$1" "${2:-}" "${3:-}" copy-semantics
}

# Emit `<artifact-sha256>:<copy-semantics-sha256>` from the same two complete
# captures.  The transaction needs both contracts for the live tree; sharing
# the walker avoids two redundant full scans without weakening either digest.
_mdm_artifact_copy_semantics_digests() {
  # <absolute-tree> [owner-uid-csv] [group-gid-csv]
  _mdm_artifact_digest tree "$1" "${2:-}" "${3:-}" \
    artifact-copy-semantics
}

# Hash only Git worktree semantics so root-owned authoritative content can be
# compared with the target-user-owned retained checkout.  The same fd-bound
# walker is used for both sides; uid/gid/timestamps and clone-specific .git
# bytes are deliberately excluded.  The retained marker is the only additional
# exclusion and is validated independently by _mdm_persistent_marker_trusted.
_mdm_worktree_content_digest() { # <absolute-tree> <authority|retained>
  local _path="$1" _role="$2" _python _canonical
  case "$_role" in authority|retained) : ;; *) return 1 ;; esac
  [[ "$_path" == /* && ! "$_path" =~ [[:cntrl:]] && ! -L "$_path" ]] \
    || return 1
  _canonical="$(_mdm_canonical_dir "$_path")" || return 1
  [[ "$_canonical" == "$_path" ]] || return 1
  _python="$(_mdm_system_python)" || return 1
  _mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_LOCAL_VALIDATION_SECONDS")" \
    /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_path" "$_role" <<'PY'
import base64
import collections
import ctypes
import errno
import hashlib
import json
import os
import stat
import sys

root, role = sys.argv[1:]
if role not in ("authority", "retained"):
    raise SystemExit(1)

MAX_ENTRIES = 100000
MAX_DEPTH = 256
MAX_FILE = 512 * 1024 * 1024
MAX_TOTAL = 2 * 1024 * 1024 * 1024
MAX_PATH_TOTAL = 64 * 1024 * 1024
MAX_SYMLINK_TARGET = 64 * 1024
MAX_SYMLINKS = 40
MAX_SYMLINK_COMPONENTS = 4096
DARWIN = sys.platform == "darwin"
O_SYMLINK = 0x00200000
MARKER = b".claude-starter-kit-mdm-managed"

if DARWIN:
    libc = ctypes.CDLL(None, use_errno=True)
    libc.freadlink.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t]
    libc.freadlink.restype = ctypes.c_ssize_t
    libc.flistxattr.argtypes = [ctypes.c_int, ctypes.c_void_p,
                               ctypes.c_size_t, ctypes.c_int]
    libc.flistxattr.restype = ctypes.c_ssize_t
    libc.fgetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p,
                               ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    libc.fgetxattr.restype = ctypes.c_ssize_t
else:
    libc = None

DIR_FLAGS = (os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
             | getattr(os, "O_CLOEXEC", 0))
FILE_FLAGS = (os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
              | getattr(os, "O_CLOEXEC", 0))
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
        raise ValueError("worktree path changed")
    return opened


def open_entry(parent, name, before):
    if stat.S_ISDIR(before.st_mode):
        flags = DIR_FLAGS
    elif stat.S_ISREG(before.st_mode):
        flags = FILE_FLAGS
    elif stat.S_ISLNK(before.st_mode):
        flags = LINK_FLAGS
    else:
        raise ValueError("unsupported worktree entry")
    descriptor = os.open(name, flags, dir_fd=parent)
    try:
        opened = assert_bound(parent, name, descriptor, before)
        if stat.S_IFMT(opened.st_mode) != stat.S_IFMT(before.st_mode):
            raise ValueError("worktree type changed")
        if not stat.S_ISDIR(opened.st_mode) and opened.st_nlink != 1:
            raise ValueError("hard-linked worktree entry")
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def fd_readlink(descriptor):
    before = os.fstat(descriptor)
    if (not stat.S_ISLNK(before.st_mode) or before.st_nlink != 1
            or before.st_size <= 0 or before.st_size > MAX_SYMLINK_TARGET):
        raise ValueError("unsafe worktree symlink")

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
    if (not first or first != second or len(first) != before.st_size
            or identity(os.fstat(descriptor)) != identity(before)):
        raise ValueError("worktree symlink changed")
    return first


def capture_xattrs(descriptor, value):
    if getattr(value, "st_flags", 0) != 0:
        raise ValueError("worktree flags are not allowed")
    if DARWIN:
        ctypes.set_errno(0)
        needed = libc.flistxattr(descriptor, None, 0, 0x0020)
        if needed < 0:
            error = ctypes.get_errno()
            raise OSError(error or errno.EIO, "flistxattr")
        if needed > 64 * 1024:
            raise ValueError("worktree xattrs too large")
        if needed == 0:
            names = []
        else:
            buffer = ctypes.create_string_buffer(needed)
            actual = libc.flistxattr(descriptor,
                                     ctypes.cast(buffer, ctypes.c_void_p),
                                     needed, 0x0020)
            if actual != needed or not bytes(buffer[:actual]).endswith(b"\0"):
                raise ValueError("worktree xattr names changed")
            names = bytes(buffer[:actual - 1]).split(b"\0")
    elif stat.S_ISLNK(value.st_mode):
        names = []
    else:
        names = [os.fsencode(name) for name in os.listxattr(descriptor)]
    if len(names) > 256 or len(set(names)) != len(names):
        raise ValueError("invalid worktree xattr names")
    records = []
    for name in sorted(names):
        if not name or len(name) > 127:
            raise ValueError("invalid worktree xattr name")
        if DARWIN:
            ctypes.set_errno(0)
            needed = libc.fgetxattr(descriptor, name, None, 0, 0, 0x0020)
            if needed < 0:
                error = ctypes.get_errno()
                raise OSError(error or errno.EIO, "fgetxattr")
            if needed > 16 * 1024 * 1024:
                raise ValueError("worktree xattr value too large")
            buffer = ctypes.create_string_buffer(max(needed, 1))
            actual = libc.fgetxattr(descriptor, name,
                                    ctypes.cast(buffer, ctypes.c_void_p),
                                    needed, 0, 0x0020)
            if actual != needed:
                raise ValueError("worktree xattr value changed")
            data = bytes(buffer[:actual])
        else:
            data = os.getxattr(descriptor, os.fsdecode(name))
            if len(data) > 16 * 1024 * 1024:
                raise ValueError("worktree xattr value too large")
        records.append({"name": base64.b64encode(name).decode("ascii"),
                        "value": base64.b64encode(data).decode("ascii")})
    return records


def require_checkout_mode(value):
    mode = stat.S_IMODE(value.st_mode)
    if stat.S_ISDIR(value.st_mode):
        allowed = (0o755,) if role == "retained" else (0o555, 0o755)
    elif stat.S_ISREG(value.st_mode):
        executable = bool(mode & 0o111)
        if role == "retained":
            allowed = (0o755,) if executable else (0o644,)
        else:
            allowed = (0o555, 0o755) if executable else (0o444, 0o644)
    else:
        return
    if mode not in allowed:
        raise ValueError("non-canonical worktree mode")


def capture():
    records = []
    total = 0
    path_total = 0
    root_bytes = os.fsencode(root)
    if not root_bytes.startswith(b"/"):
        raise ValueError("worktree path is not absolute")
    parts = root_bytes.split(b"/")[1:]
    if not parts or any(part in (b"", b".", b"..") for part in parts):
        raise ValueError("worktree path is not canonical")

    slash = os.open(b"/", DIR_FLAGS)
    held = [slash]
    bindings = []
    try:
        current = slash
        for index, part in enumerate(parts):
            before = os.stat(part, dir_fd=current, follow_symlinks=False)
            if not stat.S_ISDIR(before.st_mode):
                raise ValueError("non-directory worktree component")
            child = os.open(part, DIR_FLAGS, dir_fd=current)
            final = index == len(parts) - 1
            try:
                assert_bound(current, part, child, before, final)
            except Exception:
                os.close(child)
                raise
            bindings.append((current, part, child, before, final))
            held.append(child)
            current = child
        root_fd = current
        root_dev = os.fstat(root_fd).st_dev

        def validate_symlink(parent_parts, target):
            if target.startswith(b"/") or len(target) > MAX_SYMLINK_TARGET:
                raise ValueError("invalid worktree symlink")
            pending = collections.deque(list(parent_parts) + target.split(b"/"))
            descriptors = [os.dup(root_fd)]
            target_bindings = []
            logical = []
            hops = 0
            processed = 0
            try:
                while pending:
                    component = pending.popleft()
                    processed += 1
                    if processed > MAX_SYMLINK_COMPONENTS:
                        raise ValueError("worktree symlink too complex")
                    if component in (b"", b"."):
                        continue
                    if component == b"..":
                        if not logical:
                            raise ValueError("worktree symlink escapes root")
                        logical.pop()
                        parent, name, descriptor, before = target_bindings.pop()
                        assert_bound(parent, name, descriptor, before)
                        os.close(descriptors.pop())
                        continue
                    if not logical and (component == b".git"
                                        or (role == "retained" and component == MARKER)):
                        raise ValueError("worktree symlink enters excluded state")
                    current_fd = descriptors[-1]
                    before = os.stat(component, dir_fd=current_fd,
                                     follow_symlinks=False)
                    if before.st_dev != root_dev:
                        raise ValueError("worktree symlink crosses filesystem")
                    if stat.S_ISLNK(before.st_mode):
                        link_fd = open_entry(current_fd, component, before)
                        try:
                            nested = fd_readlink(link_fd)
                            assert_bound(current_fd, component, link_fd, before)
                        finally:
                            os.close(link_fd)
                        if nested.startswith(b"/"):
                            raise ValueError("absolute nested worktree symlink")
                        hops += 1
                        if hops > MAX_SYMLINKS:
                            raise ValueError("too many worktree symlinks")
                        pending.extendleft(reversed(nested.split(b"/")))
                        continue
                    logical.append(component)
                    if pending:
                        if not stat.S_ISDIR(before.st_mode):
                            raise ValueError("dangling worktree symlink")
                        child = os.open(component, DIR_FLAGS, dir_fd=current_fd)
                        try:
                            assert_bound(current_fd, component, child, before)
                        except Exception:
                            os.close(child)
                            raise
                        target_bindings.append((current_fd, component, child, before))
                        descriptors.append(child)
                    else:
                        if stat.S_ISDIR(before.st_mode):
                            flags = DIR_FLAGS
                        elif stat.S_ISREG(before.st_mode):
                            flags = FILE_FLAGS
                        else:
                            raise ValueError("unsupported worktree symlink target")
                        terminal = os.open(component, flags, dir_fd=current_fd)
                        try:
                            assert_bound(current_fd, component, terminal, before)
                        finally:
                            os.close(terminal)
                for parent, name, descriptor, before in reversed(target_bindings):
                    assert_bound(parent, name, descriptor, before)
            finally:
                for descriptor in reversed(descriptors):
                    try:
                        os.close(descriptor)
                    except OSError:
                        pass

        def visit(descriptor, parent, name, before, relative, depth):
            nonlocal total, path_total
            if depth > MAX_DEPTH or len(records) >= MAX_ENTRIES:
                raise ValueError("worktree too large")
            if before.st_dev != root_dev:
                raise ValueError("worktree crosses filesystem")
            xattrs = capture_xattrs(descriptor, before)
            require_checkout_mode(before)
            relative_bytes = b"/".join(relative)
            path_total += len(relative_bytes)
            if path_total > MAX_PATH_TOTAL:
                raise ValueError("worktree paths too large")
            path = base64.b64encode(relative_bytes).decode("ascii")
            if stat.S_ISDIR(before.st_mode):
                records.append({"kind": "dir", "mode": "040000", "path": path,
                                "xattrs": xattrs})
                names = sorted((os.fsencode(item) for item in os.listdir(descriptor)))
                for child_name in names:
                    if child_name in (b"", b".", b"..") or b"/" in child_name:
                        raise ValueError("invalid worktree entry")
                    if depth == 0 and (child_name == b".git"
                                       or (role == "retained" and child_name == MARKER)):
                        continue
                    child_before = os.stat(child_name, dir_fd=descriptor,
                                           follow_symlinks=False)
                    child = open_entry(descriptor, child_name, child_before)
                    try:
                        visit(child, descriptor, child_name, child_before,
                              relative + [child_name], depth + 1)
                        assert_bound(descriptor, child_name, child, child_before)
                    finally:
                        os.close(child)
                after_names = sorted((os.fsencode(item)
                                      for item in os.listdir(descriptor)))
                if after_names != names:
                    raise ValueError("worktree directory changed")
            elif stat.S_ISREG(before.st_mode):
                if before.st_nlink != 1 or before.st_size > MAX_FILE:
                    raise ValueError("unsafe worktree file")
                digest = hashlib.sha256()
                size = 0
                os.lseek(descriptor, 0, os.SEEK_SET)
                while True:
                    block = os.read(descriptor, 1024 * 1024)
                    if not block:
                        break
                    size += len(block)
                    if size > MAX_FILE:
                        raise ValueError("worktree file grew")
                    digest.update(block)
                if size != before.st_size:
                    raise ValueError("worktree file size changed")
                total += size
                if total > MAX_TOTAL:
                    raise ValueError("worktree aggregate too large")
                mode = "100755" if stat.S_IMODE(before.st_mode) & 0o111 else "100644"
                records.append({"kind": "file", "mode": mode, "path": path,
                                "sha256": digest.hexdigest(), "size": size,
                                "xattrs": xattrs})
            elif stat.S_ISLNK(before.st_mode):
                target = fd_readlink(descriptor)
                validate_symlink(relative[:-1], target)
                records.append({"kind": "symlink", "mode": "120000", "path": path,
                                "target": base64.b64encode(target).decode("ascii"),
                                "xattrs": xattrs})
            else:
                raise ValueError("unsupported worktree entry")
            if identity(os.fstat(descriptor)) != identity(before):
                raise ValueError("worktree changed")
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
        raise ValueError("worktree changed during capture")
    print(hashlib.sha256(first).hexdigest())
except (OSError, UnicodeError, ValueError, MemoryError, OverflowError,
        RuntimeError, ctypes.ArgumentError):
    raise SystemExit(1)
PY
}

_mdm_stat_identity() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%i:%HT:%z' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%i:%F:%s' "$1" 2>/dev/null
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

# Copy bounded bytes in a child because a checked user-owned pathname can be
# replaced by a FIFO before open(2).  The watchdog bounds that open, head reads
# at most limit+1 bytes, and the copied size plus source metadata must remain
# identical to the pre-open snapshot.
_MDM_BOUND_SNAPSHOT_MODE=""

_mdm_snapshot_copy_bound() {
  # <source> <snapshot> <label> <before-id> <size> <metadata> <uid> <mode> <limit>
  local _source="$1" _snapshot="$2" _label="$3" _before="$4" _size="$5"
  local _meta="$6" _uid="$7" _mode="$8" _copy_limit="$9"
  local _opened="" _copied="" _copied_size="" _after="" _meta_after=""
  local _after_uid="" _after_rest="" _after_links="" _after_mode=""
  exec 9<"$_source" || return 1
  _opened="$(_mdm_stat_fd_identity 9)" || { exec 9<&-; return 1; }
  [[ "$_opened" == "$_before" ]] || { exec 9<&-; return 1; }
  /usr/bin/head -c "$_copy_limit" <&9 > "$_snapshot" \
    || { exec 9<&-; return 1; }
  exec 9<&- 2>/dev/null || true
  _copied="$(_mdm_stat_identity "$_snapshot")" || return 1
  case "$_copied" in
    *:Regular\ File:*|*:regular\ file:*) : ;;
    *) return 1 ;;
  esac
  _copied_size="${_copied##*:}"
  [[ "$_copied_size" == "$_size" ]] || return 1
  _after="$(_mdm_stat_identity "$_source")" || return 1
  _meta_after="$(_mdm_stat_managed_metadata "$_source")" || return 1
  if [[ "$_label" == history ]]; then
    # Link-count changes are not content/identity changes.  A valid root-owned
    # history may be hardlinked by a local root recovery workflow.
    [[ "$_meta_after" =~ ^[0-9]+:[0-9]+:[0-7]+$ ]] || return 1
    _after_uid="${_meta_after%%:*}"
    _after_rest="${_meta_after#*:}"
    _after_links="${_after_rest%%:*}"
    _after_mode="$(_mdm_mode_normalize "${_after_rest#*:}" || true)"
    [[ "$_after_links" =~ ^[1-9][0-9]*$ \
      && "$_after_uid" == "$_uid" && "$_after_mode" == "$_mode" ]] \
      || return 1
  else
    [[ "$_meta_after" == "$_meta" ]] || return 1
  fi
  [[ "$_after" == "$_before" ]] || return 1
  ! _mdm_has_extended_acl "$_source" || return 1
  /bin/chmod 600 "$_snapshot"
}

_MDM_ACTIVE_BOUND_SNAPSHOT_SUPERVISOR_PID=""
_MDM_BOUND_SNAPSHOT_SUPERVISOR_STARTING=0
_MDM_BOUND_SNAPSHOT_SUPERVISOR_PREVIOUS_BG=""
_MDM_ACTIVE_BOUND_SNAPSHOT_PATH=""

_mdm_run_bound_snapshot_with_timeout() { # <seconds> <snapshot> <function> [args...]
  local _seconds="$1" _snapshot="$2" _supervisor="" _rc=0 _previous=""
  local _monitor_was_on=false _pending_signal=""
  shift 2
  _mdm_bound_snapshot_capture_parent_bg() {
    local _nounset_was_on=false
    case $- in *u*) _nounset_was_on=true ;; esac
    set +u
    _previous="$!"
    [[ "$_nounset_was_on" == true ]] && set -u
  }
  _mdm_bound_snapshot_capture_parent_bg
  # Defer a signal until cleanup ownership is fully registered.  Ignoring it
  # here would discard it instead of making it pending.
  trap '_pending_signal=HUP' HUP
  trap '_pending_signal=INT' INT
  trap '_pending_signal=TERM' TERM
  _MDM_BOUND_SNAPSHOT_SUPERVISOR_PREVIOUS_BG="$_previous"
  _MDM_BOUND_SNAPSHOT_SUPERVISOR_STARTING=1
  _MDM_ACTIVE_BOUND_SNAPSHOT_PATH="$_snapshot"
  # Arm cleanup as soon as registration is complete.  Before spawn, the $!
  # fallback rejects the saved previous PID; during handoff it recovers the
  # new supervisor PID.
  _mdm_arm_transient_signal_cleanup
  case "$_pending_signal" in
    HUP) _mdm_cleanup_transient_checkouts HUP; exit 129 ;;
    INT) _mdm_cleanup_transient_checkouts INT; exit 130 ;;
    TERM) _mdm_cleanup_transient_checkouts TERM; exit 143 ;;
  esac
  case $- in *m*) _monitor_was_on=true ;; esac
  set -m || {
    _MDM_BOUND_SNAPSHOT_SUPERVISOR_STARTING=0
    _MDM_ACTIVE_BOUND_SNAPSHOT_PATH=""
    return 1
  }
  # The parent needs monitor mode only for assigning this supervisor its own
  # process group.  Disable it inside that already-separated supervisor so
  # its normally-terminated watchdog cannot emit job-control diagnostics.
  ( set +m; _mdm_timeout_coordinator "$_seconds" "$@" ) <&0 &
  _supervisor=$!
  _MDM_ACTIVE_BOUND_SNAPSHOT_SUPERVISOR_PID="$_supervisor"
  _MDM_BOUND_SNAPSHOT_SUPERVISOR_STARTING=0
  [[ "$_monitor_was_on" == true ]] || set +m || true
  # Do not install an EXIT trap here: snapshot helpers are also consumed via
  # command substitution, where a newly-installed EXIT trap would roll back
  # the caller's live transaction when the substitution exits normally.
  wait "$_supervisor" 2>/dev/null || _rc=$?
  if [[ "$_MDM_ACTIVE_BOUND_SNAPSHOT_SUPERVISOR_PID" == "$_supervisor" ]]; then
    _MDM_ACTIVE_BOUND_SNAPSHOT_SUPERVISOR_PID=""
  fi
  if [[ "$_MDM_ACTIVE_BOUND_SNAPSHOT_PATH" == "$_snapshot" ]]; then
    _MDM_ACTIVE_BOUND_SNAPSHOT_PATH=""
  fi
  return "$_rc"
}

_mdm_snapshot_bound_to() { # <source> <snapshot> <label> [target-uid]
  local _source="$1" _snapshot="$2" _label="$3" _expected_uid="${4:-}"
  local _before _meta _uid _rest _links _mode_raw _mode
  local _size _limit _copy_limit _watch_seconds=5
  _MDM_BOUND_SNAPSHOT_MODE=""
  [[ -f "$_source" && ! -L "$_source" ]] || return 1
  [[ -f "$_snapshot" && ! -L "$_snapshot" ]] || return 1
  _before="$(_mdm_stat_identity "$_source")" || return 1
  case "$_before" in *:Regular\ File:*|*:regular\ file:*) : ;; *) return 1 ;; esac
  _size="${_before##*:}"
  _meta="$(_mdm_stat_managed_metadata "$_source")" || return 1
  [[ "$_meta" =~ ^[0-9]+:[0-9]+:[0-7]+$ ]] || return 1
  _uid="${_meta%%:*}"; _rest="${_meta#*:}"
  _links="${_rest%%:*}"; _mode_raw="${_rest#*:}"
  _mode="$(_mdm_mode_normalize "$_mode_raw")" || return 1
  _mdm_mode_is_safe "$_mode" || return 1
  if [[ "$_label" == history ]]; then
    [[ "$_links" =~ ^[1-9][0-9]*$ ]] || return 1
  else
    [[ "$_links" == 1 ]] || return 1
  fi
  _mdm_has_extended_acl "$_source" && return 1
  if [[ "$_label" == managed || "$_label" == cli || "$_label" == head ]]; then
    [[ "$_expected_uid" =~ ^[0-9]+$ && "$_uid" == "$_expected_uid" ]] \
      || return 1
  fi
  case "$_label" in
    manifest|receipt|history) _limit=4194304 ;;
    managed) _limit=67108864 ;;
    cli) _limit=536870912 ;;
    head) _limit=41 ;;
    *) return 1 ;;
  esac
  [[ "$_size" =~ ^[0-9]+$ && "$_size" -le "$_limit" ]] || return 1
  _copy_limit=$((_limit + 1))
  if [[ "${_MDM_TEST_MODE:-0}" == "1" \
    && "${MDM_SNAPSHOT_WATCHDOG_SECONDS_OVERRIDE:-}" =~ ^[1-5]$ ]]; then
    _watch_seconds="$MDM_SNAPSHOT_WATCHDOG_SECONDS_OVERRIDE"
  fi
  if ! _mdm_run_bound_snapshot_with_timeout "$_watch_seconds" "$_snapshot" \
      _mdm_snapshot_copy_bound "$_source" "$_snapshot" "$_label" \
      "$_before" "$_size" "$_meta" "$_uid" "$_mode" "$_copy_limit" \
    || [[ ! -f "$_snapshot" || -L "$_snapshot" ]]; then
    /bin/rm -f "$_snapshot"
    return 1
  fi
  _MDM_BOUND_SNAPSHOT_MODE="$_mode"
}

_mdm_stable_file_snapshot() { # <source> <label>
  local _source="$1" _label="$2" _tmp _old_umask
  _old_umask="$(umask)"; umask 077
  _tmp="$(/usr/bin/mktemp "$(_mdm_safe_tmpdir)/claude-kit-mdm-${_label}.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  if _mdm_snapshot_bound_to "$_source" "$_tmp" "$_label"; then
    printf '%s' "$_tmp"
  else
    /bin/rm -f "$_tmp"
    return 1
  fi
}

_mdm_stable_managed_snapshot() { # <source> <label> <uid> <copy-var> <mode-var>
  local _source="$1" _label="$2" _uid="$3" _copy_var="$4" _mode_var="$5"
  local _tmp _old_umask
  _old_umask="$(umask)"; umask 077
  _tmp="$(/usr/bin/mktemp "$(_mdm_safe_tmpdir)/claude-kit-mdm-${_label}.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  if ! _mdm_snapshot_bound_to "$_source" "$_tmp" managed "$_uid"; then
    /bin/rm -f "$_tmp"
    return 1
  fi
  printf -v "$_copy_var" '%s' "$_tmp"
  printf -v "$_mode_var" '%s' "$_MDM_BOUND_SNAPSHOT_MODE"
}

# パス構成要素の信頼性検証（R5-High）: 非 symlink・root 所有・group/other
# 書込不可。テスト（非 root）は MDM_LOG_SKIP_OWNER_CHECK=1 で owner 検査を無効化。
# _mdm_boot_mode_is_safe は launcher ヘルパー領域で定義（実行時に解決される）。
_mdm_component_trusted() {
  local _p="$1"
  [[ -L "$_p" ]] && return 1
  local _mode
  _mode="$(_mdm_stat_mode "$_p" || true)"
  _mdm_mode_is_safe "$_mode" || return 1
  _mdm_has_extended_acl "$_p" && return 1
  local _skip_owner="false"
  if [[ "${_MDM_TEST_MODE:-0}" == "1" ]] \
    && { [[ "${MDM_LOG_SKIP_OWNER_CHECK:-0}" == "1" ]] || [[ "${MDM_CONFIG_SKIP_OWNER_CHECK:-0}" == "1" ]]; }; then
    _skip_owner="true"
  fi
  if [[ "$_skip_owner" != "true" ]]; then
    local _owner
    _owner="$(_mdm_stat_owner "$_p" || true)"
    [[ "$_owner" == "root" ]] || return 1
  fi
  return 0
}

# 信頼起点 _base から _dir までの全構成要素（存在するもの）が信頼できるか検証
# する。root 経路で root 書込領域へ書く前に、攻撃者所有の中間/最終
# ディレクトリや中間 symlink による許可プレフィックス外への誘導を排除する。
# パス分解に word splitting / glob 展開を一切使わない（`*`/`?`/`[`
# を含むコンポーネントが pathname expansion されて検証対象がすり替わるのを防ぐ）。
# 文字列の prefix 削除で 1 セグメントずつリテラルに処理する。
_mdm_verify_dir_chain() {
  local _dir="$1" _base="$2"
  case "$_dir" in
    "$_base"|"$_base"/*) : ;;
    *) return 1 ;;
  esac
  _mdm_component_trusted "$_base" || return 1
  local _rest="${_dir#"$_base"}" _cur="$_base" _seg
  while [[ -n "$_rest" ]]; do
    _rest="${_rest#/}"            # 先頭スラッシュ除去
    [[ -z "$_rest" ]] && break
    _seg="${_rest%%/*}"           # 最初のセグメント（リテラル。glob 展開しない）
    _rest="${_rest#"$_seg"}"      # 消費（残りは /… または空）
    [[ -z "$_seg" ]] && continue
    _cur="$_cur/$_seg"
    if [[ -e "$_cur" || -L "$_cur" ]]; then
      _mdm_component_trusted "$_cur" || return 1
    fi
  done
  return 0
}

# jq 非依存でレシート JSON を書く。required_components / partial は既に JSON 配列文字列。
# セキュリティ要件:
#   - root 経路はレシート dir の信頼チェーンを検証（攻撃者所有 dir を再利用しない）
#   - dir 権限を umask に依存させない（信頼チェーン成立で 755 を要求・chmod は不要）
#   - 既存パスの symlink は辿らず除去（root の書込を別ファイルへ誘導させない）
#   - 同一 dir の一時ファイルへ書いてから mv -f（atomic rename・部分書込を晒さない）
_MDM_RECEIPT_PUBLISHED=0
_MDM_RECEIPT_PREPARED_TMP=""
_MDM_RECEIPT_PREPARED_PATH=""

_mdm_generated_receipt_is_exact() { # <temp> <destination> <result> <exit>
  local _file="$1" _destination="$2" _result="$3" _exit="$4" _python
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_file" "$_destination" "$_result" "$_exit" \
      "$MDM_RCPT_KIT_VERSION" "$MDM_RCPT_GIT_REF" \
      "$MDM_RCPT_RESOLVED_SHA" "$MDM_RCPT_INSTALL_DIR" \
      "$MDM_RCPT_REQUIRED_COMPONENTS" "$MDM_RCPT_PROFILE" \
      "$MDM_RCPT_LANGUAGE" "$MDM_RCPT_MANIFEST_PATH" \
      "$MDM_RCPT_MANIFEST_SHA256" "$MDM_RCPT_DEPLOYMENT_SHA256" \
      "$MDM_RCPT_POLICY_SHA256" "$MDM_RCPT_COMPONENT_MANIFEST_PATH" \
      "$MDM_RCPT_COMPONENT_MANIFEST_SHA256" "$MDM_RCPT_TARGET_USER" \
      "$MDM_RCPT_TARGET_UID" "$MDM_RCPT_TARGET_GENERATED_UID" \
      "$MDM_RCPT_PARTIAL" "$MDM_RCPT_TIMESTAMP" "$MDM_RCPT_LOG_PATH" \
      >/dev/null 2>&1 <<'PY'
import json
import os
import re
import stat
import sys

(path, destination, result, exit_raw, kit_version, git_ref, resolved_sha,
 install_dir, required_raw, profile, language, manifest_path, manifest_sha,
 deployment_sha, policy_sha, component_path, component_sha, target_user,
 target_uid_raw, target_guid, partial_raw, timestamp, log_path) = sys.argv[1:]

order = (
    "schema_version", "kit_version", "git_ref", "resolved_sha",
    "install_dir", "required_components", "profile", "language",
    "manifest_path", "manifest_sha256", "deployment_sha256",
    "policy_sha256", "component_manifest_path",
    "component_manifest_sha256", "target_user", "target_uid",
    "target_generated_uid", "result", "exit_code", "partial",
    "timestamp", "log_path",
)
allowed_components = {
    "biome", "claude_cli", "fonts", "ghostty", "kit", "node_runtime",
    "safety_net", "web_content_runtime",
}
hash_pattern = re.compile(r"[0-9a-f]{64}")
commit_pattern = re.compile(r"[0-9a-f]{40}")
guid_pattern = re.compile(
    r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
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


def decimal(value):
    if (not value.isascii() or not value.isdigit()
            or (len(value) > 1 and value.startswith("0"))):
        raise ValueError("non-canonical integer")
    return int(value)


def canonical_array(raw):
    value = json.loads(raw, object_pairs_hook=unique_object,
                       parse_constant=reject_constant)
    if type(value) is not list or not control_free(value):
        raise ValueError("invalid receipt array")
    rendered = json.dumps(value, ensure_ascii=False, separators=(",", ":"),
                          allow_nan=False)
    if rendered != raw:
        raise ValueError("non-canonical receipt array")
    return value


def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_uid, value.st_gid, value.st_size, value.st_mtime_ns,
            value.st_ctime_ns, getattr(value, "st_flags", 0),
            getattr(value, "st_gen", 0))


try:
    exit_code = decimal(exit_raw)
    target_uid = decimal(target_uid_raw)
    required = canonical_array(required_raw)
    partial = canonical_array(partial_raw)
    if (not 1 <= len(required) <= 8
            or any(type(item) is not str or item not in allowed_components
                   for item in required)
            or required != sorted(set(required)) or "kit" not in required):
        raise ValueError("invalid required components")
    needs_node = ("safety_net" in required
                  or "web_content_runtime" in required)
    if ("node_runtime" in required) != needs_node:
        raise ValueError("invalid node component dependency")
    if profile not in {"minimal", "standard", "full"}:
        raise ValueError("invalid profile")
    if language not in {"en", "ja"}:
        raise ValueError("invalid language")

    if result == "success":
        suffix = "/.claude-starter-kit"
        home = install_dir[:-len(suffix)] if install_dir.endswith(suffix) else ""
        receipt_dir = os.path.dirname(destination)
        if (exit_code != 0 or partial != [] or target_uid < 501
                or not target_user or not guid_pattern.fullmatch(target_guid)
                or not commit_pattern.fullmatch(git_ref)
                or resolved_sha != git_ref
                or not install_dir.startswith("/") or not home
                or install_dir != home + "/.claude-starter-kit"
                or manifest_path
                    != home + "/.claude/.starter-kit-manifest.json"
                or component_path
                    != receipt_dir + "/components-" + target_guid + ".json"
                or destination
                    != receipt_dir + "/receipt-" + target_user + ".json"
                or any(not hash_pattern.fullmatch(value) for value in (
                    manifest_sha, deployment_sha, policy_sha, component_sha))):
            raise ValueError("invalid success receipt claim")
    elif result == "failure":
        if exit_code not in {10, 11, 20, 21, 30, 40, 50, 60}:
            raise ValueError("invalid failure exit code")
        if tuple(partial) not in {
                (), ("claude_cli",), ("receipt",), ("rollback",),
                ("claude_cli", "rollback"), ("receipt", "rollback")}:
            raise ValueError("invalid partial failure claim")
        if target_user:
            if target_uid < 501 or not guid_pattern.fullmatch(target_guid):
                raise ValueError("invalid resolved target tuple")
        elif target_uid != 0 or target_guid:
            raise ValueError("invalid unresolved target tuple")
        if git_ref and not commit_pattern.fullmatch(git_ref):
            raise ValueError("invalid failure git ref")
        if resolved_sha and (not commit_pattern.fullmatch(resolved_sha)
                             or resolved_sha != git_ref):
            raise ValueError("invalid failure resolved SHA")
        if install_dir and (not install_dir.startswith("/")
                            or not install_dir.endswith("/.claude-starter-kit")):
            raise ValueError("invalid failure install path")
        if manifest_path and not manifest_path.startswith("/"):
            raise ValueError("invalid failure manifest path")
        if component_path and not component_path.startswith("/"):
            raise ValueError("invalid failure component path")
        for value in (manifest_sha, deployment_sha, policy_sha, component_sha):
            if value and not hash_pattern.fullmatch(value):
                raise ValueError("invalid failure hash")
    else:
        raise ValueError("invalid receipt result")

    expected = {
        "schema_version": 3,
        "kit_version": kit_version,
        "git_ref": git_ref,
        "resolved_sha": resolved_sha,
        "install_dir": install_dir,
        "required_components": required,
        "profile": profile,
        "language": language,
        "manifest_path": manifest_path,
        "manifest_sha256": manifest_sha,
        "deployment_sha256": deployment_sha,
        "policy_sha256": policy_sha,
        "component_manifest_path": component_path,
        "component_manifest_sha256": component_sha,
        "target_user": target_user,
        "target_uid": target_uid,
        "target_generated_uid": target_guid,
        "result": result,
        "exit_code": exit_code,
        "partial": partial,
        "timestamp": timestamp,
        "log_path": log_path,
    }
    if not control_free(expected):
        raise ValueError("receipt contains a control character")
    lines = ["{"]
    for index, key in enumerate(order):
        rendered = json.dumps(expected[key], ensure_ascii=False,
                              separators=(",", ":"), allow_nan=False)
        comma = "," if index + 1 < len(order) else ""
        lines.append(f'  {json.dumps(key)}: {rendered}{comma}')
    canonical = ("\n".join(lines) + "\n}\n").encode("utf-8")

    before = os.lstat(path)
    if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
            or before.st_size < 3 or before.st_size > 64 * 1024):
        raise ValueError("unsafe receipt temp")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW
                         | getattr(os, "O_CLOEXEC", 0))
    try:
        opened = os.fstat(descriptor)
        if identity(opened) != identity(before):
            raise ValueError("receipt identity changed")
        actual = b""
        while len(actual) < opened.st_size:
            chunk = os.read(descriptor, opened.st_size - len(actual))
            if not chunk:
                raise ValueError("short receipt read")
            actual += chunk
        if os.read(descriptor, 1):
            raise ValueError("receipt grew during read")
    finally:
        os.close(descriptor)
    if identity(os.lstat(path)) != identity(before) or actual != canonical:
        raise ValueError("receipt is not writer-canonical")
    decoded = json.loads(actual.decode("utf-8", "strict"),
                         object_pairs_hook=unique_object,
                         parse_constant=reject_constant)
    if decoded != expected or tuple(decoded) != order:
        raise ValueError("receipt schema mismatch")
except (IndexError, OSError, TypeError, UnicodeError, ValueError,
        json.JSONDecodeError):
    raise SystemExit(1)
PY
}

_mdm_receipt_discard_prepared() {
  local _tmp="${_MDM_RECEIPT_PREPARED_TMP:-}"
  local _path="${_MDM_RECEIPT_PREPARED_PATH:-}" _dir
  [[ -n "$_tmp" ]] || return 0
  [[ -n "$_path" ]] || _path="${_MDM_RECEIPT_PREPARED_DESTINATION:-}"
  _dir="${_path%/*}"
  case "$_tmp" in "$_dir"/.receipt-tmp.*) : ;; *) return 1 ;; esac
  if [[ -e "$_tmp" || -L "$_tmp" ]]; then
    [[ -f "$_tmp" && ! -L "$_tmp" ]] || return 1
    /bin/rm -f "$_tmp" || return 1
  fi
  _MDM_RECEIPT_PREPARED_TMP=""
  _MDM_RECEIPT_PREPARED_PATH=""
  _MDM_RECEIPT_PREPARED_DESTINATION=""
}

_mdm_receipt_prepared_ready() {
  local _tmp="${_MDM_RECEIPT_PREPARED_TMP:-}"
  local _path="${_MDM_RECEIPT_PREPARED_PATH:-}"
  [[ -n "$_tmp" && -n "$_path" && -f "$_tmp" && ! -L "$_tmp" \
    && "${_MDM_RECEIPT_PREPARED_DESTINATION:-}" == "$_path" ]]
}

_mdm_receipt_publish_prepared() {
  local _tmp="${_MDM_RECEIPT_PREPARED_TMP:-}"
  local _path="${_MDM_RECEIPT_PREPARED_PATH:-}"
  [[ -n "$_tmp" && -n "$_path" ]] || return 1
  /bin/mv -f "$_tmp" "$_path" 2>/dev/null || return 1
  _MDM_RECEIPT_PREPARED_TMP=""
  _MDM_RECEIPT_PREPARED_PATH=""
  _MDM_RECEIPT_PREPARED_DESTINATION=""
  _MDM_RECEIPT_PUBLISHED=1
}

mdm_receipt_prepare() {
  local _path="$1" _result="$2" _exit="$3"
  local _manifest_home=""
  _MDM_RECEIPT_PUBLISHED=0
  [[ -z "${_MDM_RECEIPT_PREPARED_TMP:-}" ]] || return 1
  _MDM_RECEIPT_PREPARED_DESTINATION="$_path"
  local _dir; _dir="$(dirname "$_path")"
  local _euid; _euid="${MDM_EUID_OVERRIDE:-$(id -u)}"
  if [[ "$_result" == success && "$_exit" -eq 0 ]]; then
    [[ "$MDM_RCPT_GIT_REF" =~ ^[0-9a-f]{40}$ \
      && "$MDM_RCPT_RESOLVED_SHA" =~ ^[0-9a-f]{40}$ \
      && "$MDM_RCPT_GIT_REF" == "$MDM_RCPT_RESOLVED_SHA" ]] || return 1
    [[ "$MDM_RCPT_TARGET_UID" =~ ^[0-9]+$ && "$MDM_RCPT_TARGET_UID" -ge 501 ]] || return 1
    _mdm_normalize_generated_uid "$MDM_RCPT_TARGET_GENERATED_UID" >/dev/null || return 1
    case "$MDM_RCPT_INSTALL_DIR" in
      /*/.claude-starter-kit)
        _manifest_home="${MDM_RCPT_INSTALL_DIR%/.claude-starter-kit}" ;;
      *) return 1 ;;
    esac
    [[ -n "$_manifest_home" \
      && "$MDM_RCPT_MANIFEST_PATH" == "$_manifest_home/.claude/.starter-kit-manifest.json" \
      && "$MDM_RCPT_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ \
      && "$MDM_RCPT_DEPLOYMENT_SHA256" =~ ^[0-9a-f]{64}$ \
      && "$MDM_RCPT_POLICY_SHA256" =~ ^[0-9a-f]{64}$ \
      && "$MDM_RCPT_COMPONENT_MANIFEST_PATH" == /* \
      && "$MDM_RCPT_COMPONENT_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
  fi
  # root 書込（mkdir 含む）の前に既存コンポーネントを検証する。
  # 中間/最終が攻撃者所有 or symlink なら、mkdir がリンク先へ作成する前に
  # fail-closed する。成立すれば以降の mktemp/chmod/mv は攻撃者が介入できない。
  if [[ "$_euid" -eq 0 ]] && ! _mdm_verify_dir_chain "$_dir" "/Library/Application Support"; then
    mdm_log R4 "レシート dir の信頼チェーンが成立しない（fail-closed）: $_dir"
    return 1
  fi
  # umask 022 で dir を 755 作成（呼び出し時点の umask 変化に依存しない）
  local _rum; _rum="$(umask)"; umask 022
  mkdir -p "$_dir" 2>/dev/null || true
  umask "$_rum"
  # 作成後の最終 dir を再検証（root 755 で作られたこと）+ 既存 dir を契約の 755 へ収束
  if [[ "$_euid" -eq 0 ]]; then
    if ! _mdm_component_trusted "$_dir"; then
      mdm_log R4 "作成後のレシート dir が信頼できない（fail-closed）: $_dir"
      return 1
    fi
    if ! chmod 755 "$_dir" 2>/dev/null; then
      mdm_log R4 "レシート dir の権限（755）を設定できない（fail-closed）: $_dir"
      return 1
    fi
  fi
  # `mv source existing-directory` succeeds by placing source *inside* the
  # directory.  Treat every pre-existing non-regular destination as a hard
  # failure (a symlink is handled separately below and replaced in-place).
  if [[ -e "$_path" && ! -f "$_path" && ! -L "$_path" ]]; then
    mdm_log R4 "レシートパスの実体が regular file でない: $_path"
    return 1
  fi
  if [[ -L "$_path" ]]; then
    rm -f "$_path" 2>/dev/null || true
    if [[ -L "$_path" || -e "$_path" ]]; then
      mdm_log R4 "レシートパスの symlink を除去できない: $_path"
      return 1
    fi
  fi
  local _tmp
  _tmp="$(mktemp "$_dir/.receipt-tmp.XXXXXX" 2>/dev/null)" || {
    _MDM_RECEIPT_PREPARED_DESTINATION=""
    return 1
  }
  _MDM_RECEIPT_PREPARED_TMP="$_tmp"
  _MDM_RECEIPT_PREPARED_PATH="$_path"
  _mdm_arm_transient_cleanup
  {
    printf '{\n'
    printf '  "schema_version": 3,\n'
    printf '  "kit_version": "%s",\n'  "$(mdm_json_escape "$MDM_RCPT_KIT_VERSION")"
    printf '  "git_ref": "%s",\n'      "$(mdm_json_escape "$MDM_RCPT_GIT_REF")"
    printf '  "resolved_sha": "%s",\n' "$(mdm_json_escape "$MDM_RCPT_RESOLVED_SHA")"
    printf '  "install_dir": "%s",\n'  "$(mdm_json_escape "$MDM_RCPT_INSTALL_DIR")"
    printf '  "required_components": %s,\n' "$MDM_RCPT_REQUIRED_COMPONENTS"
    printf '  "profile": "%s",\n'      "$(mdm_json_escape "$MDM_RCPT_PROFILE")"
    printf '  "language": "%s",\n'     "$(mdm_json_escape "$MDM_RCPT_LANGUAGE")"
    printf '  "manifest_path": "%s",\n' "$(mdm_json_escape "$MDM_RCPT_MANIFEST_PATH")"
    printf '  "manifest_sha256": "%s",\n' "$(mdm_json_escape "$MDM_RCPT_MANIFEST_SHA256")"
    printf '  "deployment_sha256": "%s",\n' "$(mdm_json_escape "$MDM_RCPT_DEPLOYMENT_SHA256")"
    printf '  "policy_sha256": "%s",\n' "$(mdm_json_escape "$MDM_RCPT_POLICY_SHA256")"
    printf '  "component_manifest_path": "%s",\n' "$(mdm_json_escape "$MDM_RCPT_COMPONENT_MANIFEST_PATH")"
    printf '  "component_manifest_sha256": "%s",\n' "$(mdm_json_escape "$MDM_RCPT_COMPONENT_MANIFEST_SHA256")"
    printf '  "target_user": "%s",\n'  "$(mdm_json_escape "$MDM_RCPT_TARGET_USER")"
    printf '  "target_uid": %s,\n' "$MDM_RCPT_TARGET_UID"
    printf '  "target_generated_uid": "%s",\n' \
      "$(mdm_json_escape "$MDM_RCPT_TARGET_GENERATED_UID")"
    printf '  "result": "%s",\n'       "$(mdm_json_escape "$_result")"
    printf '  "exit_code": %s,\n'      "$_exit"
    printf '  "partial": %s,\n'        "$MDM_RCPT_PARTIAL"
    printf '  "timestamp": "%s",\n'    "$(mdm_json_escape "$MDM_RCPT_TIMESTAMP")"
    printf '  "log_path": "%s"\n'      "$(mdm_json_escape "$MDM_RCPT_LOG_PATH")"
    printf '}\n'
  } > "$_tmp" || { _mdm_receipt_discard_prepared || true; return 1; }
  # 信頼チェーン成立 dir 内の一時ファイルなので chmod のパス指定は安全
  # （攻撃者が dir 内エントリを差し替えられない）。失敗は fail-closed（R5-High）。
  if ! chmod 600 "$_tmp" 2>/dev/null; then
    _mdm_receipt_discard_prepared || true
    mdm_log R4 "レシートの権限設定に失敗（fail-closed）: $_tmp"
    return 1
  fi
  local _meta _rest _links _mode
  [[ -f "$_tmp" && ! -L "$_tmp" ]] \
    || { _mdm_receipt_discard_prepared || true; return 1; }
  if [[ "$_euid" -eq 0 ]]; then
    _mdm_component_trusted "$_tmp" \
      || { _mdm_receipt_discard_prepared || true; return 1; }
  fi
  _meta="$(_mdm_stat_managed_metadata "$_tmp")" \
    || { _mdm_receipt_discard_prepared || true; return 1; }
  [[ "$_meta" =~ ^[0-9]+:[0-9]+:[0-7]+$ ]] \
    || { _mdm_receipt_discard_prepared || true; return 1; }
  _rest="${_meta#*:}"; _links="${_rest%%:*}"
  _mode="$(_mdm_mode_normalize "${_rest#*:}")" \
    || { _mdm_receipt_discard_prepared || true; return 1; }
  if _mdm_has_extended_acl "$_tmp" \
    || [[ "$_links" != 1 || "$_mode" != 0600 ]]; then
    _mdm_receipt_discard_prepared || true
    return 1
  fi
  _mdm_json_valid "$_tmp" \
    && _mdm_generated_receipt_is_exact "$_tmp" "$_path" "$_result" "$_exit" \
    || { _mdm_receipt_discard_prepared || true; return 1; }
  _mdm_receipt_prepared_ready
}

mdm_receipt_write() {
  mdm_receipt_prepare "$@" \
    && _mdm_receipt_prepared_ready \
    && _mdm_receipt_publish_prepared \
    || { _mdm_receipt_discard_prepared || true; return 1; }
}

# scutil の record は producer が成功した場合だけ採用する。parser は EOF まで
# 読み、重複 Name や空白/制御文字を含む値を曖昧な record として拒否する。
_mdm_read_console_user_record() {
  printf 'show State:/Users/ConsoleUser\n' | /usr/sbin/scutil 2>/dev/null
}

_mdm_parse_console_user_record() {
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

# コンソールユーザーを取得（テスト時は MDM_CONSOLE_USER_OVERRIDE を優先）
_mdm_console_user() {
  if [[ -n "${MDM_CONSOLE_USER_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_CONSOLE_USER_OVERRIDE"; return 0
  fi
  # pipefail により scutil の非0終了も assignment の失敗として扱う。
  local _u=""
  if _u="$(_mdm_read_console_user_record | _mdm_parse_console_user_record)"; then
    printf '%s' "$_u"
    return 0
  fi
  _u="$(_mdm_stat_owner /dev/console 2>/dev/null || true)"
  printf '%s' "$_u"
}

# dscl の UniqueID record を EOF まで読み、単一の10進値だけを受理する。
_mdm_parse_dscl_uid() {
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

# 対象ユーザーの UID を dscl で取得（実在確認を兼ねる）。
# テスト時は MDM_DSCL_UID_OVERRIDE でモック可能。解決不能なら非0を返す。
_mdm_user_uid() {
  local _user="$1" _uid
  if [[ -n "${MDM_DSCL_UID_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_DSCL_UID_OVERRIDE"; return 0
  fi
  _uid="$(dscl . -read "/Users/$_user" UniqueID 2>/dev/null \
    | _mdm_parse_dscl_uid)" || return 1
  printf '%s' "$_uid"
}

# Directory Services へ問い合わせる requested name/alias は、パス区切りや
# shell metacharacter を含まない safe ASCII に限る。Apple ID 系の長い
# RecordName alias を受けられるよう、short name の 32 byte 制約は課さない。
_mdm_requested_username_is_safe() {
  local _user="$1"
  [[ ${#_user} -ge 1 && ${#_user} -le 255 ]] || return 1
  [[ "$_user" =~ ^[A-Za-z0-9_][A-Za-z0-9_.@+-]*$ ]] || return 1
  [[ "$_user" != . && "$_user" != .. ]]
}

# MDM artifact 名へ埋め込む canonical macOS short name は、従来どおり
# 32 byte 以下の厳しい grammar に限る。
_mdm_canonical_username_is_safe() {
  local _user="$1"
  [[ ${#_user} -ge 1 && ${#_user} -le 32 ]] || return 1
  [[ "$_user" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*([.@][A-Za-z0-9_-]+)*$ ]]
}

_mdm_username_not_reserved() {
  local _user="$1" _lower
  _lower="$(printf '%s' "$_user" | /usr/bin/tr '[:upper:]' '[:lower:]')" \
    || return 1
  case "$_lower" in
    ''|root|_mbsetupuser|_unresolved|loginwindow|daemon|nobody) return 1 ;;
  esac
  return 0
}

_mdm_requested_username_is_allowed() {
  _mdm_requested_username_is_safe "$1" && _mdm_username_not_reserved "$1"
}

_mdm_canonical_username_is_allowed() {
  _mdm_canonical_username_is_safe "$1" && _mdm_username_not_reserved "$1"
}

# Resolve only the short name here.  Production identity is subsequently read
# as one UniqueID+GeneratedUID record from each dscl domain; doing a separate
# UID lookup here would mix account generations across multiple reads.
_mdm_resolve_target_username() { # <user-output-var>
  local _target_out_var="$1" _candidate="${KIT_MDM_TARGET_USER:-}"
  [[ "$_target_out_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return "$MDM_EXIT_USER"
  [[ -z "$_candidate" ]] && _candidate="$(_mdm_console_user)"
  if ! _mdm_requested_username_is_allowed "$_candidate"; then
    mdm_log R2 "対象ユーザー名が不正または予約済み: '$_candidate'"
    return "$MDM_EXIT_USER"
  fi
  printf -v "$_target_out_var" '%s' "$_candidate"
  return 0
}

# Compatibility helper retained for direct callers/tests.  The main root flow
# uses _mdm_resolve_target_username + _mdm_bind_target_identity_tuple instead.
_mdm_resolve_target_identity() { # <user-output-var> <uid-output-var>
  local _out_user="$1" _out_uid="$2" _u="" _uid
  [[ "$_out_user" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_out_uid" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_out_user" != "$_out_uid" ]] || return "$MDM_EXIT_USER"
  _mdm_resolve_target_username _u || return $?
  if ! _uid="$(_mdm_user_uid "$_u")"; then
    mdm_log R2 "対象ユーザーが実在しない（dscl で解決不能）: '$_u'"
    return "$MDM_EXIT_USER"
  fi
  if ! printf '%s' "$_uid" | grep -qE '^[0-9]+$'; then
    mdm_log R2 "対象ユーザーが実在しない（dscl で解決不能）: '$_u'"
    return "$MDM_EXIT_USER"
  fi
  if [[ "$_uid" -lt 501 ]]; then
    mdm_log R2 "対象ユーザーの UID がシステム領域（<501）: '$_u' (uid=$_uid)"
    return "$MDM_EXIT_USER"
  fi
  printf -v "$_out_user" '%s' "$_u"
  printf -v "$_out_uid" '%s' "$_uid"
  return 0
}

# 互換用 wrapper。production は UID も必要なので上の identity resolver を直接使う。
mdm_resolve_target_user() {
  local _resolved_user="" _resolved_uid=""
  _mdm_resolve_target_identity _resolved_user _resolved_uid || return $?
  printf '%s' "$_resolved_user"
}

_mdm_search_policy_uid() {
  /usr/bin/id -u "$1" 2>/dev/null
}

# local domain の dscl UID と macOS search policy の UID を束縛する。
_mdm_bind_target_uid() { # <user> <local-dscl-uid>
  local _user="$1" _local_uid="$2" _search_uid
  _search_uid="$(_mdm_search_policy_uid "$_user")" || return 1
  [[ "$_local_uid" =~ ^[0-9]+$ && "$_search_uid" =~ ^[0-9]+$ ]] || return 1
  [[ ${#_local_uid} -le 10 && ${#_search_uid} -le 10 ]] || return 1
  [[ "$_local_uid" == "$_search_uid" && "$_search_uid" -ge 501 ]] || return 1
  printf '%s' "$_search_uid"
}

# 対象ユーザーの canonical home を取得・検証。dscl はモック可能。
_mdm_parse_dscl_home() {
  LC_ALL=C /usr/bin/awk '
    BEGIN { state = "key"; bad = 0 }

    state == "key" && $0 == "NFSHomeDirectory:" {
      state = "continuation"
      next
    }

    state == "key" && $0 ~ /^NFSHomeDirectory:[ \t]/ {
      value = substr($0, length("NFSHomeDirectory:") + 2)
      # dscl documents whitespace-separated same-line output as multiple
      # values. A single value containing spaces uses a continuation line.
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

_mdm_parse_dscl_generated_uid() {
  LC_ALL=C /usr/bin/awk '
    BEGIN { state = "key"; bad = 0 }
    state == "key" && $0 == "GeneratedUID:" { state = "continuation"; next }
    state == "key" && $0 ~ /^GeneratedUID:[ \t]/ {
      value = substr($0, length("GeneratedUID:") + 2); state = "done"; next
    }
    state == "continuation" && $0 ~ /^[ \t]/ {
      value = substr($0, 2); state = "done"; next
    }
    { bad = 1 }
    END {
      if (!bad && state == "done" && value ~ /^[0-9A-Fa-f-]+$/) {
        print value; exit 0
      }
      exit 1
    }
  '
}

_mdm_normalize_generated_uid() {
  local _value
  _value="$(printf '%s' "$1" | /usr/bin/tr '[:lower:]' '[:upper:]')" || return 1
  [[ "$_value" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ ]] \
    || return 1
  [[ "$_value" != 00000000-0000-0000-0000-000000000000 ]] || return 1
  printf '%s' "$_value"
}

_mdm_local_generated_uid() {
  local _user="$1" _value
  if [[ "${_MDM_TEST_MODE:-0}" == 1 && -n "${MDM_DSCL_GENERATED_UID_OVERRIDE:-}" ]]; then
    _mdm_normalize_generated_uid "$MDM_DSCL_GENERATED_UID_OVERRIDE"
    return
  fi
  _value="$(/usr/bin/dscl . -read "/Users/$_user" GeneratedUID 2>/dev/null \
    | _mdm_parse_dscl_generated_uid)" || return 1
  _mdm_normalize_generated_uid "$_value"
}

_mdm_search_generated_uid() {
  local _user="$1" _value
  if [[ "${_MDM_TEST_MODE:-0}" == 1 ]]; then
    if [[ -n "${MDM_SEARCH_GENERATED_UID_OVERRIDE:-}" ]]; then
      _mdm_normalize_generated_uid "$MDM_SEARCH_GENERATED_UID_OVERRIDE"
      return
    fi
    if [[ -n "${MDM_DSCL_GENERATED_UID_OVERRIDE:-}" ]]; then
      _mdm_normalize_generated_uid "$MDM_DSCL_GENERATED_UID_OVERRIDE"
      return
    fi
  fi
  _value="$(/usr/bin/dscl /Search -read "/Users/$_user" GeneratedUID 2>/dev/null \
    | _mdm_parse_dscl_generated_uid)" || return 1
  _mdm_normalize_generated_uid "$_value"
}

_mdm_bind_target_generated_uid() {
  local _user="$1" _local _search
  _local="$(_mdm_local_generated_uid "$_user")" || return 1
  _search="$(_mdm_search_generated_uid "$_user")" || return 1
  [[ "$_local" == "$_search" ]] || return 1
  printf '%s' "$_local"
}

# Parse one dscl record containing both account-generation attributes.  The
# local and search-policy domains are each read once so UID/GeneratedUID cannot
# be mixed across separate record generations.
_mdm_parse_dscl_identity_record() {
  LC_ALL=C /usr/bin/awk '
    BEGIN { pending = ""; uid_seen = 0; guid_seen = 0; bad = 0 }
    function guid_is_canonical(value, compact) {
      if (length(value) != 36 \
          || substr(value, 9, 1) != "-" \
          || substr(value, 14, 1) != "-" \
          || substr(value, 19, 1) != "-" \
          || substr(value, 24, 1) != "-") return 0
      compact = value
      gsub(/-/, "", compact)
      return length(compact) == 32 && compact ~ /^[0-9A-Fa-f]+$/
    }
    $0 == "UniqueID:" || $0 == "GeneratedUID:" {
      if (pending != "") bad = 1
      pending = substr($0, 1, length($0) - 1)
      next
    }
    $0 ~ /^(UniqueID|GeneratedUID):[ \t]/ {
      key = $0; sub(/:.*/, "", key)
      # key excludes the colon: skip both ":" and exactly one delimiter.
      # Any additional whitespace remains in value and fails validation.
      value = substr($0, length(key) + 3)
      if (pending != "") bad = 1
      if (key == "UniqueID") {
        if (uid_seen) bad = 1; uid = value; uid_seen = 1
      } else {
        if (guid_seen) bad = 1; guid = value; guid_seen = 1
      }
      next
    }
    $0 ~ /^[ \t]/ {
      value = substr($0, 2)
      if (pending == "UniqueID") {
        if (uid_seen) bad = 1; uid = value; uid_seen = 1
      } else if (pending == "GeneratedUID") {
        if (guid_seen) bad = 1; guid = value; guid_seen = 1
      } else bad = 1
      pending = ""
      next
    }
    { bad = 1 }
    END {
      if (!bad && pending == "" && uid_seen == 1 && guid_seen == 1 \
          && uid ~ /^[0-9]+$/ && length(uid) <= 10 \
          && !(length(uid) > 1 && substr(uid, 1, 1) == "0") \
          && guid_is_canonical(guid)) {
        print uid "\t" guid; exit 0
      }
      exit 1
    }
  '
}

_mdm_read_local_identity_record() {
  /usr/bin/dscl . -read "/Users/$1" UniqueID GeneratedUID 2>/dev/null
}

_mdm_read_search_identity_record() {
  /usr/bin/dscl /Search -read "/Users/$1" UniqueID GeneratedUID 2>/dev/null
}

_mdm_bind_target_identity_tuple() { # <user> [expected-uid]
  local _user="$1" _expected_uid="${2:-}" _local _search
  local _local_uid _search_uid _local_guid _search_guid
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && -n "${MDM_DSCL_UID_OVERRIDE:-}" \
    && -n "${MDM_DSCL_GENERATED_UID_OVERRIDE:-}" ]]; then
    _local_uid="$MDM_DSCL_UID_OVERRIDE"
    _search_uid="${MDM_SEARCH_UID_OVERRIDE:-$MDM_DSCL_UID_OVERRIDE}"
    _local_guid="$MDM_DSCL_GENERATED_UID_OVERRIDE"
    _search_guid="${MDM_SEARCH_GENERATED_UID_OVERRIDE:-$MDM_DSCL_GENERATED_UID_OVERRIDE}"
  else
    _local="$(_mdm_read_local_identity_record "$_user" \
      | _mdm_parse_dscl_identity_record)" || return 1
    _search="$(_mdm_read_search_identity_record "$_user" \
      | _mdm_parse_dscl_identity_record)" || return 1
    _local_uid="${_local%%$'\t'*}"; _local_guid="${_local#*$'\t'}"
    _search_uid="${_search%%$'\t'*}"; _search_guid="${_search#*$'\t'}"
  fi
  [[ "$_local_uid" =~ ^[0-9]+$ && "$_search_uid" =~ ^[0-9]+$ \
    && "$_local_uid" == "$_search_uid" \
    && ( -z "$_expected_uid" || "$_local_uid" == "$_expected_uid" ) \
    && "$_local_uid" -ge 501 && ${#_local_uid} -le 10 ]] || return 1
  _local_guid="$(_mdm_normalize_generated_uid "$_local_guid")" || return 1
  _search_guid="$(_mdm_normalize_generated_uid "$_search_guid")" || return 1
  [[ "$_local_guid" == "$_search_guid" ]] || return 1
  printf '%s\t%s' "$_local_uid" "$_local_guid"
}

# Parse exactly one dscacheutil user record.  Only name/uid are authoritative;
# the remaining standard Directory Services fields are syntactically checked
# and ignored.  In particular, a numeric username can never be mistaken for a
# UID because lookup is performed with the explicit `-a uid` predicate.
_mdm_parse_dscacheutil_user_for_uid() { # <expected-uid>
  local _expected_uid="$1"
  [[ "$_expected_uid" =~ ^(0|[1-9][0-9]*)$ \
    && ${#_expected_uid} -le 10 ]] || return 1
  LC_ALL=C /usr/bin/awk -v expected="$_expected_uid" '
    BEGIN {
      active = 0; records = 0; name_seen = 0; uid_seen = 0; bad = 0
    }
    function finish_record() {
      if (!active) return
      records++
      active = 0
    }
    $0 == "" { finish_record(); next }
    {
      active = 1
      if ($0 ~ /[[:cntrl:]]/) { bad = 1; next }
      if ($0 ~ /^name:/) {
        if ($0 !~ /^name: [^[:space:]][^[:cntrl:]]*$/ || name_seen) {
          bad = 1; next
        }
        name = substr($0, length("name: ") + 1)
        name_seen++
        next
      }
      if ($0 ~ /^uid:/) {
        if ($0 !~ /^uid: (0|[1-9][0-9]*)$/ || uid_seen) {
          bad = 1; next
        }
        uid = substr($0, length("uid: ") + 1)
        uid_seen++
        next
      }
      # Other normal fields are data only, but still require a field name and
      # the exact dscacheutil colon delimiter shape.
      if ($0 !~ /^[A-Za-z][A-Za-z0-9_-]*:($| [^[:cntrl:]]*)$/) bad = 1
    }
    END {
      finish_record()
      if (!bad && records == 1 && name_seen == 1 && uid_seen == 1 \
          && uid == expected && length(uid) <= 10) {
        print name
        exit 0
      }
      exit 1
    }
  '
}

_mdm_read_search_user_for_uid() { # <uid>
  /usr/bin/dscacheutil -q user -a uid "$1" 2>/dev/null
}

# Resolve the search-policy canonical short name from the already-bound UID.
# The requested spelling is never lowercased into an account name: macOS
# Directory Services remains authoritative for case and aliases.
_mdm_search_policy_username_for_uid() { # <uid>
  local _uid="$1" _record
  [[ "$_uid" =~ ^[0-9]+$ && "$_uid" -ge 501 && ${#_uid} -le 10 \
    && ! ( ${#_uid} -gt 1 && "${_uid:0:1}" == 0 ) ]] || return 1
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && -n "${MDM_CANONICAL_USER_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_CANONICAL_USER_OVERRIDE"
    return 0
  fi
  _record="$(_mdm_read_search_user_for_uid "$_uid")" || return 1
  printf '%s\n' "$_record" | _mdm_parse_dscacheutil_user_for_uid "$_uid"
}

_mdm_bind_canonical_target_username() { # <output-var> <requested-user> <uid> <generated-uid>
  local _out_var="$1" _requested="$2" _uid="$3" _generated_uid="$4"
  local _canonical _tuple _requested_home _canonical_home
  [[ "$_out_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  _mdm_requested_username_is_allowed "$_requested" || return 1
  _canonical="$(_mdm_search_policy_username_for_uid "$_uid")" || return 1
  _mdm_canonical_username_is_allowed "$_canonical" || return 1
  _tuple="$(_mdm_bind_target_identity_tuple "$_canonical" "$_uid")" || return 1
  [[ "$_tuple" == "$_uid"$'\t'"$_generated_uid" ]] || return 1
  if [[ "$_requested" != "$_canonical" ]]; then
    _requested_home="$(mdm_validate_user_home "$_requested" "$_uid")" || return 1
    _canonical_home="$(mdm_validate_user_home "$_canonical" "$_uid")" || return 1
    [[ "$_requested_home" == "$_canonical_home" ]] || return 1
  fi
  printf -v "$_out_var" '%s' "$_canonical"
  return 0
}

_mdm_parse_dscl_shell() {
  LC_ALL=C /usr/bin/awk '
    BEGIN { state = "key"; bad = 0 }
    state == "key" && $0 == "UserShell:" { state = "continuation"; next }
    state == "key" && $0 ~ /^UserShell:[ \t]/ {
      value = substr($0, length("UserShell:") + 2); state = "done"; next
    }
    state == "continuation" && $0 ~ /^[ \t]/ {
      value = substr($0, 2); state = "done"; next
    }
    { bad = 1 }
    END {
      if (!bad && state == "done" && value ~ /^\/[A-Za-z0-9._+\/-]+$/) {
        print value; exit 0
      }
      exit 1
    }
  '
}

_mdm_resolve_user_shell_path() { # <absolute-shell-path>
  local _shell="$1" _canonical
  [[ "$_shell" == /* && ! "$_shell" =~ [[:cntrl:][:space:]] ]] || return 1
  _canonical="$(_mdm_canonical_any "$_shell")" || return 1
  [[ "$_canonical" == /* && ! "$_canonical" =~ [[:cntrl:][:space:]] \
    && -f "$_canonical" && ! -L "$_canonical" && -x "$_canonical" ]] || return 1
  printf '%s' "$_canonical"
}

_mdm_user_shell() {
  local _user="$1" _shell
  if [[ "${_MDM_TEST_MODE:-0}" == 1 && -n "${MDM_USER_SHELL_OVERRIDE:-}" ]]; then
    _shell="$MDM_USER_SHELL_OVERRIDE"
  else
    _shell="$(/usr/bin/dscl . -read "/Users/$_user" UserShell 2>/dev/null \
      | _mdm_parse_dscl_shell)" || return 1
  fi
  [[ "$_shell" == /* && ! "$_shell" =~ [[:cntrl:][:space:]] ]] || return 1
  if [[ "${_MDM_TEST_MODE:-0}" != 1 ]]; then
    _shell="$(_mdm_resolve_user_shell_path "$_shell")" || return 1
  fi
  printf '%s' "$_shell"
}

_mdm_user_dir_acl_safe() { # <user-owned-directory>
  local _dir="$1" _listing _first _permissions _rest
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
  [[ "$_permissions" == *@ || "$_permissions" == *+ ]] || return 1
  _rest="${_listing#*$'\n'}"
  [[ "$_rest" != *$'\n'* \
    && "$_rest" =~ ^[[:space:]]*0:[[:space:]]+group:everyone[[:space:]]+deny[[:space:]]+delete$ ]]
}

_mdm_user_home_acl_safe() { # <home>
  _mdm_user_dir_acl_safe "$1"
}

mdm_validate_user_home() {
  local _user="$1" _expected_uid="${2:-}" _home _canonical _mode
  if [[ -n "${MDM_DSCL_HOME_OVERRIDE:-}" ]]; then
    _home="$MDM_DSCL_HOME_OVERRIDE"
  else
    if ! _home="$(dscl . -read "/Users/$_user" NFSHomeDirectory 2>/dev/null \
      | _mdm_parse_dscl_home)"; then
      mdm_log R2 "home を dscl から一意に解決できない"
      return "$MDM_EXIT_USER"
    fi
  fi
  if [[ -z "$_home" || ! -d "$_home" ]]; then
    mdm_log R2 "home が存在しない: '$_home'"
    return "$MDM_EXIT_USER"
  fi
  if [[ -L "$_home" ]]; then
    mdm_log R2 "home が symlink: $_home"
    return "$MDM_EXIT_USER"
  fi
  _canonical="$(builtin cd -P -- "$_home" 2>/dev/null && printf '%s' "$PWD")" \
    || return "$MDM_EXIT_USER"
  if [[ "$_canonical" != "$_home" ]]; then
    mdm_log R2 "home が canonical path でない: $_home"
    return "$MDM_EXIT_USER"
  fi
  _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_home")")" \
    || return "$MDM_EXIT_USER"
  if ! _mdm_mode_is_safe "$_mode" \
    || ! _mdm_mode_owner_executable "$_mode" \
    || ! _mdm_user_home_acl_safe "$_home"; then
    mdm_log R2 "home の mode/ACL が管理境界として不正: $_home"
    return "$MDM_EXIT_USER"
  fi
  if [[ "${MDM_VALIDATE_HOME_SKIP_OWNER:-0}" != "1" ]]; then
    if [[ -n "$_expected_uid" ]]; then
      local _owner_uid
      _owner_uid="$(_mdm_stat_uid "$_home" 2>/dev/null || true)"
      if [[ ! "$_expected_uid" =~ ^[0-9]+$ || "$_owner_uid" != "$_expected_uid" ]]; then
        mdm_log R2 "home の所有 UID が対象ユーザーと一致しない: $_owner_uid"
        return "$MDM_EXIT_USER"
      fi
    else
      local _owner
      _owner="$(_mdm_stat_owner "$_home" 2>/dev/null || true)"
      if [[ "$_owner" != "$_user" ]]; then
        mdm_log R2 "home の所有者が対象ユーザーでない: $_owner"
        return "$MDM_EXIT_USER"
      fi
    fi
  fi
  printf '%s' "$_canonical"
}

# ref を確定 SHA に解決。install.sh は再実行せず wrapper が直接管理する。
mdm_resolve_ref_sha() {
  local _repo="$1" _ref="$2" _remote_url="${3:-}" _sha
  # 形式検証（SHA or check-ref-format --branch）
  if ! _mdm_boot_validate_gitref "$_ref" >/dev/null 2>&1; then
    mdm_log U1b "不正な git ref 形式: $_ref"
    return "$MDM_EXIT_CONFIG"
  fi
  # Production always fetches from the fixed official URL passed by the
  # caller.  Never trust an existing checkout's user-editable origin or local
  # URL rewrite configuration as the authority for a managed ref.
  # NOTE: --verify 必須。無指定の `git rev-parse <ref>` は解決失敗時でも
  # 引数文字列をそのまま stdout へ echo して返す（exit code は非0でも stdout
  # が非空になる）ため、後段の `[[ -z "$_sha" ]]` チェックをすり抜けて
  # 未解決 ref をそのまま「確定 SHA」として誤って返してしまう（実機検証済み）。
  # --verify は失敗時に stdout を空にする。
  # git は _mdm_git 経由（root 時は検証済みユーザーへ降格。Critical#2）
  if [[ -n "$_remote_url" ]]; then
    _mdm_git_network -C "$_repo" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
      fetch --quiet "$_remote_url" "$_ref" 2>/dev/null || return "$MDM_EXIT_SETUP"
    _sha="$(_mdm_git -C "$_repo" rev-parse --verify "FETCH_HEAD^{commit}" 2>/dev/null || true)"
  elif printf '%s' "$_ref" | grep -qE '^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$'; then
    _sha="$(_mdm_git -C "$_repo" rev-parse --verify "${_ref}^{commit}" 2>/dev/null || true)"
  else
    # 明示 fetch → FETCH_HEAD の commit を真実とする（ローカル ref を更新しないことがあるため）
    if ! _mdm_git_network -C "$_repo" fetch --quiet origin "$_ref" 2>/dev/null; then
      # origin が無い（初回 clone 前のローカルテスト）場合はローカル ref 解決にフォールバック
      _sha="$(_mdm_git -C "$_repo" rev-parse --verify "${_ref}^{commit}" 2>/dev/null || true)"
    else
      _sha="$(_mdm_git -C "$_repo" rev-parse --verify "FETCH_HEAD^{commit}" 2>/dev/null || true)"
    fi
  fi
  if [[ -z "$_sha" ]]; then
    # U1b はキット取得と ref ピン留めのフェーズ。
    mdm_log U1b "ref を解決できない: $_ref"
    return "$MDM_EXIT_SETUP"
  fi
  printf '%s' "$_sha"
  return 0
}

# ── 前提ブートストラップの判定（brew 有無・CLT 方針）──────
# brew 有無検知。MDM_BREW_PRESENT_OVERRIDE でテスト時にモック可能（"1"=あり/それ以外=なし）。
_mdm_brew_present() {
  if [[ -n "${MDM_BREW_PRESENT_OVERRIDE:-}" ]]; then
    [[ "$MDM_BREW_PRESENT_OVERRIDE" == "1" ]]; return
  fi
  [[ -x /opt/homebrew/bin/brew || -x /usr/local/bin/brew ]] || command -v brew >/dev/null 2>&1
}

# 対象ユーザーでの brew usability × KIT_MDM_INSTALL_HOMEBREW ×
# KIT_MDM_PREREQ_MODE から方針を決定し stdout へ。引数省略時の実体検知と
# PREREQ_MODE=skip は source-only テスト互換用。
mdm_prereq_plan() {
  local _brew_usable="${1:-}"
  if [[ -z "$_brew_usable" ]]; then
    if _mdm_brew_present; then _brew_usable=true; else _brew_usable=false; fi
  fi
  [[ "$_brew_usable" == true || "$_brew_usable" == false ]] || return 1
  case "${KIT_MDM_PREREQ_MODE:-auto}" in
    skip) printf 'skip'; return 0 ;;
    fail)
      if [[ "$_brew_usable" == true ]]; then printf 'skip'; else printf 'fail'; fi
      return 0 ;;
  esac
  if [[ "$_brew_usable" == true ]]; then printf 'skip'; return 0; fi
  case "$(_mdm_root_bool "${KIT_MDM_INSTALL_HOMEBREW:-true}" 2>/dev/null || echo true)" in
    true) printf 'bootstrap' ;;
    *)    printf 'fail' ;;
  esac
  return 0
}

# 降格実行時に対象ユーザーへ引き継ぐ環境変数の許可リスト（env -i で root 環境を
# 継承しないため、渡すものだけを明示列挙する。
_MDM_PASSTHROUGH_KEYS="PROFILE LANGUAGE EDITOR_CHOICE COMMIT_ATTRIBUTION \
ENABLE_NEW_INIT INSTALL_AGENTS INSTALL_RULES INSTALL_COMMANDS INSTALL_SKILLS \
ENABLE_CODEX_PLUGIN ENABLE_TMUX_HOOKS ENABLE_DOC_BLOCKER ENABLE_PRETTIER_HOOKS \
ENABLE_BIOME_HOOKS ENABLE_PR_CREATION_LOG ENABLE_PRE_COMPACT_COMMIT \
ENABLE_SAFETY_NET ENABLE_AUTO_UPDATE ENABLE_WEB_CONTENT_UPDATE ENABLE_STATUSLINE \
ENABLE_GHOSTTY_SETUP ENABLE_FONTS_SETUP ENABLE_DOC_SIZE_GUARD ENABLE_NO_FLICKER \
ENABLE_FEATURE_RECOMMENDATION ENABLE_AGENT_TEAMS \
KIT_MDM_GIT_REF KIT_MDM_INSTALL_DIR KIT_MDM_INSTALL_CLAUDE_CLI KIT_MDM_DRY_RUN \
KIT_MDM_PREREQ_MODE \
HTTP_PROXY HTTPS_PROXY NO_PROXY"

# LANGUAGE（en/ja。本体の実キー値）を POSIX ロケール名へ変換する。
# 旧実装は "LANG=${LANGUAGE}_JP.UTF-8" と決め打ちしており
# LANGUAGE=en のとき不正ロケール "en_JP.UTF-8" を生成していた。正しくマップする。
_mdm_lang_to_locale() {
  case "${1:-}" in
    en) printf 'en_US.UTF-8' ;;
    ja) printf 'ja_JP.UTF-8' ;;
    *)  printf 'C.UTF-8' ;;
  esac
}

# 降格 argv をグローバル配列 MDM_DROP_ARGV へ直接構築する。
# 旧実装の「改行区切り stdout → read -r で配列化」は、改行を含む値（env 由来
# EDITOR_CHOICE 等）が env のコマンド位置に落ちて任意コマンド実行になり得たため
# 廃止。シリアライズ/再パースを一切行わず、値は常に単一の配列要素として保持する。
# 多層防御として、制御文字（改行/CR/タブ等）を含む passthrough 値は拒否する。
# 引数 $4 以降は実行するコマンド argv（インタプリタ込みで呼び出し側が絶対パス指定）。
MDM_DROP_ARGV=()
_MDM_GIT_SAFE_DIRECTORY=""
_MDM_WCE_VERIFIED_BUNDLE=""
_MDM_WCE_CARRIER_ACTIVE=false
_MDM_OUTER_TRANSACTION_ACTIVE=false
_MDM_OUTER_TRANSACTION_BACKUP=""
mdm_build_drop_argv() {
  local _uid="$1" _user="$2" _home="$3"; shift 3
  local _nodebin="" _brewbin="" _tool_bins="" _shell="${_MDM_TARGET_SHELL:-/bin/bash}"
  [[ "$_shell" == /* && ! "$_shell" =~ [[:cntrl:][:space:]] ]] || return 1
  case "${KIT_MDM_REQUIRE_NODE_RUNTIME:-false}" in
    true)
      _nodebin="$(_mdm_node_runtime_bin)" || return 1
      [[ -d "$_nodebin" && ! -L "$_nodebin" ]] || return 1
      _nodebin="${_nodebin}:" ;;
    false) : ;;
    *) return 1 ;;
  esac
  [[ -x /opt/homebrew/bin/brew ]] && _brewbin="/opt/homebrew/bin:"
  [[ -x /usr/local/bin/brew ]] && _brewbin="${_brewbin}/usr/local/bin:"
  local _candidate
  for _candidate in \
    /opt/homebrew/opt/node@24/bin /usr/local/opt/node@24/bin \
    /opt/homebrew/opt/gnu-sed/libexec/gnubin /usr/local/opt/gnu-sed/libexec/gnubin \
    /opt/homebrew/opt/gawk/libexec/gnubin /usr/local/opt/gawk/libexec/gnubin; do
    [[ -d "$_candidate" && ! -L "$_candidate" ]] || continue
    _tool_bins="${_tool_bins}${_candidate}:"
  done
  MDM_DROP_ARGV=(
    /usr/bin/env -i
    "HOME=$_home"
    "USER=$_user"
    "LOGNAME=$_user"
    "SHELL=$_shell"
    "PATH=${_nodebin}${_brewbin}${_tool_bins}/usr/bin:/bin:/usr/sbin:/sbin"
    "GIT_CONFIG_NOSYSTEM=1"
    "GIT_CONFIG_GLOBAL=/dev/null"
    "GIT_TERMINAL_PROMPT=0"
    "GIT_NO_REPLACE_OBJECTS=1"
    "GIT_OPTIONAL_LOCKS=0"
    # MDM 管理マーカー: setup.sh（wizard）が update/fresh の設定復元後に
    # MDM 注入 env を再適用するためのフラグ（固定値・R2-High）
    "KIT_MDM_MANAGED=true"
    # MDMの独立期待値レンダラーとsetupのhook schemaを固定する内部値。
    # 公開設定にはせず、互換性を優先してlegacy schemaへ収束させる。
    "KIT_MDM_ASYNC_HOOKS=false"
    "KIT_MDM_REQUIRE_NODE_RUNTIME=${KIT_MDM_REQUIRE_NODE_RUNTIME:-false}"
  )
  case "${_MDM_OUTER_TRANSACTION_ACTIVE:-false}" in
    true)
      # Internal carrier: only the root-owned outer installer may suppress the
      # setup layer backup. It is deliberately absent from every config and
      # passthrough allowlist.
      MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="KIT_MDM_OUTER_TRANSACTION=true"
      if [[ -n "${_MDM_OUTER_TRANSACTION_BACKUP:-}" ]]; then
        [[ "$_MDM_OUTER_TRANSACTION_BACKUP" == "$_home"/.claude.mdm-backup.* \
          && -d "$_MDM_OUTER_TRANSACTION_BACKUP" \
          && ! -L "$_MDM_OUTER_TRANSACTION_BACKUP" ]] \
          || { MDM_DROP_ARGV=(); return 1; }
        MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="KIT_MDM_OUTER_TRANSACTION_BACKUP=$_MDM_OUTER_TRANSACTION_BACKUP"
      fi ;;
    false) : ;;
    *) MDM_DROP_ARGV=(); return 1 ;;
  esac
  if [[ "$(_mdm_root_bool "${KIT_MDM_INSTALL_CLAUDE_CLI:-true}" 2>/dev/null || echo true)" == true ]]; then
    MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="KIT_MDM_REQUIRE_NATIVE_CLAUDE_CLI=true"
  fi
  if [[ -n "${KIT_MDM_POLICY_SHA256:-}" ]]; then
    [[ "$KIT_MDM_POLICY_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
    MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="KIT_MDM_POLICY_SHA256=$KIT_MDM_POLICY_SHA256"
  fi
  case "${_MDM_WCE_CARRIER_ACTIVE:-false}" in
    true)
      local _wce_expected
      _wce_expected="$(_mdm_wce_runtime_path)" \
        || { MDM_DROP_ARGV=(); return 1; }
      [[ -n "${_MDM_WCE_VERIFIED_BUNDLE:-}" \
        && "$_MDM_WCE_VERIFIED_BUNDLE" == "$_wce_expected" \
        && "${_MDM_EXPECTED_WCE_COMPONENT_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] \
        || { MDM_DROP_ARGV=(); return 1; }
      _MDM_WCE_RUNTIME_DIGEST=""
      _mdm_wce_runtime_trusted "$_MDM_WCE_VERIFIED_BUNDLE" \
        || { MDM_DROP_ARGV=(); return 1; }
      [[ "$_MDM_WCE_RUNTIME_DIGEST" \
        == "$_MDM_EXPECTED_WCE_COMPONENT_SHA256" ]] \
        || { MDM_DROP_ARGV=(); return 1; }
      MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="KIT_MDM_WCE_RUNTIME_BUNDLE=$_MDM_WCE_VERIFIED_BUNDLE" ;;
    false) : ;;
    *) MDM_DROP_ARGV=(); return 1 ;;
  esac
  if [[ -n "${_MDM_GIT_SAFE_DIRECTORY:-}" ]]; then
    if [[ "$_MDM_GIT_SAFE_DIRECTORY" != /* ]] \
      || [[ "$_MDM_GIT_SAFE_DIRECTORY" =~ [[:cntrl:]] ]]; then
      mdm_log R1 "safe.directory の内部値が不正"
      MDM_DROP_ARGV=()
      return 1
    fi
    # Ephemeral command environment only: never write a target user's or
    # root's Git config file.  Exactly the authoritative checkout is trusted.
    MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="GIT_CONFIG_COUNT=1"
    MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="GIT_CONFIG_KEY_0=safe.directory"
    MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="GIT_CONFIG_VALUE_0=$_MDM_GIT_SAFE_DIRECTORY"
  fi
  if [[ -n "${_MDM_PRIOR_INVENTORY:-}" ]]; then
    _mdm_managed_tmp_path_matches \
      "$_MDM_PRIOR_INVENTORY" claude-kit-mdm-prior \
      || { MDM_DROP_ARGV=(); return 1; }
    _mdm_component_trusted "$_MDM_PRIOR_INVENTORY" \
      || { MDM_DROP_ARGV=(); return 1; }
    MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="KIT_MDM_PRIOR_MANAGED_INVENTORY=$_MDM_PRIOR_INVENTORY"
  fi
  if [[ -n "${LANGUAGE:-}" ]]; then
    MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="LANG=$(_mdm_lang_to_locale "$LANGUAGE")"
  fi
  local _k _v
  for _k in $_MDM_PASSTHROUGH_KEYS; do
    _v="${!_k:-}"
    [[ -z "$_v" ]] && continue
    # 制御文字を含む値は不正として拒否（多層防御。printf %q 等での温存もしない）。
    # NOTE: grep は改行を行区切りとして扱い改行そのものを検出できないため、
    # 文字列全体を対象にする bash の =~ で判定する（Bash 3.2 対応）。
    if [[ "$_v" =~ [[:cntrl:]] ]]; then
      mdm_log R1 "passthrough 値に制御文字が含まれる: $_k"
      MDM_DROP_ARGV=()
      return 1
    fi
    MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="$_k=$_v"
  done
  local _a
  for _a in "$@"; do
    MDM_DROP_ARGV[${#MDM_DROP_ARGV[@]}]="$_a"
  done
  return 0
}

# setup.sh へ渡す引数をグローバル配列 MDM_SETUP_ARGV へ直接構築する。
# 対象ユーザーの既存 manifest に依存せず、authoritative checkout を fresh
# reconciliation として適用する。KIT_MDM_DRY_RUN=true のときだけ --dry-run
# を追加する。
MDM_SETUP_ARGV=()
mdm_build_setup_argv() {
  MDM_SETUP_ARGV=(--non-interactive)
  if [[ "$(_mdm_root_bool "${KIT_MDM_DRY_RUN:-false}" 2>/dev/null || echo false)" == "true" ]]; then
    MDM_SETUP_ARGV[${#MDM_SETUP_ARGV[@]}]='--dry-run'
  fi
}

# Single-file launcher helpers.  These validate data only; fetched code is
# never sourced or executed by root.
_mdm_boot_validate_gitref() {
  local _ref="$1"
  [[ -z "$_ref" ]] && return 1
  if printf '%s' "$_ref" | grep -qE '^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$'; then
    return 0
  fi
  /usr/bin/git check-ref-format --branch "$_ref" >/dev/null 2>&1
}

# 起動時検証向けの mode 文字列 group/other 書込ビット検査。
_mdm_boot_mode_is_safe() {
  _mdm_mode_is_safe "$1"
}

# 管理設定ファイルの安全性検証。
# 親ディレクトリの検証を含む — 書込可能な親では他者が差し替えを植えられる。
_mdm_boot_config_file_is_secure() {
  local _f="$1"
  [[ -f "$_f" && ! -L "$_f" ]] || return 1
  local _mode _dir _dmode
  _mode="$(_mdm_stat_mode "$_f" || true)"
  _mdm_boot_mode_is_safe "$_mode" || return 1
  _mdm_has_extended_acl "$_f" && return 1
  _dir="$(dirname "$_f")"
  _dmode="$(_mdm_stat_mode "$_dir" || true)"
  _mdm_boot_mode_is_safe "$_dmode" || return 1
  _mdm_has_extended_acl "$_dir" && return 1
  if [[ "${_MDM_TEST_MODE:-0}" != "1" ]]; then
    case "$_dir" in
      "/Library/Application Support"|"/Library/Application Support"/*) ;;
      *) return 1 ;;
    esac
    _mdm_verify_dir_chain "$_dir" "/Library/Application Support" || return 1
  fi
  if [[ "${_MDM_TEST_MODE:-0}" != "1" || "${MDM_CONFIG_SKIP_OWNER_CHECK:-0}" != "1" ]]; then
    local _owner _downer
    _owner="$(_mdm_stat_owner "$_f" || true)"
    [[ "$_owner" == "root" ]] || return 1
    _downer="$(_mdm_stat_owner "$_dir" || true)"
    [[ "$_downer" == "root" ]] || return 1
  fi
  return 0
}

# Single-file root launcher configuration. Root never sources code from the
# user-owned checkout. In executable mode the privileged launcher has already
# discarded inherited environment, so only the root-owned config file and
# MDM-supplied KEY=VALUE argv are inputs.
_MDM_ROOT_ALLOWED_KEYS="PROFILE LANGUAGE EDITOR_CHOICE COMMIT_ATTRIBUTION \
ENABLE_NEW_INIT INSTALL_AGENTS INSTALL_RULES INSTALL_COMMANDS INSTALL_SKILLS \
ENABLE_CODEX_PLUGIN ENABLE_TMUX_HOOKS ENABLE_DOC_BLOCKER ENABLE_PRETTIER_HOOKS \
ENABLE_BIOME_HOOKS ENABLE_PR_CREATION_LOG ENABLE_PRE_COMPACT_COMMIT \
ENABLE_SAFETY_NET ENABLE_AUTO_UPDATE ENABLE_WEB_CONTENT_UPDATE ENABLE_STATUSLINE \
ENABLE_GHOSTTY_SETUP ENABLE_FONTS_SETUP ENABLE_DOC_SIZE_GUARD ENABLE_NO_FLICKER \
ENABLE_FEATURE_RECOMMENDATION ENABLE_AGENT_TEAMS \
KIT_MDM_TARGET_USER KIT_MDM_INSTALL_HOMEBREW KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE \
KIT_MDM_PREREQ_MODE KIT_MDM_WINDOWS_MODE KIT_MDM_INSTALL_CLAUDE_CLI \
KIT_MDM_GIT_REF KIT_MDM_INSTALL_DIR KIT_MDM_LOG_DIR KIT_MDM_DRY_RUN \
KIT_MDM_EXPECTED_POLICY_SHA256 \
HTTP_PROXY HTTPS_PROXY NO_PROXY"

_mdm_root_key_allowed() {
  local _wanted="$1" _key
  for _key in $_MDM_ROOT_ALLOWED_KEYS; do
    [[ "$_key" == "$_wanted" ]] && return 0
  done
  return 1
}

_mdm_root_bool() {
  case "$1" in
    true|1|yes|on|TRUE|Yes|On|YES|ON) printf 'true' ;;
    false|0|no|off|FALSE|No|Off|NO|OFF) printf 'false' ;;
    *) return 1 ;;
  esac
}

_mdm_root_gitref_syntax() {
  local _ref="$1"
  [[ -n "$_ref" && "$_ref" != -* && "$_ref" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  case "$_ref" in
    *..*|*//*|*/.|.*|*/|*.lock) return 1 ;;
  esac
  printf '%s' "$_ref"
}

_mdm_root_proxy_url() {
  local _value="$1" _rest _authority _tail
  [[ ! "$_value" =~ [[:space:][:cntrl:]] ]] || return 1
  case "$_value" in
    http://*) _rest="${_value#http://}" ;;
    https://*) _rest="${_value#https://}" ;;
    *) return 1 ;;
  esac
  [[ -n "$_rest" && "$_rest" != *'@'* && "$_rest" != *'?'* && "$_rest" != *'#'* ]] || return 1
  _authority="${_rest%%/*}"; _tail="${_rest#"$_authority"}"
  [[ -n "$_authority" && ( -z "$_tail" || "$_tail" == / ) ]] || return 1
  [[ "$_authority" =~ ^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+)(:[0-9]{1,5})?$ ]] || return 1
  printf '%s' "$_value"
}

_mdm_root_value() {
  local _key="$1" _value="$2"
  [[ ! "$_value" =~ [[:cntrl:]] ]] || return 1
  case "$_key" in
    PROFILE)
      case "$_value" in minimal|standard|full) printf '%s' "$_value" ;; *) return 1 ;; esac ;;
    LANGUAGE)
      case "$_value" in en|ja) printf '%s' "$_value" ;; *) return 1 ;; esac ;;
    KIT_MDM_PREREQ_MODE)
      case "$_value" in
        auto|fail) printf '%s' "$_value" ;;
        skip) [[ "${_MDM_TEST_MODE:-0}" == 1 ]] && printf '%s' "$_value" || return 1 ;;
        *) return 1 ;;
      esac ;;
    KIT_MDM_WINDOWS_MODE)
      case "$_value" in gitbash|wsl) printf '%s' "$_value" ;; *) return 1 ;; esac ;;
    ENABLE_AUTO_UPDATE|ENABLE_WEB_CONTENT_UPDATE|ENABLE_CODEX_PLUGIN)
      _value="$(_mdm_root_bool "$_value")" || return 1
      [[ "$_value" == false ]] || return 1
      printf '%s' "$_value" ;;
    ENABLE_*|INSTALL_*|COMMIT_ATTRIBUTION|KIT_MDM_INSTALL_HOMEBREW|KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE|KIT_MDM_INSTALL_CLAUDE_CLI|KIT_MDM_DRY_RUN)
      _mdm_root_bool "$_value" ;;
    KIT_MDM_TARGET_USER)
      _mdm_requested_username_is_safe "$_value" || return 1
      printf '%s' "$_value" ;;
    KIT_MDM_GIT_REF) _mdm_root_gitref_syntax "$_value" ;;
    KIT_MDM_EXPECTED_POLICY_SHA256)
      [[ "$_value" =~ ^[0-9a-f]{64}$ ]] || return 1
      printf '%s' "$_value" ;;
    KIT_MDM_INSTALL_DIR|KIT_MDM_LOG_DIR)
      [[ "$_value" == /* && "$_value" != *..* ]] || return 1
      printf '%s' "$_value" ;;
    HTTP_PROXY|HTTPS_PROXY)
      _mdm_root_proxy_url "$_value" ;;
    NO_PROXY)
      [[ ! "$_value" =~ [[:space:][:cntrl:]] ]] || return 1
      printf '%s' "$_value" ;;
    EDITOR_CHOICE)
      case "$_value" in vscode|cursor|zed|neovim|none) printf '%s' "$_value" ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

# Every production execution, including a non-mutating preview, must be bound
# to the desired-policy digest distributed by the MDM control plane.
_mdm_expected_policy_input_valid() {
  [[ "${KIT_MDM_EXPECTED_POLICY_SHA256:-}" =~ ^[0-9a-f]{64}$ ]]
}

_mdm_root_config_apply() {
  local _file="$1"; shift || true
  local _key _value _line _arg _set_var _value_var _normalized
  for _key in $_MDM_ROOT_ALLOWED_KEYS; do
    unset "$_key"
    unset "_MDM_ROOT_STAGE_${_key}" "_MDM_ROOT_SET_${_key}"
  done

  if [[ -e "$_file" || -L "$_file" ]]; then
    local _pre_inode _fd_inode
    _pre_inode="$(_mdm_stat_inode "$_file" || echo pre-fail)"
    _mdm_boot_config_file_is_secure "$_file" || return "$MDM_EXIT_CONFIG"
    exec 8<"$_file" || return "$MDM_EXIT_CONFIG"
    _fd_inode="$(_mdm_stat_fd_inode 8 || echo fd-fail)"
    if [[ "$_pre_inode" != "$_fd_inode" ]]; then
      exec 8<&-
      return "$MDM_EXIT_CONFIG"
    fi
    while IFS= read -r _line || [[ -n "$_line" ]]; do
      case "$_line" in
        ''|'#'*) continue ;;
        *=*) : ;;
        *) exec 8<&-; mdm_log R1 "不正な管理設定行"; return "$MDM_EXIT_CONFIG" ;;
      esac
      _key="${_line%%=*}"; _value="${_line#*=}"
      _mdm_root_key_allowed "$_key" || {
        exec 8<&-
        mdm_log R1 "不明な管理設定キー: $_key"
        return "$MDM_EXIT_CONFIG"
      }
      _set_var="_MDM_ROOT_SET_${_key}"
      [[ -z "${!_set_var:-}" ]] || {
        exec 8<&-
        mdm_log R1 "管理設定キーが重複: $_key"
        return "$MDM_EXIT_CONFIG"
      }
      if [[ "$_value" == \"*\" ]]; then
        _value="${_value#\"}"; _value="${_value%\"}"
      elif [[ "$_value" == \"* || "$_value" == *\" ]]; then
        exec 8<&-
        mdm_log R1 "管理設定値の quote が不正: $_key"
        return "$MDM_EXIT_CONFIG"
      fi
      _normalized="$(_mdm_root_value "$_key" "$_value")" || {
        exec 8<&-
        mdm_log R1 "管理設定値が不正: $_key"
        return "$MDM_EXIT_CONFIG"
      }
      printf -v "_MDM_ROOT_STAGE_${_key}" '%s' "$_normalized"
      printf -v "$_set_var" '%s' 1
    done <&8
    exec 8<&-
  fi

  for _arg in "$@"; do
    [[ -z "$_arg" ]] && continue
    case "$_arg" in *=*) : ;; *) mdm_log R1 "不明な CLI 引数: $_arg"; return "$MDM_EXIT_CONFIG" ;; esac
    _key="${_arg%%=*}"; _value="${_arg#*=}"
    _mdm_root_key_allowed "$_key" || { mdm_log R1 "不明な CLI キー: $_key"; return "$MDM_EXIT_CONFIG"; }
    _normalized="$(_mdm_root_value "$_key" "$_value")" || {
      mdm_log R1 "CLI 設定値が不正: $_key"
      return "$MDM_EXIT_CONFIG"
    }
    printf -v "_MDM_ROOT_STAGE_${_key}" '%s' "$_normalized"
    printf -v "_MDM_ROOT_SET_${_key}" '%s' 1
  done

  for _key in $_MDM_ROOT_ALLOWED_KEYS; do
    _set_var="_MDM_ROOT_SET_${_key}"; _value_var="_MDM_ROOT_STAGE_${_key}"
    [[ -n "${!_set_var:-}" ]] || continue
    _normalized="$(_mdm_root_value "$_key" "${!_value_var}")" || return "$MDM_EXIT_CONFIG"
    export "$_key=$_normalized"
  done
  : "${PROFILE:=standard}"
  : "${LANGUAGE:=en}"
  export PROFILE LANGUAGE
  return 0
}

# Compliance receipts are a system/root contract.  Non-root remediation is
# rejected and non-root dry-run never writes a receipt, so a user-owned receipt
# must never become authoritative.  The override is source-only test plumbing.
_mdm_receipt_dir_for() {
  : "$1"
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && -n "${MDM_SYSTEM_RCPT_DIR_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_SYSTEM_RCPT_DIR_OVERRIDE"
    return 0
  fi
  printf '%s' "/Library/Application Support/ClaudeCodeStarterKit"
}

# R4: レシート書き出し + 終了コード確定 + ログクローズ。
# 失敗保証は best-effort: 主経路が書けなければ root 領域の _unresolved へ
# フォールバックし、それも書けなければログ+終了コードのみを唯一のシグナルとする。
_mdm_finish() {
  local _user="$1" _home="$2" _result="$3" _code="$4"
  local _success_failure_reason=""
  MDM_RCPT_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  MDM_RCPT_LOG_PATH="$MDM_LOG_FILE"
  : "${MDM_RCPT_PROFILE:=${PROFILE:-standard}}"
  : "${MDM_RCPT_LANGUAGE:=${LANGUAGE:-en}}"
  local _rcpt_dir; _rcpt_dir="$(_mdm_receipt_dir_for "$_home")"
  if [[ "$_result" == "success" && "$_code" -eq 0 ]]; then
    # Preparation and strict semantic validation remain signal-interruptible.
    # Only the final same-directory rename and builtin commit-state transition
    # form the masked publication critical section.
    if ! mdm_receipt_prepare \
        "$_rcpt_dir/receipt-$_user.json" "$_result" "$_code"; then
      _success_failure_reason=receipt
    elif ! _mdm_receipt_prepared_ready \
      || ! _mdm_transaction_ready_to_commit; then
      _mdm_receipt_discard_prepared || true
      _success_failure_reason=transaction
    else
      trap '' HUP INT TERM
      if _mdm_receipt_publish_prepared \
        && [[ "${_MDM_RECEIPT_PUBLISHED:-0}" == 1 ]]; then
        if ! _mdm_transaction_commit; then
          case "${_MDM_TRANSACTION_STATE:-idle}" in
            committing|commit_cleanup) _mdm_transaction_commit || true ;;
          esac
        fi
      else
        _mdm_receipt_discard_prepared || true
        _success_failure_reason=receipt
        _mdm_arm_transient_cleanup
      fi
    fi
    if [[ -n "$_success_failure_reason" ]]; then
      _result="failure"
      _code="$MDM_EXIT_SETUP"
      if [[ "$_success_failure_reason" == receipt ]]; then
        MDM_RCPT_REQUIRED_COMPONENTS='["kit"]'
        MDM_RCPT_PARTIAL='["receipt"]'
      fi
      _mdm_transaction_abort || _mdm_transaction_mark_partial
      mdm_receipt_write "$_rcpt_dir/receipt-$_user.json" \
        "$_result" "$_code" 2>/dev/null \
        || mdm_receipt_write "$_rcpt_dir/receipt-_unresolved.json" \
          "$_result" "$_code" 2>/dev/null || true
    fi
  else
    _mdm_transaction_abort || _mdm_transaction_mark_partial
    mdm_receipt_write "$_rcpt_dir/receipt-$_user.json" "$_result" "$_code" || \
      mdm_receipt_write "$_rcpt_dir/receipt-_unresolved.json" \
        "$_result" "$_code" 2>/dev/null || true
  fi
  mdm_log R4 "完了: result=$_result exit=$_code" || true
  exit "$_code"
}

# 設定・ユーザー解決失敗時の best-effort レシート。
# 対象ユーザーが未確定のため root 領域の receipt-_unresolved.json へ書く。
# 非 root 等で書けなければレシートは諦め、ログ + 終了コードのみを
# シグナルとする（無条件の「必ず receipt」保証はしない契約）。
_mdm_fail_unresolved() {
  local _code="$1"
  MDM_RCPT_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  MDM_RCPT_LOG_PATH="$MDM_LOG_FILE"
  : "${MDM_RCPT_PROFILE:=${PROFILE:-standard}}"
  : "${MDM_RCPT_LANGUAGE:=${LANGUAGE:-en}}"
  local _dir="${MDM_UNRESOLVED_RCPT_DIR_OVERRIDE:-/Library/Application Support/ClaudeCodeStarterKit}"
  mdm_receipt_write "$_dir/receipt-_unresolved.json" failure "$_code" 2>/dev/null || true
  mdm_log R4 "完了: result=failure exit=$_code (unresolved)"
  exit "$_code"
}

# A dry-run is an audit preview even when target resolution fails.  In that
# mode the compliance receipt must remain byte-for-byte unchanged; normal root
# remediation keeps the best-effort unresolved failure receipt above.
_mdm_fail_or_exit_unresolved() { # <exit-code> <dry-run>
  local _code="$1" _dry_run="$2"
  if [[ "$_dry_run" == "true" ]]; then
    exit "$_code"
  fi
  _mdm_fail_unresolved "$_code"
}

# MDM_DROP_ARGV（mdm_build_drop_argv が直接構築）を環境分離降格で実行する
# 共通ヘルパー。launchctl/sudo/env は絶対パス固定。
#   (cd <home> && /bin/launchctl asuser <uid> /usr/bin/sudo -u '#<uid>'
#     -H /usr/bin/env -i ... <cmd...>)
# MDM_EXEC_AS_USER_DRYRUN=1 のとき実行せず argv を1行1要素で表示のみ
# （テスト用。表示は再パースされない）。
_mdm_exec_as_user() {
  local _uid="$1" _user="$2" _home="$3"; shift 3
  local _launchctl=/bin/launchctl _sudo=/usr/bin/sudo _supervisor="" _rc=0
  local _control="" _dir_identity="" _record_state=0 _wait_count=0 _previous=""
  local _record_verified_marker=""
  local _nounset_was_on=false
  local _deadline="${_MDM_EXEC_AS_USER_DEADLINE_SECONDS:-0}"
  [[ "$_uid" =~ ^[0-9]+$ && "$_uid" -ge 501 ]] || return 1
  [[ "$_home" == /* && ! "$_home" =~ [[:cntrl:]] ]] || return 1
  [[ "$_deadline" =~ ^[0-9]+$ && "$_deadline" -le 86400 ]] || return 1
  if [[ "${MDM_EXEC_AS_USER_DRYRUN:-0}" != "1" ]]; then
    [[ -d "$_home" && ! -L "$_home" ]] || return 1
  fi
  mdm_build_drop_argv "$_uid" "$_user" "$_home" "$@" || return 1
  if [[ "${MDM_EXEC_AS_USER_DRYRUN:-0}" == "1" ]]; then
    printf '%s\n' /bin/launchctl asuser "$_uid" /usr/bin/sudo -u "#$_uid" -H "${MDM_DROP_ARGV[@]}"
    return 0
  fi
  if [[ "${_MDM_TEST_MODE:-0}" == 1 ]]; then
    [[ -z "${MDM_LAUNCHCTL_OVERRIDE:-}" ]] || _launchctl="$MDM_LAUNCHCTL_OVERRIDE"
    [[ -z "${MDM_SUDO_OVERRIDE:-}" ]] || _sudo="$MDM_SUDO_OVERRIDE"
  fi
  [[ "$_launchctl" == /* && -x "$_launchctl" && ! -L "$_launchctl" \
    && "$_sudo" == /* && -x "$_sudo" && ! -L "$_sudo" ]] || return 1
  if [[ "${_MDM_RUN_LOCK_MODE:-}" == mkdir ]]; then
    _control="${_MDM_RUN_LOCK_CONTROL_DIR:-}"
    _dir_identity="${_MDM_RUN_LOCK_DIR_IDENTITY:-}"
    [[ -n "$_control" && -n "$_dir_identity" ]] || return 1
  fi

  # Keep a root supervisor alive around launchctl/sudo.  sudo closes fd>=3,
  # but this shell retains fd18/19 while waiting, so a killed coordinator does
  # not release the host lock until the active user command has actually
  # stopped.  mkdir fallback additionally publishes PID+start identity.
  case $- in *u*) _nounset_was_on=true ;; esac
  set +u
  _previous="$!"
  [[ "$_nounset_was_on" == true ]] && set -u
  _MDM_DROP_SUPERVISOR_PREVIOUS_BG="$_previous"
  _MDM_DROP_SUPERVISOR_STARTING=1
  /bin/sh -c '
    _home=$1; _control=$2; _dir_identity=$3; _deadline=$4; shift 4
    _worker=""; _worker_record=""; _tmp=""; _child=""; _pgid=""; _rc=0; _pending=0
    _deadline_watchdog=""
    _dir_id() {
      if [ "$(/usr/bin/uname -s 2>/dev/null)" = Darwin ]; then
        /usr/bin/stat -f "%d:%i:%HT" "$1" 2>/dev/null
      else
        /usr/bin/stat -c "%d:%i:%F" "$1" 2>/dev/null
      fi
    }
    _record_exact() {
      _record=$1; _expected_record=$2; _actual_record=""
      [ -f "$_record" ] && [ ! -L "$_record" ] || return 1
      _record_size=$(/usr/bin/wc -c < "$_record" \
        | /usr/bin/tr -d "[:space:]") || return 1
      _expected_size=$(printf "%s\n" "$_expected_record" \
        | LC_ALL=C /usr/bin/wc -c \
        | /usr/bin/tr -d "[:space:]") || return 1
      [ "$_record_size" = "$_expected_size" ] || return 1
      IFS= read -r _actual_record < "$_record" || return 1
      [ "$_actual_record" = "$_expected_record" ]
    }
    _group_live() {
      _group_listing=""
      if [ "$(/usr/bin/uname -s 2>/dev/null)" = Darwin ]; then
        _group_listing=$(/bin/ps -o stat= -g "$1" 2>/dev/null) || _group_listing=""
      else
        _group_listing=$(/bin/ps -o stat= --pgroup "$1" 2>/dev/null) \
          || _group_listing=""
      fi
      if [ -n "$_group_listing" ]; then
        ! printf "%s\n" "$_group_listing" \
          | /usr/bin/awk '\''$1 !~ /^Z/ { exit 1 }'\''
        return
      fi
      _group_listing=$(/bin/ps -axo pgid=,stat= 2>/dev/null) || return 0
      printf "%s\n" "$_group_listing" | /usr/bin/awk -v pgid="$1" \
        '\''$1 == pgid && $2 !~ /^Z/ { live=1 }
             END { exit(live ? 0 : 1) }'\''
    }
    _group_quiesced() {
      _group_listing=$(/bin/ps -axo pgid=,stat= 2>/dev/null) || return 1
      printf "%s\n" "$_group_listing" | /usr/bin/awk -v pgid="$1" \
        '\''$1 == pgid && $2 !~ /^[TtZ]/ { running=1 }
             END { exit(running ? 1 : 0) }'\''
    }
    _cleanup_record() {
      [ -n "$_worker" ] || return 0
      [ "$(_dir_id "$_control")" = "$_dir_identity" ] || return 0
      if [ -n "$_tmp" ] && [ "$_tmp" = "$_control/.worker.$$" ] \
        && [ -f "$_tmp" ] && [ ! -L "$_tmp" ]; then
        /bin/rm -f "$_tmp"
      fi
      if [ -n "$_worker_record" ] \
        && _record_exact "$_worker" "$_worker_record"; then
        /bin/rm -f "$_worker"
      fi
    }
    _stop_deadline_watchdog() {
      [ -n "$_deadline_watchdog" ] || return 0
      _watchdog_pgid=$_deadline_watchdog
      /bin/kill -TERM "$_watchdog_pgid" 2>/dev/null || :
      _watchdog_stop_count=0
      while /bin/kill -0 -- "-$_watchdog_pgid" 2>/dev/null \
        && [ "$_watchdog_stop_count" -lt 25 ]; do
        /bin/sleep 0.01
        _watchdog_stop_count=$((_watchdog_stop_count + 1))
      done
      /bin/kill -STOP -- "-$_watchdog_pgid" 2>/dev/null || :
      _watchdog_stop_count=0
      while ! _group_quiesced "$_watchdog_pgid" \
        && [ "$_watchdog_stop_count" -lt 25 ]; do
        /bin/sleep 0.01
        _watchdog_stop_count=$((_watchdog_stop_count + 1))
      done
      /bin/kill -KILL -- "-$_watchdog_pgid" 2>/dev/null || :
      _watchdog_stop_count=0
      while /bin/kill -0 -- "-$_watchdog_pgid" 2>/dev/null \
        && [ "$_watchdog_stop_count" -lt 10 ]; do
        /bin/sleep 0.01
        _watchdog_stop_count=$((_watchdog_stop_count + 1))
      done
      wait "$_deadline_watchdog" 2>/dev/null || :
      _deadline_watchdog=""
      ! _group_live "$_watchdog_pgid"
    }
    _terminate() {
      _requested_rc=$1
      _cleanup_failed=0
      trap - HUP INT TERM USR1
      # The command keeps its original stderr until cancellation begins.  From
      # here on, suppress only the supervisor asynchronous job-control
      # diagnostic (for example, "Killed: 9") while it reaps the process group.
      exec 2>/dev/null
      _stop_deadline_watchdog || _cleanup_failed=1
      if [ -n "$_child" ]; then
        if [ -n "$_pgid" ]; then
          /bin/kill -TERM "$_child" 2>/dev/null || :
        else
          /bin/kill -TERM "$_child" 2>/dev/null || :
        fi
        _stop_count=0
        while /bin/kill -0 -- "-$_pgid" 2>/dev/null \
          && [ "$_stop_count" -lt 100 ]; do
          /bin/sleep 0.01
          _stop_count=$((_stop_count + 1))
        done
        if [ -n "$_pgid" ]; then
          /bin/kill -STOP -- "-$_pgid" 2>/dev/null || :
          _stop_count=0
          while ! _group_quiesced "$_pgid" \
            && [ "$_stop_count" -lt 25 ]; do
            /bin/sleep 0.01
            _stop_count=$((_stop_count + 1))
          done
        fi
        if [ -n "$_pgid" ]; then
          /bin/kill -KILL -- "-$_pgid" 2>/dev/null || :
        else
          /bin/kill -KILL "$_child" 2>/dev/null || :
        fi
        _stop_count=0
        while /bin/kill -0 -- "-$_pgid" 2>/dev/null \
          && [ "$_stop_count" -lt 20 ]; do
          /bin/sleep 0.01
          _stop_count=$((_stop_count + 1))
        done
        _group_live "$_pgid" && _cleanup_failed=1
        wait "$_child" 2>/dev/null || :
      fi
      _cleanup_record
      [ "$_cleanup_failed" -eq 0 ] || exit 1
      exit "$_requested_rc"
    }
    trap "_pending=129" HUP
    trap "_pending=130" INT
    trap "_pending=143" TERM
    trap "_pending=124" USR1
    trap "_cleanup_record" EXIT
    case "$_deadline" in ""|*[!0-9]*) exit 1 ;; esac
    [ "$_deadline" = 0 ] || case "$_deadline" in 0*) exit 1 ;; esac
    [ "$_deadline" -le 86400 ] || exit 1
    cd -P -- "$_home" || exit 1
    if [ -n "$_control" ]; then
      [ "$(_dir_id "$_control")" = "$_dir_identity" ] || exit 1
      [ ! -e "$_control/.reap" ] && [ ! -L "$_control/.reap" ] || exit 1
      _worker="$_control/worker"
      _tmp="$_control/.worker.$$"
      _start=$(TZ=UTC0 LC_ALL=C /bin/ps -p "$$" -o lstart= 2>/dev/null \
        | /usr/bin/awk "{\$1=\$1; print}") || exit 1
      [ -n "$_start" ] && [ ! -e "$_worker" ] && [ ! -L "$_worker" ] || exit 1
      _worker_record=$(printf "%s\t%s\t%s" "$$" "$_start" "$_dir_identity") \
        || exit 1
      umask 077
      (set -C; printf "%s\n" "$_worker_record" > "$_tmp") \
        2>/dev/null || exit 1
      /bin/chmod 600 "$_tmp" || exit 1
      [ "$(_dir_id "$_control")" = "$_dir_identity" ] || exit 1
      [ ! -e "$_control/.reap" ] && [ ! -L "$_control/.reap" ] || exit 1
      /bin/mv "$_tmp" "$_worker" || exit 1
      [ "$(_dir_id "$_control")" = "$_dir_identity" ] || exit 1
      [ ! -e "$_control/.reap" ] && [ ! -L "$_control/.reap" ] || exit 1
      _record_exact "$_worker" "$_worker_record" || exit 1
      [ "$(_dir_id "$_control")" = "$_dir_identity" ] || exit 1
      [ ! -e "$_control/.reap" ] && [ ! -L "$_control/.reap" ] || exit 1
    fi
    # A dedicated process group lets cancellation stop setup descendants too;
    # killing only launchctl/sudo can orphan a grandchild and release the lock
    # while it is still mutating shared state.
    [ "$_pending" -eq 0 ] || _terminate "$_pending"
    set -m || exit 1
    "$@" &
    _child=$!
    _pgid="$_child"
    set +m || :
    [ "$_pending" -eq 0 ] || _terminate "$_pending"
    if [ "$_deadline" -gt 0 ]; then
      set -m || _terminate 1
      ( /bin/sleep "$_deadline"; /bin/kill -USR1 "$$" 2>/dev/null || : ) &
      _deadline_watchdog=$!
      set +m || :
    fi
    wait "$_child" 2>/dev/null || _rc=$?
    _stop_deadline_watchdog || _terminate 1
    [ "$_pending" -eq 0 ] || _terminate "$_pending"
    _child=""
    if _group_live "$_pgid"; then
      /bin/kill -TERM "$_pgid" 2>/dev/null || :
      _stop_count=0
      while /bin/kill -0 -- "-$_pgid" 2>/dev/null \
        && [ "$_stop_count" -lt 100 ]; do
        /bin/sleep 0.01
        _stop_count=$((_stop_count + 1))
      done
      /bin/kill -STOP -- "-$_pgid" 2>/dev/null || :
      _stop_count=0
      while ! _group_quiesced "$_pgid" \
        && [ "$_stop_count" -lt 25 ]; do
        /bin/sleep 0.01
        _stop_count=$((_stop_count + 1))
      done
      /bin/kill -KILL -- "-$_pgid" 2>/dev/null || :
      _stop_count=0
      while /bin/kill -0 -- "-$_pgid" 2>/dev/null \
        && [ "$_stop_count" -lt 20 ]; do
        /bin/sleep 0.01
        _stop_count=$((_stop_count + 1))
      done
      _group_live "$_pgid" && exit 1
    fi
    _cleanup_record
    exit "$_rc"
  ' mdm-drop-supervisor "$_home" "$_control" "$_dir_identity" "$_deadline" \
    "$_launchctl" asuser "$_uid" "$_sudo" -u "#$_uid" -H "${MDM_DROP_ARGV[@]}" &
  _supervisor=$!
  _MDM_ACTIVE_DROP_SUPERVISOR_PID="$_supervisor"
  _MDM_DROP_SUPERVISOR_STARTING=0
  if [[ -n "$_control" ]]; then
    while [[ "$_wait_count" -lt 500 ]]; do
      if _mdm_lock_record_state "$_control/worker" "$_dir_identity"; then
        _record_state=0; break
      else
        _record_state=$?
      fi
      [[ "$_record_state" -eq 3 ]] || break
      /bin/kill -0 "$_supervisor" 2>/dev/null || break
      /bin/sleep 0.01
      _wait_count=$((_wait_count + 1))
    done
    if [[ "$_record_state" -ne 0 || "$_MDM_LOCK_RECORD_PID" != "$_supervisor" ]]; then
      /bin/kill -TERM "$_supervisor" 2>/dev/null || true
      _mdm_wait_lock_holder "$_supervisor" || true
      _MDM_ACTIVE_DROP_SUPERVISOR_PID=""
      return 1
    fi
    if [[ "${_MDM_TEST_MODE:-0}" == 1 \
      && -n "${MDM_EXEC_AS_USER_RECORD_VERIFIED_MARKER_OVERRIDE:-}" ]]; then
      _record_verified_marker="$MDM_EXEC_AS_USER_RECORD_VERIFIED_MARKER_OVERRIDE"
      if [[ "$_record_verified_marker" != /* \
        || "$_record_verified_marker" =~ [[:cntrl:]] \
        || -e "$_record_verified_marker" || -L "$_record_verified_marker" ]] \
        || ! (umask 077; set -C; : > "$_record_verified_marker") 2>/dev/null \
        || [[ ! -f "$_record_verified_marker" || -L "$_record_verified_marker" ]]; then
        /bin/kill -TERM "$_supervisor" 2>/dev/null || true
        _mdm_wait_lock_holder "$_supervisor" || true
        _MDM_ACTIVE_DROP_SUPERVISOR_PID=""
        return 1
      fi
    fi
  fi
  wait "$_supervisor" || _rc=$?
  _MDM_ACTIVE_DROP_SUPERVISOR_PID=""
  return "$_rc"
}

_mdm_exec_setup_as_user() {
  local _MDM_EXEC_AS_USER_DEADLINE_SECONDS
  _MDM_EXEC_AS_USER_DEADLINE_SECONDS="$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_SETUP_SECONDS")" || return 1
  _mdm_exec_as_user "$@"
}

# ── git 実行ディスパッチャ ──────────────────────────────────────
# root が対象ユーザー所有の git repo を直接操作すると、ユーザーが仕込んだ
# .git/config（core.fsmonitor / filter / credential helper 等）経由で
# 冪等再実行時に root コード実行になる。降格コンテキスト（下記グローバル）
# が設定されているとき、git は必ず検証済み対象ユーザーへ env -i 降格して実行する。
# コンテキストは _mdm_run_user_phase が root フェーズ開始時に設定する。
_MDM_GIT_DROP_UID=""
_MDM_GIT_DROP_USER=""
_MDM_GIT_DROP_HOME=""
_mdm_git() {
  if [[ -n "$_MDM_GIT_DROP_UID" ]]; then
    _mdm_exec_as_user "$_MDM_GIT_DROP_UID" "$_MDM_GIT_DROP_USER" "$_MDM_GIT_DROP_HOME" /usr/bin/git "$@"
  else
    git "$@"
  fi
}

# Only network-bearing Git operations use this runner.  A wall-clock deadline
# covers stalls that low-speed detection cannot observe, while the low-speed
# floor rejects a peer that keeps a connection alive without useful progress.
_mdm_git_network() {
  local _deadline _MDM_EXEC_AS_USER_DEADLINE_SECONDS
  _deadline="$(_mdm_timeout_seconds "$_MDM_TIMEOUT_GIT_SECONDS")" || return 1
  if [[ -n "$_MDM_GIT_DROP_UID" ]]; then
    # _mdm_git creates a nested launchctl/sudo process group in this mode, so
    # its own supervisor must own the deadline and descendant cleanup.
    _MDM_EXEC_AS_USER_DEADLINE_SECONDS="$_deadline"
    _mdm_git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 "$@"
  else
    _mdm_run_with_timeout "$_deadline" _mdm_git \
      -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 "$@"
  fi
}

# root なら検証済みユーザーへ降格して実行、非 root なら直接実行する汎用版
# （mkdir/chmod 等、repo 配下を触る git 以外の操作に使う）。
_mdm_run_maybe_as_user() {
  if [[ -n "$_MDM_GIT_DROP_UID" ]]; then
    _mdm_exec_as_user "$_MDM_GIT_DROP_UID" "$_MDM_GIT_DROP_USER" "$_MDM_GIT_DROP_HOME" "$@"
  else
    "$@"
  fi
}

_mdm_brew_usable_for_user() { # <uid> <user> <home>
  local _uid="$1" _user="$2" _home="$3"
  _mdm_exec_as_user "$_uid" "$_user" "$_home" /bin/bash --noprofile --norc -c '
    _brew=""
    if [[ -x /opt/homebrew/bin/brew ]]; then
      _brew=/opt/homebrew/bin/brew
    elif [[ -x /usr/local/bin/brew ]]; then
      _brew=/usr/local/bin/brew
    fi
    [[ -n "$_brew" ]] || exit 1
    _prefix="$("$_brew" --prefix 2>/dev/null)" || exit 1
    [[ -n "$_prefix" && -d "$_prefix" && -w "$_prefix" ]]
  '
}

# CLT on-demand marker の固定パス（Apple の機構が定める。テスト時は override）。
_MDM_ACTIVE_CLT_MARKER=""
_MDM_ACTIVE_BREW_PKG=""
_MDM_ACTIVE_BREW_PLIST=""
_mdm_clt_marker_path() {
  printf '%s' "${MDM_CLT_MARKER_OVERRIDE:-/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress}"
}

# CLT marker を安全に作成する（R2-High）。/tmp は sticky のため他ユーザーが
# symlink を先置きでき、旧実装の touch は root 権限で任意パスの作成/
# タイムスタンプ更新に悪用できた。rm → noclobber 排他作成 → lstat 検証。
_mdm_create_clt_marker() {
  local _marker
  _marker="$(_mdm_clt_marker_path)"
  rm -f "$_marker" 2>/dev/null || true
  if [[ -e "$_marker" || -L "$_marker" ]]; then
    return 1
  fi
  if ! ( set -C; : > "$_marker" ) 2>/dev/null; then
    return 1
  fi
  _MDM_ACTIVE_CLT_MARKER="$_marker"
  _mdm_arm_transient_cleanup
  if [[ -L "$_marker" || ! -f "$_marker" ]]; then
    return 1
  fi
  local _owner
  _owner="$(_mdm_stat_uid "$_marker" 2>/dev/null || true)"
  [[ "$_owner" == "$(id -u)" ]] || return 1
  return 0
}

_mdm_remove_clt_marker() {
  local _marker="${_MDM_ACTIVE_CLT_MARKER:-$(_mdm_clt_marker_path)}"
  [[ "$_marker" == "$(_mdm_clt_marker_path)" ]] || return 1
  rm -f "$_marker" 2>/dev/null || true
  _MDM_ACTIVE_CLT_MARKER=""
}

_mdm_cleanup_prereq_artifacts() {
  local _path _base
  _path="${_MDM_ACTIVE_BREW_PKG:-}"
  if [[ -n "$_path" ]]; then
    _base="$(_mdm_safe_tmpdir)"
    case "$_path" in "$_base"/mdm-homebrew-pkg.*) rm -f "$_path" 2>/dev/null || true ;; esac
    _MDM_ACTIVE_BREW_PKG=""
  fi
  _path="${_MDM_ACTIVE_BREW_PLIST:-}"
  if [[ -n "$_path" && "$_path" == "${MDM_BREW_PLIST_OVERRIDE:-/var/tmp/.homebrew_pkg_user.plist}" ]]; then
    rm -f "$_path" 2>/dev/null || true
    _MDM_ACTIVE_BREW_PLIST=""
  fi
  _path="${_MDM_ACTIVE_CLT_MARKER:-}"
  if [[ -n "$_path" && "$_path" == "$(_mdm_clt_marker_path)" ]]; then
    rm -f "$_path" 2>/dev/null || true
    _MDM_ACTIVE_CLT_MARKER=""
  fi
}

# CLT の存在確認（テスト時は MDM_CLT_PRESENT_OVERRIDE でモック可能）。
_mdm_clt_present() {
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && -n "${MDM_CLT_PRESENT_OVERRIDE:-}" ]]; then
    [[ "$MDM_CLT_PRESENT_OVERRIDE" == "1" ]]; return
  fi
  [[ -d /Library/Developer/CommandLineTools/usr/bin \
    && -d /Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework \
    && -L /Library/Developer/CommandLineTools/usr/bin/python3 ]]
}

_mdm_check_dryrun_prerequisites() {
  if _mdm_clt_present; then
    return 0
  fi
  mdm_log R3 "dry-run: CLT が不足"
  return "$MDM_EXIT_PREREQ"
}

# softwareupdate -l の旧形式（"* Command Line Tools ..."）と現行形式
#（"* Label: Command Line Tools ..."）を同じ install label に正規化する。
_mdm_select_clt_label() {
  LC_ALL=C /usr/bin/awk '
    function newer(left, right, lparts, rparts, nl, nr, count, i, lv, rv) {
      nl = split(left, lparts, /[^0-9]+/)
      nr = split(right, rparts, /[^0-9]+/)
      count = nl > nr ? nl : nr
      for (i = 1; i <= count; i++) {
        lv = i <= nl ? lparts[i] + 0 : 0
        rv = i <= nr ? rparts[i] + 0 : 0
        if (lv != rv) return lv > rv
      }
      return left > right
    }

    /\*.*Command Line Tools/ {
      label = $0
      sub(/^[^*]*\*[[:space:]]*/, "", label)
      sub(/^Label:[[:space:]]*/, "", label)
      version = label
      sub(/^.*Xcode[[:space:]-]*/, "", version)
      if (version !~ /^[0-9]+([.-][0-9]+)*$/) next
      if (!seen || newer(version, best_version)) {
        seen = 1
        best_version = version
        best_label = label
      }
    }

    END { if (seen) print best_label }
  '
}

# Xcode Command Line Tools の導入確認。root 実行前提。
# 既定では不在時に MDM baseline での pkg 事前配布を要求して失敗を返す。
# KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=true のときのみ、Apple 公式手順として
# 文書化されていない softwareupdate 経由の導入をベストエフォートで試みる。
_mdm_ensure_clt() {
  if _mdm_clt_present; then
    return 0
  fi
  if [[ "$(_mdm_root_bool "${KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE:-false}" 2>/dev/null || echo false)" != "true" ]]; then
    mdm_log R3 "Xcode Command Line Tools が未導入。MDM baseline での pkg 事前配布が必要（KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=true で非公式フォールバックを許可可能）"
    return 1
  fi
  mdm_log R3 "非公式フォールバック: softwareupdate 経由で CLT 導入を試みる（Apple 公式手順として文書化されていない）"
  # marker パスは Apple の on-demand 機構が定める固定パス（/tmp = sticky で
  # 他ユーザーが symlink を先置きできる）。安全に作成できなければこの
  # opt-in 経路自体を中止する（fail-closed。R2-High）
  if ! _mdm_create_clt_marker; then
    mdm_log R3 "CLT marker を安全に作成できない（symlink 先置き等）。非公式フォールバックを中止"
    return 1
  fi
  local _label
  _label="$(_mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_QUERY_SECONDS")" softwareupdate -l 2>/dev/null \
    | _mdm_select_clt_label || true)"
  if [[ -n "$_label" ]]; then
    _mdm_run_with_timeout "$(_mdm_timeout_seconds \
      "$_MDM_TIMEOUT_CLT_INSTALL_SECONDS")" \
      softwareupdate -i "$_label" --verbose >/dev/null 2>&1 || true
  else
    mdm_log R3 "softwareupdate に CLT の候補が見つからない"
  fi
  _mdm_remove_clt_marker
  if _mdm_clt_present; then
    mdm_log R3 "CLT 導入を確認"
    return 0
  fi
  mdm_log R3 "CLT の非公式導入に失敗"
  return 1
}

# GitHub API から Homebrew 公式 pkg（アセット名 Homebrew.pkg / 旧 Homebrew-<version>.pkg）
# の browser_download_url を解決する。
# 出典: https://github.com/Homebrew/brew/releases/latest （2026-07-16 確認）。
# root フェーズの前提導入より前に呼ばれるため jq が使える保証が無く、
# jq 非依存で grep/sed により JSON から値を抜き出す。
# MDM_BREW_RELEASES_JSON_OVERRIDE でテスト時にモック可能（curl を経由せずファイルから読む）。
_mdm_resolve_brew_pkg_url() {
  local _json
  if [[ -n "${MDM_BREW_RELEASES_JSON_OVERRIDE:-}" ]]; then
    _json="$(cat "$MDM_BREW_RELEASES_JSON_OVERRIDE" 2>/dev/null || true)"
  else
    _json="$(_mdm_run_with_timeout "$(_mdm_timeout_seconds \
      "$_MDM_TIMEOUT_QUERY_SECONDS")" curl -fsSL \
      "https://api.github.com/repos/Homebrew/brew/releases/latest" \
      2>/dev/null || true)"
  fi
  [[ -z "$_json" ]] && return 1
  local _url
  # 無ヒットの可能性がある grep は pipefail 下で非0を返し得るため `|| true` で
  # 握り潰し、後段の空文字チェックに委ねる（本ファイル既存の NOTE と同じ作法）。
  _url="$(printf '%s' "$_json" \
    | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*\.pkg"' \
    | head -n1 \
    | sed -E 's/^"browser_download_url"[[:space:]]*:[[:space:]]*"//; s/"$//' || true)"
  [[ -z "$_url" ]] && return 1
  # 解決した URL を公式リリース配布パスに制約する（最終レビュー High#7）。
  # API 応答の改ざん/汚染があっても github.com/Homebrew/brew 以外へ飛ばない。
  # アセット名は Homebrew-<version>.pkg（旧）と Homebrew.pkg（6.0.11 で実測の現行）
  # の両方を許容する。
  if ! printf '%s' "$_url" | grep -qE '^https://github\.com/Homebrew/brew/releases/download/[^/[:space:]]+/Homebrew[^/[:space:]]*\.pkg$'; then
    mdm_log R3 "Homebrew pkg URL が公式リリース配布パスでない: $_url"
    return 1
  fi
  printf '%s' "$_url"
  return 0
}

# pkgutil --check-signature の出力を検証する（最終レビュー High#7）。
# 汎用の "Developer ID Installer" 一致だけでは Apple 発行の任意の Developer ID
# 証明書で署名した悪性 pkg を通してしまうため、Homebrew の Team ID に pin する。
# Team ID 927JGANW46 は 2026-07-17 に release 6.0.11 の実 pkg を
# `pkgutil --check-signature` して確認した一次情報
# （"Developer ID Installer: Patrick Linnane (927JGANW46)"・notarized）。
# 証明書のローテーションで Team ID が変わった場合は fail-closed になる（導入失敗
# として exit 11 → ログで判別可能）。
_MDM_BREW_TEAM_ID="927JGANW46"
_mdm_check_brew_signature_output() {
  local _out="$1"
  printf '%s' "$_out" | grep -q 'Developer ID Installer' || return 1
  printf '%s' "$_out" | grep -q "Developer ID Installer: .*(${_MDM_BREW_TEAM_ID})" || return 1
  return 0
}

# HOMEBREW_PKG_USER plist を安全に作成する（最終レビュー High#7）。
# /var/tmp は world-writable + sticky のため、他ローカルユーザーが先回りで
# symlink を置け、旧実装（defaults write）は root がそれを辿って任意ファイルへ
# 書き込む経路になった。rm → noclobber 排他作成 → lstat 検証で排除する。
# Homebrew 側の homebrew-package-user は「非 symlink 通常ファイル・root 所有・
# mode 0600・ACL 無し」の場合のみ plist を尊重する（Homebrew/brew
# Library/Homebrew/utils/macos_user.sh で確認済み）ため mode 600 で作成する。
# 値は defaults read 互換の XML plist（username は R2 で文字種検証済み = XML 安全）。
_mdm_write_brew_pkg_user_plist() {
  local _user="$1"
  local _plist="${MDM_BREW_PLIST_OVERRIDE:-/var/tmp/.homebrew_pkg_user.plist}"
  rm -f "$_plist" 2>/dev/null || true
  if [[ -e "$_plist" || -L "$_plist" ]]; then
    mdm_log R3 "既存の plist を除去できない: $_plist"
    return 1
  fi
  # noclobber（set -C）で排他的に作成: rm と作成の間に他者が再作成した場合は
  # 上書きせず失敗する。umask 177 で最初から 600
  if ! ( set -C; umask 177; printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>HOMEBREW_PKG_USER</key>\n\t<string>%s</string>\n</dict>\n</plist>\n' "$_user" > "$_plist" ) 2>/dev/null; then
    mdm_log R3 "plist の排他作成に失敗: $_plist"
    return 1
  fi
  _MDM_ACTIVE_BREW_PLIST="$_plist"
  _mdm_arm_transient_cleanup
  # 作成後の実体検証（symlink でない・通常ファイル・自分所有・mode 600）
  if [[ -L "$_plist" || ! -f "$_plist" ]]; then
    mdm_log R3 "作成した plist の実体が不正: $_plist"
    return 1
  fi
  local _owner _mode
  _owner="$(_mdm_stat_uid "$_plist" 2>/dev/null || true)"
  _mode="$(_mdm_stat_mode "$_plist" 2>/dev/null || true)"
  if [[ "$_owner" != "$(id -u)" || "$_mode" != "600" ]]; then
    mdm_log R3 "作成した plist の所有者/mode が不正: owner=$_owner mode=$_mode"
    rm -f "$_plist" 2>/dev/null || true
    return 1
  fi
  return 0
}

# Homebrew の導入。公式 .pkg + HOMEBREW_PKG_USER 方式
# （出典: https://docs.brew.sh/Installation、2026-07-16 確認）。
#
# macOS の .pkg インストーラは Homebrew/brew の GitHub Releases に配置され、
# デフォルト prefix（Apple Silicon: /opt/homebrew, Intel: /usr/local）に
# 対象ユーザー単独所有で導入される。ログインウィンドウ/ユーザーログイン前でも
# 動作するため MDM の root コンテキストに適する（curl|bash 版と異なり、対象
# ユーザーのパスワードなし sudo に依存しない）。
#
# 手順（各ステップの一次情報根拠は上記 docs.brew.sh/Installation の記載）:
#   1. GitHub API から pkg の browser_download_url を解決し公式配布パスに制約
#      （_mdm_resolve_brew_pkg_url）
#   2. 代替インストールユーザーを /var/tmp/.homebrew_pkg_user.plist に書く
#      （_mdm_write_brew_pkg_user_plist による排他作成・root 所有 0600。
#      ファイルと対象ユーザーは install 前に存在必須 — 対象ユーザーは R2 で検証済み）
#   3. pkg をダウンロードし pkgutil --check-signature で Homebrew の Team ID に
#      pin した Developer ID 署名を確認
#      （検証失敗時は導入せず終了 — 呼び出し元経由で exit 11 = MDM_EXIT_BREW）
#   4. installer -pkg <pkg> -target / で導入（root 実行）
#   5. 一時ファイル（pkg・plist）をクリーンアップし、brew バイナリの存在で成否判定
#
# curl|bash 経路は撤去済み（パスワードなし sudo が無い環境での非対話ハング
# リスクを避けるため）。pkg 方式が不可能な場合は暗黙フォールバックせず失敗を返す。
_mdm_bootstrap_homebrew() {
  local _user="$1"

  local _pkg_url
  _pkg_url="$(_mdm_resolve_brew_pkg_url)" || {
    mdm_log R3 "Homebrew pkg の URL を解決できない（GitHub API 応答不正 or ネットワーク不可）"
    return 1
  }

  # NOTE: mktemp のテンプレートに XXXXXX の後ろへ拡張子等のサフィックスを
  # 付けると、macOS 標準 (BSD) mktemp は置換をスキップしてテンプレート文字列
  # をそのまま返す（exit 0・ファイル未作成・実機検証済み）。予測可能な
  # パスになりファイル未作成のまま以降の処理が進む重大な不具合になるため、
  # XXXXXX は末尾に置く（拡張子を付けない）。installer(1) は拡張子を要求しない。
  local _pkg
  _pkg="$(mktemp "$(_mdm_safe_tmpdir)/mdm-homebrew-pkg.XXXXXX" 2>/dev/null)" || {
    mdm_log R3 "Homebrew 導入: 一時 pkg パスの作成に失敗"
    return 1
  }
  _MDM_ACTIVE_BREW_PKG="$_pkg"
  _mdm_arm_transient_cleanup

  mdm_log R3 "Homebrew pkg をダウンロード中: $_pkg_url"
  if ! _mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_PACKAGE_SECONDS")" \
    curl -fsSL -o "$_pkg" "$_pkg_url" 2>/dev/null; then
    mdm_log R3 "Homebrew pkg のダウンロードに失敗: $_pkg_url"
    _mdm_cleanup_prereq_artifacts
    return 1
  fi

  # 署名検証: exit code + 証明書チェーンの Developer ID Installer を Homebrew の
  # Team ID (927JGANW46) に pin して確認してから installer にかける（High#7）。
  local _sig_out _sig_rc=0
  _sig_out="$(_mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_PKGUTIL_SECONDS")" \
    pkgutil --check-signature "$_pkg" 2>&1)" || _sig_rc=$?
  if [[ $_sig_rc -ne 0 ]] || ! _mdm_check_brew_signature_output "$_sig_out"; then
    mdm_log R3 "Homebrew pkg の署名検証に失敗（Team ID ${_MDM_BREW_TEAM_ID} の Developer ID Installer 署名を確認できない）"
    _mdm_cleanup_prereq_artifacts
    return 1
  fi

  # 代替インストールユーザーの指定（install 直前に作成。ファイルと対象
  # ユーザーは install 前に存在必須 — 一次情報の記載どおり）。
  # symlink 追随を排除した排他作成 + root 所有 0600（brew 側の受理条件）
  local _plist_path="${MDM_BREW_PLIST_OVERRIDE:-/var/tmp/.homebrew_pkg_user.plist}"
  if ! _mdm_write_brew_pkg_user_plist "$_user"; then
    mdm_log R3 "Homebrew 導入: $_plist_path の安全な作成に失敗"
    _mdm_cleanup_prereq_artifacts
    return 1
  fi

  mdm_log R3 "Homebrew pkg を導入中 (HOMEBREW_PKG_USER=$_user)"
  local _rc=0
  _mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_PACKAGE_SECONDS")" \
    installer -pkg "$_pkg" -target / >/dev/null 2>&1 || _rc=$?
  _mdm_cleanup_prereq_artifacts
  if [[ $_rc -ne 0 ]]; then
    mdm_log R3 "Homebrew pkg の導入に失敗 (exit=$_rc)"
    return 1
  fi

  if [[ -x /opt/homebrew/bin/brew || -x /usr/local/bin/brew ]]; then
    return 0
  fi
  mdm_log R3 "Homebrew 導入後もバイナリを検出できない"
  return 1
}

# R3: 前提ブートストラップ。root 実行前提、mdm_prereq_plan が
# "bootstrap" のときのみ呼ばれる。CLT → Homebrew の順（brew の導入自体が
# CLT のコンパイラ/git に依存するため）。
# NOTE: Homebrew は pkg + HOMEBREW_PKG_USER 方式のため対象ユーザーの home は
# 不要（_user のみ渡す）。
# 終了コード契約: CLT 不足=10（前提不足）と
# Homebrew 導入失敗=11 を区別して返す。
_mdm_bootstrap_prereqs() {
  local _user="$1"
  _mdm_ensure_clt || return "$MDM_EXIT_PREREQ"
  _mdm_bootstrap_homebrew "$_user" || return "$MDM_EXIT_BREW"
  return 0
}

# The official native installer creates this fixed symlink layout.  Existence
# or executability alone is not evidence: a target user could pre-place a fake
# executable and make both setup and MDM detection report success.
_mdm_claude_cli_codesign_requirement() {
  # This is the designated requirement emitted by the current Anthropic
  # Developer ID build.  An external requirement is mandatory: plain
  # `codesign --verify` checks a binary against its own (attacker-selected)
  # designated requirement and does not establish Apple trust policy.
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

_mdm_cli_present_for_home() {
  local _home="$1" _link
  _link="$_home/.local/bin/claude"
  local _versions="$_home/.local/share/claude/versions" _target _canonical
  local _target_uid _snapshot _old_umask _rc=1 _mode
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && -n "${MDM_CLAUDE_CLI_TRUST_OVERRIDE:-}" ]]; then
    [[ "$MDM_CLAUDE_CLI_TRUST_OVERRIDE" == "1" ]]
    return
  fi
  [[ -L "$_link" ]] || return 1
  _mdm_readlink_exact "$_link" _target || return 1
  case "$_target" in "$_versions"/*) : ;; *) return 1 ;; esac
  [[ "${_target#"$_versions"/}" =~ ^[0-9A-Za-z._+-]+$ ]] || return 1
  _canonical="$(_mdm_canonical_file "$_target")" || return 1
  [[ "$_canonical" == "$_target" && -x "$_target" ]] || return 1
  _mode="$(_mdm_stat_mode "$_target")" || return 1
  _mdm_mode_owner_executable "$_mode" || return 1
  _target_uid="$(_mdm_stat_uid "$_home")" || return 1
  [[ "$_target_uid" =~ ^[0-9]+$ ]] || return 1
  _old_umask="$(umask)"; umask 077
  _snapshot="$(/usr/bin/mktemp "$(_mdm_safe_tmpdir)/claude-kit-mdm-cli.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  if ! _mdm_snapshot_bound_to "$_target" "$_snapshot" cli "$_target_uid"; then
    /bin/rm -f "$_snapshot"
    return 1
  fi
  if ! _mdm_mode_owner_executable "$_MDM_BOUND_SNAPSHOT_MODE"; then
    /bin/rm -f "$_snapshot"
    return 1
  fi
  /bin/chmod 700 "$_snapshot" || { /bin/rm -f "$_snapshot"; return 1; }
  if _mdm_claude_cli_signature_trusted "$_snapshot"; then
    _rc=0
  fi
  /bin/rm -f "$_snapshot"
  return "$_rc"
}

_mdm_repo_url() {
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && -n "${MDM_KIT_REPO_URL_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_KIT_REPO_URL_OVERRIDE"
  else
    printf '%s' "$_MDM_KIT_REPO_URL"
  fi
}

_mdm_auth_tmp_base() {
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && -n "${MDM_AUTH_TMPDIR_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_AUTH_TMPDIR_OVERRIDE"
  else
    printf '%s' /private/tmp
  fi
}

_mdm_auth_expected_uid() {
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && -n "${MDM_AUTH_OWNER_UID_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_AUTH_OWNER_UID_OVERRIDE"
  else
    printf '0'
  fi
}

_mdm_auth_base_trusted() {
  local _base="$1" _physical _uid _mode
  [[ -d "$_base" && ! -L "$_base" ]] || return 1
  _physical="$(builtin cd -P -- "$_base" 2>/dev/null && printf '%s' "$PWD")" || return 1
  [[ "$_physical" == "$_base" ]] || return 1
  _uid="$(_mdm_stat_uid "$_base" || true)"
  [[ "$_uid" == "$(_mdm_auth_expected_uid)" ]] || return 1
  _mdm_has_extended_acl "$_base" && return 1
  _mode="$(_mdm_launcher_stat_mode "$_base" || true)"
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && -n "${MDM_AUTH_TMPDIR_OVERRIDE:-}" ]]; then
    _mdm_mode_is_safe "$_mode"
  else
    [[ "$_base" == /private/tmp && "$_mode" == 1777 ]]
  fi
}

# Privileged Git never reads system/global configuration, credentials, hooks,
# or a target-user environment.  The only production remote is the constant
# official URL returned by _mdm_repo_url.
_mdm_auth_git() {
  local _key _value
  local _env=(
    /usr/bin/env -i
    HOME=/var/root
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    LC_ALL=C
    GIT_CONFIG_NOSYSTEM=1
    GIT_CONFIG_GLOBAL=/dev/null
    GIT_TERMINAL_PROMPT=0
    GIT_NO_REPLACE_OBJECTS=1
  )
  for _key in HTTP_PROXY HTTPS_PROXY; do
    _value="${!_key:-}"
    [[ -z "$_value" ]] && continue
    _mdm_root_proxy_url "$_value" >/dev/null || return "$MDM_EXIT_CONFIG"
    _env[${#_env[@]}]="$_key=$_value"
  done
  if [[ -n "${NO_PROXY:-}" ]]; then
    [[ ! "$NO_PROXY" =~ [[:space:][:cntrl:]] ]] || return "$MDM_EXIT_CONFIG"
    _env[${#_env[@]}]="NO_PROXY=$NO_PROXY"
  fi
  "${_env[@]}" /usr/bin/git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}

_mdm_auth_git_network() {
  local _deadline
  _deadline="$(_mdm_timeout_seconds "$_MDM_TIMEOUT_GIT_SECONDS")" || return 1
  _mdm_run_with_timeout "$_deadline" _mdm_auth_git \
    -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 "$@"
}

# Keep exact release/prerelease tags as-is.  For commits after a tag, encode
# git-describe's distance/hash suffix as build metadata so it does not become
# a SemVer prerelease accidentally (v1.2.3-4-gabc -> v1.2.3+4.gabc).
_mdm_describe_kit_version() { # <_mdm_git|_mdm_auth_git> <repo>
  local _git_runner="$1" _repo="$2" _exact="" _described=""
  local _base _distance _abbrev
  case "$_git_runner" in _mdm_git|_mdm_auth_git) : ;; *) printf 'unknown'; return 0 ;; esac

  _exact="$("$_git_runner" -C "$_repo" describe --tags --exact-match \
    2>/dev/null || true)"
  if [[ -n "$_exact" ]]; then
    printf '%s' "$_exact"
    return 0
  fi

  _described="$("$_git_runner" -C "$_repo" describe --tags --long --always \
    2>/dev/null || true)"
  if [[ "$_described" =~ ^(.+)-([0-9]+)-g([0-9a-f]+)$ ]]; then
    _base="${BASH_REMATCH[1]}"
    _distance="${BASH_REMATCH[2]}"
    _abbrev="${BASH_REMATCH[3]}"
    if [[ "$_base" == *+* ]]; then
      printf '%s.%s.g%s' "$_base" "$_distance" "$_abbrev"
    else
      printf '%s+%s.g%s' "$_base" "$_distance" "$_abbrev"
    fi
  elif [[ -n "$_described" ]]; then
    printf '%s' "$_described"
  else
    printf 'unknown'
  fi
}

_mdm_canonical_any() {
  local _path="$1" _target _dir _base _physical _hops=0
  while [[ -L "$_path" ]]; do
    _hops=$((_hops + 1)); [[ "$_hops" -le 40 ]] || return 1
    _mdm_readlink_exact "$_path" _target || return 1
    [[ "$_target" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    if [[ "$_target" == /* ]]; then
      _path="$_target"
    else
      _path="$(/usr/bin/dirname "$_path")/$_target"
    fi
    _dir="$(/usr/bin/dirname "$_path")"
    _base="$(/usr/bin/basename "$_path")"
    _physical="$(builtin cd -P -- "$_dir" 2>/dev/null && printf '%s' "$PWD")" || return 1
    _path="$_physical/$_base"
  done
  if [[ -d "$_path" ]]; then
    builtin cd -P -- "$_path" 2>/dev/null && printf '%s' "$PWD"
  elif [[ -e "$_path" ]]; then
    _dir="$(/usr/bin/dirname "$_path")"
    _base="$(/usr/bin/basename "$_path")"
    _physical="$(builtin cd -P -- "$_dir" 2>/dev/null && printf '%s' "$PWD")" || return 1
    printf '%s/%s' "$_physical" "$_base"
  else
    return 1
  fi
}

_MDM_AUTH_ENTRY_LIST=""
_MDM_AUTH_ENTRY_LIST_OWNER_UID=""
_mdm_runtime_artifact_uid() {
  /usr/bin/id -u
}

_mdm_auth_entry_list() { # <tree> <output-var>
  local _tree="$1" _output_var="$2" _base _output _old_umask _runtime_uid
  local _identity
  _base="$(_mdm_auth_tmp_base)"
  _runtime_uid="$(_mdm_runtime_artifact_uid)" || return 1
  [[ "$_runtime_uid" =~ ^[0-9]+$ ]] || return 1
  _old_umask="$(umask)"; umask 077
  _output="$(/usr/bin/mktemp "$_base/claude-kit-mdm-list.XXXXXX" 2>/dev/null)" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  _MDM_AUTH_ENTRY_LIST="$_output"
  _MDM_AUTH_ENTRY_LIST_OWNER_UID="$_runtime_uid"
  _identity="$(LC_ALL=C _mdm_stat_identity "$_output" || true)"
  if [[ ! -f "$_output" || -L "$_output" \
    || "$(_mdm_stat_uid "$_output" || true)" != "$_runtime_uid" ]]; then
    /bin/rm -f "$_output"
    _MDM_AUTH_ENTRY_LIST=""
    _MDM_AUTH_ENTRY_LIST_OWNER_UID=""
    return 1
  fi
  case "$_identity" in
    *:Regular\ File:*|*:regular\ file:*|*:regular\ empty\ file:*) : ;;
    *)
      /bin/rm -f "$_output"
      _MDM_AUTH_ENTRY_LIST=""
      _MDM_AUTH_ENTRY_LIST_OWNER_UID=""
      return 1 ;;
  esac
  /usr/bin/find "$_tree" -xdev -print0 > "$_output" || {
    /bin/rm -f "$_output"
    _MDM_AUTH_ENTRY_LIST=""
    _MDM_AUTH_ENTRY_LIST_OWNER_UID=""
    return 1
  }
  printf -v "$_output_var" '%s' "$_output"
}

_mdm_normalize_auth_tree() {
  local _tree="$1" _entry _entry_mode _mode_dir=755 _list=""
  local _mode_exec=755 _mode_file=644
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && "${MDM_AUTH_READONLY_OWNER_TEST:-0}" == "1" ]]; then
    _mode_dir=555; _mode_exec=555; _mode_file=444
  fi
  # Never let chmod follow a repository-provided setup.sh symlink. The
  # authoritative checkout is data until its complete tree has been validated.
  [[ -f "$_tree/setup.sh" && ! -L "$_tree/setup.sh" ]] || return 1
  _mdm_auth_entry_list "$_tree" _list || return 1
  while IFS= read -r -d '' _entry; do
    if [[ -L "$_entry" ]]; then
      :
    elif [[ -d "$_entry" ]]; then
      /bin/chmod "$_mode_dir" "$_entry" || { /bin/rm -f "$_list"; _MDM_AUTH_ENTRY_LIST=""; return 1; }
    elif [[ -f "$_entry" ]]; then
      _entry_mode="$(_mdm_stat_mode "$_entry")" \
        || { /bin/rm -f "$_list"; _MDM_AUTH_ENTRY_LIST=""; return 1; }
      if _mdm_mode_owner_executable "$_entry_mode"; then
        /bin/chmod "$_mode_exec" "$_entry" || { /bin/rm -f "$_list"; _MDM_AUTH_ENTRY_LIST=""; return 1; }
      else
        /bin/chmod "$_mode_file" "$_entry" || { /bin/rm -f "$_list"; _MDM_AUTH_ENTRY_LIST=""; return 1; }
      fi
    else
      /bin/rm -f "$_list"; _MDM_AUTH_ENTRY_LIST=""
      return 1
    fi
  done < "$_list"
  /bin/rm -f "$_list"
  _MDM_AUTH_ENTRY_LIST=""
  _MDM_AUTH_ENTRY_LIST_OWNER_UID=""
  /bin/chmod "$_mode_exec" "$_tree/setup.sh"
}

_mdm_auth_tree_trusted() {
  local _tree="$1" _expected _list _entry _uid _mode _target _rc=0
  _expected="$(_mdm_auth_expected_uid)"
  [[ -d "$_tree" && ! -L "$_tree" ]] || return 1
  _list=""
  _mdm_auth_entry_list "$_tree" _list || return 1
  while IFS= read -r -d '' _entry; do
    _uid="$(_mdm_stat_uid "$_entry" || true)"
    if [[ "$_uid" != "$_expected" ]] || _mdm_has_extended_acl "$_entry"; then
      _rc=1; break
    fi
    if [[ -L "$_entry" ]]; then
      _target="$(_mdm_canonical_any "$_entry" || true)"
      case "$_target" in "$_tree"|"$_tree"/*) : ;; *) _rc=1; break ;; esac
    elif [[ -d "$_entry" || -f "$_entry" ]]; then
      _mode="$(_mdm_stat_mode "$_entry" || true)"
      _mdm_mode_is_safe "$_mode" || { _rc=1; break; }
    else
      _rc=1; break
    fi
  done < "$_list"
  /bin/rm -f "$_list"
  _MDM_AUTH_ENTRY_LIST=""
  _MDM_AUTH_ENTRY_LIST_OWNER_UID=""
  [[ "$_rc" -eq 0 && -f "$_tree/setup.sh" && ! -L "$_tree/setup.sh" ]] \
    && _mdm_mode_owner_executable "$(_mdm_stat_mode "$_tree/setup.sh")"
}

_mdm_auth_tree_private_for_uid() { # <tree> <target-uid>
  local _tree="$1" _target_uid="$2"
  [[ "$_target_uid" =~ ^[0-9]+$ ]] || return 1
  [[ "$_target_uid" != "$(_mdm_auth_expected_uid)" ]] || return 1
  _mdm_auth_tree_trusted "$_tree"
}

_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK=/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework
_MDM_SYSTEM_PYTHON_SOURCE_LINK=/Library/Developer/CommandLineTools/usr/bin/python3
_MDM_SYSTEM_PYTHON_TARGET_PATH=""
_MDM_SYSTEM_PYTHON_TARGET_FRAMEWORK_IDENTITY=""
_MDM_SYSTEM_PYTHON_TARGET_IDENTITY=""
_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE=""
_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE_IDENTITY=""
_MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK=""
_MDM_SYSTEM_PYTHON_PRIVATE_PATH=""
_MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK_IDENTITY=""
_MDM_SYSTEM_PYTHON_PRIVATE_TARGET_IDENTITY=""
_MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL=""
_MDM_SYSTEM_PYTHON_WORKSPACE_PENDING_SIGNAL=""
_MDM_FAILURE_ROLLBACK_ACTIVE=0
_MDM_FAILURE_ROLLBACK_FRESH_PRIVATE=0
_MDM_FAILURE_ROLLBACK_SOURCE_PATH=""
_MDM_FAILURE_ROLLBACK_SOURCE_FRAMEWORK_IDENTITY=""
_MDM_FAILURE_ROLLBACK_SOURCE_TARGET_IDENTITY=""
_MDM_SYSTEM_PYTHON_REBOUND_PENDING_SIGNAL=""

_mdm_system_python_codesign_requirement() {
  printf '%s' '=identifier "com.apple.python3" and anchor apple'
}

_mdm_system_python_codesign() {
  /usr/bin/codesign "$@"
}

_mdm_system_python_runtime_uid() {
  /usr/bin/id -u
}

_mdm_system_python_copy_tool() { # <source-framework> <new-destination>
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    /usr/bin/ditto --noclone --rsrc --extattr --qtn --acl \
      --nopersistRootless -X "$1" "$2"
}

_mdm_system_python_dir_trusted() { # <canonical-directory>
  local _dir="$1" _physical _uid _mode
  [[ -d "$_dir" && ! -L "$_dir" ]] || return 1
  _physical="$(builtin cd -P -- "$_dir" 2>/dev/null && printf '%s' "$PWD")" \
    || return 1
  [[ "$_physical" == "$_dir" ]] || return 1
  _uid="$(_mdm_stat_uid "$_dir")" || return 1
  [[ "$_uid" == "$(_mdm_auth_expected_uid)" ]] || return 1
  _mode="$(_mdm_launcher_stat_mode "$_dir")" || return 1
  _mdm_mode_is_safe "$_mode" || return 1
  ! _mdm_has_extended_acl "$_dir"
}

_mdm_system_python_dir_chain_trusted() { # </Library descendant directory>
  local _dir="$1" _rest _current=/Library _segment
  case "$_dir" in /Library|/Library/*) : ;; *) return 1 ;; esac
  _mdm_system_python_dir_trusted "$_current" || return 1
  _rest="${_dir#/Library}"
  while [[ -n "$_rest" ]]; do
    _rest="${_rest#/}"
    [[ -n "$_rest" ]] || break
    _segment="${_rest%%/*}"
    [[ -n "$_segment" && "$_segment" != . && "$_segment" != .. ]] || return 1
    _rest="${_rest#"$_segment"}"
    _current="$_current/$_segment"
    _mdm_system_python_dir_trusted "$_current" || return 1
  done
}

_mdm_system_python_framework_tree_properties() { # <framework-root> <expected-uid> <expected-gid> [require-single-links]
  local _root="$1" _expected_uid="$2" _expected_gid="$3"
  local _require_single_links="${4:-false}"
  local _unsafe _entry _canonical _relative _rest _flags _flag
  local _depth _count=0 _path_bytes=0 _complete=0 LC_ALL=C
  [[ "$_root" == /* && -d "$_root" && ! -L "$_root" ]] || return 1
  [[ "$(builtin cd -P -- "$_root" 2>/dev/null && printf '%s' "$PWD")" \
    == "$_root" ]] || return 1
  [[ "$_expected_uid" =~ ^[0-9]+$ && "$_expected_gid" =~ ^[0-9]+$ ]] \
    || return 1
  [[ "$_require_single_links" == true \
    || "$_require_single_links" == false ]] || return 1
  if _mdm_is_darwin; then
    _unsafe="$(LC_ALL=C /usr/bin/find -P "$_root" -xdev \
      \( ! -uid "$_expected_uid" -o ! -gid "$_expected_gid" \
        -o -perm -0020 -o -perm -0002 -o -acl \
        -o -flags +uchg -o -flags +uappnd \
        -o -flags +schg -o -flags +sappnd \
        -o ! \( -type d -o -type f -o -type l \) \) \
      -print -quit 2>/dev/null)" \
      || return 1
  else
    _unsafe="$(LC_ALL=C /usr/bin/find -P "$_root" -xdev \
      \( ! -uid "$_expected_uid" -o ! -gid "$_expected_gid" \
        -o -perm -0020 -o -perm -0002 \
        -o ! \( -type d -o -type f -o -type l \) \) \
      -print -quit 2>/dev/null)" \
      || return 1
    ! _mdm_has_extended_acl "$_root" || return 1
  fi
  [[ -z "$_unsafe" ]] || return 1
  if _mdm_is_darwin; then
    _flags="$(LC_ALL=C /usr/bin/find -P "$_root" -xdev \
      -exec /usr/bin/stat -f '%Sf' '{}' + 2>/dev/null)" || return 1
    while IFS= read -r _flag; do
      case "$_flag" in -|compressed) : ;; *) return 1 ;; esac
    done <<< "$_flags"
  fi
  if [[ "$_require_single_links" == true ]]; then
    _unsafe="$(LC_ALL=C /usr/bin/find -P "$_root" -xdev \
      ! -type d ! -links 1 -print -quit 2>/dev/null)" || return 1
    [[ -z "$_unsafe" ]] || return 1
  fi
  while IFS= read -r -d '' _entry; do
    if [[ -z "$_entry" ]]; then _complete=1; break; fi
    _count=$((_count + 1))
    _relative="${_entry#"$_root"}"
    _path_bytes=$((_path_bytes + ${#_relative}))
    [[ "$_count" -le 10000 && "$_path_bytes" -le 4194304 \
      && "$_entry" != *$'\n'* && ! "$_entry" =~ [[:cntrl:]] ]] || return 1
    case "$_entry" in "$_root"|"$_root"/*) : ;; *) return 1 ;; esac
    _rest="${_relative#/}"; _depth=0
    while [[ "$_rest" == */* ]]; do
      _depth=$((_depth + 1)); [[ "$_depth" -lt 32 ]] || return 1
      _rest="${_rest#*/}"
    done
    if [[ -L "$_entry" ]]; then
      _canonical="$(_mdm_canonical_any "$_entry")" || return 1
      case "$_canonical" in "$_root"|"$_root"/*) : ;; *) return 1 ;; esac
    fi
  done < <(
    if LC_ALL=C /usr/bin/find -P "$_root" -xdev -print0; then
      printf '\0'
    fi
  )
  [[ "$_complete" -eq 1 && "$_count" -gt 0 ]]
}

_mdm_system_python_framework_full_spec() { # <framework-root>
  local _root="$1" _keys _stderr _rc=0
  _keys=type,uid,gid,mode,nlink,size,link,sha256digest,acldigest,xattrsdigest,flags
  _mdm_is_darwin && [[ -x /usr/sbin/mtree ]] || return 1
  exec 8>&1
  _stderr="$(LC_ALL=C /usr/sbin/mtree -c -n -P -x -p "$_root" \
    -k "$_keys" 2>&1 >&8)" || _rc=$?
  exec 8>&-
  [[ "$_rc" -eq 0 && -z "$_stderr" ]]
}

_mdm_system_python_framework_full_seal() { # <framework-root>
  local _root="$1" _seal_value _spec _base _old_umask _rc=0
  [[ -d "$_root" && ! -L "$_root" ]] || return 1
  _base="$_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE"
  [[ -n "$_base" && -d "$_base" && ! -L "$_base" ]] || return 1
  _old_umask="$(umask)"; umask 077
  _spec="$(/usr/bin/mktemp "$_base/.mtree-full.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  [[ -f "$_spec" && ! -L "$_spec" ]] || _rc=1
  _old_umask="$(umask)"; umask 077
  _mdm_system_python_framework_full_spec "$_root" > "$_spec" || _rc=1
  umask "$_old_umask"
  if [[ "$_rc" -eq 0 ]]; then
    _seal_value="$(_mdm_sha256_file "$_spec")" || _rc=1
    [[ "$_seal_value" =~ ^[0-9a-f]{64}$ ]] || _rc=1
  fi
  /bin/rm -f "$_spec" || _rc=1
  [[ ! -e "$_spec" ]] || _rc=1
  [[ "$_rc" -eq 0 ]] || return 1
  printf '%s' "$_seal_value"
}

_mdm_system_python_link_trusted() { # <fixed-link> <identity-output-var>
  local _candidate_link="$1" _out_var="$2" _observed_identity
  local _observed_metadata _uid _rest _links
  [[ "$_out_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && -L "$_candidate_link" ]] \
    || return 1
  _uid="$(_mdm_stat_uid "$_candidate_link")" || return 1
  [[ "$_uid" == "$(_mdm_auth_expected_uid)" ]] || return 1
  _observed_identity="$(_mdm_stat_identity "$_candidate_link")" || return 1
  case "$_observed_identity" in *:Symbolic\ Link:*|*:symbolic\ link:*) : ;; *) return 1 ;; esac
  _observed_metadata="$(_mdm_stat_managed_metadata "$_candidate_link")" || return 1
  [[ "$_observed_metadata" =~ ^[0-9]+:[0-9]+:[0-7]+$ ]] || return 1
  _rest="${_observed_metadata#*:}"; _links="${_rest%%:*}"
  [[ "${_observed_metadata%%:*}" == "$(_mdm_auth_expected_uid)" \
    && "$_links" =~ ^[1-9][0-9]*$ ]] || return 1
  _mdm_has_extended_acl "$_candidate_link" && return 1
  printf -v "$_out_var" '%s' "$_observed_identity"
}

_mdm_system_python_resolve_fixed_link() { # <resolved-out> <chain-identity-out>
  local _resolved_out="$1" _chain_out="$2"
  local _candidate_path="$_MDM_SYSTEM_PYTHON_SOURCE_LINK" _target _parent _base
  local _physical _hop_identity _chain_record="" _hops=0 _relative _version _expected
  [[ "$_resolved_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_chain_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_resolved_out" != "$_chain_out" ]] || return 1
  while [[ -L "$_candidate_path" ]]; do
    _hops=$((_hops + 1)); [[ "$_hops" -le 8 ]] || return 1
    _mdm_system_python_dir_chain_trusted \
      "$(/usr/bin/dirname "$_candidate_path")" || return 1
    _mdm_system_python_link_trusted "$_candidate_path" _hop_identity || return 1
    _mdm_readlink_exact "$_candidate_path" _target || return 1
    [[ "$_target" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    _chain_record="${_chain_record}${_candidate_path}"$'\t'"${_hop_identity}"$'\t'"${_target}"$'\n'
    if [[ "$_target" == /* ]]; then
      _candidate_path="$_target"
    else
      _candidate_path="$(/usr/bin/dirname "$_candidate_path")/$_target"
    fi
    _parent="$(/usr/bin/dirname "$_candidate_path")"
    _base="$(/usr/bin/basename "$_candidate_path")"
    _physical="$(builtin cd -P -- "$_parent" 2>/dev/null && printf '%s' "$PWD")" \
      || return 1
    _candidate_path="$_physical/$_base"
  done
  [[ "$_hops" -ge 1 ]] || return 1
  case "$_candidate_path" in
    "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK"/Versions/*/bin/python*) : ;;
    *) return 1 ;;
  esac
  _relative="${_candidate_path#"$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK"/Versions/}"
  _version="${_relative%%/*}"
  [[ "$_version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  _expected="$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK/Versions/$_version/bin/python$_version"
  [[ "$_candidate_path" == "$_expected" ]] || return 1
  printf -v "$_resolved_out" '%s' "$_candidate_path"
  printf -v "$_chain_out" '%s' "$_chain_record"
}

_mdm_system_python_target_trusted() { # <target> <identity-out> <metadata-out>
  local _candidate="$1" _identity_out="$2" _metadata_out="$3"
  local _canonical _observed_identity _observed_metadata _uid _rest _links _mode
  [[ "$_identity_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_metadata_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_identity_out" != "$_metadata_out" ]] || return 1
  case "$_candidate" in "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK"/*) : ;; *) return 1 ;; esac
  _canonical="$(_mdm_canonical_any "$_candidate")" || return 1
  [[ "$_canonical" == "$_candidate" && -f "$_candidate" && ! -L "$_candidate" \
    && -x "$_candidate" ]] || return 1
  _mdm_system_python_dir_chain_trusted "$(/usr/bin/dirname "$_candidate")" \
    || return 1
  _observed_identity="$(_mdm_stat_identity "$_candidate")" || return 1
  case "$_observed_identity" in *:Regular\ File:*|*:regular\ file:*) : ;; *) return 1 ;; esac
  _observed_metadata="$(_mdm_stat_managed_metadata "$_candidate")" || return 1
  [[ "$_observed_metadata" =~ ^[0-9]+:[0-9]+:[0-7]+$ ]] || return 1
  _uid="${_observed_metadata%%:*}"; _rest="${_observed_metadata#*:}"
  _links="${_rest%%:*}"; _mode="${_rest#*:}"
  [[ "$_uid" == "$(_mdm_auth_expected_uid)" \
    && "$_links" =~ ^[1-9][0-9]*$ ]] || return 1
  _mdm_mode_is_safe "$_mode" && _mdm_mode_owner_executable "$_mode" || return 1
  _mdm_has_extended_acl "$_candidate" && return 1
  printf -v "$_identity_out" '%s' "$_observed_identity"
  printf -v "$_metadata_out" '%s' "$_observed_metadata"
}

_mdm_system_python_resource_envelope_v2() { # <signed-framework> [scratch-directory]
  local _framework="$1" _base _stdout _stderr _old_umask _rc=0
  _base="${2:-$_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE}"
  [[ -d "$_framework" && ! -L "$_framework" \
    && -n "$_base" && -d "$_base" && ! -L "$_base" ]] || return 1
  _old_umask="$(umask)"; umask 077
  _stdout="$(/usr/bin/mktemp "$_base/.codesign-out.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  _stderr="$(/usr/bin/mktemp "$_base/.codesign-err.XXXXXX")" \
    || { umask "$_old_umask"; /bin/rm -f "$_stdout"; return 1; }
  umask "$_old_umask"
  [[ -f "$_stdout" && ! -L "$_stdout" \
    && -f "$_stderr" && ! -L "$_stderr" ]] || _rc=1
  if [[ "$_rc" -eq 0 ]]; then
    LC_ALL=C _mdm_system_python_codesign -dvv -- "$_framework" \
      > "$_stdout" 2> "$_stderr" || _rc=1
  fi
  if [[ "$_rc" -eq 0 ]]; then
    [[ ! -s "$_stdout" && -s "$_stderr" ]] || _rc=1
    LC_ALL=C /usr/bin/awk '
      /^Sealed Resources version=2([[:space:]]|$)/ { count++ }
      END { exit count == 1 ? 0 : 1 }
    ' "$_stderr" || _rc=1
  fi
  /bin/rm -f "$_stdout" "$_stderr" || _rc=1
  [[ ! -e "$_stdout" && ! -e "$_stderr" ]] || _rc=1
  [[ "$_rc" -eq 0 ]]
}

_mdm_validate_system_python() { # <path-out> <framework-id-out> <target-id-out> [scratch-directory]
  local _path_out="$1" _framework_out="$2" _target_out="$3"
  local _scratch="${4:-$_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE}"
  local _requirement _resolved_target _resolution _framework_identity _uid _gid
  local _resolved_after _resolution_after _framework_after
  local _target_identity _target_metadata _target_after _metadata_after
  [[ "$_path_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_framework_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_target_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  _mdm_system_python_dir_chain_trusted \
    "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK" || return 1
  _uid="$(_mdm_auth_expected_uid)" || return 1
  _gid="$(_mdm_stat_gid "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK")" || return 1
  _mdm_system_python_framework_tree_properties \
    "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK" "$_uid" "$_gid" || return 1
  _mdm_system_python_dir_chain_trusted \
    "$(/usr/bin/dirname "$_MDM_SYSTEM_PYTHON_SOURCE_LINK")" || return 1
  _framework_identity="$(_mdm_system_python_dir_identity \
    "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK")" \
    || return 1
  _mdm_system_python_resolve_fixed_link _resolved_target _resolution \
    || return 1
  _mdm_system_python_target_trusted \
    "$_resolved_target" _target_identity _target_metadata \
    || return 1
  _requirement="$(_mdm_system_python_codesign_requirement)" || return 1
  _mdm_system_python_codesign --verify --deep --strict -R "$_requirement" \
    -- "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK" >/dev/null 2>&1 || return 1
  _mdm_system_python_resource_envelope_v2 \
    "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK" "$_scratch" || return 1
  _mdm_system_python_dir_chain_trusted \
    "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK" || return 1
  _framework_after="$(_mdm_system_python_dir_identity \
    "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK")" || return 1
  _mdm_system_python_resolve_fixed_link _resolved_after _resolution_after \
    || return 1
  _mdm_system_python_target_trusted \
    "$_resolved_after" _target_after _metadata_after || return 1
  [[ "$_framework_after" == "$_framework_identity" \
    && "$_resolved_after" == "$_resolved_target" \
    && "$_resolution_after" == "$_resolution" \
    && "$_target_after" == "$_target_identity" \
    && "$_metadata_after" == "$_target_metadata" ]] || return 1
  printf -v "$_path_out" '%s' "$_resolved_target"
  printf -v "$_framework_out" '%s' "$_framework_identity"
  printf -v "$_target_out" '%s' "$_target_identity"
}

_mdm_system_python_raw_dir_identity() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%d:%i:%HT' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%d:%i:%F' "$1" 2>/dev/null
  fi
}

_mdm_system_python_dir_identity() {
  _mdm_system_python_raw_dir_identity "$1"
}

_mdm_system_python_source_test_workspace_base() {
  local _base="${MDM_SYSTEM_PYTHON_TMP_BASE_OVERRIDE:-}"
  local _runner_root="${MDM_TEST_TMP_ROOT:-}" _physical
  [[ "${_MDM_SOURCE_TEST_ACTIVE:-0}" == 1 \
    && "$_base" == "$_runner_root" \
    && "$_runner_root" == /* && -d "$_runner_root" \
    && ! -L "$_runner_root" ]] || return 1
  _physical="$(builtin cd -P -- "$_runner_root" 2>/dev/null \
    && printf '%s' "$PWD")" || return 1
  [[ "$_physical" == "$_runner_root" ]] || return 1
  printf '%s' "$_runner_root"
}

_mdm_system_python_workspace_base() {
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && -n "${MDM_SYSTEM_PYTHON_TMP_BASE_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_SYSTEM_PYTHON_TMP_BASE_OVERRIDE"
  elif _mdm_system_python_source_test_workspace_base >/dev/null; then
    _mdm_system_python_source_test_workspace_base
  else
    printf '%s' /private/tmp
  fi
}

_mdm_system_python_workspace_trusted() { # <workspace>
  local _workspace="$1" _base _physical _mode _uid
  _base="$(_mdm_system_python_workspace_base)" || return 1
  case "$_workspace" in "$_base"/claude-kit-mdm-python.*) : ;; *) return 1 ;; esac
  [[ -d "$_workspace" && ! -L "$_workspace" ]] || return 1
  _physical="$(builtin cd -P -- "$_workspace" 2>/dev/null && printf '%s' "$PWD")" \
    || return 1
  [[ "$_physical" == "$_workspace" ]] || return 1
  _uid="$(_mdm_stat_uid "$_workspace")" || return 1
  [[ "$_uid" == "$(_mdm_system_python_runtime_uid)" ]] || return 1
  _mode="$(_mdm_mode_normalize "$(_mdm_launcher_stat_mode "$_workspace")")" \
    || return 1
  [[ "$_mode" == 0700 ]] || return 1
  ! _mdm_has_extended_acl "$_workspace"
}

_mdm_system_python_clear_workspace_flags() { # <workspace>
  local _workspace="$1"
  _mdm_is_darwin || return 0
  /usr/bin/find -P "$_workspace" -xdev -exec /usr/bin/chflags -h \
    nouchg,nouappnd,noschg,nosappnd '{}' + 2>/dev/null
}

_mdm_system_python_cleanup_unbound_workspace() { # <new-workspace>
  local _workspace="$1" _base _physical _uid _mode _before _after
  _base="$(_mdm_system_python_workspace_base)" || return 1
  case "$_workspace" in "$_base"/claude-kit-mdm-python.*) : ;; *) return 1 ;; esac
  [[ -d "$_workspace" && ! -L "$_workspace" ]] || return 1
  _physical="$(builtin cd -P -- "$_workspace" 2>/dev/null && printf '%s' "$PWD")" \
    || return 1
  [[ "$_physical" == "$_workspace" ]] || return 1
  _uid="$(_mdm_stat_uid "$_workspace")" || return 1
  [[ "$_uid" == "$(_mdm_system_python_runtime_uid)" ]] || return 1
  _mode="$(_mdm_mode_normalize "$(_mdm_launcher_stat_mode "$_workspace")")" \
    || return 1
  [[ "$_mode" == 0700 ]] || return 1
  ! _mdm_has_extended_acl "$_workspace" || return 1
  _before="$(_mdm_system_python_raw_dir_identity "$_workspace")" || return 1
  case "$_before" in *:Directory|*:directory) : ;; *) return 1 ;; esac
  _mdm_system_python_clear_workspace_flags "$_workspace" || return 1
  /usr/bin/find -P "$_workspace" -xdev -type d \
    -exec /bin/chmod 0700 '{}' + 2>/dev/null || return 1
  _after="$(_mdm_system_python_raw_dir_identity "$_workspace")" || return 1
  [[ "$_after" == "$_before" ]] || return 1
  /bin/rm -rf "$_workspace" || return 1
  [[ ! -e "$_workspace" && ! -L "$_workspace" ]]
}

_mdm_system_python_handle_pending_signal() {
  case "$_MDM_SYSTEM_PYTHON_WORKSPACE_PENDING_SIGNAL" in
    "") return 0 ;;
    HUP) _mdm_cleanup_transient_checkouts HUP; exit 129 ;;
    INT) _mdm_cleanup_transient_checkouts INT; exit 130 ;;
    TERM) _mdm_cleanup_transient_checkouts TERM; exit 143 ;;
    *) return 1 ;;
  esac
}

_mdm_system_python_create_workspace() {
  local _base _base_physical _workspace="" _old_umask _identity="" _rc=0
  _base="$(_mdm_system_python_workspace_base)" || return 1
  [[ -d "$_base" && ! -L "$_base" ]] || return 1
  _base_physical="$(builtin cd -P -- "$_base" 2>/dev/null && printf '%s' "$PWD")" \
    || return 1
  [[ "$_base_physical" == "$_base" ]] || return 1
  if [[ "${_MDM_TEST_MODE:-0}" != 1 ]]; then
    # A source-only test may allocate the otherwise-real production copy under
    # the runner root, but the production trust precondition is still checked.
    [[ -d /private/tmp && ! -L /private/tmp \
      && "$(_mdm_stat_uid /private/tmp)" == 0 \
      && "$(_mdm_launcher_stat_mode /private/tmp)" == 1777 ]] || return 1
    _mdm_launcher_acl_safe /private/tmp || return 1
    if ! _mdm_system_python_source_test_workspace_base >/dev/null; then
      [[ "$_base" == /private/tmp ]] || return 1
    fi
  fi
  _MDM_SYSTEM_PYTHON_WORKSPACE_PENDING_SIGNAL=""
  trap '_mdm_cleanup_transient_checkouts' EXIT
  trap '_MDM_SYSTEM_PYTHON_WORKSPACE_PENDING_SIGNAL=HUP' HUP
  trap '_MDM_SYSTEM_PYTHON_WORKSPACE_PENDING_SIGNAL=INT' INT
  trap '_MDM_SYSTEM_PYTHON_WORKSPACE_PENDING_SIGNAL=TERM' TERM
  _old_umask="$(umask)"; umask 077
  _workspace="$(/usr/bin/mktemp -d "$_base/claude-kit-mdm-python.XXXXXX")" \
    || _rc=1
  umask "$_old_umask"
  if [[ "$_rc" -eq 0 ]]; then
    _MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE="$_workspace"
    _identity="$(_mdm_system_python_dir_identity "$_workspace")" || _rc=1
  fi
  if [[ "$_rc" -eq 0 ]]; then
    case "$_identity" in *:Directory|*:directory) : ;; *) _rc=1 ;; esac
  fi
  if [[ "$_rc" -eq 0 ]]; then
    _MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE_IDENTITY="$_identity"
    /bin/chmod 0700 "$_workspace" || _rc=1
    _mdm_system_python_workspace_trusted "$_workspace" || _rc=1
  fi
  if [[ "$_rc" -ne 0 && -n "$_workspace" ]]; then
    if [[ -n "$_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE_IDENTITY" ]]; then
      _mdm_cleanup_system_python_workspace || _rc=1
    else
      if _mdm_system_python_cleanup_unbound_workspace "$_workspace"; then
        _MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE=""
      else
        _rc=1
      fi
    fi
  fi
  _mdm_arm_transient_cleanup
  _mdm_system_python_handle_pending_signal || return 1
  [[ "$_rc" -eq 0 ]]
}

_mdm_system_python_copy_framework() { # <source> <nonexistent-destination>
  local _source="$1" _destination="$2"
  [[ -d "$_source" && ! -L "$_source" \
    && ! -e "$_destination" && ! -L "$_destination" ]] || return 1
  _mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_LOCAL_VALIDATION_SECONDS")" \
    _mdm_system_python_copy_tool "$_source" "$_destination"
}

_mdm_system_python_private_target_trusted() { # <framework> <source-target> <path-out> <identity-out> <metadata-out>
  local _framework="$1" _source_target="$2" _path_out="$3"
  local _identity_out="$4" _metadata_out="$5" _relative _version _expected
  local _candidate _canonical _identity _metadata _uid _rest _links _mode
  [[ "$_path_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_identity_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_metadata_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  case "$_source_target" in
    "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK"/Versions/*/bin/python*) : ;;
    *) return 1 ;;
  esac
  _relative="${_source_target#"$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK"/Versions/}"
  _version="${_relative%%/*}"
  [[ "$_version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  _expected="$_version/bin/python$_version"
  [[ "$_relative" == "$_expected" ]] || return 1
  _candidate="$_framework/Versions/$_expected"
  _canonical="$(_mdm_canonical_any "$_candidate")" || return 1
  [[ "$_canonical" == "$_candidate" && -f "$_candidate" \
    && ! -L "$_candidate" && -x "$_candidate" ]] || return 1
  _identity="$(_mdm_stat_identity "$_candidate")" || return 1
  case "$_identity" in *:Regular\ File:*|*:regular\ file:*) : ;; *) return 1 ;; esac
  _metadata="$(_mdm_stat_managed_metadata "$_candidate")" || return 1
  [[ "$_metadata" =~ ^[0-9]+:[0-9]+:[0-7]+$ ]] || return 1
  _uid="${_metadata%%:*}"; _rest="${_metadata#*:}"
  _links="${_rest%%:*}"; _mode="${_rest#*:}"
  [[ "$_uid" == "$(_mdm_system_python_runtime_uid)" \
    && "$_links" == 1 ]] || return 1
  _mdm_mode_is_safe "$_mode" && _mdm_mode_owner_executable "$_mode" || return 1
  _mdm_has_extended_acl "$_candidate" && return 1
  printf -v "$_path_out" '%s' "$_candidate"
  printf -v "$_identity_out" '%s' "$_identity"
  printf -v "$_metadata_out" '%s' "$_metadata"
}

_mdm_validate_private_system_python() { # <framework> <source-target> <source-framework-id> <source-target-id> <path-out> <framework-id-out> <target-id-out>
  local _framework="$1" _source_target="$2"
  local _source_framework_identity="$3" _source_target_identity="$4"
  local _path_out="$5" _framework_out="$6" _target_out="$7" _requirement
  local _path_before _path_after
  local _framework_before _framework_after _target_before _target_after
  local _meta_before _meta_after _uid _gid
  [[ "$_path_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_framework_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_target_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  _uid="$(_mdm_system_python_runtime_uid)" || return 1
  _gid="$(_mdm_stat_gid "$_framework")" || return 1
  [[ "$(_mdm_stat_uid "$_framework")" == "$_uid" ]] || return 1
  _mdm_system_python_framework_tree_properties \
    "$_framework" "$_uid" "$_gid" true || return 1
  _framework_before="$(_mdm_system_python_dir_identity "$_framework")" || return 1
  _mdm_system_python_private_target_trusted "$_framework" "$_source_target" \
    _path_before _target_before _meta_before || return 1
  [[ "$_framework_before" != "$_source_framework_identity" \
    && "$_target_before" != "$_source_target_identity" ]] || return 1
  _requirement="$(_mdm_system_python_codesign_requirement)" || return 1
  _mdm_system_python_codesign --verify --deep --strict -R "$_requirement" \
    -- "$_framework" >/dev/null 2>&1 || return 1
  _mdm_system_python_resource_envelope_v2 "$_framework" || return 1
  _framework_after="$(_mdm_system_python_dir_identity "$_framework")" || return 1
  _mdm_system_python_private_target_trusted "$_framework" "$_source_target" \
    _path_after _target_after _meta_after || return 1
  [[ "$_path_after" == "$_path_before" \
    && "$_framework_after" == "$_framework_before" \
    && "$_target_after" == "$_target_before" \
    && "$_meta_after" == "$_meta_before" ]] || return 1
  printf -v "$_path_out" '%s' "$_path_before"
  printf -v "$_framework_out" '%s' "$_framework_before"
  printf -v "$_target_out" '%s' "$_target_before"
}

_mdm_system_python_private_self_test() { # <private-python> <private-framework>
  local _python="$1" _framework="$2"
  _mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_LOCAL_VALIDATION_SECONDS")" \
    /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_framework" <<'PY'
import _ctypes
import ctypes
import json
import os
import sys

root = os.path.realpath(sys.argv[1])


def contained(value):
    path = os.path.realpath(value)
    return path == root or path.startswith(root + os.sep)


values = (sys.executable, sys.prefix, json.__file__, ctypes.__file__,
          _ctypes.__file__)
if (not sys.flags.isolated or not sys.flags.dont_write_bytecode
        or not sys.flags.no_site or any(not value or not contained(value)
                                        for value in values)):
    raise SystemExit(1)
ctypes.CDLL(None)
PY
}

_mdm_system_python_private_identity_matches() {
  [[ -n "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH" \
    && -n "$_MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK" \
    && -n "$_MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK_IDENTITY" \
    && -n "$_MDM_SYSTEM_PYTHON_PRIVATE_TARGET_IDENTITY" ]] || return 1
  _mdm_system_python_workspace_trusted \
    "$_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE" || return 1
  [[ "$(_mdm_system_python_dir_identity \
      "$_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE")" \
      == "$_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE_IDENTITY" \
    && "$(_mdm_system_python_dir_identity \
      "$_MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK")" \
      == "$_MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK_IDENTITY" ]] || return 1
  case "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH" in
    "$_MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK"/Versions/*/bin/python*) : ;;
    *) return 1 ;;
  esac
  [[ -f "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH" \
    && ! -L "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH" \
    && -x "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH" \
    && "$(_mdm_stat_identity "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH")" \
      == "$_MDM_SYSTEM_PYTHON_PRIVATE_TARGET_IDENTITY" ]]
}

_mdm_system_python_cache_baseline() {
  local _captured_seal _uid _gid
  if [[ "${_MDM_TEST_MODE:-0}" == 1 ]]; then
    [[ -n "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH" \
      && "$(_mdm_source_test_system_python)" \
        == "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH" ]] || return 1
    _MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL=test-only
    return 0
  fi
  [[ -z "$_MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL" ]] || return 1
  _mdm_system_python_private_identity_matches || return 1
  _uid="$(_mdm_system_python_runtime_uid)" || return 1
  _gid="$(_mdm_stat_gid "$_MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK")" || return 1
  [[ "$(_mdm_stat_uid "$_MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK")" \
    == "$_uid" ]] || return 1
  _mdm_system_python_framework_tree_properties \
    "$_MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK" "$_uid" "$_gid" true || return 1
  _captured_seal="$(_mdm_system_python_framework_full_seal \
    "$_MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK")" || return 1
  [[ "$_captured_seal" =~ ^[0-9a-f]{64}$ ]] || return 1
  _MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL="$_captured_seal"
}

# The subshell body prevents a staged tuple from becoming runtime authority.
_mdm_system_python_staged_baseline() ( # <framework> <path> <framework-id> <target-id>
  _MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK="$1"
  _MDM_SYSTEM_PYTHON_PRIVATE_PATH="$2"
  _MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK_IDENTITY="$3"
  _MDM_SYSTEM_PYTHON_PRIVATE_TARGET_IDENTITY="$4"
  _MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL=""
  _mdm_system_python_cache_baseline || return 1
  printf '%s' "$_MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL"
)

_mdm_system_python_cache_rebound() {
  local _captured_seal
  if [[ "${_MDM_TEST_MODE:-0}" == 1 ]]; then
    [[ "$_MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL" == test-only \
      && -n "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH" \
      && "$(_mdm_source_test_system_python)" \
        == "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH" ]]
    return
  fi
  [[ "$_MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL" =~ ^[0-9a-f]{64}$ ]] \
    || return 1
  _mdm_system_python_private_identity_matches || return 1
  _captured_seal="$(_mdm_system_python_framework_full_seal \
    "$_MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK")" || return 1
  [[ "$_captured_seal" == "$_MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL" ]]
}

_mdm_system_python_cache_rebound_for_commit() {
  local _rc=0 _pending
  # A signal may arrive while the three pending traps are being installed.
  # Publish the already-bound, per-call-revalidated source fallback first, so
  # an older cleanup trap can never execute the private copy whose final seal
  # has not yet been revalidated.  A successful seal check returns authority
  # to the private copy only after normal cleanup traps are armed again.
  _MDM_FAILURE_ROLLBACK_ACTIVE=1
  _MDM_SYSTEM_PYTHON_REBOUND_PENDING_SIGNAL=""
  trap '_MDM_SYSTEM_PYTHON_REBOUND_PENDING_SIGNAL=HUP' HUP
  trap '_MDM_SYSTEM_PYTHON_REBOUND_PENDING_SIGNAL=INT' INT
  trap '_MDM_SYSTEM_PYTHON_REBOUND_PENDING_SIGNAL=TERM' TERM
  _mdm_system_python_cache_rebound || _rc=$?
  _mdm_arm_transient_signal_cleanup
  _pending="$_MDM_SYSTEM_PYTHON_REBOUND_PENDING_SIGNAL"
  _MDM_SYSTEM_PYTHON_REBOUND_PENDING_SIGNAL=""
  case "$_pending" in
    "") : ;;
    HUP) _mdm_cleanup_transient_checkouts HUP; exit 129 ;;
    INT) _mdm_cleanup_transient_checkouts INT; exit 130 ;;
    TERM) _mdm_cleanup_transient_checkouts TERM; exit 143 ;;
    *) return 1 ;;
  esac
  if [[ "$_rc" -eq 0 ]]; then
    _MDM_FAILURE_ROLLBACK_ACTIVE=0
  fi
  [[ "$_rc" -eq 0 ]]
}

_mdm_failure_rollback_source_bind() { # <path> <framework-id> <target-id>
  local _path="$1" _framework_identity="$2" _target_identity="$3"
  case "$_path" in
    "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK"/Versions/*/bin/python*) : ;;
    *) return 1 ;;
  esac
  [[ -n "$_framework_identity" && -n "$_target_identity" ]] || return 1
  if [[ -n "$_MDM_FAILURE_ROLLBACK_SOURCE_PATH" \
    || -n "$_MDM_FAILURE_ROLLBACK_SOURCE_FRAMEWORK_IDENTITY" \
    || -n "$_MDM_FAILURE_ROLLBACK_SOURCE_TARGET_IDENTITY" ]]; then
    [[ "$_path" == "$_MDM_FAILURE_ROLLBACK_SOURCE_PATH" \
      && "$_framework_identity" \
        == "$_MDM_FAILURE_ROLLBACK_SOURCE_FRAMEWORK_IDENTITY" \
      && "$_target_identity" \
        == "$_MDM_FAILURE_ROLLBACK_SOURCE_TARGET_IDENTITY" ]]
    return
  fi
  _MDM_FAILURE_ROLLBACK_SOURCE_PATH="$_path"
  _MDM_FAILURE_ROLLBACK_SOURCE_FRAMEWORK_IDENTITY="$_framework_identity"
  _MDM_FAILURE_ROLLBACK_SOURCE_TARGET_IDENTITY="$_target_identity"
}

_mdm_failure_rollback_source_python() {
  local _base _path _framework_identity _target_identity
  [[ "${_MDM_FAILURE_ROLLBACK_ACTIVE:-0}" == 1 ]] || return 1
  case "${_MDM_TRANSACTION_STATE:-idle}" in
    active|partial|aborted) : ;;
    *) return 1 ;;
  esac
  [[ -n "$_MDM_FAILURE_ROLLBACK_SOURCE_PATH" \
    && -n "$_MDM_FAILURE_ROLLBACK_SOURCE_FRAMEWORK_IDENTITY" \
    && -n "$_MDM_FAILURE_ROLLBACK_SOURCE_TARGET_IDENTITY" ]] || return 1
  _base="$(_mdm_auth_tmp_base)" || return 1
  _mdm_auth_base_trusted "$_base" || return 1
  _mdm_validate_system_python _path _framework_identity _target_identity \
    "$_base" || return 1
  [[ "$_path" == "$_MDM_FAILURE_ROLLBACK_SOURCE_PATH" \
    && "$_framework_identity" \
      == "$_MDM_FAILURE_ROLLBACK_SOURCE_FRAMEWORK_IDENTITY" \
    && "$_target_identity" \
      == "$_MDM_FAILURE_ROLLBACK_SOURCE_TARGET_IDENTITY" ]] || return 1
  printf '%s' "$_path"
}

_mdm_clear_failure_rollback_runtime() {
  _MDM_FAILURE_ROLLBACK_ACTIVE=0
  _MDM_FAILURE_ROLLBACK_FRESH_PRIVATE=0
  _MDM_FAILURE_ROLLBACK_SOURCE_PATH=""
  _MDM_FAILURE_ROLLBACK_SOURCE_FRAMEWORK_IDENTITY=""
  _MDM_FAILURE_ROLLBACK_SOURCE_TARGET_IDENTITY=""
}

_mdm_system_python_recover_after_rebound_failure() {
  _MDM_FAILURE_ROLLBACK_FRESH_PRIVATE=0
  [[ "${_MDM_FAILURE_ROLLBACK_ACTIVE:-0}" == 1 ]] || return 1
  _mdm_failure_rollback_source_python >/dev/null || return 1
  if ! _mdm_cleanup_system_python_workspace; then
    _mdm_clear_system_python_runtime_state
    return 1
  fi
  if ! _mdm_initialize_system_python; then
    _mdm_clear_system_python_runtime_state
    return 1
  fi
  if ! _mdm_system_python_cache_rebound; then
    _mdm_clear_system_python_runtime_state
    return 1
  fi
  _MDM_FAILURE_ROLLBACK_FRESH_PRIVATE=1
}

_mdm_source_test_system_python() {
  local _python="${MDM_SYSTEM_PYTHON_OVERRIDE:-}"
  [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && "$_python" == /* && -f "$_python" && ! -L "$_python" \
    && -x "$_python" ]] || return 1
  printf '%s' "$_python"
}

_mdm_initialize_system_python() {
  local _source_path _source_framework_identity _source_target_identity
  local _private_path _private_framework_identity _private_target_identity
  local _destination _private_full_seal
  if [[ "${_MDM_TEST_MODE:-0}" == 1 ]]; then
    _source_path="$(_mdm_source_test_system_python)" || return 1
    _private_full_seal="$(_mdm_system_python_staged_baseline \
      "" "$_source_path" "" "")" || return 1
    [[ "$_private_full_seal" == test-only ]] || return 1
    _MDM_SYSTEM_PYTHON_TARGET_PATH="$_source_path"
    _MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL="$_private_full_seal"
    _MDM_SYSTEM_PYTHON_PRIVATE_PATH="$_source_path"
    return 0
  fi
  [[ -z "$_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE" \
    && -z "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH" ]] || return 1
  _mdm_system_python_create_workspace || return 1
  _mdm_validate_system_python _source_path _source_framework_identity \
    _source_target_identity || return 1
  _destination="$_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE/Python3.framework"
  _mdm_system_python_copy_framework \
    "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK" "$_destination" || return 1
  _mdm_validate_private_system_python "$_destination" "$_source_path" \
    "$_source_framework_identity" "$_source_target_identity" \
    _private_path _private_framework_identity \
    _private_target_identity || return 1
  _mdm_system_python_private_self_test \
    "$_private_path" "$_destination" || return 1
  _private_full_seal="$(_mdm_system_python_staged_baseline \
    "$_destination" "$_private_path" "$_private_framework_identity" \
    "$_private_target_identity")" || return 1
  [[ "$_private_full_seal" =~ ^[0-9a-f]{64}$ ]] || return 1
  _mdm_failure_rollback_source_bind "$_source_path" \
    "$_source_framework_identity" "$_source_target_identity" || return 1
  _MDM_SYSTEM_PYTHON_TARGET_FRAMEWORK_IDENTITY="$_source_framework_identity"
  _MDM_SYSTEM_PYTHON_TARGET_IDENTITY="$_source_target_identity"
  _MDM_SYSTEM_PYTHON_TARGET_PATH="$_source_path"
  _MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK_IDENTITY="$_private_framework_identity"
  _MDM_SYSTEM_PYTHON_PRIVATE_TARGET_IDENTITY="$_private_target_identity"
  _MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL="$_private_full_seal"
  _MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK="$_destination"
  _MDM_SYSTEM_PYTHON_PRIVATE_PATH="$_private_path"
}

_mdm_system_python() {
  if [[ "${_MDM_FAILURE_ROLLBACK_ACTIVE:-0}" == 1 ]]; then
    if [[ "${_MDM_FAILURE_ROLLBACK_FRESH_PRIVATE:-0}" != 1 ]]; then
      _mdm_failure_rollback_source_python
      return
    fi
    _mdm_system_python_cache_rebound || return 1
  fi
  if [[ "${_MDM_TEST_MODE:-0}" == 1 ]]; then
    if [[ -n "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH" ]]; then
      printf '%s' "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH"
    else
      _mdm_source_test_system_python
    fi
    return
  fi
  [[ -n "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH" \
    && -n "$_MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK" ]] || return 1
  case "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH" in
    "$_MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK"/Versions/*/bin/python*) : ;;
    *) return 1 ;;
  esac
  printf '%s' "$_MDM_SYSTEM_PYTHON_PRIVATE_PATH"
}

_mdm_target_system_python() {
  local _target_identity _target_metadata
  if [[ "${_MDM_FAILURE_ROLLBACK_ACTIVE:-0}" == 1 ]]; then
    _mdm_failure_rollback_source_python
    return
  fi
  if [[ "${_MDM_TEST_MODE:-0}" == 1 ]]; then
    _mdm_source_test_system_python
    return
  fi
  [[ -n "$_MDM_SYSTEM_PYTHON_TARGET_PATH" \
    && -n "$_MDM_SYSTEM_PYTHON_TARGET_FRAMEWORK_IDENTITY" \
    && -n "$_MDM_SYSTEM_PYTHON_TARGET_IDENTITY" ]] || return 1
  case "$_MDM_SYSTEM_PYTHON_TARGET_PATH" in
    "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK"/Versions/*/bin/python*) : ;;
    *) return 1 ;;
  esac
  _mdm_system_python_dir_chain_trusted \
    "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK" || return 1
  [[ "$(_mdm_system_python_dir_identity \
    "$_MDM_SYSTEM_PYTHON_SOURCE_FRAMEWORK")" \
      == "$_MDM_SYSTEM_PYTHON_TARGET_FRAMEWORK_IDENTITY" ]] || return 1
  _mdm_system_python_target_trusted "$_MDM_SYSTEM_PYTHON_TARGET_PATH" \
    _target_identity _target_metadata || return 1
  [[ "$_target_identity" == "$_MDM_SYSTEM_PYTHON_TARGET_IDENTITY" ]] \
    || return 1
  printf '%s' "$_MDM_SYSTEM_PYTHON_TARGET_PATH"
}

_mdm_expected_tree_trusted() { # <rendered-output> [expected-owner-uid]
  local _root="$1" _physical _list="" _entry _uid _mode _identity _size
  local _metadata _metadata_rest _links
  local _count=0 _aggregate=0 _expected="${2:-}" _rc=0
  [[ -d "$_root" && ! -L "$_root" ]] || return 1
  _physical="$(builtin cd -P -- "$_root" 2>/dev/null && printf '%s' "$PWD")" || return 1
  [[ "$_physical" == "$_root" ]] || return 1
  [[ -n "$_expected" ]] || _expected="$(_mdm_auth_expected_uid)"
  [[ "$_expected" =~ ^[0-9]+$ ]] || return 1
  _mdm_auth_entry_list "$_root" _list || return 1
  if [[ "${_MDM_AUTH_ENTRY_LIST_OWNER_UID:-}" != "$_expected" ]]; then
    _rc=1
  else
    while IFS= read -r -d '' _entry; do
      _count=$((_count + 1))
      if [[ "$_count" -gt 2000 || -L "$_entry" ]]; then _rc=1; break; fi
      _uid="$(_mdm_stat_uid "$_entry" || true)"
      if [[ "$_uid" != "$_expected" ]] || _mdm_has_extended_acl "$_entry"; then
        _rc=1; break
      fi
      _mode="$(_mdm_launcher_stat_mode "$_entry" || true)"
      _mdm_mode_is_safe "$_mode" || { _rc=1; break; }
      if [[ -f "$_entry" ]]; then
        _identity="$(_mdm_stat_identity "$_entry" || true)"
        case "$_identity" in
          *:Regular\ File:*|*:regular\ file:*) : ;;
          *) _rc=1; break ;;
        esac
        _metadata="$(_mdm_stat_managed_metadata "$_entry" || true)"
        if [[ ! "$_metadata" =~ ^[0-9]+:[0-9]+:[0-7]+$ ]]; then
          _rc=1; break
        fi
        _metadata_rest="${_metadata#*:}"
        _links="${_metadata_rest%%:*}"
        _size="${_identity##*:}"
        if [[ "$_links" != 1 || ! "$_size" =~ ^[0-9]+$ \
          || "$_size" -gt 67108864 ]]; then
          _rc=1; break
        fi
        _aggregate=$((_aggregate + 10#$_size))
        (( _aggregate <= 536870912 )) || { _rc=1; break; }
      elif [[ ! -d "$_entry" ]]; then
        _rc=1; break
      fi
    done < "$_list"
  fi
  _mdm_cleanup_auth_entry_list || return 1
  [[ "$_rc" -eq 0 && "$_count" -gt 3 \
    && -d "$_root/tree" && ! -L "$_root/tree" \
    && -f "$_root/modes.tsv" && ! -L "$_root/modes.tsv" \
    && -f "$_root/policy.json" && ! -L "$_root/policy.json" \
    && -f "$_root/manifest.json" && ! -L "$_root/manifest.json" ]]
}

_mdm_expected_json_contract_valid() { # <rendered> <profile> <language> <home>
  local _root="$1" _profile="$2" _language="$3" _home="$4" _python
  local _runtime_uid _runtime_home
  _python="$(_mdm_system_python)" || return 1
  _runtime_uid="$(_mdm_runtime_artifact_uid)" || return 1
  _runtime_home="$_home"
  [[ "$_runtime_uid" == 0 ]] && _runtime_home=/var/root
  # Pass the bounded validator as argv. Bash 5.3 can retain a write end and
  # deadlock both direct and producer-pipeline forms of a large heredoc.
  /usr/bin/env -i HOME="$_runtime_home" PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S -c '
import hashlib
import json
import re
import sys

manifest_path, policy_path, profile, language, home = sys.argv[1:]
manifest_keys = [
    "schema_version", "profile", "language", "logical_home", "async_hooks",
    "required_components", "policy_sha256", "files", "absent_files",
    "entries", "total_bytes",
]
entry_keys = [
    "path", "live_mode", "snapshot_mode", "comparison", "size", "sha256",
]
policy_keys = {
    "commit_attribution", "editor_choice", "language", "profile",
    "required_components", "schema_version", "values",
}
components = {
    "biome", "claude_cli", "fonts", "ghostty", "kit", "node_runtime",
    "safety_net", "web_content_runtime",
}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def reject_constant(_value):
    raise ValueError("non-finite JSON number")


def relative(value):
    if (type(value) is not str or not value or value.startswith("/")
            or "\\" in value or len(value.encode("utf-8")) > 1024):
        return False
    parts = value.split("/")
    return (len(parts) <= 64 and all(part not in ("", ".", "..") for part in parts)
            and not any(ord(char) < 32 or 127 <= ord(char) <= 159
                        or 0xD800 <= ord(char) <= 0xDFFF for char in value))


def load(path, limit):
    with open(path, "rb") as handle:
        raw = handle.read(limit + 1)
    if len(raw) > limit or not raw.endswith(b"\n"):
        raise ValueError("invalid generated JSON size/terminator")
    value = json.loads(raw.decode("utf-8", "strict"),
                       object_pairs_hook=unique_object,
                       parse_constant=reject_constant)
    return raw, value


try:
    manifest_raw, manifest = load(manifest_path, 64 * 1024 * 1024)
    policy_raw, policy = load(policy_path, 4 * 1024 * 1024)
    if type(manifest) is not dict or list(manifest) != manifest_keys:
        raise ValueError("invalid generated manifest keys/order")
    canonical_manifest = (json.dumps(
        manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if manifest_raw != canonical_manifest:
        raise ValueError("generated manifest is not writer-canonical")
    required = manifest["required_components"]
    files = manifest["files"]
    absent = manifest["absent_files"]
    entries = manifest["entries"]
    if (type(manifest["schema_version"]) is not int
            or manifest["schema_version"] != 1
            or manifest["profile"] != profile
            or manifest["language"] != language
            or manifest["logical_home"] != home
            or manifest["async_hooks"] is not False
            or type(required) is not list or required != sorted(set(required))
            or not required or not set(required).issubset(components)
            or type(files) is not list or files != sorted(set(files))
            or not files or len(files) > 1000
            or type(absent) is not list or absent != sorted(set(absent))
            or len(absent) > 2000 or set(files) & set(absent)
            or type(entries) is not list or len(entries) != len(files)
            or type(manifest["total_bytes"]) is not int
            or manifest["total_bytes"] < 0
            or not re.fullmatch(r"[0-9a-f]{64}", manifest["policy_sha256"])
            or any(not relative(item) for item in files + absent)):
        raise ValueError("invalid generated manifest identity")
    total = 0
    for index, entry in enumerate(entries):
        if (type(entry) is not dict or list(entry) != entry_keys
                or entry["path"] != files[index]
                or entry["live_mode"] not in {"0600", "0700"}
                or entry["snapshot_mode"] not in {"0600", "0700"}
                or entry["comparison"] not in {"exact", "managed-section"}
                or type(entry["size"]) is not int or entry["size"] < 0
                or entry["size"] > 64 * 1024 * 1024
                or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"])
                or not relative(entry["path"])):
            raise ValueError("invalid generated manifest entry")
        total += entry["size"]
    if total != manifest["total_bytes"] or total > 128 * 1024 * 1024:
        raise ValueError("invalid generated manifest total")
    if type(policy) is not dict or set(policy) != policy_keys:
        raise ValueError("invalid generated policy keys")
    canonical_policy = (json.dumps(
        policy, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
        + "\n").encode("ascii")
    if policy_raw != canonical_policy:
        raise ValueError("generated policy is not writer-canonical")
    values = policy["values"]
    if (type(policy["schema_version"]) is not int
            or policy["schema_version"] != 1
            or policy["profile"] != profile or policy["language"] != language
            or policy["editor_choice"] not in {
                "none", "vscode", "cursor", "zed", "neovim"}
            or type(policy["commit_attribution"]) is not bool
            or policy["required_components"] != required
            or type(values) is not dict or not values
            or any(type(flag) is not str
                   or not (flag.startswith("ENABLE_") or flag.startswith("INSTALL_"))
                   or type(enabled) is not bool for flag, enabled in values.items())
            or hashlib.sha256(policy_raw).hexdigest()
                != manifest["policy_sha256"]):
        raise ValueError("invalid generated policy identity")
except (OSError, TypeError, UnicodeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
' "$_root/manifest.json" "$_root/policy.json" \
    "$_profile" "$_language" "$_home"
}

_mdm_prior_relative_is_safe() {
  local _relative="$1"
  [[ -n "$_relative" && "$_relative" != /* \
    && ! "$_relative" =~ [[:cntrl:]] ]] || return 1
  case "/$_relative/" in */../*|*/./*|*//*) return 1 ;; esac
  [[ "${#_relative}" -le 1024 ]]
}

# Deletion authority is independent of the target-user manifest and latest
# receipt.  Only paths that passed a prior root postcondition as actually
# deployed are persisted here; profile-disabled/absent candidates must never
# become deletion authority merely because a remediation was attempted.
_mdm_capture_prior_inventory() { # <user> <home> <target-uid> <generated-uid>
  local _user="$1" _home="$2" _target_uid="$3" _generated_uid="${4:-}"
  local _history_dir _history _history_copy="" _count _index _relative
  local _raw="" _inventory="" _old_umask _unique_count _mode _identity_tuple
  _MDM_PRIOR_INVENTORY=""
  [[ "$_target_uid" =~ ^[0-9]+$ && "$_target_uid" -ge 501 ]] || return 1
  if [[ -z "$_generated_uid" ]]; then
    _generated_uid="$(_mdm_bind_target_generated_uid "$_user")" || return 1
  fi
  _generated_uid="$(_mdm_normalize_generated_uid "$_generated_uid")" || return 1
  _identity_tuple="$(_mdm_bind_target_identity_tuple "$_user" "$_target_uid")" || return 1
  [[ "${_identity_tuple%%$'\t'*}" == "$_target_uid" \
    && "${_identity_tuple#*$'\t'}" == "$_generated_uid" ]] || return 1
  _history_dir="$(_mdm_receipt_dir_for "$_home")"
  _history="$_history_dir/managed-history-$_generated_uid.json"
  [[ -e "$_history" || -L "$_history" ]] || return 0
  if [[ "${_MDM_TEST_MODE:-0}" == 1 && -n "${MDM_SYSTEM_RCPT_DIR_OVERRIDE:-}" ]]; then
    _mdm_component_trusted "$_history_dir" || return 1
  else
    _mdm_verify_dir_chain "$_history_dir" "/Library/Application Support" || return 1
  fi
  # An invalid child cannot safely grant deletion authority, but it must not
  # permanently deny remediation either.  Ignore it and replace it with a
  # fresh root-owned schema after a successful postcondition.
  [[ -f "$_history" && ! -L "$_history" ]] || return 0
  _mdm_component_trusted "$_history" || return 0
  _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_history" 2>/dev/null || true)" 2>/dev/null || true)"
  [[ "$_mode" == 0600 ]] || return 0
  _history_copy="$(_mdm_stable_file_snapshot "$_history" history)" || return 0
  if ! _mdm_json_valid "$_history_copy" \
    || [[ "$(_mdm_json_get "$_history_copy" schema_version)" != 2 ]] \
    || [[ "$(_mdm_json_get "$_history_copy" target_uid)" != "$_target_uid" ]] \
    || [[ "$(_mdm_json_get "$_history_copy" target_generated_uid)" != "$_generated_uid" ]] \
    || [[ "$(_mdm_json_get "$_history_copy" home)" != "$_home" ]]; then
    /bin/rm -f "$_history_copy"
    return 0
  fi
  _count="$(_mdm_json_array_count "$_history_copy" managed_inventory)"
  [[ "$_count" =~ ^[0-9]+$ && "$_count" -gt 0 && "$_count" -le 2000 ]] \
    || { /bin/rm -f "$_history_copy"; return 0; }
  _old_umask="$(umask)"; umask 077
  _raw="$(/usr/bin/mktemp "$(_mdm_safe_tmpdir)/claude-kit-mdm-prior-raw.XXXXXX")" \
    || { umask "$_old_umask"; /bin/rm -f "$_history_copy"; return 1; }
  _inventory="$(/usr/bin/mktemp "$(_mdm_safe_tmpdir)/claude-kit-mdm-prior.XXXXXX")" \
    || { umask "$_old_umask"; /bin/rm -f "$_history_copy" "$_raw"; return 1; }
  umask "$_old_umask"
  _index=0
  while (( _index < _count )); do
    _relative="$(_mdm_json_array_get "$_history_copy" managed_inventory "$_index")"
    _mdm_prior_relative_is_safe "$_relative" \
      && printf '%s\n' "$_relative" >> "$_raw" \
      || { /bin/rm -f "$_history_copy" "$_raw" "$_inventory"; return 1; }
    _index=$((_index + 1))
  done
  LC_ALL=C /usr/bin/sort -u "$_raw" > "$_inventory" \
    || { /bin/rm -f "$_history_copy" "$_raw" "$_inventory"; return 1; }
  _unique_count="$(/usr/bin/wc -l < "$_inventory" | /usr/bin/tr -d '[:space:]')"
  [[ "$_unique_count" == "$_count" ]] \
    && /bin/chmod 444 "$_inventory" \
    || { /bin/rm -f "$_history_copy" "$_raw" "$_inventory"; return 1; }
  /bin/rm -f "$_history_copy" "$_raw"
  _MDM_PRIOR_INVENTORY="$_inventory"
  _mdm_arm_transient_cleanup
}

_mdm_persist_managed_history() { # <user> <home> <target-uid> <generated-uid>
  local _user="$1" _home="$2" _target_uid="${3:-}" _generated_uid="${4:-}"
  local _manifest="${_MDM_EXPECTED_OUTPUT:-}/manifest.json"
  local _dir _path _tmp _raw _count _index _relative _total=0 _old_umask _sep=""
  local _identity_tuple
  [[ -f "$_manifest" && ! -L "$_manifest" ]] || return 1
  [[ "$_target_uid" =~ ^[0-9]+$ && "$_target_uid" -ge 501 ]] || return 1
  if [[ -z "$_generated_uid" ]]; then
    _generated_uid="$(_mdm_bind_target_generated_uid "$_user")" || return 1
  fi
  _generated_uid="$(_mdm_normalize_generated_uid "$_generated_uid")" || return 1
  _identity_tuple="$(_mdm_bind_target_identity_tuple "$_user" "$_target_uid")" || return 1
  [[ "${_identity_tuple%%$'\t'*}" == "$_target_uid" \
    && "${_identity_tuple#*$'\t'}" == "$_generated_uid" ]] || return 1
  _dir="$(_mdm_receipt_dir_for "$_home")"
  _path="$_dir/managed-history-$_generated_uid.json"
  if [[ "${_MDM_TEST_MODE:-0}" == 1 && -n "${MDM_SYSTEM_RCPT_DIR_OVERRIDE:-}" ]]; then
    [[ -d "$_dir" ]] || /bin/mkdir -p "$_dir" || return 1
    _mdm_component_trusted "$_dir" || return 1
  else
    _mdm_verify_dir_chain "$_dir" "/Library/Application Support" || return 1
    /bin/mkdir -p "$_dir" || return 1
    _mdm_component_trusted "$_dir" || return 1
  fi
  [[ ! -e "$_path" || -f "$_path" || -L "$_path" ]] || return 1
  _old_umask="$(umask)"; umask 077
  _raw="$(/usr/bin/mktemp "$(_mdm_safe_tmpdir)/claude-kit-mdm-history-raw.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  _tmp="$(/usr/bin/mktemp "$_dir/.managed-history.XXXXXX")" \
    || { umask "$_old_umask"; /bin/rm -f "$_raw"; return 1; }
  umask "$_old_umask"
  _count="$(_mdm_json_array_count "$_manifest" files)"
  [[ "$_count" =~ ^[0-9]+$ && "$_count" -gt 0 && "$_count" -le 1000 ]] \
    || { /bin/rm -f "$_raw" "$_tmp"; return 1; }
  _index=0
  while (( _index < _count )); do
    _relative="$(_mdm_json_array_get "$_manifest" files "$_index")"
    _mdm_prior_relative_is_safe "$_relative" \
      && printf '%s\n' "$_relative" >> "$_raw" \
      || { /bin/rm -f "$_raw" "$_tmp"; return 1; }
    _index=$((_index + 1)); _total=$((_total + 1))
  done
  [[ "$_total" -gt 0 && "$_total" -le 2000 ]] \
    || { /bin/rm -f "$_raw" "$_tmp"; return 1; }
  LC_ALL=C /usr/bin/sort -u -o "$_raw" "$_raw" \
    || { /bin/rm -f "$_raw" "$_tmp"; return 1; }
  _total="$(/usr/bin/wc -l < "$_raw" | /usr/bin/tr -d '[:space:]')"
  [[ "$_total" =~ ^[0-9]+$ && "$_total" -gt 0 && "$_total" -le 2000 ]] \
    || { /bin/rm -f "$_raw" "$_tmp"; return 1; }
  {
    printf '{\n  "schema_version": 2,\n'
    printf '  "target_user": "%s",\n' "$(mdm_json_escape "$_user")"
    printf '  "target_uid": %s,\n' "$_target_uid"
    printf '  "target_generated_uid": "%s",\n' "$_generated_uid"
    printf '  "home": "%s",\n' "$(mdm_json_escape "$_home")"
    printf '  "managed_inventory": ['
    _sep=""
    while IFS= read -r _relative; do
      printf '%s"%s"' "$_sep" "$(mdm_json_escape "$_relative")"
      _sep=,
    done < "$_raw"
    printf ']\n}\n'
  } > "$_tmp" || { /bin/rm -f "$_raw" "$_tmp"; return 1; }
  /bin/chmod 600 "$_tmp" \
    && /bin/mv -f "$_tmp" "$_path" \
    && [[ -f "$_path" && ! -L "$_path" ]] \
    && _mdm_component_trusted "$_path" \
    && [[ "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_path")")" == 0600 ]] \
    && [[ "$(_mdm_stat_managed_metadata "$_path")" =~ ^[0-9]+:1:[0-7]+$ ]] \
    || { /bin/rm -f "$_raw" "$_tmp"; return 1; }
  /bin/rm -f "$_raw"
}

_mdm_runtime_artifact_file_trusted() { # <regular-file> <owner-uid>
  local _path="$1" _expected_uid="$2" _identity _metadata _rest _links _mode
  [[ "$_expected_uid" =~ ^[0-9]+$ && -f "$_path" && ! -L "$_path" ]] \
    || return 1
  _identity="$(_mdm_stat_identity "$_path")" || return 1
  case "$_identity" in
    *:Regular\ File:*|*:regular\ file:*) : ;;
    *) return 1 ;;
  esac
  _metadata="$(_mdm_stat_managed_metadata "$_path")" || return 1
  [[ "$_metadata" =~ ^[0-9]+:[0-9]+:[0-7]+$ ]] || return 1
  _rest="${_metadata#*:}"
  _links="${_rest%%:*}"
  _mode="$(_mdm_mode_normalize "${_rest#*:}")" || return 1
  [[ "${_metadata%%:*}" == "$_expected_uid" && "$_links" == 1 ]] \
    || return 1
  _mdm_mode_is_safe "$_mode" && ! _mdm_has_extended_acl "$_path"
}

_mdm_snapshot_checkout_renderer() { # <clean-fixed-sha-checkout> [expected-full-sha]
  local _checkout="$1" _expected_sha="${2:-}" _source _snapshot="" _runtime_uid
  local _head_before _head_after _status _source_hash _snapshot_hash _identity _size
  local _mdm_clean_renderer_snapshot=""
  [[ -d "$_checkout" && ! -L "$_checkout" ]] || return 1
  [[ -z "$_expected_sha" || "$_expected_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  _source="$_checkout/mdm/render-expected.py"
  [[ -f "$_source" && ! -L "$_source" ]] || return 1
  _runtime_uid="$(_mdm_runtime_artifact_uid)" || return 1
  [[ "$(_mdm_stat_uid "$_source" || true)" == "$_runtime_uid" ]] || return 1
  _identity="$(_mdm_stat_identity "$_source")" || return 1
  case "$_identity" in
    *:Regular\ File:*|*:regular\ file:*) : ;;
    *) return 1 ;;
  esac
  _size="${_identity##*:}"
  [[ "$_size" =~ ^[0-9]+$ && "$_size" -le 4194304 ]] || return 1
  _head_before="$(_mdm_git -C "$_checkout" rev-parse --verify HEAD 2>/dev/null)" \
    || return 1
  [[ "$_head_before" =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ -z "$_expected_sha" || "$_head_before" == "$_expected_sha" ]] || return 1
  _status="$(_mdm_git -C "$_checkout" status --porcelain \
    --untracked-files=all 2>/dev/null)" || return 1
  [[ -z "$_status" ]] || return 1
  _mdm_launcher_snapshot "$_source" _mdm_clean_renderer_snapshot || return 1
  _snapshot="$_mdm_clean_renderer_snapshot"
  _MDM_EXPECTED_RENDERER="$_snapshot"
  _MDM_EXPECTED_RENDERER_SNAPSHOT=1
  _MDM_EXPECTED_RENDERER_OWNER_UID="$_runtime_uid"
  _mdm_clean_renderer_snapshot=""
  _mdm_arm_transient_cleanup
  _mdm_runtime_artifact_file_trusted "$_snapshot" "$_runtime_uid" || return 1
  _source_hash="$(_mdm_sha256_file "$_source")" || return 1
  _snapshot_hash="$(_mdm_sha256_file "$_snapshot")" || return 1
  [[ "$_source_hash" == "$_snapshot_hash" ]] || return 1
  _head_after="$(_mdm_git -C "$_checkout" rev-parse --verify HEAD 2>/dev/null)" \
    || return 1
  _status="$(_mdm_git -C "$_checkout" status --porcelain \
    --untracked-files=all 2>/dev/null)" || return 1
  [[ "$_head_after" == "$_head_before" && -z "$_status" \
    && ( -z "$_expected_sha" || "$_head_after" == "$_expected_sha" ) ]]
}

_mdm_cleanup_expected_inflight() {
  local _path="${_mdm_expected_inflight:-}" _base _uid _runtime_uid
  [[ -n "$_path" ]] || return 0
  _base="$(_mdm_auth_tmp_base)" || return 1
  case "$_path" in "$_base"/claude-kit-mdm-expected.*) : ;; *) return 1 ;; esac
  [[ -d "$_path" && ! -L "$_path" ]] || return 1
  _runtime_uid="$(_mdm_runtime_artifact_uid)" || return 1
  _uid="$(_mdm_stat_uid "$_path" || true)"
  [[ "$_uid" == "$_runtime_uid" ]] || return 1
  /bin/rmdir "$_path" 2>/dev/null || return 1
  _mdm_expected_inflight=""
}

_mdm_prepare_expected_state() { # <logical-home> [clean-fixed-sha-checkout] [expected-full-sha]
  local _home="$1" _checkout="${2:-${_MDM_AUTH_CHECKOUT:-}}"
  local _expected_sha="${3:-}"
  local _base _workspace _output _renderer _python _old_umask _runtime_uid
  local _runtime_home
  local _mdm_expected_inflight=""
  local _key _value _normalized _cli_required _policy _policy_hash _declared_policy
  local _args=() _override_keys
  _mdm_expected_policy_input_valid || {
    mdm_log U1b "expected policy SHA-256 が未指定または不正"
    return "$MDM_EXIT_CONFIG"
  }
  [[ -n "$_checkout" && -d "$_checkout" && ! -L "$_checkout" ]] || return 1
  [[ -z "$_expected_sha" || "$_expected_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  if [[ -z "${_MDM_EXPECTED_RENDERER:-}" ]]; then
    _mdm_snapshot_checkout_renderer "$_checkout" "$_expected_sha" || {
      mdm_log U1b "checkout rendererのFD snapshotに失敗"
      return 1
    }
  fi
  _renderer="${_MDM_EXPECTED_RENDERER:-}"
  [[ -n "$_renderer" && -f "$_renderer" && ! -L "$_renderer" ]] || {
    mdm_log U1b "信頼済み期待状態rendererがない"
    return 1
  }
  if [[ "${_MDM_TEST_MODE:-0}" != 1 ]]; then
    [[ "${_MDM_EXPECTED_RENDERER_SNAPSHOT:-0}" == 1 ]] || return 1
    case "$_renderer" in /private/tmp/claude-kit-mdm-launcher.*) : ;; *) return 1 ;; esac
  fi
  _runtime_uid="$(_mdm_runtime_artifact_uid)" || return 1
  [[ -n "${_MDM_EXPECTED_RENDERER_OWNER_UID:-}" ]] \
    || _MDM_EXPECTED_RENDERER_OWNER_UID="$_runtime_uid"
  [[ "$_MDM_EXPECTED_RENDERER_OWNER_UID" == "$_runtime_uid" ]] || return 1
  _mdm_runtime_artifact_file_trusted "$_renderer" "$_runtime_uid" || return 1
  _python="$(_mdm_system_python)" || { mdm_log U1b "Apple署名済みsystem Pythonを確認できない"; return 1; }
  _base="$(_mdm_auth_tmp_base)"
  _old_umask="$(umask)"; umask 077
  _workspace="$(/usr/bin/mktemp -d "$_base/claude-kit-mdm-expected.XXXXXX" 2>/dev/null)" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  _mdm_expected_inflight="$_workspace"
  /bin/chmod 700 "$_workspace" \
    || { _mdm_cleanup_expected_inflight || true; return 1; }
  [[ "$(_mdm_stat_uid "$_workspace" || true)" == "$_runtime_uid" \
    && "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_workspace")")" == 0700 \
    && ! -L "$_workspace" ]] \
    || { _mdm_cleanup_expected_inflight || true; return 1; }
  if _mdm_has_extended_acl "$_workspace"; then
    _mdm_cleanup_expected_inflight || true
    return 1
  fi
  _MDM_EXPECTED_DIR="$_workspace"
  _MDM_EXPECTED_OUTPUT="$_workspace/rendered"
  _MDM_EXPECTED_OWNER_UID="$_runtime_uid"
  _mdm_expected_inflight=""
  _mdm_arm_transient_cleanup
  _output="$_MDM_EXPECTED_OUTPUT"
  _args=(
    --checkout "$_checkout"
    --output "$_output"
    --profile "${PROFILE:-standard}"
    --language "${LANGUAGE:-en}"
    --editor "${EDITOR_CHOICE:-none}"
    --logical-home "$_home"
  )
  _cli_required="$(_mdm_root_bool "${KIT_MDM_INSTALL_CLAUDE_CLI:-true}" 2>/dev/null || echo true)"
  _args[${#_args[@]}]=--claude-cli-required
  _args[${#_args[@]}]="$_cli_required"
  _override_keys=""
  for _key in $_MDM_ROOT_ALLOWED_KEYS; do
    case "$_key" in ENABLE_*|INSTALL_*|COMMIT_ATTRIBUTION)
      _override_keys="${_override_keys}${_override_keys:+ }$_key" ;;
    esac
  done
  for _key in $_override_keys; do
    _value="${!_key:-}"
    [[ -n "$_value" ]] || continue
    _normalized="$(_mdm_root_bool "$_value")" || return 1
    _args[${#_args[@]}]=--override
    _args[${#_args[@]}]="$_key=$_normalized"
  done
  if [[ -n "${_MDM_PRIOR_INVENTORY:-}" ]]; then
    _mdm_component_trusted "$_MDM_PRIOR_INVENTORY" || return 1
    while IFS= read -r _value || [[ -n "$_value" ]]; do
      _mdm_prior_relative_is_safe "$_value" || return 1
      _args[${#_args[@]}]=--prior-managed
      _args[${#_args[@]}]="$_value"
    done < "$_MDM_PRIOR_INVENTORY"
  fi
  mdm_log U1b "信頼済みrendererで期待状態を生成"
  _runtime_home="$_home"
  [[ "$_runtime_uid" == 0 ]] && _runtime_home=/var/root
  _mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_LOCAL_VALIDATION_SECONDS")" \
    /usr/bin/env -i HOME="$_runtime_home" PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
      "$_python" -I -B -S "$_renderer" "${_args[@]}" >/dev/null 2>&1 || return 1
  _mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_LOCAL_VALIDATION_SECONDS")" \
    _mdm_expected_tree_trusted "$_output" "$_runtime_uid" || return 1
  _mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_LOCAL_VALIDATION_SECONDS")" \
    _mdm_expected_json_contract_valid \
      "$_output" "${PROFILE:-standard}" "${LANGUAGE:-en}" "$_home" || return 1
  _policy="$_output/policy.json"
  _policy_hash="$(_mdm_sha256_file "$_policy")" || return 1
  _declared_policy="$(_mdm_json_get "$_output/manifest.json" policy_sha256)" || return 1
  [[ "$_policy_hash" =~ ^[0-9a-f]{64}$ && "$_declared_policy" == "$_policy_hash" ]] \
    || return 1
  if [[ -n "${KIT_MDM_EXPECTED_POLICY_SHA256:-}" \
    && "$KIT_MDM_EXPECTED_POLICY_SHA256" != "$_policy_hash" ]]; then
    mdm_log U1b "expected policy SHA-256 と算出値が不一致"
    return "$MDM_EXIT_CONFIG"
  fi
  KIT_MDM_POLICY_SHA256="$_policy_hash"
  MDM_RCPT_POLICY_SHA256="$_policy_hash"
  export KIT_MDM_POLICY_SHA256
  mdm_log U1b "policy_sha256=$_policy_hash"
}

MDM_REQUIRED_COMPONENTS=()
_mdm_load_expected_required_components() {
  local _manifest="${_MDM_EXPECTED_OUTPUT:-}/manifest.json" _count _index=0
  local _value _previous="" _sep="" _json="[" _has_kit=0 _has_cli=0 _cli_required
  local _has_node=0 _needs_node=0
  [[ -f "$_manifest" && ! -L "$_manifest" ]] || return 1
  _count="$(_mdm_json_array_count "$_manifest" required_components)" || return 1
  [[ "$_count" =~ ^[0-9]+$ && "$_count" -ge 1 && "$_count" -le 8 ]] || return 1
  MDM_REQUIRED_COMPONENTS=()
  while (( _index < _count )); do
    _value="$(_mdm_json_array_get "$_manifest" required_components "$_index")" || return 1
    case "$_value" in
      biome|claude_cli|fonts|ghostty|kit|node_runtime|safety_net|web_content_runtime) : ;;
      *) return 1 ;;
    esac
    [[ -z "$_previous" || "$_value" > "$_previous" ]] || return 1
    MDM_REQUIRED_COMPONENTS[${#MDM_REQUIRED_COMPONENTS[@]}]="$_value"
    _json="${_json}${_sep}\"$_value\""; _sep=,
    [[ "$_value" == kit ]] && _has_kit=1
    [[ "$_value" == claude_cli ]] && _has_cli=1
    [[ "$_value" == node_runtime ]] && _has_node=1
    case "$_value" in safety_net|web_content_runtime) _needs_node=1 ;; esac
    _previous="$_value"; _index=$((_index + 1))
  done
  _json="$_json]"
  _cli_required="$(_mdm_root_bool "${KIT_MDM_INSTALL_CLAUDE_CLI:-true}" 2>/dev/null || echo true)"
  [[ "$_has_kit" -eq 1 ]] || return 1
  if [[ "$_cli_required" == true ]]; then
    [[ "$_has_cli" -eq 1 ]] || return 1
  else
    [[ "$_has_cli" -eq 0 ]] || return 1
  fi
  [[ "$_has_node" -eq "$_needs_node" ]] || return 1
  if [[ "$_has_node" -eq 1 ]]; then
    KIT_MDM_REQUIRE_NODE_RUNTIME=true
  else
    KIT_MDM_REQUIRE_NODE_RUNTIME=false
  fi
  export KIT_MDM_REQUIRE_NODE_RUNTIME
  MDM_RCPT_REQUIRED_COMPONENTS="$_json"
}

# Detached HEAD is data, not an invitation to execute Git against a mutable
# checkout after setup. Copy it through the bounded watchdog path so a
# target-user race from a regular file to a FIFO cannot block root remediation.
_mdm_managed_dir_matches_identity() { # <dir> [expected-uid] [dev:inode:type]
  local _dir="$1" _expected_uid="${2:-}" _expected_identity="${3:-}"
  local _identity _mode
  [[ -d "$_dir" && ! -L "$_dir" ]] || return 1
  [[ "$(_mdm_canonical_dir "$_dir" || true)" == "$_dir" ]] || return 1
  [[ -z "$_expected_uid" || "$_expected_uid" =~ ^[0-9]+$ ]] || return 1
  if [[ -n "$_expected_uid" ]]; then
    [[ "$(_mdm_stat_uid "$_dir" || true)" == "$_expected_uid" ]] || return 1
  fi
  _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_dir" || true)" || true)"
  _mdm_mode_is_safe "$_mode" || return 1
  _mdm_has_extended_acl "$_dir" && return 1
  _identity="$(_mdm_persistent_dir_identity "$_dir" || true)"
  case "$_identity" in *:Directory|*:directory) : ;; *) return 1 ;; esac
  [[ -z "$_expected_identity" || "$_identity" == "$_expected_identity" ]]
}

# The retained checkout is not an execution authority, but its worktree must
# still be an exact clean representation of the pinned commit.  Include ignored
# paths explicitly: otherwise a concurrently injected ignore-matching file can
# be accepted into the first full-tree attestation baseline.
_mdm_persistent_worktree_clean() { # <repo>
  local _status
  _status="$(_mdm_git -C "$1" status --porcelain --untracked-files=all \
    --ignored=matching -- . \
    ':(exclude).claude-starter-kit-mdm-managed' 2>/dev/null)" || return 1
  [[ -z "$_status" ]]
}

_mdm_detached_head_matches() { # <repo> <full-sha> <expected-uid>
  local _repo="$1" _sha="$2" _expected_uid="${3:-}"
  local _git_dir _git_identity _head _before _size _value _snapshot _old_umask
  [[ "$_sha" =~ ^[0-9a-f]{40}$ && "$_expected_uid" =~ ^[0-9]+$ ]] \
    || return 1
  _git_dir="$_repo/.git"
  _git_identity="$(_mdm_persistent_dir_identity "$_git_dir")" || return 1
  _mdm_managed_dir_matches_identity "$_git_dir" "$_expected_uid" \
    "$_git_identity" || return 1
  _head="$_git_dir/HEAD"
  [[ -f "$_head" && ! -L "$_head" ]] || return 1
  _before="$(_mdm_stat_identity "$_head")" || return 1
  case "$_before" in *:Regular\ File:*|*:regular\ file:*) : ;; *) return 1 ;; esac
  _size="${_before##*:}"; [[ "$_size" == 41 ]] || return 1
  _old_umask="$(umask)"; umask 077
  _snapshot="$(/usr/bin/mktemp "$(_mdm_safe_tmpdir)/claude-kit-mdm-head.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  if ! _mdm_snapshot_bound_to "$_head" "$_snapshot" head "$_expected_uid"; then
    /bin/rm -f "$_snapshot"
    return 1
  fi
  IFS= read -r _value < "$_snapshot" || { /bin/rm -f "$_snapshot"; return 1; }
  /bin/rm -f "$_snapshot"
  [[ "$_value" == "$_sha" ]] || return 1
  _mdm_managed_dir_matches_identity "$_git_dir" "$_expected_uid" \
    "$_git_identity"
}

_MDM_AUTH_CHECKOUT=""
_MDM_DRYRUN_CHECKOUT=""
_MDM_PERSISTENT_STAGE=""
_MDM_PERSISTENT_STAGE_IDENTITY=""
_MDM_PERSISTENT_TRANSACTION_STATE="idle"
_MDM_PERSISTENT_INSTALL_DIR=""
_MDM_PERSISTENT_TARGET_UID=""
_MDM_PERSISTENT_PARENT_IDENTITY=""
_MDM_PERSISTENT_CANDIDATE_IDENTITY=""
_MDM_PERSISTENT_CANDIDATE_DIGEST=""
_MDM_PERSISTENT_PREVIOUS_IDENTITY=""
_MDM_PERSISTENT_PREVIOUS_DIGEST=""
_MDM_CLAUDE_TRANSACTION_STATE="idle"
_MDM_CLAUDE_LIVE=""
_MDM_CLAUDE_BACKUP=""
_MDM_CLAUDE_FAILED=""
_MDM_CLAUDE_TARGET_UID=""
_MDM_CLAUDE_PARENT_IDENTITY=""
_MDM_CLAUDE_CANDIDATE_IDENTITY=""
_MDM_CLAUDE_PREVIOUS_IDENTITY=""
_MDM_CLAUDE_PREVIOUS_DIGEST=""
_MDM_CLAUDE_MARKER_VALUE=""
_MDM_TRANSACTION_STATE="idle"
_MDM_TRANSACTION_USER=""
_MDM_TRANSACTION_HOME=""
_MDM_TRANSACTION_UID=""
_MDM_TRANSACTION_GENERATED_UID=""
_MDM_TRANSACTION_HISTORY_PATH=""
_MDM_TRANSACTION_HISTORY_STATE="untouched"
_MDM_TRANSACTION_HISTORY_SNAPSHOT=""
_MDM_TRANSACTION_COMPONENT_PATH=""
_MDM_TRANSACTION_COMPONENT_STATE="untouched"
_MDM_TRANSACTION_COMPONENT_SNAPSHOT=""
_MDM_PARENT_MODE_STATE="idle"
_MDM_PARENT_MODE_JOURNAL=""
_MDM_PARENT_MODE_JOURNAL_IDENTITY=""
_MDM_PARENT_MODE_CHECK=""
_MDM_EXTERNAL_TRANSACTION_STATE="idle"
_MDM_EXTERNAL_TRANSACTION_JOURNAL=""
_MDM_EXTERNAL_TRANSACTION_JOURNAL_IDENTITY=""
_MDM_EXTERNAL_INVENTORY_TMP=""
_MDM_EXTERNAL_INVENTORY_TMP_IDENTITY=""
_MDM_EXTERNAL_COMMIT_CARRIER=""
_MDM_EXTERNAL_COMMIT_CARRIER_IDENTITY=""
_MDM_EXTERNAL_COMMIT_ANCESTOR=""
_MDM_EXTERNAL_COMMIT_ANCESTOR_IDENTITY=""
MDM_EXTERNAL_TRANSACTION_PATHS=()
_MDM_EXPECTED_DIR=""
_MDM_EXPECTED_OUTPUT=""
_MDM_EXPECTED_OWNER_UID=""
_MDM_PRIOR_INVENTORY=""
_MDM_EXPECTED_KIT_COMPONENT_SHA256=""
_MDM_RUN_LOCK_FILE=""
_MDM_RUN_LOCK_BASE=""
_MDM_RUN_LOCK_MODE=""
_MDM_RUN_LOCK_HOLDER_PID=""
_MDM_RUN_LOCK_WORKER_PID=""
_MDM_RUN_LOCK_CONTROL_DIR=""
_MDM_RUN_LOCK_LIFETIME_FIFO=""
_MDM_RUN_LOCK_DIR_IDENTITY=""
_MDM_RUN_LOCK_ERROR=""
_MDM_ACTIVE_DROP_SUPERVISOR_PID=""
_MDM_DROP_SUPERVISOR_STARTING=0
_MDM_DROP_SUPERVISOR_PREVIOUS_BG=""

_mdm_process_parent_pid() { # <pid>
  local _pid="$1"
  [[ "$_pid" =~ ^[0-9]+$ ]] || return 1
  /bin/ps -p "$_pid" -o ppid= 2>/dev/null | /usr/bin/tr -d '[:space:]'
}

_mdm_process_start_identity() { # <pid>
  local _pid="$1" _value
  [[ "$_pid" =~ ^[0-9]+$ ]] || return 1
  _value="$(TZ=UTC0 LC_ALL=C /bin/ps -p "$_pid" -o lstart= 2>/dev/null \
    | /usr/bin/awk '{$1=$1; print}')" || return 1
  [[ -n "$_value" && ! "$_value" =~ [[:cntrl:]] ]] || return 1
  printf '%s' "$_value"
}

_MDM_LOCK_RECORD_PID=""
_MDM_LOCK_RECORD_START=""
_MDM_LOCK_RECORD_DIR=""
_mdm_record_line_matches_identity() { # <inode:type:size> <line>
  local _identity="$1" _line="$2" _size _line_size
  _size="${_identity##*:}"
  [[ "$_size" =~ ^[0-9]+$ ]] || return 1
  _line_size="$(
    printf '%s\n' "$_line" \
      | LC_ALL=C /usr/bin/wc -c \
      | /usr/bin/tr -d '[:space:]'
  )" || return 1
  [[ "$_line_size" =~ ^[0-9]+$ && "$_size" == "$_line_size" ]]
}

_mdm_lock_record_state() { # <record-path> <expected-dir-identity>
  local _path="$1" _expected_dir="$2" _before _opened _after _meta _rest _mode
  local _line="" _pid _start _dir _tail _current_start
  _MDM_LOCK_RECORD_PID=""; _MDM_LOCK_RECORD_START=""; _MDM_LOCK_RECORD_DIR=""
  [[ -e "$_path" || -L "$_path" ]] || return 3
  [[ -f "$_path" && ! -L "$_path" ]] || return 2
  _before="$(_mdm_stat_identity "$_path")" || return 2
  exec 15<"$_path" || return 2
  _opened="$(_mdm_stat_fd_identity 15)" || { exec 15<&-; return 2; }
  [[ "$_before" == "$_opened" ]] || { exec 15<&-; return 2; }
  IFS= read -r _line <&15 || { exec 15<&-; return 2; }
  _mdm_record_line_matches_identity "$_opened" "$_line" \
    || { exec 15<&-; return 2; }
  exec 15<&-
  _after="$(_mdm_stat_identity "$_path")" || return 2
  [[ "$_after" == "$_before" ]] || return 2
  _meta="$(_mdm_stat_managed_metadata "$_path")" || return 2
  [[ "$_meta" =~ ^[0-9]+:1:[0-7]+$ ]] || return 2
  _rest="${_meta#*:}"; _rest="${_rest#*:}"
  _mode="$(_mdm_mode_normalize "$_rest")" || return 2
  [[ "$(_mdm_stat_uid "$_path" || true)" == "$(_mdm_auth_expected_uid)" \
    && "$_mode" == 0600 ]] || return 2
  _mdm_has_extended_acl "$_path" && return 2
  _pid="${_line%%$'\t'*}"; _tail="${_line#*$'\t'}"
  [[ "$_tail" != "$_line" ]] || return 2
  _start="${_tail%%$'\t'*}"; _dir="${_tail#*$'\t'}"
  [[ "$_dir" != "$_tail" && "$_pid" =~ ^[0-9]+$ \
    && -n "$_start" && ! "$_start" =~ [[:cntrl:]] \
    && "$_dir" == "$_expected_dir" ]] || return 2
  _MDM_LOCK_RECORD_PID="$_pid"
  _MDM_LOCK_RECORD_START="$_start"
  _MDM_LOCK_RECORD_DIR="$_dir"
  /bin/kill -0 "$_pid" 2>/dev/null || return 1
  _current_start="$(_mdm_process_start_identity "$_pid" || true)"
  [[ -n "$_current_start" && "$_current_start" == "$_start" ]] || return 1
  return 0
}

_MDM_REAP_RECORD_PID=""
_MDM_REAP_RECORD_START=""
_MDM_REAP_RECORD_CONTROL=""
_MDM_REAP_RECORD_DIR=""
_mdm_reap_record_state() { # <record> <control-identity> <reap-identity>
  local _path="$1" _expected_control="$2" _expected_reap="$3"
  local _before _opened _after _meta _rest _mode _line=""
  local _pid _start _control _reap _tail _current_start
  _MDM_REAP_RECORD_PID=""; _MDM_REAP_RECORD_START=""
  _MDM_REAP_RECORD_CONTROL=""; _MDM_REAP_RECORD_DIR=""
  [[ -e "$_path" || -L "$_path" ]] || return 3
  [[ -f "$_path" && ! -L "$_path" ]] || return 2
  _before="$(_mdm_stat_identity "$_path")" || return 2
  exec 15<"$_path" || return 2
  _opened="$(_mdm_stat_fd_identity 15)" || { exec 15<&-; return 2; }
  [[ "$_opened" == "$_before" ]] || { exec 15<&-; return 2; }
  IFS= read -r _line <&15 || { exec 15<&-; return 2; }
  _mdm_record_line_matches_identity "$_opened" "$_line" \
    || { exec 15<&-; return 2; }
  exec 15<&-
  _after="$(_mdm_stat_identity "$_path")" || return 2
  [[ "$_after" == "$_before" ]] || return 2
  _meta="$(_mdm_stat_managed_metadata "$_path")" || return 2
  [[ "$_meta" =~ ^[0-9]+:1:[0-7]+$ ]] || return 2
  _rest="${_meta#*:}"; _rest="${_rest#*:}"
  _mode="$(_mdm_mode_normalize "$_rest")" || return 2
  [[ "$(_mdm_stat_uid "$_path" || true)" == "$(_mdm_auth_expected_uid)" \
    && "$_mode" == 0600 ]] || return 2
  _mdm_has_extended_acl "$_path" && return 2
  _pid="${_line%%$'\t'*}"; _tail="${_line#*$'\t'}"
  [[ "$_tail" != "$_line" ]] || return 2
  _start="${_tail%%$'\t'*}"; _tail="${_tail#*$'\t'}"
  _control="${_tail%%$'\t'*}"; _reap="${_tail#*$'\t'}"
  [[ "$_reap" != "$_tail" && "$_pid" =~ ^[0-9]+$ \
    && -n "$_start" && ! "$_start" =~ [[:cntrl:]] \
    && "$_control" == "$_expected_control" \
    && "$_reap" == "$_expected_reap" ]] || return 2
  _MDM_REAP_RECORD_PID="$_pid"
  _MDM_REAP_RECORD_START="$_start"
  _MDM_REAP_RECORD_CONTROL="$_control"
  _MDM_REAP_RECORD_DIR="$_reap"
  /bin/kill -0 "$_pid" 2>/dev/null || return 1
  _current_start="$(_mdm_process_start_identity "$_pid" || true)"
  [[ -n "$_current_start" && "$_current_start" == "$_start" ]] || return 1
  return 0
}

_MDM_REAP_CLAIM_IDENTITY=""
_mdm_mkdir_reap_claim_create() { # <control> <control-identity>
  local _control="$1" _expected="$2" _reap _owner _identity _start
  local _owner_tmp _old_umask _state=0
  _MDM_REAP_CLAIM_IDENTITY=""
  _reap="$_control/.reap"; _owner="$_reap/owner"
  /bin/mkdir "$_reap" 2>/dev/null || return 1
  /bin/chmod 700 "$_reap" || return 1
  _mdm_component_trusted "$_reap" || return 1
  [[ "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_reap")")" == 0700 ]] \
    || return 1
  _mdm_has_extended_acl "$_reap" && return 1
  [[ "$(_mdm_persistent_dir_identity "$_control" || true)" == "$_expected" ]] \
    || return 1
  _identity="$(_mdm_persistent_dir_identity "$_reap" || true)"
  [[ -n "$_identity" ]] || return 1
  _start="$(_mdm_process_start_identity "$$" || true)"
  [[ -n "$_start" ]] || return 1
  _owner_tmp="$_reap/.owner.init.$$"
  _old_umask="$(umask)"; umask 077
  (set -o noclobber
   printf '%s\t%s\t%s\t%s\n' "$$" "$_start" "$_expected" "$_identity" \
     > "$_owner_tmp") 2>/dev/null
  _state=$?
  umask "$_old_umask"
  [[ "$_state" -eq 0 ]] || return 1
  /bin/chmod 600 "$_owner_tmp" || return 1
  [[ "$(_mdm_persistent_dir_identity "$_control" || true)" == "$_expected" \
    && "$(_mdm_persistent_dir_identity "$_reap" || true)" == "$_identity" ]] \
    || return 1
  /bin/mv "$_owner_tmp" "$_owner" || return 1
  if _mdm_reap_record_state "$_owner" "$_expected" "$_identity"; then
    _state=0
  else
    _state=$?
  fi
  [[ "$_state" -eq 0 && "$_MDM_REAP_RECORD_PID" == "$$" \
    && "$(_mdm_persistent_dir_identity "$_control" || true)" == "$_expected" \
    && "$(_mdm_persistent_dir_identity "$_reap" || true)" == "$_identity" ]] \
    || return 1
  _MDM_REAP_CLAIM_IDENTITY="$_identity"
}

_mdm_mkdir_reap_claim_release() { # <control> <control-id> <reap-id>
  local _control="$1" _expected="$2" _identity="$3" _reap _owner _state
  local _entry _count=0
  _reap="$_control/.reap"; _owner="$_reap/owner"
  [[ "$(_mdm_persistent_dir_identity "$_control" || true)" == "$_expected" \
    && "$(_mdm_persistent_dir_identity "$_reap" || true)" == "$_identity" ]] \
    || return 1
  if _mdm_reap_record_state "$_owner" "$_expected" "$_identity"; then
    _state=0
  else
    _state=$?
  fi
  [[ "$_state" -eq 0 && "$_MDM_REAP_RECORD_PID" == "$$" ]] || return 1
  while IFS= read -r _entry; do
    [[ "$_entry" == "$_owner" ]] || return 1
    _count=$((_count + 1))
  done < <(/usr/bin/find "$_reap" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
  [[ "$_count" -eq 1 ]] || return 1
  /bin/rm -f "$_owner" || return 1
  /bin/rmdir "$_reap" || return 1
  [[ "$(_mdm_persistent_dir_identity "$_control" || true)" == "$_expected" ]]
}

_mdm_mkdir_reap_remove_worker_temps() { # <control> <control-id> <reap-id>
  local _control="$1" _expected="$2" _reap_identity="$3"
  local _entry _name _meta _rest _mode _before _after
  if ! _mdm_reap_record_state \
      "$_control/.reap/owner" "$_expected" "$_reap_identity" \
    || [[ "$_MDM_REAP_RECORD_PID" != "$$" ]]; then
    return 1
  fi
  while IFS= read -r _entry; do
    [[ -n "$_entry" && ! "$_entry" =~ [[:cntrl:]] ]] || return 1
    _name="${_entry##*/}"
    [[ ( "$_name" =~ ^\.worker\.[0-9]+$ \
        || "$_name" =~ ^\.owner\.init\.[0-9]+$ ) \
      && -f "$_entry" && ! -L "$_entry" ]] || return 1
    _meta="$(_mdm_stat_managed_metadata "$_entry")" || return 1
    [[ "$_meta" =~ ^[0-9]+:1:[0-7]+$ ]] || return 1
    _rest="${_meta#*:}"; _rest="${_rest#*:}"
    _mode="$(_mdm_mode_normalize "$_rest")" || return 1
    [[ "$(_mdm_stat_uid "$_entry" || true)" == "$(_mdm_auth_expected_uid)" \
      && "$_mode" == 0600 ]] || return 1
    _mdm_has_extended_acl "$_entry" && return 1
    _before="$(_mdm_stat_identity "$_entry")" || return 1
    /bin/rm -f "$_entry" || return 1
    _after="$(_mdm_persistent_dir_identity "$_control" || true)"
    [[ "$_after" == "$_expected" && ! -e "$_entry" && ! -L "$_entry" \
      && -n "$_before" ]] || return 1
  done < <(/usr/bin/find "$_control" -mindepth 1 -maxdepth 1 \
    \( -name '.worker.*' -o -name '.owner.init.*' \) -print 2>/dev/null)
  [[ "$(_mdm_persistent_dir_identity "$_control/.reap" || true)" \
    == "$_reap_identity" ]]
}

# Return 0 after recovering a stale/incomplete claim, 2 while a live reaper
# owns it, and 1 for malformed metadata. Every removal is generation-bound.
_mdm_mkdir_reap_recover() { # <control> <control-identity>
  local _control="$1" _expected="$2" _reap _owner _identity _state=3
  local _count=0 _entry _entries=0 _name _meta _rest _mode _init=""
  _reap="$_control/.reap"; _owner="$_reap/owner"
  [[ -d "$_reap" && ! -L "$_reap" ]] || return 1
  _mdm_component_trusted "$_reap" || return 1
  [[ "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_reap")")" == 0700 ]] \
    || return 1
  _identity="$(_mdm_persistent_dir_identity "$_reap" || true)"
  [[ -n "$_identity" \
    && "$(_mdm_persistent_dir_identity "$_control" || true)" == "$_expected" ]] \
    || return 1
  while [[ "$_count" -lt 50 && ! -e "$_owner" && ! -L "$_owner" ]]; do
    /bin/sleep 0.01
    [[ "$(_mdm_persistent_dir_identity "$_control" || true)" == "$_expected" \
      && "$(_mdm_persistent_dir_identity "$_reap" || true)" == "$_identity" ]] \
      || return 1
    _count=$((_count + 1))
  done
  if _mdm_reap_record_state "$_owner" "$_expected" "$_identity"; then
    _state=0
  else
    _state=$?
  fi
  [[ "$_state" -ne 0 ]] || return 2
  [[ "$_state" -eq 1 || "$_state" -eq 3 ]] || return 1
  while IFS= read -r _entry; do
    _entries=$((_entries + 1))
    if [[ "$_state" -eq 1 ]]; then
      [[ "$_entry" == "$_owner" ]] || return 1
    else
      _name="${_entry##*/}"
      [[ -z "$_init" && "$_name" =~ ^\.owner\.init\.[0-9]+$ \
        && -f "$_entry" && ! -L "$_entry" ]] || return 1
      _meta="$(_mdm_stat_managed_metadata "$_entry")" || return 1
      [[ "$_meta" =~ ^[0-9]+:1:[0-7]+$ ]] || return 1
      _rest="${_meta#*:}"; _rest="${_rest#*:}"
      _mode="$(_mdm_mode_normalize "$_rest")" || return 1
      [[ "$(_mdm_stat_uid "$_entry" || true)" == "$(_mdm_auth_expected_uid)" \
        && "$_mode" == 0600 ]] || return 1
      _mdm_has_extended_acl "$_entry" && return 1
      _init="$_entry"
    fi
  done < <(/usr/bin/find "$_reap" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
  if [[ "$_state" -eq 1 ]]; then
    [[ "$_entries" -eq 1 ]] || return 1
  else
    [[ "$_entries" -le 1 ]] || return 1
  fi
  [[ "$(_mdm_persistent_dir_identity "$_control" || true)" == "$_expected" \
    && "$(_mdm_persistent_dir_identity "$_reap" || true)" == "$_identity" ]] \
    || return 1
  [[ "$_state" -ne 1 ]] || /bin/rm -f "$_owner" || return 1
  [[ -z "$_init" ]] || /bin/rm -f "$_init" || return 1
  /bin/rmdir "$_reap" || return 1
  [[ "$(_mdm_persistent_dir_identity "$_control" || true)" == "$_expected" ]]
}

# Return 0 when this live claim may remove the generation, 2 when a live owner
# or worker still protects it, and 1 for malformed/missing authority.
_mdm_mkdir_reap_removal_state() { # <control> <control-id> <reap-id>
  local _control="$1" _expected="$2" _reap_identity="$3"
  local _state _owner="$_control/owner" _worker="$_control/worker"
  if _mdm_reap_record_state \
      "$_control/.reap/owner" "$_expected" "$_reap_identity"; then
    _state=0
  else
    _state=$?
  fi
  [[ "$_state" -eq 0 && "$_MDM_REAP_RECORD_PID" == "$$" \
    && "$(_mdm_persistent_dir_identity "$_control" || true)" == "$_expected" \
    && "$(_mdm_persistent_dir_identity "$_control/.reap" || true)" \
      == "$_reap_identity" ]] || return 1

  if _mdm_lock_record_state "$_owner" "$_expected"; then
    _state=0
  else
    _state=$?
  fi
  case "$_state" in
    0) [[ "$_MDM_LOCK_RECORD_PID" == "$$" ]] || return 2 ;;
    1|3) : ;;
    2) return 1 ;;
    *) return 1 ;;
  esac
  if _mdm_lock_record_state "$_worker" "$_expected"; then
    _state=0
  else
    _state=$?
  fi
  case "$_state" in
    0) return 2 ;;
    1|3) : ;;
    2) return 1 ;;
    *) return 1 ;;
  esac

  if _mdm_reap_record_state \
      "$_control/.reap/owner" "$_expected" "$_reap_identity"; then
    _state=0
  else
    _state=$?
  fi
  [[ "$_state" -eq 0 && "$_MDM_REAP_RECORD_PID" == "$$" \
    && "$(_mdm_persistent_dir_identity "$_control" || true)" == "$_expected" \
    && "$(_mdm_persistent_dir_identity "$_control/.reap" || true)" \
      == "$_reap_identity" ]]
}

_mdm_lock_control_cleanup() { # <base> <control-dir>
  local _base="$1" _control="$2" _entry
  [[ -n "$_control" ]] || return 0
  case "$_control" in "$_base"/.remediation-lock.*) : ;; *) return 1 ;; esac
  [[ ! -L "$_control" ]] || return 1
  [[ -e "$_control" ]] || return 0
  [[ -d "$_control" ]] || return 1
  _mdm_component_trusted "$_control" || return 1
  for _entry in owner ready release; do
    [[ ! -L "$_control/$_entry" ]] || return 1
    [[ ! -e "$_control/$_entry" || -f "$_control/$_entry" ]] || return 1
  done
  [[ ! -L "$_control/lifetime" ]] || return 1
  [[ ! -e "$_control/lifetime" || -p "$_control/lifetime" ]] || return 1
  /bin/rm -f "$_control/owner" "$_control/ready" "$_control/release" \
    "$_control/lifetime" || return 1
  /bin/rmdir "$_control" 2>/dev/null || [[ ! -e "$_control" ]]
}

_mdm_wait_lock_holder() { # <holder-pid>
  local _holder="$1" _watchdog _wait_rc=0
  [[ "$_holder" =~ ^[0-9]+$ ]] || return 1
  (
    trap 'exit 0' TERM
    _watch_count=0
    while [[ "$_watch_count" -lt 500 ]]; do
      /bin/sleep 0.01
      _watch_count=$((_watch_count + 1))
    done
    /bin/kill -TERM "$_holder" 2>/dev/null || exit 0
    /bin/sleep 0.2
    /bin/kill -KILL "$_holder" 2>/dev/null || true
  ) &
  _watchdog=$!
  wait "$_holder" 2>/dev/null || _wait_rc=$?
  /bin/kill -TERM "$_watchdog" 2>/dev/null || true
  wait "$_watchdog" 2>/dev/null || true
  return "$_wait_rc"
}

_mdm_abort_legacy_lock_holder() { # <base> <control-dir> <holder-pid> <worker-pid>
  local _base="$1" _control="$2" _holder="$3" _worker="$4"
  { exec 18>&-; } 2>/dev/null || true
  if [[ "$_worker" =~ ^[0-9]+$ ]]; then
    /bin/kill -TERM "$_worker" 2>/dev/null || true
  fi
  if [[ "$_holder" =~ ^[0-9]+$ ]]; then
    /bin/kill -TERM "$_holder" 2>/dev/null || true
    _mdm_wait_lock_holder "$_holder" || true
  fi
  _mdm_lock_control_cleanup "$_base" "$_control" || true
}

_mdm_mkdir_lock_cleanup() { # <base> <control-dir> <expected-dir-identity>
  local _base="$1" _control="$2" _expected="$3" _reap _reap_identity
  local _quarantine="" _moved _entry _name _current _state=0 _count=0
  [[ "$_control" == "$_base/remediation-global.mkdir-lock" \
    && -n "$_expected" ]] || return 1
  [[ -d "$_control" && ! -L "$_control" ]] || return 1
  _current="$(_mdm_persistent_dir_identity "$_control" || true)"
  [[ "$_current" == "$_expected" ]] || return 1
  _mdm_component_trusted "$_control" || return 1

  # Unknown content is an integrity failure. Check it before creating the
  # reap claim or renaming anything so a rejected generation stays at the
  # fixed path for diagnosis and cannot be confused with its successor.
  while IFS= read -r _entry; do
    [[ -n "$_entry" && ! "$_entry" =~ [[:cntrl:]] ]] || return 1
    _name="${_entry##*/}"
    case "$_name" in
      owner|worker) [[ -f "$_entry" && ! -L "$_entry" ]] || return 1 ;;
      .worker.*) [[ "$_name" =~ ^\.worker\.[0-9]+$ \
        && -f "$_entry" && ! -L "$_entry" ]] || return 1 ;;
      .owner.init.*) [[ "$_name" =~ ^\.owner\.init\.[0-9]+$ \
        && -f "$_entry" && ! -L "$_entry" ]] || return 1 ;;
      *) return 1 ;;
    esac
  done < <(/usr/bin/find "$_control" -mindepth 1 -maxdepth 1 -print 2>/dev/null)

  # Claim this exact generation with a live process/start/identity record.
  # A successor can recover a crashed reaper without treating a bare marker
  # as permanent contention.
  _mdm_mkdir_reap_claim_create "$_control" "$_expected" || return 1
  _reap="$_control/.reap"
  _reap_identity="$_MDM_REAP_CLAIM_IDENTITY"
  _mdm_mkdir_reap_remove_worker_temps \
    "$_control" "$_expected" "$_reap_identity" || {
      _mdm_mkdir_reap_claim_release \
        "$_control" "$_expected" "$_reap_identity" || true
      return 1
    }
  if _mdm_mkdir_reap_removal_state \
      "$_control" "$_expected" "$_reap_identity"; then
    _state=0
  else
    _state=$?
  fi
  if [[ "$_state" -ne 0 ]]; then
    _mdm_mkdir_reap_claim_release \
      "$_control" "$_expected" "$_reap_identity" || return 1
    [[ "$_state" -eq 2 ]] && return 2
    return 1
  fi
  _quarantine="$(/usr/bin/mktemp -d "$_base/.remediation-reap.XXXXXX" 2>/dev/null)" \
    || { _mdm_mkdir_reap_claim_release \
      "$_control" "$_expected" "$_reap_identity" || true; return 1; }
  if ! /bin/chmod 700 "$_quarantine" \
    || ! _mdm_component_trusted "$_quarantine"; then
    /bin/rmdir "$_quarantine" 2>/dev/null || true
    _mdm_mkdir_reap_claim_release \
      "$_control" "$_expected" "$_reap_identity" || true
    return 1
  fi

  # The supervisor publishes `worker` before starting the dropped child and
  # checks for this claim both before and after publication. Re-read it here:
  # claim-first makes publication abort; worker-first makes this removal abort.
  _mdm_mkdir_reap_remove_worker_temps \
    "$_control" "$_expected" "$_reap_identity" || {
      /bin/rmdir "$_quarantine" 2>/dev/null || true
      _mdm_mkdir_reap_claim_release \
        "$_control" "$_expected" "$_reap_identity" || true
      return 1
    }
  if _mdm_mkdir_reap_removal_state \
      "$_control" "$_expected" "$_reap_identity"; then
    _state=0
  else
    _state=$?
  fi
  if [[ "$_state" -eq 0 ]]; then
    while IFS= read -r _entry; do
      [[ -n "$_entry" && ! "$_entry" =~ [[:cntrl:]] ]] \
        || { _state=1; break; }
      _name="${_entry##*/}"
      case "$_name" in
        owner|worker) [[ -f "$_entry" && ! -L "$_entry" ]] \
          || { _state=1; break; } ;;
        .reap) [[ -d "$_entry" && ! -L "$_entry" ]] \
          || { _state=1; break; } ;;
        *) _state=1; break ;;
      esac
    done < <(/usr/bin/find "$_control" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
  fi
  if [[ "$_state" -ne 0 ]]; then
    /bin/rmdir "$_quarantine" 2>/dev/null || true
    _mdm_mkdir_reap_claim_release \
      "$_control" "$_expected" "$_reap_identity" || return 1
    [[ "$_state" -eq 2 ]] && return 2
    return 1
  fi
  _moved="$_quarantine/lock"
  if ! /bin/mv "$_control" "$_moved"; then
    /bin/rmdir "$_quarantine" 2>/dev/null || true
    _mdm_mkdir_reap_claim_release \
      "$_control" "$_expected" "$_reap_identity" || true
    return 1
  fi
  [[ "$(_mdm_persistent_dir_identity "$_moved" || true)" == "$_expected" ]] \
    || return 1

  # From this point onward touch only the generation-specific quarantine.
  # A new fixed-name lock may already exist and must never be removed (ABA).
  while IFS= read -r _entry; do
    [[ -n "$_entry" && ! "$_entry" =~ [[:cntrl:]] ]] || return 1
    _name="${_entry##*/}"
    case "$_name" in
      owner|worker) [[ -f "$_entry" && ! -L "$_entry" ]] || return 1 ;;
      .reap) [[ -d "$_entry" && ! -L "$_entry" ]] || return 1 ;;
      *) return 1 ;;
    esac
  done < <(/usr/bin/find "$_moved" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
  [[ "$(_mdm_persistent_dir_identity "$_moved/.reap" || true)" \
    == "$_reap_identity" ]] || return 1
  if _mdm_reap_record_state \
      "$_moved/.reap/owner" "$_expected" "$_reap_identity"; then
    _state=0
  else
    _state=$?
  fi
  [[ "$_state" -eq 0 && "$_MDM_REAP_RECORD_PID" == "$$" ]] || return 1
  while IFS= read -r _entry; do
    [[ "$_entry" == "$_moved/.reap/owner" ]] || return 1
    _count=$((_count + 1))
  done < <(/usr/bin/find "$_moved/.reap" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
  [[ "$_count" -eq 1 ]] || return 1
  /bin/rm -f "$_moved/owner" "$_moved/worker" || return 1
  /bin/rm -f "$_moved/.reap/owner" || return 1
  /bin/rmdir "$_moved/.reap" "$_moved" "$_quarantine" || return 1
}

_mdm_mkdir_lock_wait_initialization() { # <control> <dir-identity>
  local _control="$1" _identity="$2" _count=0
  while [[ "$_count" -lt 50 ]]; do
    [[ "$(_mdm_persistent_dir_identity "$_control" || true)" == "$_identity" ]] \
      || return 1
    [[ -e "$_control/owner" || -L "$_control/owner" \
      || -e "$_control/worker" || -L "$_control/worker" ]] && return 0
    /bin/sleep 0.01
    _count=$((_count + 1))
  done
  return 0
}

_mdm_acquire_mkdir_lock() { # <base>
  local _base="$1" _control _owner_file _worker_file
  local _old_umask _attempt=0 _dir_identity="" _start="" _state=0
  _control="$_base/remediation-global.mkdir-lock"
  _owner_file="$_control/owner"
  _worker_file="$_control/worker"
  while [[ "$_attempt" -lt 3 ]]; do
    _old_umask="$(umask)"; umask 077
    if /bin/mkdir "$_control" 2>/dev/null; then
      umask "$_old_umask"
      /bin/chmod 700 "$_control" \
        || { _MDM_RUN_LOCK_ERROR=backend; return 1; }
      _mdm_component_trusted "$_control" \
        || { _MDM_RUN_LOCK_ERROR=backend; return 1; }
      _dir_identity="$(_mdm_persistent_dir_identity "$_control" || true)"
      [[ -n "$_dir_identity" ]] || { _MDM_RUN_LOCK_ERROR=backend; return 1; }
      _start="$(_mdm_process_start_identity "$$" || true)"
      [[ -n "$_start" ]] || { _MDM_RUN_LOCK_ERROR=backend; return 1; }
      _old_umask="$(umask)"; umask 077
      # Bind initialization to the directory inode via cwd. If a recovery
      # renames this incomplete generation, a delayed initializer can only
      # write into that old inode and never into a successor at the fixed path.
      (
        builtin cd -P "$_control" || exit 1
        [[ "$(_mdm_persistent_dir_identity . || true)" == "$_dir_identity" ]] \
          || exit 1
        set -o noclobber
        _owner_tmp=".owner.init.$$"
        printf '%s\t%s\t%s\n' "$$" "$_start" "$_dir_identity" \
          > "./$_owner_tmp" \
          || exit 1
        /bin/chmod 600 "./$_owner_tmp" || exit 1
        [[ "$(_mdm_persistent_dir_identity . || true)" == "$_dir_identity" ]] \
          || exit 1
        /bin/mv "./$_owner_tmp" ./owner
      ) 2>/dev/null
      _state=$?
      umask "$_old_umask"
      [[ "$_state" -eq 0 \
        && "$(_mdm_persistent_dir_identity "$_control" || true)" == "$_dir_identity" ]] \
        || { _MDM_RUN_LOCK_ERROR=backend; return 1; }
      _mdm_lock_record_state "$_owner_file" "$_dir_identity" \
        || { _MDM_RUN_LOCK_ERROR=backend; return 1; }
      _MDM_RUN_LOCK_MODE="mkdir"
      _MDM_RUN_LOCK_FILE="$_control"
      _MDM_RUN_LOCK_BASE="$_base"
      _MDM_RUN_LOCK_CONTROL_DIR="$_control"
      _MDM_RUN_LOCK_DIR_IDENTITY="$_dir_identity"
      _MDM_RUN_LOCK_ERROR=""
      return 0
    fi
    umask "$_old_umask"
    [[ -d "$_control" && ! -L "$_control" ]] \
      || { _MDM_RUN_LOCK_ERROR=backend; return 1; }
    _mdm_component_trusted "$_control" \
      || { _MDM_RUN_LOCK_ERROR=backend; return 1; }
    _dir_identity="$(_mdm_persistent_dir_identity "$_control" || true)"
    [[ -n "$_dir_identity" ]] || { _MDM_RUN_LOCK_ERROR=backend; return 1; }
    if [[ -e "$_control/.reap" || -L "$_control/.reap" ]]; then
      if _mdm_mkdir_reap_recover "$_control" "$_dir_identity"; then
        _attempt=$((_attempt + 1))
        continue
      else
        _state=$?
      fi
      if [[ "$_state" -eq 2 ]]; then
        _MDM_RUN_LOCK_ERROR=contention
      else
        _MDM_RUN_LOCK_ERROR=backend
      fi
      return 1
    fi

    if _mdm_lock_record_state "$_owner_file" "$_dir_identity"; then
      _state=0
    else
      _state=$?
    fi
    case "$_state" in
      0) _MDM_RUN_LOCK_ERROR=contention; return 1 ;;
      2) _MDM_RUN_LOCK_ERROR=backend; return 1 ;;
      3)
        _mdm_mkdir_lock_wait_initialization "$_control" "$_dir_identity" \
          || { _MDM_RUN_LOCK_ERROR=backend; return 1; }
        if _mdm_lock_record_state "$_owner_file" "$_dir_identity"; then
          _state=0
        else
          _state=$?
        fi
        case "$_state" in
          0) _MDM_RUN_LOCK_ERROR=contention; return 1 ;;
          2) _MDM_RUN_LOCK_ERROR=backend; return 1 ;;
          3) : ;;
        esac ;;
    esac
    if _mdm_lock_record_state "$_worker_file" "$_dir_identity"; then
      _state=0
    else
      _state=$?
    fi
    case "$_state" in
      0) _MDM_RUN_LOCK_ERROR=contention; return 1 ;;
      2) _MDM_RUN_LOCK_ERROR=backend; return 1 ;;
    esac
    if _mdm_mkdir_lock_cleanup "$_base" "$_control" "$_dir_identity"; then
      _state=0
    else
      _state=$?
    fi
    if [[ "$_state" -ne 0 ]]; then
      [[ "$_state" -eq 2 ]] \
        && _MDM_RUN_LOCK_ERROR=contention \
        || _MDM_RUN_LOCK_ERROR=backend
      return 1
    fi
    _attempt=$((_attempt + 1))
  done
  _MDM_RUN_LOCK_ERROR=backend
  return 1
}

_mdm_acquire_run_lock() { # <user> <home>
  local _user="$1" _home="$2" _base _lock _lockf=/usr/bin/lockf
  local _old_umask _path_identity _fd_identity _lock_rc=0
  local _control="" _owner_file _ready _release _lifetime _holder="" _worker="" _reported_holder
  local _owner_pid _ready_line _wait_count=0
  _MDM_RUN_LOCK_ERROR=backend
  _base="$(_mdm_receipt_dir_for "$_home")"
  if [[ "${_MDM_TEST_MODE:-0}" == 1 && -n "${MDM_SYSTEM_RCPT_DIR_OVERRIDE:-}" ]]; then
    [[ -d "$_base" ]] || /bin/mkdir -p "$_base" || return 1
    _mdm_component_trusted "$_base" || return 1
  else
    _mdm_verify_dir_chain "$_base" "/Library/Application Support" || return 1
    /bin/mkdir -p "$_base" || return 1
    _mdm_component_trusted "$_base" || return 1
  fi
  if [[ "${_MDM_TEST_MODE:-0}" == 1 && -n "${MDM_LOCKF_OVERRIDE:-}" ]]; then
    _lockf="$MDM_LOCKF_OVERRIDE"
  fi
  [[ "$_lockf" == /* ]] || return 1
  if [[ ! -e "$_lockf" && ! -L "$_lockf" ]]; then
    if _mdm_acquire_mkdir_lock "$_base"; then
      _mdm_arm_transient_cleanup
      return 0
    fi
    return 1
  fi
  [[ -f "$_lockf" && -x "$_lockf" && ! -L "$_lockf" ]] || return 1
  : "$_user"
  # CLT, Homebrew and compliance artifacts include host-global resources, so
  # different target users must be serialized through the same lock as well.
  _lock="$_base/remediation-global.lock"
  [[ ! -e "$_lock" || ( -f "$_lock" && ! -L "$_lock" ) ]] || return 1
  _old_umask="$(umask)"; umask 077
  if [[ ! -e "$_lock" ]]; then
    (set -o noclobber; : > "$_lock") 2>/dev/null || true
  fi
  umask "$_old_umask"
  [[ -f "$_lock" && ! -L "$_lock" ]] || return 1
  /bin/chmod 600 "$_lock" || return 1
  exec 19>>"$_lock" || return 1
  _path_identity="$(_mdm_stat_identity "$_lock")" || { exec 19>&-; return 1; }
  _fd_identity="$(_mdm_stat_fd_identity 19)" || { exec 19>&-; return 1; }
  [[ "$_path_identity" == "$_fd_identity" ]] || { exec 19>&-; return 1; }

  # shell_cmds-319 added lockf's fd-only form.  Keep that race-free form on
  # current macOS, but fall back to the traditional command form on older
  # managed releases where a missing command exits with EX_USAGE (64).
  "$_lockf" -s -t 0 19 >/dev/null 2>&1 || _lock_rc=$?
  if [[ "$_lock_rc" -eq 0 ]]; then
    _MDM_RUN_LOCK_MODE="fd"
  elif [[ "$_lock_rc" -eq 64 ]]; then
    exec 19>&-
    _old_umask="$(umask)"; umask 077
    _control="$(/usr/bin/mktemp -d "$_base/.remediation-lock.XXXXXX" 2>/dev/null)" \
      || { umask "$_old_umask"; return 1; }
    umask "$_old_umask"
    case "$_control" in "$_base"/.remediation-lock.*) : ;; *) return 1 ;; esac
    [[ -d "$_control" && ! -L "$_control" ]] || return 1
    /bin/chmod 700 "$_control" || return 1
    _mdm_component_trusted "$_control" || return 1
    _owner_file="$_control/owner"
    _ready="$_control/ready"
    _release="$_control/release"
    _lifetime="$_control/lifetime"
    /usr/bin/mkfifo "$_lifetime" || {
      _mdm_lock_control_cleanup "$_base" "$_control" || true
      return 1
    }
    /bin/chmod 600 "$_lifetime" || {
      _mdm_lock_control_cleanup "$_base" "$_control" || true
      return 1
    }
    # Open the lifetime channel before the lockf holder starts.  The wrapper
    # closes its inherited writer before exec so the holder's reader observes
    # EOF exactly when the coordinator/drop-supervisor writers are gone.
    exec 18<>"$_lifetime" || {
      _mdm_lock_control_cleanup "$_base" "$_control" || true
      return 1
    }
    _old_umask="$(umask)"; umask 077
    /bin/sh -c 'printf "%s\n" "$PPID"' > "$_owner_file"
    _lock_rc=$?
    umask "$_old_umask"
    if [[ "$_lock_rc" -ne 0 || ! -f "$_owner_file" || -L "$_owner_file" ]] \
      || ! _mdm_component_trusted "$_owner_file"; then
      _mdm_lock_control_cleanup "$_base" "$_control" || true
      return 1
    fi
    _owner_pid="$(/bin/cat "$_owner_file" 2>/dev/null || true)"
    /bin/rm -f "$_owner_file" || return 1
    [[ "$_owner_pid" =~ ^[0-9]+$ ]] \
      || { _mdm_lock_control_cleanup "$_base" "$_control" || true; return 1; }

    /bin/sh -c 'exec 18>&-; exec "$@"' mdm-lockf-wrapper \
    "$_lockf" -k -n -s -t 0 "$_lock" /bin/sh -c '
      _owner_pid=$1
      _control=$2
      _ready=$3
      _lifetime=$4
      _lockf_pid=$PPID
      _cleanup() {
        /bin/rm -f "$_control/owner" "$_ready" "$_control/release" "$_lifetime"
        /bin/rmdir "$_control" 2>/dev/null || :
      }
      trap _cleanup EXIT
      trap "exit 0" INT TERM
      umask 077
      exec 17<"$_lifetime" || exit 1
      printf "%s:%s\n" "$$" "$_lockf_pid" > "$_ready" || exit 1
      /bin/cat <&17 >/dev/null
    ' mdm-lock-holder "$_owner_pid" "$_control" "$_ready" "$_lifetime" &
    _holder=$!

    while [[ ! -e "$_ready" && "$_wait_count" -lt 500 ]]; do
      /bin/kill -0 "$_holder" 2>/dev/null || break
      /bin/sleep 0.01
      _wait_count=$((_wait_count + 1))
    done
    if [[ ! -f "$_ready" || -L "$_ready" ]] \
      || ! _mdm_component_trusted "$_ready"; then
      # `kill -0` also succeeds for an unreaped zombie. Close the lifetime
      # writer and capture the holder status through bounded wait directly;
      # EX_TEMPFAIL is lock contention, every other failure is backend damage.
      { exec 18>&-; } 2>/dev/null || true
      _lock_rc=0
      _mdm_wait_lock_holder "$_holder" || _lock_rc=$?
      _mdm_lock_control_cleanup "$_base" "$_control" || true
      if [[ "$_lock_rc" -eq 75 ]]; then
        _MDM_RUN_LOCK_ERROR=contention
      else
        _MDM_RUN_LOCK_ERROR=backend
      fi
      return 1
    fi
    _ready_line="$(/bin/cat "$_ready" 2>/dev/null || true)"
    if [[ ! "$_ready_line" =~ ^[0-9]+:[0-9]+$ ]]; then
      _mdm_abort_legacy_lock_holder "$_base" "$_control" "$_holder" "$_worker"
      return 1
    fi
    _worker="${_ready_line%%:*}"
    _reported_holder="${_ready_line#*:}"
    if [[ "$_reported_holder" != "$_holder" ]] \
      || [[ "$(_mdm_process_parent_pid "$_holder" || true)" != "$_owner_pid" ]] \
      || [[ "$(_mdm_process_parent_pid "$_worker" || true)" != "$_holder" ]]; then
      _mdm_abort_legacy_lock_holder "$_base" "$_control" "$_holder" "$_worker"
      return 1
    fi
    _MDM_RUN_LOCK_MODE="legacy"
    _MDM_RUN_LOCK_HOLDER_PID="$_holder"
    _MDM_RUN_LOCK_WORKER_PID="$_worker"
    _MDM_RUN_LOCK_CONTROL_DIR="$_control"
    _MDM_RUN_LOCK_LIFETIME_FIFO="$_lifetime"
  else
    exec 19>&-
    if [[ "$_lock_rc" -eq 75 ]]; then
      _MDM_RUN_LOCK_ERROR=contention
    else
      _MDM_RUN_LOCK_ERROR=backend
    fi
    return 1
  fi
  _MDM_RUN_LOCK_FILE="$_lock"
  _MDM_RUN_LOCK_BASE="$_base"
  _MDM_RUN_LOCK_ERROR=""
  _mdm_arm_transient_cleanup
  return 0
}

_mdm_release_run_lock() {
  local _lock="${_MDM_RUN_LOCK_FILE:-}" _base="${_MDM_RUN_LOCK_BASE:-}"
  local _mode="${_MDM_RUN_LOCK_MODE:-}" _control="${_MDM_RUN_LOCK_CONTROL_DIR:-}"
  local _holder="${_MDM_RUN_LOCK_HOLDER_PID:-}" _worker="${_MDM_RUN_LOCK_WORKER_PID:-}"
  local _lifetime="${_MDM_RUN_LOCK_LIFETIME_FIFO:-}" _wait_rc=0
  local _dir_identity="${_MDM_RUN_LOCK_DIR_IDENTITY:-}"
  [[ -n "$_lock" ]] || return 0
  [[ -n "$_base" ]] || return 1
  case "$_lock" in
    "$_base"/remediation-*.lock|"$_base"/remediation-global.mkdir-lock) : ;;
    *) return 1 ;;
  esac
  case "$_mode" in
    fd)
      [[ -f "$_lock" && ! -L "$_lock" ]] || return 1
      exec 19>&- || return 1 ;;
    legacy)
      [[ -f "$_lock" && ! -L "$_lock" ]] || return 1
      [[ "$_holder" =~ ^[0-9]+$ && "$_worker" =~ ^[0-9]+$ ]] || return 1
      [[ -n "$_control" ]] || return 1
      case "$_control" in "$_base"/.remediation-lock.*) : ;; *) return 1 ;; esac
      [[ -d "$_control" && ! -L "$_control" ]] || return 1
      _mdm_component_trusted "$_control" || return 1
      [[ "$_lifetime" == "$_control/lifetime" && -p "$_lifetime" && ! -L "$_lifetime" ]] \
        || return 1
      exec 18>&- || return 1
      _mdm_wait_lock_holder "$_holder" || _wait_rc=$?
      _mdm_lock_control_cleanup "$_base" "$_control" || return 1
      [[ "$_wait_rc" -eq 0 ]] || return 1 ;;
    mkdir)
      [[ "$_lock" == "$_base/remediation-global.mkdir-lock" \
        && "$_control" == "$_lock" && -n "$_dir_identity" ]] || return 1
      _mdm_mkdir_lock_cleanup "$_base" "$_control" "$_dir_identity" || return 1 ;;
    *) return 1 ;;
  esac
  _MDM_RUN_LOCK_FILE=""
  _MDM_RUN_LOCK_BASE=""
  _MDM_RUN_LOCK_MODE=""
  _MDM_RUN_LOCK_HOLDER_PID=""
  _MDM_RUN_LOCK_WORKER_PID=""
  _MDM_RUN_LOCK_CONTROL_DIR=""
  _MDM_RUN_LOCK_LIFETIME_FIFO=""
  _MDM_RUN_LOCK_DIR_IDENTITY=""
  _MDM_RUN_LOCK_ERROR=""
}
_mdm_cleanup_auth_entry_list() {
  local _path="${_MDM_AUTH_ENTRY_LIST:-}" _base _uid
  [[ -n "$_path" ]] || { _MDM_AUTH_ENTRY_LIST_OWNER_UID=""; return 0; }
  _base="$(_mdm_auth_tmp_base)"
  case "$_path" in "$_base"/claude-kit-mdm-list.*) : ;; *) return 1 ;; esac
  [[ -f "$_path" && ! -L "$_path" ]] || return 1
  _uid="$(_mdm_stat_uid "$_path" || true)"
  [[ -n "${_MDM_AUTH_ENTRY_LIST_OWNER_UID:-}" \
    && "$_uid" == "$_MDM_AUTH_ENTRY_LIST_OWNER_UID" ]] || return 1
  /bin/rm -f "$_path" || return 1
  _MDM_AUTH_ENTRY_LIST=""
  _MDM_AUTH_ENTRY_LIST_OWNER_UID=""
}

_mdm_cleanup_auth_checkout() {
  local _path="${_MDM_AUTH_CHECKOUT:-}" _base _uid
  [[ -n "$_path" ]] || return 0
  _base="$(_mdm_auth_tmp_base)"
  case "$_path" in "$_base"/claude-kit-mdm-auth.*) : ;; *) return 1 ;; esac
  [[ -d "$_path" && ! -L "$_path" ]] || return 1
  _uid="$(_mdm_stat_uid "$_path" || true)"
  [[ "$_uid" == "$(_mdm_auth_expected_uid)" ]] || return 1
  /usr/bin/find "$_path" -xdev -type d -exec /bin/chmod 700 '{}' + 2>/dev/null || true
  /bin/rm -rf "$_path" 2>/dev/null || return 1
  _MDM_AUTH_CHECKOUT=""
}

_mdm_cleanup_dryrun_checkout() {
  local _path="${_MDM_DRYRUN_CHECKOUT:-}"
  [[ -n "$_path" ]] || return 0
  _mdm_managed_tmp_path_matches "$_path" claude-kit-mdm-dryrun || {
    mdm_log R4 "dry-run 一時パスの形式が不正。削除しない: $_path"
    return 1
  }
  _mdm_run_maybe_as_user /bin/rm -rf "$_path" 2>/dev/null || return 1
  [[ ! -e "$_path" && ! -L "$_path" ]] || return 1
  _MDM_DRYRUN_CHECKOUT=""
}

_mdm_cleanup_persistent_stage() {
  local _path="${_MDM_PERSISTENT_STAGE:-}" _expected _name _current
  [[ -n "$_path" ]] || return 0
  _expected="${_MDM_PERSISTENT_STAGE_IDENTITY:-}"
  _name="${_path##*/}"
  case "$_name" in .claude-starter-kit.mdm-stage.*) : ;; *) return 1 ;; esac
  if [[ ! -e "$_path" && ! -L "$_path" ]]; then
    _MDM_PERSISTENT_STAGE=""
    _MDM_PERSISTENT_STAGE_IDENTITY=""
    return 0
  fi
  if [[ -z "$_expected" ]]; then
    [[ -d "$_path" && ! -L "$_path" ]] || return 1
    _mdm_run_maybe_as_user /bin/rmdir "$_path" 2>/dev/null || return 1
    _MDM_PERSISTENT_STAGE=""
    return 0
  fi
  [[ -d "$_path" && ! -L "$_path" ]] || return 1
  _current="$(_mdm_persistent_dir_identity "$_path" || true)"
  [[ "$_current" == "$_expected" ]] || return 1
  # The stage and its parent belong to the target user. Cleanup stays in the
  # same dropped-privilege context; the identity check rejects stale paths,
  # while the privilege drop keeps any remaining pathname race outside root's
  # authority boundary.
  _mdm_run_maybe_as_user /bin/rm -rf "$_path" 2>/dev/null || return 1
  [[ ! -e "$_path" && ! -L "$_path" ]] || return 1
  _MDM_PERSISTENT_STAGE=""
  _MDM_PERSISTENT_STAGE_IDENTITY=""
}

_mdm_cleanup_expected_dir() {
  local _path="${_MDM_EXPECTED_DIR:-}" _base _uid _expected_uid
  [[ -n "$_path" ]] || { _MDM_EXPECTED_OWNER_UID=""; return 0; }
  _base="$(_mdm_auth_tmp_base)"
  case "$_path" in "$_base"/claude-kit-mdm-expected.*) : ;; *) return 1 ;; esac
  [[ -d "$_path" && ! -L "$_path" ]] || return 1
  _uid="$(_mdm_stat_uid "$_path" || true)"
  _expected_uid="${_MDM_EXPECTED_OWNER_UID:-}"
  [[ "$_expected_uid" =~ ^[0-9]+$ && "$_uid" == "$_expected_uid" ]] || return 1
  /usr/bin/find "$_path" -xdev -type d -exec /bin/chmod 700 '{}' + 2>/dev/null || true
  /bin/rm -rf "$_path" 2>/dev/null || return 1
  _MDM_EXPECTED_DIR=""
  _MDM_EXPECTED_OUTPUT=""
  _MDM_EXPECTED_OWNER_UID=""
}

_mdm_cleanup_prior_inventory() {
  local _path="${_MDM_PRIOR_INVENTORY:-}" _uid
  [[ -n "$_path" ]] || return 0
  _mdm_managed_tmp_path_matches "$_path" claude-kit-mdm-prior || return 1
  [[ -f "$_path" && ! -L "$_path" ]] || return 1
  _uid="$(_mdm_stat_uid "$_path" || true)"
  [[ "$_uid" == "$(_mdm_auth_expected_uid)" ]] || return 1
  /bin/rm -f "$_path" || return 1
  _MDM_PRIOR_INVENTORY=""
}

_mdm_cleanup_renderer_snapshot() {
  local _path="${_MDM_EXPECTED_RENDERER:-}" _uid _expected_uid
  [[ "${_MDM_EXPECTED_RENDERER_SNAPSHOT:-0}" == 1 && -n "$_path" ]] \
    || { _MDM_EXPECTED_RENDERER_OWNER_UID=""; return 0; }
  _mdm_managed_tmp_path_matches "$_path" claude-kit-mdm-launcher || return 1
  [[ -f "$_path" && ! -L "$_path" ]] || return 1
  _uid="$(_mdm_stat_uid "$_path" || true)"
  _expected_uid="${_MDM_EXPECTED_RENDERER_OWNER_UID:-}"
  [[ -n "$_expected_uid" ]] || _expected_uid="$(_mdm_runtime_artifact_uid)"
  [[ "$_expected_uid" =~ ^[0-9]+$ && "$_uid" == "$_expected_uid" ]] || return 1
  /bin/rm -f "$_path" || return 1
  _MDM_EXPECTED_RENDERER=""
  _MDM_EXPECTED_RENDERER_SNAPSHOT=0
  _MDM_EXPECTED_RENDERER_OWNER_UID=""
}

_mdm_clear_system_python_runtime_state() {
  _MDM_SYSTEM_PYTHON_TARGET_PATH=""
  _MDM_SYSTEM_PYTHON_TARGET_FRAMEWORK_IDENTITY=""
  _MDM_SYSTEM_PYTHON_TARGET_IDENTITY=""
  _MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK=""
  _MDM_SYSTEM_PYTHON_PRIVATE_PATH=""
  _MDM_SYSTEM_PYTHON_PRIVATE_FRAMEWORK_IDENTITY=""
  _MDM_SYSTEM_PYTHON_PRIVATE_TARGET_IDENTITY=""
  _MDM_SYSTEM_PYTHON_PRIVATE_FULL_SEAL=""
}

_mdm_cleanup_system_python_workspace() {
  local _workspace="${_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE:-}"
  local _expected="${_MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE_IDENTITY:-}"
  local _base _actual _uid
  [[ -n "$_workspace" ]] || {
    _mdm_clear_system_python_runtime_state
    return 0
  }
  _base="$(_mdm_system_python_workspace_base)" || return 1
  case "$_workspace" in
    "$_base"/claude-kit-mdm-python.*) : ;;
    *) return 1 ;;
  esac
  [[ -n "$_expected" && -d "$_workspace" && ! -L "$_workspace" ]] || return 1
  _actual="$(_mdm_system_python_dir_identity "$_workspace")" || return 1
  [[ "$_actual" == "$_expected" ]] || return 1
  _uid="$(_mdm_stat_uid "$_workspace")" || return 1
  [[ "$_uid" == "$(_mdm_system_python_runtime_uid)" ]] || return 1
  _mdm_system_python_clear_workspace_flags "$_workspace" || return 1
  /bin/chmod 0700 "$_workspace" || return 1
  /usr/bin/find -P "$_workspace" -xdev -type d \
    -exec /bin/chmod 0700 '{}' + 2>/dev/null || return 1
  /bin/rm -rf "$_workspace" || return 1
  [[ ! -e "$_workspace" && ! -L "$_workspace" ]] || return 1
  _MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE=""
  _MDM_SYSTEM_PYTHON_PRIVATE_WORKSPACE_IDENTITY=""
  _mdm_clear_system_python_runtime_state
}

_mdm_stop_active_drop_supervisor() { # [HUP|INT|TERM]
  local _signal="${1:-TERM}" _pid="${_MDM_ACTIVE_DROP_SUPERVISOR_PID:-}"
  local _candidate="" _nounset_was_on=false
  case "$_signal" in HUP|INT|TERM) : ;; *) return 1 ;; esac
  if [[ ! "$_pid" =~ ^[1-9][0-9]*$ \
    && "${_MDM_DROP_SUPERVISOR_STARTING:-0}" == 1 ]]; then
    case $- in *u*) _nounset_was_on=true ;; esac
    set +u
    _candidate="$!"
    [[ "$_nounset_was_on" == true ]] && set -u
    if [[ "$_candidate" =~ ^[1-9][0-9]*$ \
      && "$_candidate" != "${_MDM_DROP_SUPERVISOR_PREVIOUS_BG:-}" ]]; then
      _pid="$_candidate"
    fi
  fi
  [[ "$_pid" =~ ^[1-9][0-9]*$ ]] || {
    _MDM_DROP_SUPERVISOR_STARTING=0
    return 0
  }
  /bin/kill "-$_signal" "$_pid" 2>/dev/null || true
  # The supervisor itself bounds TERM->KILL for its user child to three
  # seconds, shorter than this five-second watchdog.
  _mdm_wait_lock_holder "$_pid" >/dev/null 2>&1 || true
  _MDM_ACTIVE_DROP_SUPERVISOR_PID=""
  _MDM_DROP_SUPERVISOR_STARTING=0
  return 0
}

_mdm_stop_active_timeout_supervisor() { # [HUP|INT|TERM]
  local _signal="${1:-TERM}" _pid="${_MDM_ACTIVE_TIMEOUT_SUPERVISOR_PID:-}"
  local _candidate="" _nounset_was_on=false
  case "$_signal" in HUP|INT|TERM) : ;; *) return 1 ;; esac
  if [[ ! "$_pid" =~ ^[1-9][0-9]*$ \
    && "${_MDM_TIMEOUT_SUPERVISOR_STARTING:-0}" == 1 ]]; then
    case $- in *u*) _nounset_was_on=true ;; esac
    set +u
    _candidate="$!"
    [[ "$_nounset_was_on" == true ]] && set -u
    if [[ "$_candidate" =~ ^[1-9][0-9]*$ \
      && "$_candidate" != "${_MDM_TIMEOUT_SUPERVISOR_PREVIOUS_BG:-}" ]]; then
      _pid="$_candidate"
    fi
  fi
  [[ "$_pid" =~ ^[1-9][0-9]*$ ]] || return 0
  /bin/kill "-$_signal" "$_pid" 2>/dev/null || true
  wait "$_pid" 2>/dev/null || true
  _MDM_ACTIVE_TIMEOUT_SUPERVISOR_PID=""
  _MDM_TIMEOUT_SUPERVISOR_STARTING=0
}

_mdm_stop_active_bound_snapshot() { # [HUP|INT|TERM]
  local _signal="${1:-TERM}"
  local _pid="${_MDM_ACTIVE_BOUND_SNAPSHOT_SUPERVISOR_PID:-}"
  local _path="${_MDM_ACTIVE_BOUND_SNAPSHOT_PATH:-}" _candidate="" _base
  local _nounset_was_on=false
  case "$_signal" in HUP|INT|TERM) : ;; *) return 1 ;; esac
  if [[ ! "$_pid" =~ ^[1-9][0-9]*$ \
    && "${_MDM_BOUND_SNAPSHOT_SUPERVISOR_STARTING:-0}" == 1 ]]; then
    case $- in *u*) _nounset_was_on=true ;; esac
    set +u
    _candidate="$!"
    [[ "$_nounset_was_on" == true ]] && set -u
    if [[ "$_candidate" =~ ^[1-9][0-9]*$ \
      && "$_candidate" \
        != "${_MDM_BOUND_SNAPSHOT_SUPERVISOR_PREVIOUS_BG:-}" ]]; then
      _pid="$_candidate"
    fi
  fi
  if [[ "$_pid" =~ ^[1-9][0-9]*$ ]]; then
    /bin/kill "-$_signal" "$_pid" 2>/dev/null || true
    _mdm_wait_lock_holder "$_pid" >/dev/null 2>&1 || true
  fi
  _MDM_ACTIVE_BOUND_SNAPSHOT_SUPERVISOR_PID=""
  _MDM_BOUND_SNAPSHOT_SUPERVISOR_STARTING=0
  if [[ -n "$_path" ]]; then
    _base="$(_mdm_safe_tmpdir)" || return 1
    case "$_path" in "$_base"/claude-kit-mdm-*) : ;; *) return 1 ;; esac
    if [[ -e "$_path" || -L "$_path" ]]; then
      [[ -f "$_path" && ! -L "$_path" ]] || return 1
      /bin/rm -f "$_path" || return 1
    fi
  fi
  _MDM_ACTIVE_BOUND_SNAPSHOT_PATH=""
}

_mdm_cleanup_transient_checkouts() {
  local _timeout_signal="${1:-TERM}"
  # Cleanup is a single critical section.  Disarm EXIT and ignore every
  # catchable signal used by the launcher before the first cleanup action, so
  # a second signal cannot interrupt later stage/lock release.  The original
  # INT/TERM handler retains responsibility for the final 130/143 exit.
  trap - EXIT
  trap '' HUP INT TERM
  _mdm_launcher_cleanup_snapshots || true
  _mdm_cleanup_expected_inflight || true
  _mdm_stop_active_timeout_supervisor "$_timeout_signal" || true
  _mdm_stop_active_drop_supervisor "$_timeout_signal" || true
  _mdm_stop_active_bound_snapshot "$_timeout_signal" || true
  _mdm_receipt_discard_prepared || true
  case "${_MDM_TRANSACTION_STATE:-idle}" in
    committing|commit_cleanup) _mdm_transaction_commit || true ;;
    *) _mdm_transaction_abort || true ;;
  esac
  _mdm_external_inventory_discard || true
  _mdm_managed_parent_check_discard || true
  _mdm_cleanup_prereq_artifacts || true
  _mdm_cleanup_auth_entry_list || true
  _mdm_cleanup_dryrun_checkout || true
  if [[ "${_MDM_TRANSACTION_STATE:-idle}" != partial \
    && "${_MDM_TRANSACTION_STATE:-idle}" != committing \
    && "${_MDM_TRANSACTION_STATE:-idle}" != commit_cleanup ]]; then
    _mdm_cleanup_persistent_stage || true
  fi
  _mdm_cleanup_auth_checkout || true
  _mdm_cleanup_expected_dir || true
  _mdm_cleanup_prior_inventory || true
  _mdm_cleanup_renderer_snapshot || true
  _mdm_cleanup_system_python_workspace || true
  _mdm_clear_failure_rollback_runtime
  _mdm_release_run_lock || true
}

_mdm_arm_transient_signal_cleanup() {
  trap '_mdm_cleanup_transient_checkouts HUP; exit 129' HUP
  trap '_mdm_cleanup_transient_checkouts INT; exit 130' INT
  trap '_mdm_cleanup_transient_checkouts TERM; exit 143' TERM
}

_mdm_arm_transient_cleanup() {
  trap '_mdm_cleanup_transient_checkouts' EXIT
  _mdm_arm_transient_signal_cleanup
}

_mdm_prepare_authoritative_checkout() { # <ref> <target-uid>
  local _ref="$1" _target_uid="$2" _base _repo_url _auth _sha _head _status _privacy_uid
  _mdm_boot_validate_gitref "$_ref" >/dev/null 2>&1 || return "$MDM_EXIT_CONFIG"
  _base="$(_mdm_auth_tmp_base)"
  _mdm_auth_base_trusted "$_base" || {
    mdm_log U1b "authoritative checkout の一時領域が信頼できない"
    return 1
  }
  _auth="$(/usr/bin/mktemp -d "$_base/claude-kit-mdm-auth.XXXXXX" 2>/dev/null)" || return 1
  case "$_auth" in "$_base"/claude-kit-mdm-auth.*) : ;; *) return 1 ;; esac
  [[ -d "$_auth" && ! -L "$_auth" ]] || return 1
  [[ "$(_mdm_stat_uid "$_auth" || true)" == "$(_mdm_auth_expected_uid)" ]] || return 1
  /bin/chmod 700 "$_auth" || return 1
  _MDM_AUTH_CHECKOUT="$_auth"
  _mdm_arm_transient_cleanup

  _repo_url="$(_mdm_repo_url)"
  mdm_log U1b "root authoritative checkout を作成"
  _mdm_auth_git_network clone --quiet --no-checkout --no-local \
    "$_repo_url" "$_auth" 2>/dev/null || return 1
  _mdm_auth_git_network -C "$_auth" fetch --quiet \
    "$_repo_url" "$_ref" 2>/dev/null || return 1
  _sha="$(_mdm_auth_git -C "$_auth" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null || true)"
  [[ "$_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  _mdm_auth_git -C "$_auth" checkout --quiet --force --detach "$_sha" 2>/dev/null || return 1
  _head="$(_mdm_auth_git -C "$_auth" rev-parse --verify HEAD 2>/dev/null || true)"
  [[ "$_head" == "$_sha" ]] || return 1
  _status="$(_mdm_auth_git -C "$_auth" status --porcelain --untracked-files=all 2>/dev/null)" \
    || return 1
  [[ -z "$_status" ]] || return 1

  MDM_RCPT_RESOLVED_SHA="$_sha"
  MDM_RCPT_KIT_VERSION="$(_mdm_describe_kit_version _mdm_auth_git "$_auth")"
  _mdm_normalize_auth_tree "$_auth" || return 1
  _privacy_uid="$_target_uid"
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && -n "${MDM_AUTH_PRIVACY_UID_OVERRIDE:-}" ]]; then
    _privacy_uid="$MDM_AUTH_PRIVACY_UID_OVERRIDE"
  fi
  _mdm_auth_tree_private_for_uid "$_auth" "$_privacy_uid" || {
    mdm_log U1b "authoritative checkout が対象ユーザーから書込可能"
    return 1
  }
}

_mdm_root_ref_allowed() { # <ref> <dry-run>
  local _ref="$1" _dry_run="$2"
  _mdm_boot_validate_gitref "$_ref" >/dev/null 2>&1 || return 1
  case "$_dry_run" in true|false) : ;; *) return 1 ;; esac
  if [[ "${_MDM_TEST_MODE:-0}" != "1" ]]; then
    [[ "$_ref" =~ ^[0-9a-f]{40}$ ]]
  fi
}

# Validate every production-only semantic before lock/log/prerequisite paths
# can mutate host state.  The target home/UID are already bound by R2, so the
# dedicated checkout constraint and existing marker can be checked here.
_mdm_validate_semantic_config() { # <euid> <home> <target-uid> <dry-run>
  local _euid="$1" _home="$2" _target_uid="$3" _dry_run="$4"
  local _ref="${KIT_MDM_GIT_REF:-main}" _install_dir="$_home/.claude-starter-kit"
  _mdm_root_ref_allowed "$_ref" "$_dry_run" || return "$MDM_EXIT_CONFIG"
  _mdm_expected_policy_input_valid || return "$MDM_EXIT_CONFIG"
  _mdm_log_dir_for "$_euid" "$_home" >/dev/null || return "$MDM_EXIT_CONFIG"
  [[ "$_dry_run" == true ]] && return 0
  if [[ -n "${KIT_MDM_INSTALL_DIR:-}" && "$KIT_MDM_INSTALL_DIR" != "$_install_dir" ]]; then
    return "$MDM_EXIT_CONFIG"
  fi
  if [[ -L "$_install_dir" || ( -e "$_install_dir" && ! -d "$_install_dir" ) ]]; then
    return "$MDM_EXIT_CONFIG"
  fi
  if [[ -d "$_install_dir" ]]; then
    [[ "$(_mdm_canonical_dir "$_install_dir")" == "$_install_dir" ]] || return "$MDM_EXIT_CONFIG"
    _mdm_persistent_marker_trusted "$_install_dir" "$_target_uid" \
      || return "$MDM_EXIT_CONFIG"
  fi
}

_mdm_persistent_marker_path() {
  printf '%s/.claude-starter-kit-mdm-managed' "$1"
}

_mdm_persistent_dir_identity() {
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%d:%i:%HT' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%d:%i:%F' "$1" 2>/dev/null
  fi
}

_mdm_persistent_marker_trusted() { # <install-dir> <target-uid>
  local _marker _expected_uid="$2" _copy="" _mode="" _size=""
  local _value _extra="" _rc=1
  [[ "$_expected_uid" =~ ^[0-9]+$ ]] || return 1
  _marker="$(_mdm_persistent_marker_path "$1")"
  _mdm_stable_managed_snapshot "$_marker" persistent-marker "$_expected_uid" \
    _copy _mode || return 1
  [[ "$_mode" == 0444 ]] || { /bin/rm -f "$_copy"; return 1; }
  _size="$(/usr/bin/wc -c < "$_copy" | /usr/bin/tr -d '[:space:]')" \
    || { /bin/rm -f "$_copy"; return 1; }
  [[ "$_size" == 36 ]] || { /bin/rm -f "$_copy"; return 1; }
  exec 6<"$_copy" || { /bin/rm -f "$_copy"; return 1; }
  if IFS= read -r _value <&6 \
    && ! IFS= read -r _extra <&6 \
    && [[ -z "$_extra" ]] \
    && [[ "$_value" == claude-code-starter-kit-mdm-user-v1 ]]; then
    _rc=0
  fi
  exec 6<&-
  /bin/rm -f "$_copy"
  return "$_rc"
}

_mdm_persistent_checkout_matches_identity() { # <dir> <target-uid> <dev:inode:type>
  local _dir="$1" _target_uid="$2" _expected="$3" _before _after _mode
  [[ "$_target_uid" =~ ^[0-9]+$ && -n "$_expected" ]] || return 1
  [[ -d "$_dir" && ! -L "$_dir" ]] || return 1
  [[ "$(_mdm_canonical_dir "$_dir" || true)" == "$_dir" ]] || return 1
  [[ "$(_mdm_stat_uid "$_dir" || true)" == "$_target_uid" ]] || return 1
  _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_dir" || true)" || true)"
  _mdm_mode_is_safe "$_mode" || return 1
  _mdm_has_extended_acl "$_dir" && return 1
  _before="$(_mdm_persistent_dir_identity "$_dir" || true)"
  [[ "$_before" == "$_expected" ]] || return 1
  case "$_before" in *:Directory|*:directory) : ;; *) return 1 ;; esac
  _mdm_managed_dir_matches_identity "$_dir/.git" "$_target_uid" || return 1
  _mdm_persistent_marker_trusted "$_dir" "$_target_uid" || return 1
  _after="$(_mdm_persistent_dir_identity "$_dir" || true)"
  [[ "$_after" == "$_expected" ]]
}

_mdm_create_persistent_marker() { # <install-dir> <target-uid>
  local _marker _target_uid="$2"
  [[ "$_target_uid" =~ ^[0-9]+$ ]] || return 1
  _marker="$(_mdm_persistent_marker_path "$1")"
  [[ ! -e "$_marker" && ! -L "$_marker" ]] || return 1
  # The checkout parent is target-user writable. Never let root open a marker
  # path below it: a concurrent directory-to-symlink swap would redirect the
  # privileged write. Creation and chmod stay in the already-clean user
  # context; root only consumes a bounded, inode-bound snapshot afterwards.
  _mdm_run_maybe_as_user /bin/sh -c '
    set -eu
    umask 022
    set -C
    printf "%s\n" claude-code-starter-kit-mdm-user-v1 > "$1"
    /bin/chmod 444 "$1"
  ' mdm-persistent-marker "$_marker" 2>/dev/null || return 1
  _mdm_persistent_marker_trusted "$1" "$_target_uid"
}

_mdm_atomic_user_dir_operation() {
  # <parent> <source-name> <destination-name> <create|swap> <uid>
  # <parent-identity> <source-identity> <destination-identity|absent>
  local _parent="$1" _source="$2" _destination="$3" _operation="$4"
  local _target_uid="$5" _parent_identity="$6" _source_identity="$7"
  local _destination_identity="$8" _python _outcome
  [[ "$_parent" == /* && ! "$_parent" =~ [[:cntrl:]] \
    && "$_source" != */* && "$_destination" != */* \
    && -n "$_source" && -n "$_destination" \
    && "$_source" != . && "$_source" != .. \
    && "$_destination" != . && "$_destination" != .. \
    && "$_source" != "$_destination" \
    && "$_target_uid" =~ ^[0-9]+$ ]] || return 1
  case "$_operation" in
    create) [[ "$_destination_identity" == absent ]] || return 1 ;;
    swap) [[ "$_destination_identity" != absent ]] || return 1 ;;
    *) return 1 ;;
  esac
  _python="$(_mdm_target_system_python)" || return 1
  # The user-owned parent is opened once with O_NOFOLLOW.  Both preflight and
  # postcondition use fstatat-style dir_fd lookups around a single atomic
  # rename operation, so a pathname replacement cannot inherit stale delete
  # authority from an earlier shell check.
  if _mdm_run_maybe_as_user "$_python" -I -B -S -c '
import ctypes
import os
import stat
import sys

(parent, source, destination, operation, uid_raw, parent_expected,
 source_expected, destination_expected) = sys.argv[1:]
uid = int(uid_raw)
for name in (source, destination):
    if not name or name in (".", "..") or "/" in name or "\x00" in name:
        raise SystemExit(1)

flags = (os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
         | getattr(os, "O_CLOEXEC", 0))
parent_fd = os.open(parent, flags)

def expected_tuple(value):
    pieces = value.split(":", 2)
    if len(pieces) != 3:
        raise ValueError("invalid identity")
    return int(pieces[0]), int(pieces[1])

def checked(name, expected):
    value = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if (not stat.S_ISDIR(value.st_mode) or value.st_uid != uid
            or (value.st_dev, value.st_ino) != expected_tuple(expected)):
        raise ValueError("directory identity changed")
    return value

def missing(name):
    try:
        os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return True
    return False

try:
    parent_value = os.fstat(parent_fd)
    if (not stat.S_ISDIR(parent_value.st_mode) or parent_value.st_uid != uid
            or (parent_value.st_dev, parent_value.st_ino)
                != expected_tuple(parent_expected)):
        raise ValueError("parent identity changed")
    checked(source, source_expected)
    if operation == "create":
        if not missing(destination):
            raise ValueError("destination appeared")
    else:
        checked(destination, destination_expected)

    libc = ctypes.CDLL(None, use_errno=True)
    source_b = os.fsencode(source)
    destination_b = os.fsencode(destination)
    if sys.platform == "darwin":
        rename = libc.renameatx_np
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p,
                           ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        rename_flags = 4 if operation == "create" else 2
    elif sys.platform.startswith("linux"):
        rename = libc.renameat2
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p,
                           ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        rename_flags = 1 if operation == "create" else 2
    else:
        raise ValueError("unsupported platform")
    if rename(parent_fd, source_b, parent_fd, destination_b,
              rename_flags) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))

    if operation == "create":
        if not missing(source):
            raise ValueError("source still present")
        checked(destination, source_expected)
    else:
        checked(source, destination_expected)
        checked(destination, source_expected)
    after = os.fstat(parent_fd)
    if ((after.st_dev, after.st_ino)
            != (parent_value.st_dev, parent_value.st_ino)):
        raise ValueError("parent changed")
    os.fsync(parent_fd)
finally:
    os.close(parent_fd)
' "$_parent" "$_source" "$_destination" "$_operation" "$_target_uid" \
    "$_parent_identity" "$_source_identity" "$_destination_identity" \
    >/dev/null 2>&1; then
    return 0
  fi
  # renameatx_np/renameat2 may have completed the exchange before a later
  # postcondition or directory fsync failed.  Never assume that a non-zero
  # helper status means the namespace is unchanged: classify the two recorded
  # inode layouts and accept only the proven published layout.
  _outcome="$(_mdm_user_dir_operation_outcome \
    "$_parent" "$_source" "$_destination" "$_operation" "$_target_uid" \
    "$_parent_identity" "$_source_identity" "$_destination_identity" \
    2>/dev/null || true)"
  [[ "$_outcome" == published ]]
}

_mdm_user_dir_operation_outcome() {
  # <parent> <source-name> <destination-name> <create|swap> <uid>
  # <parent-id> <source-id> <destination-id|absent>
  local _parent="$1" _source="$2" _destination="$3" _operation="$4"
  local _uid="$5" _parent_identity="$6" _source_identity="$7"
  local _destination_identity="$8" _source_path _destination_path
  local _source_current=absent _destination_current=absent
  [[ "$(_mdm_persistent_dir_identity "$_parent" 2>/dev/null || true)" \
      == "$_parent_identity" \
    && "$(_mdm_stat_uid "$_parent" 2>/dev/null || true)" == "$_uid" ]] \
    || { printf '%s' unknown; return 1; }
  _source_path="$_parent/$_source"; _destination_path="$_parent/$_destination"
  if [[ -d "$_source_path" && ! -L "$_source_path" ]]; then
    _source_current="$(_mdm_persistent_dir_identity "$_source_path")" \
      || { printf '%s' unknown; return 1; }
  elif [[ -e "$_source_path" || -L "$_source_path" ]]; then
    printf '%s' unknown; return 1
  fi
  if [[ -d "$_destination_path" && ! -L "$_destination_path" ]]; then
    _destination_current="$(_mdm_persistent_dir_identity \
      "$_destination_path")" || { printf '%s' unknown; return 1; }
  elif [[ -e "$_destination_path" || -L "$_destination_path" ]]; then
    printf '%s' unknown; return 1
  fi
  case "$_operation:$_source_current:$_destination_current" in
    "create:$_source_identity:absent"|\
    "swap:$_source_identity:$_destination_identity")
      printf '%s' unchanged ;;
    "create:absent:$_source_identity"|\
    "swap:$_destination_identity:$_source_identity")
      printf '%s' published ;;
    *) printf '%s' unknown; return 1 ;;
  esac
}

_mdm_promote_persistent_stage() {
  # <stage> <install-dir> <create|swap> [source-id] [destination-id|absent]
  # [target-uid] [parent-id]
  local _stage="$1" _install_dir="$2" _operation="$3"
  local _source_identity="${4:-}" _destination_identity="${5:-}"
  local _target_uid="${6:-}" _parent_identity="${7:-}"
  local _parent _source_name _destination_name
  _parent="${_stage%/*}"
  [[ "$_parent" == "${_install_dir%/*}" ]] || return 1
  _source_name="${_stage##*/}"; _destination_name="${_install_dir##*/}"
  [[ -n "$_source_identity" ]] \
    || _source_identity="$(_mdm_persistent_dir_identity "$_stage")" || return 1
  if [[ -z "$_destination_identity" ]]; then
    if [[ "$_operation" == create ]]; then
      _destination_identity=absent
    else
      _destination_identity="$(_mdm_persistent_dir_identity "$_install_dir")" \
        || return 1
    fi
  fi
  [[ -n "$_target_uid" ]] \
    || _target_uid="$(_mdm_stat_uid "$_stage")" || return 1
  [[ -n "$_parent_identity" ]] \
    || _parent_identity="$(_mdm_persistent_dir_identity "$_parent")" || return 1
  _mdm_atomic_user_dir_operation "$_parent" "$_source_name" \
    "$_destination_name" "$_operation" "$_target_uid" \
    "$_parent_identity" "$_source_identity" "$_destination_identity"
}

_mdm_restore_previous_persistent_checkout() { # <stage> <install> <uid> <candidate-id> <previous-id>
  local _stage="$1" _install_dir="$2" _target_uid="$3"
  local _candidate_identity="$4" _previous_identity="$5" _stage_identity
  if ! _mdm_promote_persistent_stage "$_stage" "$_install_dir" swap; then
    # A failed exchange leaves the previous checkout at the stage pathname.
    # Disarm cleanup so that known prior state is preserved for recovery.
    _MDM_PERSISTENT_STAGE=""
    _MDM_PERSISTENT_STAGE_IDENTITY=""
    mdm_log U1b "保持用 checkout の rollback に失敗。旧 checkout を recovery stage に保持"
    return 1
  fi
  _stage_identity="$(_mdm_persistent_dir_identity "$_stage" || true)"
  if [[ "$_stage_identity" != "$_candidate_identity" ]] \
    || ! _mdm_persistent_checkout_matches_identity \
      "$_install_dir" "$_target_uid" "$_previous_identity"; then
    # The exchange happened, but a concurrent pathname replacement means we
    # cannot prove which tree is disposable. Preserve both rather than rm -rf.
    _MDM_PERSISTENT_STAGE=""
    _MDM_PERSISTENT_STAGE_IDENTITY=""
    mdm_log U1b "rollback 後の checkout identity を証明できないため両方を保持"
    return 1
  fi
  _MDM_PERSISTENT_STAGE_IDENTITY="$_candidate_identity"
  _mdm_cleanup_persistent_stage
}

_mdm_retract_initial_persistent_checkout() { # <stage-path> <install-dir> <candidate-id>
  local _stage="$1" _install_dir="$2" _candidate_identity="$3" _current
  # Move the promoted object back to its now-absent stage name before deleting
  # it. A raced replacement is preserved when its identity is not the candidate.
  if ! _mdm_promote_persistent_stage "$_install_dir" "$_stage" create; then
    _MDM_PERSISTENT_STAGE=""
    _MDM_PERSISTENT_STAGE_IDENTITY=""
    return 1
  fi
  _current="$(_mdm_persistent_dir_identity "$_stage" || true)"
  if [[ "$_current" != "$_candidate_identity" ]]; then
    # The active pathname was replaced after promotion. Put that unrelated
    # directory back at the fixed path when it is still absent; otherwise keep
    # the recovery stage untouched. Neither branch authorizes deletion.
    _mdm_promote_persistent_stage "$_stage" "$_install_dir" create || true
    _MDM_PERSISTENT_STAGE=""
    _MDM_PERSISTENT_STAGE_IDENTITY=""
    return 1
  fi
  _MDM_PERSISTENT_STAGE_IDENTITY="$_candidate_identity"
  _mdm_cleanup_persistent_stage
}

_mdm_claude_transaction_marker_path() {
  printf '%s/.claude-starter-kit-mdm-transaction' "$1"
}

_mdm_claude_transaction_marker_trusted() { # <claude-dir> <uid> <value>
  local _dir="$1" _uid="$2" _expected="$3" _copy="" _mode=""
  local _size _value="" _extra="" _rc=1
  [[ "$_uid" =~ ^[0-9]+$ && -n "$_expected" \
    && ! "$_expected" =~ [[:cntrl:]] ]] || return 1
  _mdm_stable_managed_snapshot \
    "$(_mdm_claude_transaction_marker_path "$_dir")" \
    claude-transaction-marker "$_uid" _copy _mode || return 1
  _size="$(/usr/bin/wc -c < "$_copy" | /usr/bin/tr -d '[:space:]')" \
    || { /bin/rm -f "$_copy"; return 1; }
  if [[ "$_mode" == 0444 && "$_size" -eq $((${#_expected} + 1)) ]]; then
    exec 6<"$_copy" || { /bin/rm -f "$_copy"; return 1; }
    if IFS= read -r _value <&6 \
      && ! IFS= read -r _extra <&6 \
      && [[ -z "$_extra" && "$_value" == "$_expected" ]]; then
      _rc=0
    fi
    exec 6<&-
  fi
  /bin/rm -f "$_copy"
  return "$_rc"
}

_mdm_claude_backup_marker_trusted() { # <claude-dir> <uid> <backup-path>
  local _dir="$1" _uid="$2" _expected="$3" _copy="" _mode=""
  local _size _value="" _extra="" _rc=1
  [[ "$_uid" =~ ^[0-9]+$ && "$_expected" == /* \
    && ! "$_expected" =~ [[:cntrl:]] ]] || return 1
  _mdm_stable_managed_snapshot "$_dir/.starter-kit-last-backup" \
    claude-backup-marker "$_uid" _copy _mode || return 1
  _size="$(/usr/bin/wc -c < "$_copy" | /usr/bin/tr -d '[:space:]')" \
    || { /bin/rm -f "$_copy"; return 1; }
  if _mdm_mode_is_safe "$_mode" \
    && [[ "$_size" -eq $((${#_expected} + 1)) ]]; then
    exec 6<"$_copy" || { /bin/rm -f "$_copy"; return 1; }
    if IFS= read -r _value <&6 \
      && ! IFS= read -r _extra <&6 \
      && [[ -z "$_extra" && "$_value" == "$_expected" ]]; then
      _rc=0
    fi
    exec 6<&-
  fi
  /bin/rm -f "$_copy"
  return "$_rc"
}

_mdm_create_claude_transaction_marker() { # <claude-dir> <uid> <value>
  local _dir="$1" _uid="$2" _value="$3" _marker
  [[ "$_uid" =~ ^[0-9]+$ && -n "$_value" \
    && ! "$_value" =~ [[:cntrl:]] ]] || return 1
  _marker="$(_mdm_claude_transaction_marker_path "$_dir")"
  # The candidate is target-user-owned. Remove only its copied transaction
  # marker, then create the current marker under the same dropped authority.
  _mdm_run_maybe_as_user /bin/rm -f "$_marker" 2>/dev/null || return 1
  _mdm_run_maybe_as_user /bin/sh -c '
    set -eu
    umask 022
    set -C
    printf "%s\n" "$2" > "$1"
    /bin/chmod 444 "$1"
  ' mdm-claude-transaction-marker "$_marker" "$_value" \
    2>/dev/null || return 1
  _mdm_claude_transaction_marker_trusted "$_dir" "$_uid" "$_value"
}

_mdm_transaction_failed_path() { # <source-path> <stage-token> <failed-token>
  local _source="$1" _stage_token="$2" _failed_token="$3"
  local _name="${_source##*/}" _parent="${_source%/*}"
  case "$_name" in
    *"$_stage_token"*)
      printf '%s/%s%s%s' "$_parent" "${_name%%"$_stage_token"*}" \
        "$_failed_token" "${_name#*"$_stage_token"}" ;;
    *) return 1 ;;
  esac
}

_mdm_transaction_preserve_failed_dir() {
  # <source> <failed-base> <uid> <parent-id> <source-id> <output-var>
  local _source="$1" _base="$2" _uid="$3" _parent_identity="$4"
  local _source_identity="$5" _out_var="$6" _parent _candidate _current
  local _collision=0
  [[ "$_out_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  _parent="${_source%/*}"
  [[ "$_parent" == "${_base%/*}" ]] || return 1
  _candidate="$_base"
  while [[ "$_collision" -le 100 ]]; do
    if [[ -e "$_candidate" || -L "$_candidate" ]]; then
      _collision=$((_collision + 1))
      _candidate="$_base.$_collision"
      continue
    fi
    if _mdm_atomic_user_dir_operation "$_parent" "${_source##*/}" \
        "${_candidate##*/}" create "$_uid" "$_parent_identity" \
        "$_source_identity" absent; then
      printf -v "$_out_var" '%s' "$_candidate"
      return 0
    fi
    _current="$(_mdm_persistent_dir_identity "$_source" 2>/dev/null || true)"
    [[ "$_current" == "$_source_identity" ]] || return 1
    _collision=$((_collision + 1))
    _candidate="$_base.$_collision"
  done
  return 1
}

_mdm_transaction_allocate_claude_candidate() { # <home> <uid>
  local _home="$1" _uid="$2" _timestamp _candidate
  [[ "$_uid" =~ ^[0-9]+$ ]] || return 1
  _timestamp="$(LC_ALL=C date +%Y%m%d%H%M%S 2>/dev/null)" || return 1
  [[ "$_timestamp" =~ ^[0-9]{14}$ ]] || return 1
  _candidate="$(_mdm_run_maybe_as_user /bin/sh -c '
    set -eu
    umask 077
    base="$1/.claude.mdm-backup.$2"
    candidate="$base"
    collision=0
    while [ "$collision" -le 100 ]; do
      if /bin/mkdir -m 700 "$candidate" 2>/dev/null; then
        printf "%s\n" "$candidate"
        exit 0
      fi
      [ -e "$candidate" ] || [ -L "$candidate" ] || exit 1
      collision=$((collision + 1))
      candidate="$base.$collision"
    done
    exit 1
  ' mdm-claude-candidate "$_home" "$_timestamp" 2>/dev/null)" || return 1
  case "$_candidate" in
    "$_home"/.claude.mdm-backup."$_timestamp"|\
    "$_home"/.claude.mdm-backup."$_timestamp".[0-9]*) : ;;
    *) return 1 ;;
  esac
  printf '%s' "$_candidate"
}

_mdm_transaction_rotate_claude_backups() { # <home> <current-backup>
  local _home="$1" _current="$2"
  [[ "$_current" == "$_home"/.claude.mdm-backup.* \
    && -d "$_current" && ! -L "$_current" ]] || return 1
  _mdm_run_maybe_as_user /bin/sh -c '
    set -eu
    home="$1"
    current="$2"
    for candidate in "$home"/.claude.mdm-backup.*; do
      [ -e "$candidate" ] || [ -L "$candidate" ] || continue
      [ "$candidate" = "$current" ] && continue
      suffix=${candidate#"$home"/.claude.mdm-backup.}
      printf "%s\n" "$suffix" \
        | /usr/bin/grep -Eq "^[0-9]{14}(\.[0-9]+)?$" || continue
      /bin/rm -rf "$candidate" || exit 1
    done
  ' mdm-rotate-claude-backups "$_home" "$_current"
}

_mdm_transaction_snapshot_root_file() {
  # <path> <history|manifest> <state-var> <snapshot-var>
  local _path="$1" _label="$2" _state_var="$3" _snapshot_var="$4"
  local _snapshot="" _mode="" _old_umask
  if [[ ! -e "$_path" && ! -L "$_path" ]]; then
    printf -v "$_state_var" '%s' absent
    printf -v "$_snapshot_var" '%s' ''
    return 0
  fi
  [[ -f "$_path" && ! -L "$_path" ]] || return 1
  _mdm_component_trusted "$_path" || return 1
  _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_path")")" || return 1
  [[ "$_mode" == 0600 ]] || return 1
  # Publish cleanup ownership in the same signal-masked allocation section.
  # The potentially longer bounded copy runs with the normal signal handler;
  # `capturing` means the live root file is still untouched and only the temp
  # snapshot may be discarded by abort.
  trap '' HUP INT TERM
  _old_umask="$(umask)"; umask 077
  _snapshot="$(/usr/bin/mktemp \
    "$(_mdm_safe_tmpdir)/claude-kit-mdm-${_label}.XXXXXX")" || {
    umask "$_old_umask"
    _mdm_arm_transient_cleanup
    return 1
  }
  umask "$_old_umask"
  printf -v "$_state_var" '%s' capturing
  printf -v "$_snapshot_var" '%s' "$_snapshot"
  _mdm_arm_transient_cleanup
  if ! _mdm_snapshot_bound_to "$_path" "$_snapshot" "$_label"; then
    /bin/rm -f "$_snapshot"
    printf -v "$_state_var" '%s' untouched
    printf -v "$_snapshot_var" '%s' ''
    return 1
  fi
  printf -v "$_state_var" '%s' present
}

_mdm_transaction_restore_root_file() {
  # <path> <present|absent> <snapshot>
  local _path="$1" _state="$2" _snapshot="$3" _dir _tmp="" _mode
  _dir="${_path%/*}"
  _mdm_component_receipt_dir_is_trusted "$_dir" || return 1
  case "$_state" in
    untouched|capturing) : ;;
    present)
      [[ -f "$_snapshot" && ! -L "$_snapshot" ]] || return 1
      if [[ -f "$_path" && ! -L "$_path" ]] \
        && _mdm_component_trusted "$_path" \
        && [[ "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_path")")" \
          == 0600 ]] \
        && /usr/bin/cmp -s "$_snapshot" "$_path"; then
        return 0
      fi
      _tmp="$(/usr/bin/mktemp "$_dir/.transaction-restore.XXXXXX")" \
        || return 1
      /bin/cp -p "$_snapshot" "$_tmp" \
        && /bin/chmod 600 "$_tmp" \
        || { /bin/rm -f "$_tmp"; return 1; }
      [[ -f "$_tmp" && ! -L "$_tmp" ]] \
        || { /bin/rm -f "$_tmp"; return 1; }
      _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_tmp")")" || {
        /bin/rm -f "$_tmp"; return 1;
      }
      [[ "$_mode" == 0600 ]] \
        && ! _mdm_has_extended_acl "$_tmp" \
        && /bin/mv -f "$_tmp" "$_path" \
        || { /bin/rm -f "$_tmp"; return 1; } ;;
    absent)
      if [[ -e "$_path" || -L "$_path" ]]; then
        [[ -f "$_path" && ! -L "$_path" ]] || return 1
        _mdm_component_trusted "$_path" || return 1
        _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_path")")" \
          || return 1
        [[ "$_mode" == 0600 ]] || return 1
        /bin/rm -f "$_path" || return 1
      fi ;;
    *) return 1 ;;
  esac
  _mdm_component_receipt_dir_is_trusted "$_dir" || return 1
  [[ "$_state" == untouched || "$_state" == capturing ]] && return 0
  if [[ "$_state" == present ]]; then
    [[ -f "$_path" && ! -L "$_path" ]] \
      && _mdm_component_trusted "$_path" \
      && [[ "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_path")")" == 0600 ]]
  else
    [[ ! -e "$_path" && ! -L "$_path" ]]
  fi
}

_mdm_transaction_cleanup_root_snapshots() {
  local _snapshot _prefix
  for _snapshot in "${_MDM_TRANSACTION_HISTORY_SNAPSHOT:-}" \
    "${_MDM_TRANSACTION_COMPONENT_SNAPSHOT:-}"; do
    [[ -n "$_snapshot" ]] || continue
    case "${_snapshot##*/}" in
      claude-kit-mdm-history.*) _prefix=claude-kit-mdm-history ;;
      claude-kit-mdm-manifest.*) _prefix=claude-kit-mdm-manifest ;;
      *) return 1 ;;
    esac
    _mdm_managed_tmp_path_matches "$_snapshot" "$_prefix" || return 1
    if [[ -e "$_snapshot" || -L "$_snapshot" ]]; then
      [[ -f "$_snapshot" && ! -L "$_snapshot" ]] \
        && /bin/rm -f "$_snapshot" || return 1
    fi
  done
  _MDM_TRANSACTION_HISTORY_SNAPSHOT=""
  _MDM_TRANSACTION_COMPONENT_SNAPSHOT=""
}

_mdm_managed_parent_identity() { # <directory>
  if _mdm_is_darwin; then
    /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%d:%i' "$1" 2>/dev/null
  fi
}

_mdm_managed_parent_mode_needs_private() { # <mode>
  local _mode _owner _group _other
  _mode="$(_mdm_mode_normalize "$1")" || return 2
  _owner="${_mode:1:1}"
  _group="${_mode:2:1}"
  _other="${_mode:3:1}"
  [[ "$_owner" != 7 ]] && return 0
  case "$_group$_other" in
    *[2367]*) return 0 ;;
  esac
  return 1
}

# Emit one immutable plan for the live/snapshot parents selected by the
# authoritative expected manifest. The home itself and unrelated user paths
# are deliberately outside the inventory. Existing directories are bound by
# dev+inode; a final postcondition additionally requires every managed-file
# parent and both managed roots to exist.
_mdm_managed_parent_inventory() { # <home> <target-uid> <preflight|final>
  local _home="$1" _uid="$2" _phase="$3" _manifest _python
  [[ "$_home" == /* && "$_home" != / && ! "$_home" =~ [[:cntrl:]] \
    && "$_uid" =~ ^[0-9]+$ ]] || return 1
  case "$_phase" in preflight|final) : ;; *) return 1 ;; esac
  _manifest="${_MDM_EXPECTED_OUTPUT:-}/manifest.json"
  [[ -f "$_manifest" && ! -L "$_manifest" ]] || return 1
  _python="$(_mdm_system_python)" || return 1
  _mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_SETUP_SECONDS")" \
    /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_manifest" "$_home" "$_uid" "$_phase" <<'PY'
import json
import os
import stat
import sys

manifest_path, home, uid_raw, phase = sys.argv[1:]
uid = int(uid_raw)
if phase not in ("preflight", "final"):
    raise SystemExit(1)
require_managed = phase == "final"

def invalid_text(value):
    return (not isinstance(value, str) or not value
            or any(ord(char) < 32 or 127 <= ord(char) <= 159
                   or 0xD800 <= ord(char) <= 0xDFFF for char in value))

def relative(value):
    if invalid_text(value) or value.startswith("/") or "\\" in value:
        raise ValueError("invalid relative path")
    parts = value.split("/")
    if (len(parts) > 64 or any(part in ("", ".", "..") for part in parts)
            or len(value.encode("utf-8", "strict")) > 1024):
        raise ValueError("invalid relative path")
    return parts

with open(manifest_path, "r", encoding="utf-8", errors="strict") as handle:
    manifest = json.load(handle)
files = manifest.get("files")
absent = manifest.get("absent_files")
if (not isinstance(files, list) or not 1 <= len(files) <= 1000
        or not isinstance(absent, list) or len(absent) > 1000
        or len(set(files)) != len(files) or len(set(absent)) != len(absent)):
    raise SystemExit(1)
file_parts = [relative(value) for value in files]
absent_parts = [relative(value) for value in absent]

claude = home + "/.claude"
snapshot = claude + "/.starter-kit-snapshot"
records = {}

def capture(path):
    before = os.lstat(path)
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
        raise ValueError("managed parent is not a real directory")
    if before.st_uid != uid or os.path.realpath(path) != path:
        raise ValueError("managed parent identity is unsafe")
    mode = stat.S_IMODE(before.st_mode)
    identity = (before.st_dev, before.st_ino)
    previous = records.get(path)
    value = (identity, mode)
    if previous is not None and previous != value:
        raise ValueError("managed parent changed")
    records[path] = value

def root_exists(root):
    try:
        capture(root)
        return True
    except FileNotFoundError:
        if require_managed:
            raise ValueError("managed root is missing")
        return False

def walk(root, parts, required):
    try:
        capture(root)
    except FileNotFoundError:
        if required:
            raise ValueError("managed root is missing")
        return
    current = root
    for part in parts[:-1]:
        current += "/" + part
        try:
            capture(current)
        except FileNotFoundError:
            if required:
                raise ValueError("managed file parent is missing")
            return

for root in (claude, snapshot):
    present = root_exists(root)
    if not present:
        continue
    for parts in file_parts:
        walk(root, parts, require_managed)
    for parts in absent_parts:
        walk(root, parts, False)

ordered = sorted(records, key=lambda path: (path.count("/"), os.fsencode(path)))
if len(ordered) > 65536:
    raise SystemExit(1)
sys.stdout.write("v1\t{}\t{}\n".format(uid, home))
for path in ordered:
    identity, mode = records[path]
    change = int(((mode >> 6) & 0o7) != 0o7 or bool(mode & 0o22))
    sys.stdout.write("{}\t{}:{}\t{:04o}\t{}\n".format(
        path, identity[0], identity[1], mode, change))
sys.stdout.write("end\t{}\n".format(len(ordered)))
PY
}

_mdm_managed_parent_record_valid() {
  # <path> <dev:inode> <original-mode> <change-flag> <home> <uid>
  # <original|applied>
  local _path="$1" _identity="$2" _original="$3" _change="$4"
  local _home="$5" _uid="$6" _phase="$7" _canonical _mode _expected
  [[ "$_identity" =~ ^[0-9]+:[0-9]+$ \
    && "$_original" =~ ^[0-7]{4}$ \
    && ( "$_change" == 0 || "$_change" == 1 ) ]] || return 1
  case "$_path" in "$_home/.claude"|"$_home/.claude"/*) : ;; *) return 1 ;; esac
  [[ "$_path" != "$_home" && -d "$_path" && ! -L "$_path" ]] || return 1
  _canonical="$(_mdm_canonical_dir "$_path" 2>/dev/null || true)"
  [[ "$_canonical" == "$_path" \
    && "$(_mdm_stat_uid "$_path" 2>/dev/null || true)" == "$_uid" \
    && "$(_mdm_managed_parent_identity "$_path" 2>/dev/null || true)" \
      == "$_identity" ]] || return 1
  _mdm_user_dir_acl_safe "$_path" || return 1
  _mode="$(_mdm_mode_normalize \
    "$(_mdm_launcher_stat_mode "$_path" 2>/dev/null || true)")" || return 1
  case "$_phase" in
    original) _expected="$_original" ;;
    applied)
      if [[ "$_change" == 1 ]]; then _expected=0700; else _expected="$_original"; fi ;;
    *) return 1 ;;
  esac
  [[ "$_mode" == "$_expected" ]] || return 1
  [[ "$(_mdm_managed_parent_identity "$_path" 2>/dev/null || true)" \
      == "$_identity" \
    && "$(_mdm_mode_normalize \
      "$(_mdm_launcher_stat_mode "$_path" 2>/dev/null || true)" \
      2>/dev/null || true)" == "$_expected" ]] || return 1
  _mdm_user_dir_acl_safe "$_path" || return 1
  [[ "$(_mdm_managed_parent_identity "$_path" 2>/dev/null || true)" \
    == "$_identity" ]]
}

_mdm_managed_parent_plan_bytes_valid() { # <plan> <home> <uid>
  local _plan="$1" _home="$2" _uid="$3" _python
  _python="$(_mdm_system_python)" || return 1
  _mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_SETUP_SECONDS")" \
    /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S -c '
import os
import stat
import sys

path, home, uid_raw = sys.argv[1:]
uid = int(uid_raw)
flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
descriptor = os.open(path, flags)
try:
    before = os.fstat(descriptor)
    if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
            or before.st_size < 1 or before.st_size > 128 * 1024 * 1024):
        raise ValueError("unsafe plan file")
    chunks = []
    remaining = before.st_size
    while remaining:
        chunk = os.read(descriptor, min(1024 * 1024, remaining))
        if not chunk:
            raise ValueError("short plan read")
        chunks.append(chunk)
        remaining -= len(chunk)
    if os.read(descriptor, 1):
        raise ValueError("plan grew")
    after = os.fstat(descriptor)
    current = os.stat(path, follow_symlinks=False)
    identity = lambda value: (
        value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
        value.st_uid, value.st_gid, value.st_size,
        value.st_mtime_ns, value.st_ctime_ns)
    if identity(after) != identity(before) or identity(current) != identity(before):
        raise ValueError("plan changed")
finally:
    os.close(descriptor)
data = b"".join(chunks)
if not data.endswith(b"\n") or b"\x00" in data or b"\r" in data:
    raise ValueError("non-canonical plan bytes")
lines = data[:-1].decode("utf-8", "strict").split("\n")
if len(lines) < 2 or lines[0].split("\t") != ["v1", str(uid), home]:
    raise ValueError("invalid plan header")
records = []
claude = home + "/.claude"
for line in lines[1:-1]:
    fields = line.split("\t")
    if len(fields) != 4:
        raise ValueError("invalid plan record")
    record_path, record_identity, mode, change = fields
    identity_parts = record_identity.split(":")
    if (record_path != claude and not record_path.startswith(claude + "/")):
        raise ValueError("plan path escaped")
    if (any(ord(char) < 32 or 127 <= ord(char) <= 159
            or 0xD800 <= ord(char) <= 0xDFFF for char in record_path)
            or len(identity_parts) != 2
            or any(not value.isascii() or not value.isdigit()
                   for value in identity_parts)
            or len(mode) != 4 or any(value not in "01234567" for value in mode)
            or change not in ("0", "1")):
        raise ValueError("invalid plan field")
    records.append(record_path)
if (len(records) > 65536 or len(set(records)) != len(records)
        or records != sorted(records,
                             key=lambda value: (value.count("/"),
                                                os.fsencode(value)))):
    raise ValueError("invalid plan ordering")
record_set = set(records)
snapshot = claude + "/.starter-kit-snapshot"
for record_path in records:
    if record_path.endswith("/"):
        raise ValueError("plan path has a trailing slash")
    parent = record_path.rsplit("/", 1)[0]
    if record_path != claude and parent not in record_set:
        raise ValueError("plan ancestor is missing")
    if record_path == claude:
        suffix = ""
    elif record_path == snapshot:
        suffix = ""
    elif record_path.startswith(snapshot + "/"):
        suffix = record_path[len(snapshot) + 1:]
    else:
        suffix = record_path[len(claude) + 1:]
    if suffix:
        parts = suffix.split("/")
        if (len(parts) > 64 or any(part in ("", ".", "..")
                                   for part in parts)
                or "\\" in suffix
                or len(suffix.encode("utf-8", "strict")) > 1024):
            raise ValueError("invalid plan relative path")
end = lines[-1].split("\t")
if end != ["end", str(len(records))]:
    raise ValueError("invalid plan terminator")
' "$_plan" "$_home" "$_uid" >/dev/null 2>&1
}

_mdm_managed_parent_plan_valid_inner() { # <plan> <home> <uid> <original|applied>
  local _plan="$1" _home="$2" _uid="$3" _phase="$4"
  local _line _tag _field2 _field3 _field4 _extra _count=0 _ended=0
  local _header_seen=0 _previous="" _printable _mode_rc
  case "$_phase" in original|applied) : ;; *) return 1 ;; esac
  [[ -f "$_plan" && ! -L "$_plan" ]] || return 1
  _mdm_managed_parent_plan_bytes_valid "$_plan" "$_home" "$_uid" || return 1
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    [[ -n "$_line" ]] || return 1
    _printable="${_line//$'\t'/}"
    [[ ! "$_printable" =~ [[:cntrl:]] ]] || return 1
    _tag=""; _field2=""; _field3=""; _field4=""; _extra=""
    IFS=$'\t' read -r _tag _field2 _field3 _field4 _extra <<< "$_line"
    if [[ "$_header_seen" -eq 0 ]]; then
      [[ "$_tag" == v1 && "$_field2" == "$_uid" \
        && "$_field3" == "$_home" && -z "$_field4$_extra" ]] || return 1
      _header_seen=1
      continue
    fi
    [[ "$_ended" -eq 0 ]] || return 1
    if [[ "$_tag" == end ]]; then
      [[ "$_field2" =~ ^[0-9]+$ && "$_field2" -eq "$_count" \
        && -z "$_field3$_field4$_extra" ]] || return 1
      _ended=1
      continue
    fi
    [[ -z "$_extra" && "$_tag" != "$_previous" ]] || return 1
    _mdm_managed_parent_record_valid "$_tag" "$_field2" "$_field3" \
      "$_field4" "$_home" "$_uid" "$_phase" || return 1
    if [[ "$_phase" == original ]]; then
      _mode_rc=0
      _mdm_managed_parent_mode_needs_private "$_field3" || _mode_rc=$?
      case "$_mode_rc" in
        0) [[ "$_field4" == 1 ]] || return 1 ;;
        1) [[ "$_field4" == 0 ]] || return 1 ;;
        *) return 1 ;;
      esac
    elif [[ "$_field4" == 1 ]]; then
      [[ "$(_mdm_mode_normalize \
        "$(_mdm_launcher_stat_mode "$_tag" 2>/dev/null || true)")" == 0700 ]] \
        || return 1
    fi
    _previous="$_tag"
    _count=$((_count + 1)); [[ "$_count" -le 65536 ]] || return 1
  done < "$_plan"
  [[ "$_header_seen" -eq 1 && "$_ended" -eq 1 ]]
}

_mdm_managed_parent_plan_valid() { # <plan> <home> <uid> <original|applied>
  _mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_SETUP_SECONDS")" \
    _mdm_managed_parent_plan_valid_inner "$@"
}

_mdm_managed_parent_journal_trusted() {
  local _path="${_MDM_PARENT_MODE_JOURNAL:-}" _base _meta _rest _mode
  [[ -n "$_path" && -n "${_MDM_PARENT_MODE_JOURNAL_IDENTITY:-}" ]] || return 1
  _base="$(_mdm_auth_tmp_base)"
  case "$_path" in "$_base"/claude-kit-mdm-parent-modes.*) : ;; *) return 1 ;; esac
  [[ -f "$_path" && ! -L "$_path" \
    && "$(_mdm_canonical_file "$_path" 2>/dev/null || true)" == "$_path" \
    && "$(_mdm_stat_identity "$_path" 2>/dev/null || true)" \
      == "$_MDM_PARENT_MODE_JOURNAL_IDENTITY" ]] || return 1
  _meta="$(_mdm_stat_managed_metadata "$_path")" || return 1
  [[ "$_meta" =~ ^[0-9]+:1:[0-7]+$ ]] || return 1
  _rest="${_meta#*:}"; _rest="${_rest#*:}"
  _mode="$(_mdm_mode_normalize "$_rest")" || return 1
  [[ "${_meta%%:*}" == "$(_mdm_auth_expected_uid)" && "$_mode" == 0600 ]] \
    || return 1
  ! _mdm_has_extended_acl "$_path"
}

_mdm_managed_parent_journal_discard() {
  local _path="${_MDM_PARENT_MODE_JOURNAL:-}" _base _uid
  [[ -n "$_path" ]] || { _MDM_PARENT_MODE_STATE=idle; return 0; }
  _base="$(_mdm_auth_tmp_base)"
  case "$_path" in "$_base"/claude-kit-mdm-parent-modes.*) : ;; *) return 1 ;; esac
  if [[ -n "${_MDM_PARENT_MODE_JOURNAL_IDENTITY:-}" ]]; then
    _mdm_managed_parent_journal_trusted || return 1
  else
    [[ -f "$_path" && ! -L "$_path" \
      && "$(_mdm_canonical_file "$_path" 2>/dev/null || true)" == "$_path" ]] \
      || return 1
    _uid="$(_mdm_stat_uid "$_path" 2>/dev/null || true)"
    [[ "$_uid" == "$(_mdm_auth_expected_uid)" ]] || return 1
  fi
  /bin/rm -f "$_path" || return 1
  _MDM_PARENT_MODE_JOURNAL=""
  _MDM_PARENT_MODE_JOURNAL_IDENTITY=""
  _MDM_PARENT_MODE_STATE=idle
}

_mdm_managed_parent_target_modes() { # <apply|restore> <home> <uid>
  local _operation="$1" _home="$2" _uid="$3" _python _fault_after=""
  case "$_operation" in apply|restore) : ;; *) return 1 ;; esac
  _python="$(_mdm_system_python)" || return 1
  if [[ "${_MDM_TEST_MODE:-0}" == 1 ]]; then
    _fault_after="${MDM_PARENT_MODE_FAULT_AFTER_OVERRIDE:-}"
    [[ -z "$_fault_after" || "$_fault_after" =~ ^[1-9][0-9]*$ ]] || return 1
  fi
  _mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_SETUP_SECONDS")" \
    /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S -c '
import os
import stat
import sys

operation, uid_raw, home, journal_path, journal_uid_raw, fault_raw = sys.argv[1:]
uid = int(uid_raw)
journal_uid = int(journal_uid_raw)
fault_after = int(fault_raw) if fault_raw else None
if operation not in ("apply", "restore") or not home.startswith("/"):
    raise SystemExit(1)

file_flags = (os.O_RDONLY | os.O_NOFOLLOW
              | getattr(os, "O_CLOEXEC", 0))
journal_fd = os.open(journal_path, file_flags)
try:
    journal_before = os.fstat(journal_fd)
    if (not stat.S_ISREG(journal_before.st_mode)
            or journal_before.st_uid != journal_uid
            or journal_before.st_nlink != 1
            or stat.S_IMODE(journal_before.st_mode) != 0o600
            or journal_before.st_size < 1
            or journal_before.st_size > 128 * 1024 * 1024):
        raise ValueError("unsafe managed-parent journal")
    chunks = []
    remaining = journal_before.st_size
    while remaining:
        chunk = os.read(journal_fd, min(1024 * 1024, remaining))
        if not chunk:
            raise ValueError("short managed-parent journal read")
        chunks.append(chunk)
        remaining -= len(chunk)
    if os.read(journal_fd, 1):
        raise ValueError("managed-parent journal grew")
    journal_after = os.fstat(journal_fd)
    journal_path_after = os.stat(journal_path, follow_symlinks=False)
    journal_identity = lambda value: (
        value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
        value.st_uid, value.st_gid, value.st_size,
        value.st_mtime_ns, value.st_ctime_ns)
    if (journal_identity(journal_after) != journal_identity(journal_before)
            or journal_identity(journal_path_after)
                != journal_identity(journal_before)):
        raise ValueError("managed-parent journal changed")
    journal_bytes = b"".join(chunks)
finally:
    os.close(journal_fd)
if not journal_bytes.endswith(b"\n") or b"\x00" in journal_bytes:
    raise SystemExit(1)
lines = journal_bytes.splitlines()
if len(lines) < 2:
    raise SystemExit(1)
header = lines[0].decode("utf-8", "strict").split("\t")
if header != ["v1", str(uid), home]:
    raise SystemExit(1)
records = []
ended = False
for index, raw in enumerate(lines[1:], 1):
    fields = raw.decode("utf-8", "strict").split("\t")
    if fields[0] == "end":
        if (ended or index != len(lines) - 1 or len(fields) != 2
                or not fields[1].isascii() or not fields[1].isdigit()
                or int(fields[1]) != len(records)):
            raise SystemExit(1)
        ended = True
        break
    if len(fields) != 4:
        raise SystemExit(1)
    path, identity_raw, mode_raw, change_raw = fields
    claude = home + "/.claude"
    identity_parts = identity_raw.split(":")
    if (len(identity_parts) != 2
            or any(not value.isascii() or not value.isdigit()
                   for value in identity_parts)
            or len(mode_raw) != 4 or any(value not in "01234567"
                                         for value in mode_raw)
            or path != claude and not path.startswith(claude + "/")
            or any(ord(value) < 32 or 127 <= ord(value) <= 159
                   for value in path)
            or change_raw not in ("0", "1")):
        raise SystemExit(1)
    identity = tuple(int(value) for value in identity_parts)
    records.append((path, identity, int(mode_raw, 8), change_raw == "1"))
if not ended or len(records) > 65536:
    raise SystemExit(1)

if operation == "restore":
    records.reverse()

directory_flags = (os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
                   | getattr(os, "O_CLOEXEC", 0))

def inode(value):
    return value.st_dev, value.st_ino

def open_chain(path, expected):
    parts = path.split("/")[1:]
    if (not parts or any(not part or part in (".", "..") for part in parts)):
        raise ValueError("invalid managed-parent path")
    descriptors = [os.open("/", directory_flags)]
    bindings = []
    try:
        for name in parts:
            parent_fd = descriptors[-1]
            child_fd = os.open(name, directory_flags, dir_fd=parent_fd)
            descriptors.append(child_fd)
            child = os.fstat(child_fd)
            linked = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if (not stat.S_ISDIR(child.st_mode) or inode(child) != inode(linked)):
                raise ValueError("managed-parent chain changed")
            bindings.append((parent_fd, name, child_fd, inode(child)))
        leaf = os.fstat(descriptors[-1])
        if leaf.st_uid != uid or inode(leaf) != expected:
            raise ValueError("managed-parent leaf changed")
        return descriptors, bindings
    except BaseException:
        for descriptor in reversed(descriptors):
            try:
                os.close(descriptor)
            except OSError:
                pass
        raise

def bindings_valid(bindings):
    for parent_fd, name, child_fd, expected in reversed(bindings):
        child = os.fstat(child_fd)
        linked = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (not stat.S_ISDIR(child.st_mode) or inode(child) != expected
                or inode(linked) != expected):
            raise ValueError("managed-parent binding changed")

def close_chain(descriptors):
    for descriptor in reversed(descriptors):
        try:
            os.close(descriptor)
        except OSError:
            pass

def apply_record(record):
    path, identity, original_mode, _change = record
    descriptors, bindings = open_chain(path, identity)
    leaf_fd = descriptors[-1]
    changed_here = False
    try:
        before = os.fstat(leaf_fd)
        if stat.S_IMODE(before.st_mode) != original_mode:
            raise ValueError("managed-parent mode changed before apply")
        os.fchmod(leaf_fd, 0o700)
        changed_here = True
        os.fsync(leaf_fd)
        after = os.fstat(leaf_fd)
        if inode(after) != identity or stat.S_IMODE(after.st_mode) != 0o700:
            raise ValueError("managed-parent apply failed")
        bindings_valid(bindings)
    except BaseException:
        if changed_here:
            try:
                os.fchmod(leaf_fd, original_mode)
                os.fsync(leaf_fd)
            except OSError:
                pass
        raise
    finally:
        close_chain(descriptors)

def restore_record(record):
    path, identity, original_mode, _change = record
    descriptors, bindings = open_chain(path, identity)
    leaf_fd = descriptors[-1]
    try:
        before = os.fstat(leaf_fd)
        current_mode = stat.S_IMODE(before.st_mode)
        if current_mode == original_mode:
            target_mode = original_mode
            os.fsync(leaf_fd)
        elif current_mode == 0o700:
            target_mode = original_mode
            os.fchmod(leaf_fd, target_mode)
            os.fsync(leaf_fd)
        else:
            raise ValueError("managed-parent mode changed before restore")
        after = os.fstat(leaf_fd)
        if (inode(after) != identity
                or stat.S_IMODE(after.st_mode) != target_mode):
            raise ValueError("managed-parent restore failed")
        bindings_valid(bindings)
    finally:
        close_chain(descriptors)

changed_records = []
if operation == "apply":
    try:
        for record in records:
            if not record[3]:
                continue
            apply_record(record)
            changed_records.append(record)
            if fault_after is not None and len(changed_records) >= fault_after:
                raise ValueError("source-only managed-parent fault")
    except BaseException:
        for record in reversed(changed_records):
            try:
                restore_record(record)
            except (OSError, ValueError):
                pass
        raise
else:
    failures = 0
    for record in records:
        if not record[3]:
            continue
        try:
            restore_record(record)
        except (OSError, ValueError):
            failures += 1
    if failures:
        raise SystemExit(1)
' "$_operation" "$_uid" "$_home" "$_MDM_PARENT_MODE_JOURNAL" \
    "$(_mdm_auth_expected_uid)" "$_fault_after" >/dev/null 2>&1
}

_mdm_managed_parent_modes_prepare() { # <user> <home> <uid>
  local _user="$1" _home="$2" _uid="$3" _base _old_umask
  [[ "${_MDM_PARENT_MODE_STATE:-idle}" == idle \
    && "${_MDM_TRANSACTION_STATE:-idle}" == active \
    && "$_user" == "${_MDM_TRANSACTION_USER:-}" \
    && "$_home" == "${_MDM_TRANSACTION_HOME:-}" \
    && "$_uid" == "${_MDM_TRANSACTION_UID:-}" ]] || return 1
  _base="$(_mdm_auth_tmp_base)"
  _mdm_auth_base_trusted "$_base" || return 1
  _old_umask="$(umask)"; umask 077
  _MDM_PARENT_MODE_STATE=planning
  _MDM_PARENT_MODE_JOURNAL="$(/usr/bin/mktemp \
    "$_base/claude-kit-mdm-parent-modes.XXXXXX")" \
    || { umask "$_old_umask"; _MDM_PARENT_MODE_STATE=idle; return 1; }
  umask "$_old_umask"
  /bin/chmod 0600 "$_MDM_PARENT_MODE_JOURNAL" \
    || { _mdm_managed_parent_journal_discard || true; return 1; }
  if ! _mdm_managed_parent_inventory "$_home" "$_uid" preflight \
      > "$_MDM_PARENT_MODE_JOURNAL"; then
    _mdm_managed_parent_journal_discard || true
    return 1
  fi
  /bin/chmod 0600 "$_MDM_PARENT_MODE_JOURNAL" \
    || { _mdm_managed_parent_journal_discard || true; return 1; }
  _MDM_PARENT_MODE_JOURNAL_IDENTITY="$(_mdm_stat_identity \
    "$_MDM_PARENT_MODE_JOURNAL")" \
    || { _mdm_managed_parent_journal_discard || true; return 1; }
  _mdm_managed_parent_journal_trusted \
    && _mdm_managed_parent_plan_valid \
      "$_MDM_PARENT_MODE_JOURNAL" "$_home" "$_uid" original \
    || { _mdm_managed_parent_journal_discard || true; return 1; }
  _MDM_PARENT_MODE_STATE=planned
  _MDM_PARENT_MODE_STATE=applying
  if ! _mdm_managed_parent_target_modes apply "$_home" "$_uid"; then
    return 1
  fi
  _mdm_managed_parent_journal_trusted \
    && _mdm_managed_parent_plan_valid \
      "$_MDM_PARENT_MODE_JOURNAL" "$_home" "$_uid" applied \
    || return 1
  _MDM_PARENT_MODE_STATE=applied
}

_mdm_managed_parent_modes_restore() {
  local _state="${_MDM_PARENT_MODE_STATE:-idle}"
  case "$_state" in
    idle) return 0 ;;
    planning|planned) _mdm_managed_parent_journal_discard; return $? ;;
    applying|applied) : ;;
    *) return 1 ;;
  esac
  _mdm_managed_parent_journal_trusted || return 1
  _mdm_managed_parent_target_modes restore \
    "$_MDM_TRANSACTION_HOME" "$_MDM_TRANSACTION_UID" || return 1
  _mdm_managed_parent_plan_valid "$_MDM_PARENT_MODE_JOURNAL" \
    "$_MDM_TRANSACTION_HOME" "$_MDM_TRANSACTION_UID" original || return 1
  _mdm_managed_parent_journal_discard
}

_mdm_managed_parent_modes_commit() {
  case "${_MDM_PARENT_MODE_STATE:-idle}" in
    idle) return 0 ;;
    applied)
      _mdm_managed_parent_journal_trusted || return 1
      _mdm_managed_parent_journal_discard ;;
    *) return 1 ;;
  esac
}

_mdm_managed_parent_check_discard() {
  local _path="${_MDM_PARENT_MODE_CHECK:-}" _base _uid
  [[ -n "$_path" ]] || return 0
  _base="$(_mdm_auth_tmp_base)"
  _mdm_auth_base_trusted "$_base" || return 1
  case "$_path" in "$_base"/claude-kit-mdm-parent-check.*) : ;; *) return 1 ;; esac
  if [[ -e "$_path" || -L "$_path" ]]; then
    [[ -f "$_path" && ! -L "$_path" \
      && "$(_mdm_canonical_file "$_path" 2>/dev/null || true)" == "$_path" ]] \
      || return 1
    _uid="$(_mdm_stat_uid "$_path" 2>/dev/null || true)"
    [[ "$_uid" == "$(_mdm_auth_expected_uid)" ]] || return 1
    /bin/rm -f "$_path" || return 1
  fi
  _MDM_PARENT_MODE_CHECK=""
}

_mdm_managed_parent_modes_final() { # <home> <uid>
  local _home="$1" _uid="$2" _plan _base _old_umask _rc=1
  local _identity _meta _rest _mode
  [[ -z "${_MDM_PARENT_MODE_CHECK:-}" ]] || return 1
  _base="$(_mdm_auth_tmp_base)"
  _mdm_auth_base_trusted "$_base" || return 1
  _old_umask="$(umask)"; umask 077
  _MDM_PARENT_MODE_CHECK="$(/usr/bin/mktemp \
    "$_base/claude-kit-mdm-parent-check.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  _plan="$_MDM_PARENT_MODE_CHECK"
  /bin/chmod 0600 "$_plan" \
    || { _mdm_managed_parent_check_discard || true; return 1; }
  if ! _mdm_managed_parent_inventory "$_home" "$_uid" final > "$_plan"; then
    _mdm_managed_parent_check_discard || true
    return 1
  fi
  /bin/chmod 0600 "$_plan" \
    || { _mdm_managed_parent_check_discard || true; return 1; }
  _identity="$(_mdm_stat_identity "$_plan")" \
    || { _mdm_managed_parent_check_discard || true; return 1; }
  _meta="$(_mdm_stat_managed_metadata "$_plan")" \
    || { _mdm_managed_parent_check_discard || true; return 1; }
  _rest="${_meta#*:}"; _rest="${_rest#*:}"
  _mode="$(_mdm_mode_normalize "$_rest")" \
    || { _mdm_managed_parent_check_discard || true; return 1; }
  if [[ "$(_mdm_canonical_file "$_plan" 2>/dev/null || true)" == "$_plan" \
    && "${_meta%%:*}" == "$(_mdm_auth_expected_uid)" \
    && "${_meta#*:}" == 1:* && "$_mode" == 0600 ]] \
    && ! _mdm_has_extended_acl "$_plan" \
    && _mdm_managed_parent_plan_valid "$_plan" "$_home" "$_uid" applied \
    && [[ "$(_mdm_stat_identity "$_plan" 2>/dev/null || true)" == "$_identity" ]]; then
    _rc=0
  fi
  _mdm_managed_parent_check_discard || _rc=1
  return "$_rc"
}

# The outer transaction also covers the exact target-user leaves which setup
# may mutate outside ~/.claude.  Never widen this inventory to a user-owned
# parent: every record below is one kit-reserved activation/configuration leaf.
_mdm_external_claude_active_relative() { # <home> <uid>
  local _home="$1" _uid="$2" _link _versions _target _name _before _after
  _link="$_home/.local/bin/claude"
  _versions="$_home/.local/share/claude/versions"
  [[ "$_uid" =~ ^[0-9]+$ ]] || return 1
  [[ -L "$_link" ]] || return 2
  _before="$(_mdm_stat_identity "$_link")" || return 1
  _mdm_readlink_exact "$_link" _target || return 1
  _after="$(_mdm_stat_identity "$_link")" || return 1
  [[ "$_after" == "$_before" && "$_target" == /* \
    && "${_target%/*}" == "$_versions" ]] || return 1
  _name="${_target##*/}"
  [[ "$_name" =~ ^[0-9A-Za-z._+-]+$ && "${#_name}" -le 255 ]] \
    || return 1
  [[ "$(_mdm_stat_identity "$_link" 2>/dev/null || true)" == "$_before" ]] \
    || return 1
  printf '.local/share/claude/versions/%s' "$_name"
}

_mdm_external_transaction_paths() { # <home> <uid>
  local _home="$1" _uid="$2" _component _mode _name _sha _family _target
  local _target_rc=0 _font_inventory
  [[ "$_home" == /* && "$_home" != / && ! "$_home" =~ [[:cntrl:]] ]] \
    || return 1
  [[ "$_uid" =~ ^[0-9]+$ ]] || return 1
  _mode="${KIT_MDM_PREREQ_MODE:-auto}"
  case "$_mode" in auto|fail) : ;; *) return 1 ;; esac
  for _component in "${MDM_REQUIRED_COMPONENTS[@]}"; do
    case "$_component:$_mode" in
      biome:auto)
        printf '%s\n' '.local/bin/biome' \
          '.local/lib/claude-code-starter-kit/biome/2.5.4' ;;
      claude_cli:auto)
        printf '%s\n' '.local/bin/claude'
        _target=""
        _target_rc=0
        _target="$(_mdm_external_claude_active_relative \
          "$_home" "$_uid" 2>/dev/null)" || _target_rc=$?
        case "$_target_rc" in
          0) [[ -n "$_target" ]] || return 1; printf '%s\n' "$_target" ;;
          2) [[ -z "$_target" ]] || return 1 ;;
          *) return 1 ;;
        esac ;;
      fonts:auto)
        _font_inventory="$(_mdm_component_font_expected_inventory)" \
          || return 1
        [[ -n "$_font_inventory" ]] || return 1
        while read -r _name _sha _family; do
          [[ -n "$_name" ]] || return 1
          printf 'Library/Fonts/%s\n' "$_name"
        done <<< "$_font_inventory" ;;
      ghostty:auto|ghostty:fail)
        printf '%s\n' \
          'Library/Application Support/com.mitchellh.ghostty/config' ;;
      node_runtime:auto|node_runtime:fail)
        printf '%s\n' '.local/bin/node' ;;
      safety_net:auto)
        printf '%s\n' '.local/bin/cc-safety-net' \
          '.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6' ;;
    esac
  done
}

_mdm_external_transaction_journal_inode_identity() { # <journal>
  local _identity
  if _mdm_is_darwin; then
    LC_ALL=C /usr/bin/stat -f '%d:%i:%HT' "$1" 2>/dev/null
  else
    _identity="$(LC_ALL=C /usr/bin/stat -c '%d:%i:%F' "$1" \
      2>/dev/null)" || return 1
    case "$_identity" in
      *:regular\ empty\ file)
        _identity="${_identity%:regular empty file}:regular file" ;;
    esac
    printf '%s\n' "$_identity"
  fi
}

_mdm_external_transaction_journal_metadata_trusted() {
  local _path="${_MDM_EXTERNAL_TRANSACTION_JOURNAL:-}" _base _meta _rest _mode
  [[ -n "$_path" && -n "${_MDM_EXTERNAL_TRANSACTION_JOURNAL_IDENTITY:-}" ]] \
    || return 1
  _base="$(_mdm_auth_tmp_base)" || return 1
  case "$_path" in
    "$_base"/claude-kit-mdm-external.*) : ;;
    *) return 1 ;;
  esac
  [[ -f "$_path" && ! -L "$_path" \
    && "$(_mdm_canonical_file "$_path" 2>/dev/null || true)" == "$_path" \
    && "$(_mdm_external_transaction_journal_inode_identity \
      "$_path" 2>/dev/null || true)" \
      == "$_MDM_EXTERNAL_TRANSACTION_JOURNAL_IDENTITY" ]] || return 1
  _meta="$(_mdm_stat_managed_metadata "$_path")" || return 1
  [[ "$_meta" =~ ^[0-9]+:1:[0-7]+$ ]] || return 1
  _rest="${_meta#*:}"; _rest="${_rest#*:}"
  _mode="$(_mdm_mode_normalize "$_rest")" || return 1
  [[ "${_meta%%:*}" == "$(_mdm_auth_expected_uid)" && "$_mode" == 0600 ]] \
    || return 1
  ! _mdm_has_extended_acl "$_path"
}

_mdm_external_transaction_journal_discard() {
  local _path="${_MDM_EXTERNAL_TRANSACTION_JOURNAL:-}"
  [[ -n "$_path" ]] || return 0
  _mdm_external_transaction_journal_metadata_trusted || return 1
  /bin/rm -f "$_path" || return 1
  _MDM_EXTERNAL_TRANSACTION_JOURNAL=""
  _MDM_EXTERNAL_TRANSACTION_JOURNAL_IDENTITY=""
}

_mdm_external_transaction_journal_discard_unsealed() {
  local _path="${_MDM_EXTERNAL_TRANSACTION_JOURNAL:-}" _base
  [[ -n "$_path" ]] || return 0
  _base="$(_mdm_auth_tmp_base)" || return 1
  _mdm_auth_base_trusted "$_base" || return 1
  case "$_path" in
    "$_base"/claude-kit-mdm-external.*) : ;;
    *) return 1 ;;
  esac
  [[ -f "$_path" && ! -L "$_path" \
    && "$(_mdm_canonical_file "$_path" 2>/dev/null || true)" == "$_path" \
    && "$(_mdm_stat_uid "$_path" 2>/dev/null || true)" \
      == "$(_mdm_auth_expected_uid)" ]] || return 1
  if [[ -n "${_MDM_EXTERNAL_TRANSACTION_JOURNAL_IDENTITY:-}" ]]; then
    [[ "$(_mdm_external_transaction_journal_inode_identity \
      "$_path" 2>/dev/null || true)" \
      == "$_MDM_EXTERNAL_TRANSACTION_JOURNAL_IDENTITY" ]] || return 1
  fi
  /bin/rm -f "$_path" || return 1
  _MDM_EXTERNAL_TRANSACTION_JOURNAL=""
  _MDM_EXTERNAL_TRANSACTION_JOURNAL_IDENTITY=""
}

_mdm_external_transaction_invoke() {
  # <plan|apply|prepared|verify|abort|commit> <user> <home> <uid>
  # <journal-or-empty> <relative-path...>
  local _operation="$1" _user="$2" _home="$3" _uid="$4" _journal="$5"
  local _python _deadline _carrier=- _carrier_identity=- _apply_signal_after=-
  local _MDM_EXEC_AS_USER_DEADLINE_SECONDS
  local _runner=()
  shift 5
  case "$_operation" in
    plan|apply|prepared|verify|abort|abort_planned|commit|commit_retry) : ;;
    *) return 1 ;;
  esac
  [[ -n "$_user" && "$_home" == /* && "$_home" != / \
    && ! "$_home" =~ [[:cntrl:]] && "$_uid" =~ ^[0-9]+$ \
    && "$#" -ge 1 && "$#" -le 32 ]] || return 1
  if [[ "$_operation" == plan ]]; then
    [[ -z "$_journal" ]] || return 1
  else
    [[ -n "$_journal" ]] || return 1
    _mdm_external_transaction_journal_metadata_trusted || return 1
  fi
  if [[ "$_operation" == commit || "$_operation" == commit_retry ]]; then
    _python="$(_mdm_system_python)" || return 1
  else
    _python="$(_mdm_target_system_python)" || return 1
  fi
  _deadline="$(_mdm_timeout_seconds "$_MDM_TIMEOUT_SETUP_SECONDS")" \
    || return 1
  _MDM_EXEC_AS_USER_DEADLINE_SECONDS="$_deadline"
  if [[ "$_operation" == apply && "${_MDM_TEST_MODE:-0}" == 1 \
    && -n "${MDM_EXTERNAL_APPLY_SIGNAL_AFTER_OVERRIDE:-}" ]]; then
    _apply_signal_after="$MDM_EXTERNAL_APPLY_SIGNAL_AFTER_OVERRIDE"
    [[ "$_apply_signal_after" =~ ^(HUP|INT|TERM):([1-9][0-9]*)$ \
      && "${BASH_REMATCH[2]}" -le 32 ]] || return 1
  fi
  if [[ "$_operation" == plan ]]; then
    _mdm_exec_as_user "$_uid" "$_user" "$_home" \
      "$_python" -I -B -S -c '
import ctypes
import errno
import hashlib
import os
import stat
import sys

operation, home, uid_raw, count_raw, *expected = sys.argv[1:]
uid = int(uid_raw)
count = int(count_raw)
if operation not in ("plan", "apply", "prepared", "verify", "abort", "commit"):
    raise SystemExit(1)
if count != len(expected) or not 1 <= count <= 32:
    raise SystemExit(1)

def safe_relative(value):
    if (not value or value.startswith("/") or "\\" in value
            or any(ord(char) < 32 or 127 <= ord(char) <= 159
                   for char in value)):
        return False
    parts = value.split("/")
    return (len(parts) <= 64 and all(part not in ("", ".", "..")
                                    for part in parts)
            and len(value.encode("utf-8", "strict")) <= 1024)

if len(set(expected)) != len(expected) or not all(map(safe_relative, expected)):
    raise SystemExit(1)

DIR_FLAGS = (os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
             | getattr(os, "O_CLOEXEC", 0))
FILE_FLAGS = (os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
              | getattr(os, "O_CLOEXEC", 0))
DARWIN = sys.platform == "darwin"
LINK_FLAGS = (os.O_RDONLY | os.O_NONBLOCK | 0x00200000
              | getattr(os, "O_CLOEXEC", 0))
libc = ctypes.CDLL(None, use_errno=True)
if DARWIN:
    libc.renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p,
                                  ctypes.c_int, ctypes.c_char_p,
                                  ctypes.c_uint]
    libc.renameatx_np.restype = ctypes.c_int
    libc.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    libc.acl_get_fd_np.restype = ctypes.c_void_p
    libc.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                   ctypes.POINTER(ctypes.c_void_p)]
    libc.acl_get_entry.restype = ctypes.c_int
    libc.acl_get_tag_type.argtypes = [ctypes.c_void_p,
                                      ctypes.POINTER(ctypes.c_int)]
    libc.acl_get_tag_type.restype = ctypes.c_int
    libc.acl_free.argtypes = [ctypes.c_void_p]
    libc.acl_free.restype = ctypes.c_int
    libc.flistxattr.argtypes = [ctypes.c_int, ctypes.c_void_p,
                                ctypes.c_size_t, ctypes.c_int]
    libc.flistxattr.restype = ctypes.c_ssize_t
    libc.fgetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p,
                               ctypes.c_void_p, ctypes.c_size_t,
                               ctypes.c_uint32, ctypes.c_int]
    libc.fgetxattr.restype = ctypes.c_ssize_t
elif sys.platform.startswith("linux"):
    libc.renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p,
                               ctypes.c_int, ctypes.c_char_p,
                               ctypes.c_uint]
    libc.renameat2.restype = ctypes.c_int
else:
    raise SystemExit(1)

def kind(value):
    if stat.S_ISREG(value.st_mode):
        return "f"
    if stat.S_ISDIR(value.st_mode):
        return "d"
    if stat.S_ISLNK(value.st_mode):
        return "l"
    raise ValueError("unsupported external leaf")

def identity(value):
    links = 0 if stat.S_ISDIR(value.st_mode) else value.st_nlink
    return "{}:{}:{}:{}:{}:{}".format(
        value.st_dev, value.st_ino, kind(value), value.st_uid,
        value.st_gid, links)

def stable(value):
    return (value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode),
            stat.S_IMODE(value.st_mode), value.st_uid, value.st_gid,
            value.st_nlink, value.st_size, value.st_mtime_ns,
            getattr(value, "st_flags", 0), getattr(value, "st_gen", 0))

def put(digest, value):
    raw = value if isinstance(value, bytes) else str(value).encode("utf-8")
    digest.update(len(raw).to_bytes(8, "big"))
    digest.update(raw)

def no_acl(descriptor):
    if DARWIN:
        ctypes.set_errno(0)
        acl = libc.acl_get_fd_np(descriptor, 0x00000100)
        if acl:
            libc.acl_free(acl)
            raise ValueError("extended ACL")
        if ctypes.get_errno() != errno.ENOENT:
            raise OSError(ctypes.get_errno() or errno.EIO, "acl_get_fd_np")
    else:
        names = os.listxattr(descriptor)
        if ("system.posix_acl_access" in names
                or "system.posix_acl_default" in names):
            raise ValueError("extended ACL")

def safe_parent_acl(descriptor):
    if not DARWIN:
        no_acl(descriptor)
        return
    ctypes.set_errno(0)
    acl = libc.acl_get_fd_np(descriptor, 0x00000100)
    if not acl:
        error = ctypes.get_errno()
        if error == errno.ENOENT:
            return
        raise OSError(error or errno.EIO, "acl_get_fd_np")
    try:
        entry = ctypes.c_void_p()
        selector = 0
        seen = False
        while True:
            ctypes.set_errno(0)
            result = libc.acl_get_entry(acl, selector, ctypes.byref(entry))
            if result != 0:
                error = ctypes.get_errno()
                if result == -1 and error == errno.EINVAL and seen:
                    break
                raise OSError(error or errno.EIO, "acl_get_entry")
            tag = ctypes.c_int()
            ctypes.set_errno(0)
            if libc.acl_get_tag_type(entry, ctypes.byref(tag)) != 0:
                error = ctypes.get_errno()
                raise OSError(error or errno.EIO, "acl_get_tag_type")
            if tag.value != 2:
                raise ValueError("granting external parent ACL")
            seen = True
            selector = -1
        if not seen:
            raise ValueError("empty external parent ACL")
    finally:
        if libc.acl_free(acl) != 0:
            raise OSError(ctypes.get_errno() or errno.EIO, "acl_free")

def metadata(descriptor, digest):
    no_acl(descriptor)
    if DARWIN:
        needed = libc.flistxattr(descriptor, None, 0, 0x0020)
        if needed < 0 or needed > 64 * 1024:
            raise OSError(ctypes.get_errno() or errno.EIO, "flistxattr")
        if needed:
            buffer = ctypes.create_string_buffer(needed)
            actual = libc.flistxattr(descriptor, buffer, needed, 0x0020)
            if actual != needed:
                raise OSError(ctypes.get_errno() or errno.EIO, "flistxattr")
            raw = bytes(buffer[:actual])
            if not raw.endswith(b"\0"):
                raise ValueError("invalid xattr list")
            names = sorted(raw[:-1].split(b"\0"))
        else:
            names = []
    else:
        names = sorted((os.fsencode(value) for value in os.listxattr(descriptor)))
    if len(names) > 256:
        raise ValueError("too many xattrs")
    for name in names:
        if not name or len(name) > 1024:
            raise ValueError("invalid xattr name")
        if DARWIN:
            needed = libc.fgetxattr(descriptor, name, None, 0, 0, 0x0020)
            if needed < 0 or needed > 16 * 1024 * 1024:
                raise OSError(ctypes.get_errno() or errno.EIO, "fgetxattr")
            buffer = ctypes.create_string_buffer(max(needed, 1))
            actual = libc.fgetxattr(
                descriptor, name, buffer, needed, 0, 0x0020)
            if actual != needed:
                raise OSError(ctypes.get_errno() or errno.EIO, "fgetxattr")
            value = bytes(buffer[:actual])
        else:
            value = os.getxattr(descriptor, os.fsdecode(name))
        if len(value) > 16 * 1024 * 1024:
            raise ValueError("oversized xattr")
        put(digest, name)
        put(digest, value)

def safe_owned(value, regular_link=True):
    entry_kind = kind(value)
    if value.st_uid != uid:
        raise ValueError("foreign external leaf")
    if regular_link and entry_kind in ("f", "l") and value.st_nlink != 1:
        raise ValueError("hard-linked external leaf")
    return entry_kind

def digest_entry(parent_fd, name, relative, digest, counters, root_dev):
    before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    entry_kind = safe_owned(before)
    if before.st_dev != root_dev:
        raise ValueError("external tree crosses a mount")
    counters[0] += 1
    if counters[0] > 100000:
        raise ValueError("external tree too large")
    put(digest, relative)
    put(digest, entry_kind)
    put(digest, stat.S_IMODE(before.st_mode))
    put(digest, before.st_uid)
    put(digest, before.st_gid)
    put(digest, before.st_nlink)
    put(digest, before.st_size)
    put(digest, before.st_mtime_ns)
    put(digest, getattr(before, "st_flags", 0))
    put(digest, getattr(before, "st_gen", 0))
    if entry_kind == "l":
        first = os.readlink(name, dir_fd=parent_fd)
        second = os.readlink(name, dir_fd=parent_fd)
        if first != second or stable(os.stat(
                name, dir_fd=parent_fd, follow_symlinks=False)) != stable(before):
            raise ValueError("external symlink changed")
        put(digest, os.fsencode(first))
        if DARWIN:
            descriptor = os.open(name, LINK_FLAGS, dir_fd=parent_fd)
            try:
                if stable(os.fstat(descriptor)) != stable(before):
                    raise ValueError("external symlink binding changed")
                metadata(descriptor, digest)
                if (stable(os.fstat(descriptor)) != stable(before)
                        or stable(os.stat(
                            name, dir_fd=parent_fd,
                            follow_symlinks=False)) != stable(before)):
                    raise ValueError("external symlink metadata changed")
            finally:
                os.close(descriptor)
        return
    flags = DIR_FLAGS if entry_kind == "d" else FILE_FLAGS
    descriptor = os.open(name, flags, dir_fd=parent_fd)
    try:
        if stable(os.fstat(descriptor)) != stable(before):
            raise ValueError("external entry binding changed")
        metadata(descriptor, digest)
        if entry_kind == "f":
            if before.st_size > 512 * 1024 * 1024:
                raise ValueError("external file too large")
            remaining = before.st_size
            while remaining:
                block = os.read(descriptor, min(1024 * 1024, remaining))
                if not block:
                    raise ValueError("short external file")
                digest.update(block)
                remaining -= len(block)
            if os.read(descriptor, 1):
                raise ValueError("external file grew")
        else:
            names = sorted(os.listdir(descriptor), key=os.fsencode)
            for child in names:
                if child in ("", ".", "..") or "/" in child:
                    raise ValueError("unsafe external child")
                digest_entry(descriptor, child, relative + "/" + child,
                             digest, counters, root_dev)
            if sorted(os.listdir(descriptor), key=os.fsencode) != names:
                raise ValueError("external directory changed")
        if (stable(os.fstat(descriptor)) != stable(before)
                or stable(os.stat(name, dir_fd=parent_fd,
                                  follow_symlinks=False)) != stable(before)):
            raise ValueError("external entry changed")
    finally:
        os.close(descriptor)

def fingerprint(parent_fd, name):
    before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    safe_owned(before)
    first = hashlib.sha256()
    digest_entry(parent_fd, name, ".", first, [0], before.st_dev)
    middle = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    second = hashlib.sha256()
    digest_entry(parent_fd, name, ".", second, [0], before.st_dev)
    after = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if (stable(before) != stable(middle) or stable(middle) != stable(after)
            or first.digest() != second.digest()):
        raise ValueError("external leaf changed during digest")
    return identity(after), first.hexdigest()

def safe_parent(value):
    if (not stat.S_ISDIR(value.st_mode) or value.st_uid != uid
            or stat.S_IMODE(value.st_mode) & 0o022
            or stat.S_IMODE(value.st_mode) & 0o700 != 0o700):
        raise ValueError("unsafe external parent")

home_fd = os.open(home, DIR_FLAGS)
home_value = os.fstat(home_fd)
safe_parent(home_value)
safe_parent_acl(home_fd)
if os.path.realpath(home) != home:
    raise SystemExit(1)
home_identity = identity(home_value)

def parent_for(relative):
    parts = relative.split("/")
    current = os.dup(home_fd)
    anchor_relative = "."
    anchor_identity = home_identity
    try:
        for index, part in enumerate(parts[:-1]):
            try:
                before = os.stat(part, dir_fd=current,
                                 follow_symlinks=False)
            except FileNotFoundError:
                os.close(current)
                return None, parts[-1], anchor_relative, anchor_identity
            safe_parent(before)
            child = os.open(part, DIR_FLAGS, dir_fd=current)
            opened = os.fstat(child)
            linked = os.stat(part, dir_fd=current, follow_symlinks=False)
            if stable(opened) != stable(before) or stable(linked) != stable(before):
                os.close(child)
                raise ValueError("external parent changed")
            safe_parent_acl(child)
            os.close(current)
            current = child
            anchor_relative = "/".join(parts[:index + 1])
            anchor_identity = identity(opened)
        return current, parts[-1], anchor_relative, anchor_identity
    except BaseException:
        try:
            os.close(current)
        except OSError:
            pass
        raise

def backup_name(name, token):
    prefix = ".{}.claude-kit-mdm-{}.".format(name, token)
    return prefix + os.urandom(16).hex()

records = []
try:
    for relative in expected:
        parent, name, anchor_relative, anchor_identity = parent_for(relative)
        if parent is None:
            records.append((relative, "absent", "-", "-", "-",
                            anchor_relative, anchor_identity))
            continue
        try:
            try:
                os.stat(name, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                records.append((relative, "absent", "-", "-", "-",
                                anchor_relative, anchor_identity))
                continue
            if os.fstat(parent).st_dev != home_value.st_dev:
                raise ValueError("external leaf parent crosses a mount")
            old_identity, old_digest = fingerprint(parent, name)
            backup = ""
            for _attempt in range(100):
                candidate = backup_name(name, "old")
                try:
                    os.stat(candidate, dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    backup = candidate
                    break
            if not backup:
                raise ValueError("cannot allocate external backup name")
            records.append((relative, "present", backup, old_identity,
                            old_digest, anchor_relative, anchor_identity))
        finally:
            os.close(parent)
    claude_link = ".local/bin/claude"
    dynamic_targets = [
        value for value in expected
        if (value.startswith(".local/share/claude/versions/")
            and value.count("/") == 4)
    ]
    if claude_link in expected:
        if len(dynamic_targets) > 1:
            raise ValueError("multiple Claude CLI dynamic targets")
        parent, name, _anchor_relative, _anchor_identity = parent_for(
            claude_link)
        try:
            if parent is None:
                if dynamic_targets:
                    raise ValueError("Claude CLI target without launcher")
            else:
                try:
                    launcher = os.stat(
                        name, dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    launcher = None
                if launcher is None or not stat.S_ISLNK(launcher.st_mode):
                    if dynamic_targets:
                        raise ValueError("Claude CLI target without symlink")
                else:
                    before = fingerprint(parent, name)
                    first = os.readlink(name, dir_fd=parent)
                    second = os.readlink(name, dir_fd=parent)
                    after = fingerprint(parent, name)
                    version = os.path.basename(first)
                    versions = home + "/.local/share/claude/versions"
                    if (first != second or before != after
                            or not os.path.isabs(first)
                            or os.path.normpath(first) != first
                            or os.path.dirname(first) != versions
                            or not version
                            or len(version) > 255
                            or any(char not in
                                   "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-"
                                   for char in version)):
                        raise ValueError("unsafe Claude CLI launcher target")
                    actual = ".local/share/claude/versions/" + version
                    if dynamic_targets != [actual]:
                        raise ValueError("Claude CLI target inventory drift")
        finally:
            if parent is not None:
                os.close(parent)
finally:
    os.close(home_fd)

output = ["v1\t{}\t{}\t{}".format(uid, home, len(records))]
output.extend("\t".join(record) for record in records)
output.append("end\t{}".format(len(records)))
sys.stdout.write("\n".join(output) + "\n")
' plan "$_home" "$_uid" "$#" "$@"
  else
    if [[ "$_operation" == commit || "$_operation" == commit_retry ]]; then
      _mdm_external_commit_carrier_trusted || return 1
      _carrier="$_MDM_EXTERNAL_COMMIT_CARRIER"
      _carrier_identity="$_MDM_EXTERNAL_COMMIT_CARRIER_IDENTITY"
      _runner=(_mdm_run_with_timeout "$_deadline" \
        /usr/bin/env -i HOME=/var/root \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C)
    else
      _runner=(_mdm_exec_as_user "$_uid" "$_user" "$_home")
    fi
    "${_runner[@]}" "$_python" -I -B -S -c '
import ctypes
import errno
import hashlib
import os
import stat
import sys

operation, home, uid_raw, count_raw, carrier, carrier_id, signal_after, *expected = sys.argv[1:]
uid = int(uid_raw)
count = int(count_raw)
if operation not in ("apply", "prepared", "verify", "abort",
                     "abort_planned", "commit", "commit_retry"):
    raise SystemExit(1)
if count != len(expected) or not 1 <= count <= 32:
    raise SystemExit(1)
if operation in ("commit", "commit_retry"):
    if (not os.path.isabs(carrier) or not carrier_id
            or any(ord(char) < 32 or 127 <= ord(char) <= 159
                   for char in carrier)):
        raise SystemExit(1)
elif (carrier, carrier_id) != ("-", "-"):
    raise SystemExit(1)
if operation != "apply" and signal_after != "-":
    raise SystemExit(1)
signal_name = None
signal_after_count = None
if signal_after != "-":
    pieces = signal_after.split(":")
    if (len(pieces) != 2 or pieces[0] not in ("HUP", "INT", "TERM")
            or not pieces[1].isascii() or not pieces[1].isdigit()
            or not 1 <= int(pieces[1]) <= 32):
        raise SystemExit(1)
    signal_name = pieces[0]
    signal_after_count = int(pieces[1])

def safe_relative(value):
    if (not value or value.startswith("/") or "\\" in value
            or any(ord(char) < 32 or 127 <= ord(char) <= 159
                   for char in value)):
        return False
    parts = value.split("/")
    return (len(parts) <= 64 and all(part not in ("", ".", "..")
                                    for part in parts)
            and len(value.encode("utf-8", "strict")) <= 1024)

if len(set(expected)) != len(expected) or not all(map(safe_relative, expected)):
    raise SystemExit(1)

DIR_FLAGS = (os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
             | getattr(os, "O_CLOEXEC", 0))
FILE_FLAGS = (os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
              | getattr(os, "O_CLOEXEC", 0))
DARWIN = sys.platform == "darwin"
LINK_FLAGS = (os.O_RDONLY | os.O_NONBLOCK | 0x00200000
              | getattr(os, "O_CLOEXEC", 0))
libc = ctypes.CDLL(None, use_errno=True)
if DARWIN:
    libc.renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p,
                                  ctypes.c_int, ctypes.c_char_p,
                                  ctypes.c_uint]
    libc.renameatx_np.restype = ctypes.c_int
    libc.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    libc.acl_get_fd_np.restype = ctypes.c_void_p
    libc.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                   ctypes.POINTER(ctypes.c_void_p)]
    libc.acl_get_entry.restype = ctypes.c_int
    libc.acl_get_tag_type.argtypes = [ctypes.c_void_p,
                                      ctypes.POINTER(ctypes.c_int)]
    libc.acl_get_tag_type.restype = ctypes.c_int
    libc.acl_free.argtypes = [ctypes.c_void_p]
    libc.acl_free.restype = ctypes.c_int
    libc.flistxattr.argtypes = [ctypes.c_int, ctypes.c_void_p,
                                ctypes.c_size_t, ctypes.c_int]
    libc.flistxattr.restype = ctypes.c_ssize_t
    libc.fgetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p,
                               ctypes.c_void_p, ctypes.c_size_t,
                               ctypes.c_uint32, ctypes.c_int]
    libc.fgetxattr.restype = ctypes.c_ssize_t
elif sys.platform.startswith("linux"):
    libc.renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p,
                               ctypes.c_int, ctypes.c_char_p,
                               ctypes.c_uint]
    libc.renameat2.restype = ctypes.c_int
else:
    raise SystemExit(1)

def kind(value):
    if stat.S_ISREG(value.st_mode):
        return "f"
    if stat.S_ISDIR(value.st_mode):
        return "d"
    if stat.S_ISLNK(value.st_mode):
        return "l"
    raise ValueError("unsupported external leaf")

def identity(value):
    links = 0 if stat.S_ISDIR(value.st_mode) else value.st_nlink
    return "{}:{}:{}:{}:{}:{}".format(
        value.st_dev, value.st_ino, kind(value), value.st_uid,
        value.st_gid, links)

def stable(value):
    return (value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode),
            stat.S_IMODE(value.st_mode), value.st_uid, value.st_gid,
            value.st_nlink, value.st_size, value.st_mtime_ns,
            getattr(value, "st_flags", 0), getattr(value, "st_gen", 0))

def put(digest, value):
    raw = value if isinstance(value, bytes) else str(value).encode("utf-8")
    digest.update(len(raw).to_bytes(8, "big"))
    digest.update(raw)

def no_acl(descriptor):
    if DARWIN:
        ctypes.set_errno(0)
        acl = libc.acl_get_fd_np(descriptor, 0x00000100)
        if acl:
            libc.acl_free(acl)
            raise ValueError("extended ACL")
        if ctypes.get_errno() != errno.ENOENT:
            raise OSError(ctypes.get_errno() or errno.EIO, "acl_get_fd_np")
    else:
        names = os.listxattr(descriptor)
        if ("system.posix_acl_access" in names
                or "system.posix_acl_default" in names):
            raise ValueError("extended ACL")

def safe_parent_acl(descriptor):
    if not DARWIN:
        no_acl(descriptor)
        return
    ctypes.set_errno(0)
    acl = libc.acl_get_fd_np(descriptor, 0x00000100)
    if not acl:
        error = ctypes.get_errno()
        if error == errno.ENOENT:
            return
        raise OSError(error or errno.EIO, "acl_get_fd_np")
    try:
        entry = ctypes.c_void_p()
        selector = 0
        seen = False
        while True:
            ctypes.set_errno(0)
            result = libc.acl_get_entry(acl, selector, ctypes.byref(entry))
            if result != 0:
                error = ctypes.get_errno()
                if result == -1 and error == errno.EINVAL and seen:
                    break
                raise OSError(error or errno.EIO, "acl_get_entry")
            tag = ctypes.c_int()
            ctypes.set_errno(0)
            if libc.acl_get_tag_type(entry, ctypes.byref(tag)) != 0:
                error = ctypes.get_errno()
                raise OSError(error or errno.EIO, "acl_get_tag_type")
            if tag.value != 2:
                raise ValueError("granting external parent ACL")
            seen = True
            selector = -1
        if not seen:
            raise ValueError("empty external parent ACL")
    finally:
        if libc.acl_free(acl) != 0:
            raise OSError(ctypes.get_errno() or errno.EIO, "acl_free")

def metadata(descriptor, digest):
    no_acl(descriptor)
    if DARWIN:
        needed = libc.flistxattr(descriptor, None, 0, 0x0020)
        if needed < 0 or needed > 64 * 1024:
            raise OSError(ctypes.get_errno() or errno.EIO, "flistxattr")
        if needed:
            buffer = ctypes.create_string_buffer(needed)
            actual = libc.flistxattr(descriptor, buffer, needed, 0x0020)
            if actual != needed:
                raise OSError(ctypes.get_errno() or errno.EIO, "flistxattr")
            raw = bytes(buffer[:actual])
            if not raw.endswith(b"\0"):
                raise ValueError("invalid xattr list")
            names = sorted(raw[:-1].split(b"\0"))
        else:
            names = []
    else:
        names = sorted((os.fsencode(value) for value in os.listxattr(descriptor)))
    if len(names) > 256:
        raise ValueError("too many xattrs")
    for name in names:
        if not name or len(name) > 1024:
            raise ValueError("invalid xattr name")
        if DARWIN:
            needed = libc.fgetxattr(descriptor, name, None, 0, 0, 0x0020)
            if needed < 0 or needed > 16 * 1024 * 1024:
                raise OSError(ctypes.get_errno() or errno.EIO, "fgetxattr")
            buffer = ctypes.create_string_buffer(max(needed, 1))
            actual = libc.fgetxattr(
                descriptor, name, buffer, needed, 0, 0x0020)
            if actual != needed:
                raise OSError(ctypes.get_errno() or errno.EIO, "fgetxattr")
            value = bytes(buffer[:actual])
        else:
            value = os.getxattr(descriptor, os.fsdecode(name))
        if len(value) > 16 * 1024 * 1024:
            raise ValueError("oversized xattr")
        put(digest, name)
        put(digest, value)

def safe_owned(value):
    entry_kind = kind(value)
    if value.st_uid != uid:
        raise ValueError("foreign external leaf")
    if entry_kind in ("f", "l") and value.st_nlink != 1:
        raise ValueError("hard-linked external leaf")
    return entry_kind

def digest_entry(parent_fd, name, relative, digest, counters, root_dev):
    before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    entry_kind = safe_owned(before)
    if before.st_dev != root_dev:
        raise ValueError("external tree crosses a mount")
    counters[0] += 1
    if counters[0] > 100000:
        raise ValueError("external tree too large")
    for value in (relative, entry_kind, stat.S_IMODE(before.st_mode),
                  before.st_uid, before.st_gid, before.st_nlink,
                  before.st_size, before.st_mtime_ns,
                  getattr(before, "st_flags", 0),
                  getattr(before, "st_gen", 0)):
        put(digest, value)
    if entry_kind == "l":
        first = os.readlink(name, dir_fd=parent_fd)
        second = os.readlink(name, dir_fd=parent_fd)
        if first != second or stable(os.stat(
                name, dir_fd=parent_fd, follow_symlinks=False)) != stable(before):
            raise ValueError("external symlink changed")
        put(digest, os.fsencode(first))
        if DARWIN:
            descriptor = os.open(name, LINK_FLAGS, dir_fd=parent_fd)
            try:
                if stable(os.fstat(descriptor)) != stable(before):
                    raise ValueError("external symlink binding changed")
                metadata(descriptor, digest)
                if (stable(os.fstat(descriptor)) != stable(before)
                        or stable(os.stat(
                            name, dir_fd=parent_fd,
                            follow_symlinks=False)) != stable(before)):
                    raise ValueError("external symlink metadata changed")
            finally:
                os.close(descriptor)
        return
    descriptor = os.open(name, DIR_FLAGS if entry_kind == "d" else FILE_FLAGS,
                         dir_fd=parent_fd)
    try:
        if stable(os.fstat(descriptor)) != stable(before):
            raise ValueError("external entry binding changed")
        metadata(descriptor, digest)
        if entry_kind == "f":
            if before.st_size > 512 * 1024 * 1024:
                raise ValueError("external file too large")
            remaining = before.st_size
            while remaining:
                block = os.read(descriptor, min(1024 * 1024, remaining))
                if not block:
                    raise ValueError("short external file")
                digest.update(block)
                remaining -= len(block)
            if os.read(descriptor, 1):
                raise ValueError("external file grew")
        else:
            names = sorted(os.listdir(descriptor), key=os.fsencode)
            for child in names:
                if child in ("", ".", "..") or "/" in child:
                    raise ValueError("unsafe external child")
                digest_entry(descriptor, child, relative + "/" + child,
                             digest, counters, root_dev)
            if sorted(os.listdir(descriptor), key=os.fsencode) != names:
                raise ValueError("external directory changed")
        if (stable(os.fstat(descriptor)) != stable(before)
                or stable(os.stat(name, dir_fd=parent_fd,
                                  follow_symlinks=False)) != stable(before)):
            raise ValueError("external entry changed")
    finally:
        os.close(descriptor)

def fingerprint(parent_fd, name):
    before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    safe_owned(before)
    first = hashlib.sha256()
    digest_entry(parent_fd, name, ".", first, [0], before.st_dev)
    middle = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    second = hashlib.sha256()
    digest_entry(parent_fd, name, ".", second, [0], before.st_dev)
    after = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if (stable(before) != stable(middle) or stable(middle) != stable(after)
            or first.digest() != second.digest()):
        raise ValueError("external leaf changed during digest")
    return identity(after), first.hexdigest()

def safe_parent(value):
    if (not stat.S_ISDIR(value.st_mode) or value.st_uid != uid
            or stat.S_IMODE(value.st_mode) & 0o022
            or stat.S_IMODE(value.st_mode) & 0o700 != 0o700):
        raise ValueError("unsafe external parent")

home_fd = os.open(home, DIR_FLAGS)
home_value = os.fstat(home_fd)
safe_parent(home_value)
safe_parent_acl(home_fd)
if os.path.realpath(home) != home:
    raise SystemExit(1)
home_identity = identity(home_value)

carrier_fd = None
if operation in ("commit", "commit_retry"):
    pieces = carrier_id.split(":")
    if (len(pieces) != 2
            or any(not value.isascii() or not value.isdigit()
                   for value in pieces)
            or os.path.normpath(carrier) != carrier
            or os.path.realpath(carrier) != carrier):
        raise SystemExit(1)
    before = os.stat(carrier, follow_symlinks=False)
    carrier_fd = os.open(carrier, DIR_FLAGS)
    opened = os.fstat(carrier_fd)
    linked = os.stat(carrier, follow_symlinks=False)
    if (stable(before) != stable(opened) or stable(linked) != stable(opened)
            or not stat.S_ISDIR(opened.st_mode)
            or opened.st_uid != os.geteuid()
            or stat.S_IMODE(opened.st_mode) != 0o700
            or (opened.st_dev, opened.st_ino)
                != (int(pieces[0]), int(pieces[1]))
            or opened.st_dev != home_value.st_dev):
        raise SystemExit(1)
    no_acl(carrier_fd)

def parent_for(relative):
    parts = relative.split("/")
    current = os.dup(home_fd)
    anchors = {".": home_identity}
    try:
        for index, part in enumerate(parts[:-1]):
            try:
                before = os.stat(part, dir_fd=current,
                                 follow_symlinks=False)
            except FileNotFoundError:
                os.close(current)
                return None, parts[-1], anchors
            safe_parent(before)
            child = os.open(part, DIR_FLAGS, dir_fd=current)
            opened = os.fstat(child)
            linked = os.stat(part, dir_fd=current, follow_symlinks=False)
            if stable(opened) != stable(before) or stable(linked) != stable(before):
                os.close(child)
                raise ValueError("external parent changed")
            safe_parent_acl(child)
            os.close(current)
            current = child
            anchors["/".join(parts[:index + 1])] = identity(opened)
        return current, parts[-1], anchors
    except BaseException:
        try:
            os.close(current)
        except OSError:
            pass
        raise

raw = sys.stdin.buffer.read(4 * 1024 * 1024 + 1)
if len(raw) > 4 * 1024 * 1024 or not raw.endswith(b"\n") or b"\x00" in raw:
    raise SystemExit(1)
lines = raw[:-1].decode("utf-8", "strict").split("\n")
header = lines[0].split("\t")
if header != ["v1", str(uid), home, str(count)]:
    raise SystemExit(1)
if lines[-1].split("\t") != ["end", str(count)] or len(lines) != count + 2:
    raise SystemExit(1)
records = []
for index, line in enumerate(lines[1:-1]):
    fields = line.split("\t")
    if len(fields) != 7 or fields[0] != expected[index]:
        raise SystemExit(1)
    relative, state, backup, old_identity, old_digest, anchor, anchor_id = fields
    parent_parts = relative.split("/")[:-1]
    valid_anchors = ["."] + ["/".join(parent_parts[:offset])
                              for offset in range(1, len(parent_parts) + 1)]
    if anchor not in valid_anchors:
        raise SystemExit(1)
    identity_parts = anchor_id.split(":")
    if (len(identity_parts) != 6 or identity_parts[2] != "d"
            or any(not value.isascii() or not value.isdigit()
                   for value in identity_parts[:2] + identity_parts[3:])):
        raise SystemExit(1)
    if state == "absent":
        if (backup, old_identity, old_digest) != ("-", "-", "-"):
            raise SystemExit(1)
    elif state == "present":
        name = relative.rsplit("/", 1)[-1]
        prefix = ".{}.claude-kit-mdm-old.".format(name)
        suffix = backup[len(prefix):] if backup.startswith(prefix) else ""
        old_parts = old_identity.split(":")
        if (len(suffix) != 32 or any(char not in "0123456789abcdef"
                                     for char in suffix)
                or len(old_parts) != 6 or old_parts[2] not in ("f", "d", "l")
                or any(not value.isascii() or not value.isdigit()
                       for value in old_parts[:2] + old_parts[3:])
                or len(old_digest) != 64
                or any(char not in "0123456789abcdef" for char in old_digest)):
            raise SystemExit(1)
    else:
        raise SystemExit(1)
    records.append(fields)

def locate(record):
    relative, _state, _backup, _old_identity, _old_digest, anchor, anchor_id = record
    parent, name, anchors = parent_for(relative)
    if anchors.get(anchor) != anchor_id:
        if parent is not None:
            os.close(parent)
        raise ValueError("external parent identity changed")
    return parent, name

def missing(parent, name):
    if parent is None:
        return True
    try:
        os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        return True
    return False

def move_no_replace(parent, source, destination):
    move_no_replace_between(parent, source, parent, destination)
    os.fsync(parent)

def move_no_replace_between(source_parent, source, destination_parent,
                            destination):
    ctypes.set_errno(0)
    if DARWIN:
        result = libc.renameatx_np(
            source_parent, os.fsencode(source), destination_parent,
            os.fsencode(destination), 4)
    else:
        result = libc.renameat2(
            source_parent, os.fsencode(source), destination_parent,
            os.fsencode(destination), 1)
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))

def backup_matches(parent, backup, expected_identity, expected_digest):
    try:
        actual_identity, actual_digest = fingerprint(parent, backup)
    except FileNotFoundError:
        return False
    return actual_identity == expected_identity and actual_digest == expected_digest

def marker_trusted(name):
    try:
        before = os.stat(name, dir_fd=carrier_fd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid()
            or before.st_nlink != 1 or stat.S_IMODE(before.st_mode) != 0o600
            or before.st_dev != os.fstat(carrier_fd).st_dev
            or before.st_size != 3):
        raise ValueError("unsafe external cleanup marker")
    descriptor = os.open(name, FILE_FLAGS, dir_fd=carrier_fd)
    try:
        opened = os.fstat(descriptor)
        linked = os.stat(name, dir_fd=carrier_fd, follow_symlinks=False)
        no_acl(descriptor)
        if (stable(opened) != stable(before) or stable(linked) != stable(before)
                or os.read(descriptor, 4) != b"v1\n"
                or os.read(descriptor, 1)):
            raise ValueError("external cleanup marker changed")
    finally:
        os.close(descriptor)
    return True

def create_marker(name):
    flags = (os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
             | getattr(os, "O_CLOEXEC", 0))
    descriptor = None
    created = None
    try:
        descriptor = os.open(name, flags, 0o600, dir_fd=carrier_fd)
        opened = os.fstat(descriptor)
        created = (opened.st_dev, opened.st_ino)
        os.fchmod(descriptor, 0o600)
        if os.write(descriptor, b"v1\n") != 3:
            raise ValueError("short external cleanup marker write")
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        os.fsync(carrier_fd)
        if not marker_trusted(name):
            raise ValueError("external cleanup marker publication failed")
    except BaseException:
        if descriptor is not None:
            os.close(descriptor)
        if created is not None:
            try:
                linked = os.stat(
                    name, dir_fd=carrier_fd, follow_symlinks=False)
                if ((linked.st_dev, linked.st_ino) == created
                        and stat.S_ISREG(linked.st_mode)
                        and linked.st_uid == os.geteuid()
                        and linked.st_nlink == 1):
                    os.unlink(name, dir_fd=carrier_fd)
                    os.fsync(carrier_fd)
            except (FileNotFoundError, OSError):
                pass
        raise

def cleanup_binding(value):
    return (value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode),
            stat.S_IMODE(value.st_mode), value.st_uid, value.st_gid,
            getattr(value, "st_flags", 0), getattr(value, "st_gen", 0))

def purge_verified(parent, name, root_dev, counter):
    before = os.stat(name, dir_fd=parent, follow_symlinks=False)
    entry_kind = safe_owned(before)
    if before.st_dev != root_dev:
        raise ValueError("external cleanup crosses a mount")
    counter[0] += 1
    if counter[0] > 100000:
        raise ValueError("external cleanup tree too large")
    if entry_kind == "d":
        descriptor = os.open(name, DIR_FLAGS, dir_fd=parent)
        try:
            opened = os.fstat(descriptor)
            linked = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if (cleanup_binding(opened) != cleanup_binding(before)
                    or cleanup_binding(linked) != cleanup_binding(before)):
                raise ValueError("external cleanup directory rebound")
            while True:
                names = sorted(os.listdir(descriptor), key=os.fsencode)
                if not names:
                    break
                for child in names:
                    if child in ("", ".", "..") or "/" in child:
                        raise ValueError("unsafe external cleanup child")
                    purge_verified(descriptor, child, root_dev, counter)
            linked = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if (os.listdir(descriptor)
                    or cleanup_binding(os.fstat(descriptor))
                        != cleanup_binding(before)
                    or cleanup_binding(linked) != cleanup_binding(before)):
                raise ValueError("external cleanup directory changed")
        finally:
            os.close(descriptor)
        os.rmdir(name, dir_fd=parent)
    else:
        descriptor = None
        try:
            if entry_kind == "f":
                descriptor = os.open(name, FILE_FLAGS, dir_fd=parent)
            elif DARWIN:
                descriptor = os.open(name, LINK_FLAGS, dir_fd=parent)
            linked = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if (stable(linked) != stable(before)
                    or (descriptor is not None
                        and stable(os.fstat(descriptor)) != stable(before))):
                raise ValueError("external cleanup leaf rebound")
        finally:
            if descriptor is not None:
                os.close(descriptor)
        os.unlink(name, dir_fd=parent)
    os.fsync(parent)

def remove_bound(parent, name, expected_identity, expected_digest, index):
    if carrier_fd is None:
        raise ValueError("external cleanup carrier unavailable")
    suffix = name.rsplit(".", 1)[-1]
    if (len(suffix) != 32
            or any(char not in "0123456789abcdef" for char in suffix)):
        raise ValueError("unsafe external cleanup backup name")
    slot = "r{:02d}-{}".format(index, suffix)
    marker = ".{}.verified".format(slot)
    source_missing = missing(parent, name)
    slot_missing = missing(carrier_fd, slot)
    verified = marker_trusted(marker)
    if not source_missing and not slot_missing:
        raise ValueError("external cleanup source and slot both exist")
    if not source_missing:
        if verified:
            raise ValueError("external cleanup marker conflicts with source")
        if os.fstat(parent).st_dev != os.fstat(carrier_fd).st_dev:
            raise ValueError("external cleanup carrier device mismatch")
        if fingerprint(parent, name) != (expected_identity, expected_digest):
            raise ValueError("external cleanup identity changed")
        move_no_replace_between(parent, name, carrier_fd, slot)
        os.fsync(parent)
        os.fsync(carrier_fd)
        source_missing = True
        slot_missing = False
    if not slot_missing and not verified:
        if fingerprint(carrier_fd, slot) != (expected_identity, expected_digest):
            raise ValueError("external cleanup slot changed")
        create_marker(marker)
        verified = True
    if not slot_missing:
        if not verified:
            raise ValueError("unverified external cleanup slot")
        purge_verified(carrier_fd, slot, os.fstat(carrier_fd).st_dev, [0])
        slot_missing = True
    if verified:
        if not missing(carrier_fd, slot):
            raise ValueError("external cleanup slot remains")
        if not marker_trusted(marker):
            raise ValueError("external cleanup marker disappeared")
        os.unlink(marker, dir_fd=carrier_fd)
        os.fsync(carrier_fd)
    elif operation != "commit_retry":
        raise ValueError("external cleanup source disappeared")

def failed_name(record, name):
    token = hashlib.sha256(
        "\0".join(record).encode("utf-8", "strict")
    ).hexdigest()[:32]
    return ".{}.claude-kit-mdm-failed.{}".format(name, token)

if carrier_fd is not None:
    allowed_carrier_entries = set()
    for record_index, record in enumerate(records):
        if record[1] != "present":
            continue
        suffix = record[2].rsplit(".", 1)[-1]
        slot = "r{:02d}-{}".format(record_index, suffix)
        allowed_carrier_entries.add(slot)
        allowed_carrier_entries.add(".{}.verified".format(slot))
    if any(name not in allowed_carrier_entries
           for name in os.listdir(carrier_fd)):
        raise SystemExit(1)

failures = 0
moves = 0
try:
    indexed_records = list(enumerate(records))
    ordered_records = (reversed(indexed_records)
                       if operation in ("abort", "abort_planned")
                       else indexed_records)
    for record_index, record in ordered_records:
        relative, state, backup, old_identity, old_digest, _anchor, _anchor_id = record
        parent = None
        name = ""
        try:
            parent, name = locate(record)
            if operation == "apply":
                if state == "absent":
                    if not missing(parent, name):
                        raise ValueError("absent external leaf appeared")
                    continue
                if parent is None or missing(parent, name) or not missing(parent, backup):
                    raise ValueError("external plan layout changed")
                if fingerprint(parent, name) != (old_identity, old_digest):
                    raise ValueError("external old leaf changed")
                move_no_replace(parent, name, backup)
                if (not missing(parent, name)
                        or not backup_matches(parent, backup,
                                              old_identity, old_digest)):
                    raise ValueError("external preserve postcondition")
                moves += 1
                if signal_after_count is not None and moves == signal_after_count:
                    signum = {"HUP": 1, "INT": 2, "TERM": 15}[signal_name]
                    os.kill(os.getppid(), signum)
                    raise SystemExit(128 + signum)
            elif operation == "prepared":
                if state == "absent":
                    if not missing(parent, name):
                        raise ValueError("prepared absent leaf appeared")
                elif (parent is None or not missing(parent, name)
                      or not backup_matches(parent, backup,
                                            old_identity, old_digest)):
                    raise ValueError("prepared external backup changed")
            elif operation == "verify":
                current_absent = parent is None or missing(parent, name)
                optional_old_cli_target = (
                    relative.startswith(
                        ".local/share/claude/versions/")
                    and relative.count("/") == 4)
                if current_absent and not optional_old_cli_target:
                    raise ValueError("managed external leaf is absent")
                if not current_absent:
                    fingerprint(parent, name)
                if state == "present" and not backup_matches(
                        parent, backup, old_identity, old_digest):
                    raise ValueError("external backup changed before commit")
            elif operation in ("abort", "abort_planned"):
                if operation == "abort_planned":
                    if state == "absent":
                        if not missing(parent, name):
                            raise ValueError(
                                "concurrent leaf appeared before apply")
                        continue
                    if parent is None:
                        raise ValueError("external parent disappeared")
                    if backup_matches(parent, backup,
                                      old_identity, old_digest):
                        if not missing(parent, name):
                            raise ValueError(
                                "concurrent leaf blocks planned rollback")
                        move_no_replace(parent, backup, name)
                        if fingerprint(parent, name) != (
                                old_identity, old_digest):
                            raise ValueError("planned old restore failed")
                        continue
                    if (not missing(parent, name)
                            and fingerprint(parent, name)
                                == (old_identity, old_digest)):
                        continue
                    raise ValueError("planned external layout is unknown")
                if state == "present":
                    if parent is None:
                        raise ValueError("external parent disappeared")
                    backup_present = backup_matches(
                        parent, backup, old_identity, old_digest)
                    if not backup_present:
                        if (not missing(parent, name)
                                and fingerprint(parent, name)
                                    == (old_identity, old_digest)):
                            continue
                        raise ValueError("external old backup unavailable")
                    failed = failed_name(record, name)
                    failed_identity = failed_digest = None
                    if not missing(parent, name):
                        if not missing(parent, failed):
                            raise ValueError(
                                "external failed quarantine is occupied")
                        failed_identity, failed_digest = fingerprint(parent, name)
                        move_no_replace(parent, name, failed)
                        if (not missing(parent, name)
                                or fingerprint(parent, failed)
                                    != (failed_identity, failed_digest)):
                            raise ValueError("cannot quarantine current external leaf")
                    try:
                        move_no_replace(parent, backup, name)
                    except BaseException:
                        raise
                    if fingerprint(parent, name) != (old_identity, old_digest):
                        raise ValueError("external old leaf restore failed")
                else:
                    if parent is None or missing(parent, name):
                        continue
                    failed = failed_name(record, name)
                    if not missing(parent, failed):
                        raise ValueError("external failed quarantine is occupied")
                    failed_identity, failed_digest = fingerprint(parent, name)
                    move_no_replace(parent, name, failed)
                    if not missing(parent, name):
                        raise ValueError("external absent restore failed")
            elif operation in ("commit", "commit_retry"):
                if state == "present":
                    remove_bound(parent, backup, old_identity, old_digest,
                                 record_index)
        except (OSError, ValueError):
            failures += 1
            if operation not in ("abort", "abort_planned", "commit",
                                 "commit_retry"):
                raise
        finally:
            if parent is not None:
                os.close(parent)
finally:
    if carrier_fd is not None:
        os.close(carrier_fd)
    os.close(home_fd)
if failures:
    raise SystemExit(1)
' "$_operation" "$_home" "$_uid" "$#" "$_carrier" \
      "$_carrier_identity" "$_apply_signal_after" "$@" < "$_journal"
  fi
}

_mdm_external_transaction_journal_seal() {
  local _path="${_MDM_EXTERNAL_TRANSACTION_JOURNAL:-}" _python _owner
  [[ -n "$_path" ]] || return 1
  _python="$(_mdm_system_python)" || return 1
  _owner="$(_mdm_auth_expected_uid)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S -c '
import os
import stat
import sys

path, owner_raw = sys.argv[1:]
owner = int(owner_raw)
flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
descriptor = os.open(path, flags)
try:
    before = os.fstat(descriptor)
    linked = os.stat(path, follow_symlinks=False)
    identity = lambda value: (
        value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
        value.st_uid, value.st_gid, value.st_size,
        value.st_mtime_ns, value.st_ctime_ns)
    if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
            or before.st_uid != owner
            or stat.S_IMODE(before.st_mode) != 0o600
            or before.st_size < 1 or before.st_size > 4 * 1024 * 1024
            or identity(linked) != identity(before)):
        raise ValueError("unsafe external transaction journal")
    remaining = before.st_size
    while remaining:
        block = os.read(descriptor, min(1024 * 1024, remaining))
        if not block:
            raise ValueError("short external transaction journal")
        remaining -= len(block)
    if os.read(descriptor, 1):
        raise ValueError("external transaction journal grew")
    if (identity(os.fstat(descriptor)) != identity(before)
            or identity(os.stat(path, follow_symlinks=False)) != identity(before)):
        raise ValueError("external transaction journal changed")
    os.fsync(descriptor)
finally:
    os.close(descriptor)
' "$_path" "$_owner" >/dev/null 2>&1
}

_mdm_external_commit_carrier_control() {
  # <select|create|verify|verify_empty|discard> <home> <carrier> <carrier-id>
  # <ancestor> <ancestor-id>.  Production selects the deepest proper home
  # ancestor whose complete chain is root-owned, ACL-free, immutable-free and
  # not group/world-writable.  The carrier therefore shares the home device,
  # but its pathname cannot be renamed by the target user.
  local _operation="$1" _home="$2" _carrier="$3" _carrier_id="$4"
  local _ancestor="$5" _ancestor_id="$6" _python _deadline
  local _owner _override="-" _test_mode="${_MDM_TEST_MODE:-0}"
  case "$_operation" in
    select|create|verify|verify_empty|discard) : ;;
    *) return 1 ;;
  esac
  [[ "$_home" == /* && "$_home" != / && ! "$_home" =~ [[:cntrl:]] ]] \
    || return 1
  _owner="$(_mdm_auth_expected_uid)" || return 1
  [[ "$_owner" =~ ^[0-9]+$ ]] || return 1
  _python="$(_mdm_system_python)" || return 1
  _deadline="$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_LOCAL_VALIDATION_SECONDS")" || return 1
  if [[ "$_test_mode" == 1 \
    && -n "${MDM_EXTERNAL_CARRIER_ANCESTOR_OVERRIDE:-}" ]]; then
    _override="$MDM_EXTERNAL_CARRIER_ANCESTOR_OVERRIDE"
  fi
  _mdm_run_with_timeout "$_deadline" /usr/bin/env -i HOME=/var/root \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S -c '
import ctypes
import errno
import hashlib
import os
import stat
import sys

(operation, home, carrier, carrier_id, ancestor, ancestor_id,
 owner_raw, test_mode, override, journal_id) = sys.argv[1:]
owner = int(owner_raw)
if operation not in ("select", "create", "verify", "verify_empty", "discard"):
    raise SystemExit(1)
if (owner != os.geteuid() or not os.path.isabs(home) or home == "/"
        or os.path.normpath(home) != home or os.path.realpath(home) != home
        or any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in home)
        or not journal_id):
    raise SystemExit(1)

DIR_FLAGS = (os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
             | getattr(os, "O_CLOEXEC", 0))
DARWIN = sys.platform == "darwin"
libc = ctypes.CDLL(None, use_errno=True)
if DARWIN:
    libc.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    libc.acl_get_fd_np.restype = ctypes.c_void_p
    libc.acl_free.argtypes = [ctypes.c_void_p]
    libc.acl_free.restype = ctypes.c_int

def identity(value):
    return "{}:{}".format(value.st_dev, value.st_ino)

def stable(value):
    return (value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode),
            stat.S_IMODE(value.st_mode), value.st_uid, value.st_gid,
            value.st_nlink, getattr(value, "st_flags", 0),
            getattr(value, "st_gen", 0))

def no_acl(descriptor):
    if DARWIN:
        ctypes.set_errno(0)
        acl = libc.acl_get_fd_np(descriptor, 0x00000100)
        if acl:
            libc.acl_free(acl)
            raise ValueError("extended ACL")
        if ctypes.get_errno() != errno.ENOENT:
            raise OSError(ctypes.get_errno() or errno.EIO, "acl_get_fd_np")
    else:
        names = os.listxattr(descriptor)
        if ("system.posix_acl_access" in names
                or "system.posix_acl_default" in names):
            raise ValueError("extended ACL")

def safe_control(value, descriptor, exact_mode=None):
    if (not stat.S_ISDIR(value.st_mode) or value.st_uid != owner
            or stat.S_IMODE(value.st_mode) & 0o022
            or getattr(value, "st_flags", 0) & 0x00060006):
        return False
    if exact_mode is not None and stat.S_IMODE(value.st_mode) != exact_mode:
        return False
    try:
        no_acl(descriptor)
    except (OSError, ValueError):
        return False
    return True

def open_bound(path):
    if (not os.path.isabs(path) or os.path.normpath(path) != path
            or os.path.realpath(path) != path):
        raise ValueError("non-canonical control path")
    current = os.open("/", DIR_FLAGS)
    try:
        for part in [value for value in path.split("/") if value]:
            before = os.stat(part, dir_fd=current, follow_symlinks=False)
            child = os.open(part, DIR_FLAGS, dir_fd=current)
            opened = os.fstat(child)
            linked = os.stat(part, dir_fd=current, follow_symlinks=False)
            if stable(before) != stable(opened) or stable(linked) != stable(opened):
                os.close(child)
                raise ValueError("control path changed")
            os.close(current)
            current = child
        return current
    except BaseException:
        os.close(current)
        raise

home_fd = open_bound(home)
home_value = os.fstat(home_fd)
if not stat.S_ISDIR(home_value.st_mode):
    raise SystemExit(1)
home_dev = home_value.st_dev
os.close(home_fd)

selected = None
if test_mode == "1" and override != "-":
    if (not os.path.isabs(override) or override == home
            or not home.startswith(override.rstrip("/") + "/")):
        raise SystemExit(1)
    descriptor = open_bound(override)
    try:
        value = os.fstat(descriptor)
        if value.st_dev != home_dev or not safe_control(value, descriptor):
            raise ValueError("unsafe test carrier ancestor")
        selected = override
    finally:
        os.close(descriptor)
elif override != "-" or test_mode not in ("0", "1"):
    raise SystemExit(1)
else:
    parts = [value for value in home.split("/") if value]
    current = os.open("/", DIR_FLAGS)
    chain_safe = True
    try:
        root_value = os.fstat(current)
        chain_safe = safe_control(root_value, current)
        if chain_safe and root_value.st_dev == home_dev:
            selected = "/"
        for index, part in enumerate(parts):
            before = os.stat(part, dir_fd=current, follow_symlinks=False)
            child = os.open(part, DIR_FLAGS, dir_fd=current)
            opened = os.fstat(child)
            linked = os.stat(part, dir_fd=current, follow_symlinks=False)
            if stable(before) != stable(opened) or stable(linked) != stable(opened):
                os.close(child)
                raise ValueError("home ancestor changed")
            os.close(current)
            current = child
            chain_safe = chain_safe and safe_control(opened, current)
            if index < len(parts) - 1 and chain_safe and opened.st_dev == home_dev:
                selected = "/" + "/".join(parts[:index + 1])
        if stable(os.fstat(current))[:2] != stable(home_value)[:2]:
            raise ValueError("home changed")
    finally:
        os.close(current)
if selected is None:
    raise SystemExit(1)

ancestor_fd = open_bound(selected)
try:
    ancestor_value = os.fstat(ancestor_fd)
    if (ancestor_value.st_dev != home_dev
            or not safe_control(ancestor_value, ancestor_fd)):
        raise ValueError("unsafe carrier ancestor")
    actual_ancestor_id = identity(ancestor_value)
    if operation == "select":
        sys.stdout.write("{}\t{}\n".format(selected, actual_ancestor_id))
        os.fsync(ancestor_fd)
        raise SystemExit(0)
    prefix = ".claude-kit-mdm-external-carrier."
    if (not carrier.startswith(selected.rstrip("/") + "/" + prefix)
            and not (selected == "/" and carrier.startswith("/" + prefix))):
        raise ValueError("carrier is outside selected ancestor")
    name = carrier.rsplit("/", 1)[-1]
    token = name[len(prefix):] if name.startswith(prefix) else ""
    if (len(token) != 32
            or any(char not in "0123456789abcdef" for char in token)
            or ancestor != selected or ancestor_id != actual_ancestor_id):
        raise ValueError("carrier authority changed")
    actual_carrier = (selected.rstrip("/") + "/" + name
                      if selected != "/" else "/" + name)
    if carrier != actual_carrier:
        raise ValueError("non-canonical carrier")
    try:
        before = os.stat(name, dir_fd=ancestor_fd, follow_symlinks=False)
    except FileNotFoundError:
        if operation == "create":
            os.mkdir(name, 0o700, dir_fd=ancestor_fd)
            os.fsync(ancestor_fd)
            before = os.stat(name, dir_fd=ancestor_fd, follow_symlinks=False)
        elif operation == "discard":
            raise SystemExit(0)
        else:
            raise
    else:
        if operation == "create":
            raise SystemExit(73)
    descriptor = os.open(name, DIR_FLAGS, dir_fd=ancestor_fd)
    try:
        if operation == "create":
            created_binding = (before.st_dev, before.st_ino,
                               stat.S_IFMT(before.st_mode), before.st_uid)
            os.fchmod(descriptor, 0o700)
            refreshed = os.stat(name, dir_fd=ancestor_fd,
                                follow_symlinks=False)
            if ((refreshed.st_dev, refreshed.st_ino,
                 stat.S_IFMT(refreshed.st_mode), refreshed.st_uid)
                    != created_binding):
                raise ValueError("external cleanup carrier changed on chmod")
            before = refreshed
        opened = os.fstat(descriptor)
        linked = os.stat(name, dir_fd=ancestor_fd, follow_symlinks=False)
        actual_carrier_id = identity(opened)
        exact_mode = (None if operation == "discard"
                      and carrier_id in ("", "-") else 0o700)
        if (stable(before) != stable(opened) or stable(linked) != stable(opened)
                or opened.st_dev != home_dev
                or not safe_control(opened, descriptor, exact_mode)):
            raise ValueError("unsafe external cleanup carrier")
        if ((operation in ("verify", "verify_empty")
             and carrier_id != actual_carrier_id)
                or (operation == "discard"
                    and carrier_id not in (actual_carrier_id, "-", ""))):
            raise ValueError("external cleanup carrier rebound")
        if operation in ("verify_empty", "discard"):
            if os.listdir(descriptor) or os.listdir(descriptor):
                raise ValueError("external cleanup carrier is not empty")
            if (stable(os.fstat(descriptor)) != stable(opened)
                    or stable(os.stat(name, dir_fd=ancestor_fd,
                                      follow_symlinks=False)) != stable(opened)):
                raise ValueError("external cleanup carrier changed")
        if operation != "discard":
            sys.stdout.write("{}\t{}\t{}\t{}\n".format(
                actual_carrier, actual_carrier_id,
                selected, actual_ancestor_id))
            os.fsync(descriptor)
    finally:
        os.close(descriptor)
    if operation == "discard":
        os.rmdir(name, dir_fd=ancestor_fd)
        os.fsync(ancestor_fd)
        try:
            os.stat(name, dir_fd=ancestor_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise ValueError("external cleanup carrier remains")
finally:
    os.close(ancestor_fd)
' "$_operation" "$_home" "$_carrier" "$_carrier_id" \
    "$_ancestor" "$_ancestor_id" "$_owner" "$_test_mode" "$_override" \
    "${_MDM_EXTERNAL_TRANSACTION_JOURNAL_IDENTITY:-}"
}

_mdm_external_commit_carrier_trusted() {
  local _actual _expected
  [[ -n "${_MDM_EXTERNAL_COMMIT_CARRIER:-}" \
    && -n "${_MDM_EXTERNAL_COMMIT_CARRIER_IDENTITY:-}" \
    && -n "${_MDM_EXTERNAL_COMMIT_ANCESTOR:-}" \
    && -n "${_MDM_EXTERNAL_COMMIT_ANCESTOR_IDENTITY:-}" ]] || return 1
  _actual="$(_mdm_external_commit_carrier_control verify \
    "$_MDM_TRANSACTION_HOME" "$_MDM_EXTERNAL_COMMIT_CARRIER" \
    "$_MDM_EXTERNAL_COMMIT_CARRIER_IDENTITY" \
    "$_MDM_EXTERNAL_COMMIT_ANCESTOR" \
    "$_MDM_EXTERNAL_COMMIT_ANCESTOR_IDENTITY")" || return 1
  _expected="$_MDM_EXTERNAL_COMMIT_CARRIER"$'\t'\
"$_MDM_EXTERNAL_COMMIT_CARRIER_IDENTITY"$'\t'\
"$_MDM_EXTERNAL_COMMIT_ANCESTOR"$'\t'\
"$_MDM_EXTERNAL_COMMIT_ANCESTOR_IDENTITY"
  [[ "$_actual" == "$_expected" ]]
}

_mdm_external_commit_carrier_empty_trusted() {
  local _actual _expected
  _mdm_external_commit_carrier_trusted || return 1
  _actual="$(_mdm_external_commit_carrier_control verify_empty \
    "$_MDM_TRANSACTION_HOME" "$_MDM_EXTERNAL_COMMIT_CARRIER" \
    "$_MDM_EXTERNAL_COMMIT_CARRIER_IDENTITY" \
    "$_MDM_EXTERNAL_COMMIT_ANCESTOR" \
    "$_MDM_EXTERNAL_COMMIT_ANCESTOR_IDENTITY")" || return 1
  _expected="$_MDM_EXTERNAL_COMMIT_CARRIER"$'\t'\
"$_MDM_EXTERNAL_COMMIT_CARRIER_IDENTITY"$'\t'\
"$_MDM_EXTERNAL_COMMIT_ANCESTOR"$'\t'\
"$_MDM_EXTERNAL_COMMIT_ANCESTOR_IDENTITY"
  [[ "$_actual" == "$_expected" ]]
}

_mdm_external_commit_carrier_prepare() {
  local _actual _carrier _carrier_id _ancestor _ancestor_id _extra
  local _python _deadline _token _rc=0 _planned_carrier
  if [[ -n "${_MDM_EXTERNAL_COMMIT_CARRIER:-}" ]]; then
    _mdm_external_commit_carrier_trusted
    return
  fi
  [[ -z "${_MDM_EXTERNAL_COMMIT_CARRIER_IDENTITY:-}" \
    && -z "${_MDM_EXTERNAL_COMMIT_ANCESTOR:-}" \
    && -z "${_MDM_EXTERNAL_COMMIT_ANCESTOR_IDENTITY:-}" ]] || return 1
  _actual="$(_mdm_external_commit_carrier_control select \
    "$_MDM_TRANSACTION_HOME" - - - -)" || return 1
  _extra=""
  IFS=$'\t' read -r _ancestor _ancestor_id _extra <<< "$_actual"
  [[ -n "$_ancestor" && -n "$_ancestor_id" && -z "$_extra" ]] || return 1
  _python="$(_mdm_system_python)" || return 1
  _deadline="$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_LOCAL_VALIDATION_SECONDS")" || return 1
  _token="$(_mdm_run_with_timeout "$_deadline" /usr/bin/env -i \
    HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S -c \
      'import os, sys; sys.stdout.write(os.urandom(16).hex())')" || return 1
  [[ "$_token" =~ ^[0-9a-f]{32}$ ]] || return 1
  _MDM_EXTERNAL_COMMIT_ANCESTOR="$_ancestor"
  _MDM_EXTERNAL_COMMIT_ANCESTOR_IDENTITY="$_ancestor_id"
  if [[ "$_ancestor" == / ]]; then
    _MDM_EXTERNAL_COMMIT_CARRIER="/.claude-kit-mdm-external-carrier.$_token"
  else
    _MDM_EXTERNAL_COMMIT_CARRIER="$_ancestor/.claude-kit-mdm-external-carrier.$_token"
  fi
  _planned_carrier="$_MDM_EXTERNAL_COMMIT_CARRIER"
  _actual="$(_mdm_external_commit_carrier_control create \
    "$_MDM_TRANSACTION_HOME" "$_MDM_EXTERNAL_COMMIT_CARRIER" - \
    "$_MDM_EXTERNAL_COMMIT_ANCESTOR" \
    "$_MDM_EXTERNAL_COMMIT_ANCESTOR_IDENTITY")" || _rc=$?
  if [[ "$_rc" -eq 73 ]]; then
    _MDM_EXTERNAL_COMMIT_CARRIER=""
    _MDM_EXTERNAL_COMMIT_ANCESTOR=""
    _MDM_EXTERNAL_COMMIT_ANCESTOR_IDENTITY=""
    return 1
  fi
  if [[ "$_rc" -ne 0 ]]; then
    _mdm_external_commit_carrier_discard || true
    return 1
  fi
  _extra=""
  IFS=$'\t' read -r _carrier _carrier_id _ancestor _ancestor_id _extra \
    <<< "$_actual"
  [[ "$_carrier" == "$_planned_carrier" \
    && "$_ancestor" == "$_MDM_EXTERNAL_COMMIT_ANCESTOR" \
    && "$_ancestor_id" == "$_MDM_EXTERNAL_COMMIT_ANCESTOR_IDENTITY" \
    && -n "$_carrier_id" && -z "$_extra" ]] || {
    _mdm_external_commit_carrier_discard || true
    return 1
  }
  _MDM_EXTERNAL_COMMIT_CARRIER_IDENTITY="$_carrier_id"
  _mdm_external_commit_carrier_trusted
}

_mdm_external_commit_carrier_discard() {
  [[ -n "${_MDM_EXTERNAL_COMMIT_CARRIER:-}" ]] || return 0
  _mdm_external_commit_carrier_control discard \
    "$_MDM_TRANSACTION_HOME" "$_MDM_EXTERNAL_COMMIT_CARRIER" \
    "$_MDM_EXTERNAL_COMMIT_CARRIER_IDENTITY" \
    "$_MDM_EXTERNAL_COMMIT_ANCESTOR" \
    "$_MDM_EXTERNAL_COMMIT_ANCESTOR_IDENTITY" >/dev/null || return 1
  _MDM_EXTERNAL_COMMIT_CARRIER=""
  _MDM_EXTERNAL_COMMIT_CARRIER_IDENTITY=""
  _MDM_EXTERNAL_COMMIT_ANCESTOR=""
  _MDM_EXTERNAL_COMMIT_ANCESTOR_IDENTITY=""
}

_mdm_external_inventory_discard() {
  local _path="${_MDM_EXTERNAL_INVENTORY_TMP:-}" _base
  [[ -n "$_path" ]] || return 0
  _base="$(_mdm_auth_tmp_base)" || return 1
  _mdm_auth_base_trusted "$_base" || return 1
  case "$_path" in
    "$_base"/claude-kit-mdm-external-paths.*) : ;;
    *) return 1 ;;
  esac
  [[ -f "$_path" && ! -L "$_path" \
    && "$(_mdm_stat_uid "$_path" 2>/dev/null || true)" \
      == "$(_mdm_auth_expected_uid)" ]] || return 1
  if [[ -n "${_MDM_EXTERNAL_INVENTORY_TMP_IDENTITY:-}" ]]; then
    [[ "$(_mdm_external_transaction_journal_inode_identity \
      "$_path" 2>/dev/null || true)" \
      == "$_MDM_EXTERNAL_INVENTORY_TMP_IDENTITY" ]] || return 1
  fi
  /bin/rm -f "$_path" || return 1
  _MDM_EXTERNAL_INVENTORY_TMP=""
  _MDM_EXTERNAL_INVENTORY_TMP_IDENTITY=""
}

_mdm_external_transaction_collect_paths() { # <home> <uid>
  local _home="$1" _uid="$2" _path _base _old_umask _seen _candidate
  MDM_EXTERNAL_TRANSACTION_PATHS=()
  [[ -z "${_MDM_EXTERNAL_INVENTORY_TMP:-}" \
    && -z "${_MDM_EXTERNAL_INVENTORY_TMP_IDENTITY:-}" ]] || return 1
  _base="$(_mdm_auth_tmp_base)" || return 1
  _mdm_auth_base_trusted "$_base" || return 1
  _old_umask="$(umask)"; umask 077
  _MDM_EXTERNAL_INVENTORY_TMP="$(/usr/bin/mktemp \
    "$_base/claude-kit-mdm-external-paths.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  _MDM_EXTERNAL_INVENTORY_TMP_IDENTITY="$(
    _mdm_external_transaction_journal_inode_identity \
      "$_MDM_EXTERNAL_INVENTORY_TMP"
  )" || {
    [[ -f "$_MDM_EXTERNAL_INVENTORY_TMP" \
      && ! -L "$_MDM_EXTERNAL_INVENTORY_TMP" ]] \
      && /bin/rm -f "$_MDM_EXTERNAL_INVENTORY_TMP"
    _MDM_EXTERNAL_INVENTORY_TMP=""
    return 1
  }
  /bin/chmod 0600 "$_MDM_EXTERNAL_INVENTORY_TMP" \
    || { _mdm_external_inventory_discard || true; return 1; }
  if ! _mdm_external_transaction_paths "$_home" "$_uid" \
      > "$_MDM_EXTERNAL_INVENTORY_TMP"; then
    _mdm_external_inventory_discard || true
    return 1
  fi
  while IFS= read -r _path || [[ -n "$_path" ]]; do
    if [[ -z "$_path" ]]; then
      _mdm_external_inventory_discard || true
      return 1
    fi
    [[ "$_path" != /* && ! "$_path" =~ [[:cntrl:]] \
      && "$_path" != *\\* ]] || {
        _mdm_external_inventory_discard || true
        return 1
      }
    _seen=false
    for _candidate in \
      "${MDM_EXTERNAL_TRANSACTION_PATHS[@]+"${MDM_EXTERNAL_TRANSACTION_PATHS[@]}"}"; do
      [[ "$_candidate" != "$_path" ]] || _seen=true
    done
    if [[ "$_seen" != false \
      || "${#MDM_EXTERNAL_TRANSACTION_PATHS[@]}" -ge 32 ]]; then
      _mdm_external_inventory_discard || true
      return 1
    fi
    MDM_EXTERNAL_TRANSACTION_PATHS[${#MDM_EXTERNAL_TRANSACTION_PATHS[@]}]="$_path"
  done < "$_MDM_EXTERNAL_INVENTORY_TMP"
  _mdm_external_inventory_discard
}

_mdm_external_transaction_prepare() { # <user> <home> <uid>
  local _user="$1" _home="$2" _uid="$3" _base _old_umask _rc=0
  [[ "${_MDM_TRANSACTION_STATE:-idle}" == active \
    && "${_MDM_EXTERNAL_TRANSACTION_STATE:-idle}" == idle \
    && -z "${_MDM_EXTERNAL_TRANSACTION_JOURNAL:-}" \
    && -z "${_MDM_EXTERNAL_TRANSACTION_JOURNAL_IDENTITY:-}" \
    && "$_user" == "${_MDM_TRANSACTION_USER:-}" \
    && "$_home" == "${_MDM_TRANSACTION_HOME:-}" \
    && "$_uid" == "${_MDM_TRANSACTION_UID:-}" ]] || return 1
  _mdm_external_transaction_collect_paths "$_home" "$_uid" || return 1
  if [[ "${#MDM_EXTERNAL_TRANSACTION_PATHS[@]}" -eq 0 ]]; then
    _MDM_EXTERNAL_TRANSACTION_STATE=none
    return 0
  fi
  _base="$(_mdm_auth_tmp_base)" || return 1
  _mdm_auth_base_trusted "$_base" || return 1
  _MDM_EXTERNAL_TRANSACTION_STATE=planning
  _mdm_arm_transient_cleanup
  _old_umask="$(umask)"; umask 077
  _MDM_EXTERNAL_TRANSACTION_JOURNAL="$(/usr/bin/mktemp \
    "$_base/claude-kit-mdm-external.XXXXXX")" \
    || { umask "$_old_umask"; _MDM_EXTERNAL_TRANSACTION_STATE=idle; return 1; }
  umask "$_old_umask"
  _MDM_EXTERNAL_TRANSACTION_JOURNAL_IDENTITY="$(
    _mdm_external_transaction_journal_inode_identity \
      "$_MDM_EXTERNAL_TRANSACTION_JOURNAL"
  )" || {
    _mdm_external_transaction_journal_discard_unsealed || true
    _MDM_EXTERNAL_TRANSACTION_STATE=idle
    return 1
  }
  /bin/chmod 0600 "$_MDM_EXTERNAL_TRANSACTION_JOURNAL" || {
    _mdm_external_transaction_journal_discard_unsealed || true
    _MDM_EXTERNAL_TRANSACTION_STATE=idle
    return 1
  }
  _mdm_external_transaction_invoke plan "$_user" "$_home" "$_uid" "" \
    "${MDM_EXTERNAL_TRANSACTION_PATHS[@]}" \
    > "$_MDM_EXTERNAL_TRANSACTION_JOURNAL" || _rc=$?
  /bin/chmod 0600 "$_MDM_EXTERNAL_TRANSACTION_JOURNAL" || _rc=1
  if [[ "$_rc" -ne 0 \
    || -z "$_MDM_EXTERNAL_TRANSACTION_JOURNAL_IDENTITY" ]] \
    || ! _mdm_external_transaction_journal_seal \
    || ! _mdm_external_transaction_journal_metadata_trusted; then
    _mdm_external_transaction_journal_discard_unsealed || true
    _MDM_EXTERNAL_TRANSACTION_STATE=idle
    return 1
  fi
  _MDM_EXTERNAL_TRANSACTION_STATE=planned
  if ! _mdm_external_commit_carrier_prepare; then
    _mdm_external_transaction_abort || true
    return 1
  fi
  # From this point the durable journal authorizes rollback even when the
  # helper exits immediately after any individual atomic rename.
  _rc=0
  _mdm_external_transaction_invoke apply "$_user" "$_home" "$_uid" \
    "$_MDM_EXTERNAL_TRANSACTION_JOURNAL" \
    "${MDM_EXTERNAL_TRANSACTION_PATHS[@]}" || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    _mdm_external_transaction_abort || true
    return 1
  fi
  _MDM_EXTERNAL_TRANSACTION_STATE=prepared
  if ! _mdm_external_transaction_invoke prepared "$_user" "$_home" "$_uid" \
      "$_MDM_EXTERNAL_TRANSACTION_JOURNAL" \
      "${MDM_EXTERNAL_TRANSACTION_PATHS[@]}"; then
    _mdm_external_transaction_abort || true
    return 1
  fi
}

_mdm_external_transaction_abort() {
  local _state="${_MDM_EXTERNAL_TRANSACTION_STATE:-idle}" _rc=0 _operation=abort
  case "$_state" in
    idle|none|aborted|committed) return 0 ;;
    planning)
      _mdm_external_transaction_journal_discard_unsealed || return 1
      _MDM_EXTERNAL_TRANSACTION_STATE=aborted
      return 0 ;;
    planned|prepared|partial) : ;;
    *) return 1 ;;
  esac
  [[ "${#MDM_EXTERNAL_TRANSACTION_PATHS[@]}" -ge 1 ]] || return 1
  [[ "$_state" != planned ]] || _operation=abort_planned
  trap '' HUP INT TERM
  _mdm_external_transaction_invoke "$_operation" "$_MDM_TRANSACTION_USER" \
    "$_MDM_TRANSACTION_HOME" "$_MDM_TRANSACTION_UID" \
    "$_MDM_EXTERNAL_TRANSACTION_JOURNAL" \
    "${MDM_EXTERNAL_TRANSACTION_PATHS[@]}" || _rc=$?
  if [[ "$_rc" -eq 0 ]]; then
    _mdm_external_commit_carrier_discard || _rc=1
  fi
  if [[ "$_rc" -eq 0 ]]; then
    _mdm_external_transaction_journal_discard || _rc=1
  fi
  if [[ "$_rc" -eq 0 ]]; then
    _MDM_EXTERNAL_TRANSACTION_STATE=aborted
    MDM_EXTERNAL_TRANSACTION_PATHS=()
    return 0
  fi
  _MDM_EXTERNAL_TRANSACTION_STATE=partial
  return 1
}

_mdm_external_transaction_ready() {
  case "${_MDM_EXTERNAL_TRANSACTION_STATE:-idle}" in
    none) return 0 ;;
    prepared) : ;;
    *) return 1 ;;
  esac
  [[ "${#MDM_EXTERNAL_TRANSACTION_PATHS[@]}" -ge 1 ]] || return 1
  _mdm_external_transaction_journal_metadata_trusted \
    && _mdm_external_commit_carrier_empty_trusted \
    && _mdm_external_transaction_invoke verify "$_MDM_TRANSACTION_USER" \
      "$_MDM_TRANSACTION_HOME" "$_MDM_TRANSACTION_UID" \
      "$_MDM_EXTERNAL_TRANSACTION_JOURNAL" \
      "${MDM_EXTERNAL_TRANSACTION_PATHS[@]}"
}

_mdm_external_transaction_commit() {
  local _rc=0 _operation=commit _state
  _state="${_MDM_EXTERNAL_TRANSACTION_STATE:-idle}"
  case "$_state" in
    committed) return 0 ;;
    none) _MDM_EXTERNAL_TRANSACTION_STATE=committed; return 0 ;;
    prepared|cleanup|carrier_cleanup|journal_cleanup) : ;;
    *) return 1 ;;
  esac
  [[ "${#MDM_EXTERNAL_TRANSACTION_PATHS[@]}" -ge 1 ]] || return 1
  trap '' HUP INT TERM
  if [[ "$_state" == prepared || "$_state" == cleanup ]]; then
    [[ "$_state" != cleanup ]] || _operation=commit_retry
    _mdm_external_transaction_invoke "$_operation" "$_MDM_TRANSACTION_USER" \
      "$_MDM_TRANSACTION_HOME" "$_MDM_TRANSACTION_UID" \
      "$_MDM_EXTERNAL_TRANSACTION_JOURNAL" \
      "${MDM_EXTERNAL_TRANSACTION_PATHS[@]}" || _rc=$?
    if [[ "$_rc" -eq 0 ]]; then
      _MDM_EXTERNAL_TRANSACTION_STATE=carrier_cleanup
    else
      _MDM_EXTERNAL_TRANSACTION_STATE=cleanup
      return 1
    fi
  fi
  if [[ "${_MDM_EXTERNAL_TRANSACTION_STATE:-}" == carrier_cleanup ]]; then
    if _mdm_external_commit_carrier_discard; then
      _MDM_EXTERNAL_TRANSACTION_STATE=journal_cleanup
    else
      return 1
    fi
  fi
  if [[ "${_MDM_EXTERNAL_TRANSACTION_STATE:-}" == journal_cleanup ]] \
    && _mdm_external_transaction_journal_discard; then
    _MDM_EXTERNAL_TRANSACTION_STATE=committed
    MDM_EXTERNAL_TRANSACTION_PATHS=()
    return 0
  fi
  return 1
}

_mdm_transaction_begin() { # <user> <home> <uid> <generated-uid>
  local _user="$1" _home="$2" _uid="$3" _generated="$4" _dir _old_umask
  [[ "${_MDM_TRANSACTION_STATE:-idle}" == idle \
    && "${_MDM_FAILURE_ROLLBACK_ACTIVE:-0}" == 0 \
    && "${_MDM_FAILURE_ROLLBACK_FRESH_PRIVATE:-0}" == 0 \
    && "${_MDM_PARENT_MODE_STATE:-idle}" == idle \
    && "${_MDM_EXTERNAL_TRANSACTION_STATE:-idle}" == idle \
    && -z "${_MDM_PARENT_MODE_JOURNAL:-}" \
    && -z "${_MDM_PARENT_MODE_JOURNAL_IDENTITY:-}" \
    && -z "${_MDM_EXTERNAL_TRANSACTION_JOURNAL:-}" \
    && -z "${_MDM_EXTERNAL_TRANSACTION_JOURNAL_IDENTITY:-}" \
    && -z "${_MDM_EXTERNAL_COMMIT_CARRIER:-}" \
    && -z "${_MDM_EXTERNAL_COMMIT_CARRIER_IDENTITY:-}" \
    && -z "${_MDM_EXTERNAL_COMMIT_ANCESTOR:-}" \
    && -z "${_MDM_EXTERNAL_COMMIT_ANCESTOR_IDENTITY:-}" \
    && "$_uid" =~ ^[0-9]+$ && "$_uid" -ge 501 ]] || return 1
  _generated="$(_mdm_normalize_generated_uid "$_generated")" || return 1
  _dir="$(_mdm_receipt_dir_for "$_home")"
  if [[ "${_MDM_TEST_MODE:-0}" != 1 \
    || -z "${MDM_SYSTEM_RCPT_DIR_OVERRIDE:-}" ]]; then
    _mdm_verify_dir_chain "$_dir" "/Library/Application Support" || return 1
  fi
  if [[ ! -d "$_dir" ]]; then
    [[ ! -e "$_dir" && ! -L "$_dir" ]] || return 1
    _old_umask="$(umask)"; umask 022
    /bin/mkdir -p "$_dir" || { umask "$_old_umask"; return 1; }
    umask "$_old_umask"
  fi
  /bin/chmod 755 "$_dir" || return 1
  _mdm_component_receipt_dir_is_trusted "$_dir" || return 1
  _MDM_TRANSACTION_HISTORY_PATH="$_dir/managed-history-$_generated.json"
  _MDM_TRANSACTION_COMPONENT_PATH="$_dir/components-$_generated.json"
  _MDM_TRANSACTION_HISTORY_STATE="untouched"
  _MDM_TRANSACTION_HISTORY_SNAPSHOT=""
  _MDM_TRANSACTION_COMPONENT_STATE="untouched"
  _MDM_TRANSACTION_COMPONENT_SNAPSHOT=""
  _MDM_TRANSACTION_USER="$_user"
  _MDM_TRANSACTION_HOME="$_home"
  _MDM_TRANSACTION_UID="$_uid"
  _MDM_TRANSACTION_GENERATED_UID="$_generated"
  _MDM_TRANSACTION_STATE="active"
  _mdm_arm_transient_cleanup
  _mdm_transaction_snapshot_root_file "$_MDM_TRANSACTION_HISTORY_PATH" \
    history _MDM_TRANSACTION_HISTORY_STATE \
    _MDM_TRANSACTION_HISTORY_SNAPSHOT \
    || { _mdm_transaction_abort || true; return 1; }
  if ! _mdm_transaction_snapshot_root_file \
    "$_MDM_TRANSACTION_COMPONENT_PATH" manifest \
    _MDM_TRANSACTION_COMPONENT_STATE _MDM_TRANSACTION_COMPONENT_SNAPSHOT; then
    _mdm_transaction_abort || true
    return 1
  fi
}

_mdm_transaction_prepare_claude() { # <home> <uid>
  local _home="$1" _uid="$2" _live _backup _parent_identity
  local _candidate_identity _previous_identity="" _previous_digest="" _mode
  local _copy_source_before _copy_candidate _copy_source_after
  local _source_before_digests _source_after_digests
  local _marker _live_digest _MDM_EXEC_AS_USER_DEADLINE_SECONDS
  _live="$_home/.claude"
  [[ "${_MDM_TRANSACTION_STATE:-idle}" == active \
    && "${_MDM_CLAUDE_TRANSACTION_STATE:-idle}" == idle \
    && "$_home" == "$_MDM_TRANSACTION_HOME" \
    && "$_uid" == "$_MDM_TRANSACTION_UID" ]] || return 1
  _MDM_EXEC_AS_USER_DEADLINE_SECONDS="$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_SETUP_SECONDS")" || return 1
  [[ -d "$_home" && ! -L "$_home" \
    && "$(_mdm_canonical_dir "$_home")" == "$_home" \
    && "$(_mdm_stat_uid "$_home")" == "$_uid" ]] || return 1
  _parent_identity="$(_mdm_persistent_dir_identity "$_home")" || return 1
  trap '' HUP INT TERM
  if ! _backup="$(_mdm_transaction_allocate_claude_candidate \
      "$_home" "$_uid")"; then
    _mdm_arm_transient_cleanup
    return 1
  fi
  _MDM_CLAUDE_LIVE="$_live"
  _MDM_CLAUDE_BACKUP="$_backup"
  _MDM_CLAUDE_TARGET_UID="$_uid"
  _MDM_CLAUDE_PARENT_IDENTITY="$_parent_identity"
  _MDM_CLAUDE_CANDIDATE_IDENTITY=""
  _MDM_CLAUDE_TRANSACTION_STATE="allocated"
  _mdm_arm_transient_cleanup
  _candidate_identity="$(_mdm_persistent_dir_identity "$_backup")" \
    || { _mdm_transaction_abort_claude || true; return 1; }
  [[ "$(_mdm_stat_uid "$_backup")" == "$_uid" ]] \
    || { _mdm_transaction_abort_claude || true; return 1; }
  _MDM_CLAUDE_CANDIDATE_IDENTITY="$_candidate_identity"
  _marker="claude-code-starter-kit-mdm-transaction-v1:${_backup##*/}"
  _MDM_CLAUDE_MARKER_VALUE="$_marker"
  _MDM_CLAUDE_TRANSACTION_STATE="prepared"
  _mdm_arm_transient_cleanup

  if [[ -e "$_live" || -L "$_live" ]]; then
    [[ -d "$_live" && ! -L "$_live" \
      && "$(_mdm_canonical_dir "$_live")" == "$_live" \
      && "$(_mdm_stat_uid "$_live")" == "$_uid" ]] || return 1
    _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_live")")" || return 1
    _mdm_mode_is_safe "$_mode" || return 1
    _mdm_has_extended_acl "$_live" && return 1
    _previous_identity="$(_mdm_persistent_dir_identity "$_live")" || return 1
    _source_before_digests="$(
      _mdm_artifact_copy_semantics_digests "$_live"
    )" \
      || { _mdm_transaction_abort_claude || true; return 1; }
    [[ "$_source_before_digests" \
      =~ ^[0-9a-f]{64}:[0-9a-f]{64}$ ]] \
      || { _mdm_transaction_abort_claude || true; return 1; }
    _previous_digest="${_source_before_digests%%:*}"
    _copy_source_before="${_source_before_digests#*:}"
    _mdm_run_maybe_as_user /bin/cp -a "$_live/." "$_backup/" \
      || { _mdm_transaction_abort_claude || true; return 1; }
    _mdm_run_maybe_as_user /bin/chmod "$_mode" "$_backup" \
      || { _mdm_transaction_abort_claude || true; return 1; }
    [[ "$(_mdm_persistent_dir_identity "$_backup")" == "$_candidate_identity" ]] \
      || { _mdm_transaction_abort_claude || true; return 1; }
    _copy_candidate="$(_mdm_copy_semantics_digest "$_backup")" \
      || { _mdm_transaction_abort_claude || true; return 1; }
    _source_after_digests="$(
      _mdm_artifact_copy_semantics_digests "$_live"
    )" \
      || { _mdm_transaction_abort_claude || true; return 1; }
    [[ "$_source_after_digests" \
      =~ ^[0-9a-f]{64}:[0-9a-f]{64}$ ]] \
      || { _mdm_transaction_abort_claude || true; return 1; }
    _live_digest="${_source_after_digests%%:*}"
    _copy_source_after="${_source_after_digests#*:}"
    [[ "$_copy_source_before" == "$_copy_candidate" \
      && "$_copy_source_after" == "$_copy_source_before" ]] \
      || { _mdm_transaction_abort_claude || true; return 1; }
    _mdm_create_claude_transaction_marker "$_backup" "$_uid" "$_marker" \
      || return 1
    [[ "$_live_digest" == "$_previous_digest" \
      && "$(_mdm_persistent_dir_identity "$_live")" == "$_previous_identity" ]] \
      || return 1
    _MDM_CLAUDE_PREVIOUS_IDENTITY="$_previous_identity"
    _MDM_CLAUDE_PREVIOUS_DIGEST="$_previous_digest"
    trap '' HUP INT TERM
    if ! _mdm_atomic_user_dir_operation "$_home" "${_backup##*/}" .claude \
      swap "$_uid" "$_parent_identity" "$_candidate_identity" \
      "$_previous_identity"; then
      _mdm_arm_transient_cleanup
      return 1
    fi
    _MDM_CLAUDE_TRANSACTION_STATE="swapped"
    _mdm_arm_transient_cleanup
    [[ "$(_mdm_persistent_dir_identity "$_live")" == "$_candidate_identity" \
      && "$(_mdm_persistent_dir_identity "$_backup")" == "$_previous_identity" \
      && "$(_mdm_artifact_digest tree "$_backup")" == "$_previous_digest" ]] \
      && _mdm_claude_transaction_marker_trusted \
        "$_live" "$_uid" "$_marker" \
      || { _mdm_transaction_abort_claude || true; return 1; }
  else
    _mdm_create_claude_transaction_marker "$_backup" "$_uid" "$_marker" \
      || return 1
    trap '' HUP INT TERM
    if ! _mdm_atomic_user_dir_operation "$_home" "${_backup##*/}" .claude \
      create "$_uid" "$_parent_identity" "$_candidate_identity" absent; then
      _mdm_arm_transient_cleanup
      return 1
    fi
    _MDM_CLAUDE_TRANSACTION_STATE="created"
    _mdm_arm_transient_cleanup
    [[ "$(_mdm_persistent_dir_identity "$_live")" == "$_candidate_identity" ]] \
      && _mdm_claude_transaction_marker_trusted \
        "$_live" "$_uid" "$_marker" \
      || { _mdm_transaction_abort_claude || true; return 1; }
  fi
}

_mdm_transaction_abort_claude() {
  local _state="${_MDM_CLAUDE_TRANSACTION_STATE:-idle}"
  local _live="${_MDM_CLAUDE_LIVE:-}" _backup="${_MDM_CLAUDE_BACKUP:-}"
  local _uid="${_MDM_CLAUDE_TARGET_UID:-}" _parent_identity
  local _candidate_identity _previous_identity _previous_digest _failed
  case "$_state" in idle|aborted|committed) return 0 ;; esac
  _parent_identity="$_MDM_CLAUDE_PARENT_IDENTITY"
  _candidate_identity="$_MDM_CLAUDE_CANDIDATE_IDENTITY"
  _previous_identity="$_MDM_CLAUDE_PREVIOUS_IDENTITY"
  _previous_digest="$_MDM_CLAUDE_PREVIOUS_DIGEST"
  _failed="$(_mdm_transaction_failed_path "$_backup" \
    .mdm-backup. .mdm-failed.)" || return 1
  case "$_state" in
    allocated)
      case "$_backup" in
        "${_MDM_TRANSACTION_HOME:-}"/.claude.mdm-backup.*) : ;;
        *) return 1 ;;
      esac
      _mdm_run_maybe_as_user /bin/rmdir "$_backup" 2>/dev/null || return 1
      [[ ! -e "$_backup" && ! -L "$_backup" ]] || return 1
      _failed="" ;;
    prepared)
      [[ "$(_mdm_persistent_dir_identity "$_backup" 2>/dev/null || true)" \
        == "$_candidate_identity" ]] || return 1
      _mdm_transaction_preserve_failed_dir "$_backup" "$_failed" "$_uid" \
        "$_parent_identity" "$_candidate_identity" _failed || return 1 ;;
    swapped)
      [[ "$(_mdm_persistent_dir_identity "$_live" 2>/dev/null || true)" \
          == "$_candidate_identity" \
        && "$(_mdm_persistent_dir_identity "$_backup" 2>/dev/null || true)" \
          == "$_previous_identity" \
        && "$(_mdm_artifact_digest tree "$_backup" 2>/dev/null || true)" \
          == "$_previous_digest" ]] || return 1
      _mdm_atomic_user_dir_operation "${_live%/*}" "${_backup##*/}" \
        "${_live##*/}" swap "$_uid" "$_parent_identity" \
        "$_previous_identity" "$_candidate_identity" || return 1
      [[ "$(_mdm_persistent_dir_identity "$_live" 2>/dev/null || true)" \
        == "$_previous_identity" ]] || return 1
      _mdm_transaction_preserve_failed_dir "$_backup" "$_failed" "$_uid" \
        "$_parent_identity" "$_candidate_identity" _failed || return 1 ;;
    created)
      [[ "$(_mdm_persistent_dir_identity "$_live" 2>/dev/null || true)" \
        == "$_candidate_identity" ]] || return 1
      _mdm_transaction_preserve_failed_dir "$_live" "$_failed" "$_uid" \
        "$_parent_identity" "$_candidate_identity" _failed || return 1
      [[ ! -e "$_live" && ! -L "$_live" ]] || return 1 ;;
    *) return 1 ;;
  esac
  _MDM_CLAUDE_FAILED="$_failed"
  _MDM_CLAUDE_TRANSACTION_STATE="aborted"
}

_mdm_transaction_abort_persistent() {
  local _state="${_MDM_PERSISTENT_TRANSACTION_STATE:-idle}"
  local _install="${_MDM_PERSISTENT_INSTALL_DIR:-}"
  local _stage="${_MDM_PERSISTENT_STAGE:-}" _failed _uid _parent_identity
  local _candidate_identity _candidate_digest _previous_identity _previous_digest
  case "$_state" in idle|aborted|committed) return 0 ;; esac
  _uid="$_MDM_PERSISTENT_TARGET_UID"
  _parent_identity="$_MDM_PERSISTENT_PARENT_IDENTITY"
  _candidate_identity="$_MDM_PERSISTENT_CANDIDATE_IDENTITY"
  _candidate_digest="$_MDM_PERSISTENT_CANDIDATE_DIGEST"
  _previous_identity="$_MDM_PERSISTENT_PREVIOUS_IDENTITY"
  _previous_digest="$_MDM_PERSISTENT_PREVIOUS_DIGEST"
  _failed="$(_mdm_transaction_failed_path "$_stage" \
    .mdm-stage. .mdm-failed.)" || return 1
  case "$_state" in
    allocated)
      _mdm_cleanup_persistent_stage || return 1
      _failed="" ;;
    prepared)
      [[ "$(_mdm_persistent_dir_identity "$_stage" 2>/dev/null || true)" \
        == "$_candidate_identity" ]] || return 1
      _mdm_transaction_preserve_failed_dir "$_stage" "$_failed" "$_uid" \
        "$_parent_identity" "$_candidate_identity" _failed || return 1 ;;
    swapped)
      [[ "$(_mdm_persistent_dir_identity "$_install" 2>/dev/null || true)" \
          == "$_candidate_identity" \
        && "$(_mdm_persistent_dir_identity "$_stage" 2>/dev/null || true)" \
          == "$_previous_identity" \
        && "$(_mdm_artifact_digest tree "$_install" "$_uid" \
          2>/dev/null || true)" == "$_candidate_digest" \
        && "$(_mdm_artifact_digest tree "$_stage" "$_uid" \
          2>/dev/null || true)" == "$_previous_digest" ]] || return 1
      _mdm_atomic_user_dir_operation "${_install%/*}" "${_stage##*/}" \
        "${_install##*/}" swap "$_uid" "$_parent_identity" \
        "$_previous_identity" "$_candidate_identity" || return 1
      _mdm_transaction_preserve_failed_dir "$_stage" "$_failed" "$_uid" \
        "$_parent_identity" "$_candidate_identity" _failed || return 1 ;;
    created)
      [[ "$(_mdm_persistent_dir_identity "$_install" 2>/dev/null || true)" \
          == "$_candidate_identity" \
        && "$(_mdm_artifact_digest tree "$_install" "$_uid" \
          2>/dev/null || true)" == "$_candidate_digest" ]] || return 1
      _mdm_transaction_preserve_failed_dir "$_install" "$_failed" "$_uid" \
        "$_parent_identity" "$_candidate_identity" _failed || return 1 ;;
    *) return 1 ;;
  esac
  _MDM_PERSISTENT_STAGE=""
  _MDM_PERSISTENT_STAGE_IDENTITY=""
  _MDM_PERSISTENT_TRANSACTION_STATE="aborted"
}

_mdm_transaction_mark_partial() {
  case "${MDM_RCPT_PARTIAL:-[]}" in
    *'"rollback"'*) : ;;
    '[]') MDM_RCPT_PARTIAL='["rollback"]' ;;
    *']') MDM_RCPT_PARTIAL="${MDM_RCPT_PARTIAL%]},\"rollback\"]" ;;
    *) MDM_RCPT_PARTIAL='["rollback"]' ;;
  esac
}

_mdm_transaction_abort() {
  local _rc=0
  case "${_MDM_TRANSACTION_STATE:-idle}" in
    idle|aborted|committing|commit_cleanup|committed) return 0 ;;
  esac
  trap '' HUP INT TERM
  _mdm_external_transaction_abort || _rc=1
  _mdm_transaction_abort_claude || _rc=1
  _mdm_managed_parent_modes_restore || _rc=1
  _mdm_transaction_abort_persistent || _rc=1
  _mdm_transaction_restore_root_file "$_MDM_TRANSACTION_COMPONENT_PATH" \
    "$_MDM_TRANSACTION_COMPONENT_STATE" \
    "$_MDM_TRANSACTION_COMPONENT_SNAPSHOT" || _rc=1
  _mdm_transaction_restore_root_file "$_MDM_TRANSACTION_HISTORY_PATH" \
    "$_MDM_TRANSACTION_HISTORY_STATE" \
    "$_MDM_TRANSACTION_HISTORY_SNAPSHOT" || _rc=1
  if [[ "$_rc" -eq 0 ]]; then
    _mdm_transaction_cleanup_root_snapshots || _rc=1
  fi
  if [[ "$_rc" -eq 0 ]]; then
    _MDM_TRANSACTION_STATE="aborted"
    return 0
  fi
  _MDM_TRANSACTION_STATE="partial"
  _mdm_transaction_mark_partial
  mdm_log R4 "transaction rollback が不完全。回復用pathを保持"
  return 1
}

_mdm_transaction_ready_to_commit() {
  local _home="${_MDM_TRANSACTION_HOME:-}" _uid="${_MDM_TRANSACTION_UID:-}"
  local _live="${_MDM_CLAUDE_LIVE:-}" _backup="${_MDM_CLAUDE_BACKUP:-}"
  local _install="${_MDM_PERSISTENT_INSTALL_DIR:-}"
  local _stage="${_MDM_PERSISTENT_STAGE:-}" _state
  [[ "${_MDM_TRANSACTION_STATE:-idle}" == active \
    && "$_home" == /* && "$_uid" =~ ^[0-9]+$ \
    && "$(_mdm_persistent_dir_identity "$_home" 2>/dev/null || true)" \
      == "${_MDM_CLAUDE_PARENT_IDENTITY:-}" \
    && "$(_mdm_stat_uid "$_home" 2>/dev/null || true)" == "$_uid" ]] \
    || return 1
  [[ "${_MDM_PARENT_MODE_STATE:-idle}" == applied ]] || return 1
  _mdm_managed_parent_journal_trusted || return 1
  _mdm_external_transaction_ready || return 1

  _state="${_MDM_CLAUDE_TRANSACTION_STATE:-idle}"
  [[ "$(_mdm_persistent_dir_identity "$_live" 2>/dev/null || true)" \
      == "${_MDM_CLAUDE_CANDIDATE_IDENTITY:-}" \
    && "$(_mdm_stat_uid "$_live" 2>/dev/null || true)" == "$_uid" ]] \
    || return 1
  _mdm_claude_transaction_marker_trusted "$_live" "$_uid" \
    "${_MDM_CLAUDE_MARKER_VALUE:-}" || return 1
  case "$_state" in
    swapped)
      [[ "$(_mdm_persistent_dir_identity "$_backup" 2>/dev/null || true)" \
          == "${_MDM_CLAUDE_PREVIOUS_IDENTITY:-}" \
        && "$(_mdm_artifact_digest tree "$_backup" 2>/dev/null || true)" \
          == "${_MDM_CLAUDE_PREVIOUS_DIGEST:-}" ]] || return 1
      _mdm_claude_backup_marker_trusted "$_live" "$_uid" "$_backup" \
        || return 1 ;;
    created)
      [[ ! -e "$_backup" && ! -L "$_backup" \
        && ! -e "$_live/.starter-kit-last-backup" \
        && ! -L "$_live/.starter-kit-last-backup" ]] || return 1 ;;
    *) return 1 ;;
  esac

  [[ "$(_mdm_persistent_dir_identity "${_install%/*}" \
      2>/dev/null || true)" == "${_MDM_PERSISTENT_PARENT_IDENTITY:-}" ]] \
    || return 1
  case "${_MDM_PERSISTENT_TRANSACTION_STATE:-idle}" in
    swapped)
      [[ "$(_mdm_persistent_dir_identity "$_install" 2>/dev/null || true)" \
          == "${_MDM_PERSISTENT_CANDIDATE_IDENTITY:-}" \
        && "$(_mdm_artifact_digest tree "$_install" "$_uid" \
          2>/dev/null || true)" == "${_MDM_PERSISTENT_CANDIDATE_DIGEST:-}" \
        && "$(_mdm_persistent_dir_identity "$_stage" 2>/dev/null || true)" \
          == "${_MDM_PERSISTENT_PREVIOUS_IDENTITY:-}" \
        && "$(_mdm_artifact_digest tree "$_stage" "$_uid" \
          2>/dev/null || true)" == "${_MDM_PERSISTENT_PREVIOUS_DIGEST:-}" ]] \
        || return 1 ;;
    created)
      [[ "$(_mdm_persistent_dir_identity "$_install" 2>/dev/null || true)" \
          == "${_MDM_PERSISTENT_CANDIDATE_IDENTITY:-}" \
        && "$(_mdm_artifact_digest tree "$_install" "$_uid" \
          2>/dev/null || true)" == "${_MDM_PERSISTENT_CANDIDATE_DIGEST:-}" \
        && ! -e "$_stage" && ! -L "$_stage" ]] || return 1 ;;
    *) return 1 ;;
  esac
  case "${_MDM_TRANSACTION_HISTORY_STATE:-untouched}" in
    absent) : ;;
    present) [[ -f "${_MDM_TRANSACTION_HISTORY_SNAPSHOT:-}" \
      && ! -L "${_MDM_TRANSACTION_HISTORY_SNAPSHOT:-}" ]] || return 1 ;;
    *) return 1 ;;
  esac
  case "${_MDM_TRANSACTION_COMPONENT_STATE:-untouched}" in
    absent) : ;;
    present) [[ -f "${_MDM_TRANSACTION_COMPONENT_SNAPSHOT:-}" \
      && ! -L "${_MDM_TRANSACTION_COMPONENT_SNAPSHOT:-}" ]] || return 1 ;;
    *) return 1 ;;
  esac
  _mdm_managed_parent_journal_trusted || return 1
  _mdm_managed_parent_modes_final "$_home" "$_uid"
}

_mdm_transaction_commit() {
  local _rc=0 _marker _claude_state
  case "${_MDM_TRANSACTION_STATE:-idle}" in
    committed) return 0 ;;
    active|committing|commit_cleanup) : ;;
    *) return 1 ;;
  esac
  _MDM_TRANSACTION_STATE="committing"
  _claude_state="${_MDM_CLAUDE_TRANSACTION_STATE:-idle}"
  _mdm_external_transaction_commit || _rc=1
  case "${_MDM_PERSISTENT_TRANSACTION_STATE:-idle}" in
    committed) : ;;
    swapped)
      if _mdm_cleanup_persistent_stage; then
        _MDM_PERSISTENT_TRANSACTION_STATE="committed"
      else
        _rc=1
      fi ;;
    created)
      _MDM_PERSISTENT_STAGE=""
      _MDM_PERSISTENT_STAGE_IDENTITY=""
      _MDM_PERSISTENT_TRANSACTION_STATE="committed" ;;
    *) _rc=1 ;;
  esac
  _mdm_managed_parent_modes_commit || _rc=1
  _marker="$(_mdm_claude_transaction_marker_path \
    "${_MDM_CLAUDE_LIVE:-/nonexistent}")"
  case "$_claude_state" in
    committed) : ;;
    swapped|created)
      if [[ -n "${_MDM_CLAUDE_LIVE:-}" ]] \
        && ! _mdm_run_maybe_as_user /bin/rm -f "$_marker" 2>/dev/null; then
        _rc=1
      elif [[ "$_claude_state" == swapped ]] \
        && ! _mdm_transaction_rotate_claude_backups \
          "$_MDM_TRANSACTION_HOME" "$_MDM_CLAUDE_BACKUP"; then
        _rc=1
      else
        _MDM_CLAUDE_TRANSACTION_STATE="committed"
      fi ;;
    *) _rc=1 ;;
  esac
  _mdm_transaction_cleanup_root_snapshots || _rc=1
  if [[ "$_rc" -eq 0 ]]; then
    _MDM_TRANSACTION_STATE="committed"
    return 0
  fi
  _MDM_TRANSACTION_STATE="commit_cleanup"
  mdm_log R4 "commit後 cleanup を完了できず回復用pathを保持"
  return "$_rc"
}

_mdm_normalize_persistent_worktree() { # <stage> <target-uid>
  local _stage="$1" _target_uid="$2" _python
  [[ "$_stage" == /* && ! "$_stage" =~ [[:cntrl:]] \
    && "$_target_uid" =~ ^[0-9]+$ ]] || return 1
  _python="$(_mdm_target_system_python)" || return 1
  # mktemp and Git inherit the wrapper's umask 077.  Preserve Git's executable
  # class while making the retained worktree canonical (directories 0755,
  # regular files 0644/0755).  Run the fd-bound walk as the target user: the
  # user-owned parent is never traversed with root write authority.
  _mdm_run_maybe_as_user "$_python" -I -B -S -c '
import os
import stat
import sys

root = os.fsencode(sys.argv[1])
expected_uid = int(sys.argv[2])
marker = b".claude-starter-kit-mdm-managed"
dir_flags = (os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
             | getattr(os, "O_CLOEXEC", 0))
file_flags = (os.O_RDONLY | os.O_NOFOLLOW
              | getattr(os, "O_CLOEXEC", 0))
entries = 0

def stable(value):
    return (value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode),
            value.st_uid, value.st_gid, value.st_nlink, value.st_size)

def visit(descriptor, root_dev, depth):
    global entries
    if depth > 256:
        raise ValueError("retained worktree is too deep")
    before = os.fstat(descriptor)
    if (not stat.S_ISDIR(before.st_mode) or before.st_dev != root_dev
            or before.st_uid != expected_uid):
        raise ValueError("unsafe retained directory")
    os.fchmod(descriptor, 0o755)
    names = sorted(os.fsencode(name) for name in os.listdir(descriptor))
    for name in names:
        if name in (b"", b".", b"..") or b"/" in name:
            raise ValueError("invalid retained worktree name")
        if depth == 0 and name in (b".git", marker):
            continue
        entries += 1
        if entries > 100000:
            raise ValueError("retained worktree is too large")
        value = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if value.st_dev != root_dev or value.st_uid != expected_uid:
            raise ValueError("unsafe retained worktree entry")
        if stat.S_ISDIR(value.st_mode):
            child = os.open(name, dir_flags, dir_fd=descriptor)
            try:
                if stable(os.fstat(child)) != stable(value):
                    raise ValueError("retained directory changed")
                visit(child, root_dev, depth + 1)
                after = os.fstat(child)
                if stable(after) != stable(value):
                    raise ValueError("retained directory changed")
            finally:
                os.close(child)
        elif stat.S_ISREG(value.st_mode):
            if value.st_nlink != 1:
                raise ValueError("hard-linked retained file")
            child = os.open(name, file_flags, dir_fd=descriptor)
            try:
                if stable(os.fstat(child)) != stable(value):
                    raise ValueError("retained file changed")
                mode = 0o755 if stat.S_IMODE(value.st_mode) & 0o111 else 0o644
                os.fchmod(child, mode)
                after = os.fstat(child)
                if stable(after) != stable(value):
                    raise ValueError("retained file changed")
            finally:
                os.close(child)
        elif stat.S_ISLNK(value.st_mode):
            if value.st_nlink != 1:
                raise ValueError("hard-linked retained symlink")
        else:
            raise ValueError("special retained worktree entry")
    if sorted(os.fsencode(name) for name in os.listdir(descriptor)) != names:
        raise ValueError("retained directory entries changed")

descriptor = os.open(root, dir_flags)
try:
    root_before = os.fstat(descriptor)
    if root_before.st_uid != expected_uid:
        raise ValueError("retained root owner mismatch")
    visit(descriptor, root_before.st_dev, 0)
    root_after = os.fstat(descriptor)
    if stable(root_after) != stable(root_before):
        raise ValueError("retained root changed")
finally:
    os.close(descriptor)
' "$_stage" "$_target_uid"
}

_mdm_rebuild_persistent_checkout() { # <install-dir> <repo-url> <full-sha> <target-uid>
  local _install_dir="$1" _repo_url="$2" _sha="$3" _target_uid="$4"
  local _parent _stage _stage_name _fetched _head _status _mode _existing=false
  local _install_identity="" _stage_identity _current_install _current_stage
  local _parent_identity _candidate_digest="" _previous_digest=""
  local _transactional=false
  [[ "$_sha" =~ ^[0-9a-f]{40}$ && "$_target_uid" =~ ^[0-9]+$ ]] || return 1
  _parent="$(/usr/bin/dirname "$_install_dir")"
  _mdm_run_maybe_as_user /bin/mkdir -p "$_parent" 2>/dev/null || return 1
  _parent_identity="$(_mdm_persistent_dir_identity "$_parent")" || return 1
  [[ "${_MDM_TRANSACTION_STATE:-idle}" == active ]] && _transactional=true

  if [[ -e "$_install_dir" || -L "$_install_dir" ]]; then
    [[ -d "$_install_dir" && ! -L "$_install_dir" ]] || return 1
    _install_identity="$(_mdm_persistent_dir_identity "$_install_dir" || true)"
    _mdm_persistent_checkout_matches_identity \
      "$_install_dir" "$_target_uid" "$_install_identity" || return 1
    if [[ "$_transactional" == true ]]; then
      _previous_digest="$(_mdm_artifact_digest tree \
        "$_install_dir" "$_target_uid")" || return 1
    fi
    _existing=true
  fi

  trap '' HUP INT TERM
  if ! _stage="$(_mdm_run_maybe_as_user /usr/bin/mktemp -d \
      "$_parent/.claude-starter-kit.mdm-stage.XXXXXX" 2>/dev/null)"; then
    _mdm_arm_transient_cleanup
    return 1
  fi
  _stage_name="${_stage##*/}"
  case "$_stage" in
    "$_parent"/.claude-starter-kit.mdm-stage.*) : ;;
    *) _mdm_arm_transient_cleanup
       return 1 ;;
  esac
  case "$_stage_name" in
    .claude-starter-kit.mdm-stage.*) : ;;
    *) _mdm_arm_transient_cleanup
       return 1 ;;
  esac
  _MDM_PERSISTENT_STAGE="$_stage"
  _MDM_PERSISTENT_STAGE_IDENTITY=""
  _MDM_PERSISTENT_INSTALL_DIR="$_install_dir"
  _MDM_PERSISTENT_TARGET_UID="$_target_uid"
  _MDM_PERSISTENT_PARENT_IDENTITY="$_parent_identity"
  if [[ "$_transactional" == true ]]; then
    _MDM_PERSISTENT_TRANSACTION_STATE="allocated"
  fi
  _mdm_arm_transient_cleanup
  _stage_identity="$(_mdm_persistent_dir_identity "$_stage" || true)"
  case "$_stage_identity" in
    *:Directory|*:directory) : ;;
    *)
      if [[ "$_transactional" == true ]]; then
        _mdm_transaction_abort_persistent || true
      else
        _mdm_cleanup_persistent_stage || true
      fi
      return 1 ;;
  esac
  _MDM_PERSISTENT_STAGE_IDENTITY="$_stage_identity"
  [[ -d "$_stage" && ! -L "$_stage" \
    && "$(_mdm_canonical_dir "$_stage" || true)" == "$_stage" \
    && "$(_mdm_stat_uid "$_stage" || true)" == "$_target_uid" ]] \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_stage" || true)" || true)"
  [[ "$_mode" == 0700 ]] \
    || { _mdm_cleanup_persistent_stage || true; return 1; }

  _mdm_git_network -c core.hooksPath=/dev/null clone --quiet --no-checkout --no-local \
    "$_repo_url" "$_stage" 2>/dev/null \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  _mdm_git_network -C "$_stage" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    fetch --quiet "$_repo_url" "$_sha" 2>/dev/null \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  _fetched="$(_mdm_git -C "$_stage" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null || true)"
  [[ "$_fetched" == "$_sha" ]] \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  _mdm_git -C "$_stage" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    checkout --quiet --force --detach "$_sha" 2>/dev/null \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  _head="$(_mdm_git -C "$_stage" rev-parse --verify HEAD 2>/dev/null || true)"
  [[ "$_head" == "$_sha" ]] \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  _mdm_normalize_persistent_worktree "$_stage" "$_target_uid" \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  _status="$(_mdm_git -C "$_stage" status --porcelain --untracked-files=all 2>/dev/null)" \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  [[ -z "$_status" ]] \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  _mdm_create_persistent_marker "$_stage" "$_target_uid" \
    || { _mdm_cleanup_persistent_stage || true; return 1; }
  _mdm_persistent_checkout_matches_identity \
    "$_stage" "$_target_uid" "$_stage_identity" \
    && _mdm_detached_head_matches "$_stage" "$_sha" "$_target_uid" \
    || { _mdm_cleanup_persistent_stage || true; return 1; }

  if [[ "$_transactional" == true ]]; then
    _candidate_digest="$(_mdm_artifact_digest tree \
      "$_stage" "$_target_uid")" \
      || { _mdm_cleanup_persistent_stage || true; return 1; }
    _MDM_PERSISTENT_INSTALL_DIR="$_install_dir"
    _MDM_PERSISTENT_TARGET_UID="$_target_uid"
    _MDM_PERSISTENT_PARENT_IDENTITY="$_parent_identity"
    _MDM_PERSISTENT_CANDIDATE_IDENTITY="$_stage_identity"
    _MDM_PERSISTENT_CANDIDATE_DIGEST="$_candidate_digest"
    _MDM_PERSISTENT_PREVIOUS_IDENTITY="$_install_identity"
    _MDM_PERSISTENT_PREVIOUS_DIGEST="$_previous_digest"
    _MDM_PERSISTENT_TRANSACTION_STATE="prepared"
    _mdm_arm_transient_cleanup
  fi

  if [[ "$_existing" == true ]]; then
    # Bind the destination again after the long clone/fetch window. This does
    # not claim to defeat continuous hostile mutation, but prevents a stale
    # preflight result from authorizing deletion of a replacement directory.
    _mdm_persistent_checkout_matches_identity \
      "$_install_dir" "$_target_uid" "$_install_identity" \
      || {
        if [[ "$_transactional" == true ]]; then
          _mdm_transaction_abort_persistent || true
        else
          _mdm_cleanup_persistent_stage || true
        fi
        return 1
      }
    [[ "$_transactional" == true ]] && trap '' HUP INT TERM
    if ! _mdm_promote_persistent_stage "$_stage" "$_install_dir" swap \
      "$_stage_identity" "$_install_identity" "$_target_uid" \
      "$_parent_identity"; then
      [[ "$_transactional" == true ]] && _mdm_arm_transient_cleanup
      if [[ "$_transactional" == true ]]; then
        _mdm_transaction_abort_persistent || true
      else
        _mdm_cleanup_persistent_stage || true
      fi
      return 1
    fi
    if [[ "$_transactional" == true ]]; then
      _MDM_PERSISTENT_TRANSACTION_STATE="swapped"
      _mdm_arm_transient_cleanup
    fi
    _current_stage="$(_mdm_persistent_dir_identity "$_stage" || true)"
    _current_install="$(_mdm_persistent_dir_identity "$_install_dir" || true)"
    if [[ "$_current_stage" != "$_install_identity" \
      || "$_current_install" != "$_stage_identity" ]]; then
      if [[ "$_transactional" == true ]]; then
        _mdm_transaction_abort_persistent || return 1
      else
        _mdm_restore_previous_persistent_checkout \
          "$_stage" "$_install_dir" "$_target_uid" \
          "$_stage_identity" "$_install_identity" || return 1
      fi
      return 1
    fi
    _MDM_PERSISTENT_STAGE_IDENTITY="$_install_identity"
    if ! _mdm_persistent_checkout_matches_identity \
        "$_install_dir" "$_target_uid" "$_stage_identity" \
      || ! _mdm_detached_head_matches \
        "$_install_dir" "$_sha" "$_target_uid"; then
      if [[ "$_transactional" == true ]]; then
        _mdm_transaction_abort_persistent || return 1
      else
        _mdm_restore_previous_persistent_checkout \
          "$_stage" "$_install_dir" "$_target_uid" \
          "$_stage_identity" "$_install_identity" || return 1
      fi
      return 1
    fi
    if [[ "$_transactional" != true ]]; then
      # Legacy/source-only calls without an outer transaction keep their
      # historical immediate cleanup behavior.
      _mdm_cleanup_persistent_stage || return 1
    fi
  else
    [[ "$_transactional" == true ]] && trap '' HUP INT TERM
    if ! _mdm_promote_persistent_stage "$_stage" "$_install_dir" create \
      "$_stage_identity" absent "$_target_uid" "$_parent_identity"; then
      [[ "$_transactional" == true ]] && _mdm_arm_transient_cleanup
      if [[ "$_transactional" == true ]]; then
        _mdm_transaction_abort_persistent || true
      else
        _mdm_cleanup_persistent_stage || true
      fi
      return 1
    fi
    if [[ "$_transactional" == true ]]; then
      _MDM_PERSISTENT_TRANSACTION_STATE="created"
      _mdm_arm_transient_cleanup
    fi
    if ! _mdm_persistent_checkout_matches_identity \
        "$_install_dir" "$_target_uid" "$_stage_identity" \
      || ! _mdm_detached_head_matches \
        "$_install_dir" "$_sha" "$_target_uid"; then
      if [[ "$_transactional" == true ]]; then
        _mdm_transaction_abort_persistent || return 1
      else
        _mdm_retract_initial_persistent_checkout \
          "$_stage" "$_install_dir" "$_stage_identity" || return 1
      fi
      return 1
    fi
    if [[ "$_transactional" != true ]]; then
      _MDM_PERSISTENT_STAGE=""
      _MDM_PERSISTENT_STAGE_IDENTITY=""
    fi
  fi
  return 0
}

_mdm_run_root_user_phase() { # <user> <home> <bound-target-uid>
  local _user="$1" _home="$2" _uid="$3" _ref _dry_run _install_dir _repo_url _cli_required
  local _persistent_identity="" _post_kit_digest=""
  local _auth_worktree_digest="" _retained_worktree_digest=""
  local _wce_required=false _component
  local _setup_rc=0
  # UID >= 501 と local/search-policy 一致は main の identity binding 済み。
  [[ "$_uid" =~ ^[0-9]+$ ]] \
    || { mdm_log U1b "束縛済み対象ユーザー UID が不正"; return 1; }
  _ref="${KIT_MDM_GIT_REF:-main}"
  _dry_run="$(_mdm_root_bool "${KIT_MDM_DRY_RUN:-false}" 2>/dev/null || echo false)"
  if ! _mdm_root_ref_allowed "$_ref" "$_dry_run"; then
    mdm_log U1b "production remediation の KIT_MDM_GIT_REF は full SHA 必須"
    return "$MDM_EXIT_CONFIG"
  fi
  if ! _mdm_expected_policy_input_valid; then
    mdm_log U1b "production execution の expected policy SHA-256 は必須"
    return "$MDM_EXIT_CONFIG"
  fi
  _install_dir="$_home/.claude-starter-kit"
  if [[ "$_dry_run" != "true" && -n "${KIT_MDM_INSTALL_DIR:-}" \
    && "$KIT_MDM_INSTALL_DIR" != "$_install_dir" ]]; then
    mdm_log U1b "KIT_MDM_INSTALL_DIR は専用パス $_install_dir のみ許可"
    return "$MDM_EXIT_CONFIG"
  fi
  if [[ "$_dry_run" != "true" ]]; then
    if [[ -L "$_install_dir" || ( -e "$_install_dir" && ! -d "$_install_dir" ) ]]; then
      mdm_log U1b "管理 checkout パスの実体が不正"
      return "$MDM_EXIT_CONFIG"
    fi
    if [[ -d "$_install_dir" ]] \
      && [[ "$(_mdm_canonical_dir "$_install_dir")" != "$_install_dir" ]]; then
      mdm_log U1b "管理 checkout パスが canonical でない"
      return "$MDM_EXIT_CONFIG"
    fi
    if [[ -d "$_install_dir" ]] && ! _mdm_persistent_marker_trusted "$_install_dir" "$_uid"; then
      mdm_log U1b "管理 marker の無い既存 checkout は削除しない"
      return "$MDM_EXIT_CONFIG"
    fi
  fi

  MDM_RCPT_GIT_REF="$_ref"
  MDM_RCPT_INSTALL_DIR="$_install_dir"
  _MDM_GIT_SAFE_DIRECTORY=""
  _MDM_WCE_VERIFIED_BUNDLE=""
  _MDM_WCE_CARRIER_ACTIVE=false
  _MDM_EXPECTED_WCE_COMPONENT_SHA256=""
  _MDM_GIT_DROP_UID=""
  _MDM_GIT_DROP_USER=""
  _MDM_GIT_DROP_HOME=""
  _mdm_prepare_authoritative_checkout "$_ref" "$_uid" || return $?
  _repo_url="$(_mdm_repo_url)"
  _mdm_capture_prior_inventory \
    "$_user" "$_home" "$_uid" "$_MDM_TARGET_GENERATED_UID" || return 1
  _mdm_prepare_expected_state \
    "$_home" "$_MDM_AUTH_CHECKOUT" "$MDM_RCPT_RESOLVED_SHA" || return $?
  _mdm_load_expected_required_components || return 1
  if [[ "$_dry_run" != true \
    && "${_MDM_TRANSACTION_STATE:-idle}" == active ]]; then
    mdm_log U1b "管理対象 parent directory の mode を transactionally 正規化"
    _mdm_managed_parent_modes_prepare "$_user" "$_home" "$_uid" || return 1
    mdm_log U1b "対象ユーザーの外部管理 leaf を transactionally 退避"
    _mdm_external_transaction_prepare "$_user" "$_home" "$_uid" || return 1
  fi
  for _component in "${MDM_REQUIRED_COMPONENTS[@]}"; do
    if [[ "$_component" == web_content_runtime ]]; then
      _wce_required=true
      break
    fi
  done
  if [[ "${KIT_MDM_REQUIRE_NODE_RUNTIME:-false}" == true ]]; then
    if [[ "$_dry_run" == true ]]; then
      _mdm_node_runtime_trusted "$(_mdm_node_runtime_path)" \
        && _mdm_node_runtime_activation_valid "$_user" "$_home" "$_uid" \
        || return "$MDM_EXIT_PREREQ"
    else
      mdm_log U1b "固定 Node.js private runtime を準備"
      _mdm_ensure_node_runtime "$_user" "$_home" "$_uid" \
        || return "$MDM_EXIT_PREREQ"
    fi
  fi
  if [[ "$_wce_required" == true ]]; then
    if [[ "$_dry_run" == true ]]; then
      _mdm_wce_runtime_validate_dryrun "$_user" "$_home" "$_uid" \
        || return "$MDM_EXIT_PREREQ"
    else
      mdm_log U1b "固定 web-content-extraction private runtime を準備"
      _mdm_ensure_wce_runtime "$_user" "$_home" "$_uid" \
        || return "$MDM_EXIT_PREREQ"
    fi
    [[ "${_MDM_WCE_VERIFIED_BUNDLE:-}" == "$(_mdm_wce_runtime_path)" \
      && "${_MDM_EXPECTED_WCE_COMPONENT_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] \
      || return "$MDM_EXIT_PREREQ"
  fi
  _auth_worktree_digest="$(_mdm_worktree_content_digest \
    "$_MDM_AUTH_CHECKOUT" authority)" || return 1

  # The target-user-owned checkout is a persistence artifact.  It is rebuilt
  # fresh at the resolved SHA and is never root-remediation execution authority;
  # later same-user interactive update workflows may use their own checkout.
  if [[ "$_dry_run" != "true" ]]; then
    _MDM_GIT_DROP_UID="$_uid"
    _MDM_GIT_DROP_USER="$_user"
    _MDM_GIT_DROP_HOME="$_home"
    mdm_log U1b "保持用 checkout を固定 SHA で再構築"
    _mdm_rebuild_persistent_checkout \
      "$_install_dir" "$_repo_url" "$MDM_RCPT_RESOLVED_SHA" "$_uid" || return 1
    _persistent_identity="$(_mdm_persistent_dir_identity "$_install_dir" || true)"
    _mdm_persistent_checkout_matches_identity \
      "$_install_dir" "$_uid" "$_persistent_identity" || return 1
    _retained_worktree_digest="$(_mdm_worktree_content_digest \
      "$_install_dir" retained)" || return 1
    [[ "$_retained_worktree_digest" == "$_auth_worktree_digest" ]] || return 1
    # Freeze the entire retained checkout (including .git and the managed
    # marker) before setup can mutate user state.  Clean/full-SHA checks on
    # both sides prevent a one-time pre-attestation replacement from becoming
    # its own trusted baseline.
    _mdm_persistent_worktree_clean "$_install_dir" || return 1
    _mdm_detached_head_matches \
      "$_install_dir" "$MDM_RCPT_RESOLVED_SHA" "$_uid" || return 1
    _retained_worktree_digest="$(_mdm_worktree_content_digest \
      "$_install_dir" retained)" || return 1
    [[ "$_retained_worktree_digest" == "$_auth_worktree_digest" ]] || return 1
    _MDM_EXPECTED_KIT_COMPONENT_SHA256="$(_mdm_artifact_digest tree "$_install_dir" "$_uid")" \
      || return 1
    [[ "$_MDM_EXPECTED_KIT_COMPONENT_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
    _mdm_persistent_worktree_clean "$_install_dir" || return 1
    _mdm_detached_head_matches \
      "$_install_dir" "$MDM_RCPT_RESOLVED_SHA" "$_uid" || return 1
  fi

  _cli_required="true"
  if [[ -n "${KIT_MDM_INSTALL_CLAUDE_CLI:-}" ]]; then
    _cli_required="$(_mdm_root_bool "$KIT_MDM_INSTALL_CLAUDE_CLI" 2>/dev/null || echo true)"
  fi
  if [[ "$_dry_run" != true \
    && "${_MDM_TRANSACTION_STATE:-idle}" == active ]]; then
    mdm_log U2 "outer transaction 用の ~/.claude candidate を準備"
    _mdm_transaction_prepare_claude "$_home" "$_uid" || return 1
    _MDM_OUTER_TRANSACTION_ACTIVE=true
    if [[ "${_MDM_CLAUDE_TRANSACTION_STATE:-idle}" == swapped ]]; then
      _MDM_OUTER_TRANSACTION_BACKUP="$_MDM_CLAUDE_BACKUP"
    else
      _MDM_OUTER_TRANSACTION_BACKUP=""
    fi
  fi
  mdm_build_setup_argv "$_home"
  mdm_log U2 "authoritative setup.sh を対象ユーザーで実行: ${MDM_SETUP_ARGV[*]}"
  _MDM_GIT_SAFE_DIRECTORY="$_MDM_AUTH_CHECKOUT"
  if [[ "$_wce_required" == true ]]; then
    _MDM_WCE_RUNTIME_DIGEST=""
    _mdm_wce_runtime_trusted "$_MDM_WCE_VERIFIED_BUNDLE" \
      && [[ "$_MDM_WCE_RUNTIME_DIGEST" \
        == "$_MDM_EXPECTED_WCE_COMPONENT_SHA256" ]] || return 1
    _MDM_WCE_CARRIER_ACTIVE=true
  fi
  _mdm_exec_setup_as_user "$_uid" "$_user" "$_home" \
    /bin/bash "$_MDM_AUTH_CHECKOUT/setup.sh" "${MDM_SETUP_ARGV[@]}" || _setup_rc=$?
  _MDM_WCE_CARRIER_ACTIVE=false
  _MDM_OUTER_TRANSACTION_ACTIVE=false
  _MDM_OUTER_TRANSACTION_BACKUP=""
  if [[ "$_setup_rc" -ne 0 ]]; then
    _MDM_GIT_SAFE_DIRECTORY=""
    mdm_log U2 "setup.sh の実行に失敗 (exit=$_setup_rc)"
    [[ "$_setup_rc" -eq "$MDM_EXIT_PREREQ" ]] && return "$MDM_EXIT_PREREQ"
    return 1
  fi
  _MDM_GIT_SAFE_DIRECTORY=""

  if [[ "$_wce_required" == true ]]; then
    if [[ "$_dry_run" == true ]]; then
      _mdm_wce_runtime_validate_dryrun "$_user" "$_home" "$_uid" \
        || return 1
    else
      _MDM_WCE_RUNTIME_DIGEST=""
      _mdm_wce_runtime_trusted "$_MDM_WCE_VERIFIED_BUNDLE" \
        && [[ "$_MDM_WCE_RUNTIME_DIGEST" \
          == "$_MDM_EXPECTED_WCE_COMPONENT_SHA256" ]] \
        && _mdm_wce_runtime_activation_valid \
          "$_user" "$_home" "$_uid" "$_MDM_WCE_VERIFIED_BUNDLE" \
        || return 1
    fi
  fi

  # No post-setup Git process is allowed against either checkout.
  _mdm_auth_tree_trusted "$_MDM_AUTH_CHECKOUT" || return 1
  _mdm_detached_head_matches "$_MDM_AUTH_CHECKOUT" "$MDM_RCPT_RESOLVED_SHA" \
    "$(_mdm_auth_expected_uid)" || return 1
  [[ "$(_mdm_worktree_content_digest "$_MDM_AUTH_CHECKOUT" authority)" \
    == "$_auth_worktree_digest" ]] || return 1
  if [[ "$_dry_run" != "true" ]]; then
    _mdm_persistent_checkout_matches_identity \
      "$_install_dir" "$_uid" "$_persistent_identity" || return 1
    _mdm_detached_head_matches \
      "$_install_dir" "$MDM_RCPT_RESOLVED_SHA" "$_uid" || return 1
    _retained_worktree_digest="$(_mdm_worktree_content_digest \
      "$_install_dir" retained)" || return 1
    [[ "$_retained_worktree_digest" == "$_auth_worktree_digest" ]] || return 1
    _post_kit_digest="$(_mdm_artifact_digest tree "$_install_dir" "$_uid")" || return 1
    [[ "$_post_kit_digest" == "$_MDM_EXPECTED_KIT_COMPONENT_SHA256" ]] || return 1
    _retained_worktree_digest="$(_mdm_worktree_content_digest \
      "$_install_dir" retained)" || return 1
    [[ "$_retained_worktree_digest" == "$_auth_worktree_digest" ]] || return 1
    _mdm_persistent_checkout_matches_identity \
      "$_install_dir" "$_uid" "$_persistent_identity" || return 1
  fi
  _mdm_cleanup_auth_entry_list || return 1
  _mdm_cleanup_auth_checkout || return 1

  if [[ "$_cli_required" == "true" && "$_dry_run" != "true" ]]; then
    mdm_log U3 "Claude Code CLI 導入を確認"
    if ! _mdm_cli_present_for_home "$_home"; then
      MDM_RCPT_PARTIAL='["claude_cli"]'
      return "$MDM_EXIT_CLI"
    fi
  fi
  return 0
}

# U1b→U2→U3: キット取得+refピン留め → setup.sh --non-interactive 実行 →
# Claude Code CLI 導入確認。
# root 実行時は clone を含む全 git 操作を初回から検証済み対象ユーザーへ
# env -i 降格して行う。root が対象ユーザー所有 repo を直接
# 操作すると .git/config 経由の root コード実行境界になるため、「root で
# clone してから所有権を対象ユーザーへ再帰変更する」旧方式は廃止
# （ユーザー実行の clone なら所有権は最初から正しい）。
# 戻り値: 0=成功 / MDM_EXIT_PREREQ=setup前提不足 /
#         MDM_EXIT_CLI=CLIのみ欠如（部分失敗）/
#         MDM_EXIT_CONFIG=install_dir 制約違反 / 1=それ以外の失敗
_mdm_run_user_phase() {
  local _euid="$1" _user="$2" _home="$3" _target_uid="${4:-}"
  # MDM 管理マーカー（非 root 経路は env 継承で setup.sh へ届く。root 経路は
  # mdm_build_drop_argv が固定要素として注入する）
  export KIT_MDM_MANAGED=true
  local _ref="${KIT_MDM_GIT_REF:-main}"
  local _dry_run="false"
  _dry_run="$(_mdm_root_bool "${KIT_MDM_DRY_RUN:-false}" 2>/dev/null || echo false)"

  if [[ "$_euid" -eq 0 ]]; then
    _mdm_run_root_user_phase "$_user" "$_home" "$_target_uid"
    return $?
  fi
  if [[ "$_dry_run" != "true" ]]; then
    mdm_log R2 "通常の MDM remediation は root 実行が必須"
    return "$MDM_EXIT_CONTEXT"
  fi
  if ! _mdm_expected_policy_input_valid; then
    mdm_log U1b "production preview の expected policy SHA-256 は必須"
    return "$MDM_EXIT_CONFIG"
  fi
  _MDM_GIT_DROP_UID=""
  _MDM_GIT_DROP_USER=""
  _MDM_GIT_DROP_HOME=""
  _MDM_GIT_SAFE_DIRECTORY=""

  # Root returned through the authoritative path above.  The remaining path is
  # the explicitly allowed non-root preview and never writes a receipt.
  local _uid="$_euid" _setup_rc=0 _dryrun_base="" _dryrun_physical_base=""

  local _install_dir="${KIT_MDM_INSTALL_DIR:-}"
  if [[ "$_dry_run" == "true" ]]; then
    if ! _dryrun_base="$(_mdm_test_runner_tmp_base 2>/dev/null)"; then
      if [[ "$_euid" -eq 0 ]]; then
        _dryrun_base=/private/tmp
      else
        _dryrun_base=/tmp
      fi
    fi
    _dryrun_physical_base="$(builtin cd -P -- "$_dryrun_base" 2>/dev/null \
      && printf '%s' "$PWD")" || {
      mdm_log U1b "dry-run 一時領域を canonical 化できない"
      return 1
    }
    [[ -n "$_dryrun_physical_base" && "$_dryrun_physical_base" != / ]] || return 1
    if [[ "$_euid" -eq 0 ]]; then
      _install_dir="$(_mdm_exec_as_user "$_uid" "$_user" "$_home" \
        /usr/bin/mktemp -d "$_dryrun_base/claude-kit-mdm-dryrun.XXXXXX" \
        2>/dev/null || true)"
    else
      _install_dir="$(/usr/bin/mktemp -d \
        "$_dryrun_base/claude-kit-mdm-dryrun.XXXXXX" \
        2>/dev/null || true)"
    fi
    case "$_install_dir" in
      "$_dryrun_base"/claude-kit-mdm-dryrun.*) ;;
      *) mdm_log U1b "dry-run 一時 checkout を作成できない"; return 1 ;;
    esac
    [[ -d "$_install_dir" && ! -L "$_install_dir" ]] || return 1
    _install_dir="$(builtin cd -P -- "$_install_dir" 2>/dev/null \
      && printf '%s' "$PWD")" || return 1
    case "$_install_dir" in
      "$_dryrun_physical_base"/claude-kit-mdm-dryrun.*) ;;
      *) mdm_log U1b "dry-run 一時 checkout が canonical でない"; return 1 ;;
    esac
    _MDM_DRYRUN_CHECKOUT="$_install_dir"
    _mdm_arm_transient_cleanup
  else
    [[ -z "$_install_dir" ]] && _install_dir="$_home/.claude-starter-kit"
  fi
  MDM_RCPT_GIT_REF="$_ref"
  MDM_RCPT_INSTALL_DIR="$_install_dir"

  # Normal MDM runs use one dedicated managed checkout.  A configurable
  # arbitrary home subdirectory cannot be safely replaced authoritatively
  # without risking unrelated user data, so custom paths fail closed.
  if [[ "$_dry_run" != "true" ]]; then
    if [[ "$_install_dir" != "$_home/.claude-starter-kit" ]]; then
      mdm_log U1b "KIT_MDM_INSTALL_DIR は専用パス $_home/.claude-starter-kit のみ許可"
      return "$MDM_EXIT_CONFIG"
    fi
    if [[ -L "$_install_dir" || ( -e "$_install_dir" && ! -d "$_install_dir" ) ]]; then
      mdm_log U1b "管理 checkout パスの実体が不正: $_install_dir"
      return "$MDM_EXIT_CONFIG"
    fi
    if [[ -d "$_install_dir" ]] \
      && [[ "$(_mdm_canonical_dir "$_install_dir")" != "$_install_dir" ]]; then
      mdm_log U1b "管理 checkout パスが canonical でない: $_install_dir"
      return "$MDM_EXIT_CONFIG"
    fi
  fi

  # U1b: キット取得 + ref ピン留め
  local _repo_url="$_MDM_KIT_REPO_URL"
  if [[ "${_MDM_TEST_MODE:-0}" == "1" && -n "${MDM_KIT_REPO_URL_OVERRIDE:-}" ]]; then
    _repo_url="$MDM_KIT_REPO_URL_OVERRIDE"
  fi
  # Rebuild the managed checkout from the fixed URL on every run.  Reusing a
  # target-user-owned .git/config would let origin/url rewrites and filters
  # redefine the code that setup executes.
  mdm_log U1b "管理 checkout を再構築: $_install_dir"
  _mdm_run_maybe_as_user /bin/mkdir -p "$(dirname "$_install_dir")" 2>/dev/null || true
  if [[ -e "$_install_dir" || -L "$_install_dir" ]]; then
    _mdm_run_maybe_as_user /bin/rm -rf "$_install_dir" 2>/dev/null || return 1
  fi
  if ! _mdm_git_network -c core.hooksPath=/dev/null clone --quiet --no-checkout \
    "$_repo_url" "$_install_dir" 2>/dev/null; then
    mdm_log U1b "clone に失敗: $_install_dir"
    return 1
  fi

  local _sha _rc=0
  _sha="$(mdm_resolve_ref_sha "$_install_dir" "$_ref" "$_repo_url")" || _rc=$?
  if [[ $_rc -ne 0 || -z "$_sha" ]]; then
    mdm_log U1b "ref を解決できない: $_ref"
    return 1
  fi
  if ! _mdm_git -C "$_install_dir" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    checkout --quiet --force --detach "$_sha" 2>/dev/null; then
    mdm_log U1b "checkout に失敗: $_sha"
    return 1
  fi
  local _head_sha _status
  _head_sha="$(_mdm_git -C "$_install_dir" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$_head_sha" != "$_sha" ]]; then
    mdm_log U1b "checkout 後の HEAD が解決 SHA と不一致: $_head_sha != $_sha"
    return 1
  fi
  _status="$(_mdm_git -C "$_install_dir" status --porcelain --untracked-files=all 2>/dev/null)" \
    || return 1
  if [[ -n "$_status" ]]; then
    mdm_log U1b "checkout に未追跡または変更済みファイルがある"
    return 1
  fi
  MDM_RCPT_RESOLVED_SHA="$_sha"
  MDM_RCPT_KIT_VERSION="$(_mdm_describe_kit_version _mdm_git "$_install_dir")"
  # A preview is non-authoritative, but it must still prove that the policy
  # distributed by MDM matches the renderer in this exact clean commit before
  # setup.sh is allowed to execute.
  _mdm_prepare_expected_state "$_home" "$_install_dir" "$_sha" || return $?
  _mdm_detached_head_matches "$_install_dir" "$_sha" "$_uid" || {
    mdm_log U1b "policy検証後の checkout HEAD 束縛に失敗"
    return 1
  }
  _status="$(_mdm_git -C "$_install_dir" status --porcelain \
    --untracked-files=all 2>/dev/null)" || return 1
  [[ -z "$_status" ]] || {
    mdm_log U1b "policy検証後に checkout が変更された"
    return 1
  }
  _mdm_run_maybe_as_user /bin/chmod +x "$_install_dir/setup.sh" 2>/dev/null || true

  # required_components: kit は常時、claude_cli は KIT_MDM_INSTALL_CLAUDE_CLI!=false のとき（既定 true）
  local _cli_required="true"
  if [[ -n "${KIT_MDM_INSTALL_CLAUDE_CLI:-}" ]]; then
    _cli_required="$(_mdm_root_bool "$KIT_MDM_INSTALL_CLAUDE_CLI" 2>/dev/null || echo true)"
  fi
  if [[ "$_cli_required" == "true" && "$_dry_run" != "true" ]]; then
    MDM_RCPT_REQUIRED_COMPONENTS='["kit","claude_cli"]'
  else
    MDM_RCPT_REQUIRED_COMPONENTS='["kit"]'
  fi

  # U2: setup.sh を直接実行（root 時のみ環境分離降格）。
  # 引数は mdm_build_setup_argv がグローバル配列 MDM_SETUP_ARGV へ直接構築する
  # （既存 manifest の有無に関係なく fresh reconciliation とし、
  # KIT_MDM_DRY_RUN=true のときだけ --dry-run を付与。改行シリアライズは
  # 行わない）。
  mdm_build_setup_argv "$_home"
  mdm_log U2 "setup.sh を実行: ${MDM_SETUP_ARGV[*]}"
  if [[ "$_euid" -eq 0 ]]; then
    _mdm_exec_setup_as_user "$_uid" "$_user" "$_home" /bin/bash \
      "$_install_dir/setup.sh" "${MDM_SETUP_ARGV[@]}" || _setup_rc=$?
    if [[ "$_setup_rc" -ne 0 ]]; then
      mdm_log U2 "setup.sh の実行に失敗 (exit=$_setup_rc)"
      [[ "$_setup_rc" -eq "$MDM_EXIT_PREREQ" ]] && return "$MDM_EXIT_PREREQ"
      return 1
    fi
  else
    mdm_build_drop_argv "$_uid" "$_user" "$_home" \
      /bin/bash "$_install_dir/setup.sh" "${MDM_SETUP_ARGV[@]}" || return 1
    _mdm_run_with_timeout "$(_mdm_timeout_seconds \
      "$_MDM_TIMEOUT_SETUP_SECONDS")" "${MDM_DROP_ARGV[@]}" || _setup_rc=$?
    if [[ "$_setup_rc" -ne 0 ]]; then
      mdm_log U2 "setup.sh の実行に失敗 (exit=$_setup_rc)"
      [[ "$_setup_rc" -eq "$MDM_EXIT_PREREQ" ]] && return "$MDM_EXIT_PREREQ"
      return 1
    fi
  fi

  # U3: Claude Code CLI 導入の確認（KIT_MDM_INSTALL_CLAUDE_CLI=true のとき）
  if [[ "$_cli_required" == "true" && "$_dry_run" != "true" ]]; then
    mdm_log U3 "Claude Code CLI 導入を確認"
    if ! _mdm_cli_present_for_home "$_home"; then
      mdm_log U3 "Claude Code CLI が見つからない（部分失敗として記録）"
      MDM_RCPT_PARTIAL='["claude_cli"]'
      return "$MDM_EXIT_CLI"
    fi
  fi

  return 0
}

# ログ出力先を決定して MDM_LOG_FILE を設定する。
# 設定確定（_mdm_root_config_apply）と R2 のユーザー/home 解決後に呼ぶこと。
# 旧実装は設定読込前に KIT_MDM_LOG_DIR を参照していたため、管理設定ファイル
# からの指定がログパスに反映されなかった。
# - 既定: root は /Library/Logs/ClaudeCodeStarterKit、
#         ユーザーモードは <home>/Library/Logs/ClaudeCodeStarterKit
# - KIT_MDM_LOG_DIR は許可プレフィックス（/Library/Logs または
#   <home>/Library/Logs）配下のみ許可。違反は exit 50
# ログ出力先ディレクトリを決定し許可プレフィックスを検証して stdout へ返す
# （ファイル I/O を伴わないためテスト可能。違反は exit 50）。
# 許可プレフィックスは実行モードで分ける: root は /Library/Logs のみ
# （ユーザー home 配下を許すと、ユーザーが植えた symlink を root が辿って
# 任意ファイルへ append する経路になる）。非 root は自分の home 配下のみ。
_mdm_log_dir_for() {
  local _euid="$1" _home="$2"
  local _default_dir
  if [[ "$_euid" -eq 0 ]]; then
    _default_dir="/Library/Logs/ClaudeCodeStarterKit"
  else
    _default_dir="$_home/Library/Logs/ClaudeCodeStarterKit"
  fi
  local _dir="${KIT_MDM_LOG_DIR:-$_default_dir}"
  case "$_dir" in
    *..*)
      mdm_log R1 "KIT_MDM_LOG_DIR に .. を含む: $_dir"
      return "$MDM_EXIT_CONFIG" ;;
  esac
  if [[ "$_euid" -eq 0 ]]; then
    case "$_dir" in
      /Library/Logs|/Library/Logs/*) : ;;
      *)
        mdm_log R1 "KIT_MDM_LOG_DIR が root の許可プレフィックス（/Library/Logs）配下でない: $_dir"
        return "$MDM_EXIT_CONFIG" ;;
    esac
  else
    case "$_dir" in
      "$_home/Library/Logs"|"$_home/Library/Logs/"*) : ;;
      *)
        mdm_log R1 "KIT_MDM_LOG_DIR がユーザーの許可プレフィックス（~/Library/Logs）配下でない: $_dir"
        return "$MDM_EXIT_CONFIG" ;;
    esac
  fi
  printf '%s' "$_dir"
  return 0
}

_mdm_setup_log_file() {
  local _euid="$1" _home="$2"
  local _dir _dir_rc=0
  _dir="$(_mdm_log_dir_for "$_euid" "$_home")" || _dir_rc=$?
  [[ "$_dir_rc" -eq 0 ]] || return "$_dir_rc"
  # ログ dir が symlink 経由なら拒否（root が symlink を辿って任意領域へ書くのを防ぐ。R3-High）
  if [[ -L "$_dir" ]]; then
    mdm_log R1 "ログディレクトリが symlink: $_dir"
    return "$MDM_EXIT_CONFIG"
  fi
  # root 経路: /Library/Logs から _dir までの信頼チェーンを検証（R5-High）。
  # 全構成要素が非 symlink・root 所有・group/other 書込不可であることを要求し、
  # 攻撃者所有の中間/最終 dir の再利用と、中間 symlink による許可プレフィックス
  # 外への誘導を排除する。1つでも違反すれば fail-closed。
  if [[ "$_euid" -eq 0 ]] && ! _mdm_verify_dir_chain "$_dir" "/Library/Logs"; then
    mdm_log R1 "ログ dir の信頼チェーンが成立しない（fail-closed）: $_dir"
    return "$MDM_EXIT_CONFIG"
  fi
  # umask 022 で dir を 755 作成（スクリプト冒頭で umask 022 だが、呼び出し
  # 時点の umask 変化に依存しないよう明示制御する）
  local _um; _um="$(umask)"
  umask 022
  if ! mkdir -p "$_dir" 2>/dev/null; then
    umask "$_um"
    mdm_log R1 "ログディレクトリを作成できない: $_dir"
    return "$MDM_EXIT_CONFIG"
  fi
  # root 経路: 作成後の最終 dir も信頼できること（root 755 で作られたこと）を再確認し、
  # 既存 dir を契約の 755 へ収束（信頼チェーン成立後なので chmod は race しない）
  if [[ "$_euid" -eq 0 ]]; then
    if ! _mdm_component_trusted "$_dir"; then
      umask "$_um"
      mdm_log R1 "作成後のログディレクトリが信頼できない: $_dir"
      return "$MDM_EXIT_CONFIG"
    fi
    if ! chmod 755 "$_dir" 2>/dev/null; then
      umask "$_um"
      mdm_log R1 "ログディレクトリの権限（755）を設定できない: $_dir"
      return "$MDM_EXIT_CONFIG"
    fi
  fi
  local _ts
  _ts="$(date -u +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
  local _open_rc=0
  _mdm_open_log_fd "$_dir/install-$_ts.log" || _open_rc=$?
  umask "$_um"
  return "$_open_rc"
}

# ログファイルを新規排他作成して fd 7 に束縛する。
# 既存ファイルは一切再利用しない。攻撃者が予測パスに先置きした regular file
# は noclobber で拒否 → 別名（.1, .2 …）へ。symlink は事前に除去してから
# 新規作成する（symlink 追随を断つ）。以降 mdm_log は fd 7 へ書くため、
# 検証後のパス差し替えの影響を受けない（パス再オープンを避ける）。
# 呼び出し側が umask 022 を設定済み前提で、ファイルは 644 で作られる（chmod 不要）。
# `exec 7>... 2>/dev/null` は引数なし exec のリダイレクトが現在の
# shell の fd 2 を恒久的に /dev/null へ向けてしまう。stderr 抑制は必ず
# `{ exec 7>...; } 2>/dev/null` のようにグループの一時リダイレクトに閉じ込める。
_mdm_open_log_fd() {
  local _base="$1" _cand="$1" _n=0 _opened=0
  local _noclob=0
  [[ -o noclobber ]] && _noclob=1
  while [[ "$_n" -le 50 ]]; do
    # symlink 先置きは自身を除去（noclobber は dangling symlink を追随作成し得るため）
    [[ -L "$_cand" ]] && rm -f "$_cand" 2>/dev/null
    if [[ ! -L "$_cand" ]]; then
      set -o noclobber
      if { exec 7>"$_cand"; } 2>/dev/null; then
        _opened=1
      fi
      [[ "$_noclob" -eq 0 ]] && set +o noclobber
    fi
    [[ "$_opened" -eq 1 ]] && break
    _n=$((_n + 1))
    _cand="$_base.$_n"
  done
  if [[ "$_opened" -ne 1 ]]; then
    mdm_log R1 "ログファイルを安全に作成できない（先置き衝突が解消しない）: $_base"
    return "$MDM_EXIT_CONFIG"
  fi
  if [[ -L "$_cand" || ! -f "$_cand" ]]; then
    { exec 7>&-; } 2>/dev/null || true
    mdm_log R1 "作成したログファイルの実体が不正: $_cand"
    return "$MDM_EXIT_CONFIG"
  fi
  MDM_LOG_FILE="$_cand"
  MDM_LOG_FD_OPEN=1
  return 0
}

# MDM 配布固有の既定値を適用する（本体 profiles/*.conf の既定と異なる値を
# MDM 配布でだけ上書きする場所）。_mdm_root_config_apply の**後**に呼ぶこと。
# production は clean env で起動し、ここで見える値は検証済み CLI/root config
# から移送された状態なので、明示値を保ち未設定キーだけ MDM 既定で補う。
#   - ENABLE_GHOSTTY_SETUP: 本体既定は standard/full プロファイルで true だが、
#     MDM 配布では GUI アプリの既定導入を避けるため既定 off とする。
#     mdm-config.conf で ENABLE_GHOSTTY_SETUP=true を明示すれば on にできる。
_mdm_apply_mdm_defaults() {
  : "${ENABLE_GHOSTTY_SETUP:=false}"
  : "${ENABLE_FONTS_SETUP:=false}"
  ENABLE_AUTO_UPDATE=false
  ENABLE_WEB_CONTENT_UPDATE=false
  ENABLE_CODEX_PLUGIN=false
  export ENABLE_GHOSTTY_SETUP ENABLE_FONTS_SETUP ENABLE_AUTO_UPDATE \
    ENABLE_WEB_CONTENT_UPDATE ENABLE_CODEX_PLUGIN
}

_mdm_json_query() { # <file> <valid|get|count|item> [key] [index]
  local _file="$1" _operation="$2" _key="${3:-}" _index="${4:-}"
  local _python
  case "$_operation" in valid|get|count|item) : ;; *) return 1 ;; esac
  [[ -f "$_file" && ! -L "$_file" ]] || return 1
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_file" "$_operation" "$_key" "$_index" <<'PY'
import json
import os
import stat
import sys

path, operation, key, index_raw = sys.argv[1:]


def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_uid, value.st_gid, value.st_size, value.st_mtime_ns,
            value.st_ctime_ns, getattr(value, "st_flags", 0),
            getattr(value, "st_gen", 0))


def unique_object(pairs):
    result = {}
    for name, item in pairs:
        if name in result:
            raise ValueError("duplicate JSON key")
        result[name] = item
    return result


def reject_constant(_value):
    raise ValueError("non-finite JSON number")


def control_free(value):
    return (isinstance(value, str)
            and not any(ord(char) < 32 or 127 <= ord(char) <= 159
                        or 0xD800 <= ord(char) <= 0xDFFF
                        for char in value))


def validate_strings(value, depth=0):
    if depth > 128:
        raise ValueError("JSON nesting exceeds limit")
    if isinstance(value, str):
        if not control_free(value):
            raise ValueError("JSON string contains a control character")
    elif isinstance(value, list):
        for item in value:
            validate_strings(item, depth + 1)
    elif isinstance(value, dict):
        for name, item in value.items():
            if not control_free(name):
                raise ValueError("JSON key contains a control character")
            validate_strings(item, depth + 1)


def emit_scalar(value):
    if isinstance(value, str):
        if not control_free(value):
            raise ValueError("unsafe JSON scalar")
        output = value
    elif type(value) is bool:
        output = "true" if value else "false"
    elif type(value) is int:
        output = str(value)
    else:
        raise ValueError("JSON value is not a supported scalar")
    sys.stdout.buffer.write(output.encode("utf-8", "strict"))


try:
    before = os.lstat(path)
    if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
            or before.st_size < 3 or before.st_size > 64 * 1024 * 1024):
        raise ValueError("unsafe JSON file")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW
                         | getattr(os, "O_CLOEXEC", 0))
    try:
        opened = os.fstat(descriptor)
        if identity(opened) != identity(before):
            raise ValueError("JSON identity changed")
        chunks = []
        remaining = opened.st_size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise ValueError("short JSON read")
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise ValueError("JSON grew during read")
    finally:
        os.close(descriptor)
    if identity(os.lstat(path)) != identity(before):
        raise ValueError("JSON file changed")
    data = b"".join(chunks)
    if (not data.startswith(b"{") or not data.endswith(b"}\n")
            or b"\x00" in data or b"\r" in data or b"\t" in data):
        raise ValueError("JSON bytes are not canonical at the document edge")
    text = data.decode("utf-8", "strict")
    value = json.loads(text, object_pairs_hook=unique_object,
                       parse_constant=reject_constant)
    if type(value) is not dict:
        raise ValueError("JSON root must be an object")
    validate_strings(value)
    if operation == "valid":
        raise SystemExit(0)
    current = value
    if not key or any(not part for part in key.split(".")):
        raise ValueError("invalid JSON key path")
    for part in key.split("."):
        if type(current) is not dict or part not in current:
            raise ValueError("missing JSON key")
        current = current[part]
    if operation == "get":
        emit_scalar(current)
    elif operation == "count":
        if type(current) is not list:
            raise ValueError("JSON value is not an array")
        sys.stdout.write(str(len(current)))
    else:
        if (not index_raw.isascii() or not index_raw.isdigit()
                or (len(index_raw) > 1 and index_raw.startswith("0"))):
            raise ValueError("invalid JSON array index")
        index = int(index_raw)
        if type(current) is not list or index >= len(current):
            raise ValueError("JSON array index is out of range")
        emit_scalar(current[index])
except (IndexError, OSError, RecursionError, UnicodeError, ValueError,
        json.JSONDecodeError):
    raise SystemExit(1)
PY
}

_mdm_json_valid() {
  _mdm_json_query "$1" valid
}

_mdm_json_get() { # <file> <key>
  _mdm_json_query "$1" get "$2"
}

_mdm_json_array_count() { # <file> <key>
  _mdm_json_query "$1" count "$2"
}

_mdm_json_array_get() { # <file> <key> <index>
  _mdm_json_query "$1" item "$2" "$3"
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
}

_mdm_path_is_absent_with_real_parents() { # <root> <relative>
  local _root="$1" _relative="$2" _python
  [[ -d "$_root" && ! -L "$_root" && -n "$_relative" \
    && "$_relative" != /* && ! "$_relative" =~ [[:cntrl:]] ]] || return 1
  case "/$_relative/" in */../*|*/./*|*//*) return 1 ;; esac
  _python="${_MDM_ABSENCE_PYTHON:-}"
  [[ -n "$_python" ]] || _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S -c '
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

    # ENOENT on an open directory is not enough: an untrusted user can swap an
    # ancestor out of the live pathname while this walk still holds the old
    # inode.  Rebind from the root pathname after ENOENT, compare every parent
    # inode with the held chain, and observe ENOENT again.  A second complete
    # pass makes an in-progress swap fail closed instead of certifying a stale
    # detached tree.
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

_mdm_deployment_digest() ( # <manifest-snapshot> <claude-dir> <snapshot-dir> <target-uid>
  local _manifest="$1" _claude_dir="$2" _snapshot="$3" _target_uid="$4"
  local _expected="${_MDM_EXPECTED_OUTPUT:-}" _expected_manifest _expected_modes _expected_tree
  local _count _expected_count _mode_count _index=0 _file _relative _snap_file _canonical
  local _expected_relative _expected_file _expected_live_mode _expected_snap_mode _extra _mode_line
  local _live_copy _snap_copy _live_hash _snap_hash _live_mode _snap_mode _input _digest
  local _live_size _snap_size _aggregate=0 _workspace="" _live_managed _snap_managed _expected_managed
  local _absent_count _expected_absent_count _absent_index=0 _absent_relative _expected_absent
  _mdm_cleanup_attest_workspace() {
    local _base
    [[ -n "$_workspace" ]] || return 0
    _base="$(_mdm_safe_tmpdir)" || return 1
    case "$_workspace" in "$_base"/claude-kit-mdm-attest.*) : ;; *) return 1 ;; esac
    if [[ -e "$_workspace" || -L "$_workspace" ]]; then
      [[ -d "$_workspace" && ! -L "$_workspace" ]] || return 1
      /bin/rm -rf "$_workspace" || return 1
    fi
    _workspace=""
  }
  trap '_mdm_cleanup_attest_workspace' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [[ "$_target_uid" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$_expected" ]] || return 1
  _mdm_expected_tree_trusted "$_expected" || return 1
  _expected_manifest="$_expected/manifest.json"
  _expected_modes="$_expected/modes.tsv"
  _expected_tree="$_expected/tree"
  _mdm_json_valid "$_expected_manifest" || return 1
  [[ "$(_mdm_json_get "$_expected_manifest" profile)" == "${PROFILE:-standard}" ]] || return 1
  [[ "$(_mdm_json_get "$_expected_manifest" language)" == "${LANGUAGE:-en}" ]] || return 1
  _count="$(_mdm_json_array_count "$_manifest" files)"
  _expected_count="$(_mdm_json_array_count "$_expected_manifest" files)"
  _mode_count="$(/usr/bin/wc -l < "$_expected_modes" | /usr/bin/tr -d '[:space:]')" || return 1
  [[ "$_count" =~ ^[0-9]+$ && "$_count" -gt 0 && "$_count" -le 1000 \
    && "$_expected_count" == "$_count" && "$_mode_count" == "$_count" ]] || return 1
  _workspace="$(/usr/bin/mktemp -d "$(_mdm_safe_tmpdir)/claude-kit-mdm-attest.XXXXXX")" || return 1
  /bin/chmod 700 "$_workspace" || { /bin/rm -rf "$_workspace"; return 1; }
  _input="$_workspace/deployment-input"
  (umask 077; : > "$_input") || { /bin/rm -rf "$_workspace"; return 1; }
  while (( _index < _count )); do
    _file="$(_mdm_json_array_get "$_manifest" files "$_index")"
    [[ -n "$_file" && ! "$_file" =~ [[:cntrl:]] ]] || { /bin/rm -rf "$_workspace"; return 1; }
    case "$_file" in "$_claude_dir"/*) : ;; *) /bin/rm -rf "$_workspace"; return 1 ;; esac
    _relative="${_file#"$_claude_dir"/}"
    [[ -n "$_relative" && ! "$_relative" =~ [[:cntrl:]] ]] \
      || { /bin/rm -rf "$_workspace"; return 1; }
    case "/$_relative/" in */../*|*/./*|*//*) /bin/rm -rf "$_workspace"; return 1 ;; esac
    _expected_relative="$(_mdm_json_array_get "$_expected_manifest" files "$_index")"
    [[ "$_relative" == "$_expected_relative" ]] || { /bin/rm -rf "$_workspace"; return 1; }
    _mode_line="$(/usr/bin/sed -n "$((_index + 1))p" "$_expected_modes")" \
      || { /bin/rm -rf "$_workspace"; return 1; }
    _expected_live_mode=""; _expected_snap_mode=""; _extra=""
    IFS=$'\t' read -r _expected_relative _expected_live_mode _expected_snap_mode _extra <<< "$_mode_line"
    [[ "$_expected_relative" == "$_relative" && -z "$_extra" \
      && "$_expected_live_mode" =~ ^[0-7]{4}$ && "$_expected_snap_mode" =~ ^[0-7]{4}$ ]] \
      || { /bin/rm -rf "$_workspace"; return 1; }
    _canonical="$(_mdm_canonical_file "$_file")" || { /bin/rm -rf "$_workspace"; return 1; }
    [[ "$_canonical" == "$_file" ]] || { /bin/rm -rf "$_workspace"; return 1; }
    _snap_file="$_snapshot/$_relative"
    _canonical="$(_mdm_canonical_file "$_snap_file")" || { /bin/rm -rf "$_workspace"; return 1; }
    [[ "$_canonical" == "$_snap_file" ]] || { /bin/rm -rf "$_workspace"; return 1; }
    _expected_file="$_expected_tree/$_relative"
    _canonical="$(_mdm_canonical_file "$_expected_file")" || { /bin/rm -rf "$_workspace"; return 1; }
    [[ "$_canonical" == "$_expected_file" ]] || { /bin/rm -rf "$_workspace"; return 1; }
    _live_copy=""; _live_mode=""
    _mdm_stable_managed_snapshot "$_file" managed "$_target_uid" _live_copy _live_mode \
      || { /bin/rm -rf "$_workspace"; return 1; }
    _snap_copy=""; _snap_mode=""
    _mdm_stable_managed_snapshot "$_snap_file" snapshot "$_target_uid" _snap_copy _snap_mode \
      || { /bin/rm -f "$_live_copy"; /bin/rm -rf "$_workspace"; return 1; }
    [[ "$_live_mode" == "$_expected_live_mode" && "$_snap_mode" == "$_expected_snap_mode" ]] \
      || { /bin/rm -f "$_live_copy" "$_snap_copy"; /bin/rm -rf "$_workspace"; return 1; }
    _live_size="$(/usr/bin/wc -c < "$_live_copy" | /usr/bin/tr -d '[:space:]')"
    _snap_size="$(/usr/bin/wc -c < "$_snap_copy" | /usr/bin/tr -d '[:space:]')"
    [[ "$_live_size" =~ ^[0-9]+$ && "$_snap_size" =~ ^[0-9]+$ ]] \
      || { /bin/rm -f "$_live_copy" "$_snap_copy"; /bin/rm -rf "$_workspace"; return 1; }
    _aggregate=$((_aggregate + 10#$_live_size + 10#$_snap_size))
    (( _aggregate <= 536870912 )) \
      || { /bin/rm -f "$_live_copy" "$_snap_copy"; /bin/rm -rf "$_workspace"; return 1; }
    if [[ "$_relative" == CLAUDE.md ]]; then
      _live_managed="$_workspace/live-managed.$_index"
      _snap_managed="$_workspace/snapshot-managed.$_index"
      _expected_managed="$_workspace/expected-managed.$_index"
      _mdm_extract_managed_section "$_live_copy" "$_live_managed" 0 \
        && _mdm_extract_managed_section "$_snap_copy" "$_snap_managed" 1 \
        && _mdm_extract_managed_section "$_expected_file" "$_expected_managed" 1 \
        && /usr/bin/cmp -s "$_snap_copy" "$_snap_managed" \
        && /usr/bin/cmp -s "$_expected_file" "$_expected_managed" \
        && /usr/bin/cmp -s "$_live_managed" "$_expected_file" \
        && /usr/bin/cmp -s "$_snap_copy" "$_expected_file" \
        || { /bin/rm -f "$_live_copy" "$_snap_copy"; /bin/rm -rf "$_workspace"; return 1; }
      _live_hash="$(_mdm_sha256_file "$_live_managed")"
      _snap_hash="$(_mdm_sha256_file "$_snap_copy")"
    else
      /usr/bin/cmp -s "$_live_copy" "$_expected_file" \
        && /usr/bin/cmp -s "$_snap_copy" "$_expected_file" \
        || { /bin/rm -f "$_live_copy" "$_snap_copy"; /bin/rm -rf "$_workspace"; return 1; }
      _live_hash="$(_mdm_sha256_file "$_live_copy")"
      _snap_hash="$(_mdm_sha256_file "$_snap_copy")"
    fi
    /bin/rm -f "$_live_copy" "$_snap_copy"
    [[ "$_live_hash" =~ ^[0-9a-f]{64}$ && "$_snap_hash" =~ ^[0-9a-f]{64}$ ]] \
      || { /bin/rm -rf "$_workspace"; return 1; }
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$_relative" "$_live_hash" "$_snap_hash" "$_live_mode" "$_snap_mode" >> "$_input" \
      || { /bin/rm -rf "$_workspace"; return 1; }
    _index=$((_index + 1))
  done
  _absent_count="$(_mdm_json_array_count "$_manifest" mdm_absent_files)"
  _expected_absent_count="$(_mdm_json_array_count "$_expected_manifest" absent_files)"
  [[ "$_absent_count" =~ ^[0-9]+$ && "$_absent_count" -le 1000 \
    && "$_expected_absent_count" == "$_absent_count" \
    && $((_count + _absent_count)) -le 2000 ]] \
    || { /bin/rm -rf "$_workspace"; return 1; }
  _MDM_ABSENCE_PYTHON="$(_mdm_system_python)" \
    || { /bin/rm -rf "$_workspace"; return 1; }
  while (( _absent_index < _absent_count )); do
    _absent_relative="$(_mdm_json_array_get "$_manifest" mdm_absent_files "$_absent_index")"
    _expected_absent="$(_mdm_json_array_get \
      "$_expected_manifest" absent_files "$_absent_index")"
    [[ -n "$_absent_relative" && "$_absent_relative" == "$_expected_absent" ]] \
      || { /bin/rm -rf "$_workspace"; return 1; }
    _mdm_path_is_absent_with_real_parents "$_claude_dir" "$_absent_relative" \
      && _mdm_path_is_absent_with_real_parents "$_snapshot" "$_absent_relative" \
      || { /bin/rm -rf "$_workspace"; return 1; }
    printf 'absent\t%s\n' "$_absent_relative" >> "$_input" \
      || { /bin/rm -rf "$_workspace"; return 1; }
    _absent_index=$((_absent_index + 1))
  done
  _MDM_ABSENCE_PYTHON=""
  _digest="$(_mdm_sha256_file "$_input")"
  /bin/rm -rf "$_workspace"
  _workspace=""
  [[ "$_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$_digest"
)

_mdm_deployment_manifest_schema_valid() { # <strict-json-manifest>
  local _manifest="$1" _python
  _mdm_json_valid "$_manifest" || return 1
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_manifest" <<'PY'
import json
import re
import sys

path = sys.argv[1]
ordered_keys = (
    "version", "timestamp", "kit_version", "kit_commit", "profile",
    "language", "editor", "commit_attribution", "new_init", "plugins",
    "codex_plugin", "files", "cleanup_paths", "mdm_absent_files",
    "mdm_managed", "snapshot_dir", "claude_dir", "policy_sha256",
)
keys = set(ordered_keys)


def valid_text(value, limit=4096):
    return (type(value) is str and 0 < len(value.encode("utf-8")) <= limit
            and not any(ord(char) < 32 or 127 <= ord(char) <= 159
                        or 0xD800 <= ord(char) <= 0xDFFF
                        for char in value))


try:
    with open(path, "r", encoding="utf-8", errors="strict") as handle:
        raw = handle.read()
    value = json.loads(raw)
    if type(value) is not dict or set(value) != keys:
        raise ValueError("invalid deployment manifest keys")
    string_fields = (
        "version", "timestamp", "kit_version", "kit_commit", "profile",
        "language", "editor", "commit_attribution", "new_init",
        "codex_plugin", "snapshot_dir", "claude_dir", "policy_sha256",
    )
    if (any(not valid_text(value[name]) for name in string_fields)
            or type(value["plugins"]) is not str
            or len(value["plugins"].encode("utf-8")) > 4096
            or any(ord(char) < 32 or 127 <= ord(char) <= 159
                   for char in value["plugins"])):
        raise ValueError("invalid deployment manifest scalar")
    if (value["version"] != "2" or value["mdm_managed"] is not True
            or value["editor"] not in {
                "none", "vscode", "cursor", "zed", "neovim"}
            or value["commit_attribution"] not in {"true", "false"}
            or value["new_init"] not in {"true", "false"}
            or value["codex_plugin"] != "false"
            or not re.fullmatch(
                r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z",
                value["timestamp"])):
        raise ValueError("invalid deployment manifest identity")
    files = value["files"]
    cleanup = value["cleanup_paths"]
    absent = value["mdm_absent_files"]
    if (type(files) is not list or not 1 <= len(files) <= 1000
            or type(cleanup) is not list or len(cleanup) > 2000
            or type(absent) is not list or len(absent) > 1000):
        raise ValueError("invalid deployment manifest inventory")
    for items in (files, cleanup, absent):
        if (any(not valid_text(item) for item in items)
                or len(set(items)) != len(items)):
            raise ValueError("invalid deployment manifest path")
    canonical = json.dumps(
        {name: value[name] for name in ordered_keys},
        ensure_ascii=False,
        indent=2,
    ) + "\n"
    if raw != canonical:
        raise ValueError("non-canonical deployment manifest bytes")
except (OSError, TypeError, UnicodeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
PY
}

_mdm_validate_manifest_snapshot() { # <snapshot-file> <home> <target-uid>
  local _manifest="$1" _home="$2" _target_uid="$3"
  local _version _commit _claude_dir _snapshot _profile _language _policy _digest
  _mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_LOCAL_VALIDATION_SECONDS")" \
    _mdm_deployment_manifest_schema_valid "$_manifest" || return 1
  _version="$(_mdm_json_get "$_manifest" version)"
  [[ "$_version" == "2" ]] || return 1
  [[ "$(_mdm_json_get "$_manifest" mdm_managed)" == "true" ]] || return 1
  _claude_dir="$(_mdm_json_get "$_manifest" claude_dir)"
  _snapshot="$(_mdm_json_get "$_manifest" snapshot_dir)"
  [[ "$_claude_dir" == "$_home/.claude" ]] || return 1
  [[ "$_snapshot" == "$_home/.claude/.starter-kit-snapshot" ]] || return 1
  [[ "$(_mdm_canonical_dir "$_claude_dir")" == "$_claude_dir" ]] || return 1
  [[ "$(_mdm_canonical_dir "$_snapshot")" == "$_snapshot" ]] || return 1
  _commit="$(_mdm_json_get "$_manifest" kit_commit)"
  [[ "$_commit" =~ ^[0-9a-f]{7,40}$ && "$MDM_RCPT_RESOLVED_SHA" =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ "$MDM_RCPT_RESOLVED_SHA" == "$_commit"* ]] || return 1
  _policy="$(_mdm_json_get "$_manifest" policy_sha256)" || return 1
  [[ "$_policy" =~ ^[0-9a-f]{64}$ \
    && "${MDM_RCPT_POLICY_SHA256:-}" =~ ^[0-9a-f]{64}$ \
    && "$_policy" == "$MDM_RCPT_POLICY_SHA256" ]] || return 1
  _profile="$(_mdm_json_get "$_manifest" profile)"
  _language="$(_mdm_json_get "$_manifest" language)"
  [[ "$_profile" == "${PROFILE:-standard}" ]] || return 1
  [[ "$_language" == "${LANGUAGE:-en}" ]] || return 1
  _digest="$(_mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_LOCAL_VALIDATION_SECONDS")" _mdm_deployment_digest \
      "$_manifest" "$_claude_dir" "$_snapshot" "$_target_uid")" || return 1
  MDM_RCPT_PROFILE="$_profile"
  MDM_RCPT_LANGUAGE="$_language"
  MDM_RCPT_DEPLOYMENT_SHA256="$_digest"
}

# Revalidate the user-phase result from one fd-bound manifest byte snapshot.
# Root treats the checkout/manifest only as data and signs the complete live +
# snapshot deployment digest into its receipt.
_mdm_capture_postcondition() {
  local _home="$1" _target_uid="$2" _manifest
  [[ "$_target_uid" =~ ^[0-9]+$ ]] || return 1
  _mdm_managed_parent_modes_final "$_home" "$_target_uid" || return 1
  _manifest="$_home/.claude/.starter-kit-manifest.json"
  local _canonical _manifest_copy _manifest_hash _rc=1
  _canonical="$(_mdm_canonical_file "$_manifest")" || return 1
  [[ "$_canonical" == "$_manifest" ]] || return 1
  _manifest_copy="$(_mdm_stable_file_snapshot "$_manifest" manifest)" || return 1
  _manifest_hash="$(_mdm_sha256_file "$_manifest_copy")"
  if [[ "$_manifest_hash" =~ ^[0-9a-f]{64}$ ]] \
    && _mdm_validate_manifest_snapshot "$_manifest_copy" "$_home" "$_target_uid"; then
    MDM_RCPT_MANIFEST_PATH="$_manifest"
    MDM_RCPT_MANIFEST_SHA256="$_manifest_hash"
    _rc=0
  fi
  /bin/rm -f "$_manifest_copy"
  return "$_rc"
}

# Recompute every user-controlled success claim after history persistence and
# immediately before the success receipt. A digest captured earlier in the
# run must never authorize a deployment or activation that changed meanwhile.
_mdm_revalidate_success_state() { # <user> <home> <uid> <generated-uid>
  local _user="$1" _home="$2" _uid="$3" _generated_uid="$4"
  local _manifest_path="$MDM_RCPT_MANIFEST_PATH"
  local _manifest_sha="$MDM_RCPT_MANIFEST_SHA256"
  local _deployment_sha="$MDM_RCPT_DEPLOYMENT_SHA256"
  local _component_path="$MDM_RCPT_COMPONENT_MANIFEST_PATH"
  local _component_sha="$MDM_RCPT_COMPONENT_MANIFEST_SHA256"
  local _profile="$MDM_RCPT_PROFILE" _language="$MDM_RCPT_LANGUAGE"
  [[ "$_manifest_path" == /* && "$_manifest_sha" =~ ^[0-9a-f]{64}$ \
    && "$_deployment_sha" =~ ^[0-9a-f]{64}$ \
    && "$_component_path" == /* && "$_component_sha" =~ ^[0-9a-f]{64}$ ]] \
    || return 1
  if ! _mdm_revalidate_target_identity \
      "$_user" "$_home" "$_uid" "$_generated_uid"; then
    mdm_log R4 "success revalidation: account identity drift"
    return 1
  fi
  if ! _mdm_capture_postcondition "$_home" "$_uid"; then
    mdm_log R4 "success revalidation: deployment capture failed"
    return 1
  fi
  [[ "$MDM_RCPT_MANIFEST_PATH" == "$_manifest_path" \
    && "$MDM_RCPT_MANIFEST_SHA256" == "$_manifest_sha" \
    && "$MDM_RCPT_DEPLOYMENT_SHA256" == "$_deployment_sha" \
    && "$MDM_RCPT_PROFILE" == "$_profile" \
    && "$MDM_RCPT_LANGUAGE" == "$_language" ]] || {
      mdm_log R4 "success revalidation: deployment claim drift"
      return 1
    }
  if ! _mdm_attest_components \
      "$_user" "$_home" "$_uid" "$_generated_uid"; then
    mdm_log R4 "success revalidation: component attestation failed"
    return 1
  fi
  [[ "$MDM_RCPT_COMPONENT_MANIFEST_PATH" == "$_component_path" \
    && "$MDM_RCPT_COMPONENT_MANIFEST_SHA256" == "$_component_sha" ]] || {
      mdm_log R4 "success revalidation: component claim drift"
      return 1
    }
  # Component checks can execute user-access probes. Close that window by
  # measuring the deployment once more, then bind the account tuple last.
  if ! _mdm_capture_postcondition "$_home" "$_uid"; then
    mdm_log R4 "success revalidation: final deployment capture failed"
    return 1
  fi
  [[ "$MDM_RCPT_MANIFEST_PATH" == "$_manifest_path" \
    && "$MDM_RCPT_MANIFEST_SHA256" == "$_manifest_sha" \
    && "$MDM_RCPT_DEPLOYMENT_SHA256" == "$_deployment_sha" \
    && "$MDM_RCPT_PROFILE" == "$_profile" \
    && "$MDM_RCPT_LANGUAGE" == "$_language" ]] || {
      mdm_log R4 "success revalidation: final deployment claim drift"
      return 1
    }
  if ! _mdm_revalidate_target_identity \
      "$_user" "$_home" "$_uid" "$_generated_uid"; then
    mdm_log R4 "success revalidation: final account identity drift"
    return 1
  fi
}

_mdm_revalidate_target_identity() { # <user> <home> <uid> <generated-uid>
  local _user="$1" _home="$2" _uid="$3" _generated_uid="$4"
  local _tuple _bound_home _canonical
  _canonical="$(_mdm_search_policy_username_for_uid "$_uid")" || return 1
  [[ "$_canonical" == "$_user" ]] || return 1
  _tuple="$(_mdm_bind_target_identity_tuple "$_user" "$_uid")" || return 1
  [[ "${_tuple%%$'\t'*}" == "$_uid" \
    && "${_tuple#*$'\t'}" == "$_generated_uid" ]] || return 1
  _bound_home="$(mdm_validate_user_home "$_user" "$_uid")" || return 1
  [[ "$_bound_home" == "$_home" ]]
}

# ── MDM private Node.js runtime ────────────────────────────────────────────
# MDM-managed setup never trusts a user PATH or an independently mutable
# Homebrew Cellar for Node.js.  One pinned, root-owned distribution is kept in
# the system support directory and exposed to the target user only through an
# exact absolute symlink.  Test-only overrides are accepted only while this
# file is sourced with MDM_SOURCE_ONLY=1.
_MDM_NODE_VERSION="v24.18.0"
_MDM_NODE_NPM_VERSION="11.16.0"
_MDM_NODE_TEAM_ID="HX7739G8FX"
_MDM_NODE_PROVENANCE_FILE=".claude-code-starter-kit-node-runtime"

_mdm_node_sysctl() {
  /usr/sbin/sysctl "$@"
}

_mdm_node_uname() {
  /usr/bin/uname "$@"
}

_mdm_node_runtime_arch() {
  local _machine _arm64
  if [[ "${_MDM_TEST_MODE:-0}" == 1 && -n "${MDM_NODE_ARCH_OVERRIDE:-}" ]]; then
    _machine="$MDM_NODE_ARCH_OVERRIDE"
  elif _mdm_is_darwin; then
    # Intel macOS does not expose hw.optional.arm64.  -i turns that expected
    # unknown OID into an empty value, while the hardware bit remains stable
    # across native and Rosetta-translated MDM agents on Apple Silicon.
    _arm64="$(_mdm_node_sysctl -in hw.optional.arm64 2>/dev/null)" || return 1
    _machine="$(_mdm_node_uname -m 2>/dev/null)" || return 1
    case "$_arm64:$_machine" in
      1:arm64|1:x86_64) printf '%s' arm64 ;;
      0:x86_64|:x86_64) printf '%s' x64 ;;
      *) return 1 ;;
    esac
    return 0
  else
    _machine="$(_mdm_node_uname -m 2>/dev/null)" || return 1
  fi
  case "$_machine" in
    arm64) printf '%s' arm64 ;;
    x86_64|x64) printf '%s' x64 ;;
    *) return 1 ;;
  esac
}

_mdm_node_runtime_source() { # <arch> <url-var> <sha256-var> <top-var>
  local _arch="$1" _url_var="$2" _sha_var="$3" _top_var="$4"
  local _source_top _source_url _source_sha
  [[ "$_url_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_sha_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_top_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  _source_top="node-${_MDM_NODE_VERSION}-darwin-${_arch}"
  _source_url="https://nodejs.org/dist/${_MDM_NODE_VERSION}/${_source_top}.tar.xz"
  case "$_arch" in
    arm64) _source_sha="4477b9f78efb77744cf5eb57a0e9594dba66466b38b4e93fa9f35cb907a095a6" ;;
    x64) _source_sha="4a3b6bc81542154430825128d9a279e8b364e8d90581544e506ef7579fd1ab6f" ;;
    *) return 1 ;;
  esac
  printf -v "$_url_var" '%s' "$_source_url"
  printf -v "$_sha_var" '%s' "$_source_sha"
  printf -v "$_top_var" '%s' "$_source_top"
}

_mdm_node_runtime_base() {
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && -n "${MDM_NODE_RUNTIME_ROOT_OVERRIDE:-}" ]]; then
    [[ "$MDM_NODE_RUNTIME_ROOT_OVERRIDE" == /* \
      && "$MDM_NODE_RUNTIME_ROOT_OVERRIDE" != / \
      && ! "$MDM_NODE_RUNTIME_ROOT_OVERRIDE" =~ [[:cntrl:]] ]] || return 1
    printf '%s' "$MDM_NODE_RUNTIME_ROOT_OVERRIDE"
  else
    printf '%s' "/Library/Application Support/ClaudeCodeStarterKit/runtime"
  fi
}

_mdm_node_runtime_path() {
  local _arch _base
  _arch="$(_mdm_node_runtime_arch)" || return 1
  _base="$(_mdm_node_runtime_base)" || return 1
  printf '%s/node-%s-darwin-%s' "$_base" "$_MDM_NODE_VERSION" "$_arch"
}

_mdm_node_runtime_bin() {
  local _path
  _path="$(_mdm_node_runtime_path)" || return 1
  printf '%s/bin' "$_path"
}

_mdm_node_runtime_owner_uid() {
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && -n "${MDM_NODE_OWNER_UID_OVERRIDE:-}" ]]; then
    [[ "$MDM_NODE_OWNER_UID_OVERRIDE" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$MDM_NODE_OWNER_UID_OVERRIDE"
  else
    printf '0'
  fi
}

_mdm_node_runtime_owner_gid() {
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && -n "${MDM_NODE_OWNER_GID_OVERRIDE:-}" ]]; then
    [[ "$MDM_NODE_OWNER_GID_OVERRIDE" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$MDM_NODE_OWNER_GID_OVERRIDE"
  else
    printf '0'
  fi
}

_mdm_node_runtime_codesign_requirement() {
  printf '%s' '=identifier "node" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "HX7739G8FX"'
}

_mdm_node_runtime_codesign() {
  /usr/bin/codesign "$@"
}

_mdm_node_runtime_node_version() { # <node-binary>
  /usr/bin/env -i HOME=/var/empty PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$1" --version 2>/dev/null
}

_mdm_node_runtime_process_arch() { # <node-binary>
  /usr/bin/env -i HOME=/var/empty PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$1" -p process.arch 2>/dev/null
}

_mdm_node_runtime_npm_version() { # <runtime-tree>
  /usr/bin/env -i HOME=/var/empty \
    "PATH=$1/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$1/bin/npm" --version 2>/dev/null
}

_mdm_node_runtime_bundled_npm_valid() { # <runtime-tree>
  local _root="$1" _npm_target _npx_target
  [[ -L "$_root/bin/npm" && -x "$_root/bin/npm" \
    && -L "$_root/bin/npx" && -x "$_root/bin/npx" \
    && -f "$_root/lib/node_modules/npm/package.json" \
    && ! -L "$_root/lib/node_modules/npm/package.json" \
    && -f "$_root/lib/node_modules/npm/bin/npm-cli.js" \
    && ! -L "$_root/lib/node_modules/npm/bin/npm-cli.js" \
    && -f "$_root/lib/node_modules/npm/bin/npx-cli.js" \
    && ! -L "$_root/lib/node_modules/npm/bin/npx-cli.js" ]] || return 1
  _mdm_readlink_exact "$_root/bin/npm" _npm_target || return 1
  _mdm_readlink_exact "$_root/bin/npx" _npx_target || return 1
  [[ "$_npm_target" == ../lib/node_modules/npm/bin/npm-cli.js \
    && "$_npx_target" == ../lib/node_modules/npm/bin/npx-cli.js ]]
}

_mdm_node_runtime_lipo() {
  /usr/bin/lipo "$@"
}

_mdm_node_runtime_thin_arch_valid() { # <node-binary> <logical-arch>
  local _slices
  _slices="$(_mdm_node_runtime_lipo -archs "$1" 2>/dev/null)" || return 1
  case "$2:$_slices" in arm64:arm64|x64:x86_64) return 0 ;; esac
  return 1
}

_mdm_node_runtime_otool() {
  /usr/bin/otool "$@"
}

_mdm_node_runtime_system_dylibs_only() { # <node-binary>
  local _node="$1" _output _line _dependency _first=1 _count=0
  _output="$(_mdm_node_runtime_otool -L "$_node" 2>/dev/null)" || return 1
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    if [[ "$_first" -eq 1 ]]; then
      [[ "$_line" == "$_node:" ]] || return 1
      _first=0
      continue
    fi
    _line="${_line#"${_line%%[![:space:]]*}"}"
    _dependency="${_line%%[[:space:]]*}"
    [[ -n "$_dependency" && ! "$_dependency" =~ [[:cntrl:]] ]] || return 1
    case "$_dependency" in
      /usr/lib/*|/System/Library/*) : ;;
      *) return 1 ;;
    esac
    _count=$((_count + 1))
  done <<< "$_output"
  [[ "$_first" -eq 0 && "$_count" -ge 1 ]]
}

_mdm_node_runtime_root_metadata_valid() { # <runtime-tree> <uid> <gid>
  local _tree="$1" _uid="$2" _gid="$3" _python
  [[ "$_uid" =~ ^[0-9]+$ && "$_gid" =~ ^[0-9]+$ ]] || return 1
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_tree" "$_uid" "$_gid" <<'PY'
import os
import stat
import sys

root, expected_uid, expected_gid = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
count = 0
for directory, names, files in os.walk(root, topdown=True, followlinks=False):
    for path in [directory] + [os.path.join(directory, value)
                               for value in names + files]:
        value = os.lstat(path)
        count += 1
        if count > 100000 or value.st_uid != expected_uid or value.st_gid != expected_gid:
            raise SystemExit(1)
        if not (stat.S_ISDIR(value.st_mode) or stat.S_ISREG(value.st_mode)
                or stat.S_ISLNK(value.st_mode)):
            raise SystemExit(1)
if count < 2:
    raise SystemExit(1)
PY
}

_mdm_node_runtime_expected_content_sha256() { # <logical-arch>
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && -n "${MDM_NODE_CONTENT_SHA256_OVERRIDE:-}" ]]; then
    [[ "$MDM_NODE_CONTENT_SHA256_OVERRIDE" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$MDM_NODE_CONTENT_SHA256_OVERRIDE"
    return 0
  fi
  case "$1" in
    arm64) printf '%s' 3b87679d20e675468b9281755c823b528b6406ba7af6cc7086ef00e5c8af6533 ;;
    x64) printf '%s' a9f69014ea08981c1b1822f565a39ae6970a319518ebf3e43d96ba9fc70aa209 ;;
    *) return 1 ;;
  esac
}

# Owner, group, timestamps, xattrs, and the local provenance marker are not
# release content.  Everything else is canonicalized exactly like the pinned
# official tar inventory: UTF-8 byte-sorted path/type/mode plus file bytes or
# symlink target.  This prevents fail mode from accepting a signed-node TOFU
# tree with added or changed package content.
_mdm_node_runtime_content_sha256() { # <runtime-tree>
  local _tree="$1" _python
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_tree" "$_MDM_NODE_PROVENANCE_FILE" <<'PY'
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

_mdm_node_runtime_signature_valid() { # <node-binary>
  local _node="$1" _requirement _details
  _requirement="$(_mdm_node_runtime_codesign_requirement)" || return 1
  _mdm_node_runtime_codesign --verify --strict -R "$_requirement" \
    -- "$_node" >/dev/null 2>&1 || return 1
  _details="$(_mdm_node_runtime_codesign -dv --verbose=4 -- "$_node" 2>&1)" \
    || return 1
  printf '%s\n' "$_details" | /usr/bin/grep -qx 'Identifier=node' \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx \
      "TeamIdentifier=${_MDM_NODE_TEAM_ID}" \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx \
      'Authority=Developer ID Application: Node.js Foundation (HX7739G8FX)' \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx \
      'Authority=Developer ID Certification Authority' \
    && printf '%s\n' "$_details" | /usr/bin/grep -qx \
      'Authority=Apple Root CA'
}

_mdm_node_runtime_provenance() { # <arch> <url> <sha256>
  printf 'schema=1\nversion=%s\narch=%s\nurl=%s\nsha256=%s\n' \
    "$_MDM_NODE_VERSION" "$1" "$2" "$3"
}

_mdm_exact_text_file() { # <regular-file> <expected-without-final-LF>
  local _path="$1" _expected="$2" _python
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_path" "$_expected" <<'PY'
import os
import stat
import sys

path, expected_text = sys.argv[1:]
expected = expected_text.encode("utf-8", "strict") + b"\n"

def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_uid, value.st_gid, value.st_size, value.st_mtime_ns,
            value.st_ctime_ns, getattr(value, "st_flags", 0),
            getattr(value, "st_gen", 0))

try:
    before = os.lstat(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW
                         | getattr(os, "O_CLOEXEC", 0))
    try:
        opened = os.fstat(descriptor)
        if (not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1
                or identity(opened) != identity(before)
                or opened.st_size != len(expected)):
            raise ValueError("unsafe exact-text file")
        actual = os.read(descriptor, len(expected) + 1)
        if actual != expected or os.read(descriptor, 1):
            raise ValueError("exact-text mismatch")
    finally:
        os.close(descriptor)
    if identity(os.lstat(path)) != identity(before):
        raise ValueError("exact-text file changed")
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
}

_mdm_node_runtime_provenance_valid() { # <runtime-tree> <arch> <url> <sha256>
  local _marker="$1/$_MDM_NODE_PROVENANCE_FILE" _expected
  [[ -f "$_marker" && ! -L "$_marker" ]] || return 1
  _expected="$(_mdm_node_runtime_provenance "$2" "$3" "$4")" || return 1
  _mdm_exact_text_file "$_marker" "$_expected"
}

_mdm_node_runtime_structure_safe() { # <runtime-tree|same-dir-stage>
  local _tree="$1" _expected _base _owner _group _digest
  _expected="$(_mdm_node_runtime_path)" || return 1
  _base="$(_mdm_node_runtime_base)" || return 1
  case "$_tree" in
    "$_expected"|"$_base"/.node-stage.*) : ;;
    *) return 1 ;;
  esac
  [[ -d "$_tree" && ! -L "$_tree" ]] || return 1
  [[ "$(_mdm_canonical_dir "$_tree" 2>/dev/null || true)" == "$_tree" ]] \
    || return 1
  _owner="$(_mdm_node_runtime_owner_uid)" || return 1
  _group="$(_mdm_node_runtime_owner_gid)" || return 1
  _digest="$(_mdm_artifact_digest tree "$_tree" "$_owner" "$_group")" \
    || return 1
  [[ "$_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  _mdm_node_runtime_root_metadata_valid "$_tree" "$_owner" "$_group" \
    || return 1
  _MDM_NODE_RUNTIME_DIGEST="$_digest"
}

_mdm_node_runtime_payload_trusted() { # <runtime-tree>
  local _tree="$1" _arch _url _sha _top _owner _group _before _after
  local _content _expected_content
  _mdm_node_runtime_structure_safe "$_tree" || return 1
  _before="$_MDM_NODE_RUNTIME_DIGEST"
  _arch="$(_mdm_node_runtime_arch)" || return 1
  _mdm_node_runtime_source "$_arch" _url _sha _top || return 1
  _expected_content="$(_mdm_node_runtime_expected_content_sha256 "$_arch")" \
    || return 1
  _content="$(_mdm_node_runtime_content_sha256 "$_tree")" || return 1
  [[ "$_content" == "$_expected_content" ]] || return 1
  _MDM_NODE_RUNTIME_CONTENT_SHA256="$_content"
  _owner="$(_mdm_node_runtime_owner_uid)" || return 1
  _group="$(_mdm_node_runtime_owner_gid)" || return 1
  [[ -f "$_tree/bin/node" && ! -L "$_tree/bin/node" \
    && -x "$_tree/bin/node" ]] || return 1
  _mdm_node_runtime_signature_valid "$_tree/bin/node" || return 1
  [[ "$(_mdm_node_runtime_node_version "$_tree/bin/node")" \
    == "$_MDM_NODE_VERSION" ]] || return 1
  [[ "$(_mdm_node_runtime_process_arch "$_tree/bin/node")" == "$_arch" ]] \
    || return 1
  _mdm_node_runtime_thin_arch_valid "$_tree/bin/node" "$_arch" || return 1
  _mdm_node_runtime_system_dylibs_only "$_tree/bin/node" || return 1
  _mdm_node_runtime_bundled_npm_valid "$_tree" || return 1
  [[ "$(_mdm_node_runtime_npm_version "$_tree")" \
      == "$_MDM_NODE_NPM_VERSION" ]] || return 1
  _after="$(_mdm_artifact_digest tree "$_tree" "$_owner" "$_group")" \
    || return 1
  [[ "$_after" == "$_before" ]] || return 1
  _MDM_NODE_RUNTIME_DIGEST="$_after"
}

_mdm_node_runtime_ancestors_trusted() { # <fixed-tree|same-dir-stage>
  local _tree="$1" _base _expected _owner _group _dir _mode
  local _system_dirs=() _managed_dirs=()
  _base="$(_mdm_node_runtime_base)" || return 1
  _expected="$(_mdm_node_runtime_path)" || return 1
  case "$_tree" in
    "$_expected"|"$_base"/.node-stage.*) : ;;
    *) return 1 ;;
  esac
  _owner="$(_mdm_node_runtime_owner_uid)" || return 1
  _group="$(_mdm_node_runtime_owner_gid)" || return 1
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && -n "${MDM_NODE_RUNTIME_ROOT_OVERRIDE:-}" ]]; then
    _managed_dirs=("$_base" "$_tree")
  else
    _system_dirs=(/ /Library "/Library/Application Support")
    _managed_dirs=(
      "/Library/Application Support/ClaudeCodeStarterKit"
      "$_base"
      "$_tree"
    )
  fi
  for _dir in "${_system_dirs[@]+"${_system_dirs[@]}"}"; do
    [[ -d "$_dir" && ! -L "$_dir" \
      && "$(_mdm_canonical_dir "$_dir" 2>/dev/null || true)" == "$_dir" \
      && "$(_mdm_stat_uid "$_dir" 2>/dev/null || true)" == 0 ]] \
      || return 1
    _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_dir")")" || return 1
    [[ "$_mode" == 0755 ]] || return 1
    _mdm_has_extended_acl "$_dir" && return 1
  done
  for _dir in "${_managed_dirs[@]+"${_managed_dirs[@]}"}"; do
    [[ -d "$_dir" && ! -L "$_dir" \
      && "$(_mdm_canonical_dir "$_dir" 2>/dev/null || true)" == "$_dir" \
      && "$(_mdm_stat_uid "$_dir" 2>/dev/null || true)" == "$_owner" \
      && "$(_mdm_stat_gid "$_dir" 2>/dev/null || true)" == "$_group" ]] \
      || return 1
    _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_dir")")" || return 1
    [[ "$_mode" == 0755 ]] || return 1
    _mdm_has_extended_acl "$_dir" && return 1
  done
  return 0
}

_mdm_node_runtime_trusted() { # <runtime-tree>
  local _tree="$1" _arch _url _sha _top
  _mdm_node_runtime_ancestors_trusted "$_tree" || return 1
  _mdm_node_runtime_payload_trusted "$_tree" || return 1
  _arch="$(_mdm_node_runtime_arch)" || return 1
  _mdm_node_runtime_source "$_arch" _url _sha _top || return 1
  _mdm_node_runtime_provenance_valid "$_tree" "$_arch" "$_url" "$_sha" \
    || return 1
}

_mdm_node_runtime_archive_sha256() {
  _mdm_sha256_file "$1"
}

_mdm_node_runtime_curl() {
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    /usr/bin/curl "$@"
}

_mdm_node_runtime_curl_quote() {
  local _value="$1"
  [[ ! "$_value" =~ [[:cntrl:]] ]] || return 1
  _value="${_value//\\/\\\\}"
  _value="${_value//\"/\\\"}"
  printf '%s' "$_value"
}

_mdm_node_runtime_download() { # <fixed-url> <destination>
  local _url="$1" _destination="$2" _proxy="" _no_proxy=""
  local _quoted_url _quoted_destination _quoted_proxy="" _quoted_no_proxy=""
  case "$_url" in
    https://nodejs.org/dist/v24.18.0/node-v24.18.0-darwin-arm64.tar.xz|\
    https://nodejs.org/dist/v24.18.0/node-v24.18.0-darwin-x64.tar.xz) : ;;
    *) return 1 ;;
  esac
  [[ "$_destination" == /* && -f "$_destination" \
    && ! -L "$_destination" ]] || return 1
  if [[ -n "${HTTPS_PROXY:-}" ]]; then
    _proxy="$HTTPS_PROXY"
  elif [[ -n "${HTTP_PROXY:-}" ]]; then
    _proxy="$HTTP_PROXY"
  fi
  if [[ -n "$_proxy" ]]; then
    _mdm_root_proxy_url "$_proxy" >/dev/null || return "$MDM_EXIT_CONFIG"
  fi
  if [[ -n "${NO_PROXY:-}" ]]; then
    [[ ! "$NO_PROXY" =~ [[:space:][:cntrl:]] ]] || return "$MDM_EXIT_CONFIG"
    _no_proxy="$NO_PROXY"
  fi
  _quoted_url="$(_mdm_node_runtime_curl_quote "$_url")" || return 1
  _quoted_destination="$(_mdm_node_runtime_curl_quote "$_destination")" || return 1
  [[ -z "$_proxy" ]] \
    || _quoted_proxy="$(_mdm_node_runtime_curl_quote "$_proxy")" || return 1
  [[ -z "$_no_proxy" ]] \
    || _quoted_no_proxy="$(_mdm_node_runtime_curl_quote "$_no_proxy")" || return 1
  (
    # POSIX file-size units are 512-byte blocks.  This bounds a response even
    # when a server omits Content-Length and curl cannot enforce max-filesize
    # before writing.
    ulimit -f 204800 || exit 1
    {
      printf 'url = "%s"\n' "$_quoted_url"
      printf 'output = "%s"\n' "$_quoted_destination"
      printf 'proto = "=https"\nproto-redir = "=https"\n'
      printf 'tlsv1.2\nfail\nsilent\nshow-error\nlocation\n'
      printf 'connect-timeout = 30\nmax-time = 600\nmax-filesize = 104857600\n'
      [[ -z "$_quoted_proxy" ]] || printf 'proxy = "%s"\n' "$_quoted_proxy"
      [[ -z "$_quoted_no_proxy" ]] || printf 'noproxy = "%s"\n' "$_quoted_no_proxy"
    } | _mdm_node_runtime_curl -q --config -
  )
}

_mdm_node_runtime_archive_size_valid() {
  local _identity _size
  _identity="$(_mdm_stat_identity "$1")" || return 1
  case "$_identity" in *:Regular\ File:*|*:regular\ file:*) : ;; *) return 1 ;; esac
  _size="${_identity##*:}"
  [[ "$_size" =~ ^[0-9]+$ && "$_size" -gt 0 && "$_size" -le 104857600 ]]
}

# Validate the complete tar inventory before creating the first child.  The
# extractor strips exactly one pinned top-level directory, creates regular
# files with O_EXCL|O_NOFOLLOW, delays symlinks until every directory/file is
# complete, ignores archive ownership, and never restores ACL/xattr metadata.
_mdm_node_runtime_extract_archive() { # <tar.xz> <empty-destination> <top-name>
  local _archive="$1" _destination="$2" _top="$3" _python _owner _group
  [[ -f "$_archive" && ! -L "$_archive" \
    && -d "$_destination" && ! -L "$_destination" \
    && "$_top" =~ ^node-v[0-9]+\.[0-9]+\.[0-9]+-darwin-(arm64|x64)$ ]] \
    || return 1
  _python="$(_mdm_system_python)" || return 1
  _owner="$(_mdm_node_runtime_owner_uid)" || return 1
  _group="$(_mdm_node_runtime_owner_gid)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_archive" "$_destination" "$_top" \
      "$_owner" "$_group" <<'PY'
import os
import posixpath
import stat
import sys
import tarfile

archive, destination, expected_top = sys.argv[1:4]
expected_uid, expected_gid = int(sys.argv[4]), int(sys.argv[5])
MAX_ENTRIES = 100000
MAX_DEPTH = 256
MAX_FILE = 512 * 1024 * 1024
MAX_TOTAL = 2 * 1024 * 1024 * 1024
PROVENANCE = ".claude-code-starter-kit-node-runtime"


def invalid_text(value):
    return (not isinstance(value, str) or not value
            or any(ord(char) < 32 or 127 <= ord(char) <= 159
                   or 0xD800 <= ord(char) <= 0xDFFF for char in value))


def member_path(member):
    name = member.name[:-1] if member.name.endswith("/") else member.name
    if invalid_text(name) or name.startswith("/") or "\\" in name:
        raise ValueError("invalid archive pathname")
    parts = name.split("/")
    if (not parts or parts[0] != expected_top
            or any(part in ("", ".", "..") for part in parts)):
        raise ValueError("archive pathname escapes pinned root")
    relative = tuple(parts[1:])
    if len(relative) > MAX_DEPTH or (relative and relative[0] == PROVENANCE):
        raise ValueError("reserved or over-deep archive pathname")
    return relative


def safe_link_target(relative, target):
    if invalid_text(target) or target.startswith("/") or "\\" in target:
        raise ValueError("invalid archive symlink")
    stack = list(relative[:-1])
    for part in target.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not stack:
                raise ValueError("archive symlink escapes pinned root")
            stack.pop()
        else:
            stack.append(part)
        if len(stack) > MAX_DEPTH:
            raise ValueError("over-deep archive symlink")
    if not stack:
        raise ValueError("archive symlink resolves to root")
    return tuple(stack)


destination_stat = os.lstat(destination)
if (not stat.S_ISDIR(destination_stat.st_mode)
        or os.path.islink(destination) or os.listdir(destination)):
    raise SystemExit(1)

try:
    with tarfile.open(archive, mode="r:xz") as package:
        members = package.getmembers()
        if not members or len(members) > MAX_ENTRIES:
            raise ValueError("invalid archive entry count")
        records = {}
        total = 0
        for member in members:
            relative = member_path(member)
            if relative in records:
                raise ValueError("duplicate archive pathname")
            if member.mode & ~0o777:
                raise ValueError("unsafe archive permissions")
            pax_names = set(member.pax_headers)
            if any(("acl" in name.lower() or "xattr" in name.lower()
                    or name.startswith("GNU.sparse")) for name in pax_names):
                raise ValueError("archive ACL/xattr/sparse metadata")
            if member.isdir():
                kind = "dir"
            elif member.isreg():
                kind = "file"
                if member.size < 0 or member.size > MAX_FILE:
                    raise ValueError("archive file too large")
                total += member.size
                if total > MAX_TOTAL:
                    raise ValueError("archive aggregate too large")
            elif member.issym():
                kind = "symlink"
            elif member.islnk():
                raise ValueError("archive hardlink")
            else:
                raise ValueError("unsupported archive entry")
            if kind != "symlink" and member.mode & 0o022:
                raise ValueError("writable archive entry")
            records[relative] = (member, kind)

        root_record = records.get(())
        if root_record is None or root_record[1] != "dir":
            raise ValueError("archive root directory is missing")
        for relative, (_, kind) in records.items():
            if not relative:
                continue
            for depth in range(1, len(relative)):
                parent = records.get(relative[:depth])
                if parent is None or parent[1] != "dir":
                    raise ValueError("archive parent is not a directory")
            if kind == "symlink":
                resolved = safe_link_target(relative, records[relative][0].linkname)
                if resolved not in records:
                    raise ValueError("dangling archive symlink")

        directories = sorted(
            ((relative, value[0]) for relative, value in records.items()
             if relative and value[1] == "dir"), key=lambda item: len(item[0]))
        files = sorted(
            ((relative, value[0]) for relative, value in records.items()
             if value[1] == "file"), key=lambda item: item[1].offset_data)
        links = sorted(
            ((relative, value[0]) for relative, value in records.items()
             if value[1] == "symlink"), key=lambda item: item[0])

        for relative, _ in directories:
            target = os.path.join(destination, *relative)
            os.mkdir(target, 0o700)
            os.chown(target, expected_uid, expected_gid, follow_symlinks=False)
        # getmembers() leaves the xz stream at EOF.  Reopen it before payload
        # reads and consume regular files by offset_data so the decompressor
        # only moves forward instead of repeatedly seeking through ~1 GiB of
        # uncompressed release data in pathname order.
        with tarfile.open(archive, mode="r:xz") as payloads:
            for relative, member in files:
                target = os.path.join(destination, *relative)
                source = payloads.extractfile(member)
                if source is None:
                    raise ValueError("archive regular file has no payload")
                descriptor = os.open(
                    target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                    0o600)
                written = 0
                try:
                    os.fchown(descriptor, expected_uid, expected_gid)
                    while True:
                        block = source.read(1024 * 1024)
                        if not block:
                            break
                        view = memoryview(block)
                        while view:
                            count = os.write(descriptor, view)
                            if count <= 0:
                                raise OSError("short archive write")
                            written += count
                            view = view[count:]
                    if written != member.size or source.read(1):
                        raise ValueError("archive payload size mismatch")
                    os.fchmod(descriptor, stat.S_IMODE(member.mode))
                finally:
                    os.close(descriptor)
                    source.close()
        for relative, member in links:
            target = os.path.join(destination, *relative)
            os.symlink(member.linkname, target)
            os.chown(target, expected_uid, expected_gid, follow_symlinks=False)
        for relative, member in sorted(
                directories, key=lambda item: len(item[0]), reverse=True):
            os.chmod(os.path.join(destination, *relative),
                     stat.S_IMODE(member.mode), follow_symlinks=False)
        os.chmod(destination, stat.S_IMODE(root_record[0].mode),
                 follow_symlinks=False)
        os.chown(destination, expected_uid, expected_gid, follow_symlinks=False)
except (OSError, OverflowError, tarfile.TarError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
}

_mdm_node_runtime_write_provenance() { # <tree> <arch> <url> <sha256>
  local _marker="$1/$_MDM_NODE_PROVENANCE_FILE" _owner _group _python
  [[ -d "$1" && ! -L "$1" && ! -e "$_marker" && ! -L "$_marker" ]] \
    || return 1
  if ! ( set -C; umask 022
    _mdm_node_runtime_provenance "$2" "$3" "$4" > "$_marker"
  ) 2>/dev/null; then
    return 1
  fi
  _owner="$(_mdm_node_runtime_owner_uid)" || return 1
  _group="$(_mdm_node_runtime_owner_gid)" || return 1
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_marker" "$_owner" "$_group" <<'PY'
import os
import sys

path, owner, group = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
try:
    os.fchown(descriptor, owner, group)
    os.fchmod(descriptor, 0o444)
finally:
    os.close(descriptor)
PY
}

_mdm_node_runtime_prepare_base() {
  local _base _anchor _support _dir _mode _owner _group
  local _system_dirs=()
  local _dirs=()
  _base="$(_mdm_node_runtime_base)" || return 1
  _owner="$(_mdm_node_runtime_owner_uid)" || return 1
  _group="$(_mdm_node_runtime_owner_gid)" || return 1
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && -n "${MDM_NODE_RUNTIME_ROOT_OVERRIDE:-}" ]]; then
    _anchor="$(/usr/bin/dirname "$_base")"
    _dirs=("$_base")
  else
    _anchor="/Library/Application Support"
    _support="/Library/Application Support/ClaudeCodeStarterKit"
    _system_dirs=(/ /Library "$_anchor")
    _dirs=("$_support" "$_base")
  fi
  [[ -d "$_anchor" && ! -L "$_anchor" \
    && "$(_mdm_canonical_dir "$_anchor" 2>/dev/null || true)" == "$_anchor" ]] \
    || return 1
  _mdm_component_trusted "$_anchor" || return 1
  for _dir in "${_system_dirs[@]+"${_system_dirs[@]}"}"; do
    [[ -d "$_dir" && ! -L "$_dir" \
      && "$(_mdm_canonical_dir "$_dir" 2>/dev/null || true)" == "$_dir" \
      && "$(_mdm_stat_uid "$_dir" 2>/dev/null || true)" == 0 ]] \
      || return 1
    _mdm_component_trusted "$_dir" || return 1
    _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_dir")")" || return 1
    [[ "$_mode" == 0755 ]] || return 1
  done
  for _dir in "${_dirs[@]+"${_dirs[@]}"}"; do
    if [[ -e "$_dir" || -L "$_dir" ]]; then
      [[ -d "$_dir" && ! -L "$_dir" ]] || return 1
    else
      /bin/mkdir -m 0755 "$_dir" || return 1
    fi
    [[ "$(_mdm_canonical_dir "$_dir" 2>/dev/null || true)" == "$_dir" ]] \
      || return 1
    _mdm_wce_runtime_normalize_base_dir "$_dir" "$_owner" "$_group" \
      || return 1
  done
}

_mdm_node_runtime_cleanup_work() { # <work-path>
  local _path="$1" _base _parent _name
  [[ -n "$_path" ]] || return 0
  _base="$(_mdm_node_runtime_base)" || return 1
  _parent="$(/usr/bin/dirname "$_path")"; _name="${_path##*/}"
  [[ "$_parent" == "$_base" ]] || return 1
  case "$_name" in .node-download.*|.node-stage.*) : ;; *) return 1 ;; esac
  [[ "$_path" != "$_base" && "$_path" != / ]] || return 1
  /bin/rm -rf "$_path"
}

_mdm_node_runtime_quarantine_path() {
  local _base _path _old_umask
  _base="$(_mdm_node_runtime_base)" || return 1
  _old_umask="$(umask)"; umask 077
  _path="$(/usr/bin/mktemp -d "$_base/.node-quarantine.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  [[ "$(/usr/bin/dirname "$_path")" == "$_base" \
    && "${_path##*/}" == .node-quarantine.* \
    && -d "$_path" && ! -L "$_path" ]] \
    || return 1
  /bin/rmdir "$_path" || return 1
  [[ ! -e "$_path" && ! -L "$_path" ]] || return 1
  printf '%s' "$_path"
}

_mdm_node_runtime_promote() { # <source> <destination> <operation>
  local _stage="$1" _target="$2" _operation="$3" _rename_operation _base
  _base="$(_mdm_node_runtime_base)" || return 1
  case "$_operation" in
    create|swap)
      [[ "$(/usr/bin/dirname "$_stage")" == "$_base" \
        && "$(/usr/bin/dirname "$_target")" == "$_base" \
        && "${_stage##*/}" == .node-stage.* \
        && "$_target" == "$(_mdm_node_runtime_path)" \
        && -d "$_stage" && ! -L "$_stage" ]] || return 1
      if [[ "$_operation" == create ]]; then
        [[ ! -e "$_target" && ! -L "$_target" ]] || return 1
      else
        [[ -e "$_target" || -L "$_target" ]] || return 1
      fi
      _rename_operation="$_operation" ;;
    retract)
      [[ "$_stage" == "$(_mdm_node_runtime_path)" \
        && "$(/usr/bin/dirname "$_stage")" == "$_base" \
        && "$(/usr/bin/dirname "$_target")" == "$_base" \
        && "${_target##*/}" == .node-stage.* \
        && -d "$_stage" && ! -L "$_stage" \
        && ! -e "$_target" && ! -L "$_target" ]] || return 1
      _rename_operation=create ;;
    quarantine)
      [[ "$_stage" == "$(_mdm_node_runtime_path)" \
        && "$(/usr/bin/dirname "$_stage")" == "$_base" \
        && "$(/usr/bin/dirname "$_target")" == "$_base" \
        && "${_target##*/}" == .node-quarantine.* \
        && ( -e "$_stage" || -L "$_stage" ) \
        && ! -e "$_target" && ! -L "$_target" ]] || return 1
      _rename_operation=create ;;
    restore)
      [[ "$(/usr/bin/dirname "$_stage")" == "$_base" \
        && "${_stage##*/}" == .node-quarantine.* \
        && ( -e "$_stage" || -L "$_stage" ) \
        && "$_target" == "$(_mdm_node_runtime_path)" \
        && "$(/usr/bin/dirname "$_target")" == "$_base" \
        && ! -e "$_target" && ! -L "$_target" ]] || return 1
      _rename_operation=create ;;
    *) return 1 ;;
  esac
  _mdm_node_runtime_atomic_rename \
    "$_stage" "$_target" "$_rename_operation"
}

_mdm_node_runtime_atomic_rename() { # <source> <destination> <create|swap>
  _mdm_node_runtime_atomic_rename_system "$@"
}

_mdm_node_runtime_atomic_rename_system() { # test seam around the syscall only
  local _source="$1" _destination="$2" _operation="$3" _python
  case "$_operation" in create|swap) : ;; *) return 1 ;; esac
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_source" "$_destination" "$_operation" <<'PY'
import ctypes
import os
import sys

source, destination, operation = sys.argv[1:]
libc = ctypes.CDLL(None, use_errno=True)
if sys.platform == "darwin":
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    flags = 4 if operation == "create" else 2  # RENAME_EXCL / RENAME_SWAP
    result = rename(os.fsencode(source), os.fsencode(destination), flags)
elif sys.platform.startswith("linux"):
    rename = libc.renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p,
                       ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    flags = 1 if operation == "create" else 2  # NOREPLACE / EXCHANGE
    result = rename(-100, os.fsencode(source),
                    -100, os.fsencode(destination), flags)
else:
    raise SystemExit(1)
if result != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error))
PY
}

_mdm_node_runtime_user_dir_valid() { # <directory> <target-uid>
  local _dir="$1" _uid="$2" _mode
  [[ "$_uid" =~ ^[0-9]+$ && -d "$_dir" && ! -L "$_dir" ]] || return 1
  [[ "$(_mdm_canonical_dir "$_dir" 2>/dev/null || true)" == "$_dir" \
    && "$(_mdm_stat_uid "$_dir" 2>/dev/null || true)" == "$_uid" ]] \
    || return 1
  _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_dir")")" || return 1
  _mdm_mode_is_safe "$_mode" || return 1
  ! _mdm_has_extended_acl "$_dir"
}

_mdm_node_runtime_activation_valid() { # <user> <home> <target-uid>
  local _user="$1" _home="$2" _uid="$3" _link _target _expected
  local _metadata _rest _links _runtime _arch _value
  [[ -n "$_user" && "$_uid" =~ ^[0-9]+$ ]] || return 1
  _link="$_home/.local/bin/node"
  _expected="$(_mdm_node_runtime_path)/bin/node" || return 1
  _mdm_node_runtime_user_dir_valid "$_home/.local" "$_uid" || return 1
  _mdm_node_runtime_user_dir_valid "$_home/.local/bin" "$_uid" || return 1
  [[ -L "$_link" \
    && "$(_mdm_stat_uid "$_link" 2>/dev/null || true)" == "$_uid" ]] \
    || return 1
  _metadata="$(_mdm_stat_managed_metadata "$_link")" || return 1
  _rest="${_metadata#*:}"; _links="${_rest%%:*}"
  [[ "$_links" == 1 ]] || return 1
  _mdm_has_extended_acl "$_link" && return 1
  _mdm_readlink_exact "$_link" _target || return 1
  [[ "$_target" == "$_expected" ]] || return 1
  _mdm_exec_as_user "$_uid" "$_user" "$_home" /bin/test -x "$_expected" \
    >/dev/null 2>&1 || return 1
  _arch="$(_mdm_node_runtime_arch)" || return 1
  _value="$(_mdm_exec_as_user "$_uid" "$_user" "$_home" \
    "$_expected" --version 2>/dev/null)" || return 1
  [[ "$_value" == "$_MDM_NODE_VERSION" ]] || return 1
  _value="$(_mdm_exec_as_user "$_uid" "$_user" "$_home" \
    "$_expected" -p process.arch 2>/dev/null)" || return 1
  [[ "$_value" == "$_arch" ]] || return 1
  _runtime="${_expected%/bin/node}"
  _value="$(_mdm_exec_as_user "$_uid" "$_user" "$_home" /usr/bin/env \
    "PATH=$_runtime/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$_runtime/bin/npm" --version 2>/dev/null)" || return 1
  [[ "$_value" == "$_MDM_NODE_NPM_VERSION" ]]
}

_mdm_node_runtime_replace_activation() { # <user> <home> <target-uid> <target>
  local _user="$1" _home="$2" _uid="$3" _target="$4" _python
  _python="$(_mdm_target_system_python)" || return 1
  _mdm_exec_as_user "$_uid" "$_user" "$_home" \
    "$_python" -I -B -S -c '
import errno
import os
import secrets
import stat
import sys

directory, target = sys.argv[1:]
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
descriptor = os.open(directory, flags)
temporary = None
try:
    before = os.fstat(descriptor)
    try:
        current = os.stat("node", dir_fd=descriptor, follow_symlinks=False)
    except FileNotFoundError:
        current = None
    if current is not None:
        if (current.st_uid != os.geteuid() or current.st_nlink != 1
                or not (stat.S_ISREG(current.st_mode)
                        or stat.S_ISLNK(current.st_mode))):
            raise SystemExit(1)
    for _ in range(32):
        temporary = ".node.mdm." + secrets.token_hex(12)
        try:
            os.symlink(target, temporary, dir_fd=descriptor)
            break
        except FileExistsError:
            temporary = None
    if temporary is None:
        raise SystemExit(1)
    os.replace(temporary, "node", src_dir_fd=descriptor, dst_dir_fd=descriptor)
    temporary = None
    os.fsync(descriptor)
    after = os.fstat(descriptor)
    if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
        raise SystemExit(1)
finally:
    if temporary is not None:
        try:
            os.unlink(temporary, dir_fd=descriptor)
        except OSError as error:
            if error.errno != errno.ENOENT:
                raise
    os.close(descriptor)
' "$_home/.local/bin" "$_target"
}

_mdm_node_runtime_bind_activation() { # <user> <home> <target-uid>
  local _user="$1" _home="$2" _uid="$3" _local _bin _link _target
  _local="$_home/.local"; _bin="$_local/bin"; _link="$_bin/node"
  _target="$(_mdm_node_runtime_path)/bin/node" || return 1
  if [[ -e "$_link" || -L "$_link" ]]; then
    if _mdm_node_runtime_activation_valid "$_user" "$_home" "$_uid"; then
      return 0
    fi
  fi
  if [[ ! -e "$_local" && ! -L "$_local" ]]; then
    _mdm_exec_as_user "$_uid" "$_user" "$_home" \
      /bin/mkdir -m 0755 "$_local" || return 1
  fi
  _mdm_node_runtime_user_dir_valid "$_local" "$_uid" || return 1
  if [[ ! -e "$_bin" && ! -L "$_bin" ]]; then
    _mdm_exec_as_user "$_uid" "$_user" "$_home" \
      /bin/mkdir -m 0755 "$_bin" || return 1
  fi
  _mdm_node_runtime_user_dir_valid "$_bin" "$_uid" || return 1
  _mdm_node_runtime_replace_activation \
    "$_user" "$_home" "$_uid" "$_target" || return 1
  _mdm_node_runtime_activation_valid "$_user" "$_home" "$_uid"
}

_mdm_node_runtime_rebuild() ( # <target>; unsafe existing leaf is quarantined
  local _target="$1" _base _arch _url _sha _top _archive="" _stage=""
  local _existing=false _existing_safe=false _old_identity="" _stage_identity _current
  local _quarantine="" _quarantine_identity=""
  _base="$(_mdm_node_runtime_base)" || return 1
  _arch="$(_mdm_node_runtime_arch)" || return 1
  _mdm_node_runtime_source "$_arch" _url _sha _top || return 1
  _mdm_node_runtime_prepare_base || return 1
  if [[ -e "$_target" || -L "$_target" ]]; then
    _existing=true
    _old_identity="$(_mdm_stat_identity "$_target")" || return 1
    if _mdm_node_runtime_structure_safe "$_target"; then
      _existing_safe=true
    fi
  fi
  local _old_umask
  _old_umask="$(umask)"; umask 077
  _archive="$(/usr/bin/mktemp "$_base/.node-download.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  _stage="$(/usr/bin/mktemp -d "$_base/.node-stage.XXXXXX")" \
    || { umask "$_old_umask"; _mdm_node_runtime_cleanup_work "$_archive"; return 1; }
  umask "$_old_umask"
  trap '_mdm_node_runtime_cleanup_work "$_archive" || true; _mdm_node_runtime_cleanup_work "$_stage" || true' EXIT
  trap '_mdm_node_runtime_cleanup_work "$_archive" || true; _mdm_node_runtime_cleanup_work "$_stage" || true; exit 1' HUP INT TERM
  _mdm_node_runtime_download "$_url" "$_archive" || return 1
  _mdm_node_runtime_archive_size_valid "$_archive" || return 1
  [[ "$(_mdm_node_runtime_archive_sha256 "$_archive")" == "$_sha" ]] || return 1
  _mdm_node_runtime_extract_archive "$_archive" "$_stage" "$_top" || return 1
  _mdm_node_runtime_write_provenance "$_stage" "$_arch" "$_url" "$_sha" \
    || return 1
  _mdm_node_runtime_trusted "$_stage" || return 1
  _stage_identity="$(_mdm_stat_identity "$_stage")" || return 1
  if [[ "$_existing" == true && "$_existing_safe" == true ]]; then
    _mdm_node_runtime_promote "$_stage" "$_target" swap || return 1
    _current="$(_mdm_stat_identity "$_stage" 2>/dev/null || true)"
    if [[ "$_current" != "$_old_identity" \
      || "$(_mdm_stat_identity "$_target" 2>/dev/null || true)" != "$_stage_identity" ]] \
      || ! _mdm_node_runtime_trusted "$_target"; then
      if ! _mdm_node_runtime_promote "$_stage" "$_target" swap; then
        _stage=""
      fi
      return 1
    fi
  elif [[ "$_existing" == false ]]; then
    _mdm_node_runtime_promote "$_stage" "$_target" create || return 1
    if [[ "$(_mdm_stat_identity "$_target" 2>/dev/null || true)" != "$_stage_identity" ]] \
      || ! _mdm_node_runtime_trusted "$_target"; then
      _mdm_node_runtime_promote "$_target" "$_stage" retract || true
      return 1
    fi
  else
    # Metadata-unsafe or non-directory fixed leaves are never traversed or
    # recursively removed.  Move the exact inode to a root-only sibling name,
    # publish the verified candidate into the now-absent fixed path, and keep
    # the quarantine for forensic/manual cleanup after a successful repair.
    _quarantine="$(_mdm_node_runtime_quarantine_path)" || return 1
    _mdm_node_runtime_promote "$_target" "$_quarantine" quarantine || return 1
    _quarantine_identity="$(_mdm_stat_identity "$_quarantine" 2>/dev/null || true)"
    if [[ "$_quarantine_identity" != "$_old_identity" \
      || -e "$_target" || -L "$_target" ]]; then
      if [[ ! -e "$_target" && ! -L "$_target" \
        && "$_quarantine_identity" == "$_old_identity" ]]; then
        _mdm_node_runtime_promote "$_quarantine" "$_target" restore || true
      fi
      return 1
    fi
    if ! _mdm_node_runtime_promote "$_stage" "$_target" create; then
      _mdm_node_runtime_promote "$_quarantine" "$_target" restore || true
      return 1
    fi
    if [[ "$(_mdm_stat_identity "$_target" 2>/dev/null || true)" \
        != "$_stage_identity" ]] \
      || ! _mdm_node_runtime_trusted "$_target"; then
      if [[ "$(_mdm_stat_identity "$_target" 2>/dev/null || true)" \
        == "$_stage_identity" ]]; then
        _mdm_node_runtime_promote "$_target" "$_stage" retract || true
      fi
      if [[ ! -e "$_target" && ! -L "$_target" \
        && "$(_mdm_stat_identity "$_quarantine" 2>/dev/null || true)" \
          == "$_old_identity" ]]; then
        _mdm_node_runtime_promote "$_quarantine" "$_target" restore || true
      fi
      return 1
    fi
    mdm_log U1b "不正な既存 Node.js runtime leaf を隔離: $_quarantine"
  fi
  _mdm_node_runtime_cleanup_work "$_archive" || return 1
  _archive=""
  _mdm_node_runtime_cleanup_work "$_stage" || return 1
  _stage=""
  trap - EXIT HUP INT TERM
)

_mdm_ensure_node_runtime() { # <user> <home> <target-uid>
  local _user="$1" _home="$2" _uid="$3" _mode _target _euid
  [[ -n "$_user" && "$_home" == /* && "$_uid" =~ ^[0-9]+$ ]] || return 1
  _mode="${KIT_MDM_PREREQ_MODE:-auto}"
  case "$_mode" in auto|fail) : ;; *) return 1 ;; esac
  _target="$(_mdm_node_runtime_path)" || return 1
  _euid="${MDM_EUID_OVERRIDE:-$(/usr/bin/id -u)}"
  if [[ "${_MDM_TEST_MODE:-0}" != 1 && "$_euid" -ne 0 ]]; then
    return 1
  fi
  if [[ "$_mode" == fail ]]; then
    # MDM packages may preseed only the immutable root-owned runtime.  Setup
    # creates the per-user activation link, and the post-setup component
    # attestation binds it before a success receipt is written.
    _mdm_node_runtime_trusted "$_target"
    return
  fi
  if ! _mdm_node_runtime_trusted "$_target"; then
    _mdm_node_runtime_rebuild "$_target" || return 1
  fi
  _mdm_node_runtime_trusted "$_target" || return 1
  _mdm_node_runtime_bind_activation "$_user" "$_home" "$_uid" || return 1
  _mdm_node_runtime_activation_valid "$_user" "$_home" "$_uid"
}

# ── Root-owned web-content-extraction runtime ──────────────────────
# npm is allowed to consume only the authenticated checkout's package files
# with the private Node runtime above.  The published bundle is immutable to
# target users; their skill-local node_modules path is only an activation link.
_MDM_WCE_NODE_VERSION="v24.18.0"
_MDM_WCE_NPM_VERSION="11.16.0"
_MDM_WCE_REGISTRY="https://registry.npmjs.org/"
_MDM_WCE_MARKER_FILE=".claude-code-starter-kit-wce-runtime.json"
_MDM_WCE_RUNTIME_DIGEST=""
_MDM_EXPECTED_WCE_COMPONENT_SHA256=""
_MDM_WCE_PACKAGE_SHA256="e63fb86cb553a034ecafd4ca11334d317b8b5d115775daa728e56c3bf5b1749c"
_MDM_WCE_LOCK_SHA256="f39ea3b4028710e986afb1c423b7895845e0d41839521e6cee866ed37cdb33cd"

_mdm_wce_runtime_owner_uid() {
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && -n "${MDM_WCE_OWNER_UID_OVERRIDE:-}" ]]; then
    [[ "$MDM_WCE_OWNER_UID_OVERRIDE" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$MDM_WCE_OWNER_UID_OVERRIDE"
  else
    printf '0'
  fi
}

_mdm_wce_runtime_owner_gid() {
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && -n "${MDM_WCE_OWNER_GID_OVERRIDE:-}" ]]; then
    [[ "$MDM_WCE_OWNER_GID_OVERRIDE" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$MDM_WCE_OWNER_GID_OVERRIDE"
  else
    printf '0'
  fi
}

_mdm_wce_runtime_hardware_arch() {
  local _arch
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && -n "${MDM_WCE_ARCH_OVERRIDE:-}" ]]; then
    _arch="$MDM_WCE_ARCH_OVERRIDE"
  else
    _arch="$(_mdm_node_runtime_arch)" || return 1
  fi
  case "$_arch" in
    arm64) printf '%s' arm64 ;;
    x64|x86_64) printf '%s' x64 ;;
    *) return 1 ;;
  esac
}

_mdm_wce_runtime_base() {
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && -n "${MDM_WCE_RUNTIME_ROOT_OVERRIDE:-}" ]]; then
    [[ "$MDM_WCE_RUNTIME_ROOT_OVERRIDE" == /* \
      && "$MDM_WCE_RUNTIME_ROOT_OVERRIDE" != / \
      && ! "$MDM_WCE_RUNTIME_ROOT_OVERRIDE" =~ [[:cntrl:]] ]] || return 1
    printf '%s' "$MDM_WCE_RUNTIME_ROOT_OVERRIDE"
  else
    printf '%s' "/Library/Application Support/ClaudeCodeStarterKit/runtime/web-content-extraction"
  fi
}

_mdm_wce_runtime_source_paths() { # <package-out-var> <lock-out-var>
  local _package_out="$1" _lock_out="$2" _checkout _package_path _lock_path
  [[ "$_package_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_lock_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_package_out" != "$_lock_out" ]] || return 1
  _checkout="${_MDM_AUTH_CHECKOUT:-}"
  [[ "$_checkout" == /* && -d "$_checkout" && ! -L "$_checkout" ]] || return 1
  _package_path="$_checkout/skills/web-content-extraction/package.json"
  _lock_path="$_checkout/skills/web-content-extraction/package-lock.json"
  [[ -f "$_package_path" && ! -L "$_package_path" \
    && -f "$_lock_path" && ! -L "$_lock_path" ]] || return 1
  [[ "$(_mdm_canonical_file "$_package_path")" == "$_package_path" \
    && "$(_mdm_canonical_file "$_lock_path")" == "$_lock_path" ]] || return 1
  printf -v "$_package_out" '%s' "$_package_path"
  printf -v "$_lock_out" '%s' "$_lock_path"
}

_mdm_wce_runtime_source_hashes() { # <package-sha-out-var> <lock-sha-out-var>
  local _package_out="$1" _lock_out="$2" _source_package _source_lock
  local _package_sha_value _lock_sha_value _owner
  [[ "$_package_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_lock_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ \
    && "$_package_out" != "$_lock_out" ]] || return 1
  _mdm_wce_runtime_source_paths _source_package _source_lock || return 1
  _owner="$(_mdm_auth_expected_uid)" || return 1
  _mdm_artifact_digest file "$_source_package" "$_owner" >/dev/null || return 1
  _mdm_artifact_digest file "$_source_lock" "$_owner" >/dev/null || return 1
  _package_sha_value="$(_mdm_sha256_file "$_source_package")" || return 1
  _lock_sha_value="$(_mdm_sha256_file "$_source_lock")" || return 1
  [[ "$_package_sha_value" =~ ^[0-9a-f]{64}$ \
    && "$_lock_sha_value" =~ ^[0-9a-f]{64}$ \
    && "$_package_sha_value" == "$_MDM_WCE_PACKAGE_SHA256" \
    && "$_lock_sha_value" == "$_MDM_WCE_LOCK_SHA256" ]] || return 1
  printf -v "$_package_out" '%s' "$_package_sha_value"
  printf -v "$_lock_out" '%s' "$_lock_sha_value"
}

_mdm_wce_runtime_path() { # [package-sha256 lock-sha256]
  local _package_sha_value="${1:-}" _lock_sha_value="${2:-}" _arch _base
  if [[ -z "$_package_sha_value" && -z "$_lock_sha_value" ]]; then
    _package_sha_value="$_MDM_WCE_PACKAGE_SHA256"
    _lock_sha_value="$_MDM_WCE_LOCK_SHA256"
  fi
  [[ "$#" -eq 0 || "$#" -eq 2 ]] || return 1
  [[ "$_package_sha_value" =~ ^[0-9a-f]{64}$ \
    && "$_lock_sha_value" =~ ^[0-9a-f]{64}$ ]] || return 1
  _arch="$(_mdm_wce_runtime_hardware_arch)" || return 1
  _base="$(_mdm_wce_runtime_base)" || return 1
  printf '%s/node-%s-npm-v%s-darwin-%s/%s-%s' \
    "$_base" "$_MDM_WCE_NODE_VERSION" "$_MDM_WCE_NPM_VERSION" "$_arch" \
    "$_package_sha_value" "$_lock_sha_value"
}

_mdm_wce_runtime_json_contract_valid() { # <package.json> <lock> <pkg-sha> <lock-sha>
  local _package="$1" _lock="$2" _package_sha="$3" _lock_sha="$4" _python
  [[ -f "$_package" && ! -L "$_package" && -f "$_lock" && ! -L "$_lock" \
    && "$_package_sha" =~ ^[0-9a-f]{64}$ \
    && "$_lock_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$(_mdm_sha256_file "$_package")" == "$_package_sha" \
    && "$(_mdm_sha256_file "$_lock")" == "$_lock_sha" ]] || return 1
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_package" "$_lock" <<'PY'
import base64
import json
import re
import sys
import urllib.parse

package_path, lock_path = sys.argv[1:]

def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
        value[key] = item
    return value

def load(path):
    if not 0 < __import__("os").stat(path).st_size <= 4 * 1024 * 1024:
        raise ValueError("invalid JSON size")
    with open(path, "r", encoding="utf-8", errors="strict") as handle:
        return json.load(handle, object_pairs_hook=unique_object)

def dependency_sources_safe(value):
    if value is None:
        return
    if type(value) is not dict:
        raise ValueError("dependency map is not an object")
    for name, spec in value.items():
        if (type(name) is not str or type(spec) is not str or not name or not spec
                or re.search(r"(?:^|[+])git(?:\+|:)|^file:|^https?://|^github:|^\.\.?/", spec,
                             re.IGNORECASE)):
            raise ValueError("untrusted dependency source")

try:
    package = load(package_path)
    lock = load(lock_path)
    if type(package) is not dict or package.get("private") is not True:
        raise ValueError("package must be private")
    if (type(package.get("name")) is not str
            or type(package.get("version")) is not str
            or type(package.get("dependencies")) is not dict
            or not package["dependencies"]):
        raise ValueError("invalid package metadata")
    dependency_sources_safe(package.get("dependencies"))
    dependency_sources_safe(package.get("optionalDependencies"))
    if (type(lock) is not dict or lock.get("lockfileVersion") != 3
            or type(lock.get("packages")) is not dict
            or type(lock.get("name")) is not str
            or type(lock.get("version")) is not str):
        raise ValueError("invalid lockfile v3")
    root = lock["packages"].get("")
    if (type(root) is not dict or root.get("name") != package["name"]
            or root.get("version") != package["version"]
            or root.get("dependencies") != package["dependencies"]):
        raise ValueError("package/lock root mismatch")
    if lock["name"] != package["name"] or lock["version"] != package["version"]:
        raise ValueError("package/lock identity mismatch")
    for key, metadata in lock["packages"].items():
        if type(key) is not str or type(metadata) is not dict:
            raise ValueError("invalid package entry")
        dependency_sources_safe(metadata.get("dependencies"))
        dependency_sources_safe(metadata.get("optionalDependencies"))
        if "link" in metadata or "hasInstallScript" in metadata:
            raise ValueError("links/install scripts are forbidden")
        if key == "":
            continue
        if (not key.startswith("node_modules/") and "/node_modules/" not in key
                or "\\" in key or "/../" in "/" + key + "/"
                or "/./" in "/" + key + "/" or "//" in key):
            raise ValueError("invalid lock package path")
        resolved = metadata.get("resolved")
        integrity = metadata.get("integrity")
        if type(metadata.get("version")) is not str or type(resolved) is not str:
            raise ValueError("missing pinned package metadata")
        parsed = urllib.parse.urlsplit(resolved)
        if (parsed.scheme != "https" or parsed.hostname != "registry.npmjs.org"
                or parsed.port is not None or parsed.username is not None
                or parsed.password is not None or parsed.query or parsed.fragment
                or not parsed.path.startswith("/") or not parsed.path.endswith(".tgz")
                or not resolved.startswith("https://registry.npmjs.org/")):
            raise ValueError("non-registry package source")
        if type(integrity) is not str or not re.fullmatch(r"sha512-[A-Za-z0-9+/]+={0,2}", integrity):
            raise ValueError("invalid package integrity")
        decoded = base64.b64decode(integrity[7:], validate=True)
        if len(decoded) != 64:
            raise ValueError("integrity is not sha512")
except (OSError, UnicodeError, ValueError, json.JSONDecodeError, TypeError):
    raise SystemExit(1)
PY
}

_mdm_wce_runtime_marker_json() { # <arch> <package-sha> <lock-sha>
  [[ "$1" == arm64 || "$1" == x64 ]] || return 1
  [[ "$2" =~ ^[0-9a-f]{64}$ && "$3" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '{"arch":"%s","lock_sha256":"%s","node_version":"%s","npm_version":"%s","package_sha256":"%s","registry":"%s","schema_version":1}\n' \
    "$1" "$3" "$_MDM_WCE_NODE_VERSION" "$_MDM_WCE_NPM_VERSION" "$2" \
    "$_MDM_WCE_REGISTRY"
}

_mdm_wce_runtime_marker_valid() { # <bundle> <arch> <package-sha> <lock-sha>
  local _marker="$1/$_MDM_WCE_MARKER_FILE" _python
  [[ -f "$_marker" && ! -L "$_marker" ]] || return 1
  [[ "$2" == arm64 || "$2" == x64 ]] || return 1
  [[ "$3" =~ ^[0-9a-f]{64}$ && "$4" =~ ^[0-9a-f]{64}$ ]] || return 1
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_marker" "$2" "$3" "$4" \
      "$_MDM_WCE_NODE_VERSION" "$_MDM_WCE_NPM_VERSION" \
      "$_MDM_WCE_REGISTRY" <<'PY'
import json
import os
import stat
import sys

path, arch, package_sha, lock_sha, node_version, npm_version, registry = sys.argv[1:]
expected = (json.dumps({
    "arch": arch,
    "lock_sha256": lock_sha,
    "node_version": node_version,
    "npm_version": npm_version,
    "package_sha256": package_sha,
    "registry": registry,
    "schema_version": 1,
}, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii")

def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
            value.st_gid, value.st_nlink, value.st_size, value.st_mtime_ns,
            value.st_ctime_ns)

try:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                or before.st_size != len(expected)):
            raise ValueError("unsafe marker")
        actual = b""
        while len(actual) < len(expected) + 1:
            block = os.read(descriptor, len(expected) + 1 - len(actual))
            if not block:
                break
            actual += block
        after = os.fstat(descriptor)
        current = os.stat(path, follow_symlinks=False)
        if (actual != expected or identity(before) != identity(after)
                or identity(before) != identity(current)):
            raise ValueError("marker changed")
    finally:
        os.close(descriptor)
except (OSError, ValueError):
    raise SystemExit(1)
PY
}

_mdm_wce_runtime_dir_metadata_valid() {
  # <directory> <owner-uid> <owner-gid> <allow-xattr|allow-provenance>
  local _dir="$1" _owner="$2" _group="$3" _xattr_policy="$4" _python
  [[ "$_owner" =~ ^[0-9]+$ && "$_group" =~ ^[0-9]+$ ]] || return 1
  case "$_xattr_policy" in allow-xattr|allow-provenance) : ;; *) return 1 ;; esac
  _mdm_has_extended_acl "$_dir" && return 1
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_dir" "$_owner" "$_group" \
      "$_xattr_policy" <<'PY'
import ctypes
import errno
import os
import stat
import sys

path, uid_raw, gid_raw, xattr_policy = sys.argv[1:]
uid, gid = int(uid_raw), int(gid_raw)
libc = ctypes.CDLL(None, use_errno=True)

try:
    value = os.lstat(path)
    if (not stat.S_ISDIR(value.st_mode)
            or stat.S_IMODE(value.st_mode) != 0o755
            or value.st_uid != uid or value.st_gid != gid):
        raise ValueError("unsafe WCE directory")
    if xattr_policy == "allow-provenance":
        raw = os.fsencode(path)
        ctypes.set_errno(0)
        if sys.platform == "darwin":
            libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p,
                                       ctypes.c_size_t, ctypes.c_int]
            libc.listxattr.restype = ctypes.c_ssize_t
            size = libc.listxattr(raw, None, 0, 1)
        else:
            libc.llistxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p,
                                        ctypes.c_size_t]
            libc.llistxattr.restype = ctypes.c_ssize_t
            size = libc.llistxattr(raw, None, 0)
        if size < 0:
            error = ctypes.get_errno()
            raise OSError(error or errno.EIO, "listxattr")
        if size:
            buffer = ctypes.create_string_buffer(size)
            actual = (libc.listxattr(raw, buffer, size, 1)
                      if sys.platform == "darwin"
                      else libc.llistxattr(raw, buffer, size))
            if actual != size:
                raise OSError(ctypes.get_errno() or errno.EIO, "listxattr")
            names = {name for name in bytes(buffer[:actual]).split(b"\0") if name}
            if names - {b"com.apple.provenance"}:
                raise ValueError("WCE directory has an unapproved xattr")
except (OSError, ValueError, ctypes.ArgumentError):
    raise SystemExit(1)
PY
}

_mdm_wce_runtime_ancestors_trusted() { # <bundle> <owner-uid> <owner-gid>
  local _bundle="$1" _owner="$2" _group="$3" _base _version _expected _dir
  local _support _runtime
  local _managed_dirs=()
  _base="$(_mdm_wce_runtime_base)" || return 1
  _expected="$(_mdm_wce_runtime_path \
    "$_MDM_WCE_PACKAGE_SHA256" "$_MDM_WCE_LOCK_SHA256")" || return 1
  _version="${_expected%/*}"
  case "$_bundle" in
    "$_expected") : ;;
    "$_version"/.wce-stage.*)
      [[ "${_bundle%/*}" == "$_version" \
        && "${_bundle##*/}" =~ ^\.wce-stage\.[A-Za-z0-9]+$ ]] || return 1 ;;
    *) return 1 ;;
  esac
  if [[ "${_MDM_TEST_MODE:-0}" != 1 \
    || -z "${MDM_WCE_RUNTIME_ROOT_OVERRIDE:-}" ]]; then
    for _dir in / /Library "/Library/Application Support"; do
      [[ "$(_mdm_canonical_dir "$_dir" 2>/dev/null || true)" == "$_dir" ]] \
        || return 1
      _mdm_component_trusted "$_dir" || return 1
      [[ "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_dir")")" == 0755 ]] \
        || return 1
    done
    _mdm_verify_dir_chain "$_base" "/Library/Application Support" || return 1
    _support="/Library/Application Support/ClaudeCodeStarterKit"
    _runtime="$_support/runtime"
    _managed_dirs=("$_support" "$_runtime" "$_base" "$_version")
  else
    _managed_dirs=("$_base" "$_version")
  fi
  for _dir in "${_managed_dirs[@]}"; do
    [[ "$(_mdm_canonical_dir "$_dir" 2>/dev/null || true)" == "$_dir" ]] \
      || return 1
    _mdm_wce_runtime_dir_metadata_valid "$_dir" "$_owner" "$_group" \
      allow-xattr || return 1
  done
  [[ "$(_mdm_canonical_dir "$_bundle" 2>/dev/null || true)" == "$_bundle" ]] \
    || return 1
  _mdm_wce_runtime_dir_metadata_valid \
    "$_bundle" "$_owner" "$_group" allow-provenance
}

_mdm_wce_runtime_metadata_valid() { # <bundle> <owner-uid> <owner-gid>
  local _bundle="$1" _owner="$2" _group="$3" _python
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_bundle" "$_owner" "$_group" \
      "$_MDM_WCE_MARKER_FILE" <<'PY'
import ctypes
import json
import os
import re
import stat
import sys

root, uid_raw, gid_raw, marker = sys.argv[1:]
uid, gid = int(uid_raw), int(gid_raw)
expected = {marker, "package.json", "package-lock.json", "node_modules"}
libc = ctypes.CDLL(None, use_errno=True)

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result

def load_json(path):
    value = os.lstat(path)
    if (not stat.S_ISREG(value.st_mode) or value.st_nlink != 1
            or not 0 < value.st_size <= 4 * 1024 * 1024):
        raise ValueError("unsafe JSON file")
    with open(path, "r", encoding="utf-8", errors="strict") as handle:
        return json.load(handle, object_pairs_hook=unique_object)

def dependency_parts(name):
    if type(name) is not str or not name or "\\" in name:
        raise ValueError("invalid dependency name")
    parts = name.split("/")
    if name.startswith("@"):
        if len(parts) != 2:
            raise ValueError("invalid scoped dependency")
        parts[0] = parts[0][1:]
    elif len(parts) != 1:
        raise ValueError("invalid dependency path")
    for part in parts:
        if (part in ("", ".", "..")
                or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._~-]*", part)):
            raise ValueError("invalid dependency segment")
    if name.startswith("@"):
        parts[0] = "@" + parts[0]
    return parts

def xattrs_allowed(path):
    raw = os.fsencode(path)
    if sys.platform == "darwin":
        call = libc.listxattr
        call.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                         ctypes.c_int]
        call.restype = ctypes.c_ssize_t
        size = call(raw, None, 0, 1)  # XATTR_NOFOLLOW
        if size < 0:
            raise OSError(ctypes.get_errno(), "listxattr")
        if not size:
            return True
        buffer = ctypes.create_string_buffer(size)
        actual = call(raw, buffer, size, 1)
    else:
        call = libc.llistxattr
        call.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t]
        call.restype = ctypes.c_ssize_t
        size = call(raw, None, 0)
        if size < 0:
            raise OSError(ctypes.get_errno(), "listxattr")
        if not size:
            return True
        buffer = ctypes.create_string_buffer(size)
        actual = call(raw, buffer, size)
    if actual != size:
        raise OSError(ctypes.get_errno(), "listxattr")
    names = {name for name in bytes(buffer[:actual]).split(b"\0") if name}
    return not (names - {b"com.apple.provenance"})

try:
    if set(os.listdir(root)) != expected:
        raise ValueError("bundle inventory mismatch")
    package_path = os.path.join(root, "package.json")
    lock_path = os.path.join(root, "package-lock.json")
    package = load_json(package_path)
    lock = load_json(lock_path)
    if (type(package) is not dict or type(lock) is not dict
            or type(package.get("name")) is not str
            or type(package.get("version")) is not str
            or type(package.get("dependencies")) is not dict
            or not package["dependencies"]):
        raise ValueError("invalid installed package gate")
    for name in package["dependencies"]:
        dependency = os.path.join(root, "node_modules", *dependency_parts(name))
        dependency_json = os.path.join(dependency, "package.json")
        dependency_value = os.lstat(dependency)
        package_value = os.lstat(dependency_json)
        if (not stat.S_ISDIR(dependency_value.st_mode)
                or not stat.S_ISREG(package_value.st_mode)
                or package_value.st_nlink != 1):
            raise ValueError("direct dependency missing")
    count = 0
    for directory, dirs, files in os.walk(root, topdown=True, followlinks=False):
        for path in [directory] + [os.path.join(directory, value)
                                   for value in dirs + files]:
            value = os.lstat(path)
            count += 1
            if (count > 100000 or value.st_uid != uid or value.st_gid != gid
                    or not xattrs_allowed(path)):
                raise ValueError("unsafe metadata")
            mode = stat.S_IMODE(value.st_mode)
            if stat.S_ISDIR(value.st_mode):
                if mode != 0o755:
                    raise ValueError("invalid directory mode")
            elif stat.S_ISREG(value.st_mode):
                if value.st_nlink != 1 or mode not in (0o644, 0o755):
                    raise ValueError("invalid file metadata")
            else:
                raise ValueError("links and special files are forbidden")
    for name in (marker, "package.json", "package-lock.json"):
        value = os.lstat(os.path.join(root, name))
        if stat.S_IMODE(value.st_mode) != 0o644:
            raise ValueError("invalid fixed-file mode")
    if count < 9:
        raise ValueError("empty runtime")
except (OSError, UnicodeError, TypeError, ValueError, json.JSONDecodeError,
        ctypes.ArgumentError):
    raise SystemExit(1)
PY
}

_mdm_wce_runtime_trusted() { # <bundle> [package-sha lock-sha]
  local _bundle="$1" _package_sha="${2:-}" _lock_sha="${3:-}" _expected
  local _arch _owner _group _before _after
  _MDM_WCE_RUNTIME_DIGEST=""
  if [[ -z "$_package_sha" && -z "$_lock_sha" ]]; then
    _package_sha="$_MDM_WCE_PACKAGE_SHA256"
    _lock_sha="$_MDM_WCE_LOCK_SHA256"
  fi
  [[ "$#" -eq 1 || "$#" -eq 3 ]] || return 1
  [[ "$_package_sha" =~ ^[0-9a-f]{64}$ && "$_lock_sha" =~ ^[0-9a-f]{64}$ ]] \
    || return 1
  _expected="$(_mdm_wce_runtime_path "$_package_sha" "$_lock_sha")" || return 1
  case "$_bundle" in
    "$_expected"|"${_expected%/*}"/.wce-stage.*) : ;;
    *) return 1 ;;
  esac
  [[ -d "$_bundle" && ! -L "$_bundle" \
    && "$(_mdm_canonical_dir "$_bundle")" == "$_bundle" ]] || return 1
  _arch="$(_mdm_wce_runtime_hardware_arch)" || return 1
  _owner="$(_mdm_wce_runtime_owner_uid)" || return 1
  _group="$(_mdm_wce_runtime_owner_gid)" || return 1
  _mdm_wce_runtime_ancestors_trusted \
    "$_bundle" "$_owner" "$_group" || return 1
  _before="$(_mdm_artifact_digest tree "$_bundle" "$_owner" "$_group")" \
    || return 1
  _mdm_wce_runtime_metadata_valid "$_bundle" "$_owner" "$_group" || return 1
  _mdm_wce_runtime_marker_valid "$_bundle" "$_arch" "$_package_sha" \
    "$_lock_sha" || return 1
  _mdm_wce_runtime_json_contract_valid "$_bundle/package.json" \
    "$_bundle/package-lock.json" "$_package_sha" "$_lock_sha" || return 1
  _after="$(_mdm_artifact_digest tree "$_bundle" "$_owner" "$_group")" \
    || return 1
  [[ "$_after" == "$_before" ]] || return 1
  _MDM_WCE_RUNTIME_DIGEST="$_after"
}

_mdm_wce_runtime_user_dir_valid() {
  # <directory> <target-uid> <user> <home>
  _mdm_node_runtime_user_dir_valid "$1" "$2" \
    && _mdm_component_target_dir_accessible "$1" "$2" "$3" "$4"
}

_mdm_wce_runtime_activation_valid() { # <user> <home> <uid> <bundle>
  local _user="$1" _home="$2" _uid="$3" _bundle="$4"
  local _claude _skills _skill _link _expected _metadata _rest _links _target
  [[ -n "$_user" && "$_home" == /* && "$_uid" =~ ^[0-9]+$ \
    && "$_bundle" == /* && ! "$_bundle" =~ [[:cntrl:]] ]] || return 1
  _claude="$_home/.claude"
  _skills="$_claude/skills"
  _skill="$_skills/web-content-extraction"
  _link="$_skill/node_modules"
  _expected="$_bundle/node_modules"
  # The home directory can carry the standard macOS deny-delete ACL, so bind
  # its owner/mode/effective searchability without imposing the child-dir ACL
  # policy.  This keeps the issuer aligned with the detector's activation
  # boundary and prevents a success receipt for an unsafe/unsearchable home.
  _mdm_component_target_dir_accessible \
    "$_home" "$_uid" "$_user" "$_home" || return 1
  _mdm_wce_runtime_user_dir_valid \
    "$_claude" "$_uid" "$_user" "$_home" || return 1
  _mdm_wce_runtime_user_dir_valid \
    "$_skills" "$_uid" "$_user" "$_home" || return 1
  _mdm_wce_runtime_user_dir_valid \
    "$_skill" "$_uid" "$_user" "$_home" || return 1
  [[ -d "$_bundle" && ! -L "$_bundle" \
    && -d "$_expected" && ! -L "$_expected" ]] || return 1
  [[ -L "$_link" && "$(_mdm_stat_uid "$_link" 2>/dev/null || true)" == "$_uid" ]] \
    || return 1
  _metadata="$(_mdm_stat_managed_metadata "$_link")" || return 1
  _rest="${_metadata#*:}"; _links="${_rest%%:*}"
  [[ "$_links" == 1 ]] || return 1
  _mdm_has_extended_acl "$_link" && return 1
  _mdm_readlink_exact "$_link" _target || return 1
  [[ "$_target" == "$_expected" ]] || return 1
  _mdm_exec_as_user "$_uid" "$_user" "$_home" \
    /bin/test -r "$_expected" >/dev/null 2>&1 \
    && _mdm_exec_as_user "$_uid" "$_user" "$_home" \
      /bin/test -x "$_expected" >/dev/null 2>&1
}

_mdm_wce_runtime_normalize_base_dir() { # <directory> <owner-uid> <owner-gid>
  local _dir="$1" _owner="$2" _group="$3" _python
  [[ "$_owner" =~ ^[0-9]+$ && "$_group" =~ ^[0-9]+$ ]] || return 1
  [[ -d "$_dir" && ! -L "$_dir" ]] || return 1
  # Existing root-owned parents created below /Library/Application Support
  # commonly inherit its admin group on macOS.  Accept only a non-writable,
  # ACL-free directory owned by the expected authority, then bind and
  # normalize that exact inode to the root:wheel managed contract.
  _mdm_has_extended_acl "$_dir" && return 1
  _python="$(_mdm_system_python)" || return 1
  if ! /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_dir" "$_owner" "$_group" <<'PY'
import os
import stat
import sys

path, uid_raw, gid_raw = sys.argv[1:]
uid, gid = int(uid_raw), int(gid_raw)

try:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        current = os.stat(path, follow_symlinks=False)
        if ((before.st_dev, before.st_ino) != (current.st_dev, current.st_ino)
                or not stat.S_ISDIR(before.st_mode)
                or before.st_uid != uid
                or stat.S_IMODE(before.st_mode) & 0o7022):
            raise ValueError("unsafe WCE managed directory")
        os.fchown(descriptor, uid, gid)
        os.fchmod(descriptor, 0o755)
        os.fsync(descriptor)
        after = os.fstat(descriptor)
        current = os.stat(path, follow_symlinks=False)
        if ((after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
                or (current.st_dev, current.st_ino)
                    != (before.st_dev, before.st_ino)
                or after.st_uid != uid or after.st_gid != gid
                or stat.S_IMODE(after.st_mode) != 0o755):
            raise ValueError("WCE directory normalization drift")
    finally:
        os.close(descriptor)
except (OSError, ValueError):
    raise SystemExit(1)
PY
  then
    return 1
  fi
  ! _mdm_has_extended_acl "$_dir"
}

_mdm_wce_runtime_prepare_base() {
  local _base _target _version _owner _group _dir
  local _support _runtime
  local _dirs=()
  _base="$(_mdm_wce_runtime_base)" || return 1
  _target="$(_mdm_wce_runtime_path)" || return 1
  _version="${_target%/*}"
  _owner="$(_mdm_wce_runtime_owner_uid)" || return 1
  _group="$(_mdm_wce_runtime_owner_gid)" || return 1
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && -n "${MDM_WCE_RUNTIME_ROOT_OVERRIDE:-}" ]]; then
    _dir="$(/usr/bin/dirname "$_base")"
    [[ -d "$_dir" && ! -L "$_dir" \
      && "$(_mdm_canonical_dir "$_dir" 2>/dev/null || true)" == "$_dir" ]] \
      || return 1
    _dirs=("$_base" "$_version")
  else
    for _dir in / /Library "/Library/Application Support"; do
      [[ -d "$_dir" && ! -L "$_dir" \
        && "$(_mdm_canonical_dir "$_dir" 2>/dev/null || true)" == "$_dir" ]] \
        || return 1
      _mdm_component_trusted "$_dir" || return 1
      [[ "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_dir")")" == 0755 ]] \
        || return 1
    done
    _support="/Library/Application Support/ClaudeCodeStarterKit"
    _runtime="$_support/runtime"
    _dirs=("$_support" "$_runtime" "$_base" "$_version")
  fi
  for _dir in "${_dirs[@]}"; do
    if [[ -e "$_dir" || -L "$_dir" ]]; then
      [[ -d "$_dir" && ! -L "$_dir" ]] || return 1
    else
      /bin/mkdir -m 0755 "$_dir" || return 1
    fi
    _mdm_wce_runtime_normalize_base_dir \
      "$_dir" "$_owner" "$_group" || return 1
    [[ "$(_mdm_canonical_dir "$_dir" 2>/dev/null || true)" == "$_dir" ]] \
      || return 1
    _mdm_wce_runtime_dir_metadata_valid \
      "$_dir" "$_owner" "$_group" allow-xattr || return 1
  done
}

_mdm_wce_runtime_cleanup_work() { # <stage-or-work-path>
  local _path="$1" _target _version _parent _name
  [[ -n "$_path" ]] || return 0
  _target="$(_mdm_wce_runtime_path)" || return 1
  _version="${_target%/*}"
  _parent="$(/usr/bin/dirname "$_path")"
  _name="${_path##*/}"
  [[ "$_parent" == "$_version" && "$_path" != "$_version" \
    && "$_path" != / ]] || return 1
  case "$_name" in .wce-stage.*|.wce-work.*) : ;; *) return 1 ;; esac
  /bin/rm -rf "$_path"
}

_mdm_wce_runtime_quarantine_path() {
  local _target _version _path _old_umask
  _target="$(_mdm_wce_runtime_path)" || return 1
  _version="${_target%/*}"
  _old_umask="$(umask)"; umask 077
  _path="$(/usr/bin/mktemp -d "$_version/.wce-quarantine.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  [[ "$(/usr/bin/dirname "$_path")" == "$_version" \
    && "${_path##*/}" == .wce-quarantine.* \
    && -d "$_path" && ! -L "$_path" ]] || return 1
  /bin/rmdir "$_path" || return 1
  [[ ! -e "$_path" && ! -L "$_path" ]] || return 1
  printf '%s' "$_path"
}

_mdm_wce_runtime_promote() { # <source> <destination> <create|quarantine|restore|retract>
  local _source="$1" _destination="$2" _operation="$3"
  local _target _version
  _target="$(_mdm_wce_runtime_path)" || return 1
  _version="${_target%/*}"
  case "$_operation" in
    create)
      [[ "$(/usr/bin/dirname "$_source")" == "$_version" \
        && "${_source##*/}" == .wce-stage.* \
        && "$_destination" == "$_target" \
        && -d "$_source" && ! -L "$_source" \
        && ! -e "$_destination" && ! -L "$_destination" ]] || return 1 ;;
    quarantine)
      [[ "$_source" == "$_target" \
        && ( -e "$_source" || -L "$_source" ) \
        && "$(/usr/bin/dirname "$_destination")" == "$_version" \
        && "${_destination##*/}" == .wce-quarantine.* \
        && ! -e "$_destination" && ! -L "$_destination" ]] || return 1 ;;
    restore)
      [[ "$(/usr/bin/dirname "$_source")" == "$_version" \
        && "${_source##*/}" == .wce-quarantine.* \
        && ( -e "$_source" || -L "$_source" ) \
        && "$_destination" == "$_target" \
        && ! -e "$_destination" && ! -L "$_destination" ]] || return 1 ;;
    retract)
      [[ "$_source" == "$_target" \
        && -d "$_source" && ! -L "$_source" \
        && "$(/usr/bin/dirname "$_destination")" == "$_version" \
        && "${_destination##*/}" == .wce-stage.* \
        && ! -e "$_destination" && ! -L "$_destination" ]] || return 1 ;;
    *) return 1 ;;
  esac
  _mdm_node_runtime_atomic_rename_system \
    "$_source" "$_destination" create
}

_mdm_wce_runtime_copy_sources() { # <stage> <package-sha> <lock-sha>
  local _stage="$1" _package_sha="$2" _lock_sha="$3"
  local _source_package _source_lock _owner _group _python
  _mdm_wce_runtime_source_paths _source_package _source_lock || return 1
  _owner="$(_mdm_wce_runtime_owner_uid)" || return 1
  _group="$(_mdm_wce_runtime_owner_gid)" || return 1
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_stage" "$_owner" "$_group" \
      "$_source_package" package.json "$_source_lock" package-lock.json <<'PY'
import os
import stat
import sys

stage, uid_raw, gid_raw, *sources = sys.argv[1:]
uid, gid = int(uid_raw), int(gid_raw)

def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
            value.st_gid, value.st_nlink, value.st_size, value.st_mtime_ns,
            value.st_ctime_ns)

try:
    if len(sources) != 4:
        raise ValueError("invalid source list")
    for source, name in zip(sources[::2], sources[1::2]):
        destination = os.path.join(stage, name)
        source_fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
        destination_fd = None
        try:
            before = os.fstat(source_fd)
            if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                    or not 0 < before.st_size <= 4 * 1024 * 1024):
                raise ValueError("unsafe package source")
            destination_fd = os.open(
                destination,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600)
            os.fchown(destination_fd, uid, gid)
            while True:
                block = os.read(source_fd, 1024 * 1024)
                if not block:
                    break
                view = memoryview(block)
                while view:
                    written = os.write(destination_fd, view)
                    if written <= 0:
                        raise OSError("short package write")
                    view = view[written:]
            os.fchmod(destination_fd, 0o644)
            os.fsync(destination_fd)
            after = os.fstat(source_fd)
            current = os.stat(source, follow_symlinks=False)
            if identity(before) != identity(after) or identity(before) != identity(current):
                raise ValueError("package source changed")
        finally:
            if destination_fd is not None:
                os.close(destination_fd)
            os.close(source_fd)
except (OSError, ValueError):
    raise SystemExit(1)
PY
  _mdm_wce_runtime_json_contract_valid "$_stage/package.json" \
    "$_stage/package-lock.json" "$_package_sha" "$_lock_sha"
}

_mdm_wce_runtime_write_marker() { # <stage> <arch> <package-sha> <lock-sha>
  local _stage="$1" _marker _owner _group _python
  _marker="$_stage/$_MDM_WCE_MARKER_FILE"
  [[ -d "$_stage" && ! -L "$_stage" \
    && ! -e "$_marker" && ! -L "$_marker" ]] || return 1
  if ! ( set -C; umask 077
    _mdm_wce_runtime_marker_json "$2" "$3" "$4" > "$_marker"
  ) 2>/dev/null; then
    return 1
  fi
  _owner="$(_mdm_wce_runtime_owner_uid)" || return 1
  _group="$(_mdm_wce_runtime_owner_gid)" || return 1
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_marker" "$_owner" "$_group" <<'PY'
import os
import sys

path, uid_raw, gid_raw = sys.argv[1:]
try:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        os.fchown(descriptor, int(uid_raw), int(gid_raw))
        os.fchmod(descriptor, 0o644)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
except OSError:
    raise SystemExit(1)
PY
}

_mdm_wce_runtime_normalize_stage() { # <stage>
  local _stage="$1" _owner _group _python
  _owner="$(_mdm_wce_runtime_owner_uid)" || return 1
  _group="$(_mdm_wce_runtime_owner_gid)" || return 1
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_stage" "$_owner" "$_group" <<'PY'
import ctypes
import errno
import os
import stat
import sys

root, uid_raw, gid_raw = sys.argv[1:]
uid, gid = int(uid_raw), int(gid_raw)
allowed_xattrs = {"com.apple.provenance"}
count = 0

def xattrs_allowed(path):
    raw = os.fsencode(path)
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        call = libc.listxattr
        call.argtypes = [ctypes.c_char_p, ctypes.c_void_p,
                         ctypes.c_size_t, ctypes.c_int]
        call.restype = ctypes.c_ssize_t
        size = call(raw, None, 0, 1)  # XATTR_NOFOLLOW
        if size < 0:
            raise OSError(ctypes.get_errno() or errno.EIO, "listxattr")
        if not size:
            return True
        buffer = ctypes.create_string_buffer(size)
        actual = call(raw, buffer, size, 1)
    else:
        call = libc.llistxattr
        call.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t]
        call.restype = ctypes.c_ssize_t
        size = call(raw, None, 0)
        if size < 0:
            raise OSError(ctypes.get_errno() or errno.EIO, "listxattr")
        if not size:
            return True
        buffer = ctypes.create_string_buffer(size)
        actual = call(raw, buffer, size)
    if actual != size:
        raise OSError(ctypes.get_errno() or errno.EIO, "listxattr")
    names = {os.fsdecode(name) for name in bytes(buffer[:actual]).split(b"\0")
             if name}
    return not (names - allowed_xattrs)

try:
    for directory, dirs, files in os.walk(root, topdown=True, followlinks=False):
        for path in [directory] + [os.path.join(directory, name)
                                   for name in dirs + files]:
            value = os.lstat(path)
            count += 1
            if count > 100000:
                raise ValueError("runtime too large")
            if not xattrs_allowed(path):
                raise ValueError("unapproved xattr")
            if stat.S_ISDIR(value.st_mode):
                mode = 0o755
            elif stat.S_ISREG(value.st_mode):
                if value.st_nlink != 1:
                    raise ValueError("hardlinked runtime file")
                mode = 0o755 if stat.S_IMODE(value.st_mode) & 0o111 else 0o644
            else:
                raise ValueError("links and special files are forbidden")
            os.chown(path, uid, gid, follow_symlinks=False)
            os.chmod(path, mode, follow_symlinks=False)
    if count < 9:
        raise ValueError("empty runtime")
except (OSError, TypeError, ValueError, ctypes.ArgumentError):
    raise SystemExit(1)
PY
}

_mdm_wce_runtime_npm_command() { # test seam for the exact npm process
  "$@"
}

_mdm_wce_runtime_npm_exec() {
  _mdm_run_with_timeout "$(_mdm_timeout_seconds \
    "$_MDM_TIMEOUT_WCE_NPM_SECONDS")" _mdm_wce_runtime_npm_command "$@"
}

_mdm_wce_runtime_npm_ci() { # <stage> <work-directory>
  local _stage="$1" _work="$2" _target _version _node_root _node _npm_cli
  local _proxy_key _proxy_value
  local _clean_env=()
  _target="$(_mdm_wce_runtime_path)" || return 1
  _version="${_target%/*}"
  [[ "$(/usr/bin/dirname "$_stage")" == "$_version" \
    && "${_stage##*/}" == .wce-stage.* \
    && "$(/usr/bin/dirname "$_work")" == "$_version" \
    && "${_work##*/}" == .wce-work.* \
    && -d "$_stage" && ! -L "$_stage" \
    && -d "$_work" && ! -L "$_work" ]] || return 1
  _node_root="$(_mdm_node_runtime_path)" || return 1
  _mdm_node_runtime_trusted "$_node_root" || return 1
  _node="$_node_root/bin/node"
  _npm_cli="$_node_root/lib/node_modules/npm/bin/npm-cli.js"
  [[ -x "$_node" && -f "$_npm_cli" && ! -L "$_npm_cli" ]] || return 1
  /bin/mkdir -m 0700 "$_work/home" "$_work/cache" "$_work/tmp" || return 1
  ( umask 077
    : > "$_work/user.npmrc"
    : > "$_work/global.npmrc"
  ) || return 1
  _clean_env=(/usr/bin/env -i
    "HOME=$_work/home"
    "TMPDIR=$_work/tmp"
    "USER=root"
    "LOGNAME=root"
    "PATH=$_node_root/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    "LC_ALL=C"
    "LANG=C"
    "npm_config_cache=$_work/cache"
    "npm_config_registry=$_MDM_WCE_REGISTRY"
    "npm_config_userconfig=$_work/user.npmrc"
    "npm_config_globalconfig=$_work/global.npmrc"
    "npm_config_update_notifier=false")
  for _proxy_key in HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    _proxy_value="${!_proxy_key:-}"
    [[ -n "$_proxy_value" ]] || continue
    if [[ "$_proxy_key" == NO_PROXY ]]; then
      [[ ! "$_proxy_value" =~ [[:space:][:cntrl:]] ]] || return "$MDM_EXIT_CONFIG"
    else
      _mdm_root_proxy_url "$_proxy_value" >/dev/null \
        || return "$MDM_EXIT_CONFIG"
    fi
    _clean_env[${#_clean_env[@]}]="$_proxy_key=$_proxy_value"
  done
  mdm_log U1b "固定 lock から web-content-extraction runtime を構築"
  ( builtin cd -P "$_stage" \
    && _mdm_wce_runtime_npm_exec "${_clean_env[@]}" \
      "$_node" "$_npm_cli" ci \
      --omit=dev --ignore-scripts --no-bin-links --no-audit --no-fund \
      "--registry=$_MDM_WCE_REGISTRY" ) >/dev/null 2>&1
}

_mdm_wce_runtime_rebuild() ( # <exact-target>; invalid old leaf is quarantined
  local _target="$1" _expected _version _arch _package_sha _lock_sha
  local _post_package_sha _post_lock_sha
  local _stage="" _work="" _stage_identity _old_identity=""
  local _quarantine="" _quarantine_identity="" _old_umask
  _expected="$(_mdm_wce_runtime_path)" || return 1
  [[ "$_target" == "$_expected" ]] || return 1
  _version="${_target%/*}"
  _arch="$(_mdm_wce_runtime_hardware_arch)" || return 1
  _mdm_wce_runtime_source_hashes _package_sha _lock_sha || return 1
  _mdm_wce_runtime_prepare_base || return 1
  _mdm_node_runtime_trusted "$(_mdm_node_runtime_path)" || return 1
  _old_umask="$(umask)"; umask 077
  _stage="$(/usr/bin/mktemp -d "$_version/.wce-stage.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  _work="$(/usr/bin/mktemp -d "$_version/.wce-work.XXXXXX")" \
    || { umask "$_old_umask"; _mdm_wce_runtime_cleanup_work "$_stage"; return 1; }
  umask "$_old_umask"
  trap '_mdm_wce_runtime_cleanup_work "$_work" || true; _mdm_wce_runtime_cleanup_work "$_stage" || true' EXIT
  trap '_mdm_stop_active_timeout_supervisor HUP || true; _mdm_wce_runtime_cleanup_work "$_work" || true; _mdm_wce_runtime_cleanup_work "$_stage" || true; exit 129' HUP
  trap '_mdm_stop_active_timeout_supervisor INT || true; _mdm_wce_runtime_cleanup_work "$_work" || true; _mdm_wce_runtime_cleanup_work "$_stage" || true; exit 130' INT
  trap '_mdm_stop_active_timeout_supervisor TERM || true; _mdm_wce_runtime_cleanup_work "$_work" || true; _mdm_wce_runtime_cleanup_work "$_stage" || true; exit 143' TERM
  _mdm_wce_runtime_copy_sources "$_stage" "$_package_sha" "$_lock_sha" \
    || return 1
  _mdm_wce_runtime_npm_ci "$_stage" "$_work" || return 1
  _mdm_wce_runtime_write_marker \
    "$_stage" "$_arch" "$_package_sha" "$_lock_sha" || return 1
  _mdm_wce_runtime_normalize_stage "$_stage" || return 1
  _mdm_wce_runtime_source_hashes _post_package_sha _post_lock_sha || return 1
  [[ "$_post_package_sha" == "$_package_sha" \
    && "$_post_lock_sha" == "$_lock_sha" ]] || return 1
  _mdm_wce_runtime_trusted "$_stage" "$_package_sha" "$_lock_sha" \
    || return 1
  _stage_identity="$(_mdm_stat_identity "$_stage")" || return 1
  if [[ -e "$_target" || -L "$_target" ]]; then
    _old_identity="$(_mdm_stat_identity "$_target")" || return 1
    _quarantine="$(_mdm_wce_runtime_quarantine_path)" || return 1
    _mdm_wce_runtime_promote "$_target" "$_quarantine" quarantine || return 1
    _quarantine_identity="$(_mdm_stat_identity "$_quarantine" 2>/dev/null || true)"
    if [[ "$_quarantine_identity" != "$_old_identity" \
      || -e "$_target" || -L "$_target" ]]; then
      if [[ ! -e "$_target" && ! -L "$_target" \
        && "$_quarantine_identity" == "$_old_identity" ]]; then
        _mdm_wce_runtime_promote "$_quarantine" "$_target" restore || true
      fi
      return 1
    fi
  fi
  if ! _mdm_wce_runtime_promote "$_stage" "$_target" create; then
    [[ -z "$_quarantine" ]] \
      || _mdm_wce_runtime_promote "$_quarantine" "$_target" restore || true
    return 1
  fi
  if [[ "$(_mdm_stat_identity "$_target" 2>/dev/null || true)" \
      != "$_stage_identity" ]] \
    || ! _mdm_wce_runtime_trusted "$_target" "$_package_sha" "$_lock_sha"; then
    if [[ "$(_mdm_stat_identity "$_target" 2>/dev/null || true)" \
      == "$_stage_identity" ]]; then
      _mdm_wce_runtime_promote "$_target" "$_stage" retract || true
    fi
    if [[ -n "$_quarantine" && ! -e "$_target" && ! -L "$_target" \
      && "$(_mdm_stat_identity "$_quarantine" 2>/dev/null || true)" \
        == "$_old_identity" ]]; then
      _mdm_wce_runtime_promote "$_quarantine" "$_target" restore || true
    fi
    return 1
  fi
  _stage=""
  if [[ -n "$_quarantine" ]]; then
    mdm_log U1b "不正な既存 web-content-extraction runtime leaf を隔離: $_quarantine"
  fi
  _mdm_wce_runtime_cleanup_work "$_work" || return 1
  _work=""
  trap - EXIT HUP INT TERM
)

_mdm_wce_runtime_capture_verified() { # <exact-target>
  local _target="$1"
  _MDM_WCE_VERIFIED_BUNDLE=""
  _MDM_EXPECTED_WCE_COMPONENT_SHA256=""
  _MDM_WCE_RUNTIME_DIGEST=""
  [[ "$_target" == "$(_mdm_wce_runtime_path)" ]] || return 1
  _mdm_wce_runtime_trusted "$_target" || return 1
  [[ "${_MDM_WCE_RUNTIME_DIGEST:-}" =~ ^[0-9a-f]{64}$ ]] || return 1
  _MDM_WCE_VERIFIED_BUNDLE="$_target"
  _MDM_EXPECTED_WCE_COMPONENT_SHA256="$_MDM_WCE_RUNTIME_DIGEST"
}

_mdm_wce_runtime_validate_existing() { # <user> <home> <target-uid>
  local _user="$1" _home="$2" _uid="$3" _target _package_sha _lock_sha
  [[ -n "$_user" && "$_home" == /* && "$_uid" =~ ^[0-9]+$ ]] || return 1
  _mdm_wce_runtime_source_hashes _package_sha _lock_sha || return 1
  _mdm_node_runtime_trusted "$(_mdm_node_runtime_path)" || return 1
  _target="$(_mdm_wce_runtime_path "$_package_sha" "$_lock_sha")" || return 1
  _mdm_wce_runtime_capture_verified "$_target" || return 1
  _mdm_wce_runtime_activation_valid "$_user" "$_home" "$_uid" "$_target"
}

_mdm_wce_runtime_activation_previewable() { # <user> <home> <uid> <bundle>
  local _user="$1" _home="$2" _uid="$3" _bundle="$4"
  local _dir _link _metadata _rest _links _mode
  [[ -n "$_user" && "$_home" == /* && "$_uid" =~ ^[0-9]+$ ]] || return 1
  _mdm_component_target_dir_accessible \
    "$_home" "$_uid" "$_user" "$_home" || return 1
  for _dir in "$_home/.claude" "$_home/.claude/skills" \
    "$_home/.claude/skills/web-content-extraction"; do
    if [[ ! -e "$_dir" && ! -L "$_dir" ]]; then
      # setup will create this directory and every remaining descendant.
      return 0
    fi
    _mdm_wce_runtime_user_dir_valid \
      "$_dir" "$_uid" "$_user" "$_home" || return 1
  done
  _link="$_home/.claude/skills/web-content-extraction/node_modules"
  [[ -e "$_link" || -L "$_link" ]] || return 0
  _mdm_wce_runtime_activation_valid \
    "$_user" "$_home" "$_uid" "$_bundle" && return 0
  # Match deploy.sh's atomic repair boundary. A safe real directory is the
  # normal non-MDM npm layout and will be atomically retained under a random
  # pre-MDM backup name while the activation symlink is published.
  [[ "$(_mdm_stat_uid "$_link" 2>/dev/null || true)" == "$_uid" ]] || return 1
  _metadata="$(_mdm_stat_managed_metadata "$_link")" || return 1
  _rest="${_metadata#*:}"; _links="${_rest%%:*}"; _mode="${_rest#*:}"
  _mdm_has_extended_acl "$_link" && return 1
  if [[ -d "$_link" && ! -L "$_link" ]]; then
    _mdm_mode_is_safe "$_mode"
    return
  fi
  [[ "$_links" == 1 ]] || return 1
  # Symlink mode bits are non-portable and do not control traversal.  Match
  # deploy.sh's replacement boundary: owner, ACL and link count are the
  # relevant properties for an atomically replaceable symlink.
  [[ -L "$_link" ]] && return 0
  [[ -f "$_link" && ! -L "$_link" ]] || return 1
  _mdm_mode_is_safe "$_mode"
}

_mdm_wce_runtime_validate_dryrun() { # <user> <home> <target-uid>
  local _user="$1" _home="$2" _uid="$3" _target _package_sha _lock_sha
  [[ -n "$_user" && "$_home" == /* && "$_uid" =~ ^[0-9]+$ ]] || return 1
  _mdm_wce_runtime_source_hashes _package_sha _lock_sha || return 1
  _mdm_node_runtime_trusted "$(_mdm_node_runtime_path)" || return 1
  _target="$(_mdm_wce_runtime_path "$_package_sha" "$_lock_sha")" || return 1
  _mdm_wce_runtime_capture_verified "$_target" || return 1
  # setup --dry-run intentionally does not apply the user activation change.
  # Accept absent or safely replaceable leaves as planned remediation only.
  _mdm_wce_runtime_activation_previewable \
    "$_user" "$_home" "$_uid" "$_target"
}

_mdm_ensure_wce_runtime() { # <user> <home> <target-uid>
  local _user="$1" _home="$2" _uid="$3" _mode _target _euid
  local _package_sha _lock_sha
  [[ -n "$_user" && "$_home" == /* && "$_uid" =~ ^[0-9]+$ ]] || return 1
  _mode="${KIT_MDM_PREREQ_MODE:-auto}"
  case "$_mode" in auto|fail) : ;; *) return 1 ;; esac
  _euid="${MDM_EUID_OVERRIDE:-$(/usr/bin/id -u)}"
  if [[ "${_MDM_TEST_MODE:-0}" != 1 && "$_euid" -ne 0 ]]; then
    return 1
  fi
  if [[ "$_mode" == fail ]]; then
    _mdm_wce_runtime_source_hashes _package_sha _lock_sha || return 1
    _mdm_node_runtime_trusted "$(_mdm_node_runtime_path)" || return 1
    _target="$(_mdm_wce_runtime_path "$_package_sha" "$_lock_sha")" || return 1
    # A package may preseed only the immutable root-owned bundle.  Setup owns
    # the per-user activation link and the post-setup root check binds both.
    _mdm_wce_runtime_capture_verified "$_target"
    return
  fi
  _mdm_wce_runtime_source_hashes _package_sha _lock_sha || return 1
  _mdm_node_runtime_trusted "$(_mdm_node_runtime_path)" || return 1
  _target="$(_mdm_wce_runtime_path "$_package_sha" "$_lock_sha")" || return 1
  if ! _mdm_wce_runtime_capture_verified "$_target"; then
    _mdm_wce_runtime_rebuild "$_target" || return 1
    _mdm_wce_runtime_capture_verified "$_target" || return 1
  fi
}

_MDM_COMPONENT_ENTRIES=""
_MDM_COMPONENT_TARGET_UID=""
_mdm_component_append_entry() { # <component> <path> <file|tree> [expected-sha256]
  local _component="$1" _path="$2" _kind="$3" _expected="${4:-}"
  local _digest _before _after
  case "$_component" in
    biome|claude_cli|fonts|ghostty|kit|node_runtime|safety_net|web_content_runtime) : ;;
    *) return 1 ;;
  esac
  case "$_kind" in file|tree) : ;; *) return 1 ;; esac
  [[ "$_path" == /* && ! "$_path" =~ [[:cntrl:]] ]] || return 1
  [[ -z "$_expected" || "$_expected" =~ ^[0-9a-f]{64}$ ]] || return 1
  _before="$(_mdm_stat_identity "$_path")" || return 1
  local _owner_csv="${_MDM_COMPONENT_TARGET_UID:-}" _group_csv=""
  case "$_component" in
    ghostty) [[ -z "$_owner_csv" ]] || _owner_csv="0,$_owner_csv" ;;
    node_runtime|web_content_runtime) _owner_csv=0; _group_csv=0 ;;
  esac
  _digest="$(_mdm_artifact_digest \
    "$_kind" "$_path" "$_owner_csv" "$_group_csv")" || return 1
  [[ "$_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  _after="$(_mdm_stat_identity "$_path")" || return 1
  [[ "$_after" == "$_before" \
    && ( -z "$_expected" || "$_digest" == "$_expected" ) ]] || return 1
  printf '{"component":"%s","path":"%s","kind":"%s","sha256":"%s"}\n' \
    "$_component" "$(mdm_json_escape "$_path")" "$_kind" "$_digest" \
    >> "$_MDM_COMPONENT_ENTRIES"
}

_mdm_component_sort_entries() { # <json-lines-file>
  local _input="$1" _python _sorted _old_umask
  [[ -f "$_input" && ! -L "$_input" ]] || return 1
  _python="$(_mdm_system_python)" || return 1
  _old_umask="$(umask)"; umask 077
  _sorted="$(/usr/bin/mktemp "$(_mdm_safe_tmpdir)/claude-kit-mdm-components-sort.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  if ! /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_input" > "$_sorted" <<'PY'
import json
import re
import sys

source = sys.argv[1]
allowed = {
    "biome", "claude_cli", "fonts", "ghostty", "kit", "node_runtime",
    "safety_net", "web_content_runtime",
}
records = []

def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate object key")
        value[key] = item
    return value

with open(source, "r", encoding="utf-8", errors="strict") as handle:
    for line in handle:
        if not line.endswith("\n") or not line.strip():
            raise SystemExit(1)
        value = json.loads(line, object_pairs_hook=unique_object)
        if set(value) != {"component", "path", "kind", "sha256"}:
            raise SystemExit(1)
        if value["component"] not in allowed or value["kind"] not in ("file", "tree"):
            raise SystemExit(1)
        if not isinstance(value["path"], str) or not value["path"].startswith("/"):
            raise SystemExit(1)
        if any(ord(char) < 32 or 127 <= ord(char) <= 159
               or 0xD800 <= ord(char) <= 0xDFFF for char in value["path"]):
            raise SystemExit(1)
        if not isinstance(value["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", value["sha256"]):
            raise SystemExit(1)
        records.append(value)
if not records or len(records) > 1000:
    raise SystemExit(1)
records.sort(key=lambda value: (value["component"].encode("ascii"),
                                value["path"].encode("utf-8"),
                                value["kind"].encode("ascii"),
                                value["sha256"].encode("ascii")))
seen = set()
for value in records:
    identity = (value["component"], value["path"])
    if identity in seen:
        raise SystemExit(1)
    seen.add(identity)
    print(json.dumps(value, ensure_ascii=True, sort_keys=True,
                     separators=(",", ":")))
PY
  then
    /bin/rm -f "$_sorted"
    return 1
  fi
  /bin/chmod 600 "$_sorted" || { /bin/rm -f "$_sorted"; return 1; }
  /bin/mv -f "$_sorted" "$_input"
}

_mdm_component_effective_paths() {
  # <target-uid> <user> <home> <-r|-x> <absolute-path>...
  local _uid="$1" _user="$2" _home="$3" _test="$4"; shift 4
  local _path
  [[ "$_uid" =~ ^[0-9]+$ && -n "$_user" && "$_home" == /* \
    && "$#" -ge 1 ]] || return 1
  case "$_test" in -r|-x) : ;; *) return 1 ;; esac
  for _path in "$@"; do
    [[ "$_path" == /* && ! "$_path" =~ [[:cntrl:]] ]] || return 1
  done
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && "$(/usr/bin/id -u 2>/dev/null || true)" == "$_uid" ]]; then
    for _path in "$@"; do
      /bin/test "$_test" "$_path" || return 1
    done
    return 0
  fi
  _mdm_exec_as_user "$_uid" "$_user" "$_home" \
    /bin/bash --noprofile --norc -c '
      _test=$1; shift
      for _path do /bin/test "$_test" "$_path" || exit 1; done
    ' mdm-component-access "$_test" "$@"
}

_mdm_component_effective_test() { # <uid> <user> <home> <-r|-x> <path>
  _mdm_component_effective_paths "$@"
}

_mdm_component_target_dir_accessible() { # <dir> <uid> <user> <home>
  local _dir="$1" _uid="$2" _user="$3" _home="$4" _before _after _mode
  [[ "$_uid" =~ ^[0-9]+$ && -d "$_dir" && ! -L "$_dir" ]] || return 1
  [[ "$(_mdm_canonical_dir "$_dir" 2>/dev/null || true)" == "$_dir" \
    && "$(_mdm_stat_uid "$_dir" 2>/dev/null || true)" == "$_uid" ]] \
    || return 1
  _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_dir")")" || return 1
  _mdm_mode_is_safe "$_mode" || return 1
  _mdm_user_dir_acl_safe "$_dir" || return 1
  _before="$(_mdm_persistent_dir_identity "$_dir")" || return 1
  case "$_before" in *:Directory|*:directory) : ;; *) return 1 ;; esac
  _mdm_component_effective_test \
    "$_uid" "$_user" "$_home" -x "$_dir" || return 1
  _after="$(_mdm_persistent_dir_identity "$_dir")" || return 1
  [[ "$_after" == "$_before" \
    && "$(_mdm_canonical_dir "$_dir" 2>/dev/null || true)" == "$_dir" \
    && "$(_mdm_stat_uid "$_dir" 2>/dev/null || true)" == "$_uid" ]] \
    || return 1
  _mode="$(_mdm_mode_normalize \
    "$(_mdm_stat_mode "$_dir" 2>/dev/null || true)")" || return 1
  _mdm_mode_is_safe "$_mode" || return 1
  _mdm_user_dir_acl_safe "$_dir" || return 1
  [[ "$(_mdm_persistent_dir_identity "$_dir" 2>/dev/null || true)" \
    == "$_before" ]]
}

_mdm_component_ancestors_searchable() { # <path> <uid> <user> <home>
  local _path="$1" _uid="$2" _user="$3" _home="$4" _current
  local _ancestors=()
  [[ "$_path" == /* && "$_home" == /* && "$_home" != / \
    && "$_uid" =~ ^[0-9]+$ ]] || return 1
  _current="${_path%/*}"; [[ -n "$_current" ]] || _current=/
  while :; do
    [[ -d "$_current" && ! -L "$_current" ]] || return 1
    case "$_current" in
      "$_home"|"$_home"/*)
        _mdm_component_target_dir_accessible \
          "$_current" "$_uid" "$_user" "$_home" || return 1 ;;
      *)
        # Effective search alone is insufficient: an allow-write ACE can make
        # an otherwise 0755 ancestor replaceable by another principal.  Keep
        # the same exact ACL contract as target-owned directories (no ACL, or
        # macOS's single non-inheriting everyone deny-delete entry).
        _mdm_user_dir_acl_safe "$_current" || return 1 ;;
    esac
    _ancestors[${#_ancestors[@]}]="$_current"
    [[ "$_current" == / ]] && break
    _current="${_current%/*}"; [[ -n "$_current" ]] || _current=/
  done
  _mdm_component_effective_paths \
    "$_uid" "$_user" "$_home" -x "${_ancestors[@]}"
}

_mdm_component_path_accessible() { # <path> <uid> <user> <home>
  _mdm_component_ancestors_searchable "$@" \
    && _mdm_component_effective_test "$2" "$3" "$4" -x "$1"
}

_mdm_component_tree_accessible() { # <tree> <uid> <user> <home>
  [[ -d "$1" && ! -L "$1" ]] || return 1
  _mdm_component_ancestors_searchable "$@" \
    && ! _mdm_has_extended_acl "$1" \
    && _mdm_component_effective_test "$2" "$3" "$4" -r "$1" \
    && _mdm_component_effective_test "$2" "$3" "$4" -x "$1"
}

_mdm_component_file_readable() { # <file> <uid> <user> <home>
  [[ -f "$1" && ! -L "$1" ]] || return 1
  _mdm_component_ancestors_searchable "$@" \
    && ! _mdm_has_extended_acl "$1" \
    && _mdm_component_effective_test "$2" "$3" "$4" -r "$1"
}

_mdm_component_resolve_command() { # <uid> <user> <home> <name> <output-var>
  local _uid="$1" _user="$2" _home="$3" _name="$4" _out_var="$5"
  local _path _canonical _mode
  [[ "$_name" =~ ^[A-Za-z0-9._+-]+$ \
    && "$_out_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  _path="$(_mdm_exec_as_user "$_uid" "$_user" "$_home" \
    /bin/bash --noprofile --norc -c 'command -v "$1"' mdm-component "$_name")" \
    || return 1
  [[ "$_path" == /* && ! "$_path" =~ [[:cntrl:]] ]] || return 1
  _canonical="$(_mdm_canonical_any "$_path")" || return 1
  [[ -f "$_canonical" && ! -L "$_canonical" ]] || return 1
  _mode="$(_mdm_stat_mode "$_canonical")" || return 1
  _mdm_mode_owner_executable "$_mode" || return 1
  _mdm_exec_as_user "$_uid" "$_user" "$_home" /bin/test -x "$_canonical" \
    >/dev/null 2>&1 || return 1
  printf -v "$_out_var" '%s' "$_canonical"
}

_mdm_component_fixed_executable() { # <uid> <user> <home> <path> <output-var>
  local _uid="$1" _user="$2" _home="$3" _path="$4" _out_var="$5"
  local _canonical _mode
  [[ "$_path" == /* && "$_out_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  _canonical="$(_mdm_canonical_any "$_path")" || return 1
  [[ -f "$_canonical" && ! -L "$_canonical" \
    && "$(_mdm_stat_uid "$_canonical" || true)" == "$_uid" ]] || return 1
  _mode="$(_mdm_stat_mode "$_canonical")" || return 1
  _mdm_mode_owner_executable "$_mode" || return 1
  _mdm_exec_as_user "$_uid" "$_user" "$_home" /bin/test -x "$_canonical" \
    >/dev/null 2>&1 || return 1
  printf -v "$_out_var" '%s' "$_canonical"
}

_mdm_component_cli_target() { # <user> <home> <target-uid> <output-var>
  local _user="$1" _home="$2" _uid="$3" _out_var="$4"
  local _link _target _canonical _version _dir
  local _metadata _metadata_rest _links _mode
  [[ -n "$_user" && "$_uid" =~ ^[0-9]+$ \
    && "$_out_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || return 1
  _link="$_home/.local/bin/claude"
  for _dir in "$_home" "$_home/.local" "$_home/.local/bin" \
    "$_home/.local/share" "$_home/.local/share/claude" \
    "$_home/.local/share/claude/versions"; do
    _mdm_component_target_dir_accessible \
      "$_dir" "$_uid" "$_user" "$_home" || return 1
  done
  [[ -L "$_link" && "$(_mdm_stat_uid "$_link" 2>/dev/null || true)" == "$_uid" ]] \
    || return 1
  _mdm_has_extended_acl "$_link" && return 1
  _metadata="$(_mdm_stat_managed_metadata "$_link")" || return 1
  _metadata_rest="${_metadata#*:}"; _links="${_metadata_rest%%:*}"
  [[ "$_links" == 1 ]] || return 1
  _mdm_readlink_exact "$_link" _target || return 1
  case "$_target" in "$_home/.local/share/claude/versions"/*) : ;; *) return 1 ;; esac
  _version="${_target#"$_home/.local/share/claude/versions"/}"
  [[ -n "$_version" && "$_version" != */* \
    && "$_version" =~ ^[0-9A-Za-z._+-]+$ ]] || return 1
  _canonical="$(_mdm_canonical_file "$_target")" || return 1
  [[ "$_canonical" == "$_target" \
    && "$(_mdm_stat_uid "$_canonical" 2>/dev/null || true)" == "$_uid" ]] \
    || return 1
  _mode="$(_mdm_stat_mode "$_canonical")" || return 1
  _mdm_mode_owner_executable "$_mode" || return 1
  _mdm_component_path_accessible \
    "$_link" "$_uid" "$_user" "$_home" || return 1
  _mdm_component_path_accessible \
    "$_canonical" "$_uid" "$_user" "$_home" || return 1
  printf -v "$_out_var" '%s' "$_canonical"
}

_mdm_component_fixed_launcher() {
  # <uid> <user> <home> <component-dir> <version> <executable-relative> <out>
  local _uid="$1" _user="$2" _home="$3" _component="$4" _version="$5"
  local _relative="$6" _out_var="$7" _tree _link _expected_link _canonical
  local _mode _meta _rest _links _dir
  [[ "$_component" =~ ^[a-z0-9-]+$ \
    && "$_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
    && "$_relative" != /* && "$_relative" != *..* \
    && ! "$_relative" =~ [[:cntrl:]] \
    && "$_out_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  _tree="$_home/.local/lib/claude-code-starter-kit/$_component/$_version"
  _link="$_home/.local/bin/$_component"
  _expected_link="../lib/claude-code-starter-kit/$_component/$_version/$_relative"
  [[ -d "$_tree" && ! -L "$_tree" && -L "$_link" ]] || return 1
  for _dir in "$_home" "$_home/.local" "$_home/.local/bin" \
    "$_home/.local/lib" "$_home/.local/lib/claude-code-starter-kit" \
    "${_tree%/*}" "$_tree"; do
    _mdm_component_target_dir_accessible \
      "$_dir" "$_uid" "$_user" "$_home" || return 1
  done
  _dir="${_tree}/$_relative"; _dir="${_dir%/*}"
  while [[ "$_dir" != "$_tree" ]]; do
    _mdm_component_target_dir_accessible \
      "$_dir" "$_uid" "$_user" "$_home" || return 1
    _dir="${_dir%/*}"
  done
  _mdm_component_tree_accessible \
    "$_tree" "$_uid" "$_user" "$_home" || return 1
  local _link_value
  _mdm_readlink_exact "$_link" _link_value || return 1
  [[ "$_link_value" == "$_expected_link" \
    && "$(_mdm_stat_uid "$_link" || true)" == "$_uid" ]] || return 1
  _mdm_has_extended_acl "$_link" && return 1
  _meta="$(_mdm_stat_managed_metadata "$_link")" || return 1
  _rest="${_meta#*:}"; _links="${_rest%%:*}"
  [[ "$_links" == 1 ]] || return 1
  _canonical="$(_mdm_canonical_any "$_link")" || return 1
  [[ "$_canonical" == "$_tree/$_relative" \
    && -f "$_canonical" && ! -L "$_canonical" \
    && "$(_mdm_stat_uid "$_canonical" || true)" == "$_uid" ]] || return 1
  _mode="$(_mdm_stat_mode "$_canonical")" || return 1
  _mdm_mode_owner_executable "$_mode" || return 1
  _mdm_component_path_accessible \
    "$_link" "$_uid" "$_user" "$_home" || return 1
  _mdm_component_path_accessible \
    "$_canonical" "$_uid" "$_user" "$_home" || return 1
  printf -v "$_out_var" '%s' "$_canonical"
}

_mdm_component_private_tree_shape_is_exact() { # <biome|safety_net> <tree>
  local _component="$1" _root="$2" _python
  case "$_component" in biome|safety_net) : ;; *) return 1 ;; esac
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_component" "$_root" <<'PY'
import os
import stat
import sys

component, root = sys.argv[1:]
try:
    if component == "biome":
        expected = {"": {"biome", "package.json"}}
        files = {"biome", "package.json"}
        directories = set()
    else:
        expected = {
            "": {"bin", "dist", "package.json"},
            "bin": {"cc-safety-net"},
            "dist": {"bin"},
            "dist/bin": {"cc-safety-net.js"},
        }
        files = {
            "bin/cc-safety-net", "dist/bin/cc-safety-net.js", "package.json",
        }
        directories = {"bin", "dist", "dist/bin"}
    if not stat.S_ISDIR(os.lstat(root).st_mode):
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

_mdm_component_biome_tree_is_trusted() { # <tree> <canonical-command>
  local _root="$1" _command="$2" _arch _binary_sha _package_sha
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
  _mdm_component_private_tree_shape_is_exact biome "$_root" || return 1
  [[ "$_command" == "$_root/biome" \
    && "$(_mdm_sha256_file "$_root/biome")" == "$_binary_sha" \
    && "$(_mdm_sha256_file "$_root/package.json")" == "$_package_sha" \
    && "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_root/biome")")" == 0755 \
    && "$(_mdm_mode_normalize \
      "$(_mdm_stat_mode "$_root/package.json")")" == 0644 ]]
}

_mdm_component_safety_wrapper_is_bound() { # <home> <wrapper> <private-node>
  local _home="$1" _wrapper="$2" _node="$3" _script _expected LC_ALL=C
  _script="$_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6/dist/bin/cc-safety-net.js"
  [[ "$_wrapper" \
    == "$_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6/bin/cc-safety-net" \
    && -f "$_script" && ! -L "$_script" ]] || return 1
  _expected="$(printf \
    '#!/bin/bash\nunset NODE_OPTIONS NODE_PATH\nexec %q %q "$@"\n' \
    "$_node" "$_script")" || return 1
  _mdm_exact_text_file "$_wrapper" "$_expected"
}

_mdm_component_safety_tree_is_trusted() {
  # <home> <tree> <canonical-command> <private-node>
  local _home="$1" _root="$2" _command="$3" _node="$4"
  _mdm_component_private_tree_shape_is_exact safety_net "$_root" || return 1
  [[ "$_command" == "$_root/bin/cc-safety-net" \
    && "$(_mdm_sha256_file "$_root/dist/bin/cc-safety-net.js")" \
      == 1ffbfafabf2fe4fc9b6bf64a8088ca3a96c2714cf8fd8afd5b1b326582c982d4 \
    && "$(_mdm_sha256_file "$_root/package.json")" \
      == 2e57b465553ba97e1e6f7a37655fc52e31cad4ca739140bb7af40d052e3d88c8 \
    && "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_command")")" == 0755 \
    && "$(_mdm_mode_normalize \
      "$(_mdm_stat_mode "$_root/dist/bin/cc-safety-net.js")")" == 0644 \
    && "$(_mdm_mode_normalize \
      "$(_mdm_stat_mode "$_root/package.json")")" == 0644 ]] || return 1
  _mdm_component_safety_wrapper_is_bound "$_home" "$_command" "$_node"
}

_mdm_component_cli_path_signed() { # <path> <target-uid>
  local _path="$1" _uid="$2" _snapshot _old_umask _rc=1
  [[ "$_uid" =~ ^[0-9]+$ ]] || return 1
  _old_umask="$(umask)"; umask 077
  _snapshot="$(/usr/bin/mktemp "$(_mdm_safe_tmpdir)/claude-kit-mdm-cli-component.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  if _mdm_snapshot_bound_to "$_path" "$_snapshot" cli "$_uid" \
    && _mdm_mode_owner_executable "$_MDM_BOUND_SNAPSHOT_MODE" \
    && /bin/chmod 700 "$_snapshot" \
    && _mdm_claude_cli_signature_trusted "$_snapshot"; then
    _rc=0
  fi
  /bin/rm -f "$_snapshot"
  return "$_rc"
}

_mdm_component_ghostty_codesign_requirement() {
  printf '%s' '=identifier "com.mitchellh.ghostty" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "24VZTF6M5V"'
}

_mdm_component_ghostty_codesign() {
  /usr/bin/codesign "$@"
}

_mdm_component_ghostty_xattr() {
  /usr/bin/xattr "$@"
}

_mdm_component_ghostty_signed() { # <application-bundle>
  local _app="$1" _requirement _details _executable _mode
  [[ -d "$_app" && ! -L "$_app" ]] || return 1
  _executable="$_app/Contents/MacOS/ghostty"
  [[ -f "$_executable" && ! -L "$_executable" \
    && "$(_mdm_canonical_file "$_executable")" == "$_executable" ]] \
    || return 1
  _mode="$(_mdm_stat_mode "$_executable")" || return 1
  _mdm_mode_owner_executable "$_mode" || return 1
  /bin/test -x "$_executable" || return 1
  if _mdm_component_ghostty_xattr -p com.apple.quarantine -- "$_app" \
    >/dev/null 2>&1; then
    return 1
  fi
  _requirement="$(_mdm_component_ghostty_codesign_requirement)" || return 1
  _mdm_component_ghostty_codesign --verify --deep --strict -R "$_requirement" \
    -- "$_app" >/dev/null 2>&1 \
    && _details="$(_mdm_component_ghostty_codesign \
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

# This inventory mirrors lib/fonts-mdm.sh. The unit contract compares the
# canonical bytes so an installer/detector pin cannot silently drift from the
# files that the MDM font installer actually deploys.
_mdm_component_font_expected_inventory() {
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

_mdm_component_font_expected_record() { # <basename>
  local _wanted="$1" _name _sha _family
  while read -r _name _sha _family; do
    if [[ "$_name" == "$_wanted" ]]; then
      printf '%s\t%s' "$_sha" "$_family"
      return 0
    fi
  done < <(_mdm_component_font_expected_inventory)
  return 1
}

_mdm_component_font_file_is_trusted() { # <font-file>
  local _path="$1" _name="${1##*/}" _record _sha _family _python
  _record="$(_mdm_component_font_expected_record "$_name")" || return 1
  _sha="${_record%%$'\t'*}"
  _family="${_record#*$'\t'}"
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_path" "$_name" "$_sha" "$_family" <<'PY'
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

_mdm_component_receipt_dir_is_trusted() { # <receipt-dir>
  local _dir="$1" _canonical _mode
  [[ -d "$_dir" && ! -L "$_dir" ]] || return 1
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && -n "${MDM_SYSTEM_RCPT_DIR_OVERRIDE:-}" ]]; then
    [[ "$_dir" == "$MDM_SYSTEM_RCPT_DIR_OVERRIDE" ]] || return 1
  else
    [[ "$_dir" == "/Library/Application Support/ClaudeCodeStarterKit" ]] \
      || return 1
    _mdm_verify_dir_chain "$_dir" "/Library/Application Support" || return 1
  fi
  _mdm_component_trusted "$_dir" || return 1
  _canonical="$(_mdm_canonical_dir "$_dir")" || return 1
  [[ "$_canonical" == "$_dir" ]] || return 1
  _mode="$(_mdm_mode_normalize "$(_mdm_stat_mode "$_dir")")" || return 1
  [[ "$_mode" == 0755 ]]
}

_mdm_component_generated_manifest_is_exact() {
  # <manifest> <home> <user> <uid> <generated-uid> <policy> <required...>
  local _manifest="$1" _home="$2" _user="$3" _uid="$4" _generated="$5"
  local _policy="$6" _python _name _sha _family _component
  local _node_runtime _wce_runtime=""
  local _font_names=()
  shift 6
  _node_runtime="$(_mdm_node_runtime_path)" || return 1
  for _component in "$@"; do
    if [[ "$_component" == web_content_runtime ]]; then
      [[ "${_MDM_WCE_PACKAGE_SHA256:-}" =~ ^[0-9a-f]{64}$ \
        && "${_MDM_WCE_LOCK_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || return 1
      _wce_runtime="$(_mdm_wce_runtime_path \
        "$_MDM_WCE_PACKAGE_SHA256" "$_MDM_WCE_LOCK_SHA256")" || return 1
      break
    fi
  done
  while read -r _name _sha _family; do
    [[ "$_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
    _font_names[${#_font_names[@]}]="$_name"
  done < <(_mdm_component_font_expected_inventory)
  [[ "${#_font_names[@]}" -eq 20 ]] || return 1
  _python="$(_mdm_system_python)" || return 1
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$_python" -I -B -S - "$_manifest" "$_home" "$_user" "$_uid" \
    "$_generated" "$_policy" "$_node_runtime" "$_wce_runtime" \
    "$#" "$@" "${_font_names[@]}" <<'PY'
import collections
import json
import re
import sys

manifest, home, user, uid_raw, generated, policy, node_runtime, wce_runtime, required_count_raw, *rest = sys.argv[1:]
allowed = {
    "biome", "claude_cli", "fonts", "ghostty", "kit", "node_runtime",
    "safety_net", "web_content_runtime",
}
outer_keys = {
    "entries", "policy_sha256", "schema_version", "target_generated_uid",
    "target_uid", "target_user",
}
entry_keys = {"component", "kind", "path", "sha256"}

def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate object key")
        value[key] = item
    return value

def safe_path(value):
    return (type(value) is str and value.startswith("/")
            and not any(ord(char) < 32 or 127 <= ord(char) <= 159
                        or 0xD800 <= ord(char) <= 0xDFFF
                        for char in value))

try:
    required_count = int(required_count_raw)
    if not 1 <= required_count <= len(allowed):
        raise ValueError("invalid required count")
    required = rest[:required_count]
    font_names = rest[required_count:]
    if (len(required) != required_count or len(set(required)) != required_count
            or not set(required).issubset(allowed)):
        raise ValueError("invalid required components")
    if len(font_names) != 20 or len(set(font_names)) != 20:
        raise ValueError("invalid font inventory")
    if not safe_path(node_runtime) or (wce_runtime and not safe_path(wce_runtime)):
        raise ValueError("invalid runtime path")
    with open(manifest, "rb") as handle:
        raw = handle.read(64 * 1024 * 1024 + 1)
    if len(raw) > 64 * 1024 * 1024:
        raise ValueError("component manifest is too large")
    text = raw.decode("utf-8", "strict")
    value = json.loads(text, object_pairs_hook=unique_object,
                       parse_constant=lambda _value: (_ for _ in ()).throw(
                           ValueError("non-finite JSON number")))
    if type(value) is not dict or set(value) != outer_keys:
        raise ValueError("invalid manifest keys")
    if (type(value["schema_version"]) is not int
            or value["schema_version"] != 1
            or type(value["target_user"]) is not str
            or value["target_user"] != user
            or type(value["target_uid"]) is not int
            or value["target_uid"] != int(uid_raw)
            or type(value["target_generated_uid"]) is not str
            or value["target_generated_uid"] != generated
            or type(value["policy_sha256"]) is not str
            or value["policy_sha256"] != policy
            or not re.fullmatch(r"[0-9a-f]{64}", policy)
            or type(value["entries"]) is not list):
        raise ValueError("invalid manifest identity")

    entries = value["entries"]
    identities = set()
    counts = collections.Counter()
    expected_fixed = {
        "biome": (home + "/.local/lib/claude-code-starter-kit/biome/2.5.4", "tree"),
        "ghostty": ("/Applications/Ghostty.app", "tree"),
        "kit": (home + "/.claude-starter-kit", "tree"),
        "safety_net": (home + "/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6", "tree"),
        "web_content_runtime": (wce_runtime, "tree"),
    }
    expected_fonts = {home + "/Library/Fonts/" + name for name in font_names}
    for entry in entries:
        if type(entry) is not dict or set(entry) != entry_keys:
            raise ValueError("invalid entry keys")
        component = entry["component"]
        path = entry["path"]
        kind = entry["kind"]
        digest = entry["sha256"]
        if (type(component) is not str or component not in allowed
                or not safe_path(path)
                or type(kind) is not str or kind not in ("file", "tree")
                or type(digest) is not str
                or not re.fullmatch(r"[0-9a-f]{64}", digest)):
            raise ValueError("invalid entry value")
        identity = (component, path)
        if identity in identities:
            raise ValueError("duplicate entry")
        identities.add(identity)
        counts[component] += 1
        if component in expected_fixed:
            if (path, kind) != expected_fixed[component]:
                raise ValueError("invalid fixed entry")
        elif component == "claude_cli":
            prefix = home + "/.local/share/claude/versions/"
            version = path[len(prefix):] if path.startswith(prefix) else ""
            if kind != "file" or not re.fullmatch(r"[0-9A-Za-z._+-]+", version):
                raise ValueError("invalid claude entry")
        elif component == "fonts":
            if kind != "file" or path not in expected_fonts:
                raise ValueError("invalid font entry")
        elif component == "node_runtime":
            if (path, kind) != (node_runtime, "tree"):
                raise ValueError("invalid node runtime entry")
    ordered = sorted(entries, key=lambda item: (
        item["component"].encode("ascii"), item["path"].encode("utf-8")))
    if entries != ordered:
        raise ValueError("entries are not decoded-value sorted")
    if set(counts) != set(required):
        raise ValueError("component set mismatch")
    for component in required:
        expected_count = 20 if component == "fonts" else 1
        if counts[component] != expected_count:
            raise ValueError("component count mismatch")
    if "fonts" in required:
        actual_fonts = {entry["path"] for entry in entries
                        if entry["component"] == "fonts"}
        if actual_fonts != expected_fonts:
            raise ValueError("font set mismatch")
    entry_lines = []
    for entry in entries:
        entry_lines.append("    " + json.dumps(
            entry, ensure_ascii=True, sort_keys=True, separators=(",", ":")))
    quote = lambda item: json.dumps(
        item, ensure_ascii=False, separators=(",", ":"))
    canonical = (
        "{\n  \"schema_version\": 1,\n"
        + "  \"target_user\": " + quote(user) + ",\n"
        + "  \"target_uid\": " + str(int(uid_raw)) + ",\n"
        + "  \"target_generated_uid\": " + quote(generated) + ",\n"
        + "  \"policy_sha256\": " + quote(policy) + ",\n"
        + "  \"entries\": ["
        + ("\n" + ",\n".join(entry_lines) if entry_lines else "")
        + "\n  ]\n}\n")
    if raw != canonical.encode("utf-8", "strict"):
        raise ValueError("component manifest bytes are not writer-canonical")
except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
    sys.exit(1)
PY
}

_mdm_attest_components() { # <user> <home> <uid> <generated-uid>
  local _user="$1" _home="$2" _uid="$3" _generated_uid="$4"
  local _component _path _active _canonical _dir _target _tmp _raw _old_umask
  local _node
  local _pre_digest
  local _first=1 _font_count=0 _meta _rest _links _mode
  local _name _sha _family
  [[ "$_uid" =~ ^[0-9]+$ && "$_uid" -ge 501 ]] || return 1
  _MDM_COMPONENT_TARGET_UID="$_uid"
  _generated_uid="$(_mdm_normalize_generated_uid "$_generated_uid")" || return 1
  _old_umask="$(umask)"; umask 077
  _MDM_COMPONENT_ENTRIES="$(/usr/bin/mktemp "$(_mdm_safe_tmpdir)/claude-kit-mdm-components.XXXXXX")" \
    || { umask "$_old_umask"; return 1; }
  umask "$_old_umask"
  for _component in "${MDM_REQUIRED_COMPONENTS[@]}"; do
    case "$_component" in
      kit)
        _path="$_home/.claude-starter-kit"
        [[ -d "$_path" && ! -L "$_path" ]] || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        [[ "${_MDM_EXPECTED_KIT_COMPONENT_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_append_entry kit "$_path" tree \
          "$_MDM_EXPECTED_KIT_COMPONENT_SHA256" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; } ;;
      claude_cli)
        _mdm_component_cli_target "$_user" "$_home" "$_uid" _path \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _pre_digest="$(_mdm_artifact_digest file "$_path" "$_uid")" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_cli_path_signed "$_path" "$_uid" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_append_entry claude_cli "$_path" file "$_pre_digest" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_cli_target "$_user" "$_home" "$_uid" _active \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        [[ "$_active" == "$_path" ]] \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_cli_path_signed "$_active" "$_uid" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        [[ "$(_mdm_artifact_digest file "$_active" "$_uid")" \
          == "$_pre_digest" ]] \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; } ;;
      safety_net)
        _dir="$_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6"
        _node="$(_mdm_node_runtime_path)/bin/node" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_fixed_launcher "$_uid" "$_user" "$_home" \
          cc-safety-net 1.0.6 bin/cc-safety-net _path \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        [[ "$_path" == "$_dir/bin/cc-safety-net" ]] \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _pre_digest="$(_mdm_artifact_digest tree "$_dir" "$_uid")" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_safety_tree_is_trusted \
          "$_home" "$_dir" "$_path" "$_node" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_append_entry safety_net "$_dir" tree "$_pre_digest" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_safety_tree_is_trusted \
          "$_home" "$_dir" "$_path" "$_node" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_fixed_launcher "$_uid" "$_user" "$_home" \
          cc-safety-net 1.0.6 bin/cc-safety-net _active \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        [[ "$_active" == "$_path" ]] \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; } ;;
      biome)
        _dir="$_home/.local/lib/claude-code-starter-kit/biome/2.5.4"
        _mdm_component_fixed_launcher "$_uid" "$_user" "$_home" \
          biome 2.5.4 biome _path \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        [[ "$_path" == "$_dir/biome" ]] \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _pre_digest="$(_mdm_artifact_digest tree "$_dir" "$_uid")" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_biome_tree_is_trusted "$_dir" "$_path" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_append_entry biome "$_dir" tree "$_pre_digest" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_biome_tree_is_trusted "$_dir" "$_path" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_fixed_launcher "$_uid" "$_user" "$_home" \
          biome 2.5.4 biome _active \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        [[ "$_active" == "$_path" ]] \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; } ;;
      node_runtime)
        _path="$(_mdm_node_runtime_path)" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_node_runtime_activation_valid "$_user" "$_home" "$_uid" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _MDM_NODE_RUNTIME_DIGEST=""
        _mdm_node_runtime_trusted "$_path" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        [[ "${_MDM_NODE_RUNTIME_DIGEST:-}" =~ ^[0-9a-f]{64}$ ]] \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_append_entry node_runtime "$_path" tree \
          "$_MDM_NODE_RUNTIME_DIGEST" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _pre_digest="$_MDM_NODE_RUNTIME_DIGEST"
        _MDM_NODE_RUNTIME_DIGEST=""
        _mdm_node_runtime_trusted "$_path" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        [[ "$_MDM_NODE_RUNTIME_DIGEST" == "$_pre_digest" ]] \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_node_runtime_activation_valid "$_user" "$_home" "$_uid" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; } ;;
      web_content_runtime)
        [[ "${_MDM_WCE_PACKAGE_SHA256:-}" =~ ^[0-9a-f]{64}$ \
          && "${_MDM_WCE_LOCK_SHA256:-}" =~ ^[0-9a-f]{64}$ \
          && "${_MDM_EXPECTED_WCE_COMPONENT_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _path="$(_mdm_wce_runtime_path \
          "$_MDM_WCE_PACKAGE_SHA256" "$_MDM_WCE_LOCK_SHA256")" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        [[ "${_MDM_WCE_VERIFIED_BUNDLE:-}" == "$_path" ]] \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_wce_runtime_activation_valid \
          "$_user" "$_home" "$_uid" "$_path" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _MDM_WCE_RUNTIME_DIGEST=""
        _mdm_wce_runtime_trusted "$_path" \
          "$_MDM_WCE_PACKAGE_SHA256" "$_MDM_WCE_LOCK_SHA256" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        [[ "${_MDM_WCE_RUNTIME_DIGEST:-}" \
          == "$_MDM_EXPECTED_WCE_COMPONENT_SHA256" ]] \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _pre_digest="$_MDM_WCE_RUNTIME_DIGEST"
        _mdm_component_append_entry web_content_runtime "$_path" tree \
          "$_MDM_EXPECTED_WCE_COMPONENT_SHA256" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _MDM_WCE_RUNTIME_DIGEST=""
        _mdm_wce_runtime_trusted "$_path" \
          "$_MDM_WCE_PACKAGE_SHA256" "$_MDM_WCE_LOCK_SHA256" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        [[ "$_MDM_WCE_RUNTIME_DIGEST" == "$_pre_digest" \
          && "$_MDM_WCE_RUNTIME_DIGEST" \
            == "$_MDM_EXPECTED_WCE_COMPONENT_SHA256" ]] \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_wce_runtime_activation_valid \
          "$_user" "$_home" "$_uid" "$_path" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; } ;;
      ghostty)
        _path=/Applications/Ghostty.app
        [[ -d "$_path" && ! -L "$_path" ]] || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_tree_accessible "$_path" "$_uid" "$_user" "$_home" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _pre_digest="$(_mdm_artifact_digest tree "$_path" "0,$_uid")" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_ghostty_signed "$_path" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_append_entry ghostty "$_path" tree "$_pre_digest" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_tree_accessible "$_path" "$_uid" "$_user" "$_home" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        _mdm_component_ghostty_signed "$_path" \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        [[ "$(_mdm_artifact_digest tree "$_path" "0,$_uid")" == "$_pre_digest" ]] \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; } ;;
      fonts)
        _dir="$_home/Library/Fonts"
        [[ -d "$_dir" && ! -L "$_dir" ]] || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
        while read -r _name _sha _family; do
          [[ "$_sha" =~ ^[0-9a-f]{64}$ \
            && ( "$_family" == ibm || "$_family" == hackgen ) ]] \
            || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
          _target="$_dir/$_name"
          [[ -f "$_target" && ! -L "$_target" ]] \
            || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
          _canonical="$(_mdm_canonical_file "$_target")" || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
          [[ "$_canonical" == "$_target" ]] \
            || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
          _mdm_component_file_readable \
            "$_canonical" "$_uid" "$_user" "$_home" \
            || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
          _pre_digest="$(_mdm_artifact_digest file "$_canonical" "$_uid")" \
            || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
          _mdm_component_font_file_is_trusted "$_canonical" \
            || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
          _mdm_component_append_entry fonts "$_canonical" file "$_pre_digest" \
            || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
          _active="$(_mdm_canonical_file "$_target")" \
            || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
          [[ "$_active" == "$_target" ]] \
            || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
          _mdm_component_file_readable \
            "$_active" "$_uid" "$_user" "$_home" \
            || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
          _mdm_component_font_file_is_trusted "$_active" \
            || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
          [[ "$(_mdm_artifact_digest file "$_active" "$_uid")" \
            == "$_pre_digest" ]] \
            || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
          _font_count=$((_font_count + 1))
        done < <(_mdm_component_font_expected_inventory)
        [[ "$_font_count" -eq 20 ]] \
          || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; } ;;
    esac
  done
  [[ "$MDM_RCPT_POLICY_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
  _mdm_component_sort_entries "$_MDM_COMPONENT_ENTRIES" \
    || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
  _dir="$(_mdm_receipt_dir_for "$_home")"
  _mdm_component_receipt_dir_is_trusted "$_dir" \
    || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
  _path="$_dir/components-$_generated_uid.json"
  if [[ -L "$_path" ]]; then
    /bin/rm -f "$_path" \
      || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
    [[ ! -e "$_path" && ! -L "$_path" ]] \
      || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
  elif [[ -e "$_path" && ! -f "$_path" ]]; then
    /bin/rm -f "$_MDM_COMPONENT_ENTRIES"
    return 1
  fi
  _tmp="$(/usr/bin/mktemp "$_dir/.components.XXXXXX")" \
    || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES"; return 1; }
  {
    printf '{\n  "schema_version": 1,\n'
    printf '  "target_user": "%s",\n' "$(mdm_json_escape "$_user")"
    printf '  "target_uid": %s,\n' "$_uid"
    printf '  "target_generated_uid": "%s",\n' "$_generated_uid"
    printf '  "policy_sha256": "%s",\n' "$MDM_RCPT_POLICY_SHA256"
    printf '  "entries": ['
    while IFS= read -r _raw; do
      [[ -n "$_raw" ]] || continue
      if [[ "$_first" -eq 0 ]]; then printf ','; fi
      printf '\n    %s' "$_raw"
      _first=0
    done < "$_MDM_COMPONENT_ENTRIES"
    printf '\n  ]\n}\n'
  } > "$_tmp" || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES" "$_tmp"; return 1; }
  _mdm_json_valid "$_tmp" \
    || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES" "$_tmp"; return 1; }
  _mdm_component_generated_manifest_is_exact "$_tmp" "$_home" "$_user" \
    "$_uid" "$_generated_uid" "$MDM_RCPT_POLICY_SHA256" \
    "${MDM_REQUIRED_COMPONENTS[@]}" \
    || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES" "$_tmp"; return 1; }
  _mdm_component_receipt_dir_is_trusted "$_dir" \
    || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES" "$_tmp"; return 1; }
  /bin/chmod 600 "$_tmp" && /bin/mv -f "$_tmp" "$_path" \
    || { /bin/rm -f "$_MDM_COMPONENT_ENTRIES" "$_tmp"; return 1; }
  [[ -f "$_path" && ! -L "$_path" ]] || return 1
  _mdm_component_receipt_dir_is_trusted "$_dir" || return 1
  _mdm_component_trusted "$_path" || return 1
  _meta="$(_mdm_stat_managed_metadata "$_path")" || return 1
  _rest="${_meta#*:}"; _links="${_rest%%:*}"
  _mode="$(_mdm_mode_normalize "${_rest#*:}")" || return 1
  [[ "$_links" == 1 && "$_mode" == 0600 ]] || return 1
  MDM_RCPT_COMPONENT_MANIFEST_SHA256="$(_mdm_sha256_file "$_path")" || return 1
  [[ "$MDM_RCPT_COMPONENT_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
  MDM_RCPT_COMPONENT_MANIFEST_PATH="$_path"
  /bin/rm -f "$_MDM_COMPONENT_ENTRIES"
  _MDM_COMPONENT_ENTRIES=""
}

_mdm_user_phase_exit_code() { # <user-phase-rc> <dry-run>
  local _rc="$1" _dry_run="$2"
  case "$_rc" in
    0|"$MDM_EXIT_PREREQ"|"$MDM_EXIT_CONFIG") printf '%s' "$_rc" ;;
    "$MDM_EXIT_CLI")
      if [[ "$_dry_run" == "true" ]]; then
        printf '%s' "$MDM_EXIT_SETUP"
      else
        printf '%s' "$MDM_EXIT_CLI"
      fi ;;
    *) printf '%s' "$MDM_EXIT_SETUP" ;;
  esac
}

_mdm_handle_log_setup_failure() { # <user> <home> <dry-run>
  local _user="$1" _home="$2" _dry_run="$3"
  if [[ "$_dry_run" == "true" ]]; then
    return "$MDM_EXIT_CONFIG"
  fi
  _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_CONFIG"
  return "$MDM_EXIT_CONFIG"
}

_mdm_main_euid() {
  if [[ "${_MDM_TEST_MODE:-0}" == 1 \
    && "${MDM_EUID_OVERRIDE:-}" =~ ^[0-9]+$ ]]; then
    printf '%s' "$MDM_EUID_OVERRIDE"
  else
    /usr/bin/id -u
  fi
}

# R1..R4 のオーケストレーション。root フェーズは実副作用
# （brew 導入・降格）を伴うため、単体テストでは各フェーズ関数を個別に
# 検証し、エントリポイントは clean-launch 契約までを検証する。
mdm_main() {
  # 外部コマンド実行の前に PATH を固定する。対象ユーザーが PATH に
  # 自分の bin を先頭挿入していると、uname/stat/git/curl/pkgutil/installer/
  # softwareupdate 等の裸コマンドが root 権限で乗っ取られ得る（MDM の汎用契約
  # や sudo 経路では既定環境の安全性が保証されない）。Homebrew は絶対パスで
  # 検出するため brew bin を PATH に足す必要はない。
  PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  export PATH
  GIT_CONFIG_NOSYSTEM=1
  GIT_CONFIG_GLOBAL=/dev/null
  GIT_TERMINAL_PROMPT=0
  GIT_NO_REPLACE_OBJECTS=1
  export GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL GIT_TERMINAL_PROMPT GIT_NO_REPLACE_OBJECTS

  # The pinned Node.js 24 runtime requires macOS 13.5 or newer. Treat a
  # missing/malformed product version exactly like any other unsupported OS.
  _mdm_supported_macos_host \
    || { mdm_log R1 "非対応 OS (macOS 13.5+ が必要)"; exit "$MDM_EXIT_OS"; }

  # R1: root never sources an adjacent/user-owned library.  The launcher has
  # a data-only parser and executable mode has already discarded inherited env.
  _mdm_root_config_apply "$(_mdm_config_path)" "$@" || {
    mdm_log R1 "設定エラー"
    # Configuration is not authoritative until the complete file and argv
    # validate.  In particular, a rejected payload may have requested
    # KIT_MDM_DRY_RUN=true, so this early failure must not mutate compliance.
    exit "$MDM_EXIT_CONFIG"
  }
  _mdm_apply_mdm_defaults

  # A real remediation is a privileged/system operation.  Reject non-root
  # normal runs before target resolution, log creation, checkout mutation, or
  # receipt creation.  Non-root remains useful only as an explicit preview.
  local _euid _dry_run="false"
  _euid="$(_mdm_main_euid)"
  _dry_run="$(_mdm_root_bool "${KIT_MDM_DRY_RUN:-false}" 2>/dev/null || echo false)"
  if [[ "$_euid" -ne 0 && "$_dry_run" != "true" ]]; then
    mdm_log R2 "通常の MDM remediation は root 実行が必須"
    exit "$MDM_EXIT_CONTEXT"
  fi
  if ! _mdm_expected_policy_input_valid; then
    mdm_log R1 "expected policy SHA-256 が未指定または不正"
    exit "$MDM_EXIT_CONFIG"
  fi

  # R2: ユーザー・home 解決（root の失敗時だけ system receipt を best-effort で試す）
  local _user="" _home _target_uid="" _identity_tuple=""
  if [[ "$_euid" -eq 0 ]]; then
    if ! _mdm_resolve_target_username _user; then
      _mdm_fail_or_exit_unresolved "$MDM_EXIT_USER" "$_dry_run"
    fi
    _identity_tuple="$(_mdm_bind_target_identity_tuple "$_user")" \
      || _mdm_fail_or_exit_unresolved "$MDM_EXIT_USER" "$_dry_run"
    _target_uid="${_identity_tuple%%$'\t'*}"
    _MDM_TARGET_GENERATED_UID="${_identity_tuple#*$'\t'}"
    _mdm_bind_canonical_target_username _user "$_user" "$_target_uid" \
      "$_MDM_TARGET_GENERATED_UID" \
      || _mdm_fail_or_exit_unresolved "$MDM_EXIT_USER" "$_dry_run"
    _home="$(mdm_validate_user_home "$_user" "$_target_uid")" \
      || _mdm_fail_or_exit_unresolved "$MDM_EXIT_USER" "$_dry_run"
    _MDM_TARGET_SHELL="$(_mdm_user_shell "$_user")" \
      || _mdm_fail_or_exit_unresolved "$MDM_EXIT_USER" "$_dry_run"
  else
    _user="$(/usr/bin/id -un)"; _home="$HOME"     # ユーザーモード
    _target_uid="$_euid"
    if [[ -n "${KIT_MDM_TARGET_USER:-}" && "$KIT_MDM_TARGET_USER" != "$_user" ]]; then
      mdm_log R2 "非 root 実行で別ユーザーは指定できない"
      exit "$MDM_EXIT_USER"
    fi
    _MDM_TARGET_SHELL="$(_mdm_user_shell "$_user")" || exit "$MDM_EXIT_USER"
  fi
  MDM_RCPT_TARGET_USER="$_user"
  MDM_RCPT_TARGET_UID="$_target_uid"
  MDM_RCPT_TARGET_GENERATED_UID="$_MDM_TARGET_GENERATED_UID"

  # Production-only ref/install-dir/log semantics are configuration errors,
  # and must be rejected before lock/log/CLT/Homebrew side effects.
  _mdm_validate_semantic_config "$_euid" "$_home" "$_target_uid" "$_dry_run" \
    || exit "$MDM_EXIT_CONFIG"

  # Serialize every mutating run before any path can write a receipt. A
  # competing run exits without changing checkout, history, or compliance.
  if [[ "$_euid" -eq 0 && "$_dry_run" != true ]] \
    && ! _mdm_acquire_run_lock "$_user" "$_home"; then
    if [[ "${_MDM_RUN_LOCK_ERROR:-backend}" == contention ]]; then
      mdm_log R2 "host-global MDM remediation が実行中"
      exit "$MDM_EXIT_CONTEXT"
    else
      mdm_log R2 "host-global remediation lock backend を安全に確立できない"
      exit "$MDM_EXIT_OS"
    fi
  fi

  # ログ開始（設定確定後 = KIT_MDM_LOG_DIR が管理設定/CLI からも効く）。
  if ! _mdm_setup_log_file "$_euid" "$_home"; then
    # A preview must not create or replace a compliance receipt, even when its
    # audit-log destination is invalid or unavailable.
    local _log_failure_rc=0
    _mdm_handle_log_setup_failure "$_user" "$_home" "$_dry_run" \
      || _log_failure_rc=$?
    exit "$_log_failure_rc"
  fi

  # R3: CLT is always checked before the first Git command.  Dry-run never
  # installs prerequisites; it only reports what is already available.
  if [[ "$_dry_run" == "true" ]]; then
    # Both root and non-root previews need Git before their temporary clone.
    # Report the same prerequisite code without attempting installation.
    local _dry_prereq_rc=0
    _mdm_check_dryrun_prerequisites || _dry_prereq_rc=$?
    [[ "$_dry_prereq_rc" -eq 0 ]] || exit "$_dry_prereq_rc"
  elif [[ "$_euid" -eq 0 ]]; then
    _mdm_ensure_clt || _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_PREREQ"
  fi

  # Bind every Python helper to the fixed CLT framework interpreter before
  # transaction state or managed content is touched. Full Xcode and the
  # /usr/bin/python3 xcode-select shim are deliberately not fallbacks.
  if ! _mdm_initialize_system_python; then
    mdm_log R3 "Apple署名済みCLT Pythonを信頼済み実体へ束縛できない"
    if [[ "$_dry_run" == "true" ]]; then
      exit "$MDM_EXIT_PREREQ"
    fi
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_PREREQ"
  fi
  # Homebrew failure receipts use only the already-private Python runtime.
  # This ordering prevents a prerequisite failure from reopening the live CLT
  # interpreter after its source validation phase has completed.
  if [[ "$_euid" -eq 0 && "$_dry_run" != true ]]; then
    local _prereq_rc=0 _brew_usable=false
    if _mdm_brew_usable_for_user "$_target_uid" "$_user" "$_home"; then
      _brew_usable=true
    fi
    case "$(mdm_prereq_plan "$_brew_usable")" in
      fail)
        mdm_log R3 "前提不足かつ導入無効"
        _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_PREREQ" ;;
      bootstrap)
        _mdm_bootstrap_homebrew "$_user" || _prereq_rc=$?
        if [[ "$_prereq_rc" -ne 0 ]] \
          || ! _mdm_brew_usable_for_user \
            "$_target_uid" "$_user" "$_home"; then
          mdm_log R3 "Homebrew が対象ユーザーで利用可能にならない"
          _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_BREW"
        fi ;;
    esac
  fi

  if [[ "$_euid" -eq 0 && "$_dry_run" != true ]]; then
    if ! _mdm_transaction_begin "$_user" "$_home" "$_target_uid" \
      "$_MDM_TARGET_GENERATED_UID"; then
      mdm_log R4 "outer transaction の開始に失敗"
      _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_SETUP"
    fi
  fi

  # U1b..U3: キット取得(ref 固定) + setup 実行 + CLI 導入の確認。
  # root 時は git 操作・setup.sh 実行とも検証済みユーザーへ環境分離降格（Critical#2）。
  local _user_rc=0 _final_user_rc
  _mdm_run_user_phase "$_euid" "$_user" "$_home" "$_target_uid" || _user_rc=$?
  _final_user_rc="$(_mdm_user_phase_exit_code "$_user_rc" "$_dry_run")"
  if [[ "$_dry_run" == "true" ]]; then
    if [[ "$_final_user_rc" -eq 0 ]] \
      && ! _mdm_system_python_cache_rebound; then
      mdm_log R4 "dry-run終了時にCLT Python identityが変化"
      _final_user_rc="$MDM_EXIT_PREREQ"
    fi
    _mdm_cleanup_transient_checkouts
    if [[ "$_final_user_rc" -eq 0 ]]; then
      mdm_log R4 "dry-run 完了（receipt/compliance は不変）"
      exit 0
    fi
    mdm_log R4 "dry-run 失敗: exit=$_user_rc"
    exit "$_final_user_rc"
  fi
  if [[ "$_final_user_rc" -eq "$MDM_EXIT_PREREQ" ]]; then
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_PREREQ"
  elif [[ "$_final_user_rc" -eq "$MDM_EXIT_CLI" ]]; then
    # キット配備自体は成功したが必須 CLI が欠如（部分失敗として報告）
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_CLI"
  elif [[ "$_final_user_rc" -eq "$MDM_EXIT_CONFIG" ]]; then
    # install_dir 制約違反等の設定エラーは 30 に潰さず 50 を維持
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_CONFIG"
  elif [[ "$_final_user_rc" -ne 0 ]]; then
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_SETUP"
  fi

  if ! _mdm_revalidate_target_identity \
    "$_user" "$_home" "$_target_uid" "$_MDM_TARGET_GENERATED_UID"; then
    mdm_log R4 "対象account identityが実行中に変化"
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_USER"
  fi

  if ! _mdm_capture_postcondition "$_home" "$_target_uid"; then
    mdm_log R4 "配備 postcondition の検証に失敗"
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_SETUP"
  fi
  if ! _mdm_attest_components \
    "$_user" "$_home" "$_target_uid" "$_MDM_TARGET_GENERATED_UID"; then
    mdm_log R4 "required component attestation に失敗"
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_SETUP"
  fi
  # Persist deletion authority only after root has verified that these paths
  # are the files actually deployed in both live and snapshot state.
  if ! _mdm_persist_managed_history \
    "$_user" "$_home" "$_target_uid" "$_MDM_TARGET_GENERATED_UID"; then
    mdm_log R4 "root managed history の永続化に失敗"
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_SETUP"
  fi

  if ! _mdm_revalidate_success_state \
    "$_user" "$_home" "$_target_uid" "$_MDM_TARGET_GENERATED_UID"; then
    mdm_log R4 "成功レシート直前の再検証に失敗"
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_SETUP"
  fi

  if ! _mdm_system_python_cache_rebound_for_commit; then
    # The guarded check publishes failure-only mode before restoring signal
    # cleanup, so the failed private copy is unreachable on every exit path.
    mdm_log R4 "成功レシート直前にCLT Python identityが変化"
    # A fresh, fully sealed private copy is preferred for root-only rollback.
    # Target-user rollback always revalidates the initialization-bound fixed
    # CLT source. If recovery fails or is interrupted, the same source remains
    # available to restore every transaction namespace and parent mode.
    if ! _mdm_system_python_recover_after_rebound_failure; then
      mdm_log R4 "CLT Pythonのfresh private再束縛に失敗"
    fi
    _mdm_transaction_abort || _mdm_transaction_mark_partial
    _mdm_arm_transient_cleanup
    _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_PREREQ"
  fi

  # R4: 成功レシート
  _mdm_finish "$_user" "$_home" success "$MDM_EXIT_OK"
}

# ── エントリポイント。source-only 時（テスト）は実行しない。────
# --mdm-user-phase 等の内部専用フラグは持たない: 単一の mdm_main が全フェーズを配線する。
if [[ "${MDM_SOURCE_ONLY:-0}" != "1" ]] && { [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; }; then
  mdm_main "$@"
fi
