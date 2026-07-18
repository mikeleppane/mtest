#!/bin/sh
# A directly executable target for the supervisor's text-file-busy tests.
#
# The testing adapter injects ETXTBSY before execve reaches this file, so this
# body should not run in the race tests. It exits cleanly if executed normally.
# Run via ProcessSpec.command([<this path>]) directly, not through an interpreter,
# so the adapter's retry targets the same executable path on every attempt.
exit 0
