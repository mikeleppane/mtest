#!/usr/bin/env python3
"""Unit tests for the protocol-transcript comparator the canary classifies with.

The comparator forgives exactly one difference — the toolchain identity the
generator stamps into every header — so these tests are organised around the
boundary of that tolerance: one tree where only the identity moved (the single
case that may PASS), and trees where something else moved as well. The
raise-versus-classify split is tested just as hard: a baseline this repository
committed cannot be allowed to fail parsing quietly, because a corrupted
baseline that classified as drift would read as a healthy toolchain day.
"""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from scripts.canary.protocol_compare import (
    PASS,
    PROTOCOL_DRIFT,
    CompareResult,
    ToolchainIdentity,
    compare_transcript_dirs,
    parse_header_identity,
    side_identity,
    transcript_files,
)


REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES = REPO_ROOT / "scripts" / "fixtures" / "canary"
COMMITTED_SNAPSHOTS = REPO_ROOT / "tests" / "snapshots" / "protocol"

PINNED_IDENTITY = ToolchainIdentity("x.y.z", "deadbeef")
CANDIDATE_IDENTITY = ToolchainIdentity("x.y.w", "cafef00d")


def _tree(name: str, side: str) -> Path:
    return FIXTURES / name / side


class HeaderParsingTests(unittest.TestCase):
    """Line one of a transcript, read the way the generator writes it."""

    def test_the_fixture_roots_are_exact(self) -> None:
        self.assertEqual(FIXTURES, REPO_ROOT / "scripts/fixtures/canary")
        self.assertEqual(COMMITTED_SNAPSHOTS, REPO_ROOT / "tests/snapshots/protocol")

    def test_it_reads_the_version_and_commit(self) -> None:
        parsed = parse_header_identity(
            _tree("identical_newer", "pinned") / "passing--default.txt"
        )
        self.assertEqual(parsed, ToolchainIdentity("x.y.z", "deadbeef"))

    def test_it_reads_a_committed_transcript(self) -> None:
        parsed = parse_header_identity(COMMITTED_SNAPSHOTS / "crashing--default.txt")
        self.assertEqual(parsed, ToolchainIdentity("1.0.0b2", "2cf4d08a"))

    def test_it_rejects_a_header_without_a_commit(self) -> None:
        with self.assertRaises(ValueError) as raised:
            parse_header_identity(
                _tree("malformed_pinned_header", "pinned") / "skipped--default.txt"
            )
        self.assertIn("skipped--default.txt", str(raised.exception))

    def test_it_rejects_a_bare_filename_list(self) -> None:
        with self.assertRaises(ValueError):
            parse_header_identity(COMMITTED_SNAPSHOTS / "MANIFEST.txt")

    def test_it_rejects_an_empty_file(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-canary-header-") as raw:
            empty = Path(raw) / "empty--default.txt"
            empty.write_bytes(b"")
            with self.assertRaises(ValueError):
                parse_header_identity(empty)


class TranscriptEnumerationTests(unittest.TestCase):
    """Which files the identity walk is obliged to visit."""

    def test_it_lists_every_transcript_but_the_manifest(self) -> None:
        root = _tree("identical_newer", "pinned")
        self.assertEqual(
            transcript_files(root),
            [root / "passing--default.txt", root / "skipped--default.txt"],
        )

    def test_it_lists_the_committed_snapshots(self) -> None:
        names = [path.name for path in transcript_files(COMMITTED_SNAPSHOTS)]
        self.assertNotIn("MANIFEST.txt", names)
        self.assertEqual(len(names), 22)
        self.assertEqual(names, sorted(names))

    def test_a_manifest_only_tree_lists_nothing(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-canary-empty-") as raw:
            root = Path(raw)
            (root / "MANIFEST.txt").write_bytes(b"")
            self.assertEqual(transcript_files(root), [])

    def test_a_missing_root_lists_nothing(self) -> None:
        self.assertEqual(transcript_files(FIXTURES / "no-such-tree"), [])


class SideIdentityTests(unittest.TestCase):
    """One toolchain per side, proved over every file rather than sampled."""

    def test_it_returns_the_agreed_identity(self) -> None:
        self.assertEqual(
            side_identity(_tree("identical_newer", "pinned")), PINNED_IDENTITY
        )
        self.assertEqual(
            side_identity(_tree("identical_newer", "candidate")), CANDIDATE_IDENTITY
        )

    def test_it_reads_the_committed_snapshots(self) -> None:
        self.assertEqual(
            side_identity(COMMITTED_SNAPSHOTS), ToolchainIdentity("1.0.0b2", "2cf4d08a")
        )

    def test_it_rejects_disagreeing_transcripts(self) -> None:
        with self.assertRaises(ValueError) as raised:
            side_identity(_tree("disagreeing_pinned", "pinned"))
        message = str(raised.exception)
        self.assertIn("deadbeef", message)
        self.assertIn("feedface", message)

    def test_it_rejects_a_tree_with_no_transcripts(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-canary-empty-") as raw:
            root = Path(raw)
            (root / "MANIFEST.txt").write_bytes(b"")
            with self.assertRaises(ValueError):
                side_identity(root)

    def test_it_rejects_a_missing_tree(self) -> None:
        with self.assertRaises(ValueError):
            side_identity(FIXTURES / "no-such-tree")


class ComparisonTests(unittest.TestCase):
    """The classification boundary: only the toolchain identity may move."""

    def _compare(self, tree: str) -> CompareResult:
        return compare_transcript_dirs(_tree(tree, "pinned"), _tree(tree, "candidate"))

    def test_a_newer_toolchain_over_equal_bodies_passes(self) -> None:
        result = self._compare("identical_newer")
        self.assertEqual(result.classification, PASS)
        self.assertIn("x.y.z (deadbeef)", result.detail)
        self.assertIn("x.y.w (cafef00d)", result.detail)

    def test_the_real_snapshots_compare_clean_against_themselves(self) -> None:
        result = compare_transcript_dirs(COMMITTED_SNAPSHOTS, COMMITTED_SNAPSHOTS)
        self.assertEqual(result.classification, PASS, result.detail)

    def test_one_changed_body_byte_is_drift(self) -> None:
        result = self._compare("drifted_stdout")
        self.assertEqual(result.classification, PROTOCOL_DRIFT)
        self.assertIn("passing--default.txt", result.detail)
        self.assertIn("-1 passed in 0.00s", result.detail)
        self.assertIn("+1 failed in 0.00s", result.detail)

    def test_a_changed_os_arch_is_drift(self) -> None:
        result = self._compare("os_arch_differs")
        self.assertEqual(result.classification, PROTOCOL_DRIFT)
        self.assertIn("linux-aarch64", result.detail)

    def test_a_malformed_candidate_header_is_drift(self) -> None:
        result = self._compare("malformed_candidate_header")
        self.assertEqual(result.classification, PROTOCOL_DRIFT)
        self.assertIn("skipped--default.txt", result.detail)

    def test_a_missing_candidate_transcript_is_drift(self) -> None:
        result = self._compare("missing_transcript")
        self.assertEqual(result.classification, PROTOCOL_DRIFT)
        self.assertIn("missing snapshot files: ['skipped--default.txt']", result.detail)

    def test_an_extra_candidate_transcript_is_drift(self) -> None:
        result = compare_transcript_dirs(
            _tree("missing_transcript", "candidate"),
            _tree("missing_transcript", "pinned"),
        )
        self.assertEqual(result.classification, PROTOCOL_DRIFT)
        self.assertIn(
            "unexpected snapshot files: ['skipped--default.txt']", result.detail
        )

    def test_a_malformed_baseline_raises_instead_of_classifying(self) -> None:
        with self.assertRaises(ValueError):
            self._compare("malformed_pinned_header")

    def test_a_malformed_baseline_raises_even_when_both_sides_match(self) -> None:
        # Byte-identical on both sides, so the delegated byte comparison would
        # report nothing: only the all-file identity walk can catch this.
        with self.assertRaises(ValueError):
            self._compare("malformed_shared_baseline")

    def test_disagreeing_baseline_identities_raise(self) -> None:
        with self.assertRaises(ValueError):
            self._compare("disagreeing_pinned")

    def test_an_empty_baseline_raises_and_an_empty_candidate_drifts(self) -> None:
        # A side with nothing to compare must never be mistaken for agreement.
        with tempfile.TemporaryDirectory(prefix="mtest-canary-empty-") as raw:
            empty = Path(raw)
            (empty / "MANIFEST.txt").write_bytes(b"")
            with self.assertRaises(ValueError):
                compare_transcript_dirs(empty, _tree("identical_newer", "candidate"))
            result = compare_transcript_dirs(_tree("identical_newer", "pinned"), empty)
            self.assertEqual(result.classification, PROTOCOL_DRIFT)


if __name__ == "__main__":
    unittest.main()
