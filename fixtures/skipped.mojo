"""Probe fixture: a NATIVELY skipped test.

TestSuite exposes an in-code skip API (`suite.skip[f]()`), so a test can be
registered as skipped without any CLI flag. This pins the real SKIP report line
as it originates from the suite itself — distinct from the selection-induced
SKIPs that `--skip-all`/`--only`/`--skip` produce (which are protocol artifacts
mtest suppresses). Using the API requires the manual construction form, since
`skip` must be called between discovery and the consuming `run()`.

Function order is non-alphabetical to keep pinning discovery order.
"""
from std.testing import assert_equal, TestSuite


def test_runs_normally() raises:
    assert_equal(1, 1)


def test_natively_skipped() raises:
    assert_equal(1, 1)


def main() raises:
    var suite = TestSuite.discover_tests[__functions_in_module()]()
    suite.skip[test_natively_skipped]()
    suite^.run()
