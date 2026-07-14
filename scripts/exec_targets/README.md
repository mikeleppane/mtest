# exec_targets — purpose-built subprocess helpers for the exec unit tests

These scripts are the controlled subjects the `exec` supervisor is tested
against. Each isolates one supervision invariant (group kill, EOF-vs-completion,
signal decode, concurrent drain, byte-exact argv capture, timeout latching).

They are Python because `scripts/` is this repo's Python containment zone; the
runner itself stays pure Mojo. The tests invoke them with an explicit argv —
`["python3", "scripts/exec_targets/<name>.py", ...]` — through `execvp`, never
through `/bin/sh -c`, so no shell sits between the supervisor and the subject.

Each script uses only the Python standard library and blocks "forever" with a
300-second sleep where the test relies on the supervisor's deadline to end it —
long enough that a supervisor bug (a hang, a missed kill) shows up as a stalled
test rather than a passing one.
