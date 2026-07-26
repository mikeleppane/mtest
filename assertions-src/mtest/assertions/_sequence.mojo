"""Bounded diagnostics for top-level lists."""

from mtest.assertions._display import (
    BoundedWriter,
    DISPLAY_LIMIT,
    render_value,
)


def _write_list_slice[
    T: Copyable & ImplicitlyDestructible & Equatable & Writable
](mut output: BoundedWriter, values: List[T], start: Int, stop: Int,):
    output.write_trusted("[")
    var shown = 0
    for index in range(start, stop):
        if shown == DISPLAY_LIMIT:
            break
        if shown:
            output.write_trusted(", ")
        output.write_trusted(render_value(values[index]))
        shown += 1
    output.write_trusted("]")


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
    output.write_trusted(
        "list span at index "
        + String(prefix)
        + ": actual "
        + String(actual_count)
        + " item(s), expected "
        + String(expected_count)
        + " item(s)"
        + "\n  actual omitted: "
        + String(max(0, actual_count - DISPLAY_LIMIT))
        + ", expected omitted: "
        + String(max(0, expected_count - DISPLAY_LIMIT))
        + "\n  actual: "
    )
    _write_list_slice(output, actual, prefix, actual_stop)
    output.write_trusted("\n  expected: ")
    _write_list_slice(output, expected, prefix, expected_stop)


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
        while (
            suffix < len(actual) - prefix
            and suffix < len(expected) - prefix
            and actual[len(actual) - suffix - 1]
            == expected[len(expected) - suffix - 1]
        ):
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

    var actual_stop = len(actual) - suffix
    var expected_stop = len(expected) - suffix
    var aligned = min(actual_stop - prefix, expected_stop - prefix)
    var interior_equal = (
        first_equal_after_prefix != -1
        and first_equal_after_prefix < prefix + aligned
    )

    if not interior_equal:
        _write_list_span(output, actual, expected, prefix, suffix)
        return False

    var total = mismatch_total
    output.write_trusted(
        "list mismatches: "
        + String(total)
        + " total, "
        + String(max(0, total - DISPLAY_LIMIT))
        + " omitted"
    )
    for index in mismatch_indices:
        output.write_trusted("\n  [" + String(index) + "] ")
        output.write_trusted(render_value(actual[index]))
        output.write_trusted(" != ")
        output.write_trusted(render_value(expected[index]))
    return False
