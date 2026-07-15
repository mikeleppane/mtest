#!/usr/bin/env python3
"""Echo each argv element on its own bracketed line; a fixed marker to stderr.

Every argument after the script path is written to stdout as `[<arg>]\n`, so
trailing spaces and empty entries are visible and byte-exact (an empty argument
renders as `[]`, a trailing space as `[foo ]`). A single fixed line is written
to stderr so the test can prove the two streams are captured separately and are
not interleaved into one another.
"""
import os
import sys

out = os.fdopen(1, "wb", buffering=0)
err = os.fdopen(2, "wb", buffering=0)

for arg in sys.argv[1:]:
    out.write(b"[" + arg.encode("utf-8", "surrogateescape") + b"]\n")

err.write(b"ARGV_ECHOER_STDERR\n")
