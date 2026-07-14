"""Known-outcome fixture: a file that parses cleanly but will not compile.

Verdict COMPILE-ERROR, exit-class 1. The call below names a function that is
never defined, so `mojo format` succeeds (the source is syntactically valid) but
`mojo build` fails at name resolution. This is a broken TEST file, and must be
reported as the file's fault (COMPILE-ERROR), never as a bug in the runner.
"""
from std.testing import assert_equal, TestSuite


def test_calls_an_undefined_symbol() raises:
    var value = this_symbol_is_never_defined_anywhere()
    assert_equal(value, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
