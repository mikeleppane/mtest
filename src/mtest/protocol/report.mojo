"""The report parser (Layer 2): one file's stdout to one of four verdicts.

`parse_report` reads the decoded stdout of a single child `std.testing.TestSuite`
binary and classifies it as VALID / ABSENT / OFF_GRAMMAR / AMBIGUOUS. It is
PURE: it imports only `model`, performs no I/O, holds no FFI, decides no policy,
and never raises. The session (a higher layer) owns the decode and turns the
verdict into policy; this module only reads bytes.

The grammar is exactly what the pinned toolchain emits, frozen in the golden
transcripts under `goldens/transcripts/`. Trailing spaces are load-bearing. A
report block for a file whose canonical path is `P`:

    Running <N> tests for <P>                (header, trailing space, P byte-exact)
        PASS|FAIL|SKIP [ <t> ] <name>        (row: 4 spaces; <t> matched loosely)
          <detail...>                        (FAIL detail: MORE-indented lines)
    --------                                 (the rule: exactly 8 dashes)
    Summary [ <t> ] <N> tests run: <p> passed , <f> failed , <s> skipped
    Test suite' <P> 'failed!                 (trailer, present iff f>0)

The classifier's central discipline: the report grammar is the toolchain's, so a
structural break a user's own stdout CANNOT forge (a missing rule, a broken
count, a fabricated failure trailer, drift from the pinned shape) is OFF_GRAMMAR,
while a pattern user bytes CAN produce (a second appended block, more rows than
declared, a duplicate name) is AMBIGUOUS. Identity is EXACT byte-equality on the
header path, never a suffix — a same-suffix-different-root impostor simply fails
to match and the report reads ABSENT.

Precedence (the checks fire in this order; the first to fire decides):
  1. No header whose path byte-equals `source_path`            -> ABSENT
  2. Header present but no terminal Summary                    -> OFF_GRAMMAR
     Summary present but the preceding line is not the rule    -> OFF_GRAMMAR
  3. Two or more complete matching-path blocks                 -> AMBIGUOUS
  4. A row whose name is empty/whitespaced/`::`-bearing        -> OFF_GRAMMAR
     A row name duplicated within the block                    -> AMBIGUOUS
     A non-row line in the rows region with no preceding FAIL  -> OFF_GRAMMAR
  5. Fewer rows than the header declared                       -> OFF_GRAMMAR
     More rows than the header declared                        -> AMBIGUOUS
     Rows == declared but the count arithmetic disagrees       -> OFF_GRAMMAR
  6. A failure trailer naming a different path                 -> OFF_GRAMMAR
     Trailer present with f==0, or absent with f>0             -> OFF_GRAMMAR
  7. Otherwise                                                 -> VALID
"""
from mtest.model import Outcome


@fieldwise_init
struct ReportVerdict(Equatable, ImplicitlyCopyable, Movable):
    """How a child's stdout classified against one file's report grammar."""

    var code: Int
    """The stable integer discriminant identifying this verdict."""

    comptime VALID = Self(0)
    """A single well-formed report block for `source_path`."""
    comptime ABSENT = Self(1)
    """No matching-path header at all (crash, other file, or no report)."""
    comptime OFF_GRAMMAR = Self(2)
    """A genuine matching header whose bytes violate the pinned grammar."""
    comptime AMBIGUOUS = Self(3)
    """A pattern user bytes can produce: extra blocks/rows, dup names, forgery."""

    comptime COUNT = 4
    """The number of distinct verdicts."""

    def __eq__(self, other: Self) -> Bool:
        """Two verdicts are equal iff their discriminants match. Pure."""
        return self.code == other.code

    def __ne__(self, other: Self) -> Bool:
        """Negation of `__eq__`. Pure."""
        return self.code != other.code


@fieldwise_init
struct ParsedRow(Copyable, Movable):
    """One parsed per-test result row. Owns its strings; copies are explicit."""

    var name: String
    """The test name: nonempty, whitespace-free, `::`-free, unique in the block.
    """
    var outcome: Outcome
    """The row's outcome: PASS, FAIL, or SKIP only."""
    var detail: String
    """A FAIL's verbatim detail lines, newline-joined (`""` otherwise)."""
    var timing: String
    """The raw timing token as captured, never interpreted (`""` if absent)."""


