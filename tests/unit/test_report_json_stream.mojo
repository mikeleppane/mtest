"""Tests for the pure NDJSON event serializer (Layer 2).

Table-driven, exact-output assertions over `stream_header` and
`serialize_event`: the frozen header line, the per-kind field mapping, the
`*_seconds`->`*_us` integer-microsecond conversion (round half away from zero,
negatives clamped, saturation), every per-kind bound with its derivable
omission metadata (a payload built to EXCEED each cap, asserting the head+tail
excerpt plus the omitted count), and hostile payloads (control bytes, invalid
UTF-8 pre-lossy, quote/backslash storms, NDJSON-lookalike content inside a
string). No floating-point ever appears in the output.
"""
from std.testing import assert_equal, assert_false, assert_true

from mtest.cli.parser import MTEST_VERSION
from mtest.model.attribution import AttributionDisposition
from mtest.model.events import Event, Summary
from mtest.model.node_id import NodeId
from mtest.model.outcome import Outcome
from mtest.model.parse_disposition import ParseDisposition
from mtest.model.test_counts import TestCounts
from mtest.model.test_result import TestResult
from mtest.report.json_stream import serialize_event, stream_header


# --- Small builders ---------------------------------------------------------


def _bytes(s: String) -> List[UInt8]:
    """The UTF-8 bytes of `s` as an owned list."""
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _fill(value: UInt8, n: Int) -> List[UInt8]:
    """A list of `n` copies of `value`."""
    var out = List[UInt8]()
    for _ in range(n):
        out.append(value)
    return out^


def _repeat(unit: String, n: Int) -> String:
    """`unit` repeated `n` times, built by doubling (O(log n) concatenations).
    """
    var out = String("")
    var block = unit
    var k = n
    while k > 0:
        if k & 1 == 1:
            out += block
        k >>= 1
        if k > 0:
            var doubled = String("")
            doubled += block
            doubled += block
            block = doubled^
    return out^


def _min_file_finished(duration: Float64) -> String:
    """A minimal `file_finished` line carrying only `duration`, for *_us cells.
    """
    return serialize_event(
        Event.file_finished(
            "p",
            Outcome.PASS,
            duration,
            List[String](),
            0.0,
            List[UInt8](),
            List[UInt8](),
        )
    )


# --- Stream header ----------------------------------------------------------


def test_stream_header_exact() raises:
    var want = (
        '{"event":"stream","version":1,"generator":"mtest '
        + MTEST_VERSION
        + '"}'
    )
    assert_equal(stream_header(MTEST_VERSION), want)


def test_stream_header_escapes_version() raises:
    assert_equal(
        stream_header('1.0"\\x'),
        '{"event":"stream","version":1,"generator":"mtest 1.0\\"\\\\x"}',
    )


# --- Per-kind exact mapping -------------------------------------------------


def test_session_started_exact() raises:
    var e = Event.session_started("root/dir", "mojo 1.0", 3, 1, "2/5", 4)
    assert_equal(
        serialize_event(e),
        '{"event":"session_started","root":"root/dir","toolchain":"mojo'
        + ' 1.0","selected_count":3,"excluded_count":1,"shard_label":"2/5",'
        + '"sharded_out_count":4}',
    )


def test_session_started_escapes_strings() raises:
    var e = Event.session_started('a"b', "t", 0, 0)
    assert_true('"root":"a\\"b"' in serialize_event(e))


def test_warning_exact() raises:
    var e = Event.warning("stale_exclude", "*.mojo")
    assert_equal(
        serialize_event(e),
        '{"event":"warning","warning_kind":"stale_exclude",'
        + '"warning_pattern":"*.mojo"}',
    )


def test_precompile_failed_exact() raises:
    var e = Event.precompile_failed(
        "build",
        "boom",
        0,
        ["a.mojo", "b.mojo"],
        True,
        2,
        0,
        True,
        5,
        2,
    )
    assert_equal(
        serialize_event(e),
        '{"event":"precompile_failed","step":"build","compiler_output":"boom",'
        + '"compiler_output_omitted_bytes":0,"casualty_count":2,"casualties":'
        + '["a.mojo","b.mojo"],"casualties_omitted":0,'
        + '"casualties_omitted_bytes":0,"ending_known":true,'
        + '"term_kind":2,"term_value":0,"escalated":true,"timeout_us":5000000,'
        + '"attempts_used":2}',
    )


def test_file_started_exact() raises:
    assert_equal(
        serialize_event(Event.file_started("tests/x.mojo")),
        '{"event":"file_started","path":"tests/x.mojo"}',
    )


