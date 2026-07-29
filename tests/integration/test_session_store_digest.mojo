"""Integration tests for what moves an env base's digest.

Split out of `test_session_store.mojo` on cost. These key the REAL toolchain,
and the first such collection in a process reads and hashes the compiler on
PATH and everything beside it — seconds of I/O, after which a process-lifetime
memo makes the rest of this file nearly free. That one-off is why these tests
sit together and away from the other suites that also key the real toolchain:
each such suite pays the price exactly once, and no per-file deadline carries
two of them.

The subject is coherent on its own terms. A digest that fails to move when a
build input changes is the one failure a cache must never have, so each test
here changes exactly one input and demands a different key.
"""
from std.os import getenv, setenv, unsetenv
from std.testing import (
    TestSuite,
    assert_equal,
    assert_not_equal,
    assert_true,
)

from cache_fixtures import base_digest, env_base
from session_fixtures import base_config, write_file
from tmptree import temp_root


def test_env_base_digest_is_stable_across_calls() raises:
    var root = temp_root()
    var first = env_base(base_config(), root)
    var second = env_base(base_config(), root)
    assert_true(first.enabled, "cache off: " + first.disable_reason)
    assert_true(second.enabled, "cache off: " + second.disable_reason)
    # THE property every future cache hit rests on. If two collections over
    # unchanged inputs ever disagree — an unsorted listing, an absolute path
    # leaking into a frame, a memo returning something other than what it
    # replaced — the cache degrades to a rebuild every time and nothing else in
    # the suite would notice.
    assert_equal(base_digest(first), base_digest(second))


def test_env_base_digest_moves_with_build_args() raises:
    var root = temp_root()
    var plain = env_base(base_config(), root)
    var one = base_config()
    one.build_args = ["-O2"]
    var flagged = env_base(one^, root)
    assert_true(flagged.enabled, "cache off: " + flagged.disable_reason)
    assert_not_equal(base_digest(plain), base_digest(flagged))

    var forward = base_config()
    forward.build_args = ["-O2", "--no-optimization"]
    var backward = base_config()
    backward.build_args = ["--no-optimization", "-O2"]
    # Frame ORDER inside field 7: the same two flags in the other order are a
    # different command line and must be a different key.
    assert_not_equal(
        base_digest(env_base(forward^, root)),
        base_digest(env_base(backward^, root)),
    )


def test_env_base_digest_moves_with_environment() raises:
    var root = temp_root()
    # `MODULAR_HOME` relocates the compiler's module cache, so it is keyed. It
    # is restored exactly, including the "was not set at all" case, which is a
    # different fact from "set to the empty string" and keys differently.
    var was_set = getenv("MODULAR_HOME", "\x01unset") != "\x01unset"
    var saved = getenv("MODULAR_HOME", "")
    # Collected into a list rather than three pre-declared strings so the
    # `finally` restore is never skipped and no dead initializer is needed.
    var digests = List[String]()
    try:
        _ = setenv("MODULAR_HOME", "/tmp/mtest-modular-here", True)
        digests.append(base_digest(env_base(base_config(), root)))
        _ = setenv("MODULAR_HOME", "/tmp/mtest-modular-there", True)
        digests.append(base_digest(env_base(base_config(), root)))
        _ = unsetenv("MODULAR_HOME")
        digests.append(base_digest(env_base(base_config(), root)))
    finally:
        if was_set:
            _ = setenv("MODULAR_HOME", saved, True)
        else:
            _ = unsetenv("MODULAR_HOME")
    assert_equal(len(digests), 3)
    assert_not_equal(digests[0], digests[1])
    assert_not_equal(digests[0], digests[2])
    assert_not_equal(digests[1], digests[2])


def test_env_base_digest_moves_with_root() raises:
    var here = temp_root()
    var there = temp_root()
    # Field 6 is the CANONICAL root, so two runs of the same sources from two
    # checkouts do not share a generation.
    assert_not_equal(
        base_digest(env_base(base_config(), here)),
        base_digest(env_base(base_config(), there)),
    )


def test_env_base_records_include_dir_args() raises:
    var root = temp_root()
    write_file(root, "extra/top.mojo", "# a")
    var config = base_config()
    config.build_args = ["-I", "extra"]
    var ctx = env_base(config^, root)
    assert_true(ctx.enabled, "cache off: " + ctx.disable_reason)
    assert_equal(len(ctx.extra_walk_dirs), 1)
    assert_equal(ctx.extra_walk_dirs[0], "extra")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
