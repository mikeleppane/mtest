"""Table tests for the PURE `--shard` partition and its FNV-1a hash (Layer 4).

`fnv1a64` is pinned against canonical FNV-1a-64 REFERENCE VECTORS: if the frozen
constants (offset basis `0xcbf29ce484222325`, prime `0x100000001b3`) or the
byte order were wrong, these three vectors would not reproduce, so they are the
oracle for the algorithm — never the other way round.

`partition` is pinned by its DEFINING PROPERTIES over a fixed set of fake paths,
for both modes and several `N`: the shards UNION to the whole input, are pairwise
DISJOINT, hash assignment is INDEPENDENT of input order, and slice assignment is
by SORTED index. `_parse_shard`'s grammar is pinned by the accept/reject rows.
No processes, no filesystem — pure logic only.
"""
from std.builtin.sort import sort
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from mtest.cli.parser import _parse_shard
from mtest.config import ShardMode
from mtest.session import fnv1a64, partition, shard_owns


# --- FNV-1a-64 reference vectors (the algorithm's oracle) ---


def test_fnv1a64_empty_is_offset_basis() raises:
    assert_equal(fnv1a64(""), 0xCBF29CE484222325)


def test_fnv1a64_a() raises:
    assert_equal(fnv1a64("a"), 0xAF63DC4C8601EC8C)


def test_fnv1a64_foobar() raises:
    assert_equal(fnv1a64("foobar"), 0x85944171F73967E8)


def test_fnv1a64_is_deterministic() raises:
    assert_equal(
        fnv1a64("tests/unit/test_x.mojo"), fnv1a64("tests/unit/test_x.mojo")
    )


# --- a fixed universe of fake paths (already lexicographically sorted) ---


def _fake_paths() -> List[String]:
    return [
        String("tests/unit/test_a.mojo"),
        String("tests/unit/test_b.mojo"),
        String("tests/unit/test_c.mojo"),
        String("tests/unit/test_d.mojo"),
        String("tests/unit/test_e.mojo"),
        String("tests/unit/test_f.mojo"),
        String("tests/unit/test_g.mojo"),
        String("tests/unit/test_h.mojo"),
        String("tests/unit/test_i.mojo"),
        String("tests/unit/test_j.mojo"),
        String("tests/unit/test_k.mojo"),
        String("tests/unit/test_l.mojo"),
    ]


def _contains(haystack: List[String], needle: String) -> Bool:
    for h in haystack:
        if h == needle:
            return True
    return False


def _assert_union_and_disjoint(mode: ShardMode, n: Int) raises:
    """Every path lands in exactly one shard of `1..n` (union + disjoint)."""
    var universe = _fake_paths()
    for i in range(len(universe)):
        var seen = 0
        for m in range(1, n + 1):
            var shard = partition(universe.copy(), mode, m, n)
            if _contains(shard, universe[i]):
                seen += 1
        assert_equal(
            seen, 1, "path must land in exactly one shard: " + universe[i]
        )


def test_hash_union_and_disjoint_n2() raises:
    _assert_union_and_disjoint(ShardMode.HASH, 2)


def test_hash_union_and_disjoint_n3() raises:
    _assert_union_and_disjoint(ShardMode.HASH, 3)


def test_hash_union_and_disjoint_n5() raises:
    _assert_union_and_disjoint(ShardMode.HASH, 5)


def test_slice_union_and_disjoint_n2() raises:
    _assert_union_and_disjoint(ShardMode.SLICE, 2)


def test_slice_union_and_disjoint_n3() raises:
    _assert_union_and_disjoint(ShardMode.SLICE, 3)


def test_slice_union_and_disjoint_n5() raises:
    _assert_union_and_disjoint(ShardMode.SLICE, 5)


def test_single_shard_owns_everything() raises:
    # N == 1: shard 1/1 is the whole suite in both modes.
    var universe = _fake_paths()
    var h = partition(universe.copy(), ShardMode.HASH, 1, 1)
    var s = partition(universe.copy(), ShardMode.SLICE, 1, 1)
    assert_equal(len(h), len(universe))
    assert_equal(len(s), len(universe))


