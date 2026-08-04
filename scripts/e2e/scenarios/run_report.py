"""Run-report generation and delivery-failure E2E scenarios.

Two questions the unit and contract gates cannot answer between them. The
renderers are pinned against hand-built model values, and the contract gate
drives a small scratch project; neither runs the real binary over the
committed known-outcome tree, where a file that crashes, one that does not
compile, and one that fails an assertion all reach the same document. And a
report that cannot be delivered has to escalate a green run to exit `3`
without disturbing whatever report already sits at the target, which only a
real filesystem can be asked.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import tempfile
from typing import TYPE_CHECKING

from scripts.e2e.assertions import expect, expect_exit, expect_report


if TYPE_CHECKING:
    from scripts.e2e.runner import ScenarioContext


SUITE = "e2e/suite"
"""The committed tree whose outcomes the default suite scenario pins."""

GREEN_FILE = "e2e/suite/test_passing.mojo"
"""One file that passes, so a failing exit code can only be the report's."""

SUITE_ROWS = (
    "| e2e/suite/nested/test_nested.mojo | PASS |",
    "| e2e/suite/test_compile_error.mojo | COMPILE_ERROR |",
    "| e2e/suite/test_crashing.mojo | CRASH |",
    "| e2e/suite/test_failing.mojo | FAIL |",
    "| e2e/suite/test_noisy.mojo | PASS |",
    "| e2e/suite/test_passing.mojo | PASS |",
    "| e2e/suite/test_zero.mojo | PASS |",
)
"""The leading cells of the summary row every file of the suite produces.

Path and outcome are matched together, as one row prefix, rather than as two
substrings found anywhere: a document that named the path in one place and the
outcome in another would satisfy two independent checks while pairing neither.
The measured cells after them are deliberately not pinned.
"""

MACHINE_INDEX = (
    "- `e2e/suite/test_compile_error.mojo` — COMPILE_ERROR",
    "- `e2e/suite/test_crashing.mojo` — CRASH",
    "- `e2e/suite/test_failing.mojo::test_second_fails` — FAIL",
)
"""Exactly the entries the machine index carries for the default suite.

Compared as a whole list, so a document that stopped indexing one outcome
class fails here rather than passing on the two it kept. The failing file's
entry is its NODE ID: the index exists to be pasted back into the runner, and
a file path there would reproduce more than the failure it names.
"""

FAIL_SECTION = "## `e2e/suite/test_failing.mojo` — FAIL"
"""The failing file's section heading, in the concise style's own syntax."""

FAIL_NODE_HEADING = "### FAIL `e2e/suite/test_failing.mojo::test_second_fails`"
"""The per-test heading inside that section."""

RELATIVIZED_BACKTRACE = "At e2e/suite/test_failing.mojo:14:17"
"""The compiler-baked `At` line as the report must rewrite it.

The child prints an absolute path here. The document's head note claims the
paths it composes are relative to the run root, and this is the line that
claim is hardest to keep: it arrives inside untrusted failure detail rather
than from a `NodeId`.
"""

GREEN_SECTION = "## `e2e/suite/test_passing.mojo`"
"""A green file's section heading, which the default `concise` style omits."""


def _machine_index(document: str) -> tuple[str, ...]:
    """The machine index's entries, in document order.

    Args:
        document: The whole Markdown report.

    Returns:
        Every non-empty line after the machine-index heading, and `()` when
        the document carries no such heading at all.

        Split at the LAST occurrence, not the first. The index is the final
        thing the writer emits, while everything above it includes captured
        child output: a test that printed this heading itself would otherwise
        truncate the view to whatever followed its own line, which is a
        shorter list than the document holds and would fail the comparison
        for the wrong reason.
    """
    heading = "## Machine index"
    if heading not in document:
        return ()
    tail = document.rsplit(heading, 1)[1]
    return tuple(line for line in tail.splitlines() if line.strip())


