#!/bin/sh
# A directly executable probe for the env-override PATH-resolution proof.
#
# This file lives only under tests/fixtures/exec, a directory that is NOT on any
# normal PATH. Spawning it by the bare name `path_probe.sh` therefore resolves
# only when a `PATH=` environment extra points the child's candidate search at
# this directory. It prints a fixed sentinel so the test can confirm the override
# PATH — not the inherited one — governed which executable was found.
printf 'PATH_PROBE_RAN\n'
exit 0
