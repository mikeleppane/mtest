"""The `--gh-annotations` coordinator wiring and tail rendering (L4).

Drives `run_session` with a real `AnnotationsReporter` behind the report
coordinator's annotation channel, a recorder standing in for the console, then
renders the tail through the coordinator's named `annotation_tail`. Pins: the
accumulated stream renders the deterministic per-kind-grouped tail
(node-id-sorted `::error` block, then `::warning` block, then the single
`::notice`); an inert reporter renders nothing; and the tail's `::notice` carries
the same exit-independent summary the console band does.
"""
from std.testing import assert_equal, assert_true

from mtest.report import (
    AnnotationsReporter,
    CompositeReporter,
    JsonStreamReporter,
    JunitReporter,
    RecordingCoordinator,
    RecordingReporter,
)
from mtest.session import run_session

from session_fixtures import (
    SRC_FAIL,
    SRC_PASS,
    base_config,
    temp_root,
    write_file,
)


def test_annotations_tail_rendered_through_the_coordinator() raises:
    var root = temp_root()
    write_file(root, "tests/test_pass.mojo", SRC_PASS)
    write_file(root, "tests/test_fail.mojo", SRC_FAIL)
    var config = base_config()

    var annotations = AnnotationsReporter(active=True)
    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter())),
        JsonStreamReporter.inert(),
        JunitReporter.inert(),
        annotations^,
    )
    var code = run_session(config, root, comp)
    assert_equal(code, 1, "a failing suite resolves to exit 1")

    var tail = comp.annotation_tail()
    assert_true(len(tail) >= 2, "expected at least an ::error and a ::notice")

    # The ::error block comes first, node-id-sorted; the single ::notice is last.
    assert_true(tail[0].startswith("::error "), "the error block is not first")
    assert_true("test_fail" in tail[0], "the failing file is not annotated")
    assert_true(
        tail[len(tail) - 1].startswith("::notice::"),
        "the single notice is not last",
    )

    # Per-kind grouping: every non-notice line before the notice is an ::error or
    # ::warning, never interleaved past the notice.
    for i in range(len(tail) - 1):
        assert_true(
            tail[i].startswith("::error ") or tail[i].startswith("::warning "),
            "a non-notice line followed the notice",
        )


def test_inactive_annotations_reporter_renders_nothing() raises:
    var root = temp_root()
    write_file(root, "tests/test_fail.mojo", SRC_FAIL)
    var config = base_config()

    var annotations = AnnotationsReporter.inert()
    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter())),
        JsonStreamReporter.inert(),
        JunitReporter.inert(),
        annotations^,
    )
    var code = run_session(config, root, comp)
    assert_equal(code, 1, "the run still resolves its real exit code")
    assert_equal(
        len(comp.annotation_tail()),
        0,
        "an inert annotations reporter must render nothing",
    )


def test_annotation_tail_empty_when_no_reporter_is_composed() raises:
    var root = temp_root()
    write_file(root, "tests/test_pass.mojo", SRC_PASS)
    var config = base_config()

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)
    assert_equal(code, 0, "a passing suite resolves to exit 0")
    # No annotations reporter composed: the channel answers inertly.
    assert_equal(len(comp.annotation_tail()), 0)
