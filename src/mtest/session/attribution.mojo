"""The bounds policy of the crash-attribution post-pass.

A file that crashed gets an honest but unhelpful verdict: the process died, but
the verdict cannot say which test killed it. The attribution post-pass re-runs
the file's tests one at a time, using `--only <name>` against the binary the run
already built, and names the first one that dies by signal.

Attribution is secondary evidence, never a verdict input: the file's CRASH
stands whether or not a culprit is found, and the pass emits nothing but
`CrashAttribution` events. What remains at risk is the pass spending unbounded
time, which is what these bounds exist to prevent:

- at most `ISOLATION_RUN_CAP` reruns per file;
- `isolation_timeout_secs(config.timeout_secs)` per rerun;
- `ATTRIBUTION_FILE_BUDGET_SECONDS` of wall time per file, and
  `ATTRIBUTION_SESSION_BUDGET_SECONDS` across the whole pass.

The wall budgets are checked before each rerun rather than during one, so each
is a threshold that stops the next rerun rather than a ceiling on elapsed time.
A rerun already in flight when a budget expires still runs to its own deadline,
so a file can overshoot by up to one isolation timeout, 120 s + 60 s in the
worst case. Killing a rerun mid-flight would buy a tighter number at the cost of
a torn result, so these bound the pass rather than predicting its duration.

Every stop renders a typed `AttributionDisposition`, so a reader learns why the
search ended instead of inferring it from silence. This module owns the decision
and nothing else: it is total, never raises, and reads no clock of its own,
since the caller passes the facts in. `attribution_step` never returns
`ATTRIBUTED` or `PROBE_FAILED`, which are decided elsewhere: a rerun that dies
by signal names the culprit, and a listing that cannot be recovered fails the
file.
"""
from mtest.model import AttributionDisposition

comptime ISOLATION_RUN_CAP = 32
"""The hard ceiling on isolation reruns for one crashed file.

A file with more tests than this is not searched exhaustively: the pass stops at
the cap and reports `RUN_CAP`, leaving the culprit unattributed rather than
letting a 500-test file spawn 500 processes behind a verdict that already
stands."""

comptime ISOLATION_TIMEOUT_CAP_SECS = 60
"""The ceiling on one isolation rerun's deadline, in seconds.

As `isolation_timeout_secs` applies it, the effective deadline is the minimum of
this and the configured `--timeout`, so attribution never waits longer for a
test than the run itself would have, and never waits forever when `--timeout 0`
disables the run deadline."""

comptime ATTRIBUTION_FILE_BUDGET_SECONDS = 120.0
"""The wall-clock budget for attributing one crashed file, in seconds."""

comptime ATTRIBUTION_SESSION_BUDGET_SECONDS = 600.0
"""The wall-clock budget for the whole attribution pass, in seconds.

A run with many crashed files must not turn a bounded-per-file pass into an
unbounded session. This is the outer bound that keeps the post-pass's cost
proportional to a diagnostic rather than to the run."""


def isolation_timeout_secs(timeout_secs: Int) -> Int:
    """The deadline for one isolation rerun: `min(timeout_secs, 60)`.

    A non-positive `timeout_secs` is `--timeout 0`, the sanctioned way to
    disable the run deadline. Attribution does not inherit that: an unbounded
    rerun of a hanging test would hang the whole pass behind a verdict that
    already stands, so a disabled deadline falls back to the cap.

    Args:
        timeout_secs: The configured `--timeout` in seconds. Zero, or any
            non-positive value, means the run deadline is disabled.

    Returns:
        The rerun deadline in seconds, always in `1 ..= 60`.
    """
    if timeout_secs <= 0:
        return ISOLATION_TIMEOUT_CAP_SECS
    if timeout_secs < ISOLATION_TIMEOUT_CAP_SECS:
        return timeout_secs
    return ISOLATION_TIMEOUT_CAP_SECS


@fieldwise_init
struct AttributionStep(Copyable, Movable):
    """Whether the pass may run one more isolation rerun, and why not if not.

    On a continue, `disposition` carries the same neutral value a blank
    `CrashAttribution` event does and must not be read.
    """

    var should_stop: Bool
    """True iff the pass must stop now and render `disposition`."""
    var disposition: AttributionDisposition
    """Why the pass stopped — meaningful only when `should_stop`."""


def attribution_step(
    tests_left: Int,
    runs_done: Int,
    file_elapsed: Float64,
    session_elapsed: Float64,
) -> AttributionStep:
    """Decide whether one more isolation rerun may run. Total over its inputs.

    The policy, in precedence order:

    1. `tests_left <= 0`          -> stop, `NO_REPRODUCTION`. Every test ran
       alone and none crashed, so the search completed. This deliberately
       dominates the budgets: a search that finished is never reported as one a
       clock cut short, whatever the clock happens to read.
    2. `session_elapsed >= 600 s` -> stop, `TIME_BUDGET`.
    3. `file_elapsed >= 120 s`    -> stop, `TIME_BUDGET`.
    4. `runs_done >= 32`          -> stop, `RUN_CAP`. This sits below the
       budgets so that when the clock has also run out the clock is named,
       because it would have stopped the pass whether or not the cap existed.
    5. otherwise                  -> continue.

    Args:
        tests_left: How many names of the file's listing are still unexplored.
        runs_done: How many isolation reruns this file has already spent.
        file_elapsed: This file's attribution wall time so far, in seconds.
        session_elapsed: The whole pass's wall time so far, in seconds.

    Returns:
        The stop decision and, when stopping, its typed disposition.
    """
    if tests_left <= 0:
        return AttributionStep(True, AttributionDisposition.NO_REPRODUCTION)
    if session_elapsed >= ATTRIBUTION_SESSION_BUDGET_SECONDS:
        return AttributionStep(True, AttributionDisposition.TIME_BUDGET)
    if file_elapsed >= ATTRIBUTION_FILE_BUDGET_SECONDS:
        return AttributionStep(True, AttributionDisposition.TIME_BUDGET)
    if runs_done >= ISOLATION_RUN_CAP:
        return AttributionStep(True, AttributionDisposition.RUN_CAP)
    return AttributionStep(False, AttributionDisposition.NO_REPRODUCTION)
