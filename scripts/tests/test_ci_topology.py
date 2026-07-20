#!/usr/bin/env python3
"""Mutation tests for exact Pixi and hosted-CI topology policy."""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from scripts.checks import ci_topology


class CiTopologyTests(unittest.TestCase):
    def test_repository_root_tracks_the_nested_checker(self) -> None:
        self.assertEqual(
            ci_topology.REPO_ROOT,
            Path(__file__).resolve().parents[2],
        )

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

    def test_matrix_role_mutation_is_rejected_by_fixed_oracle(self) -> None:
        workflow = (
            ci_topology.REPO_ROOT / ".github" / "workflows" / "ci.yml"
        ).read_text(encoding="utf-8")
        mutated = workflow.replace("task: test-direct", "task: test", 1)
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
