#!/usr/bin/env python3
"""Measure how the mtest parallel scheduler scales with the worker count.

This is a MAINTENANCE tool, not a gate. It answers one empirical question: where
does the `auto` worker count sit relative to the measured sweet spot on a real
machine? It drives the already-built ``build/mtest`` binary against a freshly
generated tree of medium-weight, all-pass ``test_*.mojo`` files and times it
across a small matrix, reporting the median wall-clock per cell and the speedup
against the ``-n 1`` sequential baseline.

The matrix is workers x tokens x {cold, warm}, three reps each:

- ``workers`` walks ``{1, 2, 4, cores}`` (``cores = os.cpu_count()``), so the
  measured curve brackets the provisional ``auto`` ceiling of four and shows the
  diminishing- or negative-return shape past it.
- ``tokens`` has two modes. ``on`` is the real runner default: one
  ``mtest -n W`` process whose concurrent builds share the cores-wide
  ``--num-threads`` token budget. ``off`` is a bench-side control that needs NO
  production change -- ``W`` concurrent ``mtest -n 1`` processes over disjoint
  file slices, each build spawned at the compiler's default (unbudgeted) thread
  count. The pair isolates what the token budget buys: same file-level
  parallelism, with and without the per-build thread clamp. At one worker the two
  modes are the same single ``mtest -n 1`` process, so ``off`` is only measured
  for ``W > 1``.
- ``cold`` gives every rep a fresh ``MODULAR_CACHE_DIR`` so each build compiles
  from scratch (the realistic first-CI-run cost that dominates sizing); ``warm``
  reuses a pre-warmed cache so the cell measures scheduling overhead, not the
  compiler.

The runner resolves operands against its invocation root, so each timed run is
spawned with its working directory set to the synthetic tree and a relative
operand. ``mojo`` must be on PATH for the spawned ``mojo build`` children, so run
this under ``pixi run`` (``pixi run bench-workers``). Timings are machine- and
load-specific by nature; the table's shape is fixed, its numbers are not.
"""

from __future__ import annotations

import argparse
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MTEST = REPO_ROOT / "build" / "mtest"

# A generous per-run guard. A cold sequential build of the whole tree is the
# slowest cell; this bounds a wedged run without capping a legitimately slow one.
RUN_TIMEOUT = 900.0


def _test_file_source(index: int) -> str:
    """Return the source of one medium-weight, all-pass synthetic test file.

    A few imports and several ``def test_*`` functions with a modest amount of
    compile-time surface (loops, comparisons) so each file's ``mojo build`` costs
    enough that parallelism across files is measurable, kept trivially all-pass
    so the run never fails.
    """
    return f'''"""Synthetic worker-sizing bench file {index} (all-pass)."""
from std.testing import assert_equal, assert_false, assert_true, TestSuite


def test_accumulate_{index}() raises:
    var acc = 0
    for k in range(256):
        acc += k * {index}
    assert_true(acc >= 0)


def test_alternating_{index}() raises:
    var flag = True
    for _ in range(64):
        flag = not flag
    assert_false(flag)


def test_identity_{index}() raises:
    assert_equal({index}, {index})


def test_running_sum_{index}() raises:
    var total = 0
    for k in range(1, 65):
        total += k
    assert_equal(total, 2080)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
'''


def generate_tree(root: Path, file_count: int) -> list[str]:
    """Write ``file_count`` synthetic ``test_*.mojo`` files into ``root``.

    Returns the relative file names in a stable order, so the caller can slice
    them deterministically across the ``tokens=off`` worker processes.
    """
    names: list[str] = []
    for index in range(1, file_count + 1):
        name = f"test_bench_{index:02d}.mojo"
        (root / name).write_text(_test_file_source(index), encoding="utf-8")
        names.append(name)
    return names


def _slice_evenly(names: list[str], parts: int) -> list[list[str]]:
    """Split ``names`` into ``parts`` contiguous, near-equal, non-empty slices."""
    parts = max(1, min(parts, len(names)))
    per, extra = divmod(len(names), parts)
    slices: list[list[str]] = []
    start = 0
    for i in range(parts):
        size = per + (1 if i < extra else 0)
        slices.append(names[start : start + size])
        start += size
    return [s for s in slices if s]


def _spawn(argv: list[str], cwd: Path, cache_dir: Path) -> subprocess.Popen:
    """Spawn one mtest process with a quarantined cache and mojo on PATH."""
    env = dict(os.environ)
    env["MODULAR_CACHE_DIR"] = str(cache_dir)
    env["GITHUB_ACTIONS"] = ""
    return subprocess.Popen(
        argv,
        cwd=str(cwd),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
        start_new_session=True,
    )


def _await(procs: list[subprocess.Popen]) -> None:
    """Wait for every process under one deadline; kill the group on overrun."""
    deadline = time.monotonic() + RUN_TIMEOUT
    for proc in procs:
        remaining = deadline - time.monotonic()
        try:
            proc.wait(timeout=max(0.0, remaining))
        except subprocess.TimeoutExpired:
            for other in procs:
                if other.poll() is None:
                    try:
                        os.killpg(os.getpgid(other.pid), 9)
                    except ProcessLookupError:
                        pass
            raise SystemExit(
                f"bench-workers: a run exceeded {RUN_TIMEOUT:.0f}s; aborting"
            )


