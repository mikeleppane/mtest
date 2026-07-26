#!/usr/bin/env python3
"""Ignore SIGTERM and sleep forever — forcing a SIGKILL escalation.

Sets SIGTERM to be ignored, then sleeps far past any deadline. The supervisor's
polite SIGTERM has no effect, so after the grace window it must escalate to
SIGKILL (9), which cannot be caught or ignored. The outcome latches to
`TimedOut` with `escalated=True` and final status `Signaled(9)`.

An optional first argument names a readiness marker written AFTER the disposition
is installed. A caller that waits for it knows the child is genuinely deaf to
SIGTERM; without it, a signal raised during interpreter start-up would kill the
child politely and a test meaning to prove the escalation would quietly prove
nothing instead.
"""

import os
import signal
import sys
import time


signal.signal(signal.SIGTERM, signal.SIG_IGN)
if len(sys.argv) > 1:
    marker = sys.argv[1]
    with open(marker + ".tmp", "w", encoding="utf-8") as handle:
        handle.write("ignoring\n")
    # Rename is atomic, so a reader never observes a half-written marker.
    os.rename(marker + ".tmp", marker)
time.sleep(300)
