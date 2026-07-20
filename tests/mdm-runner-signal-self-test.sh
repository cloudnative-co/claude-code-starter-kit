#!/usr/bin/env bash
# Signal and nested-runner lifecycle self-tests sourced by run-mdm-tests.sh.

_mdm_runner_signal_case() { # <signal> <expected-exit> [closed-stderr] [fallback]
  local signal_name="$1" expected_exit="$2" close_stderr="${3:-false}"
  local force_fallback="${4:-false}" supervisor_record supervisor_pid
  local probe_dir target_pid target_record target_rc=0 attempt=0 record
  local root_pid root_pgid
  local nested_pid nested_pgid target_tmp current failed=false outer_waited=false
  # shellcheck disable=SC2154  # Assigned by the sourcing runner.
  probe_dir="$runner_tmp/signal-$signal_name"
  /bin/mkdir -m 700 "$probe_dir"
  _MDM_LAUNCH_SIGNAL=""
  trap '_mdm_note_launch_signal HUP' HUP
  trap '_mdm_note_launch_signal INT' INT
  trap '_mdm_note_launch_signal TERM' TERM
  set -m
  if [[ "$close_stderr" == true ]]; then
    /usr/bin/env MDM_TEST_BASH="$MDM_TEST_BASH" \
      "$MDM_TEST_BASH" "$SCRIPT_DIR/run-mdm-tests.sh" \
        --runner-signal-target "$probe_dir" "$force_fallback" \
        > "$probe_dir/diagnostic" 2>&- &
  else
    /usr/bin/env MDM_TEST_BASH="$MDM_TEST_BASH" \
      "$MDM_TEST_BASH" "$SCRIPT_DIR/run-mdm-tests.sh" \
        --runner-signal-target "$probe_dir" "$force_fallback" \
        > "$probe_dir/diagnostic" 2>&1 &
  fi
  target_pid=$!
  set +m
  attempt=0
  target_record=""
  while [[ -z "$target_record" && "$attempt" -lt 50 ]]; do
    target_record="$(_mdm_process_record "$target_pid" || true)"
    [[ -n "$target_record" ]] && break
    /bin/sleep 0.01
    attempt=$((attempt + 1))
  done
  _MDM_ACTIVE_NESTED_RUNNER_PID="$target_pid"
  _MDM_ACTIVE_NESTED_RUNNER_RECORD="$target_record"
  _MDM_ACTIVE_NESTED_RUNNER_DIAGNOSTIC="$probe_dir/diagnostic"
  _MDM_ACTIVE_NESTED_SUPERVISOR_RECORD=""
  _MDM_ACTIVE_NESTED_SUPERVISOR_RECORD_FILE="$probe_dir/supervisor-record"
  _mdm_arm_runner_signal_traps
  case "$_MDM_LAUNCH_SIGNAL" in
    HUP) _mdm_handle_runner_signal HUP 129 ;;
    INT) _mdm_handle_runner_signal INT 130 ;;
    TERM) _mdm_handle_runner_signal TERM 143 ;;
  esac
  _MDM_LAUNCH_SIGNAL=""
  attempt=0
  while [[ ! -e "$probe_dir/ready" && "$attempt" -lt 200 ]]; do
    /bin/kill -0 "$target_pid" 2>/dev/null || break
    /bin/sleep 0.05
    attempt=$((attempt + 1))
  done
  record="$(sed -n '1p' "$probe_dir/processes" 2>/dev/null || true)"
  root_pid="${record%%:*}"; record="${record#*:}"
  root_pgid="${record%%:*}"; record="${record#*:}"
  nested_pid="${record%%:*}"; nested_pgid="${record#*:}"
  if [[ ! -e "$probe_dir/ready" || ! "$root_pid" =~ ^[1-9][0-9]*$ \
    || -z "$target_record" \
    || ! "$root_pgid" =~ ^[1-9][0-9]*$ \
    || ! "$nested_pid" =~ ^[1-9][0-9]*$ \
    || "$nested_pgid" != "$nested_pid" || "$nested_pid" == "$root_pid" \
    || "$root_pgid" == "$nested_pgid" ]]; then
    failed=true
  elif [[ "$force_fallback" == true ]]; then
    if _mdm_cleanup_nested_runner "$signal_name"; then
      target_rc="${_MDM_NESTED_RUNNER_WAIT_STATUS:-125}"
      outer_waited=true
    else
      failed=true
    fi
  else
    _mdm_signal_record "$target_record" "$signal_name" || failed=true
    if [[ "$signal_name" == INT ]]; then
      attempt=0
      while ! grep -q 'runner received INT' "$probe_dir/diagnostic" \
        && [[ "$attempt" -lt 200 ]]; do
        _mdm_record_matches "$target_pid" "$target_record" || break
        /bin/sleep 0.01
        attempt=$((attempt + 1))
      done
      if grep -q 'runner received INT' "$probe_dir/diagnostic"; then
        _mdm_signal_record "$target_record" TERM || true
      else
        failed=true
      fi
    fi
  fi
  if [[ "$failed" == true && "$outer_waited" != true \
    && -n "$target_record" ]]; then
    _mdm_cleanup_bound_supervisor \
      "$target_pid" "$target_record" TERM || true
  fi
  if [[ "$outer_waited" != true ]]; then
    set +e
    wait "$target_pid"
    target_rc=$?
    set -e
  fi
  _MDM_ACTIVE_NESTED_RUNNER_PID=""
  _MDM_ACTIVE_NESTED_RUNNER_RECORD=""
  _MDM_ACTIVE_NESTED_RUNNER_DIAGNOSTIC=""
  _MDM_ACTIVE_NESTED_SUPERVISOR_RECORD=""
  _MDM_ACTIVE_NESTED_SUPERVISOR_RECORD_FILE=""
  [[ "$target_rc" -eq "$expected_exit" ]] || failed=true
  supervisor_record="$(sed -n '1p' \
    "$probe_dir/supervisor-record" 2>/dev/null || true)"
  supervisor_pid="${supervisor_record%%|*}"
  for current in "$root_pid" "$nested_pid" "$supervisor_pid"; do
    [[ "$current" =~ ^[1-9][0-9]*$ ]] || continue
    if _mdm_record_is_live "$(_mdm_process_record "$current" || true)"; then
      failed=true
    fi
  done
  target_tmp="$(sed -n '1p' "$probe_dir/runner-tmp" 2>/dev/null || true)"
  [[ "$target_tmp" == /* && ! -e "$target_tmp" && ! -L "$target_tmp" ]] \
    || failed=true
  if [[ "$failed" == true ]]; then
    /bin/cat "$probe_dir/diagnostic" >&2 || true
    printf 'FAIL: runner %s cleanup contract failed (exit=%s)\n' \
      "$signal_name" "$target_rc" >&2
    exit 1
  fi
  printf 'PASS: runner %s preserves exit %s and collects descendant session\n' \
    "$signal_name" "$expected_exit"
}

_mdm_runner_signal_case HUP 129
_mdm_runner_signal_case INT 130
_mdm_runner_signal_case TERM 143 true true
