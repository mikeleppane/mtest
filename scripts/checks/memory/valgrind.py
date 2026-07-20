#!/usr/bin/env python3
"""Run source-built exec suites under the locked Valgrind Memcheck tool."""

from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

from scripts import aggregate_tests
from scripts.checks import native_abi as native_abi_check


ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "build" / "safety" / "valgrind"
TEST_SCRATCH = ROOT / "build" / "tests"
NATIVE_SOURCE = ROOT / "native" / "mtest_exec_native.c"
NATIVE_OBJECT = OUT / "mtest_exec_native_test.o"
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
TESTS = tuple(sorted(EXEC_TEST_ROOT.glob("test_exec_*.mojo"))) + (CONFIG_TEST,)
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
EXPECTED_REACHABLE = (78_596, 10)
VALGRIND_TARGET_CPU = "x86-64-v3"


def run(
    command: list[str],
    *,
    env: dict[str, str],
    timeout: int = 300,
) -> subprocess.CompletedProcess[str]:
    """Run one command with only standard streams inherited by the client."""
    return subprocess.run(
        command,
        cwd=ROOT,
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
    """Build the adapter and native negative-control executable with debug info."""
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
    result = run(["valgrind", *selected_flags, *command], env=env)
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


def compile_and_run_test(source: Path, env: dict[str, str]) -> None:
    """Build one suite from product sources, then execute it directly in Memcheck."""
    binary = OUT / source.stem
    entrypoint = OUT / f"{source.stem}_main.mojo"
    aggregate_tests.write_entrypoint(ROOT, entrypoint, [source])
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
    """Run negative controls, then every exec suite and lossy-UTF8 coverage."""
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
    for source in TESTS:
        compile_and_run_test(source, env)
    (OUT / "summary.log").write_text(
        "Memcheck controls: undefined, invalid, leak, fd, fork-child invalid detected\n"
        f"Native adapter suites: {len(NATIVE_TESTS)}/{len(NATIVE_TESTS)} passed\n"
        f"Source-built Mojo suites: {len(TESTS)}/{len(TESTS)} passed\n"
        "Reviewed reachable baseline: "
        f"{EXPECTED_REACHABLE[0]} bytes in {EXPECTED_REACHABLE[1]} blocks\n"
        "Project/native reachable records: 0\n"
    )
    print(f"valgrind-check: OK -- {len(TESTS)} source-built suites")
    return 0


if __name__ == "__main__":
    sys.exit(main())
