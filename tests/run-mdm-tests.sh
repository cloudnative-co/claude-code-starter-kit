#!/usr/bin/env bash
# tests/run-mdm-tests.sh - Process-isolated runner for MDM unit tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR="$SCRIPT_DIR/mdm-process-supervisor.py"
TEST_WRAPPER="$SCRIPT_DIR/mdm-test-shell-wrapper.sh"
PROCESS_LIB="$SCRIPT_DIR/mdm-runner-process-lib.sh"
SIGNAL_SELF_TEST="$SCRIPT_DIR/mdm-runner-signal-self-test.sh"
# macOS defaults to system Bash 3.2 so a large Bash 5 heredoc writer cannot
# deadlock against its smaller pipe buffer. Bash 4+ files use _find_bash4().
if [[ -n "${MDM_TEST_BASH:-}" ]]; then
  MDM_TEST_BASH="$MDM_TEST_BASH"
elif [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin \
  && -x /bin/bash ]]; then
  MDM_TEST_BASH=/bin/bash
else
  MDM_TEST_BASH="${BASH:-$(command -v bash 2>/dev/null || true)}"
fi
# Require all 12 files and at least 864 assertions across supported hosts.
readonly MIN_MDM_TEST_FILES=12
readonly MIN_MDM_ASSERTIONS=864
readonly -a MDM_TEST_BASENAMES=(
  test-mdm-bootstrap.sh
  test-mdm-detect.sh
  test-mdm-external-transaction.sh
  test-mdm-expected.sh
  test-mdm-install.sh
  test-mdm-keys-in-sync.sh
  test-mdm-lock.sh
  test-mdm-managed-env.sh
  test-mdm-managed-write-safety.sh
  test-mdm-purpose.sh
  test-mdm-ref-validate.sh
  test-mdm-wce-runtime.sh
)
MDM_TEST_SYSTEM_PYTHON=""
if [[ -x /usr/bin/python3 ]]; then
  MDM_TEST_SYSTEM_PYTHON="$(/usr/bin/python3 -I -B -c \
    'import os, sys; print(os.path.realpath(sys.executable))' \
    2>/dev/null || true)"
  [[ "$MDM_TEST_SYSTEM_PYTHON" == /* \
    && -x "$MDM_TEST_SYSTEM_PYTHON" \
    && ! -L "$MDM_TEST_SYSTEM_PYTHON" ]] || MDM_TEST_SYSTEM_PYTHON=""
fi

_find_bash4() {
  local candidate major
  for candidate in "${MDM_TEST_BASH4:-}" "$MDM_TEST_BASH" \
    "$(command -v bash 2>/dev/null || true)" \
    /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
    [[ "$candidate" == /* && -x "$candidate" ]] || continue
    major="$("$candidate" -c 'printf "%s" "${BASH_VERSINFO[0]}"' \
      2>/dev/null || true)"
    case "$major" in
      ''|*[!0-9]*) continue ;;
    esac
    if [[ "$major" -ge 4 ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}
if [[ "$MDM_TEST_BASH" != /* || ! -x "$MDM_TEST_BASH" ]]; then
  printf 'FAIL: MDM_TEST_BASH must be an absolute executable path: %s\n' \
    "$MDM_TEST_BASH" >&2
  exit 1
fi
if [[ -z "$MDM_TEST_SYSTEM_PYTHON" ]]; then
  printf 'FAIL: a resolved non-symlink /usr/bin/python3 is required\n' >&2
  exit 1
fi
if [[ ! -f "$SUPERVISOR" || -L "$SUPERVISOR" || ! -r "$SUPERVISOR" ]]; then
  printf 'FAIL: MDM process supervisor is unavailable: %s\n' \
    "$SUPERVISOR" >&2
  exit 1
fi
if [[ ! -f "$TEST_WRAPPER" || -L "$TEST_WRAPPER" || ! -r "$TEST_WRAPPER" ]]; then
  printf 'FAIL: MDM test shell wrapper is unavailable: %s\n' "$TEST_WRAPPER" >&2
  exit 1
fi
if [[ ! -f "$PROCESS_LIB" || -L "$PROCESS_LIB" || ! -r "$PROCESS_LIB" ]]; then
  printf 'FAIL: MDM runner process library is unavailable: %s\n' \
    "$PROCESS_LIB" >&2
  exit 1
fi
if [[ ! -f "$SIGNAL_SELF_TEST" || -L "$SIGNAL_SELF_TEST" \
  || ! -r "$SIGNAL_SELF_TEST" ]]; then
  printf 'FAIL: MDM runner signal self-test is unavailable: %s\n' \
    "$SIGNAL_SELF_TEST" >&2
  exit 1
fi
runner_tmp=""
_MDM_STARTUP_SIGNAL=""
_MDM_LAUNCH_SIGNAL=""
_MDM_ACTIVE_SUPERVISOR_PID=""
_MDM_ACTIVE_SUPERVISOR_RECORD=""
_MDM_ACTIVE_LABEL=""
_MDM_ACTIVE_NESTED_RUNNER_PID=""
_MDM_ACTIVE_NESTED_RUNNER_RECORD=""
_MDM_ACTIVE_NESTED_RUNNER_DIAGNOSTIC=""
_MDM_ACTIVE_NESTED_SUPERVISOR_RECORD=""
_MDM_ACTIVE_NESTED_SUPERVISOR_RECORD_FILE=""
_MDM_SUPERVISOR_RECORD_OUTPUT=""
_MDM_FORCE_SUPERVISOR_CLEANUP_FAILURE=false
_MDM_LAST_BOUND_WAIT_STATUS=""
_MDM_NESTED_RUNNER_WAIT_STATUS=""
_mdm_note_startup_signal() { # <signal-name>
  [[ -n "$_MDM_STARTUP_SIGNAL" ]] || _MDM_STARTUP_SIGNAL="$1"
}
_mdm_early_runner_cleanup() {
  local cleanup_target="${runner_tmp:-}"
  [[ -n "$cleanup_target" ]] || return 0
  if /bin/rmdir "$cleanup_target" 2>/dev/null; then
    runner_tmp=""
  fi
}
trap '_mdm_early_runner_cleanup' EXIT
trap '_mdm_note_startup_signal HUP' HUP
trap '_mdm_note_startup_signal INT' INT
trap '_mdm_note_startup_signal TERM' TERM
# Record signals until the new path is assigned for authoritative cleanup.
runner_tmp="$(/usr/bin/mktemp -d)"
runner_tmp="$(cd -P "$runner_tmp" && /bin/pwd -P)"
# shellcheck source=mdm-runner-process-lib.sh
source "$PROCESS_LIB"
_mdm_arm_runner_signal_traps
case "$_MDM_STARTUP_SIGNAL" in
  HUP) _mdm_handle_runner_signal HUP 129 ;;
  INT) _mdm_handle_runner_signal INT 130 ;;
  TERM) _mdm_handle_runner_signal TERM 143 ;;
esac
_MDM_STARTUP_SIGNAL=""
if [[ "${1:-}" == --runner-tmpdir-self-test ]]; then
  /bin/mkdir -p "$runner_tmp/locked/child"
  /bin/chmod 000 "$runner_tmp/locked/child" "$runner_tmp/locked"
  exit 0
fi
_mdm_bounded_decimal() { # <value> <minimum> <maximum>
  local value="$1" minimum="$2" maximum="$3"
  case "$value" in
    ''|0|0*|*[!0-9]*|?????*) return 1 ;;
  esac
  [[ "$value" -ge "$minimum" && "$value" -le "$maximum" ]]
}

_mdm_canonical_test_count() { # <value>
  local value="$1"
  case "$value" in
    0) return 0 ;;
    ''|0*|*[!0-9]*|??????*) return 1 ;;
  esac
  return 0
}

_mdm_read_test_result() { # <result-file>
  local result_file="$1" value total passed failed skipped
  [[ -f "$result_file" && ! -L "$result_file" && -r "$result_file" ]] \
    || return 1
  [[ "$(/usr/bin/wc -l < "$result_file" \
    | /usr/bin/tr -d '[:space:]')" == 1 ]] || return 1
  value="$(sed -n '1p' "$result_file")"
  [[ "$value" =~ ^[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+$ ]] || return 1
  IFS='|' read -r total passed failed skipped <<< "$value"
  _mdm_canonical_test_count "$total" \
    && _mdm_canonical_test_count "$passed" \
    && _mdm_canonical_test_count "$failed" \
    && _mdm_canonical_test_count "$skipped" || return 1
  [[ "$total" -gt 0 && "$passed" -gt 0 && "$failed" -eq 0 \
    && "$total" -eq $((passed + failed + skipped)) ]] || return 1
  printf '%s\n' "$value"
}
_mdm_computed_timeout_from_bytes() { # <byte-count>
  local bytes="$1" kib timeout
  case "$bytes" in
    ''|*[!0-9]*) return 1 ;;
    ???????*)
      printf '%s\n' 2700
      return 0
      ;;
  esac
  kib=$(((bytes + 1023) / 1024))
  timeout=$((600 + (kib * 4)))
  [[ "$timeout" -le 2700 ]] || timeout=2700
  printf '%s\n' "$timeout"
}
_mdm_test_timeout_seconds() { # <test-file>
  local test_file="$1" bytes declared_lines declared_timeout
  if [[ -n "${MDM_TEST_FILE_TIMEOUT_SECONDS:-}" ]]; then
    _mdm_bounded_decimal "$MDM_TEST_FILE_TIMEOUT_SECONDS" 1 2700 || return 1
    printf '%s\n' "$MDM_TEST_FILE_TIMEOUT_SECONDS"
    return 0
  fi
  declared_lines="$(LC_ALL=C grep '^# MDM_TEST_TIMEOUT_SECONDS=' \
    "$test_file" 2>/dev/null || true)"
  if [[ -n "$declared_lines" ]]; then
    [[ "$declared_lines" != *$'\n'* ]] || return 1
    declared_timeout="${declared_lines#\# MDM_TEST_TIMEOUT_SECONDS=}"
    [[ "$declared_lines" \
      == "# MDM_TEST_TIMEOUT_SECONDS=$declared_timeout" ]] || return 1
    _mdm_bounded_decimal "$declared_timeout" 60 2700 || return 1
    printf '%s\n' "$declared_timeout"
    return 0
  fi
  bytes="$(/usr/bin/wc -c < "$test_file" \
    | /usr/bin/tr -d '[:space:]')"
  _mdm_computed_timeout_from_bytes "$bytes"
}
_mdm_unsafe_negative_group_kills() { # <shell-files...>
  LC_ALL=C /usr/bin/awk '
    /^[[:space:]]*#/ { next }
    /\/bin\/kill[[:space:]]+-[[:alnum:]]+[[:space:]]+"-\$[^"]+"/ ||
    /\/bin\/kill[[:space:]]+"-\$[^"]+"[[:space:]]+"-\$[^"]+"/ {
      print FILENAME ":" FNR ":" $0
    }
  ' "$@"
}
_mdm_session_escape_uses() { # <shell-files...>
  LC_ALL=C /usr/bin/awk '
    /^[[:space:]]*#/ { next }
    /(^|[^[:alnum:]_])setsid([^[:alnum:]_]|$)/ ||
    /\/setsid([[:space:]]|$)/ ||
    /os\.setsid[[:space:]]*\(/ {
      print FILENAME ":" FNR ":" $0
    }
  ' "$@"
}

MDM_TEST_FILES=()
_mdm_validate_mdm_suite() {
  local basename candidate expected found last_nonblank test_file
  [[ "${#MDM_TEST_BASENAMES[@]}" -eq "$MIN_MDM_TEST_FILES" ]] || return 1
  MDM_TEST_FILES=()
  for basename in "${MDM_TEST_BASENAMES[@]}"; do
    test_file="$SCRIPT_DIR/unit/$basename"
    if [[ ! -f "$test_file" || -L "$test_file" || ! -r "$test_file" ]]; then
      printf 'FAIL: required MDM test is unavailable: %s\n' "$basename" >&2
      return 1
    fi
    last_nonblank="$(LC_ALL=C /usr/bin/awk \
      'NF { value = $0 } END { print value }' "$test_file")"
    if [[ "$last_nonblank" != mdm_test_reached_end ]]; then
      printf 'FAIL: required MDM test lacks its final EOF marker: %s\n' \
        "$basename" >&2
      return 1
    fi
    MDM_TEST_FILES+=("$test_file")
  done

  for candidate in "$SCRIPT_DIR"/unit/test-mdm-*.sh; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    basename="${candidate##*/}"
    found=false
    for expected in "${MDM_TEST_BASENAMES[@]}"; do
      if [[ "$basename" == "$expected" ]]; then
        found=true
        break
      fi
    done
    if [[ "$found" != true ]]; then
      printf 'FAIL: unexpected MDM test is outside the exact suite: %s\n' \
        "$basename" >&2
      return 1
    fi
  done
}

