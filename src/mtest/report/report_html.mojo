"""The pure, self-contained HTML fragment renderer for the run report.

The HTML sibling of `report_md.mojo`: the same model, the same fragment
boundaries, the same information, a different output syntax. Each function
here turns one `report_model` value into a self-contained HTML fragment; no
function reads another's output, and none does I/O — assembling fragments
into one streamed document is the report writer's job, not this module's.

Placement policy mirrors `report_md.mojo`'s, layered under the same
`html_escape_text` (and, for the one attribute position that carries
model-derived text, `html_escape_attribute`): an inline/one-line value (a
path, node id, version/platform label, build line, not-run reason, attempt
summary) passes through `console_text.escape_scalar` FIRST, so a raw ESC or
a bare CR renders as the visible `\x1B`/`\x0D` text the console and the
Markdown renderer already show there, rather than silently becoming a
browser line break or vanishing into HTML's own control-byte policy. A block
of legitimately multi-line untrusted text (a failure detail, a captured
stream) passes through `escape_multiline` instead, keeping LF and Tab
literal. Either pass runs before `html_escape_text`, which still applies on
top for the HTML-specific entities (`&`, `<`, `>`) and as a second line of
defense for any control byte the first pass did not already spell out. A
reproduce or debug target composes three passes in that order —
`escape_scalar`, then `shell_quote`, then `html_escape_text` — matching the
Markdown renderer's `shell_quote(escape_scalar(node))` with an HTML-escaping
pass on top, so a control byte cannot survive into the shell-quoting
decision and the quoted result is still HTML-safe.

The document is one continuous `<table>`: `html_document_open` opens it
(`<thead>` plus an unclosed `<tbody>`) and `html_document_close` is the only
function that closes it. Every other fragment — a summary row, a file
section, a not-run line, the machine index — renders as exactly one
self-contained `<tr>` (or nothing) that nests directly inside that same
`<tbody>`, a file section's or not-run line's row spanning every column via
`colspan="_SUMMARY_COLS"` so it can hold arbitrary block content (a
`<details>`, a `<pre>`, a list) without leaving the table's content model.
This is what lets every fragment stay self-contained with no cross-call
state: `html_document_close` always closes exactly `</tbody></table>` plus
the `<body>`/`<html>` shell, regardless of how many rows or sections came
between the two document bookends.

`html_document_open` emits exactly one `<style>` block, whose body is the
comptime constant `_REPORT_CSS`: inline CSS only, no `<script>` anywhere in
this module, and no external URL (no CDN, no font, no image host) inside the
stylesheet, so the document renders correctly with no network access and
executes nothing a hostile test name or captured stream could reach.

`html_header` and `html_summary_table_header` from the Markdown renderer have
no HTML counterpart as separate functions: the doctype/`<style>`/header/table
bundle has to be one document-opening call for HTML, where Markdown could
split "the banner" and "the table header" into two independent fragments
with nothing in between that needed a document shell.
"""
from mtest.config import shell_quote
from mtest.model import NotRunRecord, Outcome, not_run_reason_label
from mtest.report.console_text import escape_multiline, escape_scalar
from mtest.report.escape import html_escape_attribute, html_escape_text
from mtest.report.junit import format_seconds
from mtest.report.report_model import (
    ReportFinalizeContext,
    ReportHeaderFacts,
    ReportRow,
    ReportSectionInput,
    needs_action,
    outcome_label,
)
from mtest.report.report_text import normalize_detail

comptime _SUMMARY_COLS = 7
"""The summary table's column count: Path, Outcome, Duration, Passed, Failed,
Skipped, Attempts. Also the `colspan` every wide row (a file section, a
not-run line, the machine index) carries, so it spans the full table width
while staying a single `<tr>` inside the same `<tbody>` `html_document_open`
left open."""

