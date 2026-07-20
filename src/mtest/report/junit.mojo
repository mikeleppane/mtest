"""The pure JUnit XML renderer (Layer 2): typed suite state -> XML fragments.

This is the machine-report twin of the console and NDJSON renderers, for the
`--junit-xml` artifact. It is PURE: typed suite state in, XML strings out, no
I/O and no sink. The stateful shell that accumulates events, spools per-suite
fragments, and assembles the document lives in `junit_reporter`; this module
only knows how to turn a `JunitSuite` value into a valid `<testsuite>` fragment
and how to wrap a set of fragments in the `<testsuites>` root.

The dialect is the vendored junit-10 one (`scripts/schemas/junit-10.xsd`), the
same the committed `scripts/checks/reports/junit.py` oracle blesses:

- One `<testsuites>` root. It carries `name`, `tests`, `failures`, `errors` and
  NOT `skipped` — junit-10 defines no root `skipped`, so the root skipped total
  is an arithmetic fact recomputed from the child suites, never a root
  attribute.
- Each `<testsuite>` carries the four aggregate counts (INCLUDING `skipped`) and
  a decimal-seconds `time` from `format_seconds` — JUnit's own wall-clock
  policy, three fixed decimals, nonnegative, no exponent; separate from the JSON
  stream's integer-microsecond policy. Per-testcase `time` and suite `timestamp`
  are omitted (schema-optional).
- Each `<testcase>` carries `name` and `classname` and, optionally, ONE primary
  outcome child (`failure`/`error`/`skipped`, mixed-text body) and any number of
  ordered rerun/flaky children (`rerunFailure`/`rerunError`/`flakyFailure`/
  `flakyError`), each with a REQUIRED `type` and the optional `stackTrace`/
  `system-out`/`system-err` child sequence.

The count arithmetic is unconditional: per suite `tests == passing rows +
failures + errors + skipped`, counting sentinel rows; a row that carries only
rerun/flaky children (or nothing) is a passing row. The renderer computes those
counts from the rows it is given, so the declared attributes can never disagree
with the body.

Escaping is ONLY via the shared `xml_escape_text`/`xml_escape_attribute`; every
value that originates as raw child bytes is decoded through the shared
`lossy_utf8` first (see `bounded_text_from_bytes`). No CDATA, no second path.
"""
from mtest.config.lossy_utf8 import lossy_utf8
from mtest.report.escape import xml_escape_attribute, xml_escape_text

# The captured-stream head/tail windows mirror the JSON stream's bound (64 KiB
# head + 64 KiB tail); this layer cannot import the session constant, so the
# value is restated here with the same meaning.
comptime _JUNIT_HEAD = 65536
comptime _JUNIT_TAIL = 65536
comptime _ELISION: StaticString = "…"
"""The visible marker placed between a kept head window and tail window."""
comptime _TIME_CEIL = 9223372036854775807
"""The saturation ceiling (2**63 - 1) for the millisecond scaling in `time`."""


@fieldwise_init
struct JunitRerun(Copyable, Movable):
    """One `rerunFailure`/`rerunError`/`flakyFailure`/`flakyError` child.

    Its `type` is REQUIRED by the schema and is always emitted (even empty). The
    diagnostics ride as the optional ordered children `stackTrace`, `system-out`,
    `system-err`; an empty field is omitted. Owns its Strings; never raises.
    """

    var element: String
    """The child element name (`rerunFailure`/`rerunError`/`flakyFailure`/
    `flakyError`)."""
    var message: String
    """The optional `message` attribute value; omitted when empty."""
    var type_label: String
    """The REQUIRED `type` attribute value; always emitted."""
    var stack_trace: String
    """The `<stackTrace>` child body; omitted when empty."""
    var system_out: String
    """The `<system-out>` child body; omitted when empty."""
    var system_err: String
    """The `<system-err>` child body; omitted when empty."""


@fieldwise_init
struct JunitPrimary(Copyable, Movable):
    """A testcase's single primary outcome child: `failure`/`error`/`skipped`.

    Rendered as a mixed-text element (`<failure ...>body</failure>`), or
    self-closed when `body` is empty. Owns its Strings; never raises.
    """

    var element: String
    """`failure`, `error`, or `skipped` — what the outcome counts against."""
    var message: String
    """The optional `message` attribute value; omitted when empty."""
    var type_label: String
    """The optional `type` attribute value; omitted when empty."""
    var body: String
    """The mixed-text body; empty yields a self-closing element."""


