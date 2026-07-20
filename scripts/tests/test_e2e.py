#!/usr/bin/env python3
"""Focused tests for E2E native fault-source and command topology."""

from __future__ import annotations

import inspect
from dataclasses import FrozenInstanceError
import os
from pathlib import Path
import stat
import tempfile
import time
import unittest

from scripts.checks import layout
from scripts.e2e import __main__ as e2e_main
from scripts.e2e import main_open
from scripts.e2e import runner
from scripts.fixtures.toolchain import fake_retry_crash_mojo


def _write_executable(path: Path, source: str) -> None:
    path.write_text(source, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)






CORE_SCENARIOS = (
    "manifest-completeness",
    "default-suite",
    "hostile",
    "single-pass",
    "exitfirst",
    "maxfail",
    "exclude+stale",
    "all-excluded",
    "empty-dir",
    "failing-gate",
    "quiet-verbose",
    "show-output",
    "durations",
    "color",
    "passthrough+forbidden",
    "out-of-root",
)
SELECTION_SCENARIOS = (
    "usage-refusals",
    "selection-keyword",
    "selection-node-id",
    "selection-union",
    "selection-malformed-node-id",
    "selection-unknown-test",
    "selection-empty",
    "selection-chameleon",
    "single-build",
    "stale-recovery-two-builds",
    "collect",
)
RESILIENCE_SCENARIOS = (
    "resilience-matrix",
    "retries-flaky",
    "crash-attribution",
    "attribution-reruns-crashed-binary",
    "compile-timeout",
    "compile-crash-signature",
    "timeout",
    "timeout-escalation",
    "precompile",
    "precompile-timeout",
    "precompile-crash-retry",
    "precompile-promotion",
    "internal-error",
    "runtime-open-failure",
    "interrupt",
)
JSON_SCENARIOS = (
    "json-forward-compat",
    "json-purity",
    "json-color-relocated-stderr",
    "json-destination-taxonomy",
    "json-truncation-interrupt",
    "json-truncation-sigkill",
    "json-truncation-dead-pipe",
    "json-terminal-write-failure",
)
JUNIT_SCENARIOS = (
    "junit-scratch-cleanup",
    "junit-schema-gate",
    "junit-determinism",
    "junit-prior-report-intact",
    "junit-finalization-and-interrupt",
)
ANNOTATION_SCENARIOS = (
    "annotations-modes",
    "annotations-caps",
    "annotations-conflict",
    "annotations-fencing",
)










