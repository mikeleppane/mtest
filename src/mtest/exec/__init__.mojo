"""The exec layer of the mtest runner: the POSIX process adapter.

The interface is narrow: `run_supervised(spec) -> ProcessResult` plus the
interrupt primitive. It hides every fd, pipe, poll, fork/exec, and FFI call in
the runner, so nothing above this layer sees a syscall. The supervisor keeps a
crash, a failure, mtest's own deadline kill, and a spawn failure distinct, so
the process exit code the runner reports is truthful.

The public surface is re-exported here so callers write
`from mtest.exec import ProcessSpec, ProcessResult, run_supervised, ...`.
"""
from mtest.exec.spec import ProcessSpec
from mtest.exec.termination import Termination
from mtest.exec.result import ProcessResult
from mtest.exec.paths import canonicalize, lexical_source_path
from mtest.exec.supervise import (
    run_supervised,
    Supervisor,
    SlotId,
    Completion,
    KillCause,
    effective_cap,
    query_effective_cap,
    decide_kill,
    escalate_on_interrupt,
)
from mtest.exec.signals import (
    ExecRuntime,
    interrupt_requested,
    interrupt_count,
)
from mtest.exec.tty import stderr_isatty, stdout_isatty
