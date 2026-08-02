"""Pure-helper regressions for the resilience-pass review fixes (Layer 4).

Each test pins one honesty/correctness/isolation invariant that a whole-branch
adversarial review found broken, reached through the same private-helper seam
`test_session_mangle.mojo` uses. Every helper here is PURE — no processes, no
filesystem, no clock — so the policy is pinned in isolation from the orchestration
that consumes it.
"""
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.exec import ProcessResult, Termination
from mtest.model import FileFinishedPayload, Outcome, ParseDisposition
from mtest.session.retry_class import RetryClass
from mtest.session.scratch import (
    _invocation_nonce,
    _quarantine_dir,
    _retry_out_bin,
)
from mtest.session.attempt import _compile_crash_residual, flaky_eligible
from mtest.session.build import _probe_terminal
from mtest.session.effective_settings import EffectiveFileSettings
from mtest.session.names import _select_names
from mtest.session.selection import _reconcile_and_classify, _run_terminal_file


# ---- Fix 1: a crash-then-DRIFT final attempt is NOT flaky ----------------------


def test_flaky_eligible_only_for_a_genuine_pass() raises:
    # A genuine PASS after a crash-class retry is the only flaky-eligible final.
    assert_true(flaky_eligible(Outcome.PASS))


def test_flaky_eligible_rejects_drift_not_run() raises:
    # The plain run path can Exit with an OFF-GRAMMAR report -> NOT_RUN + drift.
    # NOT_RUN is not in the failing class, so the old `not is_failing()` test
    # laundered a drifted file into a green FLAKY pass. It must NOT be flaky: the
    # file's real drift verdict (exit 3) stands.
    assert_false(flaky_eligible(Outcome.NOT_RUN))


def test_flaky_eligible_rejects_real_failures() raises:
    # A crash-then-still-failing final is never flaky.
    assert_false(flaky_eligible(Outcome.FAIL))
    assert_false(flaky_eligible(Outcome.CRASH))
    assert_false(flaky_eligible(Outcome.TIMEOUT))
    assert_false(flaky_eligible(Outcome.MALFORMED_SUITE))


# ---- The selection driver's own promotion seam, not a formula copy ------------
#
# `_reconcile_and_classify` is the real production call site (selection.mojo).
# Drift (`Outcome.NOT_RUN`) never reaches its promotion check on the current
# call graph -- an OFF_GRAMMAR report returns earlier, through
# `_classified_terminal` -- so these cases exercise the two outcomes that DO
# reach it (a clean PASS and a still-failing FAIL) and pin the invariant that
# actually matters: the event's `flaky` flag is derived from the promoted
# outcome, never computed as a second, independently-driftable fact.

comptime _SELECTION_PATH = "/p/a.mojo"


def _bytes(s: String) -> List[UInt8]:
    """The UTF-8 bytes of `s` as an owned list."""
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _selection_settings() -> EffectiveFileSettings:
    """A generic settings value; the reconciler does not branch on it here."""
    return EffectiveFileSettings(60, 60, 0, False)


def _valid_pass_report_bytes() -> List[UInt8]:
    """A single-test VALID report, one PASS, no trailer (a clean exit 0)."""
    return _bytes(
        "Running 1 tests for "
        + _SELECTION_PATH
        + " \n"
        + "    PASS [ 0.001 ] test_one\n"
        + "--------\n"
        + "Summary [ 0.001 ] 1 tests run: 1 passed , 0 failed , 0 skipped "
    )


def _valid_fail_report_bytes() -> List[UInt8]:
    """A single-test VALID report, one FAIL, with its required trailer."""
    return _bytes(
        "Running 1 tests for "
        + _SELECTION_PATH
        + " \n"
        + "    FAIL [ 0.001 ] test_one\n"
        + "      At "
        + _SELECTION_PATH
        + ":1:1: boom\n"
        + "--------\n"
        + "Summary [ 0.001 ] 1 tests run: 0 passed , 1 failed , 0 skipped \n"
        + "Test suite' "
        + _SELECTION_PATH
        + " 'failed! "
    )


