"""The live-writing machine-stream reporter: `JsonStreamReporter`.

Where `json_stream` is the pure serializer turning one `Event` into one NDJSON
line, this is its sink: a `Reporter` that owns one resolved destination
descriptor and writes each serialized line to it live, as the session emits
events. It is the machine twin of `ConsoleReporter` — same `handle` seam,
different medium — and the one place in the report layer that performs I/O.

Three properties define it:

- Header first. Construction of an active reporter writes the frozen
  `stream_header(version)` line before any event, so a consumer sees the
  version on line 1.
- A write-all loop. Every line is drained through a retry loop that advances on
  partial writes and retries `EINTR`; the reporter never assumes one `write`
  empties the buffer.
- A status latch. On any write failure the reporter records the failure and the
  `errno`, and every later `handle` is a no-op that neither writes nor raises.
  The concrete `status()` accessor sits outside the `Reporter` trait so an
  owner can poll the latch and treat a dead stream as fatal, while `handle`
  itself stays total and non-raising per the trait.

An inert reporter, from `inert()`, is the no-`--json` shape: it owns no
descriptor, writes nothing, emits no header, and never latches. It exists so
the session's reporter composition can carry a stream slot at a fixed tuple
position whether or not `--json` was requested.

Descriptor ownership stays with the caller: `open_json_fd` opens a path and
`close_json_fd` closes it, and `main` closes what it opened after the session.
The reporter only borrows the descriptor, which keeps the type trivially
`Copyable, Movable` — an fd is an integer — with no double-close hazard.

The write and create/close syscalls, and the `errno` reading that classifies
their failures, are raw platform operations from `mtest.platform.stream`. They
are imported from that submodule directly rather than through the platform
package's public surface, so the raw libc `write` declaration reaches only this
one report module — the layer that already carried it — and not every module
that merely wants a process id. This module keeps only the policy: the retrying
write-all loop, the failure latch, the error messages, and the `EINTR` rules.
"""
from mtest.model import Event
from mtest.platform.stream import (
    close_fd,
    create_truncate_fd,
    errno_now,
    write_fd,
)
from mtest.report.json_stream import serialize_event, stream_header
from mtest.report.reporter import Reporter

comptime _EINTR = 4
"""`errno` for an interrupted syscall — a `write` to retry, not a failure."""


def open_json_fd(path: String) raises -> Int:
    """Open `path` as a report destination, truncating it; return the fd.

    Opens write-only, creating the file if absent and truncating it if present.
    The caller owns the returned descriptor and must `close_json_fd` it.

    Args:
        path: The destination file to create or truncate.

    Returns:
        The open descriptor.

    Raises:
        Error: When `creat(2)` failed — a missing parent directory that slipped
            past parse-time validation, a permission denial, or descriptor
            exhaustion. The message names the errno. The caller resolves this
            to the internal-error exit code, a pre-run environment failure.
    """
    var fd = create_truncate_fd(path)
    if fd < 0:
        var err = errno_now()
        raise Error(
            "report: could not open --json destination '"
            + path
            + "' (errno "
            + String(err)
            + ")"
        )
    return fd


def close_json_fd(fd: Int) -> Bool:
    """Close a descriptor opened by `open_json_fd`.

    Only an owned `--json PATH` file reaches this call; `main` gates it on
    `json_owns_fd`, since `--json -` writes to the inherited stdout, which the
    process never closes on itself. On such a file a deferred write error can
    surface only at `close`: a quota- or network-backed filesystem may buffer
    the byte-drained writes and report `ENOSPC` or `EIO` only when the
    descriptor is closed. That is actionable, because the machine report was
    not durably committed, so the caller presents this to the exit-code
    resolver as an artifact-delivery failure, exactly as a live write failure
    is. This reporter reports the fact and never transforms a code itself. The
    stream's own live write latch is independent of this result.

    `EINTR` is not a failure: on Linux a close interrupted by a signal has
    still released the descriptor, and retrying would risk double-closing a
    reused fd, so a signal landing mid-close must not escalate a clean run.
    This mirrors the live write path, which treats `EINTR` as retry.

    Args:
        fd: The descriptor to close. Not used again by the caller.

    Returns:
        Whether the close reported a genuine delivery failure.
    """
    if close_fd(fd) == 0:
        return False
    return errno_now() != _EINTR


@fieldwise_init
struct StreamStatus(Copyable, Movable):
    """The pollable health of a `JsonStreamReporter`'s destination.

    `failed` is the latch: once true it stays true. `errno` is the captured
    cause of the first failed write — 0 when the stream never failed, and also
    0 when a write reported no progress rather than an error. `context` names
    what was being written when the latch tripped, for a diagnostic.
    """

    var failed: Bool
    """Whether the stream has latched a write failure and gone silent."""
    var errno: Int
    """The `errno` captured at the first failed write; 0 when clean."""
    var context: String
    """What was being written when the latch tripped ("" when clean)."""


