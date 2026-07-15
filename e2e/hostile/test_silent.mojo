"""Known-outcome fixture: a binary that compiles, runs, exits 0, prints NOTHING.

Verdict MALFORMED-SUITE, exit-class 1. It never invokes TestSuite, so it speaks
no report block for its own path. Under the run-report-as-handshake the session
parses the run's own output and finds it ABSENT: the file ran but reported no
tests, which is a MALFORMED suite, never a PASS-from-exit-status. This is the
core of the closed zero-test ceiling — an honest zero-test report (test_zero)
is a PASS, but SILENCE is a malformed suite.
"""


def main():
    pass
