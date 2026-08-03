"""The pure Markdown fragment renderer for the run report.

Each function here turns one `report_model` value into a self-contained
Markdown fragment: no function reads another's output, and none does I/O —
assembling fragments into one streamed document is the report writer's job,
not this module's. Every fragment obeys the placement policy `report_text`
documents: a table cell or other inline value goes through `escape_scalar`
(via `md_escape_cell` / `md_code_span`), and a fenced block of untrusted
multi-line text goes through `escape_multiline` first. A reproduce or debug
target is additionally shell-quoted, through `shell_quote(escape_scalar(...))`,
so the emitted command is copy-paste safe even when the underlying path or
node id is hostile.

`md_header` and `md_summary_table_header` open the document; `md_summary_row`,
`md_file_section`, and `md_not_run_line` render one row/section/reason each;
`md_machine_index` closes it with a flat, grep-friendly list of every row that
needs a second look (see `report_model.needs_action` for the exact outcome
set, shared with `html_machine_index` so the ruling cannot drift between
renderings).
"""
from mtest.config import shell_quote
from mtest.model import NotRunRecord, Outcome, not_run_reason_label
from mtest.report.console_text import escape_multiline, escape_scalar
from mtest.report.junit import format_seconds
from mtest.report.report_model import (
    ReportFinalizeContext,
    ReportHeaderFacts,
    ReportRow,
    ReportSectionInput,
    needs_action,
    outcome_label,
)
from mtest.report.report_text import (
    md_code_fence,
    md_code_span,
    md_escape_cell,
    normalize_detail,
)


def md_header(facts: ReportHeaderFacts, ctx: ReportFinalizeContext) -> String:
    """The document-opening banner: version, platform, and the run's facts.

    Every count below the title line is conditional except the tests and
    wall-time lines: a fact that did not apply to this run (no cache
    admissions, a single worker, an unshuffled order, no shard, no
    interrupt, no drift) renders no line at all, so a plain run's header
    stays short.

    Args:
        facts: The build-time version and platform labels. Not mutated.
        ctx: The run-wide facts gathered at finalize. Not mutated.

    Returns:
        The header fragment, ending in a blank line.
    """
    var out = String("# mtest report\n\n")
    out += (
        "mtest "
        + md_escape_cell(facts.version)
        + " ("
        + md_escape_cell(facts.platform)
        + ")\n\n"
    )
    out += "wall time: " + format_seconds(ctx.wall_seconds) + "s\n"
    out += (
        "tests: "
        + String(ctx.tests_passed)
        + " passed, "
        + String(ctx.tests_failed)
        + " failed, "
        + String(ctx.tests_skipped)
        + " skipped\n"
    )
    var files = String("")
    for code in range(len(ctx.counts)):
        var n = ctx.counts[code]
        if n == 0:
            continue
        if files.byte_length() > 0:
            files += ", "
        files += String(n) + " " + outcome_label(code)
    if files.byte_length() > 0:
        out += "files: " + files + "\n"
    if ctx.built_files + ctx.cached_files > 0:
        out += (
            "builds: "
            + String(ctx.built_files)
            + " built, "
            + String(ctx.cached_files)
            + " cached\n"
        )
    if ctx.flaky_files > 0:
        out += "flaky: " + String(ctx.flaky_files) + "\n"
    if ctx.workers > 1:
        out += "workers: " + String(ctx.workers) + "\n"
    if ctx.shuffle:
        out += "shuffle seed: " + String(ctx.shuffle_seed) + "\n"
    if ctx.shard_label.byte_length() > 0:
        out += "shard: " + md_escape_cell(ctx.shard_label) + "\n"
    if ctx.interrupted:
        out += "interrupted: yes\n"
    if ctx.drift:
        out += "drift: yes\n"
    out += "\n"
    return out^


def md_summary_table_header() -> String:
    """The Markdown table header + alignment row for the summary table.

    Returns:
        Two lines: the column names, then the CommonMark alignment row.
    """
    return (
        "| Path | Outcome | Duration (s) | Passed | Failed | Skipped |"
        " Attempts |\n"
        + "| --- | --- | --- | --- | --- | --- | --- |\n"
    )


def md_summary_row(row: ReportRow) -> String:
    """One file's row in the summary table.

    `row.path` is the only untrusted field, so it alone goes through
    `md_escape_cell`; `outcome_label` and `format_seconds` already produce
    Markdown-safe text, and the remaining fields are plain integers.

    Args:
        row: The file's summary facts. Not mutated.

    Returns:
        One `|`-delimited table row, newline-terminated.
    """
    return (
        "| "
        + md_escape_cell(row.path)
        + " | "
        + outcome_label(row.outcome_code)
        + " | "
        + format_seconds(row.duration_seconds)
        + " | "
        + String(row.passed)
        + " | "
        + String(row.failed)
        + " | "
        + String(row.skipped)
        + " | "
        + String(row.attempts)
        + " |\n"
    )


