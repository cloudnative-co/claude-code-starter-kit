#!/bin/bash
# tests/unit/test-mdm-lock.sh - MDM remediation lock compatibility tests

MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"

_mdm_test_reset_lock_state() {
  _MDM_RUN_LOCK_FILE=""
  _MDM_RUN_LOCK_BASE=""
  _MDM_RUN_LOCK_MODE=""
  _MDM_RUN_LOCK_HOLDER_PID=""
  _MDM_RUN_LOCK_WORKER_PID=""
  _MDM_RUN_LOCK_CONTROL_DIR=""
}

_mdm_test_write_lockf_wrapper() { # <path>
  local _path="$1"
  cat > "$_path" <<'EOF'
#!/bin/bash
if [[ "$#" -eq 4 && "$1" == -s && "$2" == -t \
  && "$3" == 0 && "$4" == 19 ]]; then
  printf 'probe:%s\n' "$MDM_LOCKF_PROBE_RC" >> "$MDM_LOCKF_TEST_LOG"
  exit "$MDM_LOCKF_PROBE_RC"
fi
printf 'command\n' >> "$MDM_LOCKF_TEST_LOG"
exec /usr/bin/lockf "$@"
EOF
  chmod 700 "$_path"
}

_mdm_test_wait_for_file() { # <path> <child-pid>
  local _path="$1" _child="$2" _count=0
  while [[ ! -e "$_path" && "$_count" -lt 500 ]]; do
    /bin/kill -0 "$_child" 2>/dev/null || break
    /bin/sleep 0.01
    _count=$((_count + 1))
  done
  [[ -e "$_path" ]]
}

_mdm_test_wait_child_bounded() { # <child-pid>
  local _child="$1" _watchdog _rc=0
  (
    trap 'exit 0' TERM
    _watch_count=0
    while [[ "$_watch_count" -lt 500 ]]; do
      /bin/sleep 0.01
      _watch_count=$((_watch_count + 1))
    done
    /bin/kill -TERM "$_child" 2>/dev/null || exit 0
    /bin/sleep 0.2
    /bin/kill -KILL "$_child" 2>/dev/null || true
  ) &
  _watchdog=$!
  wait "$_child" 2>/dev/null || _rc=$?
  /bin/kill -TERM "$_watchdog" 2>/dev/null || true
  wait "$_watchdog" 2>/dev/null || true
  return "$_rc"
}

_lock_gate_line="$(grep -nF '_mdm_acquire_run_lock "$_user" "$_home"' \
  "$PROJECT_DIR/mdm/install-mdm.sh" | head -1 | cut -d: -f1)"
_log_setup_line="$(grep -nF '_mdm_setup_log_file "$_euid" "$_home"' \
  "$PROJECT_DIR/mdm/install-mdm.sh" | head -1 | cut -d: -f1)"
if [[ "$_lock_gate_line" =~ ^[0-9]+$ && "$_log_setup_line" =~ ^[0-9]+$ \
  && "$_lock_gate_line" -lt "$_log_setup_line" ]]; then
  pass "mdm-lock: mutating main は log/setup/receipt より前に lock を取得"
else
  fail "mdm-lock: main の lock gate 配線順が不正"
fi

