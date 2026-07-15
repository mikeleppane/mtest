"""Known-outcome fixture: a suite that prints TWO complete report blocks.

Verdict MALFORMED-SUITE, exit-class 1. It runs a real one-test TestSuite twice,
so the child emits two complete, well-formed report blocks for its own path
back to back. Two blocks is a pattern user bytes CAN produce, so the parser
classifies it AMBIGUOUS (not off-grammar), and the session reports
MALFORMED-SUITE — a forged extra block never launders into a VALID verdict.
"""
from std.testing import TestSuite, assert_true


def test_one() raises:
    assert_true(True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
    TestSuite.discover_tests[__functions_in_module()]().run()
