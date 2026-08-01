#!/usr/bin/env python3
"""Prove the bump tool still writes every site the version gate enforces.

`scripts/release/bump.py` is the write side of `scripts/checks/version.py`, and
nothing else imports it: a release is the first thing that would notice a
broken site list, which is the worst moment to find out. These tests hold the
writer and the gate to one definition of what a public transcript site is.
"""

from __future__ import annotations

from pathlib import Path
import unittest

from scripts.checks import version
from scripts.release import bump


class BumpSiteTests(unittest.TestCase):
    """The writer's site list, and its agreement with the gate."""

    def _relative_paths(self) -> tuple[Path, ...]:
        """Return every bump site as a repository-relative path, in order."""
        return tuple(site.path.relative_to(bump.REPO_ROOT) for site in bump.SITES)

    def test_sites_name_the_nine_files_that_carry_the_release(self) -> None:
        self.assertEqual(
            self._relative_paths(),
            (
                Path("src/mtest/cli/parser.mojo"),
                Path("pixi.toml"),
                Path("recipe/recipe.yaml"),
                Path("scripts/checks/version.py"),
                Path("scripts/qa/contract.py"),
                Path("README.md"),
                Path("docs/cli-contract.md"),
                Path("docs/assets/mtest-run.svg"),
                Path("docs/assets/mtest-flaky.svg"),
            ),
        )

    def test_no_file_is_named_twice(self) -> None:
        relative = self._relative_paths()
        self.assertEqual(len(set(relative)), len(relative))

    def test_every_declared_site_exists(self) -> None:
        for site in bump.SITES:
            self.assertTrue(site.path.is_file(), site.path)

    def test_every_site_holds_the_release_version(self) -> None:
        self.assertEqual(bump.current_version(), version.EXPECTED_VERSION)

    def test_each_gated_site_is_written_with_the_gates_own_pattern(self) -> None:
        """The writer reuses the gate's pattern object rather than a copy of it.

        This holds by construction while `bump.SITES` is built from
        `TRANSCRIPT_SITES`, and it exists to fail the day someone reintroduces a
        local pattern there. The direction that can catch a real divergence
        today is `test_sites_name_the_nine_files_that_carry_the_release`, which
        pins the writer's list against literal paths rather than against the
        gate.
        """
        written = {
            site.path.relative_to(bump.REPO_ROOT): site.pattern for site in bump.SITES
        }
        for relative in version.TRANSCRIPT_SITES:
            self.assertIn(relative, written)
            self.assertIs(written[relative], version.TRANSCRIPT_RE)

    def test_the_writer_declares_no_transcript_site_the_gate_does_not(self) -> None:
        """A site written with the gate's pattern but ungated would drift."""
        written = {
            site.path.relative_to(bump.REPO_ROOT)
            for site in bump.SITES
            if site.pattern is version.TRANSCRIPT_RE
        }
        self.assertEqual(written, set(version.TRANSCRIPT_SITES))


if __name__ == "__main__":
    unittest.main()