comptime _REPORT_CSS: StaticString = (
    ":root { color-scheme: light dark; }\n"
    "body {"
    ' font-family: system-ui, -apple-system, "Segoe UI", sans-serif;'
    " margin: 2rem; line-height: 1.5;"
    " }\n"
    "h1, h2 { border-bottom: 1px solid #8888; padding-bottom: 0.25rem; }\n"
    "ul.facts { list-style: none; padding: 0; margin: 0 0 1.5rem 0; }\n"
    "ul.facts li { margin: 0.15rem 0; }\n"
    "table.report { border-collapse: collapse; width: 100%; }\n"
    "table.report th, table.report td {"
    " border: 1px solid #8888; padding: 0.35rem 0.6rem;"
    " text-align: left; vertical-align: top;"
    " }\n"
    "table.report thead { background: #8882; }\n"
    "tr.file-section td, tr.not-run td, tr.machine-index td {"
    " border: none; padding: 0.35rem 0;"
    " }\n"
    "details.file {"
    " margin: 0.5rem 0; border: 1px solid #8886; border-radius: 4px;"
    " padding: 0.5rem 0.75rem;"
    " }\n"
    "details.file > summary { cursor: pointer; font-weight: 600; }\n"
    "pre {"
    " background: #8881; padding: 0.5rem; overflow-x: auto;"
    " white-space: pre-wrap; word-break: break-word;"
    " }\n"
    "code { font-family: ui-monospace, Menlo, Consolas, monospace; }\n"
    ".outcome-PASS { color: #1a7f37; }\n"
    ".outcome-FAIL, .outcome-CRASH, .outcome-TIMEOUT,"
    " .outcome-COMPILE_ERROR, .outcome-COMPILE_TIMEOUT,"
    " .outcome-MALFORMED_SUITE, .outcome-PRECOMPILE_ERROR"
    " { color: #cf222e; }\n"
    ".outcome-SKIP, .outcome-DESELECTED, .outcome-EXCLUDED"
    " { color: #6e7781; }\n"
    ".outcome-FLAKY, .outcome-NOT_RUN { color: #9a6700; }\n"
)
"""The whole document's stylesheet, inlined into the single `<style>` block
`html_document_open` emits. Pure CSS: no `url(...)`, no `@import`, no
`@font-face`, and no `expression()` — the document stays self-contained and
renders identically with no network access."""


def _escape_inline(text: String) -> String:
    """HTML-safe rendering of a value that must stay on one line.

    Runs `console_text.escape_scalar` first, so a raw control byte or an ESC
    sequence renders as the same visible escape text (`\\x1B`, `\\x0D`, ...)
    the console and the Markdown renderer already show there, rather than a
    bare CR becoming a browser line break or a C0 byte silently turning into
    HTML's own `html_escape_text` replacement character. `html_escape_text`
    still runs on top for `&`/`<`/`>` and as a second line of defense.

    Args:
        text: The untrusted, single-line value to render.

    Returns:
        `text`, control-escaped then HTML-escaped.
    """
    return html_escape_text(escape_scalar(text))


def _escape_block(text: String) -> String:
    """HTML-safe rendering of a block that legitimately spans lines.

    Runs `console_text.escape_multiline` first, keeping LF and Tab literal —
    a captured stream or a failure detail is shaped by them — and escaping
    every other control byte, then `html_escape_text` on top for `&`/`<`/`>`
    and as a second line of defense.

    Args:
        text: The untrusted, multi-line block to render.

    Returns:
        `text`, control-escaped then HTML-escaped.
    """
    return html_escape_text(escape_multiline(text))


