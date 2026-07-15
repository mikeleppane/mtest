"""Probe fixture: a test that raises a plain (non-assertion) error.

Pins the failure-detail shape for a bare `raise Error(...)` rather than an
assertion helper, and pins a MULTILINE error message containing indentation, so
the transcript captures how the report reflows embedded newlines.
"""
from std.testing import TestSuite


def test_raises_plain_error() raises:
    raise Error("boom:\n  fake detail line")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
