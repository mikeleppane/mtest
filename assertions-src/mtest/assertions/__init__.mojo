"""Bounded source-only assertions that preserve TestSuite failure semantics."""

import mtest.assertions._display as _display
import mtest.assertions._mapping as _mapping
import mtest.assertions._sequence as _sequence
import mtest.assertions._text as _text
import std.reflection as _reflection


@always_inline
def assert_equal(
    actual: String,
    expected: String,
    msg: String = "",
    *,
    location: Optional[_reflection.SourceLocation] = None,
) raises:
    """Assert exact string equality with bounded first-difference context.

    Args:
        actual: Observed string.
        expected: Expected string.
        msg: Optional reason appended after the mismatch details.
        location: Optional source location to report instead of the call site.

    Raises:
        Error: If `actual` and `expected` compare unequal.
    """
    if actual == expected:
        return
    var output = _display.BoundedWriter(_display.detail_byte_cap(msg != ""))
    _text.write_text_detail(output, actual, expected)
    var detail = _display.finish_detail(output.finish(), msg)
    if location:
        raise Error(location.value().prefix(detail))
    raise Error(_reflection.call_location().prefix(detail))


@always_inline
def assert_equal[
    T: Copyable & ImplicitlyDestructible & Equatable & Writable
](
    actual: List[T],
    expected: List[T],
    msg: String = "",
    *,
    location: Optional[_reflection.SourceLocation] = None,
) raises:
    """Assert exact list equality with bounded top-level structural details.

    Parameters:
        T: Copyable, equatable, writable list element type.

    Args:
        actual: Observed list.
        expected: Expected list with the same element type.
        msg: Optional reason appended after the mismatch details.
        location: Optional source location to report instead of the call site.

    Raises:
        Error: If the lists compare unequal.
    """
    var output = _display.BoundedWriter(_display.detail_byte_cap(msg != ""))
    if _sequence.write_list_difference(output, actual, expected):
        return
    var detail = _display.finish_detail(output.finish(), msg)
    if location:
        raise Error(location.value().prefix(detail))
    raise Error(_reflection.call_location().prefix(detail))


@always_inline
def assert_equal[
    V: Copyable & ImplicitlyDestructible & Equatable & Writable
](
    actual: Dict[String, V],
    expected: Dict[String, V],
    msg: String = "",
    *,
    location: Optional[_reflection.SourceLocation] = None,
) raises:
    """Assert exact dictionary equality with deterministic bounded categories.

    Parameters:
        V: Copyable, equatable, writable dictionary value type.

    Args:
        actual: Observed String-key dictionary.
        expected: Expected dictionary with the same value type.
        msg: Optional reason appended after the mismatch details.
        location: Optional source location to report instead of the call site.

    Raises:
        Error: If the dictionaries compare unequal.
    """
    var output = _display.BoundedWriter(_display.detail_byte_cap(msg != ""))
    if _mapping.write_dictionary_difference(output, actual, expected):
        return
    var detail = _display.finish_detail(output.finish(), msg)
    if location:
        raise Error(location.value().prefix(detail))
    raise Error(_reflection.call_location().prefix(detail))


@always_inline
def assert_equal[
    T: Equatable & Writable, _fallback: Bool = True, //
](
    actual: T,
    expected: T,
    msg: String = "",
    *,
    location: Optional[_reflection.SourceLocation] = None,
) raises:
    """Assert exact equality with a bounded opaque mismatch diagnostic.

    Parameters:
        T: Equatable and writable operand type.
        _fallback: Internal overload-ranking parameter.

    Args:
        actual: Observed value.
        expected: Expected value of the same type.
        msg: Optional reason appended after the mismatch details.
        location: Optional source location to report instead of the call site.

    Raises:
        Error: If `actual` and `expected` compare unequal.
    """
    if actual == expected:
        return
    var output = _display.BoundedWriter(_display.detail_byte_cap(msg != ""))
    _display.write_opaque_detail(output, actual, expected)
    var detail = _display.finish_detail(output.finish(), msg)
    if location:
        raise Error(location.value().prefix(detail))
    raise Error(_reflection.call_location().prefix(detail))
