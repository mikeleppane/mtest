"""The two-phase terminal protocol's exit-code RESOLUTION layer (Layer 4).

`_resolve_terminal_code` is the pure Phase-2 function that turns the run's
latched flags into the final process exit code, AROUND the unchanged
`exit_code_for`. It formalizes the frozen §9 precedence (an interrupt dominates
to 2, above a resolved internal error; else a latched/finalization failure is 3;
else the outcome code) plus the terminal-write-failure precedence: a resolved 2
STANDS (never displaced to 3 by a later I/O failure), a resolved 0/1/5 ESCALATES
to 3, and a resolved 3 stays 3. These tests pin those rules directly, without
building or running a session.
"""
from std.testing import assert_equal, TestSuite

from mtest.session.session import _resolve_terminal_code


def test_clean_pass_resolves_to_the_outcome_code() raises:
    # No flags set: the code is exactly the outcome code (0/1/5) `exit_code_for`
    # produced — the resolution layer is a pass-through.
    assert_equal(
        _resolve_terminal_code(False, False, False, False, 0, False), 0
    )
    assert_equal(
        _resolve_terminal_code(False, False, False, False, 1, False), 1
    )
    assert_equal(
        _resolve_terminal_code(False, False, False, False, 5, False), 5
    )


def test_interrupt_dominates_every_other_flag() raises:
    # A run-time interrupt resolves to 2 even above an internal error, drift, a
    # precompile failure, or a terminal-write failure — the frozen precedence.
    assert_equal(_resolve_terminal_code(True, True, True, True, 1, True), 2)


def test_internal_error_is_three() raises:
    assert_equal(_resolve_terminal_code(False, True, False, False, 0, False), 3)


def test_drift_is_three() raises:
    assert_equal(_resolve_terminal_code(False, False, True, False, 0, False), 3)


def test_precompile_failure_is_one() raises:
    assert_equal(_resolve_terminal_code(False, False, False, True, 0, False), 1)


def test_precompile_failure_yields_to_internal_error() raises:
    # Internal error outranks a precompile failure (the 3 tier beats the 1 tier).
    assert_equal(_resolve_terminal_code(False, True, False, True, 0, False), 3)


def test_terminal_write_failure_escalates_a_clean_pass_to_three() raises:
    # A resolved 0 escalates to 3 on a terminal-write/finalization failure (a
    # dead --json pipe, or a junit finalize that could not publish).
    assert_equal(_resolve_terminal_code(False, False, False, False, 0, True), 3)


def test_terminal_write_failure_escalates_a_failing_run_to_three() raises:
    # A resolved 1 (a failing run) also escalates to 3: the product could not be
    # delivered, so the run's own verdict is no longer authoritative.
    assert_equal(_resolve_terminal_code(False, False, False, False, 1, True), 3)


def test_terminal_write_failure_escalates_the_nothing_collected_five() raises:
    assert_equal(_resolve_terminal_code(False, False, False, False, 5, True), 3)


def test_terminal_write_failure_leaves_a_resolved_three_at_three() raises:
    # A resolved 3 (internal error) stays 3 under a later write failure.
    assert_equal(_resolve_terminal_code(False, True, False, False, 0, True), 3)


def test_interrupt_stands_over_a_later_write_failure() raises:
    # The interrupt precedence is never displaced by a terminal-write failure:
    # a resolved 2 stays 2 even when finalization also failed.
    assert_equal(_resolve_terminal_code(True, False, False, False, 0, True), 2)
    assert_equal(_resolve_terminal_code(True, False, False, True, 1, True), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
