"""Guarded process execution and shared run context for the E2E harness."""

from __future__ import annotations

from collections.abc import Callable
import json
import os
import pty
import select
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MTEST = os.path.join(REPO_ROOT, "build", "mtest")
E2E_ROOT = os.path.join(REPO_ROOT, "e2e")
MANIFEST_PATH = os.path.join(E2E_ROOT, "manifest.json")
TOOLCHAIN_FIXTURES = os.path.join(REPO_ROOT, "scripts", "fixtures", "toolchain")
LOGGING_MOJO = os.path.join(TOOLCHAIN_FIXTURES, "logging_mojo.py")
FAKE_SLOW_MOJO = os.path.join(TOOLCHAIN_FIXTURES, "fake_slow_mojo.py")
FAKE_CRASH_MOJO = os.path.join(TOOLCHAIN_FIXTURES, "fake_crash_mojo.py")
FAKE_WINDOW_MOJO = os.path.join(TOOLCHAIN_FIXTURES, "fake_window_mojo.py")
FAKE_STUBBORN_MOJO = os.path.join(TOOLCHAIN_FIXTURES, "fake_stubborn_mojo.py")
FAKE_FD_MOJO = os.path.join(TOOLCHAIN_FIXTURES, "fake_fd_mojo.py")
FAKE_HOSTILE_MOJO = os.path.join(TOOLCHAIN_FIXTURES, "fake_hostile_mojo.py")
PATH_MOJO = os.path.join(TOOLCHAIN_FIXTURES, "path_mojo.py")
FAKE_RETRY_CRASH_MOJO = os.path.join(
    TOOLCHAIN_FIXTURES, "fake_retry_crash_mojo.py"
)
JSON_TERMINAL_WRITE_FAULT = os.path.join(
    REPO_ROOT, "tests", "native", "e2e_json_terminal_write_fault.c"
)
CONFIG_OPEN_FAULT = os.path.join(
    REPO_ROOT, "tests", "native", "e2e_config_open_fault.c"
)
STATE_PERSISTENCE_FAULT = os.path.join(
    REPO_ROOT, "tests", "native", "e2e_state_persistence_fault.c"
)

# These are guards, not performance thresholds. Cold `mojo build` is slow.
DEFAULT_TIMEOUT = 180.0
SHORT_TIMEOUT = 30.0
BUILD_BIN_TIMEOUT = 600.0

# How often a readiness or liveness barrier re-checks. Small enough that the
# harness reacts inside the supervisor's 300 ms run-step grace, large enough not
# to spin a core while a cold `mojo build` runs.
BARRIER_POLL_SECONDS = 0.005
# How long a process group may take to disappear once the process that owned it
# has exited and been reaped. This is a hard-failing deadline, never a tolerance:
# a group still alive when it expires is a surviving-child defect.
GROUP_EXIT_DEADLINE = 5.0
# How long the harness's own cleanup waits on the polite signal before escalating.
# Short on purpose: the actors this sweeps either die at once or refuse SIGTERM
# outright, so a longer wait would only tax the scenarios that refuse it.
GROUP_TERM_SECONDS = 0.3


class ScenarioError(AssertionError):
    """An expected E2E scenario failure with diagnostic context."""


def group_alive(pgid: int) -> bool:
    """Whether any process still belongs to ``pgid``.

    Args:
        pgid: The process-group id to probe.

    Returns:
        True while the group has at least one member, false once the kernel no
        longer knows it. A permission error counts as alive: something is there.
    """
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def expect_group_gone(pgid: int, what: str) -> None:
    """Assert that ``pgid`` disappears, under one monotonic deadline.

    Args:
        pgid: The process-group id that must not survive.
        what: Human-readable subject for the failure message.

    Raises:
        ScenarioError: If the group is still alive when the deadline expires.
    """
    limit = time.monotonic() + GROUP_EXIT_DEADLINE
    while True:
        if not group_alive(pgid):
            return
        if time.monotonic() >= limit:
            raise ScenarioError(
                f"process group {pgid} ({what}) was still alive "
                f"{GROUP_EXIT_DEADLINE:.1f}s after its owner exited — an "
                "orphaned child survived"
            )
        time.sleep(BARRIER_POLL_SECONDS)


