"""The protocol layer of the mtest runner.

A report parser over one child test binary's decoded stdout. It imports only
`model`, does no I/O, and holds no FFI. It turns bytes into one of four
verdicts (VALID, ABSENT, OFF_GRAMMAR, or AMBIGUOUS) plus the parsed rows and
reconciled counts. It decides no policy: what a verdict means is the session's
call, not this layer's.

The public surface is re-exported here, so callers write
`from mtest.protocol import parse_report, ReportVerdict, ...`.
"""
from mtest.protocol.report import (
    ParsedReport,
    ParsedRow,
    ReportVerdict,
    parse_report,
)
from mtest.protocol.collection import collection_disqualifier, collection_names
