#!/usr/bin/env python3
"""Supervise one direct command with a bounded process-group lifetime."""

from __future__ import annotations

import argparse
import codecs
import contextlib
from dataclasses import dataclass
import errno
import math
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import threading
import time
from typing import IO, TYPE_CHECKING, cast


if TYPE_CHECKING:
    from collections.abc import Callable, Mapping, Sequence
    from types import FrameType

    # Exactly what `signal.getsignal` hands back and `signal.signal` accepts:
    # the caller's own callback, or one of the integer dispositions.
    _SignalHandler = Callable[[int, FrameType | None], object] | int | None


# The per-step wall-clock ceiling. It bounds a single classified build or run so
# a hang is terminated rather than stalling CI. The integration aggregate compiles
# and runs many worker-pool files in one binary; on a slow, contended CI host that
# legitimate run needs well over five minutes, so the ceiling sits at fifteen to
# leave headroom above the real workload while still catching a genuine hang.
DEFAULT_TIMEOUT_SECONDS = 900.0
DEFAULT_CAPTURE_LIMIT_BYTES = 1024 * 1024
CAPTURE_TRUNCATION_MARKER = "\n[mtest-check: output truncated]\n"
TERMINATION_GRACE_SECONDS = 5.0
TIMEOUT_EXIT_CODE = 124
_FORWARDED_SIGNALS = (signal.SIGINT, signal.SIGTERM)
# One read of a captured pipe. A child that floods faster than the caller's
# terminal drains must never block on a full pipe, so the drainers read
# whatever is available rather than waiting for a fixed-size block.
_PIPE_CHUNK_BYTES = 65536
# The longest run of bytes a marker line may occupy. Anything longer cannot be
# a marker, so it is discarded rather than retained, which bounds the memory a
# flooding child can make the supervisor hold.
_MARKER_SCAN_LIMIT_BYTES = 65536
# The whole budget for finishing the drain after the child has been reaped. Its
# own buffered bytes are already in the pipe by then, so it expires only when
# something else stalls the drain: a leaked descendant still holding the write
# end, or a caller consumer that has stopped reading and left a drainer parked
# in a write. Either way this is output the supervisor deliberately stops
# waiting for rather than stalling every run behind it.
DRAIN_SETTLE_SECONDS = 2.0
# How long a drainer may block in one poll before it re-checks its stop flag.
_DRAIN_POLL_SECONDS = 0.05
# How long sealing one caller stream may wait out a write already in flight.
# A write to a stalled consumer never returns, so this wait must be bounded:
# the whole point of this supervisor is a bounded process-group lifetime, and a
# seal that could block forever would make the supervisor itself unkillable.
SEAL_ACQUIRE_SECONDS = 0.5
# How long the seal may wait for one already-finished drainer to be reaped.
# Only a thread that has left its loop is joined within this; one still parked
# in a write falls straight through, so the total wait stays bounded and small.
_SEAL_JOIN_SECONDS = 0.05


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


def _safe_exception_text(error: BaseException) -> str:
    """Render an exception without trusting user-defined ``__str__`` code."""
    try:
        return str(error)
    except BaseException as rendering_error:  # noqa: BLE001
        return (
            f"<{type(error).__name__} could not be rendered "
            f"({type(rendering_error).__name__})>"
        )


@dataclass(frozen=True)
class CapturedCommand:
    """One supervised command's structured termination and bounded output."""

    termination: Termination
    stdout: str
    stderr: str
    capture_complete: bool = True
    """Whether both child pipes reached EOF before bounded drain settlement."""


