"""Shared pure-text primitives for run-report rendering.

Pure functions only, no I/O, no state, no environment access — the narrow seam
that keeps two independent renderings of the same event stream from drifting
apart. Two unrelated concerns share this module because both concerns are
about not duplicating a policy that already lives elsewhere:

- `normalize_detail` is the console's own FAIL-detail transform — a uniform
  dedent, then a root-relative rewrite of the compiler-baked `At <path>` line
  — moved here byte-identically so a run report shows a failure's detail
  exactly as the console does.
- `md_escape_cell`, `md_code_span`, and `md_code_fence` are Markdown's own
  structural escaping and code-span/fence sizing, layered on top of
  `console_text.escape_scalar` rather than reimplementing its scalar-control
  policy: a value only ever needs one decision about which code points a
  terminal would interpret, and that decision was already made once.

Placement policy for a renderer built on this module: a table cell or other
inline value goes through `escape_scalar` (via `md_escape_cell` /
`md_code_span`); a fenced block of untrusted multi-line text (a failure
detail, a captured stream) goes through `console_text.escape_multiline`
instead, so LF and Tab ride through literally there. This module provides the
pieces; a renderer built on top of it is the consumer.
"""
from mtest.report.console_text import escape_scalar


def _common_indent(lines: List[String]) -> Int:
    """The count of leading spaces shared by every non-empty line, or 0.

    Empty lines are ignored; a non-empty line with no leading space forces 0.
    """
    var m = -1
    for ref ln in lines:
        if ln.byte_length() == 0:
            continue
        var c = 0
        for cp in ln.codepoint_slices():
            if String(cp) == " ":
                c += 1
            else:
                break
        if c == 0:
            return 0
        if m < 0 or c < m:
            m = c
    if m < 0:
        return 0
    return m


def _strip_at_root_prefix(ln: String, root: String) -> String:
    """Strip the run-root prefix from a line that is a backtrace pointer.

    The anchored form of `normalize_detail`'s second transformation. If `ln`,
    after any leading spaces, starts with `At <root>/`, that single occurrence
    of `root + "/"` immediately after `At ` is removed. Every other byte on the
    line rides through untouched, including any later occurrence of the root
    path, such as one inside an assertion message. A line that merely contains
    `"At "` somewhere without being anchored there is left alone.
    """
    if root.byte_length() == 0:
        return ln
    var lead = String("")
    for cp in ln.codepoint_slices():
        if String(cp) == " ":
            lead += " "
        else:
            break
    var marker = lead + "At " + root + "/"
    if not ln.startswith(marker):
        return ln
    return lead + "At " + String(ln.removeprefix(marker))


def normalize_detail(detail: String, root: String) -> String:
    """A FAIL's verbatim detail with the two permitted transformations applied.

    First, strip the common leading-whitespace prefix TestSuite bakes into the
    detail block: a uniform dedent that preserves the relative shape. Second, on
    a line that is a backtrace pointer (`At <path>:<line>:<col>: ...`,
    optionally indented), render the compiler-baked absolute path root-relative
    by stripping the single run-root prefix (`root + "/"`) that immediately
    follows `At `.

    Nothing else is rewritten. A later occurrence of the run root elsewhere on
    the same line, such as inside the assertion message, is untouched, and every
    other byte rides through verbatim. Shared by the console and every run
    report so a failure's detail reads identically wherever it is shown.

    Args:
        detail: The raw, verbatim FAIL detail as TestSuite emitted it.
        root: The run root to relativize a backtrace pointer against.

    Returns:
        The dedented, root-relativized detail; `""` when `detail` is empty.
    """
    if detail.byte_length() == 0:
        return String("")
    var lines = List[String]()
    for ln in detail.split("\n"):
        lines.append(String(ln))
    var indent = _common_indent(lines)
    var prefix = String("")
    for _ in range(indent):
        prefix += " "
    var out = String("")
    for i in range(len(lines)):
        var ln = lines[i].copy()
        if indent > 0 and ln.byte_length() >= indent:
            ln = String(ln.removeprefix(prefix))
        ln = _strip_at_root_prefix(ln, root)
        if i > 0:
            out += "\n"
        out += ln
    return out^


