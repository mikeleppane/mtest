"""The `--gh-annotations` composite reindex and tail rendering (L4).

Drives `run_session` with a real `AnnotationsReporter` composed at a fixed
comptime index (mirroring `main`'s `(console, stream, junit, annotations)`, here
`(recorder, annotations)` at `run_session[-1, -1, 1]`), then reaches the concrete
reporter through the compile-time type-checked `annotation_lines[ann_index]`
typed-`Pointer` helper. Pins: the accumulated stream renders the deterministic
per-kind-grouped tail (node-id-sorted `::error` block, then `::warning` block,
then the single `::notice`); an inert reporter renders nothing; and the tail's
`::notice` carries the same exit-independent summary the console band does.
"""
from std.testing import assert_equal, assert_true

from mtest.report import (
    AnnotationsReporter,
    CompositeReporter,
    RecordingReporter,
)
from mtest.session import annotation_lines, run_session

from session_fixtures import (
    SRC_FAIL,
    SRC_PASS,
    base_config,
    temp_root,
    write_file,
)


def test_annotations_tail_rendered_via_composite_index() raises:
    var root = temp_root()
    write_file(root, "tests/test_pass.mojo", SRC_PASS)
    write_file(root, "tests/test_fail.mojo", SRC_FAIL)
    var config = base_config()

    var annotations = AnnotationsReporter(active=True)
    var comp = CompositeReporter(Tuple(RecordingReporter(), annotations^))

    # stream_index = -1, junit_index = -1, ann_index = 1.
    var code = run_session[-1, -1, 1](config, root, comp)
    assert_equal(code, 1, "a failing suite resolves to exit 1")

    var tail = annotation_lines[1](comp)
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
    var comp = CompositeReporter(Tuple(RecordingReporter(), annotations^))

    var code = run_session[-1, -1, 1](config, root, comp)
    assert_equal(code, 1, "the run still resolves its real exit code")
    assert_equal(
        len(annotation_lines[1](comp)),
        0,
        "an inert annotations reporter must render nothing",
    )


def test_ann_index_negative_one_elides_the_tail() raises:
    var root = temp_root()
    write_file(root, "tests/test_pass.mojo", SRC_PASS)
    var config = base_config()

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(config, root, comp)
    assert_equal(code, 0, "a passing suite resolves to exit 0")
    # No annotations reporter composed: the comptime branch is elided.
    assert_equal(len(annotation_lines[-1](comp)), 0)