def _reproduce_target(node: String) -> String:
    """The shell-quoted target for a reproduce/debug line.

    Scalarizes `node` first so an embedded control or newline cannot break
    the line, then shell-quotes the result — `shell_quote` leaves a plain
    path or node id unquoted (`/ . : _ -` are in its safe set) and
    single-quotes anything else, matching every other reproduce line this
    runner renders.
    """
    return shell_quote(escape_scalar(node))


def _reproduce_lines(node: String) -> String:
    """The `reproduce:`/`debug:` line pair for one target, or `""`.

    Args:
        node: The path or node id to reproduce; `""` renders neither line.

    Returns:
        Two newline-terminated lines, or `""` when `node` is empty.
    """
    if node.byte_length() == 0:
        return String("")
    var target = _reproduce_target(node)
    var out = "reproduce: " + md_code_span("mtest " + target) + "\n"
    out += "debug: " + md_code_span("mtest debug " + target) + "\n"
    return out^


def md_file_section(section: ReportSectionInput, root_note: Bool) -> String:
    """One file's full-detail section: per-test failures, streams, repro.

    `section.path` is already root-relative, the convention every `NodeId`
    in this runner follows; a compiler-baked `At <path>` line inside a
    failure's raw detail is not, and `normalize_detail` rewrites it against
    `section.root`, exactly as the console does, so the two renderings do
    not drift apart. `root_note` controls whether a short note says the
    report's paths are root-relative, so the caller can show it once per
    document rather than on every section.

    Args:
        section: The file's per-test results, captured streams, and repro
            target. Not mutated.
        root_note: Whether to emit the root-relativity note.

    Returns:
        The section fragment, ending in a blank line.
    """
    var out = (
        "## "
        + md_code_span(escape_scalar(section.path))
        + " — "
        + outcome_label(section.outcome_code)
        + "\n\n"
    )
    if root_note:
        out += (
            "> File paths in this report, including a backtrace `At` line"
            " inside a failure detail, are shown relative to the run"
            " root.\n\n"
        )
    for ref t in section.tests:
        if t.outcome != Outcome.FAIL:
            continue
        out += (
            "### FAIL " + md_code_span(escape_scalar(t.node.render())) + "\n\n"
        )
        var detail = normalize_detail(t.detail, section.root)
        if detail.byte_length() > 0:
            out += md_code_fence(escape_multiline(detail))
    if section.stdout_text.byte_length() > 0:
        out += "**stdout**\n\n"
        out += md_code_fence(escape_multiline(section.stdout_text))
        if section.stdout_truncated:
            out += "*(stdout truncated)*\n"
        out += "\n"
    if section.stderr_text.byte_length() > 0:
        out += "**stderr**\n\n"
        out += md_code_fence(escape_multiline(section.stderr_text))
        if section.stderr_truncated:
            out += "*(stderr truncated)*\n"
        out += "\n"
    if len(section.attempts) > 0:
        out += "**attempts**\n\n"
        for ref a in section.attempts:
            out += "- " + md_escape_cell(a) + "\n"
        out += "\n"
    if section.build_line.byte_length() > 0:
        out += "build: " + md_code_span(escape_scalar(section.build_line))
        out += "\n\n"
    out += _reproduce_lines(section.reproduce_node)
    out += "\n"
    return out^


def md_not_run_line(record: NotRunRecord) -> String:
    """One selected file's not-run reason, as a bullet line.

    Args:
        record: The file and the classified reason it never ran. Not
            mutated.

    Returns:
        `"- <path>: <reason label>\\n"`, both fields cell-escaped.
    """
    return (
        "- "
        + md_escape_cell(record.path)
        + ": "
        + md_escape_cell(not_run_reason_label(record.reason))
        + "\n"
    )


def md_machine_index(rows: List[ReportRow], nodes: List[String]) -> String:
    """A flat, grep-friendly index of every row that needs a second look.

    `nodes` is parallel to `rows`: `nodes[i]` is the reproduce target for
    `rows[i]`, the file's path or a more specific node id, exactly as
    `ReportSectionInput.reproduce_node` carries for that same file. This is
    a caller contract the function still defends against: a `nodes` shorter
    than `rows` renders an empty target (`''`) for the rows past its end
    rather than indexing out of bounds, so a violated contract degrades a
    line's target instead of crashing the whole document.

    See `report_model.needs_action` for exactly which outcomes are
    included.

    Args:
        rows: The summary rows to filter, in their table order. Not
            mutated.
        nodes: The parallel reproduce targets. Not mutated.

    Returns:
        `""` when no row needs action; otherwise a heading followed by one
        bullet per included row, in `rows` order.
    """
    var body = String("")
    var i = 0
    for ref row in rows:
        if needs_action(row.outcome_code):
            var node = nodes[i] if i < len(nodes) else String("")
            body += (
                "- "
                + md_code_span(_reproduce_target(node))
                + " — "
                + outcome_label(row.outcome_code)
                + "\n"
            )
        i += 1
    if body.byte_length() == 0:
        return String("")
    return "## Machine index\n\n" + body
