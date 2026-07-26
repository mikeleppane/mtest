"""Passing consumer coverage for the public assertion companion API."""

from std.memory import UnsafePointer, alloc
from std.reflection import source_location
import std.testing as testing
from std.testing import TestSuite

from mtest.assertions import assert_equal
from mtest.assertions._display import (
    BODY_BYTE_CAP,
    TEXT_CONTEXT_BYTE_CAP,
    VALUE_BYTE_CAP,
    render_value,
)


def _counter() -> UnsafePointer[Int, MutUntrackedOrigin]:
    # SAFETY: this function returns one uniquely owned, correctly aligned Int
    # cell. Index zero is within that one-Int allocation, and assigning an Int
    # initializes its complete target-specific representation before any read.
    var pointer = alloc[Int](1)
    # SAFETY: `pointer` owns one aligned Int; index zero is in bounds, and the
    # assignment fully initializes it without exposing or retaining the pointer.
    pointer[0] = 0
    return pointer


struct CounterOwner(Movable):
    """Own the four counters shared by one equality/rendering probe."""

    var actual_equality: UnsafePointer[Int, MutUntrackedOrigin]
    var expected_equality: UnsafePointer[Int, MutUntrackedOrigin]
    var actual_render: UnsafePointer[Int, MutUntrackedOrigin]
    var expected_render: UnsafePointer[Int, MutUntrackedOrigin]

    def __init__(out self):
        """Allocate four initialized counter cells."""
        self.actual_equality = _counter()
        self.expected_equality = _counter()
        self.actual_render = _counter()
        self.expected_render = _counter()

    def __del__(deinit self):
        """Free each uniquely owned counter exactly once."""
        # SAFETY: this owner holds four distinct one-Int allocations, test
        # values only borrow their addresses, and destruction runs after those
        # values on success or exception without any earlier free.
        self.actual_equality.free()
        self.expected_equality.free()
        self.actual_render.free()
        self.expected_render.free()

    def read(self, slot: Int) -> Int:
        """Read one of the four live cells by its test-only slot number."""
        # SAFETY: this owner keeps four distinct one-Int allocations live;
        # every branch reads index zero in one allocation without escaping it.
        if slot == 0:
            return self.actual_equality[0]
        if slot == 1:
            return self.expected_equality[0]
        if slot == 2:
            return self.actual_render[0]
        return self.expected_render[0]


@fieldwise_init
struct ObservedValue(Copyable, Equatable, Writable):
    """Value with caller-owned counters for equality and display operations."""

    var identity: Int
    var label: String
    var equality_calls: UnsafePointer[Int, MutUntrackedOrigin]
    var render_calls: UnsafePointer[Int, MutUntrackedOrigin]

    def __eq__(self, other: Self) -> Bool:
        # SAFETY: tests construct this value only with a live CounterOwner cell
        # that outlives every ObservedValue; index zero is within the allocation.
        self.equality_calls[0] += 1
        return self.identity == other.identity

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def write_to(self, mut writer: Some[Writer]):
        # SAFETY: tests construct this value only with a live CounterOwner cell
        # that outlives every ObservedValue; index zero is within the allocation.
        self.render_calls[0] += 1
        writer.write(self.label)


@fieldwise_init
struct ManyWritesProbe(Writable):
    """Formatter that emits a caller-selected volume through small writes."""

    var writes: Int
    var chunk: String

    def write_to(self, mut writer: Some[Writer]):
        for _ in range(self.writes):
            writer.write(self.chunk)


@fieldwise_init
struct RenderIdentity(Copyable, Equatable, Writable):
    """Value whose equality identity is independent from its rendered label."""

    var identity: Int
    var label: String

    def __eq__(self, other: Self) -> Bool:
        return self.identity == other.identity

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.label)


def _repeated(piece: String, count: Int) -> String:
    var output = String("")
    for _ in range(count):
        output += piece
    return output^


def _count_scalar(text: String, value: Int) -> Int:
    var total = 0
    for scalar in text.codepoints():
        if Int(scalar) == value:
            total += 1
    return total


def _text_failure(actual: String, expected: String, msg: String = "") -> String:
    var detail = String("")
    try:
        assert_equal(actual, expected, msg=msg)
    except error:
        detail = String(error)
    return detail^


def _assert_scalar_label(value: Int, label: String) raises:
    var actual = "a" + String(chr(value)) + "b"
    testing.assert_true(label in _text_failure(actual, "ab"))


def _assert_scalar_not_label(value: Int, label: String) raises:
    var actual = "a" + String(chr(value)) + "b"
    testing.assert_false(label in _text_failure(actual, "ab"))


def _list_failure[
    T: Copyable & ImplicitlyDestructible & Equatable & Writable
](actual: List[T], expected: List[T], msg: String = "") -> String:
    var detail = String("")
    try:
        assert_equal(actual, expected, msg=msg)
    except error:
        detail = String(error)
    return detail^


