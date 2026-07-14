"""Importable package precompiled by the --precompile success scenario.

`mojo precompile testdata/pkg/mathlib` produces build/mathlib.mojopkg; its
directory is auto-added to the include path so test_uses_pkg.mojo can resolve
`from mathlib import doubled`.
"""


def doubled(value: Int) -> Int:
    return value * 2
