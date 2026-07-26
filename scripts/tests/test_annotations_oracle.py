#!/usr/bin/env python3
"""Mutation tests for the GitHub-annotation tail oracle.

`scripts/checks/reports/annotations.py` is what decides whether mtest's emitted
`::error`/`::warning`/`::notice` tail is well formed. It was reached only through
the e2e scenarios, so nothing proved its individual rules actually reject a
broken tail. Each test here breaks exactly one property and requires the oracle
to say so.
"""

from __future__ import annotations

import unittest

from scripts.checks.reports import annotations as oracle


ROW_A = "::error file=a.mojo::a.mojo::test_one: failed"
ROW_B = "::error file=b.mojo::b.mojo::test_two: failed"
AGGREGATE = "::error ::... and 3 more errors"
"""The rollup shape `src/mtest/report/annotations.mojo` renders after the cap."""


class AnnotationTailTests(unittest.TestCase):
    def _reject(self, lines: list[str], pattern: str) -> None:
        """Assert the oracle rejects one broken tail with a matching reason."""
        with self.assertRaisesRegex(oracle.AnnotationsCheckError, pattern):
            oracle.check_tail(lines)

    def test_a_well_formed_tail_is_accepted_and_counted(self) -> None:
        counts = oracle.check_tail([ROW_A, ROW_B, AGGREGATE])
        self.assertEqual(counts, {"errors": 3, "warnings": 0, "notices": 0})

    def test_an_aggregate_with_no_rows_to_roll_up_is_rejected(self) -> None:
        # A rollup counts the rows the cap dropped, so it cannot be the only
        # line. Without this the sort assertion below would sort an empty list
        # and pass, which is precisely how a broken cap would slip through.
        self._reject([AGGREGATE], "no rows to roll up")

    def test_an_unsorted_block_is_rejected(self) -> None:
        self._reject([ROW_B, ROW_A], "not node-id sorted")

    def test_an_aggregate_that_is_not_last_is_rejected(self) -> None:
        self._reject([AGGREGATE, ROW_A], "aggregate line is not last")

    def test_two_aggregates_in_one_block_are_rejected(self) -> None:
        self._reject([ROW_A, AGGREGATE, AGGREGATE], "more than one aggregate")

    def test_a_raw_carriage_return_in_a_message_is_rejected(self) -> None:
        # A raw CR/LF would forge a second workflow-command line, which is how a
        # test name could inject an annotation of its own. CR is the reachable
        # half: it survives the grammar, where a raw LF does not.
        self._reject(["::error ::a.mojo::test_one: before\rafter"], "raw CR/LF")

    def test_a_raw_newline_never_parses_as_one_annotation(self) -> None:
        # The other half of the forgery defense. A raw LF cannot reach the
        # escaping check because the grammar refuses the line outright, so this
        # pins the rejection where it actually happens.
        self._reject(
            ["::error file=a.mojo::a.mojo\n::notice ::forged"], "not a valid annotation"
        )

    def test_an_unescaped_separator_in_a_property_value_is_rejected(self) -> None:
        # `:` and `,` separate the property segment, so a value carrying either
        # raw would split the annotation differently than mtest intended. The
        # grammar is what enforces this: `_ANNOTATION_RE`'s property group is
        # `[^:]*`, so the line never parses. The escaping check for the same
        # property is unreachable defense in depth, which is why the rule is
        # pinned here at the level that actually rejects it.
        self._reject(
            ["::error file=a:b.mojo::a.mojo::test_one: failed"],
            "not a valid annotation",
        )

    def test_a_comma_in_a_property_segment_splits_into_pairs(self) -> None:
        # The companion fact: a `,` DOES survive the grammar, and is read as a
        # pair separator rather than as part of a value.
        parsed = oracle.parse_annotation("::error file=a.mojo,line=7::a.mojo: failed")
        if parsed is None:
            self.fail("a comma-separated property segment must still parse")
        self.assertEqual(parsed.props, "file=a.mojo,line=7")

    def test_percent_escaped_control_characters_are_accepted(self) -> None:
        # %0A and %0D are the CORRECT encoding for CR/LF inside a property
        # value, so the oracle must not flag them. This pins the reasoning that
        # replaced a branch which could never fail.
        counts = oracle.check_tail(["::error file=a%0Ab.mojo::a.mojo::test_one: ok"])
        self.assertEqual(counts["errors"], 1)

    def test_more_than_one_notice_is_rejected(self) -> None:
        self._reject(["::notice ::first", "::notice ::second"], "more than one")


if __name__ == "__main__":
    unittest.main()
