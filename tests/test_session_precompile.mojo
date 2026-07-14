"""Precompile steps: the casualty fan-out on failure and the include-widening.

A failed precompile step aborts before any file identity exists: it emits a
single PrecompileFailed carrying the casualty count, counts EVERY discovered
gate/run file as NOT_RUN, and resolves exit 1 — no file is ever started. A
successful step adds its output directory to the include set of every
subsequent build, which the faithful build command records.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.config import Precompile, shell_join
from mtest.model import EventKind, Outcome
from mtest.report import CompositeReporter, RecordingReporter
from mtest.session import run_session

from session_fixtures import (
    SRC_COMPILE_ERROR,
    SRC_PASS,
    base_config,
    temp_root,
    write_file,
)


def test_failed_precompile_fans_out_all_as_not_run() raises:
    var root = temp_root()
    # A package whose __init__ does not compile.
    write_file(root, "badpkg/__init__.mojo", SRC_COMPILE_ERROR)
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", SRC_PASS)

    var config = base_config()
    config.precompiles.append(Precompile("badpkg", None))

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(config, root, comp)

    assert_equal(code, 1, "a failed precompile resolves to exit 1")
    ref rec = comp.reporters[0]
    # start + precompile_failed + finish = 3; NO file is ever started.
    assert_equal(rec.count(), 3)
    assert_true(rec.kind_at(0) == EventKind.SESSION_STARTED)
    assert_true(rec.kind_at(1) == EventKind.PRECOMPILE_FAILED)
    var pf = rec.event_at(1)
    assert_equal(pf.step, "badpkg")
    assert_equal(pf.casualty_count, 2)  # both run files are casualties
    assert_true(pf.compiler_output.byte_length() > 0)
    assert_true(rec.kind_at(2) == EventKind.SESSION_FINISHED)
    # Every discovered file is accounted for as NOT_RUN.
    assert_equal(rec.event_at(2).summary.count_of(Outcome.NOT_RUN), 2)
    assert_equal(rec.event_at(2).summary.count_of(Outcome.PASS), 0)


def test_successful_precompile_widens_include_path() raises:
    var root = temp_root()
    write_file(
        root, "goodpkg/__init__.mojo", "def helper() -> Int:\n    return 7\n"
    )
    write_file(root, "tests/test_a.mojo", SRC_PASS)

    var config = base_config()
    config.precompiles.append(Precompile("goodpkg", None))

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(config, root, comp)

    assert_equal(code, 0, "a clean precompile plus a passing file is exit 0")
    ref rec = comp.reporters[0]
    # start + file pair + finish = 4 (no PrecompileFailed event on success).
    assert_equal(rec.count(), 4)
    assert_true(rec.kind_at(1) == EventKind.FILE_STARTED)
    # The out directory (build) was added to the include set of the file build.
    var finished = rec.event_at(2)
    assert_true(finished.outcome == Outcome.PASS)
    var joined = shell_join(finished.build_argv)
    assert_true("-I build" in joined, joined)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
