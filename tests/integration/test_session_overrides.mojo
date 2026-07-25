"""Real-process coverage for per-file session override plumbing.

The tests drive deadlines, compiler deadlines, crash retries, serial batching,
gate admission, and the sequential selection pipeline. No assertion relies on
elapsed-time tolerance: a deliberately slow pass distinguishes a one-second
effective deadline from the three-second global deadline by outcome.
"""
from std.os import getenv
from std.testing import assert_equal, assert_false, assert_true

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


def _event_index(
    rec: RecordingReporter, kind: EventKind, path: String
) raises -> Int:
    for i in range(rec.count()):
        if rec.kind_at(i) == kind and rec.path_at(i) == path:
            return i
    raise Error("no matching event for " + path)


def _assert_string_lists_equal(
    actual: List[String], expected: List[String]
) raises:
    assert_equal(len(actual), len(expected))
    for i in range(len(expected)):
        assert_equal(actual[i], expected[i])


def _mask_report_timings(bytes: List[UInt8]) -> String:
    """Mask only TestSuite row/summary timings in a valid UTF-8 capture."""
    var lines = lossy_utf8(bytes).split("\n")
    var masked = String("")
    for i in range(len(lines)):
        var line = String(lines[i])
        if (
            line.startswith("    PASS [")
            or line.startswith("    FAIL [")
            or line.startswith("    SKIP [")
            or line.startswith("Summary [")
        ):
            var left = line.split("[ ", 1)
            if len(left) == 2:
                var right = String(left[1]).split(" ]", 1)
                if len(right) == 2:
                    line = String(left[0]) + "[ T ]" + String(right[1])
        if i > 0:
            masked += "\n"
        masked += line
    return masked^


def _assert_capture_equal_ignoring_report_timings(
    actual: List[UInt8], expected: List[UInt8]
) raises:
    """Compare a capture after masking its only wall-clock protocol tokens."""
    assert_equal(_mask_report_timings(actual), _mask_report_timings(expected))


def _assert_masked_seconds(actual: Float64, expected: Float64) raises:
    """Account for a wall-clock field while masking its nondeterministic value.
    """
    assert_true(actual >= 0.0)
    assert_true(expected >= 0.0)


