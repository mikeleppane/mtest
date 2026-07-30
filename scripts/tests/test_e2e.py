#!/usr/bin/env python3
"""Focused tests for E2E native fault-source and command topology."""

from __future__ import annotations

import ast
import contextlib
from dataclasses import FrozenInstanceError
import inspect
import io
import os
from pathlib import Path
import re
import resource
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import TYPE_CHECKING, Any
import unittest
from unittest import mock

from scripts.e2e import __main__ as e2e_main
from scripts.e2e import main_open, runner
from scripts.e2e.scenarios import config_file, selection
from scripts.fixtures.toolchain import fake_retry_crash_mojo


if TYPE_CHECKING:
    from collections.abc import Callable, Iterator


def _write_executable(path: Path, source: str) -> None:
    path.write_text(source, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


# A stand-in leader: it forks ONE child into its own process group, has that
# child record the group's real id and announce readiness, then waits. That is
# the shape `run_mtest_signaled` must reason about (a leader whose children
# live in groups of their own), reduced to something that starts instantly.
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
def _recorded_signals() -> Iterator[list[tuple[str, int, int]]]:
    """Record every `os.kill`/`os.killpg` the runner issues, in order."""
    calls: list[tuple[str, int, int]] = []
    # `runner.os` IS this module's `os`, so patching here patches the object
    # the runner calls through.
    real_kill, real_killpg = os.kill, os.killpg

    def kill(pid: int, sig: int) -> None:
        calls.append(("kill", pid, sig))
        real_kill(pid, sig)

    def killpg(pgid: int, sig: int) -> None:
        calls.append(("killpg", pgid, sig))
        real_killpg(pgid, sig)

    os.kill, os.killpg = kill, killpg
    try:
        yield calls
    finally:
        os.kill, os.killpg = real_kill, real_killpg


class E2EFaultTopologyTests(unittest.TestCase):
    def test_single_build_count_disables_persistent_cache(self) -> None:
        calls: list[list[str]] = []

        def run_mtest(
            args: list[str],
            *,
            timeout: float | None = None,
            env_overrides: dict[str, str] | None = None,
        ) -> runner.Run:
            del timeout
            calls.append(args)
            if env_overrides is None:
                self.fail("scenario omitted the logging-wrapper environment")
            log_path = env_overrides["MTEST_MOJO_LOG"]
            lines = ["version\t--version\n"]
            if "--no-cache" in args:
                lines.extend(
                    [
                        f"build\t{selection.MATRIX_ALPHA}\tmojo build\n",
                        f"build\t{selection.MATRIX_BETA}\tmojo build\n",
                    ]
                )
            Path(log_path).write_text("".join(lines), encoding="utf-8")
            return runner.Run(
                argv=["mtest", *args],
                returncode=0,
                stdout="",
                stderr="",
                wall=0.0,
            )

        process_runner = mock.Mock(spec=runner.E2ERunner)
        process_runner.run_mtest.side_effect = run_mtest
        context = runner.ScenarioContext(
            manifest={},
            registry=(),
            runner=process_runner,
        )

        detail = selection.s_single_build(context)

        self.assertIn("each built exactly once", detail)
        self.assertEqual(
            calls,
            [
                [
                    "--mojo",
                    runner.LOGGING_MOJO,
                    "-k",
                    "one",
                    "e2e/matrix",
                    "--no-cache",
                ]
            ],
        )

    def test_config_serial_window_disables_persistent_cache(self) -> None:
        calls: list[list[str]] = []

        def run_mtest(
            args: list[str],
            *,
            timeout: float | None = None,
            env_overrides: dict[str, str] | None = None,
        ) -> runner.Run:
            del timeout
            calls.append(args)
            if len(calls) == 1:
                return runner.Run(
                    argv=["mtest", *args],
                    returncode=1,
                    stdout="TIMEOUT e2e/slow/test_hanging.mojo after 1s\n",
                    stderr="",
                    wall=1.0,
                )
            if len(calls) == 2:
                return runner.Run(
                    argv=["mtest", *args],
                    returncode=1,
                    stdout="",
                    stderr="collect timed out after 1s\n",
                    wall=1.0,
                )
            if env_overrides is None:
                self.fail("serial override omitted the window environment")
            if "--no-cache" in args:
                Path(env_overrides["MTEST_WINDOW_LOG"]).write_text(
                    "build\te2e/parallel/test_window_a.mojo\t1.0\n"
                    "build\te2e/parallel/test_window_a.mojo\t2.0\n"
                    "build\te2e/parallel/test_window_b.mojo\t1.0\n"
                    "build\te2e/parallel/test_window_b.mojo\t2.0\n"
                    "build\te2e/parallel/test_window_c.mojo\t3.0\n"
                    "build\te2e/parallel/test_window_c.mojo\t4.0\n",
                    encoding="utf-8",
                )
                Path(env_overrides["MTEST_WINDOW_RUN_LOG"]).write_text(
                    "run\ta\t1.0\n"
                    "run\ta\t2.0\n"
                    "run\tb\t1.0\n"
                    "run\tb\t2.0\n"
                    "run\tc\t3.0\n"
                    "run\tc\t4.0\n",
                    encoding="utf-8",
                )
            return runner.Run(
                argv=["mtest", *args],
                returncode=0,
                stdout="",
                stderr="",
                wall=4.0,
            )

        process_runner = mock.Mock(spec=runner.E2ERunner)
        process_runner.run_mtest.side_effect = run_mtest
        context = runner.ScenarioContext(
            manifest={},
            registry=(),
            runner=process_runner,
        )

        detail = config_file.s_config_overrides(context)

        self.assertIn("override serial=true drained serial-last", detail)
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[2][0], "--config")
        self.assertEqual(calls[2][2:], ["--no-cache"])

    def test_stale_recovery_build_count_disables_persistent_cache(self) -> None:
        calls: list[list[str]] = []

        def run_mtest(
            args: list[str],
            *,
            timeout: float | None = None,
            env_overrides: dict[str, str] | None = None,
        ) -> runner.Run:
            del timeout
            calls.append(args)
            if env_overrides is None:
                self.fail("scenario omitted the logging-wrapper environment")
            log_path = env_overrides["MTEST_MOJO_LOG"]
            build_count = 2 if "--no-cache" in args else 1
            Path(log_path).write_text(
                "".join(
                    f"build\t{selection.CHAMELEON}\tmojo build\n"
                    for _ in range(build_count)
                ),
                encoding="utf-8",
            )
            return runner.Run(
                argv=["mtest", *args],
                returncode=1,
                stdout=f"MALFORMED-SUITE {selection.CHAMELEON}\n",
                stderr="",
                wall=0.0,
            )

        process_runner = mock.Mock(spec=runner.E2ERunner)
        process_runner.run_mtest.side_effect = run_mtest
        context = runner.ScenarioContext(
            manifest={},
            registry=(),
            runner=process_runner,
        )

        detail = selection.s_stale_recovery_two_builds(context)

        self.assertIn("2 builds logged", detail)
        self.assertEqual(
            calls,
            [
                [
                    "--mojo",
                    runner.LOGGING_MOJO,
                    selection.CHAMELEON,
                    "-k",
                    "ghost",
                    "--no-cache",
                ]
            ],
        )

    def test_registry_names_are_unique_and_the_manifest_gate_runs_first(
        self,
    ) -> None:
        names = tuple(name for name, _scenario in e2e_main.SCENARIOS)

        # No roster and no total appear here: restating the list would cost an
        # edit per scenario to re-prove what the diff already shows. Two things
        # the diff does NOT show are asserted instead. A colliding name, and
        # the ordering: `manifest-completeness` reconciles `e2e/manifest.json`
        # against disk, so running it first turns a manifest drift into a
        # first-line failure rather than one found after every other scenario
        # has spent its build time.
        self.assertEqual(len(set(names)), len(names))
        self.assertEqual(names[0], "manifest-completeness")

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
                [
                    os.fspath(pgid_file),
                    os.fspath(ready_file),
                    "yes" if answers else "no",
                ],
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
        # so WHICH call was made is the distinction: forwarding to the group is
        # the product's job, and a harness doing it itself would pass against a
        # product that forwarded nothing.
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
        # The leader is signalled first, alone. Only then, since mtest cannot
        # clean up after its own death, does the harness sweep the group it
        # recorded.
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
        # `runner.os` IS this module's `os`: same object, same patch.
        real_killpg = os.killpg

        def killpg(target: int, sig: int) -> None:
            attempts.append((target, sig))
            raise PermissionError(1, "Operation not permitted")

        os.killpg = killpg
        try:
            # Escaping here would replace the caller's own diagnosis with an
            # unrelated exception raised from cleanup.
            runner.E2ERunner.kill_group(proc)
        finally:
            os.killpg = real_killpg
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
            _write_executable(
                leader, f"#!{sys.executable}\nimport time\ntime.sleep(30)\n"
            )
            process_runner = runner.E2ERunner(repo_root=tmp, mtest=leader)
            arming_cases: tuple[dict[str, Any], ...] = (
                {},
                {"ready_files": (os.fspath(tmp / "x"),), "delay": 1.0},
            )
            for kwargs in arming_cases:
                with (
                    self.subTest(arming=sorted(kwargs)),
                    self.assertRaisesRegex(
                        runner.ScenarioError, "exactly one arming input"
                    ),
                ):
                    process_runner.run_mtest_signaled(
                        [],
                        signal_number=signal.SIGINT,
                        timeout=1.0,
                        **kwargs,
                    )

    def test_a_half_armed_barrier_still_sweeps_the_live_actor(self) -> None:
        # The failure path that is supposed to clean up must not strand a
        # process: an actor that armed before the barrier expired lives in a
        # process group of its own, which killing the leader's group cannot
        # reach, and the e2e actors then sleep on undisturbed.
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

    def test_main_open_helper_compiles_as_a_testing_adapter_consumer(self) -> None:
        commands: list[list[str]] = []
        run_stderr = (
            "exec: runtime open failed (operation 5, errno 5)\n"
            "cleanup operation 6 failed with errno 1\n"
            "exec: runtime close failed (operation 6, errno 5)\n"
            "main-open-probe: restore-attempts-before-atexit=3 "
            "initial-reopen=0 repair=-2 final-reopen=0 reclose=0\n"
        )

        def capture(
            command: list[str], *, timeout: float
        ) -> subprocess.CompletedProcess[str]:
            del timeout
            commands.append(command)
            if len(commands) == 3:
                return subprocess.CompletedProcess(command, 3, "", run_stderr)
            return subprocess.CompletedProcess(command, 0, "", "")

        with (
            mock.patch.object(main_open, "TEST_ADAPTER", Path(__file__)),
            mock.patch(
                "scripts.e2e.main_open.native_abi_check.compiler",
                return_value="clang",
            ),
            mock.patch.object(main_open, "_run", side_effect=capture),
        ):
            main_open.check_main_open_failure()

        helper_compile = commands[0]
        self.assertEqual(helper_compile.count("-DMTEST_EXEC_TESTING=1"), 1)
        self.assertNotIn("-DMTEST_EXEC_TESTING=0", helper_compile)
        main_compile = commands[1]
        self.assertEqual(
            main_compile[:4],
            ["mojo", "build", "--Werror", "--no-optimization"],
        )
        self.assertEqual(main_compile.count("--Werror"), 1)
        self.assertEqual(main_compile.count("--no-optimization"), 1)

    def test_main_open_timeout_preserves_diagnosis_for_darwin_eperm(self) -> None:
        """A zombie-only Darwin group must not mask the timeout diagnosis."""
        command = ["mojo", "build", "src/main.mojo"]
        process = mock.Mock()
        process.pid = 123
        process.returncode = -int(signal.SIGTERM)
        process.communicate.side_effect = [
            subprocess.TimeoutExpired(command, 1.0),
            ("captured stdout\n", "captured stderr\n"),
        ]

        with (
            mock.patch(
                "scripts.e2e.main_open.subprocess.Popen",
                return_value=process,
            ),
            mock.patch(
                "scripts.e2e.main_open.os.killpg",
                side_effect=PermissionError(1, "Operation not permitted"),
            ) as killpg,
            mock.patch("scripts.e2e.main_open.time.sleep") as sleep,
            self.assertRaises(main_open.MainOpenCheckError) as raised,
        ):
            main_open._run(command, timeout=1.0)

        self.assertIn("command timed out after 1s", str(raised.exception))
        self.assertIn("captured stdout", str(raised.exception))
        self.assertIn("captured stderr", str(raised.exception))
        killpg.assert_called_once_with(123, signal.SIGTERM)
        sleep.assert_not_called()
        self.assertEqual(process.communicate.call_count, 2)

    def test_main_open_timeout_bounds_incomplete_output_drain(self) -> None:
        """A detached pipe holder cannot defeat the command's hard timeout."""
        command = ["mojo", "build", "src/main.mojo"]
        initial_timeout = subprocess.TimeoutExpired(command, 1.0)
        drain_timeout = subprocess.TimeoutExpired(command, 1.0)
        process = mock.Mock()
        process.pid = 123
        process.stdout = mock.Mock()
        process.stderr = mock.Mock()
        process.communicate.side_effect = [initial_timeout, drain_timeout]
        process.wait.return_value = -int(signal.SIGTERM)

        with (
            mock.patch(
                "scripts.e2e.main_open.subprocess.Popen",
                return_value=process,
            ),
            mock.patch(
                "scripts.e2e.main_open.os.killpg",
                side_effect=PermissionError(1, "Operation not permitted"),
            ),
            mock.patch("scripts.e2e.main_open.time.sleep"),
            self.assertRaises(main_open.MainOpenCheckError) as raised,
        ):
            main_open._run(command, timeout=1.0)

        self.assertIs(raised.exception.__cause__, initial_timeout)
        self.assertIn("command timed out after 1s", str(raised.exception))
        self.assertIn("output drain remained incomplete", str(raised.exception))
        self.assertEqual(
            process.communicate.call_args_list,
            [
                mock.call(timeout=1.0),
                mock.call(timeout=main_open.POST_TIMEOUT_DRAIN_SECONDS),
            ],
        )
        process.stdout.close.assert_called_once_with()
        process.stderr.close.assert_called_once_with()
        process.wait.assert_called_once_with(
            timeout=main_open.POST_TIMEOUT_DRAIN_SECONDS
        )

    def test_scenarios_receive_an_explicit_immutable_context(self) -> None:
        registry = tuple(e2e_main.SCENARIOS)
        context = runner.ScenarioContext(manifest={}, registry=registry)

        self.assertIs(context.registry, registry)
        with self.assertRaises(FrozenInstanceError):
            # The frozen dataclass is the property under test, so the assignment
            # mypy rejects is exactly what this asserts fails at runtime.
            context.registry = ()  # type: ignore[misc]
        for name, scenario in registry:
            with self.subTest(scenario=name):
                self.assertEqual(
                    tuple(inspect.signature(scenario).parameters),
                    ("context",),
                )

    def test_harness_passes_the_context_and_contains_later_scenarios(self) -> None:
        registry = ()
        context = runner.ScenarioContext(manifest={"sentinel": 42}, registry=registry)
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


