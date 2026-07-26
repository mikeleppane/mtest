"""Core outcomes and ordinary console E2E scenarios."""

from __future__ import annotations

import contextlib
import os
import re
import shutil
import signal
import sys
import tempfile
from typing import Any

from scripts.e2e.assertions import (
    CAPTURE_BOUND_BYTES,
    VERDICT_TO_BUCKET,
    HostileStreams,
    expect,
    expect_accounting,
    expect_exit,
    hostile_actor,
    hostile_streams,
    verdict_line,
    verdict_paths_in_order,
)
from scripts.e2e.runner import (
    E2E_ROOT,
    FAKE_HOSTILE_MOJO,
    REPO_ROOT,
    SHORT_TIMEOUT,
    Run,
    ScenarioContext,
    ScenarioError,
    discovered_test_files,
)
from scripts.e2e.scenarios.json_reporter import assert_hostile_json_stream
from scripts.e2e.scenarios.junit_reporter import assert_hostile_junit_report


def s_manifest_completeness(context: ScenarioContext) -> str:
    """Reconcile the manifest and the committed tree in both directions.

    Every discoverable file must own a row, every row must name a file that is
    really on disk, and the non-discovered and support entries must exist while
    keeping a name no discovery walk would pick up.
    """
    tests = context.manifest["tests"]
    rows = set(tests.keys())
    disk = discovered_test_files()
    missing_rows = disk - rows
    stale_rows = rows - disk
    expect(
        not missing_rows,
        f"discovered files with no manifest row: {sorted(missing_rows)}",
    )
    expect(not stale_rows, f"manifest rows with no file on disk: {sorted(stale_rows)}")
    for rel in rows:
        expect(
            os.path.exists(os.path.join(REPO_ROOT, rel)),
            f"manifest row {rel} names a missing file",
        )
    # Non-discovered and support files exist but are not test_*.mojo.
    for rel in list(context.manifest.get("non_discovered", {})) + list(
        context.manifest.get("support_files", {})
    ):
        expect(
            os.path.exists(os.path.join(REPO_ROOT, rel)),
            f"listed support file {rel} is missing",
        )
        expect(
            not os.path.basename(rel).startswith("test_"),
            f"{rel} is listed as non-discovered but has a test_ prefix",
        )
    return f"{len(rows)} rows == {len(disk)} discovered files; both-way complete"


def _suite_tests(manifest: dict[str, Any]) -> dict[str, Any]:
    return {
        rel: row
        for rel, row in manifest["tests"].items()
        if row.get("in_default_suite")
    }


