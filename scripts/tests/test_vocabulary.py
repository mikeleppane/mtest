#!/usr/bin/env python3
"""The harness side of the report-vocabulary reconciliation.

`scripts/formats/vocabulary.txt` is the one machine-readable copy of the
outcome, exit-code and event vocabulary. `tests/unit/test_vocabulary_snapshot`
proves it equals what the runner's own tables produce; this module proves the
harness copies agree with it.

Two kinds of consumer are reconciled differently.

Sharers import from `scripts.formats.vocabulary`, so nothing here can drift.
What is checked instead is that the import actually reached the gate: that
`package_consumption.VERDICT_ROW_RE` sees exactly the spellings the vocabulary
carries for its file-row outcomes, and that `contract.py`'s check matrix uses
the exit-code constants rather than bare integers.

Independent oracles keep their own literals on purpose. `selfhost.py` and
`e2e/assertions.py` each read a real run's output in their own grammar, and
`json_stream.py` is the strict `--json` consumer; deriving any of them from the
same source the runner is checked against would make them agree by
construction, which is the opposite of what a second reader is for. Their
literals are harvested here and compared against the vocabulary, so drift is a
loud failure with both sides named.
"""

from __future__ import annotations

import ast
from pathlib import Path
import re
import tempfile
import unittest

from scripts.build import package_consumption
from scripts.e2e import assertions as e2e_assertions
from scripts.formats import json_stream
from scripts.formats.vocabulary import (
    CODE_BY_LABEL,
    CONSOLE_TOKENS,
    EXIT_CODES,
    JSON_TOKENS,
    MODEL_EVENT_KINDS,
    REPORT_LABELS,
    STREAM_VERSION,
    VOCABULARY_PATH,
    WIRE_EVENT_KINDS,
    VocabularyError,
    parse,
)
from scripts.harness import dogfood, selfhost
from scripts.tests import test_package_consumption, test_selfhost


REPO_ROOT = Path(__file__).resolve().parents[2]

NO_TESTS = "NO-TESTS"
"""The console's substitution for PASS on a file that collected nothing.

A console substitution, not an outcome, so it is absent from the vocabulary and
every file-row token set carries it beside the outcome tokens.
"""


def alternation_tokens(pattern: str, group: str) -> tuple[str, ...]:
    """The alternatives of one named group in a regex source.

    Args:
        pattern: A compiled pattern's source text.
        group: The named group whose alternation to read.

    Returns:
        The alternatives in source order, unescaped.

    Raises:
        AssertionError: `pattern` carries no such group, or the group is not a
            plain alternation of literals.
    """
    match = re.search(rf"\(\?P<{group}>([^)]*)\)", pattern)
    if match is None:
        raise AssertionError(f"no group {group!r} in {pattern!r}")
    tokens = tuple(
        re.sub(r"\\(.)", r"\1", alternative)
        for alternative in match.group(1).split("|")
    )
    for token in tokens:
        if not re.fullmatch(r"[A-Za-z][A-Za-z-]*", token):
            raise AssertionError(
                f"{group!r} carries a non-literal alternative: {token}"
            )
    return tokens


class VocabularyFileTests(unittest.TestCase):
    """The artifact itself: it is committed, and the parser refuses damage."""

    def test_the_vocabulary_is_committed_where_both_sides_look(self) -> None:
        self.assertEqual(VOCABULARY_PATH, REPO_ROOT / "scripts/formats/vocabulary.txt")
        self.assertTrue(VOCABULARY_PATH.is_file(), VOCABULARY_PATH)

    def test_every_section_parsed(self) -> None:
        self.assertEqual(sorted(CONSOLE_TOKENS), list(range(len(CONSOLE_TOKENS))))
        self.assertEqual(sorted(REPORT_LABELS), sorted(CONSOLE_TOKENS))
        self.assertEqual(sorted(JSON_TOKENS), sorted(CONSOLE_TOKENS))
        self.assertEqual(len(CODE_BY_LABEL), len(REPORT_LABELS))
        self.assertEqual(
            set(WIRE_EVENT_KINDS),
            {kind.lower() for kind in MODEL_EVENT_KINDS} - {"progress"},
        )

    def test_the_three_surfaces_are_kept_apart(self) -> None:
        # A row whose surfaces had collapsed into one spelling would let a
        # harness assert the console's bytes against the wire's.
        code = CODE_BY_LABEL["COMPILE_ERROR"]
        self.assertEqual(CONSOLE_TOKENS[code], "COMPILE-ERROR")
        self.assertEqual(REPORT_LABELS[code], "COMPILE_ERROR")
        self.assertEqual(JSON_TOKENS[code], "compile_error")

    def test_a_damaged_file_is_refused_rather_than_half_read(self) -> None:
        good = VOCABULARY_PATH.read_text(encoding="utf-8")
        damage = {
            "a short outcome row": "outcome 0 PASS PASS\n",
            "a repeated outcome code": "outcome 0 PASS PASS pass\n",
            "a second stream version": "stream_version 2\n",
            "an unknown section": "verdict 0 PASS\n",
            "a non-integer exit code": "exit LATER late\n",
        }
        for label, extra in damage.items():
            with self.subTest(damage=label):
                scratch = Path(self.enterContext(tempfile.TemporaryDirectory()))
                target = scratch / "vocabulary.txt"
                target.write_text(good + extra, encoding="utf-8")
                with self.assertRaises(VocabularyError):
                    parse(target)

    def test_a_missing_file_fails_loudly(self) -> None:
        with self.assertRaises(VocabularyError):
            parse(REPO_ROOT / "scripts/formats/no-such-vocabulary.txt")


