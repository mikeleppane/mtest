"""Core outcomes and ordinary console E2E scenarios."""

from __future__ import annotations

import os
import re
import shutil
import signal
import sys
import tempfile

from scripts.e2e.assertions import (
    VERDICT_TO_BUCKET,
    expect,
    expect_accounting,
    expect_exit,
    verdict_line,
    verdict_paths_in_order,
)
from scripts.e2e.runner import (
    E2E_ROOT,
    REPO_ROOT,
    SHORT_TIMEOUT,
    ScenarioContext,
    discovered_test_files,
)


def s_manifest_completeness(context: ScenarioContext) -> str:
    tests = context.manifest["tests"]
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


def _suite_tests(manifest: dict) -> dict:
    return {
        rel: row
        for rel, row in manifest["tests"].items()
        if row.get("in_default_suite")
    }


def s_default_suite(context: ScenarioContext) -> str:
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


def s_hostile(context: ScenarioContext) -> str:
    """The hostile handshake set: each report-shaped adversary, run alone.

    silent -> MALFORMED-SUITE (exit 1); forger (two blocks) -> MALFORMED-SUITE
    (exit 1); liar (off-grammar report) -> DRIFT (exit 3); overflow (a ~13 MiB
    flood) -> CAPTURE-OVERFLOW FAIL (exit 1). These files are NOT in the default
    suite — the liar alone forces exit 3, which would swamp a whole-suite run —
    so each is driven on its own here. The verdict tokens and exit codes come
    straight from the manifest rows for e2e/hostile/*."""
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


def s_single_pass(context: ScenarioContext) -> str:
    rel = "e2e/suite/test_passing.mojo"
    run = context.runner.run_mtest([rel])
    expect_exit(run, 0)
    expect(verdict_line(run, "PASS", rel) is not None, "no PASS verdict line")
    expect_accounting(run)
    return "single passing file -> exit 0"


def s_exitfirst(context: ScenarioContext) -> str:
    run = context.runner.run_mtest(["e2e/suite", "-x"])
    expect_exit(run, 1)
    summ = expect_accounting(run)
    expect(summ.not_run >= 1, f"-x left nothing NOT-RUN (not_run={summ.not_run})")
    return f"-x stopped scheduling; {summ.not_run} NOT-RUN, accounting holds"


def s_maxfail(context: ScenarioContext) -> str:
    """`--maxfail N` stops scheduling once N failing TESTS have accumulated.

    e2e/maxfail/ sorts test_a_fail, test_b_fail, test_c_pass; each failing
    file contributes exactly one failing test. `--maxfail 1` must stop right
    after test_a_fail, leaving the other two NOT-RUN."""
    run = context.runner.run_mtest(["e2e/maxfail", "--maxfail", "1"])
    expect_exit(run, 1)
    summ = expect_accounting(run)
    expect(summ.failed == 1, f"--maxfail 1 let {summ.failed} FAILs run, expected 1")
    expect(summ.not_run == 2, f"--maxfail 1 left {summ.not_run} NOT-RUN, expected 2")
    expect(
        verdict_line(run, "FAIL", "e2e/maxfail/test_a_fail.mojo") is not None,
        "the file that tripped --maxfail did not report FAIL",
    )
    return f"--maxfail 1 stopped after 1 failing test; {summ.not_run} NOT-RUN, accounting holds"


def s_exclude_and_stale(context: ScenarioContext) -> str:
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
    run = context.runner.run_mtest(
        ["e2e/suite", "--gate", "e2e/suite/test_failing.mojo"]
    )
    expect_exit(run, 1)
    summ = expect_accounting(run)
    expect(summ.not_run >= 1, f"gate abort left nothing NOT-RUN ({summ.not_run})")
    expect(summ.failed >= 1, "gate failure not reflected in summary")
    return f"failing gate aborts; {summ.not_run} NOT-RUN"


def s_quiet_verbose(context: ScenarioContext) -> str:
    rel = "e2e/suite/test_passing.mojo"
    quiet = context.runner.run_mtest([rel, "-q"])
    expect_exit(quiet, 0)
    expect(
        not any(l.startswith("PASS") for l in quiet.stdout.splitlines()),
        "-q still printed a PASS verdict line",
    )
    expect("passed" in quiet.combined, "-q dropped the summary band")

    verbose = context.runner.run_mtest([rel, "-v"])
    expect_exit(verbose, 0)
    expect("build:" in verbose.combined, "-v did not print the build command")
    expect("mojo build" in verbose.combined, "-v build line missing the build cmd")
    return "-q omits PASS lines; -v adds build cmd + timing"


def s_show_output(context: ScenarioContext) -> str:
    fail = "e2e/suite/test_failing.mojo"
    pass_ = "e2e/suite/test_passing.mojo"
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
    """`--durations N` renders a file-level slowest-files list, INFORMAL tier:
    structure only (presence, size, order, `-q` survival) — never exact
    timings."""
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
    quiet = context.runner.run_mtest(["e2e/suite", "--durations", "2", "-q"])
    expect("slowest 2 files:" in quiet.stdout, "-q suppressed the --durations list")

    return f"absent w/o flag; {shown} rows (capped from {requested}), descending, survives -q"


def s_color(context: ScenarioContext) -> str:
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
    rel = "e2e/suite/test_passing.mojo"
    good = context.runner.run_mtest([rel, "--", "--no-optimization"])
    expect_exit(good, 0)
    expect(verdict_line(good, "PASS", rel) is not None, "forwarded build arg broke the run")

    forbidden = [
        [rel, "--", "-o", "/tmp/x"],
        [rel, "--", "--emit=llvm"],
        [rel, "--", "extra_source.mojo"],
    ]
    for args in forbidden:
        run = context.runner.run_mtest(args, timeout=SHORT_TIMEOUT)
        expect_exit(run, 4)
        expect(run.stderr.strip() != "", f"forbidden build arg {args} wrote nothing to stderr")
    return "passthrough build arg works; -o/--emit/extra-source each exit 4"


def s_out_of_root(context: ScenarioContext) -> str:
    run = context.runner.run_mtest(["../outside_the_root.mojo"], timeout=SHORT_TIMEOUT)
    expect_exit(run, 4)
    expect(
        "escapes the invocation root" in run.stderr or "escapes" in run.stderr,
        f"out-of-root operand did not report escaping the root:\n{run.stderr}",
    )
    return "out-of-root operand -> exit 4"
