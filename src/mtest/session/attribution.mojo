"""The PURE bounds policy of the crash-attribution post-pass (Layer 4).

A file that CRASHED gets an honest but unhelpful verdict: the process died, but
the verdict cannot say WHICH test killed it. The attribution post-pass re-runs
the file's tests one at a time (`--only <name>` against the binary the run
already built) and names the first one that dies by signal.

It is SECONDARY EVIDENCE and never a verdict input: the file's CRASH stands
whether or not a culprit is found, and attribution emits nothing but
`CrashAttribution` events. So the only thing that can go wrong is the pass
spending unbounded time — which makes these bounds the entire safety argument:

- at most `ISOLATION_RUN_CAP` reruns per file;
- `isolation_timeout_secs(config.timeout_secs)` per rerun;
- `ATTRIBUTION_FILE_BUDGET_SECONDS` of wall time per file, and
  `ATTRIBUTION_SESSION_BUDGET_SECONDS` across the whole pass.

The wall budgets are checked BEFORE each rerun, not during one, so each is a
threshold that stops the NEXT rerun rather than a hard ceiling on elapsed time:
a rerun already in flight when a budget expires still runs to its own deadline,
so a file can overshoot by up to one isolation timeout (120 s + 60 s in the worst
case). That is deliberate — killing a rerun mid-flight would buy a tighter number
at the cost of a torn, unreadable result — but it means these are budgets that
BOUND the pass, not promises about its exact duration.

Every stop renders a TYPED `AttributionDisposition`, so a reader always learns
why the search ended and never has to infer it from silence. This module owns the
decision and nothing else: it is pure, total, never raises, and touches no clock
of its own — the caller passes the facts in. `ATTRIBUTED` and `PROBE_FAILED` are
NOT decided here (a rerun that dies by signal names the culprit; a listing that
cannot be recovered fails the file), which is why `attribution_step` never
returns them.
"""
from mtest.model import AttributionDisposition

comptime ISOLATION_RUN_CAP = 32
"""The hard ceiling on isolation reruns for ONE crashed file.

A file with more tests than this is not searched exhaustively: the pass stops at
the cap and says so (`RUN_CAP`), leaving the culprit UNATTRIBUTED rather than
letting a 500-test file spawn 500 processes behind a verdict that already
stands."""

comptime ISOLATION_TIMEOUT_CAP_SECS = 60
"""The ceiling on ONE isolation rerun's deadline, in seconds.

See `isolation_timeout_secs`: the effective deadline is the MINIMUM of this and
the configured `--timeout`, so attribution never waits longer for a test than the
run itself would have — and never waits forever when `--timeout 0` disables the
run deadline."""

comptime ATTRIBUTION_FILE_BUDGET_SECONDS = 120.0
"""The wall-clock budget for attributing ONE crashed file, in seconds."""

comptime ATTRIBUTION_SESSION_BUDGET_SECONDS = 600.0
"""The wall-clock budget for the WHOLE attribution pass, in seconds.

A run with many crashed files must not turn a bounded-per-file pass into an
unbounded session: this is the outer bound that keeps the post-pass's cost
proportional to a diagnostic, not to the run."""


def isolation_timeout_secs(timeout_secs: Int) -> Int:
    """The deadline for ONE isolation rerun: `min(timeout_secs, 60)`. Pure.

    A non-positive `timeout_secs` is `--timeout 0` — the sanctioned way to
    DISABLE the run deadline. Attribution refuses to inherit that: an unbounded
    isolation rerun of a test that hangs would hang the whole pass behind a
    verdict that already stands, so a disabled deadline falls back to the cap.

    Args:
        timeout_secs: The configured `--timeout` in seconds; `0` (or any
            non-positive value) means the run deadline is disabled.

    Returns:
        The rerun deadline in seconds, always in `1 ..= 60`. Does not raise.
    """
    if timeout_secs <= 0:
        return ISOLATION_TIMEOUT_CAP_SECS
    if timeout_secs < ISOLATION_TIMEOUT_CAP_SECS:
        return timeout_secs
    return ISOLATION_TIMEOUT_CAP_SECS


@fieldwise_init
struct AttributionStep(Copyable, Movable):
    """Whether the pass may run one more isolation rerun, and why not if not.

    `disposition` is meaningful ONLY when `should_stop`; on a continue it carries
    the same neutral value a blank `CrashAttribution` event does and must not be
    read. Holds no owned resources beyond its disposition; never raises.
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
    """Decide whether one more isolation rerun may run. Pure; total; never raises.

    The policy in precedence order — pinned row by row in
    `tests/unit/test_session_attribution.mojo`:

    1. `tests_left <= 0`                    -> stop, `NO_REPRODUCTION`. Every
       test ran alone and none crashed: the search COMPLETED. This dominates the
       budgets deliberately — a search that finished is never reported as one a
       clock cut short, whatever the clock happens to read.
    2. `session_elapsed >= 600 s`           -> stop, `TIME_BUDGET`.
    3. `file_elapsed >= 120 s`              -> stop, `TIME_BUDGET`.
    4. `runs_done >= 32`                    -> stop, `RUN_CAP`. Below the
       budgets: when the clock has ALSO run out, the clock is named, because it
       would have stopped the pass whether or not the cap existed.
    5. otherwise                            -> continue.

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
