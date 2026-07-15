"""Tiny known-outcome Mojo fixtures for the session orchestration tests.

Not a test module (no `test_` prefix), so the runner never builds it as a
suite; it is imported via `-I tests`. Each helper writes a MINIMAL real Mojo
source into a temp tree so the session can genuinely build-and-execute it — the
only faithful way to exercise the keystone — and returns configs wired to that
tree. Keep every fixture as small as its outcome demands: build output lands
under the temp root's own `build/`, never the repo's.
"""
from std.os import makedirs
from std.os.path import dirname, exists
from std.tempfile import mkdtemp

from mtest.config import (
    ColorWhen,
    Precompile,
    RunnerConfig,
    ShowOutput,
    Verbosity,
)

# A real one-test TestSuite that passes -> a VALID report, exit 0 -> PASS.
# The session now PARSES each run's own report, so a report-BEARING fixture is
# the honest PASS case: `def main(): pass` prints no report and is MALFORMED.
comptime SRC_PASS = (
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_pass() raises:\n"
    "    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
# A real one-test TestSuite whose test fails -> a VALID report with a FAIL row
# and the failure trailer, exit 1 -> FAIL.
comptime SRC_FAIL = (
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_fail() raises:\n"
    "    assert_true(False)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
# A binary that dies by SIGABRT -> CRASH (never a FAIL).
comptime SRC_CRASH = (
    "from std.ffi import external_call\n\n\ndef main():\n    _ ="
    ' external_call["abort", Int32]()\n'
)
# A source the compiler rejects -> COMPILE_ERROR (never a run outcome).
comptime SRC_COMPILE_ERROR = 'def main():\n    var x: Int = "nope"\n'
# A binary that never exits -> TIMEOUT under a deadline.
comptime SRC_HANG = "def main():\n    while True:\n        pass\n"

# --- The hostile handshake set: report-shaped adversaries. --------------------

# Compiles, runs, exits 0, prints NO report -> ABSENT -> MALFORMED_SUITE.
comptime SRC_SILENT = "def main():\n    pass\n"
# Runs a real suite TWICE, appending a second complete report block for the same
# path -> AMBIGUOUS -> MALFORMED_SUITE. (run() returns for a passing suite.)
comptime SRC_FORGER = (
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_one() raises:\n"
    "    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)
# Runs a real suite, then hand-forges a trailing Summary the grammar rejects (a
# Summary with no rule before it) -> OFF_GRAMMAR -> DRIFT (exit 3). The
# sanctioned user-authored path to exit 3.
comptime SRC_LIAR = (
    "from std.testing import TestSuite, assert_true\n\n\n"
    "def test_one() raises:\n"
    "    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
    '    print("Summary [ 0.00s ] 1 tests run: 1 passed , 0 failed ,'
    ' 0 skipped ")\n'
)
# A real suite that collects ZERO tests -> a VALID zero-test report, exit 0 ->
# PASS that ran zero tests (the closed zero-test ceiling, no longer PASS-from-
# exit-status).
comptime SRC_ZERO = (
    "from std.testing import TestSuite\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)


def temp_root() raises -> String:
    """Create and return a fresh, empty temp directory to use as a root."""
    return mkdtemp()


def write_file(root: String, rel: String, content: String) raises:
    """Write `content` to `root/rel`, creating parent directories as needed."""
    var full = root + "/" + rel
    var parent = dirname(full)
    if parent != "" and not exists(parent):
        makedirs(parent)
    with open(full, "w") as f:
        f.write(content)


def base_config() raises -> RunnerConfig:
    """A default config with a short 2-second run deadline for the fixtures."""
    var c = RunnerConfig.default()
    c.timeout_secs = 2
    return c^
