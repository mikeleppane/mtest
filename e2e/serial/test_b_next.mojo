"""Serial no-overlap fixture: an all-passing file that stamps its run window.

Reached only by the serial no-overlap scenario, as the serial file that runs
AFTER `test_a_retry.mojo`. Verdict PASS, exit-class 0. When
`MTEST_WINDOW_RUN_LOG` is armed it records the wall-clock edges of its own run
phase under the name `bnext` — a start stamp, a floored sleep, then an end stamp
— so the scenario can prove this file's run window is disjoint from (and starts
after) `test_a_retry.mojo`'s retry window, i.e. the retry drained fully before
this next serial file was admitted.
"""
from std.os import getenv
from std.testing import assert_equal, TestSuite
from std.time import perf_counter_ns, sleep

comptime WINDOW_NAME = "bnext"
comptime RUN_LOG_ENV = "MTEST_WINDOW_RUN_LOG"
comptime RUN_FLOOR_ENV = "MTEST_WINDOW_RUN_FLOOR"
comptime DEFAULT_RUN_FLOOR = 0.3


def test_serial_next_passes() raises:
    assert_equal(2, 2)


def _monotonic_seconds() -> Float64:
    """Monotonic wall seconds, for stamping a run-window edge."""
    return Float64(perf_counter_ns()) / 1.0e9


def _run_floor() -> Float64:
    """The minimum wall seconds a run window spans, from the env or the default.
    """
    var raw = getenv(RUN_FLOOR_ENV, "")
    if raw.byte_length() == 0:
        return DEFAULT_RUN_FLOOR
    try:
        return atof(raw)
    except:
        return DEFAULT_RUN_FLOOR


def _append_window(log_path: String, line: String) raises:
    """Append one record to the run-window log."""
    with open(log_path, "a") as handle:
        handle.write(line)


def _stamp_run_window() raises:
    """Record this file's run-phase edges when the run log is configured."""
    var log_path = getenv(RUN_LOG_ENV, "")
    if log_path.byte_length() == 0:
        return
    var start = _monotonic_seconds()
    _append_window(
        log_path, "run\t" + WINDOW_NAME + "\t" + String(start) + "\n"
    )
    sleep(_run_floor())
    var end = _monotonic_seconds()
    _append_window(log_path, "run\t" + WINDOW_NAME + "\t" + String(end) + "\n")


def main() raises:
    _stamp_run_window()
    TestSuite.discover_tests[__functions_in_module()]().run()
