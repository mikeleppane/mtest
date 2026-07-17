"""Flaky fixture: CRASHES on its first run, then PASSES on a retry.

The retry surface's end-to-end proof. The outcome is keyed by a per-file MARKER
under `build/e2e-scratch/` that the e2e harness owns (it creates the scratch dir
and resets the marker between runs, so ordering is deterministic):

- First attempt — no marker: drop the marker, then force a hard runtime SIGSEGV
  (the invalid-`UnsafePointer` load technique from
  `tests/fixtures/protocol/segfault.mojo`). The process dies by signal, so the
  buffered report is LOST and mtest reads a crash-class failure.
- Retry — marker present: the test passes and mtest reads a VALID report.

So `--retries 1` re-runs the crashed binary once, sees the pass, and reports the
file FLAKY (process exit 0). `--retries 0` reports the first crash as CRASH
(process exit 1). This file is reached ONLY by the retries scenario; it is never
in the default suite.
"""
from std.memory import UnsafePointer
from std.os.path import exists
from std.testing import assert_equal, TestSuite

comptime _MARKER = "build/e2e-scratch/flaky_marker"
"""The per-file marker, relative to the invocation root (mtest's run cwd)."""


def test_flaky_passes_on_retry() raises:
    if exists(_MARKER):
        # Retry: the marker the crashed first attempt dropped is present.
        assert_equal(1, 1)
    else:
        # First attempt: durably drop the marker (the `with` block flushes and
        # closes before the fault), then die by a raw SIGSEGV.
        with open(_MARKER, "w") as f:
            f.write("crashed once\n")
        var p = UnsafePointer[Int, MutUntrackedOrigin](unsafe_from_address=8)
        print(p[])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
