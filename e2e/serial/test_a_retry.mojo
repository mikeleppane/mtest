"""Serial retry fixture: CRASHES on its first run, then PASSES on a retry.

Reached only by the serial no-overlap scenario. It exists to prove the serial
pass drains a file's WHOLE pipeline — build, run, and any crash-class retry —
before admitting the next serial file. It combines two behaviors:

- The crash-then-pass of `e2e/flaky/test_flaky.mojo`, keyed by a per-file MARKER
  under `build/e2e-scratch/` the harness owns (it creates the scratch dir and
  resets the marker before each run, so ordering is deterministic). First run,
  no marker: drop the marker and force a hard SIGSEGV, so the buffered report is
  LOST and mtest reads a crash-class failure. Retry, marker present: the test
  passes and mtest reads a VALID report. So `--retries 1` reports the file FLAKY.
- The run-window stamping of `e2e/parallel/test_window_a.mojo`: when
  `MTEST_WINDOW_RUN_LOG` is armed, each attempt records the wall-clock edges of
  its OWN run window under a distinct name — `aretry1` for the crashing first
  attempt, `aretry2` for the passing retry — with a floored sleep so the windows
  are observably wide. The scenario asserts both windows are disjoint from each
  other and fall before the next serial file's window, proving the retry drained
  inside the file's single serial slot.
"""
from std.memory import UnsafePointer
from std.os import getenv
from std.os.path import exists
from std.testing import assert_equal, TestSuite
from std.time import perf_counter_ns, sleep

comptime _MARKER = "build/e2e-scratch/serial_retry_marker"
"""The per-file marker, relative to the invocation root (mtest's run cwd)."""
comptime RUN_LOG_ENV = "MTEST_WINDOW_RUN_LOG"
comptime RUN_FLOOR_ENV = "MTEST_WINDOW_RUN_FLOOR"
comptime DEFAULT_RUN_FLOOR = 0.3


def test_serial_retry_passes_on_retry() raises:
    # Reached only on the retry, once the crashing first attempt has passed. The
    # crash-or-pass decision is made in `main` before the suite runs.
    assert_equal(1, 1)


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


def _stamp_run_window(name: String) raises:
    """Record this attempt's run-phase edges when the run log is configured.

    A no-op when `MTEST_WINDOW_RUN_LOG` is unset, so the fixture stays an
    ordinary crash-then-pass file outside the no-overlap scenario.

    Args:
        name: The window name identifying this attempt (`aretry1`/`aretry2`).
    """
    var log_path = getenv(RUN_LOG_ENV, "")
    if log_path.byte_length() == 0:
        return
    var start = _monotonic_seconds()
    _append_window(log_path, "run\t" + name + "\t" + String(start) + "\n")
    sleep(_run_floor())
    var end = _monotonic_seconds()
    _append_window(log_path, "run\t" + name + "\t" + String(end) + "\n")


def main() raises:
    if exists(_MARKER):
        # Retry: stamp the passing attempt's window, then run the suite.
        _stamp_run_window("aretry2")
    else:
        # First attempt: stamp the crashing attempt's window, durably drop the
        # marker (the `with` block flushes and closes before the fault), then die
        # by a raw SIGSEGV so mtest reads a crash-class failure and retries.
        _stamp_run_window("aretry1")
        with open(_MARKER, "w") as f:
            f.write("crashed once\n")
        # SAFETY: this deliberately constructs an UnsafePointer at a known-invalid
        # address so the load below raises a genuine SIGSEGV, the exact crash this
        # fixture exists to produce for the serial-retry e2e scenario. It never
        # runs outside this test fixture.
        var p = UnsafePointer[Int, MutUntrackedOrigin](unsafe_from_address=8)
        print(p[])
    TestSuite.discover_tests[__functions_in_module()]().run()
