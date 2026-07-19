#!/usr/bin/env bash
# Process/session lifecycle helpers sourced by run-mdm-tests.sh.

_mdm_process_record() { # <pid>
  LC_ALL=C TZ=UTC0 /bin/ps -p "$1" \
    -o pid= -o ppid= -o pgid= -o uid= -o stat= -o lstart= 2>/dev/null \
    | /usr/bin/awk '
      NF >= 10 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ \
        && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {
        print $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" \
          $6 " " $7 " " $8 " " $9 " " $10
        exit
      }
    '
}

_mdm_record_identity() { # <process-record>
  local record="$1" pid ppid pgid uid _state started
  IFS='|' read -r pid ppid pgid uid _state started <<< "$record"
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$ppid" =~ ^[0-9]+$ \
    && "$pgid" =~ ^[1-9][0-9]*$ && "$uid" =~ ^[0-9]+$ \
    && -n "$started" ]] || return 1
  printf '%s|%s|%s|%s|%s\n' "$pid" "$ppid" "$pgid" "$uid" "$started"
}

_mdm_record_state() { # <process-record>
  local record="$1" _pid _ppid _pgid _uid state _started
  IFS='|' read -r _pid _ppid _pgid _uid state _started <<< "$record"
  printf '%s\n' "$state"
}

_mdm_record_matches() { # <pid> <expected-record>
  local pid="$1" expected="$2" current expected_identity current_identity
  [[ "$pid" =~ ^[1-9][0-9]*$ && -n "$expected" ]] || return 1
  current="$(_mdm_process_record "$pid" || true)"
  [[ -n "$current" ]] || return 1
  expected_identity="$(_mdm_record_identity "$expected" || true)"
  current_identity="$(_mdm_record_identity "$current" || true)"
  [[ -n "$expected_identity" && "$current_identity" == "$expected_identity" \
    && "$(_mdm_record_state "$current")" != Z* ]]
}

_mdm_session_record_identity() { # <session-leader-record>
  local record="$1" pid _ppid pgid uid _state started
  IFS='|' read -r pid _ppid pgid uid _state started <<< "$record"
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$pgid" == "$pid" \
    && "$uid" =~ ^[0-9]+$ && -n "$started" ]] || return 1
  printf '%s|%s|%s|%s\n' "$pid" "$pgid" "$uid" "$started"
}

_mdm_session_record_matches() { # <expected-session-leader-record>
  local expected="$1" pid="${1%%|*}" current expected_identity current_identity
  expected_identity="$(_mdm_session_record_identity "$expected" || true)"
  [[ -n "$expected_identity" ]] || return 1
  current="$(_mdm_process_record "$pid" || true)"
  current_identity="$(_mdm_session_record_identity "$current" || true)"
  [[ "$current_identity" == "$expected_identity" \
    && "$(_mdm_record_state "$current")" != Z* ]]
}

_mdm_read_nested_supervisor_record() { # <record-file> <nested-runner-pid>
  local record_file="$1" parent_pid="$2" record
  local pid ppid pgid uid _state _started
  [[ -f "$record_file" && ! -L "$record_file" \
    && "$(/usr/bin/wc -l < "$record_file" \
      | /usr/bin/tr -d '[:space:]')" == 1 ]] || return 1
  record="$(sed -n '1p' "$record_file")"
  IFS='|' read -r pid ppid pgid uid _state _started <<< "$record"
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$ppid" == "$parent_pid" \
    && "$pgid" == "$pid" && "$uid" == "$(/usr/bin/id -u)" ]] || return 1
  _mdm_session_record_identity "$record" >/dev/null || return 1
  printf '%s\n' "$record"
}

_mdm_external_cleanup_session() { # <session-leader-record>
  local record="$1" pid _ppid _pgid uid _state started
  _mdm_session_record_identity "$record" >/dev/null || return 1
  IFS='|' read -r pid _ppid _pgid uid _state started <<< "$record"
  "$MDM_TEST_SYSTEM_PYTHON" -I -B -S "$SUPERVISOR" \
    --cleanup-session "$pid" --expected-uid "$uid" \
    --expected-start "$started" >/dev/null 2>&1
}

_mdm_signal_record() { # <expected-record> <signal>
  local expected="$1" signal_name="$2" pid="${1%%|*}"
  _mdm_record_matches "$pid" "$expected" || return 1
  /bin/kill "-$signal_name" "$pid" 2>/dev/null
}

