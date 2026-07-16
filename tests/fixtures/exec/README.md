# Exec subprocess fixtures

These scripts are the controlled subjects the `exec` supervisor is tested
against. Each isolates one supervision invariant (group kill, EOF-vs-completion,
signal decode, concurrent drain, byte-exact argv capture, timeout latching).

They are Python because they are test-only subprocess actors, never product
code or a runner dependency. The tests invoke them with an explicit argv —
`["python3", "tests/fixtures/exec/<name>.py", ...]` — through `execvp`, never
through `/bin/sh -c`, so no shell sits between the supervisor and the subject.

Each script uses only the Python standard library and blocks "forever" with a
300-second sleep where the test relies on the supervisor's deadline to end it —
long enough that a supervisor bug (a hang, a missed kill) shows up as a stalled
test rather than a passing one.
