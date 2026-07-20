"""Pin `ProcessSpec`'s deadline and SIGTERM-grace defaults (Layer 3).

The supervisor escalates SIGTERM -> SIGKILL after `spec.grace_ms`. The default is
the run path's 300 ms, and it is a DEFAULT rather than a constant so a build —
whose compiler may be mid-cache-write when the deadline fires — can ask for a
longer one without changing any other caller. These tests pin both halves of that
contract: every existing factory call site keeps the 300 ms grace it always had,
and an explicit grace threads through untouched.
"""
from std.testing import assert_equal, assert_true

from mtest.exec.spec import ProcessSpec


def test_command_defaults_are_no_deadline_and_the_run_grace() raises:
    var s = ProcessSpec.command(["/bin/true"])
    assert_equal(s.timeout_ms, 0)
    assert_equal(s.grace_ms, 300)


def test_command_in_defaults_are_no_deadline_and_the_run_grace() raises:
    var s = ProcessSpec.command_in(["/bin/true"], "/tmp")
    assert_equal(s.timeout_ms, 0)
    assert_equal(s.grace_ms, 300)


def test_command_threads_an_explicit_grace() raises:
    var s = ProcessSpec.command(["/bin/true"], 1000, 5000)
    assert_equal(s.timeout_ms, 1000)
    assert_equal(s.grace_ms, 5000)


def test_command_in_threads_an_explicit_grace() raises:
    var s = ProcessSpec.command_in(["/bin/true"], "/tmp", 1000, 5000)
    assert_equal(s.timeout_ms, 1000)
    assert_equal(s.grace_ms, 5000)
    assert_true(s.cwd)
    assert_equal(s.cwd.value(), "/tmp")


def test_a_deadline_without_a_grace_keeps_the_default_grace() raises:
    # The pre-existing two-argument call shape: passing a deadline alone must
    # not disturb the grace every current caller relies on.
    var s = ProcessSpec.command_in(["/bin/true"], "/tmp", 250)
    assert_equal(s.timeout_ms, 250)
    assert_equal(s.grace_ms, 300)
