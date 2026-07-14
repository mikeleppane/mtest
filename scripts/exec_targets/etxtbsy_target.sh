#!/bin/sh
# A directly executable target for the supervisor's text-file-busy tests.
#
# Those tests hold this file open for writing across the supervised run, so every
# execvp of it returns ETXTBSY (Linux refuses to exec a file that has an
# open-for-write descriptor) and this body never runs. It exits cleanly if it is
# ever executed normally. Run via ProcessSpec.command([<this path>]) directly, not
# through an interpreter, so the busy file itself is the exec target.
exit 0
