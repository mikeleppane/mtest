"""Tests for the release ladder every configured run exits through.

Driven against real resources — real spool directories, real temp files, real
descriptors, a real exec runtime — because the ladder owns concrete cleanup and
a fake would only prove that the fake was called. What each case asserts is the
observable state afterwards: the scratch gone, the published report untouched,
and the code the ladder settled on.

Ordering is the invariant, so two of the cases below pin it where the
filesystem can answer: `rmdir` refuses a directory that still holds entries, so
a spool that is gone proves its fragments were removed first; and a report
published onto its target before the run ended has to survive the removal of
the scratch that produced it.
"""
from std.os.path import exists
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.cli.run_resources import RunResources
from mtest.exec import ExecRuntime
from mtest.model import EXIT_INTERRUPTED, EXIT_USAGE_ERROR
from mtest.platform import create_unique_temp, close_checked_fd, rename_path
from mtest.report import (
    close_json_fd,
    open_json_fd,
    open_junit_artifact,
    open_junit_spool,
    open_report_spool,
)

from tmptree import remove_tree, temp_root


def _resources() -> RunResources:
    """A ladder that owns nothing yet, over an exec runtime that is not open.

    `ExecRuntime.close()` on an unopened token is a no-op, so a case that is
    about the scratch or the descriptor pays nothing for the last rung.
    """
    return RunResources(
        ExecRuntime(),
        -1,
        False,
        String(""),
        String(""),
        String(""),
        String(""),
        -1,
        String(""),
        -1,
    )


def _write(path: String, text: String) raises:
    """Write `text` to `path`, replacing whatever was there."""
    with open(path, "w") as handle:
        handle.write(text)


def _read(path: String) raises -> String:
    """The complete contents of `path`."""
    with open(path, "r") as handle:
        return handle.read()


def _spool_with_fragments() raises -> String:
    """A JUnit spool directory holding two per-suite fragments."""
    var spool = open_junit_spool()
    _write(spool + "/suite-1.xml", "<testsuite name='a'/>")
    _write(spool + "/suite-2.xml", "<testsuite name='b'/>")
    return spool^


def test_the_junit_spool_goes_with_its_fragments() raises:
    """`rmdir` refuses a populated directory, so the spool proves the order."""
    var spool = _spool_with_fragments()
    var root = temp_root()
    try:
        var artifact = open_junit_artifact(spool, root + "/report.xml")
        var resources = _resources()
        resources.junit_spool = spool
        resources.junit_temp = artifact.temp_path
        assert_true(exists(spool + "/suite-1.xml"))
        assert_true(exists(artifact.temp_path))

        var outcome = resources.close_into(0, rank_delivery=True)

        assert_equal(outcome.code, 0)
        assert_equal(outcome.diagnostic, "")
        assert_false(exists(spool + "/suite-1.xml"))
        assert_false(exists(spool + "/suite-2.xml"))
        assert_false(exists(spool))
        assert_false(exists(artifact.temp_path))
    finally:
        remove_tree(spool)
        remove_tree(root)


def test_the_report_spool_goes_with_its_fragments_and_both_temps() raises:
    var spool = open_report_spool()
    var root = temp_root()
    try:
        _write(spool + "/section-1.md", "# a")
        var md = create_unique_temp(root + "/.report.md.XXXXXX")
        close_checked_fd(md.fd)
        var html = create_unique_temp(root + "/.report.html.XXXXXX")
        close_checked_fd(html.fd)
        var resources = _resources()
        resources.report_spool = spool
        resources.report_md_temp = md.path.copy()
        resources.report_html_temp = html.path.copy()

        var outcome = resources.close_into(1, rank_delivery=True)

        assert_equal(outcome.code, 1)
        assert_false(exists(spool + "/section-1.md"))
        assert_false(exists(spool))
        assert_false(exists(md.path))
        assert_false(exists(html.path))
    finally:
        remove_tree(spool)
        remove_tree(root)


def test_a_published_report_outlives_the_scratch_that_produced_it() raises:
    """Publication happens first; the ladder must not reach the published file.

    The rename is what the session's finalize performs, so this is the success
    path: the temp no longer exists under its own name, and removing it is a
    no-op that leaves the document at the destination intact.
    """
    var spool = _spool_with_fragments()
    var root = temp_root()
    try:
        var artifact = open_junit_artifact(spool, root + "/report.xml")
        _write(artifact.temp_path, "<testsuites>published</testsuites>")
        rename_path(artifact.temp_path, artifact.target_path)
        var resources = _resources()
        resources.junit_spool = spool
        resources.junit_temp = artifact.temp_path

        var outcome = resources.close_into(0, rank_delivery=True)

        assert_equal(outcome.code, 0)
        assert_false(exists(spool))
        assert_true(exists(root + "/report.xml"))
        assert_equal(
            _read(root + "/report.xml"), "<testsuites>published</testsuites>"
        )
    finally:
        remove_tree(spool)
        remove_tree(root)


