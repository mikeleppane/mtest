#!/usr/bin/env python3
"""Catch SIGTERM and exit 0 promptly; otherwise sleep forever.

Installs a SIGTERM handler that exits 0, then sleeps. When the supervisor's
deadline fires and sends SIGTERM, this process exits 0 cleanly inside the grace
window — before any SIGKILL escalation. The final status is therefore
`Exited(0)`, yet the outcome must LATCH to `TimedOut` (escalated=False): a clean
exit provoked by our own deadline kill is still a timeout, never a pass.
"""
import signal
import sys
import time


def _on_term(signum, frame):
    sys.exit(0)


signal.signal(signal.SIGTERM, _on_term)
time.sleep(300)