class _BoundedTextCapture:
    """Collect a fixed-size UTF-8 prefix from one drained child stream."""

    def __init__(self, limit_bytes: int) -> None:
        """Open one bounded capture.

        Args:
            limit_bytes: Maximum child-output bytes retained before the marker.
        """
        self._limit_bytes = limit_bytes
        self._retained = bytearray()
        self._retained_bytes = 0
        self._truncated = False

    @property
    def buffer(self) -> _BoundedTextCapture:
        """Expose this byte sink so pipe chunks are decoded only after capture."""
        return self

    def write(self, value: str | bytes) -> int:
        """Retain only the byte prefix that fits and report the full write accepted."""
        encoded = (
            value.encode("utf-8", errors="replace") if isinstance(value, str) else value
        )
        remaining = self._limit_bytes - self._retained_bytes
        retained = encoded[: max(0, remaining)]
        if retained:
            self._retained.extend(retained)
            self._retained_bytes += len(retained)
        if len(encoded) > len(retained):
            self._truncated = True
        return len(value)

    def flush(self) -> None:
        """Match the text-stream interface; capture needs no flushing."""

    def finish(self) -> str:
        """Return retained text plus one explicit marker when bytes were omitted."""
        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        # When the byte cap cut through a scalar, `final=False` leaves only that
        # incomplete terminal sequence buffered instead of inventing U+FFFD.
        # Internal invalid byte sequences are still represented explicitly.
        text = decoder.decode(bytes(self._retained), final=not self._truncated)
        return text + (CAPTURE_TRUNCATION_MARKER if self._truncated else "")


class MarkerRetention:
    """Bounded retention of one marker line drained from a child's stdout.

    The watchdog keeps at most a single line — the last complete one beginning
    with `prefix` — so supervising a child that floods its stdout costs a fixed
    amount of memory rather than growing with the output. `freeze` closes the
    capture, so a drainer that outlives the supervisor's return cannot overwrite
    the marker under the caller's read of `text`.
    """

    def __init__(self, prefix: str) -> None:
        """Open an empty capture for one marker prefix.

        Args:
            prefix: The line prefix a retained marker must start with.
        """
        self.prefix = prefix
        """The line prefix a retained marker must start with."""
        self.text = ""
        """The last complete matching line, newline included; empty when none."""
        self._lock = threading.Lock()
        self._frozen = False
        self._capture_complete = True

    def record(self, line: str) -> None:
        """Retain one complete marker line unless the capture is already frozen.

        Args:
            line: The matching line, newline included.
        """
        # The lock only ever spans one attribute assignment, so `freeze` can
        # never wait on I/O to acquire it.
        with self._lock:
            if self._frozen:
                return
            self.text = line

    def freeze(self) -> None:
        """Close the capture so `text` can be read without racing a drainer."""
        with self._lock:
            self._frozen = True

    def mark_capture_incomplete(self) -> None:
        """Record that at least one child pipe did not reach end of file."""
        with self._lock:
            self._capture_complete = False

    @property
    def capture_complete(self) -> bool:
        """Whether every child pipe reached end of file before capture closed."""
        with self._lock:
            return self._capture_complete


class _WatchdogCancellation(BaseException):
    """Carry one caller cancellation out of the blocking child wait."""

    def __init__(self, signum: int) -> None:
        self.signum = signum