class E2EFaultTopologyTests(unittest.TestCase):
    def test_master_registry_has_exact_pinned_order_and_unique_names(self) -> None:
        names = tuple(name for name, _scenario in e2e_main.SCENARIOS)

        self.assertEqual(names, layout.E2E_SCENARIO_NAMES)
        self.assertEqual(len(names), 59)
        self.assertEqual(len(set(names)), len(names))

    def test_core_scenarios_have_one_feature_owner(self) -> None:
        from scripts.e2e.scenarios import core

        owned = tuple(
            name
            for name, scenario in e2e_main.SCENARIOS
            if scenario.__module__ == core.__name__
        )
        self.assertEqual(owned, CORE_SCENARIOS)

    def test_selection_scenarios_have_one_feature_owner(self) -> None:
        from scripts.e2e.scenarios import selection

        owned = tuple(
            name
            for name, scenario in e2e_main.SCENARIOS
            if scenario.__module__ == selection.__name__
        )
        self.assertEqual(owned, SELECTION_SCENARIOS)

    def test_resilience_scenarios_have_one_feature_owner(self) -> None:
        from scripts.e2e.scenarios import resilience

        owned = tuple(
            name
            for name, scenario in e2e_main.SCENARIOS
            if scenario.__module__ == resilience.__name__
        )
        self.assertEqual(owned, RESILIENCE_SCENARIOS)
        source = inspect.getsource(resilience.s_resilience_matrix)
        self.assertIn("context.registry", source)
        self.assertNotIn("__main__", inspect.getsource(resilience))

    def test_json_scenarios_have_one_feature_owner(self) -> None:
        from scripts.e2e.scenarios import json_reporter

        owned = tuple(
            name
            for name, scenario in e2e_main.SCENARIOS
            if scenario.__module__ == json_reporter.__name__
        )
        self.assertEqual(owned, JSON_SCENARIOS)

    def test_junit_scenarios_have_one_feature_owner(self) -> None:
        from scripts.e2e.scenarios import junit_reporter

        owned = tuple(
            name
            for name, scenario in e2e_main.SCENARIOS
            if scenario.__module__ == junit_reporter.__name__
        )
        self.assertEqual(owned, JUNIT_SCENARIOS)

    def test_annotation_scenarios_have_one_feature_owner(self) -> None:
        from scripts.e2e.scenarios import annotations

        owned = tuple(
            name
            for name, scenario in e2e_main.SCENARIOS
            if scenario.__module__ == annotations.__name__
        )
        self.assertEqual(owned, ANNOTATION_SCENARIOS)

    def test_runner_owns_results_manifest_access_and_hard_timeouts(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-e2e-runner-") as raw_tmp:
            tmp = Path(raw_tmp)
            closes_streams = tmp / "closes-streams"
            _write_executable(
                closes_streams,
                "#!/usr/bin/env python3\n"
                "import os\n"
                "import time\n"
                "os.close(1)\n"
                "os.close(2)\n"
                "time.sleep(30)\n",
            )
            process_runner = runner.E2ERunner(
                repo_root=tmp,
                mtest=closes_streams,
                default_timeout=0.1,
                short_timeout=0.1,
            )

            started = time.monotonic()
            with self.assertRaisesRegex(
                runner.ScenarioError, "did not return within 0.1s"
            ):
                process_runner.run_mtest([])
            self.assertLess(time.monotonic() - started, 2.0)

            started = time.monotonic()
            with self.assertRaisesRegex(
                runner.ScenarioError, "closed its pty but never exited"
            ):
                process_runner.run_mtest_pty([])
            self.assertLess(time.monotonic() - started, 2.0)

        self.assertIs(e2e_main.ScenarioContext, runner.ScenarioContext)
        self.assertEqual(
            runner.load_manifest()["e2e_root"],
            "e2e",
        )
        self.assertEqual(
            set(runner.load_manifest()["tests"]),
            runner.discovered_test_files(),
        )

    def test_main_open_has_one_package_owner(self) -> None:
        self.assertEqual(main_open.__name__, "scripts.e2e.main_open")

    def test_scenarios_receive_an_explicit_immutable_context(self) -> None:
        registry = tuple(e2e_main.SCENARIOS)
        context = runner.ScenarioContext(manifest={}, registry=registry)

        self.assertIs(context.registry, registry)
        with self.assertRaises(FrozenInstanceError):
            context.registry = ()
        for name, scenario in registry:
            with self.subTest(scenario=name):
                self.assertEqual(
                    tuple(inspect.signature(scenario).parameters),
                    ("context",),
                )

    def test_harness_passes_the_context_and_contains_later_scenarios(self) -> None:
        registry = ()
        context = runner.ScenarioContext(
            manifest={"sentinel": 42}, registry=registry
        )
        harness = e2e_main.Harness(context)
        received: list[runner.ScenarioContext] = []

        def crashes(scenario_context: runner.ScenarioContext) -> str:
            received.append(scenario_context)
            raise RuntimeError("escaped")

        def passes(scenario_context: runner.ScenarioContext) -> str:
            received.append(scenario_context)
            return "continued"

        harness.scenario("crashes", crashes)
        harness.scenario("passes", passes)

        self.assertEqual(received, [context, context])
        self.assertEqual(
            [name for name, _ok, _detail in harness.results],
            ["crashes", "passes"],
        )
        self.assertFalse(harness.results[0][1])
        self.assertIn("RuntimeError escaped", harness.results[0][2])
        self.assertEqual(harness.results[1], ("passes", True, "continued"))

    def test_resilience_audit_reads_the_context_registry(self) -> None:
        from scripts.e2e.scenarios import resilience

        def harmless(_context: runner.ScenarioContext) -> str:
            return ""

        names = tuple(dict.fromkeys(resilience.RESILIENCE_MATRIX.values()))
        context = runner.ScenarioContext(
            manifest={},
            registry=tuple((name, harmless) for name in names),
        )
        original = e2e_main.SCENARIOS
        e2e_main.SCENARIOS = ()
        try:
            detail = resilience.s_resilience_matrix(context)
        finally:
            e2e_main.SCENARIOS = original

        self.assertIn("each covered by a registered scenario", detail)

    def test_paths_and_retry_marker_are_repository_anchored(self) -> None:
        root = Path(__file__).resolve().parents[2]
        fixture_root = root / "scripts" / "fixtures" / "toolchain"
        self.assertEqual(
            (
                Path(runner.LOGGING_MOJO),
                Path(runner.FAKE_SLOW_MOJO),
                Path(runner.FAKE_CRASH_MOJO),
                Path(runner.FAKE_RETRY_CRASH_MOJO),
            ),
            (
                fixture_root / "logging_mojo.py",
                fixture_root / "fake_slow_mojo.py",
                fixture_root / "fake_crash_mojo.py",
                fixture_root / "fake_retry_crash_mojo.py",
            ),
        )
        self.assertEqual(Path(fake_retry_crash_mojo.REPO_ROOT), root)
        self.assertEqual(
            Path(fake_retry_crash_mojo.MARKER),
            root / "build" / "e2e-scratch" / "retry_crash_build_marker",
        )

    def test_toolchain_fixtures_remain_executable(self) -> None:
        for fixture in (
            runner.LOGGING_MOJO,
            runner.FAKE_SLOW_MOJO,
            runner.FAKE_CRASH_MOJO,
            runner.FAKE_RETRY_CRASH_MOJO,
        ):
            with self.subTest(fixture=fixture):
                self.assertTrue(os.access(fixture, os.X_OK))





if __name__ == "__main__":
    unittest.main()
