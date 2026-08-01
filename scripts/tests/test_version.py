#!/usr/bin/env python3
"""Mutation tests for the public-version gate.

Each test corrupts a real public surface inside a temporary repository and
asserts the gate rejects it, so every guard is watched firing on the exact
thing it exists to prevent. A checker that has quietly stopped rejecting
anything is worse than no checker, and this one guards claims that reach a
reader rather than a build.
"""

from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from scripts.checks import version


GATED_FILES = (*version.TRANSCRIPT_SITES, Path("pixi.toml"))
DECLARED_FILES = (*version.TRANSCRIPT_SITES, *version.TRANSCRIPT_EXEMPT)


def _clone_file(root: Path, relative: Path) -> Path:
    """Copy one repository file into a temporary root, creating its parents.

    Args:
        root: Directory standing in for the repository root.
        relative: Repository-relative path to copy.

    Returns:
        The path of the copy.
    """
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(version.REPO_ROOT / relative, target)
    return target


class TranscriptGateTests(unittest.TestCase):
    """The transcript gate's rejection behavior, not merely its green path."""

    def _clone(self, root: Path) -> None:
        """Copy every gated file into a temporary repository root.

        Args:
            root: Empty directory standing in for the repository root.
        """
        for relative in GATED_FILES:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(version.REPO_ROOT / relative, target)

    def test_repository_transcript_sites_are_exact(self) -> None:
        self.assertEqual(
            version.TRANSCRIPT_SITES,
            (
                Path("README.md"),
                Path("docs/cli-contract.md"),
                Path("docs/index.md"),
                Path("docs/getting-started.md"),
                Path("docs/assets/mtest-run.svg"),
                Path("docs/assets/mtest-flaky.svg"),
            ),
        )

    def test_every_gated_site_exists_and_renders_the_release(self) -> None:
        for relative in version.TRANSCRIPT_SITES:
            path = version.REPO_ROOT / relative
            self.assertTrue(path.is_file(), path)
            self.assertEqual(
                set(version.transcript_versions(path)),
                {version.EXPECTED_VERSION},
                path,
            )
        version.check_transcript_sites()

    def test_stale_transcript_is_rejected(self) -> None:
        for relative in version.TRANSCRIPT_SITES:
            with (
                self.subTest(site=str(relative)),
                tempfile.TemporaryDirectory(prefix="mtest-version-") as raw,
            ):
                root = Path(raw)
                self._clone(root)
                site = root / relative
                site.write_text(
                    site.read_text(encoding="utf-8").replace(
                        f"mtest {version.EXPECTED_VERSION}", "mtest 0.9.9", 1
                    ),
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(AssertionError, r"0\.9\.9"):
                    version.check_transcript_sites(root)

    def test_site_that_lost_every_literal_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-version-") as raw:
            root = Path(raw)
            self._clone(root)
            (root / "docs" / "assets" / "mtest-run.svg").write_text(
                "<svg></svg>\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(AssertionError, "mtest-run.svg"):
                version.check_transcript_sites(root)

    def test_a_vanished_site_is_reported_not_crashed(self) -> None:
        """A deleted or renamed site must fail the gate, not raise OSError.

        `main()` catches `AssertionError` alone, so an unguarded `read_text`
        would end the run in a traceback instead of `version-check: FAIL`.
        """
        with tempfile.TemporaryDirectory(prefix="mtest-version-") as raw:
            root = Path(raw)
            self._clone(root)
            (root / "docs" / "cli-contract.md").unlink()
            with self.assertRaisesRegex(AssertionError, "cannot read"):
                version.check_transcript_sites(root)

    def test_the_trailing_guard_lengthens_a_malformed_match(self) -> None:
        """The guard forbids a prefix match; it does not suppress the match.

        On `mtest 1.0.01` the pattern captures `1.0.01` whole rather than
        reading the first three components as a valid `1.0.0`. Asserted here
        directly because the opposite reading is the plausible one, and the
        gate's rejection of a malformed literal rests entirely on it.
        """
        self.assertEqual(version.TRANSCRIPT_RE.findall("mtest 1.0.01"), ["1.0.01"])

    def test_malformed_literal_is_reported_whole(self) -> None:
        """A zero-padded literal disagrees with the release, so it is rejected."""
        with tempfile.TemporaryDirectory(prefix="mtest-version-") as raw:
            root = Path(raw)
            self._clone(root)
            readme = root / "README.md"
            readme.write_text(
                readme.read_text(encoding="utf-8") + "\nmtest 1.0.01\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, r"1\.0\.01"):
                version.check_transcript_sites(root)


class TranscriptSweepTests(unittest.TestCase):
    """The sweep that stops an undeclared surface from being ungated."""

    def _repository(self, root: Path) -> None:
        """Build a temporary git repository holding every declared file.

        Args:
            root: Empty directory to initialize as a repository.
        """
        subprocess.run(["git", "-C", str(root), "init", "-q"], check=True)
        for relative in DECLARED_FILES:
            _clone_file(root, relative)
        subprocess.run(
            ["git", "-C", str(root), "add", "--", *(str(p) for p in DECLARED_FILES)],
            check=True,
        )

    def _track(self, root: Path, relative: str, text: str) -> None:
        """Write one extra file into the temporary repository and track it.

        Args:
            root: The temporary repository root.
            relative: Repository-relative path of the new file.
            text: Its contents.
        """
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        subprocess.run(["git", "-C", str(root), "add", "--", relative], check=True)

    def test_repository_has_no_undeclared_transcript(self) -> None:
        version.check_no_undeclared_transcripts()

    def test_sites_and_exemptions_do_not_overlap(self) -> None:
        self.assertEqual(
            set(version.TRANSCRIPT_SITES) & set(version.TRANSCRIPT_EXEMPT), set()
        )

    def test_a_new_documentation_page_with_a_transcript_is_rejected(self) -> None:
        """The case the hand-written site list cannot catch on its own.

        The page name is deliberately one no site uses. An earlier version of
        this test fabricated `docs/getting-started.md`, which the site later
        added for real: the sweep then correctly accepted it as a declared site
        and this test failed for a reason that had nothing to do with the
        property under test.
        """
        with tempfile.TemporaryDirectory(prefix="mtest-sweep-") as raw:
            root = Path(raw)
            self._repository(root)
            self._track(
                root,
                "docs/quickstart.md",
                f"# Quickstart\n\n```\nmtest {version.EXPECTED_VERSION}\n```\n",
            )
            with self.assertRaisesRegex(AssertionError, "docs/quickstart.md"):
                version.check_no_undeclared_transcripts(root)

    def test_an_undeclared_page_is_rejected_even_at_the_right_version(self) -> None:
        """Being current is not the same as being gated; both sweeps must fire."""
        with tempfile.TemporaryDirectory(prefix="mtest-sweep-") as raw:
            root = Path(raw)
            self._repository(root)
            self._track(root, "docs/tour.md", f"mtest {version.EXPECTED_VERSION}\n")
            version.check_transcript_sites(root)
            with self.assertRaisesRegex(AssertionError, "docs/tour.md"):
                version.check_no_undeclared_transcripts(root)

    def test_an_untracked_file_is_not_a_surface(self) -> None:
        """Scratch files are not published, and must not turn the gate red."""
        with tempfile.TemporaryDirectory(prefix="mtest-sweep-") as raw:
            root = Path(raw)
            self._repository(root)
            (root / "scratch.md").write_text(
                f"mtest {version.EXPECTED_VERSION}\n", encoding="utf-8"
            )
            version.check_no_undeclared_transcripts(root)

    def test_an_exemption_that_stopped_matching_is_rejected(self) -> None:
        """A standing exemption for a file that no longer needs one is a hole."""
        with tempfile.TemporaryDirectory(prefix="mtest-sweep-") as raw:
            root = Path(raw)
            self._repository(root)
            exempt = version.TRANSCRIPT_EXEMPT[-1]
            (root / exempt).write_text("nothing here\n", encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, str(exempt)):
                version.check_no_undeclared_transcripts(root)

    def test_a_tree_without_git_fails_closed(self) -> None:
        """No inventory means no verdict, so the sweep refuses rather than pass."""
        with (
            tempfile.TemporaryDirectory(prefix="mtest-sweep-") as raw,
            self.assertRaisesRegex(AssertionError, "cannot list tracked files"),
        ):
            version.check_no_undeclared_transcripts(Path(raw))


class MojoPinGateTests(unittest.TestCase):
    """Every restatement of the toolchain pin against the one manifest."""

    def _clone(self, root: Path) -> None:
        """Copy the pin sites and the pixi manifest into a temporary root.

        Args:
            root: Empty directory standing in for the repository root.
        """
        for relative in (*version.MOJO_PIN_SITES, Path("pixi.toml")):
            _clone_file(root, relative)

    def test_repository_pin_claims_match_the_manifest(self) -> None:
        version.check_mojo_pin_sites()

    def test_every_pin_site_states_at_least_one_claim(self) -> None:
        pinned = version._manifest_mojo_pin(version.REPO_ROOT / "pixi.toml")
        for relative in version.MOJO_PIN_SITES:
            path = version.REPO_ROOT / relative
            self.assertTrue(path.is_file(), path)
            claims = version.MOJO_PIN_CLAIM_RE.findall(path.read_text(encoding="utf-8"))
            self.assertNotEqual(claims, [], path)
            self.assertEqual(set(claims), {pinned}, path)

    def test_a_stale_claim_in_any_site_is_rejected(self) -> None:
        for relative in version.MOJO_PIN_SITES:
            with (
                self.subTest(site=str(relative)),
                tempfile.TemporaryDirectory(prefix="mtest-pin-") as raw,
            ):
                root = Path(raw)
                self._clone(root)
                site = root / relative
                text = site.read_text(encoding="utf-8")
                # Rewrite the first claim itself, not the first occurrence of
                # the version string: in AGENTS.md that is prose about how the
                # pinned toolchain behaves, which is deliberately not a claim.
                match = version.MOJO_PIN_CLAIM_RE.search(text)
                if match is None:
                    self.fail(f"{relative} states no toolchain claim to mutate")
                start, end = match.span(1)
                site.write_text(text[:start] + "0.0.0b0" + text[end:], encoding="utf-8")
                with self.assertRaisesRegex(AssertionError, r"0\.0\.0b0"):
                    version.check_mojo_pin_sites(root)

    def test_a_manifest_bump_that_forgets_the_recipes_is_rejected(self) -> None:
        """The shipped case: the package would request the old compiler."""
        with tempfile.TemporaryDirectory(prefix="mtest-pin-") as raw:
            root = Path(raw)
            self._clone(root)
            pixi = root / "pixi.toml"
            pinned = version._manifest_mojo_pin(pixi)
            pixi.write_text(
                pixi.read_text(encoding="utf-8").replace(
                    f'mojo = "=={pinned}', 'mojo = "==9.9.9b9', 1
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, "recipe/recipe.yaml"):
                version.check_mojo_pin_sites(root)

    def test_a_site_that_states_no_toolchain_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-pin-") as raw:
            root = Path(raw)
            self._clone(root)
            (root / "CONTRIBUTING.md").write_text("nothing here\n", encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "CONTRIBUTING.md"):
                version.check_mojo_pin_sites(root)

    def test_a_vanished_site_is_reported_not_crashed(self) -> None:
        """`main()` catches AssertionError only, so a deleted file must be one."""
        with tempfile.TemporaryDirectory(prefix="mtest-pin-") as raw:
            root = Path(raw)
            self._clone(root)
            (root / "CHANGELOG.md").unlink()
            with self.assertRaisesRegex(AssertionError, "cannot read"):
                version.check_mojo_pin_sites(root)

    def test_narration_about_the_pinned_toolchain_is_not_a_claim(self) -> None:
        """Prose about behavior at a version must not become a version site."""
        self.assertEqual(
            version.MOJO_PIN_CLAIM_RE.findall(
                "because 1.0.0b2 polymorphism is static, and `mojo package` "
                "does not exist in 1.0.0b2"
            ),
            [],
        )


class MojoPinSweepTests(unittest.TestCase):
    """The inverse sweep that stops a new page from claiming a toolchain."""

    def _repository(self, root: Path) -> None:
        """Build a temporary git repository holding the swept documents.

        Args:
            root: Empty directory to initialize as a repository.
        """
        subprocess.run(["git", "-C", str(root), "init", "-q"], check=True)
        tracked = (*version.swept_documentation(), Path("pixi.toml"))
        for relative in tracked:
            _clone_file(root, relative)
        subprocess.run(
            ["git", "-C", str(root), "add", "--", *(str(p) for p in tracked)],
            check=True,
        )

    def _track(self, root: Path, relative: str, text: str) -> None:
        """Write one extra document into the temporary repository and track it.

        Args:
            root: The temporary repository root.
            relative: Repository-relative path of the new document.
            text: Its contents.
        """
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        subprocess.run(["git", "-C", str(root), "add", "--", relative], check=True)

    def test_repository_documents_claim_only_the_pinned_toolchain(self) -> None:
        version.check_no_stale_mojo_pin_claims()

    def test_the_swept_set_is_the_reader_facing_documentation(self) -> None:
        """Named here so widening or narrowing the sweep is a reviewed diff."""
        swept = version.swept_documentation()
        self.assertIn(Path("README.md"), swept)
        self.assertIn(Path("docs/getting-started.md"), swept)
        self.assertIn(Path("docs/releasing.md"), swept)
        self.assertNotIn(
            Path(
                "docs/superpowers/specs/2026-07-23-test-confidence-hardening-design.md"
            ),
            swept,
        )
        for relative in swept:
            self.assertEqual(relative.suffix, ".md", relative)
            self.assertIn(len(relative.parts), (1, 2), relative)

    def test_every_markdown_pin_site_is_inside_the_swept_set(self) -> None:
        """The declared list and the sweep must not describe different sets."""
        swept = set(version.swept_documentation())
        for relative in version.MOJO_PIN_SITES:
            if relative.suffix == ".md":
                self.assertIn(relative, swept, relative)

    def test_a_new_page_claiming_another_toolchain_is_rejected(self) -> None:
        """The hole the hand-written site list cannot close on its own."""
        with tempfile.TemporaryDirectory(prefix="mtest-pin-sweep-") as raw:
            root = Path(raw)
            self._repository(root)
            self._track(
                root,
                "docs/tutorial.md",
                "# Tutorial\n\nThis release requires Mojo `1.0.0b1`.\n",
            )
            with self.assertRaisesRegex(AssertionError, r"1\.0\.0b1"):
                version.check_no_stale_mojo_pin_claims(root)

    def test_a_document_stating_no_toolchain_is_accepted(self) -> None:
        """A swept document may say nothing; only a false claim is a failure."""
        with tempfile.TemporaryDirectory(prefix="mtest-pin-sweep-") as raw:
            root = Path(raw)
            self._repository(root)
            self._track(root, "docs/tutorial.md", "# Tutorial\n\nNothing here.\n")
            version.check_no_stale_mojo_pin_claims(root)

    def test_an_untracked_draft_is_not_swept(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-pin-sweep-") as raw:
            root = Path(raw)
            self._repository(root)
            (root / "docs" / "draft.md").write_text(
                "Requires Mojo `1.0.0b1`.\n", encoding="utf-8"
            )
            version.check_no_stale_mojo_pin_claims(root)

    def test_an_internal_working_document_is_not_swept(self) -> None:
        """Nothing publishes them, so a stale claim inside one reaches no one."""
        with tempfile.TemporaryDirectory(prefix="mtest-pin-sweep-") as raw:
            root = Path(raw)
            self._repository(root)
            self._track(
                root,
                "docs/superpowers/specs/design.md",
                "Captured against Mojo `1.0.0b1`.\n",
            )
            version.check_no_stale_mojo_pin_claims(root)

    def test_a_manifest_bump_that_forgets_a_document_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-pin-sweep-") as raw:
            root = Path(raw)
            self._repository(root)
            pixi = root / "pixi.toml"
            pinned = version._manifest_mojo_pin(pixi)
            pixi.write_text(
                pixi.read_text(encoding="utf-8").replace(
                    f'mojo = "=={pinned}', 'mojo = "==9.9.9b9', 1
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, r"9\.9\.9b9"):
                version.check_no_stale_mojo_pin_claims(root)

    def test_a_tree_without_git_fails_closed(self) -> None:
        with (
            tempfile.TemporaryDirectory(prefix="mtest-pin-sweep-") as raw,
            self.assertRaisesRegex(AssertionError, "cannot list tracked files"),
        ):
            version.check_no_stale_mojo_pin_claims(Path(raw))


class SupportMatrixGateTests(unittest.TestCase):
    """The published support matrix against the toolchain actually pinned."""

    def _clone(self, root: Path) -> tuple[Path, Path]:
        """Copy the README and the pixi manifest into a temporary root.

        Args:
            root: Empty directory standing in for the repository root.

        Returns:
            The cloned README path and the cloned manifest path.
        """
        for relative in GATED_FILES:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(version.REPO_ROOT / relative, target)
        return root / "README.md", root / "pixi.toml"

    def test_repository_matrix_names_the_pinned_toolchain(self) -> None:
        version.check_support_matrix()

    def test_matrix_that_advertises_another_toolchain_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-matrix-") as raw:
            readme, pixi = self._clone(Path(raw))
            pinned = version._manifest_mojo_pin(pixi)
            readme.write_text(
                readme.read_text(encoding="utf-8").replace(
                    f"`{pinned}`", "`0.0.0b0`", 1
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, r"0\.0\.0b0"):
                version.check_support_matrix(Path(raw))

    def test_toolchain_bump_that_forgets_the_matrix_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-matrix-") as raw:
            readme, pixi = self._clone(Path(raw))
            pinned = version._manifest_mojo_pin(pixi)
            pixi.write_text(
                pixi.read_text(encoding="utf-8").replace(
                    f'mojo = "=={pinned}', 'mojo = "==9.9.9b9', 1
                ),
                encoding="utf-8",
            )
            self.assertNotEqual(readme.read_text(encoding="utf-8"), "")
            with self.assertRaisesRegex(AssertionError, r"9\.9\.9b9"):
                version.check_support_matrix(Path(raw))

    def test_matrix_that_lost_its_section_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-matrix-") as raw:
            readme, _ = self._clone(Path(raw))
            readme.write_text(
                readme.read_text(encoding="utf-8").replace(
                    version.SUPPORT_MATRIX_HEADING, "### Toolchains", 1
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, "Supported toolchains"):
                version.check_support_matrix(Path(raw))

    def test_manifest_that_stopped_pinning_exactly_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-matrix-") as raw:
            _, pixi = self._clone(Path(raw))
            pinned = version._manifest_mojo_pin(pixi)
            pixi.write_text(
                pixi.read_text(encoding="utf-8").replace(
                    f'mojo = "=={pinned}', f'mojo = ">={pinned}', 1
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, "mojo"):
                version.check_support_matrix(Path(raw))


if __name__ == "__main__":
    unittest.main()