_mdm_test_legacy_contention() { # <tmp>
  local _tmp="$1"
  local _support="$_tmp/support" _wrapper="$_tmp/legacy-lockf"
  local _log="$_tmp/lockf.log" _holder _contender _count _rc _contender_rc
  local _reuse_holder _reuse_worker _residue _fd_open=0
  mkdir -p "$_support" || return 1
  chmod 755 "$_support" || return 1
  _mdm_test_write_lockf_wrapper "$_wrapper" || return 1
  printf 'sentinel\n' > "$_support/receipt-jane.json"
  /bin/cp "$_support/receipt-jane.json" "$_tmp/receipt.before" || return 1
  export MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_support"
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  export MDM_LOCKF_OVERRIDE="$_wrapper"
  export MDM_LOCKF_TEST_LOG="$_log"
  export MDM_LOCKF_PROBE_RC=64

  (
    _mdm_test_reset_lock_state
    _mdm_acquire_run_lock jane "$_tmp/home" || exit 31
    : > "$_tmp/holder.ready"
    _count=0
    while [[ ! -e "$_tmp/holder.release" && "$_count" -lt 500 ]]; do
      /bin/sleep 0.01
      _count=$((_count + 1))
    done
    [[ -e "$_tmp/holder.release" ]] || exit 32
    _mdm_release_run_lock || exit 33
    : > "$_tmp/holder.done"
  ) &
  _holder=$!
  if ! _mdm_test_wait_for_file "$_tmp/holder.ready" "$_holder"; then
    /bin/kill -TERM "$_holder" 2>/dev/null || true
    _mdm_test_wait_child_bounded "$_holder" || true
    return 1
  fi

  (
    _mdm_test_reset_lock_state
    _rc=0
    _mdm_acquire_run_lock jane "$_tmp/home" >/dev/null 2>&1 || _rc=$?
    [[ "$_rc" -ne 0 ]] || _mdm_release_run_lock
    printf '%s\n' "$_rc" > "$_tmp/contender.rc"
  ) &
  _contender=$!
  if ! _mdm_test_wait_for_file "$_tmp/contender.rc" "$_contender"; then
    /bin/kill -TERM "$_contender" 2>/dev/null || true
    _mdm_test_wait_child_bounded "$_contender" || true
    /bin/kill -TERM "$_holder" 2>/dev/null || true
    _mdm_test_wait_child_bounded "$_holder" || true
    return 1
  fi
  _mdm_test_wait_child_bounded "$_contender" || return 1
  _contender_rc="$(/bin/cat "$_tmp/contender.rc")"
  [[ "$_contender_rc" =~ ^[0-9]+$ && "$_contender_rc" -ne 0 ]] || return 1

  : > "$_tmp/holder.release"
  _mdm_test_wait_child_bounded "$_holder" || return 1
  [[ -f "$_tmp/holder.done" ]] || return 1

  _mdm_test_reset_lock_state
  _mdm_acquire_run_lock jane "$_tmp/home" || return 1
  [[ "$_MDM_RUN_LOCK_MODE" == legacy ]] || return 1
  _reuse_holder="$_MDM_RUN_LOCK_HOLDER_PID"
  _reuse_worker="$_MDM_RUN_LOCK_WORKER_PID"
  _mdm_release_run_lock || return 1
  { : >&19; } 2>/dev/null && _fd_open=1
  _residue="$(find "$_support" -maxdepth 1 \
    -name '.remediation-lock.*' -print -quit)"

  [[ "$(sed -n '1p' "$_log")" == probe:64 ]] || return 1
  [[ "$(sed -n '2p' "$_log")" == command ]] || return 1
  [[ -z "$_MDM_RUN_LOCK_FILE$_MDM_RUN_LOCK_BASE$_MDM_RUN_LOCK_MODE" ]] || return 1
  [[ -z "$_MDM_RUN_LOCK_HOLDER_PID$_MDM_RUN_LOCK_WORKER_PID" ]] || return 1
  [[ -z "$_MDM_RUN_LOCK_CONTROL_DIR" && -z "$_residue" ]] || return 1
  [[ "$_fd_open" -eq 0 ]] || return 1
  ! /bin/kill -0 "$_reuse_holder" 2>/dev/null || return 1
  ! /bin/kill -0 "$_reuse_worker" 2>/dev/null || return 1
  /usr/bin/cmp -s "$_tmp/receipt.before" "$_support/receipt-jane.json"
}

