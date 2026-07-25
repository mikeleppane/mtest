#!/usr/bin/env python3
"""Run source-built exec and report suites under the locked Valgrind Memcheck.

Alongside those suites the lane drives one real, source-built CLI reporter run
against a hostile child, so report escaping, JUnit rendering, and report/state
file finalization are executed by the shipped entry point rather than only by
unit suites. `notes/test-memory-risk-map.md` maps every product `# SAFETY:` site
to the evidence here, in the ASan lane, or in the native C tests, and states the
reason for each exclusion.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

from scripts.harness import aggregate
from scripts.checks import native_abi as native_abi_check
from scripts.checks.reports import json_stream as json_stream_oracle
from scripts.checks.reports import junit as junit_oracle


ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "build" / "safety" / "valgrind"
TEST_SCRATCH = ROOT / "build" / "tests"
NATIVE_SOURCE = ROOT / "native" / "mtest_exec_native.c"
NATIVE_OBJECT = OUT / "mtest_exec_native_test.o"
NATIVE_PRODUCTION_OBJECT = OUT / "mtest_exec_native.o"
CONTROL_SOURCE = ROOT / "tests" / "native" / "native_controls.c"
CONTROL_BINARY = OUT / "native_controls"
NATIVE_TESTS = (
    (ROOT / "tests" / "native" / "test_exec_native.c", "adapter-smoke: OK"),
    (
        ROOT / "tests" / "native" / "test_exec_native_signals.c",
        "signal-transaction: OK",
    ),
)
EXEC_TEST_ROOT = ROOT / "tests" / "integration"
CONFIG_TEST = ROOT / "tests" / "unit" / "test_config.mojo"
REPORT_TESTS = (
    ROOT / "tests" / "unit" / "test_report_escape.mojo",
    ROOT / "tests" / "unit" / "test_report_junit.mojo",
    ROOT / "tests" / "unit" / "test_report_junit_finalize.mojo",
)
"""The report-layer suites whose ownership paths this lane can judge.

Escaping and JUnit rendering both end in `unsafe_from_utf8`; JUnit finalization
creates a unique temp file, writes it, closes it, and renames it over the
target. Every one of those is an ownership transfer that a unit test alone can
only prove correct in its observable result.

`test_report_json_reporter.mojo` is deliberately absent — see
`FD_ADVERSARIAL_SUITE`."""

FD_ADVERSARIAL_SUITE = ROOT / "tests" / "unit" / "test_report_json_reporter.mojo"
"""The one report suite this lane cannot run, and why.

Its subject IS descriptor misuse: `test_write_failure_latches_and_later_handles_noop`
hands the reporter a descriptor it closed first, so the header write must latch
`EBADF`, and `test_close_json_fd_reports_failure_on_a_dead_descriptor` closes the
same descriptor twice so the second close must REPORT the failure rather than
swallow it. Under `--track-fds=yes` Memcheck reports both as errors — correctly;
they are exactly the operations the tests exist to perform.

