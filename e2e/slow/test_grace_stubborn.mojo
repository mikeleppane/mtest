"""Known-outcome fixture: the blocked child every interrupt scenario arms.

Verdict TIMEOUT, exit-class 1. It sorts after `test_first_pass.mojo` and before
every other file under slow/, so a sequential walk reaches it with exactly one
completed PASS behind it and every remaining file unscheduled — the exact shape
the interrupt accounting is asserted against.

Two properties make those scenarios exact instead of timed:

* it records its OWN process-group id, so the harness can prove the group mtest
  owned is gone afterwards — and, after a fatal SIGKILL that mtest cannot clean
  up after, can tear that group down itself;
* it announces readiness only after both the disposition and the recorded id are
  in place, and it does so from the test body, so only a real RUN of the built
  binary can create that marker.

It also IGNORES SIGTERM, so mtest's polite teardown signal cannot end it and the
run-step escalation to SIGKILL is forced rather than incidental.

Reached only by the interrupt scenarios; no default scenario walks slow/, so it
can never hang CI.
"""
from std.ffi import external_call
from std.os import getenv
from std.testing import TestSuite
from std.time import sleep

comptime PGID_FILE_ENV = "MTEST_SLOW_PGID_FILE"
"""Environment name whose value, when non-empty, receives this group's id."""
comptime READY_FILE_ENV = "MTEST_SLOW_READY_FILE"
"""Environment name whose value, when non-empty, is the readiness marker."""


def _write_marker(path: String, text: String) raises:
    """Write one marker file whole.

    Args:
        path: The absolute marker path the harness armed.
        text: The marker's contents.

    Raises:
        Error: If the marker cannot be created.
    """
    with open(path, "w") as handle:
        handle.write(text)


def test_blocks_until_it_is_killed() raises:
    # SAFETY: libc `signal(int signum, void (*handler)(int))` — the handler slot
    # takes the constant `SIG_IGN` (1), passed here as the integer it is defined
    # to be. Under the platform C ABI both arguments are register-passed, so an
    # integer 1 lands in the handler register exactly as the C constant would.
    # SIGTERM (15) is the only signal disarmed, nothing is dereferenced, and no
    # handler ever runs. Unlike a per-thread signal mask, the disposition is
    # process-wide, which is what makes this process genuinely deaf to the
    # polite signal.
    _ = external_call["signal", Int](Int32(15), Int(1))

    var pgid_path = getenv(PGID_FILE_ENV, "")
    if pgid_path.byte_length() != 0:
        # SAFETY: `getpgrp()` takes no argument and returns this process's own
        # process-group id by value; no pointer or ownership crosses the call.
        var pgid = Int(external_call["getpgrp", Int32]())
        _write_marker(pgid_path, String(pgid) + "\n")

    # Announced LAST: readiness must imply that the disposition is installed and
    # the group id is already durable, so a harness signalling on this marker
    # cannot race either of them.
    var ready_path = getenv(READY_FILE_ENV, "")
    if ready_path.byte_length() != 0:
        _write_marker(ready_path, "ready\n")

    while True:
        sleep(3600.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
