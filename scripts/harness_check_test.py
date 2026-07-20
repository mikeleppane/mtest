#!/usr/bin/env python3
"""Unit tests for independent repository-harness policy checks."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from scripts import aggregate_tests
from scripts import harness_check


class AggregateMembershipOracleTests(unittest.TestCase):
    def _fixture(self, repo: Path) -> tuple[str, ...]:
        relative = "tests/unit/test_probe.mojo"
        source = repo / relative
        source.parent.mkdir(parents=True)
        source.write_text(
            "def test_alpha():\n    pass\n\n"
            "def test_beta() raises:\n    pass\n",
            encoding="utf-8",
        )
        return (relative,)

    def test_oracle_reads_source_without_aggregate_parser(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            paths = self._fixture(repo)

            with mock.patch.object(
                aggregate_tests,
                "test_function_names",
                return_value=["test_wrong_a", "test_wrong_b"],
            ):
                membership = harness_check.independent_registration_membership(
                    repo, paths
                )

        self.assertEqual(
            membership,
            (
                ("tests/unit/test_probe.mojo", "test_alpha"),
                ("tests/unit/test_probe.mojo", "test_beta"),
            ),
        )

    def test_same_count_loader_substitution_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            paths = self._fixture(repo)

            with mock.patch.object(
                aggregate_tests,
                "test_function_names",
                return_value=["test_alpha", "test_gamma"],
            ):
                with self.assertRaisesRegex(
                    AssertionError, "registration membership/order"
                ):
                    harness_check.check_classified_entrypoint(
                        repo, paths, expected_count=2
                    )

    def test_same_count_loader_reordering_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            paths = self._fixture(repo)

            with mock.patch.object(
                aggregate_tests,
                "test_function_names",
                return_value=["test_beta", "test_alpha"],
            ):
                with self.assertRaisesRegex(
                    AssertionError, "registration membership/order"
                ):
                    harness_check.check_classified_entrypoint(
                        repo, paths, expected_count=2
                    )


class DirectInvocationPolicyTests(unittest.TestCase):
    SCRIPT_PATH = "scripts" + "/probe.py"

    def test_optioned_and_absolute_interpreters_are_rejected(self) -> None:
        forms = (
            f"python -u {self.SCRIPT_PATH}",
            f"/usr/bin/python {self.SCRIPT_PATH}",
        )

        for form in forms:
            with self.subTest(form=form):
                self.assertTrue(
                    harness_check.direct_script_invocations(
                        Path("README.md"), form
                    )
                )

    def test_sys_executable_argv_is_rejected(self) -> None:
        source = (
            "import subprocess\n"
            "import sys\n"
            "subprocess.run([sys.executable, "
            + repr(self.SCRIPT_PATH)
            + "])\n"
        )

        self.assertTrue(
            harness_check.direct_script_invocations(
                Path("scripts/caller.py"), source
            )
        )

    def test_dot_relative_script_operands_are_rejected(self) -> None:
        operand = "./" + self.SCRIPT_PATH
        cases = (
            (Path("README.md"), f"python {operand}"),
            (
                Path("scripts/caller.py"),
                "import subprocess\n"
                "import sys\n"
                "subprocess.run([sys.executable, "
                + repr(operand)
                + "])\n",
            ),
        )

        for path, contents in cases:
            with self.subTest(path=path):
                self.assertTrue(
                    harness_check.direct_script_invocations(path, contents)
                )

    def test_module_invocation_is_accepted(self) -> None:
        self.assertFalse(
            harness_check.direct_script_invocations(
                Path("README.md"), "python -u -m scripts.probe"
            )
        )

    def test_live_scope_excludes_historical_notes(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            live = repo / "README.md"
            historical = repo / "notes" / "phase-00-history.md"
            historical.parent.mkdir(parents=True)
            live.write_text("python -m scripts.probe\n", encoding="utf-8")
            historical.write_text(
                f"python -u {self.SCRIPT_PATH}\n", encoding="utf-8"
            )

            files = harness_check.live_command_files(repo)
            violations = harness_check.live_direct_invocations(repo)

        self.assertEqual(files, (Path("README.md"),))
        self.assertEqual(violations, ())

    def test_each_live_surface_is_checked(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            relative_paths = (
                Path("README.md"),
                Path("AGENTS.md"),
                Path("pixi.toml"),
                Path("scripts/probe.py"),
                Path("src/probe.mojo"),
                Path("tests/probe.mojo"),
                Path("e2e/probe.mojo"),
                Path("native/probe.c"),
                Path(".github/workflows/ci.yml"),
                Path("recipe/build.sh"),
                Path(".agents/skills/example/SKILL.md"),
                Path("notes/console-captures/README.md"),
            )
            for index, relative in enumerate(relative_paths):
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                command = f"/usr/bin/python -u {self.SCRIPT_PATH}"
                if relative.suffix == ".py":
                    command = "# " + command
                path.write_text(command + f" # {index}\n", encoding="utf-8")

            files = harness_check.live_command_files(repo)
            violations = harness_check.live_direct_invocations(repo)

        self.assertEqual(set(files), set(relative_paths))
        self.assertEqual(
            {violation.split(":", 1)[0] for violation in violations},
            {path.as_posix() for path in relative_paths},
        )


class BuildSourceVisibilityTests(unittest.TestCase):
    def _repo(self, root: Path, ignore_rule: str) -> None:
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        (root / ".gitignore").write_text(ignore_rule + "\n", encoding="utf-8")
        for relative in harness_check.BUILD_SOURCE_PATHS:
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("# fixture\n", encoding="utf-8")

    def test_unanchored_build_ignore_rejects_source_package(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            self._repo(repo, "build/")

            with self.assertRaisesRegex(AssertionError, "ignored"):
                harness_check.check_build_source_visibility(repo)

    def test_untracked_build_source_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            self._repo(repo, "/build/")
            subprocess.run(
                ["git", "-C", str(repo), "add", ".gitignore"], check=True
            )

            with self.assertRaisesRegex(AssertionError, "untracked"):
                harness_check.check_build_source_visibility(repo)


if __name__ == "__main__":
    unittest.main()
