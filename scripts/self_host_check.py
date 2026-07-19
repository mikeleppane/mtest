#!/usr/bin/env python3
"""The `test` gate: mtest dogfoods its own suite, checked for completeness.

Runs the real `build/mtest -I build -I tests/support tests/` binary (never
`mojo run` — see
scripts/test_all.sh for why) over this repo's own tests/ directory, streaming
its output live and propagating its exit code: the suite must PASS *through
mtest itself* for this gate to pass.

That alone is not proof mtest saw every test file — a discovery bug could
silently drop one and still exit 0. So this script also runs an
MTEST-INDEPENDENT completeness check: it recursively inventories the classified
suite roots with nothing but the stdlib, and fails loudly unless mtest's result
rows name that exact path set. The header count is checked independently too.

Console layout is an informal surface (see scripts/e2e_check.py's HEADER_RE),
so this parses the header line, not raw bytes.

Usage:  pixi run test        (depends on build-bin, so build/mtest exists first)
        python scripts/self_host_check.py
"""

from __future__ import annotations

import os
import re
import select
import signal
import subprocess
import sys
import time

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MTEST = os.path.join(REPO_ROOT, "build", "mtest")
NATIVE_OBJECT = os.path.join(
    REPO_ROOT, "build", "native", "mtest_exec_native_test.o"
)
TESTS_DIR = os.path.join(REPO_ROOT, "tests")

# The full 55-file suite runs several minutes serially (some files spawn their
# own nested `mojo build` children). This ceiling only guards against a
# genuine hang; it never times an individual file the way mtest's own
# `--timeout` does.
TIMEOUT_SECONDS = 900.0

# Mirrors e2e_check.py's HEADER_RE: the session-started header line is
# `root: <path>   selected: <N> files   excluded: <M> files`.
HEADER_RE = re.compile(
    r"root:\s+.*?selected:\s+(?P<selected>\d+)\s+files\s+excluded:\s+(?P<excluded>\d+)"
)
PASS_ROW_RE = re.compile(
    r"^PASS\s+(?P<path>tests/(?:unit|integration)/test_\S+\.mojo)\s",
    re.MULTILINE,
)


def discovered_test_files() -> list[str]:
    """Classified root-relative suite paths, found WITHOUT asking mtest.

    Walks tests/ directly with the stdlib only, matching the same basename
    pattern mtest's own discovery uses. Every suite must be directly under
    tests/unit or tests/integration; fixture/support/snapshot suites are a
    structural error. This function never calls mtest or reads its output.
    """
    found: list[str] = []
    for dirpath, _dirs, files in os.walk(TESTS_DIR):
        for name in files:
            if name.startswith("test_") and name.endswith(".mojo"):
                abs_path = os.path.join(dirpath, name)
                relative = os.path.relpath(abs_path, REPO_ROOT)
                parent = os.path.dirname(relative)
                if parent not in {"tests/unit", "tests/integration"}:
                    raise RuntimeError(
                        f"executable suite outside classified roots: {relative}"
                    )
                found.append(relative)
    return sorted(found)


def _kill_group(proc: subprocess.Popen) -> None:
    """Kill proc's whole process group so a hung mtest (and any `mojo build`
    children it spawned) can never wedge the gate."""
    try:
        pgid = os.getpgid(proc.pid)
    except ProcessLookupError:
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pgid, sig)
        except ProcessLookupError:
            return
        time.sleep(0.3)