@fieldwise_init
struct ParsedReport(Copyable, Movable):
    """The classified result of parsing one file's report. Owns its rows."""

    var verdict: ReportVerdict
    """Which of the four verdicts the stdout classified as."""
    var rows: List[ParsedRow]
    """The parsed rows, populated only for VALID (empty otherwise)."""
    var declared_count: Int
    """The header's declared test count `N` (0 for non-VALID)."""
    var summary_passed: Int
    """The Summary line's passed tally (0 for non-VALID)."""
    var summary_failed: Int
    """The Summary line's failed tally (0 for non-VALID)."""
    var summary_skipped: Int
    """The Summary line's skipped tally (0 for non-VALID)."""
    var has_trailer: Bool
    """Whether the `Test suite' ... 'failed!` trailer was present."""
    var reason: String
    """A short phrase naming the defect for OFF_GRAMMAR/AMBIGUOUS (`""` else)."""

    @staticmethod
    def absent() -> Self:
        """An ABSENT report: no matching header. Allocates empty rows."""
        return Self(
            ReportVerdict.ABSENT, List[ParsedRow](), 0, 0, 0, 0, False, ""
        )

    @staticmethod
    def off_grammar(reason: String) -> Self:
        """An OFF_GRAMMAR report carrying `reason`. Allocates empty rows."""
        return Self(
            ReportVerdict.OFF_GRAMMAR,
            List[ParsedRow](),
            0,
            0,
            0,
            0,
            False,
            reason,
        )

    @staticmethod
    def ambiguous(reason: String) -> Self:
        """An AMBIGUOUS report carrying `reason`. Allocates empty rows."""
        return Self(
            ReportVerdict.AMBIGUOUS,
            List[ParsedRow](),
            0,
            0,
            0,
            0,
            False,
            reason,
        )

    @staticmethod
    def valid(
        var rows: List[ParsedRow],
        declared: Int,
        passed: Int,
        failed: Int,
        skipped: Int,
        has_trailer: Bool,
    ) -> Self:
        """A VALID report with its rows and reconciled counts. Takes `rows`."""
        return Self(
            ReportVerdict.VALID,
            rows^,
            declared,
            passed,
            failed,
            skipped,
            has_trailer,
            "",
        )


@fieldwise_init
struct _SummaryParse(ImplicitlyCopyable, Movable):
    """The outcome of matching one line against the Summary grammar."""

    var ok: Bool
    var total: Int
    var passed: Int
    var failed: Int
    var skipped: Int


@fieldwise_init
struct _RowParse(ImplicitlyCopyable, Movable):
    """The outcome of matching one line against the result-row grammar."""

    var is_row: Bool
    var outcome: Outcome
    var timing: String
    var name: String


@fieldwise_init
struct _TrailerParse(ImplicitlyCopyable, Movable):
    """The outcome of matching one line against the failure-trailer grammar."""

    var is_trailer: Bool
    var path: String


def _split_lines(text: String) -> List[String]:
    """Split `text` into owned lines on `\\n`. Allocates; never raises."""
    var out = List[String]()
    for line in text.split("\n"):
        out.append(String(line))
    return out^


def _parse_nonneg_int(s: String) -> Int:
    """`s` as a non-negative decimal integer, or -1 if it is not one.

    A non-raising replacement for `Int(s)`: `parse_report` must never raise, so
    every integer field is validated digit-by-digit here. Pure.
    """
    if s.byte_length() == 0:
        return -1
    var value = 0
    for cp in s.codepoints():
        var v = Int(cp)
        if v < 48 or v > 57:
            return -1
        value = value * 10 + (v - 48)
    return value


def _header_n(line: String, source_path: String) -> Int:
    """The declared count `N` if `line` is a matching header, else -1.

    A matching header is EXACTLY `Running <N> tests for <source_path> ` — the
    trailing space and the byte-exact path are both required. Pure.
    """
    var prefix = "Running "
    if not line.startswith(prefix):
        return -1
    var suffix = " tests for " + source_path + " "
    if not line.endswith(suffix):
        return -1
    var body = String(line.removeprefix(prefix))
    var n_str = String(body.removesuffix(suffix))
    return _parse_nonneg_int(n_str)


