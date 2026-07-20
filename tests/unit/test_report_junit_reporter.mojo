"""Tests for the stateful JUnit reporter and its fragment spool (Layer 2).

Drives typed event streams through `JunitReporter` for every sentinel-matrix
cell, then asserts the SPOOLED-then-ASSEMBLED document: one fragment file per
finished suite, the correct sentinel (or none) chosen from `attempts_used` /
outcome / per-test rows, the Surefire chronology of a rerun-exhausted failure,
flaky attempt order, the precompile suite plus per-casualty not-run rows and the
empty-list degenerate case, deselected/excluded absence, the suite-level
capture, and the non-raising write latch. The junit-10 oracle is run over the
real assembled output by the `scripts/junit_render_check.py` CI gate; here the
event->fragment mapping and the spool mechanism are pinned directly, including
`open_junit_spool` — the spool-directory primitive the reporter is handed.
"""
from std.os import getenv, listdir, mkdir, rmdir, setenv, unsetenv
from std.os.path import exists, isdir
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from mtest.model.events import Event
from mtest.model.node_id import NodeId
from mtest.model.outcome import Outcome
from mtest.model.test_result import TestResult
from mtest.report.junit_reporter import (
    _SPOOL_ATTEMPTS,
    JunitReporter,
    open_junit_spool,
)

from tmptree import remove_tree, temp_root


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _reporter() raises -> JunitReporter:
    return JunitReporter(open_junit_spool(), True)


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


# --- The spool directory primitive -------------------------------------------
# `open_junit_spool` replaces `std.tempfile.mkdtemp`, whose unseeded candidate
# generator makes every process walk the SAME name sequence and fail outright in
# a shared `/tmp` where those names already exist. These pin what the
# replacement must guarantee: a real empty directory, distinct names within one
# process, a spool that still opens against a temp base ALREADY FULL of the
# names a previous run chose (the regression itself), the documented
# TMPDIR/TEMP/TMP precedence, and a raise naming the underlying cause when the
# base is unusable (which `main` resolves to exit 3).
#
# Every test here mutates process-wide state (TMPDIR) or leaves a directory on
# disk, so each restores and cleans up in a `finally` — a raising assertion must
# not leak a redirected TMPDIR into every later test in this binary — and every
# assertion runs BEFORE the cleanup, so a cleanup failure cannot displace the
# real diagnostic.


def test_open_junit_spool_creates_a_fresh_empty_directory() raises:
    var spool = open_junit_spool()
    try:
        assert_true(
            isdir(spool), "the spool path names a real directory: " + spool
        )
        assert_equal(len(listdir(spool)), 0, "a fresh spool starts empty")
    finally:
        remove_tree(spool)


def test_open_junit_spool_does_not_collide_within_one_process() raises:
    # One process opens a spool per run, but the aggregate test binary opens
    # many; the per-attempt clock reading is what keeps them apart.
    var first = open_junit_spool()
    var second = open_junit_spool()
    try:
        assert_true(isdir(first), "the first spool exists on disk: " + first)
        assert_true(isdir(second), "the second spool exists on disk: " + second)
        assert_true(first != second, "two spools in one process differ")
    finally:
        remove_tree(first)
        remove_tree(second)


def test_open_junit_spool_survives_a_temp_base_full_of_stale_spools() raises:
    # THE regression, pinned. A temp base already holding the spool names this
    # process would choose is the shared-`/tmp` condition the whole fix exists
    # for: bare `mkdtemp()` walked one unseeded name sequence into exactly this
    # and raised before a single test was built, and a bounded walk over a
    # FIXED per-pid stem exhausts the same way the moment a recycled pid meets
    # leftovers from its own earlier incarnation (containers with a persisted
    # `/tmp` restart pids low and repeat them). Only a key re-read per attempt
    # cannot be walked into again.
    var base = temp_root()
    var prev = getenv("TMPDIR", "")
    _ = setenv("TMPDIR", base, True)
    try:
        # Learn this run's stem FROM THE IMPLEMENTATION, so the clutter below
        # is exactly the candidate set a fixed-stem walk would try, whatever
        # pid this process happens to have.
        var probe = open_junit_spool()
        var leaf = String(probe.removeprefix(base + "/"))
        assert_true(
            leaf.startswith("mtest-junit-"),
            "the spool keeps its run-identifying prefix: " + probe,
        )
        var fields = leaf.split("-")
        var stem = base + "/mtest-junit-" + String(fields[2]) + "-"
        for n in range(_SPOOL_ATTEMPTS):
            var stale = stem + String(n)
            if not exists(stale):
                mkdir(stale, 0o700)
        var spool = open_junit_spool()
        assert_true(
            isdir(spool),
            "a spool still opens beside a full budget of stale ones: " + spool,
        )
        assert_true(
            spool.startswith(stem),
            "the fresh spool keeps this run's prefix: " + spool,
        )
    finally:
        if prev != "":
            _ = setenv("TMPDIR", prev, True)
        else:
            _ = unsetenv("TMPDIR")
        remove_tree(base)


