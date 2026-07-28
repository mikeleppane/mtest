#!/usr/bin/env python3
"""Unit tests for independent repository-harness policy checks."""

from __future__ import annotations

import contextlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from typing import TYPE_CHECKING
import unittest
from unittest import mock

from scripts.build import package_consumption
from scripts.checks import layout


if TYPE_CHECKING:
    from collections.abc import Iterator


class LayoutInventoryPolicyTests(unittest.TestCase):
    def test_repository_root_tracks_the_nested_checker(self) -> None:
        self.assertEqual(layout.REPO_ROOT, Path(__file__).resolve().parents[2])

    def test_every_intended_inventory_fails_closed_when_empty(self) -> None:
        cases = (
            ("CLASSIFIED_ROOTS", layout.check_suite_layout),
            (
                "FORBIDDEN_CLASSIFIED_PACKAGE_MARKERS",
                layout.check_classified_roots_are_not_precompilable_packages,
            ),
            ("BUILD_SOURCE_PATHS", layout.check_build_source_visibility),
            ("VENDORED_TOML_PATHS", layout.check_vendored_toml_layout),
            ("PLATFORM_TASK_OVERRIDES", layout.check_platform_task_overrides),
            ("PLATFORM_TARGET_KEYS", layout.check_platform_task_overrides),
        )
        for name, check in cases:
            with (
                self.subTest(inventory=name),
                mock.patch.object(layout, name, ()),
                self.assertRaisesRegex(AssertionError, "intended inventory is empty"),
            ):
                check()


