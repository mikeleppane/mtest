# Assertion diagnostics

The package includes an optional source-only
`mtest.assertions.assert_equal`. It still raises an ordinary error inside
`TestSuite`; the runner, report format, and exit code do not change. Add the
installed source root to both the test compiler and mtest:

```mojo
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
```

```console
$ mtest --no-config --no-cache --show-output failures \
    -I <PREFIX>/share/mtest/companions/assertions/src \
    companions/assertions/examples
mtest 1.1.0 (mojo)
root: <REPO>   selected: 1 files   excluded: 0

FAIL           companions/assertions/examples/test_diagnostics.mojo  <TIME>

--- FAIL companions/assertions/examples/test_diagnostics.mojo::test_text_difference_has_scalar_and_context ---
    | At companions/assertions/examples/test_diagnostics.mojo:13:28: text differs at scalar 6
    |   actual: U+0062 'b'
    |   expected: U+0042 'B'
    |   actual line 1: alpha\n
    |   actual line 2: beta\n
    |   actual line 3: gamma
    |   expected line 1: alpha\n
    |   expected line 2: BETa\n
    |   expected line 3: gamma
    |   reason: configuration text changed
reproduce: mtest -I <PREFIX>/share/mtest/companions/assertions/src companions/assertions/examples/test_diagnostics.mojo::test_text_difference_has_scalar_and_context

--- FAIL companions/assertions/examples/test_diagnostics.mojo (exit 1) — captured output (file-scoped; TestSuite does not attribute output to individual tests) ---
--- captured stderr ---
    | stack trace was not collected. Enable stack trace collection with environment variable `MODULAR_DEBUG=stack-trace-on-error`
    | Unhandled exception caught during execution:
    | Running 2 tests for <REPO>/companions/assertions/examples/test_diagnostics.mojo
    |     PASS [ <TIME> ] test_standard_assertion_still_coexists
    |     FAIL [ <TIME> ] test_text_difference_has_scalar_and_context
    |       At <REPO>/companions/assertions/examples/test_diagnostics.mojo:13:28: text differs at scalar 6
    |         actual: U+0062 'b'
    |         expected: U+0042 'B'
    |         actual line 1: alpha\n
    |         actual line 2: beta\n
    |         actual line 3: gamma
    |         expected line 1: alpha\n
    |         expected line 2: BETa\n
    |         expected line 3: gamma
    |         reason: configuration text changed
    | --------
    | Summary [ <TIME> ] 2 tests run: 1 passed , 1 failed , 0 skipped
    | Test suite' <REPO>/companions/assertions/examples/test_diagnostics.mojo 'failed!
    |


===== 1 passed, 1 failed, 0 skipped, builds: 1, cached: 0 (0 excluded, 0 not run) in <TIME> =====
```

That output was captured from the installed `.conda` artifact. The companion
specializes only top-level `String`, `List[T]`, and `Dict[String, V]`; nested
containers and custom values are displayed opaquely. List details show at most
eight entries per side, and dictionary details show at most eight entries in
each of the missing, unexpected, and changed categories. Their `omitted by
entry limit` counts describe that eight-entry selection. Dictionary keys whose
escaped display would exceed 1024 bytes are omitted from structural rows and
counted separately by `omitted by key display limit`; category totals and
displayable short-key details remain. Structural key and category order is
deterministic; opaque values retain their own `Writable` formatting, including
any ordering it chooses.

Finalized opaque-value projections are at most 1024 bytes, text context is at
most 4096 bytes, and a complete assertion body is at most 16384 bytes. Text
context shows the differing line and at most two lines on either side;
`... [cropped]` marks omitted whole lines outside that window. A bare leading
`... ` marks bytes cropped from the start of a retained long line. Each byte
cap includes a complete `... [truncated]` marker at the point where that
projection or body omitted bytes; later detail can follow a per-operand marker.
Equality is exact; a passing assertion formats nothing, while a failing
assertion formats each displayed operand once. These limits bound bytes
finalized and emitted by the companion, not private work performed inside
user-defined equality or formatting code. A present reason retains bounded
space at the end even when mismatch detail is truncated.

`<PREFIX>/share/mtest/companions/assertions/src` is one complete source package named
`mtest`, not an extension merged into another `mtest` package. Put it before
any other include root that provides `mtest`. The runner never injects this
path automatically, and Mojo does not merge it with the runner-private
precompiled package. Source-file permissions follow the environment's prefix
policy; shared-prefix installs may therefore be group-writable but are never
accepted as world-writable by the package verifier.

Only `mtest.assertions.assert_equal` is supported. The shipped underscore
modules are source implementation details, even though Mojo can import an
explicit source-module path.
