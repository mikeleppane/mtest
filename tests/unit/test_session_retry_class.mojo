"""Table tests for the PURE crash-class retry classifier (Layer 4).

`retry_classify` decides whether a failed step is CRASH-CLASS (a real crash or a
deadline kill, so `--retries` may re-run it) or DETERMINISTIC (a failing test, a
compile error, a flooded capture — never re-run). `has_crash_signature` is the
stderr scanner the build path consults for a compiler ICE that exits nonzero.

This module pins EVERY cell of the frozen policy table with synthesized
`Termination` + stderr inputs — no processes, no filesystem — exactly as
`test_session_verdict.mojo` and `test_session_classify.mojo` pin their policies.
"""
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.exec import Termination
from mtest.session import RetryClass, has_crash_signature, retry_classify


def _bytes(s: String) -> List[UInt8]:
    """The raw UTF-8 bytes of `s` as an owned list, for the stderr field."""
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _empty() -> List[UInt8]:
    """An empty stderr, for the paths that never consult it."""
    return List[UInt8]()


def _check(rc: RetryClass, eligible: Bool, label: String) raises:
    """Assert a classification's eligibility flag and label together."""
    if eligible:
        assert_true(rc.retry_eligible)
    else:
        assert_false(rc.retry_eligible)
    assert_equal(rc.label, label)


# ---- rule 1: spawn failure — never retried, either step -----------------------


def test_run_spawn_failed_not_eligible() raises:
    _check(
        retry_classify("run", Termination.spawn_failed(2), False, _empty()),
        False,
        "spawn-failed",
    )


def test_build_spawn_failed_not_eligible() raises:
    _check(
        retry_classify("build", Termination.spawn_failed(13), False, _empty()),
        False,
        "spawn-failed",
    )


# ---- rule 2: an interrupt is never retryable, either step ---------------------


def test_run_interrupt_not_eligible() raises:
    # A run TimedOut with interrupted=True is an interrupt, NOT a deadline.
    var t = Termination.timed_out(Termination.SIGNALED, 15, True)
    _check(retry_classify("run", t, True, _empty()), False, "interrupt")


def test_build_interrupt_not_eligible() raises:
    var t = Termination.timed_out(Termination.SIGNALED, 15, True)
    _check(retry_classify("build", t, True, _empty()), False, "interrupt")


def test_precompile_interrupt_not_eligible() raises:
    var t = Termination.timed_out(Termination.EXITED, 0, False)
    _check(retry_classify("precompile", t, True, _empty()), False, "interrupt")


# ---- rule 3: the RUN step -----------------------------------------------------


def test_run_signaled_eligible_signal() raises:
    _check(
        retry_classify("run", Termination.signaled(11), False, _empty()),
        True,
        "signal",
    )


def test_run_timeout_deadline_eligible() raises:
    # interrupted=False: a genuine deadline kill, retry-eligible.
    var t = Termination.timed_out(Termination.SIGNALED, 15, True)
    _check(retry_classify("run", t, False, _empty()), True, "run-timeout")


def test_run_exit0_deterministic() raises:
    _check(
        retry_classify("run", Termination.exited(0), False, _empty()),
        False,
        "deterministic",
    )


def test_run_exit1_deterministic() raises:
    _check(
        retry_classify("run", Termination.exited(1), False, _empty()),
        False,
        "deterministic",
    )


def test_run_exit_large_deterministic() raises:
    # Any exit code — a process that exited under its own control is not flaky.
    _check(
        retry_classify("run", Termination.exited(134), False, _empty()),
        False,
        "deterministic",
    )


def test_run_exit_with_crash_signature_still_deterministic() raises:
    # The crash-signature scan is a BUILD-only concern: an exited run is
    # deterministic even if its stderr carries a crash banner.
    var s = _bytes("PLEASE submit a bug report to https://example/\n")
    _check(
        retry_classify("run", Termination.exited(1), False, s),
        False,
        "deterministic",
    )


# ---- rule 4: the BUILD / PRECOMPILE step --------------------------------------


def test_build_signaled_eligible_compile_crash() raises:
    _check(
        retry_classify("build", Termination.signaled(11), False, _empty()),
        True,
        "compile-crash",
    )


def test_build_timeout_deadline_eligible() raises:
    var t = Termination.timed_out(Termination.SIGNALED, 15, True)
    _check(retry_classify("build", t, False, _empty()), True, "compile-timeout")


def test_build_exit_nonzero_with_signature_compile_crash() raises:
    # A compiler ICE: nonzero exit with a crash banner in stderr.
    var s = _bytes("mojo: internal error\nPLEASE submit a bug report ...\n")
    _check(
        retry_classify("build", Termination.exited(1), False, s),
        True,
        "compile-crash",
    )


