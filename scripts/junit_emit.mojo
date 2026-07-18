"""Emit mtest's real JUnit document for the schema/arithmetic oracle gate.

Not a product module and not a test suite: a thin CLI tool the
`scripts/junit_render_check.py` gate builds and runs. It drives the REAL
`JunitReporter` over a typed event stream that exercises every sentinel-matrix
cell (a non-retried file-level failure, a rerun-exhausted failure, a flaky pass,
a retried per-test failure, non-retried per-test outcomes, a not-run file, a
precompile failure with named casualties, and suite-level capture), spools the
per-suite fragments, assembles the whole `<testsuites>` document, and prints it
to stdout. The gate then runs `scripts/junit_check.py` over that output — so the
oracle validates the shipped renderer's OWN bytes, not a hand-authored mock.
"""
from std.tempfile import mkdtemp

from mtest.model.events import Event
from mtest.model.node_id import NodeId
from mtest.model.outcome import Outcome
from mtest.model.test_result import TestResult
from mtest.report.junit_reporter import JunitReporter


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _attempt(path: String, idx: Int) -> Event:
    return Event.attempt_finished(
        path,
        "run",
        idx,
        3,
        1,  # SIGNALED
        11,
        1,
        11,
        False,
        True,
        "signal",
        0.1,
        _bytes("attempt " + String(idx) + " stdout"),
        _bytes("attempt " + String(idx) + " stderr"),
        False,
        False,
        List[String](),
    )


def _finished(
    path: String,
    outcome: Outcome,
    var stdout: List[UInt8],
    var stderr: List[UInt8],
    signal_number: Int = 0,
    exit_status: Int = 0,
    attempts_used: Int = 1,
    flaky: Bool = False,
) -> Event:
    return Event.file_finished(
        path,
        outcome,
        0.123,
        List[String](),
        0.0,
        stdout^,
        stderr^,
        signal_number=signal_number,
        exit_status=exit_status,
        attempts_used=attempts_used,
        flaky=flaky,
    )


def main() raises:
    var rep = JunitReporter(mkdtemp(), True)

    # Cell 1: non-retried file-level failure -> [build].
    rep.handle(Event.file_started("e2e/c1_build.mojo"))
    rep.handle(
        _finished(
            "e2e/c1_build.mojo",
            Outcome.CRASH,
            _bytes('run stdout <hostile> & "quotes"'),
            _bytes("segfault"),
            signal_number=11,
        )
    )

    # Cell 2: rerun-exhausted file-level failure -> [attempts], first primary.
    rep.handle(Event.file_started("e2e/c2_attempts.mojo"))
    rep.handle(_attempt("e2e/c2_attempts.mojo", 1))
    rep.handle(_attempt("e2e/c2_attempts.mojo", 2))
    rep.handle(
        _finished(
            "e2e/c2_attempts.mojo",
            Outcome.CRASH,
            _bytes(""),
            _bytes("segfault"),
            signal_number=11,
            attempts_used=3,
        )
    )

    # Cell 3: retried final pass (flaky) -> [attempts] flakyFailure children.
    rep.handle(Event.file_started("e2e/c3_flaky.mojo"))
    rep.handle(
        Event.test_reported(
            TestResult(
                NodeId("e2e/c3_flaky.mojo", "test_recovered"), Outcome.PASS
            )
        )
    )
    rep.handle(_attempt("e2e/c3_flaky.mojo", 1))
    rep.handle(_attempt("e2e/c3_flaky.mojo", 2))
    rep.handle(
        _finished(
            "e2e/c3_flaky.mojo",
            Outcome.FLAKY,
            _bytes(""),
            _bytes(""),
            attempts_used=3,
            flaky=True,
        )
    )

    # Cell 4: retried per-test failure -> per-test primary + [attempts] rerun.
    rep.handle(Event.file_started("e2e/c4_pertest.mojo"))
    rep.handle(_attempt("e2e/c4_pertest.mojo", 1))
    rep.handle(
        Event.test_reported(
            TestResult(
                NodeId("e2e/c4_pertest.mojo", "test_fails"),
                Outcome.FAIL,
                "`left == right` failed: 1 != 2",
                "",
            )
        )
    )
    rep.handle(
        _finished(
            "e2e/c4_pertest.mojo",
            Outcome.FAIL,
            _bytes(""),
            _bytes(""),
            exit_status=1,
            attempts_used=2,
        )
    )

    # Cell 5: non-retried per-test outcomes -> no sentinel; also a skip row.
    rep.handle(Event.file_started("e2e/c5_plain.mojo"))
    rep.handle(
        Event.test_reported(
            TestResult(NodeId("e2e/c5_plain.mojo", "test_ok"), Outcome.PASS)
        )
    )
    rep.handle(
        Event.test_reported(
            TestResult(
                NodeId("e2e/c5_plain.mojo", "test_skipped"), Outcome.SKIP
            )
        )
    )
    rep.handle(
        Event.test_reported(
            TestResult(
                NodeId("e2e/c5_plain.mojo", "test_bad"),
                Outcome.FAIL,
                "assertion failed",
                "",
            )
        )
    )
    rep.handle(
        _finished(
            "e2e/c5_plain.mojo",
            Outcome.FAIL,
            _bytes("captured <output>"),
            _bytes(""),
            exit_status=1,
        )
    )

    # Cell 6 (via truncation): a not-run file gets its own [not-run] suite.
    rep.handle(
        _finished("e2e/c6_notrun.mojo", Outcome.NOT_RUN, _bytes(""), _bytes(""))
    )

    # Precompile failure: mtest::precompile suite + per-casualty [not-run] rows.
    var casualties = List[String]()
    casualties.append("e2e/dep_one.mojo")
    casualties.append("e2e/dep_two.mojo")
    rep.handle(
        Event.precompile_failed(
            "build", "error: undefined symbol <foo>", 0, casualties^
        )
    )

    print(rep.assemble("mtest"))
