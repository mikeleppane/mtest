#!/usr/bin/env python3
"""Mutation proofs for the self-hosted completeness oracle.

`scripts/harness/selfhost.py` exists because mtest running its own suite cannot
be trusted to report what it ran: a module that collects zero tests is a PASS by
design, and a file cap conflated with the exec concurrency ceiling would report
64 green files of 101 and exit 0. Both shapes produce a well-formed report and
exit 0, so the only thing that separates them from a real green run is an
independent source-derived count.

A guard nobody has watched fail is not a guard. Every test below points the
oracle at a *fake* mtest through the real watchdog and the real reconciliation,
and proves the oracle goes red:

- `SelfhostOmittedFileTests` -- 100 files reported of 101 that exist.
- `SelfhostOmittedTestsTests` -- every file reported PASS, total short by a
  module's worth of tests. This is the zero-collection shape.
- `SelfhostFalseSuccessTests` -- exit 0 with correct counts and a path set that
  differs by one name.
- `SelfhostHangTests` -- a child that ignores SIGTERM and never exits, with a
  descendant in its process group. Proves the deadline fires, the whole group
  is swept, and the harness reports a timeout instead of blocking forever.
"""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import time
import unittest

from scripts.harness import selfhost, watchdog


FAKE_SOURCE = '''\
"""A fake mtest that prints one canned report and exits."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

SPEC = json.loads(Path(sys.argv[0] + ".spec.json").read_text(encoding="utf-8"))

if SPEC["hang"]:
    # Ignore the polite signal on purpose. Only a process-group SIGKILL can end
    # this, which is exactly the property the watchdog must demonstrate.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    child = subprocess.Popen(
        [
            sys.executable,
            "-c",
            "import signal, time\\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\\n"
            "while True: time.sleep(3600)\\n",
        ]
    )
    Path(SPEC["pid_file"]).write_text(
        f"{os.getpid()}\\n{child.pid}\\n", encoding="utf-8"
    )
    while True:
        time.sleep(3600)

print("mtest 0.0.0-fake (mojo)")
print(
    "root: %s   selected: %d files   excluded: %d   workers: 4"
    % (os.getcwd(), SPEC["selected"], SPEC["excluded_files"])
)
print()
for path in SPEC["pass_rows"]:
    print("PASS           %s  0.01s" % path)
print()
print(
    "===== %d passed, %d failed, %d skipped (%d excluded, %d not run) in 0.1s ====="
    % (
        SPEC["passed"],
        SPEC["failed"],
        SPEC["skipped"],
        SPEC["excluded_tests"],
        SPEC["not_run"],
    )
)
sys.stdout.flush()
sys.exit(SPEC["exit_code"])
'''


def write_suite(repo_root: Path, files: int, tests_per_file: int) -> list[str]:
    """Write a fake classified tree and return its repository-relative paths.

    Args:
        repo_root: The temporary repository root to write under.
        files: How many `tests/unit/test_*.mojo` files to create.
        tests_per_file: How many top-level `def test_*` declarations each holds.

    Returns:
        The repository-relative paths written, in sorted order.
    """
    unit = repo_root / "tests" / "unit"
    unit.mkdir(parents=True, exist_ok=True)
    written: list[str] = []
    for index in range(files):
        path = unit / f"test_probe{index:03d}.mojo"
        body = "".join(
            f"def test_probe{index:03d}_case{case}():\n    pass\n\n\n"
            for case in range(tests_per_file)
        )
        path.write_text(f"{body}def main():\n    pass\n", encoding="utf-8")
        written.append(str(path.relative_to(repo_root)))
    return sorted(written)


def write_fake_mtest(directory: Path, spec: dict[str, object]) -> str:
    """Write an executable fake mtest driven by one canned report spec.

    Args:
        directory: Where to place the fake and its spec file.
        spec: The report the fake prints and the status it exits with.

    Returns:
        The absolute path of the executable fake.
    """
    script = directory / "fake_mtest"
    script.write_text(f"#!{sys.executable}\n{FAKE_SOURCE}", encoding="utf-8")
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    (directory / "fake_mtest.spec.json").write_text(
        json.dumps({"hang": False, "pid_file": "", **spec}), encoding="utf-8"
    )
    return str(script)


