"""The verdict-mapping functions of the session layer.

The session's honesty rests on keeping the four run endings distinct: a crash is
never a failure, our deadline kill is never a crash, and a spawn failure is not
a test outcome at all. It also rests on treating a compiler that dies by a
signal as a build failure rather than a test crash. Those two mappings are
isolated here as pure, total functions, so they can be table-tested over every
`Termination` kind independently of any process, filesystem, or reporter.

Both borrow two vocabulary values as internal sentinels that the orchestrator
branches on but never emits as a file's outcome:

- `run_verdict` returns `NOT_RUN` for a `SpawnFailed` run. The orchestrator
  checks `is_spawn_failed()` first and treats it as an internal error (exit 3),
  so this value is a total-function placeholder and is never recorded.
- `build_verdict` returns `PASS` for a clean build, meaning proceed to the run
  step, and `NOT_RUN` for a `SpawnFailed` build (internal error, exit 3). The
  outcomes it yields for reporting are `COMPILE_ERROR` and `COMPILE_TIMEOUT`.
"""
from mtest.exec import Termination
from mtest.model import Outcome


def run_verdict(t: Termination) -> Outcome:
    """Map a run termination to the file's reported outcome.

    Total over the termination kinds:

    - `Exited(0)` -> `PASS`; `Exited(nonzero)` -> `FAIL`.
    - `Signaled(_)` -> `CRASH`, a real crash rather than a failure.
    - `TimedOut` -> `TIMEOUT`, meaning our deadline killed it.
    - `SpawnFailed` -> the `NOT_RUN` sentinel. The caller checks
      `is_spawn_failed()` first and treats it as an internal error, so this
      value is never recorded.

    Args:
        t: How the supervised run ended.

    Returns:
        The reported `Outcome` for the run.
    """
    if t.is_exited():
        return Outcome.PASS if t.value == 0 else Outcome.FAIL
    if t.is_signaled():
        return Outcome.CRASH
    if t.is_timed_out():
        return Outcome.TIMEOUT
    # SpawnFailed: a sentinel only; the caller routes it to an internal error.
    return Outcome.NOT_RUN


def build_verdict(t: Termination) -> Outcome:
    """Map a build termination to a build signal. Total over the kinds.

    - `Exited(0)` -> the `PASS` sentinel: the build succeeded, proceed to the
      run step.
    - `TimedOut` -> `COMPILE_TIMEOUT`: we killed the build at
      `--compile-timeout`. The compiler never reached a verdict on the code, so
      reporting a `COMPILE_ERROR` would blame the source for our own deadline.
    - `Exited(nonzero)` or `Signaled(_)` -> `COMPILE_ERROR`. A compiler that
      dies by a signal is a build failure, not a test crash.
    - `SpawnFailed` -> the `NOT_RUN` sentinel: the compiler could not be
      spawned. The caller checks `is_spawn_failed()` first and treats it as an
      internal error (exit 3).

    An interrupt also surfaces as `TimedOut`, but the caller short-circuits an
    interrupt before consulting this function, so a `TimedOut` reaching here is
    always a genuine compile deadline.

    Args:
        t: How the supervised build ended.

    Returns:
        `PASS` to proceed, `COMPILE_TIMEOUT` for a deadline kill,
        `COMPILE_ERROR` on any other failed build, or the `NOT_RUN` spawn
        sentinel.
    """
    if t.is_exited() and t.value == 0:
        return Outcome.PASS
    if t.is_spawn_failed():
        # Could not spawn the compiler; a sentinel the caller routes to exit 3.
        return Outcome.NOT_RUN
    if t.is_timed_out():
        # Our own compile deadline killed it (an interrupt never reaches here).
        return Outcome.COMPILE_TIMEOUT
    # Exited(nonzero) or Signaled(_): a build failure. A compiler that dies by a
    # signal is a COMPILE_ERROR, not a crash.
    return Outcome.COMPILE_ERROR
