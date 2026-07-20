#!/usr/bin/env python3
"""Supervise one direct command with a bounded process-group lifetime."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
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
_FORWARDED_SIGNALS = (signal.SIGINT, signal.SIGTERM)


@dataclass(frozen=True)
class Exited:
    """A successfully spawned child exited under its own control."""

    code: int


@dataclass(frozen=True)
class Signaled:
    """A successfully spawned child was reaped after signal death."""

    signo: int


@dataclass(frozen=True)
class TimedOut:
    """The watchdog deadline expired and process-group cleanup completed."""


@dataclass(frozen=True)
class Cancelled:
    """The watchdog caller received SIGINT or SIGTERM."""

    signo: int


@dataclass(frozen=True)
class HarnessError:
    """The watchdog could not establish a truthful child termination."""

    detail: str


Termination = Exited | Signaled | TimedOut | Cancelled | HarnessError


class _WatchdogCancellation(BaseException):
    """Carry one caller cancellation out of the blocking child wait."""

    def __init__(self, signum: int) -> None:
        self.signum = signum


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


def _forward_signal_and_cleanup(
    process: subprocess.Popen[object], signum: int
) -> None:
    """Forward caller cancellation, then force-reap the complete child group."""
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        process.wait()
        return

    deadline = time.monotonic() + TERMINATION_GRACE_SECONDS
    while time.monotonic() < deadline:
        # Reap the leader as soon as it exits. Descendants can keep the process
        # group alive after that point, so group existence remains the cleanup
        # condition rather than leader status alone.
        process.poll()
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            process.wait()
            return
        time.sleep(0.01)

    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def _validate_deadline_sentinel(deadline_sentinel: Path | None) -> None:
    """Fail before spawn unless the caller supplied a regular deadline sentinel."""
    if deadline_sentinel is None:
        return
    if not deadline_sentinel.is_file() or deadline_sentinel.is_symlink():
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
            "FATAL: classified: "
            f"{source}: {step} exceeded {timeout_seconds:g}s; "
            "terminating its process group",
            file=sys.stderr,
        )
    except (BrokenPipeError, OSError):
        pass


def validate_deadline_proof(
    termination: Termination,
    deadline_sentinel: Path | None,
) -> Termination:
    """Return ``termination`` only when its sentinel state agrees with its kind."""
    sentinel_present = deadline_sentinel is not None and (
        deadline_sentinel.exists() or deadline_sentinel.is_symlink()
    )
    sentinel_matches = (
        sentinel_present
        and deadline_sentinel is not None
        and deadline_sentinel.is_file()
        and not deadline_sentinel.is_symlink()
    )
    if isinstance(termination, TimedOut):
        if not sentinel_matches:
            return HarnessError(
                "timeout result disagrees with its missing deadline sentinel"
            )
        return termination
    if sentinel_present:
        return HarnessError(
            "non-timeout result disagrees with its remaining deadline sentinel"
        )
    return termination


def _clear_non_timeout_sentinel(
    termination: Termination,
    deadline_sentinel: Path | None,
) -> Termination:
    """Remove a valid sentinel for every result except a proven timeout."""
    if isinstance(termination, TimedOut) or deadline_sentinel is None:
        return validate_deadline_proof(termination, deadline_sentinel)
    try:
        deadline_sentinel.unlink(missing_ok=True)
    except OSError as exc:
        return HarnessError(f"could not clear deadline sentinel: {exc}")
    return validate_deadline_proof(termination, deadline_sentinel)


def run_command(
    command: Sequence[str],
    *,
    source: str,
    step: str,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
    deadline_sentinel: Path | None = None,
    cwd: Path | None = None,
) -> Termination:
    """Run ``command`` and return structured, signal-truthful termination.

    Args:
        command: Direct executable argv, without shell interpretation.
        source: Suite source displayed if the command times out.
        step: Either the suite's ``build`` or ``run`` step.
        timeout_seconds: Positive wall-clock ceiling for the command.
        deadline_sentinel: Pre-created file removed only after non-timeout exit.
        cwd: Optional child working directory.

    Returns:
        Exactly one structured termination kind. ``Signaled`` is created only
        from a negative wait status after successful spawn.
    """
    if not command:
        return _clear_non_timeout_sentinel(
            HarnessError("watchdog command must not be empty"),
            deadline_sentinel,
        )
    try:
        _validate_timeout_seconds(timeout_seconds)
        _validate_deadline_sentinel(deadline_sentinel)
    except (OSError, ValueError) as exc:
        return _clear_non_timeout_sentinel(
            HarnessError(str(exc)),
            deadline_sentinel,
        )

    process: subprocess.Popen[object] | None = None
    pending_signum: int | None = None
    previous_handlers: dict[int, signal.Handlers] = {}

    def request_cancellation(signum: int, _frame: object) -> None:
        """Record the first signal and leave the blocking wait exactly once."""
        nonlocal pending_signum
        # Python signal callbacks run serially on the main thread. Recording
        # first-signal precedence before raising also closes the small window
        # before the exception handler blocks further cancellation: a prompt
        # second signal observes this value and cannot raise through cleanup.
        if pending_signum is not None:
            return
        pending_signum = signum
        if process is None:
            return
        raise _WatchdogCancellation(signum)

    try:
        for signum in _FORWARDED_SIGNALS:
            previous_handlers[signum] = signal.getsignal(signum)
            signal.signal(signum, request_cancellation)
        try:
            try:
                process = subprocess.Popen(
                    command,
                    cwd=cwd,
                    start_new_session=True,
                )
            except OSError as exc:
                # Popen can report an exec/spawn error after a cancellation was
                # already delivered in its call. No child handle is available
                # to clean up, but cancellation remains the truthful terminal
                # status instead of being overwritten by the spawn exception.
                if pending_signum is not None:
                    return _clear_non_timeout_sentinel(
                        Cancelled(pending_signum), deadline_sentinel
                    )
                return _clear_non_timeout_sentinel(
                    HarnessError(f"could not spawn child: {command[0]}: {exc}"),
                    deadline_sentinel,
                )
            if pending_signum is not None:
                raise _WatchdogCancellation(pending_signum)
            try:
                status = process.wait(timeout=timeout_seconds)
            except subprocess.TimeoutExpired:
                _terminate_process_group(process)
                _notify_timeout(source, step, timeout_seconds)
                return validate_deadline_proof(TimedOut(), deadline_sentinel)
            termination: Termination
            if status < 0:
                # The leader is already reaped, but descendants may still own
                # its process group. Sweep them before exposing the signal.
                _terminate_process_group(process)
                termination = Signaled(-status)
            else:
                termination = Exited(status)
            return _clear_non_timeout_sentinel(termination, deadline_sentinel)
        except _WatchdogCancellation as cancellation:
            # The first callback already recorded precedence. Keep the handlers
            # live during cleanup so later managed signals are synchronously
            # consumed by their no-op path instead of becoming pending signals
            # that escape when the caller's dispositions are restored.
            _forward_signal_and_cleanup(process, cancellation.signum)
            return _clear_non_timeout_sentinel(
                Cancelled(cancellation.signum), deadline_sentinel
            )
    except Exception as exc:
        detail = f"watchdog internal failure: {exc}"
        if process is not None and process.poll() is None:
            try:
                _terminate_process_group(process)
            except Exception as cleanup_exc:
                detail += f"; process-group cleanup failed: {cleanup_exc}"
        return _clear_non_timeout_sentinel(
            HarnessError(detail), deadline_sentinel
        )
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


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


def _exit_with_termination(termination: Termination) -> int:
    """Map structured termination onto a truthful command-line process status."""
    if isinstance(termination, Exited):
        return termination.code
    if isinstance(termination, TimedOut):
        return TIMEOUT_EXIT_CODE
    if isinstance(termination, HarnessError):
        print(f"FATAL: watchdog: {termination.detail}", file=sys.stderr)
        return 70
    signum = termination.signo
    if signum not in (signal.SIGKILL, signal.SIGSTOP):
        signal.signal(signum, signal.SIG_DFL)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signum})
    os.kill(os.getpid(), signum)
    return 128 + signum


def main(argv: Sequence[str] | None = None) -> int:
    """Run the requested command and expose its truthful terminal status."""
    parsed = _parse_args(sys.argv[1:] if argv is None else argv)
    termination = run_command(
        parsed.command,
        source=parsed.source,
        step=parsed.step,
        timeout_seconds=parsed.timeout_seconds,
        deadline_sentinel=parsed.deadline_sentinel,
    )
    return _exit_with_termination(termination)


if __name__ == "__main__":
    raise SystemExit(main())
