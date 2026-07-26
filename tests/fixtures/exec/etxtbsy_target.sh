#!/bin/sh
# A directly executable target for the supervisor's text-file-busy tests.
#
# The testing adapter injects ETXTBSY before execve reaches this file, so this
# body does not run in the race tests: they fault every attempt they allow. It
# DOES run in the recovery test, where the adapter stops faulting after two
# attempts, so the exact line below is that test's proof that a transient
# ETXTBSY ended in a real exec rather than an honest failure.
# Run via ProcessSpec.command([<this path>]) directly, not through an interpreter,
# so the adapter's retry targets the same executable path on every attempt.
printf 'etxtbsy-recovered\n'
exit 0