def md_escape_cell(text: String) -> String:
    """Neutralize `text` for a Markdown table cell or other inline position.

    `text` first passes through `console_text.escape_scalar`, so it is
    flattened to one line and every interpreted terminal control, LF and Tab
    included, is already rendered as visible escape text — the scalar-control
    policy is reused, never reimplemented. A structural Markdown pass then runs
    on that result, in an order that is load-bearing: `\\` is doubled FIRST,
    before any later rule can introduce a fresh backslash of its own, so
    `escape_scalar`'s own `\\x0A`/`\\x09` escapes, and the `\\|` this pass adds,
    are never re-escaped. After the backslash pass, in order: `|` becomes
    `\\|`, `&` becomes `&amp;`, `<` becomes `&lt;` (a bare `>` is inert on its
    own — it opens no Markdown structure by itself). Finally, if the assembled
    cell now starts with `-`, `+`, `#`, or `>`, one backslash is prepended so
    the cell cannot be misread as a list marker, a heading, or a blockquote.

    Args:
        text: The untrusted value, already valid UTF-8.

    Returns:
        `text` rendered safe for a Markdown table cell or inline position.
    """
    var scalarized = escape_scalar(text)
    var out = String("")
    for cp in scalarized.codepoint_slices():
        var c = String(cp)
        if c == "\\":
            out += "\\\\"
        elif c == "|":
            out += "\\|"
        elif c == "&":
            out += "&amp;"
        elif c == "<":
            out += "&lt;"
        else:
            out += c
    var lead = String("")
    for cp in out.codepoint_slices():
        lead = String(cp)
        break
    if lead == "-" or lead == "+" or lead == "#" or lead == ">":
        out = "\\" + out
    return out^


def md_code_span(text: String) -> String:
    """Wrap `text` in an inline Markdown code span sized to its own content.

    The opening and closing backtick run is one longer than the longest run of
    consecutive backticks inside `text`, the CommonMark rule that keeps an
    interior backtick run from prematurely closing the span. When `text`
    starts or ends with a backtick, a single space is added on both sides so
    the fence and the content stay visually distinct.

    Args:
        text: The untrusted value to wrap; not otherwise escaped, since a code
            span's content is verbatim by Markdown's own rule.

    Returns:
        `text` wrapped in a backtick fence sized to its own content.
    """
    var max_run = 0
    var cur = 0
    for cp in text.codepoint_slices():
        if String(cp) == "`":
            cur += 1
            if cur > max_run:
                max_run = cur
        else:
            cur = 0
    var fence_len = max_run + 1
    var fence = String("")
    for _ in range(fence_len):
        fence += "`"
    var body = text.copy()
    if text.byte_length() > 0 and (text.startswith("`") or text.endswith("`")):
        body = " " + body + " "
    return fence + body + fence


def md_code_fence(text: String) -> String:
    """Wrap `text` in a Markdown fenced code block sized to its own content.

    The fence length is the longest run of consecutive backticks inside `text`
    plus one, floored at 3, the minimum CommonMark fence width. `text` is
    guaranteed a trailing newline before the closing fence, so a block whose
    last line was unterminated does not run into the fence on the same line.

    Args:
        text: The untrusted block to fence; not otherwise escaped, since a
            fenced block's content is verbatim by Markdown's own rule.

    Returns:
        The fenced block: the opening fence, `text` (newline-terminated), and
        the closing fence, each on its own line.
    """
    var max_run = 0
    var cur = 0
    for cp in text.codepoint_slices():
        if String(cp) == "`":
            cur += 1
            if cur > max_run:
                max_run = cur
        else:
            cur = 0
    var fence_len = max_run + 1
    if fence_len < 3:
        fence_len = 3
    var fence = String("")
    for _ in range(fence_len):
        fence += "`"
    var body = text.copy()
    if body.byte_length() == 0 or not (
        body[byte=body.byte_length() - 1] == "\n"
    ):
        body += "\n"
    return fence + "\n" + body + fence + "\n"
