#!/usr/bin/env python3
"""Fast self-tests for repository test harnesses.

These checks use disposable inputs and tool shims so they exercise the real
shell orchestration without recompiling the product test suite.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

from transcript_compare import compare_directories


REPO_ROOT = Path(__file__).resolve().parent.parent
UNIT_SUITES = {
    "test_cache_registry.mojo",
    "test_cli_arity.mojo",
    "test_cli_arity0.mojo",
    "test_cli_build_flags.mojo",
    "test_cli_collect.mojo",
    "test_cli_grammar.mojo",
    "test_cli_inventory.mojo",
    "test_cli_parse.mojo",
    "test_config.mojo",
    "test_discover_fnmatch.mojo",
    "test_discover_normalize.mojo",
    "test_exec_spec.mojo",
    "test_exec_tty.mojo",
    "test_model_events.mojo",
    "test_model_exit_code.mojo",
    "test_model_node_id.mojo",
    "test_model_outcome.mojo",
    "test_model_parse_disposition.mojo",
    "test_model_slow.mojo",
    "test_model_test_counts.mojo",
    "test_model_test_result.mojo",
    "test_protocol_corruption.mojo",
    "test_protocol_matrix.mojo",
    "test_report_annotations.mojo",
    "test_report_composite.mojo",
    "test_report_console.mojo",
    "test_report_escape.mojo",
    "test_report_json_reporter.mojo",
    "test_report_json_stream.mojo",
    "test_report_junit.mojo",
    "test_report_junit_finalize.mojo",
    "test_report_junit_reporter.mojo",
    "test_report_recording.mojo",
    "test_report_signals.mojo",
    "test_select_logic.mojo",
    "test_select_operands.mojo",
    "test_session_attribution.mojo",
    "test_session_clamp.mojo",
    "test_session_classify.mojo",
    "test_session_detail.mojo",
    "test_session_mangle.mojo",
    "test_session_precompile_paths.mojo",
    "test_session_resilience.mojo",
    "test_session_retry_class.mojo",
    "test_session_shard.mojo",
    "test_session_terminal.mojo",
    "test_session_verdict.mojo",
}
INTEGRATION_SUITES = {
    "test_discover_pipeline.mojo",
    "test_discover_walk.mojo",
    "test_exec_capture.mojo",
    "test_exec_decode.mojo",
    "test_exec_etxtbsy.mojo",
    "test_exec_fdhygiene.mojo",
    "test_exec_flood.mojo",
    "test_exec_interrupt.mojo",
    "test_exec_paths.mojo",
    "test_exec_prestart.mojo",
    "test_exec_reap.mojo",
    "test_exec_sweep.mojo",
    "test_exec_timeout.mojo",
    "test_protocol_collection.mojo",
    "test_protocol_report.mojo",
    "test_session_annotations.mojo",
    "test_session_collect.mojo",
    "test_session_exit_codes.mojo",
    "test_session_flow.mojo",
    "test_session_gates.mojo",
    "test_session_handshake.mojo",
    "test_session_interrupt.mojo",
    "test_session_json_stream.mojo",
    "test_session_junit.mojo",
    "test_session_maxfail.mojo",
    "test_session_outcomes.mojo",
    "test_session_precompile.mojo",
    "test_session_rmtree.mojo",
    "test_session_selection.mojo",
    "test_transcripts_smoke.mojo",
}
SUPPORT_MODULES = {
    "exec_helpers.mojo",
    "session_fixtures.mojo",
    "tmptree.mojo",
    "transcript_cases.mojo",
}
EXEC_FIXTURES = {
    "README.md",
    "argv_echoer.py",
    "close_streams_then_hang.py",
    "dual_flooder.py",
    "escaped_pipe_holder.py",
    "etxtbsy_target.sh",
    "exit_nonzero.py",
    "flooding_grandchild.py",
    "grandchild_exit0.py",
    "grandchild_spawner.py",
    "self_signaler.py",
    "sigterm_grace_exit.py",
    "sigterm_ignorer.py",
    "sleeper.py",
}
PROTOCOL_FIXTURES = {
    "crashing.mojo",
    "empty.mojo",
    "mixed.mojo",
    "noisy.mojo",
    "passing.mojo",
    "raising.mojo",
    "segfault.mojo",
    "skipped.mojo",
    "twofail.mojo",
}


def _write_executable(path: Path, source: str) -> None:
    path.write_text(source, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def check_recursive_direct_runner() -> None:
    """The direct runner selects supplied roots and maps paths injectively."""
    tests_dir = REPO_ROOT / "tests"
    with tempfile.TemporaryDirectory(
        prefix=".harness-check-", dir=tests_dir
    ) as raw_tmp:
        tmp = Path(raw_tmp)
        root_a = tmp / "first"
        root_b = tmp / "second"
        root_a.mkdir()
        root_b.mkdir()
        source_a = root_a / "test_same_name.mojo"
        source_b = root_b / "test_same_name.mojo"
        source_a.write_text("# harness fixture A\n", encoding="utf-8")
        source_b.write_text("# harness fixture B\n", encoding="utf-8")
        disposable_outputs = REPO_ROOT / "build" / "tests" / tmp.name

        tools_dir = tmp / "tools"
        tools_dir.mkdir()
        log_path = tmp / "mojo-log.jsonl"
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
    log.write(json.dumps({"source": source, "output": str(out)}) + "\\n")
out.write_text("#!/usr/bin/env bash\\nprintf '%s\\n' " + repr("RAN:" + source) + "\\n", encoding="utf-8")
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
        try:
            result = subprocess.run(
                ["bash", "scripts/test_all.sh", *roots],
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
            expected_sources = {
                roots[index] + "/test_same_name.mojo" for index in range(2)
            }
            actual_sources = {record["source"] for record in records}
            if actual_sources != expected_sources:
                raise AssertionError(
                    "direct runner did not select exactly the supplied recursive "
                    f"roots: expected {sorted(expected_sources)}, got "
                    f"{sorted(actual_sources)}\n{result.stdout}"
                )
            outputs = {record["output"] for record in records}
            if len(outputs) != 2:
                raise AssertionError(
                    "same-basename suites mapped to a colliding output path: "
                    f"{sorted(outputs)}"
                )
            for source in sorted(expected_sources):
                if f"RAN:{source}" not in result.stdout:
                    raise AssertionError(f"direct runner did not execute {source}")
        finally:
            shutil.rmtree(disposable_outputs, ignore_errors=True)


def check_process_watchdog() -> None:
    """The direct-suite watchdog keeps ordinary exits and bounds hangs."""
    result = subprocess.run(
        [sys.executable, "scripts/process_watchdog_test.py"],
        cwd=REPO_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"process watchdog self-test exited {result.returncode}:\n{result.stdout}"
        )
    if "process-watchdog: OK" not in result.stdout:
        raise AssertionError(
            "process watchdog self-test missed its completion sentinel:\n"
            f"{result.stdout}"
        )


def _run_direct_runner_failure(
    mode: str, step: str
) -> tuple[subprocess.CompletedProcess[str], list[str], str, str, bool]:
    """Run one disposable direct-suite failure at its build or run boundary."""
    if mode not in {"ordinary", "timeout", "spawn"}:
        raise AssertionError(f"unknown direct-runner failure mode: {mode}")
    if step not in {"build", "run"}:
        raise AssertionError(f"unknown direct-runner failure step: {step}")
    tests_dir = REPO_ROOT / "tests"
    with tempfile.TemporaryDirectory(
        prefix=".harness-check-", dir=tests_dir
    ) as raw_tmp:
        tmp = Path(raw_tmp)
        root = tmp / f"direct-{mode}-{step}"
        root.mkdir()
        failing = root / "test_a_failure.mojo"
        following = root / "test_z_following.mojo"
        failing.write_text("# direct-runner failure fixture\n", encoding="utf-8")
        following.write_text("# direct-runner continuation fixture\n", encoding="utf-8")
        disposable_outputs = REPO_ROOT / "build" / "tests" / tmp.name

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
import stat
import sys
import time

args = sys.argv[1:]
mode = os.environ["MTEST_DIRECT_FAILURE_MODE"]
step = os.environ["MTEST_DIRECT_FAILURE_STEP"]
if args[0] == "precompile":
    if mode == "spawn" and step == "build":
        Path(sys.argv[0]).unlink()
    raise SystemExit(0)
if args[0] != "build":
    raise SystemExit(f"unexpected fake mojo command: {args}")
source = next(arg for arg in args if arg.endswith(".mojo"))
with open(os.environ["MTEST_FAKE_MOJO_LOG"], "a", encoding="utf-8") as log:
    log.write(source + "\\n")
if source.endswith("test_a_failure.mojo") and step == "build":
    if mode == "ordinary":
        raise SystemExit(124)
    if mode == "timeout":
        time.sleep(60)
out = Path(args[args.index("-o") + 1])
out.parent.mkdir(parents=True, exist_ok=True)
if source.endswith("test_a_failure.mojo") and step == "run" and mode == "ordinary":
    program = "#!/usr/bin/env bash\\nexit 124\\n"
elif source.endswith("test_a_failure.mojo") and step == "run" and mode == "timeout":
    program = "#!/usr/bin/env bash\\nsleep 60\\n"
elif source.endswith("test_a_failure.mojo") and step == "run" and mode == "spawn":
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
        try:
            result = subprocess.run(
                ["bash", "scripts/test_all.sh", relative_root],
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
            deadline_sentinel = disposable_outputs / root.name / f"test_a_failure.{step}-deadline"
            return (
                result,
                built,
                str(failing.relative_to(REPO_ROOT)),
                str(following.relative_to(REPO_ROOT)),
                deadline_sentinel.exists(),
            )
        finally:
            shutil.rmtree(disposable_outputs, ignore_errors=True)


def check_direct_runner_exit_124_is_not_a_timeout() -> None:
    """An ordinary build or run exit 124 fails but continues to later suites."""
    for step in ("build", "run"):
        result, built, failing, following, sentinel_exists = _run_direct_runner_failure(
            "ordinary", step
        )
        if result.returncode != 1:
            raise AssertionError(
                "ordinary exit 124 did not remain a normal suite failure: "
                f"step={step}, status={result.returncode}\n{result.stdout}"
            )
        if f"FAILED: {failing} ({step} exit 124)" not in result.stdout:
            raise AssertionError(
                "ordinary exit 124 lost its truthful failure diagnostic:\n"
                f"{result.stdout}"
            )
        if f"RAN:{following}" not in result.stdout:
            raise AssertionError(
                "ordinary exit 124 stopped the direct runner before later suites:\n"
                f"{result.stdout}"
            )
        if f"timed-out {step}" in result.stdout or sentinel_exists:
            raise AssertionError(
                "ordinary exit 124 was treated as a timeout:\n"
                f"{result.stdout}"
            )
        if built != [failing, following]:
            raise AssertionError(
                f"ordinary {step} exit 124 did not build both suites: {built}"
            )


def check_direct_runner_timeout_stops_before_following_suite() -> None:
    """A real build or run timeout exits 124 before a later suite starts."""
    for step in ("build", "run"):
        result, built, failing, following, sentinel_exists = _run_direct_runner_failure(
            "timeout", step
        )
        if result.returncode != 124:
            raise AssertionError(
                "direct-runner timeout did not preserve exit 124: "
                f"step={step}, status={result.returncode}\n{result.stdout}"
            )
        if f"timed-out {step}" not in result.stdout:
            raise AssertionError(
                "direct-runner timeout omitted its stopping diagnostic:\n"
                f"{result.stdout}"
            )
        if built != [failing] or f"RAN:{following}" in result.stdout:
            raise AssertionError(
                f"direct-runner {step} timeout reached a later suite:\n{result.stdout}"
            )
        if not sentinel_exists:
            raise AssertionError(f"real {step} timeout removed its deadline sentinel")


def check_direct_runner_spawn_failure_is_not_a_timeout() -> None:
    """A failed build or run start stops as internal error, never a timeout."""
    for step in ("build", "run"):
        result, built, failing, following, sentinel_exists = _run_direct_runner_failure(
            "spawn", step
        )
        if result.returncode != 70:
            raise AssertionError(
                "direct-runner spawn failure did not preserve internal exit 70: "
                f"step={step}, status={result.returncode}\n{result.stdout}"
            )
        if f"timed-out {step}" in result.stdout:
            raise AssertionError(
                "direct-runner spawn failure claimed timeout:\n"
                f"{result.stdout}"
            )
        if "watchdog/internal failure" not in result.stdout:
            raise AssertionError(
                "direct-runner spawn failure missed its distinct diagnostic:\n"
                f"{result.stdout}"
            )
        expected_built = [] if step == "build" else [failing]
        if built != expected_built or f"RAN:{following}" in result.stdout:
            raise AssertionError(
                f"direct-runner {step} spawn failure reached a later suite:\n{result.stdout}"
            )
        if not sentinel_exists:
            raise AssertionError(f"spawn failure removed its {step} deadline sentinel")


def check_suite_layout() -> None:
    """Every executable suite and support module has its classified home."""
    tests_dir = REPO_ROOT / "tests"
    actual_unit = {path.name for path in (tests_dir / "unit").glob("test_*.mojo")}
    actual_integration = {
        path.name for path in (tests_dir / "integration").glob("test_*.mojo")
    }
    if actual_unit != UNIT_SUITES:
        raise AssertionError(
            "unit suite membership mismatch: "
            f"missing={sorted(UNIT_SUITES - actual_unit)}, "
            f"extra={sorted(actual_unit - UNIT_SUITES)}"
        )
    if actual_integration != INTEGRATION_SUITES:
        raise AssertionError(
            "integration suite membership mismatch: "
            f"missing={sorted(INTEGRATION_SUITES - actual_integration)}, "
            f"extra={sorted(actual_integration - INTEGRATION_SUITES)}"
        )
    all_suites = {
        path.relative_to(tests_dir)
        for path in tests_dir.rglob("test_*.mojo")
        if path.is_file()
    }
    classified = {
        *(Path("unit") / name for name in UNIT_SUITES),
        *(Path("integration") / name for name in INTEGRATION_SUITES),
    }
    if all_suites != classified:
        raise AssertionError(
            "tests/ contains an executable suite outside unit/integration: "
            f"{sorted(str(path) for path in all_suites - classified)}"
        )
    actual_support = {
        path.name for path in (tests_dir / "support").glob("*.mojo")
    }
    if actual_support != SUPPORT_MODULES:
        raise AssertionError(
            "support module membership mismatch: "
            f"missing={sorted(SUPPORT_MODULES - actual_support)}, "
            f"extra={sorted(actual_support - SUPPORT_MODULES)}"
        )


def check_exec_fixture_layout() -> None:
    """Exec subprocess actors live with tests, not developer harnesses."""
    fixture_dir = REPO_ROOT / "tests" / "fixtures" / "exec"
    actual = {path.name for path in fixture_dir.iterdir()} if fixture_dir.exists() else set()
    if actual != EXEC_FIXTURES:
        raise AssertionError(
            "exec fixture membership mismatch: "
            f"missing={sorted(EXEC_FIXTURES - actual)}, "
            f"extra={sorted(actual - EXEC_FIXTURES)}"
        )
    if (REPO_ROOT / "scripts" / "exec_targets").exists():
        raise AssertionError("obsolete scripts/exec_targets directory still exists")


def check_transcript_comparator() -> None:
    """The real snapshot comparator accepts only an explicit path relocation."""
    with tempfile.TemporaryDirectory(prefix="mtest-transcript-compare-") as raw_tmp:
        tmp = Path(raw_tmp)
        before = tmp / "before"
        after = tmp / "after"
        before.mkdir()
        after.mkdir()
        old = b"<REPO>/fixtures/"
        new = b"<REPO>/tests/fixtures/protocol/"
        (before / "case.txt").write_bytes(b"source: " + old + b"passing.mojo\nPASS\n")
        (before / "MANIFEST.txt").write_bytes(b"case.txt\n")
        (after / "case.txt").write_bytes(b"source: " + new + b"passing.mojo\nPASS\n")
        (after / "MANIFEST.txt").write_bytes(b"case.txt\n")

        relocated = compare_directories(before, after, replacement=(old, new))
        if not relocated.ok or relocated.changed_files != ("case.txt",):
            raise AssertionError(
                "snapshot comparator rejected a path-only relocation: "
                f"{relocated.errors}"
            )

        (after / "case.txt").write_bytes(
            b"source: " + new + b"passing.mojo\nFAIL\n"
        )
        mutated = compare_directories(before, after, replacement=(old, new))
        if mutated.ok:
            raise AssertionError("snapshot comparator accepted a non-path mutation")

        (after / "case.txt").write_bytes((before / "case.txt").read_bytes())
        exact = compare_directories(before, after)
        if not exact.ok:
            raise AssertionError(f"exact snapshot comparator rejected equality: {exact.errors}")
        (after / "extra.txt").write_bytes(b"unexpected\n")
        extra = compare_directories(before, after)
        if extra.ok:
            raise AssertionError("snapshot comparator accepted an extra file")


def check_protocol_asset_layout() -> None:
    """Protocol generator inputs and outputs occupy their documented homes."""
    fixtures = REPO_ROOT / "tests" / "fixtures" / "protocol"
    actual_fixtures = (
        {path.name for path in fixtures.iterdir()} if fixtures.exists() else set()
    )
    if actual_fixtures != PROTOCOL_FIXTURES:
        raise AssertionError(
            "protocol fixture membership mismatch: "
            f"missing={sorted(PROTOCOL_FIXTURES - actual_fixtures)}, "
            f"extra={sorted(actual_fixtures - PROTOCOL_FIXTURES)}"
        )

    snapshots = REPO_ROOT / "tests" / "snapshots" / "protocol"
    manifest = snapshots / "MANIFEST.txt"
    if not manifest.is_file():
        raise AssertionError("protocol snapshot MANIFEST.txt is missing")
    listed = tuple(manifest.read_text(encoding="utf-8").splitlines())
    actual_snapshots = tuple(
        sorted(path.name for path in snapshots.glob("*.txt") if path != manifest)
    )
    if listed != actual_snapshots or len(listed) != 22:
        raise AssertionError(
            "protocol snapshot manifest/membership mismatch: "
            f"listed={list(listed)}, actual={list(actual_snapshots)}"
        )
    for obsolete in (REPO_ROOT / "fixtures", REPO_ROOT / "goldens"):
        if obsolete.exists():
            raise AssertionError(f"obsolete protocol asset root still exists: {obsolete}")


def check_e2e_layout() -> None:
    """Known-outcome CLI inputs stay outside self-host discovery."""
    e2e_root = REPO_ROOT / "e2e"
    manifest_path = e2e_root / "manifest.json"
    if not manifest_path.is_file():
        raise AssertionError("e2e/manifest.json is missing")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("e2e_root") != "e2e":
        raise AssertionError("e2e manifest does not declare e2e_root=e2e")
    rows = set(manifest["tests"])
    discovered = {
        path.relative_to(REPO_ROOT).as_posix()
        for path in e2e_root.rglob("test_*.mojo")
    }
    if rows != discovered or len(rows) != 31:
        raise AssertionError(
            "e2e manifest/discovery mismatch: "
            f"missing={sorted(discovered - rows)}, stale={sorted(rows - discovered)}"
        )
    referenced = {
        *rows,
        *manifest.get("non_discovered", {}).keys(),
        *manifest.get("support_files", {}).keys(),
    }
    if any(not path.startswith("e2e/") for path in referenced):
        raise AssertionError("e2e manifest retains a path outside e2e/")
    if (REPO_ROOT / "testdata").exists():
        raise AssertionError("obsolete testdata/ root still exists")


def check_format_roots() -> None:
    """Both formatting tasks cover every Mojo source family."""
    pixi = (REPO_ROOT / "pixi.toml").read_text(encoding="utf-8")
    expected = {
        'fmt = "mojo format src tests e2e"',
        'fmt-check = "mojo format src tests e2e && git diff --exit-code"',
    }
    missing = sorted(line for line in expected if line not in pixi)
    if missing:
        raise AssertionError(f"format task root coverage mismatch: missing={missing}")


def main() -> int:
    try:
        check_process_watchdog()
        check_recursive_direct_runner()
        check_direct_runner_exit_124_is_not_a_timeout()
        check_direct_runner_timeout_stops_before_following_suite()
        check_direct_runner_spawn_failure_is_not_a_timeout()
        check_suite_layout()
        check_exec_fixture_layout()
        check_transcript_comparator()
        check_protocol_asset_layout()
        check_e2e_layout()
        check_format_roots()
    except (AssertionError, OSError, subprocess.SubprocessError) as exc:
        print(f"harness-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print("harness-check: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
