#!/usr/bin/env python3
"""Canonical closed-schema attestations for release workflows."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
from pathlib import Path
import re
import sys
from typing import Any


VERSION_RE = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
TAG_RE = re.compile(r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
DIGEST_RE = re.compile(r"[0-9a-f]{64}\Z")


@dataclass(frozen=True)
class CandidateResult:
    """Evidence that one rendered community candidate passed all validations."""

    schema: int
    mode: str
    version: str
    commit: str
    build_number: int
    upstream_commit: str
    directory_digest: str
    rattler_build_version: str
    linux_validated: bool
    macos_validated: bool
    linux_aarch64_skipped: bool


@dataclass(frozen=True)
class ReleaseResult:
    """Evidence for one stable immutable GitHub release state."""

    schema: int
    tag: str
    commit: str
    created: bool
    draft: bool
    prerelease: bool
    immutable: bool


def _exact_int(value: object, label: str, *, nonnegative: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{label} must be an integer")
    if nonnegative and value < 0:
        raise ValueError(f"{label} must be non-negative")
    return value


def _exact_bool(value: object, label: str) -> bool:
    if type(value) is not bool:
        raise ValueError(f"{label} must be a boolean")
    return value


def _validate_candidate(result: CandidateResult) -> None:
    if _exact_int(result.schema, "schema") != 1:
        raise ValueError("candidate schema must equal 1")
    if result.mode not in {"dry-run", "prepare"}:
        raise ValueError(f"invalid candidate mode: {result.mode!r}")
    if VERSION_RE.fullmatch(result.version) is None:
        raise ValueError(f"invalid candidate version: {result.version!r}")
    if SHA_RE.fullmatch(result.commit) is None:
        raise ValueError("candidate commit must be a lowercase full SHA")
    _exact_int(result.build_number, "build_number", nonnegative=True)
    if SHA_RE.fullmatch(result.upstream_commit) is None:
        raise ValueError("upstream_commit must be a lowercase full SHA")
    if DIGEST_RE.fullmatch(result.directory_digest) is None:
        raise ValueError("directory_digest must be lowercase SHA-256")
    if result.rattler_build_version != "0.30.0":
        raise ValueError("rattler_build_version must equal 0.30.0")
    for label in (
        "linux_validated",
        "macos_validated",
        "linux_aarch64_skipped",
    ):
        if not _exact_bool(getattr(result, label), label):
            raise ValueError(f"{label} must be true")


def validate_release_candidate(result: CandidateResult) -> None:
    """Accept only dry-run build-zero evidence for GitHub release creation."""
    _validate_candidate(result)
    if result.mode != "dry-run":
        raise ValueError("release candidate evidence must be a dry-run")
    if result.build_number != 0:
        raise ValueError("release candidate build number must equal 0")


def _validate_release(result: ReleaseResult) -> None:
    if _exact_int(result.schema, "schema") != 1:
        raise ValueError("release schema must equal 1")
    if TAG_RE.fullmatch(result.tag) is None:
        raise ValueError(f"invalid stable release tag: {result.tag!r}")
    if SHA_RE.fullmatch(result.commit) is None:
        raise ValueError("release commit must be a lowercase full SHA")
    _exact_bool(result.created, "created")
    if _exact_bool(result.draft, "draft"):
        raise ValueError("release must not be a draft")
    if _exact_bool(result.prerelease, "prerelease"):
        raise ValueError("release must not be a prerelease")
    if not _exact_bool(result.immutable, "immutable"):
        raise ValueError("release must be immutable")


def _canonical(document: dict[str, object]) -> bytes:
    return (
        json.dumps(
            document,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        + b"\n"
    )


def candidate_bytes(result: CandidateResult) -> bytes:
    """Validate and canonically encode candidate evidence."""
    _validate_candidate(result)
    return _canonical(asdict(result))


def release_bytes(result: ReleaseResult) -> bytes:
    """Validate and canonically encode release evidence."""
    _validate_release(result)
    return _canonical(asdict(result))


def _load_document(encoded: bytes, fields: set[str]) -> dict[str, Any]:
    try:
        document: Any = json.loads(encoded)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid attestation JSON: {exc}") from exc
    if not isinstance(document, dict) or set(document) != fields:
        actual = sorted(document) if isinstance(document, dict) else type(document)
        raise ValueError(
            f"attestation key mismatch: expected={sorted(fields)}, actual={actual}"
        )
    return document


def load_candidate(encoded: bytes) -> CandidateResult:
    """Decode one canonical candidate attestation."""
    document = _load_document(encoded, set(CandidateResult.__dataclass_fields__))
    result = CandidateResult(**document)
    if encoded != candidate_bytes(result):
        raise ValueError("attestation JSON is not canonical")
    return result


def load_release(encoded: bytes) -> ReleaseResult:
    """Decode one canonical release attestation."""
    document = _load_document(encoded, set(ReleaseResult.__dataclass_fields__))
    result = ReleaseResult(**document)
    if encoded != release_bytes(result):
        raise ValueError("attestation JSON is not canonical")
    return result


def _write(path: Path, encoded: bytes) -> str:
    if path.is_symlink():
        raise ValueError(f"attestation output must not be a symlink: {path}")
    path.write_bytes(encoded)
    return hashlib.sha256(encoded).hexdigest()


def write_candidate(path: Path, result: CandidateResult) -> str:
    """Write canonical candidate evidence and return its SHA-256."""
    return _write(path, candidate_bytes(result))


def write_release(path: Path, result: ReleaseResult) -> str:
    """Write canonical release evidence and return its SHA-256."""
    return _write(path, release_bytes(result))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    domain = parser.add_subparsers(dest="domain", required=True)
    for name in ("candidate", "release"):
        subject = domain.add_parser(name)
        operation = subject.add_subparsers(dest="operation", required=True)
        validate = operation.add_parser("validate")
        validate.add_argument("--input", type=Path, required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    """Validate a canonical candidate or release attestation."""
    args = _parser().parse_args(argv)
    try:
        encoded = args.input.read_bytes()
        if args.domain == "candidate":
            result = load_candidate(encoded)
            if args.operation == "validate":
                validate_release_candidate(result)
        else:
            load_release(encoded)
    except (OSError, TypeError, ValueError) as exc:
        print(f"release-attestation: FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
