"""The pure verdict-mapping functions of the session layer (Layer 4).

The session's whole honesty rests on keeping the four run endings distinct — a
crash is never a failure, our deadline kill is never a crash, a spawn failure is
never a test outcome at all — and on treating a compiler that dies by a signal
as a BUILD failure, never a test crash. Those two mappings are isolated here as
pure, total functions so they can be table-tested over every `Termination` kind
independently of any process, filesystem, or reporter.

Neither function performs I/O or raises; each is total over the termination
kinds. Both borrow two vocabulary values as internal SENTINELS the orchestrator
branches on but never emits as a file's outcome:

- `run_verdict` returns `NOT_RUN` for a `SpawnFailed` run — the orchestrator
  checks `is_spawn_failed()` first and treats it as an internal error (exit 3),
  so this value is only a total-function placeholder, never recorded.
- `build_verdict` returns `PASS` for a clean build ("proceed to the run step")
  and `NOT_RUN` for a `SpawnFailed` build (internal error, exit 3); the only
  real reported outcome it yields is `COMPILE_ERROR`.
"""
from mtest.exec import Termination
from mtest.model import Outcome


def run_verdict(t: Termination) -> Outcome:
    """Map a RUN termination to the file's reported outcome.

    Total over the termination kinds and pure:

    - `Exited(0)` -> `PASS`; `Exited(nonzero)` -> `FAIL`.
    - `Signaled(_)` -> `CRASH` (a real crash, never a failure).
    - `TimedOut` -> `TIMEOUT` (our deadline killed it).
    - `SpawnFailed` -> `NOT_RUN` sentinel; the caller checks `is_spawn_failed()`
      first and treats it as an internal error, so this is never recorded.

    Args:
        t: How the supervised run ended. Not mutated.

    Returns:
        The reported `Outcome` for the run. Does not raise.
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
    """Map a BUILD termination to a build signal (pure, total).

    - `Exited(0)` -> `PASS` sentinel: the build succeeded, proceed to the run.
    - `Exited(nonzero)` or `Signaled(_)` -> `COMPILE_ERROR` (a compiler that
      dies by a signal is a BUILD failure, never a test crash).
    - `SpawnFailed` -> `NOT_RUN` sentinel: could not spawn the compiler; the
      caller checks `is_spawn_failed()` first and treats it as an internal
      error (exit 3).

    Args:
        t: How the supervised build ended. Not mutated.

    Returns:
        `PASS` to proceed, `COMPILE_ERROR` on a failed build, or the `NOT_RUN`
        spawn sentinel. Does not raise.
    """
    if t.is_exited() and t.value == 0:
        return Outcome.PASS
    if t.is_spawn_failed():
        # Could not spawn the compiler; a sentinel the caller routes to exit 3.
        return Outcome.NOT_RUN
    # Exited(nonzero), Signaled(_), or (interrupt-induced) TimedOut: a build
    # failure. A compiler that dies by a signal is a COMPILE_ERROR, not a crash.
    return Outcome.COMPILE_ERROR
