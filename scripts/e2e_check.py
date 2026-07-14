#!/usr/bin/env python3
"""End-to-end gate for mtest.

Runs the real `build/mtest` binary against the committed known-outcome tree under
testdata/ and asserts, for a table of scenarios, the EXACT exit code and the
STRUCTURE of the console output (verdict tokens, root-relative paths, summary
count arithmetic, framing presence/absence, error messages). Console layout is an
informal surface, so nothing here is byte-golden: it asserts tokens and counts,
never exact bytes.

Expectations come from testdata/manifest.json — the single source of truth. This
script consumes it directly and checks completeness both ways: every discovered
test_*.mojo file has a manifest row, and every manifest row names a file that
exists. There is no parallel hard-coded expectations table.

Safety: every subprocess spawn has a hard wall-clock timeout and runs in its own
process group, so a runner bug can never hang the gate. The only fixture that
never returns (testdata/slow/test_hanging.mojo) is reached solely by the
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
MANIFEST_PATH = os.path.join(REPO_ROOT, "testdata", "manifest.json")

# Generous per-spawn wall-clock ceilings. Cold `mojo build` is slow, so these are
# roomy — their only job is to keep a hung runner from wedging CI, never to time
# a scenario. The TIMEOUT and interrupt scenarios assert their own tighter bounds.
DEFAULT_TIMEOUT = 180.0
SHORT_TIMEOUT = 30.0

SUMMARY_RE = re.compile(
    r"=====\s+(\d+) passed,\s+(\d+) failed,\s+(\d+) crashed,\s+"
    r"(\d+) timed out,\s+(\d+) compile error\s+"
    r"\((\d+) excluded,\s+(\d+) not run\)\s+in\s+([\d.]+)s\s+====="
)
HEADER_RE = re.compile(r"root:\s+.*?selected:\s+(\d+) files\s+excluded:\s+(\d+)")

VERDICT_TO_BUCKET = {
    "PASS": "passed",
    "FAIL": "failed",
    "CRASH": "crashed",
    "TIMEOUT": "timed_out",
    "COMPILE-ERROR": "compile_error",
}

# A run/failing-outcome verdict line starts at column 0 with one of these
# tokens, then the root-relative path (never contains whitespace in this tree).
# Used to check contract §17's determinism promise: the console summary is
# ordered lexicographically by path, independent of finish order.
VERDICT_LINE_RE = re.compile(
    r"^(?:" + "|".join(re.escape(t) for t in VERDICT_TO_BUCKET) + r")\s+(\S+)",
    re.MULTILINE,
)


def verdict_paths_in_order(run: Run) -> list[str]:
    """Root-relative paths named by run-outcome verdict lines, in stdout order."""
    return VERDICT_LINE_RE.findall(run.stdout)


@dataclass
class Summary:
    passed: int
    failed: int
    crashed: int
    timed_out: int
    compile_error: int
    excluded: int
    not_run: int
    seconds: float

    @property
    def run_outcomes(self) -> int:
        return (
            self.passed
            + self.failed
            + self.crashed
            + self.timed_out
            + self.compile_error
        )


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
        g = m.groups()
        return Summary(
            passed=int(g[0]),
            failed=int(g[1]),
            crashed=int(g[2]),
            timed_out=int(g[3]),
            compile_error=int(g[4]),
            excluded=int(g[5]),
            not_run=int(g[6]),
            seconds=float(g[7]),
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
    """The counting invariant that must hold on every run that reaches a summary:
    run outcomes + not-run == header-selected, and the two excluded counts agree."""
    summ = run.summary()
    selected, hdr_excluded = run.header()
    expect(
        summ.run_outcomes + summ.not_run == selected,
        f"accounting broken: run_outcomes({summ.run_outcomes}) + "
        f"not_run({summ.not_run}) != selected({selected}) for {run.argv}",
    )
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
    root = os.path.join(REPO_ROOT, "testdata")
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
    run = run_mtest(["testdata/suite"])
    # Any exit_class-1 member means the session exits 1.
    any_failing = any(row["exit_class"] == 1 for row in suite.values())
    expect_exit(run, 1 if any_failing else 0)
    summ = expect_accounting(run)

    # Every suite file shows its manifest verdict token on a line naming its path.
    crash_lines: dict[str, str] = {}
    compile_error_files: list[str] = []
    for rel, row in suite.items():
        token = row["verdict"]
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

    # The zero-test file is PASS (the documented ceiling).
    zero = [r for r, row in suite.items() if row.get("zero_test_ceiling")]
    expect(len(zero) == 1, "expected exactly one zero-test-ceiling file")
    expect(
        run.verdict_line("PASS", zero[0]) is not None,
        "zero-test file did not show PASS",
    )
    # helper.mojo (non-discovered) must never appear.
    for rel in manifest.get("non_discovered", {}):
        expect(rel not in run.stdout, f"non-discovered file {rel} appeared in output")

    # Summary counts equal what the manifest predicts for the suite.
    want = {"passed": 0, "failed": 0, "crashed": 0, "timed_out": 0, "compile_error": 0}
    for row in suite.values():
        want[VERDICT_TO_BUCKET[row["verdict"]]] += 1
    got = {
        "passed": summ.passed,
        "failed": summ.failed,
        "crashed": summ.crashed,
        "timed_out": summ.timed_out,
        "compile_error": summ.compile_error,
    }
    expect(got == want, f"suite summary counts {got} != manifest {want}")
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


def s_single_pass(manifest: dict) -> str:
    rel = "testdata/suite/test_passing.mojo"
    run = run_mtest([rel])
    expect_exit(run, 0)
    expect(run.verdict_line("PASS", rel) is not None, "no PASS verdict line")
    expect_accounting(run)
    return "single passing file -> exit 0"


def s_exitfirst(manifest: dict) -> str:
    run = run_mtest(["testdata/suite", "-x"])
    expect_exit(run, 1)
    summ = expect_accounting(run)
    expect(summ.not_run >= 1, f"-x left nothing NOT-RUN (not_run={summ.not_run})")
    return f"-x stopped scheduling; {summ.not_run} NOT-RUN, accounting holds"


def s_exclude_and_stale(manifest: dict) -> str:
    run = run_mtest(
        [
            "testdata/excluded",
            "testdata/suite/test_passing.mojo",
            "--exclude",
            "testdata/excluded/test_excluded.mojo",
            "--exclude",
            "testdata/stale_no_such_*.mojo",
        ]
    )
    expect_exit(run, 0)
    summ = expect_accounting(run)
    expect(
        run.verdict_line("EXCLUDED", "testdata/excluded/test_excluded.mojo") is not None,
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
        ["testdata/excluded", "--exclude", "testdata/excluded/test_excluded.mojo"]
    )
    expect_exit(run, 5)
    expect(
        run.verdict_line("EXCLUDED", "testdata/excluded/test_excluded.mojo") is not None,
        "no EXCLUDED line",
    )
    return "everything excluded -> exit 5"


def s_empty_dir(manifest: dict) -> str:
    # Must live inside the invocation root (an out-of-root operand is exit 4).
    tmp = tempfile.mkdtemp(prefix=".e2e_empty_", dir=os.path.join(REPO_ROOT, "testdata"))
    try:
        rel = os.path.relpath(tmp, REPO_ROOT)
        run = run_mtest([rel])
        expect_exit(run, 5)
    finally:
        os.rmdir(tmp)
    return "empty directory -> exit 5"


def s_failing_gate(manifest: dict) -> str:
    run = run_mtest(
        ["testdata/suite", "--gate", "testdata/suite/test_failing.mojo"]
    )
    expect_exit(run, 1)
    summ = expect_accounting(run)
    expect(summ.not_run >= 1, f"gate abort left nothing NOT-RUN ({summ.not_run})")
    expect(summ.failed >= 1, "gate failure not reflected in summary")
    return f"failing gate aborts; {summ.not_run} NOT-RUN"


def s_timeout(manifest: dict) -> str:
    run = run_mtest(
        ["testdata/slow/test_hanging.mojo", "--timeout", "1"], timeout=SHORT_TIMEOUT
    )
    expect_exit(run, 1)
    summ = expect_accounting(run)
    expect(summ.timed_out == 1, f"expected 1 timed out, got {summ.timed_out}")
    expect(
        run.verdict_line("TIMEOUT", "testdata/slow/test_hanging.mojo") is not None,
        "no TIMEOUT verdict line",
    )
    expect(run.wall < 10.0, f"mtest took {run.wall:.1f}s to honor --timeout 1")
    return f"TIMEOUT verdict, exit 1, returned in {run.wall:.1f}s"


def s_precompile(manifest: dict) -> str:
    rel = "testdata/pkg/test_uses_pkg.mojo"
    # Success: package precompiled, auto -I resolves the import -> PASS.
    ok = run_mtest([rel, "--precompile", "testdata/pkg/mathlib"])
    expect_exit(ok, 0)
    expect(ok.verdict_line("PASS", rel) is not None, "precompiled import did not PASS")
    expect(
        "COMPILE-ERROR" not in ok.stdout,
        "auto -I failed: importing test hit a COMPILE-ERROR",
    )
    # Failure: broken package -> PRECOMPILE banner, casualties, exit 1.
    bad = run_mtest([rel, "--precompile", "testdata/pkg_broken/badlib"])
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
    rel = "testdata/suite/test_passing.mojo"
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
    fail = "testdata/suite/test_failing.mojo"
    pass_ = "testdata/suite/test_passing.mojo"
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


def s_color(manifest: dict) -> str:
    """NO_COLOR must silence AUTO color even on a real tty; --color always is
    absolute and paints regardless of NO_COLOR or tty-ness.

    A piped stdout (run_mtest) is NEVER a tty, so AUTO would already be
    colorless for an unrelated reason — that would make "NO_COLOR -> no ANSI"
    trivially true even if NO_COLOR were ignored outright. run_mtest_pty
    attaches a real pty so the AUTO+tty case is actually colored first, then
    proves NO_COLOR turns it off.
    """
    rel = "testdata/suite/test_failing.mojo"

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


def s_usage_refusals(manifest: dict) -> str:
    cases = [
        (["collect", "testdata/suite/test_passing.mojo"], "collect"),
        (["testdata/suite/test_passing.mojo", "--maxfail", "1"], "maxfail"),
        (["testdata/suite/test_passing.mojo", "-k", "foo"], "-k"),
    ]
    for args, needle in cases:
        run = run_mtest(args, timeout=SHORT_TIMEOUT)
        expect_exit(run, 4)
        expect(
            needle in run.stderr,
            f"usage error for {args} did not name '{needle}' on stderr:\n{run.stderr}",
        )
        expect(run.stderr.strip() != "", f"usage error for {args} wrote nothing to stderr")
    return "collect / --maxfail / -k each refused with exit 4 on stderr"


def s_passthrough_and_forbidden(manifest: dict) -> str:
    rel = "testdata/suite/test_passing.mojo"
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


def s_internal_error(manifest: dict) -> str:
    """A spawn/machinery failure must surface a diagnostic, not a silent exit 3.

    Point the runner at a nonexistent `--mojo`, so spawning `mojo build` fails
    with ENOENT before any file can be built. Assert exit 3, an INTERNAL-ERROR
    banner naming the build step, the missing program, and the errno; that NO
    false PASS/verdict line appears for the file; and that the file is accounted
    NOT-RUN in the summary."""
    rel = "testdata/suite/test_passing.mojo"
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
        ["--mojo", missing, rel, "--precompile", "testdata/pkg/mathlib"],
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
    argv = [MTEST, "testdata/slow"]
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
    not_run = int(m.group(7))
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
    h.scenario("single-pass", s_single_pass)
    h.scenario("exitfirst", s_exitfirst)
    h.scenario("exclude+stale", s_exclude_and_stale)
    h.scenario("all-excluded", s_all_excluded)
    h.scenario("empty-dir", s_empty_dir)
    h.scenario("failing-gate", s_failing_gate)
    h.scenario("timeout", s_timeout)
    h.scenario("precompile", s_precompile)
    h.scenario("quiet-verbose", s_quiet_verbose)
    h.scenario("show-output", s_show_output)
    h.scenario("color", s_color)
    h.scenario("usage-refusals", s_usage_refusals)
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
