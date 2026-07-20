"""The JUnit artifact FINALIZE half and the `[not-run]` synthesis (Layer 2).

`finalize` lives OUTSIDE the `Reporter` trait: the session calls it on the
concrete `JunitReporter` to assemble the spool in node-id order, verify-write a
unique temp, and atomically rename it onto PATH. These tests pin: a clean
publish writes the document at PATH; a latched SPOOL failure surfaces at
finalization (the deliberate asymmetry — it never aborted the run); a write or
rename failure leaves a PRIOR report at PATH untouched (never truncated); and
`note_not_run` synthesizes a `[not-run]` suite only for selected files that
never spooled a real one.
"""
from std.os import makedirs
from std.os.path import exists
from std.testing import assert_equal, assert_false, assert_true

from mtest.model.events import Event
from mtest.model.node_id import NodeId
from mtest.model.outcome import Outcome
from mtest.model.test_result import TestResult
from mtest.report.junit_reporter import (
    JunitReporter,
    open_junit_artifact,
    open_junit_spool,
)

from tmptree import temp_root


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _pass_finished(path: String) -> Event:
    return Event.file_finished(
        path,
        Outcome.PASS,
        0.01,
        List[String](),
        0.0,
        _bytes(""),
        _bytes(""),
        passed_tests=1,
    )


def _active_reporter(target: String) raises -> JunitReporter:
    """An active reporter whose spool and temp live beside `target`."""
    var spool = open_junit_spool()
    var art = open_junit_artifact(spool, target)
    return JunitReporter(art.spool_dir, True, art.target_path, art.temp_path)


def _drive_one_pass(mut rep: JunitReporter, path: String):
    rep.handle(Event.file_started(path))
    rep.handle(
        Event.test_reported(TestResult(NodeId(path, "test_ok"), Outcome.PASS))
    )
    rep.handle(_pass_finished(path))


def test_finalize_publishes_the_document_at_the_target_path() raises:
    var dir = temp_root()
    var target = dir + "/report.xml"
    var rep = _active_reporter(target)
    _drive_one_pass(rep, "e2e/suite/test_a.mojo")
    var result = rep.finalize()
    assert_false(result.failed, "a clean finalize must not fail")
    assert_true(exists(target), "the report must exist at the target path")
    var body: String
    with open(target, "r") as f:
        body = f.read()
    assert_true(
        "<testsuites" in body, "the target holds the assembled document"
    )
    assert_true("test_ok" in body, "the per-test row is present")


def test_finalize_removes_the_temp_after_a_clean_publish() raises:
    var dir = temp_root()
    var target = dir + "/report.xml"
    var spool = open_junit_spool()
    var art = open_junit_artifact(spool, target)
    var rep = JunitReporter(art.spool_dir, True, art.target_path, art.temp_path)
    _drive_one_pass(rep, "e2e/suite/test_a.mojo")
    _ = rep.finalize()
    # The atomic rename consumes the temp: only the target remains.
    assert_false(exists(art.temp_path), "the temp is gone after the rename")
    assert_true(exists(target))


def test_finalize_inert_reporter_is_a_no_op_success() raises:
    var rep = JunitReporter.inert()
    var result = rep.finalize()
    assert_false(result.failed, "an inert finalize is a clean no-op")


def test_latched_spool_failure_surfaces_at_finalization() raises:
    # A spool whose directory does not exist latches on the first fragment write
    # (handle stays non-raising). The failure did NOT abort the run — it rides to
    # finalization and surfaces here as a finalization failure.
    var target = temp_root() + "/report.xml"
    var rep = JunitReporter("/no/such/spool/dir", True, target, target + ".tmp")
    _drive_one_pass(rep, "e2e/suite/test_a.mojo")
    assert_true(rep.status().failed, "precondition: the spool latched")
    var result = rep.finalize()
    assert_true(result.failed, "a latched spool surfaces as a finalize failure")
    assert_false(exists(target), "no report is published from a dead spool")


def test_finalize_write_failure_leaves_a_prior_report_intact() raises:
    # A temp whose parent directory does not exist fails the verified write; the
    # PRIOR report at the target survives byte-for-byte (junit never truncates).
    var dir = temp_root()
    var target = dir + "/report.xml"
    var prior = String("<PRIOR-REPORT/>\n")
    with open(target, "w") as f:
        f.write(prior)
    var spool = open_junit_spool()
    var rep = JunitReporter(spool, True, target, "/no/such/dir/report.tmp")
    _drive_one_pass(rep, "e2e/suite/test_a.mojo")
    var result = rep.finalize()
    assert_true(result.failed, "an unwritable temp is a finalize failure")
    var body: String
    with open(target, "r") as f:
        body = f.read()
    assert_equal(body, prior, "the prior report survives unmodified")


def test_finalize_rename_onto_a_directory_leaves_the_target_intact() raises:
    # The target PATH is an existing directory: the temp write succeeds but the
    # atomic rename refuses (a file cannot replace a directory). The directory
    # survives and no partial report is left in its place.
    var parent = temp_root()
    var target = parent + "/report.xml"
    makedirs(target)  # target is now a DIRECTORY
    var spool = open_junit_spool()
    var art = open_junit_artifact(spool, target)
    var rep = JunitReporter(art.spool_dir, True, art.target_path, art.temp_path)
    _drive_one_pass(rep, "e2e/suite/test_a.mojo")
    var result = rep.finalize()
    assert_true(result.failed, "rename onto a directory is a finalize failure")
    assert_true(exists(target), "the target directory survives")


def test_note_not_run_synthesizes_only_for_unspooled_files() raises:
    var target = temp_root() + "/report.xml"
    var rep = _active_reporter(target)
    # One file actually ran and spooled a real suite.
    _drive_one_pass(rep, "e2e/suite/ran.mojo")
    assert_equal(rep.suite_count(), 1)
    # Phase 1 hands the full selected set: the ran file plus two that never ran.
    var selected: List[String] = [
        String("e2e/suite/ran.mojo"),
        String("e2e/suite/skipped_a.mojo"),
        String("e2e/suite/skipped_b.mojo"),
    ]
    rep.note_not_run(selected)
    # Only the two un-spooled files gain a [not-run] suite; the ran one is not
    # doubled.
    assert_equal(rep.suite_count(), 3)
    var doc = rep.assemble("mtest")
    assert_equal(doc.count("[not-run]"), 2)
    assert_true("skipped_a" in doc)
    assert_true("skipped_b" in doc)
