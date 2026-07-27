#!/usr/bin/env python3
"""Unit tests for independent repository-harness policy checks."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from scripts.build import package_consumption
from scripts.checks import layout
from scripts.harness import aggregate


class LayoutInventoryPolicyTests(unittest.TestCase):
    def test_repository_root_tracks_the_nested_checker(self) -> None:
        self.assertEqual(layout.REPO_ROOT, Path(__file__).resolve().parents[2])

    def test_every_intended_inventory_fails_closed_when_empty(self) -> None:
        cases = (
            ("TOP_LEVEL_SCRIPT_FILES", layout.check_top_level_script_layout),
            ("UNIT_SUITES", layout.check_suite_layout),
            ("INTEGRATION_SUITES", layout.check_suite_layout),
            ("CLASSIFIED_PATHS", layout.check_suite_layout),
            ("CLASSIFIED_ROOTS", layout.check_suite_layout),
            ("CLASSIFIED_PACKAGE_MARKERS", layout.check_suite_layout),
            ("SUPPORT_MODULES", layout.check_suite_layout),
            ("EXEC_FIXTURES", layout.check_exec_fixture_layout),
            ("E2E_NATIVE_FIXTURES", layout.check_e2e_native_fixture_layout),
            ("PROTOCOL_FIXTURES", layout.check_protocol_asset_layout),
            ("E2E_SCENARIO_NAMES", layout.check_e2e_layout),
            ("E2E_HARNESS_PATHS", layout.check_e2e_layout),
            ("BUILD_SOURCE_PATHS", layout.check_build_source_visibility),
            ("ASSERTION_SOURCE_PATHS", layout.check_assertion_companion_layout),
            ("ASSERTION_CONSUMER_PATHS", layout.check_assertion_companion_layout),
            ("ASSERTION_CHECK_PATHS", layout.check_assertion_companion_layout),
            ("ASSERTION_EXAMPLE_PATHS", layout.check_assertion_companion_layout),
            ("VENDORED_TOML_PATHS", layout.check_vendored_toml_layout),
        )
        for name, check in cases:
            with (
                self.subTest(inventory=name),
                mock.patch.object(layout, name, ()),
                self.assertRaisesRegex(AssertionError, "intended inventory is empty"),
            ):
                check()

    def test_top_level_script_membership_is_exact(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-layout-") as raw_tmp:
            repo = Path(raw_tmp)
            for relative in layout.TOP_LEVEL_SCRIPT_FILES:
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("# fixture\n", encoding="utf-8")

            layout.check_top_level_script_layout(repo)
            extra = repo / "scripts" / "unexpected.py"
            extra.write_text("# accidental top-level tool\n", encoding="utf-8")

            with self.assertRaisesRegex(
                AssertionError,
                "top-level scripts membership mismatch",
            ):
                layout.check_top_level_script_layout(repo)

    def test_exec_fixture_membership_exempts_only_the_bytecode_cache(self) -> None:
        """`__pycache__` is tolerated; nothing else unlisted is.

        The harness imports an exec actor as a module to predict its payload,
        which makes CPython write that directory. The gate must survive it
        without becoming a gate that tolerates unlisted actors.
        """
        with tempfile.TemporaryDirectory(prefix="mtest-layout-exec-") as raw_tmp:
            repo = Path(raw_tmp)
            fixtures = repo / "tests" / "fixtures" / "exec"
            fixtures.mkdir(parents=True)
            for name in layout.EXEC_FIXTURES:
                (fixtures / name).write_text("# fixture\n", encoding="utf-8")

            with mock.patch.object(layout, "REPO_ROOT", repo):
                layout.check_exec_fixture_layout()
                (fixtures / "__pycache__").mkdir()
                layout.check_exec_fixture_layout()

                (fixtures / "unlisted_actor.py").write_text("", encoding="utf-8")
                with self.assertRaisesRegex(
                    AssertionError, "exec fixture membership mismatch"
                ):
                    layout.check_exec_fixture_layout()

    def test_assertion_companion_membership_is_exact(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-layout-") as raw_tmp:
            repo = Path(raw_tmp)
            for relative in (
                *layout.ASSERTION_SOURCE_PATHS,
                *layout.ASSERTION_CONSUMER_PATHS,
                *layout.ASSERTION_CHECK_PATHS,
                *layout.ASSERTION_EXAMPLE_PATHS,
            ):
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("# fixture\n", encoding="utf-8")
            for script_name in ("scripts/build/production_build.sh",):
                path = repo / script_name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("# no assertion precompile\n", encoding="utf-8")
            recipe = repo / "recipe" / "build.sh"
            recipe.parent.mkdir(parents=True, exist_ok=True)
            recipe_contents = "# no assertion precompile\n" + "".join(
                f"install -m 644 {relative} destination\n"
                for relative in layout.ASSERTION_SOURCE_PATHS
            )
            recipe.write_text(recipe_contents, encoding="utf-8")

            layout.check_assertion_companion_layout(repo)
            expected_leaf = repo / next(iter(layout.ASSERTION_SOURCE_PATHS))
            expected_leaf.unlink()
            expected_leaf.mkdir()
            with self.assertRaisesRegex(
                AssertionError,
                "assertion companion leaf is not a regular file",
            ):
                layout.check_assertion_companion_layout(repo)
            expected_leaf.rmdir()
            expected_leaf.write_text("# fixture\n", encoding="utf-8")

            unregistered_example = repo / "companions/assertions/unexpected.mojo"
            unregistered_example.parent.mkdir(parents=True, exist_ok=True)
            unregistered_example.write_text("# accidental example\n", encoding="utf-8")
            with self.assertRaisesRegex(
                AssertionError,
                "assertion companion membership mismatch",
            ):
                layout.check_assertion_companion_layout(repo)
            unregistered_example.unlink()

            unregistered_consumer = repo / "tests/assertions/unexpected.mojo"
            unregistered_consumer.write_text(
                "# accidental consumer\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(
                AssertionError,
                "assertion consumer membership mismatch",
            ):
                layout.check_assertion_companion_layout(repo)
            unregistered_consumer.unlink()

            companion_target = repo / "outside-companion.mojo"
            companion_target.write_text("# external\n", encoding="utf-8")
            expected_leaf.unlink()
            expected_leaf.symlink_to(companion_target)
            with self.assertRaisesRegex(AssertionError, "contains symlinks"):
                layout.check_assertion_companion_layout(repo)
            expected_leaf.unlink()
            expected_leaf.write_text("# fixture\n", encoding="utf-8")

            expected_consumer = repo / next(iter(layout.ASSERTION_CONSUMER_PATHS))
            consumer_target = repo / "outside-consumer.mojo"
            consumer_target.write_text("# external\n", encoding="utf-8")
            expected_consumer.unlink()
            expected_consumer.symlink_to(consumer_target)
            with self.assertRaisesRegex(AssertionError, "contains symlinks"):
                layout.check_assertion_companion_layout(repo)
            expected_consumer.unlink()
            expected_consumer.write_text("# fixture\n", encoding="utf-8")

            recipe.write_text(
                recipe_contents
                + "mojo precompile companions/assertions/src/mtest/__init__.mojo\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, "precompiles"):
                layout.check_assertion_companion_layout(repo)

            for recursive_copy in (
                "cp -r companions/assertions destination\n",
                "cp\t-R companions/assertions destination\n",
                "cp -pr companions/assertions destination\n",
                "cp -aR companions/assertions destination\n",
                "cp --recursive companions/assertions destination\n",
            ):
                with self.subTest(recursive_copy=recursive_copy):
                    recipe.write_text(
                        recipe_contents + recursive_copy,
                        encoding="utf-8",
                    )
                    with self.assertRaisesRegex(
                        AssertionError, "recursive source copy"
                    ):
                        layout.check_assertion_companion_layout(repo)
            recipe.write_text(
                recipe_contents + "scp -r companions/assertions destination\n",
                encoding="utf-8",
            )
            layout.check_assertion_companion_layout(repo)

            missing_install = next(iter(layout.ASSERTION_SOURCE_PATHS))
            recipe.write_text(
                recipe_contents.replace(
                    f"install -m 644 {missing_install} destination\n", ""
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, "recipe install membership"):
                layout.check_assertion_companion_layout(repo)
            recipe.write_text(recipe_contents, encoding="utf-8")

            with (
                mock.patch.object(
                    package_consumption,
                    "INSTALLED_ASSERTION_FILES",
                    {Path("mtest/__init__.mojo")},
                ),
                self.assertRaisesRegex(
                    AssertionError,
                    "assertion package-check membership mismatch",
                ),
            ):
                layout.check_assertion_companion_layout(repo)

            extra = (
                repo
                / "companions/assertions/src"
                / "mtest"
                / "assertions"
                / "unexpected.mojo"
            )
            extra.write_text("# accidental public module\n", encoding="utf-8")

            with self.assertRaisesRegex(
                AssertionError,
                "assertion companion membership mismatch",
            ):
                layout.check_assertion_companion_layout(repo)


class ClassifiedMojoUniverseTests(unittest.TestCase):
    """The classified roots hold exactly the registered Mojo files, and no links."""

    SOLE_SUITE = "tests/unit/test_probe.mojo"

    def _accepted_tree(self, repo: Path) -> None:
        """Create both package markers plus the one registered classified suite."""
        for relative in (
            "tests/unit/__init__.mojo",
            "tests/integration/__init__.mojo",
            self.SOLE_SUITE,
        ):
            path = repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("def test_probe():\n    pass\n", encoding="utf-8")

    def test_universe_separates_regular_mojo_files_from_symlinked_entries(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            self._accepted_tree(repo)
            for relative in (
                "tests/unit/session_shard_test.mojo",
                "tests/integration/test_probe.mojo.disabled",
                "tests/unit/helper.mojo",
                "outside.mojo",
                "tests/unit/notes.txt",
            ):
                (repo / relative).write_text("", encoding="utf-8")
            os.symlink(repo / "outside.mojo", repo / "tests/unit/test_link.mojo")
            os.symlink(repo / "tests" / "integration", repo / "tests/unit/linked")

            regular, symlinked = layout.classified_mojo_universe(repo)

        self.assertEqual(
            regular,
            {
                Path("tests/unit/__init__.mojo"),
                Path("tests/unit/test_probe.mojo"),
                Path("tests/unit/session_shard_test.mojo"),
                Path("tests/unit/helper.mojo"),
                Path("tests/integration/__init__.mojo"),
                Path("tests/integration/test_probe.mojo.disabled"),
            },
        )
        self.assertEqual(
            symlinked,
            {Path("tests/unit/test_link.mojo"), Path("tests/unit/linked")},
        )

    def test_registered_suites_and_package_markers_are_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            self._accepted_tree(repo)

            with mock.patch.object(layout, "CLASSIFIED_PATHS", (self.SOLE_SUITE,)):
                layout.check_classified_mojo_inventory(repo)

    def test_every_unregistered_mojo_name_is_rejected(self) -> None:
        cases = (
            "tests/unit/session_shard_test.mojo",
            "tests/integration/test_probe.mojo.disabled",
            "tests/unit/helper.mojo",
        )
        for relative in cases:
            with (
                self.subTest(escape=relative),
                tempfile.TemporaryDirectory() as raw_tmp,
            ):
                repo = Path(raw_tmp)
                self._accepted_tree(repo)
                (repo / relative).write_text("", encoding="utf-8")

                with (
                    mock.patch.object(layout, "CLASSIFIED_PATHS", (self.SOLE_SUITE,)),
                    self.assertRaisesRegex(
                        AssertionError, "unexpected classified Mojo file"
                    ),
                ):
                    layout.check_classified_mojo_inventory(repo)

    def test_symlinked_classified_paths_are_rejected(self) -> None:
        cases = (
            ("tests/unit/test_link.mojo", "outside.mojo"),
            ("tests/unit/linked", "tests/integration"),
        )
        for relative, target in cases:
            with (
                self.subTest(link=relative),
                tempfile.TemporaryDirectory() as raw_tmp,
            ):
                repo = Path(raw_tmp)
                self._accepted_tree(repo)
                (repo / "outside.mojo").write_text("", encoding="utf-8")
                os.symlink(repo / target, repo / relative)

                with (
                    mock.patch.object(layout, "CLASSIFIED_PATHS", (self.SOLE_SUITE,)),
                    self.assertRaisesRegex(AssertionError, "symlinked classified path"),
                ):
                    layout.check_classified_mojo_inventory(repo)

    def test_an_unreadable_classified_subtree_is_an_error_not_an_absence(
        self,
    ) -> None:
        if os.geteuid() == 0:
            self.skipTest("root bypasses the directory permission being tested")
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            self._accepted_tree(repo)
            hidden = repo / "tests" / "unit" / "hidden"
            hidden.mkdir()
            (hidden / "evil.mojo").write_text("", encoding="utf-8")
            hidden.chmod(0o000)
            try:
                with self.assertRaises(PermissionError):
                    layout.classified_mojo_universe(repo)
                with (
                    mock.patch.object(layout, "CLASSIFIED_PATHS", (self.SOLE_SUITE,)),
                    self.assertRaises(PermissionError),
                ):
                    layout.check_classified_mojo_inventory(repo)
            finally:
                hidden.chmod(0o700)

    def test_a_symlinked_classified_root_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            self._accepted_tree(repo)
            relocated = repo / "elsewhere"
            (repo / "tests" / "unit").rename(relocated)
            os.symlink(relocated, repo / "tests" / "unit")

            _regular, symlinked = layout.classified_mojo_universe(repo)
            self.assertEqual(symlinked, {Path("tests/unit")})

            with (
                mock.patch.object(layout, "CLASSIFIED_PATHS", (self.SOLE_SUITE,)),
                self.assertRaisesRegex(AssertionError, "symlinked classified path"),
            ):
                layout.check_classified_mojo_inventory(repo)

    def test_a_registered_suite_that_vanished_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            self._accepted_tree(repo)
            (repo / self.SOLE_SUITE).unlink()

            with (
                mock.patch.object(layout, "CLASSIFIED_PATHS", (self.SOLE_SUITE,)),
                self.assertRaisesRegex(AssertionError, "missing classified Mojo file"),
            ):
                layout.check_classified_mojo_inventory(repo)

    def test_repository_suite_layout_walks_the_repository_universe(self) -> None:
        roots: list[Path] = []
        walk = layout.classified_mojo_universe

        def recording(root: Path) -> tuple[set[Path], set[Path]]:
            roots.append(root)
            return walk(root)

        with mock.patch.object(layout, "classified_mojo_universe", recording):
            layout.check_suite_layout()

        self.assertEqual(roots, [layout.REPO_ROOT])


class AggregateMembershipOracleTests(unittest.TestCase):
    def _fixture(self, repo: Path) -> tuple[str, ...]:
        relative = "tests/unit/test_probe.mojo"
        source = repo / relative
        source.parent.mkdir(parents=True)
        source.write_text(
            "def test_alpha():\n    pass\n\ndef test_beta() raises:\n    pass\n",
            encoding="utf-8",
        )
        return (relative,)

    def test_oracle_reads_source_without_aggregate_parser(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            paths = self._fixture(repo)

            with mock.patch.object(
                aggregate,
                "test_function_names",
                return_value=["test_wrong_a", "test_wrong_b"],
            ):
                membership = layout.independent_registration_membership(repo, paths)

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

            with (
                mock.patch.object(
                    aggregate,
                    "test_function_names",
                    return_value=["test_alpha", "test_gamma"],
                ),
                self.assertRaisesRegex(AssertionError, "registration membership/order"),
            ):
                layout.check_classified_entrypoint(repo, paths, expected_count=2)

    def test_same_count_loader_reordering_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            paths = self._fixture(repo)

            with (
                mock.patch.object(
                    aggregate,
                    "test_function_names",
                    return_value=["test_beta", "test_alpha"],
                ),
                self.assertRaisesRegex(AssertionError, "registration membership/order"),
            ):
                layout.check_classified_entrypoint(repo, paths, expected_count=2)


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
                    layout.direct_script_invocations(Path("README.md"), form)
                )

    def test_sys_executable_argv_is_rejected(self) -> None:
        source = (
            "import subprocess\n"
            "import sys\n"
            "subprocess.run([sys.executable, " + repr(self.SCRIPT_PATH) + "])\n"
        )

        self.assertTrue(
            layout.direct_script_invocations(Path("scripts/caller.py"), source)
        )

    def test_dot_relative_script_operands_are_rejected(self) -> None:
        operand = "./" + self.SCRIPT_PATH
        cases = (
            (Path("README.md"), f"python {operand}"),
            (
                Path("scripts/caller.py"),
                "import subprocess\n"
                "import sys\n"
                "subprocess.run([sys.executable, " + repr(operand) + "])\n",
            ),
        )

        for path, contents in cases:
            with self.subTest(path=path):
                self.assertTrue(layout.direct_script_invocations(path, contents))

    def test_module_invocation_is_accepted(self) -> None:
        self.assertFalse(
            layout.direct_script_invocations(
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
            historical.write_text(f"python -u {self.SCRIPT_PATH}\n", encoding="utf-8")

            files = layout.live_command_files(repo)
            violations = layout.live_direct_invocations(repo)

        self.assertEqual(files, (Path("README.md"),))
        self.assertEqual(violations, ())

    def test_each_live_surface_is_checked(self) -> None:
        self.assertEqual(
            layout.LIVE_COMMAND_FIXED_PATHS,
            (
                Path("README.md"),
                Path("CONTRIBUTING.md"),
                Path("SECURITY.md"),
                Path("AGENTS.md"),
                Path("pixi.toml"),
            ),
        )
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            relative_paths = (
                Path("README.md"),
                Path("CONTRIBUTING.md"),
                Path("SECURITY.md"),
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
            )
            for index, relative in enumerate(relative_paths):
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                command = f"/usr/bin/python -u {self.SCRIPT_PATH}"
                if relative.suffix == ".py":
                    command = "# " + command
                path.write_text(command + f" # {index}\n", encoding="utf-8")

            files = layout.live_command_files(repo)
            violations = layout.live_direct_invocations(repo)

        self.assertEqual(set(files), set(relative_paths))
        self.assertEqual(
            {violation.split(":", 1)[0] for violation in violations},
            {path.as_posix() for path in relative_paths},
        )


class BuildSourceVisibilityTests(unittest.TestCase):
    def _repo(self, root: Path, ignore_rule: str) -> None:
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        (root / ".gitignore").write_text(ignore_rule + "\n", encoding="utf-8")
        for relative in layout.BUILD_SOURCE_PATHS:
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("# fixture\n", encoding="utf-8")

    def test_unanchored_build_ignore_rejects_source_package(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            self._repo(repo, "build/")

            with self.assertRaisesRegex(AssertionError, "ignored"):
                layout.check_build_source_visibility(repo)

    def test_untracked_build_source_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            self._repo(repo, "/build/")
            subprocess.run(["git", "-C", str(repo), "add", ".gitignore"], check=True)

            with self.assertRaisesRegex(AssertionError, "untracked"):
                layout.check_build_source_visibility(repo)


if __name__ == "__main__":
    unittest.main()