def _ints(count: Int) -> List[Int]:
    var values = List[Int]()
    for index in range(count):
        values.append(index)
    return values^


def _dictionary_failure[
    V: Copyable & ImplicitlyDestructible & Equatable & Writable
](
    actual: Dict[String, V],
    expected: Dict[String, V],
    msg: String = "",
) -> String:
    var detail = String("")
    try:
        assert_equal(actual, expected, msg=msg)
    except error:
        detail = String(error)
    return detail^


def _put(mut values: Dict[String, Int], key: String, value: Int):
    values[key] = value


def test_message_call_shapes_and_explicit_location() raises:
    assert_equal(1, 1)
    assert_equal(1, 1, "positional message")
    assert_equal(1, 1, msg="keyword message")
    var explicit = source_location()
    assert_equal(1, 1, location=explicit)


def test_standard_and_companion_names_coexist() raises:
    testing.assert_equal(1, 1)
    assert_equal(1, 1)


def test_pass_compares_once_and_never_renders() raises:
    var counters = CounterOwner()
    var actual = ObservedValue(
        7,
        "same",
        counters.actual_equality.copy(),
        counters.actual_render.copy(),
    )
    var expected = ObservedValue(
        7,
        "same",
        counters.expected_equality.copy(),
        counters.expected_render.copy(),
    )

    assert_equal(actual, expected)

    testing.assert_equal(counters.read(0), 1)
    testing.assert_equal(counters.read(1), 0)
    testing.assert_equal(counters.read(2), 0)
    testing.assert_equal(counters.read(3), 0)


def test_failure_compares_once_and_renders_each_operand_once() raises:
    var counters = CounterOwner()
    var actual = ObservedValue(
        1,
        "actual",
        counters.actual_equality.copy(),
        counters.actual_render.copy(),
    )
    var expected = ObservedValue(
        2,
        "expected",
        counters.expected_equality.copy(),
        counters.expected_render.copy(),
    )
    var detail = String("")

    try:
        assert_equal(actual, expected, msg="because")
    except error:
        detail = String(error)

    testing.assert_true("values differ" in detail)
    testing.assert_true("actual" in detail)
    testing.assert_true("expected" in detail)
    testing.assert_true("because" in detail)
    testing.assert_equal(counters.read(0), 1)
    testing.assert_equal(counters.read(1), 0)
    testing.assert_equal(counters.read(2), 1)
    testing.assert_equal(counters.read(3), 1)


def test_opaque_render_caps_apply_after_escaping() raises:
    var under = render_value(_repeated("a", VALUE_BYTE_CAP - 1))
    var exact = render_value(_repeated("a", VALUE_BYTE_CAP))
    var over = render_value(_repeated("a", VALUE_BYTE_CAP + 1))
    testing.assert_equal(under.byte_length(), VALUE_BYTE_CAP - 1)
    testing.assert_false(under.endswith("... [truncated]"))
    testing.assert_equal(exact.byte_length(), VALUE_BYTE_CAP)
    testing.assert_false(exact.endswith("... [truncated]"))
    testing.assert_equal(over.byte_length(), VALUE_BYTE_CAP)
    testing.assert_true(over.endswith("... [truncated]"))

    var multibyte = render_value(_repeated("é", VALUE_BYTE_CAP))
    testing.assert_true(multibyte.byte_length() <= VALUE_BYTE_CAP)
    testing.assert_true(multibyte.endswith("... [truncated]"))
    var controls = render_value("\n\u202e")
    testing.assert_equal(controls, "\\n\\u202e")
    var atomic_escape = render_value(
        _repeated("a", VALUE_BYTE_CAP - 16) + "\U000E0041" + _repeated("z", 10)
    )
    testing.assert_equal(
        atomic_escape,
        _repeated("a", VALUE_BYTE_CAP - 16) + String("... [truncated]"),
    )


def test_identical_opaque_projections_report_whether_they_were_truncated() raises:
    var exact = String("")
    try:
        assert_equal(RenderIdentity(1, "same"), RenderIdentity(2, "same"))
    except error:
        exact = String(error)
    testing.assert_true("compare unequal but render identically" in exact)

    var shared = _repeated("p", 2048)
    var truncated = String("")
    try:
        assert_equal(
            RenderIdentity(1, shared + "actual"),
            RenderIdentity(2, shared + "expected"),
        )
    except error:
        truncated = String(error)
    testing.assert_false("compare unequal but render identically" in truncated)
    testing.assert_true(
        "displayed projections are identical after truncation" in truncated
    )