@fieldwise_init
struct JunitCase(Copyable, Movable):
    """One `<testcase>` row: identity plus at most one primary and any reruns.

    A row with no primary (only reruns/flaky children, or none) is a PASSING row
    for the count arithmetic. `name` is emitted verbatim — sentinels like
    `[build]` are never renamed. Owns its Strings and lists; never raises.
    """

    var name: String
    """The `name` attribute — the full node id for a real test, or the bracket
    token for a sentinel; emitted verbatim."""
    var classname: String
    """The `classname` attribute (the suite's dotted stem)."""
    var has_primary: Bool
    """Whether `primary` carries a primary outcome child for this row."""
    var primary: JunitPrimary
    """The primary outcome child; consulted only when `has_primary`."""
    var reruns: List[JunitRerun]
    """The ordered rerun/flaky children, in presentation order."""


@fieldwise_init
struct JunitSuite(Copyable, Movable):
    """The typed state of one `<testsuite>` before rendering.

    `cases` may be given in any order; `render_suite` sorts them by the frozen
    node-id key. Suite-scope captured streams attach ONCE here as `system_out`/
    `system_err`. Owns its Strings and list; never raises.
    """

    var name: String
    """The suite `name` — the exact root-relative path (or a session-level id
    like `mtest::precompile`)."""
    var time_seconds: Float64
    """The suite wall clock, rendered by `format_seconds`."""
    var cases: List[JunitCase]
    """The rows, in any order (sorted at render time)."""
    var system_out: String
    """Suite-level captured stdout, already bounded/decoded; omitted when empty.
    """
    var system_err: String
    """Suite-level captured stderr, already bounded/decoded; omitted when empty.
    """


@fieldwise_init
struct RenderedSuite(Copyable, Movable):
    """A rendered `<testsuite>` fragment plus its aggregate counts.

    The `body` is the whole fragment string; the counts let the assembler sum
    the root totals without re-parsing. `suite_key` is the frozen order key for
    the suite (its name). Owns its Strings; never raises.
    """

    var suite_key: String
    """The order key for the suite (its `name`)."""
    var body: String
    """The complete `<testsuite>...</testsuite>` fragment."""
    var tests: Int
    """The suite's `tests` count."""
    var failures: Int
    """The suite's `failures` count."""
    var errors: Int
    """The suite's `errors` count."""
    var skipped: Int
    """The suite's `skipped` count."""


def _bytes_to_string(bytes: List[UInt8]) -> String:
    """Render `bytes` as a `String`. Pure; the caller guarantees valid UTF-8."""
    # SAFETY: `unsafe_from_utf8` requires well-formed UTF-8. The only caller
    # (`dotted_classname`) copies already-valid-UTF-8 bytes through unchanged and
    # swaps only the single ASCII byte '/' (0x2F) for '.' (0x2E), so no
    # multi-byte sequence is ever split and no invalid byte is introduced.
    return String(StringSlice(unsafe_from_utf8=Span(bytes)))


def format_seconds(seconds: Float64) -> String:
    """A duration in seconds as fixed-three-decimal seconds. Pure; never raises.

    JUnit's own `time` policy, distinct from the JSON stream's integer
    microseconds: a nonnegative decimal with exactly three fractional digits and
    no exponent. A negative or NaN input clamps to `0.000`; a pathologically
    large input saturates rather than overflowing the millisecond scaling.

    Args:
        seconds: The wall-clock duration to format. Not mutated.

    Returns:
        `"<whole>.<3 digits>"`, e.g. `"0.043"`. Does not raise.
    """
    if not (seconds > 0.0):
        return "0.000"
    var scaled = seconds * 1000.0
    var ms: Int
    if scaled >= Float64(_TIME_CEIL):
        ms = _TIME_CEIL
    else:
        ms = Int(scaled + 0.5)
    var whole = ms // 1000
    var frac = ms % 1000
    var fs = String(frac)
    var out = String(whole) + "."
    for _ in range(3 - fs.byte_length()):
        out += "0"
    out += fs
    return out^


