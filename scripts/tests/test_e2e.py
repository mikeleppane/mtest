#!/usr/bin/env python3
"""Focused tests for E2E native fault-source and command topology."""

from __future__ import annotations

import contextlib
import inspect
from dataclasses import FrozenInstanceError
import os
from pathlib import Path
import resource
import signal
import stat
import subprocess
import sys
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


# A stand-in leader: it forks ONE child into its own process group, has that
# child record the group's real id and announce readiness, and then waits. This
# is the shape `run_mtest_signaled` must reason about — a leader whose children
# live in groups of their own — reduced to something that starts instantly.
_FAKE_LEADER = """import os
import signal
import subprocess
import sys
import time

pgid_file, ready_file, answers = sys.argv[1], sys.argv[2], sys.argv[3]
child = subprocess.Popen(
    [
        sys.executable,
        "-c",
        (
            "import os, sys, time\\n"
            "open(sys.argv[1], 'w').write(str(os.getpgrp()) + chr(10))\\n"
            "open(sys.argv[2], 'w').write('ready' + chr(10))\\n"
            "time.sleep(300)\\n"
        ),
        pgid_file,
        ready_file,
    ],
    start_new_session=True,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)


def _teardown(signum, frame):
    if answers == "yes":
        os.killpg(os.getpgid(child.pid), signal.SIGKILL)
        child.wait()
        sys.exit(2)


signal.signal(signal.SIGINT, _teardown)
signal.signal(signal.SIGTERM, _teardown)
time.sleep(300)
"""


@contextlib.contextmanager
def _recorded_signals():
    """Record every `os.kill`/`os.killpg` the runner issues, in order."""
    calls: list[tuple[str, int, int]] = []
    real_kill, real_killpg = runner.os.kill, runner.os.killpg

    def kill(pid: int, sig: int) -> None:
        calls.append(("kill", pid, sig))
        real_kill(pid, sig)

    def killpg(pgid: int, sig: int) -> None:
        calls.append(("killpg", pgid, sig))
        real_killpg(pgid, sig)

    runner.os.kill, runner.os.killpg = kill, killpg
    try:
        yield calls
    finally:
        runner.os.kill, runner.os.killpg = real_kill, real_killpg






