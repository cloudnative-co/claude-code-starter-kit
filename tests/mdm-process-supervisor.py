#!/usr/bin/env python3
"""Run one MDM test in a bounded, independently cleanable POSIX session."""

import errno
import os
import signal
import stat
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


EXIT_TIMEOUT = 124
EXIT_SUPERVISOR_ERROR = 125
MAX_TIMEOUT_SECONDS = 2700
POLL_SECONDS = 0.02
PS_TIMEOUT_SECONDS = 2.0
FREEZE_ATTEMPTS = 50
CLEANUP_ATTEMPTS = 250
EMERGENCY_ATTEMPTS = 100
SUPPORTED_SIGNALS = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
SIGNAL_NAMES = {signal.SIGHUP: "HUP", signal.SIGINT: "INT", signal.SIGTERM: "TERM"}
_STARTUP_SIGNAL: Optional[int] = None


class SupervisorError(RuntimeError):
    """A fail-closed process supervision error."""

def _record_startup_signal(signum: int, _frame: object) -> None:
    global _STARTUP_SIGNAL
    if _STARTUP_SIGNAL is None:
        _STARTUP_SIGNAL = signum

@dataclass(frozen=True)
class Process:
    pid: int
    ppid: int
    uid: int
    state: str
    started: str = ""

    @property
    def is_zombie(self) -> bool:
        return self.state.startswith("Z")

    @property
    def is_stopped(self) -> bool:
        return self.state.startswith(("T", "t"))

def _diagnostic(message: str) -> None:
    """Diagnostics must never prevent cleanup, including with closed stderr."""
    try:
        if not stat.S_ISREG(os.fstat(2).st_mode):
            return
        os.write(2, (message.replace("\n", " ") + "\n").encode("utf-8", "replace"))
    except OSError:
        pass


def _parse_positive_decimal(value: str, maximum: Optional[int] = None) -> int:
    if not value or not value.isascii() or not value.isdecimal():
        raise SupervisorError("value must be a positive canonical decimal")
    if value.startswith("0"):
        raise SupervisorError("value must not contain a leading zero")
    max_digits = len(str(maximum)) if maximum is not None else 20
    if len(value) > max_digits:
        raise SupervisorError("value has too many decimal digits")
    parsed = int(value, 10)
    if parsed < 1 or (maximum is not None and parsed > maximum):
        raise SupervisorError("value is outside the accepted range")
    return parsed


def _parse_start_identity(value: str) -> str:
    printable = value.isascii() and all(" " <= char <= "~" for char in value)
    if not value or len(value) > 64 or not printable:
        raise SupervisorError("process start identity is not canonical ASCII")
    fields = value.split(" ")
    if len(fields) != 5 or any(not field for field in fields):
        raise SupervisorError("process start identity is malformed")
    return value


def _parse_cli(argv: Sequence[str]) -> Tuple[str, int, List[str], Optional[int], Optional[str]]:
    if (
        len(argv) == 6
        and argv[0] == "--cleanup-session"
        and argv[2] == "--expected-uid"
        and argv[4] == "--expected-start"
    ):
        sid = _parse_positive_decimal(argv[1])
        uid = 0 if argv[3] == "0" else _parse_positive_decimal(argv[3], 4294967295)
        return "cleanup", sid, [], uid, _parse_start_identity(argv[5])
    if len(argv) >= 4 and argv[0] == "--timeout" and argv[2] == "--":
        timeout = _parse_positive_decimal(argv[1], MAX_TIMEOUT_SECONDS)
        command = list(argv[3:])
        if not command or not os.path.isabs(command[0]):
            raise SupervisorError("supervised command must use an absolute path")
        return "run", timeout, command, None, None
    raise SupervisorError(
        "usage: mdm-process-supervisor.py --timeout SECONDS -- /absolute/command [args...] "
        "or --cleanup-session SID --expected-uid UID --expected-start LSTART"
    )


