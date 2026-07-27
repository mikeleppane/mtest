#!/usr/bin/env python3
"""Self-tests for the direct-suite subprocess watchdog."""

from __future__ import annotations

import contextlib
import io
import math
import os
from pathlib import Path
import resource
import select
import signal
import subprocess
import sys
import tempfile
import threading
import time
from typing import IO, TYPE_CHECKING, cast, override
from unittest import mock

from scripts.harness import watchdog
from scripts.harness.watchdog import (
    DRAIN_SETTLE_SECONDS,
    TIMEOUT_EXIT_CODE,
    Cancelled,
    Exited,
    HarnessError,
    MarkerRetention,
    Signaled,
    TimedOut,
    run_command,
)


if TYPE_CHECKING:
    from collections.abc import Callable


PYTHON = sys.executable
REPO_ROOT = Path(__file__).resolve().parents[2]
WATCHDOG_COMMAND = [PYTHON, "-m", "scripts.harness.watchdog"]

# One 64 KiB pipe buffer is the capacity a single blocking write can fill; the
# flooding actor writes eight of them before its marker, so an undrained pipe
# would deadlock the child long before it ever reached the line under test.
FLOOD_LINE = "x" * 127 + "\n"
FLOOD_LINE_COUNT = 4096
MARKER_PREFIX = "==> "
FLOOD_MARKERS = (
    "==> tests/unit/test_first.mojo\n",
    "==> tests/unit/test_crashing.mojo\n",
)
# Every flooding case must finish well inside this guard: the longest is the
# timeout case at one second of deadline plus the five-second sweep grace.
FLOOD_GUARD_SECONDS = 30.0
# What a leaked descendant emits after the supervisor has already returned, and
# the supervisor's own verdict that must remain the caller stream's last word.
LATE_LINE = "LATE-DESCENDANT-BYTES\n"
LATE_MARKER = "==> tests/unit/test_never_reached.mojo\n"
VERDICT_LINE = "FAILED: aggregate suite (run exit 1)\n"
# The `select()` descriptor ceiling CPython inherits from FD_SETSIZE. A pipe at
# or above it must still drain, so the probe pads the descriptor table past it.
FD_SELECT_CEILING = 1024
# A caller whose stdout consumer has stopped must not outlive its own SIGTERM.
# The supervisor's bounded work after a signal is the group grace plus the drain
# settle plus the seal, well inside this guard.
BLOCKED_GUARD_SECONDS = 30.0


def _wait_for_paths(paths: tuple[Path, ...], timeout_seconds: float = 3.0) -> None:
    """Wait until every subprocess marker exists or fail with the missing set."""
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if all(path.exists() for path in paths):
            return
        time.sleep(0.01)
    missing = [str(path) for path in paths if not path.exists()]
    raise AssertionError(f"subprocess markers were not created: {missing}")


def _run(
    command: list[str],
    *,
    timeout_seconds: float = 1.0,
    deadline_sentinel: Path | None = None,
    outer_timeout_seconds: float = 15.0,
) -> subprocess.CompletedProcess[str]:
    """Run one disposable process through the watchdog command-line boundary."""
    sentinel_args = []
    if deadline_sentinel is not None:
        sentinel_args = ["--deadline-sentinel", str(deadline_sentinel)]
    return subprocess.run(
        [
            *WATCHDOG_COMMAND,
            "--source",
            "tests/unit/test_watchdog.mojo",
            "--step",
            "run",
            "--timeout-seconds",
            str(timeout_seconds),
            *sentinel_args,
            "--",
            *command,
        ],
        check=False,
        text=True,
        capture_output=True,
        timeout=outer_timeout_seconds,
    )


def test_normal_exit_is_preserved() -> None:
    """A successful suite remains successful."""
    result = _run([PYTHON, "-c", "raise SystemExit(0)"])
    if result.returncode != 0:
        raise AssertionError(f"expected exit 0, got {result.returncode}")


def test_nonzero_exit_is_preserved() -> None:
    """A failing suite's exact ordinary exit code survives the wrapper."""
    result = _run([PYTHON, "-c", "raise SystemExit(37)"])
    if result.returncode != 37:
        raise AssertionError(f"expected exit 37, got {result.returncode}")


def test_signal_death_is_preserved() -> None:
    """A signal death stays a signal rather than a synthesized exit code."""
    result = _run(
        [PYTHON, "-c", "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"]
    )
    if result.returncode != -signal.SIGTERM:
        raise AssertionError(
            f"expected signal {-signal.SIGTERM}, got {result.returncode}"
        )


def test_sigkill_death_is_preserved() -> None:
    """SIGKILL survives the CLI boundary without a disposition error."""
    result = _run(
        [PYTHON, "-c", "import os, signal; os.kill(os.getpid(), signal.SIGKILL)"]
    )
    if result.returncode != -signal.SIGKILL:
        raise AssertionError(
            f"expected signal {-signal.SIGKILL}, got {result.returncode}"
        )


def test_inherited_blocked_sigterm_is_preserved() -> None:
    """The wrapper unmasks SIGTERM before reproducing an inherited mask's death."""
    launcher = (
        "import os, signal, sys; "
        "signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM}); "
        "os.execv(sys.executable, [sys.executable, *sys.argv[1:]])"
    )
    child = (
        "import os, signal; "
        "signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM}); "
        "os.kill(os.getpid(), signal.SIGTERM)"
    )
    result = subprocess.run(
        [
            PYTHON,
            "-c",
            launcher,
            "-m",
            "scripts.harness.watchdog",
            "--source",
            "tests/unit/test_watchdog.mojo",
            "--step",
            "run",
            "--",
            PYTHON,
            "-c",
            child,
        ],
        check=False,
        text=True,
        capture_output=True,
    )
    if result.returncode != -signal.SIGTERM:
        raise AssertionError(
            f"expected blocked-mask signal {-signal.SIGTERM}, got {result.returncode}"
        )


def test_ordinary_exit_124_removes_its_deadline_sentinel() -> None:
    """A child's ordinary 124 remains distinct from a watchdog timeout."""
    with tempfile.TemporaryDirectory(prefix="mtest-watchdog-") as raw_tmp:
        sentinel = Path(raw_tmp) / "deadline-sentinel"
        sentinel.touch()
        result = _run(
            [PYTHON, "-c", "raise SystemExit(124)"],
            deadline_sentinel=sentinel,
        )
        if result.returncode != TIMEOUT_EXIT_CODE:
            raise AssertionError(
                f"expected ordinary exit {TIMEOUT_EXIT_CODE}, got {result.returncode}"
            )
        if sentinel.exists():
            raise AssertionError("ordinary exit 124 left its deadline sentinel behind")


def test_in_process_ordinary_137_is_structured_as_exited() -> None:
    """The in-process seam never infers a signal from 128-plus-N."""
    with tempfile.TemporaryDirectory(prefix="mtest-watchdog-") as raw_tmp:
        sentinel = Path(raw_tmp) / "deadline-sentinel"
        sentinel.touch()
        termination = run_command(
            [PYTHON, "-c", "raise SystemExit(137)"],
            source="tests/unit/test_watchdog.mojo",
            step="run",
            deadline_sentinel=sentinel,
        )
        if termination != Exited(137):
            raise AssertionError(f"expected Exited(137), got {termination!r}")
        if sentinel.exists():
            raise AssertionError("structured ordinary exit left its sentinel")


def test_in_process_signal_is_structured_as_signaled() -> None:
    """A negative wait status becomes Signaled only after successful spawn."""
    with tempfile.TemporaryDirectory(prefix="mtest-watchdog-") as raw_tmp:
        sentinel = Path(raw_tmp) / "deadline-sentinel"
        sentinel.touch()
        termination = run_command(
            [
                PYTHON,
                "-c",
                "import os, signal; os.kill(os.getpid(), signal.SIGTERM)",
            ],
            source="tests/unit/test_watchdog.mojo",
            step="run",
            deadline_sentinel=sentinel,
        )
        if termination != Signaled(signal.SIGTERM):
            raise AssertionError(
                f"expected Signaled({signal.SIGTERM}), got {termination!r}"
            )
        if sentinel.exists():
            raise AssertionError("structured signal result left its sentinel")


def test_invalid_run_command_timeouts_never_spawn_payloads() -> None:
    """Non-finite and over-ceiling direct calls fail before creating a child."""
    for timeout_seconds in (math.nan, math.inf, -math.inf, 901.0):
        with tempfile.TemporaryDirectory(prefix="mtest-watchdog-") as raw_tmp:
            marker = Path(raw_tmp) / "payload-started"
            sentinel = Path(raw_tmp) / "deadline-sentinel"
            sentinel.touch()
            termination = run_command(
                [
                    PYTHON,
                    "-c",
                    (
                        "from pathlib import Path; import sys; "
                        "Path(sys.argv[1]).write_text('started')"
                    ),
                    str(marker),
                ],
                source="tests/unit/test_watchdog.mojo",
                step="run",
                timeout_seconds=timeout_seconds,
                deadline_sentinel=sentinel,
            )
            if not isinstance(termination, HarnessError):
                raise AssertionError(
                    f"timeout {timeout_seconds!r} returned {termination!r}"
                )
            if marker.exists():
                raise AssertionError(f"timeout {timeout_seconds!r} started its payload")
            if sentinel.exists():
                raise AssertionError(f"timeout {timeout_seconds!r} left its sentinel")


