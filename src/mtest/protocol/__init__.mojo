"""The protocol layer of the mtest runner (Layer 2).

A pure report parser over one child test binary's decoded stdout. It imports
only `model`, does no I/O, holds no FFI, and decides no policy: it turns bytes
into one of four verdicts (VALID / ABSENT / OFF_GRAMMAR / AMBIGUOUS) plus the
parsed rows and reconciled counts, and leaves every policy decision to the
session above it.

The public surface is re-exported here so callers write
`from mtest.protocol import parse_report, ReportVerdict, ...`.
"""
from mtest.protocol.report import (
    ParsedReport,
    ParsedRow,
    ReportVerdict,
    parse_report,
)