def _ps_path() -> str:
    if sys.platform != "darwin" and not sys.platform.startswith("linux"):
        raise SupervisorError("unsupported process-census platform")
    path = "/bin/ps"
    if not os.path.isfile(path) or not os.access(path, os.X_OK):
        raise SupervisorError("required absolute process-census tool is unavailable")
    return path


PS_COLUMNS = ("-o", "pid=", "-o", "ppid=", "-o", "uid=", "-o", "stat=", "-o", "lstart=")


def _process_census(command: Sequence[str], missing_ok: bool = False) -> Dict[int, Process]:
    try:
        result = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            encoding="ascii",
            errors="strict",
            env={"LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TZ": "UTC0"},
            start_new_session=True,
            timeout=PS_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError, UnicodeError) as exc:
        raise SupervisorError("process census could not execute") from exc
    if result.returncode != 0:
        if missing_ok and result.returncode == 1 and not result.stdout.strip():
            return {}
        raise SupervisorError("process census returned a nonzero status")

    processes: Dict[int, Process] = {}
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 4)
        if len(fields) != 5:
            raise SupervisorError("process census returned a malformed row")
        pid_text, ppid_text, uid_text, state, started_text = fields
        started = _parse_start_identity(" ".join(started_text.split()))
        uid_is_decimal = uid_text.isdecimal() or (
            uid_text.startswith("-") and uid_text[1:].isdecimal()
        )
        if not (pid_text.isdecimal() and ppid_text.isdecimal() and uid_is_decimal):
            raise SupervisorError("process census returned a nonnumeric identity")
        process = Process(int(pid_text), int(ppid_text), int(uid_text), state, started)
        if process.pid < 1 or process.ppid < 0 or process.pid in processes:
            raise SupervisorError("process census returned an invalid identity")
        processes[process.pid] = process
    if not processes:
        if missing_ok:
            return {}
        raise SupervisorError("process census returned no processes")
    return processes


def _all_processes() -> Dict[int, Process]:
    return _process_census([_ps_path(), "-ax", *PS_COLUMNS])


def _require_process_identity(
    actual: Optional[Process], expected: Process, message: str
) -> Process:
    if (
        actual is None
        or actual.is_zombie
        or not expected.started
        or (actual.pid, actual.uid, actual.started)
        != (expected.pid, expected.uid, expected.started)
    ):
        raise SupervisorError(message)
    return actual


def _current_process(pid: int) -> Optional[Process]:
    processes = _process_census(
        [_ps_path(), "-p", str(pid), *PS_COLUMNS], missing_ok=True
    )
    if len(processes) > 1:
        raise SupervisorError("targeted process census returned multiple identities")
    return processes.get(pid)


def _session_members(
    session_id: int,
    excluded: Iterable[int] = (),
    expected_leader: Optional[Process] = None,
) -> Dict[int, Process]:
    excluded_set = set(excluded)
    members: Dict[int, Process] = {}
    processes = _all_processes()
    if expected_leader is not None:
        _require_process_identity(
            processes.get(expected_leader.pid), expected_leader,
            "cleanup session leader identity changed during census",
        )
    for pid, process in processes.items():
        if pid in excluded_set:
            continue
        try:
            actual_session = os.getsid(pid)
        except OSError as exc:
            if exc.errno == errno.ESRCH:
                continue
            raise SupervisorError("could not bind process census to a session") from exc
        if actual_session == session_id:
            members[pid] = process
    return members


def _depths(members: Dict[int, Process], leader: int) -> Dict[int, int]:
    depths: Dict[int, int] = {}
    for member_pid in members:
        if member_pid in depths:
            continue
        path: List[int] = []
        positions: Dict[int, int] = {}
        current = member_pid
        while current in members and current not in depths and current != leader:
            if current in positions:
                cycle_start = positions[current]
                for cycle_pid in path[cycle_start:]:
                    depths[cycle_pid] = 1
                path = path[:cycle_start]
                base = 1
                break
            positions[current] = len(path)
            path.append(current)
            current = members[current].ppid
        else:
            base = depths.get(current, 0)
            if current == leader and current in members:
                depths[current] = 0
        for path_pid in reversed(path):
            base += 1
            depths[path_pid] = base
    return depths


