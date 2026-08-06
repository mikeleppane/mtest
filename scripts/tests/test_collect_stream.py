#!/usr/bin/env python3
"""Tests for the strict collect-stream consumer.

`scripts/formats/collect_stream.py` is the oracle the contract gate and
the end-to-end gate read `mtest collect --format json` through, so its own
rejections need proving: an oracle that quietly accepts a broken stream turns
every check built on it green. Each test here breaks exactly one property, or
pins exactly one tolerance the versioning contract requires.
"""

from __future__ import annotations

import re
import unittest

from scripts.formats import collect_stream as oracle


HEADER = '{"event":"collect","version":1,"generator":"mtest x.y.z"}'
NODE_A = (
    '{"event":"node","node_id":"tests/test_a.mojo::test_one",'
    '"path":"tests/test_a.mojo","name":"test_one"}'
)
NODE_B = (
    '{"event":"node","node_id":"tests/test_b.mojo::test_two",'
    '"path":"tests/test_b.mojo","name":"test_two"}'
)


def terminal(nodes: int = 0, exit_code: int = 0) -> str:
    """One terminal record. `nodes` must match the stream it closes."""
    return f'{{"event":"collect_finished","nodes":{nodes},"exit_code":{exit_code}}}'


TERMINAL = terminal()
"""The terminal for a stream carrying no nodes, which most cases here are."""


def stream(*lines: str, torn: str = "") -> str:
    """One stream from its committed lines, plus an optional torn fragment."""
    return "".join(line + "\n" for line in lines) + torn


class FramingTests(unittest.TestCase):
    """What the consumer accepts as a well-formed stream."""

    def test_a_complete_stream_reads_its_nodes_terminal_and_version(self) -> None:
        report = oracle.parse_collect_stream(
            stream(HEADER, NODE_A, NODE_B, terminal(2))
        )
        self.assertEqual(report.version, oracle.COLLECT_STREAM_VERSION)
        self.assertEqual(
            report.node_ids,
            ["tests/test_a.mojo::test_one", "tests/test_b.mojo::test_two"],
        )
        self.assertEqual(report.exit_code, 0)
        self.assertFalse(report.torn_tail)

    def test_an_empty_stream_without_a_required_header_raises(self) -> None:
        with self.assertRaisesRegex(oracle.CollectStreamError, "empty stream"):
            oracle.parse_collect_stream("")

    def test_an_empty_stream_is_allowed_when_no_header_is_required(self) -> None:
        report = oracle.parse_collect_stream("", require_header=False)
        self.assertEqual(report.records, [])
        self.assertIsNone(report.terminal)

    def test_a_blank_committed_line_is_corruption(self) -> None:
        with self.assertRaisesRegex(oracle.CollectStreamError, "blank committed line"):
            oracle.parse_collect_stream(stream(HEADER, "", TERMINAL))

    def test_a_committed_line_that_does_not_parse_raises(self) -> None:
        with self.assertRaisesRegex(oracle.CollectStreamError, "does not parse"):
            oracle.parse_collect_stream(stream(HEADER, "{not json}", TERMINAL))

    def test_a_committed_line_that_is_not_an_object_raises(self) -> None:
        with self.assertRaisesRegex(oracle.CollectStreamError, "not a JSON object"):
            oracle.parse_collect_stream(stream(HEADER, "[1,2,3]", TERMINAL))


class HeaderTests(unittest.TestCase):
    """Line one, and the single integer that versions the format."""

    def test_a_missing_header_raises(self) -> None:
        with self.assertRaisesRegex(oracle.CollectStreamError, "not the collect"):
            oracle.parse_collect_stream(stream(NODE_A, TERMINAL))

    def test_a_non_integer_version_raises(self) -> None:
        bad = '{"event":"collect","version":"1","generator":"mtest x.y.z"}'
        with self.assertRaisesRegex(oracle.CollectStreamError, "not an integer"):
            oracle.parse_collect_stream(stream(bad, TERMINAL))

    def test_an_unknown_version_raises(self) -> None:
        bad = '{"event":"collect","version":2,"generator":"mtest x.y.z"}'
        with self.assertRaisesRegex(oracle.CollectStreamError, "unknown collect"):
            oracle.parse_collect_stream(stream(bad, TERMINAL))

    def test_the_generator_string_is_never_pinned(self) -> None:
        # The consumer must read any generator label, or it would break on
        # every release. This is what keeps the fixtures version-neutral.
        for label in ("mtest x.y.z", "mtest a.b.c-rc1", "", "something else"):
            head = f'{{"event":"collect","version":1,"generator":"{label}"}}'
            report = oracle.parse_collect_stream(stream(head, TERMINAL))
            self.assertEqual(report.version, 1)