The alternatives were both worse than exclusion: running it with `--track-fds=no`
would drop the descriptor channel and the `FILE DESCRIPTORS` assertion for a
suite that is entirely about descriptors, and relaxing `check_product_output`
would weaken the contract for all eighteen. The site it covers,
`json_stream_reporter.mojo`'s borrowed-`String` write loop, keeps its Memcheck
evidence through the real-CLI probe below, which drives `open_json_fd`,
`_write_all`, and `close_json_fd` on live descriptors under the full flag set.
The ASan lane runs this suite unchanged: LeakSanitizer does not track
descriptors, so the deliberate `EBADF` calls are inert there."""

TESTS = tuple(sorted(EXEC_TEST_ROOT.glob("test_exec_*.mojo"))) + (
    CONFIG_TEST,
) + REPORT_TESTS
VALGRIND_FLAGS = (
    "--tool=memcheck",
    "--leak-check=full",
    "--show-leak-kinds=all",
    "--errors-for-leak-kinds=definite,indirect,possible",
    "--undef-value-errors=yes",
    "--track-origins=yes",
    "--track-fds=yes",
    "--error-exitcode=99",
    "--show-error-list=yes",
    "--trace-children=no",
    "--enable-debuginfod=no",
    "--default-suppressions=no",
)
POSTFORK_FLAGS = (
    "--tool=memcheck",
    "--leak-check=no",
    "--undef-value-errors=yes",
    "--track-origins=yes",
    "--track-fds=no",
    "--error-exitcode=99",
    "--show-error-list=yes",
    "--trace-children=no",
    "--enable-debuginfod=no",
    "--default-suppressions=no",
)
CLI_VALGRIND_FLAGS = (
    "--tool=memcheck",
    "--leak-check=full",
    "--show-leak-kinds=all",
    "--errors-for-leak-kinds=definite,indirect",
    "--undef-value-errors=yes",
    "--track-origins=yes",
    "--track-fds=yes",
    "--error-exitcode=99",
    "--show-error-list=yes",
    "--trace-children=no",
    "--enable-debuginfod=no",
    "--default-suppressions=no",
)
"""Memcheck flags for the real-CLI probe.

Identical to `VALGRIND_FLAGS` except that `possible` is absent from
`--errors-for-leak-kinds`. The CLI initializes the Mojo async runtime's CPU
device, which starts one unjoined worker thread per core; glibc's per-thread
TLS descriptor table is then reachable only through an interior pointer and
Memcheck classifies it `possibly lost`. That is a runtime artifact whose block
count tracks the host's core count, so it cannot be pinned the way
`EXPECTED_REACHABLE` pins the suites' baseline. Dropping it from the ERROR
channel does NOT drop it from the gate: `check_cli_provenance` still rejects any
possibly-lost or still-reachable record carrying a product or native-adapter
frame, which is the claim that actually matters, and every other lane keeps
`possible` as a hard error."""

CLI_SOURCE = ROOT / "src" / "main.mojo"
"""The real binary's entry point, source-built with debug information here so
Memcheck can attribute a finding to a product line rather than an address."""

CLI_BINARY = OUT / "mtest"
"""The debug-built CLI this lane wraps. Never `build/mtest`: the production
artifact carries no `--target-cpu` guarantee and no guarantee of `-g`."""

CLI_SCRATCH = OUT / "cli"
"""The probe's invocation root; see the ASan lane for why it is not the repo."""

VENDORED_TOML_INCLUDE = ROOT / "vendor" / "mojo-toml"
"""The vendored parser, included as source so its frames carry debug info."""

CLI_HOME = OUT / "cli-home"
"""The probe's `HOME`. Separate from `clean_environment`'s, because the CLI
writes below its invocation root and a shared empty home would mix the two."""

HOSTILE_BUILD_STANDIN = ROOT / "scripts" / "fixtures" / "toolchain" / "fake_hostile_mojo.py"
"""The strict `--mojo` stand-in that fabricates the hostile report actor.

Both it and the actor are children the CLI `execve`s, and this lane runs with
`--trace-children=no`, so neither is under Memcheck: the subject is the mtest
parent alone. That is the point of choosing a stand-in over the real compiler —
a `mojo build` child under Memcheck would dominate the runtime and report on a
toolchain this project does not own."""

HOSTILE_ACTOR = ROOT / "tests" / "fixtures" / "exec" / "hostile_report_actor.py"
"""The committed actor the stand-in copies. Named so this gate's inventory
records the fixture whose bytes it depends on."""

CLI_MEMCHECK_BANNER = "Memcheck, a memory error detector"
"""Valgrind's own first line. Its absence means the probe never ran wrapped."""

CLI_ERROR_SUMMARY = "ERROR SUMMARY: 0 errors from 0 contexts"
"""The clean-run summary. Also absent from an unwrapped run, which is what makes
the pair a provenance proof rather than only a cleanliness assertion."""

