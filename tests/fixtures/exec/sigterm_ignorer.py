#!/usr/bin/env python3
"""Ignore SIGTERM and sleep forever — forcing a SIGKILL escalation.

Sets SIGTERM to be ignored, then sleeps far past any deadline. The supervisor's
polite SIGTERM has no effect, so after the grace window it must escalate to
SIGKILL (9), which cannot be caught or ignored. The outcome latches to
`TimedOut` with `escalated=True` and final status `Signaled(9)`.
"""
import signal
import time

signal.signal(signal.SIGTERM, signal.SIG_IGN)
time.sleep(300)
