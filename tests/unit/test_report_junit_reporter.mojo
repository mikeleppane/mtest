"""Tests for the stateful JUnit reporter and its fragment spool (Layer 2).

Drives typed event streams through `JunitReporter` for every sentinel-matrix
cell, then asserts the SPOOLED-then-ASSEMBLED document: one fragment file per
finished suite, the correct sentinel (or none) chosen from `attempts_used` /
outcome / per-test rows, the Surefire chronology of a rerun-exhausted failure,
flaky attempt order, the precompile suite plus per-casualty not-run rows and the
empty-list degenerate case, deselected/excluded absence, the suite-level
capture, and the non-raising write latch. The junit-10 oracle is run over the
real assembled output by the `scripts/junit_render_check.py` CI gate; here the
event->fragment mapping and the spool mechanism are pinned directly.
"""
from std.os import listdir
from std.tempfile import mkdtemp
from std.testing import assert_equal, assert_false, assert_true

from mtest.model.events import Event
from mtest.model.node_id import NodeId
from mtest.model.outcome import Outcome
from mtest.model.test_result import TestResult
from mtest.report.junit_reporter import JunitReporter


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _reporter() raises -> JunitReporter:
    return JunitReporter(mkdtemp(), True)


def _count_occurrences(haystack: String, needle: String) -> Int:
    return len(haystack.split(needle)) - 1


def _fail_result(path: String, name: String, detail: String) -> TestResult:
    return TestResult(NodeId(path, name), Outcome.FAIL, detail, "")


def _pass_result(path: String, name: String) -> TestResult:
    return TestResult(NodeId(path, name), Outcome.PASS)


def _attempt(path: String, idx: Int) -> Event:
    return Event.attempt_finished(
        path,
        "run",
        idx,
        3,
        1,  # term_kind = SIGNALED
        11,
        1,
        11,
        False,
        True,
        "signal",
        0.1,
        _bytes("attempt " + String(idx) + " out"),
        _bytes("attempt " + String(idx) + " err"),
        False,
        False,
        List[String](),
    )


def _finished(
    path: String,
    outcome: Outcome,
    var stdout: List[UInt8],
    var stderr: List[UInt8],
    signal_number: Int = 0,
    exit_status: Int = 0,
    attempts_used: Int = 1,
    flaky: Bool = False,
) -> Event:
    return Event.file_finished(
        path,
        outcome,
        0.05,
        List[String](),
        0.0,
        stdout^,
        stderr^,
        signal_number=signal_number,
        exit_status=exit_status,
        attempts_used=attempts_used,
        flaky=flaky,
    )


# --- Cell 1: non-retried file-level failure -> [build] ----------------------


def test_cell1_build() raises:
    var rep = _reporter()
    rep.handle(Event.file_started("e2e/c1.mojo"))
    rep.handle(
        _finished(
            "e2e/c1.mojo",
            Outcome.CRASH,
            _bytes(""),
            _bytes("boom"),
            signal_number=11,
        )
    )
    assert_equal(rep.suite_count(), 1)
    var doc = rep.assemble("mtest")
    assert_equal(_count_occurrences(doc, 'name="[build]"'), 1)
    assert_equal(_count_occurrences(doc, 'name="[attempts]"'), 0)
    assert_true('errors="1"' in doc)
    assert_true("<error " in doc)


# --- Cell 2: retried file-level failure -> [attempts], initial primary ------


def test_cell2_attempts_filelevel_initial_primary() raises:
    var rep = _reporter()
    rep.handle(Event.file_started("e2e/c2.mojo"))
    rep.handle(_attempt("e2e/c2.mojo", 1))
    rep.handle(_attempt("e2e/c2.mojo", 2))
    rep.handle(
        _finished(
            "e2e/c2.mojo",
            Outcome.CRASH,
            _bytes(""),
            _bytes("boom"),
            signal_number=11,
            attempts_used=3,
        )
    )
    var doc = rep.assemble("mtest")
    assert_equal(_count_occurrences(doc, 'name="[attempts]"'), 1)
    assert_equal(_count_occurrences(doc, 'name="[build]"'), 0)
    # Surefire chronology: primary <error> before the rerun children; the two
    # subsequent attempts (attempt 2 + the final) are reruns.
    var i_primary = doc.find("<error")
    var i_rerun = doc.find("<rerunError")
    assert_true(i_primary >= 0 and i_rerun >= 0 and i_primary < i_rerun)
    assert_equal(_count_occurrences(doc, "<rerunError"), 2)
    # The first attempt is the mixed-text primary <error> (signal 11); the two
    # later attempts carry their own captured streams as rerun system-out.
    assert_true("killed by signal 11" in doc)
    assert_true("attempt 2 out" in doc)