def test_file_finished_exact() raises:
    var e = Event.file_finished(
        "t/a.mojo",
        Outcome.PASS,
        1.5,
        ["mojo", "build"],
        0.5,
        _bytes("hi"),
        _bytes(""),
        passed_tests=2,
        skipped_tests=1,
        parse_disposition=ParseDisposition.PARSED,
    )
    assert_equal(
        serialize_event(e),
        '{"event":"file_finished","path":"t/a.mojo","outcome":"pass",'
        + '"duration_us":1500000,"build_argv":["mojo","build"],'
        + '"build_argv_omitted":0,"build_argv_omitted_bytes":0,'
        + '"build_duration_us":500000,'
        + '"captured_stdout":"hi","stdout_capture_bytes":2,'
        + '"stdout_stream_omitted_bytes":0,"captured_stderr":"",'
        + '"stderr_capture_bytes":0,"stderr_stream_omitted_bytes":0,'
        + '"stdout_truncated":false,"stderr_truncated":false,"signal_number":0,'
        + '"exit_status":0,"timeout_us":0,"exclusion_pattern":"",'
        + '"parse_disposition":"parsed","passed_tests":2,"failed_tests":0,'
        + '"skipped_tests":1,"deselected_tests":0,"attempts_used":1,'
        + '"flaky":false,"slow":false,"escalated":false}',
    )


def test_attempt_finished_exact() raises:
    var e = Event.attempt_finished(
        "t/a.mojo",
        "run",
        1,
        3,
        1,
        11,
        1,
        9,
        True,
        True,
        "signal",
        0.25,
        _bytes("out"),
        _bytes("err"),
        False,
        True,
        ["./a"],
    )
    assert_equal(
        serialize_event(e),
        '{"event":"attempt_finished","path":"t/a.mojo","step":"run",'
        + '"attempt_index":1,"attempts_planned":3,"term_kind":1,"term_value":11,'
        + '"term_final_kind":1,"term_final_value":9,"escalated":true,'
        + '"retry_eligible":true,"classification":"signal","duration_us":250000,'
        + '"captured_stdout":"out","captured_stderr":"err",'
        + '"stdout_truncated":false,"stderr_truncated":true,'
        + '"attempt_argv":["./a"],"attempt_argv_omitted":0,'
        + '"attempt_argv_omitted_bytes":0}',
    )


def test_crash_attribution_exact() raises:
    var e = Event.crash_attribution(
        "t/a.mojo", AttributionDisposition.ATTRIBUTED, "test_x", 3, 2.0
    )
    assert_equal(
        serialize_event(e),
        '{"event":"crash_attribution","path":"t/a.mojo",'
        + '"attribution_disposition":"attributed","culprit_test":"test_x",'
        + '"isolation_reruns":3,"attribution_us":2000000}',
    )


def test_collection_known_exact() raises:
    assert_equal(
        serialize_event(Event.collection_known(10, 2)),
        '{"event":"collection_known","selected_test_total":10,'
        + '"deselected_test_total":2}',
    )


def test_internal_error_exact() raises:
    assert_equal(
        serialize_event(Event.internal_error("build", "mojo", 2)),
        '{"event":"internal_error","step":"build","program":"mojo","errno":2}',
    )


def test_test_reported_exact() raises:
    var tr = TestResult(
        NodeId("t/a.mojo", "test_x"), Outcome.FAIL, "boom", "1ms"
    )
    assert_equal(
        serialize_event(Event.test_reported(tr^)),
        '{"event":"test_reported","path":"t/a.mojo","name":"test_x",'
        + '"outcome":"fail","detail":"boom","detail_omitted_bytes":0,'
        + '"timing":"1ms"}',
    )


