#!/usr/bin/env python3
"""Classify immutable GitHub release state and dereference Git tags."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from enum import Enum
import json
from pathlib import Path
import re
import subprocess
import sys


SHA_RE = re.compile(r"[0-9a-f]{40}\Z")


class ReleaseAction(Enum):
    """The only mutations an exact release snapshot may authorize."""

    CREATE_TAG_AND_RELEASE = "create-tag-and-release"
    CREATE_RELEASE = "create-release"
    NOOP = "noop"


@dataclass(frozen=True)
class ReleaseSnapshot:
    """Relevant current state for one intended tag and release."""

    tag_commit: str | None
    release_exists: bool
    draft: bool | None
    prerelease: bool | None
    immutable: bool | None


def _sha(value: str, label: str) -> None:
    if SHA_RE.fullmatch(value) is None:
        raise ValueError(f"{label} must be a lowercase full SHA")


def classify_release(
    snapshot: ReleaseSnapshot,
    expected_commit: str,
) -> ReleaseAction:
    """Return the sole safe idempotent action for a release snapshot."""
    _sha(expected_commit, "expected_commit")
    if snapshot.tag_commit is None:
        if snapshot.release_exists or any(
            value is not None
            for value in (snapshot.draft, snapshot.prerelease, snapshot.immutable)
        ):
            raise ValueError("release exists without its tag")
        return ReleaseAction.CREATE_TAG_AND_RELEASE

    _sha(snapshot.tag_commit, "tag_commit")
    if snapshot.tag_commit != expected_commit:
        raise ValueError("existing tag targets another commit")
    if type(snapshot.release_exists) is not bool:
        raise ValueError("release existence state must be boolean")
    if not snapshot.release_exists:
        if any(
            value is not None
            for value in (snapshot.draft, snapshot.prerelease, snapshot.immutable)
        ):
            raise ValueError("incomplete release snapshot")
        return ReleaseAction.CREATE_RELEASE

    if type(snapshot.draft) is not bool:
        raise ValueError("release draft state must be boolean")
    if type(snapshot.prerelease) is not bool:
        raise ValueError("release prerelease state must be boolean")
    if type(snapshot.immutable) is not bool:
        raise ValueError("release immutable state must be boolean")
    if snapshot.draft or snapshot.prerelease or not snapshot.immutable:
        raise ValueError("existing release is not stable and immutable")
    return ReleaseAction.NOOP


def dereference_tag(repo: Path, tag: str) -> str:
    """Resolve an annotated or lightweight tag to its commit."""
    try:
        completed = subprocess.run(
            ["git", "rev-list", "-n", "1", f"{tag}^{{commit}}"],
            cwd=repo,
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ValueError(f"could not dereference tag {tag!r}") from exc
    lines = completed.stdout.splitlines()
    if len(lines) != 1 or SHA_RE.fullmatch(lines[0]) is None:
        raise ValueError(f"tag {tag!r} did not resolve to one full commit")
    return lines[0]


def _load_snapshot(path: Path) -> ReleaseSnapshot:
    document = json.loads(path.read_bytes())
    fields = {
        "tag_commit",
        "release_exists",
        "draft",
        "prerelease",
        "immutable",
    }
    if not isinstance(document, dict) or set(document) != fields:
        raise ValueError("release snapshot key mismatch")
    return ReleaseSnapshot(**document)


def _write_action(path: Path, action: ReleaseAction) -> None:
    if path.is_symlink():
        raise ValueError("classification output must not be a symlink")
    path.write_text(f"{action.value}\n", encoding="utf-8")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    commands = parser.add_subparsers(dest="command", required=True)
    dereference = commands.add_parser("dereference", allow_abbrev=False)
    dereference.add_argument("--repo", type=Path, required=True)
    dereference.add_argument("--tag", required=True)
    classify = commands.add_parser("classify", allow_abbrev=False)
    classify.add_argument("--snapshot", type=Path, required=True)
    classify.add_argument("--expected-commit", required=True)
    classify.add_argument("--output", type=Path, required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    """Run a Git tag dereference or closed release-state classification."""
    args = _parser().parse_args(argv)
    try:
        if args.command == "dereference":
            print(dereference_tag(args.repo, args.tag))
        else:
            action = classify_release(
                _load_snapshot(args.snapshot),
                args.expected_commit,
            )
            _write_action(args.output, action)
    except (OSError, TypeError, ValueError) as exc:
        print(f"github-release: FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
