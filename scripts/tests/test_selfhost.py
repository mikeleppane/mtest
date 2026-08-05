#!/usr/bin/env python3
"""Mutation proofs for the self-hosted completeness oracle.

`scripts/harness/selfhost.py` exists because mtest running its own suite cannot
be trusted to report what it ran: a module that collects zero tests is a PASS by
design, and a file cap conflated with the exec concurrency ceiling would report
64 green files of 101 and exit 0. Both shapes produce a well-formed report and
exit 0, so the only thing that separates them from a real green run is an
independent source-derived count.

Every test below points the oracle at a fake mtest through the real watchdog
and the real reconciliation, and proves the oracle goes red:

- `SelfhostOmittedFileTests`: 100 files reported of 101 that exist.
- `SelfhostOmittedTestsTests`: every file reported PASS, one module collecting
  zero tests (the D1 zero-collection shape).
- `SelfhostFalseSuccessTests`: exit 0 with correct counts and a path set that
  differs by one name.
- `SelfhostHangTests`: a child that ignores SIGTERM and never exits, with a
  descendant in its process group. The deadline fires, the whole group is
  swept, and the harness reports a timeout.
- `SelfhostDistributionTests`: the right grand total behind the wrong per-file
  distribution, in both its shapes, which is what reconciling per file and per
  test NAME buys over a total.
"""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

from scripts.harness import selfhost, watchdog


