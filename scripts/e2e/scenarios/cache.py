"""Build-artifact cache E2E scenarios.

The cache is the one feature whose whole claim is about the SECOND invocation,
so it can only be settled by two real processes over one tree. Every other gate
in this repository either drives the store directly from inside one process
(the Mojo suites) or drives the publication protocol with the store as its
subject (`scripts/tests/test_cache_protocol.py`). What neither can show is the
thing a user is promised: run the suite, run it again, and get the same verdicts
for none of the compile cost.

These scenarios run in a throwaway project of their own, never the repository
root. The store lives under the invocation root, so a scenario that ran here
would inherit whatever warmth the previous gate left behind and could never
observe a cold run at all.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import tempfile

from scripts.e2e.assertions import Summary, expect, expect_exit, summary
from scripts.e2e.runner import E2ERunner, Run, ScenarioContext


ACCOUNTING_RE = re.compile(r"builds:\s+(?P<built>\d+),\s+cached:\s+(?P<cached>\d+)")
"""The console summary band's build-cache pair, `builds: N, cached: M`."""

PASSING_SUITE = """\
from std.testing import TestSuite, assert_true


def test_first() raises:
    assert_true(True)


def test_second() raises:
    assert_true(True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
"""

MIXED_SUITE = """\
from std.testing import TestSuite, assert_equal, assert_true


def test_third() raises:
    assert_true(True)


def test_disagrees() raises:
    assert_equal(1, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
"""

TREE = {
    "tests/test_alpha.mojo": PASSING_SUITE,
    "tests/test_beta.mojo": MIXED_SUITE,
}
"""A two-file project with a failing test in it.

The failure is load-bearing. A cache that served a stale or foreign binary would
most plausibly show up as a run whose verdicts moved, and an all-passing tree has
only one verdict to move away from; a tree that must report exactly one failing
test both times pins the counts in both directions.

Nothing here imports anything but the standard library, so the project needs no
`-I` and no precompile step. That is deliberate: `mojo precompile` is not
byte-deterministic, so a step that re-ran between the two invocations would
rewrite its package, move the key every file derives from, and cost the warm run
every hit through no fault of the store.
"""


def _accounting(run: Run) -> tuple[int, int]:
    """The `builds:`/`cached:` pair from one run's console summary band.

    Args:
        run: A completed run whose console output carries a summary band.

    Returns:
        The built and cached file counts the band reported.

    Raises:
        ScenarioError: If the band carries no build-cache pair, which is what a
            run that admitted nothing at all renders.
    """
    match = ACCOUNTING_RE.search(run.combined)
    expect(
        match is not None,
        f"the summary band carries no builds/cached pair for {run.argv}\n"
        f"{run.combined}",
    )
    assert match is not None  # noqa: S101 - narrowing for the type checker
    return int(match.group("built")), int(match.group("cached"))


def _counters(stream: Path) -> tuple[int, int]:
    """The `session_finished` build-cache counters from one `--json` stream.

    Args:
        stream: The file the run was pointed at with `--json`.

    Returns:
        The `built_files` and `cached_files` the terminal event reported.

    Raises:
        ScenarioError: If the stream holds no terminal event, which means the
            run died before accounting for itself.
    """
    for line in stream.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        if record.get("event") == "session_finished":
            return int(record["built_files"]), int(record["cached_files"])
    raise AssertionError(f"no session_finished record in {stream}")


def _verdicts(run: Run) -> Summary:
    """One run's parsed summary band."""
    return summary(run)


def s_cache_cold_then_warm(context: ScenarioContext) -> str:
    """A rerun over an untouched tree compiles nothing and reports the same.

    The product claim, end to end through the real binary: the second invocation
    of an unchanged suite reaches the compiler zero times, and every verdict it
    reports is the one the first invocation reported. The two halves have to be
    asserted together — a run that skipped the compiler AND changed a verdict
    would be the cache's worst failure mode, and a run that reproduced the
    verdicts by rebuilding everything would be the feature not working at all.
    """
    with tempfile.TemporaryDirectory(prefix="mtest-cache-warm-") as raw:
        project = Path(raw)
        for rel, source in TREE.items():
            path = project / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
        runner = E2ERunner(
            repo_root=project,
            mtest=context.runner.mtest,
            default_timeout=context.runner.default_timeout,
            short_timeout=context.runner.short_timeout,
        )
        expect(
            not (project / ".mtest-cache").exists(),
            "the scratch project was not cold before the first run",
        )

        cold_stream = project / "cold.ndjson"
        cold = runner.run_mtest(["--json", os.fspath(cold_stream), "tests"])
        # One failing test, so both runs are exit 1; a green pair would leave the
        # exit code free to be produced by anything.
        expect_exit(cold, 1)
        expect(
            _accounting(cold) == (2, 0),
            f"the cold run was not cold: {_accounting(cold)}",
        )
        expect(
            _counters(cold_stream) == (2, 0),
            f"the cold stream disagrees with its band: {_counters(cold_stream)}",
        )

        warm_stream = project / "warm.ndjson"
        warm = runner.run_mtest(["--json", os.fspath(warm_stream), "tests"])
        expect_exit(warm, 1)

        # The console band names what was served, so a user can see the cache
        # working without reading a machine stream.
        built, cached = _accounting(warm)
        expect(built == 0, f"the warm run still compiled {built} file(s)")
        expect(cached == 2, f"the warm run served {cached} file(s), not 2")
        # The same fact from the frozen event stream, which is what CI reads.
        expect(
            _counters(warm_stream) == (0, 2),
            f"the warm stream disagrees with its band: {_counters(warm_stream)}",
        )

        # And the verdicts did not move. Timing and the accounting pair are the
        # only things a warm run is allowed to change.
        cold_summary = _verdicts(cold)
        warm_summary = _verdicts(warm)
        for field in (
            "passed",
            "failed",
            "skipped",
            "crashed",
            "timed_out",
            "compile_error",
            "malformed",
            "excluded",
            "not_run",
            "deselected",
        ):
            expect(
                getattr(cold_summary, field) == getattr(warm_summary, field),
                f"the warm run's {field} count moved: "
                f"{getattr(cold_summary, field)} -> {getattr(warm_summary, field)}",
            )
        expect(
            (cold_summary.passed, cold_summary.failed) == (3, 1),
            f"the fixture no longer reports 3 passed / 1 failed: {cold_summary}",
        )
    return "warm rerun: builds 0, cached 2, verdicts identical to the cold run"
