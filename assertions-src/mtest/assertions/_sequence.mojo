"""Bounded diagnostics for top-level lists."""

from mtest.assertions._display import (
    _render_projection,
    _render_unequal_pair,
    BoundedWriter,
    DISPLAY_LIMIT,
)

comptime _LIST_LAYOUT_BYTE_BUDGET = 512


@fieldwise_init
struct _RenderedListSlice(Movable):
    """One bounded list-slice projection and its value-truncation state."""

    var text: String
    var truncated: Bool


def _render_list_slice[
    T: Copyable & ImplicitlyDestructible & Equatable & Writable
](values: List[T], start: Int, stop: Int, byte_cap: Int,) -> _RenderedListSlice:
    var output = BoundedWriter(byte_cap)
    output.write_trusted("[")
    var shown = 0
    var truncated = stop - start > DISPLAY_LIMIT
    for index in range(start, stop):
        if shown == DISPLAY_LIMIT:
            break
        var value = _render_projection(values[index])
        if value.truncated:
            truncated = True
        var projection = '"' + value.text + '"'
        if shown:
            projection = ", " + projection
        output.write_trusted(projection)
        if output.truncated:
            truncated = True
            break
        shown += 1
    output.write_trusted("]")
    if output.truncated:
        truncated = True
    return _RenderedListSlice(output.finish(), truncated)


def _write_list_span[
    T: Copyable & ImplicitlyDestructible & Equatable & Writable
](
    mut output: BoundedWriter,
    actual: List[T],
    expected: List[T],
    prefix: Int,
    suffix: Int,
):
    var actual_stop = len(actual) - suffix
    var expected_stop = len(expected) - suffix
    var actual_count = actual_stop - prefix
    var expected_count = expected_stop - prefix
    # Reserve room for both labels and the fixed summary before dividing the
    # caller's remaining diagnostic budget equally between the operands.
    var side_byte_cap = (output.max_bytes - _LIST_LAYOUT_BYTE_BUDGET) // 2
    var actual_projection = _render_list_slice(
        actual, prefix, actual_stop, side_byte_cap
    )
    var expected_projection = _render_list_slice(
        expected, prefix, expected_stop, side_byte_cap
    )
    output.write_trusted(
        "list span at index "
        + String(prefix)
        + ": actual "
        + String(actual_count)
        + " item(s), expected "
        + String(expected_count)
        + " item(s)"
        + "\n  actual omitted by entry limit: "
        + String(max(0, actual_count - DISPLAY_LIMIT))
        + ", expected omitted by entry limit: "
        + String(max(0, expected_count - DISPLAY_LIMIT))
    )
    if actual_projection.text == expected_projection.text:
        if actual_projection.truncated or expected_projection.truncated:
            output.write_trusted(
                "\n  displayed span projections are identical after truncation"
            )
        else:
            output.write_trusted(
                "\n  spans compare unequal but render identically"
            )
    output.write_trusted("\n  actual: " + actual_projection.text)
    output.write_trusted("\n  expected: " + expected_projection.text)


def write_list_difference[
    T: Copyable & ImplicitlyDestructible & Equatable & Writable
](mut output: BoundedWriter, actual: List[T], expected: List[T],) -> Bool:
    """Derive equality and write one bounded list mismatch diagnostic."""
    var shared = min(len(actual), len(expected))

    if len(actual) != len(expected):
        var prefix = 0
        while prefix < shared and actual[prefix] == expected[prefix]:
            prefix += 1
        var suffix = 0
        while suffix < len(actual) - prefix and suffix < len(expected) - prefix:
            var actual_index = len(actual) - suffix - 1
            var expected_index = len(expected) - suffix - 1
            var equal: Bool
            if len(actual) > len(expected):
                equal = actual[actual_index] == expected[expected_index]
            else:
                equal = expected[expected_index] == actual[actual_index]
            if not equal:
                break
            suffix += 1
        _write_list_span(output, actual, expected, prefix, suffix)
        return False

    var prefix = shared
    var last_mismatch = -1
    var first_equal_after_prefix = -1
    var mismatch_total = 0
    var mismatch_indices = List[Int]()
    for index in range(shared):
        if actual[index] == expected[index]:
            if prefix != shared and first_equal_after_prefix == -1:
                first_equal_after_prefix = index
        else:
            if prefix == shared:
                prefix = index
            last_mismatch = index
            mismatch_total += 1
            if len(mismatch_indices) < DISPLAY_LIMIT:
                mismatch_indices.append(index)
    if prefix == shared:
        return True

    var suffix = shared - last_mismatch - 1

    var interior_equal = (
        first_equal_after_prefix != -1
        and first_equal_after_prefix <= last_mismatch
    )

    if not interior_equal:
        _write_list_span(output, actual, expected, prefix, suffix)
        return False

    output.write_trusted(
        "list mismatches: "
        + String(mismatch_total)
        + " total, "
        + String(max(0, mismatch_total - DISPLAY_LIMIT))
        + " omitted by entry limit"
    )
    for index in mismatch_indices:
        output.write_trusted(
            "\n  ["
            + String(index)
            + "] "
            + _render_unequal_pair(actual[index], expected[index])
        )
        if output.truncated:
            break
    return False