class _StreamTee:
    """Forward drained child bytes to one caller stream until it is sealed.

    Owns the only writer to that stream for the child's lifetime. A write to a
    caller stream can block indefinitely — a pipe whose consumer stopped
    reading, a terminal under flow control — so sealing must not be expressed as
    an unbounded wait for the writing drainer. `seal` therefore refuses further
    writes immediately and only *bounds* how long it waits out a write already
    in flight.
    """

    def __init__(self, stream: object) -> None:
        """Wrap one caller stream, preferring its byte buffer.

        Args:
            stream: The caller's original `sys.stdout` or `sys.stderr`, or None
                when the interpreter has none.
        """
        # The caller's stream is duck-typed on purpose: under a redirect
        # `sys.stdout` is any object with `write`. These casts record the shape
        # production always has without adding a runtime check.
        #
        # Note what is NOT covered: the binary arm in `write` catches OSError and
        # ValueError only, so a `.buffer` exposing `write` but not `flush` raises
        # AttributeError out of the drainer thread. Every stream this repo passes
        # (`sys.stdout`, `io.StringIO`, `_TextOverBytes`) either has `flush` or
        # has no `.buffer` at all, so the text arm handles it. The gap is real
        # but pre-existing; do not read these casts as closing it.
        self._binary = cast("IO[bytes] | None", getattr(stream, "buffer", None))
        self._text = cast(
            "IO[str] | None",
            stream if self._binary is None and hasattr(stream, "write") else None,
        )
        self._lock = threading.Lock()
        self._sealed = threading.Event()

    @property
    def sealed(self) -> bool:
        """Whether this tee has stopped accepting new writes."""
        return self._sealed.is_set()

    def write(self, chunk: bytes) -> None:
        """Emit one drained chunk, or drop it once the stream is unusable.

        Args:
            chunk: Raw bytes read from the child's pipe.
        """
        # Checked before the lock as well as under it, so a seal that could not
        # take the lock still stops the next write from starting.
        if self._sealed.is_set():
            return
        with self._lock:
            if self._sealed.is_set():
                return
            if self._binary is not None:
                try:
                    self._binary.write(chunk)
                    self._binary.flush()
                except (OSError, ValueError):
                    # The contributor's stream is gone. The drainer keeps
                    # reading regardless, so the child cannot deadlock on a
                    # pipe nobody is emptying.
                    self._binary = None
                return
            if self._text is not None:
                # A caller stream without a byte buffer — a redirected StringIO,
                # say — still receives the bytes rather than losing them.
                try:
                    self._text.write(chunk.decode("utf-8", errors="replace"))
                    self._text.flush()
                except (OSError, ValueError, AttributeError):
                    self._text = None

    def seal(self) -> bool:
        """Refuse every later write, waiting a bounded time for one in flight.

        Returns:
            Whether the in-flight write was waited out. False means a drainer
            is still parked inside a write to a caller stream that is not
            draining; that one chunk may still land, but no further chunk can,
            and the supervisor is never made to wait on it.
        """
        self._sealed.set()
        if not self._lock.acquire(timeout=SEAL_ACQUIRE_SECONDS):
            return False
        try:
            self._binary = None
            self._text = None
        finally:
            self._lock.release()
        return True


@dataclass(frozen=True)
class _DrainState:
    """The live drainers for one captured child, and how to stop them."""

    threads: tuple[threading.Thread, ...]
    """The prepared drainer threads, in stdout-then-stderr order."""
    tees: tuple[_StreamTee, ...]
    """The caller-stream writers those drainers own, in the same order."""
    stop: threading.Event
    """Set to make every drainer leave its poll loop at the next tick."""
    retention: MarkerRetention | None
    """The marker capture the stdout drainer feeds, frozen when sealing."""
    sources: tuple[IO[bytes], ...]
    """The child pipe read ends those drainers own, in the same order.

    Held so that a drainer abandoned inside a write to a stalled caller stream
    can still be released: closing its source makes its next read fail, so the
    thread ends as soon as that write returns instead of living forever.
    """
    eof_events: tuple[threading.Event, ...] = ()
    """Per-stream proof that the drainer observed end of file."""


