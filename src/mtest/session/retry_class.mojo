"""The crash-class retry classifier.

`--retries` re-runs only crash-class failures, meaning a real crash or a
deadline kill, and never deterministic ones such as a failing assertion, a
nonzero compile error, or a flooded capture. Getting this wrong either masks a
legitimately failing test by retrying it until it passes, or wastes time
retrying a flood. This module is the single source of that decision; the attempt
loop that consumes it is wired separately.

`retry_classify` folds four facts into one `RetryClass`: the step (`"run"` vs a
compile step), the `Termination`, whether an interrupt was pending, and the raw
stderr. The policy is total. In precedence order:

1. `SpawnFailed`             -> not eligible, `"spawn-failed"` (an internal
                                error the session routes to exit 3).
2. `TimedOut` + interrupted  -> not eligible, `"interrupt"`, whichever step
                                raised it. The cause comes from the passed
                                `interrupted` flag, not from the timeout alone.
3. Run step, otherwise:
   - `Signaled`              -> eligible, `"signal"`.
   - `TimedOut` (a deadline) -> eligible, `"run-timeout"`.
   - `Exited` (any code)     -> not eligible, `"deterministic"`. A process that
                                exited under its own control is deterministic;
                                this covers worse-of disagreements, a malformed
                                suite, and a capture-overflow FAIL.
4. Build or precompile step, otherwise (precompile uses the build rules):
   - `Signaled`              -> eligible, `"compile-crash"`.
   - `TimedOut` (a deadline) -> eligible, `"compile-timeout"`.
   - `Exited(nonzero)` with a crash signature -> eligible, `"compile-crash"`:
                                a compiler ICE exiting nonzero with a banner.
   - `Exited(nonzero)` without a signature -> not eligible, `"compile-error"`:
                                an ordinary, deterministic compile error.
   - `Exited(0)`             -> not eligible, `"deterministic"`. A succeeded
                                build is not a failure; present for totality.

The crash-signature marker list in `has_crash_signature` is assumption-pinned:
it was not validated against a real Mojo internal compiler error on this
toolchain, because no ICE was reproduced during the resilience spike. The
markers port the intent of the transcript normalizer's crash patterns in
`scripts/gen_transcripts.py`: the LLVM/Mojo "PLEASE submit a bug report"
banner, a `Stack dump` header line, and the two stack-frame shapes. If a real
ICE later prints a different banner, extend the list here and re-pin the tests.

The banner match is anchored at a line start rather than matched as a bare
substring, so a deterministic compile error that echoes the phrase mid-line, in
a quoted assert message or quoted user source, is not misread as an ICE and
retried. A residual corner remains: a deterministic compiler emitting a line
that itself starts with the banner shape would still trip it.
"""
from mtest.config import lossy_utf8
from mtest.exec import Termination


@fieldwise_init
struct RetryClass(Copyable, Movable):
    """The result of classifying one failed step for retry eligibility.

    Carries the single decision (`retry_eligible`) plus a short, stable `label`
    the reporter and the AttemptFinished event render (e.g. `"signal"`,
    `"run-timeout"`, `"compile-crash"`, `"compile-error"`, `"deterministic"`).
    """

    var retry_eligible: Bool
    """True iff this failure is crash-class and `--retries` may retry it."""
    var label: String
    """A short, stable classification tag for the reporter / AttemptFinished."""


def retry_classify(
    step: String, term: Termination, interrupted: Bool, stderr: List[UInt8]
) -> RetryClass:
    """Classify one failed step under the retry policy.

    Args:
        step: `"run"` for the run step; `"build"` or `"precompile"` for a
            compile step. Both compile steps share the build rules, and any
            value other than `"run"` is treated as a compile step.
        term: How the supervised step ended.
        interrupted: Whether an interrupt was pending when the step was killed.
            An interrupt-caused `TimedOut` is never retried; a deadline one is.
        stderr: The step's raw captured stderr, scanned for a compiler crash
            signature only on the build path.

    Returns:
        The eligibility decision and its label.
    """
    # Rule 1: a spawn failure is an internal error, never a retryable outcome.
    if term.is_spawn_failed():
        return RetryClass(False, "spawn-failed")

    # Rule 2: an interrupt is never retryable, whichever step raised it. Classify
    # from the passed cause — never assume every timeout is a deadline.
    if term.is_timed_out() and interrupted:
        return RetryClass(False, "interrupt")

    if step == "run":
        # Rule 3: the RUN step.
        if term.is_signaled():
            return RetryClass(True, "signal")
        if term.is_timed_out():
            # A deadline kill (interrupt handled above).
            return RetryClass(True, "run-timeout")
        # Exited under its own control (ANY code): deterministic, never retried.
        return RetryClass(False, "deterministic")

    # Rule 4: the BUILD / PRECOMPILE step.
    if term.is_signaled():
        return RetryClass(True, "compile-crash")
    if term.is_timed_out():
        # A deadline kill (interrupt handled above).
        return RetryClass(True, "compile-timeout")
    # From here the compiler Exited with `term.value`.
    if term.value != 0 and has_crash_signature(stderr):
        # A compiler ICE: nonzero exit with a crash banner in its stderr.
        return RetryClass(True, "compile-crash")
    if term.value != 0:
        # An ordinary compile error — deterministic.
        return RetryClass(False, "compile-error")
    # Exited(0): a succeeded build. Not a failure; present only for totality.
    return RetryClass(False, "deterministic")


