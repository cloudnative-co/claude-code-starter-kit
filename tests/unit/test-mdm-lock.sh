#!/bin/bash
# tests/unit/test-mdm-lock.sh - MDM remediation lock compatibility tests
MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"
_mdm_test_reset_lock_state() {
  { exec 18>&-; } 2>/dev/null || true
  { exec 19>&-; } 2>/dev/null || true
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
}
_MDM_TEST_BG_TMP=""
_MDM_TEST_BG_HOLDER=""
_MDM_TEST_BG_SUPERVISOR=""
_MDM_TEST_BG_DESCENDANT=""
_mdm_test_cleanup_background() {
  if [[ -n "$_MDM_TEST_BG_TMP" && -d "$_MDM_TEST_BG_TMP" ]]; then
    : > "$_MDM_TEST_BG_TMP/holder.release" 2>/dev/null || true
    : > "$_MDM_TEST_BG_TMP/supervisor.release" 2>/dev/null || true
    : > "$_MDM_TEST_BG_TMP/descendant.release" 2>/dev/null || true
    : > "$_MDM_TEST_BG_TMP/drop-worker.release" 2>/dev/null || true
  fi
  if [[ "$_MDM_TEST_BG_SUPERVISOR" =~ ^[0-9]+$ ]]; then
    /bin/kill -TERM "$_MDM_TEST_BG_SUPERVISOR" 2>/dev/null || true
  fi
  if [[ "$_MDM_TEST_BG_DESCENDANT" =~ ^[0-9]+$ ]]; then
    /bin/kill -TERM "$_MDM_TEST_BG_DESCENDANT" 2>/dev/null || true
  fi
  if [[ "$_MDM_TEST_BG_HOLDER" =~ ^[0-9]+$ ]]; then
    /bin/kill -TERM "$_MDM_TEST_BG_HOLDER" 2>/dev/null || true
  fi
  /bin/sleep 0.1
  if [[ "$_MDM_TEST_BG_SUPERVISOR" =~ ^[0-9]+$ ]]; then
    /bin/kill -KILL "$_MDM_TEST_BG_SUPERVISOR" 2>/dev/null || true
  fi
  if [[ "$_MDM_TEST_BG_DESCENDANT" =~ ^[0-9]+$ ]]; then
    /bin/kill -KILL "$_MDM_TEST_BG_DESCENDANT" 2>/dev/null || true
  fi
  if [[ "$_MDM_TEST_BG_HOLDER" =~ ^[0-9]+$ ]]; then
    /bin/kill -KILL "$_MDM_TEST_BG_HOLDER" 2>/dev/null || true
  fi
  _mdm_release_run_lock >/dev/null 2>&1 || true
}
_mdm_test_arm_background_cleanup() {
  trap '_mdm_test_cleanup_background' EXIT
  trap '_mdm_test_cleanup_background; exit 130' INT
  trap '_mdm_test_cleanup_background; exit 143' TERM
}
_mdm_test_disarm_background_cleanup() {
  trap - EXIT INT TERM
  _MDM_TEST_BG_TMP=""
  _MDM_TEST_BG_HOLDER=""
  _MDM_TEST_BG_SUPERVISOR=""
  _MDM_TEST_BG_DESCENDANT=""
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
_mdm_test_write_drop_wrappers() { # <tmp>
  local _tmp="$1"
  cat > "$_tmp/launchctl" <<'EOF'
#!/bin/bash
[[ "$1" == asuser && "$2" =~ ^[0-9]+$ ]] || exit 64
shift 2
exec "$@"
EOF
  cat > "$_tmp/sudo" <<'EOF'
#!/bin/bash
[[ "$1" == -u && "$2" == \#* && "$3" == -H ]] || exit 64
shift 3
exec 18>&- 19>&-
exec "$@"
EOF
  cat > "$_tmp/drop-worker" <<'EOF'
#!/bin/bash
_tmp="$1"
_desc=""
_stop_descendant() {
  [[ "$_desc" =~ ^[0-9]+$ ]] || return 0
  /bin/kill -TERM "$_desc" 2>/dev/null || true
  wait "$_desc" 2>/dev/null || true
}
trap '_stop_descendant; exit 143' HUP INT TERM
(
  trap 'exit 0' HUP INT TERM
  while :; do /bin/sleep 1; done
) &
_desc=$!
printf '%s\n' "$$" > "$_tmp/drop-worker.pid"
printf '%s\n' "$_desc" > "$_tmp/drop-grandchild.pid"
: > "$_tmp/drop-worker.ready"
while [[ ! -e "$_tmp/drop-worker.release" ]]; do
  /bin/sleep 0.01
done
_stop_descendant
EOF
  chmod 700 "$_tmp/launchctl" "$_tmp/sudo" "$_tmp/drop-worker"
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
_mdm_test_wait_for_absence() { # <path>
  local _path="$1" _count=0
  while [[ -e "$_path" && "$_count" -lt 500 ]]; do
    /bin/sleep 0.01
    _count=$((_count + 1))
  done
  [[ ! -e "$_path" ]]
}
_mdm_test_wait_for_pid_absence() { # <pid>
  local _pid="$1" _count=0
  while /bin/kill -0 "$_pid" 2>/dev/null && [[ "$_count" -lt 500 ]]; do
    /bin/sleep 0.01
    _count=$((_count + 1))
  done
  ! /bin/kill -0 "$_pid" 2>/dev/null
}
_mdm_test_wait_child_bounded() { # <child-pid>
  local _child="$1" _watchdog _rc=0
  (
    trap 'exit 0' TERM
    _watch_count=0
    while [[ "$_watch_count" -lt 1000 ]]; do
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
_mdm_test_configure_lock_backend() { # <tmp> <fd|legacy|mkdir>
  local _tmp="$1" _backend="$2" _support
  _support="$_tmp/support"
  mkdir -p "$_support" || return 1
  chmod 755 "$_support" || return 1
  export MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_support"
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  MDM_AUTH_OWNER_UID_OVERRIDE="$(/usr/bin/id -u)"
  export MDM_AUTH_OWNER_UID_OVERRIDE
  unset MDM_LOCKF_PROBE_RC MDM_LOCKF_TEST_LOG MDM_LOCKF_OVERRIDE
  case "$_backend" in
    fd)
      [[ -x /usr/bin/lockf ]] || return 1 ;;
    legacy)
      _mdm_test_write_lockf_wrapper "$_tmp/legacy-lockf" || return 1
      export MDM_LOCKF_OVERRIDE="$_tmp/legacy-lockf"
      export MDM_LOCKF_TEST_LOG="$_tmp/lockf.log"
      export MDM_LOCKF_PROBE_RC=64 ;;
    mkdir)
      export MDM_LOCKF_OVERRIDE="$_tmp/lockf-unavailable" ;;
    *) return 1 ;;
  esac
}
_mdm_test_global_contention_cycle() { # <tmp> <fd|legacy|mkdir>
  local _tmp="$1" _backend="$2" _expected_mode
  local _holder _contender _contender_rc _contender_error _count=0 _lock
  local _residue="" _fd18_open=0
  _expected_mode="$_backend"
  _mdm_test_configure_lock_backend "$_tmp" "$_backend" || return 1
  _MDM_TEST_BG_TMP="$_tmp"
  (
    _mdm_test_reset_lock_state
    _mdm_acquire_run_lock alice "$_tmp/home-alice" || exit 21
    printf '%s\n' "$_MDM_RUN_LOCK_MODE" > "$_tmp/holder.mode"
    : > "$_tmp/holder.ready"
    while [[ ! -e "$_tmp/holder.release" && "$_count" -lt 500 ]]; do
      /bin/sleep 0.01
      _count=$((_count + 1))
    done
    [[ -e "$_tmp/holder.release" ]] || exit 22
    _mdm_release_run_lock || exit 23
    : > "$_tmp/holder.done"
  ) &
  _holder=$!
  _MDM_TEST_BG_HOLDER="$_holder"
  _mdm_test_arm_background_cleanup
  if ! _mdm_test_wait_for_file "$_tmp/holder.ready" "$_holder"; then
    /bin/kill -TERM "$_holder" 2>/dev/null || true
    _mdm_test_wait_child_bounded "$_holder" || true
    return 1
  fi
  [[ "$(/bin/cat "$_tmp/holder.mode")" == "$_expected_mode" ]] || return 1
  (
    _mdm_test_reset_lock_state
    _contender_rc=0
    _mdm_acquire_run_lock bob "$_tmp/home-bob" >/dev/null 2>&1 \
      || _contender_rc=$?
    [[ "$_contender_rc" -ne 0 ]] || _mdm_release_run_lock
    printf '%s\t%s\n' "$_contender_rc" "${_MDM_RUN_LOCK_ERROR:-}" \
      > "$_tmp/contender.rc"
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
  IFS=$'\t' read -r _contender_rc _contender_error < "$_tmp/contender.rc" \
    || return 1
  [[ "$_contender_rc" =~ ^[0-9]+$ && "$_contender_rc" -ne 0 ]] || return 1
  [[ "$_contender_error" == contention ]] || return 1
  : > "$_tmp/holder.release"
  _mdm_test_wait_child_bounded "$_holder" || return 1
  [[ -f "$_tmp/holder.done" ]] || return 1
  _mdm_test_reset_lock_state
  _mdm_acquire_run_lock carol "$_tmp/home-carol" || return 1
  _mdm_test_arm_background_cleanup
  [[ "$_MDM_RUN_LOCK_MODE" == "$_expected_mode" ]] || return 1
  _lock="$_MDM_RUN_LOCK_FILE"
  case "$_backend" in
    fd|legacy) [[ "$_lock" == "$_tmp/support/remediation-global.lock" ]] || return 1 ;;
    mkdir) [[ "$_lock" == "$_tmp/support/remediation-global.mkdir-lock" ]] || return 1 ;;
  esac
  _mdm_release_run_lock || return 1
  [[ -z "$_MDM_RUN_LOCK_FILE$_MDM_RUN_LOCK_MODE$_MDM_RUN_LOCK_ERROR" ]] \
    || return 1
  if [[ "$_backend" == legacy ]]; then
    /usr/bin/grep -qx 'probe:64' "$_tmp/lockf.log" || return 1
    /usr/bin/grep -qx 'command' "$_tmp/lockf.log" || return 1
    _residue="$(find "$_tmp/support" -maxdepth 1 \
      -name '.remediation-lock.*' -print -quit)"
    { : >&18; } 2>/dev/null && _fd18_open=1
    [[ -z "$_residue" && "$_fd18_open" -eq 0 ]] || return 1
  fi
  _mdm_test_disarm_background_cleanup
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
_drop_exec_body="$(sed -n '/^_mdm_exec_as_user()/,/^}/p' \
  "$PROJECT_DIR/mdm/install-mdm.sh")"
if printf '%s\n' "$_drop_exec_body" \
  | grep -q '_MDM_ACTIVE_DROP_SUPERVISOR_PID' \
  && printf '%s\n' "$_drop_exec_body" | grep -Eq '[[:space:]]&[[:space:]]*$' \
  && printf '%s\n' "$_drop_exec_body" | grep -q 'wait' \
  && printf '%s\n' "$_drop_exec_body" | grep -q 'TZ=UTC0'; then
  pass "mdm-lock: user drop は追跡可能な foreground supervisor として待機"
else
  fail "mdm-lock: _mdm_exec_as_user の supervisor 配線が不正"
fi
_cleanup_body="$(sed -n '/^_mdm_cleanup_transient_checkouts()/,/^}/p' \
  "$PROJECT_DIR/mdm/install-mdm.sh")"
_stop_line="$(printf '%s\n' "$_cleanup_body" \
  | grep -n '_mdm_stop_active_drop_supervisor' | head -1 | cut -d: -f1 || true)"
_release_line="$(printf '%s\n' "$_cleanup_body" \
  | grep -n '_mdm_release_run_lock' | head -1 | cut -d: -f1 || true)"
if [[ "$_stop_line" =~ ^[0-9]+$ && "$_release_line" =~ ^[0-9]+$ \
  && "$_stop_line" -lt "$_release_line" ]]; then
  pass "mdm-lock: signal/EXIT cleanup は active supervisor 停止後に lock を解放"
else
  fail "mdm-lock: transient cleanup の supervisor/lock 順序が不正"
fi
_main_lock_body="$(sed -n '/# Serialize every mutating run/,/# ログ開始/p' \
  "$PROJECT_DIR/mdm/install-mdm.sh")"
if printf '%s\n' "$_main_lock_body" | grep -q 'exit "$MDM_EXIT_CONTEXT"' \
  && printf '%s\n' "$_main_lock_body" | grep -q 'exit "$MDM_EXIT_OS"'; then
  pass "mdm-lock: main は contention=21 と backend=60 を区別"
else
  fail "mdm-lock: main の contention/backend exit 分類が不正"
fi
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
  [[ "$_MDM_RUN_LOCK_ERROR" == contention ]] || return 1
  [[ -z "$_MDM_RUN_LOCK_MODE$_MDM_RUN_LOCK_CONTROL_DIR$_residue" ]] || return 1
  [[ "$_fd_open" -eq 0 ]]
}
_mdm_test_supervisor_lifetime() { # <tmp> <fd|legacy|mkdir>
  local _tmp="$1" _backend="$2" _holder _worker _grandchild _info
  local _rc=0 _attempt=0 _acquired=0
  _mdm_test_configure_lock_backend "$_tmp" "$_backend" || return 1
  _mdm_test_write_drop_wrappers "$_tmp" || return 1
  /bin/mkdir -p "$_tmp/home-alice" || return 1
  /bin/chmod 700 "$_tmp/home-alice" || return 1
  export MDM_LAUNCHCTL_OVERRIDE="$_tmp/launchctl"
  export MDM_SUDO_OVERRIDE="$_tmp/sudo"
  _MDM_TEST_BG_TMP="$_tmp"
  /bin/bash -c '
    MDM_SOURCE_ONLY=1 source "$1/mdm/install-mdm.sh"
    _mdm_acquire_run_lock alice "$2/home-alice" || exit 51
    printf "%s\n" "$_MDM_RUN_LOCK_MODE" > "$2/lifetime.mode"
    : > "$2/coordinator.ready"
    _mdm_exec_as_user 501 alice "$2/home-alice" "$2/drop-worker" "$2"
    _rc=$?
    printf "%s\n" "$_rc" > "$2/drop-worker.rc"
    _mdm_release_run_lock || exit 52
    exit "$_rc"
  ' mdm-lock-lifetime "$PROJECT_DIR" "$_tmp" 2>"$_tmp/lifetime.stderr" &
  _holder=$!
  _MDM_TEST_BG_HOLDER="$_holder"
  _mdm_test_arm_background_cleanup
  if ! _mdm_test_wait_for_file "$_tmp/coordinator.ready" "$_holder" \
    || ! _mdm_test_wait_for_file "$_tmp/drop-worker.ready" "$_holder"; then
    /bin/kill -KILL "$_holder" 2>/dev/null || true
    _mdm_test_wait_child_bounded "$_holder" || true
    return 1
  fi
  _info="$(/bin/cat "$_tmp/drop-worker.pid")"
  [[ "$_info" =~ ^[0-9]+$ ]] || return 1
  _worker="$_info"
  _grandchild="$(/bin/cat "$_tmp/drop-grandchild.pid")"
  [[ "$_grandchild" =~ ^[0-9]+$ ]] || return 1
  [[ "$(/bin/cat "$_tmp/lifetime.mode")" == "$_backend" ]] || return 1
  _MDM_TEST_BG_SUPERVISOR="$_worker"
  _MDM_TEST_BG_DESCENDANT="$_grandchild"
  /bin/kill -KILL "$_holder" 2>/dev/null || return 1
  _mdm_test_wait_child_bounded "$_holder" || true
  /bin/kill -0 "$_worker" 2>/dev/null || return 1
  /bin/kill -0 "$_grandchild" 2>/dev/null || return 1
  _mdm_test_reset_lock_state
  _mdm_acquire_run_lock bob "$_tmp/home-bob" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]]; then
    _mdm_test_arm_background_cleanup
    _mdm_release_run_lock || true
    /bin/kill -TERM "$_worker" 2>/dev/null || true
    return 1
  fi
  [[ "$_MDM_RUN_LOCK_ERROR" == contention ]] || return 1
  : > "$_tmp/drop-worker.release"
  _mdm_test_wait_for_pid_absence "$_worker" || return 1
  _mdm_test_wait_for_pid_absence "$_grandchild" || return 1
  while [[ "$_attempt" -lt 500 ]]; do
    _mdm_test_reset_lock_state
    if _mdm_acquire_run_lock carol "$_tmp/home-carol" >/dev/null 2>&1; then
      _acquired=1
      _mdm_test_arm_background_cleanup
      break
    fi
    /bin/sleep 0.01
    _attempt=$((_attempt + 1))
  done
  [[ "$_acquired" -eq 1 && "$_MDM_RUN_LOCK_MODE" == "$_backend" ]] || return 1
  _mdm_release_run_lock || return 1
  _mdm_test_disarm_background_cleanup
}
_mdm_test_term_cleanup_order() { # <tmp> <fd|legacy|mkdir>
  local _tmp="$1" _backend="$2" _holder _worker _grandchild _info
  local _coord_rc=0 _attempt=0 _acquired=0
  declare -f _mdm_stop_active_drop_supervisor >/dev/null 2>&1 || return 1
  _mdm_test_configure_lock_backend "$_tmp" "$_backend" || return 1
  _mdm_test_write_drop_wrappers "$_tmp" || return 1
  /bin/mkdir -p "$_tmp/home-alice" || return 1
  /bin/chmod 700 "$_tmp/home-alice" || return 1
  export MDM_LAUNCHCTL_OVERRIDE="$_tmp/launchctl"
  export MDM_SUDO_OVERRIDE="$_tmp/sudo"
  _MDM_TEST_BG_TMP="$_tmp"
  /bin/bash -c '
    MDM_SOURCE_ONLY=1 source "$1/mdm/install-mdm.sh"
    _mdm_acquire_run_lock alice "$2/home-alice" || exit 71
    printf "%s\n" "$_MDM_RUN_LOCK_MODE" > "$2/term.mode"
    : > "$2/term-coordinator.ready"
    _mdm_exec_as_user 501 alice "$2/home-alice" "$2/drop-worker" "$2"
    _rc=$?
    _mdm_release_run_lock || exit 72
    exit "$_rc"
  ' mdm-lock-term "$PROJECT_DIR" "$_tmp" 2>"$_tmp/term.stderr" &
  _holder=$!
  _MDM_TEST_BG_HOLDER="$_holder"
  _mdm_test_arm_background_cleanup
  if ! _mdm_test_wait_for_file "$_tmp/term-coordinator.ready" "$_holder" \
    || ! _mdm_test_wait_for_file "$_tmp/drop-worker.ready" "$_holder"; then
    return 1
  fi
  _info="$(/bin/cat "$_tmp/drop-worker.pid")"
  [[ "$_info" =~ ^[0-9]+$ ]] || return 1
  _worker="$_info"
  _grandchild="$(/bin/cat "$_tmp/drop-grandchild.pid")"
  [[ "$_grandchild" =~ ^[0-9]+$ ]] || return 1
  _MDM_TEST_BG_SUPERVISOR="$_worker"
  _MDM_TEST_BG_DESCENDANT="$_grandchild"
  [[ "$(/bin/cat "$_tmp/term.mode")" == "$_backend" ]] || return 1
  /bin/kill -TERM "$_holder" 2>/dev/null || return 1
  _mdm_test_wait_child_bounded "$_holder" || _coord_rc=$?
  [[ "$_coord_rc" -eq 143 ]] || return 1
  _mdm_test_wait_for_pid_absence "$_worker" || return 1
  _mdm_test_wait_for_pid_absence "$_grandchild" || return 1
  while [[ "$_attempt" -lt 500 ]]; do
    _mdm_test_reset_lock_state
    if _mdm_acquire_run_lock bob "$_tmp/home-bob" >/dev/null 2>&1; then
      _acquired=1
      _mdm_test_arm_background_cleanup
      break
    fi
    /bin/sleep 0.01
    _attempt=$((_attempt + 1))
  done
  [[ "$_acquired" -eq 1 && "$_MDM_RUN_LOCK_MODE" == "$_backend" ]] || return 1
  _mdm_release_run_lock || return 1
  _mdm_test_disarm_background_cleanup
}
_mdm_test_mkdir_bad_initialization() { # <tmp>
  local _tmp="$1" _control _target _rc
  _mdm_test_configure_lock_backend "$_tmp" mkdir || return 1
  _control="$_tmp/support/remediation-global.mkdir-lock"
  # A crashed initializer with no owner is recovered after the bounded wait.
  /bin/mkdir "$_control" || return 1
  /bin/chmod 700 "$_control" || return 1
  _mdm_test_reset_lock_state
  _mdm_acquire_run_lock alice "$_tmp/home-a" || return 1
  [[ "$_MDM_RUN_LOCK_MODE" == mkdir && ! -e "$_control/.reap" ]] || return 1
  _mdm_release_run_lock || return 1
  # Neither the fixed control path nor its owner record may be a symlink or a
  # special file.  In all cases acquisition fails closed without touching the
  # symlink target.
  _target="$_tmp/symlink-target"
  /bin/mkdir "$_target" || return 1
  : > "$_target/sentinel"
  /bin/ln -s "$_target" "$_control" || return 1
  _mdm_test_reset_lock_state
  _rc=0; _mdm_acquire_run_lock bob "$_tmp/home-b" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -ne 0 && "$_MDM_RUN_LOCK_ERROR" == backend \
    && -f "$_target/sentinel" ]] || return 1
  /bin/rm -f "$_control" || return 1
  /bin/mkdir "$_control" || return 1
  /bin/chmod 700 "$_control" || return 1
  /usr/bin/mkfifo "$_control/owner" || return 1
  _mdm_test_reset_lock_state
  _rc=0; _mdm_acquire_run_lock carol "$_tmp/home-c" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -ne 0 && "$_MDM_RUN_LOCK_ERROR" == backend \
    && -p "$_control/owner" ]] || return 1
}
_mdm_test_write_record() { # <path> <field...>
  local _path="$1"; shift
  (IFS=$'\t'; printf '%s\n' "$*") > "$_path" || return 1
  /bin/chmod 600 "$_path"
}
_mdm_test_mkdir_reap_recovery() { # <tmp>
  local _tmp="$1" _control _reap _control_id _reap_id _start _rc=0
  _mdm_test_configure_lock_backend "$_tmp" mkdir || return 1
  _control="$_tmp/support/remediation-global.mkdir-lock"
  _reap="$_control/.reap"
  _start="$(_mdm_process_start_identity "$$")" || return 1
  # A bare, interrupted claim is bounded-waited and then recovered.
  /bin/mkdir "$_control" || return 1
  /bin/chmod 700 "$_control" || return 1
  /bin/mkdir "$_reap" || return 1
  /bin/chmod 700 "$_reap" || return 1
  _mdm_test_reset_lock_state
  _mdm_acquire_run_lock bare "$_tmp/home-bare" || return 1
  [[ "$_MDM_RUN_LOCK_MODE" == mkdir && ! -e "$_reap" ]] || return 1
  _mdm_release_run_lock || return 1
  # Stale reap and lock owners authorize generation-bound recovery.
  /bin/mkdir "$_control" || return 1
  /bin/chmod 700 "$_control" || return 1
  /bin/mkdir "$_reap" || return 1
  /bin/chmod 700 "$_reap" || return 1
  _control_id="$(_mdm_persistent_dir_identity "$_control")" || return 1
  _reap_id="$(_mdm_persistent_dir_identity "$_reap")" || return 1
  _mdm_test_write_record "$_control/owner" \
    "$$" "$_start-stale" "$_control_id" || return 1
  _mdm_test_write_record "$_reap/owner" \
    "$$" "$_start-stale" "$_control_id" "$_reap_id" || return 1
  _mdm_test_reset_lock_state
  _mdm_acquire_run_lock stale "$_tmp/home-stale" || return 1
  [[ "$_MDM_RUN_LOCK_MODE" == mkdir && ! -e "$_reap" ]] || return 1
  _mdm_release_run_lock || return 1
  # A live reap owner is contention and must remain untouched.
  /bin/mkdir "$_control" || return 1
  /bin/chmod 700 "$_control" || return 1
  /bin/mkdir "$_reap" || return 1
  /bin/chmod 700 "$_reap" || return 1
  _control_id="$(_mdm_persistent_dir_identity "$_control")" || return 1
  _reap_id="$(_mdm_persistent_dir_identity "$_reap")" || return 1
  _mdm_test_write_record "$_reap/owner" \
    "$$" "$_start" "$_control_id" "$_reap_id" || return 1
  _mdm_test_reset_lock_state
  _mdm_acquire_run_lock live "$_tmp/home-live" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -ne 0 && "$_MDM_RUN_LOCK_ERROR" == contention \
    && -f "$_reap/owner" ]] || return 1
  /bin/rm -f "$_reap/owner" || return 1
  /bin/rmdir "$_reap" "$_control"
}
_mdm_test_mkdir_temp_residue() { # <tmp>
  local _tmp="$1" _control _identity _start
  _mdm_test_configure_lock_backend "$_tmp" mkdir || return 1
  _control="$_tmp/support/remediation-global.mkdir-lock"
  /bin/mkdir "$_control" || return 1
  /bin/chmod 700 "$_control" || return 1
  _identity="$(_mdm_persistent_dir_identity "$_control")" || return 1
  _start="$(_mdm_process_start_identity "$$")" || return 1
  _mdm_test_write_record "$_control/.owner.init.$$" \
    "$$" "$_start-stale" "$_identity" || return 1
  _mdm_test_write_record "$_control/.worker.$$" \
    "$$" "$_start-stale" "$_identity" || return 1
  _mdm_test_reset_lock_state
  _mdm_acquire_run_lock residue "$_tmp/home-residue" || return 1
  [[ "$_MDM_RUN_LOCK_MODE" == mkdir \
    && ! -e "$_control/.owner.init.$$" && ! -e "$_control/.worker.$$" ]] \
    || return 1
  _mdm_release_run_lock
}
_mdm_test_mkdir_reap_worker_ordering() { # <tmp>
  local _tmp="$1" _control _identity _reap_id _live _start _rc=0
  _mdm_test_configure_lock_backend "$_tmp" mkdir || return 1
  _mdm_test_write_drop_wrappers "$_tmp" || return 1
  /bin/mkdir -p "$_tmp/home" || return 1
  /bin/chmod 700 "$_tmp/home" || return 1
  export MDM_LAUNCHCTL_OVERRIDE="$_tmp/launchctl"
  export MDM_SUDO_OVERRIDE="$_tmp/sudo"
  _MDM_TEST_BG_TMP="$_tmp"
  _mdm_test_reset_lock_state
  _mdm_acquire_run_lock owner "$_tmp/home" || return 1
  _mdm_test_arm_background_cleanup
  _control="$_MDM_RUN_LOCK_CONTROL_DIR"
  _identity="$_MDM_RUN_LOCK_DIR_IDENTITY"
  # Claim-first: the real supervisor must refuse worker publication/start.
  _mdm_mkdir_reap_claim_create "$_control" "$_identity" || return 1
  _reap_id="$_MDM_REAP_CLAIM_IDENTITY"
  _mdm_exec_as_user 501 owner "$_tmp/home" \
    "$_tmp/drop-worker" "$_tmp" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -ne 0 && ! -e "$_control/worker" \
    && ! -e "$_tmp/drop-worker.ready" ]] || return 1
  _mdm_mkdir_reap_claim_release \
    "$_control" "$_identity" "$_reap_id" || return 1
  # Worker-first: a live published worker makes the reaper back off.
  ( while [[ ! -e "$_tmp/reap-worker.release" ]]; do /bin/sleep 0.01; done ) &
  _live=$!
  _MDM_TEST_BG_SUPERVISOR="$_live"
  _start="$(_mdm_process_start_identity "$_live")" || return 1
  _mdm_test_write_record "$_control/worker" \
    "$_live" "$_start" "$_identity" || return 1
  _rc=0
  _mdm_mkdir_lock_cleanup "$_tmp/support" "$_control" "$_identity" \
    >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq 2 && -f "$_control/worker" && ! -e "$_control/.reap" ]] \
    || return 1
  : > "$_tmp/reap-worker.release"
  _mdm_test_wait_child_bounded "$_live" || return 1
  /bin/rm -f "$_control/worker" || return 1
  _mdm_release_run_lock || return 1
  _mdm_test_disarm_background_cleanup
}
_mdm_test_mkdir_pid_start_reuse() { # <tmp>
  local _tmp="$1" _control _owner _dir_identity _start_identity
  local _pid _recorded_start _recorded_dir _extra _rc
  _mdm_test_configure_lock_backend "$_tmp" mkdir || return 1
  _control="$_tmp/support/remediation-global.mkdir-lock"
  _owner="$_control/owner"
  /bin/mkdir "$_control" || return 1
  /bin/chmod 700 "$_control" || return 1
  _dir_identity="$(_mdm_persistent_dir_identity "$_control")" || return 1
  _start_identity="$(_mdm_process_start_identity "$$")" || return 1
  [[ -n "$_start_identity" && "$_start_identity" != *$'\t'* ]] || return 1
  printf '%s\t%s-stale\t%s\n' "$$" "$_start_identity" "$_dir_identity" \
    > "$_owner" || return 1
  /bin/chmod 600 "$_owner" || return 1
  _mdm_test_reset_lock_state
  _mdm_acquire_run_lock bob "$_tmp/home-bob" || return 1
  [[ "$_MDM_RUN_LOCK_MODE" == mkdir ]] || return 1
  IFS=$'\t' read -r _pid _recorded_start _recorded_dir _extra < "$_owner" \
    || return 1
  [[ "$_pid" =~ ^[0-9]+$ && -n "$_recorded_start" \
    && -n "$_recorded_dir" && -z "$_extra" ]] || return 1
  [[ "$_recorded_start" == "$(_mdm_process_start_identity "$_pid")" ]] \
    || return 1
  [[ "$_recorded_dir" == "$(_mdm_persistent_dir_identity "$_control")" ]] \
    || return 1
  TZ=Pacific/Honolulu _mdm_lock_record_state "$_owner" "$_recorded_dir" \
    || return 1
  _mdm_release_run_lock || return 1
  /bin/mkdir "$_control" || return 1
  /bin/chmod 700 "$_control" || return 1
  _dir_identity="$(_mdm_persistent_dir_identity "$_control")" || return 1
  printf '%s\t%s-stale\t%s-mismatch\n' "$$" "$_start_identity" \
    "$_dir_identity" > "$_owner" || return 1
  /bin/chmod 600 "$_owner" || return 1
  _mdm_test_reset_lock_state
  _rc=0; _mdm_acquire_run_lock carol "$_tmp/home-carol" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -ne 0 && "$_MDM_RUN_LOCK_ERROR" == backend \
    && -d "$_control" ]] || return 1
  /bin/rm -rf "$_control" || return 1
  /bin/mkdir "$_control" || return 1
  /bin/chmod 700 "$_control" || return 1
  _dir_identity="$(_mdm_persistent_dir_identity "$_control")" || return 1
  printf '%s\t%s-stale\t%s\textra\n' "$$" "$_start_identity" \
    "$_dir_identity" > "$_owner" || return 1
  /bin/chmod 600 "$_owner" || return 1
  _mdm_test_reset_lock_state
  _rc=0; _mdm_acquire_run_lock dave "$_tmp/home-dave" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -ne 0 && "$_MDM_RUN_LOCK_ERROR" == backend \
    && -d "$_control" ]] || return 1
  /bin/rm -rf "$_control" || return 1
  /bin/mkdir "$_control" || return 1
  /bin/chmod 700 "$_control" || return 1
  _dir_identity="$(_mdm_persistent_dir_identity "$_control")" || return 1
  printf '%s\t%s-stale\t%s\n' "$$" "$_start_identity" "$_dir_identity" \
    > "$_owner" || return 1
  /bin/chmod 600 "$_owner" || return 1
  /bin/ln "$_owner" "$_tmp/owner-hardlink" || return 1
  _mdm_test_reset_lock_state
  _rc=0; _mdm_acquire_run_lock erin "$_tmp/home-erin" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -ne 0 && "$_MDM_RUN_LOCK_ERROR" == backend \
    && -f "$_tmp/owner-hardlink" ]] || return 1
  /bin/rm -rf "$_control" || return 1
  /bin/rm -f "$_tmp/owner-hardlink" || return 1
  /bin/mkdir "$_control" || return 1
  /bin/chmod 700 "$_control" || return 1
  _dir_identity="$(_mdm_persistent_dir_identity "$_control")" || return 1
  printf '%s\t%s-stale\t%s\n' "$$" "$_start_identity" "$_dir_identity" \
    > "$_owner" || return 1
  /bin/chmod 666 "$_owner" || return 1
  _mdm_test_reset_lock_state
  _rc=0; _mdm_acquire_run_lock frank "$_tmp/home-frank" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -ne 0 && "$_MDM_RUN_LOCK_ERROR" == backend \
    && -f "$_owner" ]] || return 1
  /bin/rm -rf "$_control" || return 1
  /bin/mkdir "$_control" || return 1
  /bin/chmod 700 "$_control" || return 1
  _dir_identity="$(_mdm_persistent_dir_identity "$_control")" || return 1
  printf '%s\t%s-stale\t%s\n' "$$" "$_start_identity" "$_dir_identity" \
    > "$_owner" || return 1
  /bin/chmod 600 "$_owner" || return 1
  : > "$_control/unexpected"
  _mdm_test_reset_lock_state
  _rc=0; _mdm_acquire_run_lock grace "$_tmp/home-grace" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -ne 0 && "$_MDM_RUN_LOCK_ERROR" == backend \
    && -f "$_control/unexpected" ]] || return 1
}
_mdm_test_mkdir_successor_aba() { # <tmp>
  local _tmp="$1" _base _control _old_quarantine _old_identity
  local _successor_identity _after_identity _initializer _rc=0
  _mdm_test_configure_lock_backend "$_tmp" mkdir || return 1
  _base="$_tmp/support"
  _control="$_base/remediation-global.mkdir-lock"
  _old_quarantine="$_base/.remediation-mkdir-old-fixture"
  /bin/mkdir "$_control" || return 1
  /bin/chmod 700 "$_control" || return 1
  _old_identity="$(_mdm_persistent_dir_identity "$_control")" || return 1
  (
    builtin cd -P "$_control" || exit 1
    : > "$_tmp/initializer.bound"
    while [[ ! -e "$_tmp/initializer.resume" ]]; do /bin/sleep 0.01; done
    : > ".owner.init.$$" || exit 1
    /bin/mv ".owner.init.$$" owner
  ) &
  _initializer=$!
  _MDM_TEST_BG_TMP="$_tmp"; _MDM_TEST_BG_HOLDER="$_initializer"
  _mdm_test_arm_background_cleanup
  _mdm_test_wait_for_file "$_tmp/initializer.bound" "$_initializer" || return 1
  /bin/mv "$_control" "$_old_quarantine" || return 1
  /bin/mkdir "$_control" || return 1
  /bin/chmod 700 "$_control" || return 1
  : > "$_control/successor-sentinel"
  : > "$_tmp/initializer.resume"
  _mdm_test_wait_child_bounded "$_initializer" || return 1
  [[ -f "$_old_quarantine/owner" && ! -e "$_control/owner" ]] || return 1
  _successor_identity="$(_mdm_persistent_dir_identity "$_control")" || return 1
  _mdm_mkdir_lock_cleanup "$_base" "$_control" "$_old_identity" \
    >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -ne 0 ]] || return 1
  _after_identity="$(_mdm_persistent_dir_identity "$_control")" || return 1
  [[ "$_after_identity" == "$_successor_identity" \
    && -f "$_control/successor-sentinel" \
    && -d "$_old_quarantine" ]] || return 1
  _mdm_test_disarm_background_cleanup
}
_mdm_test_case() { # <label> <function> [args...]
  local _label="$1" _fn="$2" _tmp; shift 2
  _tmp="$(mktemp -d)"
  if ( "$_fn" "$_tmp" "$@" ); then pass "$_label"; else fail "$_label"; fi
  rm -rf "$_tmp"
}
if [[ -x /usr/bin/lockf ]]; then
  _mdm_test_case "mdm-lock: fd host-global contention・再取得" _mdm_test_global_contention_cycle fd
  _mdm_test_case "mdm-lock: legacy host-global contention・再取得・清掃" _mdm_test_global_contention_cycle legacy
  _mdm_test_case "mdm-lock: legacy holder crash cleanup" _mdm_test_legacy_crash_cleanup
  _mdm_test_case "mdm-lock: EX_TEMPFAIL は contention" _mdm_test_nonusage_failure
  _mdm_test_case "mdm-lock: fd coordinator SIGKILL lifetime" _mdm_test_supervisor_lifetime fd
  _mdm_test_case "mdm-lock: legacy coordinator SIGKILL lifetime" _mdm_test_supervisor_lifetime legacy
  _mdm_test_case "mdm-lock: fd TERM は descendants 後に再取得" _mdm_test_term_cleanup_order fd
  _mdm_test_case "mdm-lock: legacy TERM は descendants 後に再取得" _mdm_test_term_cleanup_order legacy