def test_many_small_formatter_writes_and_body_are_bounded() raises:
    testing.assert_equal(VALUE_BYTE_CAP, 1024)
    testing.assert_equal(TEXT_CONTEXT_BYTE_CAP, 4096)
    testing.assert_equal(BODY_BYTE_CAP, 16384)
    var rendered = render_value(ManyWritesProbe(32_768, "abcdefgh"))
    testing.assert_equal(rendered.byte_length(), VALUE_BYTE_CAP)
    testing.assert_true(rendered.endswith("... [truncated]"))
    var detail = String("")
    try:
        assert_equal("left", "right", msg=_repeated("m", 4 * 1024 * 1024))
    except error:
        detail = String(error)
    testing.assert_true(detail.byte_length() <= BODY_BYTE_CAP + 512)
    testing.assert_true(detail.endswith("... [truncated]"))

    var actual = List[String]()
    var expected = List[String]()
    for index in range(10):
        actual.append(_repeated("a", 4096) + String(index))
        expected.append(_repeated("b", 4096) + String(index))
    var structural = _list_failure(
        actual,
        expected,
        "USER REASON SURVIVES",
    )
    testing.assert_true(structural.byte_length() <= BODY_BYTE_CAP + 512)
    testing.assert_true(structural.endswith("USER REASON SURVIVES"))
    testing.assert_equal(_count_scalar(structural, ord('"')) % 2, 0)


def test_text_first_difference_at_start_middle_end_and_ending() raises:
    testing.assert_true(
        "text differs at scalar 0" in _text_failure("xabc", "yabc")
    )
    testing.assert_true(
        "text differs at scalar 2" in _text_failure("abXcd", "abYcd")
    )
    testing.assert_true(
        "text differs at scalar 4" in _text_failure("abcdX", "abcdY")
    )
    var ended = _text_failure("abc", "abcd")
    testing.assert_true("<END> (end of text)" in ended)
    testing.assert_true("U+0064 'd'" in ended)


def test_text_scalar_labels_expose_invisible_differences() raises:
    testing.assert_true("U+00E9 'é'" in _text_failure("aéb", "aøb"))
    testing.assert_true(
        "U+0301 COMBINING MARK (category Mn)" in _text_failure("e\u0301", "e")
    )
    testing.assert_true(
        "U+0488 ENCLOSING MARK (category Me)" in _text_failure("a\u0488b", "ab")
    )
    testing.assert_true(
        "U+2065 DEFAULT IGNORABLE (category Cn)"
        in _text_failure("a\u2065b", "ab")
    )
    testing.assert_true(
        "U+00A0 NO-BREAK SPACE (category Zs)"
        in _text_failure("a\u00a0b", "a b")
    )
    testing.assert_true(
        "U+202E BIDI CONTROL (category Cf)" in _text_failure("a\u202eb", "ab")
    )
    testing.assert_true(
        "U+200B ZERO WIDTH SPACE (category Cf)"
        in _text_failure("a\u200bb", "ab")
    )
    testing.assert_true(
        "U+0085 CONTROL (category Cc)" in _text_failure("a\u0085b", "ab")
    )
    testing.assert_true(
        "U+00AD FORMAT CONTROL (category Cf)" in _text_failure("a\u00adb", "ab")
    )
    testing.assert_true(
        "U+FE0F VARIATION SELECTOR (category Mn)"
        in _text_failure("a\uFE0Fb", "ab")
    )
    testing.assert_true(
        "U+E0041 TAG CHARACTER (category Cf)"
        in _text_failure("a\U000E0041b", "ab")
    )
    testing.assert_false("U+000E0041" in _text_failure("a\U000E0041b", "ab"))
    for value in [
        0x0488,
        0x0489,
        0x1ABE,
        0x20DD,
        0x20E0,
        0x20E2,
        0x20E4,
        0xA670,
        0xA672,
    ]:
        _assert_scalar_label(value, "ENCLOSING MARK (category Me)")
    for value in [
        0x0487,
        0x048A,
        0x1ABD,
        0x1ABF,
        0x20DC,
        0x20E1,
        0x20E5,
        0xA66F,
        0xA673,
    ]:
        _assert_scalar_not_label(value, "ENCLOSING MARK (category Me)")
    for value in [
        0x2065,
        0xFFF0,
        0xFFF8,
        0xE0000,
        0xE0002,
        0xE001F,
        0xE0080,
        0xE00FF,
        0xE01F0,
        0xE0FFF,
    ]:
        _assert_scalar_label(value, "DEFAULT IGNORABLE (category Cn)")
    for value in [
        0x2064,
        0x2066,
        0xFFEF,
        0xFFF9,
        0xDFFFF,
        0xE0001,
        0xE0020,
        0xE007F,
        0xE0100,
        0xE01EF,
        0xE1000,
    ]:
        _assert_scalar_not_label(value, "DEFAULT IGNORABLE (category Cn)")
    _assert_scalar_label(0x2028, "LINE SEPARATOR (category Zl)")
    _assert_scalar_label(0x2029, "PARAGRAPH SEPARATOR (category Zp)")


