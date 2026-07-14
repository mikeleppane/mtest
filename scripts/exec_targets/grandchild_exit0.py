#!/usr/bin/env python3
"""Direct child exits 0 immediately; a grandchild sleeps then writes a sentinel.

Mirrors grandchild_spawner but on the NORMAL-exit path: the supervised process
itself succeeds and is reaped at once, while a grandchild it forked inherits the
process group (and the stdout pipe) and would outlive it. A supervisor that only
group-kills on the timeout/interrupt path leaves the grandchild to survive its
sleep and create the sentinel (argv[1]); a supervisor that sweeps the group on
EVERY exit path kills it first, so the sentinel is never written.
"""
import os
import sys
import time

sentinel = sys.argv[1]

pid = os.fork()
if pid == 0:
    # Grandchild: if the group sweep does NOT reach us, we outlive this sleep and
    # leave proof by creating the sentinel file.
    time.sleep(2)
    with open(sentinel, "w") as f:
        f.write("grandchild survived the normal-exit group sweep\n")
    os._exit(0)

# Direct child: succeed and exit at once, leaving the grandchild behind.
os._exit(0)