def _signal_if_still_in_session(
    process: Process,
    session_id: int,
    sig: int,
    expected_leader: Optional[Process] = None,
) -> bool:
    """Recheck the bound leader identity and SID before each signal."""
    if process.pid == os.getpid():
        return False
    try:
        if expected_leader is not None:
            _require_process_identity(
                _current_process(expected_leader.pid), expected_leader,
                "cleanup session leader identity changed before signaling",
            )
        if os.getsid(process.pid) != session_id:
            if expected_leader is not None:
                raise SupervisorError(
                    "cleanup target left the validated session before signaling"
                )
            return False
        if expected_leader is not None:
            _require_process_identity(
                _current_process(expected_leader.pid), expected_leader,
                "cleanup session leader identity changed before signaling",
            )
        os.kill(process.pid, sig)
        return True
    except OSError as exc:
        if exc.errno == errno.ESRCH:
            return False
        raise SupervisorError("could not signal a bound session member") from exc


def _ordered(members: Dict[int, Process], leader: int, child_first: bool) -> List[Process]:
    depths = _depths(members, leader)
    return sorted(
        members.values(),
        key=lambda process: (depths[process.pid], process.pid),
        reverse=child_first,
    )


def _freeze_session(
    session_id: int,
    leader: int,
    excluded: Iterable[int] = (),
    require_leader: bool = False,
    expected_leader: Optional[Process] = None,
) -> Dict[int, Process]:
    excluded_set = set(excluded)
    if expected_leader is not None and expected_leader.pid != leader:
        raise SupervisorError("validated cleanup leader does not match the session ID")
    for _ in range(FREEZE_ATTEMPTS):
        before = _session_members(
            session_id, excluded_set, expected_leader=expected_leader
        )
        if expected_leader is not None:
            _require_process_identity(
                before.get(leader), expected_leader,
                "cleanup session leader identity changed before the session froze",
            )
        if require_leader and (leader not in before or before[leader].is_zombie):
            raise SupervisorError("cleanup target is no longer a live session leader")
        for process in _ordered(before, leader, child_first=False):
            if not process.is_zombie:
                _signal_if_still_in_session(
                    process,
                    session_id,
                    signal.SIGSTOP,
                    expected_leader=expected_leader,
                )
        time.sleep(POLL_SECONDS)
        after = _session_members(
            session_id, excluded_set, expected_leader=expected_leader
        )
        if expected_leader is not None:
            _require_process_identity(
                after.get(leader), expected_leader,
                "cleanup session leader identity changed while the session froze",
            )
        if require_leader and (leader not in after or after[leader].is_zombie):
            raise SupervisorError("cleanup target changed before the session froze")
        if set(before) == set(after) and all(
            process.is_zombie or process.is_stopped for process in after.values()
        ):
            return after
    raise SupervisorError("session did not reach a stable stopped state")


def _kill_frozen_members(
    members: Dict[int, Process],
    session_id: int,
    leader: int,
    kill_leader_last: bool,
    expected_leader: Optional[Process] = None,
) -> None:
    if expected_leader is not None:
        if expected_leader.pid != leader:
            raise SupervisorError(
                "validated cleanup leader does not match the session ID"
            )
        _require_process_identity(
            members.get(leader), expected_leader,
            "cleanup session leader identity changed before collection",
        )
    for process in _ordered(members, leader, child_first=True):
        if kill_leader_last and process.pid == leader:
            continue
        if not process.is_zombie:
            _signal_if_still_in_session(
                process,
                session_id,
                signal.SIGKILL,
                expected_leader=expected_leader,
            )
    if kill_leader_last:
        leader_process = members.get(leader)
        if leader_process is None:
            raise SupervisorError("session leader disappeared before final collection")
        _signal_if_still_in_session(
            leader_process,
            session_id,
            signal.SIGKILL,
            expected_leader=expected_leader,
        )


