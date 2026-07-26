#!/usr/bin/env python3
"""Tests for the Python quality runner's mode, pinning, and failure policy.

The runner shells out to ruff and mypy, so these tests deliberately never
invoke either one. What is worth pinning is the runner's own decisions: that
check mode cannot rewrite a file, that it still runs the type checker, that
both tool versions stay exact, and that a missing `uvx` fails loudly instead of
reporting success.
"""

from __future__ import annotations

import contextlib
import io
import shutil
import tomllib
import unittest
from unittest import mock

from scripts.checks import python_quality


class QualityStepTests(unittest.TestCase):
    def test_check_mode_runs_the_three_verdict_steps_in_order(self) -> None:
        labels = [label for label, _ in python_quality.quality_steps(fix=False)]
        self.assertEqual(labels, ["ruff format --check", "ruff check", "mypy --strict"])

    def test_fix_mode_rewrites_and_skips_the_type_checker(self) -> None:
        labels = [label for label, _ in python_quality.quality_steps(fix=True)]
        self.assertEqual(labels, ["ruff format", "ruff check --fix"])

    def test_check_mode_cannot_rewrite_a_file(self) -> None:
        # The whole point of the two modes: a verdict run must be readonly, so
        # `pixi run py-check` can never quietly "fix" the drift it is reporting.
        for label, command in python_quality.quality_steps(fix=False):
            self.assertNotIn("--fix", command, label)
        formatter = next(
            command
            for label, command in python_quality.quality_steps(fix=False)
            if label.startswith("ruff format")
        )
        self.assertIn("--check", formatter)

    def test_every_step_pins_its_tool_version(self) -> None:
        # An unpinned `uvx ruff` reformats the tree on ruff's next release and
        # every later diff carries the churn.
        for fix in (False, True):
            for label, command in python_quality.quality_steps(fix=fix):
                self.assertEqual(command[0], "uvx", label)
                exact = {
                    f"ruff@{python_quality.RUFF_VERSION}",
                    f"mypy=={python_quality.MYPY_VERSION}",
                }
                pinned = any(word in exact for word in command)
                self.assertTrue(pinned, f"{label} runs an unpinned tool: {command}")

    def test_mypy_reads_its_own_file_set_from_the_config(self) -> None:
        # mypy is invoked with no path operands on purpose: pyproject.toml owns
        # the file set, so the runner and the config cannot disagree.
        mypy_step = next(
            command
            for label, command in python_quality.quality_steps(fix=False)
            if label == "mypy --strict"
        )
        self.assertEqual(mypy_step, python_quality.MYPY)
        with (python_quality.REPO_ROOT / "pyproject.toml").open("rb") as handle:
            config = tomllib.load(handle)
        mypy_config = config["tool"]["mypy"]
        self.assertTrue(mypy_config["strict"])
        self.assertEqual(mypy_config["files"], list(python_quality.TARGETS))


class QualityMainTests(unittest.TestCase):
    def _run(self, argv: list[str]) -> tuple[int, str, str]:
        """Run `main` with both streams captured."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = python_quality.main(argv)
        return status, out.getvalue(), err.getvalue()

    def test_an_unexpected_flag_is_rejected_before_any_tool_runs(self) -> None:
        status, out, err = self._run(["--check"])
        self.assertEqual(status, 1)
        self.assertEqual(out, "")
        self.assertIn("unexpected arguments", err)

    def test_a_missing_uvx_fails_loudly_instead_of_skipping(self) -> None:
        # A check that passes when its tool is absent is worse than no check.
        with mock.patch.object(shutil, "which", return_value=None):
            status, out, err = self._run([])
        self.assertEqual(status, 1)
        self.assertEqual(out, "")
        self.assertIn("uvx not found", err)
        self.assertIn("not part of `pixi run ci`", err)


class QualityWiringTests(unittest.TestCase):
    def test_the_pixi_tasks_invoke_this_module(self) -> None:
        with (python_quality.REPO_ROOT / "pixi.toml").open("rb") as handle:
            tasks = tomllib.load(handle)["tasks"]
        self.assertEqual(
            tasks.get("py-check"), "python -m scripts.checks.python_quality"
        )
        self.assertEqual(
            tasks.get("py-fmt"), "python -m scripts.checks.python_quality --fix"
        )

    def test_the_quality_check_stays_outside_the_ci_floor(self) -> None:
        # ruff and mypy run through uvx so they are not pixi dependencies, which
        # means `uv` is a contributor's own install rather than something the
        # gate may assume. Keeping py-check out of `ci` is what stops a green
        # floor from depending on a tool the environment does not pin.
        from scripts.checks import ci_topology

        self.assertNotIn("py-check", ci_topology.CI_TASKS)
        self.assertNotIn("py-check", ci_topology.CI_PREFLIGHT_TASKS)
        self.assertNotIn("py-check", ci_topology.LINUX_CI_FLOOR_TASKS)
        self.assertNotIn("py-fmt", ci_topology.LINUX_CI_FLOOR_TASKS)
        workflow = (
            python_quality.REPO_ROOT / ".github" / "workflows" / "ci.yml"
        ).read_text(encoding="utf-8")
        self.assertNotIn("py-check", workflow)

    def test_the_config_lives_where_both_tools_read_it(self) -> None:
        pyproject = python_quality.REPO_ROOT / "pyproject.toml"
        self.assertTrue(pyproject.is_file())
        with pyproject.open("rb") as handle:
            config = tomllib.load(handle)
        # No [project] or [build-system]: this repo is not a Python package, and
        # pixi.toml is the workspace manifest.
        self.assertNotIn("project", config)
        self.assertNotIn("build-system", config)
        self.assertIn("ruff", config["tool"])
        self.assertIn("mypy", config["tool"])

    def test_every_ruff_exclusion_is_justified_in_place(self) -> None:
        # A bare ignore list is how a rule set rots. Each entry must sit under a
        # comment saying why, so the next reader can re-litigate it.
        source = (python_quality.REPO_ROOT / "pyproject.toml").read_text(
            encoding="utf-8"
        )
        block = source.split("ignore = [", 1)[1].split("\n]", 1)[0]
        lines = [line.strip() for line in block.splitlines() if line.strip()]
        unjustified: list[str] = []
        commented = False
        for line in lines:
            if line.startswith("#"):
                commented = True
                continue
            if not commented:
                unjustified.append(line)
        self.assertEqual(unjustified, [], "ruff ignores without a reason comment")


if __name__ == "__main__":
    unittest.main()