def _parse_summary(line: String) -> _SummaryParse:
    """Match `line` against the Summary grammar and extract its tallies.

    Requires the full pinned shape including the trailing space; anything short
    of it is not a Summary line (`ok == False`). Pure.
    """
    var miss = _SummaryParse(False, 0, 0, 0, 0)
    if not line.startswith("Summary [ "):
        return miss
    var after_prefix = String(line.removeprefix("Summary [ "))
    var brk = after_prefix.split(" ] ", 1)
    if len(brk) < 2:
        return miss
    var body = String(brk[1])
    var tr = body.split(" tests run: ", 1)
    if len(tr) < 2:
        return miss
    var total = _parse_nonneg_int(String(tr[0]))
    if total < 0:
        return miss
    var parts = String(tr[1]).split(" , ")
    if len(parts) != 3:
        return miss
    var p0 = String(parts[0])
    var p1 = String(parts[1])
    var p2 = String(parts[2])
    if not p0.endswith(" passed"):
        return miss
    if not p1.endswith(" failed"):
        return miss
    if not p2.endswith(" skipped "):
        return miss
    var pv = _parse_nonneg_int(String(p0.split(" ")[0]))
    var fv = _parse_nonneg_int(String(p1.split(" ")[0]))
    var sv = _parse_nonneg_int(String(p2.split(" ")[0]))
    if pv < 0 or fv < 0 or sv < 0:
        return miss
    return _SummaryParse(True, total, pv, fv, sv)


def _row_after(line: String, prefix: String, oc: Outcome) -> _RowParse:
    """Extract the timing and name of a row after its `prefix`. Pure.

    A row whose ` ] ` separator is missing comes back with an empty name for the
    caller to reject as malformed.
    """
    var rest = String(line.removeprefix(prefix))
    var parts = rest.split(" ] ", 1)
    if len(parts) < 2:
        return _RowParse(True, oc, "", "")
    return _RowParse(True, oc, String(parts[0]), String(parts[1]))


def _parse_row(line: String) -> _RowParse:
    """Match `line` against the result-row grammar (4 spaces, outcome, timing).

    Returns `is_row == True` for any line opening with a row prefix; a non-row
    line comes back with `is_row == False`. Pure.
    """
    if line.startswith("    PASS [ "):
        return _row_after(line, "    PASS [ ", Outcome.PASS)
    if line.startswith("    FAIL [ "):
        return _row_after(line, "    FAIL [ ", Outcome.FAIL)
    if line.startswith("    SKIP [ "):
        return _row_after(line, "    SKIP [ ", Outcome.SKIP)
    return _RowParse(False, Outcome.PASS, "", "")


def _valid_row_name(name: String) -> Bool:
    """Whether `name` is nonempty, whitespace-free, and `::`-free. Pure."""
    if name.byte_length() == 0:
        return False
    if "::" in name:
        return False
    for cp in name.codepoints():
        var v = Int(cp)
        # space, tab, newline, carriage return.
        if v == 32 or v == 9 or v == 10 or v == 13:
            return False
    return True


def _parse_trailer(line: String) -> _TrailerParse:
    """Match `line` against the failure-trailer grammar and extract its path.

    The trailer is `Test suite' <P> 'failed! ` (note the misquoting and the
    trailing space, both from the toolchain). Pure.
    """
    var prefix = "Test suite' "
    var suffix = " 'failed! "
    if line.startswith(prefix) and line.endswith(suffix):
        var body = String(line.removeprefix(prefix))
        var path = String(body.removesuffix(suffix))
        return _TrailerParse(True, path)
    return _TrailerParse(False, "")


