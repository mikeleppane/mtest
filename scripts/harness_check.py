#!/usr/bin/env python3
"""Fast self-tests for repository test harnesses.

These checks use disposable inputs and tool shims so they exercise the real
shell orchestration without recompiling the product test suite.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import tomllib

import aggregate_tests
import e2e_check
import format_all
import self_host_check
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
CLASSIFIED_PATHS = (
    "tests/integration/test_discover_pipeline.mojo",
    "tests/integration/test_discover_walk.mojo",
    "tests/integration/test_exec_capture.mojo",
    "tests/integration/test_exec_decode.mojo",
    "tests/integration/test_exec_etxtbsy.mojo",
    "tests/integration/test_exec_fdhygiene.mojo",
    "tests/integration/test_exec_flood.mojo",
    "tests/integration/test_exec_interrupt.mojo",
    "tests/integration/test_exec_paths.mojo",
    "tests/integration/test_exec_prestart.mojo",
    "tests/integration/test_exec_reap.mojo",
    "tests/integration/test_exec_sweep.mojo",
    "tests/integration/test_exec_timeout.mojo",
    "tests/integration/test_protocol_collection.mojo",
    "tests/integration/test_protocol_report.mojo",
    "tests/integration/test_session_annotations.mojo",
    "tests/integration/test_session_collect.mojo",
    "tests/integration/test_session_exit_codes.mojo",
    "tests/integration/test_session_flow.mojo",
    "tests/integration/test_session_gates.mojo",
    "tests/integration/test_session_handshake.mojo",
    "tests/integration/test_session_interrupt.mojo",
    "tests/integration/test_session_json_stream.mojo",
    "tests/integration/test_session_junit.mojo",
    "tests/integration/test_session_maxfail.mojo",
    "tests/integration/test_session_outcomes.mojo",
    "tests/integration/test_session_precompile.mojo",
    "tests/integration/test_session_rmtree.mojo",
    "tests/integration/test_session_selection.mojo",
    "tests/integration/test_transcripts_smoke.mojo",
    "tests/unit/test_cache_registry.mojo",
    "tests/unit/test_cli_arity.mojo",
    "tests/unit/test_cli_arity0.mojo",
    "tests/unit/test_cli_build_flags.mojo",
    "tests/unit/test_cli_collect.mojo",
    "tests/unit/test_cli_grammar.mojo",
    "tests/unit/test_cli_inventory.mojo",
    "tests/unit/test_cli_parse.mojo",
    "tests/unit/test_config.mojo",
    "tests/unit/test_discover_fnmatch.mojo",
    "tests/unit/test_discover_normalize.mojo",
    "tests/unit/test_exec_spec.mojo",
    "tests/unit/test_exec_tty.mojo",
    "tests/unit/test_model_events.mojo",
    "tests/unit/test_model_exit_code.mojo",
    "tests/unit/test_model_node_id.mojo",
    "tests/unit/test_model_outcome.mojo",
    "tests/unit/test_model_parse_disposition.mojo",
    "tests/unit/test_model_slow.mojo",
    "tests/unit/test_model_test_counts.mojo",
    "tests/unit/test_model_test_result.mojo",
    "tests/unit/test_protocol_corruption.mojo",
    "tests/unit/test_protocol_matrix.mojo",
    "tests/unit/test_report_annotations.mojo",
    "tests/unit/test_report_composite.mojo",
    "tests/unit/test_report_console.mojo",
    "tests/unit/test_report_escape.mojo",
    "tests/unit/test_report_json_reporter.mojo",
    "tests/unit/test_report_json_stream.mojo",
    "tests/unit/test_report_junit.mojo",
    "tests/unit/test_report_junit_finalize.mojo",
    "tests/unit/test_report_junit_reporter.mojo",
    "tests/unit/test_report_recording.mojo",
    "tests/unit/test_report_signals.mojo",
    "tests/unit/test_select_logic.mojo",
    "tests/unit/test_select_operands.mojo",
    "tests/unit/test_session_attribution.mojo",
    "tests/unit/test_session_clamp.mojo",
    "tests/unit/test_session_classify.mojo",
    "tests/unit/test_session_detail.mojo",
    "tests/unit/test_session_mangle.mojo",
    "tests/unit/test_session_precompile_paths.mojo",
    "tests/unit/test_session_resilience.mojo",
    "tests/unit/test_session_retry_class.mojo",
    "tests/unit/test_session_shard.mojo",
    "tests/unit/test_session_terminal.mojo",
    "tests/unit/test_session_verdict.mojo",
)
CLASSIFIED_TEST_COUNT = 913
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
E2E_NATIVE_FIXTURES = {
    "e2e_json_terminal_write_fault.c",
}
DARWIN_INTERPOSE_DECLARATION = r"""#if defined(__APPLE__)
#define MTEST_PRELOAD_VARIABLE "DYLD_INSERT_LIBRARIES"
#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee \
        __attribute__((section("__DATA,__interpose,interposing"))) = { \
            (const void *)(unsigned long)&_replacement, \
            (const void *)(unsigned long)&_replacee, \
        };
