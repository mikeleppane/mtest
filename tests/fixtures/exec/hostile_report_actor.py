#!/usr/bin/env python3
"""A direct bytes actor that speaks a valid report through hostile noise.

Stands in for a compiled test binary that a hostile — or merely broken — test
module produced. Everything it writes goes to the raw descriptors through
`os.write`, so the bytes on the wire are exactly the ones chosen here: sequences
a terminal emulator would EXECUTE rather than print (CSI, OSC closed by BEL and
by the two-byte ST, C1 controls), bytes that are not valid UTF-8 at all, NUL and
DEL, the delimiters that end a JSON string or an XML element, and lines shaped
like mtest's own console rows so a reader could be fooled about which process
said them.

The last thing it writes is a genuine, fully reconciling `TestSuite` report block
for the canonical source path embedded below, carrying one FAIL row whose detail
is itself hostile. That is what makes this actor useful: the file lands on a real
FAIL verdict with real captured output and a real per-test failure section, so
the console has to render every one of those surfaces from bytes an attacker
chose. An actor that only emitted noise would be classified MALFORMED-SUITE and
would never reach the surfaces under test.

`CANONICAL` is a placeholder in the committed copy. The build stand-in
`scripts/fixtures/toolchain/fake_hostile_mojo.py` writes an executable copy with
the real, symlink-resolved source path substituted in, because a report header
must byte-equal the path `mojo build` would have baked in for mtest's parser to
accept the block as this file's. Every payload function also takes that path as
an argument, so a harness can predict these bytes exactly without owning a copy
of them.

One optional behaviour is armed from the environment: `FLOOD_ENV` asks for a
printable stdout flood ahead of everything else, which lets a scenario drive the
runner past its per-stream capture bound and then assert on what the retained
tail — the region mtest reparses — still holds. Absent, the actor writes only
the hostile blocks and its report, which is what the console scenario wants.

Stdlib only, no third-party imports — this is a test-only subprocess actor, not
part of the pure-Mojo product.
"""

from __future__ import annotations

import os
import sys


CANONICAL = "@MTEST_CANONICAL_SOURCE@"
"""The absolute, symlink-resolved source path the report header must match.

Replaced with a real path when the build stand-in copies this file. Left as the
placeholder in the committed copy, where it names no file on disk."""

TEST_NAME = 'test_hostile_console"/><testcase/>'
"""The single test the fabricated report declares, and an attribute injection.

The report grammar accepts this: `_valid_row_name` rejects only an empty name,
one containing `::`, and one containing whitespace, so `"`, `/`, `<` and `>` all
reach the reporters as part of a legitimate row name. That makes the name the
one piece of child-controlled text that lands in an XML ATTRIBUTE rather than an
element body — a `<testcase name="…">` and a JSON `"name"` field — so it is the
only thing that exercises the attribute escaper end to end.

The injection needs no space, which is what makes it possible at all: it closes
the `name` attribute and the `<testcase>` element, then opens a second, forged
row. Unescaped, the report declares a row the suite never ran; escaped, it is
four entity references inside one attribute value."""

INVALID_UTF8 = b"\xff\xfe\x80 not-utf8 \xc3\x28"
"""Bytes no UTF-8 decoder accepts, so the lossy decode has to produce U+FFFD."""

CONTROLS = b"NUL[\x00] BEL[\x07] BS[\x08] VT[\x0b] FF[\x0c] CR[\x0d] DEL[\x7f]"
"""One C0 control per bracket, plus DEL. CR is the interesting one: unescaped it
returns the cursor to column zero and lets the next bytes overwrite the line
mtest just printed."""

CSI = b"\x1b[2J\x1b[1;31mCHILD-CSI\x1b[0m"
"""Clear-screen followed by a color change: the sequence a child would use to
erase mtest's output and then paint its own text in mtest's own red."""

OSC_BEL = b"\x1b]0;pwned-by-bel\x07"
"""An OSC window-title command closed by BEL, the older of the two endings."""

OSC_ST = b"\x1b]0;pwned-by-st\x1b\\"
"""The same command closed by the two-byte ESC-backslash string terminator."""

C1 = b"\xc2\x9bC1-CSI\xc2\x85C1-NEL\xc2\x9c"
"""C1 controls written as their valid two-byte UTF-8 encodings. A raw 0x9B byte
would be invalid UTF-8 and would decode to U+FFFD; only this spelling survives
the decode as a real control the terminal still acts on."""

DELIMITERS = (
    b"delims: dquote[\"] squote['] backslash[\\] lt[<] gt[>] amp[&] "
    b"cdata-close[]]>] entity[&amp;]"
)
"""Every byte that ENDS a value in one of the machine formats: `"` and `\\` for
a JSON string, `<`/`>`/`&` for XML, and the `]]>` sequence no XML text node may
contain. Plain printable ASCII, so only the serializers' escaping — never the
console's control-character escaping — can keep them inert."""