def test_open_junit_spool_honors_tmpdir() raises:
    var base = temp_root()
    var prev = getenv("TMPDIR", "")
    _ = setenv("TMPDIR", base, True)
    try:
        var spool = open_junit_spool()
        assert_true(
            spool.startswith(base + "/"),
            "the spool lands under TMPDIR: " + spool,
        )
    finally:
        if prev != "":
            _ = setenv("TMPDIR", prev, True)
        else:
            _ = unsetenv("TMPDIR")
        remove_tree(base)


def test_open_junit_spool_falls_back_to_temp_then_tmp() raises:
    # The `gettempdir()` behind the replaced `mkdtemp()` consults TMPDIR, then
    # TEMP, then TMP (measured at the pinned toolchain), so a run that confines
    # its scratch with TEMP or TMP alone must keep working.
    var temp_base = temp_root()
    var tmp_base = temp_root()
    var prev_tmpdir = getenv("TMPDIR", "")
    var prev_temp = getenv("TEMP", "")
    var prev_tmp = getenv("TMP", "")
    try:
        _ = unsetenv("TMPDIR")
        _ = setenv("TEMP", temp_base, True)
        _ = setenv("TMP", tmp_base, True)
        var via_temp = open_junit_spool()
        assert_true(
            via_temp.startswith(temp_base + "/"),
            "TEMP is honored when TMPDIR is unset: " + via_temp,
        )
        _ = unsetenv("TEMP")
        var via_tmp = open_junit_spool()
        assert_true(
            via_tmp.startswith(tmp_base + "/"),
            "TMP is honored when TMPDIR and TEMP are unset: " + via_tmp,
        )
    finally:
        if prev_tmpdir != "":
            _ = setenv("TMPDIR", prev_tmpdir, True)
        else:
            _ = unsetenv("TMPDIR")
        if prev_temp != "":
            _ = setenv("TEMP", prev_temp, True)
        else:
            _ = unsetenv("TEMP")
        if prev_tmp != "":
            _ = setenv("TMP", prev_tmp, True)
        else:
            _ = unsetenv("TMP")
        remove_tree(temp_base)
        remove_tree(tmp_base)


def test_open_junit_spool_raises_when_the_temp_base_is_unusable() raises:
    # A missing base, a base that is a regular file, a read-only filesystem and
    # a full disk all burn the whole budget identically, so the message must
    # carry the underlying cause verbatim — naming only the base would make the
    # unusable-base failure indistinguishable from a stale-directory one.
    var prev_tmpdir = getenv("TMPDIR", "")
    var prev_temp = getenv("TEMP", "")
    var prev_tmp = getenv("TMP", "")
    _ = setenv("TMPDIR", "/nonexistent-mtest-temp-base-xyz", True)
    _ = unsetenv("TEMP")
    _ = unsetenv("TMP")
    try:
        with assert_raises(
            contains=(
                "report: could not create a junit spool directory under"
                " '/nonexistent-mtest-temp-base-xyz' ("
                + String(_SPOOL_ATTEMPTS)
                + " attempts; last: "
            )
        ):
            _ = open_junit_spool()
        # The errno text is the actionable half: this is ENOENT, not a base
        # merely crowded with leftovers.
        with assert_raises(contains="No such file or directory"):
            _ = open_junit_spool()
    finally:
        if prev_tmpdir != "":
            _ = setenv("TMPDIR", prev_tmpdir, True)
        else:
            _ = unsetenv("TMPDIR")
        if prev_temp != "":
            _ = setenv("TEMP", prev_temp, True)
        else:
            _ = unsetenv("TEMP")
        if prev_tmp != "":
            _ = setenv("TMP", prev_tmp, True)
        else:
            _ = unsetenv("TMP")