CLI_FD_SUMMARY = "FILE DESCRIPTORS: 3 open (3 inherited) at exit."
"""The expected descriptor state at exit: the three the gate handed the client,
and nothing else. The CLI opens a descriptor for the NDJSON stream, one for the
state temp file, and one per JUnit spool fragment; every one of them must be
released before `main` returns, and a retained report descriptor would show up
here as a fourth open fd rather than as a leak.

`(3 inherited)` matches the suites: this gate runs its clients through
`subprocess` with piped stdout/stderr, so all three standard descriptors are
inherited rather than freshly opened terminals."""

CLI_MEMCHECK_EXIT = 99
"""`--error-exitcode`. Distinguishes a Memcheck finding from the client's own
nonzero exit, which the probe expects."""

CLI_PROBE_TREE = "hostile"
"""The single subdirectory of the scratch root that holds the probe module."""

CLI_PROBE_MODULE = "test_hostile_report.mojo"
"""The generated module the CLI is asked to run."""

CLI_PROBE_STREAM = "hostile.ndjson"
"""The NDJSON artifact, judged by the strict stream consumer."""

CLI_PROBE_REPORT = "hostile.xml"
"""The JUnit artifact, judged by the xmllint + arithmetic oracle."""

CLI_PROBE_KEYWORD = "hostile"
"""The `-k` keyword, present so the run drives `select.contains_ci`."""

CLI_PROBE_EXIT = 1
"""The fixed run's expected client exit code; see the ASan lane."""

CLI_PROBE_ESCAPED_LINE = "    | \\x1B[2J\\x1B[1;31mCHILD-CSI\\x1B[0m"
"""The child's clear-screen-and-recolor sequence as the console must render it."""

CLI_PROBE_RAW_BYTES = (
    ("ESC", "\x1b"),
    ("NUL", "\x00"),
    ("BEL", "\x07"),
    ("DEL", "\x7f"),
)
"""Control bytes that must not survive anywhere in the probe's output."""

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

Byte-identical to the ASan lane's, and `test_valgrind.py` asserts that equality
so the two lanes cannot drift into probing different runs."""

EXPECTED_REACHABLE = (78_596, 10)
VALGRIND_TARGET_CPU = "x86-64-v3"


def run(
    command: list[str],
    *,
    env: dict[str, str],
    timeout: int = 300,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run one command with only standard streams inherited by the client."""
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
    """Fail the memory gate with one actionable diagnostic."""
    if not condition:
        raise SystemExit(f"valgrind-check: {message}")


def clean_environment() -> dict[str, str]:
    """Return an environment that cannot import user Valgrind configuration."""
    env = os.environ.copy()
    for name in ("VALGRIND_OPTS", "DEBUGINFOD_URLS"):
        env.pop(name, None)
    home = OUT / "empty-home"
    home.mkdir()
    env["HOME"] = str(home)
    require(not (ROOT / ".valgrindrc").exists(), "repository .valgrindrc is forbidden")
    return env


def prepare_test_scratch() -> None:
    """Create the scratch tree required by source-built integration suites."""
    TEST_SCRATCH.mkdir(parents=True, exist_ok=True)


def test_count(source: Path) -> int:
    """Count the TestSuite-discoverable top-level test functions in `source`."""
    return len(re.findall(r"(?m)^def test_[A-Za-z0-9_]+\(", source.read_text()))