FAKE_SOURCE = '''\
"""A fake mtest that prints one canned report and writes one canned stream."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

SPEC = json.loads(Path(sys.argv[0] + ".spec.json").read_text(encoding="utf-8"))
JSON_PATH = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else ""

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

if JSON_PATH:
    # Mirror mtest's real v1 stream: header, session_started, one test_reported
    # per named test, one file_finished per reported file carrying its OWN
    # counts, then the single session_finished terminal.
    lines = [{"event": "stream", "version": 1, "generator": "mtest 0.0.0-fake"}]
    lines.append(
        {
            "event": "session_started",
            "root": os.getcwd(),
            "toolchain": "mojo",
            "selected_count": SPEC["selected"],
            "excluded_count": SPEC["excluded_files"],
            "workers": 4,
        }
    )
    for entry in SPEC["files"]:
        for name in entry["names"]:
            lines.append(
                {
                    "event": "test_reported",
                    "path": entry["path"],
                    "name": name,
                    "outcome": "pass",
                }
            )
        lines.append(
            {
                "event": "file_finished",
                "path": entry["path"],
                "outcome": "pass",
                "parse_disposition": "parsed",
                "passed_tests": entry["passed_tests"],
                "failed_tests": 0,
                "skipped_tests": 0,
                "deselected_tests": 0,
                "attempts_used": 1,
                "flaky": False,
                "exit_status": 0,
                "signal_number": 0,
            }
        )
    lines.append(
        {
            "event": "session_finished",
            "summary": {
                "pass": len(SPEC["files"]),
                "fail": 0,
                "skip": 0,
                "crash": 0,
                "timeout": 0,
                "compile_error": 0,
                "compile_timeout": 0,
                "malformed_suite": 0,
                "precompile_error": 0,
                "flaky": 0,
                "deselected": 0,
                "excluded": SPEC["excluded_tests"],
                "not_run": SPEC["not_run"],
            },
            "wall_time_us": 100000,
            "exit_code": SPEC["exit_code"],
            "test_counts": {
                "passed": SPEC["passed"],
                "failed": SPEC["failed"],
                "skipped": SPEC["skipped"],
                "deselected": 0,
            },
            "flaky_files": 0,
        }
    )
    Path(JSON_PATH).write_text(
        "".join(json.dumps(line) + "\\n" for line in lines), encoding="utf-8"
    )

if SPEC["barrier_dir"]:
    # Announce that this run's stream is on disk, then wait for every peer's.
    # That forces the interleaving the per-invocation paths exist to survive:
    # every concurrent stream coexists before any harness reads one. Under a
    # shared fixed path the last writer would win and at least one harness
    # would reconcile a run that was not its own.
    barrier = Path(SPEC["barrier_dir"])
    barrier.mkdir(parents=True, exist_ok=True)
    (barrier / (SPEC["tag"] + ".ready")).write_text("ready", encoding="utf-8")
    deadline = time.monotonic() + 60.0
    while time.monotonic() < deadline:
        if len(list(barrier.glob("*.ready"))) >= SPEC["peers"]:
            break
        time.sleep(0.02)

print("mtest 0.0.0-fake (mojo)")
print(
    "root: %s   selected: %d files   excluded: %d   workers: 4"
    % (os.getcwd(), SPEC["selected"], SPEC["excluded_files"])
)
print()
for entry in SPEC["files"]:
    print("PASS           %s  0.01s" % entry["path"])
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


def write_suite(
    repo_root: Path, files: int, tests_per_file: int
) -> dict[str, list[str]]:
    """Write a fake classified tree and return what it declares.

    Args:
        repo_root: The temporary repository root to write under.
        files: How many `tests/unit/test_*.mojo` files to create.
        tests_per_file: How many top-level `def test_*` declarations each holds.

    Returns:
        Repository-relative path to the test function names it declares, in
        sorted path order. Built from what this function wrote, never by
        re-parsing it, so a fixture cannot inherit the oracle's own reading.
    """
    unit = repo_root / "tests" / "unit"
    unit.mkdir(parents=True, exist_ok=True)
    declared: dict[str, list[str]] = {}
    for index in range(files):
        path = unit / f"test_probe{index:03d}.mojo"
        names = [f"test_probe{index:03d}_case{case}" for case in range(tests_per_file)]
        body = "".join(f"def {name}():\n    pass\n\n\n" for name in names)
        path.write_text(f"{body}def main():\n    pass\n", encoding="utf-8")
        declared[str(path.relative_to(repo_root))] = names
    return dict(sorted(declared.items()))


def faithful_spec(declared: dict[str, list[str]]) -> dict[str, object]:
    """Build the report a correct mtest would produce for one written suite.

    Args:
        declared: The suite as `write_suite` returned it.

    Returns:
        A spec for `write_fake_mtest` that agrees with the sources completely.
        Every mutation proof starts from this and breaks exactly one thing.
    """
    return {
        "selected": len(declared),
        "excluded_files": 0,
        "files": [
            {"path": path, "names": list(names), "passed_tests": len(names)}
            for path, names in declared.items()
        ],
        "passed": sum(len(names) for names in declared.values()),
        "failed": 0,
        "skipped": 0,
        "excluded_tests": 0,
        "not_run": 0,
        "exit_code": 0,
    }


def write_fake_mtest(
    directory: Path, spec: dict[str, object], name: str = "fake_mtest"
) -> str:
    """Write an executable fake mtest driven by one canned report spec.

    Args:
        directory: Where to place the fake and its spec file.
        spec: The report the fake prints, the stream it writes, and the status
            it exits with.
        name: The fake's filename, so one directory can hold several.

    Returns:
        The absolute path of the executable fake.
    """
    script = directory / name
    script.write_text(f"#!{sys.executable}\n{FAKE_SOURCE}", encoding="utf-8")
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    (directory / f"{name}.spec.json").write_text(
        json.dumps(
            {
                "hang": False,
                "pid_file": "",
                "barrier_dir": "",
                "tag": name,
                "peers": 1,
                **spec,
            }
        ),
        encoding="utf-8",
    )
    return str(script)


def _faithful_stream_records(
    repo_root: Path, declared: dict[str, list[str]]
) -> list[dict[str, object]]:
    """Build a complete, correct v1 event stream for one written suite.

    Args:
        repo_root: The repository root the run would report.
        declared: The suite as `write_suite` returned it.

    Returns:
        Records that would reconcile cleanly, used to prove that a stream at the
        stable evidence path is not read even when it would have passed.
    """
    records: list[dict[str, object]] = [
        {"event": "stream", "version": 1, "generator": "mtest 0.0.0-fake"},
        {
            "event": "session_started",
            "root": str(repo_root),
            "selected_count": len(declared),
            "excluded_count": 0,
        },
    ]
    for path, names in declared.items():
        records.extend(
            {"event": "test_reported", "path": path, "name": name, "outcome": "pass"}
            for name in names
        )
        records.append(
            {
                "event": "file_finished",
                "path": path,
                "outcome": "pass",
                "parse_disposition": "parsed",
                "passed_tests": len(names),
                "failed_tests": 0,
                "skipped_tests": 0,
                "deselected_tests": 0,
                "attempts_used": 1,
                "flaky": False,
                "exit_status": 0,
                "signal_number": 0,
            }
        )
    records.append(
        {
            "event": "session_finished",
            "summary": {"pass": len(declared), "excluded": 0, "not_run": 0},
            "exit_code": 0,
            "test_counts": {
                "passed": sum(len(names) for names in declared.values()),
                "failed": 0,
                "skipped": 0,
                "deselected": 0,
            },
        }
    )
    return records


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


FILE_ROW_TOKENS = (
    "PASS",
    "FAIL",
    "CRASH",
    "TIMEOUT",
    "COMPILE-ERROR",
    "COMPILE-TIMEOUT",
    "MALFORMED-SUITE",
    "PRECOMPILE-ERROR",
    "FLAKY",
    "NO-TESTS",
)
"""Every file-row token `_verdict_token` in `console.mojo` can print.

Written out rather than imported, so it can disagree with the regex it checks.
`scripts/tests/test_vocabulary.py` reconciles it against
`scripts/formats/vocabulary.txt` and against the copy in
`scripts/tests/test_package_consumption.py`.
"""


class VerdictRowTokenCoverageTests(unittest.TestCase):
    """`VERDICT_ROW_RE` must see every token a real console row can carry."""

    def test_verdict_row_re_sees_every_file_row_token(self) -> None:
        for token in FILE_ROW_TOKENS:
            line = f"{token} tests/unit/test_example.mojo"
            with self.subTest(token=token):
                match = selfhost.VERDICT_ROW_RE.search(line)
                if match is None:
                    raise AssertionError(f"VERDICT_ROW_RE is blind to {token}")
                self.assertEqual(match.group("verdict"), token)

    def test_verdict_row_re_rejects_a_token_outside_the_real_vocabulary(self) -> None:
        # The catch-all `[A-Z][A-Z-]{2,}` this test replaces would happily match
        # nonsense here; the tightened alternation must not.
        line = "NONSENSE-TOKEN tests/unit/test_example.mojo"

        match = selfhost.VERDICT_ROW_RE.search(line)

        if match is not None:
            raise AssertionError(
                f"VERDICT_ROW_RE matched a token outside the real vocabulary: {match}"
            )


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

    def test_the_inventory_records_each_files_own_test_names(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            declared = write_suite(repo, files=2, tests_per_file=2)

            inventory = selfhost.derive_inventory(repo, [Path("tests/unit")])

        self.assertEqual(
            {path: list(names) for path, names in inventory.tests_by_path.items()},
            declared,
        )

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
    def test_command_carries_include_paths_native_object_and_the_stream(self) -> None:
        command = selfhost.mtest_argv(
            "/tmp/mtest", "/tmp/native.o", [Path("tests/unit")], "auto", "/tmp/s.ndjson"
        )

        self.assertEqual(
            command,
            [
                "/tmp/mtest",
                "-I",
                "build",
                "-I",
                "tests/support",
                "--build-arg=--Werror",
                "--build-arg=--no-optimization",
                "--build-arg=-Xlinker",
                "--build-arg=/tmp/native.o",
                "-n",
                "auto",
                "--json",
                "/tmp/s.ndjson",
                "tests/unit",
            ],
        )


class RequestParsingTests(unittest.TestCase):
    """The worker override must reach mtest, and a typo must never mean `auto`.

    mtest reads a non-positive `-n` as `auto`, so an unvalidated value silently
    replaces the measured count the pixi tasks run under with cores/2. These
    prove the parse rejects it rather than forwarding it.
    """

    def test_roots_alone_carry_the_pinned_default(self) -> None:
        request = selfhost.parse_request(["tests/unit", "tests/integration"])

        self.assertEqual(request.workers, selfhost.DEFAULT_WORKERS)
        self.assertEqual(request.roots, ("tests/unit", "tests/integration"))

    def test_both_flag_spellings_override_the_default(self) -> None:
        for argv in (
            ["-n", "8", "tests/unit"],
            ["-n=8", "tests/unit"],
            ["--workers", "8", "tests/unit"],
            ["--workers=8", "tests/unit"],
            ["tests/unit", "-n", "8"],
        ):
            with self.subTest(argv=argv):
                request = selfhost.parse_request(argv)

                self.assertEqual(request.workers, "8")
                self.assertEqual(request.roots, ("tests/unit",))

    def test_a_nonpositive_or_misspelled_count_is_rejected(self) -> None:
        for value in ("0", "-1", "atuo", "", "4.0", "1e3"):
            with (
                self.subTest(value=value),
                self.assertRaisesRegex(
                    ValueError, "must be 'auto' or a positive integer"
                ),
            ):
                selfhost.parse_request([f"-n={value}", "tests/unit"])

    def test_a_flag_without_a_value_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "needs a worker count"):
            selfhost.parse_request(["tests/unit", "-n"])

    def test_a_repeated_count_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "given more than once"):
            selfhost.parse_request(["-n", "4", "-n", "8"])


class TimeoutPolicyTests(unittest.TestCase):
    def test_the_default_ceiling_clears_the_slowest_measured_run_twice_over(
        self,
    ) -> None:
        # Pinned to four cores with both Mojo caches cleared, the full run was
        # still going at 600s with 13 of 101 files outstanding. A ceiling that
        # merely clears the slow case is not enough: a false rc=124 on a
        # merely-slow host reads exactly like the hang this lane looks for.
        slowest_measured_seconds = 600.0

        self.assertGreaterEqual(
            selfhost.timeout_seconds({}), 2 * slowest_measured_seconds
        )
        # ...and the watchdog must actually accept the default this lane asks
        # for. Before the default/maximum split it would have refused it.
        self.assertLessEqual(selfhost.timeout_seconds({}), watchdog.MAX_TIMEOUT_SECONDS)

    def test_the_override_lowers_the_ceiling(self) -> None:
        seconds = selfhost.timeout_seconds({selfhost.TIMEOUT_ENV: "30"})

        self.assertEqual(seconds, 30.0)

    def test_an_override_above_the_watchdog_ceiling_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "must be finite and between"):
            selfhost.timeout_seconds(
                {selfhost.TIMEOUT_ENV: str(watchdog.MAX_TIMEOUT_SECONDS + 1)}
            )


class SelfhostAgreementTests(unittest.TestCase):
    def test_a_faithful_report_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            declared = write_suite(repo, files=5, tests_per_file=3)
            fake = write_fake_mtest(repo, faithful_spec(declared))

            code, out, err = run_oracle(repo, fake)

        self.assertEqual(code, 0, msg=f"stdout={out!r} stderr={err!r}")
        self.assertIn("selfhost: OK", out)

    def test_a_run_that_wrote_no_stream_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            declared = write_suite(repo, files=3, tests_per_file=2)
            spec = faithful_spec(declared)
            fake = write_fake_mtest(repo, spec)
            # A faithful-looking stream at the stable evidence path must never
            # stand in for this run's. That path is written for humans and is
            # never read back; reconciliation only ever touches the
            # per-invocation stream, which this run does not produce.
            stale = repo / selfhost.LATEST_JSON_STREAM
            stale.parent.mkdir(parents=True, exist_ok=True)
            stale.write_text(
                "".join(
                    json.dumps(record) + "\n"
                    for record in _faithful_stream_records(repo, declared)
                ),
                encoding="utf-8",
            )

            with mock.patch.object(
                selfhost, "mtest_argv", return_value=[fake, "--no-json-please"]
            ):
                code, _out, err = run_oracle(repo, fake)

        self.assertEqual(code, 1)
        self.assertIn("wrote no machine event stream", err)


DRIVER_SOURCE = '''\
"""Drive one `selfhost.verify` against a temporary repository, in its own process."""

