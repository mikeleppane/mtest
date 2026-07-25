#!/usr/bin/env python3
"""A direct bytes actor that speaks a valid report through hostile noise.

Stands in for a compiled test binary that a hostile — or merely broken — test
module produced. Everything it writes goes to the raw `stdout`/`stderr` buffers,
so the bytes on the wire are exactly the ones chosen here: sequences a terminal
emulator would EXECUTE rather than print (CSI, OSC closed by BEL and by the
two-byte ST, C1 controls), bytes that are not valid UTF-8 at all, NUL and DEL,
and lines shaped like mtest's own console rows so a reader could be fooled about
which process said them.

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
accept the block as this file's.

Stdlib only, no third-party imports — this is a test-only subprocess actor, not
part of the pure-Mojo product.
"""

from __future__ import annotations

import sys

CANONICAL = "@MTEST_CANONICAL_SOURCE@"
"""The absolute, symlink-resolved source path the report header must match.

Replaced with a real path when the build stand-in copies this file. Left as the
placeholder in the committed copy, where it names no file on disk."""

TEST_NAME = "test_hostile_console"
"""The single test the fabricated report declares. Whitespace- and `::`-free, so
the row name is well-formed under the report grammar."""

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


def hostile_block(tag: bytes) -> bytes:
    """Every hostile byte class, once, labelled with `tag`.

    Args:
        tag: A short stream label so a reader can tell the two streams apart.

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
            CONSOLE_LOOKALIKES.rstrip(b"\n"),
            REPORT_LOOKALIKES.rstrip(b"\n"),
            b"--- " + tag + b" ends ---",
            b"",
        )
    )


def report_block(skipping: bool) -> bytes:
    """The genuine, reconciling report block for `CANONICAL`.

    The trailing spaces after the header path and after `skipped` are the
    toolchain's own grammar, not formatting, and the failure trailer is required
    whenever the summary counts a failure.

    Args:
        skipping: Whether this is a `--skip-all` collection probe, which lists
            the test as SKIP and declares no failure.

    Returns:
        The report block's bytes, LF-terminated.
    """
    canonical = CANONICAL.encode("utf-8", "surrogateescape")
    if skipping:
        row = b"    SKIP [ 0.00s ] " + TEST_NAME.encode() + b"\n"
        summary = b"Summary [ 0.00s ] 1 tests run: 0 passed , 0 failed , 1 skipped \n"
        trailer = b""
    else:
        row = (
            b"    FAIL [ 0.00s ] "
            + TEST_NAME.encode()
            + b"\n      At "
            + canonical
            + b":1:1: AssertionError: "
            + CSI
            + b" \x00 \x7f "
            + C1
            + b"\n"
        )
        summary = b"Summary [ 0.00s ] 1 tests run: 0 passed , 1 failed , 0 skipped \n"
        trailer = b"Test suite' " + canonical + b" 'failed! \n"
    return (
        b"\nRunning 1 tests for "
        + canonical
        + b" \n"
        + row
        + b"--------\n"
        + summary
        + trailer
    )


def main() -> int:
    """Write the hostile streams and the report, then exit like TestSuite does.

    Returns:
        `1` for the failing run, matching a real suite that raised its report;
        `0` for a `--skip-all` collection probe, which fails nothing.
    """
    skipping = "--skip-all" in sys.argv[1:]
    if not skipping:
        # The noise comes FIRST, so the genuine block is the last one on the
        # stream: mtest anchors its terminal framing by scanning from the end.
        sys.stdout.buffer.write(hostile_block(b"child stdout"))
        sys.stderr.buffer.write(hostile_block(b"child stderr"))
        sys.stderr.buffer.flush()
    sys.stdout.buffer.write(report_block(skipping))
    sys.stdout.buffer.flush()
    return 0 if skipping else 1


if __name__ == "__main__":
    sys.exit(main())
