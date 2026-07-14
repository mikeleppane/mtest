#!/usr/bin/env python3
"""Fork a grandchild that inherits the supervised stdout pipe and outlives us.

The grandchild inherits the dup2'd stdout write end. Killing only the direct
child would leave the grandchild holding that write end — a supervisor that
drained to EOF would then block forever. Every kill therefore targets the
process GROUP, which reaches the grandchild too.

To make the group kill observable, the grandchild sleeps briefly and then, ONLY
if it is still alive, writes a sentinel file whose path is argv[1]. A working
group kill terminates the grandchild long before that sleep elapses, so the
sentinel is never created; a supervisor that killed only the direct child would
leave the grandchild to create it. Both the direct child and the grandchild
sleep far past any deadline so the supervisor's kill is the only thing that ends
this tree.
"""
import os
import sys
import time

sentinel = sys.argv[1]

pid = os.fork()
if pid == 0:
    # Grandchild: if the group kill does NOT reach us, we outlive this sleep and
    # leave proof by creating the sentinel file.
    time.sleep(2)
    with open(sentinel, "w") as f:
        f.write("grandchild survived the group kill\n")
    os._exit(0)

# Direct child: hold the inherited stdout open and outlive every deadline.
time.sleep(300)
