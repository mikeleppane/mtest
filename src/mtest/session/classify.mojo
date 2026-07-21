"""The total per-test classifier of the session layer.

`run_verdict` maps a bare run `Termination` to an outcome from the exit status
alone, which is not enough: a file that built and exited 0 while running zero
tests, or one that spoke no report at all, is not honestly a PASS. `classify`
closes that zero-test ceiling by folding three facts into one verdict: the run
termination, the run's own parsed report, and whether the capture overflowed. On
the default run path there is no separate probe, so the run's own report is the
handshake.

The policy is total over every child fate. In precedence order:

- `Signaled(_)` -> CRASH. The parser is not consulted; a crash is a crash.
- `TimedOut` -> TIMEOUT. Latched, and a valid report does not rescue it.
- `Exited`, capture overflowed with no valid report retained in the tail
  -> FAIL with CAPTURE_OVERFLOW. Never PASS, never drift.
- `Exited`, report ABSENT or AMBIGUOUS -> MALFORMED_SUITE. The file ran but
  spoke no honest report.
- `Exited`, report OFF_GRAMMAR -> drift: the report shape moved away from the
  pinned toolchain. Routes to exit 3 and contributes nothing to the exit-code
  multiset. This path is expected to be rare.
- `Exited`, report VALID -> PASS or FAIL per the reconciled report, with the
  exit status cross-checked under a worse-of rule: exit 0 with failing rows, or
  exit 1 with none, is still a FAIL.

The session layer does the decode and the parse and hands the results in;
`classify` decides the policy and `resolve_report` decides which report to trust
under truncation.
"""
from mtest.exec import Termination
from mtest.model import Outcome, ParseDisposition
from mtest.protocol import ParsedReport, ParsedRow, ReportVerdict, parse_report


comptime _TRUNCATION_MARKER = "[mtest: output truncated"
"""The prefix opening the omission marker line the capture layer splices in."""


@fieldwise_init
struct Classification(Copyable, Movable):
    """The full result of classifying one file's run.

    Carries everything the session needs to emit the file's events and account
    for it. Owns its lists and strings.
    """

    var file_outcome: Outcome
    """The file-level outcome tallied once in the per-file `Summary`."""
    var disposition: ParseDisposition
    """Why the report parse landed where it did; rides FileFinished."""
    var passed_tests: Int
    """Per-test passed count (the summary tally; 0 for a non-VALID report)."""
    var failed_tests: Int
    """Per-test failed count (the summary tally; 0 for a non-VALID report)."""
    var skipped_tests: Int
    """Per-test skipped count (the summary tally; 0 for a non-VALID report)."""
    var exit_outcomes: List[Outcome]
    """The exit-code multiset contribution: per-row outcomes for a VALID file, a
    single file-level outcome for an abnormal one, or empty for a drift file."""
    var is_drift: Bool
    """Whether the report drifted off the pinned grammar (routes to exit 3)."""
    var warning_kind: String
    """A short tag for the warning this classification demands; `""` if none."""
    var warning_detail: String
    """The sentence the reporter renders for that warning; `""` if none."""


@fieldwise_init
struct TrustedReport(Copyable, Movable):
    """Which report to trust for a run, plus whether the capture overflowed.

    On a truncated capture a report survives only if a complete valid block is
    wholly retained in the tail. Otherwise `is_overflow` is set and `report` is
    a placeholder the classifier ignores.
    """

    var report: ParsedReport
    """The report the classifier should consult; a placeholder on overflow."""
    var is_overflow: Bool
    """Whether a truncated capture kept no valid report block in its tail."""


