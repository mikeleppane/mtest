#!/usr/bin/env python3
"""Community channel, pull-request, branch, and credential state tests."""

from __future__ import annotations

from datetime import UTC, datetime
import unittest

from scripts.release.community import (
    PublicationAction,
    PublicationDecision,
    branch_name,
    classify_publication,
    validate_credential,
)


OWNER = "mikeleppane"
VERSION = "1.0.0"
BUILD_NUMBER = 0
NOW = datetime(2026, 7, 27, 12, 0, tzinfo=UTC)


def record(platform: str) -> dict[str, object]:
    return {
        "name": "mtest",
        "version": VERSION,
        "build_number": BUILD_NUMBER,
        "subdir": platform,
    }


def pull_request(**changes: object) -> dict[str, object]:
    result: dict[str, object] = {
        "html_url": "https://github.com/modular/modular-community/pull/123",
        "state": "open",
        "merged_at": None,
        "maintainer_can_modify": False,
        "head": {
            "label": f"{OWNER}:mtest-{VERSION}-build-{BUILD_NUMBER}",
            "ref": f"mtest-{VERSION}-build-{BUILD_NUMBER}",
            "user": {"login": OWNER},
        },
    }
    result.update(changes)
    return result


class PublicationStateTests(unittest.TestCase):
    def _classify(
        self,
        linux: object = None,
        macos: object = None,
        pull_requests: object = None,
    ) -> PublicationDecision:
        return classify_publication(
            [] if linux is None else linux,
            [] if macos is None else macos,
            [] if pull_requests is None else pull_requests,
            owner=OWNER,
            version=VERSION,
            build_number=BUILD_NUMBER,
        )

    def test_branch_name_is_deterministic_and_validated(self) -> None:
        self.assertEqual(branch_name(VERSION, BUILD_NUMBER), "mtest-1.0.0-build-0")
        for version, build in (("v1.0.0", 0), ("1.0", 0), ("1.0.0", -1)):
            with (
                self.subTest(version=version, build=build),
                self.assertRaises(ValueError),
            ):
                branch_name(version, build)

    def test_absent_publication_and_pull_request_create_branch(self) -> None:
        decision = self._classify()
        self.assertEqual(decision.action, PublicationAction.CREATE_BRANCH)
        self.assertIsNone(decision.pull_request_url)

    def test_both_exact_public_builds_are_an_idempotent_noop(self) -> None:
        decision = self._classify(
            [record("linux-64")],
            [record("osx-arm64")],
        )
        self.assertEqual(decision.action, PublicationAction.PUBLISHED_NOOP)

    def test_partial_publication_is_a_hard_conflict(self) -> None:
        with self.assertRaisesRegex(ValueError, "partial"):
            self._classify([record("linux-64")], [])

    def test_exact_noneditable_open_pull_request_updates_branch(self) -> None:
        decision = self._classify(pull_requests=[pull_request()])
        self.assertEqual(decision.action, PublicationAction.UPDATE_BRANCH)
        self.assertEqual(
            decision.pull_request_url,
            "https://github.com/modular/modular-community/pull/123",
        )

    def test_merged_pull_request_waits_for_public_builds(self) -> None:
        decision = self._classify(
            pull_requests=[
                pull_request(
                    state="closed",
                    merged_at="2026-07-27T12:00:00Z",
                )
            ]
        )
        self.assertEqual(decision.action, PublicationAction.MERGED_WAITING)

    def test_conflicting_pull_request_states_are_rejected(self) -> None:
        wrong_head = pull_request(
            head={
                "label": f"{OWNER}:wrong",
                "ref": "wrong",
                "user": {"login": OWNER},
            }
        )
        conflicts = (
            [pull_request(maintainer_can_modify=True)],
            [pull_request(), pull_request()],
            [wrong_head],
            [pull_request(state="closed", merged_at=None)],
        )
        for pull_requests in conflicts:
            with (
                self.subTest(pull_requests=pull_requests),
                self.assertRaises(ValueError),
            ):
                self._classify(pull_requests=pull_requests)

    def test_malformed_or_wrong_public_records_are_rejected(self) -> None:
        for records in (
            "not-a-list",
            [record("linux-64"), record("linux-64")],
            [{**record("linux-64"), "version": "1.0.1"}],
            [{**record("linux-64"), "build_number": True}],
        ):
            with self.subTest(records=records), self.assertRaises(ValueError):
                self._classify(records, [])


class CredentialTests(unittest.TestCase):
    def test_github_and_rfc3339_expirations_normalize_to_utc(self) -> None:
        formats = (
            (
                ("github-authentication-token-expiration: 2026-07-28 12:00:00 UTC\n"),
                datetime(2026, 7, 28, 12, 0, tzinfo=UTC),
            ),
            (
                (
                    "GitHub-Authentication-Token-Expiration: "
                    "2026-07-28T15:00:00+03:00\r\n"
                ),
                datetime(2026, 7, 28, 12, 0, tzinfo=UTC),
            ),
        )
        for headers, expected in formats:
            with self.subTest(headers=headers):
                self.assertEqual(
                    validate_credential(headers, {"login": OWNER}, OWNER, NOW),
                    expected,
                )

    def test_credential_rejects_wrong_identity_or_expiration(self) -> None:
        cases = (
            ("", {"login": OWNER}),
            (
                "github-authentication-token-expiration: malformed\n",
                {"login": OWNER},
            ),
            (
                ("github-authentication-token-expiration: 2026-07-26 12:00:00 UTC\n"),
                {"login": OWNER},
            ),
            (
                ("github-authentication-token-expiration: 2026-07-28 12:00:00 UTC\n"),
                {"login": "someone-else"},
            ),
        )
        for headers, user in cases:
            with (
                self.subTest(headers=headers, user=user),
                self.assertRaises(ValueError),
            ):
                validate_credential(headers, user, OWNER, NOW)


if __name__ == "__main__":
    unittest.main()
