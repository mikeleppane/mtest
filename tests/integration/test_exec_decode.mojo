"""Termination decode for `exec`: exit vs signal, spawn-failure vs genuine 127.

Asserts the structural status decode keeps a crash distinct from a failure and a
spawn failure distinct from a genuine nonzero exit:
- `/bin/false` exits 1 -> `Exited(1)`;
- the self-signaler dies by SIGABRT -> `Signaled(6)`, never an exit code;
- a nonexistent binary -> `SpawnFailed(ENOENT=2)` via the errno pipe;
- a process that genuinely exits 127 -> `Exited(127)`, NOT `SpawnFailed`.
"""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.exec import ExecRuntime, ProcessSpec, run_supervised

from exec_helpers import target, py_spec


def test_clean_nonzero_exit_is_exited() raises:
    var runtime = ExecRuntime()
    var argv = List[String]()
    argv.append("/bin/false")
    var r = run_supervised(runtime, ProcessSpec.command(argv^))
    runtime.close()
    assert_true(r.termination.is_exited(), String(r.termination))
    assert_equal(r.termination.value, 1)


def test_true_exits_zero() raises:
    var runtime = ExecRuntime()
    var argv = List[String]()
    argv.append("/bin/true")
    var r = run_supervised(runtime, ProcessSpec.command(argv^))
    runtime.close()
    assert_true(r.termination.is_exited(), String(r.termination))
    assert_equal(r.termination.value, 0)


def test_signal_death_is_signaled_not_exit() raises:
    var runtime = ExecRuntime()
    var argv = List[String]()
    argv.append(target("self_signaler.py"))
    var r = run_supervised(runtime, py_spec(argv^))
    runtime.close()
    assert_true(r.termination.is_signaled(), String(r.termination))
    assert_equal(r.termination.value, 6)  # SIGABRT
    # A crash is not a failure: it never surfaces as an exit code.
    assert_true(not r.termination.is_exited(), String(r.termination))


def test_nonexistent_binary_is_spawn_failed() raises:
    var runtime = ExecRuntime()
    var argv = List[String]()
    argv.append("/nonexistent/mtest_no_such_binary")
    var r = run_supervised(runtime, ProcessSpec.command(argv^))
    runtime.close()
    assert_true(r.termination.is_spawn_failed(), String(r.termination))
    assert_equal(r.termination.value, 2)  # ENOENT


def test_genuine_exit_127_is_exited_not_spawn_failed() raises:
    var runtime = ExecRuntime()
    var argv = List[String]()
    argv.append("python3")
    argv.append("-c")
    argv.append("import sys; sys.exit(127)")
    var r = run_supervised(runtime, ProcessSpec.command(argv^))
    runtime.close()
    assert_true(r.termination.is_exited(), String(r.termination))
    assert_equal(r.termination.value, 127)
    assert_true(not r.termination.is_spawn_failed(), String(r.termination))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
