"""The pure SLOW-threshold policy for a file's BUILD/RUN steps (Layer 0).

A step that runs a very long time is worth naming even when it eventually
succeeds — a comptime-stalled compile or a crawling test is exactly what a
reader most wants pointed at, and waiting for the 600s compile deadline (or
never, for a run with no `--timeout`) to say so is too late. `SLOW` is an
INFORMAL-tier ANNOTATION on the verdict line, never an outcome: it rides
alongside a file's real verdict and never changes it, its counts, or the exit
code (see `mtest.model.events.Event.file_finished`'s `slow` field).

Both functions are pure, total over any two non-negative second counts, and
never raise. `SLOW_THRESHOLD_SECONDS` is the single source of truth for the
60s threshold (STABLE-INTENT, no flag, no config field): a comptime-stalled
compile becomes visible at 60s, not at the 600s compile deadline.
"""

comptime SLOW_THRESHOLD_SECONDS: Float64 = 60.0
"""The wall-clock threshold, in seconds, at or above which a step is SLOW."""


def is_slow(build_seconds: Float64, run_seconds: Float64) -> Bool:
    """Whether either step's wall time crossed the SLOW threshold.

    Total and pure: True iff `build_seconds` or `run_seconds` is `>=
    SLOW_THRESHOLD_SECONDS`. A step whose duration is genuinely unknown (never
    ran) should be passed as `0.0` — never invented — which this function
    always reads as not-slow.

    Args:
        build_seconds: The BUILD step's wall time, in seconds. Not mutated.
        run_seconds: The RUN step's wall time, in seconds. Not mutated.

    Returns:
        True iff either step is at or above the threshold. Does not raise.
    """
    return (
        build_seconds >= SLOW_THRESHOLD_SECONDS
        or run_seconds >= SLOW_THRESHOLD_SECONDS
    )


def slow_step_label(build_seconds: Float64, run_seconds: Float64) -> String:
    """Name WHICH step(s) crossed the SLOW threshold, for `-v` output only.

    Total and pure: `"build"`, `"run"`, `"build and run"`, or `""` when
    neither step is slow. The durable verdict-line `SLOW` token itself never
    depends on this — only the verbose per-step naming does.

    Args:
        build_seconds: The BUILD step's wall time, in seconds. Not mutated.
        run_seconds: The RUN step's wall time, in seconds. Not mutated.

    Returns:
        The step-naming label. Does not raise.
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
