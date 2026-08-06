"""Tests for the one compiler command line every spawn site runs.

Four sites emit it — the selection build, the sequential attempt loop, the
parallel pool, and the precompile step — and the vector is not private detail:
it is what a verdict's reproduce line quotes and what the artifact store records
beside a published generation. These cases pin the exact tokens and their order.
"""
from std.testing import TestSuite, assert_equal, assert_true

from mtest.session.build import build_argv


def _joined(argv: List[String]) -> String:
    """The command line as one space-joined string, for exact comparison."""
    var out = String("")
    for i in range(len(argv)):
        if i > 0:
            out += " "
        out += argv[i]
    return out^


def test_build_argv_is_exact_for_a_test_file() raises:
    assert_equal(
        _joined(
            build_argv(
                "mojo",
                "build",
                ["build", "vendor"],
                ["--Werror", "-O0"],
                "build/bin/tests_stest_ua",
                "tests/test_a.mojo",
            )
        ),
        (
            "mojo build tests/test_a.mojo -o build/bin/tests_stest_ua"
            " -I build -I vendor --Werror -O0"
        ),
    )


def test_build_argv_is_exact_for_a_precompile_step() raises:
    # The verb is the only variation point across the four sites: a precompile
    # step threads the same includes and the same configured build arguments.
    assert_equal(
        _joined(
            build_argv(
                "/opt/mojo",
                "precompile",
                ["src"],
                ["--Werror"],
                "build/.tmp/helper.mojopkg",
                "src/helper",
            )
        ),
        (
            "/opt/mojo precompile src/helper -o build/.tmp/helper.mojopkg"
            " -I src --Werror"
        ),
    )


def test_build_argv_needs_no_includes_and_no_build_args() raises:
    assert_equal(
        _joined(
            build_argv(
                "mojo",
                "build",
                List[String](),
                List[String](),
                "build/bin/x",
                "tests/test_x.mojo",
            )
        ),
        "mojo build tests/test_x.mojo -o build/bin/x",
    )


def test_build_argv_puts_the_configured_arguments_last() raises:
    # Last, so a user's `--build-arg` can still override an include or an option
    # the runner supplied ahead of it.
    var argv = build_argv(
        "mojo",
        "build",
        ["build"],
        ["-O3", "--debug-level", "none"],
        "build/bin/x",
        "tests/test_x.mojo",
    )
    assert_equal(len(argv), 10)
    assert_equal(argv[7], "-O3")
    assert_equal(argv[8], "--debug-level")
    assert_equal(argv[9], "none")


def test_build_argv_emits_o_and_its_path_as_two_tokens() raises:
    # The store's `_rewrite_output` repoints a published generation's reproduce
    # line by matching `-o` and taking the token after it. A site that joined
    # them would leave a line naming a staging directory the rename consumed.
    var argv = build_argv(
        "mojo",
        "build",
        List[String](),
        List[String](),
        ".mtest-cache/build-v1/.tmp-x/bin",
        "tests/test_x.mojo",
    )
    assert_equal(argv[3], "-o")
    assert_equal(argv[4], ".mtest-cache/build-v1/.tmp-x/bin")


def test_build_argv_never_carries_the_pools_thread_token() raises:
    # `--num-threads` is a scheduling token for one spawn, never part of a
    # command a user reruns, so the pool appends it to its spawn argv only
    # AFTER recording the canonical line this builder produces.
    var argv = build_argv(
        "mojo",
        "build",
        ["build"],
        ["--Werror"],
        "build/bin/x",
        "tests/test_x.mojo",
    )
    for token in argv:
        assert_true(
            token != "--num-threads",
            "the canonical build argv must carry no scheduling token",
        )


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