def test_hash_assignment_independent_of_input_order() raises:
    # Shuffling the input must not move a file to a different shard.
    var forward = _fake_paths()
    var reversed = List[String]()
    for i in range(len(forward) - 1, -1, -1):
        reversed.append(forward[i])
    var n = 3
    for m in range(1, n + 1):
        var a = partition(forward.copy(), ShardMode.HASH, m, n)
        var b = partition(reversed.copy(), ShardMode.HASH, m, n)
        # Same membership set (order may differ, but the SET must match).
        assert_equal(len(a), len(b), "hash shard size must be order-invariant")
        for p in a:
            assert_true(
                _contains(b, p), "hash membership moved with order: " + p
            )


def test_hash_partition_preserves_input_order() raises:
    var universe = _fake_paths()
    var shard = partition(universe.copy(), ShardMode.HASH, 1, 3)
    # The owned subset appears in the same relative order as the input.
    var last = -1
    for p in shard:
        var at = -1
        for i in range(len(universe)):
            if universe[i] == p:
                at = i
        assert_true(at > last, "partition must preserve input order")
        last = at


def test_slice_assignment_is_by_sorted_index() raises:
    # Slice deals round-robin by index: shard m owns indices i with i%n==m-1.
    var universe = _fake_paths()
    var n = 3
    for m in range(1, n + 1):
        var shard = partition(universe.copy(), ShardMode.SLICE, m, n)
        var expected = List[String]()
        for i in range(len(universe)):
            if i % n == m - 1:
                expected.append(universe[i])
        assert_equal(len(shard), len(expected))
        for i in range(len(expected)):
            assert_equal(shard[i], expected[i])


def test_shard_owns_matches_partition_hash() raises:
    # shard_owns is the single-path oracle partition uses for hash mode.
    var universe = _fake_paths()
    var m = 2
    var n = 4
    var shard = partition(universe.copy(), ShardMode.HASH, m, n)
    for p in universe:
        assert_equal(
            shard_owns(p, m, n),
            _contains(shard, p),
            "shard_owns disagrees with partition for " + p,
        )


# --- grammar: _parse_shard (imported from the cli parser) ---


def test_grammar_accepts_bare_m_over_n() raises:
    var got = _parse_shard("2/5")
    assert_true(got[0] == ShardMode.HASH)
    assert_equal(got[1], 2)
    assert_equal(got[2], 5)


def test_grammar_accepts_hash_prefix() raises:
    var got = _parse_shard("hash:2/5")
    assert_true(got[0] == ShardMode.HASH)
    assert_equal(got[1], 2)
    assert_equal(got[2], 5)


def test_grammar_accepts_slice_prefix() raises:
    var got = _parse_shard("slice:2/5")
    assert_true(got[0] == ShardMode.SLICE)
    assert_equal(got[1], 2)
    assert_equal(got[2], 5)


def _assert_shard_rejected(value: String) raises:
    with assert_raises(contains="1<=M<=N"):
        _ = _parse_shard(value)


def test_grammar_rejects_zero_m() raises:
    _assert_shard_rejected("0/5")


def test_grammar_rejects_m_over_n() raises:
    _assert_shard_rejected("6/5")


def test_grammar_rejects_zero_n() raises:
    _assert_shard_rejected("2/0")


def test_grammar_rejects_non_digit() raises:
    _assert_shard_rejected("x/5")


def test_grammar_rejects_missing_slash() raises:
    _assert_shard_rejected("2")


def test_grammar_rejects_empty_after_prefix() raises:
    _assert_shard_rejected("hash:")


def test_grammar_rejects_empty() raises:
    _assert_shard_rejected("")


def test_grammar_rejects_unknown_prefix() raises:
    _assert_shard_rejected("bogus:2/5")