class StrictnessTests(unittest.TestCase):
    """The two things the format forbids, and the unique terminal."""

    def test_a_duplicate_key_anywhere_is_corruption(self) -> None:
        with self.assertRaisesRegex(oracle.CollectStreamError, "duplicate key"):
            oracle.parse_collect_stream('{"event":"collect","version":1,"version":2}\n')

    def test_a_non_finite_token_is_corruption(self) -> None:
        # The stream carries no floating-point value at all, so a NaN is a
        # forgery rather than a number.
        with self.assertRaisesRegex(oracle.CollectStreamError, "non-finite"):
            oracle.parse_collect_stream(
                stream(HEADER, '{"event":"node","node_id":NaN}')
            )

    def test_two_terminals_are_refused(self) -> None:
        with self.assertRaisesRegex(oracle.CollectStreamError, "more than one"):
            oracle.parse_collect_stream(stream(HEADER, TERMINAL, TERMINAL))

    def test_a_terminal_that_is_not_last_is_refused(self) -> None:
        with self.assertRaisesRegex(oracle.CollectStreamError, "not the last"):
            oracle.parse_collect_stream(stream(HEADER, terminal(1), NODE_A))

    def test_a_repeated_header_is_refused(self) -> None:
        # Two headers mean two streams spliced together, or a producer that
        # restarted mid-listing. Either way the records below the second one
        # are not what the first header described.
        with self.assertRaisesRegex(oracle.CollectStreamError, "more than one"):
            oracle.parse_collect_stream(stream(HEADER, NODE_A, HEADER, TERMINAL))

    def test_a_header_that_is_not_first_is_refused(self) -> None:
        with self.assertRaisesRegex(oracle.CollectStreamError, "not the first"):
            oracle.parse_collect_stream(
                stream(NODE_A, HEADER, terminal(1)), require_header=False
            )


class KnownRecordSchemaTests(unittest.TestCase):
    """The frozen fields of the frozen kinds, enforced.

    Without these the oracle cannot tell a correct producer from a miswired
    one: an inconsistent `node` triple satisfies every count and ordering
    assertion a check built on this module can make.
    """

    def _reject(self, record: str, pattern: str) -> None:
        with self.assertRaisesRegex(oracle.CollectStreamError, pattern):
            oracle.parse_collect_stream(stream(HEADER, record))

    def test_a_node_missing_a_required_field_is_refused(self) -> None:
        self._reject('{"event":"node","node_id":"a::b","path":"a"}', "name")
        self._reject('{"event":"node","node_id":"a::b","name":"b"}', "path")
        self._reject('{"event":"node","path":"a","name":"b"}', "node_id")

    def test_a_node_field_of_the_wrong_type_is_refused(self) -> None:
        self._reject(
            '{"event":"node","node_id":7,"path":"a","name":"b"}', "not a string"
        )
        self._reject(
            '{"event":"node","node_id":"a::b","path":null,"name":"b"}',
            "not a string",
        )

    def test_an_inconsistent_node_triple_is_refused(self) -> None:
        # The exact shape a miswired producer emits: the id is right and the
        # decomposition is not. Counts and ordering cannot see this.
        self._reject(
            '{"event":"node","node_id":"a.mojo::test_a","path":"wrong.mojo",'
            '"name":"wrong"}',
            "does not decompose",
        )

    def test_a_node_split_at_the_wrong_separator_is_refused(self) -> None:
        # Splitting `we::ird/t.mojo::test_x` at the FIRST `::` produces exactly
        # this record, so the oracle rejects that defect by construction.
        self._reject(
            '{"event":"node","node_id":"we::ird/t.mojo::test_x","path":"we",'
            '"name":"ird/t.mojo::test_x"}',
            "does not decompose",
        )

    def test_a_node_whose_path_contains_the_separator_is_accepted(self) -> None:
        good = (
            '{"event":"node","node_id":"we::ird/t.mojo::test_x",'
            '"path":"we::ird/t.mojo","name":"test_x"}'
        )
        report = oracle.parse_collect_stream(stream(HEADER, good))
        self.assertEqual(report.node_ids, ["we::ird/t.mojo::test_x"])

    def test_a_terminal_missing_a_required_field_is_refused(self) -> None:
        self._reject('{"event":"collect_finished","nodes":0}', "exit_code")
        self._reject('{"event":"collect_finished","exit_code":0}', "nodes")

    def test_a_terminal_field_of_the_wrong_type_is_refused(self) -> None:
        self._reject(
            '{"event":"collect_finished","nodes":0,"exit_code":"0"}',
            "not an integer",
        )
        self._reject(
            '{"event":"collect_finished","nodes":true,"exit_code":0}',
            "not an integer",
        )

    def test_a_terminal_count_that_disagrees_with_the_nodes_is_refused(
        self,
    ) -> None:
        with self.assertRaisesRegex(oracle.CollectStreamError, "counts 5"):
            oracle.parse_collect_stream(
                stream(
                    HEADER,
                    NODE_A,
                    '{"event":"collect_finished","nodes":5,"exit_code":0}',
                )
            )

    def test_a_header_missing_its_generator_is_refused(self) -> None:
        with self.assertRaisesRegex(oracle.CollectStreamError, "generator"):
            oracle.parse_collect_stream(stream('{"event":"collect","version":1}'))

    def test_a_non_string_generator_is_refused(self) -> None:
        with self.assertRaisesRegex(oracle.CollectStreamError, "not a string"):
            oracle.parse_collect_stream(
                stream('{"event":"collect","version":1,"generator":7}')
            )


