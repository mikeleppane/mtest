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
import subprocess
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
        self.assertEqual(labels, ["ruff check --fix", "ruff format"])

    def test_fix_mode_lints_before_it_formats(self) -> None:
        # Not a style preference; the reverse order makes py-fmt lie. Formatting
        # first, then fixing, leaves the formatter's own work stale: `ruff check
        # --fix` deleting an unused import leaves the two blank lines that
        # followed it, and nothing collapses them. py-fmt exits 0 and the very
        # next `pixi run py-check` reds on `ruff format --check`, which is the
        # one thing py-fmt exists to prevent. Reproduced against ruff 0.16.0.
        labels = [label for label, _ in python_quality.quality_steps(fix=True)]
        self.assertLess(
            labels.index("ruff check --fix"),
            labels.index("ruff format"),
            "fix mode must lint before it formats, or py-fmt can exit 0 on a "
            "tree that py-check rejects",
        )

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
        #
        # `ci-memory` is a plain command string in the base [tasks] table and
        # only gains its real `depends-on` (the asan/valgrind lanes) under
        # [target.linux-64.tasks], which silently replaces the base entry for
        # that one platform. Walking the base table alone stops at
        # `ci-memory` and never reaches the memory lanes at all — so this
        # merges the linux-64 override over the base table first before
        # walking the closure. That the override table can only ever hold such
        # a dependency-only edge, and only for a bounded set of task names, is
        # `layout.check_platform_task_overrides`'s property, not this test's.
        # Skipping instead of raising on a dependency shape this
        # module does not expect (Pixi also allows table-form dependency
        # entries) would make the closure shrink quietly; raise instead.
        with (python_quality.REPO_ROOT / "pixi.toml").open("rb") as handle:
            manifest = tomllib.load(handle)
        base_tasks = manifest["tasks"]
        linux_overrides = manifest["target"]["linux-64"]["tasks"]
        tasks = {**base_tasks, **linux_overrides}
        closure: set[str] = set()
        pending = ["ci"]
        while pending:
            name = pending.pop()
            if name in closure:
                continue
            closure.add(name)
            task = tasks.get(name)
            if isinstance(task, dict):
                dependencies = task.get("depends-on", [])
                if not isinstance(dependencies, list) or not all(
                    isinstance(dependency, str) for dependency in dependencies
                ):
                    raise AssertionError(
                        f"pixi task {name!r} has a dependency list this test "
                        f"does not understand: {dependencies!r}"
                    )
                pending.extend(dependencies)
        self.assertNotIn("py-check", closure)
        self.assertNotIn("py-fmt", closure)
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

    def _pyproject_source(self) -> str:
        """The manifest's text, for the checks that read its comments."""
        return (python_quality.REPO_ROOT / "pyproject.toml").read_text(encoding="utf-8")

    def test_every_ruff_exclusion_carries_a_reason_comment(self) -> None:
        # The ignore list itself is not restated here: changing it IS an edit to
        # pyproject.toml, visible in the diff beside the reason it carries, and
        # a re-typed copy of a config file is the textbook case the pruning
        # criterion deletes. What a diff does not enforce is that the prose
        # survives, so this counts it rather than reading positions -- a shared
        # reason paragraph over a group of related codes is fine.
        source = self._pyproject_source()
        self.assertEqual(source.count("ignore = ["), 1)
        block = source.split("ignore = [", 1)[1].split("\n]", 1)[0]
        lines = [line.strip() for line in block.splitlines() if line.strip()]
        comments = [line for line in lines if line.startswith("#")]
        entries = [line for line in lines if not line.startswith("#")]
        self.assertTrue(entries, "expected ignore entries")
        # Every group needs prose, and the first line in the block must be one.
        self.assertTrue(
            lines[0].startswith("#"), "the ignore list must open with a reason"
        )
        self.assertGreaterEqual(
            len(comments),
            10,
            "the ignore list lost its reason comments; each group must say why",
        )

    def test_ruff_excludes_are_root_anchored(self) -> None:
        # A ruff exclude with no path separator matches ANY path component, so a
        # bare "build" also excludes scripts/build/ — which hid three files from
        # both lint and format while py-check printed "clean". "/build" is not
        # the fix: it excludes nothing. Only "./build" (or "build/") is anchored.
        with (python_quality.REPO_ROOT / "pyproject.toml").open("rb") as handle:
            config = tomllib.load(handle)
        excludes = config["tool"]["ruff"]["extend-exclude"]
        self.assertTrue(excludes, "expected at least one exclude to pin")
        for pattern in excludes:
            self.assertTrue(
                pattern.startswith("./"),
                f"ruff exclude {pattern!r} is not root-anchored, so it matches "
                "that name at ANY depth and can silently drop real source",
            )

    def test_no_tracked_python_file_falls_inside_an_excluded_root(self) -> None:
        # The coverage pin, deliberately tool-free: harness-check runs where uv
        # is absent, so this cannot shell out to ruff. Given the anchored
        # patterns above, ruff's file set is every tracked .py outside these
        # roots, so this is what would have caught scripts/build/ going dark.
        with (python_quality.REPO_ROOT / "pyproject.toml").open("rb") as handle:
            config = tomllib.load(handle)
        roots = [
            pattern.removeprefix("./").rstrip("/")
            for pattern in config["tool"]["ruff"]["extend-exclude"]
        ]
        tracked = subprocess.run(
            ["git", "ls-files", "*.py"],
            cwd=python_quality.REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.split()
        self.assertTrue(tracked, "expected tracked Python files")
        hidden = [
            path
            for path in tracked
            if any(path == root or path.startswith(f"{root}/") for root in roots)
        ]
        self.assertEqual(
            hidden, [], "tracked Python files sit inside a ruff-excluded root"
        )
        # And the roots ruff is told to skip must be the ones that actually hold
        # generated or vendored trees, not a typo that silently covers nothing.
        for root in roots:
            self.assertNotIn(
                "/", root, f"exclude root {root!r} should name a top-level tree"
            )


if __name__ == "__main__":
    unittest.main()
