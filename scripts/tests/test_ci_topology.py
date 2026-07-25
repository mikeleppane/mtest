#!/usr/bin/env python3
"""Mutation tests for exact Pixi and hosted-CI topology policy."""

from __future__ import annotations

from pathlib import Path
import re
import tempfile
import tomllib
import unittest

from scripts.checks import ci_topology


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
            ["ci-preflight", "test", "dogfood-check", "e2e", "contract-check-strict"],
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
        expected = "\n".join(
            (
                "$ pixi run fmt",
                "$ pixi run test-file -- PATH",
                "$ pixi run test",
                "$ pixi run e2e",
                "$ pixi run ci",
            )
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
            contents = (ci_topology.REPO_ROOT / relative).read_text(
                encoding="utf-8"
            )
            self.assertNotIn("test-direct", contents, relative)

    def test_obsolete_test_alias_mutation_is_rejected(self) -> None:
        source = (ci_topology.REPO_ROOT / "pixi.toml").read_text(encoding="utf-8")
        mutated = source.replace(
            'test = "python -m scripts.harness.classified tests/unit tests/integration"',
            'test-direct = "python -m scripts.harness.classified tests/unit tests/integration"\n'
            'test = "python -m scripts.harness.classified tests/unit tests/integration"',
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
            matches = [row for row in rows if row.get("task") == "contract-check-strict"]
            self.assertEqual(len(matches), 1, rows)
            self.assertEqual(matches[0], {"runner": runner, **expected_row})

    def test_contract_row_runs_after_e2e_in_declared_order(self) -> None:
        linux_tasks = [row["task"] for row in ci_topology.LINUX_MATRIX_ROWS]
        macos_tasks = [row["task"] for row in ci_topology.MACOS_MATRIX_ROWS]
        self.assertEqual(
            linux_tasks,
            ["test", "dogfood-check", "e2e", "contract-check-strict", "asan-check", "valgrind-check"],
        )
        self.assertEqual(
            macos_tasks,
            ["test", "dogfood-check", "e2e", "contract-check-strict"],
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


if __name__ == "__main__":
    unittest.main()
