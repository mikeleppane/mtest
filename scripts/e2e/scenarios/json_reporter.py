"""JSON reporter and terminal-delivery E2E scenarios."""

from __future__ import annotations

import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from scripts.checks.reports import json_stream as json_stream_check
from scripts.e2e.assertions import SUMMARY_RE, expect, expect_exit
from scripts.e2e.runner import (
    DEFAULT_TIMEOUT,
    E2ERunner,
    JSON_TERMINAL_WRITE_FAULT,
    REPO_ROOT,
    SHORT_TIMEOUT,
    ScenarioContext,
    ScenarioError,
)


def _looks_like_stream_line(line: str) -> bool:
    """Whether a line is an NDJSON event record (starts a JSON object)."""
    return line.startswith('{"event":')


def s_json_forward_compat(context: ScenarioContext) -> str:
    """The strict consumer is the ORACLE, and it honors the ignore-unknowns
    obligation: a forward-compat fixture with unknown fields AND an unknown event
    kind is ACCEPTED, a torn tail is classified as truncation (not corruption),
    and a corrupt committed line / duplicate key / non-finite token is REJECTED.
    Runs the consumer's own fixture self-test so the versioning contract is gated.
    """
    rc = json_stream_check.main(["json_stream_check.py"])
    expect(rc == 0, "the strict-consumer fixture self-test failed")
    # Independently reconfirm the ignore-unknowns acceptance here.
    fc = (json_stream_check.FIXTURE_DIR / "forward_compat.ndjson").read_text()
    report = json_stream_check.parse_stream(fc)
    expect(report.version == 1, "forward-compat header version was not 1")
    expect(report.terminal is not None, "forward-compat terminal was dropped")
    expect(
        any(r.get("event") == "quantum_flux" for r in report.records),
        "the unknown event kind was not accepted by the strict consumer",
    )
    return "strict consumer accepts unknown fields+kinds; rejects corruption"


def s_json_purity(context: ScenarioContext) -> str:
    """`--json -` makes stdout the BYTE-PURE event stream and relocates the whole
    console to stderr. Every stdout byte is a stream line the strict consumer
    accepts (header first, exactly one terminal, exit_code == the real exit); the
    human summary band lives on stderr, and NOT one stream line leaks to stderr
    nor one console byte to stdout."""
    run = context.runner.run_mtest(["e2e/suite", "--json", "-", "--gh-annotations", "off"])
    # stdout is the stream: strictly consumable, header + single terminal.
    report = json_stream_check.parse_stream(run.stdout)
    expect(report.version == 1, "stream header version was not 1 on stdout")
    expect(report.terminal is not None, "stream carried no terminal record")
    expect(
        report.exit_code == run.returncode,
        f"terminal exit_code {report.exit_code} != process exit {run.returncode}",
    )
    expect(not report.torn_tail, "a completed run's stream must not be torn")
    # PURITY: stdout carries ONLY stream lines (no human summary band).
    expect(
        SUMMARY_RE.search(run.stdout) is None,
        "the human summary band leaked onto the byte-pure stream (stdout)",
    )
    # The console relocated WHOLE to stderr: the summary band is there.
    expect(
        SUMMARY_RE.search(run.stderr) is not None,
        f"the console summary band is not on stderr under --json -:\n{run.stderr}",
    )
    # No stream line leaked to stderr.
    stray = [ln for ln in run.stderr.splitlines() if _looks_like_stream_line(ln)]
    expect(not stray, f"stream lines leaked onto stderr (console fd): {stray[:2]}")
    return f"stdout byte-pure ({report.line_count if hasattr(report,'line_count') else len(report.records)} records); console on stderr; exit {run.returncode}"


def s_json_color_on_relocated_stderr(context: ScenarioContext) -> str:
    """`--color auto` decides against the console's RESOLVED destination. Under
    `--json -` with stdout PIPED (never a tty) and stderr on a real PTY, the
    console lives on stderr, so color renders on STDERR (the tty-probe's
    PTY-positive oracle) while the byte-pure stream on stdout stays free of ANSI.
    """
    _returncode, stream_bytes, console_bytes = context.runner.run_mtest_split_pty(
        [
            "e2e/suite/test_failing.mojo",
            "--json",
            "-",
            "--gh-annotations",
            "off",
            "--color",
            "auto",
        ],
        env_overrides={"NO_COLOR": None, "GITHUB_ACTIONS": ""},
        timeout=SHORT_TIMEOUT,
    )
    esc = b"\x1b["
    expect(
        esc in console_bytes,
        "no ANSI color on the relocated stderr console under --color auto + a "
        "stderr PTY (the stderr tty-probe positive case regressed)",
    )
    expect(
        esc not in stream_bytes,
        "ANSI color leaked onto the byte-pure --json - stream (stdout)",
    )
    # The stream is still strictly consumable (decoded lenient of the final tail).
    report = json_stream_check.parse_stream(
        stream_bytes.decode("utf-8", "replace")
    )
    expect(report.version == 1, "the stream header regressed under the color case")
    return "color renders on the relocated stderr; stream on stdout stays ANSI-free"