def _tee_stream(
    source: IO[bytes],
    tee: _StreamTee,
    retention: MarkerRetention | None,
    stop: threading.Event,
    reached_eof: threading.Event | None = None,
    read_chunk: Callable[[int, int], bytes] = os.read,
) -> None:
    """Drain one captured pipe onto a caller stream, retaining a marker.

    Polls rather than blocking in a read so a stop request is honored within
    one tick even while a leaked descendant still holds the pipe's write end.

    Args:
        source: The child's pipe read end. Closed before returning.
        tee: The caller-stream writer this pipe's bytes are forwarded to.
        retention: Marker state to update in place, or None to only tee.
        stop: Shared flag that ends the drain without waiting for end of file.
        reached_eof: Optional proof set only after a zero-length pipe read.
        read_chunk: Pipe-read operation, injectable for an error-path proof.
    """
    prefix = b"" if retention is None else retention.prefix.encode("utf-8")
    pending = b""
    discarding = False
    try:
        descriptor = source.fileno()
    except (OSError, ValueError):
        return
    # `poll` rather than `select`: CPython's `select.select` raises ValueError
    # for a descriptor at or above FD_SETSIZE, and a caller holding a thousand
    # open files would otherwise turn that into an instant, silent end of
    # stream that loses the whole child's output. `poll` has no such ceiling.
    poller = select.poll()
    poller.register(descriptor, select.POLLIN | select.POLLHUP | select.POLLERR)
    try:
        while not stop.is_set():
            try:
                events = poller.poll(_DRAIN_POLL_SECONDS * 1000.0)
            except InterruptedError:
                continue
            except (OSError, ValueError):
                break
            if not events:
                continue
            try:
                chunk = read_chunk(descriptor, _PIPE_CHUNK_BYTES)
            except InterruptedError:
                continue
            except (OSError, ValueError):
                break
            if not chunk:
                if reached_eof is not None:
                    reached_eof.set()
                break
            # Each stream is drained by its own thread, so the interleaving of
            # stdout against stderr at a shared terminal is now decided by
            # thread scheduling rather than by the kernel's write ordering: a
            # read boundary can split a line and let the other stream appear
            # mid-line. That is inherent to draining two pipes concurrently,
            # which is what capturing the marker requires; it is not a defect.
            tee.write(chunk)
            if retention is None:
                continue
            pending += chunk
            while True:
                break_at = pending.find(b"\n")
                if break_at < 0:
                    break
                line = pending[: break_at + 1]
                pending = pending[break_at + 1 :]
                if not discarding and line.startswith(prefix):
                    # Through `record`, never by assignment: this thread can
                    # outlive the supervisor's return, and the capture refuses
                    # a late marker rather than racing the caller's read.
                    retention.record(line.decode("utf-8", errors="replace"))
                discarding = False
            if len(pending) > _MARKER_SCAN_LIMIT_BYTES:
                pending = b""
                discarding = True
    finally:
        with contextlib.suppress(OSError, ValueError):
            source.close()


def _prepare_drainers(
    process: subprocess.Popen[bytes],
    retention: MarkerRetention,
) -> _DrainState:
    """Prepare one drainer per captured pipe without starting a thread.

    Args:
        process: The freshly spawned child owning both captured pipes.
        retention: Marker state the stdout drainer updates in place.

    Returns:
        The prepared drainers, their caller-stream writers, and their stop flag.
    """
    stop = threading.Event()
    targets = (
        (process.stdout, sys.stdout, retention),
        (process.stderr, sys.stderr, None),
    )
    threads: list[threading.Thread] = []
    tees: list[_StreamTee] = []
    sources: list[IO[bytes]] = []
    eof_events: list[threading.Event] = []
    for source, stream, marker in targets:
        if source is None:
            continue
        tee = _StreamTee(stream)
        reached_eof = threading.Event()
        thread = threading.Thread(
            target=_tee_stream,
            args=(source, tee, marker, stop, reached_eof),
            daemon=True,
        )
        threads.append(thread)
        tees.append(tee)
        sources.append(source)
        eof_events.append(reached_eof)
    return _DrainState(
        tuple(threads),
        tuple(tees),
        stop,
        retention,
        tuple(sources),
        tuple(eof_events),
    )


def _start_drainers(state: _DrainState) -> None:
    """Start every prepared drainer after its state is caller-owned."""
    for thread in state.threads:
        thread.start()


def _await_drainer_eof(state: _DrainState | None) -> bool:
    """Give every drainer a bounded opportunity to observe end of file."""
    if state is None:
        return True
    deadline = time.monotonic() + DRAIN_SETTLE_SECONDS
    for thread in state.threads:
        if thread.ident is None:
            continue
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        thread.join(remaining)
    return all(reached_eof.is_set() for reached_eof in state.eof_events)


