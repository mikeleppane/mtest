#!/usr/bin/env python3
"""Terminate by SIGABRT — die by a signal, not a nonzero exit.

Sends SIGABRT (6) to itself so the process is terminated by a signal. This is a
crash, structurally distinct from a normal nonzero exit: the supervisor must
report `Signaled(6)`, never `Exited(...)`. SIGABRT is chosen because it is far
from the supervisor's own SIGTERM (15) / SIGKILL (9), so a decode confusion
cannot hide behind a matching number.
"""
import os
import signal

os.kill(os.getpid(), signal.SIGABRT)