def s_default_suite(context: ScenarioContext) -> str:
    """Reconcile a whole default-suite run against the manifest rows it covers.

    Each member shows its manifest verdict token on a line naming its path, the
    zero-test file renders NO-TESTS instead of a plain PASS, the CRASH row keeps
    the target-pinned abort signal number and name, the COMPILE-ERROR banner
    references the undefined symbol its fixture names, the per-file and per-test
    bands agree with the manifest's own numbers, and the verdict lines arrive in
    lexicographic path order.
    """
    suite = _suite_tests(context.manifest)
    run = context.runner.run_mtest(["e2e/suite"])
    # Any exit_class-1 member means the session exits 1.
    any_failing = any(row["exit_class"] == 1 for row in suite.values())
    expect_exit(run, 1 if any_failing else 0)
    summ = expect_accounting(run)

    # Every suite file shows its manifest verdict token on a line naming its path.
    crash_lines: dict[str, str] = {}
    compile_error_files: list[str] = []
    for rel, row in suite.items():
        # A zero-test file renders NO-TESTS, not the manifest's PASS verdict.
        token = "NO-TESTS" if row.get("zero_tests") else row["verdict"]
        line = verdict_line(run, token, rel)
        if line is None:
            raise ScenarioError(f"missing verdict line {token} for {rel}")
        # S105: a console verdict token, not a credential.
        if token == "CRASH":  # noqa: S105
            crash_lines[rel] = line
        if token == "COMPILE-ERROR":  # noqa: S105 - verdict token, not a secret
            compile_error_files.append(rel)

    # Standing pin: std.os.abort lowers to the served target's trap instruction:
    # SIGILL (signal 4) on linux-64/x86_64, SIGTRAP (signal 5) on osx-arm64.
    # Require the exact number/name association on the verdict line, so neither a
    # changed death signal nor lost word-name can hide behind a generic CRASH.
    expect(
        len(crash_lines) == 1, f"expected exactly one CRASH fixture, got {crash_lines}"
    )
    target = (sys.platform.lower(), os.uname().machine.lower())
    abort_expectations = {
        ("linux", "x86_64"): (int(signal.SIGILL), "SIGILL"),
        ("darwin", "arm64"): (int(signal.SIGTRAP), "SIGTRAP"),
    }
    expect(
        target in abort_expectations,
        f"std.os.abort signal is not pinned for target {target[0]}/{target[1]}",
    )
    abort_signal, abort_name = abort_expectations[target]
    expected_abort_detail = f"signal {abort_signal} — {abort_name},"
    for rel, line in crash_lines.items():
        expect(
            expected_abort_detail in line,
            f"CRASH verdict line for {rel} lost its target-pinned detail "
            f"{expected_abort_detail!r}: {line!r}",
        )

    # Standing pin: the compile-error fixture provokes a NAME-RESOLUTION error,
    # not merely some build failure. The manifest claims it names an undefined
    # symbol; assert the rendered compiler banner actually references that
    # identifier. A future edit that turned the fixture into a syntax error (or
    # renamed the symbol) would leave the COMPILE-ERROR token green while quietly
    # breaking the property the manifest documents — this catches that drift.
    expect(
        len(compile_error_files) == 1,
        f"expected exactly one COMPILE-ERROR fixture, got {compile_error_files}",
    )
    cerr_rel = compile_error_files[0]
    marker = f"--- COMPILE-ERROR {cerr_rel}"
    expect(
        marker in run.stdout,
        f"no framed COMPILE-ERROR section for {cerr_rel}:\n{run.stdout}",
    )
    cerr_section = run.stdout[run.stdout.index(marker) :]
    expect(
        "this_symbol_is_never_defined_anywhere" in cerr_section,
        f"COMPILE-ERROR banner for {cerr_rel} did not reference the undefined "
        f"symbol the fixture names (name-resolution property):\n{cerr_section}",
    )

    # The zero-test file is a NO-TESTS pass: the zero-test ceiling is CLOSED, so
    # this PASS comes from a parsed zero-test report, not from the exit status.
    # As a member of the suite it still contributes to the exit-0 class.
    zero = [r for r, row in suite.items() if row.get("zero_tests")]
    expect(len(zero) == 1, "expected exactly one zero-test file")
    expect(
        verdict_line(run, "NO-TESTS", zero[0]) is not None,
        "zero-test file did not show a NO-TESTS verdict (never a plain PASS)",
    )
    # helper.mojo (non-discovered) must never appear.
    for rel in context.manifest.get("non_discovered", {}):
        expect(rel not in run.stdout, f"non-discovered file {rel} appeared in output")

    # Summary arithmetic under the TEST-count band: crashed/timed-out/compile-
    # error are per-FILE abnormal counts (from the verdict buckets), while
    # passed/failed count TESTS.
    file_abnormals = {"crashed": 0, "timed_out": 0, "compile_error": 0}
    for row in suite.values():
        bucket = VERDICT_TO_BUCKET[row["verdict"]]
        if bucket in file_abnormals:
            file_abnormals[bucket] += 1
    expect(
        summ.crashed == file_abnormals["crashed"],
        f"crashed FILES: band {summ.crashed} != manifest {file_abnormals['crashed']}",
    )
    expect(
        summ.timed_out == file_abnormals["timed_out"],
        f"timed-out FILES: band {summ.timed_out} != manifest "
        f"{file_abnormals['timed_out']}",
    )
    expect(
        summ.compile_error == file_abnormals["compile_error"],
        f"compile-error FILES: band {summ.compile_error} != manifest "
        f"{file_abnormals['compile_error']}",
    )
    # pass/fail/skip are per-TEST. Every report-bearing file (PASS or FAIL —
    # the verdict a parsed report can actually produce) must carry a per_test
    # block, and no non-report-bearing file (CRASH/COMPILE-ERROR, which never
    # reach the parser) may carry one; a manifest edit that adds a suite file
    # without one, or leaves a stale block on an abnormal one, fails loudly
    # here instead of silently under/over-counting the exact totals below.
    report_bearing = {"PASS", "FAIL"}
    for rel, row in suite.items():
        has_per_test = "per_test" in row
        if row["verdict"] in report_bearing:
            expect(
                has_per_test,
                f"{rel} is report-bearing ({row['verdict']}) but the manifest "
                f"has no per_test block for it",
            )
        else:
            expect(
                not has_per_test,
                f"{rel} is not report-bearing ({row['verdict']}) but the "
                f"manifest carries a per_test block for it",
            )

    want_passed = sum(
        r["per_test"]["passed"] for r in suite.values() if "per_test" in r
    )
    want_failed = sum(
        r["per_test"]["failed"] for r in suite.values() if "per_test" in r
    )
    want_skipped = sum(
        r["per_test"]["skipped"] for r in suite.values() if "per_test" in r
    )
    expect(
        summ.passed == want_passed,
        f"passed TESTS: band {summ.passed} != manifest per-test {want_passed}",
    )
    expect(
        summ.failed == want_failed,
        f"failed TESTS: band {summ.failed} != manifest per-test {want_failed}",
    )
    expect(
        summ.skipped == want_skipped,
        f"skipped TESTS: band {summ.skipped} != manifest per-test {want_skipped}",
    )
    expect(summ.excluded == 0 and summ.not_run == 0, "unexpected excluded/not-run")

    # Contract §17 (Determinism): the console summary is ordered lexicographically
    # by path, independent of finish order.
    paths = verdict_paths_in_order(run)
    expect(
        len(paths) == len(suite),
        f"expected {len(suite)} verdict lines, saw {len(paths)}: {paths}",
    )
    expect(
        paths == sorted(paths),
        f"verdict lines not in lexicographic path order (contract §17): {paths}",
    )
    return (
        f"exit 1; {summ.passed} passed / {summ.failed} failed / {summ.crashed} "
        f"crashed / {summ.compile_error} compile-error, arithmetic holds"
    )