def run_mtest_over_own_suite(
    mtest_path: str = MTEST, native_object: str = NATIVE_OBJECT
) -> tuple[int, str]:
    """Spawn mtest over tests/ with its support include, streaming output to
    this process's stdout live and also capturing it for the header parse.

    `mtest_path`/`native_object` default to this repo's own dev build
    (build/mtest + the test-variant native object) so `pixi run test` behaves
    exactly as before; scripts/package_check.py reuses this function with the
    INSTALLED package binary instead to dogfood the packaged artifact against
    the same suite.

    Runs in its own process group with the inherited environment, so `mojo`
    stays on PATH for the per-file build children mtest spawns -- the same
    contract scripts/e2e_check.py relies on. A hard wall-clock deadline kills
    the whole group on a hang rather than wedging the gate.

    Returns:
        The (exit_code, combined stdout+stderr) pair. `exit_code` is 1 (never
        mtest's own code) when the binary is missing or the run times out --
        both are this script's own failures, not a verdict from the suite.
    """
    if not os.path.exists(mtest_path):
        print(
            f"FATAL: self_host_check: binary not found at {mtest_path}; "
            f"run `pixi run build-bin`",
            file=sys.stderr,
        )
        return 1, ""

    argv = [
        mtest_path,
        "-I",
        "build",
        "-I",
        "tests/support",
        "--build-arg=-Xlinker",
        f"--build-arg={native_object}",
        "tests/",
    ]
    proc = subprocess.Popen(
        argv,
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    assert proc.stdout is not None  # guaranteed by stdout=PIPE above

    chunks: list[str] = []
    deadline = time.monotonic() + TIMEOUT_SECONDS
    timed_out = False
    fd = proc.stdout.fileno()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            timed_out = True
            break
        ready, _, _ = select.select([fd], [], [], remaining)
        if not ready:
            continue
        text = os.read(fd, 4096).decode("utf-8", errors="replace")
        if not text:
            break  # EOF: the child closed its end
        sys.stdout.write(text)
        sys.stdout.flush()
        chunks.append(text)

    if timed_out:
        _kill_group(proc)
        proc.wait(timeout=5)
        print(
            f"FATAL: self_host_check: `{' '.join(argv)}` did not finish "
            f"within {TIMEOUT_SECONDS:.0f}s -- killed its process group "
            f"(possible runner hang)",
            file=sys.stderr,
        )
        return 1, "".join(chunks)

    returncode = proc.wait(timeout=5)
    return returncode, "".join(chunks)


def verify(mtest_path: str = MTEST, native_object: str = NATIVE_OBJECT) -> int:
    """Run mtest over its own suite and check the result for completeness.

    Parameterized so scripts/package_check.py can reuse this exact dogfood +
    completeness gate against the INSTALLED package binary; `pixi run test`
    (via `main` below) calls it with this repo's own dev build.
    """
    code, output = run_mtest_over_own_suite(mtest_path, native_object)

    try:
        disk_files = discovered_test_files()
    except RuntimeError as exc:
        print(f"FATAL: self_host_check: {exc}", file=sys.stderr)
        return 1
    disk_count = len(disk_files)

    match = HEADER_RE.search(output)
    if match is None:
        print(
            "FATAL: self_host_check: no 'selected: N files ... excluded: M "
            "files' header found in mtest's output -- cannot verify "
            "completeness",
            file=sys.stderr,
        )
        return 1
    selected = int(match.group("selected"))
    excluded = int(match.group("excluded"))
    accounted_for = selected + excluded
    reported_files = sorted(set(PASS_ROW_RE.findall(output)))

    ok = True

    if code != 0:
        print(
            f"FATAL: self_host_check: mtest exited {code} running its own "
            f"suite (must be 0 -- the suite must PASS through mtest itself)",
            file=sys.stderr,
        )
        ok = False

    if accounted_for != disk_count:
        print(
            f"FATAL: self_host_check: completeness mismatch -- mtest "
            f"reported selected={selected} + excluded={excluded} = "
            f"{accounted_for} test file(s), but an independent glob of "
            f"the classified suite roots (computed without mtest) found {disk_count}: "
            f"{disk_files}",
            file=sys.stderr,
        )
        ok = False
    elif reported_files != disk_files:
        print(
            "FATAL: self_host_check: exact path membership mismatch -- "
            f"mtest PASS rows named {reported_files}, but the independent "
            f"classified inventory is {disk_files}",
            file=sys.stderr,
        )
        ok = False
    elif excluded != 0:
        # `pixi run test` never passes --exclude, so any nonzero excluded
        # count here is itself a surprise worth naming loudly, even though
        # the completeness arithmetic above still balances.
        print(
            f"WARNING: self_host_check: {excluded} file(s) excluded on an "
            f"unconfigured run of mtest over its own suite",
            file=sys.stderr,
        )

    if not ok:
        return 1

    print(
        f"self_host_check: OK -- mtest ({mtest_path}) selected {selected} "
        f"file(s) of its own suite; its exact PASS-row path set matches all "
        f"{disk_count} independently inventoried classified suites; mtest "
        f"exited 0"
    )
    return 0


def main() -> int:
    return verify(MTEST, NATIVE_OBJECT)


if __name__ == "__main__":
    sys.exit(main())
