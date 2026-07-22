"""Pure supervision-policy functions: effective capacity and observation order.

`effective_cap` maps an RLIMIT_NOFILE soft limit onto the live-child ceiling the
3N+3 spawn peak can honor; `decide_kill`/`escalate_on_interrupt` encode the
Supervisor's fixed observation-order rule (deadline evaluated before interrupt)
as a pure decision table. Pinning both here keeps the numeric formula, its every
edge, and the ordering independent of any live process.
"""
from std.testing import assert_equal, assert_true, assert_false, assert_raises

from mtest.exec import (
    effective_cap,
    decide_kill,
    escalate_on_interrupt,
    KillCause,
)


def test_effective_cap_unbounded_and_large_reach_the_ceiling() raises:
    # The RLIM_INFINITY sentinel and any limit at/above headroom + 3*64 + 3.
    assert_equal(effective_cap(UInt64.MAX), 64)
    assert_equal(effective_cap(UInt64(1_000_000)), 64)
    assert_equal(effective_cap(UInt64(1024)), 64)
    # Exact boundary: 64 + 3*64 + 3 == 259 is the first limit that reaches 64.
    assert_equal(effective_cap(UInt64(259)), 64)


def test_effective_cap_formula_below_the_ceiling() raises:
    # min(64, (soft - 64 - 3) // 3): one below the boundary is 63, and the
    # macOS default of 256 lands on the same 63.
    assert_equal(effective_cap(UInt64(258)), 63)
    assert_equal(effective_cap(UInt64(256)), 63)
    # The smallest limit that fits a single child is exactly 70 -> N == 1.
    assert_equal(effective_cap(UInt64(70)), 1)
    assert_equal(effective_cap(UInt64(72)), 1)
    assert_equal(effective_cap(UInt64(73)), 2)


def test_effective_cap_below_one_is_hard_error() raises:
    # A soft limit that cannot fit even one child is a hard environment error,
    # never a silent clamp to a capacity the spawn peak cannot honor.
    with assert_raises():
        _ = effective_cap(UInt64(69))
    with assert_raises():
        _ = effective_cap(UInt64(0))


def test_effective_cap_hard_error_names_limit_and_minimum() raises:
    var message = String("")
    try:
        _ = effective_cap(UInt64(50))
    except e:
        message = String(e)
    assert_true("50" in message, message)
    assert_true("70" in message, message)


def test_decide_kill_evaluates_deadline_before_interrupt() raises:
    # Deadline expired, no interrupt -> DEADLINE.
    var only_deadline = decide_kill(True, 0)
    assert_true(only_deadline)
    assert_true(only_deadline.value().is_deadline())
    # Deadline expired AND an interrupt observed in the same sweep -> DEADLINE
    # still wins: this is the discriminating case a check-interrupt-first
    # implementation would get wrong.
    var both = decide_kill(True, 1)
    assert_true(both.value().is_deadline())
    var both_escalating = decide_kill(True, 2)
    assert_true(both_escalating.value().is_deadline())


def test_decide_kill_interrupt_without_deadline() raises:
    var one = decide_kill(False, 1)
    assert_true(one)
    assert_true(one.value().is_interrupt())
    var two = decide_kill(False, 2)
    assert_true(two.value().is_interrupt())


def test_decide_kill_no_deadline_no_interrupt_is_none() raises:
    assert_false(decide_kill(False, 0))


def test_escalate_only_on_second_activation() raises:
    assert_false(escalate_on_interrupt(0))
    assert_false(escalate_on_interrupt(1))
    assert_true(escalate_on_interrupt(2))


def test_kill_cause_equality_and_render() raises:
    assert_equal(KillCause.deadline(), KillCause.deadline())
    assert_true(KillCause.deadline() != KillCause.interrupt())
    assert_equal(String(KillCause.deadline()), "KillCause.DEADLINE")
    assert_equal(String(KillCause.interrupt()), "KillCause.INTERRUPT")