def s_hostile(context: ScenarioContext) -> str:
    """The hostile handshake set: each report-shaped adversary, run alone.

    silent -> MALFORMED-SUITE (exit 1); forger (two blocks) -> MALFORMED-SUITE
    (exit 1); liar (off-grammar report) -> DRIFT (exit 3); overflow (a ~13 MiB
    flood) -> CAPTURE-OVERFLOW FAIL (exit 1). These files are NOT in the default
    suite — the liar alone forces exit 3, which would swamp a whole-suite run —
    so each is driven on its own here. The verdict tokens and exit codes come
    straight from the manifest rows for e2e/hostile/*.
    """
    hostile = {
        rel: row
        for rel, row in context.manifest["tests"].items()
        if rel.startswith("e2e/hostile/")
    }
    expect(len(hostile) == 4, f"expected 4 hostile fixtures, got {len(hostile)}")

    silent = "e2e/hostile/test_silent.mojo"
    run = context.runner.run_mtest([silent])
    expect_exit(run, 1)
    expect(
        verdict_line(run, "MALFORMED-SUITE", silent) is not None,
        f"silent binary did not report MALFORMED-SUITE:\n{run.stdout}",
    )

    forger = "e2e/hostile/test_forger.mojo"
    run = context.runner.run_mtest([forger])
    expect_exit(run, 1)
    expect(
        verdict_line(run, "MALFORMED-SUITE", forger) is not None,
        f"forger did not report MALFORMED-SUITE:\n{run.stdout}",
    )

    liar = "e2e/hostile/test_liar.mojo"
    run = context.runner.run_mtest([liar])
    expect_exit(run, 3)
    expect(
        "drift" in run.combined.lower(),
        f"liar did not surface a drift diagnostic (exit 3):\n{run.combined}",
    )

    # --show-output none keeps the ~8 MiB truncated capture out of the console;
    # the FAIL verdict line prints regardless of the show-output setting.
    overflow = "e2e/hostile/test_overflow.mojo"
    run = context.runner.run_mtest([overflow, "--show-output", "none"])
    expect_exit(run, 1)
    expect(
        verdict_line(run, "FAIL", overflow) is not None,
        f"overflow flood did not report FAIL:\n{run.stdout}",
    )
    return "silent/forger MALFORMED-SUITE, liar DRIFT exit 3, overflow FAIL"


HOSTILE_CONSOLE_TREE = "build/e2e-scratch/hostile-console"
"""Repo-relative home of this scenario's GENERATED source.

Deliberately outside `e2e/`, for the same reasons the descriptor-clamp scenario
generates its tree: the stand-in compiler writes a Python script, not an ELF
binary, so pointing it at a committed fixture would leave a `#!`-headed file
under the exact name a real `mojo build` produces. `build/` is gitignored and is
never walked by the manifest-completeness oracle, so nothing here joins a
committed inventory."""

HOSTILE_CONSOLE_NAME = "test_hostile_console"
"""The single generated module, and the stem of the file mtest is asked for.

Deliberately NOT the row name: the actor's `TEST_NAME` is a hostile row name
that no filesystem should have to hold, and nothing in mtest requires the two to
agree — the file is never really compiled, and the report's identity is its
header path, not its row names. Every assertion about the row reads
`hostile_actor().TEST_NAME`, so the two cannot silently drift into agreement."""

HOSTILE_CONSOLE_FILE = f"{HOSTILE_CONSOLE_TREE}/{HOSTILE_CONSOLE_NAME}.mojo"
"""The generated source, as mtest is asked for it."""

HOSTILE_CONSOLE_SOURCE = '''"""Generated source for the console text-safety scenario.

Never actually compiled: the scenario hands it to a stand-in that fabricates a
hostile report actor instead. Real `TestSuite` shape all the same, so the file
is a genuine test module rather than a shape only this scenario accepts.
"""
from std.testing import assert_equal, TestSuite


def test_hostile_console() raises:
    assert_equal(1, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
'''

HOSTILE_CONSOLE_RAW_BYTES = (
    ("ESC", "\x1b"),
    ("NUL", "\x00"),
    ("BEL", "\x07"),
    ("BS", "\x08"),
    ("VT", "\x0b"),
    ("FF", "\x0c"),
    ("DEL", "\x7f"),
    ("C1 CSI", "\u009b"),
    ("C1 NEL", "\u0085"),
    ("C1 ST", "\u009c"),
)
"""Every control the actor writes that this harness can actually observe, by
name. Not one may survive anywhere in the run's output: the console runs with
`--color never`, so mtest emits no ESC of its own either and a single occurrence
is a child byte that got through.

CR is deliberately ABSENT even though the actor writes one. `run_mtest` captures
with `text=True`, so Python's universal-newline translation rewrites a surviving
CR to LF before any assertion could see it \u2014 a `("CR", "\\r")` row here could
never fail and would be a guard in name only. A PTY capture does not rescue it
either: the tty's own ONLCR translation injects CR on output, so the byte stops
being attributable to the child. CR stays pinned where it is provable: exactly,
as `CR[\\x0D]` inside `HOSTILE_CONSOLE_FENCED_LINES` below, and by
`test_escape_multiline_escapes_cr_so_a_child_cannot_overwrite_a_line` in
`tests/unit/test_report_console_text.mojo`."""

HOSTILE_CONSOLE_FENCED_LINES = (
    "    | \\x1B[2J\\x1B[1;31mCHILD-CSI\\x1B[0m",
    "    | \\x1B]0;pwned-by-bel\\x07",
    "    | \\x1B]0;pwned-by-st\\x1B\\",
    "    | NUL[\\x00] BEL[\\x07] BS[\\x08] VT[\\x0B] FF[\\x0C] CR[\\x0D] DEL[\\x7F]",
    "    | \\u009BC1-CSI\\u0085C1-NEL\\u009C",
    "    | ��� not-utf8 �(",
)
"""The exact rendering of each hostile line: escaped, then fenced behind the
gutter. Pinned whole rather than by fragments — a partial escape (say, ESC but
not BEL) would still satisfy a fragment probe while leaving the terminal
addressable."""

HOSTILE_CONSOLE_DETAIL = (
    "AssertionError: \\x1B[2J\\x1B[1;31mCHILD-CSI\\x1B[0m \\x00 \\x7F "
    "\\u009BC1-CSI\\u0085C1-NEL\\u009C delims: dquote[\"] squote['] "
    "backslash[\\] lt[<] gt[>] amp[&] cdata-close[]]>] entity[&amp;] "
    'json-injection: ","event":"forged","captured_stdout":" '
    'xml-injection: </system-out><testcase name="forged" '
    'classname="forged"/><system-out>'
)
"""The child's failure detail as the console must render it.

Every control the child put in that line is visible escape text; every delimiter
that would end a JSON string or an XML element is untouched, because the console
is not a machine format and escaping them there would corrupt the message a
human is meant to read. The same source line is asserted, in the two other
spellings its own format requires, by the NDJSON and JUnit oracles."""

