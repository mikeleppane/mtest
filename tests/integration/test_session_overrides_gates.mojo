"""Per-file overrides on the runs that are not a pool file: gates and retries.

Split out of `test_session_overrides.mojo` by weight, back when a suite that
drove real sessions paid once per process for reading and hashing the compiler
the cache keys against. `session_fixtures.base_config` now keys a wrapper and
that payment is gone, so what is left holding the three files apart is the
subject seam below rather than any deadline.

The subject holds together on its own: an override rule is matched per file, so
a retry budget must apply to the file its pattern names and to no other, and the
gate — which runs before any of them — must still read its own effective
deadline rather than the global one.

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


def _crash_once_source(marker: String) -> String:
    return (
        "from std.ffi import external_call\n"
        "from std.os.path import exists\n"
        "from std.testing import TestSuite, assert_true\n\n\n"
        "def test_eventual_pass() raises:\n"
        "    assert_true(True)\n\n\n"
        "def main() raises:\n"
        '    if not exists("'
        + marker
        + '"):\n        with open("'
        + marker
        + '", "w") as f:\n'
        '            f.write("1")\n'
        '        _ = external_call["abort", Int32]()\n'
        "    TestSuite.discover_tests[__functions_in_module()]().run()\n"
    )


def test_plain_retries_apply_only_to_matching_file() raises:
    var root = temp_root()
    write_file(
        root,
        "tests/test_matched.mojo",
        _crash_once_source("matched_retry_marker"),
    )
    write_file(
        root,
        "tests/test_unmatched.mojo",
        _crash_once_source("unmatched_retry_marker"),
    )
    var config = base_config()
    config.timeout_secs = 10
    config.retries = 0
    config.workers = 2
    var rule = _rule("tests/test_matched.mojo")
    rule.retries = 1
    rule.saw_retries = True
    var resolved = _resolved(config, [rule.copy()])

    var comp = _recorder()
    var code = run_session(resolved, root, comp)

    assert_equal(code, 1)
    ref rec = comp.composite.reporters[0]
    var matched = _payload(rec, "tests/test_matched.mojo")
    var unmatched = _payload(rec, "tests/test_unmatched.mojo")
    assert_true(matched.outcome == Outcome.FLAKY)
    assert_equal(matched.attempts_used, 2)
    assert_true(
        unmatched.outcome == Outcome.CRASH,
        "unmatched outcome code=" + String(unmatched.outcome.code),
    )
    assert_equal(unmatched.attempts_used, 1)


def test_gate_uses_its_effective_run_deadline() raises:
    var root = temp_root()
    write_file(root, "tests/test_gate.mojo", _SRC_SLOW_PASS)
    write_file(root, "tests/test_run.mojo", SRC_PASS)
    var config = base_config()
    config.timeout_secs = 3
    config.gates = ["tests/test_gate.mojo"]
    var rule = _rule("tests/test_gate.mojo")
    rule.timeout_secs = 1
    rule.saw_timeout = True
    var resolved = _resolved(config, [rule.copy()])

    var comp = _recorder()
    var code = run_session(resolved, root, comp)

    assert_equal(code, 1)
    var payload = _payload(comp.composite.reporters[0], "tests/test_gate.mojo")
    assert_true(payload.outcome == Outcome.TIMEOUT)
    assert_equal(payload.timeout_seconds, 1)


def test_collect_probe_uses_its_effective_deadline() raises:
    var root = temp_root()
    write_file(root, "tests/test_collect.mojo", _SRC_SLOW_PROBE)
    var config = base_config()
    config.collect = True
    config.timeout_secs = 3
    var rule = _rule("tests/test_collect.mojo")
    rule.timeout_secs = 1
    rule.saw_timeout = True
    var resolved = _resolved(config, [rule.copy()])

    var result = run_collect(resolved, root)

    assert_equal(result.code, 1)
    assert_equal(len(result.listing), 0)
    assert_equal(len(result.diagnostics), 1)
    assert_true("probe timed out" in result.diagnostics[0])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