def dotted_classname(path: String) -> String:
    """The dashboard-safe dotted stem of a root-relative path. Pure.

    `/` becomes `.` and a trailing `.mojo` is dropped, so
    `e2e/suite/test_x.mojo` becomes `e2e.suite.test_x`. Dot-damage from a path
    segment that itself contains a dot is acknowledged and accepted — the stem is
    for grouping in dashboards, not for round-tripping back to a path.

    Args:
        path: The root-relative path. Not mutated.

    Returns:
        The dotted stem. Does not raise.
    """
    var noext = String(path.removesuffix(".mojo"))
    var out = List[UInt8]()
    for b in noext.as_bytes():
        if Int(b) == 47:  # '/'
            out.append(46)  # '.'
        else:
            out.append(b)
    return _bytes_to_string(out)


def node_sort_key(suite_name: String, case_name: String) -> String:
    """The frozen node-id sort key for a testcase. Pure; never raises.

    The sentinel carve-out: a `case_name` that already CONTAINS `::` is its own
    node id and is used verbatim (real tests carry `path::name`); otherwise the
    node id is reconstructed as `suite_name + "::" + case_name` (a bracket
    sentinel like `[build]` becomes `path::[build]`). The key orders BOTH row
    kinds; sentinels are never renamed, only keyed.

    Args:
        suite_name: The suite's name (its path). Not mutated.
        case_name: The testcase's `name` attribute. Not mutated.

    Returns:
        The node-id string used as the row order key. Does not raise.
    """
    if "::" in case_name:
        return case_name.copy()
    return suite_name + "::" + case_name


def bounded_text_from_bytes(data: List[UInt8]) -> String:
    """Decode raw captured bytes to bounded text for a report body. Pure.

    Mirrors the stream's head+tail bound (64 KiB each) so no single capture can
    unbound a fragment: when the data fits it is decoded whole through the shared
    `lossy_utf8`; otherwise the first and last windows are decoded independently
    (so a multi-byte sequence split at either boundary degrades to U+FFFD rather
    than swallowing the marker) and joined by the elision marker. The result is
    plain text ready for `xml_escape_text` at render time — the single escaping
    path.

    Args:
        data: The raw captured bytes. Not mutated.

    Returns:
        The bounded, lossy-decoded text. Does not raise.
    """
    var n = len(data)
    if n <= _JUNIT_HEAD + _JUNIT_TAIL:
        return lossy_utf8(data)
    var head = List[UInt8]()
    for i in range(_JUNIT_HEAD):
        head.append(data[i])
    var tail = List[UInt8]()
    for i in range(n - _JUNIT_TAIL, n):
        tail.append(data[i])
    return lossy_utf8(head) + _ELISION + lossy_utf8(tail)


def _render_primary(p: JunitPrimary) -> String:
    """Render one primary outcome child. Pure; never raises."""
    var s = "<" + p.element
    if p.message != "":
        s += ' message="' + xml_escape_attribute(p.message) + '"'
    if p.type_label != "":
        s += ' type="' + xml_escape_attribute(p.type_label) + '"'
    if p.body == "":
        s += "/>"
    else:
        s += ">" + xml_escape_text(p.body) + "</" + p.element + ">"
    return s^


def _render_rerun(r: JunitRerun) -> String:
    """Render one rerun/flaky child; `type` is always emitted. Pure."""
    var s = "<" + r.element
    if r.message != "":
        s += ' message="' + xml_escape_attribute(r.message) + '"'
    s += ' type="' + xml_escape_attribute(r.type_label) + '"'
    var body = String("")
    if r.stack_trace != "":
        body += (
            "<stackTrace>" + xml_escape_text(r.stack_trace) + "</stackTrace>"
        )
    if r.system_out != "":
        body += "<system-out>" + xml_escape_text(r.system_out) + "</system-out>"
    if r.system_err != "":
        body += "<system-err>" + xml_escape_text(r.system_err) + "</system-err>"
    if body == "":
        s += "/>"
    else:
        s += ">" + body + "</" + r.element + ">"
    return s^


def _render_case(c: JunitCase) -> String:
    """Render one `<testcase>` row with its primary and reruns. Pure."""
    var s = (
        '<testcase name="'
        + xml_escape_attribute(c.name)
        + '" classname="'
        + xml_escape_attribute(c.classname)
        + '"'
    )
    var inner = String("")
    if c.has_primary:
        inner += _render_primary(c.primary)
    for i in range(len(c.reruns)):
        inner += _render_rerun(c.reruns[i])
    if inner == "":
        s += "/>"
    else:
        s += ">" + inner + "</testcase>"
    return s^


