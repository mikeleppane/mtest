#!/usr/bin/env python3
"""Write tag-owned, byte-exact payloads to both streams, optionally barriered.

Each stream carries a payload built from one repeating token, `<tag>-out-` for
stdout and `<tag>-err-` for stderr, cut to the requested byte count and closed
by a single newline. Every window of either payload therefore names both the
owning tag and the owning stream, so the head this fixture writes and the tail
it ends with are distinguishable sentinels: a capture that mixes two slots, or
splices one stream into the other, cannot reproduce the expected bytes.

With `ready_path` and `release_path` the actor becomes a barrier: it writes
both payloads, creates `ready_path` so the test knows the bytes are already in
flight, then blocks until `release_path` appears. That lets a test force a
completion order — a neighbor finishes while this actor is still held open —
and prove that the neighbor's captured bytes are untouched by this actor's
overflow. The wait is bounded by an actor-local deadline and exits 70 on
expiry, so a supervisor bug shows up as a loud nonzero exit, never a hang.
"""

import os
import sys
import time


MAX_RELEASE_WAIT_SECONDS = 30.0
POLL_INTERVAL_SECONDS = 0.01
RELEASE_TIMEOUT_EXIT = 70
USAGE_EXIT = 64


def payload(tag: str, stream: str, size: int) -> bytes:
    """Build exactly `size` bytes of the tag/stream token, newline-terminated.

    Args:
        tag: The caller's label for this actor; appears in every token.
        stream: The stream name, `out` or `err`, appended to the tag.
        size: The total byte count to produce, at least one.

    Returns:
        The payload bytes: the token `<tag>-<stream>-` repeated and cut to
        `size - 1` bytes, followed by one newline.
    """
    token = f"{tag}-{stream}-".encode("ascii")
    body = bytearray()
    while len(body) < size - 1:
        body += token
    del body[size - 1 :]
    body += b"\n"
    return bytes(body)


def write_all(fd: int, data: bytes) -> None:
    """Write every byte of `data` to `fd`, looping over partial writes."""
    written = 0
    while written < len(data):
        written += os.write(fd, data[written:])


def wait_for_release(ready_path: str, release_path: str) -> None:
    """Announce readiness, then block until the release marker appears.

    Args:
        ready_path: Marker this actor creates once both payloads are written.
        release_path: Marker the test creates to let this actor exit.

    Raises:
        SystemExit: With `RELEASE_TIMEOUT_EXIT` if the release marker does not
            appear within `MAX_RELEASE_WAIT_SECONDS`.
    """
    with open(ready_path, "x", encoding="ascii") as ready_file:
        ready_file.write("tagged-streams-ready\n")
    deadline = time.monotonic() + MAX_RELEASE_WAIT_SECONDS
    while time.monotonic() < deadline:
        if os.path.exists(release_path):
            return
        time.sleep(POLL_INTERVAL_SECONDS)
    raise SystemExit(RELEASE_TIMEOUT_EXIT)


def main() -> None:
    """Write both payloads, then honor the optional release barrier."""
    if len(sys.argv) not in (4, 6):
        raise SystemExit(USAGE_EXIT)
    tag = sys.argv[1]
    stdout_bytes = int(sys.argv[2])
    stderr_bytes = int(sys.argv[3])
    if stdout_bytes < 1 or stderr_bytes < 1:
        raise SystemExit(USAGE_EXIT)

    write_all(1, payload(tag, "out", stdout_bytes))
    write_all(2, payload(tag, "err", stderr_bytes))

    if len(sys.argv) == 6:
        wait_for_release(sys.argv[4], sys.argv[5])


if __name__ == "__main__":
    main()
