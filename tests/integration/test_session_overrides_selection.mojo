"""Per-file overrides along the sequential selection pipeline.

Split out of `test_session_overrides.mojo` by weight; its retry case is one of
the three in the original that each paid, once per process, for reading and
hashing the compiler the cache keys against, and the three are kept in separate
suites so one per-file deadline carries one such payment.

The subject is the pipeline a selection run takes: build, run, and retry each
consult the effective budget for the file being selected, not the global one.
A selection is forced to one worker, so this is also the path on which an
override and the sequential runner meet.

No assertion relies on elapsed-time tolerance: a deliberately slow pass
distinguishes a one-second effective deadline from the three-second global
deadline by outcome.
"""
from std.os import getenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from mtest.config import (
    CliOverlay,
    ConfigEnvironment,
    FileConfig,
    OverrideRule,
    ResolvedConfig,
    RunnerConfig,
    lossy_utf8,
    resolve_config,
)
from mtest.model import (
    AttemptFinishedPayload,
    CollectionKnownPayload,
    CrashAttributionPayload,
    EventKind,
    FileFinishedPayload,
    FileStartedPayload,
    InternalErrorPayload,
    Outcome,
    PrecompileFailedPayload,
    ProgressPayload,
    SessionFinishedPayload,
    SessionStartedPayload,
    TestReportedPayload,
    WarningPayload,
)
from mtest.report import (
    CompositeReporter,
    RecordingCoordinator,
    RecordingReporter,
)
from mtest.session import run_collect, run_session

from session_fixtures import (
    SRC_PASS,
    base_config,
    temp_root,
    write_file,
)


comptime _SRC_SLOW_PASS = (
    "from std.testing import TestSuite, assert_true\n"
    "from std.time import sleep\n\n\n"
    "def test_slow() raises:\n"
    "    sleep(1.4)\n"
    "    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)

comptime _SRC_SLOW_PROBE = (
    "from std.sys import argv\n"
    "from std.testing import TestSuite, assert_true\n"
    "from std.time import sleep\n\n\n"
    "def test_pass() raises:\n"
    "    assert_true(True)\n\n\n"
    "def main() raises:\n"
    "    for arg in argv():\n"
    '        if arg == "--skip-all":\n'
    "            sleep(1.4)\n"
    "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
)


def _recorder() -> RecordingCoordinator[RecordingReporter]:
    return RecordingCoordinator(CompositeReporter(Tuple(RecordingReporter())))


def _rule(pattern: String) -> OverrideRule:
    var rule = OverrideRule.empty()
    rule.files = [pattern]
    return rule^


def _resolved(
    config: RunnerConfig, rules: List[OverrideRule]
) -> ResolvedConfig:
    var file = FileConfig.empty()
    file.overrides = rules.copy()
    return resolve_config(
        config,
        file,
        ConfigEnvironment.empty(),
        CliOverlay.default(),
    )


def _payload(
    rec: RecordingReporter, path: String
) raises -> FileFinishedPayload:
    for i in range(rec.count()):
        if rec.kind_at(i) == EventKind.FILE_FINISHED and rec.path_at(i) == path:
            return rec.event_at(i).data[FileFinishedPayload].copy()
    raise Error("no FileFinished for " + path)


def _selection_crash_once_source(marker: String) -> String:
    return (
        "from std.ffi import external_call\n"
        "from std.os.path import exists\n"
        "from std.testing import TestSuite, assert_true\n\n\n"
        "def test_eventual_pass() raises:\n"
        '    if not exists("'
        + marker
        + '"):\n        with open("'
        + marker
        + '", "w") as f:\n'
        '            f.write("1")\n'
        '        _ = external_call["abort", Int32]()\n'
        "    assert_true(True)\n\n\n"
        "def main() raises:\n"
        "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
    )


def test_selection_run_uses_its_effective_deadline() raises:
    var root = temp_root()
    write_file(root, "tests/test_selected.mojo", _SRC_SLOW_PASS)
    var config = base_config()
    config.timeout_secs = 3
    config.paths = ["tests/test_selected.mojo::test_slow"]
    var rule = _rule("tests/test_selected.mojo")
    rule.timeout_secs = 1
    rule.saw_timeout = True
    var resolved = _resolved(config, [rule.copy()])

    var comp = _recorder()
    var code = run_session(resolved, root, comp)

    assert_equal(code, 1)
    var payload = _payload(
        comp.composite.reporters[0], "tests/test_selected.mojo"
    )
    assert_true(payload.outcome == Outcome.TIMEOUT)
    assert_equal(payload.timeout_seconds, 1)


def test_selection_build_uses_its_effective_compile_deadline() raises:
    var root = temp_root()
    write_file(root, "tests/test_selected.mojo", SRC_PASS)
    var config = base_config()
    config.compile_timeout_secs = 3
    config.paths = ["tests/test_selected.mojo::test_pass"]
    config.mojo_path = (
        getenv("PIXI_PROJECT_ROOT", "")
        + "/scripts/fixtures/toolchain/fake_slow_mojo.py"
    )
    var rule = _rule("tests/test_selected.mojo")
    rule.compile_timeout_secs = 1
    rule.saw_compile_timeout = True
    var resolved = _resolved(config, [rule.copy()])

    var comp = _recorder()
    var code = run_session(resolved, root, comp)

    assert_equal(code, 1)
    var payload = _payload(
        comp.composite.reporters[0], "tests/test_selected.mojo"
    )
    assert_true(payload.outcome == Outcome.COMPILE_TIMEOUT)
    assert_equal(payload.timeout_seconds, 1)


def test_selection_retry_uses_the_effective_budget() raises:
    var root = temp_root()
    write_file(
        root,
        "tests/test_selected.mojo",
        _selection_crash_once_source("selection_retry_marker"),
    )
    var config = base_config()
    config.retries = 0
    config.paths = ["tests/test_selected.mojo::test_eventual_pass"]
    var rule = _rule("tests/test_selected.mojo")
    rule.retries = 1
    rule.saw_retries = True
    var resolved = _resolved(config, [rule.copy()])

    var comp = _recorder()
    var code = run_session(resolved, root, comp)

    assert_equal(code, 0)
    var payload = _payload(
        comp.composite.reporters[0], "tests/test_selected.mojo"
    )
    assert_true(payload.outcome == Outcome.FLAKY)
    assert_equal(payload.attempts_used, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
