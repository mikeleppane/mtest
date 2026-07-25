"""JUnit reporter lifecycle and determinism E2E scenarios."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import signal
import tempfile
from xml.etree import ElementTree as ET

from scripts.checks.reports import json_stream as json_stream_check
from scripts.checks.reports import junit as junit_check
from scripts.checks.reports import junit_canonicalize
from scripts.e2e.assertions import (
    ELISION,
    INTERRUPT_TIMEOUT,
    SLOW_NOT_RUN_FILES,
    SLOW_TREE,
    HostileStreams,
    arm_slow_tree,
    expect,
    expect_exit,
    expect_report,
    hostile_actor,
    junit_not_run_files,
)
from scripts.e2e.runner import (
    REPO_ROOT,
    SHORT_TIMEOUT,
    Run,
    ScenarioContext,
    ScenarioError,
)


XML_RAW_FORBIDDEN = (
    ("NUL", b"\x00"),
    ("BEL", b"\x07"),
    ("BS", b"\x08"),
    ("VT", b"\x0b"),
    ("FF", b"\x0c"),
    ("ESC", b"\x1b"),
)
"""Control bytes XML 1.0 has no legal representation for, in any form.

The reporter replaces each with U+FFFD, so a single occurrence anywhere in the
published document — text, attribute, or raw byte — is a sanitization bypass.
Tab, LF, and CR are absent on purpose: all three are legal `Char`s that the
reporter deliberately passes through."""


def xml_text_as_parsed(text: str) -> str:
    """The documented JUnit sanitization of one untrusted text node.

    Two rules compose here, and the assertion needs both:

    - the reporter's own (`xml_escape_text`): `&`/`<`/`>` become entities, which
      a parser gives back unchanged, so they are invisible at this level; Tab,
      LF, and CR pass through literally; every other code point below `U+0020`,
      and the noncharacters `U+FFFE`/`U+FFFF`, become `U+FFFD`, because XML 1.0
      cannot represent them at all;
    - the XML 1.0 parser's line-ending normalization, which folds a literal CRLF
      or a lone CR to a single LF before any application sees it.

    Args:
        text: The text the reporter was handed, already lossy-decoded.

    Returns:
        What a conforming XML parser must hand back for that text node.
    """
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    out: list[str] = []
    for character in normalized:
        if character in "\t\n":
            out.append(character)
        elif character < " " or character in "\ufffe\uffff":
            out.append("\ufffd")
        else:
            out.append(character)
    return "".join(out)


def _only_child(parent: ET.Element, tag: str, what: str) -> ET.Element:
    """The single `tag` child of `parent`, or a failure naming `what`.

    Args:
        parent: The element to search, one level deep.
        tag: The child element name.
        what: How to name the child in a failure.

    Returns:
        The single matching child.

    Raises:
        ScenarioError: If there is not exactly one.
    """
    found = [child for child in parent if child.tag == tag]
    if len(found) != 1:
        raise ScenarioError(
            f"expected exactly one {what} (<{tag}>), got {len(found)}: "
            f"{[child.tag for child in parent]}"
        )
    return found[0]


def assert_hostile_junit_report(
    run: Run, report_path: str | Path, streams: HostileStreams, rel_path: str
) -> str:
    """Judge the JUnit report of the one hostile-actor invocation.

    The schema oracle comes first: `xmllint` against the vendored junit-10 XSD
    decides well-formedness and structure, so an escaping bypass that produced a
    document only a lenient reader could love fails here rather than downstream.
    Everything after that is exact: the sanitized form of each text node is
    computed from the actor's payload by `xml_text_as_parsed`, and the raw bytes
    are checked for the control characters and the injected markup that
    sanitization exists to remove.

    Args:
        run: The completed run, for diagnostics on a missing artifact.
        report_path: Where the run was told to write the report.
        streams: The predicted child streams for this run.
        rel_path: The repo-relative source path under test.

    Returns:
        A one-line summary of what the report proved.

    Raises:
        ScenarioError: On any schema, arithmetic, or content mismatch.
    """
    actor = hostile_actor()
    path = expect_report(run, report_path, "the hostile --junit-xml report")
    try:
        totals = junit_check.check_artifact(path)
    except junit_check.CheckFailure as error:
        raise ScenarioError(
            f"the junit-10 oracle rejected the hostile report: {error}"
        ) from error
    expect(
        (totals.tests, totals.failures, totals.errors, totals.skipped) == (1, 1, 0, 0),
        f"the hostile report's totals are {totals}, want one failing row",
    )

    raw = path.read_bytes()
    for name, byte in XML_RAW_FORBIDDEN:
        expect(
            byte not in raw,
            f"a raw {name} byte ({byte!r}) reached the JUnit document; XML 1.0 "
            f"cannot represent it and the reporter must have replaced it",
        )
    expect(
        b"]]>" not in raw,
        "the child's CDATA-closing sequence reached the document unescaped",
    )
    expect(
        b"]]&gt;" in raw,
        "the child's `]]>` is missing from the document entirely; the text node "
        "it belongs to was dropped rather than escaped",
    )
    # The child's injected markup must appear only in its escaped spelling. A
    # text node does not escape `"`, so the forged attribute value IS in the
    # document as text; what may not be there is the tag that would give it
    # meaning, and the element boundary the child tried to close early.
    expect(
        b'&lt;testcase name="forged"' in raw,
        "the child's injected <testcase> markup is missing from the document "
        "entirely; the text node carrying it was dropped rather than escaped",
    )
    expect(
        raw.count(b"<testcase") == 1,
        f"the document holds {raw.count(b'<testcase')} <testcase> elements, "
        "want the one genuine row: the child's injected markup was written as "
        "markup",
    )
    expect(
        raw.count(b"<system-out>") == 1 and raw.count(b"</system-out>") == 1,
        f"the document holds {raw.count(b'<system-out>')} opening and "
        f"{raw.count(b'</system-out>')} closing <system-out> tags, want one of "
        "each: the child closed the element early",
    )

    root = ET.parse(os.fspath(path)).getroot()
    suite = _only_child(root, "testsuite", "testsuite for the hostile file")
    expect(
        suite.get("name") == rel_path,
        f"the hostile suite is named {suite.get('name')!r}, want {rel_path!r}",
    )
    case = _only_child(suite, "testcase", "testcase row")
    node = f"{rel_path}::{actor.TEST_NAME}"
    expect(
        case.get("name") == node,
        f"the hostile row is named {case.get('name')!r}, want {node!r} — a row "
        f"named for the orphan report header would mean the wrong block was "
        f"selected",
    )
    failure = _only_child(case, "failure", "failure child of the hostile row")
    expect(
        failure.get("type") == "AssertionError",
        f"the failure type is {failure.get('type')!r}, want 'AssertionError'",
    )
    _expect_xml_text(failure.text, streams.detail, "the <failure> body")
    _expect_xml_text(
        _only_child(suite, "system-out", "suite system-out").text,
        streams.stdout.reporter_text,
        "<system-out>",
    )
    _expect_xml_text(
        _only_child(suite, "system-err", "suite system-err").text,
        streams.stderr.reporter_text,
        "<system-err>",
    )
    expect(
        str(_only_child(suite, "system-out", "suite system-out").text).count(ELISION)
        == 1,
        "the bounded <system-out> carries no single elision marker",
    )
    return (
        f"junit: xmllint/XSD accepts {len(raw)} bytes, exact sanitized "
        f"system-out/err and <failure> body, no injected row"
    )


def _expect_xml_text(actual: str | None, source: str, what: str) -> None:
    """Assert one text node equals the documented sanitization of `source`.

    Args:
        actual: The parsed text node.
        source: The text the reporter was handed.
        what: The node's name, for the failure message.

    Raises:
        ScenarioError: If the node is absent or differs, naming the first
            differing offset.
    """
    expected = xml_text_as_parsed(source)
    if actual == expected:
        return
    if actual is None:
        raise ScenarioError(f"{what} carries no text at all")
    for index in range(min(len(actual), len(expected))):
        if actual[index] != expected[index]:
            raise ScenarioError(
                f"{what} differs from the documented sanitization at offset "
                f"{index} (lengths {len(actual)} vs {len(expected)}):\n"
                f"  got      {actual[max(index - 60, 0):index + 60]!r}\n"
                f"  expected {expected[max(index - 60, 0):index + 60]!r}"
            )
    raise ScenarioError(
        f"{what} has length {len(actual)}, want {len(expected)}; the shorter "
        f"value is a prefix of the longer one"
    )


def s_junit_scratch_cleanup(context: ScenarioContext) -> str:
    """A `--junit-xml` run leaves no spool directory behind. `main` owns the
    `mkdtemp` scratch it creates for per-suite fragments and frees it on exit;
    a busy /tmp would otherwise accrete one leaked directory (plus a fragment)
    per invocation, and eventually a `mkdtemp` failure before tests even run."""
    report_dir = tempfile.mkdtemp()
    tmpdir = tempfile.mkdtemp()  # the isolated TMPDIR the run's mkdtemp lands in
    try:
        report_path = os.path.join(report_dir, "report.xml")
        run = context.runner.run_mtest(
            ["e2e/suite", "--junit-xml", report_path],
            env_overrides={"TMPDIR": tmpdir},
        )
        expect_exit(run, 1)  # the default suite's known outcome: a normal finalize
        expect_report(run, report_path, "the junit report")
        junit_check.check_artifact(Path(report_path))
        leftovers = os.listdir(tmpdir)
        expect(
            leftovers == [],
            f"the junit spool leaked into TMPDIR after the run: {leftovers}",
        )
        return "a --junit-xml run leaves no spool directory in TMPDIR (report valid)"
    finally:
        shutil.rmtree(report_dir, ignore_errors=True)
        shutil.rmtree(tmpdir, ignore_errors=True)


def s_junit_schema_gate(context: ScenarioContext) -> str:
    """`--junit-xml PATH` writes a document that PASSES the junit-10 oracle
    (schema + arithmetic), including a flaky suite in chronological order and a
    rerun-exhausted suite with the FIRST attempt as the initial primary."""
    tmp = tempfile.mkdtemp()
    scratch = os.path.join(REPO_ROOT, "build", "e2e-scratch")
    marker = os.path.join(scratch, "flaky_marker")

    # Base document over the default suite: valid, with the compile-error file's
    # [build] sentinel and real per-test rows.
    suite_path = os.path.join(tmp, "suite.xml")
    run = context.runner.run_mtest(["e2e/suite", "--junit-xml", suite_path])
    expect_exit(run, 1)
    expect_report(run, suite_path, "the base junit report")
    junit_check.check_artifact(Path(suite_path))
    suite_doc = Path(suite_path).read_text()
    expect(
        'name="[build]"' in suite_doc,
        "the compile-error file carries no [build] sentinel",
    )
    expect(
        "::test_" in suite_doc,
        "the report carries no real per-test node-id rows",
    )

    # Flaky (chronological): crash-then-pass under --retries 1 -> flakyFailure.
    os.makedirs(scratch, exist_ok=True)
    if os.path.exists(marker):
        os.remove(marker)
    flaky_path = os.path.join(tmp, "flaky.xml")
    frun = context.runner.run_mtest(
        ["e2e/flaky/test_flaky.mojo", "--retries", "1", "--junit-xml", flaky_path],
        timeout=SHORT_TIMEOUT,
    )
    expect_exit(frun, 0)
    expect_report(frun, flaky_path, "the flaky suite's junit report")
    junit_check.check_artifact(Path(flaky_path))
    expect(
        "<flakyFailure" in Path(flaky_path).read_text(),
        "the flaky suite carries no flakyFailure child",
    )

    # Rerun-exhausted (initial-primary): a timeout on every attempt under
    # --timeout 1 --retries 1 -> an [attempts] row whose primary <error>
    # (the FIRST attempt) precedes its rerunError children.
    stub_path = os.path.join(tmp, "stubborn.xml")
    srun = context.runner.run_mtest(
        [
            "e2e/stubborn/test_stubborn.mojo",
            "--timeout",
            "1",
            "--retries",
            "1",
            "--junit-xml",
            stub_path,
        ],
        timeout=SHORT_TIMEOUT,
    )
    expect_exit(srun, 1)
    expect_report(srun, stub_path, "the rerun-exhausted junit report")
    junit_check.check_artifact(Path(stub_path))
    stub_doc = Path(stub_path).read_text()
    expect('name="[attempts]"' in stub_doc, "no [attempts] sentinel on the rerun-exhausted suite")
    i_primary = stub_doc.find("<error")
    i_rerun = stub_doc.find("<rerunError")
    expect(
        0 <= i_primary < i_rerun,
        "the rerun-exhausted [attempts] row is not initial-primary chronology",
    )
    return "junit passes the junit-10 oracle: base + flaky (chronological) + rerun-exhausted (initial-primary)"


def s_junit_determinism(context: ScenarioContext) -> str:
    """Two repeated SEQUENTIAL `--junit-xml` runs of the same suite are equal
    under the JUnit CANONICAL form (`time` and embedded text masked; structure,
    identity, classification, and counts kept). Derived copies prove each mask is
    load-bearing without relying on incidental differences between real runs:
    changing a masked `time` or diagnostic body preserves canonical equality,
    while changing an unmasked classification attribute does not."""
    with tempfile.TemporaryDirectory(prefix="mtest-junit-determinism-") as tmp:
        first = Path(tmp) / "run1.xml"
        second = Path(tmp) / "run2.xml"
        time_mutation = Path(tmp) / "time.xml"
        text_mutation = Path(tmp) / "diagnostic.xml"
        classification_mutation = Path(tmp) / "classification.xml"

        first_run = context.runner.run_mtest(["e2e/suite", "--junit-xml", str(first)])
        second_run = context.runner.run_mtest(["e2e/suite", "--junit-xml", str(second)])
        expect_exit(first_run, 1)
        expect_exit(second_run, 1)
        # Both reports must EXIST before anything reads them. A run that exits
        # as expected having written no report is a product defect to report
        # with its exit code and stderr, not a FileNotFoundError to raise out of
        # the comparison below.
        expect_report(first_run, first, "the first determinism junit report")
        expect_report(second_run, second, "the second determinism junit report")
        junit_canonicalize.assert_equal_runs(first, second)

        raw = first.read_text(encoding="utf-8")
        canonical = junit_canonicalize.canonical_bytes(raw)

        time_root = ET.fromstring(raw)
        time_element = next(
            (element for element in time_root.iter() if "time" in element.attrib),
            None,
        )
        expect(time_element is not None, "the real JUnit report has no time attribute")
        time_element.set("time", "98765.432")
        ET.ElementTree(time_root).write(
            time_mutation, encoding="utf-8", xml_declaration=True
        )
        time_raw = time_mutation.read_text(encoding="utf-8")
        expect(time_raw != raw, "the time mutation did not change the raw report")
        expect(
            junit_canonicalize.canonical_bytes(time_raw) == canonical,
            "a masked time mutation changed the canonical JUnit form",
        )

        text_root = ET.fromstring(raw)
        masked_tags = {
            "system-out",
            "system-err",
            "failure",
            "error",
            "stackTrace",
            "flakyFailure",
            "flakyError",
            "rerunFailure",
            "rerunError",
        }
        text_element = next(
            (
                element
                for element in text_root.iter()
                if element.tag in masked_tags and element.text is not None
            ),
            None,
        )
        expect(text_element is not None, "the real JUnit report has no diagnostic text")
        text_element.text = (text_element.text or "") + "\nDETERMINISTIC-MUTATION\n"
        ET.ElementTree(text_root).write(
            text_mutation, encoding="utf-8", xml_declaration=True
        )
        text_raw = text_mutation.read_text(encoding="utf-8")
        expect(text_raw != raw, "the diagnostic mutation did not change the raw report")
        expect(
            junit_canonicalize.canonical_bytes(text_raw) == canonical,
            "a masked diagnostic mutation changed the canonical JUnit form",
        )

        classification_root = ET.fromstring(raw)
        classification_element = next(
            (
                element
                for element in classification_root.iter()
                if element.tag in {"failure", "error"}
                and "type" in element.attrib
            ),
            None,
        )
        expect(
            classification_element is not None,
            "the real JUnit report has no classified failure/error child",
        )
        classification_element.set(
            "type", classification_element.attrib["type"] + "-MUTATED"
        )
        ET.ElementTree(classification_root).write(
            classification_mutation, encoding="utf-8", xml_declaration=True
        )
        classification_raw = classification_mutation.read_text(encoding="utf-8")
        expect(
            classification_raw != raw,
            "the classification mutation did not change the raw report",
        )
        expect(
            junit_canonicalize.canonical_bytes(classification_raw) != canonical,
            "an unmasked classification mutation was lost from the canonical form",
        )
        return (
            "two sequential reports canonicalize equally; deterministic time/text "
            "mutations are masked and classification remains visible"
        )


def s_junit_prior_report_intact(context: ScenarioContext) -> str:
    """A finalization failure -> exit 3 AND the PRIOR report at PATH survives
    unmodified. Unlike `--json` (which truncates its destination at open), JUnit
    never touches PATH until the final atomic rename, so a doomed run leaves a
    previous report exactly as it was."""
    tmp = tempfile.mkdtemp()
    target = os.path.join(tmp, "report.xml")
    prior = "<PRIOR-REPORT>keep me</PRIOR-REPORT>\n"
    Path(target).write_text(prior)
    # Make the target directory unwritable so the unique temp cannot be created
    # at session start: a pre-run internal error (exit 3) that never opened PATH.
    os.chmod(tmp, 0o500)
    try:
        run = context.runner.run_mtest(["e2e/suite/test_passing.mojo", "--junit-xml", target])
        expect_exit(run, 3)
        expect(
            "internal error" in run.stderr.lower(),
            f"an unwritable junit target was not an internal error:\n{run.stderr}",
        )
        expect(
            Path(target).read_text() == prior,
            "the prior junit report at PATH was modified by a doomed run",
        )
    finally:
        os.chmod(tmp, 0o700)
    return "unwritable junit target -> exit 3 pre-run; the prior report survives byte-for-byte"


def s_junit_finalization_and_interrupt(context: ScenarioContext) -> str:
    """The finalize/exit-code agreement, with and without a run-time interrupt.

    (1) A junit target that fails at rename (an existing directory) escalates a
        finished run to exit 3; the co-composed `--json` stream's terminal record
        carries the SAME 3 — the two agree.
    (2) The SAME junit failure UNDER a run-time interrupt resolves to exit 2 on
        BOTH (interrupt dominates a finalization failure).
    (3) With a WRITABLE junit target, an interrupted run still PUBLISHES a report
        carrying a `[not-run]` skipped row for every file that never ran."""
    tmp = tempfile.mkdtemp()

    # (1) Undirectory junit target, no interrupt: json terminal 3, process 3.
    undir = os.path.join(tmp, "as_dir")
    os.makedirs(undir)
    stream1 = os.path.join(tmp, "s1.ndjson")
    run = context.runner.run_mtest(["e2e/suite", "--json", stream1, "--junit-xml", undir])
    expect_exit(run, 3)
    expect_report(run, stream1, "the co-composed --json stream")
    report1 = json_stream_check.parse_stream(Path(stream1).read_text())
    expect(
        report1.terminal is not None and report1.exit_code == 3,
        f"json terminal did not agree on exit 3: {report1.exit_code}",
    )

    # (2) Undirectory junit target + run-time interrupt: both say 2.
    stream2 = os.path.join(tmp, "s2.ndjson")
    code2, term2 = _run_and_interrupt(
        context,
        os.path.join(tmp, "arming-2"),
        ["--json", stream2, "--junit-xml", undir],
    )
    expect(code2 == 2, f"interrupt over a junit failure was not exit 2, got {code2}")
    expect(term2 == 2, f"json terminal under interrupt was not 2, got {term2}")

    # (3) Writable junit target + run-time interrupt: exit 2 AND the report
    # carries a `[not-run]` row for exactly the files that never ran.
    stream3 = os.path.join(tmp, "s3.ndjson")
    good = os.path.join(tmp, "interrupted.xml")
    code3, term3 = _run_and_interrupt(
        context,
        os.path.join(tmp, "arming-3"),
        ["--json", stream3, "--junit-xml", good],
    )
    expect(code3 == 2, f"interrupt with a writable junit target was not 2, got {code3}")
    expect(term3 == 2, f"json terminal was not 2 under interrupt, got {term3}")
    expect(os.path.exists(good), "the interrupted run published no junit report")
    junit_check.check_artifact(Path(good))
    rows = junit_not_run_files(good)
    expect(
        rows == SLOW_NOT_RUN_FILES,
        f"the interrupted run's junit named {rows} as not run, want "
        f"{SLOW_NOT_RUN_FILES}",
    )
    return (
        "junit/exit agreement: undirectory -> 3 (json agrees); +interrupt -> 2 "
        f"(both); writable+interrupt -> 2 with [not-run] rows for exactly "
        f"{len(SLOW_NOT_RUN_FILES)} files"
    )


def _run_and_interrupt(
    context: ScenarioContext, arming_dir: str, args: list[str]
) -> tuple[int, int | None]:
    """Walk the slow tree to its armed blocked child, SIGINT mtest, and report.

    The signal goes to the mtest leader only, once one file has PASSED and the
    next child has announced that it is blocked — never on a wall-clock guess.
    Each call owns a FRESH arming directory, so a marker one call left behind can
    never satisfy the next call's barrier.

    Args:
        context: The scenario context.
        arming_dir: A directory this call creates and owns for its markers.
        args: The mtest arguments after the slow tree, including `--json PATH`.

    Returns:
        The process exit code and the `--json` terminal record's exit code.

    Raises:
        ScenarioError: If the barrier expires or the run wrote no stream.
    """
    os.makedirs(arming_dir)
    arming = arm_slow_tree(arming_dir)
    stream_path = args[args.index("--json") + 1]
    run, _pgid = context.runner.run_mtest_signaled(
        [SLOW_TREE, *args],
        signal_number=signal.SIGINT,
        timeout=INTERRUPT_TIMEOUT,
        ready_files=arming.ready_files,
        owned_pgid_files=arming.owned_pgid_files,
        env_overrides=arming.env,
    )
    term_code: int | None = None
    expect(
        os.path.exists(stream_path),
        f"the interrupted run wrote no --json stream at {stream_path} (exit "
        f"{run.returncode}) — there is no terminal record to recover",
    )
    text = Path(stream_path).read_text()
    if text:
        report = json_stream_check.parse_stream(text)
        if report.terminal is not None:
            term_code = report.exit_code
    return run.returncode, term_code
