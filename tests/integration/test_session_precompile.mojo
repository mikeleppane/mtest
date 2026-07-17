"""Precompile steps: the casualty fan-out on failure and the include-widening.

A failed precompile step aborts before any file identity exists: it emits a
single PrecompileFailed carrying the casualty count, counts EVERY discovered
gate/run file as NOT_RUN, and resolves exit 1 — no file is ever started. A
successful step adds its output directory to the include set of every
subsequent build, which the faithful build command records.
"""
from std.os import listdir, makedirs
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.config import (
    ColorWhen,
    Precompile,
    ShowOutput,
    Verbosity,
    shell_join,
)
from mtest.model import EventKind, Outcome
from mtest.report import (
    CompositeReporter,
    ConsoleReporter,
    RecordingReporter,
)
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
    # start + file triple (started, test_reported, finished) + finish = 5 (no
    # PrecompileFailed event on success).
    assert_equal(rec.count(), 5)
    assert_true(rec.kind_at(1) == EventKind.FILE_STARTED)
    # The out directory (build) was added to the include set of the file build.
    var finished = rec.event_at(3)
    assert_true(finished.outcome == Outcome.PASS)
    var joined = shell_join(finished.build_argv)
    assert_true("-I build" in joined, joined)


def test_failed_precompile_leaves_a_good_out_package_untouched() raises:
    # The headline promotion guarantee: an attempt builds to a TEMP path and is
    # renamed onto OUT only after it exits 0, so a step that fails can never
    # damage the package a previous good run left behind — and never litters the
    # OUT directory with the half-built temp either.
    var root = temp_root()
    write_file(root, "badpkg/__init__.mojo", SRC_COMPILE_ERROR)
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    var sentinel = String("SENTINEL-PACKAGE-BYTES\n")
    write_file(root, "build/badpkg.mojopkg", sentinel)

    var config = base_config()
    config.precompiles.append(Precompile("badpkg", None))

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(config, root, comp)

    assert_equal(code, 1, "a failed precompile resolves to exit 1")
    var after = open(root + "/build/badpkg.mojopkg", "r").read()
    assert_equal(after, sentinel, "a failed precompile damaged the good OUT")
    for name in listdir(root + "/build"):
        assert_false(
            String(name).endswith(".tmp"),
            "a failed precompile left temp litter: " + String(name),
        )


def test_promotion_failure_never_reports_a_compiler_ending() raises:
    # A step can fail with the COMPILER exiting 0: OUT already exists as a
    # directory, so the package builds but the rename onto OUT cannot happen
    # (EISDIR). The step is honestly a PRECOMPILE-ERROR — nothing was published —
    # but it has NO compiler ending to name, and the attempt's Exited(0) must
    # never surface as the banner nonsense "exited 0" on a failed step. Rendered
    # through the real console here: this is the chain the reader actually sees.
    var root = temp_root()
    write_file(
        root, "goodpkg/__init__.mojo", "def helper() -> Int:\n    return 7\n"
    )
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    makedirs(root + "/build/goodpkg.mojopkg")

    var config = base_config()
    config.precompiles.append(Precompile("goodpkg", None))

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(config, root, comp)

    assert_equal(code, 1, "an unpromotable package resolves to exit 1")
    ref rec = comp.reporters[0]
    assert_true(rec.kind_at(1) == EventKind.PRECOMPILE_FAILED)
    var pf = rec.event_at(1)
    assert_false(
        pf.ending_known,
        "a failed promotion claimed a compiler ending it never had",
    )
    assert_true(
        "could not be promoted" in pf.compiler_output,
        "the banner never explained that the rename is what lost",
    )

    var console = ConsoleReporter(
        "0.1.0-dev",
        ColorWhen.NEVER,
        is_tty=False,
        no_color=False,
        verbosity=Verbosity.NORMAL,
        show_output=ShowOutput.FAILURES,
        mtest_build_flags="",
        durations=0,
    )
    console.handle(pf)
    var out = console.output()
    assert_true("PRECOMPILE-ERROR" in out)
    assert_false(
        "exited 0" in out, "a failed step was reported as having exited 0"
    )


def test_precompile_spawn_failure_names_the_real_errno() raises:
    # Point the runner at a nonexistent compiler so spawning the precompile step
    # fails with ENOENT before any package can build. The internal-error event
    # must carry the real errno and the missing program — not a generic errno 0.
    var root = temp_root()
    write_file(root, "tests/test_a.mojo", SRC_PASS)

    var config = base_config()
    config.mojo_path = "/no/such/mojo/compiler"
    config.precompiles.append(Precompile("somepkg", None))

    var comp = CompositeReporter(Tuple(RecordingReporter()))
    var code = run_session(config, root, comp)

    assert_equal(code, 3, "a precompile spawn failure resolves to exit 3")
    ref rec = comp.reporters[0]
    # start + internal_error + finish = 3; no file is ever started.
    assert_equal(rec.count(), 3)
    assert_true(rec.kind_at(1) == EventKind.INTERNAL_ERROR)
    var ie = rec.event_at(1)
    assert_equal(ie.step, "precompile")
    assert_equal(ie.program, "/no/such/mojo/compiler")
    assert_equal(ie.errno, 2)  # ENOENT — the real spawn cause, not 0
    assert_false(ie.errno == 0, "the real spawn errno was dropped")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
