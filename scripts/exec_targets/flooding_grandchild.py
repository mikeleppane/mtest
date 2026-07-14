#!/usr/bin/env python3
"""Fork a grandchild that floods the inherited stdout pipe CONTINUOUSLY.

The grandchild inherits the dup2'd stdout write end and writes to it in a tight
loop that never stops on its own. As long as the supervisor keeps reading, the
`read` on that pipe never returns 0 (EOF): a drain that loops until EOF would
never return, and an unbounded per-slice drain would starve the deadline and
reap checks. Only a group kill closing the grandchild's write end ends the flood.

Two leader modes select which supervision path the flood attacks:

- "exit0": the leader exits 0 at once and is reaped normally. The post-reap drain
  must still terminate — the supervisor sweeps the group first, closing the
  grandchild's write end, so the drain reaches EOF instead of spinning forever.
- "alive": the leader stays alive past any deadline while the grandchild floods.
  The in-run drain must return control every slice so the deadline is honored and
  the run times out promptly instead of the reader spinning forever.
"""
import os
import sys
import time

mode = sys.argv[1] if len(sys.argv) > 1 else "exit0"

pid = os.fork()
if pid == 0:
    # Grandchild: flood the inherited stdout write end forever. Buffering is off
    # so every write reaches the pipe immediately and keeps `read` returning data.
    out = os.fdopen(1, "wb", buffering=0)
    chunk = b"x" * 4096
    while True:
        try:
            out.write(chunk)
        except (BrokenPipeError, OSError):
            # The group kill closed the read end: stop and exit.
            os._exit(0)

# Leader.
if mode == "alive":
    # Outlive every deadline; only the supervisor's kill ends this.
    time.sleep(300)
else:
    # Succeed and exit at once, leaving the flooding grandchild behind.
    os._exit(0)