class ScenarioTotalIsRegistryDerivedTests(unittest.TestCase):
    """The gate's headline number must be counted, never remembered.

    `=== <passed>/<total> scenarios passed ===` is the line a reader treats as
    the E2E result. If the total were a constant, it would keep reading as
    proof after the registry moved underneath it, so these tests drive `main`
    with a substituted registry and read the banner back.
    """

    # "91 scenarios", "1,053 classified tests", "72 end-to-end scenarios": a
    # bare integer in front of a countable noun, with room for the adjectives
    # such claims usually carry.
    _COUNT_CLAIM = re.compile(
        r"\b\d[\d,_]*\s+(?:[A-Za-z-]+\s+){0,2}"
        r"(?:scenarios?|tests?|suites?|checks?|cases?|files?|modules?)\b",
        re.IGNORECASE,
    )

    @staticmethod
    def _passing(detail: str) -> runner.Scenario:
        def scenario(_context: runner.ScenarioContext) -> str:
            return detail

        return scenario

    def _banner(self, registry: runner.ScenarioRegistry) -> str:
        buffer = io.StringIO()
        with (
            mock.patch.object(e2e_main, "SCENARIOS", registry),
            mock.patch.object(os.path, "exists", return_value=True),
            mock.patch.object(e2e_main, "load_manifest", return_value={}),
            contextlib.redirect_stdout(buffer),
        ):
            code = e2e_main.main()
        self.assertEqual(code, 0, buffer.getvalue())
        return buffer.getvalue()

    def test_the_banner_total_counts_the_registry_it_was_given(self) -> None:
        for size in (1, 3, 7):
            with self.subTest(size=size):
                registry = tuple(
                    (f"s{index}", self._passing("")) for index in range(size)
                )

                self.assertIn(
                    f"=== {size}/{size} scenarios passed ===", self._banner(registry)
                )

    def test_the_banner_total_is_not_the_committed_registry_length(self) -> None:
        # Guards the shape where a "derived" total is really `len(SCENARIOS)`
        # read from module scope while a different registry is executed.
        banner = self._banner((("only-one", self._passing("")),))

        self.assertNotIn(f"/{len(e2e_main.SCENARIOS)} scenarios passed", banner)

    def test_a_failing_scenario_is_excluded_from_the_passed_count(self) -> None:
        def failing(_context: runner.ScenarioContext) -> str:
            raise runner.ScenarioError("deliberate")

        buffer = io.StringIO()
        registry = (("ok", self._passing("")), ("bad", failing))
        with (
            mock.patch.object(e2e_main, "SCENARIOS", registry),
            mock.patch.object(os.path, "exists", return_value=True),
            mock.patch.object(e2e_main, "load_manifest", return_value={}),
            contextlib.redirect_stdout(buffer),
        ):
            code = e2e_main.main()

        self.assertEqual(code, 1)
        self.assertIn("=== 1/2 scenarios passed ===", buffer.getvalue())

    def test_no_e2e_docstring_hard_codes_a_count(self) -> None:
        harness_root = Path(runner.REPO_ROOT) / "scripts" / "e2e"
        sources = sorted(harness_root.rglob("*.py"))
        self.assertTrue(sources)

        offenders: list[str] = []
        for source in sources:
            tree = ast.parse(source.read_text(encoding="utf-8"))
            for node in ast.walk(tree):
                if not isinstance(
                    node,
                    (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef),
                ):
                    continue
                text = ast.get_docstring(node, clean=False)
                if text is None:
                    continue
                owner = getattr(node, "name", "<module>")
                offenders.extend(
                    f"{source.relative_to(runner.REPO_ROOT)}:{owner}: "
                    f"{match.group(0)!r}"
                    for match in self._COUNT_CLAIM.finditer(text)
                )

        self.assertEqual(
            offenders,
            [],
            "an E2E docstring states a total that nothing recomputes; describe "
            "the registry instead of counting it",
        )


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

    def _child_soft_limit(self, preexec: Callable[[], None] | None) -> int:
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
                (
                    "import resource, sys;"
                    "sys.stdout.write(str(resource.getrlimit(resource.RLIMIT_NOFILE)))"
                ),
            ],
            capture_output=True,
            text=True,
            check=True,
            preexec_fn=runner.limit_nofile(target),
        )
        self.assertEqual(completed.stdout.strip(), str((target, hard)))


if __name__ == "__main__":
    unittest.main()
