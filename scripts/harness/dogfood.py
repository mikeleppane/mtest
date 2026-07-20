#!/usr/bin/env python3
"""Run focused self-host probes through mtest and verify exact membership.

The exhaustive unit/integration inventory is compiled once by
``scripts/harness/classified.py``. This independent dogfood gate instead sends three
small executable probes through the real ``build/mtest`` binary. That keeps
coverage of mtest's discover/build/run/parse/report path without asking mtest
to compile the exhaustive suite one source file at a time.

Usage:  pixi run test
        python -m scripts.harness.dogfood
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import time


REPO_ROOT_PATH = Path(__file__).resolve().parents[2]
REPO_ROOT = str(REPO_ROOT_PATH)
MTEST = str(REPO_ROOT_PATH / "build" / "mtest")
NATIVE_OBJECT = str(
    REPO_ROOT_PATH / "build" / "native" / "mtest_exec_native_test.o"
)
DOGFOOD_TEST_FILES = (
    "tests/dogfood/exec_probe.mojo",
    "tests/dogfood/model_probe.mojo",
    "tests/dogfood/session_probe.mojo",
)

# Three small probes should finish comfortably inside this ceiling. It remains
# deliberately generous because the hosted package lane may have a cold Mojo
# compiler cache; the limit exists only to prevent a genuine runner hang.
TIMEOUT_SECONDS = 300.0

# Mirrors e2e_check.py's HEADER_RE: the session-started header line is
# `root: <path>   selected: <N> files   excluded: <M> files`.
HEADER_RE = re.compile(
    r"root:\s+.*?selected:\s+(?P<selected>\d+)\s+files\s+excluded:\s+(?P<excluded>\d+)"
)
PASS_ROW_RE = re.compile(
    r"^PASS\s+(?P<path>tests/dogfood/[^\s]+\.mojo)\s",
    re.MULTILINE,
)


def dogfood_test_files(repo_root: Path = REPO_ROOT_PATH) -> list[str]:
    """Return the exact declared dogfood inventory, independently of mtest."""
    dogfood_dir = repo_root / "tests" / "dogfood"
    actual = {
        str(path.relative_to(repo_root))
        for path in dogfood_dir.glob("*.mojo")
    }
    expected = set(DOGFOOD_TEST_FILES)
    if actual != expected:
        raise RuntimeError(
            "dogfood inventory mismatch: "
            f"missing={sorted(expected - actual)}, extra={sorted(actual - expected)}"
        )
    for relative in DOGFOOD_TEST_FILES:
        path = repo_root / relative
        if not path.is_file() or path.is_symlink():
            raise RuntimeError(f"dogfood probe is not a real file: {relative}")
    return list(DOGFOOD_TEST_FILES)


def _kill_group(proc: subprocess.Popen[str]) -> None:
    """Kill proc's process group, including any compiler children."""
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


def _mtest_argv(mtest_path: str, native_object: str) -> list[str]:
    """Build the self-host command with every dogfood probe named explicitly."""
    return [
        mtest_path,
        "-I",
        "build",
        "-I",
        "tests/support",
        "--build-arg=-Xlinker",
        f"--build-arg={native_object}",
        *DOGFOOD_TEST_FILES,
    ]


def run_mtest_over_own_suite(
    mtest_path: str = MTEST,
    native_object: str = NATIVE_OBJECT,
) -> tuple[int, str]:
    """Run focused probes through mtest, streaming and capturing its output."""
    if not os.path.exists(mtest_path):
        print(
            f"FATAL: dogfood: binary not found at {mtest_path}; "
            "run `pixi run build-bin`",
            file=sys.stderr,
        )
        return 1, ""

    argv = _mtest_argv(mtest_path, native_object)
    proc = subprocess.Popen(
        argv,
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    assert proc.stdout is not None

    chunks: list[str] = []
    deadline = time.monotonic() + TIMEOUT_SECONDS
    fd = proc.stdout.fileno()
    stream_open = True
    while proc.poll() is None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            _kill_group(proc)
            proc.wait(timeout=5)
            print(
                f"FATAL: dogfood: `{' '.join(argv)}` did not finish "
                f"within {TIMEOUT_SECONDS:.0f}s -- killed its process group "
                "(possible runner hang)",
                file=sys.stderr,
            )
            return 1, "".join(chunks)
        if not stream_open:
            time.sleep(min(0.05, remaining))
            continue
        ready, _, _ = select.select([fd], [], [], min(remaining, 0.25))
        if not ready:
            continue
        text = os.read(fd, 4096).decode("utf-8", errors="replace")
        if not text:
            stream_open = False
            continue
        sys.stdout.write(text)
        sys.stdout.flush()
        chunks.append(text)

    if stream_open:
        tail = proc.stdout.read()
        if tail:
            sys.stdout.write(tail)
            sys.stdout.flush()
            chunks.append(tail)
    return proc.wait(timeout=5), "".join(chunks)


def verify(
    mtest_path: str = MTEST,
    native_object: str = NATIVE_OBJECT,
) -> int:
    """Run the focused dogfood probes and verify exact result membership."""
    try:
        disk_files = dogfood_test_files()
    except RuntimeError as exc:
        print(f"FATAL: dogfood: {exc}", file=sys.stderr)
        return 1

    code, output = run_mtest_over_own_suite(mtest_path, native_object)
    match = HEADER_RE.search(output)
    if match is None:
        print(
            "FATAL: dogfood: no 'selected: N files ... excluded: M "
            "files' header found in mtest's output -- cannot verify completeness",
            file=sys.stderr,
        )
        return 1

    selected = int(match.group("selected"))
    excluded = int(match.group("excluded"))
    reported_files = sorted(set(PASS_ROW_RE.findall(output)))
    ok = True
    if code != 0:
        print(
            f"FATAL: dogfood: mtest exited {code} running focused "
            "dogfood probes (must be 0)",
            file=sys.stderr,
        )
        ok = False
    if selected != len(disk_files) or excluded != 0:
        print(
            "FATAL: dogfood: completeness mismatch -- "
            f"selected={selected}, excluded={excluded}, "
            f"declared probes={disk_files}",
            file=sys.stderr,
        )
        ok = False
    if reported_files != disk_files:
        print(
            "FATAL: dogfood: exact path membership mismatch -- "
            f"mtest PASS rows named {reported_files}, declared probes are {disk_files}",
            file=sys.stderr,
        )
        ok = False
    if not ok:
        return 1

    print(
        f"dogfood: OK -- mtest ({mtest_path}) selected and passed "
        f"all {len(disk_files)} focused dogfood probes; exact paths match"
    )
    return 0


def main() -> int:
    return verify(MTEST, NATIVE_OBJECT)


if __name__ == "__main__":
    sys.exit(main())