class TruncationTests(unittest.TestCase):
    """Absence of a terminal is the truncation signal, never an error."""

    def test_a_trailing_unterminated_fragment_is_a_torn_tail(self) -> None:
        report = oracle.parse_collect_stream(
            stream(HEADER, NODE_A, torn='{"event":"node","node_')
        )
        self.assertTrue(report.torn_tail)
        self.assertIsNone(report.terminal)
        self.assertIsNone(report.exit_code)

    def test_a_stream_that_stops_on_a_line_boundary_has_no_torn_fragment(
        self,
    ) -> None:
        # Still truncated — the terminal is missing — but the flag is about a
        # partial final LINE, and there is none.
        report = oracle.parse_collect_stream(stream(HEADER, NODE_A))
        self.assertFalse(report.torn_tail)
        self.assertIsNone(report.terminal)
        self.assertIsNone(report.exit_code)


class ForwardCompatibilityTests(unittest.TestCase):
    """The tolerance the versioning contract requires of every consumer."""

    def test_an_unknown_event_kind_is_accepted_and_kept(self) -> None:
        report = oracle.parse_collect_stream(
            stream(HEADER, '{"event":"quantum_flux","x":1}', TERMINAL)
        )
        self.assertTrue(any(r.get("event") == "quantum_flux" for r in report.records))

    def test_unknown_fields_on_known_records_are_accepted(self) -> None:
        node = '{"event":"node","node_id":"a::b","path":"a","name":"b","vnext":true}'
        report = oracle.parse_collect_stream(stream(HEADER, node, terminal(1)))
        self.assertEqual(report.node_ids, ["a::b"])


class FixtureSelfTestTests(unittest.TestCase):
    """The committed fixtures, and the self-test the module runs over them."""

    def test_the_selftest_passes_over_the_committed_fixtures(self) -> None:
        self.assertEqual(oracle.main(["collect_stream.py"]), 0)

    def test_the_fixtures_render_no_numeric_version_literal(self) -> None:
        # A numeric `mtest X.Y.Z` here would enlist the fixture in the release
        # version sweep, so a bump would rewrite test input. Asserted as the
        # ABSENCE of a numeric literal, not the presence of a neutral one: a
        # fixture carrying both would satisfy the weaker check.
        numeric = re.compile(r"mtest \d+\.\d+\.\d+")
        for name in ("forward_compat.ndjson", "corrupt_midline.ndjson"):
            text = (oracle.FIXTURE_DIR / name).read_text(encoding="utf-8")
            self.assertIsNone(
                numeric.search(text),
                f"{name} renders a numeric version literal",
            )


if __name__ == "__main__":
    unittest.main()
