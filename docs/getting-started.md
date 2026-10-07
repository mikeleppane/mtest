# Getting started

A working suite is five minutes away: one file to save, one run to watch pass,
and one deliberate mistake to see reported as itself. This page assumes mtest
is already in the workspace; if it is not, [install it first](install.md)
and come back.

## Save a test file

In a directory with nothing in it yet, `mtest init` is the one command that
writes all of this at once — a first test file, an `mtest.toml` pointing at
`tests/`, a `.gitignore`, and with `--ci github` a workflow — and prints the
prerequisites still to run.
[Starting a project in one command](#starting-a-project-in-one-command) below
walks through it. The rest of this page builds the same thing a piece at a
time, so you can see what each one is for.

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

Or let the runner write it, which is one command instead of a page to copy:

```console
$ pixi run mtest new tests/test_math.mojo
created tests/test_math.mojo
```

`mtest new` creates missing parent directories, refuses a basename no directory
walk would collect, and never overwrites an existing file — a second one on the
same path exits `4` and leaves your bytes alone. What it writes is one example
test rather than the two above, so follow the saved file if you are reading the
counts in the next section.

The import line matters more than it looks. The standard library's testing
module resolves under its full name on the supported toolchain, and the bare
short form does not resolve at all — which is the mistake the last section of
this page reproduces on purpose.

## Run the suite

Every test file is built and its binary executed directly, because that is the
only way a Mojo program's exit code is truthful. A compiler therefore has to be
reachable from the workspace, and it is: the package declares one as its run
dependency. Point the runner at the directory holding the file. `run` is the
default subcommand, so `mtest tests/` means `mtest run tests/`:

```console
$ pixi run mtest tests/
mtest 1.1.0 (mojo)
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
mtest 1.1.0 (mojo)
root: /tmp/mtest-quickstart   selected: 1 files   excluded: 0

COMPILE-ERROR  tests/test_math.mojo            0.00s

--- COMPILE-ERROR tests/test_math.mojo — mojo build said: ---
    | /tmp/mtest-quickstart/tests/test_math.mojo:3:6: error: unable to locate module 'testing'
    | from testing import assert_equal, TestSuite
    |      ^
    | mojo: error: failed to parse the provided Mojo source module
reproduce: mojo build tests/test_math.mojo -o build/bin/tests_stest_umath -D MTEST_SOURCE=/tmp/mtest-quickstart/tests/test_math.mojo


===== 0 passed, 0 failed, 0 skipped, 1 compile error, builds: 1, cached: 0 (0 excluded, 0 not run) in 1.0s =====
$ echo $?
1
```

The reproduce line is the exact build invocation the runner used, so a compile
error can be investigated outside the runner without reconstructing anything by
hand.

## Starting a project in one command

`mtest init` writes the files a project needs into the current directory:

```console
$ pixi run mtest init --ci github
created tests/test_example.mojo
created mtest.toml
created .github/workflows/test.yml
created .gitignore
next: pixi init .
next: pixi workspace channel add https://conda.modular.com/max/
next: pixi workspace channel add https://repo.prefix.dev/modular-community
next: pixi add mtest
next: mtest
next: commit pixi.toml and pixi.lock, which the workflow installs from
```

Drop `--ci github` and neither the workflow nor the commit line appears. The
`next:` lines are prerequisites rather than suggestions, and they are ordered:
`pixi workspace channel add` fails outright without a `pixi.toml`, `mtest` does
not resolve until the package is in the workspace, and the workflow just
written installs from the lock file, which `pixi add` is what produces. They
repeat the [installation](install.md) sequence because `init` cannot see
whether you have run it — in a workspace that already has mtest, every line
before `next: mtest` is already done and `pixi init .` would fail if you ran
it again.

**Nothing existing is replaced.** Every artifact is published without
overwriting, so a second `init` reports each one as `skipped` and still exits
`0`, and a file you have already edited is left exactly as it was.
`.gitignore` is the one file `init` edits rather than creates: the
`.mtest-cache/` and `build/bin/` entries — mtest's working state, and the
binaries it compiles your test files into — are appended to whatever is already
there, and only the ones actually missing are added. A `.gitignore` that is a
symlink or not a regular file is refused (exit `4`) before any artifact is
written.

## Where to go next

Selection, retries, timeouts, sharding, the machine-readable reporters, and
project configuration are all in [Usage](usage.md), and every flag is listed in
the [CLI reference](cli-reference.md) and specified exactly in the
[command-line contract](cli-contract.md). If the next thing you want is a
pipeline rather than a flag, go to [continuous integration](ci.md).
