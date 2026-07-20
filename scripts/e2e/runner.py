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
FAKE_RETRY_CRASH_MOJO = os.path.join(
    TOOLCHAIN_FIXTURES, "fake_retry_crash_mojo.py"
)
JSON_TERMINAL_WRITE_FAULT = os.path.join(
    REPO_ROOT, "tests", "native", "e2e_json_terminal_write_fault.c"
)

# These are guards, not performance thresholds. Cold `mojo build` is slow.
DEFAULT_TIMEOUT = 180.0
SHORT_TIMEOUT = 30.0
BUILD_BIN_TIMEOUT = 600.0


class ScenarioError(AssertionError):
    """An expected E2E scenario failure with diagnostic context."""


@dataclass
class Run:
    """Complete captured result from one guarded mtest process."""

    argv: list[str]
    returncode: int
    stdout: str
    stderr: str
    wall: float
    pgid: int | None = None

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
    ) -> Run:
        """Capture one mtest run under a hard whole-process-group deadline."""
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
        delay: float,
        timeout: float,
        env_overrides: dict[str, str] | None = None,
    ) -> tuple[Run, int]:
        """Signal a live mtest process, capture it, and enforce one deadline."""
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
        try:
            time.sleep(delay)
            if proc.poll() is not None:
                stdout, stderr = proc.communicate()
                raise ScenarioError(
                    f"mtest exited before signal {signal_number} could be sent: "
                    f"{argv}\n{stdout}\n{stderr}"
                )
            os.killpg(pgid, signal_number)
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
        finally:
            if proc.poll() is None:
                self.kill_group(proc)
        return (
            Run(
                argv=argv,
                returncode=proc.returncode,
                stdout=stdout,
                stderr=stderr,
                wall=time.monotonic() - start,
                pgid=pgid,
            ),
            pgid,
        )

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
        """Terminate, then kill, the process group containing ``proc``."""
        try:
            pgid = os.getpgid(proc.pid)
        except ProcessLookupError:
            return
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(pgid, sig)
            except ProcessLookupError:
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
