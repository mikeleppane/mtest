#!/usr/bin/env python3
"""Self-tests for the direct-suite subprocess watchdog."""

from __future__ import annotations

import io
import math
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile
import threading
import time

from scripts.harness import watchdog
from scripts.harness.watchdog import (
    Cancelled,
    DRAIN_SETTLE_SECONDS,
    Exited,
    HarnessError,
    MarkerRetention,
    Signaled,
    TimedOut,
    TIMEOUT_EXIT_CODE,
    run_command,
)


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
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
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
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
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
                    "from pathlib import Path; import sys; "
                    "Path(sys.argv[1]).write_text('started')",
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
                    "from pathlib import Path; import sys; "
                    "Path(sys.argv[1]).write_text('started')",
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
            raise AssertionError(f"spawn failure exited {result.returncode}, expected 70")
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
            raise AssertionError("broken timeout diagnostic cleared the deadline sentinel")


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
            "\n".join(
                [
                    "from pathlib import Path",
                    "import signal",
                    "import sys",
                    "import time",
                    "signal.signal(signal.SIGTERM, signal.SIG_IGN)",
                    "Path(sys.argv[1]).write_text('ready')",
                    "time.sleep(6.0)",
                    "Path(sys.argv[2]).write_text('survived')",
                ]
            ),
            encoding="utf-8",
        )
        child.write_text(
            "\n".join(
                [
                    "import subprocess",
                    "import sys",
                    "import time",
                    "ready, marker, grandchild = sys.argv[1:]",
                    "subprocess.Popen([sys.executable, grandchild, ready, marker])",
                    "while not __import__('pathlib').Path(ready).exists():",
                    "    time.sleep(0.01)",
                    "time.sleep(60)",
                ]
            ),
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
        if "tests/unit/test_watchdog.mojo" not in diagnostic or ": run " not in diagnostic:
            raise AssertionError(f"timeout diagnostic lost its source or step: {diagnostic}")
        if not deadline_sentinel.exists():
            raise AssertionError("actual timeout removed its deadline sentinel")
        if not ready.exists():
            raise AssertionError("timeout raced before the SIGTERM-ignoring child was ready")
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
            "\n".join(
                [
                    "from pathlib import Path",
                    "import os",
                    "import signal",
                    "import subprocess",
                    "import sys",
                    "import time",
                    "role, ready, received, child_ready, child_received = sys.argv[1:6]",
                    "signum = int(sys.argv[6])",
                    "linger_after_signal = sys.argv[8] == 'linger'",
                    "def handle(actual, _frame):",
                    "    Path(received).write_text(str(actual))",
                    "    if linger_after_signal:",
                    "        return",
                    "    raise SystemExit(0)",
                    "signal.signal(signum, handle)",
                    "if role == 'leader':",
                    "    Path(sys.argv[7]).write_text(str(os.getpid()))",
                    "    subprocess.Popen([sys.executable, __file__, 'descendant', child_ready, child_received, '', '', str(signum), '', sys.argv[8]])",
                    "Path(ready).write_text('ready')",
                    "time.sleep(60)",
                ]
            ),
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
            assert watchdog.stderr is not None
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
                try:
                    os.killpg(int(leader_pid.read_text(encoding="utf-8")), signal.SIGKILL)
                except ProcessLookupError:
                    pass


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
            "\n".join(
                [
                    "import os",
                    "import signal",
                    "import sys",
                    "sys.path.insert(0, sys.argv[1])",
                    "from scripts.harness import watchdog",
                    "def cancelled_spawn(*_args, **_kwargs):",
                    "    os.kill(os.getpid(), signal.SIGTERM)",
                    "    raise FileNotFoundError('injected spawn failure')",
                    "watchdog.subprocess.Popen = cancelled_spawn",
                    "raise SystemExit(watchdog.main(sys.argv[2:]))",
                ]
            ),
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
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
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

    def __init__(self, handle: object) -> None:
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
            with teed.open("wb") as stdout_handle:
                with diagnostics.open("wb") as stderr_handle:
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
        "\n".join(
            [
                "from pathlib import Path",
                "import sys",
                "sys.path.insert(0, sys.argv[1])",
                "from scripts.harness import watchdog",
                "retention = watchdog.MarkerRetention(sys.argv[2])",
                "termination = watchdog.run_command(",
                "    sys.argv[5:],",
                "    source='tests/unit/test_watchdog.mojo',",
                "    step='run',",
                "    timeout_seconds=float(sys.argv[4]),",
                "    deadline_sentinel=Path(sys.argv[3]),",
                "    marker_retention=retention,",
                ")",
                "raise SystemExit(watchdog._exit_with_termination(termination))",
            ]
        ),
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
            assert supervisor.stderr is not None
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
            expected = (
                FLOOD_LINE * FLOOD_LINE_COUNT + FLOOD_MARKERS[1]
            ).encode("utf-8")
            original_stdout = sys.stdout
            with teed.open("wb") as handle:
                sys.stdout = _TextOverBytes(handle)
                try:
                    termination = run_command(
                        [
                            PYTHON,
                            "-c",
                            "import sys; "
                            f"sys.stdout.write({FLOOD_LINE!r} * "
                            f"{FLOOD_LINE_COUNT}); "
                            f"sys.stdout.write({FLOOD_MARKERS[1]!r})",
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
                    f"high-fd drain teed {len(actual)} bytes, "
                    f"expected {len(expected)}"
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
            f"open capture retained {retention.text!r}, "
            f"expected {FLOOD_MARKERS[1]!r}"
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
        def seal(self) -> bool:
            order.append("seal")
            return super().seal()

    class _OrderingRetention(MarkerRetention):
        def freeze(self) -> None:
            order.append("freeze")
            super().freeze()

    state = watchdog._DrainState(
        threads=(),
        tees=(_OrderingTee(io.StringIO()), _OrderingTee(io.StringIO())),
        stop=threading.Event(),
        retention=_OrderingRetention(MARKER_PREFIX),
    )
    watchdog._seal_drainers(state)
    if order != ["freeze", "seal", "seal"]:
        raise AssertionError(
            f"seal ordering was {order}, expected the freeze first"
        )
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
        raise AssertionError(
            f"the drain lost its tee: {sink.getvalue()!r}"
        )
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
        original_start = watchdog._start_drainers
        original_settle = watchdog._settle_drainers
        original_notify = watchdog._notify_timeout

        def recording_start(
            process: object, marker: MarkerRetention
        ) -> watchdog._DrainState:
            """Capture the live drainers so the diagnostic can be inspected."""
            state = original_start(process, marker)
            states.append(state)
            return state

        def cancelling_settle(_state: watchdog._DrainState | None) -> None:
            """Stand in for a caller signal delivered inside the drain settle."""
            raise watchdog._WatchdogCancellation(signal.SIGTERM)

        def observing_notify(
            source: str, step: str, timeout_seconds: float
        ) -> None:
            """Record whether every tee was already shut when FATAL was printed."""
            sealed_at_diagnostic.append(
                bool(states) and all(tee.sealed for tee in states[-1].tees)
            )
            original_notify(source, step, timeout_seconds)

        watchdog._start_drainers = recording_start
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
            watchdog._start_drainers = original_start
            watchdog._settle_drainers = original_settle
            watchdog._notify_timeout = original_notify
        if not isinstance(termination, TimedOut):
            raise AssertionError(
                f"cancelled timeout settle returned {termination!r}"
            )
        if sealed_at_diagnostic != [True]:
            raise AssertionError(
                "the timeout diagnostic was printed with a live drainer: "
                f"{sealed_at_diagnostic}"
            )


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
                "leader_done, late_seconds = sys.argv[1], sys.argv[2]",
                "subprocess.Popen(",
                f"    [sys.executable, {str(descendant)!r}, late_seconds]",
                ")",
                f"sys.stdout.write({FLOOD_MARKERS[1]!r})",
                "sys.stdout.flush()",
                "Path(leader_done).write_text('done')",
                "raise SystemExit(0)",
            ]
        ),
        encoding="utf-8",
    )
    return actor


