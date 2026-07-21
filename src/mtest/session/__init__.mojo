"""Sequential orchestration of a test session.

The session calls `discover`, then for each discovered file composes the `exec`
supervisor to build-then-execute, maps each termination to an honest `Outcome`
(a crash, a failure, a timeout, and a compile error stay distinct), emits the
closed `Event` set to the reporter, and resolves the process exit code. It emits
events and nothing else: the reporter formats, and pre-session usage errors
belong to main.

The public surface is re-exported here, so callers write
`from mtest.session import run_session, run_verdict, build_verdict`.
"""
from mtest.session.session import run_session
from mtest.session.collect import CollectResult, run_collect
from mtest.session.verdict import run_verdict, build_verdict
from mtest.session.classify import (
    Classification,
    TrustedReport,
    classify,
    resolve_report,
)
from mtest.session.clamp import ClampedStream, clamp_stream
from mtest.session.shard import fnv1a64, partition, shard_owns
from mtest.session.retry_class import (
    RetryClass,
    has_crash_signature,
    retry_classify,
)
from mtest.session.attribution import (
    ATTRIBUTION_FILE_BUDGET_SECONDS,
    ATTRIBUTION_SESSION_BUDGET_SECONDS,
    ISOLATION_RUN_CAP,
    ISOLATION_TIMEOUT_CAP_SECS,
    AttributionStep,
    attribution_step,
    isolation_timeout_secs,
)