#else
#define MTEST_PRELOAD_VARIABLE "LD_PRELOAD"
#include <dlfcn.h>
#endif"""

CI_PREFLIGHT_TASKS = [
    "version-check",
    "fmt-check",
    "harness-check",
    "safety-check",
    "postfork-check",
    "native-check",
    "junit-check",
    "build",
    "junit-render-check",
    "transcripts-check",
]
CI_TASKS = ["ci-preflight", "test-direct", "test", "e2e"]
CI_FLOOR_TASKS = {
    *CI_PREFLIGHT_TASKS,
    "test-direct",
    "test",
    "e2e",
}
E2E_SCENARIO_NAMES = (
    "manifest-completeness",
    "resilience-matrix",
    "default-suite",
    "hostile",
    "single-pass",
    "exitfirst",
    "maxfail",
    "retries-flaky",
    "crash-attribution",
    "attribution-reruns-crashed-binary",
    "compile-timeout",
    "compile-crash-signature",
    "exclude+stale",
    "all-excluded",
    "empty-dir",
    "failing-gate",
    "timeout",
    "timeout-escalation",
    "precompile",
    "precompile-timeout",
    "precompile-crash-retry",
    "precompile-promotion",
    "quiet-verbose",
    "show-output",
    "durations",
    "color",
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
    "passthrough+forbidden",
    "out-of-root",
    "internal-error",
    "runtime-open-failure",
    "interrupt",
    "json-forward-compat",
    "json-purity",
    "json-color-relocated-stderr",
    "json-destination-taxonomy",
    "json-truncation-interrupt",
    "json-truncation-sigkill",
    "json-truncation-dead-pipe",
    "json-terminal-write-failure",
    "junit-scratch-cleanup",
    "junit-schema-gate",
    "junit-determinism",
    "junit-prior-report-intact",
    "junit-finalization-and-interrupt",
    "annotations-modes",
    "annotations-caps",
    "annotations-conflict",
    "annotations-fencing",
)
LINUX_MATRIX_ROWS = [
    {
        "runner": "ubuntu-24.04",
        "lane": "direct tests",
        "task": "test-direct",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
    {
        "runner": "ubuntu-24.04",
        "lane": "self-hosted tests",
        "task": "test",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
    {
        "runner": "ubuntu-24.04",
        "lane": "end-to-end tests",
        "task": "e2e",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
    {
        "runner": "ubuntu-24.04",
        "lane": "ASan + LSan",
        "task": "asan-check",
        "libc_debug": "false",
        "safety_artifact": "true",
        "artifact_name": "asan-logs",
        "artifact_path": "build/safety/asan/*.log",
    },
    {
        "runner": "ubuntu-24.04",
        "lane": "Valgrind Memcheck",
        "task": "valgrind-check",
        "libc_debug": "true",
        "safety_artifact": "true",
        "artifact_name": "valgrind-logs",
        "artifact_path": "build/safety/valgrind/*.log",
    },
]
MACOS_MATRIX_ROWS = [
    {
        "runner": "macos-15",
        "lane": "direct tests",
        "task": "test-direct",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
    {
        "runner": "macos-15",
        "lane": "self-hosted tests",
        "task": "test",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
    {
        "runner": "macos-15",
        "lane": "end-to-end tests",
        "task": "e2e",
        "libc_debug": "false",
        "safety_artifact": "false",
        "artifact_name": "none",
        "artifact_path": "none",
    },
]


def _write_executable(path: Path, source: str) -> None:
    path.write_text(source, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def check_recursive_direct_runner() -> None:
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
        deadline_sentinel = REPO_ROOT / "build" / "tests" / f"aggregate.{step}-deadline"
        return result, built, deadline_sentinel.exists()


def check_direct_runner_ordinary_exits_are_failures() -> None:
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


def check_direct_runner_current_signal_flattening() -> None:
    """Pin the shell harness's known flattening of child signals to exit 1."""
    for signum in (signal.SIGKILL, signal.SIGTERM):
        shell_status = 128 + signum
        for step in ("build", "run"):
            result, built, sentinel_exists = _run_direct_runner_failure(
                "signal", step, signum=signum
            )
            if result.returncode != 1:
                raise AssertionError(
                    "direct runner no longer has its characterized signal "
                    f"flattening: signal={signum}, step={step}, "
                    f"status={result.returncode}\n{result.stdout}"
                )
            expected = f"FAILED: aggregate suite ({step} exit {shell_status})"
            if expected not in result.stdout:
                raise AssertionError(
                    "direct runner lost the shell's signal-derived status before "
                    f"flattening it: expected={expected!r}\n{result.stdout}"
                )
            if f"timed-out aggregate {step}" in result.stdout or sentinel_exists:
                raise AssertionError(
                    f"signal {signum} was treated as a timeout:\n{result.stdout}"
                )
            if built != ["build/tests/aggregate_main.mojo"]:
                raise AssertionError(
                    f"signal {signum} at {step} had unexpected builds: {built}"
                )


def check_direct_runner_timeout_stops_before_following_suite() -> None:
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


def check_direct_runner_spawn_failure_is_not_a_timeout() -> None:
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
        if not sentinel_exists:
            raise AssertionError(f"spawn failure removed its {step} deadline sentinel")


def check_suite_layout() -> None:
    """Every aggregate module and support module has its classified home."""
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
            "tests/ contains a test module outside unit/integration: "
            f"{sorted(str(path) for path in all_suites - classified)}"
        )
    discovered = aggregate_tests.discover_test_files(
        REPO_ROOT,
        [Path("tests/unit"), Path("tests/integration")],
    )
    actual_paths = tuple(path.as_posix() for path in discovered)
    if actual_paths != CLASSIFIED_PATHS:
        raise AssertionError(
            "classified path ordering/membership mismatch: "
            f"expected={list(CLASSIFIED_PATHS)}, actual={list(actual_paths)}"
        )
    modules = aggregate_tests.load_modules(REPO_ROOT, discovered)
    if sum(len(module.test_functions) for module in modules) != CLASSIFIED_TEST_COUNT:
        raise AssertionError(
            "classified test count mismatch: "
            f"expected={CLASSIFIED_TEST_COUNT}, "
            f"actual={sum(len(module.test_functions) for module in modules)}"
        )
    generated = aggregate_tests.render_entrypoint(modules)
    generated_lines = generated.splitlines()
    expected_imports = [
        f"import {path.removesuffix('.mojo').replace('/', '.')} "
        f"as _mtest_module_{index}"
        for index, path in enumerate(CLASSIFIED_PATHS)
    ]
    actual_imports = [
        line for line in generated_lines if line.startswith("import tests.")
    ]
    if actual_imports != expected_imports:
        raise AssertionError("aggregate entrypoint import membership/order drifted")
    expected_markers = [
        f'    print("==> {path}", flush=True)' for path in CLASSIFIED_PATHS
    ]
    actual_markers = [
        line for line in generated_lines if line.startswith('    print("==> tests/')
    ]
    if actual_markers != expected_markers:
        raise AssertionError("aggregate entrypoint marker membership/order drifted")
    expected_registrations = [
        f"    suite_{index}.test[_mtest_module_{index}.{function}]()"
        for index, module in enumerate(modules)
        for function in module.test_functions
    ]
    actual_registrations = [
        line for line in generated_lines if re.match(r"^    suite_\d+\.test\[", line)
    ]
    if actual_registrations != expected_registrations:
        raise AssertionError("aggregate entrypoint test registration membership drifted")
    for package in (tests_dir, tests_dir / "unit", tests_dir / "integration"):
        if not (package / "__init__.mojo").is_file():
            raise AssertionError(f"aggregate package marker missing: {package}")
    for relative in sorted(classified, key=lambda path: os.fsencode(str(path))):
        source = (tests_dir / relative).read_text(encoding="utf-8")
        try:
            aggregate_tests.test_function_names(source)
        except ValueError as exc:
            raise AssertionError(f"invalid aggregate module {relative}: {exc}") from exc
    try:
        self_host_check.dogfood_test_files(REPO_ROOT)
    except RuntimeError as exc:
        raise AssertionError(str(exc)) from exc
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


def check_e2e_native_fixture_layout() -> None:
    """The E2E-only native fault sources have exact harness membership."""
    fixture_dir = REPO_ROOT / "tests" / "native"
    actual = {path.name for path in fixture_dir.glob("e2e_*")}
    if actual != E2E_NATIVE_FIXTURES:
        raise AssertionError(
            "e2e native fixture membership mismatch: "
            f"missing={sorted(E2E_NATIVE_FIXTURES - actual)}, "
            f"extra={sorted(actual - E2E_NATIVE_FIXTURES)}"
        )


def _check_e2e_interposer_source_policy(source: str) -> None:
    """Validate the write-fault fixture's platform forwarding contracts."""
    if source.count(DARWIN_INTERPOSE_DECLARATION) != 1:
        raise AssertionError(
            "E2E interposer must contain the canonical local Darwin declaration "
            "and select dlfcn.h only elsewhere"
        )
    inheritance_guard = (
        "__attribute__((constructor)) static void "
        "mtest_stop_preload_inheritance(void) {\n"
        "    unsetenv(MTEST_PRELOAD_VARIABLE);\n"
        "}"
    )
    if source.count(inheritance_guard) != 1:
        raise AssertionError(
            "E2E interposer must clear its loader variable before mtest spawns "
            "the Mojo compiler"
        )

    split_marker = "#if defined(__APPLE__)"
    platform_splits = source.split(split_marker)
    if len(platform_splits) != 3:
        raise AssertionError(
            "E2E interposer must contain exactly one include split and one "
            "platform implementation split"
        )
    apple_branch, separator, remainder = platform_splits[2].partition("#else")
    if not separator:
        raise AssertionError("E2E interposer platform split lacks a non-Darwin branch")
    other_branch, terminator, tail = remainder.partition("#endif")
    if not terminator:
        raise AssertionError("E2E interposer platform split lacks its #endif")

    def active_source(branch: str) -> str:
        without_blocks = re.sub(r"/\*.*?\*/", "", branch, flags=re.DOTALL)
        return "\n".join(
            line.split("//", 1)[0] for line in without_blocks.splitlines()
        )

    active_apple = active_source(apple_branch)
    active_other = active_source(other_branch)
    active_tail = active_source(tail)
    active_apple_lines = {line.strip() for line in active_apple.splitlines()}
    apple_required = {
        "struct iovec vector = {(void *)buffer, count};",
        "return writev(fd, &vector, 1);",
        "DYLD_INTERPOSE(mtest_faulting_write, write)",
    }
    apple_forbidden = (
        "RTLD_NEXT",
        "mtest_real_write",
        "__interpose",
        "return write(fd, buffer, count);",
        "ssize_t write(int fd, const void *buffer, size_t count)",
    )
    other_required = (
        "__attribute__((constructor))",
        'dlsym(RTLD_NEXT, "write")',
        "ssize_t write(int fd, const void *buffer, size_t count)",
    )
    if not apple_required.issubset(active_apple_lines):
        raise AssertionError(
            "Darwin E2E interposer must use DYLD_INTERPOSE and writev "
            "forwarding"
        )
    if any(fragment in active_apple for fragment in apple_forbidden):
        raise AssertionError(
            "Darwin E2E interposer contains Linux forwarding or a hand-rolled "
            "interpose tuple"
        )
    if any(fragment not in active_other for fragment in other_required):
        raise AssertionError(
            "non-Darwin E2E interposer must retain constructor-resolved "
            "RTLD_NEXT forwarding"
        )
    if "DYLD_INTERPOSE" in active_other:
        raise AssertionError("non-Darwin E2E interposer contains Darwin forwarding")
    if active_tail.strip():
        raise AssertionError(
            "E2E interposer platform implementation split must contain all "
            "active trailing code"
        )


def check_e2e_interposer_source_policy() -> None:
    """The interposer policy rejects known source-level bypass mutations."""
    source = Path(e2e_check.JSON_TERMINAL_WRITE_FAULT).read_text(encoding="utf-8")
    _check_e2e_interposer_source_policy(source)

    registration = "DYLD_INTERPOSE(mtest_faulting_write, write)"
    call_through = "return writev(fd, &vector, 1);"
    wrapper = (
        "ssize_t write(int fd, const void *buffer, size_t count) {\n"
        "    return mtest_faulting_write(fd, buffer, count);\n"
        "}\n\n"
    )
    mutations = {
        "commented Darwin registration": source.replace(
            registration, "// " + registration, 1
        ),
        "commented Darwin call-through": source.replace(
            call_through, "// " + call_through, 1
        ),
        "exported Darwin write wrapper": source.replace(
            registration + "\n", registration + "\n\n" + wrapper, 1
        ),
        "legacy Darwin section declaration": source.replace(
            "__DATA,__interpose,interposing", "__DATA,__interpose", 1
        ),
        "preload inherited by compiler child": source.replace(
            "    unsetenv(MTEST_PRELOAD_VARIABLE);",
            "    // unsetenv(MTEST_PRELOAD_VARIABLE);",
            1,
        ),
    }
    for name, mutation in mutations.items():
        if mutation == source:
            raise AssertionError(f"E2E interposer mutation did not apply: {name}")
        try:
            _check_e2e_interposer_source_policy(mutation)
        except AssertionError:
            continue
        raise AssertionError(f"E2E interposer policy accepted mutation: {name}")


def check_e2e_interposer_command_topology() -> None:
    """The E2E write-fault interposer has exact target-specific build steps."""
    command_builder = getattr(
        e2e_check, "_json_terminal_write_fault_commands", None
    )
    if command_builder is None:
        raise AssertionError("E2E interposer command builder is missing")
    directory = "/tmp/mtest-json-terminal-fault"
    source = e2e_check.JSON_TERMINAL_WRITE_FAULT
    object_path = os.path.join(directory, "mtest_json_terminal_fault.o")
    common_compile = [
        "/pinned/clang",
        "-std=c17",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-Wpedantic",
        "-fPIC",
        "-c",
        source,
        "-o",
        object_path,
    ]

    darwin_library, darwin_steps = command_builder(
        directory,
        "/pinned/clang",
        platform="darwin",
        platform_driver="/usr/bin/cc",
    )
    expected_darwin_library = os.path.join(
        directory, "libmtest_json_terminal_fault.dylib"
    )
    expected_darwin_steps = [
        ("compile", common_compile),
        (
            "link",
            [
                "/usr/bin/cc",
                "-dynamiclib",
                object_path,
                "-o",
                expected_darwin_library,
            ],
        ),
    ]
    if (darwin_library, darwin_steps) != (
        expected_darwin_library,
        expected_darwin_steps,
    ):
        raise AssertionError(
            "Darwin E2E interposer command topology mismatch: "
            f"actual={(darwin_library, darwin_steps)!r}"
        )

    linux_library, linux_steps = command_builder(
        directory,
        "/pinned/clang",
        platform="linux",
        platform_driver="/unused/platform/driver",
    )
    expected_linux_library = os.path.join(
        directory, "libmtest_json_terminal_fault.so"
    )
    expected_linux_steps = [
        ("compile", common_compile),
        (
            "link",
            [
                "/pinned/clang",
                "-shared",
                object_path,
                "-o",
                expected_linux_library,
                "-ldl",
            ],
        ),
    ]
    if (linux_library, linux_steps) != (
        expected_linux_library,
        expected_linux_steps,
    ):
        raise AssertionError(
            "Linux E2E interposer command topology mismatch: "
            f"actual={(linux_library, linux_steps)!r}"
        )


def check_e2e_interposer_failure_propagation() -> None:
    """Compile and link failures stop at, and name, their exact build step."""
    false_program = shutil.which("false")
    compiler = shutil.which("clang")
    if false_program is None or compiler is None:
        raise AssertionError("harness lacks clang/false for E2E interposer probes")
    with tempfile.TemporaryDirectory(prefix="mtest-e2e-interposer-") as raw_tmp:
        tmp = Path(raw_tmp)
        link_marker = tmp / "link-ran"
        marker_linker = tmp / "marker-linker"
        _write_executable(
            marker_linker,
            "#!/usr/bin/env python3\n"
            "from pathlib import Path\n"
            f"Path({str(link_marker)!r}).touch()\n",
        )
        try:
            e2e_check._build_json_terminal_write_fault(
                raw_tmp,
                platform="darwin",
                compiler=false_program,
                platform_driver=str(marker_linker),
            )
        except e2e_check.ScenarioError as exc:
            if "could not compile" not in str(exc):
                raise AssertionError(
                    f"interposer compile failure lost its step: {exc}"
                ) from exc
        else:
            raise AssertionError("interposer compile failure was accepted")
        if link_marker.exists():
            raise AssertionError("interposer link ran after compilation failed")

        try:
            e2e_check._build_json_terminal_write_fault(
                raw_tmp,
                platform="darwin",
                compiler=compiler,
                platform_driver=false_program,
            )
        except e2e_check.ScenarioError as exc:
            if "could not link" not in str(exc):
                raise AssertionError(
                    f"interposer link failure lost its step: {exc}"
                ) from exc
        else:
            raise AssertionError("interposer link failure was accepted")


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
        if mutated.ok or not any(
            "expected/case.txt" in error and "actual/case.txt" in error
            for error in mutated.errors
        ):
            raise AssertionError(
                "snapshot comparator did not report a byte mutation exactly"
            )

        (after / "case.txt").write_bytes((before / "case.txt").read_bytes())
        exact = compare_directories(before, after)
        if not exact.ok:
            raise AssertionError(f"exact snapshot comparator rejected equality: {exact.errors}")
        (after / "extra.txt").write_bytes(b"unexpected\n")
        extra = compare_directories(before, after)
        if extra.ok or "unexpected snapshot files: ['extra.txt']" not in extra.errors:
            raise AssertionError("snapshot comparator did not report an added file")
        (after / "extra.txt").unlink()
        (after / "case.txt").unlink()
        missing = compare_directories(before, after)
        if missing.ok or "missing snapshot files: ['case.txt']" not in missing.errors:
            raise AssertionError("snapshot comparator did not report a deleted file")


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
    scenario_names = tuple(name for name, _function in e2e_check.SCENARIOS)
    if scenario_names != E2E_SCENARIO_NAMES:
        raise AssertionError(
            "E2E scenario membership/order mismatch: "
            f"expected={list(E2E_SCENARIO_NAMES)}, actual={list(scenario_names)}"
        )
    if len(scenario_names) != 59 or len(set(scenario_names)) != len(scenario_names):
        raise AssertionError(
            "E2E scenarios must contain 59 unique names in the pinned order"
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
        'fmt = "python scripts/format_all.py"',
        'fmt-check = "python scripts/format_all.py && git diff --exit-code"',
    }
    missing = sorted(line for line in expected if line not in pixi)
    if missing:
        raise AssertionError(f"format task root coverage mismatch: missing={missing}")
    if tuple(format_all.FORMAT_ROOTS) != ("src", "tests", "e2e"):
        raise AssertionError(
            f"format source roots drifted: {format_all.FORMAT_ROOTS}"
        )


def _yaml_block(text: str, header: str) -> str:
    """Return the indented body under one exact YAML mapping header."""
    lines = text.splitlines()
    matches = [index for index, line in enumerate(lines) if line == header]
    if len(matches) != 1:
        raise AssertionError(
            f"workflow expected one {header!r} header, found {len(matches)}"
        )
    start = matches[0]
    indent = len(header) - len(header.lstrip(" "))
    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        stripped = line.lstrip(" ")
        if not stripped or stripped.startswith("#"):
            continue
        line_indent = len(line) - len(stripped)
        if line_indent <= indent:
            end = index
            break
    return "\n".join(lines[start + 1 : end])


def _yaml_mapping_keys(block: str, indent: int) -> list[str]:
    """Return exact mapping keys at one absolute indentation level."""
    prefix = re.escape(" " * indent)
    pattern = re.compile(rf"^{prefix}([A-Za-z0-9_-]+):(?:\s.*)?$")
    return [
        match.group(1)
        for line in block.splitlines()
        if (match := pattern.match(line)) is not None
    ]


def _matrix_rows(job: str) -> list[dict[str, str]]:
    """Parse the workflow's deliberately scalar-only matrix include rows."""
    rows: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for line in job.splitlines():
        first = re.match(r"^          - ([a-z_-]+): (.+)$", line)
        if first is not None:
            if current is not None:
                rows.append(current)
            current = {first.group(1): first.group(2)}
            continue
        field = re.match(r"^            ([a-z_-]+): (.+)$", line)
        if current is not None and field is not None:
            current[field.group(1)] = field.group(2)
    if current is not None:
        rows.append(current)
    return rows


def _step_attributes(job: str, name: str) -> dict[str, str]:
    """Return executable scalar attributes from one exact named workflow step."""
    block = _yaml_block(job, f"      - name: {name}")
    attributes: dict[str, str] = {}
    for line in block.splitlines():
        match = re.match(r"^        (if|run|uses): (.+)$", line)
        if match is None:
            continue
        key = match.group(1)
        if key in attributes:
            raise AssertionError(f"workflow step {name!r} repeats {key!r}")
        attributes[key] = match.group(2)
    return attributes


def _task_dependencies(tasks: dict[str, object], name: str) -> list[str]:
    """Read one Pixi task's direct dependency list without accepting shorthands."""
    task = tasks.get(name)
    if not isinstance(task, dict):
        raise AssertionError(f"Pixi task {name!r} must be a dependency aggregate")
    dependencies = task.get("depends-on")
    if not isinstance(dependencies, list) or not all(
        isinstance(item, str) for item in dependencies
    ):
        raise AssertionError(f"Pixi task {name!r} has no string dependency list")
    return dependencies


def _transitive_tasks(tasks: dict[str, object], root: str) -> set[str]:
    """Expand declared Pixi task dependencies from one aggregate root."""
    seen: set[str] = set()
    pending = [root]
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        seen.add(name)
        task = tasks.get(name)
        if isinstance(task, dict):
            dependencies = task.get("depends-on", [])
            if not isinstance(dependencies, list) or not all(
                isinstance(item, str) for item in dependencies
            ):
                raise AssertionError(f"Pixi task {name!r} has invalid dependencies")
            pending.extend(dependencies)
    return seen


def check_ci_task_graph() -> None:
    """The serial local floor is the exact preflight plus behavioral lanes."""
    with (REPO_ROOT / "pixi.toml").open("rb") as manifest:
        tasks = tomllib.load(manifest)["tasks"]
    preflight = _task_dependencies(tasks, "ci-preflight")
    if preflight != CI_PREFLIGHT_TASKS:
        raise AssertionError(
            "ci-preflight membership/order mismatch: "
            f"expected={CI_PREFLIGHT_TASKS}, actual={preflight}"
        )
    ci = _task_dependencies(tasks, "ci")
    if ci != CI_TASKS:
        raise AssertionError(
            f"ci membership/order mismatch: expected={CI_TASKS}, actual={ci}"
        )
    expected_preflight_closure = {"ci-preflight", *CI_PREFLIGHT_TASKS}
    preflight_closure = _transitive_tasks(tasks, "ci-preflight")
    if preflight_closure != expected_preflight_closure:
        raise AssertionError(
            "ci-preflight transitive closure mismatch: "
            f"missing={sorted(expected_preflight_closure - preflight_closure)}, "
            f"extra={sorted(preflight_closure - expected_preflight_closure)}"
        )
    expected_ci_closure = {
        "ci",
        "ci-preflight",
        "build-bin",
        "build-native",
        *CI_FLOOR_TASKS,
    }
    closure = _transitive_tasks(tasks, "ci")
    if closure != expected_ci_closure:
        raise AssertionError(
            "ci transitive floor mismatch: "
            f"missing={sorted(expected_ci_closure - closure)}, "
            f"extra={sorted(closure - expected_ci_closure)}"
        )
    exact_safety_tasks = {
        "asan-check": (
            "python scripts/asan_check_test.py && python scripts/asan_check.py"
        ),
        "valgrind-check": (
            "python scripts/valgrind_check_test.py && "
            "python scripts/valgrind_check.py"
        ),
    }
    for name, command in exact_safety_tasks.items():
        if tasks.get(name) != command:
            raise AssertionError(
                f"{name} no longer runs its exact negative-control harness"
            )


def check_ci_workflow() -> None:
    """The hosted gate has independent platform-local preflight/matrix chains."""
    workflow_path = REPO_ROOT / ".github" / "workflows" / "ci.yml"
    workflow = workflow_path.read_text(encoding="utf-8")
    if "continue-on-error:" in workflow:
        raise AssertionError("CI workflow must not contain continue-on-error")
    triggers = _yaml_mapping_keys(_yaml_block(workflow, "on:"), 2)
    expected_triggers = ["push", "pull_request", "workflow_dispatch"]
    if triggers != expected_triggers or "schedule:" in _yaml_block(workflow, "on:"):
        raise AssertionError(
            f"CI workflow trigger mismatch: expected={expected_triggers}, actual={triggers}"
        )
    if "    branches: [main, master]" not in _yaml_block(workflow, "on:"):
        raise AssertionError("CI push trigger no longer pins main and master")

    jobs = _yaml_mapping_keys(_yaml_block(workflow, "jobs:"), 2)
    expected_jobs = [
        "linux-preflight",
        "linux-test-matrix",
        "package",
        "macos-preflight",
        "macos-test-matrix",
    ]
    if jobs != expected_jobs:
        raise AssertionError(
            f"CI workflow job membership mismatch: expected={expected_jobs}, actual={jobs}"
        )
    job_blocks = {name: _yaml_block(workflow, f"  {name}:") for name in jobs}
    expected_needs = {
        "linux-preflight": None,
        "linux-test-matrix": "linux-preflight",
        "package": None,
        "macos-preflight": None,
        "macos-test-matrix": "macos-preflight",
    }
    for name, expected in expected_needs.items():
        if re.search(r"^    if:", job_blocks[name], re.MULTILINE):
            raise AssertionError(f"CI job {name!r} must not be conditionally disabled")
        matches = re.findall(r"^    needs:(.*)$", job_blocks[name], re.MULTILINE)
        expected_lines = [] if expected is None else [f" {expected}"]
        if matches != expected_lines:
            raise AssertionError(
                f"CI job {name!r} needs mismatch: "
                f"expected={expected_lines}, actual={matches}"
            )

    matrices = {
        "linux-test-matrix": LINUX_MATRIX_ROWS,
        "macos-test-matrix": MACOS_MATRIX_ROWS,
    }
    expected_fail_fast = {
        "linux-test-matrix": "true",
        "macos-test-matrix": "false",
    }
    for name, expected in matrices.items():
        job = job_blocks[name]
        expected_strategy = (
            "    strategy:\n"
            f"      fail-fast: {expected_fail_fast[name]}\n"
            "      matrix:\n"
            "        include:"
        )
        if expected_strategy not in job:
            raise AssertionError(
                f"CI job {name!r} strategy/fail-fast layout mismatch: "
                f"expected={expected_strategy!r}"
            )
        actual = _matrix_rows(job)
        if actual != expected:
            raise AssertionError(
                f"CI job {name!r} matrix mismatch: expected={expected}, actual={actual}"
            )
        runs_on = re.findall(r"^    runs-on: (.+)$", job, re.MULTILINE)
        if runs_on != ["${{ matrix.runner }}"]:
            raise AssertionError(
                f"CI job {name!r} runner dispatch mismatch: actual={runs_on}"
            )
        run_step = _step_attributes(job, "Run ${{ matrix.lane }}")
        if run_step != {"run": "pixi run ${{ matrix.task }}"}:
            raise AssertionError(
                f"CI job {name!r} matrix task dispatch mismatch: actual={run_step}"
            )

    behavioral_floor = CI_TASKS[1:]
    expected_matrix_tasks = {
        "linux-test-matrix": [
            *behavioral_floor,
            "asan-check",
            "valgrind-check",
        ],
        "macos-test-matrix": behavioral_floor,
    }
    for name, expected_tasks in expected_matrix_tasks.items():
        actual_tasks = [row.get("task") for row in _matrix_rows(job_blocks[name])]
        if actual_tasks != expected_tasks:
            raise AssertionError(
                f"CI job {name!r} task coverage mismatch against the required "
                f"floor: expected={expected_tasks}, actual={actual_tasks}"
            )

    linux_preflight = job_blocks["linux-preflight"]
    linux_commands = re.findall(r"^        run: (.+)$", linux_preflight, re.MULTILINE)
    expected_linux_commands = ["pixi run mojo-version", "pixi run ci-preflight"]
    if linux_commands != expected_linux_commands:
        raise AssertionError(
            "Linux preflight command mismatch: "
            f"expected={expected_linux_commands}, actual={linux_commands}"
        )
    macos_preflight = job_blocks["macos-preflight"]
    macos_commands = re.findall(r"^        run: (.+)$", macos_preflight, re.MULTILINE)
    expected_macos_commands = [
        "|",
        "pixi run native-check",
        "pixi run build-bin",
        "./build/mtest --help",
    ]
    if macos_commands != expected_macos_commands:
        raise AssertionError(
            "macOS preflight prerequisite order mismatch: "
            f"expected={expected_macos_commands}, actual={macos_commands}"
        )

    package_commands = re.findall(
        r"^        run: (.+)$", job_blocks["package"], re.MULTILINE
    )
    expected_package_commands = [
        "pixi run mojo-version",
        "pixi run package-check",
    ]
    if package_commands != expected_package_commands:
        raise AssertionError(
            "independent package command mismatch: "
            f"expected={expected_package_commands}, actual={package_commands}"
        )

    linux_matrix = job_blocks["linux-test-matrix"]
    expected_linux_steps = {
        "Install matching glibc debug symbols": {
            "if": "${{ matrix.libc_debug }}",
            "run": "|",
        },
        "Tool provenance": {"run": "|"},
        "Valgrind provenance": {
            "if": "${{ matrix.libc_debug }}",
            "run": "pixi run valgrind --version",
        },
        "Build safety prerequisite": {
            "if": "${{ matrix.safety_artifact }}",
            "run": "pixi run build",
        },
        "Upload safety logs": {
            "if": "${{ always() && matrix.safety_artifact }}",
            "uses": "actions/upload-artifact@v4",
        },
    }
    for name, expected in expected_linux_steps.items():
        actual = _step_attributes(linux_matrix, name)
        if actual != expected:
            raise AssertionError(
                f"Linux matrix step {name!r} mismatch: "
                f"expected={expected}, actual={actual}"
            )

    required_linux_lines = [
        "libc_version=\"$(dpkg-query -W -f='${Version}' libc6)\"",
        "sudo apt-get update",
        "apt-cache policy libc6 libc6-dbg",
        'sudo apt-get install --yes --no-install-recommends "libc6-dbg=$libc_version"',
        "installed_libc_version=\"$(dpkg-query -W -f='${Version}' libc6)\"",
        "debug_version=\"$(dpkg-query -W -f='${Version}' libc6-dbg)\"",
        'test "$installed_libc_version" = "$libc_version"',
        'test "$debug_version" = "$libc_version"',
        "pixi run mojo-version",
        "pixi run clang --version",
        "ldd --version | head -1",
    ]
    linux_lines = linux_matrix.splitlines()
    missing_lines = [
        line for line in required_linux_lines if f"          {line}" not in linux_lines
    ]
    if missing_lines:
        raise AssertionError(
            f"Linux matrix lost memory-safety commands: missing={missing_lines}"
        )
    upload_block = _yaml_block(linux_matrix, "      - name: Upload safety logs")
    expected_upload_lines = {
        "          name: ${{ matrix.artifact_name }}",
        "          path: ${{ matrix.artifact_path }}",
        "          if-no-files-found: warn",
        "          retention-days: 30",
    }
    actual_upload_lines = {
        line for line in upload_block.splitlines() if line.startswith("          ")
    }
    if actual_upload_lines != expected_upload_lines:
        raise AssertionError(
            "Linux safety artifact inputs mismatch: "
            f"expected={sorted(expected_upload_lines)}, "
            f"actual={sorted(actual_upload_lines)}"
        )

    for name, job in job_blocks.items():
        if job.count("uses: actions/checkout@v4") != 1:
            raise AssertionError(f"CI job {name!r} does not pin checkout@v4 once")
        if job.count("uses: prefix-dev/setup-pixi@v0.10.0") != 1:
            raise AssertionError(f"CI job {name!r} does not pin setup-pixi once")
        if "          locked: true" not in job or "          cache: true" not in job:
            raise AssertionError(f"CI job {name!r} lacks locked cached Pixi setup")

    legacy = REPO_ROOT / ".github" / "workflows" / "memory-safety.yml"
    if legacy.exists():
        raise AssertionError("legacy scheduled memory-safety workflow still exists")


def main() -> int:
    try:
        check_process_watchdog()
        check_recursive_direct_runner()
        check_direct_runner_ordinary_exits_are_failures()
        check_direct_runner_current_signal_flattening()
        check_direct_runner_timeout_stops_before_following_suite()
        check_direct_runner_spawn_failure_is_not_a_timeout()
        check_suite_layout()
        check_exec_fixture_layout()
        check_e2e_native_fixture_layout()
        check_e2e_interposer_source_policy()
        check_e2e_interposer_command_topology()
        check_e2e_interposer_failure_propagation()
        check_transcript_comparator()
        check_protocol_asset_layout()
        check_e2e_layout()
        check_format_roots()
        check_ci_task_graph()
        check_ci_workflow()
    except (AssertionError, OSError, subprocess.SubprocessError) as exc:
        print(f"harness-check: FAIL: {exc}", file=sys.stderr)
        return 1
    print("harness-check: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
