"""A continuously flooding grandchild can never spin the supervisor forever.

A grandchild that inherited the supervised stdout pipe and writes to it in a
tight, never-ending loop keeps `read` returning data indefinitely. Two paths must
stay responsive under that pressure:

- Post-reap: the leader exits 0 and is reaped at once, but the grandchild floods
  on. The supervisor sweeps the process group BEFORE the post-reap drain, closing
  the grandchild's write end so the drain reaches EOF and returns promptly — with
  the reported status still the leader's real clean `Exited(0)`.
- In-run: the leader stays alive while the grandchild floods. A single drain reads
  only a bounded slice and returns, so the deadline is re-checked every slice and
  the run times out promptly instead of the reader starving the clock.

Both assertions carry a hard wall-clock bound: a regression that lets either path
spin does not merely fail these — it hangs, which is the intended loud signal.
"""
from std.testing import assert_equal, assert_true, assert_false

from mtest.exec import ExecRuntime, run_supervised

from exec_helpers import target, py_spec


def test_flooding_grandchild_post_reap_returns_promptly() raises:
    var runtime = ExecRuntime()
    runtime.open()
    # NO timeout: the leader exits 0 immediately and is reaped. The grandchild
    # floods stdout forever. Before the group-sweep-first fix this hangs in the
    # post-reap drain; after it, the sweep closes the write end and the drain ends.
    var argv = List[String]()
    argv.append(target("flooding_grandchild.py"))
    argv.append("exit0")
    var r = run_supervised(runtime, py_spec(argv^, 0))
    runtime.close()
    # Cleanup only: the reported status is the leader's real clean exit.
    assert_true(r.termination.is_exited(), String(r.termination))
    assert_equal(r.termination.value, 0)
    assert_false(r.termination.is_timed_out(), String(r.termination))
    # Hard wall-clock bound: a spinning post-reap drain would never reach here.
    assert_true(r.duration_ms < 5000, String(r.duration_ms))


def test_flooding_grandchild_in_run_times_out_promptly() raises:
    var runtime = ExecRuntime()
    runtime.open()
    # Short timeout: the leader stays alive while the grandchild floods. A drain
    # that read to EOF (or unbounded) would starve the deadline check forever;
    # the bounded per-slice drain returns so the deadline fires and we time out.
    var argv = List[String]()
    argv.append(target("flooding_grandchild.py"))
    argv.append("alive")
    var r = run_supervised(runtime, py_spec(argv^, 200))
    runtime.close()
    assert_true(r.termination.is_timed_out(), String(r.termination))
    # Hard wall-clock bound: a spinning in-run drain would never reach here.
    assert_true(r.duration_ms < 5000, String(r.duration_ms))