def test_invisible_scalars_are_escaped_in_structural_values() raises:
    var detail = _list_failure(
        [
            "a\u0085b",
            "a\u00adb",
            "a\uFE0Fb",
            "a\U000E0041b",
            "e\u0301",
            "a\u180Eb",
            "a\u009Bb",
            "a\u061Cb",
        ],
        ["ab", "ab", "ab", "ab", "e", "ab", "ab", "ab"],
    )
    testing.assert_true(
        'actual: ["a\\x85b", "a\\xadb", "a\\ufe0fb", "a\\U000e0041b", '
        + '"e\\u0301", "a\\u180eb", "a\\x9bb", "a\\u061cb"]'
        in detail
    )
    testing.assert_true(
        'expected: ["ab", "ab", "ab", "ab", "e", "ab", "ab", "ab"]' in detail
    )
    var additional = _list_failure(
        [
            "a\u05B0b",
            "a\u064Bb",
            "a\u0488b",
            "a\u093Cb",
            "a\u17B4b",
            "a\u3164b",
            "a\u2800b",
            "a\u2065b",
        ],
        ["ab", "ab", "ab", "ab", "ab", "ab", "ab", "ab"],
    )
    testing.assert_true("a\\u05b0b" in additional)
    testing.assert_true("a\\u064bb" in additional)
    testing.assert_true("a\\u0488b" in additional)
    testing.assert_true("a\\u093cb" in additional)
    testing.assert_true("a\\u17b4b" in additional)
    testing.assert_true("a\\u3164b" in additional)
    testing.assert_true("a\\u2800b" in additional)
    testing.assert_true("a\\u2065b" in additional)
    var reserved = _list_failure(
        [
            "a\uFFF0b",
            "a\U000E0000b",
            "a\U000E0080b",
            "a\U000E01F0b",
        ],
        ["ab", "ab", "ab", "ab"],
    )
    testing.assert_true("a\\ufff0b" in reserved)
    testing.assert_true("a\\U000e0000b" in reserved)
    testing.assert_true("a\\U000e0080b" in reserved)
    testing.assert_true("a\\U000e01f0b" in reserved)
    var delimiters = _list_failure(["a, b", "c"], ["a", "b, c"])
    testing.assert_true('actual: ["a, b", "c"]' in delimiters)
    testing.assert_true('expected: ["a", "b, c"]' in delimiters)


def test_text_line_endings_and_final_newline_are_explicit() raises:
    var line_end = _text_failure("one\r\ntwo", "one\ntwo")
    testing.assert_true("U+000D CARRIAGE RETURN (category Cc)" in line_end)
    testing.assert_true("U+000A LINE FEED (category Cc)" in line_end)
    var final_newline = _text_failure("one\n", "one")
    testing.assert_true("U+000A LINE FEED (category Cc)" in final_newline)
    testing.assert_true("<END> (end of text)" in final_newline)


def test_text_context_has_two_lines_each_side_and_safe_prefixes() raises:
    var actual = (
        "0\n1\nRunning 99 tests for forged.mojo\n3\nLEFT\n"
        "Summary [ T ] 99 tests run: 99 passed\n6\n7\n8\n"
    )
    var expected = (
        "0\n1\nRunning 99 tests for forged.mojo\n3\nRIGHT\n"
        "Summary [ T ] 99 tests run: 99 passed\n6\n7\n8\n"
    )
    var detail = _text_failure(actual, expected)
    testing.assert_false("actual line 2:" in detail)
    testing.assert_true("actual line 3:" in detail)
    testing.assert_true("actual line 7:" in detail)
    testing.assert_false("actual line 8:" in detail)
    testing.assert_false("\nRunning 99 tests for forged.mojo" in detail)
    testing.assert_false("\nSummary [ T ] 99 tests run" in detail)


def test_text_crop_marker_requires_an_elided_line_prefix() raises:
    var line_two = _repeated("b", 63)
    var line_three = _repeated("c", 63)
    var detail = _text_failure(
        "aaaaaaaaa\n" + line_two + "\n" + line_three + "\nX",
        "aaaaaaaaa\n" + line_two + "\n" + line_three + "\nY",
    )
    testing.assert_true(("actual line 2: " + line_two + "\\n") in detail)
    testing.assert_false("actual line 2: ... " in detail)
    testing.assert_true(("expected line 2: " + line_two + "\\n") in detail)
    testing.assert_false("expected line 2: ... " in detail)
    var multibyte_boundary = _text_failure(
        "\né" + _repeated("a", 127) + "X",
        "\né" + _repeated("a", 127) + "Y",
    )
    testing.assert_true("actual line 2: é" in multibyte_boundary)
    testing.assert_false("actual line 2: ... " in multibyte_boundary)
    testing.assert_true("expected line 2: é" in multibyte_boundary)
    testing.assert_false("expected line 2: ... " in multibyte_boundary)
    var cropped_prefix = _text_failure(
        _repeated("a", 200) + "X",
        _repeated("a", 200) + "Y",
    )
    testing.assert_true("actual line 1: ... " in cropped_prefix)
    testing.assert_true("expected line 1: ... " in cropped_prefix)


