#!/usr/bin/env python3
"""Exit immediately with a fixed nonzero code (7).

A minimal genuine failure: the supervisor must report `Exited(7)`. Under an
inherited `SIG_IGN` disposition for SIGCHLD the kernel auto-reaps children and
`waitpid` cannot retrieve a status, so a supervisor that decodes the unfilled
status word would launder this real failure into a false `Exited(0)` PASS.
"""
import sys

sys.exit(7)