HOSTILE_CONSOLE_FORGERIES = (
    "PASS           e2e/forged/test_green.mojo  0.00s",
    "===== 9 passed, 0 failed, 0 skipped (0 excluded, 0 not run) in 0.0s =====",
    "--- FAIL e2e/forged/test_green.mojo::test_forged ---",
    "reproduce: mtest --gate /etc/shadow",
)
"""Lines the child prints that are shaped exactly like mtest's own. Escaping
cannot help here — they hold no control characters — so the gutter is the entire
defense, and each must appear ONLY behind it."""


def _write_hostile_console_tree() -> None:
    """Generate this scenario's single source, replacing any residue.

    Raises:
        OSError: The scratch tree could not be created or written.
    """
    root = os.path.join(REPO_ROOT, HOSTILE_CONSOLE_TREE)
    os.makedirs(root, exist_ok=True)
    path = os.path.join(root, f"{HOSTILE_CONSOLE_NAME}.mojo")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(HOSTILE_CONSOLE_SOURCE)


def _remove_hostile_console_artifacts() -> None:
    """Delete the generated source and the product the stand-in fabricated.

    Best-effort on every exit path: the fabricated product is a Python script
    living under a compiler-shaped name, so leaving it behind would hand a later
    scenario something that is not a binary.
    """
    shutil.rmtree(os.path.join(REPO_ROOT, HOSTILE_CONSOLE_TREE), ignore_errors=True)
    # A hand-mirror of the product's `_mangle` (src/mtest/session/scratch.mojo),
    # which cannot be imported from Python. The two sequential replaces match its
    # single pass only while the tree holds no `_` and the name holds no `/`.
    if "_" in HOSTILE_CONSOLE_TREE:
        raise AssertionError(HOSTILE_CONSOLE_TREE)
    if "/" in HOSTILE_CONSOLE_NAME:
        raise AssertionError(HOSTILE_CONSOLE_NAME)
    mangled = HOSTILE_CONSOLE_TREE.replace("_", "_u").replace("/", "_s")
    product = os.path.join(
        REPO_ROOT,
        "build",
        "bin",
        f"{mangled}_s{HOSTILE_CONSOLE_NAME.replace('_', '_u')}",
    )
    with contextlib.suppress(OSError):
        os.remove(product)


def s_hostile_console(context: ScenarioContext) -> str:
    """A child that writes terminal control sequences cannot drive the terminal.

    The producer is real: `fake_hostile_mojo.py` fabricates a direct bytes actor
    that writes invalid UTF-8, NUL, DEL, CSI, OSC closed by both BEL and ST, C1
    controls, report-lookalike noise, and lines shaped exactly like mtest's own
    verdict rows — and then a genuine reconciling report so the file lands on a
    real FAIL with a real per-test failure section. Every console surface the
    boundary covers is therefore rendered from bytes the child chose.

    Two independent claims are asserted. First, NO raw control byte survives
    anywhere in the run's output: the run is `--color never`, so mtest writes no
    ESC of its own and one occurrence would be the child's. Second, the escaped
    text lands in the exact fenced shape the contract documents, and every
    console-shaped forgery appears only behind the gutter, never as a line of
    its own where a reader — or a log scraper — would take it for mtest's voice.

    One pinned line is deliberately about the raw side: the invalid-UTF-8 line
    is asserted with its exact U+FFFD spelling, so a change that moved the lossy
    decoder while "fixing" the display would fail here rather than pass quietly.
    """
    args = [
        HOSTILE_CONSOLE_FILE,
        "--mojo",
        FAKE_HOSTILE_MOJO,
        "--color",
        "never",
    ]
    try:
        _write_hostile_console_tree()
        run = context.runner.run_mtest(args, timeout=SHORT_TIMEOUT)
        expect_exit(run, 1)

        # (1) The verdict itself: the hostile file is a real FAIL, not a
        # MALFORMED-SUITE, so the framed sections below were actually rendered.
        expect(
            verdict_line(run, "FAIL", HOSTILE_CONSOLE_FILE) is not None,
            f"the hostile file did not report FAIL:\n{run.stdout}",
        )

        # (2) Not one raw control byte anywhere in the run's output.
        for name, byte in HOSTILE_CONSOLE_RAW_BYTES:
            expect(
                byte not in run.combined,
                f"a raw {name} byte ({byte!r}) reached the console: the child "
                f"can still address the terminal",
            )

        # (3) The exact escaped-and-fenced rendering of each hostile line.
        for line in HOSTILE_CONSOLE_FENCED_LINES:
            expect(
                f"\n{line}\n" in run.stdout,
                f"the console did not render the fenced line {line!r}:\n{run.stdout}",
            )

        # (4) Every console-shaped forgery is fenced, and none of them stands
        # alone as a line. This is the claim escaping alone cannot make.
        stdout_lines = run.stdout.split("\n")
        for forgery in HOSTILE_CONSOLE_FORGERIES:
            expect(
                f"\n    | {forgery}\n" in run.stdout,
                f"the forged console line {forgery!r} was not fenced behind the "
                f"gutter:\n{run.stdout}",
            )
            expect(
                forgery not in stdout_lines,
                f"the forged console line {forgery!r} stood alone as a console "
                f"line and reads as mtest's own voice:\n{run.stdout}",
            )

        # (5) The per-test failure section rendered the child's detail through
        # the same boundary, so the failure story is neither lost nor
        # executable, and the reproduce line stays exactly one console line.
        node = f"{HOSTILE_CONSOLE_FILE}::{hostile_actor().TEST_NAME}"
        expect(
            f"--- FAIL {node} ---" in stdout_lines,
            f"no framed per-test FAIL section for {node}:\n{run.stdout}",
        )
        # The node id ends in shell metacharacters, so the repro line has to
        # single-quote it: pasted unquoted, `"/><testcase/>` would redirect and
        # the reader would run something the child composed. `'` itself is
        # absent from the name, so one pair of single quotes is the whole
        # quoting.
        expect(
            f"reproduce: mtest --mojo {FAKE_HOSTILE_MOJO} '{node}'" in stdout_lines,
            f"no exact, shell-quoted reproduce line for {node}:\n{run.stdout}",
        )
        detail = f"    | At {HOSTILE_CONSOLE_FILE}:1:1: {HOSTILE_CONSOLE_DETAIL}"
        expect(
            detail in stdout_lines,
            f"the per-test failure detail was not dedented, root-relativized, "
            f"escaped and fenced as expected:\n{run.stdout}",
        )
    finally:
        _remove_hostile_console_artifacts()
    return (
        f"hostile actor: FAIL verdict, no raw control byte survives, "
        f"{len(HOSTILE_CONSOLE_FENCED_LINES)} exact fenced lines, "
        f"{len(HOSTILE_CONSOLE_FORGERIES)} forgeries fenced"
    )