def s_json_destination_taxonomy(context: ScenarioContext) -> str:
    """The destination taxonomy split. A SYNTACTIC badness is a parse-time usage
    error (exit 4) BEFORE any build: an empty value, and a nonexistent parent
    directory. A RUNTIME open failure (the path is an existing directory, so
    open fails EISDIR at session start) is a pre-run internal error (exit 3)."""
    empty = context.runner.run_mtest(["e2e/suite", "--json", ""])
    expect_exit(empty, 4)
    expect(
        "--json" in empty.stderr,
        f"empty --json value did not name the flag:\n{empty.stderr}",
    )
    bad_parent = context.runner.run_mtest(["e2e/suite", "--json", "/no/such/dir/out.ndjson"])
    expect_exit(bad_parent, 4)
    # Exit 4 is decided BEFORE any build: no verdict/summary band was produced.
    expect(
        SUMMARY_RE.search(bad_parent.stdout + bad_parent.stderr) is None,
        "a syntactic --json usage error ran the session instead of failing pre-run",
    )
    # Runtime open failure: an existing directory as the destination -> EISDIR.
    runtime = context.runner.run_mtest(["e2e/suite/test_passing.mojo", "--json", "e2e"])
    expect_exit(runtime, 3)
    expect(
        "internal error" in runtime.stderr.lower(),
        f"a runtime --json open failure was not an internal error:\n{runtime.stderr}",
    )
    return "empty->4, bad-parent->4 (pre-build), existing-dir open->3 (session-start)"


def s_json_truncation_interrupt(context: ScenarioContext) -> str:
    """Truncation trio (1/3): an INTERRUPTED run ends the stream WITH its terminal
    record and exit_code 2. The session fires SessionFinished on interrupt; the
    file destination is alive, so the terminal record is committed."""
    stream_path = os.path.join(tempfile.mkdtemp(), "interrupt.ndjson")
    run, _pgid = context.runner.run_mtest_signaled(
        ["e2e/slow", "--json", stream_path],
        signal_number=signal.SIGINT,
        delay=8.0,
        timeout=60.0,
    )
    expect(run.returncode == 2, f"expected exit 2 on interrupt, got {run.returncode}")
    text = Path(stream_path).read_text()
    report = json_stream_check.parse_stream(text)
    expect(report.terminal is not None, "interrupted stream carried no terminal record")
    expect(
        report.exit_code == 2,
        f"interrupted terminal exit_code was {report.exit_code}, want 2",
    )
    return "interrupt: stream ends WITH terminal record, exit_code 2"


def s_json_truncation_sigkill(context: ScenarioContext) -> str:
    """Truncation trio (2/3): a SIGKILLed mtest leaves COMPLETE lines and at most
    one torn tail — never corruption — and NO terminal record. The absence of the
    terminal is the truncation signal."""
    stream_path = os.path.join(tempfile.mkdtemp(), "sigkill.ndjson")
    context.runner.run_mtest_signaled(
        ["e2e/slow", "--json", stream_path],
        signal_number=signal.SIGKILL,
        delay=8.0,
        timeout=38.0,
    )
    text = Path(stream_path).read_text()
    # parse_stream RAISES on corruption; a clean parse proves complete lines +
    # at most one torn tail.
    report = json_stream_check.parse_stream(text)
    expect(
        report.terminal is None,
        "a SIGKILLed run produced a terminal record — it could not have finalized",
    )
    return "sigkill: complete lines + at most one torn tail; no terminal record"


def s_json_truncation_dead_pipe(context: ScenarioContext) -> str:
    """Truncation trio (3/3): `mtest --json - | head` — a consumer that closes the
    pipe early. SIGPIPE is ignored, so the reporter's write returns EPIPE and
    latches a FATAL ABORT: mtest neither dies at 141 nor runs to completion — it
    exits 3, with no orphaned children. What the reader DID get is complete lines
    plus at most one torn tail."""
    returncode, got, pgid = context.runner.run_mtest_dead_pipe(
        ["e2e/suite", "--json", "-", "--gh-annotations", "off"],
        read_size=64,
        timeout=DEFAULT_TIMEOUT,
    )
    expect(
        returncode == 3,
        f"a dead --json - pipe must be a fatal abort exit 3, got "
        f"{returncode} (141 would mean SIGPIPE was NOT ignored)",
    )
    # What the reader received parses as complete lines + at most one torn tail.
    json_stream_check.parse_stream(got.decode("utf-8", "replace"), require_header=False)
    # No orphaned process group.
    time.sleep(0.5)
    orphan = True
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        orphan = False
    expect(not orphan, f"process group {pgid} still alive after fatal abort (orphan)")
    return "dead pipe: fatal abort exit 3 (not 141), no orphan, clean partial stream"


