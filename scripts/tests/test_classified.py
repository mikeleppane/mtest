#!/usr/bin/env python3
"""Behavioral tests for the contributor-facing classified harness."""

from __future__ import annotations

from collections.abc import Sequence
from contextlib import redirect_stderr
from io import StringIO
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time

from scripts.harness import aggregate
from scripts.harness import classified
from scripts.harness import watchdog


REPO_ROOT = Path(__file__).resolve().parents[2]


def test_repository_root_tracks_the_nested_runner() -> None:
    """The contributor runner anchors paths at the repository, not scripts/."""
    if classified.REPO_ROOT != REPO_ROOT:
        raise AssertionError(
            f"classified root is {classified.REPO_ROOT}, expected {REPO_ROOT}"
        )


def _write_executable(path: Path, source: str) -> None:
    path.write_text(source, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def test_recursive_direct_runner() -> None:
    """The direct runner registers supplied roots in one aggregate binary."""
    tests_dir = REPO_ROOT / "tests"
    with tempfile.TemporaryDirectory(
        prefix="_harness_check_", dir=tests_dir
    ) as raw_tmp:
        tmp = Path(raw_tmp)
        root_a = tmp / "first"
        root_b = tmp / "second"
        root_a.mkdir()
        root_b.mkdir()
        source_a = root_a / "test_same_name.mojo"
        source_b = root_b / "test_same_name.mojo"
        source_a.write_text("def test_fixture_a():\n    pass\n", encoding="utf-8")
        source_b.write_text("def test_fixture_b():\n    pass\n", encoding="utf-8")

        tools_dir = tmp / "tools"
        tools_dir.mkdir()
        log_path = tmp / "mojo-log.jsonl"
        run_log_path = tmp / "aggregate-run-log"
        fake_mojo = tools_dir / "mojo"
        _write_executable(
            fake_mojo,
            """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import stat
import sys

args = sys.argv[1:]
out = Path(args[args.index("-o") + 1])
out.parent.mkdir(parents=True, exist_ok=True)
if args[0] == "precompile":
    raise SystemExit(0)
if args[0] != "build":
    raise SystemExit(f"unexpected fake mojo command: {args}")
source = next(arg for arg in args if arg.endswith(".mojo"))
with open(os.environ["MTEST_FAKE_MOJO_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps({
        "source": source,
        "output": str(out),
        "generated": Path(source).read_text(encoding="utf-8"),
    }) + "\\n")
out.write_text("#!/usr/bin/env bash\\nprintf '%s\\n' RAN:aggregate\\nprintf '%s\\n' run >> \\"$MTEST_FAKE_RUN_LOG\\"\\n", encoding="utf-8")
out.chmod(out.stat().st_mode | stat.S_IXUSR)
""",
        )

        roots = [
            os.path.relpath(root_a, REPO_ROOT),
            os.path.relpath(root_b, REPO_ROOT),
        ]
        env = os.environ.copy()
        env["PATH"] = f"{tools_dir}{os.pathsep}{env['PATH']}"
        env["MTEST_FAKE_MOJO_LOG"] = str(log_path)
        env["MTEST_FAKE_RUN_LOG"] = str(run_log_path)
        result = subprocess.run(
            [sys.executable, "-m", "scripts.harness.classified", *roots],
            cwd=REPO_ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"recursive direct-runner probe exited {result.returncode}:\n"
                f"{result.stdout}"
            )

        records = [
            json.loads(line)
            for line in log_path.read_text(encoding="utf-8").splitlines()
        ]
        if len(records) != 1:
            raise AssertionError(
                "direct runner did not issue exactly one aggregate build: "
                f"{records}\n{result.stdout}"
            )
        record = records[0]
        if record["source"] != "build/tests/aggregate_main.mojo":
            raise AssertionError(
                "direct runner compiled an unexpected source: "
                f"{record['source']}"
            )
        expected_paths = [
            roots[index] + "/test_same_name.mojo" for index in range(2)
        ]
        generated = record["generated"]
        markers = [
            generated.index(f'print("==> {path}", flush=True)')
            for path in expected_paths
        ]
        if markers != sorted(markers):
            raise AssertionError("aggregate modules were not emitted bytewise-sorted")
        for index, path in enumerate(expected_paths):
            module = path.removesuffix(".mojo").replace("/", ".")
            alias = f"_mtest_module_{index}"
            if f"import {module} as {alias}" not in generated:
                raise AssertionError(f"aggregate entrypoint did not import {path}")
        if "RAN:aggregate" not in result.stdout:
            raise AssertionError("direct runner did not execute the aggregate binary")
        runs = run_log_path.read_text(encoding="utf-8").splitlines()
        if runs != ["run"]:
            raise AssertionError(
                f"direct runner did not execute the aggregate exactly once: {runs}"
            )


def test_root_modes_discover_focused_unit_integration_and_full_inventory() -> None:
    """Every contributor root mode reaches its deterministic classified inventory."""
    cases = (
        (("tests/unit/test_model_outcome.mojo",), 1, "tests/unit/"),
        (("tests/unit",), 49, "tests/unit/"),
        (("tests/integration",), 30, "tests/integration/"),
        ((), 79, "tests/"),
    )
    for arguments, expected_count, prefix in cases:
        roots = classified._normalized_roots(REPO_ROOT, arguments)
        paths = aggregate.discover_test_files(REPO_ROOT, roots)
        if len(paths) != expected_count:
            raise AssertionError(
                f"root mode {arguments!r} found {len(paths)}, expected {expected_count}"
            )
        if any(not path.as_posix().startswith(prefix) for path in paths):
            raise AssertionError(f"root mode {arguments!r} escaped {prefix}: {paths}")
        if paths != sorted(paths, key=lambda path: os.fsencode(str(path))):
            raise AssertionError(f"root mode {arguments!r} was not bytewise sorted")


def test_pipeline_builds_each_artifact_once_and_runs_aggregate_once() -> None:
    """The deep pipeline has one package/native/aggregate build and one direct run."""
    with tempfile.TemporaryDirectory(prefix="mtest-classified-pipeline-") as raw_tmp:
        repo = Path(raw_tmp)
        suite = repo / "tests" / "unit" / "test_probe.mojo"
        suite.parent.mkdir(parents=True)
        suite.write_text("def test_probe():\n    pass\n", encoding="utf-8")
        calls: list[tuple[str, str, tuple[str, ...]]] = []

        def successful_supervisor(
            command: Sequence[str], **kwargs: object
        ) -> watchdog.Termination:
            sentinel = kwargs["deadline_sentinel"]
            if not isinstance(sentinel, Path):
                raise AssertionError(f"unexpected sentinel: {sentinel!r}")
            sentinel.unlink()
            calls.append(
                (
                    str(kwargs["source"]),
                    str(kwargs["step"]),
                    tuple(command),
                )
            )
            return watchdog.Exited(0)

        result = classified.run_pipeline(
            [Path("tests/unit/test_probe.mojo")],
            repo_root=repo,
            environment={},
            supervisor=successful_supervisor,
        )

    if result.termination != watchdog.Exited(0):
        raise AssertionError(f"successful fake pipeline returned {result!r}")
    if [(source, step) for source, step, _command in calls] != [
        ("package", "build"),
        ("native adapter", "build"),
        ("aggregate suite", "build"),
        ("aggregate suite", "run"),
    ]:
        raise AssertionError(f"classified pipeline topology drifted: {calls}")
    aggregate_build = calls[2][2]
    aggregate_run = calls[3][2]
    if aggregate_build[:2] != ("mojo", "build"):
        raise AssertionError(f"aggregate was not compiled directly: {aggregate_build}")
    if aggregate_run != (str(repo / classified.AGGREGATE_BINARY),):
        raise AssertionError(f"aggregate was not executed directly: {aggregate_run}")


def test_sentinel_kind_disagreements_are_internal_errors() -> None:
    """Neither a bare timeout kind nor a lingering non-timeout sentinel is trusted."""
    with tempfile.TemporaryDirectory(prefix="mtest-classified-sentinel-") as raw_tmp:
        repo = Path(raw_tmp)

        def unproved_timeout(
            _command: Sequence[str], **kwargs: object
        ) -> watchdog.Termination:
            sentinel = kwargs["deadline_sentinel"]
            if not isinstance(sentinel, Path):
                raise AssertionError(f"unexpected sentinel: {sentinel!r}")
            sentinel.unlink()
            return watchdog.TimedOut()

        timeout_result = classified._run_step(
            ["unused"],
            repo_root=repo,
            source="aggregate suite",
            step="run",
            timeout_seconds=1.0,
            supervisor=unproved_timeout,
        )
        if not isinstance(timeout_result.termination, watchdog.HarnessError):
            raise AssertionError(f"unproved timeout was accepted: {timeout_result!r}")
        stderr = StringIO()
        with redirect_stderr(stderr):
            exit_code = classified._exit_for_result(timeout_result)
        if exit_code != classified.INTERNAL_ERROR_EXIT_CODE:
            raise AssertionError(f"sentinel disagreement exited {exit_code}")
        if "missing deadline sentinel" not in stderr.getvalue():
            raise AssertionError(
                f"sentinel disagreement lost its diagnostic: {stderr.getvalue()}"
            )

        def uncleared_exit(
            _command: Sequence[str], **_kwargs: object
        ) -> watchdog.Termination:
            return watchdog.Exited(0)

        exit_result = classified._run_step(
            ["unused"],
            repo_root=repo,
            source="aggregate suite",
            step="run",
            timeout_seconds=1.0,
            supervisor=uncleared_exit,
        )
        if not isinstance(exit_result.termination, watchdog.HarnessError):
            raise AssertionError(f"uncleared non-timeout was accepted: {exit_result!r}")


def test_caller_sigint_and_sigterm_remain_cancelled() -> None:
    """Caller signals interrupt supervision without becoming child crashes."""
    for signum in (signal.SIGINT, signal.SIGTERM):
        with tempfile.TemporaryDirectory(prefix="mtest-classified-cancel-") as raw_tmp:
            repo = Path(raw_tmp)
            timer = threading.Timer(
                0.1,
                os.kill,
                args=(os.getpid(), signum),
            )
            timer.start()
            try:
                result = classified._run_step(
                    [
                        sys.executable,
                        "-c",
                        "import signal, sys, time; "
                        f"signal.signal({signum}, lambda *_: sys.exit(0)); "
                        "time.sleep(60)",
                    ],
                    repo_root=repo,
                    source="aggregate suite",
                    step="run",
                    timeout_seconds=10.0,
                    supervisor=watchdog.run_command,
                )
            finally:
                timer.cancel()
                timer.join()
            if result.termination != watchdog.Cancelled(signum):
                raise AssertionError(
                    f"caller signal {signum} became {result.termination!r}"
                )
            sentinel = repo / classified._sentinel_for("aggregate suite", "run")
            if sentinel.exists():
                raise AssertionError(f"cancellation {signum} left its sentinel")


def test_cancelled_results_re_raise_the_caller_signal() -> None:
    """The command boundary reproduces both supported cancellation signals."""
    for signum in (signal.SIGINT, signal.SIGTERM):
        source = (
            "from scripts.harness import classified, watchdog; "
            "result = classified.StepResult('aggregate suite', 'run', "
            f"watchdog.Cancelled({signum})); "
            "raise SystemExit(classified._exit_for_result(result))"
        )
        completed = subprocess.run(
            [sys.executable, "-c", source],
            cwd=REPO_ROOT,
            check=False,
        )
        if completed.returncode != -signum:
            raise AssertionError(
                f"Cancelled({signum}) exited {completed.returncode}"
            )


def test_cancellation_outranks_a_racing_spawn_failure() -> None:
    """A signal delivered inside failing spawn remains Cancelled at the CLI."""
    sentinel = REPO_ROOT / "build" / "tests" / "package.build-deadline"
    sentinel.unlink(missing_ok=True)
    source = "\n".join(
        (
            "import os",
            "import signal",
            "from scripts.harness import classified, watchdog",
            "def cancelled_spawn(*_args, **_kwargs):",
            "    os.kill(os.getpid(), signal.SIGTERM)",
            "    raise FileNotFoundError('injected spawn failure')",
            "watchdog.subprocess.Popen = cancelled_spawn",
            "raise SystemExit(classified.main(['tests/unit/test_model_outcome.mojo']))",
        )
    )
    completed = subprocess.run(
        [sys.executable, "-c", source],
        cwd=REPO_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5.0,
        check=False,
    )
    if completed.returncode != -signal.SIGTERM:
        raise AssertionError(
            "spawn cancellation lost precedence: "
            f"status={completed.returncode}\n{completed.stderr}"
        )
    if sentinel.exists():
        raise AssertionError("spawn cancellation left the package sentinel")


def test_closed_streams_do_not_defeat_the_run_deadline() -> None:
    """EOF on both inherited streams is not mistaken for child completion."""
    with tempfile.TemporaryDirectory(prefix="mtest-classified-closed-") as raw_tmp:
        repo = Path(raw_tmp)
        result = classified._run_step(
            [
                sys.executable,
                str(REPO_ROOT / "tests/fixtures/exec/close_streams_then_hang.py"),
            ],
            repo_root=repo,
            source="aggregate suite",
            step="run",
            timeout_seconds=0.1,
            supervisor=watchdog.run_command,
        )
        if not isinstance(result.termination, watchdog.TimedOut):
            raise AssertionError(f"closed-stream hang returned {result!r}")


def test_timeout_kills_the_aggregate_process_group() -> None:
    """A deadline sweep kills a SIGTERM-ignoring aggregate grandchild."""
    with tempfile.TemporaryDirectory(prefix="mtest-classified-group-") as raw_tmp:
        repo = Path(raw_tmp)
        ready = repo / "grandchild-ready"
        survived = repo / "grandchild-survived"
        actor = repo / "actor.py"
        actor.write_text(
            "\n".join(
                (
                    "from pathlib import Path",
                    "import signal",
                    "import subprocess",
                    "import sys",
                    "import time",
                    "grandchild = (",
                    "    'from pathlib import Path; import signal, sys, time; '",
                    "    'signal.signal(signal.SIGTERM, signal.SIG_IGN); '",
                    "    'Path(sys.argv[1]).touch(); time.sleep(6); '",
                    "    'Path(sys.argv[2]).touch()'",
                    ")",
                    "subprocess.Popen([sys.executable, '-c', grandchild, sys.argv[1], sys.argv[2]])",
                    "while not Path(sys.argv[1]).exists(): time.sleep(0.01)",
                    "time.sleep(60)",
                )
            ),
            encoding="utf-8",
        )
        result = classified._run_step(
            [sys.executable, str(actor), str(ready), str(survived)],
            repo_root=repo,
            source="aggregate suite",
            step="run",
            timeout_seconds=0.2,
            supervisor=watchdog.run_command,
        )
        if not isinstance(result.termination, watchdog.TimedOut):
            raise AssertionError(f"group timeout returned {result!r}")
        if not ready.exists():
            raise AssertionError("grandchild was not ready before the timeout")
        time.sleep(1.0)
        if survived.exists():
            raise AssertionError("aggregate grandchild survived process-group cleanup")



def _run_direct_runner_failure(
    mode: str,
    step: str,
    *,
    exit_code: int = 124,
    signum: int = signal.SIGTERM,
) -> tuple[subprocess.CompletedProcess[str], list[str], bool]:
    """Run one disposable direct-suite failure at its build or run boundary."""
    if mode not in {"ordinary", "signal", "timeout", "spawn"}:
        raise AssertionError(f"unknown direct-runner failure mode: {mode}")
    if step not in {"build", "run"}:
        raise AssertionError(f"unknown direct-runner failure step: {step}")
    tests_dir = REPO_ROOT / "tests"
    with tempfile.TemporaryDirectory(
        prefix="_harness_check_", dir=tests_dir
    ) as raw_tmp:
        tmp = Path(raw_tmp)
        root = tmp / f"direct_{mode}_{step}"
        root.mkdir()
        suite = root / "test_failure.mojo"
        suite.write_text("def test_failure():\n    pass\n", encoding="utf-8")

        tools_dir = tmp / "tools"
        tools_dir.mkdir()
        log_path = tmp / "mojo-build-log"
        _write_executable(
            tools_dir / "python",
            f"#!/bin/sh\nexec {sys.executable} \"$@\"\n",
        )
        fake_mojo = tools_dir / "mojo"
        _write_executable(
            fake_mojo,
            """#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import stat
import sys
import time

args = sys.argv[1:]
mode = os.environ["MTEST_DIRECT_FAILURE_MODE"]
step = os.environ["MTEST_DIRECT_FAILURE_STEP"]
exit_code = int(os.environ["MTEST_DIRECT_FAILURE_EXIT"])
signum = int(os.environ["MTEST_DIRECT_FAILURE_SIGNAL"])
if args[0] == "precompile":
    if mode == "spawn" and step == "build":
        Path(sys.argv[0]).unlink()
    raise SystemExit(0)
if args[0] != "build":
    raise SystemExit(f"unexpected fake mojo command: {args}")
source = next(arg for arg in args if arg.endswith(".mojo"))
with open(os.environ["MTEST_FAKE_MOJO_LOG"], "a", encoding="utf-8") as log:
    log.write(source + "\\n")
if step == "build":
    if mode == "ordinary":
        raise SystemExit(exit_code)
    if mode == "signal":
        os.kill(os.getpid(), signum)
    if mode == "timeout":
        time.sleep(60)
out = Path(args[args.index("-o") + 1])
out.parent.mkdir(parents=True, exist_ok=True)
if step == "run" and mode == "ordinary":
    program = "#!/usr/bin/env bash\\nexit " + str(exit_code) + "\\n"
elif step == "run" and mode == "signal":
    program = (
        "#!/usr/bin/env python3\\n"
        "import os, signal\\n"
        "os.kill(os.getpid(), " + str(signum) + ")\\n"
    )
elif step == "run" and mode == "timeout":
    program = "#!/usr/bin/env bash\\nsleep 60\\n"
elif step == "run" and mode == "spawn":
    program = "#!/definitely-missing-mtest-interpreter\\n"
else:
    program = "#!/usr/bin/env bash\\nprintf '%s\\n' " + repr("RAN:" + source) + "\\n"
out.write_text(program, encoding="utf-8")
out.chmod(out.stat().st_mode | stat.S_IXUSR)
""",
        )
        env = os.environ.copy()
        env["PATH"] = f"{tools_dir}{os.pathsep}{env['PATH']}"
        env["MTEST_DIRECT_FAILURE_MODE"] = mode
        env["MTEST_DIRECT_FAILURE_STEP"] = step
        env["MTEST_DIRECT_FAILURE_EXIT"] = str(exit_code)
        env["MTEST_DIRECT_FAILURE_SIGNAL"] = str(signum)
        env["MTEST_FAKE_MOJO_LOG"] = str(log_path)
        if mode == "timeout":
            env["MTEST_TEST_ALL_TIMEOUT_SECONDS"] = "0.1"
        if mode == "spawn" and step == "build":
            # `precompile` removes the fake `mojo`; retain only system tools so
            # the suite build cannot fall through to Pixi's real compiler.
            cc = shutil.which("clang")
            nm = shutil.which("nm")
            if cc is None or nm is None:
                raise AssertionError("harness lacks compiler tools for spawn probe")
            env["PATH"] = f"{tools_dir}{os.pathsep}/usr/bin{os.pathsep}/bin"
            env["CC"] = cc
            env["NM"] = nm
        relative_root = os.path.relpath(root, REPO_ROOT)
        result = subprocess.run(
            [sys.executable, "-m", "scripts.harness.classified", relative_root],
            cwd=REPO_ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=15 if mode == "timeout" else 30,
            check=False,
        )
        built = (
            log_path.read_text(encoding="utf-8").splitlines()
            if log_path.exists()
            else []
        )
        deadline_sentinel = REPO_ROOT / "build" / "tests" / f"aggregate.{step}-deadline"
        return result, built, deadline_sentinel.exists()


def test_direct_runner_ordinary_exits_are_failures() -> None:
    """Ordinary aggregate exits 124, 137, and 143 stay non-timeout failures."""
    for exit_code in (124, 137, 143):
        for step in ("build", "run"):
            result, built, sentinel_exists = _run_direct_runner_failure(
                "ordinary", step, exit_code=exit_code
            )
            if result.returncode != 1:
                raise AssertionError(
                    f"ordinary exit {exit_code} did not remain a normal suite "
                    f"failure: step={step}, status={result.returncode}\n{result.stdout}"
                )
            if (
                f"FAILED: aggregate suite ({step} exit {exit_code})"
                not in result.stdout
            ):
                raise AssertionError(
                    f"ordinary exit {exit_code} lost its truthful failure "
                    f"diagnostic:\n{result.stdout}"
                )
            if f"timed-out aggregate {step}" in result.stdout or sentinel_exists:
                raise AssertionError(
                    f"ordinary exit {exit_code} was treated as a timeout:\n"
                    f"{result.stdout}"
                )
            if built != ["build/tests/aggregate_main.mojo"]:
                raise AssertionError(
                    f"ordinary {step} exit {exit_code} did not build the "
                    f"aggregate: {built}"
                )


def test_direct_runner_signal_deaths_are_re_raised() -> None:
    """Genuine aggregate child signals terminate the harness by that signal."""
    for signum in (signal.SIGKILL, signal.SIGTERM):
        for step in ("build", "run"):
            result, built, sentinel_exists = _run_direct_runner_failure(
                "signal", step, signum=signum
            )
            if result.returncode != -signum:
                raise AssertionError(
                    "classified harness did not re-raise the child signal: "
                    f"signal={signum}, step={step}, "
                    f"status={result.returncode}\n{result.stdout}"
                )
            expected = f"CRASHED: aggregate suite ({step} signal {signum})"
            if expected not in result.stdout:
                raise AssertionError(
                    "classified harness lost the signal diagnostic before "
                    f"re-raising it: expected={expected!r}\n{result.stdout}"
                )
            if f"timed-out aggregate {step}" in result.stdout or sentinel_exists:
                raise AssertionError(
                    f"signal {signum} was treated as a timeout:\n{result.stdout}"
                )
            if built != ["build/tests/aggregate_main.mojo"]:
                raise AssertionError(
                    f"signal {signum} at {step} had unexpected builds: {built}"
                )


def test_direct_runner_timeout_stops_before_following_suite() -> None:
    """A real aggregate build or run timeout exits 124 with its sentinel."""
    for step in ("build", "run"):
        result, built, sentinel_exists = _run_direct_runner_failure("timeout", step)
        if result.returncode != 124:
            raise AssertionError(
                "direct-runner timeout did not preserve exit 124: "
                f"step={step}, status={result.returncode}\n{result.stdout}"
            )
        if f"timed-out aggregate {step}" not in result.stdout:
            raise AssertionError(
                "direct-runner timeout omitted its stopping diagnostic:\n"
                f"{result.stdout}"
            )
        if built != ["build/tests/aggregate_main.mojo"]:
            raise AssertionError(
                f"direct-runner {step} timeout missed its aggregate build:\n{result.stdout}"
            )
        if not sentinel_exists:
            raise AssertionError(f"real {step} timeout removed its deadline sentinel")


def test_direct_runner_spawn_failure_is_not_a_timeout() -> None:
    """A failed build or run start stops as internal error, never a timeout."""
    for step in ("build", "run"):
        result, built, sentinel_exists = _run_direct_runner_failure("spawn", step)
        if result.returncode != 70:
            raise AssertionError(
                "direct-runner spawn failure did not preserve internal exit 70: "
                f"step={step}, status={result.returncode}\n{result.stdout}"
            )
        if f"timed-out aggregate {step}" in result.stdout:
            raise AssertionError(
                "direct-runner spawn failure claimed timeout:\n"
                f"{result.stdout}"
            )
        if "watchdog/internal failure" not in result.stdout:
            raise AssertionError(
                "direct-runner spawn failure missed its distinct diagnostic:\n"
                f"{result.stdout}"
            )
        expected_built = [] if step == "build" else ["build/tests/aggregate_main.mojo"]
        if built != expected_built:
            raise AssertionError(
                f"direct-runner {step} spawn failure had unexpected builds:\n{result.stdout}"
            )
        if sentinel_exists:
            raise AssertionError(f"spawn failure left its {step} deadline sentinel")

def main() -> int:
    """Run every classified-harness behavior test serially."""
    for test in (
        test_repository_root_tracks_the_nested_runner,
        test_recursive_direct_runner,
        test_root_modes_discover_focused_unit_integration_and_full_inventory,
        test_pipeline_builds_each_artifact_once_and_runs_aggregate_once,
        test_sentinel_kind_disagreements_are_internal_errors,
        test_caller_sigint_and_sigterm_remain_cancelled,
        test_cancelled_results_re_raise_the_caller_signal,
        test_cancellation_outranks_a_racing_spawn_failure,
        test_closed_streams_do_not_defeat_the_run_deadline,
        test_timeout_kills_the_aggregate_process_group,
        test_direct_runner_ordinary_exits_are_failures,
        test_direct_runner_signal_deaths_are_re_raised,
        test_direct_runner_timeout_stops_before_following_suite,
        test_direct_runner_spawn_failure_is_not_a_timeout,
    ):
        test()
    print("classified-harness: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