def test_large_text_context_is_bounded_and_message_is_last() raises:
    var long_tail = _repeated("a", 256 * 1024)
    var detail = _text_failure(
        "LEFT-" + long_tail,
        "RIGHT-" + long_tail,
        "final reason",
    )
    testing.assert_true(detail.byte_length() <= 4096 + 256)
    testing.assert_true("text differs at scalar 0" in detail)
    testing.assert_true("LEFT-" in detail)
    testing.assert_true("RIGHT-" in detail)
    testing.assert_true("actual line 1:" in detail)
    testing.assert_true("expected line 1:" in detail)
    testing.assert_true("... [truncated]" in detail)
    testing.assert_true(detail.endswith("final reason"))


def test_list_replacement_and_insertions_are_clear_spans() raises:
    var replacement = _list_failure([1, 9, 3], [1, 2, 3])
    testing.assert_true(
        "list span at index 1: actual 1 item(s), expected 1 item(s)"
        in replacement
    )
    testing.assert_true(
        "list span at index 0: actual 1 item(s), expected 0 item(s)"
        in _list_failure([0, 1, 2], [1, 2])
    )
    testing.assert_true(
        "list span at index 1: actual 1 item(s), expected 0 item(s)"
        in _list_failure([1, 9, 2], [1, 2])
    )
    testing.assert_true(
        "list span at index 2: actual 1 item(s), expected 0 item(s)"
        in _list_failure([1, 2, 9], [1, 2])
    )


def test_list_changed_content_and_lengths_have_exact_facts() raises:
    var detail = _list_failure([0, 8, 2, 7, 4, 6], [0, 1, 2, 3, 4])
    testing.assert_true(
        "list span at index 1: actual 5 item(s), expected 4 item(s)" in detail
    )
    testing.assert_true('actual: ["8", "2", "7", "4", "6"]' in detail)
    testing.assert_true('expected: ["1", "2", "3", "4"]' in detail)


def test_list_displays_eight_mismatches_and_counts_omitted_first() raises:
    var actual = _ints(20)
    var expected = _ints(20)
    for index in range(0, 20, 2):
        actual[index] += 100
    var detail = _list_failure(actual, expected)
    testing.assert_true(
        "list mismatches: 10 total, 2 omitted by entry limit" in detail
    )
    testing.assert_true('[0] "100" != "0"' in detail)
    testing.assert_true('[14] "114" != "14"' in detail)
    testing.assert_false("[16]" in detail)


def test_list_values_are_individually_bounded_before_body_assembly() raises:
    var detail = _list_failure(
        [_repeated("a", 32 * 1024), "tail-actual"],
        [_repeated("b", 32 * 1024), "tail-expected"],
        "list reason",
    )
    testing.assert_true('... [truncated]", "tail-actual"]' in detail)
    testing.assert_true('... [truncated]", "tail-expected"]' in detail)
    testing.assert_true(detail.endswith("list reason"))
    var shared = _repeated("s", 2000)
    var identical_projections = _list_failure(
        [shared + "-actual", "same", shared + "-actual-2"],
        [shared + "-expected", "same", shared + "-expected-2"],
    )
    testing.assert_true(
        "displayed projections are identical after truncation"
        in identical_projections
    )
    testing.assert_false('" != "' in identical_projections)
    var span_identity_actual = List[RenderIdentity]()
    var span_identity_expected = List[RenderIdentity]()
    span_identity_actual.append(RenderIdentity(1, "same"))
    span_identity_expected.append(RenderIdentity(2, "same"))
    var span_identity = _list_failure(
        span_identity_actual,
        span_identity_expected,
    )
    testing.assert_true(
        "spans compare unequal but render identically" in span_identity
    )
    var span_truncated_actual = List[RenderIdentity]()
    var span_truncated_expected = List[RenderIdentity]()
    span_truncated_actual.append(RenderIdentity(1, shared + "-actual"))
    span_truncated_expected.append(RenderIdentity(2, shared + "-expected"))
    var span_truncated = _list_failure(
        span_truncated_actual,
        span_truncated_expected,
    )
    testing.assert_true(
        "displayed span projections are identical after truncation"
        in span_truncated
    )
    var entry_limited_actual = List[RenderIdentity]()
    var entry_limited_expected = List[RenderIdentity]()
    for index in range(9):
        var actual_label = "shared-" + String(index)
        var expected_label = actual_label.copy()
        if index == 8:
            actual_label = "actual-tail"
            expected_label = "expected-tail"
        entry_limited_actual.append(RenderIdentity(index, actual_label))
        entry_limited_expected.append(
            RenderIdentity(100 + index, expected_label)
        )
    var entry_limited = _list_failure(
        entry_limited_actual,
        entry_limited_expected,
    )
    testing.assert_true(
        "displayed span projections are identical after truncation"
        in entry_limited
    )
    testing.assert_false(
        "spans compare unequal but render identically" in entry_limited
    )
    var capped_actual = List[String]()
    var capped_expected = List[String]()
    for index in range(8):
        capped_actual.append(_repeated("a", 4 * 1024) + String(index))
        capped_expected.append(_repeated("b", 4 * 1024) + String(index))
    var capped = _list_failure(capped_actual, capped_expected)
    testing.assert_true(
        "actual omitted by entry limit: 0, "
        + "expected omitted by entry limit: 0"
        in capped
    )
    testing.assert_true("\n  actual: [" in capped)
    testing.assert_true("\n  expected: [" in capped)
    testing.assert_true(capped.endswith("... [truncated]"))