# --- Cell 3: retried final pass (flaky) -> [attempts] flakyFailure -----------


def test_cell3_flaky_chronology() raises:
    var rep = _reporter()
    rep.handle(Event.file_started("e2e/c3.mojo"))
    rep.handle(Event.test_reported(_pass_result("e2e/c3.mojo", "test_ok")))
    rep.handle(_attempt("e2e/c3.mojo", 1))
    rep.handle(_attempt("e2e/c3.mojo", 2))
    rep.handle(
        _finished(
            "e2e/c3.mojo",
            Outcome.FLAKY,
            _bytes(""),
            _bytes(""),
            attempts_used=3,
            flaky=True,
        )
    )
    var doc = rep.assemble("mtest")
    assert_true('failures="0"' in doc)
    assert_true('errors="0"' in doc)
    assert_equal(_count_occurrences(doc, "<flakyFailure"), 2)
    assert_true('type="Signal"' in doc)  # type is required on flakyFailure
    # Attempt order preserved.
    assert_true(doc.find("attempt 1 err") < doc.find("attempt 2 err"))


# --- Cell 4: retried per-test failure -> per-test primary + [attempts] rerun -


def test_cell4_attempts_pertest() raises:
    var rep = _reporter()
    rep.handle(Event.file_started("e2e/c4.mojo"))
    rep.handle(_attempt("e2e/c4.mojo", 1))
    rep.handle(
        Event.test_reported(
            _fail_result("e2e/c4.mojo", "test_flaky", "left != right")
        )
    )
    rep.handle(
        _finished(
            "e2e/c4.mojo",
            Outcome.FAIL,
            _bytes(""),
            _bytes(""),
            exit_status=1,
            attempts_used=2,
        )
    )
    var doc = rep.assemble("mtest")
    assert_equal(_count_occurrences(doc, 'name="[attempts]"'), 1)
    assert_true('failures="1"' in doc)  # the per-test row carries the verdict
    assert_true("<rerunError" in doc)  # the prior attempt as a rerun
    assert_true("e2e/c4.mojo::test_flaky" in doc)


# --- Cell 5: non-retried per-test outcomes -> NO sentinel -------------------


def test_cell5_pertest_no_sentinel() raises:
    var rep = _reporter()
    rep.handle(Event.file_started("e2e/c5.mojo"))
    rep.handle(Event.test_reported(_pass_result("e2e/c5.mojo", "test_a")))
    rep.handle(
        Event.test_reported(
            _fail_result("e2e/c5.mojo", "test_b", "left != right")
        )
    )
    rep.handle(
        _finished(
            "e2e/c5.mojo", Outcome.FAIL, _bytes(""), _bytes(""), exit_status=1
        )
    )
    var doc = rep.assemble("mtest")
    assert_equal(_count_occurrences(doc, 'name="[build]"'), 0)
    assert_equal(_count_occurrences(doc, 'name="[attempts]"'), 0)
    assert_true('failures="1"' in doc)


# --- Cell 6: not-run ---------------------------------------------------------


def test_not_run_outcome() raises:
    var rep = _reporter()
    rep.handle(
        _finished("e2e/c6.mojo", Outcome.NOT_RUN, _bytes(""), _bytes(""))
    )
    var doc = rep.assemble("mtest")
    assert_equal(_count_occurrences(doc, 'name="[not-run]"'), 1)
    assert_true("<skipped " in doc or "<skipped/>" in doc)


# --- Precompile suite + casualty rows + empty-list degenerate ---------------


