"""Pre-exec resolution for `exec`: the deadline loop, not a blocking read,
governs spawn-failed vs exec-ran.

The errno channel that distinguishes a spawn failure (4 bytes) from a successful
exec (close-on-exec EOF) is resolved INSIDE the deadline/interrupt loop, not by a
blocking pre-read. A blocking read there would hang the parent past its deadline
if a child stalled between fork and exec, and SA_RESTART on the handlers means
Ctrl-C could not break it either.

Limitation (documented, not skipped): a FAITHFUL pre-exec stall is not portably
constructible from a committed helper. The errno pipe's write end is O_CLOEXEC,
so its EOF is delivered at the instant `exec` succeeds — before any helper code
runs — so no python target can hold that resolution open. This test therefore
asserts the strongest reachable property: with resolution folded into the loop, a
run whose child exec's and then hangs is still ended promptly by the deadline
(the loop governs), and its duration tracks the deadline rather than the child's
full hang. The spawn-failed (4-byte) and exec-ran (EOF) branches of the same loop
are pinned by the decode tests, which still pass after the refactor.
"""
from std.testing import assert_true, TestSuite

from mtest.exec import ExecRuntime, run_supervised

from exec_helpers import target, py_spec


def test_deadline_governs_the_run_not_a_blocking_preread() raises:
    var runtime = ExecRuntime()
    var argv = List[String]()
    argv.append(target("sleeper.py"))
    # Exec resolves at once (EOF), then the child hangs 300s; a short deadline
    # must end it via the loop, so the duration tracks the deadline, not 300s.
    var r = run_supervised(runtime, py_spec(argv^, 200))
    runtime.close()
    assert_true(r.termination.is_timed_out(), String(r.termination))
    assert_true(r.duration_ms < 5000, String(r.duration_ms))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
