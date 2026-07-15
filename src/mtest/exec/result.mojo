"""The outcome of one supervised run (Layer 3).

`ProcessResult` is what `run_supervised` hands back: the raw captured bytes of
each stream (kept SEPARATE and, under the capture bound, byte-exact — trailing
spaces, empty arguments, and invalid UTF-8 all survive), a per-stream truncation
flag telling a caller (without rescanning bytes) that a stream overflowed the
capture bound, a structured `Termination`, and the wall duration. The bytes are
raw so a byte-exact test can assert on them; a later rendering layer decodes them
to printable text through `lossy_utf8` (now in `config`), which never crashes on
invalid sequences.
"""
from mtest.exec.termination import Termination


@fieldwise_init
struct ProcessResult(Copyable, Movable):
    """The captured streams, the termination, and the duration of one run.

    Owns the two capture buffers, so copies are explicit; holds no fds and never
    raises once constructed.
    """

    var stdout_bytes: List[UInt8]
    """The child's raw stdout, bounded per the capture limit; kept separate."""
    var stderr_bytes: List[UInt8]
    """The child's raw stderr, bounded per the capture limit; kept separate."""
    var stdout_truncated: Bool
    """True iff stdout overflowed the capture bound and the truncation marker was
    spliced into `stdout_bytes` (the middle was dropped)."""
    var stderr_truncated: Bool
    """True iff stderr overflowed the capture bound and the truncation marker was
    spliced into `stderr_bytes` (the middle was dropped)."""
    var termination: Termination
    """How the child ended: Exited / Signaled / TimedOut / SpawnFailed."""
    var duration_ms: Int
    """Wall time from fork to reap, in milliseconds."""