def _wait_for_empty_session(
    session_id: int,
    excluded: Iterable[int] = (),
    may_resignal: bool = False,
    leader: Optional[int] = None,
) -> bool:
    excluded_set = set(excluded)
    for _ in range(CLEANUP_ATTEMPTS):
        members = _session_members(session_id, excluded_set)
        live_members = {
            pid: process for pid, process in members.items() if not process.is_zombie
        }
        if not live_members:
            return True
        if may_resignal:
            root = session_id if leader is None else leader
            for process in _ordered(live_members, root, child_first=True):
                _signal_if_still_in_session(process, session_id, signal.SIGKILL)
        time.sleep(POLL_SECONDS)
    return False


def _validate_external_session(session_id: int, expected_uid: int, expected_started: str) -> Dict[int, Process]:
    if session_id == 1:
        raise SupervisorError("refusing to collect the system session")
    if os.getsid(0) == session_id:
        raise SupervisorError("refusing to collect the caller's own session")
    try:
        if os.getsid(session_id) != session_id or os.getpgid(session_id) != session_id:
            raise SupervisorError("cleanup SID is not a current session leader PID")
    except OSError as exc:
        raise SupervisorError("cleanup session leader does not exist") from exc
    members = _session_members(session_id)
    leader = members.get(session_id)
    if leader is None or leader.is_zombie:
        raise SupervisorError("cleanup session leader is not live in the census")
    if leader.uid != expected_uid or leader.started != expected_started:
        raise SupervisorError("cleanup session leader does not match the caller identity")
    if leader.uid != os.geteuid():
        raise SupervisorError("cleanup session leader belongs to another effective UID")
    return members


def _cleanup_external_session(session_id: int, expected_uid: int, expected_started: str) -> int:
    validated = _validate_external_session(session_id, expected_uid, expected_started)
    validated_leader = validated[session_id]
    _diagnostic("MDM_SUPERVISOR_CLEANUP_BEGIN sid={}".format(session_id))
    frozen = _freeze_session(
        session_id,
        session_id,
        require_leader=True,
        expected_leader=validated_leader,
    )
    _kill_frozen_members(
        frozen,
        session_id,
        session_id,
        kill_leader_last=True,
        expected_leader=validated_leader,
    )
    if not _wait_for_empty_session(session_id):
        raise SupervisorError("cleanup session did not disappear after leader collection")
    _diagnostic("MDM_SUPERVISOR_CLEANUP_DONE sid={}".format(session_id))
    return 0