def _tail_after_marker(text: String) -> String:
    """The substring after the truncation marker line, or `""` if there is none.

    The capture layer splices a single marker line, opening
    `[mtest: output truncated`, between the retained head and the surviving
    tail. Everything after that line is the tail the report parser reparses.

    Anchors on the last matching line rather than the first. A test's own stdout
    lands in the retained head, ahead of the genuine spliced marker, so a
    malicious or buggy test could print a line opening with the marker prefix
    and forge an earlier split point. Taking the last occurrence is strictly
    conservative: it can only shrink the trusted tail toward the genuine one,
    never expand it into truncated-away or forged head bytes.
    """
    var lines = text.split("\n")
    var marker_at = -1
    for i in range(len(lines)):
        if String(lines[i]).startswith(_TRUNCATION_MARKER):
            marker_at = i
    if marker_at < 0:
        return String("")
    var out = String("")
    for i in range(marker_at + 1, len(lines)):
        if i > marker_at + 1:
            out += "\n"
        out += String(lines[i])
    return out^


def resolve_report(
    stdout_text: String, source_path: String, truncated: Bool
) -> TrustedReport:
    """Decide which report to trust for a run under the capture-overflow rule.

    A truncated capture may yield a successful verdict only when a complete
    valid block survived wholly in the tail. Only the text after the marker line
    is parsed, and if that tail parses VALID it is trusted as a normal report
    rather than an overflow. Otherwise the report was lost to truncation and
    `is_overflow` is set. An untruncated capture is parsed whole.

    Args:
        stdout_text: The child's lossy-decoded stdout.
        source_path: The canonical path the report header must byte-equal.
        truncated: Whether the capture overflowed its bound, splicing a marker.

    Returns:
        The report to consult and whether the capture overflowed.
    """
    if not truncated:
        return TrustedReport(parse_report(stdout_text, source_path), False)
    var tail = _tail_after_marker(stdout_text)
    var tail_report = parse_report(tail, source_path)
    if tail_report.verdict == ReportVerdict.VALID:
        # A complete valid block survived wholly in the tail: a normal report.
        return TrustedReport(tail_report^, False)
    return TrustedReport(ParsedReport.absent(), True)


def _row_outcomes(report: ParsedReport) -> List[Outcome]:
    """The per-row outcomes of a VALID report, in row order."""
    var out = List[Outcome]()
    for r in report.rows:
        out.append(r.outcome)
    return out^


def _any_failing(outcomes: List[Outcome]) -> Bool:
    """Whether any outcome in the list is in the failing class."""
    for o in outcomes:
        if o.is_failing():
            return True
    return False


def _abnormal(
    outcome: Outcome,
    disposition: ParseDisposition,
    warning_kind: String,
    warning_detail: String,
) -> Classification:
    """A file-level classification whose sole multiset entry is its outcome.

    Used for the abnormal endings that carry no per-test attribution.
    """
    return Classification(
        outcome,
        disposition,
        0,
        0,
        0,
        [outcome],
        False,
        warning_kind,
        warning_detail,
    )


