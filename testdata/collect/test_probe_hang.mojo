"""Known-outcome collect fixture: a probe that hangs at collection time.

The hang is in `main`, before any suite runs, so `--skip-all` cannot skip it: the
collection probe never returns and is bounded by `--timeout` (killed and reported
TIMEOUT). `mtest collect` writes a timeout diagnostic to STDERR and the listing
CONTINUES for the others. Reached only by the collect scenario under a short
`--timeout`, so it can never hang the gate.
"""
from std.time import sleep


def main():
    sleep(3600.0)
