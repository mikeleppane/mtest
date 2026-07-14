"""The model layer of the mtest runner (Layer 0).

This is the base layer: the outcome vocabulary, the closed typed event set that
is the only channel from the session to the reporters, and the pure function
that maps a multiset of run outcomes to a process exit code. It imports nothing
internal; every layer above imports from here.

The public surface is re-exported here so callers write
`from mtest.model import Outcome, Event, exit_code_for, ...`.
"""
from mtest.model.outcome import Outcome
from mtest.model.node_id import NodeId, NodeIdSplit, split_node_token
from mtest.model.test_result import TestResult
from mtest.model.parse_disposition import ParseDisposition
from mtest.model.test_counts import TestCounts
from mtest.model.events import EventKind, Summary, Event
from mtest.model.exit_code import (
    exit_code_for,
    EXIT_SUCCESS,
    EXIT_FAILURE,
    EXIT_NOTHING_RAN,
)