HOSTILE_CAPTURE_HEADER_SUFFIX = (
    " — captured output (file-scoped; TestSuite does not attribute output to"
    " individual tests) ---"
)
"""The exact tail of the console's file-scoped captured-output header line."""

HOSTILE_CAPTURE_STDERR_HEADER = "--- captured stderr ---"
"""The exact console line that separates the two captured streams."""

HOSTILE_GUTTER = "    | "
"""The gutter `prefix_lines` fences every captured logical line behind."""


def _logical_lines(text: str) -> int:
    """How many logical lines a captured block holds.

    A logical line is a run of text up to and including its terminating LF, and
    a trailing LF closes the last line rather than opening an empty one — the
    same rule `prefix_lines` fences by, so this is exactly how many gutter lines
    the console must print.

    Args:
        text: The lossy-decoded captured stream.

    Returns:
        The logical line count; `0` for empty text.
    """
    if text == "":
        return 0
    return text.count("\n") + (0 if text.endswith("\n") else 1)


def _fenced_capture_regions(run: Run) -> tuple[list[str], list[str]]:
    """The two fenced console regions of the file-scoped captured-output block.

    Args:
        run: The completed run.

    Returns:
        The stdout region's console lines and the stderr region's, in order.

    Raises:
        ScenarioError: If the block is missing or not framed exactly once.
    """
    # split("\n"), never splitlines(): the payload carries U+0085 and friends,
    # which Python treats as line boundaries and a console reader does not.
    lines = run.stdout.split("\n")
    headers = [
        index
        for index, line in enumerate(lines)
        if line.endswith(HOSTILE_CAPTURE_HEADER_SUFFIX)
    ]
    expect(
        len(headers) == 1,
        f"expected exactly one file-scoped captured-output header, got {len(headers)}",
    )
    separators = [
        index
        for index, line in enumerate(lines)
        if line == HOSTILE_CAPTURE_STDERR_HEADER
    ]
    expect(
        len(separators) == 1 and separators[0] > headers[0],
        f"expected exactly one captured-stderr header after the block header, "
        f"got indices {separators} for a header at {headers[0]}",
    )
    stdout_region = lines[headers[0] + 1 : separators[0]]
    stderr_region: list[str] = []
    for line in lines[separators[0] + 1 :]:
        # Every fenced line carries the gutter, so it is never empty: the first
        # empty line is the console's own blank after the block.
        if line == "":
            break
        stderr_region.append(line)
    return stdout_region, stderr_region


def s_hostile_reporters(context: ScenarioContext) -> str:
    """One hostile child, three reporters, one contract each.

    The same actor the console scenario uses is run ONCE more — armed with a
    stdout flood exactly the size of the capture bound, so the run overruns that
    bound by precisely the hostile payload it must not lose — with the console,
    the NDJSON stream, and the JUnit report all live. That is the point: every
    escaping helper mtest owns already has passing unit tests, so what is left
    to prove is that each reporter's call sites actually route through them, on
    the same bytes, in the same run.

    The three formats must NOT agree on their output, and each disagreement is
    asserted where it belongs:

    - the console escapes controls to visible text and fences every line behind
      a gutter, because its consumer is a terminal that would execute them;
    - the NDJSON stream JSON-escapes them and carries them through as real
      control characters, because its consumer is a parser;
    - the JUnit report replaces the ones XML 1.0 cannot represent with U+FFFD
      and entity-escapes its delimiters, because its consumer is an XML parser
      and an XSD.

    What they must agree on is the accounting: the same retained capture, the
    same truncation flags, the same verdict, and — against a child that wrote a
    complete report header for this very file with no Summary to close it — the
    same genuine report block.
    """
    actor = hostile_actor()
    flood_lines = CAPTURE_BOUND_BYTES // len(actor.FLOOD_LINE)
    args = [
        HOSTILE_CONSOLE_FILE,
        "--mojo",
        FAKE_HOSTILE_MOJO,
        "--color",
        "never",
        "--show-output",
        "all",
        "--gh-annotations",
        "off",
    ]
    with tempfile.TemporaryDirectory(prefix="mtest-hostile-reporters-") as tmp:
        stream_path = os.path.join(tmp, "hostile.ndjson")
        report_path = os.path.join(tmp, "hostile.xml")
        try:
            _write_hostile_console_tree()
            # The path the build stand-in resolves and embeds in the actor, which
            # the report header must byte-equal for the block to be this file's.
            canonical = os.path.realpath(os.path.join(REPO_ROOT, HOSTILE_CONSOLE_FILE))
            streams = hostile_streams(canonical, flood_lines)
            run = context.runner.run_mtest(
                [*args, "--json", stream_path, "--junit-xml", report_path],
                timeout=SHORT_TIMEOUT,
                env_overrides={actor.FLOOD_ENV: str(flood_lines)},
            )
            expect_exit(run, 1)
            expect(
                verdict_line(run, "FAIL", HOSTILE_CONSOLE_FILE) is not None,
                f"the hostile file did not report FAIL:\n{run.stdout[:4000]}",
            )
            console_detail = _assert_hostile_console(run, streams)
            stream_detail = assert_hostile_json_stream(
                run, stream_path, streams, HOSTILE_CONSOLE_FILE
            )
            report_detail = assert_hostile_junit_report(
                run, report_path, streams, HOSTILE_CONSOLE_FILE
            )
        finally:
            _remove_hostile_console_artifacts()
    return f"{console_detail}; {stream_detail}; {report_detail}"


