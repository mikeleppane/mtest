"""Integration tests for the toolchain memo and the identity it caches.

Split out of `test_session_store.mojo` on cost. Reading and hashing the real
compiler is seconds of I/O, and `test_toolchain_identity_memoizes_the_same_answer`
does it end to end on purpose — proving the memo answers a second call exactly
as it answered the first is the whole point, and a stub compiler would prove it
of the stub. The memo is process-lifetime, so that price is paid once per suite;
keeping this file apart from the other real-toolchain suites is what stops two
such payments landing inside one per-file deadline.

The unit-level memo cases ride along because they are the same subject from
below: what the record can hold, what it refuses, and what it discriminates on.
"""
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mtest.platform import resolve_executable
from mtest.session.store import (
    _MEMO_PATH_CAP,
    _ToolchainMemo,
    _toolchain_identity,
)

from cache_fixtures import env_base, executable_stub
from session_fixtures import base_config
from tmptree import temp_root


comptime _HEX64 = (
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
)
"""A well-formed 64-character digest rendering, standing in for a real one."""


def test_toolchain_memo_starts_matching_nothing() raises:
    # The empty slot every process starts with. If it ever matched, the first
    # lookup in a process would answer with a digest nobody computed.
    var empty = _ToolchainMemo()
    assert_false(empty.matches("/usr/bin/mojo", 141))
    assert_false(empty.matches("", 0))


def test_toolchain_memo_round_trips_a_stored_digest() raises:
    var stored = _ToolchainMemo.of("/usr/bin/mojo", 141, _HEX64)
    assert_true(stored, "a plain path and digest were refused")
    var memo = stored.value().copy()
    assert_true(memo.matches("/usr/bin/mojo", 141))
    # The rebuilt string is the property a hit rests on: a memoized run and a
    # cold run must frame identical bytes, so the digest has to come back
    # character for character.
    assert_equal(memo.sha_hex(), _HEX64)


def test_toolchain_memo_discriminates_path_and_size() raises:
    var memo = _ToolchainMemo.of("/usr/bin/mojo", 141, _HEX64).value().copy()
    # Size is the field that catches a toolchain swap changing the binary's
    # length; path is the field that catches a different compiler entirely.
    assert_false(memo.matches("/usr/bin/mojo", 142))
    assert_false(memo.matches("/usr/local/bin/mojo", 141))
    # A prefix and an extension of the stored path are both misses: the
    # comparison is on the whole path, not on what fits.
    assert_false(memo.matches("/usr/bin/moj", 141))
    assert_false(memo.matches("/usr/bin/mojoo", 141))


def test_toolchain_memo_refuses_what_it_cannot_hold_exactly() raises:
    # Every refusal costs one recomputation and nothing else. Truncating instead
    # is what would be dangerous: two compilers sharing a long prefix would
    # start matching each other.
    var long_path = String("/")
    while long_path.byte_length() <= _MEMO_PATH_CAP:
        long_path += "abcdefgh"
    assert_false(
        Bool(_ToolchainMemo.of(long_path, 141, _HEX64)),
        "an over-long path was stored rather than refused",
    )
    assert_false(
        Bool(_ToolchainMemo.of("", 141, _HEX64)),
        "an empty path was stored, forging the empty-slot marker",
    )
    assert_false(
        Bool(_ToolchainMemo.of("/usr/bin/mojo", 141, "abc")),
        "a short digest was stored rather than refused",
    )
    assert_false(
        Bool(_ToolchainMemo.of("/usr/bin/mojo", 141, _HEX64 + "0")),
        "an over-long digest was stored rather than refused",
    )
    # The longest path that still fits is stored, so the refusal is a boundary
    # and not an off-by-one that quietly shrinks the memo.
    var exact = String("/")
    while exact.byte_length() < _MEMO_PATH_CAP:
        exact += "a"
    var stored = _ToolchainMemo.of(exact, 141, _HEX64)
    assert_true(stored, "a path of exactly the capacity was refused")
    assert_true(stored.value().matches(exact, 141))


def test_toolchain_identity_memoizes_the_same_answer() raises:
    # The end-to-end property, over the real compiler: the second call must
    # answer identically to the first. A memo that returned anything else would
    # move the key bytes between two sessions of one process.
    var resolved = resolve_executable("mojo")
    assert_true(resolved, "the pinned compiler did not resolve")
    var path = resolved.value()
    var first = _toolchain_identity(path)
    var second = _toolchain_identity(path)
    assert_true(first, "the compiler could not be read")
    assert_true(second, "the memoized lookup failed")
    assert_equal(first.value().path, second.value().path)
    assert_equal(first.value().size, second.value().size)
    assert_equal(first.value().sha_hex, second.value().sha_hex)


def test_a_relative_compiler_resolves_against_the_run_root() raises:
    """The key must name the compiler the build child will actually execute.

    A spelling containing `/` is never PATH-searched — it is taken verbatim
    against a working directory — and the two processes involved do not share
    one. The build child `chdir`s to the run root before `execve`, while mtest
    resolves in its own. Against a root that is not mtest's own directory,
    `tools/mojo` therefore named one file in the key and ran another.

    The observable form of the divergence: the compiler exists under the root
    and nowhere near mtest's working directory, so resolving in the wrong place
    finds nothing at all and turns the cache off.
    """
    var root = temp_root()
    _ = executable_stub(root, "tools/mojo")
    var config = base_config()
    config.mojo_path = String("tools/mojo")

    var ctx = env_base(config^, root)
    assert_true(
        ctx.enabled,
        "the cache was disabled over a compiler that is right there: "
        + ctx.disable_reason,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
