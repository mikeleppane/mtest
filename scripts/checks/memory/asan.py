#!/usr/bin/env python3
"""Build the risk-weighted ownership surface from source and run it under ASan.

The inventory is the exec layer's process supervision plus the report layer's
escaping, JUnit rendering, and file finalization, and one real CLI run that
drives all of them together against a hostile child. `notes/test-memory-risk-map.md`
maps every product `# SAFETY:` site to the evidence here, in the Valgrind lane,
or in the native C tests, and states the reason for each exclusion.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

from scripts.checks import native_abi as native_abi_check
from scripts.checks.reports import json_stream as json_stream_oracle
from scripts.checks.reports import junit as junit_oracle


ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "build" / "safety" / "asan"
NATIVE_SOURCE = ROOT / "native" / "mtest_exec_native.c"
NATIVE_PRODUCTION_OBJECT = OUT / "mtest_exec_native.o"
NATIVE_OBJECT = OUT / "mtest_exec_native_test.o"
TESTS = (
    ROOT / "tests" / "integration" / "test_exec_capture.mojo",
    ROOT / "tests" / "integration" / "test_exec_env.mojo",
    ROOT / "tests" / "integration" / "test_exec_flood.mojo",
    ROOT / "tests" / "integration" / "test_exec_timeout.mojo",
    ROOT / "tests" / "integration" / "test_exec_interrupt.mojo",
    ROOT / "tests" / "integration" / "test_exec_etxtbsy.mojo",
    ROOT / "tests" / "integration" / "test_exec_reap.mojo",
    ROOT / "tests" / "integration" / "test_exec_fdhygiene.mojo",
    ROOT / "tests" / "integration" / "test_exec_pool.mojo",
    ROOT / "tests" / "integration" / "test_session_schedule.mojo",
    ROOT / "tests" / "unit" / "test_report_escape.mojo",
    ROOT / "tests" / "unit" / "test_report_json_reporter.mojo",
    ROOT / "tests" / "unit" / "test_report_junit.mojo",
    ROOT / "tests" / "unit" / "test_report_junit_finalize.mojo",
)
ASAN_OPTIONS = "detect_leaks=1:halt_on_error=1:abort_on_error=1"

BUILD_TIMEOUT = 600
"""Seconds allowed for one instrumented `mojo build`, whatever it compiles.

Every source here is built through the product's own import graph, so a suite's
compile cost tracks the size of the closure it reaches rather than its own line
count. `test_session_schedule.mojo` is the clearest case: it imports
`mtest.session`, so it compiles the session and cache modules whole, and its
cold ASan build measured 34.9s before the build cache landed and 101.8s after,
from the same unchanged 465-line source. Nothing about that growth is visible
in the test file, and the next module to join a compiled closure will move the
number again.

So this is a guard against a wedged compiler, not a statement about how long a
build ought to take: it is sized well above the slowest observed compile, on
the reasoning that a build one order of magnitude over budget is stuck and a
build merely slower than last month is not a CI failure. Hosted runners have no
Mojo compile cache, so every CI build pays the full cold cost.

Deliberately separate from the budget for RUNNING a built binary, which stays at
the tighter default in `run`: these suites are expected to finish in seconds,
and a hung binary should surface quickly rather than inherit a compiler's
allowance."""
CONTROL_CASES = {
    "asan_oob_control": "heap-buffer-overflow",
    "asan_uaf_control": "heap-use-after-free",
    "asan_leak_control": "LeakSanitizer: detected memory leaks",
}

CLI_SOURCE = ROOT / "src" / "main.mojo"
"""The real binary's entry point, source-built here rather than reused from
`build/mtest`, so every product frame the probe executes is instrumented."""

CLI_BINARY = OUT / "mtest"
"""The instrumented CLI. Never `build/mtest`: that artifact is uninstrumented,
and the symbol guard below exists to reject it if it is ever substituted."""

CLI_SCRATCH = OUT / "cli"
"""The probe's invocation root. The CLI resolves its project root, its
`.mtest-cache/lastrun` state file, and its per-file build products relative to
the working directory, so the probe runs from a scratch tree of its own and
leaves nothing in the checkout."""

VENDORED_TOML_INCLUDE = ROOT / "vendor" / "mojo-toml"
"""The vendored parser `mtest.config` imports. Included as SOURCE, not as the
precompiled `build/toml.mojopkg`, so the TOML parsing the probe drives is
instrumented too."""

HOSTILE_BUILD_STANDIN = (
    ROOT / "scripts" / "fixtures" / "toolchain" / "fake_hostile_mojo.py"
)
"""The strict `--mojo` stand-in that fabricates the hostile report actor.