class Supervisor:
    def __init__(self, timeout: int, command: Sequence[str]) -> None:
        self.timeout = timeout
        self.command = list(command)
        self.pid = os.getpid()
        self.session_id = self.pid
        self.target_pid: Optional[int] = None
        self.target_status: Optional[int] = None
        self.pending_signal: Optional[int] = None

    def _handle_signal(self, signum: int, _frame: object) -> None:
        if self.pending_signal is None:
            self.pending_signal = signum

    def establish_session(self) -> None:
        try:
            os.setsid()
        except OSError as exc:
            raise SupervisorError("could not establish an isolated session") from exc
        if os.getsid(0) != self.pid or os.getpgrp() != self.pid:
            raise SupervisorError("isolated session identity validation failed")
        for signum in SUPPORTED_SIGNALS:
            signal.signal(signum, self._handle_signal)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, SUPPORTED_SIGNALS)
        _diagnostic("MDM_SUPERVISOR_READY pid={} sid={}".format(self.pid, self.session_id))
        os.kill(self.pid, signal.SIGSTOP)

    def launch(self) -> None:
        try:
            target_pid = os.fork()
        except OSError as exc:
            raise SupervisorError("could not fork the supervised command") from exc
        if target_pid == 0:
            reset_signals = list(SUPPORTED_SIGNALS) + [
                signal.SIGPIPE,
                signal.SIGQUIT,
            ]
            for signal_name in ("SIGXFZ", "SIGXFSZ"):
                signum = getattr(signal, signal_name, None)
                if signum is not None and signum not in reset_signals:
                    reset_signals.append(signum)
            for signum in reset_signals:
                signal.signal(signum, signal.SIG_DFL)
            try:
                os.execve(self.command[0], self.command, os.environ.copy())
            except FileNotFoundError:
                _diagnostic("FAIL: MDM supervisor target executable was not found")
                os._exit(127)
            except OSError:
                _diagnostic("FAIL: MDM supervisor could not execute target")
                os._exit(126)
        self.target_pid = target_pid
        _diagnostic(
            "MDM_SUPERVISOR_RUNNING target={} sid={} timeout={}".format(
                target_pid, self.session_id, self.timeout
            )
        )

    def poll_target(self) -> Optional[int]:
        if self.target_status is not None:
            return self.target_status
        if self.target_pid is None:
            return None
        try:
            waited_pid, status = os.waitpid(self.target_pid, os.WNOHANG)
        except ChildProcessError as exc:
            raise SupervisorError("lost the supervised child wait identity") from exc
        if waited_pid == self.target_pid:
            self.target_status = status
        return self.target_status

    def cleanup(self, frozen: Optional[Dict[int, Process]] = None) -> bool:
        if frozen is None:
            frozen = _freeze_session(
                self.session_id,
                self.session_id,
                excluded=(self.pid,),
                require_leader=False,
            )
        _kill_frozen_members(
            frozen, self.session_id, self.session_id, kill_leader_last=False
        )
        for _ in range(CLEANUP_ATTEMPTS):
            self.poll_target()
            members = _session_members(self.session_id, excluded=(self.pid,))
            live_members = {
                pid: process for pid, process in members.items() if not process.is_zombie
            }
            if not live_members:
                return True
            for process in _ordered(live_members, self.session_id, child_first=True):
                _signal_if_still_in_session(process, self.session_id, signal.SIGKILL)
            time.sleep(POLL_SECONDS)
        return False

    def _target_exit_code(self) -> int:
        if self.target_status is None:
            raise SupervisorError("target exit status is unavailable")
        if os.WIFEXITED(self.target_status):
            return os.WEXITSTATUS(self.target_status)
        if os.WIFSIGNALED(self.target_status):
            return 128 + os.WTERMSIG(self.target_status)
        raise SupervisorError("target returned an unsupported wait status")

    def _terminal_signal_after_block(self) -> Optional[int]:
        if self.pending_signal is not None:
            return self.pending_signal
        pending = signal.sigpending()
        for signum in SUPPORTED_SIGNALS:
            if signum in pending:
                return signum
        return None

    def run(self) -> int:
        self.establish_session()
        if self.pending_signal is not None:
            signum = self.pending_signal
            _diagnostic(
                "FAIL: MDM supervisor received {} before target launch".format(
                    SIGNAL_NAMES[signum]
                )
            )
            return 128 + signum
        self.launch()
        deadline = time.monotonic() + self.timeout
        while True:
            status = self.poll_target()
            if self.pending_signal is not None:
                signum = self.pending_signal
                _diagnostic(
                    "FAIL: MDM supervisor received {}; collecting session {}".format(
                        SIGNAL_NAMES[signum], self.session_id
                    )
                )
                if not self.cleanup():
                    _diagnostic("FAIL: MDM supervisor signal cleanup remained incomplete")
                    self.emergency_cleanup()
                return 128 + signum
            if status is not None:
                signal.pthread_sigmask(signal.SIG_BLOCK, SUPPORTED_SIGNALS)
                frozen = _freeze_session(
                    self.session_id,
                    self.session_id,
                    excluded=(self.pid,),
                    require_leader=False,
                )
                signum = self._terminal_signal_after_block()
                if signum is not None:
                    _diagnostic(
                        "FAIL: MDM supervisor received {}; collecting session {}".format(
                            SIGNAL_NAMES[signum], self.session_id
                        )
                    )
                    if not self.cleanup(frozen):
                        _diagnostic(
                            "FAIL: MDM supervisor signal cleanup remained incomplete"
                        )
                        self.emergency_cleanup()
                    return 128 + signum
                live_members = {
                    pid: process
                    for pid, process in frozen.items()
                    if not process.is_zombie
                }
                if live_members:
                    _diagnostic(
                        "FAIL: MDM supervisor target exited but session {} retained members; "
                        "collecting".format(self.session_id)
                    )
                    if not self.cleanup(frozen):
                        _diagnostic("FAIL: MDM supervisor residual cleanup remained incomplete")
                        self.emergency_cleanup()
                    signum = self._terminal_signal_after_block()
                    if signum is not None:
                        return 128 + signum
                    return EXIT_SUPERVISOR_ERROR
                return self._target_exit_code()
            if time.monotonic() >= deadline:
                signal.pthread_sigmask(signal.SIG_BLOCK, SUPPORTED_SIGNALS)
                _diagnostic(
                    "FAIL: MDM supervisor timeout after {}s; collecting session {}".format(
                        self.timeout, self.session_id
                    )
                )
                if not self.cleanup():
                    _diagnostic("FAIL: MDM supervisor timeout cleanup remained incomplete")
                    self.emergency_cleanup()
                signum = self._terminal_signal_after_block()
                if signum is not None:
                    return 128 + signum
                return EXIT_TIMEOUT
            time.sleep(POLL_SECONDS)

    def emergency_cleanup(self) -> None:
        if self.target_pid is None:
            return
        needs_fallback = False
        try:
            if not self.cleanup():
                needs_fallback = True
        except BaseException:
            needs_fallback = True
        if not needs_fallback:
            return
        try:
            if not self._emergency_collect_session():
                _diagnostic("FAIL: MDM supervisor emergency cleanup remained incomplete")
        except BaseException:
            self._emergency_kill_target()
            for _ in range(EMERGENCY_ATTEMPTS):
                if self._emergency_reap_target():
                    return
                time.sleep(POLL_SECONDS)

    def _emergency_kill_target(self) -> None:
        if self.target_pid is None:
            return
        try:
            if os.getsid(self.target_pid) == self.session_id:
                os.kill(self.target_pid, signal.SIGKILL)
        except BaseException:
            pass

    def _emergency_reap_target(self) -> bool:
        if self.target_pid is None or self.target_status is not None:
            return True
        try:
            waited_pid, status = os.waitpid(self.target_pid, os.WNOHANG)
            if waited_pid == self.target_pid:
                self.target_status = status
                return True
            return False
        except ChildProcessError:
            return True
        except BaseException:
            return False

    def _emergency_collect_session(self) -> bool:
        try:
            frozen = _freeze_session(
                self.session_id,
                self.session_id,
                excluded=(self.pid,),
                require_leader=False,
            )
            _kill_frozen_members(
                frozen,
                self.session_id,
                self.session_id,
                kill_leader_last=False,
            )
        except BaseException:
            pass

        for _ in range(EMERGENCY_ATTEMPTS):
            target_reaped = self._emergency_reap_target()
            try:
                members = _session_members(
                    self.session_id, excluded=(self.pid,)
                )
            except BaseException:
                self._emergency_kill_target()
                time.sleep(POLL_SECONDS)
                continue
            live_members = {
                pid: process
                for pid, process in members.items()
                if not process.is_zombie
            }
            if not live_members and target_reaped:
                return True
            for process in live_members.values():
                try:
                    _signal_if_still_in_session(
                        process, self.session_id, signal.SIGSTOP
                    )
                except BaseException:
                    pass
            for process in live_members.values():
                try:
                    _signal_if_still_in_session(
                        process, self.session_id, signal.SIGKILL
                    )
                except BaseException:
                    pass
            self._emergency_kill_target()
            time.sleep(POLL_SECONDS)
        return False