def limit_nofile(soft: int) -> Callable[[], None]:
    """A POSIX `preexec_fn` that lowers only the CHILD's descriptor soft limit.

    `preexec_fn` runs after the fork and before the exec, so the new soft limit
    belongs to the spawned process alone: this harness keeps its own limit, and
    nothing else on the host is perturbed. The hard limit is carried through
    unchanged, so the call only ever lowers a ceiling it is allowed to lower.

    Args:
        soft: The soft `RLIMIT_NOFILE` the child runs under.

    Returns:
        The callable `subprocess.Popen` invokes in the forked child.
    """

    def apply() -> None:
        import resource

        _old_soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        resource.setrlimit(resource.RLIMIT_NOFILE, (soft, hard))

    return apply


@dataclass
class Run:
    """Complete captured result from one guarded mtest process."""

    argv: list[str]
    returncode: int
    stdout: str
    stderr: str
    wall: float
    pgid: int | None = None
    second_signal_wall: float | None = None
    """Seconds from the second signal to the process's exit, when one was sent.

    The interval a hard-termination contract is measured against: a run that
    waited out a per-slot grace instead of being killed at once shows up here as
    that whole grace. None when the run took only one signal.
    """

    @property
    def combined(self) -> str:
        """Return stdout and stderr in the harness's historical parse order."""
        return self.stdout + "\n" + self.stderr


