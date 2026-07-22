#!/usr/bin/env python3
"""Fork a grandchild that resolves `mojo` purely through the inherited PATH.

Proves the child received the FULL inherited environment rather than a scrubbed
one: the grandchild names `mojo` with no directory component, so `execvp` must
consult the inherited PATH to locate the binary the pixi environment provides. A
PATH-less or scrubbed environment makes `execvp` raise and the grandchild exits
44; a working inherited PATH execs `mojo --version`, which prints to the
inherited stdout and exits 0. This actor forwards the grandchild's exit status as
its own, so the supervised result's exit code is the resolution verdict.
"""
import os
import sys

pid = os.fork()
if pid == 0:
    # Grandchild: resolve `mojo` against the inherited PATH alone.
    try:
        os.execvp("mojo", ["mojo", "--version"])
    except OSError:
        os._exit(44)
    os._exit(45)

_, status = os.waitpid(pid, 0)
if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
sys.exit(46)