def _less(a: String, b: String) -> Bool:
    """Bytewise lexicographic `a < b`. Pure; total; never raises."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var na = len(ab)
    var nb = len(bb)
    var m = na if na < nb else nb
    for i in range(m):
        if ab[i] != bb[i]:
            return Int(ab[i]) < Int(bb[i])
    return na < nb


def render_suite(suite: JunitSuite) -> RenderedSuite:
    """Render one `<testsuite>` fragment, node-id-sorted, with computed counts.

    The rows are ordered by the frozen `node_sort_key`; the aggregate counts are
    RECOMPUTED from the rows (a `failure`/`error`/`skipped` primary counts once
    against its class, every other row is passing), so the declared attributes
    can never disagree with the body. Suite-scope `system_out`/`system_err`
    attach after the rows. Pure; never raises.

    Args:
        suite: The typed suite state. Not mutated.

    Returns:
        The rendered fragment plus its counts and order key.
    """
    var n = len(suite.cases)
    var keys = List[String]()
    for i in range(n):
        keys.append(node_sort_key(suite.name, suite.cases[i].name))
    var order = List[Int]()
    for i in range(n):
        order.append(i)
    for i in range(1, n):
        var j = i
        while j > 0 and _less(keys[order[j]], keys[order[j - 1]]):
            var t = order[j]
            order[j] = order[j - 1]
            order[j - 1] = t
            j -= 1

    var failures = 0
    var errors = 0
    var skipped = 0
    for i in range(n):
        if suite.cases[i].has_primary:
            if suite.cases[i].primary.element == "failure":
                failures += 1
            elif suite.cases[i].primary.element == "error":
                errors += 1
            elif suite.cases[i].primary.element == "skipped":
                skipped += 1

    var body = '<testsuite name="' + xml_escape_attribute(suite.name) + '"'
    body += ' tests="' + String(n) + '"'
    body += ' failures="' + String(failures) + '"'
    body += ' errors="' + String(errors) + '"'
    body += ' skipped="' + String(skipped) + '"'
    body += ' time="' + format_seconds(suite.time_seconds) + '">'
    for i in range(n):
        body += _render_case(suite.cases[order[i]])
    if suite.system_out != "":
        body += (
            "<system-out>" + xml_escape_text(suite.system_out) + "</system-out>"
        )
    if suite.system_err != "":
        body += (
            "<system-err>" + xml_escape_text(suite.system_err) + "</system-err>"
        )
    body += "</testsuite>"
    return RenderedSuite(suite.name.copy(), body^, n, failures, errors, skipped)


def assemble(root_name: String, frags: List[RenderedSuite]) -> String:
    """Wrap suite fragments in a node-id-sorted `<testsuites>` document. Pure.

    The fragments are ordered by their suite key; the root `tests`/`failures`/
    `errors` are the sums over the suites. The root carries NO `skipped`
    attribute — junit-10 defines none, so the root skipped total lives only in
    the arithmetic the oracle recomputes. Never raises.

    Args:
        root_name: The `<testsuites>` `name` (e.g. `"mtest"`). Not mutated.
        frags: The rendered suite fragments, in any order. Not mutated.

    Returns:
        The complete, well-formed `<testsuites>` document with a leading XML
        declaration and a trailing newline.
    """
    var n = len(frags)
    var order = List[Int]()
    for i in range(n):
        order.append(i)
    for i in range(1, n):
        var j = i
        while j > 0 and _less(
            frags[order[j]].suite_key, frags[order[j - 1]].suite_key
        ):
            var t = order[j]
            order[j] = order[j - 1]
            order[j - 1] = t
            j -= 1

    var tests = 0
    var failures = 0
    var errors = 0
    for i in range(n):
        tests += frags[i].tests
        failures += frags[i].failures
        errors += frags[i].errors

    var doc = String('<?xml version="1.0" encoding="UTF-8"?>\n')
    doc += '<testsuites name="' + xml_escape_attribute(root_name) + '"'
    doc += ' tests="' + String(tests) + '"'
    doc += ' failures="' + String(failures) + '"'
    doc += ' errors="' + String(errors) + '">\n'
    for i in range(n):
        doc += frags[order[i]].body + "\n"
    doc += "</testsuites>\n"
    return doc^