@dataclass(frozen=True)
class E2ERunner:
    """Run the real mtest binary with capture and process-group cleanup."""

    repo_root: str | os.PathLike[str] = REPO_ROOT
    mtest: str | os.PathLike[str] = MTEST
    default_timeout: float = DEFAULT_TIMEOUT
    short_timeout: float = SHORT_TIMEOUT

    def run_mtest(
        self,
        args: list[str],
        *,
        timeout: float | None = None,
        check_binary: bool = True,
        env_overrides: dict[str, str] | None = None,
        fd_limit: int | None = None,
    ) -> Run:
        """Capture one mtest run under a hard whole-process-group deadline.

        Args:
            args: The mtest arguments after the binary.
            timeout: The whole run's wall budget; the runner's default when
                None.
            check_binary: Whether a missing binary fails before the spawn.
            env_overrides: Environment entries layered onto the child's env.
            fd_limit: A soft `RLIMIT_NOFILE` imposed on the CHILD ONLY, so a
                scenario can drive mtest's descriptor arithmetic against a real
                kernel limit rather than a mocked one. Absent by default: the
                run inherits this harness's own limit and behaves exactly as
                every other scenario's does.

        Returns:
            The captured run.

        Raises:
            ScenarioError: If the binary is missing or the run outlives its
                deadline.
        """
        binary = os.fspath(self.mtest)
        if check_binary and not os.path.exists(binary):
            raise ScenarioError(
                f"binary not found at {binary}; run `pixi run build-bin`"
            )
        argv = [binary, *args]
        child_env = dict(os.environ)
        child_env["GITHUB_ACTIONS"] = ""
        if env_overrides:
            child_env.update(env_overrides)
        wall_limit = self.default_timeout if timeout is None else timeout
        start = time.monotonic()
        proc = subprocess.Popen(
            argv,
            cwd=os.fspath(self.repo_root),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
            env=child_env,
            preexec_fn=None if fd_limit is None else limit_nofile(fd_limit),
        )
        pgid = os.getpgid(proc.pid)
        try:
            out, err = proc.communicate(timeout=wall_limit)
        except subprocess.TimeoutExpired:
            self.kill_group(proc)
            out, err = proc.communicate()
            raise ScenarioError(
                f"mtest did not return within {wall_limit}s for argv {argv} — "
                "killed its process group (possible runner hang)"
            )
        return Run(
            argv=argv,
            returncode=proc.returncode,
            stdout=out,
            stderr=err,
            wall=time.monotonic() - start,
            pgid=pgid,
        )

    def run_mtest_pty(
        self,
        args: list[str],
        *,
        env_overrides: dict[str, str | None] | None = None,
        timeout: float | None = None,
    ) -> tuple[int, bytes]:
        """Capture combined output from mtest on a PTY under a hard deadline."""
        binary = os.fspath(self.mtest)
        if not os.path.exists(binary):
            raise ScenarioError(
                f"binary not found at {binary}; run `pixi run build-bin`"
            )
        argv = [binary, *args]
        env = dict(os.environ)
        env["GITHUB_ACTIONS"] = ""
        if env_overrides:
            for key, value in env_overrides.items():
                if value is None:
                    env.pop(key, None)
                else:
                    env[key] = value
        wall_limit = self.short_timeout if timeout is None else timeout
        master_fd, slave_fd = pty.openpty()
        proc = subprocess.Popen(
            argv,
            cwd=os.fspath(self.repo_root),
            stdout=slave_fd,
            stderr=slave_fd,
            env=env,
            start_new_session=True,
        )
        os.close(slave_fd)
        out = bytearray()
        deadline = time.monotonic() + wall_limit
        timed_out = False
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    break
                ready, _, _ = select.select([master_fd], [], [], remaining)
                if not ready:
                    continue
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                out += chunk
        finally:
            os.close(master_fd)

        if timed_out:
            self.kill_group(proc)
            proc.wait(timeout=5)
            raise ScenarioError(
                f"mtest did not return within {wall_limit}s for argv {argv} "
                "under a pty — killed its process group (possible runner hang)"
            )
        remaining = max(0.0, deadline - time.monotonic())
        try:
            returncode = proc.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            self.kill_group(proc)
            proc.wait(timeout=5)
            raise ScenarioError(
                f"mtest closed its pty but never exited for argv {argv} — "
                "killed its process group (possible runner hang)"
            )
        return returncode, bytes(out)

    def run_mtest_signaled(
        self,
        args: list[str],
        *,
        signal_number: int,
        timeout: float,
        ready_files: tuple[str, ...] = (),
        delay: float | None = None,
        second_signal: int | None = None,
        teardown_ready_files: tuple[str, ...] = (),
        owned_pgid_files: tuple[str, ...] = (),
        env_overrides: dict[str, str] | None = None,
    ) -> tuple[Run, int]:
        """Signal a live mtest process, capture it, and enforce one deadline.

        The signal goes to the mtest LEADER pid, never to its process group.
        Forwarding a cleanup signal to the process groups mtest owns is the
        product's job; signalling the group here would test this harness instead
        and would pass even if mtest forwarded nothing.

        Args:
            args: The mtest arguments after the binary.
            signal_number: The signal delivered to the leader once the run is
                armed.
            timeout: The whole call's wall budget, from spawn to exit, measured
                against one monotonic deadline. Every barrier below shares it.
            ready_files: Paths a live actor creates to announce that the run has
                reached the state under test. Every one must exist before the
                signal is sent; the call FAILS at the deadline rather than
                signalling an unarmed run. Mutually exclusive with `delay`.
            delay: A fixed pre-signal wait, for the scenarios whose arming state
                has no file to observe. Mutually exclusive with `ready_files`.
            second_signal: A second signal delivered after `teardown_ready_files`
                appear, for the double-interrupt contract.
            teardown_ready_files: Paths an actor creates once it has observed
                mtest's polite teardown signal. Required with `second_signal`,
                and asserted the same way as `ready_files`.
            owned_pgid_files: Paths in which live actors record their real PGIDs
                before the ready barrier. After a managed signal each recorded
                group must already be gone — the product cleaned up. After a
                fatal SIGKILL, which mtest cannot clean up after, this harness
                terminates each recorded group itself and proves it gone.
            env_overrides: Environment entries layered onto the child's env.

        Returns:
            The captured run — carrying `second_signal_wall`, the interval from
            a second signal to the exit, so a caller can bound hard termination
            against the per-slot grace it must beat — and mtest's own
            process-group id.

        Raises:
            ScenarioError: If the binary is missing, the arming inputs are
                ambiguous, a barrier expires, mtest exits before it is signalled,
                mtest does not exit within the deadline, or a process group
                survives.
        """
        if (delay is None) == (not ready_files):
            raise ScenarioError(
                "run_mtest_signaled needs exactly one arming input: a "
                f"readiness barrier or a fixed delay (ready_files={ready_files!r},"
                f" delay={delay!r})"
            )
        if delay is not None and owned_pgid_files:
            raise ScenarioError(
                "recorded child PGIDs need the readiness barrier that proves "
                "they were written before the signal "
                f"(owned_pgid_files={owned_pgid_files!r})"
            )
        if (second_signal is None) != (not teardown_ready_files):
            raise ScenarioError(
                "a second signal needs a teardown barrier and vice versa "
                f"(second_signal={second_signal!r}, "
                f"teardown_ready_files={teardown_ready_files!r})"
            )
        binary = os.fspath(self.mtest)
        if not os.path.exists(binary):
            raise ScenarioError(
                f"binary not found at {binary}; run `pixi run build-bin`"
            )
        argv = [binary, *args]
        child_env = dict(os.environ)
        child_env["GITHUB_ACTIONS"] = ""
        if env_overrides:
            child_env.update(env_overrides)
        start = time.monotonic()
        deadline = start + timeout
        proc = subprocess.Popen(
            argv,
            cwd=os.fspath(self.repo_root),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
            env=child_env,
        )
        pgid = os.getpgid(proc.pid)
        owned_pgids: list[int] = []
        second_signal_at: float | None = None
        try:
            if delay is not None:
                self._wait_out(min(start + delay, deadline))
            else:
                self._await_barrier(
                    proc,
                    argv,
                    tuple(ready_files) + tuple(owned_pgid_files),
                    deadline,
                    "readiness",
                )
            if proc.poll() is not None:
                stdout, stderr = proc.communicate()
                raise ScenarioError(
                    f"mtest exited before signal {signal_number} could be sent: "
                    f"{argv}\n{stdout}\n{stderr}"
                )
            owned_pgids = self._read_owned_pgids(owned_pgid_files)
            os.kill(proc.pid, signal_number)
            if second_signal is not None:
                self._await_barrier(
                    proc, argv, tuple(teardown_ready_files), deadline, "teardown"
                )
                second_signal_at = time.monotonic()
                os.kill(proc.pid, second_signal)
            try:
                stdout, stderr = proc.communicate(
                    timeout=max(0.0, deadline - time.monotonic())
                )
            except subprocess.TimeoutExpired:
                self.kill_group(proc)
                stdout, stderr = proc.communicate()
                raise ScenarioError(
                    f"mtest did not exit within {timeout}s after signal "
                    f"{signal_number}: {argv}\n{stdout}\n{stderr}"
                )
            exited_at = time.monotonic()
        except BaseException:
            # The armed actors live in process groups of their own, which
            # `kill_group` cannot reach. Recover whatever ids they managed to
            # record — a barrier that expired half-armed still leaves a live
            # child — so no failure path can strand a process on the host.
            self._sweep_owned_groups(
                owned_pgids or self._recover_owned_pgids(owned_pgid_files)
            )
            raise
        finally:
            if proc.poll() is None:
                self.kill_group(proc)
        if signal_number == signal.SIGKILL:
            # mtest cannot clean up after its own death, and its children live in
            # their own process groups, so the harness owns this teardown — after
            # the run's evidence is already on disk.
            self._sweep_owned_groups(owned_pgids)
            for owned in owned_pgids:
                expect_group_gone(owned, "child group orphaned by SIGKILL")
        else:
            try:
                for owned in owned_pgids:
                    expect_group_gone(owned, "child group mtest owned")
            except ScenarioError:
                self._sweep_owned_groups(owned_pgids)
                raise
        return (
            Run(
                argv=argv,
                returncode=proc.returncode,
                stdout=stdout,
                stderr=stderr,
                wall=time.monotonic() - start,
                pgid=pgid,
                second_signal_wall=(
                    None if second_signal_at is None else exited_at - second_signal_at
                ),
            ),
            pgid,
        )

    @staticmethod
    def _wait_out(until: float) -> None:
        """Sleep until one absolute monotonic instant."""
        remaining = until - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)

    def _await_barrier(
        self,
        proc: subprocess.Popen,
        argv: list[str],
        paths: tuple[str, ...],
        deadline: float,
        what: str,
    ) -> None:
        """Wait until every barrier path exists, or fail at the deadline.

        A barrier that merely stops waiting is worse than none: the scenario
        would silently degrade to a weaker case while every later assertion still
        passed. So the expiry is a hard failure, and a run that ends before the
        barrier is one too.

        Args:
            proc: The live mtest process, watched so an early exit fails fast.
            argv: The full argv, for the failure message.
            paths: Every path that must exist before the barrier is satisfied.
            deadline: The absolute monotonic instant the barrier expires at.
            what: Barrier name for the failure message.

        Raises:
            ScenarioError: If mtest exits first or the deadline expires.
        """
        while True:
            missing = [path for path in paths if not os.path.exists(path)]
            if not missing:
                return
            if proc.poll() is not None:
                stdout, stderr = proc.communicate()
                raise ScenarioError(
                    f"mtest exited {proc.returncode} before its {what} barrier "
                    f"was reached (missing {missing}): {argv}\n{stdout}\n{stderr}"
                )
            if time.monotonic() >= deadline:
                self.kill_group(proc)
                stdout, stderr = proc.communicate()
                raise ScenarioError(
                    f"the {what} barrier never appeared (missing {missing}) "
                    f"before the deadline: {argv}\n{stdout}\n{stderr}"
                )
            time.sleep(BARRIER_POLL_SECONDS)

    @staticmethod
    def _read_owned_pgids(owned_pgid_files: tuple[str, ...]) -> list[int]:
        """Read the real PGIDs live actors recorded for themselves.

        Args:
            owned_pgid_files: Paths each holding one decimal process-group id.

        Returns:
            The recorded ids, in the order the paths were given.

        Raises:
            ScenarioError: If a file does not hold a positive decimal id.
        """
        recorded: list[int] = []
        for path in owned_pgid_files:
            raw = Path(path).read_text(encoding="utf-8").strip()
            try:
                value = int(raw)
            except ValueError:
                raise ScenarioError(
                    f"actor pgid file {path} held {raw!r}, not a decimal pgid"
                ) from None
            if value <= 0:
                raise ScenarioError(f"actor pgid file {path} held {value}")
            recorded.append(value)
        return recorded

    @staticmethod
    def _recover_owned_pgids(owned_pgid_files: tuple[str, ...]) -> list[int]:
        """Best-effort read of the PGIDs actors recorded, for a failing path.

        Unlike `_read_owned_pgids` this never raises and never insists the set is
        complete: it exists so a half-armed run — one actor live, the barrier
        expired on another — still has its live group swept rather than left on
        the host.

        Args:
            owned_pgid_files: Paths that MAY each hold one decimal pgid.

        Returns:
            Every id that was actually recorded and parses.
        """
        recovered: list[int] = []
        for path in owned_pgid_files:
            try:
                value = int(Path(path).read_text(encoding="utf-8").strip())
            except (OSError, ValueError):
                continue
            if value > 0:
                recovered.append(value)
        return recovered

    @staticmethod
    def _sweep_owned_groups(owned_pgids: list[int]) -> None:
        """Terminate, then kill, every recorded child process group.

        Two passes with a wait after each, mirroring the product's own
        terminate-then-kill protocol: firing both signals and returning would
        leave the caller unable to tell a swept group from one still being
        reaped. Silent and bounded — every caller either raises its own failure
        around this or states the outcome with `expect_group_gone`.

        Args:
            owned_pgids: The process-group ids to tear down.
        """
        for owned in owned_pgids:
            for sig, budget in (
                (signal.SIGTERM, GROUP_TERM_SECONDS),
                (signal.SIGKILL, GROUP_EXIT_DEADLINE),
            ):
                try:
                    os.killpg(owned, sig)
                except (ProcessLookupError, PermissionError):
                    break
                limit = time.monotonic() + budget
                while group_alive(owned) and time.monotonic() < limit:
                    time.sleep(BARRIER_POLL_SECONDS)
                if not group_alive(owned):
                    break

    def run_mtest_split_pty(
        self,
        args: list[str],
        *,
        env_overrides: dict[str, str | None] | None = None,
        timeout: float | None = None,
    ) -> tuple[int, bytes, bytes]:
        """Capture stdout by pipe and stderr by PTY under one hard deadline."""
        binary = os.fspath(self.mtest)
        if not os.path.exists(binary):
            raise ScenarioError(
                f"binary not found at {binary}; run `pixi run build-bin`"
            )
        argv = [binary, *args]
        env = dict(os.environ)
        env["GITHUB_ACTIONS"] = ""
        if env_overrides:
            for key, value in env_overrides.items():
                if value is None:
                    env.pop(key, None)
                else:
                    env[key] = value
        wall_limit = self.short_timeout if timeout is None else timeout
        stdout_read, stdout_write = os.pipe()
        stderr_master, stderr_slave = pty.openpty()
        proc = subprocess.Popen(
            argv,
            cwd=os.fspath(self.repo_root),
            stdout=stdout_write,
            stderr=stderr_slave,
            env=env,
            start_new_session=True,
        )
        os.close(stdout_write)
        os.close(stderr_slave)
        stdout = bytearray()
        stderr = bytearray()
        deadline = time.monotonic() + wall_limit
        open_fds = {stdout_read, stderr_master}
        try:
            while open_fds:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self.kill_group(proc)
                    proc.wait(timeout=5)
                    raise ScenarioError(
                        f"mtest did not return within {wall_limit}s for argv "
                        f"{argv} with split PTY capture"
                    )
                ready, _, _ = select.select(list(open_fds), [], [], remaining)
                for fd in ready:
                    try:
                        chunk = os.read(fd, 4096)
                    except OSError:
                        chunk = b""
                    if not chunk:
                        open_fds.discard(fd)
                        continue
                    (stdout if fd == stdout_read else stderr).extend(chunk)
        finally:
            os.close(stdout_read)
            os.close(stderr_master)
        try:
            returncode = proc.wait(
                timeout=max(0.0, deadline - time.monotonic())
            )
        except subprocess.TimeoutExpired:
            self.kill_group(proc)
            proc.wait(timeout=5)
            raise ScenarioError(
                f"mtest closed split capture streams but never exited for argv "
                f"{argv}"
            )
        return returncode, bytes(stdout), bytes(stderr)

    def run_mtest_dead_pipe(
        self,
        args: list[str],
        *,
        read_size: int,
        timeout: float | None = None,
    ) -> tuple[int, bytes, int]:
        """Close mtest's captured stdout early and guard its process group."""
        binary = os.fspath(self.mtest)
        if not os.path.exists(binary):
            raise ScenarioError(
                f"binary not found at {binary}; run `pixi run build-bin`"
            )
        argv = [binary, *args]
        env = dict(os.environ)
        env["GITHUB_ACTIONS"] = ""
        wall_limit = self.default_timeout if timeout is None else timeout
        proc = subprocess.Popen(
            argv,
            cwd=os.fspath(self.repo_root),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            env=env,
        )
        pgid = os.getpgid(proc.pid)
        deadline = time.monotonic() + wall_limit
        captured = bytearray()
        try:
            assert proc.stdout is not None
            stdout_fd = proc.stdout.fileno()
            while len(captured) < read_size:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self.kill_group(proc)
                    proc.wait(timeout=5)
                    raise ScenarioError(
                        f"mtest produced fewer than {read_size} bytes before "
                        f"the {wall_limit}s dead-pipe deadline"
                    )
                ready, _, _ = select.select([stdout_fd], [], [], remaining)
                if not ready:
                    continue
                chunk = os.read(stdout_fd, read_size - len(captured))
                if not chunk:
                    break
                captured.extend(chunk)
            proc.stdout.close()
            try:
                returncode = proc.wait(
                    timeout=max(0.0, deadline - time.monotonic())
                )
            except subprocess.TimeoutExpired:
                self.kill_group(proc)
                proc.wait(timeout=5)
                raise ScenarioError(
                    f"mtest did not exit after its stdout pipe closed: {argv}"
                )
        finally:
            if proc.poll() is None:
                self.kill_group(proc)
        return returncode, bytes(captured), pgid

    @staticmethod
    def kill_group(proc: subprocess.Popen) -> None:
        """Terminate, then kill, the process group containing ``proc``.

        Darwin excludes zombies when it iterates process-group members, then
        reports EPERM once only terminal members remain, where Linux reports
        ESRCH. Both mean the group is gone, so both end the sweep. Treating
        EPERM as fatal here raised `PermissionError` out of a cleanup path and
        replaced the caller's own diagnosis — the timeout or stream failure that
        made cleanup necessary — with an unrelated escaped exception.
        """
        try:
            pgid = os.getpgid(proc.pid)
        except ProcessLookupError:
            return
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(pgid, sig)
            except (ProcessLookupError, PermissionError):
                return
            time.sleep(0.3)