def parse_report(stdout_text: String, source_path: String) -> ParsedReport:
    """Classify one child's decoded stdout against `source_path`'s report grammar.

    Pure and total: every input maps to exactly one `ParsedReport`, performs no
    I/O, and never raises. See the module docstring for the grammar and the
    full classification precedence.

    Args:
        stdout_text: The child's stdout, already lossy-decoded to a String by
            the caller. Not mutated.
        source_path: The canonical source path the header must byte-equal for a
            block to be this file's report. Not mutated.

    Returns:
        The verdict plus, for VALID, the parsed rows and reconciled counts.
        Allocates the rows list. Never raises.
    """
    var lines = _split_lines(stdout_text)
    var n = len(lines)

    # 1. Identity: collect every header whose path byte-equals source_path.
    var header_idx = List[Int]()
    var header_n = List[Int]()
    for i in range(n):
        var hn = _header_n(lines[i], source_path)
        if hn >= 0:
            header_idx.append(i)
            header_n.append(hn)
    if len(header_idx) == 0:
        return ParsedReport.absent()

    # 2. Terminal framing, scanned from the END.
    var summary_i = -1
    for i in range(n - 1, -1, -1):
        if _parse_summary(lines[i]).ok:
            summary_i = i
            break
    if summary_i < 0:
        return ParsedReport.off_grammar(
            "matching header without terminal framing"
        )
    if summary_i == 0 or lines[summary_i - 1] != "--------":
        return ParsedReport.off_grammar("missing rule before summary")
    var rule_i = summary_i - 1
    var summ = _parse_summary(lines[summary_i])

    # 3. Reject two or more complete matching-path blocks (a forgery).
    var complete_blocks = 0
    for k in range(len(header_idx)):
        var start = header_idx[k]
        var stop = n
        if k + 1 < len(header_idx):
            stop = header_idx[k + 1]
        for j in range(start + 1, stop - 1):
            if lines[j] == "--------" and _parse_summary(lines[j + 1]).ok:
                complete_blocks += 1
                break
    if complete_blocks >= 2:
        return ParsedReport.ambiguous("multiple complete report blocks")

    # The anchor is the last matching header before the terminal rule.
    var anchor = -1
    var declared = 0
    for k in range(len(header_idx)):
        if header_idx[k] < rule_i:
            anchor = header_idx[k]
            declared = header_n[k]
    if anchor < 0:
        return ParsedReport.off_grammar(
            "matching header without terminal framing"
        )

    # 4. Rows region: strictly between the anchor header and the terminal rule.
    var rows = List[ParsedRow]()
    for i in range(anchor + 1, rule_i):
        var line = String(lines[i])
        var rp = _parse_row(line)
        if rp.is_row:
            if not _valid_row_name(rp.name):
                return ParsedReport.off_grammar("malformed row name")
            for r in rows:
                if r.name == rp.name:
                    return ParsedReport.ambiguous("duplicate row name")
            rows.append(ParsedRow(rp.name, rp.outcome, "", rp.timing))
        else:
            # A non-row line is FAIL detail; it must follow a FAIL row.
            var li = len(rows) - 1
            if li < 0 or rows[li].outcome != Outcome.FAIL:
                return ParsedReport.off_grammar("noise in structural position")
            var existing = rows[li].detail
            if existing.byte_length() == 0:
                rows[li].detail = line
            else:
                rows[li].detail = existing + "\n" + line

    # 5. Reconcile the three independent counts.
    var rows_count = len(rows)
    if rows_count < declared:
        return ParsedReport.off_grammar("fewer rows than declared")
    if rows_count > declared:
        return ParsedReport.ambiguous("more rows than declared")
    var rp_pass = 0
    var rp_fail = 0
    var rp_skip = 0
    for r in rows:
        if r.outcome == Outcome.PASS:
            rp_pass += 1
        elif r.outcome == Outcome.FAIL:
            rp_fail += 1
        elif r.outcome == Outcome.SKIP:
            rp_skip += 1
    if (
        summ.total != declared
        or (summ.passed + summ.failed + summ.skipped) != summ.total
        or rp_pass != summ.passed
        or rp_fail != summ.failed
        or rp_skip != summ.skipped
    ):
        return ParsedReport.off_grammar("broken count arithmetic")

    # 6. Trailer consistency and path identity.
    var has_trailer = False
    for i in range(summary_i + 1, n):
        var tp = _parse_trailer(lines[i])
        if tp.is_trailer:
            if tp.path != source_path:
                return ParsedReport.off_grammar("trailer path mismatch")
            has_trailer = True
    if has_trailer and summ.failed == 0:
        return ParsedReport.off_grammar("trailer/failure-count inconsistency")
    if (not has_trailer) and summ.failed > 0:
        return ParsedReport.off_grammar("trailer/failure-count inconsistency")

    # 7. A single well-formed block for source_path.
    return ParsedReport.valid(
        rows^, declared, summ.passed, summ.failed, summ.skipped, has_trailer
    )
