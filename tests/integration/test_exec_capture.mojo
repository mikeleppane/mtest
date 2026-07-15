"""Capture invariants for `exec`: byte-exact separation, concurrent drain, bound.

Runs committed helper targets and asserts the captured bytes exactly: the two
streams stay separate and byte-exact under the bound (trailing spaces and empty
argv entries survive), a large dual-stream flood drains without deadlock, and
output past a lowered bound is truncated to head + marker + tail.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from mtest.config import lossy_utf8
from mtest.exec import ProcessSpec, ProcessResult, run_supervised
from mtest.exec.capture import BoundedCapture

from exec_helpers import bytes_to_str, count_byte, repeat, target, py_spec


def _push_n(mut cap: BoundedCapture, b: UInt8, n: Int):
    for _ in range(n):
        cap.push_byte(b)


def test_capture_below_bound_not_truncated_byte_exact() raises:
    # 150 bytes into a 200-byte bound: nothing dropped.
    var cap = BoundedCapture(100, 100)
    _push_n(cap, UInt8(ord("x")), 150)
    assert_false(cap.was_truncated())
    var out = cap.finish()
    assert_equal(len(out), 150)
    assert_equal(count_byte(out, UInt8(ord("x"))), 150)


def test_capture_at_bound_not_truncated() raises:
    # Exactly the bound (100 head + 100 tail): still nothing dropped.
    var cap = BoundedCapture(100, 100)
    _push_n(cap, UInt8(ord("y")), 200)
    assert_false(cap.was_truncated())
    assert_equal(len(cap.finish()), 200)


def test_capture_over_bound_truncated_marker() raises:
    # One byte past the bound: the middle drops and the marker is spliced.
    var cap = BoundedCapture(100, 100)
    _push_n(cap, UInt8(ord("z")), 201)
    assert_true(cap.was_truncated())
    assert_true("[mtest: output truncated" in bytes_to_str(cap.finish()))


def test_byte_exact_separate_capture() raises:
    var argv = List[String]()
    argv.append(target("argv_echoer.py"))
    argv.append("hello world")
    argv.append("trailing ")  # trailing space must survive
    argv.append("")  # empty argv entry must survive
    argv.append("x")
    var r = run_supervised(py_spec(argv^))
    assert_true(r.termination.is_exited(), String(r.termination))
    assert_equal(
        bytes_to_str(r.stdout_bytes),
        "[hello world]\n[trailing ]\n[]\n[x]\n",
    )
    # The streams are captured separately: stderr holds only its own marker.
    assert_equal(bytes_to_str(r.stderr_bytes), "ARGV_ECHOER_STDERR\n")
    # A normal run well under the bound: neither stream is flagged truncated.
    assert_false(r.stdout_truncated)
    assert_false(r.stderr_truncated)


def test_dual_stream_drain_no_deadlock() raises:
    var argv = List[String]()
    argv.append(target("dual_flooder.py"))
    var r = run_supervised(py_spec(argv^))
    assert_true(r.termination.is_exited(), String(r.termination))
    assert_equal(r.termination.value, 0)
    # 256 KiB per stream, each a single distinct byte value: separate + exact.
    assert_equal(len(r.stdout_bytes), 256 * 1024)
    assert_equal(len(r.stderr_bytes), 256 * 1024)
    assert_equal(count_byte(r.stdout_bytes, UInt8(ord("o"))), 256 * 1024)
    assert_equal(count_byte(r.stderr_bytes, UInt8(ord("e"))), 256 * 1024)


def test_capture_bound_truncates_head_tail_marker() raises:
    # 100 'a', 300 'b', 100 'c' with a 200-byte bound (100 head + 100 tail).
    var code = String(
        'import sys; sys.stdout.write("a"*100 + "b"*300 + "c"*100)'
    )
    var argv = List[String]()
    argv.append("python3")
    argv.append("-c")
    argv.append(code)
    var r = run_supervised(ProcessSpec.command(argv^), capture_bound_bytes=200)
    var s = bytes_to_str(r.stdout_bytes)
    # Head survives, tail survives, middle dropped, marker present.
    assert_true(s.startswith(repeat("a", 100)), s)
    assert_true(s.endswith(repeat("c", 100)), s)
    assert_false(repeat("b", 10) in s, s)  # the 'b' middle block is gone
    assert_true("[mtest: output truncated" in s, s)
    # The overflow is surfaced structurally: stdout flagged, quiet stderr is not.
    assert_true(r.stdout_truncated, s)
    assert_false(r.stderr_truncated, bytes_to_str(r.stderr_bytes))


def test_under_bound_is_byte_exact() raises:
    var code = String('import sys; sys.stdout.write("x"*150)')
    var argv = List[String]()
    argv.append("python3")
    argv.append("-c")
    argv.append(code)
    var r = run_supervised(ProcessSpec.command(argv^), capture_bound_bytes=200)
    assert_equal(len(r.stdout_bytes), 150)
    assert_equal(count_byte(r.stdout_bytes, UInt8(ord("x"))), 150)
    assert_false("truncated" in bytes_to_str(r.stdout_bytes))
    assert_false(r.stdout_truncated)


def test_lossy_utf8_replaces_invalid_preserves_valid() raises:
    # Valid ASCII + a lone 0xFF (invalid) + valid UTF-8 'é' (0xC3 0xA9).
    var b = List[UInt8]()
    b.append(UInt8(ord("h")))
    b.append(0xFF)
    b.append(0xC3)
    b.append(0xA9)
    var s = lossy_utf8(b)
    assert_true(s.startswith("h"), s)
    assert_true("�" in s, s)  # replacement char for 0xFF
    assert_true(s.endswith("é"), s)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