def _reconcile(
    stdout_bytes: List[UInt8], code: Int, flaky_if_pass: Bool
) -> FileFinishedPayload:
    """Drive the real selection reconciler and return its emitted payload."""
    var term = ProcessResult(
        stdout_bytes.copy(),
        List[UInt8](),
        False,
        False,
        Termination.exited(code),
        5,
    )
    var universe = [String("test_one")]
    var fr = _reconcile_and_classify(
        _selection_settings(),
        "tests/test_a.mojo",
        term,
        universe,
        universe.copy(),
        List[String](),
        List[String](),
        0.0,
        _SELECTION_PATH,
        attempts_used=2,
        flaky_if_pass=flaky_if_pass,
    )
    return fr.event.data[FileFinishedPayload].copy()


def test_reconcile_promotes_a_genuine_pass_to_flaky() raises:
    # The real selection driver seam (`_reconcile_and_classify`), not a
    # formula copy: a clean pass after an earlier crash-class attempt is
    # promoted, and the event's `flaky` flag agrees with the promoted outcome.
    var payload = _reconcile(_valid_pass_report_bytes(), 0, True)
    assert_true(payload.outcome == Outcome.FLAKY)
    assert_true(payload.flaky)
    assert_true(payload.flaky == (payload.outcome == Outcome.FLAKY))


def test_reconcile_does_not_promote_without_a_prior_crash() raises:
    # No earlier crash-class attempt (`flaky_if_pass=False`): a clean pass
    # stays a plain PASS, never flaky.
    var payload = _reconcile(_valid_pass_report_bytes(), 0, False)
    assert_true(payload.outcome == Outcome.PASS)
    assert_false(payload.flaky)
    assert_true(payload.flaky == (payload.outcome == Outcome.FLAKY))


def test_reconcile_does_not_promote_a_failing_outcome() raises:
    # `flaky_if_pass=True` promotes ONLY a genuine pass. A file that is still
    # failing after the crash-class retry stays FAIL, never flaky -- the
    # invariant `flaky == (outcome == FLAKY)` holds for the reachable
    # non-PASS case too.
    var payload = _reconcile(_valid_fail_report_bytes(), 1, True)
    assert_true(payload.outcome == Outcome.FAIL)
    assert_false(payload.flaky)
    assert_true(payload.flaky == (payload.outcome == Outcome.FLAKY))


# ---- Fix 5: the late-interrupt DOMINANCE now lives in the terminal protocol ----
#
# The interrupt-linearization that a late (mid-attribution) interrupt dominates
# the resolved exit code is fixed at the two-phase terminal protocol's Phase-1
# entry, which reports it as a fact to `resolve_exit_code`; the precedence's
# dedicated pins live in `test_model_exit_code.mojo`.


# ---- Fix 7: the residual warning does not claim "killed" for a self-exited ICE -


def test_residual_exited_ice_does_not_claim_killed() raises:
    # An ICE that EXITED nonzero with a crash signature (label "compile-crash",
    # no signal, no timeout) was NOT killed by us. The warning must not say so.
    var w = _compile_crash_residual(
        "compile",
        "a/b.mojo",
        RetryClass(True, "compile-crash"),
        Termination.exited(1),
    )
    assert_false("was killed" in w, w)
    assert_true("crashed on its own" in w, w)
    # The cache-suspect / quarantine tail survives (the e2e asserts on it).
    assert_true("quarantined" in w, w)


def test_residual_timeout_may_say_killed() raises:
    var w = _compile_crash_residual(
        "compile",
        "a/b.mojo",
        RetryClass(True, "compile-timeout"),
        Termination.timed_out(Termination.SIGNALED, 9, True),
    )
    assert_true("killed" in w, w)


def test_residual_signal_says_crashed_not_killed() raises:
    var w = _compile_crash_residual(
        "precompile",
        "p/q",
        RetryClass(True, "compile-crash"),
        Termination.signaled(11),
    )
    assert_false("was killed" in w, w)
    assert_true("crashed" in w, w)
    assert_true("the precompile of" in w, w)


# ---- Fix 3: attribution never isolates a DESELECTED test ----------------------


def test_select_names_restricts_to_selected_subset() raises:
    # A file with two crashing tests, run under `-k <second>`: only the SECOND
    # is an isolation candidate. The deselected first must not be named.
    var universe = [String("test_a"), String("test_b")]
    var selected = [String("test_b")]
    var got = _select_names(universe, selected)
    assert_equal(len(got), 1)
    assert_equal(got[0], "test_b")


