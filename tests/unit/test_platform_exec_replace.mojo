"""Failure-path regressions for the process-image replacement.

A successful `execv` would replace this test binary, so only the paths that
return are exercised here. Every target spelled below has a non-directory
component (`/dev/null` is a character device), which `execv` refuses with
`ENOTDIR` on both supported platforms: a target that merely does not exist
today could exist on someone's machine tomorrow, and a target that could be
executed would destroy the test runner the moment a guard regressed.
"""
from std.testing import assert_raises, TestSuite

from mtest.platform import exec_replace

comptime _UNREACHABLE = "/dev/null/mtest-debug-binary"
"""A path `execv` cannot resolve by construction: `/dev/null` is not a directory.
"""

comptime _EXECV_FAILED = (
    "exec: execv failed for '/dev/null/mtest-debug-binary' (errno 20)"
)
"""The whole expected message. `ENOTDIR` is 20 on both Linux and Darwin, and the
path and the errno are the entire diagnostic value of the failure.
"""


def test_exec_replace_reports_the_path_and_errno_when_execv_fails() raises:
    var argv: List[String] = ["definitely-not-here"]
    with assert_raises(contains=_EXECV_FAILED):
        exec_replace(_UNREACHABLE, argv)


def test_exec_replace_refuses_empty_argv() raises:
    with assert_raises(contains="exec: empty argv"):
        exec_replace(_UNREACHABLE, List[String]())


def test_exec_replace_refuses_a_nul_byte_in_the_binary_path() raises:
    var argv: List[String] = ["arg0"]
    with assert_raises(contains="exec: NUL byte in the binary path"):
        exec_replace(_UNREACHABLE + "\0ignored", argv)


def test_exec_replace_refuses_a_nul_byte_in_an_argument() raises:
    var argv: List[String] = ["arg0", "before\0discarded"]
    with assert_raises(contains="exec: NUL byte in argv[1]"):
        exec_replace(_UNREACHABLE, argv)


def main() raises:
    """Run this module's tests through the stdlib suite."""
    TestSuite.discover_tests[__functions_in_module()]().run()
