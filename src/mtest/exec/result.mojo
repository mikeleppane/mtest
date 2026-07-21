"""The outcome of one supervised run.

`ProcessResult` is what `run_supervised` hands back: the raw captured bytes of
each stream, a per-stream truncation flag, a structured `Termination`, and the
wall duration.

The two streams are kept separate, and under the capture bound the bytes are
byte-exact: trailing spaces, empty arguments, and invalid UTF-8 all survive.
The truncation flags let a caller learn that a stream overflowed the capture
bound without rescanning the bytes. Keeping the bytes raw is what lets a
byte-exact test assert on them; a later rendering layer decodes them to
printable text through `config`'s `lossy_utf8`, which never crashes on invalid
sequences.
"""
from mtest.exec.termination import Termination


@fieldwise_init
struct ProcessResult(Copyable, Movable):
    """The captured streams, the termination, and the duration of one run.

    Owns the two capture buffers, so copies are explicit; holds no fds.
    """

    var stdout_bytes: List[UInt8]
    """The child's raw stdout, bounded by the capture limit."""
    var stderr_bytes: List[UInt8]
    """The child's raw stderr, bounded by the capture limit."""
    var stdout_truncated: Bool
    """True iff stdout overflowed the capture bound, so the middle was dropped
    and the truncation marker spliced into `stdout_bytes`."""
    var stderr_truncated: Bool
    """True iff stderr overflowed the capture bound, so the middle was dropped
    and the truncation marker spliced into `stderr_bytes`."""
    var termination: Termination
    """How the child ended: Exited / Signaled / TimedOut / SpawnFailed."""
    var duration_ms: Int
    """Wall time from fork to reap, in milliseconds."""