def _is_digit(b: UInt8) -> Bool:
    """Whether `b` is an ASCII digit `0`..`9`."""
    return b >= 48 and b <= 57


def _is_hex(b: UInt8) -> Bool:
    """Whether `b` is an ASCII hex digit, case-insensitive."""
    if _is_digit(b):
        return True
    var lo = b | 0x20  # fold to lowercase
    return lo >= 0x61 and lo <= 0x66  # a..f


def _is_ws(b: UInt8) -> Bool:
    """Whether `b` is a space or a tab (the `\\s` of the frame patterns)."""
    return b == 32 or b == 9


def _is_symbolless_frame(lb: Span[UInt8, _]) -> Bool:
    """Whether `lb` is a symbol-less stack frame line.

    Ports `^\\d+\\s+\\S+\\s+0x[0-9a-f]+`, the no-symbolizer frame shape
    `<n>  <module> 0x<hex>`, as a plain forward scan without a regex engine. The
    complementary `\\d+`/`\\s+`/`\\S+` runs need no backtracking.
    """
    var n = len(lb)
    var i = 0
    # ^\d+
    while i < n and _is_digit(lb[i]):
        i += 1
    if i == 0:
        return False
    # \s+
    var w1 = i
    while i < n and _is_ws(lb[i]):
        i += 1
    if i == w1:
        return False
    # \S+ (the module token; at least one non-whitespace byte)
    var t0 = i
    while i < n and not _is_ws(lb[i]):
        i += 1
    if i == t0:
        return False
    # \s+
    var w2 = i
    while i < n and _is_ws(lb[i]):
        i += 1
    if i == w2:
        return False
    # 0x
    if i + 1 >= n or lb[i] != 48 or lb[i + 1] != 120:
        return False
    i += 2
    # [0-9a-f]+
    var h0 = i
    while i < n and _is_hex(lb[i]):
        i += 1
    return i > h0


def _is_symbolized_frame(lb: Span[UInt8, _]) -> Bool:
    """Whether `lb` is a symbolized stack frame line.

    Ports `^\\s*#\\d+ 0x[0-9a-f]+`, the llvm-symbolizer frame shape
    `#<n> 0x<hex> <sym> <file>:<l>:<c>`, as a plain forward scan.
    """
    var n = len(lb)
    var i = 0
    # ^\s*
    while i < n and _is_ws(lb[i]):
        i += 1
    # #
    if i >= n or lb[i] != 35:
        return False
    i += 1
    # \d+
    var d0 = i
    while i < n and _is_digit(lb[i]):
        i += 1
    if i == d0:
        return False
    # a single literal space
    if i >= n or lb[i] != 32:
        return False
    i += 1
    # 0x
    if i + 1 >= n or lb[i] != 48 or lb[i + 1] != 120:
        return False
    i += 2
    # [0-9a-f]+
    var h0 = i
    while i < n and _is_hex(lb[i]):
        i += 1
    return i > h0


def has_crash_signature(stderr: List[UInt8]) -> Bool:
    """Whether the raw stderr bytes carry a compiler-crash marker.

    A conservative, total scan for the assumption-pinned markers described in
    the module docstring. Matches any of:

    - a line starting with `please submit a bug report`, matched
      case-insensitively and tolerating leading whitespace. The LLVM/Mojo ICE
      banner line opens `PLEASE submit a bug report to <url>`, and anchoring at
      the line start keeps a mid-line echo from forging it.
    - a line beginning `Stack dump`.
    - a stack-frame line in either shape the runtime emits (see
      `_is_symbolless_frame` and `_is_symbolized_frame`).

    Args:
        stderr: The step's raw captured stderr bytes.

    Returns:
        True iff a crash marker is present.
    """
    var text = lossy_utf8(stderr)
    for line in text.split("\n"):
        var l = String(line)
        # The LLVM/Mojo ICE banner LINE opens `PLEASE submit a bug report to
        # <url>`. Anchor on that canonical shape at the LINE START (leading
        # whitespace tolerated) so a deterministic compile error whose stderr
        # merely ECHOES `submit a bug report` mid-line — a quoted assert message
        # or quoted user source — cannot forge the signature and get retried.
        if l.lower().lstrip().startswith("please submit a bug report"):
            return True
        if l.startswith("Stack dump"):
            return True
        var lb = l.as_bytes()
        if _is_symbolless_frame(lb) or _is_symbolized_frame(lb):
            return True
    return False