_mdm_test_legacy_crash_cleanup() { # <tmp>
  local _tmp="$1"
  local _support="$_tmp/support" _wrapper="$_tmp/legacy-lockf"
  local _owner _info _control _holder _worker _count=0 _residue
  mkdir -p "$_support" || return 1
  chmod 755 "$_support" || return 1
  _mdm_test_write_lockf_wrapper "$_wrapper" || return 1
  export MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_support"
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  export MDM_LOCKF_OVERRIDE="$_wrapper"
  export MDM_LOCKF_TEST_LOG="$_tmp/lockf.log"
  export MDM_LOCKF_PROBE_RC=64

  (
    _mdm_test_reset_lock_state
    _mdm_acquire_run_lock jane "$_tmp/home" || exit 41
    printf '%s:%s:%s\n' "$_MDM_RUN_LOCK_CONTROL_DIR" \
      "$_MDM_RUN_LOCK_HOLDER_PID" "$_MDM_RUN_LOCK_WORKER_PID" \
      > "$_tmp/crash.info"
    : > "$_tmp/crash.ready"
    while :; do /bin/sleep 1; done
  ) &
  _owner=$!
  if ! _mdm_test_wait_for_file "$_tmp/crash.ready" "$_owner"; then
    /bin/kill -TERM "$_owner" 2>/dev/null || true
    _mdm_test_wait_child_bounded "$_owner" || true
    return 1
  fi
  _info="$(/bin/cat "$_tmp/crash.info")"
  _control="${_info%%:*}"
  _info="${_info#*:}"; _holder="${_info%%:*}"; _worker="${_info#*:}"
  [[ "$_holder" =~ ^[0-9]+$ && "$_worker" =~ ^[0-9]+$ ]] || return 1
  /bin/kill -KILL "$_owner" 2>/dev/null || return 1
  _mdm_test_wait_child_bounded "$_owner" || true
  while [[ "$_count" -lt 500 ]]; do
    if [[ ! -e "$_control" ]] \
      && ! /bin/kill -0 "$_holder" 2>/dev/null \
      && ! /bin/kill -0 "$_worker" 2>/dev/null; then
      break
    fi
    /bin/sleep 0.01
    _count=$((_count + 1))
  done
  [[ ! -e "$_control" ]] || return 1
  ! /bin/kill -0 "$_holder" 2>/dev/null || return 1
  ! /bin/kill -0 "$_worker" 2>/dev/null || return 1

  _mdm_test_reset_lock_state
  _mdm_acquire_run_lock jane "$_tmp/home" || return 1
  _mdm_release_run_lock || return 1
  _residue="$(find "$_support" -maxdepth 1 \
    -name '.remediation-lock.*' -print -quit)"
  [[ -z "$_residue" ]]
}

_mdm_test_nonusage_failure() { # <tmp>
  local _tmp="$1"
  local _support="$_tmp/support" _wrapper="$_tmp/lockf-fail"
  local _rc=0 _residue _fd_open=0
  mkdir -p "$_support" || return 1
  chmod 755 "$_support" || return 1
  _mdm_test_write_lockf_wrapper "$_wrapper" || return 1
  export MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_support"
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  export MDM_LOCKF_OVERRIDE="$_wrapper"
  export MDM_LOCKF_TEST_LOG="$_tmp/lockf.log"
  export MDM_LOCKF_PROBE_RC=75
  _mdm_test_reset_lock_state
  _mdm_acquire_run_lock jane "$_tmp/home" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]]; then
    _mdm_release_run_lock || true
    return 1
  fi
  { : >&19; } 2>/dev/null && _fd_open=1
  _residue="$(find "$_support" -maxdepth 1 \
    -name '.remediation-lock.*' -print -quit)"
  [[ "$(/bin/cat "$_tmp/lockf.log")" == probe:75 ]] || return 1
  [[ -z "$_MDM_RUN_LOCK_MODE$_MDM_RUN_LOCK_CONTROL_DIR$_residue" ]] || return 1
  [[ "$_fd_open" -eq 0 ]]
}

if [[ -x /usr/bin/lockf ]]; then
  _legacy_tmp="$(mktemp -d)"
  if ( _mdm_test_legacy_contention "$_legacy_tmp" ); then
    pass "mdm-lock: legacy lockf は probe→command・競合拒否・再利用・清掃を維持"
  else
    fail "mdm-lock: legacy lockf compatibility contract が不正"
  fi
  rm -rf "$_legacy_tmp"

  _crash_tmp="$(mktemp -d)"
  if ( _mdm_test_legacy_crash_cleanup "$_crash_tmp" ); then
    pass "mdm-lock: legacy holder は owner 強制終了後に lock と制御領域を清掃"
  else
    fail "mdm-lock: legacy holder の crash cleanup が不正"
  fi
  rm -rf "$_crash_tmp"

  _failure_tmp="$(mktemp -d)"
  if ( _mdm_test_nonusage_failure "$_failure_tmp" ); then
    pass "mdm-lock: EX_USAGE 以外の fd probe 失敗は fallback せず fail-closed"
  else
    fail "mdm-lock: fd probe failure の分岐が不正"
  fi
  rm -rf "$_failure_tmp"
else
  skip "mdm-lock: macOS lockf compatibility" "/usr/bin/lockf unavailable"
fi
