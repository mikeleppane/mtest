"""Tests for the two accumulators every run driver settles into.

`RunTally` is where the gate loop, the plain run loop, the selection
sub-session, and each pooled batch put what they learn; `CacheAdmissions` is
where the same drivers charge the run's first-attempt compile admissions.
`_absorb_batch` is the one place a finished batch is folded back into both. A
field that grows without a fold would silently drop that batch's contribution
from the run, so the fold case below constructs a whole `PoolBatchResult`
positionally: a new field on either struct fails to compile here rather than
going quietly unfolded.
"""
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mtest.exec import Termination
from mtest.model import Event, Outcome, ParseDisposition, TestCounts
from mtest.protocol import ParsedReport
from mtest.session.attempt import _AttemptResult, _finalize_attempt
from mtest.session.classify import Classification, TrustedReport
from mtest.session.effective_settings import EffectiveFileSettings
from mtest.session.file_result import CacheAdmissions, RunTally, _CrashFile
from mtest.session.pool import PoolBatchResult
from mtest.session.session import _absorb_batch


def _settings() -> EffectiveFileSettings:
    return EffectiveFileSettings(30, 300, 0, False)


def _crash(rel: String) -> _CrashFile:
    return _CrashFile(rel, _settings(), "build/bin/" + rel, List[String]())


def _loaded_tally() -> RunTally:
    """A tally with every field set to something distinguishable."""
    return RunTally(
        [Outcome.FAIL, Outcome.PASS],
        TestCounts(1, 2, 3, 4),
        5,
        [_crash("tests/test_c.mojo")],
        True,
        True,
        True,
        True,
        True,
    )


def test_absorb_batch_folds_every_field_a_batch_carries() raises:
    var tally = RunTally.zeros()
    var admissions = CacheAdmissions.zeros()
    # Positional, so a field added to either struct breaks this case loudly
    # instead of being dropped on the floor by the fold.
    var batch = PoolBatchResult(_loaded_tally(), True, CacheAdmissions(7, 9))

    _absorb_batch(tally, admissions, batch)

    assert_equal(len(tally.run_outcomes), 2)
    assert_true(tally.run_outcomes[0] == Outcome.FAIL)
    assert_true(tally.run_outcomes[1] == Outcome.PASS)
    assert_equal(tally.test_totals.passed, 1)
    assert_equal(tally.test_totals.failed, 2)
    assert_equal(tally.test_totals.skipped, 3)
    assert_equal(tally.test_totals.deselected, 4)
    assert_equal(tally.ran_files, 5)
    assert_equal(len(tally.crash_files), 1)
    assert_equal(tally.crash_files[0].rel, "tests/test_c.mojo")
    assert_true(tally.drift)
    assert_true(tally.aborted)
    assert_true(tally.interrupted)
    assert_true(tally.internal_error)
    assert_true(tally.console_dead)
    # The admissions land on the session's one accumulator, never inside the
    # batch, so the gate, parallel, and serial batches each account for
    # themselves.
    assert_equal(admissions.built, 7)
    assert_equal(admissions.cached, 9)


def test_absorb_batch_leaves_the_batch_local_halt_to_its_caller() raises:
    # `halted` is the parallel batch's own `-x`/`--maxfail` latch, read once by
    # the serial pass that follows it. Folding it into the run would make the
    # session behave as if the whole run had halted.
    var tally = RunTally.zeros()
    var admissions = CacheAdmissions.zeros()
    var batch = PoolBatchResult(RunTally.zeros(), True, CacheAdmissions.zeros())
    _absorb_batch(tally, admissions, batch)
    assert_true(batch.halted)
    assert_false(tally.aborted)
    assert_false(tally.interrupted)
    assert_false(tally.internal_error)


def test_a_zeroed_admissions_accumulator_has_charged_nothing() raises:
    var admissions = CacheAdmissions.zeros()
    assert_equal(admissions.built, 0)
    assert_equal(admissions.cached, 0)


