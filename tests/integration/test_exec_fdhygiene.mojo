"""FD hygiene for `exec`: repeated spawns must not leak file descriptors.

The runner spawns one child per file in one long-lived process, so a single
leaked pipe end per spawn accumulates without bound. This runs many supervised
spawns and asserts the process's open-fd count does not grow. Also exercises a
plain construct-and-drop of a `ProcessResult` to prove its owned buffers release
cleanly.
"""
from std.os import listdir
from std.testing import assert_true, assert_equal, TestSuite

from mtest.exec import ExecRuntime, ProcessSpec, ProcessResult, run_supervised
from mtest.exec.termination import Termination


def _open_fd_count() raises -> Int:
    """How many fds this process currently has open (via /proc/self/fd)."""
    var n = 0
    for _ in listdir("/proc/self/fd"):
        n += 1
    return n


def test_repeated_spawns_do_not_leak_fds() raises:
    var runtime = ExecRuntime()
    runtime.open()
    # Warm up once so any one-time mappings (the interrupt flag page) exist.
    var warm = List[String]()
    warm.append("/bin/true")
    _ = run_supervised(runtime, ProcessSpec.command(warm^))

    var before = _open_fd_count()
    for _ in range(100):
        var argv = List[String]()
        argv.append("/bin/true")
        var r = run_supervised(runtime, ProcessSpec.command(argv^))
        assert_true(r.termination.is_exited(), String(r.termination))
    var after = _open_fd_count()
    runtime.close()
    # No growth: every pipe end opened per spawn is closed on every path.
    assert_true(
        after <= before,
        String("fd leak: before=") + String(before) + " after=" + String(after),
    )


def test_process_result_construct_and_drop() raises:
    # Construct with owned buffers and let it drop — no leak, no crash.
    for _ in range(3):
        var out = List[UInt8]()
        out.append(UInt8(65))
        var err = List[UInt8]()
        var pr = ProcessResult(
            out^, err^, False, False, Termination.exited(0), 5
        )
        assert_equal(len(pr.stdout_bytes), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