def _assert_complete_event_projection(
    actual: RecordingReporter, expected: RecordingReporter
) raises:
    """Compare every deterministic field in two complete event streams."""
    assert_equal(actual.count(), expected.count())
    for i in range(expected.count()):
        var aevent = actual.event_at(i)
        var eevent = expected.event_at(i)
        assert_true(aevent.kind == eevent.kind)

        if aevent.kind == EventKind.SESSION_STARTED:
            ref a = aevent.data[SessionStartedPayload]
            ref e = eevent.data[SessionStartedPayload]
            assert_equal(a.root, e.root)
            assert_equal(a.toolchain, e.toolchain)
            assert_equal(a.selected_count, e.selected_count)
            assert_equal(a.excluded_count, e.excluded_count)
            assert_equal(a.shard_label, e.shard_label)
            assert_equal(a.sharded_out_count, e.sharded_out_count)
            assert_equal(a.workers, e.workers)
        elif aevent.kind == EventKind.WARNING:
            ref a = aevent.data[WarningPayload]
            ref e = eevent.data[WarningPayload]
            assert_equal(a.warning_kind, e.warning_kind)
            assert_equal(a.warning_pattern, e.warning_pattern)
        elif aevent.kind == EventKind.PRECOMPILE_FAILED:
            ref a = aevent.data[PrecompileFailedPayload]
            ref e = eevent.data[PrecompileFailedPayload]
            assert_equal(a.step, e.step)
            assert_equal(a.compiler_output, e.compiler_output)
            assert_equal(a.casualty_count, e.casualty_count)
            _assert_string_lists_equal(a.casualties, e.casualties)
            assert_equal(a.ending_known, e.ending_known)
            assert_equal(a.term_kind, e.term_kind)
            assert_equal(a.term_value, e.term_value)
            assert_equal(a.escalated, e.escalated)
            assert_equal(a.timeout_seconds, e.timeout_seconds)
            assert_equal(a.attempts_used, e.attempts_used)
        elif aevent.kind == EventKind.FILE_STARTED:
            ref a = aevent.data[FileStartedPayload]
            ref e = eevent.data[FileStartedPayload]
            assert_equal(a.path, e.path)
        elif aevent.kind == EventKind.FILE_FINISHED:
            ref a = aevent.data[FileFinishedPayload]
            ref e = eevent.data[FileFinishedPayload]
            assert_equal(a.path, e.path)
            assert_true(a.outcome == e.outcome)
            _assert_masked_seconds(a.duration_seconds, e.duration_seconds)
            _assert_string_lists_equal(a.build_argv, e.build_argv)
            _assert_masked_seconds(
                a.build_duration_seconds, e.build_duration_seconds
            )
            _assert_capture_equal_ignoring_report_timings(
                a.captured_stdout, e.captured_stdout
            )
            _assert_capture_equal_ignoring_report_timings(
                a.captured_stderr, e.captured_stderr
            )
            assert_equal(a.signal_number, e.signal_number)
            assert_equal(a.exit_status, e.exit_status)
            assert_equal(a.timeout_seconds, e.timeout_seconds)
            assert_equal(a.exclusion_pattern, e.exclusion_pattern)
            assert_true(a.parse_disposition == e.parse_disposition)
            assert_equal(a.passed_tests, e.passed_tests)
            assert_equal(a.failed_tests, e.failed_tests)
            assert_equal(a.skipped_tests, e.skipped_tests)
            assert_equal(a.deselected_tests, e.deselected_tests)
            assert_equal(a.attempts_used, e.attempts_used)
            assert_equal(a.flaky, e.flaky)
            assert_equal(a.slow, e.slow)
            assert_equal(a.escalated, e.escalated)
            assert_equal(a.stdout_truncated, e.stdout_truncated)
            assert_equal(a.stderr_truncated, e.stderr_truncated)
            assert_equal(a.serial, e.serial)
        elif aevent.kind == EventKind.SESSION_FINISHED:
            ref a = aevent.data[SessionFinishedPayload]
            ref e = eevent.data[SessionFinishedPayload]
            assert_equal(len(a.summary.counts), len(e.summary.counts))
            for oi in range(len(e.summary.counts)):
                assert_equal(a.summary.counts[oi], e.summary.counts[oi])
            _assert_masked_seconds(a.wall_time_seconds, e.wall_time_seconds)
            assert_equal(a.exit_code, e.exit_code)
            assert_equal(a.test_counts.passed, e.test_counts.passed)
            assert_equal(a.test_counts.failed, e.test_counts.failed)
            assert_equal(a.test_counts.skipped, e.test_counts.skipped)
            assert_equal(a.test_counts.deselected, e.test_counts.deselected)
            assert_equal(a.flaky_files, e.flaky_files)
        elif aevent.kind == EventKind.INTERNAL_ERROR:
            ref a = aevent.data[InternalErrorPayload]
            ref e = eevent.data[InternalErrorPayload]
            assert_equal(a.step, e.step)
            assert_equal(a.program, e.program)
            assert_equal(a.errno, e.errno)
        elif aevent.kind == EventKind.TEST_REPORTED:
            ref a = aevent.data[TestReportedPayload]
            ref e = eevent.data[TestReportedPayload]
            assert_equal(a.path, e.path)
            assert_equal(a.test.node.path, e.test.node.path)
            assert_equal(a.test.node.name, e.test.node.name)
            assert_true(a.test.outcome == e.test.outcome)
            assert_equal(a.test.detail, e.test.detail)
            assert_equal(
                a.test.timing.byte_length() > 0,
                e.test.timing.byte_length() > 0,
            )
        elif aevent.kind == EventKind.COLLECTION_KNOWN:
            ref a = aevent.data[CollectionKnownPayload]
            ref e = eevent.data[CollectionKnownPayload]
            assert_equal(a.selected_test_total, e.selected_test_total)
            assert_equal(a.deselected_test_total, e.deselected_test_total)
        elif aevent.kind == EventKind.ATTEMPT_FINISHED:
            ref a = aevent.data[AttemptFinishedPayload]
            ref e = eevent.data[AttemptFinishedPayload]
            assert_equal(a.path, e.path)
            assert_equal(a.step, e.step)
            assert_equal(a.attempt_index, e.attempt_index)
            assert_equal(a.attempts_planned, e.attempts_planned)
            assert_equal(a.term_kind, e.term_kind)
            assert_equal(a.term_value, e.term_value)
            assert_equal(a.term_final_kind, e.term_final_kind)
            assert_equal(a.term_final_value, e.term_final_value)
            assert_equal(a.escalated, e.escalated)
            assert_equal(a.retry_eligible, e.retry_eligible)
            assert_equal(a.classification, e.classification)
            _assert_masked_seconds(a.duration_seconds, e.duration_seconds)
            _assert_capture_equal_ignoring_report_timings(
                a.captured_stdout, e.captured_stdout
            )
            _assert_capture_equal_ignoring_report_timings(
                a.captured_stderr, e.captured_stderr
            )
            assert_equal(a.stdout_truncated, e.stdout_truncated)
            assert_equal(a.stderr_truncated, e.stderr_truncated)
            _assert_string_lists_equal(a.attempt_argv, e.attempt_argv)
        elif aevent.kind == EventKind.CRASH_ATTRIBUTION:
            ref a = aevent.data[CrashAttributionPayload]
            ref e = eevent.data[CrashAttributionPayload]
            assert_equal(a.path, e.path)
            assert_true(a.attribution_disposition == e.attribution_disposition)
            assert_equal(a.culprit_test, e.culprit_test)
            assert_equal(a.isolation_reruns, e.isolation_reruns)
            _assert_masked_seconds(a.attribution_seconds, e.attribution_seconds)
        elif aevent.kind == EventKind.PROGRESS:
            ref a = aevent.data[ProgressPayload]
            ref e = eevent.data[ProgressPayload]
            assert_equal(a.completed, e.completed)
            assert_equal(a.total, e.total)
            _assert_string_lists_equal(a.running_paths, e.running_paths)
            assert_equal(
                len(a.running_elapsed_seconds),
                len(e.running_elapsed_seconds),
            )
            for ti in range(len(e.running_elapsed_seconds)):
                _assert_masked_seconds(
                    a.running_elapsed_seconds[ti],
                    e.running_elapsed_seconds[ti],
                )
        else:
            raise Error("unhandled event kind in compatibility projection")


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


