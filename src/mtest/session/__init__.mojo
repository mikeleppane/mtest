"""The session layer of the mtest runner (Layer 4): sequential orchestration.

`session` is the integration keystone. It calls `discover`, then for each
discovered file composes the `exec` supervisor to build-then-execute, maps each
termination to an honest `Outcome` (a crash, a failure, a timeout, and a compile
error stay distinct), emits the closed `Event` set to the reporter, and resolves
the process exit code. It emits events and NOTHING else — the reporter formats;
pre-session usage errors are main's.

The public surface is re-exported here so callers write
`from mtest.session import run_session, run_verdict, build_verdict`.
"""
from mtest.session.session import run_session
from mtest.session.verdict import run_verdict, build_verdict