def test_build_exit_nonzero_no_signature_compile_error() raises:
    # An ordinary compile error — deterministic, never retried.
    var s = _bytes("error: use of unknown declaration 'foo'\n")
    _check(
        retry_classify("build", Termination.exited(1), False, s),
        False,
        "compile-error",
    )


def test_build_exit0_deterministic() raises:
    _check(
        retry_classify("build", Termination.exited(0), False, _empty()),
        False,
        "deterministic",
    )


def test_build_exit0_ignores_signature() raises:
    # Code 0 is a succeeded build: never a crash regardless of stderr content.
    var s = _bytes("Stack dump:\n")
    _check(
        retry_classify("build", Termination.exited(0), False, s),
        False,
        "deterministic",
    )


def test_precompile_signaled_compile_crash() raises:
    # Precompile uses the same rules as build.
    _check(
        retry_classify("precompile", Termination.signaled(6), False, _empty()),
        True,
        "compile-crash",
    )


def test_precompile_exit_nonzero_no_signature_compile_error() raises:
    var s = _bytes("error: bad\n")
    _check(
        retry_classify("precompile", Termination.exited(1), False, s),
        False,
        "compile-error",
    )


# ---- has_crash_signature: positive markers ------------------------------------


def test_sig_bug_report_phrase() raises:
    assert_true(
        has_crash_signature(
            _bytes("PLEASE submit a bug report to https://example/ and ...\n")
        )
    )


def test_sig_bug_report_case_insensitive() raises:
    assert_true(
        has_crash_signature(_bytes("please SUBMIT A BUG REPORT and include\n"))
    )


def test_sig_stack_dump_line() raises:
    assert_true(
        has_crash_signature(
            _bytes("Stack dump:\n0.\tProgram arguments: mojo build ...\n")
        )
    )


def test_sig_symbolless_frame() raises:
    # "<n>  <module> 0x<hex>" — the no-symbolizer frame form.
    assert_true(has_crash_signature(_bytes("3 mtest 0x0000abcd\n")))


def test_sig_symbolized_frame() raises:
    # "#<n> 0x<hex> <sym> ..." — the llvm-symbolizer frame form.
    assert_true(has_crash_signature(_bytes("#4 0x00001234 foo /a/b.cpp:1:2\n")))


def test_sig_frame_among_other_lines() raises:
    # A frame anywhere in a multi-line stream is enough.
    assert_true(
        has_crash_signature(
            _bytes("compiling ...\nnote: here\n5 libFoo 0xdeadbeef\n")
        )
    )


# ---- has_crash_signature: negative cases --------------------------------------


def test_sig_bug_report_midline_echo_is_not_crash() raises:
    # An ordinary DETERMINISTIC compile error whose stderr merely ECHOES the
    # phrase mid-line (a quoted assert message, quoted user source) must NOT
    # forge the ICE banner: only a real banner LINE is crash-class. Retrying a
    # deterministic failure would violate the core invariant.
    assert_false(
        has_crash_signature(
            _bytes(
                "error: assertion failed: submit a bug report if it recurs\n"
            )
        )
    )
    assert_false(
        has_crash_signature(
            _bytes(
                'note:  raise Error("please submit a bug report upstream")\n'
            )
        )
    )


def test_sig_bug_report_banner_line_after_noise_is_crash() raises:
    # The genuine LLVM/Mojo ICE banner LINE still trips it, even preceded by
    # other output.
    assert_true(
        has_crash_signature(
            _bytes(
                "mojo: internal error\nPLEASE submit a bug report to"
                " https://example/ and include the backtrace\n"
            )
        )
    )


def test_sig_ordinary_compile_error() raises:
    assert_false(
        has_crash_signature(
            _bytes("error: cannot find 'foo'\nnote: defined here\n")
        )
    )


def test_sig_empty() raises:
    assert_false(has_crash_signature(_empty()))


def test_sig_hex_but_not_frame() raises:
    # A hex address in prose is NOT a frame line.
    assert_false(
        has_crash_signature(_bytes("error: value 0xdeadbeef is out of range\n"))
    )


def test_sig_digits_no_module_token() raises:
    # "<n> 0x<hex>" — only two fields, missing the module token: not a frame.
    assert_false(has_crash_signature(_bytes("3 0xabcd\n")))


def test_sig_hash_token_before_0x() raises:
    # "#<n> <tok> 0x<hex>" — the symbolized form needs 0x right after the space.
    assert_false(has_crash_signature(_bytes("#4 foo 0x1\n")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
