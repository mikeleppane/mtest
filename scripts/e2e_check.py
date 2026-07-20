#!/usr/bin/env python3
"""End-to-end gate for mtest.

Runs the real `build/mtest` binary against the committed known-outcome tree under
e2e/ and asserts, for a table of scenarios, the EXACT exit code and the
STRUCTURE of the console output (verdict tokens, root-relative paths, summary
count arithmetic, framing presence/absence, error messages). Console layout is an
informal surface, so nothing here is byte-golden: it asserts tokens and counts,
never exact bytes.

Expectations come from e2e/manifest.json — the single source of truth. This
script consumes it directly and checks completeness both ways: every discovered
test_*.mojo file has a manifest row, and every manifest row names a file that
exists. There is no parallel hard-coded expectations table.

Safety: every subprocess spawn has a hard wall-clock timeout and runs in its own
process group, so a runner bug can never hang the gate. The only fixture that
never returns (e2e/slow/test_hanging.mojo) is reached solely by the
--timeout scenario (which mtest bounds) and the interrupt scenario (which sends
SIGINT under a kill-guard).

The binary spawns `mojo build` per file, so `mojo` must be on the child's PATH.
This harness NEVER scrubs the environment: it passes the inherited environment
straight through, and the `e2e` pixi task runs it under `pixi run`, so the pixi
toolchain (with mojo on PATH) is inherited by build/mtest and its build children.

Usage:  pixi run e2e        (builds the binary first, then runs this)
        python -m scripts.e2e_check
"""

from __future__ import annotations

import inspect
import os
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from xml.etree import ElementTree as ET

from scripts.checks.reports import annotations as annotations_check
from scripts.checks.reports import json_stream as json_stream_check
from scripts.checks.reports import junit as junit_check
from scripts.checks.reports import junit_canonicalize
from scripts.e2e import main_open as main_open_check
from scripts.e2e.scenarios import core, resilience, selection
from scripts.e2e.assertions import (
    SUMMARY_RE,
    VERDICT_TO_BUCKET,
    expect,
    expect_accounting,
    expect_exit,
    expect_report,
    summary,
    verdict_line,
    verdict_paths_in_order,
)
from scripts.e2e.runner import (
    DEFAULT_RUNNER,
    E2E_ROOT,
    FAKE_CRASH_MOJO,
    FAKE_RETRY_CRASH_MOJO,
    FAKE_SLOW_MOJO,
    JSON_TERMINAL_WRITE_FAULT,
    LOGGING_MOJO,
    MTEST,
    REPO_ROOT,
    SHORT_TIMEOUT,
    DEFAULT_TIMEOUT,
    Run,
    Scenario,
    ScenarioContext,
    ScenarioError,
    ScenarioRegistry,
    bootstrap_build_bin,
    discovered_test_files,
    load_manifest,
)

run_mtest = DEFAULT_RUNNER.run_mtest
run_mtest_pty = DEFAULT_RUNNER.run_mtest_pty
_kill_group = DEFAULT_RUNNER.kill_group
_bootstrap_build_bin = bootstrap_build_bin


@dataclass
class Harness:
    context: ScenarioContext
    results: list[tuple[str, bool, str]] = field(default_factory=list)

    def scenario(self, name: str, fn: Scenario) -> None:
        try:
            detail = fn(self.context)
            self.results.append((name, True, detail or ""))
            print(f"PASS  {name}  {detail or ''}")
        except ScenarioError as exc:
            self.results.append((name, False, str(exc)))
            print(f"FAIL  {name}\n      {exc}")
        except Exception as exc:
            # CONTAINMENT. ScenarioError above is the EXPECTED failure channel;
            # anything else — an OSError from a lost race against a child
            # process, a FileNotFoundError on an artifact a run never wrote, a
            # plain bug in the scenario — used to escape `main` as a traceback
            # and tear the gate down mid-table. Every scenario registered AFTER
            # the offender then never ran, and its silence read as coverage:
            # that is how a real defect in a late scenario's subject can hide
            # behind an early scenario's crash. Contained here it is still a
            # real FAILURE (`ok()` is False, `main` returns 1) — nothing is
            # swallowed into a PASS — and the traceback is kept verbatim as the
            # detail so the cause stays diagnosable. KeyboardInterrupt and
            # SystemExit derive from BaseException, so an operator's Ctrl-C and
            # a deliberate exit still stop the gate immediately.
            #
            # The label states only what is known — that an exception escaped
            # by a path other than the expected one. It deliberately does NOT
            # blame the harness: an OSError while reaping a child, or a missing
            # artifact a run was supposed to write, is frequently caused BY
            # mtest, and pre-assigning the fault here would misdirect triage.
            # The traceback below is the evidence; read it before concluding.
            detail = (
                f"{type(exc).__name__} escaped the scenario outside the "
                f"expected ScenarioError channel — cause undetermined, see the "
                f"traceback:\n"
                f"{traceback.format_exc()}"
            )
            self.results.append((name, False, detail))
            print(f"FAIL  {name}\n      {detail}")

    def ok(self) -> bool:
        return all(passed for _n, passed, _d in self.results)






