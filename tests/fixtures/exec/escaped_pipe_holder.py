#!/usr/bin/env python3
"""Leave the supervised group while retaining its stdout capture pipe.

The spawned descendant calls ``setsid()`` before the leader exits 0, owns a
ready marker rooted at ``argv[2]``, and writes small periodic bytes to stdout
until it sees the matching stop marker or reaches its bounded self-expiry.
Cleanup cooperates through those markers only; it never stores or signals a
numeric PID that could be reused by an unrelated process.
"""
import os
import sys
import time


MAX_LIFETIME_SECONDS = 10.0


def spawn(control_path: str) -> None:
    """Spawn one synchronized escaped descendant and exit the leader 0."""
    ready_path = control_path + ".ready"
    stop_path = control_path + ".stop"
    for stale_path in (ready_path, stop_path):
        try:
            os.unlink(stale_path)
        except FileNotFoundError:
            pass

    ready_r, ready_w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(ready_r)
        os.setsid()
        with open(ready_path, "x", encoding="ascii") as ready_file:
            ready_file.write("escaped-writer-ready\n")
        os.write(ready_w, b"1")
        os.close(ready_w)
        deadline = time.monotonic() + MAX_LIFETIME_SECONDS
        while time.monotonic() < deadline:
            if os.path.exists(stop_path):
                os.close(1)
                os.close(2)
                os.unlink(ready_path)
                os._exit(0)
            try:
                os.write(1, b"escaped-writer\n")
            except BrokenPipeError:
                # The supervisor reached its post-leader bound and closed the
                # read end. Stay alive for the test's explicit cleanup proof.
                pass
            time.sleep(0.02)
        os.close(1)
        os.close(2)
        os.unlink(ready_path)
        os._exit(0)

    os.close(ready_w)
    ready = os.read(ready_r, 1)
    os.close(ready_r)
    if ready != b"1":
        os._exit(70)
    os._exit(0)


def cleanup(control_path: str) -> None:
    """Request cooperative shutdown and verify the escapee acknowledged it."""
    ready_path = control_path + ".ready"
    stop_path = control_path + ".stop"
    if not os.path.exists(ready_path):
        raise SystemExit(70)
    with open(stop_path, "x", encoding="ascii") as stop_file:
        stop_file.write("stop-escaped-writer\n")
    deadline = time.monotonic() + 2.0
    while os.path.exists(ready_path) and time.monotonic() < deadline:
        time.sleep(0.02)
    if os.path.exists(ready_path):
        raise SystemExit(70)
    os.unlink(stop_path)
    sys.stdout.write("CLEANED\n")


def make_unresponsive(control_path: str) -> None:
    """Create a ready marker with no owner to test cleanup's loud timeout."""
    ready_path = control_path + ".ready"
    stop_path = control_path + ".stop"
    for stale_path in (ready_path, stop_path):
        try:
            os.unlink(stale_path)
        except FileNotFoundError:
            pass
    with open(ready_path, "x", encoding="ascii") as ready_file:
        ready_file.write("no-owner-can-acknowledge\n")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(64)
    if sys.argv[1] == "spawn":
        spawn(sys.argv[2])
    elif sys.argv[1] == "cleanup":
        cleanup(sys.argv[2])
    elif sys.argv[1] == "unresponsive":
        make_unresponsive(sys.argv[2])
    else:
        raise SystemExit(64)


if __name__ == "__main__":
    main()
