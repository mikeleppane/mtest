"""Known-outcome fixture: a test that IGNORES SIGTERM and then never returns.

The escalation proof. mtest's supervisor ends a step that blew its deadline with
a protocol, not a single signal: SIGTERM to the process group, a grace period
(300 ms on the run step), then SIGKILL if the group is still alive. A child that
dies politely on SIGTERM never exercises the second half of that protocol, so
this fixture refuses the polite signal — only SIGKILL can end it — and the
`Termination` the supervisor latches records the escalation for the console.

Verdict TIMEOUT, exit-class 1. Reached ONLY by the timeout-escalation scenario
(`--timeout 1 --retries 1`), which mtest bounds; no default scenario walks
stubborn/, so this can never hang CI. The cost of the escalation itself is one
grace period (~0.3 s), not a compile-length wait.
"""
from std.ffi import external_call
from std.time import sleep
from std.testing import TestSuite


def test_ignores_sigterm_until_killed() raises:
    # SAFETY: libc `signal(int signum, void (*handler)(int))` — the handler slot
    # takes the constant `SIG_IGN` (1), passed here as the integer it is defined
    # to be. Under the SysV AMD64 C ABI both arguments are register-passed, so an
    # integer 1 lands in the handler register exactly as the C constant would.
    # SIGTERM (15) is the only signal disarmed; nothing is dereferenced and no
    # handler ever runs. This fixture exists to be killed and never runs outside
    # the timeout-escalation e2e scenario.
    _ = external_call["signal", Int](Int32(15), Int(1))
    while True:
        sleep(3600.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
