"""The pure byte-assembly and throttle arithmetic of the live progress counter.

No processes, no console descriptor, no clock: the parallel driver's ephemeral
TTY counter is decoration written directly to the borrowed handle, never part of
the committed console stream, so its two decidable pieces are pinned here in
isolation. `_progress_flush_bytes` assembles one flush — erase the shown counter,
write the committed chunk, redraw the counter — and `_should_emit_progress`
decides when a tick is worth a redraw (a completion or an in-flight-set change is
always shown; an elapsed-only refresh is throttled). The erase/redraw's real
console coordination and the piped-absence guarantee are proved end to end by the
`parallel-progress-tty` e2e scenario against a real PTY and a pipe.
"""
from std.testing import assert_equal, assert_false, assert_true

from mtest.session.pool import (
    _PROGRESS_INTERVAL_NS,
    _progress_flush_bytes,
    _should_emit_progress,
)


def test_flush_erases_before_chunk_when_a_counter_was_shown() raises:
    # A shown counter is erased first: the assembly begins with the single-line
    # erase (`\r\x1b[K`), then the committed chunk, then the redrawn counter.
    var out = _progress_flush_bytes("verdict\n", "COUNTER", True)
    assert_true(out.startswith("\r\x1b[K"))
    assert_true("verdict\n" in out)
    assert_true(out.endswith("COUNTER"))


def test_flush_writes_no_escape_bytes_off_a_terminal() raises:
    # Off a terminal the overlay is empty and no counter was ever shown, so the
    # assembly is exactly the committed chunk — not one escape byte reaches a
    # pipe. This is the piped-absence guarantee at the byte level.
    var out = _progress_flush_bytes("verdict\n", "", False)
    assert_equal(out, String("verdict\n"))
    assert_false("\x1b" in out)
    assert_false("\r" in out)


def test_flush_first_draw_has_no_erase_prefix() raises:
    # The first counter draw, before any is shown, redraws without erasing —
    # there is nothing on screen to clear.
    var out = _progress_flush_bytes("", "COUNTER", False)
    assert_equal(out, String("COUNTER"))


def test_flush_closing_erase_clears_without_redraw() raises:
    # The batch-terminal flush erases the shown counter and redraws nothing (the
    # caller passes an empty overlay), leaving just the single-line erase so the
    # counter never survives into the framed sections and summary.
    var out = _progress_flush_bytes("", "", True)
    assert_equal(out, String("\r\x1b[K"))


def test_throttle_coalesces_same_state_within_the_interval() raises:
    # Two ticks with the same completed count and the same in-flight set, closer
    # together than the interval, coalesce: the later one does not re-emit.
    var emit = _should_emit_progress(
        3,
        3,
        "a.mojo\nb.mojo\n",
        "a.mojo\nb.mojo\n",
        1_050_000_000,
        1_000_000_000,
        _PROGRESS_INTERVAL_NS,
    )
    assert_false(emit)


def test_throttle_always_emits_on_a_completed_change() raises:
    # A finished file changes the completed count and is always shown at once,
    # however little time has passed — a finished file's block never waits.
    var emit = _should_emit_progress(
        4,
        3,
        "a.mojo\n",
        "a.mojo\n",
        1_000_000_010,
        1_000_000_000,
        _PROGRESS_INTERVAL_NS,
    )
    assert_true(emit)


def test_throttle_always_emits_on_a_running_set_change() raises:
    # A change in which files are in flight is a semantic change and is shown at
    # once, even within the interval.
    var emit = _should_emit_progress(
        3,
        3,
        "a.mojo\nc.mojo\n",
        "a.mojo\nb.mojo\n",
        1_010_000_000,
        1_000_000_000,
        _PROGRESS_INTERVAL_NS,
    )
    assert_true(emit)


def test_throttle_admits_an_elapsed_only_refresh_after_the_interval() raises:
    # With neither a completion nor a set change, a refresh is admitted once the
    # interval has elapsed, bounding the elapsed-only redraw rate.
    var emit = _should_emit_progress(
        3,
        3,
        "a.mojo\n",
        "a.mojo\n",
        1_000_000_000 + _PROGRESS_INTERVAL_NS,
        1_000_000_000,
        _PROGRESS_INTERVAL_NS,
    )
    assert_true(emit)