_mdm_wait_bound_supervisor() { # <pid> <expected-record>
  local pid="$1" expected="$2" attempt=0 current expected_identity
  local current_identity current_state wait_status
  _MDM_LAST_BOUND_WAIT_STATUS=""
  expected_identity="$(_mdm_record_identity "$expected" || true)"
  [[ -n "$expected_identity" ]] || return 1
  while [[ "$attempt" -lt 400 ]]; do
    current="$(_mdm_process_record "$pid" || true)"
    current_identity="$(_mdm_record_identity "$current" || true)"
    current_state="$(_mdm_record_state "$current" 2>/dev/null || true)"
    if [[ -z "$current" || "$current_identity" != "$expected_identity" \
      || "$current_state" == Z* ]]; then
      if wait "$pid" 2>/dev/null; then
        wait_status=0
      else
        wait_status=$?
      fi
      [[ "$wait_status" -ne 127 ]] || return 1
      _MDM_LAST_BOUND_WAIT_STATUS="$wait_status"
      return 0
    fi
    /bin/sleep 0.02
    attempt=$((attempt + 1))
  done
  return 1
}

_mdm_cleanup_bound_supervisor() { # <pid> <expected-record> [signal]
  local pid="$1" expected="$2" signal_name="${3:-TERM}"
  local current_pid current_ppid current_pgid _rest
  [[ -n "$expected" ]] || return 0
  IFS='|' read -r current_pid current_ppid current_pgid _rest <<< "$expected"
  [[ "$current_pid" == "$pid" && "$current_ppid" == "$$" ]] || return 1

  _mdm_signal_record "$expected" "$signal_name" || true
  # A supervisor is intentionally stopped before launch. Continue it so its
  # installed signal handler can collect the session before exiting.
  _mdm_signal_record "$expected" CONT || true
  if _mdm_wait_bound_supervisor "$pid" "$expected"; then
    return 0
  fi

  # Fallback collection requires the exact live supervisor/session leader SID.
  if [[ "$current_pgid" == "$pid" ]] \
    && _mdm_record_matches "$pid" "$expected"; then
    _mdm_external_cleanup_session "$expected" || true
  fi
  if _mdm_wait_bound_supervisor "$pid" "$expected"; then
    return 0
  fi
  return 1
}

_mdm_cleanup_unbound_direct_child() { # <direct-child-pid>
  local pid="$1" job_pid wait_rc
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  # Use Bash's job identity, not the numeric PID: Bash may reap a short-lived
  # child before explicit wait, after which that numeric PID could be reused.
  job_pid="$(jobs -p %+ 2>/dev/null || true)"
  if [[ "$job_pid" == "$pid" ]]; then
    builtin kill -TERM %+ 2>/dev/null || true
    builtin kill -CONT %+ 2>/dev/null || true
    /bin/sleep 0.02
    job_pid="$(jobs -p %+ 2>/dev/null || true)"
    if [[ "$job_pid" == "$pid" ]]; then
      builtin kill -KILL %+ 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null
  wait_rc=$?
  [[ "$wait_rc" -ne 127 ]]
}