def test_leaked_descendant_bounds_the_drain_and_seals_the_tee() -> None:
    """A leaked pipe holder cannot stall the drain nor write past the verdict."""
    with tempfile.TemporaryDirectory(prefix="mtest-watchdog-leak-") as raw_tmp:
        tmp = Path(raw_tmp)
        late_seconds = DRAIN_SETTLE_SECONDS + 3.0
        actor = _leaking_actor(tmp)
        leader_done = tmp / "leader-done"
        sentinel = tmp / "deadline-sentinel"
        sentinel.touch()
        retention = MarkerRetention(MARKER_PREFIX)
        teed = tmp / "teed-stdout"
        diagnostics = tmp / "teed-stderr"
        original_stdout = sys.stdout
        original_stderr = sys.stderr
        # The caller's stream stays open across the descendant's late write, so
        # an unsealed drainer would genuinely append to it here.
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
                            str(late_seconds),
                        ],
                        source="tests/unit/test_watchdog.mojo",
                        step="run",
                        timeout_seconds=30.0,
                        deadline_sentinel=sentinel,
                        marker_retention=retention,
                    )
                    elapsed = time.monotonic() - started
                    # The supervisor's own verdict, written after the drain has
                    # been sealed. Nothing the child group emits later may
                    # follow it.
                    stdout_handle.write(VERDICT_LINE.encode("utf-8"))
                    stdout_handle.flush()
                finally:
                    sys.stdout = original_stdout
                    sys.stderr = original_stderr
            # Outlive the descendant's write before reading the stream back.
            time.sleep(max(late_seconds - elapsed, 0.0) + 1.0)
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
        # Stand in for a straggling drainer: the supervisor has returned, so the
        # capture must already be closed against a later marker.
        retention.record(LATE_MARKER)
        if retention.text != FLOOD_MARKERS[1]:
            raise AssertionError(
                "the seal left the marker capture open after returning: "
                f"{retention.text!r}"
            )
        if elapsed >= DRAIN_SETTLE_SECONDS + 2.0:
            raise AssertionError(
                f"leaked descendant stalled the drain for {elapsed:.1f}s"
            )
        if sentinel.exists():
            raise AssertionError("leaking actor left its deadline sentinel")
        if not tail.endswith(VERDICT_LINE.encode("utf-8")):
            raise AssertionError(
                f"a drainer wrote past the sealed verdict: {tail[-120:]!r}"
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
        actor = _leaking_actor(tmp)
        leader_done = tmp / "leader-done"
        sentinel = tmp / "deadline-sentinel"
        sentinel.touch()
        supervisor = subprocess.Popen(
            [
                *_retaining_watchdog_argv(tmp, sentinel, timeout_seconds=30.0),
                PYTHON,
                str(actor),
                str(leader_done),
                str(DRAIN_SETTLE_SECONDS + 30.0),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            _wait_for_paths((leader_done,))
            # The leader has exited, so the supervisor is past `wait` and inside
            # the bounded drain that the leaked descendant is holding open.
            time.sleep(DRAIN_SETTLE_SECONDS / 4.0)
            os.kill(supervisor.pid, signal.SIGTERM)
            status = supervisor.wait(timeout=30.0)
            assert supervisor.stderr is not None
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
        test_timeout_terminates_the_whole_process_group,
        test_sigterm_is_forwarded_to_the_process_group,
        test_sigint_is_forwarded_to_the_process_group,
        test_first_signal_wins_during_forced_cleanup,
        test_cancellation_wins_when_spawn_then_raises,
        test_flooding_child_is_drained_teed_and_marked,
        test_leaked_descendant_bounds_the_drain_and_seals_the_tee,
        test_a_caller_stream_without_a_byte_buffer_still_receives_the_tee,
        test_cancellation_during_the_drain_settle_stays_cancelled,
        test_a_blocked_caller_stream_cannot_swallow_a_caller_signal,
        test_high_numbered_pipe_descriptors_do_not_lose_output,
        test_a_frozen_marker_capture_refuses_later_writes,
        test_the_seal_freezes_the_capture_before_it_seals_any_tee,
        test_a_drainer_cannot_write_through_a_frozen_capture,
        test_a_cancelled_timeout_settle_seals_before_the_timeout_diagnostic,
    ):
        test()
    print("process-watchdog: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
