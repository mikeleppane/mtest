"""Passing consumer coverage for the public assertion companion API."""

from std.memory import UnsafePointer, alloc, memset_zero
from std.reflection import source_location
import std.testing as testing
from std.testing import TestSuite

from mtest.assertions import assert_equal
from mtest.assertions._display import (
    BODY_BYTE_CAP,
    VALUE_BYTE_CAP,
    render_value,
)


def _counter() -> UnsafePointer[Int, MutUntrackedOrigin]:
    # SAFETY: this function returns one uniquely owned, correctly aligned Int
    # cell; memset initializes every byte before any test reads the counter.
    var pointer = alloc[Int](1)
    memset_zero(pointer.bitcast[UInt8](), 8)
    return pointer


@fieldwise_init
struct ObservedValue(Copyable, Equatable, Writable):
    """Value with caller-owned counters for equality and display operations."""

    var identity: Int
    var label: String
    var equality_calls: UnsafePointer[Int, MutUntrackedOrigin]
    var render_calls: UnsafePointer[Int, MutUntrackedOrigin]

    def __eq__(self, other: Self) -> Bool:
        self.equality_calls[0] += 1
        return self.identity == other.identity

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def write_to(self, mut writer: Some[Writer]):
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


def _repeated(piece: String, count: Int) -> String:
    var output = String("")
    for _ in range(count):
        output += piece
    return output^


def _text_failure(actual: String, expected: String, msg: String = "") -> String:
    var detail = String("")
    try:
        assert_equal(actual, expected, msg=msg)
    except error:
        detail = String(error)
    return detail^


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
    var actual_equality = _counter()
    var expected_equality = _counter()
    var actual_render = _counter()
    var expected_render = _counter()
    var actual = ObservedValue(7, "same", actual_equality, actual_render)
    var expected = ObservedValue(7, "same", expected_equality, expected_render)

    assert_equal(actual, expected)

    testing.assert_equal(actual_equality[0], 1)
    testing.assert_equal(expected_equality[0], 0)
    testing.assert_equal(actual_render[0], 0)
    testing.assert_equal(expected_render[0], 0)
    # SAFETY: these four allocations remain uniquely owned by this test and no
    # ObservedValue escapes; each allocation is freed exactly once after use.
    actual_equality.free()
    expected_equality.free()
    actual_render.free()
    expected_render.free()