def run_oracle(
    repo_root: Path,
    mtest_path: str,
    *,
    roots: tuple[str, ...] = ("tests/unit",),
    environment: dict[str, str] | None = None,
) -> tuple[int, str, str]:
    """Run the oracle against a fake mtest and capture everything it printed.

    Args:
        repo_root: The temporary repository root to run in.
        mtest_path: The fake mtest binary to point the oracle at.
        roots: Requested suite roots.
        environment: Environment the oracle reads its deadline override from.

    Returns:
        The oracle's exit code, its stdout, and its stderr.
    """
    out = StringIO()
    err = StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = selfhost.verify(
            roots,
            repo_root=repo_root,
            mtest_path=mtest_path,
            native_object=str(repo_root / "build" / "native" / "fake.o"),
            environment={} if environment is None else environment,
        )
    return code, out.getvalue(), err.getvalue()


class IndependentParserTests(unittest.TestCase):
    def test_reads_top_level_test_declarations_in_order(self) -> None:
        source = (
            "from testing import assert_true\n"
            "def test_alpha():\n    pass\n"
            "def test_beta(x: Int):\n    pass\n"
            "def helper():\n    pass\n"
            "    def test_nested():\n        pass\n"
            "def test_():\n    pass\n"
        )

        names = selfhost.independent_test_function_names(source, "tests/unit/x.mojo")

        self.assertEqual(names, ("test_alpha", "test_beta"))

    def test_a_file_that_collects_nothing_is_named_and_rejected(self) -> None:
        source = "struct Suite:\n    fn test_alpha(self):\n        pass\n"

        with self.assertRaisesRegex(AssertionError, r"tests/unit/moved\.mojo"):
            selfhost.independent_test_function_names(source, "tests/unit/moved.mojo")

    def test_a_duplicate_declaration_is_rejected(self) -> None:
        source = "def test_alpha():\n    pass\ndef test_alpha():\n    pass\n"

        with self.assertRaisesRegex(AssertionError, "duplicate"):
            selfhost.independent_test_function_names(source, "tests/unit/dupe.mojo")