class AssertionCompanionLayoutTests(unittest.TestCase):
    """The companion contract is reconciled from disk, never from a list.

    Every fixture here is built by writing files, and the expectation is
    whatever those files are. `SOURCES` names the tree this fixture happens to
    contain -- it is not a copy of the repository's companion membership, and
    `test_a_new_companion_source_needs_no_ledger_edit` is what holds that
    distinction honest.
    """

    SOURCES = (
        "mtest/__init__.mojo",
        "mtest/assertions/__init__.mojo",
    )

    def _repo(self, root: Path, sources: tuple[str, ...]) -> None:
        """Write a companion tree, a recipe that installs it, and a build."""
        for relative in sources:
            path = root / layout.COMPANION_SOURCE_ROOT / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("# fixture\n", encoding="utf-8")
        example = root / layout.COMPANION_ROOT / "examples" / "test_diagnostics.mojo"
        example.parent.mkdir(parents=True, exist_ok=True)
        example.write_text("# example\n", encoding="utf-8")
        production = root / "scripts" / "build" / "production_build.sh"
        production.parent.mkdir(parents=True, exist_ok=True)
        production.write_text("# no assertion precompile\n", encoding="utf-8")
        recipe = root / "recipe" / "build.sh"
        recipe.parent.mkdir(parents=True, exist_ok=True)
        recipe.write_text(self._recipe(sources), encoding="utf-8")

    @staticmethod
    def _recipe(sources: tuple[str, ...], suffix: str = "") -> str:
        return (
            "# no assertion precompile\n"
            + "".join(
                f"install -m 644 "
                f"{(layout.COMPANION_SOURCE_ROOT / relative).as_posix()} dest\n"
                for relative in sources
            )
            + suffix
        )

    @contextlib.contextmanager
    def _fixture(self, sources: tuple[str, ...] = SOURCES) -> Iterator[Path]:
        """Yield a repository whose companion contract already holds."""
        with (
            tempfile.TemporaryDirectory(prefix="mtest-companion-") as raw_tmp,
            mock.patch.object(
                package_consumption,
                "INSTALLED_ASSERTION_FILES",
                {Path(relative) for relative in sources},
            ),
        ):
            repo = Path(raw_tmp)
            self._repo(repo, sources)
            layout.check_assertion_companion_layout(repo)
            yield repo

    def test_a_new_companion_source_needs_no_ledger_edit(self) -> None:
        """Adding a module costs the recipe and the shipped list, nothing more.

        The recipe line is the install the package needs and the shipped list
        is what `public_verify` cannot derive; if this check ever needs a third
        edit, the derivation has regressed back into a list of its own.
        """
        with self._fixture((*self.SOURCES, "mtest/assertions/_brand_new.mojo")):
            pass

    def test_a_source_without_its_install_line_is_rejected(self) -> None:
        """The load-bearing case: a shipped module the package never installs.

        The shipped membership is advanced alongside disk so the earlier
        equality passes, which leaves the recipe as the only disagreement --
        exactly the state that produces a broken package and is otherwise
        invisible until a full package build runs.
        """
        with self._fixture() as repo:
            orphan = repo / layout.COMPANION_SOURCE_ROOT / "mtest" / "orphan.mojo"
            orphan.write_text("# unshipped\n", encoding="utf-8")

            with (
                mock.patch.object(
                    package_consumption,
                    "INSTALLED_ASSERTION_FILES",
                    {Path(relative) for relative in self.SOURCES}
                    | {Path("mtest/orphan.mojo")},
                ),
                self.assertRaisesRegex(
                    AssertionError, "recipe install membership mismatch"
                ),
            ):
                layout.check_assertion_companion_layout(repo)

    def test_an_install_line_without_its_source_is_rejected(self) -> None:
        with self._fixture() as repo:
            (repo / "recipe" / "build.sh").write_text(
                self._recipe((*self.SOURCES, "mtest/ghost.mojo")), encoding="utf-8"
            )

            with self.assertRaisesRegex(
                AssertionError, "recipe install membership mismatch"
            ):
                layout.check_assertion_companion_layout(repo)

    def test_a_shipped_membership_that_disagrees_with_disk_is_rejected(self) -> None:
        with (
            self._fixture() as repo,
            mock.patch.object(
                package_consumption,
                "INSTALLED_ASSERTION_FILES",
                {Path("mtest/__init__.mojo")},
            ),
            self.assertRaisesRegex(
                AssertionError, "assertion package-check membership mismatch"
            ),
        ):
            layout.check_assertion_companion_layout(repo)

    def test_an_empty_companion_tree_fails_closed(self) -> None:
        with self._fixture() as repo:
            for relative in self.SOURCES:
                (repo / layout.COMPANION_SOURCE_ROOT / relative).unlink()

            with self.assertRaisesRegex(AssertionError, "has no source file"):
                layout.check_assertion_companion_layout(repo)

    def test_a_symlinked_companion_entry_is_rejected(self) -> None:
        with self._fixture() as repo:
            outside = repo / "outside.mojo"
            outside.write_text("# external\n", encoding="utf-8")
            leaf = repo / layout.COMPANION_SOURCE_ROOT / self.SOURCES[0]
            leaf.unlink()
            leaf.symlink_to(outside)

            with self.assertRaisesRegex(AssertionError, "contains symlinks"):
                layout.check_assertion_companion_layout(repo)

    def test_a_non_regular_companion_entry_is_rejected(self) -> None:
        with self._fixture() as repo:
            os.mkfifo(repo / layout.COMPANION_ROOT / "pipe")

            with self.assertRaisesRegex(AssertionError, "not a regular file"):
                layout.check_assertion_companion_layout(repo)

    def test_a_leak_into_the_private_package_is_rejected(self) -> None:
        with self._fixture() as repo:
            (repo / "src" / "mtest" / "assertions").mkdir(parents=True)

            with self.assertRaisesRegex(AssertionError, "leaked into private"):
                layout.check_assertion_companion_layout(repo)

    def test_precompiling_the_public_source_is_rejected(self) -> None:
        cases = (
            ("scripts/build/production_build.sh", "production build"),
            ("recipe/build.sh", "recipe build"),
        )
        for relative, label in cases:
            with self.subTest(script=relative), self._fixture() as repo:
                path = repo / relative
                path.write_text(
                    path.read_text(encoding="utf-8")
                    + "mojo precompile companions/assertions/src/mtest\n",
                    encoding="utf-8",
                )

                with self.assertRaisesRegex(AssertionError, f"{label} precompiles"):
                    layout.check_assertion_companion_layout(repo)

    def test_a_recursive_copy_of_the_public_source_is_rejected(self) -> None:
        recursive_copies = (
            "cp -r companions/assertions destination\n",
            "cp\t-R companions/assertions destination\n",
            "cp -pr companions/assertions destination\n",
            "cp -aR companions/assertions destination\n",
            "cp --recursive companions/assertions destination\n",
        )
        for recursive_copy in recursive_copies:
            with self.subTest(copy=recursive_copy), self._fixture() as repo:
                (repo / "recipe" / "build.sh").write_text(
                    self._recipe(self.SOURCES, recursive_copy), encoding="utf-8"
                )

                with self.assertRaisesRegex(AssertionError, "recursive source copy"):
                    layout.check_assertion_companion_layout(repo)

    def test_a_non_recursive_lookalike_command_is_accepted(self) -> None:
        with self._fixture() as repo:
            (repo / "recipe" / "build.sh").write_text(
                self._recipe(
                    self.SOURCES, "scp -r companions/assertions destination\n"
                ),
                encoding="utf-8",
            )

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