def test_pool_run_deadline_is_effective_per_file() raises:
    var root = temp_root()
    write_file(root, "tests/test_override.mojo", _SRC_SLOW_PASS)
    write_file(root, "tests/test_unmatched.mojo", _SRC_SLOW_PASS)
    var config = base_config()
    config.timeout_secs = 3
    config.workers = 2
    var rule = _rule("tests/test_override.mojo")
    rule.timeout_secs = 1
    rule.saw_timeout = True
    var resolved = _resolved(config, [rule.copy()])

    var comp = _recorder()
    var code = run_session(resolved, root, comp)

    assert_equal(code, 1)
    ref rec = comp.composite.reporters[0]
    var matched = _payload(rec, "tests/test_override.mojo")
    var unmatched = _payload(rec, "tests/test_unmatched.mojo")
    assert_true(matched.outcome == Outcome.TIMEOUT)
    assert_equal(matched.timeout_seconds, 1)
    assert_true(unmatched.outcome == Outcome.PASS)


def test_pool_compile_deadline_is_effective_per_file() raises:
    var root = temp_root()
    write_file(root, "tests/test_override.mojo", SRC_PASS)
    var config = base_config()
    config.compile_timeout_secs = 3
    config.workers = 2
    config.mojo_path = (
        getenv("PIXI_PROJECT_ROOT", "")
        + "/scripts/fixtures/toolchain/fake_slow_mojo.py"
    )
    var rule = _rule("tests/test_override.mojo")
    rule.compile_timeout_secs = 1
    rule.saw_compile_timeout = True
    var resolved = _resolved(config, [rule.copy()])

    var comp = _recorder()
    var code = run_session(resolved, root, comp)

    assert_equal(code, 1)
    var payload = _payload(
        comp.composite.reporters[0], "tests/test_override.mojo"
    )
    assert_true(payload.outcome == Outcome.COMPILE_TIMEOUT)
    assert_equal(payload.timeout_seconds, 1)


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


def test_later_serial_union_runs_after_parallel_at_capacity_one() raises:
    var root = temp_root()
    write_file(root, "tests/test_parallel.mojo", SRC_PASS)
    write_file(root, "tests/test_serial_a.mojo", SRC_PASS)
    write_file(root, "tests/test_serial_b.mojo", SRC_PASS)
    var config = base_config()
    config.workers = 2
    var broad = _rule("tests/*.mojo")
    var serial = _rule("tests/test_serial_*.mojo")
    serial.serial = True
    serial.saw_serial = True
    var resolved = _resolved(config, [broad.copy(), serial.copy()])

    var comp = _recorder()
    var code = run_session(resolved, root, comp)

    assert_equal(code, 0)
    ref rec = comp.composite.reporters[0]
    assert_false(_payload(rec, "tests/test_parallel.mojo").serial)
    assert_true(_payload(rec, "tests/test_serial_a.mojo").serial)
    assert_true(_payload(rec, "tests/test_serial_b.mojo").serial)
    var parallel_finished = _event_index(
        rec, EventKind.FILE_FINISHED, "tests/test_parallel.mojo"
    )
    var serial_a_started = _event_index(
        rec, EventKind.FILE_STARTED, "tests/test_serial_a.mojo"
    )
    var serial_a_finished = _event_index(
        rec, EventKind.FILE_FINISHED, "tests/test_serial_a.mojo"
    )
    var serial_b_started = _event_index(
        rec, EventKind.FILE_STARTED, "tests/test_serial_b.mojo"
    )
    assert_true(parallel_finished < serial_a_started)
    assert_true(serial_a_finished < serial_b_started)


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


def test_capacity_one_without_overrides_preserves_legacy_projection() raises:
    var root = temp_root()
    write_file(root, "tests/test_plain.mojo", SRC_PASS)
    var config = base_config()
    config.workers = 1
    var resolved = _resolved(config, List[OverrideRule]())

    var legacy_comp = _recorder()
    var legacy_code = run_session(config, root, legacy_comp)
    var resolved_comp = _recorder()
    var resolved_code = run_session(resolved, root, resolved_comp)

    assert_equal(legacy_code, 0)
    assert_equal(resolved_code, legacy_code)
    ref legacy = legacy_comp.composite.reporters[0]
    ref layered = resolved_comp.composite.reporters[0]
    _assert_complete_event_projection(layered, legacy)
    for i in range(layered.count()):
        if layered.kind_at(i) == EventKind.FILE_FINISHED:
            ref payload = layered.event_at(i).data[FileFinishedPayload]
            for arg in payload.build_argv:
                assert_true(arg != "--num-threads")


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
