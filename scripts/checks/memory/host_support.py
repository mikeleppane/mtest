#!/usr/bin/env python3
"""Report that this host cannot run the memory lanes, and prove it should not.

`ci-memory` is the local floor's memory-safety aggregate. On linux-64 the
manifest's platform-scoped override replaces this command with a dependency
edge onto `asan-check` and `valgrind-check`, so this module never runs there.
Everywhere else it is what `ci-memory` actually executes.

Both lanes are linux-64 only, and for different reasons. Memcheck is pinned
under `[target.linux-64.dependencies]`, so the binary does not exist on any
other platform. The ASan lane's negative controls, leak accounting, and
symbolized frame expectations were built and pinned against the Linux
toolchain, and no hosted cell exercises them on Darwin. Silently succeeding
would let a macOS `pixi run ci` claim a memory-safety verdict it never
computed, so this prints exactly what went uncovered and names the lanes that
own it.

Reaching this module ON linux-64 means the platform override was lost — a
manifest edit that quietly demoted the whole point of the aggregate. That is
the one case here that fails closed.
"""

from __future__ import annotations

import platform
import sys


LANES = ("asan-check", "valgrind-check")
"""The lanes `ci-memory` runs on linux-64, and skips wherever this module runs."""


def is_linux(system: str) -> bool:
    """Whether a `platform.system()` string names Linux.

    Args:
        system: The value `platform.system()` returned, or a test's stand-in.

    Returns:
        True when the host is Linux and the manifest override should have run
        the lanes instead of this module.
    """
    return system == "Linux"


def main(system: str | None = None) -> int:
    """Announce the uncovered lanes, or fail because linux-64 reached this code.

    Args:
        system: The host system name. Defaults to `platform.system()`; tests
            pass an explicit value to drive both branches.

    Returns:
        0 after reporting the skip on a platform that genuinely cannot run the
        lanes, and 1 on Linux, where arriving here means the manifest's
        `[target.linux-64.tasks]` override for `ci-memory` was removed.
    """
    host = platform.system() if system is None else system
    lanes = ", ".join(LANES)
    if is_linux(host):
        print(
            "FATAL: ci-memory: reached the non-Linux fallback on Linux; the "
            f"[target.linux-64.tasks] override that runs {lanes} is missing",
            file=sys.stderr,
        )
        return 1
    print(
        f"ci-memory: SKIPPED on {host} -- {lanes} are linux-64 only "
        "(Memcheck is pinned for linux-64 alone, and the ASan controls are "
        "pinned against the Linux toolchain). The hosted Linux cells own this "
        "verdict; this run did not compute it."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
