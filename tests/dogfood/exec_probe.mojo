"""Focused self-host probe for the linked native process supervisor."""
from std.testing import assert_equal, assert_true, TestSuite

from mtest.exec import ExecRuntime, ProcessSpec, run_supervised

from exec_helpers import true_binary


def test_supervisor_executes_a_child_to_exit_zero() raises:
    """The packaged Mojo layer reaches the linked native exec adapter."""
    var runtime = ExecRuntime()
    runtime.open()
    var argv = List[String]()
    argv.append(true_binary())
    var result = run_supervised(runtime, ProcessSpec.command(argv^))
    runtime.close()
    assert_true(result.termination.is_exited(), String(result.termination))
    assert_equal(result.termination.value, 0)


def main() raises:
    """Run this standalone probe through mtest's normal TestSuite protocol."""
    TestSuite.discover_tests[__functions_in_module()]().run()