def compile_inputs(cc: str, env: dict[str, str]) -> None:
    """Build both adapter variants and the control executable with debug info.

    The testing variant backs the Mojo suites and the fault controls; the
    production variant, with `MTEST_EXEC_TESTING=0`, is what the real-CLI probe
    links, so that probe exercises the same object the shipped binary carries.
    """
    flags = [
        "-std=c17",
        "-O0",
        "-g",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-Wpedantic",
        "-fPIC",
        "-fvisibility=hidden",
        "-DMTEST_EXEC_TESTING=1",
        "-I",
        str(ROOT / "native"),
    ]
    compiled = run(
        [cc, *flags, "-c", str(NATIVE_SOURCE), "-o", str(NATIVE_OBJECT)],
        env=env,
    )
    require(compiled.returncode == 0, f"native compile failed:\n{compiled.stdout}")
    production_flags = [
        flag for flag in flags if not flag.startswith("-DMTEST_EXEC_TESTING=")
    ]
    production_flags.append("-DMTEST_EXEC_TESTING=0")
    production = run(
        [
            cc,
            *production_flags,
            "-c",
            str(NATIVE_SOURCE),
            "-o",
            str(NATIVE_PRODUCTION_OBJECT),
        ],
        env=env,
    )
    require(
        production.returncode == 0,
        f"production native compile failed:\n{production.stdout}",
    )
    linked = run(
        [cc, *flags, str(NATIVE_SOURCE), str(CONTROL_SOURCE), "-o", str(CONTROL_BINARY)],
        env=env,
    )
    require(linked.returncode == 0, f"control link failed:\n{linked.stdout}")
    for source, _ in NATIVE_TESTS:
        binary = OUT / source.stem
        compiled_test = run(
            [cc, *flags, str(NATIVE_SOURCE), str(source), "-o", str(binary)],
            env=env,
        )
        require(
            compiled_test.returncode == 0,
            f"native test link failed for {source.name}:\n{compiled_test.stdout}",
        )


