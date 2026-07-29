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


def captured(*lines: str) -> str:
    """One captured-stdout blob from its lines, the way a real run emits it."""
    return "\n".join(lines)


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
        # line; without this the sort assertion below sorts an empty list.
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
        # The other half of the forgery defense. A raw LF never reaches the
        # escaping check, because the grammar refuses the line outright.
        self._reject(
            ["::error file=a.mojo::a.mojo\n::notice ::forged"], "not a valid annotation"
        )

    def test_an_unescaped_separator_in_a_property_value_is_rejected(self) -> None:
        # A raw `:` or `,` in a value splits the annotation differently than
        # mtest intended. `_ANNOTATION_RE`'s property group is `[^:]*`, so the
        # grammar rejects the line and the escaping check never sees it.
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
        # value, so the oracle must not flag them.
        counts = oracle.check_tail(["::error file=a%0Ab.mojo::a.mojo::test_one: ok"])
        self.assertEqual(counts["errors"], 1)

    def test_more_than_one_notice_is_rejected(self) -> None:
        self._reject(["::notice ::first", "::notice ::second"], "more than one")

    def test_a_raw_carriage_return_in_a_property_is_rejected(self) -> None:
        # The message check alone left this open: `.` in the grammar matches CR,
        # so a property carrying one parses and used to pass. A property segment
        # is just as good a place to forge a second command line from.
        self._reject(
            ["::error file=a.mojo\rline=9::a.mojo::test_one: failed"],
            "property segment carries a raw CR/LF",
        )


class AnnotationExtractionTests(unittest.TestCase):
    """What reaches `check_tail` from a real captured stdout.

    Extraction used to skip any annotation-shaped line the grammar refused, which
    made the whole oracle false-green: the malformed line vanished and the tail
    then reconciled to zero errors. These pin the extraction boundary itself.
    """

    def test_a_malformed_annotation_reaches_the_tail_check(self) -> None:
        # `tests/a:b.mojo` is a legal POSIX path. Emitted unescaped, the `:`
        # makes the line unparseable; dropping it silently reported no errors.
        text = captured(
            "console output above",
            "::error file=tests/a:b.mojo::tests/a:b.mojo::test_one: failed",
            "::notice ::mtest: 1 error",
        )
        kept = oracle.annotation_tail_outside_fences(text)
        self.assertIn(
            "::error file=tests/a:b.mojo::tests/a:b.mojo::test_one: failed", kept
        )
        with self.assertRaisesRegex(
            oracle.AnnotationsCheckError, "not a valid annotation"
        ):
            oracle.check_tail(kept)

    def test_a_well_formed_tail_extracts_and_passes(self) -> None:
        text = captured(
            "console output above",
            ROW_A,
            ROW_B,
            "::notice ::mtest: 2 errors",
        )
        kept = oracle.annotation_tail_outside_fences(text)
        self.assertEqual(kept, [ROW_A, ROW_B, "::notice ::mtest: 2 errors"])
        self.assertEqual(oracle.check_tail(kept)["errors"], 2)

    def test_an_annotation_echoed_inside_a_fence_stays_inert(self) -> None:
        # The fence exclusion must survive the extraction change: a child echoing
        # `::error` inside a stop-commands fence is text, not mtest's own tail.
        token = "abcdef0123456789abcdef0123456789"  # noqa: S105 - a fence token
        text = captured(
            f"::stop-commands::{token}",
            "::error file=child.mojo::echoed by the child",
            f"::{token}::",
            "::notice ::mtest: 0 errors",
        )
        kept = oracle.annotation_tail_outside_fences(text)
        self.assertEqual(kept, ["::notice ::mtest: 0 errors"])
        self.assertEqual(oracle.check_tail(kept)["errors"], 0)

    def test_a_malformed_annotation_inside_a_fence_also_stays_inert(self) -> None:
        # The looser opener match must not resurrect fenced child output.
        token = "abcdef0123456789abcdef0123456789"  # noqa: S105 - a fence token
        text = captured(
            f"::stop-commands::{token}",
            "::error file=child:bad.mojo::echoed, unparseable, still inert",
            f"::{token}::",
            "::notice ::mtest: 0 errors",
        )
        kept = oracle.annotation_tail_outside_fences(text)
        self.assertEqual(kept, ["::notice ::mtest: 0 errors"])

    def test_ordinary_console_text_is_not_mistaken_for_an_annotation(self) -> None:
        # The opener pattern must stay narrow: only our three kinds, and only
        # when the line really opens with one.
        text = captured(
            "PASS tests/a.mojo",
            "  note: ::error appears mid-line and is not an annotation",
            "::errorish ::not one of our kinds",
            "::notice ::mtest: 0 errors",
        )
        self.assertEqual(
            oracle.annotation_tail_outside_fences(text),
            ["::notice ::mtest: 0 errors"],
        )


if __name__ == "__main__":
    unittest.main()
