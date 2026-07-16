"""Known-outcome fixture: a module with a helper but ZERO test_ functions.

Verdict PASS, exit-class 0 — the documented ceiling. A single file that
collects no tests runs cleanly and exits 0, so the runner counts it PASS. (A
whole session that collects nothing across every file is the separate exit-5
case; one empty file is not an error.)
"""
from std.testing import TestSuite


def _not_a_test() -> Int:
    return 42


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
