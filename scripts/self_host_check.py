#!/usr/bin/env python3
"""The `test` gate: mtest dogfoods its own suite, checked for completeness.

Runs the real `build/mtest -I build tests/` binary (never `mojo run` — see
scripts/test_all.sh for why) over this repo's own tests/ directory, streaming
its output live and propagating its exit code: the suite must PASS *through
mtest itself* for this gate to pass.

That alone is not proof mtest saw every test file — a discovery bug could
silently drop one and still exit 0. So this script also runs an
MTEST-INDEPENDENT completeness check: it globs tests/test_*.mojo on disk
itself, with nothing but the stdlib, and fails loudly if that count disagrees
with the "selected: N files ... excluded: M files" count mtest's own header
reported. Together, selected + excluded must equal every test_*.mojo file this
script found on its own — proof mtest discovered (and accounted for) every
file in its own suite, not just a subset that happened to pass.

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


def discovered_test_files() -> list[str]:
    """Root-relative `tests/test_*.mojo` paths, found WITHOUT asking mtest.

    Walks tests/ directly with the stdlib only, matching the same basename
    pattern mtest's own discovery glob uses (`test_*.mojo`,
    src/mtest/discover/walk.mojo) recursively -- so a future subdirectory
    under tests/ stays covered. This function must never call mtest or read
    its output; it is the independent half of the completeness check.
    """
    found: list[str] = []
    for dirpath, _dirs, files in os.walk(TESTS_DIR):
        for name in files:
            if name.startswith("test_") and name.endswith(".mojo"):
                abs_path = os.path.join(dirpath, name)
                found.append(os.path.relpath(abs_path, REPO_ROOT))
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


def run_mtest_over_own_suite() -> tuple[int, str]:
    """Spawn `build/mtest -I build tests/`, streaming its combined output to
    this process's stdout live and also capturing it for the header parse.

    Runs in its own process group with the inherited environment, so `mojo`
    stays on PATH for the per-file build children mtest spawns -- the same
    contract scripts/e2e_check.py relies on. A hard wall-clock deadline kills
    the whole group on a hang rather than wedging the gate.

    Returns:
        The (exit_code, combined stdout+stderr) pair. `exit_code` is 1 (never
        mtest's own code) when the binary is missing or the run times out --
        both are this script's own failures, not a verdict from the suite.
    """
    if not os.path.exists(MTEST):
        print(
            f"FATAL: self_host_check: binary not found at {MTEST}; "
            f"run `pixi run build-bin`",
            file=sys.stderr,
        )
        return 1, ""

    argv = [MTEST, "-I", "build", "tests/"]
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


def main() -> int:
    code, output = run_mtest_over_own_suite()

    disk_files = discovered_test_files()
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
            f"tests/test_*.mojo (computed without mtest) found {disk_count}: "
            f"{disk_files}",
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
        f"self_host_check: OK -- mtest selected {selected} file(s) of its "
        f"own suite; an independent glob (computed without mtest) also found "
        f"{disk_count}; mtest exited 0"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
