# Exec subprocess fixtures

These scripts are the controlled subjects the `exec` supervisor is tested
against. Each isolates one supervision invariant (owned-process-group kill,
escaped-descendant pipe containment, EOF-vs-completion, signal decode,
concurrent drain, byte-exact argv capture, timeout latching).

They are Python because they are test-only subprocess actors, never product
code or a runner dependency. The tests invoke them with an explicit argv —
`["python3", "tests/fixtures/exec/<name>.py", ...]` — with `PATH` resolved in
the parent and `execve` called in the child, never through `/bin/sh -c`, so no
shell sits between the supervisor and the subject.

Each script uses only the Python standard library and blocks "forever" with a
300-second sleep where the test relies on the supervisor's deadline to end it —
long enough that a supervisor bug (a hang, a missed kill) shows up as a stalled
test rather than a passing one.

`escaped_pipe_holder.py` is deliberately different: its descendant calls
`setsid()`, so it is outside the process group mtest owns. It self-expires after
ten seconds and also provides a bounded cooperative cleanup mode. Cleanup
creates a unique stop marker and waits for the escapee to remove its own ready
marker immediately before exiting; it never stores or signals a numeric PID.
The test invokes and verifies that handshake, so even a supervisor regression
cannot leave the escapee running indefinitely in CI.