def _json_terminal_write_fault_commands(
    directory: str,
    compiler: str,
    *,
    platform: str = sys.platform,
    platform_driver: str = "/usr/bin/cc",
) -> tuple[str, list[tuple[str, list[str]]]]:
    """Return the target-specific interposer output and ordered build steps."""
    object_path = os.path.join(directory, "mtest_json_terminal_fault.o")
    compile_command = [
        compiler,
        "-std=c17",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-Wpedantic",
        "-fPIC",
        "-c",
        JSON_TERMINAL_WRITE_FAULT,
        "-o",
        object_path,
    ]
    if platform == "darwin":
        library = os.path.join(directory, "libmtest_json_terminal_fault.dylib")
        link_command = [
            platform_driver,
            "-dynamiclib",
            object_path,
            "-o",
            library,
        ]
    else:
        library = os.path.join(directory, "libmtest_json_terminal_fault.so")
        link_command = [
            compiler,
            "-shared",
            object_path,
            "-o",
            library,
            "-ldl",
        ]
    return library, [("compile", compile_command), ("link", link_command)]


def _build_json_terminal_write_fault(
    directory: str,
    *,
    platform: str = sys.platform,
    compiler: str | None = None,
    platform_driver: str = "/usr/bin/cc",
) -> str:
    """Build the test-only terminal-record write interposer in `directory`."""
    selected_compiler = compiler or os.environ.get("CC", "clang")
    library, steps = _json_terminal_write_fault_commands(
        directory,
        selected_compiler,
        platform=platform,
        platform_driver=platform_driver,
    )
    for step, argv in steps:
        proc = subprocess.Popen(
            argv,
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
        try:
            output, _ = proc.communicate(timeout=SHORT_TIMEOUT)
        except subprocess.TimeoutExpired:
            E2ERunner.kill_group(proc)
            output, _ = proc.communicate()
            raise ScenarioError(
                f"the JSON terminal-write fault interposer did not {step} within "
                f"{SHORT_TIMEOUT}s:\n{output}"
            )
        expect(
            proc.returncode == 0,
            f"could not {step} the JSON terminal-write fault interposer "
            f"({proc.returncode}):\n{output}",
        )
    return library


def s_json_terminal_write_failure(context: ScenarioContext) -> str:
    """A deterministic terminal-record write failure escalates clean 0 to 3.

    A test-only dynamic-library interposer rejects only the real CLI's write
    containing the exact `session_finished` event marker. Every earlier write
    reaches a normal file destination, so the stream proves a clean PASS through
    `file_finished`, then loses only its terminal record. The process exit is the
    out-of-band truth for that final delivery failure.
    """
    rel = "e2e/suite/test_passing.mojo"
    with tempfile.TemporaryDirectory(prefix="mtest-json-terminal-fault-") as tmp:
        stream_path = os.path.join(tmp, "stream.ndjson")
        library = _build_json_terminal_write_fault(tmp)
        if sys.platform == "darwin":
            loader_variable = "DYLD_INSERT_LIBRARIES"
        else:
            loader_variable = "LD_PRELOAD"
        inherited_preloads = os.environ.get(loader_variable, "")
        preload_value = library + (
            os.pathsep + inherited_preloads if inherited_preloads else ""
        )
        run = context.runner.run_mtest(
            [rel, "--json", stream_path, "--gh-annotations", "off"],
            timeout=DEFAULT_TIMEOUT,
            env_overrides={loader_variable: preload_value},
        )
        expect(
            run.returncode == 3,
            f"a terminal-record write failure after a clean all-pass run must "
            f"escalate 0 -> 3, got {run.returncode}\n"
            f"--- stdout ---\n{run.stdout}\n--- stderr ---\n{run.stderr}",
        )
        expect(
            os.path.exists(stream_path),
            f"the run wrote no --json stream at {stream_path} (exit "
            f"{run.returncode}) — there is no terminal-record delivery to judge"
            f"\n--- stdout ---\n{run.stdout}\n--- stderr ---\n{run.stderr}",
        )
        text = Path(stream_path).read_text(encoding="utf-8")
        report = json_stream_check.parse_stream(text)
        expect(report.terminal is None, "the rejected terminal record reached the stream")
        file_finishes = [
            record
            for record in report.records
            if record.get("event") == "file_finished"
        ]
        event_names = [record.get("event") for record in report.records]
        expect(
            len(file_finishes) == 1,
            f"expected one committed pre-terminal file_finished record, got "
            f"{len(file_finishes)}\n"
            f"events={event_names!r} torn_tail={report.torn_tail}\n"
            f"--- stream ---\n{text}\n"
            f"--- stdout ---\n{run.stdout}\n--- stderr ---\n{run.stderr}",
        )
        expect(
            file_finishes[0].get("path") == rel
            and file_finishes[0].get("outcome") == "pass",
            f"pre-terminal file result was not the clean PASS: {file_finishes[0]}",
        )
        expect(not report.torn_tail, "the deterministic failure left a torn JSON tail")
        time.sleep(0.5)
        orphan = True
        assert run.pgid is not None
        try:
            os.killpg(run.pgid, 0)
        except ProcessLookupError:
            orphan = False
        expect(
            not orphan,
            f"process group {run.pgid} still alive after terminal-write abort (orphan)",
        )
        return "terminal write fault: clean PASS escalates 0 -> 3, no orphan"
