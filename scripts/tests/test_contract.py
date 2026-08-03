#!/usr/bin/env python3
"""Focused tests for the release-contract oracle (`scripts/qa/contract.py`).

`contract-check-strict` is a blocking release-floor Pixi task (part of
`pixi run ci` and both hosted platform matrices); `contract-check` remains
the non-strict, rebuild-if-stale entry point for local iteration.
"""

from __future__ import annotations

import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
from typing import TYPE_CHECKING, TypedDict, Unpack, cast, override
import unittest
from unittest import mock

from scripts.qa import contract


if TYPE_CHECKING:
    from collections.abc import Callable


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

    `ensure_binary` takes the binary path and its input paths explicitly, so
    these tests drive the real fail-closed logic against a disposable temp tree
    without invoking `pixi` or `mojo`.
    """

    @override
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="mtest-contract-binary-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.binary = self.root / "build" / "mtest"
        self.binary.parent.mkdir(parents=True)
        self.src = self.root / "src"
        self.src.mkdir()
        self.input_paths = [self.src]
        self.build_calls: list[dict[str, str]] = []

    def _fake_build(self, env: dict[str, str]) -> subprocess.CompletedProcess[bytes]:
        self.build_calls.append(env)
        self.binary.write_text("built")
        return subprocess.CompletedProcess(args=["fake-build"], returncode=0)

    def test_missing_binary_with_no_rebuild_dies_closed(self) -> None:
        with self.assertRaises(SystemExit) as ctx:
            contract.ensure_binary(
                self.binary,
                self.input_paths,
                {},
                rebuild=False,
                allow_rebuild=False,
                build=self._fake_build,
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
                self.binary,
                self.input_paths,
                {},
                rebuild=False,
                allow_rebuild=False,
                build=self._fake_build,
            )
        self.assertEqual(ctx.exception.code, 2)
        self.assertEqual(self.build_calls, [])

    def test_stale_file_input_with_no_rebuild_dies_closed(self) -> None:
        # `_newest_mtime`'s `elif p.is_file():` limb is what makes a FILE
        # input count toward staleness, and five of the seven documented
        # BINARY_INPUT_PATHS entries are files. Every OTHER case in this class
        # passes only a directory, so a regression that mistypes that limb
        # would stay green while `--no-rebuild` validated a binary older than
        # a touched `pixi.lock`.
        self.binary.write_text("old")
        stale_time = time.time() - 100
        os.utime(self.binary, (stale_time, stale_time))
        pixi_lock = self.root / "pixi.lock"
        pixi_lock.write_text("locked")  # newer than the backdated binary

        with self.assertRaises(SystemExit) as ctx:
            contract.ensure_binary(
                self.binary,
                [self.src, pixi_lock],
                {},
                rebuild=False,
                allow_rebuild=False,
                build=self._fake_build,
            )
        self.assertEqual(ctx.exception.code, 2)
        self.assertEqual(self.build_calls, [])

    def test_fresh_binary_with_no_rebuild_returns_without_building(self) -> None:
        (self.src / "main.mojo").write_text("code")
        self.binary.write_text("built")  # written after the source -> fresh

        contract.ensure_binary(
            self.binary,
            self.input_paths,
            {},
            rebuild=False,
            allow_rebuild=False,
            build=self._fake_build,
        )
        self.assertEqual(self.build_calls, [])

    def test_missing_binary_with_rebuild_allowed_builds_once(self) -> None:
        contract.ensure_binary(
            self.binary,
            self.input_paths,
            {},
            rebuild=False,
            allow_rebuild=True,
            build=self._fake_build,
        )
        self.assertEqual(len(self.build_calls), 1)
        self.assertTrue(self.binary.is_file())

    def test_failed_build_dies_closed(self) -> None:
        def failing_build(env: dict[str, str]) -> subprocess.CompletedProcess[bytes]:
            self.build_calls.append(env)
            return subprocess.CompletedProcess(args=["fake-build"], returncode=1)

        with self.assertRaises(SystemExit) as ctx:
            contract.ensure_binary(
                self.binary,
                self.input_paths,
                {},
                rebuild=False,
                allow_rebuild=True,
                build=failing_build,
            )
        self.assertEqual(ctx.exception.code, 2)
        self.assertEqual(len(self.build_calls), 1)

    def test_binary_input_paths_cover_the_documented_provenance_set(self) -> None:
        # The mtime scan is a fail-closed HEURISTIC; the content-identity proof
        # is the Pixi `contract-check-strict -> build-bin` task edge. The scan
        # must still cover every documented input.
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
    """Negative controls for the SIGINT probe's bounded barrier.

    The bounded readiness/absence barrier replaced fixed `time.sleep` calls.
    These drive the polling primitive directly, with no subprocess and no real
    mtest binary.
    """

    def test_child_never_became_ready_returns_false_within_bound(self) -> None:
        calls: list[int] = []

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

        ok = contract.wait_until(
            ready_after_two_polls, deadline=time.time() + 5, poll_interval=0.01
        )

        self.assertTrue(ok)
        self.assertEqual(calls["n"], 2)


class ExactProcessIdentificationTests(unittest.TestCase):
    """`exact_process_pid` must identify the compiled TEST BINARY.

    A running `mojo build` mentions the same mangled name as its `-o` argument.
    The old `pgrep -f irq_stest_` matched both, so readiness could flip True
    while mtest was still compiling and SIGINT arrived before any hang child
    existed. These spawn two REAL processes standing in for that ambiguity: a
    decoy carrying the mangled name only as an argument, and a "binary" whose
    argv[0] IS the mangled name.
    """

    MANGLED = "tch_probe_uexactuid"  # a throwaway name, not the real HANG_MANGLED_NAME

    @override
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="mtest-exact-pid-")
        self.addCleanup(self.tmp.cleanup)
        self.procs: list[subprocess.Popen[bytes]] = []
        self.addCleanup(self._killall)

    def _killall(self) -> None:
        for p in self.procs:
            # Cleanup must never mask an assertion that already failed.
            with contextlib.suppress(Exception):
                p.kill()
                p.wait(timeout=5)

    def _spawn(self, argv: list[str]) -> subprocess.Popen[bytes]:
        p = subprocess.Popen(argv)
        self.procs.append(p)
        return p

    def test_exact_process_pid_ignores_a_compiler_mentioning_the_same_name(
        self,
    ) -> None:
        # The decoy stands in for `mojo build ... -o build/bin/<mangled>`:
        # its command line CONTAINS the mangled name, but argv[0] is the
        # compiler driver. That is the UNCACHED build's shape and every
        # retry rebuild's; a first cached build stages elsewhere, which
        # narrows the ambiguity without removing it.
        decoy = self._spawn(
            [
                "python3",
                "-c",
                "import time; time.sleep(300)",
                "-o",
                f"build/bin/{self.MANGLED}",
            ]
        )
        # The "binary" stands in for the exec'd test binary: a real ELF
        # executable, since the kernel rewrites a `#!`-script's argv[0] to the
        # interpreter. Here argv[0] IS its own path, ending in the mangled name.
        fake_bin = Path(self.tmp.name) / self.MANGLED
        shutil.copy2("/bin/sleep", fake_bin)
        fake_bin.chmod(0o755)
        real = self._spawn([str(fake_bin), "300"])

        try:
            pid = contract.wait_until(
                lambda: contract.exact_process_pid(self.MANGLED) is not None,
                deadline=time.time() + 10,
                poll_interval=0.05,
            )
            self.assertTrue(pid, "the real binary was never identified")
            # The cast only tells the type checker what `wait_until` above and
            # the assertion below already establish.
            found = cast("str", contract.exact_process_pid(self.MANGLED))
            self.assertIsNotNone(found)
            self.assertEqual(int(found), real.pid)
            self.assertNotEqual(int(found), decoy.pid)
            # The decoy DOES show up in the raw pgrep scan, so the ambiguity
            # `exact_process_pid` resolves is real.
            raw = contract.matching_pids(self.MANGLED)
            self.assertIn(str(decoy.pid), raw)
            self.assertIn(str(real.pid), raw)
        finally:
            self._killall()

    def test_is_own_binary_accepts_both_output_shapes_and_nothing_else(
        self,
    ) -> None:
        # mtest builds a file's binary to one of two places and the SIGINT
        # probe must recognize either. A published generation's directory name
        # carries a run-dependent digest, so what is asserted is the store
        # prefix, the mangled name, and the `_h` separator that no mangled
        # name can itself contain.
        store = contract.CACHE_STORE_PREFIX
        digest = "0123456789abcdef0123456789abcdef"
        gen = f"{store}{self.MANGLED}_h{digest}/bin"
        plain = f"build/bin/{self.MANGLED}"
        self.assertTrue(contract.is_own_binary(plain, self.MANGLED))
        self.assertTrue(contract.is_own_binary(gen, self.MANGLED))
        # Another file's generation, sharing only the store prefix.
        other = f"{store}some_uother_ufile_h{digest}/bin"
        self.assertFalse(contract.is_own_binary(other, self.MANGLED))
        # A cache-shaped path outside the store must not be adopted.
        stray = f"/elsewhere/{self.MANGLED}_h{digest}/bin"
        self.assertFalse(contract.is_own_binary(stray, self.MANGLED))
        # And the compiler itself, whatever it was asked to write.
        self.assertFalse(contract.is_own_binary("/usr/bin/mojo", self.MANGLED))

    def test_is_own_binary_accepts_the_unpublished_staging_shape(self) -> None:
        # The sequential driver builds AND runs from the staging directory,
        # publishing only after the run is classified, so the child whose PID
        # the SIGINT probe needs is executing
        # `<store>/.tmp-<mangled>-<pid>-<clock>-<attempt>/bin` with no
        # generation yet. Missing this shape leaves `pgrep -f <mangled>` empty,
        # burns the readiness deadline, and fails the interrupt contract.
        store = contract.CACHE_STORE_PREFIX
        staging = f"{store}{contract.CACHE_STAGING_PREFIX}{self.MANGLED}-1234-99-0/bin"
        self.assertTrue(contract.is_own_binary(staging, self.MANGLED))
        # The two published shapes must keep working alongside the staging one.
        digest = "0123456789abcdef0123456789abcdef"
        self.assertTrue(
            contract.is_own_binary(f"build/bin/{self.MANGLED}", self.MANGLED)
        )
        self.assertTrue(
            contract.is_own_binary(f"{store}{self.MANGLED}_h{digest}/bin", self.MANGLED)
        )
        # Another file staging concurrently, sharing only the store prefix and
        # the `.tmp-` marker. `--shard` makes two live staging directories over
        # one checkout ordinary.
        self.assertFalse(
            contract.is_own_binary(
                f"{store}{contract.CACHE_STAGING_PREFIX}some_uother_ufile-1234-99-0/bin",
                self.MANGLED,
            )
        )
        # A file whose mangled name merely EXTENDS this one past a `-`. The
        # match anchors on the trailing pid/clock/attempt fields, which a
        # prefix test would not: `a` would pass against `a-1`'s directory.
        self.assertFalse(
            contract.is_own_binary(
                f"{store}{contract.CACHE_STAGING_PREFIX}{self.MANGLED}-x-1234-99-0/bin",
                self.MANGLED,
            )
        )
        # A staging-shaped path outside the store must not be adopted.
        self.assertFalse(
            contract.is_own_binary(
                f"/elsewhere/{contract.CACHE_STAGING_PREFIX}{self.MANGLED}-1234-99-0/bin",
                self.MANGLED,
            )
        )
        # And a compiler naming ANY of the three as its `-o` output is still
        # the compiler: argv[0] decides, never the rest of the command line.
        for compiler in ("/usr/bin/mojo", "mojo", "/opt/pixi/envs/default/bin/mojo"):
            self.assertFalse(contract.is_own_binary(compiler, self.MANGLED))

    def test_process_state_reports_sleeping_for_the_identified_binary(self) -> None:
        fake_bin = Path(self.tmp.name) / self.MANGLED
        shutil.copy2("/bin/sleep", fake_bin)
        fake_bin.chmod(0o755)
        real = self._spawn([str(fake_bin), "300"])

        ready = contract.wait_until(
            lambda: contract.exact_process_pid(self.MANGLED) is not None,
            deadline=time.time() + 10,
            poll_interval=0.05,
        )
        self.assertTrue(ready)
        # The cast restates the barrier above; it adds no runtime behavior.
        pid = cast("str", contract.exact_process_pid(self.MANGLED))
        self.assertEqual(int(pid), real.pid)
        state = contract.wait_until(
            lambda: contract.process_state(pid) == "S",
            deadline=time.time() + 10,
            poll_interval=0.05,
        )
        self.assertTrue(state, f"pid {pid} never reported state S")


class FakeSupervisor:
    """A `subprocess.Popen`-shaped test double for `run_interrupt_probe`."""

    def __init__(self, exit_code: int = 2, out: str = "1 not run\n") -> None:
        self.pid = 999999  # never sent a REAL signal; run_interrupt_probe's
        # `send_sigint` is always overridden in these tests
        self.returncode: int | None = None
        self._exit_code = exit_code
        self._out = out
        self.killed = False
        self.communicate_calls = 0

    def poll(self) -> int | None:
        return self.returncode

    # `timeout` mirrors `Popen.communicate`'s keyword, which the probe passes
    # by name; the double has nothing to wait for, so it only records the call.
    def communicate(self, timeout: float | None = None) -> tuple[str, None]:  # noqa: ARG002
        self.communicate_calls += 1
        self.returncode = self._exit_code
        return self._out, None

    def kill(self) -> None:
        self.killed = True


class ProbeArgs(TypedDict, total=False):
    """The keyword arguments of `contract.run_interrupt_probe`, all optional.

    `total=False` lets one dict serve as both the default set and a per-test
    override set, so each test names only the knob it exercises.
    """

    spawn: Callable[[], subprocess.Popen[str]]
    hang_ready: Callable[[], bool]
    hang_present: Callable[[], bool]
    strict: bool
    outer_deadline: float
    orphan_timeout: float
    poll_interval: float
    killtree: Callable[[subprocess.Popen[str]], None] | None
    send_sigint: Callable[[int], None] | None


class InterruptProbeProductionPathTests(unittest.TestCase):
    """Negative controls that drive `run_interrupt_probe` itself.

    That is the EXACT function `Runner.check_interrupt` calls against the real
    `mtest` binary, rather than the generic `wait_until` primitive under a
    different name. Faking `spawn`, `send_sigint`, and `killtree` keeps every
    real subprocess and signal out of it.
    """

    def _run(
        self,
        *,
        proc: FakeSupervisor | None = None,
        **kwargs: Unpack[ProbeArgs],
    ) -> tuple[str, str, FakeSupervisor, list[int], list[object]]:
        proc = proc or FakeSupervisor()
        sigint_calls: list[int] = []
        killtree_calls: list[object] = []
        defaults: ProbeArgs = {
            # `FakeSupervisor` implements the three members the probe touches:
            # `poll`, `communicate`, and `kill`.
            "spawn": lambda: cast("subprocess.Popen[str]", proc),
            "hang_ready": lambda: True,
            "hang_present": lambda: False,
            "strict": False,
            "outer_deadline": time.time() + 5,
            "orphan_timeout": 0.3,
            "poll_interval": 0.02,
            "killtree": killtree_calls.append,
            "send_sigint": sigint_calls.append,
        }
        defaults.update(kwargs)
        status, detail = contract.run_interrupt_probe(**defaults)
        return status, detail, proc, sigint_calls, killtree_calls

    def test_child_never_ready_is_skip_when_not_strict(self) -> None:
        status, detail, _proc, sigint_calls, _ = self._run(
            hang_ready=lambda: False,
            strict=False,
            outer_deadline=time.time() + 0.2,
        )
        self.assertEqual(status, contract.SKIP)
        self.assertIn("child never became ready", detail)
        self.assertEqual(sigint_calls, [])  # never signaled: never ready

    def test_child_never_ready_is_fail_when_strict(self) -> None:
        status, detail, _proc, sigint_calls, _ = self._run(
            hang_ready=lambda: False,
            strict=True,
            outer_deadline=time.time() + 0.2,
        )
        self.assertEqual(status, contract.FAIL)
        self.assertIn("child never became ready", detail)
        self.assertIn("--strict", detail)
        self.assertEqual(sigint_calls, [])

    def test_supervisor_already_dead_exits_before_the_outer_deadline(self) -> None:
        # Without a `proc.poll()` fast-exit, a dead supervisor burns the FULL
        # outer deadline waiting for a child it will never spawn.
        proc = FakeSupervisor()
        proc.returncode = 137  # already exited before the probe even started
        start = time.time()
        status, detail, _, sigint_calls, _ = self._run(
            proc=proc,
            hang_ready=lambda: False,
            outer_deadline=time.time() + 5,
        )
        elapsed = time.time() - start
        self.assertEqual(status, contract.SKIP)
        self.assertIn("child never became ready", detail)
        self.assertLess(elapsed, 2.0, "did not fast-exit on a dead supervisor")
        self.assertEqual(sigint_calls, [])

    def test_missing_process_inspection_is_skip_when_not_strict(self) -> None:
        def raises() -> bool:
            raise RuntimeError("pgrep unavailable: [Errno 2] no such file")

        status, detail, proc, sigint_calls, _ = self._run(
            hang_ready=raises, strict=False
        )
        self.assertEqual(status, contract.SKIP)
        self.assertIn("pgrep unavailable", detail)
        self.assertTrue(proc.killed)
        self.assertEqual(sigint_calls, [])

    def test_missing_process_inspection_is_fail_when_strict(self) -> None:
        def raises() -> bool:
            raise RuntimeError("ps unavailable: [Errno 2] no such file")

        status, detail, proc, _sigint_calls, _ = self._run(
            hang_ready=raises, strict=True
        )
        self.assertEqual(status, contract.FAIL)
        self.assertIn("ps unavailable", detail)
        self.assertIn("--strict", detail)
        self.assertTrue(proc.killed)

    def test_child_survived_cleanup_is_named_in_the_failure_detail(self) -> None:
        status, detail, proc, sigint_calls, killtree_calls = self._run(
            hang_ready=lambda: True,
            hang_present=lambda: True,  # never leaves
        )
        self.assertEqual(status, contract.FAIL)
        self.assertIn("orphaned_child=True", detail)
        self.assertIn("; child survived cleanup", detail)
        self.assertEqual(sigint_calls, [proc.pid])  # SIGINT only after readiness
        self.assertEqual(killtree_calls, [proc])

    def test_clean_pass_when_child_gone_and_supervisor_reports_not_run(self) -> None:
        status, detail, proc, sigint_calls, _ = self._run(
            hang_ready=lambda: True,
            hang_present=lambda: False,
        )
        self.assertEqual(status, contract.PASS)
        self.assertEqual(detail, "")
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(sigint_calls, [proc.pid])


class CheckRosterTests(unittest.TestCase):
    """The roster, and the pin that `main` actually consults it.

    Without the call-site pin these body tests stay green while `main` reports
    a verdict for a run that skipped half its checks.
    """

    def test_roster_covers_the_matrix_and_every_bespoke_check(self) -> None:
        roster = list(contract.EXPECTED_CHECK_NAMES)

        self.assertEqual(len(roster), len(set(roster)), "duplicate check name")
        matrix = [c.name for c in contract.build_matrix()]
        self.assertEqual(roster[: len(matrix)], matrix)
        self.assertEqual(
            roster[len(matrix) :],
            [
                "collect: exact node-id set for tests/",
                "determinism: collect byte-identical",
                "collect: --format json agrees with the lines listing and the exit",
                "determinism: --shuffle --seed repeats its file order",
                "help: --help -> stdout, exit 0",
                "usage error: -V -> stderr, exit 4",
                "collect: streams split, listing continues past a bad probe",
                "color: --color always beats NO_COLOR",
                "precompile: success path resolves import (auto -I)",
                "symlink: a symlinked test file is collected and run, never dropped",
                "shape: a test-named non-file walk entry is announced, never dropped",
                "shape: an unsupported operand is refused with its real problem",
                "value: 2^63 refused for every non-negative integer flag",
                "report: --json to a readerless FIFO fails fast, never blocks",
                "path: a long-but-legal path builds, never a false COMPILE-ERROR",
                "flaky: --fail-on-flaky turns a FLAKY-only run's 0 into 1",
                "debug: the handoff is the test's own exit, with no mtest verdict",
                "interrupt: SIGINT frees the owned process group",
            ],
        )

    def test_complete_unfiltered_run_is_accepted(self) -> None:
        contract.verify_every_check_ran(contract.EXPECTED_CHECK_NAMES, filtered=False)

    def test_one_missing_check_is_refused(self) -> None:
        without_interrupt = tuple(
            n for n in contract.EXPECTED_CHECK_NAMES if not n.startswith("interrupt:")
        )
        with self.assertRaises(contract.ContractRosterError) as caught:
            contract.verify_every_check_ran(without_interrupt, filtered=False)
        self.assertIn("interrupt: SIGINT", str(caught.exception))

    def test_unrostered_check_is_refused_even_when_filtered(self) -> None:
        with self.assertRaises(contract.ContractRosterError):
            contract.verify_every_check_ran(("invented: check",), filtered=True)

    def test_filtered_subset_must_keep_roster_order_and_run_once(self) -> None:
        subset = contract.EXPECTED_CHECK_NAMES[2:5]
        contract.verify_every_check_ran(subset, filtered=True)
        with self.assertRaises(contract.ContractRosterError):
            contract.verify_every_check_ran(tuple(reversed(subset)), filtered=True)
        with self.assertRaises(contract.ContractRosterError):
            contract.verify_every_check_ran(subset + subset[:1], filtered=True)

    def _main_over_a_fake_runner(
        self, argv: list[str], drop: str = ""
    ) -> tuple[int, str, str]:
        """Run `main` with every check replaced by a recording double.

        Args:
            argv: The command line to parse, without the program name.
            drop: A check name whose double records nothing, standing in for
                a deleted call site.

        Returns:
            The exit code and the captured stdout/stderr.
        """
        recorded: list[str] = []

        class FakeRunner:
            def __init__(self, *_args: object, **_kwargs: object) -> None:
                self.results: list[tuple[str, str, str, str]] = []

            def record(
                self, status: str, name: str, ref: str, detail: str = ""
            ) -> None:
                self.results.append((status, name, ref, detail))

            def _perform(self, name: str) -> None:
                recorded.append(name)
                if name != drop:
                    self.results.append((contract.PASS, name, "ref", ""))

            def check(self, c: contract.Check) -> None:
                self._perform(c.name)

            def check_collect_exact(self) -> None:
                self._perform("collect: exact node-id set for tests/")

            def check_determinism(self) -> None:
                self._perform("determinism: collect byte-identical")

            def check_collect_json(self) -> None:
                self._perform(
                    "collect: --format json agrees with the lines listing and the exit"
                )

            def check_shuffle_determinism(self) -> None:
                self._perform("determinism: --shuffle --seed repeats its file order")

            def check_help_stream(self) -> None:
                self._perform("help: --help -> stdout, exit 0")
                self._perform("usage error: -V -> stderr, exit 4")

            def check_collect_streams(self) -> None:
                self._perform(
                    "collect: streams split, listing continues past a bad probe"
                )

            def check_color(self) -> None:
                self._perform("color: --color always beats NO_COLOR")

            def check_precompile_success(self) -> None:
                self._perform("precompile: success path resolves import (auto -I)")

            def check_symlinked_test_file(self) -> None:
                self._perform(
                    "symlink: a symlinked test file is collected and run, never dropped"
                )

            def check_nonregular_walk_entry(self) -> None:
                self._perform(
                    "shape: a test-named non-file walk entry is announced, "
                    "never dropped"
                )

            def check_unsupported_operand(self) -> None:
                self._perform(
                    "shape: an unsupported operand is refused with its real problem"
                )

            def check_integer_overflow_values(self) -> None:
                self._perform("value: 2^63 refused for every non-negative integer flag")

            def check_json_fifo_does_not_block(self) -> None:
                self._perform(
                    "report: --json to a readerless FIFO fails fast, never blocks"
                )

            def check_long_path_builds(self) -> None:
                self._perform(
                    "path: a long-but-legal path builds, never a false COMPILE-ERROR"
                )

            def check_fail_on_flaky(self) -> None:
                self._perform(
                    "flaky: --fail-on-flaky turns a FLAKY-only run's 0 into 1"
                )

            def check_debug_handoff(self) -> None:
                self._perform(
                    "debug: the handoff is the test's own exit, with no mtest verdict"
                )

            def check_interrupt(self, _strict: bool) -> None:
                self._perform("interrupt: SIGINT frees the owned process group")

        ok = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        out, err = io.StringIO(), io.StringIO()
        with (
            mock.patch.multiple(
                contract,
                Runner=FakeRunner,
                pixi_env=mock.Mock(return_value={}),
                ensure_binary=mock.Mock(),
                scaffold=mock.Mock(),
            ),
            # `contract` imports `subprocess`, so this patches the identical
            # module object the checker calls through.
            mock.patch.object(subprocess, "run", return_value=ok),
            mock.patch.object(sys, "argv", ["contract.py", *argv]),
            contextlib.redirect_stdout(out),
            contextlib.redirect_stderr(err),
        ):
            code = contract.main()
        self.performed = recorded
        return code, out.getvalue(), err.getvalue()

    def test_main_performs_every_rostered_check_in_order(self) -> None:
        code, out, err = self._main_over_a_fake_runner([])
        self.assertEqual(code, 0, err)
        self.assertEqual(tuple(self.performed), contract.EXPECTED_CHECK_NAMES)
        self.assertIn("0 failed, 0 skipped", out)

    def test_main_refuses_a_verdict_when_a_call_site_recorded_nothing(self) -> None:
        code, _out, err = self._main_over_a_fake_runner(
            [], drop="interrupt: SIGINT frees the owned process group"
        )
        self.assertEqual(code, 2)
        self.assertIn("did not perform every check it reports", err)

    def test_no_interrupt_records_a_skip_instead_of_bypassing(self) -> None:
        code, out, err = self._main_over_a_fake_runner(["--no-interrupt"])
        self.assertEqual(code, 0, err)
        self.assertNotIn(
            "interrupt: SIGINT frees the owned process group", self.performed
        )
        self.assertIn("1 skipped", out)

    def test_strict_fails_on_a_skip_including_no_interrupt(self) -> None:
        code, out, _err = self._main_over_a_fake_runner(["--strict", "--no-interrupt"])
        self.assertEqual(code, 1)
        self.assertIn("1 skipped", out)


if __name__ == "__main__":
    unittest.main()
