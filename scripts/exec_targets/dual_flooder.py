#!/usr/bin/env python3
"""Write a fixed, large volume to BOTH stdout and stderr, interleaved.

Emits exactly 262144 bytes of 'o' to stdout and 262144 bytes of 'e' to stderr
(256 KiB each), in interleaved 4 KiB chunks with a flush after every chunk, then
exits 0. A supervisor that drains only one stream at a time pipe-deadlocks once
the unread pipe fills its ~64 KiB kernel buffer; concurrent draining does not.
The single-character streams make separate, byte-exact capture checkable: every
stdout byte must be 'o' and every stderr byte 'e', with the exact counts.
"""
import os
import sys

CHUNK = 4096
TOTAL = 256 * 1024  # 262144 bytes per stream

out = os.fdopen(1, "wb", buffering=0)
err = os.fdopen(2, "wb", buffering=0)

written = 0
o_chunk = b"o" * CHUNK
e_chunk = b"e" * CHUNK
while written < TOTAL:
    out.write(o_chunk)
    err.write(e_chunk)
    written += CHUNK

sys.exit(0)
