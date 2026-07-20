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
    annotations,
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
    ("annotations-modes", annotations.s_annotations_modes),
    ("annotations-caps", annotations.s_annotations_caps),
    ("annotations-conflict", annotations.s_annotations_conflict),
    ("annotations-fencing", annotations.s_annotations_fencing),
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