It is a Python script the CLI `execve`s, so it and the actor it writes run
OUTSIDE this gate's instrumentation: the compiler and the test child are the
subjects of neither ASan nor Memcheck here, and only the mtest parent is."""

HOSTILE_ACTOR = ROOT / "tests" / "fixtures" / "exec" / "hostile_report_actor.py"
"""The committed actor the stand-in copies. Not invoked directly; named so this
gate's inventory records the fixture whose bytes it depends on."""

CLI_PROBE_LSAN_OPTIONS = "verbosity=1"
"""The one `LSAN_OPTIONS` value the CLI probe sets, and nothing else.

`main` deliberately pops `LSAN_OPTIONS` so a developer's environment cannot
weaken the leak check; this puts back exactly one flag, on the probe alone.
`verbosity` only raises logging — it suppresses nothing, adds no suppression
file, and changes no detection threshold — and it is what makes
`CLI_LSAN_WITNESS` appear."""

CLI_LSAN_WITNESS = "LeakSanitizer: checking for leaks"
"""LeakSanitizer announcing, from inside the process under test, that it is
running the leak check.

This is the ASan lane's answer to the Valgrind lane's Memcheck-provenance
requirement, and it is a POSITIVE witness in a place the `__asan_` symbol guard
cannot reach. That guard is static: it proves the binary was linked against the
runtime, not that the runtime did anything in this run. Without this line, a
clean probe and a probe whose leak check silently never ran are the same
observation. The hostile child cannot forge it either — it is written by the
parent's own runtime, after the child is long gone."""

CLI_PROBE_TREE = "hostile"
"""The single subdirectory of the scratch root that holds the probe module."""

CLI_PROBE_MODULE = "test_hostile_report.mojo"
"""The generated module the CLI is asked to run. Never really compiled: the
stand-in writes the actor in its place."""

CLI_PROBE_STREAM = "hostile.ndjson"
"""The NDJSON artifact, judged by the strict stream consumer."""

CLI_PROBE_REPORT = "hostile.xml"
"""The JUnit artifact, judged by the xmllint + arithmetic oracle."""

CLI_PROBE_KEYWORD = "hostile"
"""The `-k` keyword. Present so the run drives `select.contains_ci`, whose
ASCII case fold is the one `# SAFETY:` site in the select layer; without it that
site would have no instrumented evidence at all."""

CLI_PROBE_EXIT = 1
"""The fixed run's expected client exit code.

ONE, not zero, because the actor writes a genuine reconciling report with one
FAIL row. Pinning 1 is a stronger POSITIVE claim than pinning 0 would be: only a
run that actually built the child, captured its bytes, parsed its report, and
resolved a failing verdict can produce it, whereas 0 is also what a run that did
almost nothing returns.

It is NOT stronger for excluding Valgrind's `--error-exitcode=99` — any exact
pin excludes 99 equally, including a pin of 0."""

CLI_PROBE_ESCAPED_LINE = "    | \\x1B[2J\\x1B[1;31mCHILD-CSI\\x1B[0m"
"""The child's clear-screen-and-recolor sequence as the console must render it.

Pinned whole. Its presence proves three things at once actually ran under
instrumentation: the TOML `show-output` value reached the resolver, the capture
survived to the console, and the escaper rewrote the sequence rather than
forwarding it."""

CLI_PROBE_RAW_BYTES = (
    ("ESC", "\x1b"),
    ("NUL", "\x00"),
    ("BEL", "\x07"),
    ("DEL", "\x7f"),
)
"""Control bytes that must not survive anywhere in the probe's output. The run
resolves `color = "never"` from its config file, so mtest emits no ESC of its
own and a single occurrence is a child byte that got through."""