def test_parser_rejects_invalid_timeouts_before_payload_start() -> None:
    """CLI timeout values reject NaN, infinities, and values above 900 seconds."""
    for timeout_seconds in ("nan", "inf", "-inf", "901"):
        with tempfile.TemporaryDirectory(prefix="mtest-watchdog-") as raw_tmp:
            marker = Path(raw_tmp) / "payload-started"
            result = _run(
                [
                    PYTHON,
                    "-c",
                    (
                        "from pathlib import Path; import sys; "
                        "Path(sys.argv[1]).write_text('started')"
                    ),
                    str(marker),
                ],
                timeout_seconds=float(timeout_seconds),
            )
            if result.returncode == 0:
                raise AssertionError(f"parser accepted timeout {timeout_seconds!r}")
            if marker.exists():
                raise AssertionError(
                    f"parser started payload for timeout {timeout_seconds!r}"
                )


def test_spawn_failure_is_not_a_timeout() -> None:
    """A missing executable leaves the sentinel without claiming a deadline."""
    with tempfile.TemporaryDirectory(prefix="mtest-watchdog-") as raw_tmp:
        sentinel = Path(raw_tmp) / "deadline-sentinel"
        sentinel.touch()
        result = _run(
            [str(Path(raw_tmp) / "does-not-exist")],
            deadline_sentinel=sentinel,
        )
        if result.returncode != 70:
            raise AssertionError(
                f"spawn failure exited {result.returncode}, expected 70"
            )
        if "exceeded" in result.stderr or "timed out" in result.stderr:
            raise AssertionError(f"spawn failure claimed timeout:\n{result.stderr}")
        if sentinel.exists():
            raise AssertionError("spawn failure left the deadline sentinel")


def test_broken_timeout_diagnostic_leaves_the_deadline_sentinel() -> None:
    """A notification write failure cannot bypass cleanup or make the shell pass."""

    class BrokenStderr:
        """A pipe-like stderr that rejects the watchdog's timeout diagnostic."""

        def write(self, _text: str) -> int:
            raise BrokenPipeError("deliberate watchdog diagnostic failure")

        def flush(self) -> None:
            return None

    with tempfile.TemporaryDirectory(prefix="mtest-watchdog-") as raw_tmp:
        sentinel = Path(raw_tmp) / "deadline-sentinel"
        sentinel.touch()
        original_stderr = sys.stderr
        sys.stderr = BrokenStderr()
        try:
            termination = run_command(
                [PYTHON, "-c", "import time; time.sleep(60)"],
                source="tests/unit/test_watchdog.mojo",
                step="run",
                timeout_seconds=0.1,
                deadline_sentinel=sentinel,
            )
        finally:
            sys.stderr = original_stderr
        if not isinstance(termination, TimedOut):
            raise AssertionError(f"expected TimedOut, got {termination!r}")
        if not sentinel.exists():
            raise AssertionError(
                "broken timeout diagnostic cleared the deadline sentinel"
            )


def test_closed_timeout_diagnostic_preserves_the_deadline_result() -> None:
    """A closed stderr cannot replace a proven timeout with an internal error."""

    class ClosedStderr:
        """A stderr stand-in with the error produced by a closed text stream."""

        def write(self, _text: str) -> int:
            raise ValueError("I/O operation on closed file")

        def flush(self) -> None:
            return None

    with tempfile.TemporaryDirectory(prefix="mtest-watchdog-") as raw_tmp:
        sentinel = Path(raw_tmp) / "deadline-sentinel"
        sentinel.touch()
        original_stderr = sys.stderr
        sys.stderr = ClosedStderr()
        try:
            termination = run_command(
                [PYTHON, "-c", "import time; time.sleep(60)"],
                source="tests/unit/test_watchdog.mojo",
                step="run",
                timeout_seconds=0.1,
                deadline_sentinel=sentinel,
            )
        finally:
            sys.stderr = original_stderr
        if not isinstance(termination, TimedOut):
            raise AssertionError(f"expected TimedOut, got {termination!r}")
        if not sentinel.exists():
            raise AssertionError("closed timeout diagnostic cleared deadline proof")


def test_timeout_terminates_the_whole_process_group() -> None:
    """A timeout kills a suite's escaped descendant and reaps its leader."""
    with tempfile.TemporaryDirectory(prefix="mtest-watchdog-") as raw_tmp:
        tmp = Path(raw_tmp)
        ready = tmp / "descendant-ready"
        marker = tmp / "escaped-child-survived"
        deadline_sentinel = tmp / "deadline-sentinel"
        deadline_sentinel.touch()
        grandchild = tmp / "grandchild.py"
        child = tmp / "parent.py"
        grandchild.write_text(
            "from pathlib import Path\n"
            "import signal\n"
            "import sys\n"
            "import time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "Path(sys.argv[1]).write_text('ready')\n"
            "time.sleep(6.0)\n"
            "Path(sys.argv[2]).write_text('survived')",
            encoding="utf-8",
        )
        child.write_text(
            "import subprocess\n"
            "import sys\n"
            "import time\n"
            "ready, marker, grandchild = sys.argv[1:]\n"
            "subprocess.Popen([sys.executable, grandchild, ready, marker])\n"
            "while not __import__('pathlib').Path(ready).exists():\n"
            "    time.sleep(0.01)\n"
            "time.sleep(60)",
            encoding="utf-8",
        )
        result = _run(
            [PYTHON, str(child), str(ready), str(marker), str(grandchild)],
            timeout_seconds=0.4,
            deadline_sentinel=deadline_sentinel,
            outer_timeout_seconds=12.0,
        )
        if result.returncode != TIMEOUT_EXIT_CODE:
            raise AssertionError(
                f"expected timeout exit {TIMEOUT_EXIT_CODE}, got {result.returncode}"
            )
        diagnostic = result.stderr
        if (
            "tests/unit/test_watchdog.mojo" not in diagnostic
            or ": run " not in diagnostic
        ):
            raise AssertionError(
                f"timeout diagnostic lost its source or step: {diagnostic}"
            )
        if not deadline_sentinel.exists():
            raise AssertionError("actual timeout removed its deadline sentinel")
        if not ready.exists():
            raise AssertionError(
                "timeout raced before the SIGTERM-ignoring child was ready"
            )
        # `_run` captures the watchdog's inherited stdout/stderr. It cannot
        # return until the descendant closes those inherited pipe ends; then
        # this delayed marker separately proves the descendant did not survive
        # long enough to resume after the group sweep.
        time.sleep(1.0)
        if marker.exists():
            raise AssertionError("timeout let the descendant finish after cleanup")