def test_select_names_preserves_source_order() raises:
    var universe = [String("test_a"), String("test_b"), String("test_c")]
    var selected = [String("test_c"), String("test_a")]
    var got = _select_names(universe, selected)
    assert_equal(len(got), 2)
    assert_equal(got[0], "test_a")  # source order, not selection order
    assert_equal(got[1], "test_c")


def test_select_names_empty_selection_keeps_all() raises:
    # The plain (non-selection) run path passes an empty set: every name stays.
    var universe = [String("test_a"), String("test_b")]
    var got = _select_names(universe, List[String]())
    assert_equal(len(got), 2)


# ---- Fix 6: concurrent invocations get distinct temp/quarantine namespaces -----


def test_invocation_nonce_is_nonempty_and_stable() raises:
    var a = _invocation_nonce()
    assert_true(a.byte_length() > 0)
    # Stable within one process, so every construction site agrees.
    assert_equal(a, _invocation_nonce())


def test_quarantine_dir_distinct_per_invocation() raises:
    # Same source + attempt, two concurrent invocation nonces: the quarantine
    # cache dirs must differ, or one process's cleanup deletes the other's live
    # cache mid-rebuild.
    var a = _quarantine_dir("", "tests_stest_ua", 2, "111")
    var b = _quarantine_dir("", "tests_stest_ua", 2, "222")
    assert_false(a == b, "two invocations shared a quarantine dir: " + a)


def test_quarantine_dir_distinct_per_attempt_and_prefix() raises:
    var one = _quarantine_dir("", "m", 2, "9")
    var two = _quarantine_dir("", "m", 3, "9")
    assert_false(one == two, "two attempts shared a quarantine dir")
    var run = _quarantine_dir("", "m", 2, "9")
    var pre = _quarantine_dir("precompile-", "m", 2, "9")
    assert_false(run == pre, "a build and precompile step shared a dir")


def test_retry_out_bin_distinct_per_invocation() raises:
    # Same source + attempt, two nonces: the rebuilt binary paths must differ,
    # or two processes write the same .attempt-N file under each other.
    var a = _retry_out_bin("tests_stest_ua", 2, "111")
    var b = _retry_out_bin("tests_stest_ua", 2, "222")
    assert_false(a == b, "two invocations shared a retry binary: " + a)


def test_retry_out_bin_distinct_per_attempt() raises:
    var a = _retry_out_bin("m", 2, "9")
    var b = _retry_out_bin("m", 3, "9")
    assert_false(a == b, "two attempts shared a retry binary")


# ---- FileFinished carries the file-scope process result's own truncation ------


def test_run_terminal_file_propagates_truncation_from_process_result() raises:
    # A selection-run CRASH/TIMEOUT/malformed terminal is built straight from
    # the run's own ProcessResult; its truncation booleans must ride the
    # verdict per-stream, not collapse to a shared or defaulted flag.
    var term = ProcessResult(
        List[UInt8](),
        List[UInt8](),
        True,
        False,
        Termination.signaled(11),
        5,
    )
    var fr = _run_terminal_file(
        "tests/test_x.mojo",
        Outcome.CRASH,
        ParseDisposition.NO_REPORT,
        "",
        "",
        List[String](),
        0.0,
        0.0,
        term,
        0,
        signal_number=11,
    )
    assert_true(
        fr.event.data[FileFinishedPayload].stdout_truncated,
        "stdout truncation must propagate",
    )
    assert_false(
        fr.event.data[FileFinishedPayload].stderr_truncated,
        "an untruncated stream must stay False",
    )


def test_probe_terminal_propagates_truncation_from_probe_result() raises:
    # The --skip-all probe genuinely executes the file's binary, so a
    # truncated probe capture is real truncation of that file's run and must
    # ride the terminal FileFinished the probe produces on a crash/timeout/
    # malformed/overflow probe.
    var fr = _probe_terminal(
        "tests/test_x.mojo",
        Outcome.CRASH,
        ParseDisposition.NO_REPORT,
        "",
        "",
        List[String](),
        0.0,
        List[UInt8](),
        List[UInt8](),
        False,
        signal_number=11,
        stdout_truncated=False,
        stderr_truncated=True,
    )
    assert_false(
        fr.event.data[FileFinishedPayload].stdout_truncated,
        "an untruncated stream must stay False",
    )
    assert_true(
        fr.event.data[FileFinishedPayload].stderr_truncated,
        "stderr truncation must propagate",
    )


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