CLI_PROBE_SOURCE = '''"""Generated source for the instrumented CLI reporter probe.

Never actually compiled: the build stand-in fabricates a hostile report actor in
its place. Real `TestSuite` shape all the same, so discovery sees a genuine test
module rather than a shape only this gate accepts.
"""
from std.testing import assert_equal, TestSuite


def test_hostile_console() raises:
    assert_equal(1, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
'''

CLI_PROBE_CONFIG = """[run]
paths = ["hostile/test_hostile_report.mojo"]
workers = 1
state = true

[build]
compile-timeout = 120

[report]
color = "never"
show-output = "all"
gh-annotations = "off"
"""
"""The probe's project configuration, passed with an explicit `--config`.

Explicit on purpose: an unreadable configuration file named on the command line
is a usage error, so the bounded regular-file read in `mtest.platform` is on the
probe's critical path rather than merely available to it. `paths` supplies the
operand, `show-output` supplies the captured-output surface the escaped-line
assertion depends on, and `state` makes the run write and promote
`.mtest-cache/lastrun` through the temp-file and rename boundary."""


def run(
    command: list[str],
    *,
    env: dict[str, str] | None = None,
    timeout: int = 180,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run one build or test command and capture its complete combined output."""
    return subprocess.run(
        command,
        cwd=ROOT if cwd is None else cwd,
        env=env,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )


def require(condition: bool, message: str) -> None:
    """Fail the hard gate with one actionable diagnostic."""
    if not condition:
        raise SystemExit(f"asan-check: {message}")


def test_count(source: Path) -> int:
    """Count the TestSuite-discoverable top-level test functions in `source`."""
    return len(re.findall(r"(?m)^def test_[A-Za-z0-9_]+\(", source.read_text()))


def compile_native(cc: str) -> None:
    """Build the testing adapter and controls with matching ASan instrumentation."""
    flags = [
        "-std=c17",
        "-O1",
        "-g",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-Wpedantic",
        "-fPIC",
        "-fvisibility=hidden",
        "-fno-omit-frame-pointer",
        "-fsanitize=address",
        "-DMTEST_EXEC_TESTING=1",
        "-I",
        str(ROOT / "native"),
    ]
    for testing, output in (
        (False, NATIVE_PRODUCTION_OBJECT),
        (True, NATIVE_OBJECT),
    ):
        variant_flags = [
            flag for flag in flags if not flag.startswith("-DMTEST_EXEC_TESTING=")
        ]
        variant_flags.append(f"-DMTEST_EXEC_TESTING={1 if testing else 0}")
        compiled = run(
            [cc, *variant_flags, "-c", str(NATIVE_SOURCE), "-o", str(output)]
        )
        require(
            compiled.returncode == 0,
            f"native compile failed for {output.name}:\n{compiled.stdout}",
        )
        symbols = run([os.environ.get("NM", "nm"), "-u", str(output)])
        require(symbols.returncode == 0, f"nm failed:\n{symbols.stdout}")
        require(
            "__asan_" in symbols.stdout,
            f"{output.name} is not ASan-instrumented",
        )


def check_production_exec(env: dict[str, str]) -> None:
    """Source-build and run the production exec boundary under ASan."""
    source = ROOT / "tests" / "dogfood" / "exec_probe.mojo"
    binary = OUT / "exec_probe"
    compiled = run(
        [
            "mojo",
            "build",
            "--sanitize",
            "address",
            "-g",
            "-I",
            "src",
            "-I",
            "tests/support",
            str(source.relative_to(ROOT)),
            "-o",
            str(binary),
            "-Xlinker",
            str(NATIVE_PRODUCTION_OBJECT),
        ],
        timeout=BUILD_TIMEOUT,
    )
    require(
        compiled.returncode == 0,
        f"ASan production exec build failed:\n{compiled.stdout}",
    )
    symbols = run([os.environ.get("NM", "nm"), "-u", str(binary)])
    require(
        symbols.returncode == 0,
        f"nm failed for ASan production exec:\n{symbols.stdout}",
    )
    require("__asan_" in symbols.stdout, "ASan production exec is not instrumented")
    executed = run([str(binary)], env=env)
    (OUT / "production-exec.log").write_text(executed.stdout)
    require(
        executed.returncode == 0,
        f"ASan production exec smoke exited {executed.returncode}",
    )
    require(
        "1 tests run: 1 passed" in executed.stdout,
        "ASan production exec smoke missed completion sentinel",
    )
    print("asan-production-exec: 1/1 passed")


def write_cli_probe_tree(scratch: Path) -> None:
    """Materialize the probe's invocation root: one config and one module.

    Args:
        scratch: The directory the CLI will resolve as its project root.

    Raises:
        OSError: The tree could not be created or written.
    """
    module_dir = scratch / CLI_PROBE_TREE
    module_dir.mkdir(parents=True, exist_ok=True)
    (scratch / "mtest.toml").write_text(CLI_PROBE_CONFIG, encoding="utf-8")
    (module_dir / CLI_PROBE_MODULE).write_text(CLI_PROBE_SOURCE, encoding="utf-8")


def cli_probe_command(binary: Path, scratch: Path) -> list[str]:
    """The one fixed reporter invocation both memory lanes drive.

    Args:
        binary: The instrumented CLI to run.
        scratch: The probe's invocation root, already materialized.

    Returns:
        The complete argv. The operand comes from `[run] paths` in the config
        rather than the command line, so a configuration read that silently
        produced nothing would select no files and fail the verdict assertion.
    """
    return [
        str(binary),
        "--config",
        str(scratch / "mtest.toml"),
        "-k",
        CLI_PROBE_KEYWORD,
        "--mojo",
        str(HOSTILE_BUILD_STANDIN),
        "--json",
        str(scratch / CLI_PROBE_STREAM),
        "--junit-xml",
        str(scratch / CLI_PROBE_REPORT),
    ]


def check_cli_probe_output(
    returncode: int, stdout: str, scratch: Path, label: str
) -> str:
    """Judge one instrumented CLI reporter run and both artifacts it wrote.

    Every rejection names one cause. The two machine formats are handed to the
    project's existing strict oracles — the NDJSON stream consumer and the
    xmllint + arithmetic JUnit checker — rather than parsed here, so this gate
    cannot accept an artifact the report gates would reject.

    Args:
        returncode: The client's exit code.
        stdout: The run's complete combined output.
        scratch: The probe's invocation root.
        label: The lane name, for diagnostics.

    Returns:
        A one-line summary of what the artifacts proved.

    Raises:
        SystemExit: On any mismatch.
    """
    require(
        returncode == CLI_PROBE_EXIT,
        f"{label} CLI reporter run exited {returncode}, expected "
        f"{CLI_PROBE_EXIT} — the hostile report was not consumed",
    )
    require(
        CLI_PROBE_ESCAPED_LINE in stdout,
        f"{label} CLI reporter run is missing the escaped hostile line "
        f"{CLI_PROBE_ESCAPED_LINE!r}",
    )
    for name, byte in CLI_PROBE_RAW_BYTES:
        require(
            byte not in stdout,
            f"{label} CLI reporter run emitted a raw {name} byte ({byte!r})",
        )
    state = scratch / ".mtest-cache" / "lastrun"
    require(
        state.is_file(),
        f"{label} CLI reporter run wrote no state file at {state} — the "
        "temp-file and rename finalization never completed",
    )

    stream_path = scratch / CLI_PROBE_STREAM
    require(stream_path.is_file(), f"{label} CLI reporter run wrote no {stream_path}")
    try:
        report = json_stream_oracle.parse_stream(
            stream_path.read_text(encoding="utf-8")
        )
    except json_stream_oracle.StreamError as error:
        require(False, f"{label} CLI stream failed the strict NDJSON consumer: {error}")
        raise
    require(
        report.version == json_stream_oracle.STREAM_VERSION,
        f"{label} CLI stream declared version {report.version}",
    )
    require(not report.torn_tail, f"{label} CLI stream has a torn tail")
    require(
        report.exit_code == CLI_PROBE_EXIT,
        f"{label} CLI stream terminal reported exit {report.exit_code}",
    )

    report_path = scratch / CLI_PROBE_REPORT
    require(report_path.is_file(), f"{label} CLI reporter run wrote no {report_path}")
    try:
        totals = junit_oracle.check_artifact(report_path)
    except junit_oracle.CheckFailure as error:
        require(False, f"{label} CLI report failed the JUnit oracle: {error}")
        raise
    require(
        (totals.tests, totals.failures) == (1, 1),
        f"{label} CLI report counted tests={totals.tests} failures="
        f"{totals.failures}, expected one failing row",
    )
    return (
        f"NDJSON {len(report.records)} records (v{report.version}), "
        f"JUnit tests={totals.tests} failures={totals.failures}"
    )


def check_cli_instrumentation(stdout: str) -> None:
    """Require the probe's own output to prove the sanitizer ran, and was clean.

    The ASan lane's counterpart to the Valgrind lane's Memcheck provenance. The
    `__asan_` symbol guard in `check_cli` is a STATIC check — it proves the
    binary links the runtime, not that the runtime did anything during this run.
    Only `CLI_LSAN_WITNESS` distinguishes a clean probe from one whose leak check
    never executed, and the two look identical without it.

    Args:
        stdout: The probe's complete combined output.

    Raises:
        SystemExit: The leak check left no witness, or the sanitizer reported a
            finding.
    """
    require(
        CLI_LSAN_WITNESS in stdout,
        f"ASan CLI reporter run left no {CLI_LSAN_WITNESS!r} witness: the leak "
        "check did not run in the probe process",
    )
    require(
        "ERROR: AddressSanitizer" not in stdout,
        "ASan CLI reporter run reported an ASan error",
    )
    require(
        "LeakSanitizer: detected" not in stdout,
        "ASan CLI reporter run reported a leak",
    )


def check_cli(env: dict[str, str]) -> None:
    """Source-build the real CLI under ASan and drive the fixed reporter run.

    Args:
        env: The child environment, carrying `ASAN_OPTIONS`.

    Raises:
        SystemExit: The build failed, the binary is not instrumented, the
            sanitizer reported a finding, or an artifact was rejected.
    """
    compiled = run(
        [
            "mojo",
            "build",
            "--sanitize",
            "address",
            "-g",
            "-I",
            "src",
            "-I",
            str(VENDORED_TOML_INCLUDE),
            str(CLI_SOURCE.relative_to(ROOT)),
            "-o",
            str(CLI_BINARY),
            "-Xlinker",
            str(NATIVE_PRODUCTION_OBJECT),
        ],
        timeout=BUILD_TIMEOUT,
    )
    require(compiled.returncode == 0, f"ASan CLI build failed:\n{compiled.stdout}")
    symbols = run([os.environ.get("NM", "nm"), "-u", str(CLI_BINARY)])
    require(symbols.returncode == 0, f"nm failed for the ASan CLI:\n{symbols.stdout}")
    require("__asan_" in symbols.stdout, "ASan CLI is not instrumented")

    write_cli_probe_tree(CLI_SCRATCH)
    probe_env = dict(env)
    probe_env["LSAN_OPTIONS"] = CLI_PROBE_LSAN_OPTIONS
    executed = run(
        cli_probe_command(CLI_BINARY, CLI_SCRATCH),
        env=probe_env,
        timeout=600,
        cwd=CLI_SCRATCH,
    )
    (OUT / "cli-reporters.log").write_text(executed.stdout)
    check_cli_instrumentation(executed.stdout)
    detail = check_cli_probe_output(
        executed.returncode, executed.stdout, CLI_SCRATCH, "ASan"
    )
    print(f"asan-cli: {detail}")


def check_controls(env: dict[str, str]) -> None:
    """Prove OOB, UAF, and leak findings make the harness fail closed."""
    for case, marker in CONTROL_CASES.items():
        source = ROOT / "tests" / "native" / f"{case}.mojo"
        binary = OUT / case
        compiled = run(
            [
                "mojo",
                "build",
                "--sanitize",
                "address",
                "-g",
                str(source.relative_to(ROOT)),
                "-o",
                str(binary),
                "-Xlinker",
                str(NATIVE_OBJECT),
            ]
        )
        require(
            compiled.returncode == 0,
            f"negative control {case} failed to build:\n{compiled.stdout}",
        )
        result = run([str(binary)], env=env, timeout=30)
        log = OUT / f"control-{case}.log"
        log.write_text(result.stdout)
        require(result.returncode != 0, f"negative control {case} returned success")
        require(marker in result.stdout, f"negative control {case} missed {marker!r}")
        require(
            "CONTROL RETURNED" not in result.stdout,
            f"negative control {case} continued after corruption",
        )
        print(f"asan-control: {case}: detected")


def compile_and_run_test(source: Path, env: dict[str, str]) -> None:
    """Build one Mojo suite from product sources and execute it directly.

    Every classified module under `tests/unit` and `tests/integration` now
    declares its own `main()`, so the source itself is a complete, directly
    buildable entrypoint. There is no generated `*_main.mojo` wrapper to bolt
    on: `mojo build` runs straight on `source`. `-I .` is dropped too -- it
    existed only so a generated wrapper's `import tests.unit.<module>` could
    resolve the repo-root-relative module path; a source file built directly
    never spells that import (verified: no `tests/unit/*.mojo` or
    `tests/integration/*.mojo` file imports another via the `tests.*` package
    path), so the include has nothing left to resolve.
    """
    binary = OUT / source.stem
    compiled = run(
        [
            "mojo",
            "build",
            "--sanitize",
            "address",
            "-g",
            "-I",
            "src",
            "-I",
            "tests/support",
            str(source.relative_to(ROOT)),
            "-o",
            str(binary),
            "-Xlinker",
            str(NATIVE_OBJECT),
        ],
        timeout=BUILD_TIMEOUT,
    )
    require(
        compiled.returncode == 0, f"build failed for {source.name}:\n{compiled.stdout}"
    )
    symbols = run([os.environ.get("NM", "nm"), "-u", str(binary)])
    require(symbols.returncode == 0, f"nm failed for {source.name}:\n{symbols.stdout}")
    require("__asan_" in symbols.stdout, f"{source.name} is not ASan-instrumented")

    executed = run([str(binary)], env=env)
    (OUT / f"{source.stem}.log").write_text(executed.stdout)
    expected = test_count(source)
    sentinel = f"{expected} tests run: {expected} passed"
    require(
        executed.returncode == 0,
        f"{source.name} exited {executed.returncode}:\n{executed.stdout}",
    )
    require(
        sentinel in executed.stdout,
        f"{source.name} missed completion sentinel {sentinel!r}",
    )
    require(
        "ERROR: AddressSanitizer" not in executed.stdout,
        f"{source.name} reported an ASan error",
    )
    require(
        "LeakSanitizer: detected" not in executed.stdout,
        f"{source.name} reported a leak",
    )
    print(f"asan-test: {source.name}: {expected}/{expected} passed")


def main() -> int:
    """Run live controls, the real-CLI probe, then the source-built subset."""
    require(bool(TESTS), "source inventory is empty")
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    cc = native_abi_check.compiler()
    compile_native(cc)
    env = os.environ.copy()
    env["ASAN_OPTIONS"] = ASAN_OPTIONS
    env.pop("LSAN_OPTIONS", None)
    check_controls(env)
    check_production_exec(env)
    check_cli(env)
    for source in TESTS:
        compile_and_run_test(source, env)
    (OUT / "summary.log").write_text(
        "ASan/LSan controls: OOB, UAF, leak detected\n"
        "ASan production exec smoke: passed\n"
        "ASan real-CLI reporter run: NDJSON + JUnit accepted by the strict oracles\n"
        f"Source-built suites: {len(TESTS)}/{len(TESTS)} passed\n"
    )
    print(f"asan-check: OK -- {len(TESTS)} source-built suites + 1 CLI reporter run")
    return 0


if __name__ == "__main__":
    sys.exit(main())