def test_precompile_with_named_casualties() raises:
    var rep = _reporter()
    var casualties = List[String]()
    casualties.append("e2e/dep_a.mojo")
    casualties.append("e2e/dep_b.mojo")
    rep.handle(Event.precompile_failed("build", "boom", 0, casualties^))
    assert_equal(rep.suite_count(), 3)  # precompile + 2 casualties
    var doc = rep.assemble("mtest")
    assert_equal(_count_occurrences(doc, 'name="[precompile]"'), 1)
    assert_equal(_count_occurrences(doc, 'name="[not-run]"'), 2)
    assert_true("not run: precompile failed (build)" in doc)
    assert_true('name="mtest::precompile"' in doc)


def test_precompile_empty_casualty_list_invents_no_rows() raises:
    var rep = _reporter()
    # A bare count with no names: only the precompile suite is rendered.
    rep.handle(Event.precompile_failed("build", "boom", 5, List[String]()))
    assert_equal(rep.suite_count(), 1)
    var doc = rep.assemble("mtest")
    assert_equal(_count_occurrences(doc, 'name="[precompile]"'), 1)
    assert_equal(_count_occurrences(doc, 'name="[not-run]"'), 0)


# --- Absence: deselected / excluded carry no suite --------------------------


def test_excluded_and_deselected_are_absent() raises:
    var rep = _reporter()
    rep.handle(
        _finished("e2e/ex.mojo", Outcome.EXCLUDED, _bytes(""), _bytes(""))
    )
    rep.handle(
        _finished("e2e/de.mojo", Outcome.DESELECTED, _bytes(""), _bytes(""))
    )
    assert_equal(rep.suite_count(), 0)
    var doc = rep.assemble("mtest")
    assert_false("<testsuite " in doc)


# --- Suite-level capture -----------------------------------------------------


def test_suite_level_capture() raises:
    var rep = _reporter()
    rep.handle(Event.file_started("e2e/cap.mojo"))
    rep.handle(Event.test_reported(_pass_result("e2e/cap.mojo", "test_ok")))
    rep.handle(
        _finished(
            "e2e/cap.mojo",
            Outcome.PASS,
            _bytes("hello <stdout>"),
            _bytes("hello stderr"),
        )
    )
    var doc = rep.assemble("mtest")
    assert_true("<system-out>hello &lt;stdout&gt;</system-out>" in doc)
    assert_true("<system-err>hello stderr</system-err>" in doc)


# --- Spooling mechanism ------------------------------------------------------


def test_spools_one_fragment_file_per_suite() raises:
    var rep = _reporter()
    rep.handle(_finished("e2e/a.mojo", Outcome.PASS, _bytes(""), _bytes("")))
    rep.handle(_finished("e2e/b.mojo", Outcome.PASS, _bytes(""), _bytes("")))
    assert_equal(rep.suite_count(), 2)
    var n_files = 0
    for entry in listdir(rep.spool_dir()):
        if String(entry).endswith(".xml"):
            n_files += 1
    assert_equal(n_files, 2)  # one fragment file per suite


def test_assemble_orders_suites_by_node_id() raises:
    var rep = _reporter()
    rep.handle(_finished("e2e/z.mojo", Outcome.PASS, _bytes(""), _bytes("")))
    rep.handle(_finished("e2e/a.mojo", Outcome.PASS, _bytes(""), _bytes("")))
    var doc = rep.assemble("mtest")
    assert_true(doc.find("e2e/a.mojo") < doc.find("e2e/z.mojo"))


# --- Inert + latch -----------------------------------------------------------


def test_inert_reporter_does_nothing() raises:
    var rep = JunitReporter.inert()
    rep.handle(Event.file_started("e2e/x.mojo"))
    rep.handle(_finished("e2e/x.mojo", Outcome.FAIL, _bytes(""), _bytes("")))
    assert_equal(rep.suite_count(), 0)
    var doc = rep.assemble("mtest")
    assert_false("<testsuite " in doc)


def test_write_failure_latches_and_does_not_raise() raises:
    # A non-existent spool directory makes every fragment write fail; `handle`
    # must swallow it, latch, and never raise out of the seam.
    var rep = JunitReporter("/nonexistent-junit-spool-xyz", True)
    rep.handle(_finished("e2e/x.mojo", Outcome.FAIL, _bytes(""), _bytes("")))
    assert_true(rep.status().failed)
    assert_equal(rep.suite_count(), 0)