if ! _mdm_validate_mdm_suite; then
  exit 1
fi

# Signal probe: a second process group remains in the supervisor session.
if [[ "${1:-}" == --runner-signal-target ]]; then
  signal_probe_dir="${2:-}"
  [[ "${3:-false}" == false || "${3:-false}" == true ]] || exit 2
  _MDM_FORCE_SUPERVISOR_CLEANUP_FAILURE="${3:-false}"
  [[ "$signal_probe_dir" == /* && -d "$signal_probe_dir" \
    && ! -L "$signal_probe_dir" ]] || exit 2
  printf '%s\n' "$runner_tmp" > "$signal_probe_dir/runner-tmp"
  /bin/mkdir -p "$runner_tmp/locked/child"
  if [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]]; then
    printf 'immutable\n' > "$runner_tmp/locked/child/interrupt-immutable"
    /usr/bin/chflags uchg "$runner_tmp/locked/child/interrupt-immutable"
    /bin/chmod +a "everyone deny delete" "$runner_tmp/locked"
  fi
  /bin/chmod 000 "$runner_tmp/locked/child" "$runner_tmp/locked"
  _MDM_SUPERVISOR_RECORD_OUTPUT="$signal_probe_dir/supervisor-record"
  _mdm_run_supervised 60 "$runner_tmp/signal-target.out" \
    "runner signal target" /usr/bin/env MDM_SIGNAL_DIR="$signal_probe_dir" \
    "$MDM_TEST_BASH" -c '
      trap "" HUP INT TERM
      set -m
      (
        trap "" HUP INT TERM
        while :; do /bin/sleep 1; done
      ) &
      nested=$!
      root_pgid="$(/bin/ps -p "$$" -o pgid= \
        | /usr/bin/tr -d "[:space:]")"
      nested_pgid="$(/bin/ps -p "$nested" -o pgid= \
        | /usr/bin/tr -d "[:space:]")"
      printf "%s:%s:%s:%s\n" "$$" "$root_pgid" \
        "$nested" "$nested_pgid" > "$MDM_SIGNAL_DIR/processes"
      : > "$MDM_SIGNAL_DIR/ready"
      set +m
      while :; do /bin/sleep 1; done
    '
  exit 91
fi

kill_scan_safe="$runner_tmp/kill-safe.sh"
kill_scan_unsafe="$runner_tmp/kill-unsafe.sh"
relative_tmp_probe="$runner_tmp/relative-tmpdir"
/bin/mkdir "$relative_tmp_probe"
if ! (cd "$runner_tmp" \
    && /usr/bin/env TMPDIR=relative-tmpdir MDM_TEST_BASH="$MDM_TEST_BASH" \
      "$MDM_TEST_BASH" "$SCRIPT_DIR/run-mdm-tests.sh" \
        --runner-tmpdir-self-test) \
  || [[ -n "$(/usr/bin/find -P "$relative_tmp_probe" \
      -mindepth 1 -print -quit)" ]]; then
  printf 'FAIL: runner accepted a relative temporary root\n' >&2
  exit 1
fi
printf 'PASS: runner temporary root stays absolute with relative TMPDIR\n'
printf '%s\n' \
  '/bin/kill -KILL -- "-$group"' \
  '/bin/kill "-$signal" "$pid"' > "$kill_scan_safe"
printf '%s\n' \
  '/bin/kill -KILL "-$group"' \
  '/bin/kill "-$signal" "-$group"' > "$kill_scan_unsafe"
if [[ -n "$(_mdm_unsafe_negative_group_kills "$kill_scan_safe")" \
  || "$(_mdm_unsafe_negative_group_kills "$kill_scan_unsafe" \
    | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" != 2 ]]; then
  printf 'FAIL: negative process-group kill preflight is not fail-closed\n' >&2
  exit 1
fi

unsafe_group_kills="$(_mdm_unsafe_negative_group_kills \
  "$SCRIPT_DIR/../mdm/install-mdm.sh" \
  "$SCRIPT_DIR/../mdm/detect-mdm.sh" \
  "${MDM_TEST_FILES[@]}")"
if [[ -n "$unsafe_group_kills" ]]; then
  printf 'FAIL: negative process-group kill operand requires --:\n%s\n' \
    "$unsafe_group_kills" >&2
  exit 1
fi
printf 'PASS: negative process-group kill operands use --\n'

session_escapes="$(_mdm_session_escape_uses \
  "$SCRIPT_DIR/../mdm/install-mdm.sh" \
  "$SCRIPT_DIR/../mdm/detect-mdm.sh" \
  "${MDM_TEST_FILES[@]}")"
if [[ -n "$session_escapes" ]]; then
  printf 'FAIL: MDM tests must not escape the runner session:\n%s\n' \
    "$session_escapes" >&2
  exit 1
fi
printf 'PASS: MDM payloads stay inside the runner session\n'

timeout_declared="$runner_tmp/timeout-declared.sh"
timeout_duplicate="$runner_tmp/timeout-duplicate.sh"
printf '%s\n' '# MDM_TEST_TIMEOUT_SECONDS=1800' > "$timeout_declared"
printf '%s\n' '# MDM_TEST_TIMEOUT_SECONDS=1800' \
  '# MDM_TEST_TIMEOUT_SECONDS=1801' > "$timeout_duplicate"
if [[ "$(unset MDM_TEST_FILE_TIMEOUT_SECONDS; \
    _mdm_test_timeout_seconds "$timeout_declared")" != 1800 ]] \
  || (unset MDM_TEST_FILE_TIMEOUT_SECONDS; \
    _mdm_test_timeout_seconds "$timeout_duplicate") >/dev/null 2>&1; then
  printf 'FAIL: per-file watchdog timeout declaration is not strict\n' >&2
  exit 1
fi
for invalid_timeout in 01800 59 2701 18446744073709553416 '1800 '; do
  printf '# MDM_TEST_TIMEOUT_SECONDS=%s\n' "$invalid_timeout" \
    > "$timeout_declared"
  if (unset MDM_TEST_FILE_TIMEOUT_SECONDS; \
      _mdm_test_timeout_seconds "$timeout_declared") >/dev/null 2>&1; then
    printf 'FAIL: per-file watchdog accepted invalid declaration: %s\n' \
      "$invalid_timeout" >&2
    exit 1
  fi
done
for invalid_timeout in 01 2701 18446744073709553416 '1800 '; do
  if MDM_TEST_FILE_TIMEOUT_SECONDS="$invalid_timeout" \
      _mdm_test_timeout_seconds "$timeout_declared" >/dev/null 2>&1; then
    printf 'FAIL: per-file watchdog accepted invalid override: %s\n' \
      "$invalid_timeout" >&2
    exit 1
  fi
done
if [[ "$(MDM_TEST_FILE_TIMEOUT_SECONDS=1 \
    _mdm_test_timeout_seconds "$timeout_declared")" != 1 \
  || "$(_mdm_computed_timeout_from_bytes 0)" != 600 \
  || "$(_mdm_computed_timeout_from_bytes 1025)" != 608 \
  || "$(_mdm_computed_timeout_from_bytes 18446744073709553416)" != 2700 ]]; then
  printf 'FAIL: per-file watchdog timeout arithmetic is not bounded\n' >&2
  exit 1
fi
printf 'PASS: per-file watchdog accepts only canonical bounded timeouts\n'

cleanup_probe="$runner_tmp/cleanup-probe"
cleanup_outside="$runner_tmp/cleanup-outside"
/bin/mkdir -p "$cleanup_probe/locked/child" "$cleanup_outside"
printf 'outside\n' > "$cleanup_outside/marker"
/bin/ln -s "$cleanup_outside" "$cleanup_probe/locked/outside-link"
/bin/chmod 000 "$cleanup_probe/locked/child" "$cleanup_probe/locked"
/bin/chmod 0500 "$cleanup_outside"
if [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]]; then
  cleanup_outside_mode="$(/usr/bin/stat -f '%Lp' "$cleanup_outside")"
else
  cleanup_outside_mode="$(/usr/bin/stat -c '%a' "$cleanup_outside")"
fi
if _mdm_remove_runner_tree "$cleanup_probe" \
  && [[ ! -e "$cleanup_probe" && ! -L "$cleanup_probe" \
    && "$(sed -n '1p' "$cleanup_outside/marker")" == outside ]] \
  && { if [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]]; then
         [[ "$(/usr/bin/stat -f '%Lp' "$cleanup_outside")" \
           == "$cleanup_outside_mode" ]]
       else
         [[ "$(/usr/bin/stat -c '%a' "$cleanup_outside")" \
           == "$cleanup_outside_mode" ]]
       fi; }; then
  /bin/chmod 0700 "$cleanup_outside"
  printf 'PASS: runner cleanup handles locked fixtures without following symlinks\n'
else
  printf 'FAIL: runner cleanup cannot safely remove locked fixtures\n' >&2
  exit 1
fi
if (
  _mdm_signal_record() { return 0; }
  _mdm_wait_bound_supervisor() { return 1; }
  _mdm_record_matches() { return 1; }
  _mdm_cleanup_bound_supervisor \
    123 "123|$$|123|501|S|Sun Jul 20 00:00:00 2026" TERM
); then
  printf 'FAIL: forced supervisor cleanup failure was hidden\n' >&2
  exit 1
fi
printf 'PASS: forced supervisor cleanup failure propagates\n'

probe="$runner_tmp/probe.fail"
TEST_FAILURE_SENTINEL="$probe" "$MDM_TEST_BASH" -c '
  source "$1"
  (fail "runner sentinel probe") >/dev/null
' _ "$SCRIPT_DIR/helpers.sh"
if [[ ! -s "$probe" ]]; then
  printf 'FAIL: MDM failure sentinel did not propagate from a subshell\n' >&2
  exit 1
fi

wrapper_root="$runner_tmp/wrapper-root"
wrapper_record="$runner_tmp/wrapper-record"
wrapper_output="$runner_tmp/wrapper-timeout.out"
/bin/mkdir "$wrapper_root"
set +e
_mdm_run_supervised 1 "$wrapper_output" "wrapper timeout probe" \
  /usr/bin/env MDM_TEST_TMP_ROOT="$wrapper_root" \
  MDM_WRAPPER_RECORD="$wrapper_record" \
  "$MDM_TEST_BASH" "$TEST_WRAPPER" --timeout-probe
wrapper_rc=$?
set -e
wrapper_path="$(sed -n '1p' "$wrapper_record" 2>/dev/null || true)"
if [[ "$wrapper_rc" -ne 124 || "$wrapper_path" != "$wrapper_root"/* \
  || ! -d "$wrapper_path" ]] \
  || ! _mdm_remove_runner_tree "$wrapper_root" \
  || [[ -e "$wrapper_root" || -L "$wrapper_root" ]]; then
  /bin/cat "$wrapper_output" >&2 || true
  printf 'FAIL: timed-out MDM test temporary object escaped cleanup\n' >&2
  exit 1
fi
printf 'PASS: timed-out MDM test temporary objects stay runner-owned\n'

wrapper_early="$runner_tmp/wrapper-early.sh"
wrapper_complete="$runner_tmp/wrapper-complete.sh"
wrapper_option="$runner_tmp/wrapper-option.sh"
wrapper_explicit="$runner_tmp/wrapper-explicit.sh"
wrapper_contract_completion="$runner_tmp/wrapper-contract.complete"
wrapper_contract_result="$runner_tmp/wrapper-contract.result"
wrapper_nested="$runner_tmp/wrapper-nested.sh"
wrapper_nested_completion="$runner_tmp/wrapper-nested.complete"
wrapper_nested_result="$runner_tmp/wrapper-nested.result"
wrapper_nested_ledger="$runner_tmp/wrapper-nested.assertions"
printf '%s\n' \
  'pass "early assertion"' \
  'mdm_test_reached_end || true' \
  'return 0' \
  'fail "unreachable assertion"' \
  'mdm_test_reached_end' > "$wrapper_early"
printf '%s\n' \
  'pass "complete assertion"' \
  'mdm_test_reached_end' > "$wrapper_complete"
printf '%s\n' \
  '(pass "nested assertion")' \
  'pass "parent assertion"' \
  'mdm_test_reached_end' > "$wrapper_nested"
printf '%s\n' \
  'mktemp -d -t mdm-wrapper-escape' \
  'pass "unsafe option form was accepted"' \
  'mdm_test_reached_end' > "$wrapper_option"
printf '%s\n' \
  'mktemp -d /private/tmp/mdm-wrapper-escape.XXXXXX' \
  'pass "external explicit template was accepted"' \
  'mdm_test_reached_end' > "$wrapper_explicit"
set +e
/usr/bin/env MDM_TEST_TMP_ROOT="$runner_tmp" \
  "$MDM_TEST_BASH" "$TEST_WRAPPER" "$SCRIPT_DIR/helpers.sh" \
  "$wrapper_early" "$wrapper_contract_completion" \
  "$wrapper_contract_result" >/dev/null 2>&1
wrapper_early_rc=$?
set -e
if [[ "$wrapper_early_rc" -eq 0 \
  || -e "$wrapper_contract_completion" || -L "$wrapper_contract_completion" \
  || -e "$wrapper_contract_result" || -L "$wrapper_contract_result" ]]; then
  printf 'FAIL: wrapper accepted a sourced test that returned before EOF\n' >&2
  exit 1
fi
set +e
/usr/bin/env MDM_TEST_TMP_ROOT="$runner_tmp" \
  "$MDM_TEST_BASH" "$TEST_WRAPPER" "$SCRIPT_DIR/helpers.sh" \
  "$wrapper_option" "$wrapper_contract_completion" \
  "$wrapper_contract_result" >/dev/null 2>&1
wrapper_option_rc=$?
set -e
if [[ "$wrapper_option_rc" -eq 0 \
  || -e "$wrapper_contract_completion" || -L "$wrapper_contract_completion" \
  || -e "$wrapper_contract_result" || -L "$wrapper_contract_result" ]]; then
  printf 'FAIL: wrapper accepted an escaping mktemp option form\n' >&2
  exit 1
fi
set +e
/usr/bin/env MDM_TEST_TMP_ROOT="$runner_tmp" \
  "$MDM_TEST_BASH" "$TEST_WRAPPER" "$SCRIPT_DIR/helpers.sh" \
  "$wrapper_explicit" "$wrapper_contract_completion" \
  "$wrapper_contract_result" >/dev/null 2>&1
wrapper_explicit_rc=$?
set -e
if [[ "$wrapper_explicit_rc" -eq 0 \
  || -e "$wrapper_contract_completion" || -L "$wrapper_contract_completion" \
  || -e "$wrapper_contract_result" || -L "$wrapper_contract_result" ]]; then
  printf 'FAIL: wrapper accepted an external explicit mktemp template\n' >&2
  exit 1
fi
if ! /usr/bin/env MDM_TEST_TMP_ROOT="$runner_tmp" \
    "$MDM_TEST_BASH" "$TEST_WRAPPER" "$SCRIPT_DIR/helpers.sh" \
      "$wrapper_complete" "$wrapper_contract_completion" \
      "$wrapper_contract_result" >/dev/null 2>&1 \
  || [[ ! -f "$wrapper_contract_completion" \
    || -L "$wrapper_contract_completion" || -s "$wrapper_contract_completion" \
    || "$(sed -n '1p' "$wrapper_contract_result")" != '1|1|0|0' ]] \
  || [[ "$(/usr/bin/wc -l < "$wrapper_contract_result" \
    | /usr/bin/tr -d '[:space:]')" != 1 ]]; then
  printf 'FAIL: wrapper did not publish its canonical structured result\n' >&2
  exit 1
fi
printf 'PASS: wrapper requires EOF and publishes a structured result\n'
if ! /usr/bin/env MDM_TEST_TMP_ROOT="$runner_tmp" \
    TEST_ASSERTION_LEDGER="$wrapper_nested_ledger" \
    "$MDM_TEST_BASH" "$TEST_WRAPPER" "$SCRIPT_DIR/helpers.sh" \
      "$wrapper_nested" "$wrapper_nested_completion" \
      "$wrapper_nested_result" >/dev/null 2>&1 \
  || [[ "$(sed -n '1p' "$wrapper_nested_result")" != '2|2|0|0' ]]; then
  printf 'FAIL: wrapper omitted a nested assertion from its result\n' >&2
  exit 1
fi
printf 'PASS: wrapper result includes nested assertions\n'

_mdm_record_is_live() { # <process-record>
  local state
  [[ -n "$1" ]] || return 1
  state="$(_mdm_record_state "$1" 2>/dev/null || true)"
  [[ -n "$state" && "$state" != Z* ]]
}
if _mdm_record_is_live '123|1|123|501|Z+|Sun Jul 20 00:00:00 2026' \
  || ! _mdm_record_is_live '123|1|123|501|S+|Sun Jul 20 00:00:00 2026'; then
  printf 'FAIL: watchdog collection predicate mishandled process state\n' >&2
  exit 1
fi
printf 'PASS: watchdog collection predicate ignores zombie records\n'

watchdog_output="$runner_tmp/watchdog-probe.out"
watchdog_record="$runner_tmp/watchdog-probe.pid"
set +e
_mdm_run_supervised 1 "$watchdog_output" "watchdog self-probe" \
  "$MDM_TEST_BASH" -c '
    trap "" HUP INT TERM
    set -m
    (
      trap "" HUP INT TERM
      while :; do /bin/sleep 1; done
    ) &
    nested=$!
    nested_pgid="$(/bin/ps -p "$nested" -o pgid= \
      | /usr/bin/tr -d "[:space:]")"
    printf "%s:%s:%s\n" "$nested" "$nested_pgid" "$$" > "$1"
    set +m
    while :; do /bin/sleep 1; done
  ' _ "$watchdog_record"
watchdog_rc=$?
set -e
watchdog_value="$(sed -n '1p' "$watchdog_record" 2>/dev/null || true)"
watchdog_pid="${watchdog_value%%:*}"
watchdog_value="${watchdog_value#*:}"
watchdog_pgid="${watchdog_value%%:*}"
watchdog_process="$(_mdm_process_record "$watchdog_pid" || true)"
if [[ "$watchdog_rc" -ne 124 || ! "$watchdog_pid" =~ ^[1-9][0-9]*$ \
  || "$watchdog_pgid" != "$watchdog_pid" ]] \
  || _mdm_record_is_live "$watchdog_process"; then
  /bin/cat "$watchdog_output" >&2 || true
  printf 'FAIL: session watchdog did not collect a separate process group\n' >&2
  exit 1
fi
printf 'PASS: per-file watchdog collects descendants across process groups\n'

orphan_output="$runner_tmp/orphan-probe.out"
orphan_record="$runner_tmp/orphan-probe.pid"
set +e
_mdm_run_supervised 5 "$orphan_output" "orphan self-probe" \
  "$MDM_TEST_BASH" -c '
    set -m
    (
      trap "" HUP INT TERM
      while :; do /bin/sleep 1; done
    ) &
    child=$!
    printf "%s\n" "$child" > "$1"
    exit 0
  ' _ "$orphan_record"
orphan_rc=$?
set -e
orphan_pid="$(sed -n '1p' "$orphan_record" 2>/dev/null || true)"
orphan_process="$(_mdm_process_record "$orphan_pid" || true)"
if [[ "$orphan_rc" -ne 125 \
  || ! "$orphan_pid" =~ ^[1-9][0-9]*$ ]] \
  || _mdm_record_is_live "$orphan_process"; then
  /bin/cat "$orphan_output" >&2 || true
  printf 'FAIL: completed target left a live session member\n' >&2
  exit 1
fi
printf 'PASS: runner detects and collects a fast reparented descendant\n'

unbound_output="$runner_tmp/unbound-identity.out"
if (
  trap - EXIT HUP INT TERM
  _mdm_arm_runner_signal_traps() { :; }
  _mdm_process_record() { return 1; }
  set +e
  _mdm_run_supervised 5 "$unbound_output" "unbound identity self-probe" \
    /usr/bin/true
  unbound_rc=$?
  set -e
  [[ "$unbound_rc" -eq 125 && -z "$(jobs -p)" ]]
); then
  printf 'PASS: launch identity failure collects the bound Bash job\n'
else
  /bin/cat "$unbound_output" >&2 || true
  printf 'FAIL: launch identity failure left its supervisor job\n' >&2
  exit 1
fi
set +e
_mdm_run_supervised 1 /dev/null "missing READY self-probe" /usr/bin/true
missing_ready_rc=$?
set -e
if [[ "$missing_ready_rc" -ne 125 || -n "$(jobs -p)" ]]; then
  printf 'FAIL: runner launched a supervisor without observing READY\n' >&2
  exit 1
fi
printf 'PASS: runner requires the bound supervisor READY record\n'

# shellcheck source=mdm-runner-signal-self-test.sh
source "$SIGNAL_SELF_TEST"

normal_output="$runner_tmp/normal-probe.out"
set +e
_mdm_run_supervised 5 "$normal_output" "normal self-probe" \
  "$MDM_TEST_BASH" -c 'printf "watchdog-normal-complete\n"'
normal_rc=$?
set -e
if [[ "$normal_rc" -ne 0 ]] \
  || ! grep -qx 'watchdog-normal-complete' "$normal_output"; then
  /bin/cat "$normal_output" >&2 || true
  printf 'FAIL: session supervisor changed normal completion (exit=%s)\n' \
    "$normal_rc" >&2
  exit 1
fi
printf 'PASS: per-file watchdog preserves normal child completion\n'

if [[ "${1:-}" == --runner-watchdog-self-test ]]; then
  exit 0
fi

printf '\n══ MDM Unit Tests (%s) ══\n\n' \
  "$("$MDM_TEST_BASH" --version | head -1)"

file_count=0
failed_files=0
pass_count=0
for test_file in "${MDM_TEST_FILES[@]}"; do
  file_count=$((file_count + 1))
  sentinel="$runner_tmp/$(basename "$test_file").fail"
  completion="$runner_tmp/$(basename "$test_file").complete"
  result="$runner_tmp/$(basename "$test_file").result"
  ledger="$runner_tmp/$(basename "$test_file").assertions"
  output="$runner_tmp/$(basename "$test_file").out"
  test_bash="$MDM_TEST_BASH"
  file_timeout=""
  printf '── %s ──\n' "$(basename "$test_file")"

  if ! file_timeout="$(_mdm_test_timeout_seconds "$test_file")"; then
    printf 'FAIL: invalid watchdog timeout for %s: %s\n\n' \
      "$(basename "$test_file")" \
      "${MDM_TEST_FILE_TIMEOUT_SECONDS:-computed}"
    failed_files=$((failed_files + 1))
    continue
  fi

  if grep -q '^# MDM_TEST_BASH_MIN=4$' "$test_file"; then
    test_major="$("$test_bash" -c 'printf "%s" "${BASH_VERSINFO[0]}"' \
      2>/dev/null || true)"
    if [[ ! "$test_major" =~ ^[0-9]+$ || "$test_major" -lt 4 ]]; then
      if ! test_bash="$(_find_bash4)"; then
        printf 'FAIL: %s requires Bash 4+, but none was found\n\n' \
          "$(basename "$test_file")"
        failed_files=$((failed_files + 1))
        continue
      fi
    fi
  fi

  rc=0
  set +e
  _mdm_run_supervised "$file_timeout" "$output" \
    "$(basename "$test_file")" /usr/bin/env \
    TEST_FAILURE_SENTINEL="$sentinel" \
    TEST_ASSERTION_LEDGER="$ledger" \
    MDM_SYSTEM_PYTHON_OVERRIDE="$MDM_TEST_SYSTEM_PYTHON" \
    MDM_DETECT_PYTHON_OVERRIDE="$MDM_TEST_SYSTEM_PYTHON" \
    MDM_TEST_TMP_ROOT="$runner_tmp" \
    "$test_bash" "$TEST_WRAPPER" \
      "$SCRIPT_DIR/helpers.sh" "$test_file" "$completion" "$result"
  rc=$?
  set -e
  /bin/cat "$output"

  result_value="$(_mdm_read_test_result "$result" 2>/dev/null || true)"
  current_pass=0
  result_valid=no
  if [[ -n "$result_value" ]]; then
    current_pass="${result_value#*|}"
    current_pass="${current_pass%%|*}"
    result_valid=yes
  fi
  pass_count=$((pass_count + current_pass))
  if [[ "$rc" -ne 0 || -e "$sentinel" || -L "$sentinel" \
    || ! -f "$completion" || -L "$completion" || -s "$completion" \
    || "$result_valid" != yes ]]; then
    failed_files=$((failed_files + 1))
    nested_failures=0
    completed=no
    [[ -f "$completion" && ! -L "$completion" && ! -s "$completion" ]] \
      && completed=yes
    if [[ -f "$sentinel" && ! -L "$sentinel" ]]; then
      nested_failures="$(/usr/bin/wc -l < "$sentinel" \
        | /usr/bin/tr -d '[:space:]')"
    fi
    printf 'FAIL: %s (exit=%s, completed=%s, result=%s, passes=%s, nested failures=%s)\n' \
      "$(basename "$test_file")" "$rc" "$completed" "$result_valid" \
      "$current_pass" "$nested_failures"
  fi
  printf '\n'
done

if [[ "$file_count" -ne "$MIN_MDM_TEST_FILES" ]]; then
  printf 'FAIL: exact MDM suite count changed (%s; required=%s)\n' \
    "$file_count" "$MIN_MDM_TEST_FILES" >&2
  exit 1
fi
if [[ "$pass_count" -lt "$MIN_MDM_ASSERTIONS" ]]; then
  printf 'FAIL: suspiciously few MDM assertions ran (%s; minimum=%s)\n' \
    "$pass_count" "$MIN_MDM_ASSERTIONS" >&2
  exit 1
fi
if [[ "$failed_files" -ne 0 ]]; then
  printf 'FAIL: %s/%s MDM test files failed\n' \
    "$failed_files" "$file_count" >&2
  exit 1
fi

printf 'PASS: %s MDM test files, %s assertions\n' \
  "$file_count" "$pass_count"