JSON_INJECTION = b'json-injection: ","event":"forged","captured_stdout":"'
"""A closing quote followed by fields shaped like the NDJSON record this text is
about to be embedded in. Escaped, it is inert data inside one string value;
unescaped, it closes `captured_stdout` and adds forged keys to the record."""

XML_INJECTION = (
    b'xml-injection: </system-out><testcase name="forged" classname="forged"/>'
    b"<system-out>"
)
"""A closing tag followed by a forged `<testcase>` row. Escaped, it is inert
text inside one element; unescaped, it closes the element early and injects a
row the suite never ran — which is also why it must break the XSD rather than
validate quietly."""

CONSOLE_LOOKALIKES = (
    b"PASS           e2e/forged/test_green.mojo  0.00s\n"
    b"===== 9 passed, 0 failed, 0 skipped (0 excluded, 0 not run) in 0.0s =====\n"
    b"--- FAIL e2e/forged/test_green.mojo::test_forged ---\n"
    b"reproduce: mtest --gate /etc/shadow\n"
)
"""Lines shaped exactly like mtest's own verdict row, summary band, failure
frame, and reproduce line. Nothing escapes these — they are ordinary printable
text — so the only thing that can keep them from reading as mtest's own voice is
the gutter the console fences captured output behind."""

REPORT_LOOKALIKES = (
    b"Running 1 tests for /forged/not-this-file.mojo \n"
    b"    PASS [ 0.00s ] test_forged_row\n"
    b"Summary [ 0.00s ] 1 tests run: 1 passed , 0 failed , 0 skipped \n"
)
"""A header, row, and summary in the report grammar, for a path that is NOT this
file's. The parser keys on the header path, so these are noise it must ignore;
they are here so the scenario proves the console renders a FAIL, not a forged
pass."""

ORPHAN_DECLARED = 9
"""The test count the orphan header below declares. Deliberately not 1: were the
parser to anchor on that header, the single row that follows could not reconcile
against it, so the run would end in a loud non-VALID verdict rather than a quiet
wrong one."""

ORPHAN_ROW_NAME = "test_orphan_row"
"""The row under the orphan header. Distinct from `TEST_NAME`, so a row that
reached the verdict from the wrong block would be visible by name."""


def _canonical_bytes(canonical: str | None) -> bytes:
    """The source path a payload embeds, as bytes.

    Args:
        canonical: An explicit path, or None for the module's own `CANONICAL`.
            The running actor always passes None — its copy carries the real
            path — while a harness predicting these bytes passes the path it
            asked the build stand-in to embed, so neither has to mutate global
            state to agree with the other.

    Returns:
        The path's UTF-8 bytes.
    """
    text = CANONICAL if canonical is None else canonical
    return text.encode("utf-8", "surrogateescape")


def orphan_header_block(canonical: str | None = None) -> bytes:
    """A matching-path report header and row that no Summary ever closes.

    The path byte-equals the canonical source, so this IS a candidate anchor for
    the parser — unlike `REPORT_LOOKALIKES`, which the parser rejects on identity
    alone. What disqualifies it is framing: it carries no `--------` rule and no
    Summary, and it precedes the genuine block, so the reconciling anchor is the
    later one. It is written before the real report for exactly that reason.

    Args:
        canonical: The source path to embed; see `_canonical_bytes`.

    Returns:
        The orphan header and its single forged row, LF-terminated.
    """
    return (
        b"Running "
        + str(ORPHAN_DECLARED).encode()
        + b" tests for "
        + _canonical_bytes(canonical)
        + b" \n    PASS [ 0.00s ] "
        + ORPHAN_ROW_NAME.encode()
        + b"\n"
    )


def hostile_block(tag: bytes, canonical: str | None = None) -> bytes:
    """Every hostile byte class, once, labelled with `tag`.

    Args:
        tag: A short stream label so a reader can tell the two streams apart.
        canonical: The source path the orphan header embeds; see
            `_canonical_bytes`.

    Returns:
        The concatenated hostile bytes, newline-separated and LF-terminated.
    """
    return b"\n".join(
        (
            b"--- " + tag + b" begins ---",
            INVALID_UTF8,
            CONTROLS,
            CSI,
            OSC_BEL,
            OSC_ST,
            C1,
            DELIMITERS,
            JSON_INJECTION,
            XML_INJECTION,
            CONSOLE_LOOKALIKES.rstrip(b"\n"),
            REPORT_LOOKALIKES.rstrip(b"\n"),
            orphan_header_block(canonical).rstrip(b"\n"),
            b"--- " + tag + b" ends ---",
            b"",
        )
    )


