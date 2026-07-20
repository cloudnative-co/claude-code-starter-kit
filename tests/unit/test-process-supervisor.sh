#!/bin/bash
# tests/unit/test-process-supervisor.sh - MDM process supervisor contracts.

_ps_supervisor="$PROJECT_DIR/tests/mdm-process-supervisor.py"
_ps_python=""
if [[ -x /usr/bin/python3 ]]; then
  _ps_python="$(/usr/bin/python3 -I -B -c \
    'import os, sys; print(os.path.realpath(sys.executable))' \
    2>/dev/null || true)"
fi

if [[ "$_ps_python" == /* && -x "$_ps_python" && ! -L "$_ps_python" ]] \
  && "$_ps_python" -I -B -S -c '
import importlib.util
import os
import select
import signal
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("mdm_supervisor_contract", path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
start_identity = "Sun Jul 19 01:00:00 2026"
assert module._parse_cli([
    "--cleanup-session", "42", "--expected-uid", "0",
    "--expected-start", start_identity,
]) == ("cleanup", 42, [], 0, start_identity)
for invalid_cleanup in (
    ["--cleanup-session", "42"],
    ["--cleanup-session", "42", "--expected-uid", "00",
     "--expected-start", start_identity],
    ["--cleanup-session", "42", "--expected-uid", "501",
     "--expected-start", "Sun  Jul 19 01:00:00 2026"],
):
    try:
        module._parse_cli(invalid_cleanup)
    except module.SupervisorError:
        pass
    else:
        raise AssertionError("invalid cleanup identity was accepted")
members = {
    pid: module.Process(pid, pid + 1, 501, "S")
    for pid in range(1, 1501)
}
members[1500] = module.Process(1500, 9000, 501, "S")
depths = module._depths(members, 9000)
assert depths[1] == 1500 and depths[1500] == 1
supervisor = module.Supervisor(1, ["/usr/bin/true"])
supervisor.target_pid = 99999999
supervisor.cleanup = lambda: (_ for _ in ()).throw(RecursionError())
supervisor.emergency_cleanup()

# A full diagnostic pipe must be ignored instead of blocking supervision.
diag_read, diag_write = os.pipe()
saved_stderr = os.dup(2)
try:
    os.set_blocking(diag_write, False)
    while True:
        try:
            os.write(diag_write, b"x" * 4096)
        except BlockingIOError:
            break
    os.set_blocking(diag_write, True)
    os.dup2(diag_write, 2)
    diagnostic_started = module.time.monotonic()
    module._diagnostic("full pipe")
    assert module.time.monotonic() - diagnostic_started < 0.1
finally:
    os.dup2(saved_stderr, 2)
    os.close(saved_stderr)
    os.close(diag_write)
    os.close(diag_read)

# A target exit is successful only after one stable freeze. Signals arriving
# during that freeze win over the target status, and a newly observed member
# makes the otherwise-zero target fail closed and get collected.
original_freeze = module._freeze_session
original_diagnostic = module._diagnostic
original_members = module._session_members
original_signal_member = module._signal_if_still_in_session
original_sleep = module.time.sleep
old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])
old_term_handler = signal.getsignal(signal.SIGTERM)
old_quit_handler = signal.getsignal(signal.SIGQUIT)
try:
    module._diagnostic = lambda _message: None
    signal.signal(signal.SIGTERM, lambda _signum, _frame: None)
    signal.signal(signal.SIGQUIT, signal.SIG_IGN)
    quit_target = module.Supervisor(
        1, ["/bin/sh", "-c", "kill -s QUIT $$; exit 7"]
    )
    quit_target.launch()
    deadline = module.time.monotonic() + 2
    while quit_target.poll_target() is None and module.time.monotonic() < deadline:
        module.time.sleep(0.01)
    assert quit_target._target_exit_code() == 128 + signal.SIGQUIT

    if hasattr(signal, "SIGXFSZ"):
        xfsz = module.Supervisor(
            1, ["/bin/sh", "-c", "kill -s XFSZ $$; exit 7"]
        )
        xfsz.launch()
        deadline = module.time.monotonic() + 2
        while xfsz.poll_target() is None and module.time.monotonic() < deadline:
            module.time.sleep(0.01)
        assert xfsz._target_exit_code() == 128 + signal.SIGXFSZ

    signal_race = module.Supervisor(1, ["/usr/bin/true"])
    signal_race.establish_session = lambda: None
    signal_race.launch = lambda: setattr(signal_race, "target_pid", 42)
    signal_race.poll_target = lambda: 0
    signal_race.target_status = 0
    signal_cleanup = []
    signal_emergency = []
    def fail_signal_cleanup(frozen=None):
        signal_cleanup.append(frozen)
        return False
    signal_race.cleanup = fail_signal_cleanup
    signal_race.emergency_cleanup = lambda: signal_emergency.append(True)

    def inject_signal(*_args, **_kwargs):
        os.kill(os.getpid(), signal.SIGTERM)
        return {}

    module._freeze_session = inject_signal
    assert signal_race.run() == 128 + signal.SIGTERM
    assert signal_race.pending_signal is None
    assert signal.SIGTERM in signal.sigpending()
    assert signal_cleanup == [{}]
    assert signal_emergency == [True]
    signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)

    # Model a member that forks between censuses. The first set mismatch must
    # retry, and only the second stopped/stable snapshot can be returned.
    snapshots = iter([
        {43: module.Process(43, 9000, 501, "S")},
        {44: module.Process(44, 43, 501, "S")},
        {44: module.Process(44, 43, 501, "S")},
        {44: module.Process(44, 43, 501, "T")},
    ])
    module._session_members = lambda *_args, **_kwargs: next(snapshots)
    module._signal_if_still_in_session = lambda *_args, **_kwargs: True
    module.time.sleep = lambda _seconds: None
    module._freeze_session = original_freeze
    residual = module._freeze_session(9000, 9000, excluded=(9000,))
    assert residual == {44: module.Process(44, 43, 501, "T")}

    residual_race = module.Supervisor(1, ["/usr/bin/true"])
    residual_race.establish_session = lambda: None
    residual_race.launch = lambda: setattr(residual_race, "target_pid", 43)
    residual_race.poll_target = lambda: 0
    residual_race.target_status = 0
    residual_cleanup = []
    residual_emergency = []
    def fail_residual_cleanup(frozen=None):
        residual_cleanup.append(frozen)
        return False
    residual_race.cleanup = fail_residual_cleanup
    residual_race.emergency_cleanup = lambda: residual_emergency.append(True)
    module._freeze_session = lambda *_args, **_kwargs: residual
    assert residual_race.run() == module.EXIT_SUPERVISOR_ERROR
    assert residual_cleanup == [residual]
    assert residual_emergency == [True]

    signal_failure = module.Supervisor(1, ["/usr/bin/true"])
    signal_failure.establish_session = lambda: None
    signal_failure.launch = lambda: setattr(signal_failure, "target_pid", 45)
    def poll_with_signal():
        signal_failure.pending_signal = signal.SIGTERM
        return None
    signal_failure.poll_target = poll_with_signal
    signal_failure.cleanup = lambda frozen=None: False
    signal_emergency = []
    signal_failure.emergency_cleanup = lambda: signal_emergency.append(True)
    assert signal_failure.run() == 128 + signal.SIGTERM
    assert signal_emergency == [True]

    timeout_failure = module.Supervisor(0, ["/usr/bin/true"])
    timeout_failure.establish_session = lambda: None
    timeout_failure.launch = lambda: setattr(timeout_failure, "target_pid", 46)
    timeout_failure.poll_target = lambda: None
    timeout_failure.cleanup = lambda frozen=None: False
    timeout_emergency = []
    timeout_failure.emergency_cleanup = lambda: timeout_emergency.append(True)
    assert timeout_failure.run() == module.EXIT_TIMEOUT
    assert timeout_emergency == [True]
finally:
    signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
    signal.signal(signal.SIGTERM, old_term_handler)
    signal.signal(signal.SIGQUIT, old_quit_handler)
    module._freeze_session = original_freeze
    module._diagnostic = original_diagnostic
    module._session_members = original_members
    module._signal_if_still_in_session = original_signal_member
    module.time.sleep = original_sleep

# Failure cleanup must preserve a pending terminal signal even if emergency
# cleanup itself raises before the final decision.
original_diagnostic = module._diagnostic
old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])
old_hup_handler = signal.getsignal(signal.SIGHUP)
old_term_handler = signal.getsignal(signal.SIGTERM)
try:
    module._diagnostic = lambda _message: None
    signal.signal(signal.SIGHUP, lambda _signum, _frame: None)
    signal.signal(signal.SIGTERM, lambda _signum, _frame: None)
    for signum, cleanup_raises in (
        (signal.SIGTERM, False),
        (signal.SIGHUP, True),
    ):
        signal.pthread_sigmask(signal.SIG_BLOCK, module.SUPPORTED_SIGNALS)
        os.kill(os.getpid(), signum)
        failed_supervisor = module.Supervisor(1, ["/usr/bin/true"])
        emergency_calls = []
        def emergency_failure():
            emergency_calls.append(True)
            if cleanup_raises:
                raise RuntimeError("emergency cleanup failed")
        failed_supervisor.emergency_cleanup = emergency_failure
        assert module._exit_after_supervisor_failure(
            failed_supervisor
        ) == 128 + signum
        assert emergency_calls == [True]
        assert signum in signal.sigpending()
        assert signal.sigwait({signum}) == signum
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
finally:
    signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
    signal.signal(signal.SIGHUP, old_hup_handler)
    signal.signal(signal.SIGTERM, old_term_handler)
    module._diagnostic = original_diagnostic

# Final exit restores default dispositions while signals remain blocked. A
# signal after the final check therefore terminates success, timeout, and
# exception paths through the OS; SIGINT before handler setup does the same.
def assert_main_signal_exit(decision, expected_signal):
    probe = os.fork()
    if probe == 0:
        original_signal = module.signal.signal
        original_mask = module.signal.pthread_sigmask
        original_parse_cli = module._parse_cli
        injected = [False]
        module._diagnostic = lambda _message: None

        class FinalizeProbe:
            def __init__(self):
                self.pending_signal = None

            def _handle_signal(self, signum, _frame):
                if self.pending_signal is None:
                    self.pending_signal = signum

            def run(self):
                if decision == "pre-handler":
                    for signum in module.SUPPORTED_SIGNALS:
                        original_signal(signum, self._handle_signal)
                    signal.pthread_sigmask(
                        signal.SIG_UNBLOCK, module.SUPPORTED_SIGNALS
                    )
                if decision == "multi-pending":
                    self.pending_signal = signal.SIGTERM
                    os.kill(os.getpid(), signal.SIGHUP)
                if decision == "startup-multi-pending":
                    module._STARTUP_SIGNAL = signal.SIGTERM
                    os.kill(os.getpid(), signal.SIGHUP)
                if decision == "failure":
                    raise module.SupervisorError("decision failed")
                if decision == "timeout":
                    return module.EXIT_TIMEOUT
                return 0

            def emergency_cleanup(self):
                return None

            def _terminal_signal_after_block(self):
                if self.pending_signal is not None:
                    return self.pending_signal
                pending = signal.sigpending()
                return next((item for item in module.SUPPORTED_SIGNALS
                             if item in pending), None)

        module.Supervisor = lambda *_args, **_kwargs: FinalizeProbe()
        if decision == "pre-handler":
            original_signal(signal.SIGINT, signal.SIG_IGN)
            def signal_before_handler(argv):
                os.kill(os.getpid(), signal.SIGINT)
                return original_parse_cli(argv)
            module._parse_cli = signal_before_handler
        elif decision == "pre-keyboard":
            def keyboard_before_block(signum, handler):
                if signum == signal.SIGINT and not injected[0]:
                    injected[0] = True
                    raise KeyboardInterrupt()
                return original_signal(signum, handler)
            module.signal.signal = keyboard_before_block
        elif decision in ("multi-pending", "startup-multi-pending"):
            def require_selected_unblock(operation, signals):
                if (operation == signal.SIG_UNBLOCK
                    and set(signals) != {signal.SIGTERM}):
                    raise AssertionError("finalizer widened the selected signal")
                return original_mask(operation, signals)
            module.signal.pthread_sigmask = require_selected_unblock
        else:
            original_signal(signal.SIGTERM, lambda _signum, _frame: None)
            def signal_after_check(signum, handler):
                result = original_signal(signum, handler)
                if (signum in module.SUPPORTED_SIGNALS
                    and handler == signal.SIG_DFL and not injected[0]):
                    injected[0] = True
                    os.kill(os.getpid(), signal.SIGTERM)
                return result
            module.signal.signal = signal_after_check
        try:
            result = module.main(["--timeout", "1", "--", "/usr/bin/true"])
        except BaseException:
            result = 250
        os._exit(result)

    status = None
    deadline = module.time.monotonic() + 3
    while module.time.monotonic() < deadline:
        waited_pid, current = os.waitpid(probe, os.WNOHANG)
        if waited_pid == probe:
            status = current
            break
        module.time.sleep(0.02)
    if status is None:
        os.kill(probe, signal.SIGKILL)
        _, status = os.waitpid(probe, 0)
    assert os.WIFSIGNALED(status)
    assert os.WTERMSIG(status) == expected_signal

for decision_name, decision_signal in (
    ("success", signal.SIGTERM),
    ("timeout", signal.SIGTERM),
    ("failure", signal.SIGTERM),
    ("pre-handler", signal.SIGINT),
    ("pre-keyboard", signal.SIGINT),
    ("multi-pending", signal.SIGTERM),
    ("startup-multi-pending", signal.SIGTERM),
):
    assert_main_signal_exit(decision_name, decision_signal)

# External cleanup must carry the validated leader immutable start identity
# into the first freeze census. Replacing the leader PID between validation and
# freeze must fail before any STOP or KILL can reach the replacement session.
original_validate = module._validate_external_session
original_members = module._session_members
original_current = getattr(module, "_current_process", None)
original_getsid = module.os.getsid
original_getpgid = module.os.getpgid
original_kill = module.os.kill
original_sleep = module.time.sleep
external_sid = 98765431

def external_process(state, started):
    try:
        return module.Process(external_sid, 1, os.geteuid(), state, started)
    except TypeError:
        # Keep this mutation probe executable against the pre-fix four-field
        # Process API: that implementation must reach the signal spy below.
        return module.Process(external_sid, 1, os.geteuid(), state)

validated_leader = external_process("S", "Sun Jul 19 01:00:00 2026")
replacement_leader = external_process("T", "Sun Jul 19 01:00:01 2026")
replacement_signals = []
validate_argcount = original_validate.__code__.co_argcount
cleanup_argcount = module._cleanup_external_session.__code__.co_argcount
try:
    module._session_members = lambda *_args, **_kwargs: {
        external_sid: validated_leader
    }
    module.os.getsid = lambda pid: os.getpid() + 1 if pid == 0 else external_sid
    module.os.getpgid = lambda _pid: external_sid
    if validate_argcount >= 3:
        try:
            original_validate(
                external_sid, os.geteuid(), replacement_leader.started
            )
        except module.SupervisorError:
            pass
        else:
            raise AssertionError("caller start identity was rebound by Python cleanup")

    module._validate_external_session = lambda *_args: {
        external_sid: validated_leader
    }
    module._session_members = lambda *_args, **_kwargs: {
        external_sid: replacement_leader
    }
    module._current_process = lambda _pid: replacement_leader
    module.os.getsid = lambda _pid: external_sid
    module.os.kill = lambda pid, sig: replacement_signals.append((pid, sig))
    module.time.sleep = lambda _seconds: None
    try:
        if cleanup_argcount >= 3:
            module._cleanup_external_session(
                external_sid, os.geteuid(), validated_leader.started
            )
        else:
            module._cleanup_external_session(external_sid)
    except module.SupervisorError:
        pass
    else:
        raise AssertionError("replacement leader escaped fail-closed cleanup")
    assert replacement_signals == []

    # A drift observed by the post-STOP census must stop collection before a
    # later signal is sent using the replacement identity.
    freeze_snapshots = iter([
        {external_sid: validated_leader},
        {external_sid: replacement_leader},
    ])
    module._session_members = lambda *_args, **_kwargs: next(freeze_snapshots)
    module._current_process = lambda _pid: validated_leader
    try:
        module._freeze_session(
            external_sid,
            external_sid,
            require_leader=True,
            expected_leader=validated_leader,
        )
    except module.SupervisorError:
        pass
    else:
        raise AssertionError("post-STOP leader replacement escaped validation")
    assert replacement_signals == [(external_sid, signal.SIGSTOP)]
    replacement_signals[:] = []

    # Even a frozen snapshot that still names the validated leader must be
    # rejected if a final live census observes replacement before SIGKILL.
    frozen_leader = external_process("T", validated_leader.started)
    module._current_process = lambda _pid: replacement_leader
    try:
        module._kill_frozen_members(
            {external_sid: frozen_leader},
            external_sid,
            external_sid,
            kill_leader_last=True,
            expected_leader=validated_leader,
        )
    except module.SupervisorError:
        pass
    else:
        raise AssertionError("replacement leader escaped final identity check")
    assert replacement_signals == []
finally:
    module._validate_external_session = original_validate
    module._session_members = original_members
    if original_current is None:
        delattr(module, "_current_process")
    else:
        module._current_process = original_current
    module.os.getsid = original_getsid
    module.os.getpgid = original_getpgid
    module.os.kill = original_kill
    module.time.sleep = original_sleep

# Force cleanup() itself to fail after a real target creates a second process
# group. The independent emergency path must still collect every live SID
# member and reap the direct target without a blocking wait.
probe = os.fork()
if probe == 0:
    read_fd = -1
    write_fd = -1
    nested_pid = None
    emergency = None
    child_result = 1

    def alarm_timeout(_signum, _frame):
        raise TimeoutError("emergency cleanup probe timed out")

    try:
        signal.signal(signal.SIGALRM, alarm_timeout)
        signal.alarm(10)
        os.setsid()
        read_fd, write_fd = os.pipe()
        os.set_inheritable(write_fd, True)
        script = (
            "set -m; "
            "(trap \"\" HUP INT TERM; while :; do /bin/sleep 1; done) & "
            "nested=$!; printf \"%s\\n\" \"$nested\" >&\"$1\"; "
            "set +m; while :; do /bin/sleep 1; done"
        )
        emergency = module.Supervisor(
            5, ["/bin/bash", "-c", script, "emergency-probe", str(write_fd)]
        )
        emergency.launch()
        os.close(write_fd)
        write_fd = -1
        readable, _, _ = select.select([read_fd], [], [], 2)
        assert readable
        nested_text = os.read(read_fd, 64).decode("ascii").strip()
        assert nested_text.isdecimal() and not nested_text.startswith("0")
        nested_pid = int(nested_text, 10)
        assert os.getsid(emergency.target_pid) == emergency.pid
        assert os.getsid(nested_pid) == emergency.pid
        assert os.getpgid(nested_pid) == nested_pid
        assert nested_pid != emergency.target_pid
        emergency.cleanup = lambda *_args, **_kwargs: (
            (_ for _ in ()).throw(RecursionError())
        )
        emergency.emergency_cleanup()
        deadline = module.time.monotonic() + 2
        while module.time.monotonic() < deadline:
            remaining = module._session_members(
                emergency.pid, excluded=(emergency.pid,)
            )
            if not any(not process.is_zombie for process in remaining.values()):
                break
            module.time.sleep(0.02)
        assert not any(not process.is_zombie for process in remaining.values())
        assert emergency._emergency_reap_target()
        child_result = 0
    except BaseException:
        child_result = 1
    finally:
        signal.alarm(0)
        for descriptor in (read_fd, write_fd):
            if descriptor >= 0:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
        if emergency is not None:
            try:
                emergency._emergency_collect_session()
            except BaseException:
                pass
            emergency._emergency_kill_target()
            for _ in range(module.EMERGENCY_ATTEMPTS):
                if emergency._emergency_reap_target():
                    break
                module.time.sleep(module.POLL_SECONDS)
        if nested_pid is not None:
            try:
                if os.getsid(nested_pid) == os.getpid():
                    os.kill(nested_pid, signal.SIGKILL)
            except OSError:
                pass
    os._exit(child_result)

probe_status = None
probe_deadline = module.time.monotonic() + 12
while module.time.monotonic() < probe_deadline:
    waited_pid, status = os.waitpid(probe, os.WNOHANG)
    if waited_pid == probe:
        probe_status = status
        break
    module.time.sleep(0.02)
if probe_status is None:
    probe_process = module._current_process(probe)
    try:
        if probe_process is not None:
            module._cleanup_external_session(
                probe, probe_process.uid, probe_process.started
            )
    except BaseException:
        pass
    final_deadline = module.time.monotonic() + 2
    while module.time.monotonic() < final_deadline:
        waited_pid, status = os.waitpid(probe, os.WNOHANG)
        if waited_pid == probe:
            probe_status = status
            break
        module.time.sleep(0.02)
if probe_status is None:
    try:
        os.kill(probe, signal.SIGKILL)
    except OSError:
        pass
    _, probe_status = os.waitpid(probe, 0)
assert os.WIFEXITED(probe_status) and os.WEXITSTATUS(probe_status) == 0
' "$_ps_supervisor"; then
  pass "process-supervisor: ancestry, emergency, and terminal decisions are stable"
else
  fail "process-supervisor: ancestry, emergency, or terminal decision escaped"
fi

_ps_sigchld_contract() {
  local tmp="" child="" record pid ppid pgid state rc=125 attempt=0 failed=false
  local owner_pid="" result=1
  _ps_contract_cleanup() {
    if [[ "${child:-}" =~ ^[1-9][0-9]*$ ]] \
      && /bin/kill -0 "${child:-}" 2>/dev/null; then
      /bin/kill -CONT "$child" 2>/dev/null || true
      /bin/kill -TERM "$child" 2>/dev/null || true
      /bin/sleep 0.05
      /bin/kill -KILL "$child" 2>/dev/null || true
    fi
    [[ -z "${child:-}" ]] || wait "$child" 2>/dev/null || true
    [[ -z "${tmp:-}" ]] || /bin/chmod -R u+rwx "$tmp" 2>/dev/null || true
    [[ -z "${tmp:-}" ]] || /bin/rm -rf -- "$tmp"
  }
  trap '_ps_contract_cleanup' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  tmp="$(mktemp -d)" || return 1
  # Bash 3.2 has no BASHPID and $$ keeps the parent value in a subshell.
  # A direct foreground child records the actual PID of this function's shell
  # as its PPID. Avoid command substitution here because that adds a shell.
  /bin/sh -c 'printf "%s\n" "$PPID" > "$1"' \
    process-supervisor-owner "$tmp/owner" \
    || { /bin/rm -rf -- "$tmp"; return 1; }
  IFS= read -r owner_pid < "$tmp/owner" \
    || { /bin/rm -rf -- "$tmp"; return 1; }
  [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] \
    || { /bin/rm -rf -- "$tmp"; return 1; }
  set +m
  (
    trap '' CHLD
    exec "$_ps_python" -I -B -S "$_ps_supervisor" \
      --timeout 5 -- /usr/bin/true
  ) > "$tmp/output" 2>&1 &
  child=$!
  while [[ "$attempt" -lt 250 ]]; do
    record="$(LC_ALL=C /bin/ps -p "$child" \
      -o pid= -o ppid= -o pgid= -o stat= 2>/dev/null \
      | /usr/bin/awk 'NF == 4 { print $1 "|" $2 "|" $3 "|" $4 }')"
    IFS='|' read -r pid ppid pgid state <<< "$record"
    if [[ "$pid" == "$child" && "$ppid" == "$owner_pid" \
      && "$pgid" == "$child" && "$state" == *T* ]] \
      && grep -qx "MDM_SUPERVISOR_READY pid=$child sid=$child" \
        "$tmp/output"; then
      break
    fi
    /bin/kill -0 "$child" 2>/dev/null || break
    /bin/sleep 0.02
    attempt=$((attempt + 1))
  done
  if [[ "$pid" != "$child" || "$ppid" != "$owner_pid" \
    || "$pgid" != "$child" || "$state" != *T* ]]; then
    _ps_contract_cleanup
    child=""
    trap - EXIT HUP INT TERM
    return 1
  else
    /bin/kill -CONT "$child" || failed=true
  fi
  set +e
  wait "$child"
  rc=$?
  set -e
  child=""
  [[ "$rc" -eq 0 ]] || failed=true
  grep -q '^MDM_SUPERVISOR_RUNNING target=' "$tmp/output" || failed=true
  ! grep -q 'lost the supervised child wait identity' "$tmp/output" \
    || failed=true
  [[ "$failed" == false ]] && result=0
  _ps_contract_cleanup || result=1
  trap - EXIT HUP INT TERM
  return "$result"
}

if [[ -z "$_ps_python" ]]; then
  fail "process-supervisor: resolved system Python is unavailable"
elif (_ps_sigchld_contract); then
  pass "process-supervisor: inherited SIGCHLD ignore cannot auto-reap target"
else
  fail "process-supervisor: inherited SIGCHLD ignore changed target status"
fi

_ps_runner_process_contract() {
  local tmp child="" expected zombie_record record_calls wait_calls
  local group_leader_record group_leader_pid=43210
  tmp="$(mktemp -d)" || return 1
  _ps_runner_process_tmp="$tmp"
  _ps_runner_process_child=""
  /usr/bin/touch "$tmp/record-calls" "$tmp/wait-calls"
  _ps_runner_process_cleanup() {
    if [[ "${_ps_runner_process_child:-}" =~ ^[1-9][0-9]*$ ]]; then
      /bin/kill -KILL "$_ps_runner_process_child" 2>/dev/null || true
      builtin wait "$_ps_runner_process_child" 2>/dev/null || true
    fi
    [[ -z "${_ps_runner_process_tmp:-}" ]] \
      || /bin/rm -rf -- "$_ps_runner_process_tmp"
  }
  trap '_ps_runner_process_cleanup' EXIT HUP INT TERM
  # shellcheck source=../mdm-runner-process-lib.sh
  source "$PROJECT_DIR/tests/mdm-runner-process-lib.sh"

  /bin/sleep 30 &
  child=$!
  _ps_runner_process_child="$child"
  expected="$child|1|$child|501|S|Mon Jul 20 00:00:00 2026"
  zombie_record="$child|1|$child|501|Z|Mon Jul 20 00:00:00 2026"
  _mdm_process_record() {
    local calls
    printf 'call\n' >> "$tmp/record-calls"
    calls="$(/usr/bin/wc -l < "$tmp/record-calls" \
      | /usr/bin/tr -d '[:space:]')"
    [[ "$calls" -gt 1 ]] || return 0
    printf '%s\n' "$zombie_record"
  }
  wait() {
    printf 'wait\n' >> "$tmp/wait-calls"
    return 23
  }
  _mdm_wait_bound_supervisor "$child" "$expected" || return 1
  record_calls="$(/usr/bin/wc -l < "$tmp/record-calls" \
    | /usr/bin/tr -d '[:space:]')"
  wait_calls="$(/usr/bin/wc -l < "$tmp/wait-calls" \
    | /usr/bin/tr -d '[:space:]')"
  [[ "$_MDM_LAST_BOUND_WAIT_STATUS" == 23 \
    && "$record_calls" == 2 && "$wait_calls" == 1 ]] || return 1
  /bin/kill -KILL "$child" 2>/dev/null || true
  builtin wait "$child" 2>/dev/null || true
  child=""
  _ps_runner_process_child=""

  group_leader_record="$group_leader_pid|1|$group_leader_pid|501|S|\
Mon Jul 20 00:00:00 2026"
  _mdm_process_record() { printf '%s\n' "$group_leader_record"; }
  _mdm_process_session_id() { printf '%s\n' $((group_leader_pid + 1)); }
  if MDM_TEST_SYSTEM_PYTHON=/usr/bin/true SUPERVISOR=/dev/null \
      _mdm_external_cleanup_session "$group_leader_record"; then
    return 1
  fi
  _mdm_process_session_id() { printf '%s\n' "$group_leader_pid"; }
  MDM_TEST_SYSTEM_PYTHON=/usr/bin/true SUPERVISOR=/dev/null \
    _mdm_external_cleanup_session "$group_leader_record" || return 1
}

if (_ps_runner_process_contract); then
  pass "process-supervisor: runner waits and external SID cleanup stay bound"
else
  fail "process-supervisor: runner wait or external SID cleanup escaped bounds"
fi

unset -f _ps_sigchld_contract 2>/dev/null || true
unset -f _ps_runner_process_contract 2>/dev/null || true
unset _ps_supervisor _ps_python