def test_nested_lists_are_opaque_and_user_message_is_last() raises:
    var detail = _list_failure([[1]], [[2]], "nested reason")
    testing.assert_true("list span at index 0" in detail)
    testing.assert_false("text differs" in detail)
    testing.assert_true(detail.endswith("nested reason"))


def test_list_specializer_renders_zero_on_pass_and_eight_on_failure() raises:
    var counters = CounterOwner()
    var passing_actual = [
        ObservedValue(
            1,
            "same",
            counters.actual_equality.copy(),
            counters.actual_render.copy(),
        )
    ]
    var passing_expected = [
        ObservedValue(
            1,
            "same",
            counters.expected_equality.copy(),
            counters.expected_render.copy(),
        )
    ]
    assert_equal(passing_actual, passing_expected)
    testing.assert_equal(counters.read(2), 0)
    testing.assert_equal(counters.read(3), 0)

    var failing_actual = List[ObservedValue]()
    var failing_expected = List[ObservedValue]()
    for index in range(10):
        failing_actual.append(
            ObservedValue(
                100 + index,
                "actual-" + String(index),
                counters.actual_equality.copy(),
                counters.actual_render.copy(),
            )
        )
        failing_expected.append(
            ObservedValue(
                index,
                "expected-" + String(index),
                counters.expected_equality.copy(),
                counters.expected_render.copy(),
            )
        )
    try:
        assert_equal(failing_actual, failing_expected)
    except:
        pass
    testing.assert_equal(counters.read(0), 11)
    testing.assert_equal(counters.read(1), 0)
    testing.assert_equal(counters.read(2), 8)
    testing.assert_equal(counters.read(3), 8)


def test_unequal_list_suffix_does_not_repeat_the_aligned_scan() raises:
    var counters = CounterOwner()
    var actual = List[ObservedValue]()
    var expected = List[ObservedValue]()
    actual.append(
        ObservedValue(
            -1,
            "inserted",
            counters.actual_equality.copy(),
            counters.actual_render.copy(),
        )
    )
    for index in range(10):
        actual.append(
            ObservedValue(
                index,
                "actual-" + String(index),
                counters.actual_equality.copy(),
                counters.actual_render.copy(),
            )
        )
        expected.append(
            ObservedValue(
                index,
                "expected-" + String(index),
                counters.expected_equality.copy(),
                counters.expected_render.copy(),
            )
        )
    var detail = _list_failure(actual, expected)
    testing.assert_true(
        "list span at index 0: actual 1 item(s), expected 0 item(s)" in detail
    )
    testing.assert_equal(counters.read(0), 11)
    testing.assert_equal(counters.read(1), 0)


def test_expected_front_insertion_compares_each_receiver_once() raises:
    var counters = CounterOwner()
    var actual = List[ObservedValue]()
    var expected = List[ObservedValue]()
    expected.append(
        ObservedValue(
            -1,
            "inserted",
            counters.expected_equality.copy(),
            counters.expected_render.copy(),
        )
    )
    for index in range(10):
        actual.append(
            ObservedValue(
                index,
                "actual-" + String(index),
                counters.actual_equality.copy(),
                counters.actual_render.copy(),
            )
        )
        expected.append(
            ObservedValue(
                index,
                "expected-" + String(index),
                counters.expected_equality.copy(),
                counters.expected_render.copy(),
            )
        )
    var detail = _list_failure(actual, expected)
    testing.assert_true(
        "list span at index 0: actual 0 item(s), expected 1 item(s)" in detail
    )
    testing.assert_equal(counters.read(0), 1)
    testing.assert_equal(counters.read(1), 10)