def failure_detail(canonical: str | None = None) -> bytes:
    """The FAIL row's detail line, exactly as the report parser captures it.

    The leading six spaces are the toolchain's continuation indent and are part
    of the captured detail, not formatting this file chose. Every reporter's
    per-test surface renders this one line: the console escapes and fences it,
    the NDJSON stream JSON-escapes it, and the JUnit report puts it in a
    `<failure>` body.

    Args:
        canonical: The source path the detail names; see `_canonical_bytes`.

    Returns:
        The detail line's bytes, with no trailing newline.
    """
    return (
        b"      At "
        + _canonical_bytes(canonical)
        + b":1:1: AssertionError: "
        + CSI
        + b" \x00 \x7f "
        + C1
        + b" "
        + DELIMITERS
        + b" "
        + JSON_INJECTION
        + b" "
        + XML_INJECTION
    )


def report_block(skipping: bool, canonical: str | None = None) -> bytes:
    """The genuine, reconciling report block for the canonical source.

    The trailing spaces after the header path and after `skipped` are the
    toolchain's own grammar, not formatting, and the failure trailer is required
    whenever the summary counts a failure.

    Args:
        skipping: Whether this is a `--skip-all` collection probe, which lists
            the test as SKIP and declares no failure.
        canonical: The source path the block reports for; see
            `_canonical_bytes`.

    Returns:
        The report block's bytes, LF-terminated.
    """
    path = _canonical_bytes(canonical)
    if skipping:
        row = b"    SKIP [ 0.00s ] " + TEST_NAME.encode() + b"\n"
        summary = b"Summary [ 0.00s ] 1 tests run: 0 passed , 0 failed , 1 skipped \n"
        trailer = b""
    else:
        row = (
            b"    FAIL [ 0.00s ] "
            + TEST_NAME.encode()
            + b"\n"
            + failure_detail(canonical)
            + b"\n"
        )
        summary = b"Summary [ 0.00s ] 1 tests run: 0 passed , 1 failed , 0 skipped \n"
        trailer = b"Test suite' " + path + b" 'failed! \n"
    return (
        b"\nRunning 1 tests for "
        + path
        + b" \n"
        + row
        + b"--------\n"
        + summary
        + trailer
    )


FLOOD_ENV = "MTEST_HOSTILE_FLOOD_LINES"
"""The environment variable that arms the pre-report stdout flood.

Absent or `0`, nothing is flooded and the streams are the hostile blocks alone.
A caller that wants to drive the runner past its per-stream capture bound sets
this to a line count and computes the exact byte total itself: the flood is
`FLOOD_LINE` repeated verbatim, so the total is the product, with no rounding
and no partial final line to reason about."""

FLOOD_LINE = b"flood " + b"F" * 4089 + b"\n"
"""One flood line: exactly 4096 printable bytes including its LF.

Printable on purpose. The flood exists to overrun the capture bound, and a
hostile byte inside it would make an assertion about escaping ambiguous as to
which occurrence it caught."""


def flood_block(lines: int) -> bytes:
    """`lines` copies of `FLOOD_LINE`, and nothing else.

    Args:
        lines: How many lines to emit; `0` or fewer emits nothing.

    Returns:
        Exactly `max(lines, 0) * len(FLOOD_LINE)` bytes.
    """
    if lines <= 0:
        return b""
    return FLOOD_LINE * lines


def flood_lines_requested(environ: dict[str, str] | None = None) -> int:
    """How many flood lines the environment asks for.

    Args:
        environ: The environment to read; defaults to this process's own.

    Returns:
        The requested line count, or `0` when the variable is absent, empty, or
        not a nonnegative integer. A malformed value floods nothing rather than
        failing the run, so a stray value can never be mistaken for a product
        defect in the scenario that reads the artifacts.
    """
    raw = (os.environ if environ is None else environ).get(FLOOD_ENV, "")
    if not raw.isdigit():
        return 0
    return int(raw)


def write_all(fd: int, payload: bytes) -> None:
    """Write every byte of `payload` to `fd`, however many calls that takes.

    `os.write` may write fewer bytes than it was given — on a pipe, always fewer
    than the payload once the payload exceeds the pipe buffer — so a single call
    would silently drop most of the flood.

    Args:
        fd: The descriptor to write to.
        payload: The bytes to deliver in full.

    Raises:
        OSError: The descriptor rejected a write.
    """
    view = memoryview(payload)
    while view:
        view = view[os.write(fd, view) :]


def main() -> int:
    """Write the hostile streams and the report, then exit like TestSuite does.

    Returns:
        `1` for the failing run, matching a real suite that raised its report;
        `0` for a `--skip-all` collection probe, which fails nothing.
    """
    skipping = "--skip-all" in sys.argv[1:]
    if not skipping:
        # The flood comes FIRST and the noise SECOND, so that when the flood
        # overruns the capture bound it is flood bytes that are dropped from the
        # middle: every hostile byte, and the genuine report, survive in the
        # retained tail, which is the region mtest reparses after truncation.
        write_all(1, flood_block(flood_lines_requested()))
        write_all(1, hostile_block(b"child stdout"))
        write_all(2, hostile_block(b"child stderr"))
    write_all(1, report_block(skipping))
    return 0 if skipping else 1


if __name__ == "__main__":
    sys.exit(main())
