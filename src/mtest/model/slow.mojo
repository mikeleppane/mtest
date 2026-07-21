"""The slow-step threshold policy for a file's build and run steps.

`SLOW` is an informal-tier annotation on the verdict line, never an outcome: it
rides alongside a file's real verdict and changes neither that verdict, nor its
counts, nor the exit code (see the `slow` field on
`mtest.model.events.Event.file_finished`). It exists so a step that runs a very
long time gets named even when it eventually succeeds — a comptime-stalled
compile becomes visible at 60s rather than at the 600s compile deadline, or
never for a run with no `--timeout`.

`SLOW_THRESHOLD_SECONDS` is the single source of truth for the threshold; there
is no flag and no config field for it. Both functions are total over any two
non-negative second counts.
"""

comptime SLOW_THRESHOLD_SECONDS: Float64 = 60.0
"""The wall-clock threshold, in seconds, at or above which a step is SLOW."""


def is_slow(build_seconds: Float64, run_seconds: Float64) -> Bool:
    """Whether either step's wall time crossed the slow threshold.

    A step whose duration is genuinely unknown, because it never ran, should be
    passed as `0.0` rather than invented; this function reads that as not slow.

    Args:
        build_seconds: The build step's wall time, in seconds.
        run_seconds: The run step's wall time, in seconds.

    Returns:
        True iff either step is at or above `SLOW_THRESHOLD_SECONDS`.
    """
    return (
        build_seconds >= SLOW_THRESHOLD_SECONDS
        or run_seconds >= SLOW_THRESHOLD_SECONDS
    )


def slow_step_label(build_seconds: Float64, run_seconds: Float64) -> String:
    """Name which steps crossed the slow threshold, for `-v` output only.

    The durable verdict-line `SLOW` token does not depend on this; only the
    verbose per-step naming does.

    Args:
        build_seconds: The build step's wall time, in seconds.
        run_seconds: The run step's wall time, in seconds.

    Returns:
        `"build"`, `"run"`, `"build and run"`, or `""` when neither step is
        slow.
    """
    var build_slow = build_seconds >= SLOW_THRESHOLD_SECONDS
    var run_slow = run_seconds >= SLOW_THRESHOLD_SECONDS
    if build_slow and run_slow:
        return "build and run"
    if build_slow:
        return "build"
    if run_slow:
        return "run"
    return ""