else
  skip "mdm-lock: macOS lockf compatibility" "/usr/bin/lockf unavailable"
fi
_mdm_test_case "mdm-lock: mkdir host-global contention・再取得" _mdm_test_global_contention_cycle mkdir
_mdm_test_case "mdm-lock: mkdir coordinator SIGKILL lifetime" _mdm_test_supervisor_lifetime mkdir
_mdm_test_case "mdm-lock: mkdir TERM は descendants 後に再取得" _mdm_test_term_cleanup_order mkdir
_mdm_test_case "mdm-lock: missing owner recovery・特殊 path fail-closed" \
  _mdm_test_mkdir_bad_initialization
_mdm_test_case "mdm-lock: bare/stale/live reap recovery・競合" \
  _mdm_test_mkdir_reap_recovery
_mdm_test_case "mdm-lock: bound owner-init/worker residue recovery" \
  _mdm_test_mkdir_temp_residue
_mdm_test_case "mdm-lock: reap claim/worker publish ordering" \
  _mdm_test_mkdir_reap_worker_ordering
_mdm_test_case "mdm-lock: PID start identity・record integrity" \
  _mdm_test_mkdir_pid_start_reuse
_mdm_test_case "mdm-lock: delayed initializer/successor ABA prevention" \
  _mdm_test_mkdir_successor_aba