# Every kill/timeout/crash class this build serves, mapped to the registered
# scenario that drives it end-to-end. `s_resilience_matrix` checks this table
# BOTH WAYS against SCENARIOS, the way `s_manifest_completeness` checks the
# manifest against the tree — so a class whose scenario is silently dropped, and
# a new resilience scenario nobody classified, both go RED.
#
# Two rows share `precompile-crash-retry`: the classifier gives the build and
# precompile steps the SAME rules, and the precompile step is where a compiler's
# death BY SIGNAL is driven. No scenario kills a `build` step with a signal —
# that rule is exercised one step over, not directly.

# A scenario that reaches for one of the kill/timeout/crash `--mojo` stand-ins is
# a resilience scenario by construction, and must therefore be named by the
# matrix above. Matched against each scenario's SOURCE, so the reverse check
# needs no second hand-maintained list to drift out of step.
















































# A slowest-files row: two leading spaces, the path, then a trailing "N.NNs".
















































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
    run = run_mtest(["e2e/suite", "--json", "-", "--gh-annotations", "off"])
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
    if not os.path.exists(MTEST):
        raise ScenarioError(f"binary not found at {MTEST}; run `pixi run build-bin`")
    argv = [MTEST, "e2e/suite/test_failing.mojo", "--json", "-", "--gh-annotations", "off", "--color", "auto"]
    stdout_r, stdout_w = os.pipe()
    master_fd, slave_fd = pty.openpty()
    env = dict(os.environ)
    env.pop("NO_COLOR", None)  # AUTO must be free to colorize a tty
    env["GITHUB_ACTIONS"] = ""  # keep fencing out of this color assertion
    proc = subprocess.Popen(
        argv,
        cwd=REPO_ROOT,
        stdout=stdout_w,
        stderr=slave_fd,
        env=env,
        start_new_session=True,
    )
    os.close(stdout_w)
    os.close(slave_fd)
    stream_bytes = bytearray()
    console_bytes = bytearray()
    deadline = time.monotonic() + SHORT_TIMEOUT
    open_fds = {stdout_r, master_fd}
    try:
        while open_fds:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _kill_group(proc)
                raise ScenarioError("color-pty scenario timed out")
            ready, _, _ = select.select(list(open_fds), [], [], remaining)
            for fd in ready:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    chunk = b""
                if not chunk:
                    open_fds.discard(fd)
                    continue
                (stream_bytes if fd == stdout_r else console_bytes).extend(chunk)
    finally:
        os.close(stdout_r)
        os.close(master_fd)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            _kill_group(proc)
            proc.wait(timeout=5)
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
    empty = run_mtest(["e2e/suite", "--json", ""])
    expect_exit(empty, 4)
    expect(
        "--json" in empty.stderr,
        f"empty --json value did not name the flag:\n{empty.stderr}",
    )
    bad_parent = run_mtest(["e2e/suite", "--json", "/no/such/dir/out.ndjson"])
    expect_exit(bad_parent, 4)
    # Exit 4 is decided BEFORE any build: no verdict/summary band was produced.
    expect(
        SUMMARY_RE.search(bad_parent.stdout + bad_parent.stderr) is None,
        "a syntactic --json usage error ran the session instead of failing pre-run",
    )
    # Runtime open failure: an existing directory as the destination -> EISDIR.
    runtime = run_mtest(["e2e/suite/test_passing.mojo", "--json", "e2e"])
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
    argv = [MTEST, "e2e/slow", "--json", stream_path]
    proc = subprocess.Popen(
        argv, cwd=REPO_ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, start_new_session=True,
    )
    pgid = os.getpgid(proc.pid)
    try:
        time.sleep(8.0)
        expect(proc.poll() is None, "mtest exited before it could be interrupted")
        os.killpg(pgid, signal.SIGINT)
        try:
            proc.communicate(timeout=60.0)
        except subprocess.TimeoutExpired:
            _kill_group(proc)
            proc.communicate()
            raise ScenarioError("mtest did not exit within the guard after SIGINT")
    finally:
        if proc.poll() is None:
            _kill_group(proc)
    expect(proc.returncode == 2, f"expected exit 2 on interrupt, got {proc.returncode}")
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
    argv = [MTEST, "e2e/slow", "--json", stream_path]
    proc = subprocess.Popen(
        argv, cwd=REPO_ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, start_new_session=True,
    )
    pgid = os.getpgid(proc.pid)
    try:
        time.sleep(8.0)
        expect(proc.poll() is None, "mtest exited before it could be killed")
        os.killpg(pgid, signal.SIGKILL)
        proc.communicate(timeout=30.0)
    finally:
        if proc.poll() is None:
            _kill_group(proc)
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
    if not os.path.exists(MTEST):
        raise ScenarioError(f"binary not found at {MTEST}; run `pixi run build-bin`")
    argv = [MTEST, "e2e/suite", "--json", "-", "--gh-annotations", "off"]
    proc = subprocess.Popen(
        argv, cwd=REPO_ROOT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    pgid = os.getpgid(proc.pid)
    got = bytearray()
    try:
        # Read a little (the header block), then close the read end — a `head`.
        assert proc.stdout is not None
        got.extend(proc.stdout.read(64))
        proc.stdout.close()
        try:
            proc.wait(timeout=DEFAULT_TIMEOUT)
        except subprocess.TimeoutExpired:
            _kill_group(proc)
            proc.wait()
            raise ScenarioError("mtest did not exit after its stream pipe closed")
    finally:
        if proc.poll() is None:
            _kill_group(proc)
    expect(
        proc.returncode == 3,
        f"a dead --json - pipe must be a fatal abort exit 3, got "
        f"{proc.returncode} (141 would mean SIGPIPE was NOT ignored)",
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
            _kill_group(proc)
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
    if not os.path.exists(MTEST):
        raise ScenarioError(f"binary not found at {MTEST}; run `pixi run build-bin`")
    rel = "e2e/suite/test_passing.mojo"
    with tempfile.TemporaryDirectory(prefix="mtest-json-terminal-fault-") as tmp:
        stream_path = os.path.join(tmp, "stream.ndjson")
        library = _build_json_terminal_write_fault(tmp)
        argv = [MTEST, rel, "--json", stream_path, "--gh-annotations", "off"]
        env = dict(os.environ)
        env["GITHUB_ACTIONS"] = ""
        if sys.platform == "darwin":
            loader_variable = "DYLD_INSERT_LIBRARIES"
        else:
            loader_variable = "LD_PRELOAD"
        inherited_preloads = env.get(loader_variable, "")
        env[loader_variable] = library + (
            os.pathsep + inherited_preloads if inherited_preloads else ""
        )
        proc = subprocess.Popen(
            argv,
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
            env=env,
        )
        pgid = os.getpgid(proc.pid)
        try:
            stdout, stderr = proc.communicate(timeout=DEFAULT_TIMEOUT)
        except subprocess.TimeoutExpired:
            _kill_group(proc)
            stdout, stderr = proc.communicate()
            raise ScenarioError(
                "mtest did not exit after the injected terminal-record write "
                f"failure:\n--- stdout ---\n{stdout}\n--- stderr ---\n{stderr}"
            )
        finally:
            if proc.poll() is None:
                _kill_group(proc)
        expect(
            proc.returncode == 3,
            f"a terminal-record write failure after a clean all-pass run must "
            f"escalate 0 -> 3, got {proc.returncode}\n"
            f"--- stdout ---\n{stdout}\n--- stderr ---\n{stderr}",
        )
        expect(
            os.path.exists(stream_path),
            f"the run wrote no --json stream at {stream_path} (exit "
            f"{proc.returncode}) — there is no terminal-record delivery to judge"
            f"\n--- stdout ---\n{stdout}\n--- stderr ---\n{stderr}",
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
            f"--- stdout ---\n{stdout}\n--- stderr ---\n{stderr}",
        )
        expect(
            file_finishes[0].get("path") == rel
            and file_finishes[0].get("outcome") == "pass",
            f"pre-terminal file result was not the clean PASS: {file_finishes[0]}",
        )
        expect(not report.torn_tail, "the deterministic failure left a torn JSON tail")
        time.sleep(0.5)
        orphan = True
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            orphan = False
        expect(
            not orphan,
            f"process group {pgid} still alive after terminal-write abort (orphan)",
        )
        return "terminal write fault: clean PASS escalates 0 -> 3, no orphan"


def s_junit_scratch_cleanup(context: ScenarioContext) -> str:
    """A `--junit-xml` run leaves no spool directory behind. `main` owns the
    `mkdtemp` scratch it creates for per-suite fragments and frees it on exit;
    a busy /tmp would otherwise accrete one leaked directory (plus a fragment)
    per invocation, and eventually a `mkdtemp` failure before tests even run."""
    report_dir = tempfile.mkdtemp()
    tmpdir = tempfile.mkdtemp()  # the isolated TMPDIR the run's mkdtemp lands in
    try:
        report_path = os.path.join(report_dir, "report.xml")
        run = run_mtest(
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
    run = run_mtest(["e2e/suite", "--junit-xml", suite_path])
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
    frun = run_mtest(
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
    srun = run_mtest(
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

        first_run = run_mtest(["e2e/suite", "--junit-xml", str(first)])
        second_run = run_mtest(["e2e/suite", "--junit-xml", str(second)])
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
        run = run_mtest(["e2e/suite/test_passing.mojo", "--junit-xml", target])
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
    run = run_mtest(["e2e/suite", "--json", stream1, "--junit-xml", undir])
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
        ["e2e/slow", "--json", stream2, "--junit-xml", undir]
    )
    expect(code2 == 2, f"interrupt over a junit failure was not exit 2, got {code2}")
    expect(term2 == 2, f"json terminal under interrupt was not 2, got {term2}")

    # (3) Writable junit target + run-time interrupt: exit 2 AND the report
    # carries [not-run] rows for the files that never ran.
    stream3 = os.path.join(tmp, "s3.ndjson")
    good = os.path.join(tmp, "interrupted.xml")
    code3, term3 = _run_and_interrupt(
        ["e2e/slow", "--json", stream3, "--junit-xml", good]
    )
    expect(code3 == 2, f"interrupt with a writable junit target was not 2, got {code3}")
    expect(term3 == 2, f"json terminal was not 2 under interrupt, got {term3}")
    expect(os.path.exists(good), "the interrupted run published no junit report")
    junit_check.check_artifact(Path(good))
    expect(
        "[not-run]" in Path(good).read_text(),
        "the interrupted run's junit carries no [not-run] rows for un-run files",
    )
    return "junit/exit agreement: undirectory -> 3 (json agrees); +interrupt -> 2 (both); writable+interrupt -> 2 with [not-run] rows"


def _run_and_interrupt(args: list[str]) -> tuple[int, int | None]:
    """Spawn `mtest args` over the slow tree, SIGINT its group mid-run, and
    return (process exit code, json terminal exit_code). The `--json` stream is
    read back to recover the terminal record the run committed on interrupt."""
    stream_path = args[args.index("--json") + 1]
    proc = subprocess.Popen(
        [MTEST, *args],
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    pgid = os.getpgid(proc.pid)
    try:
        time.sleep(8.0)
        expect(proc.poll() is None, "mtest exited before it could be interrupted")
        os.killpg(pgid, signal.SIGINT)
        try:
            proc.communicate(timeout=60.0)
        except subprocess.TimeoutExpired:
            _kill_group(proc)
            proc.communicate()
            raise ScenarioError("mtest did not exit within the guard after SIGINT")
    finally:
        if proc.poll() is None:
            _kill_group(proc)
    term_code: int | None = None
    expect(
        os.path.exists(stream_path),
        f"the interrupted run wrote no --json stream at {stream_path} (exit "
        f"{proc.returncode}) — there is no terminal record to recover",
    )
    text = Path(stream_path).read_text()
    if text:
        report = json_stream_check.parse_stream(text)
        if report.terminal is not None:
            term_code = report.exit_code
    return proc.returncode, term_code


# The scenario table, in run order. The single source of truth for what the gate
# runs: `main` dispatches over it and `s_resilience_matrix` checks the kill/
# timeout/crash coverage table against it, so a scenario can never be classified
# by the matrix yet quietly left unregistered (or vice versa).
def _annotation_lines(stdout: str) -> list[str]:
    """mtest's OWN annotation tail: annotation lines outside every fence."""
    return annotations_check.annotation_tail_outside_fences(stdout)


def s_annotations_modes(context: ScenarioContext) -> str:
    """MODE resolution: `on` always renders the tail; `auto` follows
    GITHUB_ACTIONS; `off` never renders even under Actions.

    The tail is the node-id-sorted `::error` block then the single `::notice`,
    printed to stdout AFTER the console summary band, only when resolved-on."""
    fail = "e2e/annotations/test_many_fail.mojo"

    # `on`: the tail renders regardless of GITHUB_ACTIONS.
    run = run_mtest([fail, "--gh-annotations", "on"])
    expect_exit(run, 1)
    tail = _annotation_lines(run.stdout)
    annotations_check.check_tail(tail)
    expect(any(a.startswith("::notice::") for a in tail), "on: no ::notice tail")
    expect(any(a.startswith("::error ") for a in tail), "on: no ::error tail")

    # `auto` OUTSIDE Actions: nothing annotation-shaped on stdout.
    run = run_mtest(
        [fail, "--gh-annotations", "auto"],
        env_overrides={"GITHUB_ACTIONS": ""},
    )
    expect_exit(run, 1)
    expect(
        not _annotation_lines(run.stdout),
        f"auto outside Actions still emitted a tail:\n{run.stdout}",
    )

    # `auto` INSIDE Actions: the tail renders.
    run = run_mtest(
        [fail, "--gh-annotations", "auto"],
        env_overrides={"GITHUB_ACTIONS": "true"},
    )
    expect_exit(run, 1)
    expect(
        any(a.startswith("::notice::") for a in _annotation_lines(run.stdout)),
        "auto inside Actions rendered no tail",
    )

    # `off` even INSIDE Actions: never a tail.
    run = run_mtest(
        [fail, "--gh-annotations", "off"],
        env_overrides={"GITHUB_ACTIONS": "true"},
    )
    expect_exit(run, 1)
    expect(
        not _annotation_lines(run.stdout),
        f"off under Actions still emitted a tail:\n{run.stdout}",
    )
    return "on renders; auto follows GITHUB_ACTIONS; off never renders"


def s_annotations_caps(context: ScenarioContext) -> str:
    """The 10-error per-STEP cap: twelve failures render nine node-id-sorted
    rows plus ONE `... and 3 more errors` aggregate — never eleven lines."""
    run = run_mtest(
        ["e2e/annotations/test_many_fail.mojo", "--gh-annotations", "on"]
    )
    expect_exit(run, 1)
    tail = _annotation_lines(run.stdout)
    annotations_check.check_tail(tail)
    errors = [a for a in tail if a.startswith("::error")]
    expect(
        len(errors) == 10,
        f"error block was not capped at 10 lines: {len(errors)}",
    )
    expect(
        any("... and 3 more errors" in a for a in errors),
        f"no cap-minus-one aggregate line:\n{chr(10).join(errors)}",
    )
    return "12 failures -> 9 rows + '... and 3 more errors' (10 lines, capped)"


def s_annotations_conflict(context: ScenarioContext) -> str:
    """The `--json -` conflict rule, BOTH endings plus the one that runs.

    `--json - --gh-annotations on` and the default `auto` beside `--json -` are
    each usage errors (exit 4) naming both fixes; only explicit `off` runs, and
    then stdout is the byte-pure stream with no annotation line."""
    # (1) explicit `on` conflicts: exit 4, message names both fixes.
    run = run_mtest(["e2e/suite", "--json", "-", "--gh-annotations", "on"])
    expect_exit(run, 4)
    expect(
        "gh-annotations off" in run.stderr and "--json PATH" in run.stderr,
        f"the on-conflict message names neither fix:\n{run.stderr}",
    )

    # (2) the DEFAULT (auto) also conflicts with `--json -`: exit 4.
    run = run_mtest(["e2e/suite", "--json", "-"])
    expect_exit(run, 4)
    expect(
        "gh-annotations off" in run.stderr,
        f"the auto-conflict message names no fix:\n{run.stderr}",
    )

    # (3) explicit `off` is the ONLY combination that runs beside `--json -`.
    run = run_mtest(
        ["e2e/suite", "--json", "-", "--gh-annotations", "off"]
    )
    expect(run.returncode in (0, 1), f"off+--json - did not run: {run.returncode}")
    expect(
        not _annotation_lines(run.stdout),
        "the byte-pure stream carried an annotation line",
    )
    report = json_stream_check.parse_stream(run.stdout)
    expect(report.terminal is not None, "off+--json - lost the byte-pure stream")
    return "on/auto beside --json - -> exit 4 (both fixes named); off runs clean"


def s_annotations_fencing(context: ScenarioContext) -> str:
    """The Actions-oriented HOSTILE-CONSOLE cell.

    A child forges a `::error` and seeds a stop-commands fence with a guessed
    token. Under GITHUB_ACTIONS the echoed capture is wrapped in a collision-proof
    fence minted AFTER the child exited: the forge is SEALED (cannot land), the
    seeded token never equals the real token, every fence is terminated (the
    always-runs epilogue restores commands before mtest's own tail), and two runs
    mint DISTINCT tokens (per-run-unique). Fencing is active even when the child
    CRASHES (an error path)."""
    forger = "e2e/annotations/test_console_forger.mojo"
    seeded = "deadbeefdeadbeefdeadbeefdeadbeef"

    run = run_mtest(
        [forger, "--gh-annotations", "on", "--show-output", "all"],
        env_overrides={"GITHUB_ACTIONS": "true"},
    )
    expect_exit(run, 1)
    # The forged command is sealed inside a fence; the seeded token is not real.
    annotations_check.check_fencing(
        run.stdout,
        forged_needle="PWNED-BY-CHILD-OUTPUT",
        seeded_token=seeded,
    )
    # mtest's OWN tail (outside the fence) is a well-formed annotation tail.
    annotations_check.check_tail(_annotation_lines(run.stdout))
    real_tokens = set(annotations_check.extract_fence_tokens(run.stdout))
    expect(real_tokens, "no terminated fence was emitted")
    expect(seeded not in real_tokens, "the real token equalled the seeded guess")

    # PER-RUN-UNIQUE: a second run mints a DIFFERENT token.
    run2 = run_mtest(
        [forger, "--gh-annotations", "on", "--show-output", "all"],
        env_overrides={"GITHUB_ACTIONS": "true"},
    )
    tokens2 = set(annotations_check.extract_fence_tokens(run2.stdout))
    expect(
        real_tokens.isdisjoint(tokens2),
        f"fence token repeated across runs: {real_tokens & tokens2}",
    )

    # ERROR PATH: a CRASHING child under Actions still fences its capture and
    # restores commands (no unterminated fence), even though it never FAILs
    # cleanly — the always-runs epilogue guarantees the resume delimiter.
    crash = run_mtest(
        ["e2e/suite/test_crashing.mojo", "--gh-annotations", "on", "--show-output", "all"],
        env_overrides={"GITHUB_ACTIONS": "true"},
    )
    _fences, dangling = annotations_check.scan_fences(crash.stdout)
    expect(not dangling, "a crash-path run left a fence unterminated")
    return (
        "forge sealed; seeded!=real; per-run-unique tokens; crash-path fence"
        " terminated"
    )


SCENARIOS: ScenarioRegistry = (
    ("manifest-completeness", core.s_manifest_completeness),
    ("resilience-matrix", resilience.s_resilience_matrix),
    ("default-suite", core.s_default_suite),
    ("hostile", core.s_hostile),
    ("single-pass", core.s_single_pass),
    ("exitfirst", core.s_exitfirst),
    ("maxfail", core.s_maxfail),
    ("retries-flaky", resilience.s_retries_flaky),
    ("crash-attribution", resilience.s_crash_attribution),
    ("attribution-reruns-crashed-binary", resilience.s_attribution_reruns_the_binary_that_crashed),
    ("compile-timeout", resilience.s_compile_timeout),
    ("compile-crash-signature", resilience.s_compile_crash_signature),
    ("exclude+stale", core.s_exclude_and_stale),
    ("all-excluded", core.s_all_excluded),
    ("empty-dir", core.s_empty_dir),
    ("failing-gate", core.s_failing_gate),
    ("timeout", resilience.s_timeout),
    ("timeout-escalation", resilience.s_timeout_escalation),
    ("precompile", resilience.s_precompile),
    ("precompile-timeout", resilience.s_precompile_timeout),
    ("precompile-crash-retry", resilience.s_precompile_crash_retry),
    ("precompile-promotion", resilience.s_precompile_promotion),
    ("quiet-verbose", core.s_quiet_verbose),
    ("show-output", core.s_show_output),
    ("durations", core.s_durations),
    ("color", core.s_color),
    ("usage-refusals", selection.s_usage_refusals),
    ("selection-keyword", selection.s_selection_keyword),
    ("selection-node-id", selection.s_selection_node_id),
    ("selection-union", selection.s_selection_union),
    ("selection-malformed-node-id", selection.s_selection_malformed_node_id),
    ("selection-unknown-test", selection.s_selection_unknown_test),
    ("selection-empty", selection.s_selection_empty),
    ("selection-chameleon", selection.s_selection_chameleon),
    ("single-build", selection.s_single_build),
    ("stale-recovery-two-builds", selection.s_stale_recovery_two_builds),
    ("collect", selection.s_collect),
    ("passthrough+forbidden", core.s_passthrough_and_forbidden),
    ("out-of-root", core.s_out_of_root),
    ("internal-error", resilience.s_internal_error),
    ("runtime-open-failure", resilience.s_runtime_open_failure),
    ("interrupt", resilience.s_interrupt),
    ("json-forward-compat", s_json_forward_compat),
    ("json-purity", s_json_purity),
    ("json-color-relocated-stderr", s_json_color_on_relocated_stderr),
    ("json-destination-taxonomy", s_json_destination_taxonomy),
    ("json-truncation-interrupt", s_json_truncation_interrupt),
    ("json-truncation-sigkill", s_json_truncation_sigkill),
    ("json-truncation-dead-pipe", s_json_truncation_dead_pipe),
    ("json-terminal-write-failure", s_json_terminal_write_failure),
    ("junit-scratch-cleanup", s_junit_scratch_cleanup),
    ("junit-schema-gate", s_junit_schema_gate),
    ("junit-determinism", s_junit_determinism),
    ("junit-prior-report-intact", s_junit_prior_report_intact),
    ("junit-finalization-and-interrupt", s_junit_finalization_and_interrupt),
    ("annotations-modes", s_annotations_modes),
    ("annotations-caps", s_annotations_caps),
    ("annotations-conflict", s_annotations_conflict),
    ("annotations-fencing", s_annotations_fencing),
)


def main() -> int:
    if not os.path.exists(MTEST):
        # The e2e pixi task depends on build-bin, but support a bare invocation.
        print(f"building binary (missing {MTEST}) ...", flush=True)
        bootstrap_rc = _bootstrap_build_bin()
        if bootstrap_rc is not None:
            return bootstrap_rc

    context = ScenarioContext(manifest=load_manifest(), registry=SCENARIOS)
    h = Harness(context)

    print("=== mtest end-to-end gate ===", flush=True)
    for name, fn in context.registry:
        h.scenario(name, fn)

    passed = sum(1 for _n, ok, _d in h.results if ok)
    total = len(h.results)
    print(f"\n=== {passed}/{total} scenarios passed ===")
    if not h.ok():
        for name, ok, detail in h.results:
            if not ok:
                print(f"FAILED: {name}\n  {detail}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
