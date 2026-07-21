"""The protocol layer of the mtest runner.

A report parser over one child test binary's decoded stdout. It imports only
`model`, does no I/O, holds no FFI, and decides no policy: it turns bytes into
one of four verdicts — VALID, ABSENT, OFF_GRAMMAR, or AMBIGUOUS — plus the
parsed rows and reconciled counts, leaving every policy decision to the session
above it.

The public surface is re-exported here, so callers can write
`from mtest.protocol import parse_report, ReportVerdict, ...`.
"""
from mtest.protocol.report import (
    ParsedReport,
    ParsedRow,
    ReportVerdict,
    parse_report,
)
from mtest.protocol.collection import collection_disqualifier, collection_names
