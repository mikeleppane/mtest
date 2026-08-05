"""Sequential orchestration of a test session.

The session calls `discover`, then for each discovered file composes the `exec`
supervisor to build-then-execute, maps each termination to an honest `Outcome`
(a crash, a failure, a timeout, and a compile error stay distinct), emits the
closed `Event` set to the reporter, and resolves the process exit code. It emits
events and nothing else: the reporter formats, and pre-session usage errors
belong to main.

The build-artifact store is a subpackage with its own facade, and only the two
cache-root operations reach past this one: `--cache-clear` deletes that root,
and the last-run state file lives inside it whether or not the cache is
enabled, so the composition root has to be able to create and delete it without
knowing anything else about the store.

What is re-exported here is what a caller outside the package uses, so they
write `from mtest.session import run_session, run_verdict, build_verdict`: the
four entrypoints with their result types, the two verdict maps, and the two
cache-root operations. The clamp, the shard, the retry classes, the pipeline
kernel and the attribution bounds are internal policy and are imported from the
module that owns them, so adding a name here is a decision to support it.
"""
from mtest.session.store import clear_cache_root, ensure_cache_root
from mtest.session.session import (
    SessionResult,
    run_session,
    run_session_with_state,
)
from mtest.session.collect import CollectResult, run_collect
from mtest.session.debug import DebugOutcome, DebugPlan, prepare_debug
from mtest.session.verdict import run_verdict, build_verdict
