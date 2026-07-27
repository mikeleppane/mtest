#!/usr/bin/env python3
"""Mutation tests for exact Pixi and hosted-CI topology policy."""

from __future__ import annotations

import contextlib
import io
from pathlib import Path
import re
import tempfile
import tomllib
import unittest

from scripts.checks import ci_topology
from scripts.checks.memory import host_support


class CiTopologyTests(unittest.TestCase):
    def test_repository_root_tracks_the_nested_checker(self) -> None:
        self.assertEqual(
            ci_topology.REPO_ROOT,
            Path(__file__).resolve().parents[2],
        )

    def test_conventional_test_is_the_exhaustive_gate(self) -> None:
        with (ci_topology.REPO_ROOT / "pixi.toml").open("rb") as manifest:
            tasks = tomllib.load(manifest)["tasks"]

        self.assertNotIn("test-direct", tasks)
        self.assertEqual(
            tasks.get("test"),
            "python -m scripts.harness.classified tests/unit tests/integration",
        )
        self.assertEqual(
            tasks.get("dogfood-check", {}).get("cmd"),
            "python -m scripts.harness.dogfood",
        )
        self.assertEqual(
            tasks.get("ci", {}).get("depends-on"),
            [
                "ci-preflight",
                "test",
                "assertions-check",
                "dogfood-check",
                "e2e",
                "contract-check-strict",
                "ci-memory",
            ],
        )
        self.assertEqual(
            tasks.get("readme-help-check"),
            {
                "cmd": "python -m scripts.checks.readme_help",
                "depends-on": ["build-bin"],
            },
        )
        self.assertEqual(
            tasks.get("ci-preflight", {}).get("depends-on"),
            ci_topology.CI_PREFLIGHT_TASKS,
        )

    def test_contributor_workflow_is_documented_without_legacy_aliases(self) -> None:
        readme = (ci_topology.REPO_ROOT / "README.md").read_text(encoding="utf-8")
        expected = (
            "$ pixi run fmt\n"
            "$ pixi run test-file -- PATH\n"
            "$ pixi run test\n"
            "$ pixi run e2e\n"
            "$ pixi run ci"
        )
        self.assertIn(expected, readme)
        for relative in (
            "README.md",
            "tests/README.md",
            "AGENTS.md",
            ".agents/skills/test-driven-development/SKILL.md",
            ".agents/skills/mojo-coding-guidance/SKILL.md",
            ".agents/skills/code-review-and-quality/SKILL.md",
            ".agents/skills/improve-architecture/SKILL.md",
            ".agents/skills/validating-mtest/SKILL.md",
        ):
            contents = (ci_topology.REPO_ROOT / relative).read_text(encoding="utf-8")
            self.assertNotIn("test-direct", contents, relative)

    def test_obsolete_test_alias_mutation_is_rejected(self) -> None:
        source = (ci_topology.REPO_ROOT / "pixi.toml").read_text(encoding="utf-8")
        mutated = source.replace(
            'test = "python -m scripts.harness.classified tests/unit '
            'tests/integration"',
            'test-direct = "python -m scripts.harness.classified tests/unit '
            'tests/integration"\n'
            'test = "python -m scripts.harness.classified tests/unit '
            'tests/integration"',
            1,
        )
        self.assertNotEqual(mutated, source)
        with tempfile.TemporaryDirectory(prefix="mtest-ci-topology-") as raw_tmp:
            repo = Path(raw_tmp)
            (repo / "pixi.toml").write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "obsolete test-direct"):
                ci_topology.check_ci_task_graph(repo)

    def test_preflight_order_mutation_is_rejected(self) -> None:
        source = (ci_topology.REPO_ROOT / "pixi.toml").read_text(encoding="utf-8")
        mutated = source.replace(
            '    "version-check",\n    "fmt-check",',
            '    "fmt-check",\n    "version-check",',
            1,
        )
        self.assertNotEqual(mutated, source)
        with tempfile.TemporaryDirectory(prefix="mtest-ci-topology-") as raw_tmp:
            repo = Path(raw_tmp)
            (repo / "pixi.toml").write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "membership/order"):
                ci_topology.check_ci_task_graph(repo)

    def test_formatter_command_mutation_is_rejected(self) -> None:
        source = (ci_topology.REPO_ROOT / "pixi.toml").read_text(encoding="utf-8")
        mutated = source.replace(
            'fmt-check = { cmd = "git diff --exit-code", depends-on = ["fmt"] }',
            'fmt-check = "mojo format src companions tests e2e"',
            1,
        )
        self.assertNotEqual(mutated, source)
        with tempfile.TemporaryDirectory(prefix="mtest-ci-topology-") as raw_tmp:
            repo = Path(raw_tmp)
            (repo / "pixi.toml").write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "fmt-check task mismatch"):
                ci_topology.check_ci_task_graph(repo)

    def test_recipe_checks_are_owned_by_the_cheap_serial_gate(self) -> None:
        with (ci_topology.REPO_ROOT / "pixi.toml").open("rb") as manifest:
            tasks = tomllib.load(manifest)["tasks"]

        self.assertEqual(
            tasks.get("recipe-check"),
            "python -m scripts.tests.test_community_recipe && "
            "python -m scripts.checks.community_recipe",
        )
        self.assertIn(
            "scripts.tests.test_community_recipe",
            ci_topology.HARNESS_CHECK_MODULES,
        )
        self.assertIn(
            "scripts.checks.community_recipe",
            ci_topology.HARNESS_CHECK_MODULES,
        )
        self.assertIn(
            "find -P src companions tests e2e recipe",
            ci_topology.FORMAT_COMMAND,
        )

    def test_readme_help_gate_removal_is_rejected(self) -> None:
        source = (ci_topology.REPO_ROOT / "pixi.toml").read_text(encoding="utf-8")
        mutated = source.replace(
            '    "readme-help-check",\n',
            "",
            1,
        )
        self.assertNotEqual(mutated, source)
        with tempfile.TemporaryDirectory(prefix="mtest-ci-topology-") as raw_tmp:
            repo = Path(raw_tmp)
            (repo / "pixi.toml").write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "membership/order"):
                ci_topology.check_ci_task_graph(repo)

    def test_readme_help_gate_command_mutation_is_rejected(self) -> None:
        source = (ci_topology.REPO_ROOT / "pixi.toml").read_text(encoding="utf-8")
        mutated = source.replace(
            'cmd = "python -m scripts.checks.readme_help"',
            'cmd = "python -m scripts.checks.layout"',
            1,
        )
        self.assertNotEqual(mutated, source)
        with tempfile.TemporaryDirectory(prefix="mtest-ci-topology-") as raw_tmp:
            repo = Path(raw_tmp)
            (repo / "pixi.toml").write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "readme-help-check"):
                ci_topology.check_ci_task_graph(repo)

    def test_harness_owner_removal_is_rejected(self) -> None:
        source = (ci_topology.REPO_ROOT / "pixi.toml").read_text(encoding="utf-8")
        mutated = source.replace(
            " && python -m scripts.tests.test_dogfood",
            "",
            1,
        )
        self.assertNotEqual(mutated, source)
        with tempfile.TemporaryDirectory(prefix="mtest-ci-topology-") as raw_tmp:
            repo = Path(raw_tmp)
            (repo / "pixi.toml").write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "serial owner chain"):
                ci_topology.check_ci_task_graph(repo)

    def test_classified_task_shell_regression_is_rejected(self) -> None:
        source = (ci_topology.REPO_ROOT / "pixi.toml").read_text(encoding="utf-8")
        mutated = source.replace(
            'test-file = "python -m scripts.harness.classified"',
            'test-file = "bash scripts/legacy_runner.sh"',
            1,
        )
        self.assertNotEqual(mutated, source)
        with tempfile.TemporaryDirectory(prefix="mtest-ci-topology-") as raw_tmp:
            repo = Path(raw_tmp)
            (repo / "pixi.toml").write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "classified task"):
                ci_topology.check_ci_task_graph(repo)

    def test_contract_row_appears_in_both_platform_matrices(self) -> None:
        expected_row = {
            "lane": "strict contract",
            "task": "contract-check-strict",
            "libc_debug": "false",
            "safety_artifact": "false",
            "artifact_name": "none",
            "artifact_path": "none",
        }
        for runner, rows in (
            ("ubuntu-24.04", ci_topology.LINUX_MATRIX_ROWS),
            ("macos-15", ci_topology.MACOS_MATRIX_ROWS),
        ):
            matches = [
                row for row in rows if row.get("task") == "contract-check-strict"
            ]
            self.assertEqual(len(matches), 1, rows)
            self.assertEqual(matches[0], {"runner": runner, **expected_row})

    def test_contract_row_runs_after_e2e_in_declared_order(self) -> None:
        linux_tasks = [row["task"] for row in ci_topology.LINUX_MATRIX_ROWS]
        macos_tasks = [row["task"] for row in ci_topology.MACOS_MATRIX_ROWS]
        self.assertEqual(
            linux_tasks,
            [
                "test",
                "assertions-check",
                "dogfood-check",
                "e2e",
                "contract-check-strict",
                "asan-check",
                "valgrind-check",
            ],
        )
        self.assertEqual(
            macos_tasks,
            [
                "test",
                "assertions-check",
                "dogfood-check",
                "e2e",
                "contract-check-strict",
            ],
        )

    def test_contract_row_job_depends_on_its_platform_preflight_job(self) -> None:
        # Each matrix job's OWN `needs:` (not a per-row field) is what makes
        # the strict-contract row depend on that platform's preflight job —
        # a fresh checkout runs preflight first, then this job's `build-bin`
        # produces the binary the row's `--no-rebuild` validates.
        workflow = (
            ci_topology.REPO_ROOT / ".github" / "workflows" / "ci.yml"
        ).read_text(encoding="utf-8")
        for job_name, preflight_job in (
            ("linux-test-matrix", "linux-preflight"),
            ("macos-test-matrix", "macos-preflight"),
        ):
            job = ci_topology._yaml_block(workflow, f"  {job_name}:")
            needs = re.findall(r"^    needs:(.*)$", job, re.MULTILINE)
            self.assertEqual(needs, [f" {preflight_job}"], job_name)
            rows = [
                row
                for row in ci_topology._matrix_rows(job)
                if row.get("task") == "contract-check-strict"
            ]
            self.assertEqual(len(rows), 1, job_name)

    def test_contract_row_removal_is_rejected(self) -> None:
        workflow = (
            ci_topology.REPO_ROOT / ".github" / "workflows" / "ci.yml"
        ).read_text(encoding="utf-8")
        mutated = workflow.replace(
            "          - runner: ubuntu-24.04\n"
            "            lane: strict contract\n"
            "            task: contract-check-strict\n"
            "            libc_debug: false\n"
            "            safety_artifact: false\n"
            "            artifact_name: none\n"
            "            artifact_path: none\n",
            "",
            1,
        )
        self.assertNotEqual(mutated, workflow)
        with tempfile.TemporaryDirectory(prefix="mtest-ci-topology-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_path = repo / ".github" / "workflows" / "ci.yml"
            workflow_path.parent.mkdir(parents=True)
            workflow_path.write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "matrix mismatch"):
                ci_topology.check_ci_workflow(repo)

    def test_matrix_role_mutation_is_rejected_by_fixed_oracle(self) -> None:
        workflow = (
            ci_topology.REPO_ROOT / ".github" / "workflows" / "ci.yml"
        ).read_text(encoding="utf-8")
        mutated = workflow.replace("task: test", "task: dogfood-check", 1)
        self.assertNotEqual(mutated, workflow)
        with tempfile.TemporaryDirectory(prefix="mtest-ci-topology-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_path = repo / ".github" / "workflows" / "ci.yml"
            workflow_path.parent.mkdir(parents=True)
            workflow_path.write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "matrix mismatch"):
                ci_topology.check_ci_workflow(repo)

    def test_required_lane_display_name_mutation_is_rejected(self) -> None:
        workflow = (
            ci_topology.REPO_ROOT / ".github" / "workflows" / "ci.yml"
        ).read_text(encoding="utf-8")
        mutated = workflow.replace("lane: direct tests", "lane: exhaustive tests", 1)
        self.assertNotEqual(mutated, workflow)
        with tempfile.TemporaryDirectory(prefix="mtest-ci-topology-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_path = repo / ".github" / "workflows" / "ci.yml"
            workflow_path.parent.mkdir(parents=True)
            workflow_path.write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "matrix mismatch"):
                ci_topology.check_ci_workflow(repo)

    def _workflow(self) -> str:
        """Return the live CI workflow text."""
        return (ci_topology.REPO_ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )

    def _reject(self, mutated: str, pattern: str) -> None:
        """Require the topology oracle to reject one mutated workflow.

        Args:
            mutated: Workflow text differing from the live one.
            pattern: Regex the rejection message must match.
        """
        self.assertNotEqual(mutated, self._workflow())
        with tempfile.TemporaryDirectory(prefix="mtest-ci-topology-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_path = repo / ".github" / "workflows" / "ci.yml"
            workflow_path.parent.mkdir(parents=True)
            workflow_path.write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, pattern):
                ci_topology.check_ci_workflow(repo)

    def test_both_platforms_own_a_blocking_package_job(self) -> None:
        workflow = self._workflow()
        for job_name, display, runner in (
            ("package", "Linux / packaged artifact", "ubuntu-24.04"),
            ("macos-package", "macOS arm64 / packaged artifact", "macos-15"),
        ):
            job = ci_topology._yaml_block(workflow, f"  {job_name}:")
            self.assertEqual(
                re.findall(r"^    name: (.+)$", job, re.MULTILINE), [display]
            )
            self.assertEqual(
                re.findall(r"^    runs-on: (.+)$", job, re.MULTILINE), [runner]
            )
            self.assertEqual(
                re.findall(r"^        run: (.+)$", job, re.MULTILINE),
                ["pixi run mojo-version", "pixi run package-check"],
            )

    def test_macos_package_job_removal_is_rejected(self) -> None:
        workflow = self._workflow()
        mutated = workflow.split("  macos-package:")[0]
        self._reject(mutated, "job membership mismatch")

    def test_macos_package_job_on_a_linux_runner_is_rejected(self) -> None:
        workflow = self._workflow()
        head, _, tail = workflow.partition("  macos-package:")
        mutated = (
            head
            + "  macos-package:"
            + tail.replace("    runs-on: macos-15", "    runs-on: ubuntu-24.04", 1)
        )
        self._reject(mutated, "package runner mismatch")

    def test_macos_package_job_without_its_preflight_dependency_is_rejected(
        self,
    ) -> None:
        workflow = self._workflow()
        mutated = workflow.replace(
            "    name: macOS arm64 / packaged artifact\n    needs: macos-preflight\n",
            "    name: macOS arm64 / packaged artifact\n",
            1,
        )
        self._reject(mutated, "needs mismatch")

    def test_macos_package_job_running_another_task_is_rejected(self) -> None:
        workflow = self._workflow()
        head, _, tail = workflow.partition("  macos-package:")
        mutated = (
            head
            + "  macos-package:"
            + tail.replace(
                "        run: pixi run package-check",
                "        run: pixi run package-build",
                1,
            )
        )
        self._reject(mutated, "package command mismatch")

    def test_linux_package_job_display_name_mutation_is_rejected(self) -> None:
        # The Linux display name is an externally configured required check.
        workflow = self._workflow()
        mutated = workflow.replace(
            "    name: Linux / packaged artifact",
            "    name: Linux / conda package",
            1,
        )
        self._reject(mutated, "package display name mismatch")

    def test_linux_package_job_removal_is_rejected(self) -> None:
        workflow = self._workflow()
        head, _, tail = workflow.partition("  package:\n")
        mutated = (
            head
            + tail.partition("  macos-preflight:\n")[1]
            + (tail.partition("  macos-preflight:\n")[2])
        )
        self._reject(mutated, "job membership mismatch")

    def test_coverage_capability_module_owns_a_harness_check_slot(self) -> None:
        # The probe itself is diagnostic, but the branch logic that decides
        # between "no facility, exit 0" and "facility found, exit nonzero" is
        # blocking: it rides the cheap serial chain.
        self.assertIn(
            "scripts.tests.test_coverage_capability",
            ci_topology.HARNESS_CHECK_MODULES,
        )

    def test_coverage_capability_task_command_mutation_is_rejected(self) -> None:
        source = (ci_topology.REPO_ROOT / "pixi.toml").read_text(encoding="utf-8")
        mutated = source.replace(
            'coverage-capability = "python -m scripts.checks.coverage_capability"',
            'coverage-capability = "python -m scripts.checks.version"',
            1,
        )
        self.assertNotEqual(mutated, source)
        with tempfile.TemporaryDirectory(prefix="mtest-ci-topology-") as raw_tmp:
            repo = Path(raw_tmp)
            (repo / "pixi.toml").write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "coverage-capability task"):
                ci_topology.check_ci_task_graph(repo)

    def test_coverage_capability_task_removal_is_rejected(self) -> None:
        source = (ci_topology.REPO_ROOT / "pixi.toml").read_text(encoding="utf-8")
        mutated = source.replace(
            'coverage-capability = "python -m scripts.checks.coverage_capability"\n',
            "",
            1,
        )
        self.assertNotEqual(mutated, source)
        with tempfile.TemporaryDirectory(prefix="mtest-ci-topology-") as raw_tmp:
            repo = Path(raw_tmp)
            (repo / "pixi.toml").write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "coverage-capability task"):
                ci_topology.check_ci_task_graph(repo)

    def test_coverage_capability_stays_outside_the_ci_floor(self) -> None:
        # It shells out to the real compiler, and it is a diagnostic rather
        # than a release gate. The exact `ci` list and the pinned transitive
        # closure are what keep it out; this test names the reason.
        self.assertNotIn("coverage-capability", ci_topology.CI_TASKS)
        self.assertNotIn("coverage-capability", ci_topology.CI_PREFLIGHT_TASKS)
        self.assertNotIn("coverage-capability", ci_topology.CI_FLOOR_TASKS)

    def test_coverage_capability_entering_the_ci_floor_is_rejected(self) -> None:
        source = (ci_topology.REPO_ROOT / "pixi.toml").read_text(encoding="utf-8")
        mutated = source.replace(
            '    "ci-memory",\n]',
            '    "ci-memory",\n    "coverage-capability",\n]',
            1,
        )
        self.assertNotEqual(mutated, source)
        with tempfile.TemporaryDirectory(prefix="mtest-ci-topology-") as raw_tmp:
            repo = Path(raw_tmp)
            (repo / "pixi.toml").write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, "ci membership/order"):
                ci_topology.check_ci_task_graph(repo)

    def test_memory_lanes_are_members_of_the_local_linux_floor(self) -> None:
        # The whole point of the aggregate: before it, a green `pixi run ci`
        # said nothing about memory safety, because both lanes were reachable
        # only by naming them and in practice ran hosted or not at all.
        self.assertIn("ci-memory", ci_topology.CI_TASKS)
        for lane in ci_topology.MEMORY_LANE_TASKS:
            self.assertIn(lane, ci_topology.LINUX_CI_FLOOR_TASKS, lane)
            self.assertNotIn(lane, ci_topology.CI_FLOOR_TASKS, lane)

    def test_memory_aggregate_dropped_from_the_local_floor_is_rejected(self) -> None:
        self._reject_manifest_mutation(
            '    "contract-check-strict",\n    "ci-memory",\n]',
            '    "contract-check-strict",\n]',
            "ci membership/order",
        )

    def test_silent_memory_aggregate_fallback_is_rejected(self) -> None:
        # A bare `true` here is the tempting shortcut that would let a macOS
        # floor imply a memory verdict it never computed.
        self._reject_manifest_mutation(
            f'ci-memory = "{ci_topology.CI_MEMORY_FALLBACK_COMMAND}"',
            'ci-memory = "true"',
            "ci-memory base command mismatch",
        )

    def test_removing_the_linux_memory_override_is_rejected(self) -> None:
        self._reject_manifest_mutation(
            'ci-memory = { depends-on = ["asan-check", "valgrind-check"] }',
            "",
            f"\\[target.{re.escape(ci_topology.MEMORY_PLATFORM)}.tasks\\] ci-memory",
        )

    def test_dropping_one_lane_from_the_memory_override_is_rejected(self) -> None:
        self._reject_manifest_mutation(
            'ci-memory = { depends-on = ["asan-check", "valgrind-check"] }',
            'ci-memory = { depends-on = ["asan-check"] }',
            "ci-memory mismatch",
        )

    def _reject_manifest_mutation(
        self, original: str, replacement: str, pattern: str
    ) -> None:
        """Assert the checker rejects one exact manifest mutation."""
        source = (ci_topology.REPO_ROOT / "pixi.toml").read_text(encoding="utf-8")
        mutated = source.replace(original, replacement, 1)
        self.assertNotEqual(mutated, source)
        with tempfile.TemporaryDirectory(prefix="mtest-ci-topology-") as raw_tmp:
            repo = Path(raw_tmp)
            (repo / "pixi.toml").write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, pattern):
                ci_topology.check_ci_task_graph(repo)

    def test_package_test_module_owns_a_harness_check_slot(self) -> None:
        # The package gate's oracles are unit-tested in the cheap serial chain,
        # not only inside the expensive packaging job.
        self.assertIn(
            "scripts.tests.test_package_consumption",
            ci_topology.HARNESS_CHECK_MODULES,
        )


