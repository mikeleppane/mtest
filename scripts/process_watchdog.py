#!/usr/bin/env python3
"""Run one direct-test command with a bounded process-group lifetime."""

from __future__ import annotations

import argparse
import math
import os
import signal
import subprocess
import sys
import time
from collections.abc import Sequence
from pathlib import Path


DEFAULT_TIMEOUT_SECONDS = 300.0
TERMINATION_GRACE_SECONDS = 5.0
TIMEOUT_EXIT_CODE = 124


def _terminate_process_group(process: subprocess.Popen[object]) -> None:
    """Terminate a timed-out process group and wait for its leader."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait()
        return

    # The leader can exit from SIGTERM before a descendant that inherited its
    # group. Keep the full grace period, then sweep that group even if the
    # leader has already exited and been reaped.
    time.sleep(TERMINATION_GRACE_SECONDS)

    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def _validate_deadline_sentinel(deadline_sentinel: Path | None) -> None:
    """Fail before spawn unless the caller supplied a regular deadline sentinel."""
    if deadline_sentinel is None:
        return
    if not deadline_sentinel.is_file():
        raise ValueError(
            "watchdog deadline sentinel must exist as a regular file before spawn: "
            f"{deadline_sentinel}"
        )


def _validate_timeout_seconds(timeout_seconds: float) -> None:
    """Reject non-finite or out-of-policy watchdog ceilings before spawn."""
    if not math.isfinite(timeout_seconds) or not (
        0 < timeout_seconds <= DEFAULT_TIMEOUT_SECONDS
    ):
        raise ValueError(
            "watchdog timeout must be finite and between 0 and "
            f"{DEFAULT_TIMEOUT_SECONDS:g} seconds"
        )


def _notify_timeout(source: str, step: str, timeout_seconds: float) -> None:
    """Best-effort timeout diagnostic after process-group cleanup."""
    try:
        print(
            "FATAL: test_all: "
            f"{source}: {step} exceeded {timeout_seconds:g}s; "
            "terminating its process group",
            file=sys.stderr,
        )
    except (BrokenPipeError, OSError):
        pass


def run_command(
    command: Sequence[str],
    *,
    source: str,
    step: str,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
    deadline_sentinel: Path | None = None,
) -> int:
    """Run ``command`` and return its status, bounding its process group.

    Args:
        command: Direct executable argv, without shell interpretation.
        source: Suite source displayed if the command times out.
        step: Either the suite's ``build`` or ``run`` step.
        timeout_seconds: Positive wall-clock ceiling for the command.
        deadline_sentinel: Pre-created file removed only after non-timeout exit.

    Returns:
        The direct child's normal ``Popen.returncode``. A timeout returns 124.
    """
    if not command:
        raise ValueError("watchdog command must not be empty")
    _validate_timeout_seconds(timeout_seconds)
    _validate_deadline_sentinel(deadline_sentinel)

    process = subprocess.Popen(command, start_new_session=True)
    try:
        status = process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        _terminate_process_group(process)
        _notify_timeout(source, step, timeout_seconds)
        return TIMEOUT_EXIT_CODE
    if deadline_sentinel is not None:
        deadline_sentinel.unlink()
    return status


def _parse_args(argv: Sequence[str]) -> argparse.Namespace:
    """Parse the watchdog's deliberately narrow command-line interface."""
    parser = argparse.ArgumentParser(
        description="bound one direct test build or run command",
    )
    parser.add_argument("--source", required=True)
    parser.add_argument("--step", required=True, choices=("build", "run"))
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
    )
    parser.add_argument("--deadline-sentinel", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    parsed = parser.parse_args(argv)
    if parsed.command[:1] == ["--"]:
        parsed.command = parsed.command[1:]
    if not parsed.command:
        parser.error("a command after -- is required")
    try:
        _validate_timeout_seconds(parsed.timeout_seconds)
    except ValueError as exc:
        parser.error(str(exc))
    return parsed


def _exit_with_child_status(status: int) -> int:
    """Return normal exits and reproduce signal exits for the shell caller."""
    if status >= 0:
        return status
    signum = -status
    if signum not in (signal.SIGKILL, signal.SIGSTOP):
        signal.signal(signum, signal.SIG_DFL)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signum})
    os.kill(os.getpid(), signum)
    return 128 + signum


def main(argv: Sequence[str] | None = None) -> int:
    """Run the requested command and expose its truthful terminal status."""
    parsed = _parse_args(sys.argv[1:] if argv is None else argv)
    status = run_command(
        parsed.command,
        source=parsed.source,
        step=parsed.step,
        timeout_seconds=parsed.timeout_seconds,
        deadline_sentinel=parsed.deadline_sentinel,
    )
    return _exit_with_child_status(status)


if __name__ == "__main__":
    raise SystemExit(main())
