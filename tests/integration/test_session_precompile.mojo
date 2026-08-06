"""Precompile steps: the casualty fan-out on failure and the include-widening.

A failed precompile step aborts before any file identity exists: it emits a
single PrecompileFailed carrying the casualty count, counts EVERY discovered
gate/run file as NOT_RUN, and resolves exit 1 — no file is ever started. A
successful step adds its output directory to the include set of every
subsequent build, which the faithful build command records.
"""
from std.os import listdir, makedirs
from std.os.path import isdir
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.config import (
    ColorWhen,
    Precompile,
    ShowOutput,
    Verbosity,
    shell_join,
)
from mtest.model import (
    EventKind,
    FileFinishedPayload,
    InternalErrorPayload,
    Outcome,
    PrecompileFailedPayload,
    SessionFinishedPayload,
)
from mtest.report import (
    CompositeReporter,
    ConsoleReporter,
    RecordingCoordinator,
    RecordingReporter,
)
from mtest.exec import ExecRuntime
from mtest.session import run_session
from mtest.session.precompile import run_precompile_step
from mtest.session.store import (
    PRECOMPILE_SUBDIR,
    STORE_DIR,
    CacheContext,
    collect_env_base,
)

from session_fixtures import (
    SRC_COMPILE_ERROR,
    SRC_PASS,
    base_config,
    temp_root,
    write_file,
)


comptime _GOOD_PKG = "def value() -> Int:\n    return 1\n"


def _stamp_dir(root: String) -> String:
    """Where a stamped precompile step records that it ran."""
    return root + "/" + STORE_DIR + "/" + PRECOMPILE_SUBDIR


def test_a_stamped_step_is_skipped_on_the_next_pass() raises:
    var root = temp_root()
    write_file(root, "goodpkg/__init__.mojo", _GOOD_PKG)
    var config = base_config()
    var pc = Precompile("goodpkg", None)
    var runtime = ExecRuntime()
    runtime.open()
    var ctx = collect_env_base(runtime, config, root)

    var first_includes = config.include_paths.copy()
    var first_priors = List[String]()
    var first = run_precompile_step(
        runtime,
        config,
        root,
        pc,
        ctx,
        first_includes,
        first_priors,
        use_cache=True,
    )
    assert_true(Bool(first), "a cold step has no stamp to skip on")
    assert_true(first.value().ok, "the step compiled")
    assert_true(isdir(_stamp_dir(root)), "a first-attempt success is stamped")

    var second_includes = config.include_paths.copy()
    var second_priors = List[String]()
    var second = run_precompile_step(
        runtime,
        config,
        root,
        pc,
        ctx,
        second_includes,
        second_priors,
        use_cache=True,
    )
    # Skipped, and still widening: the package on disk is the one the key
    # names, so every later build must still see its directory.
    assert_false(Bool(second), "an unchanged step is skipped")
    assert_equal(len(second_includes), len(first_includes))
    assert_equal(len(second_priors), 1)
    runtime.close()


def test_the_cache_switch_makes_a_step_ignore_its_own_stamp() raises:
    """`use_cache=False` keys nothing, so a stamped step still runs.

    This is the switch `debug` runs under: every path it prints has to have
    been produced by that invocation, so it never skips a step on the strength
    of a stamp an earlier run wrote.
    """
    var root = temp_root()
    write_file(root, "goodpkg/__init__.mojo", _GOOD_PKG)
    var config = base_config()
    var pc = Precompile("goodpkg", None)
    var runtime = ExecRuntime()
    runtime.open()
    var ctx = collect_env_base(runtime, config, root)

    var warm_includes = config.include_paths.copy()
    var warm_priors = List[String]()
    _ = run_precompile_step(
        runtime,
        config,
        root,
        pc,
        ctx,
        warm_includes,
        warm_priors,
        use_cache=True,
    )
    assert_true(isdir(_stamp_dir(root)), "the stamp this case needs is there")

    var off_includes = config.include_paths.copy()
    var off_priors = List[String]()
    var off = run_precompile_step(
        runtime,
        config,
        root,
        pc,
        ctx,
        off_includes,
        off_priors,
        use_cache=False,
    )
    assert_true(Bool(off), "a step with the cache off is never skipped")
    assert_true(off.value().ok, "and it really compiled")
    runtime.close()


def test_failed_precompile_fans_out_all_as_not_run() raises:
    var root = temp_root()
    # A package whose __init__ does not compile.
    write_file(root, "badpkg/__init__.mojo", SRC_COMPILE_ERROR)
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", SRC_PASS)

    var config = base_config()
    config.precompiles.append(Precompile("badpkg", None))

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 1, "a failed precompile resolves to exit 1")
    ref rec = comp.composite.reporters[0]
    # start + precompile_failed + finish = 3; NO file is ever started.
    assert_equal(rec.count(), 3)
    assert_true(rec.kind_at(0) == EventKind.SESSION_STARTED)
    assert_true(rec.kind_at(1) == EventKind.PRECOMPILE_FAILED)
    var pfe = rec.event_at(1)
    ref pf = pfe.data[PrecompileFailedPayload]
    assert_equal(pf.step, "badpkg")
    assert_equal(pf.casualty_count, 2)  # both run files are casualties
    assert_true(pf.compiler_output.byte_length() > 0)
    assert_true(rec.kind_at(2) == EventKind.SESSION_FINISHED)
    # Every discovered file is accounted for as NOT_RUN.
    assert_equal(
        rec.event_at(2)
        .data[SessionFinishedPayload]
        .summary.count_of(Outcome.NOT_RUN),
        2,
    )
    assert_equal(
        rec.event_at(2)
        .data[SessionFinishedPayload]
        .summary.count_of(Outcome.PASS),
        0,
    )