def test_admissions_charge_across_batches_rather_than_replacing() raises:
    # Every batch of a run charges the same accumulator, so the gate batch's
    # compiles must still be there after the parallel and serial batches fold.
    var admissions = CacheAdmissions.zeros()
    admissions.merge(CacheAdmissions(2, 1))
    admissions.merge(CacheAdmissions(3, 4))
    assert_equal(admissions.built, 5)
    assert_equal(admissions.cached, 5)


def test_merge_accumulates_rather_than_replaces() raises:
    var tally = RunTally.zeros()
    var first = _loaded_tally()
    var second = _loaded_tally()
    tally.merge(first)
    tally.merge(second)

    assert_equal(len(tally.run_outcomes), 4)
    assert_equal(tally.test_totals.passed, 2)
    assert_equal(tally.test_totals.failed, 4)
    assert_equal(tally.test_totals.skipped, 6)
    assert_equal(tally.test_totals.deselected, 8)
    assert_equal(tally.ran_files, 10)
    assert_equal(len(tally.crash_files), 2)


def test_merge_never_clears_a_flag_the_run_already_latched() raises:
    # Every flag here is a latch the exit-code model ranks: a later clean batch
    # must not withdraw an interrupt, an internal error, or a drift that already
    # happened.
    var tally = RunTally.zeros()
    tally.merge(_loaded_tally())
    tally.merge(RunTally.zeros())
    assert_true(tally.drift)
    assert_true(tally.aborted)
    assert_true(tally.interrupted)
    assert_true(tally.internal_error)
    assert_true(tally.console_dead)


def test_a_zeroed_tally_has_nothing_accumulated_and_nothing_latched() raises:
    var tally = RunTally.zeros()
    assert_equal(len(tally.run_outcomes), 0)
    assert_equal(tally.test_totals.passed, 0)
    assert_equal(tally.test_totals.failed, 0)
    assert_equal(tally.test_totals.skipped, 0)
    assert_equal(tally.test_totals.deselected, 0)
    assert_equal(tally.ran_files, 0)
    assert_equal(len(tally.crash_files), 0)
    assert_false(tally.drift)
    assert_false(tally.aborted)
    assert_false(tally.interrupted)
    assert_false(tally.internal_error)
    assert_false(tally.console_dead)


def test_a_finalized_attempt_reports_no_deselection() raises:
    """The plain attempt loop never deselects, and the tally fold relies on it.

    `settle_file` folds all four per-test totals for every driver, including the
    gate and plain run loops, which reach it through `_finalize_attempt`. That
    is only a no-op for `deselected` because this is the one construction of
    those counts on that path and it hardcodes zero. A path that started
    reporting deselections here would begin contributing to the run-wide total
    with nothing saying so.
    """
    var cls = Classification(
        Outcome.FAIL,
        ParseDisposition.PARSED,
        3,
        2,
        1,
        [Outcome.PASS, Outcome.FAIL],
        False,
        "",
        "",
    )
    var att = _AttemptResult(
        control=0,
        internal_event=Event.file_started(""),
        build_failed=False,
        build_argv=["mojo", "build", "tests/test_a.mojo"],
        bterm=Termination.exited(0),
        build_stderr=List[UInt8](),
        bdur=1.0,
        out_bin="build/bin/tests_stest_ua",
        rterm=Termination.exited(1),
        run_stdout=List[UInt8](),
        run_stderr=List[UInt8](),
        rdur=0.5,
        trusted=TrustedReport(ParsedReport.absent(), False),
        cls=cls^,
        run_stdout_truncated=False,
        run_stderr_truncated=False,
    )

    var fr = _finalize_attempt(_settings(), "tests/test_a.mojo", att^, 1, False)

    # The other three carry through, so a zero here is the field's own answer
    # and not an empty classification making every count agree.
    assert_equal(fr.test_counts.passed, 3)
    assert_equal(fr.test_counts.failed, 2)
    assert_equal(fr.test_counts.skipped, 1)
    assert_equal(fr.test_counts.deselected, 0)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