Scenario = Callable[["ScenarioContext"], str]
ScenarioRegistry = tuple[tuple[str, Scenario], ...]


@dataclass(frozen=True)
class ScenarioContext:
    """Immutable access to one run's manifest, runner, and master registry."""

    manifest: dict
    registry: ScenarioRegistry
    runner: E2ERunner = field(default_factory=E2ERunner)


DEFAULT_RUNNER = E2ERunner()


def load_manifest() -> dict:
    """Load the committed E2E manifest."""
    with open(MANIFEST_PATH, encoding="utf-8") as manifest_file:
        return json.load(manifest_file)


def discovered_test_files() -> set[str]:
    """Return every recursively discoverable E2E test path."""
    found: set[str] = set()
    for dirpath, _dirs, files in os.walk(E2E_ROOT):
        for name in files:
            if name.startswith("test_") and name.endswith(".mojo"):
                absolute = os.path.join(dirpath, name)
                found.add(os.path.relpath(absolute, REPO_ROOT))
    return found


def bootstrap_build_bin() -> int | None:
    """Build the runner for a bare invocation under a hard process guard."""
    argv = ["pixi", "run", "build-bin"]
    proc = subprocess.Popen(argv, cwd=REPO_ROOT, start_new_session=True)
    try:
        proc.communicate(timeout=BUILD_BIN_TIMEOUT)
    except subprocess.TimeoutExpired:
        E2ERunner.kill_group(proc)
        proc.communicate()
        print(
            f"FATAL: `pixi run build-bin` did not finish within "
            f"{BUILD_BIN_TIMEOUT:.0f}s — killed its process group "
            "(possible toolchain hang)",
            file=sys.stderr,
        )
        return 1
    if proc.returncode != 0:
        print(f"FATAL: `pixi run build-bin` exited {proc.returncode}", file=sys.stderr)
        return proc.returncode
    return None