def run_once(
    tree: Path,
    names: list[str],
    workers: int,
    tokens: str,
    cache_root: Path,
) -> float:
    """Time one configuration end to end and return the wall-clock seconds.

    ``tokens == "on"`` is a single budgeted ``mtest -n workers`` process over the
    whole tree. ``tokens == "off"`` is ``workers`` concurrent ``mtest -n 1``
    processes over disjoint slices, each with its own quarantined cache, timed as
    the span from the first spawn to the last exit.
    """
    if tokens == "on" or workers == 1:
        cache = cache_root / "on"
        cache.mkdir(parents=True, exist_ok=True)
        start = time.monotonic()
        proc = _spawn([str(MTEST), "-n", str(workers), "."], tree, cache)
        _await([proc])
        return time.monotonic() - start
    slices = _slice_evenly(names, workers)
    start = time.monotonic()
    procs: list[subprocess.Popen] = []
    for i, slice_names in enumerate(slices):
        cache = cache_root / f"off-{i}"
        cache.mkdir(parents=True, exist_ok=True)
        procs.append(
            _spawn([str(MTEST), "-n", "1", *slice_names], tree, cache)
        )
    _await(procs)
    return time.monotonic() - start


@dataclass
class Cell:
    """One measured matrix cell: its keys and the median of its reps."""

    workers: int
    tokens: str
    temp: str
    median_seconds: float


def measure_cell(
    tree: Path,
    names: list[str],
    workers: int,
    tokens: str,
    temp: str,
    reps: int,
) -> Cell:
    """Run one cell ``reps`` times and return its median wall-clock.

    ``warm`` warms a shared cache once (untimed) and reuses it across the reps;
    ``cold`` gives every rep a fresh cache root so each build starts from empty.
    """
    samples: list[float] = []
    with tempfile.TemporaryDirectory(prefix="mtest-bench-cache-") as warm_root:
        if temp == "warm":
            run_once(tree, names, workers, tokens, Path(warm_root))
        for _ in range(reps):
            if temp == "warm":
                samples.append(
                    run_once(tree, names, workers, tokens, Path(warm_root))
                )
                continue
            cold_dir = tempfile.mkdtemp(prefix="mtest-bench-cold-")
            try:
                samples.append(
                    run_once(tree, names, workers, tokens, Path(cold_dir))
                )
            finally:
                shutil.rmtree(cold_dir, ignore_errors=True)
    return Cell(workers, tokens, temp, statistics.median(samples))


def worker_ladder(cores: int) -> list[int]:
    """Return the sorted, de-duplicated worker counts ``{1, 2, 4, cores}``."""
    return sorted({1, 2, 4, max(1, cores)})


def format_table(cells: list[Cell], cores: int, files: int, reps: int) -> str:
    """Render the measured cells as a fixed-shape, stdlib-only text table."""
    baseline: dict[str, float] = {}
    for cell in cells:
        if cell.workers == 1:
            baseline[cell.temp] = cell.median_seconds
    lines = [
        "mtest worker-sizing benchmark",
        f"machine: {cores} logical cores | tree: {files} files | "
        f"reps: {reps} (median reported)",
        "",
        f"{'workers':>7}  {'tokens':<6}  {'temp':<4}  "
        f"{'median_s':>9}  {'speedup_vs_-n1':>14}",
    ]
    for cell in cells:
        base = baseline.get(cell.temp)
        speedup = (
            f"{base / cell.median_seconds:.2f}x"
            if base and cell.median_seconds > 0
            else "n/a"
        )
        lines.append(
            f"{cell.workers:>7}  {cell.tokens:<6}  {cell.temp:<4}  "
            f"{cell.median_seconds:>9.2f}  {speedup:>14}"
        )
    return "\n".join(lines)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse the tree-size, rep-count, and worker-ladder overrides."""
    parser = argparse.ArgumentParser(
        prog="bench-workers",
        description="Measure mtest scheduler scaling vs the auto worker count.",
    )
    parser.add_argument(
        "--files",
        type=int,
        default=16,
        help="synthetic test files in the tree (default 16)",
    )
    parser.add_argument(
        "--reps",
        type=int,
        default=3,
        help="reps per cell; the median is reported (default 3)",
    )
    parser.add_argument(
        "--workers",
        type=str,
        default="",
        help=(
            "comma-separated worker counts to override the default "
            "{1,2,4,cores} ladder"
        ),
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """Generate the tree, run the matrix, and print the measured table."""
    args = parse_args(argv)
    if not MTEST.is_file():
        print(
            f"bench-workers: missing {MTEST}; run `pixi run build-bin` first",
            file=sys.stderr,
        )
        return 1
    cores = os.cpu_count() or 1
    if args.workers.strip():
        ladder = sorted({max(1, int(w)) for w in args.workers.split(",")})
    else:
        ladder = worker_ladder(cores)

    with tempfile.TemporaryDirectory(prefix="mtest-bench-tree-") as tree_str:
        tree = Path(tree_str)
        names = generate_tree(tree, args.files)
        cells: list[Cell] = []
        for temp in ("cold", "warm"):
            for workers in ladder:
                token_modes = ["on"] if workers == 1 else ["on", "off"]
                for tokens in token_modes:
                    cell = measure_cell(
                        tree, names, workers, tokens, temp, args.reps
                    )
                    cells.append(cell)
                    print(
                        f"bench-workers: measured n={workers} tokens={tokens} "
                        f"{temp} -> {cell.median_seconds:.2f}s",
                        file=sys.stderr,
                    )
    print(format_table(cells, cores, args.files, args.reps))
    return 0


if __name__ == "__main__":
    sys.exit(main())
