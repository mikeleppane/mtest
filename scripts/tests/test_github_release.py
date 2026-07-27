#!/usr/bin/env python3
"""Release-state and Git tag dereference tests."""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path
import subprocess
import tempfile
import unittest

from scripts.release.github_release import (
    ReleaseAction,
    ReleaseSnapshot,
    classify_release,
    dereference_tag,
    main,
)


COMMIT = "0123456789abcdef0123456789abcdef01234567"


def snapshot(**changes: object) -> ReleaseSnapshot:
    base = ReleaseSnapshot(
        tag_commit=COMMIT,
        release_exists=True,
        draft=False,
        prerelease=False,
        immutable=True,
    )
    return replace(base, **changes)  # type: ignore[arg-type]


class ReleaseStateTests(unittest.TestCase):
    def test_absent_tag_and_release_are_created_together(self) -> None:
        self.assertEqual(
            classify_release(
                ReleaseSnapshot(None, False, None, None, None),
                COMMIT,
            ),
            ReleaseAction.CREATE_TAG_AND_RELEASE,
        )

    def test_exact_tag_without_release_creates_only_release(self) -> None:
        self.assertEqual(
            classify_release(
                ReleaseSnapshot(COMMIT, False, None, None, None),
                COMMIT,
            ),
            ReleaseAction.CREATE_RELEASE,
        )

    def test_exact_immutable_stable_release_is_idempotent(self) -> None:
        self.assertEqual(
            classify_release(snapshot(), COMMIT),
            ReleaseAction.NOOP,
        )

    def test_conflicting_or_mutable_states_are_rejected(self) -> None:
        conflicts = (
            ReleaseSnapshot(None, True, False, False, True),
            snapshot(tag_commit="1" * 40),
            snapshot(release_exists=1),
            snapshot(release_exists=False, draft=False),
            snapshot(draft=True),
            snapshot(prerelease=True),
            snapshot(immutable=False),
            snapshot(tag_commit="A" * 40),
        )
        for state in conflicts:
            with self.subTest(state=state), self.assertRaises(ValueError):
                classify_release(state, COMMIT)

    def test_expected_commit_must_be_a_lowercase_full_sha(self) -> None:
        for commit in ("0" * 39, "A" * 40):
            with self.subTest(commit=commit), self.assertRaises(ValueError):
                classify_release(snapshot(), commit)


class TagDereferenceTests(unittest.TestCase):
    def _repository(self, root: Path) -> str:
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(
            ["git", "-C", str(root), "config", "user.name", "mtest"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(root), "config", "user.email", "mtest@example.test"],
            check=True,
        )
        (root / "file").write_text("content\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(root), "add", "file"], check=True)
        subprocess.run(
            ["git", "-C", str(root), "commit", "-q", "-m", "fixture"],
            check=True,
        )
        return subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def test_lightweight_and_annotated_tags_resolve_to_the_commit(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-tag-") as raw_tmp:
            repo = Path(raw_tmp)
            commit = self._repository(repo)
            subprocess.run(
                ["git", "-C", str(repo), "tag", "v1.0.0"],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(repo), "tag", "-a", "v1.0.1", "-m", "release"],
                check=True,
            )
            self.assertEqual(dereference_tag(repo, "v1.0.0"), commit)
            self.assertEqual(dereference_tag(repo, "v1.0.1"), commit)

    def test_missing_tag_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-tag-") as raw_tmp:
            repo = Path(raw_tmp)
            self._repository(repo)
            with self.assertRaises(ValueError):
                dereference_tag(repo, "v1.0.0")


class ReleaseCliTests(unittest.TestCase):
    def test_classify_writes_only_the_action(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-release-cli-") as raw_tmp:
            root = Path(raw_tmp)
            snapshot_path = root / "snapshot.json"
            output_path = root / "action.txt"
            snapshot_path.write_text(
                (
                    '{"draft":false,"immutable":true,"prerelease":false,'
                    '"release_exists":true,'
                    f'"tag_commit":"{COMMIT}"}}\n'
                ),
                encoding="utf-8",
            )
            self.assertEqual(
                main(
                    [
                        "classify",
                        "--snapshot",
                        str(snapshot_path),
                        "--expected-commit",
                        COMMIT,
                        "--output",
                        str(output_path),
                    ]
                ),
                0,
            )
            self.assertEqual(output_path.read_text(encoding="utf-8"), "noop\n")


if __name__ == "__main__":
    unittest.main()
