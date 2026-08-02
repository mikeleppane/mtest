"""Deterministic shuffle: the frozen SplitMix64 generator and Fisher-Yates.

The generator is checked against the published SplitMix64 reference vector,
then the seed-42 permutation is pinned as a cross-invocation contract: any
future `--shuffle --seed 42` reproduce line depends on this exact order.
"""
from std.builtin.sort import sort
from std.testing import TestSuite, assert_equal

from mtest.select.shuffle import SplitMix64, shuffle_strings


def test_splitmix64_known_vector() raises:
    # Published SplitMix64 reference: seed 0 -> 0xE220A8397B1DCDAF first.
    var rng = SplitMix64(0)
    assert_equal(rng.next(), UInt64(0xE220A8397B1DCDAF))


def test_exact_permutation_for_seed_42_is_frozen() raises:
    # THE frozen mapping: this exact order is a 1.x contract, hand-derived
    # from the reference next() outputs via Fisher-Yates. Never change it —
    # a change here breaks every reproduce line ever printed for seed 42.
    var a: List[String] = ["a", "b", "c", "d", "e"]
    shuffle_strings(a, 42)
    var want: List[String] = ["b", "c", "a", "e", "d"]
    assert_equal(len(a), len(want))
    for i in range(len(want)):
        assert_equal(a[i], want[i])


def test_shuffle_is_deterministic_for_a_seed() raises:
    var a: List[String] = ["a", "b", "c", "d", "e"]
    var b: List[String] = ["a", "b", "c", "d", "e"]
    shuffle_strings(a, 42)
    shuffle_strings(b, 42)
    assert_equal(len(a), len(b))
    for i in range(len(a)):
        assert_equal(a[i], b[i])


def test_shuffle_is_a_permutation() raises:
    var a: List[String] = ["a", "b", "c", "d", "e"]
    shuffle_strings(a, 7)
    sort(a)
    var want: List[String] = ["a", "b", "c", "d", "e"]
    assert_equal(len(a), len(want))
    for i in range(len(want)):
        assert_equal(a[i], want[i])


def test_exact_permutations_for_seeds_7_and_9_are_frozen() raises:
    # Fixed seeds chosen at implementation time; both orders are frozen 1.x
    # contracts, hand-derived from the reference next() outputs via
    # Fisher-Yates over 8 elements the same way as the seed-42 case. Pinning
    # both exact orders subsumes the weaker claim that they merely differ —
    # a wiring claim (the seed participates), not a statistics claim.
    var a: List[String] = ["a", "b", "c", "d", "e", "f", "g", "h"]
    var b = a.copy()
    shuffle_strings(a, 7)
    shuffle_strings(b, 9)
    var want_a: List[String] = ["b", "e", "f", "c", "g", "a", "d", "h"]
    var want_b: List[String] = ["d", "g", "f", "b", "h", "a", "c", "e"]
    assert_equal(len(a), len(want_a))
    assert_equal(len(b), len(want_b))
    for i in range(len(want_a)):
        assert_equal(a[i], want_a[i])
    for i in range(len(want_b)):
        assert_equal(b[i], want_b[i])


def test_empty_and_single_are_noops() raises:
    var empty = List[String]()
    shuffle_strings(empty, 3)
    assert_equal(len(empty), 0)
    var one: List[String] = ["x"]
    shuffle_strings(one, 3)
    assert_equal(len(one), 1)
    assert_equal(one[0], "x")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