class SharerTests(unittest.TestCase):
    """Consumers that import the vocabulary, checked at the point of use."""

    def test_the_packaged_row_regex_sees_exactly_the_shared_spellings(self) -> None:
        # Compared against the written-out list, not against the comprehension
        # that produces VERDICT_ROW_TOKENS: re-deriving it here would assert
        # the same expression against itself and could never fail.
        expected = test_package_consumption.FILE_ROW_TOKENS
        self.assertEqual(package_consumption.VERDICT_ROW_TOKENS, expected)
        for token in expected:
            with self.subTest(token=token):
                match = package_consumption.VERDICT_ROW_RE.search(
                    f"{token} e2e/cases/example.mojo"
                )
                self.assertIsNotNone(match, f"VERDICT_ROW_RE is blind to {token}")

    def test_the_packaged_row_regex_stays_narrow(self) -> None:
        # SKIP and DESELECTED are per-test outcomes and EXCLUDED and NOT-RUN
        # get their own accounting rows, so none of them starts a verdict row.
        for label in ("SKIP", "DESELECTED", "EXCLUDED", "NOT_RUN"):
            token = CONSOLE_TOKENS[CODE_BY_LABEL[label]]
            with self.subTest(token=token):
                self.assertNotIn(token, package_consumption.VERDICT_ROW_TOKENS)
                self.assertIsNone(
                    package_consumption.VERDICT_ROW_RE.search(
                        f"{token} e2e/cases/example.mojo"
                    )
                )

    def test_the_contract_matrix_names_its_exit_codes(self) -> None:
        source = (REPO_ROOT / "scripts/qa/contract.py").read_text(encoding="utf-8")
        bare: list[int] = []
        for node in ast.walk(ast.parse(source)):
            if not isinstance(node, ast.Call):
                continue
            if not isinstance(node.func, ast.Name) or node.func.id != "Check":
                continue
            self.assertGreaterEqual(len(node.args), 4, ast.dump(node)[:120])
            code = node.args[3]
            if isinstance(code, ast.Constant):
                bare.append(node.lineno)
        self.assertEqual(
            bare,
            [],
            f"Check rows spelling their exit code as a bare integer: {bare}",
        )


class IndependentOracleTests(unittest.TestCase):
    """Oracles that keep their own literals, reconciled against the artifact."""

    def test_the_selfhost_row_regex_matches_the_packaged_one(self) -> None:
        harvested = alternation_tokens(selfhost.VERDICT_ROW_RE.pattern, "verdict")
        self.assertEqual(harvested, package_consumption.VERDICT_ROW_TOKENS)

    def test_every_harvested_file_row_token_is_a_console_token(self) -> None:
        console = set(CONSOLE_TOKENS.values())
        harvested = {
            "selfhost.VERDICT_ROW_RE": alternation_tokens(
                selfhost.VERDICT_ROW_RE.pattern, "verdict"
            ),
            "package_consumption.VERDICT_ROW_RE": alternation_tokens(
                package_consumption.VERDICT_ROW_RE.pattern, "token"
            ),
            "test_selfhost.FILE_ROW_TOKENS": test_selfhost.FILE_ROW_TOKENS,
            "test_package_consumption.FILE_ROW_TOKENS": (
                test_package_consumption.FILE_ROW_TOKENS
            ),
        }
        for source, tokens in harvested.items():
            with self.subTest(source=source):
                self.assertEqual(
                    set(tokens) - {NO_TESTS} - console,
                    set(),
                    f"{source} carries a token no console outcome spells",
                )
                self.assertIn(NO_TESTS, tokens)

    def test_the_two_written_out_token_lists_agree(self) -> None:
        self.assertEqual(
            test_selfhost.FILE_ROW_TOKENS,
            test_package_consumption.FILE_ROW_TOKENS,
        )

    def test_the_e2e_verdict_tokens_are_console_tokens(self) -> None:
        console = set(CONSOLE_TOKENS.values())
        self.assertEqual(set(e2e_assertions.VERDICT_TO_BUCKET) - console, set())
        self.assertEqual(
            set(e2e_assertions.VERDICT_LINE_TOKENS) - {NO_TESTS} - console, set()
        )

    def test_the_dogfood_row_regex_anchors_on_the_pass_token(self) -> None:
        pattern = dogfood.PASS_ROW_RE.pattern
        self.assertTrue(
            pattern.startswith(f"^{CONSOLE_TOKENS[CODE_BY_LABEL['PASS']]}"), pattern
        )

    def test_the_strict_consumer_pins_the_same_stream_version(self) -> None:
        self.assertEqual(json_stream.STREAM_VERSION, STREAM_VERSION)

    def test_the_exit_codes_the_harness_names_are_the_published_ones(self) -> None:
        self.assertEqual(
            EXIT_CODES,
            {
                "SUCCESS": 0,
                "FAILURE": 1,
                "INTERRUPTED": 2,
                "INTERNAL_ERROR": 3,
                "USAGE_ERROR": 4,
                "NOTHING_RAN": 5,
            },
        )


if __name__ == "__main__":
    unittest.main()
