"""Bounded source-only assertions that preserve TestSuite failure semantics."""

from std.reflection import SourceLocation, call_location

from mtest.assertions._display import (
    BODY_BYTE_CAP,
    BoundedWriter,
    write_opaque_detail,
)
from mtest.assertions._text import write_text_detail
from mtest.assertions._sequence import write_list_difference
from mtest.assertions._mapping import write_dictionary_difference


@always_inline
def assert_equal(
    actual: String,
    expected: String,
    msg: String = "",
    *,
    location: Optional[SourceLocation] = None,
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
    var output = BoundedWriter(BODY_BYTE_CAP)
    write_text_detail(output, actual, expected)
    if msg:
        output.write_trusted("\n  reason: ")
        output.write(msg)
    var detail = output.finish()
    if location:
        raise Error(location.value().prefix(detail))
    raise Error(call_location().prefix(detail))


@always_inline
def assert_equal[
    T: Copyable & ImplicitlyDestructible & Equatable & Writable
](
    actual: List[T],
    expected: List[T],
    msg: String = "",
    *,
    location: Optional[SourceLocation] = None,
) raises:
    """Assert exact list equality with bounded top-level structural details.

    Args:
        actual: Observed list.
        expected: Expected list with the same element type.
        msg: Optional reason appended after the mismatch details.
        location: Optional source location to report instead of the call site.

    Raises:
        Error: If the lists compare unequal.
    """
    var output = BoundedWriter(BODY_BYTE_CAP)
    if write_list_difference(output, actual, expected):
        return
    if msg:
        output.write_trusted("\n  reason: ")
        output.write(msg)
    var detail = output.finish()
    if location:
        raise Error(location.value().prefix(detail))
    raise Error(call_location().prefix(detail))


@always_inline
def assert_equal[
    V: Copyable & ImplicitlyDestructible & Equatable & Writable
](
    actual: Dict[String, V],
    expected: Dict[String, V],
    msg: String = "",
    *,
    location: Optional[SourceLocation] = None,
) raises:
    """Assert exact dictionary equality with deterministic bounded categories.

    Args:
        actual: Observed String-key dictionary.
        expected: Expected dictionary with the same value type.
        msg: Optional reason appended after the mismatch details.
        location: Optional source location to report instead of the call site.

    Raises:
        Error: If the dictionaries compare unequal.
    """
    var output = BoundedWriter(BODY_BYTE_CAP)
    if write_dictionary_difference(output, actual, expected):
        return
    if msg:
        output.write_trusted("\n  reason: ")
        output.write(msg)
    var detail = output.finish()
    if location:
        raise Error(location.value().prefix(detail))
    raise Error(call_location().prefix(detail))


@always_inline
def assert_equal[
    T: Equatable & Writable, _fallback: Bool = True, //
](
    actual: T,
    expected: T,
    msg: String = "",
    *,
    location: Optional[SourceLocation] = None,
) raises:
    """Assert exact equality with a bounded opaque mismatch diagnostic.

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
    var output = BoundedWriter(BODY_BYTE_CAP)
    write_opaque_detail(output, actual, expected)
    if msg:
        output.write_trusted("\n  reason: ")
        output.write(msg)
    var detail = output.finish()
    if location:
        raise Error(location.value().prefix(detail))
    raise Error(call_location().prefix(detail))
