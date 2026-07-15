"""The chameleon: lists its tests under --skip-all, refuses them under --only.

Under `--skip-all` it registers BOTH test_real and test_ghost, so the probe sees
a two-test collection listing. Under `--only` it registers only test_real, so
the stdlib raises `… test not found in suite: test_ghost`. This is the sanctioned
proof that user code can refuse a name it just listed: mtest recollects once
(loud), retries, sees the same refusal, and reports MALFORMED-SUITE (exit-1
class) — never exit 3. Reached only by the selection chameleon scenario.
"""
from std.sys import argv
from std.testing import assert_true, TestSuite


def test_real() raises:
    assert_true(True)


def test_ghost() raises:
    assert_true(True)


def main() raises:
    var has_only = False
    for a in argv():
        if a == "--only":
            has_only = True
    var s = TestSuite()
    s.test[test_real]()
    if not has_only:
        s.test[test_ghost]()
    s^.run()
