"""The `--junit-xml` finalize wiring and the two-phase terminal protocol (L4).

Drives `run_session` with a real `JunitReporter` composed at a fixed comptime
index (mirroring `main`'s `(console, stream, junit)`, here `(recorder, junit)`
at `run_session[-1, 1]`). Pins: a real run PUBLISHES the report at PATH and
dispatches EXACTLY ONE `SessionFinished`; a finalization failure (an undirectory
target) escalates a resolved 0/1 to exit 3 by the terminal-write precedence,
with the SAME code carried on the single dispatched terminal — the two phases
agree, and a prior report survives.
"""
from std.os import makedirs
from std.os.path import exists
from std.testing import assert_equal, assert_true

from mtest.model import EventKind
from mtest.report import (
    CompositeReporter,
    JunitReporter,
    RecordingReporter,
    open_junit_artifact,
    open_junit_spool,
)
from mtest.session import run_session

from session_fixtures import (
    SRC_FAIL,
    SRC_PASS,
    base_config,
    temp_root,
    write_file,
)


def _one_session_finished(ref rec: RecordingReporter, want_code: Int) raises:
    var n = rec.count()
    assert_true(n > 0, "the recorder observed no events")
    var finishes = 0
    for i in range(n):
        if rec.kind_at(i) == EventKind.SESSION_FINISHED:
            finishes += 1
            assert_equal(
                rec.event_at(i).exit_code,
                want_code,
                "the dispatched terminal carries the resolved code",
            )
    assert_equal(finishes, 1, "exactly one SessionFinished is dispatched")
    assert_true(
        rec.kind_at(n - 1) == EventKind.SESSION_FINISHED,
        "SessionFinished is the last event dispatched",
    )


def test_junit_report_published_and_one_terminal_dispatched() raises:
    var root = temp_root()
    write_file(root, "tests/test_pass.mojo", SRC_PASS)
    write_file(root, "tests/test_fail.mojo", SRC_FAIL)
    var config = base_config()

    var target = temp_root() + "/report.xml"
    var spool = open_junit_spool()
    var art = open_junit_artifact(spool, target)
    var junit = JunitReporter(
        art.spool_dir, True, art.target_path, art.temp_path
    )
    var comp = CompositeReporter(Tuple(RecordingReporter(), junit^))

    # stream_index = -1 (no stream), junit_index = 1.
    var code = run_session[-1, 1](config, root, comp)
    assert_equal(code, 1, "a failing suite resolves to exit 1")

    # The report was published at the target by Phase 1.
    assert_true(exists(target), "the junit report exists at the target path")
    var body: String
    with open(target, "r") as f:
        body = f.read()
    assert_true(
        "<testsuites" in body, "the target holds the assembled document"
    )
    assert_true("test_fail" in body, "the failing file's suite is present")

    ref rec = comp.reporters[0]
    _one_session_finished(rec, 1)


def test_junit_finalization_failure_escalates_to_exit_3() raises:
    var root = temp_root()
    write_file(root, "tests/test_pass.mojo", SRC_PASS)
    var config = base_config()

    # The target PATH is an existing DIRECTORY: the atomic rename cannot replace
    # it, so finalization fails and a resolved 0 escalates to exit 3 by the
    # terminal-write precedence — the single dispatched terminal agrees.
    var parent = temp_root()
    var target = parent + "/report.xml"
    makedirs(target)
    var spool = open_junit_spool()
    var art = open_junit_artifact(spool, target)
    var junit = JunitReporter(
        art.spool_dir, True, art.target_path, art.temp_path
    )
    var comp = CompositeReporter(Tuple(RecordingReporter(), junit^))

    var code = run_session[-1, 1](config, root, comp)
    assert_equal(code, 3, "a failed finalization escalates a clean run to 3")
    assert_true(exists(target), "the undirectory target survives")

    ref rec = comp.reporters[0]
    _one_session_finished(rec, 3)