def _assert_hostile_console(run: Run, streams: HostileStreams) -> str:
    """Judge the console rendering of the hostile run.

    Args:
        run: The completed run.
        streams: The predicted child streams for this run.

    Returns:
        A one-line summary of what the console proved.

    Raises:
        ScenarioError: On any mismatch.
    """
    # Every observable control, not just ESC and NUL. Two of these — VT and FF,
    # and U+0085 among the C1 rows — are also line boundaries to Python's
    # `str.splitlines()`, which `verdict_line` above uses on this very output.
    # Pinning them here keeps that helper's safety argument local to the
    # scenario that depends on it rather than borrowed from another one.
    for name, byte in HOSTILE_CONSOLE_RAW_BYTES:
        expect(
            byte not in run.combined,
            f"a raw {name} byte ({byte!r}) reached the console: the child can "
            f"still address the terminal",
        )
    for line in HOSTILE_CONSOLE_FENCED_LINES:
        expect(
            f"\n{line}\n" in run.stdout,
            f"the console did not render the fenced line {line!r}",
        )
    stdout_region, stderr_region = _fenced_capture_regions(run)
    for label, region, text in (
        ("stdout", stdout_region, streams.stdout.retained),
        ("stderr", stderr_region, streams.stderr.retained),
    ):
        decoded = text.decode("utf-8", "replace")
        expected = _logical_lines(decoded)
        expect(
            len(region) == expected,
            f"the console fenced {len(region)} captured {label} lines, want "
            f"{expected} — one per logical line of the retained capture",
        )
        for index, line in enumerate(region):
            if not line.startswith(HOSTILE_GUTTER):
                raise ScenarioError(
                    f"captured {label} console line {index} escaped the gutter "
                    f"and reads as mtest's own voice: {line[:200]!r}"
                )
    return (
        f"console: {len(stdout_region)} + {len(stderr_region)} fenced lines, "
        f"none of {len(HOSTILE_CONSOLE_RAW_BYTES)} raw controls survives, exact "
        f"escape tokens"
    )


def s_single_pass(context: ScenarioContext) -> str:
    """A lone passing file exits 0, shows PASS, and reconciles its accounting."""
    rel = "e2e/suite/test_passing.mojo"
    run = context.runner.run_mtest([rel])
    expect_exit(run, 0)
    expect(verdict_line(run, "PASS", rel) is not None, "no PASS verdict line")
    expect_accounting(run)
    return "single passing file -> exit 0"


def s_exitfirst(context: ScenarioContext) -> str:
    """`-x` stops scheduling at the first failure and leaves the rest NOT-RUN."""
    run = context.runner.run_mtest(["e2e/suite", "-x"])
    expect_exit(run, 1)
    summ = expect_accounting(run)
    expect(summ.not_run >= 1, f"-x left nothing NOT-RUN (not_run={summ.not_run})")
    return f"-x stopped scheduling; {summ.not_run} NOT-RUN, accounting holds"


def s_maxfail(context: ScenarioContext) -> str:
    """`--maxfail N` stops scheduling once N failing TESTS have accumulated.

    e2e/maxfail/ sorts test_a_fail, test_b_fail, test_c_pass; each failing
    file contributes exactly one failing test. `--maxfail 1` must stop right
    after test_a_fail, leaving the other two NOT-RUN.
    """
    run = context.runner.run_mtest(["e2e/maxfail", "--maxfail", "1"])
    expect_exit(run, 1)
    summ = expect_accounting(run)
    expect(summ.failed == 1, f"--maxfail 1 let {summ.failed} FAILs run, expected 1")
    expect(summ.not_run == 2, f"--maxfail 1 left {summ.not_run} NOT-RUN, expected 2")
    expect(
        verdict_line(run, "FAIL", "e2e/maxfail/test_a_fail.mojo") is not None,
        "the file that tripped --maxfail did not report FAIL",
    )
    return (
        f"--maxfail 1 stopped after 1 failing test; {summ.not_run} NOT-RUN, "
        f"accounting holds"
    )


