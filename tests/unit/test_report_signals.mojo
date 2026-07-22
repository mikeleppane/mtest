"""Pure tests for platform-aware report-layer signal narration."""

from std.sys.info import CompilationTarget
from std.testing import assert_equal

from mtest.report.signals import (
    _signal_name_for_platform,
    signal_name_for_target,
)


def _assert_names(
    numbers: List[Int], expected: List[String], is_macos: Bool
) raises:
    """Assert one platform's complete named-signal table exactly."""
    assert_equal(len(numbers), len(expected))
    for i in range(len(numbers)):
        assert_equal(
            _signal_name_for_platform(numbers[i], is_macos), expected[i]
        )


def test_linux_signal_table_preserves_every_existing_name() raises:
    _assert_names(
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 13, 15],
        [
            "SIGHUP, hangup",
            "SIGINT, interrupt",
            "SIGQUIT, quit",
            "SIGILL, illegal instruction",
            "SIGTRAP, trace/breakpoint trap",
            "SIGABRT, abort",
            "SIGBUS, bus error",
            "SIGFPE, floating-point exception",
            "SIGKILL, killed",
            "SIGSEGV, segmentation fault",
            "SIGPIPE, broken pipe",
            "SIGTERM, terminated",
        ],
        False,
    )
    assert_equal(_signal_name_for_platform(10, False), "")


def test_darwin_signal_table_pins_emt_and_bus_numbers() raises:
    _assert_names(
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15],
        [
            "SIGHUP, hangup",
            "SIGINT, interrupt",
            "SIGQUIT, quit",
            "SIGILL, illegal instruction",
            "SIGTRAP, trace/breakpoint trap",
            "SIGABRT, abort",
            "SIGEMT, emulation trap",
            "SIGFPE, floating-point exception",
            "SIGKILL, killed",
            "SIGBUS, bus error",
            "SIGSEGV, segmentation fault",
            "SIGPIPE, broken pipe",
            "SIGTERM, terminated",
        ],
        True,
    )


def test_unknown_signal_falls_back_to_the_bare_number_on_both_platforms() raises:
    for signo in [0, 31, 62]:
        assert_equal(_signal_name_for_platform(signo, False), "")
        assert_equal(_signal_name_for_platform(signo, True), "")


def test_target_entry_selects_the_compilation_platform() raises:
    assert_equal(
        signal_name_for_target(7),
        _signal_name_for_platform(7, CompilationTarget.is_macos()),
    )
