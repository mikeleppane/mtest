#!/usr/bin/env python3
"""Focused tests for the manually invoked release-contract oracle."""

from __future__ import annotations

from pathlib import Path
import tomllib
import unittest

from scripts.qa import contract


class ContractToolLocationTests(unittest.TestCase):
    def test_nested_module_discovers_the_repository_root(self) -> None:
        repo_root = Path(__file__).resolve().parents[2]

        self.assertEqual(contract.REPO, repo_root)
        self.assertEqual(contract.find_repo_root(Path(contract.__file__)), repo_root)
        self.assertEqual(contract.MTEST, repo_root / "build" / "mtest")

    def test_pixi_task_uses_the_package_entry_point(self) -> None:
        tasks = tomllib.loads(
            (contract.REPO / "pixi.toml").read_text(encoding="utf-8")
        )["tasks"]

        self.assertEqual(tasks["contract-check"], "python -m scripts.qa.contract")
        self.assertNotIn("contract-check", tasks["ci"]["depends-on"])
        self.assertNotIn("contract-check", tasks["ci-preflight"]["depends-on"])


if __name__ == "__main__":
    unittest.main()
