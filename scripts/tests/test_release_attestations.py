#!/usr/bin/env python3
"""Closed-schema tests for release candidate and publication attestations."""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path
import tempfile
import unittest

from scripts.release.attestations import (
    CandidateResult,
    ReleaseResult,
    candidate_bytes,
    load_candidate,
    load_release,
    release_bytes,
    validate_release_candidate,
    write_candidate,
    write_release,
)


COMMIT = "0123456789abcdef0123456789abcdef01234567"
UPSTREAM_COMMIT = "89abcdef0123456789abcdef0123456789abcdef"
DIGEST = "a" * 64


def candidate(**changes: object) -> CandidateResult:
    base = CandidateResult(
        schema=1,
        mode="dry-run",
        version="1.0.0",
        commit=COMMIT,
        build_number=0,
        upstream_commit=UPSTREAM_COMMIT,
        directory_digest=DIGEST,
        rattler_build_version="0.30.0",
        linux_validated=True,
        macos_validated=True,
        linux_aarch64_skipped=True,
    )
    return replace(base, **changes)  # type: ignore[arg-type]


def release(**changes: object) -> ReleaseResult:
    base = ReleaseResult(
        schema=1,
        tag="v1.0.0",
        commit=COMMIT,
        created=True,
        draft=False,
        prerelease=False,
        immutable=True,
    )
    return replace(base, **changes)  # type: ignore[arg-type]


class CandidateAttestationTests(unittest.TestCase):
    def test_candidate_encoding_is_canonical_and_round_trips(self) -> None:
        encoded = candidate_bytes(candidate())
        self.assertEqual(
            encoded,
            (
                b'{"build_number":0,"commit":"0123456789abcdef0123456789abcdef'
                b'01234567","directory_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                b'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","linux_aarch64_skipped":true,'
                b'"linux_validated":true,"macos_validated":true,"mode":"dry-run",'
                b'"rattler_build_version":"0.30.0","schema":1,'
                b'"upstream_commit":"89abcdef0123456789abcdef0123456789abcdef",'
                b'"version":"1.0.0"}\n'
            ),
        )
        self.assertEqual(load_candidate(encoded), candidate())

    def test_candidate_write_returns_the_written_digest(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-candidate-") as raw_tmp:
            path = Path(raw_tmp) / "candidate.json"
            digest = write_candidate(path, candidate())
            self.assertEqual(
                digest,
                "10c6deba20477d7a555d7bd1ae8aa16ad43ef82d595f4a326f2ac439531e4a40",
            )
            self.assertEqual(path.read_bytes(), candidate_bytes(candidate()))

    def test_candidate_rejects_each_closed_invariant(self) -> None:
        mutations = (
            {"schema": 2},
            {"mode": "publish"},
            {"version": "v1.0.0"},
            {"commit": "A" * 40},
            {"build_number": -1},
            {"build_number": True},
            {"upstream_commit": "0" * 39},
            {"directory_digest": "A" * 64},
            {"rattler_build_version": "0.30.1"},
            {"linux_validated": False},
            {"linux_validated": 1},
            {"macos_validated": False},
            {"linux_aarch64_skipped": False},
        )
        for changes in mutations:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                candidate_bytes(candidate(**changes))

    def test_candidate_loader_rejects_unknown_missing_and_noncanonical_json(
        self,
    ) -> None:
        encoded = candidate_bytes(candidate())
        cases = (
            encoded.replace(b'"schema":1,', b'"schema":1,"unknown":true,', 1),
            encoded.replace(b'"schema":1,', b"", 1),
            encoded.replace(b',"version"', b', "version"', 1),
        )
        for payload in cases:
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                load_candidate(payload)

    def test_release_workflow_accepts_only_exact_dry_run_build_zero(self) -> None:
        validate_release_candidate(candidate())
        for result in (
            candidate(mode="prepare"),
            candidate(build_number=1),
        ):
            with self.subTest(result=result), self.assertRaises(ValueError):
                validate_release_candidate(result)


class ReleaseAttestationTests(unittest.TestCase):
    def test_release_encoding_is_canonical_and_round_trips(self) -> None:
        encoded = release_bytes(release())
        self.assertEqual(
            encoded,
            (
                b'{"commit":"0123456789abcdef0123456789abcdef01234567",'
                b'"created":true,"draft":false,"immutable":true,'
                b'"prerelease":false,"schema":1,"tag":"v1.0.0"}\n'
            ),
        )
        self.assertEqual(load_release(encoded), release())

    def test_release_write_returns_the_written_digest(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-release-") as raw_tmp:
            path = Path(raw_tmp) / "release.json"
            digest = write_release(path, release())
            self.assertEqual(
                digest,
                "bd9ead8e991eb6dbba9b80467539d4a3da1dc894b210640da8e6fe44ecd3ed5f",
            )
            self.assertEqual(path.read_bytes(), release_bytes(release()))

    def test_release_rejects_mutable_or_nonstable_states(self) -> None:
        mutations = (
            {"schema": 0},
            {"tag": "1.0.0"},
            {"tag": "v1.0.0-beta"},
            {"commit": "0" * 39},
            {"created": 1},
            {"draft": True},
            {"prerelease": True},
            {"immutable": False},
        )
        for changes in mutations:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                release_bytes(release(**changes))

    def test_release_loader_rejects_unknown_and_missing_keys(self) -> None:
        encoded = release_bytes(release())
        cases = (
            encoded.replace(b'"schema":1,', b'"schema":1,"unknown":true,', 1),
            encoded.replace(b'"created":true,', b"", 1),
        )
        for payload in cases:
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                load_release(payload)


if __name__ == "__main__":
    unittest.main()