CORE_SCENARIOS = (
    "manifest-completeness",
    "default-suite",
    "hostile",
    "hostile-console",
    "hostile-reporters",
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
    "mojo-executable-precedence",
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
    "interrupt-sigterm",
    "interrupt-double",
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
PARALLEL_SCENARIOS = (
    "parallel-projection-eq",
    "parallel-capacity-one",
    "parallel-window-overlap",
    "parallel-interrupt",
    "parallel-shard-disjoint",
    "collect-parallel",
    "parallel-auto-smoke",
    "parallel-json-workers",
    "parallel-j-rejected",
    "parallel-junit-canonical-eq",
    "parallel-progress-tty",
    "parallel-serial-noverlap",
    "parallel-serial-stale-glob",
    "parallel-fd-clamp",
)
CONFIG_SCENARIOS = (
    "config-resolution",
    "config-diagnostics",
    "config-state",
    "failure-reselection",
    "config-overrides",
)
CONFIG_SHOW_SCENARIOS = ("config-show",)










class E2EFaultTopologyTests(unittest.TestCase):
    def test_master_registry_has_exact_pinned_order_and_unique_names(self) -> None:
        names = tuple(name for name, _scenario in e2e_main.SCENARIOS)

        self.assertEqual(names, layout.E2E_SCENARIO_NAMES)
        self.assertEqual(len(names), 91)
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

    def test_parallel_scenarios_have_one_feature_owner(self) -> None:
        from scripts.e2e.scenarios import parallel

        owned = tuple(
            name
            for name, scenario in e2e_main.SCENARIOS
            if scenario.__module__ == parallel.__name__
        )
        self.assertEqual(owned, PARALLEL_SCENARIOS)

    def test_config_scenarios_have_one_feature_owner(self) -> None:
        from scripts.e2e.scenarios import config_file

        owned = tuple(
            name
            for name, scenario in e2e_main.SCENARIOS
            if scenario.__module__ == config_file.__name__
        )
        self.assertEqual(owned, CONFIG_SCENARIOS)

    def test_config_show_scenarios_have_one_feature_owner(self) -> None:
        from scripts.e2e.scenarios import config_show

        owned = tuple(
            name
            for name, scenario in e2e_main.SCENARIOS
            if scenario.__module__ == config_show.__name__
        )
        self.assertEqual(owned, CONFIG_SHOW_SCENARIOS)

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

    def _signalled_run(
        self, tmp: Path, *, answers: bool, signal_number: int
    ) -> tuple[list[tuple[str, int, int]], int, int, int]:
        """Drive one `run_mtest_signaled` against the fake leader.

        Args:
            tmp: A scratch directory this call owns.
            answers: Whether the fake leader cleans its child group up and exits,
                as a live mtest does for a managed interrupt.
            signal_number: The signal delivered to the leader.

        Returns:
            The recorded signal calls, the run's exit code, the leader's pgid,
            and the child group's real pgid.
        """
        leader = tmp / "fake-leader"
        _write_executable(leader, f"#!{sys.executable}\n" + _FAKE_LEADER)
        pgid_file = tmp / "child.pgid"
        ready_file = tmp / "child.ready"
        process_runner = runner.E2ERunner(repo_root=tmp, mtest=leader)
        with _recorded_signals() as calls:
            run, pgid = process_runner.run_mtest_signaled(
                [os.fspath(pgid_file), os.fspath(ready_file), "yes" if answers else "no"],
                signal_number=signal_number,
                timeout=30.0,
                ready_files=(os.fspath(ready_file),),
                owned_pgid_files=(os.fspath(pgid_file),),
            )
        child_pgid = int(pgid_file.read_text(encoding="utf-8").strip())
        return list(calls), run.returncode, pgid, child_pgid

    def test_a_managed_interrupt_signals_only_the_leader(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-signal-topology-") as raw:
            calls, returncode, pgid, child_pgid = self._signalled_run(
                Path(raw), answers=True, signal_number=signal.SIGINT
            )

        self.assertEqual(returncode, 2)
        self.assertNotEqual(child_pgid, pgid)
        # `os.kill(leader)` and `os.killpg(leader_group)` carry the same number,
        # so WHICH call was made is the whole distinction: forwarding the signal
        # to the group is the product's job, and a harness that did it itself
        # would pass even against a product that forwarded nothing.
        terminating = [call for call in calls if call[2] != 0]
        self.assertEqual(terminating, [("kill", pgid, int(signal.SIGINT))])
        self.assertTrue(
            all(call[2] == 0 for call in calls if call[0] == "killpg"),
            f"a managed interrupt used killpg for more than existence: {calls}",
        )

    def test_a_fatal_signal_sweeps_recorded_groups_after_the_leader(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-signal-fatal-") as raw:
            calls, _returncode, pgid, child_pgid = self._signalled_run(
                Path(raw), answers=False, signal_number=signal.SIGKILL
            )

        self.assertNotEqual(child_pgid, pgid)
        terminating = [call for call in calls if call[2] != 0]
        # The leader is signalled first, alone. Only then — mtest cannot clean up
        # after its own death — does the harness sweep the group it recorded.
        self.assertEqual(terminating[0], ("kill", pgid, int(signal.SIGKILL)))
        self.assertTrue(terminating[1:], "the orphaned child group was never swept")
        for name, target, _sig in terminating[1:]:
            self.assertEqual(name, "killpg")
            self.assertEqual(target, child_pgid)
        self.assertFalse(
            runner.group_alive(child_pgid),
            f"child group {child_pgid} survived the harness sweep",
        )

    def test_group_sweep_reads_eperm_as_a_gone_group(self) -> None:
        """Darwin reports EPERM, not ESRCH, for a zombie-only process group."""
        proc = subprocess.Popen(
            [sys.executable, "-c", "import time\ntime.sleep(30)\n"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        pgid = os.getpgid(proc.pid)
        attempts: list[tuple[int, int]] = []
        real_killpg = runner.os.killpg

        def killpg(target: int, sig: int) -> None:
            attempts.append((target, sig))
            raise PermissionError(1, "Operation not permitted")

        runner.os.killpg = killpg
        try:
            # Escaping here would replace the caller's own diagnosis with an
            # unrelated exception raised from cleanup.
            runner.E2ERunner.kill_group(proc)
        finally:
            runner.os.killpg = real_killpg
            real_killpg(pgid, signal.SIGKILL)
            proc.wait()
        self.assertEqual(
            attempts,
            [(pgid, int(signal.SIGTERM))],
            f"EPERM did not end the group sweep: {attempts}",
        )

    def test_signalled_runs_reject_ambiguous_arming(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-signal-arming-") as raw:
            tmp = Path(raw)
            leader = tmp / "fake-leader"
            _write_executable(leader, f"#!{sys.executable}\nimport time\ntime.sleep(30)\n")
            process_runner = runner.E2ERunner(repo_root=tmp, mtest=leader)
            for kwargs in (
                {},
                {"ready_files": (os.fspath(tmp / "x"),), "delay": 1.0},
            ):
                with self.subTest(arming=sorted(kwargs)):
                    with self.assertRaisesRegex(
                        runner.ScenarioError, "exactly one arming input"
                    ):
                        process_runner.run_mtest_signaled(
                            [],
                            signal_number=signal.SIGINT,
                            timeout=1.0,
                            **kwargs,
                        )

    def test_a_half_armed_barrier_still_sweeps_the_live_actor(self) -> None:
        # The failure path that is supposed to clean up must not be the one that
        # strands a process: an actor that armed before the barrier expired lives
        # in a process group of its own, which killing the leader's group cannot
        # reach, and the e2e actors hold for an hour.
        with tempfile.TemporaryDirectory(prefix="mtest-signal-halfarmed-") as raw:
            tmp = Path(raw)
            leader = tmp / "fake-leader"
            _write_executable(leader, f"#!{sys.executable}\n" + _FAKE_LEADER)
            pgid_file = tmp / "child.pgid"
            ready_file = tmp / "child.ready"
            never = tmp / "second-actor.ready"
            process_runner = runner.E2ERunner(repo_root=tmp, mtest=leader)

            with self.assertRaisesRegex(
                runner.ScenarioError, "readiness barrier never appeared"
            ):
                process_runner.run_mtest_signaled(
                    [os.fspath(pgid_file), os.fspath(ready_file), "no"],
                    signal_number=signal.SIGINT,
                    timeout=5.0,
                    ready_files=(os.fspath(ready_file), os.fspath(never)),
                    owned_pgid_files=(os.fspath(pgid_file),),
                )

            child_pgid = int(pgid_file.read_text(encoding="utf-8").strip())
            self.assertFalse(
                runner.group_alive(child_pgid),
                f"the armed actor's group {child_pgid} survived a barrier "
                "expiry — it would sleep on the host for an hour",
            )

    def test_a_readiness_barrier_fails_instead_of_proceeding(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mtest-signal-barrier-") as raw:
            tmp = Path(raw)
            leader = tmp / "fake-leader"
            _write_executable(
                leader, f"#!{sys.executable}\nimport time\ntime.sleep(30)\n"
            )
            process_runner = runner.E2ERunner(repo_root=tmp, mtest=leader)
            started = time.monotonic()
            with self.assertRaisesRegex(
                runner.ScenarioError, "readiness barrier never appeared"
            ):
                process_runner.run_mtest_signaled(
                    [],
                    signal_number=signal.SIGINT,
                    timeout=0.5,
                    ready_files=(os.fspath(tmp / "never-written"),),
                )
            self.assertLess(time.monotonic() - started, 10.0)

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
                Path(runner.FAKE_STUBBORN_MOJO),
                Path(runner.FAKE_FD_MOJO),
                Path(runner.FAKE_HOSTILE_MOJO),
                Path(runner.PATH_MOJO),
            ),
            (
                fixture_root / "logging_mojo.py",
                fixture_root / "fake_slow_mojo.py",
                fixture_root / "fake_crash_mojo.py",
                fixture_root / "fake_retry_crash_mojo.py",
                fixture_root / "fake_stubborn_mojo.py",
                fixture_root / "fake_fd_mojo.py",
                fixture_root / "fake_hostile_mojo.py",
                fixture_root / "path_mojo.py",
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
            runner.FAKE_STUBBORN_MOJO,
            runner.FAKE_FD_MOJO,
            runner.FAKE_HOSTILE_MOJO,
            runner.PATH_MOJO,
        ):
            with self.subTest(fixture=fixture):
                self.assertTrue(os.access(fixture, os.X_OK))


@unittest.skipUnless(
    hasattr(resource, "RLIMIT_NOFILE"),
    "this platform has no RLIMIT_NOFILE to lower",
)
class LimitNofileTests(unittest.TestCase):
    """`runner.limit_nofile` must change the CHILD, not merely be accepted.

    Every assertion here reads a limit the spawned process observed for itself
    and printed back, because a `preexec_fn` that was constructed, passed, and
    silently ignored would satisfy any check made on this side of the fork.
    """

    _REPORT_SOFT = (
        "import resource, sys;"
        "sys.stdout.write(str(resource.getrlimit(resource.RLIMIT_NOFILE)[0]))"
    )
    """A child that prints the soft `RLIMIT_NOFILE` the kernel gave it."""

    def _child_soft_limit(self, preexec) -> int:
        """The soft limit a child observes when spawned under `preexec`."""
        completed = subprocess.run(
            [sys.executable, "-c", self._REPORT_SOFT],
            capture_output=True,
            text=True,
            check=True,
            preexec_fn=preexec,
        )
        return int(completed.stdout.strip())

    def test_the_child_observes_the_lowered_soft_limit(self) -> None:
        parent_soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        target = 76
        if hard != resource.RLIM_INFINITY and hard < target:
            self.skipTest(f"the host's hard RLIMIT_NOFILE {hard} is below {target}")

        self.assertEqual(self._child_soft_limit(runner.limit_nofile(target)), target)
        # The parent is untouched: the limit is applied between the fork and the
        # exec, so lowering a child's ceiling must not lower this process's.
        self.assertEqual(
            resource.getrlimit(resource.RLIMIT_NOFILE), (parent_soft, hard)
        )

    def test_an_unlimited_child_keeps_this_process_limit(self) -> None:
        parent_soft, _hard = resource.getrlimit(resource.RLIMIT_NOFILE)

        # The control that makes the test above evidence rather than a tautology:
        # without the preexec_fn the child inherits, so 76 can only have come
        # from `limit_nofile`.
        self.assertEqual(self._child_soft_limit(None), parent_soft)

    def test_the_hard_limit_is_carried_through_unchanged(self) -> None:
        _parent_soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        target = 76
        if hard != resource.RLIM_INFINITY and hard < target:
            self.skipTest(f"the host's hard RLIMIT_NOFILE {hard} is below {target}")

        completed = subprocess.run(
            [
                sys.executable,
                "-c",
                "import resource, sys;"
                "sys.stdout.write(str(resource.getrlimit(resource.RLIMIT_NOFILE)))",
            ],
            capture_output=True,
            text=True,
            check=True,
            preexec_fn=runner.limit_nofile(target),
        )
        self.assertEqual(completed.stdout.strip(), str((target, hard)))





if __name__ == "__main__":
    unittest.main()
