#!/usr/bin/env python3
"""Self-tests for the direct-suite subprocess watchdog."""

from __future__ import annotations

import math
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from process_watchdog import TIMEOUT_EXIT_CODE, run_command


PYTHON = sys.executable
WATCHDOG = Path(__file__).with_name("process_watchdog.py")


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
            PYTHON,
            str(WATCHDOG),
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
            str(WATCHDOG),
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


def test_invalid_run_command_timeouts_never_spawn_payloads() -> None:
    """Non-finite and over-ceiling direct calls fail before creating a child."""
    for timeout_seconds in (math.nan, math.inf, -math.inf, 301.0):
        with tempfile.TemporaryDirectory(prefix="mtest-watchdog-") as raw_tmp:
            marker = Path(raw_tmp) / "payload-started"
            try:
                run_command(
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
                )
            except ValueError:
                pass
            else:
                raise AssertionError(f"timeout {timeout_seconds!r} did not raise")
            if marker.exists():
                raise AssertionError(f"timeout {timeout_seconds!r} started its payload")


def test_parser_rejects_invalid_timeouts_before_payload_start() -> None:
    """CLI timeout values reject NaN, infinities, and values above 300 seconds."""
    for timeout_seconds in ("nan", "inf", "-inf", "301"):
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
        if result.returncode == TIMEOUT_EXIT_CODE:
            raise AssertionError("spawn failure was encoded as timeout status 124")
        if "exceeded" in result.stderr or "timed out" in result.stderr:
            raise AssertionError(f"spawn failure claimed timeout:\n{result.stderr}")
        if not sentinel.exists():
            raise AssertionError("spawn failure removed the deadline sentinel")


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
            status = run_command(
                [PYTHON, "-c", "import time; time.sleep(60)"],
                source="tests/unit/test_watchdog.mojo",
                step="run",
                timeout_seconds=0.1,
                deadline_sentinel=sentinel,
            )
        finally:
            sys.stderr = original_stderr
        if status != TIMEOUT_EXIT_CODE:
            raise AssertionError(f"expected timeout exit {TIMEOUT_EXIT_CODE}, got {status}")
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


def main() -> int:
    """Run every watchdog invariant without an external test framework."""
    for test in (
        test_normal_exit_is_preserved,
        test_nonzero_exit_is_preserved,
        test_signal_death_is_preserved,
        test_sigkill_death_is_preserved,
        test_inherited_blocked_sigterm_is_preserved,
        test_ordinary_exit_124_removes_its_deadline_sentinel,
        test_invalid_run_command_timeouts_never_spawn_payloads,
        test_parser_rejects_invalid_timeouts_before_payload_start,
        test_spawn_failure_is_not_a_timeout,
        test_broken_timeout_diagnostic_leaves_the_deadline_sentinel,
        test_timeout_terminates_the_whole_process_group,
    ):
        test()
    print("process-watchdog: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
