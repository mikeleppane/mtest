#!/usr/bin/env python3
"""Tests for the pinned documentation-site build.

The build itself fetches a documentation tool and renders a site, which is why
`build_command` and `missing_uvx` are public: the two properties worth pinning
are what the build asks for and what it does when the tool is absent, and both
are answerable without a network, a cache, or an output directory.

What these tests hold is the pinning itself. The published site is meant to be a
property of the tree rather than of the day, and a floating version would change
every page in it on its own release schedule with no diff here to explain the
change. A version bump is a deliberate act, so it costs an edit in two places.
"""

from __future__ import annotations

import contextlib
import io
from pathlib import Path
import unittest
from unittest import mock

from scripts.docs import build_site


UVX_LOOKUP = f"{build_site.__name__}.shutil.which"
"""Where the module looks for `uvx`, patched instead of the real PATH."""

MKDOCS_RUN = f"{build_site.__name__}.subprocess.run"
"""Where the module spawns the build, patched so no site is ever rendered."""


class BuildCommandTests(unittest.TestCase):
    """The argv that builds the site names exact versions and stays strict."""

    def test_documentation_tool_versions_are_pinned_exactly(self) -> None:
        self.assertEqual(build_site.MKDOCS_VERSION, "1.6.1")
        self.assertEqual(build_site.MKDOCS_MATERIAL_VERSION, "9.6.14")
        for pin in build_site.MKDOCS:
            if "==" in pin:
                requirement, version = pin.split("==", 1)
                self.assertTrue(version, requirement)
                self.assertNotIn(",", version, requirement)
                self.assertNotIn(">", pin, requirement)
                self.assertNotIn("<", pin, requirement)

    def test_default_command_is_strict_and_leaves_the_output_location_alone(
        self,
    ) -> None:
        self.assertEqual(
            build_site.build_command(),
            (
                "uvx",
                "--from",
                "mkdocs==1.6.1",
                "--with",
                "mkdocs-material==9.6.14",
                "mkdocs",
                "build",
                "--strict",
            ),
        )

    def test_site_dir_override_is_passed_through(self) -> None:
        command = build_site.build_command(site_dir=Path("/tmp/mtest-site"))
        self.assertEqual(command[-2:], ("--site-dir", "/tmp/mtest-site"))
        self.assertIn("--strict", command)

    def test_strictness_is_the_only_thing_a_caller_can_drop(self) -> None:
        relaxed = build_site.build_command(strict=False)
        self.assertNotIn("--strict", relaxed)
        self.assertEqual(relaxed, (*build_site.MKDOCS, "build"))
        self.assertEqual(
            build_site.build_command(),
            (*relaxed, "--strict"),
        )


class MissingToolTests(unittest.TestCase):
    """A build that cannot start says so and names the remedy."""

    def test_present_tool_reports_nothing(self) -> None:
        with mock.patch(UVX_LOOKUP, return_value="/usr/bin/uvx"):
            self.assertIsNone(build_site.missing_uvx())

    def test_absent_tool_reports_an_actionable_message(self) -> None:
        with mock.patch(UVX_LOOKUP, return_value=None) as which:
            message = build_site.missing_uvx()
        which.assert_called_once_with("uvx")
        self.assertEqual(message, build_site.UVX_REMEDY)
        self.assertIn("FATAL", str(message))
        self.assertIn("uv", str(message))

    def test_build_raises_instead_of_skipping_when_the_tool_is_absent(self) -> None:
        with (
            mock.patch.object(build_site, "missing_uvx", return_value="no uvx"),
            mock.patch(MKDOCS_RUN) as run,
            self.assertRaisesRegex(build_site.SiteBuildError, "no uvx"),
        ):
            build_site.build()
        run.assert_not_called()

    def test_nonzero_build_is_a_failure_carrying_the_exit_status(self) -> None:
        announced = io.StringIO()
        with (
            mock.patch.object(build_site, "missing_uvx", return_value=None),
            mock.patch(
                MKDOCS_RUN,
                return_value=mock.Mock(returncode=3),
            ),
            contextlib.redirect_stdout(announced),
            self.assertRaisesRegex(build_site.SiteBuildError, "exit 3"),
        ):
            build_site.build()
        self.assertIn(" ".join(build_site.build_command()), announced.getvalue())


class EntryPointTests(unittest.TestCase):
    """The module entry point takes no arguments and reports a shell status.

    The entry point writes to stdout and stderr, and this suite runs inside a
    gate whose log is read on a red run, so each case captures what its call
    printed rather than scattering it through the gate's output.
    """

    def _main(self, argv: list[str]) -> tuple[int, str, str]:
        """Run the entry point, returning its status and captured streams.

        Args:
            argv: Arguments after the module name.

        Returns:
            The shell status, everything written to stdout, and everything
            written to stderr.
        """
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = build_site.main(argv)
        return status, out.getvalue(), err.getvalue()

    def test_successful_build_exits_zero(self) -> None:
        with mock.patch.object(build_site, "build") as build:
            status, out, _ = self._main([])
        self.assertEqual(status, 0)
        self.assertIn("strict", out)
        build.assert_called_once_with()

    def test_failed_build_exits_nonzero(self) -> None:
        with mock.patch.object(
            build_site,
            "build",
            side_effect=build_site.SiteBuildError("broken link"),
        ):
            status, _, err = self._main([])
        self.assertEqual(status, 1)
        self.assertIn("broken link", err)

    def test_arguments_are_refused_rather_than_ignored(self) -> None:
        with mock.patch.object(build_site, "build") as build:
            status, _, err = self._main(["--site-dir", "/tmp/elsewhere"])
        self.assertEqual(status, 1)
        self.assertIn("--site-dir", err)
        build.assert_not_called()


if __name__ == "__main__":
    unittest.main()