_mdm_remove_runner_tree() { # <runner-owned-path>
  local root="$1"
  [[ "$root" == /* && "$root" != / ]] || return 1
  [[ -e "$root" || -L "$root" ]] || return 0
  if [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]]; then
    /usr/bin/chflags -h 0 "$root" 2>/dev/null || return 1
    if [[ -d "$root" && ! -L "$root" ]]; then
      /bin/chmod u+rwx "$root" || return 1
      /usr/bin/find -P "$root" -xdev \
        -exec /usr/bin/chflags -h 0 '{}' \; \
        \( -type l -exec /bin/chmod -h -N '{}' \; \
          -o -type d -exec /bin/chmod u+rwx '{}' \; \
            -exec /bin/chmod -N '{}' \; \
          -o -exec /bin/chmod u+rw '{}' \; \
            -exec /bin/chmod -N '{}' \; \) 2>/dev/null || return 1
    else
      [[ -L "$root" ]] || /bin/chmod u+rw "$root" || return 1
      /bin/chmod -h -N "$root" 2>/dev/null || return 1
    fi
  elif [[ -d "$root" && ! -L "$root" ]]; then
    /bin/chmod u+rwx "$root" || return 1
    /usr/bin/find -P "$root" -type d \
      -exec /bin/chmod u+rwx '{}' \; 2>/dev/null || return 1
  fi
  /bin/rm -rf -- "$root"
}

_mdm_remove_runner_tmp() {
  local cleanup_target="${runner_tmp:-}"
  [[ -n "$cleanup_target" ]] || return 0
  if _mdm_remove_runner_tree "$cleanup_target"; then
    runner_tmp=""
    return 0
  fi
  return 1
}

_mdm_runner_exit_cleanup() {
  local exit_code=$?
  trap - EXIT
  if ! _mdm_remove_runner_tmp; then
    printf 'FAIL: runner temporary root cleanup remained incomplete\n' >&2 || true
    [[ "$exit_code" -ne 0 ]] || exit_code=1
  fi
  exit "$exit_code"
}

_mdm_cleanup_nested_runner() { # <signal-name>
  local signal_name="$1" pid="${_MDM_ACTIVE_NESTED_RUNNER_PID:-}"
  local record="${_MDM_ACTIVE_NESTED_RUNNER_RECORD:-}" record_file
  local supervisor_record attempt=0 nested_done=false failed=false
  local nested_wait_status=""
  record_file="${_MDM_ACTIVE_NESTED_SUPERVISOR_RECORD_FILE:-}"
  supervisor_record="${_MDM_ACTIVE_NESTED_SUPERVISOR_RECORD:-}"
  [[ -n "$pid" && -n "$record" ]] || return 0
  while [[ -z "$supervisor_record" && -n "$record_file" \
    && "$attempt" -lt 300 ]]; do
    supervisor_record="$(_mdm_read_nested_supervisor_record \
      "$record_file" "$pid" 2>/dev/null || true)"
    [[ -n "$supervisor_record" ]] && break
    _mdm_record_matches "$pid" "$record" || break
    /bin/sleep 0.02
    attempt=$((attempt + 1))
  done
  _MDM_ACTIVE_NESTED_SUPERVISOR_RECORD="$supervisor_record"
  _mdm_signal_record "$record" "$signal_name" || true
  if _mdm_wait_bound_supervisor "$pid" "$record"; then
    nested_done=true
    nested_wait_status="$_MDM_LAST_BOUND_WAIT_STATUS"
  fi
  if [[ -n "$supervisor_record" ]] \
    && _mdm_session_record_matches "$supervisor_record"; then
    _mdm_external_cleanup_session "$supervisor_record" || failed=true
    _mdm_session_record_matches "$supervisor_record" && failed=true
  fi
  if [[ "$nested_done" != true ]]; then
    _mdm_signal_record "$record" TERM || true
    if _mdm_wait_bound_supervisor "$pid" "$record"; then
      nested_done=true
      nested_wait_status="$_MDM_LAST_BOUND_WAIT_STATUS"
    else
      _mdm_signal_record "$record" KILL || true
      if _mdm_wait_bound_supervisor "$pid" "$record"; then
        nested_done=true
        nested_wait_status="$_MDM_LAST_BOUND_WAIT_STATUS"
      fi
    fi
  fi
  _MDM_NESTED_RUNNER_WAIT_STATUS="$nested_wait_status"
  [[ "$nested_done" == true && "$failed" == false ]]
}

_mdm_handle_runner_signal() { # <signal-name> <exit-code>
  local signal_name="$1" exit_code="$2"
  local pid="${_MDM_ACTIVE_SUPERVISOR_PID:-}"
  local record="${_MDM_ACTIVE_SUPERVISOR_RECORD:-}"
  trap '' HUP INT TERM
  if ! _mdm_cleanup_nested_runner "$signal_name"; then
    printf 'FAIL: runner could not fully collect its nested self-test\n' \
      >&2 || true
  fi
  _MDM_ACTIVE_NESTED_RUNNER_PID=""
  _MDM_ACTIVE_NESTED_RUNNER_RECORD=""
  _MDM_ACTIVE_NESTED_RUNNER_DIAGNOSTIC=""
  _MDM_ACTIVE_NESTED_SUPERVISOR_RECORD=""
  _MDM_ACTIVE_NESTED_SUPERVISOR_RECORD_FILE=""
  if [[ -n "$pid" && -n "$record" ]]; then
    printf 'FAIL: runner received %s while running %s; collecting session\n' \
      "$signal_name" "${_MDM_ACTIVE_LABEL:-unknown}" >&2 || true
    if [[ "${_MDM_FORCE_SUPERVISOR_CLEANUP_FAILURE:-false}" == true ]]; then
      printf 'FAIL: runner self-test forced local supervisor cleanup failure\n' \
        >&2 || true
    elif ! _mdm_cleanup_bound_supervisor "$pid" "$record" "$signal_name"; then
      printf 'FAIL: runner could not fully collect its supervised session\n' \
        >&2 || true
    fi
  fi
  _MDM_ACTIVE_SUPERVISOR_PID=""
  _MDM_ACTIVE_SUPERVISOR_RECORD=""
  _MDM_ACTIVE_LABEL=""
  if ! _mdm_remove_runner_tmp; then
    printf 'FAIL: runner signal cleanup left its temporary root\n' >&2 || true
  fi
  trap - EXIT
  exit "$exit_code"
}

_mdm_arm_runner_signal_traps() {
  trap '_mdm_runner_exit_cleanup' EXIT
  trap '_mdm_handle_runner_signal HUP 129' HUP
  trap '_mdm_handle_runner_signal INT 130' INT
  trap '_mdm_handle_runner_signal TERM 143' TERM
}

_mdm_note_launch_signal() { # <signal-name>
  [[ -n "$_MDM_LAUNCH_SIGNAL" ]] || _MDM_LAUNCH_SIGNAL="$1"
}

_mdm_run_supervised() { # <timeout> <output> <label> <command...>
  local timeout_seconds="$1" output="$2" label="$3"
  local child_pid child_record="" child_rc=125 attempt=0
  local pid ppid pgid _uid state _started pending ready=false
  local record_output="${_MDM_SUPERVISOR_RECORD_OUTPUT:-}"
  local record_parent="" record_published=true
  shift 3
  _MDM_LAUNCH_SIGNAL=""
  trap '_mdm_note_launch_signal HUP' HUP
  trap '_mdm_note_launch_signal INT' INT
  trap '_mdm_note_launch_signal TERM' TERM
  set +m
  "$MDM_TEST_SYSTEM_PYTHON" -I -B -S "$SUPERVISOR" \
    --timeout "$timeout_seconds" -- "$@" >"$output" 2>&1 &
  child_pid=$!
  _MDM_ACTIVE_SUPERVISOR_PID="$child_pid"
  _MDM_ACTIVE_LABEL="$label"
  while [[ "$attempt" -lt 250 ]]; do
    child_record="$(_mdm_process_record "$child_pid" || true)"
    if [[ -n "$child_record" ]]; then
      IFS='|' read -r pid ppid pgid _uid state _started <<< "$child_record"
      if [[ "$pid" == "$child_pid" && "$ppid" == "$$" \
        && "$pgid" == "$child_pid" && "$state" == *T* ]] \
        && grep -q "^MDM_SUPERVISOR_READY pid=$child_pid sid=$child_pid$" \
          "$output"; then
        ready=true
        break
      fi
    fi
    [[ "$(jobs -p %+ 2>/dev/null || true)" == "$child_pid" ]] || break
    /bin/sleep 0.02
    attempt=$((attempt + 1))
  done
  if [[ "$ready" == true && -n "$record_output" ]]; then
    record_parent="${record_output%/*}"
    if [[ "$record_output" != /* || ! -d "$record_parent" \
      || -L "$record_parent" || -e "$record_output" \
      || -L "$record_output" \
      || "$(cd -P "$record_parent" && /bin/pwd -P)" != "$record_parent" ]] \
      || ! (set -o noclobber; printf '%s\n' "$child_record" \
        > "$record_output"); then
      record_published=false
    fi
  fi
  if [[ -z "$child_record" || "$pid" != "$child_pid" \
    || "$ppid" != "$$" || "$pgid" != "$child_pid" \
    || "$state" != *T* || "$ready" != true \
    || "$record_published" != true ]]; then
    printf 'FAIL: supervisor did not establish a stopped session for %s\n' \
      "$label" >> "$output"
    if [[ -n "$child_record" ]]; then
      _mdm_cleanup_bound_supervisor "$child_pid" "$child_record" TERM || true
    else
      _mdm_cleanup_unbound_direct_child "$child_pid" || true
    fi
    _MDM_ACTIVE_SUPERVISOR_PID=""
    _MDM_ACTIVE_SUPERVISOR_RECORD=""
    _MDM_ACTIVE_LABEL=""
    _mdm_arm_runner_signal_traps
    pending="$_MDM_LAUNCH_SIGNAL"
    _MDM_LAUNCH_SIGNAL=""
    case "$pending" in
      HUP) _mdm_handle_runner_signal HUP 129 ;;
      INT) _mdm_handle_runner_signal INT 130 ;;
      TERM) _mdm_handle_runner_signal TERM 143 ;;
    esac
    return 125
  fi

  _MDM_ACTIVE_SUPERVISOR_RECORD="$child_record"
  _mdm_arm_runner_signal_traps
  pending="$_MDM_LAUNCH_SIGNAL"
  _MDM_LAUNCH_SIGNAL=""
  case "$pending" in
    HUP) _mdm_handle_runner_signal HUP 129 ;;
    INT) _mdm_handle_runner_signal INT 130 ;;
    TERM) _mdm_handle_runner_signal TERM 143 ;;
  esac

  if ! _mdm_signal_record "$child_record" CONT; then
    printf 'FAIL: supervisor session changed before launch for %s\n' \
      "$label" >> "$output"
    _mdm_cleanup_bound_supervisor "$child_pid" "$child_record" TERM || true
    child_rc=125
  elif wait "$child_pid"; then
    child_rc=0
  else
    child_rc=$?
  fi

  # Never reinterpret a reaped numeric PID as a new direct child.
  _MDM_ACTIVE_SUPERVISOR_PID=""
  _MDM_ACTIVE_SUPERVISOR_RECORD=""
  _MDM_ACTIVE_LABEL=""
  return "$child_rc"
}
