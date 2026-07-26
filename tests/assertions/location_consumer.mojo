"""Deliberately failing consumer that pins assertion caller coordinates."""

from std.reflection import source_location
from std.testing import TestSuite

from mtest.assertions import assert_equal


def test_generic_omitted_message() raises:
    assert_equal(1, 2)  # ASSERT-LOCATION: test_generic_omitted_message


def test_generic_positional_message() raises:
    assert_equal(
        2, 3, "positional"
    )  # ASSERT-LOCATION: test_generic_positional_message


def test_generic_keyword_message() raises:
    assert_equal(
        3, 4, msg="keyword"
    )  # ASSERT-LOCATION: test_generic_keyword_message


def test_string_location() raises:
    assert_equal("left", "right")  # ASSERT-LOCATION: test_string_location


def test_list_location() raises:
    assert_equal([1], [2])  # ASSERT-LOCATION: test_list_location


def test_dictionary_location() raises:
    assert_equal(
        {"key": 1}, {"key": 2}
    )  # ASSERT-LOCATION: test_dictionary_location


def test_generic_explicit_location() raises:
    var chosen = (
        source_location()
    )  # ASSERT-EXPLICIT-LOCATION: test_generic_explicit_location
    assert_equal(1, 2, location=chosen)


def test_string_explicit_location() raises:
    var chosen = (
        source_location()
    )  # ASSERT-EXPLICIT-LOCATION: test_string_explicit_location
    assert_equal("left", "right", location=chosen)


def test_list_explicit_location() raises:
    var chosen = (
        source_location()
    )  # ASSERT-EXPLICIT-LOCATION: test_list_explicit_location
    assert_equal([1], [2], location=chosen)


def test_dictionary_explicit_location() raises:
    var chosen = (
        source_location()
    )  # ASSERT-EXPLICIT-LOCATION: test_dictionary_explicit_location
    assert_equal({"key": 1}, {"key": 2}, location=chosen)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