def s_exclude_and_stale(context: ScenarioContext) -> str:
    """`--exclude` announces every exclusion and warns on a pattern that misses.

    A pattern matching nothing must produce a stale-exclusion warning instead of
    passing silently, and the excluded count must reflect only the file that was
    really dropped.
    """
    run = context.runner.run_mtest(
        [
            "e2e/excluded",
            "e2e/suite/test_passing.mojo",
            "--exclude",
            "e2e/excluded/test_excluded.mojo",
            "--exclude",
            "e2e/stale_no_such_*.mojo",
        ]
    )
    expect_exit(run, 0)
    summ = expect_accounting(run)
    expect(
        verdict_line(run, "EXCLUDED", "e2e/excluded/test_excluded.mojo") is not None,
        "no loud EXCLUDED line",
    )
    expect(
        "stale-exclusion" in run.combined,
        "no stale-exclusion warning for the pattern that matched nothing",
    )
    expect(summ.excluded == 1, f"expected 1 excluded, got {summ.excluded}")
    return "one EXCLUDED + stale-exclusion warning; excluded=1"


def s_all_excluded(context: ScenarioContext) -> str:
    """Excluding every selected file exits 5 and still prints the EXCLUDED line."""
    run = context.runner.run_mtest(
        ["e2e/excluded", "--exclude", "e2e/excluded/test_excluded.mojo"]
    )
    expect_exit(run, 5)
    expect(
        verdict_line(run, "EXCLUDED", "e2e/excluded/test_excluded.mojo") is not None,
        "no EXCLUDED line",
    )
    return "everything excluded -> exit 5"


def s_empty_dir(context: ScenarioContext) -> str:
    """An empty directory inside the invocation root exits 5, not 0."""
    # Must live inside the invocation root (an out-of-root operand is exit 4).
    tmp = tempfile.mkdtemp(prefix=".e2e_empty_", dir=E2E_ROOT)
    try:
        rel = os.path.relpath(tmp, REPO_ROOT)
        run = context.runner.run_mtest([rel])
        expect_exit(run, 5)
    finally:
        os.rmdir(tmp)
    return "empty directory -> exit 5"


def s_failing_gate(context: ScenarioContext) -> str:
    """A failing `--gate` aborts the session and leaves the rest NOT-RUN."""
    run = context.runner.run_mtest(
        ["e2e/suite", "--gate", "e2e/suite/test_failing.mojo"]
    )
    expect_exit(run, 1)
    summ = expect_accounting(run)
    expect(summ.not_run >= 1, f"gate abort left nothing NOT-RUN ({summ.not_run})")
    expect(summ.failed >= 1, "gate failure not reflected in summary")
    return f"failing gate aborts; {summ.not_run} NOT-RUN"


def s_quiet_verbose(context: ScenarioContext) -> str:
    """`-q` drops the PASS verdict lines but keeps the summary band.

    `-v` adds the build command, so each verbosity end is asserted against what
    it is documented to change rather than against the other.
    """
    rel = "e2e/suite/test_passing.mojo"
    quiet = context.runner.run_mtest([rel, "-q"])
    expect_exit(quiet, 0)
    expect(
        not any(line.startswith("PASS") for line in quiet.stdout.splitlines()),
        "-q still printed a PASS verdict line",
    )
    expect("passed" in quiet.combined, "-q dropped the summary band")

    verbose = context.runner.run_mtest([rel, "-v"])
    expect_exit(verbose, 0)
    expect("build:" in verbose.combined, "-v did not print the build command")
    expect("mojo build" in verbose.combined, "-v build line missing the build cmd")
    return "-q omits PASS lines; -v adds build cmd + timing"


def s_show_output(context: ScenarioContext) -> str:
    """`--show-output` decides which captures are framed, and nothing else.

    `none` suppresses the framed FAIL section, the default frames a failure and
    keeps the `reproduce:` line INSIDE that section, and `all` frames a pass too.
    """
    fail = "e2e/suite/test_failing.mojo"
    pass_ = "e2e/suite/test_passing.mojo"  # noqa: S105 - a fixture path, not a secret
    none = context.runner.run_mtest([fail, "--show-output", "none"])
    expect_exit(none, 1)
    expect("--- FAIL" not in none.stdout, "--show-output none still framed the FAIL")

    default = context.runner.run_mtest([fail])
    expect_exit(default, 1)
    expect("--- FAIL" in default.stdout, "default did not frame the FAIL")
    # The reproduce line lives INSIDE the framed section, not just anywhere in
    # stdout, and names the failing file the way a human would re-invoke it.
    fail_section = default.stdout[default.stdout.index("--- FAIL") :]
    expect(
        f"reproduce: mtest {fail}" in fail_section,
        f"no reproduce: line for {fail} inside the framed FAIL section",
    )

    all_ = context.runner.run_mtest([pass_, "--show-output", "all"])
    expect_exit(all_, 0)
    expect("--- PASS" in all_.stdout, "--show-output all did not frame the PASS")
    return "framing: none suppresses, failures frames FAIL, all frames PASS"


DURATIONS_ROW_RE = re.compile(r"^  (\S+)\s+([\d.]+)s\s*$")


