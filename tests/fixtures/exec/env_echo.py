#!/usr/bin/env python3
"""Echo the child's full environment as `KEY=VALUE` lines, then exit 0.

Every entry of `os.environ` is written to stdout as `KEY=VALUE\n` in raw bytes,
nothing added and nothing filtered, so a test can assert the exact presence,
absence, value, and uniqueness of any key. This lets the env-override proofs read
back precisely what the C adapter handed the child at `execve`: an injected extra
must appear, the full inherited environment must survive, and a key an extra
replaces must appear exactly once with the new value (no inherited duplicate).
"""
import os

out = os.fdopen(1, "wb", buffering=0)

for key, value in os.environ.items():
    line = key + "=" + value + "\n"
    out.write(line.encode("utf-8", "surrogateescape"))