def _settle_drainers(state: _DrainState | None) -> None:
    """Finish the drain within a fixed budget, then seal both caller streams.

    Waits only briefly for a natural end of file: once the child is reaped its
    buffered bytes are already in the pipe, so a longer wait would only be
    waiting on a leaked descendant's future output, which this supervisor does
    not owe the caller. Idempotent, so a cancellation that interrupts one call
    is fully settled by the next.

    Args:
        state: The live drainers, or None when the child was not captured.
    """
    _await_drainer_eof(state)
    _seal_drainers(state)


def _seal_drainers(state: _DrainState | None) -> None:
    """Stop every drainer, shut its caller stream, and close the marker capture.

    Bounded by construction: the stop flag and the marker freeze never wait on
    I/O, and each tee's seal waits at most `SEAL_ACQUIRE_SECONDS` for a write
    already in flight. A drainer parked in a write to a stalled consumer is
    never *waited on*, because no path through `run_command` may become
    unkillable — but it is no longer simply forgotten either. A seal that could
    not take the lock means exactly that, and this function then closes the
    child pipe that drainer owns, so the thread ends the moment its in-flight
    write returns instead of parking forever on a descriptor nobody will read
    again. Without that, every such call leaked one thread and one descriptor,
    and a caller invoking `run_command` in a loop exhausted both.

    The close is safe against the drainer's own use of the pipe: the tee is
    sealed first, so any bytes a racing read produces are dropped anyway, and
    `_tee_stream` treats a failing read as end of stream and returns through
    its own `finally`, where a second close is tolerated.

    Idempotent.

    Args:
        state: The live drainers, or None when the child was not captured.
    """
    if state is None:
        return
    if state.retention is not None and not all(
        reached_eof.is_set() for reached_eof in state.eof_events
    ):
        # Only an observed zero-length read proves a pipe complete. A live
        # drainer, a poll/read error, or forced settlement can all omit bytes;
        # semantic callers must know that and fail closed.
        state.retention.mark_capture_incomplete()
    state.stop.set()
    # Freeze BEFORE sealing the tees, not after. A drainer already past its
    # stop check reads one more chunk; sealing first means that chunk's bytes
    # are dropped from the tee while its marker is still recorded, so the
    # reported last module names a line the user never saw. Freezing first
    # keeps the two consistent, and costs nothing on the normal path, where
    # the drainers have hit EOF and been joined before this runs. Ordering
    # matters most when a tee's seal blocks: freeze would otherwise wait out
    # SEAL_ACQUIRE_SECONDS behind it, widening the window it is closing.
    if state.retention is not None:
        state.retention.freeze()
    for index, tee in enumerate(state.tees):
        thread_started = (
            index >= len(state.threads) or state.threads[index].ident is not None
        )
        if tee.seal() and thread_started:
            continue
        # This drainer is parked in a write to a caller stream that is not
        # draining. Release the resources it holds rather than abandoning them.
        if index < len(state.sources):
            with contextlib.suppress(OSError, ValueError):
                state.sources[index].close()
    # A brief, bounded join so a drainer that has already finished is reaped
    # here rather than left for the interpreter. Threads still parked in a
    # write fall through untouched; the supervisor never waits on them.
    for thread in state.threads:
        if thread.ident is not None:
            thread.join(_SEAL_JOIN_SECONDS)


def _signal_group(pid: int, signum: int) -> bool:
    """Signal one owned process group, reporting whether it still exists.

    `ESRCH` is the portable "no such group". Darwin adds a second spelling for
    the same fact: `killpg` reports `EPERM` when every remaining member is a
    zombie, because a zombie can no longer be sent a signal. This supervisor
    created the group and owns every member, so `EPERM` cannot mean a
    permission boundary here — a caller that may not signal its own children
    could not have spawned them. Treating it as a hard error let a Ctrl-C that
    raced the child's exit replace a truthful `Cancelled` or `Signaled` with a
    `HarnessError`, so the classified harness returned internal exit 70 for a
    run that had in fact been cancelled cleanly.

    Args:
        pid: The group leader's pid, which is also the process-group id.
        signum: The signal to send, or `0` to probe for the group's existence.

    Returns:
        True when the signal was delivered, False when the group is gone —
        either fully reaped or, on Darwin, zombie-only.
    """
    try:
        os.killpg(pid, signum)
    except ProcessLookupError:
        return False
    except PermissionError:
        # Darwin's zombie-only group. See above for why this is not a
        # permission failure for a group this supervisor owns.
        return False
    return True