struct JsonStreamReporter(Reporter):
    """A `Reporter` that writes each serialized event live to one descriptor.

    Holds a borrowed destination fd and a failure latch. Construction of an
    active reporter writes the header line; each `handle` serializes the event
    and writes the line plus a newline through the write-all loop. On any write
    failure the reporter latches and goes silent. `Copyable, Movable`, since
    every field is trivial or an owned `String`, so it composes into the
    reporter tuple.
    """

    var _fd: Int
    """The destination descriptor, `-1` when inert; borrowed, never closed."""
    var _active: Bool
    """Whether this reporter writes at all; `False` is the inert shape."""
    var _failed: Bool
    """The latch: set on the first write failure, then every `handle` no-ops."""
    var _errno: Int
    """The `errno` captured when the latch tripped; 0 while clean."""
    var _context: String
    """What was being written when the latch tripped ("" while clean)."""

    def __init__(out self, fd: Int, version: String, active: Bool):
        """Construct a reporter over `fd`; an active one writes the header now.

        Args:
            fd: The destination descriptor (borrowed; the caller closes it).
            version: The mtest version for the header's `generator` field.
            active: Whether to write; `False` yields an inert reporter that
                emits nothing and never latches.
        """
        self._fd = fd
        self._active = active
        self._failed = False
        self._errno = 0
        self._context = String("")
        if active:
            self._emit(stream_header(version), "stream_header")

    @staticmethod
    def inert() -> Self:
        """The no-`--json` reporter: owns no descriptor, writes nothing."""
        return Self(-1, "", False)

    def handle(mut self, e: Event):
        """Serialize `e` and write its NDJSON line.

        A no-op when inert or already latched: the reporter never writes again
        after a failure.

        Args:
            e: The event to serialize and write.
        """
        if not self._active or self._failed:
            return
        self._emit(serialize_event(e), "event")

    def status(self) -> StreamStatus:
        """The pollable latch state, callable outside the `Reporter` trait.

        An owner polls this after each dispatch to learn whether the stream's
        destination died mid-run; a latched failure is the fatal-abort signal.
        """
        return StreamStatus(self._failed, self._errno, self._context)

    def _emit(mut self, line: String, context: String):
        """Write `line` and a trailing newline, latching on any failure.

        The newline is skipped when the line itself failed, so a latched
        reporter writes nothing further.

        Args:
            line: The complete line to write, without its newline.
            context: What is being written, recorded if the latch trips.
        """
        if not self._write_all(line, context):
            return
        _ = self._write_all("\n", context)

    def _write_all(mut self, s: String, context: String) -> Bool:
        """Drain `s` to the descriptor, retrying partial writes and `EINTR`.

        Never assumes one `write` empties the buffer: it advances by the
        returned count on a short write and retries an `EINTR`. A non-`EINTR`
        error, or a write reporting no progress with bytes still pending,
        latches the reporter.

        Args:
            s: The bytes to drain, as a string.
            context: What is being written, recorded if the latch trips.

        Returns:
            `True` when every byte was written, `False` after latching a
            failure.
        """
        var b = s.as_bytes()
        var total = len(b)
        var offset = 0
        while offset < total:
            # SAFETY: `b` borrows `s`'s bytes for the whole loop (`s` is a live
            # argument, so its buffer outlives every iteration). `offset` is in
            # `[0, total)` every iteration, so `unsafe_ptr() + offset` stays
            # inside the `total`-byte initialized buffer, and the length passed
            # is exactly the remaining `total - offset` bytes; the derived
            # pointer does not escape and `write_fd` reads through it and retains
            # nothing.
            var n = write_fd(self._fd, b.unsafe_ptr() + offset, total - offset)
            if n < 0:
                var err = errno_now()
                if err == _EINTR:
                    continue
                self._latch(err, context)
                return False
            if n == 0:
                # A zero write with bytes still pending makes no progress; treat
                # it as a failed destination rather than spin forever.
                self._latch(0, context)
                return False
            offset += n
        _ = b
        return True

    def _latch(mut self, err: Int, context: String):
        """Record the first write failure and go silent for the rest of the run.

        Later calls are ignored, so the latch keeps the cause of the first
        failure rather than the most recent one.

        Args:
            err: The `errno` captured at the failure, or 0 when the write
                reported no progress rather than an error.
            context: What was being written when the latch tripped.
        """
        if not self._failed:
            self._failed = True
            self._errno = err
            self._context = context.copy()