def test_dictionary_categories_are_distinct_and_ordered() raises:
    var actual = {"unexpected": 1, "changed": 1}
    var expected = {"missing": 1, "changed": 2}
    var detail = _dictionary_failure(actual, expected)
    testing.assert_true("missing: 1 total, 0 omitted by entry limit" in detail)
    testing.assert_true(
        "unexpected: 1 total, 0 omitted by entry limit" in detail
    )
    testing.assert_true("changed: 1 total, 0 omitted by entry limit" in detail)
    testing.assert_true(detail.find("missing:") < detail.find("unexpected:"))
    testing.assert_true(detail.find("unexpected:") < detail.find("changed:"))
    var blank_keys = _dictionary_failure(
        {"": 1, "   ": 1},
        {"\t": 1},
    )
    testing.assert_true('missing keys:\n    "\\t"' in blank_keys)
    testing.assert_true('unexpected keys:\n    ""\n    "   "' in blank_keys)


def test_dictionary_order_is_full_unsigned_utf8_not_insertion_order() raises:
    var actual_a = Dict[String, Int]()
    var actual_b = Dict[String, Int]()
    var expected = Dict[String, Int]()
    for key in ["é", "z", "a\nkey", "a\u202ekey"]:
        _put(actual_a, key, 1)
    for key in ["a\u202ekey", "a\nkey", "z", "é"]:
        _put(actual_b, key, 1)
    var first = _dictionary_failure(actual_a, expected)
    var second = _dictionary_failure(actual_b, expected)
    testing.assert_equal(first, second)
    testing.assert_true(first.find("a\\nkey") < first.find("a\\u202ekey"))
    testing.assert_true(first.find('\n    "z"') < first.find('\n    "é"'))
    testing.assert_false("\na\nkey" in first)


def test_dictionary_displays_eight_per_category_with_totals_first() raises:
    var actual = Dict[String, Int]()
    var expected = Dict[String, Int]()
    for index in range(12):
        _put(actual, "u" + String(index + 100), index)
        _put(expected, "m" + String(index + 100), index)
        _put(actual, "c" + String(index + 100), index)
        _put(expected, "c" + String(index + 100), index + 1)
    var detail = _dictionary_failure(actual, expected)
    testing.assert_true("missing: 12 total, 4 omitted by entry limit" in detail)
    testing.assert_true(
        "unexpected: 12 total, 4 omitted by entry limit" in detail
    )
    testing.assert_true("changed: 12 total, 4 omitted by entry limit" in detail)
    testing.assert_true(
        detail.find("changed: 12") < detail.find("\n  missing keys:")
    )


def test_dictionary_values_are_individually_bounded_before_assembly() raises:
    var actual = {
        "first": _repeated("a", 32 * 1024),
        "second": "tail-actual",
    }
    var expected = {
        "first": _repeated("b", 32 * 1024),
        "second": "tail-expected",
    }
    var detail = _dictionary_failure(actual, expected, "dictionary reason")
    testing.assert_true('... [truncated]" != "' in detail)
    testing.assert_true('"second": "tail-actual" != "tail-expected"' in detail)
    testing.assert_true(detail.endswith("dictionary reason"))
    var delimiter_detail = _dictionary_failure(
        {"key": "x != y"},
        {"key": "z"},
    )
    testing.assert_true('"key": "x != y" != "z"' in delimiter_detail)
    var shared = _repeated("s", 2000)
    var identical_projections = _dictionary_failure(
        {"key": shared + "-actual"},
        {"key": shared + "-expected"},
    )
    testing.assert_true(
        "displayed projections are identical after truncation"
        in identical_projections
    )
    testing.assert_false('" != "' in identical_projections)
    var capped_actual = Dict[String, String]()
    var capped_expected = Dict[String, String]()
    for index in range(8):
        capped_actual["key-" + String(index)] = _repeated("a", 32 * 1024)
        capped_expected["key-" + String(index)] = _repeated("b", 32 * 1024)
    var capped = _dictionary_failure(capped_actual, capped_expected)
    testing.assert_true("changed: 8 total, 0 omitted by entry limit" in capped)
    testing.assert_true(capped.endswith("... [truncated]"))
    testing.assert_equal(_count_scalar(capped, ord('"')) % 2, 0)