from pathlib import Path
import sys

from scripts.harness import selfhost

sys.exit(
    selfhost.verify(
        ("tests/unit",),
        repo_root=Path(sys.argv[1]),
        mtest_path=sys.argv[2],
        native_object=sys.argv[3],
        environment={},
    )
)
'''


class ConcurrentInvocationTests(unittest.TestCase):
    """Two invocations on one checkout must never read each other's stream.

    Four pixi tasks (`test`, `test-unit`, `test-integration`, `test-file`) point
    at this harness, so two runs sharing a checkout is ordinary. With a fixed
    stream path, run A can recreate the file between run B's pre-spawn unlink
    and B's read, and B's per-file and per-test-name verdict would then describe
    someone else's run.
    """

    def test_artifact_paths_are_unique_per_invocation(self) -> None:
        repo = Path("/repo")

        first = selfhost.run_artifacts(repo)
        second = selfhost.run_artifacts(repo)

        self.assertNotEqual(first.stream, second.stream)
        self.assertNotEqual(first.sentinel, second.sentinel)
        for artifact in (first.stream, first.sentinel):
            self.assertEqual(artifact.parent, repo / selfhost.ARTIFACT_DIR)

    def test_two_concurrent_runs_keep_their_own_verdicts(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            declared = write_suite(repo, files=6, tests_per_file=3)
            barrier = repo / "barrier"

            good = faithful_spec(declared)
            good.update({"barrier_dir": str(barrier), "tag": "good", "peers": 2})
            bad = faithful_spec(declared)
            # Same grand total, wrong per-file distribution: caught ONLY by the
            # per-file stream check, which is exactly the check a shared stream
            # path would corrupt.
            files: list[dict[str, object]] = bad["files"]  # type: ignore[assignment]
            files[1]["passed_tests"] = 5
            files[4]["passed_tests"] = 1
            bad.update({"barrier_dir": str(barrier), "tag": "bad", "peers": 2})

            good_path = write_fake_mtest(repo, good, "fake_good")
            bad_path = write_fake_mtest(repo, bad, "fake_bad")
            driver = repo / "driver.py"
            driver.write_text(DRIVER_SOURCE, encoding="utf-8")

            environment = dict(os.environ)
            environment["PYTHONPATH"] = str(Path(selfhost.__file__).parents[2])
            processes = [
                subprocess.Popen(
                    [
                        sys.executable,
                        str(driver),
                        str(repo),
                        fake,
                        str(repo / "build" / "native" / "fake.o"),
                    ],
                    cwd=repo,
                    env=environment,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                for fake in (good_path, bad_path)
            ]
            results = [process.communicate(timeout=180) for process in processes]
            codes = [process.returncode for process in processes]

        # The faithful run passes and the corrupted run fails, every time. Under
        # a shared stream path the last writer would win and both harnesses
        # would reconcile one stream, flipping one of these verdicts.
        self.assertEqual(codes[0], 0, msg=f"faithful run failed: {results[0][1]!r}")
        self.assertEqual(codes[1], 1, msg=f"corrupted run passed: {results[1][1]!r}")
        self.assertIn("passed_tests=5 but the source declares 3", results[1][1])
        self.assertNotIn("passed_tests=", results[0][1])


class SelfhostOmittedFileTests(unittest.TestCase):
    """Mutation 1: mtest reports one file fewer than exists on disk."""

    def test_a_report_that_omits_a_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            declared = write_suite(repo, files=101, tests_per_file=3)
            spec = faithful_spec(declared)
            spec["selected"] = 100
            spec["files"] = spec["files"][:100]  # type: ignore[index]
            spec["passed"] = 300
            fake = write_fake_mtest(repo, spec)

            code, _out, err = run_oracle(repo, fake)

        self.assertEqual(code, 1)
        self.assertIn("[json] file_finished membership mismatch", err)
        self.assertIn("[console] selected file count mismatch", err)
        self.assertIn("mtest selected 100 file(s), the sources declare 101", err)
        self.assertIn("[console] exact path membership mismatch", err)
        self.assertIn("tests/unit/test_probe100.mojo", err)

    def test_a_report_truncated_at_the_exec_slot_ceiling_is_rejected(self) -> None:
        # The 64-of-101 shape: the exec supervision cap is 64 in both layers,
        # and a defect conflating it with a total-file cap looks like this.
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            declared = write_suite(repo, files=101, tests_per_file=3)
            spec = faithful_spec(declared)
            spec["selected"] = 64
            spec["files"] = spec["files"][:64]  # type: ignore[index]
            spec["passed"] = 192
            fake = write_fake_mtest(repo, spec)

            code, _out, err = run_oracle(repo, fake)

        self.assertEqual(code, 1)
        self.assertIn("mtest selected 64 file(s), the sources declare 101", err)
        self.assertIn("mtest reported 192 passed, the sources declare 303", err)


class SelfhostOmittedTestsTests(unittest.TestCase):
    """Mutation 2: correct file membership, a module that collected nothing."""

    def test_a_module_that_collected_nothing_is_named_and_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            declared = write_suite(repo, files=101, tests_per_file=3)
            spec = faithful_spec(declared)
            # One module built, ran, collected zero tests, and passed anyway.
            entries: list[dict[str, object]] = spec["files"]  # type: ignore[assignment]
            entries[7]["names"] = []
            entries[7]["passed_tests"] = 0
            spec["passed"] = 300
            fake = write_fake_mtest(repo, spec)

            code, _out, err = run_oracle(repo, fake)

        self.assertEqual(code, 1)
        # The stream names the FILE, not just an unexplained shortfall.
        self.assertIn(
            "[json] tests/unit/test_probe007.mojo: passed_tests=0 but the source "
            "declares 3 test function(s)",
            err,
        )
        self.assertIn("declared but never reported: ['test_probe007_case0'", err)
        self.assertIn("[console] exact test-total mismatch", err)
        self.assertNotIn("membership mismatch", err)


class SelfhostFalseSuccessTests(unittest.TestCase):
    """Mutation 3: exit 0, well-formed, correct counts, wrong path set."""

    def test_a_plausible_report_naming_a_file_that_does_not_exist_is_rejected(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            declared = write_suite(repo, files=101, tests_per_file=3)
            spec = faithful_spec(declared)
            entries: list[dict[str, object]] = spec["files"]  # type: ignore[assignment]
            entries[-1]["path"] = "tests/unit/test_ghost.mojo"
            fake = write_fake_mtest(repo, spec)

            code, _out, err = run_oracle(repo, fake)

        self.assertEqual(code, 1)
        self.assertIn("[json] file_finished membership mismatch", err)
        self.assertIn("[console] exact path membership mismatch", err)
        self.assertIn("tests/unit/test_ghost.mojo", err)
        self.assertIn("tests/unit/test_probe100.mojo", err)
        self.assertNotIn("[console] exact test-total mismatch", err)
        self.assertNotIn("[console] selected file count mismatch", err)


class SelfhostDistributionTests(unittest.TestCase):
    """Mutation 5: the right grand total behind the wrong distribution.

    Both shapes satisfy every total the console report states (the selected
    count, the PASS row set, `303 passed`), which is why per-file and per-name
    reconciliation exists.
    """

    def test_a_correct_total_over_a_wrong_per_file_count_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            declared = write_suite(repo, files=101, tests_per_file=3)
            spec = faithful_spec(declared)
            entries: list[dict[str, object]] = spec["files"]  # type: ignore[assignment]
            # File A ran two extra, file B ran two fewer. 303 either way.
            entries[3]["passed_tests"] = 5
            entries[9]["passed_tests"] = 1
            fake = write_fake_mtest(repo, spec)

            code, _out, err = run_oracle(repo, fake)

        self.assertEqual(code, 1)
        self.assertIn(
            "[json] tests/unit/test_probe003.mojo: passed_tests=5 but the source "
            "declares 3 test function(s)",
            err,
        )
        self.assertIn(
            "[json] tests/unit/test_probe009.mojo: passed_tests=1 but the source "
            "declares 3 test function(s)",
            err,
        )
        # Every console-level check is satisfied. Only the per-file view sees it.
        self.assertNotIn("[console]", err)

    def test_a_correct_count_over_permuted_test_names_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            repo = Path(raw_tmp).resolve()
            declared = write_suite(repo, files=101, tests_per_file=3)
            spec = faithful_spec(declared)
            entries: list[dict[str, object]] = spec["files"]  # type: ignore[assignment]
            # Swap one test between two files. Every count in the run is right:
            # per-file passed_tests, the grand total, the file set, the exit
            # code. Only the reported NAMES are wrong.
            first: list[str] = entries[3]["names"]  # type: ignore[assignment]
            second: list[str] = entries[9]["names"]  # type: ignore[assignment]
            first[0], second[0] = second[0], first[0]
            fake = write_fake_mtest(repo, spec)

            code, _out, err = run_oracle(repo, fake)

        self.assertEqual(code, 1)
        self.assertIn(
            "[json] tests/unit/test_probe003.mojo: reported test names differ", err
        )
        self.assertIn(
            "[json] tests/unit/test_probe009.mojo: reported test names differ", err
        )
        self.assertIn("declared but never reported: ['test_probe003_case0']", err)
        self.assertIn("reported but not declared: ['test_probe009_case0']", err)
        # No count anywhere in the run disagrees. Names are the only witness.
        self.assertNotIn("passed_tests=", err)
        self.assertNotIn("[console]", err)


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
            declared = write_suite(repo, files=3, tests_per_file=2)
            pid_file = repo / "hung.pids"
            spec = faithful_spec(declared)
            spec["hang"] = True
            spec["pid_file"] = str(pid_file)
            fake = write_fake_mtest(repo, spec)

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
