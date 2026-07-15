"""The TOTAL per-test classifier of the session layer (Layer 4).

`run_verdict` maps a bare RUN `Termination` to an outcome from the exit status
alone. That is not enough: a file that built and exited 0 while running ZERO
tests, or one that spoke no report at all, is not honestly a PASS. `classify`
closes that "zero-test ceiling" by folding three facts together — the RUN
termination, the run's OWN parsed report, and whether the capture overflowed —
into one honest verdict. On the default run path there is no separate probe: the
run's own report IS the handshake.

The policy is TOTAL over every child fate and is pinned, row by row, in
`tests/unit/test_session_classify.mojo`. In precedence order:

- `Signaled(_)`      -> CRASH   (the parser is UNCONSULTED — a crash is a crash).
- `TimedOut`         -> TIMEOUT (latched; a valid report does not rescue it).
- `Exited`, capture overflowed with no valid report retained in the tail
                     -> FAIL / CAPTURE_OVERFLOW (never PASS, never drift).
- `Exited`, report ABSENT / AMBIGUOUS  -> MALFORMED_SUITE (the file ran but
                     spoke no honest report).
- `Exited`, report OFF_GRAMMAR         -> DRIFT: the report shape moved from the
                     pinned toolchain. Routes to exit 3, contributes NOTHING to
                     the exit-code multiset. The sanctioned-rare path.
- `Exited`, report VALID               -> PASS/FAIL per the reconciled report,
                     with the exit status cross-checked (a WORSE-OF rule: exit 0
                     with failing rows, or exit 1 with none, is still a FAIL).

Both functions here are PURE: no I/O, no FFI, no raising. The session layer does
the decode and the parse and then hands the results in; `classify` decides the
policy and `resolve_report` decides WHICH report to trust under truncation.
"""
from mtest.exec import Termination
from mtest.model import Outcome, ParseDisposition
from mtest.protocol import ParsedReport, ParsedRow, ReportVerdict, parse_report


comptime _TRUNCATION_MARKER = "[mtest: output truncated"
"""The prefix the capture layer splices at the head of its omission marker line."""


@fieldwise_init
struct Classification(Copyable, Movable):
    """The full result of classifying one file's run. Owns its lists/strings.

    Carries everything the session needs to emit the file's events and account
    for it: the file-level `file_outcome` (tallied once in the per-file summary),
    the `disposition` (why the report parse landed where it did), the per-test
    counts (what the summary line showed), the `exit_outcomes` multiset
    contribution (per-test outcomes for a VALID file, else the single file-level
    outcome, else empty for drift), the `is_drift` flag (routes to exit 3), and
    the loud-warning info (`warning_kind`/`warning_detail`, both `""` if none).
    """

    var file_outcome: Outcome
    """The file-level outcome tallied once in the per-file `Summary`."""
    var disposition: ParseDisposition
    """Why the report parse landed where it did (rides the FileFinished event)."""
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
    """A short tag for the loud warning this classification demands (`""` none)."""
    var warning_detail: String
    """The human sentence the reporter renders for the warning (`""` if none)."""


@fieldwise_init
struct TrustedReport(Copyable, Movable):
    """Which report to trust for a run, plus whether the capture overflowed.

    On a truncated capture a report survives ONLY if a complete valid block is
    wholly retained in the tail; otherwise `is_overflow` is set and `report` is
    a placeholder the classifier ignores.
    """

    var report: ParsedReport
    """The report the classifier should consult (a placeholder when overflow)."""
    var is_overflow: Bool
    """Whether a truncated capture lost the report (no valid block in the tail)."""


def _tail_after_marker(text: String) -> String:
    """The substring AFTER the truncation marker LINE, or `""` if none is found.

    The capture layer splices a single loud marker line (opening
    `[mtest: output truncated`) between the retained head and the surviving tail.
    Everything after that line is the tail the report parser reparses.

    Anchors on the LAST matching line, not the first: a test's own stdout lands
    in the retained HEAD (before the genuine spliced marker) and a malicious or
    buggy test could print a line that itself opens with the marker prefix,
    forging an earlier split point. Taking the last occurrence is strictly
    conservative — it can only shrink the trusted tail toward the genuine one,
    never expand it into truncated-away or forged head bytes. Pure.
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

    A truncated capture must NEVER yield a successful verdict unless a complete
    valid block survived wholly in the TAIL: parse only the text after the marker
    line and, if that tail parses VALID, trust it as a normal report (NOT
    overflow). Otherwise the report was lost to truncation and `is_overflow` is
    set. An untruncated capture is parsed whole. Pure; never raises.

    Args:
        stdout_text: The child's lossy-decoded stdout. Not mutated.
        source_path: The canonical path the report header must byte-equal.
        truncated: Whether the capture overflowed its bound (marker spliced).

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
    """The per-row outcomes of a VALID report, in row order. Pure."""
    var out = List[Outcome]()
    for r in report.rows:
        out.append(r.outcome)
    return out^


def _any_failing(outcomes: List[Outcome]) -> Bool:
    """Whether any outcome in the list is in the failing class. Pure."""
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
    """A file-level (non-per-test) classification whose sole multiset entry is
    its own outcome. Pure."""
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
    """Classify one file's run into the TOTAL policy. Pure; never raises.

    The session handles the three cases BEFORE the classifier: a build
    COMPILE_ERROR, a run `SpawnFailed` (internal error, exit 3), and a run
    `TimedOut` while an interrupt is pending (interrupt, exit 2). Everything else
    reaches here with the RUN termination, the report to trust (already resolved
    for capture overflow), and the `is_overflow` bool.

    Args:
        t: The RUN termination (Signaled / TimedOut / Exited only, here).
        report: The report to consult (ignored when `is_overflow`). Not mutated.
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
                + "); check the toolchain pin and goldens/transcripts/ against"
                " the file's own output"
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
