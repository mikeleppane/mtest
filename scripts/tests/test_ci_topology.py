#!/usr/bin/env python3
"""Mutation tests for exact Pixi and hosted-CI topology policy."""

from __future__ import annotations

from pathlib import Path
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
            ["ci-preflight", "test", "dogfood-check", "e2e"],
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
