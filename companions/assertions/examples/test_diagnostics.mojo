"""Executable example for the optional source-only assertion companion."""

import mtest.assertions as assertions
import std.testing as testing
from std.testing import TestSuite


def test_standard_assertion_still_coexists() raises:
    testing.assert_equal(2 + 2, 4)


def test_text_difference_has_scalar_and_context() raises:
    assertions.assert_equal(
        "alpha\nbeta\ngamma",
        "alpha\nBETa\ngamma",
        msg="configuration text changed",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
