"""Known-outcome fixture: a test that never returns.

Verdict TIMEOUT, exit-class 1. The loop sleeps forever, so the file is only ever
reached under `--timeout` (which kills it and reports TIMEOUT) or the interrupt
scenario (SIGINT). No default scenario walks slow/, so this can never hang CI.
"""
from std.time import sleep
from std.testing import TestSuite


def test_hangs_forever() raises:
    while True:
        sleep(3600.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
