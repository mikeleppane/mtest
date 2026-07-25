"""Known-outcome fixture: the passing file that sorts FIRST under slow/.

Verdict PASS, exit-class 0. It exists so the interrupt scenarios can be exact
rather than timed: a sequential walk of slow/ must have COMPLETED one file before
the next child blocks, and this is that file. Its verdict is the `1 passed` half
of the interrupt summary, and every later file is the NOT-RUN half.

When `MTEST_SLOW_PASSED_FILE` names a path the test body writes that marker, so
only a real RUN of the built binary can create it — a build alone never does —
and a harness waiting for it is waiting for an observed fact instead of guessing
with a sleep.
"""
from std.os import getenv
from std.testing import assert_equal, TestSuite

comptime PASSED_FILE_ENV = "MTEST_SLOW_PASSED_FILE"
"""Environment name whose value, when non-empty, is the marker path to write."""


def test_first_pass() raises:
    var path = getenv(PASSED_FILE_ENV, "")
    if path.byte_length() != 0:
        with open(path, "w") as handle:
            handle.write("passed\n")
    assert_equal(1, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