class PlatformTaskOverrideTests(unittest.TestCase):
    """A `[target.<platform>.tasks]` entry replaces a base task invisibly.

    Pixi emits no warning, `pixi run <task>` keeps working, and the hosted
    matrix names its lanes by task name -- so a substituted lane stays green
    in every view while running something else. Three words of TOML are the
    whole attack, which is why the bound is a check rather than a review
    convention.
    """

    BASE = (
        "[workspace]\n"
        'name = "fixture"\n'
        "\n"
        "[tasks]\n"
        'asan-check = "python -m scripts.checks.memory.asan"\n'
        'ci-memory = "python -m scripts.checks.memory.host_support"\n'
    )
    LEGITIMATE = (
        "\n[target.linux-64.dependencies]\n"
        'valgrind = "==3.27.1"\n'
        "\n[target.linux-64.tasks]\n"
        'ci-memory = { depends-on = ["asan-check"] }\n'
    )

    def _manifest(self, body: str) -> Path:
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (root / "pixi.toml").write_text(body, encoding="utf-8")
        return root

    def test_the_repositorys_own_manifest_is_within_the_bound(self) -> None:
        layout.check_platform_task_overrides()

    def test_the_dependency_only_override_is_accepted(self) -> None:
        root = self._manifest(self.BASE + self.LEGITIMATE)

        layout.check_platform_task_overrides(root)

    def test_substituting_a_lane_for_one_platform_is_rejected(self) -> None:
        # The exact reproduced attack: three words that leave `pixi run
        # asan-check` exiting 0 having run `/bin/true`, with the hosted
        # "ASan + LSan" required check still reporting the same task name.
        root = self._manifest(
            self.BASE + self.LEGITIMATE + 'asan-check = "true"\n',
        )

        with self.assertRaisesRegex(AssertionError, r"outside the bounded set"):
            layout.check_platform_task_overrides(root)

    def test_an_allowlisted_override_may_not_carry_a_command(self) -> None:
        # Narrowing to a name list alone is not enough: the permitted entry
        # must stay a pure dependency edge, or the same substitution arrives
        # under a name the allowlist blesses.
        for body in (
            'ci-memory = "true"\n',
            'ci-memory = { cmd = "true", depends-on = ["asan-check"] }\n',
        ):
            with self.subTest(body=body):
                root = self._manifest(
                    self.BASE + "\n[target.linux-64.tasks]\n" + body,
                )

                with self.assertRaisesRegex(AssertionError, r"dependency-only|`cmd`"):
                    layout.check_platform_task_overrides(root)

    def test_an_unread_target_key_is_rejected(self) -> None:
        root = self._manifest(
            self.BASE + '\n[target.linux-64]\nactivation = { env = { X = "1" } }\n',
        )

        with self.assertRaisesRegex(AssertionError, "unexpected keys"):
            layout.check_platform_task_overrides(root)

    def test_an_override_on_any_other_platform_is_rejected_too(self) -> None:
        root = self._manifest(
            self.BASE + '\n[target.osx-arm64.tasks]\nasan-check = "true"\n',
        )

        with self.assertRaisesRegex(AssertionError, r"\[target\.osx-arm64\.tasks\]"):
            layout.check_platform_task_overrides(root)

    def test_a_renamed_base_task_leaves_the_allowlist_loud(self) -> None:
        # A stale allowlist entry permits overriding a name nothing runs, so
        # the bound would quietly cover the wrong task.
        root = self._manifest(
            self.BASE.replace("ci-memory", "ci-mem") + self.LEGITIMATE,
        )

        with self.assertRaisesRegex(AssertionError, "no longer exists"):
            layout.check_platform_task_overrides(root)


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