def test_session_finished_exact() raises:
    var counts: List[Int] = [5, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    var e = Event.session_finished(
        Summary(counts^), 3.0, 1, TestCounts(5, 1, 0, 0), 0
    )
    assert_equal(
        serialize_event(e),
        '{"event":"session_finished","summary":{"pass":5,"fail":1,"skip":0,'
        + '"crash":0,"timeout":0,"compile_error":0,"compile_timeout":0,'
        + '"malformed_suite":0,"precompile_error":0,"flaky":0,"deselected":0,'
        + '"excluded":0,"not_run":0},"wall_time_us":3000000,"exit_code":1,'
        + '"test_counts":{"passed":5,"failed":1,"skipped":0,"deselected":0},'
        + '"flaky_files":0}',
    )


# --- Frozen token vocabularies ----------------------------------------------


def test_every_outcome_token() raises:
    var tokens: List[String] = [
        "pass",
        "fail",
        "skip",
        "crash",
        "timeout",
        "compile_error",
        "compile_timeout",
        "malformed_suite",
        "precompile_error",
        "flaky",
        "deselected",
        "excluded",
        "not_run",
    ]
    for code in range(Outcome.COUNT):
        var tr = TestResult(NodeId("p", "n"), Outcome(code))
        var line = serialize_event(Event.test_reported(tr^))
        assert_true(('"outcome":"' + tokens[code] + '"') in line)


def test_flaky_is_first_class_pass_outcome() raises:
    var e = Event.file_finished(
        "p",
        Outcome.FLAKY,
        0.0,
        List[String](),
        0.0,
        List[UInt8](),
        List[UInt8](),
        attempts_used=2,
        flaky=True,
    )
    var line = serialize_event(e)
    assert_true('"outcome":"flaky"' in line)
    assert_true('"flaky":true' in line)
    assert_true('"attempts_used":2' in line)


def test_every_parse_disposition_token() raises:
    var tokens: List[String] = [
        "parsed",
        "no_report",
        "ambiguous",
        "drift",
        "capture_overflow",
    ]
    for code in range(ParseDisposition.COUNT):
        var e = Event.file_finished(
            "p",
            Outcome.PASS,
            0.0,
            List[String](),
            0.0,
            List[UInt8](),
            List[UInt8](),
            parse_disposition=ParseDisposition(code),
        )
        assert_true(
            ('"parse_disposition":"' + tokens[code] + '"') in serialize_event(e)
        )


def test_every_attribution_disposition_token() raises:
    var tokens: List[String] = [
        "attributed",
        "no_reproduction",
        "probe_failed",
        "run_cap",
        "time_budget",
    ]
    for code in range(AttributionDisposition.COUNT):
        var e = Event.crash_attribution(
            "p", AttributionDisposition(code), "", 0, 0.0
        )
        assert_true(
            ('"attribution_disposition":"' + tokens[code] + '"')
            in serialize_event(e)
        )


# --- Duration (*_us) conversion cells ---------------------------------------


def test_duration_us_round_half_away_from_zero() raises:
    # 0.0000005 s = 0.5 us rounds AWAY from zero to 1 us.
    assert_true('"duration_us":1' in _min_file_finished(0.0000005))


def test_duration_us_clamps_negative_to_zero() raises:
    assert_true('"duration_us":0' in _min_file_finished(-1.0))


def test_duration_us_zero() raises:
    assert_true('"duration_us":0' in _min_file_finished(0.0))


def test_duration_us_normal_value() raises:
    assert_true('"duration_us":2500000' in _min_file_finished(2.5))


def test_duration_us_saturates() raises:
    # 1e13 s * 1e6 overflows Int; the conversion saturates at 2**63 - 1.
    assert_true(
        '"duration_us":9223372036854775807' in _min_file_finished(1.0e13)
    )


def test_timeout_us_from_integer_seconds() raises:
    var e = Event.file_finished(
        "p",
        Outcome.TIMEOUT,
        0.0,
        List[String](),
        0.0,
        List[UInt8](),
        List[UInt8](),
        timeout_seconds=7,
    )
    assert_true('"timeout_us":7000000' in serialize_event(e))


def test_timeout_us_saturates() raises:
    var e = Event.file_finished(
        "p",
        Outcome.TIMEOUT,
        0.0,
        List[String](),
        0.0,
        List[UInt8](),
        List[UInt8](),
        timeout_seconds=10000000000000,
    )
    assert_true('"timeout_us":9223372036854775807' in serialize_event(e))


# --- Per-kind bounds and omission metadata ----------------------------------


def test_captured_stream_head_tail_bound() raises:
    # Head window of 'a', a dropped middle of 'Z', tail window of 'b'. 'Z' is
    # absent from every field name/token, so its absence proves the middle was
    # dropped; the head/tail junction 'a…b' proves the elision marker sits
    # between the retained windows.
    var data = List[UInt8]()
    data += _fill(0x61, 65536)  # head 'a'
    data += _fill(0x5A, 10)  # dropped middle 'Z'
    data += _fill(0x62, 65536)  # tail 'b'
    var e = Event.file_finished(
        "p",
        Outcome.PASS,
        0.0,
        List[String](),
        0.0,
        data^,
        List[UInt8](),
        stdout_truncated=True,
    )
    var line = serialize_event(e)
    assert_true(('"captured_stdout":"' + _repeat("a", 200)) in line)  # head 'a'
    assert_true("a…b" in line)  # head window, marker, tail window adjacency
    assert_true(
        (_repeat("b", 200) + '","stdout_capture_bytes":131082') in line
    )  # tail 'b' then the retained-capture byte count
    assert_true('"stdout_stream_omitted_bytes":10' in line)
    assert_false("Z" in line)  # dropped middle is gone
    assert_true('"stdout_truncated":true' in line)


def test_captured_stream_exact_fit_not_bounded() raises:
    var data = _fill(0x61, 131072)  # exactly head+tail, nothing dropped
    var e = Event.file_finished(
        "p",
        Outcome.PASS,
        0.0,
        List[String](),
        0.0,
        data^,
        List[UInt8](),
    )
    var line = serialize_event(e)
    assert_true('"stdout_capture_bytes":131072' in line)
    assert_true('"stdout_stream_omitted_bytes":0' in line)
    assert_false("…" in line)


def test_detail_head_tail_bound() raises:
    var detail = _repeat("a", 65536) + _repeat("Z", 10) + _repeat("b", 65536)
    var tr = TestResult(NodeId("p", "n"), Outcome.FAIL, detail, "")
    var line = serialize_event(Event.test_reported(tr^))
    assert_true(('"detail":"' + _repeat("a", 200)) in line)  # head window
    assert_true("a…b" in line)  # marker between windows
    assert_true(
        (_repeat("b", 200) + '","detail_omitted_bytes":10') in line
    )  # tail window then the omitted count
    assert_false("Z" in line)  # dropped middle is gone


def test_compiler_output_head_tail_bound() raises:
    var out = _repeat("a", 65536) + _repeat("Z", 5) + _repeat("b", 65536)
    var e = Event.precompile_failed("build", out, 0)
    var line = serialize_event(e)
    assert_true(('"compiler_output":"' + _repeat("a", 200)) in line)  # head
    assert_true("a…b" in line)  # marker between windows
    assert_true(
        (_repeat("b", 200) + '","compiler_output_omitted_bytes":5') in line
    )  # tail window then the omitted count
    assert_false("Z" in line)  # dropped middle is gone


def test_argv_list_and_element_bounds() raises:
    var argv = List[String]()
    argv.append(_repeat("b", 5000))  # element exceeds the 4 KiB element cap
    for _ in range(299):
        argv.append("x")  # 300 entries total exceeds the 256 list cap
    var e = Event.file_finished(
        "p",
        Outcome.PASS,
        0.0,
        argv^,
        0.0,
        List[UInt8](),
        List[UInt8](),
    )
    var line = serialize_event(e)
    # The over-long element is kept as a head+tail window (3072 + 1024 = 4096
    # retained bytes) with the visible elision marker between, never a silent
    # cut: the longest contiguous run is the 3072-byte head, and the dropped
    # middle bytes (5000 - 4096 = 904) ride in build_argv_omitted_bytes.
    assert_true(_repeat("b", 3072) in line)  # the head window
    assert_false(_repeat("b", 3073) in line)  # nothing longer survives
    assert_true("…" in line)  # the visible elision marker
    assert_true('"build_argv_omitted":44' in line)  # 300 - 256 entries
    assert_true('"build_argv_omitted_bytes":904' in line)  # 5000 - 4096 bytes


def test_scalar_runner_string_is_visibly_bounded_not_silently_cut() raises:
    # A pathological scalar runner field (here a 5000-byte path) is kept as a
    # head+tail window with the visible elision marker, never silently truncated
    # to a value indistinguishable from a genuine 4 KiB one.
    var e = Event.file_started(_repeat("p", 5000))
    var line = serialize_event(e)
    assert_true(_repeat("p", 3072) in line)  # the head window survives
    assert_false(_repeat("p", 3073) in line)  # nothing longer
    assert_true("…" in line)  # truncation is visible in the value itself


def test_casualties_list_bound_count_authoritative() raises:
    var casualties = List[String]()
    for _ in range(300):
        casualties.append("dep.mojo")
    var e = Event.precompile_failed("build", "", 0, casualties^)
    var line = serialize_event(e)
    assert_true('"casualty_count":300' in line)  # authoritative, not derived
    assert_true('"casualties_omitted":44' in line)


# --- Hostile payloads -------------------------------------------------------


def test_hostile_captured_bytes_escaped_and_ndjson_safe() raises:
    var data = _bytes('a"b\\c\n\t' + chr(0) + '{"event":"fake"}')
    data.append(0xFF)  # invalid UTF-8, pre-lossy
    var e = Event.file_finished(
        "p",
        Outcome.CRASH,
        0.0,
        List[String](),
        0.0,
        data^,
        List[UInt8](),
    )
    var line = serialize_event(e)
    # The whole record is still ONE line: every control byte is escaped, so a
    # smuggled newline cannot forge a second NDJSON record.
    assert_false("\n" in line)
    assert_true('a\\"b\\\\c\\n\\t' in line)
    assert_true("\\u0000" in line)
    assert_true(
        '{\\"event\\":\\"fake\\"}' in line
    )  # NDJSON-lookalike neutralized
    assert_true("�" in line)  # invalid byte became U+FFFD


def test_hostile_quote_backslash_storm_in_path() raises:
    var e = Event.file_started('"\\"\\"\\')
    assert_true('"path":"\\"\\\\\\"\\\\\\"\\\\"' in serialize_event(e))
