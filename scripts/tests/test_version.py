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
import tempfile
import unittest

from scripts.checks import version


GATED_FILES = (*version.TRANSCRIPT_SITES, Path("pixi.toml"))


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