def _casualties(root: String, seed: Int) raises -> List[String]:
    """The named casualties of a failed precompile under one shuffle seed."""
    var config = base_config()
    config.precompiles.append(Precompile("badpkg", None))
    config.shuffle = True
    config.shuffle_seed = seed
    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    _ = run_session(config, root, comp)
    ref rec = comp.composite.reporters[0]
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.PRECOMPILE_FAILED:
            return (
                rec.event_at(i).data[PrecompileFailedPayload].casualties.copy()
            )
    raise Error("the session emitted no PrecompileFailed event")


def test_precompile_casualties_stay_sorted_under_every_seed() raises:
    # `--shuffle` randomizes EXECUTION order; a casualty list is a report, and
    # reports stay node-id sorted. Nothing here even runs, so a list that moved
    # with the seed would be the randomizer leaking into a surface the stream
    # contract calls deterministic.
    var root = temp_root()
    write_file(root, "badpkg/__init__.mojo", SRC_COMPILE_ERROR)
    write_file(root, "tests/test_a.mojo", SRC_PASS)
    write_file(root, "tests/test_b.mojo", SRC_PASS)
    write_file(root, "tests/test_c.mojo", SRC_PASS)
    write_file(root, "tests/test_d.mojo", SRC_PASS)

    # Seeds 7 and 9 draw different orders over four files, so a casualty list
    # built from the execution order cannot agree with itself across the pair.
    var sorted_names: List[String] = [
        "tests/test_a.mojo",
        "tests/test_b.mojo",
        "tests/test_c.mojo",
        "tests/test_d.mojo",
    ]
    for seed in [7, 9]:
        var named = _casualties(root, seed)
        assert_equal(len(named), 4)
        for i in range(4):
            assert_equal(
                named[i],
                sorted_names[i],
                "casualties moved with the shuffle seed",
            )


def test_successful_precompile_widens_include_path() raises:
    var root = temp_root()
    write_file(
        root, "goodpkg/__init__.mojo", "def helper() -> Int:\n    return 7\n"
    )
    write_file(root, "tests/test_a.mojo", SRC_PASS)

    var config = base_config()
    config.precompiles.append(Precompile("goodpkg", None))

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 0, "a clean precompile plus a passing file is exit 0")
    ref rec = comp.composite.reporters[0]
    # start + file triple (started, test_reported, finished) + finish = 5 (no
    # PrecompileFailed event on success).
    assert_equal(rec.count(), 5)
    assert_true(rec.kind_at(1) == EventKind.FILE_STARTED)
    # The out directory (build) was added to the include set of the file build.
    var fe = rec.event_at(3)
    ref finished = fe.data[FileFinishedPayload]
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

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
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

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 1, "an unpromotable package resolves to exit 1")
    ref rec = comp.composite.reporters[0]
    assert_true(rec.kind_at(1) == EventKind.PRECOMPILE_FAILED)
    var pf = rec.event_at(1)
    ref pfp = pf.data[PrecompileFailedPayload]
    assert_false(
        pfp.ending_known,
        "a failed promotion claimed a compiler ending it never had",
    )
    assert_true(
        "could not be promoted" in pfp.compiler_output,
        "the banner never explained that the rename is what lost",
    )

    var console = ConsoleReporter(
        "0.6.0",
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

    var comp = RecordingCoordinator(
        CompositeReporter(Tuple(RecordingReporter()))
    )
    var code = run_session(config, root, comp)

    assert_equal(code, 3, "a precompile spawn failure resolves to exit 3")
    ref rec = comp.composite.reporters[0]
    # The claim is "no file is ever started", asserted by KIND rather than by a
    # literal event count. The same unresolvable `mojo_path` that fails the
    # spawn also stops the build cache from identifying a compiler, so the
    # session emits its once-per-run `cache-off` warning — a designed event that
    # shifts every literal index after SESSION_STARTED without changing anything
    # this case is about.
    var internal_errors = 0
    var files_seen = 0
    for i in range(rec.count()):
        var kind = rec.kind_at(i)
        if kind == EventKind.INTERNAL_ERROR:
            internal_errors += 1
            ref ie = rec.event_at(i).data[InternalErrorPayload]
            assert_equal(ie.step, "precompile")
            assert_equal(ie.program, "/no/such/mojo/compiler")
            assert_equal(ie.errno, 2)  # ENOENT — the real spawn cause, not 0
            assert_false(ie.errno == 0, "the real spawn errno was dropped")
        elif kind == EventKind.FILE_STARTED or kind == EventKind.FILE_FINISHED:
            files_seen += 1
    assert_equal(internal_errors, 1, "exactly one diagnostic is emitted")
    assert_equal(files_seen, 0, "no file may be started after a failed step")
    assert_true(
        rec.kind_at(rec.count() - 1) == EventKind.SESSION_FINISHED,
        "the session must still be terminated by SessionFinished",
    )


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