def _assert_cancellation_reaches_process_group(
    signum: int,
    *,
    followup_signum: int | None = None,
) -> None:
    """A caller cancellation reaches the leader and its inherited group."""
    with tempfile.TemporaryDirectory(prefix="mtest-watchdog-") as raw_tmp:
        tmp = Path(raw_tmp)
        leader_ready = tmp / "leader-ready"
        descendant_ready = tmp / "descendant-ready"
        leader_signal = tmp / "leader-signal"
        descendant_signal = tmp / "descendant-signal"
        leader_pid = tmp / "leader-pid"
        deadline_sentinel = tmp / "deadline-sentinel"
        deadline_sentinel.touch()
        actor = tmp / "signal_actor.py"
        actor.write_text(
            "from pathlib import Path\n"
            "import os\n"
            "import signal\n"
            "import subprocess\n"
            "import sys\n"
            "import time\n"
            "role, ready, received, child_ready, child_received = sys.argv[1:6]\n"
            "signum = int(sys.argv[6])\n"
            "linger_after_signal = sys.argv[8] == 'linger'\n"
            "def handle(actual, _frame):\n"
            "    Path(received).write_text(str(actual))\n"
            "    if linger_after_signal:\n"
            "        return\n"
            "    raise SystemExit(0)\n"
            "signal.signal(signum, handle)\n"
            "if role == 'leader':\n"
            "    Path(sys.argv[7]).write_text(str(os.getpid()))\n"
            "    subprocess.Popen([sys.executable, __file__, 'descendant', "
            "child_ready, child_received, '', '', str(signum), '', "
            "sys.argv[8]])\n"
            "Path(ready).write_text('ready')\n"
            "time.sleep(60)",
            encoding="utf-8",
        )
        watchdog_args = [
            "--source",
            "tests/unit/test_watchdog.mojo",
            "--step",
            "run",
            "--deadline-sentinel",
            str(deadline_sentinel),
            "--",
            PYTHON,
            str(actor),
            "leader",
            str(leader_ready),
            str(leader_signal),
            str(descendant_ready),
            str(descendant_signal),
            str(signum),
            str(leader_pid),
            "linger" if followup_signum is not None else "exit",
        ]
        command = [*WATCHDOG_COMMAND, *watchdog_args]
        watchdog = subprocess.Popen(
            command,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            _wait_for_paths((leader_ready, descendant_ready, leader_pid))
            os.kill(watchdog.pid, signum)
            if followup_signum is not None:
                _wait_for_paths((leader_signal, descendant_signal))
                os.kill(watchdog.pid, followup_signum)
            status = watchdog.wait(timeout=8.0)
            if status != -signum:
                raise AssertionError(
                    f"expected watchdog signal {-signum}, got {status}"
                )
            _wait_for_paths((leader_signal, descendant_signal))
            for received in (leader_signal, descendant_signal):
                actual = received.read_text(encoding="utf-8")
                if actual != str(signum):
                    raise AssertionError(
                        f"process-group member received {actual}, expected {signum}"
                    )
            if followup_signum is not None:
                group_deadline = time.monotonic() + 2.0
                while True:
                    try:
                        os.killpg(
                            int(leader_pid.read_text(encoding="utf-8")),
                            0,
                        )
                    except ProcessLookupError:
                        break
                    if time.monotonic() >= group_deadline:
                        raise AssertionError(
                            "double cancellation left the child group alive"
                        )
                    time.sleep(0.01)
            if deadline_sentinel.exists():
                raise AssertionError("cancellation left the deadline sentinel")
            if watchdog.stderr is None:
                raise AssertionError("the watchdog was spawned without a stderr pipe")
            diagnostic = watchdog.stderr.read()
            if "Traceback" in diagnostic:
                raise AssertionError(
                    f"double cancellation escaped watchdog cleanup:\n{diagnostic}"
                )
        finally:
            if watchdog.poll() is None:
                watchdog.kill()
                watchdog.wait()
            if leader_pid.exists():
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(
                        int(leader_pid.read_text(encoding="utf-8")), signal.SIGKILL
                    )


def test_sigterm_is_forwarded_to_the_process_group() -> None:
    """SIGTERM cancellation is preserved and forwarded to every child."""
    _assert_cancellation_reaches_process_group(signal.SIGTERM)


def test_sigint_is_forwarded_to_the_process_group() -> None:
    """SIGINT cancellation is preserved and forwarded to every child."""
    _assert_cancellation_reaches_process_group(signal.SIGINT)


def test_first_signal_wins_during_forced_cleanup() -> None:
    """A follow-up signal during forced cleanup cannot replace the first."""
    _assert_cancellation_reaches_process_group(
        signal.SIGTERM,
        followup_signum=signal.SIGINT,
    )


def test_cancellation_wins_when_spawn_then_raises() -> None:
    """A signal delivered inside a failing spawn remains the terminal status."""
    with tempfile.TemporaryDirectory(prefix="mtest-watchdog-") as raw_tmp:
        tmp = Path(raw_tmp)
        sentinel = tmp / "deadline-sentinel"
        sentinel.touch()
        wrapper = tmp / "cancelled_spawn_watchdog.py"
        wrapper.write_text(
            "import os\n"
            "import signal\n"
            "import sys\n"
            "sys.path.insert(0, sys.argv[1])\n"
            "from scripts.harness import watchdog\n"
            "def cancelled_spawn(*_args, **_kwargs):\n"
            "    os.kill(os.getpid(), signal.SIGTERM)\n"
            "    raise FileNotFoundError('injected spawn failure')\n"
            "watchdog.subprocess.Popen = cancelled_spawn\n"
            "raise SystemExit(watchdog.main(sys.argv[2:]))",
            encoding="utf-8",
        )
        result = subprocess.run(
            [
                PYTHON,
                str(wrapper),
                str(REPO_ROOT),
                "--source",
                "tests/unit/test_watchdog.mojo",
                "--step",
                "run",
                "--deadline-sentinel",
                str(sentinel),
                "--",
                PYTHON,
                "-c",
                "raise SystemExit(0)",
            ],
            check=False,
            text=True,
            capture_output=True,
            timeout=5.0,
        )
        if result.returncode != -signal.SIGTERM:
            raise AssertionError(
                "expected cancellation to outrank spawn failure, got "
                f"{result.returncode}:\n{result.stderr}"
            )
        if "Traceback" in result.stderr:
            raise AssertionError(f"spawn cancellation escaped:\n{result.stderr}")
        if sentinel.exists():
            raise AssertionError("spawn cancellation left the deadline sentinel")


class _TextOverBytes:
    """A stdout/stderr stand-in exposing the byte buffer the watchdog tees to."""

    def __init__(self, handle: IO[bytes]) -> None:
        self.buffer = handle

    def write(self, text: str) -> int:
        """Encode one diagnostic string onto the captured byte buffer."""
        return self.buffer.write(text.encode("utf-8"))

    def flush(self) -> None:
        """Flush the captured byte buffer."""
        self.buffer.flush()


def _flooding_marker_actor(tmp: Path) -> Path:
    """Write an actor that floods past the pipe capacity before its markers."""
    actor = tmp / "flooding_marker_actor.py"
    actor.write_text(
        "\n".join(
            [
                "import os",
                "import signal",
                "import sys",
                "import time",
                "mode = sys.argv[1]",
                f"sys.stdout.write({FLOOD_LINE!r} * {FLOOD_LINE_COUNT})",
                f"sys.stdout.write({FLOOD_MARKERS[0]!r})",
                f"sys.stdout.write({FLOOD_MARKERS[1]!r})",
                "sys.stdout.flush()",
                "if mode == 'ordinary':",
                "    raise SystemExit(5)",
                "if mode == 'signal':",
                "    os.kill(os.getpid(), signal.SIGTERM)",
                "time.sleep(60)",
            ]
        ),
        encoding="utf-8",
    )
    return actor


def test_flooding_child_is_drained_teed_and_marked() -> None:
    """Every ending drains the flood, tees it whole, and keeps the last marker."""
    expected_terminations = {
        "ordinary": Exited(5),
        "signal": Signaled(signal.SIGTERM),
        "timeout": TimedOut(),
    }
    expected_output = (
        FLOOD_LINE * FLOOD_LINE_COUNT + FLOOD_MARKERS[0] + FLOOD_MARKERS[1]
    ).encode("utf-8")
    for mode, expected in expected_terminations.items():
        with tempfile.TemporaryDirectory(prefix="mtest-watchdog-flood-") as raw_tmp:
            tmp = Path(raw_tmp)
            actor = _flooding_marker_actor(tmp)
            sentinel = tmp / "deadline-sentinel"
            sentinel.touch()
            retention = MarkerRetention(MARKER_PREFIX)
            teed = tmp / "teed-stdout"
            diagnostics = tmp / "teed-stderr"
            original_stdout = sys.stdout
            original_stderr = sys.stderr
            started = time.monotonic()
            with (
                teed.open("wb") as stdout_handle,
                diagnostics.open("wb") as stderr_handle,
            ):
                sys.stdout = _TextOverBytes(stdout_handle)
                sys.stderr = _TextOverBytes(stderr_handle)
                try:
                    termination = run_command(
                        [PYTHON, str(actor), mode],
                        source="tests/unit/test_watchdog.mojo",
                        step="run",
                        timeout_seconds=1.0,
                        deadline_sentinel=sentinel,
                        marker_retention=retention,
                    )
                finally:
                    sys.stdout = original_stdout
                    sys.stderr = original_stderr
            elapsed = time.monotonic() - started
            if termination != expected:
                raise AssertionError(
                    f"flooding {mode} returned {termination!r}, expected {expected!r}"
                )
            if elapsed >= FLOOD_GUARD_SECONDS:
                raise AssertionError(
                    f"flooding {mode} took {elapsed:.1f}s, past the outer guard"
                )
            actual = teed.read_bytes()
            if actual != expected_output:
                raise AssertionError(
                    f"flooding {mode} teed {len(actual)} bytes, "
                    f"expected {len(expected_output)}"
                )
            if retention.text != FLOOD_MARKERS[1]:
                raise AssertionError(
                    f"flooding {mode} retained {retention.text!r}, "
                    f"expected {FLOOD_MARKERS[1]!r}"
                )


def _retaining_watchdog_argv(
    tmp: Path, sentinel: Path, *, timeout_seconds: float
) -> list[str]:
    """Return argv for a supervisor process that captures its child's marker.

    The watchdog's own command line never opts into capture, so a test that
    needs to signal a capturing supervisor drives `run_command` through this
    thin wrapper instead.

    Args:
        tmp: Directory the wrapper source is written into.
        sentinel: Deadline sentinel the supervised step must reconcile.
        timeout_seconds: Wall-clock ceiling handed to the supervised step.

    Returns:
        The argv prefix; append the supervised command to it.
    """
    wrapper = tmp / "retaining_watchdog.py"
    wrapper.write_text(
        "from pathlib import Path\n"
        "import sys\n"
        "sys.path.insert(0, sys.argv[1])\n"
        "from scripts.harness import watchdog\n"
        "retention = watchdog.MarkerRetention(sys.argv[2])\n"
        "termination = watchdog.run_command(\n"
        "    sys.argv[5:],\n"
        "    source='tests/unit/test_watchdog.mojo',\n"
        "    step='run',\n"
        "    timeout_seconds=float(sys.argv[4]),\n"
        "    deadline_sentinel=Path(sys.argv[3]),\n"
        "    marker_retention=retention,\n"
        ")\n"
        "raise SystemExit(watchdog._exit_with_termination(termination))",
        encoding="utf-8",
    )
    return [
        PYTHON,
        str(wrapper),
        str(REPO_ROOT),
        MARKER_PREFIX,
        str(sentinel),
        str(timeout_seconds),
    ]


def test_a_blocked_caller_stream_cannot_swallow_a_caller_signal() -> None:
    """A caller stdout nobody drains must never make the supervisor unkillable."""
    with tempfile.TemporaryDirectory(prefix="mtest-watchdog-block-") as raw_tmp:
        tmp = Path(raw_tmp)
        sentinel = tmp / "deadline-sentinel"
        sentinel.touch()
        ready = tmp / "child-ready"
        actor = tmp / "blocked_consumer_actor.py"
        actor.write_text(
            "\n".join(
                [
                    "from pathlib import Path",
                    "import sys",
                    "import time",
                    "Path(sys.argv[1]).write_text('ready')",
                    f"sys.stdout.write({FLOOD_LINE!r} * {FLOOD_LINE_COUNT})",
                    "sys.stdout.flush()",
                    "time.sleep(120)",
                ]
            ),
            encoding="utf-8",
        )
        supervisor = subprocess.Popen(
            [
                *_retaining_watchdog_argv(tmp, sentinel, timeout_seconds=120.0),
                PYTHON,
                str(actor),
                str(ready),
            ],
            # Deliberately never read: this is a caller whose own stdout consumer
            # has stopped, which is what terminal flow control looks like.
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        status: int | None = None
        diagnostic = b""
        try:
            _wait_for_paths((ready,))
            # Let both the child's pipe and the unread caller pipe fill, so the
            # stdout drainer is parked inside a write that will never return.
            time.sleep(1.0)
            os.kill(supervisor.pid, signal.SIGTERM)
            try:
                status = supervisor.wait(timeout=BLOCKED_GUARD_SECONDS)
            except subprocess.TimeoutExpired:
                status = None
        finally:
            if supervisor.poll() is None:
                supervisor.kill()
                supervisor.wait()
            if supervisor.stderr is None:
                raise AssertionError("the supervisor was spawned without a stderr pipe")
            diagnostic = supervisor.stderr.read()
            for stream in (supervisor.stdout, supervisor.stderr):
                if stream is not None:
                    stream.close()
        if status is None:
            raise AssertionError(
                "a blocked caller stream made the supervisor unkillable: it "
                f"outlived SIGTERM by {BLOCKED_GUARD_SECONDS:g}s"
            )
        if status != -signal.SIGTERM:
            raise AssertionError(
                f"blocked caller stream exited {status}, "
                f"expected {-signal.SIGTERM}:\n{diagnostic.decode(errors='replace')}"
            )
        if b"Traceback" in diagnostic:
            raise AssertionError(
                "blocked caller stream escaped cleanup:\n"
                f"{diagnostic.decode(errors='replace')}"
            )


def test_high_numbered_pipe_descriptors_do_not_lose_output() -> None:
    """A pipe above the select() ceiling drains instead of vanishing silently."""
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    ceiling = FD_SELECT_CEILING + 32
    if hard != resource.RLIM_INFINITY and hard < ceiling:
        raise AssertionError(
            f"harness cannot raise RLIMIT_NOFILE to {ceiling}: hard limit {hard}"
        )
    padding: list[int] = []
    resource.setrlimit(resource.RLIMIT_NOFILE, (ceiling, hard))
    try:
        while True:
            descriptor = os.open(os.devnull, os.O_RDONLY)
            padding.append(descriptor)
            if descriptor >= FD_SELECT_CEILING:
                break
        with tempfile.TemporaryDirectory(prefix="mtest-watchdog-highfd-") as raw:
            tmp = Path(raw)
            sentinel = tmp / "deadline-sentinel"
            sentinel.touch()
            retention = MarkerRetention(MARKER_PREFIX)
            teed = tmp / "teed-stdout"
            expected = (FLOOD_LINE * FLOOD_LINE_COUNT + FLOOD_MARKERS[1]).encode(
                "utf-8"
            )
            original_stdout = sys.stdout
            with teed.open("wb") as handle:
                sys.stdout = _TextOverBytes(handle)
                try:
                    termination = run_command(
                        [
                            PYTHON,
                            "-c",
                            (
                                "import sys; "
                                f"sys.stdout.write({FLOOD_LINE!r} * "
                                f"{FLOOD_LINE_COUNT}); "
                                f"sys.stdout.write({FLOOD_MARKERS[1]!r})"
                            ),
                        ],
                        source="tests/unit/test_watchdog.mojo",
                        step="run",
                        timeout_seconds=30.0,
                        deadline_sentinel=sentinel,
                        marker_retention=retention,
                    )
                finally:
                    sys.stdout = original_stdout
            if termination != Exited(0):
                raise AssertionError(f"high-fd child returned {termination!r}")
            actual = teed.read_bytes()
            if actual != expected:
                raise AssertionError(
                    f"high-fd drain teed {len(actual)} bytes, expected {len(expected)}"
                )
            if retention.text != FLOOD_MARKERS[1]:
                raise AssertionError(
                    f"high-fd drain retained {retention.text!r}, "
                    f"expected {FLOOD_MARKERS[1]!r}"
                )
    finally:
        for descriptor in padding:
            os.close(descriptor)
        resource.setrlimit(resource.RLIMIT_NOFILE, (soft, hard))


def test_a_frozen_marker_capture_refuses_later_writes() -> None:
    """Freezing the capture ends the drainer's claim on the retained marker."""
    retention = MarkerRetention(MARKER_PREFIX)
    retention.record(FLOOD_MARKERS[0])
    retention.record(FLOOD_MARKERS[1])
    if retention.text != FLOOD_MARKERS[1]:
        raise AssertionError(
            f"open capture retained {retention.text!r}, expected {FLOOD_MARKERS[1]!r}"
        )
    retention.freeze()
    retention.record(LATE_MARKER)
    if retention.text != FLOOD_MARKERS[1]:
        raise AssertionError(
            f"frozen capture accepted a later marker: {retention.text!r}"
        )


def test_the_seal_freezes_the_capture_before_it_seals_any_tee() -> None:
    """Order matters: a tee sealed first can drop bytes whose marker still lands.

    A drainer already past its stop check reads one more chunk. If the tees are
    sealed before the capture is frozen, that chunk's bytes are dropped from
    the caller's stream while its marker is still recorded, and the run reports
    a last module the user never saw. The window widens to the seal's bounded
    acquire whenever an earlier tee's seal has to wait out a write in flight,
    so the ordering is asserted directly rather than raced for.
    """
    order: list[str] = []

    class _OrderingTee(watchdog._StreamTee):
        @override
        def seal(self) -> bool:
            order.append("seal")
            return super().seal()

    class _OrderingRetention(MarkerRetention):
        @override
        def freeze(self) -> None:
            order.append("freeze")
            super().freeze()

    state = watchdog._DrainState(
        threads=(),
        tees=(_OrderingTee(io.StringIO()), _OrderingTee(io.StringIO())),
        stop=threading.Event(),
        retention=_OrderingRetention(MARKER_PREFIX),
        sources=(),
    )
    watchdog._seal_drainers(state)
    if order != ["freeze", "seal", "seal"]:
        raise AssertionError(f"seal ordering was {order}, expected the freeze first")
    if not state.stop.is_set():
        raise AssertionError("sealing left the drainers' stop flag clear")


def test_a_drainer_cannot_write_through_a_frozen_capture() -> None:
    """The drain site records through the capture, so a freeze really binds it."""
    read_descriptor, write_descriptor = os.pipe()
    os.write(write_descriptor, LATE_MARKER.encode("utf-8"))
    os.close(write_descriptor)
    retention = MarkerRetention(MARKER_PREFIX)
    retention.record(FLOOD_MARKERS[1])
    retention.freeze()
    sink = io.StringIO()
    with os.fdopen(read_descriptor, "rb") as source:
        watchdog._tee_stream(
            source,
            watchdog._StreamTee(sink),
            retention,
            threading.Event(),
        )
    if sink.getvalue() != LATE_MARKER:
        raise AssertionError(f"the drain lost its tee: {sink.getvalue()!r}")
    if retention.text != FLOOD_MARKERS[1]:
        raise AssertionError(
            f"a drainer wrote through a frozen capture: {retention.text!r}"
        )


def test_a_cancelled_timeout_settle_seals_before_the_timeout_diagnostic() -> None:
    """Aborting the timeout drain must not leave a tee live past the FATAL line."""
    with tempfile.TemporaryDirectory(prefix="mtest-watchdog-tmoseal-") as raw_tmp:
        tmp = Path(raw_tmp)
        sentinel = tmp / "deadline-sentinel"
        sentinel.touch()
        retention = MarkerRetention(MARKER_PREFIX)
        states: list[watchdog._DrainState] = []
        sealed_at_diagnostic: list[bool] = []
        original_prepare = watchdog._prepare_drainers
        original_settle = watchdog._settle_drainers
        original_notify = watchdog._notify_timeout

        def recording_prepare(
            process: subprocess.Popen[bytes], retention: MarkerRetention
        ) -> watchdog._DrainState:
            """Capture the live drainers so the diagnostic can be inspected."""
            state = original_prepare(process, retention)
            states.append(state)
            return state

        def cancelling_settle(
            # ARG001: the name and type must match `_settle_drainers` for this
            # stand-in to be a type-compatible replacement for it.
            state: watchdog._DrainState | None,  # noqa: ARG001
        ) -> None:
            """Stand in for a caller signal delivered inside the drain settle."""
            raise watchdog._WatchdogCancellation(signal.SIGTERM)

        def observing_notify(source: str, step: str, timeout_seconds: float) -> None:
            """Record whether every tee was already shut when FATAL was printed."""
            sealed_at_diagnostic.append(
                bool(states) and all(tee.sealed for tee in states[-1].tees)
            )
            original_notify(source, step, timeout_seconds)

        watchdog._prepare_drainers = recording_prepare
        watchdog._settle_drainers = cancelling_settle
        watchdog._notify_timeout = observing_notify
        try:
            termination = run_command(
                [PYTHON, "-c", "import time; time.sleep(120)"],
                source="tests/unit/test_watchdog.mojo",
                step="run",
                timeout_seconds=0.2,
                deadline_sentinel=sentinel,
                marker_retention=retention,
            )
        finally:
            watchdog._prepare_drainers = original_prepare
            watchdog._settle_drainers = original_settle
            watchdog._notify_timeout = original_notify
        if not isinstance(termination, TimedOut):
            raise AssertionError(f"cancelled timeout settle returned {termination!r}")
        if sealed_at_diagnostic != [True]:
            raise AssertionError(
                "the timeout diagnostic was printed with a live drainer: "
                f"{sealed_at_diagnostic}"
            )


def test_a_signal_during_timeout_diagnostic_keeps_deadline_precedence() -> None:
    """A proven deadline cannot become cancellation during final reporting."""
    with tempfile.TemporaryDirectory(prefix="mtest-watchdog-tmosignal-") as raw_tmp:
        sentinel = Path(raw_tmp) / "deadline-sentinel"
        sentinel.touch()
        original_notify = watchdog._notify_timeout

        def interrupting_notify(source: str, step: str, timeout_seconds: float) -> None:
            os.kill(os.getpid(), signal.SIGINT)
            original_notify(source, step, timeout_seconds)

        watchdog._notify_timeout = interrupting_notify
        try:
            termination = run_command(
                [PYTHON, "-c", "import time; time.sleep(120)"],
                source="tests/unit/test_watchdog.mojo",
                step="run",
                timeout_seconds=0.2,
                deadline_sentinel=sentinel,
            )
        finally:
            watchdog._notify_timeout = original_notify
        if not isinstance(termination, TimedOut):
            raise AssertionError(f"signal changed proven timeout into {termination!r}")
        if not sentinel.exists():
            raise AssertionError("signal during timeout removed deadline proof")


def test_partial_drainer_start_is_published_before_cancellation() -> None:
    """A signal between thread starts still seals the published drain state."""
    retention = MarkerRetention(MARKER_PREFIX)
    started_threads: list[threading.Thread] = []
    original_start = watchdog._start_drainers

    def cancelling_start(state: watchdog._DrainState) -> None:
        thread = state.threads[0]
        thread.start()
        started_threads.append(thread)
        raise watchdog._WatchdogCancellation(signal.SIGINT)

    watchdog._start_drainers = cancelling_start
    try:
        termination = run_command(
            [PYTHON, "-c", "import time; time.sleep(120)"],
            source="tests/unit/test_watchdog.mojo",
            step="run",
            timeout_seconds=10.0,
            marker_retention=retention,
        )
    finally:
        watchdog._start_drainers = original_start
    if termination != Cancelled(signal.SIGINT):
        raise AssertionError(f"partial drainer cancellation returned {termination!r}")
    retention.record(LATE_MARKER)
    if retention.text:
        raise AssertionError("partial drainer state was not frozen before return")
    if retention.capture_complete:
        raise AssertionError("partial drainer start claimed complete capture")
    if any(thread.is_alive() for thread in started_threads):
        raise AssertionError("a partially started drainer outlived cancellation")


def _leaking_actor(tmp: Path) -> Path:
    """Write a leader that leaves a descendant holding the inherited stdout."""
    descendant = tmp / "late_descendant.py"
    descendant.write_text(
        "\n".join(
            [
                "import sys",
                "import time",
                "time.sleep(float(sys.argv[1]))",
                f"sys.stdout.write({LATE_LINE!r})",
                "sys.stdout.flush()",
                "time.sleep(120)",
            ]
        ),
        encoding="utf-8",
    )
    actor = tmp / "leaking_marker_actor.py"
    actor.write_text(
        "\n".join(
            [
                "from pathlib import Path",
                "import subprocess",
                "import sys",
                "import os",
                "leader_done, late_seconds = sys.argv[1], sys.argv[2]",
                "subprocess.Popen(",
                f"    [sys.executable, {str(descendant)!r}, late_seconds]",
                ")",
                f"sys.stdout.write({FLOOD_MARKERS[1]!r})",
                "sys.stdout.flush()",
                "Path(leader_done).write_text(str(os.getpid()))",
                "raise SystemExit(0)",
            ]
        ),
        encoding="utf-8",
    )
    return actor


def _persistent_leaking_actor(tmp: Path) -> Path:
    """Write a leader that leaves one indefinitely sleeping descendant."""
    descendant = tmp / "persistent_descendant.py"
    descendant.write_text(
        "from pathlib import Path\n"
        "import os\n"
        "import sys\n"
        "import time\n"
        "Path(sys.argv[1]).write_text(str(os.getpid()))\n"
        "time.sleep(120)",
        encoding="utf-8",
    )
    actor = tmp / "persistent_leader.py"
    actor.write_text(
        "\n".join(
            [
                "from pathlib import Path",
                "import os",
                "import subprocess",
                "import sys",
                "import time",
                "leader_pid, descendant_pid = sys.argv[1], sys.argv[2]",
                "Path(leader_pid).write_text(str(os.getpid()))",
                "subprocess.Popen(",
                f"    [sys.executable, {str(descendant)!r}, descendant_pid]",
                ")",
                "while not Path(descendant_pid).exists():",
                "    time.sleep(0.01)",
                f"sys.stdout.write({FLOOD_MARKERS[1]!r})",
                "sys.stdout.flush()",
                "raise SystemExit(0)",
            ]
        ),
        encoding="utf-8",
    )
    return actor


def test_leaked_descendant_output_precedes_cleanup_verdict() -> None:
    """Output before the bounded survivor sweep is retained before the verdict."""
    with tempfile.TemporaryDirectory(prefix="mtest-watchdog-leak-") as raw_tmp:
        tmp = Path(raw_tmp)
        actor = _leaking_actor(tmp)
        leader_done = tmp / "leader-done"
        sentinel = tmp / "deadline-sentinel"
        sentinel.touch()
        retention = MarkerRetention(MARKER_PREFIX)
        teed = tmp / "teed-stdout"
        diagnostics = tmp / "teed-stderr"
        original_stdout = sys.stdout
        original_stderr = sys.stderr
        with teed.open("wb") as stdout_handle:
            with diagnostics.open("wb") as stderr_handle:
                sys.stdout = _TextOverBytes(stdout_handle)
                sys.stderr = _TextOverBytes(stderr_handle)
                try:
                    started = time.monotonic()
                    termination = run_command(
                        [
                            PYTHON,
                            str(actor),
                            str(leader_done),
                            "0.1",
                        ],
                        source="tests/unit/test_watchdog.mojo",
                        step="run",
                        timeout_seconds=30.0,
                        deadline_sentinel=sentinel,
                        marker_retention=retention,
                    )
                    elapsed = time.monotonic() - started
                    stdout_handle.write(VERDICT_LINE.encode("utf-8"))
                    stdout_handle.flush()
                finally:
                    sys.stdout = original_stdout
                    sys.stderr = original_stderr
            stdout_handle.flush()
            tail = teed.read_bytes()
        if termination != Exited(0):
            raise AssertionError(f"leaking actor returned {termination!r}")
        if not leader_done.exists():
            raise AssertionError("leader never reached its marker")
        if retention.text != FLOOD_MARKERS[1]:
            raise AssertionError(
                f"leaking actor retained {retention.text!r}, "
                f"expected {FLOOD_MARKERS[1]!r}"
            )
        if retention.capture_complete:
            raise AssertionError("survivor sweep reported complete capture")
        if LATE_LINE.encode("utf-8") not in tail:
            raise AssertionError("descendant output before the sweep was lost")
        if not tail.endswith(VERDICT_LINE.encode("utf-8")):
            raise AssertionError(
                f"child output did not precede the caller verdict: {tail[-120:]!r}"
            )
        leader_pid = int(leader_done.read_text(encoding="utf-8"))
        if watchdog._signal_group(leader_pid, 0):
            raise AssertionError("survivor process group remained after return")
        if elapsed < DRAIN_SETTLE_SECONDS - 0.2:
            raise AssertionError(
                f"survivor drain was not given its bounded window: {elapsed:.1f}s"
            )
        if elapsed >= DRAIN_SETTLE_SECONDS + 2.0:
            raise AssertionError(
                f"leaked descendant stalled the drain for {elapsed:.1f}s"
            )
        if sentinel.exists():
            raise AssertionError("leaking actor left its deadline sentinel")


def test_captured_command_marks_a_forced_drain_incomplete() -> None:
    """A leaked pipe holder makes capture incomplete and is swept."""
    with tempfile.TemporaryDirectory(prefix="mtest-watchdog-capture-leak-") as raw_tmp:
        tmp = Path(raw_tmp)
        actor = _persistent_leaking_actor(tmp)
        leader_pid_path = tmp / "leader-pid"
        descendant_pid_path = tmp / "descendant-pid"
        captured = watchdog.run_captured_command(
            [PYTHON, str(actor), str(leader_pid_path), str(descendant_pid_path)],
            source="tests/unit/test_watchdog.mojo",
            step="run",
            timeout_seconds=30.0,
        )
        if captured.termination != Exited(0):
            raise AssertionError(
                f"captured leaking actor returned {captured.termination!r}"
            )
        if captured.capture_complete:
            raise AssertionError("forced drain settlement reported complete capture")
        leader_pid = int(leader_pid_path.read_text(encoding="utf-8"))
        group_alive = watchdog._signal_group(leader_pid, 0)
        if group_alive:
            # Keep the red regression from leaking its actor before the
            # production cleanup exists.
            with contextlib.suppress(ProcessLookupError):
                os.killpg(leader_pid, signal.SIGKILL)
            raise AssertionError("ordinary leader exit left its process group alive")


def test_read_error_cannot_report_capture_complete() -> None:
    """A drainer error is not end of file and must fail capture closed."""
    read_descriptor, write_descriptor = os.pipe()
    os.write(write_descriptor, b"unread output")
    os.close(write_descriptor)
    reached_eof = threading.Event()
    retention = MarkerRetention(MARKER_PREFIX)
    sink = io.StringIO()

    def fail_read(_descriptor: int, _size: int) -> bytes:
        raise OSError("injected read failure")

    with os.fdopen(read_descriptor, "rb") as source:
        watchdog._tee_stream(
            source,
            watchdog._StreamTee(sink),
            retention,
            threading.Event(),
            reached_eof,
            read_chunk=fail_read,
        )
    state = watchdog._DrainState(
        threads=(),
        tees=(),
        stop=threading.Event(),
        retention=retention,
        sources=(),
        eof_events=(reached_eof,),
    )
    watchdog._seal_drainers(state)
    if retention.capture_complete:
        raise AssertionError("read failure was reported as complete capture")


def test_ordinary_exit_kills_survivors_before_drain_settlement() -> None:
    """The owned group is swept before leader reap, even if settle is cancelled."""
    order: list[str] = []
    original_signal_group = watchdog._signal_group
    original_settle = watchdog._settle_drainers
    settle_calls = 0

    def gone_group(pid: int, signum: int) -> bool:
        _assert_leader_is_unreaped(pid)
        order.append(f"signal-{signum}")
        return False

    def recording_settle(state: watchdog._DrainState | None) -> None:
        nonlocal settle_calls
        settle_calls += 1
        order.append("settle")
        if settle_calls == 1:
            raise watchdog._WatchdogCancellation(signal.SIGINT)
        original_settle(state)

    watchdog._signal_group = gone_group
    watchdog._settle_drainers = recording_settle
    try:
        termination = run_command(
            [PYTHON, "-c", "raise SystemExit(0)"],
            source="tests/unit/test_watchdog.mojo",
            step="run",
            timeout_seconds=10.0,
            marker_retention=MarkerRetention(MARKER_PREFIX),
        )
    finally:
        watchdog._signal_group = original_signal_group
        watchdog._settle_drainers = original_settle
    if termination != Cancelled(signal.SIGINT):
        raise AssertionError(f"ordinary child returned {termination!r}")
    expected = [f"signal-{signal.SIGKILL}", "settle", "settle"]
    if order != expected:
        raise AssertionError(f"ordinary cleanup order was {order}, expected {expected}")


def test_exit_observation_does_not_reap_the_group_leader() -> None:
    """Exit readiness leaves the leader PID pinned until group cleanup."""
    process = subprocess.Popen(
        [PYTHON, "-c", "raise SystemExit(0)"],
        start_new_session=True,
    )
    try:
        if not watchdog._wait_for_exit_without_reaping(process, 10.0):
            raise AssertionError("ordinary child exit was not observed")
        _assert_leader_is_unreaped(process.pid)
        watchdog._signal_group(process.pid, signal.SIGKILL)
        if process.wait() != 0:
            raise AssertionError("post-observation wait lost the original exit status")
    finally:
        if process.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def _assert_leader_is_unreaped(
    pid: int,
    *,
    waitid_available: bool | None = None,
) -> None:
    """Require a zombie leader to retain its PID on this Python platform."""
    if waitid_available is None:
        waitid_available = hasattr(os, "waitid")
    if waitid_available:
        try:
            status = os.waitid(
                os.P_PID,
                pid,
                os.WEXITED | os.WNOHANG | os.WNOWAIT,
            )
        except ChildProcessError as exc:
            raise AssertionError(
                "exit observation reaped the process-group leader"
            ) from exc
        if status is None:
            raise AssertionError("observed leader was not waitable")
        return
    try:
        os.kill(pid, 0)
    except ProcessLookupError as exc:
        raise AssertionError(
            "exit observation released the process-group leader PID"
        ) from exc


def test_unreaped_leader_probe_has_a_darwin_safe_fallback() -> None:
    """The non-reaping guard works when Python exposes no waitid binding."""
    process = subprocess.Popen(
        [PYTHON, "-c", "raise SystemExit(0)"],
        start_new_session=True,
    )
    try:
        if not watchdog._wait_for_exit_without_reaping(process, 10.0):
            raise AssertionError("ordinary child exit was not observed")
        _assert_leader_is_unreaped(process.pid, waitid_available=False)
        process.wait()
    finally:
        if process.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def test_darwin_exit_observation_rejects_registration_errors() -> None:
    """A kqueue EV_ERROR cannot masquerade as a child exit notification."""

    class _Darwin:
        sysname = "Darwin"

    class _ErrorEvent:
        flags = 0x01
        fflags = 0
        data = 12

    class _Queue:
        def __init__(self) -> None:
            self.calls = 0

        def control(
            self, changes: list[object], _max_events: int, _timeout: float
        ) -> list[_ErrorEvent]:
            self.calls += 1
            if self.calls == 1:
                raise InterruptedError
            if not changes:
                raise AssertionError("interrupted kqueue registration was not retried")
            return [_ErrorEvent()]

        def close(self) -> None:
            pass

    class _Process:
        pid = 1234

    queue = _Queue()

    def darwin_uname() -> _Darwin:
        return _Darwin()

    def fake_kqueue() -> _Queue:
        return queue

    def fake_kevent(*_args: object, **_kwargs: object) -> object:
        return object()

    original_uname = os.uname
    original_attrs = {
        name: getattr(select, name, None)
        for name in (
            "kqueue",
            "kevent",
            "KQ_FILTER_PROC",
            "KQ_EV_ADD",
            "KQ_EV_ONESHOT",
            "KQ_NOTE_EXIT",
            "KQ_EV_ERROR",
        )
    }
    os.uname = darwin_uname  # type: ignore[assignment]
    select.kqueue = fake_kqueue  # type: ignore[attr-defined]
    select.kevent = fake_kevent  # type: ignore[attr-defined]
    select.KQ_FILTER_PROC = 1  # type: ignore[attr-defined]
    select.KQ_EV_ADD = 2  # type: ignore[attr-defined]
    select.KQ_EV_ONESHOT = 4  # type: ignore[attr-defined]
    select.KQ_NOTE_EXIT = 8  # type: ignore[attr-defined]
    select.KQ_EV_ERROR = 0x01  # type: ignore[attr-defined]
    try:
        try:
            watchdog._wait_for_exit_without_reaping(
                cast("subprocess.Popen[bytes]", _Process()), 1.0
            )
        except OSError as exc:
            if exc.errno != 12:
                raise AssertionError(f"wrong kqueue registration errno: {exc}") from exc
        else:
            raise AssertionError("kqueue registration error was reported as exit")
    finally:
        os.uname = original_uname
        for name, value in original_attrs.items():
            if value is None:
                delattr(select, name)
            else:
                setattr(select, name, value)


def test_internal_failure_cleans_an_exited_unreaped_group() -> None:
    """Backstop cleanup must not poll away group ownership before its sweep."""
    original_wait_for_exit = watchdog._wait_for_exit_without_reaping
    original_terminate = watchdog._terminate_process_group
    terminate_calls = 0

    def fail_after_exit(
        process: subprocess.Popen[bytes], timeout_seconds: float
    ) -> bool:
        if not original_wait_for_exit(process, timeout_seconds):
            raise AssertionError("test child did not exit")
        raise RuntimeError("injected post-exit failure")

    def recording_terminate(process: subprocess.Popen[bytes]) -> None:
        nonlocal terminate_calls
        terminate_calls += 1
        original_terminate(process)

    watchdog._wait_for_exit_without_reaping = fail_after_exit
    watchdog._terminate_process_group = recording_terminate
    try:
        termination = run_command(
            [PYTHON, "-c", "raise SystemExit(0)"],
            source="tests/unit/test_watchdog.mojo",
            step="run",
            timeout_seconds=10.0,
        )
    finally:
        watchdog._wait_for_exit_without_reaping = original_wait_for_exit
        watchdog._terminate_process_group = original_terminate
    if not isinstance(termination, HarnessError):
        raise AssertionError(f"internal failure returned {termination!r}")
    if terminate_calls != 1:
        raise AssertionError(
            f"backstop swept the exited group {terminate_calls} times, expected once"
        )


def test_signal_during_internal_failure_cleanup_cannot_escape() -> None:
    """Backstop cleanup consumes managed signals until the child is reaped."""
    original_wait_for_exit = watchdog._wait_for_exit_without_reaping
    original_terminate = watchdog._terminate_process_group

    def injected_failure(
        process: subprocess.Popen[bytes],  # noqa: ARG001
        timeout_seconds: float,  # noqa: ARG001
    ) -> bool:
        raise RuntimeError("injected wait failure")

    def interrupting_terminate(process: subprocess.Popen[bytes]) -> None:
        os.kill(os.getpid(), signal.SIGTERM)
        original_terminate(process)

    watchdog._wait_for_exit_without_reaping = injected_failure
    watchdog._terminate_process_group = interrupting_terminate
    try:
        try:
            termination = run_command(
                [PYTHON, "-c", "raise SystemExit(0)"],
                source="tests/unit/test_watchdog.mojo",
                step="run",
                timeout_seconds=10.0,
            )
        except watchdog._WatchdogCancellation as exc:
            raise AssertionError("managed signal escaped backstop cleanup") from exc
    finally:
        watchdog._wait_for_exit_without_reaping = original_wait_for_exit
        watchdog._terminate_process_group = original_terminate
    if not isinstance(termination, HarnessError):
        raise AssertionError(f"cleanup signal escaped as {termination!r}")


def test_signal_while_formatting_internal_failure_still_cleans_group() -> None:
    """A managed signal before the backstop flag cannot escape group cleanup."""
    original_wait_for_exit = watchdog._wait_for_exit_without_reaping
    original_terminate = watchdog._terminate_process_group
    terminate_calls = 0

    class _InterruptingError(RuntimeError):
        @override
        def __str__(self) -> str:
            os.kill(os.getpid(), signal.SIGTERM)
            raise RuntimeError("injected formatting failure")

    def injected_failure(
        process: subprocess.Popen[bytes],  # noqa: ARG001
        timeout_seconds: float,  # noqa: ARG001
    ) -> bool:
        raise _InterruptingError

    def recording_terminate(process: subprocess.Popen[bytes]) -> None:
        nonlocal terminate_calls
        terminate_calls += 1
        original_terminate(process)

    watchdog._wait_for_exit_without_reaping = injected_failure
    watchdog._terminate_process_group = recording_terminate
    try:
        try:
            termination = run_command(
                [PYTHON, "-c", "import time; time.sleep(0.5)"],
                source="tests/unit/test_watchdog.mojo",
                step="run",
                timeout_seconds=10.0,
            )
        except watchdog._WatchdogCancellation as exc:
            raise AssertionError(
                "managed signal escaped while formatting internal failure"
            ) from exc
    finally:
        watchdog._wait_for_exit_without_reaping = original_wait_for_exit
        watchdog._terminate_process_group = original_terminate
    if not isinstance(termination, HarnessError):
        raise AssertionError(f"formatting signal escaped as {termination!r}")
    if terminate_calls != 1:
        raise AssertionError(
            f"backstop swept the child group {terminate_calls} times, expected once"
        )
    if "_InterruptingError could not be rendered" not in termination.detail:
        raise AssertionError(
            f"unrenderable failure lost its stable fallback: {termination.detail!r}"
        )


def test_failed_leader_wait_keeps_backstop_cleanup_armed() -> None:
    """A failed reap cannot mark the process group fully cleaned."""
    original_wait = cast(
        "Callable[[subprocess.Popen[bytes], float | None], int]",
        subprocess.Popen.wait,
    )
    failed_wait = False
    waited_processes: list[subprocess.Popen[bytes]] = []
    terminate_calls = 0

    def failing_first_wait(
        process: subprocess.Popen[bytes],
        timeout: float | None = None,
    ) -> int:
        nonlocal failed_wait
        waited_processes.append(process)
        if not failed_wait:
            failed_wait = True
            raise RuntimeError("injected leader reap failure")
        return original_wait(process, timeout)

    def recording_terminate(process: subprocess.Popen[bytes]) -> None:
        nonlocal terminate_calls
        terminate_calls += 1
        original_wait(process, None)

    try:
        with (
            mock.patch.object(subprocess.Popen, "wait", failing_first_wait),
            mock.patch.object(
                watchdog,
                "_terminate_process_group",
                recording_terminate,
            ),
        ):
            termination = run_command(
                [PYTHON, "-c", "raise SystemExit(0)"],
                source="tests/unit/test_watchdog.mojo",
                step="run",
                timeout_seconds=10.0,
            )
    finally:
        for process in waited_processes:
            original_wait(process, None)
    if not isinstance(termination, HarnessError):
        raise AssertionError(f"failed wait returned {termination!r}")
    if terminate_calls != 1:
        raise AssertionError(
            f"backstop cleanup ran {terminate_calls} times, expected once"
        )


def test_timeout_diagnostic_uses_the_callers_source() -> None:
    """A reusable watchdog diagnostic must not claim a classified-suite caller."""
    captured = io.StringIO()
    with contextlib.redirect_stderr(captured):
        watchdog._notify_timeout("assertions-check", "compile", 1.5)
    expected = (
        "FATAL: assertions-check: compile exceeded 1.5s; "
        "terminating its process group\n"
    )
    if captured.getvalue() != expected:
        raise AssertionError(
            f"timeout diagnostic was {captured.getvalue()!r}, expected {expected!r}"
        )


def test_a_caller_stream_without_a_byte_buffer_still_receives_the_tee() -> None:
    """A redirected text stream is written to, never silently discarded."""
    with tempfile.TemporaryDirectory(prefix="mtest-watchdog-text-") as raw_tmp:
        tmp = Path(raw_tmp)
        sentinel = tmp / "deadline-sentinel"
        sentinel.touch()
        retention = MarkerRetention(MARKER_PREFIX)
        captured = io.StringIO()
        original_stdout = sys.stdout
        sys.stdout = captured
        try:
            termination = run_command(
                [
                    PYTHON,
                    "-c",
                    f"import sys; sys.stdout.write({FLOOD_MARKERS[1]!r})",
                ],
                source="tests/unit/test_watchdog.mojo",
                step="run",
                timeout_seconds=10.0,
                deadline_sentinel=sentinel,
                marker_retention=retention,
            )
        finally:
            sys.stdout = original_stdout
        if termination != Exited(0):
            raise AssertionError(f"text-stream tee returned {termination!r}")
        if captured.getvalue() != FLOOD_MARKERS[1]:
            raise AssertionError(
                f"text-stream tee wrote {captured.getvalue()!r}, "
                f"expected {FLOOD_MARKERS[1]!r}"
            )
        if retention.text != FLOOD_MARKERS[1]:
            raise AssertionError(
                f"text-stream tee retained {retention.text!r}, "
                f"expected {FLOOD_MARKERS[1]!r}"
            )


def test_cancellation_during_the_drain_settle_stays_cancelled() -> None:
    """A caller signal in the post-exit drain is Cancelled, never a traceback."""
    with tempfile.TemporaryDirectory(prefix="mtest-watchdog-cancel-") as raw_tmp:
        tmp = Path(raw_tmp)
        sentinel = tmp / "deadline-sentinel"
        sentinel.touch()
        settle_ready = tmp / "settle-ready"
        wrapper = tmp / "delayed_settle_watchdog.py"
        wrapper.write_text(
            "from pathlib import Path\n"
            "import sys\n"
            "import time\n"
            "sys.path.insert(0, sys.argv[1])\n"
            "from scripts.harness import watchdog\n"
            "original_settle = watchdog._settle_drainers\n"
            "settle_calls = [0]\n"
            "def delayed_settle(state):\n"
            "    settle_calls[0] += 1\n"
            "    if settle_calls[0] == 1:\n"
            "        Path(sys.argv[4]).touch()\n"
            "        time.sleep(120)\n"
            "    original_settle(state)\n"
            "watchdog._settle_drainers = delayed_settle\n"
            "retention = watchdog.MarkerRetention(sys.argv[2])\n"
            "termination = watchdog.run_command(\n"
            "    sys.argv[6:],\n"
            "    source='tests/unit/test_watchdog.mojo',\n"
            "    step='run',\n"
            "    timeout_seconds=float(sys.argv[5]),\n"
            "    deadline_sentinel=Path(sys.argv[3]),\n"
            "    marker_retention=retention,\n"
            ")\n"
            "raise SystemExit(watchdog._exit_with_termination(termination))",
            encoding="utf-8",
        )
        supervisor = subprocess.Popen(
            [
                PYTHON,
                str(wrapper),
                str(REPO_ROOT),
                MARKER_PREFIX,
                str(sentinel),
                str(settle_ready),
                "30.0",
                PYTHON,
                "-c",
                "raise SystemExit(0)",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            _wait_for_paths((settle_ready,))
            os.kill(supervisor.pid, signal.SIGTERM)
            status = supervisor.wait(timeout=30.0)
            if supervisor.stderr is None:
                raise AssertionError("the supervisor was spawned without a stderr pipe")
            diagnostic = supervisor.stderr.read()
        finally:
            if supervisor.poll() is None:
                supervisor.kill()
                supervisor.wait()
        if status != -signal.SIGTERM:
            raise AssertionError(
                f"cancellation during the drain exited {status}, "
                f"expected {-signal.SIGTERM}:\n{diagnostic}"
            )
        if "Traceback" in diagnostic:
            raise AssertionError(
                f"cancellation during the drain escaped cleanup:\n{diagnostic}"
            )
        if sentinel.exists():
            raise AssertionError(
                "cancellation during the drain left the deadline sentinel"
            )


def test_a_zombie_only_group_reports_gone_on_both_spellings() -> None:
    """Darwin spells "every member is a zombie" EPERM, not ESRCH.

    Treating that as an error let a Ctrl-C racing the child's exit replace a
    truthful Cancelled or Signaled with HarnessError, so the classified harness
    returned internal exit 70 for a cancellation that in fact completed. This
    supervisor owns every member of the group it signals, so EPERM cannot mean
    a permission boundary.
    """
    # `watchdog.os` is this module's own `os`, so patching it here reaches the
    # identical object the supervisor calls through.
    for error in (ProcessLookupError(), PermissionError()):

        def refuse(_pid: int, _signum: int, exc: OSError = error) -> None:
            raise exc

        original = os.killpg
        os.killpg = refuse
        try:
            if watchdog._signal_group(1234, 0):
                raise AssertionError(
                    f"{type(error).__name__} was not treated as a gone group"
                )
        finally:
            os.killpg = original

    delivered: list[tuple[int, int]] = []

    def accept(pid: int, signum: int) -> None:
        delivered.append((pid, signum))

    original = os.killpg
    os.killpg = accept
    try:
        if not watchdog._signal_group(99, 15):
            raise AssertionError("a live group was reported gone")
    finally:
        os.killpg = original
    if delivered != [(99, 15)]:
        raise AssertionError(f"signal not forwarded verbatim: {delivered}")


def test_forwarding_a_signal_survives_a_zombie_only_group() -> None:
    """The whole cleanup path, not just the helper, must tolerate EPERM."""

    class _Reaped:
        pid = 4321

        def __init__(self) -> None:
            self.waited = 0

        def poll(self) -> None:
            return None

        def wait(self) -> None:
            self.waited += 1

    def zombie_only(_pid: int, _signum: int) -> None:
        raise PermissionError

    process = _Reaped()
    # `_Reaped` is a duck-typed stand-in exposing exactly the three members both
    # cleanup paths touch; the cast states that without changing what is passed.
    reaped = cast("subprocess.Popen[bytes]", process)
    original = os.killpg
    os.killpg = zombie_only
    try:
        watchdog._forward_signal_and_cleanup(reaped, 2)
        watchdog._terminate_process_group(reaped)
    finally:
        os.killpg = original
    if process.waited != 2:
        raise AssertionError(
            f"cleanup did not reap the leader on both paths: {process.waited}"
        )


def test_an_unsealable_tee_releases_its_drainer_source() -> None:
    """A stalled caller stream must not leak a thread and a descriptor.

    `seal` returns False when a drainer is parked in a write nobody is
    reading. Ignoring that left the thread blocked forever holding the child's
    pipe, so a caller running `run_command` in a loop exhausted both.
    """

    class _UnsealableTee:
        def seal(self) -> bool:
            return False

    class _Source:
        def __init__(self) -> None:
            self.closed = False

        def close(self) -> None:
            self.closed = True

    source = _Source()
    state = watchdog._DrainState(
        threads=(),
        # Duck-typed stand-ins for the only two members `_seal_drainers`
        # touches; the casts state that without changing what is passed.
        tees=cast("tuple[watchdog._StreamTee, ...]", (_UnsealableTee(),)),
        stop=threading.Event(),
        retention=None,
        sources=cast("tuple[IO[bytes], ...]", (source,)),
    )
    watchdog._seal_drainers(state)
    if not source.closed:
        raise AssertionError(
            "an unsealable tee left its drainer holding the child pipe"
        )


def test_a_sealable_tee_keeps_its_source_for_the_drainer_to_close() -> None:
    """The normal path is unchanged: `_tee_stream` closes its own source."""

    class _SealableTee:
        def seal(self) -> bool:
            return True

    class _Source:
        def __init__(self) -> None:
            self.closed = False

        def close(self) -> None:
            self.closed = True

    source = _Source()
    watchdog._seal_drainers(
        watchdog._DrainState(
            threads=(),
            # Duck-typed stand-ins, as in the unsealable case above.
            tees=cast("tuple[watchdog._StreamTee, ...]", (_SealableTee(),)),
            stop=threading.Event(),
            retention=None,
            sources=cast("tuple[IO[bytes], ...]", (source,)),
        )
    )
    if source.closed:
        raise AssertionError("a cleanly sealed tee closed its source twice")


def test_bounded_capture_preserves_a_scalar_split_across_byte_writes() -> None:
    """Child pipe chunk boundaries must not become Unicode replacement text."""
    capture = watchdog._BoundedTextCapture(32)
    capture.buffer.write(b"\xc3")
    capture.buffer.write(b"\xa9")
    if capture.finish() != "é":
        raise AssertionError("bounded capture decoded UTF-8 byte chunks separately")


def test_bounded_capture_drops_a_scalar_split_by_the_byte_cap() -> None:
    """The retention cap must not manufacture replacement text."""
    capture = watchdog._BoundedTextCapture(2)
    capture.buffer.write(b"a\xc3\xa9")
    expected = "a" + watchdog.CAPTURE_TRUNCATION_MARKER
    if capture.finish() != expected:
        raise AssertionError(
            f"byte cap manufactured text: {capture.finish()!r}, expected {expected!r}"
        )


def main() -> int:
    """Run every watchdog invariant without an external test framework."""
    for test in (
        test_normal_exit_is_preserved,
        test_nonzero_exit_is_preserved,
        test_signal_death_is_preserved,
        test_sigkill_death_is_preserved,
        test_inherited_blocked_sigterm_is_preserved,
        test_ordinary_exit_124_removes_its_deadline_sentinel,
        test_in_process_ordinary_137_is_structured_as_exited,
        test_in_process_signal_is_structured_as_signaled,
        test_invalid_run_command_timeouts_never_spawn_payloads,
        test_parser_rejects_invalid_timeouts_before_payload_start,
        test_spawn_failure_is_not_a_timeout,
        test_broken_timeout_diagnostic_leaves_the_deadline_sentinel,
        test_closed_timeout_diagnostic_preserves_the_deadline_result,
        test_timeout_terminates_the_whole_process_group,
        test_sigterm_is_forwarded_to_the_process_group,
        test_sigint_is_forwarded_to_the_process_group,
        test_first_signal_wins_during_forced_cleanup,
        test_cancellation_wins_when_spawn_then_raises,
        test_flooding_child_is_drained_teed_and_marked,
        test_leaked_descendant_output_precedes_cleanup_verdict,
        test_captured_command_marks_a_forced_drain_incomplete,
        test_read_error_cannot_report_capture_complete,
        test_ordinary_exit_kills_survivors_before_drain_settlement,
        test_exit_observation_does_not_reap_the_group_leader,
        test_unreaped_leader_probe_has_a_darwin_safe_fallback,
        test_darwin_exit_observation_rejects_registration_errors,
        test_internal_failure_cleans_an_exited_unreaped_group,
        test_signal_during_internal_failure_cleanup_cannot_escape,
        test_signal_while_formatting_internal_failure_still_cleans_group,
        test_failed_leader_wait_keeps_backstop_cleanup_armed,
        test_timeout_diagnostic_uses_the_callers_source,
        test_a_caller_stream_without_a_byte_buffer_still_receives_the_tee,
        test_cancellation_during_the_drain_settle_stays_cancelled,
        test_a_blocked_caller_stream_cannot_swallow_a_caller_signal,
        test_high_numbered_pipe_descriptors_do_not_lose_output,
        test_a_zombie_only_group_reports_gone_on_both_spellings,
        test_forwarding_a_signal_survives_a_zombie_only_group,
        test_an_unsealable_tee_releases_its_drainer_source,
        test_a_sealable_tee_keeps_its_source_for_the_drainer_to_close,
        test_bounded_capture_preserves_a_scalar_split_across_byte_writes,
        test_bounded_capture_drops_a_scalar_split_by_the_byte_cap,
        test_a_frozen_marker_capture_refuses_later_writes,
        test_the_seal_freezes_the_capture_before_it_seals_any_tee,
        test_a_drainer_cannot_write_through_a_frozen_capture,
        test_a_cancelled_timeout_settle_seals_before_the_timeout_diagnostic,
        test_a_signal_during_timeout_diagnostic_keeps_deadline_precedence,
        test_partial_drainer_start_is_published_before_cancellation,
    ):
        test()
    print("process-watchdog: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
