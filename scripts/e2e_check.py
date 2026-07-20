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
from scripts.e2e.scenarios import (
    core,
    json_reporter,
    junit_reporter,
    resilience,
    selection,
)
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
    ("json-forward-compat", json_reporter.s_json_forward_compat),
    ("json-purity", json_reporter.s_json_purity),
    ("json-color-relocated-stderr", json_reporter.s_json_color_on_relocated_stderr),
    ("json-destination-taxonomy", json_reporter.s_json_destination_taxonomy),
    ("json-truncation-interrupt", json_reporter.s_json_truncation_interrupt),
    ("json-truncation-sigkill", json_reporter.s_json_truncation_sigkill),
    ("json-truncation-dead-pipe", json_reporter.s_json_truncation_dead_pipe),
    ("json-terminal-write-failure", json_reporter.s_json_terminal_write_failure),
    ("junit-scratch-cleanup", junit_reporter.s_junit_scratch_cleanup),
    ("junit-schema-gate", junit_reporter.s_junit_schema_gate),
    ("junit-determinism", junit_reporter.s_junit_determinism),
    ("junit-prior-report-intact", junit_reporter.s_junit_prior_report_intact),
    ("junit-finalization-and-interrupt", junit_reporter.s_junit_finalization_and_interrupt),
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
