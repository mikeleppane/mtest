"""Known-outcome fixture: a suite whose report DRIFTS off the pinned grammar.

Verdict DRIFT -> exit 3. It runs a real one-test TestSuite, then hand-prints a
trailing Summary line with no rule (`--------`) before it. The end-scan takes
that last Summary as terminal, its preceding line is not the rule, so the parser
classifies the report OFF_GRAMMAR: a structural break the toolchain's own
grammar would never emit. The session routes off-grammar to exit 3 — the
sanctioned-rare, user-authored path to the internal-error tier — rather than
laundering a drifted report into a test verdict.
"""
from std.testing import TestSuite, assert_true


def test_one() raises:
    assert_true(True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
    print("Summary [ 0.00s ] 1 tests run: 1 passed , 0 failed , 0 skipped ")