class CodeQLWorkflowTests(unittest.TestCase):
    """Fail-closed policy for the independently triggered CodeQL workflow."""

    def _workflow(self) -> str:
        """Return the live CodeQL workflow text."""
        return (
            ci_topology.REPO_ROOT / ".github" / "workflows" / "codeql.yml"
        ).read_text(encoding="utf-8")

    def _reject(self, mutated: str, pattern: str) -> None:
        """Require the CodeQL oracle to reject one mutated workflow."""
        self.assertNotEqual(mutated, self._workflow())
        with tempfile.TemporaryDirectory(prefix="mtest-codeql-topology-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_path = repo / ".github" / "workflows" / "codeql.yml"
            workflow_path.parent.mkdir(parents=True)
            workflow_path.write_text(mutated, encoding="utf-8")
            with self.assertRaisesRegex(AssertionError, pattern):
                ci_topology.check_codeql_workflow(repo)

    def _write_inventory(self, root: Path) -> Path:
        """Create the exact expected workflow inventory in a temporary repo."""
        workflow_root = root / ".github" / "workflows"
        workflow_root.mkdir(parents=True)
        for name in ("ci.yml", "codeql.yml"):
            source = ci_topology.REPO_ROOT / ".github" / "workflows" / name
            (workflow_root / name).write_text(
                source.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
        return workflow_root

    def test_repository_workflow_inventory_is_exact(self) -> None:
        self.assertEqual(
            ci_topology.WORKFLOW_PATHS,
            {
                Path(".github/workflows/ci.yml"),
                Path(".github/workflows/codeql.yml"),
            },
        )
        ci_topology.check_workflow_inventory()

    def test_javascript_actions_pin_reviewed_node24_releases(self) -> None:
        self.assertEqual(
            ci_topology.CHECKOUT_ACTION_SHA,
            "3d3c42e5aac5ba805825da76410c181273ba90b1",
        )
        self.assertEqual(
            ci_topology.CODEQL_ACTION_SHA,
            "e4fba868fa4b1b91e1fdab776edc8cfbe6e9fb81",
        )
        for name in ("ci.yml", "codeql.yml"):
            workflow = (
                ci_topology.REPO_ROOT / ".github" / "workflows" / name
            ).read_text(encoding="utf-8")
            self.assertNotIn("actions/checkout@v4", workflow, name)
            self.assertNotIn(
                "11bd71901bbe5b1630ceea73d27597364c9af683",
                workflow,
                name,
            )
        codeql = self._workflow()
        self.assertNotIn(
            "github/codeql-action/",
            codeql.replace(
                "github/codeql-action/init@e4fba868fa4b1b91e1fdab776edc8cfbe6e9fb81",
                "",
            ).replace(
                "github/codeql-action/analyze@e4fba868fa4b1b91e1fdab776edc8cfbe6e9fb81",
                "",
            ),
        )

    def test_missing_workflow_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-workflow-inventory-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_root = self._write_inventory(repo)
            (workflow_root / "codeql.yml").unlink()
            with self.assertRaisesRegex(AssertionError, "inventory mismatch"):
                ci_topology.check_workflow_inventory(repo)

    def test_extra_yaml_workflow_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-workflow-inventory-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_root = self._write_inventory(repo)
            (workflow_root / "surprise.yaml").write_text(
                "name: Surprise\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, "inventory mismatch"):
                ci_topology.check_workflow_inventory(repo)

    def test_symlinked_workflow_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-workflow-inventory-") as raw_tmp:
            repo = Path(raw_tmp)
            workflow_root = self._write_inventory(repo)
            (workflow_root / "codeql.yml").unlink()
            (workflow_root / "codeql.yml").symlink_to("ci.yml")
            with self.assertRaisesRegex(AssertionError, "symlink"):
                ci_topology.check_workflow_inventory(repo)

    def test_all_required_triggers_are_pinned(self) -> None:
        workflow = self._workflow()
        mutations = {
            "push": workflow.replace(
                "  push:\n    branches: [main]\n",
                "",
                1,
            ),
            "pull_request": workflow.replace(
                "  pull_request:\n    branches: [main]\n",
                "",
                1,
            ),
            "schedule": workflow.replace(
                '  schedule:\n    - cron: "23 4 * * 1"\n',
                "",
                1,
            ),
            "workflow_dispatch": workflow.replace("  workflow_dispatch:\n", "", 1),
        }
        for trigger, mutated in mutations.items():
            with self.subTest(trigger=trigger):
                self._reject(mutated, "trigger mismatch")

    def test_security_event_write_permission_is_required(self) -> None:
        self._reject(
            self._workflow().replace(
                "  security-events: write",
                "  security-events: read",
                1,
            ),
            "permission mismatch",
        )

    def test_codeql_autobuild_is_rejected(self) -> None:
        workflow = self._workflow()
        marker = "      - name: Analyze C and C++\n"
        mutated = workflow.replace(
            marker,
            "      - name: Autobuild\n"
            "        uses: github/codeql-action/autobuild@"
            f"{ci_topology.CODEQL_ACTION_SHA}"
            " # v4.37.3\n\n" + marker,
            1,
        )
        self._reject(mutated, "autobuild")

    def test_native_job_requires_the_real_manual_build(self) -> None:
        self._reject(
            self._workflow().replace(
                "        run: pixi run build-native",
                "        run: true",
                1,
            ),
            "manual build",
        )

    def test_python_job_must_not_build_the_product(self) -> None:
        workflow = self._workflow()
        marker = "      - name: Analyze Python\n"
        mutated = workflow.replace(
            marker,
            "      - name: Build product\n        run: pixi run build\n\n" + marker,
            1,
        )
        self._reject(mutated, "Python job must not run shell commands")

    def test_action_tag_in_place_of_commit_is_rejected(self) -> None:
        self._reject(
            self._workflow().replace(
                f"github/codeql-action/init@{ci_topology.CODEQL_ACTION_SHA}",
                "github/codeql-action/init@v3",
                1,
            ),
            "action pin mismatch",
        )


class MemoryHostSupportTests(unittest.TestCase):
    """Behavior of the command `ci-memory` runs off linux-64.

    These live beside the topology tests because the module exists only to make
    the platform-scoped task honest: it is task-placement policy, not a memory
    checker of its own.
    """

    def _run(self, system: str) -> tuple[int, str, str]:
        """Run the fallback for one host, capturing both streams."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = host_support.main(system)
        return status, out.getvalue(), err.getvalue()

    def test_a_foreign_platform_reports_the_uncovered_lanes(self) -> None:
        status, out, err = self._run("Darwin")
        self.assertEqual(status, 0)
        self.assertEqual(err, "")
        self.assertIn("SKIPPED on Darwin", out)
        for lane in host_support.LANES:
            self.assertIn(lane, out, lane)

    def test_linux_reaching_the_fallback_fails_closed(self) -> None:
        # Arriving here on Linux means the manifest override was removed, so
        # the lanes would have been skipped on the one platform that runs them.
        status, out, err = self._run("Linux")
        self.assertEqual(status, 1)
        self.assertEqual(out, "")
        self.assertIn("FATAL", err)
        self.assertIn(ci_topology.MEMORY_PLATFORM, err)

    def test_the_reported_lanes_match_the_pinned_aggregate(self) -> None:
        self.assertEqual(list(host_support.LANES), ci_topology.MEMORY_LANE_TASKS)


if __name__ == "__main__":
    unittest.main()