def test_failure_compares_once_and_renders_each_operand_once() raises:
    var actual_equality = _counter()
    var expected_equality = _counter()
    var actual_render = _counter()
    var expected_render = _counter()
    var actual = ObservedValue(1, "actual", actual_equality, actual_render)
    var expected = ObservedValue(
        2, "expected", expected_equality, expected_render
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
    testing.assert_equal(actual_equality[0], 1)
    testing.assert_equal(expected_equality[0], 0)
    testing.assert_equal(actual_render[0], 1)
    testing.assert_equal(expected_render[0], 1)
    # SAFETY: these four allocations remain uniquely owned by this test and no
    # ObservedValue escapes; each allocation is freed exactly once after use.
    actual_equality.free()
    expected_equality.free()
    actual_render.free()
    expected_render.free()


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


def test_many_small_formatter_writes_and_body_are_bounded() raises:
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


def test_large_text_context_is_bounded_and_message_is_last() raises:
    var common = _repeated("a", 256 * 1024)
    var detail = _text_failure(common + "X", common + "Y", "final reason")
    testing.assert_true(detail.byte_length() <= 4096 + 256)
    testing.assert_true("text differs at scalar 262144" in detail)
    testing.assert_true(
        detail.endswith("... [truncated]") or detail.endswith("final reason")
    )


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
    testing.assert_true("list mismatches: 3 total, 0 omitted" in detail)
    testing.assert_true("[1] 8 != 1" in detail)
    testing.assert_true("[3] 7 != 3" in detail)
    testing.assert_true("[5] unexpected 6" in detail)


def test_list_displays_eight_mismatches_and_counts_omitted_first() raises:
    var actual = _ints(20)
    var expected = _ints(20)
    for index in range(0, 20, 2):
        actual[index] += 100
    var detail = _list_failure(actual, expected)
    testing.assert_true("list mismatches: 10 total, 2 omitted" in detail)
    testing.assert_true("[0] 100 != 0" in detail)
    testing.assert_true("[14] 114 != 14" in detail)
    testing.assert_false("[16]" in detail)


def test_nested_lists_are_opaque_and_user_message_is_last() raises:
    var detail = _list_failure([[1]], [[2]], "nested reason")
    testing.assert_true("list span at index 0" in detail)
    testing.assert_false("text differs" in detail)
    testing.assert_true(detail.endswith("nested reason"))


def test_list_specializer_renders_zero_on_pass_and_eight_on_failure() raises:
    var actual_equality = _counter()
    var expected_equality = _counter()
    var actual_render = _counter()
    var expected_render = _counter()
    var passing_actual = [
        ObservedValue(1, "same", actual_equality, actual_render)
    ]
    var passing_expected = [
        ObservedValue(1, "same", expected_equality, expected_render)
    ]
    assert_equal(passing_actual, passing_expected)
    testing.assert_equal(actual_render[0], 0)
    testing.assert_equal(expected_render[0], 0)

    var failing_actual = List[ObservedValue]()
    var failing_expected = List[ObservedValue]()
    for index in range(10):
        failing_actual.append(
            ObservedValue(
                100 + index,
                "actual-" + String(index),
                actual_equality,
                actual_render,
            )
        )
        failing_expected.append(
            ObservedValue(
                index,
                "expected-" + String(index),
                expected_equality,
                expected_render,
            )
        )
    try:
        assert_equal(failing_actual, failing_expected)
    except:
        pass
    testing.assert_equal(actual_render[0], 8)
    testing.assert_equal(expected_render[0], 8)
    # SAFETY: all probe values are dead before their four uniquely owned
    # counters are freed exactly once.
    actual_equality.free()
    expected_equality.free()
    actual_render.free()
    expected_render.free()


def test_dictionary_categories_are_distinct_and_ordered() raises:
    var actual = {"unexpected": 1, "changed": 1}
    var expected = {"missing": 1, "changed": 2}
    var detail = _dictionary_failure(actual, expected)
    testing.assert_true("missing: 1 total, 0 omitted" in detail)
    testing.assert_true("unexpected: 1 total, 0 omitted" in detail)
    testing.assert_true("changed: 1 total, 0 omitted" in detail)
    testing.assert_true(detail.find("missing:") < detail.find("unexpected:"))
    testing.assert_true(detail.find("unexpected:") < detail.find("changed:"))


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
    testing.assert_true(first.find("\n    z") < first.find("\n    é"))
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
    testing.assert_true("missing: 12 total, 4 omitted" in detail)
    testing.assert_true("unexpected: 12 total, 4 omitted" in detail)
    testing.assert_true("changed: 12 total, 4 omitted" in detail)
    testing.assert_true(
        detail.find("changed: 12") < detail.find("\n  missing keys:")
    )


def test_dictionary_key_cap_boundary_and_opaque_fallback() raises:
    var boundary = _repeated("q", 1024)
    var within = Dict[String, Int]()
    var empty = Dict[String, Int]()
    _put(within, boundary, 1)
    var structural = _dictionary_failure(within, empty)
    testing.assert_true("unexpected: 1 total" in structural)

    var over = Dict[String, Int]()
    _put(over, boundary + "z", 1)
    var opaque = _dictionary_failure(over, empty)
    testing.assert_true("structural key exceeds 1024 bytes" in opaque)
    testing.assert_false(boundary in opaque)


def test_equal_dictionary_with_oversized_key_returns_without_rendering() raises:
    var key = _repeated("k", 1025)
    var actual_equality = _counter()
    var expected_equality = _counter()
    var actual_render = _counter()
    var expected_render = _counter()
    var actual = Dict[String, ObservedValue]()
    var expected = Dict[String, ObservedValue]()
    actual[key] = ObservedValue(7, "actual", actual_equality, actual_render)
    expected[key] = ObservedValue(
        7, "expected", expected_equality, expected_render
    )
    assert_equal(actual, expected)
    testing.assert_equal(actual_render[0], 0)
    testing.assert_equal(expected_render[0], 0)
    # SAFETY: both dictionaries and their values are dead before the four
    # uniquely owned counters are freed exactly once.
    actual_equality.free()
    expected_equality.free()
    actual_render.free()
    expected_render.free()


def test_dictionary_specializer_renders_only_eight_changed_values() raises:
    var actual_equality = _counter()
    var expected_equality = _counter()
    var actual_render = _counter()
    var expected_render = _counter()
    var actual = Dict[String, ObservedValue]()
    var expected = Dict[String, ObservedValue]()
    for index in range(12):
        var key = "key-" + String(index + 100)
        actual[key] = ObservedValue(
            index,
            "actual-" + String(index),
            actual_equality,
            actual_render,
        )
        expected[key] = ObservedValue(
            100 + index,
            "expected-" + String(index),
            expected_equality,
            expected_render,
        )
    try:
        assert_equal(actual, expected)
    except:
        pass
    testing.assert_equal(actual_render[0], 8)
    testing.assert_equal(expected_render[0], 8)
    # SAFETY: both dictionaries and their values are dead before the four
    # uniquely owned counters are freed exactly once.
    actual_equality.free()
    expected_equality.free()
    actual_render.free()
    expected_render.free()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