def classify(
    t: Termination, report: ParsedReport, is_overflow: Bool
) -> Classification:
    """Classify one file's run under the total policy.

    The session handles three cases before the classifier: a build
    COMPILE_ERROR, a run `SpawnFailed` (internal error, exit 3), and a run
    `TimedOut` while an interrupt is pending (interrupt, exit 2). Everything
    else reaches here with the run termination, the report to trust as already
    resolved for capture overflow, and the `is_overflow` flag.

    Args:
        t: The run termination; only Signaled, TimedOut, or Exited reach here.
        report: The report to consult. Ignored when `is_overflow`.
        is_overflow: Whether the capture overflowed and lost the report.

    Returns:
        The full `Classification` — outcome, disposition, counts, the exit-code
        multiset contribution, the drift flag, and any loud-warning info.
    """
    # A crash is a crash: the parser is unconsulted.
    if t.is_signaled():
        return _abnormal(Outcome.CRASH, ParseDisposition.NO_REPORT, "", "")
    # Our own deadline kill: latched, never rescued by a report.
    if t.is_timed_out():
        return _abnormal(Outcome.TIMEOUT, ParseDisposition.NO_REPORT, "", "")

    # From here the child Exited normally with `code`.
    var code = t.value

    # Capture overflow: a truncated capture that kept no valid block in its tail
    # can never be trusted for a successful verdict. Never drift, never PASS.
    if is_overflow:
        return _abnormal(
            Outcome.FAIL,
            ParseDisposition.CAPTURE_OVERFLOW,
            "capture-overflow",
            (
                "the run's stdout overflowed the capture bound and no complete"
                " report survived in the retained tail (look for the '[mtest:"
                " output truncated' marker); reduce the test's output or raise"
                " the capture bound"
            ),
        )

    var v = report.verdict

    # The file ran but spoke no honest report at all.
    if v == ReportVerdict.ABSENT:
        return _abnormal(
            Outcome.MALFORMED_SUITE,
            ParseDisposition.NO_REPORT,
            "malformed-suite",
            (
                "the file ran and exited but printed no report block for its"
                " own path; a conforming main runs"
                " TestSuite.discover_tests[__functions_in_module()]().run()"
            ),
        )
    # A pattern user bytes CAN forge: a second block, extra rows, a dup name.
    if v == ReportVerdict.AMBIGUOUS:
        return _abnormal(
            Outcome.MALFORMED_SUITE,
            ParseDisposition.AMBIGUOUS,
            "malformed-suite",
            String("the report was ambiguous: ") + report.reason,
        )
    # A structural break the toolchain's own grammar rejects: the format moved.
    # Routes to exit 3 and contributes NOTHING to the exit-code multiset.
    if v == ReportVerdict.OFF_GRAMMAR:
        return Classification(
            Outcome.NOT_RUN,
            ParseDisposition.DRIFT,
            0,
            0,
            0,
            List[Outcome](),
            True,
            "drift",
            (
                "the report drifted off the pinned toolchain's grammar ("
                + report.reason
                + "); check the toolchain pin and tests/snapshots/protocol/"
                " against the file's own output"
            ),
        )

    # VALID: the report reconciled. The per-test counts are what the summary
    # showed, regardless of which outcomes ride the exit-code multiset.
    var p = report.summary_passed
    var f = report.summary_failed
    var s = report.summary_skipped
    var rows = _row_outcomes(report)

    if code == 0 and f == 0:
        # Clean per-test pass/skip (this includes the zero-test PASS).
        return Classification(
            Outcome.PASS, ParseDisposition.PARSED, p, f, s, rows^, False, "", ""
        )
    if code == 1 and f > 0:
        # The normal failing file: rows carry the attribution.
        return Classification(
            Outcome.FAIL, ParseDisposition.PARSED, p, f, s, rows^, False, "", ""
        )
    if code == 0 and f > 0:
        # WORSE-OF: the report lists failures but the process exited 0.
        return Classification(
            Outcome.FAIL,
            ParseDisposition.PARSED,
            p,
            f,
            s,
            rows^,
            False,
            "exit-status-mismatch",
            "the report lists failing tests but the process exited 0",
        )
    if code == 1 and f == 0:
        # WORSE-OF: exit 1 with no attributable failing test -> file-level FAIL.
        return Classification(
            Outcome.FAIL,
            ParseDisposition.PARSED,
            p,
            f,
            s,
            [Outcome.FAIL],
            False,
            "exit-status-mismatch",
            "the process exited 1 but the report lists no failing test",
        )

    # Exited(2..255) with a VALID report: an unexpected exit code disagreement.
    # The failing rows (if any) carry the attribution, else a file-level FAIL.
    var contribution: List[Outcome]
    if _any_failing(rows):
        contribution = rows^
    else:
        contribution = [Outcome.FAIL]
    return Classification(
        Outcome.FAIL,
        ParseDisposition.PARSED,
        p,
        f,
        s,
        contribution^,
        False,
        "exit-status-mismatch",
        String("unexpected exit code ") + String(code),
    )
