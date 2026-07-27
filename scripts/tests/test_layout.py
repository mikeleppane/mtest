#!/usr/bin/env python3
"""Unit tests for independent repository-harness policy checks."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

from scripts.build import package_consumption
from scripts.checks import layout


class LayoutInventoryPolicyTests(unittest.TestCase):
    def test_repository_root_tracks_the_nested_checker(self) -> None:
        self.assertEqual(layout.REPO_ROOT, Path(__file__).resolve().parents[2])

    def test_every_intended_inventory_fails_closed_when_empty(self) -> None:
        cases = (
            ("TOP_LEVEL_SCRIPT_FILES", layout.check_top_level_script_layout),
            ("CLASSIFIED_ROOTS", layout.check_suite_layout),
            (
                "FORBIDDEN_CLASSIFIED_PACKAGE_MARKERS",
                layout.check_classified_roots_are_not_precompilable_packages,
            ),
            ("SUPPORT_MODULES", layout.check_suite_layout),
            ("EXEC_FIXTURES", layout.check_exec_fixture_layout),
            ("E2E_NATIVE_FIXTURES", layout.check_e2e_native_fixture_layout),
            ("PROTOCOL_FIXTURES", layout.check_protocol_asset_layout),
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
    """Every Mojo file under a classified root is one the runner actually runs.

    The expectation is derived from disk and from the runner's own glob, so
    these fixtures never register anything: a tree is accepted or rejected on
    what it contains, not on what some list says it should contain.
    """

    SOLE_SUITE = "tests/unit/test_probe.mojo"

    def _accepted_tree(self, repo: Path) -> None:
        """Create one discoverable suite per classified root, and no markers.

        Both classified roots are plain directories: an `__init__.mojo` there
        would make `mojo precompile tests/` fail, since every classified
        module declares `main()`.
        """
        for relative in (
            self.SOLE_SUITE,
            "tests/integration/test_flow.mojo",
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
                Path("tests/unit/test_probe.mojo"),
                Path("tests/unit/session_shard_test.mojo"),
                Path("tests/unit/helper.mojo"),
                Path("tests/integration/test_flow.mojo"),
                Path("tests/integration/test_probe.mojo.disabled"),
            },
        )
        self.assertEqual(
            symlinked,
            {Path("tests/unit/test_link.mojo"), Path("tests/unit/linked")},
        )

    def test_a_discoverable_tree_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            self._accepted_tree(repo)

            layout.check_classified_mojo_inventory(repo)

    def test_a_new_test_file_needs_no_ledger_edit(self) -> None:
        """Adding a suite must cost zero edits anywhere in this repository.

        This is the property the deleted `CLASSIFIED_PATHS`/`UNIT_SUITES`
        ledgers cost on every single new test file, and the reason they are
        gone. If this test ever needs a companion edit to pass, the derivation
        has regressed back into a list.
        """
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            self._accepted_tree(repo)
            (repo / "tests" / "unit" / "test_brand_new.mojo").write_text(
                "def test_new():\n    pass\n", encoding="utf-8"
            )

            layout.check_classified_mojo_inventory(repo)

    def test_every_name_the_runner_would_skip_is_rejected(self) -> None:
        """A Mojo file the discovery glob misses never runs, and no oracle sees it.

        `selfhost.py` reconciles what mtest reported against what it found on
        disk, so it can only speak for files discovery reached. A parked
        `.mojo.disabled` or a misnamed module is invisible to both, which is
        exactly the gap this check exists to close.
        """
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

                with self.assertRaisesRegex(
                    AssertionError, "discovery would silently skip"
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

                with self.assertRaisesRegex(
                    AssertionError, "symlinked classified path"
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
                with self.assertRaises(PermissionError):
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

            with self.assertRaisesRegex(AssertionError, "symlinked classified path"):
                layout.check_classified_mojo_inventory(repo)

    def test_a_classified_root_with_no_test_file_is_rejected(self) -> None:
        """Emptiness fails closed; a derived expectation must not become vacuous.

        Without this, a root that lost every suite -- or a glob that stopped
        matching anything -- would satisfy a check that only ever asks
        "is everything present named correctly?".
        """
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            self._accepted_tree(repo)
            (repo / self.SOLE_SUITE).unlink()

            with self.assertRaisesRegex(
                AssertionError, "classified root holds no .* test file: tests/unit"
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


class ClassifiedPackagePrecompileGuardTests(unittest.TestCase):
    """Reintroducing a package marker over main()-declaring tests must fail."""

    def test_a_reintroduced_marker_is_rejected_without_touching_mojo(self) -> None:
        # The structural pre-check must fire before any subprocess is spawned,
        # so this proves the failure even with `mojo` unresolvable.
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            marker = repo / "tests" / "unit" / "__init__.mojo"
            marker.parent.mkdir(parents=True)
            marker.write_text("", encoding="utf-8")

            with (
                mock.patch.object(shutil, "which", return_value=None),
                self.assertRaisesRegex(AssertionError, "package marker reintroduced"),
            ):
                layout.check_classified_roots_are_not_precompilable_packages(repo)

    def test_mojo_missing_from_path_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            with (
                mock.patch.object(shutil, "which", return_value=None),
                self.assertRaisesRegex(AssertionError, "mojo is not available on PATH"),
            ):
                layout.check_classified_roots_are_not_precompilable_packages(repo)

    def test_a_failed_precompile_is_surfaced_with_its_stderr(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            failed = subprocess.CompletedProcess(
                args=["mojo", "precompile"],
                returncode=1,
                stdout="",
                stderr="error: 'main()' is not supported within packages\n",
            )
            with (
                mock.patch.object(shutil, "which", return_value="/bin/mojo"),
                mock.patch.object(subprocess, "run", return_value=failed),
                self.assertRaisesRegex(
                    AssertionError,
                    r"mojo precompile tests/ failed \(rc=1\).*not supported "
                    r"within packages",
                ),
            ):
                layout.check_classified_roots_are_not_precompilable_packages(repo)

    def test_absent_markers_and_a_clean_precompile_pass(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            ok = subprocess.CompletedProcess(
                args=["mojo", "precompile"], returncode=0, stdout="", stderr=""
            )
            with (
                mock.patch.object(shutil, "which", return_value="/bin/mojo"),
                mock.patch.object(subprocess, "run", return_value=ok) as run,
            ):
                layout.check_classified_roots_are_not_precompilable_packages(repo)

            self.assertEqual(run.call_args.kwargs["cwd"], repo)
            self.assertIn("tests/", run.call_args.args[0])


class DirectInvocationPolicyTests(unittest.TestCase):
    """A script command spelled as a path must be rejected wherever it is written.

    The forms are built by concatenation so this file cannot match its own
    scanner, and the fixture repository is a real `git init` because the file
    set under test is `git ls-files` -- an untracked file must be invisible to
    the scan, which is what keeps working notes and a linked worktree from
    reddening one machine and not another.
    """

    SCRIPT_PATH = "scripts" + "/probe.py"
    MODULE_COMMAND = "python -u -m scripts.probe"

    def _repo(self, root: Path) -> None:
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        (root / "scripts").mkdir()
        (root / "scripts" / "__init__.py").write_text("", encoding="utf-8")

    def _track(self, root: Path, relative: str, contents: str) -> None:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        subprocess.run(["git", "-C", str(root), "add", relative], check=True)

    def test_every_by_path_spelling_is_rejected(self) -> None:
        forms = (
            "python " + self.SCRIPT_PATH,
            "python -u " + self.SCRIPT_PATH,
            "python3.12 " + self.SCRIPT_PATH,
            "/usr/bin/python " + self.SCRIPT_PATH,
            "python ./" + self.SCRIPT_PATH,
            "run `python -u " + self.SCRIPT_PATH + "` to regenerate",
        )
        for form in forms:
            with (
                self.subTest(form=form),
                tempfile.TemporaryDirectory() as raw_tmp,
            ):
                repo = Path(raw_tmp)
                self._repo(repo)
                self._track(repo, "README.md", form + "\n")

                with self.assertRaisesRegex(AssertionError, "interpreter plus a path"):
                    layout.check_python_package_invocation(repo)

    def test_the_module_form_and_untracked_files_are_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            self._repo(repo)
            self._track(repo, "README.md", self.MODULE_COMMAND + "\n")
            # Present in the checkout, absent from the index: the scan must not
            # see it, or a contributor's scratch file reds a gate CI passes.
            (repo / "scratch.md").write_text(
                "python -u " + self.SCRIPT_PATH + "\n", encoding="utf-8"
            )

            self.assertEqual(layout.direct_script_invocations(repo), ())
            layout.check_python_package_invocation(repo)

    def test_a_finding_names_its_file_line_and_operand(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            self._repo(repo)
            self._track(
                repo,
                "docs/guide.md",
                self.MODULE_COMMAND + "\npython -u " + self.SCRIPT_PATH + "\n",
            )

            self.assertEqual(
                layout.direct_script_invocations(repo),
                (f"docs/guide.md:2: {self.SCRIPT_PATH}",),
            )

    def test_an_empty_index_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp)
            self._repo(repo)

            with self.assertRaisesRegex(AssertionError, "no tracked file"):
                layout.direct_script_invocations(repo)


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
