"""Attribution fixture: crashes only when its tests run TOGETHER.

Verdict CRASH, exit-class 1 — byte-identical to its deterministic sibling's
verdict, which is the whole point. Its role is the NO-REPRODUCTION half of the
crash-attribution honesty pair: NO single test is the culprit, so the bounded
isolation pass runs each test alone, sees both pass, and reports NO_REPRODUCTION
— leaving the culprit UNATTRIBUTED rather than guessing. The file's CRASH stands
either way.

The shared state is the PROCESS ENVIRONMENT, chosen deliberately: it is
per-process, so it cannot leak between the isolation reruns (each is a fresh
process) or across invocations the way an on-disk marker would. Run whole,
`test_corrupts_shared_state` sets the variable and `test_trips_over_shared_state`
then trips over it and segfaults. Run alone under `--only`, the setter never runs,
so the tripper sees an unset variable and passes — the crash genuinely does not
reproduce under isolation.

The suite is registered EXPLICITLY rather than discovered because the ORDER is
load-bearing here: the corrupter must run before the tripper for the file to
crash at all. `--skip-all` still lists both names (running no body) and `--only`
still selects one, so the probe and the isolation reruns work exactly as they do
for a discovered suite.

Reached ONLY by the crash-attribution scenario; never in the default suite.
"""
from std.memory import UnsafePointer
from std.os import getenv, setenv
from std.testing import assert_true, TestSuite

comptime _STATE_VAR = "MTEST_E2E_ATTRIBUTION_SHARED_STATE"
"""The in-process shared state the first test corrupts and the second trips over.
"""


def test_corrupts_shared_state() raises:
    # Alone this is simply a passing test: it corrupts state nothing else reads.
    _ = setenv(_STATE_VAR, "corrupt", True)
    assert_true(True)


def test_trips_over_shared_state() raises:
    if getenv(_STATE_VAR, "") != "corrupt":
        # Run alone (under `--only`), the corrupter never ran: nothing to trip
        # over, so this test passes and the crash does not reproduce.
        assert_true(True)
        return
    # SAFETY: this deliberately constructs an UnsafePointer at a known-invalid
    # address so the load below raises a genuine SIGSEGV — the order-dependent
    # crash this fixture exists to produce for the crash-attribution e2e
    # scenario. It is reached only when the sibling test corrupted the shared
    # state earlier in the SAME process, and never runs outside this fixture.
    var p = UnsafePointer[Int, MutUntrackedOrigin](unsafe_from_address=8)
    print(p[])


def main() raises:
    var s = TestSuite()
    s.test[test_corrupts_shared_state]()
    s.test[test_trips_over_shared_state]()
    s^.run()