class DerivedInventoryTests(unittest.TestCase):
    def test_a_new_file_needs_no_ledger_edit(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            write_suite(repo, files=3, tests_per_file=4)
            roots = [Path("tests/unit")]

            before = selfhost.derive_inventory(repo, roots)
            write_suite(repo, files=4, tests_per_file=4)
            after = selfhost.derive_inventory(repo, roots)

        self.assertEqual((len(before.paths), before.total_tests), (3, 12))
        self.assertEqual((len(after.paths), after.total_tests), (4, 16))

    def test_a_new_test_function_needs_no_ledger_edit(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            write_suite(repo, files=2, tests_per_file=3)
            roots = [Path("tests/unit")]

            before = selfhost.derive_inventory(repo, roots)
            target = repo / "tests/unit/test_probe000.mojo"
            target.write_text(
                target.read_text(encoding="utf-8") + "\ndef test_extra():\n    pass\n",
                encoding="utf-8",
            )
            after = selfhost.derive_inventory(repo, roots)

        self.assertEqual(before.total_tests, 6)
        self.assertEqual(after.total_tests, 7)

    def test_a_single_file_root_is_an_inventory_of_one(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            write_suite(repo, files=3, tests_per_file=5)

            roots = selfhost.normalized_roots(repo, ["tests/unit/test_probe001.mojo"])
            inventory = selfhost.derive_inventory(repo, roots)

        self.assertEqual(inventory.paths, ("tests/unit/test_probe001.mojo",))
        self.assertEqual(inventory.total_tests, 5)

    def test_a_root_outside_tests_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            (repo / "src").mkdir()

            with self.assertRaisesRegex(ValueError, "must be tests/ or below"):
                selfhost.normalized_roots(repo, ["src"])


class CommandTests(unittest.TestCase):
    def test_command_carries_include_paths_and_the_linked_native_object(self) -> None:
        command = selfhost.mtest_argv(
            "/tmp/mtest", "/tmp/native.o", [Path("tests/unit")], "auto"
        )

        self.assertEqual(
            command,
            [
                "/tmp/mtest",
                "-I",
                "build",
                "-I",
                "tests/support",
                "--build-arg=--no-optimization",
                "--build-arg=-Xlinker",
                "--build-arg=/tmp/native.o",
                "-n",
                "auto",
                "tests/unit",
            ],
        )


class TimeoutPolicyTests(unittest.TestCase):
    def test_the_default_ceiling_clears_the_slowest_measured_run(self) -> None:
        # The full self-hosted run measured ~629s on four cores.
        self.assertGreater(selfhost.timeout_seconds({}), 629.0)

    def test_the_override_lowers_the_ceiling(self) -> None:
        seconds = selfhost.timeout_seconds({selfhost.TIMEOUT_ENV: "30"})

        self.assertEqual(seconds, 30.0)

    def test_an_override_above_the_watchdog_ceiling_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "must be finite and between"):
            selfhost.timeout_seconds({selfhost.TIMEOUT_ENV: "100000"})


class SelfhostAgreementTests(unittest.TestCase):
    def test_a_faithful_report_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            paths = write_suite(repo, files=5, tests_per_file=3)
            fake = write_fake_mtest(
                repo,
                {
                    "selected": 5,
                    "excluded_files": 0,
                    "pass_rows": paths,
                    "passed": 15,
                    "failed": 0,
                    "skipped": 0,
                    "excluded_tests": 0,
                    "not_run": 0,
                    "exit_code": 0,
                },
            )

            code, out, err = run_oracle(repo, fake)

        self.assertEqual(code, 0, msg=f"stdout={out!r} stderr={err!r}")
        self.assertIn("selfhost: OK", out)


class SelfhostOmittedFileTests(unittest.TestCase):
    """Mutation 1: mtest reports one file fewer than exists on disk."""

    def test_a_report_that_omits_a_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            paths = write_suite(repo, files=101, tests_per_file=3)
            fake = write_fake_mtest(
                repo,
                {
                    "selected": 100,
                    "excluded_files": 0,
                    "pass_rows": paths[:100],
                    "passed": 300,
                    "failed": 0,
                    "skipped": 0,
                    "excluded_tests": 0,
                    "not_run": 0,
                    "exit_code": 0,
                },
            )

            code, _out, err = run_oracle(repo, fake)

        self.assertEqual(code, 1)
        self.assertIn("selected file count mismatch", err)
        self.assertIn("mtest selected 100 file(s), the sources declare 101", err)
        self.assertIn("exact path membership mismatch", err)
        self.assertIn(paths[100], err)

    def test_a_report_truncated_at_the_exec_slot_ceiling_is_rejected(self) -> None:
        # The 64-of-101 shape: the exec supervision cap is 64 in both layers,
        # and a defect conflating it with a total-file cap looks like this.
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            paths = write_suite(repo, files=101, tests_per_file=3)
            fake = write_fake_mtest(
                repo,
                {
                    "selected": 64,
                    "excluded_files": 0,
                    "pass_rows": paths[:64],
                    "passed": 192,
                    "failed": 0,
                    "skipped": 0,
                    "excluded_tests": 0,
                    "not_run": 0,
                    "exit_code": 0,
                },
            )

            code, _out, err = run_oracle(repo, fake)

        self.assertEqual(code, 1)
        self.assertIn("mtest selected 64 file(s), the sources declare 101", err)
        self.assertIn("mtest reported 192 passed, the sources declare 303", err)


class SelfhostOmittedTestsTests(unittest.TestCase):
    """Mutation 2: correct file membership, a module that collected nothing."""

    def test_a_report_short_by_one_modules_tests_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            paths = write_suite(repo, files=101, tests_per_file=3)
            fake = write_fake_mtest(
                repo,
                {
                    "selected": 101,
                    "excluded_files": 0,
                    "pass_rows": paths,
                    # One module built, ran, collected zero tests, and passed.
                    "passed": 300,
                    "failed": 0,
                    "skipped": 0,
                    "excluded_tests": 0,
                    "not_run": 0,
                    "exit_code": 0,
                },
            )

            code, _out, err = run_oracle(repo, fake)

        self.assertEqual(code, 1)
        self.assertIn("exact test-total mismatch", err)
        self.assertIn("mtest reported 300 passed, the sources declare 303", err)
        self.assertIn("a module that collected nothing looks exactly like this", err)
        self.assertNotIn("exact path membership mismatch", err)


class SelfhostFalseSuccessTests(unittest.TestCase):
    """Mutation 3: exit 0, well-formed, correct counts, wrong path set."""

    def test_a_plausible_report_naming_a_file_that_does_not_exist_is_rejected(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            paths = write_suite(repo, files=101, tests_per_file=3)
            rows = [*paths[:-1], "tests/unit/test_ghost.mojo"]
            fake = write_fake_mtest(
                repo,
                {
                    "selected": 101,
                    "excluded_files": 0,
                    "pass_rows": rows,
                    "passed": 303,
                    "failed": 0,
                    "skipped": 0,
                    "excluded_tests": 0,
                    "not_run": 0,
                    "exit_code": 0,
                },
            )

            code, _out, err = run_oracle(repo, fake)

        self.assertEqual(code, 1)
        self.assertIn("exact path membership mismatch", err)
        self.assertIn("tests/unit/test_ghost.mojo", err)
        self.assertIn(paths[-1], err)
        self.assertNotIn("exact test-total mismatch", err)
        self.assertNotIn("selected file count mismatch", err)


def _process_alive(pid: int) -> bool:
    """Report whether one pid still names a live process.

    Args:
        pid: The process id recorded by the hung fake or its descendant.

    Returns:
        True while the process still exists, allowing a brief settle window for
        the group sweep and the orphan's reparenting reap.
    """
    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        time.sleep(0.05)
    return True


class SelfhostHangTests(unittest.TestCase):
    """Mutation 4: a run that never exits, under the process-group deadline."""

    def test_a_hung_run_is_killed_by_group_and_reported_as_a_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            write_suite(repo, files=3, tests_per_file=2)
            pid_file = repo / "hung.pids"
            fake = write_fake_mtest(
                repo,
                {
                    "hang": True,
                    "pid_file": str(pid_file),
                    "selected": 0,
                    "excluded_files": 0,
                    "pass_rows": [],
                    "passed": 0,
                    "failed": 0,
                    "skipped": 0,
                    "excluded_tests": 0,
                    "not_run": 0,
                    "exit_code": 0,
                },
            )

            started = time.monotonic()
            code, _out, err = run_oracle(
                repo, fake, environment={selfhost.TIMEOUT_ENV: "3"}
            )
            elapsed = time.monotonic() - started
            recorded = pid_file.read_text(encoding="utf-8").split()

        self.assertEqual(code, watchdog.TIMEOUT_EXIT_CODE)
        self.assertIn("exceeded 3s", err)
        self.assertIn("process group was terminated", err)
        # It ended on the deadline, not on its own and not never: the fake
        # sleeps in an unbounded loop and ignores SIGTERM.
        self.assertGreaterEqual(elapsed, 3.0)
        self.assertLess(elapsed, 120.0)
        self.assertEqual(len(recorded), 2)
        for raw_pid in recorded:
            self.assertFalse(
                _process_alive(int(raw_pid)),
                msg=f"pid {raw_pid} survived the process-group sweep",
            )


if __name__ == "__main__":
    unittest.main()
