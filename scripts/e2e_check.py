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

import json
import os
import pty
import re
import select
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MTEST = os.path.join(REPO_ROOT, "build", "mtest")
E2E_ROOT = os.path.join(REPO_ROOT, "e2e")
MANIFEST_PATH = os.path.join(E2E_ROOT, "manifest.json")
LOGGING_MOJO = os.path.join(REPO_ROOT, "scripts", "logging_mojo.py")
FAKE_SLOW_MOJO = os.path.join(REPO_ROOT, "scripts", "fake_slow_mojo.py")

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
    child_env = None
    if env_overrides:
        child_env = dict(os.environ)
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

    # Standing pin: the crashing fixture dies by SIGILL (signal 4). mtest
    # renders the terminating signal both as the bare number and named in words
    # ("signal 4 — SIGILL, illegal instruction") on the verdict line, so a
    # regression that changes the death signal OR drops the word-name is caught
    # here rather than only by a one-time manual cross-check.
    expect(len(crash_lines) == 1, f"expected exactly one CRASH fixture, got {crash_lines}")
    for rel, line in crash_lines.items():
        expect(
            "signal 4" in line,
            f"CRASH verdict line for {rel} lost its signal-4 detail: {line!r}",
        )
        expect(
            "SIGILL" in line,
            f"CRASH verdict line for {rel} lost its worded signal name: {line!r}",
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
    run = run_mtest(
        ["e2e/slow/test_hanging.mojo", "--timeout", "1"], timeout=SHORT_TIMEOUT
    )
    expect_exit(run, 1)
    summ = expect_accounting(run)
    expect(summ.timed_out == 1, f"expected 1 timed out, got {summ.timed_out}")
    expect(
        run.verdict_line("TIMEOUT", "e2e/slow/test_hanging.mojo") is not None,
        "no TIMEOUT verdict line",
    )
    expect(run.wall < 10.0, f"mtest took {run.wall:.1f}s to honor --timeout 1")
    return f"TIMEOUT verdict, exit 1, returned in {run.wall:.1f}s"


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
    --serial/--json are part of the v1 contract but not served by this build, so
    each fires the standard availability refusal (exit 4, the flag named on
    stderr) regardless of subcommand."""
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

    json_path = run_mtest(
        ["--json", "out.json", "e2e/matrix"], timeout=SHORT_TIMEOUT
    )
    expect_exit(json_path, 4)
    expect(
        "--json" in json_path.stderr,
        f"--json did not name itself on stderr:\n{json_path.stderr}",
    )
    expect(
        "not available in this build" in json_path.stderr,
        f"--json did not fire the availability refusal:\n{json_path.stderr}",
    )
    expect(
        json_path.stdout == "",
        f"a usage error must print no listing to stdout, got:\n{json_path.stdout!r}",
    )

    json_stdout = run_mtest(
        ["--json", "-", "e2e/matrix"], timeout=SHORT_TIMEOUT
    )
    expect_exit(json_stdout, 4)
    expect(
        "--json" in json_stdout.stderr,
        f"--json - did not name itself on stderr:\n{json_stdout.stderr}",
    )
    expect(
        "not available in this build" in json_stdout.stderr,
        f"--json - did not fire the availability refusal:\n{json_stdout.stderr}",
    )
    expect(
        json_stdout.stdout == "",
        f"a usage error must print no listing to stdout, got:\n{json_stdout.stdout!r}",
    )

    return (
        "run-only flags (--maxfail, --gate, -s) + collect -> exit 4 on "
        "stderr, no listing; --serial/--json -> exit 4 availability refusal"
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
    h.scenario("manifest-completeness", s_manifest_completeness)
    h.scenario("default-suite", s_default_suite)
    h.scenario("hostile", s_hostile)
    h.scenario("single-pass", s_single_pass)
    h.scenario("exitfirst", s_exitfirst)
    h.scenario("maxfail", s_maxfail)
    h.scenario("retries-flaky", s_retries_flaky)
    h.scenario("compile-timeout", s_compile_timeout)
    h.scenario("exclude+stale", s_exclude_and_stale)
    h.scenario("all-excluded", s_all_excluded)
    h.scenario("empty-dir", s_empty_dir)
    h.scenario("failing-gate", s_failing_gate)
    h.scenario("timeout", s_timeout)
    h.scenario("precompile", s_precompile)
    h.scenario("quiet-verbose", s_quiet_verbose)
    h.scenario("show-output", s_show_output)
    h.scenario("durations", s_durations)
    h.scenario("color", s_color)
    h.scenario("usage-refusals", s_usage_refusals)
    h.scenario("selection-keyword", s_selection_keyword)
    h.scenario("selection-node-id", s_selection_node_id)
    h.scenario("selection-union", s_selection_union)
    h.scenario("selection-malformed-node-id", s_selection_malformed_node_id)
    h.scenario("selection-unknown-test", s_selection_unknown_test)
    h.scenario("selection-empty", s_selection_empty)
    h.scenario("selection-chameleon", s_selection_chameleon)
    h.scenario("single-build", s_single_build)
    h.scenario("stale-recovery-two-builds", s_stale_recovery_two_builds)
    h.scenario("collect", s_collect)
    h.scenario("passthrough+forbidden", s_passthrough_and_forbidden)
    h.scenario("out-of-root", s_out_of_root)
    h.scenario("internal-error", s_internal_error)
    h.scenario("interrupt", s_interrupt)

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
