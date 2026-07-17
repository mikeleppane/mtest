"""Probe fixture: a test that segfaults the process mid-suite.

Pins the hard-crash path taken by a genuine invalid memory access (SIGSEGV)
rather than a controlled `abort()`. The buffered report is LOST (no PASS lines,
no Summary) and the process dies by SIGNAL. Unlike `crashing.mojo` there is no
`ABORT:` line: a raw segfault emits none, so the snapshot pins that absence.
The fault is triggered by loading through an UnsafePointer aimed at an unmapped
low address, which reliably raises signal 11 on this toolchain.
"""
from std.memory import UnsafePointer
from std.testing import assert_equal, TestSuite


def test_before_segfault_passes() raises:
    assert_equal(1, 1)


def test_segfaults() raises:
    var p = UnsafePointer[Int, MutUntrackedOrigin](unsafe_from_address=8)
    print(p[])


def test_after_segfault_passes() raises:
    assert_equal(1, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
