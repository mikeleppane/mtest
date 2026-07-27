#!/usr/bin/env python3
"""Classify community publication state and validate fork credentials."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import UTC, datetime
from enum import Enum
import json
from pathlib import Path
import re
import sys


VERSION_RE = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
EXPIRATION_HEADER = "github-authentication-token-expiration"
OAUTH_SCOPES_HEADER = "x-oauth-scopes"


class PublicationAction(Enum):
    """The only safe next actions for one community build."""

    CREATE_BRANCH = "create-branch"
    UPDATE_BRANCH = "update-branch"
    PUBLISHED_NOOP = "published-noop"
    MERGED_WAITING = "merged-waiting"


@dataclass(frozen=True)
class PublicationDecision:
    """One closed publication decision and its existing PR, if any."""

    action: PublicationAction
    pull_request_url: str | None


def branch_name(version: str, build_number: int) -> str:
    """Return the sole branch name for a community package build."""
    if VERSION_RE.fullmatch(version) is None:
        raise ValueError(f"invalid version: {version!r}")
    build: object = build_number
    if isinstance(build, bool) or not isinstance(build, int) or build < 0:
        raise ValueError(f"invalid build number: {build!r}")
    return f"mtest-{version}-build-{build_number}"


def _records(
    document: object,
    *,
    platform: str,
    version: str,
    build_number: int,
) -> bool:
    if not isinstance(document, list):
        raise ValueError(f"{platform} channel records must be a list")
    if len(document) > 1:
        raise ValueError(f"{platform} channel returned duplicate package records")
    if not document:
        return False
    item = document[0]
    if not isinstance(item, dict):
        raise ValueError(f"{platform} channel record must be an object")
    expected = {
        "name": "mtest",
        "version": version,
        "build_number": build_number,
        "subdir": platform,
    }
    if item != expected:
        raise ValueError(
            f"{platform} channel record mismatch: expected={expected}, actual={item}"
        )
    if isinstance(item["build_number"], bool):
        raise ValueError(f"{platform} build_number must be an integer")
    return True


def _pull_request(
    document: object,
    *,
    owner: str,
    branch: str,
) -> PublicationDecision | None:
    if not isinstance(document, list):
        raise ValueError("pull request response must be a list")
    if len(document) > 1:
        raise ValueError("duplicate pull requests exist for the release branch")
    if not document:
        return None
    item = document[0]
    if not isinstance(item, dict):
        raise ValueError("pull request record must be an object")
    head = item.get("head")
    if not isinstance(head, dict):
        raise ValueError("pull request head is missing")
    user = head.get("user")
    if (
        not isinstance(user, dict)
        or user.get("login") != owner
        or head.get("ref") != branch
        or head.get("label") != f"{owner}:{branch}"
    ):
        raise ValueError("pull request head does not match the exact fork branch")
    if item.get("maintainer_can_modify") is not False:
        raise ValueError("pull request must disable maintainer edits")
    base = item.get("base")
    repository = base.get("repo") if isinstance(base, dict) else None
    if (
        not isinstance(base, dict)
        or base.get("ref") != "main"
        or not isinstance(repository, dict)
        or repository.get("full_name") != "modular/modular-community"
    ):
        raise ValueError("pull request base must be modular/modular-community main")
    url = item.get("html_url")
    if not isinstance(url, str) or not url.startswith("https://github.com/"):
        raise ValueError("pull request URL is invalid")
    state = item.get("state")
    merged_at = item.get("merged_at")
    if state == "open" and merged_at is None:
        return PublicationDecision(PublicationAction.UPDATE_BRANCH, url)
    if state == "closed" and isinstance(merged_at, str) and merged_at:
        return PublicationDecision(PublicationAction.MERGED_WAITING, url)
    raise ValueError("pull request is closed without a merge")


def classify_publication(
    linux_records: object,
    macos_records: object,
    pull_requests: object,
    *,
    owner: str,
    version: str,
    build_number: int,
) -> PublicationDecision:
    """Classify exact public-channel and upstream pull-request state."""
    branch = branch_name(version, build_number)
    linux = _records(
        linux_records,
        platform="linux-64",
        version=version,
        build_number=build_number,
    )
    macos = _records(
        macos_records,
        platform="osx-arm64",
        version=version,
        build_number=build_number,
    )
    if linux != macos:
        raise ValueError("partial public publication: supported platforms disagree")
    if linux:
        return PublicationDecision(PublicationAction.PUBLISHED_NOOP, None)
    pull_request = _pull_request(pull_requests, owner=owner, branch=branch)
    if pull_request is not None:
        return pull_request
    return PublicationDecision(PublicationAction.CREATE_BRANCH, None)


def _expiration(headers: str) -> str:
    values: list[str] = []
    for line in headers.splitlines():
        name, separator, value = line.partition(":")
        if separator and name.strip().lower() == EXPIRATION_HEADER:
            values.append(value.strip())
    if len(values) != 1:
        raise ValueError("GitHub token expiration header must appear exactly once")
    return values[0]


def _reject_classic_scopes(headers: str) -> None:
    for line in headers.splitlines():
        name, separator, value = line.partition(":")
        if separator and name.strip().lower() == OAUTH_SCOPES_HEADER and value.strip():
            raise ValueError("classic GitHub token scopes are not accepted")


def _parse_expiration(raw: str) -> datetime:
    try:
        if raw.endswith(" UTC"):
            parsed = datetime.strptime(raw, "%Y-%m-%d %H:%M:%S UTC").replace(tzinfo=UTC)
        else:
            parsed = datetime.fromisoformat(raw)
    except ValueError as exc:
        raise ValueError(f"invalid GitHub token expiration: {raw!r}") from exc
    if parsed.tzinfo is None:
        raise ValueError("GitHub token expiration must include a timezone")
    return parsed.astimezone(UTC)


def validate_credential(
    headers: str,
    user_document: object,
    expected_login: str,
    now: datetime,
) -> datetime:
    """Validate authenticated fork identity and a future token expiry."""
    if (
        not isinstance(user_document, dict)
        or user_document.get("login") != expected_login
    ):
        raise ValueError("authenticated GitHub login does not match fork owner")
    if now.tzinfo is None:
        raise ValueError("credential comparison time must be timezone-aware")
    _reject_classic_scopes(headers)
    expiration = _parse_expiration(_expiration(headers))
    if expiration <= now.astimezone(UTC):
        raise ValueError("GitHub token is expired")
    return expiration


def validate_fork_repository(document: object, expected_owner: str) -> None:
    """Require the token-visible repository to be the intended writable fork."""
    if not isinstance(document, dict):
        raise ValueError("fork repository response must be an object")
    parent = document.get("parent")
    permissions = document.get("permissions")
    if (
        document.get("full_name") != f"{expected_owner}/modular-community"
        or document.get("fork") is not True
        or not isinstance(parent, dict)
        or parent.get("full_name") != "modular/modular-community"
        or not isinstance(permissions, dict)
        or permissions.get("push") is not True
    ):
        raise ValueError(
            "credential must access the intended writable modular-community fork"
        )


def validate_archive_license(listing: str, expected: str) -> None:
    """Require exactly one archive listing entry equal to the license path."""
    matches = [
        line.rstrip(" \t\r")
        for line in listing.splitlines()
        if line.rstrip(" \t\r") == expected
    ]
    if matches != [expected]:
        raise ValueError(
            f"archive must contain exactly one {expected!r} entry; "
            f"matches={len(matches)}"
        )


def _load_json(path: Path) -> object:
    return json.loads(path.read_bytes())


def _write(path: Path, text: str) -> None:
    if path.is_symlink():
        raise ValueError(f"output must not be a symlink: {path}")
    path.write_text(text, encoding="utf-8")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    commands = parser.add_subparsers(dest="command", required=True)

    branch = commands.add_parser("branch", allow_abbrev=False)
    branch.add_argument("--version", required=True)
    branch.add_argument("--build-number", type=int, required=True)
    branch.add_argument("--output", type=Path, required=True)

    archive = commands.add_parser("archive-license", allow_abbrev=False)
    archive.add_argument("--listing", type=Path, required=True)
    archive.add_argument("--expected", required=True)

    classify = commands.add_parser("classify", allow_abbrev=False)
    classify.add_argument("--linux-records", type=Path, required=True)
    classify.add_argument("--macos-records", type=Path, required=True)
    classify.add_argument("--pull-requests", type=Path, required=True)
    classify.add_argument("--owner", required=True)
    classify.add_argument("--version", required=True)
    classify.add_argument("--build-number", type=int, required=True)
    classify.add_argument("--output", type=Path, required=True)

    credential = commands.add_parser("credential", allow_abbrev=False)
    credential.add_argument("--headers", type=Path, required=True)
    credential.add_argument("--user", type=Path, required=True)
    credential.add_argument("--expected-login", required=True)
    credential.add_argument("--output", type=Path, required=True)
    fork = commands.add_parser("fork", allow_abbrev=False)
    fork.add_argument("--repository", type=Path, required=True)
    fork.add_argument("--expected-owner", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    """Run one closed community-publication helper command."""
    args = _parser().parse_args(argv)
    try:
        if args.command == "branch":
            _write(
                args.output,
                f"{branch_name(args.version, args.build_number)}\n",
            )
        elif args.command == "archive-license":
            validate_archive_license(
                args.listing.read_text(encoding="utf-8"),
                args.expected,
            )
        elif args.command == "classify":
            decision = classify_publication(
                _load_json(args.linux_records),
                _load_json(args.macos_records),
                _load_json(args.pull_requests),
                owner=args.owner,
                version=args.version,
                build_number=args.build_number,
            )
            _write(
                args.output,
                json.dumps(
                    {
                        "action": decision.action.value,
                        "pull_request_url": decision.pull_request_url,
                    },
                    ensure_ascii=True,
                    separators=(",", ":"),
                    sort_keys=True,
                )
                + "\n",
            )
        elif args.command == "credential":
            expiration = validate_credential(
                args.headers.read_text(encoding="utf-8"),
                _load_json(args.user),
                args.expected_login,
                datetime.now(UTC),
            )
            _write(
                args.output,
                expiration.isoformat().replace("+00:00", "Z") + "\n",
            )
        else:
            validate_fork_repository(
                _load_json(args.repository),
                args.expected_owner,
            )
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as exc:
        print(f"community-publication: FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
