"""The R4 interrupt primitive for `exec`: sigaction handlers over a latch flag.

Proves the one new FFI surface end to end: installing SIGINT/SIGTERM handlers via
`sigaction`, self-signaling, and observing the latching flag flip; then that a
supervised run bails out promptly when the interrupt is already set instead of
waiting out a deadline.

Kept in its own module because the interrupt flag latches for the life of the
process, so these tests reset it explicitly and share no state with the others.
"""
from std.testing import assert_true, assert_false, TestSuite

from mtest.exec import (
    ProcessSpec,
    run_supervised,
    install_signal_handlers,
    interrupt_requested,
)
from mtest.exec.signals import _reset_interrupt, _raise_self

from exec_helpers import target, py_spec

comptime _SIGINT = 2


def test_sigaction_self_signal_flips_flag() raises:
    install_signal_handlers()
    _reset_interrupt()
    assert_false(interrupt_requested(), "flag should start clear")
    _raise_self(_SIGINT)
    # The async-signal-safe handler set the latching flag; we observe it.
    assert_true(interrupt_requested(), "SIGINT handler did not set the flag")
    _reset_interrupt()


def test_run_supervised_bails_out_promptly_on_interrupt() raises:
    install_signal_handlers()
    _reset_interrupt()
    _raise_self(_SIGINT)
    assert_true(interrupt_requested())
    # No deadline at all, but the pending interrupt must group-kill and return.
    var argv = List[String]()
    argv.append(target("sleeper.py"))
    var r = run_supervised(py_spec(argv^, 0))
    assert_true(r.termination.is_timed_out(), String(r.termination))
    assert_true(r.duration_ms < 5000, String(r.duration_ms))
    _reset_interrupt()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
