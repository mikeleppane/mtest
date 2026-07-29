"""Integration tests for whether an env base collects at all.

Split out of `test_session_store.mojo` on cost, not on subject. Collecting a
base against the real toolchain reads and hashes the compiler on PATH and every
entry beside it, which is by far the largest fixed cost a suite here can carry;
a case that disables BEFORE reaching the toolchain costs nothing.
`test_env_base_enabled_for_the_real_toolchain` is the one test here that pays
that price, and it pays it deliberately: the pinned toolchain's own layout is
what it is asserting about. Every other suite that drives a session keys a
wrapper instead, through `session_fixtures.base_config`. The early-refusal
cases ride along because they are the same question — does this config key? —
answered the other way.

The framing cases, which stand up a stub toolchain instead of keying the real
one, live in `test_session_store_toolchain_frame.mojo`.
"""
from std.testing import TestSuite, assert_false, assert_true, assert_equal

from cache_fixtures import env_base
from session_fixtures import base_config, real_toolchain_config
from tmptree import temp_root


def test_env_base_enabled_for_the_real_toolchain() raises:
    # The bare `mojo` spelling is the contract default, so this is the shape a
    # user's first run takes: PATH resolution, the compiler's own digest, the
    # version banner, and the library directory shipped beside it all have to
    # come back before a key exists at all. Nothing here stands in for any of
    # them — a stub would prove the layout of the stub.
    var root = temp_root()
    var ctx = env_base(real_toolchain_config(), root)
    assert_true(ctx.enabled, "cache off: " + ctx.disable_reason)
    assert_equal(ctx.disable_reason, "")
    assert_false(ctx.warned)
    assert_equal(ctx.built_files, 0)
    assert_equal(ctx.cached_files, 0)
    assert_equal(len(ctx.extra_walk_dirs), 0)


def test_env_base_disables_on_unknown_arg() raises:
    var root = temp_root()
    var config = base_config()
    config.build_args = ["--sysroot=/x"]
    var ctx = env_base(config^, root)
    assert_false(ctx.enabled)
    # The reason names the token, because that is the thing the user can remove.
    assert_true(
        "--sysroot=/x" in ctx.disable_reason,
        "reason did not name the token: " + ctx.disable_reason,
    )


def test_env_base_disables_on_unresolvable_compiler() raises:
    var root = temp_root()
    var config = base_config()
    config.mojo_path = "mtest-absent-compiler"
    var ctx = env_base(config^, root)
    assert_false(ctx.enabled)
    assert_true(
        "mtest-absent-compiler" in ctx.disable_reason,
        "reason did not name the compiler: " + ctx.disable_reason,
    )


def test_env_base_disables_on_missing_arg_file() raises:
    var root = temp_root()
    var config = base_config()
    config.build_args = ["-Xlinker", "absent.o"]
    var ctx = env_base(config^, root)
    assert_false(ctx.enabled)
    assert_true(
        "absent.o" in ctx.disable_reason,
        "reason did not name the token: " + ctx.disable_reason,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
