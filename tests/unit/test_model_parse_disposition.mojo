"""Tests for `ParseDisposition` (Layer 0): the closed report-parse vocabulary.

Five distinct values, closed like `Outcome`. These tests pin that every value
is distinct and that equality compares by code, so a later parser can branch on
disposition without risking two values silently comparing equal.
"""
from std.testing import assert_equal, assert_true, assert_false

from mtest.model import ParseDisposition


def _all_dispositions() -> List[ParseDisposition]:
    """Every value in the vocabulary, once each. Does not mutate or raise."""
    return [
        ParseDisposition.PARSED,
        ParseDisposition.NO_REPORT,
        ParseDisposition.AMBIGUOUS,
        ParseDisposition.DRIFT,
        ParseDisposition.CAPTURE_OVERFLOW,
    ]


def test_vocabulary_is_complete_and_distinct() raises:
    var all = _all_dispositions()
    assert_equal(len(all), ParseDisposition.COUNT)
    for i in range(len(all)):
        for j in range(len(all)):
            if i == j:
                assert_true(all[i] == all[j])
            else:
                assert_true(all[i] != all[j])


def test_eq_and_ne_compare_by_code() raises:
    assert_true(ParseDisposition.PARSED == ParseDisposition.PARSED)
    assert_false(ParseDisposition.PARSED == ParseDisposition.NO_REPORT)
    assert_true(ParseDisposition.PARSED != ParseDisposition.NO_REPORT)