def s_durations(context: ScenarioContext) -> str:
    """`--durations N` renders a file-level slowest-files list.

    INFORMAL tier: structure only (presence, size, order, `-q` survival) — never
    exact timings.
    """
    suite = _suite_tests(context.manifest)
    files_run = sum(1 for row in suite.values() if row["verdict"] != "COMPILE-ERROR")
    cerr_rel = next(
        rel for rel, row in suite.items() if row["verdict"] == "COMPILE-ERROR"
    )

    # Absent without the flag.
    absent = context.runner.run_mtest(["e2e/suite"])
    expect(
        "slowest" not in absent.stdout,
        "a slowest-files section appeared without --durations",
    )

    # Present with the flag; requesting far more rows than files ran, the
    # header states the ACTUAL (capped) count, never the requested N.
    requested = files_run + 50
    run = context.runner.run_mtest(["e2e/suite", "--durations", str(requested)])
    m = re.search(r"slowest (\d+) files:\n((?:  .+\n)+)", run.stdout)
    if m is None:
        raise ScenarioError(
            f"no slowest-files section with --durations {requested}:\n{run.stdout}"
        )
    shown = int(m.group(1))
    rows = [ln for ln in m.group(2).splitlines() if ln.strip()]
    expect(
        shown == files_run,
        f"header states {shown}, expected {files_run} (files that actually ran)",
    )
    expect(shown != requested, f"header echoed the requested N ({requested}) verbatim")
    expect(len(rows) == shown, f"header says {shown} rows but {len(rows)} rendered")

    parsed = []
    for ln in rows:
        rm = DURATIONS_ROW_RE.match(ln)
        if rm is None:
            raise ScenarioError(f"slowest-files row is not 'path  N.NNs': {ln!r}")
        parsed.append((rm.group(1), float(rm.group(2))))

    # The COMPILE-ERROR file never reached the run step (duration 0.0) and
    # must never appear among the rows, however many were requested.
    expect(
        all(path != cerr_rel for path, _dur in parsed),
        f"COMPILE-ERROR file {cerr_rel} (never ran) appeared in the "
        f"slowest-files list: {parsed}",
    )

    # Descending duration order (ties would break by path, not asserted here
    # since real wall-clock durations are exceedingly unlikely to tie).
    durs = [d for _p, d in parsed]
    expect(
        all(durs[i] >= durs[i + 1] for i in range(len(durs) - 1)),
        f"slowest-files rows are not in descending duration order: {parsed}",
    )

    # Survives -q: an explicit --durations beats the -q verbosity default.
    quiet = context.runner.run_mtest(["e2e/suite", "--durations", "2", "-q"])
    expect("slowest 2 files:" in quiet.stdout, "-q suppressed the --durations list")

    return (
        f"absent w/o flag; {shown} rows (capped from {requested}), descending, "
        f"survives -q"
    )


def s_color(context: ScenarioContext) -> str:
    """NO_COLOR must silence AUTO color even on a real tty.

    `--color always` is absolute and paints regardless of NO_COLOR or tty-ness.

    A piped stdout (run_mtest) is NEVER a tty, so AUTO would already be
    colorless for an unrelated reason — that would make "NO_COLOR -> no ANSI"
    trivially true even if NO_COLOR were ignored outright. run_mtest_pty
    attaches a real pty so the AUTO+tty case is actually colored first, then
    proves NO_COLOR turns it off.
    """
    rel = "e2e/suite/test_failing.mojo"

    # Explicitly REMOVE NO_COLOR so the colors-expected case does not inherit an
    # ambient NO_COLOR (e.g. under `NO_COLOR=1 pixi run ci`), which would silence
    # AUTO color and fail this assertion spuriously. The NO_COLOR-silences case
    # below still sets it.
    tty_rc, tty_out = context.runner.run_mtest_pty(
        [rel], env_overrides={"NO_COLOR": None}, timeout=SHORT_TIMEOUT
    )
    expect(tty_rc == 1, f"expected exit 1 under a pty, got {tty_rc}")
    expect(
        b"\x1b" in tty_out,
        "AUTO on a real tty (NO_COLOR unset) produced no ANSI escapes",
    )

    no_color_rc, no_color_out = context.runner.run_mtest_pty(
        [rel], env_overrides={"NO_COLOR": "1"}, timeout=SHORT_TIMEOUT
    )
    expect(no_color_rc == 1, f"expected exit 1 under a pty, got {no_color_rc}")
    expect(
        b"\x1b" not in no_color_out,
        "NO_COLOR=1 on a real tty still emitted ANSI escape bytes",
    )

    always = context.runner.run_mtest([rel, "--color", "always"], timeout=SHORT_TIMEOUT)
    expect_exit(always, 1)
    expect(
        "\x1b" in always.stdout,
        "--color always emitted no ANSI even though it is documented absolute",
    )
    return "AUTO+tty colors, NO_COLOR silences it, --color always is absolute"


def s_passthrough_and_forbidden(context: ScenarioContext) -> str:
    """A forwarded build argument reaches the build; a forbidden one exits 4.

    `-o`, `--emit=`, and an extra source operand each refuse with something on
    stderr, so passthrough cannot be used to redirect or extend the build.
    """
    rel = "e2e/suite/test_passing.mojo"
    good = context.runner.run_mtest([rel, "--", "--no-optimization"])
    expect_exit(good, 0)
    expect(
        verdict_line(good, "PASS", rel) is not None, "forwarded build arg broke the run"
    )

    forbidden = [
        [rel, "--", "-o", "/tmp/x"],
        [rel, "--", "--emit=llvm"],
        [rel, "--", "extra_source.mojo"],
    ]
    for args in forbidden:
        run = context.runner.run_mtest(args, timeout=SHORT_TIMEOUT)
        expect_exit(run, 4)
        expect(
            run.stderr.strip() != "",
            f"forbidden build arg {args} wrote nothing to stderr",
        )
    return "passthrough build arg works; -o/--emit/extra-source each exit 4"


def s_out_of_root(context: ScenarioContext) -> str:
    """An operand outside the invocation root exits 4 and says it escaped."""
    run = context.runner.run_mtest(["../outside_the_root.mojo"], timeout=SHORT_TIMEOUT)
    expect_exit(run, 4)
    expect(
        "escapes the invocation root" in run.stderr or "escapes" in run.stderr,
        f"out-of-root operand did not report escaping the root:\n{run.stderr}",
    )
    return "out-of-root operand -> exit 4"
