#!/usr/bin/env python3
"""Focused tests for the manually invoked release-contract oracle."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import time
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
        self.assertEqual(
            tasks["contract-check-strict"],
            {
                "cmd": "python -m scripts.qa.contract --strict --no-rebuild",
                "depends-on": ["build-bin"],
            },
        )
        self.assertIn("contract-check-strict", tasks["ci"]["depends-on"])
        self.assertNotIn("contract-check-strict", tasks["ci-preflight"]["depends-on"])


class EnsureBinaryFailsClosedTests(unittest.TestCase):
    """`--no-rebuild` must never validate a missing or stale binary.

    `ensure_binary` takes the binary path and its input paths explicitly so
    these tests exercise the real fail-closed/build-triggering logic against
    a disposable temp tree — never the repo's own `build/mtest` — and never
    invoke `pixi`/`mojo`.
    """

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="mtest-contract-binary-")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.binary = root / "build" / "mtest"
        self.binary.parent.mkdir(parents=True)
        self.src = root / "src"
        self.src.mkdir()
        self.input_paths = [self.src]
        self.build_calls: list[dict[str, str]] = []

    def _fake_build(self, env: dict[str, str]) -> subprocess.CompletedProcess:
        self.build_calls.append(env)
        self.binary.write_text("built")
        return subprocess.CompletedProcess(args=["fake-build"], returncode=0)

    def test_missing_binary_with_no_rebuild_dies_closed(self) -> None:
        with self.assertRaises(SystemExit) as ctx:
            contract.ensure_binary(
                self.binary, self.input_paths, {}, rebuild=False,
                allow_rebuild=False, build=self._fake_build,
            )
        self.assertEqual(ctx.exception.code, 2)
        self.assertEqual(self.build_calls, [])

    def test_stale_binary_with_no_rebuild_dies_closed(self) -> None:
        self.binary.write_text("old")
        stale_time = time.time() - 100
        os.utime(self.binary, (stale_time, stale_time))
        (self.src / "main.mojo").write_text("code")  # newer than the binary

        with self.assertRaises(SystemExit) as ctx:
            contract.ensure_binary(
                self.binary, self.input_paths, {}, rebuild=False,
                allow_rebuild=False, build=self._fake_build,
            )
        self.assertEqual(ctx.exception.code, 2)
        self.assertEqual(self.build_calls, [])

    def test_fresh_binary_with_no_rebuild_returns_without_building(self) -> None:
        (self.src / "main.mojo").write_text("code")
        self.binary.write_text("built")  # written after the source -> fresh

        contract.ensure_binary(
            self.binary, self.input_paths, {}, rebuild=False,
            allow_rebuild=False, build=self._fake_build,
        )
        self.assertEqual(self.build_calls, [])

    def test_missing_binary_with_rebuild_allowed_builds_once(self) -> None:
        contract.ensure_binary(
            self.binary, self.input_paths, {}, rebuild=False,
            allow_rebuild=True, build=self._fake_build,
        )
        self.assertEqual(len(self.build_calls), 1)
        self.assertTrue(self.binary.is_file())

    def test_failed_build_dies_closed(self) -> None:
        def failing_build(env: dict[str, str]) -> subprocess.CompletedProcess:
            self.build_calls.append(env)
            return subprocess.CompletedProcess(args=["fake-build"], returncode=1)

        with self.assertRaises(SystemExit) as ctx:
            contract.ensure_binary(
                self.binary, self.input_paths, {}, rebuild=False,
                allow_rebuild=True, build=failing_build,
            )
        self.assertEqual(ctx.exception.code, 2)
        self.assertEqual(len(self.build_calls), 1)

    def test_binary_input_paths_cover_the_documented_provenance_set(self) -> None:
        # The mtime scan is a fail-closed HEURISTIC, not a content-identity
        # proof (that proof is the Pixi `contract-check-strict -> build-bin`
        # task edge) — but it must at least cover every documented input.
        expected = {
            contract.REPO / "src",
            contract.REPO / "native",
            contract.REPO / "scripts" / "build" / "production_build.sh",
            contract.REPO / "scripts" / "build" / "native.py",
            contract.REPO / "scripts" / "build" / "native_strict_flags.txt",
            contract.REPO / "pixi.toml",
            contract.REPO / "pixi.lock",
        }
        self.assertEqual(set(contract.BINARY_INPUT_PATHS), expected)


class WaitUntilBoundedPollTests(unittest.TestCase):
    """Negative controls for the SIGINT probe's bounded readiness/absence
    barrier, which replaced fixed `time.sleep` calls. These exercise the
    pure polling primitive directly — no subprocess, no real mtest binary —
    so they stay fast and deterministic.
    """

    def test_child_never_became_ready_returns_false_within_bound(self) -> None:
        calls = []

        def never_ready() -> bool:
            calls.append(1)
            return False

        start = time.time()
        ok = contract.wait_until(never_ready, deadline=start + 0.2, poll_interval=0.02)
        elapsed = time.time() - start

        self.assertFalse(ok)
        self.assertLess(elapsed, 2.0)
        self.assertGreaterEqual(len(calls), 2)

    def test_child_survived_cleanup_returns_false_when_presence_persists(self) -> None:
        # The orphan barrier polls `not present()`; a child that never exits
        # keeps `present` True forever, so the barrier must report "not
        # gone" within its bound instead of waiting indefinitely.
        def still_present() -> bool:
            return True

        start = time.time()
        gone = contract.wait_until(
            lambda: not still_present(), deadline=start + 0.2, poll_interval=0.02
        )

        self.assertFalse(gone)

    def test_predicate_becoming_true_returns_as_soon_as_it_does(self) -> None:
        calls = {"n": 0}

        def ready_after_two_polls() -> bool:
            calls["n"] += 1
            return calls["n"] >= 2

        ok = contract.wait_until(ready_after_two_polls, deadline=time.time() + 5, poll_interval=0.01)

        self.assertTrue(ok)
        self.assertEqual(calls["n"], 2)


if __name__ == "__main__":
    unittest.main()
