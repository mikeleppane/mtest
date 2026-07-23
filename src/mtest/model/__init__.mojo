"""The model layer of the mtest runner.

The base layer: the outcome vocabulary, the closed typed event set that is the
only channel from the session to the reporters, and the exit-code authority —
the outcome-multiset mapping plus the one resolver every caller that reaches an
exit code goes through. It imports nothing internal; every layer above imports
from here.

The public surface is re-exported here, so callers can write
`from mtest.model import Outcome, Event, resolve_exit_code, ...`.
"""
from mtest.model.outcome import Outcome
from mtest.model.node_id import NodeId, NodeIdSplit, split_node_token
from mtest.model.test_result import TestResult
from mtest.model.parse_disposition import ParseDisposition
from mtest.model.attribution import AttributionDisposition
from mtest.model.test_counts import TestCounts
from mtest.model.events import (
    EventKind,
    Summary,
    Event,
    EventPayload,
    SessionStartedPayload,
    WarningPayload,
    PrecompileFailedPayload,
    FileStartedPayload,
    FileFinishedPayload,
    SessionFinishedPayload,
    InternalErrorPayload,
    TestReportedPayload,
    CollectionKnownPayload,
    AttemptFinishedPayload,
    CrashAttributionPayload,
    ProgressPayload,
)
from mtest.model.exit_code import (
    TerminalFacts,
    exit_code_for,
    resolve_exit_code,
    EXIT_SUCCESS,
    EXIT_FAILURE,
    EXIT_NOTHING_RAN,
    EXIT_INTERNAL_ERROR,
)
from mtest.model.slow import SLOW_THRESHOLD_SECONDS, is_slow, slow_step_label
