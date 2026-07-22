"""The platform layer of the mtest runner: the narrow platform-I/O boundary.

Layer 0, beneath every other package. This module imports nothing from `mtest`,
which is the whole point of where it sits: `report` (Layer 2), `exec` (Layer 3)
and `session` (Layer 4) can all reach it without an upward edge. Before it
existed, `report` had no blessed place to get a `write(2)` — `exec` sits a layer
above it — so fd-owning reporters declared their own libc symbols and `rename(2)`
ended up implemented twice, once in `exec` and once in the JUnit reporter.

This is one of the runner's two audited foreign boundaries. The other is
`native/` and the `mtest_exec_*` ABI that `exec` calls: a private C17 POSIX
adapter carrying fork/exec, pipe supervision, and signal handling. The two stay
separate on purpose. This module holds the small, self-contained per-call
operations a Mojo caller needs directly; `native/` holds the machinery that has
to be written in C to be async-signal-safe after a fork.

Every entity here either delegates to a safe standard-library wrapper, or is a
single foreign call carrying its own `# SAFETY:` argument immediately beside it.
Where the standard library can express an operation's exact error semantics, the
safe call wins and no foreign declaration is written at all — deleting an unsafe
operation beats wrapping it.

The public surface is re-exported here so callers write
`from mtest.platform import process_id, rename_path`.
"""
from mtest.platform.fs import rename_path
from mtest.platform.process import process_id