def _wait_for_exit_without_reaping(
    process: subprocess.Popen[bytes],
    timeout_seconds: float,
) -> bool:
    """Observe leader exit while retaining its PID as process-group ownership.

    Linux `waitid(WNOWAIT)` and Darwin kqueue process events report exit
    readiness without reaping. The leader therefore remains a zombie and pins
    both its PID and process-group ID until this supervisor sweeps descendants.

    Args:
        process: Live child whose session and process group this caller owns.
        timeout_seconds: Maximum wait for an exit notification.

    Returns:
        True when the leader exited, False when the timeout elapsed first.
    """
    platform_name = os.uname().sysname
    if platform_name == "Linux":
        deadline = time.monotonic() + timeout_seconds
        while True:
            result = os.waitid(
                os.P_PID,
                process.pid,
                os.WEXITED | os.WNOHANG | os.WNOWAIT,
            )
            if result is not None:
                return True
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            time.sleep(min(0.01, remaining))
    if platform_name == "Darwin":
        queue = select.kqueue()  # type: ignore[attr-defined]
        try:
            event = select.kevent(  # type: ignore[attr-defined]
                process.pid,
                filter=select.KQ_FILTER_PROC,  # type: ignore[attr-defined]
                flags=select.KQ_EV_ADD  # type: ignore[attr-defined]
                | select.KQ_EV_ONESHOT,  # type: ignore[attr-defined]
                fflags=select.KQ_NOTE_EXIT,  # type: ignore[attr-defined]
            )
            deadline = time.monotonic() + timeout_seconds
            changes = [event]
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                try:
                    events = queue.control(changes, 1, remaining)
                except InterruptedError:
                    continue
                changes = []
                if not events:
                    continue
                observed = events[0]
                if observed.flags & select.KQ_EV_ERROR:  # type: ignore[attr-defined]
                    error_number = observed.data
                    if error_number == errno.ESRCH:
                        return True
                    raise OSError(error_number, os.strerror(error_number))
                if observed.fflags & select.KQ_NOTE_EXIT:  # type: ignore[attr-defined]
                    return True
                raise RuntimeError("Darwin process event did not report exit")
        finally:
            queue.close()
    raise RuntimeError(f"unsupported watchdog platform: {platform_name}")


def _terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    """Terminate a timed-out process group and wait for its leader."""
    if not _signal_group(process.pid, signal.SIGTERM):
        process.wait()
        return

    # The leader can exit from SIGTERM before a descendant that inherited its
    # group. Keep the full grace period, then sweep that group even if the
    # leader has already exited and been reaped.
    time.sleep(TERMINATION_GRACE_SECONDS)

    _signal_group(process.pid, signal.SIGKILL)
    process.wait()


