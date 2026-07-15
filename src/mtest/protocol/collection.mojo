"""Collection-listing qualification (Layer 2): does a `--skip-all` probe read
as a collection listing?

`mtest` runs a file's tests with `--skip-all` to discover node ids WITHOUT
executing any test body: a conforming module prints an ordinary report whose
rows are all SKIP. `collection_disqualifier` decides, from the parsed report
alone, whether that shape held; `collection_names` extracts the listed names
in source/discovery order. Both are PURE: they read only a `ParsedReport`,
import `model` (through `report`) ONLY, perform no I/O, and never raise. The
exit-code check and the drift-vs-malformed routing for a disqualified probe
are session policy, not this module's.

Precedence (the first to fire decides, mirroring `report.mojo`'s own
first-fires-wins discipline):

    1. `verdict != VALID`   -> "no valid report block"
    2. A row is not SKIP    -> "a test body ran under collection: <name>"
    3. `summary_failed > 0` -> "collection reported failures"
    4. `has_trailer`        -> "collection carried a failure trailer"

A FAIL row is caught by (2) before (3) or (4) ever fire, so it is reported by
the offending row's name rather than as a bare failure-count or trailer
phrase — the more actionable diagnostic for a caller building a collection
error message.
"""
from mtest.model import Outcome
from mtest.protocol.report import ParsedReport, ReportVerdict


def collection_disqualifier(report: ParsedReport) -> String:
    """The first reason `report` fails to qualify as a collection listing.

    A qualifying report is VALID, every row is SKIP, `summary_failed == 0`,
    and it carries no failure trailer — the shape a conforming module prints
    under `--skip-all`, which runs no test body. See the module docstring for
    the exact precedence among disqualifiers.

    Args:
        report: A parsed report to classify. Not mutated.

    Returns:
        `""` if `report` qualifies as a collection listing; otherwise a short
        phrase naming the first disqualifying defect. Allocates the returned
        string. Never raises.
    """
    if report.verdict != ReportVerdict.VALID:
        return "no valid report block"
    for row in report.rows:
        if row.outcome != Outcome.SKIP:
            return "a test body ran under collection: " + row.name
    if report.summary_failed > 0:
        return "collection reported failures"
    if report.has_trailer:
        return "collection carried a failure trailer"
    return ""


def collection_names(report: ParsedReport) -> List[String]:
    """The row names of `report`, in source/discovery order.

    Defined for any report; meaningful as a collection listing only when
    `collection_disqualifier(report) == ""`. A non-VALID report already
    carries no rows, so this returns an empty list for one.

    Args:
        report: A parsed report to read names from. Not mutated.

    Returns:
        The row names in the order they appear in `report.rows`. Allocates.
        Never raises.
    """
    var out = List[String]()
    for row in report.rows:
        out.append(row.name)
    return out^