def s_report_md(context: ScenarioContext) -> str:
    """`--report` publishes real documents for the real known-outcome tree.

    One invocation composes both sinks, because the two are meant to describe
    the same run from the same events: the Markdown document is read in full
    (every file's summary row, the failing file's section, the root-relative
    rewrite of its backtrace, the machine index, and the section the concise
    style leaves out), and the HTML sibling is checked for the shell and the
    same verdict, which is what proves one run served both formats.
    """
    with tempfile.TemporaryDirectory(prefix="mtest-run-report-") as tmp:
        markdown = Path(tmp) / "run.md"
        html = Path(tmp) / "run.html"
        run = context.runner.run_mtest(
            [
                SUITE,
                "--report",
                f"md:{markdown}",
                "--report",
                f"html:{html}",
            ]
        )
        # The suite's own verdict: a report that published cleanly must not
        # move the run's exit code in either direction.
        expect_exit(run, 1)
        expect_report(run, markdown, "the markdown run report")
        expect_report(run, html, "the html run report")

        document = markdown.read_text(encoding="utf-8")
        expect(
            document.startswith("# mtest report\n"),
            f"the markdown report does not open with its title: {document[:80]!r}",
        )
        expect(
            "relative to the run root" in document,
            "the document never states that its paths are root-relative, so a "
            "reader cannot tell which checkout they are relative to",
        )
        missing = [row for row in SUITE_ROWS if row not in document]
        expect(
            not missing,
            f"the summary table is missing {len(missing)} row(s): {missing}",
        )
        expect(
            FAIL_SECTION in document and FAIL_NODE_HEADING in document,
            "the failing file has no per-test section naming the test that failed",
        )
        expect(
            RELATIVIZED_BACKTRACE in document,
            f"the failure detail carries no root-relative backtrace "
            f"({RELATIVIZED_BACKTRACE!r}); the head note's claim is false",
        )
        expect(
            GREEN_SECTION not in document,
            "the default concise style sectioned a passing file, which only "
            "--report-style full may do",
        )
        index = _machine_index(document)
        expect(
            index == MACHINE_INDEX,
            f"the machine index reads {index}, want {MACHINE_INDEX}",
        )

        page = html.read_text(encoding="utf-8")
        expect(
            page.startswith("<!doctype html>"),
            f"the html report is not a document: {page[:80]!r}",
        )
        expect(
            "relative to the run root" in page,
            "the html document omits the root-relativity note the markdown "
            "one carries; the two renderings describe the same run",
        )
        expect(
            "<td>FAIL</td>" in page and "test_second_fails" in page,
            "the html document carries no FAIL row naming the failing test",
        )
        expect(
            "<script" not in page,
            "the self-contained html document grew a <script> element",
        )
        return (
            f"--report md+html over {SUITE}: {len(SUITE_ROWS)} summary rows, a "
            f"root-relative backtrace, {len(MACHINE_INDEX)} machine-index "
            f"entries, no section for a green file"
        )


def s_report_escalates(context: ScenarioContext) -> str:
    """An undeliverable report exits 3 AND the PRIOR report at PATH survives.

    The parent directory EXISTS and is made unwritable, which separates the
    two refusals that look alike from outside: a missing parent is a usage
    error caught before the run (exit 4), while a parent that cannot take the
    session-start temp is a delivery failure (exit 3). The file the runner is
    pointed at is green, so the `3` can only come from the report.

    Nothing touches PATH until the final rename, so the report already there
    has to survive byte for byte — the `--junit-xml` guarantee, held by the
    same means for the same reason.
    """
    tmp = tempfile.mkdtemp(prefix="mtest-run-report-")
    target = os.path.join(tmp, "run.md")
    prior = "# PRIOR REPORT\n\nkeep me\n"
    Path(target).write_text(prior, encoding="utf-8")
    # Unwritable, not absent: the unique temp cannot be created beside the
    # target at session start, which is the failure under test.
    os.chmod(tmp, 0o500)
    try:
        run = context.runner.run_mtest([GREEN_FILE, "--report", f"md:{target}"])
        expect_exit(run, 3)
        expect(
            "internal error" in run.stderr.lower(),
            f"an unwritable --report target was not an internal error:\n{run.stderr}",
        )
        # And the diagnostic has to name the destination it could not
        # prepare. A run composing several destinations reaches this exit
        # code from any of them, so a message that only says "internal
        # error" leaves the reader to guess which writer failed.
        expect(
            os.path.basename(target) in run.stderr,
            f"the internal error never names the report destination "
            f"{os.path.basename(target)!r} it could not prepare:\n{run.stderr}",
        )
        expect(
            Path(target).read_text(encoding="utf-8") == prior,
            "the prior report at PATH was modified by a doomed run",
        )
    finally:
        os.chmod(tmp, 0o700)
        shutil.rmtree(tmp, ignore_errors=True)
    return (
        "unwritable --report parent -> exit 3 on a green file; the prior "
        "report survives byte-for-byte"
    )
