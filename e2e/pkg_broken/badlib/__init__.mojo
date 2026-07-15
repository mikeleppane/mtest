"""Deliberately broken package for the --precompile failure scenario.

`mojo precompile e2e/pkg_broken/badlib` fails at name resolution (the return
value names a symbol that does not exist). A failing precompile step has no test
identity to attach to, so the runner prints one PRECOMPILE-ERROR banner, lists
every dependent test file as a casualty, and exits 1.
"""


def broken(value: Int) -> Int:
    return this_symbol_does_not_exist(value)