def test_an_unpublished_temp_leaves_the_previous_report_standing() raises:
    """A run that never finalized must not damage the report already there."""
    var spool = _spool_with_fragments()
    var root = temp_root()
    try:
        _write(root + "/report.xml", "<testsuites>previous</testsuites>")
        var artifact = open_junit_artifact(spool, root + "/report.xml")
        _write(artifact.temp_path, "<testsuites>abandoned</testsuites>")
        var resources = _resources()
        resources.junit_spool = spool
        resources.junit_temp = artifact.temp_path

        var outcome = resources.close_into(3, rank_delivery=True)

        assert_equal(outcome.code, 3)
        assert_false(exists(artifact.temp_path))
        assert_equal(
            _read(root + "/report.xml"), "<testsuites>previous</testsuites>"
        )
    finally:
        remove_tree(spool)
        remove_tree(root)


def test_owning_nothing_releases_nothing_and_keeps_the_code() raises:
    """Every exit path runs the ladder, including the ones that took nothing."""
    var resources = _resources()
    var outcome = resources.close_into(5, rank_delivery=True)
    assert_equal(outcome.code, 5)
    assert_equal(outcome.diagnostic, "")


def test_scratch_that_is_already_gone_is_not_a_failure() raises:
    """The abort paths reach here after a partial creation, so this must hold.
    """
    var root = temp_root()
    remove_tree(root)
    var resources = _resources()
    resources.junit_spool = root + "/junit"
    resources.junit_temp = root + "/junit/report.tmp"
    resources.report_spool = root + "/report"
    resources.report_md_temp = root + "/report/out.md"
    resources.report_html_temp = root + "/report/out.html"

    var outcome = resources.close_into(0, rank_delivery=True)

    assert_equal(outcome.code, 0)
    assert_equal(outcome.diagnostic, "")


def test_an_owned_descriptor_is_closed_and_reports_a_clean_delivery() raises:
    var root = temp_root()
    try:
        var resources = _resources()
        resources.json_fd = open_json_fd(root + "/stream.ndjson")
        resources.json_owns_fd = True

        var outcome = resources.close_into(0, rank_delivery=True)

        assert_equal(outcome.code, 0)
        assert_false(resources.json_owns_fd)
        # Owning nothing now, a second pass cannot close the number twice and
        # so cannot invent a delivery failure out of a healthy run.
        assert_equal(resources.close_into(0, rank_delivery=True).code, 0)
    finally:
        remove_tree(root)


def test_a_borrowed_stream_descriptor_is_left_open() raises:
    """Under `--json -` the stream writes to a stdout `main` never opened."""
    var root = temp_root()
    var fd = open_json_fd(root + "/stream.ndjson")
    try:
        var resources = _resources()
        resources.json_fd = fd
        resources.json_owns_fd = False

        var outcome = resources.close_into(0, rank_delivery=True)

        assert_equal(outcome.code, 0)
        # Still open: closing it here reports success, which an already-closed
        # descriptor could not.
        assert_false(close_json_fd(fd))
    finally:
        remove_tree(root)


def test_a_failed_delivery_escalates_every_ranked_run_code() raises:
    """A terminal artifact that was not committed outranks the run's verdict.

    `close(2)` on `-1` fails with `EBADF` on every supported platform and can
    never report `EINTR`, which is the one status the reporter forgives — so
    this is the deferred write error a quota- or network-backed filesystem
    surfaces at close, without needing one.
    """
    for code in [0, 1, 5]:
        var resources = _resources()
        resources.json_owns_fd = True
        assert_equal(resources.close_into(code, rank_delivery=True).code, 3)

    # An interrupt was decided by the operator, not by the artifact.
    var interrupted = _resources()
    interrupted.json_owns_fd = True
    assert_equal(
        interrupted.close_into(EXIT_INTERRUPTED, rank_delivery=True).code,
        EXIT_INTERRUPTED,
    )


def test_an_unranked_refusal_survives_a_failed_delivery() raises:
    """A usage error was decided before any run existed; nothing re-ranks it."""
    var resources = _resources()
    resources.json_owns_fd = True
    assert_equal(
        resources.close_into(EXIT_USAGE_ERROR, rank_delivery=False).code,
        EXIT_USAGE_ERROR,
    )


def test_the_scratch_is_released_before_the_code_is_settled() raises:
    """An escalating delivery failure must not shorten the ladder above it."""
    var spool = _spool_with_fragments()
    try:
        var resources = _resources()
        resources.junit_spool = spool
        resources.json_owns_fd = True

        var outcome = resources.close_into(0, rank_delivery=True)

        assert_equal(outcome.code, 3)
        assert_false(exists(spool))
    finally:
        remove_tree(spool)


def test_a_live_exec_runtime_is_restored_without_a_diagnostic() raises:
    """The last rung, against the real process-global signal state."""
    var resources = _resources()
    resources.runtime.open()
    assert_true(resources.runtime.active)

    var outcome = resources.close_into(0, rank_delivery=False)

    assert_equal(outcome.code, 0)
    assert_equal(outcome.diagnostic, "")
    assert_false(resources.runtime.active)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
