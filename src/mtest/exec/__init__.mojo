"""The exec layer of the mtest runner (Layer 3): the POSIX process adapter.

The deepest module: a narrow interface — `run_supervised(spec) -> ProcessResult`
plus the interrupt primitive — hiding every fd, pipe, poll, fork/exec, and FFI
call in the whole runner. Nothing above this layer sees a syscall. The supervisor
keeps a crash, a failure, our own deadline kill, and a spawn failure distinct, so
the process exit code the runner ultimately reports is truthful.

The public surface is re-exported here so callers write
`from mtest.exec import ProcessSpec, ProcessResult, run_supervised, ...`.
"""
from mtest.exec.spec import ProcessSpec
from mtest.exec.termination import Termination
from mtest.exec.result import ProcessResult, lossy_utf8
from mtest.exec.supervise import run_supervised
from mtest.exec.signals import (
    install_signal_handlers,
    interrupt_requested,
)
from mtest.exec.tty import stdout_isatty