def html_document_open(
    facts: ReportHeaderFacts, ctx: ReportFinalizeContext
) -> String:
    """The document-opening shell: doctype, style, header facts, table open.

    Mirrors `md_header`'s conditional-fact policy exactly: every count below
    the title is conditional except the tests and wall-time lines, so a
    plain run's header stays short. Ends by opening the summary table
    (`<thead>` with the column labels, then an unclosed `<tbody>`) for
    `html_summary_row` to append into; `html_document_close` is the only
    function that closes it.

    Args:
        facts: The build-time version and platform labels. Not mutated.
        ctx: The run-wide facts gathered at finalize. Not mutated.

    Returns:
        The opening shell fragment, ending with `<tbody>` left open.
    """
    var out = String('<!doctype html>\n<html lang="en">\n<head>\n')
    out += '<meta charset="utf-8">\n'
    out += "<title>mtest report</title>\n"
    out += "<style>\n" + _REPORT_CSS + "</style>\n"
    out += "</head>\n<body>\n"
    out += "<h1>mtest report</h1>\n"
    out += (
        "<p>mtest "
        + _escape_inline(facts.version)
        + " ("
        + _escape_inline(facts.platform)
        + ")</p>\n"
    )
    out += '<ul class="facts">\n'
    out += "<li>wall time: " + format_seconds(ctx.wall_seconds) + "s</li>\n"
    out += (
        "<li>tests: "
        + String(ctx.tests_passed)
        + " passed, "
        + String(ctx.tests_failed)
        + " failed, "
        + String(ctx.tests_skipped)
        + " skipped</li>\n"
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
        out += "<li>files: " + files + "</li>\n"
    if ctx.built_files + ctx.cached_files > 0:
        out += (
            "<li>builds: "
            + String(ctx.built_files)
            + " built, "
            + String(ctx.cached_files)
            + " cached</li>\n"
        )
    if ctx.flaky_files > 0:
        out += "<li>flaky: " + String(ctx.flaky_files) + "</li>\n"
    if ctx.workers > 1:
        out += "<li>workers: " + String(ctx.workers) + "</li>\n"
    if ctx.shuffle:
        out += "<li>shuffle seed: " + String(ctx.shuffle_seed) + "</li>\n"
    if ctx.shard_label.byte_length() > 0:
        out += "<li>shard: " + _escape_inline(ctx.shard_label) + "</li>\n"
    if ctx.interrupted:
        out += "<li>interrupted: yes</li>\n"
    if ctx.drift:
        out += "<li>drift: yes</li>\n"
    out += "</ul>\n"
    out += "<h2>Summary</h2>\n"
    out += '<table class="report">\n<thead>\n<tr>'
    out += (
        "<th>Path</th><th>Outcome</th><th>Duration (s)</th>"
        "<th>Passed</th><th>Failed</th><th>Skipped</th><th>Attempts</th>"
    )
    out += "</tr>\n</thead>\n<tbody>\n"
    return out^


def html_summary_row(row: ReportRow) -> String:
    """One file's row in the summary table.

    `row.path` is the only untrusted field, so it alone goes through
    `_escape_inline`; the outcome label is our own closed vocabulary, still
    routed through `html_escape_attribute` where it lands in the `class`
    attribute so that safety is structural rather than "provably safe
    today". `format_seconds` already produces HTML-safe text, and the
    remaining fields are plain integers.

    Args:
        row: The file's summary facts. Not mutated.

    Returns:
        One complete `<tr>`, newline-terminated, nesting directly inside the
        `<tbody>` `html_document_open` left open.
    """
    var label = outcome_label(row.outcome_code)
    return (
        '<tr class="'
        + html_escape_attribute("outcome-" + label)
        + '"><td><code>'
        + _escape_inline(row.path)
        + "</code></td><td>"
        + label
        + "</td><td>"
        + format_seconds(row.duration_seconds)
        + "</td><td>"
        + String(row.passed)
        + "</td><td>"
        + String(row.failed)
        + "</td><td>"
        + String(row.skipped)
        + "</td><td>"
        + String(row.attempts)
        + "</td></tr>\n"
    )


def _reproduce_target(node: String) -> String:
    """The scalar-safe, shell-quoted, HTML-escaped reproduce/debug target.

    Three passes, in order, matching the Markdown renderer's
    `shell_quote(escape_scalar(node))` with an HTML-escaping pass on top:
    `escape_scalar` first, so a control byte or ESC sequence cannot survive
    into the shell-quoting decision; then `shell_quote`, which leaves a
    plain path or node id unquoted (`/ . : _ -` are in its safe set) and
    single-quotes anything else; then `html_escape_text`, so a hostile node
    id can neither break the emitted shell command nor the surrounding
    `<code>` text.
    """
    return html_escape_text(shell_quote(escape_scalar(node)))


def _reproduce_lines(node: String) -> String:
    """The `reproduce:`/`debug:` line pair for one target, or `""`.

    Args:
        node: The path or node id to reproduce; `""` renders neither line.

    Returns:
        Two newline-terminated `<p>` lines, or `""` when `node` is empty.
    """
    if node.byte_length() == 0:
        return String("")
    var target = _reproduce_target(node)
    var out = "<p>reproduce: <code>mtest " + target + "</code></p>\n"
    out += "<p>debug: <code>mtest debug " + target + "</code></p>\n"
    return out^


def _is_green(outcome_code: Int) -> Bool:
    """Whether a file section is collapsed (`<details>` closed) by default.

    Only `PASS` is green: every other outcome, `FLAKY` included, opens the
    section by default so a reader sees why it is here without clicking.
    """
    return outcome_code == Outcome.PASS.code


def html_file_section(section: ReportSectionInput, root_note: Bool) -> String:
    """One file's full-detail section: per-test failures, streams, repro.

    `section.path` is already root-relative, the convention every `NodeId`
    in this runner follows; a compiler-baked `At <path>` line inside a
    failure's raw detail is not, and `normalize_detail` rewrites it against
    `section.root`, exactly as the console and the Markdown renderer do, so
    every rendering of a failure's detail reads identically. `root_note`
    controls whether a short note says the report's paths are root-relative,
    so the caller can show it once per document rather than on every
    section. The whole section renders as one `<tr>` whose single `<td>`
    spans every summary column (`colspan="_SUMMARY_COLS"`) and holds a
    `<details>`, open by default for any outcome other than `PASS`
    (`_is_green`).

    Args:
        section: The file's per-test results, captured streams, and repro
            target. Not mutated.
        root_note: Whether to emit the root-relativity note.

    Returns:
        One complete `<tr>`, newline-terminated.
    """
    var out = (
        '<tr class="file-section"><td colspan="'
        + String(_SUMMARY_COLS)
        + '">\n'
    )
    var open_attr = String("")
    if not _is_green(section.outcome_code):
        open_attr = " open"
    out += '<details class="file"' + open_attr + ">\n"
    out += (
        "<summary><code>"
        + _escape_inline(section.path)
        + "</code> — "
        + outcome_label(section.outcome_code)
        + "</summary>\n"
    )
    if root_note:
        out += (
            '<p class="note">File paths in this report, including a'
            " backtrace <code>At</code> line inside a failure detail, are"
            " shown relative to the run root.</p>\n"
        )
    for ref t in section.tests:
        if t.outcome != Outcome.FAIL:
            continue
        out += (
            "<h4>FAIL <code>"
            + _escape_inline(t.node.render())
            + "</code></h4>\n"
        )
        var detail = normalize_detail(t.detail, section.root)
        if detail.byte_length() > 0:
            out += "<pre>\n" + _escape_block(detail) + "</pre>\n"
    if section.stdout_text.byte_length() > 0:
        out += "<p><strong>stdout</strong></p>\n"
        out += "<pre>\n" + _escape_block(section.stdout_text) + "</pre>\n"
        if section.stdout_truncated:
            out += "<p><em>(stdout truncated)</em></p>\n"
    if section.stderr_text.byte_length() > 0:
        out += "<p><strong>stderr</strong></p>\n"
        out += "<pre>\n" + _escape_block(section.stderr_text) + "</pre>\n"
        if section.stderr_truncated:
            out += "<p><em>(stderr truncated)</em></p>\n"
    if len(section.attempts) > 0:
        out += "<p><strong>attempts</strong></p>\n<ul>\n"
        for ref a in section.attempts:
            out += "<li>" + _escape_inline(a) + "</li>\n"
        out += "</ul>\n"
    if section.build_line.byte_length() > 0:
        out += (
            "<p>build: <code>"
            + _escape_inline(section.build_line)
            + "</code></p>\n"
        )
    out += _reproduce_lines(section.reproduce_node)
    out += "</details>\n</td></tr>\n"
    return out^


def html_not_run_line(record: NotRunRecord) -> String:
    """One selected file's not-run reason, as a wide table row.

    Args:
        record: The file and the classified reason it never ran. Not
            mutated.

    Returns:
        One complete `<tr>`, both fields HTML-escaped, newline-terminated.
    """
    return (
        '<tr class="not-run"><td colspan="'
        + String(_SUMMARY_COLS)
        + '"><code>'
        + _escape_inline(record.path)
        + "</code>: "
        + _escape_inline(not_run_reason_label(record.reason))
        + "</td></tr>\n"
    )


def html_machine_index(rows: List[ReportRow], nodes: List[String]) -> String:
    """A flat list of every row that needs a second look, as a wide row.

    `nodes` is parallel to `rows`: `nodes[i]` is the reproduce target for
    `rows[i]`, exactly as `md_machine_index` reads it, including its guard
    against a `nodes` shorter than `rows` — a violated caller contract
    degrades a line's target to `''` rather than indexing out of bounds. See
    `report_model.needs_action` for exactly which outcomes are included.

    Args:
        rows: The summary rows to filter, in their table order. Not
            mutated.
        nodes: The parallel reproduce targets. Not mutated.

    Returns:
        `""` when no row needs action; otherwise one complete `<tr>`
        carrying a heading and one list item per included row, in `rows`
        order.
    """
    var body = String("")
    var i = 0
    for ref row in rows:
        if needs_action(row.outcome_code):
            var node = nodes[i] if i < len(nodes) else String("")
            body += (
                "<li><code>"
                + _reproduce_target(node)
                + "</code> — "
                + outcome_label(row.outcome_code)
                + "</li>\n"
            )
        i += 1
    if body.byte_length() == 0:
        return String("")
    return (
        '<tr class="machine-index"><td colspan="'
        + String(_SUMMARY_COLS)
        + '">\n<h2>Machine index</h2>\n<ul>\n'
        + body
        + "</ul>\n</td></tr>\n"
    )


def html_document_close() -> String:
    """Close the summary table and the document shell.

    Always closes exactly what `html_document_open` left open — the summary
    table's `<tbody>`/`<table>`, then the `<body>`/`<html>` shell —
    regardless of how many summary rows, file sections, not-run lines, or a
    machine index were emitted in between: every one of those renders as a
    complete `<tr>` (or nothing) nested directly inside that same `<tbody>`,
    so nothing is ever left open for this function to guess about.

    Returns:
        The closing fragment.
    """
    return "</tbody>\n</table>\n</body>\n</html>\n"
