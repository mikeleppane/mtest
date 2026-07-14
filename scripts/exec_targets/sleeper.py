#!/usr/bin/env python3
"""Sleep forever with default signal dispositions.

A plain long sleep. When the supervisor's deadline fires it sends the group a
SIGTERM, whose default action terminates this process, so the final status is
`Signaled(15)` — but the outcome must still latch to `TimedOut`, because the
death was our deadline's doing, not the program's.
"""
import time

time.sleep(300)
