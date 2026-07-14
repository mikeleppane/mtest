"""Known-outcome fixture: a test that imports a precompiled package.

Verdict PASS, exit-class 0 — but ONLY under `--precompile testdata/pkg/mathlib`.
Without the precompiled mathlib package on the include path this file fails to
resolve `from mathlib import doubled`, so it is never run outside the precompile
scenario. Its success proves both `--precompile` and the automatic `-I` that
makes the built package resolvable.
"""
from mathlib import doubled
from std.testing import assert_equal, TestSuite


def test_uses_precompiled_pkg() raises:
    assert_equal(doubled(21), 42)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
