"""Support module that is NOT a test file — no test_ prefix.

A directory walk selects only test_*.mojo, so this file must never be collected
or reported. The manifest records it under non_discovered and the harness proves
it never appears in a default run's verdict lines.
"""
from std.testing import assert_equal


def shared_check(value: Int) raises:
    assert_equal(value, value)