def _terminal_signal(supervisor: Optional[Supervisor]) -> Optional[int]:
    if _STARTUP_SIGNAL in SUPPORTED_SIGNALS:
        return _STARTUP_SIGNAL
    try:
        if supervisor is not None:
            signum = supervisor._terminal_signal_after_block()
        else:
            signum = next((item for item in SUPPORTED_SIGNALS if item in signal.sigpending()), None)
    except BaseException:
        return None
    return signum if signum in SUPPORTED_SIGNALS else None

def _exit_after_supervisor_failure(supervisor: Optional[Supervisor]) -> int:
    signal.pthread_sigmask(signal.SIG_BLOCK, SUPPORTED_SIGNALS)
    try:
        if supervisor is not None:
            supervisor.emergency_cleanup()
    except BaseException:
        _diagnostic("FAIL: MDM supervisor emergency cleanup raised an internal error")
    signum = _terminal_signal(supervisor)
    return 128 + signum if signum is not None else EXIT_SUPERVISOR_ERROR

def _finalize_process_exit(supervisor: Optional[Supervisor], exit_code: int) -> int:
    signal.pthread_sigmask(signal.SIG_BLOCK, SUPPORTED_SIGNALS)
    signum = _terminal_signal(supervisor)
    for item in SUPPORTED_SIGNALS:
        signal.signal(item, signal.SIG_DFL)
    if signum is not None and signum not in signal.sigpending():
        os.kill(os.getpid(), signum)
    unblocked = (signum,) if signum is not None else SUPPORTED_SIGNALS
    signal.pthread_sigmask(signal.SIG_UNBLOCK, unblocked)
    return exit_code