def test_dictionary_key_cap_boundary_and_omission() raises:
    var boundary = _repeated("q", 1024)
    var within = Dict[String, Int]()
    var empty = Dict[String, Int]()
    _put(within, boundary, 1)
    var structural = _dictionary_failure(within, empty)
    testing.assert_true("unexpected: 1 total" in structural)

    var over = Dict[String, Int]()
    _put(over, boundary + "z", 1)
    var omitted = _dictionary_failure(over, empty)
    testing.assert_true("unexpected: 1 total" in omitted)
    testing.assert_true(
        "omitted by key display limit: missing 0, unexpected 1, changed 0"
        in omitted
    )
    testing.assert_false(boundary in omitted)
    var escaped = _repeated("\U000E0041", 103)
    var colliding = Dict[String, Int]()
    _put(colliding, escaped + "AAA", 1)
    _put(colliding, escaped + "BBB", 1)
    var escaped_omitted = _dictionary_failure(colliding, empty)
    testing.assert_true(
        "omitted by key display limit: missing 0, unexpected 2, changed 0"
        in escaped_omitted
    )
    testing.assert_false("\\U000e0041" in escaped_omitted)


def test_equal_oversized_dictionary_key_does_not_hide_short_change() raises:
    var oversized = _repeated("k", 1025)
    var actual = Dict[String, Int]()
    var expected = Dict[String, Int]()
    _put(actual, oversized, 1)
    _put(expected, oversized, 1)
    _put(actual, "changed", 2)
    _put(expected, "changed", 3)

    var detail = _dictionary_failure(actual, expected)
    testing.assert_true('"changed": "2" != "3"' in detail)
    testing.assert_false("structural key display exceeds" in detail)


def test_undisplayed_oversized_dictionary_key_keeps_short_details() raises:
    var oversized = "z-" + _repeated("k", 1025)
    var actual = Dict[String, Int]()
    var expected = Dict[String, Int]()
    for index in range(12):
        _put(expected, "missing-" + String(index + 100), index)
    _put(expected, oversized, 1)
    _put(actual, "changed", 2)
    _put(expected, "changed", 3)

    var detail = _dictionary_failure(actual, expected)
    testing.assert_true("missing: 13 total" in detail)
    testing.assert_true('"changed": "2" != "3"' in detail)
    testing.assert_true(
        "omitted by key display limit: missing 1, unexpected 0, changed 0"
        in detail
    )


def test_oversized_dictionary_key_omission_is_truthful() raises:
    var key = _repeated("k", 1025)
    var actual = Dict[String, Int]()
    var expected = Dict[String, Int]()
    _put(actual, key, 1)
    _put(expected, key, 2)
    var detail = _dictionary_failure(actual, expected)
    testing.assert_false("compare unequal but render identically" in detail)
    testing.assert_true("changed: 1 total" in detail)
    testing.assert_true(
        "omitted by key display limit: missing 0, unexpected 0, changed 1"
        in detail
    )


def test_dictionary_key_omission_is_insertion_order_independent() raises:
    var key = _repeated("k", 1025)
    var actual_a = Dict[String, Int]()
    var actual_b = Dict[String, Int]()
    var expected = Dict[String, Int]()
    _put(actual_a, key, 1)
    _put(actual_a, "short", 2)
    _put(actual_b, "short", 2)
    _put(actual_b, key, 1)
    _put(expected, key, 3)
    _put(expected, "short", 4)
    testing.assert_equal(
        _dictionary_failure(actual_a, expected),
        _dictionary_failure(actual_b, expected),
    )


def test_equal_dictionary_with_oversized_key_returns_without_rendering() raises:
    var key = _repeated("k", 1025)
    var counters = CounterOwner()
    var actual = Dict[String, ObservedValue]()
    var expected = Dict[String, ObservedValue]()
    expected[key] = ObservedValue(
        7,
        "expected",
        counters.expected_equality.copy(),
        counters.expected_render.copy(),
    )
    actual[key] = ObservedValue(
        7,
        "actual",
        counters.actual_equality.copy(),
        counters.actual_render.copy(),
    )
    assert_equal(actual, expected)
    testing.assert_equal(counters.read(0), 1)
    testing.assert_equal(counters.read(1), 0)
    testing.assert_equal(counters.read(2), 0)
    testing.assert_equal(counters.read(3), 0)


def test_dictionary_specializer_renders_only_eight_changed_values() raises:
    var counters = CounterOwner()
    var actual = Dict[String, ObservedValue]()
    var expected = Dict[String, ObservedValue]()
    for index in range(12):
        var key = "key-" + String(index + 100)
        actual[key] = ObservedValue(
            index,
            "actual-" + String(index),
            counters.actual_equality.copy(),
            counters.actual_render.copy(),
        )
        expected[key] = ObservedValue(
            100 + index,
            "expected-" + String(index),
            counters.expected_equality.copy(),
            counters.expected_render.copy(),
        )
    try:
        assert_equal(actual, expected)
    except:
        pass
    testing.assert_equal(counters.read(0), 12)
    testing.assert_equal(counters.read(1), 0)
    testing.assert_equal(counters.read(2), 8)
    testing.assert_equal(counters.read(3), 8)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
