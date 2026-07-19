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
        python scripts/e2e_check.py
"""

from __future__ import annotations

import inspect
import json
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
from dataclasses import dataclass, field
from pathlib import Path
from xml.etree import ElementTree as ET

import annotations_check
import json_stream_check
import junit_canonicalize
import junit_check
import main_open_check

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MTEST = os.path.join(REPO_ROOT, "build", "mtest")
E2E_ROOT = os.path.join(REPO_ROOT, "e2e")
MANIFEST_PATH = os.path.join(E2E_ROOT, "manifest.json")
LOGGING_MOJO = os.path.join(REPO_ROOT, "scripts", "logging_mojo.py")
FAKE_SLOW_MOJO = os.path.join(REPO_ROOT, "scripts", "fake_slow_mojo.py")
FAKE_CRASH_MOJO = os.path.join(REPO_ROOT, "scripts", "fake_crash_mojo.py")
FAKE_RETRY_CRASH_MOJO = os.path.join(REPO_ROOT, "scripts", "fake_retry_crash_mojo.py")
JSON_TERMINAL_WRITE_FAULT = os.path.join(
    REPO_ROOT, "tests", "native", "e2e_json_terminal_write_fault.c"
)

# Generous per-spawn wall-clock ceilings. Cold `mojo build` is slow, so these are
# roomy — their only job is to keep a hung runner from wedging CI, never to time
# a scenario. The TIMEOUT and interrupt scenarios assert their own tighter bounds.
DEFAULT_TIMEOUT = 180.0
SHORT_TIMEOUT = 30.0

# The summary band counts TESTS for pass/fail/skip and FILES for the abnormals.
# pass/fail/skip always appear; each file-level abnormal appears only when
# nonzero, so every abnormal segment (and the trailing deselected count) is
# optional. Named groups keep call sites robust to the optional segments.
SUMMARY_RE = re.compile(
    r"=====\s+(?P<passed>\d+) passed,\s+(?P<failed>\d+) failed,\s+"
    r"(?P<skipped>\d+) skipped"
    r"(?:,\s+(?P<crashed>\d+) crashed)?"
    r"(?:,\s+(?P<timed_out>\d+) timed out)?"
    r"(?:,\s+(?P<compile_error>\d+) compile error)?"
    r"(?:,\s+(?P<malformed>\d+) malformed suite)?"
    r"[^(]*"
    r"\((?P<excluded>\d+) excluded,\s+(?P<not_run>\d+) not run"
    r"(?:,\s+(?P<deselected>\d+) deselected)?\)"
    r"\s+in\s+(?P<seconds>[\d.]+)s\s+====="
)
HEADER_RE = re.compile(r"root:\s+.*?selected:\s+(\d+) files\s+excluded:\s+(\d+)")

VERDICT_TO_BUCKET = {
    "PASS": "passed",
    "FAIL": "failed",
    "CRASH": "crashed",
    "TIMEOUT": "timed_out",
    "COMPILE-ERROR": "compile_error",
}

# A per-file verdict line starts at column 0 with one of these tokens, then the
# root-relative path (never contains whitespace in this tree). NO-TESTS is a
# valid zero-test pass line and must be counted for the ordering check. Used to
# check contract §17's determinism promise: the console summary is ordered
# lexicographically by path, independent of finish order.
VERDICT_LINE_TOKENS = list(VERDICT_TO_BUCKET) + ["NO-TESTS"]
VERDICT_LINE_RE = re.compile(
    r"^(?:" + "|".join(re.escape(t) for t in VERDICT_LINE_TOKENS) + r")\s+(\S+)",
    re.MULTILINE,
)


def verdict_paths_in_order(run: Run) -> list[str]:
    """Root-relative paths named by run-outcome verdict lines, in stdout order."""
    return VERDICT_LINE_RE.findall(run.stdout)


@dataclass
class Summary:
    # passed/failed/skipped are per-TEST totals; crashed/timed_out/compile_error/
    # malformed are per-FILE abnormal counts (omitted from the band when zero, so
    # they parse as 0 here). excluded/not_run/deselected are separate counts.
    passed: int
    failed: int
    skipped: int
    crashed: int
    timed_out: int
    compile_error: int
    malformed: int
    excluded: int
    not_run: int
    seconds: float
    deselected: int = 0


class ScenarioError(AssertionError):
    pass


@dataclass
class Run:
    argv: list[str]
    returncode: int
    stdout: str
    stderr: str
    wall: float

    @property
    def combined(self) -> str:
        return self.stdout + "\n" + self.stderr

    def summary(self) -> Summary:
        m = SUMMARY_RE.search(self.combined)
        if not m:
            # ScenarioError (not bare AssertionError): Harness.scenario() only
            # catches ScenarioError, so a missing summary band must raise that
            # subclass to be reported as a clean scenario FAILURE rather than
            # crashing the whole harness with a raw traceback.
            raise ScenarioError(
                f"no summary band in output for {self.argv}\n{self.combined}"
            )
        g = m.groupdict()

        def num(key: str) -> int:
            return int(g[key]) if g.get(key) is not None else 0

        return Summary(
            passed=num("passed"),
            failed=num("failed"),
            skipped=num("skipped"),
            crashed=num("crashed"),
            timed_out=num("timed_out"),
            compile_error=num("compile_error"),
            malformed=num("malformed"),
            excluded=num("excluded"),
            not_run=num("not_run"),
            deselected=num("deselected"),
            seconds=float(g["seconds"]),
        )

    def header(self) -> tuple[int, int]:
        m = HEADER_RE.search(self.combined)
        if not m:
            raise ScenarioError(
                f"no header band in output for {self.argv}\n{self.combined}"
            )
        return int(m.group(1)), int(m.group(2))

    def verdict_line(self, token: str, path: str) -> str | None:
        """A verdict line starts with the token and names the path; framed
        sections start with '---', so startswith(token) never matches them."""
        for line in self.stdout.splitlines():
            if line.startswith(token) and path in line:
                return line
        return None


def run_mtest(
    args: list[str],
    *,
    timeout: float = DEFAULT_TIMEOUT,
    check_binary: bool = True,
    env_overrides: dict[str, str] | None = None,
) -> Run:
    """Spawn build/mtest with an explicit argv (never a shell) in its own process
    group, with the inherited environment (mojo stays on PATH). On timeout the
    whole group is killed so a hung runner cannot wedge the gate.

    `env_overrides`, when given, layers on top of the inherited environment
    (never replaces it) — the harness still never scrubs the environment, it
    only adds or overrides a handful of keys for a single scenario (e.g.
    NO_COLOR)."""
    if check_binary and not os.path.exists(MTEST):
        raise ScenarioError(f"binary not found at {MTEST}; run `pixi run build-bin`")
    argv = [MTEST, *args]
    # Pin GITHUB_ACTIONS OFF by default so the console's stop-commands fencing —
    # keyed on GITHUB_ACTIONS, independent of --gh-annotations — never perturbs a
    # scenario's structural assertions when this gate itself runs inside Actions.
    # The annotation cells opt back IN with env_overrides={"GITHUB_ACTIONS":"true"}.
    # This is a determinism control over one CI-detection variable, not an
    # environment scrub: PATH and the toolchain still pass straight through.
    child_env = dict(os.environ)
    child_env["GITHUB_ACTIONS"] = ""
    if env_overrides:
        child_env.update(env_overrides)
    start = time.monotonic()
    proc = subprocess.Popen(
        argv,
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
        env=child_env,
    )
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        out, err = proc.communicate()
        raise ScenarioError(
            f"mtest did not return within {timeout}s for argv {argv} — "
            f"killed its process group (possible runner hang)"
        )
    wall = time.monotonic() - start
    return Run(argv=argv, returncode=proc.returncode, stdout=out, stderr=err, wall=wall)


def run_mtest_pty(
    args: list[str],
    *,
    env_overrides: dict[str, str | None] | None = None,
    timeout: float = SHORT_TIMEOUT,
) -> tuple[int, bytes]:
    """Spawn build/mtest with stdout+stderr attached to a real pty, in its own
    process group, hard-timeout guarded exactly like run_mtest.

    Only the color scenario needs this: a piped stdout (run_mtest) is NEVER a
    tty, so ColorWhen.AUTO is colorless regardless of NO_COLOR — an assertion
    built on a pipe would pass even if NO_COLOR were silently ignored. A real
    pty is required to prove NO_COLOR actually overrides an AUTO run that would
    otherwise be colored.
    """
    if not os.path.exists(MTEST):
        raise ScenarioError(f"binary not found at {MTEST}; run `pixi run build-bin`")
    argv = [MTEST, *args]
    env = dict(os.environ)
    env["GITHUB_ACTIONS"] = ""  # deterministic: no fencing unless a cell opts in
    if env_overrides:
        # A None value REMOVES the key from the child environment (a plain
        # dict.update cannot clear an ambient key). This lets a scenario prove
        # behavior with a variable explicitly absent, not merely overridden.
        for key, value in env_overrides.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
    master_fd, slave_fd = pty.openpty()
    proc = subprocess.Popen(
        argv,
        cwd=REPO_ROOT,
        stdout=slave_fd,
        stderr=slave_fd,
        env=env,
        start_new_session=True,
    )
    os.close(slave_fd)
    out = bytearray()
    deadline = time.monotonic() + timeout
    timed_out = False
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            ready, _, _ = select.select([master_fd], [], [], remaining)
            if not ready:
                continue
            try:
                chunk = os.read(master_fd, 4096)
            except OSError:
                break  # pty closed on the child side: EOF
            if not chunk:
                break
            out += chunk
    finally:
        os.close(master_fd)

    if timed_out:
        _kill_group(proc)
        proc.wait(timeout=5)
        raise ScenarioError(
            f"mtest did not return within {timeout}s for argv {argv} under a pty "
            f"— killed its process group (possible runner hang)"
        )
    try:
        returncode = proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        proc.wait(timeout=5)
        raise ScenarioError(
            f"mtest closed its pty but never exited for argv {argv} — "
            f"killed its process group (possible runner hang)"
        )
    return returncode, bytes(out)


def _kill_group(proc: subprocess.Popen) -> None:
    try:
        pgid = os.getpgid(proc.pid)
    except ProcessLookupError:
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pgid, sig)
        except ProcessLookupError:
            return
        time.sleep(0.3)


# ---- assertion helpers -------------------------------------------------------


def expect(cond: bool, msg: str) -> None:
    if not cond:
        raise ScenarioError(msg)


def expect_exit(run: Run, code: int) -> None:
    expect(
        run.returncode == code,
        f"expected exit {code}, got {run.returncode} for {run.argv}\n"
        f"--- stdout ---\n{run.stdout}\n--- stderr ---\n{run.stderr}",
    )


def expect_accounting(run: Run) -> Summary:
    """The file-count invariant that still holds now that pass/fail/skip count
    TESTS, not files: the summary and the header agree on the excluded FILE count.

    (The old run-outcomes+not-run==selected file-count identity no longer holds
    — passed/failed are per-test, and `s_default_suite` asserts that exact
    test-count arithmetic separately; here we keep the band parseable and the
    excluded counts reconciled for every scenario, not just the default suite.)
    """
    summ = run.summary()
    _selected, hdr_excluded = run.header()
    expect(
        summ.excluded == hdr_excluded,
        f"excluded mismatch: summary {summ.excluded} vs header {hdr_excluded} "
        f"for {run.argv}",
    )
    return summ


# ---- manifest ----------------------------------------------------------------


def load_manifest() -> dict:
    with open(MANIFEST_PATH, encoding="utf-8") as fh:
        return json.load(fh)


def discovered_test_files() -> set[str]:
    root = E2E_ROOT
    found: set[str] = set()
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if name.startswith("test_") and name.endswith(".mojo"):
                abs_p = os.path.join(dirpath, name)
                found.add(os.path.relpath(abs_p, REPO_ROOT))
    return found


# ---- scenarios ---------------------------------------------------------------
#
# Each scenario is a function taking the loaded manifest and raising
# ScenarioError on any structural or exit-code mismatch. The name is the dict
# key; ordering in RESULTS follows insertion.


@dataclass
class Harness:
    manifest: dict
    results: list[tuple[str, bool, str]] = field(default_factory=list)

    def scenario(self, name: str, fn) -> None:
        try:
            detail = fn(self.manifest)
            self.results.append((name, True, detail or ""))
            print(f"PASS  {name}  {detail or ''}")
        except ScenarioError as exc:
            self.results.append((name, False, str(exc)))
            print(f"FAIL  {name}\n      {exc}")

    def ok(self) -> bool:
        return all(passed for _n, passed, _d in self.results)


def s_manifest_completeness(manifest: dict) -> str:
    tests = manifest["tests"]
    rows = set(tests.keys())
    disk = discovered_test_files()
    missing_rows = disk - rows
    stale_rows = rows - disk
    expect(not missing_rows, f"discovered files with no manifest row: {sorted(missing_rows)}")
    expect(not stale_rows, f"manifest rows with no file on disk: {sorted(stale_rows)}")
    for rel in rows:
        expect(
            os.path.exists(os.path.join(REPO_ROOT, rel)),
            f"manifest row {rel} names a missing file",
        )
    # Non-discovered and support files exist but are not test_*.mojo.
    for rel in list(manifest.get("non_discovered", {})) + list(
        manifest.get("support_files", {})
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


def _suite_tests(manifest: dict) -> dict:
    return {
        rel: row
        for rel, row in manifest["tests"].items()
        if row.get("in_default_suite")
    }


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
RESILIENCE_MATRIX = {
    "run crash: std.os.abort target trap (SIGILL x86_64 / SIGTRAP arm64)": (
        "default-suite"
    ),
    "run crash: SIGSEGV": "retries-flaky",
    "run timeout: polite exit inside the grace": "timeout",
    "run timeout: SIGKILL escalation past the grace": "timeout-escalation",
    "compile timeout: the build step": "compile-timeout",
    "compile timeout: the precompile step": "precompile-timeout",
    "compiler crash: death by SIGNAL": "precompile-crash-retry",
    "compiler crash: crash SIGNATURE + nonzero exit": "compile-crash-signature",
    "compiler crash: a retried build's binary is the one attributed": (
        "attribution-reruns-crashed-binary"
    ),
    "precompile crash": "precompile-crash-retry",
    "promotion: a killed compile never touches OUT": "precompile-promotion",
}

# A scenario that reaches for one of the kill/timeout/crash `--mojo` stand-ins is
# a resilience scenario by construction, and must therefore be named by the
# matrix above. Matched against each scenario's SOURCE, so the reverse check
# needs no second hand-maintained list to drift out of step.
RESILIENCE_SHIM_MARKERS = ("FAKE_CRASH_MOJO", "FAKE_SLOW_MOJO", "FAKE_RETRY_CRASH_MOJO")


def s_resilience_matrix(manifest: dict) -> str:
    """The matrix as a WHOLE: every kill/timeout/crash class has a live scenario.

    The individual scenarios prove their own behavior; this one pins the SET, so
    a future change that quietly drops a class from the gate is caught by the
    gate. Checked both ways, mirroring `s_manifest_completeness`:

      * every class in RESILIENCE_MATRIX names a REGISTERED scenario (delete or
        rename `s_compile_timeout` and this goes red, instead of the compile
        timeout simply ceasing to be tested);
      * every registered scenario that drives a crash/slow compiler stand-in is
        named by the matrix (add a resilience scenario and you must say which
        class it serves).

    This asserts COVERAGE, never behavior — it runs no mtest of its own.
    """
    registered = {name for name, _fn in SCENARIOS}
    classified = set(RESILIENCE_MATRIX.values())

    dangling = sorted(
        f"{cls!r} -> {scen!r}"
        for cls, scen in RESILIENCE_MATRIX.items()
        if scen not in registered
    )
    expect(
        not dangling,
        "the resilience matrix names scenarios that are not registered — a "
        f"kill/timeout/crash class lost its end-to-end proof: {dangling}",
    )

    unclassified = sorted(
        name
        for name, fn in SCENARIOS
        if name not in classified
        and any(marker in inspect.getsource(fn) for marker in RESILIENCE_SHIM_MARKERS)
    )
    expect(
        not unclassified,
        "these scenarios drive a crash/slow compiler stand-in but no resilience "
        f"class claims them — add a RESILIENCE_MATRIX row: {unclassified}",
    )
    return (
        f"{len(RESILIENCE_MATRIX)} kill/timeout/crash classes, each covered by a "
        f"registered scenario; no unclassified resilience scenario"
    )


def s_default_suite(manifest: dict) -> str:
    suite = _suite_tests(manifest)
    run = run_mtest(["e2e/suite"])
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
        line = run.verdict_line(token, rel)
        expect(line is not None, f"missing verdict line {token} for {rel}")
        if token == "CRASH":
            crash_lines[rel] = line
        if token == "COMPILE-ERROR":
            compile_error_files.append(rel)

    # Standing pin: std.os.abort lowers to the served target's trap instruction:
    # SIGILL (signal 4) on linux-64/x86_64, SIGTRAP (signal 5) on osx-arm64.
    # Require the exact number/name association on the verdict line, so neither a
    # changed death signal nor lost word-name can hide behind a generic CRASH.
    expect(len(crash_lines) == 1, f"expected exactly one CRASH fixture, got {crash_lines}")
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
        run.verdict_line("NO-TESTS", zero[0]) is not None,
        "zero-test file did not show a NO-TESTS verdict (never a plain PASS)",
    )
    # helper.mojo (non-discovered) must never appear.
    for rel in manifest.get("non_discovered", {}):
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
        f"timed-out FILES: band {summ.timed_out} != manifest {file_abnormals['timed_out']}",
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


def s_hostile(manifest: dict) -> str:
    """The hostile handshake set: each report-shaped adversary, run alone.

    silent -> MALFORMED-SUITE (exit 1); forger (two blocks) -> MALFORMED-SUITE
    (exit 1); liar (off-grammar report) -> DRIFT (exit 3); overflow (a ~13 MiB
    flood) -> CAPTURE-OVERFLOW FAIL (exit 1). These files are NOT in the default
    suite — the liar alone forces exit 3, which would swamp a whole-suite run —
    so each is driven on its own here. The verdict tokens and exit codes come
    straight from the manifest rows for e2e/hostile/*."""
    hostile = {
        rel: row
        for rel, row in manifest["tests"].items()
        if rel.startswith("e2e/hostile/")
    }
    expect(len(hostile) == 4, f"expected 4 hostile fixtures, got {len(hostile)}")

    silent = "e2e/hostile/test_silent.mojo"
    run = run_mtest([silent])
    expect_exit(run, 1)
    expect(
        run.verdict_line("MALFORMED-SUITE", silent) is not None,
        f"silent binary did not report MALFORMED-SUITE:\n{run.stdout}",
    )

    forger = "e2e/hostile/test_forger.mojo"
    run = run_mtest([forger])
    expect_exit(run, 1)
    expect(
        run.verdict_line("MALFORMED-SUITE", forger) is not None,
        f"forger did not report MALFORMED-SUITE:\n{run.stdout}",
    )

    liar = "e2e/hostile/test_liar.mojo"
    run = run_mtest([liar])
    expect_exit(run, 3)
    expect(
        "drift" in run.combined.lower(),
        f"liar did not surface a drift diagnostic (exit 3):\n{run.combined}",
    )

    # --show-output none keeps the ~8 MiB truncated capture out of the console;
    # the FAIL verdict line prints regardless of the show-output setting.
    overflow = "e2e/hostile/test_overflow.mojo"
    run = run_mtest([overflow, "--show-output", "none"])
    expect_exit(run, 1)
    expect(
        run.verdict_line("FAIL", overflow) is not None,
        f"overflow flood did not report FAIL:\n{run.stdout}",
    )
    return "silent/forger MALFORMED-SUITE, liar DRIFT exit 3, overflow FAIL"


def s_single_pass(manifest: dict) -> str:
    rel = "e2e/suite/test_passing.mojo"
    run = run_mtest([rel])
    expect_exit(run, 0)
    expect(run.verdict_line("PASS", rel) is not None, "no PASS verdict line")
    expect_accounting(run)
    return "single passing file -> exit 0"


def s_exitfirst(manifest: dict) -> str:
    run = run_mtest(["e2e/suite", "-x"])
    expect_exit(run, 1)
    summ = expect_accounting(run)
    expect(summ.not_run >= 1, f"-x left nothing NOT-RUN (not_run={summ.not_run})")
    return f"-x stopped scheduling; {summ.not_run} NOT-RUN, accounting holds"


def s_maxfail(manifest: dict) -> str:
    """`--maxfail N` stops scheduling once N failing TESTS have accumulated.

    e2e/maxfail/ sorts test_a_fail, test_b_fail, test_c_pass; each failing
    file contributes exactly one failing test. `--maxfail 1` must stop right
    after test_a_fail, leaving the other two NOT-RUN."""
    run = run_mtest(["e2e/maxfail", "--maxfail", "1"])
    expect_exit(run, 1)
    summ = expect_accounting(run)
    expect(summ.failed == 1, f"--maxfail 1 let {summ.failed} FAILs run, expected 1")
    expect(summ.not_run == 2, f"--maxfail 1 left {summ.not_run} NOT-RUN, expected 2")
    expect(
        run.verdict_line("FAIL", "e2e/maxfail/test_a_fail.mojo") is not None,
        "the file that tripped --maxfail did not report FAIL",
    )
    return f"--maxfail 1 stopped after 1 failing test; {summ.not_run} NOT-RUN, accounting holds"


def s_retries_flaky(manifest: dict) -> str:
    """`--retries` re-runs a crash-class failure; a late pass is FLAKY.

    The flaky fixture crashes by SIGSEGV on its first run (dropping a marker) and
    passes on a re-run (marker present). The harness OWNS the scratch dir and
    resets the marker before each run so ordering is deterministic:
      * --retries 1 -> the crashed first attempt shows a TRY line, the file is
        reported FLAKY, and the process exits 0;
      * --retries 0 -> the first crash stands as CRASH and the process exits 1.
    Structure is asserted (a TRY line and a FLAKY token are present), never the
    exact console bytes."""
    rel = "e2e/flaky/test_flaky.mojo"
    scratch = os.path.join(REPO_ROOT, "build", "e2e-scratch")
    marker = os.path.join(scratch, "flaky_marker")

    def reset() -> None:
        os.makedirs(scratch, exist_ok=True)
        if os.path.exists(marker):
            os.remove(marker)

    try:
        # --retries 1: crash then pass -> FLAKY, exit 0, with a TRY line.
        reset()
        run1 = run_mtest([rel, "--retries", "1"], timeout=SHORT_TIMEOUT)
        expect_exit(run1, 0)
        expect(
            run1.verdict_line("TRY", rel) is not None,
            f"--retries 1 showed no TRY line for the crashed first attempt:\n"
            f"{run1.stdout}",
        )
        expect(
            run1.verdict_line("FLAKY", rel) is not None,
            f"--retries 1 did not report the file FLAKY:\n{run1.stdout}",
        )
        expect_accounting(run1)

        # --retries 0: the first crash stands -> CRASH, exit 1.
        reset()
        run0 = run_mtest([rel, "--retries", "0"], timeout=SHORT_TIMEOUT)
        expect_exit(run0, 1)
        expect(
            run0.verdict_line("CRASH", rel) is not None,
            f"--retries 0 did not report the file CRASH:\n{run0.stdout}",
        )

        # SELECTION variant: retries must NOT be inert under -k/node-id. The same
        # crash-then-pass via a keyword selection is FLAKY with a TRY line.
        reset()
        runk = run_mtest(
            ["e2e/flaky", "-k", "flaky", "--retries", "1"],
            timeout=SHORT_TIMEOUT,
        )
        expect_exit(runk, 0)
        expect(
            runk.verdict_line("TRY", rel) is not None,
            f"-k selection + --retries 1 showed no TRY line:\n{runk.stdout}",
        )
        expect(
            runk.verdict_line("FLAKY", rel) is not None,
            f"-k selection + --retries 1 did not report FLAKY:\n{runk.stdout}",
        )
    finally:
        if os.path.exists(marker):
            os.remove(marker)
    return (
        "retries: default --retries 1 -> TRY + FLAKY (exit 0); --retries 0 ->"
        " CRASH (exit 1); -k selection --retries 1 -> TRY + FLAKY (exit 0)"
    )


def s_crash_attribution(manifest: dict) -> str:
    """A CRASH file gets a bounded isolation post-pass that NEVER moves the verdict.

    The honesty pair, and the doctrine's core claim asserted directly:

      * the DETERMINISTIC crasher — one test always dies — is ATTRIBUTED: the
        pass names test_boom as the culprit;
      * the ORDER-DEPENDENT crasher — crashes only with its tests run together —
        is NO-REPRODUCTION: each test passes alone, so the culprit stays
        UNATTRIBUTED and is never guessed.

    Both files must produce the IDENTICAL verdict and exit code: attribution is
    secondary evidence, so a run where it succeeds and a run where it fails must
    be indistinguishable in everything a verdict is made of. That equality —
    exit 1, a CRASH verdict line, and a byte-equal summary accounting tuple — is
    asserted between the two runs, not merely against the manifest. Structure
    only; never console bytes."""
    attributed_rel = "e2e/attribution/test_deterministic_crasher.mojo"
    unattributed_rel = "e2e/attribution/test_order_dependent_crasher.mojo"

    def verdict_facts(rel: str) -> tuple:
        run = run_mtest([rel], timeout=SHORT_TIMEOUT)
        # THE claim: the CRASH verdict and the exit code stand on their own.
        expect_exit(run, 1)
        crash_line = run.verdict_line("CRASH", rel)
        expect(
            crash_line is not None,
            f"{rel} did not report the file CRASH:\n{run.stdout}",
        )
        summ = expect_accounting(run)
        expect(
            summ.crashed == 1,
            f"{rel}: band counted {summ.crashed} crashed files, expected 1",
        )
        # The pass announces itself before spawning anything, so a watcher of a
        # long run is never left wondering where the extra processes came from.
        expect(
            "crash-attribution-start" in run.combined,
            f"{rel}: the attribution pass never announced itself:\n{run.stdout}",
        )
        line = run.verdict_line("ATTRIBUTION", rel)
        expect(
            line is not None,
            f"{rel}: no ATTRIBUTION line for a crashed file:\n{run.stdout}",
        )
        facts = (
            summ.passed,
            summ.failed,
            summ.skipped,
            summ.crashed,
            summ.excluded,
            summ.not_run,
        )
        return run.returncode, facts, line

    attributed_rc, attributed_facts, attributed_line = verdict_facts(attributed_rel)
    unattributed_rc, unattributed_facts, unattributed_line = verdict_facts(
        unattributed_rel
    )

    # The deterministic crasher's culprit is NAMED.
    expect(
        "ATTRIBUTED" in attributed_line and "test_boom" in attributed_line,
        f"the deterministic crasher's culprit was not attributed to test_boom: "
        f"{attributed_line!r}",
    )
    expect(
        "UNATTRIBUTED" not in attributed_line,
        f"an ATTRIBUTED line still called the culprit unknown: {attributed_line!r}",
    )

    # The order-dependent crasher's culprit is NOT guessed.
    expect(
        "NO-REPRODUCTION" in unattributed_line,
        f"the order-dependent crasher did not report NO-REPRODUCTION: "
        f"{unattributed_line!r}",
    )
    expect(
        "UNATTRIBUTED" in unattributed_line,
        f"a failed isolation search did not say the culprit is UNATTRIBUTED: "
        f"{unattributed_line!r}",
    )
    for name in ("test_corrupts_shared_state", "test_trips_over_shared_state"):
        expect(
            name not in unattributed_line,
            f"a NO-REPRODUCTION line named {name} — attribution GUESSED a "
            f"culprit it never reproduced: {unattributed_line!r}",
        )

    # THE DOCTRINE: attribution success and attribution failure leave the
    # verdict and the exit code indistinguishable.
    expect(
        attributed_rc == unattributed_rc == 1,
        f"attribution changed the exit code: attributed={attributed_rc}, "
        f"unattributed={unattributed_rc} (both must be 1)",
    )
    expect(
        attributed_facts == unattributed_facts,
        f"attribution changed the summary accounting: attributed="
        f"{attributed_facts} != unattributed={unattributed_facts}",
    )
    # The REGISTRY-listing branch. A bare path operand is not a selection, so
    # both runs above took the plain loop and the fallback probe; the branch that
    # reads the already-recorded `rel::name` listing (and strips that prefix)
    # would never execute. A strip bug there is INVISIBLE by construction: the
    # malformed names would feed `--only`, every rerun would exit nonzero but
    # UNSIGNALED, and the pass would report a falsely honest NO-REPRODUCTION on a
    # file whose culprit is plainly nameable. `-k boom` forces the selection path,
    # so the listing comes from the registry — and the culprit must still be named.
    keyword = run_mtest(
        [attributed_rel, "-k", "boom"], timeout=SHORT_TIMEOUT
    )
    expect_exit(keyword, 1)
    expect(
        keyword.verdict_line("CRASH", attributed_rel) is not None,
        f"-k boom did not report the file CRASH:\n{keyword.stdout}",
    )
    keyword_line = keyword.verdict_line("ATTRIBUTION", attributed_rel)
    expect(
        keyword_line is not None,
        f"-k boom produced no ATTRIBUTION line:\n{keyword.stdout}",
    )
    expect(
        "ATTRIBUTED" in keyword_line and "test_boom" in keyword_line,
        f"the registry-recorded listing did not name the culprit (a node-id "
        f"prefix-strip bug would surface exactly here): {keyword_line!r}",
    )

    return (
        "attribution: deterministic -> ATTRIBUTED (test_boom); order-dependent "
        "-> NO-REPRODUCTION (UNATTRIBUTED); both exit 1 with identical CRASH "
        f"accounting {attributed_facts}; -k selection -> ATTRIBUTED off the "
        "registry listing"
    )


def s_attribution_reruns_the_binary_that_crashed(manifest: dict) -> str:
    """Attribution reruns the binary that ACTUALLY crashed, not a reconstructed name.

    The one path where the pass could point at the WRONG thing. A crash-class
    BUILD failure is retried, and the retry rebuilds to a FRESH
    `build/bin/<mangled>.attempt-2` and then RUNS that binary — so a file whose
    rebuilt binary crashes at runtime has a CRASH verdict earned by a path the
    mangled name does not name. A runner that reconstructed `build/bin/<mangled>`
    would probe either a nonexistent file or a STALE binary from an earlier run,
    and a stale binary can yield a culprit out of code that never ran: a
    misleading ATTRIBUTED.

    The shim (scripts/fake_retry_crash_mojo.py) makes that divergence real: its
    first `build` truncates `-o` and hangs until `--compile-timeout` kills it
    (crash-class -> retried), and its second writes a working binary at the
    retry's fresh `.attempt-2` path. So `build/bin/<mangled>` exists but is
    non-runnable, and only `.attempt-2` can answer a probe. ATTRIBUTED naming
    test_boom is therefore reachable ONLY by rerunning the binary that ran."""
    rel = "e2e/attribution/test_deterministic_crasher.mojo"
    scratch = os.path.join(REPO_ROOT, "build", "e2e-scratch")
    marker = os.path.join(scratch, "retry_crash_build_marker")

    def reset() -> None:
        os.makedirs(scratch, exist_ok=True)
        if os.path.exists(marker):
            os.remove(marker)

    try:
        reset()
        run = run_mtest(
            [
                "--mojo",
                FAKE_RETRY_CRASH_MOJO,
                rel,
                "--compile-timeout",
                "1",
                "--retries",
                "1",
            ],
            timeout=SHORT_TIMEOUT,
        )
        # The first build was killed and retried, and the rebuilt binary crashed:
        # the verdict is CRASH, exit 1 — attribution changes neither.
        expect_exit(run, 1)
        expect(
            run.verdict_line("TRY", rel) is not None,
            f"the killed first build showed no TRY line:\n{run.stdout}",
        )
        expect(
            run.verdict_line("CRASH", rel) is not None,
            f"the rebuilt binary's runtime crash was not reported CRASH:\n"
            f"{run.stdout}",
        )
        line = run.verdict_line("ATTRIBUTION", rel)
        expect(
            line is not None,
            f"no ATTRIBUTION line for the retried-build crash:\n{run.stdout}",
        )
        # THE claim: only the `.attempt-2` binary can name this culprit.
        expect(
            "ATTRIBUTED" in line and "test_boom" in line,
            f"attribution did not rerun the binary that crashed — a "
            f"reconstructed build/bin/<mangled> would land exactly here "
            f"(PROBE-FAILED, or a culprit named out of a stale binary): "
            f"{line!r}",
        )
    finally:
        if os.path.exists(marker):
            os.remove(marker)
    return (
        "build-retry crash: verdict CRASH exit 1 (unchanged), and attribution "
        "named test_boom off the .attempt-2 binary that actually ran"
    )


def s_compile_timeout(manifest: dict) -> str:
    """`--compile-timeout` bounds the BUILD; a blown deadline is COMPILE-TIMEOUT.

    Uses the committed slow-compiler `--mojo` stand-in
    (scripts/fake_slow_mojo.py), which sleeps forever on `build` but honors
    SIGTERM promptly — so this exercises the GRACEFUL half of the supervised kill
    protocol against a normal, perfectly valid fixture. The file is only slow to
    compile, never broken: that is exactly what separates COMPILE-TIMEOUT from
    COMPILE-ERROR.

      * --compile-timeout 1 -> COMPILE-TIMEOUT, the split-or-exclude hint, exit 1;
      * --compile-timeout 1 --retries 1 -> the first timed-out compile shows a TRY
        line and the compile-kill-residual warning (the rebuild ran quarantined
        against a fresh module cache), then the retry times out too and the file
        is still COMPILE-TIMEOUT at exit 1.

    Structure is asserted, never the exact console bytes."""
    rel = "e2e/suite/test_passing.mojo"

    # --compile-timeout 1: one bounded build, killed at the deadline.
    run = run_mtest(
        ["--mojo", FAKE_SLOW_MOJO, rel, "--compile-timeout", "1"],
        timeout=SHORT_TIMEOUT,
    )
    expect_exit(run, 1)
    expect(
        run.verdict_line("COMPILE-TIMEOUT", rel) is not None,
        f"--compile-timeout 1 did not report COMPILE-TIMEOUT:\n{run.stdout}",
    )
    expect(
        "compile timeout" in run.stdout and "split" in run.stdout,
        f"the COMPILE-TIMEOUT banner carried no split-or-exclude hint:\n{run.stdout}",
    )
    expect(
        "--compile-timeout 1" in run.stdout,
        f"the COMPILE-TIMEOUT banner's repro line never named the deadline:\n"
        f"{run.stdout}",
    )
    expect(
        run.verdict_line("COMPILE-ERROR", rel) is None,
        f"a build WE killed was reported as a COMPILE-ERROR:\n{run.stdout}",
    )
    expect_accounting(run)

    # --retries 1: a compile-timeout is crash-class, so it retries + quarantines.
    runr = run_mtest(
        ["--mojo", FAKE_SLOW_MOJO, rel, "--compile-timeout", "1", "--retries", "1"],
        timeout=SHORT_TIMEOUT,
    )
    expect_exit(runr, 1)
    expect(
        runr.verdict_line("TRY", rel) is not None,
        f"--retries 1 showed no TRY line for the timed-out first compile:\n"
        f"{runr.stdout}",
    )
    expect(
        "compile-kill-residual" in runr.stdout,
        f"a killed compile fired no cache-residual warning:\n{runr.stdout}",
    )
    expect(
        "quarantin" in runr.stdout,
        f"the retried compile never mentioned the cache quarantine:\n{runr.stdout}",
    )
    expect(
        runr.verdict_line("COMPILE-TIMEOUT", rel) is not None,
        f"a retry-exhausted compile timeout is still COMPILE-TIMEOUT:\n{runr.stdout}",
    )
    expect_accounting(runr)

    return (
        "compile-timeout: --compile-timeout 1 -> COMPILE-TIMEOUT + hint (exit 1);"
        " --retries 1 -> TRY + quarantined rebuild + COMPILE-TIMEOUT (exit 1)"
    )


def s_compile_crash_signature(manifest: dict) -> str:
    """The stderr CRASH SIGNATURE — not the nonzero exit — decides a build retry.

    A compiler can crash and still exit under its own control: an ICE that prints
    the LLVM banner and returns nonzero looks, to the supervisor, exactly like a
    rejected program. Only the stderr tells them apart, so `retry_classify` scans
    it (`has_crash_signature`). This scenario is the DISCRIMINATING PAIR that
    proves the scan actually gates the decision:

      * (a) WITH the banner  -> crash-class: a TRY line, the compile-kill-residual
        warning, the quarantined rebuild — then the retry crashes the same way and
        the file lands on its deterministic COMPILE-ERROR;
      * (b) WITHOUT the banner -> deterministic: NO TRY line, NO residual warning,
        one attempt only, straight to COMPILE-ERROR.

    Both halves run the SAME shim with the SAME argv and the SAME `--retries 1`,
    and the shim exits nonzero (never by a signal) in both. The ONLY difference is
    the stderr text. A single (a)-style scenario would pass even if the runner
    retried EVERY nonzero build — i.e. even if the signature list did nothing; (b)
    is what makes that impossible. Delete the `has_crash_signature(...)` condition
    from `retry_classify` (or force it true) and (b) fails on the TRY line.

    Structure is asserted, never the exact console bytes."""
    rel = "e2e/suite/test_passing.mojo"
    argv = ["--mojo", FAKE_CRASH_MOJO, rel, "--retries", "1"]

    # (a) nonzero exit WITH the ICE banner -> crash-class -> retried.
    sig = run_mtest(
        argv, timeout=SHORT_TIMEOUT, env_overrides={"MTEST_FAKE_BUILD_CRASH": "signature"}
    )
    expect_exit(sig, 1)
    expect(
        sig.verdict_line("TRY", rel) is not None,
        f"a nonzero build with a crash banner was NOT retried (no TRY line) — the "
        f"crash-signature scan is not reaching the retry decision:\n{sig.stdout}",
    )
    expect(
        "compile-crash" in sig.stdout,
        f"the retried build's TRY line did not classify it compile-crash:\n{sig.stdout}",
    )
    expect(
        "compile-kill-residual" in sig.stdout and "quarantin" in sig.stdout,
        f"a crash-class build fired no quarantined-rebuild warning:\n{sig.stdout}",
    )
    expect(
        sig.verdict_line("COMPILE-ERROR", rel) is not None,
        f"the retry-exhausted crash-class build did not land on COMPILE-ERROR:\n"
        f"{sig.stdout}",
    )
    expect_accounting(sig)

    # (b) the SAME shim, the SAME nonzero exit, ordinary stderr -> deterministic.
    plain = run_mtest(
        argv, timeout=SHORT_TIMEOUT, env_overrides={"MTEST_FAKE_BUILD_CRASH": "plain"}
    )
    expect_exit(plain, 1)
    expect(
        plain.verdict_line("TRY", rel) is None,
        f"an ordinary compile error was RETRIED — `--retries` must never re-run a "
        f"deterministic build failure, and only the stderr text differs from the "
        f"crash-class run:\n{plain.stdout}",
    )
    expect(
        "compile-kill-residual" not in plain.stdout,
        f"a deterministic compile error fired the cache-residual warning:\n"
        f"{plain.stdout}",
    )
    expect(
        plain.verdict_line("COMPILE-ERROR", rel) is not None,
        f"an ordinary compile error did not report COMPILE-ERROR:\n{plain.stdout}",
    )
    expect_accounting(plain)

    return (
        "compile-crash signature: nonzero exit + ICE banner -> TRY + quarantined"
        " retry -> COMPILE-ERROR; the SAME nonzero exit with ordinary stderr ->"
        " no TRY, no warning, COMPILE-ERROR (only the stderr text differs)"
    )


def s_exclude_and_stale(manifest: dict) -> str:
    run = run_mtest(
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
        run.verdict_line("EXCLUDED", "e2e/excluded/test_excluded.mojo") is not None,
        "no loud EXCLUDED line",
    )
    expect(
        "stale-exclusion" in run.combined,
        "no stale-exclusion warning for the pattern that matched nothing",
    )
    expect(summ.excluded == 1, f"expected 1 excluded, got {summ.excluded}")
    return "one EXCLUDED + stale-exclusion warning; excluded=1"


def s_all_excluded(manifest: dict) -> str:
    run = run_mtest(
        ["e2e/excluded", "--exclude", "e2e/excluded/test_excluded.mojo"]
    )
    expect_exit(run, 5)
    expect(
        run.verdict_line("EXCLUDED", "e2e/excluded/test_excluded.mojo") is not None,
        "no EXCLUDED line",
    )
    return "everything excluded -> exit 5"


def s_empty_dir(manifest: dict) -> str:
    # Must live inside the invocation root (an out-of-root operand is exit 4).
    tmp = tempfile.mkdtemp(prefix=".e2e_empty_", dir=E2E_ROOT)
    try:
        rel = os.path.relpath(tmp, REPO_ROOT)
        run = run_mtest([rel])
        expect_exit(run, 5)
    finally:
        os.rmdir(tmp)
    return "empty directory -> exit 5"


def s_failing_gate(manifest: dict) -> str:
    run = run_mtest(
        ["e2e/suite", "--gate", "e2e/suite/test_failing.mojo"]
    )
    expect_exit(run, 1)
    summ = expect_accounting(run)
    expect(summ.not_run >= 1, f"gate abort left nothing NOT-RUN ({summ.not_run})")
    expect(summ.failed >= 1, "gate failure not reflected in summary")
    return f"failing gate aborts; {summ.not_run} NOT-RUN"


def s_timeout(manifest: dict) -> str:
    """The POLITE half of the escalation pair (the stubborn half is
    timeout-escalation). This fixture sleeps without disarming SIGTERM, so the
    supervisor's polite signal ends it inside the grace and NO SIGKILL is ever
    sent. The verdict must therefore name the deadline and say nothing about an
    escalation: this is the assertion that makes the escalation clause a
    CONDITIONAL fact rather than a constant, so a clause appended unconditionally
    fails HERE while the stubborn scenario stays green.
    """
    rel = "e2e/slow/test_hanging.mojo"
    run = run_mtest([rel, "--timeout", "1"], timeout=SHORT_TIMEOUT)
    expect_exit(run, 1)
    summ = expect_accounting(run)
    expect(summ.timed_out == 1, f"expected 1 timed out, got {summ.timed_out}")
    verdict = run.verdict_line("TIMEOUT", rel)
    expect(verdict is not None, "no TIMEOUT verdict line")
    expect(
        "timed out after 1s" in verdict,
        f"the TIMEOUT verdict did not name the deadline:\n{verdict}",
    )
    expect(
        "escalated" not in verdict and "SIGKILL" not in verdict,
        f"a child that died on the polite SIGTERM was narrated as having been"
        f" escalated to SIGKILL — the escalation clause is not conditional on the"
        f" latched Termination:\n{verdict}",
    )
    expect(run.wall < 10.0, f"mtest took {run.wall:.1f}s to honor --timeout 1")
    return (
        f"TIMEOUT verdict names the deadline and claims NO escalation (polite"
        f" SIGTERM sufficed), exit 1, returned in {run.wall:.1f}s"
    )


def s_timeout_escalation(manifest: dict) -> str:
    """A child that IGNORES SIGTERM forces the supervisor's full kill protocol:
    SIGTERM -> 300ms run-step grace -> SIGKILL. The escalation is latched on the
    Termination, and BOTH places that can narrate it must:

      * --retries 0 -> no attempt is non-final, so there is no TRY line and the
        TIMEOUT VERDICT line is the only place the reader can learn the child had
        to be killed. This is the common case (`mtest --timeout N`).
      * --retries 1 -> attempt 1 is a crash-class run-timeout, so it also gets a
        TRY line, and the two must agree.

    Structure only — the wording is an informal surface, so this asserts the
    lines, the escalation clause, and the final TIMEOUT verdict, never exact
    bytes. Only SIGKILL can end this fixture; if the escalation ever regressed,
    the child would survive its deadline and the harness guard (not these
    assertions) would fire.
    """
    rel = "e2e/stubborn/test_stubborn.mojo"

    # --retries 0: the verdict line alone carries the story.
    run0 = run_mtest([rel, "--timeout", "1", "--retries", "0"], timeout=SHORT_TIMEOUT)
    expect_exit(run0, 1)
    summ0 = expect_accounting(run0)
    expect(summ0.timed_out == 1, f"expected 1 timed out, got {summ0.timed_out}")
    expect(
        "TRY" not in run0.stdout,
        f"--retries 0 scheduled only one attempt but showed a TRY line:\n{run0.stdout}",
    )
    verdict0 = run0.verdict_line("TIMEOUT", rel)
    expect(verdict0 is not None, f"no TIMEOUT verdict line:\n{run0.stdout}")
    expect(
        "escalated to SIGKILL" in verdict0,
        f"a SIGTERM-ignoring child's TIMEOUT verdict did not report the SIGKILL"
        f" escalation, so nothing in the run did:\n{verdict0}",
    )
    expect(
        "timed out after 1s" in verdict0,
        f"the TIMEOUT verdict did not name the deadline:\n{verdict0}",
    )

    # --retries 1: the TRY line tells the same story, and so does the verdict.
    run = run_mtest([rel, "--timeout", "1", "--retries", "1"], timeout=SHORT_TIMEOUT)
    expect_exit(run, 1)
    summ = expect_accounting(run)
    expect(summ.timed_out == 1, f"expected 1 timed out, got {summ.timed_out}")
    try_line = run.verdict_line("TRY", rel)
    expect(
        try_line is not None,
        f"the timed-out first attempt showed no TRY line:\n{run.stdout}",
    )
    expect(
        "escalated to SIGKILL" in try_line,
        f"a SIGTERM-ignoring child's TRY line did not report the SIGKILL"
        f" escalation:\n{try_line}",
    )
    expect(
        "timed out" in try_line,
        f"the TRY line did not name the deadline as the cause:\n{try_line}",
    )
    verdict = run.verdict_line("TIMEOUT", rel)
    expect(verdict is not None, f"no final TIMEOUT verdict line:\n{run.stdout}")
    expect(
        "escalated to SIGKILL" in verdict,
        f"the TRY line reported the escalation but the final verdict did not:\n{verdict}",
    )
    return (
        "SIGTERM ignored -> --retries 0: TIMEOUT verdict itself reports the SIGKILL"
        f" escalation (no TRY line); --retries 1: TRY + verdict agree; exit 1, {run.wall:.1f}s"
    )


def s_precompile(manifest: dict) -> str:
    rel = "e2e/pkg/test_uses_pkg.mojo"
    # Success: package precompiled, auto -I resolves the import -> PASS.
    ok = run_mtest([rel, "--precompile", "e2e/pkg/mathlib"])
    expect_exit(ok, 0)
    expect(ok.verdict_line("PASS", rel) is not None, "precompiled import did not PASS")
    expect(
        "COMPILE-ERROR" not in ok.stdout,
        "auto -I failed: importing test hit a COMPILE-ERROR",
    )
    # Failure: broken package -> PRECOMPILE banner, casualties, exit 1.
    bad = run_mtest([rel, "--precompile", "e2e/pkg_broken/badlib"])
    expect_exit(bad, 1)
    expect(
        "PRECOMPILE" in bad.combined,
        "no PRECOMPILE banner on a failed precompile step",
    )
    expect(
        "could not run" in bad.combined or "casualt" in bad.combined.lower(),
        "failed precompile did not list dependent files as casualties",
    )
    bsumm = bad.summary()
    expect(bsumm.not_run >= 1, "casualty file not accounted as NOT-RUN")
    return "precompile PASS (auto -I) + broken precompile banner/casualty exit 1"


def s_precompile_timeout(manifest: dict) -> str:
    """`--compile-timeout` bounds a `--precompile` step too; a blown deadline is
    a PRECOMPILE-ERROR that NAMES the timeout.

    Uses the slow-compiler stand-in (scripts/fake_slow_mojo.py), which sleeps
    forever on `precompile` and honors SIGTERM promptly. The package is fine; only
    the compiler is slow — so this separates "we killed it at our deadline" from
    "the compiler rejected the code", which read identically at exit 1 unless the
    banner says which one happened.

    Structure is asserted, never the exact console bytes."""
    rel = "e2e/pkg/test_uses_pkg.mojo"
    run = run_mtest(
        [
            "--mojo",
            FAKE_SLOW_MOJO,
            rel,
            "--precompile",
            "e2e/pkg/mathlib",
            "--compile-timeout",
            "1",
        ],
        timeout=SHORT_TIMEOUT,
    )
    expect_exit(run, 1)
    expect(
        "PRECOMPILE-ERROR" in run.combined,
        f"a timed-out precompile did not report PRECOMPILE-ERROR:\n{run.stdout}",
    )
    # The ending, in words: the deadline WE enforced — never a bare exit code.
    expect(
        "timed out after 1s" in run.combined,
        f"the PRECOMPILE-ERROR banner never named the timeout:\n{run.stdout}",
    )
    # The compiler's own output rides verbatim, and the dependents are named.
    expect(
        "lowering module" in run.combined,
        f"the PRECOMPILE-ERROR banner dropped the compiler output:\n{run.stdout}",
    )
    expect(
        rel in run.combined and "could not run" in run.combined,
        f"the timed-out precompile listed no casualties:\n{run.stdout}",
    )
    expect(run.wall < 20.0, f"mtest took {run.wall:.1f}s to honor --compile-timeout 1")
    return "precompile --compile-timeout 1 -> PRECOMPILE-ERROR naming the timeout + casualties (exit 1)"


def s_precompile_crash_retry(manifest: dict) -> str:
    """A crash-class precompile is retried under `--retries`, then reported.

    Uses the crashing-compiler stand-in (scripts/fake_crash_mojo.py), which dies
    by SIGSEGV on `precompile`. A signal death is crash-class, so:

      * --retries 0 -> one attempt, PRECOMPILE-ERROR naming the signal, exit 1;
      * --retries 1 -> a TRY line for the first attempt plus the residual warning
        (the retry ran quarantined against a fresh module cache), then the retry
        crashes too and the step is still PRECOMPILE-ERROR at exit 1.
    """
    rel = "e2e/pkg/test_uses_pkg.mojo"
    base = ["--mojo", FAKE_CRASH_MOJO, rel, "--precompile", "e2e/pkg/mathlib"]

    run = run_mtest([*base, "--retries", "0"], timeout=SHORT_TIMEOUT)
    expect_exit(run, 1)
    expect(
        "PRECOMPILE-ERROR" in run.combined,
        f"a crashed precompile did not report PRECOMPILE-ERROR:\n{run.stdout}",
    )
    # The ending, in words: the signal that killed the compiler, named.
    expect(
        "died by signal 11 (SIGSEGV, segmentation fault)" in run.combined,
        f"the PRECOMPILE-ERROR banner never named the signal:\n{run.stdout}",
    )
    # At --retries 0 exactly one attempt runs: no TRY line, no retry warning.
    expect(
        "TRY" not in run.stdout,
        f"--retries 0 retried a precompile step:\n{run.stdout}",
    )

    runr = run_mtest([*base, "--retries", "1"], timeout=SHORT_TIMEOUT)
    expect_exit(runr, 1)
    expect(
        runr.verdict_line("TRY", "e2e/pkg/mathlib") is not None,
        f"--retries 1 showed no TRY line for the crashed precompile:\n{runr.stdout}",
    )
    expect(
        "precompile" in runr.stdout and "compile-crash" in runr.stdout,
        f"the precompile TRY line lost its step/classification:\n{runr.stdout}",
    )
    expect(
        "compile-kill-residual" in runr.stdout,
        f"a killed precompile fired no cache-residual warning:\n{runr.stdout}",
    )
    expect(
        "quarantin" in runr.stdout,
        f"the retried precompile never mentioned the cache quarantine:\n{runr.stdout}",
    )
    expect(
        "PRECOMPILE-ERROR" in runr.combined and "2 attempts" in runr.combined,
        f"a retry-exhausted precompile did not report both attempts:\n{runr.stdout}",
    )
    return (
        "precompile crash: --retries 0 -> PRECOMPILE-ERROR naming signal 11 (exit 1);"
        " --retries 1 -> TRY + residual warning + quarantined retry -> PRECOMPILE-ERROR"
    )


def s_precompile_promotion(manifest: dict) -> str:
    """THE promotion guarantee: a failed precompile never touches OUT.

    An attempt builds to a temp path and is renamed onto OUT only after it exits
    0. So a step that is killed at the deadline, or dies by a signal, must leave a
    good package from an earlier run BYTE-IDENTICAL — and leave no temp litter in
    the OUT directory either. Both killed endings are checked against the same
    sentinel: this is the deliverable the whole change exists for.

    This scenario is DISCRIMINATING, not decorative: both shims TRUNCATE their
    `-o` path before sleeping/crashing, the way a real `mojo precompile` owns (and
    on failure deletes) its output. Point mtest at eager promotion — build to OUT
    directly — and every assertion below fails, because the shim then destroys the
    sentinel exactly as the real compiler would. The sentinel survives ONLY
    because mtest never let the compiler near OUT."""
    rel = "e2e/pkg/test_uses_pkg.mojo"
    out_dir = os.path.join(REPO_ROOT, "build", "e2e-promotion")
    out_rel = "build/e2e-promotion/mathlib.mojopkg"
    out_path = os.path.join(REPO_ROOT, out_rel)
    sentinel = b"SENTINEL-PACKAGE-BYTES\n"

    def _litter() -> list[str]:
        return sorted(
            name for name in os.listdir(out_dir) if name.endswith(".tmp")
        )

    try:
        for label, mojo_shim, extra in (
            ("killed at the deadline", FAKE_SLOW_MOJO, ["--compile-timeout", "1"]),
            ("crashed by a signal", FAKE_CRASH_MOJO, []),
        ):
            os.makedirs(out_dir, exist_ok=True)
            with open(out_path, "wb") as fh:
                fh.write(sentinel)
            run = run_mtest(
                [
                    "--mojo",
                    mojo_shim,
                    rel,
                    "--precompile",
                    f"e2e/pkg/mathlib:{out_rel}",
                    *extra,
                ],
                timeout=SHORT_TIMEOUT,
            )
            expect_exit(run, 1)
            expect(
                "PRECOMPILE-ERROR" in run.combined,
                f"the precompile {label} did not fail the step:\n{run.stdout}",
            )
            expect(
                os.path.isfile(out_path),
                f"a precompile {label} DESTROYED the good OUT package "
                f"({out_rel} no longer exists)",
            )
            with open(out_path, "rb") as fh:
                after = fh.read()
            expect(
                after == sentinel,
                f"a precompile {label} DAMAGED the good OUT package: "
                f"{after!r} != {sentinel!r}",
            )
            expect(
                _litter() == [],
                f"a precompile {label} left temp litter in OUT: {_litter()}",
            )
    finally:
        shutil.rmtree(out_dir, ignore_errors=True)
    return (
        "promotion: a precompile killed at the deadline and one killed by SIGSEGV"
        " both left the pre-existing OUT byte-identical, with no .tmp litter"
    )


def s_quiet_verbose(manifest: dict) -> str:
    rel = "e2e/suite/test_passing.mojo"
    quiet = run_mtest([rel, "-q"])
    expect_exit(quiet, 0)
    expect(
        not any(l.startswith("PASS") for l in quiet.stdout.splitlines()),
        "-q still printed a PASS verdict line",
    )
    expect("passed" in quiet.combined, "-q dropped the summary band")

    verbose = run_mtest([rel, "-v"])
    expect_exit(verbose, 0)
    expect("build:" in verbose.combined, "-v did not print the build command")
    expect("mojo build" in verbose.combined, "-v build line missing the build cmd")
    return "-q omits PASS lines; -v adds build cmd + timing"


def s_show_output(manifest: dict) -> str:
    fail = "e2e/suite/test_failing.mojo"
    pass_ = "e2e/suite/test_passing.mojo"
    none = run_mtest([fail, "--show-output", "none"])
    expect_exit(none, 1)
    expect("--- FAIL" not in none.stdout, "--show-output none still framed the FAIL")

    default = run_mtest([fail])
    expect_exit(default, 1)
    expect("--- FAIL" in default.stdout, "default did not frame the FAIL")
    # The reproduce line lives INSIDE the framed section, not just anywhere in
    # stdout, and names the failing file the way a human would re-invoke it.
    fail_section = default.stdout[default.stdout.index("--- FAIL") :]
    expect(
        f"reproduce: mtest {fail}" in fail_section,
        f"no reproduce: line for {fail} inside the framed FAIL section",
    )

    all_ = run_mtest([pass_, "--show-output", "all"])
    expect_exit(all_, 0)
    expect("--- PASS" in all_.stdout, "--show-output all did not frame the PASS")
    return "framing: none suppresses, failures frames FAIL, all frames PASS"


# A slowest-files row: two leading spaces, the path, then a trailing "N.NNs".
DURATIONS_ROW_RE = re.compile(r"^  (\S+)\s+([\d.]+)s\s*$")


def s_durations(manifest: dict) -> str:
    """`--durations N` renders a file-level slowest-files list, INFORMAL tier:
    structure only (presence, size, order, `-q` survival) — never exact
    timings."""
    suite = _suite_tests(manifest)
    files_run = sum(1 for row in suite.values() if row["verdict"] != "COMPILE-ERROR")
    cerr_rel = next(
        rel for rel, row in suite.items() if row["verdict"] == "COMPILE-ERROR"
    )

    # Absent without the flag.
    absent = run_mtest(["e2e/suite"])
    expect(
        "slowest" not in absent.stdout,
        "a slowest-files section appeared without --durations",
    )

    # Present with the flag; requesting far more rows than files ran, the
    # header states the ACTUAL (capped) count, never the requested N.
    requested = files_run + 50
    run = run_mtest(["e2e/suite", "--durations", str(requested)])
    m = re.search(r"slowest (\d+) files:\n((?:  .+\n)+)", run.stdout)
    expect(
        m is not None,
        f"no slowest-files section with --durations {requested}:\n{run.stdout}",
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
        expect(rm is not None, f"slowest-files row is not 'path  N.NNs': {ln!r}")
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
    quiet = run_mtest(["e2e/suite", "--durations", "2", "-q"])
    expect("slowest 2 files:" in quiet.stdout, "-q suppressed the --durations list")

    return f"absent w/o flag; {shown} rows (capped from {requested}), descending, survives -q"


def s_color(manifest: dict) -> str:
    """NO_COLOR must silence AUTO color even on a real tty; --color always is
    absolute and paints regardless of NO_COLOR or tty-ness.

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
    tty_rc, tty_out = run_mtest_pty(
        [rel], env_overrides={"NO_COLOR": None}, timeout=SHORT_TIMEOUT
    )
    expect(tty_rc == 1, f"expected exit 1 under a pty, got {tty_rc}")
    expect(
        b"\x1b" in tty_out,
        "AUTO on a real tty (NO_COLOR unset) produced no ANSI escapes",
    )

    no_color_rc, no_color_out = run_mtest_pty(
        [rel], env_overrides={"NO_COLOR": "1"}, timeout=SHORT_TIMEOUT
    )
    expect(no_color_rc == 1, f"expected exit 1 under a pty, got {no_color_rc}")
    expect(
        b"\x1b" not in no_color_out,
        "NO_COLOR=1 on a real tty still emitted ANSI escape bytes",
    )

    always = run_mtest([rel, "--color", "always"], timeout=SHORT_TIMEOUT)
    expect_exit(always, 1)
    expect(
        "\x1b" in always.stdout,
        "--color always emitted no ANSI even though it is documented absolute",
    )
    return "AUTO+tty colors, NO_COLOR silences it, --color always is absolute"


COLLECT_MATRIX_EXPECTED = [
    "e2e/matrix/test_alpha.mojo::test_alpha_one",
    "e2e/matrix/test_alpha.mojo::test_alpha_three",
    "e2e/matrix/test_alpha.mojo::test_alpha_two",
    "e2e/matrix/test_beta.mojo::test_beta_one",
    "e2e/matrix/test_beta.mojo::test_beta_two",
]
COLLECT_DIR_EXPECTED = [
    "e2e/collect/test_probe_ok.mojo::test_one",
    "e2e/collect/test_probe_ok.mojo::test_two",
]


def s_collect(manifest: dict) -> str:
    """`collect` / `--collect-only`: STDOUT is byte-clean and is ONLY the sorted
    node-id listing; every diagnostic goes to STDERR; the total per-file policy
    holds (qualifying listed; compile-error/crash/timeout/malformed -> stderr +
    continue + exit-1; drift -> exit 3; nothing collectable -> exit 5).

    STDOUT purity is asserted MECHANICALLY: stdout is split into lines and the
    lines must be exactly the sorted expected node-id set — nothing else may ride
    stdout, ever."""
    # 1. Byte-purity on a clean tree: stdout is EXACTLY the sorted listing.
    run = run_mtest(["collect", "e2e/matrix"])
    expect_exit(run, 0)
    node_ids = run.stdout.splitlines()
    expect(
        node_ids == sorted(node_ids),
        f"collect listing is not lexicographically sorted: {node_ids}",
    )
    expect(
        node_ids == COLLECT_MATRIX_EXPECTED,
        f"collect listing {node_ids} != expected {COLLECT_MATRIX_EXPECTED}",
    )
    # STDOUT ends in exactly one newline per node id and carries nothing else.
    expect(
        run.stdout == "".join(n + "\n" for n in COLLECT_MATRIX_EXPECTED),
        f"stdout is not the byte-clean listing:\n{run.stdout!r}",
    )
    expect(
        run.stderr.strip() == "",
        f"an all-qualifying collect must keep stderr empty:\n{run.stderr}",
    )

    # 2. `--collect-only` is byte-identical to the `collect` subcommand.
    co = run_mtest(["--collect-only", "e2e/matrix"])
    expect_exit(co, 0)
    expect(
        co.stdout == run.stdout,
        "--collect-only stdout differs from the collect subcommand",
    )

    # 3. The per-file matrix: a crashing probe and a hanging probe (bounded by a
    # short --timeout) each write a diagnostic to STDERR while the good file's
    # node ids are still listed; exit-1 class. No diagnostic leaks onto STDOUT.
    mtx = run_mtest(
        ["collect", "e2e/collect", "--timeout", "2"], timeout=SHORT_TIMEOUT
    )
    expect_exit(mtx, 1)
    mtx_ids = mtx.stdout.splitlines()
    expect(
        mtx_ids == COLLECT_DIR_EXPECTED,
        f"the good file's node ids were not listed: {mtx_ids}",
    )
    expect(
        "collect:" not in mtx.stdout,
        f"a diagnostic leaked onto STDOUT:\n{mtx.stdout!r}",
    )
    expect(
        "test_probe_crash.mojo" in mtx.stderr,
        f"the crashing probe had no STDERR diagnostic:\n{mtx.stderr}",
    )
    expect(
        "test_probe_hang.mojo" in mtx.stderr,
        f"the hanging probe had no STDERR diagnostic:\n{mtx.stderr}",
    )

    # 4. An off-grammar probe is DRIFT (exit 3); STDOUT stays empty.
    liar = run_mtest(
        ["collect", "e2e/hostile/test_liar.mojo"], timeout=SHORT_TIMEOUT
    )
    expect_exit(liar, 3)
    expect(liar.stdout == "", f"drift left bytes on STDOUT:\n{liar.stdout!r}")
    expect(
        "drift" in liar.stderr.lower(),
        f"the off-grammar probe surfaced no drift diagnostic:\n{liar.stderr}",
    )

    # 5. A malformed suite (silent) is exit-1; STDOUT stays empty.
    silent = run_mtest(
        ["collect", "e2e/hostile/test_silent.mojo"], timeout=SHORT_TIMEOUT
    )
    expect_exit(silent, 1)
    expect(silent.stdout == "", "a malformed probe left bytes on STDOUT")
    expect(
        "test_silent.mojo" in silent.stderr,
        f"the malformed probe had no STDERR diagnostic:\n{silent.stderr}",
    )

    # 6. Nothing collectable -> exit 5; STDOUT empty.
    tmp = tempfile.mkdtemp(
        prefix=".e2e_collect_empty_", dir=E2E_ROOT
    )
    try:
        rel = os.path.relpath(tmp, REPO_ROOT)
        empt = run_mtest(["collect", rel], timeout=SHORT_TIMEOUT)
        expect_exit(empt, 5)
        expect(empt.stdout == "", "nothing-collectable left bytes on STDOUT")
    finally:
        os.rmdir(tmp)

    return (
        "byte-clean sorted listing; --collect-only == collect; "
        "crash/hang/malformed -> stderr + continue (exit 1); drift exit 3; "
        "empty exit 5"
    )


def s_usage_refusals(manifest: dict) -> str:
    """collect is now served, so the collect-subcommand refusal is gone. The
    remaining usage refusal this build enforces is a RUN-ONLY flag combined with
    collect mode: a listing is not a run, so every served run-only flag
    (--maxfail, -x/--exitfirst, --gate, -s/--show-output) is refused with exit 4,
    while --timeout is NOT refused (it bounds the probes). Separately,
    --serial is part of the v1 contract but not served by this build, so it
    fires the standard availability refusal (exit 4, the flag named on
    stderr) regardless of subcommand. (--json is now SERVED — its destination
    taxonomy is proven by s_json_destination_taxonomy, not here.)"""
    run = run_mtest(
        ["collect", "--maxfail", "1", "e2e/matrix"], timeout=SHORT_TIMEOUT
    )
    expect_exit(run, 4)
    expect(
        "--maxfail" in run.stderr,
        f"collect+--maxfail did not name --maxfail on stderr:\n{run.stderr}",
    )
    expect(
        "run-only" in run.stderr,
        f"collect+--maxfail did not explain the run-only refusal:\n{run.stderr}",
    )
    expect(
        run.stdout == "",
        f"a usage error must print no listing to stdout, got:\n{run.stdout!r}",
    )

    gate = run_mtest(
        ["collect", "--gate", "e2e/matrix/test_alpha.mojo", "e2e/matrix"],
        timeout=SHORT_TIMEOUT,
    )
    expect_exit(gate, 4)
    expect(
        "--gate" in gate.stderr,
        f"collect+--gate did not name --gate on stderr:\n{gate.stderr}",
    )
    expect(
        "run-only" in gate.stderr,
        f"collect+--gate did not explain the run-only refusal:\n{gate.stderr}",
    )
    expect(
        gate.stdout == "",
        f"a usage error must print no listing to stdout, got:\n{gate.stdout!r}",
    )

    show = run_mtest(
        ["collect", "-s", "e2e/matrix"], timeout=SHORT_TIMEOUT
    )
    expect_exit(show, 4)
    expect(
        "run-only" in show.stderr,
        f"collect+-s did not explain the run-only refusal:\n{show.stderr}",
    )
    expect(
        show.stdout == "",
        f"a usage error must print no listing to stdout, got:\n{show.stdout!r}",
    )

    serial = run_mtest(
        ["--serial", "foo*", "e2e/matrix"], timeout=SHORT_TIMEOUT
    )
    expect_exit(serial, 4)
    expect(
        "--serial" in serial.stderr,
        f"--serial did not name itself on stderr:\n{serial.stderr}",
    )
    expect(
        "not available in this build" in serial.stderr,
        f"--serial did not fire the availability refusal:\n{serial.stderr}",
    )
    expect(
        serial.stdout == "",
        f"a usage error must print no listing to stdout, got:\n{serial.stdout!r}",
    )

    return (
        "run-only flags (--maxfail, --gate, -s) + collect -> exit 4 on "
        "stderr, no listing; --serial -> exit 4 availability refusal"
    )


def s_passthrough_and_forbidden(manifest: dict) -> str:
    rel = "e2e/suite/test_passing.mojo"
    good = run_mtest([rel, "--", "--no-optimization"])
    expect_exit(good, 0)
    expect(good.verdict_line("PASS", rel) is not None, "forwarded build arg broke the run")

    forbidden = [
        [rel, "--", "-o", "/tmp/x"],
        [rel, "--", "--emit=llvm"],
        [rel, "--", "extra_source.mojo"],
    ]
    for args in forbidden:
        run = run_mtest(args, timeout=SHORT_TIMEOUT)
        expect_exit(run, 4)
        expect(run.stderr.strip() != "", f"forbidden build arg {args} wrote nothing to stderr")
    return "passthrough build arg works; -o/--emit/extra-source each exit 4"


def s_out_of_root(manifest: dict) -> str:
    run = run_mtest(["../outside_the_root.mojo"], timeout=SHORT_TIMEOUT)
    expect_exit(run, 4)
    expect(
        "escapes the invocation root" in run.stderr or "escapes" in run.stderr,
        f"out-of-root operand did not report escaping the root:\n{run.stderr}",
    )
    return "out-of-root operand -> exit 4"


MATRIX_ALPHA = "e2e/matrix/test_alpha.mojo"
MATRIX_BETA = "e2e/matrix/test_beta.mojo"
CHAMELEON = "e2e/chameleon/test_chameleon.mojo"


def s_selection_keyword(manifest: dict) -> str:
    """`-k` narrows a file to a subset run under --only; the rest are DESELECTED.

    `-k two` selects only test_alpha_two of the three; the file runs under
    --only, PASSes, and the two unselected tests are counted DESELECTED (a
    summary count, never a listed verdict row)."""
    run = run_mtest([MATRIX_ALPHA, "-k", "two"])
    expect_exit(run, 0)
    summ = expect_accounting(run)
    expect(
        run.verdict_line("PASS", MATRIX_ALPHA) is not None,
        "the -k subset selection did not PASS the file",
    )
    expect(
        summ.deselected == 2,
        f"expected 2 deselected under -k two, got {summ.deselected}",
    )
    return "-k selects a subset (--only), rest DESELECTED; exit 0"


def s_selection_node_id(manifest: dict) -> str:
    """A node-id operand selects exactly one test; the rest are DESELECTED."""
    run = run_mtest([f"{MATRIX_ALPHA}::test_alpha_one"])
    expect_exit(run, 0)
    summ = expect_accounting(run)
    expect(
        run.verdict_line("PASS", MATRIX_ALPHA) is not None,
        "the node-id selection did not PASS the file",
    )
    expect(
        summ.deselected == 2,
        f"expected 2 deselected for a single node id, got {summ.deselected}",
    )
    return "node-id operand selects one test; 2 DESELECTED; exit 0"


def s_selection_union(manifest: dict) -> str:
    """A dir operand UNIONs with a node id under it: the whole tree still runs.

    `mtest e2e/matrix e2e/matrix/test_alpha.mojo::test_alpha_one`
    covers test_alpha.mojo with BOTH a plain dir operand and a node id — the
    plain operand wins (whole), so every test in both files runs and nothing is
    deselected."""
    run = run_mtest(["e2e/matrix", f"{MATRIX_ALPHA}::test_alpha_one"])
    expect_exit(run, 0)
    summ = expect_accounting(run)
    expect(
        run.verdict_line("PASS", MATRIX_ALPHA) is not None,
        "union run did not PASS test_alpha.mojo",
    )
    expect(
        run.verdict_line("PASS", MATRIX_BETA) is not None,
        "union run did not PASS test_beta.mojo (the dir must keep it whole)",
    )
    expect(
        summ.deselected == 0,
        f"union kept everything, but {summ.deselected} were deselected",
    )
    return "dir + node-id union runs the whole tree; 0 DESELECTED; exit 0"


def s_selection_malformed_node_id(manifest: dict) -> str:
    """More than one `::` is a MALFORMED node id -> exit 4, never 'unknown test'.
    """
    run = run_mtest(
        [f"{MATRIX_ALPHA}::test_alpha_one::extra"], timeout=SHORT_TIMEOUT
    )
    expect_exit(run, 4)
    expect(
        "malformed node id" in run.stderr,
        f"malformed node id did not say so on stderr:\n{run.stderr}",
    )
    expect(
        "unknown test" not in run.stderr,
        f"a malformed node id must NOT be reported as 'unknown test':\n{run.stderr}",
    )
    return "malformed node id (>1 '::') -> exit 4, names it, never 'unknown test'"


def s_selection_unknown_test(manifest: dict) -> str:
    """A node id naming a test the file does not collect -> exit 4 'unknown test'.
    """
    run = run_mtest([f"{MATRIX_ALPHA}::test_does_not_exist"], timeout=SHORT_TIMEOUT)
    expect_exit(run, 4)
    expect(
        "unknown test" in run.stderr,
        f"an unknown test name did not report 'unknown test':\n{run.stderr}",
    )
    return "unknown test name (after the probe) -> exit 4"


def s_selection_empty(manifest: dict) -> str:
    """A `-k` that matches nothing deselects every test -> nothing runs -> exit 5.
    """
    run = run_mtest([MATRIX_ALPHA, "-k", "no_such_keyword_zzz"])
    expect_exit(run, 5)
    return "empty final selection (all deselected) -> exit 5"


def s_selection_chameleon(manifest: dict) -> str:
    """The chameleon: recollect-once then MALFORMED-SUITE (exit-1), never exit 3.

    Selecting the ghost forces a --only run; the suite lists it under --skip-all
    but refuses it under --only, so mtest warns loudly, rebuilds + recollects,
    retries, sees the same refusal, and reports MALFORMED-SUITE."""
    run = run_mtest([CHAMELEON, "-k", "ghost"], timeout=SHORT_TIMEOUT)
    expect_exit(run, 1)
    expect(
        run.verdict_line("MALFORMED-SUITE", CHAMELEON) is not None,
        f"the chameleon was not reported MALFORMED-SUITE:\n{run.stdout}",
    )
    expect(
        "stale-name" in run.combined or "WARNING" in run.combined,
        f"the recover-once flow did not warn loudly:\n{run.combined}",
    )
    return "chameleon: loud recollect-once then MALFORMED-SUITE, exit 1 (not 3)"


def _mojo_log_path() -> str:
    """A fresh path for MTEST_MOJO_LOG, absent until the logging wrapper writes
    it — proves the wrapper (not some pre-existing file) produced the log."""
    fd, path = tempfile.mkstemp(prefix="mtest_mojo_log_", suffix=".tsv")
    os.close(fd)
    os.remove(path)
    return path


def _mojo_log_lines(path: str) -> list[str]:
    """The logging wrapper's recorded lines, or [] if it never wrote the file."""
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as fh:
        return [ln.rstrip("\n") for ln in fh if ln.strip()]


def _count_builds(lines: list[str], rel: str) -> int:
    """How many `build\\t<rel>\\t...` entries the wrapper logged for `rel`."""
    count = 0
    for ln in lines:
        fields = ln.split("\t")
        if len(fields) >= 2 and fields[0] == "build" and fields[1] == rel:
            count += 1
    return count


def s_single_build(manifest: dict) -> str:
    """The BuildProducts registry shares ONE `mojo build` per file between the
    selection probe and the run — proved with the committed logging `--mojo`
    wrapper (scripts/logging_mojo.py) over a SINGLE selection-run invocation.
    Two separate `mtest` invocations would legitimately rebuild; this scenario
    never does that.

    `-k one` over the whole e2e/matrix tree matches test_alpha_one AND
    test_beta_one, so BOTH files are touched — a multi-file selection. Phase 1
    (probe every run file) builds each file once; Phase 2 (run the selected
    subset) reuses that same binary. The wrapper's log is the independent
    witness: exactly one `mojo build <file>` line per file, not two."""
    log_path = _mojo_log_path()
    try:
        run = run_mtest(
            ["--mojo", LOGGING_MOJO, "-k", "one", "e2e/matrix"],
            env_overrides={"MTEST_MOJO_LOG": log_path},
        )
        expect_exit(run, 0)
        expect(
            os.path.exists(log_path),
            "the logging --mojo wrapper never wrote a log file",
        )
        lines = _mojo_log_lines(log_path)
        for rel in (MATRIX_ALPHA, MATRIX_BETA):
            n = _count_builds(lines, rel)
            expect(
                n == 1,
                f"expected exactly 1 'mojo build {rel}' over one selection-run "
                f"invocation (probe+run must share the build), got {n}: {lines}",
            )
        return (
            f"one invocation selects across 2 files (-k one); each built "
            f"exactly once ({len(lines)} mojo invocations logged total)"
        )
    finally:
        if os.path.exists(log_path):
            os.remove(log_path)


def s_stale_recovery_two_builds(manifest: dict) -> str:
    """The chameleon's stale-name recovery rebuilds the file EXACTLY TWICE: the
    initial Phase-1 build, then the one recollect-once rebuild the recovery
    flow triggers when the suite refuses under `--only` a name it just listed
    under `--skip-all`. The run still ends MALFORMED-SUITE (exit-1 class),
    never exit 3 — the recovery is a bounded retry, not a drift."""
    log_path = _mojo_log_path()
    try:
        run = run_mtest(
            ["--mojo", LOGGING_MOJO, CHAMELEON, "-k", "ghost"],
            env_overrides={"MTEST_MOJO_LOG": log_path},
            timeout=SHORT_TIMEOUT,
        )
        expect_exit(run, 1)
        expect(
            run.verdict_line("MALFORMED-SUITE", CHAMELEON) is not None,
            "the chameleon was not reported MALFORMED-SUITE under the logging "
            f"wrapper:\n{run.stdout}",
        )
        lines = _mojo_log_lines(log_path)
        n = _count_builds(lines, CHAMELEON)
        expect(
            n == 2,
            f"expected exactly 2 'mojo build {CHAMELEON}' entries (initial + "
            f"one stale-name rebuild), got {n}: {lines}",
        )
        return (
            "chameleon: 2 builds logged (initial + stale-name rebuild), "
            "MALFORMED-SUITE exit 1 (not 3)"
        )
    finally:
        if os.path.exists(log_path):
            os.remove(log_path)


def s_internal_error(manifest: dict) -> str:
    """A spawn/machinery failure must surface a diagnostic, not a silent exit 3.

    Point the runner at a nonexistent `--mojo`, so spawning `mojo build` fails
    with ENOENT before any file can be built. Assert exit 3, an INTERNAL-ERROR
    banner naming the build step, the missing program, and the errno; that NO
    false PASS/verdict line appears for the file; and that the file is accounted
    NOT-RUN in the summary."""
    rel = "e2e/suite/test_passing.mojo"
    missing = "/no/such/mojo/compiler"
    run = run_mtest(["--mojo", missing, rel], timeout=SHORT_TIMEOUT)
    expect_exit(run, 3)
    summ = expect_accounting(run)

    expect(
        "INTERNAL-ERROR" in run.stdout,
        f"no INTERNAL-ERROR banner on a spawn failure:\n{run.stdout}",
    )
    expect(
        "build" in run.stdout,
        f"internal-error banner did not name the build step:\n{run.stdout}",
    )
    expect(
        missing in run.stdout,
        f"internal-error banner did not name the missing program:\n{run.stdout}",
    )
    expect(
        "errno" in run.stdout,
        f"internal-error banner did not report an errno:\n{run.stdout}",
    )
    # No false verdict: the file must never be reported PASS (or any verdict).
    expect(
        run.verdict_line("PASS", rel) is None,
        f"spawn failure produced a false PASS verdict for {rel}",
    )
    expect(
        not verdict_paths_in_order(run),
        f"spawn failure produced verdict lines: {verdict_paths_in_order(run)}",
    )
    expect(
        summ.not_run >= 1,
        f"spawn-failed file not accounted NOT-RUN (not_run={summ.not_run})",
    )

    # A precompile spawn failure must name the real errno too, not a generic
    # errno 0. Point --precompile at a step whose compiler cannot be spawned: the
    # banner names the precompile step, the missing program, and ENOENT (errno 2)
    # exactly as the build path does — the errno is threaded, not dropped.
    pc = run_mtest(
        ["--mojo", missing, rel, "--precompile", "e2e/pkg/mathlib"],
        timeout=SHORT_TIMEOUT,
    )
    expect_exit(pc, 3)
    expect(
        "INTERNAL-ERROR" in pc.stdout,
        f"no INTERNAL-ERROR banner on a precompile spawn failure:\n{pc.stdout}",
    )
    expect(
        "precompile" in pc.stdout,
        f"internal-error banner did not name the precompile step:\n{pc.stdout}",
    )
    expect(
        "errno 2" in pc.stdout,
        f"precompile spawn failure dropped the real errno (expected ENOENT):"
        f"\n{pc.stdout}",
    )
    return (
        "exit 3; build+precompile INTERNAL-ERROR banners name step/program/"
        "errno; file NOT-RUN"
    )


def s_runtime_open_failure(manifest: dict) -> str:
    """The real CLI main must report and explicitly repair failed signal open."""
    try:
        return main_open_check.check_main_open_failure()
    except main_open_check.MainOpenCheckError as error:
        raise ScenarioError(str(error)) from error


def s_interrupt(manifest: dict) -> str:
    """Spawn mtest against slow/ in its OWN process group, wait until it has
    clearly started (its header appears), let it enter the hang, then SIGINT the
    group. Assert exit 2, a partial summary with NOT-RUN accounting, and that the
    process group is gone (no orphan). Hard-guarded so it can never hang CI."""
    argv = [MTEST, "e2e/slow"]
    proc = subprocess.Popen(
        argv,
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    pgid = os.getpgid(proc.pid)
    deadline = time.monotonic() + 60.0
    try:
        # Give the build+run of the hanging file time to get underway. Sequential
        # scheduling walks test_hanging first, so the passing siblings stay
        # unscheduled behind it. A fixed grace is enough and keeps this bounded.
        time.sleep(8.0)
        expect(proc.poll() is None, "mtest exited before it could be interrupted")
        os.killpg(pgid, signal.SIGINT)
        try:
            out, err = proc.communicate(timeout=max(5.0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            _kill_group(proc)
            proc.communicate()
            raise ScenarioError("mtest did not exit within the guard after SIGINT")
    finally:
        if proc.poll() is None:
            _kill_group(proc)

    expect(proc.returncode == 2, f"expected exit 2 on interrupt, got {proc.returncode}\n{out}\n{err}")
    combined = out + "\n" + err
    m = SUMMARY_RE.search(combined)
    expect(m is not None, f"no partial summary after interrupt:\n{combined}")
    not_run = int(m.group("not_run"))
    expect(not_run >= 1, f"interrupt summary showed no NOT-RUN accounting (not_run={not_run})")

    # The process group must be gone — no orphaned children.
    time.sleep(0.5)
    orphan = True
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        orphan = False
    expect(not orphan, f"process group {pgid} still alive after mtest exit (orphan)")
    return f"exit 2; partial summary with {not_run} NOT-RUN; no orphaned process group"


BUILD_BIN_TIMEOUT = 600.0
"""Hard wall-clock ceiling for the bare-invocation `pixi run build-bin`
bootstrap. Generous — a cold precompile+link is slow — but finite: every
subprocess spawn in this file is hard-timeout-guarded so a wedged toolchain can
never hang the gate, and this bootstrap path is no exception."""


def _bootstrap_build_bin() -> int | None:
    """Run `pixi run build-bin` in its own process group with a hard timeout,
    mirroring run_mtest's no-hang guarantee. Returns None on success, or an
    exit code for main() to return on failure/timeout."""
    argv = ["pixi", "run", "build-bin"]
    proc = subprocess.Popen(argv, cwd=REPO_ROOT, start_new_session=True)
    try:
        proc.communicate(timeout=BUILD_BIN_TIMEOUT)
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        proc.communicate()
        print(
            f"FATAL: `pixi run build-bin` did not finish within "
            f"{BUILD_BIN_TIMEOUT:.0f}s — killed its process group "
            f"(possible toolchain hang)",
            file=sys.stderr,
        )
        return 1
    if proc.returncode != 0:
        print(f"FATAL: `pixi run build-bin` exited {proc.returncode}", file=sys.stderr)
        return proc.returncode
    return None


def _looks_like_stream_line(line: str) -> bool:
    """Whether a line is an NDJSON event record (starts a JSON object)."""
    return line.startswith('{"event":')


def s_json_forward_compat(manifest: dict) -> str:
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


def s_json_purity(manifest: dict) -> str:
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


def s_json_color_on_relocated_stderr(manifest: dict) -> str:
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


def s_json_destination_taxonomy(manifest: dict) -> str:
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


def s_json_truncation_interrupt(manifest: dict) -> str:
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


def s_json_truncation_sigkill(manifest: dict) -> str:
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


def s_json_truncation_dead_pipe(manifest: dict) -> str:
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


def _build_json_terminal_write_fault(directory: str) -> str:
    """Build the test-only terminal-record write interposer in `directory`."""
    compiler = os.environ.get("CC", "clang")
    if sys.platform == "darwin":
        library = os.path.join(directory, "libmtest_json_terminal_fault.dylib")
        platform_flags = ["-dynamiclib"]
        link_libraries: list[str] = []
    else:
        library = os.path.join(directory, "libmtest_json_terminal_fault.so")
        platform_flags = ["-shared", "-fPIC"]
        link_libraries = ["-ldl"]
    argv = [
        compiler,
        "-std=c17",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-Wpedantic",
        *platform_flags,
        JSON_TERMINAL_WRITE_FAULT,
        "-o",
        library,
        *link_libraries,
    ]
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
            "the JSON terminal-write fault interposer did not compile within "
            f"{SHORT_TIMEOUT}s:\n{output}"
        )
    expect(
        proc.returncode == 0,
        f"could not compile the JSON terminal-write fault interposer "
        f"({proc.returncode}):\n{output}",
    )
    return library


def s_json_terminal_write_failure(manifest: dict) -> str:
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
        text = Path(stream_path).read_text(encoding="utf-8")
        report = json_stream_check.parse_stream(text)
        expect(report.terminal is None, "the rejected terminal record reached the stream")
        file_finishes = [
            record
            for record in report.records
            if record.get("event") == "file_finished"
        ]
        expect(
            len(file_finishes) == 1,
            f"expected one committed pre-terminal file_finished record, got "
            f"{len(file_finishes)}",
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


def s_junit_scratch_cleanup(manifest: dict) -> str:
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
        expect(os.path.exists(report_path), "the junit report was not written")
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


def s_junit_schema_gate(manifest: dict) -> str:
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


def s_junit_determinism(manifest: dict) -> str:
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


def s_junit_prior_report_intact(manifest: dict) -> str:
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


def s_junit_finalization_and_interrupt(manifest: dict) -> str:
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


def s_annotations_modes(manifest: dict) -> str:
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


def s_annotations_caps(manifest: dict) -> str:
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


def s_annotations_conflict(manifest: dict) -> str:
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


def s_annotations_fencing(manifest: dict) -> str:
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


SCENARIOS = [
    ("manifest-completeness", s_manifest_completeness),
    ("resilience-matrix", s_resilience_matrix),
    ("default-suite", s_default_suite),
    ("hostile", s_hostile),
    ("single-pass", s_single_pass),
    ("exitfirst", s_exitfirst),
    ("maxfail", s_maxfail),
    ("retries-flaky", s_retries_flaky),
    ("crash-attribution", s_crash_attribution),
    ("attribution-reruns-crashed-binary", s_attribution_reruns_the_binary_that_crashed),
    ("compile-timeout", s_compile_timeout),
    ("compile-crash-signature", s_compile_crash_signature),
    ("exclude+stale", s_exclude_and_stale),
    ("all-excluded", s_all_excluded),
    ("empty-dir", s_empty_dir),
    ("failing-gate", s_failing_gate),
    ("timeout", s_timeout),
    ("timeout-escalation", s_timeout_escalation),
    ("precompile", s_precompile),
    ("precompile-timeout", s_precompile_timeout),
    ("precompile-crash-retry", s_precompile_crash_retry),
    ("precompile-promotion", s_precompile_promotion),
    ("quiet-verbose", s_quiet_verbose),
    ("show-output", s_show_output),
    ("durations", s_durations),
    ("color", s_color),
    ("usage-refusals", s_usage_refusals),
    ("selection-keyword", s_selection_keyword),
    ("selection-node-id", s_selection_node_id),
    ("selection-union", s_selection_union),
    ("selection-malformed-node-id", s_selection_malformed_node_id),
    ("selection-unknown-test", s_selection_unknown_test),
    ("selection-empty", s_selection_empty),
    ("selection-chameleon", s_selection_chameleon),
    ("single-build", s_single_build),
    ("stale-recovery-two-builds", s_stale_recovery_two_builds),
    ("collect", s_collect),
    ("passthrough+forbidden", s_passthrough_and_forbidden),
    ("out-of-root", s_out_of_root),
    ("internal-error", s_internal_error),
    ("runtime-open-failure", s_runtime_open_failure),
    ("interrupt", s_interrupt),
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
]


def main() -> int:
    if not os.path.exists(MTEST):
        # The e2e pixi task depends on build-bin, but support a bare invocation.
        print(f"building binary (missing {MTEST}) ...", flush=True)
        bootstrap_rc = _bootstrap_build_bin()
        if bootstrap_rc is not None:
            return bootstrap_rc

    manifest = load_manifest()
    h = Harness(manifest)

    print("=== mtest end-to-end gate ===", flush=True)
    for name, fn in SCENARIOS:
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