def main(argv: Sequence[str]) -> int:
    global _STARTUP_SIGNAL
    supervisor: Optional[Supervisor] = None
    _STARTUP_SIGNAL = None
    try:
        for signum in (signal.SIGINT, signal.SIGHUP, signal.SIGTERM):
            signal.signal(signum, _record_startup_signal)
        signal.pthread_sigmask(signal.SIG_BLOCK, SUPPORTED_SIGNALS)
        signal.signal(signal.SIGCHLD, signal.SIG_DFL)
        mode, value, command, expected_uid, expected_started = _parse_cli(argv)
        _ps_path()
        if mode == "cleanup":
            _STARTUP_SIGNAL = None
            for signum in SUPPORTED_SIGNALS:
                signal.signal(signum, signal.SIG_IGN)
            signal.pthread_sigmask(signal.SIG_UNBLOCK, SUPPORTED_SIGNALS)
            if expected_uid is None or expected_started is None:
                raise SupervisorError("cleanup session identity is unavailable")
            return _cleanup_external_session(value, expected_uid, expected_started)
        supervisor = Supervisor(value, command)
        supervisor.pending_signal = _STARTUP_SIGNAL
        exit_code = supervisor.run()
    except KeyboardInterrupt:
        signal.pthread_sigmask(signal.SIG_BLOCK, SUPPORTED_SIGNALS)
        _record_startup_signal(signal.SIGINT, None)
        _diagnostic("FAIL: MDM supervisor received INT during startup")
        exit_code = _exit_after_supervisor_failure(supervisor)
    except SupervisorError as exc:
        _diagnostic("FAIL: MDM supervisor: {}".format(exc))
        exit_code = _exit_after_supervisor_failure(supervisor)
    except BaseException as exc:  # Last-resort fail-closed path for the test runner.
        _diagnostic("FAIL: MDM supervisor internal error: {}".format(type(exc).__name__))
        exit_code = _exit_after_supervisor_failure(supervisor)
    return _finalize_process_exit(supervisor, exit_code)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
