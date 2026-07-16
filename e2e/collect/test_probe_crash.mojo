"""Known-outcome collect fixture: a probe that crashes at collection time.

The crash is in `main`, not a test body, so `--skip-all` cannot skip past it: the
collection probe itself dies by signal. `mtest collect` writes a crash diagnostic
to STDERR for this file and the listing CONTINUES for the others. Reached only by
the collect scenario (a whole run would CRASH).
"""
from std.ffi import external_call


def main():
    # SAFETY: libc abort has the exact `void abort(void)` ABI and accepts no
    # pointer. This hostile fixture deliberately terminates here by SIGABRT.
    external_call["abort", NoneType]()