def valgrind(
    command: list[str],
    env: dict[str, str],
    *,
    quiet_child: bool,
    flags: tuple[str, ...] = VALGRIND_FLAGS,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run the locked Memcheck command, optionally omitting fork-child reports.

    Product suites silence only the transient pre-exec fork copy. Otherwise a
    deliberate spawn failure reports the parent's still-live plan allocations
    and setup descriptor as leaks in the `_exit(127)` child. The parent process,
    where ownership is decided and released, remains fully checked. Native
    controls independently prove project/native invalid, undefined, leak, and fd
    findings remain visible. A second unsilenced pass audits invalid and
    undefined accesses in the pre-exec fork child without treating its COW
    allocations and inherited descriptors as ownership leaks.
    """
    selected_flags = list(flags)
    if quiet_child:
        selected_flags.append("--child-silent-after-fork=yes")
    result = run(["valgrind", *selected_flags, *command], env=env, cwd=cwd)
    startup_failure = re.search(
        r"(?m)^valgrind:\s+Fatal error at startup:", result.stdout
    )
    if startup_failure is not None:
        (OUT / "startup-failure.log").write_text(result.stdout)
        require(
            False,
            f"Valgrind failed to start for {' '.join(command)}:\n{result.stdout}",
        )
    return result


def check_controls(env: dict[str, str]) -> None:
    """Prove every parent and fork-child detection channel stays live."""
    cases = {
        "mem-undefined": "Conditional jump or move depends on uninitialised value",
        "mem-invalid": "Invalid read",
        "asan-leak": "definitely lost: 64 bytes in 1 blocks",
        "mem-fd": "Open file descriptor",
    }
    for case, marker in cases.items():
        result = valgrind([str(CONTROL_BINARY), case], env, quiet_child=False)
        (OUT / f"control-{case}.log").write_text(result.stdout)
        require(marker in result.stdout, f"negative control {case} missed {marker!r}")
        if case == "mem-fd":
            require(result.returncode == 99, f"fd control exited {result.returncode}, expected 99")
            require(
                "FILE DESCRIPTORS: 4 open (3 inherited)" in result.stdout,
                "fd control did not expose the extra descriptor",
            )
        else:
            require(
                result.returncode == 99,
                f"negative control {case} exited {result.returncode}, expected 99",
            )
        print(f"valgrind-control: {case}: detected")

    child = valgrind(
        [str(CONTROL_BINARY), "mem-child-invalid"],
        env,
        quiet_child=False,
        flags=POSTFORK_FLAGS,
    )
    (OUT / "control-mem-child-invalid.log").write_text(child.stdout)
    require(child.returncode == 0, f"child-memory control parent exited {child.returncode}")
    require("Invalid read" in child.stdout, "child-memory control hid the fork-child finding")
    summaries = [
        int(value)
        for value in re.findall(r"ERROR SUMMARY: ([0-9,]+) errors", child.stdout)
    ]
    require(
        any(value > 0 for value in summaries),
        "child-memory control parser saw no child error summary",
    )
    print("valgrind-control: mem-child-invalid: detected")


def check_native_tests(env: dict[str, str]) -> None:
    """Run the adapter lifecycle binaries through both Memcheck passes."""
    for source, sentinel in NATIVE_TESTS:
        binary = OUT / source.stem
        full = valgrind([str(binary)], env, quiet_child=True)
        (OUT / f"{source.stem}.log").write_text(full.stdout)
        require(full.returncode == 0, f"{source.name} exited {full.returncode}:\n{full.stdout}")
        require(sentinel in full.stdout, f"{source.name} missed {sentinel!r}")
        require(
            "ERROR SUMMARY: 0 errors from 0 contexts" in full.stdout,
            f"{source.name} has Memcheck errors",
        )
        require(
            "All heap blocks were freed -- no leaks are possible" in full.stdout,
            f"{source.name} retained native memory",
        )
        require(
            "FILE DESCRIPTORS: 3 open (3 inherited) at exit" in full.stdout,
            f"{source.name} has a nonstandard fd count",
        )

        postfork = valgrind(
            [str(binary)], env, quiet_child=False, flags=POSTFORK_FLAGS
        )
        (OUT / f"{source.stem}.postfork.log").write_text(postfork.stdout)
        require(
            postfork.returncode == 0,
            f"{source.name} post-fork audit exited {postfork.returncode}",
        )
        require(sentinel in postfork.stdout, f"{source.name} post-fork audit missed {sentinel!r}")
        summaries = [
            int(value.replace(",", ""))
            for value in re.findall(r"ERROR SUMMARY: ([0-9,]+) errors", postfork.stdout)
        ]
        require(
            summaries and all(value == 0 for value in summaries),
            f"{source.name} post-fork errors: {summaries}",
        )
        print(f"valgrind-native: {source.name}: passed")


def parse_reachable(output: str, source: Path) -> None:
    """Require the reviewed pinned Mojo-runtime reachable-allocation baseline."""
    match = re.search(r"still reachable: ([0-9,]+) bytes in ([0-9,]+) blocks", output)
    require(match is not None, f"{source.name} has no reachable summary")
    got = (int(match.group(1).replace(",", "")), int(match.group(2).replace(",", "")))
    require(
        got == EXPECTED_REACHABLE,
        f"{source.name} reachable baseline changed: {got} != {EXPECTED_REACHABLE}",
    )
    records = re.findall(
        r"(?ms)^==\d+== [0-9,]+ bytes in .*?still reachable.*?"
        r"(?=^==\d+== (?:[0-9,]+ bytes|LEAK SUMMARY:))",
        output,
    )
    for record in records:
        require(
            "native/mtest_exec_native.c" not in record,
            f"{source.name} retains a native-adapter allocation",
        )
        require("src/mtest/" not in record, f"{source.name} retains a product allocation")


def check_product_output(result: subprocess.CompletedProcess[str], source: Path) -> None:
    """Verify client completion, Memcheck findings, leaks, and fd hygiene."""
    expected = test_count(source)
    sentinel = f"{expected} tests run: {expected} passed"
    require(result.returncode == 0, f"{source.name} exited {result.returncode}:\n{result.stdout}")
    require(sentinel in result.stdout, f"{source.name} missed completion sentinel {sentinel!r}")
    require(
        "ERROR SUMMARY: 0 errors from 0 contexts" in result.stdout,
        f"{source.name} has Memcheck errors",
    )
    for kind in ("definitely lost", "indirectly lost", "possibly lost"):
        require(f"{kind}: 0 bytes in 0 blocks" in result.stdout, f"{source.name} has {kind} memory")
    require(
        "suppressed: 0 bytes in 0 blocks" in result.stdout,
        f"{source.name} unexpectedly used a suppression",
    )
    require(
        "FILE DESCRIPTORS: 3 open (3 inherited) at exit" in result.stdout,
        f"{source.name} has a nonstandard fd count",
    )
    require(
        "Open file descriptor" not in result.stdout,
        f"{source.name} leaked or misused a descriptor",
    )
    parse_reachable(result.stdout, source)


def check_postfork_output(result: subprocess.CompletedProcess[str], source: Path) -> None:
    """Reject invalid/undefined accesses from the unsilenced pre-exec child."""
    expected = test_count(source)
    sentinel = f"{expected} tests run: {expected} passed"
    require(
        result.returncode == 0,
        f"{source.name} post-fork audit exited {result.returncode}:\n{result.stdout}",
    )
    require(sentinel in result.stdout, f"{source.name} post-fork audit missed {sentinel!r}")
    summaries = [
        int(value.replace(",", ""))
        for value in re.findall(
            r"ERROR SUMMARY: ([0-9,]+) errors", result.stdout
        )
    ]
    require(summaries, f"{source.name} post-fork audit has no Memcheck summary")
    require(
        all(value == 0 for value in summaries),
        f"{source.name} post-fork audit reported errors: {summaries}",
    )


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
        binary: The CLI to run, here as Memcheck's client program.
        scratch: The probe's invocation root, already materialized.

    Returns:
        The complete argv, byte-identical to the ASan lane's.
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


def check_cli_provenance(returncode: int, log: str) -> None:
    """Require the probe's own log to prove it ran under Memcheck, cleanly.

    This is the assertion that separates "the instrumented run found nothing"
    from "the instrumented run never happened". An unwrapped client produces
    output that satisfies every artifact assertion in `check_cli_probe_output`
    while carrying none of the four markers checked here.

    Args:
        returncode: What the `valgrind` invocation returned.
        log: The probe's complete combined output.

    Raises:
        SystemExit: The log carries no Memcheck provenance, reports findings,
            shows an unexpected descriptor state, or the client exit is wrong.
    """
    require(
        CLI_MEMCHECK_BANNER in log,
        "CLI artifact probe log has no Memcheck banner "
        f"({CLI_MEMCHECK_BANNER!r}): the probe did not run under Valgrind",
    )
    require(
        CLI_ERROR_SUMMARY in log,
        f"CLI artifact probe log has no {CLI_ERROR_SUMMARY!r}: it either "
        "reported Memcheck errors or never ran under Valgrind",
    )
    require(
        CLI_FD_SUMMARY in log,
        f"CLI artifact probe log has no {CLI_FD_SUMMARY!r}: the expected "
        "descriptor summary is absent, so fd ownership is unproven",
    )
    require(
        returncode != CLI_MEMCHECK_EXIT,
        f"CLI artifact probe exited {CLI_MEMCHECK_EXIT} — Memcheck rejected "
        f"the run:\n{log}",
    )
    require(
        returncode == CLI_PROBE_EXIT,
        f"CLI artifact probe exited {returncode}, expected {CLI_PROBE_EXIT}",
    )
    for kind in ("definitely lost", "indirectly lost"):
        require(
            f"{kind}: 0 bytes in 0 blocks" in log,
            f"CLI artifact probe has {kind} memory",
        )
    require(
        "suppressed: 0 bytes in 0 blocks" in log,
        "CLI artifact probe unexpectedly used a suppression",
    )
    records = re.findall(
        r"(?ms)^==\d+== [0-9,]+ bytes in .*?(?:possibly lost|still reachable).*?"
        r"(?=^==\d+== (?:[0-9,]+ bytes|LEAK SUMMARY:))",
        log,
    )
    for record in records:
        require(
            "native/mtest_exec_native.c" not in record,
            "CLI artifact probe retains a native-adapter allocation",
        )
        require(
            "src/mtest/" not in record and "src/main.mojo" not in record,
            "CLI artifact probe retains a product allocation",
        )


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


def check_cli(env: dict[str, str]) -> None:
    """Source-build the real CLI and drive the fixed reporter run in Memcheck.

    Args:
        env: The Valgrind-clean environment.

    Raises:
        SystemExit: The build failed, the probe carries no Memcheck provenance,
            Memcheck reported a finding, or an artifact was rejected.
    """
    compiled = run(
        [
            "mojo",
            "build",
            "-g",
            "--target-cpu",
            VALGRIND_TARGET_CPU,
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
        env=env,
        timeout=900,
    )
    require(compiled.returncode == 0, f"CLI build failed:\n{compiled.stdout}")

    write_cli_probe_tree(CLI_SCRATCH)
    CLI_HOME.mkdir(parents=True, exist_ok=True)
    probe_env = dict(env)
    probe_env["HOME"] = str(CLI_HOME)
    result = valgrind(
        cli_probe_command(CLI_BINARY, CLI_SCRATCH),
        probe_env,
        quiet_child=True,
        flags=CLI_VALGRIND_FLAGS,
        cwd=CLI_SCRATCH,
    )
    (OUT / "cli-reporters.log").write_text(result.stdout)
    check_cli_provenance(result.returncode, result.stdout)
    detail = check_cli_probe_output(
        result.returncode, result.stdout, CLI_SCRATCH, "Valgrind"
    )
    print(f"valgrind-cli: {detail}")


def compile_and_run_test(source: Path, env: dict[str, str]) -> None:
    """Build one suite from product sources, then execute it directly in Memcheck."""
    binary = OUT / source.stem
    entrypoint = OUT / f"{source.stem}_main.mojo"
    aggregate.write_entrypoint(ROOT, entrypoint, [source])
    compiled = run(
        [
            "mojo",
            "build",
            "-g",
            "--target-cpu",
            VALGRIND_TARGET_CPU,
            "-I",
            ".",
            "-I",
            "src",
            "-I",
            "tests/support",
            str(entrypoint),
            "-o",
            str(binary),
            "-Xlinker",
            str(NATIVE_OBJECT),
        ],
        env=env,
    )
    require(compiled.returncode == 0, f"build failed for {source.name}:\n{compiled.stdout}")
    result = valgrind([str(binary)], env, quiet_child=True)
    (OUT / f"{source.stem}.log").write_text(result.stdout)
    check_product_output(result, source)
    postfork = valgrind(
        [str(binary)], env, quiet_child=False, flags=POSTFORK_FLAGS
    )
    (OUT / f"{source.stem}.postfork.log").write_text(postfork.stdout)
    check_postfork_output(postfork, source)
    expected = test_count(source)
    print(f"valgrind-test: {source.name}: {expected}/{expected} passed")


def main() -> int:
    """Run controls, the native suites, the real-CLI probe, then every suite."""
    require(bool(NATIVE_TESTS), "native source inventory is empty")
    require(bool(TESTS), "Mojo source inventory is empty")
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    prepare_test_scratch()
    env = clean_environment()
    version = run(["valgrind", "--version"], env=env)
    require(version.returncode == 0, f"cannot execute locked Valgrind:\n{version.stdout}")
    require(
        version.stdout.strip() == "valgrind-3.27.1",
        f"wrong Valgrind: {version.stdout.strip()}",
    )
    cc = native_abi_check.compiler()
    compile_inputs(cc, env)
    check_controls(env)
    check_native_tests(env)
    check_cli(env)
    for source in TESTS:
        compile_and_run_test(source, env)
    (OUT / "summary.log").write_text(
        "Memcheck controls: undefined, invalid, leak, fd, fork-child invalid detected\n"
        f"Native adapter suites: {len(NATIVE_TESTS)}/{len(NATIVE_TESTS)} passed\n"
        "Real-CLI reporter run: Memcheck provenance asserted, NDJSON + JUnit "
        "accepted by the strict oracles\n"
        f"Source-built Mojo suites: {len(TESTS)}/{len(TESTS)} passed\n"
        "Reviewed reachable baseline: "
        f"{EXPECTED_REACHABLE[0]} bytes in {EXPECTED_REACHABLE[1]} blocks\n"
        "Project/native reachable records: 0\n"
    )
    print(
        f"valgrind-check: OK -- {len(TESTS)} source-built suites "
        "+ 1 CLI reporter run"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