def _forward_signal_and_cleanup(process: subprocess.Popen[bytes], signum: int) -> None:
    """Forward a signal, force-reap the process group, and its leader."""
    if not _signal_group(process.pid, signum):
        process.wait()
        return

    _wait_for_exit_without_reaping(process, TERMINATION_GRACE_SECONDS)
    # Whether the leader exited or ignored the forwarded signal, it still pins
    # the group ID here: no wait operation above made that ID reusable.
    _signal_group(process.pid, signal.SIGKILL)
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
    with contextlib.suppress(BrokenPipeError, OSError, ValueError):
        print(
            f"FATAL: {source}: {step} exceeded {timeout_seconds:g}s; "
            "terminating its process group",
            file=sys.stderr,
        )


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
    env: Mapping[str, str] | None = None,
    marker_retention: MarkerRetention | None = None,
) -> Termination:
    """Run ``command`` and return structured, signal-truthful termination.

    Args:
        command: Direct executable argv, without shell interpretation.
        source: Suite source displayed if the command times out.
        step: Either the suite's ``build`` or ``run`` step.
        timeout_seconds: Positive wall-clock ceiling for the command.
        deadline_sentinel: Pre-created file removed only after non-timeout exit.
        cwd: Optional child working directory.
        env: Optional complete child environment.
        marker_retention: When given, both child streams become pipes that
            concurrent drainers tee to the caller's own stdout and stderr while
            retaining the last complete marker line. Updated in place.

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

    process: subprocess.Popen[bytes] | None = None
    process_group_cleaned = False
    cleanup_in_progress = False
    pending_signum: int | None = None
    previous_handlers: dict[signal.Signals, _SignalHandler] = {}
    drain_state: _DrainState | None = None
    captured = subprocess.PIPE if marker_retention is not None else None

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
        # An exception already being handled will reach the supervisor's
        # backstop without help. Raising through that handler could skip the
        # cleanup it is about to perform, including in the small interval
        # before `cleanup_in_progress` can be set.
        if process is None or cleanup_in_progress or sys.exception() is not None:
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
                    env=env,
                    start_new_session=True,
                    stdout=captured,
                    stderr=captured,
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
            if marker_retention is not None:
                # Both pipes must be draining before any blocking wait: a child
                # that outruns a 64 KiB pipe buffer would otherwise block on
                # write while the supervisor blocks on wait.
                drain_state = _prepare_drainers(process, marker_retention)
                _start_drainers(drain_state)
            if pending_signum is not None:
                # TRY301 is suppressed here: this raise IS the cancellation
                # path, caught by the arm that closes this try. Abstracting it
                # into an inner function would only hide the control flow.
                raise _WatchdogCancellation(pending_signum)  # noqa: TRY301
            if not _wait_for_exit_without_reaping(process, timeout_seconds):
                cleanup_in_progress = True
                try:
                    _terminate_process_group(process)
                    process_group_cleaned = True
                    try:
                        _settle_drainers(drain_state)
                    except _WatchdogCancellation:
                        # The group is already swept and the deadline sentinel
                        # is the timeout's standing proof, so a cancellation in
                        # the final drain cannot un-time-out an ended child.
                        _seal_drainers(drain_state)
                    _notify_timeout(source, step, timeout_seconds)
                    return validate_deadline_proof(TimedOut(), deadline_sentinel)
                finally:
                    # Keep deadline attribution atomic through its diagnostic
                    # and proof validation. Managed signals are recorded during
                    # this interval but cannot replace a timeout already proven.
                    cleanup_in_progress = False
            capture_complete_before_sweep = _await_drainer_eof(drain_state)
            # The unreaped leader still pins this process-group ID. Sweep now,
            # before the wait below releases ownership and allows PID reuse.
            cleanup_in_progress = True
            try:
                _signal_group(process.pid, signal.SIGKILL)
                status = process.wait()
                process_group_cleaned = True
            finally:
                cleanup_in_progress = False
            termination: Termination = (
                Signaled(-status) if status < 0 else Exited(status)
            )
            if not capture_complete_before_sweep and marker_retention is not None:
                marker_retention.mark_capture_incomplete()
            if pending_signum is not None:
                raise _WatchdogCancellation(pending_signum)  # noqa: TRY301
            # Settle inside this try, never in the `finally`: the drain can wait
            # seconds on a leaked descendant, and a caller signal in that window
            # must reach the cancellation arm below rather than escaping as an
            # unhandled BaseException past the caller's own except clauses.
            _settle_drainers(drain_state)
            return _clear_non_timeout_sentinel(termination, deadline_sentinel)
        except _WatchdogCancellation as cancellation:
            # The first callback already recorded precedence. Keep the handlers
            # live during cleanup so later managed signals are synchronously
            # consumed by their no-op path instead of becoming pending signals
            # that escape when the caller's dispositions are restored. That also
            # makes this settle safe: `pending_signum` is set, so the callback
            # returns without raising and cannot re-enter this arm.
            #
            # `process` cannot be None here: the only source of this exception is
            # `request_cancellation`, which returns without raising while
            # `process` is still None, and the explicit raise above runs only
            # after the spawn has been assigned. The cast states that invariant
            # without adding a branch; if it were ever violated the attribute
            # access inside would still fall to the internal-failure arm below,
            # exactly as it does today.
            if not process_group_cleaned:
                _forward_signal_and_cleanup(
                    cast("subprocess.Popen[bytes]", process), cancellation.signum
                )
                process_group_cleaned = True
            _settle_drainers(drain_state)
            return _clear_non_timeout_sentinel(
                Cancelled(cancellation.signum), deadline_sentinel
            )
    # BLE001 is suppressed on both arms below: this is the supervisor's
    # outermost boundary. Anything escaping here wedges the gate that spawned
    # it, so every exception must become a HarnessError, and a failure inside
    # cleanup must not replace the detail that caused it.
    except Exception as exc:  # noqa: BLE001
        cleanup_failure: Exception | None = None
        if process is not None and not process_group_cleaned:
            cleanup_in_progress = True
            try:
                _terminate_process_group(process)
                process_group_cleaned = True
            except Exception as cleanup_exc:  # noqa: BLE001
                cleanup_failure = cleanup_exc
            finally:
                cleanup_in_progress = False
        detail = "watchdog internal failure: " + _safe_exception_text(exc)
        if cleanup_failure is not None:
            detail += "; process-group cleanup failed: " + _safe_exception_text(
                cleanup_failure
            )
        return _clear_non_timeout_sentinel(HarnessError(detail), deadline_sentinel)
    finally:
        # Restore the caller's dispositions before the backstop seal. A managed
        # handler that outlived its `try` would raise `_WatchdogCancellation`
        # from a `finally` with no arm left to catch it, so nothing may run here
        # under one. The seal below is bounded, not instantaneous — it can wait
        # up to `SEAL_ACQUIRE_SECONDS` per stream on a write already in flight —
        # but with the caller's own dispositions back in force that wait stays
        # interruptible, and a signal during it terminates as the caller asked.
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        _seal_drainers(drain_state)


def run_captured_command(
    command: Sequence[str],
    *,
    source: str,
    step: str,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
    capture_limit_bytes: int = DEFAULT_CAPTURE_LIMIT_BYTES,
) -> CapturedCommand:
    """Run one process group and retain only bounded stdout and stderr prefixes.

    Args:
        command: Direct executable argv, without shell interpretation.
        source: Source label displayed if the command times out.
        step: Work label displayed if the command times out.
        timeout_seconds: Positive wall-clock ceiling for the process group.
        cwd: Optional child working directory.
        env: Optional complete child environment.
        capture_limit_bytes: Maximum retained bytes for each child stream.

    Returns:
        Structured termination plus bounded stdout and stderr.

    Raises:
        ValueError: If ``capture_limit_bytes`` is not positive.
    """
    if capture_limit_bytes <= 0:
        raise ValueError("capture limit must be greater than zero")
    stdout = _BoundedTextCapture(capture_limit_bytes)
    stderr = _BoundedTextCapture(capture_limit_bytes)
    retention = MarkerRetention("\0mtest-captured-command-no-marker")
    with tempfile.TemporaryDirectory(prefix="mtest-command-watchdog-") as raw:
        sentinel = Path(raw) / "deadline"
        sentinel.touch()
        with (
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            termination = run_command(
                command,
                source=source,
                step=step,
                timeout_seconds=timeout_seconds,
                deadline_sentinel=sentinel,
                cwd=cwd,
                env=env,
                marker_retention=retention,
            )
    return CapturedCommand(
        termination,
        stdout.finish(),
        stderr.finish(),
        capture_complete=retention.capture_complete,
    )


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
