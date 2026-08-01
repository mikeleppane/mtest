# Getting started

A working suite is five minutes away: one file to save, one run to watch pass,
and one deliberate mistake to see reported as itself. This page assumes mtest
is already in the workspace; if it is not, [install it first](index.md#install)
and come back.

## Save a test file

A test file is an ordinary Mojo program. It declares test functions and a
`main()` that hands them to the standard library's suite, which keeps owning
discovery and the report format inside the file. Save this as
`tests/test_math.mojo`:

```mojo
"""Arithmetic examples for a first mtest run."""

from std.testing import assert_equal, TestSuite


def test_addition() raises:
    assert_equal(2 + 2, 4)


def test_multiplication() raises:
    assert_equal(3 * 7, 21)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
```

The import line matters more than it looks. The standard library's testing
module resolves under its full name on the supported toolchain, and the bare
short form does not resolve at all — which is the mistake the last section of
this page reproduces on purpose.

## Run the suite

Every test file is built and its binary executed directly, because that is the
only way a Mojo program's exit code is truthful. A compiler therefore has to be
reachable from the workspace, and it is: the package declares one as its run
dependency. Point the runner at the directory holding the file:

```console
$ pixi run mtest tests/
mtest 1.0.0 (mojo)
root: /tmp/mtest-quickstart   selected: 1 files   excluded: 0

PASS           tests/test_math.mojo            0.03s

===== 2 passed, 0 failed, 0 skipped, builds: 1, cached: 0 (0 excluded, 0 not run) in 1.3s =====
$ echo $?
0
```

Two test functions in one file report as two passes and one build, because the
summary counts individual tests rather than files. The two counters beside them
are the build cache. This store was empty, so the file was compiled rather than
reused.

## Watch a broken file be reported as itself

Now break that import — replace the full module name with the bare short form —
and run it again. A file that does not compile is a distinct outcome from a
test that failed, it is never quietly skipped, and the run exits non-zero:

```console
$ pixi run mtest tests/
mtest 1.0.0 (mojo)
root: /tmp/mtest-quickstart   selected: 1 files   excluded: 0

COMPILE-ERROR  tests/test_math.mojo            0.00s

--- COMPILE-ERROR tests/test_math.mojo — mojo build said: ---
    | /tmp/mtest-quickstart/tests/test_math.mojo:3:6: error: unable to locate module 'testing'
    | from testing import assert_equal, TestSuite
    |      ^
    | mojo: error: failed to parse the provided Mojo source module
reproduce: mojo build tests/test_math.mojo -o build/bin/tests_stest_umath


===== 0 passed, 0 failed, 0 skipped, 1 compile error, builds: 1, cached: 0 (0 excluded, 0 not run) in 1.0s =====
$ echo $?
1
```

The reproduce line is the exact build invocation the runner used, so a compile
error can be investigated outside the runner without reconstructing anything by
hand.

## Where to go next

Selection, retries, timeouts, sharding, the machine-readable reporters, and
project configuration are all in the
[Usage section of the README](https://github.com/mikeleppane/mtest#usage), and
every flag is specified exactly in the
[command-line contract](cli-contract.md). If the next thing you want is a
pipeline rather than a flag, go to [continuous integration](ci.md).
